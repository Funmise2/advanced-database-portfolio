from tosipay_redis import clear, heading, note, run

OTP_TTL = 300
MAX_ATTEMPTS = 3
clear("tosipay:otp*")

phone = "+2348031110001"
otp_key = f"tosipay:otp:{phone}"
attempts_key = f"tosipay:otp-attempts:{phone}"

heading("Issue a code. NX means: only if no valid code exists already")
run("SET", otp_key, "482913", "NX", "EX", OTP_TTL)
run("TTL", otp_key)

heading("She taps 'Resend' straight away")
run("SET", otp_key, "771045", "NX", "EX", OTP_TTL)
note("(nil): the first code is still valid, so no second code is created and no second SMS is paid for.")

heading("She types a wrong code")
run("INCR", attempts_key)
run("EXPIRE", attempts_key, OTP_TTL)
note("Wrong code: 1 of 3 attempts used. The code itself is kept.")

heading("She types the right code. GETDEL reads it and deletes it in one step")
run("GETDEL", otp_key)
run("DEL", attempts_key)
note("The code matched, so the new device is trusted.")

heading("Someone replays the same code a minute later")
run("GETDEL", otp_key)
note("(nil): the code was deleted when it was used, so it cannot be used twice.")

heading("A second login: someone guesses three times")
run("SET", otp_key, "305617", "NX", "EX", OTP_TTL)
for attempt in range(1, MAX_ATTEMPTS + 1):
    count = run("INCR", attempts_key)
    if attempt == 1:
        run("EXPIRE", attempts_key, OTP_TTL)
    note(f"Wrong code: {count} of {MAX_ATTEMPTS} attempts used.")
note("Third wrong attempt: the code is cancelled and the customer must request a new one.")
run("DEL", otp_key, attempts_key)
run("EXISTS", otp_key)
