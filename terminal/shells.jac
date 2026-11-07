"""Integrated terminal: real PTY sessions running the user's login shell.

Output is buffered per session (bounded) and streamed to the UI over SSE from a byte offset, so a
dropped stream resumes without losing output. Keystrokes and resizes arrive as small RPCs.
"""
import os;
import pty;
import fcntl;
import struct;
import signal;
import termios;
import codecs;
import secrets;
import threading;
import time;
import from typing { Generator }

import re;
import json;
import from settings.session { authorized }
import from settings.credentials { read_config }
import from settings.chatgpt { tool_env }
import from indexer.api { current_project }

glob MAX_BUFFER: int = 2000000;
glob STREAM_IDLE_S: float = 20.0;

obj TermInfo {
    has ok: bool = True;
    has error: str = "";
    has sid: str = "";
    has shell: str = "";
    has cwd: str = "";
}

"""How the UI should render the terminal so it matches the user's own (prompt themes like
powerlevel10k draw icons from a Nerd Font, so the font matters as much as the shell)."""
obj TermPrefs {
    has font_family: str = "";
    has font_size: float = 13.0;
    has source: str = "default";
    has shell: str = "";
}

glob _VSCODE_SETTINGS: list[str] = [
    "~/Library/Application Support/Code/User/settings.json",
    "~/Library/Application Support/Cursor/User/settings.json",
    "~/.config/Code/User/settings.json"
];
glob _FONT_DIRS: list[str] = ["~/Library/Fonts", "/Library/Fonts", "~/.local/share/fonts", "/usr/share/fonts"];

def _vscode_terminal_font() -> tuple[str, float] {
    for path in _VSCODE_SETTINGS {
        try {
            with open(os.path.expanduser(path), encoding="utf-8") as fh {
                text = fh.read();
            }
        } except OSError {
            continue;
        }
        fam = re.search(r'"terminal\.integrated\.fontFamily"\s*:\s*"([^"]+)"', text);
        size = re.search(r'"terminal\.integrated\.fontSize"\s*:\s*([0-9.]+)', text);
        if fam {
            return (fam.group(1), float(size.group(1)) if size else 0.0);
        }
    }
    return ("", 0.0);
}

def _installed_nerd_font() -> str {
    for d in _FONT_DIRS {
        full = os.path.expanduser(d);
        if not os.path.isdir(full) {
            continue;
        }
        for name in sorted(os.listdir(full)) {
            stem = os.path.splitext(name)[0];
            if " NF" in stem {
                return stem.split(" NF")[0] + " NF";
            }
            if "NerdFont" in stem {
                return stem.split("-")[0].replace("NerdFontMono", " Nerd Font Mono").replace("NerdFont", " Nerd Font");
            }
        }
    }
    return "";
}

def detect_term_prefs() -> TermPrefs {
    shell = os.path.basename(os.environ.get("SHELL") or "/bin/zsh");
    cfg = read_config();
    custom = str(cfg.get("terminal_font", "") or "");
    custom_size = float(cfg.get("terminal_font_size", 0) or 0);
    if custom {
        return TermPrefs(font_family=custom, font_size=custom_size or 13.0, source="jac smith settings", shell=shell);
    }
    (fam, size) = _vscode_terminal_font();
    if fam {
        return TermPrefs(font_family=fam, font_size=size or 13.0, source="VS Code terminal settings", shell=shell);
    }
    nf = _installed_nerd_font();
    if nf {
        return TermPrefs(font_family=nf, font_size=13.0, source="installed Nerd Font", shell=shell);
    }
    return TermPrefs(font_family="", font_size=13.0, source="default", shell=shell);
}

def:pub term_prefs(token: str) -> TermPrefs {
    if not authorized(token) {
        return TermPrefs(source="unauthorized");
    }
    return detect_term_prefs();
}

obj PtySession {
    has sid: str;
    has fd: int;
    has pid: int;
    has shell: str;
    has cwd: str;
    has chunks: list[bytes] = [];
    has base: int = 0;
    has size: int = 0;
    has alive: bool = True;
    has cond: any = None;

    def end_offset() -> int {
        return self.base + self.size;
    }

    def append(data: bytes) -> None {
        with self.cond {
            self.chunks.append(data);
            self.size += len(data);
            while self.size > MAX_BUFFER and len(self.chunks) > 1 {
                dropped = self.chunks.pop(0);
                self.size -= len(dropped);
                self.base += len(dropped);
            }
            self.cond.notify_all();
        }
    }

    """Bytes from `offset` to the end, and the new offset. Offsets older than the buffer clamp to its start."""
    def read_from(offset: int) -> tuple[bytes, int] {
        start = max(offset, self.base);
        drop_n = start - self.base;
        out = b"".join(self.chunks)[drop_n:];
        return (out, start + len(out));
    }
}

glob _sessions: dict[str, PtySession] = {};

def _pump(s: PtySession) -> None {
    while True {
        try {
            data = os.read(s.fd, 65536);
        } except OSError {
            data = b"";
        }
        if not data {
            break;
        }
        s.append(data);
    }
    with s.cond {
        s.alive = False;
        s.cond.notify_all();
    }
    try { os.waitpid(s.pid, 0); } except ChildProcessError {}
    try { os.close(s.fd); } except OSError {}
}

def _set_size(fd: int, cols: int, rows: int) -> None {
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", max(rows, 2), max(cols, 10), 0, 0));
}

