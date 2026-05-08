-- ============================================================
-- Financial Ledger Platform
-- Schema Inspection Queries
-- Database: PostgreSQL 14+
--
-- Purpose:
--   Programmatic inspection of database schema objects
--   using ANSI-standard information_schema views.
--   Compatible with PostgreSQL, MySQL, and most other
--   relational databases.
--
-- Usage:
--   Run individual sections as needed in pgAdmin Query Tool.
--   All queries are read-only — safe to run at any time.
-- ============================================================


-- ------------------------------------------------------------
-- 1. ALL TABLES
-- Lists all user-created tables in the public schema.
-- ------------------------------------------------------------
SELECT 
    table_name,
    table_type
FROM information_schema.tables
WHERE table_schema = 'public'
ORDER BY table_name;


-- ------------------------------------------------------------
-- 2. COLUMNS FOR A SPECIFIC TABLE
-- Replace 'accounts' with any table name to inspect.
-- Returns column names, data types, nullability, defaults.
-- ------------------------------------------------------------
SELECT 
    column_name,
    data_type,
    is_nullable,
    column_default
FROM information_schema.columns
WHERE table_name = 'accounts'
ORDER BY ordinal_position;


-- ------------------------------------------------------------
-- 3. ALL COLUMNS ACROSS ALL TABLES
-- Full column inventory for every table in the schema.
-- Useful for documentation and impact analysis.
-- ------------------------------------------------------------
SELECT
    table_name,
    column_name,
    data_type,
    is_nullable,
    column_default
FROM information_schema.columns
WHERE table_schema = 'public'
ORDER BY table_name, ordinal_position;


-- ------------------------------------------------------------
-- 4. ALL CONSTRAINTS
-- Returns CHECK, UNIQUE, PRIMARY KEY, and FOREIGN KEY
-- constraints across all tables.
-- ------------------------------------------------------------
SELECT
    tc.table_name,
    tc.constraint_name,
    tc.constraint_type,
    kcu.column_name
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
    ON tc.constraint_name = kcu.constraint_name
WHERE tc.table_schema = 'public'
ORDER BY tc.table_name, tc.constraint_type;


-- ------------------------------------------------------------
-- 5. FOREIGN KEYS ONLY
-- Shows all foreign key relationships with source column
-- and referenced table/column. Useful for understanding
-- data lineage and dependency order for inserts/deletes.
-- ------------------------------------------------------------
SELECT
    tc.table_name           AS source_table,
    kcu.column_name         AS source_column,
    ccu.table_name          AS referenced_table,
    ccu.column_name         AS referenced_column,
    tc.constraint_name
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
    ON tc.constraint_name = kcu.constraint_name
JOIN information_schema.constraint_column_usage ccu
    ON tc.constraint_name = ccu.constraint_name
WHERE tc.constraint_type = 'FOREIGN KEY'
AND tc.table_schema = 'public'
ORDER BY tc.table_name;


-- ------------------------------------------------------------
-- 6. CHECK CONSTRAINTS
-- Lists all CHECK constraints with their definitions.
-- Useful for verifying business rules are enforced
-- at the database level.
-- ------------------------------------------------------------
SELECT
    tc.table_name,
    tc.constraint_name,
    cc.check_clause
FROM information_schema.table_constraints tc
JOIN information_schema.check_constraints cc
    ON tc.constraint_name = cc.constraint_name
WHERE tc.constraint_type = 'CHECK'
AND tc.table_schema = 'public'
ORDER BY tc.table_name;


-- ------------------------------------------------------------
-- 7. STORED PROCEDURES AND FUNCTIONS
-- Lists all stored procedures and functions in the schema.
-- ------------------------------------------------------------
SELECT 
    routine_name,
    routine_type,
    data_type       AS return_type,
    created         AS created_at
FROM information_schema.routines
WHERE routine_schema = 'public'
ORDER BY routine_type, routine_name;


-- ------------------------------------------------------------
-- 8. VIEWS
-- Lists all views with their full definitions.
-- ------------------------------------------------------------
SELECT 
    table_name          AS view_name,
    view_definition
FROM information_schema.views
WHERE table_schema = 'public'
ORDER BY table_name;


-- ------------------------------------------------------------
-- 9. TRIGGERS
-- Lists all triggers with their target tables,
-- triggering events, and timing (BEFORE/AFTER).
-- ------------------------------------------------------------
SELECT
    trigger_name,
    event_object_table  AS table_name,
    event_manipulation  AS trigger_event,
    action_timing       AS timing,
    action_statement
FROM information_schema.triggers
WHERE trigger_schema = 'public'
ORDER BY event_object_table, trigger_name;


-- ------------------------------------------------------------
-- 10. INDEXES
-- Lists all indexes including primary keys and
-- unique constraints. Uses pg_catalog rather than
-- information_schema as indexes are PostgreSQL-specific.
-- ------------------------------------------------------------
SELECT
    tablename       AS table_name,
    indexname       AS index_name,
    indexdef        AS index_definition
FROM pg_indexes
WHERE schemaname = 'public'
ORDER BY tablename, indexname;


-- ------------------------------------------------------------
-- 11. ROW COUNTS PER TABLE
-- Quick data volume check across all tables.
-- Useful for verifying ETL load completeness.
-- Note: Uses pg_stat_user_tables for performance.
-- For exact counts use SELECT COUNT(*) per table.
-- ------------------------------------------------------------
SELECT
    relname         AS table_name,
    n_live_tup      AS estimated_row_count
FROM pg_stat_user_tables
WHERE schemaname = 'public'
ORDER BY n_live_tup DESC;


-- ------------------------------------------------------------
-- 12. COMPLETE SCHEMA INVENTORY
-- Single query returning all schema objects by type.
-- Useful for README documentation and GitHub repo overview.
-- ------------------------------------------------------------
SELECT
    table_name      AS object_name,
    'TABLE'         AS object_type
FROM information_schema.tables
WHERE table_schema = 'public'

UNION ALL

SELECT 
    routine_name, 
    routine_type
FROM information_schema.routines
WHERE routine_schema = 'public'

UNION ALL

SELECT 
    table_name, 
    'VIEW'
FROM information_schema.views
WHERE table_schema = 'public'

UNION ALL

SELECT DISTINCT 
    trigger_name, 
    'TRIGGER'
FROM information_schema.triggers
WHERE trigger_schema = 'public'

ORDER BY object_type, object_name;


-- ------------------------------------------------------------
-- 13. TABLE DEPENDENCY ORDER
-- Shows tables in safe insert order based on
-- foreign key dependencies. Run this when rebuilding
-- the schema from scratch to determine correct
-- CREATE TABLE and INSERT sequence.
-- ------------------------------------------------------------
SELECT
    ccu.table_name      AS referenced_table,
    tc.table_name       AS dependent_table,
    kcu.column_name     AS foreign_key_column
FROM information_schema.table_constraints tc
JOIN information_schema.key_column_usage kcu
    ON tc.constraint_name = kcu.constraint_name
JOIN information_schema.constraint_column_usage ccu
    ON tc.constraint_name = ccu.constraint_name
WHERE tc.constraint_type = 'FOREIGN KEY'
AND tc.table_schema = 'public'
ORDER BY ccu.table_name, tc.table_name;
