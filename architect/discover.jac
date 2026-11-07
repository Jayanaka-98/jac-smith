"""Agentic architecture discovery and maintenance.

  1. Evidence   - the indexer's map: tree, key modules and their interfaces, README, libraries.
  2. Architect  - an agent proposes the domain architecture (for a compiler: its stages and the
                  passes inside them; for a web app: client, API, services, stores) as JSON.
                  Codex on the user's ChatGPT sign-in explores the repo itself; byLLM is the fallback.
  3. Map        - every module gets a component: the architect's path hints first, then directory
                  neighbours, then Jev (System One choice over the discovered components).
  4. Verify     - real imports between components are compared with the declared flows (drift).
  5. Maintain   - on every re-index only changed modules are re-mapped (Jev again); falling
                  coverage marks the architecture stale so the agent can re-discover it.
"""
import os;
import re;
import json;
import time;
import hashlib;
import tempfile;
import threading;
import subprocess;
import from datetime { datetime }

import from jaclang.byllm.lib { Model }
import from architect.model { ArchComponent, ArchFlow, ArchModel, ArchStep, ArchStatus, ModuleArch, ModNode, ModEdge, CompModules }
import from architect.jev { ChoiceJob, jev_choose_many }
import from indexer.api { current_project }
import from indexer.graph { ProjectData }
import from indexer.model { BoxInfo }
import from settings.credentials { APP_DIR, jev_key, read_config }
import from settings.chatgpt { codex_path, tool_env, login_status }
import from settings.session { authorized }

glob MAX_JEV_DISCOVER: int = 2500;
glob MAX_JEV_MAINTAIN: int = 150;
glob NONE_LABEL: str = "none";
glob GENERAL_LABEL: str = "general";
"""Path segments that mark code outside the product's architecture (decided without asking Jev)."""
glob OUTSIDE_DIRS: set[str] = {
    "test", "tests", "testing", "example", "examples", "sample", "samples", "benchmark", "benchmarks",
    "bench", "fixture", "fixtures", "docs", "doc", "scripts", "vendor", "third_party", "generated", "demo", "demos"
};

def is_outside(rel: str) -> bool {
    parts = rel.split("/");
    base = parts[-1];
    if base.startswith("test_") or "_test." in base or ".test." in base or ".spec." in base {
        return True;
    }
    return any([seg.lower() in OUTSIDE_DIRS for seg in parts[:-1]]);
}

glob KINDS: list[str] = ["stage", "component", "service", "store", "interface", "runtime", "library", "tooling", "ui"];
glob STYLES: list[str] = ["pipeline", "layered", "client-server", "plugin", "microservices", "event-driven", "library", "monolith"];

# ---------------------------------------------------------------- proposal (byLLM fallback)

obj ProposedComponent {
    has id: str;
    has name: str;
    has kind: str;
    has summary: str;
    has paths: list[str];
    has order: int;
    has parent: str;
}
sem ProposedComponent.id = "Short lowercase slug, unique";
sem ProposedComponent.kind = "One of: stage, component, service, store, interface, runtime, library, tooling, ui";
sem ProposedComponent.paths = "Project-relative directory or file paths that implement this component";
sem ProposedComponent.order = "Position in the pipeline for stages (1, 2, 3...), 0 otherwise";
sem ProposedComponent.parent = "id of the enclosing component for sub-components (e.g. a pass inside a stage), empty for top level";

obj ProposedFlow {
    has src: str;
    has dst: str;
    has label: str;
}
sem ProposedFlow.label = "What moves between the two components, in domain terms (e.g. 'AST', 'typed IR', 'HTTP request')";

obj ArchProposal {
    has system_kind: str;
    has style: str;
    has title: str;
    has summary: str;
    has components: list[ProposedComponent];
    has flows: list[ProposedFlow];
}
sem ArchProposal.system_kind = "What the system is, e.g. 'compiler', 'web application', 'CLI tool'";
sem ArchProposal.style = "One of: pipeline, layered, client-server, plugin, microservices, event-driven, library, monolith";

glob arch_llm: Model = Model(model_name="gpt-4o-mini");
glob _arch_model_name: str = "";

def propose_architecture(evidence: str) -> ArchProposal by arch_llm(temperature=0.2, max_output_retries=2);
sem propose_architecture = "You are a software architect. From the evidence about a code base, describe its real architecture in domain language: what kind of system it is, its 4-12 major components (for a pipeline such as a compiler: the ordered stages; add sub-components for the important internal structure such as passes), and the flows between them. Map every component to the paths that implement it.";
sem propose_architecture.evidence = "Index of the project: tree, key modules with interfaces, README, libraries";

# ---------------------------------------------------------------- schema + prompt for Codex

