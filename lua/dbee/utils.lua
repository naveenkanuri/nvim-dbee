local M = {}

-- private variable with registered onces
---@type table<string, boolean>
local used_onces = {}

---@param id string unique id of this singleton bool
---@return boolean
function M.once(id)
  id = id or ""

  if used_onces[id] then
    return false
  end

  used_onces[id] = true

  return true
end

-- Get cursor range of current selection
---@return integer start row
---@return integer start column
---@return integer end row
---@return integer end column
function M.visual_selection()
  -- return to normal mode ('< and '> become available only after you exit visual mode)
  local key = vim.api.nvim_replace_termcodes("<esc>", true, false, true)
  vim.api.nvim_feedkeys(key, "x", false)

  local _, srow, scol, _ = unpack(vim.fn.getpos("'<"))
  local _, erow, ecol, _ = unpack(vim.fn.getpos("'>"))
  if ecol > 200000 then
    ecol = 20000
  end
  if srow < erow or (srow == erow and scol <= ecol) then
    return srow - 1, scol - 1, erow - 1, ecol
  else
    return erow - 1, ecol - 1, srow - 1, scol
  end
end

---@param level "info"|"warn"|"error"
---@param message string
---@param subtitle? string
function M.log(level, message, subtitle)
  -- log level
  local l = vim.log.levels.OFF
  if level == "info" then
    l = vim.log.levels.INFO
  elseif level == "warn" then
    l = vim.log.levels.WARN
  elseif level == "error" then
    l = vim.log.levels.ERROR
  end

  -- subtitle
  if subtitle then
    subtitle = "[" .. subtitle .. "]:"
  else
    subtitle = ""
  end
  vim.notify(subtitle .. " " .. message, l, { title = "nvim-dbee" })
end

---Trim leading and trailing whitespace from a value.
---@param value any
---@return string
function M.trim(value)
  return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Gets keys of a map and sorts them by name
---@param obj table<string, any> map-like table
---@return string[]
function M.sorted_keys(obj)
  local keys = {}
  for k, _ in pairs(obj) do
    table.insert(keys, k)
  end
  table.sort(keys)
  return keys
end

-- create an autocmd that is associated with a window rather than a buffer.
---@param events string[]
---@param winid integer
---@param opts table<string, any>
local function create_window_autocmd(events, winid, opts)
  opts = opts or {}
  if not events or not winid or not opts.callback then
    return
  end

  local cb = opts.callback

  opts.callback = function(event)
    -- remove autocmd if window is closed
    if not vim.api.nvim_win_is_valid(winid) then
      vim.api.nvim_del_autocmd(event.id)
      return
    end

    local wid = vim.fn.bufwinid(event.buf or -1)
    if wid ~= winid then
      return
    end
    cb(event)
  end

  vim.api.nvim_create_autocmd(events, opts)
end

-- create an autocmd just once in a single place in code.
-- If opts hold a "window" key, autocmd is defined per window rather than a buffer.
-- If window and buffer are provided, this results in an error.
---@param events string[] events list as defined in nvim api
---@param opts table<string, any> options as in api
function M.create_singleton_autocmd(events, opts)
  if opts.window and opts.buffer then
    error("cannot register autocmd for buffer and window at the same time")
  end

  local caller_info = debug.getinfo(2)
  if not caller_info or not caller_info.name or not caller_info.currentline then
    error("could not determine function caller")
  end

  if
    not M.once(
      "autocmd_singleton_"
        .. caller_info.name
        .. caller_info.currentline
        .. tostring(opts.window)
        .. tostring(opts.buffer)
    )
  then
    -- already configured
    return
  end

  if opts.window then
    local window = opts.window
    opts.window = nil
    create_window_autocmd(events, window, opts)
    return
  end

  vim.api.nvim_create_autocmd(events, opts)
end

local random_charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890"

