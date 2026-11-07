# jac smith

An architecture-first, agent-first IDE, written in Jac and shipped as a native desktop app.

You don't start from files. You start from a **box**: the whole project, holding sub-boxes sized by
importance rather than by line count, with everything the code reaches outside itself drawn as
dashed boxes. The same index drives two views and a coding agent:

- **Developer view**: nested boxes (a binary treemap weighted by fan-in, public API surface and
  size, with Jev's centrality tier applied), colored by architectural role, each showing a
  syntax-highlighted snippet. Hover a box to see what it depends on and what depends on it; click to
  open it. At the bottom of a drill-down you get the file itself: line numbers, an outline, and
  editing behind a lock.
- **Architecture view**: the system the code implements (compiler stages and passes, services,
  stores) rather than its folders. A hybrid engine discovers it: deterministic subsystems, a Jev
  archetype template with slot placement, then one focused refine call to Codex, Claude or Gemini.
  Modules are mapped onto components, flows are checked against real imports, and drift is
  reported. Zooming in leads back to the modules.
- **History view**: git history drawn like a git tree rotated 90 degrees. The trunk (main) is the
  top line, commits are blobs along it, and branches hang below it, forking off and merging back.
- **Review view**: open pull requests (via the GitHub CLI), and for each one the architecture
  components it lands in, the modules that depend on what it edits, and per-file diffs.
- **Agent hub**: always scoped to what you're focused on. Gemini over ACP, Codex (`codex exec`),
  Claude (`claude -p`), or the Jac byLLM agent with tools that read the architecture graph, read,
  search and write files, run `jac check`, and load Jac skills via `jac guide`. Boxes it reads light
  up yellow; boxes it edits turn red. It minimizes to a floating orb.
- **Terminal**: real PTYs running your login shell (`$SHELL -l`), so your prompt (e.g.
  powerlevel10k) and dotfiles load as usual. The font follows your terminal setup (VS Code's
  terminal font, or an installed Nerd Font).

Every panel is resizable, and the theme (midnight, graphite, daylight) is set in Settings.

## Layout

| Box | What it does |
|---|---|
| `indexer/` | `scan` parses Python (stdlib `ast`), Jac and JS/TS; `graph` builds Jac `Box`/`External` nodes with `Contains`/`Imports`/`Uses` edges (including `arch.jac` wiring) and rolls importance up with a post-order `Rollup` walker; `roles` asks **Jev** (System One) for each module's role and tier; `layout` is the treemap; `snippets` tokenizes code previews; `api` serves one level at a time as a `BoxFrame`. |
| `architect/` | Architecture discovery and maintenance: templates, the hybrid engine, Jev placement, module mapping, drift. |
| `agent/`, `agents/` | The byLLM Jac agent and its tools; the agent hub (ACP client, Codex/Claude runners, permission requests). |
| `history/` | Commit graph, timeline lanes, commit details and diffs. |
| `review/` | Pull requests and their impact on boxes and architecture components. |
| `settings/` | Credentials, model and theme settings, ChatGPT sign-in via the official Codex CLI, and the session token. |
| `terminal/` | PTY sessions, long-polled by byte offset (the desktop host buffers streamed responses). |
| `ui/` | Client components: `Shell`, `BoxView`, `CodeView`, `ArchView`, `TimelineView`, `ReviewView`, `DetailCard`, `AgentPanel`, `Terminal`, `SettingsPanel`. |

## Run

```bash
jac install          # Python + npm deps
jac run              # build if needed, then open the desktop window
jac run --dev        # hot reload
jac build            # .jac/client/desktop/jac-smith.app
jac test -d tests/   # indexer, architecture, agent hub, history, review, PTY tests
```

## Keys and accounts

- **Jev**: put `JEV_API_KEY` (or `TYPESAFE_API_KEY`) in any `.env` file and add that file under
  Settings. Keys are loaded into the server process only; the UI only ever learns key *names*.
- **ChatGPT**: Settings → *Sign in with ChatGPT*. This runs `codex login` from OpenAI's Codex CLI,
  installed on demand into `~/.jac-smith/tools`, so jac smith never handles your ChatGPT
  credentials.
- **Jac agent model**: any LiteLLM model id (default `openrouter/anthropic/claude-sonnet-4.5`),
  using keys from the same `.env` files.

## Security note

Single-process Jac serving allows any origin (CORS `*`) on a loopback port, so every endpoint
requires a session token. The token is kept in `~/.jac-smith/session.token` (mode 0600), and the UI
reads it through the desktop host's native bridge, which only accepts loopback origins. A web
page can't read it, so it can't drive the terminal or the agent.