glob ARCH_SCHEMA: dict[str, any] = {
    "type": "object",
    "additionalProperties": False,
    "required": ["system_kind", "style", "title", "summary", "components", "flows"],
    "properties": {
        "system_kind": {"type": "string"},
        "style": {"type": "string", "enum": STYLES},
        "title": {"type": "string"},
        "summary": {"type": "string"},
        "components": {
            "type": "array",
            "items": {
                "type": "object",
                "additionalProperties": False,
                "required": ["id", "name", "kind", "summary", "paths", "order", "parent"],
                "properties": {
                    "id": {"type": "string"},
                    "name": {"type": "string"},
                    "kind": {"type": "string", "enum": KINDS},
                    "summary": {"type": "string"},
                    "paths": {"type": "array", "items": {"type": "string"}},
                    "order": {"type": "integer"},
                    "parent": {"type": "string"}
                }
            }
        },
        "flows": {
            "type": "array",
            "items": {
                "type": "object",
                "additionalProperties": False,
                "required": ["src", "dst", "label"],
                "properties": {
                    "src": {"type": "string"},
                    "dst": {"type": "string"},
                    "label": {"type": "string"}
                }
            }
        }
    }
};

def _codex_prompt(evidence: str) -> str {
    return "\n".join([
        "You are the architecture agent of jac smith, an architecture-first IDE.",
        "Figure out the REAL architecture of the repository in the working directory, in the language of its domain.",
        "For a compiler that means its stages (e.g. lexing/parsing, AST, semantic passes, IR, code generation, runtime) and the passes inside them;",
        "for a web app: client, API, services, data stores, integrations; for a library: its core abstractions and extension points.",
        "Do not describe the folder layout - describe what the system does and how data moves through it.",
        "",
        "Rules:",
        "- 4 to 12 top-level components. Give sub-components (parent = the enclosing component id) where a component has meaningful internal structure, e.g. the passes of a compiler stage. At most 40 components in total.",
        "- ids: short lowercase slugs, unique. order: 1..n for pipeline stages in execution order, 0 otherwise.",
        "- paths: project-relative directories or files that implement the component. They must exist. Be specific for sub-components.",
        "- flows: src/dst are component ids; label says what moves (e.g. 'source text', 'UniTree AST', 'Python bytecode', 'REST calls').",
        "- Explore the code (read-only) to confirm; the index below is a head start, not ground truth.",
        "",
        "Index of the project:",
        evidence
    ]);
}

# ---------------------------------------------------------------- helpers

def project_key(root_dir: str) -> str {
    return hashlib.sha1(os.path.realpath(root_dir).encode("utf-8")).hexdigest()[:12];
}

def store_path(root_dir: str) -> str {
    return os.path.join(APP_DIR, "projects", project_key(root_dir), "architecture.json");
}

def load_stored(root_dir: str) -> dict[str, any] | None {
    try {
        with open(store_path(root_dir), encoding="utf-8") as fh {
            data = json.load(fh);
        }
        return data if isinstance(data, dict) else None;
    } except (OSError, ValueError) {
        return None;
    }
}

def save_stored(root_dir: str, data: dict[str, any]) -> None {
    path = store_path(root_dir);
    os.makedirs(os.path.dirname(path), exist_ok=True);
    (fd, tmp) = tempfile.mkstemp(prefix="architecture-", suffix=".tmp", dir=os.path.dirname(path));
    with os.fdopen(fd, "w", encoding="utf-8") as fh {
        json.dump(data, fh, indent=1);
    }
    os.replace(tmp, path);
}

def _slug(text: str) -> str {
    s = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-");
    return s[:40] or "c";
}

def _modules(p: ProjectData) -> list[BoxInfo] {
    return [b for b in p.boxes.values() if b.kind == "module"];
}

def module_text(p: ProjectData, b: BoxInfo) -> str {
    sigs = [s.signature for s in b.symbols if s.public][:10];
    users = b.fan_in;
    deps = list(p.mod_deps.get(b.id, {}).keys())[:12];
    ext = [e.replace("ext:", "").split(":", 1)[-1] for e in b.externals[:10]];
    return "\n".join([
        "Module: " + b.id,
        "Summary: " + (b.summary or "(no docstring)"),
        "Interfaces: " + ("; ".join(sigs) if sigs else "(none)"),
        "Imports from project: " + (", ".join(deps) if deps else "(none)"),
        "Libraries: " + (", ".join(ext) if ext else "(none)"),
        "Used by " + str(users) + " modules; " + str(b.loc) + " lines"
    ]);
}

def module_hash(p: ProjectData, b: BoxInfo) -> str {
    return hashlib.sha1(module_text(p, b).encode("utf-8")).hexdigest()[:16];
}

