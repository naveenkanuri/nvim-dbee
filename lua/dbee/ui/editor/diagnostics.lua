local M = {}

---@class dbee_diag_entry
---@field adapter string
---@field parser fun(err_msg: string, ctx: dbee_diag_ctx): dbee_diag_result|nil
---@field sql boolean
---@field aliases string[]

---@type table<string, dbee_diag_entry>
local entries = {}
---@type table<string, string>
local canonical_by_name = {}

---@param adapter string
---@return string
local function normalize_adapter(adapter)
  return tostring(adapter or ""):lower()
end

---@param message string
---@param ctx dbee_diag_ctx
---@param rel_line integer
---@param rel_col integer
---@return dbee_diag_result
local function make_result(message, ctx, rel_line, rel_col)
  local start_line = tonumber(ctx and ctx.start_line or 0) or 0
  local start_col = tonumber(ctx and ctx.start_col or 0) or 0
  local line = math.max(start_line + math.max(rel_line, 1) - 1, 0)
  local col = math.max(math.max(rel_col, 1) - 1, 0)
  if rel_line == 1 then
    col = start_col + col
  end

  return {
    line = line,
    col = col,
    message = message,
    severity = vim.diagnostic.severity.ERROR,
  }
end

---@param position integer
---@param resolved_query string
---@return integer?
---@return integer?
local function position_to_line_col(position, resolved_query)
  if type(resolved_query) ~= "string" or resolved_query == "" then
    return nil, nil
  end
  if position < 1 or position > (#resolved_query + 1) then
    return nil, nil
  end

  local prefix = resolved_query:sub(1, position - 1)
  local _, newline_count = prefix:gsub("\n", "\n")
  local line = newline_count + 1
  local last_newline = prefix:match(".*()\n") or 0

  local col = (#prefix - last_newline) + 1
  return line, col
end

---@param adapter string
---@param err_msg string
---@param ctx dbee_diag_ctx
---@return dbee_diag_result
local function build_fallback(adapter, err_msg, ctx)
  local message = tostring(err_msg or "")
  if message == "" then
    message = "query failed"
  end
  return make_result(("[%s] %s"):format(adapter, message), ctx, 1, 1)
end

---@param err_msg string
---@param ctx dbee_diag_ctx
---@return dbee_diag_result|nil
local function postgres_parser(err_msg, ctx)
  local position = tonumber(tostring(err_msg or ""):match("POSITION:%s*(%d+)"))
  if not position then
    return nil
  end

  local line, col = position_to_line_col(position, ctx and ctx.resolved_query or nil)
  if not line or not col then
    return nil
  end

  return make_result(err_msg, ctx, line, col)
end

---@param err_msg string
---@param ctx dbee_diag_ctx
---@return dbee_diag_result|nil
local function mysql_parser(err_msg, ctx)
  local line = tonumber(tostring(err_msg or ""):match("[Ll][Ii][Nn][Ee]%s+(%d+)"))
  if not line then
    return nil
  end
  return make_result(err_msg, ctx, line, 1)
end

---@param err_msg string
---@param ctx dbee_diag_ctx
---@return dbee_diag_result|nil
local function sqlserver_parser(err_msg, ctx)
  local line = tonumber(tostring(err_msg or ""):match("[Ll][Ii][Nn][Ee]%s+(%d+)"))
  if not line then
    return nil
  end
  return make_result(err_msg, ctx, line, 1)
end

---@param err_msg string
---@param ctx dbee_diag_ctx
---@return dbee_diag_result|nil
local function oracle_parser(err_msg, ctx)
  local message = tostring(err_msg or "")
  local line, col = message:match("line%s+(%d+),?%s*column%s+(%d+)")
  if not line or not col then
    line, col = message:match("line%s+(%d+),?%s*col%s+(%d+)")
  end
  if line and col then
    return make_result(err_msg, ctx, tonumber(line), tonumber(col))
  end

  line, col = message:match("%[L(%d+):C(%d+)%]")
  if line and col then
    return make_result(err_msg, ctx, tonumber(line), tonumber(col))
  end

  line = message:match("[Aa][Tt]%s+[Ll][Ii][Nn][Ee]%s+(%d+)")
  if line then
    return make_result(err_msg, ctx, tonumber(line), 1)
  end

  line = message:match("[Ll][Ii][Nn][Ee]%s+(%d+)")
  if line then
    return make_result(err_msg, ctx, tonumber(line), 1)
  end

  return nil
end

---@param adapter string
---@param parser fun(err_msg: string, ctx: dbee_diag_ctx): dbee_diag_result|nil
---@param opts dbee_diag_parser_opts
function M.register_parser(adapter, parser, opts)
  local canonical = normalize_adapter(adapter)
  if canonical == "" then
    error("register_parser requires adapter")
  end
  opts = opts or {}
  if type(opts.sql) ~= "boolean" then
    error(("register_parser(%s) requires boolean opts.sql"):format(canonical))
  end

  local names = { canonical }
  for _, alias in ipairs(opts.aliases or {}) do
    names[#names + 1] = normalize_adapter(alias)
  end

  for _, name in ipairs(names) do
    if name == "" then
      error(("register_parser(%s) has empty alias"):format(canonical))
    end
    if canonical_by_name[name] then
      error(("duplicate diagnostics parser registration: %s"):format(name))
    end
  end

  local entry = {
    adapter = canonical,
    parser = parser,
    sql = opts.sql,
    aliases = vim.deepcopy(opts.aliases or {}),
  }
  entries[canonical] = entry
  for _, name in ipairs(names) do
    canonical_by_name[name] = canonical
  end
end

---@param adapter string
---@return boolean
function M.is_sql_adapter(adapter)
  local canonical = canonical_by_name[normalize_adapter(adapter)]
  if not canonical then
    return false
  end
  local entry = entries[canonical]
  return entry ~= nil and entry.sql == true
end

---@param adapter string
---@param err_msg string
---@param ctx dbee_diag_ctx
---@return dbee_diag_result|nil
function M.build_diagnostic(adapter, err_msg, ctx)
  local normalized = normalize_adapter(adapter)
  local canonical = canonical_by_name[normalized]
  if not canonical then
    return nil
  end

  local entry = entries[canonical]
  if not entry or not entry.sql then
    return nil
  end

  if entry.parser then
    local parsed = entry.parser(err_msg, ctx or {})
    if parsed then
      parsed.severity = vim.diagnostic.severity.ERROR
      return parsed
    end
  end

  return build_fallback(canonical, err_msg, ctx or {})
end

M.register_parser("postgres", postgres_parser, { sql = true, aliases = { "pg", "postgresql" } })
M.register_parser("mysql", mysql_parser, { sql = true })
M.register_parser("sqlite", nil, { sql = true, aliases = { "sqlite3" } })
M.register_parser("sqlserver", sqlserver_parser, { sql = true, aliases = { "mssql" } })
M.register_parser("oracle", oracle_parser, { sql = true })
M.register_parser("duck", nil, { sql = true, aliases = { "duckdb" } })
M.register_parser("bigquery", nil, { sql = true })
M.register_parser("clickhouse", nil, { sql = true })
M.register_parser("databricks", nil, { sql = true })
M.register_parser("redshift", nil, { sql = true })

return M
