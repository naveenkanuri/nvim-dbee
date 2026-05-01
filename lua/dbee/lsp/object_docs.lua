local M = {}

local MARKDOWN_ESCAPE = {
  ["\\"] = "\\\\",
  ["`"] = "\\`",
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
  return tostring(value or ""):gsub("[\\`%*_%{%}%[%]%(%)#%+%-%.!|]", MARKDOWN_ESCAPE)
end

---@param value any
---@return string
local function inline_code(value)
  return "`" .. M.escape_markdown(value) .. "`"
end

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
  local limit = math.min(#tables, 20)
  if limit > 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Table preview:"
    for i = 1, limit do
      lines[#lines + 1] = "- " .. (markdown and inline_code(tables[i]) or tostring(tables[i]))
    end
    if #tables > limit then
      lines[#lines + 1] = "- +" .. tostring(#tables - limit) .. " more"
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
  local lines = {
    markdown and ("### " .. (metadata.table_type == "view" and "View " or "Table ") .. name)
      or ((metadata.table_type == "view" and "View " or "Table ") .. name),
    "",
    "Type: " .. tostring(metadata.table_type or "table"),
  }
  if metadata.column_count ~= nil then
    lines[#lines + 1] = "Columns loaded: " .. tostring(metadata.column_count)
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
    if #columns > limit then
      lines[#lines + 1] = "- +" .. tostring(#columns - limit) .. " more"
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
---@param _item table?
---@param opts? table
---@return table
function M.format_resolve(metadata, _item, opts)
  opts = opts or {}
  local kind = supports_markdown(opts.client_capabilities, "completion") and "markdown" or "plaintext"
  local detail
  if metadata.kind == "schema" then
    detail = "schema"
  elseif metadata.kind == "table" then
    detail = tostring(metadata.table_type or "table")
  elseif metadata.kind == "column" then
    detail = tostring(metadata.type or "column")
  end
  return {
    documentation = M.markup(format_value(metadata, { kind = kind }), opts.client_capabilities, nil, "completion"),
    detail = detail,
  }
end

return M
