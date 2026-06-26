-- Loop detection for the agent loop. Watches for two runaway patterns within a
-- single turn and reacts with "warn once, then stop":
--   * the same tool call (name + identical arguments) made repeatedly in a row
--   * tool calls returning errors repeatedly in a row
-- Uses CONSECUTIVE counts so that any change in behavior resets the streak,
-- keeping false positives low. A/B/A/B ping-pong is intentionally not caught.

local LoopDetect = {}
LoopDetect.__index = LoopDetect

-- Serialize a value to a stable, canonical string so that two argument tables
-- that differ only in key order produce the same text. Object keys are sorted;
-- array order is preserved (it is semantically meaningful). The output is for
-- comparison only -- it need not be valid JSON.
local function canonical(v)
  local t = type(v)
  if t ~= "table" then
    return string.format("%q", tostring(v))
  end
  -- Treat a table with contiguous 1..n integer keys as an array (order kept).
  local n = 0
  for _ in pairs(v) do n = n + 1 end
  if n == #v then
    local parts = {}
    for i = 1, n do parts[i] = canonical(v[i]) end
    return "[" .. table.concat(parts, ",") .. "]"
  end
  -- Otherwise an object: sort keys for order-independence.
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
  local parts = {}
  for _, k in ipairs(keys) do
    parts[#parts + 1] = tostring(k) .. "=" .. canonical(v[k])
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

-- Build a comparison signature for a tool call. `args` may be a decoded table
-- (key order normalized) or a raw string (passed through unchanged, so a call
-- whose arguments failed to parse still keeps its distinct identity).
function LoopDetect.signature(name, args)
  if type(args) == "table" then
    return name .. ":" .. canonical(args)
  end
  return name .. ":" .. tostring(args)
end

function LoopDetect.new(opts)
  opts = opts or {}
  return setmetatable({
    repeat_threshold = opts.repeat_threshold or 3,
    error_threshold = opts.error_threshold or 4,
    last_sig = nil,
    repeat_count = 0,
    error_count = 0,
    warned = false,
  }, LoopDetect)
end

-- Record one tool call's signature (e.g. "name:arguments").
function LoopDetect:record_call(sig)
  if sig == self.last_sig then
    self.repeat_count = self.repeat_count + 1
  else
    self.last_sig = sig
    self.repeat_count = 1
  end
end

-- Record one tool result. is_error is truthy when the call failed.
function LoopDetect:record_result(is_error)
  if is_error then
    self.error_count = self.error_count + 1
  else
    self.error_count = 0
  end
end

function LoopDetect:_reason()
  if self.repeat_count >= self.repeat_threshold then return "repeat" end
  if self.error_count >= self.error_threshold then return "error" end
  return nil
end

-- Evaluate after a step's calls/results have been recorded.
-- Returns: nil | "warn" | "stop", reason
function LoopDetect:check()
  local reason = self:_reason()
  if not reason then
    self.warned = false
    return nil, nil
  end
  if self.warned then
    return "stop", reason
  end
  self.warned = true
  return "warn", reason
end

return LoopDetect
