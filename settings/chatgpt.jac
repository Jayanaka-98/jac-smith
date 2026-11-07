"""ChatGPT access through the official OpenAI Codex CLI.

The app never handles ChatGPT credentials itself: "Sign in with ChatGPT" runs `codex login`, which
performs OpenAI's own browser sign-in and stores the session in ~/.codex. The agent panel then runs
`codex exec` against the open project, so model access is billed to the user's ChatGPT plan.
The CLI is installed on demand into ~/.jac-smith/tools (app-managed, not global).
"""
import os;
import re;
import glob as pyglob;
import shutil;
import subprocess;
import tempfile;
import threading;

import from settings.credentials { APP_DIR }

glob TOOLS_DIR: str = os.path.join(APP_DIR, "tools");
glob _URL = re.compile(r"https://\S+");
glob _login_proc: any = None;
glob _login_lines: list[str] = [];

def _node_dirs() -> list[str] {
    home = os.path.expanduser("~");
    dirs = ["/opt/homebrew/bin", "/usr/local/bin", os.path.join(home, ".bun", "bin")];
    dirs.extend(sorted(pyglob.glob(os.path.join(home, ".nvm", "versions", "node", "*", "bin")), reverse=True));
    return [d for d in dirs if os.path.isdir(d)];
}

"""PATH for child processes. A desktop app launched from Finder inherits a minimal PATH, so node may be missing."""
def tool_env() -> dict[str, str] {
    env = dict(os.environ);
    parts = env.get("PATH", "").split(os.pathsep);
    for d in _node_dirs() {
        if d not in parts {
            parts.append(d);
        }
    }
    env["PATH"] = os.pathsep.join([p for p in parts if p]);
    return env;
}

def codex_path() -> str {
    local = os.path.join(TOOLS_DIR, "node_modules", ".bin", "codex");
    if os.path.exists(local) {
        return local;
    }
    return shutil.which("codex", path=tool_env()["PATH"]) or "";
}

def npm_path() -> str {
    return shutil.which("npm", path=tool_env()["PATH"]) or "";
}

def install_codex() -> str {
    npm = npm_path();
    if not npm {
        return "npm was not found. Install Node.js (https://nodejs.org), then try again.";
    }
    os.makedirs(TOOLS_DIR, exist_ok=True);
    try {
        r = subprocess.run(
            [npm, "install", "--prefix", TOOLS_DIR, "@openai/codex"],
            capture_output=True, text=True, timeout=600, env=tool_env()
        );
    } except subprocess.TimeoutExpired {
        return "Installing the Codex CLI timed out.";
    }
    if r.returncode != 0 {
        return "npm install failed: " + (r.stderr or r.stdout)[-600:];
    }
    return "Installed the Codex CLI into " + TOOLS_DIR;
}

"""Returns (signed_in, human-readable status)."""
def login_status() -> tuple[bool, str] {
    cx = codex_path();
    if not cx {
        return (False, "Codex CLI not installed");
    }
    try {
        r = subprocess.run([cx, "login", "status"], capture_output=True, text=True, timeout=20, env=tool_env());
    } except Exception as e {
        return (False, "status check failed: " + str(e));
    }
    text = ((r.stdout or "") + (r.stderr or "")).strip();
    return (r.returncode == 0 and "logged in" in text.lower(), text.splitlines()[-1] if text else "not signed in");
}

def login_in_progress() -> bool {
    return _login_proc is not None and _login_proc.poll() is None;
}

def login_url() -> str {
    for line in _login_lines {
        m = _URL.search(line);
        if m and "auth" in m.group(0) {
            return m.group(0);
        }
    }
    return "";
}

def _pump(proc: any) -> None {
    for line in proc.stdout {
        _login_lines.append(line.rstrip());
    }
}

"""Start the official browser sign-in. Returns immediately; the UI polls status."""
def start_login() -> str {
    if login_in_progress() {
        return "Sign-in already in progress - finish it in your browser.";
    }
    cx = codex_path();
    if not cx {
        return "Install the Codex CLI first.";
    }
    _login_lines.clear();
    _login_proc = subprocess.Popen(
        [cx, "login"],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
        text=True, env=tool_env()
    );
    threading.Thread(target=_pump, args=(_login_proc,), daemon=True).start();
    return "Opening ChatGPT sign-in in your browser...";
}

def cancel_login() -> None {
    if login_in_progress() {
        _login_proc.terminate();
    }
}

def logout() -> str {
    cx = codex_path();
    if not cx {
        return "Codex CLI not installed";
    }
    r = subprocess.run([cx, "logout"], capture_output=True, text=True, timeout=20, env=tool_env());
    return ((r.stdout or "") + (r.stderr or "")).strip() or "Signed out";
}

"""Run one Codex turn in the project directory and return its final message."""
def codex_exec(prompt: str, cwd: str, allow_edits: bool, model: str = "") -> tuple[bool, str] {
    cx = codex_path();
    if not cx {
        return (False, "The Codex CLI is not installed. Open Settings and choose Install.");
    }
    (fd, out_file) = tempfile.mkstemp(prefix="jac-smith-codex-", suffix=".txt");
    os.close(fd);
    cmd = [
        cx, "exec", "--skip-git-repo-check", "--ephemeral", "--color", "never",
        "-C", cwd,
        "-s", "workspace-write" if allow_edits else "read-only",
        "-o", out_file
    ];
    if model {
        cmd.extend(["-m", model]);
    }
    cmd.append("-");
    try {
        r = subprocess.run(
            cmd, input=prompt, capture_output=True, text=True, timeout=900, cwd=cwd, env=tool_env()
        );
        with open(out_file, encoding="utf-8", errors="replace") as fh {
            answer = fh.read().strip();
        }
    } except subprocess.TimeoutExpired {
        return (False, "Codex timed out after 15 minutes.");
    } finally {
        try { os.remove(out_file); } except OSError {}
    }
    if r.returncode != 0 and not answer {
        return (False, "Codex failed: " + ((r.stderr or "") + (r.stdout or "")).strip()[-1500:]);
    }
    return (True, answer or (r.stdout or "").strip()[-4000:]);
}