def build_evidence(p: ProjectData) -> str {
    lines: list[str] = [];
    rootb = p.boxes[p.root_id];
    lines.append("Project: " + rootb.name + " (" + str(rootb.files) + " source files, " + str(rootb.loc) + " lines)");
    for name in ["README.md", "readme.md", "README.rst", "README"] {
        rp = os.path.join(p.root_dir, name);
        if os.path.isfile(rp) {
            with open(rp, encoding="utf-8", errors="replace") as fh {
                lines.append("\nREADME (excerpt):\n" + fh.read(3500));
            }
            break;
        }
    }
    lines.append("\nTree (packages, depth <= 4):");
    def walk(bid: str, depth: int) {
        b = p.boxes[bid];
        if b.kind == "package" {
            lines.append("  " * depth + b.path + "/  [" + str(b.files) + " modules, " + str(b.loc) + " loc]");
        }
        if depth < 4 {
            for c in b.children {
                if p.boxes[c].kind == "package" {
                    walk(c, depth + 1);
                }
            }
        }
    }
    for c in rootb.children {
        walk(c, 0);
    }
    mods = sorted(_modules(p), key=lambda (b: BoxInfo) -> float { -b.score })[:45];
    lines.append("\nMost important modules:");
    for b in mods {
        sigs = [s.signature for s in b.symbols if s.public][:5];
        lines.append("- " + b.id + " (" + str(b.loc) + " loc, used by " + str(b.fan_in) + ")" + ((": " + b.summary) if b.summary else ""));
        if sigs {
            lines.append("    " + "; ".join(sigs)[:300]);
        }
    }
    exts = sorted(p.exts.values(), key=lambda (e: any) -> int { -e.uses })[:25];
    lines.append("\nLibraries used: " + ", ".join([e.name + " (" + e.ecosystem + ")" for e in exts]));
    return "\n".join(lines)[:30000];
}

def _valid_path(p: ProjectData, path: str) -> str {
    q = path.strip().strip("/");
    if q.startswith("./") {
        q = q[2:];
    }
    if not q or q == "." {
        return "";
    }
    if q in p.boxes {
        return q;
    }
    for bid in p.boxes.keys() {
        if bid.startswith(q + "/") {
            return q;
        }
    }
    return "";
}

"""Normalise an architect proposal: unique ids, valid parents and flows, existing paths only."""
def normalise(p: ProjectData, raw: dict[str, any]) -> dict[str, any] {
    comps: list[dict[str, any]] = [];
    seen: dict[str, str] = {};
    for c in (raw.get("components") or [])[:40] {
        cid = _slug(str(c.get("id") or c.get("name") or "c"));
        base = cid;
        n = 2;
        while cid in seen {
            cid = base + "-" + str(n);
            n += 1;
        }
        seen[str(c.get("id") or cid)] = cid;
        kind = str(c.get("kind") or "component");
        comps.append({
            "id": cid,
            "name": str(c.get("name") or cid),
            "kind": kind if kind in KINDS else "component",
            "summary": str(c.get("summary") or ""),
            "paths": [q for q in [_valid_path(p, str(x)) for x in (c.get("paths") or [])] if q],
            "order": int(c.get("order") or 0),
            "parent": str(c.get("parent") or "")
        });
    }
    ids = {c["id"] for c in comps};
    for c in comps {
        par = seen.get(c["parent"], _slug(c["parent"])) if c["parent"] else "";
        c["parent"] = par if par in ids and par != c["id"] else "";
    }
    flows: list[dict[str, any]] = [];
    for f in raw.get("flows") or [] {
        s = seen.get(str(f.get("src") or ""), "");
        d = seen.get(str(f.get("dst") or ""), "");
        if s and d and s != d {
            flows.append({"src": s, "dst": d, "label": str(f.get("label") or "")});
        }
    }
    style = str(raw.get("style") or "monolith");
    return {
        "system_kind": str(raw.get("system_kind") or ""),
        "style": style if style in STYLES else "monolith",
        "title": str(raw.get("title") or ""),
        "summary": str(raw.get("summary") or ""),
        "components": comps,
        "flows": flows
    };
}

# ---------------------------------------------------------------- architect engines

def propose_with_codex(p: ProjectData, evidence: str) -> tuple[dict[str, any] | None, str] {
    cx = codex_path();
    if not cx {
        return (None, "Codex CLI not installed");
    }
    (signed_in, _) = login_status();
    if not signed_in {
        return (None, "not signed in to ChatGPT");
    }
    (sfd, schema_file) = tempfile.mkstemp(prefix="jac-smith-arch-schema-", suffix=".json");
    os.close(sfd);
    (ofd, out_file) = tempfile.mkstemp(prefix="jac-smith-arch-", suffix=".json");
    os.close(ofd);
    with open(schema_file, "w", encoding="utf-8") as fh {
        json.dump(ARCH_SCHEMA, fh);
    }
    try {
        r = subprocess.run(
            [cx, "exec", "--skip-git-repo-check", "--ephemeral", "--color", "never",
             "-C", p.root_dir, "-s", "read-only", "--output-schema", schema_file, "-o", out_file, "-"],
            input=_codex_prompt(evidence), capture_output=True, text=True, timeout=1200,
            cwd=p.root_dir, env=tool_env()
        );
        with open(out_file, encoding="utf-8", errors="replace") as fh {
            text = fh.read().strip();
        }
    } except subprocess.TimeoutExpired {
        return (None, "Codex timed out");
    } finally {
        for f in [schema_file, out_file] {
            try { os.remove(f); } except OSError {}
        }
    }
    if not text {
        return (None, "Codex returned nothing: " + ((r.stderr or "") + (r.stdout or "")).strip()[-400:]);
    }
    m = re.search(r"\{.*\}", text, re.S);
    try {
        return (json.loads(m.group(0) if m else text), "");
    } except ValueError as e {
        return (None, "Codex output was not JSON: " + str(e));
    }
}

