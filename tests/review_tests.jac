"""Review: PR diff slicing, local-branch fallback, and impact mapping."""
import os;
import subprocess;
import tempfile;
import from review.prs { slice_diff, local_list, local_detail, github_repo, pr_detail }

def _sh(args: list[str], cwd: str) -> None {
    subprocess.run(args, cwd=cwd, check=True, capture_output=True);
}

def _repo() -> str {
    d = tempfile.mkdtemp(prefix="review-");
    _sh(["git", "init", "-q", "-b", "main"], d);
    _sh(["git", "config", "user.email", "t@example.com"], d);
    _sh(["git", "config", "user.name", "T"], d);
    with open(os.path.join(d, "a.py"), "w") as fh { fh.write("x = 1\n"); }
    _sh(["git", "add", "."], d);
    _sh(["git", "commit", "-q", "-m", "init"], d);
    _sh(["git", "checkout", "-q", "-b", "feat/thing"], d);
    with open(os.path.join(d, "a.py"), "a") as fh { fh.write("y = 2\n"); }
    with open(os.path.join(d, "b.py"), "w") as fh { fh.write("import a\n"); }
    _sh(["git", "add", "."], d);
    _sh(["git", "commit", "-q", "-m", "feat: add thing"], d);
    _sh(["git", "checkout", "-q", "main"], d);
    return d;
}

test "slice_diff picks one file out of a multi-file diff" {
    full = "diff --git a/x.py b/x.py\n+1\ndiff --git a/y.py b/y.py\n+2\n-3\n";
    assert slice_diff(full, "y.py") == "diff --git a/y.py b/y.py\n+2\n-3\n";
    assert slice_diff(full, "z.py") == "";
}

test "unmerged local branches stand in for PRs" {
    d = _repo();
    prs = local_list(d, 10);
    assert len(prs) == 1;
    assert prs[0].ref == "feat/thing";
    assert prs[0].title == "feat: add thing";
    assert prs[0].files == 2;
    assert prs[0].additions == 2;
    assert github_repo(d) == "";
}

test "local branch detail lists files and rejects bad refs" {
    d = _repo();
    det = local_detail(d, "feat/thing");
    assert det.ok;
    assert sorted([f.path for f in det.files]) == ["a.py", "b.py"];
    assert pr_detail(d, "--output=x").ok == False;
    assert pr_detail(d, "a..b").ok == False;
    assert local_detail(d, "nope").ok == False;
}
