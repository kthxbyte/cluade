local json = {}

json.null = {}

local ESCAPES = {
  ['"']  = '\\"',
  ['\\'] = '\\\\',
  ['\b'] = '\\b',
  ['\f'] = '\\f',
  ['\n'] = '\\n',
  ['\r'] = '\\r',
  ['\t'] = '\\t',
}
local ESC_REV = {b='\b', f='\f', n='\n', r='\r', t='\t'}

local function _encode_string(s)
  return '"' .. s:gsub('[%c"\\\127-\255]', function(c)
    local b = string.byte(c)
    if b < 0x20 or b == 0x7f then
      return string.format('\\u%04x', b)
    end
    return ESCAPES[c] or c
  end) .. '"'
end

local function _is_array(t)
  local count, max_key = 0, 0
  for k in pairs(t) do
    count = count + 1
    if type(k) ~= 'number' or k < 1 or math.floor(k) ~= k then
      return false
    end
    if k > max_key then max_key = k end
  end
  if count == 0 then return false end
  return max_key == count
end

local function _encode_value(v)
  if v == json.null then return 'null' end
  local t = type(v)
  if t == 'nil'   then return 'null'
  elseif t == 'boolean' then return v and 'true' or 'false'
  elseif t == 'number' then
    local s = string.format('%.17g', v):gsub('[.]+$', '')
    return s == '-0' and '0' or s
  elseif t == 'string' then
    return _encode_string(v)
  elseif t == 'table' then
    local parts, n = {}, 1
    if _is_array(v) then
      for i = 1, #v do
        parts[n] = _encode_value(v[i]); n = n + 1
      end
      return '[' .. table.concat(parts, ',') .. ']'
    else
      for k, val in pairs(v) do
        parts[n] = _encode_string(tostring(k)) .. ':' .. _encode_value(val)
        n = n + 1
      end
      return '{' .. table.concat(parts, ',') .. '}'
    end
  end
  error('cannot encode type ' .. t)
end

local function _skip_ws(str, i)
  while true do
    local c = str:sub(i, i)
    if c ~= ' ' and c ~= '\t' and c ~= '\n' and c ~= '\r' then break end
    i = i + 1
  end
  return i
end

local function _parse_string(str, i)
  local parts, start = {}, i
  while true do
    local c = str:sub(i, i)
    if c == '' then error('unterminated string at ' .. i) end
    if c == '"' then
      if i > start then table.insert(parts, str:sub(start, i - 1)) end
      return table.concat(parts), i + 1
    elseif c == '\\' then
      if i > start then table.insert(parts, str:sub(start, i - 1)) end
      i = i + 1
      local ec = str:sub(i, i)
      if ec == 'u' then
        local codepoint = tonumber(str:sub(i + 1, i + 4), 16)
        if not codepoint then error('invalid \\u escape at ' .. i) end
        if codepoint < 0x80 then
          table.insert(parts, string.char(codepoint))
        elseif codepoint < 0x800 then
          table.insert(parts, string.char(0xC0 + math.floor(codepoint / 64), 0x80 + codepoint % 64))
        else
          table.insert(parts, string.char(0xE0 + math.floor(codepoint / 4096), 0x80 + math.floor(codepoint / 64) % 64, 0x80 + codepoint % 64))
        end
        i = i + 5; start = i
      else
        table.insert(parts, ESC_REV[ec] or ec)
        i = i + 1; start = i
      end
    else
      i = i + 1
    end
  end
end

local function _parse_number(str, i)
  local j = i
  if str:sub(j, j) == '-' then j = j + 1 end
  while str:sub(j, j):match('%d') do j = j + 1 end
  if str:sub(j, j) == '.' then
    j = j + 1
    while str:sub(j, j):match('%d') do j = j + 1 end
  end
  if str:sub(j, j) == 'e' or str:sub(j, j) == 'E' then
    j = j + 1
    if str:sub(j, j) == '+' or str:sub(j, j) == '-' then j = j + 1 end
    while str:sub(j, j):match('%d') do j = j + 1 end
  end
  return tonumber(str:sub(i, j - 1)), j
end

local _parse_object, _parse_array

local function _parse_value(str, i)
  i = _skip_ws(str, i)
  local c = str:sub(i, i)
  if c == '{' then
    return _parse_object(str, i + 1)
  elseif c == '[' then
    return _parse_array(str, i + 1)
  elseif c == '"' then
    return _parse_string(str, i + 1)
  elseif c == 't' then
    if str:sub(i, i + 3) ~= 'true' then error('expected true at ' .. i) end
    return true, i + 4
  elseif c == 'f' then
    if str:sub(i, i + 4) ~= 'false' then error('expected false at ' .. i) end
    return false, i + 5
  elseif c == 'n' then
    if str:sub(i, i + 3) ~= 'null' then error('expected null at ' .. i) end
    return json.null, i + 4
  else
    return _parse_number(str, i)
  end
end

function _parse_object(str, i)
  local obj = {}
  i = _skip_ws(str, i)
  if str:sub(i, i) == '}' then return obj, i + 1 end
  while true do
    i = _skip_ws(str, i)
    local key; key, i = _parse_string(str, i + 1)
    i = _skip_ws(str, i)
    if str:sub(i, i) ~= ':' then error('expected : at ' .. i) end
    i = i + 1
    local val; val, i = _parse_value(str, i)
    obj[key] = val
    i = _skip_ws(str, i)
    local c = str:sub(i, i)
    if c == '}' then return obj, i + 1 end
    if c ~= ',' then error('expected , or } at ' .. i) end
    i = i + 1
  end
end

function _parse_array(str, i)
  local arr = {}
  local n = 1
  i = _skip_ws(str, i)
  if str:sub(i, i) == ']' then return arr, i + 1 end
  while true do
    local val; val, i = _parse_value(str, i)
    arr[n] = val; n = n + 1
    i = _skip_ws(str, i)
    local c = str:sub(i, i)
    if c == ']' then return arr, i + 1 end
    if c ~= ',' then error('expected , or ] at ' .. i) end
    i = i + 1
  end
end

function json.encode(v)
  return _encode_value(v)
end

function json.decode(str)
  if type(str) ~= 'string' then error('json.decode: expected string') end
  local val, pos = _parse_value(str, 1)
  pos = _skip_ws(str, pos)
  if pos <= #str then
    error('trailing garbage at position ' .. pos)
  end
  return val
end

return json
