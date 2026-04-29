local context = require("dbee.lsp.context")

local M = {}

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

--- Extract table references from SQL text and validate against cache.
---@param text string full buffer text
---@param cache SchemaCache
---@return table[] diagnostics
local function compute_diagnostics(text, cache)
  local diagnostics = {}
  local lines = vim.split(text, "\n")

  for line_idx, line in ipairs(lines) do
    -- find table refs after FROM/JOIN (case-insensitive)
    -- pattern: FROM/JOIN optional_schema.table_name
    for kw, rest in line:gmatch("([Ff][Rr][Oo][Mm]%s+)(.-)$") do
      -- extract first table reference
      local schema_part, tbl = rest:match("^([%w_]+)%.([%w_]+)")
      if schema_part and tbl then
        local actual, _ = cache:find_table(tbl)
        if not actual then
          local col_start = #kw + line:find(kw, 1, true) - 1
          diagnostics[#diagnostics + 1] = {
            range = {
              start = { line = line_idx - 1, character = #kw },
              ["end"] = { line = line_idx - 1, character = #kw + #schema_part + 1 + #tbl },
            },
            severity = DiagnosticSeverity.Warning,
            source = "dbee-lsp",
            message = string.format("Unknown table: %s.%s", schema_part, tbl),
          }
        end
      else
        tbl = rest:match("^([%w_]+)")
        if tbl and #tbl > 0 then
          local actual, _ = cache:find_table(tbl)
          if not actual then
            diagnostics[#diagnostics + 1] = {
              range = {
                start = { line = line_idx - 1, character = #kw },
                ["end"] = { line = line_idx - 1, character = #kw + #tbl },
              },
              severity = DiagnosticSeverity.Warning,
              source = "dbee-lsp",
              message = string.format("Unknown table: %s", tbl),
            }
          end
        end
      end
    end

    -- same for JOIN variants
    for kw, rest in line:gmatch("([Jj][Oo][Ii][Nn]%s+)(.-)$") do
      local schema_part, tbl = rest:match("^([%w_]+)%.([%w_]+)")
      if schema_part and tbl then
        local actual, _ = cache:find_table(tbl)
        if not actual then
          diagnostics[#diagnostics + 1] = {
            range = {
              start = { line = line_idx - 1, character = line:find(kw, 1, true) + #kw - 1 },
              ["end"] = { line = line_idx - 1, character = line:find(kw, 1, true) + #kw - 1 + #schema_part + 1 + #tbl },
            },
            severity = DiagnosticSeverity.Warning,
            source = "dbee-lsp",
            message = string.format("Unknown table: %s.%s", schema_part, tbl),
          }
        end
      else
        tbl = rest:match("^([%w_]+)")
        if tbl and #tbl > 0 then
          local actual, _ = cache:find_table(tbl)
          if not actual then
            local kw_pos = line:find("[Jj][Oo][Ii][Nn]")
            if kw_pos then
              local after_kw = line:sub(kw_pos):match("^%w+%s+()")
              if after_kw then
                local char_start = kw_pos - 1 + after_kw - 1
                diagnostics[#diagnostics + 1] = {
                  range = {
                    start = { line = line_idx - 1, character = char_start },
                    ["end"] = { line = line_idx - 1, character = char_start + #tbl },
                  },
                  severity = DiagnosticSeverity.Warning,
                  source = "dbee-lsp",
                  message = string.format("Unknown table: %s", tbl),
                }
              end
            end
          end
        end
      end
    end
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

  return function(dispatchers, config)
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
          if dispatchers and dispatchers.on_exit then
            dispatchers.on_exit(0, 0)
          end
        elseif method == "textDocument/didSave" or method == "textDocument/didChange" then
          -- publish diagnostics on save or change
          vim.schedule(function()
            local uri = params.textDocument.uri
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
            local notify = dispatchers and (dispatchers.notification or dispatchers.on_notify)
            if notify then
              notify("textDocument/publishDiagnostics", {
                uri = uri,
                diagnostics = diags,
              })
            end
          end)
        end
        return true
      end,

      is_closing = function()
        return closing
      end,

      terminate = function()
        closing = true
      end,
    }
  end
end

return M
