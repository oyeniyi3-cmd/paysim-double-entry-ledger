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
--   Overdraft transactions flagged automatically:
--   amount > oldbalanceOrg → status = 'FLAGGED'
--   Applies to: TRANSFER, CASH_OUT, DEBIT only.
--   CASH_IN and PAYMENT cannot overdraft by definition.
--
-- Audit:
--   All runs logged to etl_log with row counts,
--   per-type breakdowns, and success/failure status.
--   paysim_raw.is_processed set to TRUE after load.
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
    -- Main INSERT: paysim_raw → journal_entries
    -- One journal entry per unprocessed paysim_raw row.
    -- Anomaly detection embedded in CASE logic.
    -- --------------------------------------------------------
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

    -- --------------------------------------------------------
    -- Log breakdown by trans_type
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
    -- Mark source rows as processed
    -- Only after successful journal_entries insert
    -- --------------------------------------------------------
    UPDATE paysim_raw
    SET is_processed = TRUE
    WHERE is_processed = FALSE;

    -- --------------------------------------------------------
    -- Update ETL log to SUCCESS
    -- --------------------------------------------------------
    UPDATE etl_log
    SET
        status          = 'SUCCESS',
        rows_processed  = v_rows_total,
        message         = 'Completed successfully. '
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
