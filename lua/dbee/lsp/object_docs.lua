local M = {}

local MARKDOWN_ESCAPE = {
  ["\\"] = "\\\\",
  ["*"] = "\\*",
  ["_"] = "\\_",
  ["{"] = "\\{",
  ["}"] = "\\}",
  ["["] = "\\[",
  ["]"] = "\\]",
  ["("] = "\\(",
  [")"] = "\\)",
  ["#"] = "\\#",
  ["+"] = "\\+",
  ["-"] = "\\-",
  ["."] = "\\.",
  ["!"] = "\\!",
  ["|"] = "\\|",
}

---@param value any
---@return string
function M.escape_markdown(value)
  return tostring(value or ""):gsub("[\\%*_%{%}%[%]%(%)#%+%-%.!|]", MARKDOWN_ESCAPE)
end

---@param value any
---@return string
function M.code_span(value)
  -- Markdown backtick code-span content is literal; no escape needed except
  -- for backtick collisions (handled via delimiter-doubling below). The
  -- previous escape_markdown() call inserted backslashes for `_`/`.`/etc.
  -- that some renderers (snacks/cmp) display verbatim, producing visible
  -- `\_` and `\.` in identifier popups.
  local text = tostring(value or "")
  local longest = 0
  for run in text:gmatch("`+") do
    if #run > longest then
      longest = #run
    end
  end
  local delimiter = string.rep("`", longest + 1)
  if longest > 0 then
    return delimiter .. " " .. text .. " " .. delimiter
  end
  return delimiter .. text .. delimiter
end

local inline_code = M.code_span

---@param client_caps table?
---@param surface? "hover"|"completion"
---@return boolean
local function supports_markdown(client_caps, surface)
  if type(client_caps) ~= "table" then
    return true
  end
  local formats
  if surface == "completion" then
    formats = client_caps.textDocument
      and client_caps.textDocument.completion
      and client_caps.textDocument.completion.completionItem
      and client_caps.textDocument.completion.completionItem.documentationFormat
  else
    formats = client_caps.textDocument
      and client_caps.textDocument.hover
      and client_caps.textDocument.hover.contentFormat
  end
  if type(formats) == "table" then
    for _, format in ipairs(formats) do
      if format == "markdown" then
        return true
      end
    end
    return false
  end
  return true
end

---@param lines string[]
---@return string
local function join_lines(lines)
  return table.concat(lines, "\n")
end

---@param value any
---@param markdown boolean
---@return string
local function display_identifier(value, markdown)
  local text = tostring(value or "")
  if not markdown then
    return text
  end
  if text:match("^[%w_%.]+$") then
    return text
  end
  if text:find("[\\%*_%{%}%[%]%(%)#%+%-!|`]") then
    return inline_code(text)
  end
  return text
end

