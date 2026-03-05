# Codebase Structure

**Analysis Date:** 2026-03-05

## Directory Layout

```
nvim-dbee/
├── dbee/                    # Go backend (compiled to binary)
│   ├── main.go              # Process entry point, RPC server
│   ├── endpoints.go         # RPC endpoint definitions (DbeeXxx functions)
│   ├── endpoints_test.go    # Endpoint argument parsing tests
│   ├── adapters/            # Database-specific driver implementations
│   ├── core/                # Database-agnostic abstractions
│   │   ├── builders/        # ResultStream convenience constructors
│   │   ├── format/          # Output formatters (JSON, CSV)
│   │   └── mock/            # Test doubles for Adapter/ResultStream
│   ├── handler/             # Connection/call lifecycle, event bus
│   ├── plugin/              # Neovim RPC plugin framework, logger, manifest
│   └── tests/               # Integration tests per database
│       ├── integration/     # Per-adapter integration test files
│       ├── testdata/        # Test SQL fixtures
│       └── testhelpers/     # Per-adapter test setup helpers
├── lua/                     # Lua frontend (Neovim plugin)
│   └── dbee/                # Main Lua package
│       ├── api/             # Structured API layer (core, ui, state)
│       ├── handler/         # Lua-side handler (wraps Go RPC calls)
│       ├── install/         # Binary installation from manifest
│       ├── layouts/         # Window layout implementations
│       ├── lsp/             # SQL autocompletion LSP server
│       ├── ui/              # UI components
│       │   ├── common/      # Shared buffer/window helpers, floats
│       │   ├── drawer/      # Tree view (connections, schemas, notes)
│       │   ├── editor/      # SQL editor with note management
│       │   └── result/      # Query result display with pagination
│       ├── config.lua        # Default config, validation, merge
│       ├── doc.lua           # Doc generation helpers
│       ├── health.lua        # :checkhealth integration
│       ├── query_splitter.lua # Oracle-aware SQL script splitting
│       ├── sources.lua       # Connection source implementations
│       ├── utils.lua         # Shared utilities
│       └── variables.lua     # Bind/substitution variable resolution
├── plugin/                  # Neovim plugin loader
│   └── dbee.lua             # :Dbee command registration
├── ci/                      # Build and test infrastructure
│   ├── headless/            # Headless Neovim test scripts
│   ├── build.sh             # Cross-platform Go build
│   ├── publish.sh           # Release publishing
│   ├── target-matrix.sh     # CI target enumeration
│   └── targets.json         # Supported OS/arch matrix
├── doc/                     # Vim help files
├── docs/                    # Design docs and plans
│   └── plans/               # Implementation plans
├── assets/                  # Images and media
├── bin/                     # Compiled binary output
├── .github/                 # GitHub Actions workflows
│   └── workflows/           # CI pipeline definitions
├── ARCHITECTURE.md          # Upstream architecture overview
├── README.md                # User documentation
├── LICENSE                  # AGPL-3.0
├── .stylua.toml             # Lua formatter config
├── .luacheckrc              # Lua linter config
├── .luarc.json              # Lua language server config
└── .gitignore               # Git ignore rules
```

## Directory Purposes

**`dbee/` (Go Backend):**
- Purpose: Compiled Go binary that runs as a Neovim remote plugin process
- Contains: All database interaction logic, RPC endpoints, adapters
- Key files:
  - `dbee/main.go`: Process entry, RPC server setup
  - `dbee/endpoints.go`: All `DbeeXxx` RPC function registrations
  - `dbee/handler/handler.go`: Connection/call state management
  - `dbee/core/connection.go`: Connection abstraction with Adapter/Driver
  - `dbee/core/call.go`: Query execution state machine
  - `dbee/core/result.go`: Thread-safe result caching
  - `dbee/core/types.go`: Core interfaces (ResultStream, Formatter, Structure)
  - `dbee/core/call_state.go`: Call state enum
  - `dbee/core/call_error_kind.go`: Error classification
  - `dbee/core/call_archive.go`: Result persistence to temp files

