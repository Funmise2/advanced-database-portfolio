-- =====================================================================
-- TosiPay - Portfolio 3, example 3: double spend (WINDOW A)
--
-- Adaeze Okafor's wallet (2010000013) is used from two places at once:
-- the app (window A) and USSD (window B). Each payment is 60% of the
-- balance, so only one of them should be allowed.
--
-- Part 1: an early design that reads the balance, checks it, and writes
--         the new figure back, with no lock and no ledger.
-- Part 2: the same two payments through post_transfer(), which locks
--         the account with SELECT ... FOR UPDATE.
--
-- Start window B first, then this window, then follow the prompts:
--   psql -U postgres -d tosipay -f portfolio-3-transactions-concurrency/3-double-spend-window-a.sql
--
-- Needs post-transfer.sql. Part 1 repairs itself from the ledger;
-- part 2 really moves money (60% of Adaeze's wallet each run).
-- =====================================================================
SET search_path TO tosipay;

\echo
\echo '=== DOUBLE SPEND - WINDOW A: Adaeze pays from the app ==='
\echo
\echo '##### PART 1: read, check, write back (no lock) #####'
\prompt 'Once window B is waiting at its first prompt, press Enter here for step 1: ' go

\set ECHO queries
BEGIN;
SELECT a.balance AS seen_a FROM account a WHERE a.account_number = '2010000013' \gset
SELECT round(:seen_a * 0.6, 0) AS amount_a \gset
\set ECHO none
\echo 'Window A sees NGN' :seen_a 'and approves a payment of NGN' :amount_a '(enough money).'
\echo
\echo '>>> Next: step 2 in window B'
\prompt 'Do step 2 in window B first, then press Enter here for step 3: ' go

\set ECHO queries
UPDATE account SET balance = :seen_a - :amount_a WHERE account_number = '2010000013';
COMMIT;
\set ECHO none
\echo 'Window A saved' :seen_a '-' :amount_a 'and committed.'
\echo
\echo '>>> Next: step 4 in window B'
\prompt 'Do step 4 in window B first, then press Enter here for step 5: ' go

\echo
\echo '##### PART 2: the same payments through post_transfer() #####'
SELECT 'P3-DA-' || to_char(clock_timestamp(), 'YYYYMMDD-HH24MISS') AS ref_a \gset
\set ECHO queries
BEGIN;
SELECT a.balance AS seen_a FROM account a WHERE a.account_number = '2010000013' \gset
SELECT round(:seen_a * 0.6, 0) AS amount_a \gset
SELECT post_transfer(:'ref_a', '2010000013', '2010000046', :amount_a, 10, 'APP', 'Phone purchase') AS txn_a \gset
\set ECHO none
SELECT t.reference, t.status, t.amount FROM txn t WHERE t.txn_id = :txn_a;
\echo 'Posted but not committed. post_transfer() holds a row lock on the wallet until COMMIT.'
\echo
\echo '>>> Next: step 6 in window B. Window B will wait.'
\prompt 'Do step 6 in window B first (it will wait), then press Enter here for step 7: ' go

\set ECHO queries
COMMIT;
\set ECHO none
\echo 'Window A committed and released the lock.'
\echo
\echo '>>> Next: look at window B, which has now carried on by itself.'
