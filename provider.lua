local json = require("vendor.json")

local HttpProvider = {}
HttpProvider.__index = HttpProvider

function HttpProvider:new(config)
  local obj = {
    _config = config,
  }
  setmetatable(obj, self)
  return obj
end

function HttpProvider:chat(messages, tools, options)
  options = options or {}
  local body = {
    model = self._config.model,
    messages = messages,
  }
  if tools and #tools > 0 then
    body.tools = tools
    body.tool_choice = "auto"
  end
  if self._config.thinking ~= false then
    body.thinking = { type = "enabled" }
    body.reasoning_effort = self._config.reasoning_effort or "max"
  end
  if options.temperature then body.temperature = options.temperature end
  if options.max_tokens then body.max_tokens = options.max_tokens end

  local url = self._config.base_url:gsub("/+$", "") .. "/chat/completions"
  local body_str = json.encode(body)

  local tmpf = os.tmpname()
  local f = io.open(tmpf, "w")
  if not f then return nil, "cannot create temp file" end
  f:write(body_str)
  f:close()

  local esc = function(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
  local cmd = "curl -s -w '\\n%{http_code}' --max-time " .. (options.timeout or 60)
    .. " -X POST " .. esc(url)
    .. " -H 'Content-Type: application/json'"
    .. " -d @" .. esc(tmpf)
  if self._config.api_key and #self._config.api_key > 0 then
    cmd = cmd .. " -H " .. esc("Authorization: Bearer " .. self._config.api_key)
  end

  local pf = io.popen(cmd .. " 2>&1")
  if not pf then
    os.remove(tmpf)
    return nil, "curl execution failed"
  end
  local output = pf:read("*a")
  pf:close()
  os.remove(tmpf)

  if not output or #output == 0 then
    return nil, "empty response from API"
  end

  local lines = {}
  for line in output:gmatch("[^\n]+") do lines[#lines + 1] = line end
  local http_code = tonumber(lines[#lines])
  local raw = table.concat(lines, "\n", 1, #lines - 1)

  if not http_code then
    return nil, "no HTTP status: " .. output:sub(1, 200)
  end

  local success, parsed = pcall(json.decode, raw)
  if not success or not parsed then
    return nil, "failed to parse response (HTTP " .. http_code .. "): " .. tostring(parsed or raw:sub(1, 200))
  end

  if http_code ~= 200 then
    local err_msg = parsed and parsed.error and parsed.error.message
    return nil, "HTTP " .. tostring(http_code) .. (err_msg and ": " .. err_msg or "")
  end

  local choice = parsed.choices and parsed.choices[1]
  if not choice then
    return nil, "no choices in response"
  end

  return {
    content = choice.message.content,
    reasoning_content = choice.message.reasoning_content,
    tool_calls = choice.message.tool_calls,
    finish_reason = choice.finish_reason,
    usage = parsed.usage,
  }
end

return HttpProvider
