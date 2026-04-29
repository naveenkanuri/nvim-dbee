-- Headless validation for Phase 8 FileSource hardening, metadata fidelity,
-- and round-trip persistence guarantees.
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp+=$(pwd)" \
--   -c "luafile ci/headless/check_filesource_persistence.lua"

local function fail(msg)
  print("DCFG02_FILESOURCE_FAIL=" .. msg)
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

local function assert_match(label, actual, pattern)
  if type(actual) ~= "string" or actual:find(pattern, 1, true) == nil then
    fail(label .. ": expected " .. vim.inspect(actual) .. " to contain " .. vim.inspect(pattern))
  end
end

local function find_record(records, wanted_id)
  for _, record in ipairs(records or {}) do
    if record.id == wanted_id then
      return record
    end
  end
  return nil
end

local function write_json(path, records)
  local ok, encoded = pcall(vim.fn.json_encode, records)
  if not ok then
    fail("json encode failed for " .. tostring(path))
  end
  local fd = assert(io.open(path, "w"))
  fd:write(encoded)
  fd:close()
end

local function read_json(path)
  local fd = assert(io.open(path, "r"))
  local content = fd:read("*a")
  fd:close()
  if content == "" then
    return {}
  end
  local ok, decoded = pcall(vim.fn.json_decode, content)
  if not ok then
    fail("json decode failed for " .. tostring(path))
  end
  return decoded or {}
end

local function make_temp_dir()
  local dir = vim.fn.tempname()
  vim.fn.mkdir(dir, "p")
  return dir
end

local function cleanup_path(path)
  if path and path ~= "" then
    pcall(vim.fn.delete, path, "rf")
  end
end

local function with_source(records, fn)
  local dir = make_temp_dir()
  local path = vim.fs.joinpath(dir, "connections.json")
  write_json(path, vim.deepcopy(records or {}))

  local ok, result = pcall(function()
    local source = require("dbee.sources").FileSource:new(path)
    return fn(source, path, dir)
  end)

  cleanup_path(dir)

  if not ok then
    fail(result)
  end
end

local function run_atomic_write_contract()
  with_source({
    {
      id = "conn-atomic",
      name = "Atomic",
      type = "postgres",
      url = "postgres://atomic",
    },
  }, function(source, path)
    local original_records = read_json(path)
    local original_rename = vim.loop.fs_rename
    vim.loop.fs_rename = function()
      return nil, "rename exploded"
    end

    local ok, err = pcall(source.update, source, "conn-atomic", {
      name = "Atomic Updated",
      type = "postgres",
      url = "postgres://atomic-updated",
    })

    vim.loop.fs_rename = original_rename

    assert_true("atomic update failed", not ok)
    assert_match("atomic update error", tostring(err), "could not rename temp file")
    assert_eq("atomic file unchanged", vim.inspect(read_json(path)), vim.inspect(original_records))
    assert_eq("atomic temp cleanup", vim.fn.glob(path .. ".*.tmp"), "")
  end)

  with_source({
    {
      id = "conn-atomic",
      name = "Atomic",
      type = "postgres",
      url = "postgres://atomic",
    },
  }, function(source, path)
    local original_records = read_json(path)
    local original_open = io.open

    local function assert_io_failure(method_name, expected_pattern)
      io.open = function(target, mode)
        local real_file, err = original_open(target, mode)
        if not real_file then
          return real_file, err
        end

        if mode == "w" and target ~= path and target:find(path .. ".", 1, true) == 1 then
          return {
            write = function(_, data)
              if method_name == "write" then
                return nil, "write exploded"
              end
              return real_file:write(data)
            end,
            flush = function()
              if method_name == "flush" then
                return nil, "flush exploded"
              end
              return real_file:flush()
            end,
            close = function()
              if method_name == "close" then
                return nil, "close exploded"
              end
              return real_file:close()
            end,
          }
        end

        return real_file, err
      end

      local ok, update_err = pcall(source.update, source, "conn-atomic", {
        name = "Atomic Updated",
        type = "postgres",
        url = "postgres://atomic-updated",
      })

      io.open = original_open

      assert_true(method_name .. " failure propagated", not ok)
      assert_match(method_name .. " failure message", tostring(update_err), expected_pattern)
      assert_eq(method_name .. " keeps original file", vim.inspect(read_json(path)), vim.inspect(original_records))
      assert_eq(method_name .. " temp cleanup", vim.fn.glob(path .. ".*.tmp"), "")
    end

    assert_io_failure("write", "could not write temp file")
    assert_io_failure("flush", "could not flush temp file")
    assert_io_failure("close", "could not close temp file")
  end)

  print("DCFG02_ATOMIC_WRITE_OK=true")
