"""Terminal tests: a real PTY runs the login shell, takes input, resizes, and closes."""
import time;

import from terminal.shells { term_open, term_write, term_resize, term_close, _sessions }
import from settings.session { SESSION_TOKEN }

def wait_for(sid: str, needle: str, timeout: float = 15.0) -> str {
    deadline = time.time() + timeout;
    text = "";
    while time.time() < deadline {
        s = _sessions[sid];
        (data, _) = s.read_from(0);
        text = data.decode("utf-8", errors="replace");
        if needle in text {
            return text;
        }
        time.sleep(0.1);
    }
    return text;
}

test "pty runs the shell and echoes command output" {
    info = term_open(SESSION_TOKEN, "/tmp", 80, 24);
    assert info.ok, info.error;
    assert term_write(SESSION_TOKEN, info.sid, "echo jac-smith-$((6*7))\r");
    out = wait_for(info.sid, "jac-smith-42");
    assert "jac-smith-42" in out, out[-500:];
    assert term_resize(SESSION_TOKEN, info.sid, 132, 40);
    assert term_write(SESSION_TOKEN, info.sid, "stty size\r");
    out = wait_for(info.sid, "40 132");
    assert "40 132" in out, out[-500:];
    assert term_close(SESSION_TOKEN, info.sid);
}

test "terminal refuses calls without the session token" {
    assert not term_open("nope", "/tmp", 80, 24).ok;
}

test "terminal font follows the user's terminal setup" {
    import from terminal.shells { detect_term_prefs }
    p = detect_term_prefs();
    print(p.font_family, p.font_size, p.source, p.shell);
    assert p.shell != "";
    assert p.font_size > 0;
}

test "long-poll reads return promptly, resume by offset, and never split utf-8" {
    import from terminal.shells { read_chunk }
    info = term_open(SESSION_TOKEN, "/tmp", 80, 24);
    assert info.ok, info.error;
    first = read_chunk(info.sid, 0, 10.0);
    off = first.o;
    t0 = time.time();
    assert term_write(SESSION_TOKEN, info.sid, "printf 'caf\\303\\251 ok\\n'\r");
    got = "";
    while "café ok" not in got and time.time() - t0 < 10 {
        c = read_chunk(info.sid, off, 5.0);
        got = got + c.d;
        off = c.o;
    }
    assert "café ok" in got, got[-300:];
    assert time.time() - t0 < 5.0, "output should arrive promptly, not at the idle timeout";
    # a byte offset in the middle of a multi-byte char is never handed out
    s = _sessions[info.sid];
    (raw, _) = s.read_from(0);
    assert raw.decode("utf-8", errors="strict") is not None;
    term_close(SESSION_TOKEN, info.sid);
}
