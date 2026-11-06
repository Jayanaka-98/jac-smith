"""App shell: top bar, the detail card on the left, the two views, terminal, and the agent."""
import from "react" { useEffect }
import from "lucide-react" { FolderOpen, Boxes, Workflow, Terminal as TerminalIcon, Settings2, ChevronRight, LoaderCircle, PanelLeft, GitBranch }
import from ..indexer.model { BoxFrame, BoxInfo, Crumb, IndexSummary, SettingsStatus }
import from ..architect.model { ArchModel, ArchComponent }
import from .rpc { rpc }
import from .cache { cached_frame, prefetch, clear_cache }
import from .theme { ROLE_ORDER, role_rgb, fmt_count }
import from .BoxView { BoxView }
import from .ArchView { ArchView }
import from .DetailCard { BoxCard, ComponentCard, ProjectCard, CommitCard }
import from .TimelineView { TimelineView }
import from .AgentPanel { AgentPanel }
import from .AgentBlob { AgentBlob }
import from .SettingsPanel { SettingsPanel, apply_theme }
import from .Terminal { TerminalPanel }
import from .Sash { Sash, load_layout, save_layout, clamp_size, layout_default, load_agent_min, save_agent_min }

def:pub Shell() -> JsxElement {
    has projectPath: str = "";
    has summary: IndexSummary | None = None;
    has frame: BoxFrame | None = None;
    has focusId: str = ".";
    has view: str = "developer";
    has direction: str = "in";
    has loading: str = "";
    has error: str = "";
    has touched: list[str] = [];
    has showSettings: bool = False;
    has showTerminal: bool = False;
    has termEver: bool = False;
    has jevReady: bool = False;
    has jevState: str = "";
    has backend: str = "codex";
    has draft: str = "";
    has hovered: BoxInfo | None = None;
    has selected: BoxInfo | None = None;
    has archModel: ArchModel | None = None;
    has selComp: str = "";
    has projectKey: str = "";
    has sizes: dict[str, float] = load_layout();
    has dragBase: Ref[float] = Ref(0.0);
    has agentMin: bool = load_agent_min();
    has agentBusy: bool = False;
    has agentUnread: bool = False;
    has codeSel: dict[str, any] | None = None;
    has histCommit: str = "";
    has commitDetail: any = None;
    has diffPath: str = "";
    has archModule: BoxInfo | None = None;

    def aspect() -> float {
        w = window.innerWidth - sizes["left"] - (0 if agentMin else sizes["agent"]) - (sizes["rail"] if sizes["rail"] > 0 else 34) - 80;
        h = window.innerHeight - 150 - ((sizes["term"] + 20) if showTerminal else 0);
        return max(w, 300) / max(h, 200);
    }

    def relayout() {
        save_layout(sizes);
        if frame is not None and view == "developer" {
            load_frame(focusId);
        }
    }
    def start_drag(key: str) {
        dragBase.current = 0.0 if (key == "agent" and agentMin) else sizes[key];
    }
    def set_agent_min(v: bool) {
        agentMin = v;
        if not v {
            agentUnread = False;
        }
        save_agent_min(v);
    }
    async def select_commit(sha: str) {
        histCommit = sha;
        diffPath = "";
        commitDetail = None;
        commitDetail = await rpc("git_commit", {"sha": sha});
    }
    def show_on_map(ids: list[str]) {
        touched = ids;
        view = "developer";
        open_box(".", "out");
    }
    async def select_arch_module(mid: str) {
        archModule = await rpc("get_box", {"box_id": mid});
    }
    def toggle_rail() {
        nxt = {**sizes};
        if sizes["rail"] > 0 {
            nxt["railLast"] = sizes["rail"];
            nxt["rail"] = 0;
        } else {
            nxt["rail"] = sizes["railLast"] if sizes["railLast"] >= 150 else layout_default("rail");
        }
        sizes = nxt;
        relayout();
    }
    def toggle_left() {
        nxt = {**sizes};
        nxt["left"] = layout_default("left") if sizes["left"] == 0 else 0;
        sizes = nxt;
        relayout();
    }
    def ask(t: str) {
        draft = t;
        if agentMin {
            set_agent_min(False);
            relayout();
        }
    }
    def drag_to(key: str, value: float) {
        lo = {"left": 220, "agent": 280, "rail": 150, "term": 120};
        hi = {"left": 600, "agent": 820, "rail": 440, "term": window.innerHeight * 0.72};
        size = clamp_size(value, lo[key], hi[key], key != "term");
        if key == "agent" {
            # dragging the agent shut minimizes it to the orb; its width is kept for when it returns
            if size == 0 {
                if not agentMin {
                    set_agent_min(True);
                    base = dragBase.current or 0.0;
                    if base >= 280 {
                        nxt0 = {**sizes};
                        nxt0["agent"] = base;
                        sizes = nxt0;
                    }
                }
                return;
            }
            if agentMin {
                set_agent_min(False);
            }
        }
        nxt = {**sizes};
        nxt[key] = size;
        sizes = nxt;
    }
    def reset_size(key: str) {
        nxt = {**sizes};
        nxt[key] = layout_default(key);
        sizes = nxt;
        relayout();
    }

    async def load_frame(bid: str) {
        f = await cached_frame(bid, aspect());
        if f["ok"] {
            frame = f;
            focusId = f["focus"]["id"];
            hovered = None;
        } else {
            error = String(f["error"]);
        }
    }

    async def enrich(path: str) {
        jevState = "Jev classifying...";
        try {
            s = await rpc("index_project", {"path": path, "use_jev": True});
            if s["ok"] {
                clear_cache();
                summary = s;
                await load_frame(focusId);
                jevState = "Jev roles";
            } else {
                jevState = "Jev failed";
            }
        } except Exception {
            jevState = "Jev failed";
        }
    }

    async def open_project(path: str) {
        loading = "Indexing " + path;
        error = "";
        try {
            s = await rpc("index_project", {"path": path, "use_jev": False});
            clear_cache();
            if not s["ok"] {
                error = String(s["error"]);
                loading = "";
                return;
            }
            summary = s;
            projectPath = s["project"];
            projectKey = s["project"] + "@" + str(Date.now());
            selected = None;
            selComp = "";
            archModel = None;
            touched = [];
            direction = "in";
            await load_frame(s["root_id"]);
            loading = "";
            if jevReady {
                enrich(projectPath);
            }
        } except Exception as e {
            error = String(e);
            loading = "";
        }
    }

    async can with entry {
        saved_theme = "midnight";
        try {
            saved_theme = localStorage.getItem("jac-smith.theme") or "midnight";
        } except Exception {}
        apply_theme(saved_theme);
        try {
            st = await rpc("get_settings", {});
            if not localStorage.getItem("jac-smith.theme") and st["theme"] {
                apply_theme(String(st["theme"]));
            }
            jevReady = st["jev_ready"];
            backend = String(st["agent_backend"]);
            path = await rpc("default_project", {});
            projectPath = String(path);
            await open_project(projectPath);
        } except Exception as e {
            error = "Could not reach the jac smith server: " + String(e);
        }
    }

    async def open_box(bid: str, dir: str) {
        direction = dir;
        selected = None;
        await load_frame(bid);
    }

    def go_up() {
        if frame is not None and len(frame.crumbs) > 1 {
            open_box(frame.crumbs[len(frame.crumbs) - 2].id, "out");
        }
    }

    useEffect(lambda {
        handler = lambda (e: any) {
            tag = String(e.target.tagName or "");
            cls = String(e.target.className or "");
            if e.key == "Escape" and view == "developer" and tag not in ["INPUT", "TEXTAREA"] and not cls.startswith("xterm") {
                if selected is not None {
                    selected = None;
                } else {
                    go_up();
                }
            }
        };
        window.addEventListener("keydown", handler);
        return lambda { window.removeEventListener("keydown", handler); };
    }, [frame, view, selected]);

    async def select_box(bid: str) {
        if not bid {
            selected = None;
            return;
        }
        if frame is not None {
            for c in frame.children {
                if c.info.id == bid {
                    selected = c.info;
                    return;
                }
            }
        }
        selected = await rpc("get_box", {"box_id": bid});
    }

    def hover_box(bid: str) {
        if not bid {
            hovered = None;
            return;
        }
        if frame is not None {
            for c in frame.children {
                if c.info.id == bid {
                    hovered = c.info;
                    prefetch(bid, c.info.kind, aspect());
                    return;
                }
            }
        }
    }

    async def navigate(bid: str) {
        b = await rpc("get_box", {"box_id": bid});
        if not b {
            return;
        }
        view = "developer";
        await open_box(bid, "in");
    }

    async def after_edit() {
        s = await rpc("index_project", {"path": projectPath, "use_jev": jevReady});
        clear_cache();
        if s["ok"] {
            summary = s;
        }
        await load_frame(focusId);
    }

    def on_settings_changed(st: SettingsStatus) {
        was = jevReady;
        jevReady = st.jev_ready;
        backend = st.agent_backend;
        if jevReady and not was and projectPath {
            enrich(projectPath);
        }
    }

    cur: BoxFrame = frame if frame is not None else BoxFrame(ok=False);
    crumbs: list[Crumb] = cur.crumbs;
    focus = cur.focus;
    focus_name = (focus.path or focus.name) if focus else "project";
    present = [c.info.role for c in cur.children];
    roles_here = [r for r in ROLE_ORDER if r in present];
    comp: ArchComponent | None = None;
    if archModel is not None and selComp {
        for c in archModel.components {
            if c.id == selComp {
                comp = c;
            }
        }
    }
    card_box = hovered if hovered is not None else (selected if selected is not None else focus);

    <div className="app">
        <header className="topbar">
            <button className={"icon-btn" + (" on" if sizes["left"] > 0 else "")} title={"Hide details panel" if sizes["left"] > 0 else "Show details panel"} onClick={lambda (e: MouseEvent) { toggle_left(); }}><PanelLeft size={16} /></button>
            <div className="brand"><span className="brand-mark" />jac smith</div>
            <div className="path-pill">
                <FolderOpen size={14} />
                <input value={projectPath} onChange={lambda (e: ChangeEvent) { projectPath = e.target.value; }} onKeyDown={lambda (e: KeyboardEvent) { if e.key == "Enter" { open_project(projectPath); } }} placeholder="/path/to/project" spellCheck={False} />
                <button className="chip-btn" onClick={lambda (e: MouseEvent) { open_project(projectPath); }}>Open</button>
            </div>
            <div className="switch">
                <span className="knob" style={{"transform": "translateX(" + ("0" if view == "developer" else ("112px" if view == "architecture" else "224px")) + ")"}} />
                <button className={"on" if view == "developer" else ""} onClick={lambda (e: MouseEvent) { view = "developer"; }}><Boxes size={14} />Developer</button>
                <button className={"on" if view == "architecture" else ""} onClick={lambda (e: MouseEvent) { view = "architecture"; }}><Workflow size={14} />Architecture</button>
                <button className={"on" if view == "history" else ""} onClick={lambda (e: MouseEvent) { view = "history"; }}><GitBranch size={14} />History</button>
            </div>
            <span className="spacer" />
            {summary and <span className="stat">{fmt_count(summary.modules) + " modules · " + fmt_count(summary.loc) + " loc · " + str(summary.externals) + " externals"}</span>}
            <span className={"pill " + ("busy" if jevState.startswith("Jev class") else ("ok" if jevReady else "warn"))} title="Jev decision model"><span className="dot" />{jevState or ("Jev ready" if jevReady else "Jev off")}</span>
            <button className={"icon-btn" + (" on" if showTerminal else "")} title="Terminal" onClick={lambda (e: MouseEvent) { showTerminal = not showTerminal; termEver = True; }}><TerminalIcon size={16} /></button>
            <button className="icon-btn" title="Settings" onClick={lambda (e: MouseEvent) { showSettings = True; }}><Settings2 size={16} /></button>
        </header>
        <div className="workspace">
            {sizes["left"] > 0 and <aside className="side" style={{"width": str(sizes["left"]) + "px"}}>
                {if view == "history" {
                    if commitDetail and commitDetail["ok"] {
                        <CommitCard detail={commitDetail} diffPath={diffPath} onDiff={lambda (pth: str) { diffPath = pth; }} onShowOnMap={show_on_map} onNavigate={lambda (bid: str) { navigate(bid); }} onAsk={ask} />
                    } else {
                        <ProjectCard title="History" text="main is the top line, newest on the right; branches hang below it, forking off and merging back. Hover a blob for a preview, click it to see what changed; click a file for its diff; Show on map lights up the boxes it touched." />
                    }
                } elif view == "architecture" {
                    if archModule is not None {
                        <BoxCard box={archModule} preview={False} onNavigate={lambda (bid: str) { navigate(bid); }} onAsk={ask} />
                    } elif comp is not None and archModel is not None {
                        <ComponentCard comp={comp} model={archModel} onOpenComponent={lambda (cid: str) { selComp = cid; }} onNavigate={lambda (bid: str) { navigate(bid); }} onAsk={ask} />
                    } elif archModel is not None and archModel.exists {
                        <ProjectCard title={archModel.title} text={archModel.summary + " Click a component to see what it is, which modules implement it, and how data flows through it. Double-click to open its parts."} />
                    } else {
                        <ProjectCard title="Architecture" text="The architecture view shows the system the code implements - stages, passes, services, stores - rather than its folders. Discover it once; jac smith keeps it in sync as files change." />
                    }
                } elif card_box is not None {
                    <BoxCard box={card_box} preview={hovered is not None} onNavigate={lambda (bid: str) { navigate(bid); }} onAsk={ask} />
                } else {
                    <ProjectCard title="jac smith" text="Open a project to see its architecture." />
                }}
            </aside>}
            <Sash axis="x" onStart={lambda { start_drag("left"); }} onDrag={lambda (d: float) { drag_to("left", dragBase.current + d); }} onEnd={relayout} onReset={lambda { reset_size("left"); }} />
            <main className="stage">
                {if view == "developer" {
                    <nav className="crumbs">
                        {for (i, c) in enumerate(crumbs) {
                            if i > 0 {
                                <span key={"s" + c.id} className="crumb-sep"><ChevronRight size={13} /></span>
                            }
                            <button key={c.id} className={"crumb" + (" last" if i == len(crumbs) - 1 else "")} onClick={lambda (e: MouseEvent) { open_box(c.id, "out"); }}>{c.name}</button>
                        }}
                        <div className="legend">
                            {for r in roles_here {
                                <span key={r} className="legend-item"><span className="swatch" style={{"background": "rgb(" + role_rgb(r) + ")", "boxShadow": "0 0 8px rgba(" + role_rgb(r) + ",.8)"}} />{r.lower()}</span>
                            }}
                        </div>
                    </nav>
                }}
                <div className="view">
                    {if error {
                        <div className="empty"><h2>Something went wrong</h2><p>{error}</p></div>
                    } elif loading and frame is None {
                        <div className="empty"><h2 className="shimmer-text">Reading the architecture</h2><p>{loading}</p></div>
                    } elif frame is None {
                        <div className="empty"><h2>Open a project</h2><p>Type a folder path above and press Enter.</p></div>
                    } elif view == "history" {
                        <TimelineView projectKey={projectKey} selected={histCommit} diffPath={diffPath} onSelect={lambda (sha: str) { select_commit(sha); }} onCloseDiff={lambda { diffPath = ""; }} />
                    } elif view == "developer" {
                        <BoxView frame={cur} selectedId={selected.id if selected else ""} touched={touched} direction={direction} onSelect={lambda (bid: str) { select_box(bid); }} onOpen={lambda (bid: str) { open_box(bid, "in"); }} onHover={hover_box} onCodeSelection={lambda (f: str, a: int, b: int, t: str) { codeSel = {"file": f, "start": a, "end": b, "text": t}; }} onFileSaved={lambda { after_edit(); }} railWidth={sizes["rail"]} onRailToggle={toggle_rail} railSash={<Sash axis="x" onStart={lambda { start_drag("rail"); }} onDrag={lambda (d: float) { drag_to("rail", dragBase.current - d); }} onEnd={relayout} onReset={lambda { reset_size("rail"); }} />} />
                    } else {
                        <ArchView projectKey={projectKey} onModel={lambda (m: ArchModel) { archModel = m; }} onSelectComp={lambda (cid: str) { selComp = cid; archModule = None; }} onSelectModule={lambda (mid: str) { select_arch_module(mid); }} onOpenModule={lambda (mid: str) { archModule = None; navigate(mid); }} />
                    }}
                    {loading and frame and <div className="toast"><LoaderCircle size={13} className="spin" />{loading}</div>}
                </div>
                {termEver and <div className="term-wrap" style={{"display": "flex" if showTerminal else "none"}}>
                    <Sash axis="y" onStart={lambda { start_drag("term"); }} onDrag={lambda (d: float) { drag_to("term", dragBase.current - d); }} onEnd={relayout} onReset={lambda { reset_size("term"); }} />
                    <TerminalPanel cwd={projectPath} height={sizes["term"]} onClose={lambda { showTerminal = False; }} />
                </div>}
            </main>
            <Sash axis="x" onStart={lambda { start_drag("agent"); }} onDrag={lambda (d: float) { drag_to("agent", dragBase.current - d); }} onEnd={relayout} onReset={lambda { reset_size("agent"); }} />
            {<AgentPanel selection={codeSel} onClearSelection={lambda { codeSel = None; }} width={sizes["agent"]} hidden={agentMin} onMinimize={lambda { set_agent_min(True); relayout(); }} onActivity={lambda (b: bool, replied: bool) { agentBusy = b; if replied and agentMin { agentUnread = True; } }} focusId={focusId} focusName={focus_name} backend={backend} draft={draft} onTouched={lambda (ids: list[str]) { touched = ids; }} onEdited={lambda { after_edit(); }} onNavigate={lambda (bid: str) { navigate(bid); }} />}
        </div>
        {agentMin and <AgentBlob focusName={focus_name} busy={agentBusy} unread={agentUnread} onOpen={lambda { set_agent_min(False); relayout(); }} />}
        {showSettings and <SettingsPanel onClose={lambda { showSettings = False; }} onChanged={on_settings_changed} />}
    </div>
}
