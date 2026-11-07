"""Architectural roles for modules, decided by Jev (TypeSafe's System One decision model).

Role and tier are closed sets, which is exactly what a decision model answers: one pass, a
probability per label, no generated text. Answers are cached by content hash under
~/.jac-smith/cache so re-indexing only asks about files that changed. With no Jev key, a
path-based heuristic fills in so the views still have colors.
"""
import os;
import json;
import hashlib;
import from concurrent.futures { ThreadPoolExecutor }

import from jaclang.byllm.lib { Model, Decision }
import from settings.credentials { APP_DIR, jev_key }

enum ArchRole {
    ENTRY,
    UI,
    API,
    DOMAIN,
    DATA,
    AI,
    INTEGRATION,
    INFRA,
    CONFIG,
    TEST,
    TOOLING
}

sem ArchRole.ENTRY = "Application entry point, bootstrap, or main module that wires the other parts together";
sem ArchRole.UI = "User interface: components, pages, views, layout, styling, client-side state";
sem ArchRole.API = "Server endpoints, routes, controllers, RPC handlers, request/response wiring";
sem ArchRole.DOMAIN = "Core business or domain logic, algorithms, models of the problem the project solves";
sem ArchRole.DATA = "Persistence, storage, database access, schemas, caches, serialization";
sem ArchRole.AI = "LLM calls, agents, prompts, model configuration, ML inference";
sem ArchRole.INTEGRATION = "Clients for external services, SDK wrappers, subprocess or OS integration";
sem ArchRole.INFRA = "Runtime plumbing: logging, concurrency, networking, auth, deployment helpers";
sem ArchRole.CONFIG = "Settings, constants, environment and credential handling";
sem ArchRole.TEST = "Tests, fixtures, mocks, benchmarks";
sem ArchRole.TOOLING = "Build scripts, codegen, CLIs for developers, migrations, one-off utilities";

enum Tier {
    CORE,
    SUPPORTING,
    PERIPHERAL
}

sem Tier.CORE = "Central to what the project does; many other parts rely on it or it embodies the main idea";
sem Tier.SUPPORTING = "Necessary helper that serves the core but is not itself the main idea";
sem Tier.PERIPHERAL = "Edge code: examples, scripts, tests, small utilities, rarely depended upon";

obj ModuleProfile {
    has role: ArchRole;
    has tier: Tier;
}

sem ModuleProfile.role = "The architectural layer this module belongs to";
sem ModuleProfile.tier = "How central this module is to the project";

glob JEV_MODEL: str = "systemone:typesafe/jev-latest";
glob jev: Model = Model(model_name=JEV_MODEL);

def profile_module(path: str, digest: str) -> Decision[ModuleProfile] by jev();
sem profile_module = "Classify a source module of a software project by architectural role and centrality";
sem profile_module.path = "Project-relative file path of the module";
sem profile_module.digest = "Module summary: docstring, declared interfaces, imports, and how many other modules depend on it";

obj RoleAnswer {
    has role: str;
    has tier: str;
    has confidence: float = 0.0;
    has source: str = "heuristic";
}

"""Jev answers below this confidence lose to the path heuristic for the role (the tier is kept)."""
glob MIN_ROLE_CONFIDENCE: float = 0.1;

glob CACHE_PATH: str = os.path.join(APP_DIR, "cache", "roles.json");
glob _cache: dict[str, dict[str, any]] = {};
glob _cache_loaded: bool = False;

def _load_cache() -> None {
    if _cache_loaded {
        return;
    }
    _cache_loaded = True;
    try {
        with open(CACHE_PATH, encoding="utf-8") as fh {
            data = json.load(fh);
        }
        if isinstance(data, dict) {
            _cache.update(data);
        }
    } except (OSError, ValueError) {}
}

def _save_cache() -> None {
    os.makedirs(os.path.dirname(CACHE_PATH), exist_ok=True);
    with open(CACHE_PATH, "w", encoding="utf-8") as fh {
        json.dump(_cache, fh);
    }
}

def cache_key(path: str, digest: str) -> str {
    return hashlib.sha256((JEV_MODEL + "\n" + path + "\n" + digest).encode("utf-8")).hexdigest()[:32];
}

"""Rebuild the Jev model so a key registered after startup takes effect."""
def refresh_jev() -> bool {
    key = jev_key();
    if key {
        jev = Model(model_name=JEV_MODEL, api_key=key);
    }
    return bool(key);
}

