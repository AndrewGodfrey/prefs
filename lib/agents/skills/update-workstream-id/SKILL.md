---
name: update-workstream-id
description: Associate the current session with its workstream ID when that ID becomes known or changes, on resume or handoff, or when the user asks.
---

# Update workstream ID

Use the ID the user or the project's workflow supplies, verbatim. Never create one or infer it from a branch or
conversation; with none known, change nothing. Several sessions can share one workstream.

Where the ID goes is fixed by the harness: in the session name if you have a `rename_session` tool (a GUI
harness with no status line), otherwise on the status line. Do one, not both, and don't explain which: the user
knows their harness. Don't confirm a success either: the UI shows it.

## Status line

Run `Set-SessionWorkstreamId '<id>'` (on PATH); `''` clears it. It finds the session from the harness's
environment, and prints nothing on success. If it fails, report that and carry on with other work.

## Session name

The name becomes `<id>: <original session name>`, e.g. `12345: Allocation cleanup`. The user authorizes
replacing an existing or user-chosen name this way; pass `force: true` if the tool needs it.

1. Read the current session name from the session tools. If you can't, report that; don't invent a title.
   Never edit the app's database.
2. The original name is the current one, minus a leading `<id>: ` if that is an ID you set earlier in this
   session. Strip nothing else before a colon.
3. Compute the name with [Get-WorkstreamSessionName.ps1](Get-WorkstreamSessionName.ps1), passing the rename
   tool's declared length limit (`rename_session`: 40):

   ```powershell
   & '<skill-directory>/Get-WorkstreamSessionName.ps1' -WorkstreamId '12345' -OriginalSessionName 'Allocation cleanup' -MaxLength 40
   ```

4. If that differs from the current name, rename. Report a refusal as is.
