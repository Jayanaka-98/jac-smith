"""Hybrid engine (offline parts): subsystem selection, skeleton from Jev placements, refinement merge."""
import os;

import from indexer.api { do_index, current_project }
import from architect.hybrid { candidate_subsystems, subsystem_of, skeleton_arch, refined_to_raw, Subsystem }
import from architect.templates { template_by_id }
import from architect.discover { normalise, map_modules, build_model }

glob REPO: str = os.path.dirname(os.path.dirname(os.path.abspath(__file__)));

test "subsystems cover the product and skip tests" {
    s = do_index(REPO, False);
    assert s.ok, s.error;
    p = current_project();
    assert p is not None;
    subs = candidate_subsystems(p);
    for d in ["indexer", "ui", "architect", "settings", "terminal", "agent"] {
        assert d in subs, str(subs);
    }
    assert "tests" not in subs;
    sub = subsystem_of(p, "indexer");
    assert sub.modules >= 6 and "Subsystem: indexer" in sub.digest;
}

test "skeleton from placements, then a codex refinement that forgets one subsystem" {
    s = do_index(REPO, False);
    assert s.ok, s.error;
    p = current_project();
    assert p is not None;
    tpl = template_by_id("ide");
    assert tpl is not None;
    slots = {"ui": "ui", "indexer": "analysis", "architect": "analysis", "agent": "ai", "settings": "platform", "terminal": "platform", "history": "analysis", "review": "analysis", "agents": "ai"};
    subs = [Subsystem(id=k, modules=1, loc=1, digest="", slot=v, confidence=0.9) for (k, v) in slots.items()];
    sk = skeleton_arch(p, tpl, subs);
    ids = [c["id"] for c in sk["components"]];
    assert "analysis" in ids and "indexer" in ids and "architect" in ids;   # two subsystems -> sub-components
    assert [c for c in sk["components"] if c["id"] == "indexer"][0]["parent"] == "analysis";
    assert ("ui", "analysis") in [(f["src"], f["dst"]) for f in sk["flows"]];
    refined = {
        "system_kind": "IDE", "style": "layered", "title": "jac smith", "summary": "s",
        "components": [
            {"id": "map", "name": "Code map", "kind": "component", "summary": "", "order": 0, "parent": "", "subsystems": ["indexer"]},
            {"id": "arch", "name": "Architecture agent", "kind": "service", "summary": "", "order": 0, "parent": "", "subsystems": ["architect", "agent", "bogus"]},
            {"id": "views", "name": "Views", "kind": "ui", "summary": "", "order": 0, "parent": "", "subsystems": ["ui"]}
        ],
        "flows": [{"src": "views", "dst": "map", "label": "frames"}]
    };
    raw = refined_to_raw(refined, subs, sk);
    by_id = {c["id"]: c for c in raw["components"]};
    assert by_id["arch"]["paths"] == ["architect", "agent"];      # unknown id dropped
    assert "platform" in by_id and sorted(by_id["platform"]["paths"]) == ["settings", "terminal"];  # forgotten ones fall back to their slot
    arch = normalise(p, raw);
    (assign, _) = map_modules(p, arch, {}, [b.id for b in p.boxes.values() if b.kind == "module"], 0);
    model = build_model(p, {"arch": arch, "assignments": assign});
    assert model.coverage > 0.9, str(model.coverage);
}
