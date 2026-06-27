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
  local errf = os.tmpname()
  -- -sS: silent progress but still print transport errors (to stderr).
  -- --http1.1: avoid curl exit 92 (HTTP/2 PROTOCOL_ERROR) when the server or an
  -- intermediate proxy resets the HTTP/2 stream on long-running requests.
  local cmd = "curl -sS --http1.1 -w '\\n%{http_code}' --max-time " .. (options.timeout or 60)
    .. " -X POST " .. esc(url)
    .. " -H 'Content-Type: application/json'"
    .. " -d @" .. esc(tmpf)
  if self._config.api_key and #self._config.api_key > 0 then
    cmd = cmd .. " -H " .. esc("Authorization: Bearer " .. self._config.api_key)
  end

  -- Capture curl's stderr in a file and its exit code via a trailing stdout
  -- marker: Lua 5.1's popen:close() does not return the child exit status.
  local pf = io.popen(cmd .. " 2>" .. esc(errf) .. "; printf '\\n__CURL_EXIT__%s' \"$?\"")
  if not pf then
    os.remove(tmpf)
    os.remove(errf)
    return nil, "curl execution failed"
  end
  local output = pf:read("*a") or ""
  pf:close()
  os.remove(tmpf)

  local curl_exit = output:match("__CURL_EXIT__(%d+)%s*$")
  output = output:gsub("\n?__CURL_EXIT__%d+%s*$", "")
  local curl_err = ""
  local ef = io.open(errf, "r")
  if ef then curl_err = (ef:read("*a") or ""):gsub("%s+$", ""); ef:close() end
  os.remove(errf)

  local function _curl_detail()
    local d = "curl exit " .. tostring(curl_exit)
    if curl_err ~= "" then d = d .. ": " .. curl_err end
    return d
  end

  if #output == 0 then
    return nil, "empty response from API (" .. _curl_detail() .. ")"
  end

  local lines = {}
  for line in output:gmatch("[^\n]+") do lines[#lines + 1] = line end
  local http_code = tonumber(lines[#lines])
  local raw = table.concat(lines, "\n", 1, #lines - 1)

  -- A non-zero curl exit means the transfer failed even if a status line was
  -- already received: a timeout (exit 28) can yield "HTTP 200" with a truncated
  -- or empty body. http_code 0 (and no body) means no transaction completed at
  -- all: connection reset (56), empty reply (52), TLS error (35), connect (7).
  if (curl_exit and curl_exit ~= "0") or not http_code or http_code == 0 then
    return nil, "request failed (HTTP " .. tostring(http_code) .. ", " .. _curl_detail() .. ")"
  end

  local success, parsed = pcall(json.decode, raw)
  if not success or not parsed then
    local detail = tostring(parsed or "")
    if not success then
      detail = detail .. " | body: " .. raw:sub(1, 300)
    end
    return nil, "failed to parse response (HTTP " .. http_code .. ", " .. _curl_detail() .. "): " .. detail
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
    -- Literal wire bytes, surfaced only for the --show-tools-json debug view.
    raw_body = self._config.show_tools_json and raw or nil,
  }
end

return HttpProvider
