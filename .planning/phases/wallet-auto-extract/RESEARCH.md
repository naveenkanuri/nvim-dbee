# Oracle Wallet Auto-Extract - Research

**Researched:** 2026-05-01
**Status:** Revision 3 ready for plan-gate review r4
**Base HEAD:** `d1c3576`

## Backlog And User Problem

`known-issues.md:116` records the runtime gap: Oracle wallet `.zip` paths are accepted by the wizard but `go-ora` expects an extracted wallet directory. Passing a zip path produces an error shaped like:

```text
temp.Ping: c.driver.Ping: open /Users/naveenkanuri/Downloads/Wallet_SPSDB.zip/cwallet.sso: not a directory
```

The right fix is not another wizard parse path. The runtime URL already contains a wallet path; the Oracle adapter must normalize zip paths before opening the driver.

## Existing Runtime Path

Connection creation flows through `core.NewConnection()`:

- `ConnectionParams.Expand()` expands template env/exec expressions into the URL.
- `adapter.Connect(expanded.URL)` is called before ping or query execution.
- `Connection.Ping()` calls `driver.Ping(ctx)`.

Wizard testing and submit both use the same backend seam:

- `lua/dbee/ui/connection_wizard/init.lua:1358` calls `handler:connection_test_spec(submission.params)`.
- `Handler:connection_test_spec()` calls `DbeeConnectionTestSpec`.
- `dbee/handler/handler.go:244` creates a temporary connection, pings it, and closes it.

Therefore, adding extraction inside `Oracle.Connect()` fixes:

- wizard Test Connection,
- wizard Submit pre-save ping,
- saved connection activation,
- reconnect/test of existing saved connections.

## Existing Oracle URL Shape

The wizard currently serializes Oracle Cloud Wallet URLs in two forms:

1. Parsed single-address descriptor:

```text
oracle://user:pass@host:port/service?wallet=<path>&SSL=enable&SSL Verify=false
```

2. Raw descriptor fallback:

```text
oracle://user:pass@host:port?connStr=<descriptor>&WALLET=<path>
```

`parse_oracle_url()` accepts wallet path inputs from the canonical wizard field `wallet_path`, while runtime URLs may contain `WALLET`, `wallet`, or `Wallet`. The Go helper should resolve wallet query keys case-insensitively, preserve the first original key spelling when replacing the value, accept duplicate recognized keys only when they agree, and fail closed on conflicting duplicate wallet values.

Implementation caution: avoid broad semantic rewrites of the Oracle URL. Query encoding may normalize spaces such as `SSL Verify`, so tests must cover the existing wizard-generated direct and `connStr` shapes.

## Existing Wizard Behavior

Phase 8 already implemented assistive wallet inspection in Lua:

- `read_wallet_tnsnames()` can read a wallet directory or shell out to `unzip -p <zip> tnsnames.ora`.
- `DCFG02_WALLET_ALIAS_DISCOVERY_OK` proves wallet-directory and wallet-zip alias discovery in headless tests.
- `DCFG02_TRANSIENT_PING_OK` proves the wizard routes through a transient backend test before save.

This phase should not remove the assistive alias discovery path. It should add a short hint for zip paths and let the authoritative backend ping prove extraction.

## Go Extraction Design

Recommended helper file: `dbee/adapters/oracle_wallet.go`.

Key helpers:

```go
func prepareOracleWalletURL(rawURL string) (string, *oracleWalletResolution, error)
func resolveOracleWalletPath(path string) (*oracleWalletResolution, error)
func clearOracleWalletCache() error
```

Detailed metadata should not require widening `core.Adapter.Connect(url) (Driver, error)` or connection params. Add an optional interface path instead:

```go
type ConnectDetailedAdapter interface {
    ConnectDetailed(url string) (core.Driver, map[string]any, error)
}
```

`core.NewConnection()` checks for the optional interface, stores returned metadata on `core.Connection`, and otherwise calls the existing `Connect`. `wrappedAdapter` forwards the optional hook only when the underlying adapter implements it. Non-Oracle adapters keep nil metadata and current behavior.

