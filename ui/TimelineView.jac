"""History as a horizontal timeline: main runs left to right, commits are blobs along it, PR branches
curve in from side lanes and merge back, open branches fork off. No text on the canvas - hover for a
preview, click for the full commit in the left card."""
import from "react" { useEffect }
import from "lucide-react" { GitBranch, Minus, Plus, ChevronsRight, RefreshCw }
import from .rpc { rpc }
import from .HistoryView { CommitDiff, lane_color }

glob KIND_COLORS: dict[str, str] = {
    "feat": "#34d399", "fix": "#f472b6", "perf": "#fbbf24", "refactor": "#6ea8ff", "test": "#a3e635",
    "docs": "#94a3b8", "ci": "#64748b", "chore": "#64748b", "build": "#64748b", "release": "#a78bfa", "merge": "#a78bfa"
};
glob MAIN_Y: int = 52;
glob ROW_GAP: int = 34;
glob PAD: int = 40;

def:pub kind_color(kind: str) -> str {
    return KIND_COLORS[kind] if kind in KIND_COLORS else "#8b93a7";
}

def:pub row_y(row: int) -> float {
    return MAIN_Y + ROW_GAP * (row + 1);
}

"""x position for a timestamp: interpolated along main (commits newer than main extend to the right)."""
def:pub x_at(main: list[any], ts: int, gap: float) -> float {
    n = len(main);
    if n == 0 {
        return PAD;
    }
    if ts <= main[0]["ts"] {
        return PAD;
    }
    for i in range(1, n) {
        if main[i]["ts"] >= ts {
            a = main[i - 1]["ts"];
            b = main[i]["ts"];
            f = (ts - a) / (b - a) if b > a else 0.5;
            return PAD + (i - 1 + f) * gap;
        }
    }
    return -1.0;
}

"""Positions for main commits and lanes; lanes are packed into rows above/below main and their
commits sit at the moment they were made."""
def:pub lay_out(tl: any, gap: float) -> dict[str, any] {
    main = tl["main"];
    last_x = PAD + max(len(main) - 1, 0) * gap;
    rows_end: list[float] = [];
    lanes: list[dict[str, any]] = [];
    right = last_x;
    for ln in tl["lanes"] {
        pts: list[dict[str, any]] = [];
        prev_x = -1000000.0;
        ahead = 0;
        for c in ln["commits"] {
            if len(main) > 0 and c["ts"] < main[0]["ts"] {
                continue;
            }
            px = x_at(main, c["ts"], gap);
            if px < 0 {
                ahead += 1;
                px = last_x + ahead * gap * 0.7;
            }
            px = max(px, prev_x + max(gap * 0.45, 5.0));
            prev_x = px;
            pts.append({"x": px, "c": c});
        }
        if len(pts) == 0 {
            continue;
        }
        x0 = PAD + ln["fork"] * gap if ln["fork"] >= 0 else pts[0]["x"] - gap;
        x0 = min(x0, pts[0]["x"] - gap * 0.6);
        if ln["merge"] >= 0 {
            x1 = max(PAD + ln["merge"] * gap, pts[len(pts) - 1]["x"] + gap * 0.6);
        } else {
            x1 = pts[len(pts) - 1]["x"];
        }
        row = -1;
        for (r, end) in enumerate(rows_end) {
            if end + gap < x0 {
                row = r;
                break;
            }
        }
        if row < 0 {
            row = len(rows_end);
            rows_end.append(0.0);
        }
        rows_end[row] = x1;
        right = max(right, x1);
        lanes.append({"lane": ln, "x0": x0, "x1": x1, "y": row_y(row), "row": row, "color": lane_color(row + 1), "pts": pts, "forked": ln["fork"] >= 0});
    }
    top = 0;
    bottom = max([l["y"] for l in lanes] + [MAIN_Y]) + 34;
    return {"lanes": lanes, "width": right + PAD * 2, "top": top, "height": bottom - top, "last_x": last_x};
}

def:pub lane_path(l: dict[str, any], gap: float) -> str {
    y = l["y"];
    x0 = l["x0"];
    x1 = l["x1"];
    h = gap * 0.55;
    if l["forked"] {
        d = "M " + str(x0) + " " + str(MAIN_Y) + " C " + str(x0 + h) + " " + str(MAIN_Y) + ", " + str(x0 + h * 0.4) + " " + str(y) + ", " + str(x0 + h) + " " + str(y);
    } else {
        d = "M " + str(x0) + " " + str(y);
    }
    if l["lane"]["merge"] >= 0 {
        d = d + " L " + str(x1 - h) + " " + str(y) + " C " + str(x1 - h * 0.4) + " " + str(y) + ", " + str(x1 - h) + " " + str(MAIN_Y) + ", " + str(x1) + " " + str(MAIN_Y);
    } else {
        d = d + " L " + str(x1) + " " + str(y);
    }
    return d;
}

