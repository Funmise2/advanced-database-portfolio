SET search_path TO tosipay;

\echo
\echo '=== The STANDBY before promotion ==='
SELECT pg_is_in_recovery() AS is_standby, current_setting('port') AS port;
SELECT timeline_id FROM pg_control_checkpoint();
SELECT COUNT(*) AS transactions FROM txn;

\echo
\echo '=== Failover: promote the standby to a primary ==='
\set ECHO queries
SELECT pg_promote(true, 60);
\set ECHO none
SELECT pg_is_in_recovery() AS is_standby;
SHOW transaction_read_only;
CHECKPOINT;
SELECT timeline_id FROM pg_control_checkpoint();
\echo 'The server has left recovery and started a new timeline.'

\echo
\echo '=== The promoted server now accepts payments ==='
SELECT 'P5-P-' || to_char(clock_timestamp(), 'YYYYMMDD-HH24MISS') AS ref \gset
\set ECHO queries
SELECT post_transfer(:'ref', '2010000021', '2010000046', 1500, 10, 'APP', 'Paid after failover') AS txn_id \gset
\set ECHO none
SELECT t.txn_id, t.reference, t.status, t.amount
  FROM txn t
 WHERE t.txn_id = :txn_id;
SELECT COUNT(*) AS transactions FROM txn;
