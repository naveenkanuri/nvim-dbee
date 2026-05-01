-- Headless Phase 12.1 checks for LSP hover and completionItem/resolve.

vim.env.XDG_STATE_HOME = vim.fn.tempname()
vim.fn.mkdir(vim.env.XDG_STATE_HOME, "p")

package.preload["nio"] = package.preload["nio"] or function()
  return {}
end

local SchemaCache = require("dbee.lsp.schema_cache")
local server = require("dbee.lsp.server")
local hover = require("dbee.lsp.hover")
local resolve = require("dbee.lsp.resolve")
local docs = require("dbee.lsp.object_docs")
local schema_filter = require("dbee.schema_filter")

local function fail(msg)
  print("LSP12_FAIL=" .. tostring(msg))
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

local function assert_false(label, value)
  if value then
    fail(label .. ": expected false")
  end
end

local function assert_eq(label, actual, expected)
  if actual ~= expected then
    fail(label .. ": expected " .. vim.inspect(expected) .. " got " .. vim.inspect(actual))
  end
end

local scope_ref = { value = schema_filter.normalize(nil, "postgres") }
local epoch_ref = { value = 1 }

local function make_handler()
  local handler = {
    counters = {
      sync = 0,
      async = 0,
      authority = 0,
    },
  }
  function handler:get_schema_filter_normalized()
    handler.counters.authority = handler.counters.authority + 1
    return scope_ref.value
  end
  function handler:get_authoritative_root_epoch()
    return epoch_ref.value
  end
  function handler:get_current_connection()
    return { id = "lsp12", type = "postgres" }
  end
  function handler:connection_get_columns()
    handler.counters.sync = handler.counters.sync + 1
    return {}
  end
  function handler:connection_get_columns_async(conn_id, request_id, branch_id, root_epoch, request)
    handler.counters.async = handler.counters.async + 1
    handler.last_columns_async = {
      conn_id = conn_id,
      request_id = request_id,
      branch_id = branch_id,
      root_epoch = root_epoch,
      request = request,
    }
  end
  function handler:connection_get_schema_objects_singleflight()
    handler.counters.async = handler.counters.async + 1
    return {}
  end
  function handler:connection_get_structure_singleflight()
    handler.counters.async = handler.counters.async + 1
    return {}
  end
  return handler
end

local function rows()
  return {
    { schema_name = "public", table_name = "users", obj_type = "table" },
    { schema_name = "public", table_name = "orders", obj_type = "table" },
    { schema_name = "Public", table_name = "users", obj_type = "table" },
  }
end

local function make_cache(conn_id)
  scope_ref.value = schema_filter.normalize(nil, "postgres")
  epoch_ref.value = 1
  local handler = make_handler()
  local cache = SchemaCache:new(handler, conn_id or "lsp12")
  cache:build_from_metadata_rows(rows())
  cache:_store_columns("public.users", {
    { name = "id", type = "integer", nullable = false, primary_key = true },
    { name = "email", type = "text", nullable = true, default = "''" },
  })
  cache:_store_columns("public.orders", {
    { name = "id", type = "integer" },
    { name = "user_id", type = "integer", foreign_key = "public.users.id" },
  })
  cache:_store_columns("Public.users", {
    { name = "id", type = "text" },
  })
  return cache, handler
end

local function make_buffer(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, "/tmp/dbee-lsp12-" .. tostring(math.random(1000000)) .. ".sql")
  vim.api.nvim_buf_set_option(bufnr, "filetype", "sql")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  return bufnr, vim.uri_from_bufnr(bufnr)
end

local function position_of(line, needle, occurrence)
  occurrence = occurrence or 1
  local init = 1
  local start_pos
  for _ = 1, occurrence do
    start_pos = line:find(needle, init, true)
    if not start_pos then
      fail("missing needle " .. tostring(needle) .. " in " .. tostring(line))
    end
    init = start_pos + #needle
  end
  return start_pos - 1
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

local function request_hover(client, uri, line, character)
  return request(client, "textDocument/hover", {
    textDocument = { uri = uri },
    position = { line = line, character = character },
  })
end

local function request_resolve(client, item)
  return request(client, "completionItem/resolve", item)
end

local function first_label(items, label)
  for _, item in ipairs(items or {}) do
    if item.label == label then
      return item
    end
  end
  return nil
end

