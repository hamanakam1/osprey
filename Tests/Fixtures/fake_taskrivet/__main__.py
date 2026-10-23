"""A synthetic stand-in for the Taskrivet coordination ledger.

It implements the small slice of the Taskrivet CLI contract that Osprey uses:
task-add, start, checkpoint, fail, and status. It keeps its state in one
SQLite file and enforces the same cumulative-token rule the real ledger
enforces, so a test can prove that Osprey carries a reported count forward
instead of resetting it.

This fixture exists so the test suite does not need a Taskrivet checkout.
Every value it produces is invented.
"""
import json
import os
import sqlite3
import sys
import time
import uuid


def open_db(path):
    connection = sqlite3.connect(path)
    connection.execute(
        "CREATE TABLE IF NOT EXISTS tasks (id TEXT PRIMARY KEY, objective TEXT, acceptance TEXT, scope TEXT, status TEXT)"
    )
    connection.execute(
        "CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, task_id TEXT, owner TEXT, tokens INTEGER, status TEXT, progress TEXT, stagnant INTEGER)"
    )
    connection.commit()
    return connection


def require(value, name):
    if not value:
        raise SystemExit("osprey-test-fixture: %s is required" % name)


def main(argv):
    database = os.environ.get("TASKRIVET_DB", "fixture.sqlite")
    command = None
    arguments = []
    index = 0
    while index < len(argv):
        argument = argv[index]
        if argument == "--db":
            database = argv[index + 1]
            index += 2
            continue
        if command is None:
            command = argument
        else:
            arguments.append(argument)
        index += 1

    require(command, "a command")
    failure_path = database + ".failure.json"
    if os.path.exists(failure_path):
        with open(failure_path) as handle:
            failure = json.load(handle)
        if failure["command"] == command:
            print(json.dumps(failure["stdout"]))
            print(failure["stderr"], file=sys.stderr)
            raise SystemExit(failure["status"])
    connection = open_db(database)

    if command == "task-add":
        task_id = arguments[0]
        options = {}
        for position, argument in enumerate(arguments):
            if argument.startswith("--"):
                options[argument] = arguments[position + 1]
        require(options.get("--objective"), "--objective")
        require(options.get("--acceptance"), "--acceptance")
        require(options.get("--scope"), "--scope")
        connection.execute(
            "INSERT OR REPLACE INTO tasks (id, objective, acceptance, scope, status) VALUES (?,?,?,?,?)",
            (task_id, options["--objective"], options["--acceptance"], options["--scope"], "ready"),
        )
        connection.commit()
        print(json.dumps({"task": task_id, "status": "ready"}))
        return

    if command == "start":
        task_id = arguments[0]
        owner = "unknown"
        for position, argument in enumerate(arguments):
            if argument == "--owner":
                owner = arguments[position + 1]
        row = connection.execute("SELECT id FROM tasks WHERE id=?", (task_id,)).fetchone()
        require(row is not None, "an existing task")
        session_id = "ses_" + uuid.uuid4().hex[:24]
        connection.execute(
            "INSERT INTO sessions (id, task_id, owner, tokens, status, progress, stagnant) VALUES (?,?,?,?,?,?,?)",
            (session_id, task_id, owner, 0, "active", "", 0),
        )
        connection.commit()
        print(json.dumps({"session_id": session_id, "task": task_id, "owner": owner}))
        return

    if command == "checkpoint":
        session_id = arguments[0]
        options = {}
        for position, argument in enumerate(arguments):
            if argument.startswith("--"):
                options[argument] = arguments[position + 1]
        require(options.get("--summary"), "--summary")
        require(options.get("--evidence"), "--evidence")
        require(options.get("--next"), "--next")
        require(options.get("--tokens"), "--tokens")
        tokens = int(options["--tokens"])
        row = connection.execute("SELECT id, tokens FROM sessions WHERE id=?", (session_id,)).fetchone()
        require(row is not None, "an existing session")
        if tokens < row[1]:
            raise SystemExit("osprey-test-fixture: cumulative token count cannot decrease")
        connection.execute(
            "UPDATE sessions SET tokens=?, progress=?, stagnant=0, status=? WHERE id=?",
            (tokens, options["--evidence"], "active", session_id),
        )
        connection.commit()
        print(json.dumps({"session_id": session_id, "status": "active", "tokens": tokens}))
        return

    if command == "fail":
        session_id = arguments[0]
        options = {}
        for position, argument in enumerate(arguments):
            if argument.startswith("--"):
                options[argument] = arguments[position + 1]
        require(options.get("--category"), "--category")
        require(options.get("--summary"), "--summary")
        connection.execute("UPDATE sessions SET status='failed' WHERE id=?", (session_id,))
        connection.commit()
        print(json.dumps({"session_id": session_id, "status": "failed"}))
        return

    if command == "status":
        tasks = [dict(zip(("id", "objective", "acceptance", "scope", "status"), row)) for row in
                 connection.execute("SELECT id, objective, acceptance, scope, status FROM tasks ORDER BY id")]
        sessions = [dict(zip(("id", "task_id", "owner", "tokens", "status"), row)) for row in
                    connection.execute("SELECT id, task_id, owner, tokens, status FROM sessions ORDER BY id")]
        print(json.dumps({
            "tasks": tasks,
            "sessions": sessions,
            "failures": [],
            "metrics": {"accepted": 0, "reported_tokens": sum(s["tokens"] for s in sessions),
                        "measured_cash_cost": None, "measured_token_savings": None},
        }))
        return

    raise SystemExit("osprey-test-fixture: unsupported command %s" % command)


if __name__ == "__main__":
    main(sys.argv[1:])
    time.sleep(0)
