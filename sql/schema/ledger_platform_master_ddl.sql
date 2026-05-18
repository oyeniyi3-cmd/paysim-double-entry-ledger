-- ============================================================
-- Financial Ledger Platform
-- Master DDL Script — Layer 1 Complete
-- Database: PostgreSQL 14+
--
-- Execution Order:
--   1. Tables (in dependency order)
--   2. Functions and Triggers
--   3. Views
--   4. Stored Procedures
--   5. Seed Data
--
-- Known Limitations:
--   - Deferrable balance constraints not available in
--     PostgreSQL without explicit DEFERRABLE syntax.
--     Ledger balance enforced at procedure layer.
--   - UNIQUE constraint on ledger_lines pending duplicate
--     expiry batch job (compute-constrained on local machine).
--     Add after running duplicate expiry on cloud instance.
--   - Merchant accounts (M-prefix) collapse to single
--     External Counterparty account. Phase 2 enhancement:
--     individual merchant account tracking.
--   - load_ledger_lines() uses row-by-row loop. Correct
--     for portfolio demonstration; not bulk-optimized.
--
-- Design Decisions:
--   - Double-entry ledger: every transaction produces
--     balanced debit/credit ledger lines.
--   - All transfers route through suspense account to
--     model real-world settlement behavior.
--   - Merchant (M-prefix) accounts mapped to EXTERNAL type.
--   - CASH_OUT destinations modeled as EXTERNAL with
--     nameDest preserved in journal_entries.reference_id.
--   - Overdraft transactions flagged, not rejected, to
--     preserve reconciliation and fraud analysis value.
--   - Fee rates externalized in fee_schedule table —
--     rate changes are data updates, not code changes.
--   - paysim_raw staging table preserves source data
--     without transformation as immutable audit trail.
--   - ledger_lines.line_status tracks ACTIVE/EXPIRED/REVERSED
--     without deleting data — full history preserved.
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
-- System accounts protected from deletion via trigger.
-- account_name must be unique across all account types.
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
-- 3. FEE SCHEDULE
-- Configurable fee rules by transaction type.
-- Externalizes fee logic from stored procedures.
-- Rate changes are data updates, not code changes.
-- ------------------------------------------------------------
CREATE TABLE fee_schedule (
    fee_schedule_id     SERIAL          PRIMARY KEY,
    trans_type          TEXT            NOT NULL,
    fee_type            TEXT            NOT NULL,
    fee_rate            NUMERIC(8,6),
    fee_fixed           NUMERIC(18,2),
    is_active           BOOLEAN         NOT NULL DEFAULT TRUE,
    effective_date      DATE            NOT NULL,
    created_at          TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT fee_type_check CHECK (fee_type IN (
        'PERCENTAGE',
        'FIXED',
        'HYBRID'
    ))
);


-- ------------------------------------------------------------
-- 4. JOURNAL ENTRIES
-- Parent record for every transaction. One entry per event.
-- Derives from paysim_raw (one-to-one relationship).
-- Status lifecycle: PENDING → POSTED | FLAGGED | REVERSED
--                              | DUPLICATE
-- FLAGGED:    anomaly detected (overdraft, unknown type)
-- DUPLICATE:  already processed, skip in ledger pipeline
-- REVERSED:   cancelled transaction
-- paysim_raw_id links back to source for auditability.
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
        'FLAGGED',
        'DUPLICATE'
    ))
);


