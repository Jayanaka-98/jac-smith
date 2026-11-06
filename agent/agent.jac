"""The coding agent beside the views.

Two backends:
  codex - OpenAI Codex CLI running on the user's ChatGPT sign-in, in the project directory.
  jac   - a byLLM ReAct agent whose tools read the architecture graph, read/search/write files,
          run `jac check`, and load Jac skills on demand through `jac guide`.
Both are handed the architecture of the focused box, and both report which boxes they touched
so the views can light them up.
"""
import os;
import re;
import shutil;
import subprocess;

import from jaclang.byllm.lib { Model }
import from indexer.model { AgentReply, BoxInfo }
import from indexer.api { current_project, safe_path, reindex }
import from indexer.scan { SKIP_DIRS, LANG_BY_EXT }
import from settings.credentials { read_config }
import from settings.chatgpt { codex_exec, tool_env }
import from settings.session { authorized }
import from architect.discover { describe_architecture }

glob MAX_TOOL_OUT: int = 12000;
glob _touched: list[str] = [];
glob _edited: list[str] = [];
glob _allow_edits: bool = False;
glob history: list[dict[str, any]] = [];
glob _model_name: str = "";
glob agent_llm: Model = Model(model_name="gpt-4o-mini");

def _clip(text: str) -> str {
    if len(text) <= MAX_TOOL_OUT {
        return text;
    }
    return text[:MAX_TOOL_OUT] + "\n... [truncated " + str(len(text) - MAX_TOOL_OUT) + " chars]";
}

def _touch(bid: str) -> None {
    if bid and bid not in _touched {
        _touched.append(bid);
    }
}

def _describe(b: BoxInfo) -> str {
    p = current_project();
    lines = [
        b.kind.upper() + " " + (b.path or b.name) + "  role=" + (b.role or "?") + " tier=" + (b.tier or "?")
        + " importance=" + str(round(b.importance, 3)) + " loc=" + str(b.loc) + " fan_in=" + str(b.fan_in)
    ];
    if b.summary {
        lines.append("summary: " + b.summary);
    }
    if b.children and p is not None {
        lines.append("contains (most important first):");
        for c in b.children[:30] {
            cb = p.boxes[c];
            lines.append("  - " + c + " [" + cb.kind + ", " + (cb.role or "?") + ", importance " + str(round(cb.importance, 3)) + "]" + ((" - " + cb.summary) if cb.summary else ""));
        }
    }
    if b.symbols {
        lines.append("interfaces:");
        for s in b.symbols[:40] {
            if s.public {
                lines.append("  " + s.signature + "  (line " + str(s.line) + ")");
            }
        }
    }
    if b.depends_on {
        lines.append("depends on: " + ", ".join(b.depends_on[:30]));
    }
    if b.externals {
        lines.append("external: " + ", ".join([e.replace("ext:", "") for e in b.externals[:30]]));
    }
    if p is not None and b.kind == "module" {
        users = [m for (m, deps) in p.mod_deps.items() if b.id in deps];
        if users {
            lines.append("used by: " + ", ".join(users[:30]));
        }
    }
    return "\n".join(lines);
}

def describe_box(box_id: str) -> str {
    p = current_project();
    if p is None {
        return "No project is open.";
    }
    b = p.boxes.get(box_id.strip() or p.root_id);
    if b is None {
        return "No box with id '" + box_id + "'. Box ids are project-relative paths; the project root is '.'.";
    }
    _touch(b.id);
    return _clip(_describe(b));
}
sem describe_box = "Describe one box of the architecture: its role, importance, children, interfaces, dependencies and users.";
sem describe_box.box_id = "Project-relative path of a package directory or module file; '.' is the whole project.";

def project_architecture() -> str {
    p = current_project();
    if p is None {
        return "No project is open.";
    }
    return _clip(describe_architecture(p));
}
sem project_architecture = "The project's discovered domain architecture: its components (e.g. compiler stages and passes), what each does, which paths implement it, and the flows between them. Read this first to orient.";

