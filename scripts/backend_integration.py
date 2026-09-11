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


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


class HTTP:
    def __init__(self, url, token):
        parsed = urllib.parse.urlsplit(url)
        require(parsed.scheme == "http" and parsed.hostname == "127.0.0.1" and parsed.port, "Fixture must use loopback HTTP")
        self.url, self.token = url, token
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
        self.calls = []

    def request(self, method, path, body=None, query=None, token=True, status=200):
        if query:
            path += "?" + urllib.parse.urlencode(query)
        headers = {"Accept": "application/json"}
        if token:
            headers["Authorization"] = "Bearer " + (self.token if token is True else token)
        if body is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(self.url + path, data=None if body is None else json.dumps(body).encode(), headers=headers, method=method)
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
    def __init__(self, url, token, expected_status=101):
        parsed = urllib.parse.urlsplit(url)
        self.sock = socket.create_connection((parsed.hostname, parsed.port), timeout=10)
        self.buffer = bytearray()
        self.inbox, self.history = [], []
        key = base64.b64encode(os.urandom(16)).decode()
        headers = ["GET /v2/ws HTTP/1.1", f"Host: {parsed.netloc}", "Upgrade: websocket", "Connection: Upgrade",
                   "Sec-WebSocket-Version: 13", "Sec-WebSocket-Key: " + key]
        if token:
            headers.append("Authorization: Bearer " + token)
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
    token = Path(manifest["tokenPath"]).read_text().strip()
    http = HTTP(manifest["url"], token)
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
            require(http.request("GET", "/health", token=False) == "ok", "Health wire"),
            http.request("GET", "/v2/version", token=False),
            require(http.request("GET", "/v2/transport-policy", token=False)["requiredProtocol"] == "none", "Transport policy")
        )[1])
        require(version["data_dir"] == manifest["dataDir"], "Unexpected backend data directory")
        check("HTTP-auth-missing-and-wrong", lambda: [http.request("GET", "/v2/providers", token=t, status=401)["code"] for t in (False, "wrong-fixture-token")])
        check("WS-auth-missing-and-wrong", lambda: [WebSocket(manifest["url"], t, expected_status=401) and "rejected" for t in (None, "wrong-fixture-token")])
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

        ws = WebSocket(manifest["url"], token)
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
            reconnect = WebSocket(manifest["url"], token)
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
