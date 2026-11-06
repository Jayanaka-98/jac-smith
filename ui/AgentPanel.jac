"""The agent hub panel: Codex, Claude Code, Gemini (ACP), the Jac agent, or any ACP agent.

Replies stream in as events: text, thinking, tool calls with diffs, plans, and permission requests
that you answer inline. The agent always knows the focused box and any code you selected.
"""
import from "lucide-react" {
    Sparkles, Send, RefreshCw, Minus, TextSelect, X, Square, FileText, Pencil, TerminalSquare,
    Search, Globe, Brain, Wrench, Check, LoaderCircle, CircleX, ShieldQuestion
}
import from .rpc { rpc }

obj ChatMsg {
    has who: str;
    has text: str = "";
    has parts: list[dict[str, any]] = [];
    has touched: list[str] = [];
    has edited: list[str] = [];
    has meta: str = "";
    has failed: bool = False;
    has live: bool = False;
    has run_id: str = "";
}

glob AGENT_LABELS: dict[str, str] = {"codex": "Codex", "claude": "Claude", "gemini": "Gemini", "jac": "Jac agent", "custom": "ACP agent"};

def:pub agent_label(b: str) -> str {
    return AGENT_LABELS[b] if b in AGENT_LABELS else b;
}

"""Fold a batch of hub events into the message's parts (returns a fresh list for reactivity)."""
def:pub apply_events(parts: list[dict[str, any]], events: list[any]) -> list[dict[str, any]] {
    out = [{**p} for p in parts];
    for ev in events {
        k = ev["kind"];
        last = out[len(out) - 1] if len(out) > 0 else None;
        if k in ["text", "thought"] {
            if last and last["type"] == k {
                last["text"] = last["text"] + ev["text"];
            } else {
                out.append({"type": k, "text": ev["text"]});
            }
        } elif k == "tool" {
            found = False;
            for p in out {
                if p["type"] == "tool" and p["id"] == ev["tool_id"] {
                    found = True;
                    if ev["title"] {
                        p["title"] = ev["title"];
                    }
                    if ev["status"] {
                        p["status"] = ev["status"];
                    }
                    if ev["diff"] {
                        p["diff"] = ev["diff"];
                    }
                    if len(ev["paths"]) > 0 {
                        p["paths"] = ev["paths"];
                    }
                }
            }
            if not found {
                out.append({"type": "tool", "id": ev["tool_id"], "title": ev["title"], "status": ev["status"], "kind": ev["tool_kind"], "paths": ev["paths"], "diff": ev["diff"]});
            }
        } elif k == "plan" {
            out = [p for p in out if p["type"] != "plan"];
            out.append({"type": "plan", "text": ev["text"]});
        } elif k == "permission" {
            out.append({"type": "permission", "id": ev["tool_id"], "title": ev["title"], "kind": ev["tool_kind"], "options": ev["options"], "chosen": ""});
        } elif k == "permission_done" {
            for p in out {
                if p["type"] == "permission" and p["id"] == ev["tool_id"] {
                    p["chosen"] = ev["text"];
                }
            }
        } elif k in ["info", "error"] {
            out.append({"type": k, "text": ev["text"]});
        }
    }
    return out;
}

def:pub ToolIcon(kind: str) -> JsxElement {
    <span className="ti">{if kind == "read" { <FileText size={13} /> } elif kind == "edit" { <Pencil size={13} /> } elif kind == "execute" { <TerminalSquare size={13} /> } elif kind == "search" { <Search size={13} /> } elif kind == "fetch" { <Globe size={13} /> } elif kind == "think" { <Brain size={13} /> } else { <Wrench size={13} /> }}</span>
}

def:pub DiffBlock(diff: str) -> JsxElement {
    lines = diff.split(chr(10))[:60];
    <pre className="diff">{for (i, l) in enumerate(lines) {
        <span key={str(i)} className={"dl " + ("add" if l.startswith("+") and not l.startswith("+++") else ("del" if l.startswith("-") and not l.startswith("---") else ("hunk" if l.startswith("@@") else "")))}>{l + chr(10)}</span>
    }}</pre>
}

