# Codebase Concerns

**Analysis Date:** 2026-03-05

## Tech Debt

**All Results Loaded Into Memory (No Pagination at Driver Level):**
- Issue: `Result.SetIter()` in `dbee/core/result.go` drains the entire `ResultStream` iterator into an in-memory `[]Row` slice (lines 62-73). There is no LIMIT or streaming cutoff. A `SELECT *` on a multi-million row table will consume unbounded RAM.
- Files: `dbee/core/result.go` (lines 44, 62-73), `dbee/core/call.go` (line 230)
- Impact: OOM on large result sets; forces full materialization before the user sees any rows. The UI pages results (`page_size` in `lua/dbee/ui/result/init.lua`) but the Go side fetches everything regardless.
- Fix approach: Implement lazy/chunked result streaming with a configurable row limit (e.g., `max_rows`). Stop iterator drain after threshold and expose a "fetch more" mechanism.

**Hardcoded `/tmp` Paths for Archive and Call Log:**
- Issue: Archive data writes to `/tmp/dbee-history/` (hardcoded in `dbee/core/call_archive.go` line 20) and call log writes to `/tmp/dbee-calllog.json` (hardcoded in `dbee/handler/handler.go` line 20). These paths are not configurable and not user-namespaced. On shared systems, multiple users get collisions.
- Files: `dbee/core/call_archive.go` (line 20), `dbee/handler/handler.go` (line 20)
- Impact: Data collisions on multi-user systems; archive files from different users can overwrite each other. On macOS, `/tmp` is cleaned periodically, losing history silently.
- Fix approach: Move archive and call log paths under `vim.fn.stdpath("state")` / XDG-compliant directories. Accept path as config option. Use user-specific subdirectory.

**`context.TODO()` Scattered Across Drivers:**
- Issue: Multiple adapter drivers use `context.TODO()` for metadata queries (`Structure()`, `Columns()`, `ListDatabases()`), making these calls uncancellable and unbounded.
- Files: `dbee/adapters/sqlserver_driver.go` (lines 47, 66), `dbee/adapters/postgres_driver.go` (lines 54, 73), `dbee/adapters/clickhouse_driver.go` (lines 58, 79), `dbee/adapters/mysql_driver.go` (line 28), `dbee/adapters/mongo.go` (line 54), `dbee/adapters/mongo_driver.go` (line 138)
- Impact: If a metadata query hangs (e.g., slow `information_schema` on large PostgreSQL), the entire plugin hangs with no way to cancel. The Oracle driver fixed this by using explicit timeouts (`context.WithTimeout`), but other drivers have not been updated.
- Fix approach: Replace all `context.TODO()` with `context.WithTimeout(context.Background(), N)` or accept a parent context from the caller. Oracle adapter pattern in `dbee/adapters/oracle_driver.go` (lines 408-409) is the model.

**`ColumnsFromQuery` Uses `fmt.Sprintf` (SQL Injection Vector):**
- Issue: `builders.Client.ColumnsFromQuery()` in `dbee/core/builders/client.go` (line 53) uses `fmt.Sprintf(query, args...)` to interpolate table/schema names directly into SQL strings. Every adapter's `Columns()` method passes user-controlled schema/table names through this path.
- Files: `dbee/core/builders/client.go` (lines 52-53), `dbee/adapters/sqlserver_driver.go` (line 30), `dbee/adapters/postgres_driver.go` (line 39), `dbee/adapters/oracle_driver.go` (line 368), `dbee/adapters/mysql_driver.go` (line 22), `dbee/adapters/clickhouse_driver.go` (line 28), `dbee/adapters/sqlite_driver.go` (line 26), `dbee/adapters/databricks_driver.go` (line 33)
- Impact: A maliciously named table/schema could inject SQL into metadata queries. In practice, table names come from the `Structure()` query results, limiting exploitation to existing database objects. But this is still a code-smell that prevents safe use with untrusted connection sources.
- Fix approach: Use parameterized queries where the driver supports it. For drivers that don't support parameterizing identifiers, use proper identifier quoting functions per-dialect.