def propose_with_llm(evidence: str) -> tuple[dict[str, any] | None, str] {
    name = str(read_config().get("agent_model", "") or "gpt-4o-mini");
    if name != _arch_model_name {
        arch_llm = Model(model_name=name);
        _arch_model_name = name;
    }
    try {
        prop = propose_architecture(evidence);
    } except Exception as e {
        return (None, "LLM architect failed: " + str(e));
    }
    return ({
        "system_kind": prop.system_kind, "style": prop.style, "title": prop.title, "summary": prop.summary,
        "components": [
            {"id": c.id, "name": c.name, "kind": c.kind, "summary": c.summary, "paths": c.paths, "order": c.order, "parent": c.parent}
            for c in prop.components
        ],
        "flows": [{"src": f.src, "dst": f.dst, "label": f.label} for f in prop.flows]
    }, "");
}

# ---------------------------------------------------------------- mapping

def _children_of(comps: list[dict[str, any]]) -> dict[str, list[dict[str, any]]] {
    out: dict[str, list[dict[str, any]]] = {};
    for c in comps {
        out.setdefault(c["parent"], []).append(c);
    }
    return out;
}

def _path_match(comps: list[dict[str, any]], rel: str) -> str {
    best = "";
    best_len = -1;
    for c in comps {
        for q in c["paths"] {
            if (rel == q or rel.startswith(q + "/")) and len(q) > best_len {
                best = c["id"];
                best_len = len(q);
            }
        }
    }
    return best;
}

def _criteria(options: list[dict[str, any]], with_none: bool, general_of: str = "") -> dict[str, str] {
    crit: dict[str, str] = {};
    for c in options[:24] {
        crit[c["id"]] = c["name"] + ": " + c["summary"];
    }
    if general_of {
        crit[GENERAL_LABEL] = "General code of " + general_of + " not specific to one of the parts above";
    }
    if with_none {
        crit[NONE_LABEL] = "Not part of any listed component: tests, examples, fixtures, benchmarks, scripts, vendored or generated code";
    }
    return crit;
}

"""Assign modules to components. `todo` limits the work to those module ids (maintenance)."""
def map_modules(
    p: ProjectData, arch: dict[str, any], previous: dict[str, dict[str, any]], todo: list[str], jev_cap: int
) -> tuple[dict[str, dict[str, any]], int] {
    comps = arch["components"];
    kids = _children_of(comps);
    by_id = {c["id"]: c for c in comps};
    out: dict[str, dict[str, any]] = {k: v for (k, v) in previous.items() if k in p.boxes};
    hashes = {m: module_hash(p, p.boxes[m]) for m in todo};
    title = arch.get("title") or arch.get("system_kind") or "this project";
    instr = "Which architectural component of " + str(title) + " does this module belong to?";

    pending: list[str] = [];
    refine: list[tuple[str, str]] = [];
    for m in todo {
        hit = _path_match(comps, m);
        if hit and hit in kids {
            refine.append((m, hit));
        } elif hit {
            out[m] = {"component": hit, "source": "paths", "confidence": 1.0, "hash": hashes[m]};
        } else {
            pending.append(m);
        }
    }

    # directory neighbours: a module whose directory is dominated by one component joins it
    by_dir: dict[str, dict[str, int]] = {};
    for (m, a) in out.items() {
        if a["component"] and a["component"] != NONE_LABEL {
            d = os.path.dirname(m);
            by_dir.setdefault(d, {})[a["component"]] = by_dir.get(d, {}).get(a["component"], 0) + 1;
        }
    }
    still: list[str] = [];
    for m in pending {
        if is_outside(m) {
            out[m] = {"component": NONE_LABEL, "source": "rules", "confidence": 1.0, "hash": hashes[m]};
            continue;
        }
        # vote in the module's directory, then its ancestors, until a clear majority appears
        d = os.path.dirname(m);
        placed = False;
        for depth in range(3) {
            votes: dict[str, int] = {};
            for (dd, counts) in by_dir.items() {
                if dd == d or (depth > 0 and dd.startswith(d + "/")) {
                    for (k, v) in counts.items() {
                        votes[k] = votes.get(k, 0) + v;
                    }
                }
            }
            total = sum(votes.values());
            if total >= 3 {
                top = max(votes, key=lambda (k: str) -> int { votes[k] });
                share = votes[top] / total;
                if share >= 0.6 {
                    out[m] = {"component": top, "source": "neighbors", "confidence": round(0.8 * share * (0.9 ** depth), 3), "hash": hashes[m]};
                    placed = True;
                }
                break;
            }
            if not d {
                break;
            }
            d = os.path.dirname(d);
        }
        if not placed {
            still.append(m);
        }
    }

    jev_used = 0;
    if jev_key() {
        tops = [c for c in comps if not c["parent"]];
        jobs: list[ChoiceJob] = [];
        for m in still[:jev_cap] {
            jobs.append(ChoiceJob(key=m, state=module_text(p, p.boxes[m]), instructions=instr, criteria=_criteria(tops, True)));
        }
        for (m, par) in refine[:max(jev_cap - len(jobs), 0)] {
            jobs.append(ChoiceJob(
                key=m, state=module_text(p, p.boxes[m]),
                instructions="Which part of " + by_id[par]["name"] + " does this module implement?",
                criteria=_criteria(kids[par], False, by_id[par]["name"])
            ));
        }
        answers = jev_choose_many(jobs);
        jev_used = len(jobs);
        second: list[ChoiceJob] = [];
        for (m, a) in answers.items() {
            if a.error or not a.choice {
                continue;
            }
            if a.choice == NONE_LABEL {
                out[m] = {"component": NONE_LABEL, "source": "jev", "confidence": a.confidence, "hash": hashes[m]};
            } elif a.choice == GENERAL_LABEL {
                owners = [r for (mm, r) in refine if mm == m];
                if owners {
                    out[m] = {"component": owners[0], "source": "jev", "confidence": a.confidence, "hash": hashes[m]};
                }
            } elif a.choice in by_id {
                out[m] = {"component": a.choice, "source": "jev", "confidence": a.confidence, "hash": hashes[m]};
                if a.choice in kids and jev_used + len(second) < jev_cap {
                    second.append(ChoiceJob(
                        key=m, state=module_text(p, p.boxes[m]),
                        instructions="Which part of " + by_id[a.choice]["name"] + " does this module implement?",
                        criteria=_criteria(kids[a.choice], False, by_id[a.choice]["name"])
                    ));
                }
            }
        }
        for (m, a) in jev_choose_many(second).items() {
            jev_used += 1;
            if not a.error and a.choice in by_id {
                out[m] = {"component": a.choice, "source": "jev", "confidence": round(min(a.confidence, out[m]["confidence"]), 3), "hash": hashes[m]};
            }
        }
    }
    # whatever is left after the cap: paths-refine falls back to the parent, others stay unassigned
    for (m, par) in refine {
        if m not in out or out[m].get("hash") != hashes[m] {
            out[m] = {"component": par, "source": "paths", "confidence": 0.7, "hash": hashes[m]};
        }
    }
    return (out, jev_used);
}

