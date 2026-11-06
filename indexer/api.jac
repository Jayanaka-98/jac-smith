"""Indexer endpoints: open/index a project and serve one level of the hierarchy as a BoxFrame.

Module-level dependencies are aggregated up to the focused level on demand, so the same data
drives the developer (box) view and the architecture (graph) view.
"""
import os;
import time;
import tempfile;
import hashlib;

import from indexer.model {
    SourceFile, BoxInfo, SymbolInfo, ExternalInfo, Tile, ChildView, DepEdge, Crumb, BoxFrame, IndexSummary
}
import from indexer.scan { scan_project }
import from indexer.graph { ProjectData, build_project }
import from indexer.layout { treemap }
import from indexer.snippets { module_snippet, range_snippet, tokenize, lang_of }
import from settings.credentials { jev_key, read_config, write_config }
import from settings.session { authorized }

glob _project: ProjectData | None = None;
glob _last_jev: bool = False;
glob MAX_SOURCE: int = 400000;
glob MAX_INNER: int = 28;

def current_project() -> ProjectData | None {
    return _project;
}

def:pub default_project(token: str) -> str {
    if not authorized(token) {
        return "";
    }
    recent = read_config().get("recent_projects", []);
    if recent and os.path.isdir(str(recent[0])) {
        return str(recent[0]);
    }
    cwd = os.getcwd();
    if cwd != "/" and os.path.isfile(os.path.join(cwd, "jac.toml")) {
        return cwd;
    }
    return os.path.expanduser("~");
}

def:pub recent_projects(token: str) -> list[str] {
    if not authorized(token) {
        return [];
    }
    return [str(p) for p in read_config().get("recent_projects", []) if os.path.isdir(str(p))][:8];
}

def _remember(path: str) -> None {
    cfg = read_config();
    recent = [str(p) for p in cfg.get("recent_projects", []) if str(p) != path];
    cfg["recent_projects"] = [path] + recent[:9];
    write_config(cfg);
}

def do_index(path: str, use_jev: bool = False) -> IndexSummary {
    start = time.time();
    root_dir = os.path.abspath(os.path.expanduser(path.strip() or "."));
    if not os.path.isdir(root_dir) {
        return IndexSummary(ok=False, error="Not a directory: " + root_dir);
    }
    jev_on = use_jev and bool(jev_key());
    try {
        files = scan_project(root_dir);
        data = build_project(root_dir, files, jev_on);
    } except Exception as e {
        return IndexSummary(ok=False, error="Indexing failed: " + str(e), project=root_dir);
    }
    _project = data;
    _last_jev = jev_on;
    _remember(root_dir);
    mods = len([b for b in data.boxes.values() if b.kind == "module"]);
    pkgs = len([b for b in data.boxes.values() if b.kind == "package"]);
    return IndexSummary(
        ok=True, project=root_dir, root_id=data.root_id, modules=mods, packages=pkgs,
        externals=len(data.exts), loc=data.boxes[data.root_id].loc,
        millis=int((time.time() - start) * 1000)
    );
}

"""Re-run the last index (used by the agent after it edits files)."""
def reindex() -> IndexSummary {
    if _project is None {
        return IndexSummary(ok=False, error="No project open");
    }
    return do_index(_project.root_dir, _last_jev);
}

def _ancestors(p: ProjectData, bid: str) -> list[str] {
    chain: list[str] = [];
    cur = bid;
    seen: set[str] = set();
    while cur and cur in p.boxes and cur not in seen {
        seen.add(cur);
        chain.append(cur);
        cur = p.boxes[cur].parent;
    }
    return chain;
}

def _assign_members(p: ProjectData, bid: str, member: str, out: dict[str, str]) -> None {
    out[bid] = member;
    for c in p.boxes[bid].children {
        _assign_members(p, c, member, out);
    }
}

