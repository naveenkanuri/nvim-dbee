-- Phase 21 column completion annotation checks.

vim.env.XDG_STATE_HOME = vim.fn.tempname()
vim.fn.mkdir(vim.env.XDG_STATE_HOME, "p")

package.preload["nio"] = package.preload["nio"] or function()
  return {}
end

local SchemaCache = require("dbee.lsp.schema_cache")
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
  local handler = {}
  function handler:get_schema_filter_normalized()
    return scope_ref.value
  end
  function handler:get_authoritative_root_epoch()
    return epoch_ref.value
  end
  function handler:get_current_connection()
    return { id = "lsp21-annotations", type = conn_type or "postgres" }
  end
  return handler
end

local function first_label(items, label)
  for _, item in ipairs(items or {}) do
    if item.label == label then
      return item
    end
  end
  return nil
end

local function detail_text(item)
  return tostring(item and item.detail or "")
end

local function label_detail(item)
  return tostring(item and item.labelDetails and item.labelDetails.detail or "")
end

local function make_cache(conn_id, conn_type, rows)
  scope_ref.value = schema_filter.normalize(nil, conn_type or "postgres")
  epoch_ref.value = 1
  local cache = SchemaCache:new(make_handler(conn_type or "postgres"), conn_id)
  cache:build_from_metadata_rows(rows)
  return cache
end

local rows = {
  { schema_name = "public", table_name = "users", obj_type = "table" },
  { schema_name = "public", table_name = "memberships", obj_type = "table" },
  { schema_name = "public", table_name = "legacy_keys", obj_type = "table" },
  { schema_name = "public", table_name = "orders", obj_type = "table" },
  { schema_name = "public", table_name = "capability_false", obj_type = "table" },
}

local cache = make_cache("lsp21-annotations-pg", "postgres", rows)
local users_columns = {
  { name = "id", type = "integer", nullable = true, primary_key = true },
  { name = "email", type = "text", nullable = true },
  { name = "name", type = "text", nullable = false },
}
local memberships_columns = {
  { name = "org_id", type = "integer", primary_key = true, primary_key_ordinal = 1 },
  { name = "user_id", type = "integer", primary_key = true, primary_key_ordinal = 2 },
}
local legacy_key_columns = {
  { name = "left_id", type = "integer", primary_key = true },
  { name = "right_id", type = "integer", primary_key = true },
}
local orders_columns = {
  {
    name = "user_id",
    type = "integer",
    foreign_keys = {
      {
        constraint_name = "fk_orders_user",
        source_column = "user_id",
        target_schema = "public",
        target_table = "users",
        target_column = "id",
      },
    },
  },
  {
    name = "member_user_id",
    type = "integer",
    foreign_keys = {
      {
        constraint_name = "fk_orders_member",
        source_columns = { "member_org_id", "member_user_id" },
        target_schema = "public",
        target_table = "memberships",
        target_columns = { "org_id", "user_id" },
        source_ordinal = 2,
      },
    },
  },
  {
    name = "owner_id",
    type = "integer",
    foreign_keys = {
      {
        constraint_name = "fk_orders_owner_user",
        source_column = "owner_id",
        target_schema = "public",
        target_table = "users",
        target_column = "id",
      },
      {
        constraint_name = "fk_orders_owner_member",
        source_columns = { "owner_id" },
        target_schema = "public",
        target_table = "memberships",
        target_columns = { "user_id" },
      },
    },
  },
}
local capability_false_columns = {
  { name = "plain", type = "text", primary_key = false },
}

local before_orders = vim.inspect(orders_columns)
cache:_store_columns("public.users", users_columns)
cache:_store_columns("public.memberships", memberships_columns)
cache:_store_columns("public.legacy_keys", legacy_key_columns)
cache:_store_columns("public.orders", orders_columns)
cache:_store_columns("public.capability_false", capability_false_columns)

local users_items = cache:get_column_completion_items("public", "users", {
  schema_quoted = true,
  table_quoted = true,
  include_data = true,
})
local id_item = first_label(users_items, "id")
local email_item = first_label(users_items, "email")
local name_item = first_label(users_items, "name")
assert_eq("label raw", id_item.label, "id")
assert_eq("insertText raw", id_item.insertText, "id")
emit("LSP21_COMPLETION_LABEL_UNCHANGED_OK", "true")
assert_true("labelDetails PK", label_detail(id_item):find("%[PK%]", 1, false) ~= nil)
emit("LSP21_LABELDETAILS_DETAIL_RENDERED_OK", "true")
assert_true("detail PK", detail_text(id_item):find("%[PK%]", 1, false) ~= nil)
emit("LSP21_DETAIL_COMPAT_RENDERED_OK", "true")
emit("LSP21_PK_SINGLE_MARKER_OK", "true")
assert_true("nullable true marker", label_detail(email_item):find("null", 1, true) ~= nil)
emit("LSP21_NULLABLE_TRUE_MARKER_OK", "true")
assert_false("pk null suppressed", label_detail(id_item):find("null", 1, true) ~= nil)
emit("LSP21_PK_NULL_SUPPRESSED_OK", "true")
assert_eq("not null omitted", name_item.labelDetails, nil)
emit("LSP21_NOT_NULL_OMITTED_OK", "true")

