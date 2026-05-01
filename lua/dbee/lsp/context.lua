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
  text = text or ""
  local statements = {}
  local current = {}
  local start_line, start_character = 0, 0
  local line, character = 0, 0
  local has_content = false
  local state = "normal"
  local dollar_tag = nil

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

  local function mark_content(ch)
    if not has_content and ch:match("%S") then
      start_line = line
      start_character = character
      has_content = true
    end
  end

  local function append_char(ch)
    mark_content(ch)
    current[#current + 1] = ch
    if ch == "\n" then
      line = line + 1
      character = 0
    else
      character = character + 1
    end
  end

  local function append_text(segment)
    for offset = 1, #segment do
      append_char(segment:sub(offset, offset))
    end
  end

  local function dollar_quote_tag(index)
    return text:sub(index):match("^(%$[%w_]*%$)")
  end

  local i = 1
  while i <= #text do
    local ch = text:sub(i, i)
    local next_ch = text:sub(i + 1, i + 1)

    if state == "normal" and ch == ";" then
      push_statement()
      character = character + 1
      i = i + 1
    elseif state == "normal" and ch == "-" and next_ch == "-" then
      state = "line_comment"
      append_text("--")
      i = i + 2
    elseif state == "normal" and ch == "/" and next_ch == "*" then
      state = "block_comment"
      append_text("/*")
      i = i + 2
    elseif state == "normal" and ch == "'" then
      state = "single_quote"
      append_char(ch)
      i = i + 1
    elseif state == "normal" and ch == '"' then
      state = "double_quote"
      append_char(ch)
      i = i + 1
    elseif state == "normal" and ch == "$" then
      local tag = dollar_quote_tag(i)
      if tag then
        state = "dollar_quote"
        dollar_tag = tag
        append_text(tag)
        i = i + #tag
      else
        append_char(ch)
        i = i + 1
      end
    elseif state == "line_comment" then
      append_char(ch)
      if ch == "\n" then
        state = "normal"
      end
      i = i + 1
    elseif state == "block_comment" then
      if ch == "*" and next_ch == "/" then
        append_text("*/")
        state = "normal"
        i = i + 2
      else
        append_char(ch)
        i = i + 1
      end
    elseif state == "single_quote" then
      if ch == "'" and next_ch == "'" then
        append_text("''")
        i = i + 2
      else
        append_char(ch)
        if ch == "'" then
          state = "normal"
        end
        i = i + 1
      end
    elseif state == "double_quote" then
      if ch == '"' and next_ch == '"' then
        append_text('""')
        i = i + 2
      else
        append_char(ch)
        if ch == '"' then
          state = "normal"
        end
        i = i + 1
      end
    elseif state == "dollar_quote" and dollar_tag and text:sub(i, i + #dollar_tag - 1) == dollar_tag then
      local tag = dollar_tag
      append_text(tag)
      state = "normal"
      dollar_tag = nil
      i = i + #tag
    else
      append_char(ch)
      i = i + 1
    end
  end

  push_statement()
  return statements
end

---@param statement { text: string, start: { line: integer, character: integer }, _offset_index?: table }
---@return { offsets: integer[], positions: table[] }
local function ensure_statement_offset_index(statement)
  if statement._offset_index then
    return statement._offset_index
  end

  local offsets = { 1 }
  local positions = {
    {
      line = statement.start.line,
      character = statement.start.character,
    },
  }
  local line = statement.start.line
  local character = statement.start.character

  for index = 1, #statement.text do
    local ch = statement.text:sub(index, index)
    if ch == "\n" then
      line = line + 1
      character = 0
      offsets[#offsets + 1] = index + 1
      positions[#positions + 1] = {
        line = line,
        character = character,
      }
    else
      character = character + 1
    end
  end

  statement._offset_index = {
    offsets = offsets,
    positions = positions,
  }
  return statement._offset_index
end

---Convert a 1-based byte offset inside a statement to an absolute position.
---@param statement { text: string, start: { line: integer, character: integer } }
---@param offset integer
---@return { line: integer, character: integer }
function M.statement_offset_to_position(statement, offset)
  local index = ensure_statement_offset_index(statement)
  local target = math.max(1, math.min(tonumber(offset) or 1, #statement.text + 1))
  local low = 1
  local high = #index.offsets
  local best = 1
  while low <= high do
    local mid = math.floor((low + high) / 2)
    if index.offsets[mid] <= target then
      best = mid
      low = mid + 1
    else
      high = mid - 1
    end
  end
  local base = index.positions[best]
  return {
    line = base.line,
    character = base.character + (target - index.offsets[best]),
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
      if a.specificity == b.specificity then
        return (a.ref_start or 0) < (b.ref_start or 0)
      end
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
    local next_ch = line:sub(index + 1, index + 1)
    if ch == "-" and next_ch == "-" then
      break
    elseif ch == "/" and next_ch == "*" then
      local _, close_end = line:find("*/", index + 2, true)
      index = close_end and (close_end + 1) or (#line + 1)
    elseif ch == "$" then
      local tag = line:sub(index):match("^(%$[%w_]*%$)")
      if tag then
        local _, close_end = line:find(tag, index + #tag, true)
        index = close_end and (close_end + 1) or (#line + 1)
      else
        index = index + 1
      end
    elseif ch == "'" then
      index = index + 1
      while index <= #line do
        local current = line:sub(index, index)
        if current == "'" then
          if line:sub(index + 1, index + 1) == "'" then
            index = index + 2
          else
            index = index + 1
            break
          end
        else
          index = index + 1
        end
      end
    elseif ch == '"' then
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
    elseif ch:match("[%a_]") then
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
    elseif ch:match("%d") then
      while index <= #line and line:sub(index, index):match("[%w_%.]") do
        index = index + 1
      end
    else
      index = index + 1
    end
  end
  return tokens
end

---@param statement table
---@return table[]
local function scan_statement_tokens(statement)
  local tokens = {}
  local index = 1
  local depth = 0
  ensure_statement_offset_index(statement)

  while index <= #statement.text do
    local ch = statement.text:sub(index, index)
    local next_ch = statement.text:sub(index + 1, index + 1)
    if ch == "-" and next_ch == "-" then
      local newline = statement.text:find("\n", index + 2, true)
      index = newline or (#statement.text + 1)
    elseif ch == "/" and next_ch == "*" then
      local _, close_end = statement.text:find("*/", index + 2, true)
      index = close_end and (close_end + 1) or (#statement.text + 1)
    elseif ch == "$" then
      local tag = statement.text:sub(index):match("^(%$[%w_]*%$)")
      if tag then
        local _, close_end = statement.text:find(tag, index + #tag, true)
        index = close_end and (close_end + 1) or (#statement.text + 1)
      else
        index = index + 1
      end
    elseif ch == "'" then
      index = index + 1
      while index <= #statement.text do
        local current = statement.text:sub(index, index)
        if current == "'" then
          if statement.text:sub(index + 1, index + 1) == "'" then
            index = index + 2
          else
            index = index + 1
            break
          end
        else
          index = index + 1
        end
      end
    elseif ch == '"' then
      local start_index = index
      local raw = { ch }
      index = index + 1
      local closed = false
      while index <= #statement.text do
        local current = statement.text:sub(index, index)
        raw[#raw + 1] = current
        if current == '"' then
          if statement.text:sub(index + 1, index + 1) == '"' then
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
            depth = depth,
            offset_start = start_index,
            offset_end = index,
            range = {
              start = M.statement_offset_to_position(statement, start_index),
              ["end"] = M.statement_offset_to_position(statement, index),
            },
          }
        end
      end
    elseif ch:match("[%a_]") then
      local start_index = index
      while index <= #statement.text and statement.text:sub(index, index):match("[%w_]") do
        index = index + 1
      end
      local raw_text = statement.text:sub(start_index, index - 1)
      local parsed = parse_identifier(raw_text)
      if parsed then
        tokens[#tokens + 1] = {
          raw = raw_text,
          name = parsed.name,
          quoted = false,
          depth = depth,
          offset_start = start_index,
          offset_end = index,
          range = {
            start = M.statement_offset_to_position(statement, start_index),
            ["end"] = M.statement_offset_to_position(statement, index),
          },
        }
      end
    elseif ch:match("%d") then
      while index <= #statement.text and statement.text:sub(index, index):match("[%w_%.]") do
        index = index + 1
      end
    elseif ch == "(" then
      depth = depth + 1
      index = index + 1
    elseif ch == ")" then
      depth = math.max(0, depth - 1)
      index = index + 1
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

---@param text string
---@param start table
---@param offset integer
---@return table
local function statement_offset_to_position(text, start, offset)
  local current_line = start.line
  local current_col = start.character
  for i = 1, math.max(0, offset - 1) do
    local ch = text:sub(i, i)
    if ch == "\n" then
      current_line = current_line + 1
      current_col = 0
    else
      current_col = current_col + 1
    end
  end
  return { line = current_line, character = current_col }
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
  local statement_start = { line = start_line, character = 0 }
  local cursor_offset = position_to_statement_offset({
    text = text,
    start = statement_start,
  }, cursor_line, params.position.character or 0)
  local slice_start = 1
  for i = 1, math.min(cursor_offset - 1, #text) do
    if text:sub(i, i) == ";" then
      slice_start = i + 1
    end
  end
  local slice_end = #text
  local next_semicolon = text:find(";", math.max(1, cursor_offset), true)
  if next_semicolon then
    slice_end = next_semicolon - 1
  end
  return {
    text = text:sub(slice_start, slice_end),
    start = statement_offset_to_position(text, statement_start, slice_start),
    scanned_lines = scanned,
  }
end

---@param statement table
---@param opts? { top_level_only?: boolean }
---@return table[]
local function parse_statement_table_refs(statement, opts)
  opts = opts or {}
  local refs = {}
  local matches = {}

  local tokens = scan_statement_tokens(statement)
  local from_boundaries = {
    select = true,
    where = true,
    join = true,
    inner = true,
    left = true,
    right = true,
    full = true,
    cross = true,
    outer = true,
    on = true,
    group = true,
    order = true,
    having = true,
    limit = true,
    offset = true,
    union = true,
    set = true,
    values = true,
  }

  local function token_lower(token)
    if not token or token.quoted == true then
      return nil
    end
    if opts.top_level_only == true and token.depth ~= 0 then
      return nil
    end
    return token.name:lower()
  end

  local function token_keyword(token)
    local lower = token_lower(token)
    return lower and sql_keywords_set[lower] == true
  end

  local function from_boundary(token)
    local lower = token_lower(token)
    return lower and from_boundaries[lower] == true
  end

  local function separator_between(left_end, right_start)
    if not left_end or not right_start or right_start <= left_end then
      return ""
    end
    return statement.text:sub(left_end, right_start - 1)
  end

  local function dot_between(left, right)
    if not left or not right then
      return false
    end
    return separator_between(left.offset_end, right.offset_start):match("^%s*%.%s*$") ~= nil
  end

  local function parse_table_at(index, specificity)
    local first = tokens[index]
    if not first or token_keyword(first) or (opts.top_level_only == true and first.depth ~= 0) then
      return nil, index + 1
    end

    local second = tokens[index + 1]
    if second and not token_keyword(second) and dot_between(first, second)
      and (opts.top_level_only ~= true or second.depth == 0)
    then
      return {
        pos = first.offset_start,
        specificity = specificity,
        ref_start = first.offset_start,
        ref_end = second.offset_end,
        ref = first.raw .. "." .. second.raw,
        schema = first.name,
        schema_quoted = first.quoted,
        schema_range = first.range,
        table = second.name,
        table_quoted = second.quoted,
        table_range = second.range,
      }, index + 2
    end

    return {
      pos = first.offset_start,
      specificity = specificity,
      ref_start = first.offset_start,
      ref_end = first.offset_end,
      ref = first.raw,
      table = first.name,
      table_quoted = first.quoted,
      table_range = first.range,
    }, index + 1
  end

  local function attach_alias(ref, index)
    local token = tokens[index]
    if not ref or not token then
      return index
    end
    if opts.top_level_only == true and token.depth ~= 0 then
      return index
    end
    if separator_between(ref.ref_end, token.offset_start):find(",", 1, true) then
      return index
    end

    local alias_token
    local lower = token_lower(token)
    if lower == "as" then
      local candidate = tokens[index + 1]
      if candidate and not token_keyword(candidate) then
        alias_token = candidate
        index = index + 2
      else
        return index + 1
      end
    elseif not from_boundary(token) and not token_keyword(token) then
      alias_token = token
      index = index + 1
    else
      return index
    end

    ref.alias = alias_token.name
    ref.alias_key = alias_token.name:lower()
    return index
  end

  local function add_match(ref)
    if ref then
      matches[#matches + 1] = ref
    end
  end

  local function parse_from_list(start_index)
    local index = start_index
    while index <= #tokens do
      if from_boundary(tokens[index]) then
        break
      end
      local ref
      ref, index = parse_table_at(index, 1)
      if ref then
        index = attach_alias(ref, index)
        add_match(ref)
      end
    end
  end

  local function parse_single_after(keyword, start_index, specificity)
    local index = start_index
    while tokens[index] and token_lower(tokens[index]) == "as" do
      index = index + 1
    end
    local ref
    ref, index = parse_table_at(index, specificity)
    if ref then
      attach_alias(ref, index)
      add_match(ref)
    end
  end

  local index = 1
  while index <= #tokens do
    local lower = token_lower(tokens[index])
    if lower == "from" then
      parse_from_list(index + 1)
    elseif lower == "join" or lower == "update" or lower == "into" then
      parse_single_after(lower, index + 1, 1)
    end
    index = index + 1
  end

  table.sort(matches, function(a, b)
    if a.pos == b.pos then
      if a.specificity == b.specificity then
        return (a.ref_start or 0) < (b.ref_start or 0)
      end
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
---@param ref table
---@return table
local function ref_with_ranges(statement, ref)
  local enriched = vim.deepcopy(ref)
  enriched.ref_range = {
    start = M.statement_offset_to_position(statement, ref.ref_start),
    ["end"] = M.statement_offset_to_position(statement, ref.ref_end),
  }

  if enriched.schema_range and enriched.table_range then
    return enriched
  end

  local parts = split_identifier_ref(ref.ref)
  if parts and #parts == 2 then
    local schema_raw = parts[1]
    local table_raw = parts[2]
    local schema_start = ref.ref_start
    local schema_end = schema_start + #schema_raw
    local table_start = schema_end + 1
    local table_end = table_start + #table_raw
    enriched.schema_range = {
      start = M.statement_offset_to_position(statement, schema_start),
      ["end"] = M.statement_offset_to_position(statement, schema_end),
    }
    enriched.table_range = {
      start = M.statement_offset_to_position(statement, table_start),
      ["end"] = M.statement_offset_to_position(statement, table_end),
    }
  else
    enriched.table_range = enriched.ref_range
  end

  return enriched
end

---@param statement table
---@return table[]
function M.statement_table_refs(statement)
  local refs = {}
  for _, ref in ipairs(parse_statement_table_refs(statement)) do
    refs[#refs + 1] = ref_with_ranges(statement, ref)
  end
  return refs
end

---@param statement table
---@return table[]
function M.code_action_table_refs(statement)
  local refs = {}
  for _, ref in ipairs(parse_statement_table_refs(statement, { top_level_only = true })) do
    refs[#refs + 1] = ref_with_ranges(statement, ref)
  end
  return refs
end

---@param left table
---@param right table
---@return integer
local function compare_position(left, right)
  local left_line = tonumber(left and left.line) or 0
  local right_line = tonumber(right and right.line) or 0
  if left_line ~= right_line then
    return left_line < right_line and -1 or 1
  end
  local left_char = tonumber(left and left.character) or 0
  local right_char = tonumber(right and right.character) or 0
  if left_char == right_char then
    return 0
  end
  return left_char < right_char and -1 or 1
end

---@param range table?
---@return table
local function normalize_range(range)
  range = range or {}
  local start = range.start or range["start"] or { line = 0, character = 0 }
  local finish = range["end"] or range.finish or start
  return {
    start = {
      line = tonumber(start.line) or 0,
      character = tonumber(start.character) or 0,
    },
    ["end"] = {
      line = tonumber(finish.line) or tonumber(start.line) or 0,
      character = tonumber(finish.character) or tonumber(start.character) or 0,
    },
  }
end

---@param range table
---@return table
local function range_cursor(range)
  range = normalize_range(range)
  return range.start
end

---@param outer table
---@param inner table
---@return boolean
local function range_intersects(outer, inner)
  outer = normalize_range(outer)
  inner = normalize_range(inner)
  return compare_position(inner["end"], outer.start) >= 0
    and compare_position(inner.start, outer["end"]) <= 0
end

---@param statement table
---@param position table
---@return boolean
local function statement_contains_position(statement, position)
  local start_pos = statement.start or { line = 0, character = 0 }
  local end_pos = M.statement_offset_to_position(statement, #statement.text + 1)
  return compare_position(start_pos, position) <= 0
    and compare_position(position, end_pos) <= 0
end

---@param params table
---@return table?
function M.code_action_statement(params)
  if type(params) ~= "table" or not params.textDocument or not params.textDocument.uri then
    return nil
  end
  local bufnr = vim.uri_to_bufnr(params.textDocument.uri)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local cursor = range_cursor(params.range)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local text = table.concat(lines or {}, "\n")
  for _, statement in ipairs(M.extract_statements(text)) do
    if statement_contains_position(statement, cursor) then
      return statement
    end
  end
  return nil
end

---@param token table?
---@return string?
local function token_lower_name(token)
  if not token or token.quoted == true then
    return nil
  end
  return token.name:lower()
end

---@param statement table
---@return { has_with: boolean, valid: boolean, names: table[] }
function M.statement_local_relations(statement)
  local tokens = scan_statement_tokens(statement)
  local first_top = nil
  for index, token in ipairs(tokens) do
    if token.depth == 0 then
      first_top = index
      break
    end
  end
  if not first_top or token_lower_name(tokens[first_top]) ~= "with" then
    return { has_with = false, valid = true, names = {} }
  end

  local names = {}
  local index = first_top + 1
  while index <= #tokens do
    local token = tokens[index]
    if token.depth ~= 0 then
      index = index + 1
    else
      local lower = token_lower_name(token)
      if lower == "select" then
        return { has_with = true, valid = #names > 0, names = names }
      end
      if lower and sql_keywords_set[lower] then
        return { has_with = true, valid = false, names = names }
      end

      names[#names + 1] = {
        name = token.name,
        raw = token.raw,
        quoted = token.quoted,
        range = token.range,
      }
      index = index + 1

      local found_as = false
      while index <= #tokens do
        local candidate = tokens[index]
        if candidate.depth == 0 then
          local candidate_lower = token_lower_name(candidate)
          if candidate_lower == "as" then
            found_as = true
            index = index + 1
            break
          elseif candidate_lower == "select" then
            return { has_with = true, valid = false, names = names }
          end
        end
        index = index + 1
      end
      if not found_as then
        return { has_with = true, valid = false, names = names }
      end

      while index <= #tokens and tokens[index].depth ~= 0 do
        index = index + 1
      end
    end
  end

  return { has_with = true, valid = false, names = names }
end

---@param statement table
---@return table?
function M.single_code_action_table_ref(statement)
  local refs = M.code_action_table_refs(statement)
  if #refs ~= 1 then
    return nil
  end
  return refs[1]
end

---@param statement table
---@param range table
---@return table?
function M.table_ref_at_range(statement, range)
  for _, ref in ipairs(M.code_action_table_refs(statement)) do
    if ref.table_range and range_intersects(range, ref.table_range) then
      return ref
    end
  end
  return nil
end

---@param statement table
---@return table?
local function top_level_select_bounds(statement)
  local select_offset, from_offset = nil, nil
  for _, token in ipairs(scan_statement_tokens(statement)) do
    if token.depth == 0 and token.quoted ~= true then
      local lower = token.name:lower()
      if lower == "select" and not select_offset then
        select_offset = token.offset_end
      elseif lower == "from" and select_offset then
        from_offset = token.offset_start
        break
      end
    end
  end
  if not select_offset or not from_offset or from_offset <= select_offset then
    return nil
  end
  return {
    select_end = select_offset,
    from_start = from_offset,
  }
end

---@param statement table
---@return table[]
local function scan_star_tokens(statement)
  local stars = {}
  local index = 1
  local depth = 0
  local state = "normal"
  local dollar_tag = nil

  local function dollar_quote_tag(offset)
    return statement.text:sub(offset):match("^(%$[%w_]*%$)")
  end

  while index <= #statement.text do
    local ch = statement.text:sub(index, index)
    local next_ch = statement.text:sub(index + 1, index + 1)

    if state == "normal" and ch == "-" and next_ch == "-" then
      state = "line_comment"
      index = index + 2
    elseif state == "normal" and ch == "/" and next_ch == "*" then
      state = "block_comment"
      index = index + 2
    elseif state == "normal" and ch == "'" then
      state = "single_quote"
      index = index + 1
    elseif state == "normal" and ch == '"' then
      state = "double_quote"
      index = index + 1
    elseif state == "normal" and ch == "$" then
      local tag = dollar_quote_tag(index)
      if tag then
        state = "dollar_quote"
        dollar_tag = tag
        index = index + #tag
      else
        index = index + 1
      end
    elseif state == "normal" and ch == "(" then
      depth = depth + 1
      index = index + 1
    elseif state == "normal" and ch == ")" then
      depth = math.max(0, depth - 1)
      index = index + 1
    elseif state == "normal" and ch == "*" then
      stars[#stars + 1] = {
        offset_start = index,
        offset_end = index + 1,
        depth = depth,
        range = {
          start = M.statement_offset_to_position(statement, index),
          ["end"] = M.statement_offset_to_position(statement, index + 1),
        },
      }
      index = index + 1
    elseif state == "line_comment" then
      if ch == "\n" then
        state = "normal"
      end
      index = index + 1
    elseif state == "block_comment" then
      if ch == "*" and next_ch == "/" then
        state = "normal"
        index = index + 2
      else
        index = index + 1
      end
    elseif state == "single_quote" then
      if ch == "'" and next_ch == "'" then
        index = index + 2
      else
        if ch == "'" then
          state = "normal"
        end
        index = index + 1
      end
    elseif state == "double_quote" then
      if ch == '"' and next_ch == '"' then
        index = index + 2
      else
        if ch == '"' then
          state = "normal"
        end
        index = index + 1
      end
    elseif state == "dollar_quote" and dollar_tag
      and statement.text:sub(index, index + #dollar_tag - 1) == dollar_tag
    then
      state = "normal"
      index = index + #dollar_tag
      dollar_tag = nil
    else
      index = index + 1
    end
  end

  return stars
end

---@param statement table
---@param offset integer
---@return boolean
local function star_is_qualified(statement, offset)
  local before = statement.text:sub(1, math.max(0, offset - 1))
  return before:match("%.%s*$") ~= nil
end

---@param statement table
---@param range table
---@return table?
---@return string?
function M.select_star_at_range(statement, range)
  local bounds = top_level_select_bounds(statement)
  if not bounds then
    return nil, "not_select_list"
  end
  for _, star in ipairs(scan_star_tokens(statement)) do
    if star.depth == 0
      and star.offset_start > bounds.select_end
      and star.offset_start < bounds.from_start
      and range_intersects(range, star.range)
    then
      if star_is_qualified(statement, star.offset_start) then
        return nil, "qualified_star"
      end
      return star, nil
    end
  end
  return nil, "missing_star"
end

---@param params table
---@return table?
function M.code_action_context(params)
  local statement = M.code_action_statement(params)
  if not statement then
    return nil
  end
  return {
    uri = params.textDocument and params.textDocument.uri,
    range = normalize_range(params.range),
    statement = statement,
    table_refs = M.code_action_table_refs(statement),
    local_relations = M.statement_local_relations(statement),
  }
end

---@param statement table
---@param table_refs table[]
---@return table[]
local function statement_column_refs(statement, table_refs)
  local columns = {}
  local aliases = {}
  local tables_by_key = {}
  for _, ref in ipairs(table_refs or {}) do
    if ref.alias_key then
      aliases[ref.alias_key] = ref
    end
    if ref.table and ref.table ~= "" then
      tables_by_key[ref.table] = ref
      if not ref.table_quoted then
        tables_by_key[ref.table:lower()] = ref
      end
    end
  end
  local tokens = scan_statement_tokens(statement)
  local table_ref_token_indexes = {}
  local sorted_table_refs = vim.deepcopy(table_refs or {})
  table.sort(sorted_table_refs, function(a, b)
    return (a.ref_start or 0) < (b.ref_start or 0)
  end)
  local table_ref_index = 1
  for index, token in ipairs(tokens) do
    while sorted_table_refs[table_ref_index]
      and token.offset_start >= (sorted_table_refs[table_ref_index].ref_end or 0)
    do
      table_ref_index = table_ref_index + 1
    end
    local ref = sorted_table_refs[table_ref_index]
    if ref and token.offset_start >= ref.ref_start and token.offset_end <= ref.ref_end then
      table_ref_token_indexes[index] = true
    end
  end

  local function token_keyword(token)
    return token and token.quoted ~= true and sql_keywords_set[token.name:lower()]
  end

  local function ref_for_prefix(prefix)
    if not prefix or prefix == "" then
      return nil
    end
    local alias = aliases[prefix:lower()]
    if alias then
      return alias
    end
    return tables_by_key[prefix] or tables_by_key[prefix:lower()]
  end

  for index = 1, #tokens - 1 do
    local left = tokens[index]
    local right = tokens[index + 1]
    local between = statement.text:sub(left.offset_end, right.offset_start - 1)
    if between:match("^%s*%.%s*$")
      and not table_ref_token_indexes[index]
      and not table_ref_token_indexes[index + 1]
      and not token_keyword(left)
      and not token_keyword(right)
    then
      local ref = ref_for_prefix(left.name)
      if ref then
        columns[#columns + 1] = {
          schema = ref.schema,
          schema_quoted = ref.schema_quoted,
          table = ref.table,
          table_quoted = ref.table_quoted,
          column = right.name,
          column_quoted = right.quoted,
          range = right.range,
        }
      end
    end
  end

  local function trim_span(start_offset, end_offset)
    while start_offset <= end_offset and statement.text:sub(start_offset, start_offset):match("%s") do
      start_offset = start_offset + 1
    end
    while end_offset >= start_offset and statement.text:sub(end_offset, end_offset):match("%s") do
      end_offset = end_offset - 1
    end
    return start_offset, end_offset
  end

  local function split_select_items(start_offset, end_offset)
    local items = {}
    local item_start = start_offset
    local depth = 0
    local index = start_offset
    local quote = nil
    while index <= end_offset do
      local ch = statement.text:sub(index, index)
      local next_ch = statement.text:sub(index + 1, index + 1)
      if quote == "'" then
        if ch == "'" then
          if next_ch == "'" then
            index = index + 1
          else
            quote = nil
          end
        end
      elseif quote == '"' then
        if ch == '"' then
          if next_ch == '"' then
            index = index + 1
          else
            quote = nil
          end
        end
      elseif ch == "'" or ch == '"' then
        quote = ch
      elseif ch == "(" then
        depth = depth + 1
      elseif ch == ")" and depth > 0 then
        depth = depth - 1
      elseif ch == "," and depth == 0 then
        local first, last = trim_span(item_start, index - 1)
        if first <= last then
          items[#items + 1] = { start_offset = first, end_offset = last }
        end
        item_start = index + 1
      end
      index = index + 1
    end
    local first, last = trim_span(item_start, end_offset)
    if first <= last then
      items[#items + 1] = { start_offset = first, end_offset = last }
    end
    return items
  end

  local function simple_identifier_item(item)
    local raw = statement.text:sub(item.start_offset, item.end_offset)
    local parsed = parse_identifier(raw)
    if not parsed then
      return nil
    end
    if not parsed.quoted and (not raw:match("^[%a_][%w_]*$") or sql_keywords_set[parsed.name:lower()]) then
      return nil
    end
    return {
      name = parsed.name,
      quoted = parsed.quoted,
      range = {
        start = M.statement_offset_to_position(statement, item.start_offset),
        ["end"] = M.statement_offset_to_position(statement, item.end_offset + 1),
      },
    }
  end

  if #table_refs == 1 then
    local single_ref = table_refs[1]
    local from_match = statement.text:find("%f[%a]" .. keyword_pattern("from") .. "%f[%A]")
    local select_start, select_end = statement.text:find("%f[%a]" .. keyword_pattern("select") .. "%f[%A]")
    if from_match and select_end and select_start < from_match then
      for _, item in ipairs(split_select_items(select_end + 1, from_match - 1)) do
        local column = simple_identifier_item(item)
        if column then
          columns[#columns + 1] = {
            schema = single_ref.schema,
            schema_quoted = single_ref.schema_quoted,
            table = single_ref.table,
            table_quoted = single_ref.table_quoted,
            column = column.name,
            column_quoted = column.quoted,
            range = column.range,
          }
        end
      end
    end
  end

  return columns
end

---@param text string
---@return table[]
local function extract_symbol_statements(text)
  return M.extract_statements(text or "")
end

---@param text string
---@return { tables: table[], columns: table[] }
function M.extract_symbol_references(text)
  local tables = {}
  local columns = {}
  for _, statement in ipairs(extract_symbol_statements(text or "")) do
    local statement_tables = M.statement_table_refs(statement)
    for _, ref in ipairs(statement_tables) do
      tables[#tables + 1] = ref
    end
    for _, col in ipairs(statement_column_refs(statement, statement_tables)) do
      columns[#columns + 1] = col
    end
  end
  return {
    tables = tables,
    columns = columns,
  }
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