def read_file(path: str) -> str {
    full = safe_path(path);
    if not full or not os.path.isfile(full) {
        return "Not a file inside the project: " + path;
    }
    _touch(path);
    with open(full, encoding="utf-8", errors="replace") as fh {
        text = fh.read();
    }
    numbered = "\n".join([str(i + 1).rjust(5) + "  " + l for (i, l) in enumerate(text.splitlines())]);
    return _clip(numbered);
}
sem read_file = "Read a source file in the project, with line numbers.";
sem read_file.path = "Project-relative file path.";

def search_code(pattern: str) -> str {
    p = current_project();
    if p is None {
        return "No project is open.";
    }
    try {
        rx = re.compile(pattern);
    } except re.error as e {
        return "Bad regex: " + str(e);
    }
    hits: list[str] = [];
    for (dirpath, dirnames, filenames) in os.walk(p.root_dir) {
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not d.startswith(".")];
        for f in filenames {
            if os.path.splitext(f)[1] not in LANG_BY_EXT and not f.endswith((".toml", ".md", ".json", ".css")) {
                continue;
            }
            full = os.path.join(dirpath, f);
            rel = os.path.relpath(full, p.root_dir).replace(os.sep, "/");
            try {
                with open(full, encoding="utf-8", errors="replace") as fh {
                    for (i, line) in enumerate(fh.read().splitlines()) {
                        if rx.search(line) {
                            hits.append(rel + ":" + str(i + 1) + ": " + line.rstrip()[:200]);
                            if len(hits) >= 80 {
                                return _clip("\n".join(hits) + "\n... (first 80 matches)");
                            }
                        }
                    }
                }
            } except OSError {
                continue;
            }
        }
    }
    return "\n".join(hits) if hits else "No matches.";
}
sem search_code = "Search project files with a Python regular expression; returns path:line: text for up to 80 matches.";
sem search_code.pattern = "Python regular expression.";

def write_file(path: str, content: str) -> str {
    if not _allow_edits {
        return "Edits are turned off for this request. Describe the change instead; the user can enable edits in the agent panel.";
    }
    full = safe_path(path);
    if not full {
        return "Refusing to write outside the project: " + path;
    }
    os.makedirs(os.path.dirname(full), exist_ok=True);
    with open(full, "w", encoding="utf-8") as fh {
        fh.write(content);
    }
    if path not in _edited {
        _edited.append(path);
    }
    _touch(path);
    return "Wrote " + str(len(content)) + " chars to " + path;
}
sem write_file = "Create or overwrite a file in the project with the full new content.";
sem write_file.path = "Project-relative file path.";
sem write_file.content = "The complete new file content.";

def _jac(args: list[str], cwd: str) -> str {
    jac_bin = shutil.which("jac", path=tool_env()["PATH"] + os.pathsep + os.path.expanduser("~/.local/bin"));
    if not jac_bin {
        return "The jac CLI is not on PATH.";
    }
    try {
        r = subprocess.run([jac_bin] + args, capture_output=True, text=True, timeout=120, cwd=cwd, env=tool_env());
    } except subprocess.TimeoutExpired {
        return "jac " + " ".join(args) + " timed out.";
    }
    return _clip(((r.stdout or "") + (r.stderr or "")).strip() or "(no output)");
}

def jac_guide(topic: str) -> str {
    p = current_project();
    cwd = p.root_dir if p is not None else os.path.expanduser("~");
    t = topic.strip();
    if not t {
        return _jac(["guide"], cwd);
    }
    return _jac(["guide", t], cwd);
}
sem jac_guide = "Load a Jac skill guide (versioned Jac language and tooling guidance shipped with the installed compiler). Call with an empty topic to list all guides. Always read jac-essentials and the guide for the task before writing Jac.";
sem jac_guide.topic = "Guide name such as jac-essentials, jac-cl-components, jac-walker-patterns; empty string lists all guides.";

def jac_check(path: str) -> str {
    p = current_project();
    if p is None {
        return "No project is open.";
    }
    target = path.strip() or ".";
    if target != "." and not safe_path(target) {
        return "Not inside the project: " + path;
    }
    return _jac(["check", target], p.root_dir);
}
sem jac_check = "Type-check Jac code with the compiler. Run after every edit to a .jac file.";
sem jac_check.path = "Project-relative file or directory to check; '.' checks the whole project.";

