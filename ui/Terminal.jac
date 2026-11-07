"""Integrated terminal: xterm.js panes on real PTYs, in tabs.

Output arrives over an SSE stream that resumes from the last byte offset, so a recycled
connection never drops or repeats output. Keystrokes are batched and sent strictly in order.
"""
import from "react" { useEffect }
import from "@xterm/xterm" { Terminal }
import from "@xterm/addon-fit" { FitAddon }
import from "@xterm/addon-web-links" { WebLinksAddon }
import from .rpc { rpc }

glob _NL: str = chr(10);
glob _ESC: str = chr(27);

glob TERM_THEME: dict[str, str] = {
    "background": "#0d1016",
    "foreground": "#e6e9ef",
    "cursor": "#7aa2ff",
    "selectionBackground": "#2a3a5c",
    "black": "#1a2029",
    "brightBlack": "#5c6676",
    "blue": "#7aa2ff",
    "brightBlue": "#9db9ff",
    "magenta": "#b48cff",
    "brightMagenta": "#cbb0ff",
    "green": "#3ecf8e",
    "brightGreen": "#6fe0aa",
    "yellow": "#f5b84a",
    "brightYellow": "#ffd166",
    "red": "#ff6b6b",
    "brightRed": "#ff9b9b",
    "cyan": "#40d4e2",
    "brightCyan": "#7fe6ef"
};

async def _flush(st: dict[str, any]) {
    if st["busy"] {
        return;
    }
    st["busy"] = True;
    try {
        while st["buf"] and not st["closed"] {
            chunk = st["buf"];
            st["buf"] = "";
            await rpc("term_write", {"sid": st["sid"], "data": chunk});
        }
    } except Exception as e {
        console.error("[term] write failed", e);
    }
    st["busy"] = False;
}

def _send(st: dict[str, any], data: str) {
    if not st["sid"] or st["exited"] {
        return;
    }
    st["buf"] = st["buf"] + data;
    _flush(st);
}

"""Pull output with long-polling: each read returns as soon as the shell prints something.
(The desktop host buffers streamed responses, so SSE would only flush at its idle timeout.)"""
async def _stream(st: dict[str, any], term: any) {
    while not st["closed"] and not st["exited"] {
        try {
            c = await rpc("term_read", {"sid": st["sid"], "offset": st["offset"], "wait_s": 20});
            if st["closed"] {
                return;
            }
            if c["d"] {
                term.write(c["d"]);
            }
            st["offset"] = c["o"];
            if c["x"] {
                st["exited"] = True;
                term.write(_NL + _ESC + "[2m[process exited - open a new tab with +]" + _ESC + "[0m");
            }
        } except Exception as e {
            if not st["closed"] {
                console.error("[term] read failed, retrying", e);
                await new(Promise, lambda (resolve: any) { setTimeout(resolve, 600); });
            }
        }
    }
}

async def _start(st: dict[str, any], term: any, fit: any, family: str, size: float) {
    # Wait for the user's terminal font (e.g. a Nerd Font for powerlevel10k) before measuring cells.
    if family {
        try {
            await globalThis.document.fonts.load(str(size) + "px '" + family + "'");
            await globalThis.document.fonts.load("bold " + str(size) + "px '" + family + "'");
        } except Exception {}
        term.options.fontFamily = "'" + family + "', 'JetBrains Mono', Menlo, monospace";
    }
    try {
        fit.fit();
    } except Exception {}
    info = await rpc("term_open", {"cwd": st["cwd"], "cols": term.cols, "rows": term.rows});
    if not info["ok"] {
        term.write(_ESC + "[31mCould not start a shell: " + String(info["error"]) + _ESC + "[0m");
        return;
    }
    st["sid"] = info["sid"];
    st["title"] = info["shell"];
    if st["closed"] {
        await rpc("term_close", {"sid": st["sid"]});
        return;
    }
    term.onData(lambda (d: str) { _send(st, d); });
    term.onResize(lambda (sz: any) {
        if st["sid"] and not st["exited"] {
            rpc("term_resize", {"sid": st["sid"], "cols": sz.cols, "rows": sz.rows});
        }
    });
    _stream(st, term);
}

