---
phase: wallet-auto-extract
plan: 01
type: execute
wave: 1
depends_on: ["08-type-aware-connection-wizard", 14, "12.3"]
files_modified:
  - dbee/adapters/oracle_wallet.go
  - dbee/adapters/oracle.go
  - dbee/adapters/adapters.go
  - dbee/adapters/oracle_wallet_test.go
  - dbee/core/connection.go
  - dbee/endpoints.go
  - dbee/handler/handler.go
  - lua/dbee.lua
  - lua/dbee/api/__register.lua
  - lua/dbee/api/core.lua
  - lua/dbee/api/state.lua
  - lua/dbee/config.lua
  - lua/dbee/handler/init.lua
  - plugin/dbee.lua
  - lua/dbee/ui/connection_wizard/init.lua
  - ci/headless/check_oracle_wallet_zip.lua
  - Makefile
  - README.md
  - doc/dbee.txt
autonomous: true
requirements: [DCFG-02]
---

# Oracle Wallet Auto-Extract - Plan

**Created:** 2026-05-01
**Status:** Revision 3 ready for plan-gate review r4
**Base HEAD:** `d1c3576`

## Goal

Make Oracle wallet `.zip` paths work without manual unzip:

- User enters `wallet_path = ~/Downloads/Wallet_SPSDB.zip`.
- Test/Submit/Connect detects the zip, extracts it to a secure content-hash cache, validates wallet files, rewrites the Oracle URL wallet query parameter to the extracted directory, and then calls `go-ora`.
- Later connects reuse the cache unless the zip is newer, the marker is invalid, or required files are missing.
- Existing directory wallet paths continue unchanged.

## Workflow Note

`gsd-sdk query init.phase-op wallet-auto-extract` currently reports `phase_found=false`; this backlog feature is therefore planned in the explicitly requested directory rather than as a numbered roadmap phase. The frontmatter above is still structured for downstream tooling and review.

## Upstream Decisions

Inherit:

- Phase 8 D-89..D-106 for wizard mode, transient ping, FileSource metadata, and wallet alias discovery.
- Phase 14/11 r6/12.1/12.2/12.3 invariants. Do not touch `schema_filter_authority`, `schema_name_canonical`, or `epoch_authority`.
- `known-issues.md:116` backlog scope for zip wallet auto-extract.

## Phase Decisions

