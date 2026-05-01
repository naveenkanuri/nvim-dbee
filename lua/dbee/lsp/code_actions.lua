local context = require("dbee.lsp.context")
local epoch_authority = require("dbee.lsp.epoch_authority")
local schema_filter_authority = require("dbee.schema_filter_authority")
local schema_name_canonical = require("dbee.schema_name_canonical")

local M = {}

M.COMMAND_REFRESH_SCHEMA = "dbee/refresh_schema"
M.COMMAND_RELOAD_TABLE = "dbee/reload_table"

local ACTION_EXPAND = "expand_select_star"
local ACTION_QUALIFY = "qualify_identifier"
local ACTION_RELOAD = "reload_table_metadata"
local ACTION_REFRESH = "refresh_schema"

---@param opts? table
---@return table
local function features(opts)
  local lsp = opts and opts.lsp or opts or {}
  local master = lsp.code_actions ~= false
  return {
    code_actions = master,
    expand_select_star = master and lsp.code_action_expand_select_star ~= false,
    qualify_identifier = master and lsp.code_action_qualify_identifier ~= false,
    refresh_schema = master and lsp.code_action_refresh_schema ~= false,
    reload_table_metadata = master and lsp.code_action_reload_table_metadata ~= false,
    max_expand_columns = tonumber(lsp.code_action_max_expand_columns) or 200,
  }
end

---@param cache SchemaCache
---@return boolean
local function authority_available(cache)
  if not cache or type(cache.read_lsp_authority) ~= "function" then
    return false
  end
  return not schema_filter_authority.is_fail_closed(cache:read_lsp_authority())
end

---@param cache SchemaCache
---@return boolean
local function cache_fresh(cache)
  local check = epoch_authority.check_fresh(cache, cache and cache.handler, cache and cache.conn_id)
  return check.fresh
end

