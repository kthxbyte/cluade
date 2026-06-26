-- Loop detection for the agent loop. Watches for two runaway patterns within a
-- single turn and reacts with "warn once, then stop":
--   * the same tool call (name + identical arguments) made repeatedly in a row
--   * tool calls returning errors repeatedly in a row
-- Uses CONSECUTIVE counts so that any change in behavior resets the streak,
-- keeping false positives low. A/B/A/B ping-pong is intentionally not caught.

local LoopDetect = {}
LoopDetect.__index = LoopDetect

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
