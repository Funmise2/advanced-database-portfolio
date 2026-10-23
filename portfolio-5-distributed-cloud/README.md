# Portfolio 5: Distributed and Cloud Databases

TosiPay holds customers' money, so one database server is a single point of
failure: if it stops, nobody can pay. This portfolio sets up **PostgreSQL
streaming replication** for the `tosipay` database, with a standby server that
keeps a live copy, and shows replication, reads from the copy, stale reads and
failover. It then discusses sharding and how TosiPay would be deployed.

## Files

| File | Purpose |
|---|---|
| [1-replication.sql](1-replication.sql) | A transfer on the primary appears on the standby; replication status on both servers. |
| [2-read-replica.sql](2-read-replica.sql) | Reports run on the standby; writes to the standby are refused. |
| [3-stale-read.sql](3-stale-read.sql) | A standby that has fallen behind returns an old balance, then catches up. |
| [4-promote.sql](4-promote.sql) | Failover: the standby is promoted to a primary and accepts payments. |
| `evidence/` | Output of the setup and of each script. |

## Setup

The primary is the PostgreSQL 18 server from Portfolios 1 to 4 (port 5432).
The standby is a second PostgreSQL 18 server on the same machine (port 5433),
created from a copy of the primary. Commands for Git Bash, from the repository
root ([evidence/0-setup.txt](evidence/0-setup.txt)):

```bash
"/c/Program Files/PostgreSQL/18/bin/pg_basebackup" -h localhost -p 5432 -U postgres -D "$HOME/tosipay-standby" -R -X stream -v
"/c/Program Files/PostgreSQL/18/bin/pg_ctl" -D "$HOME/tosipay-standby" -o "-p 5433 -c cluster_name=tosipay_standby" -l "$HOME/tosipay-standby.log" start
```

- `pg_basebackup` copies the primary's data files while it keeps running, and
  streams the write-ahead log (WAL) generated during the copy (`-X stream`), so
  the copy is consistent.
- `-R` writes `standby.signal` and the connection to the primary into the copy,
  so it starts as a standby.
- When it starts, the standby connects to the primary and keeps receiving and
  replaying the primary's WAL: every change made on the primary is replayed
  on the standby.

Physical replication copies a whole PostgreSQL server, not one database.
On a real deployment TosiPay would have servers of its own.

Then run the scripts in order. Script 1 starts on the primary, scripts 2 to 4
on the standby:

```bash
psql -U postgres -p 5432 -d tosipay -f portfolio-5-distributed-cloud/1-replication.sql > portfolio-5-distributed-cloud/evidence/1-replication.txt 2>&1
psql -U postgres -p 5433 -d tosipay -f portfolio-5-distributed-cloud/2-read-replica.sql > portfolio-5-distributed-cloud/evidence/2-read-replica.txt 2>&1
psql -U postgres -p 5433 -d tosipay -f portfolio-5-distributed-cloud/3-stale-read.sql > portfolio-5-distributed-cloud/evidence/3-stale-read.txt 2>&1
psql -U postgres -p 5433 -d tosipay -f portfolio-5-distributed-cloud/4-promote.sql > portfolio-5-distributed-cloud/evidence/4-promote.txt 2>&1
```

Script 4 turns the standby into a primary, so it must run last. To run the
examples again, or to remove the standby afterwards:

```bash
"/c/Program Files/PostgreSQL/18/bin/pg_ctl" -D "$HOME/tosipay-standby" stop
rm -rf "$HOME/tosipay-standby" "$HOME/tosipay-standby.log"
```

## 1. Replication

[evidence/1-replication.txt](evidence/1-replication.txt)

On the primary, `pg_stat_replication` showed the standby connected:

| application_name | state | sync_state | replay_lag |
|---|---|---|---|
| `tosipay_standby` | streaming | async | 0.007 s |

Tunde Bakare then paid Chinedu Eze NGN 2,500 through `post_transfer()`
(Portfolio 3), as transaction 902012. One second later, on the standby:

- `pg_stat_wal_receiver` showed it `streaming` from port 5432;
- its replay position had passed the primary's WAL position at the commit
  (`has_replayed_the_commit = t`);
- transaction 902012 was there, and Tunde's and Chinedu's balances (82,340.00
  and 225,186.00) were exactly the same as on the primary.

The standby received the change because it is in the WAL, not because the
application wrote it twice. Every committed change on the primary, including
the ledger lines and the audit log, reaches the standby the same way.

## 2. The standby as a read replica

[evidence/2-read-replica.txt](evidence/2-read-replica.txt)

The standby is in recovery (`is_standby = t`) and every transaction on it is
read-only (`transaction_read_only = on`). It can still answer queries:

| Query | Time on the standby | Result |
|---|---:|---|
| Nightly reconciliation (Portfolio 2, Q8d) | 74.9 ms | 0 mismatches |
| Balance sheet (Portfolio 3, example 4) | 27.9 ms | Sums to 0.00 |

Running reports here takes their load off the primary, which only has to
handle payments. Portfolio 2 suggested exactly this for the weekly full
reconciliation.

A payment and a direct balance update sent to the standby by mistake were
both refused:

```
ERROR:  cannot execute SELECT FOR UPDATE in a read-only transaction
ERROR:  cannot execute UPDATE in a read-only transaction
```

There is one primary, and every change must go through it. This is what keeps
the copies from disagreeing.

## 3. Consistency: a stale read

[evidence/3-stale-read.txt](evidence/3-stale-read.txt)

Replication here is **asynchronous**: the primary confirms a commit without
waiting for the standby. Normally the standby is only milliseconds behind,
so to make the gap visible the script pauses replay on the standby
(`pg_wal_replay_pause()`), as if it were overloaded or on a slow link.