---@param refs table[]?
---@param markdown boolean
---@return string[]?
local function format_referenced_by(refs, markdown)
  if type(refs) ~= "table" or (#refs == 0 and (tonumber(refs._truncated_count) or 0) == 0) then
    return nil
  end

  local lines = { "", "Referenced by:" }
  local limit = math.min(#refs, 50)
  for i = 1, limit do
    local ref = refs[i]
    local qualified = table.concat({
      tostring(ref.src_schema or "_default"),
      tostring(ref.src_table or ""),
      tostring(ref.src_col or ""),
    }, ".")
    local line = "  - " .. display_identifier(qualified, markdown)
    if ref.constraint and ref.constraint ~= "" then
      line = line .. "  (constraint: " .. display_identifier(ref.constraint, markdown) .. ")"
    end
    lines[#lines + 1] = line
  end

  local truncated = tonumber(refs._truncated_count) or 0
  if truncated > 0 then
    lines[#lines + 1] = "Referenced by: (truncated, +" .. tostring(truncated) .. " more)"
  end
  return lines
end

---@param metadata table
---@param markdown boolean
---@return string
local function format_schema(metadata, markdown)
  local name = markdown and inline_code(metadata.schema) or tostring(metadata.schema or "")
  local lines = {
    markdown and ("### Schema " .. name) or ("Schema " .. name),
    "",
    "Tables: " .. tostring(metadata.table_count or 0),
  }
  local tables = metadata.tables or {}
  local total_tables = tonumber(metadata.table_count) or #tables
  local limit = math.min(#tables, 20)
  if limit > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Table preview:"
    for i = 1, limit do
      lines[#lines + 1] = "- " .. (markdown and inline_code(tables[i]) or tostring(tables[i]))
    end
    if total_tables > limit then
      lines[#lines + 1] = "- +" .. tostring(total_tables - limit) .. " more"
    end
  end
  return join_lines(lines)
end

---@param metadata table
---@param markdown boolean
---@return string
local function format_table(metadata, markdown)
  local qualified = (metadata.schema and metadata.schema ~= "_default")
    and (metadata.schema .. "." .. metadata.table)
    or metadata.table
  local name = markdown and inline_code(qualified) or tostring(qualified or "")
  local table_label = metadata.table_type == "materialized_view" and "Materialized View"
    or metadata.table_type == "view" and "View"
    or "Table"
  local lines = {
    markdown and ("### " .. table_label .. " " .. name) or (table_label .. " " .. name),
    "",
    "Type: " .. tostring(metadata.table_type or "table"),
  }
  if metadata.column_count ~= nil then
    local column_line = "Columns loaded: " .. tostring(metadata.column_count)
    if metadata.columns_truncated and metadata.columns_truncated_at then
      column_line = column_line
        .. " (showing first "
        .. tostring(metadata.columns_truncated_at)
        .. " of "
        .. tostring(metadata.column_count)
        .. " columns)"
    end
    lines[#lines + 1] = column_line
  end
  if metadata.row_count ~= nil then
    lines[#lines + 1] = "Rows: " .. tostring(metadata.row_count)
  end
  local columns = metadata.columns or {}
  local limit = math.min(#columns, 20)
  if limit > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Column preview:"
    for i = 1, limit do
      local col = columns[i]
      local label = markdown and inline_code(col.name) or tostring(col.name or "")
      local typ = col.type and (" " .. (markdown and inline_code(col.type) or tostring(col.type))) or ""
      lines[#lines + 1] = "- " .. label .. typ
    end
    local total = metadata.column_count or #columns
    if total > limit then
      lines[#lines + 1] = "- +" .. tostring(total - limit) .. " more"
    end
  end
  return join_lines(lines)
end

---@param metadata table
---@param markdown boolean
---@return string
local function format_column(metadata, markdown)
  local qualified = table.concat({
    metadata.schema or "_default",
    metadata.table or "",
    metadata.column or metadata.name or "",
  }, ".")
  local name = markdown and inline_code(qualified) or qualified
  local lines = {
    markdown and ("### Column " .. name) or ("Column " .. name),
  }
  if metadata.type then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Type: " .. (markdown and inline_code(metadata.type) or tostring(metadata.type))
  end
  if metadata.nullable ~= nil then
    lines[#lines + 1] = "Nullable: " .. tostring(metadata.nullable)
  end
  if metadata.default ~= nil then
    lines[#lines + 1] = "Default: " .. (markdown and inline_code(metadata.default) or tostring(metadata.default))
  end
  if metadata.primary_key ~= nil then
    lines[#lines + 1] = "Primary key: " .. tostring(metadata.primary_key)
  end
  if metadata.foreign_key ~= nil then
    lines[#lines + 1] = "Foreign key: " .. tostring(metadata.foreign_key)
  end
  local referenced_by = format_referenced_by(metadata.referenced_by, markdown)
  if referenced_by then
    for _, line in ipairs(referenced_by) do
      lines[#lines + 1] = line
    end
  end
  return join_lines(lines)
end

---@param metadata table
---@param opts? table
---@return string
local function format_value(metadata, opts)
  opts = opts or {}
  local markdown = opts.kind ~= "plaintext"
  if metadata.kind == "schema" then
    return format_schema(metadata, markdown)
  end
  if metadata.kind == "table" then
    return format_table(metadata, markdown)
  end
  if metadata.kind == "column" then
    return format_column(metadata, markdown)
  end
  return markdown and inline_code(metadata.name or metadata.label or "") or tostring(metadata.name or metadata.label or "")
end

---@param value string
---@param client_caps table?
---@param fallback_kind? string
---@param surface? "hover"|"completion"
---@return table
function M.markup(value, client_caps, fallback_kind, surface)
  local kind = supports_markdown(client_caps, surface) and "markdown" or (fallback_kind or "plaintext")
  return {
    kind = kind,
    value = value,
  }
end

---@param metadata table
---@param opts? table
---@return table
function M.format_hover(metadata, opts)
  opts = opts or {}
  local kind = supports_markdown(opts.client_capabilities, "hover") and "markdown" or "plaintext"
  return M.markup(format_value(metadata, { kind = kind }), opts.client_capabilities, nil, "hover")
end

---@param metadata table
---@param item table?
---@param opts? table
---@return table
function M.format_resolve(metadata, item, opts)
  opts = opts or {}
  local kind = supports_markdown(opts.client_capabilities, "completion") and "markdown" or "plaintext"
  local detail
  if metadata.kind == "schema" then
    detail = "schema"
  elseif metadata.kind == "table" then
    detail = tostring(metadata.table_type or "table")
  elseif metadata.kind == "column" then
    detail = item and item.detail or tostring(metadata.type or "column")
  end
  return {
    documentation = M.markup(format_value(metadata, { kind = kind }), opts.client_capabilities, nil, "completion"),
    detail = detail,
  }
end

return M
