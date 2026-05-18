-- ============================================================
-- Financial Ledger Platform
-- Stored Procedure: load_journal_entries
-- Database: PostgreSQL 14+
--
-- Purpose:
--   ETL procedure that transforms paysim_raw into
--   journal_entries table.
--
-- Data Lineage:
--   paysim_raw → journal_entries (one-to-one)
--
-- Anomaly Detection:
--   Two anomaly types detected and flagged automatically:
--
--   1. DUPLICATE: transaction_id already exists in
--      journal_entries. Row is flagged in paysim_raw
--      before insert and assigned status = 'DUPLICATE'.
--      Duplicate rows are skipped by load_ledger_lines()
--      which filters on status = 'PENDING' only.
--
--   2. OVERDRAFT: amount exceeds sender opening balance.
--      Applies to TRANSFER, CASH_OUT, DEBIT only.
--      Assigned status = 'FLAGGED'.
--
--   DUPLICATE is checked before OVERDRAFT in CASE logic.
--   Order matters — first matching condition wins.
--   A row cannot be both DUPLICATE and FLAGGED.
--
-- Status Values:
--   PENDING   = Ready for ledger processing
--   DUPLICATE = Already processed, skip
--   FLAGGED   = Anomaly detected, needs review
--
-- Audit:
--   All runs logged to etl_log with row counts,
--   per-type breakdowns, and success/failure status.
--   paysim_raw.is_processed set to TRUE after load.
--
-- Idempotency:
--   Safe to rerun. is_processed = FALSE filter ensures
--   only unprocessed rows are loaded. Duplicate detection
--   provides additional protection against double inserts.
--
-- Usage:
--   CALL load_journal_entries();
-- ============================================================

CREATE OR REPLACE PROCEDURE load_journal_entries()
LANGUAGE plpgsql
AS $$
DECLARE
    v_rows_total        INT := 0;
    v_rows_by_type      RECORD;
    v_log_id            INT;
    v_error_message     TEXT;
BEGIN
    -- --------------------------------------------------------
    -- Create ETL log entry for this run
    -- --------------------------------------------------------
    INSERT INTO etl_log (process_name, status, message)
    VALUES ('load_journal_entries', 'PARTIAL', 'Run started')
    RETURNING etl_log_id INTO v_log_id;

    -- --------------------------------------------------------
    -- Step 1: Flag duplicates in paysim_raw BEFORE insert
    -- Marks any unprocessed row whose paysim_raw_id
    -- already exists as a transaction_id in journal_entries.
    -- Runs before the main INSERT so the CASE statement
    -- can reference anomaly_flag to assign DUPLICATE status.
    -- --------------------------------------------------------
    UPDATE paysim_raw
    SET anomaly_flag = 'DUPLICATE: transaction_id already exists'
    WHERE is_processed = FALSE
    AND paysim_raw_id::text IN (
        SELECT transaction_id
        FROM journal_entries
        WHERE transaction_id IS NOT NULL
    );

    -- --------------------------------------------------------
    -- Step 2: Main INSERT: paysim_raw → journal_entries
    -- Unified CASE logic handles all anomaly types.
    -- DUPLICATE checked before OVERDRAFT — first match wins.
    -- anomaly_flag included in CTE to enable CASE reference.
    -- --------------------------------------------------------
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
        -- Status determination: DUPLICATE → FLAGGED → PENDING
        CASE
            WHEN rt.anomaly_flag LIKE 'DUPLICATE%'
                THEN 'DUPLICATE'
            WHEN rt.amount > rt.oldbalanceOrg
            AND rt.trans_type IN ('TRANSFER', 'CASH_OUT', 'DEBIT')
                THEN 'FLAGGED'
            ELSE 'PENDING'
        END,
        rt.trans_type || ' from ' || rt.nameOrig,
        -- Anomaly flag propagation
        CASE
            WHEN rt.anomaly_flag LIKE 'DUPLICATE%'
                THEN rt.anomaly_flag
            WHEN rt.amount > rt.oldbalanceOrg
            AND rt.trans_type IN ('TRANSFER', 'CASH_OUT', 'DEBIT')
                THEN 'OVERDRAFT: amount exceeds opening balance'
            ELSE NULL
        END
    FROM raw_transactions AS rt;

    -- Capture total rows inserted
    GET DIAGNOSTICS v_rows_total = ROW_COUNT;

    -- --------------------------------------------------------
    -- Step 3: Log breakdown by trans_type
    -- Must run BEFORE flipping is_processed to TRUE
    -- --------------------------------------------------------
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

    -- --------------------------------------------------------
    -- Step 4: Mark source rows as processed
    -- Only after successful journal_entries insert
    -- --------------------------------------------------------
    UPDATE paysim_raw
    SET is_processed = TRUE
    WHERE is_processed = FALSE;

    -- --------------------------------------------------------
    -- Step 5: Update ETL log to SUCCESS
    -- --------------------------------------------------------
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
    SET
        status  = 'FAILURE',
        message = 'Error: ' || v_error_message
    WHERE etl_log_id = v_log_id;

    RAISE;
END;
$$;
