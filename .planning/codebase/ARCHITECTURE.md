# Architecture

**Analysis Date:** 2026-03-05

## Pattern Overview

**Overall:** Two-process plugin with Go backend (database I/O) and Lua frontend (Neovim UI), communicating via Neovim's RPC/msgpack protocol. Event-driven architecture where Go fires events consumed by Lua listeners.

**Key Characteristics:**
- Strict separation: Go handles all database interaction, Lua handles all UI
- Communication is bidirectional: Lua calls Go functions synchronously via `vim.fn.Dbee*`, Go triggers Lua callbacks via `require("dbee.handler.__events").trigger()`
- Adapter pattern for database drivers -- each database type registers itself at Go init time
- Source pattern for connection providers -- connections loaded from files, env vars, or memory
- UI is event-driven: Go state changes trigger Lua listeners that update UI components
- Lazy initialization: core (Go process) starts on first API call, UI starts on first layout open

## Layers

**Public API (`lua/dbee.lua`):**
- Purpose: User-facing functions (setup, open, close, execute, actions, pickers)
- Location: `lua/dbee.lua`
- Contains: `dbee.setup()`, `dbee.execute_context()`, `dbee.execute_script()`, `dbee.actions()`, `dbee.pick_*()` pickers, `dbee.reconnect_current_connection()`
- Depends on: `lua/dbee/api/init.lua`, `lua/dbee/utils.lua`, `lua/dbee/query_splitter.lua`, `lua/dbee/variables.lua`
- Used by: End users, `plugin/dbee.lua` (`:Dbee` command)

**API Layer (`lua/dbee/api/`):**
- Purpose: Structured access to core (backend) and UI operations. Lazy-initializes subsystems on first access.
- Location: `lua/dbee/api/init.lua`, `lua/dbee/api/core.lua`, `lua/dbee/api/ui.lua`, `lua/dbee/api/state.lua`
- Contains: `api.core.*` (connection/call operations), `api.ui.*` (editor/result/drawer/call_log operations)
- Depends on: `lua/dbee/api/state.lua` (singleton state manager that lazily creates Handler, EditorUI, ResultUI, DrawerUI, CallLogUI)
- Used by: `lua/dbee.lua`, `lua/dbee/layouts/init.lua`

**State Manager (`lua/dbee/api/state.lua`):**
- Purpose: Singleton that owns the lifecycle of Handler and all UI components. Ensures setup order (core before UI).
- Location: `lua/dbee/api/state.lua`
- Contains: `setup()`, `handler()`, `editor()`, `result()`, `drawer()`, `call_log()`, `config()`
- Initialization order: `setup()` stores config -> `handler()` registers Go process + creates Lua Handler -> `editor()/result()/drawer()/call_log()` create UI components
- Used by: `lua/dbee/api/core.lua`, `lua/dbee/api/ui.lua`

**Lua Handler (`lua/dbee/handler/init.lua`):**
- Purpose: Wraps Go backend. Manages sources and their connections. Translates Lua calls to `vim.fn.Dbee*` RPC calls.
- Location: `lua/dbee/handler/init.lua`
- Contains: Source management (`add_source`, `source_reload`, `source_get_connections`), connection operations, call operations
- Depends on: `lua/dbee/handler/__events.lua` (event bus), `lua/dbee/api/__register.lua` (Go process registration)
- Used by: All UI components, API layer

**Event Bus (`lua/dbee/handler/__events.lua`):**
- Purpose: Receives events from Go via `ExecLua`, dispatches to registered Lua listeners via `vim.schedule`
- Location: `lua/dbee/handler/__events.lua`
- Events: `call_state_changed`, `current_connection_changed`, `database_selected`, `structure_loaded`
- Go side: `dbee/handler/event_bus.go` serializes event data as Lua table literals and calls `ExecLua`
- All event callbacks run in `vim.schedule` to avoid blocking the Go RPC thread

