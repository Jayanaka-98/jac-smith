"""Architecture workflow tests: normalise a proposal, map modules, verify flows, maintain."""
import os;

import from indexer.api { do_index, current_project }
import from architect.discover { normalise, map_modules, build_model, describe_architecture }

glob REPO: str = os.path.dirname(os.path.dirname(os.path.abspath(__file__)));

glob PROPOSAL: dict[str, any] = {
    "system_kind": "IDE",
    "style": "layered",
    "title": "jac smith",
    "summary": "Architecture-first IDE.",
    "components": [
        {"id": "Index", "name": "Indexer", "kind": "stage", "summary": "Builds the code map", "paths": ["indexer"], "order": 1, "parent": ""},
        {"id": "scan", "name": "Scanner", "kind": "stage", "summary": "Parses sources", "paths": ["indexer/scan.jac", "./indexer/layout.jac/"], "order": 1, "parent": "Index"},
        {"id": "graph", "name": "Graph builder", "kind": "stage", "summary": "Builds the graph", "paths": ["indexer/graph.jac", "indexer/roles.jac"], "order": 2, "parent": "Index"},
        {"id": "ui", "name": "Desktop UI", "kind": "ui", "summary": "Views", "paths": ["ui", "main.jac"], "order": 0, "parent": ""},
        {"id": "agent", "name": "Agent", "kind": "service", "summary": "Coding agent", "paths": ["agent", "architect"], "order": 0, "parent": ""},
        {"id": "platform", "name": "Platform", "kind": "runtime", "summary": "Settings and terminals", "paths": ["settings", "terminal", "does/not/exist"], "order": 0, "parent": ""},
        {"id": "dup", "name": "Dup", "kind": "weird-kind", "summary": "", "paths": [], "order": 0, "parent": "nobody"}
    ],
    "flows": [
        {"src": "ui", "dst": "Index", "label": "BoxFrame"},
        {"src": "agent", "dst": "Index", "label": "architecture queries"},
        {"src": "agent", "dst": "missing", "label": "dropped"}
    ]
};

test "normalise slugs ids, drops bad paths, parents and flows" {
    s = do_index(REPO, False);
    assert s.ok, s.error;
    p = current_project();
    assert p is not None;
    arch = normalise(p, PROPOSAL);
    ids = [c["id"] for c in arch["components"]];
    assert "index" in ids and "scan" in ids;
    by_id = {c["id"]: c for c in arch["components"]};
    assert by_id["scan"]["parent"] == "index";
    assert by_id["scan"]["paths"] == ["indexer/scan.jac", "indexer/layout.jac"];
    assert "does/not/exist" not in by_id["platform"]["paths"];
    assert by_id["dup"]["parent"] == "" and by_id["dup"]["kind"] == "component";
    assert len(arch["flows"]) == 2;
}

test "mapping, flow verification and drift" {
    s = do_index(REPO, False);
    assert s.ok, s.error;
    p = current_project();
    assert p is not None;
    arch = normalise(p, PROPOSAL);
    mods = [b.id for b in p.boxes.values() if b.kind == "module"];
    (assign, used) = map_modules(p, arch, {}, mods, 0);
    assert assign["indexer/scan.jac"]["component"] == "scan";
    assert assign["indexer/graph.jac"]["component"] == "graph";
    assert assign["indexer/api.jac"]["component"] == "index";
    assert assign["ui/Shell.jac"]["component"] == "ui";
    model = build_model(p, {"arch": arch, "assignments": assign});
    comps = {c.id: c for c in model.components};
    assert comps["index"].module_count >= comps["scan"].module_count + comps["graph"].module_count;
    assert "scan" in comps["index"].children;
    flows = {(f.src, f.dst): f for f in model.flows};
    assert flows[("agent", "index")].declared and flows[("agent", "index")].observed > 0;
    # the graph builder imports the scanner: an observed sub-level flow inside the indexer
    assert ("graph", "scan") in flows and not flows[("graph", "scan")].declared;
    # tests/ is outside the product architecture: classified by rule, never sent to Jev
    assert assign["tests/indexer_tests.jac"]["component"] == "none";
    assert assign["tests/indexer_tests.jac"]["source"] == "rules";
    assert model.coverage > 0.9, str(model.coverage);
    text = describe_architecture(p);
    assert "No architecture" in text or "jac smith" in text;
}

test "a component lists its modules and the imports between them" {
    import from architect.discover { component_modules, save_stored, store_path, load_stored }
    s = do_index(REPO, False);
    assert s.ok, s.error;
    p = current_project();
    assert p is not None;
    arch = normalise(p, PROPOSAL);
    (assign, _) = map_modules(p, arch, {}, [b.id for b in p.boxes.values() if b.kind == "module"], 0);
    previous = load_stored(p.root_dir);
    save_stored(p.root_dir, {"arch": arch, "assignments": assign});
    try {
        cm = component_modules(p, "index", 60);
        assert cm.ok, cm.error;
        ids = [m.id for m in cm.modules];
        assert "indexer/scan.jac" in ids and "indexer/api.jac" in ids;
        assert ("indexer/graph.jac", "indexer/scan.jac") in [(e.src, e.dst) for e in cm.edges];
        assert not component_modules(p, "nope", 10).ok;
    } finally {
        if previous is not None {
            save_stored(p.root_dir, previous);
        }
    }
}
