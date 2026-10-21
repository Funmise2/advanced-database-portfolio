import redis

r = redis.Redis(host="localhost", port=6379, decode_responses=True)
r.response_callbacks.clear()

client = redis.Redis(host="localhost", port=6379, decode_responses=True)


def show(reply, indent=""):
    if reply is None:
        return indent + "(nil)"
    if isinstance(reply, list):
        if not reply:
            return indent + "(empty array)"
        return "\n".join(f"{indent}{i}) {show(item).strip()}" for i, item in enumerate(reply, 1))
    if isinstance(reply, int):
        return f"{indent}(integer) {reply}"
    if reply == "OK":
        return indent + "OK"
    return f'{indent}"{reply}"'


def run(*command):
    reply = r.execute_command(*command)
    print("> " + " ".join(str(part) for part in command))
    print(show(reply))
    return reply


def heading(text):
    print()
    print(f"=== {text} ===")


def note(text):
    print(text)


def clear(pattern):
    for key in client.scan_iter(match=pattern):
        client.delete(key)


def server_summary():
    info = client.info("server")
    persistence = client.config_get("save")
    appendonly = client.config_get("appendonly")
    print(f"Server: {info.get('redis_version', '?')} "
          f"(save: {persistence.get('save') or 'off'}, appendonly: {appendonly.get('appendonly')})")
