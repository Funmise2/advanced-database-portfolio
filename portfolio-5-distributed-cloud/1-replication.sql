SET search_path TO tosipay;

\echo
\echo '=== On the PRIMARY (port 5432): who is replicating from it ==='
SELECT pg_is_in_recovery() AS is_standby, current_setting('port') AS port;
SELECT application_name, state, sync_state, sent_lsn, replay_lsn, replay_lag
  FROM pg_stat_replication;

\echo
\echo '=== On the PRIMARY: Tunde pays Chinedu NGN 2,500 ==='
SELECT 'P5-R-' || to_char(clock_timestamp(), 'YYYYMMDD-HH24MISS') AS ref \gset
\set ECHO queries
SELECT post_transfer(:'ref', '2010000021', '2010000046', 2500, 10, 'APP', 'Replication test') AS txn_id \gset
\set ECHO none
SELECT t.txn_id, t.reference, t.status, t.amount, t.created_at
  FROM txn t
 WHERE t.reference = :'ref';
SELECT pg_current_wal_lsn() AS primary_lsn \gset
\echo 'Primary WAL position after the commit:' :primary_lsn

\connect tosipay postgres localhost 5433
SET search_path TO tosipay;
SELECT pg_sleep(1);

\echo
\echo '=== On the STANDBY (port 5433), one second later ==='
SELECT pg_is_in_recovery() AS is_standby, current_setting('port') AS port;
SELECT status, sender_port, latest_end_lsn
  FROM pg_stat_wal_receiver;
SELECT pg_last_wal_replay_lsn() AS standby_replay_lsn,
       pg_last_wal_replay_lsn() >= :'primary_lsn'::pg_lsn AS has_replayed_the_commit;
SELECT t.txn_id, t.reference, t.status, t.amount, t.created_at
  FROM txn t
 WHERE t.reference = :'ref';
SELECT a.account_number, a.balance
  FROM account a
 WHERE a.account_number IN ('2010000021', '2010000046')
 ORDER BY a.account_number;

\connect tosipay postgres localhost 5432
SET search_path TO tosipay;

\echo
\echo '=== The same balances on the PRIMARY ==='
SELECT a.account_number, a.balance
  FROM account a
 WHERE a.account_number IN ('2010000021', '2010000046')
 ORDER BY a.account_number;
