;; State Machine Lending Protocol 
;; Explicit state transitions with validation gates

;; === AUTHORITY & CONSTANTS ===
(define-constant SYSTEM_AUTHORITY tx-sender)
(define-constant DECIMAL_PRECISION u1000000)
(define-constant TIME_UNITS_PER_YEAR u31536000)
(define-constant MAX_UTILIZATION u1000000)

;; === STATE TRANSITION ERRORS ===
(define-constant UNAUTHORIZED_TRANSITION (err u301))
(define-constant INVALID_STATE_CHANGE (err u302))
(define-constant INSUFFICIENT_RESOURCES (err u303))
(define-constant COLLATERAL_VIOLATION (err u304))
(define-constant MARKET_SUSPENDED (err u305))
(define-constant POSITION_HEALTHY (err u306))
(define-constant BORROWER_UNKNOWN (err u307))
(define-constant TRANSITION_BLOCKED (err u308))

;; === MARKET STATE VARIABLES ===
(define-data-var market-liquidity uint u0)
(define-data-var active-loans uint u0)
(define-data-var lending-multiplier uint DECIMAL_PRECISION)
(define-data-var borrowing-multiplier uint DECIMAL_PRECISION)
(define-data-var checkpoint-time uint u0)
(define-data-var market-status bool true)

;; === RATE MODEL STATE ===
(define-data-var baseline-rate uint u20000)      ;; 2% floor rate
(define-data-var efficiency-slope uint u100000)  ;; 10% linear slope  
(define-data-var stress-slope uint u600000)     ;; 60% stress slope
(define-data-var efficiency-target uint u800000) ;; 80% target utilization

;; === SECURITY MODEL STATE ===
(define-data-var collateral-coverage uint u750000)  ;; 75% coverage requirement
(define-data-var liquidation-premium uint u100000)  ;; 10% liquidation bonus
(define-data-var protocol-reserve uint u100000)     ;; 10% protocol take

;; === PARTICIPANT STATE MAPS ===
(define-map lender-states principal {
  balance-tokens: uint,
  multiplier-snapshot: uint,
  state-transition-time: uint,
  status: (string-ascii 20)
})

(define-map borrower-states principal {
  debt-tokens: uint,
  multiplier-snapshot: uint,
  state-transition-time: uint,
  status: (string-ascii 20)
})

(define-map collateral-states principal {
  locked-amount: uint,
  last-validation: uint,
  status: (string-ascii 20)
})

;; === STATE QUERY INTERFACE ===

(define-read-only (query-market-efficiency)
  (let ((liquid-capital (var-get market-liquidity))
        (deployed-capital (var-get active-loans)))
    (if (is-eq liquid-capital u0)
        u0
        (let ((efficiency (/ (* deployed-capital DECIMAL_PRECISION) liquid-capital)))
          (if (<= efficiency MAX_UTILIZATION)
              efficiency
              MAX_UTILIZATION)))))

(define-read-only (compute-borrowing-rate)
  (let ((efficiency (query-market-efficiency))
        (target-efficiency (var-get efficiency-target))
        (baseline (var-get baseline-rate))
        (normal-slope (var-get efficiency-slope))
        (emergency-slope (var-get stress-slope)))
    (if (<= efficiency target-efficiency)
        ;; Normal operating range
        (+ baseline (/ (* efficiency normal-slope) DECIMAL_PRECISION))
        ;; Stress range
        (+ (+ baseline normal-slope)
           (/ (* (- efficiency target-efficiency) emergency-slope)
              (- DECIMAL_PRECISION target-efficiency))))))

(define-read-only (compute-lending-rate)
  (let ((borrowing-rate (compute-borrowing-rate))
        (efficiency (query-market-efficiency))
        (protocol-fee (var-get protocol-reserve)))
    (/ (* (* borrowing-rate efficiency) (- DECIMAL_PRECISION protocol-fee))
       (* DECIMAL_PRECISION DECIMAL_PRECISION))))

(define-read-only (query-lender-position (participant principal))
  (match (map-get? lender-states participant)
    state-record
    (let ((token-balance (get balance-tokens state-record))
          (user-multiplier (get multiplier-snapshot state-record))
          (current-multiplier (var-get lending-multiplier)))
      (if (> user-multiplier u0)
          (/ (* token-balance current-multiplier) user-multiplier)
          token-balance))
    u0))