-- ------------------------------------------------------------
-- 5. LEDGER LINES
-- Individual debit/credit rows. Child of journal_entries.
-- Derives from journal_entries (one-to-many relationship).
-- Every journal entry must produce balanced lines:
--   SUM(amount WHERE entry_type='DEBIT')
--   = SUM(amount WHERE entry_type='CREDIT')
-- Balance enforced at procedure layer.
-- line_status tracks validity without deleting history:
--   ACTIVE   = valid, included in all reporting
--   EXPIRED  = duplicate run output, excluded from reporting
--   REVERSED = cancelled transaction lines
-- UNIQUE constraint on (journal_entry_id, entry_sequence,
-- line_status) pending duplicate expiry batch job.
-- ------------------------------------------------------------
CREATE TABLE ledger_lines (
    ledger_line_id      SERIAL          PRIMARY KEY,
    journal_entry_id    INT             NOT NULL REFERENCES journal_entries(journal_entry_id),
    account_id          INT             NOT NULL REFERENCES accounts(account_id),
    currency_code       INT             NOT NULL REFERENCES currency(currency_code),
    entry_type          TEXT            NOT NULL,
    amount              NUMERIC(18,2)   NOT NULL,
    entry_sequence      INT,
    line_status         TEXT            NOT NULL DEFAULT 'ACTIVE',
    created_at          TIMESTAMP       NOT NULL DEFAULT CURRENT_TIMESTAMP,

    CONSTRAINT entry_type_check CHECK (entry_type IN ('DEBIT', 'CREDIT')),
    CONSTRAINT amount_check     CHECK (amount >= 0),
    CONSTRAINT line_status_check CHECK (line_status IN (
        'ACTIVE',
        'EXPIRED',
        'REVERSED'
    ))

    -- UNIQUE constraint to be added after duplicate expiry:
    -- ADD CONSTRAINT ledger_lines_unique
    -- UNIQUE (journal_entry_id, entry_sequence, line_status);
);


-- ------------------------------------------------------------
-- 6. PAYSIM RAW
-- Staging table. Receives PaySim CSV data as-is.
-- Never modified after load except is_processed flag
-- and anomaly_flag (set by load_journal_entries).
-- Serves as immutable audit trail back to source data.
-- paysim_raw_id is a pipeline key, not a business key.
-- trans_type renamed from 'type' to avoid reserved word.
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
-- 7. ETL LOG
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
-- 8. ETL LOG DETAIL
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
-- Joins etl_log and etl_log_detail for full run breakdown.
-- Single query surface for monitoring and reporting.
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


-- ------------------------------------------------------------
-- View: vw_etl_log
-- Full ETL run history ordered by most recent first.
-- Usage:
--   SELECT * FROM vw_etl_log LIMIT 1;  -- most recent run
--   SELECT * FROM vw_etl_log;           -- full history
-- ------------------------------------------------------------
CREATE VIEW vw_etl_log AS
SELECT
    etl_log_id,
    run_timestamp,
    process_name,
    status,
    rows_processed,
    message
FROM etl_log
ORDER BY run_timestamp DESC;


-- ------------------------------------------------------------
-- View: vw_journal_status_summary
-- Pipeline health snapshot by status.
-- PENDING  = not yet written to ledger
-- POSTED   = fully processed
-- FLAGGED  = anomaly detected, needs review
-- DUPLICATE = already processed, skipped
-- REVERSED = cancelled
-- ------------------------------------------------------------
CREATE VIEW vw_journal_status_summary AS
SELECT
    status,
    COUNT(*)            AS entry_count,
    SUM(amount)         AS total_amount
FROM journal_entries
GROUP BY status
ORDER BY status;


-- ------------------------------------------------------------
-- View: vw_paysim_flagged
-- All flagged rows in paysim_raw staging table.
-- ------------------------------------------------------------
CREATE VIEW vw_paysim_flagged AS
SELECT
    paysim_raw_id,
    step,
    trans_type,
    amount,
    nameOrig,
    oldbalanceOrg,
    newbalanceOrig,
    nameDest,
    anomaly_flag,
    loaded_at
FROM paysim_raw
WHERE anomaly_flag IS NOT NULL
ORDER BY loaded_at DESC;


-- ============================================================
-- SECTION 4: STORED PROCEDURES
-- ============================================================

