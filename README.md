# Advanced Database Systems Portfolio (MIT 8103)

Individual practical database portfolio for MIT 8103 Advanced Database Systems,
2026/2027 First Semester.

## Case study: TosiPay

TosiPay is a simulated Nigerian mobile wallet and agent banking platform.
Customers hold wallets, savings and current accounts; POS agents provide cash-in
and cash-out services; and the platform processes transfers, deposits,
withdrawals, bill payments and reversals.

- **Users of the database:** customers (via app and USSD), POS agents,
  TosiPay operations and compliance staff, and internal services.
- **Major data:** customers and KYC details (BVN, NIN, tier), agents, accounts,
  transactions, double-entry ledger postings, billers and an audit log.
- **Key operations:** open accounts, deposit and withdraw cash through agents,
  transfer funds, pay bills, reverse failed or disputed transactions, and
  audit account balances.

## Repository structure

| Folder | Portfolio activity | Status |
|---|---|---|
| [portfolio-1-database-design](portfolio-1-database-design/) | Database design and modelling | In progress |
| portfolio-2-query-optimisation | Query processing and optimisation | Not started |
| portfolio-3-transactions-concurrency | Transactions and concurrency | Not started |
| portfolio-4-nosql | NoSQL and advanced data models | Not started |
| portfolio-5-distributed-cloud | Distributed and cloud databases | Not started |

## Requirements

- PostgreSQL 16 or later (developed and tested on PostgreSQL 18)