end

local function run_unknown_field_contracts()
  with_source({
    {
      id = "conn-preserve",
      name = "Keep Me",
      type = "postgres",
      url = "postgres://keep:old@db.local:5432/app?sslmode=require",
      tags = { "alpha", "beta" },
      color = "blue",
      wizard = {
        db_kind = "postgres",
        mode = "postgres_form",
        rendered_url = "postgres://keep:old@db.local:5432/app?sslmode=require",
        custom_top_level = "top_preserve",
        fields = {
          name = "Keep Me",
          host = "db.local",
          port = "5432",
          database = "app",
          username = "keep",
          password = "old",
          sslmode = "require",
          custom_unknown_key = "preserve_me",
          nested = {
            untouched = "still-here",
          },
        },
      },
    },
    {
      id = "conn-sibling",
      name = "Sibling",
      type = "mysql",
      url = "mysql://sibling",
      extra = {
        keep = true,
      },
    },
  }, function(source, path)
    source:update("conn-preserve", {
      name = "Keep Me Updated",
      type = "postgres",
      url = "postgres://keep:new@db.local:5432/app?sslmode=require",
      wizard = {
        fields = {
          password = "new",
        },
      },
    })

    local persisted = read_json(path)
    local updated = find_record(persisted, "conn-preserve")
    local sibling = find_record(persisted, "conn-sibling")

    assert_true("updated record exists", updated ~= nil)
    assert_true("sibling record exists", sibling ~= nil)
    assert_eq("unknown top-level color preserved", updated.color, "blue")
    assert_eq("unknown top-level tags preserved", vim.inspect(updated.tags), vim.inspect({ "alpha", "beta" }))
    assert_eq("wizard mode preserved", updated.wizard.mode, "postgres_form")
    assert_eq("wizard custom top-level preserved", updated.wizard.custom_top_level, "top_preserve")
    assert_eq("wizard nested custom preserved", updated.wizard.fields.custom_unknown_key, "preserve_me")
    assert_eq("wizard nested table preserved", updated.wizard.fields.nested.untouched, "still-here")
    assert_eq("wizard leaf updated", updated.wizard.fields.password, "new")
    assert_eq("sibling extra preserved", sibling.extra.keep, true)
  end)

  print("DCFG02_UNKNOWN_FIELD_PRESERVE_OK=true")
  print("DCFG02_WIZARD_NESTED_PRESERVE_OK=true")
end