- **D-504:** Wallet zip extraction is Go-side runtime behavior owned by the Oracle adapter.
- **D-505:** The extraction hook runs before `sql.Open("oracle", url)` in `Oracle.Connect()`, covering persisted connects and transient pings.
- **D-506:** `dbee/adapters/oracle_wallet.go` owns detection, hashing, extraction, validation, cache reuse, and URL rewrite helpers.
- **D-507:** Recognize wallet query keys case-insensitively and preserve the first original query-key spelling when rewriting for go-ora compatibility.
- **D-508:** Non-zip wallet paths pass through unchanged.
- **D-509:** Cache root is `${XDG_CACHE_HOME:-os.UserCacheDir()}/nvim-dbee/wallets`.
- **D-510:** Cache directories use the first 12 SHA-256 hex chars; the marker stores the full digest and rejects prefix mismatch.
- **D-511:** Re-hash zip content on every zip connect unless a later perf gate proves digest dominates and a size+mtime shortcut is required; the primary cache-hit budget includes the digest cost.
- **D-512:** Reuse cache only when marker hash matches, required files exist, and source zip mtime is not newer than the marker.
- **D-513:** Re-extract on newer zip mtime, invalid/missing marker, or missing required files.
- **D-514:** Use standard library `archive/zip`; no shell `unzip` dependency and no new Go dependency.
- **D-515:** Required extracted root files are `cwallet.sso`, `tnsnames.ora`, and `sqlnet.ora`.
- **D-516:** Reject unsafe zip entries: absolute, drive-letter absolute, empty, traversal, symlink, device, or non-regular file.
- **D-517:** Enforce 10 MiB per file and 50 MiB total extracted regular-file size using declared and copied byte counts.
- **D-518:** Cache dirs are `0700`; files and marker are `0600` where OS permissions support it.
- **D-519:** Extraction is temp-dir + validate + marker + final replacement; partial final directories must not be returned to callers.
- **D-520:** Leading `~/` in wallet paths is expanded by the Go resolver before stat/hash/extract.
- **D-521:** Wizard shows a non-blocking `.zip` auto-extract hint for Oracle Cloud Wallet mode.
- **D-522:** Successful Test Connection may include redacted extraction context when the backend reports extraction: hash prefix, cache hit/miss, and file count only.
- **D-523:** Extraction failures surface wrapped Go errors through existing ping/save failure paths.
- **D-524:** Add `:DBeeWalletCacheClear` and `:Dbee wallet_cache_clear`, both backed by a Go-owned cache clear endpoint.
- **D-525:** Cache clear removes only the managed wallet cache subtree.
- **D-526:** Post-digest cache reuse P95 target is `<5ms`; total cache-hit P95 including stat+digest+cache validation is `<30ms` for the fixture wallet zip.
- **D-527:** First extract and mtime re-extract P95 target is `<500ms` for the fixture wallet zip.
- **D-528:** Tests do not require a live Oracle database.
- **D-529:** Wallet zip rollup is exact-once and blocks sign-off on missing/duplicate markers.
- **D-530:** URL rewrite tests must cover both existing wizard URL shapes: direct `wallet=` and raw-descriptor `WALLET=` with `connStr=`.
- **D-531:** The helper returns extraction metadata internally. Lua success messaging consumes it through an additive detailed transient-test path; connection params are not widened.
- **D-532:** Preserve the existing `connection_test_spec()` nil-on-success/failure-table contract for current callers. Add a detailed wrapper or endpoint for the wizard when success metadata is needed, and prove legacy callers still treat successful pings as nil.
- **D-533:** Existing Lua wallet alias discovery may keep using `unzip -p` for assistive parsing in Phase 8 code. Runtime extraction must not depend on shell `unzip`.
- **D-534:** The cache clear command is best-effort and user-initiated. There is no automatic cache pruning in this phase.
- **D-535:** `make perf-lsp PERF_PLATFORM=macos` remains a regression smoke after implementation, not the primary wallet performance gate.
- **D-536:** Wallet RPC/API changes must be registered end-to-end: Go endpoint, generated manifest entry in `lua/dbee/api/__register.lua`, Lua handler wrapper, public `lua/dbee/api/core.lua` wrapper, and user command where applicable.
- **D-537:** Add `connection_test_detailed` / `DbeeConnectionTestDetailed`, returning `{ status, error?, meta? }`; `meta.wallet_auto_extract` may include `hash_prefix`, `cache_hit`, `extracted`, and `file_count`, but never the full cache path.
- **D-538:** Keep `connection_test_spec` exactly backward-compatible: nil on success, failure table on error, no success metadata.
- **D-539:** Add `oracle.wallet_auto_extract` config, default `true`. Lua setup syncs the flag to Go via a registered endpoint; when false, zip paths follow the pre-feature driver error path and extraction is not attempted.
- **D-540:** User-visible extraction success text is redacted, e.g. `wallet extracted (7c4a8d... 12 files)`.
- **D-541:** The canonical wizard/config field is lowercase `wallet_path`; the adapter normalizes URL wallet lookup case-insensitively, accepts duplicate recognized keys only when they agree, and fails closed on conflicting duplicate values.
- **D-542:** Add `make wallet-test` using the existing artifact style: Go verbose wallet tests tee to `<artifact>/wallet-go.log`; the Lua rollup reads that log plus Lua sentinel output and emits combined wallet rollup markers.
- **D-543:** Wallet perf tests are deterministic: `go test -count=1`, 10 warmup iterations, 100 measured iterations, isolated temp cache root, explicit timer boundaries, and P50/P95/max marker output.
- **D-544:** `WALLET_ZIP_CACHE_HIT_TOTAL_P95_MS` measures full cache-hit dispatch, including path stat, zip hash, marker validation, and URL rewrite.
- **D-545:** Stale final replacement extracts to a sibling temp dir, validates it, removes the stale final dir, renames temp to final, and revalidates final before returning; on rename race, revalidate the winner and discard temp.
- **D-546:** Concurrent same-zip extraction may duplicate work but must converge on one validated final dir with no temp residue or partial cache reuse.
- **D-547:** The phase may read user-provided wallet zip/dir paths at runtime, but writes only the managed cache root and test temp dirs; original wallet zips and directories are never modified.
- **D-548:** Detailed test metadata flows through an optional adapter metadata hook stored on `core.Connection`; `core.Adapter.Connect(url) (Driver, error)` and connection params remain backward-compatible.
- **D-549:** `wrappedAdapter` forwards the optional detailed-connect hook only when the underlying adapter implements it. Non-Oracle adapters produce nil metadata and keep existing behavior.
- **D-550:** `lua/dbee/api/state.lua` owns setup-time wallet auto-extract sync ordering. The order is exactly `register()` -> prepend `install.dir()` to `PATH` -> `DbeeOracleWalletSetAutoExtract(m.config.oracle.wallet_auto_extract)` -> `Handler:new(m.config.sources, opts)` so the first sync RPC uses the intended `dbee` binary and source-loaded saved connections cannot extract before the disable flag reaches Go.
- **D-551:** `lua/dbee/handler/init.lua` owns one central pre-source-load sync hook. `state.lua` passes a wallet auto-extract sync callback into `Handler:new(...)`; `Handler:new` stores it before initializing sources; `_source_reload_silent()` invokes it before any `DbeeCreateConnection` call and aborts source reload on sync failure. This single hook covers constructor source load plus deferred `add_source`, `source_reload`, `source_add`, and `source_update`.

