"""Agent hub: chat agents behind one event model.

Transports
  acp     Agent Client Protocol (JSON-RPC over stdio): Gemini CLI natively, plus any custom ACP agent.
          The hub answers the agent's fs/read_text_file and fs/write_text_file requests inside the
          project and turns session/request_permission into an approval card in the UI.
  codex   `codex exec --json` (resumes the thread each turn). codex-acp is the ACP route, but its
          bundled Codex core rejects current ChatGPT models, so the CLI stream is used for now.
  claude  `claude -p --output-format stream-json` (resumes the session each turn).
  jac     the built-in byLLM agent.

Each turn is a run with an append-only event list; the UI long-polls it (the desktop host buffers
streamed responses, so SSE is not used).
"""
import os;
import re;
import json;
import time;
import difflib;
import shutil;
import secrets;
import threading;
import subprocess;

import from settings.session { authorized }
import from settings.credentials { read_config }
import from settings.chatgpt { codex_path, tool_env, TOOLS_DIR }
import from indexer.api { current_project, safe_path, reindex }
import from agent.agent { _describe, _snapshot_mtimes, run_jac_agent, _ensure_model, _touched, _edited }
import from architect.discover { describe_architecture }

glob AGENT_NAMES: dict[str, str] = {"codex": "Codex (ChatGPT)", "claude": "Claude Code", "gemini": "Gemini CLI", "jac": "Jac agent (byLLM)", "custom": "Custom ACP agent"};

obj AgentEvent {
    has seq: int;
    has kind: str;
    has text: str = "";
    has tool_id: str = "";
    has title: str = "";
    has status: str = "";
    has tool_kind: str = "";
    has paths: list[str] = [];
    has diff: str = "";
    has options: list[dict[str, str]] = [];
}

obj EventBatch {
    has ok: bool = True;
    has error: str = "";
    has events: list[AgentEvent] = [];
    has done: bool = False;
    has touched: list[str] = [];
    has edited: list[str] = [];
    has reindexed: bool = False;
}

obj RunStart {
    has ok: bool = True;
    has error: str = "";
    has run_id: str = "";
    has backend: str = "";
}

obj AgentStatus {
    has id: str;
    has name: str;
    has transport: str;
    has installed: bool = False;
    has ready: bool = False;
    has version: str = "";
    has detail: str = "";
    has model: str = "";
}

obj Run {
    has id: str;
    has backend: str;
    has events: list[AgentEvent] = [];
    has done: bool = False;
    has cond: any = None;
    has touched: list[str] = [];
    has edited: list[str] = [];
    has reindexed: bool = False;
    has permissions: dict[str, any] = {};
    has cancel: bool = False;
    has proc: any = None;

    def emit(kind: str, **fields: any) -> AgentEvent {
        with self.cond {
            ev = AgentEvent(seq=len(self.events), kind=kind, **fields);
            self.events.append(ev);
            self.cond.notify_all();
            return ev;
        }
    }

    def finish() -> None {
        with self.cond {
            self.done = True;
            self.cond.notify_all();
        }
    }
}

glob _runs: dict[str, Run] = {};
glob _resume: dict[str, str] = {};      # backend@project -> codex thread / claude session id
glob _acp: dict[str, any] = {};         # backend@project -> AcpClient

def _rel(path: str) -> str {
    p = current_project();
    if p is None or not path {
        return path;
    }
    try {
        r = os.path.relpath(os.path.realpath(path), os.path.realpath(p.root_dir));
    } except ValueError {
        return path;
    }
    return path if r.startswith("..") else r.replace(os.sep, "/");
}

def _touch(run: Run, path: str, edited: bool = False) -> None {
    r = _rel(path);
    if r and r not in run.touched {
        run.touched.append(r);
    }
    if edited and r and r not in run.edited {
        run.edited.append(r);
    }
}

def _diff(path: str, old: str, new: str) -> str {
    lines = list(difflib.unified_diff(old.splitlines(), new.splitlines(), fromfile=path, tofile=path, lineterm="", n=2));
    return "\n".join(lines[:80]);
}

