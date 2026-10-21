# Portfolio 4: NoSQL and Advanced Data Models

PostgreSQL holds TosiPay's money: customers, accounts, transactions and the
double-entry ledger. Around every payment there is also short-lived data that
is read and written constantly but never needs a join or a report: USSD menu
sessions, one-time passwords, the running total for the daily limit, and the
references of requests already seen. This portfolio models that data in a
**key-value store**, Redis (run on Windows as Memurai, which is Redis 8.2
compatible), and explains why it suits it better than the relational database.

## Files

| File | Purpose |
|---|---|
| [tosipay_redis.py](tosipay_redis.py) | Shared connection and printing helpers. Each command is printed with Redis's raw reply, the way `redis-cli` shows it. |
| [1-ussd-session.py](1-ussd-session.py) | Example 1: USSD session state in a hash that expires by itself. |
| [2-otp.py](2-otp.py) | Example 2: one-time passwords that expire, can be used once, and allow 3 attempts. |
| [3-daily-limit.py](3-daily-limit.py) | Example 3: the daily limit counter, first with a race, then atomic with a Lua script. |
| [4-idempotency.py](4-idempotency.py) | Example 4: claiming a request reference with `SET NX` so duplicates are not processed. |
| [requirements.txt](requirements.txt) | The Python Redis client (`redis` 5.2.1). |
| `evidence/` | Output of each example. |

## How to run

Needs a Redis-compatible server on `localhost:6379` (developed with Memurai
8.1, Redis 8.2.5) and Python 3 with the client library:

```bash
python -m pip install -r portfolio-4-nosql/requirements.txt
python portfolio-4-nosql/1-ussd-session.py > portfolio-4-nosql/evidence/1-ussd-session.txt 2>&1
python portfolio-4-nosql/2-otp.py > portfolio-4-nosql/evidence/2-otp.txt 2>&1
python portfolio-4-nosql/3-daily-limit.py > portfolio-4-nosql/evidence/3-daily-limit.txt 2>&1
python portfolio-4-nosql/4-idempotency.py > portfolio-4-nosql/evidence/4-idempotency.txt 2>&1
```

Each script only creates and deletes keys that start with `tosipay:`, and
clears its own keys first, so it can be run again.

## Key design

A key-value store has no tables and no schema. The only way to find a value is
by its key, so the key names are the data model:

| Key | Type | Expires | Holds |
|---|---|---|---|
| `tosipay:ussd:{session_id}` | Hash | 180 s after the last key press | Where the customer is in the USSD menu, and what they have entered so far |
| `tosipay:otp:{phone}` | String | 300 s | The 6-digit code sent by SMS |
| `tosipay:otp-attempts:{phone}` | String (counter) | 300 s | Wrong attempts for that code |
| `tosipay:limit:{account_number}:{yyyymmdd}` | String (counter) | Midnight, Lagos time | Amount sent today |
| `tosipay:idem:{reference}` | String | 24 h | `PROCESSING`, then the result of the request |

Every key is built from something the service already knows when the request
arrives (the network's session id, the phone number, the account number and
date, the request reference), so each read is a single lookup. The
`tosipay:` prefix keeps these keys apart from anything else on the server.

## Example 1: USSD session state

Halima Sani dials `*347*8#` on a feature phone to send money. The network
sends each key press to TosiPay with a session id and drops the session after
about 3 minutes of silence ([evidence/1-ussd-session.txt](evidence/1-ussd-session.txt)).

- Each key press is one `HSET` on the session's hash plus `EXPIRE 180`, which
  restarts the 3-minute timer. Two seconds after the last key press, `TTL`
  showed 178 seconds left and `HGETALL` returned the whole session: menu step,
  recipient and amount.
- When she confirmed, TosiPay would call `post_transfer()` in PostgreSQL
  (Portfolio 3) and `DEL` the session.
- An abandoned session was given a 3-second TTL for the demo. Four seconds
  later `EXISTS` returned 0: Redis had removed it by itself.

In PostgreSQL this would be a `ussd_session` table written on every key press,
with a scheduled job to delete abandoned rows, and every row would also go
through the write-ahead log and leave dead rows for `VACUUM`. None of that
data is needed once the session ends.

## Example 2: one-time passwords

Adaeze Okafor logs in on a new phone and is sent a code
([evidence/2-otp.txt](evidence/2-otp.txt)).

- `SET ... NX EX 300` creates the code only if none is valid. Pressing
  "Resend" straight away returned `(nil)`, so no second code or SMS was
  created.
- `GETDEL` reads the code and deletes it in one step. The right code was
  accepted once; replaying it returned `(nil)`.
