#!/usr/bin/env python3
"""Model-free native run-options peer; only writes its isolated request log."""
import json
import os
from pathlib import Path
import sys


session_file = os.environ["OMP_FIXTURE_SESSION_FILE"]
log_file = Path(os.environ["OMP_FIXTURE_LOG"])
model = "initial"
fast_enabled = False
fast_active = os.environ.get("OMP_FIXTURE_FAST_ACTIVE") == "1"
mode = "normal"
held = []
held_state = []
slow_supported = None
slow_scope = None
slow_enabled = False
busy = False
thinking = "off"


def emit(value):
    print(json.dumps(value, separators=(",", ":")), flush=True)


def reply(command, data=None, error=None):
    value = dict(type="response", id=command["id"], command=command["type"], success=error is None)
    if error is not None:
        value["error"] = error
    elif data is not None:
        value["data"] = data
    emit(value)


def native_model(name):
    return dict(provider="fixture", id=name, api="openai-responses", identity={"class": "openai"})


def active_fast():
    return None if fast_active is None else fast_enabled and fast_active


def state():
    value = dict(sessionFile=session_file, sessionId=Path(session_file).stem,
                model=native_model(model), thinkingLevel=thinking, fastModeEnabled=fast_enabled,
                fastModeActive=active_fast(), isStreaming=busy, isCompacting=False,
                queuedMessageCount=0, hasPendingAsyncWork=busy, isSettled=not busy, todoPhases=[])
    if slow_supported is not None:
        value.update(slowModeSupported=slow_supported, slowModeEnabled=slow_enabled)
    if slow_scope is not None:
        value["slowModeScope"] = slow_scope
    return value


def complete(command):
    global fast_enabled, slow_enabled
    if command["type"] == "set_fast_mode":
        fast_enabled = command["enabled"]
        reply(command, dict(enabled=fast_enabled, active=active_fast()))
    elif command["type"] == "set_slow_mode":
        slow_enabled = command["enabled"]
        reply(command, dict(enabled=slow_enabled))
    elif command["type"] == "set_cache_warming":
        reply(command, dict(mode=command["mode"]))
    else:
        reply(command)  # Public auto-retry/abort acknowledgement has no data.


if len(sys.argv) > 1 and sys.argv[1] == "models":
    emit(dict(models=[
        dict(kind="chat", provider="fixture", id="initial", name="Native reasoning model", reasoning=True,
             thinking=["low", "max"], contextWindow=100000),
        dict(kind="chat", provider="fixture", id="nonfast", name="Native regular model", reasoning=False),
    ]))
    sys.exit(0)


for line in sys.stdin:
    command = json.loads(line)
    method = command["type"]
    with log_file.open("a", encoding="utf-8") as log:
        log.write(json.dumps(command) + "\n")
    if method == "negotiate_protocol":
        reply(command, dict(protocolVersion=2))
    elif method == "set_event_filter":
        reply(command, dict(events=None, messageUpdates="delta"))
    elif method == "get_state":
        if mode == "hold-state":
            held_state.append((command, state()))
            mode = "normal"
        else:
            reply(command, state())
    elif method == "get_available_models":
        regular = dict(provider="fixture", id="nonfast", api="openai-completions", identity={"class": "kimi"})
        reply(command, dict(models=[native_model(name) for name in ("initial", "replacement", "alternate")] + [regular]))
    elif method == "set_model":
        model = command["modelId"]
        reply(command, native_model(model))
    elif method == "set_thinking_level":
        thinking = command["level"]
        reply(command, dict(level=thinking))
    elif method == "fixture_fast_active":
        fast_active = command["active"]
        reply(command)
    elif method == "fixture_busy":
        busy = command["busy"]
        reply(command)
    elif method == "get_available_thinking_levels":
        reply(command, dict(levels=["off"]))
    elif method == "get_entries":
        reply(command, dict(entries=[], leafId=None))
    elif method in ("set_fast_mode", "set_auto_retry", "abort_retry", "set_slow_mode", "set_cache_warming"):
        if mode == "hold":
            held.append(command)
        elif mode == "reject":
            reply(command, error="Fixture model rejected the requested run option")
        elif mode == "unsupported":
            reply(command, error="Unknown command: " + method)
        elif mode == "malformed":
            reply(command, dict(active=False))
        else:
            complete(command)
    elif method == "fixture_mode":
        mode = command["mode"]
        reply(command)
    elif method == "fixture_release":
        for pending in held:
            complete(pending)
        held.clear()
        reply(command)
    elif method == "fixture_release_state":
        for pending, snapshot in held_state:
            reply(pending, snapshot)
        held_state.clear()
        reply(command)
    elif method == "fixture_model":
        model = command["model"]
        fast_enabled = False
        fast_active = None
        reply(command)
    elif method == "fixture_resource_state":
        slow_supported = command.get("supported")
        slow_scope = command.get("scope")
        slow_enabled = command.get("enabled", False)
        reply(command)
    elif method == "fixture_warming_event":
        emit(command["event"])
        reply(command)
    elif method == "fixture_retry_start":
        emit(dict(type="auto_retry_start", attempt=2, maxAttempts=4, delayMs=1250,
                  errorMessage="Fixture native rate limit"))
        reply(command)
    elif method == "fixture_retry_end":
        emit(dict(type="auto_retry_end", success=True, attempt=2))
        reply(command)
    elif method == "fixture_session":
        session_file = command["sessionFile"]
        reply(command, state())
    else:
        reply(command, error="Unknown command: " + method)
