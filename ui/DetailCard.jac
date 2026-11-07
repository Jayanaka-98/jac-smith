"""The card on the left: everything about the box (or architecture component) you are pointing at."""
import from "lucide-react" { Sparkles, CodeXml, ArrowUpLeft, Layers, Workflow, GitCommitHorizontal, MapPin, FileDiff }
import from ..indexer.model { BoxInfo, SymbolInfo }
import from ..architect.model { ArchModel, ArchComponent, ArchFlow, ModuleArch }
import from .theme { role_rgb, fmt_count, eco_label }
import from .rpc { rpc }

glob _NL: str = chr(10);

def:pub card_glow(rgb: str) -> dict[str, str] {
    return {"background": "radial-gradient(120% 90% at 10% -10%, rgba(" + rgb + ",.28), transparent 60%)"};
}

def:pub BoxCard(
    box: BoxInfo,
    preview: bool,
    onNavigate: Callable[[str], None],
    onAsk: Callable[[str], None]
) -> JsxElement {
    has source: str = "";
    has showCode: bool = False;
    has part: ModuleArch | None = None;
    has codeTokens: list[list[str]] = [];
    has snipTokens: list[list[str]] = [];

    async can with [box.id] entry {
        showCode = False;
        source = "";
        part = None;
        codeTokens = [];
        snipTokens = [];
        module_id = box.parent if box.kind == "symbol" else box.id;
        if box.kind == "symbol" and len(box.symbols) > 0 {
            snipTokens = await rpc("read_source_tokens", {"box_id": module_id, "start": box.symbols[0].line, "count": min(max(box.loc, 4), 80)});
        }
        if box.kind in ["module", "symbol"] {
            try {
                part = await rpc("arch_of_module", {"module": module_id});
            } except Exception {}
        }
    }

    async def toggle_code() {
        if not showCode and len(codeTokens) == 0 {
            codeTokens = await rpc("read_source_tokens", {"box_id": box.id, "start": 1, "count": 0});
        }
        showCode = not showCode;
    }

    rgb = role_rgb(box.role);
    publics = [s for s in box.symbols if s.public];
    kind_label = {"project": "Project", "package": "Package", "module": "Module", "symbol": "Declaration"};

    <div className="card">
        <div className="card-glow" style={card_glow(rgb)} />
        <div key={box.id} className="card-inner">
            <div>
                <div className="card-kicker">
                    <span className="role-dot" style={{"--rgb": rgb}} />
                    {(box.role.lower() + " · " if box.role else "") + (kind_label[box.kind] if box.kind in kind_label else box.kind)}
                    {preview and <span style={{"marginLeft": "auto", "color": "var(--faint)"}}>hover</span>}
                </div>
                <div className="card-title" style={{"marginTop": "6px"}}>{box.name}</div>
                {box.path and <div className="card-path">{box.path}</div>}
            </div>
            {if part and part.component {
                <div className="part-of">
                    <div className="part-of-top"><Workflow size={13} /><span>{"Part of "}<b>{(part.parent_name + " › " if part.parent_name else "") + part.component_name}</b></span></div>
                    <div className="bar"><i style={{"width": str(round(part.confidence * 100)) + "%"}} /></div>
                    <div className="note" style={{"marginTop": 0, "fontSize": "11px"}}>{"mapped by " + ("Jev" if part.source == "jev" else part.source) + " · " + str(round(part.confidence * 100)) + "% confident"}</div>
                </div>
            }}
            {if box.kind == "symbol" {
                <div className="card-text mono" style={{"fontSize": "11.5px"}}>{box.summary}</div>
            } elif box.summary {
                <div className="card-text">{box.summary}</div>
            }}
            <div className="stats">
                <div className="stat-tile"><b>{fmt_count(box.loc)}</b><span>{"lines" if box.kind == "symbol" else "lines of code"}</span></div>
                {if box.kind in ["package", "project"] {
                    <div className="stat-tile"><b>{fmt_count(box.files)}</b><span>files</span></div>
                } else {
                    <div className="stat-tile"><b>{str(len(publics))}</b><span>public declarations</span></div>
                }}
                {if box.kind in ["package", "project"] {
                    <div className="stat-tile"><b>{str(len(box.children))}</b><span>boxes inside</span></div>
                } else {
                    <div className="stat-tile"><b>{str(box.fan_in)}</b><span>modules use it</span></div>
                }}
                {if box.kind in ["package", "project"] {
                    <div className="stat-tile"><b>{str(len(box.externals))}</b><span>outside deps</span></div>
                } else {
                    <div className="stat-tile"><b>{str(len(box.depends_on))}</b><span>project deps</span></div>
                }}
            </div>
            {if len(snipTokens) > 0 {
                <pre className="code-block">{for (i, tk) in enumerate(snipTokens) { <span key={"s" + str(i)} className={"tk-" + tk[0]}>{tk[1]}</span> }}</pre>
            }}
            {if box.kind == "module" and len(publics) > 0 and not showCode {
                <div className="sec">
                    <h5>Interfaces</h5>
                    <div className="list">
                        {for s in publics[:18] {
                            <div key={s.name + str(s.line)} className="list-row" title={s.signature}><span className="k">{s.kind}</span><span>{s.name}</span></div>
                        }}
                    </div>
                </div>
            }}
            {if showCode {
                <pre className="code-block">{for (i, tk) in enumerate(codeTokens) { <span key={"c" + str(i)} className={"tk-" + tk[0]}>{tk[1]}</span> }}</pre>
            }}
            {if len(box.depends_on) > 0 {
                <div className="sec">
                    <h5>Depends on</h5>
                    <div className="list">
                        {for d in box.depends_on[:14] {
                            <button key={d} className="list-row" onClick={lambda (e: MouseEvent) { onNavigate(d); }}><span className="k">{"→"}</span><span>{d}</span></button>
                        }}
                    </div>
                </div>
            }}
            {if len(box.externals) > 0 {
                <div className="sec">
                    <h5>Uses outside code</h5>
                    <div className="chips">
                        {for x in box.externals[:24] {
                            <span key={x} className="chip dashed">{x.replace("ext:", "").split(":")[1] if ":" in x.replace("ext:", "") else x}</span>
                        }}
                    </div>
                </div>
            }}
            <div className="actions">
                <button className="btn-grad" onClick={lambda (e: MouseEvent) { onAsk("Explain " + (box.path or box.name) + ": what it is responsible for, how it is wired to the rest, and anything risky."); }}><Sparkles size={13} />Ask agent</button>
                {box.kind == "module" and <button className="chip-btn" onClick={lambda (e: MouseEvent) { toggle_code(); }}><CodeXml size={13} />{"Hide code" if showCode else "View code"}</button>}
            </div>
        </div>
    </div>
}