def tool_bin(name: str) -> str {
    local = os.path.join(TOOLS_DIR, "node_modules", ".bin", name);
    if os.path.exists(local) {
        return local;
    }
    return shutil.which(name, path=tool_env()["PATH"]) or "";
}

def context_preamble(focus_id: str, context: str, context_file: str, allow_edits: bool) -> str {
    p = current_project();
    if p is None {
        return "";
    }
    focus = p.boxes.get(focus_id) or p.boxes[p.root_id];
    parts = [
        "[jac smith context] The developer works in an architecture-first IDE.",
        "Project architecture:\n" + describe_architecture(p)[:4000],
        "Focused on:\n" + _describe(focus)[:2500],
        "Edits are " + ("ALLOWED." if allow_edits else "LOCKED: do not modify files; propose changes instead.")
    ];
    if context {
        parts.append("Selected code" + (" (" + context_file + ")" if context_file else "") + ":\n```\n" + context[:12000] + "\n```");
    }
    if any([p.root_dir.endswith(".jac") for _ in [0]]) or os.path.exists(os.path.join(p.root_dir, "jac.toml")) {
        parts.append("For Jac code run `jac guide jac-essentials` and the task guide first, and `jac check` after changes.");
    }
    return "\n\n".join(parts);
}

# ------------------------------------------------------------------ ACP