## Task Breakdown

| Task | Description | Files / Functions | Sentinels | Complexity |
| --- | --- | --- | --- | --- |
| 1 | Add Oracle wallet URL parser/rewrite helper with case-insensitive wallet query lookup, duplicate-key handling, tilde expansion, zip magic/extension detection, and non-zip pass-through. | `dbee/adapters/oracle_wallet.go` | passthrough, magic, tilde, URL rewrite, duplicate key normalization | Medium |
| 2 | Implement secure cache hashing, marker validation, mtime invalidation, stale final replacement, size caps, zip-slip/symlink rejection, permissions, and concurrent-safe temp extraction. | `oracle_wallet.go` | extract, cache hit, mtime, stale replace, slip, symlink, bomb, permissions, atomic/concurrent | Large |
| 3 | Wire `Oracle.Connect()` to prepare the URL before `sql.Open`, honor the Go-synced disable flag, wrap extraction errors actionably, and expose optional connect metadata. | `dbee/adapters/oracle.go`, `dbee/adapters/adapters.go`, `dbee/core/connection.go` | connect URL rewrite, disable honored, error surfaced, metadata stored | Medium |
| 4 | Add Go unit tests, deterministic perf cohorts, and verbose marker output for wallet extraction and metadata. | `dbee/adapters/oracle_wallet_test.go` | Go markers + deterministic metrics | Medium |
| 5 | Add Go endpoints for cache clear, detailed transient test metadata, and wallet auto-extract config sync while preserving legacy nil-on-success ping behavior. | `dbee/endpoints.go`, `dbee/handler/handler.go` | detailed meta, legacy ping, config sync | Medium |
| 6 | Register and expose wallet endpoints through Vim RPC and Lua API wrappers, sync wallet auto-extract config after PATH setup but before initial source load, and add user cache-clear commands. | `lua/dbee/api/__register.lua`, `lua/dbee/api/core.lua`, `lua/dbee/api/state.lua`, `lua/dbee.lua`, `plugin/dbee.lua` | RPC registered, cache clear command, sync after PATH prepend | Medium |
| 7 | Add the central pre-source-load wallet sync hook in the handler so `_source_reload_silent()` syncs before every source-created connection path. | `lua/dbee/handler/init.lua`, `lua/dbee/api/state.lua` | disable sync before source load, deferred source load sync | Medium |
| 8 | Add `oracle.wallet_auto_extract` config, wizard `.zip` hint, redacted detailed-test success message, and save semantics unchanged. | `lua/dbee/config.lua`, `lua/dbee/ui/connection_wizard/init.lua` | wizard hint, redacted success, disable flag | Medium |
| 9 | Add wallet rollup/headless harness and `make wallet-test` combined Go/Lua artifact flow. | `ci/headless/check_oracle_wallet_zip.lua`, `Makefile` | combined rollup/exactly-once/all-pass | Medium |
| 10 | Update docs for zip wallet behavior, cache location, disable flag, clear command, redacted metadata, and security limits. | `README.md`, `doc/dbee.txt` | docs grep | Small |
| 11 | Run final verification and capture summary. | no source change | all markers + regression smoke | Small |

