local utils = require("dbee.utils")

local M = {}

local PL_SQL_START_PATTERNS = {
  "^BEGIN%f[%W]",
  "^DECLARE%f[%W]",
  "^CREATE%s+PROCEDURE%f[%W]",
  "^CREATE%s+FUNCTION%f[%W]",
  "^CREATE%s+PACKAGE%s+BODY%f[%W]",
  "^CREATE%s+PACKAGE%f[%W]",
  "^CREATE%s+TRIGGER%f[%W]",
  "^CREATE%s+TYPE%f[%W]",
  "^CREATE%s+OR%s+REPLACE%s+PROCEDURE%f[%W]",
  "^CREATE%s+OR%s+REPLACE%s+FUNCTION%f[%W]",
  "^CREATE%s+OR%s+REPLACE%s+PACKAGE%s+BODY%f[%W]",
  "^CREATE%s+OR%s+REPLACE%s+PACKAGE%f[%W]",
  "^CREATE%s+OR%s+REPLACE%s+TRIGGER%f[%W]",
  "^CREATE%s+OR%s+REPLACE%s+TYPE%f[%W]",
}

local SQL_START_PATTERNS = {
  "^SELECT%f[%W]",
  "^INSERT%f[%W]",
  "^UPDATE%f[%W]",
  "^DELETE%f[%W]",
  "^MERGE%f[%W]",
  "^WITH%f[%W]",
  "^EXPLAIN%f[%W]",
  "^CALL%f[%W]",
  "^ALTER%f[%W]",
  "^DROP%f[%W]",
  "^TRUNCATE%f[%W]",
  "^GRANT%f[%W]",
  "^REVOKE%f[%W]",
  "^COMMIT%f[%W]",
  "^ROLLBACK%f[%W]",
}

---@param query string
---@return string
local function strip_leading_sql_comments(query)
  local s = utils.trim(query)
  while #s > 0 do
    if s:sub(1, 2) == "--" then
      local idx = s:find("\n", 1, true)
      if not idx then
        return ""
      end
      s = utils.trim(s:sub(idx + 1))
    elseif s:sub(1, 2) == "/*" then
      local idx = s:find("*/", 1, true)
      if not idx then
        return ""
      end
      s = utils.trim(s:sub(idx + 2))
    else
      break
    end
  end
  return s
end

