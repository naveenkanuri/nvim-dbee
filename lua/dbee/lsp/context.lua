--- SQL cursor context analysis for completion.
--- Determines what kind of completion to offer based on cursor position.
--- Uses regex as primary approach since SQL is often incomplete during typing.
local M = {}

---@alias completion_context
---| "schema"
---| "table"
---| "table_in_schema"
---| "column"
---| "column_of_table"
---| "keyword"
---| "none"

--- Table-context keywords: cursor after these means we're completing a table name.
local table_keywords = {
  "from",
  "join",
  "inner%s+join",
  "left%s+join",
  "right%s+join",
  "full%s+join",
  "cross%s+join",
  "left%s+outer%s+join",
  "right%s+outer%s+join",
  "full%s+outer%s+join",
  "into",
  "update",
  "table",
  "delete%s+from",
}

--- Column-context keywords: cursor in these positions means column completion.
local column_keywords = {
  "select",
  "where",
  "and",
  "or",
  "on",
  "set",
  "order%s+by",
  "group%s+by",
  "having",
  "when",
  "then",
  "else",
  "case",
  "between",
  "in",
  "values",
}

--- Get the text of the current line up to the cursor position.
---@param params table LSP completion params
---@return string
local function get_text_before_cursor(params)
  local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
  local line = params.position.line
  local col = params.position.character

  local lines = vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)
  if not lines or #lines == 0 then
    return ""
  end

  return lines[1]:sub(1, col)
end

