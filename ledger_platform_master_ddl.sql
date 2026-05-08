-- ============================================================
-- Financial Ledger Platform
-- Master DDL Script
-- Database: PostgreSQL 14+
-- 
-- Execution Order:
--   1. Tables (in dependency order)
--   2. Triggers and Functions
--   3. Views
--   4. Seed Data
--
-- Design Decisions:
--   - Double-entry ledger: every transaction produces
--     balanced debit/credit ledger lines
--   - All transfers route through a suspense account
--     to model real-world settlement behavior
--   - Merchant (M-prefix) and agent accounts in PaySim
--     are mapped to EXTERNAL account type
--   - CASH_OUT destinations are modeled as EXTERNAL
--     with nameDest preserved in reference_id
--   - Overdraft transactions are flagged rather than
--     rejected to support reconciliation reporting
--   - Deferrable balance constraints not available in
--     PostgreSQL without explicit DEFERRABLE syntax;
--     ledger balance enforced at procedure layer
--   - paysim_raw staging table preserves source data
--     without transformation as ETL audit trail
-- ============================================================


-- ============================================================
-- SECTION 1: TABLES
-- ============================================================

-- ------------------------------------------------------------
-- 1. CURRENCY
-- Reference table. Populated before all other tables.
-- currency_code is a surrogate integer key, not ISO code.
-- ISO code stored separately in iso_code column.
-- ------------------------------------------------------------
CREATE TABLE currency (
    currency_code   SERIAL          PRIMARY KEY,
    currency_name   TEXT            NOT NULL,
    iso_code        TEXT            NOT NULL DEFAULT 'USD',
    is_active       BOOLEAN         NOT NULL DEFAULT TRUE
);


-- ------------------------------------------------------------
-- 2. ACCOUNTS
-- Holds all account types: customer, system, and external.
-- System accounts are protected from deletion via trigger.
-- account_name must be unique — enforces no duplicate
-- accounts across customer and system account populations.
-- BROKERAGE type retained for future use.
-- ------------------------------------------------------------
CREATE TABLE accounts (
    account_id          SERIAL      PRIMARY KEY,
    account_name        TEXT        NOT NULL,
    account_type        TEXT        NOT NULL,
    currency_code       INT         NOT NULL REFERENCES currency(currency_code),
    is_system_account   BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at          TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT account_name_unique UNIQUE (account_name),

    CONSTRAINT account_type_check CHECK (account_type IN (
        'BANK',
        'BROKERAGE',
        'SUSPENSE',
        'FEE_REVENUE',
        'EXTERNAL'
    ))
);


-- ------------------------------------------------------------
-- 3. JOURNAL ENTRIES
-- Parent record for every transaction. One entry per event.
-- Derives from paysim_raw (one-to-one relationship).
-- Status lifecycle: PENDING → POSTED | FLAGGED | REVERSED
-- FLAGGED: transaction anomaly detected (e.g. overdraft)
-- paysim_raw_id links back to source row for auditability.
-- ------------------------------------------------------------
CREATE TABLE journal_entries (
    journal_entry_id    SERIAL          PRIMARY KEY,
    transaction_id      TEXT            UNIQUE,
    reference_id        TEXT,
    trans_type          TEXT,
    amount              NUMERIC(18,2),
    paysim_raw_id       INT,
    entry_timestamp     TIMESTAMP       NOT NULL,
    status              TEXT            NOT NULL DEFAULT 'PENDING',
    description         TEXT,
    source_system       TEXT,
    anomaly_flag        TEXT,
    created_at          TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT status_check CHECK (status IN (
        'PENDING',
        'POSTED',
        'REVERSED',
        'FLAGGED'
    ))
);


-- ------------------------------------------------------------
-- 4. LEDGER LINES
-- Individual debit/credit rows. Child of journal_entries.
-- Derives from journal_entries (one-to-many relationship).
-- Every journal entry must produce balanced lines:
--   SUM(amount WHERE entry_type='DEBIT')
--   = SUM(amount WHERE entry_type='CREDIT')
-- Balance enforced at procedure layer (not constraint layer)
-- due to multi-row nature of double-entry accounting.
-- ------------------------------------------------------------
CREATE TABLE ledger_lines (
    ledger_line_id      SERIAL          PRIMARY KEY,
    journal_entry_id    INT             NOT NULL REFERENCES journal_entries(journal_entry_id),
    account_id          INT             NOT NULL REFERENCES accounts(account_id),
    currency_code       INT             NOT NULL REFERENCES currency(currency_code),
    entry_type          TEXT            NOT NULL,
    amount              NUMERIC(18,2)   NOT NULL,
    entry_sequence      INT,
    created_at          TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT entry_type_check CHECK (entry_type IN ('DEBIT', 'CREDIT')),
    CONSTRAINT amount_check     CHECK (amount >= 0)
);


