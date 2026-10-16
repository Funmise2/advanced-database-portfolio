-- =====================================================================
-- TosiPay - Portfolio 2: indexes
--
-- Each index targets a full table scan seen in evidence/plans_before.txt.
-- Run after generate-data.sql, then capture the plans again:
--   psql -U postgres -d tosipay -f portfolio-2-query-optimisation/indexes.sql
--
-- Re-runnable: every index uses IF NOT EXISTS.
-- =====================================================================
\set ON_ERROR_STOP on
\timing on
SET search_path TO tosipay;

-- ---------------------------------------------------------------------
-- ledger_entry (2.3M rows)
-- ---------------------------------------------------------------------

-- Q1 mini statement: find one account's entries and read them newest
-- first. The index is already in (posted_at, entry_id) order, so the
-- planner can scan it backwards and stop after 10 rows (no sort).
CREATE INDEX IF NOT EXISTS idx_ledger_account_posted
    ON ledger_entry (account_id, posted_at, entry_id);

-- Q4 dispute lookup: the ledger lines of one transaction. Also used by
-- the trg_ledger_balanced trigger, which sums the lines of a txn_id
-- on every insert.
CREATE INDEX IF NOT EXISTS idx_ledger_txn
    ON ledger_entry (txn_id);

-- ---------------------------------------------------------------------
-- txn (900k rows)
-- ---------------------------------------------------------------------

-- Q2 daily limit, Q3 customer history, Q5 agent report: money sent from
-- one account in a time window. Equality column first, range column second.
CREATE INDEX IF NOT EXISTS idx_txn_source_created
    ON txn (source_account_id, created_at);

-- Q3 and Q5: money received by one account in a time window.
CREATE INDEX IF NOT EXISTS idx_txn_destination_created
    ON txn (destination_account_id, created_at);

-- Q6 operations dashboard: only ~3% of transactions fail, so a partial
-- index on just those rows is small and is only touched when a
-- transaction fails.
CREATE INDEX IF NOT EXISTS idx_txn_failed_created
    ON txn (created_at)
    WHERE status = 'FAILED';

-- Q7 monthly report: a month of transactions. txn rows are inserted in
-- time order, so created_at follows the physical row order. A BRIN index
-- stores only the min/max created_at per block range, which makes it
-- tiny compared with a B-tree, and is ideal for date range reports.
CREATE INDEX IF NOT EXISTS idx_txn_created_brin
    ON txn USING brin (created_at);

-- ---------------------------------------------------------------------
-- account (131k rows): foreign keys PostgreSQL does not index by itself
-- ---------------------------------------------------------------------

-- Q3: a customer's accounts.
CREATE INDEX IF NOT EXISTS idx_account_customer
    ON account (customer_id);

-- Q5: an agent's float account.
CREATE INDEX IF NOT EXISTS idx_account_agent
    ON account (agent_id);

ANALYZE ledger_entry;
ANALYZE txn;
ANALYZE account;

\echo '--- Index sizes ---'
SELECT c.relname                                   AS index_name,
       t.relname                                   AS table_name,
       am.amname                                   AS index_type,
       pg_size_pretty(pg_relation_size(c.oid))     AS index_size,
       pg_size_pretty(pg_relation_size(t.oid))     AS table_size
  FROM pg_index i
  JOIN pg_class c ON c.oid = i.indexrelid
  JOIN pg_class t ON t.oid = i.indrelid
  JOIN pg_am am   ON am.oid = c.relam
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname = 'tosipay'
   AND c.relname LIKE 'idx\_%'
 ORDER BY pg_relation_size(c.oid) DESC;
