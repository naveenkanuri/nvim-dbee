local Popup = require("nui.popup")

local menu = require("dbee.ui.drawer.menu")
local utils = require("dbee.utils")

local uv = vim.loop

local M = {}

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

local function deepcopy(value)
  return vim.deepcopy(value)
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

local function parse_wallet_aliases(contents)
  local aliases = {}
  local seen = {}

  for line in (contents .. "\n"):gmatch("([^\n]*)\n") do
    local trimmed = vim.trim(line)
    if trimmed ~= "" and not vim.startswith(trimmed, "#") and not vim.startswith(trimmed, "!") then
      local first = trimmed:sub(1, 1)
      if first ~= "(" then
        local alias_group = trimmed:match("^([^=]+)%s*=")
        if alias_group then
          for alias in alias_group:gmatch("[^,%s]+") do
            if alias ~= "" and not seen[alias] then
              seen[alias] = true
              aliases[#aliases + 1] = alias
            end
          end
        end
      end
    end
  end

  table.sort(aliases)
  return aliases
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

local function refresh_wallet_alias_state(state)
  state.wallet_aliases = {}
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

  local aliases = parse_wallet_aliases(contents)
  state.wallet_aliases = aliases
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

local function seed_state(seed)
  seed = seed or {}
  local params = deepcopy(seed.params or {})
  local wizard = deepcopy(seed.wizard or {})

  local mode = wizard.mode
  if not mode then
    if params.type == "oracle" then
      mode = "oracle_custom_jdbc"
    elseif params.type == "postgres" then
      mode = "postgres_url"
    else
      mode = "other_raw"
    end
  end

  local state = {
    db_kind = wizard.db_kind or mode_db_kind(mode),
    mode = mode,
    fields = {},
    selection = 1,
    wallet_aliases = {},
    wallet_alias_warning = nil,
    last_error = nil,
  }

  for known_mode in pairs(FIELD_DEFS) do
    ensure_mode_fields(state, known_mode)
  end

  if type(wizard.fields) == "table" then
    state.fields[mode] = vim.tbl_extend("force", state.fields[mode], deepcopy(wizard.fields))
  end

  if params.name and state.fields[mode].name == nil then
    state.fields[mode].name = params.name
  end
  if params.type and state.fields.other_raw.type == nil then
    state.fields.other_raw.type = params.type
  end
  if params.url and state.fields.other_raw.url == nil then
    state.fields.other_raw.url = params.url
  end
  if params.url and state.fields.postgres_url.url == nil then
    state.fields.postgres_url.url = params.url
  end
  if params.url and state.fields.oracle_custom_jdbc.descriptor == nil then
    state.fields.oracle_custom_jdbc.descriptor = params.url
  end

  refresh_wallet_alias_state(state)
  return state
end

local Wizard = {}
Wizard.__index = Wizard

local function popup_options(opts)
  local width = 72
  local height = 18
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
  }
end

function Wizard:new(opts)
  local popup = Popup(popup_options(opts))
  local instance = setmetatable({
    opts = opts,
    popup = popup,
    state = seed_state(opts.seed),
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
  self.state.mode = mode
  self.state.db_kind = mode_db_kind(mode)
  local target_fields = ensure_mode_fields(self.state, mode)
  copy_shared_fields(previous_fields, target_fields)
  refresh_wallet_alias_state(self.state)
  self.state.selection = 1
  self:render()
end

function Wizard:set_db_kind(db_kind)
  local previous_fields = deepcopy(self:current_fields())
  self.state.db_kind = db_kind
  local next_mode = first_mode_for_db_kind(db_kind)
  self.state.mode = next_mode
  local target_fields = ensure_mode_fields(self.state, next_mode)
  copy_shared_fields(previous_fields, target_fields)
  refresh_wallet_alias_state(self.state)
  self.state.selection = 1
  self:render()
end

function Wizard:set_field(field_key, value)
  local fields = self:current_fields()
  fields[field_key] = value
  if self.state.mode == "oracle_cloud_wallet" and field_key == "wallet_path" then
    refresh_wallet_alias_state(self.state)
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
  end

  add_entry({ kind = "type" }, string.format("Type: %s", display_type_label(self.state.db_kind)))
  add_entry({ kind = "mode" }, string.format("Mode: %s", display_mode_label(self.state.mode)))
  lines[#lines + 1] = ""

  for _, field in ipairs(FIELD_DEFS[self.state.mode] or {}) do
    add_entry({ kind = "field", field = field }, string.format("%s: %s", field.label, self:format_field_value(field)))
  end

  lines[#lines + 1] = ""
  add_entry({ kind = "submit" }, "Submit")
  add_entry({ kind = "cancel" }, "Cancel")

  if self.state.wallet_alias_warning then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Warning: " .. self.state.wallet_alias_warning
  end
  if self.state.last_error then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Error: " .. self.state.last_error
  end

  vim.bo[self.popup.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(self.popup.bufnr, 0, -1, false, lines)
  vim.bo[self.popup.bufnr].modifiable = false
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
  if self.opts.on_submit then
    self.opts.on_submit({
      params = {},
      wizard = {
        db_kind = self.state.db_kind,
        mode = self.state.mode,
        fields = deepcopy(self:current_fields()),
      },
    })
  end
  self:close()
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
    mappings = {},
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
    mappings = {},
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
      mappings = {},
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
  if field.kind == "multiline" then
    title = field.label .. " (multiline)"
  end

  if field.kind == "select" and field.options then
    menu.select({
      relative_winid = self.popup.winid,
      title = title,
      items = field.options,
      mappings = {},
      on_confirm = function(selection)
        self:set_field(target_key, selection)
      end,
      on_yank = function() end,
    })
    return
  end

  menu.input({
    relative_winid = self.popup.winid,
    title = title,
    default_value = current_value,
    mappings = {},
    on_confirm = function(value)
      self:set_field(target_key, value)
    end,
  })
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

return M
