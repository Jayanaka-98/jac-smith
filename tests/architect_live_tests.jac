"""Live architecture discovery (network: Codex/ChatGPT + Jev). Opt-in:
JAC_SMITH_LIVE_PROJECT=/path/to/repo jac test tests/architect_live_tests.jac
"""
import os;
import time;
import json;

import from indexer.api { do_index, current_project }
import from architect.discover { start_discovery, describe_architecture, maintain, current_status, refine }

test "live discovery on a real project" {
    target = os.environ.get("JAC_SMITH_LIVE_PROJECT", "");
    if not target {
        print("skipping: set JAC_SMITH_LIVE_PROJECT");
        return;
    }
    t0 = time.time();
    s = do_index(target, False);
    assert s.ok, s.error;
    print("indexed", s.modules, "modules in", s.millis, "ms");
    if os.environ.get("JAC_SMITH_LIVE_REFINE") {
        p0 = current_project();
        assert p0 is not None;
        m0 = refine(p0);
        out0 = os.environ.get("JAC_SMITH_LIVE_OUT", "");
        if out0 {
            with open(out0, "w") as fh {
                fh.write(describe_architecture(p0) + "\n\ncoverage=" + str(m0.coverage) + " unassigned=" + str(m0.unassigned) + " total=" + str(m0.modules_total) + " seconds=" + str(round(time.time() - t0)) + "\n");
            }
        }
        assert m0.coverage > 0.6, str(m0.coverage);
        return;
    }
    start_discovery(os.environ.get("JAC_SMITH_LIVE_ENGINE", ""));
    while current_status().running {
        time.sleep(3);
    }
    st = current_status();
    for step in st.steps {
        print("[" + step.state + "]", step.label, "-", step.detail);
    }
    assert st.ok, st.error;
    p = current_project();
    assert p is not None;
    model = maintain(p);
    out = os.environ.get("JAC_SMITH_LIVE_OUT", "");
    if out {
        with open(out, "w") as fh {
            fh.write(describe_architecture(p) + "\n\ncoverage=" + str(model.coverage) + " unassigned=" + str(model.unassigned) + " total=" + str(model.modules_total) + "\n");
            fh.write("\n".join(["[" + x.state + "] " + x.label + " - " + x.detail for x in st.steps]));
            fh.write("\nseconds=" + str(round(time.time() - t0)));
        }
    }
    assert model.coverage > 0.3, str(model.coverage);
}
