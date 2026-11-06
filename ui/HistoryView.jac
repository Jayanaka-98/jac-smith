"""History view: the git graph - lanes, merges, refs - with a diff panel for the selected file."""
import from "lucide-react" { GitBranch, GitCommitHorizontal, X, FolderGit2, RefreshCw }
import from .rpc { rpc }

glob ROW: int = 30;
glob LANE: int = 16;
glob LANE_COLORS: list[str] = ["#a78bfa", "#6ea8ff", "#f472b6", "#34d399", "#fbbf24", "#40d4e2", "#fb7185", "#a3e635"];

def:pub lane_color(i: int) -> str {
    return LANE_COLORS[i % len(LANE_COLORS)];
}

def:pub lx(i: int) -> float {
    return 12 + i * LANE;
}

def:pub ly(r: int) -> float {
    return r * ROW + ROW / 2;
}

def:pub seg_path(x1: float, y1: float, x2: float, y2: float) -> str {
    if x1 == x2 {
        return "M " + str(x1) + " " + str(y1) + " L " + str(x2) + " " + str(y2);
    }
    my = (y1 + y2) / 2;
    return "M " + str(x1) + " " + str(y1) + " C " + str(x1) + " " + str(my) + ", " + str(x2) + " " + str(my) + ", " + str(x2) + " " + str(y2);
}

def:pub ref_kind(r: str) -> str {
    if r.startswith("tag:") {
        return "tag";
    }
    if r.startswith("HEAD") {
        return "head";
    }
    if "/" in r {
        return "remote";
    }
    return "branch";
}

def:pub CommitDiff(sha: str, path: str, onClose: Callable[[], None]) -> JsxElement {
    has text: str = "";
    has loading: bool = True;
    async can with [sha, path] entry {
        loading = True;
        text = String(await rpc("git_file_diff", {"sha": sha, "path": path}));
        loading = False;
    }
    lines = text.split(chr(10)) if text else [];
    <aside className="hist-diff">
        <div className="cv-head">
            <span className="cv-path">{path}</span>
            <span className="stat mono">{sha[:7]}</span>
            <button className="icon-btn" onClick={lambda (e: MouseEvent) { onClose(); }}><X size={14} /></button>
        </div>
        <div className="hist-diff-body">
            {if loading {
                <div className="cv-loading shimmer-text">Loading diff...</div>
            }}
            {for (i, l) in enumerate(lines) {
                <div key={str(i)} className={"hd-line " + ("add" if l.startswith("+") and not l.startswith("+++") else ("del" if l.startswith("-") and not l.startswith("---") else ("hunk" if l.startswith("@@") else ("meta" if l.startswith("diff ") or l.startswith("index ") or l.startswith("+++") or l.startswith("---") else ""))))}>{l or " "}</div>
            }}
        </div>
    </aside>
}

def:pub HistoryView(
    projectKey: str,
    selected: str,
    diffPath: str,
    onSelect: Callable[[str], None],
    onCloseDiff: Callable[[], None]
) -> JsxElement {
    has log: any = None;
    has loading: bool = True;
    has limit: int = 400;
    has scoped: bool = False;

    async def load() {
        loading = True;
        log = await rpc("git_log", {"limit": limit, "offset": 0, "scoped": scoped});
        loading = False;
    }
    async can with [projectKey, limit, scoped] entry {
        await load();
    }

    commits: list[any] = log["commits"] if log and log["ok"] else [];
    lanes = min(int(log["lanes"]) if log and log["ok"] else 1, 14);
    gw = lx(lanes) + 8;
    h = len(commits) * ROW;

    <div className="historyview">
        <div className="hist-main">
            <div className="hist-head">
                <GitBranch size={15} />
                <span className="hist-title">{log["branch"] if log and log["ok"] and log["branch"] else "History"}</span>
                {log and log["ok"] and <span className="stat mono">{"HEAD " + log["head"] + " · " + str(len(commits)) + " commits" + (" +" if log["more"] else "")}</span>}
                <span className="spacer" />
                <label className="check"><input type="checkbox" checked={scoped} onChange={lambda (e: ChangeEvent) { scoped = e.target.checked; }} /><FolderGit2 size={13} />only this folder</label>
                <button className="icon-btn" title="Refresh" onClick={lambda (e: MouseEvent) { load(); }}><RefreshCw size={14} /></button>
            </div>
            {if log and not log["ok"] {
                <div className="empty"><h2>No history</h2><p>{log["error"]}</p></div>
            } elif log and log["ok"] and len(commits) == 0 {
                <div className="empty"><h2>No commits yet</h2><p>{log["error"] or "Commit something to see the graph."}</p></div>
            } else {
                <div className="hist-scroll">
                    <div className="hist-rows" style={{"height": str(h) + "px", "--gw": str(gw) + "px"}}>
                        <svg className="hist-graph" width={gw} height={h}>
                            {for (r, c) in enumerate(commits) {
                                for (k, s) in enumerate(c["incoming"]) {
                                    if r > 0 and s["a"] < 14 and s["b"] < 14 {
                                        <path key={"i" + str(r) + "_" + str(k)} d={seg_path(lx(s["a"]), ly(r - 1), lx(s["b"]), ly(r))} stroke={lane_color(s["lane"])} />
                                    }
                                }
                                for (k, s) in enumerate(c["outgoing"]) {
                                    if r + 1 < len(commits) and s["b"] < 14 {
                                        <path key={"o" + str(r) + "_" + str(k)} d={seg_path(lx(c["col"]), ly(r), lx(s["b"]), ly(r + 1))} stroke={lane_color(s["lane"])} />
                                    }
                                }
                            }}
                            {for (r, c) in enumerate(commits) {
                                if c["col"] < 14 {
                                    <circle key={"n" + str(r)} cx={lx(c["col"])} cy={ly(r)} r={5 if len(c["parents"]) > 1 else 4} fill={"#0b0d13" if len(c["parents"]) > 1 else lane_color(c["col"])} stroke={lane_color(c["col"])} strokeWidth="2" className={"hist-dot" + (" sel" if c["hash"] == selected else "")} />
                                }
                            }}
                        </svg>
                        {for (r, c) in enumerate(commits) {
                            <div key={c["hash"]} className={"hist-row" + (" sel" if c["hash"] == selected else "")} style={{"top": str(r * ROW) + "px"}} onClick={lambda (e: MouseEvent) { onSelect(c["hash"]); }}>
                                <span className="hist-subject">
                                    {for ref in c["refs"] {
                                        <span key={ref} className={"ref " + ref_kind(ref)}>{ref.replace("tag: ", "")}</span>
                                    }}
                                    {c["subject"]}
                                </span>
                                <span className="hist-author">{c["author"]}</span>
                                <span className="hist-date">{c["rel"]}</span>
                                <span className="hist-hash">{c["short"]}</span>
                            </div>
                        }}
                    </div>
                    {log and log["more"] and <div className="hist-more"><button className="chip-btn" onClick={lambda (e: MouseEvent) { limit = limit + 400; }}>{"Load 400 more"}</button></div>}
                </div>
            }}
            {loading and <div className="toast"><GitCommitHorizontal size={13} />Reading history...</div>}
        </div>
        {if selected and diffPath {
            <CommitDiff sha={selected} path={diffPath} onClose={onCloseDiff} />
        }}
    </div>
}
