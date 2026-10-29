#!/usr/bin/env python3
"""Model-free native subagent cursor and host-tool protocol peer."""
import json
import os
from pathlib import Path
import sys
from datetime import datetime, timezone

root = Path(os.environ["OMP_FIXTURE_SESSION_FILE"]).parent
parent = root / "parent.jsonl"
parent.touch()
log = Path(os.environ["OMP_FIXTURE_LOG"])
worker = "head-1"
run = 0
file = None
tool = None
entry_count = 0
accepted_steers = []
hold_next_read = False
held_read = None


def emit(value):
    print(json.dumps(value), flush=True)


def reply(command, data=None, error=None):
    emit(dict(type="response", id=command["id"], command=command["type"], success=error is None,
              **({"error": error} if error else {"data": data or {}})))


def progress():
    emit(dict(type="subagent_progress", payload=dict(index=0, agent="task", agentSource="project",
              sessionFile=str(file), parentToolCallId=tool, assignment="Native assignment",
              progress=dict(id=worker, status="running", resolvedModelIdentity="native/model", tokens=170000,
                            contextTokens=32000, contextWindow=128000))))


def append(text, role="assistant", **metadata):
    global entry_count
    entry_count += 1
    if role == "assistant":
        metadata.setdefault("stopReason", "stop")
        metadata.setdefault("provider", "native")
        metadata.setdefault("model", "model")
        metadata.setdefault("usage", dict(input=2000, output=1000, cacheRead=29000, cacheWrite=0, totalTokens=32000))
    stamp = datetime.fromtimestamp(1_700_000_000 + entry_count * 10, timezone.utc).isoformat().replace("+00:00", "Z")
    with file.open("a") as output:
        output.write(json.dumps(dict(type="message", id=f"m-{entry_count}", parentId=None,
                     timestamp=stamp,
                     message=dict(role=role, content=[dict(type="text", text=text)], **metadata))) + "\n")


def incoming(text):
    global entry_count
    entry_count += 1
    stamp = datetime.fromtimestamp(1_700_000_000 + entry_count * 10, timezone.utc).isoformat().replace("+00:00", "Z")
    with file.open("a") as output:
        output.write(json.dumps(dict(type="custom_message", id=f"m-{entry_count}", parentId=None,
                     timestamp=stamp, customType="irc:incoming", display=True,
                     content=f"<irc>Incoming IRC message from agent `Main`:\n{text}</irc>",
                     details=dict(fromParent=True, message=text, **{"from": "Main"}))) + "\n")


