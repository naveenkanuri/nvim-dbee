local M = {}

local VALID_FOLDS = {
  lower = true,
  upper = true,
  identity = true,
  case_insensitive = true,
}

---@param adapter string?
---@param fallback? "lower"|"upper"|"identity"|"case_insensitive"
---@return "lower"|"upper"|"identity"|"case_insensitive"
function M.fold_for(adapter, fallback)
  adapter = tostring(adapter or ""):lower()
  if adapter == "postgres" or adapter == "postgresql" or adapter == "pg" or adapter == "mysql" then
    return "lower"
  end
  if adapter == "oracle" then
    return "upper"
  end
  if adapter == "clickhouse" then
    return "identity"
  end
  if adapter == "sqlite" or adapter == "sqlite3" or adapter == "sqlserver" or adapter == "mssql" then
    return "case_insensitive"
  end
  if VALID_FOLDS[fallback] then
    return fallback
  end
  return "case_insensitive"
end

---@param adapter_fold string?
---@return "lower"|"upper"|"identity"|"case_insensitive"
local function normalize_fold(adapter_fold)
  if VALID_FOLDS[adapter_fold] then
    return adapter_fold
  end
  return M.fold_for(adapter_fold)
end

---@param name string?
---@param quoted boolean?
---@param adapter_fold string?
---@return CanonicalSchemaName
function M.canonical(name, quoted, adapter_fold)
  local exact = tostring(name or "")
  local fold = normalize_fold(adapter_fold)
  local is_quoted = quoted == true
  local canonical = exact

  if fold == "case_insensitive" then
    canonical = exact:lower()
  elseif not is_quoted and fold == "lower" then
    canonical = exact:lower()
  elseif not is_quoted and fold == "upper" then
    canonical = exact:upper()
  end

  return {
    exact = exact,
    canonical = canonical,
    quoted = is_quoted,
    adapter_fold = fold,
  }
end

---@param a string?
---@param a_quoted boolean?
---@param b string?
---@param b_quoted boolean?
---@param adapter_fold string?
---@return boolean
function M.equivalent(a, a_quoted, b, b_quoted, adapter_fold)
  return M.canonical(a, a_quoted, adapter_fold).canonical
    == M.canonical(b, b_quoted, adapter_fold).canonical
end

---@param name string?
---@param quoted boolean?
---@param adapter_fold string?
---@return string[]
function M.probe_candidates(name, quoted, adapter_fold)
  local exact = tostring(name or "")
  if exact == "" then
    return {}
  end

  local out = {}
  local seen = {}
  local function add(value)
    if value ~= "" and not seen[value] then
      seen[value] = true
      out[#out + 1] = value
    end
  end

  add(exact)
  add(M.canonical(exact, quoted == true, adapter_fold).canonical)
  return out
end

---@param name string?
---@param adapter_fold string?
---@return boolean
function M.is_unquoted_canonical(name, adapter_fold)
  local fold = normalize_fold(adapter_fold)
  if fold == "case_insensitive" then
    return true
  end
  local exact = tostring(name or "")
  return M.canonical(exact, false, fold).canonical == exact
end

---@param name string?
---@param adapter_fold string?
---@return string
function M.loaded_key(name, adapter_fold)
  return M.canonical(name, true, adapter_fold).canonical
end

---@param name string?
---@param adapter_fold string?
---@return string
function M.singleflight_key(name, adapter_fold)
  local fold = normalize_fold(adapter_fold)
  if fold == "case_insensitive" then
    return M.canonical(name, false, fold).canonical
  end
  return M.canonical(name, true, fold).canonical
end

return M
