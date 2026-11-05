#!/usr/bin/env python3
"""Inspect a verified public client in a sandbox, without login, inference or personal data."""
import argparse
import json
import os
import pathlib
import signal
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("root", type=pathlib.Path, help="An official-runtime-smoke artifact directory")
args = parser.parse_args()
repository = pathlib.Path(__file__).resolve().parent.parent
allowed = (repository / ".build" / "official-runtime-smoke").resolve()
root = args.root.resolve()
assert root.parent == allowed, "Use an isolated verified distribution artifact"
evidence = json.loads((root / "verification.json").read_text())
binary = (root / evidence["executable"]).resolve()
assert binary.is_relative_to(root) and binary.is_file()
work = root / "inspection"
work.mkdir(mode=0o700, exist_ok=True)
config = work / "cli"
config.mkdir(mode=0o700, exist_ok=True)
quote = json.dumps
personal = pathlib.Path.home().resolve()
profile = f'''(version 1)
(allow default)
(deny network*)
(deny appleevent-send)
(deny process-exec (require-not (literal {quote(str(binary))})))
(deny file-read* (require-all (subpath {quote(str(personal))}) (require-not (subpath {quote(str(root))}))))
(deny file-write* (require-not (subpath {quote(str(root))})))
(deny mach-lookup (global-name "com.apple.securityd") (global-name "com.apple.securityd.xpc"))
'''
environment = {key: value for key, value in os.environ.items() if key in {"HOME", "USER", "LOGNAME", "PATH", "LANG", "LC_ALL"}}
environment.update(CLAUDE_CONFIG_DIR=str(config), DISABLE_AUTOUPDATER="1", DISABLE_UPDATES="1", TERM="dumb")

def inspect(*arguments, expected_status=0):
    child = subprocess.Popen(["/usr/bin/sandbox-exec", "-p", profile, str(binary), *arguments], cwd=work,
                             env=environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                             start_new_session=True)
    try:
        try:
            output, _ = child.communicate(timeout=30)
        except (subprocess.TimeoutExpired, KeyboardInterrupt):
            if child.stdin is not None and not child.stdin.closed:
                child.stdin.close()
            child.stdin = None
            if child.poll() is None:
                try:
                    child.send_signal(signal.SIGINT)
                except ProcessLookupError:
                    pass
            try:
                child.communicate(timeout=5)
            except (subprocess.TimeoutExpired, KeyboardInterrupt):
                if child.poll() is None:
                    raise SystemExit(f"Inspection did not finish. Owned process PID {child.pid} is still running; no forceful termination was attempted.") from None
                raise SystemExit("Inspection did not finish draining its output after the owned process exited.") from None
            raise SystemExit("Inspection did not finish within its allowed run. The owned process exited after a normal interrupt.") from None
        assert child.returncode == expected_status, "Official client command failed in the no-network inspection sandbox"
        assert len(output) <= 256 * 1024, "Unexpected inspection output"
        return output.decode("utf-8", errors="strict")
    finally:
        for stream in (child.stdin, child.stdout, child.stderr):
            if stream is not None:
                stream.close()

version = inspect("--version").strip()
assert evidence["version"] in version, "Binary version differs from the verified manifest"
help_text = inspect("--help")
required = ["--restricted", "--session-id", "--settings", "--mcp-config", "--strict-mcp-config", "--tools", "--permission-mode",
            "--allowedTools"]
missing = [flag for flag in required if flag not in help_text]
assert not missing, "Required CLI options not advertised by --help: " + ", ".join(missing)
# The documented prompt-file option can be hidden from help; real session acceptance remains a separate gate.
documented_unadvertised = [flag for flag in ["--append-system-prompt-file"] if flag not in help_text]
status = json.loads(inspect("auth", "status", expected_status=1))
assert status.get("loggedIn") is False, "The isolated inspection must remain signed out"
assert pathlib.Path(status.get("configDirectory", "")).resolve() == config.resolve(), "The client did not use its isolated directory"
result = {"version": evidence["version"], "versionCommandPassed": True, "helpCommandPassed": True,
          "requiredFlags": required, "networkDenied": True, "personalDirectoryReadsDenied": True,
          "documentedFlagsNotAdvertised": documented_unadvertised, "promptFileExecutionVerified": False,
          "writesRestrictedToArtifact": True, "isolatedSignedOutStatusConfirmed": True, "loginOrInferenceRun": False}
(root / "client-inspection.json").write_text(json.dumps(result, indent=2) + "\n")
print("Official client version, advertised CLI options and isolated signed-out state verified in a no-network sandbox; no login or inference run.")
