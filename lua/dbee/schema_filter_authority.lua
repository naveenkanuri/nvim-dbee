local schema_filter = require("dbee.schema_filter")

local M = {}

local FAIL_CLOSED_SIGNATURE = "schema-filter-v1|fail-closed"

---@class SchemaFilterAuthority
---@field status "ok"|"api_absent_legacy"|"authority_unavailable"
---@field scope table?

---@return table
function M.fail_closed_scope()
  return {
    schema_filter = { include = {}, exclude = {}, lazy_per_schema = false },
    schema_filter_signature = FAIL_CLOSED_SIGNATURE,
    fold = "case_insensitive",
    connection_type = "",
    include = {},
    exclude = {},
    implicit_all = false,
    active = true,
    lazy_per_schema = false,
    fail_closed = true,
  }
end

---@return table
function M.legacy_implicit_all()
  return schema_filter.normalize(nil, nil)
end

---@param authority SchemaFilterAuthority?
---@return boolean
function M.is_fail_closed(authority)
  if not authority then
    return true
  end
  return authority.status == "authority_unavailable"
    or (authority.status == "ok" and authority.scope and authority.scope.fail_closed == true)
end

---Returns the authoritative schema-filter scope for a given connection.
---@param handler Handler?
---@param conn_id connection_id?
---@return SchemaFilterAuthority
function M.read(handler, conn_id)
  if not handler or not conn_id or conn_id == "" then
    return { status = "authority_unavailable" }
  end
  if type(handler.get_schema_filter_normalized) ~= "function" then
    return { status = "api_absent_legacy" }
  end

  local ok, scope = pcall(handler.get_schema_filter_normalized, handler, conn_id)
  if not ok or not scope then
    return { status = "authority_unavailable" }
  end
  return { status = "ok", scope = scope }
end

return M