**`dbee/adapters/` (Database Drivers):**
- Purpose: Per-database Adapter+Driver implementations, self-registered at init
- Contains: One `{db}.go` (init + registration) + `{db}_driver.go` (Driver impl) per database
- Key files:
  - `dbee/adapters/adapters.go`: Mux registry, `NewConnection()` factory
  - `dbee/adapters/postgres.go` / `dbee/adapters/postgres_driver.go`: PostgreSQL
  - `dbee/adapters/oracle.go` / `dbee/adapters/oracle_driver.go`: Oracle (with PL/SQL, DBMS_OUTPUT, ref cursors)
  - `dbee/adapters/oracle_plsql.go`: PL/SQL block detection
  - `dbee/adapters/oracle_refcursor.go`: REF CURSOR handling
- Naming: `{database}.go` for init/registration, `{database}_driver.go` for Driver implementation

**`dbee/core/builders/`:**
- Purpose: Convenience functions for creating ResultStream and related objects
- Key files:
  - `dbee/core/builders/client.go`: Client builder
  - `dbee/core/builders/result.go`: ResultStream builder
  - `dbee/core/builders/next.go`: Next() implementation helpers
  - `dbee/core/builders/columns.go`: Column builder

**`dbee/handler/` (Go Handler):**
- Purpose: Neovim-aware handler that wraps core abstractions with RPC event dispatching
- Key files:
  - `dbee/handler/handler.go`: Main handler with connection/call lookups
  - `dbee/handler/event_bus.go`: Go-to-Lua event dispatch via ExecLua
  - `dbee/handler/call_log.go`: Call log persistence (JSON to /tmp)
  - `dbee/handler/format_table.go`: Table formatter for buffer display
  - `dbee/handler/output_buffer.go`: Neovim buffer writer
  - `dbee/handler/output_yank.go`: Yank register writer
  - `dbee/handler/marshal.go`: Go-to-Lua type conversion helpers

**`lua/dbee/` (Lua Frontend):**
- Purpose: Neovim plugin logic -- UI, config, API
- Key files:
  - `lua/dbee.lua`: Public API (setup, execute, actions, pickers)
  - `lua/dbee/config.lua`: Default config + validation + merge
  - `lua/dbee/utils.lua`: Shared utilities (logging, visual_selection, query_under_cursor)
  - `lua/dbee/sources.lua`: FileSource, EnvSource, MemorySource
  - `lua/dbee/query_splitter.lua`: Oracle-aware SQL splitting (handles `/` terminators, PL/SQL blocks)
  - `lua/dbee/variables.lua`: Bind variable (`:name`) and substitution variable (`&name`) resolution
  - `lua/dbee/health.lua`: `:checkhealth` provider
  - `lua/dbee/doc.lua`: Documentation generation helpers

**`lua/dbee/api/`:**
- Purpose: Structured API layer that lazily initializes subsystems
- Key files:
  - `lua/dbee/api/init.lua`: Exports `core`, `ui`, `setup`, `current_config`
  - `lua/dbee/api/core.lua`: Backend API (connections, calls, helpers, history)
  - `lua/dbee/api/ui.lua`: UI API (editor, result, drawer, call_log operations)
  - `lua/dbee/api/state.lua`: Singleton state manager, lazy init of Handler + UI components
  - `lua/dbee/api/__register.lua`: Remote plugin process registration

**`lua/dbee/handler/`:**
- Purpose: Lua wrapper around Go backend RPC calls
- Key files:
  - `lua/dbee/handler/init.lua`: Handler class -- source management, connection_execute, call_cancel, etc.
  - `lua/dbee/handler/__events.lua`: Event bus for Go-to-Lua callbacks (register + trigger)