`oracleWalletResolution` should include:

```go
type oracleWalletResolution struct {
    OriginalPath  string
    EffectivePath string
    CacheHit      bool
    Extracted     bool
    CacheDir      string
    Hash          string
    HashPrefix    string
    FileCount     int
}
```

`Oracle.Connect(url)` calls `prepareOracleWalletURL()` first and passes the rewritten URL to `sql.Open`. `Oracle.ConnectDetailed(url)` does the same work and returns redacted metadata for the detailed test endpoint. Errors are wrapped as `oracle wallet: ...` so UI messages are actionable.

`CacheDir`, `OriginalPath`, and `EffectivePath` are internal-only. Detailed test metadata must expose only redacted fields such as `HashPrefix`, `CacheHit`, `Extracted`, and `FileCount`.

## Cache And Atomicity

Use:

```text
${XDG_CACHE_HOME:-os.UserCacheDir()}/nvim-dbee/wallets/<sha256-prefix-12>/
```

The final directory should contain the wallet files plus an internal marker:

```json
{
  "sha256": "<full hex>",
  "source_mtime_unix_nano": 123,
  "extracted_at_unix_nano": 456
}
```

Use the marker mtime/content instead of relying only on directory mtime. Directory mtimes can change when files are touched, and a marker gives a stable place to store the full hash for prefix-collision defense.

Atomic extraction shape:

1. Ensure cache root `0700`.
2. Hash the zip content.
3. Validate existing cache dir and marker.
4. If invalid/stale, extract into sibling temp dir.
5. Reject unsafe entries before writing.
6. Validate required files in temp dir.
7. Write marker `0600`.
8. Remove stale final dir only after the temp dir is validated.
9. Rename temp dir to final.
10. Revalidate final before returning it to callers.
11. If a concurrent final already exists or rename races, discard temp and revalidate the winning final.

No portable stdlib file lock is necessary for v1.3 if final dirs are never visible before validation.

## Security Requirements

Zip extraction must fail closed for:

- absolute paths,
- Windows drive-letter absolute paths,
- `..` traversal after `filepath.Clean`,
- empty paths,
- symlinks or non-regular file entries,
- per-file uncompressed size over 10 MiB,
- total regular-file uncompressed size over 50 MiB,
- missing `cwallet.sso`, `tnsnames.ora`, or `sqlnet.ora`.

Copy with a counted reader, not just header checks, because archive metadata is not a security boundary.

## Lua Integration Research

`plugin/dbee.lua` currently exposes only `:Dbee <subcommand>`. There is no standalone wallet command. To provide the requested `:DBeeWalletCacheClear` cleanly:

- add a Go endpoint, e.g. `DbeeOracleWalletCacheClear`;
- add a Lua handler wrapper;
- add a public `require("dbee").wallet_cache_clear()` function;
- register both `:DBeeWalletCacheClear` and `:Dbee wallet_cache_clear`.

This keeps the cache path owned by Go and avoids duplicating `os.UserCacheDir` / XDG behavior in Lua.

The wizard hint belongs in `lua/dbee/ui/connection_wizard/init.lua` near render/status output for `oracle_cloud_wallet`. It can be fully headless-tested by seeding a `.zip` wallet path and inspecting rendered buffer lines or exported state.

The current `connection_test_spec()` Lua wrapper treats nil as success and any non-nil table as failure. Do not break that contract to carry wallet metadata. Add a detailed transient-test endpoint and wrappers:

