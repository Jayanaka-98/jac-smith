"""Settings: which agents and models jac smith uses, the TypeSafe (Jev) key, and the theme."""
import from "react" { useEffect }
import from "lucide-react" { Bot, Workflow, Palette, KeyRound, Check, LoaderCircle, Download, X }
import from ..indexer.model { SettingsStatus }
import from .rpc { rpc }

glob THEMES: list[dict[str, str]] = [
    {"id": "midnight", "name": "Midnight", "bg": "#07080c", "panel": "#11131b", "accent": "linear-gradient(120deg,#6ea8ff,#a78bfa,#f472b6)", "text": "#eef0f6"},
    {"id": "graphite", "name": "Graphite", "bg": "#0e0f11", "panel": "#17191c", "accent": "linear-gradient(120deg,#5eead4,#60a5fa)", "text": "#e7e9ec"},
    {"id": "daylight", "name": "Daylight", "bg": "#f6f7fb", "panel": "#ffffff", "accent": "linear-gradient(120deg,#4f7cff,#8b5cf6,#ec4899)", "text": "#1a1d26"}
];

def:pub apply_theme(theme: str) {
    try {
        document.documentElement.setAttribute("data-theme", theme);
        localStorage.setItem("jac-smith.theme", theme);
    } except Exception {}
}

def:pub AgentCard(a: any, isDefault: bool, st: SettingsStatus, working: str, onAct: Callable[[str, dict[str, any], str], None], onModel: Callable[[str, str], None]) -> JsxElement {
    has model: str = "";
    has extra: str = "";
    can with [a["id"]] entry {
        model = String(a["model"] or "");
        extra = st.custom_acp_command if a["id"] == "custom" else "";
    }
    model_key = {"codex": "codex_model", "claude": "claude_model", "gemini": "gemini_model", "jac": "agent_model"};
    placeholder = {"codex": "default from ~/.codex/config.toml", "claude": "e.g. sonnet, opus, haiku", "gemini": "default gemini-2.5-flash", "jac": "LiteLLM id, e.g. openrouter/anthropic/claude-sonnet-4.5"};
    <div className={"agent-opt" + (" on" if isDefault else "")}>
        <div className="agent-opt-head">
            <span className={"pill " + ("ok" if a["ready"] else "warn")}><span className="dot" />{"ready" if a["ready"] else "not set up"}</span>
            <b>{a["name"]}</b>
            <span className="stat mono">{a["version"]}</span>
            <span className="spacer" />
            {isDefault and <span className="default-tag"><Check size={11} />default</span>}
            {not isDefault and a["ready"] and <button className="chip-btn" onClick={lambda (e: MouseEvent) { onAct("set_config", {"key": "agent_backend", "value": a["id"]}, "Saving"); }}>Make default</button>}
        </div>
        <div className="note" style={{"marginTop": "2px"}}>{a["transport"] + " · " + a["detail"]}</div>
        {if a["id"] in model_key {
            <div className="row">
                <input className="field" value={model} placeholder={placeholder[a["id"]]} onChange={lambda (e: ChangeEvent) { model = e.target.value; }} />
                <button className="chip-btn" onClick={lambda (e: MouseEvent) { onModel(model_key[a["id"]], model); }}>Save model</button>
            </div>
        }}
        {if a["id"] == "custom" {
            <div className="row">
                <input className="field" value={extra} placeholder="ACP agent command, e.g. npx @zed-industries/claude-code-acp" onChange={lambda (e: ChangeEvent) { extra = e.target.value; }} />
                <button className="chip-btn" onClick={lambda (e: MouseEvent) { onModel("custom_acp_command", extra); }}>Save</button>
            </div>
        }}
        {if a["id"] == "codex" {
            <div className="row">
                <span className="note" style={{"flex": 1, "marginTop": 0}}>{"ChatGPT: " + (st.chatgpt_status if st.chatgpt_signed_in else ("finish signing in in your browser..." if st.login_in_progress else "signed out"))}</span>
                {if st.chatgpt_signed_in {
                    <button className="chip-btn" onClick={lambda (e: MouseEvent) { onAct("chatgpt_sign_out", {}, "Signing out"); }}>Sign out</button>
                } elif st.codex_installed {
                    <button className="btn-grad" onClick={lambda (e: MouseEvent) { onAct("chatgpt_sign_in", {}, "Opening sign-in"); }}>Sign in with ChatGPT</button>
                }}
            </div>
        }}
        {if a["id"] == "gemini" {
            <div className="row">
                <input className="field" type="password" value={extra} placeholder={("GEMINI_API_KEY " + st.gemini_key_hint) if st.gemini_key_hint else "GEMINI_API_KEY (optional - otherwise Google sign-in)"} onChange={lambda (e: ChangeEvent) { extra = e.target.value; }} />
                <button className="chip-btn" disabled={not extra} onClick={lambda (e: MouseEvent) { onAct("set_key", {"name": "GEMINI_API_KEY", "value": extra}, "Saving key"); extra = ""; }}>Save key</button>
            </div>
        }}
        {not a["installed"] and a["id"] in ["codex", "claude", "gemini"] and <div className="row">
            <button className="btn-grad" disabled={working != ""} onClick={lambda (e: MouseEvent) { onAct("agent_install", {"agent_id": a["id"]}, "Installing " + a["name"]); }}><Download size={13} />{"Install " + a["name"]}</button>
            <span className="note" style={{"marginTop": 0}}>into ~/.jac-smith/tools</span>
        </div>}
    </div>
}