| | Primary | Standby (replay paused) | Standby (after resume) |
|---|---:|---:|---:|
| Tunde's balance | 81,330.00 | **82,340.00** | 81,330.00 |
| The NGN 1,000 payment exists | yes | **no** | yes |

While paused, the standby had **received** the change (99,672 bytes of WAL
not yet applied, with `received_lsn` ahead of `applied_lsn`) but not applied
it. If Tunde's app had read his balance from the standby, he would have seen
the old amount just after paying: a **stale read**. Once replay resumed, the
standby caught up and agreed with the primary again: **eventual consistency**.

For TosiPay this means:

- Anything a customer has just changed must be read from the **primary**:
  the balance after a payment, and above all the balance check inside
  `post_transfer()`. The standby is for reports, where a few seconds' delay
  does not matter.
- PostgreSQL can also make replication **synchronous** with
  `synchronous_standby_names` and `synchronous_commit`. With
  `synchronous_commit = remote_apply`, a commit waits until the standby has
  applied it, so a read from the standby straight afterwards would see it.
  The cost is that every payment waits for the standby, and payments stop if
  the only synchronous standby is down. It was not switched on here, because
  it is a setting of the whole primary server.

## 4. Availability: failover

[evidence/4-promote.txt](evidence/4-promote.txt)

If the primary fails, the standby can take over. The script promoted it with
`pg_promote()`:

| | Before | After |
|---|---|---|
| `pg_is_in_recovery()` | true | false |
| `transaction_read_only` | on | off |
| Timeline | 1 | 2 |

The promoted server accepted a payment straight away (transaction 902044).
The **timeline** change matters: from the moment of promotion, the new
primary's history branches off from the old one, and PostgreSQL labels the
new branch so the two can never be mixed up.

In this demonstration the old primary kept running, so for a moment there
were two servers accepting payments: the payment on the promoted server did
not exist on the original. This is **split brain**. With money it would mean
two different balances for one wallet. In production, failover must therefore
**fence** the old primary first (shut it down or cut its network) before
promoting the standby. Tools such as Patroni do this automatically, using a
separate consensus store to agree on which server is the primary.

## 5. Sharding (discussion)

Sharding splits the data across several primaries, each holding part of it.
TosiPay does not need it yet: Portfolio 2's 2.3 million ledger entries fit in
a 177 MB table that one server handles comfortably, and a read replica can
take the reports.

If TosiPay grew to tens of millions of wallets, the natural shard key would
be the **account** (for example with Citus, which shards PostgreSQL tables):

- An account's ledger lines would live on the same shard as the account, so
  the mini statement (Portfolio 2, Q1) and the daily limit check (Q2) would
  each touch one shard.
- A transfer between two accounts on **different** shards would need both
  shards to commit or neither. That needs **two-phase commit** (PostgreSQL's
  `PREPARE TRANSACTION` and `COMMIT PREPARED`), which is slower and blocks if
  a shard fails between the two phases. The single-server guarantees from
  Portfolio 3 (one `COMMIT`, row locks, the deferred balance check) no longer
  come for free.
- The fee income and settlement accounts are touched by almost every transfer
  (the "hot spot" noted in Portfolio 3), so they would have to be split into
  several sub-accounts, one per shard, and totalled for reporting.

A cheaper first step is **partitioning** `ledger_entry` by month on one
server. Old months could then be moved to cheaper storage or dropped from
indexes without affecting current payments.

## 6. Deployment (discussion)

| Component | Where | Why |
|---|---|---|
| PostgreSQL primary | Data centre in Lagos | Customers and most partner banks are there. Nigerian rules for payment providers favour keeping customer data in Nigeria, and the Nigeria Data Protection Act 2023 governs personal data such as BVN and NIN |
| Synchronous standby | Same Lagos data centre, separate rack and power supply | Takes over on server failure with no lost payments. `synchronous_commit = on` costs only a millisecond inside one site |
| Asynchronous standby | A second data centre in Abuja | Survives the loss of the whole Lagos site. Asynchronous, because waiting for Abuja on every payment would be too slow; a few seconds of data could be lost in a disaster, which is accepted for this rare case |
| Read replica | Lagos | Reports, the reconciliation and analytics, as in section 2 |
| Redis (Portfolio 4) | Lagos, with its own replica | Sessions, codes and counters. Losing them is acceptable, as Portfolio 4 explains |
| Backups | WAL archived continuously plus a nightly base backup, kept in both cities and encrypted | **Point-in-time recovery**: the database can be restored to any moment, for example just before a bad deployment deleted data. Replication cannot do this, because a mistake is replicated too |

A managed cloud database (such as Amazon RDS or Azure Database for
PostgreSQL) would handle backups, replicas and failover automatically, but the
main cloud regions serving Africa are outside Nigeria. Unless a managed service
is available inside the country, TosiPay would run PostgreSQL itself on
Nigerian infrastructure, with a tool such as Patroni managing failover.

### CAP theorem

During a network partition, a distributed system must choose between
**consistency** (every read sees the latest write) and **availability** (every
request is answered).

- For payments, TosiPay chooses **consistency**. There is only one primary,
  and if the synchronous standby cannot be reached, payments wait rather than
  risk two servers with different balances. A delayed payment can be retried;
  a wallet that spends the same money twice cannot be undone.
- For reports and the balance a customer browses, TosiPay chooses
  **availability**: the read replica keeps answering even if it is a few
  seconds behind, as section 3 showed.

## Limitations

- Primary and standby ran on one laptop, so the demonstration shows how
  replication works, not how it behaves over a real network between cities.
- Synchronous replication and automatic failover were discussed, not set up.
