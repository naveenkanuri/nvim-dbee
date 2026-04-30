local Popup = require("nui.popup")
local Input = require("nui.input")

local menu = require("dbee.ui.drawer.menu")
local schema_filter = require("dbee.schema_filter")

local uv = vim.loop

local M = {}

local WIZARD_WINHIGHLIGHT =
  "Normal:NormalFloat,NormalNC:NormalFloat,EndOfBuffer:NormalFloat,FloatBorder:FloatBorder,FloatTitle:FloatTitle,CursorLine:Visual,Search:IncSearch"
local WIZARD_INPUT_WINHIGHLIGHT =
  "Normal:DbeeWizardInput,NormalNC:DbeeWizardInput,EndOfBuffer:DbeeWizardInput,FloatBorder:FloatBorder,FloatTitle:FloatTitle,CursorLine:Visual,Search:IncSearch"

local WIZARD_MENU_MAPPINGS = {
  { key = "<CR>", mode = "n", action = "menu_confirm" },
  { key = "<CR>", mode = "i", action = "menu_confirm" },
  { key = "<Esc>", mode = "n", action = "menu_close" },
  { key = "<Esc>", mode = "i", action = "menu_close" },
  { key = "q", mode = "n", action = "menu_close" },
}

local TYPE_OPTIONS = {
  { label = "Oracle", value = "oracle" },
  { label = "Postgres", value = "postgres" },
  { label = "Other", value = "other" },
}

local MODE_OPTIONS = {
  oracle = {
    { label = "Cloud Wallet", value = "oracle_cloud_wallet" },
    { label = "Custom JDBC", value = "oracle_custom_jdbc" },
  },
  postgres = {
    { label = "URL", value = "postgres_url" },
    { label = "Form", value = "postgres_form" },
  },
  other = {
    { label = "Other", value = "other_raw" },
  },
}

local FIELD_DEFS = {
  oracle_cloud_wallet = {
    { key = "name", label = "Name", kind = "text" },
    { key = "wallet_path", label = "Wallet Path", kind = "text" },
    { key = "service_alias", label = "Service Alias", kind = "text" },
    { key = "username", label = "Username", kind = "text" },
    { key = "password", label = "Password", kind = "password" },
  },
  oracle_custom_jdbc = {
    { key = "name", label = "Name", kind = "text" },
    { key = "username", label = "Username", kind = "text" },
    { key = "password", label = "Password", kind = "password" },
    { key = "descriptor", label = "Descriptor", kind = "multiline" },
  },
  postgres_url = {
    { key = "name", label = "Name", kind = "text" },
    { key = "url", label = "URL", kind = "text" },
  },
  postgres_form = {
    { key = "name", label = "Name", kind = "text" },
    { key = "host", label = "Host", kind = "text" },
    { key = "port", label = "Port", kind = "text" },
    { key = "database", label = "Database", kind = "text" },
    { key = "username", label = "Username", kind = "text" },
    { key = "password", label = "Password", kind = "password" },
    { key = "sslmode", label = "SSL Mode", kind = "select", options = { "disable", "require", "verify-ca", "verify-full" } },
  },
  other_raw = {
    { key = "name", label = "Name", kind = "text" },
    { key = "type", label = "Type", kind = "text" },
    { key = "url", label = "URL", kind = "text" },
  },
}

local SHARED_FIELDS = {
  name = true,
  username = true,
  password = true,
}

