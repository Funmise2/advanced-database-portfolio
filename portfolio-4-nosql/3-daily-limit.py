import threading
from datetime import datetime, timedelta, timezone

from tosipay_redis import clear, client, heading, note, run

LAGOS = timezone(timedelta(hours=1))
LIMIT = 50000
AMOUNT = 30000
clear("tosipay:limit:*")

today = datetime.now(LAGOS)
key = f"tosipay:limit:2010000038:{today:%Y%m%d}"
midnight = int(datetime(today.year, today.month, today.day, tzinfo=LAGOS).timestamp()) + 86400

heading("The counter: one key per wallet per day, expiring at midnight Lagos time")
run("SET", key, 0)
run("EXPIREAT", key, midnight)
run("TTL", key)
note("At midnight the key disappears, so tomorrow starts from 0 with no reset job.")

print_lock = threading.Lock()


def say(text):
    with print_lock:
        print(text)


heading("PART 1: read, check, write back (two payments at once)")
both_read = threading.Barrier(2)


def naive_payment(channel):
    spent = int(client.get(key) or 0)
    say(f"{channel}: reads spent today = {spent}")
    both_read.wait()
    if spent + AMOUNT <= LIMIT:
        client.set(key, spent + AMOUNT, keepttl=True)
        say(f"{channel}: {spent} + {AMOUNT} <= {LIMIT}, approved, writes {spent + AMOUNT}")
    else:
        say(f"{channel}: rejected")


threads = [threading.Thread(target=naive_payment, args=(channel,)) for channel in ("APP ", "USSD")]
for thread in threads:
    thread.start()
for thread in threads:
    thread.join()
run("GET", key)
note(f"Both payments were approved: NGN {2 * AMOUNT:,} against a limit of NGN {LIMIT:,},")
note("and the counter shows only one of them. The second write overwrote the first.")

heading("PART 2: check and add in one Lua script (two payments at once)")
CHECK_AND_ADD = """
local spent = tonumber(redis.call('GET', KEYS[1]) or '0')
local amount = tonumber(ARGV[1])
if spent + amount > tonumber(ARGV[2]) then
    return {0, spent}
end
local total = redis.call('INCRBY', KEYS[1], amount)
redis.call('EXPIREAT', KEYS[1], ARGV[3])
return {1, total}
"""
check_and_add = client.register_script(CHECK_AND_ADD)
run("SET", key, 0)
run("EXPIREAT", key, midnight)
both_ready = threading.Barrier(2)


def atomic_payment(channel):
    both_ready.wait()
    allowed, total = check_and_add(keys=[key], args=[AMOUNT, LIMIT, midnight])
    if allowed:
        say(f"{channel}: approved, spent today is now {total}")
    else:
        say(f"{channel}: rejected, {total} already spent today and {AMOUNT} more would pass {LIMIT}")


threads = [threading.Thread(target=atomic_payment, args=(channel,)) for channel in ("APP ", "USSD")]
for thread in threads:
    thread.start()
for thread in threads:
    thread.join()
run("GET", key)
run("TTL", key)
note("Redis runs one command or script at a time, so the second script saw the first one's total.")
note("Exactly one payment was approved, and the counter is correct.")

heading("If Redis loses the counter, it is rebuilt from PostgreSQL")
note("The counter is a fast first check, not the record of what was sent. PostgreSQL still checks")
note("the limit inside post_transfer() (Portfolio 3), and the counter can be rebuilt from the txn table")
note("with the daily limit query from Portfolio 2 (Q2), then written back with SET and EXPIREAT.")
