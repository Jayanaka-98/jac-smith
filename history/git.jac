"""Git history for the History view: a lane-laid-out commit graph, commit details, and file diffs.

Lanes are computed here so the UI only draws: every row carries its commit's column plus the line
segments arriving from the row above (straight continuations, merges converging into this commit)
and the branch-off segments leaving it toward the row below.
"""
import os;
import re;
import subprocess;
import from datetime { datetime, timezone }

import from settings.session { authorized }
import from indexer.api { current_project }

glob SEP: str = "\x1f";
glob HASH_RE = re.compile(r"^[0-9a-f]{7,40}$");

obj Segment {
    has a: int;
    has b: int;
    has lane: int;
}

obj CommitRow {
    has hash: str;
    has short: str;
    has parents: list[str] = [];
    has author: str = "";
    has date: str = "";
    has rel: str = "";
    has subject: str = "";
    has refs: list[str] = [];
    has col: int = 0;
    has incoming: list[Segment] = [];
    has outgoing: list[Segment] = [];
}

obj GitLog {
    has ok: bool = True;
    has error: str = "";
    has repo: str = "";
    has scoped: bool = False;
    has head: str = "";
    has branch: str = "";
    has commits: list[CommitRow] = [];
    has lanes: int = 1;
    has more: bool = False;
}

obj FileChange {
    has path: str;
    has status: str = "M";
    has added: int = 0;
    has deleted: int = 0;
    has box_id: str = "";
}

obj CommitDetail {
    has ok: bool = True;
    has error: str = "";
    has hash: str = "";
    has author: str = "";
    has email: str = "";
    has date: str = "";
    has message: str = "";
    has parents: list[str] = [];
    has refs: list[str] = [];
    has files: list[FileChange] = [];
    has boxes: list[str] = [];
}

def _git(args: list[str], cwd: str, timeout: int = 30) -> tuple[int, str, str] {
    try {
        r = subprocess.run(["git"] + args, capture_output=True, text=True, timeout=timeout, cwd=cwd, errors="replace");
    } except (OSError, subprocess.TimeoutExpired) as e {
        return (1, "", str(e));
    }
    return (r.returncode, r.stdout, r.stderr);
}

def repo_root(cwd: str) -> str {
    (rc, out, _) = _git(["rev-parse", "--show-toplevel"], cwd);
    return out.strip() if rc == 0 else "";
}

