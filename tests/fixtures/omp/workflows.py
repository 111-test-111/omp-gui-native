#!/usr/bin/env python3
"""Model-free public RPC peer for queue, branch, and context regression checks."""
import json
import os
from pathlib import Path
import sys

if "--version" in sys.argv:
    print("workflow-fixture")
    sys.exit(0)

session_file = os.environ["OMP_FIXTURE_SESSION_FILE"]
log_file = os.environ["OMP_FIXTURE_LOG"]
if "--resume" in sys.argv:
    session_file = sys.argv[sys.argv.index("--resume") + 1]
    entries = [row for line in Path(session_file).read_text().splitlines()
               if (row := json.loads(line)).get("type") != "session"]
else:
    Path(session_file).write_text(json.dumps(dict(type="session", id=Path(session_file).stem,
        timestamp="2026-10-16T00:00:00.000Z", cwd=os.getcwd())) + "\n")
    entries = []
queue = []
prompts = []
streaming = False
auto_compaction = True
revision = 0
delayed = []
blocked_reads = []
background_write = False
queue_cancel_mode = None
pending_final_reply = None
held_context_stats = None
held_context_entries = []
hold_context_stats = False
hold_context_entries = False


def emit(value):
    print(json.dumps(value, separators=(",", ":")), flush=True)


def queue_result(command, payload, *, removed=None, error=None):
    result = dict(requestID=payload["requestID"], operation=payload["operation"],
                  success=error is None, protocolVersion=1)
    if removed is not None:
        result["removed"] = removed
    if error:
        result["error"] = error
    emit(dict(type="extension_ui_request", id="queue-" + payload["requestID"],
              method="notify", notifyType="info",
              message="OMP_GUI_QUEUE_RESULT:" + json.dumps(result, separators=(",", ":"))))
    reply(command, dict(agentInvoked=False))


def reply(command, data=None, error=None):
    if "_control" in command:
        queue_result(command["_control"], command["_control_payload"], error=error)
        return
    emit(dict(type="response", id=command["id"], command=command["type"],
              success=error is None, **({"error": error} if error else {"data": data or {}})))

def reply_state(command):
    reply(command, dict(sessionFile=session_file, sessionId=Path(session_file).stem,
                        isStreaming=streaming, isCompacting=False, autoCompactionEnabled=auto_compaction,
                        contextUsage=dict(tokens=15 * len(entries), contextWindow=128000),
                        queuedMessageCount=len(queue), hasPendingAsyncWork=streaming or bool(queue),
                        isSettled=not streaming and not queue, messageCount=len(entries), todoPhases=[]))


def commit_handoff(command):
    document = "# Handoff\n\n" + command.get("customInstructions", "Next steps")
    entries.append(dict(type="compaction", id=f"handoff-{len(entries)}",
                        parentId=entries[-1]["id"] if entries else None, method="handoff",
                        timestamp="2026-10-17T07:28:30.000Z", summary=document, tokensBefore=91036))
    # Manual handoff's public RPC reply omits the document and usually has no path.
    reply(command, {})



def consume(command):
    global revision
    text = "Expanded native template" if command["message"] == "expand-template" else command["message"]
    message = dict(role="user", content=[dict(type="text", text=text)] + command.get("images", []))
    native_id = f"entry-{len(entries)}"
    entries.append(dict(type="message", id=native_id, parentId=entries[-1]["id"] if entries else None,
                        timestamp="2026-10-16T00:00:00.000Z", message=message))
    revision += 1
    emit(dict(type="message_start", message=message))
    emit(dict(type="message_end", message=message))


def assistant(text, native_id, *, tool_call=False, failed=False):
    """Emit the native successful/continuing turn boundary, not agent_end."""
    message = dict(role="assistant", content=[dict(type="text", text=text)],
                   stopReason="toolUse" if tool_call else "error" if failed else "stop")
    if failed:
        message["errorMessage"] = "Fixture follow-up failure"
    if tool_call:
        message["content"].append(dict(type="toolCall", id=native_id + "-read",
                                       name="read", arguments=dict(path="fixture.txt")))
    entries.append(dict(type="message", id=native_id,
                        parentId=entries[-1]["id"] if entries else None,
                        timestamp="2026-10-16T00:00:00.000Z", message=message))
    emit(dict(type="message_start", messageId=native_id, message=message))
    emit(dict(type="message_end", messageId=native_id, message=message))
    results = []
    if tool_call:
        result = dict(role="toolResult", toolCallId=native_id + "-read", toolName="read",
                      content=[dict(type="text", text="Fixture file")], isError=False)
        emit(dict(type="tool_execution_start", toolCallId=native_id + "-read",
                  toolName="read", args=dict(path="fixture.txt")))
        emit(dict(type="tool_execution_end", toolCallId=native_id + "-read",
                  toolName="read", isError=False, result=result))
        results.append(result)
    emit(dict(type="turn_end", message=message, toolResults=results))
    return message


