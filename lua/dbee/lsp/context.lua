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

---@param raw string?
---@return { name: string, quoted: boolean }?
local function parse_identifier(raw)
  if type(raw) ~= "string" or raw == "" then
    return nil
  end
  if raw:sub(1, 1) == '"' and raw:sub(-1) == '"' and #raw >= 2 then
    return {
      name = raw:sub(2, -2):gsub('""', '"'),
      quoted = true,
    }
  end
  if raw:match("^[%w_]+$") then
    return {
      name = raw,
      quoted = false,
    }
  end
  return nil
end

---@param ref string
---@return string[]?
local function split_identifier_ref(ref)
  if type(ref) ~= "string" or ref == "" then
    return nil
  end

  local parts = {}
  local current = {}
  local quoted = false
  local index = 1
  while index <= #ref do
    local ch = ref:sub(index, index)
    if ch == '"' then
      current[#current + 1] = ch
      if quoted and ref:sub(index + 1, index + 1) == '"' then
        current[#current + 1] = '"'
        index = index + 1
      else
        quoted = not quoted
      end
    elseif ch == "." and not quoted then
      parts[#parts + 1] = table.concat(current)
      current = {}
    else
      current[#current + 1] = ch
    end
    index = index + 1
  end
  if quoted then
    return nil
  end
  parts[#parts + 1] = table.concat(current)
  return parts
end

---@param ref string
---@return { table: string, table_quoted: boolean, schema: string?, schema_quoted: boolean? }?
function M.parse_table_ref(ref)
  local parts = split_identifier_ref(ref)
  if not parts or #parts == 0 or #parts > 2 then
    return nil
  end

  if #parts == 1 then
    local table_id = parse_identifier(parts[1])
    if not table_id then
      return nil
    end
    return {
      table = table_id.name,
      table_quoted = table_id.quoted,
    }
  end

  local schema_id = parse_identifier(parts[1])
  local table_id = parse_identifier(parts[2])
  if not schema_id or not table_id then
    return nil
  end
  return {
    schema = schema_id.name,
    schema_quoted = schema_id.quoted,
    table = table_id.name,
    table_quoted = table_id.quoted,
  }
end

M.parse_identifier = parse_identifier
M.split_identifier_ref = split_identifier_ref

---@param text string
---@return { name: string, quoted: boolean, raw: string }?
local function identifier_before_dot(text)
  local quoted_raw = text:match('("[^"]*")%.$')
  local quoted_id = parse_identifier(quoted_raw)
  if quoted_id then
    quoted_id.raw = quoted_raw
    return quoted_id
  end

  local raw = text:match("([%w_]+)%.$")
  local id = parse_identifier(raw)
  if id then
    id.raw = raw
  end
  return id
end

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
        local parsed = M.parse_table_ref(table_ref)
        if parsed then
          matches[#matches + 1] = {
            pos = s,
            specificity = specificity,
            alias = alias_lower,
            table = parsed.table,
            table_quoted = parsed.table_quoted,
            schema = parsed.schema,
            schema_quoted = parsed.schema_quoted,
          }
        end
      end

      init = e + 1
    end
  end

  add_matches("[Ff][Rr][Oo][Mm]%s+([^%s,;%(%)]+)%s+([%w_]+)", 1)
  add_matches("[Jj][Oo][Ii][Nn]%s+([^%s,;%(%)]+)%s+([%w_]+)", 1)
  add_matches("[Uu][Pp][Dd][Aa][Tt][Ee]%s+([^%s,;%(%)]+)%s+([%w_]+)", 1)
  add_matches("[Mm][Ee][Rr][Gg][Ee]%s+[Ii][Nn][Tt][Oo]%s+([^%s,;%(%)]+)%s+([%w_]+)", 1)

  add_matches("[Ff][Rr][Oo][Mm]%s+([^%s,;%(%)]+)%s+[Aa][Ss]%s+([%w_]+)", 2)
  add_matches("[Jj][Oo][Ii][Nn]%s+([^%s,;%(%)]+)%s+[Aa][Ss]%s+([%w_]+)", 2)
  add_matches("[Uu][Pp][Dd][Aa][Tt][Ee]%s+([^%s,;%(%)]+)%s+[Aa][Ss]%s+([%w_]+)", 2)
  add_matches("[Mm][Ee][Rr][Gg][Ee]%s+[Ii][Nn][Tt][Oo]%s+([^%s,;%(%)]+)%s+[Aa][Ss]%s+([%w_]+)", 2)

  table.sort(matches, function(a, b)
    if a.pos == b.pos then
      return a.specificity < b.specificity
    end
    return a.pos < b.pos
  end)

  for _, m in ipairs(matches) do
    aliases[m.alias] = {
      table = m.table,
      table_quoted = m.table_quoted,
      schema = m.schema,
      schema_quoted = m.schema_quoted,
    }
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

  -- Check for dot-completion: identifier. at end of line.
  local dot_identifier = identifier_before_dot(trimmed)
  if dot_identifier then
    local dot_prefix = dot_identifier.name
    -- Could be schema.table or table/alias.column
    -- Check if we're in a table context (after FROM/JOIN)
    local before_dot = trimmed:sub(1, #trimmed - #(dot_identifier.raw or dot_prefix) - 1)
    local lower_before = before_dot:lower():match("%S+%s*$") or ""

    for _, kw in ipairs(table_keywords) do
      if lower_before:match(kw .. "%s*$") then
        -- schema.table completion
        return "table_in_schema", dot_prefix, { schema_quoted = dot_identifier.quoted }
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
    return "column_of_table", dot_prefix, {
      table = dot_prefix,
      table_quoted = dot_identifier.quoted,
      schema = nil,
    }
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

---@param keyword string
---@return string
local function keyword_pattern(keyword)
  local parts = {}
  for i = 1, #keyword do
    local ch = keyword:sub(i, i)
    if ch:match("%a") then
      parts[#parts + 1] = "[" .. ch:lower() .. ch:upper() .. "]"
    else
      parts[#parts + 1] = ch
    end
  end
  return table.concat(parts)
end

---@param line string
---@return table[]
local function scan_identifier_tokens(line)
  local tokens = {}
  local index = 1
  while index <= #line do
    local ch = line:sub(index, index)
    if ch == '"' then
      local start_index = index
      local raw = { ch }
      index = index + 1
      local closed = false
      while index <= #line do
        local current = line:sub(index, index)
        raw[#raw + 1] = current
        if current == '"' then
          if line:sub(index + 1, index + 1) == '"' then
            index = index + 1
            raw[#raw + 1] = '"'
          else
            closed = true
            index = index + 1
            break
          end
        else
          index = index + 1
        end
      end
      if closed then
        local raw_text = table.concat(raw)
        local parsed = parse_identifier(raw_text)
        if parsed then
          tokens[#tokens + 1] = {
            raw = raw_text,
            name = parsed.name,
            quoted = true,
            start_col = start_index - 1,
            end_col = index - 1,
          }
        end
      end
    elseif ch:match("[%w_]") then
      local start_index = index
      while index <= #line and line:sub(index, index):match("[%w_]") do
        index = index + 1
      end
      local raw_text = line:sub(start_index, index - 1)
      local parsed = parse_identifier(raw_text)
      if parsed then
        tokens[#tokens + 1] = {
          raw = raw_text,
          name = parsed.name,
          quoted = false,
          start_col = start_index - 1,
          end_col = index - 1,
        }
      end
    else
      index = index + 1
    end
  end
  return tokens
end

---@param params table
---@return table?
function M.token_at_position(params)
  if type(params) ~= "table" or not params.textDocument or not params.position then
    return nil
  end
  local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
  local line_nr = params.position.line or 0
  local col = params.position.character or 0
  local lines = vim.api.nvim_buf_get_lines(bufnr, line_nr, line_nr + 1, false)
  local line = lines and lines[1] or ""

  for _, token in ipairs(scan_identifier_tokens(line)) do
    if token.start_col <= col and col < token.end_col then
      local keyword = token.quoted ~= true and sql_keywords_set[token.name:lower()]
      if keyword then
        return nil
      end
      token.range = {
        start = { line = line_nr, character = token.start_col },
        ["end"] = { line = line_nr, character = token.end_col },
      }
      return token
    end
    if col == token.end_col and token.end_col > token.start_col then
      local keyword = token.quoted ~= true and sql_keywords_set[token.name:lower()]
      if not keyword then
        token.range = {
          start = { line = line_nr, character = token.start_col },
          ["end"] = { line = line_nr, character = token.end_col },
        }
        return token
      end
    end
  end
  return nil
end

---@param statement table
---@param line integer
---@param col integer
---@return integer
local function position_to_statement_offset(statement, line, col)
  local offset = 1
  local current_line = statement.start.line
  local current_col = statement.start.character
  while offset <= #statement.text do
    if current_line == line and current_col == col then
      return offset
    end
    local ch = statement.text:sub(offset, offset)
    offset = offset + 1
    if ch == "\n" then
      current_line = current_line + 1
      current_col = 0
    else
      current_col = current_col + 1
    end
  end
  return #statement.text + 1
end

---@param params table
---@param opts? { max_scan_lines?: integer }
---@return table?
function M.extract_hover_statement(params, opts)
  opts = opts or {}
  local max_scan_lines = opts.max_scan_lines or 200
  local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
  local cursor_line = params.position.line or 0
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local start_line = cursor_line
  local end_line = cursor_line
  local scanned = 1
  local hit_start = false
  local hit_end = false

  while start_line > 0 and scanned < max_scan_lines do
    local prev = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, start_line, false)[1] or ""
    if prev:match("^%s*$") or prev:find(";") then
      hit_start = true
      break
    end
    start_line = start_line - 1
    scanned = scanned + 1
  end
  if start_line == 0 then
    hit_start = true
  end

  while end_line < line_count - 1 and scanned < max_scan_lines do
    local current = vim.api.nvim_buf_get_lines(bufnr, end_line, end_line + 1, false)[1] or ""
    if end_line > cursor_line and (current:match("^%s*$") or current:find(";")) then
      hit_end = true
      break
    end
    if end_line == cursor_line and current:sub((params.position.character or 0) + 1):find(";") then
      hit_end = true
      break
    end
    end_line = end_line + 1
    scanned = scanned + 1
  end
  if end_line >= line_count - 1 then
    hit_end = true
  end

  if not hit_start or not hit_end then
    return nil
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line + 1, false)
  local text = table.concat(lines, "\n")
  return {
    text = text,
    start = { line = start_line, character = 0 },
    scanned_lines = scanned,
  }
end

---@param statement table
---@return table[]
local function parse_statement_table_refs(statement)
  local refs = {}
  local matches = {}

  local function add_matches(keyword, specificity)
    local pattern = "()%f[%a]" .. keyword_pattern(keyword) .. "%f[%A]%s+()([^%s,;%(%)]+)%s*([%w_]*)"
    local init = 1
    while true do
      local match_start, match_end, _, ref_start, ref, alias = statement.text:find(pattern, init)
      if not match_start then
        break
      end
      local parsed = M.parse_table_ref(ref)
      if parsed then
        local alias_lower = alias and alias:lower() or ""
        if sql_keywords_set[alias_lower] then
          alias = nil
          alias_lower = ""
        end
        matches[#matches + 1] = {
          pos = match_start,
          specificity = specificity,
          ref_start = ref_start,
          ref_end = ref_start + #ref,
          ref = ref,
          alias = alias and alias ~= "" and alias or nil,
          alias_key = alias_lower ~= "" and alias_lower or nil,
          schema = parsed.schema,
          schema_quoted = parsed.schema_quoted,
          table = parsed.table,
          table_quoted = parsed.table_quoted,
        }
      end
      init = match_end + 1
    end
  end

  for _, keyword in ipairs({ "from", "join", "update", "into" }) do
    add_matches(keyword, 1)
  end

  table.sort(matches, function(a, b)
    if a.pos == b.pos then
      return a.specificity < b.specificity
    end
    return a.pos < b.pos
  end)

  for _, ref in ipairs(matches) do
    refs[#refs + 1] = ref
  end
  return refs
end

---@param statement table
---@param token table
---@return table?
local function component_for_token(statement, token)
  local offset = position_to_statement_offset(statement, token.range.start.line, token.range.start.character)
  for _, ref in ipairs(parse_statement_table_refs(statement)) do
    if ref.ref_start <= offset and offset < ref.ref_end then
      local parts = split_identifier_ref(ref.ref)
      if parts and #parts == 2 then
        local schema_raw = parts[1]
        local table_raw = parts[2]
        local schema_start = ref.ref_start
        local schema_end = schema_start + #schema_raw
        local table_start = schema_end + 1
        local table_end = table_start + #table_raw
        if schema_start <= offset and offset < schema_end then
          return vim.tbl_extend("force", ref, { component = "schema" })
        end
        if table_start <= offset and offset < table_end then
          return vim.tbl_extend("force", ref, { component = "table" })
        end
      else
        return vim.tbl_extend("force", ref, { component = "table" })
      end
    end
  end
  return nil
end

---@param statement table
---@return table<string, table>
local function alias_map(statement)
  local aliases = {}
  for _, ref in ipairs(parse_statement_table_refs(statement)) do
    if ref.alias_key then
      aliases[ref.alias_key] = ref
    end
  end
  return aliases
end

---@param params table
---@param opts? { max_scan_lines?: integer }
---@return table?
function M.hover_context(params, opts)
  local token = M.token_at_position(params)
  if not token then
    return nil
  end
  local statement = M.extract_hover_statement(params, opts)
  if not statement then
    return {
      token = token,
      capped = true,
    }
  end
  local table_refs = parse_statement_table_refs(statement)
  local selected_ref = component_for_token(statement, token)
  local aliases = alias_map(statement)

  local line = vim.api.nvim_buf_get_lines(vim.uri_to_bufnr(params.textDocument.uri), token.range.start.line, token.range.start.line + 1, false)[1] or ""
  local before = line:sub(1, token.range.start.character)
  local prefix_raw = before:match('("[^"]*")%.$') or before:match("([%w_]+)%.$")
  local prefix = parse_identifier(prefix_raw)

  return {
    token = token,
    statement = statement,
    table_refs = table_refs,
    selected_ref = selected_ref,
    aliases = aliases,
    prefix = prefix,
    single_table_ref = (#table_refs == 1) and table_refs[1] or nil,
  }
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
