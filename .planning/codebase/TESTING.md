# Testing Patterns

**Analysis Date:** 2026-03-05

## Overview

The project has three test layers:
1. **Go unit tests** - Co-located `*_test.go` files for backend logic
2. **Go integration tests** - Testcontainer-based database adapter tests
3. **Lua headless regression tests** - Neovim headless scripts testing plugin logic

---

## Go Unit Tests

### Framework

**Runner:**
- Go standard `testing` package
- Go 1.23.x

**Assertion Library:**
- `github.com/stretchr/testify` v1.10.0
- Uses both `require` (fail-fast) and `assert` (continue on failure)

**Mocking:**
- `github.com/DATA-DOG/go-sqlmock` v1.5.2 for SQL driver mocking
- Custom mock package at `dbee/core/mock/` for domain objects

**Run Commands:**
```bash
cd dbee
go test $(go list ./... | grep -v tests) -v     # Run all unit tests
go test ./core/ -v -run TestCall_Cancel          # Run specific test
```

### Test File Organization

**Location:** Co-located with source files (standard Go convention)

**Naming:** `<source_file>_test.go` matching the entity under test

**Structure:**
```
dbee/
  core/
    call_error_kind.go
    call_error_kind_test.go       # Tests classifyCallError
    call_test.go                  # Tests Call lifecycle
    result_test.go                # Tests Result pagination
    connection_bind_test.go       # Tests bind-aware execution
    call_unmarshal_test.go        # Tests JSON marshaling
    call_getresult_test.go        # Tests GetResult state handling
    mock/
      adapter.go                  # Mock adapter implementation
      adapter_options.go          # Functional options for mock
      result.go                   # Mock result stream
      result_options.go           # Functional options for mock stream
  adapters/
    oracle_driver_context_test.go # Tests Oracle query context lifetime
    oracle_driver_session_test.go # Tests Oracle session management
    oracle_plsql_test.go          # Tests PL/SQL detection
    oracle_helpers_test.go        # Tests Oracle helper queries
    oracle_refcursor_test.go      # Tests REF CURSOR handling
    oracle_driver_dbms_output_test.go # Tests DBMS_OUTPUT capture
    bigquery_driver_test.go       # Tests BigQuery driver
    databricks_driver_test.go     # Tests Databricks driver
    duck_driver_test.go           # Tests DuckDB driver
    redis_test.go                 # Tests Redis driver
  core/builders/
    client_args_test.go           # Tests query builder with args
    next_test.go                  # Tests next-row iterator
  endpoints_test.go               # Tests RPC endpoint parsing
```

### Test Patterns

**Package choice:**
- Same package (`package core`) for testing unexported functions
- External test package (`package core_test`) for testing public API

**Table-driven tests with subtests:**
```go
func TestClassifyCallError(t *testing.T) {
    t.Parallel()

    tests := []struct {
        name string
        err  error
        want string
    }{
        {name: "nil", err: nil, want: ""},
        {name: "context canceled", err: context.Canceled, want: callErrorKindCanceled},
        {name: "unknown", err: errors.New("query failed"), want: callErrorKindUnknown},
    }

    for _, tt := range tests {
        tt := tt
        t.Run(tt.name, func(t *testing.T) {
            t.Parallel()
            got := classifyCallError(tt.err)
            require.Equal(t, tt.want, got)
        })
    }
}
```

**Assertion style:**
- Use `require.New(t)` shorthand (`r := require.New(t)`) in complex tests
- Use `require.Equal`, `require.NoError`, `require.ErrorContains` for fail-fast assertions
- Use `assert.Equal`, `assert.Contains` in integration tests where continuation is preferred

**Async / Concurrency testing:**
```go
// Wait for async call completion with timeout
select {
case <-call.Done():
case <-time.After(5 * time.Second):
    t.Error("call did not finish in expected time")
}

// Use Eventually for async state transitions
r.Eventually(func() bool {
    return eventIndex.Load() == int32(len(expectedEvents))
}, 2*time.Second, 10*time.Millisecond)
```

**Event ordering verification:**
```go
var eventIndex atomic.Int32
call := connection.Execute("_", func(state core.CallState, c *core.Call) {
    idx := int(eventIndex.Load())
    r.Less(idx, len(expectedEvents))
    r.Equal(expectedEvents[idx], state)
    eventIndex.Add(1)
})
```

### Mock Package (`dbee/core/mock/`)

**Purpose:** Reusable mock implementations of `core.Driver`, `core.Adapter`, and `core.ResultStream`.

**Key types:**
- `mock.NewAdapter(rows, ...opts)` - Creates mock adapter with functional options
- `mock.NewResultStream(rows, ...opts)` - Creates mock result stream
- `mock.NewRows(from, to)` - Generates test rows: `{index(int), "row_N"(string)}`

