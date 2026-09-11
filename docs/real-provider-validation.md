# One-request real Codex validation

Passed on 2026-09-11 at 00:07:07.985576 Asia/Taipei (2026-09-10 at 16:07:07.985576 UTC). One prompt was submitted through the real Rust backend and completed successfully. No prompt retry, model fallback, or tool call occurred. This verifies the backend HTTP/WebSocket and persistence path; the request was sent by the integration harness, not the mobile UI.

| Item | Evidence |
| --- | --- |
| Backend executable | `/Users/youtonghy/github/Project/Todex/TodeX_backend/target/debug/todex-agentd` |
| Backend SHA-256 | `2e82c4ca33024574756e7207ec392e3cb1ddae4b78f220b658e03ca69cc01fa7` |
| Backend version | `DEV0.0.0` |
| Real CLI | `/opt/homebrew/bin/codex`, `codex-cli 0.153.4` |
| Model selection | Model omitted from HTTP request; provider confirmed `gpt-6-astra` |
| Permissions | Requested `permissionMode: ask`; provider confirmed `workspace-write`, `on-request`, reviewer `user` |
| Temporary backend | `http://127.0.0.1:53666`, PID `75254`, now stopped |
| Temporary state root | `/private/tmp/todex-mobile-live-p7v1mkp7` |
| Conversation | `cc213563-bc5f-480c-9462-b7b83afd7236` |
| Turn | `turn_dcabef3224b24254a110c82068667ea1` |
| Client request | `live-once-431facf64fcc41cdacca6aadf9150204` |
| Native session | `01a08c12-5b06-7d02-beba-4308ed871534` |

The sole HTTP prompt submission contained exactly:

```json
{
  "text": "Reply with only TODEX_MOBILE_LIVE_OK. Do not call any tools or read/write files.",
  "permissionMode": "ask",
  "clientRequestId": "live-once-431facf64fcc41cdacca6aadf9150204"
}
```

The persisted user `message.created` event has sequence **2**, timestamp `2026-09-10T16:06:45.638016Z`, and event ID `evt_fe86b475a67f455dad1cc6725896057a`. Its content matches the submitted prompt exactly.

The final assistant message is exactly `TODEX_MOBILE_LIVE_OK`. The WebSocket delivered `turn.completed` at sequence **24**, timestamp **`2026-09-10T16:07:07.985576Z`**, event ID `evt_1a870bb2edc545279aaa419a30764183`, with `stopReason: completed`. HTTP replay returned the same completion event. After shutdown, the on-disk event log still contained the exact user message and completion event; its SHA-256 is `754de960739d38cc0d88039a31901879c7268e5451918627dccc1dcd902d1354`.

The 24 replay events include one turn start, one turn completion, one final assistant message, and zero tool, subagent, or permission events. The conversation returned to `idle`; the temporary workspace had no non-Git files before or after the request. Provider usage reported 16,207 input tokens (12,160 cache-read), 11 output tokens, and 16,218 total tokens. **Monetary cost is unknown**; token usage is not a billing receipt.

The backend and CLI used temporary home, data, configuration, and workspace directories. Existing ChatGPT authentication was exposed only through the authorized `auth.json` symlink in the temporary owner-only Codex home. The harness did not read or print credential contents, and the symlink was removed afterward. The temporary backend exited with code 0; its port is closed, and no process retains open files in its temporary directory. The generated local backend token was removed from the stopped fixture configuration. The existing fake fixture at `http://127.0.0.1:49933/health` still returns HTTP 200 and `ok`.

Sanitized local artifacts:

- [Validation report](/private/tmp/todex-mobile-live-p7v1mkp7/report.json)
- [Event transcript](/private/tmp/todex-mobile-live-p7v1mkp7/events.sanitized.json)
- [Backend log](/private/tmp/todex-mobile-live-p7v1mkp7/logs/backend.sanitized.log)
- [Cleanup and fake-fixture health verification](/private/tmp/todex-mobile-live-p7v1mkp7/cleanup-verification.json)

This validation added only this report in the repository. No main app or Core source was changed for this request, and no commit was created. The temporary runner contains a run-once guard and must not be rerun as part of this validation.
