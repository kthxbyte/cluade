-- load_config must honor DEEPSEEK_API_KEY (DeepSeek is the default provider),
-- the same way it already honors OPENAI_API_KEY/ANTHROPIC_API_KEY. Lua 5.1 has
-- no os.setenv, so each case runs in a subprocess with the env set on the shell.

package.path = "./?.lua;./?/init.lua;" .. package.path
local fail = 0
local function ok(cond, msg)
  if cond then print("  ok  - " .. msg) else print("  FAIL- " .. msg); fail = fail + 1 end
end

-- Run load_config in a child lua and print the resolved api_key. The three
-- provider env vars are scrubbed first (the test shell may have a real one set),
-- so only the key named in `env` is present; HOME/project point at empty dirs.
local function api_key_with(env)
  local empty = os.tmpname(); os.remove(empty); os.execute("mkdir -p '" .. empty .. "'")
  local lua = "package.path='./?.lua;./?/init.lua;'..package.path;"
    .. "io.write(require('store').load_config('" .. empty .. "/proj').api_key or '')"
  local cmd = "env -u OPENAI_API_KEY -u ANTHROPIC_API_KEY -u DEEPSEEK_API_KEY "
    .. "HOME='" .. empty .. "' " .. env .. " lua5.1 -e \"" .. lua .. "\""
  local f = io.popen(cmd); local out = f:read("*a") or ""; f:close()
  os.execute("rm -rf '" .. empty .. "'")
  return out
end

ok(api_key_with("DEEPSEEK_API_KEY='ds-test-123'") == "ds-test-123",
  "DEEPSEEK_API_KEY is picked up when set")
ok(api_key_with("") == "", "no env key -> empty default")

if fail == 0 then print("\nALL PASS") else print("\n" .. fail .. " FAILED"); os.exit(1) end