def heuristic_role(path: str, lang: str, fan_in: int) -> RoleAnswer {
    p = "/" + path.lower();
    base = os.path.basename(p);
    role = "DOMAIN";
    if "/test" in p or base.startswith("test_") or "_test." in base or ".spec." in base or ".test." in base {
        role = "TEST";
    } elif base in ["main.jac", "main.py", "__main__.py", "app.py", "index.js", "index.ts", "main.ts", "main.js", "cli.py"] {
        role = "ENTRY";
    } elif any([s in p for s in ["/ui/", "/components/", "/pages/", "/views/", "/frontend/", "/client/"]]) or base.endswith((".tsx", ".jsx")) {
        role = "UI";
    } elif any([s in p for s in ["/api/", "/routes/", "/endpoints", "/server/", "/handlers/", "/controllers/"]]) {
        role = "API";
    } elif any([s in p for s in ["/agent", "/llm", "/prompts/", "/ai/", "/byllm", "/model"]]) {
        role = "AI";
    } elif any([s in p for s in ["/db/", "/store", "/storage", "/persist", "/schema", "/migrations/", "/cache"]]) {
        role = "DATA";
    } elif any([s in p for s in ["/config", "/settings", "/env", "/credential", "/constants"]]) {
        role = "CONFIG";
    } elif any([s in p for s in ["/scripts/", "/tools/", "/bin/", "/build", "setup.py", "/codegen"]]) {
        role = "TOOLING";
    } elif any([s in p for s in ["/client", "/sdk", "/integration", "/adapters/"]]) {
        role = "INTEGRATION";
    } elif any([s in p for s in ["/utils", "/util/", "/lib/", "/infra", "/core/runtime", "/log"]]) {
        role = "INFRA";
    }
    tier = "CORE" if fan_in >= 3 else ("PERIPHERAL" if role in ["TEST", "TOOLING"] else "SUPPORTING");
    return RoleAnswer(role=role, tier=tier, confidence=0.0, source="heuristic");
}

def _ask_jev(path: str, digest: str) -> RoleAnswer | None {
    try {
        d = profile_module(path, digest);
        prof = d.value;
        if prof is None {
            return None;
        }
        return RoleAnswer(
            role=prof.role.name, tier=prof.tier.name, confidence=float(d.confidence), source="jev"
        );
    } except Exception as e {
        print("[jac-smith] jev classify failed for " + path + ": " + str(e));
        return None;
    }
}

obj RoleJob {
    has path: str;
    has digest: str;
    has lang: str;
    has fan_in: int;
}

"""Classify many modules: cache first, then Jev in parallel, heuristic for whatever is left.

Returns (answers keyed by path, how many came from Jev this call, how many from the cache).
"""
def classify_modules(jobs: list[RoleJob], use_jev: bool, max_calls: int = 300) -> tuple[dict[str, RoleAnswer], int, int] {
    _load_cache();
    out: dict[str, RoleAnswer] = {};
    pending: list[RoleJob] = [];
    cached = 0;
    for j in jobs {
        hit = _cache.get(cache_key(j.path, j.digest));
        if hit {
            out[j.path] = RoleAnswer(
                role=str(hit["role"]), tier=str(hit["tier"]),
                confidence=float(hit.get("confidence", 0.0)), source="jev"
            );
            cached += 1;
        } else {
            pending.append(j);
        }
    }
    asked = 0;
    if use_jev and pending and refresh_jev() {
        batch = pending[:max_calls];
        with ThreadPoolExecutor(max_workers=8) as pool {
            results = list(pool.map(lambda (j: RoleJob) -> RoleAnswer | None { _ask_jev(j.path, j.digest) }, batch));
        }
        for (j, ans) in zip(batch, results) {
            if ans is not None {
                out[j.path] = ans;
                _cache[cache_key(j.path, j.digest)] = {
                    "role": ans.role, "tier": ans.tier, "confidence": ans.confidence
                };
                asked += 1;
            }
        }
        if asked {
            _save_cache();
        }
    }
    for j in jobs {
        a = out.get(j.path);
        if a is None {
            out[j.path] = heuristic_role(j.path, j.lang, j.fan_in);
        } elif a.confidence < MIN_ROLE_CONFIDENCE {
            h = heuristic_role(j.path, j.lang, j.fan_in);
            out[j.path] = RoleAnswer(role=h.role, tier=a.tier, confidence=a.confidence, source="jev+heuristic");
        }
    }
    return (out, asked, cached);
}
