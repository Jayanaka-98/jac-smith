"""The end of the drill-down: a file as an editor would show it - every line, numbered, highlighted,
scrollable, with an outline to jump between declarations.

Locked by default (fast read-only view). The lock at the top right unlocks real editing; saves are
atomic and refuse to overwrite changes made elsewhere. Selecting code hands it to the agent.
"""
import from "react" { useEffect }
import from "lucide-react" { FileCode, ListTree, Lock, LockOpen, Save, TriangleAlert }
import from ..indexer.model { BoxInfo, SymbolInfo }
import from .rpc { rpc }
import from .cache { cached_lines, forget_file }
import from .Editor { CodeEditor }

glob CHUNK: int = 200;

def:pub symbol_line(s: SymbolInfo) -> int {
    return s.line;
}

def:pub line_of(dom: any) -> int {
    el: any = dom;
    if el and el.nodeType == 3 {
        el = el.parentElement;
    }
    row: any = el.closest("[data-ln]") if el else None;
    return int(row.getAttribute("data-ln")) if row else 0;
}

def:pub CodeView(
    file: BoxInfo,
    jumpLine: int,
    onJump: Callable[[int], None],
    onSelection: Callable[[str, int, int, str], None],
    onSaved: Callable[[], None]
) -> JsxElement {
    has lines: list[list[list[str]]] = [];
    has loading: bool = True;
    has active: int = 0;
    has scrollRef: Ref[HTMLDivElement] = Ref();
    has locked: bool = True;
    has text: str = "";
    has original: str = "";
    has version: str = "";
    has saving: bool = False;
    has notice: str = "";
    has conflict: bool = False;
    has confirmLock: bool = False;
    has reloadKey: int = 0;

    async can with [file.id, reloadKey] entry {
        loading = True;
        if reloadKey > 0 {
            forget_file(file.id);
        }
        lines = await cached_lines(file.id);
        loading = False;
    }
    can with [file.id] entry {
        locked = True;
        confirmLock = False;
        notice = "";
        conflict = False;
    }

    def go(line: int) {
        if scrollRef.current {
            el: any = scrollRef.current.querySelector("[data-ln='" + str(line) + "']");
            if el {
                el.scrollIntoView({"block": "center", "behavior": "smooth"});
            }
        }
        active = line;
    }

    useEffect(lambda {
        if jumpLine > 0 and len(lines) > 0 and locked {
            go(jumpLine);
        }
        return lambda { };
    }, [jumpLine, len(lines), file.id, locked]);

    dirty = not locked and text != original;

    async def unlock() {
        notice = "";
        conflict = False;
        f = await rpc("read_source_file", {"box_id": file.id});
        if not f["ok"] {
            notice = String(f["error"]);
            return;
        }
        text = String(f["text"]);
        original = text;
        version = String(f["version"]);
        locked = False;
    }
    async def save() {
        if saving or not dirty {
            return;
        }
        saving = True;
        r = await rpc("write_source", {"box_id": file.id, "content": text, "expected_version": version});
        saving = False;
        if r["ok"] {
            version = String(r["version"]);
            original = text;
            notice = "Saved";
            conflict = False;
            forget_file(file.id);
            setTimeout(lambda { if notice == "Saved" { notice = ""; } }, 1600);
            onSaved();
        } else {
            notice = String(r["error"]);
            conflict = bool(r["conflict"]);
        }
    }
    def lock_now() {
        locked = True;
        confirmLock = False;
        reloadKey = reloadKey + 1;
    }
    def toggle_lock(e: MouseEvent) {
        if locked {
            unlock();
        } elif dirty {
            confirmLock = True;
        } else {
            lock_now();
        }
    }
    async def save_and_lock() {
        await save();
        if not dirty {
            lock_now();
        }
    }
    async def reload_from_disk() {
        await unlock();
    }

    # selection in the read-only view: map the DOM selection back to line numbers
    def mouse_up(e: MouseEvent) {
        sel: any = globalThis.getSelection();
        if not sel or sel.isCollapsed {
            return;
        }
        a = line_of(sel.anchorNode);
        b = line_of(sel.focusNode);
        if a == 0 or b == 0 {
            return;
        }
        lo = min(a, b);
        hi = max(a, b);
        if lo == hi {
            picked = String(sel.toString());
        } else {
            picked = chr(10).join(["".join([t[1] for t in ln]) for ln in lines[lo - 1:hi]]);
        }
        if picked.strip() {
            onSelection(file.id, lo, hi, picked);
        }
    }

    chunks: list[int] = list(range(0, len(lines), CHUNK));
    outline = sorted(file.symbols, key=symbol_line);
    width = len(str(len(lines))) + 1;

    <div className="codeview">
        <div className="cv-main">
            <div className="cv-head">
                <FileCode size={14} />
                <span className="cv-path">{file.path}</span>
                {dirty and <span className="cv-dirty" title="Unsaved changes" />}
                {notice and <span className={"cv-notice" + (" bad" if notice != "Saved" else "")}>{notice}</span>}
                <span className="stat">{str(len(lines)) + " lines · " + (file.lang or "text")}</span>
                {not locked and <button className="chip-btn" disabled={not dirty or saving} onClick={lambda (e: MouseEvent) { save(); }} title="Save (⌘S)"><Save size={12} />{"Saving..." if saving else "Save"}</button>}
                <button className={"lock-btn" + ("" if locked else " open")} onClick={toggle_lock} title={"Locked - click to edit" if locked else "Editing - click to lock"}>
                    {if locked { <Lock size={14} /> } else { <LockOpen size={14} /> }}
                    <span>{"Locked" if locked else "Editing"}</span>
                </button>
            </div>
            {if confirmLock {
                <div className="cv-bar">
                    <TriangleAlert size={13} />
                    <span>Unsaved changes.</span>
                    <button className="chip-btn" onClick={lambda (e: MouseEvent) { save_and_lock(); }}>Save and lock</button>
                    <button className="chip-btn" onClick={lambda (e: MouseEvent) { lock_now(); }}>Discard</button>
                    <button className="chip-btn" onClick={lambda (e: MouseEvent) { confirmLock = False; }}>Keep editing</button>
                </div>
            } elif conflict {
                <div className="cv-bar">
                    <TriangleAlert size={13} />
                    <span>The file changed on disk while you were editing.</span>
                    <button className="chip-btn" onClick={lambda (e: MouseEvent) { reload_from_disk(); }}>Reload (lose my edits)</button>
                </div>
            }}
            {if locked {
                <div className="cv-scroll" ref={scrollRef} style={{"--gutter": str(width) + "ch"}} onMouseUp={mouse_up}>
                    {if loading {
                        <div className="cv-loading shimmer-text">Opening file...</div>
                    }}
                    {for start in chunks {
                        <div key={"ch" + str(start)} className="cv-chunk" style={{"containIntrinsicSize": "auto " + str(min(CHUNK, len(lines) - start) * 20) + "px"}}>
                            {for (i, toks) in enumerate(lines[start:start + CHUNK]) {
                                <div key={str(start + i)} className={"cv-line" + (" hl" if start + i + 1 == active else "")} data-ln={str(start + i + 1)}>
                                    <span className="cv-ln">{str(start + i + 1)}</span>
                                    <span className="cv-code">{for (j, tk) in enumerate(toks) { <span key={str(j)} className={"tk-" + tk[0]}>{tk[1]}</span> }}{" "}</span>
                                </div>
                            }}
                        </div>
                    }}
                </div>
            } else {
                <CodeEditor
                    text={original}
                    lang={file.lang}
                    jumpLine={jumpLine}
                    onChange={lambda (v: str) { text = v; }}
                    onSave={lambda { save(); }}
                    onSelection={lambda (a: int, b: int, t: str) { onSelection(file.id, a, b, t); }}
                />
            }}
        </div>
        {if len(outline) > 0 {
            <aside className="cv-outline">
                <div className="cv-outline-head"><ListTree size={13} />Outline</div>
                {for s in outline {
                    <button key={s.name + str(s.line)} className={"cv-sym" + (" on" if active == s.line else "") + ("" if s.public else " private")} onClick={lambda (e: MouseEvent) { go(s.line); onJump(s.line); }} title={s.signature}>
                        <span className="k">{s.kind}</span>
                        <span className="n">{s.name}</span>
                        <span className="l">{str(s.line)}</span>
                    </button>
                }}
            </aside>
        }}
    </div>
}
