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

--- Get full buffer text up to the cursor position.
---@param bufnr integer
---@param line integer
---@param col integer
---@return string
local function get_buffer_text_before_cursor(bufnr, line, col)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, line + 1, false)
  if not lines or #lines == 0 then
    return ""
  end

  lines[#lines] = lines[#lines]:sub(1, col)
  return table.concat(lines, "\n")
end

---Split SQL text into statement chunks while preserving absolute positions.
---@param text string
---@return { text: string, start: { line: integer, character: integer } }[]
function M.extract_statements(text)
  local statements = {}
  local current = {}
  local start_line, start_character = 0, 0
  local line, character = 0, 0
  local has_content = false

  local function push_statement()
    local statement_text = table.concat(current)
    if statement_text:match("%S") then
      statements[#statements + 1] = {
        text = statement_text,
        start = {
          line = start_line,
          character = start_character,
        },
      }
    end
    current = {}
    has_content = false
  end

  for i = 1, #text do
    local ch = text:sub(i, i)
    if not has_content and not ch:match("%s") then
      start_line = line
      start_character = character
      has_content = true
    end

    if ch == ";" then
      push_statement()
    else
      current[#current + 1] = ch
    end

    if ch == "\n" then
      line = line + 1
      character = 0
    else
      character = character + 1
    end
  end

  push_statement()
  return statements
end

---Convert a 1-based byte offset inside a statement to an absolute position.
---@param statement { text: string, start: { line: integer, character: integer } }
---@param offset integer
---@return { line: integer, character: integer }
function M.statement_offset_to_position(statement, offset)
  local line = statement.start.line
  local character = statement.start.character
  local text = statement.text:sub(1, math.max(0, offset - 1))
  for i = 1, #text do
    local ch = text:sub(i, i)
    if ch == "\n" then
      line = line + 1
      character = 0
    else
      character = character + 1
    end
  end
  return {
    line = line,
    character = character,
  }
end

--- Parse alias map from the current statement up to the cursor.
--- Scans FROM/JOIN/UPDATE/MERGE table aliases and prefers the latest binding.
---@param bufnr integer
---@param line integer
---@param col integer
---@return table<string, { table: string, schema: string? }>
local function parse_aliases(bufnr, line, col)
  local text = get_buffer_text_before_cursor(bufnr, line, col)
  if text == "" then
    return {}
  end

  -- Keep alias resolution scoped to the current statement only.
  local stmt_start = text:match(".*();")
  if stmt_start then
    text = text:sub(stmt_start + 1)
  end

  ---@type table<string, { table: string, schema: string? }>
  local aliases = {}
  local matches = {}

  ---@param pattern string
  ---@param specificity integer
  local function add_matches(pattern, specificity)
    local init = 1
    while true do
      local s, e, table_ref, alias = text:find(pattern, init)
      if not s then
        break
      end

      local alias_lower = alias and alias:lower() or ""
      if alias_lower ~= "" and not sql_keywords_set[alias_lower] then
        local schema, tbl = table_ref:match("^([%w_]+)%.([%w_]+)$")
        if not tbl then
          tbl = table_ref
          schema = nil
        end

        matches[#matches + 1] = {
          pos = s,
          specificity = specificity,
          alias = alias_lower,
          table = tbl,
          schema = schema,
        }
      end

      init = e + 1
    end
  end

  add_matches("[Ff][Rr][Oo][Mm]%s+([%w_%.]+)%s+([%w_]+)", 1)
  add_matches("[Jj][Oo][Ii][Nn]%s+([%w_%.]+)%s+([%w_]+)", 1)
  add_matches("[Uu][Pp][Dd][Aa][Tt][Ee]%s+([%w_%.]+)%s+([%w_]+)", 1)
  add_matches("[Mm][Ee][Rr][Gg][Ee]%s+[Ii][Nn][Tt][Oo]%s+([%w_%.]+)%s+([%w_]+)", 1)

  add_matches("[Ff][Rr][Oo][Mm]%s+([%w_%.]+)%s+[Aa][Ss]%s+([%w_]+)", 2)
  add_matches("[Jj][Oo][Ii][Nn]%s+([%w_%.]+)%s+[Aa][Ss]%s+([%w_]+)", 2)
  add_matches("[Uu][Pp][Dd][Aa][Tt][Ee]%s+([%w_%.]+)%s+[Aa][Ss]%s+([%w_]+)", 2)
  add_matches("[Mm][Ee][Rr][Gg][Ee]%s+[Ii][Nn][Tt][Oo]%s+([%w_%.]+)%s+[Aa][Ss]%s+([%w_]+)", 2)

  table.sort(matches, function(a, b)
    if a.pos == b.pos then
      return a.specificity < b.specificity
    end
    return a.pos < b.pos
  end)

  for _, m in ipairs(matches) do
    aliases[m.alias] = { table = m.table, schema = m.schema }
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

  -- Some completion clients send requests before inserting trigger characters.
  -- If completion was triggered by ".", emulate the post-insert text so alias
  -- and table.column context detection still works.
  local trigger_char = params.context and params.context.triggerCharacter
  if trigger_char == "." and not trimmed:match("%.$") then
    trimmed = trimmed .. "."
  end

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
    local aliases = parse_aliases(bufnr, params.position.line, params.position.character)
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
