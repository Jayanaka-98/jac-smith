"""Agent hub: the ACP client end-to-end against a fake ACP agent (no network)."""
import os;
import shutil;
import time;
import threading;

import from indexer.api { do_index }
import from agents.hub { Run, run_acp, read_events, _acp }

glob REPO: str = os.path.dirname(os.path.dirname(os.path.abspath(__file__)));
glob FAKE: list[str] = [shutil.which("python3") or "/usr/bin/python3", os.path.join(REPO, "tests", "fixtures", "fake_acp_agent.py")];

def text_of(run: Run) -> str {
    return "".join([e.text for e in run.events if e.kind == "text"]);
}

test "acp turn with locked edits: file read through the client, edit permission auto-declined" {
    s = do_index(REPO, False);
    assert s.ok, s.error;
    run = Run(id="r1", backend="custom", cond=threading.Condition());
    run_acp(run, "test-locked", REPO, "hello", False, FAKE);
    out = text_of(run);
    assert "First line:" in out, out;
    assert "Permission: no." in out, out;
    assert "indexer/layout.jac" in run.touched, str(run.touched);
    tools = [e for e in run.events if e.kind == "tool"];
    assert tools and "-b" in tools[-1].diff and "+c" in tools[-1].diff, tools[-1].diff if tools else "no tool";
    assert any([e.kind == "info" and "locked" in e.text for e in run.events]);
    _acp.pop("test-locked@" + REPO).close();
}

test "acp turn with edits allowed: permission surfaces to the user and the choice reaches the agent" {
    s = do_index(REPO, False);
    assert s.ok, s.error;
    run = Run(id="r2", backend="custom", cond=threading.Condition());
    def answer() {
        deadline = time.time() + 20;
        while time.time() < deadline {
            perms = [e for e in run.events if e.kind == "permission"];
            if perms {
                w = run.permissions[perms[0].tool_id];
                w["choice"] = "yes";
                w["event"].set();
                return;
            }
            time.sleep(0.05);
        }
    }
    threading.Thread(target=answer, daemon=True).start();
    run_acp(run, "test-open", REPO, "hello", True, FAKE);
    assert "Permission: yes." in text_of(run), text_of(run);
    batch = read_events("missing", 0, 0.0);
    assert not batch.ok;
    _acp.pop("test-open@" + REPO).close();
}
