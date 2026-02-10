local M = {}

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function strip_leading_sql_comments(query)
  local s = trim(query)
  while #s > 0 do
    if s:sub(1, 2) == "--" then
      local idx = s:find("\n", 1, true)
      if not idx then
        return ""
      end
      s = trim(s:sub(idx + 1))
    elseif s:sub(1, 2) == "/*" then
      local idx = s:find("*/", 1, true)
      if not idx then
        return ""
      end
      s = trim(s:sub(idx + 2))
    else
      break
    end
  end
  return s
end

local function is_create_plsql(upper_query)
  if upper_query:match("^CREATE%s+PROCEDURE%f[%W]") then
    return true
  end
  if upper_query:match("^CREATE%s+FUNCTION%f[%W]") then
    return true
  end
  if upper_query:match("^CREATE%s+PACKAGE%f[%W]") then
    return true
  end
  if upper_query:match("^CREATE%s+TRIGGER%f[%W]") then
    return true
  end
  if upper_query:match("^CREATE%s+TYPE%f[%W]") then
    return true
  end

  if upper_query:match("^CREATE%s+OR%s+REPLACE%s+PROCEDURE%f[%W]") then
    return true
  end
  if upper_query:match("^CREATE%s+OR%s+REPLACE%s+FUNCTION%f[%W]") then
    return true
  end
  if upper_query:match("^CREATE%s+OR%s+REPLACE%s+PACKAGE%f[%W]") then
    return true
  end
  if upper_query:match("^CREATE%s+OR%s+REPLACE%s+TRIGGER%f[%W]") then
    return true
  end
  if upper_query:match("^CREATE%s+OR%s+REPLACE%s+TYPE%f[%W]") then
    return true
  end

  return false
end

local function is_plsql_like(query)
  local s = strip_leading_sql_comments(query)
  if s == "" then
    return false
  end

  local upper = s:upper()
  if upper:match("^BEGIN") or upper:match("^DECLARE") then
    return true
  end

  if upper:match("^CALL%s") then
    return true
  end

  if upper:match("^CREATE%s+") and is_create_plsql(upper) then
    return true
  end

  return false
end

local function split_non_plsql(block)
  local out = {}
  local buf = {}
  local in_quote = false
  local i = 1

  while i <= #block do
    local ch = block:sub(i, i)
    buf[#buf + 1] = ch

    if ch == "'" then
      if in_quote then
        local next_char = block:sub(i + 1, i + 1)
        if next_char == "'" then
          buf[#buf + 1] = next_char
          i = i + 1
        else
          in_quote = false
        end
      else
        in_quote = true
      end
    elseif ch == ";" and not in_quote then
      local stmt = trim(table.concat(buf))
      if stmt ~= "" then
        out[#out + 1] = stmt
      end
      buf = {}
    end

    i = i + 1
  end

  local rest = trim(table.concat(buf))
  if rest ~= "" then
    out[#out + 1] = rest
  end

  return out
end

---Split script into executable queries.
---Oracle mode understands PL/SQL blocks and SQL*Plus '/' block terminator lines.
---@param script string
---@param opts? { adapter_type?: string }
---@return string[]
function M.split(script, opts)
  script = script or ""
  opts = opts or {}

  local lines = vim.split(script, "\n", { plain = true })
  local adapter_type = (opts.adapter_type or ""):lower()
  local oracle_mode = adapter_type == "oracle"

  local blocks = {}
  local cur = {}

  local function flush_current()
    if #cur == 0 then
      return
    end
    blocks[#blocks + 1] = table.concat(cur, "\n")
    cur = {}
  end

  for _, line in ipairs(lines) do
    if line:match("^%s*$") then
      flush_current()
    else
      cur[#cur + 1] = line
      if oracle_mode and line:match("^%s*/%s*$") and is_plsql_like(table.concat(cur, "\n")) then
        flush_current()
      end
    end
  end
  flush_current()

  local queries = {}
  for _, block in ipairs(blocks) do
    local tblock = trim(block)
    if tblock ~= "" then
      if oracle_mode and is_plsql_like(tblock) then
        queries[#queries + 1] = tblock
      else
        local parts = split_non_plsql(tblock)
        for _, p in ipairs(parts) do
          local stmt = trim(p)
          if stmt ~= "" then
            queries[#queries + 1] = stmt
          end
        end
      end
    end
  end

  return queries
end

return M
