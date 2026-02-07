--- Incremental benchmark for dbee LSP.
--- Run each step individually after opening dbee:
---   :lua require("dbee.lsp.bench").step1()
---   :lua require("dbee.lsp.bench").step2()
---   etc.

local M = {}

local function timed(label, fn)
  local start = vim.loop.hrtime()
  local ok, result = pcall(fn)
  local elapsed_ms = (vim.loop.hrtime() - start) / 1e6
  if ok then
    print(string.format("%s: %.1f ms", label, elapsed_ms))
  else
    print(string.format("%s: ERROR %s", label, tostring(result)))
  end
  return ok and result or nil
end

-- Step 1: Is the handler available? (should be instant)
function M.step1()
  local state = require("dbee.api.state")
  print("core_loaded: " .. tostring(state.is_core_loaded()))
  print("ui_loaded: " .. tostring(state.is_ui_loaded()))
  local h = timed("state.handler()", function() return state.handler() end)
  if h then print("handler: OK") end
end

-- Step 2: Get current connection (should be instant)
function M.step2()
  local state = require("dbee.api.state")
  local handler = state.handler()
  local conn = timed("get_current_connection()", function()
    return handler:get_current_connection()
  end)
  if conn then
    print(string.format("  name=%s type=%s id=%s", conn.name, conn.type, conn.id))
    -- stash for later steps
    M._conn = conn
    M._handler = handler
  else
    print("  no connection active")
  end
end

-- Step 3: Get structure (THIS IS LIKELY THE SLOW ONE)
function M.step3()
  if not M._handler or not M._conn then
    print("run step2 first")
    return
  end
  local s = timed("connection_get_structure()", function()
    return M._handler:connection_get_structure(M._conn.id)
  end)
  if s then
    -- count nodes
    local counts = { schema = 0, table = 0, view = 0, other = 0 }
    local function walk(nodes)
      if not nodes or nodes == vim.NIL then return end
      for _, n in ipairs(nodes) do
        local t = n.type or ""
        if t == "" then counts.schema = counts.schema + 1
        elseif t == "table" then counts.table = counts.table + 1
        elseif t == "view" then counts.view = counts.view + 1
        else counts.other = counts.other + 1 end
        walk(n.children)
      end
    end
    walk(s)
    print(string.format("  %d schemas, %d tables, %d views, %d other",
      counts.schema, counts.table, counts.view, counts.other))
    M._structure = s
  end
end

-- Step 3b: Get structure again (Go-side cached, should be fast)
function M.step3b()
  if not M._handler or not M._conn then
    print("run step2 first")
    return
  end
  timed("connection_get_structure() [2nd call]", function()
    return M._handler:connection_get_structure(M._conn.id)
  end)
end

