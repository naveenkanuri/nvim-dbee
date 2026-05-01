local context = require("dbee.lsp.context")
local code_actions = require("dbee.lsp.code_actions")
local epoch_authority = require("dbee.lsp.epoch_authority")
local hover = require("dbee.lsp.hover")
local resolve = require("dbee.lsp.resolve")
local symbols = require("dbee.lsp.symbols")

local M = {}
local DIAGNOSTIC_NS = vim.api.nvim_create_namespace("dbee/lsp")

local CompletionItemKind = {
  Text = 1,
  Method = 2,
  Function = 3,
  Field = 5,
  Variable = 6,
  Class = 7,
  Module = 9,
  Property = 10,
  Unit = 11,
  Keyword = 14,
  Snippet = 15,
  Folder = 19,
  EnumMember = 20,
  Struct = 22,
}

local function completion_result(items, is_incomplete)
  return {
    items = items or {},
    isIncomplete = is_incomplete == true,
  }
end

---@param cache SchemaCache
---@return boolean
local function cache_fresh(cache)
  local check = epoch_authority.check_fresh(cache, cache and cache.handler, cache and cache.conn_id)
  return check.fresh
end

--- Build completion items for table names.
---@param cache SchemaCache
---@param schema string? specific schema to filter by
---@param opts? table
---@return lsp.CompletionItem[]
local function table_completions(cache, schema, opts)
  if not cache_fresh(cache) then
    return {}
  end
  opts = opts or {}
  opts.include_data = true
  if schema then
    return cache:get_table_completion_items(schema, opts)
  end

  return cache:get_all_table_completion_items({ include_data = true })
end

--- Build completion items for column names of a specific table.
---@param cache SchemaCache
---@param table_ref string table name or alias
---@param alias_info table? { table: string, schema: string? }
---@return table result
local function column_completions(cache, table_ref, alias_info)
  if not cache_fresh(cache) then
    return completion_result({}, false)
  end

  local tbl_name = table_ref

  if alias_info then
    tbl_name = alias_info.table
  end

  local cols = nil
  local actual_name, actual_schema = nil, nil

  if alias_info and alias_info.schema then
    -- Explicit schema-qualified aliases should stay in that schema. Resolve
    -- schema/table according to quote metadata, then queue async warmup if
    -- metadata cache doesn't contain that schema/table yet.
    actual_name, actual_schema = cache:find_table_in_schema(alias_info.schema, tbl_name, {
      schema_quoted = alias_info.schema_quoted,
      table_quoted = alias_info.table_quoted,
    })
    if actual_name then
      cols = cache:get_columns_async(actual_schema, actual_name, {
        schema_quoted = true,
        table_quoted = true,
      })
    else
      cols = cache:get_columns_async(alias_info.schema, tbl_name, {
        schema_quoted = alias_info.schema_quoted,
        table_quoted = alias_info.table_quoted,
        probe_if_missing = true,
        materializations = { "table", "view" },
      })
    end
  else
    -- Unqualified table or alias: use global table resolution.
    actual_name, actual_schema = cache:find_table(tbl_name, {
      table_quoted = alias_info and alias_info.table_quoted,
    })
    if actual_name then
      cols = cache:get_columns_async(actual_schema, actual_name, {
        schema_quoted = true,
        table_quoted = true,
      })
    end
  end

  if not cols then
    return completion_result({}, false)
  end

  if cols.is_incomplete then
    return completion_result({}, true)
  end

  actual_schema = actual_schema or cols.resolved_schema
  actual_name = actual_name or cols.resolved_name
  if actual_schema and actual_name then
    return completion_result(cache:get_column_completion_items(actual_schema, actual_name, {
      schema_quoted = true,
      table_quoted = true,
      include_data = true,
    }), false)
  end

  return completion_result({}, false)
end

--- Build completion items from already-cached columns only (no lazy loading).
---@param cache SchemaCache
---@return lsp.CompletionItem[]
local function all_column_completions(cache)
  if not cache_fresh(cache) then
    return {}
  end

  local items = {}
  local seen = {}

  for key, cols in pairs(cache:get_cached_columns()) do
    local tbl_name = key:match("%.(.+)$") or key
    for _, col in ipairs(cols) do
      if not seen[col.name] then
        seen[col.name] = true
        items[#items + 1] = {
          label = col.name,
          kind = CompletionItemKind.Field,
          detail = col.type .. " (" .. tbl_name .. ")",
          insertText = col.name,
          sortText = "1_" .. col.name,
        }
      end
    end
  end

  return items
