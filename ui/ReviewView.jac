"""Review view: open pull requests on the left, and for the selected one, what it changes - the
architecture components it touches (sized by churn), how far the change reaches through imports,
and every file grouped by component, each opening its diff."""
import from "lucide-react" { GitPullRequest, RefreshCw, X, Search, Waypoints, FileDiff, ArrowUpLeft, CircleDot, FilePlus2 }
import from .rpc { rpc }

def:pub review_badge(pr: any) -> str {
    if pr["draft"] {
        return "draft";
    }
    return pr["review"] or "";
}

def:pub ReviewDiff(prRef: str, path: str, onClose: Callable[[], None]) -> JsxElement {
    has text: str = "";
    has loading: bool = True;
    async can with [prRef, path] entry {
        loading = True;
        text = String(await rpc("review_diff", {"ref": prRef, "path": path}));
        loading = False;
    }
    lines = text.split(chr(10)) if text else [];
    <aside className="hist-diff">
        <div className="cv-head">
            <span className="cv-path">{path}</span>
            <span className="stat mono">{("#" + prRef) if prRef.isdigit() else prRef}</span>
            <button className="icon-btn" onClick={lambda (e: MouseEvent) { onClose(); }}><X size={14} /></button>
        </div>
        <div className="hist-diff-body">
            {if loading {
                <div className="cv-loading shimmer-text">Loading diff...</div>
            } elif len(lines) == 0 or (len(lines) == 1 and not lines[0]) {
                <div className="cv-loading">No textual diff for this file.</div>
            }}
            {for (i, l) in enumerate(lines) {
                <div key={str(i)} className={"hd-line " + ("add" if l.startswith("+") and not l.startswith("+++") else ("del" if l.startswith("-") and not l.startswith("---") else ("hunk" if l.startswith("@@") else ("meta" if l.startswith("diff ") or l.startswith("index ") or l.startswith("+++") or l.startswith("---") or l.startswith("new file") or l.startswith("deleted file") else ""))))}>{l or " "}</div>
            }}
        </div>
    </aside>
}

