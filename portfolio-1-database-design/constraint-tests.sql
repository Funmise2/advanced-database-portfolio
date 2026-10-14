-- =====================================================================
-- TosiPay - constraint and integrity tests
-- Run after schema.sql and seed.sql:
--   psql -U postgres -d tosipay -f constraint-tests.sql
--
-- Part A tries to insert invalid data; every line should print PASS
-- (meaning the database rejected the bad data). Everything runs inside
-- a transaction that is rolled back, so the sample data is unchanged.
-- Part B checks that the seeded data is internally consistent.
-- =====================================================================
SET search_path TO tosipay;

BEGIN;
-- Check the deferred ledger trigger per statement instead of at COMMIT,
-- so its error can be caught by the test helper below.
SET CONSTRAINTS ALL IMMEDIATE;

CREATE FUNCTION pg_temp.expect_error(p_label TEXT, p_sql TEXT) RETURNS TEXT
LANGUAGE plpgsql AS $$
BEGIN
    EXECUTE p_sql;
    RETURN 'FAIL  ' || p_label || '  (statement was accepted)';
EXCEPTION WHEN OTHERS THEN
    RETURN 'PASS  ' || p_label || '  -> ' || SQLERRM;
END;
$$;

\echo '--- Part A: invalid data must be rejected ---'
SELECT pg_temp.expect_error('Duplicate phone number',
  $q$INSERT INTO tosipay.customer (first_name, last_name, phone_number, date_of_birth, nin)
     VALUES ('Test', 'User', '+2348031110001', '2000-01-01', '70100000099')$q$)
UNION ALL
SELECT pg_temp.expect_error('Badly formatted phone number',
  $q$INSERT INTO tosipay.customer (first_name, last_name, phone_number, date_of_birth, nin)
     VALUES ('Test', 'User', '08031110009', '2000-01-01', '70100000099')$q$)
UNION ALL
SELECT pg_temp.expect_error('Tier 1 customer with neither BVN nor NIN',
  $q$INSERT INTO tosipay.customer (first_name, last_name, phone_number, date_of_birth, kyc_tier_id)
     VALUES ('Test', 'User', '+2348031110099', '2000-01-01', 1)$q$)
UNION ALL
SELECT pg_temp.expect_error('Tier 2 customer with BVN but no NIN',
  $q$INSERT INTO tosipay.customer (first_name, last_name, phone_number, date_of_birth, kyc_tier_id, bvn)
     VALUES ('Test', 'User', '+2348031110099', '2000-01-01', 2, '22100000099')$q$)
UNION ALL
SELECT pg_temp.expect_error('Tier 3 customer with NIN but no BVN',
  $q$INSERT INTO tosipay.customer (first_name, last_name, phone_number, date_of_birth, kyc_tier_id, nin)
     VALUES ('Test', 'User', '+2348031110099', '2000-01-01', 3, '70100000099')$q$)
UNION ALL
SELECT pg_temp.expect_error('NIN already used by another customer',
  $q$INSERT INTO tosipay.customer (first_name, last_name, phone_number, date_of_birth, nin)
     VALUES ('Test', 'User', '+2348031110099', '2000-01-01', '70100000001')$q$)
UNION ALL
SELECT pg_temp.expect_error('Customer with non-existent KYC tier (FK)',
  $q$INSERT INTO tosipay.customer (first_name, last_name, phone_number, date_of_birth, kyc_tier_id, bvn, nin)
     VALUES ('Test', 'User', '+2348031110098', '2000-01-01', 9, '22100000099', '70100000099')$q$)
UNION ALL
SELECT pg_temp.expect_error('Agent with no owning customer',
  $q$INSERT INTO tosipay.agent (business_name, phone_number, state, lga)
     VALUES ('Test POS', '+2348092220099', 'Oyo', 'Ibadan North')$q$)
UNION ALL
SELECT pg_temp.expect_error('Account with unknown account type (FK)',
  $q$INSERT INTO tosipay.account (account_number, account_type_code, owner_kind, customer_id)
     VALUES ('2010000997', 'CRYPTO', 'CUSTOMER', 1)$q$)
UNION ALL
SELECT pg_temp.expect_error('Wallet claiming to be agent-owned (type/owner_kind mismatch)',
  $q$INSERT INTO tosipay.account (account_number, account_type_code, owner_kind, agent_id)
     VALUES ('2010000999', 'WALLET', 'AGENT', 1)$q$)
UNION ALL
SELECT pg_temp.expect_error('Wallet owned by an agent',
  $q$INSERT INTO tosipay.account (account_number, account_type_code, owner_kind, agent_id)
     VALUES ('2010000999', 'WALLET', 'CUSTOMER', 1)$q$)
UNION ALL
SELECT pg_temp.expect_error('Account with two owners',
  $q$INSERT INTO tosipay.account (account_number, account_type_code, owner_kind, customer_id, agent_id)
     VALUES ('2010000998', 'WALLET', 'CUSTOMER', 1, 1)$q$)
