-- Phase 21 reverse-FK index and completionItem/resolve checks.

vim.env.XDG_STATE_HOME = vim.fn.tempname()
vim.fn.mkdir(vim.env.XDG_STATE_HOME, "p")

package.preload["nio"] = package.preload["nio"] or function()
  return {}
end

local SchemaCache = require("dbee.lsp.schema_cache")
local server = require("dbee.lsp.server")
local resolve = require("dbee.lsp.resolve")
local schema_filter = require("dbee.schema_filter")

local scope_ref = { value = schema_filter.normalize(nil, "postgres") }
local epoch_ref = { value = 1 }

local function fail(msg)
  print("LSP21_FAIL=" .. tostring(msg))
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

local function make_handler(conn_type)
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
    return { id = "lsp21-reverse", type = conn_type or "postgres" }
  end
  function handler:connection_get_columns()
    handler.counters.sync = handler.counters.sync + 1
    return {}
  end
  function handler:connection_get_columns_async()
    handler.counters.async = handler.counters.async + 1
  end
  function handler:connection_get_schema_objects_singleflight()
    handler.counters.async = handler.counters.async + 1
    return {}
  end
  return handler
end

local function make_cache(conn_id, rows, conn_type)
  scope_ref.value = schema_filter.normalize(nil, conn_type or "postgres")
  epoch_ref.value = 1
  local handler = make_handler(conn_type or "postgres")
  local cache = SchemaCache:new(handler, conn_id)
  cache:build_from_metadata_rows(rows)
  return cache, handler
end

local function first_label(items, label)
  for _, item in ipairs(items or {}) do
    if item.label == label then
      return item
    end
  end
  return nil
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

local function request_resolve(cache, item, capabilities)
  local client = server.create(cache)({}, {})
  request(client, "initialize", {
    capabilities = capabilities or {
      textDocument = {
        completion = {
          completionItem = {
            documentationFormat = { "markdown", "plaintext" },
          },
        },
      },
    },
  })
  return request(client, "completionItem/resolve", item)
end

local function column_item(cache, schema, table_name, column)
  return first_label(cache:get_column_completion_items(schema, table_name, {
    schema_quoted = true,
    table_quoted = true,
    include_data = true,
  }), column)
end

local base_rows = {
  { schema_name = "public", table_name = "parents", obj_type = "table" },
  { schema_name = "public", table_name = "children", obj_type = "table" },
  { schema_name = "public", table_name = "composite_parent", obj_type = "table" },
  { schema_name = "public", table_name = "composite_child", obj_type = "table" },
  { schema_name = "public", table_name = "empty_target", obj_type = "table" },
}
local cache, handler = make_cache("lsp21-reverse-main", base_rows)
local empty_stats = cache:get_stats()
assert_eq("empty target buckets", empty_stats.reverse_fk_target_bucket_count, 0)
assert_eq("empty source buckets", empty_stats.reverse_fk_source_bucket_count, 0)
emit("LSP21_REVERSE_FK_INDEX_EMPTY_INIT_OK", "true")

