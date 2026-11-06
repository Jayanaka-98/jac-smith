"""Architecture view: the project's domain architecture, discovered and maintained by agents.

Nodes are components (a compiler's stages, the passes inside a stage, a web app's services...),
edges are what flows between them. Declared flows come from the architect agent; red dashed
edges are imports the architecture does not declare (drift). Double-click to open a component.
"""
import from "react" { useMemo, useEffect }
import from "@xyflow/react" { ReactFlow, Background, Controls, MiniMap, MarkerType }
import from "@dagrejs/dagre" { graphlib, layout }
import from "lucide-react" { Sparkles, RefreshCw, Check, LoaderCircle, TriangleAlert, ChevronRight, CircleDot, ScanSearch }
import from ..architect.model { ArchModel, ArchComponent, ArchFlow, ArchStatus, ArchStep }
import from .rpc { rpc }
import from .theme { fmt_count }

glob KIND_RGB: dict[str, str] = {
    "stage": "110,168,255",
    "component": "167,139,250",
    "service": "244,114,182",
    "store": "52,211,153",
    "interface": "251,191,36",
    "runtime": "64,212,226",
    "library": "150,160,190",
    "tooling": "150,138,124",
    "ui": "236,110,173"
};

def:pub kind_rgb(kind: str) -> str {
    if kind in KIND_RGB {
        return KIND_RGB[kind];
    }
    return "167,139,250";
}

glob ARCH_HANDLERS: dict[str, any] = {"open": None};

def:pub open_module(mid: str) {
    cb = ARCH_HANDLERS["open"];
    if cb {
        cb.call(None, mid);
    }
}

def:pub ArchCard(c: any, outside: bool, nkids: int) -> JsxElement {
    <div className={"anode" + (" ext-node" if outside else "")} style={{"--rgb": kind_rgb(c["kind"])}}>
        <div className="anode-top">
            <span className="anode-kind">{"outside · " + c["kind"] if outside else c["kind"]}</span>
            {c["order"] > 0 and not outside and <span className="anode-order">{"#" + str(c["order"])}</span>}
        </div>
        <div className="anode-name">{c["name"]}</div>
        {not outside and <div className="anode-sum">{c["summary"]}</div>}
        {not outside and <div className="anode-foot">
            <span>{fmt_count(c["module_count"]) + " modules"}</span>
            <div className="bar"><i style={{"width": str(round(c["confidence"] * 100)) + "%"}} /></div>
            {nkids > 0 and <span className="anode-parts">{str(nkids) + " parts"}<ChevronRight size={12} /></span>}
        </div>}
        {not outside and <div className="anode-mods">
            {for m in (c["top_modules"] or [])[:5] {
                <button key={m} className="anode-mod" onClick={lambda (e: MouseEvent) { e.stopPropagation(); open_module(m); }} onDoubleClick={lambda (e: MouseEvent) { e.stopPropagation(); }} title={"Open " + m}>{m.split("/")[-1]}</button>
            }}
        </div>}
    </div>
}


def:pub lift_to_level(parents: dict[str, str], cid: str, level: str) -> str {
    cur = cid;
    hops = 0;
    while cur and cur in parents and hops < 12 {
        if parents[cur] == level {
            return cur;
        }
        cur = parents[cur];
        hops += 1;
    }
    return "";
}

def:pub top_of(parents: dict[str, str], cid: str) -> str {
    cur = cid;
    hops = 0;
    while cur in parents and parents[cur] and hops < 12 {
        cur = parents[cur];
        hops += 1;
    }
    return cur;
}

def:pub order_key(c: ArchComponent) -> int {
    return c.order;
}

glob KIND_RANK: dict[str, int] = {"runtime": 0, "store": 1, "service": 2, "component": 3, "library": 4, "interface": 5, "ui": 6, "tooling": 7, "stage": 8};

def:pub kind_key(c: ArchComponent) -> int {
    return KIND_RANK[c.kind] if c.kind in KIND_RANK else 9;
}

def:pub drift_weight(e: dict[str, any]) -> float {
    return float(e["style"]["strokeWidth"]);
}