## Execution Waves

### Wave 1 - Go Runtime Core

Tasks: 1, 2, 3, 4

Goal: prove zip wallet extraction, cache reuse, invalidation, safety, permissions, and URL rewrite entirely in Go before Lua surfaces depend on it.

### Wave 2 - User Controls

Tasks: 5, 6, 7, 8

Goal: add cache clearing, detailed metadata, PATH-aware disable/config sync, central source-load sync coverage, and user-facing wizard feedback without changing the existing Phase 8 wizard submission contract.

### Wave 3 - Evidence And Docs

Tasks: 9, 10

Goal: make the feature gate reproducible through wallet-specific markers, exact rollup, and documentation.

### Wave 4 - Regression Verification

Task: 11

Goal: run wallet tests, Go package tests, and v1.3 smoke to prove no regression.

## Sentinel Matrix

Strict true markers:

| Marker | Assertion |
| --- | --- |
| `WALLET_ZIP_AUTO_EXTRACT_OK` | Valid wallet zip extracts and required files exist in cache. |
| `WALLET_ZIP_CACHE_HIT_REUSES` | Same zip second resolve reuses existing cache dir without re-copying files. |
| `WALLET_ZIP_CONTENT_HASH_DEDUPES` | Same zip content at different paths resolves to same cache dir. |
| `WALLET_ZIP_MTIME_INVALIDATES` | Newer source zip mtime triggers re-extract for same hash dir. |
| `WALLET_ZIP_STALE_FINAL_REPLACED` | Pre-existing stale final dir with junk is replaced; final contains only fresh validated wallet files. |
| `WALLET_ZIP_SLIP_REJECTED` | `../` or absolute-path entries are rejected. |
| `WALLET_ZIP_SYMLINK_REJECTED` | Symlink or non-regular zip entries are rejected. |
| `WALLET_ZIP_BOMB_REJECTED` | Oversized per-file or total extracted size is rejected. |
| `WALLET_ZIP_MISSING_FILES_ERROR` | Missing required wallet files returns an actionable missing-file error. |
| `WALLET_ZIP_PERMISSIONS_LOCKED` | Cache dir/file modes are restrictive where supported. |
| `WALLET_ZIP_NON_ZIP_PASSTHROUGH` | Directory/non-zip wallet paths are not rewritten or extracted. |
| `WALLET_ZIP_MAGIC_BYTES_DETECTED` | ZIP magic bytes are detected even when extension is not lowercase `.zip`. |
| `WALLET_ZIP_TILDE_EXPANDS` | `~/.../Wallet.zip` resolves against the user home dir before extraction. |
| `WALLET_ZIP_ATOMIC_RENAME_OK` | Failed extraction leaves no partial final dir; successful extraction appears only after validation. |
| `WALLET_ZIP_CONCURRENT_RESOLVE_OK` | Concurrent same-zip resolves converge on one validated cache dir without temp residue. |
| `WALLET_ZIP_CONN_URL_REWRITTEN` | Oracle URL wallet query param is replaced with extracted dir and other query params survive. |
| `WALLET_ZIP_DUPLICATE_WALLET_KEYS_NORMALIZED` | Case-variant wallet query keys normalize to one logical path; conflicting duplicate values fail closed. |
| `WALLET_ZIP_TEST_SUCCESS_MESSAGE_OK` | Wizard test success can include redacted extraction context when backend reports it. |
| `WALLET_ZIP_NO_FULL_PATH_DISCLOSURE` | Detailed metadata and success text do not include the full cache directory or source wallet path. |
| `WALLET_ZIP_DETAILED_TEST_META_OK` | `connection_test_detailed` returns status plus redacted wallet extraction metadata on success. |
| `WALLET_ZIP_LEGACY_PING_CONTRACT_OK` | Existing `connection_test_spec()` callers still receive nil on success and failure table on failure. |
| `WALLET_ZIP_WIZARD_HINT_OK` | Oracle Cloud Wallet `.zip` path renders the auto-extract hint. |
| `WALLET_ZIP_RPC_REGISTERED` | Cache clear, detailed test, and wallet config sync endpoints are registered and callable from Lua. |
| `WALLET_ZIP_DISABLE_FLAG_HONORED` | `oracle.wallet_auto_extract=false` prevents extraction and preserves the pre-feature zip error path. |
| `WALLET_ZIP_DISABLE_SYNC_BEFORE_SOURCE_LOAD` | Fresh setup with disabled config and saved zip-wallet source syncs Go before source-created Oracle connections can extract. |
| `WALLET_ZIP_DISABLE_SYNC_AFTER_PATH_PREPEND` | Setup prepends `install.dir()` to `PATH` before the first wallet auto-extract sync RPC fires. |
| `WALLET_ZIP_DISABLE_SYNC_BEFORE_DEFERRED_SOURCE_LOAD` | Deferred `add_source`, `source_reload`, `source_add`, and `source_update` paths sync before `_source_reload_silent()` creates connections. |
| `WALLET_ZIP_CACHE_CLEAR_COMMAND_OK` | Both cache-clear command surfaces call the backend clear path and remove only managed cache files. |
| `WALLET_ZIP_EXTRACTION_ERROR_SURFACED` | Corrupt/unsafe extraction errors appear through the existing ping/save failure message. |
| `WALLET_ZIP_NO_LIVE_ORACLE_DEPENDENCY` | Wallet tests pass without opening a live Oracle database. |
| `WALLET_ZIP_PERF_DETERMINISTIC` | Perf cohorts run with fixed warmup/measured counts, isolated temp cache, and `go test -count=1`. |
| `WALLET_ZIP_ROLLUP_GO_LUA_COMBINED` | Wallet rollup consumes both Go verbose marker log and Lua sentinel output. |
| `WALLET_ZIP_ROLLUP_EXACTLY_ONCE_OK` | Every required wallet marker appears exactly once before rollup. |

