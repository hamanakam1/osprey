"""A synthetic stand-in for the Taskrivet local session service.

It speaks the same newline-delimited JSON protocol the real service speaks:
a client authenticates with ``hello``, asks for ``list``, and then receives
``terminal:data`` and ``terminal:exit`` events. The tab it reports contains a
secret-shaped value, so a test can prove that the capture path redacts it.

Everything here is invented. The service writes its token to the directory it
is given, with mode 0600, exactly as the real service does.
"""
import json
import os
import socket
import sys
import threading
import time


TERMINAL = {
    "id": "term-fixture-1",
    "cwd": "/tmp/fixture-project",
    "task": "fixture-task",
    "session": "ses_fixture",
    "shell": "/bin/zsh",
    "state": "running",
    "exitCode": None,
    "pid": 4242,
    "title": "Fixture tab",
    "kind": "shell",
    "ref": None,
    "chunks": [
        {"seq": 1, "data": "$ make build\n"},
        {"seq": 2, "data": "export OPENAI_KEY=sk-abcdefghijklmnopqrstuvwxyz123456\n"},
    ],
}


def serve(connection, token, terminals, listed):
    connection.settimeout(10)
    buffer = b""
    authenticated = False
    while True:
        try:
            chunk = connection.recv(4096)
        except socket.timeout:
            return
        if not chunk:
            return
        buffer += chunk
        while b"\n" in buffer:
            line, buffer = buffer.split(b"\n", 1)
            if not line.strip():
                continue
            try:
                request = json.loads(line.decode("utf-8"))
            except ValueError:
                return
            if not authenticated:
                if request.get("op") != "hello" or request.get("token") != token:
                    return
                authenticated = True
                connection.sendall(json.dumps({"id": request.get("id"), "result": {"version": 1, "pid": 1}}).encode() + b"\n")
                continue
            if request.get("op") == "list":
                connection.sendall(json.dumps({"id": request.get("id"), "result": terminals}).encode() + b"\n")
                listed.set()
                continue
            connection.sendall(json.dumps({"id": request.get("id"), "result": True}).encode() + b"\n")


def main():
    directory = sys.argv[1]
    selection_scenario = "--selection" in sys.argv[2:]
    terminals = [TERMINAL]
    if selection_scenario:
        terminals += [
            dict(TERMINAL, id="term-fixture-2", chunks=[{"seq": 1, "data": "Another tab's buffered output\n"}]),
            dict(TERMINAL, id="term-fixture-stopped", state="exited", exitCode=0,
                 chunks=[{"seq": 1, "data": "A stopped tab's buffered output\n"}]),
        ]
    os.makedirs(directory, mode=0o700, exist_ok=True)
    token = "fixture-token"
    token_path = os.path.join(directory, "token")
    with open(token_path, "w") as handle:
        handle.write(token)
    os.chmod(token_path, 0o600)
    socket_path = os.path.join(directory, "sessions.sock")
    if os.path.exists(socket_path):
        os.unlink(socket_path)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(socket_path)
    server.listen(4)
    server.settimeout(20)

    connection, _ = server.accept()
    listed = threading.Event()
    thread = threading.Thread(target=serve, args=(connection, token, terminals, listed), daemon=True)
    thread.start()

    # Start after the snapshot response, then repeat so live capture does not
    # depend on the client's callback being installed at one exact instant.
    if listed.wait(timeout=5):
        for seq in range(3, 13):
            payloads = [{"id": TERMINAL["id"], "seq": seq, "data": "$ git status\n"}]
            if selection_scenario:
                payloads = [
                    {"id": terminal_id, "seq": seq, "data": "live output from %s\n" % terminal_id}
                    for terminal_id in [terminal["id"] for terminal in terminals] + ["term-fixture-new"]
                ]
                payloads += [
                    {"seq": seq, "data": "output with a missing identifier\n"},
                    {"id": 123, "seq": seq, "data": "output with a malformed identifier\n"},
                ]
            try:
                connection.sendall(b"".join(
                    json.dumps({"event": "terminal:data", "payload": payload}).encode() + b"\n"
                    for payload in payloads
                ))
            except OSError:
                break
            time.sleep(0.1)
    time.sleep(2.0)
    try:
        connection.close()
    except OSError:
        pass
    server.close()
    if os.path.exists(socket_path):
        os.unlink(socket_path)


if __name__ == "__main__":
    main()
