# StateLend

A state machine-driven lending protocol built on Stacks that provides secure, efficient lending and borrowing with explicit state transitions and validation gates.

## Overview

StateLend implements a sophisticated DeFi lending protocol using state machine principles to ensure safe and predictable transitions between different user states (lender, borrower, secured participant). The protocol features dynamic interest rates, over-collateralized loans, and automatic liquidation mechanisms.

## Key Features

### 🔄 State Machine Architecture
- **Explicit State Transitions**: All user interactions are modeled as state transitions with validation gates
- **Position Health Monitoring**: Continuous monitoring of collateralization ratios
- **Atomic Operations**: State changes are atomic and validated before execution

### 💰 Dynamic Interest Rate Model
- **Utilization-Based Rates**: Interest rates adjust based on market utilization
- **Two-Tier Rate Structure**: Normal and stress rate curves for optimal capital efficiency
- **Real-Time Accrual**: Interest accrues continuously based on block timestamps

### 🛡️ Security & Risk Management
- **Over-Collateralization**: Configurable collateral requirements (default 75% LTV)
- **Liquidation System**: Automated liquidation with incentive premiums
- **Position Validation**: Health checks prevent unsafe state transitions

### 📊 Market Mechanics
- **Liquidity Pools**: Depositors provide liquidity and earn yield
- **Borrowing Against Collateral**: Users can borrow against locked STX collateral
- **Protocol Reserves**: Automated reserve accumulation for protocol sustainability

## Contract Architecture

### State Variables
- **Market State**: Liquidity, active loans, multipliers, and status
- **Rate Model**: Baseline rates, slopes, and utilization targets  
- **Security Model**: Collateral ratios, liquidation parameters

### User State Maps
- **Lender States**: Token balances, multiplier snapshots, transition history
- **Borrower States**: Debt positions, accrual tracking, status
- **Collateral States**: Locked amounts, validation timestamps

### Core Functions

#### Liquidity Provision
```clarity
(transition-to-lender amount)     ;; Deposit STX to earn yield
(transition-from-lender amount)   ;; Withdraw deposited STX plus accrued interest
```

#### Collateral Management  
```clarity
(transition-to-secured amount)    ;; Lock STX as collateral
(transition-from-secured amount)  ;; Release collateral (health checks apply)
```

#### Borrowing Operations
```clarity
(transition-to-borrower amount)   ;; Borrow against collateral
(transition-from-borrower amount) ;; Repay borrowed amount plus interest
```

#### Liquidation System
```clarity
(execute-liquidation-transition target coverage) ;; Liquidate unhealthy positions
```

## Interest Rate Model

StateLend uses a dual-slope interest rate model:

- **Baseline Rate**: 2% minimum APR
- **Normal Slope**: 10% slope up to target utilization (80%)
- **Stress Slope**: 60% slope beyond target utilization
- **Maximum Utilization**: 100% hard cap

### Rate Calculation
```
if utilization ≤ target:
  rate = baseline + (utilization × normal_slope)
else:
  rate = baseline + normal_slope + ((utilization - target) × stress_slope / (1 - target))
```

## Security Model

### Collateralization
- **Loan-to-Value**: 75% maximum (configurable)
- **Health Factor**: Continuous monitoring of collateral/debt ratios
- **Liquidation Threshold**: Positions become liquidatable when under-collateralized

### Liquidation Mechanics
- **Liquidation Premium**: 10% bonus for liquidators
- **Partial Liquidations**: Liquidators can cover any portion of unhealthy debt
- **Collateral Seizure**: Liquidators receive debt coverage + premium in collateral

## Usage Examples

### Becoming a Lender
```clarity
;; Deposit 1000 STX to earn yield
(contract-call? .statelend transition-to-lender u1000000000)

;; Check current position
(contract-call? .statelend query-lender-position tx-sender)

;; Withdraw 500 STX plus accrued interest  
(contract-call? .statelend transition-from-lender u500000000)
```

### Borrowing Against Collateral
```clarity
;; Lock 1000 STX as collateral
(contract-call? .statelend transition-to-secured u1000000000)

;; Borrow 750 STX (75% LTV)
(contract-call? .statelend transition-to-borrower u750000000)

;; Check position health
(contract-call? .statelend validate-position-health tx-sender)

;; Repay loan
(contract-call? .statelend transition-from-borrower u750000000)
```

### Liquidating Positions
```clarity
;; Check if position is liquidatable
(contract-call? .statelend validate-position-health 'SP123...)

;; Execute liquidation
(contract-call? .statelend execute-liquidation-transition 'SP123... u500000000)
```

## Query Interface

### Market Information
- `query-market-efficiency`: Current utilization rate
- `compute-borrowing-rate`: Current borrowing APR
- `compute-lending-rate`: Current lending APR

### Position Information  
- `query-lender-position`: User's lending balance with accrued interest
- `query-borrower-position`: User's debt balance with accrued interest
- `query-collateral-position`: User's locked collateral amount
- `validate-position-health`: Check if position is healthy

## Configuration

### Rate Model Parameters
```clarity
baseline-rate: 20000      ;; 2% APR (in basis points × 100)
efficiency-slope: 100000  ;; 10% slope
stress-slope: 600000      ;; 60% stress slope  
efficiency-target: 800000 ;; 80% target utilization
```

### Security Parameters
```clarity
collateral-coverage: 750000   ;; 75% LTV
liquidation-premium: 100000   ;; 10% liquidation bonus
protocol-reserve: 100000      ;; 10% protocol fee
```

## Administrative Functions

Only the system authority can modify protocol parameters:

- `transition-rate-model`: Update interest rate parameters
- `transition-security-model`: Update collateral and liquidation parameters  
- `initialize-system-state`: Initialize the protocol state

## Error Codes

- `301`: Unauthorized transition
- `302`: Invalid state change
- `303`: Insufficient resources
- `304`: Collateral violation
- `305`: Market suspended
- `306`: Position healthy (cannot liquidate)
- `307`: Borrower unknown
- `308`: Transition blocked

## Contributing

Contributions are welcome! Please read the contributing guidelines and submit pull requests for any improvements.

## Security

This protocol handles user funds and should undergo thorough security audits before mainnet deployment. Please report any security issues responsibly.
