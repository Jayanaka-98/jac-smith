"""Hybrid architecture discovery: Jev decides, Codex names.

  1. Subsystems   deterministic: split the code map into 6-48 units at the right granularity
  2. Archetype    Jev, 1 call: which kind of system (template library)
  3. Placement    Jev, 1 call per subsystem in parallel: which template slot, with confidence
  4. Skeleton     saved and shown immediately; the template supplies stage order and flows
  5. Refine       Codex, one focused call on the compact skeleton: rename in the project's
                  vocabulary, split mixed slots, label flows; it opens files only for the
                  low-confidence subsystems instead of exploring the repository
  6. Map/verify   modules map by subsystem membership (paths), leftovers by neighbours and Jev;
                  flows are checked against real imports
"""
import os;
import re;
import json;
import tempfile;
import subprocess;
import from datetime { datetime }

import from architect.templates { TEMPLATES, Template, Slot, template_by_id, OUTSIDE_SLOT, OUTSIDE_TEXT }
import from architect.jev { jev_choose, jev_choose_many, ChoiceJob }
import from architect.discover {
    module_text, normalise, map_modules, build_model, save_stored, is_outside, build_evidence,
    _slug, _modules, KINDS, STYLES, MAX_JEV_DISCOVER
}
import from indexer.graph { ProjectData }
import from indexer.model { BoxInfo }
import from settings.chatgpt { codex_path, tool_env, login_status, TOOLS_DIR }
import from settings.credentials { read_config }
import shutil;

glob UNCERTAIN_BELOW: float = 0.75;
glob MAX_SUBSYSTEMS: int = 48;

obj Subsystem {
    has id: str;
    has modules: int;
    has loc: int;
    has digest: str;
    has summary: str = "";
    has slot: str = "";
    has confidence: float = 0.0;
}

def _in_scope(path: str) -> bool {
    return not is_outside(path + "/x.py");
}

"""Split the map into subsystems: packages larger than `share` of the code are opened up."""
def candidate_subsystems(p: ProjectData, share: float = 0.1) -> list[str] {
    total = max(sum([b.loc for b in _modules(p) if _in_scope(os.path.dirname(b.id) or ".") and not is_outside(b.id)]), 1);
    def walk_box(bid: str, depth: int, threshold: float) -> list[str] {
        b = p.boxes[bid];
        if b.kind == "module" {
            return [bid] if (b.loc >= 0.01 * total and not is_outside(bid)) else [];
        }
        if not _in_scope(bid) {
            return [];
        }
        has_sub = len([k for k in b.children if p.boxes[k].kind == "package"]) > 0;
        if depth < 6 and b.loc > threshold and has_sub {
            out: list[str] = [];
            for k in b.children {
                out.extend(walk_box(k, depth + 1, threshold));
            }
            return out;
        }
        return [bid];
    }
    threshold = share * total;
    for _ in range(8) {
        subs: list[str] = [];
        for k in p.boxes[p.root_id].children {
            subs.extend(walk_box(k, 0, threshold));
        }
        if len(subs) <= MAX_SUBSYSTEMS {
            return subs;
        }
        threshold = threshold * 1.6;
    }
    return subs[:MAX_SUBSYSTEMS];
}

def subsystem_of(p: ProjectData, sid: str) -> Subsystem {
    b = p.boxes[sid];
    if b.kind == "module" {
        mods = [b];
    } else {
        mods = sorted([m for m in _modules(p) if m.id.startswith(sid + "/") and not is_outside(m.id)], key=lambda (m: BoxInfo) -> float { -m.score });
    }
    texts = [module_text(p, m)[:1400] for m in mods[:6]];
    summary = next(iter([m.summary for m in mods if m.summary]), "");
    digest = "Subsystem: " + sid + " (" + str(len(mods)) + " modules, " + str(sum([m.loc for m in mods])) + " lines)\n" + "\n---\n".join(texts);
    return Subsystem(id=sid, modules=len(mods), loc=sum([m.loc for m in mods]), digest=digest[:7000], summary=summary);
}

