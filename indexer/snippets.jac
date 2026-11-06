"""Code previews for boxes: pick the most telling lines of a module and tokenize them for highlighting.

Tokenizing happens here (Jac, Python, JS/TS) so the UI renders plain text spans - no HTML injection,
and Jac gets real highlighting, which off-the-shelf highlighters do not know.
Token kinds: k keyword, s string, c comment, n number, f defined name, t type, d decorator, p plain.
"""
import os;
import re;

glob _cache: dict[str, tuple[float, list[str]]] = {};
glob MAX_FILE: int = 600000;

glob JAC_KW: set[str] = {
    "import", "from", "as", "include", "def", "can", "has", "obj", "node", "edge", "walker", "class",
    "enum", "impl", "sem", "glob", "with", "entry", "exit", "visit", "spawn", "report", "disengage",
    "skip", "return", "yield", "if", "elif", "else", "for", "while", "in", "not", "and", "or", "is",
    "try", "except", "finally", "raise", "assert", "lambda", "async", "await", "match", "case", "switch",
    "default", "break", "continue", "del", "test", "by", "here", "self", "visitor", "root", "True",
    "False", "None", "static", "override", "abs", "pub", "priv", "protect", "type", "flow", "wait",
    "comptime", "own"
};
glob PY_KW: set[str] = {
    "import", "from", "as", "def", "class", "return", "yield", "if", "elif", "else", "for", "while",
    "in", "not", "and", "or", "is", "try", "except", "finally", "raise", "assert", "lambda", "async",
    "await", "with", "match", "case", "break", "continue", "del", "pass", "global", "nonlocal",
    "True", "False", "None", "self"
};
glob JS_KW: set[str] = {
    "import", "from", "export", "default", "function", "class", "return", "if", "else", "for", "while",
    "const", "let", "var", "new", "this", "typeof", "instanceof", "in", "of", "async", "await", "try",
    "catch", "finally", "throw", "switch", "case", "break", "continue", "interface", "type", "extends",
    "implements", "enum", "true", "false", "null", "undefined", "void", "as", "yield", "static", "readonly"
};
glob DEFINERS: set[str] = {"def", "can", "obj", "node", "edge", "walker", "class", "enum", "function", "interface", "type", "impl"};

glob _TOKEN = re.compile(
    r'(?P<c>#\*[\s\S]*?\*#|#[^\n]*|//[^\n]*|/\*[\s\S]*?\*/)'
    r'|(?P<s>[rRbBfF]{0,2}"""[\s\S]*?"""|[rRbBfF]{0,2}\'\'\'[\s\S]*?\'\'\'|[rRbBfF]{0,2}"(?:[^"\\\n]|\\.)*"|[rRbBfF]{0,2}\'(?:[^\'\\\n]|\\.)*\'|`(?:[^`\\]|\\.)*`)'
    r'|(?P<d>@[A-Za-z_][\w.]*)'
    r'|(?P<n>\b(?:0[xob][\da-fA-F_]+|\d[\d_]*(?:\.\d+)?(?:e[+-]?\d+)?)\b)'
    r'|(?P<w>[A-Za-z_$][\w$]*)'
    r'|(?P<ws>\s+)'
    r'|(?P<p>.)'
);

def _lines(path: str) -> list[str] {
    try {
        mt = os.path.getmtime(path);
        if os.path.getsize(path) > MAX_FILE {
            return [];
        }
    } except OSError {
        return [];
    }
    hit = _cache.get(path);
    if hit is not None and hit[0] == mt {
        return hit[1];
    }
    try {
        with open(path, encoding="utf-8", errors="replace") as fh {
            lines = fh.read().splitlines();
        }
    } except OSError {
        return [];
    }
    _cache[path] = (mt, lines);
    return lines;
}

def lang_of(path: str) -> str {
    ext = os.path.splitext(path)[1].lower();
    if ext == ".jac" {
        return "jac";
    }
    if ext == ".py" {
        return "python";
    }
    return "js";
}

"""Tokenize code into [kind, text] pairs, merging adjacent plain text."""
def tokenize(code: str, lang: str) -> list[list[str]] {
    kws = JAC_KW if lang == "jac" else (PY_KW if lang == "python" else JS_KW);
    out: list[list[str]] = [];
    expect_name = False;
    def push(kind: str, text: str) {
        if out and out[-1][0] == kind and kind == "p" {
            out[-1][1] = out[-1][1] + text;
        } else {
            out.append([kind, text]);
        }
    }
    for m in _TOKEN.finditer(code) {
        kind = m.lastgroup or "p";
        text = m.group(0);
        if kind == "c" and lang == "python" and text.startswith("//") {
            kind = "p";
        }
        if kind == "w" {
            if text in kws {
                push("k", text);
                if not (expect_name and text in ["pub", "priv", "protect", "static", "async"]) {
                    expect_name = text in DEFINERS;
                }
                continue;
            }
            if expect_name {
                push("f", text);
                expect_name = False;
                continue;
            }
            push("t" if text[0].isupper() else "p", text);
            continue;
        }
        if kind == "ws" {
            push("p", text);
            continue;
        }
        if kind == "p" and text != ":" {
            expect_name = False;
        }
        push(kind, text);
    }
    return out;
}

def _is_preamble(line: str) -> bool {
    s = line.strip();
    return (
        not s or s.startswith("#") or s.startswith("//") or s.startswith("import ")
        or s.startswith("from ") or s.startswith("include ") or s.startswith("\"\"\"")
        or s.startswith("'use ") or s.startswith("\"use ") or s == "}"
    );
}

"""Start of the code that best represents a file: the first declaration after docstring and imports."""
def interesting_start(lines: list[str], decl_lines: list[int]) -> int {
    in_doc = False;
    first_code = 0;
    for (i, raw) in enumerate(lines) {
        s = raw.strip();
        if s.count("\"\"\"") == 1 {
            in_doc = not in_doc;
            continue;
        }
        if in_doc or _is_preamble(raw) {
            continue;
        }
        first_code = i;
        break;
    }
    later = sorted([d - 1 for d in decl_lines if d - 1 >= first_code]);
    if later {
        # keep decorators that belong to the declaration
        start = later[0];
        while start > first_code and lines[start - 1].strip().startswith("@") {
            start -= 1;
        }
        return start;
    }
    return first_code;
}

def take(lines: list[str], start: int, count: int) -> str {
    chunk = [l.rstrip()[:110] for l in lines[start:start + count]];
    while chunk and not chunk[-1].strip() {
        chunk.pop();
    }
    # dedent so nested declarations do not waste the narrow box
    indents = [len(l) - len(l.lstrip()) for l in chunk if l.strip()];
    cut = min(indents) if indents else 0;
    return "\n".join([l[cut:] for l in chunk]);
}

def module_snippet(full_path: str, decl_lines: list[int], count: int = 14) -> tuple[str, int] {
    lines = _lines(full_path);
    if not lines {
        return ("", 0);
    }
    start = interesting_start(lines, decl_lines);
    return (take(lines, start, count), start + 1);
}

def range_snippet(full_path: str, line: int, count: int) -> str {
    lines = _lines(full_path);
    if not lines or line < 1 {
        return "";
    }
    return take(lines, line - 1, count);
}
