SET search_path TO tosipay;

SELECT 'P3-C-' || to_char(clock_timestamp(), 'YYYYMMDD-HH24MISS') AS ref \gset

\echo
\echo '=== Before: the three accounts this transfer will change ==='
SELECT a.account_number, a.owner_kind, COALESCE(c.first_name || ' ' || c.last_name, 'Fee income') AS holder, a.balance
  FROM account a
  LEFT JOIN customer c ON c.customer_id = a.customer_id
 WHERE a.account_number IN ('2010000021', '2010000046', '0000000002')
 ORDER BY a.account_id;

\echo
\echo '=== The transfer, inside one transaction ==='
\set ECHO queries
BEGIN;
SELECT post_transfer(:'ref', '2010000021', '2010000046', 5000, 10, 'APP', 'Payment for phone repair') AS txn_id \gset
\set ECHO none

\echo
\echo '--- Inside the transaction (not yet visible to any other session) ---'
SELECT t.txn_id, t.reference, t.txn_type, t.status, t.amount, t.fee
  FROM txn t
 WHERE t.txn_id = :txn_id;

SELECT a.account_number, l.entry_type, l.amount, l.balance_after
  FROM ledger_entry l
  JOIN account a ON a.account_id = l.account_id
 WHERE l.txn_id = :txn_id
 ORDER BY l.entry_id;

\set ECHO queries
COMMIT;
\set ECHO none

\echo
\echo '=== After COMMIT: all the changes are saved together ==='
SELECT a.account_number, COALESCE(c.first_name || ' ' || c.last_name, 'Fee income') AS holder, a.balance
  FROM account a
  LEFT JOIN customer c ON c.customer_id = a.customer_id
 WHERE a.account_number IN ('2010000021', '2010000046', '0000000002')
 ORDER BY a.account_id;

\echo
\echo '=== Retry: the app times out and sends the same request again ==='
\set ECHO queries
SELECT post_transfer(:'ref', '2010000021', '2010000046', 5000, 10, 'APP', 'Payment for phone repair') AS txn_id;
\set ECHO none

SELECT COUNT(*) AS txns_with_this_reference,
       (SELECT a.balance FROM account a WHERE a.account_number = '2010000021') AS tunde_balance_now
  FROM txn t
 WHERE t.reference = :'ref';
\echo 'Still one transaction and the balance did not change: the retry was safe.'
