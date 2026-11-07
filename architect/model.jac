"""Wire types for the discovered architecture (the domain view: stages, passes, services...)."""

"""One architectural component. Sub-components (e.g. the passes inside a compiler's semantic
stage) point at their parent; `order` sequences pipeline stages (0 when not a stage)."""
obj ArchComponent {
    has id: str;
    has name: str;
    has kind: str = "component";
    has summary: str = "";
    has paths: list[str] = [];
    has order: int = 0;
    has parent: str = "";
    has children: list[str] = [];
    has module_count: int = 0;
    has loc: int = 0;
    has confidence: float = 0.0;
    has jev_mapped: int = 0;
    has top_modules: list[str] = [];
}

"""Something that moves between components. `declared` flows come from the architect; `observed`
counts real imports between the components' modules. Observed-only flows are drift."""
obj ArchFlow {
    has src: str;
    has dst: str;
    has label: str = "";
    has declared: bool = True;
    has observed: int = 0;
}

obj ArchModel {
    has ok: bool = True;
    has exists: bool = False;
    has error: str = "";
    has project: str = "";
    has system_kind: str = "";
    has style: str = "";
    has title: str = "";
    has summary: str = "";
    has components: list[ArchComponent] = [];
    has flows: list[ArchFlow] = [];
    has coverage: float = 0.0;
    has modules_total: int = 0;
    has unassigned: int = 0;
    has unassigned_sample: list[str] = [];
    has drift: list[str] = [];
    has stale: bool = False;
    has stale_reason: str = "";
    has generated_by: str = "";
    has mapped_by: str = "";
    has updated_at: str = "";
}

obj ArchStep {
    has label: str;
    has state: str = "pending";
    has detail: str = "";
}

obj ArchStatus {
    has running: bool = False;
    has done: bool = False;
    has ok: bool = True;
    has error: str = "";
    has engine: str = "";
    has steps: list[ArchStep] = [];
    has started_at: float = 0.0;
}

"""What a module belongs to, for the developer view and the agent."""
obj ModuleArch {
    has module: str;
    has component: str = "";
    has component_name: str = "";
    has parent_name: str = "";
    has source: str = "";
    has confidence: float = 0.0;
}

"""A module inside an architecture component (the architecture view's deepest level)."""
obj ModNode {
    has id: str;
    has name: str;
    has loc: int = 0;
    has fan_in: int = 0;
    has role: str = "";
    has summary: str = "";
    has confidence: float = 0.0;
    has source: str = "";
    has component: str = "";
}

obj ModEdge {
    has src: str;
    has dst: str;
    has weight: int = 1;
}

obj CompModules {
    has ok: bool = True;
    has error: str = "";
    has component: str = "";
    has name: str = "";
    has modules: list[ModNode] = [];
    has edges: list[ModEdge] = [];
    has more: int = 0;
}
