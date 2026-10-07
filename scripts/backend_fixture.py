#!/usr/bin/env python3
"""Start/status/stop a real Rust backend with entirely temporary state and fake CLIs."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request

# The backend keeps every conversation end-to-end encrypted (history v3) and
# refuses writes until a history recipient exists (HISTORY_KEY_REQUIRED).
# Python has no X-Wing, so the fixture device's recipient is a fixed test
# vector: seed = SHA-256("todex-mobile-fixture-history-recipient-v1"), public
# key = HistoryCrypto.recipientKey(seed:).publicKey (X-Wing ML-KEM-768 +
# X25519, base64url). backend_integration.py registers the public key; the
# Swift live tests read the seed from history-seed.txt to decrypt.
HISTORY_RECIPIENT_SEED = "IBNsVFOslrwDGrrndmQ9Lu3Jbq-LySdj3KOQgUgy8YY"
HISTORY_RECIPIENT_PUBLIC_KEY = (
    "UjAcAVx7_eGO36kjHWY9BylZEzRROSW1Y_eJ-WfMe4RpuAtyHXlTgUIMTenAe9WdkvRMoitVaexeuiiidNStXgEe1SWqpFV7"
    "OvMmtPxCT8AGTQp7fMtc6lhSDKGTz6dIHRkMJewYOXtj2QJuDqWQ5cOZsTFTpny-k4sOsLSSlfwu6cVfcaNSi6FQHyxn47gQ"
    "jQWjASEbKDsNcPfDcbbLyaFRb7OG-RCc1gAvVoptaRywnLyZNqxzLnZEsMcwlycqn_aqeTcMTHSlMvqHOyMxXbw-Fyxs7cbL"
    "5Nk_lLGEGyktpNEtn1JNsAzL7NmdZQcwkOaBH9Ve-CcsodVrXWN23dFGuIE3JkuBfiIUezE5z8CWIsUaVeYQ2NBbiMKCDjYH"
    "Ngg-D_yZ3TkuTCdUvuZbM4ZWUna6JlK4oGGaZXqbF8ikMAOs9yOX8ZW9imjGUTB1a2lU5HR8wZBXjWFNfQtt4kKnWbK3cffB"
    "XxwQAFdcWssjfCZBEUobf1AI_tiuVdq5_QFlempA-NKT75N3EJCsDbwFz6g4gAKlqwhH-Zay0bAvmvAeNtEXE8Aim8qsjYFt"
    "XRRXnQIhzqqp7aW8LOaRWUAToOCe3rzI4ZBVQrx1zNkaI4txOqdWvsKavKN8D0k40OjMoOg0jUm1VVkW4kw_SuUGMKOA59Me"
    "AokzLtOGkDynlSNHFNAbhAG776pl0QFKYzyIwxwP9VyHBQaxLKGsCVmax-ZPyiwUXkYjlzm4limihQYSaKyLXMauNAzOGQWP"
    "kMIR-iNWjuQauZZD02OVKzWjU6XKDYIOpiGBASheqIdjWluuRyXIFmNwzkyRnoSEc1GJbUwyQ5fPRTiBrhA6fxrNzuGWA0CG"
    "xOFrvGiMYHZ7V9ewk5ItSRoAOXJ1HotVciGq3FHK5gPHanGGWeNmBbqB4lgMORR9ZvfFKiIoeFl0kEWDzjdGNpfDB6FzuPDI"
    "ICrB8dYIIMm5-xMXdyC29niigxQ-6XS85UcXaYJ5OrKn7Dq1mQY9xBJBi5ikV-hRTIeqCvI_MPuZukSayiFUbJYj7hNL1CcF"
    "Z2qxoNunxTjKkyE1w1zKuLFRZclxVDHB-yxh7JOs0bgpnxehWnq1yRdTVBGou6h38_Erdfm56fCxhRnF_Qe_RHWF1UIr75EM"
    "lXSV_uyKRwuHKfBHR0NhIXolNRU79jVh4OoXKfiTGyq0tlZ7NFZO-jy9-oqBUBuKOzphmqFo3oTC2Uejmgu7TOMNTFOMGWCP"
    "TbV7h7dcCrkN88nEYBJJFyyQQ_MEeQyXnYmFHLkOc7Zh30vJRGGUZqDBYbxMDSoUlEeAUSqg-mJCE4SN77GGM-ShIfhRj5aG"
    "UaA8WNi1YBCBlllGtxSr-FDEBAW2c8Qc6WALxCObZaJrFHVAYXB3ayKKkeBJ3aq9VnkDRQBP9cWdU7xg03UmV0BbIIRyMDdZ"
    "_0wLX5OBvMeIpRYrfNG20IRs8SQlQfx4Y0THCIwKmTOBZ9ULuqGhd-tBq6V4bYtG6nNWgiwiZwF8b1g3sSs7RomadcETBrJP"
    "0sv6UphQwmqt6GTGC-au0iPi3W-om5q_SOA7zu_QLneol9quTLpPDrJ7joxHS14BZ6cXMD2BAeh7hz6mMRPVNQ"
)


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
    # Enroll the fixed cross-language test device (tests/fixtures/
    # device-auth-v1.json) so live tests exercise the real signature path.
    device_seed = "FRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRUVFRU"
    device_path = root / "device.txt"
    device_path.write_text(device_seed + "\n")
    device_path.chmod(0o600)
    # A second fixed device ("device B") for multi-device history tests:
    # grants, permanent revocation and restore need two enrolled devices.
    device_b_path = root / "device-b.txt"
    device_b_path.write_text("KioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKio\n")
    device_b_path.chmod(0o600)
    history_seed_path = root / "history-seed.txt"
    history_seed_path.write_text(HISTORY_RECIPIENT_SEED + "\n")
    history_seed_path.chmod(0o600)
    devices = {
        "version": 1,
        "devices": {
            "dev_1-HghL4hOwHlBoUq": {
                "deviceId": "dev_1-HghL4hOwHlBoUq",
                "name": "TodeX mobile fixture",
                "publicKey": "1UIH2hlJd9z0atv-wrwudbUtWopCGE_t_cAAJPDj6No",
                "pairedAt": 1700000000000,
            },
            "dev_tgAwbPp2cj_ew5Xl": {
                "deviceId": "dev_tgAwbPp2cj_ew5Xl",
                "name": "TodeX mobile fixture B",
                "publicKey": "GX9rI-FshTLGq8g4-s1ep4m-DHaykgM0A5v6iz02jWE",
                "pairedAt": 1700000000000,
            },
        },
    }
    devices_path = root / "data/devices.json"
    devices_path.write_text(json.dumps(devices, indent=2) + "\n")
    devices_path.chmod(0o600)
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
    # UI tests pick this folder from the "@folder:" reference menu.
    (workspace / "docs").mkdir(exist_ok=True)
    (workspace / "docs/guide.md").write_text("# Fixture guide\n")
    # UI tests resolve "#" skills from the provider project skill root.
    skill = workspace / ".codex/skills/fixture-skill"
    skill.mkdir(parents=True, exist_ok=True)
    (skill / "SKILL.md").write_text(
        "---\nname: fixture-skill\ndescription: Fixture skill used by the TodeX mobile UI tests.\n---\n")
    env = environment(root)
    for args in (["init", "--initial-branch=fixture"], ["add", "."], ["commit", "-m", "Initial isolated fixture"],
                 # The Git worktree menu lists linked trees; UI tests open this one as a workspace.
                 ["worktree", "add", "../wt-fixture", "-b", "wt-fixture"]):
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
        '[security]', 'enable_auth = true', 'enable_tls = false', ''
    ])
    config_path = root / "data/config.toml"
    config_path.write_text(config)
    config_path.chmod(0o600)
    manifest = {
        "kind": "todex-mobile-isolated-fixture-v1", "root": str(root), "backendBinary": str(binary),
        "backendSHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "home": str(home), "dataDir": str(root / "data"), "configPath": str(config_path),
        "workspaceRoot": str(root / "workspaces"), "workspace": str(workspace),
        "deviceSecretPath": str(device_path), "historySeedPath": str(history_seed_path),
        "historyRecipientPublicKey": HISTORY_RECIPIENT_PUBLIC_KEY, "logPath": str(root / "logs/backend.log"),
        "providerWireLog": str(root / "logs/provider-wire.jsonl"),
        "startedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    (root / "fixture.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return launch(root, manifest)


def launch(root, manifest):
    """Runs the daemon on the fixture's data directory and records where it listens."""
    env = environment(root)
    command = [manifest["backendBinary"], "daemon-run", "--host", "127.0.0.1", "--port", "0", "--data-dir", manifest["dataDir"], "--workspace-root", manifest["workspaceRoot"]]
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
    device_seed = (root / "device.txt").read_text().strip()
    connection = {"name": "TodeX isolated fixture", "serverURL": manifest["url"], "deviceSecret": device_seed,
                  "encryption": manifest.get("encryption", "none"), "publicKey": manifest.get("publicKey", "")}
    (root / "simulator-connection.json").write_text(json.dumps(connection, indent=2) + "\n")
    (root / "simulator-connection.json").chmod(0o600)
    return manifest


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def b64url_decode(text):
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def x25519_public(secret):
    """RFC 7748 X25519(secret, 9): the backend stores only the secret."""
    p, a24 = 2**255 - 19, 121665
    k = bytearray(secret)
    k[0] &= 248
    k[31] &= 127
    k[31] |= 64
    k = int.from_bytes(k, "little")
    x2, z2, x3, z3, swap = 1, 0, 9, 1, 0
    for t in reversed(range(255)):
        bit = (k >> t) & 1
        if swap ^ bit:
            x2, x3, z2, z3 = x3, x2, z3, z2
        swap = bit
        a, b, c, d = x2 + z2, x2 - z2, x3 + z3, x3 - z3
        aa, bb, da, cb = a * a, b * b, d * a, c * b
        e = aa - bb
        x3, z3 = (da + cb) ** 2 % p, 9 * (da - cb) ** 2 % p
        x2, z2 = aa * bb % p, e * (aa + a24 * e) % p
    if swap:
        x2, z2 = x3, z3
    return (x2 * pow(z2, p - 2, p) % p).to_bytes(32, "little")