def:pub AgentParts(
    parts: list[dict[str, any]],
    runId: str,
    onNavigate: Callable[[str], None],
    onAnswer: Callable[[str, str, str], None]
) -> JsxElement {
    <div className="parts">
        {for (i, p) in enumerate(parts) {
            if p["type"] == "text" {
                <div key={"p" + str(i)} className="part-text">{p["text"]}</div>
            } elif p["type"] == "thought" {
                <details key={"p" + str(i)} className="part-thought"><summary><Brain size={12} />Thinking</summary><div>{p["text"]}</div></details>
            } elif p["type"] == "tool" {
                <div key={"p" + str(i)} className={"part-tool " + p["status"]}>
                    <div className="tool-row">
                        <span className="tool-icon"><ToolIcon kind={p["kind"]} /></span>
                        <span className="tool-title">{p["title"] or p["kind"]}</span>
                        <span className="tool-status">{if p["status"] == "completed" { <Check size={12} /> } elif p["status"] == "failed" { <CircleX size={12} /> } else { <LoaderCircle size={12} className="spin" /> }}</span>
                    </div>
                    {len(p["paths"]) > 0 and <div className="tool-paths">
                        {for pth in p["paths"][:6] {
                            <button key={pth} className="touch-chip" onClick={lambda (e: MouseEvent) { onNavigate(pth); }}>{pth}</button>
                        }}
                    </div>}
                    {p["diff"] and <DiffBlock diff={p["diff"]} />}
                </div>
            } elif p["type"] == "plan" {
                <div key={"p" + str(i)} className="part-plan">{p["text"]}</div>
            } elif p["type"] == "permission" {
                <div key={"p" + str(i)} className="part-perm">
                    <div className="perm-head"><ShieldQuestion size={14} /><span>{p["title"]}</span></div>
                    {if p["chosen"] {
                        <div className="perm-chosen">{"Answered: " + p["chosen"]}</div>
                    } else {
                        <div className="perm-actions">
                            {for o in p["options"] {
                                <button key={o["id"]} className={"btn-grad" if o["kind"].startswith("allow") else "chip-btn"} onClick={lambda (e: MouseEvent) { onAnswer(runId, p["id"], o["id"]); }}>{o["name"]}</button>
                            }}
                        </div>
                    }}
                </div>
            } elif p["type"] == "info" {
                <div key={"p" + str(i)} className="part-info">{p["text"]}</div>
            } elif p["type"] == "error" {
                <div key={"p" + str(i)} className="part-error">{p["text"]}</div>
            }
        }}
    </div>
}

