"""VS Code-style resize handles and persisted panel sizes."""

"""A drag handle. `axis` is "x" (resizes widths) or "y" (resizes heights). It reports the pointer
delta from where the drag started; the owner keeps the size at drag start and clamps."""
def:pub Sash(
    axis: str,
    onStart: Callable[[], None],
    onDrag: Callable[[float], None],
    onEnd: Callable[[], None],
    onReset: Callable[[], None]
) -> JsxElement {
    has active: bool = False;

    def down(e: MouseEvent) {
        if e.button != 0 {
            return;
        }
        e.preventDefault();
        sx = e.clientX;
        sy = e.clientY;
        active = True;
        onStart();
        document.body.classList.add("sash-dragging-" + axis);
        move = lambda (ev: any) {
            onDrag(ev.clientX - sx if axis == "x" else ev.clientY - sy);
        };
        up = lambda (ev: any) {
            window.removeEventListener("mousemove", move);
            window.removeEventListener("mouseup", up);
            document.body.classList.remove("sash-dragging-" + axis);
            active = False;
            onEnd();
        };
        window.addEventListener("mousemove", move);
        window.addEventListener("mouseup", up);
    }
    def dbl(e: MouseEvent) {
        onReset();
    }

    <div className={"sash sash-" + axis + (" active" if active else "")} onMouseDown={down} onDoubleClick={dbl} />
}

glob LAYOUT_KEY: str = "jac-smith.layout.v1";
glob LAYOUT_DEFAULTS: dict[str, float] = {"left": 312, "agent": 372, "rail": 214, "term": 280, "railLast": 214};

def:pub layout_default(key: str) -> float {
    return LAYOUT_DEFAULTS[key] if key in LAYOUT_DEFAULTS else 300.0;
}

def:pub load_layout() -> dict[str, float] {
    out = {**LAYOUT_DEFAULTS};
    try {
        raw = localStorage.getItem(LAYOUT_KEY);
        if raw {
            saved: dict[str, float] = JSON.parse(raw) as dict[str, float];
            for k in ["left", "agent", "rail", "term", "railLast"] {
                if k in saved and saved[k] >= 0 {
                    out[k] = saved[k];
                }
            }
        }
    } except Exception {}
    return out;
}

def:pub save_layout(sizes: dict[str, float]) {
    try {
        localStorage.setItem(LAYOUT_KEY, JSON.stringify(sizes));
    } except Exception {}
}

"""Clamp a dragged size; dragging well under the minimum collapses the panel (returns 0)."""
def:pub clamp_size(value: float, lo: float, hi: float, collapsible: bool) -> float {
    if collapsible and value < lo * 0.55 {
        return 0;
    }
    return min(max(value, lo), hi);
}

def:pub load_agent_min() -> bool {
    try {
        return localStorage.getItem("jac-smith.agent.min") == "1";
    } except Exception {}
    return False;
}

def:pub save_agent_min(v: bool) {
    try {
        localStorage.setItem("jac-smith.agent.min", "1" if v else "0");
    } except Exception {}
}
