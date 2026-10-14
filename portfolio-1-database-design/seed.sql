-- =====================================================================
-- TosiPay - sample data for Portfolio 1
-- Run after schema.sql:  psql -U postgres -d tosipay -f seed.sql
-- All people and businesses are fictional.
-- =====================================================================
SET search_path TO tosipay;

BEGIN;

INSERT INTO kyc_tier (kyc_tier_id, tier_name, daily_txn_limit, max_balance) VALUES
    (1, 'TIER_1',    50000.00,  300000.00),
    (2, 'TIER_2',   200000.00,  500000.00),
    (3, 'TIER_3',  5000000.00,       NULL);

INSERT INTO account_type (account_type_code, type_name, owner_kind, interest_rate_pa, min_balance) VALUES
    ('WALLET',        'Mobile Wallet',         'CUSTOMER',  0.00,     0.00),
    ('SAVINGS',       'Savings Account',       'CUSTOMER',  8.00,     0.00),
    ('CURRENT',       'Current Account',       'CUSTOMER',  0.00,  5000.00),
    ('FIXED_DEPOSIT', 'Fixed Deposit',         'CUSTOMER', 12.00, 50000.00),
    ('AGENT_FLOAT',   'Agent Float Account',   'AGENT',     0.00,     0.00),
    ('SYSTEM',        'TosiPay Internal (GL)', 'SYSTEM',    0.00,     0.00);

INSERT INTO customer (customer_id, first_name, last_name, phone_number, email, bvn, nin, date_of_birth, kyc_tier_id) VALUES
    (1, 'Adaeze',    'Okafor',   '+2348031110001', 'adaeze.okafor@example.com', '22100000001', '70100000001', '1990-04-12', 3),
    (2, 'Tunde',     'Bakare',   '+2348031110002', 'tunde.bakare@example.com',  '22100000002', '70100000002', '1985-11-03', 2),
    (3, 'Halima',    'Sani',     '+2348031110003', NULL,                         NULL,          '70100000003', '2001-07-21', 1),
    (4, 'Chinedu',   'Eze',      '+2348031110004', 'chinedu.eze@example.com',   '22100000004', '70100000004', '1995-01-30', 2),
    (5, 'Funmilayo', 'Ogunleye', '+2348031110005', NULL,                         '22100000005', NULL,          '1999-09-09', 1),
    (6, 'Ibrahim',   'Musa',     '+2348031110006', 'ibrahim.musa@example.com',  '22100000006', '70100000006', '1980-03-15', 3);

-- Tunde (customer 2) runs Ikeja Cash Point, so his personal wallet and the
-- agent float account are linked through agent.owner_customer_id.
INSERT INTO agent (agent_id, owner_customer_id, business_name, phone_number, state, lga) VALUES
    (1, 2, 'Ikeja Cash Point',   '+2348092220001', 'Lagos', 'Ikeja'),
    (2, 6, 'Sabon Gari POS Hub', '+2348092220002', 'Kano',  'Fagge');

INSERT INTO account (account_id, account_number, account_type_code, owner_kind, customer_id, agent_id) VALUES
    ( 1, '0000000001', 'SYSTEM',      'SYSTEM',   NULL, NULL),  -- partner-bank settlement
    ( 2, '0000000002', 'SYSTEM',      'SYSTEM',   NULL, NULL),  -- fee income
    ( 3, '3010000011', 'AGENT_FLOAT', 'AGENT',    NULL, 1),
    ( 4, '3010000029', 'AGENT_FLOAT', 'AGENT',    NULL, 2),
    ( 5, '2010000013', 'WALLET',      'CUSTOMER', 1,    NULL),
    ( 6, '2010000021', 'WALLET',      'CUSTOMER', 2,    NULL),
    ( 7, '2010000038', 'WALLET',      'CUSTOMER', 3,    NULL),
    ( 8, '2010000046', 'WALLET',      'CUSTOMER', 4,    NULL),
    ( 9, '2010000054', 'WALLET',      'CUSTOMER', 5,    NULL),
    (10, '2210000017', 'SAVINGS',     'CUSTOMER', 1,    NULL),
    (11, '1010000015', 'CURRENT',     'CUSTOMER', 4,    NULL);  -- opened, not yet funded

INSERT INTO biller (biller_id, biller_name, category) VALUES
    (1, 'Ikeja Electric',   'ELECTRICITY'),
    (2, 'MTN Airtime',      'AIRTIME'),
    (3, 'DStv',             'CABLE_TV');

