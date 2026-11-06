"""The architecture graph: boxes (project / package / module), externals, and the edges between them.

Built fresh on every index from the scanner output, then rolled up bottom-up by the Rollup walker
and snapshotted into plain wire objects (ProjectData) that the endpoints serve from.
"""
import os;
import sys;
import math;

import from indexer.model { BoxInfo, SymbolInfo, ExternalInfo }
import from indexer.scan { RawFile, RawImport }
import from indexer.roles { RoleJob, RoleAnswer, classify_modules }
import from indexer.archwire { wire_edges, WIRE_FILES }

node Box {
    has bid: str;
    has name: str;
    has path: str;
    has kind: str;
    has lang: str = "";
    has loc: int = 0;
    has files: int = 0;
    has self_score: float = 0.0;
    has score: float = 0.0;
    has fan_in: int = 0;
    has summary: str = "";
    has symbols: list[SymbolInfo] = [];
    has ext_ids: list[str] = [];
    has role: str = "";
    has tier: str = "";
    has role_confidence: float = 0.0;
    has role_source: str = "";
}

node External {
    has eid: str;
    has name: str;
    has ecosystem: str;
}

edge Contains: Box --> Box {}

edge Imports: Box --> Box {
    has count: int = 1;
}

edge Uses: Box --> External {
    has count: int = 1;
}