**`lua/dbee/ui/`:**
- Purpose: UI tile implementations
- Key files:
  - `lua/dbee/ui/editor/init.lua`: EditorUI -- note management, query actions, diagnostics, cancel-confirm
  - `lua/dbee/ui/editor/welcome.lua`: Welcome screen banner
  - `lua/dbee/ui/result/init.lua`: ResultUI -- paginated display, progress, yank
  - `lua/dbee/ui/result/progress.lua`: Spinner with slow/stuck hints
  - `lua/dbee/ui/drawer/init.lua`: DrawerUI -- NuiTree-based tree view
  - `lua/dbee/ui/drawer/convert.lua`: Converts handler/editor data to DrawerUINode trees
  - `lua/dbee/ui/drawer/menu.lua`: Floating select/input menus
  - `lua/dbee/ui/drawer/expansion.lua`: Tree expansion state save/restore
  - `lua/dbee/ui/call_log.lua`: CallLogUI -- call history display
  - `lua/dbee/ui/common/init.lua`: Shared buffer/window configuration helpers
  - `lua/dbee/ui/common/floats.lua`: Floating window configuration

**`lua/dbee/lsp/`:**
- Purpose: Built-in SQL LSP for table/column autocompletion
- Key files:
  - `lua/dbee/lsp/init.lua`: LSP lifecycle, 3-tier cache strategy, event registration
  - `lua/dbee/lsp/server.lua`: LSP server implementation (completionProvider)
  - `lua/dbee/lsp/schema_cache.lua`: Schema data cache with disk persistence
  - `lua/dbee/lsp/context.lua`: SQL context analysis for completions
  - `lua/dbee/lsp/bench.lua`: Benchmarking utilities

**`lua/dbee/layouts/`:**
- Purpose: Window layout strategies
- Key files:
  - `lua/dbee/layouts/init.lua`: `Default` (4-pane) and `Minimal` (2-pane) layouts
  - `lua/dbee/layouts/tools.lua`: Window state save/restore ("egg" pattern)

**`ci/headless/`:**
- Purpose: Pure-Lua headless tests that run in Neovim without database connections
- Contains: `check_*.lua` test scripts (query splitter, variables, actions, LSP, editor features)
- Key files:
  - `ci/headless/run_note_queries.lua`: Note query execution test harness
  - `ci/headless/test.sql`: SQL fixture data

**`plugin/`:**
- Purpose: Neovim plugin autoload entry point
- Key files:
  - `plugin/dbee.lua`: `:Dbee` user command with subcommand routing

## Key File Locations

**Entry Points:**
- `lua/dbee.lua`: Main public API (require("dbee"))
- `plugin/dbee.lua`: :Dbee command registration
- `dbee/main.go`: Go process entry point

**Configuration:**
- `lua/dbee/config.lua`: All defaults, validation, merge logic
- `.stylua.toml`: Lua formatter settings
- `.luacheckrc`: Lua linter settings
- `.luarc.json`: Lua language server settings

**Core Logic (Go):**
- `dbee/core/connection.go`: Connection with Adapter/Driver
- `dbee/core/call.go`: Query execution lifecycle
- `dbee/core/result.go`: Result caching and formatting
- `dbee/handler/handler.go`: State management
- `dbee/endpoints.go`: RPC endpoint definitions

**Core Logic (Lua):**
- `lua/dbee/handler/init.lua`: RPC call wrapper
- `lua/dbee/api/state.lua`: Lazy initialization orchestrator
- `lua/dbee/query_splitter.lua`: SQL script splitting
- `lua/dbee/variables.lua`: Variable resolution

**UI:**
- `lua/dbee/ui/editor/init.lua`: SQL editor
- `lua/dbee/ui/result/init.lua`: Result viewer
- `lua/dbee/ui/drawer/init.lua`: Tree browser
- `lua/dbee/ui/call_log.lua`: Call history
- `lua/dbee/layouts/init.lua`: Window arrangement

**Testing:**
- `ci/headless/check_*.lua`: Headless Lua tests
- `dbee/tests/integration/`: Go integration tests per adapter
- `dbee/core/*_test.go`: Go unit tests
- `dbee/adapters/*_test.go`: Adapter unit tests