-- Step 4: Get columns for one table
function M.step4()
  if not M._handler or not M._conn or not M._structure then
    print("run step3 first")
    return
  end
  -- find first table
  local tbl
  local function find(nodes)
    if tbl or not nodes or nodes == vim.NIL then return end
    for _, n in ipairs(nodes) do
      if n.type == "table" then tbl = n; return end
      find(n.children)
    end
  end
  find(M._structure)

  if not tbl then
    print("no tables found in structure")
    return
  end

  print(string.format("  table: %s.%s", tbl.schema or "", tbl.name))
  local cols = timed("connection_get_columns()", function()
    return M._handler:connection_get_columns(M._conn.id, {
      table = tbl.name,
      schema = tbl.schema or "",
      materialization = tbl.type,
    })
  end)
  if cols then
    print(string.format("  %d columns", #cols))
  end
end

-- Step 5: LSP start with empty cache (no structure call)
function M.step5()
  local srv = require("dbee.lsp.server")
  local SC = require("dbee.lsp.schema_cache")
  local state = require("dbee.api.state")

  local handler = state.handler()
  local conn = handler:get_current_connection()
  if not conn then print("no connection"); return end

  local cache = SC:new(handler, conn.id)
  -- deliberately NOT calling cache:build()

  local cid = timed("vim.lsp.start() empty cache", function()
    return vim.lsp.start({
      name = "dbee-lsp-bench",
      cmd = srv.create(cache),
      root_dir = vim.fn.getcwd(),
    })
  end)
  if cid then
    print("  client_id: " .. cid)
    -- stop it
    local client = vim.lsp.get_client_by_id(cid)
    if client then client:stop() end
    print("  stopped")
  end
end

-- Step 6: Cache build from pre-fetched structure (no RPC)
function M.step6()
  if not M._handler or not M._conn then
    print("run step2 first")
    return
  end

  -- try drawer cache first
  local state = require("dbee.api.state")
  local structs
  local ok, drawer = pcall(state.drawer)
  if ok and drawer and drawer.structure_cache then
    local cached = drawer.structure_cache[M._conn.id]
    if cached and cached.structures then
      structs = cached.structures
      print("  source: drawer cache (already in Lua memory)")
    end
  end

  -- fallback to step3 structure if available
  if not structs and M._structure then
    structs = M._structure
    print("  source: step3 structure (fetched earlier)")
  end

  if not structs then
    print("  no structure available — run step3 first or open the drawer")
    return
  end

  local SC = require("dbee.lsp.schema_cache")
  local cache = SC:new(M._handler, M._conn.id)
  timed("cache:build_from_structure() [pure Lua flatten]", function()
    cache:build_from_structure(structs)
  end)
  print(string.format("  %d schemas, %d table names",
    #cache:get_schemas(), #cache:get_all_table_names()))
end

-- Step 7: Full LSP status
function M.step7()
  local lsp = require("dbee.lsp")
  print(vim.inspect(lsp.status()))
end

-- Step 8: Test metadata SQL query (executes and times the query, doesn't start LSP)
function M.step8()
  if not M._handler or not M._conn then
    print("run step2 first")
    return
  end

  local lsp_init = require("dbee.lsp")
  local queries = {
    oracle = [[SELECT owner AS schema_name, table_name, 'table' AS obj_type
      FROM all_tables T JOIN all_users U ON T.owner = U.username WHERE U.common = 'NO'
      UNION ALL
      SELECT owner AS schema_name, view_name AS table_name, 'view' AS obj_type
      FROM all_views V JOIN all_users U ON V.owner = U.username WHERE U.common = 'NO'
      ORDER BY 1, 2]],
  }

  local sql = queries[M._conn.type]
  if not sql then
    print("no metadata query for type: " .. M._conn.type)
    return
  end

  print("  executing metadata query for type: " .. M._conn.type)
  local call = timed("connection_execute(metadata SQL)", function()
    return M._handler:connection_execute(M._conn.id, "/* dbee-lsp bench */ " .. sql)
  end)
  if call then
    print(string.format("  call_id=%s state=%s", call.id, call.state))
    print("  waiting for archived state... (check step7 or call step8b)")
    M._metadata_call = call
  end
end

-- Step 8b: Check metadata query result and parse it
function M.step8b()
  if not M._handler or not M._metadata_call then
    print("run step8 first")
    return
  end

  -- Check call state
  local calls = M._handler:connection_get_calls(M._conn.id)
  local call
  for _, c in ipairs(calls) do
    if c.id == M._metadata_call.id then
      call = c
      break
    end
  end

  if not call then
    print("call not found")
    return
  end

  print(string.format("  state=%s time_taken=%.1fms", call.state, call.time_taken_us / 1000))

  if call.state ~= "archived" then
    print("  not archived yet, try again later")
    return
  end

  -- Store as JSON to temp file
  local tmp = os.tmpname() .. ".json"
  timed("call_store_result(json, file)", function()
    M._handler:call_store_result(call.id, "json", "file", { extra_arg = tmp })
  end)

  -- Read and parse
  local f = io.open(tmp, "r")
  if not f then
    print("  failed to open " .. tmp)
    return
  end
  local content = f:read("*a")
  f:close()
  local file_size = #content
  os.remove(tmp)

  print(string.format("  JSON file size: %.1f KB", file_size / 1024))

  local rows = timed("vim.json.decode", function()
    return vim.json.decode(content)
  end)

  if rows then
    print(string.format("  %d rows", #rows))
    -- Show first 3 rows
    for i = 1, math.min(3, #rows) do
      print(string.format("  row %d: %s", i, vim.inspect(rows[i])))
    end

    -- Build cache from rows
    local SC = require("dbee.lsp.schema_cache")
    local cache = SC:new(M._handler, M._conn.id)
    timed("cache:build_from_metadata_rows()", function()
      cache:build_from_metadata_rows(rows)
    end)
    print(string.format("  %d schemas, %d table names",
      #cache:get_schemas(), #cache:get_all_table_names()))
  end
end

return M
