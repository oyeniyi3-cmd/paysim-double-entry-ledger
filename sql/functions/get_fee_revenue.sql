-- ============================================================
-- Financial Ledger Platform
-- Function: get_fee_revenue
-- Database: PostgreSQL 14+
--
-- Purpose:
--   Reporting function returning fee revenue collected
--   within a specified date range, broken down by
--   transaction type and date.
--
-- Design Decision:
--   Implemented as a FUNCTION (not PROCEDURE) because
--   it returns a result set and is called inline in
--   SELECT statements. PROCEDURE is reserved for
--   data modification operations.
--
-- Fee Revenue Source:
--   Fee revenue is not stored in a separate table.
--   It is derived from ledger_lines where:
--     account = 'Platform Fee Revenue'
--     entry_type = 'CREDIT'
--   This avoids data duplication — the ledger is the
--   system of record for all financial activity.
--
-- Parameters:
--   p_start_date : Start of date range (inclusive)
--   p_end_date   : End of date range (inclusive)
--                  Defaults to CURRENT_DATE if omitted
--
-- Usage:
--   -- Single date
--   SELECT * FROM get_fee_revenue('2024-01-01', '2024-01-01');
--
--   -- Date range
--   SELECT * FROM get_fee_revenue('2024-01-01', '2024-01-31');
--
--   -- Month to date
--   SELECT * FROM get_fee_revenue(
--       DATE_TRUNC('month', CURRENT_DATE)::DATE,
--       CURRENT_DATE
--   );
--
--   -- All time
--   SELECT * FROM get_fee_revenue('2000-01-01', CURRENT_DATE);
--
--   -- Single date using default end date
--   SELECT * FROM get_fee_revenue('2024-01-01');
-- ============================================================

CREATE OR REPLACE FUNCTION get_fee_revenue(
    p_start_date    DATE,
    p_end_date      DATE DEFAULT CURRENT_DATE
)
RETURNS TABLE (
    fee_date        DATE,
    trans_type      TEXT,
    fees_collected  NUMERIC(18,2)
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT
        DATE(ll.created_at)             AS fee_date,
        je.trans_type                   AS trans_type,
        SUM(ll.amount)::NUMERIC(18,2)   AS fees_collected
    FROM ledger_lines ll
    JOIN journal_entries je
        ON je.journal_entry_id = ll.journal_entry_id
    JOIN accounts a
        ON a.account_id = ll.account_id
    WHERE a.account_name = 'Platform Fee Revenue'
    AND ll.entry_type = 'CREDIT'
    AND DATE(ll.created_at) BETWEEN p_start_date AND p_end_date
    GROUP BY DATE(ll.created_at), je.trans_type
    ORDER BY DATE(ll.created_at) DESC;
END;
$$;