"""Jev: archetype, then a template slot for every subsystem. Returns (template, archetype confidence)."""
def jev_skeleton(p: ProjectData, subs: list[Subsystem]) -> tuple[Template, float] {
    crit = {t.id: t.description for t in TEMPLATES};
    a = jev_choose(build_evidence(p)[:11000], "What kind of software system is this repository?", crit);
    tpl = template_by_id(a.choice) or TEMPLATES[1];
    slot_crit = {s.id: s.name + ": " + s.summary for s in tpl.slots};
    slot_crit[OUTSIDE_SLOT] = OUTSIDE_TEXT;
    jobs = [ChoiceJob(key=s.id, state=s.digest, instructions="Which part of a " + tpl.name.lower() + "'s architecture is this subsystem?", criteria=slot_crit) for s in subs];
    answers = jev_choose_many(jobs);
    for s in subs {
        r = answers.get(s.id);
        if r is not None and not r.error and r.choice {
            s.slot = r.choice;
            s.confidence = r.confidence;
        }
    }
    return (tpl, a.confidence);
}

def _pretty(sid: str) -> str {
    parts = [x for x in sid.replace(".jac", "").replace(".py", "").split("/") if x];
    tail = parts[-1] if parts else sid;
    if len(tail) <= 3 and len(parts) > 1 {
        tail = parts[-2] + " " + tail;
    }
    return tail.replace("_", " ").replace("-", " ").strip().capitalize();
}

"""Turn Jev's placements into an architecture: used slots become components, and a slot holding
several subsystems gets them as sub-components."""
def skeleton_arch(p: ProjectData, tpl: Template, subs: list[Subsystem]) -> dict[str, any] {
    comps: list[dict[str, any]] = [];
    used: list[str] = [];
    for slot in tpl.slots {
        members = [s for s in subs if s.slot == slot.id];
        if not members {
            continue;
        }
        used.append(slot.id);
        comps.append({
            "id": slot.id, "name": slot.name, "kind": slot.kind, "summary": slot.summary,
            "order": slot.order, "parent": "", "paths": [s.id for s in members]
        });
        if len(members) > 1 {
            for s in members {
                comps.append({
                    "id": _slug(s.id), "name": _pretty(s.id), "kind": slot.kind, "summary": s.summary,
                    "order": 0, "parent": slot.id, "paths": [s.id]
                });
            }
        }
    }
    flows = [{"src": a, "dst": b, "label": l} for (a, b, l) in tpl.flows if a in used and b in used];
    root_name = p.boxes[p.root_id].name;
    return {
        "system_kind": tpl.name.lower(), "style": tpl.style, "title": root_name + " · " + tpl.name,
        "summary": "", "components": comps, "flows": flows
    };
}

glob REFINE_SCHEMA: dict[str, any] = {
    "type": "object", "additionalProperties": False,
    "required": ["system_kind", "style", "title", "summary", "components", "flows"],
    "properties": {
        "system_kind": {"type": "string"},
        "style": {"type": "string", "enum": STYLES},
        "title": {"type": "string"},
        "summary": {"type": "string"},
        "components": {"type": "array", "items": {
            "type": "object", "additionalProperties": False,
            "required": ["id", "name", "kind", "summary", "order", "parent", "subsystems"],
            "properties": {
                "id": {"type": "string"}, "name": {"type": "string"},
                "kind": {"type": "string", "enum": KINDS}, "summary": {"type": "string"},
                "order": {"type": "integer"}, "parent": {"type": "string"},
                "subsystems": {"type": "array", "items": {"type": "string"}}
            }
        }},
        "flows": {"type": "array", "items": {
            "type": "object", "additionalProperties": False, "required": ["src", "dst", "label"],
            "properties": {"src": {"type": "string"}, "dst": {"type": "string"}, "label": {"type": "string"}}
        }}
    }
};

