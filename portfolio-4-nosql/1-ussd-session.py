import time

from tosipay_redis import clear, heading, note, run, server_summary

SESSION_TTL = 180
clear("tosipay:ussd:*")
server_summary()

key = "tosipay:ussd:ATUid_7f3c91"

heading("Key press 1: Halima dials *347*8#. A session hash is created")
run("HSET", key, "msisdn", "+2348031110003", "account", "2010000038", "menu", "MAIN")
run("EXPIRE", key, SESSION_TTL)
run("TTL", key)

heading("Key press 2: she chooses 1 (Send money)")
run("HSET", key, "menu", "ENTER_RECIPIENT")
run("EXPIRE", key, SESSION_TTL)

heading("Key press 3: she enters the recipient's account number")
run("HSET", key, "menu", "ENTER_AMOUNT", "recipient", "2010000054")
run("EXPIRE", key, SESSION_TTL)

heading("Two seconds later the session is still alive, and its timer counts down")
time.sleep(2)
run("TTL", key)
run("HGETALL", key)
note("Each key press reads and updates one small hash by its key: no table scan, no join.")

heading("Key press 4: she enters 5000 and confirms with her PIN")
run("HSET", key, "menu", "CONFIRM", "amount", "5000")
note("TosiPay now calls post_transfer() in PostgreSQL (Portfolio 3), then ends the session:")
run("DEL", key)
run("EXISTS", key)

heading("An abandoned session: the customer walks away in the middle of the menu")
abandoned = "tosipay:ussd:ATUid_a210be"
run("HSET", abandoned, "msisdn", "+2348031110005", "account", "2010000054", "menu", "ENTER_AMOUNT")
note("The demo uses a 3 second TTL instead of 180 seconds, so it does not have to wait 3 minutes.")
run("EXPIRE", abandoned, 3)
time.sleep(4)
run("EXISTS", abandoned)
note("Redis removed the session by itself when the TTL ran out. No clean-up job or DELETE was needed.")