**UI Components (`lua/dbee/ui/`):**
- Purpose: Four UI tiles that compose the dbee window layout
- Components:
  - **EditorUI** (`lua/dbee/ui/editor/init.lua`): Note management, SQL editing, query execution actions (run_file, run_selection, run_under_cursor), session persistence, Oracle error diagnostics, cancel-confirm prompt
  - **ResultUI** (`lua/dbee/ui/result/init.lua`): Paginated result display, progress spinner, status messages, yank/store operations
  - **DrawerUI** (`lua/dbee/ui/drawer/init.lua`): Tree view (NuiTree) of connections, schemas, tables, notes. Supports expand/collapse, helpers, generate_call
  - **CallLogUI** (`lua/dbee/ui/call_log.lua`): History of calls with state icons
- All components receive `Handler` and register event listeners for reactive updates
- Contains: Buffer/window management, key mappings, action dispatch

**Layout (`lua/dbee/layouts/init.lua`):**
- Purpose: Window arrangement strategy. Saves/restores vim window layout.
- Location: `lua/dbee/layouts/init.lua`
- Implementations:
  - `Default` -- 4-pane: editor (main), result (bottom), drawer (left), call_log (below drawer)
  - `Minimal` -- 2-pane: editor (top), result (bottom), optional toggle drawer
- Uses: `lua/dbee/layouts/tools.lua` for window save/restore ("egg" pattern)
- Custom layouts implement the `Layout` interface: `is_open()`, `open()`, `reset()`, `close()`

**Go Plugin Entry (`dbee/main.go`):**
- Purpose: Process entry point. Connects to Neovim via stdin/stdout msgpack RPC.
- Location: `dbee/main.go`
- Flow: Creates `nvim.Nvim` client -> creates `plugin.Plugin` + `handler.Handler` -> calls `mountEndpoints()` -> serves RPC
- Also supports `--manifest` flag for generating Lua autoload manifest

**Go Endpoints (`dbee/endpoints.go`):**
- Purpose: Maps RPC function names to `handler.Handler` methods. Defines msgpack argument shapes.
- Location: `dbee/endpoints.go`
- Pattern: `p.RegisterEndpoint("DbeeConnectionExecute", func(args) { h.ConnectionExecute(...) })`
- All endpoints are registered as `0:function:DbeeXxx` specs (Neovim remote plugin protocol)

**Go Handler (`dbee/handler/handler.go`):**
- Purpose: Connection and call lifecycle management. In-memory lookups for connections and calls. Fires events.
- Location: `dbee/handler/handler.go`
- Contains: `lookupConnection`, `lookupCall`, `lookupConnectionCall` maps; call log persistence (`/tmp/dbee-calllog.json`)
- Depends on: `dbee/core/`, `dbee/adapters/`

**Go Core (`dbee/core/`):**
- Purpose: Database-agnostic abstractions for connections, queries, results
- Location: `dbee/core/`
- Key types:
  - `Connection` (`connection.go`): Wraps Adapter+Driver, executes queries, returns Calls
  - `Call` (`call.go`): Represents a single query execution with state machine (unknown -> executing -> retrieving -> archived | *_failed | canceled)
  - `Result` (`result.go`): Thread-safe cache that drains a `ResultStream` iterator into rows
  - `ResultStream` interface (`types.go`): Iterator over query results (Header, Next, HasNext, Close)
  - `Adapter` interface (`connection.go`): `Connect(url) -> Driver`, `GetHelpers(opts)`
  - `Driver` interface (`connection.go`): `Query(ctx, query) -> ResultStream`, `Structure()`, `Columns()`, `Close()`
  - Optional interfaces: `BindDriver` (parameterized queries), `DatabaseSwitcher` (database switching)
- Subpackages:
  - `dbee/core/builders/`: Convenience constructors for ResultStream implementations
  - `dbee/core/format/`: JSON and CSV formatters
  - `dbee/core/mock/`: Test doubles for Adapter and ResultStream

