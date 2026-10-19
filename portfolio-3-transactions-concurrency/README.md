# Portfolio 3: Transactions and Concurrency

A transfer in TosiPay changes several rows at once: the transaction header,
the balances of the sender, the receiver and the fee income account, and one
ledger line for each. This portfolio adds the **posting function** that
Portfolio 1 left for this stage, and uses it to show commit, rollback, a
concurrency problem with its fix, and the effect of isolation levels.

## Files

| File | Purpose |
|---|---|
| [post-transfer.sql](post-transfer.sql) | Creates `post_transfer()`, which posts one transfer as a single unit of work. Re-runnable. |
| [1-commit.sql](1-commit.sql) | Example 1: a transfer committed as one unit, then retried with the same reference. |
| [2-rollback.sql](2-rollback.sql) | Example 2: a transfer over the daily limit, and an unbalanced posting rolled back at `COMMIT`. |
| [3-double-spend-window-a.sql](3-double-spend-window-a.sql), [3-double-spend-window-b.sql](3-double-spend-window-b.sql) | Example 3: two payments from one wallet at the same time, without and with a row lock. |
| [4-isolation-window-a.sql](4-isolation-window-a.sql), [4-isolation-window-b.sql](4-isolation-window-b.sql) | Example 4: a balance sheet built under `READ COMMITTED` and `REPEATABLE READ` while a transfer commits. |
| `evidence/` | Output of every example. Examples 3 and 4 have one file per window. |

## How to run

Run from the repository root, after Portfolio 1 (Portfolio 2's data can be
loaded or not):

```bash
psql -U postgres -d tosipay -f portfolio-3-transactions-concurrency/post-transfer.sql
psql -U postgres -d tosipay -f portfolio-3-transactions-concurrency/1-commit.sql > portfolio-3-transactions-concurrency/evidence/1-commit.txt 2>&1
psql -U postgres -d tosipay -f portfolio-3-transactions-concurrency/2-rollback.sql > portfolio-3-transactions-concurrency/evidence/2-rollback.txt 2>&1
```

Examples 3 and 4 need two sessions. Open two terminals, start the window B
script first, then the window A script, and press Enter in each window when
its prompt asks. Each prompt names the step that has to run first in the
other window. For example 3:

```bash
psql -U postgres -d tosipay -f portfolio-3-transactions-concurrency/3-double-spend-window-b.sql 2>&1 | tee portfolio-3-transactions-concurrency/evidence/3-double-spend-window-b.txt
psql -U postgres -d tosipay -f portfolio-3-transactions-concurrency/3-double-spend-window-a.sql 2>&1 | tee portfolio-3-transactions-concurrency/evidence/3-double-spend-window-a.txt
```

Example 4 is run the same way with its own two files. Every example uses new
references on each run, so all of them can be run again. Examples 1, 3 and 4
really move money, so the balances in a new run will differ from the ones
below.

## The posting function

`post_transfer(reference, from, to, amount, fee, channel, narration)` does the
whole transfer inside the caller's transaction:

1. **Idempotency.** If the reference has been posted before, it returns that
   transaction and does nothing else. `txn.reference` is already `UNIQUE`
   (Portfolio 1), so a retried request from the app can never move money
   twice.
2. **Locking.** It locks the sender, the receiver and the fee income account
   with `SELECT ... FOR UPDATE`, always in `account_id` order, and only then
   reads their balances.
3. **Business checks**, the ones Portfolio 1 left for the posting logic:
   - both accounts are `ACTIVE`;
   - the sender's KYC daily limit (`kyc_tier.daily_txn_limit`) is not
     exceeded by today's successful transfers plus this one;
   - the sender keeps at least the account type's `min_balance`.

   A failed check is **not** an error. The attempt is saved as a `FAILED`
   transaction with a `failure_reason`, so it appears in the customer's
   history and in audit, and no money moves.
