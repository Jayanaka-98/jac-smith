"""Pull requests for the Review view: the open PRs of the project's repository and what each one
touches - files, the boxes they live in, the architecture components they change, and how far the
change reaches through the import graph.

GitHub PRs come from the `gh` CLI (upstream remote first, then origin). Without `gh`, or for a repo
with no GitHub remote, unmerged local branches stand in for PRs so the view still works offline.
"""
import os;
import re;
import json;
import shutil;
import subprocess;
import from datetime { datetime, timezone }

import from settings.session { authorized }
import from indexer.api { current_project }
import from indexer.graph { ProjectData }
import from architect.discover { load_stored }
import from history.git { repo_root, relative_time }

glob GH_URL = re.compile(r"github\.com[:/]([\w.-]+)/([\w.-]+?)(?:\.git)?/?$");
glob BRANCH_RE = re.compile(r"^[\w./-]{1,200}$");
glob _diffs: dict[str, str] = {};

obj PRCheck {
    has name: str;
    has state: str = "pending";
}

obj PRSummary {
    has ref: str;
    has number: int = 0;
    has title: str = "";
    has author: str = "";
    has branch: str = "";
    has base: str = "";
    has draft: bool = False;
    has updated: str = "";
    has rel: str = "";
    has additions: int = 0;
    has deletions: int = 0;
    has files: int = 0;
    has review: str = "";
    has url: str = "";
}

obj PRList {
    has ok: bool = True;
    has error: str = "";
    has repo: str = "";
    has source: str = "";
    has note: str = "";
    has prs: list[PRSummary] = [];
}

obj PRFile {
    has path: str;
    has added: int = 0;
    has deleted: int = 0;
    has box_id: str = "";
    has component: str = "";
    has is_new: bool = False;
}

obj PRComponent {
    has id: str;
    has name: str;
    has parent_name: str = "";
    has files: int = 0;
    has added: int = 0;
    has deleted: int = 0;
}

obj PRDetail {
    has ok: bool = True;
    has error: str = "";
    has source: str = "";
    has summary: PRSummary | None = None;
    has body: str = "";
    has files: list[PRFile] = [];
    has components: list[PRComponent] = [];
    has boxes: list[str] = [];
    has checks: list[PRCheck] = [];
    has dependents: int = 0;
    has dependent_sample: list[str] = [];
    has outside: int = 0;
    has arch_mapped: bool = False;
}

def _run(cmd: list[str], cwd: str, timeout: int = 40) -> tuple[int, str, str] {
    try {
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, cwd=cwd, errors="replace");
    } except (OSError, subprocess.TimeoutExpired) as e {
        return (1, "", str(e));
    }
    return (r.returncode, r.stdout, r.stderr);
}

def gh_path() -> str {
    found = shutil.which("gh");
    if found {
        return found;
    }
    for cand in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"] {
        if os.path.exists(cand) {
            return cand;
        }
    }
    return "";
}

"""owner/name of the GitHub repository a checkout tracks: upstream wins over origin (a fork's PRs
are opened against upstream)."""
def github_repo(repo_dir: str) -> str {
    for remote in ["upstream", "origin"] {
        (rc, out, _) = _run(["git", "remote", "get-url", remote], repo_dir, 10);
        if rc == 0 {
            m = GH_URL.search(out.strip());
            if m {
                return m.group(1) + "/" + m.group(2);
            }
        }
    }
    return "";
}

def _review_state(decision: str) -> str {
    return {"APPROVED": "approved", "CHANGES_REQUESTED": "changes", "REVIEW_REQUIRED": "pending"}.get(decision or "", "");
}

def gh_list(gh: str, repo_dir: str, repo: str, limit: int) -> tuple[list[PRSummary], str] {
    fields = "number,title,author,headRefName,baseRefName,isDraft,updatedAt,additions,deletions,changedFiles,reviewDecision,url";
    (rc, out, err) = _run([gh, "pr", "list", "--repo", repo, "--state", "open", "--limit", str(limit), "--json", fields], repo_dir, 60);
    if rc != 0 {
        return ([], (err.strip() or out.strip())[:300] or "gh pr list failed");
    }
    try {
        rows = json.loads(out);
    } except ValueError {
        return ([], "gh returned unreadable output");
    }
    prs: list[PRSummary] = [];
    for r in rows {
        prs.append(PRSummary(
            ref=str(r["number"]), number=int(r["number"]), title=r.get("title", ""),
            author=(r.get("author") or {}).get("login", ""), branch=r.get("headRefName", ""),
            base=r.get("baseRefName", ""), draft=bool(r.get("isDraft")), updated=r.get("updatedAt", ""),
            rel=relative_time(r.get("updatedAt", "")), additions=int(r.get("additions") or 0),
            deletions=int(r.get("deletions") or 0), files=int(r.get("changedFiles") or 0),
            review=_review_state(r.get("reviewDecision", "")), url=r.get("url", "")
        ));
    }
    return (prs, "");
}