(define-read-only (query-borrower-position (participant principal))
  (match (map-get? borrower-states participant)
    state-record
    (let ((debt-balance (get debt-tokens state-record))
          (user-multiplier (get multiplier-snapshot state-record))
          (current-multiplier (var-get borrowing-multiplier)))
      (if (> user-multiplier u0)
          (/ (* debt-balance current-multiplier) user-multiplier)
          debt-balance))
    u0))

(define-read-only (query-collateral-position (participant principal))
  (match (map-get? collateral-states participant)
    state-record (get locked-amount state-record)
    u0))

(define-read-only (validate-position-health (participant principal))
  (let ((collateral-value (query-collateral-position participant))
        (debt-value (query-borrower-position participant))
        (coverage-ratio (var-get collateral-coverage)))
    (if (is-eq debt-value u0)
        true
        (>= (/ (* collateral-value coverage-ratio) DECIMAL_PRECISION) debt-value))))

;; === STATE TRANSITION MECHANICS ===

(define-private (execute-accrual-transition)
  (match (get-block-info? time (- block-height u1))
    current-timestamp
    (let ((last-checkpoint (var-get checkpoint-time)))
      (if (> current-timestamp last-checkpoint)
          (let ((time-delta (- current-timestamp last-checkpoint))
                (borrowing-rate (compute-borrowing-rate))
                (lending-rate (compute-lending-rate))
                (borrowing-accrual (/ (* borrowing-rate time-delta) TIME_UNITS_PER_YEAR))
                (lending-accrual (/ (* lending-rate time-delta) TIME_UNITS_PER_YEAR)))
            (var-set borrowing-multiplier (+ (var-get borrowing-multiplier) borrowing-accrual))
            (var-set lending-multiplier (+ (var-get lending-multiplier) lending-accrual))
            (var-set checkpoint-time current-timestamp)
            (ok true))
          (ok true)))
    (ok true)))

(define-private (validate-market-state)
  (ok (var-get market-status)))

(define-private (execute-asset-transfer (sender principal) (recipient principal) (amount uint))
  (if (is-eq sender tx-sender)
      (stx-transfer? amount sender recipient)
      (as-contract (stx-transfer? amount sender recipient))))

;; === LIQUIDITY PROVISION TRANSITIONS ===

(define-public (transition-to-lender (deposit-amount uint))
  (begin
    (asserts! (> deposit-amount u0) INVALID_STATE_CHANGE)
    (asserts! (is-ok (validate-market-state)) MARKET_SUSPENDED)
    (let ((accrual-result (execute-accrual-transition))) true)
    
    (try! (execute-asset-transfer tx-sender (as-contract tx-sender) deposit-amount))
    
    (let ((current-multiplier (var-get lending-multiplier))
          (normalized-tokens (/ (* deposit-amount DECIMAL_PRECISION) current-multiplier))
          (timestamp (default-to u0 (get-block-info? time (- block-height u1))))
          (existing-state (default-to 
                          { balance-tokens: u0, 
                            multiplier-snapshot: current-multiplier,
                            state-transition-time: timestamp,
                            status: "ACTIVE" }
                          (map-get? lender-states tx-sender))))
      
      (map-set lender-states tx-sender {
        balance-tokens: (+ (get balance-tokens existing-state) normalized-tokens),
        multiplier-snapshot: current-multiplier,
        state-transition-time: timestamp,
        status: "ACTIVE"
      })
      
      (var-set market-liquidity (+ (var-get market-liquidity) deposit-amount))
      (ok deposit-amount))))

(define-public (transition-from-lender (withdrawal-amount uint))
  (begin
    (asserts! (> withdrawal-amount u0) INVALID_STATE_CHANGE)
    (asserts! (is-ok (validate-market-state)) MARKET_SUSPENDED)
    (let ((accrual-result (execute-accrual-transition))) true)
    
    (let ((available-balance (query-lender-position tx-sender))
          (current-multiplier (var-get lending-multiplier))
          (normalized-withdrawal (/ (* withdrawal-amount DECIMAL_PRECISION) current-multiplier))
          (existing-state (unwrap! (map-get? lender-states tx-sender) INSUFFICIENT_RESOURCES)))
      
      (asserts! (>= available-balance withdrawal-amount) INSUFFICIENT_RESOURCES)
      
      (map-set lender-states tx-sender {
        balance-tokens: (- (get balance-tokens existing-state) normalized-withdrawal),
        multiplier-snapshot: current-multiplier,
        state-transition-time: (get state-transition-time existing-state),
        status: (get status existing-state)
      })
      
      (var-set market-liquidity (- (var-get market-liquidity) withdrawal-amount))
      (try! (execute-asset-transfer (as-contract tx-sender) tx-sender withdrawal-amount))
      (ok withdrawal-amount))))