def:pub day_label(ts: int) -> str {
    dt: any = new(Date, ts * 1000);
    months: list[str] = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
    m: int = int(dt.getMonth());
    return months[m] + " " + str(dt.getDate());
}

def:pub TimelineView(
    projectKey: str,
    selected: str,
    diffPath: str,
    onSelect: Callable[[str], None],
    onCloseDiff: Callable[[], None]
) -> JsxElement {
    has tl: any = None;
    has loading: bool = True;
    has gap: float = 22.0;
    has hover: dict[str, any] | None = None;
    has scrollY: float = 0.0;
    has scrollRef: Ref[HTMLDivElement] = Ref();

    async def load() {
        loading = True;
        tl = await rpc("git_timeline", {"limit": 300, "branches": 12});
        loading = False;
    }
    async can with [projectKey] entry {
        await load();
    }
    def to_newest() {
        if scrollRef.current {
            el: any = scrollRef.current;
            el.scrollLeft = el.scrollWidth;
        }
    }
    useEffect(lambda {
        setTimeout(lambda { to_newest(); }, 30);
        return lambda { };
    }, [tl]);

    ok = tl is not None and tl["ok"] and len(tl["main"]) > 0;
    geo = lay_out(tl, gap) if ok else {"xs": {}, "lanes": [], "width": 600, "top": 0, "height": 300, "last_x": 0};
    main = tl["main"] if ok else [];
    ticks: list[dict[str, any]] = [];
    if ok {
        prev = "";
        every = max(1, int(70 / gap));
        for (i, c) in enumerate(main) {
            lab = day_label(c["ts"]);
            if lab != prev and (len(ticks) == 0 or i - ticks[len(ticks) - 1]["i"] >= every) {
                ticks.append({"i": i, "x": PAD + i * gap, "label": lab});
            }
            prev = lab;
        }
    }
    kinds_present = [k for k in ["feat", "fix", "perf", "refactor", "test", "docs", "ci", "release"] if len([c for c in main if c["kind"] == k]) > 0];

    def enter(c: any, x: float, y: float) {
        hover = {"c": c, "x": x, "y": y};
    }

    <div className="historyview">
        <div className="hist-main">
            <div className="hist-head">
                <GitBranch size={15} />
                <span className="hist-title">{tl["branch"] if ok else "History"}</span>
                {ok and <span className="stat mono">{str(len(main)) + " commits · " + str(len([l for l in tl["lanes"] if l["kind"] == "pr"])) + " merged branches · " + str(len([l for l in tl["lanes"] if l["kind"] == "branch"])) + " open"}</span>}
                <div className="tl-legend">
                    {for k in kinds_present {
                        <span key={k} className="legend-item"><span className="swatch" style={{"background": kind_color(k)}} />{k}</span>
                    }}
                    <span className="legend-item"><span className="swatch pr" />PR</span>
                </div>
                <span className="spacer" />
                <button className="icon-btn" title="Zoom out" onClick={lambda (e: MouseEvent) { gap = max(gap / 1.35, 6.0); }}><Minus size={14} /></button>
                <button className="icon-btn" title="Zoom in" onClick={lambda (e: MouseEvent) { gap = min(gap * 1.35, 80.0); }}><Plus size={14} /></button>
                <button className="icon-btn" title="Jump to newest" onClick={lambda (e: MouseEvent) { to_newest(); }}><ChevronsRight size={14} /></button>
                <button className="icon-btn" title="Refresh" onClick={lambda (e: MouseEvent) { load(); }}><RefreshCw size={14} /></button>
            </div>
            {if tl is not None and not tl["ok"] {
                <div className="empty"><h2>No history</h2><p>{tl["error"]}</p></div>
            } elif tl is not None and not ok {
                <div className="empty"><h2>No commits yet</h2><p>{tl["error"] or "Commit something to see the timeline."}</p></div>
            } else {
                <div className="tl-wrap">
                <div className="tl-pin" style={{"top": str(MAIN_Y - scrollY - 10) + "px"}}><GitBranch size={11} />{tl["branch"] if ok else "main"}</div>
                <div className="tl-scroll" ref={scrollRef} onScroll={lambda (e: UIEvent) { scrollY = e.target.scrollTop; }} onMouseLeave={lambda (e: MouseEvent) { hover = None; }}>
                    <svg className="tl-svg" width={geo["width"]} height={geo["height"]} viewBox={"0 " + str(geo["top"]) + " " + str(geo["width"]) + " " + str(geo["height"])}>
                        <defs>
                            <linearGradient id="mainline" x1="0" x2="1" y1="0" y2="0">
                                <stop offset="0%" stopColor="#6ea8ff" stopOpacity="0.35" />
                                <stop offset="100%" stopColor="#a78bfa" stopOpacity="0.9" />
                            </linearGradient>
                        </defs>
                        {for t in ticks {
                            <g key={"t" + str(t["i"])}>
                                <line x1={t["x"]} x2={t["x"]} y1={22} y2={geo["height"] - 8} className="tl-tick" />
                                <text x={t["x"] + 4} y={16} className="tl-date">{t["label"]}</text>
                            </g>
                        }}
                        {for (k, l) in enumerate(geo["lanes"]) {
                            <path key={"lp" + str(k)} d={lane_path(l, gap)} stroke={l["color"]} className={"tl-lane " + l["lane"]["kind"]} />
                        }}
                        <line x1={PAD - 10} x2={geo["last_x"] + 10} y1={MAIN_Y} y2={MAIN_Y} stroke="url(#mainline)" className="tl-main" />
                        <text x={geo["last_x"] + 16} y={MAIN_Y + 4} className="tl-head-label">{(tl["branch"] if ok else "main") + (" · HEAD" if ok and tl["branch"] == tl["current"] else "")}</text>
                        {for (k, l) in enumerate(geo["lanes"]) {
                            if l["lane"]["kind"] == "branch" and len(l["pts"]) > 0 {
                                <text key={"ll" + str(k)} x={l["x1"] + 10} y={l["y"] + 4} fill={l["color"]} className={"tl-lane-label" + (" current" if ok and l["lane"]["name"] == tl["current"] else "")}>{(("HEAD · " if ok and l["lane"]["name"] == tl["current"] else "") + l["lane"]["name"])[:48]}</text>
                            }
                        }}
                        {for (k, l) in enumerate(geo["lanes"]) {
                            for (j, pt) in enumerate(l["pts"]) {
                                <circle key={"lc" + str(k) + "_" + str(j)} cx={pt["x"]} cy={l["y"]} r={4.5 if gap >= 10 else 3} fill={l["color"]} className={"tl-blob" + (" sel" if pt["c"]["hash"] == selected else "")} onMouseEnter={lambda (e: MouseEvent) { enter(pt["c"], pt["x"], l["y"]); }} onClick={lambda (e: MouseEvent) { onSelect(pt["c"]["hash"]); }} />
                            }
                        }}
                        {for (i, c) in enumerate(main) {
                            <g key={c["hash"]} className="tl-node" onMouseEnter={lambda (e: MouseEvent) { enter(c, PAD + i * gap, MAIN_Y); }} onClick={lambda (e: MouseEvent) { onSelect(c["hash"]); }}>
                                {(c["pr"] > 0 or c["merge"]) and <circle cx={PAD + i * gap} cy={MAIN_Y} r={9 if gap >= 10 else 6} className={"tl-ring" + (" merge" if c["merge"] else "")} />}
                                <circle cx={PAD + i * gap} cy={MAIN_Y} r={5.5 if gap >= 10 else 3.5} fill={kind_color(c["kind"])} className={"tl-blob" + (" sel" if c["hash"] == selected else "")} />
                                {len(c["refs"]) > 0 and <circle cx={PAD + i * gap} cy={MAIN_Y - 16} r={2.5} className="tl-ref" />}
                            </g>
                        }}
                    </svg>
                    {hover and <div className="tl-tip" style={{"left": str(hover["x"]) + "px", "top": str(hover["y"] - geo["top"] - 12) + "px"}}>
                        <div className="tl-tip-subject">{hover["c"]["subject"][:90]}</div>
                        <div className="tl-tip-meta">{hover["c"]["short"] + " · " + hover["c"]["author"] + (" · PR #" + str(hover["c"]["pr"]) if hover["c"]["pr"] else "") + (" · " + ", ".join(hover["c"]["refs"]) if len(hover["c"]["refs"]) > 0 else "")}</div>
                    </div>}
                </div>
                </div>
            }}
            {loading and <div className="toast">Reading history...</div>}
        </div>
        {if selected and diffPath {
            <CommitDiff sha={selected} path={diffPath} onClose={onCloseDiff} />
        }}
    </div>
}
