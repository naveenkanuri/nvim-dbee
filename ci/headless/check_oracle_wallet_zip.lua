-- Oracle wallet zip auto-extract rollup gate.
--
-- Usage:
--   WALLET_GO_LOG=/path/to/wallet-go.log nvim --headless -u NONE -i NONE -n \
--     --cmd "set rtp+=$(pwd)" \
--     -c "luafile ci/headless/check_oracle_wallet_zip.lua"

local emitted = {}

local function record(label, value)
  emitted[label] = emitted[label] or {}
  emitted[label][#emitted[label] + 1] = tostring(value)
  print(label .. "=" .. tostring(value))
end

local function fail(message)
  record("WALLET_ZIP_ROLLUP_FAIL", message)
  record("WALLET_ZIP_ALL_PASS", "false")
  vim.cmd("cquit 1")
end

local function assert_true(label, value)
  if not value then
    fail(label .. ": expected truthy, got " .. vim.inspect(value))
  end
end

local function assert_eq(label, actual, expected)
  if actual ~= expected then
    fail(label .. ": expected " .. vim.inspect(expected) .. " got " .. vim.inspect(actual))
  end
end

local function read_file(path)
  local fd = io.open(path, "r")
  if not fd then
    fail("could not read file: " .. tostring(path))
  end
  local content = fd:read("*a")
  fd:close()
  return content
end

local function parse_marker_lines(content, out)
  for line in tostring(content or ""):gmatch("[^\r\n]+") do
    local key, value = line:match("^([%w_]+)=(.*)$")
    if key then
      out[key] = out[key] or {}
      out[key][#out[key] + 1] = value
    end
  end
end

local function install_wizard_stubs()
  package.loaded["nui.popup"] = function()
    return {
      bufnr = nil,
      winid = nil,
      mount = function(self)
        self.bufnr = vim.api.nvim_create_buf(false, true)
      end,
      unmount = function(self)
        if self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr) then
          vim.api.nvim_buf_delete(self.bufnr, { force = true })
        end
      end,
      map = function() end,
    }
  end

  package.loaded["nui.input"] = function()
    return {
      mount = function() end,
      unmount = function() end,
      map = function() end,
    }
  end

  package.loaded["nui.menu"] = setmetatable({
    item = function(text)
      return { text = text }
    end,
  }, {
    __call = function()
      return {
        mount = function() end,
        unmount = function() end,
        map = function() end,
        tree = {
          get_node = function()
            return nil
          end,
        },
      }
    end,
  })

  package.loaded["dbee.ui.drawer.menu"] = {
    select = function(opts)
      return opts
    end,
    input = function(opts)
      return opts
    end,
  }
end

local function install_api_state_stubs()
  package.loaded["dbee.ui.common.floats"] = {
    configure = function() end,
  }
  for _, module in ipairs({
    "dbee.ui.drawer",
    "dbee.ui.editor",
    "dbee.ui.result",
    "dbee.ui.call_log",
  }) do
    package.loaded[module] = {
      new = function()
        return {}
      end,
    }
  end
end

local function run_wizard_checks()
  install_wizard_stubs()
  package.loaded["dbee.ui.connection_wizard"] = nil
  local wizard_mod = require("dbee.ui.connection_wizard")

  local hint = wizard_mod._wallet_auto_extract_hint({
    mode = "oracle_cloud_wallet",
    fields = {
      oracle_cloud_wallet = {
        wallet_path = "/tmp/Wallet_SPSDB.zip",
      },
    },
  })
  assert_true("wallet zip hint", hint and hint:find("auto%-extracted") ~= nil)
  record("WALLET_ZIP_WIZARD_HINT_OK", "true")

  local success = wizard_mod._wallet_auto_extract_success({
    wallet_auto_extract = {
      hash_prefix = "7c4a8d991122",
      cache_hit = false,
      extracted = true,
      file_count = 12,
    },
  })
  assert_eq("wallet success text", success, "wallet extracted (7c4a8d... 12 files)")
  assert_true("wallet success redacted", not success:find("/", 1, true) and not success:find(".zip", 1, true))
  record("WALLET_ZIP_NO_FULL_PATH_DISCLOSURE", "true")

  local ok_handler = {
    connection_test_detailed = function(_, params)
      assert_true("detailed test params", params and params.type == "oracle")
      return {
        status = "ok",
        meta = {
          wallet_auto_extract = {
            hash_prefix = "7c4a8d991122",
            cache_hit = false,
            extracted = true,
            file_count = 12,
          },
        },
      }
    end,
  }
  local ok_wizard = wizard_mod.open({
    handler = ok_handler,
    seed = {
      wizard = {
        db_kind = "oracle",
        mode = "oracle_cloud_wallet",
        fields = {
          name = "SPSDB",
          wallet_path = "/tmp/Wallet_SPSDB.zip",
          service_alias = "DB_LOW",
          username = "user",
          password = "pass",
        },
      },
    },
  })
  ok_wizard:test_connection()
  assert_eq("detailed test status", ok_wizard.state.test_status, "ok")
  assert_eq("detailed test message", ok_wizard.state.test_message, success)
  record("WALLET_ZIP_TEST_SUCCESS_MESSAGE_OK", "true")
  record("WALLET_ZIP_DETAILED_TEST_META_OK", "true")

  local error_handler = {
    connection_test_detailed = function()
      return {
        status = "error",
        error = {
          error_kind = "driver",
          message = "prepare oracle wallet: unsafe wallet zip entry",
        },
      }
    end,
  }
  local error_wizard = wizard_mod.open({
    handler = error_handler,
    seed = {
      wizard = {
        db_kind = "oracle",
        mode = "oracle_cloud_wallet",
        fields = {
          name = "SPSDB",
          wallet_path = "/tmp/Wallet_SPSDB.zip",
          service_alias = "DB_LOW",
          username = "user",
          password = "pass",
        },
      },
    },
  })
  error_wizard:test_connection()
  assert_eq("extraction error status", error_wizard.state.test_status, "failed")
  assert_true("extraction error surfaced", tostring(error_wizard.state.test_error):find("unsafe wallet zip", 1, true) ~= nil)
  record("WALLET_ZIP_EXTRACTION_ERROR_SURFACED", "true")
end

local function run_rpc_and_command_checks()
  install_api_state_stubs()
  local manifest = table.concat(vim.fn.readfile("lua/dbee/api/__register.lua"), "\n")
  for _, name in ipairs({
    "DbeeConnectionTestDetailed",
    "DbeeOracleWalletCacheClear",
    "DbeeOracleWalletSetAutoExtract",
  }) do
    assert_true("manifest contains " .. name, manifest:find(name, 1, true) ~= nil)
  end
  assert_true("core detailed wrapper", type(require("dbee.api.core").connection_test_detailed) == "function")
  assert_true("core cache clear wrapper", type(require("dbee.api.core").oracle_wallet_cache_clear) == "function")
  assert_true("core config sync wrapper", type(require("dbee.api.core").oracle_wallet_set_auto_extract) == "function")
  record("WALLET_ZIP_RPC_REGISTERED", "true")

  local Handler = require("dbee.handler")
  vim.fn.DbeeConnectionTestSpec = function()
    return vim.NIL
  end
  local h = Handler:new()
  assert_eq("legacy ping contract", h:connection_test_spec({ type = "oracle" }), nil)
  record("WALLET_ZIP_LEGACY_PING_CONTRACT_OK", "true")

  local clear_calls = 0
  local old_loaded = vim.g.loaded_dbee
  vim.g.loaded_dbee = nil
  package.loaded["dbee"] = {
    open = function() end,
    close = function() end,
    toggle = function() end,
    actions = function() end,
    execute = function()
      return nil, nil
    end,
    compile_object = function() end,
    execute_script = function() end,
    cancel_script = function() end,
    store = function() end,
    wallet_cache_clear = function()
      clear_calls = clear_calls + 1
    end,
  }
  dofile("plugin/dbee.lua")
  vim.cmd("DBeeWalletCacheClear")
  vim.cmd("Dbee wallet_cache_clear")
  vim.g.loaded_dbee = old_loaded
  package.loaded["dbee"] = nil
  assert_eq("cache clear command calls", clear_calls, 2)
  record("WALLET_ZIP_CACHE_CLEAR_COMMAND_OK", "true")
end

local function run_sync_checks()
  local state_text = table.concat(vim.fn.readfile("lua/dbee/api/state.lua"), "\n")
  local register_pos = state_text:find("register%(%)")
  local path_pos = state_text:find("vim%.env%.PATH")
  local sync_pos = path_pos and state_text:find("sync_oracle_wallet_auto_extract%(%)", path_pos)
  local handler_pos = path_pos and state_text:find("Handler:new", path_pos)
  assert_true("sync ordering positions", register_pos and path_pos and sync_pos and handler_pos)
  assert_true("register before path", register_pos < path_pos)
  assert_true("path before sync", path_pos < sync_pos)
  assert_true("sync before handler", sync_pos < handler_pos)
  record("WALLET_ZIP_DISABLE_SYNC_AFTER_PATH_PREPEND", "true")

  local Handler = require("dbee.handler")
  local order = {}
  local connections = {}
  local specs = {
    { id = "wallet-a", name = "Wallet A", type = "oracle", url = "oracle://u:p@h/s?wallet=/tmp/Wallet.zip" },
  }
  local source = {
    name = function()
      return "wallet-source"
    end,
    load = function()
      return vim.deepcopy(specs)
    end,
    create = function(_, details)
      specs[#specs + 1] = vim.deepcopy(details)
      return details.id
    end,
    update = function(_, conn_id, details)
      for index, spec in ipairs(specs) do
        if spec.id == conn_id then
          specs[index] = vim.deepcopy(details)
          return
        end
      end
    end,
  }

  vim.fn.DbeeGetCurrentConnection = function()
    return vim.NIL
  end
  vim.fn.DbeeGetConnections = function(ids)
    local out = {}
    for _, id in ipairs(ids or {}) do
      if connections[id] then
        out[#out + 1] = vim.deepcopy(connections[id])
      end
    end
    return out
  end
  vim.fn.DbeeDeleteConnection = function(id)
    connections[id] = nil
  end
  vim.fn.DbeeSetCurrentConnection = function() end
  vim.fn.DbeeClearCurrentConnection = function() end
  vim.fn.DbeeCreateConnection = function(spec)
    order[#order + 1] = "create:" .. spec.id
    connections[spec.id] = vim.deepcopy(spec)
    return spec.id
  end

  local function before_source_load()
    order[#order + 1] = "sync"
  end

  local handler = Handler:new({ source }, { before_source_load = before_source_load })
  assert_eq("initial source sync first", order[1], "sync")
  assert_true("initial source creates after sync", tostring(order[2] or ""):find("^create:") ~= nil)
  record("WALLET_ZIP_DISABLE_SYNC_BEFORE_SOURCE_LOAD", "true")

  local function assert_deferred(label, fn)
    order = {}
    fn()
    assert_eq(label .. " sync first", order[1], "sync")
    assert_true(label .. " creates after sync", tostring(order[2] or ""):find("^create:") ~= nil)
  end

  assert_deferred("source_reload", function()
    handler:source_reload("wallet-source")
  end)
  assert_deferred("source_add", function()
    handler:source_add_connection("wallet-source", {
      id = "wallet-b",
      name = "Wallet B",
      type = "oracle",
      url = "oracle://u:p@h/s?wallet=/tmp/Wallet.zip",
    })
  end)
  assert_deferred("source_update", function()
    handler:source_update_connection("wallet-source", "wallet-b", {
      id = "wallet-b",
      name = "Wallet B2",
      type = "oracle",
      url = "oracle://u:p@h/s?wallet=/tmp/Wallet.zip",
    })
  end)
  record("WALLET_ZIP_DISABLE_SYNC_BEFORE_DEFERRED_SOURCE_LOAD", "true")
end

run_wizard_checks()
run_rpc_and_command_checks()
run_sync_checks()

local required_true_markers = {
  "WALLET_ZIP_AUTO_EXTRACT_OK",
  "WALLET_ZIP_CACHE_HIT_REUSES",
  "WALLET_ZIP_CONTENT_HASH_DEDUPES",
  "WALLET_ZIP_MTIME_INVALIDATES",
  "WALLET_ZIP_STALE_FINAL_REPLACED",
  "WALLET_ZIP_SLIP_REJECTED",
  "WALLET_ZIP_SYMLINK_REJECTED",
  "WALLET_ZIP_BOMB_REJECTED",
  "WALLET_ZIP_MISSING_FILES_ERROR",
  "WALLET_ZIP_PERMISSIONS_LOCKED",
  "WALLET_ZIP_NON_ZIP_PASSTHROUGH",
  "WALLET_ZIP_MAGIC_BYTES_DETECTED",
  "WALLET_ZIP_TILDE_EXPANDS",
  "WALLET_ZIP_ATOMIC_RENAME_OK",
  "WALLET_ZIP_CONCURRENT_RESOLVE_OK",
  "WALLET_ZIP_CONN_URL_REWRITTEN",
  "WALLET_ZIP_DUPLICATE_WALLET_KEYS_NORMALIZED",
  "WALLET_ZIP_TEST_SUCCESS_MESSAGE_OK",
  "WALLET_ZIP_NO_FULL_PATH_DISCLOSURE",
  "WALLET_ZIP_DETAILED_TEST_META_OK",
  "WALLET_ZIP_LEGACY_PING_CONTRACT_OK",
  "WALLET_ZIP_WIZARD_HINT_OK",
  "WALLET_ZIP_RPC_REGISTERED",
  "WALLET_ZIP_DISABLE_FLAG_HONORED",
  "WALLET_ZIP_DISABLE_SYNC_BEFORE_SOURCE_LOAD",
  "WALLET_ZIP_DISABLE_SYNC_AFTER_PATH_PREPEND",
  "WALLET_ZIP_DISABLE_SYNC_BEFORE_DEFERRED_SOURCE_LOAD",
  "WALLET_ZIP_CACHE_CLEAR_COMMAND_OK",
  "WALLET_ZIP_EXTRACTION_ERROR_SURFACED",
  "WALLET_ZIP_NO_LIVE_ORACLE_DEPENDENCY",
  "WALLET_ZIP_PERF_DETERMINISTIC",
  "WALLET_ZIP_ROLLUP_GO_LUA_COMBINED",
  "WALLET_ZIP_ROLLUP_EXACTLY_ONCE_OK",
}

local numeric_markers = {
  WALLET_ZIP_CACHE_HIT_MS = 5,
  WALLET_ZIP_CACHE_HIT_TOTAL_P95_MS = 30,
  WALLET_ZIP_EXTRACT_MS = 500,
  WALLET_ZIP_REEXTRACT_MS = 500,
}

local function combined_markers()
  local markers = {}
  local go_log = os.getenv("WALLET_GO_LOG")
  if not go_log or go_log == "" then
    fail("WALLET_GO_LOG is required")
  end
  parse_marker_lines(read_file(go_log), markers)
  for key, values in pairs(emitted) do
    markers[key] = markers[key] or {}
    for _, value in ipairs(values) do
      markers[key][#markers[key] + 1] = value
    end
  end
  return markers
end

local function validate_markers(markers, include_exact)
  local failures = {}
  for _, marker in ipairs(required_true_markers) do
    if include_exact or marker ~= "WALLET_ZIP_ROLLUP_EXACTLY_ONCE_OK" then
      local values = markers[marker] or {}
      if #values ~= 1 then
        failures[#failures + 1] = marker .. " count=" .. tostring(#values)
      elseif values[1] ~= "true" then
        failures[#failures + 1] = marker .. " expected true got " .. tostring(values[1])
      end
    end
  end
  for marker, budget in pairs(numeric_markers) do
    local values = markers[marker] or {}
    if #values ~= 1 then
      failures[#failures + 1] = marker .. " count=" .. tostring(#values)
    else
      local value = tonumber(values[1])
      if not value or value ~= value or value == math.huge or value >= budget then
        failures[#failures + 1] = marker .. " expected finite < " .. tostring(budget) .. " got " .. tostring(values[1])
      end
    end
  end
  return failures
end

local markers = combined_markers()
local has_go = markers.WALLET_ZIP_AUTO_EXTRACT_OK and #markers.WALLET_ZIP_AUTO_EXTRACT_OK == 1
local has_lua = markers.WALLET_ZIP_WIZARD_HINT_OK and #markers.WALLET_ZIP_WIZARD_HINT_OK == 1
assert_true("combined go lua markers", has_go and has_lua)
record("WALLET_ZIP_ROLLUP_GO_LUA_COMBINED", "true")

markers = combined_markers()
local pre_exact_failures = validate_markers(markers, false)
if #pre_exact_failures > 0 then
  fail(table.concat(pre_exact_failures, "; "))
end
record("WALLET_ZIP_ROLLUP_EXACTLY_ONCE_OK", "true")

markers = combined_markers()
local final_failures = validate_markers(markers, true)
if #final_failures > 0 then
  fail(table.concat(final_failures, "; "))
end

record("WALLET_ZIP_ROLLUP_MARKERS_CHECKED", "37")
record("WALLET_ZIP_ALL_PASS", "true")
vim.cmd("qa!")
