# Portfolio 2: Query Processing and Optimisation

Eight queries that TosiPay runs every day were measured on a realistic volume
of data with `EXPLAIN (ANALYZE, BUFFERS)`, before and after adding indexes.
The schema is the one from [Portfolio 1](../portfolio-1-database-design/).

## Files

| File | Purpose |
|---|---|
| [generate-data.sql](generate-data.sql) | Adds about 100,000 customers, 1,000 agents, 131,000 accounts, 900,000 transactions and 2.3 million ledger entries on top of the Portfolio 1 sample data. Uses a fixed random seed, so the data is the same on every run. |
| [queries.sql](queries.sql) | The eight workload queries. Prints the results, or the execution plans when run with `-v explain=...`. |
| [indexes.sql](indexes.sql) | Eight indexes, one or more per slow query, then `ANALYZE` and a list of index sizes. Re-runnable. |
| [evidence/query_results.txt](evidence/query_results.txt) | Results of the eight queries. |
| [evidence/plans_before.txt](evidence/plans_before.txt) | Execution plans before `indexes.sql`. |
| [evidence/indexes_output.txt](evidence/indexes_output.txt) | Output of `indexes.sql`, including the size of each index. It was captured on a second run, after the indexes already existed, so each `CREATE INDEX` reports "already exists, skipping". |
| [evidence/plans_after.txt](evidence/plans_after.txt) | Execution plans after `indexes.sql`. |

## How to run

Run from the repository root, after the Portfolio 1 `schema.sql` and
`seed.sql`:

```bash
psql -U postgres -d tosipay -f portfolio-2-query-optimisation/generate-data.sql
psql -U postgres -d tosipay -f portfolio-2-query-optimisation/queries.sql > portfolio-2-query-optimisation/evidence/query_results.txt 2>&1
psql -U postgres -d tosipay -v explain="EXPLAIN (ANALYZE, BUFFERS)" -f portfolio-2-query-optimisation/queries.sql > portfolio-2-query-optimisation/evidence/plans_before.txt 2>&1
psql -U postgres -d tosipay -f portfolio-2-query-optimisation/indexes.sql > portfolio-2-query-optimisation/evidence/indexes_output.txt 2>&1
psql -U postgres -d tosipay -v explain="EXPLAIN (ANALYZE, BUFFERS)" -f portfolio-2-query-optimisation/queries.sql > portfolio-2-query-optimisation/evidence/plans_after.txt 2>&1
```

`generate-data.sql` ends by checking that the sum of all account balances is
still 0, so the generated data obeys the same double-entry rule as the seed
data.

## The workload

| # | Query | Who runs it | Index added for it |
|---|---|---|---|
| Q1 | Mini statement: last 10 ledger entries on a wallet | Customer, on the app home screen | `ledger_entry (account_id, posted_at, entry_id)` |
| Q2 | Daily limit check: amount sent today | Payment service, before every payment | `txn (source_account_id, created_at)` |
| Q3 | All of a customer's transactions in a month, found by phone number | Customer care | `account (customer_id)`, `txn (source_account_id, created_at)`, `txn (destination_account_id, created_at)` |
| Q4 | A transaction and its ledger lines, by reference | Disputes team | `ledger_entry (txn_id)` |
| Q5 | Cash in and cash out at one agent for a day | Agent, end of day | `account (agent_id)` and the two `txn` indexes above |
| Q6 | Failed transactions per channel, last 7 days | Operations dashboard | partial index `txn (created_at) WHERE status = 'FAILED'` |
| Q7 | Bill payment volume per biller for a month | Finance, monthly report | BRIN index `txn (created_at)` |
| Q8 | Accounts whose stored balance differs from the ledger | Nightly reconciliation job | none (see below) |

Each query uses fixed example values (one wallet, one customer, one agent, one
day), so every run measures the same work. The results are in
[evidence/query_results.txt](evidence/query_results.txt). Q8 returns no rows,
which is correct: every stored balance matches the ledger.

## Results

| # | Before | After | Plan before | Plan after |
|---|---:|---:|---|---|
| Q1 | 152.9 ms | 0.4 ms | Parallel seq scan of all 2.3M `ledger_entry` rows to find the wallet's 11 | Index scan on `idx_ledger_account_posted` reads only those 11 |
| Q2 | 145.7 ms | 0.2 ms | Parallel seq scan of `txn`, about 899,000 rows removed by the filter | Index scan on `idx_txn_source_created`: one account, one day |
| Q3 | 123.7 ms | 0.2 ms | Seq scan of `txn` for June (74,000 rows) and of all 131,000 accounts, then the `OR` join checked 49,598 times per worker | `idx_account_customer` finds the 2 accounts; a `BitmapOr` of the source and destination indexes finds the transactions |
| Q4 | 115.3 ms | 0.2 ms | Parallel seq scan of `ledger_entry` for 3 lines | Index scan on `idx_ledger_txn` |
| Q5 | 83.2 ms | 0.5 ms | Seq scans of `txn` and `account` | `idx_account_agent`, then the same `BitmapOr` as Q3 |
| Q6 | 83.8 ms | 0.7 ms | Parallel seq scan of `txn`, 900,000 rows read for 512 | Index scan on the partial index `idx_txn_failed_created`, which only holds failed transactions |
| Q7 | 90.2 ms | 46.9 ms | Parallel seq scan of `txn` for May | Bitmap heap scan driven by the BRIN index `idx_txn_created_brin` |
| Q8 | 654.5 ms | 673.0 ms | Full aggregate of `ledger_entry`, spilling to disk | Same plan: no index can help |

