local floats = require("dbee.ui.common.floats")
local DrawerUI = require("dbee.ui.drawer")
local EditorUI = require("dbee.ui.editor")
local ResultUI = require("dbee.ui.result")
local CallLogUI = require("dbee.ui.call_log")
local Handler = require("dbee.handler")
local install = require("dbee.install")
local notes_migration = require("dbee.notes_migration")
local register = require("dbee.api.__register")

-- Phase 23 invariant (LOAD-BEARING — verified Phase 27 contract review
-- 2026-05-08; v1.5 backlog item #318 DROPPED):
--
-- The lock probe at the top of setup_handler() MUST run on EVERY entry,
-- including when m.core_loaded and m.migration_complete are cached true.
-- Another nvim instance can begin a fresh migration at any time regardless
-- of this process's local cache (m.migration_complete only proves a past
-- maybe_run() succeeded — not current on-disk state).
--
-- Skipping the probe (e.g. via a `core_loaded && migration_complete` early
-- return placed BEFORE is_migration_in_progress) opens a corruption window
-- where this instance's editor reads/writes/deletes/renames under notes_dir
-- collide with the other instance's mid-flight legacy local rename, global
-- rmdir, or staging promotion (which writes live folder:<id>/ files via
-- fs_rename — see notes_migration.lua promote_staging).
--
-- setup_handler() also performs a pure-read pre-register probe before any
-- RegisterPlugin call. Fatal migration failures are held by
-- _assert_migration_ok(); retryable in-progress probes do not set any flag.
-- RegisterPlugin failure is out of Phase 23 migration-latch scope: the
-- pre-existing register-once landmine below means users restart nvim after a
-- register-fail.

-- public and private module objects
local M = {}
local m = {}

-- is core set up?
m.core_loaded = false
-- is ui set up?
m.ui_loaded = false
-- was setup function called?
m.setup_called = false
---@type Config
m.config = {}
m.migration_attempted = false
m.migration_fatal_failed = false
m.migration_complete = false

local function _assert_migration_ok(opts)
  if m.migration_fatal_failed then
    error("dbee migration failed; restart nvim to retry. See notes/.notes-migration-v1.last-failure.log for details.")
  end
  if
    m.core_loaded
    and not m.migration_complete
    and not (opts and opts.allow_incomplete_retry == true)
  then
    error(
      "dbee migration not yet complete; close the other nvim instance and retry. See notes/.notes-migration-v1.last-failure.log for details."
    )
  end
end

local function _throw_migration_in_progress()
  error("another nvim instance is migrating notes; close that instance and retry, or restart all nvim instances")
end

local function resolve_notes_dir()
  return (m.config.editor and m.config.editor.directory) or (vim.fn.stdpath("state") .. "/dbee/notes")
end

local function write_migration_failure_log(notes_dir, err, detail)
  pcall(notes_migration.write_last_failure_log, notes_dir, err, debug.traceback("", 2), detail)
end

local function _throw_migration_aborted(error_kind)
  error(
    "dbee migration aborted ("
      .. tostring(error_kind or "unknown")
      .. "); restart nvim to retry. See notes/.notes-migration-v1.last-failure.log for details."
  )
end

local function oracle_wallet_auto_extract_enabled()
  local oracle = m.config.oracle or {}
  return oracle.wallet_auto_extract ~= false
end

local function sync_oracle_wallet_auto_extract()
  -- Best-effort: silently skip if the Go backend predates the wallet RPC
  -- (e.g. user has an older `dbee` binary). Default behavior on the Go side
  -- is auto-extract enabled, which matches the Lua default.
  pcall(vim.fn.DbeeOracleWalletSetAutoExtract, oracle_wallet_auto_extract_enabled())
end