glob TIER_WEIGHT: dict[str, float] = {"CORE": 1.6, "SUPPORTING": 1.0, "PERIPHERAL": 0.55};
glob JAC_PACKAGES: set[str] = {"jaclang", "byllm", "jac_client", "jac_scale"};
glob NODE_BUILTINS: set[str] = {
    "fs", "path", "os", "http", "https", "url", "util", "events", "stream", "crypto",
    "child_process", "net", "tls", "zlib", "buffer", "process", "assert", "readline", "worker_threads"
};
glob JS_EXTS: list[str] = [".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".jac"];

"""Bottom-up aggregation. Exit abilities fire post-order, so every child is final before its parent."""
walker Rollup {
    can descend with Box entry {
        visit [->:Contains:->];
    }

    can gather with Box exit {
        kids = [here ->:Contains:->];
        if not kids {
            here.score = here.self_score;
            here.files = 1 if here.kind == "module" else 0;
            skip;
        }
        here.score = sum([k.score for k in kids]);
        here.loc = sum([k.loc for k in kids]);
        here.files = sum([k.files for k in kids]);
        ext: set[str] = set();
        votes: dict[str, float] = {};
        for k in kids {
            ext.update(k.ext_ids);
            if k.role {
                votes[k.role] = votes.get(k.role, 0.0) + k.score;
            }
        }
        here.ext_ids = sorted(ext);
        if votes {
            here.role = max(votes, key=lambda (r: str) -> float { votes[r] });
            here.role_confidence = votes[here.role] / max(float(sum(votes.values())), 1e-9);
            here.role_source = "rollup";
        }
    }
}

"""Everything the endpoints and the agent need, as plain objects (no live graph references)."""
obj ProjectData {
    has root_dir: str;
    has root_id: str = ".";
    has boxes: dict[str, BoxInfo] = {};
    has exts: dict[str, ExternalInfo] = {};
    has mod_deps: dict[str, dict[str, int]] = {};
    has mod_ext: dict[str, dict[str, int]] = {};
    has jev_classified: int = 0;
    has jev_cached: int = 0;
}

obj Resolver {
    has dotted: dict[str, str] = {};
    has paths: set[str] = set();
    has top_packages: set[str] = set();

    def register(rel: str) -> None {
        self.paths.add(rel);
        (stem, ext) = os.path.splitext(rel);
        if ext not in [".py", ".jac"] {
            return;
        }
        parts = stem.split("/");
        if parts[-1] == "__init__" {
            parts = parts[:-1];
        }
        offsets = [0];
        if parts and parts[0] in ["src", "lib"] and len(parts) > 1 {
            offsets.append(1);
        }
        for o in offsets {
            v = parts[o:];
            if not v {
                continue;
            }
            key = ".".join(v);
            if key not in self.dotted or rel.endswith("__init__.py") {
                self.dotted[key] = rel;
            }
            self.top_packages.add(v[0]);
            for i in range(1, len(v)) {
                pkg = ".".join(v[:i]);
                if pkg not in self.dotted {
                    self.dotted[pkg] = "/".join(parts[:o + i]);
                }
            }
        }
    }

    def _lookup(dotted: str) -> str {
        return self.dotted.get(dotted, "");
    }

    """Returns ("internal", box_id) or ("external", ecosystem:name) or ("", "")."""
    def resolve(rf: RawFile, imp: RawImport) -> tuple[str, str] {
        if imp.kind == "path" {
            return self._resolve_path(rf.rel, imp.target);
        }
        if imp.kind == "package" {
            return self._resolve_package(imp.target);
        }
        if imp.level > 0 {
            base = rf.rel.split("/")[:-1];
            up = imp.level - 1;
            if up > len(base) {
                return ("", "");
            }
            base = base[:len(base) - up];
            stem = base + ([p for p in imp.target.split(".") if p] if imp.target else []);
            for n in imp.names {
                hit = self._lookup(".".join(stem + [n]));
                if hit {
                    return ("internal", hit);
                }
            }
            hit = self._lookup(".".join(stem));
            return ("internal", hit) if hit else ("", "");
        }
        for n in imp.names {
            hit = self._lookup(imp.target + "." + n);
            if hit {
                return ("internal", hit);
            }
        }
        parts = imp.target.split(".");
        for i in range(len(parts), 0, -1) {
            hit = self._lookup(".".join(parts[:i]));
            if hit and (i == len(parts) or parts[0] in self.top_packages) {
                return ("internal", hit);
            }
        }
        top = parts[0];
        if not top {
            return ("", "");
        }
        if top in JAC_PACKAGES {
            return ("external", "jac:" + top);
        }
        if top in sys.stdlib_module_names {
            return ("external", "stdlib:" + top);
        }
        return ("external", "pypi:" + top);
    }

    def _resolve_package(name: str) -> tuple[str, str] {
        if name.startswith(".") {
            return ("", "");
        }
        parts = name.split("/");
        pkg = "/".join(parts[:2]) if name.startswith("@") else parts[0];
        if pkg.startswith("node:") or pkg in NODE_BUILTINS {
            return ("external", "node:" + pkg.replace("node:", ""));
        }
        if pkg.startswith("@jac/") {
            return ("external", "jac:" + pkg);
        }
        return ("external", "npm:" + pkg);
    }

    def _resolve_path(rel: str, target: str) -> tuple[str, str] {
        if not (target.startswith(".") or target.startswith("/")) {
            return self._resolve_package(target);
        }
        base = os.path.dirname(rel);
        cand = os.path.normpath(os.path.join(base, target)).replace(os.sep, "/");
        tries = [cand] + [cand + e for e in JS_EXTS] + [cand + "/index" + e for e in JS_EXTS];
        for t in tries {
            if t in self.paths {
                return ("internal", t);
            }
        }
        return ("", "");
    }
}

def _ensure_dir(boxes: dict[str, Box], dir_rel: str) -> Box {
    if dir_rel in boxes {
        return boxes[dir_rel];
    }
    parent_rel = os.path.dirname(dir_rel) or ".";
    parent = _ensure_dir(boxes, parent_rel);
    b = Box(bid=dir_rel, name=os.path.basename(dir_rel), path=dir_rel, kind="package");
    parent +>:Contains():+> b;
    boxes[dir_rel] = b;
    return b;
}

def ext_info(eid: str) -> ExternalInfo {
    (eco, name) = eid.split(":", 1);
    return ExternalInfo(id="ext:" + eid, name=name, ecosystem=eco);
}

def module_digest(b: Box, imports: list[str]) -> str {
    sigs = [s.signature for s in b.symbols if s.public][:14];
    lines = [
        "Summary: " + (b.summary or "(none)"),
        "Language: " + b.lang + ", " + str(b.loc) + " lines",
        "Interfaces: " + ("; ".join(sigs) if sigs else "(none)"),
        "Imports: " + (", ".join(imports[:16]) if imports else "(none)"),
        "Depended on by " + str(b.fan_in) + " other modules"
    ];
    return "\n".join(lines);
}

"""Build the graph from scanner output, classify roles, roll up, and snapshot."""
def build_project(root_dir: str, files: dict[str, RawFile], use_jev: bool) -> ProjectData {
    root_box = Box(bid=".", name=os.path.basename(os.path.abspath(root_dir)) or root_dir, path="", kind="project");
    boxes: dict[str, Box] = {".": root_box};
    exts: dict[str, External] = {};
    res = Resolver();
    for rel in files.keys() {
        res.register(rel);
    }

    for (rel, rf) in files.items() {
        parent = _ensure_dir(boxes, os.path.dirname(rel) or ".");
        m = Box(
            bid=rel, name=os.path.basename(rel), path=rel, kind="module", lang=rf.lang,
            loc=rf.loc, summary=rf.summary, symbols=rf.symbols
        );
        parent +>:Contains():+> m;
        boxes[rel] = m;
    }

    mod_deps: dict[str, dict[str, int]] = {};
    mod_ext: dict[str, dict[str, int]] = {};
    import_names: dict[str, list[str]] = {};
    for (rel, rf) in files.items() {
        deps: dict[str, int] = {};
        used: dict[str, int] = {};
        names: list[str] = [];
        for imp in rf.imports {
            (kind, target) = res.resolve(rf, imp);
            if kind == "internal" and target != rel and target in boxes {
                deps[target] = deps.get(target, 0) + 1;
                names.append(target);
            } elif kind == "external" {
                used[target] = used.get(target, 0) + 1;
                names.append(target.split(":", 1)[1]);
            }
        }
        m = boxes[rel];
        for (t, c) in deps.items() {
            m +>:Imports(count=c):+> boxes[t];
        }
        for (eid, c) in used.items() {
            if eid not in exts {
                info = ext_info(eid);
                exts[eid] = External(eid=info.id, name=info.name, ecosystem=info.ecosystem);
            }
            m +>:Uses(count=c):+> exts[eid];
        }
        m.ext_ids = sorted(["ext:" + e for e in used.keys()]);
        mod_deps[rel] = deps;
        mod_ext[rel] = {("ext:" + e): c for (e, c) in used.items()};
        import_names[rel] = names;
    }

    # projects using Jac's architecture wiring declare their imports centrally
    wire_files = [rel for rel in files.keys() if os.path.basename(rel) in WIRE_FILES];
    if wire_files {
        lookup = {k: v for (k, v) in res.dotted.items() if v in files};
        for (cons, provs) in wire_edges(root_dir, wire_files, lookup).items() {
            if cons not in boxes {
                continue;
            }
            deps = mod_deps.setdefault(cons, {});
            for (prov, n) in provs.items() {
                if prov in boxes and prov not in deps {
                    boxes[cons] +>:Imports(count=n):+> boxes[prov];
                    deps[prov] = n;
                    import_names.setdefault(cons, []).append(prov);
                }
            }
        }
    }

    modules = [b for b in boxes.values() if b.kind == "module"];
    for m in modules {
        m.fan_in = len([m <-:Imports:<-]);
    }

    jobs = [
        RoleJob(path=m.bid, digest=module_digest(m, import_names.get(m.bid, [])), lang=m.lang, fan_in=m.fan_in)
        for m in modules
    ];
    (answers, asked, cached) = classify_modules(jobs, use_jev);
    for m in modules {
        a = answers.get(m.bid);
        if a is not None {
            m.role = a.role;
            m.tier = a.tier;
            m.role_confidence = a.confidence;
            m.role_source = a.source;
        }
        public = len([s for s in m.symbols if s.public]);
        base = 1.0 + 0.6 * math.log2(1 + m.loc) + 1.5 * m.fan_in + 0.35 * min(public, 20);
        m.self_score = base * TIER_WEIGHT.get(m.tier, 1.0);
    }

    root_box spawn Rollup();

    max_module = max([m.score for m in modules] + [1e-9]);
    max_fan = max([m.fan_in for m in modules] + [1]);
    total = max(root_box.score, 1e-9);
    data = ProjectData(root_dir=os.path.abspath(root_dir), jev_classified=asked, jev_cached=cached);
    for b in boxes.values() {
        kids = [b ->:Contains:->];
        kids_sorted = sorted(kids, key=lambda (k: Box) -> float { -k.score });
        parent_ids = [p.bid for p in [b <-:Contains:<-]];
        data.boxes[b.bid] = BoxInfo(
            id=b.bid, name=b.name, path=b.path, kind=b.kind, lang=b.lang,
            parent=parent_ids[0] if parent_ids else "",
            children=[k.bid for k in kids_sorted],
            loc=b.loc, files=b.files, score=b.score,
            importance=(b.score / max_module) if b.kind == "module" else (b.score / total),
            centrality=b.fan_in / max_fan,
            fan_in=b.fan_in, role=b.role, tier=b.tier, role_confidence=b.role_confidence,
            role_source=b.role_source, summary=b.summary, symbols=b.symbols,
            externals=b.ext_ids,
            depends_on=sorted(mod_deps.get(b.bid, {}).keys())
        );
    }
    uses: dict[str, int] = {};
    for counts in mod_ext.values() {
        for (e, c) in counts.items() {
            uses[e] = uses.get(e, 0) + c;
        }
    }
    for e in exts.values() {
        data.exts[e.eid] = ExternalInfo(id=e.eid, name=e.name, ecosystem=e.ecosystem, uses=uses.get(e.eid, 0));
    }
    data.mod_deps = mod_deps;
    data.mod_ext = mod_ext;
    return data;
}