def encrypt(root, protocol):
    """Restarts the fixture with transport encryption and pins its key for clients.

    Run backend_integration.py first: its verifier speaks plaintext WebSocket,
    which the backend refuses once it requires encryption (loopback included).
    """
    root, manifest = read_fixture(root)
    subprocess.run([manifest["backendBinary"], "daemon", "stop", "--data-dir", manifest["dataDir"]],
                   cwd=root, env=environment(root), capture_output=True, text=True, check=True, timeout=20)
    config_path = Path(manifest["configPath"])
    lines = [('pairing_encryption = ' + json.dumps(protocol)) if line.startswith("pairing_encryption") else line
             for line in config_path.read_text().split("\n")]
    config_path.write_text("\n".join(lines))
    # The data directory keeps its pairing keys across restarts.
    keys = json.loads((root / "data/pairing_keys.json").read_text())
    public = keys["mlKemPublic"] if protocol == "ml-kem-768" else b64url(x25519_public(b64url_decode(keys["x25519Secret"])))
    manifest.update(encryption=protocol, publicKey=public)
    return launch(root, manifest)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    starter = sub.add_parser("start")
    starter.add_argument("--backend-binary", type=Path, default=Path(__file__).resolve().parents[2] / "TodeX_backend/target/debug/todex-agentd")
    for name in ("status", "stop"):
        sub.add_parser(name).add_argument("--fixture", required=True)
    encryptor = sub.add_parser("encrypt", help="Restart with pairing_encryption set and pin its public key")
    encryptor.add_argument("--fixture", required=True)
    encryptor.add_argument("--encryption", choices=("x25519", "ml-kem-768"), default="x25519")
    args = parser.parse_args()
    if args.action == "start":
        result = start(args.backend_binary)
    elif args.action == "encrypt":
        result = encrypt(args.fixture, args.encryption)
    else:
        root, result = read_fixture(args.fixture)
        process = subprocess.run([result["backendBinary"], "daemon", args.action, "--data-dir", result["dataDir"]],
                                 cwd=root, env=environment(root), capture_output=True, text=True, check=True, timeout=20)
        result = {"fixture": str(root), "result": process.stdout.strip()}
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