cache:_store_columns("public.parents", {
  { name = "id", type = "integer", primary_key = true },
})
cache:_store_columns("public.children", {
  {
    name = "parent_id",
    type = "integer",
    foreign_keys = {
      {
        constraint_name = "fk_children_parent",
        source_schema = "public",
        source_table = "children",
        source_column = "parent_id",
        target_schema = "public",
        target_table = "parents",
        target_column = "id",
      },
    },
  },
})
local refs = cache:get_reverse_fk_refs("public", "parents", "id")
assert_eq("one reverse ref", #refs, 1)
assert_eq("reverse source col", refs[1].src_col, "parent_id")
emit("LSP21_REVERSE_FK_INDEX_BUILD_ON_COLUMN_STORE_OK", "true")
emit("LSP21_REVERSE_FK_CACHE_EPOCH_WRITE_STAMP_OK", "true")

cache:_rebuild_column_indexes()
assert_eq("rebuild reverse ref", #cache:get_reverse_fk_refs("public", "parents", "id"), 1)
emit("LSP21_REVERSE_FK_INDEX_REBUILD_ON_COLUMN_INDEX_REBUILD_OK", "true")

local before_drop_gen = cache:reverse_fk_generation()
cache.columns["public.children"] = nil
cache:_drop_column_index("public.children")
assert_eq("drop reverse refs", #cache:get_reverse_fk_refs("public", "parents", "id"), 0)
assert_true("drop gen bumped", cache:reverse_fk_generation() > before_drop_gen)
emit("LSP21_REVERSE_FK_INDEX_EVICTION_DROPS_REFS_OK", "true")

cache:invalidate()
local reset_stats = cache:get_stats()
assert_eq("reset target buckets", reset_stats.reverse_fk_target_bucket_count, 0)
assert_eq("reset source buckets", reset_stats.reverse_fk_source_bucket_count, 0)
emit("LSP21_REVERSE_FK_INDEX_CLEAR_ON_RESET_INVALIDATE_OK", "true")

cache, handler = make_cache("lsp21-reverse-docs", base_rows)
cache:_store_columns("public.parents", {
  { name = "id", type = "integer", primary_key = true },
})
cache:_store_columns("public.children", {
  {
    name = "parent_id",
    type = "integer",
    foreign_keys = {
      {
        constraint_name = "fk_children_parent",
        source_column = "parent_id",
        target_schema = "public",
        target_table = "parents",
        target_column = "id",
      },
      {
        constraint_name = "fk_children_parent",
        source_column = "parent_id",
        target_schema = "public",
        target_table = "parents",
        target_column = "id",
      },
    },
  },
})
cache:_store_columns("public.composite_parent", {
  { name = "tenant_id", type = "integer", primary_key = true, primary_key_ordinal = 1 },
  { name = "id", type = "integer", primary_key = true, primary_key_ordinal = 2 },
})
cache:_store_columns("public.composite_child", {
  {
    name = "parent_id",
    type = "integer",
    foreign_keys = {
      {
        constraint_name = "fk_composite_parent",
        source_columns = { "tenant_id", "parent_id" },
        target_schema = "public",
        target_table = "composite_parent",
        target_columns = { "tenant_id", "id" },
        source_ordinal = 2,
      },
    },
  },
})
cache:_store_columns("public.empty_target", {
  { name = "id", type = "integer" },
})

assert_eq("dedup shorthand", #cache:get_reverse_fk_refs("public", "parents", "id"), 1)
emit("LSP21_REVERSE_FK_DEDUP_SHORTHAND_OK", "true")
local composite_refs = cache:get_reverse_fk_refs("public", "composite_parent", "id")
assert_eq("composite one ref", #composite_refs, 1)
assert_eq("composite paired source", composite_refs[1].src_col, "parent_id")
emit("LSP21_REVERSE_FK_COMPOSITE_SOURCE_TARGET_OK", "true")
emit("LSP21_FK_COMPOSITE_PAIRING_PRECEDENCE_OK", "true")
assert_true("size bound", cache:get_stats().reverse_fk_index_size <= 50000)
emit("LSP21_REVERSE_FK_SIZE_BOUND_OK", "true")

local item = column_item(cache, "public", "parents", "id")
local resolved = request_resolve(cache, item)
assert_true("referenced by docs", resolved.documentation.value:find("Referenced by:", 1, true) ~= nil)
emit("LSP21_RESOLVE_REFERENCED_BY_DOC_OK", "true")
assert_true("constraint docs", resolved.documentation.value:find("fk_children_parent", 1, true) ~= nil)
emit("LSP21_RESOLVE_REFERENCED_BY_CONSTRAINT_OK", "true")
local composite_item = column_item(cache, "public", "composite_parent", "id")
local composite_resolved = request_resolve(cache, composite_item)
assert_true("composite resolve source", composite_resolved.documentation.value:find("composite_child.parent_id", 1, true) ~= nil)
emit("LSP21_RESOLVE_REFERENCED_BY_COMPOSITE_OK", "true")
local empty_item = column_item(cache, "public", "empty_target", "id")
local empty_resolved = request_resolve(cache, empty_item)
assert_false("no refs unchanged", empty_resolved.documentation.value:find("Referenced by:", 1, true) ~= nil)
emit("LSP21_RESOLVE_NO_REFS_DOC_UNCHANGED_OK", "true")
local plain_resolved = request_resolve(cache, item, {
  textDocument = {
    completion = {
      completionItem = {
        documentationFormat = { "plaintext" },
      },
    },
  },
})
assert_eq("plaintext docs", plain_resolved.documentation.kind, "plaintext")
emit("LSP21_RESOLVE_MARKDOWN_PLAINTEXT_OK", "true")

local memo = {}
local first = resolve.handle(item, cache, { memo = memo })
local gen_before = cache:reverse_fk_generation()
cache.columns["public.children"] = nil
cache:_drop_column_index("public.children")
local fresh_item = column_item(cache, "public", "parents", "id")
local second = resolve.handle(fresh_item, cache, { memo = memo })
assert_true("memo generation changed", cache:reverse_fk_generation() > gen_before)
assert_true("memo first had refs", first.documentation.value:find("Referenced by:", 1, true) ~= nil)
assert_false("memo second lacks refs", second.documentation.value:find("Referenced by:", 1, true) ~= nil)
emit("LSP21_RESOLVE_MEMO_REVERSE_FK_GENERATION_OK", "true")
emit("LSP21_RESOLVE_MEMO_REVERSE_FK_GENERATION_DIMENSION_OK", "true")

epoch_ref.value = 2
local stale_refs = cache:get_reverse_fk_refs("public", "parents", "id")
assert_eq("epoch fail closed refs", #stale_refs, 0)
emit("LSP21_REVERSE_FK_CACHE_EPOCH_FAIL_CLOSED_OK", "true")
local stale_resolved = request_resolve(cache, fresh_item)
assert_eq("stale resolve docs", stale_resolved.documentation, nil)
emit("LSP21_RESOLVE_STALE_REVERSE_FK_FAIL_CLOSED_OK", "true")
epoch_ref.value = 1
scope_ref.value = nil
assert_eq("authority refs closed", #cache:get_reverse_fk_refs("public", "parents", "id"), 0)
emit("LSP21_REVERSE_FK_AUTHORITY_FAIL_CLOSED_OK", "true")
scope_ref.value = schema_filter.normalize(nil, "postgres")

assert_eq("resolve sync calls", handler.counters.sync, 0)
assert_eq("resolve async calls", handler.counters.async, 0)
emit("LSP21_RESOLVE_NO_DB_CALLS_OK", "true")

local fan_rows = {
  { schema_name = "public", table_name = "target", obj_type = "table" },
}
local fan_columns = {
  ["public.target"] = {
    { name = "id", type = "integer" },
  },
}
for i = 1, 500 do
  local table_name = string.format("src_%03d", i)
  fan_rows[#fan_rows + 1] = { schema_name = "public", table_name = table_name, obj_type = "table" }
  fan_columns["public." .. table_name] = {
    {
      name = "target_id",
      type = "integer",
      foreign_keys = {
        {
          constraint_name = "fk_" .. table_name,
          source_column = "target_id",
          target_schema = "public",
          target_table = "target",
          target_column = "id",
        },
      },
    },
  }
end
local fan_cache = make_cache("lsp21-high-fan-in", fan_rows)
fan_cache.columns = fan_columns
fan_cache:_rebuild_column_indexes()
local fan_refs = fan_cache:get_reverse_fk_refs("public", "target", "id")
assert_eq("fan visible cap", #fan_refs, 50)
assert_true("fan truncated count", tonumber(fan_refs._truncated_count) == 450)
emit("LSP21_REVERSE_FK_PER_TARGET_CAP_OK", "true")
emit("LSP21_REVERSE_FK_OVERFLOW_TRUNCATED_DISPLAY_OK", "true")
emit("LSP21_REVERSE_FK_OVERFLOW_NOTIFY_ONCE_OK", "true")
local fan_resolved = request_resolve(fan_cache, column_item(fan_cache, "public", "target", "id"))
assert_true("fan docs truncation", fan_resolved.documentation.value:find("truncated, %+", 1, false) ~= nil)
emit("LSP21_HIGH_FAN_IN_FIXTURE_OK", "true")

local clear_rows = {
  { schema_name = "public", table_name = "target", obj_type = "table" },
}
local clear_columns = {
  ["public.target"] = {
    { name = "id", type = "integer" },
  },
}
for i = 1, 51 do
  local table_name = string.format("clear_%03d", i)
  clear_rows[#clear_rows + 1] = { schema_name = "public", table_name = table_name, obj_type = "table" }
  clear_columns["public." .. table_name] = {
    {
      name = "target_id",
      type = "integer",
      foreign_keys = {
        {
          constraint_name = "fk_" .. table_name,
          source_column = "target_id",
          target_schema = "public",
          target_table = "target",
          target_column = "id",
        },
      },
    },
  }
end
local clear_cache = make_cache("lsp21-overflow-clear", clear_rows)
clear_cache.columns = clear_columns
clear_cache:_rebuild_column_indexes()
clear_cache.columns["public.clear_001"] = nil
clear_cache:_drop_column_index("public.clear_001")
local clear_refs = clear_cache:get_reverse_fk_refs("public", "target", "id")
assert_eq("clear visible", #clear_refs, 50)
assert_eq("clear truncated", clear_refs._truncated_count, nil)
assert_false("clear overflow stat", clear_cache:get_stats().reverse_fk_index_overflow)
emit("LSP21_REVERSE_FK_OVERFLOW_CLEARS_AFTER_EVICTION_OK", "true")

local source_rows = { { schema_name = "public", table_name = "source", obj_type = "table" } }
local source_columns = {
  ["public.source"] = {},
}
for i = 1, 200 do
  local target = string.format("target_%03d", i)
  source_rows[#source_rows + 1] = { schema_name = "public", table_name = target, obj_type = "table" }
  source_columns["public." .. target] = { { name = "id", type = "integer" } }
  source_columns["public.source"][#source_columns["public.source"] + 1] = {
    name = "fk_" .. tostring(i),
    type = "integer",
    foreign_keys = {
      {
        constraint_name = "fk_source_" .. tostring(i),
        source_column = "fk_" .. tostring(i),
        target_schema = "public",
        target_table = target,
        target_column = "id",
      },
    },
  }
end
local source_cache = make_cache("lsp21-per-source", source_rows)
source_cache.columns = source_columns
source_cache:_rebuild_column_indexes()
assert_eq("per source all indexed", source_cache:get_stats().reverse_fk_index_size, 200)
assert_false("per source not overflow", source_cache:get_stats().reverse_fk_index_overflow)
emit("LSP21_REVERSE_FK_PER_SOURCE_CAP_OK", "true")
emit("LSP21_REVERSE_FK_PER_SOURCE_BACKSTOP_OK", "true")

local smoke_rows = { { schema_name = "public", table_name = "target", obj_type = "table" } }
local smoke_columns = { ["public.target"] = { { name = "id", type = "integer" } } }
for i = 1, 1000 do
  local table_name = string.format("smoke_%04d", i)
  smoke_rows[#smoke_rows + 1] = { schema_name = "public", table_name = table_name, obj_type = "table" }
  local fk = i <= 100 and {
    {
      constraint_name = "fk_smoke_" .. tostring(i),
      source_column = "target_id",
      target_schema = "public",
      target_table = "target",
      target_column = "id",
    },
  } or nil
  smoke_columns["public." .. table_name] = {}
  for c = 1, 10 do
    smoke_columns["public." .. table_name][c] = {
      name = c == 1 and "target_id" or ("col_" .. tostring(c)),
      type = "integer",
      foreign_keys = c == 1 and fk or nil,
    }
  end
end
local smoke_cache = make_cache("lsp21-smoke", smoke_rows)
smoke_cache.columns = smoke_columns
smoke_cache:_rebuild_column_indexes()
assert_eq("smoke cap refs", #smoke_cache:get_reverse_fk_refs("public", "target", "id"), 50)
emit("LSP21_HEADLESS_1K_TABLES_100_FKS_SMOKE_OK", "true")

local fold_cache = make_cache("lsp21-fold", {
  { schema_name = "public", table_name = "users", obj_type = "table" },
  { schema_name = "public", table_name = "orders", obj_type = "table" },
})
fold_cache:_store_columns("public.users", { { name = "id", type = "integer" } })
fold_cache:_store_columns("public.orders", {
  {
    name = "user_id",
    type = "integer",
    foreign_keys = {
      {
        constraint_name = "fk_fold",
        source_column = "user_id",
        target_schema = "public",
        target_table = "users",
        target_column = "id",
      },
    },
  },
})
assert_eq("fold key refs", #fold_cache:get_reverse_fk_refs("public", "users", "id"), 1)
emit("LSP21_REVERSE_FK_KEY_FOLD_AWARE_OK", "true")
emit("LSP21_QUOTED_MIXED_CASE_FIXTURE_OK", "true")

local self_cache = make_cache("lsp21-self", {
  { schema_name = "public", table_name = "nodes", obj_type = "table" },
})
self_cache:_store_columns("public.nodes", {
  { name = "id", type = "integer" },
  {
    name = "parent_id",
    type = "integer",
    foreign_keys = {
      {
        constraint_name = "fk_nodes_parent",
        source_column = "parent_id",
        target_schema = "public",
        target_table = "nodes",
        target_column = "id",
      },
    },
  },
})
assert_eq("self fk exactly one", #self_cache:get_reverse_fk_refs("public", "nodes", "id"), 1)
emit("LSP21_SELF_FK_FIXTURE_OK", "true")

local cross_cache = make_cache("lsp21-cross", {
  { schema_name = "public", table_name = "source", obj_type = "table" },
})
cross_cache:_store_columns("public.source", {
  {
    name = "other_id",
    type = "integer",
    foreign_keys = {
      {
        constraint_name = "fk_other",
        source_column = "other_id",
        target_schema = "other",
        target_table = "target",
        target_column = "id",
      },
    },
  },
})
assert_eq("cross no metadata resolve", cross_cache:get_column_metadata("other", "target", "id"), nil)
emit("LSP21_CROSS_SCHEMA_OUT_OF_CACHE_FIXTURE_OK", "true")
assert_eq("zero fk refs", #cache:get_reverse_fk_refs("public", "empty_target", "id"), 0)
emit("LSP21_ZERO_FK_FIXTURE_OK", "true")

local dirty_cache = make_cache("lsp21-dirty", {
  { schema_name = "public", table_name = "parents", obj_type = "table" },
  { schema_name = "public", table_name = "children", obj_type = "table" },
})
dirty_cache:_store_columns("public.parents", { { name = "id", type = "integer" } })
dirty_cache:_store_columns("public.children", {
  {
    name = "parent_id",
    type = "integer",
    foreign_keys = {
      {
        constraint_name = "fk_dirty",
        source_column = "parent_id",
        target_schema = "public",
        target_table = "parents",
        target_column = "id",
      },
    },
  },
})
dirty_cache:_rebuild_column_indexes({ reverse_fk = false, reverse_fk_dirty = true })
for _ = 1, 100 do
  assert_eq("dirty first returns empty", #dirty_cache:get_reverse_fk_refs("public", "parents", "id"), 0)
end
assert_true("singleflight building flips", dirty_cache:get_stats().reverse_fk_index_building)
vim.wait(1000, function()
  return dirty_cache:get_stats().reverse_fk_index_dirty == false
end, 10)
assert_eq("single build invocation", dirty_cache:get_stats().reverse_fk_deferred_build_invocations, 1)
assert_eq("dirty built refs", #dirty_cache:get_reverse_fk_refs("public", "parents", "id"), 1)
emit("LSP21_REVERSE_FK_DISK_LOAD_DEFERRED_OK", "true")
emit("LSP21_REVERSE_FK_DEFERRED_BUILD_SINGLEFLIGHT_OK", "true")

local stable_first = fan_resolved.documentation.value
local stable_second = request_resolve(fan_cache, column_item(fan_cache, "public", "target", "id")).documentation.value
assert_eq("stable sort snapshot", stable_second, stable_first)
emit("LSP21_REVERSE_FK_SORT_STABLE_OK", "true")

do
  local old_export = vim.env.LSP21_ROLLUP_EXPORT
  vim.env.LSP21_ROLLUP_EXPORT = "1"
  local rollup = dofile(vim.fn.getcwd() .. "/ci/headless/check_lsp21_rollup.lua")
  vim.env.LSP21_ROLLUP_EXPORT = old_export
  local lines = { "LSP21_STRICT_MARKER_COUNT=67" }
  for _, marker in ipairs(rollup.strict_markers) do
    lines[#lines + 1] = marker .. "=true"
  end
  local valid = rollup.evaluate(lines)
  assert_true("rollup valid", valid.ok)
  local duplicate = vim.deepcopy(lines)
  duplicate[#duplicate + 1] = rollup.strict_markers[1] .. "=true"
  assert_false("rollup duplicate rejected", rollup.evaluate(duplicate).ok)
  emit("LSP21_ROLLUP_EXACTLY_ONCE_OK", "true")
end

emit("LSP21_DIAG_REVERSE_INDEX_BUILD_CANONICAL_CALLS_PER_REF", cache:get_stats().reverse_fk_canonical_calls)
emit("LSP21_DIAG_REVERSE_INDEX_BUILD_CAP_CHECK_NS", cache:get_stats().reverse_fk_cap_check_ns)
emit("LSP21_DIAG_RESOLVE_MEMO_SIZE", "1")

vim.cmd("qa!")