4. **Posting.** It inserts the `SUCCESS` transaction, updates each balance
   and writes the matching ledger line with its `balance_after`. The deferred
   `trg_ledger_balanced` trigger from Portfolio 1 then checks at `COMMIT` that
   debits equal credits.

## Example 1: COMMIT

Tunde Bakare pays Chinedu Eze NGN 5,000 from the app, with a NGN 10 fee
([evidence/1-commit.txt](evidence/1-commit.txt)).

| Account | Before | After `COMMIT` | Ledger line |
|---|---:|---:|---|
| Tunde's wallet `2010000021` | 134,900.00 | 129,890.00 | DEBIT 5,010.00 |
| Chinedu's wallet `2010000046` | 69,900.00 | 74,900.00 | CREDIT 5,000.00 |
| Fee income `0000000002` | 26,687,600.00 | 26,687,610.00 | CREDIT 10.00 |

Inside the transaction, the new rows and balances were visible to this session
only. At `COMMIT` they became visible to everyone at once (**atomicity**), and
from then on they survive a crash (**durability**). The ledger lines add up:
5,010 debited, 5,000 + 10 credited (**consistency**).

The same request was then sent again, as the app would after a timeout. The
function returned the same `txn_id` (902001) with the notice "was already
posted ... nothing done". There is still one transaction with that reference
and Tunde's balance did not change.

## Example 2: ROLLBACK

[evidence/2-rollback.txt](evidence/2-rollback.txt) shows two kinds of failure.

**Part A: a business failure.** Halima Sani is on KYC Tier 1, with a daily
limit of NGN 50,000. She tries to send NGN 60,000. The function saves the
attempt as `FAILED` with the reason "Daily limit exceeded: 0.00 sent today,
limit 50000.00". The transaction has no ledger lines and her balance stays at
40,000. A rejected payment is part of the business, so it is committed as a
record, not rolled back.

**Part B: a technical failure.** A hand-written correction moves NGN 5,000
from Adaeze Okafor to Chinedu with a NGN 10 fee, but forgets the fee's credit
line. Every statement succeeds, and inside the transaction Adaeze's balance
already shows 164,980. At `COMMIT` the deferred trigger finds the transaction
unbalanced:

```
ERROR:  Transaction 902003 is unbalanced: debits 5010.00 <> credits 5000.00
```

PostgreSQL then rolls back the **whole** transaction. Adaeze is back at
169,990, Chinedu at 74,900, and the transaction row does not exist. The error
came at the last step, after the balances had been changed, and still nothing
was kept. This is why the balanced-ledger rule is a `DEFERRABLE INITIALLY
DEFERRED` trigger: it has to wait until all the lines are in, and it can still
stop the commit.

## Example 3: double spend, and the fix

Adaeze pays from the app (window A) and over USSD (window B) at the same
moment. Each payment is 60% of her balance, so only one should be allowed
([window A](evidence/3-double-spend-window-a.txt),
[window B](evidence/3-double-spend-window-b.txt)).

**Part 1: read, check, write back, with no lock.** This is how a simple app
would do it:

| Step | Window A | Window B |
|---|---|---|
| 1 | Reads 67,986. Approves 40,792 | |
| 2 | | Reads 67,986. Approves 40,792 |
| 3 | Saves 67,986 − 40,792 = 27,194 and commits | |
| 4 | | Saves 67,986 − 40,792 = 27,194 and commits |

Payments worth 81,584 were approved against a balance of 67,986, but the
balance only went down once. Window B wrote over window A's change because it
worked from a balance that was already out of date: a **lost update**, which
in a wallet means a **double spend**. `READ COMMITTED` allows this, because each
statement on its own is correct.

The `audit_log` trigger from Portfolio 1 recorded both writes:

| Write | Old balance | New balance |
|---|---:|---:|
| Window A | 67,986.00 | 27,194.00 |
| Window B | 27,194.00 | 27,194.00 |

