local M = {}

-- NOTE:
-- Oracle variable support uses:
--   - backend named binds for :bind variables
--   - client-side text substitution for &substitution variables

---@class dbee.VariableToken
---@field key string
---@field kind "bind"|"substitution"
---@field name string
---@field token string

---@param adapter_type? string
---@return boolean
local function is_oracle(adapter_type)
  return (adapter_type or ""):lower() == "oracle"
end

---@param kind "bind"|"substitution"
---@param name string
---@return string
local function token_key(kind, name)
  return kind .. ":" .. name
end

---@param opts table
---@param on_confirm fun(value?: string)
---@return boolean
local function open_input_prompt(opts, on_confirm)
  if vim.ui and type(vim.ui.input) == "function" then
    vim.ui.input(opts, on_confirm)
    return true
  end

  local ok_snacks, snacks_input = pcall(require, "snacks.input")
  if not ok_snacks or snacks_input == nil then
    return false
  end

  if type(snacks_input) == "table" and type(snacks_input.input) == "function" then
    snacks_input.input(opts, on_confirm)
    return true
  end

  local ok_call = pcall(function()
    ---@diagnostic disable-next-line: redundant-parameter
    snacks_input(opts, on_confirm)
  end)
  return ok_call
end

---@param text string
---@param start_index integer
---@return string|nil name
---@return integer|nil end_index
local function read_identifier(text, start_index)
  -- Intentionally requires an alphabetic/underscore first char.
  -- Positional binds like :1/:2 are currently unsupported.
  local first = text:sub(start_index, start_index)
  if first == "" or not first:match("[A-Za-z_]") then
    return nil, nil
  end

  local j = start_index + 1
  while j <= #text and text:sub(j, j):match("[%w_$#]") do
    j = j + 1
  end

  return text:sub(start_index, j - 1), j - 1
end

---@param text string
---@param on_token fun(kind: "bind"|"substitution", name: string, start_idx: integer, end_idx: integer, token: string)
local function scan_tokens(text, on_token)
  local i = 1
  local n = #text
  local in_single = false
  local in_double = false
  local in_line_comment = false
  local block_comment_depth = 0

  while i <= n do
    local ch = text:sub(i, i)
    local next_ch = (i < n) and text:sub(i + 1, i + 1) or ""

    if in_line_comment then
      if ch == "\n" then
        in_line_comment = false
      end
      i = i + 1
      goto continue
    end

    if block_comment_depth > 0 then
      if ch == "/" and next_ch == "*" then
        block_comment_depth = block_comment_depth + 1
        i = i + 2
      elseif ch == "*" and next_ch == "/" then
        block_comment_depth = block_comment_depth - 1
        i = i + 2
      else
        i = i + 1
      end
      goto continue
    end

    -- Oracle '&' variables are SQL*Plus-style textual substitutions.
    -- They may appear inside single-quoted literals, so we intentionally
    -- scan for '&' before single-quote handling.
    if ch == "&" and not in_double then
      local prefix_len = 1
      if next_ch == "&" then
        prefix_len = 2
      end
      local name, end_idx = read_identifier(text, i + prefix_len)
      if name then
        on_token("substitution", name, i, end_idx, text:sub(i, end_idx))
        i = end_idx + 1
        goto continue
      end
    end

    if in_single then
      if ch == "'" then
        if next_ch == "'" then
          i = i + 2
        else
          in_single = false
          i = i + 1
        end
      else
        i = i + 1
      end
      goto continue
    end

    if in_double then
      if ch == '"' then
        if next_ch == '"' then
          i = i + 2
        else
          in_double = false
          i = i + 1
        end
      else
        i = i + 1
      end
      goto continue
    end

    if ch == "-" and next_ch == "-" then
      in_line_comment = true
      i = i + 2
      goto continue
    end

    if ch == "/" and next_ch == "*" then
      block_comment_depth = 1
      i = i + 2
      goto continue
    end

    if ch == "'" then
      in_single = true
      i = i + 1
      goto continue
    end

    if ch == '"' then
      in_double = true
      i = i + 1
      goto continue
    end

    if ch == ":" then
      local prev_ch = (i > 1) and text:sub(i - 1, i - 1) or ""
      if prev_ch ~= ":" then
        local name, end_idx = read_identifier(text, i + 1)
        if name then
          -- Skip Oracle trigger pseudo-record fields (:NEW.col / :OLD.col).
          -- Treating these as bind variables corrupts trigger definitions.
          local upper = name:upper()
          if upper == "NEW" or upper == "OLD" then
            local k = end_idx + 1
            while k <= n and text:sub(k, k):match("%s") do
              k = k + 1
            end
            if text:sub(k, k) == "." then
              i = end_idx + 1
              goto continue
            end
          end
          on_token("bind", name, i, end_idx, text:sub(i, end_idx))
          i = end_idx + 1
          goto continue
        end
      end
    end

    i = i + 1
    ::continue::
  end