def run_jac_agent(request: str, focus_context: str) -> str by agent_llm(
    tools=[project_architecture, describe_box, read_file, search_code, write_file, jac_guide, jac_check],
    conversation=history,
    max_react_iterations=24,
    system_prompt="You are the coding agent inside jac smith, an architecture-first IDE. Developers see their project as nested boxes (packages and modules, sized by importance) and as a dependency graph, not as files. Ground every answer in the architecture: start from describe_box, then read code only where needed. When you write or change Jac code, first load the relevant guides with jac_guide (jac-essentials, then the task guide), and run jac_check on what you changed. Keep answers short and refer to boxes by their project-relative path."
);
sem run_jac_agent = "Help the developer with their request about the open project.";
sem run_jac_agent.request = "The developer's message.";
sem run_jac_agent.focus_context = "Architecture of the box the developer is currently focused on.";

def _ensure_model() -> None {
    name = str(read_config().get("agent_model", "") or "gpt-4o-mini");
    if name != _model_name {
        agent_llm = Model(model_name=name);
        _model_name = name;
    }
}

def _snapshot_mtimes(root_dir: str) -> dict[str, float] {
    out: dict[str, float] = {};
    for (dirpath, dirnames, filenames) in os.walk(root_dir) {
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not d.startswith(".")];
        for f in filenames {
            full = os.path.join(dirpath, f);
            try {
                out[os.path.relpath(full, root_dir).replace(os.sep, "/")] = os.path.getmtime(full);
            } except OSError {
                continue;
            }
        }
    }
    return out;
}

def _codex_prompt(request: str, focus_context: str, arch_context: str, allow_edits: bool) -> str {
    return "\n".join([
        "You are working inside jac smith, an architecture-first IDE.",
        "",
        "Domain architecture of the project:",
        arch_context,
        "",
        "The developer is looking at this part of the code map:",
        "",
        focus_context,
        "",
        "If you write or change Jac (.jac) code, first run `jac guide jac-essentials` and the guide for the task (`jac guide` lists them), and run `jac check` on what you changed.",
        "Edits are " + ("allowed." if allow_edits else "NOT allowed: answer and propose changes without modifying files."),
        "Keep the answer short; refer to code by project-relative path.",
        "",
        "Developer request:",
        request
    ]);
}

def:pub ask_agent(token: str, message: str, focus_id: str, backend: str = "", allow_edits: bool = False, context: str = "", context_file: str = "") -> AgentReply {
    if not authorized(token) {
        return AgentReply(text="unauthorized", ok=False);
    }
    p = current_project();
    if p is None {
        return AgentReply(text="Open a project first.", ok=False);
    }
    _touched.clear();
    _edited.clear();
    _allow_edits = allow_edits;
    chosen = backend or str(read_config().get("agent_backend", "codex"));
    if context {
        message = message + "\n\nThe developer selected this code" + (" in " + context_file if context_file else "") + ":\n```\n" + context[:12000] + "\n```";
    }
    focus = p.boxes.get(focus_id) or p.boxes[p.root_id];
    focus_context = _describe(focus);

    if chosen == "codex" {
        before = _snapshot_mtimes(p.root_dir);
        (ok, text) = codex_exec(_codex_prompt(message, focus_context, describe_architecture(p)[:6000], allow_edits), p.root_dir, allow_edits);
        after = _snapshot_mtimes(p.root_dir);
        changed = sorted([f for (f, t) in after.items() if before.get(f) != t] + [f for f in before.keys() if f not in after]);
        for f in changed {
            _edited.append(f);
            _touch(f);
        }
        _touch(focus.id);
        if context_file {
            _touch(context_file);
        }
        reply = AgentReply(text=text, backend="codex", ok=ok, touched=list(_touched), edited=list(_edited));
    } else {
        _ensure_model();
        try {
            text = run_jac_agent(message, focus_context);
            reply = AgentReply(text=str(text), backend="jac:" + _model_name, touched=list(_touched), edited=list(_edited));
        } except Exception as e {
            reply = AgentReply(text="The Jac agent failed: " + str(e), backend="jac:" + _model_name, ok=False);
        }
    }
    if reply.edited {
        reply.reindexed = reindex().ok;
    }
    return reply;
}

def:pub reset_agent(token: str) -> bool {
    if not authorized(token) {
        return False;
    }
    history.clear();
    return True;
}
