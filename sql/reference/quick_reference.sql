-- ============================================================
-- Financial Ledger Platform
-- Quick Reference: All Callable Objects — Layer 1 Complete
-- Database: PostgreSQL 14+
--
-- Object Types:
--   PROCEDURE : Data modification. Called with CALL.
--   FUNCTION  : Data retrieval with parameters.
--               Called with SELECT * FROM.
--   VIEW      : Data retrieval, no parameters.
--               Called with SELECT * FROM.
-- ============================================================


-- ============================================================
-- SECTION 1: ETL PROCEDURES
-- Run in this order for a clean pipeline execution.
-- ============================================================

-- Step 1: Load raw data to journal entries
CALL load_journal_entries();

-- Step 2: Load journal entries to ledger lines
CALL load_ledger_lines();


-- ============================================================
-- SECTION 2: VERIFICATION FUNCTIONS
-- Run after ETL to confirm pipeline integrity.
-- ============================================================

-- Ledger balance by transaction type (all time)
SELECT * FROM check_ledger_balance();

-- Ledger balance for date range
SELECT * FROM check_ledger_balance('2024-01-01', '2024-01-31');

-- Ledger balance month to date
SELECT * FROM check_ledger_balance(
    DATE_TRUNC('month', CURRENT_DATE)::DATE,
    CURRENT_DATE
);

-- Suspense account balance (all time)
SELECT * FROM check_suspense_balance();

-- Suspense account balance for date range
SELECT * FROM check_suspense_balance('2024-01-01', '2024-01-31');

-- Ledger integrity — flagged transactions in ledger lines
SELECT * FROM check_ledger_integrity();

-- Quick pass/fail integrity check
SELECT CASE
    WHEN COUNT(*) = 0 THEN 'PASS: No integrity violations'
    ELSE 'FAIL: ' || COUNT(*) || ' violations detected'
END AS integrity_status
FROM check_ledger_integrity();


-- ============================================================
-- SECTION 3: RECONCILIATION FUNCTIONS
-- ============================================================

-- Missing ledger lines (POSTED entries with no ledger lines)
SELECT * FROM check_missing_ledger_lines();
SELECT * FROM check_missing_ledger_lines('2024-01-01', '2024-01-31');

-- Flagged journal entries (overdrafts, anomalies)
SELECT * FROM get_journal_flagged();
SELECT * FROM get_journal_flagged('2024-01-01', '2024-01-31');

-- Duplicate detection: paysim_raw source data
SELECT * FROM check_paysim_duplicates();
SELECT * FROM check_paysim_duplicates('2024-01-01', '2024-01-31');

-- Duplicate detection: journal entries
SELECT * FROM check_journal_duplicates();
SELECT * FROM check_journal_duplicates('2024-01-01', '2024-01-31');

-- Ledger line count integrity (expected vs actual per entry)
SELECT * FROM check_ledger_line_counts();
SELECT * FROM check_ledger_line_counts('2024-01-01', '2024-01-31');

-- Summary of flagged counts by type
SELECT
    trans_type,
    COUNT(*) AS flagged_count
FROM check_ledger_line_counts()
GROUP BY trans_type
ORDER BY flagged_count DESC;


-- ============================================================
-- SECTION 4: REPORTING FUNCTIONS
-- ============================================================

-- Fee revenue all time
SELECT * FROM get_fee_revenue('2000-01-01', CURRENT_DATE);

-- Fee revenue for date range
SELECT * FROM get_fee_revenue('2024-01-01', '2024-01-31');

-- Fee revenue month to date
SELECT * FROM get_fee_revenue(
    DATE_TRUNC('month', CURRENT_DATE)::DATE,
    CURRENT_DATE
);

-- Fee revenue single date (uses default end date)
SELECT * FROM get_fee_revenue('2024-01-01');


-- ============================================================
-- SECTION 5: VIEWS
-- ============================================================

-- Most recent ETL run
SELECT * FROM vw_etl_log LIMIT 1;

-- Full ETL history
SELECT * FROM vw_etl_log;

-- Filter by procedure
SELECT * FROM vw_etl_log
WHERE process_name = 'load_ledger_lines'
LIMIT 1;

-- Filter by status
SELECT * FROM vw_etl_log
WHERE status = 'FAILURE';

-- ETL run summary with per-type breakdown
SELECT * FROM etl_run_summary;

-- Most recent run detail
SELECT * FROM etl_run_summary
WHERE etl_log_id = (SELECT MAX(etl_log_id) FROM etl_log);

-- Pipeline health snapshot
SELECT * FROM vw_journal_status_summary;

-- Flagged rows in staging table
SELECT * FROM vw_paysim_flagged;
SELECT COUNT(*) FROM vw_paysim_flagged;


-- ============================================================
-- SECTION 6: SCHEMA INSPECTION
-- ============================================================

-- All tables
SELECT table_name FROM information_schema.tables
WHERE table_schema = 'public' ORDER BY table_name;

-- Row counts per table
SELECT relname AS table_name, n_live_tup AS estimated_row_count
FROM pg_stat_user_tables
WHERE schemaname = 'public'
ORDER BY n_live_tup DESC;

-- All constraints on ledger_lines
SELECT constraint_name, constraint_type
FROM information_schema.table_constraints
WHERE table_name = 'ledger_lines';

-- Line status distribution in ledger_lines
SELECT line_status, COUNT(*)
FROM ledger_lines
GROUP BY line_status;

-- Journal entry status distribution
SELECT status, COUNT(*)
FROM journal_entries
GROUP BY status;
