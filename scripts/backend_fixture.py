#!/usr/bin/env python3
"""Start/status/stop a real Rust backend with entirely temporary state and fake CLIs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request


def environment(root):
    # Deliberate child-process home directories. The invoking shell is unchanged.
    home = root / "home"
    return {
        "HOME": str(home), "USER": "fixture", "LOGNAME": "fixture", "SHELL": "/bin/sh",
        "PATH": str(root / "bin") + ":/usr/bin:/bin:/usr/sbin:/sbin",
        "TMPDIR": str(root / "tmp") + "/", "LANG": "en_US.UTF-8", "TERM": "xterm-256color",
        "CODEX_HOME": str(home / ".codex"), "CLAUDE_CONFIG_DIR": str(home / ".claude"),
        "XDG_CONFIG_HOME": str(home / ".config"), "XDG_DATA_HOME": str(home / ".local/share"),
        "XDG_CACHE_HOME": str(home / ".cache"), "XDG_RUNTIME_DIR": str(root / "runtime"),
        "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": str(home / ".gitconfig"),
        "GIT_TERMINAL_PROMPT": "0", "NO_PROXY": "127.0.0.1,localhost", "RUST_LOG": "todex_agentd=info",
    }


def read_fixture(root):
    root = Path(root).resolve()
    manifest = json.loads((root / "fixture.json").read_text())
    if manifest.get("kind") != "todex-mobile-isolated-fixture-v1" or manifest.get("root") != str(root):
        raise ValueError("Not an owned TodeX fixture directory")
    if manifest["dataDir"] != str(root / "data"):
        raise ValueError("Fixture data directory is inconsistent")
    return root, manifest


def start(binary):
    binary = Path(binary).resolve()
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise ValueError("Pass an existing executable with --backend-binary")
    root = Path(tempfile.mkdtemp(prefix="todex-mobile-fixture-", dir="/tmp")).resolve()
    for directory in ("home/.codex", "home/.claude", "home/.config", "home/.local/share", "home/.cache", "tmp", "runtime", "bin", "logs", "data", "workspaces/project"):
        (root / directory).mkdir(parents=True, exist_ok=True)
    token = "fixture_" + secrets.token_urlsafe(32)
    token_path = root / "token.txt"
    token_path.write_text(token + "\n")
    token_path.chmod(0o600)
    shutil.copy2(Path(__file__).with_name("fake_provider.py"), root / "bin/fake_provider.py")
    for provider in ("codex", "claude"):
        launcher = root / "bin" / provider
        launcher.write_text("#!/bin/sh\nexec " + shlex.quote(sys.executable) + " " + shlex.quote(str(root / "bin/fake_provider.py")) + " " + provider + ' "$@"\n')
        launcher.chmod(0o700)
    home = root / "home"
    (home / ".gitconfig").write_text('[user]\n name = TodeX Fixture\n email = fixture@example.invalid\n[commit]\n gpgsign = false\n[init]\n defaultBranch = fixture\n')
    workspace = root / "workspaces/project"
    (workspace / "README.md").write_text("# TodeX isolated fixture\n\nUse fixture:permission or fixture:hold in chat.\n")
    (workspace / "sample + 中文.md").write_text("original text\n")
    env = environment(root)
    for args in (["init", "--initial-branch=fixture"], ["add", "."], ["commit", "-m", "Initial isolated fixture"]):
        subprocess.run(["/usr/bin/git", "-C", str(workspace), *args], env=env, check=True, capture_output=True, text=True)
    quote = json.dumps
    config = '\n'.join([
        'host = "127.0.0.1"', 'port = 0', 'pairing_encryption = "none"',
        'workspace_root = ' + quote(str(root / "workspaces")),
        '[agent]', 'default_agent = "codex"',
        'codex_bin = ' + quote(str(root / "bin/codex")),
        'claude_bin = ' + quote(str(root / "bin/claude")),
        'pi_bin = ' + quote(str(root / "bin/unavailable-pi")),
        'grok_bin = ' + quote(str(root / "bin/unavailable-grok")),
        '[security]', 'enable_auth = true', 'enable_tls = false', 'auth_token = ' + quote(token), ''
    ])
    config_path = root / "data/config.toml"
    config_path.write_text(config)
    config_path.chmod(0o600)
    manifest = {
        "kind": "todex-mobile-isolated-fixture-v1", "root": str(root), "backendBinary": str(binary),
        "backendSHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "home": str(home), "dataDir": str(root / "data"), "configPath": str(config_path),
        "workspaceRoot": str(root / "workspaces"), "workspace": str(workspace),
        "tokenPath": str(token_path), "logPath": str(root / "logs/backend.log"),
        "providerWireLog": str(root / "logs/provider-wire.jsonl"),
        "startedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    (root / "fixture.json").write_text(json.dumps(manifest, indent=2) + "\n")
    command = [str(binary), "daemon-run", "--host", "127.0.0.1", "--port", "0", "--data-dir", str(root / "data"), "--workspace-root", str(root / "workspaces")]
    with (root / "logs/backend.log").open("ab") as log:
        child = subprocess.Popen(command, cwd=root, env=env, stdin=subprocess.DEVNULL,
                                 stdout=log, stderr=log, start_new_session=True)
    try:
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if child.poll() is not None:
                raise RuntimeError("Backend exited: " + (root / "logs/backend.log").read_text()[-4000:])
            try:
                daemon = json.loads((root / "data/daemon.json").read_text())
                if daemon["pid"] == child.pid and daemon["port"] > 0:
                    manifest.update(pid=child.pid, port=daemon["port"], url="http://127.0.0.1:" + str(daemon["port"]))
                    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(manifest["url"] + "/health", timeout=1) as response:
                        if response.read() == b"ok":
                            break
            except (OSError, ValueError, KeyError):
                pass
            time.sleep(0.1)
        else:
            raise TimeoutError("Backend startup timed out; inspect " + str(root / "logs/backend.log"))
    except BaseException:
        child.terminate()
        child.wait(timeout=5)
        raise
    manifest["webSocketURL"] = manifest["url"].replace("http:", "ws:") + "/v2/ws"
    (root / "fixture.json").write_text(json.dumps(manifest, indent=2) + "\n")
    connection = {"name": "TodeX isolated fixture", "serverURL": manifest["url"], "token": token, "encryption": "none", "publicKey": ""}
    (root / "simulator-connection.json").write_text(json.dumps(connection, indent=2) + "\n")
    (root / "simulator-connection.json").chmod(0o600)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    starter = sub.add_parser("start")
    starter.add_argument("--backend-binary", type=Path, default=Path(__file__).resolve().parents[2] / "TodeX_backend/target/debug/todex-agentd")
    for name in ("status", "stop"):
        sub.add_parser(name).add_argument("--fixture", required=True)
    args = parser.parse_args()
    if args.action == "start":
        result = start(args.backend_binary)
    else:
        root, result = read_fixture(args.fixture)
        process = subprocess.run([result["backendBinary"], "daemon", args.action, "--data-dir", result["dataDir"]],
                                 cwd=root, env=environment(root), capture_output=True, text=True, check=True, timeout=20)
        result = {"fixture": str(root), "result": process.stdout.strip()}
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
