-- =====================================================================
-- TosiPay - Portfolio 2: bulk data generator
--
-- Adds a realistic volume of data on top of the Portfolio 1 sample data,
-- so that query plans and indexes can be measured. With the defaults it
-- adds about 100,000 customers, 1,000 agents, 130,000 accounts,
-- 900,000 transactions and 2.3 million ledger entries.
--
-- Run after portfolio-1 schema.sql and seed.sql, from the repo root:
--   psql -U postgres -d tosipay -f portfolio-2-query-optimisation/generate-data.sql
--
-- Sizes can be changed with -v, e.g. -v n_customers=20000
-- The same random seed is used every time, so the data is repeatable.
-- =====================================================================
\set ON_ERROR_STOP on
\timing on

\if :{?n_customers}          \else \set n_customers 100000      \endif
\if :{?n_agents}             \else \set n_agents 1000           \endif
\if :{?deposits_per_wallet}  \else \set deposits_per_wallet 3   \endif
\if :{?outflows_per_wallet}  \else \set outflows_per_wallet 6   \endif

SET search_path TO tosipay;
SELECT setseed(0.42);

-- Ledger entries that already exist (from seed.sql). Their balance_after
-- values are corrected at the end, because the generated history is
-- dated before the seed data.
SELECT COALESCE(MAX(entry_id), 0) AS seed_max_entry FROM ledger_entry \gset

BEGIN;

-- Bulk-load triggers off for the load only:
--  * trg_ledger_balanced runs a SUM per inserted row, and ledger_entry has
--    no index on txn_id yet, so 2.3M rows would take hours. Balance is
--    checked once, set-based, before COMMIT instead.
--  * trg_audit_account would write an audit row for every new account.
--    A bulk load is not a business change, so it is not audited.
ALTER TABLE ledger_entry DISABLE TRIGGER trg_ledger_balanced;
ALTER TABLE account      DISABLE TRIGGER trg_audit_account;

-- ---------------------------------------------------------------------
-- 1. Customers (ids from 1001). Tier mix: 60% Tier 1, 30% Tier 2,
--    10% Tier 3. Tier 1 always has a NIN; half of them also have a BVN.
-- ---------------------------------------------------------------------
INSERT INTO customer (customer_id, first_name, last_name, phone_number, email,
                      bvn, nin, date_of_birth, kyc_tier_id, created_at)
SELECT 1000 + g,
       (ARRAY['Adaeze','Tunde','Halima','Chinedu','Funmilayo','Ibrahim','Ngozi','Emeka',
              'Aisha','Segun','Blessing','Musa','Chiamaka','Yusuf','Temitope','Ifeanyi',
              'Zainab','Babajide','Amaka','Sani','Kemi','Obinna','Hadiza','Olumide',
              'Nkechi','Abubakar','Bisola','Uche','Fatima','Kunle'])[1 + floor(r_first * 30)::int],
       (ARRAY['Okafor','Bakare','Sani','Eze','Ogunleye','Musa','Adeyemi','Okonkwo',
              'Bello','Adebayo','Nwosu','Abdullahi','Olawale','Umar','Chukwu','Ibrahim',
              'Afolabi','Lawal','Obi','Danjuma','Ogundipe','Nnamdi','Yakubu','Akande',
              'Ezeh','Garba','Oyelaran','Mohammed','Onyeka','Salami'])[1 + floor(r_last * 30)::int],
       '+23480' || lpad((50000000 + g)::text, 8, '0'),
       CASE WHEN r_email < 0.7 THEN 'user' || g || '@example.com' END,
       CASE WHEN tier > 1 OR r_bvn < 0.5 THEN '23' || lpad(g::text, 9, '0') END,
       '80' || lpad(g::text, 9, '0'),
       DATE '1950-01-01' + floor(r_dob * (DATE '2005-12-31' - DATE '1950-01-01'))::int,
       tier,
       TIMESTAMPTZ '2025-01-01 00:00+01' + r_created * INTERVAL '240 days'
  FROM (SELECT g, random() AS r_first, random() AS r_last, random() AS r_email,
               random() AS r_bvn, random() AS r_dob, random() AS r_created,
               CASE WHEN r < 0.6 THEN 1 WHEN r < 0.9 THEN 2 ELSE 3 END AS tier
          FROM (SELECT g, random() AS r FROM generate_series(1, :n_customers) g) t) s;