--- Generate a random string
---@return string _ random string of 10 characters
function M.random_string()
  local function r(length)
    if length < 1 then
      return ""
    end

    local i = math.random(1, #random_charset)
    return r(length - 1) .. random_charset:sub(i, i)
  end

  return r(10)
end

--- Fallback: find the contiguous block of non-empty lines around cursor_row.
--- Used when treesitter can't parse the statement (e.g. PL/SQL blocks).
---@param lines string[]
---@param cursor_row integer zero-based row index
---@return string query, integer start_row, integer end_row
local function query_block_at_cursor(lines, cursor_row)
  -- If cursor is on an empty line, return empty
  if not lines[cursor_row + 1] or lines[cursor_row + 1]:match("^%s*$") then
    return "", cursor_row, cursor_row
  end

  -- Scan upward to find start of block
  local start_row = cursor_row
  while start_row > 0 and lines[start_row] and not lines[start_row]:match("^%s*$") do
    start_row = start_row - 1
  end
  if not lines[start_row + 1] or lines[start_row + 1]:match("^%s*$") then
    start_row = start_row + 1
  end

  -- Scan downward to find end of block
  local end_row = cursor_row
  while end_row < #lines - 1 and lines[end_row + 2] and not lines[end_row + 2]:match("^%s*$") do
    end_row = end_row + 1
  end

  -- Extract the block
  local block_lines = {}
  for i = start_row, end_row do
    table.insert(block_lines, lines[i + 1]) -- lines is 1-indexed
  end
  local query = table.concat(block_lines, "\n")

  return query, start_row, end_row
end

---@param line string
---@return string
local function trim_trailing_semicolon(line)
  return tostring(line or ""):gsub(";%s*$", "")
end

---@param line string
---@return string
local function trim_leading_whitespace(line)
  return tostring(line or ""):gsub("^%s+", "")
end

---Find statement line range in fallback mode using the selected query text.
---Returns nil when a stable range cannot be derived.
---@param block_lines string[]
---@param block_start integer
---@param cursor_row integer
---@param query string
---@return integer?, integer?
local function find_fallback_statement_range(block_lines, block_start, cursor_row, query)
  local function lines_match(block_line, query_line, idx, total)
    local b = tostring(block_line or "")
    local q = tostring(query_line or "")
    if idx == 1 then
      b = trim_leading_whitespace(b)
      q = trim_leading_whitespace(q)
    end
    if idx == total then
      b = trim_trailing_semicolon(b)
      q = trim_trailing_semicolon(q)
    end
    return b == q
  end

  local qlines = vim.split(query, "\n", { plain = true })
  if #qlines == 0 then
    return nil, nil
  end

  -- Single-line statements can share a line with other statements.
  if #qlines == 1 then
    local q = trim_leading_whitespace(qlines[1])
    for i, line in ipairs(block_lines) do
      local row = block_start + i - 1
      local normalized = trim_leading_whitespace(line)
      if normalized:find(q, 1, true) then
        if row == cursor_row then
          return row, row
        end
      end
    end
    for i, line in ipairs(block_lines) do
      local row = block_start + i - 1
      local normalized = trim_leading_whitespace(line)
      if normalized:find(q, 1, true) then
        return row, row
      end
    end
    return nil, nil
  end

  local max_start = #block_lines - #qlines + 1
  for s = 1, max_start do
    local matched = true
    for j = 1, #qlines do
      local b = block_lines[s + j - 1]
      local q = qlines[j]
      if not lines_match(b, q, j, #qlines) then
        matched = false
        break
      end
    end
    if matched then
      local start_row = block_start + s - 1
      local end_row = start_row + #qlines - 1
      if cursor_row >= start_row and cursor_row <= end_row then
        return start_row, end_row
      end
    end
  end

  for s = 1, max_start do
    local matched = true
    for j = 1, #qlines do
      local b = block_lines[s + j - 1]
      local q = qlines[j]
      if not lines_match(b, q, j, #qlines) then
        matched = false
        break
      end
    end
    if matched then
      local start_row = block_start + s - 1
      return start_row, start_row + #qlines - 1
    end
  end

  return nil, nil
end

-- Keywords that cannot be the last word of a syntactically complete SQL statement.
-- When a tree-sitter statement node ends with one of these, the parser has
-- incorrectly split the statement and the next sibling should be merged back.
-- Example: "select name from t fetch" | "first 10 rows only" — the parser
-- treats "fetch" as a table alias, but the user intended FETCH FIRST.
local SQL_INCOMPLETE_CLAUSE_ENDINGS = {
  FETCH = true,     -- FETCH FIRST/NEXT N ROWS ONLY
  OFFSET = true,    -- OFFSET N ROWS
  LIMIT = true,     -- LIMIT N
  ORDER = true,     -- ORDER BY
  GROUP = true,     -- GROUP BY
  PARTITION = true,  -- PARTITION BY
  FOR = true,       -- FOR UPDATE
  CONNECT = true,   -- Oracle: CONNECT BY
  START = true,     -- Oracle: START WITH
  UNION = true,     -- UNION ALL / UNION SELECT
  INTERSECT = true, -- INTERSECT SELECT
  EXCEPT = true,    -- EXCEPT SELECT
  MINUS = true,     -- Oracle: MINUS SELECT
}

--- Get the SQL statement under the cursor and its range (using treesitter).
--- Potential returns are 1. the SQL query, 2. empty string, 3. nil if filetype isn't SQL.
---@param bufnr integer buffer containing the SQL queries.
---@param opts? { adapter_type?: string }
---@return nil|string query, nil|integer start_row, nil|integer end_row
function M.query_under_cursor(bufnr, opts)
  opts = opts or {}
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local ft = vim.bo[bufnr].filetype
  if ft ~= "sql" then
    return
  end
  local adapter_type = tostring(opts.adapter_type or ""):lower()

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local cursor_row = cursor[1] - 1
  local cursor_col = cursor[2]

  -- Step 1: Find the blank-line-delimited block around cursor.
  -- This is the maximum extent of the query — tree-sitter can only narrow it down.
  local block_query, block_start, block_end = query_block_at_cursor(lines, cursor_row)
  if block_query == "" then
    return "", cursor_row, cursor_row
  end

  -- Step 2: Extract block lines for tree-sitter parsing
  local block_lines = {}
  for i = block_start, block_end do
    table.insert(block_lines, lines[i + 1])
  end

  -- Step 3: Use tree-sitter to find the specific statement within the block.
  -- This handles blocks with multiple SQL statements separated by semicolons.
  local tmp_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(tmp_buf, 0, -1, false, block_lines)

  local query = ""
  local start_row, end_row = block_start, block_end

  local should_use_treesitter = adapter_type ~= "oracle"
  local ok, parser = false, nil
  if should_use_treesitter then
    ok, parser = pcall(vim.treesitter.get_parser, tmp_buf, "sql", {})
  end
  if ok and parser then
    local root = parser:parse()[1]:root()
    local cursor_in_block = cursor_row - block_start

    for node in root:iter_children() do
      if node:type() == "statement" then
        local ns, _, ne, _ = node:range()
        if cursor_in_block >= ns and cursor_in_block <= ne then
          query = vim.treesitter.get_node_text(node, tmp_buf)
          start_row, end_row = block_start + ns, block_start + ne

          -- Merge continuation clauses split by the parser (e.g. FETCH FIRST)
          local sibling = node:next_named_sibling()
          while sibling do
            local last_word = (query:match("(%S+)%s*$") or ""):upper()
            if not SQL_INCOMPLETE_CLAUSE_ENDINGS[last_word] then
              break
            end
            local sib_start, _, sib_end, _ = sibling:range()
            if sib_start > (end_row - block_start) + 1 then
              break
            end
            local sib_text = vim.treesitter.get_node_text(sibling, tmp_buf)
            query = query .. " " .. sib_text
            end_row = block_start + sib_end
            sibling = sibling:next_named_sibling()
          end

          break
        end
      end
    end
  end

  vim.api.nvim_buf_delete(tmp_buf, { force = true })

  -- Step 4: If tree-sitter couldn't narrow down, pick the statement at cursor
  -- using the splitter fallback. This avoids executing multiple statements
  -- from a single non-empty block when parser support is unavailable.
  if query == "" then
    local ok_splitter, splitter = pcall(require, "dbee.query_splitter")
    if ok_splitter and splitter and type(splitter.split) == "function" then
      local all_queries = splitter.split(block_query, { adapter_type = adapter_type })
      if #all_queries > 0 then
        local prefix_lines = {}
        for i = block_start, cursor_row do
          if i == cursor_row then
            local line = lines[i + 1] or ""
            local effective_col = cursor_col
            local first_non_space = line:find("%S")
            if first_non_space and effective_col < (first_non_space - 1) then
              effective_col = first_non_space - 1
            end
            table.insert(prefix_lines, line:sub(1, effective_col + 1))
          else
            table.insert(prefix_lines, lines[i + 1] or "")
          end
        end

        local prefix_query = table.concat(prefix_lines, "\n")
        local prefix_queries = splitter.split(prefix_query, { adapter_type = adapter_type })
        local idx = #prefix_queries
        if idx < 1 then
          idx = 1
        end
        if idx > #all_queries then
          idx = #all_queries
        end
        query = all_queries[idx] or ""
      end
    end

    if query == "" then
      query = block_query
    end
    local fallback_start, fallback_end = find_fallback_statement_range(block_lines, block_start, cursor_row, query)
    if fallback_start ~= nil and fallback_end ~= nil then
      start_row, end_row = fallback_start, fallback_end
    else
      start_row, end_row = block_start, block_end
    end
  end

  return query:gsub(";%s*$", ""), start_row, end_row
end

return M
