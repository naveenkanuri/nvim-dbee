# External Integrations

**Analysis Date:** 2026-03-05

## APIs & External Services

This plugin does not call external HTTP APIs directly. All external communication happens through database drivers that the user configures with connection URLs. The Go backend binary is a child process of Neovim, communicating exclusively via msgpack-rpc over stdin/stdout.

## Database Adapters

Each adapter registers itself via `init()` in its source file with one or more type aliases. The adapter mux lives at `dbee/adapters/adapters.go`. Adapters implement the `core.Adapter` interface (`dbee/core/connection.go`) which provides `Connect(url)` and `GetHelpers(opts)`.

**SQL-based (via `database/sql`):**

| Type Aliases | Driver Package | Adapter File | Driver File | Optional Interfaces |
|---|---|---|---|---|
| `postgres`, `postgresql`, `pg` | `github.com/lib/pq` | `dbee/adapters/postgres.go` | `dbee/adapters/postgres_driver.go` | `DatabaseSwitcher` |
| `oracle` | `github.com/sijms/go-ora/v2` | `dbee/adapters/oracle.go` | `dbee/adapters/oracle_driver.go` | `BindDriver` (PL/SQL, refcursor, DBMS_OUTPUT) |
| `mysql` | `github.com/go-sql-driver/mysql` | `dbee/adapters/mysql.go` | `dbee/adapters/mysql_driver.go` | `DatabaseSwitcher` |
| `sqlserver`, `mssql` | `github.com/microsoft/go-mssqldb` | `dbee/adapters/sqlserver.go` | `dbee/adapters/sqlserver_driver.go` | `DatabaseSwitcher` |
| `sqlite`, `sqlite3` | `modernc.org/sqlite` | `dbee/adapters/sqlite.go` | `dbee/adapters/sqlite_driver.go` | - |
| `duck`, `duckdb` | `github.com/marcboeker/go-duckdb` | `dbee/adapters/duck.go` | `dbee/adapters/duck_driver.go` | - |
| `redshift` | `github.com/lib/pq` (reuses postgres) | `dbee/adapters/redshift.go` | `dbee/adapters/redshift_driver.go` | - |
| `clickhouse` | `github.com/ClickHouse/clickhouse-go/v2` | `dbee/adapters/clickhouse.go` | `dbee/adapters/clickhouse_driver.go` | `DatabaseSwitcher` |
| `databricks` | `github.com/databricks/databricks-sql-go` | `dbee/adapters/databricks.go` | `dbee/adapters/databricks_driver.go` | - |
| `bigquery` | `cloud.google.com/go/bigquery` | `dbee/adapters/bigquery.go` | `dbee/adapters/bigquery_driver.go` | `DatabaseSwitcher` |

**Non-SQL:**

| Type Aliases | Driver Package | Adapter File | Driver File | Notes |
|---|---|---|---|---|
| `mongo`, `mongodb` | `go.mongodb.org/mongo-driver` | `dbee/adapters/mongo.go` | `dbee/adapters/mongo_driver.go` | JSON-style queries (e.g., `{"find": "collection"}`) |
| `redis` | `github.com/redis/go-redis/v9` | `dbee/adapters/redis.go` | `dbee/adapters/redis_driver.go` | Redis commands as queries |

**Driver Interface:**
All drivers implement `core.Driver` (`dbee/core/connection.go`):
```go
type Driver interface {
    Query(ctx context.Context, query string) (ResultStream, error)
    Structure() ([]*Structure, error)
    Columns(opts *TableOptions) ([]*Column, error)
    Close()
}
```

**Optional interfaces:**
- `core.BindDriver` - Parameterized queries with named bind values (Oracle implements this)
- `core.DatabaseSwitcher` - Switch between databases (Postgres, MySQL, SQL Server, ClickHouse, BigQuery)

**Adding a new adapter:**
1. Create `dbee/adapters/{name}.go` implementing `core.Adapter`
2. Create `dbee/adapters/{name}_driver.go` implementing `core.Driver`
3. Register via `init()` function calling `register(&YourAdapter{}, "alias1", "alias2")`
4. Add integration test at `dbee/tests/integration/{name}_integration_test.go`
5. Add testcontainer helper at `dbee/tests/testhelpers/{name}.go`

## Data Storage

**Connection Persistence:**
- JSON file at `vim.fn.stdpath("state") .. "/dbee/persistence.json"` (default)
- Managed by `FileSource` in `lua/dbee/sources.lua`
- Format: JSON array of `ConnectionParams` objects `[{"id":"...","name":"...","url":"...","type":"..."}]`

**Call Log:**
- JSON file at `/tmp/dbee-calllog.json` (hardcoded in `dbee/handler/handler.go:20`)
- Persists query history across sessions (call ID, query text, state, timing)

**LSP Schema Cache:**
- Disk cache managed by `lua/dbee/lsp/schema_cache.lua`
- Stored at `vim.fn.stdpath("data") .. "/dbee/lsp/"`
- Per-connection cache for table/column metadata; enables instant LSP startup

**Result Archiving:**
- Query results archived to local gob-encoded files for later retrieval
- Managed by `dbee/core/call_archive.go`

**File Storage:**
- Local filesystem only; no cloud storage integration
- Editor scratchpads stored in configurable directory (`editor.directory` in config)

**Caching:**
- No external cache service
- In-memory caching of connections, calls, and results in the Go handler (`dbee/handler/handler.go`)
- Lua-side schema cache with disk persistence for LSP (`lua/dbee/lsp/schema_cache.lua`)

## Authentication & Identity