def _refine_prompt(tpl: Template, arch_conf: float, subs: list[Subsystem], skeleton: dict[str, any]) -> str {
    rows: list[str] = [];
    for s in subs {
        flag = "  UNCERTAIN" if s.confidence < UNCERTAIN_BELOW else "";
        rows.append("- " + s.id + " | slot=" + (s.slot or "?") + " conf=" + str(round(s.confidence, 2)) + flag + " | " + str(s.modules) + " modules, " + str(s.loc) + " lines | " + (s.summary or "")[:160]);
    }
    skel = json.dumps({"components": [{k: c[k] for k in ["id", "name", "parent", "paths"]} for c in skeleton["components"]], "flows": skeleton["flows"]}, indent=1);
    return "\n".join([
        "You refine an architecture that a decision model (Jev) already drafted. Do NOT explore the repository broadly.",
        "Jev classified the system as: " + tpl.name + " (confidence " + str(round(arch_conf, 2)) + ").",
        "",
        "Subsystems (ids are paths in the working directory) with Jev's placement:",
        "\n".join(rows),
        "",
        "Draft architecture (template vocabulary):",
        skel,
        "",
        "Your job, in the project's own domain vocabulary:",
        "1. Name each component the way this project's authors would (e.g. 'UniTree AST', 'JCIR bytecode backend'), with a one-sentence summary.",
        "2. Split a component that groups unrelated subsystems; merge components that are artificially separate; nest sub-components (parent = id) where it clarifies structure. 4-12 top-level components, at most 40 in total.",
        "3. Every subsystem id must appear in exactly one component's `subsystems` list (use leaf components). Parent-only components may have an empty list.",
        "4. Stages of a pipeline get order 1..n in execution order; everything else order 0.",
        "5. Flows: src/dst are component ids; label says what moves between them in domain terms.",
        "6. Open files ONLY to settle subsystems marked UNCERTAIN, and only a few files each.",
        "If the template is wrong for this system, restructure freely - the subsystem ids are what must be preserved."
    ]);
}

def codex_refine(p: ProjectData, tpl: Template, arch_conf: float, subs: list[Subsystem], skeleton: dict[str, any]) -> tuple[dict[str, any] | None, str] {
    cx = codex_path();
    if not cx or not login_status()[0] {
        return (None, "ChatGPT/Codex not available");
    }
    (sfd, schema_file) = tempfile.mkstemp(prefix="jac-smith-refine-schema-", suffix=".json");
    os.close(sfd);
    (ofd, out_file) = tempfile.mkstemp(prefix="jac-smith-refine-", suffix=".json");
    os.close(ofd);
    with open(schema_file, "w", encoding="utf-8") as fh {
        json.dump(REFINE_SCHEMA, fh);
    }
    text = "";
    try {
        r = subprocess.run(
            [cx, "exec", "--skip-git-repo-check", "--ephemeral", "--color", "never", "-C", p.root_dir,
             "-s", "read-only", "--output-schema", schema_file, "-o", out_file, "-"],
            input=_refine_prompt(tpl, arch_conf, subs, skeleton), capture_output=True, text=True,
            timeout=900, cwd=p.root_dir, env=tool_env()
        );
        with open(out_file, encoding="utf-8", errors="replace") as fh {
            text = fh.read().strip();
        }
        if not text {
            return (None, "Codex returned nothing: " + ((r.stderr or "") + (r.stdout or "")).strip()[-300:]);
        }
    } except subprocess.TimeoutExpired {
        return (None, "Codex timed out");
    } finally {
        for f in [schema_file, out_file] {
            try { os.remove(f); } except OSError {}
        }
    }
    m = re.search(r"\{.*\}", text, re.S);
    try {
        return (json.loads(m.group(0) if m else text), "");
    } except ValueError as e {
        return (None, "Codex output was not JSON: " + str(e));
    }
}

def _bin(name: str) -> str {
    local = os.path.join(TOOLS_DIR, "node_modules", ".bin", name);
    if os.path.exists(local) {
        return local;
    }
    return shutil.which(name, path=tool_env()["PATH"]) or "";
}