def release(*, failed=False):
    global streaming, background_write, pending_final_reply
    if background_write:
        Path("Acceptance.txt").write_text("native-changed\n")
        background_write = False
    for queued in sorted(queue, key=lambda row: row["type"] != "steer"):
        consume(queued)
    queue.clear()
    last_message = None
    if pending_final_reply:
        last_message = assistant(*pending_final_reply, failed=failed)
        pending_final_reply = None
    streaming = False
    emit(dict(type="agent_end", isTerminal=True, **({"messages": [last_message]} if failed else {})))
    for prompt in prompts:
        emit(dict(type="prompt_result", id=prompt["id"], status="error" if failed else "completed",
                  sessionSettled=True, **({"error": {"message": "Fixture follow-up failure"}} if failed else {})))
    prompts.clear()
    emit(dict(type="session_settled"))


for line in sys.stdin:
    command = json.loads(line)
    method = command["type"]
    control_file = os.environ.get("OMP_FIXTURE_CONTROL_FILE")
    if control_file and Path(control_file).exists():
        control = json.loads(Path(control_file).read_text())
        Path(control_file).unlink()
        queue_cancel_mode = control.get("cancel", queue_cancel_mode)
        if control.get("release"):
            release(failed=bool(control.get("fail")))
    with open(log_file, "a") as log:
        log.write(json.dumps(command) + "\n")
    if method == "prompt" and command.get("message", "").startswith("/omp-gui-queue "):
        payload = json.loads(command["message"].removeprefix("/omp-gui-queue "))
        if payload["operation"] == "hello":
            queue_result(command, payload)
            continue
        if payload["operation"] == "remove_follow_up":
            mode, queue_cancel_mode = queue_cancel_mode, None
            if mode == "reject":
                queue_result(command, payload, error="Fixture rejected native queue removal")
                continue
            target = next((row for row in queue if row["type"] == "follow_up"
                           and row["id"] == payload["submissionID"]), None)
            if target is not None:
                queue.remove(target)
                if mode == "consume-first":
                    consume(target)
            queue_result(command, payload, removed=target is not None and mode != "consume-first")
            continue
        if payload["operation"] == "follow_up":
            original = command
            command = dict(type="follow_up", id=payload["submissionID"],
                           message=payload["message"], images=payload.get("images", []),
                           _control=original, _control_payload=payload)
            method = "follow_up"
        else:
            queue_result(command, payload, error="Unknown queue operation")
            continue
    if method == "negotiate_protocol":
        reply(command, dict(protocolVersion=2))
    elif method == "get_state":
        if any(row["type"] == "handoff" for row in delayed):
            blocked_reads.append(command)
        else:
            reply_state(command)
    elif method == "get_available_models":
        reply(command, dict(models=[]))
    elif method == "get_available_thinking_levels":
        reply(command, dict(levels=["off"]))
    elif method == "get_available_commands":
        reply(command, dict(commands=[dict(name="omp-gui-queue", source="extension",
                                          description="OMP GUI native queue controls")]))
    elif method in ("prompt", "abort_and_prompt", "steer", "follow_up"):
        if command["message"] == "reject":
            reply(command, error="Fixture rejected before admission")
            continue
        if command["message"] == "exit-before-acceptance":
            sys.exit(7)
        if command["message"] == "consume-before-acceptance":
            consume(command)
            reply(command)
            continue
        if command["message"] == "hold-acceptance":
            delayed.append(command)
            continue
        if method == "abort_and_prompt":
            for prompt in prompts:
                emit(dict(type="prompt_result", id=prompt["id"], status="aborted", sessionSettled=False))
            prompts.clear()
        reply(command, dict(agentInvoked=True) if method in ("prompt", "abort_and_prompt") else {})
        if method in ("prompt", "abort_and_prompt"):
            prompts.append(command)
            streaming = True
            emit(dict(type="agent_start"))
            consume(command)
            if command["message"] == "background-file-write":
                background_write = True
                emit(dict(type="tool_execution_start", toolCallId="background-bash", toolName="bash",
                          args=dict(command="sleep 4; printf 'native-changed\\n' > Acceptance.txt")))
                emit(dict(type="tool_execution_end", toolCallId="background-bash", toolName="bash", isError=False,
                          result=dict(content=[], details={"async": dict(state="running", jobId="bg_1", type="bash")})))
            if command["message"] == "waiting-approval":
                emit(dict(type="extension_ui_request", id="fixture-approval", method="confirm", title="Fixture approval", message="Continue?"))
        else:
            if command["message"] in ("final-reply-next", "tool-boundary-steer"):
                is_steer = command["message"] == "tool-boundary-steer"
                assistant("Tool-call commentary" if is_steer else "First independent final response",
                          "tool-boundary" if is_steer else "first-final", tool_call=is_steer)
                emit(dict(type="turn_start", turnIndex=1, timestamp=0))
                consume(command)
                assistant("Follow-up work in progress", "follow-up-progress", tool_call=True)
                pending_final_reply = ("Final response after steering" if is_steer
                                       else "Second independent final response", "second-final")
            elif command["message"] == "queue-next":
                old = prompts.pop()
                emit(dict(type="agent_end", isTerminal=True))
                emit(dict(type="agent_start"))
                consume(command)
                emit(dict(type="prompt_result", id=old["id"], status="error", error=dict(message="Previous run failed"), sessionSettled=False))
            else:
                queue.append(command)
            if os.environ.get("OMP_FIXTURE_AUTO_RELEASE") == "1" and len(queue) == 2:
                release()
    elif method == "fixture_release":
        release()
        reply(command)
    elif method == "fixture_boundary":
        message = dict(role="assistant", content=[dict(type="text", text="Boundary response")],
                       stopReason=command["stopReason"])
        if command.get("stopDetails"):
            message["stopDetails"] = command["stopDetails"]
        if command.get("toolCall"):
            message["content"].append(dict(type="toolCall", id="boundary-tool", name="read", arguments={}))
        emit(dict(type="turn_end", message=message, toolResults=command.get("toolResults", [])))
        for submission_id in command["consume"]:
            queued = next(row for row in queue if row["id"] == submission_id)
            queue.remove(queued)
            consume(queued)
        reply(command)
    elif method == "fixture_background_yield":
        # Native background turns have no command prompt ticket. Exercise their
        # terminal events without session_settled; get_state still owns idle.
        streaming = True
        emit(dict(type="agent_start"))
        streaming = False
        emit(dict(type="agent_end", isTerminal=True))
        reply(command)
    elif method == "fixture_background_resume":
        streaming = True
        emit(dict(type="agent_start"))
        for queued in sorted(queue, key=lambda row: row["type"] != "steer"):
            consume(queued)
        queue.clear()
        streaming = False
        emit(dict(type="agent_end", isTerminal=True))
        reply(command)
    elif method == "fixture_confirm":
        for pending in delayed:
            if pending["type"] == "handoff":
                commit_handoff(pending)
            else:
                reply(pending, dict(summary="Late summary", tokensBefore=100) if pending["type"] == "compact" else {})
            if pending["type"] in ("steer", "follow_up"):
                queue.append(pending)
        delayed.clear()
        for pending in blocked_reads:
            reply_state(pending)
        blocked_reads.clear()
        reply(command)
    elif method == "abort":
        streaming = False
        reply(command)
    elif method == "extension_ui_response":
        pass
    elif method == "get_entries":
        if hold_context_entries:
            held_context_entries.append(command)
        else:
            reply(command, dict(entries=entries, leafId=entries[-1]["id"] if entries else None))
    elif method == "branch":
        index = next((i for i, row in enumerate(entries) if row["id"] == command.get("entryId")), None)
        if index is None:
            reply(command, error="Invalid entry ID for branching")
        elif os.environ.get("OMP_FIXTURE_BRANCH_CANCEL") == "1" or Path(os.environ.get("OMP_FIXTURE_CANCEL_FILE", "/nonexistent-omp-workflow-cancel")).exists():
            reply(command, dict(cancelled=True, text="cancelled"))
        else:
            text = entries[index]["message"]["content"][0]["text"]
            entries = entries[:index]
            source_file = session_file
            session_file = str(Path(session_file).with_name("branched.jsonl"))
            Path(session_file).write_text(json.dumps(dict(type="session", id=Path(session_file).stem,
                timestamp="2026-10-16T00:00:00.000Z", cwd=os.getcwd(), parentSession=source_file)) + "\n")
            revision += 1
            reply(command, dict(cancelled=False, text=text))
    elif method == "get_session_stats":
        if hold_context_stats:
            held_context_stats = command
        else:
            reply(command, dict(userMessages=len(entries), tokens=dict(input=15, output=4, total=19)))
    elif method == "fixture_hold_context_reads":
        hold_context_stats = True
        hold_context_entries = True
        reply(command)
    elif method == "fixture_release_context_stats":
        hold_context_stats = False
        if held_context_stats:
            reply(held_context_stats, dict(userMessages=77, tokens=dict(input=15, output=4, total=19)))
            held_context_stats = None
        reply(command)
    elif method == "fixture_release_context_history":
        hold_context_entries = False
        for pending in held_context_entries:
            reply(pending, dict(entries=entries, leafId=entries[-1]["id"] if entries else None))
        held_context_entries.clear()
        reply(command)
    elif method == "set_auto_compaction":
        auto_compaction = command["enabled"]
        reply(command)
    elif method == "compact":
        if command.get("customInstructions") == "hold-acceptance":
            delayed.append(command)
            continue
        emit(dict(type="manual_compaction_start"))
        result = dict(summary="Fixture summary", tokensBefore=200)
        emit(dict(type="manual_compaction_end", result=result, aborted=False))
        reply(command, result)
    elif method == "handoff":
        if command.get("customInstructions") == "hold-serial-handoff":
            delayed.append(command)
        elif command.get("customInstructions") == "reject-handoff":
            reply(command, error="Fixture handoff generation failed")
        elif command.get("customInstructions") == "skip-handoff":
            emit(dict(type="response", id=command["id"], command="handoff", success=True, data=None))
        else:
            commit_handoff(command)
    elif method == "export_html":
        Path(command["outputPath"]).write_text("<!doctype html><title>Fixture export</title>")
        reply(command, dict(path=command["outputPath"]))
    else:
        reply(command, error="Unknown command: " + method)
