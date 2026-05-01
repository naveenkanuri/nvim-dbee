local M = {}

---@param value any
---@return integer
local function epoch_number(value)
  return tonumber(value) or 0
end

---@param value any
---@return integer
function M.normalize_epoch(value)
  return epoch_number(value)
end

---Return the cache metadata epoch.
---@param cache SchemaCache?
---@return integer
function M.cache_epoch(cache)
  if cache and type(cache.metadata_root_epoch) == "function" then
    local ok, epoch = pcall(cache.metadata_root_epoch, cache)
    if ok then
      return epoch_number(epoch)
    end
  end
  return 0
end

---Return the handler authoritative root epoch for a connection.
---@param handler Handler?
---@param conn_id connection_id?
---@return integer
function M.handler_epoch(handler, conn_id)
  if handler and type(handler.get_authoritative_root_epoch) == "function" then
    local ok, epoch = pcall(handler.get_authoritative_root_epoch, handler, conn_id)
    if ok then
      return epoch_number(epoch)
    end
  end
  return 0
end

---@class EpochCheck
---@field fresh boolean
---@field cache_epoch integer
---@field handler_epoch integer

---Check if cache metadata is fresh against the handler authoritative root epoch.
---@param cache SchemaCache?
---@param handler Handler?
---@param conn_id connection_id?
---@return EpochCheck
function M.check_fresh(cache, handler, conn_id)
  local cache_epoch = M.cache_epoch(cache)
  local handler_epoch = M.handler_epoch(handler, conn_id)
  return {
    fresh = cache_epoch == handler_epoch,
    cache_epoch = cache_epoch,
    handler_epoch = handler_epoch,
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
---@return boolean
function M.admit_write(_cache, write_epoch, authoritative_epoch)
  return epoch_number(write_epoch) == epoch_number(authoritative_epoch)
end

return M