def:pub build_arch_flow(model: ArchModel, level: str, show_drift: bool) -> dict[str, any] {
    parents: dict[str, str] = {};
    by_id: dict[str, ArchComponent] = {};
    kids_count: dict[str, int] = {};
    for c in model.components {
        parents[c.id] = c.parent;
        by_id[c.id] = c;
        if c.parent {
            kids_count[c.parent] = (kids_count[c.parent] if c.parent in kids_count else 0) + 1;
        }
    }
    here = [c for c in model.components if c.parent == level];
    g = new(graphlib.Graph);
    g.setGraph({"rankdir": "LR", "nodesep": 34, "ranksep": 96, "marginx": 30, "marginy": 30});
    g.setDefaultEdgeLabel(lambda { return {}; });
    W = 250;
    H = 140;
    for c in here {
        g.setNode(c.id, {"width": W, "height": H});
    }
    stages = sorted([c for c in here if c.order > 0], key=order_key);
    for i in range(1, len(stages)) {
        g.setEdge(stages[i - 1].id, stages[i].id, {"weight": 8});
    }
    edges: list[dict[str, any]] = [];
    seen: list[str] = [];
    outside: list[str] = [];
    for f in model.flows {
        if not f.declared and not show_drift {
            continue;
        }
        a = lift_to_level(parents, f.src, level);
        b = lift_to_level(parents, f.dst, level);
        if not a and not b {
            continue;
        }
        if not a {
            a = "out:" + top_of(parents, f.src);
        }
        if not b {
            b = "out:" + top_of(parents, f.dst);
        }
        if a == b {
            continue;
        }
        eid = a + ">" + b + (">d" if f.declared else ">x");
        if eid in seen {
            continue;
        }
        seen.append(eid);
        for x in [a, b] {
            if x.startswith("out:") and x not in outside {
                outside.append(x);
                g.setNode(x, {"width": 190, "height": 64});
            }
        }
        g.setEdge(a, b);
        col = "#a78bfa" if f.declared else "#f87171";
        edges.append({
            "id": eid, "source": a, "target": b,
            "label": f.label if f.declared else str(f.observed) + (" import" if f.observed == 1 else " imports"),
            "animated": f.declared,
            "markerEnd": {"type": MarkerType.ArrowClosed, "color": col},
            "labelBgPadding": [6, 3],
            "labelBgBorderRadius": 6,
            "style": {
                "stroke": col, "strokeWidth": 1.6 + min(f.observed, 20) * 0.08,
                "strokeDasharray": "none" if f.declared else "6 5", "opacity": 0.9 if f.declared else 0.6
            }
        });
    }
    # drift: only the strongest undeclared dependencies, so the declared design stays readable
    drift_edges = sorted([e for e in edges if e["id"].endswith(">x")], key=drift_weight, reverse=True)[:8];
    edges = [e for e in edges if e["id"].endswith(">d")] + drift_edges;
    pos: dict[str, any] = {};
    pipeline = len(stages) >= 2;
    if pipeline {
        # stages in execution order along one row; supporting parts in rows beneath, outside context above
        gap = 96;
        for (i, c) in enumerate(stages) {
            pos[c.id] = {"x": i * (W + gap), "y": 0};
        }
        rest = sorted([c for c in here if c.order <= 0], key=kind_key);
        cols = max(len(stages), 3);
        row_w = cols * (W + 60) - 60;
        stage_w = len(stages) * (W + gap) - gap;
        offset = (stage_w - row_w) / 2;
        for (j, c) in enumerate(rest) {
            pos[c.id] = {"x": offset + (j % cols) * (W + 60), "y": (H + 120) * (1 + Math.floor(j / cols))};
        }
        ow = len(outside) * 230 - 40;
        for (k, x) in enumerate(outside) {
            pos[x] = {"x": (stage_w - ow) / 2 + k * 230, "y": -(64 + 120)};
        }
    } else {
        layout(g);
        for c in here {
            p0 = g.node(c.id);
            pos[c.id] = {"x": p0.x - W / 2, "y": p0.y - H / 2};
        }
        for x in outside {
            p1 = g.node(x);
            pos[x] = {"x": p1.x - 95, "y": p1.y - 32};
        }
    }
    nodes: list[dict[str, any]] = [];
    for c in here {
        nodes.append({
            "id": c.id, "className": "anode-host",
            "position": pos[c.id],
            "style": {"width": W, "height": H},
            "sourcePosition": "right", "targetPosition": "left",
            "data": {"label": <ArchCard c={c} outside={False} nkids={kids_count[c.id] if c.id in kids_count else 0} />}
        });
    }
    for x in outside {
        cid = x[4:];
        oc = by_id[cid] if cid in by_id else None;
        nodes.append({
            "id": x, "className": "anode-host",
            "position": pos[x],
            "style": {"width": 190, "height": 64},
            "sourcePosition": "right", "targetPosition": "left",
            "data": {"label": <ArchCard c={oc if oc else {"name": cid, "kind": "component", "order": 0}} outside={True} nkids={0} />}
        });
    }
    return {"nodes": nodes, "edges": edges};
}

