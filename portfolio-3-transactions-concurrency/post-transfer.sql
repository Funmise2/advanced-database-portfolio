SET search_path TO tosipay;

CREATE OR REPLACE FUNCTION post_transfer(
    p_reference     VARCHAR,
    p_from_number   CHAR(10),
    p_to_number     CHAR(10),
    p_amount        NUMERIC(18,2),
    p_fee           NUMERIC(18,2) DEFAULT 10,
    p_channel       VARCHAR       DEFAULT 'APP',
    p_narration     VARCHAR       DEFAULT 'Transfer'
) RETURNS BIGINT
LANGUAGE plpgsql AS $$
DECLARE
    v_src         account%ROWTYPE;
    v_dst         account%ROWTYPE;
    v_fee_acct    account%ROWTYPE;
    v_limit       NUMERIC(18,2);
    v_min_balance NUMERIC(18,2);
    v_sent_today  NUMERIC(18,2);
    v_reason      VARCHAR(200);
    v_txn_id      BIGINT;
    v_balance     NUMERIC(18,2);
BEGIN
    SELECT t.txn_id INTO v_txn_id FROM txn t WHERE t.reference = p_reference;
    IF FOUND THEN
        RAISE NOTICE 'Reference % was already posted as txn %: nothing done', p_reference, v_txn_id;
        RETURN v_txn_id;
    END IF;

    PERFORM 1
       FROM account a
      WHERE a.account_number IN (p_from_number, p_to_number, '0000000002')
      ORDER BY a.account_id
        FOR UPDATE;

    SELECT * INTO v_src      FROM account a WHERE a.account_number = p_from_number;
    SELECT * INTO v_dst      FROM account a WHERE a.account_number = p_to_number;
    SELECT * INTO v_fee_acct FROM account a WHERE a.account_number = '0000000002';
    IF v_src.account_id IS NULL OR v_dst.account_id IS NULL THEN
        RAISE EXCEPTION 'Unknown account number % or %', p_from_number, p_to_number;
    END IF;

    IF v_src.status <> 'ACTIVE' OR v_dst.status <> 'ACTIVE' THEN
        v_reason := 'Account is not active';
    END IF;

    IF v_reason IS NULL AND v_src.owner_kind = 'CUSTOMER' THEN
        SELECT k.daily_txn_limit INTO v_limit
          FROM customer c
          JOIN kyc_tier k ON k.kyc_tier_id = c.kyc_tier_id
         WHERE c.customer_id = v_src.customer_id;

        SELECT COALESCE(SUM(t.amount), 0) INTO v_sent_today
          FROM txn t
         WHERE t.source_account_id = v_src.account_id
           AND t.status = 'SUCCESS'
           AND t.created_at >= current_date;

        IF v_sent_today + p_amount > v_limit THEN
            v_reason := format('Daily limit exceeded: %s sent today, limit %s',
                               v_sent_today, v_limit);
        END IF;
    END IF;

    IF v_reason IS NULL THEN
        SELECT ty.min_balance INTO v_min_balance
          FROM account_type ty
         WHERE ty.account_type_code = v_src.account_type_code;

        IF v_src.owner_kind <> 'SYSTEM'
           AND v_src.balance - p_amount - p_fee < v_min_balance THEN
            v_reason := format('Insufficient funds: balance %s, needs %s',
                               v_src.balance, p_amount + p_fee);
        END IF;
    END IF;

    IF v_reason IS NOT NULL THEN
        INSERT INTO txn (reference, txn_type, channel, source_account_id, destination_account_id,
                         amount, fee, status, failure_reason, narration, completed_at)
        VALUES (p_reference, 'TRANSFER', p_channel, v_src.account_id, v_dst.account_id,
                p_amount, p_fee, 'FAILED', v_reason, p_narration, now())
        RETURNING txn_id INTO v_txn_id;
        RETURN v_txn_id;
    END IF;

    INSERT INTO txn (reference, txn_type, channel, source_account_id, destination_account_id,
                     amount, fee, status, narration, completed_at)
    VALUES (p_reference, 'TRANSFER', p_channel, v_src.account_id, v_dst.account_id,
            p_amount, p_fee, 'SUCCESS', p_narration, now())
    RETURNING txn_id INTO v_txn_id;

    UPDATE account a SET balance = a.balance - (p_amount + p_fee)
     WHERE a.account_id = v_src.account_id
    RETURNING a.balance INTO v_balance;
    INSERT INTO ledger_entry (txn_id, account_id, entry_type, amount, balance_after)
    VALUES (v_txn_id, v_src.account_id, 'DEBIT', p_amount + p_fee, v_balance);

    UPDATE account a SET balance = a.balance + p_amount
     WHERE a.account_id = v_dst.account_id
    RETURNING a.balance INTO v_balance;
    INSERT INTO ledger_entry (txn_id, account_id, entry_type, amount, balance_after)
    VALUES (v_txn_id, v_dst.account_id, 'CREDIT', p_amount, v_balance);

    IF p_fee > 0 THEN
        UPDATE account a SET balance = a.balance + p_fee
         WHERE a.account_id = v_fee_acct.account_id
        RETURNING a.balance INTO v_balance;
        INSERT INTO ledger_entry (txn_id, account_id, entry_type, amount, balance_after)
        VALUES (v_txn_id, v_fee_acct.account_id, 'CREDIT', p_fee, v_balance);
    END IF;

    RETURN v_txn_id;
END;
$$;

\echo 'post_transfer() created'