def default_branch(repo_dir: str) -> str {
    (rc, out, _) = _run(["git", "symbolic-ref", "--short", "refs/remotes/origin/HEAD"], repo_dir, 10);
    if rc == 0 and out.strip() {
        return out.strip();
    }
    for cand in ["main", "master", "trunk", "develop"] {
        (rc2, _, _) = _run(["git", "show-ref", "--verify", "--quiet", "refs/heads/" + cand], repo_dir, 10);
        if rc2 == 0 {
            return cand;
        }
    }
    return "HEAD";
}

"""Unmerged local branches as stand-in PRs, newest first."""
def local_list(repo_dir: str, limit: int) -> list[PRSummary] {
    base = default_branch(repo_dir);
    base_short = base.split("/", 1)[1] if base.startswith("origin/") else base;
    fmt = "%(refname:short)\x1f%(committerdate:iso-strict)\x1f%(authorname)\x1f%(subject)";
    (rc, out, _) = _run(["git", "for-each-ref", "--sort=-committerdate", "--format=" + fmt, "--no-merged=" + base, "refs/heads"], repo_dir, 30);
    if rc != 0 {
        return [];
    }
    prs: list[PRSummary] = [];
    for line in out.splitlines() {
        f = line.split("\x1f");
        if len(f) < 4 or f[0] == base_short {
            continue;
        }
        (_, stat, _) = _run(["git", "diff", "--shortstat", base + "..." + f[0]], repo_dir, 30);
        nums = [int(x) for x in re.findall(r"(\d+) (?:file|insertion|deletion)", stat)];
        files_n = nums[0] if len(nums) > 0 else 0;
        adds = int(m.group(1)) if (m := re.search(r"(\d+) insertion", stat)) else 0;
        dels = int(m2.group(1)) if (m2 := re.search(r"(\d+) deletion", stat)) else 0;
        prs.append(PRSummary(
            ref=f[0], title=f[3], author=f[2], branch=f[0], base=base_short, updated=f[1],
            rel=relative_time(f[1]), additions=adds, deletions=dels, files=files_n
        ));
        if len(prs) >= limit {
            break;
        }
    }
    return prs;
}

def list_prs(cwd: str, limit: int) -> PRList {
    repo_dir = repo_root(cwd);
    if not repo_dir {
        return PRList(ok=False, error="not a git repository");
    }
    repo = github_repo(repo_dir);
    gh = gh_path();
    note = "";
    if repo and gh {
        (prs, err) = gh_list(gh, repo_dir, repo, limit);
        if not err {
            return PRList(repo=repo, source="github", prs=prs);
        }
        note = "GitHub unavailable (" + err.splitlines()[0][:160] + ") - showing local branches";
    } elif repo {
        note = "Install and log in to the GitHub CLI (gh) to see pull requests - showing local branches";
    } else {
        note = "No GitHub remote - showing unmerged local branches";
    }
    return PRList(repo=repo or os.path.basename(repo_dir), source="local", note=note, prs=local_list(repo_dir, limit));
}

# ------------------------------------------------------------------ impact

def _check_state(c: dict[str, any]) -> str {
    concl = (c.get("conclusion") or "").upper();
    state = (c.get("state") or c.get("status") or "").upper();
    if concl in ["SUCCESS"] or state == "SUCCESS" {
        return "success";
    }
    if concl in ["FAILURE", "TIMED_OUT", "CANCELLED", "ACTION_REQUIRED", "STARTUP_FAILURE"] or state in ["FAILURE", "ERROR"] {
        return "failure";
    }
    if concl in ["SKIPPED", "NEUTRAL", "STALE"] {
        return "neutral";
    }
    return "pending";
}