end

--- Build completion items for schema names.
---@param cache SchemaCache
---@return lsp.CompletionItem[]
local function schema_completions(cache)
  if not cache_fresh(cache) then
    return {}
  end
  return cache:get_schema_completion_items({ include_data = true })
end

--- Build completion items for SQL keywords.
---@return lsp.CompletionItem[]
local function keyword_completions()
  local items = {}
  for _, kw in ipairs(context.keywords) do
    items[#items + 1] = {
      label = kw,
      kind = CompletionItemKind.Keyword,
      insertText = kw,
      sortText = "2_" .. kw,
    }
  end
  return items
end

--- Get completion items based on cursor context.
---@param params table
---@param cache SchemaCache
---@return table result
local function get_completions(params, cache)
  local ctx, extra, alias_info = context.analyze(params)

  if ctx == "table" then
    local items = table_completions(cache, nil)
    -- also include schemas for qualified completion
    vim.list_extend(items, vim.deepcopy(schema_completions(cache)))
    return completion_result(items, false)
  end

  if ctx == "table_in_schema" then
    if type(cache.get_schema_table_completion_async) == "function" then
      alias_info = alias_info or {}
      alias_info.include_data = true
      local schema_result = cache:get_schema_table_completion_async(extra, alias_info)
      return completion_result(schema_result.items or {}, schema_result.is_incomplete == true)
    end
    return completion_result(table_completions(cache, extra, alias_info), false)
  end

  if ctx == "column_of_table" then
    return column_completions(cache, extra, alias_info)
  end

  if ctx == "column" then
    -- provide columns from all loaded tables + table names for table.column
    local items = all_column_completions(cache)
    vim.list_extend(items, vim.deepcopy(table_completions(cache, nil)))
    return completion_result(items, false)
  end

  if ctx == "schema" then
    return completion_result(schema_completions(cache), false)
  end

  -- keyword fallback
  local items = keyword_completions()
  vim.list_extend(items, vim.deepcopy(table_completions(cache, nil)))
  return completion_result(items, false)
end

local DiagnosticSeverity = {
  Error = 1,
  Warning = 2,
  Information = 3,
  Hint = 4,
}

local function get_lsp_diagnostics_config()
  local defaults = {
    diagnostics_mode = "debounce_didchange",
    diagnostics_debounce_ms = 250,
  }
  local ok, state = pcall(require, "dbee.api.state")
  if not ok or not state or type(state.config) ~= "function" then
    return defaults
  end
  local config_ok, cfg = pcall(state.config)
  local lsp = config_ok and cfg and cfg.lsp or nil
  if type(lsp) ~= "table" then
    return defaults
  end
  return {
    diagnostics_mode = lsp.diagnostics_mode or defaults.diagnostics_mode,
    diagnostics_debounce_ms = lsp.diagnostics_debounce_ms or defaults.diagnostics_debounce_ms,
  }
end

local function get_lsp_feature_config(opts)
  local defaults = {
    hover = true,
    resolve = true,
    document_symbols = true,
    workspace_symbols = true,
    code_actions = true,
    code_action_expand_select_star = true,
    code_action_qualify_identifier = true,
    code_action_refresh_schema = true,
    code_action_reload_table_metadata = true,
    code_action_max_expand_columns = 200,
  }
  if opts and type(opts.lsp) == "table" then
    return {
      hover = opts.lsp.hover ~= false,
      resolve = opts.lsp.resolve ~= false,
      document_symbols = opts.lsp.document_symbols ~= false,
      workspace_symbols = opts.lsp.workspace_symbols ~= false,
      code_actions = opts.lsp.code_actions ~= false,
      code_action_expand_select_star = opts.lsp.code_action_expand_select_star ~= false,
      code_action_qualify_identifier = opts.lsp.code_action_qualify_identifier ~= false,
      code_action_refresh_schema = opts.lsp.code_action_refresh_schema ~= false,
      code_action_reload_table_metadata = opts.lsp.code_action_reload_table_metadata ~= false,
      code_action_max_expand_columns = tonumber(opts.lsp.code_action_max_expand_columns) or 200,
    }
  end
  local ok, state = pcall(require, "dbee.api.state")
  if not ok or not state or type(state.config) ~= "function" then
    return defaults
  end
  local config_ok, cfg = pcall(state.config)
  local lsp = config_ok and cfg and cfg.lsp or nil
  if type(lsp) ~= "table" then
    return defaults
  end
  return {
    hover = lsp.hover ~= false,
    resolve = lsp.resolve ~= false,
    document_symbols = lsp.document_symbols ~= false,
    workspace_symbols = lsp.workspace_symbols ~= false,
    code_actions = lsp.code_actions ~= false,
    code_action_expand_select_star = lsp.code_action_expand_select_star ~= false,
    code_action_qualify_identifier = lsp.code_action_qualify_identifier ~= false,
    code_action_refresh_schema = lsp.code_action_refresh_schema ~= false,
    code_action_reload_table_metadata = lsp.code_action_reload_table_metadata ~= false,
    code_action_max_expand_columns = tonumber(lsp.code_action_max_expand_columns) or 200,
  }
