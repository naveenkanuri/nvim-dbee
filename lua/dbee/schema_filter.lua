local M = {}

local REGEX_META = "[%[%]%(%)%{%}%^%$%+%?%*\\|]"

local function trim(value)
  return vim.trim(tostring(value or ""))
end

local function fold_id(conn_type)
  conn_type = tostring(conn_type or ""):lower()
  if conn_type == "oracle" then
    return "upper"
  end
  if conn_type == "postgres" or conn_type == "postgresql" or conn_type == "pg" then
    return "lower"
  end
  if conn_type == "mysql" then
    return "lower"
  end
  if conn_type == "sqlserver" or conn_type == "mssql" then
    return "case_insensitive"
  end
  return "upper"
end

local function fold_value(value, fold)
  value = tostring(value or "")
  if fold == "upper" then
    return value:upper()
  end
  if fold == "lower" or fold == "case_insensitive" then
    return value:lower()
  end
  return value
end

local function validate_pattern(pattern)
  if pattern:find(REGEX_META) then
    return false, "schema_filter supports literal names plus SQL glob % and _ only"
  end
  return true
end

local function normalize_list(values, fold, reject_empty)
  if values == nil or values == vim.NIL then
    return nil, nil
  end
  if type(values) ~= "table" then
    return nil, "schema_filter include/exclude must be lists"
  end

  local out = {}
  local seen = {}
  for _, raw in ipairs(values) do
    local value = trim(raw)
    if value ~= "" then
      local ok, err = validate_pattern(value)
      if not ok then
        return nil, err
      end
      value = fold_value(value, fold)
      if not seen[value] then
        seen[value] = true
        out[#out + 1] = value
      end
    end
  end

  if reject_empty and #out == 0 then
    return nil, "schema_filter.include cannot be empty; remove schema_filter to include all schemas"
  end
  table.sort(out)
  return out, nil
end

local function list_has_nonempty(values)
  if type(values) ~= "table" then
    return false
  end
  for _, value in ipairs(values) do
    if trim(value) ~= "" then
      return true
    end
  end
  return false
end

local function encode_list(values, implicit_all)
  if implicit_all then
    return "*"
  end
  if not values or #values == 0 then
    return "0:"
  end

  local encoded = {}
  for _, value in ipairs(values) do
    encoded[#encoded + 1] = tostring(#value) .. ":" .. value
  end
  return table.concat(encoded, ",")
end

local function sql_glob_to_lua(pattern)
  local magic = {
    ["^"] = true,
    ["$"] = true,
    ["("] = true,
    [")"] = true,
    ["%"] = true,
    ["."] = true,
    ["["] = true,
    ["]"] = true,
    ["*"] = true,
    ["+"] = true,
    ["-"] = true,
    ["?"] = true,
  }
  local out = { "^" }
  for index = 1, #pattern do
    local ch = pattern:sub(index, index)
    if ch == "%" then
      out[#out + 1] = ".*"
    elseif ch == "_" then
      out[#out + 1] = "."
    elseif magic[ch] then
      out[#out + 1] = "%" .. ch
    else
      out[#out + 1] = ch
    end
  end
  out[#out + 1] = "$"
  return table.concat(out)
end

function M.fold_id(conn_type)
  return fold_id(conn_type)
end

function M.fold(value, conn_type_or_fold)
  local fold = conn_type_or_fold
  if fold ~= "upper" and fold ~= "lower" and fold ~= "case_insensitive" and fold ~= "identity" then
    fold = fold_id(conn_type_or_fold)
  end
  return fold_value(value, fold)
end

function M.normalize(raw_filter, conn_type)
  local fold = fold_id(conn_type)
  local filter = raw_filter
  if filter == vim.NIL then
    filter = nil
  end

  local include_present = type(filter) == "table" and filter.include ~= nil and filter.include ~= vim.NIL
  local include, include_err = normalize_list(include_present and filter.include or nil, fold, include_present)
  if include_err then
    return nil, include_err
  end
  local exclude, exclude_err = normalize_list(type(filter) == "table" and filter.exclude or nil, fold, false)
  if exclude_err then
    return nil, exclude_err
  end

  include = include or {}
  exclude = exclude or {}
  local lazy = type(filter) == "table"
    and filter.lazy_per_schema == true
    and include_present
    and #include > 0
    or false
  local implicit_all = not include_present
  local signature = table.concat({
    "schema-filter-v1",
    "type=" .. tostring(conn_type or ""),
    "fold=" .. fold,
    "lazy=" .. (lazy and "1" or "0"),
    "include=" .. encode_list(include, implicit_all),
    "exclude=" .. encode_list(exclude, false),
  }, "|")

  return {
    schema_filter = {
      include = vim.deepcopy(include),
      exclude = vim.deepcopy(exclude),
      lazy_per_schema = lazy,
    },
    schema_filter_signature = signature,
    fold = fold,
    connection_type = tostring(conn_type or ""),
    include = vim.deepcopy(include),
    exclude = vim.deepcopy(exclude),
    implicit_all = implicit_all,
    active = (not implicit_all) or #exclude > 0,
    lazy_per_schema = lazy,
  }, nil
end

function M.to_structure_options(raw_filter, conn_type)
  local normalized, err = M.normalize(raw_filter, conn_type)
  if not normalized then
    return nil, err
  end
  return {
    schema_filter = normalized.schema_filter,
    schema_filter_signature = normalized.schema_filter_signature,
    fold = normalized.fold,
    connection_type = normalized.connection_type,
  }, nil
end

function M.validate_persisted_filter(raw_filter, conn_type)
  if raw_filter == nil or raw_filter == vim.NIL then
    return true
  end
  if type(raw_filter) ~= "table" then
    return false, "schema_filter must be a table"
  end

  local include_present = raw_filter.include ~= nil and raw_filter.include ~= vim.NIL
  local include_nonempty = list_has_nonempty(raw_filter.include)
  if include_present and not include_nonempty then
    return false, "schema_filter.include cannot be empty; remove schema_filter to include all schemas"
  end
  if raw_filter.lazy_per_schema == true and not include_nonempty then
    return false, "schema_filter.lazy_per_schema requires a non-empty schema_filter.include"
  end

  local _, err = M.normalize(raw_filter, conn_type)
  if err then
    return false, err
  end
  return true
end

function M.matches(schema, normalized)
  if not normalized then
    return true
  end
  local folded = fold_value(schema, normalized.fold)
  local include_ok = normalized.implicit_all == true or #(normalized.include or {}) == 0
  for _, pattern in ipairs(normalized.include or {}) do
    if folded:match(sql_glob_to_lua(pattern)) then
      include_ok = true
      break
    end
  end
  if not include_ok then
    return false
  end
  for _, pattern in ipairs(normalized.exclude or {}) do
    if folded:match(sql_glob_to_lua(pattern)) then
      return false
    end
  end
  return true
end

function M.filter_structures(structs, normalized)
  if not normalized or normalized.active ~= true then
    return vim.deepcopy(structs or {})
  end

  local function node_schema(node, parent_schema)
    local schema = node.schema or parent_schema or ""
    if (node.type or "") == "schema" then
      schema = schema ~= "" and schema or node.name or ""
    end
    return schema
  end

  local function walk(nodes, parent_schema)
    local out = {}
    for _, node in ipairs(nodes or {}) do
      if type(node) == "table" then
        local current_schema = node_schema(node, parent_schema)
        local schema_scoped = current_schema ~= ""
        if not schema_scoped or M.matches(current_schema, normalized) then
          local copy = vim.deepcopy(node)
          if copy.children then
            copy.children = walk(copy.children, current_schema ~= "" and current_schema or parent_schema)
          end
          out[#out + 1] = copy
        end
      end
    end
    return out
  end

  return walk(structs or {}, nil)
end

function M.is_lazy_enabled(raw_filter)
  return type(raw_filter) == "table"
    and raw_filter.lazy_per_schema == true
    and list_has_nonempty(raw_filter.include)
end

function M.capabilities(conn_type)
  conn_type = tostring(conn_type or ""):lower()
  local lazy = conn_type == "oracle"
    or conn_type == "postgres"
    or conn_type == "postgresql"
    or conn_type == "pg"
    or conn_type == "mysql"
    or conn_type == "sqlserver"
    or conn_type == "mssql"
  return {
    schema_filter = true,
    lazy_per_schema = lazy,
    list_schemas = lazy,
    structure_for_schema = lazy,
  }
end

return M