def:pub ModCard(m: any) -> JsxElement {
    conf = round(float(m["confidence"]) * 100);
    <div className="anode modnode" style={{"--rgb": "110,168,255"}}>
        <div className="anode-top">
            <span className="anode-kind">module</span>
            <span className="anode-order">{str(m["loc"]) + " loc"}</span>
        </div>
        <div className="anode-name">{m["name"]}</div>
        <div className="anode-foot">
            <span>{"used by " + str(m["fan_in"])}</span>
            <div className="bar" title={"mapped by " + String(m["source"]) + " · " + str(conf) + "%"}><i style={{"width": str(conf) + "%"}} /></div>
        </div>
    </div>
}

def:pub build_module_flow(cm: any) -> dict[str, any] {
    g = new(graphlib.Graph);
    g.setGraph({"rankdir": "LR", "nodesep": 22, "ranksep": 70, "marginx": 30, "marginy": 30});
    g.setDefaultEdgeLabel(lambda { return {}; });
    W = 210;
    H = 78;
    for m in cm["modules"] {
        g.setNode(m["id"], {"width": W, "height": H});
    }
    for e in cm["edges"] {
        g.setEdge(e["src"], e["dst"]);
    }
    layout(g);
    nodes: list[dict[str, any]] = [];
    for m in cm["modules"] {
        pos = g.node(m["id"]);
        nodes.append({
            "id": m["id"], "className": "anode-host", "position": {"x": pos.x - W / 2, "y": pos.y - H / 2},
            "style": {"width": W, "height": H}, "sourcePosition": "right", "targetPosition": "left",
            "data": {"label": <ModCard m={m} />}
        });
    }
    edges: list[dict[str, any]] = [];
    for e in cm["edges"] {
        edges.append({
            "id": e["src"] + ">" + e["dst"], "source": e["src"], "target": e["dst"],
            "markerEnd": {"type": MarkerType.ArrowClosed, "color": "#6ea8ff"},
            "style": {"stroke": "#6ea8ff", "strokeWidth": 1.2 + min(int(e["weight"]), 6) * 0.2, "opacity": 0.75}
        });
    }
    return {"nodes": nodes, "edges": edges};
}

def:pub CoverageRing(value: float) -> JsxElement {
    r = 19;
    circ = 2 * 3.14159 * r;
    dash = str(round(circ * value, 2)) + " " + str(round(circ, 2));
    <svg className="ring" viewBox="0 0 46 46">
        <defs>
            <linearGradient id="ringgrad" x1="0" y1="0" x2="1" y2="1">
                <stop offset="0%" stopColor="#6ea8ff" />
                <stop offset="50%" stopColor="#a78bfa" />
                <stop offset="100%" stopColor="#f472b6" />
            </linearGradient>
        </defs>
        <circle cx="23" cy="23" r={r} fill="none" stroke="rgba(255,255,255,.08)" strokeWidth="4" />
        <circle cx="23" cy="23" r={r} fill="none" stroke="url(#ringgrad)" strokeWidth="4" strokeLinecap="round" strokeDasharray={dash} transform="rotate(-90 23 23)" />
        <text x="23" y="27" textAnchor="middle">{str(round(value * 100)) + "%"}</text>
    </svg>
}

def:pub StepList(steps: list[ArchStep]) -> JsxElement {
    <div className="steps">
        {for (i, s) in enumerate(steps) {
            <div key={"st" + str(i)} className={"step " + s.state}>
                <span className="step-icon">
                    {if s.state == "done" {
                        <Check size={15} />
                    } elif s.state == "active" {
                        <LoaderCircle size={15} className="spin" />
                    } elif s.state == "error" {
                        <TriangleAlert size={15} />
                    } else {
                        <CircleDot size={13} />
                    }}
                </span>
                <div><b>{s.label}</b>{s.detail and <small>{s.detail}</small>}</div>
            </div>
        }}
    </div>
}

