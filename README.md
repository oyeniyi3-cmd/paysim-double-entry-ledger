# Financial Ledger Platform
### A Production-Grade SQL Portfolio Project

A double-entry financial ledger system built on PostgreSQL, demonstrating advanced SQL design, ETL pipeline architecture, data governance, and financial systems thinking. Built using the [PaySim synthetic financial dataset](https://www.kaggle.com/datasets/ealaxi/paysim1).

---

## Project Overview

This project simulates a real-world fintech payments platform — modeling the full lifecycle of financial transactions from raw ingestion through double-entry ledger accounting, reconciliation, and analytics reporting.

It was designed to demonstrate two things simultaneously:

- **Technical depth** — schema design, stored procedures, functions, triggers, CTEs, window functions, indexing strategy, and query optimization
- **Business thinking** — payment rail modeling, settlement patterns, fee engines, anomaly detection, duplicate detection, and reconciliation logic

---

## Architecture

The platform is organized in four layers, each deriving from the one above it:

```
┌─────────────────────────────────────────────────────┐
│  Layer 1: Ingestion                                  │
│  paysim_raw — raw CSV data, append-only audit trail  │
└────────────────────────┬────────────────────────────┘
                         │ one-to-one
┌────────────────────────▼────────────────────────────┐
│  Layer 2: Ledger                                     │
│  journal_entries — transaction lifecycle management  │
│  ledger_lines    — double-entry debit/credit rows    │
└────────────────────────┬────────────────────────────┘
                         │ one-to-many
┌────────────────────────▼────────────────────────────┐
│  Layer 3: Reference                                  │
│  accounts, currency, fee_schedule                    │
└────────────────────────┬────────────────────────────┘
                         │
┌────────────────────────▼────────────────────────────┐
│  Layer 4: Reporting & Reconciliation                 │
│  Views, functions, reconciliation queries            │
└─────────────────────────────────────────────────────┘
```

---

## Schema

### Core Tables

| Table | Purpose | Rows (approx) |
|---|---|---|
| `paysim_raw` | Raw PaySim CSV staging table | 6.3M |
| `journal_entries` | Parent transaction record, one per event | 6.3M |
| `ledger_lines` | Individual debit/credit rows | 32M (16M active) |
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
  Detects: DUPLICATE transactions, OVERDRAFT anomalies

Stage 3: Transform + Load (ledger)
  CALL load_ledger_lines();
  Fee calculation, account resolution, status update
```

All runs are logged to `etl_log` with row counts, per-type breakdowns, and success/failure status.

---

## Reconciliation Layer

Four reconciliation checks validate ledger integrity after every ETL run:

| Check | Function | Expected Result |
|---|---|---|
| Ledger balance | `check_ledger_balance()` | Zero variance all types |
| Suspense balance | `check_suspense_balance()` | BALANCED |
| Missing ledger lines | `check_missing_ledger_lines()` | Zero rows |
| Ledger integrity | `check_ledger_integrity()` | Zero rows |

Three duplicate detection checks:

| Check | Function | Expected Result |
|---|---|---|
| Source duplicates | `check_paysim_duplicates()` | Zero rows |
| Pipeline duplicates | `check_journal_duplicates()` | Zero rows |
| Line count integrity | `check_ledger_line_counts()` | Zero rows |

---

## Duplicate Detection Design

Two duplicate definitions are implemented, each catching a different class of problem:

**Exact duplicates** — same sender, receiver, amount, and time period. Catches identical rows in source data.

**Replay duplicates** — same sender, receiver, and amount across different time periods. Catches repeated transaction submissions, a common fraud pattern known as a replay attack.

When a duplicate is detected during `load_journal_entries()`:
- The row is flagged in `paysim_raw` with `anomaly_flag = 'DUPLICATE'`
- The journal entry is created with `status = 'DUPLICATE'`
- `load_ledger_lines()` filters on `status = 'PENDING'` — DUPLICATE entries are automatically excluded

This pattern is industry standard: detect, flag, skip, preserve history.

---

## Data Governance

### System Account Protection
System accounts cannot be deleted. A database trigger raises an exception on any DELETE attempt against accounts where `is_system_account = TRUE`. Enforced at the database level independent of application logic.

### ETL Audit Trail
Every ETL run is logged to `etl_log` with timestamp, process name, status, row count, and error message on failure. Per-transaction-type breakdowns are stored in `etl_log_detail`.

### Idempotent Pipeline
`paysim_raw.is_processed` and `journal_entries.status` ensure the pipeline is resumable. Failed runs can be safely rerun without duplication.

### Anomaly Detection
Overdraft conditions are detected automatically during `load_journal_entries()` and flagged before ledger lines are written. Flagged transactions are excluded from the ledger pipeline until reviewed.

### line_status Pattern
`ledger_lines.line_status` tracks row validity without deleting history:
- `ACTIVE` — valid, included in all reporting
- `EXPIRED` — duplicate run output, excluded from reporting
- `REVERSED` — cancelled transaction lines

This preserves full audit history while enabling clean active-data queries. Truncating and reloading would destroy the evidence trail needed for production incident investigation and regulatory compliance.

---

## Design Decisions

### Why PostgreSQL over MySQL?
MySQL does not support deferrable constraints, which are required to enforce ledger balance across multi-row transactions at the database level. PostgreSQL's constraint model is more appropriate for financial system integrity.

### Why route all transfers through a suspense account?
Real payment rails (ACH, wire transfer) do not move funds instantaneously. The suspense account models the settlement window. A suspense balance that does not clear to zero indicates a reconciliation break — the foundation of the reconciliation query layer.

### Why is fee revenue not stored in a separate table?
Fee revenue is captured in `ledger_lines` as CREDIT entries to the `Platform Fee Revenue` account. A separate table would violate normalization — the ledger is the system of record.

### Why are merchant accounts modeled as EXTERNAL?
PaySim never tracks merchant balances. Merchants (M-prefix) are modeled as external counterparties whose internal balances are not managed by this platform, reflecting real-world payment processing.

### Why flag overdrafts rather than reject them?
Rejecting overdraft transactions discards data valuable for reconciliation and fraud analysis. Flagging preserves the data while preventing it from flowing through the ledger unchecked.

### Why use a fee_schedule table?
Hardcoding fee rates inside stored procedures means a rate change requires code modification. A `fee_schedule` table externalizes this business rule — rate changes are data updates, not code changes. Standard practice in production payment systems.

### Why not TRUNCATE when duplicate ledger lines were discovered?
TRUNCATE destroys audit history. In production, that history has regulatory and operational value — it identifies the point of failure, provides evidence for disputes with data providers, and satisfies audit trail requirements (SOX, PCI-DSS). The `line_status = 'EXPIRED'` pattern preserves history while excluding bad data from active processing.

---

## Repository Structure

```
/sql
    /schema
        ledger_platform_master_ddl.sql
    /procedures
        load_journal_entries.sql
        load_ledger_lines.sql
    /functions
        get_fee_revenue.sql
        verification_objects.sql
    /reconciliation
        reconciliation_flagged_transactions.sql
        reconciliation_duplicates.sql
        reconciliation_missing_lines.sql
    /inspection
        schema_inspection.sql
    /reference
        quick_reference.sql
        sql_order_of_operations.sql
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

**3. Load PaySim CSV**

In pgAdmin: right-click `paysim_raw` → Import/Export Data
- Format: CSV, Header: ON, Delimiter: comma
- Exclude columns: `paysim_raw_id`, `loaded_at`, `is_processed`

**4. Run ETL procedures in order**
```sql
CALL load_journal_entries();
CALL load_ledger_lines();
```

**5. Verify ledger integrity**
```sql
SELECT * FROM check_ledger_balance();
SELECT * FROM check_suspense_balance();
SELECT * FROM check_missing_ledger_lines();
```

---

## Known Limitations and Future Enhancements

| Limitation | Notes |
|---|---|
| Single currency | Schema designed for extension. `currency_code` FK on all relevant tables |
| Single External Counterparty | All merchants collapse to one account. Phase 2: individual merchant tracking |
| Row-by-row ETL loop | `load_ledger_lines` uses plpgsql loop — correct for demonstration, not bulk-optimized |
| Duplicate expiry pending | `ledger_lines` has ~16M EXPIRED rows pending batch job. Requires cloud instance compute |
| UNIQUE constraint pending | `ledger_lines_unique` to be added after expiry batch completes |
| No BROKERAGE transactions | Account type retained for future dataset extension |

---

## Author

**Oyeniyi Oyediran, M.S.**
Senior Technical Product Manager
MS, Data Analytics & Business Intelligence — Stevens Institute of Technology

[LinkedIn](#) | [GitHub](#)