-- ------------------------------------------------------------
-- 5. PAYSIM RAW
-- Staging table. Receives PaySim CSV data as-is.
-- Never modified after load except is_processed flag.
-- Serves as immutable audit trail back to source data.
-- paysim_raw_id is a pipeline key, not a business key.
-- trans_type renamed from 'type' to avoid reserved word.
-- anomaly_flag records why a row was flagged pre-load.
-- ------------------------------------------------------------
CREATE TABLE paysim_raw (
    paysim_raw_id       SERIAL          PRIMARY KEY,
    step                INT,
    trans_type          TEXT,
    amount              NUMERIC(18,2),
    nameOrig            TEXT,
    oldbalanceOrg       NUMERIC(18,2),
    newbalanceOrig      NUMERIC(18,2),
    nameDest            TEXT,
    oldbalanceDest      NUMERIC(18,2),
    newbalanceDest      NUMERIC(18,2),
    isFraud             BOOLEAN,
    isFlaggedFraud      BOOLEAN,
    anomaly_flag        TEXT,
    loaded_at           TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,
    is_processed        BOOLEAN         NOT NULL DEFAULT FALSE
);


-- ------------------------------------------------------------
-- 6. ETL LOG
-- Run-level audit trail for all ETL procedures.
-- One row per procedure execution.
-- Status: SUCCESS | FAILURE | PARTIAL
-- ------------------------------------------------------------
CREATE TABLE etl_log (
    etl_log_id          SERIAL      PRIMARY KEY,
    run_timestamp       TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
    process_name        TEXT        NOT NULL,
    status              TEXT        NOT NULL,
    rows_processed      INT,
    message             TEXT,

    CONSTRAINT etl_status_check CHECK (status IN (
        'SUCCESS',
        'FAILURE',
        'PARTIAL'
    ))
);


-- ------------------------------------------------------------
-- 7. ETL LOG DETAIL
-- Transaction-type breakdown per ETL run.
-- Child of etl_log (one-to-many).
-- Timestamp derived via JOIN to etl_log — not duplicated
-- here to preserve normalization.
-- ------------------------------------------------------------
CREATE TABLE etl_log_detail (
    etl_log_detail_id   SERIAL      PRIMARY KEY,
    etl_log_id          INT         NOT NULL REFERENCES etl_log(etl_log_id),
    trans_type          TEXT,
    rows_processed      INT
);


-- ============================================================
-- SECTION 2: FUNCTIONS AND TRIGGERS
-- ============================================================

-- ------------------------------------------------------------
-- Trigger Function: protect_system_accounts
-- Prevents deletion of system accounts.
-- Raises exception if DELETE attempted on any account
-- where is_system_account = TRUE.
-- Function-based approach chosen over inline trigger logic
-- for reusability and independent testability.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION protect_system_accounts()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.is_system_account = TRUE THEN
        RAISE EXCEPTION 'System accounts cannot be deleted: %', OLD.account_name;
    END IF;
    RETURN OLD;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER prevent_system_account_deletion
BEFORE DELETE ON accounts
FOR EACH ROW
EXECUTE FUNCTION protect_system_accounts();


-- ============================================================
-- SECTION 3: VIEWS
-- ============================================================

-- ------------------------------------------------------------
-- View: etl_run_summary
-- Joins etl_log and etl_log_detail for admin reporting.
-- Single query surface for run history, row counts,
-- per-type breakdowns, and error messages.
-- Normalized alternative to duplicating run_timestamp
-- in etl_log_detail.
-- ------------------------------------------------------------
CREATE VIEW etl_run_summary AS
SELECT
    el.etl_log_id,
    el.run_timestamp,
    el.process_name,
    el.status,
    el.rows_processed,
    el.message,
    eld.trans_type,
    eld.rows_processed      AS rows_by_type
FROM etl_log el
JOIN etl_log_detail eld ON eld.etl_log_id = el.etl_log_id
ORDER BY el.run_timestamp DESC;


-- ============================================================
-- SECTION 4: STORED PROCEDURES
-- ============================================================

-- ------------------------------------------------------------
-- Procedure: load_journal_entries
-- ETL procedure: paysim_raw → journal_entries
-- Relationship: one paysim_raw row → one journal_entries row
-- Anomaly detection: flags overdraft transactions
--   (amount > oldbalanceOrg) with status = 'FLAGGED'
-- Audit: writes run summary and per-type counts to etl_log
-- Pipeline: marks paysim_raw rows as is_processed = TRUE
--   only after successful journal_entries insert
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE load_journal_entries()
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows_total        INT := 0;
    v_rows_by_type      RECORD;
    v_log_id            INT;
    v_error_message     TEXT;
