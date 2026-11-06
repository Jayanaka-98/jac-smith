"""Developer view: the focused box and its children as importance-weighted boxes.

Hover a box and it glimmers (a light sweep, plus a glow that follows the cursor) and opens up to
show what it is. Click it and it grows to fill the canvas while its own children cascade in -
packages into modules, modules into their declarations. Things outside the box sit on the rail.
"""
import from "lucide-react" { ChevronRight, CodeXml, LayoutGrid, PanelRightClose, PanelRightOpen }
import from .CodeView { CodeView }
import from ..indexer.model { BoxFrame, ChildView, Tile, ExternalInfo, SymbolInfo }
import from .theme { role_rgb, eco_label, fmt_count, pct }

def:pub can_expand(kind: str, n_children: int, n_symbols: int) -> bool {
    if kind == "symbol" {
        return False;
    }
    if kind == "module" {
        return n_symbols > 0;
    }
    return n_children > 0;
}

"""Highlighted code. Tokens come pre-classified from the server; rendered as text spans (no HTML)."""
def:pub CodeSnip(tokens: list[list[str]], caption: str = "") -> JsxElement {
    <div className="tile-code">
        {caption and <div className="from">{caption}</div>}
        <pre>{for (i, tk) in enumerate(tokens) {
            <span key={"t" + str(i)} className={"tk-" + tk[0]}>{tk[1]}</span>
        }}</pre>
    </div>
}

def:pub MiniTile(t: Tile) -> JsxElement {
    style = {
        "left": pct(t.x), "top": pct(t.y),
        "width": "calc(" + pct(t.w) + " + 1px)", "height": "calc(" + pct(t.h) + " + 1px)",
        "--rgb": role_rgb(t.role),
        "background": "rgba(" + role_rgb(t.role) + "," + str(0.05 + 0.16 * t.importance) + ")"
    };
    <div className="mini" style={style} title={t.name}>{t.name if t.w > 0.14 and t.h > 0.12 else ""}</div>
}

def:pub ChildTile(
    cv: ChildView,
    index: int,
    state: str,
    onPick: Callable[[str], None],
    onHover: Callable[[str], None]
) -> JsxElement {
    info = cv.info;
    t = cv.tile;
    expandable = can_expand(info.kind, len(info.children), len(info.symbols));
    box_style = {
        "left": pct(t.x), "top": pct(t.y), "width": pct(t.w), "height": pct(t.h),
        "animationDelay": str(min(index * 12, 120)) + "ms"
    };
    inner_style = {
        "--rgb": role_rgb(info.role),
        "--imp": str(round(t.importance, 3)),
        "--cen": str(round(info.centrality, 3))
    };
    stats = "";
    if info.kind == "package" {
        stats = fmt_count(info.files) + " files · " + fmt_count(info.loc) + " loc";
    } elif info.kind == "symbol" {
        stats = str(info.loc) + " lines";
    } else {
        stats = fmt_count(info.loc) + " loc";
    }
    if info.fan_in > 0 {
        stats = stats + " · used by " + str(info.fan_in);
    }
    publics = [s for s in info.symbols if s.public];
    big = t.w > 0.16 and t.h > 0.2;

    def click(e: MouseEvent) {
        e.stopPropagation();
        onPick(info.id);
    }
    def enter(e: MouseEvent) {
        onHover(info.id);
    }
    def leave(e: MouseEvent) {
        onHover("");
    }
    def move(e: MouseEvent) {
        el: any = e.currentTarget;
        r = el.getBoundingClientRect();
        el.style.setProperty("--mx", str(e.clientX - r.left) + "px");
        el.style.setProperty("--my", str(e.clientY - r.top) + "px");
    }

    <div className={"tile " + info.kind + " " + state} style={box_style}>
        <div className="tile-inner" style={inner_style} onClick={click} onMouseEnter={enter} onMouseLeave={leave} onMouseMove={move}>
            <div className="tile-head">
                <span className="role-dot" />
                <span className="tile-name">{info.name}</span>
                {expandable and <span className="tile-chev"><ChevronRight size={14} /></span>}
            </div>
            {t.h > 0.1 and <div className="tile-stats">{stats}</div>}
            {if len(cv.inner) > 0 and t.h > (0.34 if len(cv.code) > 0 else 0.18) {
                <div className="tile-body">
                    {for m in cv.inner {
                        <MiniTile key={m.id} t={m} />
                    }}
                </div>
            }}
            {if len(cv.code) > 0 and t.h > 0.13 and t.w > 0.1 {
                <CodeSnip tokens={cv.code} caption={(cv.code_from.split("/")[-1] + ":" + str(cv.code_line)) if info.kind == "package" else ""} />
            } elif info.kind == "module" and len(publics) > 0 and t.h > 0.18 {
                <ul className="ifaces">
                    {for s in publics[:10] {
                        <li key={s.name + str(s.line)}><span className="k">{s.kind}</span>{" " + s.name}</li>
                    }}
                </ul>
            }}
            {if big {
                <div className="tile-details">
                    {(info.summary and info.kind != "symbol") and <p>{info.summary}</p>}
                    {len(publics) > 0 and info.kind != "symbol" and <div className="ifs">
                        {for s in publics[:4] {
                            <span key={"d" + s.name}><b>{s.kind}</b>{" " + s.name + "  "}</span>
                        }}
                    </div>}
                    <div className="meta">{(info.role.lower() + " · " if info.role else "") + ("click to open" if expandable else "click for details")}</div>
                </div>
            }}
        </div>
    </div>
}

