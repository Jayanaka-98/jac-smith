"""Per-install session token guarding every endpoint.

The in-process server answers on a loopback port with CORS open (`allow_origins=['*']` in
single-process mode), so without a guard any web page could drive the terminal or the agent.
The token lives in a 0600 file; the app's own UI reads it through the desktop fs bridge
(which enforces loopback Host/Origin), and web pages cannot read local files.
"""
import os;
import hmac;
import secrets;

import from settings.credentials { APP_DIR }

glob TOKEN_PATH: str = os.path.join(APP_DIR, "session.token");

def _load_or_create() -> str {
    try {
        with open(TOKEN_PATH, encoding="utf-8") as fh {
            existing = fh.read().strip();
        }
        if len(existing) >= 32 {
            return existing;
        }
    } except OSError {}
    os.makedirs(APP_DIR, exist_ok=True);
    tok = secrets.token_urlsafe(32);
    fd = os.open(TOKEN_PATH, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600);
    with os.fdopen(fd, "w") as fh {
        fh.write(tok);
    }
    return tok;
}

glob SESSION_TOKEN: str = _load_or_create();

def authorized(token: str) -> bool {
    return bool(token) and hmac.compare_digest(str(token), SESSION_TOKEN);
}