"""Map repo-relative paths to boxes and architecture components, and walk the import graph backwards
to find the modules that depend on what changed."""
def attach_impact(detail: PRDetail, repo_dir: str, raw_files: list[tuple[str, int, int]]) -> None {
    p = current_project();
    prefix = os.path.relpath(p.root_dir, repo_dir) if p is not None else ".";
    prefix = "" if prefix == "." else prefix + "/";
    stored = load_stored(p.root_dir) if p is not None else None;
    assignments: dict[str, any] = stored.get("assignments", {}) if stored else {};
    comps = {c["id"]: c for c in stored["arch"]["components"]} if stored else {};
    detail.arch_mapped = len(comps) > 0;
    dir_comp: dict[str, dict[str, int]] = {};
    for (mod, a) in assignments.items() {
        d = os.path.dirname(mod);
        cid = a.get("component", "");
        if cid {
            dir_comp.setdefault(d, {})[cid] = dir_comp.get(d, {}).get(cid, 0) + 1;
        }
    }
    boxes: set[str] = set();
    changed: set[str] = set();
    per_comp: dict[str, PRComponent] = {};
    for (path, added, deleted) in raw_files {
        f = PRFile(path=path, added=added, deleted=deleted);
        if p is None or not path.startswith(prefix) {
            detail.outside += 1;
            detail.files.append(f);
            continue;
        }
        rel = path[len(prefix):];
        if rel in p.boxes {
            f.box_id = rel;
            changed.add(rel);
        } else {
            f.is_new = True;
            d = os.path.dirname(rel);
            while d and d not in p.boxes {
                d = os.path.dirname(d);
            }
            f.box_id = d;
        }
        top = rel.split("/")[0];
        if top in p.boxes {
            boxes.add(top);
        }
        cid = (assignments.get(rel) or {}).get("component", "");
        if not cid {
            d = os.path.dirname(rel);
            while True {
                votes = dir_comp.get(d);
                if votes {
                    cid = max(votes.items(), key=lambda (kv: any) -> int { kv[1] })[0];
                    break;
                }
                if not d {
                    break;
                }
                d = os.path.dirname(d);
            }
        }
        if cid and cid in comps {
            f.component = cid;
            pc = per_comp.get(cid);
            if pc is None {
                c = comps[cid];
                owner = comps.get(c.get("parent", ""));
                pc = PRComponent(id=cid, name=c["name"], parent_name=owner["name"] if owner else "");
                per_comp[cid] = pc;
            }
            pc.files += 1;
            pc.added += added;
            pc.deleted += deleted;
        }
        detail.files.append(f);
    }
    detail.boxes = sorted(boxes);
    detail.components = sorted(per_comp.values(), key=lambda (c: PRComponent) -> int { -(c.added + c.deleted) });
    if p is not None and changed {
        proj: ProjectData = p;
        deps: dict[str, int] = {};
        for (consumer, provs) in proj.mod_deps.items() {
            if consumer in changed {
                continue;
            }
            hits = sum([n for (prov, n) in provs.items() if prov in changed]);
            if hits {
                deps[consumer] = hits;
            }
        }
        detail.dependents = len(deps);
        ranked = sorted(deps.keys(), key=lambda (k: str) -> int { -(proj.boxes[k].fan_in if k in proj.boxes else 0) });
        detail.dependent_sample = ranked[:8];
    }
}

def gh_detail(gh: str, repo_dir: str, repo: str, num: int) -> PRDetail {
    fields = "number,title,author,headRefName,baseRefName,isDraft,updatedAt,additions,deletions,changedFiles,reviewDecision,url,body,files,statusCheckRollup";
    (rc, out, err) = _run([gh, "pr", "view", str(num), "--repo", repo, "--json", fields], repo_dir, 60);
    if rc != 0 {
        return PRDetail(ok=False, error=(err.strip() or "gh pr view failed")[:300]);
    }
    try {
        r = json.loads(out);
    } except ValueError {
        return PRDetail(ok=False, error="gh returned unreadable output");
    }
    summary = PRSummary(
        ref=str(r["number"]), number=int(r["number"]), title=r.get("title", ""),
        author=(r.get("author") or {}).get("login", ""), branch=r.get("headRefName", ""),
        base=r.get("baseRefName", ""), draft=bool(r.get("isDraft")), updated=r.get("updatedAt", ""),
        rel=relative_time(r.get("updatedAt", "")), additions=int(r.get("additions") or 0),
        deletions=int(r.get("deletions") or 0), files=int(r.get("changedFiles") or 0),
        review=_review_state(r.get("reviewDecision", "")), url=r.get("url", "")
    );
    detail = PRDetail(source="github", summary=summary, body=(r.get("body") or "")[:20000]);
    for c in r.get("statusCheckRollup") or [] {
        detail.checks.append(PRCheck(name=c.get("name") or c.get("context") or "check", state=_check_state(c)));
    }
    raw = [(f["path"], int(f.get("additions") or 0), int(f.get("deletions") or 0)) for f in r.get("files") or []];
    attach_impact(detail, repo_dir, raw);
    return detail;
}