obj AcpClient {
    has backend: str;
    has cmd: list[str];
    has cwd: str;
    has proc: any = None;
    has next_id: int = 1;
    has pending: dict[int, any] = {};
    has lock: any = None;
    has session_id: str = "";
    has modes: list[str] = [];
    has run: any = None;
    has allow_edits: bool = False;
    has alive: bool = False;
    has error: str = "";

    def start() -> None {
        self.lock = threading.Lock();
        env = tool_env();
        if self.backend == "gemini" {
            # opening the project in jac smith is the trust decision; without it Gemini waits silently
            env["GEMINI_CLI_TRUST_WORKSPACE"] = "true";
        }
        self.proc = subprocess.Popen(
            self.cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, bufsize=1, cwd=self.cwd, env=env
        );
        self.alive = True;
        threading.Thread(target=self._reader, daemon=True).start();
        threading.Thread(target=self._stderr_reader, daemon=True).start();
    }

    """Agents report retries and API failures on stderr; surface them so a stalled turn explains itself."""
    def _stderr_reader() -> None {
        last = 0.0;
        for line in self.proc.stderr {
            text = re.sub(r"\x1b\[[0-9;]*m", "", line).strip();
            if not text or text.startswith("at ") {
                continue;
            }
            m = re.search(r"(status (\d{3})|\"code\": (\d{3})|Retrying[^.]*|high demand[^.]*|quota[^.]*|fetch failed[^.]*|not running in a trusted directory|no longer available[^.]*)", text, re.I);
            run = self.run;
            if m and run is not None and not run.done and time.time() - last > 4 {
                last = time.time();
                run.emit("info", text=AGENT_NAMES.get(self.backend, self.backend) + ": " + text[:180]);
            }
        }
    }

    def _send(msg: dict[str, any]) -> None {
        with self.lock {
            self.proc.stdin.write(json.dumps(msg) + "\n");
            self.proc.stdin.flush();
        }
    }

    def request(method: str, params: dict[str, any], timeout: float = 600.0) -> dict[str, any] {
        rid = self.next_id;
        self.next_id += 1;
        box: dict[str, any] = {"event": threading.Event(), "reply": None};
        self.pending[rid] = box;
        self._send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params});
        box["event"].wait(timeout);
        self.pending.pop(rid, None);
        reply: any = box["reply"];
        if reply is None {
            raise Exception(method + " timed out" if self.alive else self.backend + " exited");
        }
        if "error" in reply {
            err: any = reply["error"];
            raise Exception(str(err.get("data", {}).get("message", "") or err.get("message", "error"))[:400]);
        }
        return reply.get("result") or {};
    }

    def respond(rid: any, result: any = None, error: str = "") -> None {
        if error {
            self._send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32000, "message": error}});
        } else {
            self._send({"jsonrpc": "2.0", "id": rid, "result": result});
        }
    }

    def _reader() -> None {
        for line in self.proc.stdout {
            try {
                msg = json.loads(line);
            } except ValueError {
                continue;
            }
            if "id" in msg and ("result" in msg or "error" in msg) and "method" not in msg {
                box = self.pending.get(msg["id"]);
                if box is not None {
                    box["reply"] = msg;
                    box["event"].set();
                }
            } elif msg.get("method") == "session/update" {
                self._on_update(msg["params"].get("update", {}));
            } elif "method" in msg and "id" in msg {
                threading.Thread(target=self._on_request, args=(msg,), daemon=True).start();
            }
        }
        self.alive = False;
        for box in list(self.pending.values()) {
            box["event"].set();
        }
    }

    def _on_update(u: dict[str, any]) -> None {
        run = self.run;
        if run is None {
            return;
        }
        k = u.get("sessionUpdate", "");
        if k == "agent_message_chunk" and (u.get("content") or {}).get("type") == "text" {
            run.emit("text", text=u["content"].get("text", ""));
        } elif k == "agent_thought_chunk" and (u.get("content") or {}).get("type") == "text" {
            run.emit("thought", text=u["content"].get("text", ""));
        } elif k in ["tool_call", "tool_call_update"] {
            paths = [str(l.get("path", "")) for l in (u.get("locations") or []) if l.get("path")];
            diff = "";
            for c in u.get("content") or [] {
                if c.get("type") == "diff" {
                    diff = _diff(_rel(str(c.get("path", ""))), str(c.get("oldText") or ""), str(c.get("newText") or ""));
                    paths.append(str(c.get("path", "")));
                }
            }
            for pth in paths {
                _touch(run, pth);
            }
            run.emit(
                "tool", tool_id=str(u.get("toolCallId", "")), title=str(u.get("title") or ""),
                status=str(u.get("status") or ""), tool_kind=str(u.get("kind") or ""),
                paths=[_rel(x) for x in paths], diff=diff
            );
        } elif k == "plan" {
            entries = u.get("entries") or [];
            run.emit("plan", text="\n".join([("✓ " if e.get("status") == "completed" else ("→ " if e.get("status") == "in_progress" else "○ ")) + str(e.get("content", "")) for e in entries]));
        }
    }

    def _on_request(msg: dict[str, any]) -> None {
        method = msg["method"];
        params = msg.get("params") or {};
        run = self.run;
        if method == "fs/read_text_file" {
            full = safe_path(_rel(str(params.get("path", ""))));
            if not full or not os.path.isfile(full) {
                self.respond(msg["id"], error="outside the project or missing: " + str(params.get("path", "")));
                return;
            }
            with open(full, encoding="utf-8", errors="replace") as fh {
                lines = fh.read().splitlines(keepends=True);
            }
            start = max(int(params.get("line") or 1) - 1, 0);
            limit = params.get("limit");
            chunk = lines[start:start + int(limit)] if limit else lines[start:];
            if run is not None {
                _touch(run, full);
            }
            self.respond(msg["id"], {"content": "".join(chunk)});
        } elif method == "fs/write_text_file" {
            full = safe_path(_rel(str(params.get("path", ""))));
            if not self.allow_edits {
                self.respond(msg["id"], error="Edits are locked in jac smith. Ask the developer to enable edits.");
                return;
            }
            if not full {
                self.respond(msg["id"], error="Refusing to write outside the project");
                return;
            }
            old = "";
            if os.path.isfile(full) {
                with open(full, encoding="utf-8", errors="replace") as fh {
                    old = fh.read();
                }
            }
            os.makedirs(os.path.dirname(full), exist_ok=True);
            with open(full, "w", encoding="utf-8") as fh {
                fh.write(str(params.get("content", "")));
            }
            if run is not None {
                _touch(run, full, True);
                run.emit("tool", tool_id="write:" + _rel(full), title="Wrote " + _rel(full), status="completed", tool_kind="edit", paths=[_rel(full)], diff=_diff(_rel(full), old, str(params.get("content", ""))));
            }
            self.respond(msg["id"], None);
        } elif method == "session/request_permission" {
            options = params.get("options") or [];
            tool = params.get("toolCall") or {};
            kind = str(tool.get("kind") or "");
            if not self.allow_edits and kind in ["edit", "delete", "move", "execute"] {
                reject = [o for o in options if str(o.get("kind", "")).startswith("reject")];
                if reject {
                    if run is not None {
                        run.emit("info", text="Declined '" + str(tool.get("title") or kind) + "' - edits are locked.");
                    }
                    self.respond(msg["id"], {"outcome": {"outcome": "selected", "optionId": reject[0]["optionId"]}});
                    return;
                }
            }
            if run is None {
                self.respond(msg["id"], {"outcome": {"outcome": "cancelled"}});
                return;
            }
            pid = secrets.token_hex(4);
            waiter: dict[str, any] = {"event": threading.Event(), "choice": ""};
            run.permissions[pid] = waiter;
            run.emit(
                "permission", tool_id=pid, title=str(tool.get("title") or "Permission requested"), tool_kind=kind,
                options=[{"id": str(o.get("optionId")), "name": str(o.get("name")), "kind": str(o.get("kind"))} for o in options]
            );
            waiter["event"].wait(900);
            choice = waiter["choice"];
            if choice {
                run.emit("permission_done", tool_id=pid, text=choice);
                self.respond(msg["id"], {"outcome": {"outcome": "selected", "optionId": choice}});
            } else {
                self.respond(msg["id"], {"outcome": {"outcome": "cancelled"}});
            }
        } else {
            self._send({"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32601, "message": "jac smith does not support " + method}});
        }
    }

    def ensure_session() -> None {
        if self.session_id {
            return;
        }
        init = self.request("initialize", {
            "protocolVersion": 1,
            "clientCapabilities": {"fs": {"readTextFile": True, "writeTextFile": True}, "terminal": False},
            "clientInfo": {"name": "jac-smith", "title": "jac smith", "version": "0.1.0"}
        }, 60.0);
        methods = [str(a.get("id")) for a in init.get("authMethods") or []];
        if self.backend == "gemini" and "gemini-api-key" in methods and os.environ.get("GEMINI_API_KEY") {
            self.request("authenticate", {"methodId": "gemini-api-key"}, 60.0);
        }
        try {
            sess = self.request("session/new", {"cwd": self.cwd, "mcpServers": []}, 120.0);
        } except Exception as e {
            if "auth" in str(e).lower() and "oauth-personal" in methods {
                self.request("authenticate", {"methodId": "oauth-personal"}, 600.0);
                sess = self.request("session/new", {"cwd": self.cwd, "mcpServers": []}, 120.0);
            } else {
                raise e;
            }
        }
        self.session_id = str(sess.get("sessionId", ""));
        self.modes = [str(m.get("id")) for m in ((sess.get("modes") or {}).get("availableModes") or [])];
    }

    def prompt(run: Run, text: str, allow_edits: bool) -> str {
        self.run = run;
        self.allow_edits = allow_edits;
        self.ensure_session();
        wanted = "auto" if allow_edits else "read-only";
        if wanted in self.modes {
            try {
                self.request("session/set_mode", {"sessionId": self.session_id, "modeId": wanted}, 30.0);
            } except Exception {}
        }
        res = self.request("session/prompt", {"sessionId": self.session_id, "prompt": [{"type": "text", "text": text}]}, 1800.0);
        return str(res.get("stopReason", "end_turn"));
    }

    def cancel() -> None {
        if self.session_id and self.alive {
            self._send({"jsonrpc": "2.0", "method": "session/cancel", "params": {"sessionId": self.session_id}});
        }
    }

    def close() -> None {
        try { self.proc.kill(); } except Exception {}
        self.alive = False;
    }
}

def acp_command(backend: str) -> list[str] {
    cfg = read_config();
    if backend == "gemini" {
        g = tool_bin("gemini");
        if not g {
            return [];
        }
        cmd = [g, "--acp"];
        # the CLI default model is frequently overloaded (503); flash answers reliably
        model = str(cfg.get("gemini_model", "") or "") or "gemini-2.5-flash";
        cmd.extend(["-m", model]);
        return cmd;
    }
    custom = str(cfg.get("custom_acp_command", "") or "").strip();
    return custom.split() if custom else [];
}

def run_acp(run: Run, backend: str, proj_root: str, text: str, allow_edits: bool, cmd_override: list[str] | None = None) -> None {
    key = backend + "@" + proj_root;
    client = _acp.get(key);
    if client is None or not client.alive {
        cmd = cmd_override or acp_command(backend);
        if not cmd {
            raise Exception(AGENT_NAMES.get(backend, backend) + " is not installed - see Settings › Agents");
        }
        client = AcpClient(backend=backend, cmd=cmd, cwd=proj_root);
        client.start();
        _acp[key] = client;
    }
    run.proc = client;
    stop = client.prompt(run, text, allow_edits);
    if stop not in ["end_turn", ""] {
        run.emit("info", text="stopped: " + stop);
    }
}

# ------------------------------------------------------------------ Codex CLI stream

def run_codex(run: Run, proj_root: str, text: str, allow_edits: bool) -> None {
    cx = codex_path();
    if not cx {
        raise Exception("Codex CLI not installed - see Settings › Agents");
    }
    key = "codex@" + proj_root;
    model = str(read_config().get("codex_model", "") or "");
    cmd = [cx, "exec", "--json", "--skip-git-repo-check", "--color", "never", "-C", proj_root, "-s", "workspace-write" if allow_edits else "read-only"];
    if model {
        cmd.extend(["-m", model]);
    }
    if key in _resume {
        cmd.extend(["resume", _resume[key], "-"]);
    } else {
        cmd.append("-");
    }
    proc: any = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, cwd=proj_root, env=tool_env());
    run.proc = proc;
    proc.stdin.write(text);
    proc.stdin.close();
    for line in proc.stdout {
        try {
            e = json.loads(line);
        } except ValueError {
            continue;
        }
        t = e.get("type", "");
        it = e.get("item") or {};
        it_type = it.get("type", "");
        if t == "thread.started" {
            _resume[key] = str(e.get("thread_id", ""));
        } elif it_type == "agent_message" and t == "item.completed" {
            run.emit("text", text=str(it.get("text", "")));
        } elif it_type == "reasoning" and t == "item.completed" {
            run.emit("thought", text=str(it.get("text", "")));
        } elif it_type == "command_execution" {
            out = str(it.get("aggregated_output") or "");
            run.emit("tool", tool_id=str(it.get("id", "")), title=str(it.get("command", "")), status="completed" if t == "item.completed" and it.get("exit_code", 0) == 0 else ("failed" if t == "item.completed" else "in_progress"), tool_kind="execute", diff=out[-1200:] if t == "item.completed" else "");
        } elif it_type == "file_change" {
            paths = [str(c.get("path", "")) for c in it.get("changes") or []];
            for pth in paths {
                _touch(run, pth, True);
            }
            run.emit("tool", tool_id=str(it.get("id", "")), title="Changed " + ", ".join([_rel(x) for x in paths]), status=str(it.get("status") or "completed"), tool_kind="edit", paths=[_rel(x) for x in paths]);
        } elif it_type == "todo_list" {
            run.emit("plan", text="\n".join([("✓ " if i.get("completed") else "○ ") + str(i.get("text", "")) for i in it.get("items") or []]));
        } elif t == "error" or it_type == "error" {
            run.emit("error", text=str(e.get("message") or it.get("message") or "error"));
        } elif t == "turn.completed" {
            u = e.get("usage") or {};
            run.emit("info", text=str(u.get("input_tokens", 0)) + " in · " + str(u.get("output_tokens", 0)) + " out tokens");
        }
    }
    proc.wait();
    if proc.returncode not in [0, None] and not run.cancel {
        err = (proc.stderr.read() or "")[-600:];
        if err.strip() {
            run.emit("error", text=err.strip());
        }
    }
}

