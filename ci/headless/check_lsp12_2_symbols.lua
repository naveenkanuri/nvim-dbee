-- Headless Phase 12.2 checks for LSP document/workspace symbols.

vim.env.XDG_STATE_HOME = vim.fn.tempname()
vim.fn.mkdir(vim.env.XDG_STATE_HOME, "p")

package.preload["nio"] = package.preload["nio"] or function()
  return {}
end

local SchemaCache = require("dbee.lsp.schema_cache")
local context = require("dbee.lsp.context")
local server = require("dbee.lsp.server")
local symbols = require("dbee.lsp.symbols")
local schema_filter = require("dbee.schema_filter")

local function fail(msg)
  print("LSP12_2_FAIL=" .. tostring(msg))
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

local epoch_ref = { value = 1 }
local scope_ref = { value = schema_filter.normalize(nil, "postgres") }

local function make_handler(opts)
  opts = opts or {}
  local handler = {
    counters = {
      sync = 0,
      async = 0,
    },
  }
  function handler:get_authoritative_root_epoch()
    return epoch_ref.value
  end
  if opts.legacy_authority ~= true then
    function handler:get_schema_filter_normalized()
      return scope_ref.value
    end
  end
  function handler:get_current_connection()
    return { id = opts.conn_id or "lsp12-2", type = opts.conn_type or "postgres" }
  end
  function handler:connection_get_columns()
    handler.counters.sync = handler.counters.sync + 1
    return {}
  end
  function handler:connection_get_columns_async()
    handler.counters.async = handler.counters.async + 1
    return {}
  end
  function handler:connection_get_schema_objects_singleflight()
    handler.counters.async = handler.counters.async + 1
    return {}
  end
  return handler
end

local function rows()
  return {
    { schema_name = "public", table_name = "users", obj_type = "table" },
    { schema_name = "public", table_name = "orders", obj_type = "table" },
    { schema_name = "audit", table_name = "users", obj_type = "table" },
    { schema_name = "private", table_name = "secrets", obj_type = "table" },
    { schema_name = "space schema", table_name = "slash/table?#\"%", obj_type = "table" },
  }
end

local function make_cache(opts)
  opts = opts or {}
  epoch_ref.value = opts.epoch or 1
  scope_ref.value = opts.scope
    or schema_filter.normalize(nil, "postgres")
  local handler = make_handler(opts)
  local cache = SchemaCache:new(handler, opts.conn_id or "lsp12-2")
  cache:build_from_metadata_rows(rows(), { root_epoch = opts.root_epoch or epoch_ref.value })
  cache:_store_columns("public.users", {
    { name = "id", type = "integer" },
    { name = "email", type = "text" },
  })
  cache:_store_columns("public.orders", {
    { name = "id", type = "integer" },
    { name = "user_id", type = "integer" },
  })
  return cache, handler
end

local function make_buffer(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, "/tmp/dbee-lsp12-2-" .. tostring(math.random(1000000)) .. ".sql")
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

local function symbol_named(items, name)
  for _, item in ipairs(items or {}) do
    if item.name == name then
      return item
    end
  end
  return nil
end

local function child_named(item, name)
  for _, child in ipairs(item and item.children or {}) do
    if child.name == name then
      return child
    end
  end
  return nil
end

local function child_count(item, name)
  local count = 0
  for _, child in ipairs(item and item.children or {}) do
    if child.name == name then
      count = count + 1
    end
  end
  return count
end

local cache, handler = make_cache()
local client = server.create(cache)({}, {})
local init = request(client, "initialize", {
  capabilities = {
    textDocument = {
      documentSymbol = {
        hierarchicalDocumentSymbolSupport = true,
      },
    },
    workspace = {
      symbol = {
        resolveSupport = { properties = { "location" } },
      },
    },
  },
})
assert_eq("document symbol capability", init.capabilities.documentSymbolProvider, true)
assert_eq("workspace symbol capability", init.capabilities.workspaceSymbolProvider, true)

