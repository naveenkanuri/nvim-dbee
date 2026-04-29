-- Headless validation for Phase 14 schema_filter normalization and runtime
-- source/handler preservation.
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=$(pwd)" \
--   -c "luafile ci/headless/check_schema_filter.lua"

local function fail(msg)
  print("ARCH14_SCHEMA_FILTER_FAIL=" .. msg)
  vim.cmd("cquit 1")
end

local function assert_true(label, value)
  if not value then
    fail(label .. ": expected truthy, got " .. vim.inspect(value))
  end
end

local function assert_eq(label, actual, expected)
  if actual ~= expected then
    fail(label .. ": expected " .. vim.inspect(expected) .. " got " .. vim.inspect(actual))
  end
end

local schema_filter = require("dbee.schema_filter")

local function run_normalization_contract()
  local opts, err = schema_filter.to_structure_options({
    include = { " fin% ", "HR", "FIN%" },
    exclude = { " fin_temp% " },
    lazy_per_schema = true,
  }, "postgres")
  assert_true("normalized options", opts ~= nil and err == nil)
  assert_eq("include sorted deduped", table.concat(opts.schema_filter.include, ","), "fin%,hr")
  assert_eq("exclude folded", table.concat(opts.schema_filter.exclude, ","), "fin_temp%")
  assert_eq(
    "signature",
    opts.schema_filter_signature,
    "schema-filter-v1|type=postgres|fold=lower|lazy=1|include=4:fin%,2:hr|exclude=9:fin_temp%"
  )

  local normalized = assert(schema_filter.normalize(opts.schema_filter, "postgres"))
  assert_true("include match", schema_filter.matches("FINANCE", normalized))
  assert_true("literal match", schema_filter.matches("hr", normalized))
  assert_true("exclude match", not schema_filter.matches("FIN_TEMP_1", normalized))
  print("ARCH14_SCHEMA_FILTER_MATCHING_OK=true")
  print("ARCH14_SCHEMA_FILTER_SIGNATURE_STABLE=true")
end

local function run_invalid_pattern_contract()
  local opts, err = schema_filter.to_structure_options({ include = { "HR.PROD" } }, "oracle")
  assert_true("dot literal is accepted", opts ~= nil and err == nil)

  opts, err = schema_filter.to_structure_options({ include = { "HR[0-9]" } }, "oracle")
  assert_true("regex pattern rejected", opts == nil and tostring(err):find("SQL glob", 1, true) ~= nil)

  opts, err = schema_filter.to_structure_options({ include = {} }, "oracle")
  assert_true("empty include rejected", opts == nil and tostring(err):find("include", 1, true) ~= nil)
  print("ARCH14_SCHEMA_FILTER_INVALID_PATTERN_REJECTED=true")
end

local function run_sources_preserve_filter_contract()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  local path = vim.fs.joinpath(dir, "connections.json")
  local records = {
    {
      id = "conn-schema-filter",
      name = "Filtered",
      type = "postgres",
      url = "postgres://example",
      schema_filter = {
        include = { "app%" },
        exclude = { "app_tmp%" },
        lazy_per_schema = true,
      },
    },
  }
  local file = assert(io.open(path, "w"))
  file:write(vim.fn.json_encode(records))
  file:close()

  local source = require("dbee.sources").FileSource:new(path)
  local loaded = source:load()
  vim.fn.delete(dir, "rf")

  assert_eq("loaded count", #loaded, 1)
  assert_eq("schema_filter include", loaded[1].schema_filter.include[1], "app%")
  assert_eq("schema_filter exclude", loaded[1].schema_filter.exclude[1], "app_tmp%")
  assert_true("schema_filter lazy", loaded[1].schema_filter.lazy_per_schema == true)
  print("ARCH14_SCHEMA_FILTER_PERSISTED=true")
end

local function run_handler_authority_contract()
  local Handler = require("dbee.handler")
  local handler = Handler:new({})
  vim.fn.DbeeConnectionGetParams = function(conn_id)
    assert_eq("conn id", conn_id, "conn-runtime")
    return {
      id = "conn-runtime",
      name = "Runtime",
      type = "oracle",
      url = "oracle://example",
      schema_filter = {
        include = { "hr", "FIN%" },
        exclude = { "HR_TEMP%" },
        lazy_per_schema = false,
      },
    }
  end

  local opts = handler:get_schema_filter("conn-runtime")
  assert_eq("fold", opts.fold, "upper")
  assert_eq("include folded", table.concat(opts.schema_filter.include, ","), "FIN%,HR")
  assert_true("lazy default false", opts.schema_filter.lazy_per_schema == false)
  print("ARCH14_SCHEMA_FILTER_RPC_ROUNDTRIP_OK=true")
  print("ARCH14_LAZY_PER_SCHEMA_FLAG_GATED=true")
end

run_normalization_contract()
run_invalid_pattern_contract()
run_sources_preserve_filter_contract()
run_handler_authority_contract()

print("ARCH14_SCHEMA_FILTER_ALL_PASS=true")
vim.cmd("qa")
