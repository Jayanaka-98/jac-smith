"""Client cache with hover prefetch, so opening a box or a file shows already-loaded data.

Entries are promises, so a hover-started request and the click that follows share one fetch.
Cleared whenever the project is re-indexed or a file is saved.
"""
import from .rpc { rpc }

glob _frames: dict[str, any] = {};
glob _lines: dict[str, any] = {};

def:pub frame_key(bid: str, aspect: float) -> str {
    return bid + "@" + str(round(aspect, 1));
}

def:pub cached_frame(bid: str, aspect: float) -> any {
    k = frame_key(bid, aspect);
    if k not in _frames {
        _frames[k] = rpc("get_frame", {"box_id": bid, "aspect": aspect});
    }
    return _frames[k];
}

def:pub cached_lines(file_id: str) -> any {
    if file_id not in _lines {
        _lines[file_id] = rpc("read_source_lines", {"box_id": file_id});
    }
    return _lines[file_id];
}

"""Warm the cache for a box the pointer is resting on."""
def:pub prefetch(bid: str, kind: str, aspect: float) {
    try {
        if kind in ["package", "project", "module"] {
            cached_frame(bid, aspect);
        }
        if kind == "module" {
            cached_lines(bid);
        }
    } except Exception {}
}

def:pub forget_file(file_id: str) {
    if file_id in _lines {
        del _lines[file_id];
    }
}

def:pub clear_cache() {
    _frames = {};
    _lines = {};
}
