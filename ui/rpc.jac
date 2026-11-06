"""Client transport: one raw-fetch RPC helper that attaches the session token.

The generated RPC stubs cache "reader" responses for 60s and dedupe identical concurrent calls;
terminal keystrokes, status polling, and frames that change after a re-index must never be
served from cache, so every call goes through here instead.
"""

glob _token: str = "";

"""Call the desktop host's native plugin bridge (the same wire `@jac/desktop` uses).

jaclang 0.37.25 declares the `@jac/desktop` capability objects without `:pub`, so they cannot be
imported into a bundle yet; this goes straight to the broker, which enforces loopback Host/Origin.
"""
async def:pub desktop_invoke(plugin: str, command: str, args: dict[str, any]) -> any {
    broker = globalThis.__JAC_BROKER__;
    if broker {
        resp = await fetch(String(broker) + "/invoke", {
            "method": "POST",
            "headers": {"Content-Type": "application/json"},
            "body": JSON.stringify([plugin, command, args])
        });
        parsed = await resp.json();
        if parsed["ok"] {
            return parsed["data"];
        }
        raise Exception(plugin + "." + command + ": " + String(parsed["error"]["message"]));
    }
    if globalThis.__jac and globalThis.__jac.invoke {
        return await globalThis.__jac.invoke(plugin, command, args);
    }
    raise Exception("jac smith must run inside its desktop window (no native bridge found)");
}

async def:pub session_token() -> str {
    if _token {
        return _token;
    }
    hash = String(window.location.hash or "");
    if not globalThis.__JAC_BROKER__ and not globalThis.__jac and hash.startswith("#token=") {
        # Outside the desktop window (e.g. a browser pointed at the app's loopback port) the token
        # can be handed over in the URL fragment; it never reaches the server logs or other origins.
        _token = hash[7:];
        return _token;
    }
    r = await desktop_invoke("jac.fs", "read_file", {"path": "~/.jac-smith/session.token", "encoding": "utf-8"});
    _token = str(r["content"]).strip();
    return _token;
}

def:pub forget_token() {
    _token = "";
}

async def:pub rpc(name: str, args: dict[str, any]) -> any {
    tok = await session_token();
    body = {**args, "token": tok};
    resp = await fetch("/function/" + name, {
        "method": "POST",
        "headers": {"Content-Type": "application/json"},
        "body": JSON.stringify(body)
    });
    env = await resp.json();
    if not env["ok"] {
        msg = "request failed";
        if env["error"] and env["error"]["message"] {
            msg = String(env["error"]["message"]);
        }
        raise Exception(name + ": " + msg);
    }
    return env["data"]["result"];
}
