SET search_path TO tosipay;

\echo
\echo '=== Connected to the STANDBY (port 5433) ==='
SELECT pg_is_in_recovery() AS is_standby, current_setting('port') AS port;
SHOW transaction_read_only;

\timing on
\echo
\echo '=== Nightly reconciliation (Portfolio 2, Q8d): customer and agent accounts with postings on 29 August ==='
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
\echo '=== Balance sheet (Portfolio 3, example 4) in one query ==='
SELECT SUM(a.balance) FILTER (WHERE a.owner_kind <> 'SYSTEM') AS owed_to_customers_and_agents,
       SUM(a.balance) FILTER (WHERE a.owner_kind = 'SYSTEM')  AS system_accounts,
       SUM(a.balance)                                         AS must_be_zero
  FROM account a;
\timing off

\echo
\echo '=== A payment sent to the standby by mistake ==='
\set ECHO queries
SELECT post_transfer('P5-RO-' || to_char(clock_timestamp(), 'YYYYMMDD-HH24MISS'), '2010000021', '2010000046', 1000, 10, 'APP', 'Sent to the wrong server');
UPDATE account SET balance = balance + 1000000 WHERE account_number = '2010000021';
\set ECHO none
\echo 'Both are refused: the standby only accepts reads. Every change must go through the primary.'
