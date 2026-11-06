"""Source scanning: walk a project tree and pull imports and top-level declarations out of each file.

Python goes through the stdlib `ast` module; Jac and JS/TS go through line-level patterns,
which is enough to recover the architecture (who imports whom, what each module exposes).
"""
import os;
import re;
import ast;

import from indexer.model { SymbolInfo }

glob SKIP_DIRS: set[str] = {
    ".git", "node_modules", ".jac", "__pycache__", ".venv", "venv", "env", "dist",
    "build", ".idea", ".vscode", "packages", ".mypy_cache", ".pytest_cache", ".tox",
    "site-packages", ".next", "target", "out", "coverage", ".claude", ".ruff_cache"
};

glob LANG_BY_EXT: dict[str, str] = {
    ".py": "python", ".jac": "jac", ".js": "javascript", ".jsx": "javascript",
    ".mjs": "javascript", ".cjs": "javascript", ".ts": "typescript", ".tsx": "typescript"
};

glob MAX_FILES: int = 12000;
glob MAX_BYTES: int = 1500000;

"""One import statement as written. kind is module (dotted), path (file path), or package (bare npm name)."""
obj RawImport {
    has target: str;
    has level: int = 0;
    has names: list[str] = [];
    has kind: str = "module";
}

obj RawFile {
    has rel: str;
    has lang: str;
    has loc: int = 0;
    has imports: list[RawImport] = [];
    has symbols: list[SymbolInfo] = [];
    has summary: str = "";
}

glob _JAC_IMPORT_FROM = re.compile(r'^\s*import\s+from\s+("[^"]+"|[\w\.]+)\s*\{([^}]*)\}?', re.M);
glob _JAC_IMPORT_PLAIN = re.compile(r'^\s*import\s+(?!from\b|type\b)([\w\.]+(?:\s+as\s+\w+)?(?:\s*,\s*[\w\.]+(?:\s+as\s+\w+)?)*)\s*;', re.M);
glob _JAC_IMPORT_STR = re.compile(r'^\s*import\s+"([^"]+)"\s*;', re.M);
glob _JAC_INCLUDE = re.compile(r'^\s*include\s+([\w\.]+)\s*;', re.M);
glob _JAC_DECL = re.compile(
    r'^(?:@\w[^\n]*\n)*(async\s+def|def|node|edge|walker|async\s+walker|obj|class|enum)(?::(pub|protect|priv))?\s+([A-Za-z_]\w*)([^{;\n]*)',
    re.M
);
glob _JAC_DOC = re.compile(r'^\s*"""(.*?)"""', re.S);

glob _JS_IMPORT = re.compile(r'''(?:^|\n)\s*(?:import|export)\s+(?:[\w*{}\s,$]+\s+from\s+)?['"]([^'"]+)['"]''');
glob _JS_REQUIRE = re.compile(r'''require\(\s*['"]([^'"]+)['"]\s*\)''');
glob _JS_DYNAMIC = re.compile(r'''import\(\s*['"]([^'"]+)['"]\s*\)''');
glob _JS_DECL = re.compile(
    r'^export\s+(default\s+)?(async\s+)?(function\*?|class|const|let|var|interface|type|enum)\s+([A-Za-z_$][\w$]*)([^\n{=]*)',
    re.M
);
glob _JS_DOC = re.compile(r'^\s*/\*\*?(.*?)\*/', re.S);

def count_loc(src: str) -> int {
    n = 0;
    for line in src.splitlines() {
        s = line.strip();
        if s and not s.startswith("#") and not s.startswith("//") {
            n += 1;
        }
    }
    return n;
}

def first_sentence(text: str) -> str {
    t = " ".join(text.strip().split());
    if not t {
        return "";
    }
    cut = t.find(". ");
    if 0 < cut < 200 {
        return t[:cut + 1];
    }
    return t[:200];
}

def _py_signature(n: any) -> str {
    args = ast.unparse(n.args);
    ret = (" -> " + ast.unparse(n.returns)) if n.returns else "";
    prefix = "async def " if isinstance(n, ast.AsyncFunctionDef) else "def ";
    return prefix + n.name + "(" + args + ")" + ret;
}

def scan_python(rel: str, src: str) -> RawFile {
    out = RawFile(rel=rel, lang="python", loc=count_loc(src));
    tree: any = None;
    try {
        tree = ast.parse(src);
    } except Exception {
        return out;
    }
    out.summary = first_sentence(ast.get_docstring(tree) or "");
    for n in ast.walk(tree) {
        if isinstance(n, ast.Import) {
            for a in n.names {
                out.imports.append(RawImport(target=a.name));
            }
        } elif isinstance(n, ast.ImportFrom) {
            out.imports.append(
                RawImport(
                    target=n.module or "",
                    level=n.level or 0,
                    names=[a.name for a in n.names]
                )
            );
        }
    }
    for n in tree.body {
        if isinstance(n, ast.ClassDef) {
            bases = ", ".join([ast.unparse(b) for b in n.bases]);
            sig = "class " + n.name + (("(" + bases + ")") if bases else "");
            out.symbols.append(
                SymbolInfo(name=n.name, kind="class", line=n.lineno, signature=sig, public=not n.name.startswith("_"))
            );
        } elif isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) {
            out.symbols.append(
                SymbolInfo(
                    name=n.name, kind="def", line=n.lineno,
                    signature=_py_signature(n), public=not n.name.startswith("_")
                )
            );
        }
    }
    return out;
}