;; === COLLATERAL MANAGEMENT TRANSITIONS ===

(define-public (transition-to-secured (collateral-amount uint))
  (begin
    (asserts! (> collateral-amount u0) INVALID_STATE_CHANGE)
    (try! (execute-asset-transfer tx-sender (as-contract tx-sender) collateral-amount))
    
    (let ((timestamp (default-to u0 (get-block-info? time (- block-height u1))))
          (existing-collateral (query-collateral-position tx-sender)))
      
      (map-set collateral-states tx-sender {
        locked-amount: (+ existing-collateral collateral-amount),
        last-validation: timestamp,
        status: "SECURED"
      })
      (ok collateral-amount))))

(define-public (transition-from-secured (release-amount uint))
  (begin
    (asserts! (> release-amount u0) INVALID_STATE_CHANGE)
    (let ((accrual-result (execute-accrual-transition))) true)
    
    (let ((available-collateral (query-collateral-position tx-sender))
          (outstanding-debt (query-borrower-position tx-sender))
          (remaining-collateral (- available-collateral release-amount))
          (coverage-requirement (var-get collateral-coverage))
          (timestamp (default-to u0 (get-block-info? time (- block-height u1)))))
      
      (asserts! (>= available-collateral release-amount) INSUFFICIENT_RESOURCES)
      
      ;; Validate health after transition
      (if (> outstanding-debt u0)
          (asserts! (>= (/ (* remaining-collateral coverage-requirement) DECIMAL_PRECISION) 
                       outstanding-debt) COLLATERAL_VIOLATION)
          true)
      
      (map-set collateral-states tx-sender {
        locked-amount: remaining-collateral,
        last-validation: timestamp,
        status: "SECURED"
      })
      
      (try! (execute-asset-transfer (as-contract tx-sender) tx-sender release-amount))
      (ok release-amount))))

;; === BORROWING TRANSITIONS ===

(define-public (transition-to-borrower (loan-amount uint))
  (begin
    (asserts! (> loan-amount u0) INVALID_STATE_CHANGE)
    (asserts! (is-ok (validate-market-state)) MARKET_SUSPENDED)
    (let ((accrual-result (execute-accrual-transition))) true)
    
    (let ((collateral-value (query-collateral-position tx-sender))
          (existing-debt (query-borrower-position tx-sender))
          (coverage-requirement (var-get collateral-coverage))
          (max-borrowing-capacity (/ (* collateral-value coverage-requirement) DECIMAL_PRECISION))
          (projected-debt (+ existing-debt loan-amount))
          (current-multiplier (var-get borrowing-multiplier))
          (normalized-loan (/ (* loan-amount DECIMAL_PRECISION) current-multiplier))
          (timestamp (default-to u0 (get-block-info? time (- block-height u1))))
          (existing-state (default-to 
                          { debt-tokens: u0,
                            multiplier-snapshot: current-multiplier,
                            state-transition-time: timestamp,
                            status: "ACTIVE" }
                          (map-get? borrower-states tx-sender))))
      
      (asserts! (>= max-borrowing-capacity projected-debt) COLLATERAL_VIOLATION)
      (asserts! (>= (var-get market-liquidity) loan-amount) INSUFFICIENT_RESOURCES)
      
      (map-set borrower-states tx-sender {
        debt-tokens: (+ (get debt-tokens existing-state) normalized-loan),
        multiplier-snapshot: current-multiplier,
        state-transition-time: timestamp,
        status: "ACTIVE"
      })
      
      (var-set active-loans (+ (var-get active-loans) loan-amount))
      (var-set market-liquidity (- (var-get market-liquidity) loan-amount))
      
      (try! (execute-asset-transfer (as-contract tx-sender) tx-sender loan-amount))
      (ok loan-amount))))

