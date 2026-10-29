#!/usr/bin/env python3
"""Deterministic side-question peer. No native OMP, accounts or GUI processes."""
import copy
import json
import os
from pathlib import Path
import sys
import time


root = Path(os.environ["OMP_FIXTURE_SESSION_FILE"]).parent
session_file = Path(os.environ["OMP_FIXTURE_SESSION_FILE"])
log = Path(os.environ["OMP_FIXTURE_LOG"])
scenario = os.environ.get("OMP_FIXTURE_SCENARIO", "normal")
record = None
pending = None
pending_cancel = None
counter = 0
main_running = False
main_command = None
goal_state = None
hold_state = False
held_state = None
saved = False


def emit(value):
    print(json.dumps(value, ensure_ascii=False, separators=(",", ":")), flush=True)


def reply(command, data=None, error=None):
    emit(dict(type="response", id=command["id"], command=command["type"],
              success=error is None, **(dict(error=error) if error else dict(data=data or {}))))


def latest():
    return record.get("followUps", [record])[-1]


def finish(status="complete", answer="Native answer"):
    global saved
    turn = latest()
    turn.update(status=status, answer=answer, updatedAt=turn["updatedAt"] + 1)
    emit(dict(type="btw_record", record=record))
    saved = False


for line in sys.stdin:
    command = json.loads(line)
    with log.open("a") as stream:
        stream.write(json.dumps(command) + "\n")
    kind = command["type"]
    if kind == "get_state":
        session_file.touch(exist_ok=True)
        state_value = dict(sessionFile=str(session_file), sessionId="fixture-main", isStreaming=main_running,
                           isCompacting=False, isSettled=not main_running, queuedMessageCount=0,
                           hasPendingAsyncWork=False, goal=copy.deepcopy(goal_state),
                           model=dict(provider="fixture", id="local", contextWindow=100000))
        if hold_state:
            held_state = (copy.deepcopy(command), state_value)
            hold_state = False
            (root / "state-read-held").write_text("held")
        else:
            reply(command, state_value)
    elif kind == "fixture_hold_state":
        hold_state = True
        reply(command)
    elif kind == "fixture_release_state":
        if held_state:
            reply(*held_state)
            held_state = None
        reply(command)
    elif kind == "goal":
        if command["op"] == "create":
            goal = dict(id="cross-goal", objective=command["objective"], status="active", tokensUsed=0,
                        timeUsedSeconds=0, createdAt=1, updatedAt=1)
            goal_state = dict(enabled=True, mode="active", goal=goal)
            emit(dict(type="goal_updated", goal=goal, state=goal_state))
        reply(command, dict(goal=goal_state["goal"] if goal_state else None, state=goal_state))
    elif kind == "negotiate_protocol":
        reply(command, dict(protocolVersion=2))
    elif kind == "get_available_models":
        reply(command, dict(models=[]))
    elif kind == "get_available_commands":
        reply(command, dict(commands=[]))
    elif kind in {"cancel_subagent", "steer_subagent"}:
        reply(command, error="Unknown command: " + kind)
    elif kind == "prompt":
        main_running = True
        main_command = command
        reply(command, dict(agentInvoked=True))
        emit(dict(type="agent_start"))
        emit(dict(type="message_update", messageId="main", assistantMessageEvent=dict(type="text_delta", delta="Main reply ")))
    elif kind == "fixture_main_finish":
        main_running = False
        emit(dict(type="message_end", messageId="main", message=dict(role="assistant", content=[dict(type="text", text="Main reply done")], stopReason="stop")))
        emit(dict(type="agent_end", messages=[], isTerminal=True))
        if main_command:
            emit(dict(type="prompt_result", id=main_command["id"], status="completed", agentInvoked=True, sessionSettled=True))
        emit(dict(type="session_settled"))
        reply(command)
    elif kind == "btw":
        if scenario == "unsupported":
            reply(command, error="Unknown command: btw")
            continue
        if record and latest()["status"] == "running":
            reply(command, error="A /btw question is still running; cancel it first")
            continue
        counter += 1
        turn = dict(question=command["question"].strip(), answer="", status="running", createdAt=counter * 10, updatedAt=counter * 10)
        if "recordId" in command:
            if record is None or command["recordId"] != record["id"]:
                reply(command, error="Unknown /btw topic")
                continue
            record.setdefault("followUps", []).append(turn)
        else:
            record = dict(turn, id="topic-" + str(counter), leafId="main-leaf")
        # The production controller emits its initial checkpoint before admission.
        if command["question"].strip() != "hold-without-start":
            emit(dict(type="btw_record", record=record))
        if command["question"].strip() in {"hold-admission", "hold-without-start"}:
            pending = copy.deepcopy(command)
        elif command["question"].strip() != "hold-without-start":
            reply(command, dict(record=record))
        if command["question"] == "instant":
            finish(answer="Final snapshot corrects the stream")
        elif command["question"].strip() != "hold-without-start":
            latest()["answer"] = "partial "
            emit(dict(type="btw_delta", recordId=record["id"], delta="partial "))
    elif kind == "fixture_admit":
        if pending:
            emit(dict(type="btw_record", record=record))
            reply(pending, dict(record=record))
            pending = None
        reply(command)
    elif kind == "fixture_finish":
        finish(answer=command.get("answer", "Native answer"))
        reply(command)
    elif kind == "fixture_storage_error":
        emit(dict(type="notice", source="btw-history", level="error", message="Could not save /btw history: fixture denied"))
        reply(command)
    elif kind == "fixture_frame_error":
        emit(dict(type="rpc_frame_error", error="fixture oversized result"))
        reply(command)
    elif kind == "btw_cancel":
        match = record is not None and ("recordId" not in command or command["recordId"] == record["id"])
        cancelled = match and latest()["status"] == "running"
        if cancelled and latest()["question"] == "hold-without-start":
            pending_cancel = copy.deepcopy(command)
            continue
        if cancelled:
            finish(status="cancelled", answer=latest()["answer"])
        reply(command, dict(cancelled=cancelled))
    elif kind == "fixture_cancel_confirm":
        if pending_cancel:
            finish(status="cancelled", answer=latest()["answer"])
            reply(pending_cancel, dict(cancelled=True))
            pending_cancel = None
        reply(command)
    elif kind == "get_btw_history":
        raise AssertionError("GUI must not read unbounded BTW history")
    else:
        reply(command)

# stdin EOF is the only successful disposal barrier. SIGTERM would skip this.
(root / "eof-received").write_text("EOF")
if scenario == "slow-drain":
    while not (root / "allow-exit").exists():
        time.sleep(0.01)
if scenario == "drain-error":
    emit(dict(type="notice", source="btw-history", level="error", message="Could not save /btw history: fixture EOF failure"))
else:
    (root / "native-sidecar-saved").write_text(json.dumps(record))
sys.exit(0)