local member_items = cache:get_column_completion_items("public", "memberships", {
  schema_quoted = true,
  table_quoted = true,
})
assert_true("pk ordinal 1", label_detail(first_label(member_items, "org_id")):find("%[PK1%]") ~= nil)
assert_true("pk ordinal 2", label_detail(first_label(member_items, "user_id")):find("%[PK2%]") ~= nil)
emit("LSP21_PK_COMPOSITE_ORDINAL_OK", "true")

local legacy_items = cache:get_column_completion_items("public", "legacy_keys", {
  schema_quoted = true,
  table_quoted = true,
})
assert_true("pk fallback left", label_detail(first_label(legacy_items, "left_id")):find("%[PK%]") ~= nil)
assert_false("no fabricated ordinal", label_detail(first_label(legacy_items, "left_id")):find("%[PK1%]") ~= nil)
emit("LSP21_PK_COMPOSITE_NO_ORDINAL_FALLBACK_OK", "true")

local order_items = cache:get_column_completion_items("public", "orders", {
  schema_quoted = true,
  table_quoted = true,
})
local user_fk = first_label(order_items, "user_id")
local composite_fk = first_label(order_items, "member_user_id")
local multi_fk = first_label(order_items, "owner_id")
assert_true("single fk marker", label_detail(user_fk):find("%[FK→users%.id%]") ~= nil)
emit("LSP21_FK_SINGLE_MARKER_OK", "true")
assert_true("composite fk marker", label_detail(composite_fk):find("%[FK→memberships%.%(org_id,user_id%)%]") ~= nil)
emit("LSP21_FK_COMPOSITE_TARGET_TUPLE_OK", "true")
assert_true("multiple fk user", label_detail(multi_fk):find("users%.id") ~= nil)
assert_true("multiple fk member", label_detail(multi_fk):find("memberships%.user_id") ~= nil)
emit("LSP21_FK_MULTIPLE_REFS_OK", "true")
assert_false("malformed nil fk absent", label_detail(multi_fk):find("nil", 1, true) ~= nil)

local cap_item = first_label(cache:get_column_completion_items("public", "capability_false", {
  schema_quoted = true,
  table_quoted = true,
}), "plain")
assert_eq("capability false labelDetails", cap_item.labelDetails, nil)
assert_eq("capability false detail", cap_item.detail, "text")
emit("LSP21_CAPABILITY_FALSE_EMPTY_RICH_FIELDS_OMIT_OK", "true")

cache:_save_columns_to_disk("public.orders", orders_columns)
local payload_path = cache:_columns_cache_path("public.orders")
local payload = vim.json.decode(table.concat(vim.fn.readfile(payload_path), "\n"))
assert_eq("disk version", payload.version, 4)
for _, col in ipairs(payload.columns or {}) do
  assert_eq("disk no labelDetails", col.labelDetails, nil)
  assert_eq("disk no referenced_by", col.referenced_by, nil)
  assert_eq("disk no rendered annotation", col.detail, nil)
  assert_eq("disk no overflow", col.truncated, nil)
end
emit("LSP21_DISK_PAYLOAD_SHAPE_UNCHANGED_OK", "true")
assert_eq("columns unmutated", vim.inspect(orders_columns), before_orders)
emit("LSP21_COLUMN_RECORDS_UNMUTATED_BY_ANNOTATION_OK", "true")

local oracle = make_cache("lsp21-annotations-oracle", "oracle", {
  { schema_name = "HR", table_name = "USERS", obj_type = "table" },
})
oracle:_store_columns("HR.USERS", {
  { name = "ID", type = "NUMBER", primary_key = true },
})
local oracle_id = first_label(oracle:get_column_completion_items("HR", "USERS", {
  schema_quoted = true,
  table_quoted = true,
}), "ID")
assert_true("oracle pk marker", label_detail(oracle_id):find("%[PK%]") ~= nil)
emit("LSP21_HEADLESS_PG_ORACLE_FIXTURES_OK", "true")
emit("LSP21_HEADLESS_CAPABILITY_FALSE_FIXTURE_OK", "true")

vim.cmd("qa!")