def:pub ExternalBox(x: ExternalInfo, lit: bool, dim: bool, onOpen: Callable[[str], None]) -> JsxElement {
    is_project = x.ecosystem == "project";
    cls = "ext" + (" project" if is_project else "") + (" lit" if lit else "") + (" dim" if dim else "");
    def open(e: MouseEvent) {
        if is_project {
            onOpen(x.id);
        }
    }
    <button className={cls} onClick={open} title={eco_label(x.ecosystem) + " · " + str(x.uses) + " import sites"}>
        <span className="ext-name">{x.name}</span>
        <span className="ext-uses">{str(x.uses)}</span>
    </button>
}

def:pub eco_group(eco: str) -> str {
    if eco == "project" {
        return "project";
    }
    if eco in ["stdlib", "node"] {
        return "platform";
    }
    return "lib";
}

"""The rail minimized: a thin strip with one dot per outside dependency. Hovering a box still
lights the dots it uses, so the connection survives collapsing."""
def:pub RailStrip(externals: list[ExternalInfo], active: str, linked: list[str], onExpand: Callable[[], None]) -> JsxElement {
    shown = externals[:40];
    <aside className="rail-strip" onClick={lambda (e: MouseEvent) { e.stopPropagation(); onExpand(); }} title={"Outside this box: " + str(len(externals)) + " - click to expand"}>
        <span className="strip-btn"><PanelRightOpen size={14} /></span>
        <span className="strip-count">{str(len(externals))}</span>
        <span className="strip-label">Outside this box</span>
        <div className="strip-dots">
            {for x in shown {
                <span key={x.id} className={"strip-dot " + eco_group(x.ecosystem) + (" lit" if active != "" and x.id in linked else "") + (" dim" if active != "" and x.id not in linked else "")} title={x.name + " · " + eco_label(x.ecosystem) + " · " + str(x.uses)} />
            }}
        </div>
    </aside>
}

def:pub ExternalRail(
    externals: list[ExternalInfo], active: str, linked: list[str], onOpen: Callable[[str], None], width: float = 214,
    onCollapse: Callable[[], None] | None = None
) -> JsxElement {
    groups = [
        ("Elsewhere in project", [x for x in externals if x.ecosystem == "project"]),
        ("Libraries", [x for x in externals if x.ecosystem in ["pypi", "npm", "jac"]]),
        ("Platform", [x for x in externals if x.ecosystem in ["stdlib", "node"]])
    ];
    <aside className="rail" style={{"width": str(width) + "px"}}>
        <div className="rail-head">
            <span>{"Outside this box · " + str(len(externals))}</span>
            {onCollapse and <button className="icon-btn" title="Minimize to a strip" onClick={lambda (e: MouseEvent) { e.stopPropagation(); onCollapse(); }}><PanelRightClose size={14} /></button>}
        </div>
        {for (title, items) in groups {
            if len(items) > 0 {
                <div key={title}>
                    <h4>{title}</h4>
                    {for x in items[:30] {
                        <ExternalBox key={x.id} x={x} lit={x.id in linked} dim={active != "" and x.id not in linked} onOpen={onOpen} />
                    }}
                </div>
            }
        }}
    </aside>
}

