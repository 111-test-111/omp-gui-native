#!/usr/bin/env python3
"""Deterministic public Goal RPC peer; never calls a model or installed OMP."""
import copy
import json
import os
from pathlib import Path
import sys

session_file = os.environ["OMP_FIXTURE_SESSION_FILE"]
log_file = os.environ["OMP_FIXTURE_LOG"]
supported = os.environ.get("OMP_FIXTURE_GOAL_SUPPORT", "1") == "1"
Path(session_file).write_text(json.dumps(dict(type="session", id=Path(session_file).stem,
    timestamp="2026-10-17T00:00:00.000Z", cwd=os.getcwd())) + "\n")
state = None
streaming = False
next_id = 0
held = None
bad_get = False
hold_state = False
held_state = None
goal_auto = "off"
scheduled = False
goal_enabled = True
goal_race = False
hold_goal_read = False
held_goal_read = None


def emit(value):
    print(json.dumps(value, separators=(",", ":")), flush=True)


def reply(command, data=None, error=None):
    emit(dict(type="response", id=command["id"], command=command["type"], success=error is None,
              **({"error": error} if error else {"data": data if data is not None else {}})))


def goal_result():
    return copy.deepcopy(dict(goal=state["goal"] if state else None, state=state))


def event():
    emit(dict(type="goal_updated", **goal_result()))


def finish_work():
    global streaming, scheduled
    streaming = False
    scheduled = False
    emit(dict(type="agent_end", messages=[], isTerminal=True, yielded=True))
    emit(dict(type="session_settled"))


def run_auto_work():
    global streaming, scheduled
    if goal_auto == "scheduled":
        scheduled = True
    elif goal_auto == "finished":
        streaming = True
        emit(dict(type="agent_start"))
        finish_work()


emit(dict(type="ready", protocolVersion=1, supportedProtocolVersions=[1, 2]))
for line in sys.stdin:
    command = json.loads(line)
    with open(log_file, "a") as log:
        log.write(json.dumps(command) + "\n")
    kind = command["type"]
    if kind == "negotiate_protocol":
        reply(command, dict(protocolVersion=2))
    elif kind == "get_state":
        value = dict(sessionFile=session_file, sessionId=Path(session_file).stem, isStreaming=streaming,
                     isCompacting=False, isSettled=not streaming and not scheduled, hasPendingAsyncWork=False,
                     queuedMessageCount=0, todoPhases=[], autoCompactionEnabled=True,
                     fastModeEnabled=False, fastModeActive=False, messageCount=0)
        if supported:
            value["goal"] = copy.deepcopy(state)
        if hold_state:
            held_state = (copy.deepcopy(command), copy.deepcopy(value))
            hold_state = False
        else:
            reply(command, value)
    elif kind == "get_entries":
        reply(command, dict(entries=[], leafId=None))
    elif kind in {"get_available_commands", "get_available_models"}:
        reply(command, {"commands" if kind.endswith("commands") else "models": []})
    elif kind == "fixture_bad_get":
        bad_get = True
        reply(command)
    elif kind == "fixture_goal_auto":
        goal_auto = command["mode"]
        reply(command)
    elif kind == "fixture_goal_enabled":
        goal_enabled = command["enabled"]
        reply(command)
    elif kind == "fixture_replace_goal":
        state["goal"]["id"] = "replaced-goal"
        reply(command)  # Deliberately omit an event; a fresh get must catch it.
    elif kind == "fixture_race_goal":
        goal_race = True
        reply(command)
    elif kind == "fixture_hold_goal_read":
        hold_goal_read = True
        reply(command)
    elif kind == "fixture_release_goal_read":
        if held_goal_read:
            reply(*held_goal_read)
            held_goal_read = None
        reply(command)
    elif kind == "fixture_hold_state":
        hold_state = True
        reply(command)
    elif kind == "fixture_release_state":
        if held_state:
            reply(*held_state)
            held_state = None
        reply(command)
    elif kind == "fixture_release_goal":
        if held:
            reply(*held)
            held = None
        reply(command)
    elif kind == "fixture_work":
        if command["action"] == "start":
            streaming = True
            emit(dict(type="agent_start"))
        else:
            finish_work()
        reply(command)
    elif kind == "fixture_goal_event":
        action = command["action"]
        if state:
            state["goal"]["updatedAt"] += 1
            if action == "budget":
                state["goal"].update(status="budget-limited", tokensUsed=120)
            elif action == "time":
                state["goal"]["timeUsedSeconds"] += 1.25
            elif action == "unknown":
                state["goal"]["status"] = "native-future-status"
                state["mode"] = "native-future-mode"
            elif action == "unknown-mode":
                state["goal"]["status"] = "active"
                state["mode"] = "native-future-mode"
            elif action == "active":
                state["goal"]["status"] = "active"
                state["mode"] = "active"
            elif action == "complete":
                state["goal"]["status"] = "complete"
                state.update(enabled=False, mode="exiting", reason="completed")
            event()
            if action == "complete":
                state = None  # OMP clears completion after the explicit event.
                finish_work()
        reply(command)
    elif kind == "goal" and supported:
        op = command["op"]
        if op in {"create", "resume"} and not goal_enabled:
            reply(command, error="Goal mode is disabled (goal.enabled).")
            continue
        if op != "get" and goal_race:
            goal_race = False
            state["goal"]["id"] = "raced-goal"
        if op == "get":
            value = {"state": None} if bad_get else goal_result()
            if hold_goal_read:
                held_goal_read = (copy.deepcopy(command), value)
                hold_goal_read = False
            else:
                reply(command, value)
            bad_get = False
        elif op == "create":
            if state and state["goal"]["status"] not in {"complete", "dropped"}:
                reply(command, error="A goal is already active.")
                continue
            next_id += 1
            goal = dict(id=f"goal-{next_id}", objective=command["objective"], status="active", tokensUsed=0,
                        timeUsedSeconds=0, createdAt=1, updatedAt=1)
            if "token_budget" in command:
                goal["tokenBudget"] = command["token_budget"]
            state = dict(enabled=True, mode="active", goal=goal)
            event()
            run_auto_work()
            if command["objective"] == "delayed confirmation":
                held = (copy.deepcopy(command), goal_result())
            else:
                reply(command, goal_result())
        elif op == "pause":
            if state:
                state.update(enabled=False, mode="active")
                state["goal"].update(status="paused", updatedAt=state["goal"]["updatedAt"] + 1)
                event()
            reply(command, goal_result())
        elif op == "resume":
            if not state or state["goal"]["status"] != "paused":
                reply(command, error="No paused goal to resume.")
                continue
            state.update(enabled=True, mode="active")
            state["goal"].update(status="active", updatedAt=state["goal"]["updatedAt"] + 1)
            event()
            run_auto_work()
            reply(command, goal_result())
        elif op == "drop":
            if state:
                state["goal"]["status"] = "dropped"
                state["enabled"] = False
                event()
            state = None
            reply(command, goal_result())
        else:
            reply(command, error=f"Unknown goal op: {op}")
    elif kind == "prompt":
        streaming = True
        reply(command, dict(agentInvoked=True))
        emit(dict(type="agent_start"))
        user = dict(role="user", content=[dict(type="text", text=command["message"])])
        emit(dict(type="message_start", message=user))
        emit(dict(type="message_end", message=user))
        finish_work()
        emit(dict(type="prompt_result", id=command["id"], status="completed", agentInvoked=True, sessionSettled=True))
    else:
        reply(command, error=f"Unknown command: {kind}")
