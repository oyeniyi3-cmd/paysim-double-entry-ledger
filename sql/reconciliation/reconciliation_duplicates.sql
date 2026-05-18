-- ============================================================
-- Financial Ledger Platform
-- Reconciliation Layer: Duplicate Detection
-- Database: PostgreSQL 14+
--
-- Objects:
--   check_paysim_duplicates()      FUNCTION - Source duplicates
--   check_journal_duplicates()     FUNCTION - Pipeline duplicates
--   check_ledger_line_counts()     FUNCTION - Line count integrity
--
-- Duplicate Types:
--   EXACT DUPLICATE  : Same sender, receiver, amount, same step
--   REPLAY DUPLICATE : Same sender, receiver, amount, diff step
--                      Common fraud pattern: replay attacks
--
-- Expected Results:
--   check_paysim_duplicates()  → zero rows (clean source)
--   check_journal_duplicates() → zero rows (UNIQUE constraint)
--   check_ledger_line_counts() → zero rows (correct line counts)
--
-- Known Issue:
--   check_ledger_line_counts() currently returns rows due to
--   load_ledger_lines() running twice. Duplicate lines have
--   line_status = 'ACTIVE' pending expiry batch job.
--   Function filters ACTIVE + POSTED to isolate the issue.
--   Add UNIQUE constraint after expiry batch completes:
--   ALTER TABLE ledger_lines ADD CONSTRAINT ledger_lines_unique
--   UNIQUE (journal_entry_id, entry_sequence, line_status);
-- ============================================================


