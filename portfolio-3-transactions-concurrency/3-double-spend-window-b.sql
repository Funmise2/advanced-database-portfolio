-- =====================================================================
-- TosiPay - Portfolio 3, example 3: double spend (WINDOW B)
--
-- Adaeze's second payment, sent over USSD at the same moment as the app
-- payment in window A. Start this window first:
--   psql -U postgres -d tosipay -f portfolio-3-transactions-concurrency/3-double-spend-window-b.sql
-- =====================================================================
SET search_path TO tosipay;

\echo
\echo '=== DOUBLE SPEND - WINDOW B: Adaeze pays over USSD ==='
\echo
\echo '##### PART 1: read, check, write back (no lock) #####'
\prompt 'Do step 1 in window A first, then press Enter here for step 2: ' go

\set ECHO queries
BEGIN;
SELECT a.balance AS seen_b FROM account a WHERE a.account_number = '2010000013' \gset
SELECT round(:seen_b * 0.6, 0) AS amount_b \gset
\set ECHO none
\echo 'Window B also sees NGN' :seen_b 'and approves a payment of NGN' :amount_b '(enough money).'
\echo
\echo '>>> Next: step 3 in window A'
\prompt 'Do step 3 in window A first, then press Enter here for step 4: ' go

\set ECHO queries
UPDATE account SET balance = :seen_b - :amount_b WHERE account_number = '2010000013';
COMMIT;
\set ECHO none
\echo
\echo '--- The audit log shows both writes. The second one did not lower the balance at all, ---'
\echo '--- because window B worked it out from the balance it read before window A''s write. ---'
SELECT x.changed_at, x.old_balance, x.new_balance
  FROM (SELECT al.audit_id, al.changed_at,
               al.old_data ->> 'balance' AS old_balance,
               al.new_data ->> 'balance' AS new_balance
          FROM audit_log al
         WHERE al.table_name = 'account'
           AND al.record_id = (SELECT a.account_id FROM account a WHERE a.account_number = '2010000013')
         ORDER BY al.audit_id DESC
         LIMIT 2) x
 ORDER BY x.audit_id;
SELECT :amount_b * 2 AS total_approved, :seen_b AS balance_at_the_time,
       (SELECT a.balance FROM account a WHERE a.account_number = '2010000013') AS balance_now;
\echo 'Two payments worth more than the whole balance were approved, and the balance went down only once.'
\echo 'Window B wrote over window A''s change (a lost update), so one payment was never charged.'
\echo
\echo '--- Reconciliation against the ledger finds the problem ---'
SELECT a.balance AS stored_balance,
       SUM(CASE l.entry_type WHEN 'CREDIT' THEN l.amount ELSE -l.amount END) AS ledger_balance
  FROM account a
  JOIN ledger_entry l ON l.account_id = a.account_id
 WHERE a.account_number = '2010000013'
 GROUP BY a.balance;
\echo '--- Repair: put the stored balance back from the ledger ---'
UPDATE account a
   SET balance = (SELECT SUM(CASE l.entry_type WHEN 'CREDIT' THEN l.amount ELSE -l.amount END)
                    FROM ledger_entry l
                   WHERE l.account_id = a.account_id)
 WHERE a.account_number = '2010000013';
\echo
\echo '>>> Next: step 5 in window A'
\prompt 'Do step 5 in window A first, then press Enter here for step 6: ' go

\echo
\echo '##### PART 2: the same payments through post_transfer() #####'
SELECT 'P3-DB-' || to_char(clock_timestamp(), 'YYYYMMDD-HH24MISS') AS ref_b \gset
SELECT a.balance AS seen_b FROM account a WHERE a.account_number = '2010000013' \gset
SELECT round(:seen_b * 0.6, 0) AS amount_b \gset
\echo 'Window B sees NGN' :seen_b '(window A has not committed yet) and asks for NGN' :amount_b
\echo 'Window B now waits here until window A commits.'
\set ECHO queries
BEGIN;
SELECT post_transfer(:'ref_b', '2010000013', '2010000021', :amount_b, 10, 'USSD', 'Rent') AS txn_b \gset
COMMIT;
\set ECHO none
\echo
\echo '--- Both payments ---'
SELECT t.reference, t.channel, t.amount, t.status, t.failure_reason
  FROM txn t
 WHERE t.txn_id = :txn_b
    OR t.txn_id = (SELECT MAX(t2.txn_id) FROM txn t2 WHERE t2.reference LIKE 'P3-DA-%')
 ORDER BY t.txn_id;
SELECT a.balance AS adaeze_balance_now FROM account a WHERE a.account_number = '2010000013';
\echo 'Window B waited for the lock, then read the balance after window A''s payment.'
\echo 'There was not enough left, so its payment was recorded as FAILED and no money moved.'
\echo
\echo '=== Done ==='