**Handler Lookup Maps Not Thread-Safe:**
- Issue: `Handler` in `dbee/handler/handler.go` stores connections and calls in plain Go maps (`lookupConnection`, `lookupCall`, `lookupConnectionCall`) with no mutex protection. The call log is restored in a goroutine (line 49-54) concurrently with potential map reads.
- Files: `dbee/handler/handler.go` (lines 27-29, 48-54, 86-177)
- Impact: Potential data race if the goroutine restoring call log from disk completes while the UI is already making RPC calls that read these maps. In practice, Neovim's RPC is single-threaded on the Go side, so races are unlikely but the code is technically unsound.
- Fix approach: Add a `sync.RWMutex` to `Handler` or ensure call log restoration completes before the handler is accessible to RPC endpoints. The goroutine fire-and-forget pattern at line 49 is the specific danger.

**Unimplemented `bitsadmin` Installer:**
- Issue: The Windows `bitsadmin` installer in `lua/dbee/install/init.lua` (line 146) has a hardcoded `"TODO"` as its argument, making Windows binary installation via bitsadmin non-functional.
- Files: `lua/dbee/install/init.lua` (lines 142-149)
- Impact: Windows users relying on `bitsadmin` (instead of `curl`/`wget`/`go`) cannot install. Not critical since `curl` is available on modern Windows.
- Fix approach: Implement proper bitsadmin download command or remove it from the priority list.

**Duplicated `NextYield`/`readIter` Pattern:**
- Issue: `dbee/core/call_archive.go` `readIter()` (lines 244-349) is a copy-paste of `dbee/core/builders/next.go` `NextYield()` (lines 83-154), acknowledged in a comment at line 243-244. Both use the same channel-based iterator pattern with `atomic.Value` and 5-second timeouts.
- Files: `dbee/core/call_archive.go` (lines 242-349), `dbee/core/builders/next.go` (lines 83-154)
- Impact: Bug fixes must be applied in two places. The duplication exists due to import cycle prevention.
- Fix approach: Extract the shared pattern into a new low-level package (e.g., `dbee/core/iter`) that both `builders` and `call_archive` can import.

## Known Bugs

**Multiple Result Sets Not Properly Supported:**
- Symptoms: `parseRows` in `dbee/core/builders/client.go` (line 197) has a `TODO` comment questioning whether multiple result sets are even supported. The `hasNextFunc` at line 196-205 attempts to advance to the next result set but uses the same header from the first set.
- Files: `dbee/core/builders/client.go` (lines 196-205)
- Trigger: Execute a stored procedure that returns multiple result sets (common in SQL Server and Oracle).
- Workaround: Results from subsequent result sets may display with wrong column headers or be silently dropped.

## Security Considerations

**Overly Permissive File Permissions:**
- Risk: Archive directories are created with `os.ModePerm` (0777) at `dbee/core/call_archive.go` line 67. Log file uses `0o666` at `dbee/plugin/logger.go` line 35. On shared systems, any user can read query history and logs containing SQL statements, which may include sensitive data.
- Files: `dbee/core/call_archive.go` (line 67), `dbee/plugin/logger.go` (line 35)
- Current mitigation: Files are in `/tmp` which on many systems has sticky bit. But directory content (query text, results) is world-readable.
- Recommendations: Use `0o700` for directories and `0o600` for files. Connection URLs (which may contain credentials) flow through `ConnectionParams` and end up in call log JSON at `/tmp/dbee-calllog.json`.

**Query History Persisted in Plaintext:**
- Risk: `dbee/handler/call_log.go` serializes all executed queries (including those with hardcoded credentials in WHERE clauses or connection strings) to `/tmp/dbee-calllog.json` as pretty-printed JSON. Archive files in `/tmp/dbee-history/` contain full result sets as gob-encoded binary.
- Files: `dbee/handler/call_log.go` (lines 11-71), `dbee/core/call_archive.go` (lines 60-155)
- Current mitigation: None.
- Recommendations: Consider redacting or omitting sensitive queries. At minimum, restrict file permissions. Offer config option to disable call log persistence.

**SQL Injection via `ColumnsFromQuery` (see Tech Debt section):**
- Risk: User-controlled identifiers interpolated into metadata SQL queries.
- Files: `dbee/core/builders/client.go` (line 53)
- Current mitigation: Identifiers come from `Structure()` queries that already queried the same database.
- Recommendations: Use parameterized queries or proper identifier escaping.

## Performance Bottlenecks