-- ---------------------------------------------------------------------
-- 2. Agents (ids from 101), each run by one of the generated customers.
-- ---------------------------------------------------------------------
INSERT INTO agent (agent_id, owner_customer_id, business_name, phone_number, state, lga, onboarded_at)
SELECT 100 + g,
       1000 + g,
       loc.lga || ' Cash Point ' || g,
       '+23490' || lpad(g::text, 8, '0'),
       loc.state,
       loc.lga,
       TIMESTAMPTZ '2025-06-01 00:00+01' + random() * INTERVAL '90 days'
  FROM generate_series(1, :n_agents) g
  JOIN (VALUES (0, 'Lagos', 'Ikeja'),        (1, 'Lagos', 'Surulere'),     (2, 'Lagos', 'Alimosho'),
               (3, 'Oyo',   'Ibadan North'), (4, 'Oyo',   'Surulere'),     (5, 'Kano',  'Fagge'),
               (6, 'Kano',  'Nassarawa'),    (7, 'Rivers','Port Harcourt'),(8, 'FCT',   'Abuja Municipal'),
               (9, 'Enugu', 'Enugu North'),  (10,'Kaduna','Kaduna North'), (11,'Anambra','Onitsha North'))
       AS loc (n, state, lga) ON loc.n = g % 12;

-- ---------------------------------------------------------------------
-- 3. Accounts
--    wallets      1,000,000 + customer number (every customer)
--    savings      2,000,000 + customer number (about 30% of customers)
--    agent float  3,000,000 + agent number
-- ---------------------------------------------------------------------
INSERT INTO account (account_id, account_number, account_type_code, owner_kind, customer_id, opened_at)
SELECT 1000000 + g, '20' || lpad(g::text, 8, '0'), 'WALLET', 'CUSTOMER', 1000 + g,
       c.created_at + INTERVAL '5 minutes'
  FROM generate_series(1, :n_customers) g
  JOIN customer c ON c.customer_id = 1000 + g;

INSERT INTO account (account_id, account_number, account_type_code, owner_kind, customer_id, opened_at)
SELECT 2000000 + g, '22' || lpad(g::text, 8, '0'), 'SAVINGS', 'CUSTOMER', 1000 + g,
       c.created_at + INTERVAL '1 day'
  FROM generate_series(1, :n_customers) g
  JOIN customer c ON c.customer_id = 1000 + g
 WHERE random() < 0.3;

INSERT INTO account (account_id, account_number, account_type_code, owner_kind, agent_id, opened_at)
SELECT 3000000 + g, '30' || lpad(g::text, 8, '0'), 'AGENT_FLOAT', 'AGENT', 100 + g,
       a.onboarded_at
  FROM generate_series(1, :n_agents) g
  JOIN agent a ON a.agent_id = 100 + g;

INSERT INTO biller (biller_name, category) VALUES
    ('Eko Electric',            'ELECTRICITY'),
    ('Airtel Airtime',          'AIRTIME'),
    ('Glo Data',                'DATA'),
    ('GOtv',                    'CABLE_TV'),
    ('Lagos Water Corporation', 'WATER');

-- ---------------------------------------------------------------------
-- 4. Transactions, built in a staging table first so that txn_id can
--    follow created_at order (as it would in a live system).
--
--    Balances can never go negative: every wallet receives at least
--    3 x 20,000 in deposits (Oct-Dec 2025) before it spends anything,
--    and its 6 outflows (Jan-Aug 2026) are at most 6 x 8,100 in total.
--    Each agent float is topped up with more than its deposits need.
-- ---------------------------------------------------------------------
CREATE TEMP TABLE gen_raw (
    txn_type    VARCHAR(15),
    channel     VARCHAR(10),
    src         INTEGER,
    dst         INTEGER,
    amount      NUMERIC(18,2),
    fee         NUMERIC(18,2),
    failed      BOOLEAN,
    created_at  TIMESTAMPTZ
) ON COMMIT DROP;