end

---@param feature_config table
---@return table?
local function execute_command_provider(feature_config)
  if feature_config.code_actions == false then
    return nil
  end
  local commands = code_actions.enabled_commands(feature_config)
  if #commands == 0 then
    return nil
  end
  return { commands = commands }
end

local function to_vim_diagnostics(diagnostics)
  local converted = {}
  for _, diagnostic in ipairs(diagnostics or {}) do
    local range = diagnostic.range or {}
    local start = range.start or {}
    local finish = range["end"] or {}
    converted[#converted + 1] = {
      lnum = start.line or 0,
      col = start.character or 0,
      end_lnum = finish.line or start.line or 0,
      end_col = finish.character or start.character or 0,
      severity = diagnostic.severity,
      source = diagnostic.source,
      message = diagnostic.message,
    }
  end
  return converted
end

function M.diagnostic_namespace()
  return DIAGNOSTIC_NS
end

---@param bufnr? integer
function M.clear_diagnostics(bufnr)
  if bufnr then
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.diagnostic.set(DIAGNOSTIC_NS, bufnr, {})
    end
    return
  end

  for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buffer) then
      vim.diagnostic.set(DIAGNOSTIC_NS, buffer, {})
    end
  end
end

--- Extract table references from SQL text and validate against cache.
---@param text string full buffer text
---@param cache SchemaCache
---@return table[] diagnostics
local function compute_diagnostics(text, cache)
  local diagnostics = {}

  local function add_unknown(statement, ref)
    local raw_ref = ref and ref.ref or ""
    local missing = false
    local message
    if ref and ref.schema then
      local schema_part = ref.schema
      local tbl = ref.table
      if type(cache.schema_status) == "function" then
        local status = cache:schema_status(schema_part, { schema_quoted = ref.schema_quoted })
        if status == "filtered_out" then
          diagnostics[#diagnostics + 1] = {
            range = {
              start = ref.schema_range and ref.schema_range.start
                or context.statement_offset_to_position(statement, ref.ref_start),
              ["end"] = ref.schema_range and ref.schema_range["end"]
                or context.statement_offset_to_position(statement, ref.ref_start + #schema_part),
            },
            severity = DiagnosticSeverity.Information,
            source = "dbee-lsp",
            message = string.format("Schema %s is outside this connection's scope. Edit schema_filter to include.", schema_part),
          }
          return
        elseif status == "active_unloaded" then
          return
        end
      end
      local actual = cache:find_table_in_schema(schema_part, tbl, {
        schema_quoted = ref.schema_quoted,
        table_quoted = ref.table_quoted,
      })
      missing = actual == nil
      message = string.format("Unknown table: %s.%s", schema_part, tbl)
    else
      if not ref or not ref.table then
        return
      end
      local tbl = ref.table
      local actual = cache:find_table(tbl, { table_quoted = ref.table_quoted })
      missing = actual == nil
      if missing and type(cache.has_unloaded_active_schemas) == "function" and cache:has_unloaded_active_schemas() then
        return
      end
      message = string.format("Unknown table: %s", tbl)
    end

    if not missing then
      return
    end

    diagnostics[#diagnostics + 1] = {
      range = {
        start = ref.ref_range and ref.ref_range.start
          or context.statement_offset_to_position(statement, ref.ref_start),
        ["end"] = ref.ref_range and ref.ref_range["end"]
          or context.statement_offset_to_position(statement, ref.ref_end or (ref.ref_start + #raw_ref)),
      },
      severity = DiagnosticSeverity.Warning,
      source = "dbee-lsp",
      message = message,
    }
  end

  for _, statement in ipairs(context.extract_statements(text)) do
    for _, ref in ipairs(context.statement_table_refs(statement)) do
      add_unknown(statement, ref)
    end
  end

  return diagnostics
end

--- Create an in-process LSP RPC client.
--- Returns a function suitable for vim.lsp.start({ cmd = ... }).
---@param cache SchemaCache
---@param opts? table
---@return fun(dispatchers: table, config: table): table
function M.create(cache, opts)
  local closing = false
  local msg_id = 0
  local diagnostic_timers = {}
  local diagnostic_buffers = {}
  local feature_config = get_lsp_feature_config(opts)
  local resolve_memo = {}
  local client_capabilities = nil
  local document_versions = {}

  return function(dispatchers, config)
    local diagnostic_refresh_scheduled = false

    local function schedule_diagnostic_refresh()
      if diagnostic_refresh_scheduled then
        return
      end
      diagnostic_refresh_scheduled = true
      vim.schedule(function()
        diagnostic_refresh_scheduled = false
        if closing then
          return
        end
        if dispatchers and type(dispatchers.server_request) == "function" then
          pcall(dispatchers.server_request, "workspace/diagnostic/refresh", vim.empty_dict())
        end
      end)
    end

    local function emit_columns_loaded(payload)
      if closing then
        return
      end
      if dispatchers and type(dispatchers.notification) == "function" then
        pcall(dispatchers.notification, "dbee/columnsLoaded", payload)
      end
      schedule_diagnostic_refresh()
    end

    if cache and type(cache.set_completion_refresh_notifier) == "function" then
      cache:set_completion_refresh_notifier(emit_columns_loaded)
    end

    local function clear_completion_refresh_notifier()
      if cache and type(cache.set_completion_refresh_notifier) == "function" then
        cache:set_completion_refresh_notifier(nil)
      end
    end

    local function clear_timer(uri)
      local timer = diagnostic_timers[uri]
      if timer then
        timer:stop()
        timer:close()
        diagnostic_timers[uri] = nil
      end
    end

    local function clear_all_diagnostics()
      for bufnr in pairs(diagnostic_buffers) do
        M.clear_diagnostics(bufnr)
      end
      diagnostic_buffers = {}
      for uri in pairs(diagnostic_timers) do
        clear_timer(uri)
      end
    end

    local function publish_diagnostics(uri, diagnostics)
      local bufnr = vim.uri_to_bufnr(uri)
      if vim.api.nvim_buf_is_valid(bufnr) then
        diagnostic_buffers[bufnr] = true
        vim.diagnostic.set(DIAGNOSTIC_NS, bufnr, to_vim_diagnostics(diagnostics))
      end
    end

    local function compute_and_publish(uri)
      local bufnr = vim.uri_to_bufnr(uri)
      if not vim.api.nvim_buf_is_valid(bufnr) then
        return
      end
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      local text = table.concat(lines, "\n")
      local diags = epoch_authority.read_with_freshness(cache, cache and cache.handler, cache and cache.conn_id, function()
        local ok, computed = pcall(compute_diagnostics, text, cache)
        if not ok then
          return {}
        end
        return computed or {}
      end)
      publish_diagnostics(uri, diags or {})
    end

    local function handle_diagnostics(method, params)
      local cfg = get_lsp_diagnostics_config()
      local mode = cfg.diagnostics_mode or "debounce_didchange"
      local uri = params.textDocument.uri
      if mode == "off" then
        clear_timer(uri)
        publish_diagnostics(uri, {})
        return
      end
      if method == "textDocument/didSave" then
        clear_timer(uri)
        compute_and_publish(uri)
        return
      end
      if mode == "save_only" then
        return
      end

      clear_timer(uri)
      local timer = (vim.uv or vim.loop).new_timer()
      diagnostic_timers[uri] = timer
      timer:start(cfg.diagnostics_debounce_ms or 250, 0, function()
        clear_timer(uri)
        vim.schedule(function()
          compute_and_publish(uri)
        end)
      end)
    end

    return {
      request = function(method, params, callback, notify_reply_callback)
        msg_id = msg_id + 1
        local current_id = msg_id

        if method == "initialize" then
          client_capabilities = params and params.capabilities or nil
          callback(nil, {
            capabilities = {
              hoverProvider = feature_config.hover and true or nil,
              documentSymbolProvider = feature_config.document_symbols and true or nil,
              workspaceSymbolProvider = feature_config.workspace_symbols and true or nil,
              codeActionProvider = feature_config.code_actions and true or nil,
              executeCommandProvider = execute_command_provider(feature_config),
              completionProvider = {
                triggerCharacters = { ".", " " },
                resolveProvider = feature_config.resolve == true,
              },
              textDocumentSync = {
                openClose = true,
                change = 1, -- full sync
              },
            },
            serverInfo = {
              name = "dbee-lsp",
              version = "0.1.0",
            },
          })
        elseif method == "shutdown" then
          closing = true
          callback(nil, nil)
        elseif method == "textDocument/hover" then
          local ok, result = pcall(hover.handle, params, cache, {
            enabled = feature_config.hover,
            client_capabilities = client_capabilities,
          })
          if not ok then
            result = nil
          end
          callback(nil, result)
        elseif method == "textDocument/completion" then
          -- Completion must stay cache/async-only; sync column misses are not
          -- allowed on the request path.
          local ok, result = pcall(get_completions, params, cache)
          if not ok then
            result = completion_result({}, false)
          end
          callback(nil, {
            items = result.items or {},
            isIncomplete = result.isIncomplete == true,
          })
        elseif method == "completionItem/resolve" then
          local ok, result = pcall(resolve.handle, params, cache, {
            enabled = feature_config.resolve,
            client_capabilities = client_capabilities,
            memo = resolve_memo,
          })
          if not ok then
            result = params
          end
          callback(nil, result)
        elseif method == "textDocument/documentSymbol" then
          local ok, result = pcall(symbols.handle_document_symbol, params, cache, {
            enabled = feature_config.document_symbols,
            client_capabilities = client_capabilities,
          })
          if not ok then
            result = nil
          end
          callback(nil, result)
        elseif method == "workspace/symbol" then
          local ok, result = pcall(symbols.handle_workspace_symbol, params, cache, {
            enabled = feature_config.workspace_symbols,
            client_capabilities = client_capabilities,
          })
          if not ok then
            result = {}
          end
          callback(nil, result)
        elseif method == "textDocument/codeAction" then
          local ok, result = pcall(code_actions.handle_code_action, params, cache, {
            lsp = feature_config,
            document_versions = document_versions,
          })
          if not ok then
            result = {}
          end
          callback(nil, result)
        elseif method == "workspace/executeCommand" then
          local ok, result = pcall(code_actions.execute_command, params, cache, {
            lsp = feature_config,
            commands = opts and opts.code_action_commands or nil,
          })
          if not ok then
            result = nil
          end
          callback(nil, result)
        else
          callback(nil, nil)
        end

        return true, current_id
      end,

      notify = function(method, params)
        if method == "exit" then
          closing = true
          clear_completion_refresh_notifier()
          clear_all_diagnostics()
          if dispatchers and dispatchers.on_exit then
            dispatchers.on_exit(0, 0)
          end
        elseif method == "textDocument/didOpen" then
          if params and params.textDocument then
            document_versions[params.textDocument.uri] = params.textDocument.version
          end
          handle_diagnostics(method, params)
        elseif method == "textDocument/didSave" or method == "textDocument/didChange" then
          if method == "textDocument/didChange" and params and params.textDocument then
            document_versions[params.textDocument.uri] = params.textDocument.version
            symbols.invalidate_document(params.textDocument.uri)
          end
          handle_diagnostics(method, params)
        elseif method == "textDocument/didClose" then
          if params and params.textDocument then
            document_versions[params.textDocument.uri] = nil
            symbols.invalidate_document(params.textDocument.uri)
          end
        end
        return true
      end,

      is_closing = function()
        return closing
      end,

      terminate = function()
        closing = true
        clear_completion_refresh_notifier()
        clear_all_diagnostics()
      end,
    }
  end
end

return M