def local_detail(repo_dir: str, branch: str) -> PRDetail {
    (rc, _, _) = _run(["git", "show-ref", "--verify", "--quiet", "refs/heads/" + branch], repo_dir, 10);
    if rc != 0 {
        return PRDetail(ok=False, error="no such branch");
    }
    base = default_branch(repo_dir);
    fmt = "%an\x1f%cI\x1f%s\x1f%b";
    (_, info, _) = _run(["git", "log", "-1", "--format=" + fmt, branch], repo_dir, 10);
    f = info.split("\x1f");
    (_, log, _) = _run(["git", "log", "--format=- %s", base + ".." + branch], repo_dir, 20);
    (_, numstat, _) = _run(["git", "diff", "--numstat", "-M", base + "..." + branch], repo_dir, 60);
    raw: list[tuple[str, int, int]] = [];
    for line in numstat.splitlines() {
        cols = line.split("\t");
        if len(cols) >= 3 {
            path = cols[2];
            if " => " in path {
                path = re.sub(r"\{[^}]* => ([^}]*)\}", lambda (m: any) -> str { m.group(1) }, path).split(" => ")[-1];
            }
            raw.append((path, int(cols[0]) if cols[0].isdigit() else 0, int(cols[1]) if cols[1].isdigit() else 0));
        }
    }
    summary = PRSummary(
        ref=branch, title=f[2] if len(f) > 2 else branch, author=f[0] if f else "", branch=branch,
        base=base.split("/", 1)[1] if base.startswith("origin/") else base, updated=f[1] if len(f) > 1 else "",
        rel=relative_time(f[1]) if len(f) > 1 else "", additions=sum([x[1] for x in raw]),
        deletions=sum([x[2] for x in raw]), files=len(raw)
    );
    detail = PRDetail(source="local", summary=summary, body="Commits on this branch:" + chr(10) + log.strip());
    attach_impact(detail, repo_dir, raw);
    return detail;
}

def pr_detail(cwd: str, ref: str) -> PRDetail {
    repo_dir = repo_root(cwd);
    if not repo_dir {
        return PRDetail(ok=False, error="not a git repository");
    }
    if ref.isdigit() {
        repo = github_repo(repo_dir);
        gh = gh_path();
        if not (repo and gh) {
            return PRDetail(ok=False, error="GitHub CLI or remote unavailable");
        }
        return gh_detail(gh, repo_dir, repo, int(ref));
    }
    if not BRANCH_RE.match(ref) or ref.startswith("-") or ".." in ref {
        return PRDetail(ok=False, error="bad branch name");
    }
    return local_detail(repo_dir, ref);
}

"""The diff section for one file out of a unified multi-file diff."""
def slice_diff(full: str, path: str) -> str {
    out: list[str] = [];
    on = False;
    for line in full.split("\n") {
        if line.startswith("diff --git ") {
            on = line.endswith(" b/" + path);
        }
        if on {
            out.append(line);
        }
    }
    return "\n".join(out);
}

def pr_diff(cwd: str, ref: str, path: str) -> str {
    if "\n" in path or path.startswith("-") or not path {
        return "";
    }
    repo_dir = repo_root(cwd);
    if not repo_dir {
        return "";
    }
    if ref.isdigit() {
        repo = github_repo(repo_dir);
        gh = gh_path();
        if not (repo and gh) {
            return "";
        }
        key = repo + "#" + ref;
        if key not in _diffs {
            (rc, out, err) = _run([gh, "pr", "diff", ref, "--repo", repo, "--color", "never"], repo_dir, 90);
            if rc != 0 {
                return "Could not fetch the diff: " + err.strip()[:300];
            }
            if len(_diffs) > 12 {
                _diffs.clear();
            }
            _diffs[key] = out;
        }
        text = slice_diff(_diffs[key], path);
    } else {
        if not BRANCH_RE.match(ref) or ref.startswith("-") or ".." in ref {
            return "";
        }
        base = default_branch(repo_dir);
        (_, text, _) = _run(["git", "diff", "-M", "--no-color", base + "..." + ref, "--", path], repo_dir, 60);
    }
    lines = text.splitlines();
    return "\n".join(lines[:3000]) + ("\n… diff truncated" if len(lines) > 3000 else "");
}

# ------------------------------------------------------------------ endpoints

def:pub review_prs(token: str, limit: int = 60) -> PRList {
    if not authorized(token) {
        return PRList(ok=False, error="unauthorized");
    }
    p = current_project();
    if p is None {
        return PRList(ok=False, error="No project open");
    }
    return list_prs(p.root_dir, max(min(limit, 200), 1));
}

def:pub review_pr(token: str, ref: str) -> PRDetail {
    if not authorized(token) {
        return PRDetail(ok=False, error="unauthorized");
    }
    p = current_project();
    if p is None {
        return PRDetail(ok=False, error="No project open");
    }
    return pr_detail(p.root_dir, ref);
}

def:pub review_diff(token: str, ref: str, path: str) -> str {
    if not authorized(token) {
        return "";
    }
    p = current_project();
    if p is None {
        return "";
    }
    return pr_diff(p.root_dir, ref, path);
}