-- 4a. Cash deposits at agents: agent float -> customer wallet
INSERT INTO gen_raw
SELECT 'DEPOSIT', 'AGENT_POS',
       3000000 + 1 + floor(random() * :n_agents)::int,
       1000000 + g,
       (200 + floor(random() * 801)) * 100,          -- 20,000 to 100,000
       0, false,
       TIMESTAMPTZ '2025-10-01 07:00+01' + random() * INTERVAL '91 days'
  FROM generate_series(1, :n_customers) g,
       generate_series(1, :deposits_per_wallet) k;

-- 4b. One float top-up per agent from the settlement account, dated
--     before the deposits, covering everything the agent pays out.
INSERT INTO gen_raw
SELECT 'FLOAT_TOPUP', 'SYSTEM', 1, d.src, d.total + 500000, 0, false,
       TIMESTAMPTZ '2025-09-30 08:00+01'
  FROM (SELECT src, SUM(amount) AS total FROM gen_raw
         WHERE txn_type = 'DEPOSIT' GROUP BY src) d;

-- 4c. Spending from wallets: 60% transfers, 25% bill payments,
--     15% cash withdrawals at an agent; about 3% fail.
INSERT INTO gen_raw
SELECT txn_type,
       CASE WHEN txn_type = 'WITHDRAWAL' THEN 'AGENT_POS'
            WHEN r_channel < 0.7 THEN 'APP' ELSE 'USSD' END,
       1000000 + g,
       CASE txn_type
            -- any other wallet, never the sender's own
            WHEN 'TRANSFER'   THEN 1000000 + 1 + (g + floor(r_dst * (:n_customers - 1))::int) % :n_customers
            WHEN 'WITHDRAWAL' THEN 3000000 + 1 + floor(r_dst * :n_agents)::int
       END,
       (5 + floor(r_amount * 76)) * 100,             -- 500 to 8,000
       CASE txn_type WHEN 'TRANSFER' THEN 10 ELSE 100 END,
       r_fail < 0.03,
       TIMESTAMPTZ '2026-01-01 07:00+01' + r_time * INTERVAL '242 days'
  FROM (SELECT g, random() AS r_channel, random() AS r_dst, random() AS r_amount,
               random() AS r_fail, random() AS r_time,
               CASE WHEN r < 0.60 THEN 'TRANSFER'
                    WHEN r < 0.85 THEN 'BILL_PAYMENT'
                    ELSE 'WITHDRAWAL' END AS txn_type
          FROM (SELECT g, random() AS r
                  FROM generate_series(1, :n_customers) g,
                       generate_series(1, :outflows_per_wallet) k) t) s;

CREATE TEMP TABLE gen_txn ON COMMIT DROP AS
SELECT 1000 + row_number() OVER (ORDER BY created_at, src, dst) AS txn_id,
       r.*,
       created_at + (1 + floor(random() * 5)) * INTERVAL '1 second' AS completed_at
  FROM gen_raw r;

INSERT INTO txn (txn_id, reference, txn_type, channel, source_account_id, destination_account_id,
                 amount, fee, status, failure_reason, narration, created_at, completed_at)
SELECT txn_id, 'GEN-' || txn_id, txn_type, channel, src, dst, amount, fee,
       CASE WHEN failed THEN 'FAILED' ELSE 'SUCCESS' END,
       CASE WHEN failed THEN 'Switch timeout - no debit' END,
       CASE txn_type WHEN 'DEPOSIT'      THEN 'Cash deposit'
                     WHEN 'FLOAT_TOPUP'  THEN 'Agent float funding'
                     WHEN 'TRANSFER'     THEN 'Transfer'
                     WHEN 'BILL_PAYMENT' THEN 'Bill payment'
                     WHEN 'WITHDRAWAL'   THEN 'Cash withdrawal' END,
       created_at, completed_at
  FROM gen_txn
 ORDER BY txn_id;

INSERT INTO bill_payment (txn_id, biller_id, customer_reference, token)
SELECT t.txn_id,
       1 + floor(random() * (SELECT COUNT(*) FROM biller))::int,
       lpad(floor(random() * 1e11)::bigint::text, 11, '0'),
       CASE WHEN NOT t.failed THEN lpad(floor(random() * 1e10)::bigint::text, 10, '0') END
  FROM gen_txn t
 WHERE t.txn_type = 'BILL_PAYMENT';