"""The box at the focus's sibling level (or above) that contains an out-of-focus target."""
def _context_box(p: ProjectData, target: str, focus_chain: set[str]) -> str {
    x = target;
    while x in p.boxes and p.boxes[x].parent and p.boxes[x].parent not in focus_chain {
        x = p.boxes[x].parent;
    }
    return x;
}

def _tile(b: BoxInfo, x: float, y: float, w: float, h: float) -> Tile {
    return Tile(
        id=b.id, name=b.name, kind=b.kind, x=x, y=y, w=w, h=h,
        importance=b.importance, centrality=b.centrality, role=b.role
    );
}

def frame_for(box_id: str, aspect: float = 1.6) -> BoxFrame {
    p = _project;
    if p is None {
        return BoxFrame(ok=False, error="No project open");
    }
    focus = p.boxes.get(box_id) or p.boxes[p.root_id];
    chain = _ancestors(p, focus.id);
    crumbs = [Crumb(id=c, name=p.boxes[c].name) for c in reversed(chain)];
    members = focus.children if focus.children else [focus.id];

    member_of: dict[str, str] = {};
    for m in members {
        _assign_members(p, m, m, member_of);
    }
    chain_set = set(chain);

    edge_w: dict[tuple[str, str], int] = {};
    ext_uses: dict[str, int] = {};
    context: dict[str, ExternalInfo] = {};
    for (bid, member) in member_of.items() {
        for (t, cnt) in p.mod_deps.get(bid, {}).items() {
            dst = member_of.get(t, "");
            if not dst {
                dst = _context_box(p, t, chain_set);
                if dst not in context {
                    cb = p.boxes[dst];
                    context[dst] = ExternalInfo(id=dst, name=cb.name + ("/" if cb.kind == "package" else ""), ecosystem="project");
                }
                context[dst].uses += cnt;
            }
            if dst != member {
                edge_w[(member, dst)] = edge_w.get((member, dst), 0) + cnt;
            }
        }
        for (e, cnt) in p.mod_ext.get(bid, {}).items() {
            edge_w[(member, e)] = edge_w.get((member, e), 0) + cnt;
            ext_uses[e] = ext_uses.get(e, 0) + cnt;
        }
    }

    externals: list[ExternalInfo] = list(context.values());
    for (e, cnt) in ext_uses.items() {
        base = p.exts.get(e);
        if base is not None {
            externals.append(ExternalInfo(id=e, name=base.name, ecosystem=base.ecosystem, uses=cnt));
        }
    }
    externals = sorted(externals, key=lambda (x: ExternalInfo) -> int { -x.uses });

    edges = [
        DepEdge(src=s, dst=d, weight=w, external=d.startswith("ext:") or d in context)
        for ((s, d), w) in edge_w.items()
    ];
    edges = sorted(edges, key=lambda (x: DepEdge) -> int { -x.weight })[:400];

    children: list[ChildView] = [];
    if focus.children {
        rects = treemap([(c, p.boxes[c].score) for c in focus.children], aspect);
        for c in focus.children {
            b = p.boxes[c];
            r = rects[c];
            inner: list[Tile] = [];
            if b.children {
                sub = b.children[:MAX_INNER];
                sub_aspect = aspect * (r.w / max(r.h, 1e-6));
                sub_rects = treemap([(s, p.boxes[s].score) for s in sub], sub_aspect);
                inner = [_tile(p.boxes[s], sub_rects[s].x, sub_rects[s].y, sub_rects[s].w, sub_rects[s].h) for s in sub];
            }
            children.append(ChildView(info=b, tile=_tile(b, r.x, r.y, r.w, r.h), inner=inner));
        }
    }
    for cv in children {
        attach_code(p, cv);
    }
    if focus.kind == "module" and len(focus.symbols) > 0 {
        children = symbol_children(focus, aspect);
        for cv in children {
            attach_code(p, cv);
        }
    }
    return BoxFrame(
        ok=True, project=p.root_dir, focus=focus, crumbs=crumbs, children=children,
        externals=externals, edges=edges
    );
}