local function memo_entry_count(memo)
  local count = 0
  for key in pairs(memo or {}) do
    if key ~= "__dbee_generation" then
      count = count + 1
    end
  end
  return count
end

local cache, handler = make_cache("lsp12-main")
local client = server.create(cache)({}, {})
local init = request(client, "initialize", {
  capabilities = {
    textDocument = {
      hover = { contentFormat = { "markdown", "plaintext" } },
      completion = {
        completionItem = {
          documentationFormat = { "markdown", "plaintext" },
        },
      },
    },
  },
})
assert_eq("hover capability", init.capabilities.hoverProvider, true)
assert_eq("resolve capability", init.capabilities.completionProvider.resolveProvider, true)

handler.counters.sync = 0
handler.counters.async = 0

local table_line = "select * from public.users u where u.id = 1"
local bufnr, uri = make_buffer({ table_line })
local table_hover = request_hover(client, uri, 0, position_of(table_line, "users"))
assert_true("table hover", table_hover and table_hover.contents and table_hover.contents.value:find("public", 1, true))
emit("LSP12_HOVER_TABLE_OK", "true")

local column_hover = request_hover(client, uri, 0, position_of(table_line, "id"))
assert_true("column hover", column_hover and column_hover.contents.value:find("integer", 1, true))
emit("LSP12_HOVER_COLUMN_OK", "true")

local schema_hover = request_hover(client, uri, 0, position_of(table_line, "public"))
assert_true("schema hover", schema_hover and schema_hover.contents.value:find("Schema", 1, true))
emit("LSP12_HOVER_SCHEMA_OK", "true")

local keyword_hover = request_hover(client, uri, 0, position_of(table_line, "select"))
assert_eq("keyword hover", keyword_hover, nil)
emit("LSP12_HOVER_NIL_ON_KEYWORD", "true")

local unknown_buf, unknown_uri = make_buffer({ "select missing_col" })
local unknown_hover = request_hover(client, unknown_uri, 0, position_of("select missing_col", "missing_col"))
assert_eq("unknown hover", unknown_hover, nil)
emit("LSP12_HOVER_NIL_ON_UNKNOWN", "true")

scope_ref.value = nil
local denied_hover = request_hover(client, uri, 0, position_of(table_line, "users"))
assert_eq("authority hover", denied_hover, nil)
emit("LSP12_HOVER_AUTHORITY_FAIL_CLOSED", "true")
scope_ref.value = schema_filter.normalize(nil, "postgres")

local upper_line = "select * from PUBLIC.USERS"
local upper_buf, upper_uri = make_buffer({ upper_line })
local upper_hover = request_hover(client, upper_uri, 0, position_of(upper_line, "USERS"))
assert_true("canonical hover", upper_hover and upper_hover.contents.value:find("public", 1, true))
emit("LSP12_HOVER_CANONICAL_LOOKUP_OK", "true")

local quoted_line = 'select * from "Public".users'
local quoted_buf, quoted_uri = make_buffer({ quoted_line })
local quoted_hover = request_hover(client, quoted_uri, 0, position_of(quoted_line, "users"))
assert_true("quoted hover", quoted_hover and quoted_hover.contents.value:find("Public", 1, true))
emit("LSP12_HOVER_QUOTED_CASE_PRESERVED", "true")

local markdown = docs.format_hover({
  kind = "column",
  schema = "public",
  table = "bad|`name",
  column = "id*",
  type = "text",
}, {})
assert_eq("markdown kind", markdown.kind, "markdown")
assert_true("markdown escaped pipe", markdown.value:find("\\|", 1, true) ~= nil)
assert_true("markdown escaped star", markdown.value:find("\\*", 1, true) ~= nil)
local resolve_plain = docs.format_resolve({
  kind = "table",
  schema = "public",
  table = "users",
  table_type = "table",
}, nil, {
  client_capabilities = {
    textDocument = {
      completion = {
        completionItem = {
          documentationFormat = { "plaintext" },
        },
      },
    },
  },
})
assert_eq("resolve plaintext fallback", resolve_plain.documentation.kind, "plaintext")
emit("LSP12_HOVER_MARKDOWN_FORMAT_OK", "true")

local backtick_markdown = docs.format_hover({
  kind = "schema",
  schema = "weird``name",
  tables = {},
  table_count = 0,
}, {})
assert_true("backtick code span delimiter", backtick_markdown.value:find("``` weird``name ```", 1, true) ~= nil)
emit("LSP12_HOVER_MARKDOWN_BACKTICK_SAFE", "true")