def:pub ReviewView(
    projectKey: str,
    selected: str,
    detail: any,
    diffPath: str,
    onSelect: Callable[[str], None],
    onDiff: Callable[[str], None],
    onNavigate: Callable[[str], None]
) -> JsxElement {
    has listing: any = None;
    has loading: bool = True;
    has query: str = "";
    has compFilter: str = "";

    async def load() {
        loading = True;
        listing = await rpc("review_prs", {"limit": 80});
        loading = False;
        if listing and listing["ok"] and len(listing["prs"]) > 0 and not selected {
            onSelect(listing["prs"][0]["ref"]);
        }
    }
    async can with [projectKey] entry {
        await load();
    }
    async can with [selected] entry {
        compFilter = "";
    }

    prs: list[any] = listing["prs"] if listing and listing["ok"] else [];
    q = query.lower().strip();
    shown = [p for p in prs if not q or q in p["title"].lower() or q in p["author"].lower() or q in p["branch"].lower() or q in p["ref"]];
    ok_detail = detail is not None and detail["ok"] and detail["summary"] is not None and detail["summary"]["ref"] == selected;
    comps: list[any] = detail["components"] if ok_detail else [];
    files: list[any] = detail["files"] if ok_detail else [];
    churn_max = max([c["added"] + c["deleted"] for c in comps] + [1]);
    file_max = max([f["added"] + f["deleted"] for f in files] + [1]);
    visible = [f for f in files if not compFilter or f["component"] == compFilter];
    comp_names = {c["id"]: c["name"] for c in comps};

    <div className="historyview reviewview">
        <div className={"rv-list" + (" folded" if ok_detail and diffPath else "")}>
            <div className="hist-head">
                <GitPullRequest size={15} />
                <span className="hist-title">{"Pull requests" if not listing or listing["source"] != "local" else "Branches"}</span>
                {listing and listing["ok"] and <span className="stat mono">{str(len(prs)) + " open"}</span>}
                <span className="spacer" />
                <button className="icon-btn" title="Refresh" onClick={lambda (e: MouseEvent) { load(); }}><RefreshCw size={14} className={"spin" if loading else ""} /></button>
            </div>
            <div className="rv-search">
                <Search size={13} />
                <input value={query} placeholder="Filter by title, author, branch, #" spellCheck={False} onChange={lambda (e: ChangeEvent) { query = e.target.value; }} />
            </div>
            {listing and listing["ok"] and listing["note"] and <div className="rv-note">{listing["note"]}</div>}
            <div className="rv-items">
                {if listing and not listing["ok"] {
                    <div className="rv-empty">{listing["error"]}</div>
                } elif listing and len(prs) == 0 {
                    <div className="rv-empty">Nothing open. Every branch is merged.</div>
                } elif not listing {
                    <div className="rv-empty shimmer-text">Fetching pull requests...</div>
                }}
                {for p in shown {
                    <button key={p["ref"]} className={"rv-item" + (" sel" if p["ref"] == selected else "")} onClick={lambda (e: MouseEvent) { onSelect(p["ref"]); }}>
                        <div className="rv-item-top">
                            {p["number"] > 0 and <span className="rv-num">{"#" + str(p["number"])}</span>}
                            <span className="rv-title">{p["title"]}</span>
                        </div>
                        <div className="rv-item-meta">
                            <span>{p["author"]}</span>
                            <span className="faint">{p["rel"]}</span>
                            {review_badge(p) and <span className={"rv-badge " + review_badge(p)}>{review_badge(p)}</span>}
                            <span className="spacer" />
                            <span className="fnum"><span className="a">{"+" + str(p["additions"])}</span>{" "}<span className="d">{"−" + str(p["deletions"])}</span></span>
                        </div>
                    </button>
                }}
            </div>
        </div>
        <div className="hist-main rv-impact">
            {if not selected {
                <div className="empty"><h2>Pick a pull request</h2><p>See which parts of the system it changes and how far the change reaches.</p></div>
            } elif detail is not None and not detail["ok"] {
                <div className="empty"><h2>Could not read this one</h2><p>{detail["error"]}</p></div>
            } elif not ok_detail {
                <div className="empty"><h2 className="shimmer-text">Mapping the change</h2><p>Reading files, placing them in the architecture...</p></div>
            } else {
                <div className="rv-scroll">
                    <div className="rv-head">
                        <div className="rv-head-title">{detail["summary"]["title"]}</div>
                        <div className="rv-head-meta mono">
                            {(("#" + str(detail["summary"]["number"]) + " · ") if detail["summary"]["number"] > 0 else "") + detail["summary"]["branch"] + " → " + detail["summary"]["base"]}
                        </div>
                    </div>
                    <div className="rv-metrics">
                        <div className="stat-tile"><b>{str(len(files))}</b><span>files</span></div>
                        <div className="stat-tile"><b>{str(len(comps))}</b><span>components</span></div>
                        <div className="stat-tile"><b>{str(len(detail["boxes"]))}</b><span>top-level boxes</span></div>
                        <div className="stat-tile" title="Modules outside the PR that import a module it changes"><b>{str(detail["dependents"])}</b><span>dependent modules</span></div>
                    </div>
                    <div className="rv-section">
                        <h5><Waypoints size={13} />Where it lands in the architecture</h5>
                        {if len(comps) == 0 {
                            <div className="rv-empty small">{("All changes are outside this project folder." if detail["outside"] >= len(files) else ("None of these files belong to an architecture component - tests, docs, tooling or config only." if detail["arch_mapped"] else "No architecture mapped yet - discover it in the Architecture view to see components here."))}</div>
                        }}
                        <div className="rv-comps">
                            {for c in comps {
                                <button key={c["id"]} className={"rv-comp" + (" on" if compFilter == c["id"] else "")} onClick={lambda (e: MouseEvent) { compFilter = "" if compFilter == c["id"] else c["id"]; }}>
                                    <span className="rv-comp-bar" style={{"width": str(max(4, 100 * (c["added"] + c["deleted"]) / churn_max)) + "%"}} />
                                    <span className="rv-comp-name">{c["name"]}{c["parent_name"] and <span className="faint">{" · " + c["parent_name"]}</span>}</span>
                                    <span className="rv-comp-n">{str(c["files"]) + " file" + ("s" if c["files"] != 1 else "")}</span>
                                    <span className="fnum"><span className="a">{"+" + str(c["added"])}</span>{" "}<span className="d">{"−" + str(c["deleted"])}</span></span>
                                </button>
                            }}
                        </div>
                    </div>
                    {detail["dependents"] > 0 and <div className="rv-section">
                        <h5><CircleDot size={13} />{"Reaches " + str(detail["dependents"]) + " module" + ("s" if detail["dependents"] != 1 else "") + " through imports"}</h5>
                        <div className="chips">
                            {for m in detail["dependent_sample"] {
                                <button key={m} className="chip clickable" title="Open in the code map" onClick={lambda (e: MouseEvent) { onNavigate(m); }}>{m}</button>
                            }}
                            {detail["dependents"] > len(detail["dependent_sample"]) and <span className="chip faint">{"+" + str(detail["dependents"] - len(detail["dependent_sample"])) + " more"}</span>}
                        </div>
                    </div>}
                    <div className="rv-section">
                        <h5><FileDiff size={13} />{("Files in " + comp_names[compFilter]) if compFilter else "Files"}{compFilter and <button className="link-btn" onClick={lambda (e: MouseEvent) { compFilter = ""; }}>show all</button>}</h5>
                        <div className="list">
                            {for f in visible[:400] {
                                <div key={f["path"]} className={"commit-file rv-file" + (" on" if f["path"] == diffPath else "")}>
                                    <span className="rv-file-bar"><span style={{"width": str(max(3, 100 * (f["added"] + f["deleted"]) / file_max)) + "%"}} /></span>
                                    {f["is_new"] and <FilePlus2 size={12} className="rv-new" />}
                                    <button className="commit-file-path" onClick={lambda (e: MouseEvent) { onDiff(f["path"]); }} title="Show diff">{f["path"]}</button>
                                    {f["component"] and not compFilter and <span className="rv-file-comp">{comp_names[f["component"]] if f["component"] in comp_names else ""}</span>}
                                    <span className="fnum"><span className="a">{"+" + str(f["added"])}</span>{" "}<span className="d">{"−" + str(f["deleted"])}</span></span>
                                    {f["box_id"] and <button className="icon-btn tiny" title="Open in the code map" onClick={lambda (e: MouseEvent) { onNavigate(f["box_id"]); }}><ArrowUpLeft size={11} /></button>}
                                </div>
                            }}
                        </div>
                    </div>
                </div>
            }}
        </div>
        {if ok_detail and diffPath {
            <ReviewDiff prRef={selected} path={diffPath} onClose={lambda { onDiff(""); }} />
        }}
    </div>
}