# ---------------------------------------------------------------- verification + model

def _ancestors(by_id: dict[str, dict[str, any]], cid: str) -> list[str] {
    chain: list[str] = [];
    cur = cid;
    while cur and cur in by_id and cur not in chain {
        chain.append(cur);
        cur = by_id[cur]["parent"];
    }
    return chain;
}

def build_model(p: ProjectData, stored: dict[str, any]) -> ArchModel {
    arch = stored["arch"];
    assign: dict[str, dict[str, any]] = stored.get("assignments", {});
    comps = arch["components"];
    by_id = {c["id"]: c for c in comps};
    kids = _children_of(comps);
    mods = _modules(p);
    comp_of = {m: a["component"] for (m, a) in assign.items() if a.get("component") in by_id};

    count: dict[str, int] = {};
    loc: dict[str, int] = {};
    conf_sum: dict[str, float] = {};
    conf_n: dict[str, int] = {};
    jev_n: dict[str, int] = {};
    members: dict[str, list[BoxInfo]] = {};
    for (m, cid) in comp_of.items() {
        b = p.boxes.get(m);
        if b is None {
            continue;
        }
        a = assign[m];
        conf_sum[cid] = conf_sum.get(cid, 0.0) + float(a.get("confidence", 0.0));
        conf_n[cid] = conf_n.get(cid, 0) + 1;
        if a.get("source") == "jev" {
            jev_n[cid] = jev_n.get(cid, 0) + 1;
        }
        for anc in _ancestors(by_id, cid) {
            count[anc] = count.get(anc, 0) + 1;
            loc[anc] = loc.get(anc, 0) + b.loc;
            members.setdefault(anc, []).append(b);
        }
    }

    observed: dict[tuple[str, str], int] = {};
    for (m, deps) in p.mod_deps.items() {
        cm = comp_of.get(m, "");
        if not cm {
            continue;
        }
        for (t, n) in deps.items() {
            ct = comp_of.get(t, "");
            if not ct or ct == cm {
                continue;
            }
            a_chain = list(reversed(_ancestors(by_id, cm)));
            b_chain = list(reversed(_ancestors(by_id, ct)));
            i = 0;
            while i < len(a_chain) and i < len(b_chain) and a_chain[i] == b_chain[i] {
                i += 1;
            }
            if i < len(a_chain) and i < len(b_chain) {
                key = (a_chain[i], b_chain[i]);
                observed[key] = observed.get(key, 0) + n;
            }
        }
    }
    flows: list[ArchFlow] = [];
    declared_keys: set[tuple[str, str]] = set();
    for f in arch["flows"] {
        key = (f["src"], f["dst"]);
        declared_keys.add(key);
        flows.append(ArchFlow(src=f["src"], dst=f["dst"], label=f["label"], declared=True, observed=observed.get(key, 0)));
    }
    noise = 1 if len(mods) < 300 else 2;
    undeclared = sorted(
        [(k, v) for (k, v) in observed.items() if k not in declared_keys and (k[1], k[0]) not in declared_keys and v >= noise],
        key=lambda (kv: tuple[tuple[str, str], int]) -> int { -kv[1] }
    );
    for ((s, d), v) in undeclared[:30] {
        flows.append(ArchFlow(src=s, dst=d, label="", declared=False, observed=v));
    }
    drift: list[str] = [];
    for ((s, d), v) in undeclared[:6] {
        drift.append(by_id[s]["name"] + " imports " + by_id[d]["name"] + " (" + str(v) + (" import" if v == 1 else " imports") + ") but the architecture declares no such flow");
    }

    total = len(mods);
    none_n = len([m for (m, a) in assign.items() if a.get("component") == NONE_LABEL and m in p.boxes]);
    assigned = len([m for m in comp_of.keys() if m in p.boxes]);
    in_scope = max(total - none_n, 1);
    unassigned = [b.id for b in mods if b.id not in assign];
    coverage = assigned / in_scope;
    stale = False;
    reason = "";
    if coverage < 0.5 {
        stale = True;
        reason = "Only " + str(round(coverage * 100)) + "% of modules fit the current architecture";
    } elif len(unassigned) > max(8.0, 0.2 * total) {
        stale = True;
        reason = str(len(unassigned)) + " modules are not mapped yet";
    }

    components: list[ArchComponent] = [];
    for c in comps {
        tops = sorted(members.get(c["id"], []), key=lambda (b: BoxInfo) -> float { -b.score })[:12];
        n = conf_n.get(c["id"], 0);
        components.append(ArchComponent(
            id=c["id"], name=c["name"], kind=c["kind"], summary=c["summary"], paths=c["paths"],
            order=c["order"], parent=c["parent"], children=[k["id"] for k in kids.get(c["id"], [])],
            module_count=count.get(c["id"], 0), loc=loc.get(c["id"], 0),
            confidence=round(conf_sum.get(c["id"], 0.0) / n, 3) if n else 0.0,
            jev_mapped=jev_n.get(c["id"], 0), top_modules=[b.id for b in tops]
        ));
    }
    return ArchModel(
        ok=True, exists=True, project=p.root_dir, system_kind=arch["system_kind"], style=arch["style"],
        title=arch["title"], summary=arch["summary"], components=components, flows=flows,
        coverage=round(coverage, 3), modules_total=total, unassigned=len(unassigned),
        unassigned_sample=unassigned[:12], drift=drift, stale=stale, stale_reason=reason,
        generated_by=str(stored.get("generated_by", "")), mapped_by=str(stored.get("mapped_by", "")),
        updated_at=str(stored.get("updated_at", ""))
    );
}