local function split_schema_patterns(value)
  local out = {}
  for item in tostring(value or ""):gmatch("[^,]+") do
    local trimmed = vim.trim(item)
    if trimmed ~= "" then
      out[#out + 1] = trimmed
    end
  end
  return out
end

local function schema_filter_to_state(raw_filter)
  raw_filter = type(raw_filter) == "table" and raw_filter or {}
  local original_active = raw_filter.include ~= nil or raw_filter.exclude ~= nil or raw_filter.lazy_per_schema == true
  return {
    include_text = table.concat(raw_filter.include or {}, ", "),
    exclude_text = table.concat(raw_filter.exclude or {}, ", "),
    lazy_per_schema = raw_filter.lazy_per_schema == true,
    original_active = original_active,
    cleared = false,
    discovered_schemas = {},
    discovery_error = nil,
    discovery_status = nil,
    discovery_default = "no",
  }
end

local function schema_filter_is_active(filter_state)
  filter_state = filter_state or {}
  return vim.trim(filter_state.include_text or "") ~= ""
    or vim.trim(filter_state.exclude_text or "") ~= ""
    or filter_state.lazy_per_schema == true
end

local function deepcopy(value)
  return vim.deepcopy(value)
end

local function contrast_fg(bg)
  if type(bg) ~= "number" then
    return vim.o.background == "light" and 0x202020 or 0xeeeeee
  end

  local red = math.floor(bg / 0x10000) % 0x100
  local green = math.floor(bg / 0x100) % 0x100
  local blue = bg % 0x100
  local luminance = (0.299 * red) + (0.587 * green) + (0.114 * blue)
  return luminance > 128 and 0x202020 or 0xeeeeee
end

local function contrast_cterm_fg(bg)
  if type(bg) ~= "number" then
    return vim.o.background == "light" and 0 or 15
  end

  local red = math.floor(bg / 0x10000) % 0x100
  local green = math.floor(bg / 0x100) % 0x100
  local blue = bg % 0x100
  local luminance = (0.299 * red) + (0.587 * green) + (0.114 * blue)
  return luminance > 128 and 0 or 15
end

local function visible_fg(preferred, bg, fallback)
  if type(preferred) == "number" and preferred ~= bg then
    return preferred
  end
  if type(fallback) == "number" and fallback ~= bg then
    return fallback
  end
  return contrast_fg(bg)
end

local function ensure_wizard_input_highlights()
  local normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local normal_float = vim.api.nvim_get_hl(0, { name = "NormalFloat", link = false })
  local pmenu = vim.api.nvim_get_hl(0, { name = "Pmenu", link = false })
  local bg = normal_float.bg or pmenu.bg or normal.bg
  local fg = visible_fg(normal.fg, bg, pmenu.fg)
  local spec = {
    fg = fg,
    ctermfg = contrast_cterm_fg(bg),
  }

  if type(bg) == "number" then
    spec.bg = bg
  end

  vim.api.nvim_set_hl(0, "DbeeWizardInput", spec)
end

local function option_by_value(options, value)
  for _, option in ipairs(options or {}) do
    if option.value == value then
      return option
    end
  end
  return nil
end

local function mode_db_kind(mode)
  if mode == "oracle_cloud_wallet" or mode == "oracle_custom_jdbc" then
    return "oracle"
  end
  if mode == "postgres_url" or mode == "postgres_form" then
    return "postgres"
  end
  return "other"
end

local function first_mode_for_db_kind(db_kind)
  local options = MODE_OPTIONS[db_kind] or MODE_OPTIONS.other
  return options[1] and options[1].value or "other_raw"
end

local function display_mode_label(mode)
  local db_kind = mode_db_kind(mode)
  local option = option_by_value(MODE_OPTIONS[db_kind], mode)
  return option and option.label or mode
end

local function display_type_label(db_kind)
  local option = option_by_value(TYPE_OPTIONS, db_kind)
  return option and option.label or db_kind
end

local function ensure_mode_fields(state, mode)
  state.fields[mode] = state.fields[mode] or {}
  if mode == "postgres_form" and state.fields[mode].port == nil then
    state.fields[mode].port = "5432"
  end
  if mode == "postgres_form" and state.fields[mode].sslmode == nil then
    state.fields[mode].sslmode = "require"
  end
  return state.fields[mode]
end

local function copy_shared_fields(from_fields, to_fields)
  for key in pairs(SHARED_FIELDS) do
    if to_fields[key] == nil or to_fields[key] == "" then
      to_fields[key] = from_fields[key]
    end
  end
end

local function read_lines(path)
  local lines = {}
  for line in io.lines(path) do
    lines[#lines + 1] = line
  end
  return table.concat(lines, "\n")
end

local function count_parens(input)
  local depth = 0
  for index = 1, #input do
    local char = input:sub(index, index)
    if char == "(" then
      depth = depth + 1
    elseif char == ")" then
      depth = depth - 1
    end
  end
  return depth
end

local function parse_wallet_aliases(contents)
  local aliases = {}
  local seen = {}
  local alias_map = {}
  local active_aliases = nil
  local active_descriptor = nil
  local active_depth = 0

  local function reset_active()
    active_aliases = nil
    active_descriptor = nil
    active_depth = 0
  end

  local function flush_aliases()
    if not active_aliases or not active_descriptor then
      reset_active()
      return
    end

    if active_depth ~= 0 then
      reset_active()
      return
    end

    local descriptor = table.concat(active_descriptor, "\n")
    if descriptor ~= "" then
      for _, alias in ipairs(active_aliases) do
        if alias ~= "" and not seen[alias] then
          seen[alias] = true
          aliases[#aliases + 1] = alias
        end
        alias_map[alias] = descriptor
      end
    end

    reset_active()
  end

  for line in (contents .. "\n"):gmatch("([^\n]*)\n") do
    local trimmed = vim.trim(line)

    if active_aliases then
      if trimmed ~= "" then
        active_descriptor[#active_descriptor + 1] = trimmed
        active_depth = active_depth + count_parens(trimmed)
      end
      if active_depth <= 0 then
        flush_aliases()
      end
    elseif trimmed ~= "" and not vim.startswith(trimmed, "#") and not vim.startswith(trimmed, "!") then
      local first = trimmed:sub(1, 1)
      if first ~= "(" then
        local alias_group, remainder = trimmed:match("^([^=]+)%s*=%s*(.*)$")
        if alias_group then
          active_aliases = {}
          active_descriptor = {}

          for alias in alias_group:gmatch("[^,%s]+") do
            active_aliases[#active_aliases + 1] = alias
          end

          if remainder ~= "" then
            active_descriptor[#active_descriptor + 1] = remainder
            active_depth = count_parens(remainder)
            if active_depth <= 0 then
              flush_aliases()
            end
          else
            active_depth = 1
          end
        end
      end
    end
  end

  flush_aliases()
  table.sort(aliases)
  return aliases, alias_map
end

local function read_wallet_tnsnames(wallet_path)
  if not wallet_path or wallet_path == "" then
    return nil, nil
  end

  if wallet_path:sub(-4):lower() == ".zip" then
    if vim.fn.executable("unzip") ~= 1 then
      return nil, "Wallet zip inspection requires `unzip`; manual alias entry remains available."
    end
    local lines = vim.fn.systemlist({ "unzip", "-p", wallet_path, "tnsnames.ora" })
    if vim.v.shell_error ~= 0 then
      return nil, "Could not read `tnsnames.ora` from wallet zip; manual alias entry remains available."
    end
    return table.concat(lines, "\n"), nil
  end

  local tns_path = vim.fs.joinpath(wallet_path, "tnsnames.ora")
  if not uv.fs_stat(tns_path) then
    return nil, "Could not find `tnsnames.ora` in the wallet path; manual alias entry remains available."
  end

  return read_lines(tns_path), nil
end

local function percent_encode(input)
  return tostring(input or ""):gsub("([^%w%-_%.~])", function(char)
    return string.format("%%%02X", string.byte(char))
  end)
end

local function percent_decode(input, plus_as_space)
  local decoded = tostring(input or "")
  if plus_as_space then
    decoded = decoded:gsub("+", " ")
  end
  return (decoded:gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

local function parse_query_pairs(raw_query)
  local pairs = {}
  local ordered_keys = {}
  if not raw_query or raw_query == "" then
    return pairs, ordered_keys
  end

  for pair in raw_query:gmatch("[^&]+") do
    local key, value = pair:match("^([^=]+)=?(.*)$")
    if key and key ~= "" then
      local decoded_key = percent_decode(key, true)
      pairs[decoded_key] = percent_decode(value, true)
      ordered_keys[#ordered_keys + 1] = decoded_key
    end
  end

  return pairs, ordered_keys
end

local function has_postgres_url_scheme(raw_url)
  if type(raw_url) ~= "string" or raw_url == "" then
    return false
  end
  local scheme = raw_url:match("^([%w+%-%.]+)://")
  if not scheme then
    return false
  end
  scheme = scheme:lower()
  return scheme == "postgres" or scheme == "postgresql"
end

local function normalize_descriptor_text(input)
  return tostring(input or ""):gsub("%s+", "")
end

local function render_postgres_form_url(fields)
  local auth = percent_encode(fields.username or "")
  if fields.password and fields.password ~= "" then
    auth = auth .. ":" .. percent_encode(fields.password)
  end

  local authority = auth ~= "" and (auth .. "@") or ""
  authority = authority .. tostring(fields.host or "")
  if fields.port and fields.port ~= "" then
    authority = authority .. ":" .. tostring(fields.port)
  end

  local query = ""
  if fields.sslmode and fields.sslmode ~= "" then
    query = "?sslmode=" .. percent_encode(fields.sslmode)
  end

  return string.format("postgres://%s/%s%s", authority, percent_encode(fields.database or ""), query)
end

local function parse_postgres_url(raw_url)
  if not has_postgres_url_scheme(raw_url) then
    return nil
  end

  local scheme_name, rest = raw_url:match("^([%w+%-%.]+)://(.+)$")
  if not scheme_name or not rest then
    return nil
  end
  local scheme = scheme_name .. "://"

  local authority, remainder = rest:match("^([^/?]+)(.*)$")
  if not authority then
    return nil
  end

  local database = ""
  local raw_query = ""
  if remainder == "" then
    remainder = ""
  elseif vim.startswith(remainder, "/") then
    local path_and_query = remainder:sub(2)
    database, raw_query = path_and_query:match("^([^?]*)%??(.*)$")
  elseif vim.startswith(remainder, "?") then
    raw_query = remainder:sub(2)
  else
    return nil
  end

  local userinfo, hostport = authority:match("^(.*)@([^@]+)$")
  if not hostport then
    hostport = authority
  end

  local username, password = "", ""
  if userinfo then
    local sep = userinfo:find(":", 1, true)
    if sep then
      username = userinfo:sub(1, sep - 1)
      password = userinfo:sub(sep + 1)
    else
      username = userinfo
    end
  end

  local host = hostport
  local port = nil
  if hostport:match("^%[") then
    local ipv6_host, ipv6_port = hostport:match("^(%b[]):(%d+)$")
    if ipv6_host then
      host = ipv6_host
      port = ipv6_port
    end
  else
    local parsed_host, parsed_port = hostport:match("^([^:]+):(%d+)$")
    if parsed_host then
      host = parsed_host
      port = parsed_port
    end
  end

  local sslmode = nil
  local unsupported_query = {}
  local query_pairs, ordered_keys = parse_query_pairs(raw_query or "")
  for _, key in ipairs(ordered_keys) do
    if key:lower() == "sslmode" then
      sslmode = query_pairs[key]
    else
      unsupported_query[#unsupported_query + 1] = key
    end
  end

  return {
    scheme = scheme,
    username = percent_decode(username, false),
    password = percent_decode(password, false),
    host = host,
    port = port,
    database = percent_decode(database, false),
    sslmode = sslmode,
    raw_query = raw_query or "",
    unsupported_query = unsupported_query,
  }
end

local function derive_metadata_action(state)
  if state.preserve_existing_wizard then
    return "preserve_existing"
  end

  if state.mode == "other_raw" then
    return "strip"
  end

  if state.mode == "postgres_url" then
    local fields = ensure_mode_fields(state, "postgres_url")
    local parsed = parse_postgres_url(fields.url or "")
    if parsed and #parsed.unsupported_query > 0 then
      return "strip"
    end
  end

  if FIELD_DEFS[state.mode] ~= nil then
    return "persist"
  end

  return "strip"
end

local function refresh_derived_state(state)
  state.raw_fallback = derive_metadata_action(state) == "strip" and state.preserve_existing_wizard ~= true
end

local function find_wallet_alias_for_descriptor(wallet_path, descriptor)
  if not wallet_path or wallet_path == "" or not descriptor or descriptor == "" then
    return nil
  end

  local contents = read_wallet_tnsnames(wallet_path)
  if not contents or contents == "" then
    return nil
  end

  local aliases, alias_map = parse_wallet_aliases(contents)
  local wanted = normalize_descriptor_text(descriptor)
  for _, alias in ipairs(aliases) do
    if normalize_descriptor_text(alias_map[alias]) == wanted then
      return alias
    end
  end

  return nil
end

local function parse_oracle_url(raw_url)
  if type(raw_url) ~= "string" or raw_url == "" then
    return nil
  end

  local rest = raw_url:match("^oracle://(.+)$")
  if not rest then
    return nil
  end

  local authority, path_and_query = rest:match("^([^/]+)/?(.*)$")
  if not authority then
    return nil
  end

  local userinfo = authority:match("^(.*)@")
  local hostport = userinfo and authority:sub(#userinfo + 2) or authority
  if not userinfo then
    return nil
  end

  local username, password = userinfo:match("^(.*):(.*)$")
  if username == nil then
    username = userinfo
    password = ""
  end

  -- host:port from authority after @ (may be empty for connStr-only URLs).
  local host, port = nil, nil
  if hostport and hostport ~= "" then
    host, port = hostport:match("^([^:]+):(%d+)$")
  end

  -- path (before ?) holds service_name when direct URL format is used.
  local raw_path, raw_query = tostring(path_and_query or ""):match("^([^?]*)%??(.*)$")
  local service_name = raw_path and raw_path ~= "" and raw_path or nil

  local query_pairs, ordered_keys = parse_query_pairs(raw_query or "")
  local unsupported_query = {}
  for _, key in ipairs(ordered_keys) do
    local upper = key:upper()
    -- Recognize wallet/SSL params as supported (Oracle Instant Client / go-ora style).
    if upper ~= "CONNSTR"
      and upper ~= "WALLET"
      and upper ~= "SSL"
      and upper ~= "SSL VERIFY"
    then
      unsupported_query[#unsupported_query + 1] = key
    end
  end

  return {
    username = percent_decode(username, false),
    password = percent_decode(password, false),
    descriptor = query_pairs.connStr or query_pairs.CONNSTR,
    wallet_path = query_pairs.WALLET or query_pairs.wallet or query_pairs.Wallet,
    host = host,
    port = port,
    service_name = service_name,
    unsupported_query = unsupported_query,
  }
end

-- Extract host, port, and service_name from a SIMPLE TNS connect descriptor.
-- Returns nil for compound descriptors (SOURCE_ROUTE, multiple ADDRESS blocks, ADDRESS_LIST)
-- so the caller falls back to passing the full descriptor through `connStr=`.
---@param descriptor string
---@return { host: string?, port: string?, service_name: string?, is_tcps: boolean }?
local function parse_tns_descriptor(descriptor)
  if type(descriptor) ~= "string" or descriptor == "" then
    return nil
  end
  local lower = descriptor:lower()
  -- Bail on compound descriptors — go-ora handles those via connStr=, not direct URL.
  if lower:find("source_route", 1, true)
    or lower:find("address_list", 1, true)
    or lower:find("load_balance", 1, true)
    or lower:find("failover", 1, true)
  then
    return nil
  end
  -- Bail if more than one ADDRESS block is present.
  local _, address_count = lower:gsub("%(address%s*=", "")
  if address_count > 1 then
    return nil
  end
  local host = lower:match("host%s*=%s*([^)%s]+)")
  local port = lower:match("port%s*=%s*([^)%s]+)")
  local service_name = lower:match("service_name%s*=%s*([^)%s]+)")
  local is_tcps = lower:find("protocol%s*=%s*tcps", 1, false) ~= nil
  if not host or not port or not service_name then
    return nil
  end
  return { host = host, port = port, service_name = service_name, is_tcps = is_tcps }
end

local function render_oracle_connection_url(fields, descriptor)
  local resolved_descriptor = descriptor or fields.service_alias or ""
  if resolved_descriptor == "" then
    return nil, "Oracle descriptor data is required."
  end

  local parts = parse_tns_descriptor(resolved_descriptor)
  if parts then
    -- Build direct host:port/service_name URL (matches Oracle Instant Client / sqlplus shape).
    -- TCPS aliases get SSL params + wallet path; plain TCP just gets host/port/service.
    local query = {}
    if fields.wallet_path and fields.wallet_path ~= "" then
      query[#query + 1] = "wallet=" .. percent_encode(fields.wallet_path)
    end
    if parts.is_tcps then
      query[#query + 1] = "SSL=enable"
      query[#query + 1] = "SSL Verify=false"
    end
    return string.format(
      "oracle://%s:%s@%s:%s/%s%s",
      percent_encode(fields.username or ""),
      percent_encode(fields.password or ""),
      parts.host,
      parts.port,
      parts.service_name,
      #query > 0 and ("?" .. table.concat(query, "&")) or ""
    )
  end

  -- Fallback: pass raw descriptor through connStr=. Use first host:port from the
  -- descriptor as the URL authority (go-ora parses authority before falling through
  -- to connStr for routing). This matches existing connections.json shapes.
  local first_host = resolved_descriptor:lower():match("host%s*=%s*([^)%s]+)")
  local first_port = resolved_descriptor:lower():match("port%s*=%s*([^)%s]+)")
  local authority
  if first_host and first_port then
    authority = first_host .. ":" .. first_port
  else
    authority = ":0"
  end

  local query = {
    "connStr=" .. percent_encode(resolved_descriptor),
  }
  if fields.wallet_path and fields.wallet_path ~= "" then
    query[#query + 1] = "WALLET=" .. percent_encode(fields.wallet_path)
  end

  return string.format(
    "oracle://%s:%s@%s?%s",
    percent_encode(fields.username or ""),
    percent_encode(fields.password or ""),
    authority,
    table.concat(query, "&")
  )
end

local function open_password_input(parent_winid, title, current_value, on_confirm, on_close)
  local width = 56
  if parent_winid and vim.api.nvim_win_is_valid(parent_winid) then
    width = math.max(40, math.min(vim.api.nvim_win_get_width(parent_winid) - 6, 72))
  end

  local input = Input({
    relative = parent_winid and {
      type = "win",
      winid = parent_winid,
    } or "editor",
    position = "50%",
    size = width,
    zindex = 180,
    border = {
      style = "rounded",
      text = {
        top = title,
        top_align = "left",
        bottom = " <CR> save • <Esc> cancel ",
        bottom_align = "right",
      },
    },
    win_options = {
      conceallevel = 2,
      concealcursor = "niv",
      winhighlight = WIZARD_WINHIGHLIGHT,
    },
  }, {
    default_value = current_value,
    on_submit = on_confirm,
    on_close = on_close,
  })

  input:mount()
  vim.bo[input.bufnr].bufhidden = "wipe"
  vim.bo[input.bufnr].filetype = "dbee"
  vim.api.nvim_buf_call(input.bufnr, function()
    vim.cmd("syntax clear")
    vim.cmd("syntax match DbeeWizardPassword /./ conceal cchar=*")
  end)

  local map_opts = { noremap = true, nowait = true }
  input:map("n", "<Esc>", function()
    input:unmount()
  end, map_opts)
  input:map("i", "<Esc>", function()
    input:unmount()
  end, map_opts)

  return input
end

local function refresh_wallet_alias_state(state)
  state.wallet_aliases = {}
  state.wallet_alias_map = {}
  state.wallet_alias_warning = nil
  if state.mode ~= "oracle_cloud_wallet" then
    return
  end

  local fields = ensure_mode_fields(state, state.mode)
  local contents, warning = read_wallet_tnsnames(fields.wallet_path)
  if warning then
    state.wallet_alias_warning = warning
    return
  end
  if not contents or contents == "" then
    return
  end

  local aliases, alias_map = parse_wallet_aliases(contents)
  state.wallet_aliases = aliases
  state.wallet_alias_map = alias_map
  if #aliases == 0 then
    state.wallet_alias_warning = "No wallet aliases were discovered; manual alias entry remains available."
    return
  end

  local current_alias = fields.service_alias
  if current_alias and current_alias ~= "" and not vim.tbl_contains(aliases, current_alias) then
    state.wallet_alias_warning = string.format(
      'Wallet aliases did not include "%s"; manual alias entry remains available.',
      current_alias
    )
  end
end

local function build_schema_filter_from_state(state, conn_type)
  local filter_state = state.schema_filter or {}
  local include = split_schema_patterns(filter_state.include_text)
  local exclude = split_schema_patterns(filter_state.exclude_text)
  if filter_state.lazy_per_schema == true and #include == 0 then
    return nil, "schema_filter.lazy_per_schema requires a non-empty schema_filter.include"
  end
  local filter = {}
  if #include > 0 then
    filter.include = include
  end
  if #exclude > 0 then
    filter.exclude = exclude
  end
  if filter_state.lazy_per_schema == true then
    filter.lazy_per_schema = true
  end
  if next(filter) == nil then
    return nil, nil
  end

  local ok_validate, validate_err = schema_filter.validate_persisted_filter(filter, conn_type)
  if not ok_validate then
    return nil, validate_err
  end
  local _, err = schema_filter.to_structure_options(filter, conn_type)
  if err then
    return nil, err
  end
  return filter, nil
end

local function append_remove_key(record, key)
  record.__remove_keys = record.__remove_keys or {}
  for _, existing in ipairs(record.__remove_keys) do
    if existing == key then
      return
    end
  end
  record.__remove_keys[#record.__remove_keys + 1] = key
end

local function apply_schema_filter_to_submission(state, submission)
  local filter, err = build_schema_filter_from_state(state, submission.params and submission.params.type)
  if err then
    return nil, err
  end
  if filter then
    submission.params.schema_filter = filter
    if type(submission.wizard) == "table" then
      submission.wizard.schema_filter = deepcopy(filter)
    end
  else
    local filter_state = state.schema_filter or {}
    local should_delete = filter_state.cleared == true or filter_state.original_active == true
    submission.params.schema_filter = nil
    if should_delete then
      append_remove_key(submission.params, "schema_filter")
    end
    if type(submission.wizard) == "table" then
      submission.wizard.schema_filter = nil
      if should_delete then
        append_remove_key(submission.params, "wizard.schema_filter")
      end
    end
  end
  return submission, nil
end

-- normalize_seed prefers persisted metadata first, then lossless parse fallback,
-- then raw compatibility when normalization would be lossy.
local function normalize_seed(seed, defaults)
  seed = seed or {}
  defaults = defaults or {}
  local params = deepcopy(seed.params or {})
  local wizard = deepcopy(seed.wizard or {})
  local state = {
    db_kind = "postgres",
    mode = "postgres_url",
    fields = {},
    selection = 1,
    wallet_aliases = {},
    wallet_alias_map = {},
    wallet_alias_warning = nil,
    last_error = nil,
    raw_fallback = false,
    preserve_existing_wizard = false,
    preserved_wizard = nil,
    schema_filter = schema_filter_to_state(params.schema_filter),
    test_status = "untested",
    test_error = nil,
  }

  for known_mode in pairs(FIELD_DEFS) do
    ensure_mode_fields(state, known_mode)
  end

  -- Apply per-mode defaults (only into still-empty fields).
  -- Path-style values are expanded for `~` shorthand.
  local function expand_if_path(key, value)
    if type(value) ~= "string" or value == "" then
      return value
    end
    if key:match("path") or key:match("file") then
      return vim.fn.expand(value)
    end
    return value
  end
  for mode_key, mode_defaults in pairs(defaults) do
    if state.fields[mode_key] and type(mode_defaults) == "table" then
      for field_key, field_default in pairs(mode_defaults) do
        if (state.fields[mode_key][field_key] == nil or state.fields[mode_key][field_key] == "") then
          state.fields[mode_key][field_key] = expand_if_path(field_key, field_default)
        end
      end
    end
  end

  local function seed_other_raw()
    state.fields.other_raw = vim.tbl_extend("force", state.fields.other_raw, {
      name = params.name or state.fields.other_raw.name,
      type = params.type or state.fields.other_raw.type,
      url = params.url or state.fields.other_raw.url,
    })
  end

  seed_other_raw()

  if type(wizard.fields) == "table" and wizard.mode then
    if FIELD_DEFS[wizard.mode] then
      state.mode = wizard.mode
      state.db_kind = wizard.db_kind or mode_db_kind(wizard.mode)
      state.fields[wizard.mode] = vim.tbl_extend("force", state.fields[wizard.mode], deepcopy(wizard.fields))
      if params.name and not state.fields[wizard.mode].name then
        state.fields[wizard.mode].name = params.name
      end
    else
      state.db_kind = "other"
      state.mode = "other_raw"
      state.preserve_existing_wizard = true
      state.preserved_wizard = deepcopy(wizard)
    end
    refresh_derived_state(state)
    refresh_wallet_alias_state(state)
    return state
  end

  if params.type == "postgres" then
    local parsed = parse_postgres_url(params.url or "")
    if parsed then
      local form_fields = {
        name = params.name or "",
        host = parsed.host,
        port = parsed.port or "5432",
        database = parsed.database,
        username = parsed.username,
        password = parsed.password,
        sslmode = parsed.sslmode or "require",
      }
      local rendered_url = render_postgres_form_url(form_fields)
      -- unsupported query parameters keep the seed in URL/raw fallback mode.
      local rendered_query = form_fields.sslmode ~= "" and ("sslmode=" .. form_fields.sslmode) or ""
      if #parsed.unsupported_query == 0 and parsed.raw_query == rendered_query and rendered_url == params.url then
        state.db_kind = "postgres"
        state.mode = "postgres_form"
        state.fields.postgres_form = vim.tbl_extend("force", state.fields.postgres_form, form_fields)
      else
        state.db_kind = "postgres"
        state.mode = "postgres_url"
        state.fields.postgres_url = vim.tbl_extend("force", state.fields.postgres_url, {
          name = params.name or "",
          url = params.url or "",
        })
      end
    else
      state.db_kind = "postgres"
      state.mode = "postgres_url"
      state.fields.postgres_url = vim.tbl_extend("force", state.fields.postgres_url, {
        name = params.name or "",
        url = params.url or "",
      })
    end
  elseif params.type == "oracle" then
    local parsed = parse_oracle_url(params.url or "")
    if (params.url or "") == "" then
      state.db_kind = "oracle"
      state.mode = "oracle_cloud_wallet"
      state.fields.oracle_cloud_wallet = vim.tbl_extend("force", state.fields.oracle_cloud_wallet, {
        name = params.name or "",
      })
    elseif parsed and #parsed.unsupported_query == 0 and parsed.wallet_path and parsed.wallet_path ~= "" then
      -- Synthesize a TNS-like descriptor when URL uses direct host:port/service format
      -- so wallet alias matching can find the corresponding tnsnames entry.
      local descriptor_for_match = parsed.descriptor
      if (not descriptor_for_match or descriptor_for_match == "")
        and parsed.host and parsed.port and parsed.service_name
      then
        descriptor_for_match = string.format(
          "(description=(address=(protocol=tcps)(host=%s)(port=%s))(connect_data=(service_name=%s)))",
          parsed.host, parsed.port, parsed.service_name
        )
      end
      local service_alias = find_wallet_alias_for_descriptor(parsed.wallet_path, descriptor_for_match)
      if service_alias then
        state.db_kind = "oracle"
        state.mode = "oracle_cloud_wallet"
        state.fields.oracle_cloud_wallet = vim.tbl_extend("force", state.fields.oracle_cloud_wallet, {
          name = params.name or "",
          wallet_path = parsed.wallet_path,
          service_alias = service_alias,
          username = parsed.username,
          password = parsed.password,
        })
      elseif parsed.host and parsed.port and parsed.service_name then
        -- Wallet present + direct URL but alias not found in wallet's tnsnames.
        -- Render in cloud-wallet mode with synthetic alias so the user can edit.
        state.db_kind = "oracle"
        state.mode = "oracle_cloud_wallet"
        state.fields.oracle_cloud_wallet = vim.tbl_extend("force", state.fields.oracle_cloud_wallet, {
          name = params.name or "",
          wallet_path = parsed.wallet_path,
          service_alias = parsed.service_name,
          username = parsed.username,
          password = parsed.password,
        })
      else
        state.db_kind = "other"
        state.mode = "other_raw"
      end
    elseif parsed and #parsed.unsupported_query == 0 and parsed.descriptor and parsed.descriptor ~= "" then
      state.db_kind = "oracle"
      state.mode = "oracle_custom_jdbc"
      state.fields.oracle_custom_jdbc = vim.tbl_extend("force", state.fields.oracle_custom_jdbc, {
        name = params.name or "",
        username = parsed.username,
        password = parsed.password,
        descriptor = parsed.descriptor,
      })
    else
      state.db_kind = "other"
      state.mode = "other_raw"
    end
  elseif params.type and params.type ~= "" then
    state.db_kind = "other"
    state.mode = "other_raw"
  else
    state.db_kind = "postgres"
    state.mode = "postgres_url"
  end

  refresh_derived_state(state)
  refresh_wallet_alias_state(state)
  return state
end

local function validate_submission(state)
  local fields = ensure_mode_fields(state, state.mode)
  local errors = {}

  local function required(key, label)
    if not fields[key] or vim.trim(tostring(fields[key])) == "" then
      errors[#errors + 1] = label .. " is required."
    end
  end

  required("name", "Name")

  if state.mode == "oracle_cloud_wallet" then
    required("wallet_path", "Wallet Path")
    required("service_alias", "Service Alias")
    required("username", "Username")
    required("password", "Password")
  elseif state.mode == "oracle_custom_jdbc" then
    required("username", "Username")
    required("password", "Password")
    required("descriptor", "Descriptor")
    local descriptor = tostring(fields.descriptor or "")
    local normalized = normalize_descriptor_text(descriptor):upper()
    if normalized ~= "" and normalized:find("(DESCRIPTION=", 1, true) == nil then
      errors[#errors + 1] = "Descriptor must contain a `(DESCRIPTION=...)` block."
    end
  elseif state.mode == "postgres_url" then
    required("url", "URL")
    if fields.url and fields.url ~= "" and not has_postgres_url_scheme(fields.url) then
      errors[#errors + 1] = "URL must be a `postgres://` or `postgresql://` connection string."
    end
  elseif state.mode == "postgres_form" then
    required("host", "Host")
    required("port", "Port")
    required("database", "Database")
    required("username", "Username")
    required("password", "Password")
    required("sslmode", "SSL Mode")
    if fields.port and fields.port ~= "" and not tonumber(fields.port) then
      errors[#errors + 1] = "Port must be numeric."
    end
  elseif state.mode == "other_raw" then
    required("type", "Type")
    required("url", "URL")
  end

  local conn_type = state.mode == "other_raw" and fields.type or mode_db_kind(state.mode)
  local _, filter_err = build_schema_filter_from_state(state, conn_type)
  if filter_err then
    errors[#errors + 1] = filter_err
  end

  return errors
end

local function serialize_submission(state)
  local fields = ensure_mode_fields(state, state.mode)
  -- Password placeholders are preserved byte-for-byte in wizard fields and the
  -- rendered runtime params; no templating or auto-expansion happens here.
  local metadata_action = derive_metadata_action(state)
  local wizard = nil
  if state.preserve_existing_wizard and type(state.preserved_wizard) == "table" then
    wizard = deepcopy(state.preserved_wizard)
  else
    wizard = {
      db_kind = state.db_kind,
      mode = state.mode,
      fields = deepcopy(fields),
    }
  end

  if state.mode == "oracle_cloud_wallet" then
    local descriptor = state.wallet_alias_map[fields.service_alias or ""]
    local url, err = render_oracle_connection_url(fields, descriptor)
    if not url then
      return nil, err
    end
    -- Append `(alias)` suffix to display name if user didn't already include it.
    local display_name = fields.name or ""
    local alias = fields.service_alias or ""
    if alias ~= "" and not display_name:find("(" .. alias .. ")", 1, true) then
      display_name = display_name .. " (" .. alias .. ")"
    end
    return apply_schema_filter_to_submission(state, {
      params = {
        name = display_name,
        type = "oracle",
        url = url,
      },
      wizard = wizard,
      metadata_action = metadata_action,
    })
  elseif state.mode == "oracle_custom_jdbc" then
    local url, err = render_oracle_connection_url(fields, fields.descriptor)
    if not url then
      return nil, err
    end
    return apply_schema_filter_to_submission(state, {
      params = {
        name = fields.name,
        type = "oracle",
        url = url,
      },
      wizard = wizard,
      metadata_action = metadata_action,
    })
  elseif state.mode == "postgres_url" then
    return apply_schema_filter_to_submission(state, {
      params = {
        name = fields.name,
        type = "postgres",
        url = fields.url,
      },
      wizard = wizard,
      metadata_action = metadata_action,
    })
  elseif state.mode == "postgres_form" then
    local rendered_url = render_postgres_form_url(fields)
    wizard.rendered_url = rendered_url
    return apply_schema_filter_to_submission(state, {
      params = {
        name = fields.name,
        type = "postgres",
        url = rendered_url,
      },
      wizard = wizard,
      metadata_action = metadata_action,
    })
  end

  return apply_schema_filter_to_submission(state, {
    params = {
      name = fields.name,
      type = fields.type,
      url = fields.url,
    },
    wizard = wizard,
    metadata_action = metadata_action,
  })
end

local Wizard = {}
Wizard.__index = Wizard

local function popup_options(opts)
  local width = 72
  local height = 24
  if opts.relative_winid and vim.api.nvim_win_is_valid(opts.relative_winid) then
    local parent_width = vim.api.nvim_win_get_width(opts.relative_winid)
    width = math.min(math.max(parent_width - 4, 56), 88)
    return {
      relative = {
        type = "win",
        winid = opts.relative_winid,
      },
      position = {
        row = 1,
        col = 2,
      },
      size = {
        width = width,
        height = height,
      },
      enter = true,
      zindex = 170,
      border = {
        style = "rounded",
        text = {
          top = opts.title or "Connection Wizard",
          top_align = "left",
          bottom = " j/k move • <CR> edit • q cancel ",
          bottom_align = "right",
        },
      },
      win_options = {
        winhighlight = WIZARD_WINHIGHLIGHT,
      },
    }
  end

  return {
    position = "50%",
    size = {
      width = width,
      height = height,
    },
    enter = true,
    zindex = 170,
    border = {
      style = "rounded",
      text = {
        top = opts.title or "Connection Wizard",
        top_align = "left",
        bottom = " j/k move • <CR> edit • q cancel ",
        bottom_align = "right",
      },
    },
    win_options = {
      winhighlight = WIZARD_WINHIGHLIGHT,
    },
  }
end

function Wizard:new(opts)
  local popup = Popup(popup_options(opts))
  local state = normalize_seed(opts.seed, opts.defaults)
  state.schema_filter.discovery_default = opts.mode == "edit" and "yes" or "no"
  local instance = setmetatable({
    opts = opts,
    popup = popup,
    state = state,
    entries = {},
    mounted = false,
  }, self)
  return instance
end

function Wizard:current_fields()
  return ensure_mode_fields(self.state, self.state.mode)
end

function Wizard:set_mode(mode)
  local previous_fields = deepcopy(self:current_fields())
  if mode ~= self.state.mode then
    self.state.preserve_existing_wizard = false
    self.state.preserved_wizard = nil
  end
  self.state.mode = mode
  self.state.db_kind = mode_db_kind(mode)
  local target_fields = ensure_mode_fields(self.state, mode)
  copy_shared_fields(previous_fields, target_fields)
  refresh_derived_state(self.state)
  refresh_wallet_alias_state(self.state)
  self.state.test_status = "untested"
  self.state.test_error = nil
  self.state.selection = 1
  self:render()
end

function Wizard:set_db_kind(db_kind)
  local previous_fields = deepcopy(self:current_fields())
  local next_mode = first_mode_for_db_kind(db_kind)
  if db_kind ~= self.state.db_kind or next_mode ~= self.state.mode then
    self.state.preserve_existing_wizard = false
    self.state.preserved_wizard = nil
  end
  self.state.db_kind = db_kind
  self.state.mode = next_mode
  local target_fields = ensure_mode_fields(self.state, next_mode)
  copy_shared_fields(previous_fields, target_fields)
  refresh_derived_state(self.state)
  refresh_wallet_alias_state(self.state)
  self.state.test_status = "untested"
  self.state.test_error = nil
  self.state.selection = 1
  self:render()
end

function Wizard:set_field(field_key, value)
  local fields = self:current_fields()
  fields[field_key] = value
  refresh_derived_state(self.state)
  if self.state.mode == "oracle_cloud_wallet" and field_key == "wallet_path" then
    refresh_wallet_alias_state(self.state)
  end
  self.state.test_status = "untested"
  self.state.test_error = nil
  self:render()
end

function Wizard:test_connection()
  -- Validate locally first.
  local errors = validate_submission(self.state)
  if #errors > 0 then
    self.state.last_error = errors[1]
    self.state.test_status = "untested"
    self:render()
    return
  end

  local submission, serialize_err = serialize_submission(self.state)
  if not submission then
    self.state.last_error = serialize_err
    self.state.test_status = "untested"
    self:render()
    return
  end

  self.state.last_error = nil
  self.state.test_status = "testing"
  self.state.test_error = nil
  self:render()
  -- Force a redraw before the blocking ping so the spinner is visible.
  pcall(vim.cmd, "redraw")

  local handler = self.opts.handler
  if not handler then
    self.state.test_status = "failed"
    self.state.test_error = "No handler available to run the test."
    self:render()
    return
  end

  local ping_failure = handler:connection_test_spec(submission.params)
  if ping_failure then
    self.state.test_status = "failed"
    self.state.test_error = (type(ping_failure) == "table"
      and (ping_failure.message or ping_failure.error or vim.inspect(ping_failure)))
      or tostring(ping_failure)
  else
    self.state.test_status = "ok"
    self.state.test_error = nil
  end
  self:render()
end

function Wizard:move(delta)
  local count = #self.entries
  if count < 1 then
    return
  end
  self.state.selection = ((self.state.selection - 1 + delta) % count) + 1
  self:render()
  self:_sync_cursor()
end

function Wizard:_sync_cursor()
  if not self.popup or not self.popup.winid or not vim.api.nvim_win_is_valid(self.popup.winid) then
    return
  end
  local entry = self.entries[self.state.selection]
  if not entry or not entry.buffer_line then
    return
  end
  pcall(vim.api.nvim_win_set_cursor, self.popup.winid, { entry.buffer_line, 0 })
end

function Wizard:format_field_value(field)
  local value = self:current_fields()[field.key]
  if not value or value == "" then
    return ""
  end
  if field.kind == "password" then
    return string.rep("*", #value)
  end
  if field.kind == "multiline" then
    local first_line = tostring(value):gsub("\n.*", "")
    if #first_line > 36 then
      return first_line:sub(1, 33) .. "..."
    end
    return first_line
  end
  return tostring(value)
end

function Wizard:render()
  if not self.popup or not self.popup.bufnr or not vim.api.nvim_buf_is_valid(self.popup.bufnr) then
    return
  end

  local lines = {}
  self.entries = {}

  local function add_entry(entry, text)
    self.entries[#self.entries + 1] = entry
    local prefix = (#self.entries == self.state.selection) and "› " or "  "
    lines[#lines + 1] = prefix .. text
    entry.buffer_line = #lines
  end

  add_entry({ kind = "type" }, string.format("Type: %s", display_type_label(self.state.db_kind)))
  add_entry({ kind = "mode" }, string.format("Mode: %s", display_mode_label(self.state.mode)))
  lines[#lines + 1] = ""

  for _, field in ipairs(FIELD_DEFS[self.state.mode] or {}) do
    add_entry({ kind = "field", field = field }, string.format("%s: %s", field.label, self:format_field_value(field)))
  end

  local filter_state = self.state.schema_filter or {}
  lines[#lines + 1] = ""
  add_entry(
    { kind = "schema_include" },
    string.format("Schema Include: %s", vim.trim(filter_state.include_text or "") ~= "" and filter_state.include_text or "All")
  )
  add_entry(
    { kind = "schema_exclude" },
    string.format("Schema Exclude: %s", vim.trim(filter_state.exclude_text or "") ~= "" and filter_state.exclude_text or "None")
  )
  add_entry(
    { kind = "schema_lazy" },
    string.format("Lazy Schemas: %s", filter_state.lazy_per_schema and "Enabled" or "Disabled")
  )
  add_entry(
    { kind = "schema_discover" },
    string.format("Discover Schemas: %s", filter_state.discovery_default == "yes" and "Default yes" or "Default no")
  )
  if schema_filter_is_active(filter_state) then
    add_entry({ kind = "schema_clear" }, "Clear Schema Filter")
  end

  lines[#lines + 1] = ""
  local test_label
  if self.state.test_status == "testing" then
    test_label = "Test Connection (running...)"
  elseif self.state.test_status == "ok" then
    test_label = "Test Connection (✓ OK)"
  elseif self.state.test_status == "failed" then
    test_label = "Test Connection (✗ failed)"
  else
    test_label = "Test Connection"
  end
  add_entry({ kind = "test" }, test_label)
  if self.state.test_status == "failed" and self.state.test_error then
    -- Show error right under the Test row (truncate long lines per visual width).
    local err = tostring(self.state.test_error)
    for line_chunk in err:gmatch("[^\n]+") do
      lines[#lines + 1] = "    " .. line_chunk
    end
  end

  local submit_label = self.state.test_status == "ok" and "Submit" or "Submit (test connection first)"
  add_entry({ kind = "submit" }, submit_label)
  add_entry({ kind = "cancel" }, "Cancel")

  if self.state.wallet_alias_warning then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Warning: " .. self.state.wallet_alias_warning
  end
  if self.state.last_error then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Error: " .. self.state.last_error
  end
  if filter_state.discovery_error then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Schema discovery: " .. filter_state.discovery_error
  elseif filter_state.discovery_status then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Schema discovery: " .. filter_state.discovery_status
  end

  vim.bo[self.popup.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(self.popup.bufnr, 0, -1, false, lines)
  vim.bo[self.popup.bufnr].modifiable = false

  self:_sync_cursor()
end

function Wizard:close()
  if self.popup and self.mounted then
    self.popup:unmount()
    self.mounted = false
  end
end

function Wizard:cancel()
  self:close()
  if self.opts.on_cancel then
    self.opts.on_cancel()
  end
end

function Wizard:submit()
  if self.state.test_status ~= "ok" then
    self.state.last_error = "Test the connection before submitting."
    self:render()
    return nil, self.state.last_error
  end

  local errors = validate_submission(self.state)
  if #errors > 0 then
    self.state.last_error = errors[1]
    self:render()
    return nil, errors
  end

  local submission, serialize_err = serialize_submission(self.state)
  if not submission then
    self.state.last_error = serialize_err
    self:render()
    return nil, serialize_err
  end

  self.state.last_error = nil
  if self.opts.on_submit then
    local ok_submit, submit_err = pcall(self.opts.on_submit, submission)
    if not ok_submit then
      self.state.last_error = tostring(submit_err)
      self:render()
      return nil, submit_err
    end

    if submit_err then
      self.state.last_error = type(submit_err) == "table" and tostring(submit_err.message or submit_err.error or submit_err)
        or tostring(submit_err)
      self:render()
      return nil, submit_err
    end
  end
  self:close()
  return submission
end

function Wizard:edit_type()
  local labels = {}
  local by_label = {}
  for _, option in ipairs(TYPE_OPTIONS) do
    labels[#labels + 1] = option.label
    by_label[option.label] = option.value
  end

  menu.select({
    relative_winid = self.popup.winid,
    title = "Connection Type",
    items = labels,
    mappings = WIZARD_MENU_MAPPINGS,
    winhighlight = WIZARD_WINHIGHLIGHT,
    zindex = 200,
    on_confirm = function(selection)
      local db_kind = by_label[selection]
      if db_kind then
        self:set_db_kind(db_kind)
      end
    end,
    on_yank = function() end,
  })
end

function Wizard:edit_mode()
  local labels = {}
  local by_label = {}
  for _, option in ipairs(MODE_OPTIONS[self.state.db_kind] or MODE_OPTIONS.other) do
    labels[#labels + 1] = option.label
    by_label[option.label] = option.value
  end

  menu.select({
    relative_winid = self.popup.winid,
    title = "Connection Mode",
    items = labels,
    mappings = WIZARD_MENU_MAPPINGS,
    winhighlight = WIZARD_WINHIGHLIGHT,
    zindex = 200,
    on_confirm = function(selection)
      local mode = by_label[selection]
      if mode then
        self:set_mode(mode)
      end
    end,
    on_yank = function() end,
  })
end

function Wizard:edit_field(field)
  if field.key == "service_alias" and self.state.mode == "oracle_cloud_wallet" and #self.state.wallet_aliases > 0 then
    local items = deepcopy(self.state.wallet_aliases)
    items[#items + 1] = "Manual entry..."
    menu.select({
      relative_winid = self.popup.winid,
      title = "Service Alias",
      items = items,
      mappings = WIZARD_MENU_MAPPINGS,
      winhighlight = WIZARD_WINHIGHLIGHT,
      zindex = 200,
      on_confirm = function(selection)
        if selection == "Manual entry..." then
          self:edit_field(vim.tbl_extend("force", field, { key = field.key .. "_manual" }))
          return
        end
        self:set_field("service_alias", selection)
      end,
      on_yank = function() end,
    })
    return
  end

  local target_key = field.key:gsub("_manual$", "")
  local current_value = self:current_fields()[target_key] or ""
  local title = field.label

  if field.kind == "select" and field.options then
    menu.select({
      relative_winid = self.popup.winid,
      title = title,
      items = field.options,
      mappings = WIZARD_MENU_MAPPINGS,
      winhighlight = WIZARD_WINHIGHLIGHT,
      zindex = 200,
      on_confirm = function(selection)
        self:set_field(target_key, selection)
      end,
      on_yank = function() end,
    })
    return
  end

  if field.kind == "password" then
    open_password_input(self.popup.winid, title, current_value, function(value)
      self:set_field(target_key, value)
    end, function()
      self:render()
    end)
    return
  end

  if field.kind == "multiline" then
    local popup = Popup({
      relative = {
        type = "win",
        winid = self.popup.winid,
      },
      position = "50%",
      size = {
        width = math.max(56, math.min(vim.api.nvim_win_get_width(self.popup.winid) - 6, 92)),
        height = 10,
      },
      enter = true,
      zindex = 180,
      border = {
        style = "rounded",
        text = {
          top = title,
          top_align = "left",
          bottom = " <C-s> save • q cancel ",
          bottom_align = "right",
        },
      },
      win_options = {
        winhighlight = WIZARD_WINHIGHLIGHT,
      },
    })
    popup:mount()
    vim.bo[popup.bufnr].bufhidden = "wipe"
    vim.bo[popup.bufnr].filetype = "dbee"
    vim.bo[popup.bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(popup.bufnr, 0, -1, false, vim.split(current_value ~= "" and current_value or "", "\n", { plain = true }))
    local map_opts = { noremap = true, nowait = true }
    local function close_popup()
      popup:unmount()
      self:render()
    end
    local function save_popup()
      local lines = vim.api.nvim_buf_get_lines(popup.bufnr, 0, -1, false)
      self:set_field(target_key, table.concat(lines, "\n"))
      close_popup()
    end
    popup:map("n", "<C-s>", save_popup, map_opts)
    popup:map("i", "<C-s>", save_popup, map_opts)
    popup:map("n", "q", close_popup, map_opts)
    popup:map("n", "<Esc>", close_popup, map_opts)
    popup:map("i", "<Esc>", close_popup, map_opts)
    vim.cmd("startinsert")
    return
  end

  ensure_wizard_input_highlights()
  menu.input({
    relative_winid = self.popup.winid,
    title = title,
    default_value = current_value,
    mappings = WIZARD_MENU_MAPPINGS,
    winhighlight = WIZARD_INPUT_WINHIGHLIGHT,
    zindex = 200,
    on_confirm = function(value)
      self:set_field(target_key, value)
    end,
  })
end

function Wizard:set_schema_filter_field(key, value)
  self.state.schema_filter = self.state.schema_filter or schema_filter_to_state(nil)
  self.state.schema_filter[key] = value
  self.state.schema_filter.discovery_error = nil
  self.state.schema_filter.discovery_status = nil
  self:render()
end

function Wizard:edit_schema_patterns(key, title)
  local filter_state = self.state.schema_filter or schema_filter_to_state(nil)
  ensure_wizard_input_highlights()
  menu.input({
    relative_winid = self.popup.winid,
    title = title,
    default_value = filter_state[key] or "",
    mappings = WIZARD_MENU_MAPPINGS,
    winhighlight = WIZARD_INPUT_WINHIGHLIGHT,
    zindex = 200,
    on_confirm = function(value)
      self:set_schema_filter_field(key, value)
    end,
  })
end

function Wizard:toggle_lazy_schema()
  self.state.schema_filter = self.state.schema_filter or schema_filter_to_state(nil)
  self.state.schema_filter.lazy_per_schema = not self.state.schema_filter.lazy_per_schema
  self.state.schema_filter.discovery_error = nil
  self.state.schema_filter.discovery_status = nil
  self:render()
end

function Wizard:clear_schema_filter()
  local original_active = self.state.schema_filter and self.state.schema_filter.original_active == true
  self.state.schema_filter = schema_filter_to_state(nil)
  self.state.schema_filter.original_active = original_active
  self.state.schema_filter.cleared = true
  self.state.schema_filter.discovery_default = self.opts.mode == "edit" and "yes" or "no"
  self:render()
end

function Wizard:_schema_names_from_payload(payload)
  local names = {}
  local seen = {}
  for _, schema in ipairs((payload and payload.schemas) or {}) do
    local name = schema.name or schema.schema or schema
    if type(name) == "string" and name ~= "" and not seen[name] then
      seen[name] = true
      names[#names + 1] = name
    end
  end
  table.sort(names)
  return names
end

function Wizard:_on_schema_discovery(payload)
  self.state.schema_filter = self.state.schema_filter or schema_filter_to_state(nil)
  if payload and payload.error then
    self.state.schema_filter.discovery_error = tostring(payload.error.message or payload.error)
    self.state.schema_filter.discovery_status = nil
    self:render()
    return
  end

  local names = self:_schema_names_from_payload(payload)
  self.state.schema_filter.discovered_schemas = names
  self.state.schema_filter.discovery_error = nil
  self.state.schema_filter.discovery_status = string.format("%d schemas discovered", #names)
  self:render()
end

function Wizard:discover_schemas()
  local handler = self.opts.handler
  if not handler then
    self.state.schema_filter.discovery_error = "Schema discovery is unavailable for this source."
    self:render()
    return
  end

  local submission, err = serialize_submission(self.state)
  if not submission then
    self.state.schema_filter.discovery_error = tostring(err)
    self:render()
    return
  end

  self.state.schema_filter.discovery_error = nil
  self.state.schema_filter.discovery_status = "Loading..."
  self:render()

  if self.opts.mode == "edit" and self.opts.conn_id and type(handler.connection_list_schemas_singleflight) == "function" then
    handler:connection_list_schemas_singleflight({
      conn_id = self.opts.conn_id,
      purpose = "wizard",
      consumer = "wizard-schema-discovery",
      caller_token = "wizard",
      callback = function(payload)
        self:_on_schema_discovery(payload)
      end,
    })
    return
  end

  if self.opts.mode == "edit" and self.opts.conn_id and type(handler.connection_list_schemas) == "function" then
    local ok, schemas = pcall(handler.connection_list_schemas, handler, self.opts.conn_id)
    if not ok then
      self:_on_schema_discovery({ error = schemas })
    else
      self:_on_schema_discovery({ schemas = schemas })
    end
    return
  end

  if type(handler.connection_list_schemas_spec_async) ~= "function" then
    self:_on_schema_discovery({ error = "Schema discovery is unavailable for unsaved connections." })
    return
  end

  local spec = deepcopy(submission.params)
  spec.schema_filter = nil
  handler:connection_list_schemas_spec_async(spec, function(payload)
    self:_on_schema_discovery(payload)
  end)
end

function Wizard:activate_selected()
  local entry = self.entries[self.state.selection]
  if not entry then
    return
  end
  if entry.kind == "type" then
    self:edit_type()
  elseif entry.kind == "mode" then
    self:edit_mode()
  elseif entry.kind == "field" then
    self:edit_field(entry.field)
  elseif entry.kind == "schema_include" then
    self:edit_schema_patterns("include_text", "Schema Include")
  elseif entry.kind == "schema_exclude" then
    self:edit_schema_patterns("exclude_text", "Schema Exclude")
  elseif entry.kind == "schema_lazy" then
    self:toggle_lazy_schema()
  elseif entry.kind == "schema_discover" then
    self:discover_schemas()
  elseif entry.kind == "schema_clear" then
    self:clear_schema_filter()
  elseif entry.kind == "test" then
    self:test_connection()
  elseif entry.kind == "submit" then
    self:submit()
  elseif entry.kind == "cancel" then
    self:cancel()
  end
end

function Wizard:mount()
  if self.mounted then
    return self
  end

  self.popup:mount()
  self.mounted = true
  vim.bo[self.popup.bufnr].bufhidden = "wipe"
  vim.bo[self.popup.bufnr].filetype = "dbee"

  local map_opts = { noremap = true, nowait = true }
  self.popup:map("n", "j", function()
    self:move(1)
  end, map_opts)
  self.popup:map("n", "k", function()
    self:move(-1)
  end, map_opts)
  self.popup:map("n", "<Tab>", function()
    self:move(1)
  end, map_opts)
  self.popup:map("n", "<S-Tab>", function()
    self:move(-1)
  end, map_opts)
  self.popup:map("n", "<Down>", function()
    self:move(1)
  end, map_opts)
  self.popup:map("n", "<Up>", function()
    self:move(-1)
  end, map_opts)
  self.popup:map("n", "<CR>", function()
    self:activate_selected()
  end, map_opts)
  self.popup:map("n", "q", function()
    self:cancel()
  end, map_opts)
  self.popup:map("n", "<Esc>", function()
    self:cancel()
  end, map_opts)

  self:render()
  self:_sync_cursor()
  return self
end

---@param opts { relative_winid?: integer, mode?: '"add"'|'"edit"', title?: string, source_meta?: table, seed?: ConnectionWizardSeed, on_submit?: fun(submission: ConnectionWizardSubmission), on_cancel?: fun() }
---@return table
function M.open(opts)
  opts = opts or {}
  local wizard = Wizard:new(opts)
  return wizard:mount()
end

M._TYPE_OPTIONS = TYPE_OPTIONS
M._MODE_OPTIONS = MODE_OPTIONS
M._FIELD_DEFS = FIELD_DEFS
M._parse_wallet_aliases = parse_wallet_aliases
M._read_wallet_tnsnames = read_wallet_tnsnames
M._validate = validate_submission
M._serialize = serialize_submission
M._normalize_seed = normalize_seed
M._render_postgres_form_url = render_postgres_form_url
M._parse_postgres_url = parse_postgres_url

return M