"""The module that best represents a box: follow the most important child down to a file."""
def key_module(p: ProjectData, bid: str) -> str {
    cur = bid;
    for _ in range(16) {
        b = p.boxes.get(cur);
        if b is None {
            return "";
        }
        if b.kind == "module" {
            return cur;
        }
        if not b.children {
            return "";
        }
        cur = b.children[0];
    }
    return "";
}

"""Attach a highlighted code preview to a child view (module: its first real declaration;
package: its key module; declaration: its own lines)."""
def attach_code(p: ProjectData, cv: ChildView) -> None {
    b = cv.info;
    if b.kind == "symbol" {
        if b.symbols {
            text = range_snippet(os.path.join(p.root_dir, b.parent), b.symbols[0].line, min(max(b.loc, 3), 16));
            cv.code = tokenize(text, lang_of(b.parent));
            cv.code_from = b.parent;
            cv.code_line = b.symbols[0].line;
        }
        return;
    }
    mod = b.id if b.kind == "module" else key_module(p, b.id);
    if not mod {
        return;
    }
    mb = p.boxes[mod];
    (text, line) = module_snippet(os.path.join(p.root_dir, mod), [s.line for s in mb.symbols if s.public] or [s.line for s in mb.symbols]);
    if text {
        cv.code = tokenize(text, lang_of(mod));
        cv.code_from = mod;
        cv.code_line = line;
    }
}

"""A module expands into its declarations: one box per class/def/node/walker, sized by line span."""
def symbol_children(focus: BoxInfo, aspect: float) -> list[ChildView] {
    ordered = sorted(focus.symbols, key=lambda (s: SymbolInfo) -> int { s.line });
    spans: dict[str, int] = {};
    for (i, s) in enumerate(ordered) {
        nxt = ordered[i + 1].line if i + 1 < len(ordered) else s.line + 15;
        spans[s.name + ":" + str(s.line)] = max(nxt - s.line, 2);
    }
    chosen = [s for s in ordered if s.public] or ordered;
    chosen = sorted(chosen, key=lambda (s: SymbolInfo) -> int { -spans[s.name + ":" + str(s.line)] })[:48];
    biggest = max([spans[s.name + ":" + str(s.line)] for s in chosen] + [1]);
    infos: list[BoxInfo] = [];
    for s in chosen {
        span = spans[s.name + ":" + str(s.line)];
        infos.append(BoxInfo(
            id=focus.id + "#" + s.name + ":" + str(s.line), name=s.name, path=focus.path, kind="symbol",
            lang=focus.lang, parent=focus.id, loc=span, score=float(span), importance=span / biggest,
            role=focus.role, tier=focus.tier, summary=s.signature, symbols=[s]
        ));
    }
    rects = treemap([(b.id, b.score) for b in infos], aspect);
    return [ChildView(info=b, tile=_tile(b, rects[b.id].x, rects[b.id].y, rects[b.id].w, rects[b.id].h)) for b in infos];
}

def:pub get_box(token: str, box_id: str) -> BoxInfo | None {
    if not authorized(token) or _project is None {
        return None;
    }
    return _project.boxes.get(box_id);
}

def safe_path(rel: str) -> str {
    if _project is None {
        return "";
    }
    base_dir = os.path.realpath(_project.root_dir);
    full = os.path.realpath(os.path.join(base_dir, rel));
    if full != base_dir and not full.startswith(base_dir + os.sep) {
        return "";
    }
    return full;
}

def source_of(box_id: str) -> str {
    full = safe_path(box_id);
    if not full or not os.path.isfile(full) {
        return "";
    }
    with open(full, encoding="utf-8", errors="replace") as fh {
        return fh.read(MAX_SOURCE);
    }
}

