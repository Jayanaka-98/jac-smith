"""jac smith: an architecture-first, agent-first IDE (Jac desktop app).

Server half: the Jev-assisted architecture indexer, the coding agent (ChatGPT via Codex, or a
byLLM Jac agent), settings, and PTY terminals. The UI calls them over raw fetch (see ui/rpc.jac),
so every endpoint module is imported here to register it.
"""
import from indexer.api {
    default_project, recent_projects, index_project, get_frame, get_box, read_source,
    read_source_tokens, read_source_lines, read_source_file, write_source
}
import from settings.api {
    get_settings, register_env_file, unregister_env_file, set_agent, chatgpt_install,
    chatgpt_sign_in, chatgpt_cancel, chatgpt_sign_out, set_config, set_key, test_jev
}
import from agents.hub { agent_start, agent_events, agent_permission, agent_cancel, agent_reset, agents_status, agent_install }
import from agent.agent { ask_agent, reset_agent }
import from architect.discover { arch_get, arch_discover, arch_status, arch_of_module, arch_refine, arch_component_modules }
import from history.git { git_log, git_commit, git_file_diff, git_timeline }
import from terminal.shells { term_open, term_stream, term_read, term_write, term_resize, term_close, term_prefs }

import "./assets/app.css";
import from .ui.Shell { Shell }

def:pub app() -> JsxElement {
    <Shell />
}
