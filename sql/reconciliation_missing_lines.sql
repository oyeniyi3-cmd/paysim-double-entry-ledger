-- ============================================================
-- Financial Ledger Platform
-- Reconciliation Layer: Missing Ledger Line Detection
-- Database: PostgreSQL 14+
--
-- Object:
--   check_missing_ledger_lines()  FUNCTION
--
-- Purpose:
--   Detects POSTED journal entries with no corresponding
--   rows in ledger_lines. A POSTED entry with zero ledger
--   lines indicates a silent ETL failure — the pipeline
--   claimed success but produced no accounting entries.
--
-- Design Note:
--   ledger_lines has no status column by design.
--   Transaction status is managed at the journal_entries
--   level. A ledger line's existence implies it belongs
--   to a POSTED transaction. Flagged and duplicate
--   transactions are filtered at the pipeline layer
--   before ledger lines are written.
--
-- Expected Result:
--   Zero rows = pipeline integrity confirmed.
--   Any rows = silent failure requiring investigation.
-- ============================================================


-- ------------------------------------------------------------
-- FUNCTION: check_missing_ledger_lines
-- Anti-join pattern: finds POSTED journal entries with
-- no matching rows in ledger_lines.
-- NOT EXISTS chosen over LEFT JOIN / NULL check for
-- readability and performance on large datasets.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION check_missing_ledger_lines(
    p_start_date    DATE DEFAULT '2000-01-01',
    p_end_date      DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
    journal_entry_id    INTEGER,
    status              TEXT,
    description         TEXT,
    trans_type          TEXT,
    flagged             TEXT
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT
        je.journal_entry_id,
        je.status,
        je.description,
        je.trans_type,
        'Journal entry not posted to ledger table.' AS flagged
    FROM journal_entries je
    WHERE je.status = 'POSTED'
    AND DATE(je.created_at) BETWEEN p_start_date AND p_end_date
    AND NOT EXISTS (
        SELECT 1 FROM ledger_lines ll
        WHERE ll.journal_entry_id = je.journal_entry_id
    )
    ORDER BY je.journal_entry_id;
END;
$$;