Numeric markers:

| Marker | Budget |
| --- | --- |
| `WALLET_ZIP_CACHE_HIT_MS` | finite; post-digest validation P95 `<5ms`. |
| `WALLET_ZIP_CACHE_HIT_TOTAL_P95_MS` | finite; full cache-hit path including stat+digest+validation P95 `<30ms`. |
| `WALLET_ZIP_EXTRACT_MS` | finite; fixture extraction P95 `<500ms`. |
| `WALLET_ZIP_REEXTRACT_MS` | finite; fixture mtime re-extraction P95 `<500ms`. |

Rollup-emitted markers:

| Marker | Assertion |
| --- | --- |
| `WALLET_ZIP_ROLLUP_MARKERS_CHECKED` | `37` checked markers. |
| `WALLET_ZIP_ALL_PASS` | All strict and numeric wallet markers pass. |

Marker ledger: 33 strict true markers + 4 numeric markers = 37 checked. Rollup emits 2 additional markers, for 39 emitted wallet markers total.

## Verification Commands

Primary feature gate:

```bash
make wallet-test WALLET_PLATFORM=macos
go -C dbee test ./core ./handler ./adapters
```

Regression smoke:

```bash
make perf-lsp PERF_PLATFORM=macos
```

Expected final evidence:

- `WALLET_ZIP_ROLLUP_MARKERS_CHECKED=37`
- `WALLET_ZIP_ALL_PASS=true`
- Existing `DCFG02_WIZARD_ALL_PASS=true`
- `LSP12_HOVER_RESOLVE_ALL_PASS=true`
- `LSP12_2_ALL_PASS=true`
- `LSP12_3_ALL_PASS=true`
- `ARCH14_ALL_PASS=true`