local function setup_handler()
  local notes_dir = resolve_notes_dir()
  if notes_migration.is_migration_in_progress(notes_dir) then
    _throw_migration_in_progress()
  end

  _assert_migration_ok({ allow_incomplete_retry = true })

  if m.core_loaded and m.migration_complete then
    return
  end

  if not m.setup_called then
    error("setup() has not been called yet")
  end

  if not m.core_loaded then
    -- register remote plugin and mark core_loaded immediately. RegisterPlugin
    -- can only run once per session; if a later setup step throws, a retry
    -- must NOT call register() again ("Plugin '0' is already registered").
    register()
    m.core_loaded = true

    -- add install binary to path
    local pathsep = ":"
    if vim.fn.has("win32") == 1 then
      pathsep = ";"
    end
    vim.env.PATH = install.dir() .. pathsep .. vim.env.PATH

    sync_oracle_wallet_auto_extract()

    m.handler = Handler:new(m.config.sources, {
      before_source_load = sync_oracle_wallet_auto_extract,
    })
    m.handler:add_helpers(m.config.extra_helpers)

    -- activate the last-used connection across nvim restarts; fall back to
    -- the user's `default_connection` when no persisted choice exists or the
    -- persisted id no longer maps to a known connection.
    do
      local last_connection = require("dbee.last_connection")
      local target = nil
      local persisted = last_connection.read()
      if persisted then
        local ok_params, params = pcall(m.handler.connection_get_params, m.handler, persisted)
        if ok_params and params then
          target = persisted
        end
      end
      if not target and m.config.default_connection then
        target = m.config.default_connection
      end
      if target then
        pcall(m.handler.set_current_connection, m.handler, target)
      end
    end
  end

  local ok_migration, migration_result, migration_error_kind, migration_detail =
    pcall(notes_migration.maybe_run, m.handler, notes_dir, m)
  if not ok_migration then
    m.migration_fatal_failed = true
    write_migration_failure_log(notes_dir, migration_result)
    error(migration_result)
  end
  if migration_result == false and migration_error_kind == "lock_held" then
    m.migration_attempted = false
    _throw_migration_in_progress()
  end
  if migration_result == false then
    local err = migration_error_kind or "unknown"
    m.migration_fatal_failed = true
    write_migration_failure_log(notes_dir, err, migration_detail)
    _throw_migration_aborted(err)
  end
  if migration_result == true then
    m.migration_complete = true
  end
end

local function setup_ui()
  setup_handler()
  _assert_migration_ok()

  if m.ui_loaded then
    return
  end

  -- configure options for floating windows
  floats.configure(m.config.float_options)

  -- initiate all UI elements
  m.result = ResultUI:new(m.handler, m.config.result)
  m.call_log = CallLogUI:new(m.handler, m.result, m.config.call_log, function(query)
    -- Deferred require to avoid circular dependency (state -> call_log -> dbee)
    require("dbee").rerun_query(query)
  end)
  m.editor = EditorUI:new(m.handler, m.result, m.config.editor)
  m.drawer = DrawerUI:new(m.handler, m.editor, m.result, m.config.drawer)

  -- register LSP event listeners for schema cache management
  local ok, lsp = pcall(require, "dbee.lsp")
  if ok then
    lsp.register_events()
  end

  m.ui_loaded = true
end

---@param cfg Config
function M.setup(cfg)
  if m.setup_called then
    error("setup() can only be called once")
  end
  m.config = cfg

  m.setup_called = true
end

---@return boolean
function M.is_core_loaded()
  return m.core_loaded
end

---@return boolean
function M.is_ui_loaded()
  return m.ui_loaded
end

---@return Handler
function M.handler()
  _assert_migration_ok({ allow_incomplete_retry = true })
  setup_handler()
  _assert_migration_ok()
  return m.handler
end

---@return EditorUI
function M.editor()
  setup_ui()
  _assert_migration_ok()
  return m.editor
end

---@return CallLogUI
function M.call_log()
  setup_ui()
  _assert_migration_ok()
  return m.call_log
end

---@return DrawerUI
function M.drawer()
  setup_ui()
  _assert_migration_ok()
  return m.drawer
end

---@return ResultUI
function M.result()
  setup_ui()
  _assert_migration_ok()
  return m.result
end

---@return Config
function M.config()
  return m.config
end

return M