- Go endpoint `DbeeConnectionTestDetailed` returns `{ status, error?, meta? }`.
- Go endpoint `DbeeOracleWalletCacheClear` owns cache deletion.
- Go endpoint `DbeeOracleWalletSetAutoExtract` receives the Lua config flag for the current session.
- `lua/dbee/api/__register.lua` must include all three endpoints.
- `lua/dbee/api/core.lua` and `lua/dbee/handler/init.lua` must expose Lua-callable wrappers.
- `lua/dbee/api/state.lua` must call the config-sync endpoint in `setup_handler()` after `register()` and the existing `install.dir()` PATH prepend, but before `Handler:new(m.config.sources)`.
- `lua/dbee/handler/init.lua` should accept a pre-source-load sync callback from `state.lua`; `Handler:new` stores it before constructor source initialization, and `_source_reload_silent()` invokes it before any `DbeeCreateConnection` call.

The wizard should call `connection_test_detailed()` for success messaging, while existing callers continue to use `connection_test_spec()`.

Add `oracle.wallet_auto_extract = true` to Lua config. On setup, sync it to Go after the existing PATH setup and before any configured sources are loaded. Deferred source-add/reload paths re-sync through the central `_source_reload_silent()` hook before they create source-backed connections. When false, the adapter skips extraction for zip paths, allowing the pre-feature driver error path to surface and giving users a real rollback switch.

## Verification Research

Primary commands:

```bash
make wallet-test WALLET_PLATFORM=macos
go -C dbee test ./core ./handler ./adapters
```

Regression smoke:

```bash
make perf-lsp PERF_PLATFORM=macos
```

`make wallet-test` should mirror the `perf-lsp` artifact pattern: run Go wallet tests with `go test -count=1 -v`, tee output to `<artifact>/wallet-go.log`, run the Lua headless script with that log path, and emit combined rollup markers. Perf cohorts use 10 warmups, 100 measured iterations, isolated temp cache roots, and explicit timer boundaries. Cache-hit total P95 includes stat, digest, marker validation, and URL rewrite.

`make perf-lsp` is not the primary feature gate, but it remains the easiest way to prove the Phase 4..14 + 12.1/12.2/12.3 smoke stayed green after touching wizard and adapter seams.

## Risks And Mitigations

| Risk | Mitigation |
| --- | --- |
| URL rewrite breaks `SSL Verify` or `connStr` query encoding | Unit-test both existing wizard URL shapes and preserve non-wallet params. |
| Partial extraction reused after crash | Temp-dir plus marker plus required-file validation before final rename. |
| Zip slip or symlink escape | Reject unsafe entry names and non-regular modes before write. |
| Same wallet at different paths repeats extraction | Content hash key dedupes paths. |
| Same content but newer source mtime | Re-extract per D-513 to match the locked invalidation rule. |
| Cache clear deletes user files | Only remove the managed cache root; never touch original zip/dir. |
| Detailed success leaks sensitive paths | Expose only hash prefix, cache hit/miss, extracted flag, and file count. |
| Disable flag works only in Lua tests | Sync `oracle.wallet_auto_extract` to Go and assert zip extraction is skipped when false. |
| Disable flag sync fires before PATH setup | In `state.lua`, preserve order `register()` -> PATH prepend -> sync RPC -> `Handler:new(m.config.sources)`. |
| Disable flag sync happens after source load | In `handler/init.lua`, use one `_source_reload_silent()` pre-create hook so constructor load and deferred add/reload/update paths sync before `DbeeCreateConnection`. |
| Go markers and Lua markers drift | `make wallet-test` writes one Go marker log that the Lua rollup consumes. |
| Cache-hit timing excludes hash cost | Track total cache-hit P95 with digest included and keep post-digest timing as a secondary metric. |
| Stale final dir retains junk | Remove stale final only after validated temp extraction; revalidate final after rename. |
| Windows permission semantics differ | Best-effort chmod; Unix-mode assertions skip or adapt on Windows. |

## Recommended Plan Shape

Use four waves:

1. Go resolver and secure cache extraction.
2. Adapter integration, detailed test/cache clear/config-sync RPCs, and Lua API registration.
3. Lua hint/redacted test message and combined wallet sentinel harness.
4. Docs and regression verification.

Do not modify the LSP helpers or re-open Phase 12 code.

---

*Phase: wallet-auto-extract*
*Research complete: 2026-05-01*