- Wrong attempts are counted with `INCR` on a key with the same expiry. After
  3 wrong attempts the code and the counter were deleted.

## Example 3: the daily limit counter

Halima's KYC Tier 1 limit is NGN 50,000. She sends two NGN 30,000 payments at
the same moment from the app and from USSD; only one should be allowed
([evidence/3-daily-limit.txt](evidence/3-daily-limit.txt)).

The counter key includes the date and expires at midnight Lagos time
(`EXPIREAT`), so the next day starts from 0 without a reset job.

| Approach | APP | USSD | Counter afterwards |
|---|---|---|---|
| `GET`, check in the application, `SET` | Read 0, approved | Read 0, approved | 30,000 (should be 60,000, and the second payment should have been refused) |
| One Lua script: read, check and `INCRBY` | Rejected: 30,000 already spent | Approved | 30,000 |

The first approach is the same **lost update** as Portfolio 3, example 3: both
requests read 0 before either wrote. In PostgreSQL it was fixed with a row
lock. Redis has no row locks, but it runs one command or script at a time. A
Lua script therefore runs as a single step, and no other request can read the
counter between the check and the `INCRBY`.

The Redis counter is a fast first check, not the record of what was sent.
`post_transfer()` still checks the limit against the `txn` table inside the
PostgreSQL transaction. If the counter is lost, it can be rebuilt with the
daily limit query from Portfolio 2 (Q2).

## Example 4: idempotency keys

On a weak network the app often sends the same payment request two or three
times ([evidence/4-idempotency.txt](evidence/4-idempotency.txt)).

- The first copy claims the reference with `SET tosipay:idem:{reference}
  PROCESSING NX EX 86400` and gets `OK`. A retry gets `(nil)` and is told the
  first copy is still running.
- When the payment finishes, the result is stored with `SET ... XX KEEPTTL`.
  The `txn` number in the demo is illustrative. A later copy is answered from
  Redis without touching PostgreSQL.
- Three copies of a new request were started at exactly the same moment.
  Exactly one got the reference; the other two were turned away.

PostgreSQL already makes duplicates impossible with the `UNIQUE` reference on
`txn` (Portfolio 1) and the check in `post_transfer()` (Portfolio 3). Redis adds
an earlier, cheaper check, so duplicates never reach the database at all.

## Why a key-value store suits this data

- **Every access is by a known key.** The session id, phone number, account
  and date, or request reference is always known. Nothing is ever searched by
  value, joined or aggregated, which is all a key-value store needs to support.
- **The data expires.** USSD sessions, codes, daily totals and references are
  only useful for minutes to a day. A TTL on each key deletes it at the right
  moment. In PostgreSQL every one of these would need a clean-up job.
- **It is written far more often than the ledger.** Every key press and every
  payment attempt touches it. Redis keeps the data in memory and answers in
  well under a millisecond, which keeps that load off the database that holds
  the money.
- **Atomic operations replace locks.** `INCR`, `SET NX`, `GETDEL` and Lua
  scripts each run as one step, which is enough to stop the lost update in
  example 3 and the duplicate requests in example 4.

### What is given up

- **Durability.** The server in these runs saves a snapshot to disk at most
  every 60 seconds (`save 3600 1 300 100 60 10000`) and has the append-only log
  turned off (`appendonly: no`). A crash can lose the last minute of changes.
  That is acceptable here only because every value can be lost or rebuilt: a
  customer redials USSD, requests a new code, the daily total is recomputed
  from `txn`, and PostgreSQL still rejects duplicate references.
- **No queries across keys.** There is no way to ask "which sessions are on
  the confirm screen" or "who has sent the most today" without reading every
  key. Reports stay in PostgreSQL.
- **No relationships or constraints.** Nothing stops a counter key from naming
  an account that does not exist. Integrity rules stay in PostgreSQL.
- **Memory.** All data must fit in RAM, which is why only small, short-lived
  values are stored, each with an expiry.

So money, balances, the ledger and KYC stay in PostgreSQL, where Portfolios 1
to 3 enforce them with constraints and transactions. Redis holds only what is
cheap to lose.

### Other NoSQL models considered

| Model | Fit for TosiPay |
|---|---|
| Document (e.g. MongoDB) | Could hold KYC documents or app activity events, whose shape varies. Not needed for the data above, which is too small and simple for documents |
| Column-family (e.g. Cassandra) | Suits very high write volumes spread over many servers, such as storing every app event for years. More than TosiPay's current volume needs |
| Graph (e.g. Neo4j) | The strongest candidate for **fraud detection**: following money through chains of wallets, or finding many accounts that share one device or agent. A natural next step, but a different problem from the real-time state above |