**Full Result Materialization Before Display:**
- Problem: Every query result is fully drained from the database driver into a Go `[]Row` slice in memory before the UI can display any results. For queries returning millions of rows, this means long waits with only a spinner visible.
- Files: `dbee/core/result.go` (lines 62-73), `dbee/core/call.go` (lines 229-238)
- Cause: `Result.SetIter()` is a blocking drain loop with no early exit. The archive step (`call_archive.go` line 241) then copies the entire result to disk as gob files, adding more latency.
- Improvement path: Stream results to the UI in chunks as they arrive. Display partial results while the iterator is still active. Implement a max-rows limit with explicit "load more" action.

**Polling Loop in `Result.getRows()`:**
- Problem: `getRows()` in `dbee/core/result.go` (lines 169-192) uses a busy-wait polling loop with `time.Sleep(50ms)` to wait for rows to become available during concurrent fill. This wastes CPU cycles and adds up to 50ms latency per page render.
- Files: `dbee/core/result.go` (lines 169-192)
- Cause: No condition variable or channel-based notification when new rows are appended.
- Improvement path: Replace poll loop with `sync.Cond` or a channel that signals when new rows are available or the drain is complete.

**Oracle Adapter Mutex Serializes All Queries:**
- Problem: The Oracle adapter uses a single `sync.Mutex` (`d.mu`) that serializes all query execution on the session-pinned connection. While the mutex is held during row retrieval (released only via `result.AddCallback`), no other query can execute.
- Files: `dbee/adapters/oracle_driver.go` (lines 33, 212, 278)
- Cause: Oracle's go-ora driver requires session-pinned connections for features like DBMS_OUTPUT capture. The mutex ensures session integrity.
- Improvement path: This is a deliberate design tradeoff documented in the code. Structure queries already bypass the session connection (line 407-409). Consider a pool of session connections for truly concurrent execution.

## Fragile Areas

**Lua `dbee.lua` Main Module (1264 lines):**
- Files: `lua/dbee.lua`
- Why fragile: This single file contains the entire public API: `execute_context`, `execute_script`, `cancel_script`, `compile_object`, `reconnect_current_connection`, `retry_last_disconnected`, `actions`, all picker functions (`pick_notes`, `pick_connections`, `pick_history`), and the `execute` convenience wrapper. Shared mutable state (`active_script_run`) is a module-level variable. The `actions()` function alone spans 170+ lines with nested closures.
- Safe modification: Test changes against headless CI scripts in `ci/headless/`. The `execute_script` flow involves complex state management across `active_script_run`, `wait_for_call_terminal_state`, and the cancel mechanism. Any change to state transitions needs concurrent scenario testing.
- Test coverage: Good headless coverage for script execution, variable resolution, action dispatch, and cancellation. But no coverage for `pick_history` confirm flow (line 534-651) with its multi-step note search and floating preview.

**Editor UI Cancel-Confirm Prompt State Machine:**
- Files: `lua/dbee/ui/editor/init.lua` (lines 100-104, 108-151, 350-447)
- Why fragile: The cancel-confirm prompt manages 4 mutable state fields (`_confirm_pending`, `_confirm_conn_id`, `_confirm_resolve`, `_confirm_picker`) across two event listener callbacks and the `confirm_and_execute` closure. State transitions depend on timing between `vim.ui.select` callback, auto-dismiss listener, and Go-side call state events arriving via `vim.schedule`. A synchronous picker close can trigger the choice callback before the auto-dismiss code runs.
- Safe modification: Always verify the double-execution guard (`if resolved then return end`). Test with the headless CI script `ci/headless/check_cancel_confirm_prompt.lua`.
- Test coverage: Has dedicated headless test, but only covers deterministic scenarios. Race-condition-like timing issues between picker close and event dispatch are hard to test headlessly.

**Call State Machine (Go side):**
- Files: `dbee/core/call.go` (lines 130-253)
- Why fragile: `newCallFromExecutor` spawns two goroutines: one for event processing (line 177-210) and one for execution (line 212-250). State transitions flow through a buffered channel (`eventsCh`) with non-blocking sends for `Retrieving` events. The `processState` function has a guard list of terminal states that prevent further transitions. The `Cancel()` function at line 328-342 only acts on `Executing` or `Retrieving` states.
- Safe modification: Any change to state transitions must preserve: (1) terminal states are truly terminal, (2) `markDone()` is called exactly once, (3) `cancelFunc` fires `cancelOnce` correctly, (4) event channel draining after `done` close. Run `go test ./dbee/core/...` with `-race` flag.
- Test coverage: Comprehensive unit tests in `dbee/core/call_test.go` (523 lines) covering normal flow, cancel flow, concurrent cancel, and buffered event saturation.

