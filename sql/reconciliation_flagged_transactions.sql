-- ============================================================
-- Financial Ledger Platform
-- Reconciliation Layer: Flagged Transaction Objects
-- Database: PostgreSQL 14+
--
-- Purpose:
--   Detection and reporting of anomalous transactions
--   across all three pipeline layers: paysim_raw,
--   journal_entries, and ledger_lines.
--
-- Objects:
--   vw_paysim_flagged         VIEW     - Flagged rows in staging
--   get_journal_flagged()     FUNCTION - Flagged journal entries
--   check_ledger_integrity()  FUNCTION - Integrity verification
--
-- Anomaly Types:
--   OVERDRAFT: Transaction amount exceeds sender opening balance.
--   Applies to TRANSFER, CASH_OUT, DEBIT only.
--   CASH_IN and PAYMENT cannot overdraft by definition.
--
-- Pipeline Behavior:
--   Flagged transactions are loaded to journal_entries
--   with status = 'FLAGGED' and anomaly_flag populated.
--   They are excluded from ledger_lines processing.
--   check_ledger_integrity() confirms zero leakage.
--
-- Design Decision:
--   ledger_lines has no status column by design.
--   Transaction status is managed at the journal_entries
--   level. A ledger line's existence implies it belongs
--   to a POSTED transaction. Flagged transactions are
--   filtered at the pipeline layer before ledger lines
--   are written.
--
-- Usage:
--   -- All flagged rows in staging
--   SELECT * FROM vw_paysim_flagged;
--
--   -- Flagged journal entries all time
--   SELECT * FROM get_journal_flagged();
--
--   -- Flagged journal entries for date range
--   SELECT * FROM get_journal_flagged('2024-01-01', '2024-01-31');
--
--   -- Verify no flagged transactions in ledger
--   SELECT * FROM check_ledger_integrity();
--   -- Zero rows = pipeline integrity confirmed
-- ============================================================


-- ------------------------------------------------------------
-- VIEW: vw_paysim_flagged
--
-- Returns all rows in paysim_raw where an anomaly was
-- detected during staging inspection.
--
-- Anomaly flag is set during load_journal_entries()
-- before rows are promoted to journal_entries.
--
-- Usage:
--   SELECT * FROM vw_paysim_flagged;
--   SELECT COUNT(*) FROM vw_paysim_flagged;
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


-- ------------------------------------------------------------
-- FUNCTION: get_journal_flagged
--
-- Returns flagged journal entries within a date range.
-- Catches rows where EITHER:
--   anomaly_flag IS NOT NULL (anomaly recorded)
--   OR status = 'FLAGGED'   (status set by pipeline)
--
-- Both conditions checked independently as defensive
-- coding — in theory they always match, but checking
-- both catches edge cases where one was set without
-- the other.
--
-- Operator precedence note:
--   AND is evaluated before OR. Parentheses wrap the
--   OR condition to ensure date filter applies to
--   both anomaly conditions, not just the first.
--
-- Parameters:
--   p_start_date : Start date (inclusive). Default: 2000-01-01
--   p_end_date   : End date (inclusive). Default: CURRENT_DATE
--
-- Usage:
--   SELECT * FROM get_journal_flagged();
--   SELECT * FROM get_journal_flagged('2024-01-01', '2024-01-31');
--   SELECT * FROM get_journal_flagged('2024-01-01');
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_journal_flagged(
    p_start_date    DATE DEFAULT '2000-01-01',
    p_end_date      DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
    journal_entry_id    INTEGER,
    transaction_id      TEXT,
    trans_type          TEXT,
    amount              NUMERIC(18,2),
    status              TEXT,
    anomaly_flag        TEXT,
    entry_timestamp     TIMESTAMP,
    created_at          TIMESTAMP
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT
        je.journal_entry_id,
        je.transaction_id,
        je.trans_type,
        je.amount,
        je.status,
        je.anomaly_flag,
        je.entry_timestamp,
        je.created_at
    FROM journal_entries je
    WHERE DATE(je.created_at) BETWEEN p_start_date AND p_end_date
    AND (je.anomaly_flag IS NOT NULL OR je.status = 'FLAGGED')
    ORDER BY je.created_at DESC;
END;
$$;


-- ------------------------------------------------------------
-- FUNCTION: check_ledger_integrity
--
-- Verifies that no flagged transactions leaked into
-- ledger_lines during ETL processing.
--
-- Expected result: zero rows returned.
-- Any rows returned indicate a pipeline integrity failure
-- requiring immediate investigation.
--
-- Joins ledger_lines to journal_entries to check parent
-- status — ledger_lines has no status column by design.
-- See design decision note in file header.
--
-- Parameters:
--   p_start_date : Start date (inclusive). Default: 2000-01-01
--   p_end_date   : End date (inclusive). Default: CURRENT_DATE
--
-- Usage:
--   SELECT * FROM check_ledger_integrity();
--   SELECT * FROM check_ledger_integrity('2024-01-01', '2024-01-31');
--
--   -- Quick pass/fail check
--   SELECT CASE
--       WHEN COUNT(*) = 0 THEN 'PASS: No integrity violations'
--       ELSE 'FAIL: ' || COUNT(*) || ' violations detected'
--   END AS integrity_status
--   FROM check_ledger_integrity();
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION check_ledger_integrity(
    p_start_date    DATE DEFAULT '2000-01-01',
    p_end_date      DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
    ledger_line_id      INTEGER,
    journal_entry_id    INTEGER,
    trans_type          TEXT,
    status              TEXT,
    anomaly_flag        TEXT,
    entry_type          TEXT,
    amount              NUMERIC(18,2)
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT
        ll.ledger_line_id,
        ll.journal_entry_id,
        je.trans_type,
        je.status,
        je.anomaly_flag,
        ll.entry_type,
        ll.amount
    FROM ledger_lines ll
    JOIN journal_entries je
        ON ll.journal_entry_id = je.journal_entry_id
    WHERE DATE(je.created_at) BETWEEN p_start_date AND p_end_date
    AND (je.status = 'FLAGGED' OR je.anomaly_flag IS NOT NULL)
    ORDER BY ll.ledger_line_id;
END;
$$;
