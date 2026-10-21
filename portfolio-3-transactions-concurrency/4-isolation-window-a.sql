SET search_path TO tosipay;

\echo
\echo '=== ISOLATION - WINDOW A: the daily balance sheet ==='
\echo
\echo '##### PART 1: READ COMMITTED (the PostgreSQL default) #####'
\prompt 'Once window B is waiting at its first prompt, press Enter here for step 1: ' go

\set ECHO queries
BEGIN ISOLATION LEVEL READ COMMITTED;
SELECT SUM(a.balance) AS owed_to_customers_and_agents
  FROM account a
 WHERE a.owner_kind <> 'SYSTEM' \gset
\set ECHO none
\echo 'Owed to customers and agents: NGN' :owed_to_customers_and_agents
\echo
\echo '>>> Next: step 2 in window B'
\prompt 'Do step 2 in window B first, then press Enter here for step 3: ' go

\set ECHO queries
SELECT :owed_to_customers_and_agents AS owed_to_customers_and_agents,
       SUM(a.balance)                AS system_accounts,
       :owed_to_customers_and_agents + SUM(a.balance) AS must_be_zero
  FROM account a
 WHERE a.owner_kind = 'SYSTEM';
COMMIT;
\set ECHO none
\echo 'The balance sheet does not add up. The second query saw the transfer that'
\echo 'committed after the first query, so the two totals come from different moments.'

\echo
\echo '##### PART 2: REPEATABLE READ #####'
\set ECHO queries
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT SUM(a.balance) AS owed_to_customers_and_agents
  FROM account a
 WHERE a.owner_kind <> 'SYSTEM' \gset
\set ECHO none
\echo 'Owed to customers and agents: NGN' :owed_to_customers_and_agents
\echo
\echo '>>> Next: step 4 in window B'
\prompt 'Do step 4 in window B first, then press Enter here for step 5: ' go

\set ECHO queries
SELECT :owed_to_customers_and_agents AS owed_to_customers_and_agents,
       SUM(a.balance)                AS system_accounts,
       :owed_to_customers_and_agents + SUM(a.balance) AS must_be_zero
  FROM account a
 WHERE a.owner_kind = 'SYSTEM';
COMMIT;
\set ECHO none
\echo 'The balance sheet adds up. Both queries read the snapshot taken at the first'
\echo 'query, so the transfer in window B is not half-included.'

\echo
\echo '--- After COMMIT, a new query sees window B''s second transfer, and still adds up ---'
SELECT SUM(a.balance) FILTER (WHERE a.owner_kind <> 'SYSTEM') AS owed_to_customers_and_agents,
       SUM(a.balance) FILTER (WHERE a.owner_kind = 'SYSTEM')  AS system_accounts,
       SUM(a.balance)                                         AS must_be_zero
  FROM account a;
\echo
\echo '=== Done ==='
