SET search_path TO tosipay;

\echo
\echo '=== On the STANDBY: it falls behind (replay paused, as if the server were overloaded) ==='
SELECT pg_is_in_recovery() AS is_standby, current_setting('port') AS port;
\set ECHO queries
SELECT pg_wal_replay_pause();
\set ECHO none
SELECT pg_get_wal_replay_pause_state() AS replay_state;

\connect tosipay postgres localhost 5432
SET search_path TO tosipay;

\echo
\echo '=== On the PRIMARY: Tunde pays Chinedu NGN 1,000 ==='
SELECT 'P5-S-' || to_char(clock_timestamp(), 'YYYYMMDD-HH24MISS') AS ref \gset
\set ECHO queries
SELECT post_transfer(:'ref', '2010000021', '2010000046', 1000, 10, 'APP', 'Stale read test') AS txn_id \gset
\set ECHO none
SELECT a.balance AS tunde_balance_on_primary
  FROM account a
 WHERE a.account_number = '2010000021';
SELECT application_name, state,
       pg_wal_lsn_diff(sent_lsn, replay_lsn) AS bytes_received_but_not_applied
  FROM pg_stat_replication;

\connect tosipay postgres localhost 5433
SET search_path TO tosipay;

\echo
\echo '=== On the STANDBY: Tunde checks his balance in the app, and the app reads from the standby ==='
SELECT a.balance AS tunde_balance_on_standby
  FROM account a
 WHERE a.account_number = '2010000021';
SELECT COUNT(*) AS payments_with_this_reference FROM txn t WHERE t.reference = :'ref';
SELECT pg_last_wal_receive_lsn() AS received_lsn,
       pg_last_wal_replay_lsn()  AS applied_lsn;
\echo 'The standby has received the change but not applied it. Tunde sees his old balance: a stale read.'

\echo
\echo '=== On the STANDBY: replay resumes ==='
\set ECHO queries
SELECT pg_wal_replay_resume();
SELECT pg_sleep(1);
\set ECHO none
SELECT a.balance AS tunde_balance_on_standby
  FROM account a
 WHERE a.account_number = '2010000021';
SELECT COUNT(*) AS payments_with_this_reference FROM txn t WHERE t.reference = :'ref';
SELECT pg_last_wal_receive_lsn() = pg_last_wal_replay_lsn() AS caught_up;
\echo 'The standby has caught up and agrees with the primary again: eventual consistency.'