-- ------------------------------------------------------------
-- Procedure: load_journal_entries
-- ETL: paysim_raw → journal_entries (one-to-one)
-- Anomaly detection:
--   DUPLICATE: transaction already in journal_entries
--   OVERDRAFT: amount exceeds sender opening balance
-- DUPLICATE checked before OVERDRAFT — first match wins.
-- Usage: CALL load_journal_entries();
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
    INSERT INTO etl_log (process_name, status, message)
    VALUES ('load_journal_entries', 'PARTIAL', 'Run started')
    RETURNING etl_log_id INTO v_log_id;

    -- Flag duplicates before main insert
    UPDATE paysim_raw
    SET anomaly_flag = 'DUPLICATE: transaction_id already exists'
    WHERE is_processed = FALSE
    AND paysim_raw_id::text IN (
        SELECT transaction_id
        FROM journal_entries
        WHERE transaction_id IS NOT NULL
    );

    WITH raw_transactions AS (
        SELECT
            paysim_raw_id,
            trans_type,
            amount,
            loaded_at,
            nameOrig,
            oldbalanceOrg,
            anomaly_flag,
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
            WHEN rt.anomaly_flag LIKE 'DUPLICATE%'
                THEN 'DUPLICATE'
            WHEN rt.amount > rt.oldbalanceOrg
            AND rt.trans_type IN ('TRANSFER', 'CASH_OUT', 'DEBIT')
                THEN 'FLAGGED'
            ELSE 'PENDING'
        END,
        rt.trans_type || ' from ' || rt.nameOrig,
        CASE
            WHEN rt.anomaly_flag LIKE 'DUPLICATE%'
                THEN rt.anomaly_flag
            WHEN rt.amount > rt.oldbalanceOrg
            AND rt.trans_type IN ('TRANSFER', 'CASH_OUT', 'DEBIT')
                THEN 'OVERDRAFT: amount exceeds opening balance'
            ELSE NULL
        END
    FROM raw_transactions AS rt;

    GET DIAGNOSTICS v_rows_total = ROW_COUNT;

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

    UPDATE paysim_raw
    SET is_processed = TRUE
    WHERE is_processed = FALSE;

    UPDATE etl_log
    SET
        status         = 'SUCCESS',
        rows_processed = v_rows_total,
        message        = 'Completed successfully. '
                            || v_rows_total || ' rows processed.'
    WHERE etl_log_id = v_log_id;

EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error_message = MESSAGE_TEXT;
    UPDATE etl_log
    SET status = 'FAILURE', message = 'Error: ' || v_error_message
    WHERE etl_log_id = v_log_id;
    RAISE;
END;
$$;


-- ------------------------------------------------------------
-- Procedure: load_ledger_lines
-- ETL: paysim_raw + journal_entries → ledger_lines
-- Processes PENDING journal entries only.
-- FLAGGED and DUPLICATE entries are excluded.
-- Fee rates looked up dynamically from fee_schedule.
-- Usage: CALL load_ledger_lines();
-- ------------------------------------------------------------
CREATE OR REPLACE PROCEDURE load_ledger_lines()
LANGUAGE plpgsql
AS $$
DECLARE
    rec             RECORD;
    v_fee_amount    NUMERIC(18,2);
    v_fee_rate      NUMERIC(8,6);
    v_rows_total    INT := 0;
    v_log_id        INT;
    v_error_message TEXT;
BEGIN
    INSERT INTO etl_log (process_name, status, message)
    VALUES ('load_ledger_lines', 'PARTIAL', 'Run started')
    RETURNING etl_log_id INTO v_log_id;

    FOR rec IN
        SELECT
            pr.paysim_raw_id,
            pr.trans_type,
            pr.amount,
            pr.nameOrig,
            pr.nameDest,
            pr.oldbalanceOrg,
            pr.newbalanceOrig,
            pr.oldbalanceDest,
            pr.newbalanceDest,
            je.journal_entry_id
        FROM paysim_raw AS pr
        JOIN journal_entries AS je
            ON pr.paysim_raw_id::text = je.transaction_id
        WHERE je.status = 'PENDING'
    LOOP
        v_fee_amount := 0;
        v_fee_rate   := 0;

        IF rec.trans_type = 'CASH_IN' THEN
            INSERT INTO ledger_lines (journal_entry_id, account_id, currency_code, entry_type, amount, entry_sequence)
            VALUES (rec.journal_entry_id, (SELECT account_id FROM accounts WHERE account_name = 'External Counterparty'), 1, 'DEBIT', rec.amount, 1);
            INSERT INTO ledger_lines (journal_entry_id, account_id, currency_code, entry_type, amount, entry_sequence)
            VALUES (rec.journal_entry_id, (SELECT account_id FROM accounts WHERE account_name = 'Main Settlement Suspense'), 1, 'CREDIT', rec.amount, 2);
            INSERT INTO ledger_lines (journal_entry_id, account_id, currency_code, entry_type, amount, entry_sequence)
            VALUES (rec.journal_entry_id, (SELECT account_id FROM accounts WHERE account_name = 'Main Settlement Suspense'), 1, 'DEBIT', rec.amount, 3);
            INSERT INTO ledger_lines (journal_entry_id, account_id, currency_code, entry_type, amount, entry_sequence)
            VALUES (rec.journal_entry_id, (SELECT account_id FROM accounts WHERE account_name = rec.nameOrig), 1, 'CREDIT', rec.amount, 4);
            UPDATE journal_entries SET status = 'POSTED' WHERE journal_entry_id = rec.journal_entry_id;

        ELSIF rec.trans_type = 'CASH_OUT' THEN
            SELECT ROUND(rec.amount * fs.fee_rate, 2) INTO v_fee_amount FROM fee_schedule fs WHERE fs.trans_type = 'CASH_OUT' AND fs.is_active = TRUE;
            INSERT INTO ledger_lines (journal_entry_id, account_id, currency_code, entry_type, amount, entry_sequence)
            VALUES (rec.journal_entry_id, (SELECT account_id FROM accounts WHERE account_name = rec.nameOrig), 1, 'DEBIT', rec.amount + v_fee_amount, 1);
            INSERT INTO ledger_lines (journal_entry_id, account_id, currency_code, entry_type, amount, entry_sequence)
            VALUES (rec.journal_entry_id, (SELECT account_id FROM accounts WHERE account_name = 'Main Settlement Suspense'), 1, 'CREDIT', rec.amount + v_fee_amount, 2);
            INSERT INTO ledger_lines (journal_entry_id, account_id, currency_code, entry_type, amount, entry_sequence)
            VALUES (rec.journal_entry_id, (SELECT account_id FROM accounts WHERE account_name = 'Main Settlement Suspense'), 1, 'DEBIT', rec.amount, 3);
            INSERT INTO ledger_lines (journal_entry_id, account_id, currency_code, entry_type, amount, entry_sequence)
            VALUES (rec.journal_entry_id, (SELECT account_id FROM accounts WHERE account_name = 'External Counterparty'), 1, 'CREDIT', rec.amount, 4);
            INSERT INTO ledger_lines (journal_entry_id, account_id, currency_code, entry_type, amount, entry_sequence)
            VALUES (rec.journal_entry_id, (SELECT account_id FROM accounts WHERE account_name = 'Main Settlement Suspense'), 1, 'DEBIT', v_fee_amount, 5);
            INSERT INTO ledger_lines (journal_entry_id, account_id, currency_code, entry_type, amount, entry_sequence)
            VALUES (rec.journal_entry_id, (SELECT account_id FROM accounts WHERE account_name = 'Platform Fee Revenue'), 1, 'CREDIT', v_fee_amount, 6);
            UPDATE journal_entries SET status = 'POSTED' WHERE journal_entry_id = rec.journal_entry_id;

        ELSIF rec.trans_type = 'TRANSFER' THEN
            SELECT ROUND(rec.amount * fs.fee_rate, 2) INTO v_fee_amount FROM fee_schedule fs WHERE fs.trans_type = 'TRANSFER' AND fs.is_active = TRUE;
            INSERT INTO ledger_lines (journal_entry_id, account_id, currency_code, entry_type, amount, entry_sequence)
            VALUES (rec.journal_entry_id, (SELECT account_id FROM accounts WHERE account_name = rec.nameOrig), 1, 'DEBIT', rec.amount + v_fee_amount, 1);
            INSERT INTO ledger_lines (journal_entry_id, account_id, currency_code, entry_type, amount, entry_sequence)
            VALUES (rec.journal_entry_id, (SELECT account_id FROM accounts WHERE account_name = 'Main Settlement Suspense'), 1, 'CREDIT', rec.amount + v_fee_amount, 2);
            INSERT INTO ledger_lines (journal_entry_id, account_id, currency_code, entry_type, amount, entry_sequence)
            VALUES (rec.journal_entry_id, (SELECT account_id FROM accounts WHERE account_name = 'Main Settlement Suspense'), 1, 'DEBIT', rec.amount, 3);
            INSERT INTO ledger_lines (journal_entry_id, account_id, currency_code, entry_type, amount, entry_sequence)
            VALUES (rec.journal_entry_id, (SELECT account_id FROM accounts WHERE account_name = rec.nameDest), 1, 'CREDIT', rec.amount, 4);
            INSERT INTO ledger_lines (journal_entry_id, account_id, currency_code, entry_type, amount, entry_sequence)
            VALUES (rec.journal_entry_id, (SELECT account_id FROM accounts WHERE account_name = 'Main Settlement Suspense'), 1, 'DEBIT', v_fee_amount, 5);
            INSERT INTO ledger_lines (journal_entry_id, account_id, currency_code, entry_type, amount, entry_sequence)
            VALUES (rec.journal_entry_id, (SELECT account_id FROM accounts WHERE account_name = 'Platform Fee Revenue'), 1, 'CREDIT', v_fee_amount, 6);
            UPDATE journal_entries SET status = 'POSTED' WHERE journal_entry_id = rec.journal_entry_id;

        ELSIF rec.trans_type = 'PAYMENT' THEN
            INSERT INTO ledger_lines (journal_entry_id, account_id, currency_code, entry_type, amount, entry_sequence)
            VALUES (rec.journal_entry_id, (SELECT account_id FROM accounts WHERE account_name = rec.nameOrig), 1, 'DEBIT', rec.amount, 1);
            INSERT INTO ledger_lines (journal_entry_id, account_id, currency_code, entry_type, amount, entry_sequence)
            VALUES (rec.journal_entry_id, (SELECT account_id FROM accounts WHERE account_name = 'Main Settlement Suspense'), 1, 'CREDIT', rec.amount, 2);
            INSERT INTO ledger_lines (journal_entry_id, account_id, currency_code, entry_type, amount, entry_sequence)
            VALUES (rec.journal_entry_id, (SELECT account_id FROM accounts WHERE account_name = 'Main Settlement Suspense'), 1, 'DEBIT', rec.amount, 3);
            INSERT INTO ledger_lines (journal_entry_id, account_id, currency_code, entry_type, amount, entry_sequence)
            VALUES (rec.journal_entry_id, (SELECT account_id FROM accounts WHERE account_name = 'External Counterparty'), 1, 'CREDIT', rec.amount, 4);
            UPDATE journal_entries SET status = 'POSTED' WHERE journal_entry_id = rec.journal_entry_id;

        ELSIF rec.trans_type = 'DEBIT' THEN
            INSERT INTO ledger_lines (journal_entry_id, account_id, currency_code, entry_type, amount, entry_sequence)
            VALUES (rec.journal_entry_id, (SELECT account_id FROM accounts WHERE account_name = rec.nameOrig), 1, 'DEBIT', rec.amount, 1);
            INSERT INTO ledger_lines (journal_entry_id, account_id, currency_code, entry_type, amount, entry_sequence)
            VALUES (rec.journal_entry_id, (SELECT account_id FROM accounts WHERE account_name = 'Main Settlement Suspense'), 1, 'CREDIT', rec.amount, 2);
            INSERT INTO ledger_lines (journal_entry_id, account_id, currency_code, entry_type, amount, entry_sequence)
            VALUES (rec.journal_entry_id, (SELECT account_id FROM accounts WHERE account_name = 'Main Settlement Suspense'), 1, 'DEBIT', rec.amount, 3);
            INSERT INTO ledger_lines (journal_entry_id, account_id, currency_code, entry_type, amount, entry_sequence)
            VALUES (rec.journal_entry_id, (SELECT account_id FROM accounts WHERE account_name = rec.nameDest), 1, 'CREDIT', rec.amount, 4);
            UPDATE journal_entries SET status = 'POSTED' WHERE journal_entry_id = rec.journal_entry_id;

        ELSE
            UPDATE journal_entries
            SET status = 'FLAGGED', anomaly_flag = 'UNKNOWN TRANS_TYPE: ' || rec.trans_type
            WHERE journal_entry_id = rec.journal_entry_id;
        END IF;

        v_rows_total := v_rows_total + 1;
    END LOOP;

    UPDATE etl_log
    SET
        status         = 'SUCCESS',
        rows_processed = v_rows_total,
        message        = 'Completed successfully. ' || v_rows_total || ' rows processed.'
    WHERE etl_log_id = v_log_id;

EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error_message = MESSAGE_TEXT;
    UPDATE etl_log
    SET status = 'FAILURE', message = 'Error: ' || v_error_message
    WHERE etl_log_id = v_log_id;
    RAISE;
END;
$$;


-- ============================================================
-- SECTION 5: SEED DATA
-- Execute in order. Currency before accounts.
-- ============================================================

-- Currency
INSERT INTO currency (currency_name, iso_code, is_active)
VALUES ('US Dollar', 'USD', TRUE);

-- System Accounts
INSERT INTO accounts (account_name, account_type, currency_code, is_system_account)
VALUES
    ('Main Settlement Suspense',   'SUSPENSE',    (SELECT currency_code FROM currency WHERE iso_code = 'USD'), TRUE),
    ('Failed Settlement Suspense', 'SUSPENSE',    (SELECT currency_code FROM currency WHERE iso_code = 'USD'), TRUE),
    ('Platform Fee Revenue',       'FEE_REVENUE', (SELECT currency_code FROM currency WHERE iso_code = 'USD'), TRUE),
    ('External Counterparty',      'EXTERNAL',    (SELECT currency_code FROM currency WHERE iso_code = 'USD'), TRUE);

-- Fee Schedule
INSERT INTO fee_schedule (trans_type, fee_type, fee_rate, fee_fixed, effective_date)
VALUES
    ('TRANSFER', 'PERCENTAGE', 0.005000, 0.00, CURRENT_DATE),
    ('CASH_OUT',  'PERCENTAGE', 0.010000, 0.00, CURRENT_DATE),
    ('PAYMENT',  'FIXED',      0.000000, 1.50, CURRENT_DATE);

-- Customer and Merchant Accounts from PaySim
-- Run after paysim_raw is loaded.
INSERT INTO accounts (account_name, account_type, currency_code)
SELECT DISTINCT
    nameOrig,
    CASE WHEN nameOrig LIKE 'C%' THEN 'BANK' WHEN nameOrig LIKE 'M%' THEN 'EXTERNAL' END,
    (SELECT currency_code FROM currency WHERE iso_code = 'USD')
FROM paysim_raw
UNION
SELECT DISTINCT
    nameDest,
    CASE WHEN nameDest LIKE 'C%' THEN 'BANK' WHEN nameDest LIKE 'M%' THEN 'EXTERNAL' END,
    (SELECT currency_code FROM currency WHERE iso_code = 'USD')
FROM paysim_raw
ON CONFLICT (account_name) DO NOTHING;
