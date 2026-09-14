#!/usr/bin/env python3
"""Exercise a running isolated fixture using real HTTP and RFC 6455 sockets (stdlib only)."""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import socket
import struct
import sys
import time
import traceback
import urllib.error
import urllib.parse
import urllib.request
import uuid

from backend_fixture import read_fixture


def require(condition, message):
    if not condition:
        raise AssertionError(message)


# --- todex.device-auth.v1 -------------------------------------------------
# Pure-Python Ed25519 (RFC 8032 reference algorithm): no third-party
# dependencies are available in the fixture environment.
_Q = 2**255 - 19
_L = 2**252 + 27742317777372353535851937790883648493
_D = (-121665 * pow(121666, _Q - 2, _Q)) % _Q
_I = pow(2, (_Q - 1) // 4, _Q)


def _edwards(p, q):
    x1, y1 = p
    x2, y2 = q
    factor = _D * x1 * x2 * y1 * y2
    x3 = (x1 * y2 + x2 * y1) * pow(1 + factor, _Q - 2, _Q)
    y3 = (y1 * y2 + x1 * x2) * pow(1 - factor, _Q - 2, _Q)
    return x3 % _Q, y3 % _Q


def _scalarmult(point, e):
    if e == 0:
        return (0, 1)
    half = _scalarmult(point, e // 2)
    result = _edwards(half, half)
    if e & 1:
        result = _edwards(result, point)
    return result


_By = 4 * pow(5, _Q - 2, _Q) % _Q
_Bx = (lambda x: (x * _I) % _Q if (x * x - (((_By * _By - 1) * pow(_D * _By * _By + 1, _Q - 2, _Q)) % _Q)) % _Q else x)(
    pow(((_By * _By - 1) * pow(_D * _By * _By + 1, _Q - 2, _Q)) % _Q, (_Q + 3) // 8, _Q))
_Bx = _Bx if _Bx % 2 == 0 else _Q - _Bx
_B = (_Bx, _By)


def _encode_point(point):
    x, y = point
    bits = [(y >> i) & 1 for i in range(255)] + [x & 1]
    return bytes(sum(bits[i * 8 + j] << j for j in range(8)) for i in range(32))


def _hint(message):
    return int.from_bytes(hashlib.sha512(message).digest(), "little")


def _public_key(seed):
    h = hashlib.sha512(seed).digest()
    a = 2 ** 254 + sum(2 ** i * ((h[i // 8] >> (i % 8)) & 1) for i in range(3, 254))
    return _encode_point(_scalarmult(_B, a)), a


def ed25519_sign(seed, message):
    public, a = _public_key(seed)
    r = _hint(hashlib.sha512(seed).digest()[32:] + message) % _L
    encoded_r = _encode_point(_scalarmult(_B, r))
    s_value = (r + _hint(encoded_r + public + message) * a) % _L
    return encoded_r + s_value.to_bytes(32, "little")


def _b64url(data):
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def _b64url_decode(text):
    return base64.urlsafe_b64decode(text + "=" * (-len(text) % 4))


def _canonical_query(query):
    if not query:
        return ""
    pairs = []
    for pair in query.split("&"):
        key, _, value = pair.partition("=")
        decoded_key = urllib.parse.unquote_plus(key)
        if decoded_key in ("device_id", "auth_ts", "auth_nonce", "auth_sig"):
            continue
        pairs.append((urllib.parse.quote(decoded_key, safe="-._~"),
                      urllib.parse.quote(urllib.parse.unquote_plus(value), safe="-._~")))
    return "&".join(k + "=" + v for k, v in sorted(pairs))


class DeviceAuth:
    """Signs requests as the fixture-enrolled device from device.txt."""

    def __init__(self, seed_b64url):
        self.seed = _b64url_decode(seed_b64url)
        self.public, _ = _public_key(self.seed)
        fingerprint = hashlib.sha256(self.public).digest()
        self.device_id = "dev_" + _b64url(fingerprint[:12])

    def headers(self, method, path, raw_query="", body=b""):
        timestamp = str(int(time.time()))
        nonce = _b64url(os.urandom(16))
        payload = "\0".join([
            "todex.device-auth.v1", self.device_id, method, path,
            _canonical_query(raw_query), timestamp, nonce,
            _b64url(hashlib.sha256(body).digest()),
        ]).encode()
        return {
            "x-todex-device-id": self.device_id,
            "x-todex-auth-ts": timestamp,
            "x-todex-auth-nonce": nonce,
            "x-todex-auth-sig": _b64url(ed25519_sign(self.seed, payload)),
        }



class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class HTTP:
    def __init__(self, url, device_seed):
        parsed = urllib.parse.urlsplit(url)
        require(parsed.scheme == "http" and parsed.hostname == "127.0.0.1" and parsed.port, "Fixture must use loopback HTTP")
        self.url, self.device = url, DeviceAuth(device_seed)
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        self.calls = []

    def request(self, method, path, body=None, query=None, signed=True, status=200):
        raw_query = urllib.parse.urlencode(query) if query else ""
        if raw_query:
            path += "?" + raw_query
        headers = {"Accept": "application/json"}
        data = None if body is None else json.dumps(body).encode()
        if signed:
            # `signed` may carry a different seed to exercise rejection of an
            # unenrolled device; True uses the fixture device.
            signer = self.device if signed is True else DeviceAuth(signed)
            headers.update(signer.headers(method, path.split("?", 1)[0], raw_query, data or b""))
        if data is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(self.url + path, data=data, headers=headers, method=method)
        try:
            response = self.opener.open(request, timeout=20)
        except urllib.error.HTTPError as error:
            response = error
        with response:
            raw = response.read()
            actual = response.status
        try:
            result = json.loads(raw) if raw else None
        except ValueError:
            result = raw.decode("utf-8", errors="replace")
        self.calls.append({"method": method, "path": path, "status": actual})
        require(actual == status, f"{method} {path}: expected {status}, got {actual}: {result}")
        return result


class WebSocket:
    def __init__(self, url, device_seed, expected_status=101):
        parsed = urllib.parse.urlsplit(url)
        self.sock = socket.create_connection((parsed.hostname, parsed.port), timeout=10)
        self.buffer = bytearray()
        self.inbox, self.history = [], []
        key = base64.b64encode(os.urandom(16)).decode()
        # The handshake signature rides in the query so it can cover the
        # transport-crypto parameters too (none in this fixture).
        query = ""
        if device_seed is not None:
            device = DeviceAuth(device_seed)
            signed = device.headers("GET", "/v2/ws")
            query = "?" + urllib.parse.urlencode({
                "device_id": device.device_id,
                "auth_ts": signed["x-todex-auth-ts"],
                "auth_nonce": signed["x-todex-auth-nonce"],
                "auth_sig": signed["x-todex-auth-sig"],
            })
        headers = ["GET /v2/ws" + query + " HTTP/1.1", f"Host: {parsed.netloc}", "Upgrade: websocket", "Connection: Upgrade",
                   "Sec-WebSocket-Version: 13", "Sec-WebSocket-Key: " + key]
        self.sock.sendall(("\r\n".join(headers) + "\r\n\r\n").encode())
        while b"\r\n\r\n" not in self.buffer:
            data = self.sock.recv(4096)
            require(bool(data), "WebSocket handshake closed")
            self.buffer.extend(data)
            require(len(self.buffer) < 65536, "Oversized handshake")
        head, rest = bytes(self.buffer).split(b"\r\n\r\n", 1)
        self.buffer = bytearray(rest)
        lines = head.decode().split("\r\n")
        actual = int(lines[0].split()[1])
        if actual != expected_status:
            self.sock.close()
            raise AssertionError(f"WS handshake expected {expected_status}, got {actual}")
        if actual != 101:
            self.sock.close()
            return
        response_headers = dict(line.lower().split(": ", 1) for line in lines[1:] if ": " in line)
        expected_accept = base64.b64encode(hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode().lower()
        require(response_headers.get("sec-websocket-accept") == expected_accept, "Invalid websocket accept")

    def exact(self, size):
        while len(self.buffer) < size:
            data = self.sock.recv(max(4096, size - len(self.buffer)))
            require(bool(data), "Socket closed while waiting for a frame")
            self.buffer.extend(data)
        result = bytes(self.buffer[:size])
        del self.buffer[:size]
        return result

    def frame(self, payload, opcode=1):
        mask = os.urandom(4)
        length = len(payload)
        head = bytes([0x80 | opcode])
        if length < 126:
            head += bytes([0x80 | length])
        elif length < 65536:
            head += bytes([0x80 | 126]) + struct.pack("!H", length)
        else:
            head += bytes([0x80 | 127]) + struct.pack("!Q", length)
        self.sock.sendall(head + mask + bytes(value ^ mask[i % 4] for i, value in enumerate(payload)))

    def receive(self, timeout):
        self.sock.settimeout(timeout)
        fragments = bytearray()
        while True:
            first, second = self.exact(2)
            opcode, length = first & 15, second & 127
            require(not second & 128, "Server frames must be unmasked")
            if length == 126:
                length = struct.unpack("!H", self.exact(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", self.exact(8))[0]
            require(length + len(fragments) <= 8 * 1024 * 1024, "Oversized server message")
            payload = self.exact(length)
            if opcode == 9:
                self.frame(payload, 10)
                continue
            if opcode == 10:
                continue
            require(opcode != 8, "Server sent close: " + repr(payload))
            require(opcode in (0, 1), "Expected text/continuation frame")
            fragments.extend(payload)
            if first & 128:
                message = json.loads(fragments)
                self.history.append(message)
                return message

    def send(self, kind, payload):
        request_id = "integration-" + uuid.uuid4().hex
        self.frame(json.dumps({"id": request_id, "type": kind, "payload": payload}).encode())
        return request_id

    def wait(self, predicate, timeout=15):
        deadline = time.monotonic() + timeout
        while True:
            for index, value in enumerate(self.inbox):
                if predicate(value):
                    return self.inbox.pop(index)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("Expected WS event not received; last events: " + json.dumps(self.history[-4:]))
            value = self.receive(remaining)
            if predicate(value):
                return value
            self.inbox.append(value)

    def command(self, kind, payload, error=None):
        request_id = self.send(kind, payload)
        response = self.wait(lambda frame: frame.get("id") == request_id)
        require(response["type"] == ("server.error" if error else "server.result"), f"{kind}: {response}")
        if error:
            require(response["payload"]["code"] == error, f"{kind}: wrong error {response}")
        return response["payload"]

    def event(self, conversation_id, kind, after=0):
        return self.wait(lambda frame: frame.get("type") == "conversation.event"
                         and frame["payload"].get("conversationId") == conversation_id
                         and frame["payload"].get("type") == kind
                         and frame["payload"].get("sequence", 0) > after)["payload"]

    def close(self):
        try:
            self.frame(struct.pack("!H", 1000), 8)
        except OSError:
            pass
        self.sock.close()


def verify(root, manifest):
    device_seed = Path(manifest["deviceSecretPath"]).read_text().strip()
    http = HTTP(manifest["url"], device_seed)
    report = {"fixture": str(root), "backendSHA256": manifest["backendSHA256"], "url": manifest["url"],
              "startedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "checks": [],
              "scope": "Real Rust backend, real HTTP/WS/PTY/Git; deterministic fake Codex and Claude CLI; no external AI services."}
    sockets = []

    def check(name, operation):
        try:
            detail = operation()
            report["checks"].append({"name": name, "status": "passed", "detail": detail})
            print("PASS " + name, flush=True)
            return detail
        except Exception as error:
            report["checks"].append({"name": name, "status": "failed", "error": str(error)})
            raise

    try:
        # A previous interrupted verifier may have left its own synthetic hold turn active.
        # Only touch the explicitly recorded fixture conversations, never unrelated sessions.
        previous_report = root / "integration-report.json"
        if previous_report.exists() and not json.loads(previous_report.read_text()).get("passed"):
            for key in ("conversationId", "claudeConversationId"):
                if manifest.get(key):
                    path = "/v2/conversations/" + manifest[key]
                    state = http.request("GET", path)
                    if state["status"] in ("running", "waiting_permission"):
                        http.request("POST", path + "/cancel")
                        deadline = time.monotonic() + 12
                        while http.request("GET", path)["status"] in ("running", "waiting_permission"):
                            require(time.monotonic() < deadline, "Previous synthetic hold turn did not cancel")
                            time.sleep(0.1)
        version = check("health-version-policy", lambda: (
            require(http.request("GET", "/health", signed=False) == "ok", "Health wire"),
            http.request("GET", "/v2/version", signed=False),
            require(http.request("GET", "/v2/transport-policy", signed=False)["requiredProtocol"] == "none", "Transport policy")
        )[1])
        require(version["data_dir"] == manifest["dataDir"], "Unexpected backend data directory")
        wrong_seed = _b64url(os.urandom(32))
        check("HTTP-auth-missing-and-wrong", lambda: [http.request("GET", "/v2/providers", signed=t, status=401)["code"] for t in (False, wrong_seed)])
        check("WS-auth-missing-and-wrong", lambda: [WebSocket(manifest["url"], t, expected_status=401) and "rejected" for t in (None, wrong_seed)])
        providers = check("provider-catalog", lambda: http.request("GET", "/v2/providers"))["providers"]
        require(all(any(p["id"] == kind and p["available"] for p in providers) for kind in ("codex", "claude-code")), "Fixture providers unavailable")

        def workspace_setup():
            now = int(time.time() * 1000)
            record = {"id": "fixture", "name": "Isolated Fixture", "path": manifest["workspace"],
                      "sessionId": "cdxs_fixture", "tenantId": "local", "threadId": "", "model": "fixture-model",
                      "approvalPolicy": "on-request", "sandboxMode": "workspace-write", "createdAt": now, "updatedAt": now}
            result = http.request("PUT", "/v2/workspaces", {"workspaces": [record]})["workspaces"]
            item = next(item for item in result if item["path"] == manifest["workspace"])
            require(item["id"].startswith("ws_"), "Canonical workspace id missing")
            trust = http.request("GET", "/v2/workspaces/" + item["id"] + "/trust")
            require(trust["trusted"], "Saving workspace should auto-trust undecided path")
            require(any(w["id"] == item["id"] for w in http.request("GET", "/v2/workspaces")["workspaces"]), "Workspace list persistence")
            return item
        workspace = check("workspace-save-list-trust", workspace_setup)
        manifest["workspaceId"] = workspace["id"]
        def model_discovery():
            models = http.request("GET", "/v2/providers/models", query={"provider": "codex", "workspace": manifest["workspace"]})
            require(any(m["id"] == "fixture-model" for m in models["models"]), "Fake model not discovered")
            return models
        check("trusted-provider-model-discovery", model_discovery)

        def files():
            path = str(Path(manifest["workspace"]) / "sample + 中文.md")
            contents = http.request("GET", "/v2/workspace/file", query={"path": path})["text"]
            require(isinstance(contents, str), "Fixture file must use a backend-supported text extension")
            updated = contents + "integration edit\n"
            require(http.request("PUT", "/v2/workspace/file", {"path": path, "text": updated, "expectedText": contents})["saved"], "File save not confirmed")
            require(http.request("GET", "/v2/workspace/file", query={"path": path})["text"] == updated, "Saved contents mismatch")
            require(http.request("PUT", "/v2/workspace/file", {"path": path, "text": "stale", "expectedText": contents}, status=409)["code"] == "CONFLICT", "Stale-write error")
            require(http.request("GET", "/v2/workspace/file", query={"path": path})["text"] == updated, "Conflict overwrote file")
            http.request("GET", "/v2/workspace/entries", query={"cwd": manifest["workspace"], "query": "sample", "limit": 40})
            http.request("GET", "/v2/workspace/directories", query={"path": manifest["workspaceRoot"]})
            return "Unicode/+ path roundtrip; compare-and-save and 409 preserve current contents"
        check("files-and-conflict", files)

        def git():
            query = {"workspacePath": manifest["workspace"]}
            status = http.request("GET", "/v2/git/status", query=query)
            require(status["branch"], "Missing Git branch")
            http.request("GET", "/v2/git/scan", query=query)
            http.request("GET", "/v2/git/workspace", query=query)
            branch = "fixture-integration-" + uuid.uuid4().hex[:8]
            http.request("POST", "/v2/git/operation", {**query, "operation": {"action": "create-branch", "branchName": branch}})
            http.request("POST", "/v2/git/run", {**query, "action": "commit", "message": "Fixture integration edit", "includeUnstaged": True})
            require(http.request("GET", "/v2/git/status", query=query)["changedFiles"] == 0, "Fixture commit left changes")
            return "Local repository scan/status/workspace, create branch and commit; no push or PR"
        check("git-local-operations", git)

        ws = WebSocket(manifest["url"], device_seed)
        sockets.append(ws)
        check("WS-ping", lambda: require(ws.command("server.ping", {})["pong"], "Missing pong"))

        def conversation_create():
            conversation = http.request("POST", "/v2/conversations", {"workspace": manifest["workspace"], "provider": "codex", "title": "Simulator Codex fixture"})
            conversation_id = conversation["id"]
            require(http.request("GET", "/v2/conversations/" + conversation_id)["status"] == "idle", "Initial status")
            require(any(c["id"] == conversation_id for c in http.request("GET", "/v2/conversations")["conversations"]), "Conversation list persistence")
            http.request("PATCH", "/v2/conversations/" + conversation_id, {"title": "Simulator Codex fixture", "archived": False})
            ws.command("conversation.subscribe", {"conversationId": conversation_id, "afterSequence": 0})
            return conversation_id
        cid = check("conversation-create-list-get-update-subscribe", conversation_create)
        manifest["conversationId"] = cid

        def permission():
            http.request("POST", "/v2/conversations/" + cid + "/prompt", {"text": "fixture:permission", "model": "fixture-model", "clientRequestId": uuid.uuid4().hex})
            event = ws.event(cid, "permission.requested")
            require(http.request("GET", "/v2/conversations/" + cid)["status"] == "waiting_permission", "Permission waiting status")
            http.request("POST", "/v2/conversations/" + cid + "/permissions/" + event["payload"]["permissionId"], {"outcome": "allow_once"})
            resolved = ws.event(cid, "permission.resolved", event["sequence"])
            require(resolved["payload"]["outcome"] == "allow_once", "Permission decision did not persist")
            delta = ws.event(cid, "message.delta", event["sequence"])
            require("permission:accept" in delta["payload"]["delta"], "Fake CLI did not receive approval")
            return ws.event(cid, "turn.completed", event["sequence"])["sequence"]
        last = check("REST-prompt-WS-events-permission-roundtrip", permission)

        def cancel():
            ws.command("conversation.prompt", {"conversationId": cid, "text": "fixture:hold"})
            started = ws.event(cid, "turn.started", last)
            try:
                delta = ws.event(cid, "message.delta", started["sequence"])
                require(delta["payload"]["delta"] == "Fixture holding until cancel", "Provider did not acknowledge held turn")
            finally:
                http.request("POST", "/v2/conversations/" + cid + "/cancel")
            return ws.event(cid, "turn.cancelled", started["sequence"])["sequence"]
        last = check("WS-prompt-REST-cancel", cancel)

        def replay():
            after, events = 0, []
            for _ in range(100):
                page = http.request("GET", "/v2/conversations/" + cid + "/events", query={"afterSequence": after, "limit": 3})
                events.extend(page["events"])
                if not page["hasMore"]:
                    break
                require(page["nextSequence"] > after, "Replay did not advance")
                after = page["nextSequence"]
            require([e["sequence"] for e in events] == list(range(1, len(events) + 1)), "Replay sequence gap or duplicate")
            require(len({e["eventId"] for e in events}) == len(events), "Duplicate event ids")
            reconnect = WebSocket(manifest["url"], device_seed)
            sockets.append(reconnect)
            cursor = max(0, events[-1]["sequence"] - 2)
            result = reconnect.command("conversation.subscribe", {"conversationId": cid, "afterSequence": cursor, "limit": 1})
            actual = [f["payload"]["sequence"] for f in reconnect.inbox if f.get("type") == "conversation.event"]
            require(actual == list(range(cursor + 1, result["nextSequence"] + 1)), "Reconnect did not replay from cursor")
            (root / "conversation-events.json").write_text(json.dumps(events, indent=2) + "\n")
            return {"eventCount": len(events), "reconnectAfter": cursor}
        check("REST-pagination-and-WS-reconnect-replay", replay)

        def claude():
            conversation = ws.command("conversation.create", {"provider": "claude-code", "workspace": manifest["workspace"], "title": "Simulator Claude fixture"})
            ccid = conversation["id"]
            manifest["claudeConversationId"] = ccid
            ws.command("conversation.subscribe", {"conversationId": ccid})
            ws.command("conversation.prompt", {"conversationId": ccid, "text": "fixture:permission"})
            event = ws.event(ccid, "permission.requested")
            ws.command("conversation.permission.respond", {"conversationId": ccid, "permissionId": event["payload"]["permissionId"], "decision": {"outcome": "allow_once"}})
            delta = ws.event(ccid, "message.delta", event["sequence"])
            require("permission:allow" in delta["payload"]["delta"]["text"], "Claude permission response not delivered")
            ws.event(ccid, "turn.completed", event["sequence"])
            return ccid
        check("Claude-stream-json-permission-and-completion", claude)

        def terminal():
            terminal_id = "fixture-terminal-" + uuid.uuid4().hex
            scope = {"terminalId": terminal_id, "tenantId": "local"}
            ws.send("terminal.start", {**scope, "workspaceId": workspace["id"], "cwd": manifest["workspace"], "shell": "/bin/sh", "rows": 24, "cols": 80})
            ws.wait(lambda f: f.get("type") == "terminal.started" and f["payload"].get("terminalId") == terminal_id)
            try:
                marker = "PTY_" + uuid.uuid4().hex
                # Marker does not occur contiguously in the submitted command, distinguishing output from echo.
                ws.send("terminal.input", {**scope, "data": "printf '%s%s\\n' '" + marker[:10] + "' '" + marker[10:] + "'\n"})
                output = ""
                while marker not in output:
                    frame = ws.wait(lambda f: f.get("type") == "terminal.output" and f["payload"].get("terminalId") == terminal_id)
                    output += frame["payload"]["data"]
                ws.send("terminal.resize", {**scope, "rows": 30, "cols": 100})
                ws.wait(lambda f: f.get("type") == "terminal.resized" and f["payload"].get("terminalId") == terminal_id)
                return "Real /bin/sh PTY start/input/output/resize/stop in fixture workspace"
            finally:
                ws.send("terminal.stop", {**scope, "force": True})
                ws.wait(lambda f: f.get("type") in ("terminal.stopped", "terminal.exited") and f["payload"].get("terminalId") == terminal_id)
        check("terminal-PTY", terminal)

        def errors():
            require(http.request("GET", "/v2/conversations/not-a-uuid", status=400)["code"] == "INVALID_REQUEST", "Invalid id error")
            http.request("GET", "/v2/conversations/" + str(uuid.uuid4()), status=404)
            outside = str(root / "home/outside.txt")
            Path(outside).write_text("fixture file outside configured workspace root\n")
            require(http.request("GET", "/v2/workspace/file", query={"path": outside}, status=403)["code"] == "WORKSPACE_PATH_OUTSIDE_ROOT", "Root guard error")
            ws.command("conversation.resume", {"conversationId": cid}, error="UNSUPPORTED")
            http.request("PATCH", "/v2/conversations/" + cid, {"unknownField": True}, status=422)
            return "400 invalid id, 404 missing UUID, 403 workspace boundary, Unsupported native resume, 422 unknown patch field"
        check("structured-errors", errors)
        report["completed"] = True
    except Exception as error:
        report["failure"] = str(error)
        traceback.print_exc()
    finally:
        for ws in sockets:
            ws.close()
        report["httpCalls"] = http.calls
        report["passed"] = report.get("completed", False) and all(item["status"] == "passed" for item in report["checks"])
        report["completedAt"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        (root / "integration-report.json").write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
        (root / "fixture.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", required=True)
    args = parser.parse_args()
    root, manifest = read_fixture(args.fixture)
    report = verify(root, manifest)
    print(json.dumps({"passed": report["passed"], "checks": len(report["checks"]), "report": str(root / "integration-report.json")}, indent=2))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