(define-public (transition-from-borrower (repayment-amount uint))
  (begin
    (asserts! (> repayment-amount u0) INVALID_STATE_CHANGE)
    (let ((accrual-result (execute-accrual-transition))) true)
    
    (let ((outstanding-debt (query-borrower-position tx-sender))
          (effective-repayment (if (> repayment-amount outstanding-debt) outstanding-debt repayment-amount))
          (current-multiplier (var-get borrowing-multiplier))
          (normalized-repayment (/ (* effective-repayment DECIMAL_PRECISION) current-multiplier))
          (existing-state (unwrap! (map-get? borrower-states tx-sender) BORROWER_UNKNOWN)))
      
      (asserts! (> outstanding-debt u0) BORROWER_UNKNOWN)
      (try! (execute-asset-transfer tx-sender (as-contract tx-sender) effective-repayment))
      
      (map-set borrower-states tx-sender {
        debt-tokens: (- (get debt-tokens existing-state) normalized-repayment),
        multiplier-snapshot: current-multiplier,
        state-transition-time: (get state-transition-time existing-state),
        status: (get status existing-state)
      })
      
      (var-set active-loans (- (var-get active-loans) effective-repayment))
      (var-set market-liquidity (+ (var-get market-liquidity) effective-repayment))
      (ok effective-repayment))))

;; === LIQUIDATION TRANSITIONS ===

(define-public (execute-liquidation-transition (target-borrower principal) (coverage-amount uint))
  (begin
    (asserts! (> coverage-amount u0) INVALID_STATE_CHANGE)
    (asserts! (not (validate-position-health target-borrower)) POSITION_HEALTHY)
    (let ((accrual-result (execute-accrual-transition))) true)
    
    (let ((target-debt (query-borrower-position target-borrower))
          (target-collateral (query-collateral-position target-borrower))
          (premium-rate (var-get liquidation-premium))
          (effective-coverage (if (> coverage-amount target-debt) target-debt coverage-amount))
          (collateral-seizure (+ effective-coverage 
                               (/ (* effective-coverage premium-rate) DECIMAL_PRECISION))))
      
      (asserts! (<= collateral-seizure target-collateral) INSUFFICIENT_RESOURCES)
      (try! (execute-asset-transfer tx-sender (as-contract tx-sender) effective-coverage))
      
      ;; Transition borrower state
      (let ((current-multiplier (var-get borrowing-multiplier))
            (normalized-coverage (/ (* effective-coverage DECIMAL_PRECISION) current-multiplier))
            (existing-debt-state (unwrap! (map-get? borrower-states target-borrower) BORROWER_UNKNOWN)))
        (map-set borrower-states target-borrower {
          debt-tokens: (- (get debt-tokens existing-debt-state) normalized-coverage),
          multiplier-snapshot: current-multiplier,
          state-transition-time: (get state-transition-time existing-debt-state),
          status: "LIQUIDATED"
        }))
      
      ;; Transition collateral state
      (let ((timestamp (default-to u0 (get-block-info? time (- block-height u1)))))
        (map-set collateral-states target-borrower {
          locked-amount: (- target-collateral collateral-seizure),
          last-validation: timestamp,
          status: "LIQUIDATED"
        }))
      
      ;; Transfer seized collateral
      (try! (execute-asset-transfer (as-contract tx-sender) tx-sender collateral-seizure))
      
      ;; Update market state
      (var-set active-loans (- (var-get active-loans) effective-coverage))
      (var-set market-liquidity (+ (var-get market-liquidity) effective-coverage))
      (ok collateral-seizure))))

;; === ADMINISTRATIVE TRANSITIONS ===

(define-public (transition-rate-model (new-baseline uint) (new-efficiency uint) (new-stress uint) (new-target uint))
  (begin
    (asserts! (is-eq tx-sender SYSTEM_AUTHORITY) UNAUTHORIZED_TRANSITION)
    (var-set baseline-rate new-baseline)
    (var-set efficiency-slope new-efficiency)
    (var-set stress-slope new-stress)
    (var-set efficiency-target new-target)
    (ok true)))

(define-public (transition-security-model (new-coverage uint) (new-premium uint) (new-reserve uint))
  (begin
    (asserts! (is-eq tx-sender SYSTEM_AUTHORITY) UNAUTHORIZED_TRANSITION)
    (var-set collateral-coverage new-coverage)
    (var-set liquidation-premium new-premium)
    (var-set protocol-reserve new-reserve)
    (ok true)))

(define-public (initialize-system-state)
  (begin
    (asserts! (is-eq tx-sender SYSTEM_AUTHORITY) UNAUTHORIZED_TRANSITION)
    (match (get-block-info? time (- block-height u1))
      timestamp (var-set checkpoint-time timestamp)
      false)
    (ok true)))