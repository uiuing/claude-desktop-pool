#!/usr/bin/env python3
"""Exercise packaged hook/MCP entry points with private fixtures and no Claude process."""
import json
import os
from pathlib import Path
import plistlib
import select
import signal
import subprocess
import time
import uuid

repository = Path(__file__).resolve().parent.parent
app = repository / "dist" / "Claude Pool.app"
info = plistlib.loads((app / "Contents" / "Info.plist").read_bytes())
binary = app / "Contents" / "MacOS" / info["CFBundleExecutable"]
artifact = repository / ".build" / "packaged-bridge" / str(uuid.uuid4())
artifact.mkdir(parents=True, mode=0o700)
personal = Path.home().resolve()
quote = json.dumps
profile = f'''(version 1)
(allow default)
(deny network*)
(deny appleevent-send)
(deny process-exec (require-not (literal {quote(str(binary))})))
(deny file-read* (require-all (subpath {quote(str(personal))})
  (require-not (subpath {quote(str(app))})) (require-not (subpath {quote(str(artifact))}))))
(deny file-write* (require-not (subpath {quote(str(artifact))})))
(deny mach-lookup (global-name "com.apple.securityd") (global-name "com.apple.securityd.xpc")
  (global-name "com.apple.windowserver.active"))
'''
environment = {key: value for key, value in os.environ.items()
               if key in {"HOME", "USER", "LOGNAME", "PATH", "LANG", "LC_ALL"}}


