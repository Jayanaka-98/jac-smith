"""Probe: can architecture discovery be Jev-only? (network, opt-in)
JAC_SMITH_JEV_PROBE=/path/to/repo JAC_SMITH_JEV_OUT=/tmp/out.txt jac test tests/jev_engine_probe.jac
Asks Jev closed-set questions only: system archetype, template-slot per subsystem, stage order.
"""
import os;
import time;

import from indexer.api { do_index, current_project }
import from indexer.graph { ProjectData }
import from architect.discover { build_evidence, module_text, load_stored }
import from architect.jev { jev_choose, jev_choose_many, ChoiceJob }

glob ARCHETYPES: dict[str, str] = {
    "compiler": "Compiler, interpreter or programming-language toolchain: parses source, analyzes it, generates code, ships a runtime",
    "webapp": "Web application: browser client plus server API and database",
    "service": "Backend service or API platform without its own language",
    "datapipe": "Data or ETL pipeline: ingest, transform, store, report",
    "ml": "Machine-learning training or inference system",
    "library": "General-purpose library or SDK consumed by other programs",
    "cli": "Command-line tool",
    "game": "Game or game engine",
    "infra": "Infrastructure or deployment tooling"
};

glob COMPILER_SLOTS: dict[str, str] = {
    "frontend": "Lexing and parsing: tokenizer, grammar, parser producing the syntax tree",
    "ast": "Syntax tree / IR data structures and their utilities",
    "semantic": "Semantic analysis passes: symbol tables, name and import resolution, type checking, other static checks",
    "lowering": "Lowering and optimization: intermediate representations, transforms between IRs",
    "codegen": "Code generation backends that emit target code (bytecode, JavaScript, native/LLVM)",
    "runtime": "Runtime library and execution model used by compiled programs",
    "driver": "Compiler driver / build orchestration: pipelines of passes, caching, module loading",
    "tooling": "Developer tooling: CLI, language server, formatter, editor integration",
    "stdlib": "Standard library and built-in modules for user programs",
    "platform": "Application platform features beyond the language core: serving, persistence, deployment, AI integration, client bundling"
};

def dir_digest(rel: str) -> str {
    found = current_project();
    if found is None {
        return rel;
    }
    p: ProjectData = found;
    mods = sorted([b for b in p.boxes.values() if b.kind == "module" and b.id.startswith(rel + "/")], key=lambda (b: any) -> float { -b.score })[:8];
    return "Subsystem directory: " + rel + "\n" + "\n---\n".join([module_text(p, b) for b in mods]);
}

test "jev-only architecture probe" {
    target = os.environ.get("JAC_SMITH_JEV_PROBE", "");
    if not target {
        print("skipping: set JAC_SMITH_JEV_PROBE");
        return;
    }
    out_lines: list[str] = [];
    t0 = time.time();
    s = do_index(target, False);
    assert s.ok, s.error;
    p = current_project();
    assert p is not None;

    # 1. archetype
    ev = build_evidence(p)[:11000];
    a = jev_choose(ev, "What kind of software system is this repository?", ARCHETYPES);
    out_lines.append("ARCHETYPE: " + a.choice + " conf=" + str(round(a.confidence, 3)) + " top=" + str(sorted(a.probabilities.items(), key=lambda (kv: any) -> float { -kv[1] })[:3]));

    # 2. template slots for subsystems
    subs = [
        "jaclang/compiler/frontend", "jaclang/compiler/passes", "jaclang/compiler/types",
        "jaclang/compiler/backends/py", "jaclang/compiler/backends/es", "jaclang/compiler/backends/native",
        "jaclang/compiler/driver", "jaclang/compiler/placement", "jaclang/runtime", "jaclang/lsp", "jaclang/cli",
        "jaclang/server", "jaclang/byllm", "jaclang/client", "jaclang/data", "jaclang/scale", "jaclang/project"
    ];
    subs = [d for d in subs if d in p.boxes];
    jobs = [ChoiceJob(key=d, state=dir_digest(d), instructions="Which part of a compiler's architecture is this subsystem?", criteria=COMPILER_SLOTS) for d in subs];
    ans = jev_choose_many(jobs);
    stored = load_stored(p.root_dir);
    codex_of: dict[str, str] = {};
    if stored is not None {
        comps = {c["id"]: c for c in stored["arch"]["components"]};
        for d in subs {
            votes: dict[str, int] = {};
            for (m, asg) in stored["assignments"].items() {
                if m.startswith(d + "/") and asg["component"] in comps {
                    c = comps[asg["component"]];
                    top = c["parent"] or c["id"];
                    name = comps[top]["name"] if top in comps else top;
                    votes[name] = votes.get(name, 0) + 1;
                }
            }
            if votes {
                codex_of[d] = max(votes, key=lambda (k: str) -> int { votes[k] });
            }
        }
    }
    out_lines.append("\nSLOTS (Jev, closed-set)  vs  Codex top-level component:");
    for d in subs {
        r = ans[d];
        out_lines.append("  " + d.ljust(36) + (r.choice or "ERR:" + r.error).ljust(11) + str(round(r.confidence, 2)).ljust(6) + " | " + codex_of.get(d, "-"));
    }

    # 3. stage order, pairwise
    pairs = [
        ("jaclang/compiler/frontend", "jaclang/compiler/passes"),
        ("jaclang/compiler/passes", "jaclang/compiler/backends/py"),
        ("jaclang/compiler/types", "jaclang/compiler/backends/native"),
        ("jaclang/compiler/backends/py", "jaclang/runtime"),
        ("jaclang/compiler/frontend", "jaclang/compiler/backends/es")
    ];
    order_crit = {
        "before": "The first subsystem runs earlier in the compilation pipeline and feeds the second",
        "after": "The first subsystem runs later than the second and consumes its output",
        "independent": "They are not ordered relative to each other"
    };
    ojobs = [ChoiceJob(key=a1 + " ? " + b1, state="FIRST:\n" + dir_digest(a1)[:5000] + "\n\nSECOND:\n" + dir_digest(b1)[:5000], instructions="In the compiler's pipeline, how does the FIRST subsystem relate to the SECOND?", criteria=order_crit) for (a1, b1) in pairs];
    oans = jev_choose_many(ojobs);
    out_lines.append("\nORDER (pairwise):");
    for j in ojobs {
        r = oans[j.key];
        out_lines.append("  " + j.key.ljust(70) + r.choice + " " + str(round(r.confidence, 2)));
    }
    out_lines.append("\nseconds=" + str(round(time.time() - t0, 1)) + " jev_calls=" + str(1 + len(jobs) + len(ojobs)));
    out = os.environ.get("JAC_SMITH_JEV_OUT", "");
    if out {
        with open(out, "w") as fh {
            fh.write("\n".join(out_lines) + "\n");
        }
    }
}