def:pub SettingsPanel(onClose: Callable[[], None], onChanged: Callable[[SettingsStatus], None]) -> JsxElement {
    has st: SettingsStatus | None = None;
    has agents: list[any] = [];
    has tab: str = "agents";
    has envPath: str = "";
    has jevKey: str = "";
    has working: str = "";
    has testResult: str = "";
    has theme: str = "midnight";

    async def load() {
        s = await rpc("get_settings", {});
        st = s;
        theme = String(s["theme"] or "midnight");
        onChanged(s);
        agents = await rpc("agents_status", {});
    }
    async def act(name: str, args: dict[str, any], label: str) {
        working = label;
        try {
            r = await rpc(name, args);
            if name in ["agent_install"] {
                testResult = String(r);
            }
        } except Exception as e {
            console.error(e);
        }
        await load();
        working = "";
    }
    async def save_cfg(key: str, value: str) {
        await act("set_config", {"key": key, "value": value}, "Saving");
    }
    async def test_key() {
        testResult = "Asking Jev...";
        testResult = String(await rpc("test_jev", {}));
    }
    def pick_theme(t: str) {
        theme = t;
        apply_theme(t);
        save_cfg("theme", t);
    }

    async can with entry {
        await load();
    }
    useEffect(lambda {
        timer = setInterval(lambda {
            if st and st.login_in_progress {
                load();
            }
        }, 2000);
        return lambda { clearInterval(timer); };
    }, [st]);

    tabs = [("agents", "Agents"), ("architecture", "Architecture"), ("appearance", "Appearance"), ("keys", "Keys")];

    <div className="overlay" onClick={lambda (e: MouseEvent) { onClose(); }}>
        <div className="dialog settings" onClick={lambda (e: MouseEvent) { e.stopPropagation(); }}>
            <div className="settings-head">
                <h3>Settings</h3>
                <span className="spacer" />
                {working and <span className="stat"><LoaderCircle size={12} className="spin" />{" " + working + "..."}</span>}
                <button className="icon-btn" onClick={lambda (e: MouseEvent) { onClose(); }}><X size={16} /></button>
            </div>
            <div className="settings-body">
                <nav className="settings-tabs">
                    {for (tid, label) in tabs {
                        <button key={tid} className={"stab" + (" on" if tab == tid else "")} onClick={lambda (e: MouseEvent) { tab = tid; }}>
                            {if tid == "agents" { <Bot size={14} /> } elif tid == "architecture" { <Workflow size={14} /> } elif tid == "appearance" { <Palette size={14} /> } else { <KeyRound size={14} /> }}
                            {label}
                        </button>
                    }}
                </nav>
                <div className="settings-pane">
                    {if st is None {
                        <p className="note">Loading...</p>
                    } elif tab == "agents" {
                        <div>
                            <p className="note" style={{"marginTop": 0}}>{"The chat agents jac smith can drive. Gemini and custom agents speak the Agent Client Protocol; Codex and Claude run through their own CLIs on your existing logins. Every agent gets the architecture, the focused box and your selection as context."}</p>
                            {for a in agents {
                                <AgentCard key={a["id"]} a={a} isDefault={st.agent_backend == a["id"]} st={st} working={working} onAct={lambda (n: str, args: dict[str, any], l: str) { act(n, args, l); }} onModel={lambda (k: str, v: str) { save_cfg(k, v); }} />
                            }}
                            {testResult and <p className="note">{testResult}</p>}
                        </div>
                    } elif tab == "architecture" {
                        <div>
                            <div className="section">
                                <h4>Architecture discovery</h4>
                                <p>{"Jev drafts the architecture from templates in seconds; this agent then names it in the project's own vocabulary."}</p>
                                <div className="seg-row">
                                    {for (nid, nlabel) in [("codex", "Codex"), ("claude", "Claude"), ("gemini", "Gemini"), ("none", "Jev only")] {
                                        <button key={nid} className={"seg-btn" + (" on" if st.arch_namer == nid else "")} onClick={lambda (e: MouseEvent) { save_cfg("arch_namer", nid); }}>{nlabel}</button>
                                    }}
                                </div>
                            </div>
                            <div className="section">
                                <h4>
                                    {"TypeSafe · Jev key"}
                                    <span className={"pill " + ("ok" if st.jev_ready else "warn")}><span className="dot" />{("set " + st.jev_hint) if st.jev_ready else "missing"}</span>
                                </h4>
                                <p>{"Jev decides the architecture skeleton and maps every module. " + (st.jev_source if st.jev_source else "No key yet.")}</p>
                                <div className="row">
                                    <input className="field" type="password" value={jevKey} placeholder="Paste a new TypeSafe API key" onChange={lambda (e: ChangeEvent) { jevKey = e.target.value; }} />
                                    <button className="btn-grad" disabled={not jevKey} onClick={lambda (e: MouseEvent) { act("set_key", {"name": "JEV_API_KEY", "value": jevKey}, "Saving key"); jevKey = ""; }}>Save key</button>
                                    <button className="chip-btn" disabled={not st.jev_ready} onClick={lambda (e: MouseEvent) { test_key(); }}>Test</button>
                                </div>
                                {testResult and <p className="note">{testResult}</p>}
                                <p className="note">{"Saved to ~/.jac-smith/credentials.env (readable only by you) and used ahead of other .env files. The value is never sent to the UI."}</p>
                            </div>
                        </div>
                    } elif tab == "appearance" {
                        <div className="theme-grid">
                            {for t in THEMES {
                                <button key={t["id"]} className={"theme-card" + (" on" if theme == t["id"] else "")} onClick={lambda (e: MouseEvent) { pick_theme(t["id"]); }}>
                                    <div className="theme-preview" style={{"background": t["bg"]}}>
                                        <div className="tp-bar" style={{"background": t["panel"]}}><span style={{"background": t["accent"]}} /></div>
                                        <div className="tp-body">
                                            <div className="tp-box" style={{"background": t["panel"]}} />
                                            <div className="tp-box" style={{"background": t["panel"]}} />
                                            <div className="tp-line" style={{"background": t["accent"]}} />
                                        </div>
                                    </div>
                                    <span className="theme-name">{t["name"]}{theme == t["id"] and <Check size={13} />}</span>
                                </button>
                            }}
                        </div>
                    } else {
                        <div>
                            <div className="section">
                                <h4>Key sources</h4>
                                <p>{"API keys are read from these .env files at startup. Only key names reach the UI."}</p>
                                {for f in st.env_files {
                                    <div key={f} className="row">
                                        <span className="mono" style={{"flex": 1}}>{f}</span>
                                        <button className="chip-btn" onClick={lambda (e: MouseEvent) { act("unregister_env_file", {"path": f}, "Removing"); }}>Remove</button>
                                    </div>
                                }}
                                <div className="row">
                                    <input className="field" value={envPath} placeholder="~/path/to/.env" onChange={lambda (e: ChangeEvent) { envPath = e.target.value; }} />
                                    <button className="chip-btn" disabled={not envPath} onClick={lambda (e: MouseEvent) { act("register_env_file", {"path": envPath}, "Adding"); envPath = ""; }}>Add .env</button>
                                </div>
                                {len(st.keys_present) > 0 and <p className="note">{"Keys available: " + ", ".join(st.keys_present)}</p>}
                            </div>
                        </div>
                    }}
                </div>
            </div>
        </div>
    </div>
}