--- Parse alias map from the full buffer text.
--- Scans FROM and JOIN clauses for aliases like: FROM employees e, departments d
---@param bufnr integer
---@return table<string, { table: string, schema: string? }>
local function parse_aliases(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local text = table.concat(lines, " ")
  local aliases = {}

  local lower = text:lower()

  -- Scan for "table alias" and "table AS alias" patterns after FROM/JOIN keywords.
  --   word.word word  (schema.table alias)
  --   word word       (table alias) — but not SQL keywords
  local sql_keywords_set = {
    select = true, from = true, where = true, join = true, inner = true,
    left = true, right = true, full = true, cross = true, outer = true,
    on = true, ["and"] = true, ["or"] = true, ["in"] = true, ["not"] = true, as = true,
    order = true, group = true, by = true, having = true, limit = true,
    offset = true, union = true, all = true, distinct = true, set = true,
    insert = true, into = true, update = true, delete = true, create = true,
    alter = true, drop = true, null = true, is = true, like = true,
    between = true, exists = true, case = true, when = true, ["then"] = true,
    ["else"] = true, ["end"] = true, values = true, asc = true, desc = true,
  }

  -- Match: schema.table AS alias
  for schema, tbl, alias in text:gmatch("([%w_]+)%.([%w_]+)%s+[Aa][Ss]%s+([%w_]+)") do
    aliases[alias:lower()] = { table = tbl, schema = schema }
  end

  -- Match: schema.table alias (not a keyword)
  for schema, tbl, alias in text:gmatch("([%w_]+)%.([%w_]+)%s+([%w_]+)") do
    local a = alias:lower()
    if not sql_keywords_set[a] and not aliases[a] then
      aliases[a] = { table = tbl, schema = schema }
    end
  end

  -- Match: table AS alias (no schema)
  for tbl, alias in text:gmatch("([%w_]+)%s+[Aa][Ss]%s+([%w_]+)") do
    local a = alias:lower()
    if not aliases[a] then
      aliases[a] = { table = tbl, schema = nil }
    end
  end

  -- Match: FROM/JOIN table alias (no schema, no AS)
  for tbl, alias in text:gmatch("[Ff][Rr][Oo][Mm]%s+([%w_]+)%s+([%w_]+)") do
    local a = alias:lower()
    if not sql_keywords_set[a] and not aliases[a] then
      aliases[a] = { table = tbl, schema = nil }
    end
  end
  for tbl, alias in text:gmatch("[Jj][Oo][Ii][Nn]%s+([%w_]+)%s+([%w_]+)") do
    local a = alias:lower()
    if not sql_keywords_set[a] and not aliases[a] then
      aliases[a] = { table = tbl, schema = nil }
    end
  end

  return aliases
end

--- Analyze cursor context and return what kind of completion to offer.
---@param params table LSP completion params
---@return completion_context context_type
---@return string? extra schema name, table ref, etc.
---@return table? alias_info for column_of_table: { table, schema }
function M.analyze(params)
  local text = get_text_before_cursor(params)
  if text == "" then
    return "keyword", nil, nil
  end

  local trimmed = text:match("^(.-)%s*$") or text

  -- Check for dot-completion: "word." at end of line
  local dot_prefix = trimmed:match("([%w_]+)%.$")
  if dot_prefix then
    -- Could be schema.table or table/alias.column
    -- Check if we're in a table context (after FROM/JOIN)
    local before_dot = trimmed:sub(1, #trimmed - #dot_prefix - 1)
    local lower_before = before_dot:lower():match("%S+%s*$") or ""

    for _, kw in ipairs(table_keywords) do
      if lower_before:match(kw .. "%s*$") then
        -- schema.table completion
        return "table_in_schema", dot_prefix, nil
      end
    end

    -- Otherwise it's table.column or alias.column
    local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
    local aliases = parse_aliases(bufnr)
    local lower_prefix = dot_prefix:lower()

    if aliases[lower_prefix] then
      return "column_of_table", dot_prefix, aliases[lower_prefix]
    end

    -- Could be a direct table name
    return "column_of_table", dot_prefix, { table = dot_prefix, schema = nil }
  end

  -- Check for table context: after FROM, JOIN, INTO, UPDATE, etc.
  local lower = trimmed:lower()
  for _, kw in ipairs(table_keywords) do
    if lower:match(kw .. "%s+[%w_]*$") then
      return "table", nil, nil
    end
  end

  -- Check for comma-separated table list after FROM: "FROM t1, "
  if lower:match("from%s+.+,%s*[%w_]*$") then
    -- verify we're still in FROM clause (no WHERE/GROUP/ORDER yet)
    local after_from = lower:match("from%s+(.*)$")
    if after_from and not after_from:match("where") and not after_from:match("group")
      and not after_from:match("order") and not after_from:match("having") then
      return "table", nil, nil
    end
  end

  -- Check for column context
  for _, kw in ipairs(column_keywords) do
    if lower:match(kw .. "%s+[%w_]*$") then
      return "column", nil, nil
    end
  end

  -- Check for comma in SELECT list: "SELECT col1, "
  if lower:match("select%s+.+,%s*[%w_]*$") then
    local after_select = lower:match("select%s+(.*)$")
    if after_select and not after_select:match("from") then
      return "column", nil, nil
    end
  end

  -- Check for comma in WHERE clause conditions
  if lower:match("where%s+.+,%s*[%w_]*$") or lower:match("and%s+.+,%s*[%w_]*$") then
    return "column", nil, nil
  end

  return "keyword", nil, nil
end

--- Common SQL keywords for fallback completion.
---@type string[]
M.keywords = {
  "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "EXISTS",
  "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
  "CREATE", "ALTER", "DROP", "TABLE", "VIEW", "INDEX",
  "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "OUTER", "CROSS", "ON",
  "ORDER", "BY", "ASC", "DESC", "GROUP", "HAVING",
  "LIMIT", "OFFSET", "UNION", "ALL", "DISTINCT",
  "AS", "LIKE", "BETWEEN", "IS", "NULL",
  "CASE", "WHEN", "THEN", "ELSE", "END",
  "COUNT", "SUM", "AVG", "MIN", "MAX",
  "BEGIN", "COMMIT", "ROLLBACK",
  "GRANT", "REVOKE", "WITH",
}

return M
