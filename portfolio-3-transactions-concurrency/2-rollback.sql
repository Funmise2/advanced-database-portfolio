-- =====================================================================
-- TosiPay - Portfolio 3, example 2: ROLLBACK
--
-- Part A: a business failure. Halima Sani (KYC Tier 1, daily limit
--         NGN 50,000) tries to send NGN 60,000. The attempt is saved as a
--         FAILED transaction and no money moves.
-- Part B: a technical failure. A hand-written correction forgets the
--         fee line, so debits do not equal credits. Every statement works,
--         but the deferred trg_ledger_balanced trigger rejects the
--         transaction at COMMIT and PostgreSQL rolls all of it back.
--
--   psql -U postgres -d tosipay -f portfolio-3-transactions-concurrency/2-rollback.sql
--
-- Needs post-transfer.sql. Re-runnable: each run uses new references.
-- =====================================================================
SET search_path TO tosipay;

SELECT 'P3-RA-' || to_char(clock_timestamp(), 'YYYYMMDD-HH24MISS') AS ref_a,
       'P3-RB-' || to_char(clock_timestamp(), 'YYYYMMDD-HH24MISS') AS ref_b \gset

\echo
\echo '##### PART A: over the daily limit #####'
SELECT a.account_number, c.first_name || ' ' || c.last_name AS holder, k.tier_name, k.daily_txn_limit, a.balance
  FROM account a
  JOIN customer c ON c.customer_id = a.customer_id
  JOIN kyc_tier k ON k.kyc_tier_id = c.kyc_tier_id
 WHERE a.account_number = '2010000038';

\set ECHO queries
SELECT post_transfer(:'ref_a', '2010000038', '2010000054', 60000, 10, 'USSD', 'School fees') AS txn_id \gset
\set ECHO none

SELECT t.reference, t.status, t.failure_reason
  FROM txn t
 WHERE t.txn_id = :txn_id;
SELECT COUNT(*) AS ledger_lines,
       (SELECT a.balance FROM account a WHERE a.account_number = '2010000038') AS halima_balance_now
  FROM ledger_entry l
 WHERE l.txn_id = :txn_id;
\echo 'The attempt is kept for audit, but it has no ledger lines and the balance did not change.'

\echo
\echo '##### PART B: an unbalanced posting is rolled back at COMMIT #####'
\echo '--- Balances before ---'
SELECT a.account_number, a.balance
  FROM account a
 WHERE a.account_number IN ('2010000013', '2010000046', '0000000002')
 ORDER BY a.account_id;

\set ECHO queries
BEGIN;
INSERT INTO txn (reference, txn_type, channel, source_account_id, destination_account_id,
                 amount, fee, status, narration, completed_at)
SELECT :'ref_b', 'TRANSFER', 'SYSTEM', s.account_id, d.account_id, 5000, 10, 'SUCCESS', 'Manual correction', now()
  FROM account s, account d
 WHERE s.account_number = '2010000013' AND d.account_number = '2010000046'
RETURNING txn_id \gset
UPDATE account SET balance = balance - 5010 WHERE account_number = '2010000013';
UPDATE account SET balance = balance + 5000 WHERE account_number = '2010000046';
INSERT INTO ledger_entry (txn_id, account_id, entry_type, amount, balance_after)
SELECT :txn_id, a.account_id, 'DEBIT', 5010, a.balance FROM account a WHERE a.account_number = '2010000013';
INSERT INTO ledger_entry (txn_id, account_id, entry_type, amount, balance_after)
SELECT :txn_id, a.account_id, 'CREDIT', 5000, a.balance FROM account a WHERE a.account_number = '2010000046';
\set ECHO none
\echo '--- Every statement succeeded. Inside the transaction the balances have changed: ---'
SELECT a.account_number, a.balance
  FROM account a
 WHERE a.account_number IN ('2010000013', '2010000046', '0000000002')
 ORDER BY a.account_id;
\echo '--- The NGN 10 fee was debited but never credited to the fee account. Now COMMIT: ---'
\set ECHO queries
COMMIT;
\set ECHO none

\echo
\echo '--- After the failed COMMIT ---'
SELECT a.account_number, a.balance
  FROM account a
 WHERE a.account_number IN ('2010000013', '2010000046', '0000000002')
 ORDER BY a.account_id;
SELECT COUNT(*) AS txns_with_reference_b FROM txn t WHERE t.reference = :'ref_b';
\echo 'The balances are back where they started and the txn row does not exist: the whole transaction was rolled back.'
