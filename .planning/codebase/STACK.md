# Technology Stack

**Analysis Date:** 2026-03-05

## Languages

**Primary:**
- Go 1.23 (toolchain go1.23.4) - Backend binary (`dbee/`): database adapters, connection management, query execution, result streaming, RPC handler
- Lua (Neovim Lua 5.1/LuaJIT) - Frontend plugin (`lua/`): UI management, config, LSP server, query splitting, event handling

**Secondary:**
- Shell (sh/bash) - CI scripts (`ci/build.sh`, `ci/publish.sh`, `ci/target-matrix.sh`)
- YAML - GitHub Actions workflows (`.github/workflows/`)

## Runtime

**Environment:**
- Neovim >= 0.11.x (CI tests against v0.11.6)
- Go 1.23.x for building the backend binary
- The Go binary runs as a Neovim child process communicating via msgpack-rpc over stdin/stdout

**Package Manager:**
- Go modules (`dbee/go.mod`, `dbee/go.sum`)
- Lockfile: `dbee/go.sum` present
- No separate Lua package manager; Lua code is loaded via Neovim's runtime path (`rtp`)

## Frameworks

**Core:**
- `github.com/neovim/go-client` v1.2.1 - Neovim msgpack-rpc client for Go; the Go binary registers functions that Lua calls via `vim.fn`
- Neovim Lua API (`vim.api`, `vim.lsp`, `vim.loop`) - All UI rendering, buffer management, keymaps, and in-process LSP

**Testing:**
- `github.com/stretchr/testify` v1.10.0 - Go unit test assertions
- `github.com/testcontainers/testcontainers-go` v0.35.0 - Integration tests via Docker containers for each database adapter
- `github.com/DATA-DOG/go-sqlmock` v1.5.2 - SQL mock for unit tests
- Neovim headless mode (`nvim --headless`) - Lua regression tests in CI

**Build/Dev:**
- `ci/build.sh` - Shell script wrapping `go build` with cross-compilation support
- Zig (`goto-bus-stop/setup-zig@v2`) - C cross-compiler for CGO-enabled builds on non-native platforms
- StyLua v0.17 - Lua formatter (config: `.stylua.toml`)
- Luacheck - Lua linter (config: `.luacheckrc`)
- mdformat-gfm - Markdown linter for `README.md` and `ARCHITECTURE.md`

## Key Dependencies

**Critical (database drivers):**
- `github.com/lib/pq` v1.10.9 - PostgreSQL driver (aliases: `postgres`, `postgresql`, `pg`)
- `github.com/sijms/go-ora/v2` v2.7.6 - Oracle driver (alias: `oracle`)
- `github.com/go-sql-driver/mysql` v1.7.1 - MySQL driver (alias: `mysql`)
- `github.com/microsoft/go-mssqldb` v1.7.0 - SQL Server driver (aliases: `sqlserver`, `mssql`)
- `github.com/marcboeker/go-duckdb` v1.7.0 - DuckDB driver (alias: `duck`)
- `modernc.org/sqlite` v1.21.2 - SQLite driver (alias: `sqlite`, `sqlite3`)
- `go.mongodb.org/mongo-driver` v1.11.6 - MongoDB driver (aliases: `mongo`, `mongodb`)
- `github.com/redis/go-redis/v9` v9.0.2 - Redis driver (alias: `redis`)
- `cloud.google.com/go/bigquery` v1.61.0 - BigQuery driver (alias: `bigquery`)
- `github.com/ClickHouse/clickhouse-go/v2` v2.20.0 - ClickHouse driver (alias: `clickhouse`)
- `github.com/databricks/databricks-sql-go` v1.5.3 - Databricks driver (alias: `databricks`)

**Infrastructure:**
- `github.com/google/uuid` v1.6.0 - Connection and call ID generation
- `github.com/jedib0t/go-pretty/v6` v6.5.8 - Table formatting for result display in Neovim buffers
- `golang.org/x/sync` v0.10.0 - Concurrency primitives (errgroup, singleflight)
- `github.com/docker/docker` v27.1.1 - Docker client for testcontainers integration tests

## Configuration

**Environment:**
- `DBEE_CONNECTIONS` - JSON-encoded connection definitions loaded by `EnvSource` (`lua/dbee/sources.lua`)
- Connection persistence file: `vim.fn.stdpath("state") .. "/dbee/persistence.json"` (managed by `FileSource`)
- No `.env` files detected in the repository

**Plugin Configuration:**
- Lua config object defined in `lua/dbee/config.lua`; merged via `vim.tbl_deep_extend("force", default, user_config)`
- Key settings: `sources`, `extra_helpers`, `drawer`, `editor`, `result`, `call_log`, `window_layout`

**Build:**
- `.stylua.toml` - StyLua formatter config (120 col, 2-space indent, Unix line endings)
- `.luacheckrc` - Luacheck config (ignores 122/631, global `vim`)
- `ci/targets.json` - Cross-compilation target matrix (6 primary platforms, ~20 total)

## Platform Requirements

**Development:**
- Go 1.23+ with module support
- Neovim >= 0.11.x (for headless tests and LSP API)
- CGO enabled for DuckDB on macOS/Windows; optional on Linux (can build from source with `duckdb_from_source` tag)
- Docker for running integration tests (testcontainers)

**Production (user installation):**
- Neovim >= 0.9 (plugin runtime; 0.11+ recommended for LSP features)
- Pre-built binary downloaded from GitHub releases via `curl`/`wget`, or built locally with `go build`
- Binary installed to `vim.fn.stdpath("data") .. "/dbee/bin/dbee"`
- Install methods (priority order): wget, curl, bitsadmin (Windows), go, cgo

**Supported Platforms (1st class):**
- darwin/amd64, darwin/arm64 (CGO enabled)
- linux/amd64, linux/arm64 (Zig cross-compilation)
- windows/amd64, windows/arm64 (CGO enabled)

---

*Stack analysis: 2026-03-05*
