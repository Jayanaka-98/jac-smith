"""Architecture wiring files (Jac's arch.jac / archwire.jac) as dependency edges.

Projects that adopt Jac's architecture wiring declare imports centrally instead of in the modules:
`provider --> consumer { names }` or `provider ++> [a | b, c { names }]` inside
`graph import <pkg> { ... }` / `impl import <pkg> { ... }` blocks. Without reading these, such a
codebase looks like it has no internal dependencies at all.
"""
import os;
import re;

glob _BLOCK = re.compile(r"^(?:graph|impl)\s+import\s*([\w\.]*)\s*\{", re.M);
glob _PAYLOAD = re.compile(r"\{[^{}]*\}");
glob _WIRE = re.compile(r"(?:\btype\s+)?([A-Za-z_][\w\.]*)(?:\s+as\s+\w+)?\s*(?:\+\+>|-->)\s*");
glob _DOTTED = re.compile(r"[A-Za-z_][\w]*(?:\.[A-Za-z_][\w]*)*");
glob _RULE = re.compile(r"^\s*edge\s+\w+\s*:[^;]*;", re.M);
glob WIRE_FILES: set[str] = {"arch.jac", "archwire.jac"};

obj Wire {
    has provider: str;
    has consumers: list[str];
}

def _blocks(text: str) -> list[tuple[str, str]] {
    out: list[tuple[str, str]] = [];
    for m in _BLOCK.finditer(text) {
        start = m.end();
        depth = 1;
        i = start;
        while i < len(text) and depth > 0 {
            if text[i] == "{" {
                depth += 1;
            } elif text[i] == "}" {
                depth -= 1;
            }
            i += 1;
        }
        out.append((m.group(1) or "", text[start:i - 1]));
    }
    return out;
}

"""Wires as (provider, [consumers]) with dotted paths relative to the wiring file's directory."""
def parse_wires(text: str) -> list[Wire] {
    wires: list[Wire] = [];
    for (header, body) in _blocks(text) {
        body = _RULE.sub("", body);
        prev = None;
        while prev != body {
            prev = body;
            body = _PAYLOAD.sub(" ", body);
        }
        matches = list(_WIRE.finditer(body));
        for (k, m) in enumerate(matches) {
            left = m.group(1);
            if left in ["type", "edge"] {
                continue;
            }
            end = matches[k + 1].start() if k + 1 < len(matches) else len(body);
            tail = body[m.end():end];
            consumers = [c for c in _DOTTED.findall(tail) if c not in ["type", "as"]];
            provider = (header + "." + left) if header else left;
            if consumers {
                wires.append(Wire(provider=provider, consumers=consumers));
            }
        }
    }
    return wires;
}

"""Map a dotted path (possibly reaching into a symbol) to the longest matching module id."""
def resolve_dotted(dotted: str, base: str, lookup: dict[str, str]) -> str {
    parts = dotted.split(".");
    for i in range(len(parts), 0, -1) {
        key = ".".join(parts[:i]);
        full = (base + "." + key) if base else key;
        hit = lookup.get(full, "");
        if hit {
            return hit;
        }
    }
    return "";
}

"""Dependency edges declared by wiring files: consumer module -> provider module -> count."""
def wire_edges(root_dir: str, wire_files: list[str], lookup: dict[str, str]) -> dict[str, dict[str, int]] {
    edges: dict[str, dict[str, int]] = {};
    for rel in wire_files {
        try {
            with open(os.path.join(root_dir, rel), encoding="utf-8", errors="replace") as fh {
                text = fh.read();
            }
        } except OSError {
            continue;
        }
        base = os.path.dirname(rel).replace("/", ".");
        for w in parse_wires(text) {
            prov = resolve_dotted(w.provider, base, lookup);
            if not prov {
                continue;
            }
            for c in w.consumers {
                cons = resolve_dotted(c, base, lookup);
                if cons and cons != prov {
                    edges.setdefault(cons, {})[prov] = edges.get(cons, {}).get(prov, 0) + 1;
                }
            }
        }
    }
    return edges;
}
