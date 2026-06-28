-- Tests that json.encode preserves UTF-8 instead of flattening every non-ASCII
-- byte to '?'. json.encode is on cluade's hot path -- it encodes every request
-- body sent to the LLM and every saved session -- so a lossy encoder corrupts
-- non-English text, accented identifiers, emoji, arrows/box-drawing, etc., both
-- outbound to the model and on disk. Raw UTF-8 is valid inside a JSON string,
-- so encode must pass it through losslessly while still escaping control chars.

package.path = "./?.lua;./?/init.lua;" .. package.path
local json = require("vendor.json")

local fail = 0
local function ok(cond, msg)
  if cond then print("  ok  - " .. msg) else print("  FAIL- " .. msg); fail = fail + 1 end
end

-- 1. Lossless round-trip across a range of UTF-8 (arrow, em-dash, accent, emoji, CJK).
do
  local s = "allow \226\134\146 ask \226\128\148 caf\195\169 \240\159\154\128 \230\151\165\230\156\172\232\170\158"
  ok(json.decode(json.encode(s)) == s, "UTF-8 string survives encode->decode unchanged")
end

-- 2. encode must not introduce '?' substitutions for non-ASCII input.
do
  local s = "r\195\169sum\195\169"   -- "résumé"
  ok(not json.encode(s):find("?", 1, true), "encode does not replace non-ASCII with '?'")
end

-- 3. UTF-8 nested in a table round-trips too (the real shape: messages/sessions).
do
  local t = { content = "fix the caf\195\169 \226\134\146 bar", n = 2 }
  local back = json.decode(json.encode(t))
  ok(back.content == t.content and back.n == 2, "UTF-8 inside a table round-trips")
end

-- 4. Control characters, quotes, and backslashes are still escaped correctly.
do
  local s = 'a\tb\n"q"\\z'
  local back = json.decode(json.encode(s))
  ok(back == s, "control chars / quotes / backslash still round-trip")
end

if fail == 0 then print("\nALL PASS") else print("\n" .. fail .. " FAILED"); os.exit(1) end
