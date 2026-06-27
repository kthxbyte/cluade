-- Tests for lineedit rendering. Focused on the paste-duplication root cause:
-- the renderer must NOT use absolute cursor save/restore (ESC[s / ESC[u), must
-- repaint the prompt from a stable column-0 reference, and must move the cursor
-- with row-relative motion that survives scrolling.

package.path = "./?.lua;" .. package.path
local le = require("lineedit")
local r = le._render

local fail = 0
local function ok(cond, msg)
  if cond then print("  ok  - " .. msg)
  else print("  FAIL- " .. msg); fail = fail + 1 end
end

-- 1. No absolute-anchor sequences anywhere in a render.
local out = r("> ", 2, "hello world", 11, 80, 0)
ok(not out:find("\27%[u"), "render emits no ESC[u (absolute restore)")
ok(not out:find("\27%[s"), "render emits no ESC[s (absolute save)")
ok(out:find("\27%[J", 1), "render clears to end of screen (ESC[J)")
ok(out:find("> hello world", 1, true), "render repaints prompt + line")

-- 2. Short, non-wrapping line: cursor ends on row 0, column = pw+pos.
local out2, row2 = r("> ", 2, "hello", 5, 80, 0)
ok(row2 == 0, "short line stays on row 0")
ok(out2:find("\27%[7C$"), "short line places cursor at column 7 (2+5)")

-- 3. Wrapping line, cursor at end: width 10, prompt 2, 20-char line.
--    abs_end = 22 -> end_row 2, target_row 2 (no up move), col 2.
local out3, row3 = r("> ", 2, string.rep("x", 20), 20, 10, 0)
ok(row3 == 2, "wrapping line cursor on row 2")
ok(not out3:find("\27%[%d+A"), "cursor at end needs no up-move")
ok(out3:find("\27%[2C$"), "wrapping line cursor at column 2")

-- 4. Wrapping line, cursor in the middle: pos 5 -> target_row 0, must move UP
--    from end_row 2 by 2 rows, then to column 7.
local out4, row4 = r("> ", 2, string.rep("x", 20), 5, 10, 0)
ok(out4:find("\27%[2A"), "mid-line cursor moves up 2 rows")
ok(out4:find("\27%[7C$"), "mid-line cursor at column 7")
ok(row4 == 0, "mid-line cursor reported on row 0")

-- 5. Uses prev_row to climb back before repainting (scroll-safe anchor).
local out5 = r("> ", 2, "x", 1, 80, 3)
ok(out5:find("^\27%[3A"), "starts by moving up prev_row (3) rows")

-- 6. Exact row-boundary wrap: pw+#line == term_w forces an extra newline so the
--    terminal's deferred wrap matches our math.
local out6, row6 = r("> ", 2, string.rep("x", 8), 8, 10, 0)
ok(out6:find("> " .. string.rep("x", 8) .. "\r\n", 1, true), "boundary line forces ESC newline")
ok(row6 == 1, "boundary line cursor on row 1")

-- 7. End-to-end: a raw (non-bracketed) paste of N chars must yield the buffer
--    exactly once, and must never emit the broken absolute-anchor sequences.
local pasted = "version 2 is what we should backport."
local feed = pasted .. "\r"
local i = 0
local fake_stdin = { read = function(_, _) i = i + 1; return (i <= #feed) and feed:sub(i, i) or nil end }
local captured = {}
local real_write, real_flush, real_stdin = io.write, io.flush, io.stdin
io.write = function(...) for _, s in ipairs({ ... }) do captured[#captured + 1] = tostring(s) end end
io.flush = function() end
io.stdin = fake_stdin
le._set_tty(true)
local line = le.readline("> ")
io.write, io.flush, io.stdin = real_write, real_flush, real_stdin
local emitted = table.concat(captured)
ok(line == pasted, "paste returns buffer exactly once (" .. tostring(line and #line) .. " chars)")
ok(select(2, line:gsub(pasted, "")) == 1, "buffer contains the text exactly once, not duplicated")
ok(not emitted:find("\27%[u"), "e2e: no ESC[u emitted during paste")
ok(not emitted:find("\27%[s"), "e2e: no ESC[s emitted during paste")

-- 8. Width detection returns a sane positive number (never 0/nil that would
--    make the redraw math divide the line into bogus rows).
local cols = le._term_cols()
ok(type(cols) == "number" and cols > 0, "_term_cols returns a positive width (" .. tostring(cols) .. ")")

if fail == 0 then print("\nALL PASS") else print("\n" .. fail .. " FAILED"); os.exit(1) end