def:pub index_project(token: str, path: str, use_jev: bool = False) -> IndexSummary {
    if not authorized(token) {
        return IndexSummary(ok=False, error="unauthorized");
    }
    return do_index(path, use_jev);
}

def:pub get_frame(token: str, box_id: str, aspect: float = 1.6) -> BoxFrame {
    if not authorized(token) {
        return BoxFrame(ok=False, error="unauthorized");
    }
    return frame_for(box_id, aspect);
}

def:pub read_source(token: str, box_id: str) -> str {
    if not authorized(token) {
        return "";
    }
    return source_of(box_id);
}

"""A whole file as highlight tokens (for the detail card's code view)."""
def:pub read_source_tokens(token: str, box_id: str, start: int = 1, count: int = 0) -> list[list[str]] {
    if not authorized(token) {
        return [];
    }
    text = source_of(box_id);
    if not text {
        return [];
    }
    if count > 0 {
        text = "\n".join(text.splitlines()[max(start - 1, 0):max(start - 1, 0) + count]);
    }
    return tokenize(text, lang_of(box_id));
}

"""A whole file as highlighted lines: each line is a list of [kind, text] tokens (the code view)."""
def source_lines(box_id: str) -> list[list[list[str]]] {
    text = source_of(box_id);
    if not text {
        return [];
    }
    lines: list[list[list[str]]] = [[]];
    for tk in tokenize(text, lang_of(box_id)) {
        parts = tk[1].split("\n");
        for (i, part) in enumerate(parts) {
            if i > 0 {
                lines.append([]);
            }
            if part {
                lines[-1].append([tk[0], part]);
            }
        }
    }
    if lines and not lines[-1] {
        lines.pop();
    }
    return lines;
}

def:pub read_source_lines(token: str, box_id: str) -> list[list[list[str]]] {
    if not authorized(token) {
        return [];
    }
    return source_lines(box_id);
}

def:pub read_source_file(token: str, box_id: str) -> SourceFile {
    if not authorized(token) {
        return SourceFile(ok=False, error="unauthorized");
    }
    full = safe_path(box_id);
    if not full or not os.path.isfile(full) {
        return SourceFile(ok=False, error="Not a file in the project: " + box_id);
    }
    with open(full, encoding="utf-8", errors="replace", newline="") as fh {
        text = fh.read(MAX_SOURCE);
    }
    return SourceFile(path=box_id, text=text, mtime=os.path.getmtime(full), version=file_version(full));
}

def file_version(full: str) -> str {
    with open(full, "rb") as fh {
        return hashlib.sha1(fh.read()).hexdigest();
    }
}

"""Save an edited file atomically. Refuses (conflict) if it changed on disk since it was opened."""
def save_file(box_id: str, content: str, expected_version: str) -> SourceFile {
    full = safe_path(box_id);
    if not full or not os.path.isfile(full) {
        return SourceFile(ok=False, error="Not a file in the project: " + box_id);
    }
    current = file_version(full);
    if expected_version and current != expected_version {
        return SourceFile(ok=False, conflict=True, path=box_id, version=current, error="The file changed on disk after you opened it (the agent or another tool edited it). Reload to see the new version.");
    }
    mode = os.stat(full).st_mode & 0o777;
    (fd, tmp) = tempfile.mkstemp(prefix=".jac-smith-", dir=os.path.dirname(full));
    try {
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as fh {
            fh.write(content);
        }
        os.chmod(tmp, mode);
        os.replace(tmp, full);
    } except Exception as e {
        try { os.remove(tmp); } except OSError {}
        return SourceFile(ok=False, path=box_id, error="Save failed: " + str(e));
    }
    return SourceFile(ok=True, path=box_id, text="", mtime=os.path.getmtime(full), version=file_version(full));
}

def:pub write_source(token: str, box_id: str, content: str, expected_version: str = "") -> SourceFile {
    if not authorized(token) {
        return SourceFile(ok=False, error="unauthorized");
    }
    return save_file(box_id, content, expected_version);
}