def _line_of(src: str, idx: int) -> int {
    return src.count("\n", 0, idx) + 1;
}

def _split_dots(target: str) -> tuple[int, str] {
    level = len(target) - len(target.lstrip("."));
    return (level, target[level:]);
}

def scan_jac(rel: str, src: str) -> RawFile {
    out = RawFile(rel=rel, lang="jac", loc=count_loc(src));
    doc = _JAC_DOC.match(src);
    if doc {
        out.summary = first_sentence(doc.group(1));
    }
    for m in _JAC_IMPORT_FROM.finditer(src) {
        target = m.group(1);
        names = [x.strip().split(" as ")[0].strip() for x in (m.group(2) or "").split(",") if x.strip()];
        if target.startswith("\"") {
            out.imports.append(RawImport(target=target.strip("\""), names=names, kind="package"));
        } else {
            (level, rest) = _split_dots(target);
            out.imports.append(RawImport(target=rest, level=level, names=names));
        }
    }
    for m in _JAC_IMPORT_PLAIN.finditer(src) {
        for part in m.group(1).split(",") {
            name = part.strip().split(" ")[0];
            if name {
                (level, rest) = _split_dots(name);
                out.imports.append(RawImport(target=rest, level=level));
            }
        }
    }
    for m in _JAC_IMPORT_STR.finditer(src) {
        out.imports.append(RawImport(target=m.group(1), kind="path"));
    }
    for m in _JAC_INCLUDE.finditer(src) {
        (level, rest) = _split_dots(m.group(1));
        out.imports.append(RawImport(target=rest, level=level));
    }
    for m in _JAC_DECL.finditer(src) {
        kw = " ".join(m.group(1).split());
        access = m.group(2) or "";
        name = m.group(3);
        tail = " ".join((m.group(4) or "").split());
        sig = kw + ((":" + access) if access else "") + " " + name + (" " + tail if tail else "");
        out.symbols.append(
            SymbolInfo(
                name=name,
                kind=kw.replace("async ", ""),
                line=_line_of(src, m.start(1)),
                signature=sig.strip(),
                public=(access != "priv") and not name.startswith("_")
            )
        );
    }
    return out;
}

def scan_js(rel: str, src: str, lang: str) -> RawFile {
    out = RawFile(rel=rel, lang=lang, loc=count_loc(src));
    doc = _JS_DOC.match(src);
    if doc {
        out.summary = first_sentence(doc.group(1).replace("*", " "));
    }
    seen: set[str] = set();
    for rx in [_JS_IMPORT, _JS_REQUIRE, _JS_DYNAMIC] {
        for m in rx.finditer(src) {
            t = m.group(1);
            if t in seen {
                continue;
            }
            seen.add(t);
            kind = "path" if t.startswith(".") or t.startswith("/") else "package";
            out.imports.append(RawImport(target=t, kind=kind));
        }
    }
    for m in _JS_DECL.finditer(src) {
        kw = m.group(3);
        name = m.group(4);
        tail = " ".join((m.group(5) or "").split());
        out.symbols.append(
            SymbolInfo(
                name=name,
                kind=kw,
                line=_line_of(src, m.start(3)),
                signature=("export " + kw + " " + name + " " + tail).strip(),
                public=True
            )
        );
    }
    return out;
}

def scan_file(rel: str, src: str) -> RawFile | None {
    ext = os.path.splitext(rel)[1].lower();
    lang = LANG_BY_EXT.get(ext, "");
    if lang == "python" {
        return scan_python(rel, src);
    } elif lang == "jac" {
        return scan_jac(rel, src);
    } elif lang {
        return scan_js(rel, src, lang);
    }
    return None;
}

"""Walk a project and scan every source file. Returns files keyed by project-relative POSIX path."""
def scan_project(root_dir: str) -> dict[str, RawFile] {
    files: dict[str, RawFile] = {};
    for (dirpath, dirnames, filenames) in os.walk(root_dir) {
        dirnames[:] = sorted([d for d in dirnames if d not in SKIP_DIRS and not d.startswith(".")]);
        for fname in sorted(filenames) {
            if len(files) >= MAX_FILES {
                return files;
            }
            ext = os.path.splitext(fname)[1].lower();
            if ext not in LANG_BY_EXT or fname.endswith(".d.ts") or ".min." in fname {
                continue;
            }
            full = os.path.join(dirpath, fname);
            try {
                if os.path.getsize(full) > MAX_BYTES {
                    continue;
                }
                with open(full, encoding="utf-8", errors="replace") as fh {
                    src = fh.read();
                }
            } except OSError {
                continue;
            }
            rel = os.path.relpath(full, root_dir).replace(os.sep, "/");
            rf = scan_file(rel, src);
            if rf is not None {
                files[rel] = rf;
            }
        }
    }
    return files;
}