def write_json(path, value):
    staged = path.with_name(f".{uuid.uuid4()}.tmp")
    descriptor = os.open(staged, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as output:
        json.dump(value, output)
        output.flush()
        os.fsync(output.fileno())
    os.replace(staged, path)


def fixture():
    identity = str(uuid.uuid4())
    directory = artifact / identity
    directory.mkdir(mode=0o700)
    for name in ("events", "results"):
        (directory / name).mkdir(mode=0o700)
    write_json(directory / "run.json", {"session_id": identity})
    return directory, identity


def launch(arguments, directory):
    return subprocess.Popen(["/usr/bin/sandbox-exec", "-p", profile, str(binary), *arguments],
                            cwd=directory, env=environment, stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE)


def finish(process):
    if process.stdin and not process.stdin.closed:
        process.stdin.close()
    try:
        return process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.send_signal(signal.SIGINT)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            raise RuntimeError(f"Packaged helper did not exit; owned PID {process.pid} retained without force-kill")
        raise RuntimeError("Packaged helper required interruption instead of a normal EOF exit")


class Wire:
    def __init__(self, process):
        self.process = process
        self.buffer = bytearray()
        self.messages = []

    def send(self, method, params=None, identity=None):
        message = {"jsonrpc": "2.0", "method": method}
        if params is not None:
            message["params"] = params
        if identity is not None:
            message["id"] = identity
        self.process.stdin.write(json.dumps(message).encode() + b"\n")
        self.process.stdin.flush()

    def receive(self, predicate):
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            for index, message in enumerate(self.messages):
                if predicate(message):
                    return self.messages.pop(index)
            ready, _, _ = select.select([self.process.stdout], [], [], max(0, deadline - time.monotonic()))
            if not ready:
                break
            chunk = os.read(self.process.stdout.fileno(), 65536)
            assert chunk, "Packaged helper ended before responding"
            self.buffer.extend(chunk)
            assert len(self.buffer) <= 262144, "Unexpected helper output size"
            while b"\n" in self.buffer:
                line, _, self.buffer = self.buffer.partition(b"\n")
                self.messages.append(json.loads(line))
        raise RuntimeError("Packaged helper response timed out")


def tool_event(directory, name, seen):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        paths = list((directory / "events").glob("*.json"))
        assert len(paths) <= 32, "Unexpected event count"
        for path in paths:
            event = json.loads(path.read_text())
            if event.get("event") == "toolCall" and event.get("name") == name and event.get("id") not in seen:
                uuid.UUID(event["id"])
                seen.add(event["id"])
                assert path.stat().st_mode & 0o777 == 0o600
                return event
        time.sleep(0.02)
    raise RuntimeError("Packaged helper did not publish the synthetic tool call")


def wait_for_catalog(directory, revision):
    receipt = directory / "tools-listed.json"
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if receipt.exists() and json.loads(receipt.read_text()).get("revision") == revision:
            return
        time.sleep(0.02)
    raise RuntimeError("Packaged helper did not confirm the expected tool catalog")


directory, identity = fixture()
hook = launch(["--bridge-hook", str(directory), "SessionStart"], directory)
try:
    hook.stdin.write(json.dumps({"session_id": identity, "model": "sonnet", "ignored_fixture": "discard"}).encode())
    hook.stdin.close()
    assert finish(hook) == 0, "Packaged hook entry point failed"
    assert hook.stdout.read() == b"", "Observational hook must not change a client decision"
    assert hook.stderr.read() == b"", "Packaged hook unexpectedly wrote diagnostics"
finally:
    if hook.poll() is None:
        finish(hook)
events = list((directory / "events").glob("*.json"))
assert len(events) == 1
assert json.loads(events[0].read_text()) == {"session_id": identity, "model": "sonnet", "event": "SessionStart"}
assert events[0].stat().st_mode & 0o777 == 0o600

directory, _ = fixture()
revision = str(uuid.uuid4())
definition = {"name": "fixture_read", "inputSchema": {"type": "object"}}
write_json(directory / "tools.json", {"revision": revision, "tools": [definition]})
helper = launch(["--mcp-helper", str(directory)], directory)
wire = Wire(helper)
try:
    wire.send("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                            "clientInfo": {"name": "pool-fixture", "version": "1"}}, 1)
    initialized = wire.receive(lambda value: value.get("id") == 1)
    assert initialized["result"]["capabilities"]["tools"]["listChanged"] is True
    wire.send("notifications/initialized")
    wire.send("tools/list", identity=2)
    assert wire.receive(lambda value: value.get("id") == 2)["result"]["tools"] == [definition]
    wait_for_catalog(directory, revision)
    wire.send("tools/call", {"name": "fixture_read", "arguments": {"value": "synthetic"}}, 3)
    seen = set()
    original = tool_event(directory, "fixture_read", seen)
    assert original["input"] == {"value": "synthetic"}

    revision = str(uuid.uuid4())
    definition = {"name": "fixture_next", "inputSchema": {"type": "object"}}
    write_json(directory / "tools.json", {"revision": revision, "tools": [definition]})
    wire.receive(lambda value: value.get("method") == "notifications/tools/list_changed")
    wire.send("tools/list", identity=4)
    assert wire.receive(lambda value: value.get("id") == 4)["result"]["tools"] == [definition]
    wait_for_catalog(directory, revision)
    result = {"content": [{"type": "text", "text": "synthetic result"}], "isError": False}
    write_json(directory / "results" / f"{original['id']}.json", result)
    assert wire.receive(lambda value: value.get("id") == 3)["result"] == result
    wire.send("tools/call", {"name": "fixture_read", "arguments": {}}, 5)
    assert wire.receive(lambda value: value.get("id") == 5)["error"]["code"] == -32602
    wire.send("tools/call", {"name": "fixture_next", "arguments": {}}, 6)
    updated = tool_event(directory, "fixture_next", seen)
    write_json(directory / "results" / f"{updated['id']}.json", result)
    assert wire.receive(lambda value: value.get("id") == 6)["result"] == result
    assert finish(helper) == 0, "Packaged MCP helper did not finish normally"
    assert helper.stderr.read() == b"", "Packaged MCP helper unexpectedly wrote diagnostics"
finally:
    if helper.poll() is None:
        finish(helper)

write_json(artifact / "verification.json", {
    "packagedHook": True, "privateFilteredEvents": True, "packagedMCP": True,
    "dynamicCatalog": True, "pendingResultContinuity": True, "removedToolRejected": True,
    "normalEOFExit": True, "networkDenied": True, "personalDataAccessDenied": True,
    "realClaudeLaunched": False,
})
print("Packaged hook, MCP round trips, catalog changes, private events and normal EOF exit passed in the no-network sandbox.")