## Scaling Limits

**Archive Storage (Disk):**
- Current capacity: Every executed query's full result set is archived to `/tmp/dbee-history/` as gob files. No cleanup or rotation.
- Limit: Disk space in `/tmp`. A few large queries (e.g., 100K rows with wide columns) can consume hundreds of megabytes. Over time, archive directories accumulate indefinitely.
- Scaling path: Implement TTL-based cleanup. Add max archive size config. Consider using a single database file (SQLite) instead of per-call directory trees.

**In-Memory Result Cache:**
- Current capacity: All query results are held in memory in `Result.rows` until the connection is closed or the plugin exits.
- Limit: Available process memory. No eviction policy.
- Scaling path: Add LRU eviction for old results. Allow configurable max cached results per connection.

**Handler Lookup Maps (Memory):**
- Current capacity: `lookupCall` in `dbee/handler/handler.go` grows monotonically. Every call ever made during a session is retained.
- Limit: For power users running hundreds of queries in a session, the map grows without bound.
- Scaling path: Evict old calls after archiving. Keep only N most recent per connection.

## Dependencies at Risk

**`github.com/sijms/go-ora` (Oracle Driver):**
- Risk: This is a pure-Go Oracle driver that handles OCI protocol directly. It has known quirks with timeout handling (see `oracleDefaultQueryTimeout` workaround at `dbee/adapters/oracle_driver.go` line 25) and OUT parameter sizing. The session-pinned connection pattern and `isSessionConnError` checks at lines 165-184 are workarounds for driver instability on disconnect.
- Impact: Oracle adapter stability depends on driver behavior for edge cases (network interrupts, idle timeouts, PL/SQL cursor handling).
- Migration plan: No alternative pure-Go Oracle driver exists. Continue with defensive error handling and session reset patterns.

## Missing Critical Features

**No Result Row Limit / Streaming:**
- Problem: Users cannot set a max number of rows to fetch. There is no streaming display of partial results while a query is still running.
- Blocks: Safe use with large tables. Users must know to add `LIMIT`/`FETCH FIRST` to queries manually.

**No Archive Cleanup:**
- Problem: Query result archives accumulate in `/tmp/dbee-history/` without any cleanup mechanism.
- Blocks: Long-running usage on machines with limited `/tmp` space.

## Test Coverage Gaps

**Lua Picker Functions (Snacks Integration):**
- What's not tested: `dbee.pick_notes()`, `dbee.pick_connections()`, `dbee.pick_history()` (lines 306-651 in `lua/dbee.lua`) depend on `snacks.nvim` which is not available in headless CI. The `pick_history` confirm handler has complex logic for note searching and floating preview creation.
- Files: `lua/dbee.lua` (lines 306-651)
- Risk: Regressions in picker formatting, filter token parsing (`parse_tokens`), or confirm actions go undetected.
- Priority: Medium - pickers are user-facing but isolated from core logic.

**Handler Thread Safety:**
- What's not tested: No test verifies concurrent access to `Handler.lookupCall` and `Handler.lookupConnectionCall` maps, specifically the race between async call log restoration (goroutine at `dbee/handler/handler.go` line 49) and early RPC calls.
- Files: `dbee/handler/handler.go` (lines 27-29, 48-54)
- Risk: Potential data race on startup if Neovim sends RPC calls before call log restore completes.
- Priority: Low - Neovim's RPC model makes this unlikely but the code is technically racy.

**Non-Oracle Adapter Metadata (Structure/Columns):**
- What's not tested: Metadata queries (`Structure()`, `Columns()`) for postgres, sqlserver, clickhouse, mysql use `context.TODO()` and have no timeout tests. Integration tests exist but are container-dependent and not part of PR gate.
- Files: `dbee/adapters/postgres_driver.go`, `dbee/adapters/sqlserver_driver.go`, `dbee/adapters/clickhouse_driver.go`, `dbee/adapters/mysql_driver.go`
- Risk: Hanging metadata queries block the entire plugin with no timeout.
- Priority: Medium - affects all non-Oracle users with slow metadata catalogs.

---

*Concerns audit: 2026-03-05*
