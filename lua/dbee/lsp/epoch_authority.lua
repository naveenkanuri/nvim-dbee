local M = {}

---@param value any
---@return integer
local function epoch_number(value)
  return tonumber(value) or 0
end

---@param value any
---@return integer
---@return boolean available
local function epoch_value(value)
  local epoch = tonumber(value)
  if epoch == nil then
    return 0, false
  end
  return epoch, true
end

---@param value any
---@return integer
function M.normalize_epoch(value)
  return epoch_number(value)
end

---Return the cache metadata epoch.
---@param cache SchemaCache?
---@return integer
---@return boolean available
function M.cache_epoch(cache)
  if cache and type(cache.metadata_root_epoch) == "function" then
    local ok, epoch = pcall(cache.metadata_root_epoch, cache)
    if ok then
      return epoch_value(epoch)
    end
  end
  return 0, false
end

---Return the handler authoritative root epoch for a connection.
---@param handler Handler?
---@param conn_id connection_id?
---@return integer
---@return boolean available
function M.handler_epoch(handler, conn_id)
  if handler and type(handler.get_authoritative_root_epoch) == "function" then
    local ok, epoch = pcall(handler.get_authoritative_root_epoch, handler, conn_id)
    if ok then
      return epoch_value(epoch)
    end
  end
  return 0, false
end

---@class EpochCheck
---@field fresh boolean
---@field available boolean
---@field cache_epoch integer
---@field handler_epoch integer
---@field cache_available boolean
---@field handler_available boolean

---Check if cache metadata is fresh against the handler authoritative root epoch.
---@param cache SchemaCache?
---@param handler Handler?
---@param conn_id connection_id?
---@return EpochCheck
function M.check_fresh(cache, handler, conn_id)
  local cache_epoch, cache_available = M.cache_epoch(cache)
  local handler_epoch, handler_available = M.handler_epoch(handler, conn_id)
  local available = cache_available and handler_available
  return {
    fresh = available and cache_epoch == handler_epoch,
    available = available,
    cache_epoch = cache_epoch,
    handler_epoch = handler_epoch,
    cache_available = cache_available,
    handler_available = handler_available,
  }
end

---Read a cached value only when cache metadata is fresh.
---@param cache SchemaCache?
---@param handler Handler?
---@param conn_id connection_id?
---@param read_fn fun(check: EpochCheck): any
---@return any|nil
---@return EpochCheck
function M.read_with_freshness(cache, handler, conn_id, read_fn)
  local check = M.check_fresh(cache, handler, conn_id)
  if not check.fresh or type(read_fn) ~= "function" then
    return nil, check
  end
  return read_fn(check), check
end

---Admit an epoch-stamped cache write only when it matches the authority epoch.
---@param _cache SchemaCache?
---@param write_epoch any
---@param authoritative_epoch any
---@param authoritative_available? boolean
---@return boolean
function M.admit_write(_cache, write_epoch, authoritative_epoch, authoritative_available)
  local normalized_write, write_available = epoch_value(write_epoch)
  local normalized_authority, authority_available = epoch_value(authoritative_epoch)
  if authoritative_available == false then
    authority_available = false
  end
  return write_available and authority_available and normalized_write == normalized_authority
end

return M