end

---@param query string
---@param opts? { adapter_type?: string }
---@return dbee.VariableToken[]
function M.collect(query, opts)
  query = tostring(query or "")
  opts = opts or {}

  if not is_oracle(opts.adapter_type) then
    return {}
  end

  local tokens = {}
  local seen = {}
  scan_tokens(query, function(kind, name, _, _, token)
    local key = token_key(kind, name)
    if seen[key] then
      return
    end
    seen[key] = true
    tokens[#tokens + 1] = {
      key = key,
      kind = kind,
      name = name,
      token = token,
    }
  end)
  return tokens
end

---@param variable dbee.VariableToken
---@param timeout_ms integer
---@return string|nil value
---@return string|nil err
local function prompt_variable_value(variable, timeout_ms)
  local done = false
  local value = nil
  local err = nil
  local prompt = variable.kind == "bind"
      and ("Bind :" .. variable.name .. ": ")
    or ("Substitute &" .. variable.name .. ": ")

  local function on_confirm(input)
    value = input
    done = true
  end

  -- Open prompt on next loop tick so we are not in a keymap/action callback stack.
  -- Using vim.ui.input allows snacks.nvim to provide floating input when configured.
  vim.schedule(function()
    if open_input_prompt({
      prompt = prompt,
      default = "",
    }, on_confirm) then
      return
    end

    err = "variable input UI is unavailable"
    done = true
  end)

  local ok_wait = vim.wait(timeout_ms, function()
    return done
  end, 20)
  if not ok_wait then
    err = "variable input timed out"
  elseif value == nil then
    err = "variable input canceled"
  elseif value == "" then
    err = "variable input empty"
  end
  if err then
    return nil, err
  end

  return tostring(value), nil
end