-- Transactions -------------------------------------------------------
INSERT INTO txn (txn_id, reference, txn_type, channel, source_account_id, destination_account_id,
                 amount, fee, status, failure_reason, reverses_txn_id, narration, created_at, completed_at) VALUES
 ( 1, 'TP-20260901-0001', 'FLOAT_TOPUP',  'SYSTEM',    1, 3, 1000000.00,   0, 'SUCCESS',  NULL, NULL, 'Agent float funding',        '2026-09-01 08:00+01', '2026-09-01 08:00:02+01'),
 ( 2, 'TP-20260901-0002', 'FLOAT_TOPUP',  'SYSTEM',    1, 4,  500000.00,   0, 'SUCCESS',  NULL, NULL, 'Agent float funding',        '2026-09-01 08:05+01', '2026-09-01 08:05:02+01'),
 ( 3, 'TP-20260902-0001', 'DEPOSIT',      'AGENT_POS', 3, 5,  250000.00,   0, 'SUCCESS',  NULL, NULL, 'Cash deposit',               '2026-09-02 10:15+01', '2026-09-02 10:15:03+01'),
 ( 4, 'TP-20260902-0002', 'DEPOSIT',      'AGENT_POS', 3, 6,  120000.00,   0, 'SUCCESS',  NULL, NULL, 'Cash deposit',               '2026-09-02 11:40+01', '2026-09-02 11:40:02+01'),
 ( 5, 'TP-20260903-0001', 'DEPOSIT',      'AGENT_POS', 4, 7,   40000.00,   0, 'SUCCESS',  NULL, NULL, 'Cash deposit',               '2026-09-03 09:05+01', '2026-09-03 09:05:02+01'),
 ( 6, 'TP-20260903-0002', 'DEPOSIT',      'AGENT_POS', 4, 8,   80000.00,   0, 'SUCCESS',  NULL, NULL, 'Cash deposit',               '2026-09-03 13:20+01', '2026-09-03 13:20:04+01'),
 ( 7, 'TP-20260904-0001', 'DEPOSIT',      'AGENT_POS', 3, 9,   20000.00,   0, 'SUCCESS',  NULL, NULL, 'Cash deposit',               '2026-09-04 16:45+01', '2026-09-04 16:45:02+01'),
 ( 8, 'TP-20260905-0001', 'TRANSFER',     'APP',       5, 6,   30000.00,  10, 'SUCCESS',  NULL, NULL, 'Rent contribution',          '2026-09-05 19:02+01', '2026-09-05 19:02:01+01'),
 ( 9, 'TP-20260906-0001', 'TRANSFER',     'APP',       5, 10,  50000.00,   0, 'SUCCESS',  NULL, NULL, 'Move to savings',            '2026-09-06 07:30+01', '2026-09-06 07:30:01+01'),
 (10, 'TP-20260907-0001', 'BILL_PAYMENT', 'USSD',      6, NULL, 15000.00, 100, 'SUCCESS',  NULL, NULL, 'Prepaid electricity',        '2026-09-07 20:10+01', '2026-09-07 20:10:05+01'),
 (11, 'TP-20260908-0001', 'WITHDRAWAL',   'AGENT_POS', 8, 4,   10000.00, 100, 'SUCCESS',  NULL, NULL, 'Cash withdrawal',            '2026-09-08 12:00+01', '2026-09-08 12:00:03+01'),
 (12, 'TP-20260909-0001', 'TRANSFER',     'USSD',      7, 9,    5000.00,  10, 'FAILED',   'Switch timeout - no debit', NULL, 'School fees', '2026-09-09 08:15+01', '2026-09-09 08:15:30+01'),
 (13, 'TP-20260910-0001', 'TRANSFER',     'APP',       6, 8,   20000.00,  10, 'REVERSED', NULL, NULL, 'Payment for goods',          '2026-09-10 14:00+01', '2026-09-10 14:00:01+01'),
 (14, 'TP-20260911-0001', 'REVERSAL',     'SYSTEM',    8, 6,   20010.00,   0, 'SUCCESS',  NULL, 13,   'Dispute: wrong beneficiary', '2026-09-11 09:30+01', '2026-09-11 09:30:01+01');

INSERT INTO bill_payment (txn_id, biller_id, customer_reference, token) VALUES
    (10, 1, '45012345678', '1234-5678-9012-3456-7890');