## Naming Conventions

**Files (Lua):**
- Pattern: `snake_case.lua`
- Examples: `query_splitter.lua`, `call_log.lua`, `schema_cache.lua`
- Module entry: `init.lua` inside a directory
- Private modules: prefix with `__` (e.g., `__events.lua`, `__register.lua`)

**Files (Go):**
- Pattern: `snake_case.go`
- Examples: `call_state.go`, `call_error_kind.go`, `event_bus.go`
- Tests: `*_test.go` co-located with source
- Adapters: `{database}.go` (registration) + `{database}_driver.go` (implementation)

**Directories:**
- Pattern: `snake_case` for both Go and Lua
- UI components: named by function (`editor/`, `result/`, `drawer/`)

## Where to Add New Code

**New Database Adapter:**
- Create `dbee/adapters/{name}.go` with `init()` that calls `register(adapter, "type_alias")`
- Create `dbee/adapters/{name}_driver.go` implementing `core.Driver` interface
- Add integration test: `dbee/tests/integration/{name}_integration_test.go`
- Add test helper: `dbee/tests/testhelpers/{name}.go`
- Optionally add LSP metadata query in `lua/dbee/lsp/init.lua` METADATA_QUERIES table

**New RPC Endpoint:**
- Add handler method in `dbee/handler/handler.go`
- Register endpoint in `dbee/endpoints.go` via `p.RegisterEndpoint("DbeeNewEndpoint", ...)`
- Add Lua wrapper in `lua/dbee/handler/init.lua`
- Expose via API in `lua/dbee/api/core.lua` or `lua/dbee/api/ui.lua`

**New UI Feature:**
- For editor actions: add to `EditorUI:get_actions()` in `lua/dbee/ui/editor/init.lua`
- For result actions: add to `ResultUI:get_actions()` in `lua/dbee/ui/result/init.lua`
- For drawer actions: add to `DrawerUI:get_actions()` in `lua/dbee/ui/drawer/init.lua`
- Register key mapping in `lua/dbee/config.lua` default mappings

**New Connection Source:**
- Implement `Source` interface in `lua/dbee/sources.lua` (or separate file)
- Required methods: `name()` -> string, `load()` -> ConnectionParams[]
- Optional methods: `create()`, `update()`, `delete()`, `file()`

**New Public API Function:**
- Add function to `lua/dbee.lua`
- Add `:Dbee` subcommand in `plugin/dbee.lua` if user-facing
- Add to `dbee.actions()` picker if appropriate

**New Event:**
- Go side: Add method to `eventBus` in `dbee/handler/event_bus.go`
- Fire from handler method in `dbee/handler/handler.go`
- Lua side: Register listener via `handler:register_event_listener(event_name, fn)` in consuming component

**New Headless Test:**
- Create `ci/headless/check_{feature}.lua`
- Add to CI matrix in `.github/workflows/`
- Pattern: setup mock handler/editor, exercise logic, assert with `assert()`, print pass/fail

**New Layout:**
- Implement `Layout` interface: `is_open()`, `open()`, `reset()`, `close()`
- Reference: `lua/dbee/layouts/init.lua` Default and Minimal implementations
- Pass to config: `window_layout = MyLayout:new(opts)`

## Special Directories

**`bin/`:**
- Purpose: Compiled Go binary output directory
- Generated: Yes (by `ci/build.sh` or `go build`)
- Committed: No (in .gitignore except manifest)

**`.planning/`:**
- Purpose: GSD planning and codebase analysis documents
- Generated: By analysis tools
- Committed: No

**`doc/`:**
- Purpose: Vim help documentation files
- Generated: Partially (from Lua annotations)
- Committed: Yes

**`assets/`:**
- Purpose: Screenshots and images for README
- Generated: No
- Committed: Yes

**`dbee/core/mock/`:**
- Purpose: Test doubles for Go unit tests
- Generated: No
- Committed: Yes

---

*Structure analysis: 2026-03-05*
