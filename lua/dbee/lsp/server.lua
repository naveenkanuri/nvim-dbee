local context = require("dbee.lsp.context")

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

--- Build completion items for table names.
---@param cache SchemaCache
---@param schema string? specific schema to filter by
---@return lsp.CompletionItem[]
local function table_completions(cache, schema)
  if schema then
    return cache:get_table_completion_items(schema)
  end

  return cache:get_all_table_completion_items()
end

--- Build completion items for column names of a specific table.
---@param cache SchemaCache
---@param table_ref string table name or alias
---@param alias_info table? { table: string, schema: string? }
---@return table result
local function column_completions(cache, table_ref, alias_info)
  local tbl_name = table_ref

  if alias_info then
    tbl_name = alias_info.table
  end

  local cols = nil
  local actual_name, actual_schema = nil, nil

  if alias_info and alias_info.schema then
    -- Explicit schema-qualified aliases should stay in that schema. Resolve
    -- schema/table case-insensitively against cache, then queue async warmup
    -- if metadata cache doesn't contain that schema/table yet.
    actual_name, actual_schema = cache:find_table_in_schema(alias_info.schema, tbl_name)
    if actual_name then
      cols = cache:get_columns_async(actual_schema, actual_name)
    else
      cols = cache:get_columns_async(alias_info.schema, tbl_name, {
        probe_if_missing = true,
        materializations = { "table", "view" },
      })
    end
  else
    -- Unqualified table or alias: use global table resolution.
    actual_name, actual_schema = cache:find_table(tbl_name)
    if actual_name then
      cols = cache:get_columns_async(actual_schema, actual_name)
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
    return completion_result(cache:get_column_completion_items(actual_schema, actual_name), false)
  end

  return completion_result({}, false)
end

--- Build completion items from already-cached columns only (no lazy loading).
---@param cache SchemaCache
---@return lsp.CompletionItem[]
local function all_column_completions(cache)
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
  return cache:get_schema_completion_items()
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
      local schema_result = cache:get_schema_table_completion_async(extra)
      return completion_result(schema_result.items or {}, schema_result.is_incomplete == true)
    end
    return completion_result(table_completions(cache, extra), false)
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

  local function keyword_pattern(keyword)
    local parts = {}
    for i = 1, #keyword do
      local ch = keyword:sub(i, i)
      parts[#parts + 1] = "[" .. ch:lower() .. ch:upper() .. "]"
    end
    return table.concat(parts)
  end

  local function add_unknown(statement, ref, ref_start)
    local schema_part, tbl = ref:match("^([%w_]+)%.([%w_]+)$")
    local missing = false
    local message
    if schema_part and tbl then
      if type(cache.schema_status) == "function" then
        local status = cache:schema_status(schema_part)
        if status == "filtered_out" then
          diagnostics[#diagnostics + 1] = {
            range = {
              start = context.statement_offset_to_position(statement, ref_start),
              ["end"] = context.statement_offset_to_position(statement, ref_start + #schema_part),
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
      local actual = cache:find_table_in_schema(schema_part, tbl)
      missing = actual == nil
      message = string.format("Unknown table: %s.%s", schema_part, tbl)
    else
      tbl = ref:match("^([%w_]+)$")
      if not tbl then
        return
      end
      local actual = cache:find_table(tbl)
      missing = actual == nil
      message = string.format("Unknown table: %s", tbl)
    end

    if not missing then
      return
    end

    diagnostics[#diagnostics + 1] = {
      range = {
        start = context.statement_offset_to_position(statement, ref_start),
        ["end"] = context.statement_offset_to_position(statement, ref_start + #ref),
      },
      severity = DiagnosticSeverity.Warning,
      source = "dbee-lsp",
      message = message,
    }
  end

  local function scan_statement(statement, keyword)
    local pattern = "()%f[%a]" .. keyword_pattern(keyword) .. "%f[%A]%s+()([%w_%.]+)"
    local init = 1
    while true do
      local match_start, match_end, _, ref_start, ref = statement.text:find(pattern, init)
      if not match_start then
        break
      end
      add_unknown(statement, ref, ref_start)
      init = match_end + 1
    end
  end

  for _, statement in ipairs(context.extract_statements(text)) do
    scan_statement(statement, "from")
    scan_statement(statement, "join")
  end

  return diagnostics
end

--- Create an in-process LSP RPC client.
--- Returns a function suitable for vim.lsp.start({ cmd = ... }).
---@param cache SchemaCache
---@return fun(dispatchers: table, config: table): table
function M.create(cache)
  local closing = false
  local msg_id = 0
  local diagnostic_timers = {}
  local diagnostic_buffers = {}

  return function(dispatchers, config)
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
      local ok, diags = pcall(compute_diagnostics, text, cache)
      if not ok then
        diags = {}
      end
      publish_diagnostics(uri, diags)
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
          callback(nil, {
            capabilities = {
              completionProvider = {
                triggerCharacters = { ".", " " },
                resolveProvider = false,
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
        else
          callback(nil, nil)
        end

        return true, current_id
      end,

      notify = function(method, params)
        if method == "exit" then
          closing = true
          clear_all_diagnostics()
          if dispatchers and dispatchers.on_exit then
            dispatchers.on_exit(0, 0)
          end
        elseif method == "textDocument/didSave" or method == "textDocument/didChange" then
          handle_diagnostics(method, params)
        end
        return true
      end,

      is_closing = function()
        return closing
      end,

      terminate = function()
        closing = true
        clear_all_diagnostics()
      end,
    }
  end
end

return M
