"""Settings endpoints: model keys (as presence only), agent backend, and ChatGPT sign-in."""
import from indexer.model { SettingsStatus }
import from settings.session { authorized }
import from indexer.roles { refresh_jev }
import from settings.credentials {
    read_config, write_config, jev_key, jev_source, keys_present, add_env_file, remove_env_file,
    set_secret, key_hint
}
import from settings.chatgpt {
    codex_path, install_codex, login_status, login_in_progress, login_url, start_login,
    cancel_login, logout
}

def _status(message: str = "") -> SettingsStatus {
    cfg = read_config();
    (signed_in, status_text) = login_status();
    cx = codex_path();
    return SettingsStatus(
        jev_ready=bool(jev_key()),
        jev_source=jev_source(),
        env_files=[str(f) for f in cfg.get("env_files", [])],
        keys_present=keys_present(),
        agent_model=str(cfg.get("agent_model", "")),
        agent_backend=str(cfg.get("agent_backend", "codex")),
        codex_installed=bool(cx),
        codex_path=cx,
        chatgpt_signed_in=signed_in,
        chatgpt_status=status_text,
        login_in_progress=login_in_progress(),
        login_url=login_url(),
        message=message,
        arch_namer=str(cfg.get("arch_namer", "codex")),
        claude_model=str(cfg.get("claude_model", "") or ""),
        gemini_model=str(cfg.get("gemini_model", "") or ""),
        codex_model=str(cfg.get("codex_model", "") or ""),
        custom_acp_command=str(cfg.get("custom_acp_command", "") or ""),
        theme=str(cfg.get("theme", "midnight")),
        jev_hint=key_hint("JEV_API_KEY") or key_hint("TYPESAFE_API_KEY"),
        gemini_key_hint=key_hint("GEMINI_API_KEY")
    );
}

def:pub get_settings(token: str) -> SettingsStatus {
    if not authorized(token) {
        return SettingsStatus(message="unauthorized");
    }
    return _status();
}

def:pub register_env_file(token: str, path: str) -> SettingsStatus {
    if not authorized(token) {
        return SettingsStatus(message="unauthorized");
    }
    msg = add_env_file(path);
    refresh_jev();
    return _status(msg);
}

def:pub unregister_env_file(token: str, path: str) -> SettingsStatus {
    if not authorized(token) {
        return SettingsStatus(message="unauthorized");
    }
    msg = remove_env_file(path);
    refresh_jev();
    return _status(msg);
}

def:pub set_agent(token: str, backend: str, model: str) -> SettingsStatus {
    if not authorized(token) {
        return SettingsStatus(message="unauthorized");
    }
    cfg = read_config();
    if backend in ["codex", "jac"] {
        cfg["agent_backend"] = backend;
    }
    if model.strip() {
        cfg["agent_model"] = model.strip();
    }
    write_config(cfg);
    return _status("Agent set to " + str(cfg["agent_backend"]));
}

def:pub chatgpt_install(token: str) -> SettingsStatus {
    if not authorized(token) {
        return SettingsStatus(message="unauthorized");
    }
    return _status(install_codex());
}

def:pub chatgpt_sign_in(token: str) -> SettingsStatus {
    if not authorized(token) {
        return SettingsStatus(message="unauthorized");
    }
    return _status(start_login());
}

def:pub chatgpt_cancel(token: str) -> SettingsStatus {
    if not authorized(token) {
        return SettingsStatus(message="unauthorized");
    }
    cancel_login();
    return _status("Sign-in cancelled");
}

def:pub chatgpt_sign_out(token: str) -> SettingsStatus {
    if not authorized(token) {
        return SettingsStatus(message="unauthorized");
    }
    return _status(logout());
}

glob CONFIG_CHOICES: dict[str, list[str]] = {
    "agent_backend": ["codex", "claude", "gemini", "jac", "custom"],
    "arch_namer": ["codex", "claude", "gemini", "none"],
    "theme": ["midnight", "graphite", "daylight"]
};
glob CONFIG_FREE: list[str] = ["claude_model", "gemini_model", "codex_model", "agent_model", "custom_acp_command"];

def:pub set_config(token: str, key: str, value: str) -> SettingsStatus {
    if not authorized(token) {
        return SettingsStatus(message="unauthorized");
    }
    if key in CONFIG_CHOICES and value not in CONFIG_CHOICES[key] {
        return _status("Unknown value for " + key);
    }
    if key not in CONFIG_CHOICES and key not in CONFIG_FREE {
        return _status("Unknown setting " + key);
    }
    cfg = read_config();
    cfg[key] = value.strip();
    write_config(cfg);
    return _status("Saved");
}

def:pub set_key(token: str, name: str, value: str) -> SettingsStatus {
    if not authorized(token) {
        return SettingsStatus(message="unauthorized");
    }
    msg = set_secret(name, value);
    if name == "JEV_API_KEY" {
        refresh_jev();
    }
    return _status(msg);
}

def:pub test_jev(token: str) -> str {
    if not authorized(token) {
        return "unauthorized";
    }
    import from architect.jev { jev_choose }
    r = jev_choose("A function that parses command-line flags and prints usage.", "What does this code do?", {"cli": "Command-line handling", "db": "Database access"});
    if r.error {
        return "Jev error: " + r.error;
    }
    return "Jev answered '" + r.choice + "' at " + str(round(r.confidence * 100)) + "% confidence";
}