# ------------------------------------------------------------------ Claude Code (claude -p)

def _claude_title(name: str, inp: dict[str, any]) -> tuple[str, str, list[str]] {
    path = str(inp.get("file_path") or inp.get("path") or inp.get("notebook_path") or "");
    kinds = {"Read": "read", "Edit": "edit", "MultiEdit": "edit", "Write": "edit", "Bash": "execute", "Grep": "search", "Glob": "search", "LS": "read", "WebFetch": "fetch", "WebSearch": "fetch", "TodoWrite": "think", "Task": "think"};
    kind = kinds.get(name, "other");
    if name == "Bash" {
        return (str(inp.get("command", ""))[:160], kind, []);
    }
    if name in ["Grep", "Glob"] {
        return (name + " " + str(inp.get("pattern", "")), kind, [path] if path else []);
    }
    return (name + (" " + _rel(path) if path else ""), kind, [path] if path else []);
}

def run_claude(run: Run, proj_root: str, text: str, allow_edits: bool) -> None {
    cl = tool_bin("claude");
    if not cl {
        raise Exception("Claude Code CLI not found - see Settings › Agents");
    }
    key = "claude@" + proj_root;
    model = str(read_config().get("claude_model", "") or "");
    cmd = [cl, "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages"];
    if allow_edits {
        cmd.extend(["--permission-mode", "acceptEdits"]);
    } else {
        cmd.extend(["--disallowedTools", "Edit", "MultiEdit", "Write", "NotebookEdit", "Bash"]);
    }
    if model {
        cmd.extend(["--model", model]);
    }
    if key in _resume {
        cmd.extend(["--resume", _resume[key]]);
    }
    proc: any = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, cwd=proj_root, env=tool_env());
    run.proc = proc;
    proc.stdin.write(text);
    proc.stdin.close();
    tools: dict[str, dict[str, any]] = {};
    for line in proc.stdout {
        try {
            e = json.loads(line);
        } except ValueError {
            continue;
        }
        t = e.get("type", "");
        if t == "system" and e.get("subtype") == "init" {
            _resume[key] = str(e.get("session_id", ""));
        } elif t == "stream_event" {
            ev = e.get("event") or {};
            if ev.get("type") == "content_block_delta" {
                d = ev.get("delta") or {};
                if d.get("type") == "text_delta" {
                    run.emit("text", text=str(d.get("text", "")));
                } elif d.get("type") == "thinking_delta" {
                    run.emit("thought", text=str(d.get("thinking", "")));
                }
            }
        } elif t == "assistant" {
            for block in (e.get("message") or {}).get("content") or [] {
                if block.get("type") == "tool_use" {
                    inp = block.get("input") or {};
                    (title, kind, paths) = _claude_title(str(block.get("name", "")), inp);
                    diff = "";
                    if block.get("name") in ["Edit", "MultiEdit"] {
                        edits = inp.get("edits") or [{"old_string": inp.get("old_string", ""), "new_string": inp.get("new_string", "")}];
                        diff = "\n".join([_diff(_rel(paths[0]) if paths else "", str(x.get("old_string", "")), str(x.get("new_string", ""))) for x in edits])[:4000];
                    } elif block.get("name") == "Write" {
                        diff = _diff(_rel(paths[0]) if paths else "", "", str(inp.get("content", "")))[:4000];
                    }
                    for pth in paths {
                        _touch(run, pth, kind == "edit");
                    }
                    tools[str(block.get("id"))] = {"title": title, "kind": kind, "paths": [_rel(x) for x in paths]};
                    run.emit("tool", tool_id=str(block.get("id")), title=title, status="in_progress", tool_kind=kind, paths=[_rel(x) for x in paths], diff=diff);
                }
            }
        } elif t == "user" {
            for block in (e.get("message") or {}).get("content") or [] {
                if isinstance(block, dict) and block.get("type") == "tool_result" {
                    tid = str(block.get("tool_use_id"));
                    meta = tools.get(tid, {"title": "", "kind": "", "paths": []});
                    run.emit("tool", tool_id=tid, title=meta["title"], status="failed" if block.get("is_error") else "completed", tool_kind=meta["kind"], paths=meta["paths"]);
                }
            }
        } elif t == "result" {
            if e.get("session_id") {
                _resume[key] = str(e["session_id"]);
            }
            cost = e.get("total_cost_usd");
            denials = e.get("permission_denials") or [];
            if denials {
                run.emit("info", text=str(len(denials)) + " action(s) blocked because edits are locked.");
            }
            if e.get("is_error") {
                run.emit("error", text=str(e.get("result") or "Claude reported an error"));
            }
            if cost is not None {
                run.emit("info", text="$" + str(round(float(cost), 4)) + " this turn");
            }
        }
    }
    proc.wait();
    if proc.returncode not in [0, None] and not run.cancel {
        err = (proc.stderr.read() or "")[-600:];
        if err.strip() {
            run.emit("error", text=err.strip());
        }
    }
}

