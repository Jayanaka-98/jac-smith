"""Binary treemap: area is proportional to importance, recursively splitting along the longer side.

Coordinates are unit fractions of the parent box; `aspect` is the parent's width/height ratio so
tiles come out close to square on screen rather than in unit space.
"""

obj Rect {
    has x: float;
    has y: float;
    has w: float;
    has h: float;
}

def _split(items: list[tuple[str, float]], r: Rect, aspect: float, out: dict[str, Rect]) -> None {
    if not items {
        return;
    }
    if len(items) == 1 {
        out[items[0][0]] = r;
        return;
    }
    total = sum([v for (_, v) in items]);
    if total <= 0 {
        total = float(len(items));
        items = [(k, 1.0) for (k, _) in items];
    }
    acc = 0.0;
    cut = 1;
    best = 2.0;
    for i in range(1, len(items)) {
        acc += items[i - 1][1];
        gap = abs(acc / total - 0.5);
        if gap < best {
            best = gap;
            cut = i;
        }
    }
    left = items[:cut];
    right = items[cut:];
    frac = sum([v for (_, v) in left]) / total;
    if r.w * aspect >= r.h {
        lw = r.w * frac;
        _split(left, Rect(x=r.x, y=r.y, w=lw, h=r.h), aspect, out);
        _split(right, Rect(x=r.x + lw, y=r.y, w=r.w - lw, h=r.h), aspect, out);
    } else {
        th = r.h * frac;
        _split(left, Rect(x=r.x, y=r.y, w=r.w, h=th), aspect, out);
        _split(right, Rect(x=r.x, y=r.y + th, w=r.w, h=r.h - th), aspect, out);
    }
}

"""Lay out weighted items in the unit square. Weights are softened (sqrt) so small parts stay legible."""
def treemap(items: list[tuple[str, float]], aspect: float = 1.6, soften: bool = True) -> dict[str, Rect] {
    out: dict[str, Rect] = {};
    weighted = [(k, (max(v, 0.0) ** 0.5) if soften else max(v, 0.0)) for (k, v) in items];
    weighted = sorted(weighted, key=lambda (kv: tuple[str, float]) -> float { -kv[1] });
    _split(weighted, Rect(x=0.0, y=0.0, w=1.0, h=1.0), max(aspect, 0.1), out);
    return out;
}