for line in sys.stdin:
    command = json.loads(line)
    with log.open("a") as output:
        output.write(json.dumps(command) + "\n")
    method = command["type"]
    if method == "host_tool_result":
        continue
    if method == "negotiate_protocol":
        reply(command, dict(protocolVersion=2))
    elif method == "get_state":
        reply(command, dict(sessionFile=str(parent), sessionId="parent", isStreaming=False,
                            isCompacting=False, queuedMessageCount=0, hasPendingAsyncWork=bool(run),
                            isSettled=not run, messageCount=0, todoPhases=[]))
    elif method == "get_available_models":
        reply(command, dict(models=[]))
    elif method == "get_available_commands":
        reply(command, dict(commands=[]))
    elif method == "get_subagents":
        reply(command, dict(subagents=[]))
    elif method in ("cancel_subagent", "steer_subagent"):
        if not command.get("subagentId"):
            reply(command, error="`subagentId` must be a non-empty string.")
        elif method == "steer_subagent":
            accepted_steers.append(command["message"])
            reply(command)
        else:
            reply(command, dict(cancelled=True))
    elif method == "set_subagent_subscription":
        reply(command, dict(level=command["level"]))
    elif method == "set_host_tools":
        reply(command, dict(toolNames=[tool["name"] for tool in command["tools"]]))
    elif method == "get_subagent_messages":
        requested = Path(command["sessionFile"])
        body = requested.read_bytes()
        start = command.get("fromByte", 0)
        reset = start > len(body)
        if reset:
            start = 0
        tail = body[start:]
        newline = tail.rfind(b"\n")
        tail = tail[:newline + 1] if newline >= 0 else b""
        entries = [json.loads(row) for row in tail.splitlines()]
        data = dict(sessionFile=str(requested), fromByte=start, nextByte=start + len(tail),
                    reset=reset, entries=entries, messages=[row["message"] for row in entries if "message" in row])
        if hold_next_read:
            held_read = (command, data)
            hold_next_read = False
        else:
            reply(command, data)
    elif method == "fixture_spawn":
        run += 1
        tool = f"parent-call-{run}"
        file = root / f"head-{run}.jsonl"
        file.write_text(json.dumps(dict(type="session", id=f"session-{run}", cwd=str(root / f"worktree-{run}"))) + "\n")
        entry_count = 0
        append("Native assignment", role="user")
        append(f"Final output from run {run}")
        emit(dict(type="subagent_lifecycle", payload=dict(id=worker, index=0, agent="task", agentSource="project",
                  description="Native head", status="started", sessionFile=str(file), parentToolCallId=tool)))
        progress()
        reply(command)
    elif method == "fixture_append":
        append(command["text"])
        progress()
        reply(command)
    elif method == "fixture_wake":
        append("Follow-up on the same worker", role="user")
        append("The same worker completed its follow-up")
        emit(dict(type="subagent_lifecycle", payload=dict(id=worker, index=0, agent="task", agentSource="project",
                  description="Native head", status="started", sessionFile=str(file), parentToolCallId=tool)))
        progress()
        reply(command)
    elif method == "fixture_truncate":
        file.write_text("")
        entry_count = 0
        append("Native assignment", role="user")
        # Snapshot compaction retains the surviving native entry identities.
        entry_count = 4
        append("Steering input", role="user")
        append("Replacement snapshot")
        progress()
        reply(command)
    elif method == "fixture_steer":
        append("Steering input", role="user")
        append("Steering response")
        progress()
        reply(command)
    elif method == "fixture_async_notice":
        append(command["text"], role="custom", customType="async-result", display=True)
        progress()
        reply(command)
    elif method == "fixture_parent_instruction":
        incoming(command["text"])
        append("Inspecting the requested correction", stopReason="toolUse")
        progress()
        reply(command)
    elif method == "fixture_hold_read":
        hold_next_read = True
        append("Continuing the same correction", stopReason="toolUse")
        progress()
        reply(command)
    elif method == "fixture_consume_steer":
        for text in accepted_steers:
            append(text, role="user")
        accepted_steers.clear()
        append("Acknowledged steering response")
        progress()
        reply(command)
    elif method == "fixture_stale_finish":
        emit(dict(type="subagent_lifecycle", payload=dict(id=worker, status="completed", parentToolCallId="parent-call-1",
                  sessionFile=str(root / "head-1.jsonl"))))
        reply(command)
    elif method == "fixture_ownerless_finish":
        emit(dict(type="subagent_lifecycle", payload=dict(id=worker, status="completed")))
        reply(command)
    elif method == "fixture_ownerless_progress":
        emit(dict(type="subagent_progress", payload=dict(progress=dict(id=worker, status="running", tokens=999,
                  resolvedModelIdentity="stale/model"))))
        reply(command)
    elif method == "fixture_finish":
        if command.get("text"):
            append("Final verification", stopReason="toolUse")
            append(command["text"], stopReason=command.get("stopReason", "stop"))
        emit(dict(type="subagent_lifecycle", payload=dict(id=worker, status=command.get("status", "completed"),
                  parentToolCallId=tool, sessionFile=str(file))))
        if held_read:
            # Release the pre-completion snapshot only after the lifecycle event.
            reply(*held_read)
            held_read = None
        reply(command)
    elif method == "fixture_host":
        emit(dict(type="host_tool_call", id=command["callId"], toolCallId="tool-" + command["callId"],
                  toolName="gui_read_selected_context", arguments={}))
        reply(command)
    elif method == "fixture_host_cancel":
        emit(dict(type="host_tool_cancel", id="cancel", targetId=command["callId"]))
        reply(command)
    else:
        reply(command)
