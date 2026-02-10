local M = {}

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

---@param text string
---@param start_index integer
---@return string|nil name
---@return integer|nil end_index
local function read_identifier(text, start_index)
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

  local ok_snacks, snacks_input = pcall(require, "snacks.input")
  if ok_snacks and snacks_input and type(snacks_input.input) == "function" then
    snacks_input.input({
      prompt = prompt,
      default = "",
    }, on_confirm)
  elseif vim.ui and type(vim.ui.input) == "function" then
    vim.ui.input({
      prompt = prompt,
      default = "",
    }, on_confirm)
  else
    return nil, "variable input UI is unavailable"
  end

  local ok_wait = vim.wait(timeout_ms, function()
    return done
  end, 20)
  if not ok_wait then
    err = "variable input timed out"
  elseif value == nil then
    err = "variable input canceled"
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
    local value = provided[token.key]
    if value == nil then
      value = provided[token.token]
    end
    if value == nil then
      value = provided[token.name]
    end
    if value == nil then
      local prompted, prompt_err = prompt_fn(token)
      if prompt_err then
        return nil, prompt_err
      end
      if prompted == nil then
        return nil, "variable input canceled"
      end
      value = prompted
    end
    resolved_values[token.key] = tostring(value)
  end

  return apply_values(query, resolved_values), nil
end

return M
