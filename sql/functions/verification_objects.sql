-- ============================================================
-- Financial Ledger Platform
-- Verification Views and Functions
-- Database: PostgreSQL 14+
--
-- Purpose:
--   Production-grade verification objects for monitoring
--   pipeline health, ledger integrity, and transaction
--   status at a glance.
--
-- Objects:
--   check_ledger_balance()    FUNCTION  - Debit/credit variance
--   vw_etl_log                VIEW      - ETL run history
--   vw_journal_status_summary VIEW      - Pipeline health snapshot
--
-- Design Principle:
--   Read-only objects do not write to etl_log.
--   ETL logging is reserved for data-modifying procedures.
--   Views use ORDER BY for consistent output; apply LIMIT
--   at query time rather than inside the view definition.
--
-- Usage:
--   -- Check ledger balance all time
--   SELECT * FROM check_ledger_balance();
--
--   -- Check ledger balance for date range
--   SELECT * FROM check_ledger_balance('2024-01-01', '2024-01-31');
--
--   -- Check last ETL run
--   SELECT * FROM vw_etl_log LIMIT 1;
--
--   -- Check full ETL history
--   SELECT * FROM vw_etl_log;
--
--   -- Check pipeline health
--   SELECT * FROM vw_journal_status_summary;
-- ============================================================


-- ------------------------------------------------------------
-- FUNCTION: check_ledger_balance
--
-- Returns debit/credit totals and variance by transaction
-- type for a specified date range.
--
-- A variance of zero confirms ledger integrity.
-- Any non-zero variance indicates a reconciliation break
-- requiring investigation.
--
-- Parameters:
--   p_start_date : Start date (inclusive). Default: 2000-01-01
--   p_end_date   : End date (inclusive). Default: CURRENT_DATE
--
-- Returns:
--   trans_type        : Transaction type
--   transaction_count : Number of journal entries
--   total_debits      : Sum of all debit amounts
--   total_credits     : Sum of all credit amounts
--   variance          : total_debits - total_credits
--                       Zero = balanced. Non-zero = break.
--
-- Usage:
--   SELECT * FROM check_ledger_balance();
--   SELECT * FROM check_ledger_balance('2024-01-01', '2024-01-31');
--   SELECT * FROM check_ledger_balance('2024-01-01');
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
    GROUP BY je.trans_type
    ORDER BY je.trans_type;
END;
$$;


-- ------------------------------------------------------------
-- VIEW: vw_etl_log
--
-- Full ETL run history ordered by most recent first.
-- Covers all ETL procedures: load_journal_entries,
-- load_ledger_lines, and any future procedures.
--
-- Usage:
--   SELECT * FROM vw_etl_log LIMIT 1;  -- most recent run
--   SELECT * FROM vw_etl_log;           -- full history
--
--   -- Filter by procedure
--   SELECT * FROM vw_etl_log
--   WHERE process_name = 'load_ledger_lines'
--   LIMIT 1;
--
--   -- Filter by status
--   SELECT * FROM vw_etl_log
--   WHERE status = 'FAILURE';
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
-- VIEW: vw_journal_status_summary
--
-- Snapshot of journal entry counts and amounts by status.
-- Primary pipeline health monitor.
--
-- Status meanings:
--   PENDING  = Loaded to journal, not yet written to ledger
--   POSTED   = Fully processed through ledger pipeline
--   FLAGGED  = Anomaly detected, requires investigation
--              (e.g. overdraft, unknown transaction type)
--   REVERSED = Cancelled or reversed transactions
--
-- Healthy pipeline shows:
--   PENDING  = 0  (all entries processed)
--   POSTED   = N  (all transactions complete)
--   FLAGGED  = low number (anomalies under review)
--   REVERSED = low number (reversals as expected)
--
-- Usage:
--   SELECT * FROM vw_journal_status_summary;
-- ------------------------------------------------------------
CREATE VIEW vw_journal_status_summary AS
SELECT
    status,
    COUNT(*)            AS entry_count,
    SUM(amount)         AS total_amount
FROM journal_entries
GROUP BY status
ORDER BY status;