def:pub ComponentCard(
    comp: ArchComponent,
    model: ArchModel,
    onOpenComponent: Callable[[str], None],
    onNavigate: Callable[[str], None],
    onAsk: Callable[[str], None]
) -> JsxElement {
    names: dict[str, str] = {};
    for c in model.components {
        names[c.id] = c.name;
    }
    incoming = [f for f in model.flows if f.dst == comp.id];
    outgoing = [f for f in model.flows if f.src == comp.id];
    kids = [c for c in model.components if c.parent == comp.id];
    drift = [d for d in model.drift if comp.name in d];

    <div className="card">
        <div className="card-glow" style={card_glow("167,139,250")} />
        <div key={comp.id} className="card-inner">
            <div>
                <div className="card-kicker"><Layers size={12} />{comp.kind + (" · stage " + str(comp.order) if comp.order > 0 else "")}</div>
                <div className="card-title" style={{"marginTop": "6px"}}>{comp.name}</div>
                {comp.parent and <div className="card-path">{"inside " + (names[comp.parent] if comp.parent in names else comp.parent)}</div>}
            </div>
            <div className="card-text">{comp.summary}</div>
            <div className="stats">
                <div className="stat-tile"><b>{fmt_count(comp.module_count)}</b><span>modules</span></div>
                <div className="stat-tile"><b>{fmt_count(comp.loc)}</b><span>lines of code</span></div>
                <div className="stat-tile"><b>{str(comp.jev_mapped)}</b><span>mapped by Jev</span></div>
                <div className="stat-tile"><b>{str(round(comp.confidence * 100)) + "%"}</b><span>mean confidence</span></div>
            </div>
            {if len(kids) > 0 {
                <div className="sec">
                    <h5>{"Inside (" + str(len(kids)) + ")"}</h5>
                    <div className="list">
                        {for k in kids {
                            <button key={k.id} className="list-row" onClick={lambda (e: MouseEvent) { onOpenComponent(comp.id); }}><span className="k">{k.kind}</span><span>{k.name}</span></button>
                        }}
                    </div>
                </div>
            }}
            {if len(incoming) + len(outgoing) > 0 {
                <div className="sec">
                    <h5>Flows</h5>
                    <div className="list">
                        {for f in incoming[:10] {
                            <div key={"in" + f.src} className="list-row"><span className="k">{"←"}</span><span>{(names[f.src] if f.src in names else f.src) + (": " + f.label if f.label else ("  (" + str(f.observed) + " imports, undeclared)" if not f.declared else ""))}</span></div>
                        }}
                        {for f in outgoing[:10] {
                            <div key={"out" + f.dst} className="list-row"><span className="k">{"→"}</span><span>{(names[f.dst] if f.dst in names else f.dst) + (": " + f.label if f.label else ("  (" + str(f.observed) + " imports, undeclared)" if not f.declared else ""))}</span></div>
                        }}
                    </div>
                </div>
            }}
            {if len(comp.paths) > 0 {
                <div className="sec">
                    <h5>Implemented in</h5>
                    <div className="chips">
                        {for p in comp.paths[:12] {
                            <button key={p} className="chip" onClick={lambda (e: MouseEvent) { onNavigate(p); }}>{p}</button>
                        }}
                    </div>
                </div>
            }}
            {if len(comp.top_modules) > 0 {
                <div className="sec">
                    <h5>Key modules</h5>
                    <div className="list">
                        {for m in comp.top_modules[:10] {
                            <button key={m} className="list-row" onClick={lambda (e: MouseEvent) { onNavigate(m); }}><span className="k"><ArrowUpLeft size={11} /></span><span>{m}</span></button>
                        }}
                    </div>
                </div>
            }}
            {if len(drift) > 0 {
                <div className="sec">
                    <h5>Drift</h5>
                    {for d in drift {
                        <div key={d} className="note" style={{"marginTop": 0, "color": "#fca5a5"}}>{d}</div>
                    }}
                </div>
            }}
            <div className="actions">
                <button className="btn-grad" onClick={lambda (e: MouseEvent) { onAsk("Walk me through the " + comp.name + " component of the architecture: its responsibilities, its key modules, and how data flows in and out of it."); }}><Sparkles size={13} />Ask agent</button>
                {len(kids) > 0 and <button className="chip-btn" onClick={lambda (e: MouseEvent) { onOpenComponent(comp.id); }}><Layers size={13} />Open parts</button>}
            </div>
        </div>
    </div>
}

