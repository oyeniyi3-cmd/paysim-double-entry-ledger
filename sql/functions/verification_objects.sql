-- ============================================================
-- Financial Ledger Platform
-- Verification Views and Functions
-- Database: PostgreSQL 14+
--
-- Objects:
--   check_ledger_balance()    FUNCTION - Debit/credit variance
--   check_suspense_balance()  FUNCTION - Suspense account health
--   vw_etl_log                VIEW     - ETL run history
--   vw_journal_status_summary VIEW     - Pipeline health snapshot
--
-- All objects are read-only. No ETL logging.
-- ============================================================


-- ------------------------------------------------------------
-- FUNCTION: check_ledger_balance
-- Returns debit/credit totals and variance by trans type.
-- Zero variance = balanced ledger.
-- Non-zero variance = reconciliation break.
-- Filters ACTIVE ledger lines only.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION check_ledger_balance(
    p_start_date DATE DEFAULT '2000-01-01',
    p_end_date   DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
    trans_type          TEXT,
    transaction_count   BIGINT,
    total_debits        NUMERIC(18,2),
    total_credits       NUMERIC(18,2),
    variance            NUMERIC(18,2)
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT
        je.trans_type,
        COUNT(DISTINCT je.journal_entry_id),
        SUM(CASE WHEN ll.entry_type = 'DEBIT'
            THEN ll.amount ELSE 0 END)::NUMERIC(18,2),
        SUM(CASE WHEN ll.entry_type = 'CREDIT'
            THEN ll.amount ELSE 0 END)::NUMERIC(18,2),
        (SUM(CASE WHEN ll.entry_type = 'DEBIT'
            THEN ll.amount ELSE 0 END) -
        SUM(CASE WHEN ll.entry_type = 'CREDIT'
            THEN ll.amount ELSE 0 END))::NUMERIC(18,2) AS variance
    FROM ledger_lines ll
    JOIN journal_entries je
        ON je.journal_entry_id = ll.journal_entry_id
    WHERE DATE(ll.created_at) BETWEEN p_start_date AND p_end_date
    AND ll.line_status = 'ACTIVE'
    GROUP BY je.trans_type
    ORDER BY je.trans_type;
END;
$$;


-- ------------------------------------------------------------
-- FUNCTION: check_suspense_balance
-- Returns debit/credit totals and net balance for all
-- suspense accounts.
-- BALANCED     = all settlements cleared (expected)
-- BREAK DETECTED = funds stuck in transit (investigate)
-- Main Settlement Suspense should always show BALANCED.
-- Failed Settlement Suspense balance is expected when
-- failed transactions are pending resolution.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION check_suspense_balance(
    p_start_date    DATE DEFAULT '2000-01-01',
    p_end_date      DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
    suspense_account    TEXT,
    total_debits        NUMERIC(18,2),
    total_credits       NUMERIC(18,2),
    suspense_balance    NUMERIC(18,2),
    balance_status      TEXT
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT
        acct.account_name,
        SUM(CASE WHEN ll.entry_type = 'DEBIT'
            THEN ll.amount ELSE 0 END)::NUMERIC(18,2),
        SUM(CASE WHEN ll.entry_type = 'CREDIT'
            THEN ll.amount ELSE 0 END)::NUMERIC(18,2),
        (SUM(CASE WHEN ll.entry_type = 'CREDIT'
            THEN ll.amount ELSE 0 END) -
        SUM(CASE WHEN ll.entry_type = 'DEBIT'
            THEN ll.amount ELSE 0 END))::NUMERIC(18,2),
        CASE
            WHEN SUM(CASE WHEN ll.entry_type = 'CREDIT'
                THEN ll.amount ELSE 0 END) -
                 SUM(CASE WHEN ll.entry_type = 'DEBIT'
                THEN ll.amount ELSE 0 END) = 0
            THEN 'BALANCED'
            ELSE 'BREAK DETECTED'
        END
    FROM ledger_lines ll
    JOIN accounts acct
        ON ll.account_id = acct.account_id
    WHERE acct.account_name IN (
        'Main Settlement Suspense',
        'Failed Settlement Suspense'
    )
    AND DATE(ll.created_at) BETWEEN p_start_date AND p_end_date
    AND ll.line_status = 'ACTIVE'
    GROUP BY acct.account_name
    ORDER BY acct.account_name;
END;
$$;


-- ------------------------------------------------------------
-- VIEW: vw_etl_log
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
-- Healthy pipeline: PENDING=0, POSTED=N, FLAGGED=low.
-- ------------------------------------------------------------
CREATE VIEW vw_journal_status_summary AS
SELECT
    status,
    COUNT(*)            AS entry_count,
    SUM(amount)         AS total_amount
FROM journal_entries
GROUP BY status
ORDER BY status;