**Go Adapters (`dbee/adapters/`):**
- Purpose: Database-specific driver implementations
- Location: `dbee/adapters/`
- Pattern: Each database has `{name}.go` (init registration) + `{name}_driver.go` (Driver implementation)
- Supported: postgres, mysql, sqlite, sqlserver, oracle, bigquery, clickhouse, databricks, duck, mongo, redis, redshift
- Registration: `init()` functions call `register(adapter, aliases...)` to add to global `registeredAdapters` map
- Oracle has extended support: `oracle_plsql.go`, `oracle_refcursor.go`, `oracle_driver.go` (DBMS_OUTPUT, ref cursors, PL/SQL detection)

**LSP (`lua/dbee/lsp/`):**
- Purpose: SQL autocompletion via embedded LSP server
- Location: `lua/dbee/lsp/init.lua`, `lua/dbee/lsp/server.lua`, `lua/dbee/lsp/schema_cache.lua`
- Strategy: 3-tier cache population (1. disk cache for instant start, 2. async structure_loaded event, 3. fallback metadata SQL query after 5s)
- Provides: Table/column name completion for SQL buffers

## Data Flow

**Query Execution (single statement):**

1. User triggers `run_under_cursor` action in EditorUI (`lua/dbee/ui/editor/init.lua`)
2. EditorUI extracts query text, optionally resolves variables (`lua/dbee/variables.lua`)
3. EditorUI calls `handler:connection_execute(conn_id, query, opts)` -> `vim.fn.DbeeConnectionExecute()` (RPC to Go)
4. Go `handler.ConnectionExecute()` (`dbee/handler/handler.go`) calls `connection.ExecuteWithOptions()` (`dbee/core/connection.go`)
5. `Connection.ExecuteWithOptions()` creates a `Call` via `newCallFromExecutor()` (`dbee/core/call.go`) which spawns two goroutines: executor and event processor
6. Executor goroutine calls `driver.Query(ctx, query)` -> gets `ResultStream` -> drains into `Result` -> archives to disk
7. At each state transition, event processor calls `onEvent` callback -> `handler.events.CallStateChanged(call)` -> `eb.callLua("call_state_changed", data)` -> Neovim `ExecLua`
8. Lua event bus (`lua/dbee/handler/__events.lua`) receives event, dispatches via `vim.schedule` to all listeners
9. ResultUI listener (`on_call_state_changed`) updates display: spinner during executing/retrieving, paginated results on archived, error message on failure
10. EditorUI listener (`on_call_state_changed`) updates note-call associations and sets Oracle error diagnostics

**Script Execution:**

1. `dbee.execute_script()` (`lua/dbee.lua`) splits script via `query_splitter.split()` (`lua/dbee/query_splitter.lua`)
2. Executes statements sequentially, each through the same query execution flow
3. Uses `wait_for_call_terminal_state()` (polling via `vim.wait`) between statements
4. Supports cancellation via `active_script_run.canceled` flag checked between statements

**State Management:**
- Go side: Connection/Call state in `handler.Handler` maps (in-memory), call log persisted to `/tmp/dbee-calllog.json`
- Lua side: Current connection tracked in Go handler, current note in EditorUI, note-call associations in EditorUI, last-active note persisted to `~/.local/state/nvim/dbee/last_note.json`
- Notes stored as `.sql` files on disk at `~/.local/state/nvim/dbee/notes/{namespace}/{name}.sql`
- LSP schema cache persisted to disk for instant startup

## Key Abstractions

**Source:**
- Purpose: Provider of database connections (pluggable)
- Examples: `lua/dbee/sources.lua` -- `FileSource` (JSON file), `EnvSource` (env var), `MemorySource` (Lua table)
- Pattern: Interface with `name()` and `load()` required, `create/update/delete/file` optional
- Connection specs flow: Source.load() -> vim.fn.DbeeCreateConnection() -> Go handler stores Connection

