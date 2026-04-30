-- Headless render validation for Add Connection wizard text inputs.
--
-- Usage:
-- nvim --headless -u NONE -i NONE -n \
--   --cmd "set rtp^=/path/to/nui.nvim | set rtp+=$(pwd)" \
--   -c "luafile ci/headless/check_wizard_input_visible.lua"

local function fail(msg)
  print("UX13_WIZARD_INPUT_RENDER_VISIBLE=false")
  print("UX13_WIZARD_INPUT_RENDER_FAIL=" .. tostring(msg))
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

local function drain(ms)
  vim.wait(ms or 80, function()
    return false
  end, 5)
end

local function split_winhighlight(value)
  local mappings = {}
  for item in tostring(value or ""):gmatch("[^,]+") do
    local from, to = item:match("^([^:]+):(.+)$")
    if from and to then
      mappings[from] = to
    end
  end
  return mappings
end

local function get_hl(group)
  local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group, link = false })
  if ok and type(hl) == "table" then
    return hl
  end
  return {}
end

local function effective_hl(group, base_hl)
  local hl = get_hl(group)
  return {
    fg = hl.fg or (base_hl and base_hl.fg),
    bg = hl.bg or (base_hl and base_hl.bg),
    ctermfg = hl.ctermfg or (base_hl and base_hl.ctermfg),
    ctermbg = hl.ctermbg or (base_hl and base_hl.ctermbg),
  }
end

local function add_group(groups, group)
  if type(group) == "table" then
    for _, item in ipairs(group) do
      add_group(groups, item)
    end
    return
  end
  if type(group) == "string" and group ~= "" then
    groups[group] = true
  end
end

local function extmark_groups_covering_text(bufnr, text_len)
  local groups = {}
  local extmarks = vim.api.nvim_buf_get_extmarks(bufnr, -1, 0, -1, { details = true })
  for _, extmark in ipairs(extmarks) do
    local row = extmark[2]
    local col = extmark[3]
    local details = extmark[4] or {}
    local end_row = details.end_row or row
    local end_col = details.end_col or col
    local overlaps_typed_line = row == 0 and end_row == 0 and col < text_len and end_col > 0
    if overlaps_typed_line then
      add_group(groups, details.hl_group)
    end
  end
  return groups, extmarks
end

local function assert_visible_group(group, base_hl)
  local hl = effective_hl(group, base_hl)
  if type(hl.fg) ~= "number" then
    fail("typed text group " .. group .. " has no resolved foreground: " .. vim.inspect(hl))
  end
  if type(hl.bg) == "number" and hl.fg == hl.bg then
    fail(string.format("typed text group %s has invisible gui colors fg=%06x bg=%06x", group, hl.fg, hl.bg))
  end
  if type(hl.ctermfg) == "number" and type(hl.ctermbg) == "number" and hl.ctermfg == hl.ctermbg then
    fail(string.format("typed text group %s has invisible cterm colors fg=%s bg=%s", group, hl.ctermfg, hl.ctermbg))
  end
  return hl
end

local function open_wizard_and_type()
  vim.o.termguicolors = true
  vim.o.columns = 120
  vim.o.lines = 40
  pcall(vim.cmd.colorscheme, "default")

  local wizard_mod = require("dbee.ui.connection_wizard")
  local wizard = wizard_mod.open({
    mode = "add",
    title = "Add Connection",
    seed = {
      params = {
        type = "postgres",
        name = "",
        url = "",
      },
      wizard = {
        db_kind = "postgres",
        mode = "postgres_form",
        fields = {
          name = "",
          host = "",
          port = "5432",
          database = "",
          username = "",
          password = "",
          sslmode = "require",
        },
      },
    },
    on_submit = function() end,
  })
  drain()

  local wizard_bufnr = wizard.popup.bufnr
  vim.defer_fn(function()
    vim.fn.feedkeys(vim.api.nvim_replace_termcodes("jj<CR>", true, false, true), "mx")
  end, 20)
  assert_true("text input opened", vim.wait(500, function()
    return vim.api.nvim_get_current_buf() ~= wizard_bufnr
  end, 5))

  local input_bufnr = vim.api.nvim_get_current_buf()
  vim.defer_fn(function()
    vim.fn.feedkeys("ihello", "nx")
  end, 20)
  assert_true("typed text reached prompt buffer", vim.wait(500, function()
    local lines = vim.api.nvim_buf_get_lines(input_bufnr, 0, -1, false)
    return lines[1] == "hello"
  end, 5))

  return wizard, input_bufnr, vim.fn.bufwinid(input_bufnr)
end

local wizard, input_bufnr, input_winid = open_wizard_and_type()
assert_true("input window valid", input_winid > 0 and vim.api.nvim_win_is_valid(input_winid))

local lines = vim.api.nvim_buf_get_lines(input_bufnr, 0, -1, false)
assert_eq("typed prompt line", lines[1], "hello")
assert_eq("prompt prefix", vim.fn.prompt_getprompt(input_bufnr), "")
assert_eq("input buftype", vim.api.nvim_get_option_value("buftype", { buf = input_bufnr }), "prompt")
assert_eq("input syntax", vim.api.nvim_get_option_value("syntax", { buf = input_bufnr }), "")
assert_eq("input conceallevel", vim.api.nvim_get_option_value("conceallevel", { win = input_winid }), 0)
assert_eq("input concealcursor", vim.api.nvim_get_option_value("concealcursor", { win = input_winid }), "")

local winhighlight = vim.api.nvim_get_option_value("winhighlight", { win = input_winid })
local mappings = split_winhighlight(winhighlight)
local base_group = mappings.Normal or "Normal"
local base_hl = get_hl(base_group)
local groups = {
  [base_group] = true,
}
local extmark_groups, extmarks = extmark_groups_covering_text(input_bufnr, #"hello")
for group in pairs(extmark_groups) do
  groups[group] = true
end

local summaries = {}
for group in pairs(groups) do
  local hl = assert_visible_group(group, base_hl)
  summaries[#summaries + 1] = string.format(
    "%s:fg=%s:bg=%s:ctermfg=%s:ctermbg=%s",
    group,
    tostring(hl.fg),
    tostring(hl.bg),
    tostring(hl.ctermfg),
    tostring(hl.ctermbg)
  )
end
table.sort(summaries)

print("UX13_WIZARD_INPUT_LINES=" .. table.concat(lines, "\\n"))
print("UX13_WIZARD_INPUT_EXTMARK_COUNT=" .. tostring(#extmarks))
print("UX13_WIZARD_INPUT_WINHIGHLIGHT=" .. winhighlight)
print("UX13_WIZARD_INPUT_RENDER_GROUPS=" .. table.concat(summaries, ","))
print("UX13_WIZARD_INPUT_CONCEAL_OK=true")
print("UX13_WIZARD_INPUT_RENDER_VISIBLE=true")

pcall(function()
  wizard:close()
end)
vim.cmd("qa!")