def:pub TerminalPane(visible: bool, cwd: str, family: str, size: float) -> JsxElement {
    has hostRef: Ref[HTMLDivElement] = Ref();
    has fitRef: Ref[any] = Ref(None);
    has termRef: Ref[any] = Ref(None);

    useEffect(lambda {
        term = new(Terminal, {
            "fontFamily": "'" + family + "', 'JetBrains Mono', Menlo, monospace" if family else "'JetBrains Mono', 'SF Mono', Menlo, monospace",
            "fontSize": size,
            "lineHeight": 1.2,
            "cursorBlink": True,
            "scrollback": 10000,
            "allowProposedApi": True,
            "macOptionIsMeta": True,
            "theme": TERM_THEME
        });
        fit = new(FitAddon);
        term.loadAddon(fit);
        term.loadAddon(new(WebLinksAddon));
        term.open(hostRef.current);
        fitRef.current = fit;
        termRef.current = term;
        st = {"sid": "", "buf": "", "busy": False, "closed": False, "exited": False, "offset": 0, "cwd": cwd, "title": ""};
        _start(st, term, fit, family, size);
        ro = new(ResizeObserver, lambda {
            try {
                fit.fit();
            } except Exception {}
        });
        ro.observe(hostRef.current);
        return lambda {
            st["closed"] = True;
            ro.disconnect();
            if st["sid"] {
                rpc("term_close", {"sid": st["sid"]});
            }
            term.dispose();
        };
    }, []);

    can with [visible] entry {
        if visible and fitRef.current {
            fitRef.current.fit();
            if termRef.current {
                termRef.current.focus();
            }
        }
    }

    <div className="term-host" ref={hostRef} style={{"display": "block" if visible else "none"}} />
}

def:pub TerminalPanel(cwd: str, onClose: Callable[[], None], height: float = 280) -> JsxElement {
    has tabs: list[int] = [1];
    has active: int = 1;
    has counter: int = 1;
    has family: str = "";
    has size: float = 13.0;
    has fontSource: str = "";
    has ready: bool = False;

    async can with entry {
        try {
            p = await rpc("term_prefs", {});
            family = String(p["font_family"]);
            size = float(p["font_size"]);
            fontSource = String(p["source"]);
        } except Exception {}
        ready = True;
    }

    def add_tab(e: MouseEvent) {
        counter = counter + 1;
        tabs = tabs + [counter];
        active = counter;
    }
    def close_tab(tid: int) {
        rest = [t for t in tabs if t != tid];
        if len(rest) == 0 {
            onClose();
            return;
        }
        tabs = rest;
        if active == tid {
            active = rest[len(rest) - 1];
        }
    }
    def hide(e: MouseEvent) {
        onClose();
    }

    <section className="terminal" style={{"height": str(height) + "px"}}>
        <div className="term-tabs">
            {for t in tabs {
                <div key={"tab" + str(t)} className={"term-tab" + (" on" if t == active else "")} onClick={lambda (e: MouseEvent) { active = t; }}>
                    <span>{"shell " + str(t)}</span>
                    <button className="term-x" onClick={lambda (e: MouseEvent) { e.stopPropagation(); close_tab(t); }}>{"×"}</button>
                </div>
            }}
            <button className="icon-btn" onClick={add_tab} title="New terminal">{"+"}</button>
            <span className="spacer" />
            {family and <span className="stat" title={"Font from " + fontSource}>{family}</span>}
            <span className="stat mono">{cwd}</span>
            <button className="icon-btn" onClick={hide} title="Hide terminal">{"▾"}</button>
        </div>
        <div className="term-body">
            {if ready {
                for t in tabs {
                    <TerminalPane key={"pane" + str(t)} visible={t == active} cwd={cwd} family={family} size={size} />
                }
            }}
        </div>
    </section>
}