def:pub BoxView(
    frame: BoxFrame,
    selectedId: str,
    touched: list[str],
    direction: str,
    onSelect: Callable[[str], None],
    onOpen: Callable[[str], None],
    onHover: Callable[[str], None],
    railWidth: float = 214,
    railSash: any = None,
    onRailToggle: Callable[[], None] | None = None,
    onCodeSelection: Callable[[str, int, int, str], None] | None = None,
    onFileSaved: Callable[[], None] | None = None
) -> JsxElement {
    has hoverId: str = "";
    has ghost: dict[str, any] | None = None;
    has ghostGrow: bool = False;
    has moduleMode: str = "code";
    has jumpLine: int = 0;

    focus = frame.focus;
    focus_id = focus.id if focus is not None else "";
    is_file = focus is not None and focus.kind == "module";

    can with [focus_id] entry {
        moduleMode = "code";
        jumpLine = 0;
    }
    active = hoverId or selectedId;
    linked: list[str] = [e.dst for e in frame.edges if e.src == active] if active else [e.dst for e in frame.edges];
    users: list[str] = [e.src for e in frame.edges if e.dst == active] if active else [];

    def hover(bid: str) {
        hoverId = bid;
        onHover(bid);
    }
    def pick(bid: str) {
        for cv in frame.children {
            if cv.info.id == bid {
                if cv.info.kind == "module" {
                    # files open instantly, like an editor tab - no zoom choreography
                    hoverId = "";
                    onOpen(bid);
                } elif can_expand(cv.info.kind, len(cv.info.children), len(cv.info.symbols)) {
                    ghost = {
                        "left": pct(cv.tile.x), "top": pct(cv.tile.y), "width": pct(cv.tile.w), "height": pct(cv.tile.h),
                        "rgb": role_rgb(cv.info.role), "name": cv.info.name
                    };
                    ghostGrow = False;
                    setTimeout(lambda { ghostGrow = True; }, 16);
                    setTimeout(lambda { ghost = None; ghostGrow = False; }, 380);
                    hoverId = "";
                    onOpen(bid);
                } else {
                    if cv.info.kind == "symbol" and len(cv.info.symbols) > 0 {
                        jumpLine = cv.info.symbols[0].line;
                        moduleMode = "code";
                    }
                    onSelect(bid);
                }
                return;
            }
        }
    }
    def clear(e: MouseEvent) {
        onSelect("");
    }
    def tile_state(bid: str) -> str {
        if bid == selectedId {
            return "selected";
        }
        if bid in touched {
            return "touched";
        }
        if hoverId and bid != hoverId {
            if bid in linked {
                return "dep";
            }
            if bid in users {
                return "user";
            }
            return "dim";
        }
        return "";
    }

    meta = "";
    if focus is not None {
        if focus.kind == "module" {
            meta = fmt_count(focus.loc) + " loc · " + str(len(frame.children)) + " declarations";
        } else {
            meta = fmt_count(focus.files) + " files · " + fmt_count(focus.loc) + " loc";
        }
        if focus.summary {
            meta = meta + " · " + focus.summary;
        }
    }

    <div className="boxview">
        <section className="frame" onClick={clear}>
            {if focus is not None {
                <div className="frame-head">
                    <span className="frame-title">{focus.name + ("/" if focus.kind == "package" else "")}</span>
                    <span className="frame-meta">{meta}</span>
                    {is_file and <div className="mode-toggle">
                        <button className={"on" if moduleMode == "code" else ""} onClick={lambda (e: MouseEvent) { e.stopPropagation(); moduleMode = "code"; }}><CodeXml size={13} />Code</button>
                        <button className={"on" if moduleMode == "boxes" else ""} onClick={lambda (e: MouseEvent) { e.stopPropagation(); moduleMode = "boxes"; }}><LayoutGrid size={13} />Declarations</button>
                    </div>}
                </div>
            }}
            {if is_file and moduleMode == "code" and focus is not None {
                <div key={"code" + focus_id} className={"frame-body enter-" + direction} onClick={lambda (e: MouseEvent) { e.stopPropagation(); }}>
                    <CodeView file={focus} jumpLine={jumpLine} onJump={lambda (l: int) { jumpLine = l; }} onSelection={lambda (f: str, a: int, b: int, t: str) { if onCodeSelection { onCodeSelection(f, a, b, t); } }} onSaved={lambda { if onFileSaved { onFileSaved(); } }} />
                </div>
            } else {
            <div key={focus_id} className={"frame-body enter-" + direction}>
                {if len(frame.children) == 0 {
                    <div className="empty"><h2>Nothing inside</h2><p>No declarations were found in this box.</p></div>
                }}
                {for (i, cv) in enumerate(frame.children) {
                    <ChildTile key={cv.info.id} cv={cv} index={i} state={tile_state(cv.info.id)} onPick={pick} onHover={hover} />
                }}
                {if ghost {
                    <div className={"zoom-ghost" + (" grow" if ghostGrow else "")} style={{"left": ghost["left"], "top": ghost["top"], "width": ghost["width"], "height": ghost["height"], "--rgb": ghost["rgb"]}}>
                        <span className="zoom-ghost-name">{ghost["name"]}</span>
                    </div>
                }}
            </div>
            }}
        </section>
        {railWidth > 0 and railSash}
        {if railWidth > 0 {
            <ExternalRail externals={frame.externals} active={active} linked={linked} onOpen={onOpen} width={railWidth} onCollapse={lambda { if onRailToggle { onRailToggle(); } }} />
        } else {
            <RailStrip externals={frame.externals} active={active} linked={linked} onExpand={lambda { if onRailToggle { onRailToggle(); } }} />
        }}
    </div>
}
