-- Headless Phase 12.3 checks for LSP code actions.

vim.env.XDG_STATE_HOME = vim.env.XDG_STATE_HOME or vim.fn.tempname()
vim.fn.mkdir(vim.env.XDG_STATE_HOME, "p")

package.preload["nio"] = package.preload["nio"] or function()
  return {}
end

package.loaded["dbee.api.state"] = {
  config = function()
    return { lsp = { diagnostics_mode = "off" } }
  end,
}

local SchemaCache = require("dbee.lsp.schema_cache")
local server = require("dbee.lsp.server")
local schema_filter = require("dbee.schema_filter")

local function fail(msg)
  print("LSP12_3_FAIL=" .. tostring(msg))
  vim.cmd("cquit 1")
end

local function emit(label, value)
  print(label .. "=" .. tostring(value))
end

local function assert_true(label, value)
  if not value then
    fail(label .. ": expected true")
  end
end

local function assert_eq(label, actual, expected)
  if actual ~= expected then
    fail(label .. ": expected " .. vim.inspect(expected) .. " got " .. vim.inspect(actual))
  end
end

local scope_ref = { value = schema_filter.normalize(nil, "postgres") }
local epoch_ref = { value = 1 }

local function make_handler(opts)
  opts = opts or {}
  local handler = {
    counters = {
      sync = 0,
      async = 0,
      authority = 0,
      current = 0,
      connection_get_columns = 0,
      connection_get_columns_async = 0,
    },
    async_requests = {},
  }

  function handler:get_schema_filter_normalized()
    handler.counters.authority = handler.counters.authority + 1
    return scope_ref.value
  end

  function handler:get_authoritative_root_epoch()
    return epoch_ref.value
  end

  function handler:get_current_connection()
    handler.counters.current = handler.counters.current + 1
    return { id = opts.conn_id or "lsp12-3", type = "postgres" }
  end

  function handler:connection_get_columns()
    handler.counters.sync = handler.counters.sync + 1
    handler.counters.connection_get_columns = handler.counters.connection_get_columns + 1
    return {}
  end

  function handler:connection_get_columns_async(conn_id, request_id, branch_id, root_epoch, request)
    handler.counters.async = handler.counters.async + 1
    handler.counters.connection_get_columns_async = handler.counters.connection_get_columns_async + 1
    handler.async_requests[#handler.async_requests + 1] = {
      conn_id = conn_id,
      request_id = request_id,
      branch_id = branch_id,
      root_epoch = root_epoch,
      request = request,
    }
  end

  function handler:connection_get_structure_singleflight(request)
    handler.counters.async = handler.counters.async + 1
    handler.last_structure_refresh = request
  end

  return handler
end

local function rows()
  return {
    { schema_name = "public", table_name = "users", obj_type = "table" },
    { schema_name = "public", table_name = "orders", obj_type = "table" },
    { schema_name = "public", table_name = "wide_table", obj_type = "table" },
    { schema_name = "audit", table_name = "users", obj_type = "table" },
    { schema_name = "private", table_name = "secrets", obj_type = "table" },
    { schema_name = "Case Schema", table_name = "Case Table", obj_type = "table" },
  }
end

local function make_columns(prefix, count)
  local columns = {}
  for i = 1, count do
    columns[#columns + 1] = {
      name = string.format("%s_%03d", prefix, i),
      type = "text",
    }
  end
  return columns
end

local function make_cache(opts)
  opts = opts or {}
  scope_ref.value = opts.scope or schema_filter.normalize(nil, "postgres")
  epoch_ref.value = opts.epoch or 1
  local handler = make_handler(opts)
  local cache = SchemaCache:new(handler, opts.conn_id or "lsp12-3")
  assert_true("cache build", cache:build_from_metadata_rows(rows(), { root_epoch = opts.root_epoch or epoch_ref.value }))
  cache:_store_columns("public.users", {
    { name = "id", type = "integer" },
    { name = "email", type = "text" },
  }, { root_epoch = epoch_ref.value })
  cache:_store_columns("public.orders", {
    { name = "id", type = "integer" },
    { name = "user_id", type = "integer" },
  }, { root_epoch = epoch_ref.value })
  cache:_store_columns("Case Schema.Case Table", {
    { name = "Id Col", type = "integer" },
    { name = "Email Col", type = "text" },
  }, { root_epoch = epoch_ref.value })
  cache:_store_columns("public.wide_table", make_columns("wide_col", opts.wide_count or 201), {
    root_epoch = epoch_ref.value,
  })
  return cache, handler
end

local function make_buffer(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, "/tmp/dbee-lsp12-3-" .. tostring(math.random(1000000)) .. ".sql")
  vim.api.nvim_buf_set_option(bufnr, "filetype", "sql")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr, vim.uri_from_bufnr(bufnr)