local line = "select u.id from public.users u join public.orders o on u.id = o.user_id"
local bufnr, uri = make_buffer({ line })
local tree = request(client, "textDocument/documentSymbol", {
  textDocument = { uri = uri },
})
local public = symbol_named(tree, "public")
assert_true("hierarchy public", public and public.kind == 3)
assert_true("hierarchy users", child_named(public, "users") ~= nil)
assert_true("hierarchy orders", child_named(public, "orders") ~= nil)
emit("LSP12_2_DOCSYMBOL_HIERARCHY_OK", "true")

local flat = symbols.handle_document_symbol({
  textDocument = { uri = uri },
}, cache, { force_flat = true })
assert_true("flat users", symbol_named(flat, "users") ~= nil)
emit("LSP12_2_DOCSYMBOL_FLAT_FALLBACK_OK", "true")

local users = child_named(public, "users")
assert_eq("users range line", users.selectionRange.start.line, 0)
assert_true("users range character", users.selectionRange.start.character > 0)
emit("LSP12_2_DOCSYMBOL_RANGES_VALID", "true")

local unknown_buf, unknown_uri = make_buffer({ "select * from mystery" })
local unknown = request(client, "textDocument/documentSymbol", {
  textDocument = { uri = unknown_uri },
})
assert_true("unknown ref", symbol_named(unknown, "mystery") ~= nil)
emit("LSP12_2_DOCSYMBOL_UNKNOWN_REF_OK", "true")

local unqualified_buf, unqualified_uri = make_buffer({ "select * from users" })
local unqualified = request(client, "textDocument/documentSymbol", {
  textDocument = { uri = unqualified_uri },
})
assert_true("unqualified root", symbol_named(unqualified, "users") ~= nil)
emit("LSP12_2_DOCSYMBOL_UNQUALIFIED_FLAT", "true")

local unknown_qualified_buf, unknown_qualified_uri = make_buffer({ "select * from unknown.tablex" })
local unknown_qualified = request(client, "textDocument/documentSymbol", {
  textDocument = { uri = unknown_qualified_uri },
})
assert_eq("unknown schema parent", symbol_named(unknown_qualified, "unknown"), nil)
assert_true("unknown qualified flat", symbol_named(unknown_qualified, "unknown.tablex") ~= nil)
emit("LSP12_2_DOCSYMBOL_UNKNOWN_QUALIFIED_FLAT", "true")

