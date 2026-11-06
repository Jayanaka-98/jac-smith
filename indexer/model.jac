"""Wire types shared by the indexer, the agent, and the UI."""

"""A top-level declaration inside a module: the module's interface surface."""
obj SymbolInfo {
    has name: str;
    has kind: str;
    has line: int = 0;
    has signature: str = "";
    has public: bool = True;
}

"""A box in the developer view: the project, a package (directory), or a module (file)."""
obj BoxInfo {
    has id: str;
    has name: str;
    has path: str;
    has kind: str;
    has lang: str = "";
    has parent: str = "";
    has children: list[str] = [];
    has loc: int = 0;
    has files: int = 0;
    has score: float = 0.0;
    has importance: float = 0.0;
    has centrality: float = 0.0;
    has fan_in: int = 0;
    has role: str = "";
    has tier: str = "";
    has role_confidence: float = 0.0;
    has role_source: str = "";
    has summary: str = "";
    has symbols: list[SymbolInfo] = [];
    has externals: list[str] = [];
    has depends_on: list[str] = [];
}

"""Something a box points at that is not part of the box's own code.

ecosystem is one of: stdlib, pypi, npm, node, jac, project.
"project" marks an internal box that lives outside the current focus.
"""
obj ExternalInfo {
    has id: str;
    has name: str;
    has ecosystem: str;
    has uses: int = 0;
}

"""A positioned rectangle in unit coordinates (0..1) of its parent box."""
obj Tile {
    has id: str;
    has name: str;
    has kind: str;
    has x: float;
    has y: float;
    has w: float;
    has h: float;
    has importance: float = 0.0;
    has centrality: float = 0.0;
    has role: str = "";
}

"""A child of the focused box, with its tile and a one-level preview of its insides."""
obj ChildView {
    has info: BoxInfo;
    has tile: Tile;
    has inner: list[Tile] = [];
    has code: list[list[str]] = [];
    has code_from: str = "";
    has code_line: int = 0;
}

"""An aggregated dependency between two boxes (or a box and an external) at the focus level."""
obj DepEdge {
    has src: str;
    has dst: str;
    has weight: int = 1;
    has external: bool = False;
}

obj Crumb {
    has id: str;
    has name: str;
}

"""Everything both views need to render one level of the hierarchy."""
obj BoxFrame {
    has ok: bool = True;
    has error: str = "";
    has project: str = "";
    has focus: BoxInfo | None = None;
    has crumbs: list[Crumb] = [];
    has children: list[ChildView] = [];
    has externals: list[ExternalInfo] = [];
    has edges: list[DepEdge] = [];
}

obj IndexSummary {
    has ok: bool = True;
    has error: str = "";
    has project: str = "";
    has root_id: str = "";
    has modules: int = 0;
    has packages: int = 0;
    has externals: int = 0;
    has loc: int = 0;
    has millis: int = 0;
}

obj AgentReply {
    has text: str;
    has backend: str = "";
    has touched: list[str] = [];
    has edited: list[str] = [];
    has reindexed: bool = False;
    has ok: bool = True;
}

"""Result of the Jev role-classification pass over the indexed modules."""
obj EnrichSummary {
    has ok: bool = True;
    has error: str = "";
    has classified: int = 0;
    has cached: int = 0;
    has source: str = "";
    has millis: int = 0;
}

"""What the settings panel shows. Never carries secret values, only whether they are present."""
obj SettingsStatus {
    has jev_ready: bool = False;
    has jev_source: str = "";
    has env_files: list[str] = [];
    has keys_present: list[str] = [];
    has agent_model: str = "";
    has agent_backend: str = "";
    has codex_installed: bool = False;
    has codex_path: str = "";
    has chatgpt_signed_in: bool = False;
    has chatgpt_status: str = "";
    has login_in_progress: bool = False;
    has login_url: str = "";
    has message: str = "";
    has arch_namer: str = "codex";
    has claude_model: str = "";
    has gemini_model: str = "";
    has codex_model: str = "";
    has custom_acp_command: str = "";
    has theme: str = "midnight";
    has jev_hint: str = "";
    has gemini_key_hint: str = "";
}

"""A file opened for editing. `version` (content hash) guards against overwriting changes made elsewhere."""
obj SourceFile {
    has ok: bool = True;
    has error: str = "";
    has path: str = "";
    has text: str = "";
    has mtime: float = 0.0;
    has version: str = "";
    has conflict: bool = False;
}