---@param query string
---@param values table<string, string>
---@return string
local function apply_values(query, values)
  local replacements = {}
  scan_tokens(query, function(kind, name, start_idx, end_idx)
    local key = token_key(kind, name)
    local replacement = values[key]
    if replacement ~= nil then
      replacements[#replacements + 1] = {
        start_idx = start_idx,
        end_idx = end_idx,
        value = replacement,
      }
    end
  end)

  if #replacements == 0 then
    return query
  end

  local out = {}
  local cursor = 1
  for _, r in ipairs(replacements) do
    out[#out + 1] = query:sub(cursor, r.start_idx - 1)
    out[#out + 1] = r.value
    cursor = r.end_idx + 1
  end
  out[#out + 1] = query:sub(cursor)

  return table.concat(out)
end

---@param provided table<string, any>
---@param token dbee.VariableToken
---@return string|nil
local function get_provided_value(provided, token)
  local value = provided[token.key]
  if value == nil then
    value = provided[token.token]
  end
  if value == nil then
    value = provided[token.name]
  end
  if value == nil then
    return nil
  end
  return tostring(value)
end

---@param tokens dbee.VariableToken[]
---@param resolved_values table<string, string>
---@return table<string, string> substitution_values
---@return table<string, string> bind_values
local function split_resolved_values(tokens, resolved_values)
  local substitution_values = {}
  local bind_values = {}
  for _, token in ipairs(tokens) do
    local value = resolved_values[token.key]
    if value ~= nil then
      if token.kind == "substitution" then
        substitution_values[token.key] = value
      elseif token.kind == "bind" then
        bind_values[token.name] = value
      end
    end
  end
  return substitution_values, bind_values
end

---@param value string
---@return string|nil
local function unsafe_script_delimiter(value)
  if value:find(";", 1, true) ~= nil then
    return "semicolon"
  end
  if value:find("\n", 1, true) ~= nil or value:find("\r", 1, true) ~= nil then
    return "newline"
  end
  return nil
end

---@param tokens dbee.VariableToken[]
---@param resolved_values table<string, string>
---@return string|nil
local function validate_script_substitution_values(tokens, resolved_values)
  for _, token in ipairs(tokens) do
    if token.kind == "substitution" then
      local value = resolved_values[token.key]
      if value ~= nil then
        local delimiter = unsafe_script_delimiter(value)
        if delimiter ~= nil then
          return string.format(
            "unsafe substitution value for &%s: %s detected; use bind variables (:name) for script execution",
            token.name,
            delimiter
          )
        end
      end
    end
  end
  return nil
end

---@param variable dbee.VariableToken
---@param on_done fun(value: string|nil, err: string|nil)
local function prompt_variable_value_async(variable, on_done)
  local prompt = variable.kind == "bind"
      and ("Bind :" .. variable.name .. ": ")
    or ("Substitute &" .. variable.name .. ": ")

  local function handle_input(input)
    if input == nil then
      on_done(nil, "variable input canceled")
      return
    end
    if input == "" then
      on_done(nil, "variable input empty")
      return
    end
    on_done(tostring(input), nil)
  end

  vim.schedule(function()
    if open_input_prompt({
      prompt = prompt,
      default = "",
    }, handle_input) then
      return
    end

    on_done(nil, "variable input UI is unavailable")
  end)
end

---@param query string
---@param opts? { adapter_type?: string, values?: table<string, string>, prompt_async_fn?: fun(variable: dbee.VariableToken, on_done: fun(value: string|nil, err: string|nil)) }
---@param on_done fun(resolved: string|nil, err: string|nil)
function M.resolve_async(query, opts, on_done)
  query = tostring(query or "")
  opts = opts or {}

  if not is_oracle(opts.adapter_type) then
    on_done(query, nil)
    return
  end

  local tokens = M.collect(query, opts)
  if #tokens == 0 then
    on_done(query, nil)
    return
  end

  local provided = opts.values or {}
  local resolved_values = {}
  local prompt_async_fn = opts.prompt_async_fn or prompt_variable_value_async

  local function step(index)
    if index > #tokens then
      on_done(apply_values(query, resolved_values), nil)
      return
    end

    local token = tokens[index]
    local preset = get_provided_value(provided, token)
    if preset ~= nil then
      resolved_values[token.key] = preset
      step(index + 1)
      return
    end

    prompt_async_fn(token, function(value, err)
      if err then
        on_done(nil, err)
        return
      end
      if value == nil then
        on_done(nil, "variable input canceled")
        return
      end
      if value == "" then
        on_done(nil, "variable input empty")
        return
      end
      resolved_values[token.key] = tostring(value)
      step(index + 1)
    end)
  end

  step(1)
end

---@param query string
---@param opts? { adapter_type?: string, values?: table<string, string>, prompt_async_fn?: fun(variable: dbee.VariableToken, on_done: fun(value: string|nil, err: string|nil)), reject_script_delimiters?: boolean }
---@param on_done fun(resolved_query: string|nil, exec_opts: QueryExecuteOpts|nil, err: string|nil)
function M.resolve_for_execute_async(query, opts, on_done)
  query = tostring(query or "")
  opts = opts or {}

  if not is_oracle(opts.adapter_type) then
    on_done(query, nil, nil)
    return
  end

  local tokens = M.collect(query, opts)
  if #tokens == 0 then
    on_done(query, nil, nil)
    return
  end

  local provided = opts.values or {}
  local resolved_values = {}
  local prompt_async_fn = opts.prompt_async_fn or prompt_variable_value_async

  local function step(index)
    if index > #tokens then
      if opts.reject_script_delimiters then
        local validate_err = validate_script_substitution_values(tokens, resolved_values)
        if validate_err then
          on_done(nil, nil, validate_err)
          return
        end
      end
      local substitution_values, bind_values = split_resolved_values(tokens, resolved_values)
      local resolved_query = apply_values(query, substitution_values)
      if next(bind_values) ~= nil then
        on_done(resolved_query, { binds = bind_values }, nil)
      else
        on_done(resolved_query, nil, nil)
      end
      return
    end

    local token = tokens[index]
    local preset = get_provided_value(provided, token)
    if preset ~= nil then
      resolved_values[token.key] = preset
      step(index + 1)
      return
    end

    prompt_async_fn(token, function(value, err)
      if err then
        on_done(nil, nil, err)
        return
      end
      if value == nil then
        on_done(nil, nil, "variable input canceled")
        return
      end
      if value == "" then
        on_done(nil, nil, "variable input empty")
        return
      end
      resolved_values[token.key] = tostring(value)
      step(index + 1)
    end)
  end

  step(1)
end

---@param query string
---@param opts? { adapter_type?: string, values?: table<string, string>, prompt_fn?: fun(variable: dbee.VariableToken): (string|nil), (string|nil), timeout_ms?: integer }
---@return string|nil resolved
---@return string|nil err
function M.resolve(query, opts)
  query = tostring(query or "")
  opts = opts or {}

  if not is_oracle(opts.adapter_type) then
    return query, nil
  end

  local tokens = M.collect(query, opts)
  if #tokens == 0 then
    return query, nil
  end

  local provided = opts.values or {}
  local resolved_values = {}
  local prompt_fn = opts.prompt_fn or function(variable)
    return prompt_variable_value(variable, tonumber(opts.timeout_ms) or (5 * 60 * 1000))
  end

  for _, token in ipairs(tokens) do
    local value = get_provided_value(provided, token)
    if value == nil then
      local prompted, prompt_err = prompt_fn(token)
      if prompt_err then
        return nil, prompt_err
      end
      if prompted == nil then
        return nil, "variable input canceled"
      end
      if prompted == "" then
        return nil, "variable input empty"
      end
      value = prompted
    end
    resolved_values[token.key] = tostring(value)
  end

  return apply_values(query, resolved_values), nil
end

---@param query string
---@param opts? { adapter_type?: string, values?: table<string, string>, prompt_fn?: fun(variable: dbee.VariableToken): (string|nil), (string|nil), timeout_ms?: integer, reject_script_delimiters?: boolean }
---@return string|nil resolved_query
---@return QueryExecuteOpts|nil exec_opts
---@return string|nil err
function M.resolve_for_execute(query, opts)
  query = tostring(query or "")
  opts = opts or {}

  if not is_oracle(opts.adapter_type) then
    return query, nil, nil
  end

  local tokens = M.collect(query, opts)
  if #tokens == 0 then
    return query, nil, nil
  end

  local provided = opts.values or {}
  local resolved_values = {}
  local prompt_fn = opts.prompt_fn or function(variable)
    return prompt_variable_value(variable, tonumber(opts.timeout_ms) or (5 * 60 * 1000))
  end

  for _, token in ipairs(tokens) do
    local value = get_provided_value(provided, token)
    if value == nil then
      local prompted, prompt_err = prompt_fn(token)
      if prompt_err then
        return nil, nil, prompt_err
      end
      if prompted == nil then
        return nil, nil, "variable input canceled"
      end
      if prompted == "" then
        return nil, nil, "variable input empty"
      end
      value = prompted
    end
    resolved_values[token.key] = tostring(value)
  end

  if opts.reject_script_delimiters then
    local validate_err = validate_script_substitution_values(tokens, resolved_values)
    if validate_err then
      return nil, nil, validate_err
    end
  end

  local substitution_values, bind_values = split_resolved_values(tokens, resolved_values)
  local resolved_query = apply_values(query, substitution_values)
  if next(bind_values) ~= nil then
    return resolved_query, { binds = bind_values }, nil
  end
  return resolved_query, nil, nil
end

---@param query string
---@param opts? { adapter_type?: string, binds?: table<string, string> }
---@return QueryExecuteOpts|nil
function M.bind_opts_for_query(query, opts)
  query = tostring(query or "")
  opts = opts or {}

  if not is_oracle(opts.adapter_type) then
    return nil
  end
  local all_binds = opts.binds or {}
  if next(all_binds) == nil then
    return nil
  end

  local tokens = M.collect(query, { adapter_type = opts.adapter_type })
  local query_binds = {}
  for _, token in ipairs(tokens) do
    if token.kind == "bind" and all_binds[token.name] ~= nil then
      query_binds[token.name] = tostring(all_binds[token.name])
    end
  end
  if next(query_binds) == nil then
    return nil
  end

  return { binds = query_binds }
end

return M
