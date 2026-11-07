"""App credentials: API keys are loaded at startup from .env files the user registers in settings.

Secrets never live in this repo. ~/.jac-smith/config.json lists the .env files to read; only
API-key-shaped variables (*_API_KEY, *_TOKEN for model providers) are pulled into the process env,
and values are never sent to the UI - the UI only learns which key names are present.
"""
import os;
import json;
import re;
import tempfile;

glob APP_DIR: str = os.path.join(os.path.expanduser("~"), ".jac-smith");
glob CONFIG_PATH: str = os.path.join(APP_DIR, "config.json");
glob JEV_KEYS: list[str] = ["JEV_API_KEY", "TYPESAFE_API_KEY"];
glob _KEY_NAME = re.compile(r"^[A-Z][A-Z0-9_]*_API_KEY$");
glob _ENV_LINE = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$");

"""Key name -> the .env file it was loaded from (empty string when it came from the process env)."""
glob loaded_from: dict[str, str] = {};

def default_config() -> dict[str, any] {
    return {
        "env_files": [],
        "agent_backend": "codex",
        "agent_model": "openrouter/anthropic/claude-sonnet-4.5",
        "recent_projects": []
    };
}

def read_config() -> dict[str, any] {
    cfg = default_config();
    try {
        with open(CONFIG_PATH, encoding="utf-8") as fh {
            data = json.load(fh);
        }
        if isinstance(data, dict) {
            cfg.update(data);
        }
    } except (OSError, ValueError) {}
    return cfg;
}

"""Atomic write: a private temp file per writer, then rename, so concurrent writers never collide."""
def write_config(cfg: dict[str, any]) -> None {
    os.makedirs(APP_DIR, exist_ok=True);
    (fd, tmp) = tempfile.mkstemp(prefix="config-", suffix=".json.tmp", dir=APP_DIR);
    try {
        with os.fdopen(fd, "w", encoding="utf-8") as fh {
            json.dump(cfg, fh, indent=2);
        }
        os.chmod(tmp, 0o600);
        os.replace(tmp, CONFIG_PATH);
    } except Exception as e {
        try { os.remove(tmp); } except OSError {}
        raise e;
    }
}

def parse_env_file(path: str) -> dict[str, str] {
    out: dict[str, str] = {};
    try {
        with open(os.path.expanduser(path), encoding="utf-8", errors="replace") as fh {
            lines = fh.read().splitlines();
        }
    } except OSError {
        return out;
    }
    for line in lines {
        m = _ENV_LINE.match(line);
        if not m or line.strip().startswith("#") {
            continue;
        }
        val = m.group(2).strip();
        if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'" {
            val = val[1:-1];
        } else {
            val = val.split(" #")[0].strip();
        }
        out[m.group(1)] = val;
    }
    return out;
}

"""Load API keys from every registered .env file. Process env wins; earlier files win over later ones."""
def load_credentials() -> None {
    for k in list(os.environ.keys()) {
        if _KEY_NAME.match(k) and k not in loaded_from {
            loaded_from[k] = "";
        }
    }
    for f in read_config().get("env_files", []) {
        for (k, v) in parse_env_file(str(f)).items() {
            if not _KEY_NAME.match(k) or not v {
                continue;
            }
            if k in loaded_from {
                continue;
            }
            os.environ[k] = v;
            loaded_from[k] = str(f);
        }
    }
}

def jev_key() -> str {
    for k in JEV_KEYS {
        v = os.environ.get(k, "");
        if v {
            return v;
        }
    }
    return "";
}

def jev_source() -> str {
    for k in JEV_KEYS {
        if os.environ.get(k) {
            src = loaded_from.get(k, "");
            return k + " from " + (src if src else "process environment");
        }
    }
    return "";
}

def keys_present() -> list[str] {
    return sorted([k for k in os.environ.keys() if _KEY_NAME.match(k) and os.environ.get(k)]);
}

def add_env_file(path: str) -> str {
    p = os.path.abspath(os.path.expanduser(path.strip()));
    if not os.path.isfile(p) {
        return "No such file: " + p;
    }
    cfg = read_config();
    files = [str(f) for f in cfg.get("env_files", [])];
    if p not in files {
        files.append(p);
    }
    cfg["env_files"] = files;
    write_config(cfg);
    load_credentials();
    found = [k for k in parse_env_file(p).keys() if _KEY_NAME.match(k)];
    return "Registered " + p + " (" + (", ".join(found) if found else "no *_API_KEY entries") + ")";
}

def remove_env_file(path: str) -> str {
    cfg = read_config();
    cfg["env_files"] = [str(f) for f in cfg.get("env_files", []) if str(f) != path];
    write_config(cfg);
    for (k, src) in list(loaded_from.items()) {
        if src == path {
            os.environ.pop(k, None);
            loaded_from.pop(k, None);
        }
    }
    load_credentials();
    return "Removed " + path;
}

with entry {
    load_credentials();
}

glob SECRETS_PATH: str = os.path.join(APP_DIR, "credentials.env");
glob SETTABLE_KEYS: list[str] = ["JEV_API_KEY", "GEMINI_API_KEY", "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "OPENROUTER_API_KEY"];

"""Store a key in ~/.jac-smith/credentials.env (0600), make it win over other .env files, and apply it now."""
def set_secret(name: str, value: str) -> str {
    if name not in SETTABLE_KEYS {
        return "Not a settable key: " + name;
    }
    os.makedirs(APP_DIR, exist_ok=True);
    current = parse_env_file(SECRETS_PATH);
    if value.strip() {
        current[name] = value.strip();
    } else {
        current.pop(name, None);
    }
    (fd, tmp) = tempfile.mkstemp(prefix="credentials-", dir=APP_DIR);
    with os.fdopen(fd, "w", encoding="utf-8") as fh {
        for (k, v) in current.items() {
            fh.write(k + "=" + v + "\n");
        }
    }
    os.chmod(tmp, 0o600);
    os.replace(tmp, SECRETS_PATH);
    cfg = read_config();
    files = [str(f) for f in cfg.get("env_files", []) if str(f) != SECRETS_PATH];
    cfg["env_files"] = [SECRETS_PATH] + files;
    write_config(cfg);
    if value.strip() {
        os.environ[name] = value.strip();
        loaded_from[name] = SECRETS_PATH;
        return name + " saved";
    }
    os.environ.pop(name, None);
    loaded_from.pop(name, None);
    load_credentials();
    return name + " removed";
}

def key_hint(name: str) -> str {
    v = os.environ.get(name, "");
    return ("…" + v[-4:]) if len(v) >= 8 else ("set" if v else "");
}