---@param lines string[]
---@param index integer
---@param max_lookahead integer
---@return string
local function compact_preview(lines, index, max_lookahead)
  local lookahead = {}
  local max_index = math.min(#lines, index + max_lookahead)
  for i = index, max_index do
    lookahead[#lookahead + 1] = lines[i]
  end

  local preview = strip_leading_sql_comments(table.concat(lookahead, "\n"))
  if preview == "" then
    return ""
  end

  return preview:gsub("%s+", " "):upper()
end

---@param text string
---@return string[]
local function split_non_plsql(text)
  local queries = {}
  local buf = {}
  local i = 1
  local n = #text
  local in_single = false
  local in_double = false
  local in_line_comment = false
  local in_block_comment = false

  local function append_char(ch)
    buf[#buf + 1] = ch
  end

  local function flush_statement()
    local stmt = utils.trim(table.concat(buf))
    if stmt ~= "" then
      queries[#queries + 1] = stmt
    end
    buf = {}
  end

  while i <= n do
    local ch = text:sub(i, i)
    local next_ch = (i < n) and text:sub(i + 1, i + 1) or ""

    if in_line_comment then
      append_char(ch)
      if ch == "\n" then
        in_line_comment = false
      end
      i = i + 1
      goto continue
    end

    if in_block_comment then
      append_char(ch)
      if ch == "*" and next_ch == "/" then
        append_char(next_ch)
        in_block_comment = false
        i = i + 2
      else
        i = i + 1
      end
      goto continue
    end

    if in_single then
      append_char(ch)
      if ch == "'" then
        if next_ch == "'" then
          append_char(next_ch)
          i = i + 2
        else
          in_single = false
          i = i + 1
        end
      else
        i = i + 1
      end
      goto continue
    end

    if in_double then
      append_char(ch)
      if ch == '"' then
        if next_ch == '"' then
          append_char(next_ch)
          i = i + 2
        else
          in_double = false
          i = i + 1
        end
      else
        i = i + 1
      end
      goto continue
    end

    if ch == "-" and next_ch == "-" then
      append_char(ch)
      append_char(next_ch)
      in_line_comment = true
      i = i + 2
      goto continue
    end

    if ch == "/" and next_ch == "*" then
      append_char(ch)
      append_char(next_ch)
      in_block_comment = true
      i = i + 2
      goto continue
    end

    if ch == "'" then
      append_char(ch)
      in_single = true
      i = i + 1
      goto continue
    end

    if ch == '"' then
      append_char(ch)
      in_double = true
      i = i + 1
      goto continue
    end

    append_char(ch)
    if ch == ";" then
      flush_statement()
    end

    i = i + 1
    ::continue::
  end

  flush_statement()
  return queries
end

---@param line string
---@return boolean
local function is_plsql_block_end_line(line)
  local compact = utils.trim(line):upper()
  return compact:match("^END%s*;%s*$") ~= nil or compact:match("^END%s+[%w_$#]+%s*;%s*$") ~= nil
end

---@param lines string[]
---@param index integer
---@return boolean
local function is_plsql_start_at(lines, index)
  local compact = compact_preview(lines, index, 4)
  if compact == "" then
    return false
  end

  for _, pattern in ipairs(PL_SQL_START_PATTERNS) do
    if compact:match(pattern) then
      return true
    end
  end

  return false
end

---@param lines string[]
---@param index integer
---@return boolean
local function is_sql_start_at(lines, index)
  local compact = compact_preview(lines, index, 2)
  if compact == "" then
    return false
  end

  for _, pattern in ipairs(SQL_START_PATTERNS) do
    if compact:match(pattern) then
      return true
    end
  end

  return false
end

---@param lines string[]
---@param current_index integer
---@return boolean
local function has_next_statement_start(lines, current_index)
  if current_index >= #lines then
    return false
  end
  local next_index = current_index + 1
  return is_plsql_start_at(lines, next_index) or is_sql_start_at(lines, next_index)
end

---@param lines string[]
---@return string[]
local function split_oracle(lines)
  local queries = {}
  local sql_lines = {}
  local plsql_lines = nil

  local function append_query(query)
    local q = utils.trim(query)
    if q ~= "" then
      queries[#queries + 1] = q
    end
  end

  local function flush_sql()
    if #sql_lines == 0 then
      return
    end
    local sql_text = table.concat(sql_lines, "\n")
    local parts = split_non_plsql(sql_text)
    for _, part in ipairs(parts) do
      append_query(part)
    end
    sql_lines = {}
  end

  for i, line in ipairs(lines) do
    if plsql_lines then
      if line:match("^%s*/%s*$") then
        append_query(table.concat(plsql_lines, "\n"))
        plsql_lines = nil
      else
        plsql_lines[#plsql_lines + 1] = line
        if is_plsql_block_end_line(line) and has_next_statement_start(lines, i) then
          append_query(table.concat(plsql_lines, "\n"))
          plsql_lines = nil
        end
      end
    else
      if is_plsql_start_at(lines, i) then
        flush_sql()
        plsql_lines = { line }
      else
        sql_lines[#sql_lines + 1] = line
      end
    end
  end

  if plsql_lines and #plsql_lines > 0 then
    append_query(table.concat(plsql_lines, "\n"))
  end
  flush_sql()

  return queries
end

---Split script into executable queries.
---Oracle mode understands PL/SQL blocks and SQL*Plus '/' block terminator lines.
---@param script string
---@param opts? { adapter_type?: string }
---@return string[]
function M.split(script, opts)
  script = tostring(script or "")
  opts = opts or {}

  local adapter_type = (opts.adapter_type or ""):lower()
  if adapter_type == "oracle" then
    local lines = vim.split(script, "\n", { plain = true })
    return split_oracle(lines)
  end

  return split_non_plsql(script)
end

return M
