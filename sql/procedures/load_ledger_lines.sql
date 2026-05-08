-- ============================================================
-- Financial Ledger Platform
-- Stored Procedure: load_ledger_lines
-- Database: PostgreSQL 14+
--
-- Purpose:
--   ETL procedure that transforms journal_entries into
--   double-entry ledger lines in ledger_lines table.
--
-- Data Lineage:
--   paysim_raw + journal_entries → ledger_lines
--
-- Transaction Type Handling:
--   CASH_IN  : 4 lines, no fee
--   CASH_OUT : 6 lines, fee applied
--   TRANSFER : 6 lines, fee applied
--   PAYMENT  : 4 lines, no fee
--   DEBIT    : 4 lines, no fee
--
-- Fee Logic:
--   Fee rate looked up dynamically from fee_schedule table.
--   Fee calculated as: ROUND(amount * fee_rate, 2)
--   Fee reset to 0 on each loop iteration to prevent
--   bleed-over between transaction types.
--
-- Anomaly Handling:
--   FLAGGED journal entries are skipped (WHERE status='PENDING')
--   Unknown transaction types are flagged for investigation.
--
-- Audit:
--   All runs logged to etl_log with row counts and status.
--   journal_entries.status updated PENDING → POSTED on success.
-- ============================================================

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
    -- --------------------------------------------------------
    -- Create ETL log entry for this run
    -- --------------------------------------------------------
    INSERT INTO etl_log (process_name, status, message)
    VALUES ('load_ledger_lines', 'PARTIAL', 'Run started')
    RETURNING etl_log_id INTO v_log_id;

    -- --------------------------------------------------------
    -- Main loop: one iteration per PENDING journal entry
    -- --------------------------------------------------------
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
        -- Reset fee on every iteration
        -- Prevents fee bleed-over between transaction types
        v_fee_amount := 0;
        v_fee_rate   := 0;

        -- --------------------------------------------------------
        -- CASH_IN
        -- Source: External Counterparty
        -- Destination: Customer (nameOrig)
        -- Fee: None
        -- Lines: 4
        -- --------------------------------------------------------
        IF rec.trans_type = 'CASH_IN' THEN

            -- Line 1: DEBIT External Counterparty
            INSERT INTO ledger_lines (
                journal_entry_id, account_id, currency_code,
                entry_type, amount, entry_sequence)
            VALUES (
                rec.journal_entry_id,
                (SELECT account_id FROM accounts
                    WHERE account_name = 'External Counterparty'),
                1,
                'DEBIT',
                rec.amount,
                1);

            -- Line 2: CREDIT Main Settlement Suspense
            INSERT INTO ledger_lines (
                journal_entry_id, account_id, currency_code,
                entry_type, amount, entry_sequence)
            VALUES (
                rec.journal_entry_id,
                (SELECT account_id FROM accounts
                    WHERE account_name = 'Main Settlement Suspense'),
                1,
                'CREDIT',
                rec.amount,
                2);

            -- Line 3: DEBIT Main Settlement Suspense
            INSERT INTO ledger_lines (
                journal_entry_id, account_id, currency_code,
                entry_type, amount, entry_sequence)
            VALUES (
                rec.journal_entry_id,
                (SELECT account_id FROM accounts
                    WHERE account_name = 'Main Settlement Suspense'),
                1,
                'DEBIT',
                rec.amount,
                3);

            -- Line 4: CREDIT Customer (nameOrig)
            INSERT INTO ledger_lines (
                journal_entry_id, account_id, currency_code,
                entry_type, amount, entry_sequence)
            VALUES (
                rec.journal_entry_id,
                (SELECT account_id FROM accounts
                    WHERE account_name = rec.nameOrig),
                1,
                'CREDIT',
                rec.amount,
                4);

            -- Mark journal entry as POSTED
            UPDATE journal_entries
            SET status = 'POSTED'
            WHERE journal_entry_id = rec.journal_entry_id;

        -- --------------------------------------------------------
        -- CASH_OUT
        -- Source: Customer (nameOrig)
        -- Destination: External Counterparty
        -- nameDest preserved in journal_entries.reference_id
        -- Fee: Percentage of transaction amount
        -- Lines: 6
        -- --------------------------------------------------------
        ELSIF rec.trans_type = 'CASH_OUT' THEN

            -- Calculate fee once for reuse across all lines
            SELECT ROUND(rec.amount * fs.fee_rate, 2) INTO v_fee_amount
            FROM fee_schedule fs
            WHERE fs.trans_type = 'CASH_OUT'
            AND fs.is_active = TRUE;

            -- Line 1: DEBIT Customer (gross amount including fee)
            INSERT INTO ledger_lines (
                journal_entry_id, account_id, currency_code,
                entry_type, amount, entry_sequence)
            VALUES (
                rec.journal_entry_id,
                (SELECT account_id FROM accounts
                    WHERE account_name = rec.nameOrig),
                1,
                'DEBIT',
                rec.amount + v_fee_amount,
                1);

            -- Line 2: CREDIT Main Settlement Suspense (gross)
            INSERT INTO ledger_lines (
                journal_entry_id, account_id, currency_code,
                entry_type, amount, entry_sequence)
            VALUES (
                rec.journal_entry_id,
                (SELECT account_id FROM accounts
                    WHERE account_name = 'Main Settlement Suspense'),
                1,
                'CREDIT',
                rec.amount + v_fee_amount,
                2);

            -- Line 3: DEBIT Main Settlement Suspense (net amount)
            INSERT INTO ledger_lines (
                journal_entry_id, account_id, currency_code,
                entry_type, amount, entry_sequence)
            VALUES (
                rec.journal_entry_id,
                (SELECT account_id FROM accounts
                    WHERE account_name = 'Main Settlement Suspense'),
                1,
                'DEBIT',
                rec.amount,
                3);

            -- Line 4: CREDIT External Counterparty (net amount)
            INSERT INTO ledger_lines (
                journal_entry_id, account_id, currency_code,
                entry_type, amount, entry_sequence)
            VALUES (
                rec.journal_entry_id,
                (SELECT account_id FROM accounts
                    WHERE account_name = 'External Counterparty'),
                1,
                'CREDIT',
                rec.amount,
                4);

            -- Line 5: DEBIT Main Settlement Suspense (fee)
            INSERT INTO ledger_lines (
                journal_entry_id, account_id, currency_code,
                entry_type, amount, entry_sequence)
            VALUES (
                rec.journal_entry_id,
                (SELECT account_id FROM accounts
                    WHERE account_name = 'Main Settlement Suspense'),
                1,
                'DEBIT',
                v_fee_amount,
                5);

            -- Line 6: CREDIT Platform Fee Revenue (fee)
            INSERT INTO ledger_lines (
                journal_entry_id, account_id, currency_code,
                entry_type, amount, entry_sequence)
            VALUES (
                rec.journal_entry_id,
                (SELECT account_id FROM accounts
                    WHERE account_name = 'Platform Fee Revenue'),
                1,
                'CREDIT',
                v_fee_amount,
                6);

            -- Mark journal entry as POSTED
            UPDATE journal_entries
            SET status = 'POSTED'
            WHERE journal_entry_id = rec.journal_entry_id;

        -- --------------------------------------------------------
        -- TRANSFER
        -- Source: Customer (nameOrig)
        -- Destination: Customer (nameDest)
        -- Fee: Percentage of transaction amount
        -- Lines: 6
        -- --------------------------------------------------------
        ELSIF rec.trans_type = 'TRANSFER' THEN

            -- Calculate fee once for reuse across all lines
            SELECT ROUND(rec.amount * fs.fee_rate, 2) INTO v_fee_amount
            FROM fee_schedule fs
            WHERE fs.trans_type = 'TRANSFER'
            AND fs.is_active = TRUE;

            -- Line 1: DEBIT Customer (gross amount including fee)
            INSERT INTO ledger_lines (
                journal_entry_id, account_id, currency_code,
                entry_type, amount, entry_sequence)
            VALUES (
                rec.journal_entry_id,
                (SELECT account_id FROM accounts
                    WHERE account_name = rec.nameOrig),
                1,
                'DEBIT',
                rec.amount + v_fee_amount,
                1);

            -- Line 2: CREDIT Main Settlement Suspense (gross)
            INSERT INTO ledger_lines (
                journal_entry_id, account_id, currency_code,
                entry_type, amount, entry_sequence)
            VALUES (
                rec.journal_entry_id,
                (SELECT account_id FROM accounts
                    WHERE account_name = 'Main Settlement Suspense'),
                1,
                'CREDIT',
                rec.amount + v_fee_amount,
                2);

            -- Line 3: DEBIT Main Settlement Suspense (net amount)
            INSERT INTO ledger_lines (
                journal_entry_id, account_id, currency_code,
                entry_type, amount, entry_sequence)
            VALUES (
                rec.journal_entry_id,
                (SELECT account_id FROM accounts
                    WHERE account_name = 'Main Settlement Suspense'),
                1,
                'DEBIT',
                rec.amount,
                3);

            -- Line 4: CREDIT Customer (nameDest)
            INSERT INTO ledger_lines (
                journal_entry_id, account_id, currency_code,
                entry_type, amount, entry_sequence)
            VALUES (
                rec.journal_entry_id,
                (SELECT account_id FROM accounts
                    WHERE account_name = rec.nameDest),
                1,
                'CREDIT',
                rec.amount,
                4);

            -- Line 5: DEBIT Main Settlement Suspense (fee)
            INSERT INTO ledger_lines (
                journal_entry_id, account_id, currency_code,
                entry_type, amount, entry_sequence)
            VALUES (
                rec.journal_entry_id,
                (SELECT account_id FROM accounts
                    WHERE account_name = 'Main Settlement Suspense'),
                1,
                'DEBIT',
                v_fee_amount,
                5);

            -- Line 6: CREDIT Platform Fee Revenue (fee)
            INSERT INTO ledger_lines (
                journal_entry_id, account_id, currency_code,
                entry_type, amount, entry_sequence)
            VALUES (
                rec.journal_entry_id,
                (SELECT account_id FROM accounts
                    WHERE account_name = 'Platform Fee Revenue'),
                1,
                'CREDIT',
                v_fee_amount,
                6);

            -- Mark journal entry as POSTED
            UPDATE journal_entries
            SET status = 'POSTED'
            WHERE journal_entry_id = rec.journal_entry_id;

        -- --------------------------------------------------------
        -- PAYMENT
        -- Source: Customer (nameOrig)
        -- Destination: External Counterparty (merchant)
        -- All merchant accounts (M-prefix) map to EXTERNAL type
        -- Merchant balances not tracked per PaySim design
        -- Fee: None (merchant absorbs cost)
        -- Lines: 4
        -- --------------------------------------------------------
        ELSIF rec.trans_type = 'PAYMENT' THEN

            -- Line 1: DEBIT Customer (nameOrig)
            INSERT INTO ledger_lines (
                journal_entry_id, account_id, currency_code,
                entry_type, amount, entry_sequence)
            VALUES (
                rec.journal_entry_id,
                (SELECT account_id FROM accounts
                    WHERE account_name = rec.nameOrig),
                1,
                'DEBIT',
                rec.amount,
                1);

            -- Line 2: CREDIT Main Settlement Suspense
            INSERT INTO ledger_lines (
                journal_entry_id, account_id, currency_code,
                entry_type, amount, entry_sequence)
            VALUES (
                rec.journal_entry_id,
                (SELECT account_id FROM accounts
                    WHERE account_name = 'Main Settlement Suspense'),
                1,
                'CREDIT',
                rec.amount,
                2);

            -- Line 3: DEBIT Main Settlement Suspense
            INSERT INTO ledger_lines (
                journal_entry_id, account_id, currency_code,
                entry_type, amount, entry_sequence)
            VALUES (
                rec.journal_entry_id,
                (SELECT account_id FROM accounts
                    WHERE account_name = 'Main Settlement Suspense'),
                1,
                'DEBIT',
                rec.amount,
                3);

            -- Line 4: CREDIT External Counterparty
            INSERT INTO ledger_lines (
                journal_entry_id, account_id, currency_code,
                entry_type, amount, entry_sequence)
            VALUES (
                rec.journal_entry_id,
                (SELECT account_id FROM accounts
                    WHERE account_name = 'External Counterparty'),
                1,
                'CREDIT',
                rec.amount,
                4);

            -- Mark journal entry as POSTED
            UPDATE journal_entries
            SET status = 'POSTED'
            WHERE journal_entry_id = rec.journal_entry_id;

        -- --------------------------------------------------------
        -- DEBIT
        -- Source: Customer (nameOrig)
        -- Destination: Customer (nameDest)
        -- In-house transfer — no external routing
        -- Fee: None
        -- Lines: 4
        -- --------------------------------------------------------
        ELSIF rec.trans_type = 'DEBIT' THEN

            -- Line 1: DEBIT Customer (nameOrig)
            INSERT INTO ledger_lines (
                journal_entry_id, account_id, currency_code,
                entry_type, amount, entry_sequence)
            VALUES (
                rec.journal_entry_id,
                (SELECT account_id FROM accounts
                    WHERE account_name = rec.nameOrig),
                1,
                'DEBIT',
                rec.amount,
                1);

            -- Line 2: CREDIT Main Settlement Suspense
            INSERT INTO ledger_lines (
                journal_entry_id, account_id, currency_code,
                entry_type, amount, entry_sequence)
            VALUES (
                rec.journal_entry_id,
                (SELECT account_id FROM accounts
                    WHERE account_name = 'Main Settlement Suspense'),
                1,
                'CREDIT',
                rec.amount,
                2);

            -- Line 3: DEBIT Main Settlement Suspense
            INSERT INTO ledger_lines (
                journal_entry_id, account_id, currency_code,
                entry_type, amount, entry_sequence)
            VALUES (
                rec.journal_entry_id,
                (SELECT account_id FROM accounts
                    WHERE account_name = 'Main Settlement Suspense'),
                1,
                'DEBIT',
                rec.amount,
                3);

            -- Line 4: CREDIT Customer (nameDest)
            INSERT INTO ledger_lines (
                journal_entry_id, account_id, currency_code,
                entry_type, amount, entry_sequence)
            VALUES (
                rec.journal_entry_id,
                (SELECT account_id FROM accounts
                    WHERE account_name = rec.nameDest),
                1,
                'CREDIT',
                rec.amount,
                4);

            -- Mark journal entry as POSTED
            UPDATE journal_entries
            SET status = 'POSTED'
            WHERE journal_entry_id = rec.journal_entry_id;

        -- --------------------------------------------------------
        -- UNKNOWN TRANSACTION TYPE
        -- Flag for investigation rather than silently skipping.
        -- Defensive coding for data quality assurance.
        -- --------------------------------------------------------
        ELSE
            UPDATE journal_entries
            SET
                status       = 'FLAGGED',
                anomaly_flag = 'UNKNOWN TRANS_TYPE: ' || rec.trans_type
            WHERE journal_entry_id = rec.journal_entry_id;

        END IF;

        -- Increment row counter on every iteration
        v_rows_total := v_rows_total + 1;

    END LOOP;

    -- --------------------------------------------------------
    -- Update ETL log to SUCCESS
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