-- ------------------------------------------------------------
-- FUNCTION: check_paysim_duplicates
-- Two duplicate definitions:
--   EXACT DUPLICATE  : same nameOrig, nameDest, amount, step
--   REPLAY DUPLICATE : same nameOrig, nameDest, amount
--                      across different steps (time periods)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION check_paysim_duplicates(
    p_start_date    DATE DEFAULT '2000-01-01',
    p_end_date      DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
    nameOrig        TEXT,
    nameDest        TEXT,
    amount          NUMERIC(18,2),
    occurrences     BIGINT,
    first_seen      INTEGER,
    last_seen       INTEGER,
    duplicate_type  TEXT
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY

    -- Definition 1: Exact duplicates
    SELECT
        pr.nameOrig,
        pr.nameDest,
        pr.amount,
        COUNT(*)            AS occurrences,
        MIN(pr.step)        AS first_seen,
        MAX(pr.step)        AS last_seen,
        'EXACT DUPLICATE'   AS duplicate_type
    FROM paysim_raw pr
    WHERE DATE(pr.loaded_at) BETWEEN p_start_date AND p_end_date
    GROUP BY pr.nameOrig, pr.nameDest, pr.amount, pr.step
    HAVING COUNT(*) > 1

    UNION ALL

    -- Definition 2: Replay duplicates
    SELECT
        pr.nameOrig,
        pr.nameDest,
        pr.amount,
        COUNT(*)            AS occurrences,
        MIN(pr.step)        AS first_seen,
        MAX(pr.step)        AS last_seen,
        'REPLAY DUPLICATE'  AS duplicate_type
    FROM paysim_raw pr
    WHERE DATE(pr.loaded_at) BETWEEN p_start_date AND p_end_date
    GROUP BY pr.nameOrig, pr.nameDest, pr.amount
    HAVING COUNT(DISTINCT pr.step) > 1

    ORDER BY duplicate_type, occurrences DESC;
END;
$$;


-- ------------------------------------------------------------
-- FUNCTION: check_journal_duplicates
-- Detects duplicate transaction_ids in journal_entries.
-- transaction_id has a UNIQUE constraint — any result
-- here indicates constraint bypass or manual insert.
-- Expected result: zero rows.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION check_journal_duplicates(
    p_start_date    DATE DEFAULT '2000-01-01',
    p_end_date      DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
    transaction_id      TEXT,
    trans_type          TEXT,
    amount              NUMERIC(18,2),
    occurrences         BIGINT,
    duplicate_type      TEXT
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT
        je.transaction_id,
        je.trans_type,
        je.amount,
        COUNT(*)                    AS occurrences,
        'DUPLICATE TRANSACTION ID'  AS duplicate_type
    FROM journal_entries je
    WHERE DATE(je.created_at) BETWEEN p_start_date AND p_end_date
    GROUP BY je.transaction_id, je.trans_type, je.amount
    HAVING COUNT(je.transaction_id) > 1
    ORDER BY occurrences DESC;
END;
$$;


-- ------------------------------------------------------------
-- FUNCTION: check_ledger_line_counts
-- Verifies each journal entry has the correct number of
-- ledger lines for its transaction type.
-- Expected line counts:
--   CASH_IN, PAYMENT, DEBIT = 4 lines
--   CASH_OUT, TRANSFER      = 6 lines
-- TOO MANY LEDGER LINES = duplicate ETL run
-- TOO FEW LEDGER LINES  = incomplete ETL run
-- Filters ACTIVE lines and POSTED entries only.
-- Expected result: zero rows.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION check_ledger_line_counts(
    p_start_date    DATE DEFAULT '2000-01-01',
    p_end_date      DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
    journal_entry_id    INTEGER,
    trans_type          TEXT,
    expected_lines      INTEGER,
    actual_lines        BIGINT,
    duplicate_type      TEXT
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT
        je.journal_entry_id,
        je.trans_type,
        CASE
            WHEN je.trans_type IN ('CASH_IN', 'PAYMENT', 'DEBIT') THEN 4
            WHEN je.trans_type IN ('CASH_OUT', 'TRANSFER') THEN 6
            ELSE 0
        END                         AS expected_lines,
        COUNT(ll.ledger_line_id)    AS actual_lines,
        CASE
            WHEN COUNT(ll.ledger_line_id) >
                CASE
                    WHEN je.trans_type IN ('CASH_IN', 'PAYMENT', 'DEBIT') THEN 4
                    WHEN je.trans_type IN ('CASH_OUT', 'TRANSFER') THEN 6
                    ELSE 0
                END
                THEN 'TOO MANY LEDGER LINES'
            WHEN COUNT(ll.ledger_line_id) <
                CASE
                    WHEN je.trans_type IN ('CASH_IN', 'PAYMENT', 'DEBIT') THEN 4
                    WHEN je.trans_type IN ('CASH_OUT', 'TRANSFER') THEN 6
                    ELSE 0
                END
                THEN 'TOO FEW LEDGER LINES'
            ELSE NULL
        END                         AS duplicate_type
    FROM ledger_lines ll
    JOIN journal_entries je
        ON ll.journal_entry_id = je.journal_entry_id
    WHERE DATE(ll.created_at) BETWEEN p_start_date AND p_end_date
    AND ll.line_status = 'ACTIVE'
    AND je.status = 'POSTED'
    GROUP BY je.journal_entry_id, je.trans_type
    HAVING COUNT(ll.ledger_line_id) !=
        CASE
            WHEN je.trans_type IN ('CASH_IN', 'PAYMENT', 'DEBIT') THEN 4
            WHEN je.trans_type IN ('CASH_OUT', 'TRANSFER') THEN 6
            ELSE 0
        END
    ORDER BY actual_lines DESC;
END;
$$;


-- ------------------------------------------------------------
-- Batch Expiry Script (run on cloud instance)
-- Expires duplicate ledger lines from second ETL run.
-- Keeps lowest ledger_line_id per journal_entry_id +
-- entry_sequence combination as the ACTIVE record.
-- Run after this script on a machine with sufficient memory.
-- Then add UNIQUE constraint (see file header).
-- ------------------------------------------------------------
/*
DO $$
DECLARE
    rows_updated INT;
BEGIN
    LOOP
        UPDATE ledger_lines
        SET line_status = 'EXPIRED'
        WHERE ledger_line_id IN (
            SELECT ll.ledger_line_id
            FROM ledger_lines ll
            WHERE ll.line_status = 'ACTIVE'
            AND ll.ledger_line_id > (
                SELECT MIN(ll2.ledger_line_id)
                FROM ledger_lines ll2
                WHERE ll2.journal_entry_id = ll.journal_entry_id
                AND ll2.entry_sequence = ll.entry_sequence
            )
            LIMIT 100000
        );
        GET DIAGNOSTICS rows_updated = ROW_COUNT;
        RAISE NOTICE 'Rows expired: %', rows_updated;
        EXIT WHEN rows_updated = 0;
    END LOOP;
END;
$$;

-- After expiry completes, add UNIQUE constraint:
ALTER TABLE ledger_lines
ADD CONSTRAINT ledger_lines_unique
UNIQUE (journal_entry_id, entry_sequence, line_status);
*/