scope_ref.value = nil
local neutral = request(client, "textDocument/documentSymbol", {
  textDocument = { uri = uri },
})
assert_true("authority neutral", #neutral > 0)
assert_eq("authority unavailable no schema parent", symbol_named(neutral, "public"), nil)
assert_true("authority unavailable source table", symbol_named(neutral, "public.users") ~= nil)
scope_ref.value = schema_filter.normalize({ include = { "audit" } }, "postgres")
local filtered_authority_buf, filtered_authority_uri = make_buffer({ "select * from public.users" })
local filtered_authority = request(client, "textDocument/documentSymbol", {
  textDocument = { uri = filtered_authority_uri },
})
assert_eq("filtered authority no schema parent", symbol_named(filtered_authority, "public"), nil)
assert_true("filtered authority source table", symbol_named(filtered_authority, "public.users") ~= nil)
scope_ref.value = schema_filter.normalize(nil, "postgres")
emit("LSP12_2_DOCSYMBOL_AUTHORITY_NEUTRAL", "true")
emit("LSP12_2_DOCSYMBOL_AUTHORITY_DEGRADES_TO_NAME", "true")

local users_node = child_named(symbol_named(tree, "public"), "users")
assert_true("qualified column", child_named(users_node, "id") ~= nil)
local as_alias_buf, as_alias_uri = make_buffer({ "select u.id from public.users AS u" })
local as_alias = request(client, "textDocument/documentSymbol", {
  textDocument = { uri = as_alias_uri },
})
local as_alias_users = child_named(symbol_named(as_alias, "public"), "users")
assert_true("as alias table", as_alias_users ~= nil)
assert_true("as alias column", child_named(as_alias_users, "id") ~= nil)
emit("LSP12_2_DOCSYMBOL_AS_ALIAS_COLUMNS_OK", "true")

local ambiguous_buf, ambiguous_uri = make_buffer({ "select id from public.users u join public.orders o on u.email = o.user_id" })
local ambiguous = request(client, "textDocument/documentSymbol", {
  textDocument = { uri = ambiguous_uri },
})
local ambiguous_users = child_named(symbol_named(ambiguous, "public"), "users")
assert_eq("ambiguous bare column omitted", child_named(ambiguous_users, "id"), nil)
emit("LSP12_2_DOCSYMBOL_COLUMN_SCOPE_SAFE", "true")

local multiline_from_buf, multiline_from_uri = make_buffer({ "select * from", "public.users" })
local multiline_from = request(client, "textDocument/documentSymbol", {
  textDocument = { uri = multiline_from_uri },
})
assert_true("multiline from users", child_named(symbol_named(multiline_from, "public"), "users") ~= nil)
emit("LSP12_2_DOCSYMBOL_MULTILINE_FROM_OK", "true")

local multiline_join_buf, multiline_join_uri = make_buffer({
  "select *",
  "from",
  "  public.users u",
  "join",
  "  public.orders o",
  "on u.id = o.user_id",
})
local multiline_join = request(client, "textDocument/documentSymbol", {
  textDocument = { uri = multiline_join_uri },
})
local multiline_join_public = symbol_named(multiline_join, "public")
assert_true("multiline join users", child_named(multiline_join_public, "users") ~= nil)
assert_true("multiline join orders", child_named(multiline_join_public, "orders") ~= nil)
emit("LSP12_2_DOCSYMBOL_MULTILINE_JOIN_OK", "true")

local multiline_column_buf, multiline_column_uri = make_buffer({
  "select",
  "  id,",
  "  name",
  "from users",
})
local multiline_column = request(client, "textDocument/documentSymbol", {
  textDocument = { uri = multiline_column_uri },
})
local multiline_column_users = symbol_named(multiline_column, "users")
assert_true("multiline column id", child_named(multiline_column_users, "id") ~= nil)
assert_true("multiline column name", child_named(multiline_column_users, "name") ~= nil)
emit("LSP12_2_DOCSYMBOL_MULTILINE_COLUMN_OK", "true")

local identifier_buf, identifier_uri = make_buffer({
  "select 1, id, count(*), 'literal', id as alias from users",
})
local identifier_only = request(client, "textDocument/documentSymbol", {
  textDocument = { uri = identifier_uri },
})
local identifier_users = symbol_named(identifier_only, "users")
assert_true("identifier id retained", child_named(identifier_users, "id") ~= nil)
assert_eq("numeric literal omitted", child_named(identifier_users, "1"), nil)
assert_eq("function omitted", child_named(identifier_users, "count"), nil)
assert_eq("string literal omitted", child_named(identifier_users, "literal"), nil)
assert_eq("alias omitted", child_named(identifier_users, "alias"), nil)
emit("LSP12_2_DOCSYMBOL_SELECT_LIST_IDENTIFIERS_ONLY", "true")

local ignored_text_buf, ignored_text_uri = make_buffer({
  "select * from users -- from public.fake",
  "select 'join public.orders' as s from users",
  "/* from public.orders */ select * from users",
})
local ignored_text = request(client, "textDocument/documentSymbol", {
  textDocument = { uri = ignored_text_uri },
})
assert_true("real users retained", symbol_named(ignored_text, "users") ~= nil)
assert_eq("comment/string schema omitted", symbol_named(ignored_text, "public"), nil)
assert_eq("comment/string fake omitted", symbol_named(ignored_text, "public.fake"), nil)
emit("LSP12_2_DOCSYMBOL_IGNORES_COMMENTS_AND_STRINGS", "true")

local aware_split_buf, aware_split_uri = make_buffer({
  "select '; from public.fake' as s from users",
  "select $$; from public.fake$$ as s from users",
  "select $tag$; from public.fake$tag$ as s from users",
  "select * from users -- ; from public.fake",
  "select * from users /* ; from public.fake */",
})
local aware_split = request(client, "textDocument/documentSymbol", {
  textDocument = { uri = aware_split_uri },
})
assert_true("quote/comment split users retained", symbol_named(aware_split, "users") ~= nil)
assert_eq("quote/comment split schema omitted", symbol_named(aware_split, "public"), nil)
assert_eq("quote/comment split fake omitted", symbol_named(aware_split, "public.fake"), nil)
emit("LSP12_2_DOCSYMBOL_STMT_SPLIT_QUOTE_COMMENT_AWARE", "true")

local diag_ns = server.diagnostic_namespace()
local diagnostic_text_buf, diagnostic_text_uri = make_buffer({
  "select 1 from users -- from public.fake",
  "select '; from public.fake' as s from users",
  "select $$; from public.fake$$ as s from users",
  "select * from users /* join public.fake */",
})
vim.diagnostic.set(diag_ns, diagnostic_text_buf, {})
client.notify("textDocument/didSave", {
  textDocument = { uri = diagnostic_text_uri },
})
local diagnostic_text = vim.diagnostic.get(diagnostic_text_buf, { namespace = diag_ns })
assert_eq("diagnostic comments/strings omitted", #diagnostic_text, 0)
emit("LSP12_2_DIAGNOSTICS_IGNORES_COMMENTS_AND_STRINGS", "true")

local oracle_function_sql = "SELECT USER, SYS_CONTEXT('USERENV', 'SERVICE_NAME') AS SERVICE FROM DUAL"
local oracle_function_refs = context.statement_table_refs({
  text = oracle_function_sql,
  start = { line = 0, character = 0 },
})
assert_eq("oracle function table ref count", #oracle_function_refs, 1)
assert_eq("oracle function table ref", oracle_function_refs[1].ref, "DUAL")

local function_select_refs = context.statement_table_refs({
  text = "SELECT count(*), upper(name) FROM users",
  start = { line = 0, character = 0 },
})
assert_eq("select-list function table ref count", #function_select_refs, 1)
assert_eq("select-list function table ref", function_select_refs[1].ref, "users")

local extract_function_refs = context.statement_table_refs({
  text = "SELECT extract(year from created_at) AS y FROM users",
  start = { line = 0, character = 0 },
})
assert_eq("extract function table ref count", #extract_function_refs, 1)
assert_eq("extract function table ref", extract_function_refs[1].ref, "users")

local prior_scope = scope_ref.value
scope_ref.value = schema_filter.normalize(nil, "oracle")
local oracle_handler = make_handler({ conn_id = "lsp12-2-oracle", conn_type = "oracle" })
local oracle_cache = SchemaCache:new(oracle_handler, "lsp12-2-oracle")
oracle_cache:build_from_metadata_rows({
  { schema_name = "SYS", table_name = "DUAL", obj_type = "table" },
}, { root_epoch = epoch_ref.value })
local oracle_client = server.create(oracle_cache)({}, {})
local oracle_diag_buf, oracle_diag_uri = make_buffer({ oracle_function_sql })
vim.diagnostic.set(diag_ns, oracle_diag_buf, {})
oracle_client.notify("textDocument/didSave", {
  textDocument = { uri = oracle_diag_uri },
})
local oracle_function_diagnostics = vim.diagnostic.get(oracle_diag_buf, { namespace = diag_ns })
assert_eq("oracle function diagnostics omitted", #oracle_function_diagnostics, 0)
oracle_client.terminate()
scope_ref.value = prior_scope
emit("LSP12_2_DIAGNOSTICS_FUNCTION_CALL_NOT_TABLE_REF", "true")

-- CTE alias names must NOT be extracted as table refs (they're statement-local).
local cte_simple = context.statement_table_refs({
  text = "WITH e AS (SELECT 1 AS x FROM DUAL) SELECT * FROM e",
  start = { line = 0, character = 0 },
})
assert_eq("cte alias filtered count", #cte_simple, 1)
assert_eq("cte alias filtered ref", cte_simple[1].ref, "DUAL")

local cte_recursive = context.statement_table_refs({
  text = "WITH RECURSIVE t(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM t WHERE n<5) SELECT * FROM t",
  start = { line = 0, character = 0 },
})
assert_eq("cte recursive alias filtered count", #cte_recursive, 0)

local cte_with_real = context.statement_table_refs({
  text = "WITH e AS (SELECT 1 FROM DUAL) SELECT * FROM e, real_table",
  start = { line = 0, character = 0 },
})
assert_eq("cte with real table count", #cte_with_real, 2)
local cte_real_names = { cte_with_real[1].ref, cte_with_real[2].ref }
table.sort(cte_real_names)
assert_eq("cte real ref 1", cte_real_names[1], "DUAL")
assert_eq("cte real ref 2", cte_real_names[2], "real_table")
emit("LSP12_2_DIAGNOSTICS_CTE_ALIAS_NOT_TABLE_REF", "true")

local dedupe_buf, dedupe_uri = make_buffer({ "select * from public.users; select * from PUBLIC.USERS" })
local dedupe = request(client, "textDocument/documentSymbol", {
  textDocument = { uri = dedupe_uri },
})
local dedupe_public = symbol_named(dedupe, "public")
assert_true("canonical dedupe parent", dedupe_public ~= nil)
assert_eq("canonical dedupe users", child_count(dedupe_public, "users"), 1)
assert_eq("canonical dedupe uppercase parent", symbol_named(dedupe, "PUBLIC"), nil)
emit("LSP12_2_DOCSYMBOL_DEDUPE_CANONICAL", "true")

local cache_key_buf, cache_key_uri = make_buffer({ "select * from public.users" })
symbols._reset_cache()
local known_symbols = symbols.handle_document_symbol({
  textDocument = { uri = cache_key_uri },
}, cache, {
  client_capabilities = {
    textDocument = {
      documentSymbol = {
        hierarchicalDocumentSymbolSupport = true,
      },
    },
  },
})
assert_true("cache identity known schema", child_named(symbol_named(known_symbols, "public"), "users") ~= nil)
local other_handler = make_handler({ conn_id = "lsp12-2-other" })
local other_cache = SchemaCache:new(other_handler, "lsp12-2-other")
other_cache:build_from_metadata_rows({
  { schema_name = "audit", table_name = "users", obj_type = "table" },
}, { root_epoch = epoch_ref.value })
local unknown_symbols = symbols.handle_document_symbol({
  textDocument = { uri = cache_key_uri },
}, other_cache, {
  client_capabilities = {
    textDocument = {
      documentSymbol = {
        hierarchicalDocumentSymbolSupport = true,
      },
    },
  },
})
assert_eq("cache identity no stale schema parent", symbol_named(unknown_symbols, "public"), nil)
assert_true("cache identity reparsed root", symbol_named(unknown_symbols, "public.users") ~= nil)
emit("LSP12_2_DOCSYMBOL_CACHE_KEY_INCLUDES_CACHE_IDENTITY", "true")

local stale_epoch_buf, stale_epoch_uri = make_buffer({ "select * from public.users" })
symbols._reset_cache()
epoch_ref.value = 1
local stale_fresh = symbols.handle_document_symbol({
  textDocument = { uri = stale_epoch_uri },
}, cache, {
  client_capabilities = {
    textDocument = {
      documentSymbol = {
        hierarchicalDocumentSymbolSupport = true,
      },
    },
  },
})
assert_true("stale epoch setup schema parent", child_named(symbol_named(stale_fresh, "public"), "users") ~= nil)
epoch_ref.value = 2
local stale_degraded = symbols.handle_document_symbol({
  textDocument = { uri = stale_epoch_uri },
}, cache, {
  client_capabilities = {
    textDocument = {
      documentSymbol = {
        hierarchicalDocumentSymbolSupport = true,
      },
    },
  },
})
assert_eq("stale epoch no schema parent", symbol_named(stale_degraded, "public"), nil)
assert_true("stale epoch source-only table", symbol_named(stale_degraded, "public.users") ~= nil)
epoch_ref.value = 1
emit("LSP12_2_DOCSYMBOL_EPOCH_STALE_DEGRADES", "true")

local long_line_buf, long_line_uri = make_buffer({
  "select * from users " .. string.rep("x", 1024 * 1024 + 128),
})
local long_line = request(client, "textDocument/documentSymbol", {
  textDocument = { uri = long_line_uri },
})
assert_true("byte cap retained early ref", symbol_named(long_line, "users") ~= nil)
emit("LSP12_2_DOCSYMBOL_BYTE_CAP_STREAMED", "true")

local dense_refs = {}
for i = 1, 2000 do
  dense_refs[#dense_refs + 1] = "public.t" .. tostring(i)
end
local dense_buf, dense_uri = make_buffer({ "select * from " .. table.concat(dense_refs, ", ") })
local dense_start = (vim.uv or vim.loop).hrtime()
local dense = symbols.handle_document_symbol({
  textDocument = { uri = dense_uri },
}, cache, {
  client_capabilities = {
    textDocument = {
      documentSymbol = {
        hierarchicalDocumentSymbolSupport = true,
      },
    },
  },
})
local dense_elapsed_ms = ((vim.uv or vim.loop).hrtime() - dense_start) / 1e6
assert_true("dense refs populated", child_named(symbol_named(dense, "public"), "t2000") ~= nil)
assert_true("dense refs bounded", dense_elapsed_ms < 50)
emit("LSP12_2_DOCSYMBOL_DENSE_REFS_BOUNDED", "true")

local large_lines = {}
for i = 1, 10000 do
  if i == 1 then
    large_lines[i] = "select * from public.users"
  elseif i == 250 then
    large_lines[i] = "select * from public.orders"
  elseif i == 9999 then
    large_lines[i] = "select * from users"
  else
    large_lines[i] = "select 1"
  end
end
local large_buf, large_uri = make_buffer(large_lines)
local start = (vim.uv or vim.loop).hrtime()
local large = request(client, "textDocument/documentSymbol", {
  textDocument = { uri = large_uri },
})
local elapsed_ms = ((vim.uv or vim.loop).hrtime() - start) / 1e6
local large_public = symbol_named(large, "public")
assert_true("large has early symbol", large_public and child_named(large_public, "users") ~= nil)
assert_true("large has post-200 symbol", large_public and child_named(large_public, "orders") ~= nil)
assert_true("large has near-cap symbol", symbol_named(large, "users") ~= nil)
assert_true("large bounded runtime", elapsed_ms < 50)
emit("LSP12_2_DOCSYMBOL_FULL_DOC_BOUNDED", "true")
emit("LSP12_2_DOCSYMBOL_LARGE_BUFFER_BOUNDED", "true")

symbols._reset_cache()
request(client, "textDocument/documentSymbol", {
  textDocument = { uri = uri },
})
assert_eq("cache populated", symbols.cache_size(), 1)
client.notify("textDocument/didChange", { textDocument = { uri = uri } })
assert_eq("cache invalidated", symbols.cache_size(), 0)
emit("LSP12_2_DOCSYMBOL_BUFFER_CACHE_INVALIDATED", "true")

request(client, "textDocument/documentSymbol", {
  textDocument = { uri = uri },
})
client.notify("textDocument/didClose", { textDocument = { uri = uri } })
assert_eq("didclose evicts", symbols.cache_size(), 0)
emit("LSP12_2_DOCSYMBOL_DIDCLOSE_EVICTS", "true")

local invalid_buf, invalid_uri = make_buffer({ "select * from users" })
request(client, "textDocument/documentSymbol", {
  textDocument = { uri = invalid_uri },
})
vim.api.nvim_buf_delete(invalid_buf, { force = true })
assert_eq("invalid evicts", symbols.cache_size(), 0)
emit("LSP12_2_DOCSYMBOL_INVALID_BUFFER_EVICTS", "true")

local disabled_doc_client = server.create(cache, {
  lsp = { document_symbols = false, workspace_symbols = true, hover = true, resolve = true },
})({}, {})
local disabled_init = request(disabled_doc_client, "initialize", { capabilities = {} })
assert_eq("doc disabled cap", disabled_init.capabilities.documentSymbolProvider, nil)
assert_eq("doc disabled direct", request(disabled_doc_client, "textDocument/documentSymbol", {
  textDocument = { uri = uri },
}), nil)
emit("LSP12_2_DOCSYMBOL_DISABLED_NO_CAPABILITY", "true")

scope_ref.value = nil
local authority_closed = request(client, "workspace/symbol", { query = "users" })
assert_eq("authority unavailable empty", #authority_closed, 0)
emit("LSP12_2_WORKSPACESYMBOL_AUTHORITY_FAIL_CLOSED", "true")
scope_ref.value = schema_filter.normalize(nil, "postgres")

local legacy_cache = make_cache({ legacy_authority = true })
local legacy_items = symbols.handle_workspace_symbol({ query = "users" }, legacy_cache, {
  client_capabilities = { workspace = { symbol = { resolveSupport = { properties = {} } } } },
})
assert_true("legacy implicit all", #legacy_items >= 2)
emit("LSP12_2_WORKSPACESYMBOL_AUTHORITY_LEGACY_IMPLICIT_ALL", "true")

scope_ref.value = schema_filter.normalize({ include = { "public" } }, "postgres")
local scoped = request(client, "workspace/symbol", { query = "" })
assert_true("scoped public users", symbol_named(scoped, "users") ~= nil)
assert_eq("scoped private excluded", symbol_named(scoped, "secrets"), nil)
scope_ref.value = schema_filter.normalize(nil, "postgres")
emit("LSP12_2_WORKSPACESYMBOL_AUTHORITY_OK_SCOPED", "true")

epoch_ref.value = 2
local stale_workspace = request(client, "workspace/symbol", { query = "users" })
assert_eq("stale workspace empty", #stale_workspace, 0)
epoch_ref.value = 1
emit("LSP12_2_WORKSPACESYMBOL_EPOCH_FAIL_CLOSED", "true")

local upper_query = request(client, "workspace/symbol", { query = "USERS" })
assert_true("case routed lookup", symbol_named(upper_query, "users") ~= nil)
emit("LSP12_2_WORKSPACESYMBOL_CANONICAL_LOOKUP", "true")

local substring = request(client, "workspace/symbol", { query = "ser" })
assert_true("substring query", symbol_named(substring, "users") ~= nil)
emit("LSP12_2_WORKSPACESYMBOL_QUERY_SUBSTRING", "true")

local capped = symbols.handle_workspace_symbol({ query = "" }, cache, {
  limit = 2,
  client_capabilities = { workspace = { symbol = { resolveSupport = { properties = {} } } } },
})
assert_eq("cap count", #capped, 2)
emit("LSP12_2_WORKSPACESYMBOL_PAGINATION_OK", "true")
assert_true("alloc bounded", symbols._last_workspace_allocations <= 2)
emit("LSP12_2_WORKSPACESYMBOL_CAP_BEFORE_COPY", "true")

for _, item in ipairs(request(client, "workspace/symbol", { query = "orders" })) do
  assert_true("active conn uri", item.location and item.location.uri:find("lsp12%-2", 1, false) ~= nil)
end
emit("LSP12_2_WORKSPACESYMBOL_ACTIVE_CONNECTION_ONLY", "true")

local encoded = request(client, "workspace/symbol", { query = "slash" })
local encoded_item = symbol_named(encoded, "slash/table?#\"%")
assert_true("encoded item", encoded_item ~= nil)
assert_true("encoded uri", encoded_item.location.uri:find("slash%2Ftable%3F%23%22%25", 1, true) ~= nil)
emit("LSP12_2_WORKSPACESYMBOL_DBEE_URI_PERCENT_ENCODED", "true")

local fallback_shape = symbols.handle_workspace_symbol({ query = "orders" }, cache, {
  force_symbol_information = true,
})
assert_true("fallback location range", fallback_shape[1] and fallback_shape[1].location and fallback_shape[1].location.range)
emit("LSP12_2_WORKSPACESYMBOL_LOCATION_FALLBACK_OK", "true")

local disabled_ws_client = server.create(cache, {
  lsp = { document_symbols = true, workspace_symbols = false, hover = true, resolve = true },
})({}, {})
local disabled_ws_init = request(disabled_ws_client, "initialize", { capabilities = {} })
assert_eq("workspace disabled cap", disabled_ws_init.capabilities.workspaceSymbolProvider, nil)
assert_eq("workspace disabled direct", #request(disabled_ws_client, "workspace/symbol", { query = "" }), 0)
emit("LSP12_2_WORKSPACESYMBOL_DISABLED_NO_CAPABILITY", "true")

local preferred = request(client, "workspace/symbol", { query = "orders" })
assert_true("preferred uri only ok", preferred[1] and preferred[1].location and preferred[1].location.uri)
assert_true("fallback shape ok", fallback_shape[1] and fallback_shape[1].location and fallback_shape[1].location.range)
emit("LSP12_2_WORKSPACESYMBOL_SHAPE_FALLBACK_OK", "true")

assert_eq("document sync db calls", handler.counters.sync, 0)
assert_eq("document async db calls", handler.counters.async, 0)
emit("LSP12_2_DOCSYMBOL_NO_SYNC_DB", "true")
emit("LSP12_2_DOCSYMBOL_NO_ASYNC_DB", "true")
assert_eq("workspace sync db calls", handler.counters.sync, 0)
assert_eq("workspace async db calls", handler.counters.async, 0)
emit("LSP12_2_WORKSPACESYMBOL_NO_SYNC_DB", "true")
emit("LSP12_2_WORKSPACESYMBOL_NO_ASYNC_DB", "true")

local function read_file(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    fail("unable to read " .. path)
  end
  return table.concat(lines, "\n")
end

local function assert_no_pattern(label, text, patterns)
  for _, pattern in ipairs(patterns) do
    if text:find(pattern) then
      fail(label .. " matched bypass pattern: " .. pattern)
    end
  end
end

local symbols_source = read_file("lua/dbee/lsp/symbols.lua")
assert_no_pattern("symbols epoch", symbols_source, {
  ":authoritative_root_epoch%(",
  "metadata_root_epoch",
  "get_authoritative_root_epoch",
})
assert_no_pattern("symbols authority", symbols_source, {
  "schema_filter_authority",
  "read_lsp_authority",
  "authority%.status",
  "allowed_schemas",
  "blocked_schemas",
})
assert_no_pattern("symbols fold", symbols_source, {
  "lower%(",
  "upper%(",
  "casefold",
  "canonicalize",
  "canonical_name",
})
assert_no_pattern("symbols db calls", symbols_source, {
  "connection_get_[%w_]*%s*%(",
})
local schema_cache_source = read_file("lua/dbee/lsp/schema_cache.lua")
local helper_start = schema_cache_source:find("function SchemaCache:get_workspace_symbol_snapshot", 1, true)
assert_true("helper body found", helper_start ~= nil)
local helper_end = schema_cache_source:find("\nend\n\n--- Find a schema", helper_start, true)
assert_true("helper body end found", helper_end ~= nil)
local helper_body = schema_cache_source:sub(helper_start, helper_end)
assert_no_pattern("helper epoch", helper_body, {
  ":authoritative_root_epoch%(",
  "metadata_root_epoch",
  "get_authoritative_root_epoch",
})
assert_no_pattern("helper authority", helper_body, {
  "read_lsp_authority",
  "authority%.status",
  "allowed_schemas",
  "blocked_schemas",
})
assert_no_pattern("helper local fold", helper_body, {
  "lower%(",
  "upper%(",
  "casefold",
  "canonicalize",
  "canonical_name",
})
assert_no_pattern("helper db calls", helper_body, {
  "connection_get_[%w_]*%s*%(",
})
emit("LSP12_2_NEW_SYMBOL_CODE_NO_HELPER_BYPASS", "true")

local makefile = read_file("Makefile")
assert_true("make perf wired", makefile:find("check_lsp12_2_symbols.lua", 1, true) ~= nil)
emit("LSP12_2_MAKE_PERF_LSP_WIRED", "true")

vim.env.LSP12_ROLLUP_EXPORT = "1"
local rollup = dofile("ci/headless/check_lsp12_rollup.lua")
vim.env.LSP12_ROLLUP_EXPORT = nil
local synthetic = {}
for _, marker in ipairs(rollup.required_lsp12_2_true_markers or {}) do
  synthetic[#synthetic + 1] = marker .. "=true"
end
synthetic[#synthetic + 1] = "LSP12_2_PERF_SCENARIOS_COUNT=5"
synthetic[#synthetic + 1] = "LSP12_2_MEASURED_COUNT=100"
local valid = rollup.evaluate_lsp12_2(synthetic)
assert_true("rollup valid", valid.ok)
local duplicate = vim.deepcopy(synthetic)
duplicate[#duplicate + 1] = (rollup.required_lsp12_2_true_markers or {})[1] .. "=true"
local duplicate_result = rollup.evaluate_lsp12_2(duplicate)
assert_true("rollup duplicate rejected", not duplicate_result.ok)
emit("LSP12_2_ROLLUP_EXACTLY_ONCE_OK", "true")

emit("LSP12_2_ALL_FUNCTIONAL_SENTINELS_DONE", "true")
vim.cmd("qa!")
