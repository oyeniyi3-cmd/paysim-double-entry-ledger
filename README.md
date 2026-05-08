# Financial Ledger Platform

A double-entry financial ledger system built on PostgreSQL, demonstrating SQL design, ETL pipeline architecture, data governance, and financial systems thinking. Built using the [PaySim synthetic financial dataset](https://www.kaggle.com/datasets/ealaxi/paysim1).

---

## Project Overview

This project simulates a fintech payments platform — modeling the full lifecycle of financial transactions from raw ingestion through double-entry ledger accounting, reconciliation, and analytics reporting.

It was designed to demonstrate two things:

- **Technical depth** — schema design, stored procedures, triggers, CTEs, window functions, indexing strategy, and query optimization
- **Business thinking** — payment rail modeling, settlement patterns, fee engines, anomaly detection, and reconciliation logic

---

## Architecture

The platform is organized in four layers, each deriving from the one above it:

```
┌─────────────────────────────────────────────────────┐
│ Layer 1: Ingestion                                  │
│ paysim_raw — raw CSV data, append-only audit trail  │
└────────────────────────┬────────────────────────────┘
                         │ one-to-one
┌────────────────────────▼────────────────────────────┐
│ Layer 2: Ledger                                     │
│ journal_entries — transaction lifecycle             │
│ ledger_lines    — double-entry debit/credit rows    │
└────────────────────────┬────────────────────────────┘
                         │ one-to-many
┌────────────────────────▼────────────────────────────┐
│ Layer 3: Reference                                  │
│ accounts, currency, fee_schedule                    │
└────────────────────────┬────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────┐
│ Layer 4: Reporting                                  │
│ Views, functions, reconciliation queries            │
└─────────────────────────────────────────────────────┘
```

---

## Schema

### Core Tables

| Table | Purpose | Rows (approx.) |
|---|---|---|
| `paysim_raw` | Raw PaySim CSV staging table | 6.3M |
| `journal_entries` | Parent transaction record, one per event | 6.3M |
| `ledger_lines` | Individual debit/credit rows | 25M+ |
| `accounts` | All account types: customer, system, external | 9M+ |
| `currency` | Currency reference table | 1 |
| `fee_schedule` | Configurable fee rules by transaction type | 3 |

### Audit Tables

| Table | Purpose |
|---|---|
| `etl_log` | Run-level ETL audit trail |
| `etl_log_detail` | Per-transaction-type row counts per run |

### Account Types

| Type | Description |
|---|---|
| `BANK` | Customer bank/checking accounts |
| `BROKERAGE` | Customer trading accounts (future use) |
| `SUSPENSE` | Settlement holding accounts |
| `FEE_REVENUE` | Platform income account |
| `EXTERNAL` | Merchants, agents, outside institutions |

### System Accounts (Seed Data)

Four platform accounts are pre-seeded and protected from deletion via database trigger:

| Account | Type | Purpose |
|---|---|---|
| Main Settlement Suspense | SUSPENSE | Holds funds in transit during settlement |
| Failed Settlement Suspense | SUSPENSE | Holds funds from failed transactions |
| Platform Fee Revenue | FEE_REVENUE | Accumulates platform fee income |
| External Counterparty | EXTERNAL | Represents merchants and cash agents |

---

## Double-Entry Ledger Model

Every transaction produces multiple balanced ledger lines. Total debits must equal total credits for every journal entry.

### TRANSFER — 6 lines (fee applied)

```
Line 1: DEBIT   Customer (sender)            $amount + fee
Line 2: CREDIT  Main Settlement Suspense     $amount + fee
Line 3: DEBIT   Main Settlement Suspense     $amount
Line 4: CREDIT  Customer (receiver)          $amount
Line 5: DEBIT   Main Settlement Suspense     $fee
Line 6: CREDIT  Platform Fee Revenue         $fee
```

### CASH_OUT — 6 lines (fee applied)

```
Line 1: DEBIT   Customer (sender)            $amount + fee
Line 2: CREDIT  Main Settlement Suspense     $amount + fee
Line 3: DEBIT   Main Settlement Suspense     $amount
Line 4: CREDIT  External Counterparty        $amount
Line 5: DEBIT   Main Settlement Suspense     $fee
Line 6: CREDIT  Platform Fee Revenue         $fee
```

### PAYMENT — 4 lines (no fee)

```
Line 1: DEBIT   Customer (sender)            $amount
Line 2: CREDIT  Main Settlement Suspense     $amount
Line 3: DEBIT   Main Settlement Suspense     $amount
Line 4: CREDIT  External Counterparty        $amount
```

### CASH_IN — 4 lines (no fee)

```
Line 1: DEBIT   External Counterparty        $amount
Line 2: CREDIT  Main Settlement Suspense     $amount
Line 3: DEBIT   Main Settlement Suspense     $amount
Line 4: CREDIT  Customer (receiver)          $amount
```

### DEBIT — 4 lines (no fee)

```
Line 1: DEBIT   Customer (sender)            $amount
Line 2: CREDIT  Main Settlement Suspense     $amount
Line 3: DEBIT   Main Settlement Suspense     $amount
Line 4: CREDIT  Customer (receiver)          $amount
```

The suspense account nets to zero on every completed transaction. A non-zero suspense balance indicates a reconciliation break.

---

## ETL Pipeline

Three-stage pipeline with full audit logging:

```
Stage 1: Extract
  CSV → paysim_raw (pgAdmin import)

Stage 2: Transform + Load (journal)
  CALL load_journal_entries();
  paysim_raw → journal_entries
  Anomaly detection: overdraft flagging

Stage 3: Transform + Load (ledger)
  CALL load_ledger_lines();
  paysim_raw + journal_entries → ledger_lines
  Fee calculation, account resolution, status update
```

All runs are logged to `etl_log` with row counts, per-type breakdowns, and success/failure status. Failed runs preserve the error message for diagnosis.

---

## Design Decisions

### Why PostgreSQL over MySQL?
MySQL does not support deferrable constraints, which are required to enforce ledger balance across multi-row transactions at the database level. PostgreSQL's constraint model is more appropriate for financial system integrity.

### Why route all transfers through a suspense account?
Real payment rails (ACH, wire transfer) do not move funds instantaneously. The suspense account models the settlement window — the period between a transaction being initiated and funds being confirmed. A suspense balance that does not clear to zero indicates a reconciliation break, which is the foundation of the reconciliation query layer.

### Why is fee revenue not stored in a separate table?
Fee revenue is captured in `ledger_lines` as CREDIT entries to the `Platform Fee Revenue` account. Duplicating this data in a separate table would violate normalization principles. The `get_fee_revenue()` function derives fee reporting from the ledger directly.

### Why are merchant accounts modeled as EXTERNAL?
PaySim never tracks merchant balances — all merchant `oldbalanceDest` and `newbalanceDest` values are zero. Merchants (M-prefix accounts) are therefore modeled as external counterparties whose internal balances are not managed by this platform. This reflects real-world payment processing where the platform does not hold merchant funds.

### Why flag overdrafts rather than reject them?
Rejecting overdraft transactions at load time would discard data that is valuable for reconciliation and fraud analysis. Flagging preserves the data while preventing it from flowing through the ledger unchecked. Flagged transactions require manual review before being posted or reversed.

### Why use a `fee_schedule` table rather than hardcoded rates?
Hardcoding fee rates inside stored procedures means a rate change requires code modification and redeployment. A `fee_schedule` table externalizes this business rule — rate changes are a data update, not a code change. This is standard practice in production payment systems.

---

## Data Governance

### System Account Protection
System accounts cannot be deleted. A database trigger raises an exception on any DELETE attempt against accounts where `is_system_account = TRUE`. This is enforced at the database level independent of application logic.

### ETL Audit Trail
Every ETL run is logged to `etl_log` with:
- Run timestamp
- Process name
- Status (SUCCESS / FAILURE / PARTIAL)
- Row count
- Error message (on failure)
- Per-transaction-type breakdown via `etl_log_detail`

### Idempotent Pipeline
`paysim_raw.is_processed` and `journal_entries.status` ensure the pipeline is resumable. If a run fails mid-way, unprocessed rows remain available for reprocessing without duplication.

### Anomaly Detection
Overdraft conditions are detected automatically during `load_journal_entries` and flagged before ledger lines are written. Flagged transactions are excluded from the ledger pipeline until reviewed.

---

## Repository Structure

```
/sql
    /schema
        ledger_platform_master_ddl.sql   — All tables, triggers,
                                           views, seed data
    /procedures
        load_journal_entries.sql         — ETL: raw → journal
        load_ledger_lines.sql            — ETL: journal → ledger
    /functions
        get_fee_revenue.sql              — Fee revenue reporting
        verification_objects.sql         — Balance check, status views
    /inspection
        schema_inspection.sql            — Schema interrogation queries
```

---

## Setup Instructions

### Prerequisites
- PostgreSQL 14 or higher
- pgAdmin or DBeaver
- PaySim dataset from [Kaggle](https://www.kaggle.com/datasets/ealaxi/paysim1)

### Installation

**1. Create the database**
```sql
CREATE DATABASE ledger_platform;
```

**2. Run the master DDL**

Connect to `ledger_platform` and run:
```
/sql/schema/ledger_platform_master_ddl.sql
```

This creates all tables, triggers, views, and inserts seed data.

**3. Load PaySim CSV**

In pgAdmin: right-click `paysim_raw` → Import/Export Data

- Format: CSV
- Header: ON
- Delimiter: comma
- Columns: exclude `paysim_raw_id`, `loaded_at`, `is_processed`

**4. Run ETL procedures in order**
```sql
CALL load_journal_entries();
CALL load_ledger_lines();
```

**5. Verify ledger integrity**
```sql
SELECT * FROM check_ledger_balance();
```
All variance values should be zero.

---

## Verification Queries

```sql
-- Ledger balance by transaction type
SELECT * FROM check_ledger_balance();

-- Balance for a specific date range
SELECT * FROM check_ledger_balance('2024-01-01', '2024-01-31');

-- Most recent ETL run
SELECT * FROM vw_etl_log LIMIT 1;

-- Pipeline health snapshot
SELECT * FROM vw_journal_status_summary;

-- Fee revenue month to date
SELECT * FROM get_fee_revenue(
    DATE_TRUNC('month', CURRENT_DATE)::DATE,
    CURRENT_DATE
);
```

---

## Dataset

**PaySim** is a synthetic mobile money transaction dataset modeled on real financial transaction patterns. It was originally created for fraud detection research.

| Field | Description |
|---|---|
| `step` | Time unit (1 hour). 744 steps = 30 days |
| `type` | Transaction type: CASH_IN, CASH_OUT, DEBIT, PAYMENT, TRANSFER |
| `amount` | Transaction amount |
| `nameOrig` | Originating account (C-prefix = customer) |
| `nameDest` | Destination account (C-prefix = customer, M-prefix = merchant) |
| `oldbalanceOrg` | Sender opening balance |
| `newbalanceOrig` | Sender closing balance |
| `oldbalanceDest` | Receiver opening balance |
| `newbalanceDest` | Receiver closing balance |
| `isFraud` | Fraud flag |
| `isFlaggedFraud` | System fraud flag |

**Known limitations of PaySim as a ledger source:**
- Merchant balances are never tracked (always zero)
- No explicit fee column — fees are simulated via `fee_schedule`
- Some transactions show amount exceeding sender balance (modeled as overdrafts)
- CASH_OUT destinations are cash agents, not ATMs, per mobile money conventions

---

## Known Limitations and Future Enhancements

| Limitation | Notes |
|---|---|
| Single currency | Schema designed for extension. `currency_code` FK exists on all relevant tables |
| Single External Counterparty account | All merchants collapse to one account. Phase 2: individual merchant tracking |
| Row-by-row ETL loop | `load_ledger_lines` uses plpgsql loop — performant for correctness demonstration, not optimized for bulk throughput |
| No BROKERAGE transactions in dataset | Account type retained for future dataset extension |

---

## Author

**Oyeniyi Oyediran, M.S.**
Senior Technical Product Manager
MS, Data Analytics & Business Intelligence — Stevens Institute of Technology

www.linkedin.com/in/oyoy365 | https://github.com/oyeniyi3-cmdu