def namer_available(namer: str) -> bool {
    if namer == "codex" {
        return bool(codex_path()) and login_status()[0];
    }
    if namer == "claude" {
        return bool(_bin("claude"));
    }
    if namer == "gemini" {
        return bool(_bin("gemini"));
    }
    return False;
}

def _json_from(text: str) -> dict[str, any] | None {
    m = re.search(r"\{.*\}", text, re.S);
    if not m {
        return None;
    }
    try {
        data = json.loads(m.group(0));
    } except ValueError {
        return None;
    }
    return data if isinstance(data, dict) else None;
}

"""Refine with Claude (`claude -p` + JSON schema) or Gemini (`gemini -p`, read-only), same contract as Codex."""
def cli_refine(namer: str, p: ProjectData, tpl: Template, arch_conf: float, subs: list[Subsystem], skeleton: dict[str, any]) -> tuple[dict[str, any] | None, str] {
    prompt = _refine_prompt(tpl, arch_conf, subs, skeleton) + "\n\nReturn ONLY a JSON object matching this JSON Schema, with no prose:\n" + json.dumps(REFINE_SCHEMA);
    cfg = read_config();
    if namer == "claude" {
        cmd = [_bin("claude"), "-p", "--output-format", "json", "--json-schema", json.dumps(REFINE_SCHEMA), "--disallowedTools", "Edit", "MultiEdit", "Write", "NotebookEdit", "Bash"];
        if cfg.get("claude_model") {
            cmd.extend(["--model", str(cfg["claude_model"])]);
        }
    } else {
        cmd = [_bin("gemini"), "-p", "-", "-o", "json", "--approval-mode", "plan", "-m", str(cfg.get("gemini_model") or "gemini-2.5-flash"), "--skip-trust"];
    }
    try {
        r = subprocess.run(cmd, input=prompt, capture_output=True, text=True, timeout=900, cwd=p.root_dir, env=tool_env());
    } except subprocess.TimeoutExpired {
        return (None, namer + " timed out");
    }
    outer = _json_from(r.stdout or "");
    if outer is None {
        return (None, namer + " returned no JSON: " + ((r.stderr or "") + (r.stdout or "")).strip()[-300:]);
    }
    for field in ["structured_output", "result", "response"] {
        inner = outer.get(field);
        if isinstance(inner, dict) and "components" in inner {
            return (inner, "");
        }
        if isinstance(inner, str) {
            parsed = _json_from(inner);
            if parsed is not None and "components" in parsed {
                return (parsed, "");
            }
        }
    }
    if "components" in outer {
        return (outer, "");
    }
    return (None, namer + " output had no components");
}

"""Convert Codex's refinement (components own subsystem ids) into the raw architecture shape
(components own paths). Subsystems Codex forgot fall back to their Jev slot's component."""
def refined_to_raw(refined: dict[str, any], subs: list[Subsystem], skeleton: dict[str, any]) -> dict[str, any] {
    known = {s.id: s for s in subs};
    placed: set[str] = set();
    comps: list[dict[str, any]] = [];
    for c in refined.get("components") or [] {
        ids = [x for x in (c.get("subsystems") or []) if x in known and x not in placed];
        placed.update(ids);
        comps.append({
            "id": c.get("id"), "name": c.get("name"), "kind": c.get("kind"), "summary": c.get("summary"),
            "order": c.get("order") or 0, "parent": c.get("parent") or "", "paths": ids
        });
    }
    ids_present = {str(c["id"]) for c in comps};
    for s in subs {
        if s.id in placed or s.slot == OUTSIDE_SLOT or not s.slot {
            continue;
        }
        host = s.slot if s.slot in ids_present else "";
        if not host {
            sk = [c for c in skeleton["components"] if c["id"] == s.slot];
            if sk {
                comps.append({**sk[0], "paths": []});
                ids_present.add(s.slot);
                host = s.slot;
            }
        }
        for c in comps {
            if c["id"] == host {
                c["paths"] = list(c["paths"]) + [s.id];
            }
        }
    }
    return {
        "system_kind": refined.get("system_kind") or skeleton["system_kind"],
        "style": refined.get("style") or skeleton["style"],
        "title": refined.get("title") or skeleton["title"],
        "summary": refined.get("summary") or "",
        "components": comps,
        "flows": refined.get("flows") or []
    };
}

