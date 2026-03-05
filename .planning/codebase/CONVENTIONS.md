# Coding Conventions

**Analysis Date:** 2026-03-05

## Languages

This is a dual-language codebase:
- **Lua** (Neovim plugin frontend): `lua/dbee/`
- **Go** (backend binary): `dbee/`

Each language follows its own conventions documented below.

---

## Lua Conventions

### Naming Patterns

**Files:**
- Use `snake_case.lua` for all file names
- Use `init.lua` for directory modules (e.g., `lua/dbee/ui/editor/init.lua`)
- Prefix headless test scripts with `check_` (e.g., `ci/headless/check_query_splitter.lua`)

**Functions:**
- Use `snake_case` for all functions: `query_under_cursor()`, `resolve_note_from_file()`
- Private methods use `snake_case` with `---@private` annotation
- Module-level local helpers use `snake_case`: `local function strip_leading_sql_comments(query)`

**Variables:**
- Use `snake_case` for locals and fields: `cursor_row`, `block_start`, `note_id`
- Constants use `UPPER_SNAKE_CASE`: `PL_SQL_START_PATTERNS`, `SQL_INCOMPLETE_CLAUSE_ENDINGS`, `METADATA_QUERIES`
- Boolean fields prefixed with `is_` or `_` for internal state: `_confirm_pending`, `in_single`

**Types / Classes:**
- Use `PascalCase` for class names: `EditorUI`, `Handler`, `DbeeLsp`, `SchemaCache`
- Use `snake_case` for type aliases: `note_id`, `namespace_id`, `editor_event_name`

### Code Style

**Formatting:**
- StyLua enforced in CI (config: `.stylua.toml`)
- 120 column width
- 2-space indentation (spaces, not tabs)
- Unix line endings
- `AutoPreferDouble` quote style
- `NoSingleTable` call parentheses (omit parens when single table arg)

**Linting:**
- Luacheck enforced in CI (config: `.luacheckrc`)
- `vim` is a read global
- Error code 631 (line too long) is suppressed
- Error code 122 (indirectly setting readonly global) is suppressed
- Unused argument warning disabled for `self`

### Type Annotations

Use LuaLS `---@` annotations extensively:

```lua
---@class EditorUI
---@field private handler Handler
---@field private winid? integer
---@field private notes table<namespace_id, table<note_id, note_details>>

---@param handler Handler
---@param result ResultUI
---@param opts? editor_config
---@return EditorUI
function EditorUI:new(handler, result, opts)
```

**Rules:**
- Annotate all public function parameters and returns with `---@param` / `---@return`
- Mark private methods with `---@private`
- Use `?` suffix for optional types: `integer?`, `string?`
- Use `---@alias` for domain-specific type names

### Module Pattern

**Standard module pattern** (non-class):
```lua
local M = {}

function M.some_function(arg)
  -- ...
end

return M
```

**Class pattern** (OOP via metatables):
```lua
local MyClass = {}

function MyClass:new(opts)
  local o = { ... }
  setmetatable(o, self)
  self.__index = self
  return o
end

function MyClass:method()
  -- ...
end

return MyClass
```

### Import Organization

**Order:**
1. Local `require()` calls for project modules
2. No external dependencies (plugin uses only Neovim stdlib + optional snacks.nvim)

**Path convention:** Dot-separated module paths matching directory structure:
```lua
local utils = require("dbee.utils")
local common = require("dbee.ui.common")
local EditorUI = require("dbee.ui.editor")
```

### Error Handling (Lua)

**Patterns:**
- Use `pcall()` for calls that may fail, check `ok` return:
  ```lua
  local ok, result = pcall(self.handler.connection_get_calls, self.handler, conn_id)
  if not ok or not result then
    return
  end
  ```
- Use `error()` for programmer errors (invalid arguments, missing required params)
- Use `vim.notify(msg, vim.log.levels.WARN)` for user-facing errors
- Never let an error propagate to the user as an unhandled Lua traceback

**Defensive patterns:**
- Always guard `vim.api.nvim_win_is_valid(winid)` before window operations
- Always guard `vim.api.nvim_buf_is_valid(bufnr)` before buffer operations
- Use `type(x) == "function"` checks before calling optional interfaces

### Logging (Lua)

**Framework:** `vim.notify` for user-facing messages, `utils.log()` for structured internal logs.

**Patterns:**
```lua
-- User-facing notifications
vim.notify("No SQL statement to execute at cursor", vim.log.levels.WARN)
vim.notify("Reconnected " .. conn.name, vim.log.levels.INFO)

-- Internal errors (handler)
utils.log("error", "failed registering source: " .. source:name() .. " " .. mes, "core")
```

### Comments (Lua)

**When to comment:**
- Document the "why" for non-obvious decisions (see detailed comments in `lua/dbee/ui/editor/init.lua`)
- Use block comments above complex code sections explaining intent
- Single-line `--` comments for brief clarifications

**LuaDoc:**
- Every public function gets `---@param` and `---@return` annotations
- Class fields documented with `---@field` in the class declaration