# ------------------------------------------------------------------ Jac agent

def run_jac(run: Run, message: str, preamble: str) -> None {
    _ensure_model();
    _touched.clear();
    _edited.clear();
    text = run_jac_agent(message, preamble);
    for pth in list(_touched) {
        _touch(run, pth);
    }
    for pth in list(_edited) {
        _touch(run, pth, True);
    }
    run.emit("text", text=str(text));
}

# ------------------------------------------------------------------ runs

def _work(run: Run, backend: str, message: str, focus_id: str, context: str, context_file: str, allow_edits: bool) -> None {
    p = current_project();
    try {
        if p is None {
            raise Exception("Open a project first.");
        }
        preamble = context_preamble(focus_id, context, context_file, allow_edits);
        full = preamble + "\n\n[developer request]\n" + message;
        before = _snapshot_mtimes(p.root_dir) if backend in ["codex", "claude"] else {};
        if context_file {
            _touch(run, os.path.join(p.root_dir, context_file.split(":")[0]));
        }
        if backend in ["gemini", "custom"] {
            run_acp(run, backend, p.root_dir, full, allow_edits);
        } elif backend == "codex" {
            run_codex(run, p.root_dir, full, allow_edits);
        } elif backend == "claude" {
            run_claude(run, p.root_dir, full, allow_edits);
        } else {
            jac_agent_allow(allow_edits);
            run_jac(run, message, preamble);
        }
        if before {
            after = _snapshot_mtimes(p.root_dir);
            for f in sorted([f for (f, t) in after.items() if before.get(f) != t]) {
                _touch(run, os.path.join(p.root_dir, f), True);
            }
        }
        if run.edited {
            run.reindexed = reindex().ok;
        }
    } except Exception as e {
        run.emit("error", text=str(e)[:800]);
    }
    run.emit("done");
    run.finish();
}

