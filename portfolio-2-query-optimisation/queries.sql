-- =====================================================================
-- TosiPay - Portfolio 2: workload queries
--
-- Eight queries that TosiPay runs every day. Run after generate-data.sql.
--
-- Show the results:
--   psql -U postgres -d tosipay -f portfolio-2-query-optimisation/queries.sql
--
-- Show the execution plans instead (the :explain variable is put in
-- front of every query):
--   psql -U postgres -d tosipay -v explain="EXPLAIN (ANALYZE, BUFFERS)" \
--        -f portfolio-2-query-optimisation/queries.sql
--
-- Fixed example values are used (one customer, one agent, one day) so
-- that every run measures the same work.
-- =====================================================================
\if :{?explain} \else \set explain '' \endif
SET search_path TO tosipay;

\echo
\echo '=== Q1. Mini statement: last 10 entries on a wallet (app home screen) ==='
:explain
SELECT l.posted_at, t.txn_type, t.narration, l.entry_type, l.amount, l.balance_after
  FROM account a
  JOIN ledger_entry l ON l.account_id = a.account_id
  JOIN txn t          ON t.txn_id = l.txn_id
 WHERE a.account_number = '2000012345'
 ORDER BY l.posted_at DESC, l.entry_id DESC
 LIMIT 10;

\echo
\echo '=== Q2. Daily limit check: how much has this wallet sent today? (runs before every payment) ==='
:explain
SELECT COALESCE(SUM(t.amount), 0) AS sent_today, k.daily_txn_limit
  FROM account a
  JOIN customer c ON c.customer_id = a.customer_id
  JOIN kyc_tier k ON k.kyc_tier_id = c.kyc_tier_id
  LEFT JOIN txn t ON t.source_account_id = a.account_id
                 AND t.status = 'SUCCESS'
                 AND t.created_at >= TIMESTAMPTZ '2026-03-08 00:00+01'
                 AND t.created_at <  TIMESTAMPTZ '2026-03-09 00:00+01'
 WHERE a.account_number = '2000012345'
 GROUP BY k.daily_txn_limit;

\echo
\echo '=== Q3. Customer care: all of a customer''s transactions in June, found by phone number ==='
:explain
SELECT t.txn_id, t.reference, t.created_at, t.txn_type, t.amount, t.status,
       CASE WHEN t.source_account_id = a.account_id THEN 'OUT' ELSE 'IN' END AS direction
  FROM customer c
  JOIN account a ON a.customer_id = c.customer_id
  JOIN txn t     ON t.source_account_id = a.account_id
                 OR t.destination_account_id = a.account_id
 WHERE c.phone_number = '+2348050012345'
   AND t.created_at >= TIMESTAMPTZ '2026-06-01 00:00+01'
   AND t.created_at <  TIMESTAMPTZ '2026-07-01 00:00+01'
 ORDER BY t.created_at;

\echo
\echo '=== Q4. Dispute lookup: a transaction and its ledger lines, by reference ==='
:explain
SELECT t.reference, t.txn_type, t.status, t.amount, t.fee,
       a.account_number, l.entry_type, l.amount AS entry_amount
  FROM txn t
  JOIN ledger_entry l ON l.txn_id = t.txn_id
  JOIN account a      ON a.account_id = l.account_id
 WHERE t.reference = 'GEN-500000'
 ORDER BY l.entry_id;

\echo
\echo '=== Q5. Agent end-of-day report: cash in and cash out at one agent ==='
:explain
SELECT t.txn_type, COUNT(*) AS txn_count, SUM(t.amount) AS total_amount
  FROM agent g
  JOIN account a ON a.agent_id = g.agent_id
  JOIN txn t     ON (t.txn_type = 'DEPOSIT'    AND t.source_account_id      = a.account_id)
                 OR (t.txn_type = 'WITHDRAWAL' AND t.destination_account_id = a.account_id)
 WHERE g.phone_number = '+2349000000250'
   AND t.status = 'SUCCESS'
   AND t.created_at >= TIMESTAMPTZ '2025-11-14 00:00+01'
   AND t.created_at <  TIMESTAMPTZ '2025-11-15 00:00+01'
 GROUP BY t.txn_type;

\echo
\echo '=== Q6. Operations dashboard: failed transactions per channel, last 7 days ==='
:explain
SELECT channel, txn_type, COUNT(*) AS failed_count
  FROM txn
 WHERE status = 'FAILED'
   AND created_at >= TIMESTAMPTZ '2026-08-23 00:00+01'
   AND created_at <  TIMESTAMPTZ '2026-08-30 00:00+01'
 GROUP BY channel, txn_type
 ORDER BY failed_count DESC;

\echo
\echo '=== Q7. Monthly biller report: bill payment volume per biller in May ==='
:explain
SELECT b.biller_name, b.category, COUNT(*) AS payments, SUM(t.amount) AS total_paid
  FROM bill_payment bp
  JOIN txn t    ON t.txn_id = bp.txn_id
  JOIN biller b ON b.biller_id = bp.biller_id
 WHERE t.status = 'SUCCESS'
   AND t.created_at >= TIMESTAMPTZ '2026-05-01 00:00+01'
   AND t.created_at <  TIMESTAMPTZ '2026-06-01 00:00+01'
 GROUP BY b.biller_name, b.category
 ORDER BY total_paid DESC;

\echo
\echo '=== Q8. Nightly reconciliation: accounts whose stored balance differs from the ledger ==='
:explain
SELECT a.account_id, a.balance AS stored_balance, l.ledger_balance
  FROM account a
  JOIN (SELECT account_id,
               SUM(CASE entry_type WHEN 'CREDIT' THEN amount ELSE -amount END) AS ledger_balance
          FROM ledger_entry
         GROUP BY account_id) l ON l.account_id = a.account_id
 WHERE a.balance <> l.ledger_balance;