---

## Go Conventions

### Naming Patterns

**Files:**
- Use `snake_case.go` for all file names
- Test files: `*_test.go` co-located with source (e.g., `call_error_kind_test.go`)
- Prefix test files matching the entity they test

**Functions/Methods:**
- Exported: `PascalCase` (`NewConnection`, `GetResult`, `ClassifyCallError`)
- Unexported: `camelCase` (`classifyCallError`, `hasErrorPattern`)

**Variables:**
- Unexported package-level constants: `camelCase` (`callErrorKindUnknown`, `oracleDefaultQueryTimeout`)
- Exported constants: `PascalCase` (`CallStateExecuting`)
- Local variables: `camelCase`

**Types:**
- Exported structs: `PascalCase` (`Connection`, `Call`, `Result`)
- Unexported structs: `camelCase` (`oracleDriver`, `adapterConfig`)
- Interfaces verified with compile-time assertion: `var _ core.Driver = (*oracleDriver)(nil)`

### Import Organization

**Order (standard Go convention):**
1. Standard library imports
2. Third-party imports
3. Internal project imports

```go
import (
    "context"
    "database/sql"
    "fmt"

    "github.com/stretchr/testify/require"

    "github.com/kndndrj/nvim-dbee/dbee/core"
    "github.com/kndndrj/nvim-dbee/dbee/core/builders"
)
```

**Import aliases (integration tests):**
```go
th "github.com/kndndrj/nvim-dbee/dbee/tests/testhelpers"
tsuite "github.com/stretchr/testify/suite"
tc "github.com/testcontainers/testcontainers-go"
sqlmock "github.com/DATA-DOG/go-sqlmock"
```

### Error Handling (Go)

**Patterns:**
- Return `error` as last return value from functions
- Use `fmt.Errorf("context: %w", err)` for wrapping
- Use `errors.Is()` for sentinel error checks (e.g., `errors.Is(err, context.Canceled)`)
- Use string pattern matching for driver-specific error classification (`strings.Contains`)

**Error classification pattern** (see `dbee/core/call_error_kind.go`):
```go
func classifyCallError(err error) string {
    if errors.Is(err, context.Canceled) {
        return callErrorKindCanceled
    }
    msg := strings.ToLower(err.Error())
    if hasErrorPattern(msg, timeoutErrorPatterns) {
        return callErrorKindTimeout
    }
    return callErrorKindUnknown
}
```

### Concurrency

**Patterns used:**
- `sync.Mutex` for protecting shared state (e.g., `oracleDriver.mu`)
- `sync/atomic` for lock-free counters in tests
- Channels for signaling completion (`call.Done()`)
- `context.Context` for cancellation propagation
- `sync.WaitGroup` for goroutine coordination in tests

### Comments (Go)

**When to comment:**
- Exported types and functions get GoDoc-style comments
- Constants with non-obvious values get inline comments
- Complex concurrency logic gets block comments explaining invariants

```go
// oracleDefaultQueryTimeout is the fallback timeout when the caller's context
// has no deadline. go-ora's internal default (~30s) is too short for many
// queries; this provides a practical "no limit" that still gives go-ora a
// deadline to work with.
const oracleDefaultQueryTimeout = 24 * time.Hour
```

### Functional Options Pattern

Use the functional options pattern for configurable constructors (see `dbee/core/mock/`):

```go
type AdapterOption func(*adapterConfig)

func AdapterWithQuerySideEffect(query string, sideEffect func(context.Context) error) AdapterOption {
    return func(c *adapterConfig) {
        c.querySideEffects[query] = sideEffect
    }
}

func NewAdapter(data []core.Row, opts ...AdapterOption) *Adapter {
    config := &adapterConfig{...}
    for _, opt := range opts {
        opt(config)
    }
    return &Adapter{data: data, config: config}
}
```

### Interface Compliance

Verify interface implementation at compile time:
```go
var _ core.Driver = (*oracleDriver)(nil)
var _ core.BindDriver = (*oracleDriver)(nil)
var _ core.Adapter = (*Adapter)(nil)
```

---

## Cross-Language Conventions

### RPC Boundary

Go functions are exposed to Lua via Neovim's msgpack RPC. The naming convention at the boundary:
- Go: `DbeeCallCancel`, `DbeeDeleteConnection` (PascalCase with `Dbee` prefix)
- Lua: accessed via `vim.fn.DbeeCallCancel`

### Configuration

- Config objects use `---@class` annotations in Lua with optional fields marked `?`
- Default config is defined in `lua/dbee/config.lua` as `config.default`
- Users merge via `config.merge_with_default(cfg)` + `config.validate(merged)`

### Event System

- Go backend fires events via RPC callbacks
- Lua handler dispatches to registered listeners: `handler:register_event_listener(event, callback)`
- Event names use `snake_case`: `call_state_changed`, `structure_loaded`, `current_note_changed`

---

*Convention analysis: 2026-03-05*