"""Bring a stored architecture up to date with the current index: re-map changed/new modules."""
def maintain(p: ProjectData) -> ArchModel {
    found = load_stored(p.root_dir);
    if found is None {
        return ArchModel(ok=True, exists=False, project=p.root_dir);
    }
    stored: dict[str, any] = found;
    assign: dict[str, dict[str, any]] = stored.get("assignments", {});
    current = {b.id: b for b in _modules(p)};
    todo = [m for (m, b) in current.items() if m not in assign or assign[m].get("hash") != module_hash(p, b)];
    removed = [m for m in assign.keys() if m not in current];
    if todo or removed {
        for m in removed {
            assign.pop(m, None);
        }
        (assign, used) = map_modules(p, stored["arch"], assign, todo, MAX_JEV_MAINTAIN);
        stored["assignments"] = assign;
        stored["updated_at"] = datetime.now().isoformat(timespec="seconds");
        stored["maintained"] = int(stored.get("maintained", 0)) + 1;
        save_stored(p.root_dir, stored);
    }
    return build_model(p, stored);
}

"""Map every module the stored architecture has not placed yet (full Jev budget)."""
def refine(p: ProjectData) -> ArchModel {
    found = load_stored(p.root_dir);
    if found is None {
        return ArchModel(ok=True, exists=False, project=p.root_dir);
    }
    stored: dict[str, any] = found;
    assign: dict[str, dict[str, any]] = stored.get("assignments", {});
    todo = [b.id for b in _modules(p) if b.id not in assign];
    (assign, used) = map_modules(p, stored["arch"], assign, todo, MAX_JEV_DISCOVER);
    stored["assignments"] = assign;
    stored["mapped_by"] = "Jev" if used or stored.get("mapped_by") == "Jev" else stored.get("mapped_by", "paths");
    stored["updated_at"] = datetime.now().isoformat(timespec="seconds");
    save_stored(p.root_dir, stored);
    return build_model(p, stored);
}

def module_component(p: ProjectData, module: str) -> ModuleArch {
    found = load_stored(p.root_dir);
    if found is None {
        return ModuleArch(module=module);
    }
    stored: dict[str, any] = found;
    a = stored.get("assignments", {}).get(module);
    by_id = {c["id"]: c for c in stored["arch"]["components"]};
    if not a or a.get("component") not in by_id {
        return ModuleArch(module=module, source=str(a.get("source", "")) if a else "");
    }
    c = by_id[a["component"]];
    owner = by_id.get(c["parent"]);
    return ModuleArch(
        module=module, component=c["id"], component_name=c["name"],
        parent_name=owner["name"] if owner else "", source=str(a.get("source", "")),
        confidence=float(a.get("confidence", 0.0))
    );
}