def:pub AgentPanel(
    width: float,
    focusId: str,
    focusName: str,
    backend: str,
    draft: str,
    onTouched: Callable[[list[str]], None],
    onEdited: Callable[[], None],
    onNavigate: Callable[[str], None],
    hidden: bool = False,
    onMinimize: Callable[[], None] | None = None,
    onActivity: Callable[[bool, bool], None] | None = None,
    selection: dict[str, any] | None = None,
    onClearSelection: Callable[[], None] | None = None
) -> JsxElement {
    has msgs: list[ChatMsg] = [];
    has text: str = "";
    has busy: bool = False;
    has allowEdits: bool = False;
    has chosen: str = "";
    has runId: str = "";
    has endRef: Ref[HTMLDivElement] = Ref();

    can with [draft] entry {
        if draft {
            text = draft;
        }
    }
    can with [msgs, busy] entry {
        if endRef.current {
            endRef.current.scrollIntoView({"block": "end"});
        }
    }

    active_backend = chosen or backend or "codex";

    def update_last(parts: list[dict[str, any]], touched: list[str], edited: list[str], live: bool, failed: bool) {
        if len(msgs) == 0 {
            return;
        }
        last = msgs[len(msgs) - 1];
        msgs = msgs[:len(msgs) - 1] + [ChatMsg(who="agent", parts=parts, touched=touched, edited=edited, meta=last.meta, failed=failed, live=live, run_id=last.run_id)];
    }

    async def send_text(msg: str) {
        if not msg or busy {
            return;
        }
        text = "";
        ctx = selection["text"] if selection else "";
        ctx_file = (selection["file"] + ":" + str(selection["start"]) + "-" + str(selection["end"])) if selection else "";
        user_meta = (selection["file"].split("/")[-1] + " L" + str(selection["start"]) + "-" + str(selection["end"])) if selection else focusName;
        if selection and onClearSelection {
            onClearSelection();
        }
        busy = True;
        if onActivity {
            onActivity(True, False);
        }
        msgs = msgs + [ChatMsg(who="user", text=msg, meta=user_meta)];
        try {
            st = await rpc("agent_start", {"message": msg, "focus_id": focusId, "backend": active_backend, "allow_edits": allowEdits, "context": ctx, "context_file": ctx_file});
            if not st["ok"] {
                raise Exception(String(st["error"]));
            }
            runId = st["run_id"];
            msgs = msgs + [ChatMsg(who="agent", meta=agent_label(st["backend"]), live=True, run_id=st["run_id"])];
            parts: list[dict[str, any]] = [];
            after = 0;
            done = False;
            failed = False;
            touched: list[str] = [];
            while not done {
                b = await rpc("agent_events", {"run_id": st["run_id"], "after": after, "wait_s": 20});
                if not b["ok"] {
                    parts = parts + [{"type": "error", "text": String(b["error"])}];
                    failed = True;
                    break;
                }
                after = after + len(b["events"]);
                parts = apply_events(parts, b["events"]);
                failed = failed or len([e for e in b["events"] if e["kind"] == "error"]) > 0;
                touched = b["touched"];
                update_last(parts, touched, b["edited"], True, failed);
                onTouched(touched);
                done = b["done"];
                if done and b["reindexed"] {
                    onEdited();
                }
            }
            last = msgs[len(msgs) - 1];
            update_last(last.parts, last.touched, last.edited, False, failed);
        } except Exception as e {
            msgs = msgs + [ChatMsg(who="agent", parts=[{"type": "error", "text": String(e)}], failed=True)];
        }
        busy = False;
        runId = "";
        if onActivity {
            onActivity(False, True);
        }
    }
    async def answer(run_id: str, perm_id: str, option_id: str) {
        await rpc("agent_permission", {"run_id": run_id, "permission_id": perm_id, "option_id": option_id});
    }
    async def stop() {
        if runId {
            await rpc("agent_cancel", {"run_id": runId});
        }
    }
    def on_key(e: KeyboardEvent) {
        if e.key == "Enter" and (e.metaKey or e.ctrlKey) {
            e.preventDefault();
            send_text(text.strip());
        }
    }
    async def reset() {
        await rpc("agent_reset", {"backend": ""});
        msgs = [];
        onTouched([]);
    }

    suggestions = [
        "What is " + focusName + " responsible for, and what depends on it?",
        "Where would I add a new feature in " + focusName + "?",
        "What looks risky or tangled in " + focusName + "?"
    ];

    <aside className="agent" style={{"width": str(width) + "px", "display": "none" if hidden else "flex"}}>
        <div className="agent-card">
            <div className="agent-head">
                <span className="spark"><Sparkles size={14} /></span>
                <span className="agent-title">{agent_label(active_backend)}</span>
                <span className="focus-chip" title={"Focused on " + focusName}>{focusName}</span>
                <span className="spacer" />
                <button className="icon-btn" onClick={lambda (e: MouseEvent) { reset(); }} title="New conversation"><RefreshCw size={14} /></button>
                {onMinimize and <button className="icon-btn" onClick={lambda (e: MouseEvent) { onMinimize(); }} title="Minimize to orb"><Minus size={15} /></button>}
            </div>
            <div className="msgs">
                {if len(msgs) == 0 {
                    <div className="welcome">
                        <div>{"Ask about the box you are in. The agent reads the architecture first and opens code only when it needs to. Files it reads glow yellow; files it edits turn red."}</div>
                        {for s in suggestions {
                            <button key={s} className="suggest" onClick={lambda (e: MouseEvent) { send_text(s); }}>{s}</button>
                        }}
                    </div>
                }}
                {for (i, m) in enumerate(msgs) {
                    <div key={"m" + str(i)} className={"msg " + m.who + (" error" if m.failed else "")}>
                        {if m.who == "user" {
                            <span>{m.text}</span>
                        } else {
                            <AgentParts parts={m.parts} runId={m.run_id} onNavigate={onNavigate} onAnswer={lambda (r: str, p: str, o: str) { answer(r, p, o); }} />
                        }}
                        {if m.who == "agent" and len(m.parts) == 0 and m.live {
                            <div className="thinking"><Sparkles size={13} /><span className="shimmer-text">{"Working on " + focusName + "..."}</span></div>
                        }}
                        {if m.who == "agent" and not m.live and (len(m.touched) > 0 or m.meta) {
                            <div className="msg-meta">
                                {m.meta and <span>{m.meta}</span>}
                                {for t in m.touched[:10] {
                                    <button key={t} className={"touch-chip" + (" edit" if t in m.edited else "")} onClick={lambda (e: MouseEvent) { onNavigate(t); }}>{t}</button>
                                }}
                            </div>
                        }}
                    </div>
                }}
                <div ref={endRef} />
            </div>
            <div className="composer">
                {selection and <div className="sel-chip" title={selection["text"]}>
                    <TextSelect size={13} />
                    <span className="sel-file">{selection["file"].split("/")[-1]}</span>
                    <span className="sel-range">{"L" + str(selection["start"]) + ("" if selection["start"] == selection["end"] else "–" + str(selection["end"]))}</span>
                    <span className="sel-preview">{selection["text"].strip().split(chr(10))[0][:60]}</span>
                    <button className="sel-x" onClick={lambda (e: MouseEvent) { if onClearSelection { onClearSelection(); } }} title="Don't send this selection"><X size={12} /></button>
                </div>}
                <div className="composer-box">
                    <textarea value={text} onChange={lambda (e: ChangeEvent) { text = e.target.value; }} onKeyDown={on_key} placeholder={("Ask about the selected code" if selection else "Ask about " + focusName) + "   ⌘↵"} />
                    <div className="composer-row">
                        <select className="select" value={active_backend} onChange={lambda (e: ChangeEvent) { chosen = e.target.value; }}>
                            <option value="codex">Codex · ChatGPT</option>
                            <option value="claude">Claude Code</option>
                            <option value="gemini">Gemini · ACP</option>
                            <option value="jac">Jac agent · byLLM</option>
                            <option value="custom">Custom ACP agent</option>
                        </select>
                        <label className="check"><input type="checkbox" checked={allowEdits} onChange={lambda (e: ChangeEvent) { allowEdits = e.target.checked; }} />edits</label>
                        <span className="spacer" />
                        {if busy {
                            <button className="send stop" onClick={lambda (e: MouseEvent) { stop(); }} title="Stop"><Square size={12} /></button>
                        } else {
                            <button className="send" disabled={not text.strip()} onClick={lambda (e: MouseEvent) { send_text(text.strip()); }}><Send size={14} /></button>
                        }}
                    </div>
                </div>
            </div>
        </div>
    </aside>
}