**Adapter/Driver:**
- Purpose: Database-specific implementations behind a common interface
- Examples: `dbee/adapters/postgres_driver.go`, `dbee/adapters/oracle_driver.go`
- Pattern: Adapter creates Driver from URL. Driver executes queries and returns ResultStream. Adapters self-register via `init()`.

**Call State Machine:**
- Purpose: Tracks lifecycle of a single query execution
- States: `unknown` -> `executing` -> `retrieving` -> `archived` (happy path); `executing_failed`, `retrieving_failed`, `archive_failed`, `canceled` (error paths)
- Defined in: `dbee/core/call_state.go`
- Error classification: `dbee/core/call_error_kind.go` classifies errors as `timeout`, `disconnected`, `canceled`, `unknown`

**ResultStream -> Result -> Archive:**
- Purpose: Pipeline from live database cursor to cached, formatted output
- `ResultStream` (interface, `dbee/core/types.go`): Iterator returned by Driver.Query()
- `Result` (`dbee/core/result.go`): Thread-safe in-memory cache, drains ResultStream
- Archive (`dbee/core/call_archive.go`): Persists Result to temp file for re-display after GC

## Entry Points

**User Commands (`plugin/dbee.lua`):**
- Location: `plugin/dbee.lua`
- Triggers: `:Dbee` command with subcommands (open, close, toggle, execute, execute_script, cancel_script, compile_object, store, actions)
- Responsibilities: Parses args, dispatches to `lua/dbee.lua` functions

**Lua Plugin API (`lua/dbee.lua`):**
- Location: `lua/dbee.lua`
- Triggers: User config `require("dbee").setup(cfg)`, keymaps, commands
- Responsibilities: Public API surface. All user-facing operations.

**Go Process (`dbee/main.go`):**
- Location: `dbee/main.go`
- Triggers: Spawned by Neovim via remote plugin registration (`lua/dbee/api/__register.lua`)
- Responsibilities: RPC server, hosts all Go-side logic

**Go Manifest (`dbee/main.go --manifest`):**
- Location: `dbee/main.go`
- Triggers: `ci/build.sh` during release
- Responsibilities: Generates `lua/dbee/install/__manifest.lua` mapping function names to RPC specs

## Error Handling

**Strategy:** Defensive with pcall/xpcall on Lua side, explicit error returns on Go side. Events dispatched via vim.schedule with pcall wrappers.

**Patterns:**
- Go endpoints return `(result, error)` tuples, logged by `plugin.logReturn()`
- Lua handler wraps all `vim.fn.Dbee*` calls; some use pcall for graceful degradation (e.g., `call_cancel` retries after RPC channel re-registration)
- Event listeners wrapped in pcall -- one failing listener does not block others (`lua/dbee/handler/__events.lua` line 23-28)
- Call errors classified into `error_kind` (timeout/disconnected/canceled/unknown) for user-facing messages
- Oracle errors parsed for line/column location and displayed as vim diagnostics (`lua/dbee/ui/editor/init.lua`)

## Cross-Cutting Concerns

**Logging:**
- Go: `plugin.Logger` wraps Neovim's `vim.api.nvim_echo` for info/error messages (`dbee/plugin/logger.go`)
- Lua: `utils.log(level, msg, module)` (`lua/dbee/utils.lua`)
- All endpoint calls logged with method name and success/failure

**Validation:**
- Config validated in `lua/dbee/config.lua` via `vim.validate`
- Go endpoint args validated via msgpack struct tags and explicit nil checks

**Authentication:**
- Connection URLs contain credentials (user responsibility)
- No auth layer in the plugin itself -- delegated to database drivers

**Event System:**
- Go -> Lua: `dbee/handler/event_bus.go` fires events via `ExecLua` with Lua table literal payloads
- Lua -> Lua: `lua/dbee/handler/__events.lua` dispatches to registered listeners
- Editor has its own event system for note lifecycle events
- All events scheduled via `vim.schedule` to run on main thread

---

*Architecture analysis: 2026-03-05*