end

local function request(client, method, params)
  local done = false
  local response
  client.request(method, params, function(err, result)
    response = { err = err, result = result }
    done = true
  end)
  vim.wait(1000, function()
    return done
  end, 10)
  if not response then
    fail(method .. " timeout")
  end
  if response.err then
    fail(method .. " error: " .. tostring(response.err))
  end
  return response.result
end

local function initialize(client)
  return request(client, "initialize", { capabilities = {} })
end

local function did_open(client, uri, version, text)
  client.notify("textDocument/didOpen", {
    textDocument = {
      uri = uri,
      languageId = "sql",
      version = version or 1,
      text = text or "",
    },
  })
end

local function did_change(client, uri, version, text)
  client.notify("textDocument/didChange", {
    textDocument = {
      uri = uri,
      version = version,
    },
    contentChanges = {
      { text = text },
    },
  })
end

local function position_of(line, needle, occurrence)
  occurrence = occurrence or 1
  local init = 1
  local found
  for _ = 1, occurrence do
    found = line:find(needle, init, true)
    if not found then
      fail("missing needle " .. tostring(needle) .. " in " .. tostring(line))
    end
    init = found + #needle
  end
  return found - 1
end

local function code_action(client, uri, line, start_char, end_char, only)
  return request(client, "textDocument/codeAction", {
    textDocument = { uri = uri },
    range = {
      start = { line = line or 0, character = start_char },
      ["end"] = { line = line or 0, character = end_char or start_char },
    },
    context = only and { only = only } or {},
  })
end

local function execute_command(client, command, args)
  return request(client, "workspace/executeCommand", {
    command = command,
    arguments = args and { args } or {},
  })
end

local function first_action(actions, title)
  for _, action in ipairs(actions or {}) do
    if action.title == title then
      return action
    end
  end
  return nil
end

local function first_command(actions, command)
  for _, action in ipairs(actions or {}) do
    if action.command and action.command.command == command then
      return action
    end
  end
  return nil
end

local function client_for(cache, opts)
  opts = opts or {}
  local calls = {
    refresh = 0,
    reload = 0,
  }
  opts.code_action_commands = opts.code_action_commands or {
    refresh_schema = function()
      calls.refresh = calls.refresh + 1
      return nil
    end,
    reload_table = function(args)
      calls.reload = calls.reload + 1
      return cache:reload_table_metadata_async(args.schema, args.table, args)
    end,
  }
  local client = server.create(cache, opts)({}, {})
  return client, calls
end