def jac_agent_allow(allow: bool) -> None {
    import agent.agent as ag;
    ag._allow_edits = allow;
}

def:pub agent_start(token: str, message: str, focus_id: str, backend: str = "", allow_edits: bool = False, context: str = "", context_file: str = "") -> RunStart {
    if not authorized(token) {
        return RunStart(ok=False, error="unauthorized");
    }
    chosen = backend or str(read_config().get("agent_backend", "codex"));
    run = Run(id=secrets.token_hex(6), backend=chosen, cond=threading.Condition());
    _runs[run.id] = run;
    threading.Thread(target=_work, args=(run, chosen, message, focus_id, context, context_file, allow_edits), daemon=True).start();
    return RunStart(run_id=run.id, backend=chosen);
}

def read_events(run_id: str, after: int, wait_s: float) -> EventBatch {
    run = _runs.get(run_id);
    if run is None {
        return EventBatch(ok=False, error="no such run", done=True);
    }
    deadline = time.time() + max(min(wait_s, 25.0), 0.0);
    with run.cond {
        while len(run.events) <= after and not run.done and time.time() < deadline {
            run.cond.wait(timeout=max(min(deadline - time.time(), 1.0), 0.01));
        }
        evs = run.events[after:];
        done = run.done and len(run.events) <= after + len(evs);
    }
    return EventBatch(events=evs, done=done, touched=list(run.touched), edited=list(run.edited), reindexed=run.reindexed);
}

