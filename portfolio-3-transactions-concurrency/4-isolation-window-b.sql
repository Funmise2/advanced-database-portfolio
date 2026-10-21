SET search_path TO tosipay;

\echo
\echo '=== ISOLATION - WINDOW B: Tunde sends money to his bank account ==='
\echo
\prompt 'Do step 1 in window A first, then press Enter here for step 2: ' go

SELECT 'P3-IB1-' || to_char(clock_timestamp(), 'YYYYMMDD-HH24MISS') AS ref_1 \gset
\set ECHO queries
SELECT post_transfer(:'ref_1', '2010000021', '0000000001', 20000, 10, 'APP', 'Transfer to bank account') AS txn_1 \gset
\set ECHO none
SELECT t.reference, t.status, t.amount, t.fee FROM txn t WHERE t.txn_id = :txn_1;
\echo 'Saved and committed straight away (autocommit): NGN 20,010 moved from customer money to SYSTEM accounts.'
\echo
\echo '>>> Next: step 3 in window A'
\prompt 'Do step 3 in window A first, then press Enter here for step 4: ' go

SELECT 'P3-IB2-' || to_char(clock_timestamp(), 'YYYYMMDD-HH24MISS') AS ref_2 \gset
\set ECHO queries
SELECT post_transfer(:'ref_2', '2010000021', '0000000001', 20000, 10, 'APP', 'Transfer to bank account') AS txn_2 \gset
\set ECHO none
SELECT t.reference, t.status, t.amount, t.fee FROM txn t WHERE t.txn_id = :txn_2;
\echo 'A second transfer of NGN 20,010 is saved and committed.'
\echo
\echo '>>> Next: step 5 in window A'
\echo
\echo '=== Done in window B ==='
