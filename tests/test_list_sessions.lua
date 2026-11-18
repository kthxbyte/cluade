-- Store.list_sessions surfaces a title (stored, else a first-user-message
-- snippet) and skips empty (0-msg) sessions.

package.path = "./?.lua;./?/init.lua;" .. package.path
local Store = require("store")
local json = require("vendor.json")

local fail = 0
local function ok(cond, msg)
  if cond then print("  ok  - " .. msg) else print("  FAIL- " .. msg); fail = fail + 1 end
end

local dir = os.tmpname(); os.remove(dir); os.execute("mkdir -p '" .. dir .. "'")
local function write(name, tbl)
  local f = io.open(dir .. "/" .. name, "w"); f:write(json.encode(tbl)); f:close()
end

write("titled.json", { cwd = "/x", created = "t", title = "Saved Title",
  messages = { { role = "user", content = "whatever" }, { role = "assistant", content = "ok" } } })
write("untitled.json", { cwd = "/x", created = "t",
  messages = { { role = "user", content = "hello world" }, { role = "assistant", content = "ok" } } })
write("empty.json", { cwd = "/x", created = "t", messages = {} })

local rows = Store.list_sessions(dir)
local function title_present(t) for _, r in ipairs(rows) do if r.title == t then return true end end return false end

ok(#rows == 2, "0-msg session skipped (got " .. #rows .. " rows)")
ok(title_present("Saved Title"), "stored title surfaced")
ok(title_present("hello world"), "untitled-with-content gets a first-message snippet")

os.execute("rm -rf '" .. dir .. "'")
if fail == 0 then print("\nALL PASS") else print("\n" .. fail .. " FAILED"); os.exit(1) end