def:pub ProjectCard(title: str, text: str) -> JsxElement {
    <div className="card">
        <div className="card-glow" style={card_glow("110,168,255")} />
        <div className="empty-card">
            <div className="card-kicker">jac smith</div>
            <div className="card-title" style={{"color": "var(--text)"}}>{title}</div>
            <div>{text}</div>
        </div>
    </div>
}

def:pub CommitCard(
    detail: any,
    diffPath: str,
    onDiff: Callable[[str], None],
    onShowOnMap: Callable[[list[str]], None],
    onNavigate: Callable[[str], None],
    onAsk: Callable[[str], None]
) -> JsxElement {
    lines = String(detail["message"] or "").split(chr(10));
    subject = lines[0] if lines else "";
    body = chr(10).join(lines[1:]).strip();
    files: list[any] = detail["files"] or [];
    added = sum([int(f["added"]) for f in files]);
    deleted = sum([int(f["deleted"]) for f in files]);
    in_project = [f["box_id"] for f in files if f["box_id"]];
    <div className="card">
        <div className="card-glow" style={card_glow("110,168,255")} />
        <div key={detail["hash"]} className="card-inner">
            <div>
                <div className="card-kicker"><GitCommitHorizontal size={13} />{"commit " + String(detail["hash"])[:10]}</div>
                <div className="card-title" style={{"marginTop": "6px", "fontSize": "16px"}}>{subject}</div>
                <div className="card-path">{detail["author"] + " · " + String(detail["date"]).replace("T", " ")[:16]}</div>
            </div>
            {len(detail["refs"]) > 0 and <div className="chips">
                {for r in detail["refs"] {
                    <span key={r} className="chip">{r}</span>
                }}
            </div>}
            {body and <div className="card-text" style={{"whiteSpace": "pre-wrap", "fontSize": "12px"}}>{body}</div>}
            <div className="stats">
                <div className="stat-tile"><b>{str(len(files))}</b><span>files changed</span></div>
                <div className="stat-tile"><b><span style={{"color": "var(--ok)"}}>{"+" + str(added)}</span>{" "}<span style={{"color": "var(--bad)"}}>{"−" + str(deleted)}</span></b><span>lines</span></div>
            </div>
            {len(detail["parents"]) > 1 and <div className="note" style={{"marginTop": 0}}>{"Merge of " + ", ".join([x[:7] for x in detail["parents"]])}</div>}
            <div className="sec">
                <h5>Changed files</h5>
                <div className="list">
                    {for f in files[:200] {
                        <div key={f["path"]} className={"commit-file" + (" on" if f["path"] == diffPath else "")}>
                            <span className={"fstatus s" + f["status"]}>{f["status"]}</span>
                            <button className="commit-file-path" onClick={lambda (e: MouseEvent) { onDiff(f["path"]); }} title="Show diff">{f["path"]}</button>
                            <span className="fnum"><span className="a">{"+" + str(f["added"])}</span>{" "}<span className="d">{"−" + str(f["deleted"])}</span></span>
                            {f["box_id"] and <button className="icon-btn tiny" title="Open in the code map" onClick={lambda (e: MouseEvent) { onNavigate(f["box_id"]); }}><ArrowUpLeft size={11} /></button>}
                        </div>
                    }}
                </div>
            </div>
            <div className="actions">
                {len(in_project) > 0 and <button className="btn-grad" onClick={lambda (e: MouseEvent) { onShowOnMap(in_project + detail["boxes"]); }}><MapPin size={13} />Show on map</button>}
                <button className="chip-btn" onClick={lambda (e: MouseEvent) { onAsk("Explain commit " + String(detail["hash"])[:10] + " (" + subject + "): what changed architecturally and what it affects."); }}><Sparkles size={13} />Ask agent</button>
            </div>
        </div>
    </div>
}

