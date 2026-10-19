-- =====================================================================
-- TosiPay - Portfolio 2: improving Q8 (nightly reconciliation)
--
-- Q8 did not get faster with indexes, because it adds up the whole
-- ledger. This script measures four ways to make it cheaper:
--   Q8a  the original query, as a baseline in the same session
--   Q8b  the same query with more work_mem for this job only
--   Q8c  a rewrite that only checks accounts with postings that day
--   Q8d  a running-balance check using balance_after
--   Q8e  the closed-system check that covers the SYSTEM accounts
--
-- Run after indexes.sql, with the plans shown:
--   psql -U postgres -d tosipay -v explain="EXPLAIN (ANALYZE, BUFFERS)" \
--        -f portfolio-2-query-optimisation/reconciliation.sql
-- =====================================================================
\if :{?explain} \else \set explain '' \endif
SET search_path TO tosipay;

\echo
\echo '=== Q8a. Original: every account against the full ledger ==='
:explain
SELECT a.account_id, a.balance AS stored_balance, l.ledger_balance
  FROM account a
  JOIN (SELECT account_id,
               SUM(CASE entry_type WHEN 'CREDIT' THEN amount ELSE -amount END) AS ledger_balance
          FROM ledger_entry
         GROUP BY account_id) l ON l.account_id = a.account_id
 WHERE a.balance <> l.ledger_balance;

\echo
\echo '=== Q8b. Same query with work_mem raised for this transaction only ==='
-- SET LOCAL only lasts until COMMIT, so live payments keep the default.
BEGIN;
SET LOCAL work_mem = '64MB';
:explain
SELECT a.account_id, a.balance AS stored_balance, l.ledger_balance
  FROM account a
  JOIN (SELECT account_id,
               SUM(CASE entry_type WHEN 'CREDIT' THEN amount ELSE -amount END) AS ledger_balance
          FROM ledger_entry
         GROUP BY account_id) l ON l.account_id = a.account_id
 WHERE a.balance <> l.ledger_balance;
COMMIT;

\echo
\echo '=== New index for Q8c: BRIN on ledger_entry.posted_at ==='
-- Ledger entries are inserted in posting order, so posted_at follows the
-- physical row order, the same reason the BRIN index on txn works for Q7.
\timing on
CREATE INDEX IF NOT EXISTS idx_ledger_posted_brin
    ON ledger_entry USING brin (posted_at);
\timing off
ANALYZE ledger_entry;
SELECT pg_size_pretty(pg_relation_size('idx_ledger_posted_brin')) AS index_size;

\echo
\echo '=== Q8c. Rewrite: only customer and agent accounts with postings on 29 August ==='
-- Accounts with no new postings cannot have drifted since the last run,
-- so only the day's accounts are checked. Each one's ledger is summed
-- through idx_ledger_account_posted.
:explain
WITH changed AS (
    SELECT DISTINCT l.account_id
      FROM ledger_entry l
     WHERE l.posted_at >= TIMESTAMPTZ '2026-08-29 00:00+01'
       AND l.posted_at <  TIMESTAMPTZ '2026-08-30 00:00+01'
)
SELECT a.account_id, a.balance AS stored_balance, s.ledger_balance
  FROM changed ch
  JOIN account a ON a.account_id = ch.account_id
 CROSS JOIN LATERAL (
       SELECT SUM(CASE l.entry_type WHEN 'CREDIT' THEN l.amount ELSE -l.amount END) AS ledger_balance
         FROM ledger_entry l
        WHERE l.account_id = a.account_id) s
 WHERE a.owner_kind <> 'SYSTEM'
   AND a.balance <> s.ledger_balance;

\echo
\echo '=== Q8d. Running-balance check: the same accounts against their latest balance_after ==='
-- Q8c still re-adds each account's whole history, and an account's
-- entries are spread across the table, so that means many random page
-- reads. balance_after already holds the running total at each posting,
-- so only the account's latest entry is needed: one backward index scan
-- on idx_ledger_account_posted and one row per account.
:explain
WITH changed AS (
    SELECT DISTINCT l.account_id
      FROM ledger_entry l
     WHERE l.posted_at >= TIMESTAMPTZ '2026-08-29 00:00+01'
       AND l.posted_at <  TIMESTAMPTZ '2026-08-30 00:00+01'
)
SELECT a.account_id, a.balance AS stored_balance, last_entry.balance_after
  FROM changed ch
  JOIN account a ON a.account_id = ch.account_id
 CROSS JOIN LATERAL (
       SELECT l.balance_after
         FROM ledger_entry l
        WHERE l.account_id = a.account_id
        ORDER BY l.posted_at DESC, l.entry_id DESC
        LIMIT 1) last_entry
 WHERE a.owner_kind <> 'SYSTEM'
   AND a.balance <> last_entry.balance_after;

\echo
\echo '--- How many accounts Q8c and Q8d checked, out of all accounts ---'
SELECT COUNT(DISTINCT l.account_id) AS accounts_checked,
       (SELECT COUNT(*) FROM account) AS all_accounts
  FROM ledger_entry l
  JOIN account a ON a.account_id = l.account_id
 WHERE l.posted_at >= TIMESTAMPTZ '2026-08-29 00:00+01'
   AND l.posted_at <  TIMESTAMPTZ '2026-08-30 00:00+01'
   AND a.owner_kind <> 'SYSTEM';

\echo
\echo '=== Q8e. SYSTEM accounts: the closed-system check (all balances must sum to 0) ==='
-- The settlement and fee accounts are touched by almost every transaction,
-- so summing their ledgers nightly would cost nearly as much as Q8a.
-- Because TosiPay is double-entry, the balances of all accounts must add
-- up to 0. If they do, and every customer and agent account matches its
-- ledger, the SYSTEM accounts are correct as a whole.
\timing on
SELECT SUM(a.balance) AS total_of_all_balances
  FROM account a;
