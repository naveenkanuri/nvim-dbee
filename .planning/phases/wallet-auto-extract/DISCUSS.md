# Oracle Wallet Auto-Extract - Discussion

**Gathered:** 2026-05-01
**Status:** Revision 3 ready for plan-gate review r4
**Codex thread:** `019de3a8-0f9e-7331-9b24-d64e87711634`
**Base HEAD:** `d1c3576`

## Phase Boundary

This phase makes Oracle Cloud Wallet `.zip` paths work at runtime:

- A saved or transient Oracle connection may contain a wallet query parameter pointing at `Wallet_*.zip`.
- On test, submit, or connect, the Go Oracle adapter detects the zip, extracts it to a managed cache directory, verifies the required wallet files, and rewrites only the wallet path passed to `go-ora`.
- Existing directory wallet paths continue to pass through unchanged.
- Lua adds a small user-facing hint and a cache-clear command; it does not implement extraction.

Out of scope:

- New Oracle connection modes.
- New secret storage, wallet editing, or wallet download UX.
- Live Oracle integration tests.
- Any LSP helper or Phase 12 cache changes.

## Carry-Forward Constraints

- Honor Phase 8 D-89..D-106 for the type-aware wizard and FileSource metadata model.
- Honor Phase 14/11 r6/12.1/12.2/12.3 invariants; the three LSP helper modules remain untouched.
- Preserve Phase 8's rule that wallet alias discovery is assistive and driver ping remains authoritative.
- Keep connection params backward-compatible: runtime records remain `{ id, name, type, url }`.
- Existing directory-based Oracle wallet connections must continue to work without cache involvement.

## Locked Decisions

### Runtime Ownership

- **D-504:** Wallet zip extraction is Go-side runtime behavior owned by the Oracle adapter. Lua may hint, test, and clear cache, but it must not unzip the wallet for connection execution.
- **D-505:** The extraction hook runs before `sql.Open("oracle", url)` in `Oracle.Connect()`, so both persisted connects and transient `ConnectionTestSpec` use the same behavior.
- **D-506:** `dbee/adapters/oracle_wallet.go` owns path detection, hashing, extraction, validation, cache reuse, and URL rewrite helpers. `oracle.go` only calls the helper and wraps errors.
- **D-507:** The helper recognizes wallet zip paths from Oracle URL query keys case-insensitively and preserves the first original key spelling when rewriting for go-ora compatibility.
- **D-508:** A non-zip wallet path is passed through unchanged. Directory validation remains the driver's responsibility unless the path was extracted by this feature.

### Cache Location And Keying

- **D-509:** Cache root is `${XDG_CACHE_HOME:-os.UserCacheDir()}/nvim-dbee/wallets` on Go side. The planned user-facing shorthand is `~/.cache/nvim-dbee/wallets` on Unix-like systems.
- **D-510:** Cache directory names use the first 12 hex characters of the SHA-256 digest of zip content. A marker file stores the full digest so a prefix collision fails closed instead of reusing wrong contents.
- **D-511:** The resolver computes SHA-256 on every zip connect to dedupe same-content wallets across paths unless perf evidence requires a later size+mtime shortcut. The primary cache-hit budget includes digest time.
- **D-512:** Cache hit reuse is allowed only when the marker full hash matches, required files exist, and the zip mtime is not newer than the completed extraction marker.
- **D-513:** Re-extract when the zip mtime is newer than the marker, the marker is missing/invalid, or required files are missing.

### Extraction Semantics

- **D-514:** Extraction uses Go standard library `archive/zip`; no shell `unzip` dependency and no new Go dependency.
- **D-515:** The extracted directory must contain `cwallet.sso`, `tnsnames.ora`, and `sqlnet.ora` at its root after extraction. Missing files return an actionable error listing all missing names.
- **D-516:** Wallet zips with absolute paths, drive-letter paths, empty paths, `..` traversal, symlinks, devices, or other non-regular entries are rejected before writing content.
- **D-517:** Per-file uncompressed size is capped at 10 MiB and total extracted regular-file size at 50 MiB. Both header-declared and actually copied byte counts are enforced.
- **D-518:** Cache root and extraction dirs are `0700`; extracted files and marker files are `0600`. Windows best-effort permissions are acceptable but tests assert Unix modes when supported.
- **D-519:** Extraction is atomic from the caller's perspective: write to a temp directory under the cache root, validate and write the marker, replace stale final contents, then revalidate final before returning. Concurrent connects may duplicate extraction work, but they must never return a partial final directory.
- **D-520:** Leading `~/` wallet paths are expanded in Go before stat/hash/extract. This covers direct hand-authored URLs as well as wizard defaults.

### User Feedback And Cache Clearing

- **D-521:** Wizard Oracle Cloud Wallet mode shows a non-blocking hint when `wallet_path` ends in `.zip`: "Wallet zip will be auto-extracted on connect." This does not block manual alias entry.
- **D-522:** The Test Connection success status includes only redacted extraction context when the backend returns it, using terse text such as `OK (wallet extracted 7c4a8d... 12 files)`.
- **D-523:** Extraction failures surface the Go wrapped error verbatim through the existing ping/save failure path.
- **D-524:** Add `:DBeeWalletCacheClear` as a direct command and `:Dbee wallet_cache_clear` as a discoverable subcommand. Both call a Go-owned cache clear endpoint so Lua does not duplicate cache path logic.
- **D-525:** Cache clearing removes only the managed `nvim-dbee/wallets` subtree. It never deletes the original wallet zip or user-provided directory.