def relative_time(iso: str) -> str {
    try {
        then = datetime.fromisoformat(iso);
        secs = (datetime.now(timezone.utc) - then).total_seconds();
    } except ValueError {
        return "";
    }
    for (unit, size) in [("y", 31536000), ("mo", 2592000), ("d", 86400), ("h", 3600), ("m", 60)] {
        if secs >= size {
            return str(int(secs // size)) + unit + " ago";
        }
    }
    return "just now";
}

"""Assign lanes. Lanes keep their index for their lifetime (trailing empties are trimmed)."""
def layout(rows: list[CommitRow]) -> int {
    lanes: list[str | None] = [];
    origin: dict[int, int] = {};
    widest = 1;
    for row in rows {
        hits = [j for (j, h) in enumerate(lanes) if h == row.hash];
        if hits {
            col = hits[0];
        } else {
            free = [j for (j, h) in enumerate(lanes) if h is None];
            col = free[0] if free else len(lanes);
        }
        for (j, h) in enumerate(lanes) {
            if h is not None {
                row.incoming.append(Segment(a=origin.get(j, j), b=col if h == row.hash else j, lane=j if h != row.hash else col));
            }
        }
        for j in hits {
            lanes[j] = None;
        }
        while len(lanes) <= col {
            lanes.append(None);
        }
        new_origin: dict[int, int] = {j: j for (j, h) in enumerate(lanes) if h is not None};
        if row.parents {
            lanes[col] = row.parents[0];
            new_origin[col] = col;
            for par in row.parents[1:] {
                if par in lanes {
                    j = lanes.index(par);
                    row.outgoing.append(Segment(a=col, b=j, lane=j));
                } else {
                    free = [j for (j, h) in enumerate(lanes) if h is None and j != col];
                    j = free[0] if free else len(lanes);
                    while len(lanes) <= j {
                        lanes.append(None);
                    }
                    lanes[j] = par;
                    new_origin[j] = col;
                }
            }
        }
        row.col = col;
        origin = new_origin;
        while lanes and lanes[-1] is None {
            lanes.pop();
        }
        widest = max(widest, len(lanes), col + 1);
    }
    return widest;
}

def read_log(cwd: str, limit: int, offset: int, scoped: bool) -> GitLog {
    repo_dir = repo_root(cwd);
    if not repo_dir {
        return GitLog(ok=False, error="This project is not inside a git repository.");
    }
    fmt = SEP.join(["%H", "%P", "%an", "%aI", "%s", "%D"]);
    args = ["log", "--all", "--date-order", "--pretty=format:" + fmt, "-n", str(limit + 1), "--skip", str(offset)];
    if scoped and os.path.realpath(cwd) != os.path.realpath(repo_dir) {
        args = args[:1] + ["--parents"] + args[1:] + ["--", os.path.relpath(cwd, repo_dir)];
    }
    (rc, out, err) = _git(args, repo_dir, 60);
    if rc != 0 {
        if "does not have any commits" in err or "bad default revision" in err {
            return GitLog(ok=True, repo=repo_dir, error="No commits yet.");
        }
        return GitLog(ok=False, repo=repo_dir, error=err.strip()[:300]);
    }
    rows: list[CommitRow] = [];
    for line in out.splitlines() {
        parts = line.split(SEP);
        if len(parts) < 6 {
            continue;
        }
        refs = [x.strip().replace("HEAD -> ", "HEAD → ") for x in parts[5].split(",") if x.strip()];
        rows.append(CommitRow(
            hash=parts[0], short=parts[0][:7], parents=[x for x in parts[1].split() if x],
            author=parts[2], date=parts[3], rel=relative_time(parts[3]), subject=parts[4], refs=refs
        ));
    }
    more = len(rows) > limit;
    rows = rows[:limit];
    lanes = layout(rows);
    (_, head, _) = _git(["rev-parse", "--short", "HEAD"], repo_dir);
    (_, branch, _) = _git(["rev-parse", "--abbrev-ref", "HEAD"], repo_dir);
    return GitLog(ok=True, repo=repo_dir, scoped=scoped, head=head.strip(), branch=branch.strip(), commits=rows, lanes=lanes, more=more);
}

def commit_detail(cwd: str, sha: str) -> CommitDetail {
    if not HASH_RE.match(sha) {
        return CommitDetail(ok=False, error="bad commit id");
    }
    repo_dir = repo_root(cwd);
    if not repo_dir {
        return CommitDetail(ok=False, error="not a git repository");
    }
    fmt = SEP.join(["%H", "%an", "%ae", "%aI", "%P", "%D", "%B"]);
    (rc, out, err) = _git(["show", "-s", "--pretty=format:" + fmt, sha], repo_dir);
    if rc != 0 {
        return CommitDetail(ok=False, error=err.strip()[:300]);
    }
    f = out.split(SEP);
    detail = CommitDetail(
        hash=f[0], author=f[1], email=f[2], date=f[3], parents=f[4].split(),
        refs=[x.strip() for x in f[5].split(",") if x.strip()], message=SEP.join(f[6:]).strip()
    );
    (_, numstat, _) = _git(["show", "--numstat", "--format=", "-M", sha], repo_dir);
    (_, names, _) = _git(["show", "--name-status", "--format=", "-M", sha], repo_dir);
    status: dict[str, str] = {};
    for line in names.splitlines() {
        cols = line.split("\t");
        if len(cols) >= 2 {
            status[cols[-1]] = cols[0][:1];
        }
    }
    p = current_project();
    prefix = os.path.relpath(p.root_dir, repo_dir) if p is not None else ".";
    prefix = "" if prefix == "." else prefix + "/";
    boxes: set[str] = set();
    for line in numstat.splitlines() {
        cols = line.split("\t");
        if len(cols) < 3 {
            continue;
        }
        path = cols[2];
        if " => " in path {
            path = re.sub(r"\{[^}]* => ([^}]*)\}", lambda (m: any) -> str { m.group(1) }, path).split(" => ")[-1];
        }
        box_id = "";
        if p is not None and path.startswith(prefix) {
            rel = path[len(prefix):];
            if rel in p.boxes {
                box_id = rel;
                top = rel.split("/")[0];
                boxes.add(top if top in p.boxes else rel);
            }
        }
        detail.files.append(FileChange(
            path=path, status=status.get(path, "M"),
            added=int(cols[0]) if cols[0].isdigit() else 0, deleted=int(cols[1]) if cols[1].isdigit() else 0,
            box_id=box_id
        ));
    }
    detail.boxes = sorted(boxes);
    return detail;
}

def file_diff(cwd: str, sha: str, path: str) -> str {
    if not HASH_RE.match(sha) or "\n" in path or path.startswith("-") {
        return "";
    }
    repo_dir = repo_root(cwd);
    if not repo_dir {
        return "";
    }
    (rc, out, _) = _git(["show", "--format=", "-M", "--no-color", sha, "--", path], repo_dir, 60);
    lines = out.splitlines();
    return "\n".join(lines[:3000]) + ("\n… diff truncated" if len(lines) > 3000 else "");
}

def:pub git_log(token: str, limit: int = 400, offset: int = 0, scoped: bool = False) -> GitLog {
    if not authorized(token) {
        return GitLog(ok=False, error="unauthorized");
    }
    p = current_project();
    if p is None {
        return GitLog(ok=False, error="No project open");
    }
    return read_log(p.root_dir, max(min(limit, 2000), 1), max(offset, 0), scoped);
}

def:pub git_commit(token: str, sha: str) -> CommitDetail {
    if not authorized(token) {
        return CommitDetail(ok=False, error="unauthorized");
    }
    p = current_project();
    if p is None {
        return CommitDetail(ok=False, error="No project open");
    }
    return commit_detail(p.root_dir, sha);
}

def:pub git_file_diff(token: str, sha: str, path: str) -> str {
    if not authorized(token) {
        return "";
    }
    p = current_project();
    if p is None {
        return "";
    }
    return file_diff(p.root_dir, sha, path);
}

# ------------------------------------------------------------------ timeline (horizontal history view)

glob _PR = re.compile(r"\(#(\d+)\)|[Mm]erge pull request #(\d+)");
glob _KIND = re.compile(r"^(\w+)(?:\([^)]*\))?!?:");

obj TCommit {
    has hash: str;
    has short: str;
    has ts: int = 0;
    has subject: str = "";
    has author: str = "";
    has kind: str = "";
    has pr: int = 0;
    has merge: bool = False;
    has refs: list[str] = [];
}

"""A side lane: a merged PR branch (real merge commit) or an unmerged branch."""
obj Lane {
    has kind: str;
    has name: str = "";
    has pr: int = 0;
    has commits: list[TCommit] = [];
    has fork: int = -1;
    has merge: int = -1;
}

obj Timeline {
    has ok: bool = True;
    has error: str = "";
    has branch: str = "";
    has current: str = "";
    has head: str = "";
    has main: list[TCommit] = [];
    has lanes: list[Lane] = [];
}

def _tcommits(repo_dir: str, args: list[str]) -> list[TCommit] {
    fmt = SEP.join(["%H", "%P", "%ct", "%s", "%an", "%D"]);
    (rc, out, _) = _git(["log", "--format=" + fmt] + args, repo_dir, 60);
    if rc != 0 {
        return [];
    }
    rows: list[TCommit] = [];
    for line in out.splitlines() {
        f = line.split(SEP);
        if len(f) < 6 {
            continue;
        }
        m = _PR.search(f[3]);
        k = _KIND.match(f[3]);
        rows.append(TCommit(
            hash=f[0], short=f[0][:7], ts=int(f[2] or 0), subject=f[3][:200], author=f[4],
            kind=(k.group(1).lower() if k else ("merge" if len(f[1].split()) > 1 else "")),
            pr=int(m.group(1) or m.group(2)) if m else 0, merge=len(f[1].split()) > 1,
            refs=[x.strip() for x in f[5].split(",") if x.strip()]
        ));
    }
    return rows;
}

glob TRUNK_NAMES: list[str] = ["main", "master", "upstream/main", "origin/main", "upstream/master", "origin/master", "trunk", "develop"];

"""The trunk the timeline runs along: the most recently updated of the main-like branches (local or
remote), so a checkout sitting on a feature branch still shows main as the top line."""
def trunk_ref(repo_dir: str) -> str {
    best = "";
    best_ts = -1;
    for name in TRUNK_NAMES {
        (rc, out, _) = _git(["log", "-1", "--format=%ct", name, "--"], repo_dir, 10);
        if rc == 0 and out.strip().isdigit() and int(out.strip()) > best_ts {
            best_ts = int(out.strip());
            best = name;
        }
    }
    return best or "HEAD";
}

def read_timeline(cwd: str, limit: int, max_branches: int) -> Timeline {
    repo_dir = repo_root(cwd);
    if not repo_dir {
        return Timeline(ok=False, error="This project is not inside a git repository.");
    }
    trunk = trunk_ref(repo_dir);
    main = _tcommits(repo_dir, ["--first-parent", "-n", str(limit), trunk]);
    if not main {
        return Timeline(ok=True, error="No commits yet.");
    }
    main.reverse();
    index = {c.hash: i for (i, c) in enumerate(main)};
    (_, branch, _) = _git(["rev-parse", "--abbrev-ref", "HEAD"], repo_dir);
    (_, parents_out, _) = _git(["log", "--first-parent", "--merges", "--format=%H %P", "-n", str(limit), trunk], repo_dir);
    lanes: list[Lane] = [];
    for line in parents_out.splitlines() {
        hs = line.split();
        if len(hs) < 3 or hs[0] not in index {
            continue;
        }
        (merge_sha, p1, p2) = (hs[0], hs[1], hs[2]);
        commits = _tcommits(repo_dir, ["-n", "40", p2, "^" + p1]);
        commits.reverse();
        (_, base, _) = _git(["merge-base", p1, p2], repo_dir);
        mc = main[index[merge_sha]];
        lanes.append(Lane(kind="pr", name=mc.subject, pr=mc.pr, commits=commits, fork=index.get(base.strip(), -1), merge=index[merge_sha]));
    }
    oldest = main[0].ts;
    (_, refs_out, _) = _git(["for-each-ref", "--sort=-committerdate", "refs/heads", "refs/remotes", "--format=%(refname:short)" + SEP + "%(objectname)" + SEP + "%(committerdate:unix)"], repo_dir);
    seen_tips: set[str] = set(index.keys());
    current = branch.strip();
    ref_lines = refs_out.splitlines();
    ref_lines.sort(key=lambda (ln: str) -> int { 0 if ln.split(SEP)[0] == current else 1 });
    for line in ref_lines {
        if len([l for l in lanes if l.kind == "branch"]) >= max_branches {
            break;
        }
        f = line.split(SEP);
        if len(f) < 3 or f[0].endswith("/HEAD") or f[0] == trunk or f[1] in seen_tips {
            continue;
        }
        if int(f[2] or 0) < oldest and f[0] != current {
            continue;
        }
        commits = _tcommits(repo_dir, ["-n", "30", f[1], "^" + trunk]);
        if not commits {
            continue;
        }
        seen_tips.add(f[1]);
        commits.reverse();
        (_, base, _) = _git(["merge-base", trunk, f[1]], repo_dir);
        lanes.append(Lane(kind="branch", name=f[0], commits=commits, fork=index.get(base.strip(), -1), merge=-1));
    }
    (_, head, _) = _git(["rev-parse", "--short", trunk], repo_dir);
    return Timeline(ok=True, branch=trunk, current=current, head=head.strip(), main=main, lanes=lanes);
}

def:pub git_timeline(token: str, limit: int = 300, branches: int = 12) -> Timeline {
    if not authorized(token) {
        return Timeline(ok=False, error="unauthorized");
    }
    p = current_project();
    if p is None {
        return Timeline(ok=False, error="No project open");
    }
    return read_timeline(p.root_dir, max(min(limit, 3000), 1), max(min(branches, 40), 0));
}
