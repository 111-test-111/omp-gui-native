#!/usr/bin/env python3
"""Deterministic model-free RPC peer. Only touches explicitly supplied fixture paths."""
import base64
import json
import os
import sys
import time

scenario = os.environ.get("OMP_FIXTURE_SCENARIO", "legacy")
log_path = os.environ["OMP_FIXTURE_LOG"]
session_file = os.environ["OMP_FIXTURE_SESSION_FILE"]
pending = False
late = False


def emit(value):
    print(json.dumps(value, separators=(",", ":")), flush=True)


def reply(command, data=None, error=None):
    value = dict(type="response", id=command.get("id"), command=command["type"], success=error is None)
    value["error" if error else "data"] = error if error else data
    emit(value)


emit(dict(type="ready", protocolVersion=1, supportedProtocolVersions=[1, 2], maxFrameBytes=1048576, maxReassembledFrameBytes=67108864))
for line in sys.stdin:
    command = json.loads(line)
    method = command["type"]
    with open(log_path, "a", encoding="utf-8") as log:
        log.write(method + "\n")
    if method == "negotiate_protocol":
        emit(dict(type="response", id="unsolicited", command="fixture_unsolicited", success=True, data={}))
        reply(command, dict(protocolVersion=2))
    elif method == "extension_ui_response":
        if response_path := os.environ.get("OMP_FIXTURE_RESPONSES"):
            with open(response_path, "a", encoding="utf-8") as responses:
                responses.write(json.dumps(command, ensure_ascii=False) + "\n")
    elif method == "get_state":
        state = dict(sessionFile=session_file, isStreaming=False, isCompacting=False,
                     queuedMessageCount=0, isSettled=not pending, hasPendingAsyncWork=pending, todoPhases=[])
        if late:
            emit(dict(type="session_settled"))
            late = False
            pending = False
        reply(command, state)
        if scenario == "crash" and pending:
            sys.exit(3)
    elif method == "get_available_thinking_levels":
        reply(command, dict(levels=["off"]))
    elif method == "get_entries":
        reply(command, dict(entries=[], leafId=None))
    elif method in ("cancel_subagent", "steer_subagent") and scenario == "controls":
        reply(command, error="`subagentId` must be a non-empty string.")
    elif method == "prompt":
        reply(command, dict(agentInvoked=True))
        emit(dict(type="agent_start"))
        emit(dict(type="agent_end", isTerminal=True))
        pending = True
        late = command["message"] == "late-state"
        emit(dict(type="prompt_result", id=command["id"], status="completed", agentInvoked=True, sessionSettled=False))
    elif method == "fixture_settle":
        pending = False
        emit(dict(type="session_settled"))
        reply(command, {})
    elif method == "fixture_chunks":
        data = json.dumps(dict(type="response", id=command["id"], command=method, success=True,
                               data=dict(text="x" * (2 * 1024 * 1024))), separators=(",", ":")).encode()
        chunks = [data[i:i + 262144] for i in range(0, len(data), 262144)]
        for index, chunk in enumerate(chunks):
            emit(dict(type="rpc_chunk", chunkId=command["id"], index=index, count=len(chunks),
                      byteLength=len(data), data=base64.b64encode(chunk).decode()))
    elif method == "fixture_timeout":
        time.sleep(0.15)
        reply(command, {})
    else:
        reply(command, error="Unknown command: " + method)