local long_lines = {}
for i = 1, 6 do
  long_lines[i] = "select id"
end
local long_buf, long_uri = make_buffer(long_lines)
local bounded = hover.handle({
  textDocument = { uri = long_uri },
  position = { line = 3, character = 7 },
}, cache, { max_scan_lines = 2 })
assert_eq("bounded scan", bounded, nil)
emit("LSP12_HOVER_CONTEXT_SCAN_BOUNDED", "true")

local select_line = "SELECT id FROM public.users"
local select_buf, select_uri = make_buffer({ select_line })
local select_hover = request_hover(client, select_uri, 0, position_of(select_line, "id"))
assert_true("select-list single table", select_hover and select_hover.contents.value:find("integer", 1, true))
emit("LSP12_HOVER_SELECT_LIST_SINGLE_TABLE_OK", "true")

local ambiguous_line = "SELECT id FROM public.users u JOIN public.orders o ON u.id = o.id"
local ambiguous_buf, ambiguous_uri = make_buffer({ ambiguous_line })
local ambiguous_hover = request_hover(client, ambiguous_uri, 0, position_of(ambiguous_line, "id"))
assert_eq("ambiguous select-list", ambiguous_hover, nil)
emit("LSP12_HOVER_SELECT_LIST_AMBIGUOUS_NIL", "true")

local comma_from_line = "SELECT id FROM public.users, public.orders"
local comma_from_buf, comma_from_uri = make_buffer({ comma_from_line })
local comma_from_hover = request_hover(client, comma_from_uri, 0, position_of(comma_from_line, "id"))
assert_eq("comma from ambiguous select-list", comma_from_hover, nil)
emit("LSP12_HOVER_COMMA_FROM_AMBIGUOUS_NIL", "true")

local semicolon_line = "SELECT * FROM public.orders; SELECT id FROM public.users"
local semicolon_buf, semicolon_uri = make_buffer({ semicolon_line })
local semicolon_hover = request_hover(client, semicolon_uri, 0, position_of(semicolon_line, "id"))
assert_true("same-line semicolon column hover", semicolon_hover and semicolon_hover.contents.value:find("Primary key", 1, true))
assert_true("same-line semicolon not previous table", not semicolon_hover.contents.value:find("orders%.id"))
emit("LSP12_HOVER_SAME_LINE_SEMICOLON_OK", "true")

assert_eq("hover sync db calls", handler.counters.sync, 0)
assert_eq("hover async db calls", handler.counters.async, 0)
emit("LSP12_HOVER_NO_SYNC_DB", "true")
emit("LSP12_HOVER_NO_ASYNC_DB", "true")