def:pub agent_events(token: str, run_id: str, after: int = 0, wait_s: float = 20.0) -> EventBatch {
    if not authorized(token) {
        return EventBatch(ok=False, error="unauthorized", done=True);
    }
    return read_events(run_id, after, wait_s);
}

def:pub agent_permission(token: str, run_id: str, permission_id: str, option_id: str) -> bool {
    if not authorized(token) {
        return False;
    }
    run = _runs.get(run_id);
    if run is None or permission_id not in run.permissions {
        return False;
    }
    w = run.permissions.pop(permission_id);
    w["choice"] = option_id;
    w["event"].set();
    return True;
}

def:pub agent_cancel(token: str, run_id: str) -> bool {
    if not authorized(token) {
        return False;
    }
    run = _runs.get(run_id);
    if run is None {
        return False;
    }
    run.cancel = True;
    for w in list(run.permissions.values()) {
        w["event"].set();
    }
    proc = run.proc;
    if isinstance(proc, AcpClient) {
        proc.cancel();
    } elif proc is not None {
        try { proc.terminate(); } except Exception {}
    }
    return True;
}

def:pub agent_reset(token: str, backend: str = "") -> bool {
    if not authorized(token) {
        return False;
    }
    for k in list(_resume.keys()) {
        if not backend or k.startswith(backend + "@") {
            _resume.pop(k);
        }
    }
    for k in list(_acp.keys()) {
        if not backend or k.startswith(backend + "@") {
            _acp.pop(k).close();
        }
    }
    import agent.agent as ag;
    ag.history.clear();
    return True;
}