-- ---------------------------------------------------------------------
-- 5. Ledger entries for every successful transaction:
--    DEBIT  source       amount + fee
--    CREDIT destination  amount   (settlement account 1 for bill payments)
--    CREDIT fee income   fee      (account 2, only when fee > 0)
--    balance_after is the running total per account.
-- ---------------------------------------------------------------------
INSERT INTO ledger_entry (txn_id, account_id, entry_type, amount, balance_after, posted_at)
SELECT txn_id, account_id, entry_type, amount,
       SUM(CASE entry_type WHEN 'CREDIT' THEN amount ELSE -amount END)
           OVER (PARTITION BY account_id ORDER BY posted_at, txn_id, line
                 ROWS UNBOUNDED PRECEDING),
       posted_at
  FROM (SELECT txn_id, src AS account_id, 'DEBIT' AS entry_type, amount + fee AS amount,
               completed_at AS posted_at, 1 AS line
          FROM gen_txn WHERE NOT failed
        UNION ALL
        SELECT txn_id, COALESCE(dst, 1), 'CREDIT', amount, completed_at, 2
          FROM gen_txn WHERE NOT failed
        UNION ALL
        SELECT txn_id, 2, 'CREDIT', fee, completed_at, 3
          FROM gen_txn WHERE NOT failed AND fee > 0) e
 ORDER BY posted_at, txn_id, line;

-- The seed entries on the settlement (1) and fee income (2) accounts are
-- dated after the generated history, so add the generated totals to them.
UPDATE ledger_entry l
   SET balance_after = l.balance_after + g.net
  FROM (SELECT account_id, SUM(CASE entry_type WHEN 'CREDIT' THEN amount ELSE -amount END) AS net
          FROM ledger_entry
         WHERE entry_id > :seed_max_entry AND account_id IN (1, 2)
         GROUP BY account_id) g
 WHERE l.account_id = g.account_id
   AND l.entry_id <= :seed_max_entry;

-- Stored balances = credits - debits (chk_account_non_negative still applies).
UPDATE account a
   SET balance = l.net
  FROM (SELECT account_id, SUM(CASE entry_type WHEN 'CREDIT' THEN amount ELSE -amount END) AS net
          FROM ledger_entry
         GROUP BY account_id) l
 WHERE a.account_id = l.account_id
   AND a.balance <> l.net;

-- Replaces the per-row trigger for this load: one set-based check.
DO $$
DECLARE
    v_bad BIGINT;
BEGIN
    SELECT COUNT(*) INTO v_bad
      FROM (SELECT txn_id
              FROM tosipay.ledger_entry
             GROUP BY txn_id
            HAVING SUM(amount) FILTER (WHERE entry_type = 'DEBIT')
                <> SUM(amount) FILTER (WHERE entry_type = 'CREDIT')) x;
    IF v_bad > 0 THEN
        RAISE EXCEPTION '% generated transactions are unbalanced', v_bad;
    END IF;
END;
$$;

ALTER TABLE ledger_entry ENABLE TRIGGER trg_ledger_balanced;
ALTER TABLE account      ENABLE TRIGGER trg_audit_account;

SELECT setval(pg_get_serial_sequence('tosipay.customer', 'customer_id'), (SELECT MAX(customer_id) FROM customer));
SELECT setval(pg_get_serial_sequence('tosipay.agent',    'agent_id'),    (SELECT MAX(agent_id)    FROM agent));
SELECT setval(pg_get_serial_sequence('tosipay.account',  'account_id'),  (SELECT MAX(account_id)  FROM account));
SELECT setval(pg_get_serial_sequence('tosipay.txn',      'txn_id'),      (SELECT MAX(txn_id)      FROM txn));

COMMIT;

-- Fresh statistics so the planner knows the new table sizes.
ANALYZE;

\echo '--- Row counts after loading ---'
SELECT 'customer' AS table_name, COUNT(*) AS row_count FROM customer
UNION ALL SELECT 'agent',        COUNT(*) FROM agent
UNION ALL SELECT 'account',      COUNT(*) FROM account
UNION ALL SELECT 'txn',          COUNT(*) FROM txn
UNION ALL SELECT 'bill_payment', COUNT(*) FROM bill_payment
UNION ALL SELECT 'ledger_entry', COUNT(*) FROM ledger_entry;

\echo '--- Sum of all balances (closed system, must be 0) ---'
SELECT SUM(balance) AS total_of_all_balances FROM account;