UNION ALL
SELECT pg_temp.expect_error('Overdrawn customer wallet',
  $q$UPDATE tosipay.account SET balance = -1 WHERE account_id = 5$q$)
UNION ALL
SELECT pg_temp.expect_error('Transaction with zero amount',
  $q$INSERT INTO tosipay.txn (reference, txn_type, channel, source_account_id, destination_account_id, amount)
     VALUES ('TP-TEST-0001', 'TRANSFER', 'APP', 5, 6, 0)$q$)
UNION ALL
SELECT pg_temp.expect_error('Transfer to the same account',
  $q$INSERT INTO tosipay.txn (reference, txn_type, channel, source_account_id, destination_account_id, amount)
     VALUES ('TP-TEST-0002', 'TRANSFER', 'APP', 5, 5, 100)$q$)
UNION ALL
SELECT pg_temp.expect_error('Duplicate transaction reference (idempotency)',
  $q$INSERT INTO tosipay.txn (reference, txn_type, channel, source_account_id, destination_account_id, amount)
     VALUES ('TP-20260905-0001', 'TRANSFER', 'APP', 5, 6, 100)$q$)
UNION ALL
SELECT pg_temp.expect_error('Reversal without the original transaction',
  $q$INSERT INTO tosipay.txn (reference, txn_type, channel, source_account_id, destination_account_id, amount)
     VALUES ('TP-TEST-0003', 'REVERSAL', 'SYSTEM', 6, 5, 100)$q$)
UNION ALL
SELECT pg_temp.expect_error('Reversing the same transaction twice',
  $q$INSERT INTO tosipay.txn (reference, txn_type, channel, source_account_id, destination_account_id, amount, reverses_txn_id)
     VALUES ('TP-TEST-0004', 'REVERSAL', 'SYSTEM', 8, 6, 20010, 13)$q$)
UNION ALL
SELECT pg_temp.expect_error('FAILED transaction without a failure reason',
  $q$INSERT INTO tosipay.txn (reference, txn_type, channel, source_account_id, destination_account_id, amount, status)
     VALUES ('TP-TEST-0005', 'TRANSFER', 'APP', 5, 6, 100, 'FAILED')$q$)
UNION ALL
SELECT pg_temp.expect_error('Unbalanced ledger posting (debit without credit)',
  $q$INSERT INTO tosipay.ledger_entry (txn_id, account_id, entry_type, amount, balance_after)
     VALUES (9, 5, 'DEBIT', 1, 0)$q$);

ROLLBACK;

\echo '--- Part B: consistency checks on the seeded data (each should return 0 rows) ---'

\echo 'B1. Accounts whose stored balance differs from the ledger:'
SELECT a.account_id, a.balance AS stored_balance,
       COALESCE(SUM(CASE l.entry_type WHEN 'CREDIT' THEN l.amount ELSE -l.amount END), 0) AS ledger_balance
  FROM account a
  LEFT JOIN ledger_entry l ON l.account_id = a.account_id
 GROUP BY a.account_id, a.balance
HAVING a.balance <> COALESCE(SUM(CASE l.entry_type WHEN 'CREDIT' THEN l.amount ELSE -l.amount END), 0);

\echo 'B2. Transactions whose debits and credits do not match:'
SELECT txn_id,
       SUM(amount) FILTER (WHERE entry_type = 'DEBIT')  AS debits,
       SUM(amount) FILTER (WHERE entry_type = 'CREDIT') AS credits
  FROM ledger_entry
 GROUP BY txn_id
HAVING SUM(amount) FILTER (WHERE entry_type = 'DEBIT')
    <> SUM(amount) FILTER (WHERE entry_type = 'CREDIT');

\echo 'B3. FAILED transactions that moved money:'
SELECT t.txn_id, t.reference
  FROM txn t
  JOIN ledger_entry l ON l.txn_id = t.txn_id
 WHERE t.status = 'FAILED';

\echo 'B4. Sum of all balances in the system (closed system, must be 0):'
SELECT SUM(balance) AS total_of_all_balances FROM account;

\echo '--- Part C: every account a person controls (personal + agent business) ---'
SELECT c.customer_id,
       c.first_name || ' ' || c.last_name AS person,
       a.account_number,
       t.type_name,
       COALESCE(g.business_name, '(personal)') AS held_as,
       a.balance
  FROM customer c
  JOIN account a
    ON a.customer_id = c.customer_id
    OR a.agent_id IN (SELECT agent_id FROM agent WHERE owner_customer_id = c.customer_id)
  JOIN account_type t ON t.account_type_code = a.account_type_code
  LEFT JOIN agent g   ON g.agent_id = a.agent_id
 ORDER BY c.customer_id, a.account_id;