def:pub term_open(token: str, cwd: str = "", cols: int = 100, rows: int = 30) -> TermInfo {
    if not authorized(token) {
        return TermInfo(ok=False, error="unauthorized");
    }
    p = current_project();
    start_dir = cwd or (p.root_dir if p is not None else os.path.expanduser("~"));
    if not os.path.isdir(start_dir) {
        start_dir = os.path.expanduser("~");
    }
    shell = os.environ.get("SHELL") or "/bin/zsh";
    env = tool_env();
    env["TERM"] = "xterm-256color";
    env["COLORTERM"] = "truecolor";
    env["TERM_PROGRAM"] = "jac-smith";
    env.setdefault("LANG", "en_US.UTF-8");
    env.pop("JAC_BUILD", None);
    forked = pty.fork();
    pid = int(forked[0]);
    fd = int(forked[1]);
    if pid == 0 {
        try {
            os.chdir(start_dir);
            os.execvpe(shell, [shell, "-l"], env);
        } finally {
            os._exit(127);
        }
    }
    _set_size(fd, cols, rows);
    sid = secrets.token_hex(8);
    s = PtySession(sid=sid, fd=fd, pid=pid, shell=shell, cwd=start_dir, cond=threading.Condition());
    _sessions[sid] = s;
    threading.Thread(target=_pump, args=(s,), daemon=True).start();
    return TermInfo(ok=True, sid=sid, shell=os.path.basename(shell), cwd=start_dir);
}

"""SSE stream of terminal output starting at a byte offset.

Each frame is {"o": next_offset, "d": text}; a final frame with "x": true means the shell exited.
The stream ends after STREAM_IDLE_S without output so connections recycle; the UI reconnects
from the last offset it saw.
"""
def:pub term_stream(token: str, sid: str, offset: int = 0) -> None {
    def frames -> Generator[dict[str, any], None, None] {
        if not authorized(token) or sid not in _sessions {
            yield {"o": offset, "d": "", "x": True, "e": "no such session"};
            return;
        }
        s = _sessions[sid];
        decoder = codecs.getincrementaldecoder("utf-8")(errors="replace");
        cur = offset;
        deadline = time.time() + STREAM_IDLE_S;
        while True {
            with s.cond {
                while s.end_offset() <= cur and s.alive and time.time() < deadline {
                    s.cond.wait(timeout=1.0);
                }
                (data, nxt) = s.read_from(cur);
                alive = s.alive;
            }
            if data {
                cur = nxt;
                deadline = time.time() + STREAM_IDLE_S;
                yield {"o": cur, "d": decoder.decode(data)};
            } elif not alive {
                yield {"o": cur, "d": decoder.decode(b"", final=True), "x": True};
                return;
            } elif time.time() >= deadline {
                yield {"o": cur, "d": ""};
                return;
            }
        }
    }
    report frames();
}

obj TermChunk {
    has o: int = 0;
    has d: str = "";
    has x: bool = False;
    has e: str = "";
}

"""Long-poll for terminal output from a byte offset.

Returns as soon as any output exists (or after `wait` seconds of silence), so it works on servers
that buffer streamed responses. Output is cut at a UTF-8 boundary; the returned offset `o` is where
the next read continues, so nothing is lost or repeated.
"""
def read_chunk(sid: str, offset: int, wait_s: float) -> TermChunk {
    if sid not in _sessions {
        return TermChunk(o=offset, x=True, e="no such session");
    }
    s = _sessions[sid];
    deadline = time.time() + max(min(wait_s, 25.0), 0.0);
    with s.cond {
        while s.end_offset() <= offset and s.alive and time.time() < deadline {
            s.cond.wait(timeout=max(min(deadline - time.time(), 1.0), 0.01));
        }
        (data, nxt) = s.read_from(offset);
        alive = s.alive;
    }
    start = nxt - len(data);
    decoder = codecs.getincrementaldecoder("utf-8")(errors="replace");
    text = decoder.decode(data, final=not alive);
    pending = len(decoder.getstate()[0]);
    return TermChunk(o=start + len(data) - pending, d=text, x=(not alive) and pending == 0 and s.end_offset() <= nxt);
}

def:pub term_read(token: str, sid: str, offset: int = 0, wait_s: float = 20.0) -> TermChunk {
    if not authorized(token) {
        return TermChunk(o=offset, x=True, e="unauthorized");
    }
    return read_chunk(sid, offset, wait_s);
}

def:pub term_write(token: str, sid: str, data: str) -> bool {
    if not authorized(token) or sid not in _sessions {
        return False;
    }
    s = _sessions[sid];
    if not s.alive {
        return False;
    }
    payload = data.encode("utf-8");
    while payload {
        n = os.write(s.fd, payload);
        payload = payload[n:];
    }
    return True;
}

def:pub term_resize(token: str, sid: str, cols: int, rows: int) -> bool {
    if not authorized(token) or sid not in _sessions {
        return False;
    }
    s = _sessions[sid];
    if s.alive {
        _set_size(s.fd, cols, rows);
        try { os.kill(s.pid, int(signal.SIGWINCH)); } except OSError {}
    }
    return True;
}

def:pub term_close(token: str, sid: str) -> bool {
    if not authorized(token) or sid not in _sessions {
        return False;
    }
    s = _sessions.pop(sid);
    if s.alive {
        try { os.kill(s.pid, int(signal.SIGHUP)); } except OSError {}
    }
    return True;
}

def close_all() -> None {
    for sid in list(_sessions.keys()) {
        s = _sessions.pop(sid);
        if s.alive {
            try { os.kill(s.pid, int(signal.SIGHUP)); } except OSError {}
        }
    }
}
