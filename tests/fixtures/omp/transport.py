#!/usr/bin/env python3
"""Forward-only transport faults; no GUI library or native profile access."""
import base64
import json
import os
import sys
import time


projection = os.environ.get("OMP_FIXTURE_PROJECTION", "delta")


def emit(value):
    print(json.dumps(value, separators=(",", ":"), ensure_ascii=False), flush=True)


def response(command, **data):
    return dict(type="response", id=command["id"], command=command["type"], success=True, data=data)


def chunks(value, size=262144):
    data = json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode()
    parts = [data[i:i + size] for i in range(0, len(data), size)]
    return [dict(type="rpc_chunk", chunkId="fixture", index=i, count=len(parts), byteLength=len(data), data=base64.b64encode(part).decode()) for i, part in enumerate(parts)]


for line in sys.stdin:
    command = json.loads(line)
    kind = command["type"]
    if log_path := os.environ.get("OMP_FIXTURE_PROJECTION_LOG"):
        with open(log_path, "a", encoding="utf-8") as log:
            log.write(json.dumps(command, ensure_ascii=False) + "\n")
    if kind == "set_event_filter":
        if command.get("events", "missing") is not None or command.get("messageUpdates") != "delta":
            emit(dict(type="response", id=command["id"], command=kind, success=False,
                      error="Fixture requires an explicit null event filter and delta projection"))
        elif projection == "unsupported":
            emit(dict(type="response", id=command["id"], command=kind, success=False, error="Unknown command: " + kind))
        elif projection == "mismatch":
            emit(dict(response(command, messageUpdates="delta"), command="different-command"))
        elif projection == "legacy":
            emit(response(command, events=None))
        elif projection == "malformed":
            emit(response(command, events=None, messageUpdates=["delta"]))
        elif projection == "future":
            emit(response(command, events=None, messageUpdates="future-projection"))
        elif projection == "full":
            emit(response(command, events=None, messageUpdates="full"))
        else:
            if projection == "late":
                time.sleep(0.08)
            emit(response(command, events=None, messageUpdates="delta"))
    elif kind == "fixture_set_projection":
        projection = command["projection"]
        emit(response(command))
    elif kind == "fixture_unsolicited_projection":
        emit(dict(type="response", id="foreign-projection", command="set_event_filter", success=True,
                  data=dict(events=None, messageUpdates="delta")))
        emit(response(command, alive=True))
    elif kind == "negotiate_protocol":
        emit(response(command, protocolVersion=2))
    elif kind == "get_state":
        emit(response(command, sessionFile=os.path.join(os.getcwd(), "projection-session.jsonl"),
                      isStreaming=False, isCompacting=False, queuedMessageCount=0,
                      isSettled=True, hasPendingAsyncWork=False, todoPhases=[]))
    elif kind == "large":
        emit(dict(type="large-started"))
        for part in chunks(response(command, text="原生🙂" * 1_000_000)):
            emit(part)
    elif kind == "overlap":
        parts = chunks(response(command, text="x" * 500_000))
        emit(parts[0])
        emit(parts[0])
    elif kind == "out-of-order":
        emit(chunks(response(command, text="x" * 500_000))[1])
    elif kind == "mismatch":
        emit(dict(response(command), command="another-command"))
    elif kind == "unknown-events":
        emit(dict(type="future_native_event", futurePayload=dict(state="unknown")))
        emit(dict(type="response", id="foreign-id", command="future-command", success=True, data={}))
        emit(response(command, alive=True))
    elif kind == "exit":
        sys.exit(7)
    elif kind == "truncated":
        emit(chunks(response(command, text="x" * 500_000))[0])
        sys.exit(0)
    elif kind == "wait":
        pass
    else:
        emit(response(command, alive=True))
