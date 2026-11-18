-- Tests for the `ask` tool executor. The terminal I/O is behind seams
-- (_ask_available / _ask_write / _ask_read) so the choice/multi-select/free-text
-- logic is verified without a real terminal. _ask_read pops from a queued answer
-- list so sequential reads (a selection, then an "Other" follow-up) are
-- deterministic.

package.path = "./?.lua;./?/init.lua;" .. package.path
local Tools = require("tools")

local fail = 0
local function ok(cond, msg)
  if cond then print("  ok  - " .. msg) else print("  FAIL- " .. msg); fail = fail + 1 end
end

-- Seam stubs.
local answers = {}
local last_prompt = nil
Tools._ask_available = function() return true end
Tools._ask_write = function() end
Tools._ask_read = function(p) last_prompt = p; return table.remove(answers, 1) end

local function ask(params) return Tools.execute_ask(".", params) end
local opts3 = { { label = "A" }, { label = "B" }, { label = "C" } }

-- missing question -> error
ok(ask({}).status == "error", "missing question is an error")

-- no controlling terminal -> error, no blocking read
Tools._ask_available = function() return false end
ok(ask({ question = "q", options = opts3 }).status == "error", "no tty -> error")
Tools._ask_available = function() return true end

-- single-select by index
answers = { "2" }
ok(ask({ question = "pick", options = opts3 }).output == "B", "single-select by index")
ok(last_prompt and last_prompt:find("number", 1, true) ~= nil, "single-select prompt asks for a number")

-- options given as bare strings are normalized
answers = { "1" }
ok(ask({ question = "pick", options = { "A", "B" } }).output == "A", "bare-string options normalized")

-- single-select given several numbers -> the first one typed only (3 -> C)
answers = { "3,1" }
ok(ask({ question = "pick", options = opts3 }).output == "C", "single-select takes the first typed index")

-- "Other" (index N+1) -> free-text follow-up
answers = { "4", "custom text" }
ok(ask({ question = "pick", options = opts3 }).output == "custom text", "Other -> free-text follow-up")

-- multi-select joins labels
answers = { "1,3" }
ok(ask({ question = "pick", multiple = true, options = opts3 }).output == "A, C", "multi-select joins labels")

-- multi-select with Other appends typed text
answers = { "2,4", "x" }
ok(ask({ question = "pick", multiple = true, options = opts3 }).output == "B, x", "multi-select + Other")

-- non-numeric input is passed through verbatim: at a choice prompt the user is
-- steering ("none of these, do Z"), not selecting -- their words reach the model.
answers = { "9,foo,2" }
ok(ask({ question = "pick", options = opts3 }).output == "9,foo,2", "mixed/non-numeric input passed through as free text")

answers = { "none of these, do Z instead" }
ok(ask({ question = "pick", options = opts3 }).output == "none of these, do Z instead", "prose answer at a choice prompt is passed through")

-- ambiguous numeric-ish prose is NOT guessed into an index
answers = { "option 2" }
ok(ask({ question = "pick", options = opts3 }).output == "option 2", "'option 2' passed through, not resolved to an index")

-- a pure but out-of-range number -> no valid index -> no answer (model re-asks)
answers = { "9" }
ok(ask({ question = "pick", options = opts3 }).output == "(no answer)", "out-of-range number -> no answer")

-- prose at a multi-select prompt is passed through too
answers = { "skip all, just summarize" }
ok(ask({ question = "pick", multiple = true, options = opts3 }).output == "skip all, just summarize", "prose at a multi-select prompt passed through")

-- Other chosen but left blank -> dropped -> no answer
answers = { "4", "" }
ok(ask({ question = "pick", options = opts3 }).output == "(no answer)", "blank Other dropped -> no answer")

-- free text (no options)
answers = { "hello world" }
ok(ask({ question = "name?" }).output == "hello world", "free-text question")

-- blank answer -> (no answer)
answers = { "" }
ok(ask({ question = "pick", options = { { label = "A" } } }).output == "(no answer)", "blank selection -> no answer")

if fail == 0 then print("\nALL PASS") else print("\n" .. fail .. " FAILED"); os.exit(1) end
