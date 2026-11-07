"""Architecture templates: the closed vocabulary Jev chooses from.

Each archetype lists slots (components a system of that kind usually has, in pipeline order where
one exists) and canonical flows between them. Jev picks the archetype, then places each subsystem
into a slot. Codex later renames and splits slots in the project's own vocabulary.
"""

obj Slot {
    has id: str;
    has name: str;
    has kind: str;
    has summary: str;
    has order: int = 0;
}

obj Template {
    has id: str;
    has name: str;
    has description: str;
    has style: str;
    has slots: list[Slot];
    has flows: list[tuple[str, str, str]] = [];
}

glob OUTSIDE_SLOT: str = "outside";
glob OUTSIDE_TEXT: str = "Not part of the product: tests, examples, benchmarks, fixtures, docs, scripts, vendored or generated code";

def _s(id: str, name: str, kind: str, summary: str, order: int = 0) -> Slot {
    return Slot(id=id, name=name, kind=kind, summary=summary, order=order);
}

glob TEMPLATES: list[Template] = [
    Template(
        id="compiler", style="pipeline", name="Compiler / language toolchain",
        description="Compiler, interpreter or programming-language toolchain: parses source, analyzes it, generates code, ships a runtime",
        slots=[
            _s("frontend", "Lexing and parsing", "stage", "Tokenizer, grammar and parser that turn source text into a syntax tree", 1),
            _s("ast", "Syntax tree and IR model", "component", "Syntax-tree / intermediate-representation data structures and utilities"),
            _s("semantic", "Semantic analysis", "stage", "Symbol tables, name and import resolution, type checking and other static checks", 2),
            _s("lowering", "Lowering and optimization", "stage", "Intermediate representations and transforms between them", 3),
            _s("codegen", "Code generation", "stage", "Backends that emit target code: bytecode, JavaScript, native or LLVM", 4),
            _s("runtime", "Runtime", "runtime", "Runtime library and execution model used by compiled programs", 5),
            _s("driver", "Compiler driver", "component", "Orchestrates passes, module loading, caching and builds"),
            _s("stdlib", "Standard library", "library", "Built-in modules for user programs"),
            _s("tooling", "Developer tooling", "tooling", "CLI, language server, formatter, editor integration"),
            _s("platform", "Application platform", "service", "Features beyond the language core: serving, persistence, deployment, AI integration, client bundling")
        ],
        flows=[
            ("frontend", "semantic", "syntax tree"), ("semantic", "lowering", "analyzed tree"),
            ("lowering", "codegen", "IR"), ("semantic", "codegen", "analyzed tree"), ("codegen", "runtime", "generated code"),
            ("driver", "frontend", "source modules"), ("tooling", "driver", "build requests"), ("runtime", "stdlib", "library calls"),
            ("runtime", "platform", "platform services")
        ]
    ),
    Template(
        id="webapp", style="client-server", name="Web application",
        description="Web application: browser client plus server API and database",
        slots=[
            _s("client", "Client UI", "ui", "Pages, components, client state and styling", 1),
            _s("api", "API layer", "service", "Routes, controllers, request validation, serialization", 2),
            _s("domain", "Domain logic", "component", "Business rules and use cases", 3),
            _s("data", "Data access", "store", "Database schema, queries, repositories, migrations", 4),
            _s("auth", "Identity and access", "service", "Authentication, sessions, permissions"),
            _s("integrations", "Integrations", "service", "Clients for external services, queues, email, payments"),
            _s("jobs", "Background jobs", "service", "Workers, schedulers, async processing"),
            _s("shared", "Shared kernel", "library", "Types, utilities and config shared by client and server"),
            _s("ops", "Build and deployment", "tooling", "Build scripts, infrastructure, CI")
        ],
        flows=[("client", "api", "HTTP requests"), ("api", "domain", "commands and queries"), ("domain", "data", "persistence"),
               ("api", "auth", "credentials"), ("domain", "integrations", "external calls"), ("jobs", "domain", "scheduled work")]
    ),
    Template(
        id="service", style="layered", name="Backend service / platform",
        description="Backend service or API platform without its own language",
        slots=[
            _s("interface", "Service interface", "interface", "Endpoints, RPC handlers, protocol adapters", 1),
            _s("application", "Application services", "component", "Use cases orchestrating the domain", 2),
            _s("domain", "Domain model", "component", "Core entities and rules", 3),
            _s("persistence", "Persistence", "store", "Storage, caching, schemas", 4),
            _s("integration", "Integrations", "service", "Outbound clients and messaging"),
            _s("infra", "Runtime infrastructure", "runtime", "Configuration, logging, concurrency, auth plumbing"),
            _s("ops", "Operations", "tooling", "Deployment, scripts, observability")
        ],
        flows=[("interface", "application", "requests"), ("application", "domain", "operations"), ("domain", "persistence", "state"),
               ("application", "integration", "outbound calls")]
    ),
    Template(
        id="datapipe", style="pipeline", name="Data pipeline",
        description="Data or ETL pipeline: ingest, transform, store, report",
        slots=[
            _s("ingest", "Ingestion", "stage", "Sources, connectors, extraction", 1),
            _s("transform", "Transformation", "stage", "Cleaning, enrichment, joins, feature building", 2),
            _s("store", "Storage", "store", "Warehouses, lakes, schemas", 3),
            _s("serve", "Serving and reporting", "stage", "APIs, dashboards, exports", 4),
            _s("orchestration", "Orchestration", "component", "DAGs, schedulers, retries"),
            _s("quality", "Data quality", "component", "Validation, tests on data, lineage"),
            _s("ops", "Operations", "tooling", "Deployment and configuration")
        ],
        flows=[("ingest", "transform", "raw records"), ("transform", "store", "clean tables"), ("store", "serve", "query results"),
               ("orchestration", "ingest", "runs")]
    ),
    Template(
        id="ml", style="pipeline", name="Machine-learning system",
        description="Machine-learning training or inference system",
        slots=[
            _s("data", "Data preparation", "stage", "Datasets, loaders, preprocessing, features", 1),
            _s("model", "Model definition", "component", "Architectures, layers, losses"),
            _s("training", "Training", "stage", "Training loops, optimization, checkpoints", 2),
            _s("evaluation", "Evaluation", "stage", "Metrics, benchmarks, analysis", 3),
            _s("inference", "Inference and serving", "stage", "Prediction APIs, batching, deployment", 4),
            _s("experiment", "Experiment management", "tooling", "Configs, tracking, sweeps"),
            _s("infra", "Compute infrastructure", "runtime", "Distributed training, hardware, kernels")
        ],
        flows=[("data", "training", "batches"), ("model", "training", "model"), ("training", "evaluation", "checkpoints"),
               ("training", "inference", "trained weights")]
    ),
    Template(
        id="library", style="library", name="Library / SDK",
        description="General-purpose library or SDK consumed by other programs",
        slots=[
            _s("api", "Public API", "interface", "The surface users import", 1),
            _s("core", "Core engine", "component", "The main algorithms and abstractions", 2),
            _s("extensions", "Extensions and plugins", "component", "Optional features and extension points"),
            _s("adapters", "Adapters", "component", "Integrations with other libraries and platforms"),
            _s("utils", "Utilities", "library", "Shared helpers"),
            _s("tooling", "Tooling", "tooling", "Build, docs generation, release")
        ],
        flows=[("api", "core", "calls"), ("core", "extensions", "hooks"), ("core", "adapters", "platform calls")]
    ),
    Template(
        id="cli", style="layered", name="Command-line tool",
        description="Command-line tool",
        slots=[
            _s("commands", "Commands", "interface", "Argument parsing and command handlers", 1),
            _s("core", "Core logic", "component", "What the commands actually do", 2),
            _s("io", "I/O and integrations", "component", "Files, network, subprocesses, external tools", 3),
            _s("config", "Configuration", "component", "Settings, profiles, environment"),
            _s("output", "Output and reporting", "ui", "Formatting, progress, terminal UI")
        ],
        flows=[("commands", "core", "parsed arguments"), ("core", "io", "operations"), ("core", "output", "results")]
    ),
    Template(
        id="ide", style="layered", name="Developer tool / IDE",
        description="Developer tool, IDE or code-intelligence application with UI, analysis engine and agents",
        slots=[
            _s("ui", "User interface", "ui", "Views, panels, components, styling", 1),
            _s("analysis", "Code analysis engine", "component", "Indexing, parsing, code maps and graphs", 2),
            _s("ai", "AI agents", "service", "LLM agents, prompts, model integration"),
            _s("platform", "Host platform", "runtime", "Desktop/web host, terminals, OS integration, settings"),
            _s("storage", "State and storage", "store", "Caches, persisted state, configuration files")
        ],
        flows=[("ui", "analysis", "queries"), ("ui", "ai", "requests"), ("ai", "analysis", "context"), ("analysis", "storage", "cached results")]
    ),
    Template(
        id="game", style="layered", name="Game / game engine",
        description="Game or game engine",
        slots=[
            _s("loop", "Game loop", "runtime", "Main loop, timing, scheduling", 1),
            _s("logic", "Game logic", "component", "Rules, entities, scripting", 2),
            _s("render", "Rendering", "component", "Graphics, scenes, shaders", 3),
            _s("physics", "Physics and simulation", "component", "Collision, movement"),
            _s("assets", "Assets", "store", "Loading and managing assets"),
            _s("input", "Input and audio", "interface", "Controls, sound"),
            _s("ui", "Game UI", "ui", "Menus and HUD")
        ],
        flows=[("loop", "logic", "ticks"), ("logic", "render", "scene state"), ("input", "logic", "events")]
    )
];

def template_by_id(tid: str) -> Template | None {
    for t in TEMPLATES {
        if t.id == tid {
            return t;
        }
    }
    return None;
}
