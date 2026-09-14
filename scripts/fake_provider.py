#!/usr/bin/env python3
"""Deterministic local CLI fixture. Never executes tools or calls an AI service."""
import json
import os
from pathlib import Path
import sys
import uuid


def main():
    provider, *args = sys.argv[1:]
    root = Path(__file__).resolve().parent.parent
    if "--version" in args:
        print("codex-cli 0.0.0" if provider == "codex" else "0.0.0 (Claude Code fixture)")
        return
    if "generate-json-schema" in args:
        destination = Path(args[args.index("--out") + 1])
        destination.mkdir(parents=True, exist_ok=True)
        (destination / "ClientRequest.json").write_text(json.dumps({"oneOf": []}))
        return
    thread = "fixture-thread-" + uuid.uuid4().hex
    turn = None
    pending = None
    session = str(uuid.uuid4())
    output = ""

    def send(message):
        print(json.dumps(message, ensure_ascii=False), flush=True)

    def codex_complete(status="completed"):
        if status == "completed":
            send({"method": "item/agentMessage/delta", "params": {
                "threadId": thread, "turnId": turn, "itemId": "fixture-message", "delta": output}})
            send({"method": "item/completed", "params": {
                "threadId": thread, "turnId": turn,
                "item": {"id": "fixture-message", "type": "agentMessage", "text": output}}})
        send({"method": "turn/completed", "params": {
            "threadId": thread, "turn": {"id": turn, "status": status}}})

    def claude_complete():
        send({"type": "stream_event", "session_id": session, "event": {
            "type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": output}}})
        send({"type": "assistant", "session_id": session, "message": {
            "role": "assistant", "content": [{"type": "text", "text": output}]}})
        send({"type": "result", "subtype": "success", "session_id": session,
              "is_error": False, "result": output, "usage": {"input_tokens": 5, "output_tokens": 9}})

    for line in sys.stdin:
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        with (root / "logs" / "provider-wire.jsonl").open("a") as log:
            log.write(json.dumps({"provider": provider, "pid": os.getpid(), "wire": message}) + "\n")
        if provider == "codex":
            method = message.get("method")
            request_id = message.get("id")
            params = message.get("params") or {}
            if method == "initialize":
                send({"id": request_id, "result": {"userAgent": "todex-mobile-fixture"}})
            elif method in ("thread/start", "thread/resume", "thread/fork"):
                thread = params.get("threadId", thread) if method == "thread/resume" else "fixture-thread-" + uuid.uuid4().hex
                send({"id": request_id, "result": {"thread": {"id": thread}, "model": "fixture-model"}})
            elif method == "model/list":
                send({"id": request_id, "result": {"data": [{
                    "id": "fixture-model", "model": "fixture-model", "displayName": "Fixture Codex",
                    "isDefault": True, "inputModalities": ["text", "image"], "description": "Local deterministic fixture",
                    "supportedReasoningEfforts": [{"reasoningEffort": "medium", "description": "Fixture"}],
                    "defaultReasoningEffort": "medium"}], "nextCursor": None}})
            elif method == "turn/start":
                turn = "fixture-turn-" + uuid.uuid4().hex
                text = " ".join(item.get("text", "") for item in params.get("input", []) if isinstance(item, dict))
                output = "Fixture Codex: " + text
                send({"id": request_id, "result": {"turn": {"id": turn}}})
                send({"method": "turn/started", "params": {"threadId": thread, "turn": {"id": turn, "status": "inProgress"}}})
                if "fixture:permission" in text:
                    pending = "fixture-permission-" + uuid.uuid4().hex
                    send({"id": pending, "method": "item/commandExecution/requestApproval", "params": {
                        "threadId": thread, "turnId": turn, "itemId": "fixture-tool",
                        "command": "echo fixture-only", "cwd": os.getcwd(),
                        "reason": "Fixture permission roundtrip; no command will execute"}})
                elif "fixture:hold" in text:
                    send({"method": "item/agentMessage/delta", "params": {
                        "threadId": thread, "turnId": turn, "itemId": "fixture-hold", "delta": "Fixture holding until cancel"}})
                else:
                    codex_complete()
            elif method == "turn/interrupt":
                send({"id": request_id, "result": {}})
                codex_complete("interrupted")
            elif method == "thread/compact/start":
                send({"id": request_id, "result": {}})
                send({"method": "item/completed", "params": {"threadId": thread, "item": {"id": "compact", "type": "contextCompaction"}}})
            elif method is None and pending and request_id == pending:
                pending = None
                output += " [permission:" + (message.get("result") or {}).get("decision", "unknown") + "]"
                codex_complete()
            elif method == "skills/list":
                send({"id": request_id, "result": {"data": []}})
            elif request_id is not None:
                send({"id": request_id, "error": {"code": -32601, "message": "Fixture method not implemented: " + str(method)}})
        else:
            kind = message.get("type")
            if kind == "control_request":
                send({"type": "control_response", "response": {
                    "subtype": "success", "request_id": message.get("request_id"), "response": {}}})
            elif kind == "user":
                session = message.get("session_id", session)
                content = message.get("message", {}).get("content", [])
                text = content if isinstance(content, str) else " ".join(item.get("text", "") for item in content)
                output = "Fixture Claude: " + text
                mode = args[args.index("--permission-mode") + 1] if "--permission-mode" in args else "default"
                send({"type": "system", "subtype": "init", "session_id": session, "permissionMode": mode, "model": "fixture-claude"})
                if "fixture:permission" in text:
                    pending = "fixture-claude-permission-" + uuid.uuid4().hex
                    send({"type": "control_request", "request_id": pending, "request": {
                        "subtype": "can_use_tool", "tool_name": "Bash", "input": {"command": "echo fixture-only"}}})
                elif "fixture:hold" not in text:
                    claude_complete()
            elif kind == "control_response" and message.get("response", {}).get("request_id") == pending:
                pending = None
                output += " [permission:" + message["response"].get("response", {}).get("behavior", "unknown") + "]"
                claude_complete()


if __name__ == "__main__":
    main()