# ------------------------------------------------------------------ status for Settings

def _version(cmd: list[str]) -> str {
    try {
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=15, env=tool_env());
        out = (r.stdout or r.stderr or "").strip().splitlines();
        return out[0][:60] if out else "";
    } except Exception {
        return "";
    }
}

def agents_status_list() -> list[AgentStatus] {
    cfg = read_config();
    out: list[AgentStatus] = [];
    cx = codex_path();
    out.append(AgentStatus(id="codex", name=AGENT_NAMES["codex"], transport="codex exec --json (codex-acp lags current models)", installed=bool(cx), ready=bool(cx), version=_version([cx, "--version"]) if cx else "", model=str(cfg.get("codex_model", "") or ""), detail="Uses your ChatGPT sign-in"));
    cl = tool_bin("claude");
    out.append(AgentStatus(id="claude", name=AGENT_NAMES["claude"], transport="claude -p (stream-json)", installed=bool(cl), ready=bool(cl), version=_version([cl, "--version"]) if cl else "", model=str(cfg.get("claude_model", "") or ""), detail="Uses your Claude Code login"));
    g = tool_bin("gemini");
    auth = "GEMINI_API_KEY" if os.environ.get("GEMINI_API_KEY") else "Google sign-in (opens a browser on first use)";
    out.append(AgentStatus(id="gemini", name=AGENT_NAMES["gemini"], transport="ACP (gemini --acp)", installed=bool(g), ready=bool(g), version=_version([g, "--version"]) if g else "", model=str(cfg.get("gemini_model", "") or ""), detail="Auth: " + auth));
    out.append(AgentStatus(id="jac", name=AGENT_NAMES["jac"], transport="byLLM tools", installed=True, ready=True, model=str(cfg.get("agent_model", "") or ""), detail="Built in; tools read the architecture and load Jac skills"));
    custom = str(cfg.get("custom_acp_command", "") or "");
    out.append(AgentStatus(id="custom", name=AGENT_NAMES["custom"], transport="ACP", installed=bool(custom), ready=bool(custom), detail=custom or "Set a command, e.g. `npx @zed-industries/claude-code-acp`"));
    return out;
}

def:pub agents_status(token: str) -> list[AgentStatus] {
    if not authorized(token) {
        return [];
    }
    return agents_status_list();
}

def:pub agent_install(token: str, agent_id: str) -> str {
    if not authorized(token) {
        return "unauthorized";
    }
    pkgs = {"gemini": "@google/gemini-cli", "claude": "@anthropic-ai/claude-code", "codex": "@openai/codex"};
    if agent_id not in pkgs {
        return "Nothing to install for " + agent_id;
    }
    npm = shutil.which("npm", path=tool_env()["PATH"]);
    if not npm {
        return "npm not found - install Node.js first";
    }
    os.makedirs(TOOLS_DIR, exist_ok=True);
    r = subprocess.run([npm, "install", "--prefix", TOOLS_DIR, "--no-audit", "--no-fund", pkgs[agent_id]], capture_output=True, text=True, timeout=900, env=tool_env());
    return ("Installed " + pkgs[agent_id]) if r.returncode == 0 else ("Install failed: " + (r.stderr or r.stdout)[-400:]);
}