Window B's write changed nothing. The ledger had not been touched in this
part, so reconciliation showed the stored balance (27,194) and the ledger
(67,986) disagreeing, and the script repaired the balance from the ledger.

**Part 2: the same two payments through `post_transfer()`:**

| Step | Window A | Window B |
|---|---|---|
| 5 | Posts 40,792 and holds the row lock, not yet committed | |
| 6 | | Calls `post_transfer()` for 40,792 and **waits** for the lock |
| 7 | Commits and releases the lock | Gets the lock, reads 27,184 and records `FAILED: Insufficient funds: balance 27184.00, needs 40802` |

Window B read the balance only after it had the lock, so it saw window A's
payment. This is **pessimistic locking**: the second payment waits instead of
working from a stale balance.

## Example 4: isolation levels

A finance officer builds the daily balance sheet in two queries: what TosiPay
owes customers and agents, then the SYSTEM accounts. TosiPay is a closed
double-entry system, so the two must add up to exactly 0. Between the two
queries, Tunde sends NGN 20,000 (+ NGN 10 fee) to his bank account, which moves
money from his wallet to the SYSTEM accounts
([window A](evidence/4-isolation-window-a.txt),
[window B](evidence/4-isolation-window-b.txt)).

| Isolation level | Owed to customers and agents | SYSTEM accounts | Sum (must be 0) |
|---|---:|---:|---:|
| `READ COMMITTED` | 17,847,322,380.00 | −17,847,302,370.00 | **20,010.00** |
| `REPEATABLE READ` | 17,847,302,370.00 | −17,847,302,370.00 | **0.00** |

Under `READ COMMITTED` each query sees everything committed before **that
query** started. The second query saw the transfer and the first did not, so
the balance sheet is out by exactly the transfer plus its fee. Nothing is
wrong with the data; the two totals come from different moments.

Under `REPEATABLE READ` the transaction takes one snapshot at its first query
and reads from it until it ends. The second transfer committed in between,
but neither query saw it, so the totals match. A new query after `COMMIT` saw
it and still added up to 0.00.

Reports that combine several queries, such as this balance sheet or the
nightly reconciliation from Portfolio 2, should therefore run under
`REPEATABLE READ`. PostgreSQL never allows dirty reads (reading another
transaction's uncommitted changes), so `READ UNCOMMITTED` behaves like `READ
COMMITTED` and is not shown. `SERIALIZABLE` would also prevent anomalies that
`REPEATABLE READ` allows, at the cost of cancelling transactions that then
have to be retried; the row locks in `post_transfer()` already protect the
balances, so it is not needed here.

## Design notes

- **Deadlocks.** If transfer 1 locked Tunde then Chinedu while transfer 2
  locked Chinedu then Tunde, each could end up waiting for the other.
  PostgreSQL would detect this and cancel one of them. `post_transfer()`
  avoids it by always locking in `account_id` order, so two transfers in
  opposite directions queue instead.
- **Two retries at the same moment.** If the same reference arrives twice at
  once, both calls can pass the idempotency check before either has
  committed. The second one then waits on the `UNIQUE` index on
  `txn.reference` and fails when the first commits, so money still moves only
  once.
- **Failed attempts are committed.** A limit or balance failure is saved as a
  `FAILED` row instead of raising an error, because the customer's history and
  the audit trail should show it. Only genuine errors (an unknown account, an
  unbalanced ledger) roll back.

## Limitations and next steps

- **The fee income account is a hot spot.** Every transfer with a fee locks
  and updates the same row, so all fee-paying transfers queue on it, however
  unrelated their accounts are. A busier system would post fees to several
  fee accounts, or record them in the ledger only and update the stored fee
  balance in a periodic batch.
- `post_transfer()` covers transfers only. Deposits, withdrawals, bill
  payments and reversals would follow the same pattern.
- The receiver's `max_balance` for their KYC tier is not checked yet.