### Performance And Verification

- **D-526:** Post-digest cache reuse target is P95 `<5ms` for stat/marker/required-file validation. Whole cache-hit resolution, including digest, has P95 target `<30ms` for the fixture wallet zip.
- **D-527:** First extract and mtime-triggered re-extract target P95 `<500ms` for a typical Oracle wallet zip fixture under 1 MiB.
- **D-528:** Tests avoid a live Oracle database. They prove URL rewrite and extraction before `go-ora` by unit-testing the helper and by the existing transient ping path shape.
- **D-529:** The feature emits a strict wallet rollup with exact marker counting. Rollup failure blocks execution sign-off.

### Plan-Gate r1 Closure Decisions

- **D-536:** New wallet endpoints must be registered in Go, `lua/dbee/api/__register.lua`, `lua/dbee/api/core.lua`, Lua handler wrappers, and public command surfaces before they count as implemented.
- **D-537:** `connection_test_detailed` returns `{ status, error?, meta? }` with redacted `meta.wallet_auto_extract` fields only: hash prefix, cache hit/miss, extracted flag, and file count.
- **D-538:** `connection_test_spec` stays backward-compatible and never carries success metadata.
- **D-539:** `oracle.wallet_auto_extract` defaults to true and is synced to Go; false disables zip extraction and preserves the pre-feature zip error path.
- **D-540:** User-visible success text never prints full source wallet or cache paths.
- **D-541:** The canonical wizard/config key is lowercase `wallet_path`; adapter lookup of URL wallet query keys is case-insensitive and conflicting duplicate values fail closed.
- **D-542:** `make wallet-test` mechanically combines Go verbose marker output and Lua sentinel output into one wallet rollup.
- **D-543:** Perf gates use `go test -count=1`, 10 warmups, 100 measured iterations, isolated temp cache, and explicit timer boundaries.
- **D-544:** Cache-hit total P95 includes stat, digest, marker validation, and URL rewrite.
- **D-545:** Stale final replacement removes stale final contents only after a validated temp extraction exists, then revalidates the final dir before returning.
- **D-546:** Concurrent same-zip extraction must converge without temp residue or partial cache reuse.
- **D-547:** Runtime may read user-provided wallet paths, but writes only managed cache or test temp dirs.
- **D-548:** Detailed test metadata flows through an optional adapter metadata hook stored on `core.Connection`; connection params and the core `Connect(url)` contract stay backward-compatible.
- **D-549:** `wrappedAdapter` forwards detailed-connect metadata only for adapters that opt in. Non-Oracle adapters keep nil metadata and current behavior.

### Plan-Gate r2 Closure Decisions

- **D-550:** `lua/dbee/api/state.lua` owns setup-time wallet auto-extract sync ordering. It calls `DbeeOracleWalletSetAutoExtract(m.config.oracle.wallet_auto_extract)` only after RPC `register()` and the existing `install.dir()` PATH prepend, and before `Handler:new(m.config.sources)`.

### Plan-Gate r3 Closure Decisions

- **D-551:** `lua/dbee/handler/init.lua` owns one central pre-source-load sync hook. `state.lua` passes the wallet auto-extract sync callback into `Handler:new(...)`; `Handler:new` stores it before constructor source initialization; `_source_reload_silent()` invokes it before any `DbeeCreateConnection` call and aborts reload on sync failure, covering constructor load plus `add_source`, `source_reload`, `source_add`, and `source_update`.

## Deferred Ideas

- Background cache pruning or TTL cleanup.
- Wallet cache browser/open-in-finder UI.
- Encrypted extracted-wallet storage.
- Full live Oracle wallet integration test.
- Support for arbitrary nested wallet zip layouts beyond root-level expected files.

## Canonical References

- `known-issues.md` - v1.3 Oracle wallet auto-extract backlog entry and original failure mode.
- `.planning/PROJECT.md` - v1.3 milestone principles and additive/backward-compatible rule.
- `.planning/REQUIREMENTS.md` - DCFG-02 validated wizard requirement and adapter compatibility constraints.
- `.planning/phases/08-type-aware-connection-wizard/08-CONTEXT.md` - Oracle Cloud Wallet mode, wallet zip alias discovery, and transient ping ownership.
- `.planning/phases/08-type-aware-connection-wizard/08-02-PLAN.md` - wizard wallet path and `.zip` alias-discovery implementation context.
- `.planning/phases/08-type-aware-connection-wizard/08-04-SUMMARY.md` - existing headless wallet alias discovery and transient ping evidence.
- `dbee/adapters/oracle.go` - Oracle adapter connect seam before `sql.Open`.
- `dbee/adapters/oracle_driver.go` - Oracle driver/ping behavior after `sql.Open`.
- `dbee/handler/handler.go` - transient connection test path used by wizard test and submit.
- `lua/dbee/ui/connection_wizard/init.lua` - Oracle wallet fields, URL rendering, alias discovery, and test status UI.
- `plugin/dbee.lua` - user command registration surface.

---

*Phase: wallet-auto-extract*
*Context gathered: 2026-05-01*