**Auth Provider:**
- No application-level authentication
- Database authentication is handled entirely by connection URLs (each driver parses credentials from the URL)
- BigQuery uses Google Cloud Application Default Credentials or service account keys via the BigQuery SDK

## Neovim IPC (msgpack-rpc)

**Communication Protocol:**
- Go binary (`dbee/main.go`) connects to Neovim via `nvim.New(os.Stdin, stdout, stdout, log.Printf)`
- Functions registered via `plugin.RegisterEndpoint()` in `dbee/plugin/plugin.go`
- Lua calls Go functions via `vim.fn.DbeeXxx()` (generated manifest at `lua/dbee/install/__manifest.lua`)

**Event System (Go to Lua):**
- Go handler fires Lua events via `eb.vim.ExecLua()` in `dbee/handler/event_bus.go`
- Lua event bus at `lua/dbee/handler/__events.lua`
- Events: `call_state_changed`, `current_connection_changed`, `database_selected`, `structure_loaded`

**Registered RPC Endpoints (`dbee/endpoints.go`):**
| Endpoint | Purpose |
|---|---|
| `DbeeCreateConnection` | Create and register a new database connection |
| `DbeeDeleteConnection` | Remove a connection |
| `DbeeGetConnections` | List connections (optionally filtered by IDs) |
| `DbeeAddHelpers` | Register custom helper queries for a connection type |
| `DbeeConnectionGetHelpers` | Get helper queries for a table |
| `DbeeSetCurrentConnection` | Set the active connection |
| `DbeeGetCurrentConnection` | Get the currently active connection |
| `DbeeConnectionExecute` | Execute a query on a connection |
| `DbeeConnectionGetCalls` | Get query call history for a connection |
| `DbeeConnectionGetParams` | Get connection parameters |
| `DbeeConnectionGetStructure` | Get database structure (schemas/tables/views) synchronously |
| `DbeeConnectionGetStructureAsync` | Get database structure asynchronously (fires `structure_loaded` event) |
| `DbeeConnectionGetColumns` | Get column info for a specific table |
| `DbeeConnectionListDatabases` | List available databases |
| `DbeeConnectionSelectDatabase` | Switch to a different database |
| `DbeeCallCancel` | Cancel a running query |
| `DbeeCallDisplayResult` | Render results into a Neovim buffer |
| `DbeeCallStoreResult` | Export results to file/buffer/yank register (JSON, CSV, or table format) |

## In-Process LSP Server

**Implementation:** `lua/dbee/lsp/server.lua`
- Runs as an in-process Neovim LSP client (no external process)
- Provides SQL completion (tables, columns, schemas, keywords, aliases) and diagnostics (unknown table warnings)
- Triggered by `.` and space characters
- Uses `SchemaCache` (`lua/dbee/lsp/schema_cache.lua`) populated from database structure data

**Metadata Queries (`lua/dbee/lsp/init.lua`):**
- Per-database-type SQL queries to fetch schema/table metadata for LSP completion
- Supported: oracle, postgres (+ aliases pg, postgresql), mysql, sqlite (+ sqlite3), sqlserver (+ mssql)
- Fallback mechanism: disk cache -> async structure load -> metadata SQL query (5s timeout)

## Monitoring & Observability

**Error Tracking:**
- No external error tracking service
- Errors logged via `plugin.Logger` to Neovim's message area (`vim.notify`)
- Error classification system in `dbee/core/call_error_kind.go` (timeout, disconnected, canceled, unknown)

**Logs:**
- Go side: `log.Printf` via Neovim's stderr (redirected: `os.Stdout = os.Stderr` in `dbee/main.go`)
- Lua side: `utils.log()` wrapper around `vim.notify()` with severity levels
- Plugin logging: `dbee/plugin/logger.go` writes to Neovim via `nvim.WritelnErr()`

## CI/CD & Deployment

**Hosting:**
- GitHub repository: `github.com/kndndrj/nvim-dbee`
- Pre-built binaries uploaded to GitHub Releases

**CI Pipeline (GitHub Actions):**

| Workflow | File | Triggers | Purpose |
|---|---|---|---|
| Compile and Upload | `.github/workflows/compile.yml` | push/PR to master, release | Cross-compile Go binary for all platforms, upload to release |
| Testing | `.github/workflows/test.yml` | push/PR to master | Go unit tests, Lua headless regression tests, Go integration tests (testcontainers) |
| Linting | `.github/workflows/lint.yml` | push/PR to master | Luacheck, StyLua, mdformat |
| Docgen | `.github/workflows/docgen.yml` | push/PR to master | Generate vimdoc documentation |

**Release Process:**
1. Create GitHub release (tag)
2. `compile.yml` builds binaries for all platforms in `ci/targets.json`
3. Binaries uploaded as release assets (tar.gz archives)
4. Install manifest generated at `lua/dbee/install/__manifest.lua` with download URLs per platform
5. Manifest committed back to the branch and tag moved

## Environment Configuration

**Required env vars (for users):**
- None required for basic operation
- `DBEE_CONNECTIONS` - Optional: JSON array of connection definitions for `EnvSource`

**CI env vars:**
- `GO_VERSION` - Go version for CI (set to `1.23.x`)
- `TESTCONTAINERS_RYUK_DISABLED` - Disable Ryuk reaper in integration tests
- `GITHUB_TOKEN` - For StyLua action and release uploads

## Webhooks & Callbacks

**Incoming:**
- None (this is a Neovim plugin, not a web service)

**Outgoing:**
- None (all communication is local: Neovim <-> Go binary via stdin/stdout, Go binary <-> databases via driver connections)

---

*Integration audit: 2026-03-05*
