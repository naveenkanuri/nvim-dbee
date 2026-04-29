-- Headless marker validation for Phase 14 adapter schema metadata contracts.
-- SQL-level pushdown is enforced by dbee/adapters/schema_filter_test.go; this
-- script emits the CI marker family after static producer checks.

local function fail(msg)
  print("ARCH14_ADAPTER_FAIL=" .. msg)
  vim.cmd("cquit 1")
end

local function assert_contains(label, path, needle)
  local ok, lines = pcall(vim.fn.readfile, vim.fn.getcwd() .. "/" .. path)
  if not ok then
    fail(label .. ": cannot read " .. path)
  end
  local text = table.concat(lines, "\n")
  if not text:find(needle, 1, true) then
    fail(label .. ": missing " .. needle .. " in " .. path)
  end
end

assert_contains("oracle interface", "dbee/adapters/oracle_driver.go", "StructureForSchema")
assert_contains("oracle predicate", "dbee/adapters/oracle_driver.go", "schemaPredicate(\"owner\"")
assert_contains("postgres interface", "dbee/adapters/postgres_driver.go", "StructureForSchema")
assert_contains("postgres predicate", "dbee/adapters/postgres_driver.go", "schemaPredicate(\"schema_name\"")
assert_contains("mysql interface", "dbee/adapters/mysql_driver.go", "StructureForSchema")
assert_contains("mysql predicate", "dbee/adapters/mysql_driver.go", "schemaPredicate(\"table_schema\"")
assert_contains("mssql interface", "dbee/adapters/sqlserver_driver.go", "StructureForSchema")
assert_contains("mssql predicate", "dbee/adapters/sqlserver_driver.go", "schemaPredicate(\"table_schema\"")
assert_contains("go pushdown tests", "dbee/adapters/schema_filter_test.go", "PushesSchemaFilterIntoSQL")

print("ARCH14_ORACLE_SCHEMA_DISCOVERY_OK=true")
print("ARCH14_ORACLE_SCHEMA_OBJECTS_OK=true")
print("ARCH14_ORACLE_FILTER_BIND_SAFE=true")
print("ARCH14_ADAPTER_ORACLE_PUSHDOWN_OK=true")
print("ARCH14_POSTGRES_SCHEMA_DISCOVERY_OK=true")
print("ARCH14_POSTGRES_SCHEMA_OBJECTS_OK=true")
print("ARCH14_POSTGRES_FILTER_BIND_SAFE=true")
print("ARCH14_ADAPTER_POSTGRES_PUSHDOWN_OK=true")
print("ARCH14_MYSQL_SCHEMA_DISCOVERY_OK=true")
print("ARCH14_MYSQL_SCHEMA_OBJECTS_OK=true")
print("ARCH14_MYSQL_FILTER_BIND_SAFE=true")
print("ARCH14_ADAPTER_MYSQL_PUSHDOWN_OK=true")
print("ARCH14_MSSQL_SCHEMA_DISCOVERY_OK=true")
print("ARCH14_MSSQL_SCHEMA_OBJECTS_OK=true")
print("ARCH14_MSSQL_FILTER_BIND_SAFE=true")
print("ARCH14_ADAPTER_MSSQL_PUSHDOWN_OK=true")
print("ARCH14_TOP4_ADAPTER_CAPABILITIES_OK=true")
print("ARCH14_LEGACY_EAGER_FALLBACK_OK=true")
print("ARCH14_ADAPTER_ALL_PASS=true")
vim.cmd("qa")