local cache, handler = make_cache()
local client, command_calls = client_for(cache)
local init = initialize(client)
assert_eq("code action provider", init.capabilities.codeActionProvider, true)
assert_eq("execute command count", #init.capabilities.executeCommandProvider.commands, 2)
assert_eq("execute refresh command", init.capabilities.executeCommandProvider.commands[1], "dbee/refresh_schema")
assert_eq("execute reload command", init.capabilities.executeCommandProvider.commands[2], "dbee/reload_table")
emit("LSP12_3_EXECUTE_COMMAND_PROVIDER_OK", "true")

local line = "select * from public.users"
local bufnr, uri = make_buffer({ line })
did_open(client, uri, 1, line)
local star = position_of(line, "*")
local expand = code_action(client, uri, 0, star, star + 1, { "refactor.rewrite" })
local expand_action = first_action(expand, "Expand SELECT * -> list columns")
assert_true("expand action", expand_action ~= nil)
local expand_edit = expand_action.edit.documentChanges[1].edits[1]
assert_eq("expand text", expand_edit.newText, "id, email")
emit("LSP12_3_EXPAND_SELECT_STAR_OK", "true")

local quoted_line = 'select * from "Case Schema"."Case Table"'
local quoted_buf, quoted_uri = make_buffer({ quoted_line })
did_open(client, quoted_uri, 1, quoted_line)
local quoted_star = position_of(quoted_line, "*")
local quoted_expand = code_action(client, quoted_uri, 0, quoted_star, quoted_star + 1, { "refactor.rewrite" })
local quoted_expand_action = first_action(quoted_expand, "Expand SELECT * -> list columns")
assert_true("quoted expand action", quoted_expand_action ~= nil)
assert_eq("quoted expand text", quoted_expand_action.edit.documentChanges[1].edits[1].newText, '"Id Col", "Email Col"')
emit("LSP12_3_EXPAND_SELECT_STAR_QUOTED_PRESERVED", "true")

scope_ref.value = schema_filter.normalize({ include = { "audit" } }, "postgres")
local scoped = code_action(client, uri, 0, star, star + 1, { "refactor.rewrite" })
assert_eq("out of scope expand", #scoped, 0)
scope_ref.value = schema_filter.normalize(nil, "postgres")
emit("LSP12_3_EXPAND_SELECT_STAR_OUT_OF_SCOPE_NO_ACTION", "true")

local wide_line = "select * from public.wide_table"
local wide_buf, wide_uri = make_buffer({ wide_line })
did_open(client, wide_uri, 1, wide_line)
local wide_lookup_count = 0
local original_columns = cache.get_code_action_table_columns
cache.get_code_action_table_columns = function(self, ...)
  wide_lookup_count = wide_lookup_count + 1
  local result, reason = original_columns(self, ...)
  assert_eq("wide omitted reason", reason, "too_wide")
  return result, reason
end
local wide_star = position_of(wide_line, "*")
local wide_actions = code_action(client, wide_uri, 0, wide_star, wide_star + 1, { "refactor.rewrite" })
cache.get_code_action_table_columns = original_columns
assert_eq("wide action omitted", #wide_actions, 0)
assert_eq("wide lookup count", wide_lookup_count, 1)
emit("LSP12_3_EXPAND_SELECT_STAR_WIDE_TABLE_BOUNDED_COPY", "true")

for _, qualified_line in ipairs({
  "select u.* from public.users u",
  'select "u".* from public.users "u"',
  "select public.users.* from public.users",
}) do
  local qb, quri = make_buffer({ qualified_line })
  did_open(client, quri, 1, qualified_line)
  local qstar = position_of(qualified_line, "*")
  local actions = code_action(client, quri, 0, qstar, qstar + 1, { "refactor.rewrite" })
  assert_eq("qualified star omitted", #actions, 0)
end
emit("LSP12_3_EXPAND_QUALIFIED_STAR_NO_ACTION", "true")

local cte_line = "with users as (select 1) select * from users"
local cte_buf, cte_uri = make_buffer({ cte_line })
did_open(client, cte_uri, 1, cte_line)
local cte_lookup_count = 0
cache.get_code_action_table_columns = function()
  cte_lookup_count = cte_lookup_count + 1
  fail("CTE shadow reached cached column lookup")
end
local cte_star = position_of(cte_line, "*")
local cte_actions = code_action(client, cte_uri, 0, cte_star, cte_star + 1, { "refactor.rewrite" })
cache.get_code_action_table_columns = original_columns
assert_eq("cte shadow expand omitted", #cte_actions, 0)
assert_eq("cte shadow lookup count", cte_lookup_count, 0)
emit("LSP12_3_EXPAND_CTE_SHADOW_NO_ACTION", "true")

local recursive_cte_line = "with recursive users as (select 1) select * from users"
local recursive_cte_buf, recursive_cte_uri = make_buffer({ recursive_cte_line })
did_open(client, recursive_cte_uri, 1, recursive_cte_line)
local recursive_cte_lookup_count = 0
cache.get_code_action_table_columns = function()
  recursive_cte_lookup_count = recursive_cte_lookup_count + 1
  fail("WITH RECURSIVE CTE shadow reached cached column lookup")
end
local recursive_cte_star = position_of(recursive_cte_line, "*")
local recursive_cte_expand = code_action(
  client,
  recursive_cte_uri,
  0,
  recursive_cte_star,
  recursive_cte_star + 1,
  { "refactor.rewrite" }
)
cache.get_code_action_table_columns = original_columns
local recursive_cte_ref_pos = position_of(recursive_cte_line, "users", 2)
local recursive_cte_qualify = code_action(
  client,
  recursive_cte_uri,
  0,
  recursive_cte_ref_pos,
  recursive_cte_ref_pos,
  { "refactor.rewrite" }
)
local recursive_cte_reload = code_action(
  client,
  recursive_cte_uri,
  0,
  recursive_cte_ref_pos,
  recursive_cte_ref_pos,
  { "source" }
)
assert_eq("recursive cte expand omitted", #recursive_cte_expand, 0)
assert_eq("recursive cte qualify omitted", #recursive_cte_qualify, 0)
assert_eq("recursive cte source only refresh", #recursive_cte_reload, 1)
assert_true("recursive cte refresh retained", first_command(recursive_cte_reload, "dbee/refresh_schema") ~= nil)
assert_eq("recursive cte lookup count", recursive_cte_lookup_count, 0)
emit("LSP12_3_WITH_RECURSIVE_CTE_SHADOW_NO_ACTION", "true")

do
  local function check_derived_table_alias_no_action()
    local derived_line = "select * from (select id from public.orders) users"
    local _, derived_uri = make_buffer({ derived_line })
    did_open(client, derived_uri, 1, derived_line)
    local derived_lookup_count = 0
    cache.get_code_action_table_columns = function()
      derived_lookup_count = derived_lookup_count + 1
      fail("derived table alias reached cached column lookup")
    end
    local derived_star = position_of(derived_line, "*")
    local derived_expand = code_action(client, derived_uri, 0, derived_star, derived_star + 1, { "refactor.rewrite" })
    cache.get_code_action_table_columns = original_columns
    local derived_alias_pos = position_of(derived_line, "users")
    local derived_qualify = code_action(client, derived_uri, 0, derived_alias_pos, derived_alias_pos, { "refactor.rewrite" })
    local derived_reload = code_action(client, derived_uri, 0, derived_alias_pos, derived_alias_pos, { "source" })
    assert_eq("derived alias expand omitted", #derived_expand, 0)
    assert_eq("derived alias qualify omitted", #derived_qualify, 0)
    assert_eq("derived alias source only refresh", #derived_reload, 1)
    assert_true("derived alias refresh retained", first_command(derived_reload, "dbee/refresh_schema") ~= nil)
    assert_eq("derived alias lookup count", derived_lookup_count, 0)
    emit("LSP12_3_DERIVED_TABLE_ALIAS_NO_ACTION", "true")
  end
  check_derived_table_alias_no_action()
end

local qualify_line = "select id from orders"
local qualify_buf, qualify_uri = make_buffer({ qualify_line })
did_open(client, qualify_uri, 1, qualify_line)
local orders_pos = position_of(qualify_line, "orders")
local qualify = code_action(client, qualify_uri, 0, orders_pos, orders_pos, { "refactor.rewrite" })
local qualify_action = first_action(qualify, "Qualify identifier: orders -> public.orders")
assert_true("qualify action", qualify_action ~= nil)
assert_eq("qualify edit", qualify_action.edit.documentChanges[1].edits[1].newText, "public.")
emit("LSP12_3_QUALIFY_IDENTIFIER_OK", "true")

local ambiguous_line = "select id from users"
local ambiguous_buf, ambiguous_uri = make_buffer({ ambiguous_line })
did_open(client, ambiguous_uri, 1, ambiguous_line)
local ambiguous_pos = position_of(ambiguous_line, "users")
local ambiguous = code_action(client, ambiguous_uri, 0, ambiguous_pos, ambiguous_pos, { "refactor.rewrite" })
assert_eq("ambiguous qualify omitted", #ambiguous, 0)
emit("LSP12_3_QUALIFY_IDENTIFIER_AMBIGUOUS_NO_ACTION", "true")

local partial_handler = make_handler()
local partial_cache = SchemaCache:new(partial_handler, "lsp12-3-partial")
assert_true("partial schemas", partial_cache:build_from_schemas({
  { name = "public" },
  { name = "audit" },
}, { root_epoch = epoch_ref.value }))
assert_true("partial public load", partial_cache:on_schema_objects_loaded({
  conn_id = "lsp12-3-partial",
  schema = "public",
  root_epoch = epoch_ref.value,
  objects = {
    { name = "users", type = "table", schema = "public" },
  },
}))
partial_cache:_store_columns("public.users", {
  { name = "id", type = "integer" },
}, { root_epoch = epoch_ref.value })
local partial_client = client_for(partial_cache)
initialize(partial_client)
local partial_line = "select * from users"
local partial_buf, partial_uri = make_buffer({ partial_line })
did_open(partial_client, partial_uri, 1, partial_line)
local partial_star = position_of(partial_line, "*")
local partial_users = position_of(partial_line, "users")
assert_eq(
  "partial lazy expand omitted",
  #code_action(partial_client, partial_uri, 0, partial_star, partial_star + 1, { "refactor.rewrite" }),
  0
)
assert_eq(
  "partial lazy qualify omitted",
  #code_action(partial_client, partial_uri, 0, partial_users, partial_users, { "refactor.rewrite" }),
  0
)
local partial_source = code_action(partial_client, partial_uri, 0, partial_users, partial_users, { "source" })
assert_eq("partial lazy source only refresh", #partial_source, 1)
assert_true("partial lazy refresh retained", first_command(partial_source, "dbee/refresh_schema") ~= nil)
emit("LSP12_3_UNQUALIFIED_PARTIAL_LAZY_FAIL_CLOSED", "true")

local quoted_qualify_line = 'select id from "Case Table"'
local quoted_qualify_buf, quoted_qualify_uri = make_buffer({ quoted_qualify_line })
did_open(client, quoted_qualify_uri, 1, quoted_qualify_line)
local case_pos = position_of(quoted_qualify_line, "Case Table")
local quoted_qualify = code_action(client, quoted_qualify_uri, 0, case_pos, case_pos, { "refactor.rewrite" })
local quoted_qualify_action = quoted_qualify[1]
assert_true("quoted qualify action", quoted_qualify_action ~= nil)
assert_eq("quoted qualify edit", quoted_qualify_action.edit.documentChanges[1].edits[1].newText, '"Case Schema".')
emit("LSP12_3_QUALIFY_IDENTIFIER_QUOTED_PRESERVED", "true")

local already_line = "select id from public.orders"
local already_buf, already_uri = make_buffer({ already_line })
did_open(client, already_uri, 1, already_line)
local already_pos = position_of(already_line, "orders")
local already = code_action(client, already_uri, 0, already_pos, already_pos, { "refactor.rewrite" })
assert_eq("already qualified omitted", #already, 0)
emit("LSP12_3_QUALIFY_IDENTIFIER_ALREADY_QUALIFIED_NO_ACTION", "true")

local cte_qualify_pos = position_of(cte_line, "users", 2)
local cte_qualify = code_action(client, cte_uri, 0, cte_qualify_pos, cte_qualify_pos, { "refactor.rewrite" })
assert_eq("cte qualify omitted", #cte_qualify, 0)
emit("LSP12_3_QUALIFY_CTE_SHADOW_NO_ACTION", "true")

local source_line = "select id from public.orders"
local source_buf, source_uri = make_buffer({ source_line })
did_open(client, source_uri, 1, source_line)
local source_pos = position_of(source_line, "orders")
local source_actions = code_action(client, source_uri, 0, source_pos, source_pos, { "source" })
local refresh = first_command(source_actions, "dbee/refresh_schema")
local reload = first_command(source_actions, "dbee/reload_table")
assert_true("refresh action", refresh ~= nil)
assert_eq("refresh conn", refresh.command.arguments[1].conn_id, "lsp12-3")
emit("LSP12_3_REFRESH_SCHEMA_CMD_OK", "true")
assert_true("reload action", reload ~= nil)
assert_eq("reload schema", reload.command.arguments[1].schema, "public")
assert_eq("reload table", reload.command.arguments[1].table, "orders")
emit("LSP12_3_RELOAD_TABLE_METADATA_CMD_OK", "true")

execute_command(client, refresh.command.command, refresh.command.arguments[1])
execute_command(client, reload.command.command, reload.command.arguments[1])
assert_eq("refresh callback", command_calls.refresh, 1)
assert_eq("reload callback", command_calls.reload, 1)
emit("LSP12_3_WORKSPACE_EXECUTE_COMMAND_OK", "true")

local refresh_before = command_calls.refresh
execute_command(client, refresh.command.command, refresh.command.arguments[1])
assert_eq("refresh immediate scheduled", command_calls.refresh, refresh_before + 1)
emit("LSP12_3_REFRESH_CMD_IMMEDIATE_ASYNC", "true")

local immediate_cache, immediate_handler = make_cache()
local immediate_client, immediate_calls = client_for(immediate_cache)
initialize(immediate_client)
local immediate_buf, immediate_uri = make_buffer({ source_line })
did_open(immediate_client, immediate_uri, 1, source_line)
local immediate_source = code_action(immediate_client, immediate_uri, 0, source_pos, source_pos, { "source" })
local immediate_reload = first_command(immediate_source, "dbee/reload_table")
local async_before = immediate_handler.counters.connection_get_columns_async
execute_command(immediate_client, immediate_reload.command.command, immediate_reload.command.arguments[1])
assert_eq("reload callback immediate", immediate_calls.reload, 1)
assert_eq("reload async scheduled", immediate_handler.counters.connection_get_columns_async, async_before + 1)
emit("LSP12_3_RELOAD_CMD_IMMEDIATE_ASYNC", "true")

local filtered_args = vim.deepcopy(reload.command.arguments[1])
filtered_args.schema = "private"
filtered_args.table = "secrets"
scope_ref.value = schema_filter.normalize({ include = { "public" } }, "postgres")
local reload_before = command_calls.reload
execute_command(client, "dbee/reload_table", filtered_args)
assert_eq("filtered reload rejected", command_calls.reload, reload_before)
scope_ref.value = schema_filter.normalize(nil, "postgres")
emit("LSP12_3_RELOAD_CMD_SCOPE_FILTERED", "true")

local cte_source = code_action(client, cte_uri, 0, cte_qualify_pos, cte_qualify_pos, { "source" })
assert_eq("cte reload omitted source count", #cte_source, 1)
assert_true("cte refresh retained", first_command(cte_source, "dbee/refresh_schema") ~= nil)
emit("LSP12_3_RELOAD_CTE_SHADOW_NO_ACTION", "true")

scope_ref.value = nil
local authority_actions = code_action(client, uri, 0, star, star + 1)
assert_eq("authority fail closed", #authority_actions, 0)
scope_ref.value = schema_filter.normalize(nil, "postgres")
emit("LSP12_3_AUTHORITY_FAIL_CLOSED_NO_ACTIONS", "true")

epoch_ref.value = 2
local stale_actions = code_action(client, uri, 0, star, star + 1)
assert_eq("stale fail closed", #stale_actions, 0)
epoch_ref.value = 1
emit("LSP12_3_EPOCH_STALE_NO_ACTIONS", "true")

local stale_token = vim.deepcopy(refresh.command.arguments[1])
cache:invalidate()
local stale_before = command_calls.refresh
execute_command(client, "dbee/refresh_schema", stale_token)
assert_eq("stale command rejected", command_calls.refresh, stale_before)
emit("LSP12_3_COMMAND_STALE_TOKEN_REJECTED", "true")

cache, handler = make_cache()
client, command_calls = client_for(cache)
initialize(client)
local no_action_line = "select 1 from public.orders"
local no_action_buf, no_action_uri = make_buffer({ no_action_line })
did_open(client, no_action_uri, 1, no_action_line)
local one_pos = position_of(no_action_line, "1")
local no_actions = code_action(client, no_action_uri, 0, one_pos, one_pos, { "refactor" })
assert_eq("no actionable refactor", #no_actions, 0)
emit("LSP12_3_NO_ACTIONABLE_RANGE_EMPTY", "true")

local whitespace_buf, whitespace_uri = make_buffer({ "   " })
did_open(client, whitespace_uri, 1, "   ")
local whitespace_source = code_action(client, whitespace_uri, 0, 0, 0, { "source" })
assert_eq("whitespace source refresh only", #whitespace_source, 1)
assert_true("whitespace refresh returned", first_command(whitespace_source, "dbee/refresh_schema") ~= nil)
assert_eq("whitespace reload omitted", first_command(whitespace_source, "dbee/reload_table"), nil)
emit("LSP12_3_REFRESH_AVAILABLE_NO_STATEMENT_CONTEXT", "true")

local disabled_cache = make_cache()
local disabled_client, disabled_calls = client_for(disabled_cache, {
  lsp = { code_actions = false },
})
local disabled_init = initialize(disabled_client)
assert_eq("disabled code action provider", disabled_init.capabilities.codeActionProvider, nil)
assert_eq("disabled execute provider", disabled_init.capabilities.executeCommandProvider, nil)
local disabled_buf, disabled_uri = make_buffer({ line })
did_open(disabled_client, disabled_uri, 1, line)
local disabled_actions = code_action(disabled_client, disabled_uri, 0, star, star + 1)
assert_eq("disabled code actions", #disabled_actions, 0)
execute_command(disabled_client, "dbee/refresh_schema", refresh.command.arguments[1])
assert_eq("disabled direct command", disabled_calls.refresh, 0)
emit("LSP12_3_DISABLED_NO_CAPABILITY", "true")

local command_disabled_cache = make_cache()
local command_disabled_client, command_disabled_calls = client_for(command_disabled_cache, {
  lsp = {
    code_action_refresh_schema = false,
    code_action_reload_table_metadata = false,
  },
})
local command_disabled_init = initialize(command_disabled_client)
assert_eq("command disabled provider", command_disabled_init.capabilities.executeCommandProvider, nil)
local command_disabled_buf, command_disabled_uri = make_buffer({ source_line })
did_open(command_disabled_client, command_disabled_uri, 1, source_line)
local command_disabled_actions = code_action(command_disabled_client, command_disabled_uri, 0, source_pos, source_pos, { "source" })
assert_eq("disabled source commands", #command_disabled_actions, 0)
execute_command(command_disabled_client, "dbee/refresh_schema", refresh.command.arguments[1])
assert_eq("disabled direct refresh callback", command_disabled_calls.refresh, 0)
emit("LSP12_3_DISABLED_CMD_REJECTED_DIRECT", "true")

local order_line = "select * from orders"
local order_buf, order_uri = make_buffer({ order_line })
did_open(client, order_uri, 1, order_line)
local order_star = position_of(order_line, "*")
local order_end = position_of(order_line, "orders") + #"orders"
local ordered = code_action(client, order_uri, 0, order_star, order_end)
local titles = vim.tbl_map(function(action)
  return action.title
end, ordered)
assert_eq("ordered count", #ordered, 4)
assert_eq("ordered expand", titles[1], "Expand SELECT * -> list columns")
assert_true("ordered qualify", titles[2]:find("Qualify identifier", 1, true) == 1)
assert_eq("ordered reload", titles[3], "Reload table metadata")
assert_eq("ordered refresh", titles[4], "Refresh schema cache")
emit("LSP12_3_ACTION_ORDER_STABLE", "true")

local only_refactor = code_action(client, order_uri, 0, order_star, order_end, { "refactor" })
local only_rewrite = code_action(client, order_uri, 0, order_star, order_end, { "refactor.rewrite" })
local only_source = code_action(client, order_uri, 0, order_star, order_end, { "source" })
local mixed = code_action(client, order_uri, 0, order_star, order_end, { "source", "refactor" })
assert_eq("only refactor count", #only_refactor, 2)
assert_eq("only rewrite count", #only_rewrite, 2)
assert_eq("only source count", #only_source, 2)
assert_eq("mixed stable count", #mixed, 4)
emit("LSP12_3_CONTEXT_ONLY_PREFIX_MATCH_OK", "true")

local multistmt_line = "select '; from public.fake' as s; select * from public.orders"
local multistmt_buf, multistmt_uri = make_buffer({ multistmt_line })
did_open(client, multistmt_uri, 1, multistmt_line)
local multistmt_star = position_of(multistmt_line, "*")
local multistmt_actions = code_action(client, multistmt_uri, 0, multistmt_star, multistmt_star + 1, { "refactor.rewrite" })
assert_true("multistmt expand", first_action(multistmt_actions, "Expand SELECT * -> list columns") ~= nil)
emit("LSP12_3_MULTISTMT_SEMICOLON_AWARE", "true")

local edit_action = first_action(ordered, "Expand SELECT * -> list columns")
local doc_changes = edit_action.edit.documentChanges
assert_eq("documentChanges count", #doc_changes, 1)
assert_eq("single edit count", #doc_changes[1].edits, 1)
assert_true("versioned edit", type(doc_changes[1].textDocument.version) == "number")
emit("LSP12_3_EDIT_SINGLE_FILE_SINGLE_RANGE", "true")

local stale_buf, stale_uri = make_buffer({ order_line })
did_open(client, stale_uri, 1, order_line)
local stale_action = code_action(client, stale_uri, 0, order_star, order_star + 1, { "refactor.rewrite" })[1]
vim.api.nvim_buf_set_lines(stale_buf, 0, -1, false, { "select id from orders" })
did_change(client, stale_uri, 2, "select id from orders")
local stale_edit_version = stale_action.edit.documentChanges[1].textDocument.version
if vim.lsp.util.buf_versions then
  vim.lsp.util.buf_versions[stale_buf] = 2
end
pcall(vim.lsp.util.apply_workspace_edit, stale_action.edit, "utf-16")
local stale_after = vim.api.nvim_buf_get_lines(stale_buf, 0, -1, false)[1]
assert_eq("stale edit version captured", stale_edit_version, 1)
assert_eq("stale edit no-op", stale_after, "select id from orders")
emit("LSP12_3_STALE_EDIT_REJECTED", "true")

local request_db_cache, request_db_handler = make_cache()
local request_db_client = client_for(request_db_cache)
initialize(request_db_client)
local request_db_line = "select * from public.users"
local request_db_buf, request_db_uri = make_buffer({ request_db_line })
did_open(request_db_client, request_db_uri, 1, request_db_line)
local before_sync = request_db_handler.counters.connection_get_columns
local before_async = request_db_handler.counters.connection_get_columns_async
local request_db_star = position_of(request_db_line, "*")
code_action(request_db_client, request_db_uri, 0, request_db_star, request_db_star + 1)
assert_eq("no sync db", request_db_handler.counters.connection_get_columns - before_sync, 0)
assert_eq("no async db", request_db_handler.counters.connection_get_columns_async - before_async, 0)
emit("LSP12_3_NO_SYNC_DB", "true")
emit("LSP12_3_NO_ASYNC_DB", "true")

local function read_file(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    fail("unable to read " .. path)
  end
  return table.concat(lines, "\n")
end

local code_actions_text = read_file("lua/dbee/lsp/code_actions.lua")
local context_text = read_file("lua/dbee/lsp/context.lua")
local cache_text = read_file("lua/dbee/lsp/schema_cache.lua")
local server_text = read_file("lua/dbee/lsp/server.lua")
local init_text = read_file("lua/dbee/lsp/init.lua")
local function assert_absent(label, text, pattern, plain)
  assert_eq(label, text:find(pattern, 1, plain == true), nil)
end
local function slice(label, text, start_pattern, end_pattern)
  local start_pos = text:find(start_pattern, 1, true)
  if not start_pos then
    fail("missing static guard start: " .. label)
  end
  local end_pos = end_pattern and text:find(end_pattern, start_pos + 1, true) or nil
  if not end_pos then
    end_pos = #text + 1
  end
  return text:sub(start_pos, end_pos - 1)
end

assert_true("canonical helper used", code_actions_text:find("schema_name_canonical%.is_unquoted_canonical") ~= nil)
assert_true("epoch helper used", code_actions_text:find("epoch_authority%.check_fresh") ~= nil)
assert_true("reload helper present", cache_text:find("reload_table_metadata_async", 1, true) ~= nil)
assert_true("execute dispatch present", server_text:find("workspace/executeCommand", 1, true) ~= nil)
assert_true("init callbacks present", init_text:find("code_action_refresh_schema", 1, true) ~= nil)
local context_code_action_text = slice(
  "context code action helpers",
  context_text,
  "function M.code_action_statement",
  "function M.analyze"
)
local reload_helper_text = slice(
  "schema cache reload helper",
  cache_text,
  "function SchemaCache:reload_table_metadata_async",
  "--- Apply a structure_children_loaded column payload"
)
local server_code_action_text = slice(
  "server code action routes",
  server_text,
  'elseif method == "textDocument/codeAction"',
  "return true, current_id"
)
local init_command_text = slice(
  "init command callbacks",
  init_text,
  "local function code_action_command_context",
  "--- Start LSP with a populated cache."
)
assert_absent("code actions no connection_get", code_actions_text, "connection_get_", true)
assert_absent("context helpers no connection_get", context_code_action_text, "connection_get_", true)
assert_absent("server routes no connection_get", server_code_action_text, "connection_get_", true)
assert_absent("init callbacks no direct column db", init_command_text, "connection_get_columns", true)
assert_absent("init callbacks no direct schema object db", init_command_text, "connection_get_schema_objects", true)
assert_absent("code actions no handler epoch bypass", code_actions_text, "epoch_authority%.handler_epoch")
assert_absent("code actions no cache epoch bypass", code_actions_text, "epoch_authority%.cache_epoch")
assert_absent("code actions no read freshness bypass", code_actions_text, "epoch_authority%.read_with_freshness")
assert_absent("server route no authority helper", server_text, "schema_filter_authority", true)
assert_absent("context helpers no authority helper", context_code_action_text, "schema_filter_authority", true)
assert_absent("schema cache reload no current connection", reload_helper_text, "get_current_connection", true)
assert_absent("schema cache reload no structure refresh", reload_helper_text, "connection_get_structure", true)
assert_true("refresh command id present", code_actions_text:find('COMMAND_REFRESH_SCHEMA = "dbee/refresh_schema"', 1, true) ~= nil)
assert_true("reload command id present", code_actions_text:find('COMMAND_RELOAD_TABLE = "dbee/reload_table"', 1, true) ~= nil)
emit("LSP12_3_NEW_CODE_ACTION_NO_HELPER_BYPASS", "true")

local makefile_text = read_file("Makefile")
local sentinel_pos = makefile_text:find("check_lsp12_3_code_actions.lua", 1, true)
local rollup_pos = makefile_text:find("lsp12%-rollup")
assert_true("make perf-lsp wired", sentinel_pos ~= nil and rollup_pos ~= nil and sentinel_pos < rollup_pos)
emit("LSP12_3_MAKE_PERF_LSP_WIRED", "true")

local old_export = vim.env.LSP12_ROLLUP_EXPORT
vim.env.LSP12_ROLLUP_EXPORT = "1"
local rollup = dofile("ci/headless/check_lsp12_rollup.lua")
vim.env.LSP12_ROLLUP_EXPORT = old_export
local rollup_lines = {}
for _, marker in ipairs(rollup.required_lsp12_3_true_markers) do
  rollup_lines[#rollup_lines + 1] = marker .. "=true"
end
for label, expected in pairs(rollup.required_lsp12_3_metric_markers) do
  rollup_lines[#rollup_lines + 1] = label .. "=" .. (expected == "number" and "1.00" or expected)
end
local rollup_result = rollup.evaluate_lsp12_3(rollup_lines)
assert_true("rollup valid", rollup_result.ok)
rollup_lines[#rollup_lines + 1] = "LSP12_3_EXPAND_SELECT_STAR_OK=true"
local duplicate = rollup.evaluate_lsp12_3(rollup_lines)
assert_true("rollup duplicate rejected", not duplicate.ok)
emit("LSP12_3_ROLLUP_EXACTLY_ONCE_OK", "true")

emit("LSP12_3_ALL_FUNCTIONAL_SENTINELS_DONE", "true")
vim.cmd("qa!")