BEGIN
    -- Create log entry for this run
    INSERT INTO etl_log (process_name, status, message)
    VALUES ('load_journal_entries', 'PARTIAL', 'Run started')
    RETURNING etl_log_id INTO v_log_id;

    -- Main INSERT: paysim_raw → journal_entries
    WITH raw_transactions AS (
        SELECT
            paysim_raw_id,
            trans_type,
            amount,
            loaded_at,
            nameOrig,
            oldbalanceOrg,
            is_processed
        FROM paysim_raw
        WHERE is_processed = FALSE
    )
    INSERT INTO journal_entries (
        transaction_id,
        trans_type,
        amount,
        paysim_raw_id,
        entry_timestamp,
        status,
        description,
        anomaly_flag
    )
    SELECT
        rt.paysim_raw_id::text,
        rt.trans_type,
        rt.amount,
        rt.paysim_raw_id,
        rt.loaded_at,
        CASE
            WHEN rt.amount > rt.oldbalanceOrg
            AND rt.trans_type IN ('TRANSFER', 'CASH_OUT', 'DEBIT')
            THEN 'FLAGGED'
            ELSE 'PENDING'
        END,
        rt.trans_type || ' from ' || rt.nameOrig,
        CASE
            WHEN rt.amount > rt.oldbalanceOrg
            AND rt.trans_type IN ('TRANSFER', 'CASH_OUT', 'DEBIT')
            THEN 'OVERDRAFT: amount exceeds opening balance'
            ELSE NULL
        END
    FROM raw_transactions AS rt;

    -- Capture total rows inserted
    GET DIAGNOSTICS v_rows_total = ROW_COUNT;

    -- Log breakdown by trans_type before flipping is_processed
    FOR v_rows_by_type IN
        SELECT trans_type, COUNT(*) AS row_count
        FROM journal_entries
        WHERE paysim_raw_id IN (
            SELECT paysim_raw_id
            FROM paysim_raw
            WHERE is_processed = FALSE
        )
        GROUP BY trans_type
    LOOP
        INSERT INTO etl_log_detail (etl_log_id, trans_type, rows_processed)
        VALUES (v_log_id, v_rows_by_type.trans_type, v_rows_by_type.row_count);
    END LOOP;

    -- Mark source rows as processed
    UPDATE paysim_raw
    SET is_processed = TRUE
    WHERE is_processed = FALSE;

    -- Update log entry to SUCCESS
    UPDATE etl_log
    SET
        status          = 'SUCCESS',
        rows_processed  = v_rows_total,
        message         = 'Completed successfully. ' || v_rows_total || ' rows processed.'
    WHERE etl_log_id = v_log_id;

EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error_message = MESSAGE_TEXT;

    UPDATE etl_log
    SET
        status  = 'FAILURE',
        message = 'Error: ' || v_error_message
    WHERE etl_log_id = v_log_id;

    RAISE;
END;
$$;


-- ============================================================
-- SECTION 5: SEED DATA
-- Execute in order. Currency must exist before accounts.
-- ============================================================

-- ------------------------------------------------------------
-- Seed: Currency
-- ------------------------------------------------------------
INSERT INTO currency (currency_name, iso_code, is_active)
VALUES ('US Dollar', 'USD', TRUE);


-- ------------------------------------------------------------
-- Seed: System Accounts
-- Four platform accounts required before any transaction
-- can be processed through the ledger pipeline.
--
-- Main Settlement Suspense:
--   Holds funds in transit during transfer settlement.
--   Should net to zero after each completed transaction.
--   Non-zero balance indicates reconciliation break.
--
-- Failed Settlement Suspense:
--   Holds funds from failed or error-state transactions
--   pending investigation and resolution.
--
-- Platform Fee Revenue:
--   Platform-owned income account. Receives fee credits
--   on applicable transaction types.
--
-- External Counterparty:
--   Represents merchants (M-prefix) and cash agents
--   whose balances are not tracked in this system.
-- ------------------------------------------------------------
INSERT INTO accounts (account_name, account_type, currency_code, is_system_account)
VALUES
    ('Main Settlement Suspense',   'SUSPENSE',    (SELECT currency_code FROM currency WHERE iso_code = 'USD'), TRUE),
    ('Failed Settlement Suspense', 'SUSPENSE',    (SELECT currency_code FROM currency WHERE iso_code = 'USD'), TRUE),
    ('Platform Fee Revenue',       'FEE_REVENUE', (SELECT currency_code FROM currency WHERE iso_code = 'USD'), TRUE),
    ('External Counterparty',      'EXTERNAL',    (SELECT currency_code FROM currency WHERE iso_code = 'USD'), TRUE);


-- ------------------------------------------------------------
-- Seed: Customer and Merchant Accounts from PaySim
-- Run after paysim_raw is loaded.
-- UNION deduplicates accounts appearing as both
-- sender and receiver across transactions.
-- C-prefix → BANK account type
-- M-prefix → EXTERNAL account type
-- ON CONFLICT DO NOTHING protects system accounts
-- and prevents duplicate inserts on reruns.
-- ------------------------------------------------------------
INSERT INTO accounts (account_name, account_type, currency_code)
SELECT DISTINCT
    nameOrig,
    CASE
        WHEN nameOrig LIKE 'C%' THEN 'BANK'
        WHEN nameOrig LIKE 'M%' THEN 'EXTERNAL'
    END,
    (SELECT currency_code FROM currency WHERE iso_code = 'USD')
FROM paysim_raw

UNION

SELECT DISTINCT
    nameDest,
    CASE
        WHEN nameDest LIKE 'C%' THEN 'BANK'
        WHEN nameDest LIKE 'M%' THEN 'EXTERNAL'
    END,
    (SELECT currency_code FROM currency WHERE iso_code = 'USD')
FROM paysim_raw

ON CONFLICT (account_name) DO NOTHING;
