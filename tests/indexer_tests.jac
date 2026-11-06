"""Indexer tests: index this repository itself and check the architecture it recovers."""
import os;

import from indexer.api { do_index, frame_for, source_of, current_project, index_project }
import from settings.session { SESSION_TOKEN }
import from indexer.scan { scan_jac, scan_python, scan_js }
import from indexer.layout { treemap }

glob REPO: str = os.path.dirname(os.path.dirname(os.path.abspath(__file__)));

test "jac scanner reads imports and declarations" {
    src = "\"\"\"Doc line. More.\"\"\"\nimport os;\nimport from indexer.model { BoxInfo, Tile }\nimport from \"react\" { useState }\nimport from .ui.Shell { Shell }\nnode Box {\n    has x: int;\n}\ndef:pub frame_for(box_id: str) -> BoxFrame {\n}\nwalker Rollup {\n}\n";
    rf = scan_jac("a/b.jac", src);
    targets = [i.target for i in rf.imports];
    assert "os" in targets;
    assert "indexer.model" in targets;
    assert "react" in targets;
    rel = [i for i in rf.imports if i.target == "ui.Shell"];
    assert len(rel) == 1 and rel[0].level == 1;
    names = [s.name for s in rf.symbols];
    assert names == ["Box", "frame_for", "Rollup"], str(names);
    assert rf.summary == "Doc line.";
}

test "python scanner uses ast" {
    rf = scan_python("pkg/mod.py", "\"\"\"Mod.\"\"\"\nimport json\nfrom . import sib\nfrom ..core import thing\nclass A(Base):\n    pass\ndef _hidden(): pass\nasync def go(x: int) -> str: pass\n");
    assert [(i.target, i.level) for i in rf.imports] == [("json", 0), ("", 1), ("core", 2)];
    assert [s.name for s in rf.symbols] == ["A", "_hidden", "go"];
    assert not rf.symbols[1].public;
    assert rf.symbols[2].signature == "async def go(x: int) -> str";
}

test "js scanner finds packages and relative paths" {
    rf = scan_js("src/a.ts", "import React from 'react';\nimport { x } from './util';\nconst fs = require('fs');\nexport function hello() {}\n", "typescript");
    kinds = {i.target: i.kind for i in rf.imports};
    assert kinds == {"react": "package", "./util": "path", "fs": "package"};
    assert [s.name for s in rf.symbols] == ["hello"];
}

test "treemap tiles cover the unit square" {
    rects = treemap([("a", 9.0), ("b", 4.0), ("c", 1.0), ("d", 1.0)], 1.6);
    area = sum([r.w * r.h for r in rects.values()]);
    assert abs(area - 1.0) < 1e-6;
    assert rects["a"].w * rects["a"].h > rects["d"].w * rects["d"].h;
}

test "indexing this repo recovers its architecture" {
    s = do_index(REPO, False);
    assert s.ok, s.error;
    assert s.modules >= 8, str(s.modules);
    p = current_project();
    assert p is not None;
    # internal resolution: the api module imports the graph module
    assert "indexer/graph.jac" in p.mod_deps["indexer/api.jac"];
    assert "settings/credentials.jac" in p.mod_deps["indexer/roles.jac"];
    # externals carry their ecosystem
    assert "ext:stdlib:os" in p.exts;
    assert "ext:jac:jaclang" in p.exts;
    # the rollup walker summed child scores into packages
    idx = p.boxes["indexer"];
    kid_sum = sum([p.boxes[c].score for c in idx.children]);
    assert abs(idx.score - kid_sum) < 1e-6;
    assert p.boxes["."].files == s.modules;
    # model.jac is imported by many modules, so it has fan-in
    assert p.boxes["indexer/model.jac"].fan_in >= 3;
    assert p.boxes["indexer/model.jac"].role != "";
}

test "frames aggregate dependencies to the focused level" {
    s = do_index(REPO, False);
    assert s.ok, s.error;
    top = frame_for(".", 1.6);
    assert top.ok;
    ids = [c.info.id for c in top.children];
    assert "indexer" in ids and "settings" in ids;
    pairs = [(e.src, e.dst) for e in top.edges];
    assert ("indexer", "settings") in pairs, str(pairs);
    inner = frame_for("indexer", 1.6);
    names = [c.info.name for c in inner.children];
    assert "graph.jac" in names;
    ctx = [x.id for x in inner.externals if x.ecosystem == "project"];
    assert "settings" in ctx, str(ctx);
    assert [c.name for c in inner.crumbs][-1] == "indexer";
    assert "node Box" in source_of("indexer/graph.jac");
    assert source_of("../../etc/passwd") == "";
}

test "jev classifies module roles when a key is configured" {
    import from settings.credentials { jev_key }
    if not jev_key() {
        print("skipping: no JEV_API_KEY / TYPESAFE_API_KEY registered");
        return;
    }
    s = do_index(REPO, True);
    assert s.ok, s.error;
    p = current_project();
    assert p is not None;
    jev_boxes = [b for b in p.boxes.values() if b.kind == "module" and b.role_source == "jev"];
    assert len(jev_boxes) >= 1, "no module was classified by Jev";
    for b in jev_boxes {
        print(b.id, b.role, b.tier, round(b.role_confidence, 2));
    }
}

test "endpoints refuse calls without the session token" {
    assert not index_project("wrong", REPO, False).ok;
    assert index_project(SESSION_TOKEN, REPO, False).ok;
}