"""Plain-text architecture for agents."""
def describe_architecture(p: ProjectData) -> str {
    model = maintain(p);
    if not model.exists {
        return "No architecture has been discovered for this project yet.";
    }
    by_id = {c.id: c for c in model.components};
    lines = [model.title + " - " + model.system_kind + " (" + model.style + ")", model.summary, ""];
    def emit(parent: str, depth: int) {
        level = [c for c in model.components if c.parent == parent];
        level = sorted(level, key=lambda (c: ArchComponent) -> int { c.order if c.order > 0 else 999 });
        for c in level {
            stage = ("stage " + str(c.order) + ", ") if c.order > 0 else "";
            lines.append("    " * depth + "- " + c.name + " [" + stage + c.kind + "] " + str(c.module_count) + " modules: " + c.summary + (" (paths: " + ", ".join(c.paths[:4]) + ")" if c.paths else ""));
            emit(c.id, depth + 1);
        }
    }
    emit("", 0);
    lines.append("");
    for f in model.flows {
        if f.declared and f.src in by_id and f.dst in by_id {
            lines.append(by_id[f.src].name + " -> " + by_id[f.dst].name + ": " + f.label);
        }
    }
    if model.drift {
        lines.append("\nDrift: " + "; ".join(model.drift));
    }
    return "\n".join(lines);
}

# ---------------------------------------------------------------- background discovery job

glob _status: ArchStatus = ArchStatus();
glob _job_lock: any = threading.Lock();

def _step(i: int, state: str, detail: str = "") -> None {
    _status.steps[i].state = state;
    if detail {
        _status.steps[i].detail = detail;
    }
}

def _pick_engine(requested: str) -> str {
    if requested in ["hybrid", "jev", "codex", "llm"] {
        return requested;
    }
    if jev_key() {
        return "hybrid";
    }
    if codex_path() and login_status()[0] {
        return "codex";
    }
    return "llm";
}

def run_hybrid_job(p: ProjectData, refine: bool, namer: str) -> None {
    import from architect.hybrid { run_hybrid }
    def step(i: int, state: str, detail: str) {
        _step(i, state, detail);
    }
    try {
        run_hybrid(p, step, refine, namer);
        _status.ok = True;
    } except Exception as e {
        for st in _status.steps {
            if st.state == "active" {
                st.state = "error";
                st.detail = str(e)[:300];
            }
        }
        _status.ok = False;
        _status.error = str(e)[:500];
    }
    _status.running = False;
    _status.done = True;
}

def run_discovery(p: ProjectData, engine: str) -> None {
    try {
        _step(0, "active");
        evidence = build_evidence(p);
        _step(0, "done", str(len(_modules(p))) + " modules, " + str(len(evidence)) + " chars of evidence");

        _step(1, "active", "Codex is exploring the repository" if engine == "codex" else "byLLM architect is reading the index");
        (raw, err) = propose_with_codex(p, evidence) if engine == "codex" else propose_with_llm(evidence);
        if raw is None and engine == "codex" {
            _step(1, "active", err + " - falling back to byLLM");
            (raw, err) = propose_with_llm(evidence);
            engine = "llm";
        }
        if raw is None {
            raise Exception(err);
        }
        arch = normalise(p, raw);
        if len(arch["components"]) < 2 {
            raise Exception("the architect returned fewer than two components");
        }
        _status.engine = engine;
        _step(1, "done", arch["system_kind"] + " · " + arch["style"] + " · " + str(len(arch["components"])) + " components");

        _step(2, "active", "path hints, directory neighbours, then Jev");
        mods = [b.id for b in _modules(p)];
        (assign, used) = map_modules(p, arch, {}, mods, MAX_JEV_DISCOVER);
        _step(2, "done", str(len(assign)) + " of " + str(len(mods)) + " modules mapped · " + str(used) + " Jev decisions");

        _step(3, "active");
        stored = {
            "arch": arch, "assignments": assign,
            "generated_by": "codex (ChatGPT)" if engine == "codex" else "byLLM (" + _arch_model_name + ")",
            "mapped_by": "Jev" if used else "paths",
            "updated_at": datetime.now().isoformat(timespec="seconds"),
            "generated_at": datetime.now().isoformat(timespec="seconds")
        };
        model = build_model(p, stored);
        _step(3, "done", str(round(model.coverage * 100)) + "% coverage · " + str(len(model.drift)) + " drift findings");

        _step(4, "active");
        save_stored(p.root_dir, stored);
        _step(4, "done", store_path(p.root_dir).replace(os.path.expanduser("~"), "~"));
        _status.ok = True;
    } except Exception as e {
        for s in _status.steps {
            if s.state == "active" {
                s.state = "error";
                s.detail = str(e)[:300];
            }
        }
        _status.ok = False;
        _status.error = str(e)[:500];
    }
    _status.running = False;
    _status.done = True;
}

def current_status() -> ArchStatus {
    return _status;
}