cache:_upsert_table_index("public", "wide_table", "table")
local wide_columns = {}
for i = 1, 250 do
  wide_columns[#wide_columns + 1] = { name = "col_" .. tostring(i), type = "text" }
end
cache:_store_columns("public.wide_table", wide_columns)
local wide_meta = cache:get_table_metadata("public", "wide_table", {
  schema_quoted = true,
  table_quoted = true,
  max_columns = 20,
})
assert_eq("wide table total count", wide_meta.column_count, 250)
assert_true("wide table copied bounded", #wide_meta.columns <= 20 and wide_meta.columns_copied <= 20)
assert_true("wide table truncated", wide_meta.columns_truncated == true)
local wide_docs = docs.format_hover(wide_meta, {})
assert_true("wide table truncation doc", wide_docs.value:find("showing first 20 of 250 columns", 1, true) ~= nil)
local wide_col = cache:get_column_metadata("public", "wide_table", "col_250", {
  schema_quoted = true,
  table_quoted = true,
})
assert_eq("wide column direct lookup", wide_col and wide_col.column, "col_250")
emit("LSP12_HOVER_WIDE_TABLE_BOUNDED_COPY", "true")

handler.counters.sync = 0
handler.counters.async = 0

local schema_item = first_label(cache:get_schema_completion_items({ include_data = true }), "public")
local table_item = first_label(cache:get_table_completion_items("public", { schema_quoted = true, include_data = true }), "users")
local column_item = first_label(cache:get_column_completion_items("public", "users", {
  schema_quoted = true,
  table_quoted = true,
  include_data = true,
}), "id")
assert_true("schema item data", schema_item and schema_item.data)
assert_true("table item data", table_item and table_item.data)
assert_true("column item data", column_item and column_item.data)

local resolved_schema = request_resolve(client, schema_item)
assert_true("schema docs", resolved_schema.documentation and resolved_schema.documentation.value:find("Schema", 1, true))
emit("LSP12_RESOLVE_SCHEMA_DOCS_OK", "true")

local resolved_table = request_resolve(client, table_item)
assert_true("table docs", resolved_table.documentation and resolved_table.documentation.value:find("users", 1, true))
emit("LSP12_RESOLVE_TABLE_DOCS_OK", "true")

local resolved_column = request_resolve(client, column_item)
assert_true("column docs", resolved_column.documentation and resolved_column.documentation.value:find("integer", 1, true))
emit("LSP12_RESOLVE_COLUMN_DOCS_OK", "true")

local non_dbee = { label = "SELECT", kind = 14, detail = "keyword" }
local non_dbee_resolved = request_resolve(client, non_dbee)
assert_eq("non dbee passthrough detail", non_dbee_resolved.detail, "keyword")
assert_eq("non dbee passthrough docs", non_dbee_resolved.documentation, nil)
emit("LSP12_RESOLVE_NON_DBEE_ITEM_PASSTHROUGH", "true")

local stale_item = vim.deepcopy(table_item)
cache:_store_columns("public.users", {
  { name = "id", type = "integer" },
  { name = "email", type = "text" },
  { name = "extra_col", type = "text" },
})
local stale_resolved = request_resolve(client, stale_item)
assert_eq("stale no docs", stale_resolved.documentation, nil)
assert_eq("stale incomplete", stale_resolved.data.dbee_resolve_status, "incomplete")
emit("LSP12_RESOLVE_STALE_RETURNS_INCOMPLETE", "true")

local fresh_table_item = first_label(cache:get_table_completion_items("public", { schema_quoted = true, include_data = true }), "users")
local fresh_resolved = request_resolve(client, fresh_table_item)
assert_true("fresh generation docs", fresh_resolved.documentation ~= nil)
emit("LSP12_RESOLVE_FRESH_ITEM_GENERATION_OK", "true")

scope_ref.value = nil
local denied_resolve = request_resolve(client, fresh_table_item)
assert_eq("authority resolve docs", denied_resolve.documentation, nil)
assert_eq("authority resolve incomplete", denied_resolve.data.dbee_resolve_status, "incomplete")
emit("LSP12_RESOLVE_AUTHORITY_FAIL_CLOSED", "true")
scope_ref.value = schema_filter.normalize(nil, "postgres")

local completion_line = "SELECT i"
local comp_buf, comp_uri = make_buffer({ completion_line })
local completion_result = request(client, "textDocument/completion", {
  textDocument = { uri = comp_uri },
  position = { line = 0, character = #completion_line },
})
local global_id = first_label(completion_result.items, "id")
assert_true("global id exists", global_id ~= nil)
assert_eq("global id ambiguous no data", global_id.data, nil)
local global_resolved = request_resolve(client, global_id)
assert_eq("global id passthrough docs", global_resolved.documentation, nil)
emit("LSP12_RESOLVE_GLOBAL_COLUMN_AMBIGUOUS_PASSTHROUGH", "true")

local table_completion_line = "SELECT * FROM u"
local table_comp_buf, table_comp_uri = make_buffer({ table_completion_line })
local table_completion_result = request(client, "textDocument/completion", {
  textDocument = { uri = table_comp_uri },
  position = { line = 0, character = #table_completion_line },
})
local ambiguous_users = first_label(table_completion_result.items, "users")
assert_true("ambiguous global users exists", ambiguous_users ~= nil)
assert_eq("ambiguous global users no data", ambiguous_users.data, nil)
local ambiguous_users_resolved = request_resolve(client, ambiguous_users)
assert_eq("ambiguous global users no docs", ambiguous_users_resolved.documentation, nil)
local unique_orders = first_label(table_completion_result.items, "orders")
assert_true("unique global orders data", unique_orders and unique_orders.data)
local unique_orders_resolved = request_resolve(client, unique_orders)
assert_true("unique global orders docs", unique_orders_resolved.documentation ~= nil)
emit("LSP12_RESOLVE_AMBIGUOUS_GLOBAL_NO_DOCS", "true")

local public_item = first_label(cache:get_table_completion_items("public", { schema_quoted = true, include_data = true }), "users")
local mixed_item = first_label(cache:get_table_completion_items("Public", { schema_quoted = true, include_data = true }), "users")
local public_doc = resolve.handle(public_item, cache, { memo = {} })
local mixed_doc = resolve.handle(mixed_item, cache, { memo = {} })
assert_true("exact docs differ", public_doc.documentation.value ~= mixed_doc.documentation.value)
emit("LSP12_RESOLVE_EXACT_CASE_PRESERVED", "true")

local memo = {}
local first_public = resolve.handle(public_item, cache, { memo = memo })
local first_mixed = resolve.handle(mixed_item, cache, { memo = memo })
local second_mixed = resolve.handle(mixed_item, cache, { memo = memo })
local second_public = resolve.handle(public_item, cache, { memo = memo })
assert_eq("memo public stable", first_public.documentation.value, second_public.documentation.value)
assert_eq("memo mixed stable", first_mixed.documentation.value, second_mixed.documentation.value)
assert_true("memo exact distinct", first_public.documentation.value ~= first_mixed.documentation.value)
emit("LSP12_RESOLVE_MEMO_EXACT_DISTINCT", "true")

local prior_resolved = resolve.handle(public_item, cache, { memo = {} })
scope_ref.value = nil
local scrubbed_authority = resolve.handle(prior_resolved, cache, { memo = {} })
assert_eq("authority scrub docs", scrubbed_authority.documentation, nil)
assert_eq("authority scrub detail", scrubbed_authority.detail, nil)
emit("LSP12_RESOLVE_AUTHORITY_SCRUBS_PRIOR_DOCS", "true")
scope_ref.value = schema_filter.normalize(nil, "postgres")

local prior_resolved_gen = resolve.handle(first_label(cache:get_table_completion_items("public", { schema_quoted = true, include_data = true }), "users"), cache, { memo = {} })
cache:_store_columns("public.users", {
  { name = "id", type = "integer" },
  { name = "email", type = "text" },
})
local scrubbed_gen = resolve.handle(prior_resolved_gen, cache, { memo = {} })
assert_eq("generation scrub docs", scrubbed_gen.documentation, nil)
assert_eq("generation scrub detail", scrubbed_gen.detail, nil)
emit("LSP12_RESOLVE_GEN_BUMP_SCRUBS_PRIOR_DOCS", "true")

local stale_authority_cache, stale_authority_handler = make_cache("lsp12-stale-authority")
local stale_authority_item = first_label(stale_authority_cache:get_table_completion_items("public", {
  schema_quoted = true,
  include_data = true,
}), "users")
stale_authority_cache:_store_columns("public.users", {
  { name = "id", type = "integer" },
  { name = "email", type = "text" },
  { name = "authority_probe", type = "text" },
})
stale_authority_handler.counters.authority = 0
local stale_authority_result = resolve.handle(stale_authority_item, stale_authority_cache, { memo = {} })
assert_eq("stale authority status", stale_authority_result.data.dbee_resolve_status, "incomplete")
assert_true("stale path checked authority", stale_authority_handler.counters.authority > 0)
emit("LSP12_RESOLVE_STALE_PATH_CHECKS_AUTHORITY", "true")

local function synthetic_table_item(test_cache, generation, schema, table_name)
  return {
    label = table_name,
    data = {
      source = "dbee",
      version = 1,
      kind = "table",
      schema = schema,
      table = table_name,
      schema_exact = schema,
      table_exact = table_name,
      schema_quoted = true,
      table_quoted = true,
      cache_identity = test_cache:cache_identity(),
      cache_generation = generation,
      root_epoch = test_cache:authoritative_root_epoch(),
    },
  }
end

do
  local invalid_cache, invalid_handler = make_cache("lsp12-invalid")
  function invalid_handler:get_current_connection()
    return { id = "lsp12-invalid", type = "postgres" }
  end
  local invalid_item = first_label(invalid_cache:get_table_completion_items("public", {
    schema_quoted = true,
    include_data = true,
  }), "users")
  local before_generation = invalid_cache:generation()
  local old_state = package.loaded["dbee.api.state"]
  local old_lsp_init = package.loaded["dbee.lsp.init"]
  package.loaded["dbee.lsp.init"] = nil
  package.loaded["dbee.api.state"] = {
    is_core_loaded = function()
      return true
    end,
    handler = function()
      return invalid_handler
    end,
    config = function()
      return { lsp = {} }
    end,
  }
  local lsp_init = require("dbee.lsp.init")
  lsp_init._cache = invalid_cache
  lsp_init._conn_id = "lsp12-invalid"
  lsp_init._connection_invalidated_consumer_live = true
  lsp_init._pending_connection_invalidations = {
    { current_conn_id_after = "lsp12-invalid" },
  }
  lsp_init._flush_connection_invalidations()
  package.loaded["dbee.api.state"] = old_state
  package.loaded["dbee.lsp.init"] = old_lsp_init
  assert_true("invalidation generation bump", invalid_cache:generation() > before_generation)
  local invalid_resolved = resolve.handle(invalid_item, invalid_cache, { memo = {} })
  assert_eq("invalidation old item incomplete", invalid_resolved.data.dbee_resolve_status, "incomplete")
  emit("LSP12_RESOLVE_INVALIDATION_BUMPS_GENERATION", "true")
end

do
  local lag_cache, lag_handler = make_cache("lsp12-invalid-lag")
  function lag_handler:get_current_connection()
    return { id = "lsp12-invalid-lag", type = "postgres" }
  end
  local old_state = package.loaded["dbee.api.state"]
  local old_lsp_init = package.loaded["dbee.lsp.init"]
  package.loaded["dbee.lsp.init"] = nil
  package.loaded["dbee.api.state"] = {
    is_core_loaded = function()
      return true
    end,
    handler = function()
      return lag_handler
    end,
    config = function()
      return { lsp = {} }
    end,
  }
  local lsp_init = require("dbee.lsp.init")
  lsp_init._cache = lag_cache
  lsp_init._conn_id = "lsp12-invalid-lag"
  lsp_init._connection_invalidated_consumer_live = true
  lsp_init._pending_connection_invalidations = {}
  lsp_init._connection_invalidation_flush_scheduled = false
  epoch_ref.value = 2
  lsp_init._on_connection_invalidated({
    current_conn_id_after = "lsp12-invalid-lag",
    authoritative_root_epoch = 2,
  })
  local lag_line = "select * from public.users u where u.id = 1"
  local lag_buf, lag_uri = make_buffer({ lag_line })
  local lag_hover = hover.handle({
    textDocument = { uri = lag_uri },
    position = { line = 0, character = position_of(lag_line, "users") },
  }, lag_cache)
  assert_eq("hover invalidation lag no docs", lag_hover, nil)
  emit("LSP12_HOVER_INVALIDATION_LAG_FAIL_CLOSED", "true")
  local lag_item = first_label(lag_cache:get_table_completion_items("public", {
    schema_quoted = true,
    include_data = true,
  }), "users")
  assert_true("invalidation lag item data", lag_item and lag_item.data)
  assert_eq("invalidation lag cache-owned epoch", lag_item.data.root_epoch, 1)
  local lag_resolved = resolve.handle(lag_item, lag_cache, { memo = {} })
  assert_eq("invalidation lag no docs", lag_resolved.documentation, nil)
  assert_eq("invalidation lag incomplete", lag_resolved.data.dbee_resolve_status, "incomplete")
  lsp_init._pending_connection_invalidations = {}
  lsp_init._connection_invalidated_consumer_live = false
  package.loaded["dbee.api.state"] = old_state
  package.loaded["dbee.lsp.init"] = old_lsp_init
  epoch_ref.value = 1
  emit("LSP12_RESOLVE_INVALIDATION_LAG_FAIL_CLOSED", "true")
end

do
  local disk_cache = make_cache("lsp12-disk-epoch")
  disk_cache:save_to_disk()
  disk_cache:_save_columns_to_disk("public.users", disk_cache.columns["public.users"])
  epoch_ref.value = 2
  local loaded_cache = SchemaCache:new(make_handler(), "lsp12-disk-epoch")
  assert_true("disk epoch stale cache loads", loaded_cache:load_from_disk())
  assert_eq("disk epoch restored from disk", loaded_cache:metadata_root_epoch(), 1)

  local disk_line = "select id from public.users"
  local disk_buf, disk_uri = make_buffer({ disk_line })
  local disk_hover = hover.handle({
    textDocument = { uri = disk_uri },
    position = { line = 0, character = position_of(disk_line, "id") },
  }, loaded_cache)
  assert_eq("disk stale hover no docs", disk_hover, nil)

  local disk_table_item = first_label(loaded_cache:get_table_completion_items("public", {
    schema_quoted = true,
    include_data = true,
  }), "users")
  assert_true("disk stale table item", disk_table_item and disk_table_item.data)
  local disk_table_resolved = resolve.handle(disk_table_item, loaded_cache, { memo = {} })
  assert_eq("disk stale table no docs", disk_table_resolved.documentation, nil)
  assert_eq("disk stale table incomplete", disk_table_resolved.data.dbee_resolve_status, "incomplete")

  local disk_column_item = first_label(loaded_cache:get_column_completion_items("public", "users", {
    schema_quoted = true,
    table_quoted = true,
    include_data = true,
  }), "id")
  assert_true("disk stale column item", disk_column_item and disk_column_item.data)
  local disk_column_resolved = resolve.handle(disk_column_item, loaded_cache, { memo = {} })
  assert_eq("disk stale column no docs", disk_column_resolved.documentation, nil)
  assert_eq("disk stale column incomplete", disk_column_resolved.data.dbee_resolve_status, "incomplete")
  epoch_ref.value = 1
  emit("LSP12_DISK_CACHE_EPOCH_FAIL_CLOSED", "true")
end

local function assert_path_generation(label, before_cache, mutate, fresh_item, destructive)
  local old_item = synthetic_table_item(before_cache, before_cache:generation(), "public", "users")
  mutate(before_cache)
  local old_result = resolve.handle(old_item, before_cache, { memo = {} })
  assert_eq(label .. " old incomplete", old_result.data.dbee_resolve_status, "incomplete")
  if destructive then
    local fresh = fresh_item(before_cache)
    assert_true(label .. " no fresh docs", not fresh)
    return
  end
  local fresh = fresh_item(before_cache)
  assert_true(label .. " fresh item", fresh and fresh.data)
  local fresh_result = resolve.handle(fresh, before_cache, { memo = {} })
  assert_true(label .. " fresh docs", fresh_result.documentation ~= nil)
end

do
  local c = SchemaCache:new(make_handler(), "lsp12-gen-initial")
  assert_path_generation("initial_load", c, function(target)
    target:build_from_metadata_rows({ { schema_name = "public", table_name = "users", obj_type = "table" } })
  end, function(target)
    return first_label(target:get_table_completion_items("public", { schema_quoted = true, include_data = true }), "users")
  end)

  local c2 = make_cache("lsp12-gen-structure")
  assert_path_generation("structure_refresh", c2, function(target)
    target:build_from_structure({
      { type = "schema", name = "public", schema = "public", children = {
        { type = "table", schema = "public", name = "users" },
      } },
    })
  end, function(target)
    return first_label(target:get_table_completion_items("public", { schema_quoted = true, include_data = true }), "users")
  end)

  local c3 = make_cache("lsp12-gen-schema-list")
  assert_path_generation("schema_list_reload", c3, function(target)
    target:build_from_schemas({ "public" }, { preserve_loaded = false })
    target:on_schema_objects_loaded({
      conn_id = "lsp12-gen-schema-list",
      schema = "public",
      objects = {
        { type = "table", schema = "public", name = "users" },
      },
    })
  end, function(target)
    return first_label(target:get_table_completion_items("public", { schema_quoted = true, include_data = true }), "users")
  end)

  local c4_handler = make_handler()
  local c4 = SchemaCache:new(c4_handler, "lsp12-gen-columns")
  c4:build_from_metadata_rows({ { schema_name = "public", table_name = "users", obj_type = "table" } })
  local old_columns_item = synthetic_table_item(c4, c4:generation(), "public", "users")
  local async_result = c4:get_columns_async("public", "users", {
    schema_quoted = true,
    table_quoted = true,
  })
  assert_true("columns async should be incomplete", async_result.is_incomplete)
  assert_true("columns async request captured", c4_handler.last_columns_async ~= nil)
  assert_true("columns loaded applied", c4:on_columns_loaded({
    conn_id = "lsp12-gen-columns",
    kind = "columns",
    request_id = c4_handler.last_columns_async.request_id,
    branch_id = c4_handler.last_columns_async.branch_id,
    root_epoch = c4_handler.last_columns_async.root_epoch,
    columns = { { name = "id", type = "integer" } },
  }))
  local old_columns_result = resolve.handle(old_columns_item, c4, { memo = {} })
  assert_eq("on_columns_loaded old incomplete", old_columns_result.data.dbee_resolve_status, "incomplete")
  local fresh_columns_item = first_label(c4:get_column_completion_items("public", "users", {
    schema_quoted = true,
    table_quoted = true,
    include_data = true,
  }), "id")
  assert_true("on_columns_loaded fresh item", fresh_columns_item and fresh_columns_item.data)
  local fresh_columns_result = resolve.handle(fresh_columns_item, c4, { memo = {} })
  assert_true("on_columns_loaded fresh docs", fresh_columns_result.documentation ~= nil)

  local c5 = make_cache("lsp12-gen-schema-objects")
  assert_path_generation("on_schema_objects_loaded", c5, function(target)
    target:on_schema_objects_loaded({
      conn_id = "lsp12-gen-schema-objects",
      schema = "public",
      objects = {
        { type = "table", schema = "public", name = "users" },
      },
    })
  end, function(target)
    return first_label(target:get_table_completion_items("public", { schema_quoted = true, include_data = true }), "users")
  end)

  local c6 = make_cache("lsp12-gen-disk")
  c6:save_to_disk()
  local c6_loaded = SchemaCache:new(make_handler(), "lsp12-gen-disk")
  assert_path_generation("load_from_disk", c6_loaded, function(target)
    assert_true("disk load", target:load_from_disk())
  end, function(target)
    return first_label(target:get_table_completion_items("public", { schema_quoted = true, include_data = true }), "users")
  end)

  local c7 = make_cache("lsp12-gen-invalidate")
  assert_path_generation("invalidate", c7, function(target)
    target:invalidate()
  end, function(target)
    return first_label(target:get_table_completion_items("public", { schema_quoted = true, include_data = true }), "users")
  end, true)

  local c8 = make_cache("lsp12-gen-fail-closed")
  assert_path_generation("refresh_schema_scope_fail_closed", c8, function(target)
    scope_ref.value = nil
    target:refresh_schema_scope()
    scope_ref.value = schema_filter.normalize(nil, "postgres")
  end, function(target)
    return first_label(target:get_table_completion_items("public", { schema_quoted = true, include_data = true }), "users")
  end, true)
end
emit("LSP12_RESOLVE_GENERATION_PROOF_ALL_PATHS", "true")

local memo_gen_item = first_label(cache:get_table_completion_items("public", { schema_quoted = true, include_data = true }), "users")
local memo_gen = resolve.handle(memo_gen_item, cache, { memo = {} })
local memo_gen_again = resolve.handle(memo_gen_item, cache, { memo = {} })
assert_eq("memo generation stable", memo_gen.documentation.value, memo_gen_again.documentation.value)
cache:_store_columns("public.users", {
  { name = "id", type = "integer" },
  { name = "email", type = "text" },
  { name = "last_gen", type = "text" },
})
local memo_stale = resolve.handle(memo_gen_item, cache, { memo = {} })
assert_eq("memo generation stale", memo_stale.data.dbee_resolve_status, "incomplete")
emit("LSP12_RESOLVE_MEMO_PER_GENERATION_OK", "true")

local prune_cache = make_cache("lsp12-memo-prune")
local prune_item = first_label(prune_cache:get_table_completion_items("public", {
  schema_quoted = true,
  include_data = true,
}), "users")
local prune_memo = {}
resolve.handle(prune_item, prune_cache, { memo = prune_memo })
assert_true("memo filled", memo_entry_count(prune_memo) > 0)
prune_cache:_store_columns("public.users", {
  { name = "id", type = "integer" },
  { name = "email", type = "text" },
  { name = "memo_prune", type = "text" },
})
local prune_stale = resolve.handle(prune_item, prune_cache, { memo = prune_memo })
assert_eq("memo prune stale", prune_stale.data.dbee_resolve_status, "incomplete")
assert_eq("memo pruned", memo_entry_count(prune_memo), 0)
emit("LSP12_RESOLVE_MEMO_PRUNED_ON_GEN_BUMP", "true")

assert_eq("resolve sync db calls", handler.counters.sync, 0)
assert_eq("resolve async db calls", handler.counters.async, 0)
emit("LSP12_RESOLVE_NO_SYNC_DB", "true")
emit("LSP12_RESOLVE_NO_ASYNC_DB", "true")

vim.cmd("qa!")