test "tokenizer highlights jac, python and js" {
    import from indexer.snippets { tokenize }
    toks = tokenize("def:pub get_frame(x: int) -> BoxFrame {\n    return \"hi\"; # note\n}", "jac");
    kinds = {t[1]: t[0] for t in toks if t[1].strip()};
    assert kinds["def"] == "k" and kinds["pub"] == "k";
    assert kinds["get_frame"] == "f", str(toks);
    assert kinds["BoxFrame"] == "t";
    assert kinds["\"hi\""] == "s";
    assert kinds["# note"] == "c";
    assert "".join([t[1] for t in toks]) == "def:pub get_frame(x: int) -> BoxFrame {\n    return \"hi\"; # note\n}";
    py = {t[1]: t[0] for t in tokenize("@cache\nasync def run(n=3):\n    pass", "python") if t[1].strip()};
    assert py["@cache"] == "d" and py["run"] == "f" and py["3"] == "n";
    js = {t[1]: t[0] for t in tokenize("export function go() { return `x`; } // y", "js") if t[1].strip()};
    assert js["go"] == "f" and js["`x`"] == "s" and js["// y"] == "c";
}

test "every box carries a code preview that starts at real code" {
    s = do_index(REPO, False);
    assert s.ok, s.error;
    top = frame_for(".", 1.6);
    for cv in top.children {
        assert len(cv.code) > 0, cv.info.id;
    }
    idx = frame_for("indexer", 1.6);
    scan = [cv for cv in idx.children if cv.info.id == "indexer/scan.jac"][0];
    text = "".join([t[1] for t in scan.code]);
    assert not text.startswith("import") and not text.startswith("\"\"\""), text[:80];
    assert scan.code_from == "indexer/scan.jac" and scan.code_line > 1;
    pkg = [cv for cv in top.children if cv.info.id == "indexer"][0];
    assert pkg.code_from.startswith("indexer/");
    syms = frame_for("indexer/graph.jac", 1.6);
    rollup = [cv for cv in syms.children if cv.info.name == "Rollup"][0];
    assert "walker Rollup" in "".join([t[1] for t in rollup.code]);
}

test "source lines keep every line of the file, highlighted" {
    import from indexer.api { source_lines }
    s = do_index(REPO, False);
    assert s.ok, s.error;
    lines = source_lines("indexer/layout.jac");
    with open(os.path.join(REPO, "indexer/layout.jac")) as fh {
        raw = fh.read().splitlines();
    }
    assert len(lines) == len(raw), str(len(lines)) + " vs " + str(len(raw));
    for (i, l) in enumerate(lines) {
        assert "".join([t[1] for t in l]) == raw[i], "line " + str(i + 1);
    }
    kinds = {t[0] for l in lines for t in l};
    assert "k" in kinds and "f" in kinds and "s" in kinds;
}

test "saving an edited file is atomic and refuses stale writes" {
    import from indexer.api { save_file, file_version }
    s = do_index(REPO, False);
    assert s.ok, s.error;
    rel = "tests/_edit_probe.jac";
    full = os.path.join(REPO, rel);
    with open(full, "w") as fh { fh.write("glob X: int = 1;\n"); }
    try {
        v0 = file_version(full);
        r = save_file(rel, "glob X: int = 2;\n", v0);
        assert r.ok, r.error;
        with open(full) as fh { assert fh.read() == "glob X: int = 2;\n"; }
        stale = save_file(rel, "glob X: int = 3;\n", v0);
        assert not stale.ok and stale.conflict;
        with open(full) as fh { assert fh.read() == "glob X: int = 2;\n"; }
        assert not save_file("../outside.txt", "x", "").ok;
    } finally {
        os.remove(full);
    }
}

test "outside boxes: packages end with a slash, files do not" {
    s = do_index(REPO, False);
    assert s.ok, s.error;
    pkg_names = [x.name for x in frame_for("architect", 1.6).externals if x.ecosystem == "project"];
    assert "indexer/" in pkg_names, str(pkg_names);
    file_names = [x.name for x in frame_for("indexer/graph.jac", 1.6).externals if x.ecosystem == "project"];
    assert "model.jac" in file_names and "model.jac/" not in file_names, str(file_names);
}

test "architecture wiring files become dependency edges" {
    import from indexer.archwire { parse_wires, resolve_dotted }
    text = "graph import {\n    edge Core: core.* --> app.*;\n}\n\ngraph import core {\n    store ++> [\n        app.views | app.api.Handler.run { Thing },\n        app.cli { main },\n    ]\n    type util --> app.views { helper }\n    store as s --> app.jobs;\n}\n";
    wires = parse_wires(text);
    pairs = [(w.provider, c) for w in wires for c in w.consumers];
    assert ("core.store", "app.views") in pairs, str(pairs);
    assert ("core.store", "app.api.Handler.run") in pairs, str(pairs);
    assert ("core.store", "app.cli") in pairs and ("core.util", "app.views") in pairs and ("core.store", "app.jobs") in pairs, str(pairs);
    assert not [p for p in pairs if "Thing" in p[1] or p[1] == "main"], str(pairs);
    lookup = {"pkg.app.api": "pkg/app/api.jac"};
    assert resolve_dotted("app.api.Handler.run", "pkg", lookup) == "pkg/app/api.jac";
}