**Functional options for configuring mocks:**
```go
// Inject side effects for specific queries
mock.AdapterWithQuerySideEffect("wait", func(ctx context.Context) error {
    <-ctx.Done()
    return ctx.Err()
})

// Control stream timing
mock.AdapterWithResultStreamOpts(mock.ResultStreamWithNextSleep(300*time.Millisecond))

// Define table structures
mock.AdapterWithTableDefinition("users", []*core.Column{{Name: "id", Type: "NUMBER"}})
```

**Ad-hoc test doubles:**
When mock package doesn't fit, define struct inline in test file:
```go
type bindAwareDriver struct {
    queryCalls          int
    queryWithBindsCalls int
    lastBinds           map[string]string
}
```

### SQL Mock (`go-sqlmock`)

Used for testing SQL driver interactions without a real database:
```go
db, mock, err := sqlmock.New()
require.NoError(t, err)
defer db.Close()

mockRows := sqlmock.NewRows([]string{"value"}).AddRow("42")
mock.ExpectQuery(regexp.QuoteMeta("SELECT ?")).
    WithArgs("42").
    WillReturnRows(mockRows)

// ... execute code under test ...

require.NoError(t, mock.ExpectationsWereMet())
```

### Custom `database/sql/driver` implementations

For testing Oracle-specific behavior (context lifetime, bind args), test files register custom `database/sql/driver` implementations:
```go
type oracleQueryCtxDriver struct{}
func (oracleQueryCtxDriver) Open(string) (driver.Conn, error) { ... }

// Register once using sync.Once
oracleQueryCtxRegisterOnce.Do(func() {
    sql.Register(oracleQueryCtxDriverName, oracleQueryCtxDriver{})
})
```

---

## Go Integration Tests

### Framework

**Runner:** `github.com/stretchr/testify/suite`
**Containers:** `github.com/testcontainers/testcontainers-go` v0.35.0

**Run Commands:**
```bash
cd dbee
sudo go test ./tests/integration/postgres_integration_test.go -v
```

### Organization

**Location:** `dbee/tests/integration/`
**Naming:** `<adapter>_integration_test.go`
**Package:** `package integration`

**Supported adapters:**
- `postgres`, `mysql`, `sqlite`, `sqlserver`, `clickhouse`
- `bigquery`, `duckdb`, `redshift`, `oracle`

### Test Suite Pattern

```go
type PostgresTestSuite struct {
    tsuite.Suite
    ctr *th.PostgresContainer
    ctx context.Context
    d   *core.Connection
}

func TestPostgresTestSuite(t *testing.T) {
    tsuite.Run(t, new(PostgresTestSuite))
}

func (suite *PostgresTestSuite) SetupSuite() {
    suite.ctx = context.Background()
    ctr, err := th.NewPostgresContainer(suite.ctx, &core.ConnectionParams{...})
    // ...
}

func (suite *PostgresTestSuite) TeardownSuite() {
    tc.CleanupContainer(suite.T(), suite.ctr)
}
```

### Test Helpers (`dbee/tests/testhelpers/`)

**Purpose:** Shared helpers for container setup and result extraction.

**Key functions:**
- `th.GetResult(t, connection, query)` - Execute query and wait for archived result
- `th.GetResultWithCancel(t, connection, query)` - Execute and cancel immediately
- `th.GetSchemas(t, structure)` - Extract schema names from structure tree
- `th.GetModels(t, structure, modelType)` - Extract model names by type
- `th.GetTestDataPath()` / `th.GetTestDataFile(filename)` - Access `dbee/tests/testdata/`

**Container helpers per adapter:**
- `th.NewPostgresContainer(ctx, params)`, `th.NewMySQLContainer(ctx, params)`, etc.
- Each returns a container with pre-seeded test data and a `Driver` field

### Standard Integration Test Cases

Every adapter integration suite tests:
1. `TestShouldErrorInvalidQuery` - Invalid SQL returns error
2. `TestShouldCancelQuery` - Long-running query can be canceled
3. `TestShouldReturnManyRows` - Multi-row SELECT with correct columns and states
4. `TestShouldReturnSingleRows` - Single-row SELECT (often via view)
5. `TestShouldReturnStructure` - Database structure (schemas, tables, views)
6. `TestShouldReturnColumns` - Column metadata for a table
7. `TestShouldSwitchDatabase` - Database switching (where supported)

### CI Configuration

Integration tests run in GitHub Actions (`.github/workflows/test.yml`):
- Auto-discovers adapters from `tests/integration/*_integration_test.go`
- Runs each adapter as a separate matrix job with 10-minute timeout
- Uses `TESTCONTAINERS_RYUK_DISABLED=true`

---

## Lua Headless Regression Tests

### Framework

**Runner:** Neovim headless mode (no UI, no vimrc)
**Location:** `ci/headless/`
**Naming:** `check_<feature>.lua`

**Run command:**
```bash
nvim --headless -u NONE -i NONE -n \
  --cmd "set rtp+=/path/to/nvim-dbee" \
  -c "luafile ci/headless/check_query_splitter.lua"
```

