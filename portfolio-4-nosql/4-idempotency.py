import threading

from tosipay_redis import clear, client, heading, note, run

DAY = 86400
clear("tosipay:idem:*")

reference = "TP-20261021-8841"
key = f"tosipay:idem:{reference}"

heading("First request: claim the reference")
run("SET", key, "PROCESSING", "NX", "EX", DAY)
note("OK: this request owns the reference and goes on to call post_transfer() in PostgreSQL.")

heading("The app times out and sends the same request again")
run("SET", key, "PROCESSING", "NX", "EX", DAY)
run("GET", key)
note("(nil): the reference is taken, so the retry is not processed. It is told the first request is still running.")

heading("The first request finishes: store its result, keeping the 24-hour expiry")
run("SET", key, "SUCCESS:txn=902140", "XX", "KEEPTTL")
run("TTL", key)

heading("A third copy arrives")
run("SET", key, "PROCESSING", "NX", "EX", DAY)
run("GET", key)
note("The third copy is answered with the stored result, without touching PostgreSQL.")

heading("Three copies of a new request arrive at exactly the same moment")
reference = "TP-20261021-8842"
key = f"tosipay:idem:{reference}"
start = threading.Barrier(3)
lock = threading.Lock()


def request(copy):
    start.wait()
    claimed = client.set(key, f"PROCESSING:copy{copy}", nx=True, ex=DAY)
    with lock:
        print(f"copy {copy}: {'claimed the reference, processing' if claimed else 'reference taken, not processed'}")


threads = [threading.Thread(target=request, args=(copy,)) for copy in (1, 2, 3)]
for thread in threads:
    thread.start()
for thread in threads:
    thread.join()
run("GET", key)
note("SET NX is a single atomic step, so exactly one copy claimed the reference.")
note("After 24 hours the key expires; by then the UNIQUE reference in PostgreSQL still blocks any late duplicate.")