def start_discovery(engine: str = "") -> ArchStatus {
    p = current_project();
    if p is None {
        return ArchStatus(ok=False, error="No project open");
    }
    with _job_lock {
        if _status.running {
            return _status;
        }
        chosen = _pick_engine(engine);
        if chosen in ["hybrid", "jev"] {
            import from architect.hybrid { namer_available }
            namer = str(read_config().get("arch_namer", "codex") or "codex");
            refine = chosen == "hybrid" and namer != "none" and namer_available(namer);
            _status = ArchStatus(
                running=True, done=False, engine=chosen, started_at=time.time(),
                steps=[
                    ArchStep(label="Find subsystems in the code map"),
                    ArchStep(label="Jev · identify the kind of system"),
                    ArchStep(label="Jev · place every subsystem in the architecture"),
                    ArchStep(label="Show the skeleton"),
                    ArchStep(label=(namer.capitalize() + " · name and refine in the project's vocabulary") if refine else ("Naming skipped (" + namer + " unavailable)" if namer != "none" else "Naming skipped (Jev only)")),
                    ArchStep(label="Map modules and verify flows against imports"),
                    ArchStep(label="Save and keep maintained")
                ]
            );
            threading.Thread(target=run_hybrid_job, args=(p, refine, namer), daemon=True).start();
            return _status;
        }
        _status = ArchStatus(
            running=True, done=False, engine=chosen, started_at=time.time(),
            steps=[
                ArchStep(label="Collect evidence from the index"),
                ArchStep(label="Architect agent (" + ("Codex · ChatGPT" if chosen == "codex" else "byLLM") + ")"),
                ArchStep(label="Map modules to components (Jev)"),
                ArchStep(label="Verify flows against real imports"),
                ArchStep(label="Save and keep maintained")
            ]
        );
        threading.Thread(target=run_discovery, args=(p, chosen), daemon=True).start();
    }
    return _status;
}

# ---------------------------------------------------------------- endpoints

def:pub arch_get(token: str) -> ArchModel {
    if not authorized(token) {
        return ArchModel(ok=False, error="unauthorized");
    }
    p = current_project();
    if p is None {
        return ArchModel(ok=False, error="No project open");
    }
    try {
        return maintain(p);
    } except Exception as e {
        return ArchModel(ok=False, error="Could not load the architecture: " + str(e));
    }
}

def:pub arch_discover(token: str, engine: str = "") -> ArchStatus {
    if not authorized(token) {
        return ArchStatus(ok=False, error="unauthorized");
    }
    return start_discovery(engine);
}

def:pub arch_refine(token: str) -> ArchModel {
    if not authorized(token) {
        return ArchModel(ok=False, error="unauthorized");
    }
    p = current_project();
    if p is None {
        return ArchModel(ok=False, error="No project open");
    }
    return refine(p);
}

def:pub arch_status(token: str) -> ArchStatus {
    if not authorized(token) {
        return ArchStatus(ok=False, error="unauthorized");
    }
    return _status;
}

def:pub arch_of_module(token: str, module: str) -> ModuleArch {
    if not authorized(token) {
        return ModuleArch(module=module);
    }
    p = current_project();
    if p is None {
        return ModuleArch(module=module);
    }
    return module_component(p, module);
}

"""The modules implementing a component (and its sub-components), most important first."""
def component_modules(p: ProjectData, comp_id: str, limit: int) -> CompModules {
    found = load_stored(p.root_dir);
    if found is None {
        return CompModules(ok=False, error="No architecture yet");
    }
    stored: dict[str, any] = found;
    by_id = {c["id"]: c for c in stored["arch"]["components"]};
    if comp_id not in by_id {
        return CompModules(ok=False, error="Unknown component " + comp_id);
    }
    members: list[BoxInfo] = [];
    for (m, a) in stored.get("assignments", {}).items() {
        cid = a.get("component", "");
        if cid in by_id and comp_id in _ancestors(by_id, cid) and m in p.boxes {
            members.append(p.boxes[m]);
        }
    }
    members = sorted(members, key=lambda (b: BoxInfo) -> float { -b.score });
    shown = members[:limit];
    ids = {b.id for b in shown};
    assign = stored.get("assignments", {});
    nodes = [ModNode(
        id=b.id, name=b.name, loc=b.loc, fan_in=b.fan_in, role=b.role, summary=b.summary,
        confidence=float(assign.get(b.id, {}).get("confidence", 0.0)), source=str(assign.get(b.id, {}).get("source", "")),
        component=str(assign.get(b.id, {}).get("component", ""))
    ) for b in shown];
    edges: list[ModEdge] = [];
    for b in shown {
        for (t, n) in p.mod_deps.get(b.id, {}).items() {
            if t in ids and t != b.id {
                edges.append(ModEdge(src=b.id, dst=t, weight=n));
            }
        }
    }
    return CompModules(component=comp_id, name=by_id[comp_id]["name"], modules=nodes, edges=edges, more=max(len(members) - limit, 0));
}

def:pub arch_component_modules(token: str, comp_id: str, limit: int = 60) -> CompModules {
    if not authorized(token) {
        return CompModules(ok=False, error="unauthorized");
    }
    p = current_project();
    if p is None {
        return CompModules(ok=False, error="No project open");
    }
    return component_modules(p, comp_id, max(min(limit, 200), 1));
}