### Test Structure

Each script is self-contained with its own assertion helpers:

```lua
local function assert_eq(actual, expected, name)
  if actual ~= expected then
    print("PREFIX_ASSERT_FAIL=" .. name .. ":" .. tostring(actual) .. "!=" .. tostring(expected))
    vim.cmd("cquit 1")
    return false
  end
  return true
end

-- ... test code ...

print("PREFIX_ALL_PASS=true")
vim.cmd("qa!")
```

**Conventions:**
- Each script prints diagnostic `KEY=VALUE` lines for CI parsing
- Exit with `cquit 1` on failure (non-zero exit code)
- Exit with `qa!` on success
- Every assertion short-circuits on failure with `return`
- Use unique print prefixes per test script (e.g., `SPLITTER_`, `CALL_CANCEL_RETRY_`)

### Test Doubles in Headless Tests

Headless tests create fake objects to simulate the plugin environment:

```lua
-- Fake handler with controlled behavior
local handler = {
  register_event_listener = function(_, event, cb) ... end,
  get_current_connection = function() return { id = "conn_test", type = "generic" } end,
  connection_execute = function(_, _, query, opts) ... end,
  connection_get_calls = function(_, _) ... end,
  call_cancel = function(_, id) ... end,
}

-- Fake result
local result = {
  set_call = function() end,
  clear = function() end,
  restore_call = function() end,
}

-- Override vim.ui.select for prompt testing
vim.ui.select = function(_, opts, on_choice)
  select_was_called = true
  select_callback = on_choice
  return { close = function() picker_close_called = true end }
end
```

### Headless Test Scripts

| Script | Tests |
|--------|-------|
| `check_query_splitter.lua` | Oracle PL/SQL splitting, generic splitting, comments, quotes |
| `check_query_under_cursor.lua` | Tree-sitter statement detection, fallback mode |
| `check_variables.lua` | Bind/substitution variable scanning |
| `check_editor_variables.lua` | Variable resolution in editor context |
| `check_execute_script.lua` | Sequential script execution |
| `check_editor_error_jump.lua` | Oracle error location parsing and cursor jump |
| `check_call_cancel_retry.lua` | Stale RPC channel retry logic |
| `check_editor_call_routing.lua` | Note-to-call routing and result restoration |
| `check_events_dispatch_resilience.lua` | Event listener error isolation |
| `check_actions_entrypoints.lua` | Actions palette dispatch |
| `check_actions_recovery.lua` | Disconnected call recovery |
| `check_result_progress_hints.lua` | Progress spinner slow/stuck hints |
| `check_result_restore_elapsed.lua` | Elapsed time restoration |
| `check_result_error_kinds.lua` | Error kind propagation to UI |
| `check_lsp_alias_completion.lua` | LSP table alias completion |
| `check_lsp_schema_alias_completion.lua` | LSP schema-qualified alias completion |
| `check_lsp_alias_rebinding.lua` | LSP alias rebinding on connection change |
| `check_run_note_queries_opts.lua` | Note query execution options |
| `check_cancel_confirm_prompt.lua` | Cancel-confirm prompt: 14 scenario test |

### CI Configuration

Headless tests run in GitHub Actions (`.github/workflows/test.yml`):
- Each script is a separate matrix entry (fail-fast disabled)
- Installs Neovim v0.11.6 binary
- Sets runtime path to repo root: `--cmd "set rtp+=${GITHUB_WORKSPACE}"`

---

## Coverage

**Requirements:** No formal coverage targets enforced.

**Go coverage:**
```bash
cd dbee && go test $(go list ./... | grep -v tests) -coverprofile=coverage.out
go tool cover -html=coverage.out
```

**Lua coverage:** Not instrumented. Headless tests serve as functional regression coverage.

---

## Test Guidelines

### What to Mock (Go)

- Database drivers (use `go-sqlmock` or custom `database/sql/driver` implementations)
- Adapters (use `dbee/core/mock/` package)
- Result streams (use `mock.NewResultStream`)

### What NOT to Mock (Go)

- The `core.Connection` / `core.Call` lifecycle -- test with real objects + mock adapters
- JSON marshal/unmarshal -- test roundtrip with real encoding

### Adding a New Headless Test

1. Create `ci/headless/check_<feature>.lua`
2. Use unique print prefix: `FEATURE_`
3. Define local `assert_eq`/`assert_true` helpers with `cquit 1` on failure
4. End with success print and `vim.cmd("qa!")`
5. Add the script name to `.github/workflows/test.yml` matrix under `lua-headless-regression`

### Adding a New Integration Test

1. Create `dbee/tests/integration/<adapter>_integration_test.go`
2. Create container helper in `dbee/tests/testhelpers/<adapter>.go`
3. Use `tsuite.Suite` pattern with `SetupSuite` / `TeardownSuite`
4. CI automatically discovers new `*_integration_test.go` files via `find`

---

*Testing analysis: 2026-03-05*