## Implementation Notes

- Do not add new dependencies.
- Do not write outside the repo except test temp dirs and the managed wallet cache. Runtime may read the user-specified wallet zip or wallet directory path.
- Keep all original wallet zips and user wallet directories untouched.
- Do not alter FileSource metadata shape for wallet extraction.
- Do not touch the three Phase 12 helper modules.

## Revision 1 Closure Map

| r1 issue | Closure |
| --- | --- |
| RPC/API surface incomplete | D-536, Tasks 5-6, `WALLET_ZIP_RPC_REGISTERED`. |
| Success metadata path undefined | D-537/D-538/D-548/D-549, Tasks 3/5/8, `WALLET_ZIP_DETAILED_TEST_META_OK`. |
| Rollback/disable missing | D-539, Tasks 3/5/6/8, `WALLET_ZIP_DISABLE_FLAG_HONORED`. |
| Go marker rollup not wired | D-542, Task 9, `WALLET_ZIP_ROLLUP_GO_LUA_COMBINED`. |
| Cache-hit perf excludes hash cost | D-526/D-544, `WALLET_ZIP_CACHE_HIT_TOTAL_P95_MS`. |
| Perf method under-specified | D-543, Task 4, `WALLET_ZIP_PERF_DETERMINISTIC`. |
| Stale final replacement underspecified | D-545, Task 2, `WALLET_ZIP_STALE_FINAL_REPLACED`. |
| Success message leaks cache path | D-522/D-540, `WALLET_ZIP_NO_FULL_PATH_DISCLOSURE`. |
| Duplicate wallet key behavior undefined | D-541, Task 1, `WALLET_ZIP_DUPLICATE_WALLET_KEYS_NORMALIZED`. |

## Revision 2 Closure Map

| r2 issue | Closure |
| --- | --- |
| Disable flag can sync too late before source load | D-550, Tasks 6-7, `WALLET_ZIP_DISABLE_SYNC_BEFORE_SOURCE_LOAD`. |

## Revision 3 Closure Map

| r3 sub-issue | Closure |
| --- | --- |
| Sync RPC could fire before `install.dir()` PATH prepend | D-550, Task 6, `WALLET_ZIP_DISABLE_SYNC_AFTER_PATH_PREPEND`. |
| Deferred source-created connection paths lacked one pinned sync seam | D-551, Task 7, `WALLET_ZIP_DISABLE_SYNC_BEFORE_DEFERRED_SOURCE_LOAD`. |

## Plan-Gate Checklist

- Goal-backward path covers Test, Submit, and Connect.
- Cache key, invalidation, permissions, and extraction atomicity are sentinel-covered.
- Detailed transient test metadata has a registered RPC path while legacy transient test behavior remains unchanged.
- Disable flag is synced to Go after PATH setup, before initial source load, and through one central `_source_reload_silent()` hook before deferred source-created connection paths, proving a zip path does not trigger extraction when disabled.
- Wallet rollup mechanically combines Go and Lua markers from a shared artifact log.
- Security limits cover zip slip, symlinks, size caps, and missing files.
- Existing directory wallet flow has explicit pass-through coverage.
- Lua hint/command additions are additive and do not reopen Phase 8 wizard architecture or leak full wallet/cache paths.
- Regression smoke preserves Phase 4..14 + 12.1/12.2/12.3.

---

*Phase: wallet-auto-extract*
*Plan created: 2026-05-01*