local function run_roundtrip_contracts()
  with_source({}, function(source, path)
    local pg_url = "postgres://url_user:${PG_PASSWORD}@url-host:5432/url_db?sslmode=require"
    local pg_url_id = source:create({
      name = "PG URL",
      type = "postgres",
      url = pg_url,
      wizard = {
        db_kind = "postgres",
        mode = "postgres_url",
        fields = {
          name = "PG URL",
          url = pg_url,
        },
      },
    })

    local pg_form_id = source:create({
      name = "PG Form",
      type = "postgres",
      url = "postgres://form_user:literal-pass@form-host:5432/form_db?sslmode=require",
      wizard = {
        db_kind = "postgres",
        mode = "postgres_form",
        rendered_url = "postgres://form_user:literal-pass@form-host:5432/form_db?sslmode=require",
        fields = {
          name = "PG Form",
          host = "form-host",
          port = "5432",
          database = "form_db",
          username = "form_user",
          password = "literal-pass",
          sslmode = "require",
        },
      },
    })

    local oracle_descriptor = table.concat({
      "(DESCRIPTION=",
      "  (ADDRESS=(PROTOCOL=tcp)(HOST=oracle-host)(PORT=1521))",
      "  (CONNECT_DATA=(SERVICE_NAME=XE))",
      ")",
    }, "\n")
    local oracle_id = source:create({
      name = "Oracle JDBC",
      type = "oracle",
      url = "oracle://scott:tiger@:0/?connStr=(DESCRIPTION=(ADDRESS=(PROTOCOL=tcp)(HOST=oracle-host)(PORT=1521))(CONNECT_DATA=(SERVICE_NAME=XE)))",
      wizard = {
        db_kind = "oracle",
        mode = "oracle_custom_jdbc",
        fields = {
          name = "Oracle JDBC",
          username = "scott",
          password = "tiger",
          descriptor = oracle_descriptor,
        },
      },
    })

    local pg_url_record = source:get_record(pg_url_id)
    local pg_form_record = source:get_record(pg_form_id)
    local oracle_record = source:get_record(oracle_id)

    assert_true("pg url record exists", pg_url_record ~= nil)
    assert_true("pg form record exists", pg_form_record ~= nil)
    assert_true("oracle record exists", oracle_record ~= nil)

    assert_eq("pg url exact roundtrip", pg_url_record.url, pg_url)
    assert_eq("pg url wizard mode", pg_url_record.wizard.mode, "postgres_url")
    assert_eq("pg url wizard field", pg_url_record.wizard.fields.url, pg_url)

    assert_eq("pg form rendered url", pg_form_record.wizard.rendered_url, "postgres://form_user:literal-pass@form-host:5432/form_db?sslmode=require")
    assert_eq("pg form url roundtrip", pg_form_record.url, "postgres://form_user:literal-pass@form-host:5432/form_db?sslmode=require")
    assert_eq("pg form literal password", pg_form_record.wizard.fields.password, "literal-pass")

    assert_eq("oracle descriptor roundtrip", oracle_record.wizard.fields.descriptor, oracle_descriptor)
    assert_eq("oracle wizard mode", oracle_record.wizard.mode, "oracle_custom_jdbc")

    source:delete(pg_form_id)
    local after_delete = read_json(path)
    assert_true("pg url remains after delete", find_record(after_delete, pg_url_id) ~= nil)
    assert_true("oracle remains after delete", find_record(after_delete, oracle_id) ~= nil)
    assert_eq("pg form removed", find_record(after_delete, pg_form_id), nil)

    assert_eq("metadata roundtrip pg url", pg_url_record.wizard.db_kind, "postgres")
    assert_eq("metadata roundtrip pg form", pg_form_record.wizard.db_kind, "postgres")
    assert_eq("metadata roundtrip oracle", oracle_record.wizard.db_kind, "oracle")
    assert_match("placeholder preserved", pg_url_record.url, "${PG_PASSWORD}")
  end)

  print("DCFG02_METADATA_ROUNDTRIP_OK=true")
  print("DCFG02_PASSWORD_PLACEHOLDER_PRESERVED_OK=true")
  print("DCFG02_PG_URL_ROUNDTRIP_OK=true")
  print("DCFG02_PG_FORM_RENDERED_URL_OK=true")
  print("DCFG02_ORACLE_DESCRIPTOR_ROUNDTRIP_OK=true")
  print("DCFG02_DELETE_PRESERVES_SIBLINGS_OK=true")
end

run_atomic_write_contract()
run_unknown_field_contracts()
run_roundtrip_contracts()

print("DCFG02_FILESOURCE_ALL_PASS=true")
vim.cmd("qa!")