def:pub ArchView(
    projectKey: str,
    onModel: Callable[[ArchModel], None],
    onSelectComp: Callable[[str], None],
    onSelectModule: Callable[[str], None] | None = None,
    onOpenModule: Callable[[str], None] | None = None
) -> JsxElement {
    has model: ArchModel | None = None;
    has status: ArchStatus | None = None;
    has level: str = "";
    has engine: str = "";
    has showDrift: bool = False;
    has error: str = "";
    has refining: bool = False;
    has compMods: any = None;
    has zoomed: bool = False;

    ARCH_HANDLERS["open"] = onOpenModule;

    async def load() {
        try {
            m = await rpc("arch_get", {});
            model = m;
            onModel(m);
            error = "" if m["ok"] else String(m["error"]);
        } except Exception as e {
            error = String(e);
        }
    }
    async def poll() {
        s = await rpc("arch_status", {});
        status = s;
        skeleton_ready = len(s["steps"]) > 3 and s["steps"][3]["state"] == "done";
        if (s["done"] and not s["running"]) or skeleton_ready {
            await load();
        }
    }
    async def discover() {
        error = "";
        level = "";
        status = await rpc("arch_discover", {"engine": engine});
    }
    async def refine_rest() {
        refining = True;
        try {
            m = await rpc("arch_refine", {});
            model = m;
            onModel(m);
        } except Exception as e {
            error = String(e);
        }
        refining = False;
    }

    async can with [projectKey] entry {
        level = "";
        status = None;
        await load();
        s = await rpc("arch_status", {});
        if s["running"] {
            status = s;
        }
    }

    running = status is not None and status.running;
    useEffect(lambda {
        if not running {
            return lambda { };
        }
        timer = setInterval(lambda { poll(); }, 1500);
        return lambda { clearInterval(timer); };
    }, [running]);

    has_model = model is not None and model.exists;
    failed = status is not None and status.done and not status.ok;
    is_leaf = level != "" and model is not None and len([c for c in model.components if c.parent == level]) == 0;

    async can with [level, projectKey] entry {
        compMods = None;
        if level and model is not None and len([c for c in model.components if c.parent == level]) == 0 {
            compMods = await rpc("arch_component_modules", {"comp_id": level, "limit": 60});
        }
    }
    graph_data = useMemo(lambda {
        if model is None {
            return {"nodes": [], "edges": []};
        }
        current: ArchModel = model if model is not None else ArchModel(ok=False);
        if not current.exists {
            return {"nodes": [], "edges": []};
        }
        if is_leaf {
            if compMods and compMods["ok"] {
                return build_module_flow(compMods);
            }
            return {"nodes": [], "edges": []};
        }
        return build_arch_flow(current, level, showDrift);
    }, [model, level, showDrift, compMods]);

    m: ArchModel = model if model is not None else ArchModel(ok=False);
    names: dict[str, str] = {};
    parents: dict[str, str] = {};
    if model is not None {
        for c in model.components {
            names[c.id] = c.name;
            parents[c.id] = c.parent;
        }
    }
    trail: list[str] = [];
    cur = level;
    hops = 0;
    while cur and hops < 12 {
        trail = [cur] + trail;
        cur = parents[cur] if cur in parents else "";
        hops += 1;
    }

    def click(e: any, n: any) {
        nid = String(n.id);
        if is_leaf {
            if onSelectModule {
                onSelectModule(nid);
            }
            return;
        }
        onSelectComp(nid[4:] if nid.startswith("out:") else nid);
    }
    def dbl(e: any, n: any) {
        nid = String(n.id);
        if is_leaf {
            if onOpenModule {
                onOpenModule(nid);
            }
            return;
        }
        target = nid[4:] if nid.startswith("out:") else nid;
        if model is not None and len([c for c in model.components if c.id == target]) > 0 {
            level = target;
            onSelectComp(target);
        }
    }
    def moved(e: any, vp: any) {
        z = vp.zoom > 1.3;
        if z != zoomed {
            zoomed = z;
        }
    }

    <div className="archview">
        {if (running and not has_model) or (failed and not has_model) {
            <div className="hero">
                <div className="orb" />
                <h2>{"Discovering the architecture" if running else "Discovery stopped"}</h2>
                <p>{"An architect agent is reading the code. Jev then maps every module onto what it finds, and the flows are checked against the real imports." if running else (status.error if status else "")}</p>
                {status and <StepList steps={status.steps} />}
                {not running and <button className="btn-grad" onClick={lambda (e: MouseEvent) { discover(); }}><RefreshCw size={13} />Try again</button>}
            </div>
        } elif not has_model {
            <div className="hero">
                <div className="orb" />
                <h2>Discover the architecture</h2>
                <p>{"Not the folders - the system. For a compiler that is its stages and the passes inside them; for a web app, its client, services and stores. Jev drafts it in seconds from a library of architecture templates, Codex names it in the project's own vocabulary, and jac smith keeps it current as the code changes."}</p>
                {error and <p style={{"color": "#fca5a5"}}>{error}</p>}
                <div className="row" style={{"justifyContent": "center"}}>
                    <select className="select" value={engine} onChange={lambda (e: ChangeEvent) { engine = e.target.value; }}>
                        <option value="">Auto · Jev decides, Codex names</option>
                        <option value="jev">Jev only · seconds, template vocabulary</option>
                        <option value="codex">Codex only · explores the whole repo</option>
                        <option value="llm">byLLM · reads the index</option>
                    </select>
                    <button className="btn-grad" onClick={lambda (e: MouseEvent) { discover(); }}><Sparkles size={13} />Discover architecture</button>
                </div>
            </div>
        } else {
            <div style={{"display": "flex", "flexDirection": "column", "flex": 1, "minHeight": 0}}>
                <div className="arch-head">
                    <CoverageRing value={m.coverage} />
                    <div className="arch-head-text">
                        <div className="arch-kind">{m.system_kind + " · " + m.style}</div>
                        <div className="arch-title">{m.title}</div>
                        <div className="arch-sum">{m.summary}</div>
                    </div>
                    <div style={{"display": "flex", "flexDirection": "column", "alignItems": "flex-end", "gap": "6px", "flexShrink": 0}}>
                        <div className="row" style={{"marginTop": 0}}>
                            <span className="pill"><span className="dot" />{"architect · " + m.generated_by}</span>
                            <span className="pill ok"><span className="dot" />{"mapped by " + m.mapped_by}</span>
                        </div>
                        <div className="row" style={{"marginTop": 0}}>
                            <label className="check"><input type="checkbox" checked={showDrift} onChange={lambda (e: ChangeEvent) { showDrift = e.target.checked; }} />{"Drift (" + str(len(m.drift)) + ")"}</label>
                            {m.unassigned > 0 and <button className="chip-btn" disabled={refining} onClick={lambda (e: MouseEvent) { refine_rest(); }}>{if refining { <LoaderCircle size={12} className="spin" /> } else { <ScanSearch size={12} /> }}{"Map " + fmt_count(m.unassigned) + " more"}</button>}
                            <button className="chip-btn" onClick={lambda (e: MouseEvent) { discover(); }}><RefreshCw size={12} />Rediscover</button>
                        </div>
                    </div>
                </div>
                {m.stale and <div className="banner warn"><TriangleAlert size={14} />{m.stale_reason + ". Map the rest, or rediscover if the design itself changed."}</div>}
                <div className="crumbs" style={{"padding": "0 16px 8px"}}>
                    <button className={"crumb" + (" last" if level == "" else "")} onClick={lambda (e: MouseEvent) { level = ""; }}>Overview</button>
                    {for t in trail {
                        <span key={"sep" + t} className="crumb-sep"><ChevronRight size={13} /></span>
                        <button key={t} className={"crumb" + (" last" if t == level else "")} onClick={lambda (e: MouseEvent) { level = t; }}>{names[t] if t in names else t}</button>
                    }}
                    <span className="stat" style={{"marginLeft": "auto"}}>{fmt_count(m.modules_total) + " modules · " + str(round(m.coverage * 100)) + "% mapped · updated " + m.updated_at.replace("T", " ")}</span>
                </div>
                {running and status and <div className="arch-progress">
                    <div className="arch-progress-head"><LoaderCircle size={13} className="spin" />{"Refining the architecture"}</div>
                    <StepList steps={status.steps} />
                </div>}
                {is_leaf and compMods and compMods["ok"] and <div className="leaf-note">{str(len(compMods["modules"])) + " modules implement " + compMods["name"] + (" (+" + str(compMods["more"]) + " more)" if compMods["more"] else "") + " · click to inspect · double-click to open the code"}</div>}
                <div className={"arch-canvas" + (" zoomed" if zoomed else "")}>
                    <ReactFlow
                        key={projectKey + "|" + level + "|" + str(len(graph_data["nodes"])) + "|" + str(len(graph_data["edges"]))}
                        defaultNodes={graph_data["nodes"]}
                        defaultEdges={graph_data["edges"]}
                        onNodeClick={click}
                        onNodeDoubleClick={dbl}
                        onMove={moved}
                        fitView={True}
                        fitViewOptions={{"padding": 0.16}}
                        minZoom={0.15}
                        colorMode="dark"
                        proOptions={{"hideAttribution": True}}
                    >
                        <Background gap={24} size={1} color="rgba(255,255,255,0.05)" />
                        <Controls showInteractive={False} />
                        <MiniMap pannable={True} zoomable={True} nodeColor="#2b2f45" maskColor="rgba(5,7,10,0.65)" />
                    </ReactFlow>
                </div>
            </div>
        }}
    </div>
}