Times move by a few milliseconds between runs. Several "before" plans also
read pages from disk (`read=` in the `Buffers` lines) while the "after" runs
found most pages in memory, so only the large differences should be read as
the effect of the indexes.

## What the plans show

**Foreign keys are not indexed automatically.** PostgreSQL creates an index
for every primary key and `UNIQUE` constraint, but not for foreign keys.
`ledger_entry.account_id`, `ledger_entry.txn_id`, `account.customer_id` and
`account.agent_id` had no index, so Q1, Q3, Q4 and Q5 read whole tables to
return a handful of rows. This was already noted as a limitation in
Portfolio 1.

**Equality column first, range column second.** In
`txn (source_account_id, created_at)` all of one account's transactions are
stored together in time order, so "this account, today" is one short range in
the index. Q2 runs before every payment, so it matters most: it went from
146 ms to 0.2 ms. With the columns the other way round, the index would have
to scan every transaction of the day and filter by account.

**`OR` across two columns needs two indexes.** Q3 and Q5 look for transactions
where the account is the source *or* the destination. One composite index
cannot answer both sides, so there is one index per side. The planner scans
both and combines them with `BitmapOr`. Before the indexes, the same `OR` was
checked as a join filter against every June transaction.

**Partial index for a rare status.** Only about 3% of transactions fail. The
partial index on `created_at WHERE status = 'FAILED'` holds only those rows,
so it is small, and it is not touched at all when a successful transaction is
inserted. The query's `WHERE status = 'FAILED'` matches the index condition,
so the planner can use it.

**BRIN for a large date range.** Q7 reads a whole month, about 75,000
transactions. A B-tree would be large and the planner would probably still
prefer a sequential scan for that many rows. Because transactions are
inserted in time order, `created_at` follows the physical order of the table,
and a BRIN index only stores the lowest and highest `created_at` for each
block range. It costs a few pages instead of megabytes. The plan shows the
trade-off: the bitmap is lossy (`Heap Blocks: lossy=1408`), so 12,060 rows
from neighbouring days were read and thrown away on recheck. Q7 roughly
halved, from 90 ms to 47 ms. Part of that is the cache effect noted above,
since the "after" run read no pages from disk.

**Q1 still sorts.** The comment in `indexes.sql` expected the index on
`(account_id, posted_at, entry_id)` to return rows already in order, with no
sort. In the plan, the planner fetched the wallet's 11 entries through the
index and then sorted them, because sorting 11 rows costs almost nothing. For
a wallet with thousands of entries the planner would be expected to scan the
index backwards and stop after 10 rows instead. Either way the cost is now
proportional to one wallet, not to the whole ledger.

**Some queries cannot be fixed with an index.** Q8 has to add up every one of
the 2.3 million ledger entries to compare each account with its stored
balance. There is no filter for an index to use, so the plan is the same
before and after. The plan also shows the hash aggregate running out of
memory and spilling to disk (`Batches: 21 ... Disk Usage: 23416kB`). Options
for this query are:

- raise `work_mem` for the reconciliation job only (`SET LOCAL work_mem`),
  so the aggregate stays in memory;
- reconcile only the accounts that had postings since the last run, which
  turns a full scan into an indexed lookup;
- keep the full check but run it on a read replica (Portfolio 5), so it does
  not compete with live payments.

At 0.7 seconds a night the query is not a problem yet. It would become one as
the ledger grows, because its cost grows with the whole history.

## Cost of the indexes

Indexes are not free. Every payment inserts one `txn` row and two or three
`ledger_entry` rows, and each of those now updates more indexes:

- `txn`: primary key, `reference`, `reverses_txn_id`, plus the two new
  B-trees, the partial index (only for failed transactions) and the BRIN
  index;
- `ledger_entry`: primary key plus the two new B-trees.

TosiPay reads far more often than it writes (every app screen, every limit
check, every agent report), so the trade is worth it here. The deferred
`trg_ledger_balanced` trigger from Portfolio 1 also benefits, because it sums
a transaction's ledger lines by `txn_id` at every commit and can now use
`idx_ledger_txn`.

Indexes also take disk space. The sizes from
[evidence/indexes_output.txt](evidence/indexes_output.txt):

| Index | Type | Size | Table size |
|---|---|---:|---:|
| `idx_ledger_account_posted` | B-tree | 91 MB | 177 MB |
| `idx_ledger_txn` | B-tree | 39 MB | 177 MB |
| `idx_txn_destination_created` | B-tree | 27 MB | 112 MB |
| `idx_txn_source_created` | B-tree | 27 MB | 112 MB |
| `idx_account_customer` | B-tree | 2.7 MB | 22 MB |
| `idx_account_agent` | B-tree | 0.9 MB | 22 MB |
| `idx_txn_failed_created` | B-tree, partial | 408 kB | 112 MB |
| `idx_txn_created_brin` | BRIN | 24 kB | 112 MB |

Together the eight indexes take about 188 MB, against 311 MB for the three
tables. The two `ledger_entry` indexes alone are 130 MB, three-quarters of
the table they index, because the ledger is the largest and fastest-growing
table. The sizes also show why the index type matters:

- The **BRIN** index on `created_at` is **24 kB**. A B-tree on the same
  column of `txn` would be expected to be similar to the other `txn` B-trees,
  about 27 MB, roughly a thousand times larger.
- The **partial** index is **408 kB**, because it only holds the 3% of
  transactions that failed.
- `idx_ledger_account_posted` is the largest index at 91 MB, because it has
  three columns and covers every ledger entry.

## Limitations

- The data is generated, so the spread of values is more even than real
  traffic. For example every biller has almost the same number of payments in
  Q7.
- Each query was measured once before and once after. Repeated runs would
  give a more reliable average.