-- Ledger entries (double-entry). Fees are credited to the fee income account (2).
-- Bill payments are credited to settlement (1), from where TosiPay pays the biller.
INSERT INTO ledger_entry (txn_id, account_id, entry_type, amount, balance_after, posted_at) VALUES
 ( 1, 1, 'DEBIT',  1000000.00, -1000000.00, '2026-09-01 08:00:02+01'),
 ( 1, 3, 'CREDIT', 1000000.00,  1000000.00, '2026-09-01 08:00:02+01'),
 ( 2, 1, 'DEBIT',   500000.00, -1500000.00, '2026-09-01 08:05:02+01'),
 ( 2, 4, 'CREDIT',  500000.00,   500000.00, '2026-09-01 08:05:02+01'),
 ( 3, 3, 'DEBIT',   250000.00,   750000.00, '2026-09-02 10:15:03+01'),
 ( 3, 5, 'CREDIT',  250000.00,   250000.00, '2026-09-02 10:15:03+01'),
 ( 4, 3, 'DEBIT',   120000.00,   630000.00, '2026-09-02 11:40:02+01'),
 ( 4, 6, 'CREDIT',  120000.00,   120000.00, '2026-09-02 11:40:02+01'),
 ( 5, 4, 'DEBIT',    40000.00,   460000.00, '2026-09-03 09:05:02+01'),
 ( 5, 7, 'CREDIT',   40000.00,    40000.00, '2026-09-03 09:05:02+01'),
 ( 6, 4, 'DEBIT',    80000.00,   380000.00, '2026-09-03 13:20:04+01'),
 ( 6, 8, 'CREDIT',   80000.00,    80000.00, '2026-09-03 13:20:04+01'),
 ( 7, 3, 'DEBIT',    20000.00,   610000.00, '2026-09-04 16:45:02+01'),
 ( 7, 9, 'CREDIT',   20000.00,    20000.00, '2026-09-04 16:45:02+01'),
 ( 8, 5, 'DEBIT',    30010.00,   219990.00, '2026-09-05 19:02:01+01'),
 ( 8, 6, 'CREDIT',   30000.00,   150000.00, '2026-09-05 19:02:01+01'),
 ( 8, 2, 'CREDIT',      10.00,       10.00, '2026-09-05 19:02:01+01'),
 ( 9, 5, 'DEBIT',    50000.00,   169990.00, '2026-09-06 07:30:01+01'),
 ( 9,10, 'CREDIT',   50000.00,    50000.00, '2026-09-06 07:30:01+01'),
 (10, 6, 'DEBIT',    15100.00,   134900.00, '2026-09-07 20:10:05+01'),
 (10, 1, 'CREDIT',   15000.00, -1485000.00, '2026-09-07 20:10:05+01'),
 (10, 2, 'CREDIT',     100.00,      110.00, '2026-09-07 20:10:05+01'),
 (11, 8, 'DEBIT',    10100.00,    69900.00, '2026-09-08 12:00:03+01'),
 (11, 4, 'CREDIT',   10000.00,   390000.00, '2026-09-08 12:00:03+01'),
 (11, 2, 'CREDIT',     100.00,      210.00, '2026-09-08 12:00:03+01'),
 -- txn 12 FAILED: no ledger entries
 (13, 6, 'DEBIT',    20010.00,   114890.00, '2026-09-10 14:00:01+01'),
 (13, 8, 'CREDIT',   20000.00,    89900.00, '2026-09-10 14:00:01+01'),
 (13, 2, 'CREDIT',      10.00,      220.00, '2026-09-10 14:00:01+01'),
 (14, 8, 'DEBIT',    20000.00,    69900.00, '2026-09-11 09:30:01+01'),
 (14, 2, 'DEBIT',       10.00,      210.00, '2026-09-11 09:30:01+01'),
 (14, 6, 'CREDIT',   20010.00,   134900.00, '2026-09-11 09:30:01+01');

-- Account balances are derived from the ledger (credits - debits).
UPDATE account a
   SET balance = l.net
  FROM (SELECT account_id,
               SUM(CASE entry_type WHEN 'CREDIT' THEN amount ELSE -amount END) AS net
          FROM ledger_entry
         GROUP BY account_id) l
 WHERE a.account_id = l.account_id;

-- Explicit ids were used above, so move identity sequences past them.
SELECT setval(pg_get_serial_sequence('tosipay.customer', 'customer_id'), (SELECT MAX(customer_id) FROM customer));
SELECT setval(pg_get_serial_sequence('tosipay.agent',    'agent_id'),    (SELECT MAX(agent_id)    FROM agent));
SELECT setval(pg_get_serial_sequence('tosipay.account',  'account_id'),  (SELECT MAX(account_id)  FROM account));
SELECT setval(pg_get_serial_sequence('tosipay.biller',   'biller_id'),   (SELECT MAX(biller_id)   FROM biller));
SELECT setval(pg_get_serial_sequence('tosipay.txn',      'txn_id'),      (SELECT MAX(txn_id)      FROM txn));

COMMIT;