---@param kind string
---@param only string[]?
---@return boolean
local function kind_allowed(kind, only)
  if type(only) ~= "table" or #only == 0 then
    return true
  end
  for _, requested in ipairs(only) do
    if kind == requested or kind:sub(1, #requested + 1) == requested .. "." then
      return true
    end
  end
  return false
end

---@param opts table
---@param kind string
---@return boolean
local function request_allows(opts, kind)
  return kind_allowed(kind, opts.only)
end

---@param name string
---@return string
local function quote_identifier(name)
  return '"' .. tostring(name or ""):gsub('"', '""') .. '"'
end

---@param cache SchemaCache
---@param name string
---@param force_quote boolean?
---@return string
local function render_identifier(cache, name, force_quote)
  if force_quote == true then
    return quote_identifier(name)
  end
  if schema_name_canonical.is_unquoted_canonical(name, cache and cache.fold_id) then
    return tostring(name or "")
  end
  return quote_identifier(name)
end

---@param versions table<string, integer>?
---@param uri string
---@return integer?
local function document_version(versions, uri)
  local version = versions and versions[uri]
  if type(version) == "number" then
    return version
  end
  return nil
end

---@param uri string
---@param version integer
---@param range table
---@param new_text string
---@return table
local function workspace_edit(uri, version, range, new_text)
  return {
    documentChanges = {
      {
        textDocument = {
          uri = uri,
          version = version,
        },
        edits = {
          {
            range = range,
            newText = new_text,
          },
        },
      },
    },
  }
end

---@param cache SchemaCache
---@return table
local function command_token(cache)
  return {
    conn_id = cache and cache.conn_id,
    cache_identity = cache and type(cache.cache_identity) == "function" and cache:cache_identity() or nil,
    cache_generation = cache and type(cache.generation) == "function" and cache:generation() or nil,
    root_epoch = cache and type(cache.metadata_root_epoch) == "function" and cache:metadata_root_epoch() or nil,
  }
end

---@param cache SchemaCache
---@param token table?
---@return boolean
local function token_current(cache, token)
  if type(token) ~= "table" or not cache then
    return false
  end
  if token.conn_id ~= cache.conn_id then
    return false
  end
  if type(cache.cache_identity) == "function" and token.cache_identity ~= cache:cache_identity() then
    return false
  end
  if type(cache.generation) == "function" and tonumber(token.cache_generation) ~= cache:generation() then
    return false
  end
  if type(cache.metadata_root_epoch) == "function" and tonumber(token.root_epoch) ~= cache:metadata_root_epoch() then
    return false
  end
  return true
end

---@param cache SchemaCache
---@param local_relations table?
---@param ref table?
---@return boolean
local function local_relation_shadow(cache, local_relations, ref)
  if not ref or ref.schema then
    return false
  end
  if not local_relations or local_relations.has_with ~= true then
    return false
  end
  if local_relations.valid ~= true then
    return true
  end
  for _, relation in ipairs(local_relations.names or {}) do
    if schema_name_canonical.equivalent(
      relation.name,
      relation.quoted,
      ref.table,
      ref.table_quoted,
      cache and cache.fold_id
    ) then
      return true
    end
  end
  return false
end

---@param cache SchemaCache
---@param ref table
---@return table?
local function resolve_ref(cache, ref)
  if not cache or not ref or type(cache.resolve_table_for_code_action) ~= "function" then
    return nil
  end
  local resolved = cache:resolve_table_for_code_action(ref.schema, ref.table, {
    schema_quoted = ref.schema_quoted,
    table_quoted = ref.table_quoted,
  })
  return resolved
end

---@param action string
---@param cfg table
---@return boolean
local function action_enabled(action, cfg)
  return cfg[action] == true
end

---@param cache SchemaCache
---@param ref table
---@param cfg table
---@return table?
local function cached_columns_for_expand(cache, ref, cfg)
  if type(cache.get_code_action_table_columns) ~= "function" then
    return nil
  end
  return cache:get_code_action_table_columns(ref.schema, ref.table, {
    schema_quoted = ref.schema_quoted,
    table_quoted = ref.table_quoted,
    max_columns = cfg.max_expand_columns,
  })
end

---@param params table
---@param cache SchemaCache
---@param opts table
---@return table?
local function expand_action(params, cache, opts)
  if not action_enabled(ACTION_EXPAND, opts.features) or not request_allows(opts, "refactor.rewrite") then
    return nil
  end
  local version = document_version(opts.document_versions, opts.ctx.uri)
  if not version then
    return nil
  end
  local star = context.select_star_at_range(opts.ctx.statement, opts.ctx.range)
  if not star then
    return nil
  end
  local ref = context.single_code_action_table_ref(opts.ctx.statement)
  if not ref or local_relation_shadow(cache, opts.ctx.local_relations, ref) then
    return nil
  end
  local metadata = cached_columns_for_expand(cache, ref, opts.features)
  if not metadata or not metadata.columns or #metadata.columns == 0 then
    return nil
  end

  local force_quote = ref.schema_quoted == true or ref.table_quoted == true
  local rendered = {}
  for _, column in ipairs(metadata.columns) do
    rendered[#rendered + 1] = render_identifier(cache, column.name, force_quote)
  end
  return {
    title = "Expand SELECT * -> list columns",
    kind = "refactor.rewrite",
    edit = workspace_edit(opts.ctx.uri, version, star.range, table.concat(rendered, ", ")),
  }
end

---@param params table
---@param cache SchemaCache
---@param opts table
---@return table?
local function qualify_action(params, cache, opts)
  if not action_enabled(ACTION_QUALIFY, opts.features) or not request_allows(opts, "refactor.rewrite") then
    return nil
  end
  local version = document_version(opts.document_versions, opts.ctx.uri)
  if not version then
    return nil
  end
  local ref = context.table_ref_at_range(opts.ctx.statement, opts.ctx.range)
  if not ref or ref.schema or local_relation_shadow(cache, opts.ctx.local_relations, ref) then
    return nil
  end
  local resolved = resolve_ref(cache, ref)
  if not resolved or not resolved.schema or resolved.schema == "_default" then
    return nil
  end
  local rendered_schema = render_identifier(cache, resolved.schema, ref.table_quoted == true)
  local raw_ref = ref.raw or ref.ref or ref.table
  local target = rendered_schema .. "." .. raw_ref
  local insert_range = {
    start = ref.table_range.start,
    ["end"] = ref.table_range.start,
  }
  return {
    title = "Qualify identifier: " .. raw_ref .. " -> " .. target,
    kind = "refactor.rewrite",
    edit = workspace_edit(opts.ctx.uri, version, insert_range, rendered_schema .. "."),
  }
end

---@param cache SchemaCache
---@param ref table
---@return table?
local function reload_args(cache, ref)
  local resolved = resolve_ref(cache, ref)
  if not resolved then
    return nil
  end
  local token = command_token(cache)
  token.schema = resolved.schema
  token.table = resolved.table
  token.schema_quoted = true
  token.table_quoted = true
  return token
end

---@param params table
---@param cache SchemaCache
---@param opts table
---@return table?
local function reload_action(params, cache, opts)
  if not action_enabled(ACTION_RELOAD, opts.features) or not request_allows(opts, "source") then
    return nil
  end
  local ref = context.table_ref_at_range(opts.ctx.statement, opts.ctx.range)
  if not ref or local_relation_shadow(cache, opts.ctx.local_relations, ref) then
    return nil
  end
  local args = reload_args(cache, ref)
  if not args then
    return nil
  end
  return {
    title = "Reload table metadata",
    kind = "source",
    command = {
      title = "Reload table metadata",
      command = M.COMMAND_RELOAD_TABLE,
      arguments = { args },
    },
  }
end

---@param params table
---@param cache SchemaCache
---@param opts table
---@return table?
local function refresh_action(params, cache, opts)
  if not action_enabled(ACTION_REFRESH, opts.features) or not request_allows(opts, "source") then
    return nil
  end
  return {
    title = "Refresh schema cache",
    kind = "source",
    command = {
      title = "Refresh schema cache",
      command = M.COMMAND_REFRESH_SCHEMA,
      arguments = { command_token(cache) },
    },
  }
end

local registry = {
  expand_action,
  qualify_action,
  reload_action,
  refresh_action,
}

---@param opts? table
---@return string[]
function M.enabled_commands(opts)
  local cfg = features(opts)
  local commands = {}
  if cfg.refresh_schema then
    commands[#commands + 1] = M.COMMAND_REFRESH_SCHEMA
  end
  if cfg.reload_table_metadata then
    commands[#commands + 1] = M.COMMAND_RELOAD_TABLE
  end
  return commands
end

---@param command string
---@param opts? table
---@return boolean
function M.command_enabled(command, opts)
  local cfg = features(opts)
  if command == M.COMMAND_REFRESH_SCHEMA then
    return cfg.refresh_schema == true
  end
  if command == M.COMMAND_RELOAD_TABLE then
    return cfg.reload_table_metadata == true
  end
  return false
end

---@param params table
---@param cache SchemaCache
---@param opts? table
---@return table[]
function M.handle_code_action(params, cache, opts)
  opts = opts or {}
  local cfg = features(opts)
  if not cfg.code_actions or not cache or not authority_available(cache) or not cache_fresh(cache) then
    return {}
  end

  local action_ctx = context.code_action_context(params)
  if not action_ctx then
    return {}
  end

  local request_opts = {
    ctx = action_ctx,
    features = cfg,
    only = params.context and params.context.only or nil,
    document_versions = opts.document_versions,
  }

  local out = {}
  for _, contribute in ipairs(registry) do
    local ok, action = pcall(contribute, params, cache, request_opts)
    if ok and action then
      out[#out + 1] = action
    end
  end
  return out
end

---@param params table
---@param cache SchemaCache
---@param opts? table
---@return any
function M.execute_command(params, cache, opts)
  opts = opts or {}
  local command = params and params.command
  if not M.command_enabled(command, opts) then
    return nil
  end
  if not cache or not authority_available(cache) or not cache_fresh(cache) then
    return nil
  end
  local args = params.arguments and params.arguments[1] or nil
  if not token_current(cache, args) then
    return nil
  end

  local callbacks = opts.commands or opts.code_action_commands or {}
  if command == M.COMMAND_REFRESH_SCHEMA then
    if type(callbacks.refresh_schema) == "function" then
      return callbacks.refresh_schema(args)
    end
    return nil
  end

  if command == M.COMMAND_RELOAD_TABLE then
    if not args.schema or not args.table then
      return nil
    end
    local resolved = cache:resolve_table_for_code_action(args.schema, args.table, {
      schema_quoted = args.schema_quoted,
      table_quoted = args.table_quoted,
    })
    if not resolved then
      return nil
    end
    if type(callbacks.reload_table) == "function" then
      return callbacks.reload_table(args)
    end
  end

  return nil
end

return M
