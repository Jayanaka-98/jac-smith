"""Jev (TypeSafe System One) choice questions with labels decided at runtime.

byLLM lowers compile-time enums onto this protocol; architecture components are only known after
discovery, so the mapper speaks the wire format directly: one `choice` question whose criteria are
the discovered components and their descriptions. One pass, a probability per label, no text.
"""
import json;
import time;
import from urllib.request { Request, urlopen }
import from urllib.error { HTTPError, URLError }
import from concurrent.futures { ThreadPoolExecutor }

import from settings.credentials { jev_key }

glob JEV_URL: str = "https://api.typesafe.ai/v1/systemone";
glob JEV_MODEL: str = "jev-latest";
glob MAX_STATE: int = 12000;

obj JevAnswer {
    has choice: str = "";
    has confidence: float = 0.0;
    has probabilities: dict[str, float] = {};
    has error: str = "";
}

"""Ask Jev to pick one label. criteria maps label -> description (2..255 labels)."""
def jev_choose(state: str, instructions: str, criteria: dict[str, str]) -> JevAnswer {
    key = jev_key();
    if not key {
        return JevAnswer(error="no Jev key");
    }
    payload = {
        "model": JEV_MODEL,
        "state": state[:MAX_STATE],
        "questions": {"value": {"type": "choice", "instructions": instructions, "criteria": criteria}}
    };
    body: dict[str, any] = {};
    for attempt in range(3) {
        req = Request(
            JEV_URL,
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json", "Authorization": "Bearer " + key},
            method="POST"
        );
        try {
            with urlopen(req, timeout=60.0) as resp {
                body = json.loads(resp.read().decode("utf-8", "replace"));
            }
            break;
        } except HTTPError as e {
            if e.code in (429, 529, 503) and attempt < 2 {
                time.sleep(0.6 * (attempt + 1));
                continue;
            }
            return JevAnswer(error="HTTP " + str(e.code));
        } except (URLError, TimeoutError, ValueError) as e {
            if attempt < 2 {
                time.sleep(0.5);
                continue;
            }
            return JevAnswer(error=str(e));
        }
    }
    ans = (body.get("answers") or {}).get("value") or {};
    probs = {str(k): float(v) for (k, v) in (ans.get("probabilities") or {}).items()};
    return JevAnswer(
        choice=str(ans.get("choice") or ""),
        confidence=float(ans.get("confidence") or 0.0),
        probabilities=probs
    );
}

obj ChoiceJob {
    has key: str;
    has state: str;
    has instructions: str;
    has criteria: dict[str, str];
}

"""Run many choice questions in parallel; returns answers keyed by job key."""
def jev_choose_many(jobs: list[ChoiceJob], workers: int = 16) -> dict[str, JevAnswer] {
    if not jobs {
        return {};
    }
    with ThreadPoolExecutor(max_workers=workers) as pool {
        results = list(pool.map(
            lambda (j: ChoiceJob) -> JevAnswer { jev_choose(j.state, j.instructions, j.criteria) },
            jobs
        ));
    }
    return {j.key: r for (j, r) in zip(jobs, results)};
}
