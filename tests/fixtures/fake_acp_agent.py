"""A minimal ACP agent for tests: streams text, reads a file via the client, asks permission, reports a diff."""
import json
import sys

def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()

def read():
    line = sys.stdin.readline()
    return json.loads(line) if line else None

def call(mid, method, params):
    send({"jsonrpc": "2.0", "id": mid, "method": method, "params": params})
    while True:
        msg = read()
        if msg is None:
            sys.exit(0)
        if msg.get("id") == mid and "method" not in msg:
            return msg

def chunk(sid, text):
    send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}}})

cwd = "."
while True:
    msg = read()
    if msg is None:
        break
    method, mid, params = msg.get("method"), msg.get("id"), msg.get("params") or {}
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": 1, "agentInfo": {"name": "fake", "version": "1"}, "authMethods": [], "agentCapabilities": {}}})
    elif method == "session/new":
        cwd = params["cwd"]
        send({"jsonrpc": "2.0", "id": mid, "result": {"sessionId": "s1"}})
    elif method == "session/prompt":
        chunk("s1", "Reading. ")
        r = call(100, "fs/read_text_file", {"sessionId": "s1", "path": cwd + "/indexer/layout.jac", "line": 1, "limit": 1})
        first = (r.get("result") or {}).get("content", "").strip()
        chunk("s1", "First line: " + first[:20] + ". ")
        p = call(101, "session/request_permission", {"sessionId": "s1", "toolCall": {"toolCallId": "t1", "title": "Edit layout.jac", "kind": "edit"},
            "options": [{"optionId": "yes", "name": "Allow", "kind": "allow_once"}, {"optionId": "no", "name": "Reject", "kind": "reject_once"}]})
        chosen = ((p.get("result") or {}).get("outcome") or {}).get("optionId", "cancelled")
        chunk("s1", "Permission: " + chosen + ".")
        send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "s1", "update": {"sessionUpdate": "tool_call", "toolCallId": "t2", "title": "Proposed edit", "kind": "edit", "status": "completed",
            "content": [{"type": "diff", "path": cwd + "/indexer/layout.jac", "oldText": "a\nb\n", "newText": "a\nc\n"}]}}})
        send({"jsonrpc": "2.0", "id": mid, "result": {"stopReason": "end_turn"}})
