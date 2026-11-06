"""History view: lane layout and commit details against a throwaway git repo."""
import os;
import tempfile;
import subprocess;

import from history.git { read_log, commit_detail, file_diff, layout, CommitRow, read_timeline }

def git(d: str, args: list[str]) -> str {
    env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@x", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@x"};
    return subprocess.run(["git"] + args, cwd=d, capture_output=True, text=True, env=env, check=True).stdout.strip();
}

def make_repo() -> str {
    d = tempfile.mkdtemp(prefix="jac-smith-git-");
    git(d, ["init", "-q", "-b", "main"]);
    for (name, body) in [("a.py", "x = 1\n"), ("b.py", "y = 2\n")] {
        with open(os.path.join(d, name), "w") as fh { fh.write(body); }
        git(d, ["add", name]);
        git(d, ["commit", "-q", "-m", "add " + name]);
    }
    git(d, ["checkout", "-q", "-b", "feature"]);
    with open(os.path.join(d, "a.py"), "a") as fh { fh.write("z = 3\n"); }
    git(d, ["commit", "-q", "-am", "feature work"]);
    git(d, ["checkout", "-q", "main"]);
    with open(os.path.join(d, "b.py"), "a") as fh { fh.write("w = 4\n"); }
    git(d, ["commit", "-q", "-am", "main work"]);
    git(d, ["merge", "-q", "--no-ff", "feature", "-m", "merge feature"]);
    return d;
}

test "git graph lanes: a merge fans out and converges" {
    d = make_repo();
    log = read_log(d, 50, 0, False);
    assert log.ok, log.error;
    assert len(log.commits) == 5, str(len(log.commits));
    merge = log.commits[0];
    assert merge.subject == "merge feature" and len(merge.parents) == 2;
    assert log.lanes == 2, str(log.lanes);
    # the commit after the merge sits in one lane and the other branch in the second lane
    cols = {c.subject: c.col for c in log.commits};
    assert cols["main work"] != cols["feature work"], str(cols);
    # the shared ancestor receives two converging lines (both branches end there)
    base = [c for c in log.commits if c.subject == "add b.py"][0];
    assert len([s for s in base.incoming if s.b == base.col]) == 2, str([(s.a, s.b) for s in base.incoming]);
    assert any(["main" in r for r in merge.refs]);
}

test "commit details and file diff" {
    d = make_repo();
    log = read_log(d, 50, 0, False);
    fw = [c for c in log.commits if c.subject == "feature work"][0];
    det = commit_detail(d, fw.hash);
    assert det.ok, det.error;
    assert [f.path for f in det.files] == ["a.py"];
    assert det.files[0].added == 1 and det.files[0].deleted == 0;
    diff = file_diff(d, fw.hash, "a.py");
    assert "+z = 3" in diff, diff;
    assert not commit_detail(d, "not-a-hash").ok;
    assert file_diff(d, fw.hash, "--output=/tmp/x") == "";
}

test "timeline: main runs oldest to newest, the merged branch becomes a PR lane" {
    d = make_repo();
    git(d, ["checkout", "-q", "-b", "wip"]);
    with open(os.path.join(d, "c.py"), "w") as fh { fh.write("q = 9\n"); }
    git(d, ["add", "c.py"]);
    git(d, ["commit", "-q", "-m", "feat: open work (#7)"]);
    git(d, ["checkout", "-q", "main"]);
    tl = read_timeline(d, 100, 5);
    assert tl.ok, tl.error;
    assert [c.subject for c in tl.main] == ["add a.py", "add b.py", "main work", "merge feature"], str([c.subject for c in tl.main]);
    prs = [l for l in tl.lanes if l.kind == "pr"];
    assert len(prs) == 1 and [c.subject for c in prs[0].commits] == ["feature work"];
    assert prs[0].fork == 1 and prs[0].merge == 3, str((prs[0].fork, prs[0].merge));
    open_lanes = [l for l in tl.lanes if l.kind == "branch"];
    assert len(open_lanes) == 1 and open_lanes[0].name == "wip" and open_lanes[0].merge == -1;
    assert open_lanes[0].commits[0].pr == 7 and open_lanes[0].commits[0].kind == "feat";
}