"""Run the hybrid engine. `step(index, state, detail)` reports progress; returns what was stored."""
def run_hybrid(p: ProjectData, step: Callable[[int, str, str], None], refine: bool, namer: str = "codex") -> dict[str, any] {
    step(0, "active", "");
    ids = candidate_subsystems(p);
    subs = [subsystem_of(p, sid) for sid in ids];
    step(0, "done", str(len(subs)) + " subsystems from " + str(len(_modules(p))) + " modules");

    step(1, "active", "");
    (tpl, arch_conf) = jev_skeleton(p, subs);
    step(1, "done", tpl.name + " · " + str(round(arch_conf * 100)) + "% confident");
    uncertain = [s for s in subs if s.confidence < UNCERTAIN_BELOW];
    outside = [s for s in subs if s.slot == OUTSIDE_SLOT];
    step(2, "done", str(len(subs) - len(outside)) + " placed, " + str(len(outside)) + " outside, " + str(len(uncertain)) + " uncertain · " + str(1 + len(subs)) + " Jev calls");

    step(3, "active", "");
    skeleton = skeleton_arch(p, tpl, subs);
    arch = normalise(p, skeleton);
    (assign, _) = map_modules(p, arch, {}, [b.id for b in _modules(p)], 0);
    sub_meta = {s.id: {"slot": s.slot, "confidence": s.confidence} for s in subs};
    stamp = datetime.now().isoformat(timespec="seconds");
    stored = {
        "arch": arch, "assignments": assign, "engine": "hybrid", "archetype": tpl.id,
        "archetype_confidence": arch_conf, "subsystems": sub_meta,
        "generated_by": "Jev skeleton" + (" · " + namer.capitalize() + " refining…" if refine else ""),
        "mapped_by": "Jev", "updated_at": stamp, "generated_at": stamp
    };
    save_stored(p.root_dir, stored);
    step(3, "done", str(len(arch["components"])) + " components on screen");

    final_arch = arch;
    if refine {
        step(4, "active", "one focused " + namer.capitalize() + " call on the skeleton (" + str(len(uncertain)) + " uncertain subsystems to check)");
        (refined, err) = codex_refine(p, tpl, arch_conf, subs, skeleton) if namer == "codex" else cli_refine(namer, p, tpl, arch_conf, subs, skeleton);
        if refined is not None {
            candidate = normalise(p, refined_to_raw(refined, subs, skeleton));
            if len(candidate["components"]) >= 2 {
                final_arch = candidate;
                step(4, "done", str(len(final_arch["components"])) + " components named in the project's vocabulary");
            } else {
                step(4, "error", "refinement was unusable; keeping the Jev skeleton");
            }
        } else {
            step(4, "error", err + " - keeping the Jev skeleton");
        }
    } else {
        step(4, "done", "skipped (Jev only)");
    }

    step(5, "active", "");
    (assign, used) = map_modules(p, final_arch, {}, [b.id for b in _modules(p)], MAX_JEV_DISCOVER);
    stored["arch"] = final_arch;
    stored["assignments"] = assign;
    stored["generated_by"] = ("Jev + " + namer.capitalize() if final_arch is not arch else "Jev");
    stored["updated_at"] = datetime.now().isoformat(timespec="seconds");
    model = build_model(p, stored);
    step(5, "done", str(round(model.coverage * 100)) + "% of modules mapped · " + str(used) + " extra Jev decisions · " + str(len(model.drift)) + " drift findings");

    step(6, "active", "");
    save_stored(p.root_dir, stored);
    step(6, "done", "maintained on every re-index");
    return stored;
}
