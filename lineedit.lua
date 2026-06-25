-- cluade vendor module: line editing with history and basic cursor movement
-- API: init(), readline(prompt), add_history(line)

local lineedit = {}

local is_tty = false
local history = {}
local history_max = 100
local saved_line = nil    -- draft saved when scrolling history

-- ANSI SGR sequence: \27[ digits;semicolons m
local ansi_pat = "\27%[[%d;]*m"

-- Returns visual width of string after stripping ANSI color codes
local function _visual_width(s)
  local stripped = s:gsub(ansi_pat, "")
  -- also strip CSI cursor sequences \27[%d*[A-FHJK]
  stripped = stripped:gsub("\27%[%d*%a", "")
  return #stripped
end

-- Build the byte sequence to repaint the prompt+line and place the cursor at
-- `pos`. All cursor motion is RELATIVE to the cursor's current row, so it
-- survives terminal scrolling. A previous version anchored to an absolute saved
-- position (ESC[s / ESC[u); that broke -- and visibly duplicated the line --
-- as soon as a long (wrapping) paste scrolled the screen and the saved row
-- scrolled away.
--
-- prev_row: row offset (>=0) the cursor currently sits on, below the first row
-- of the input. Returns the output string and the cursor's new row offset.
local function _render(prompt, pw, line, pos, term_w, prev_row)
  local out = {}
  -- 1. Return to column 0 of the first input row, relative to where we are now.
  if prev_row > 0 then out[#out + 1] = "\27[" .. prev_row .. "A" end
  out[#out + 1] = "\r"
  -- 2. Clear the old prompt/line and any wrapped rows below it.
  out[#out + 1] = "\27[J"
  -- 3. Repaint prompt and line from the stable column-0 reference.
  out[#out + 1] = prompt
  out[#out + 1] = line

  local abs_end = pw + #line
  -- 4. If the line ends exactly on a row boundary the terminal defers the wrap;
  --    force the next row so our row math matches what the terminal actually did.
  if #line > 0 and abs_end % term_w == 0 then
    out[#out + 1] = "\r\n"
  end

  -- 5. Move the cursor from the line end up/across to `pos`.
  local end_row = math.floor(abs_end / term_w)
  local abs_target = pw + pos
  local target_row = math.floor(abs_target / term_w)
  local target_col = abs_target % term_w
  if end_row > target_row then
    out[#out + 1] = "\27[" .. (end_row - target_row) .. "A"
  end
  out[#out + 1] = "\r"
  if target_col > 0 then
    out[#out + 1] = "\27[" .. target_col .. "C"
  end

  return table.concat(out), target_row
end

-- Read the rest of a CSI escape sequence (after \27[)
local function _read_csi()
  local buf = ""
  local ch = io.stdin:read(1)
  if not ch then return "", "" end
  while ch and ch:match("[%d;]") do
    buf = buf .. ch
    ch = io.stdin:read(1)
  end
  return buf, ch or ""
end

function lineedit.init()
  is_tty = (os.execute("test -t 0 2>/dev/null") == 0)
  return is_tty
end

function lineedit.readline(prompt)
  if not is_tty then
    io.write(prompt)
    io.flush()
    return io.read("*l")
  end

  saved_line = nil   -- clear stale draft from previous readline call
  io.write(prompt)
  io.write("\27[?25h")   -- ensure cursor is visible
  io.write("\27[?2004h") -- enable bracketed paste mode
  local line = ""
  local pos = 0
  local hist_idx = nil   -- nil = editing current line; number = history index (1-based)
  local paste_buf = nil  -- non-nil = accumulating pasted text
  local cursor_row = 0   -- cursor's current row offset below the first input row
  local pw = _visual_width(prompt)

  io.flush()

  local function refresh()
    local term_w = tonumber(os.getenv("COLUMNS")) or 80
    local out, new_row = _render(prompt, pw, line, pos, term_w, cursor_row)
    io.write(out)
    io.flush()
    cursor_row = new_row
  end

  local function _move_left()
    if pos > 0 then
      pos = pos - 1
      refresh()
    end
  end

  local function _move_right()
    if pos < #line then
      pos = pos + 1
      refresh()
    end
  end

  local function _load_history(entry)
    line = entry or ""
    pos = #line
    refresh()
  end

  while true do
    local ch = io.stdin:read(1)
    if not ch then
      io.write("\n")
      return nil
    end

    local byte = ch:byte()

    -- Bracketed paste mode: accumulate until end marker
    if paste_buf ~= nil then
      paste_buf = paste_buf .. ch
      local marker = "\27[201~"
      if #paste_buf >= #marker and paste_buf:sub(-#marker) == marker then
        local text = paste_buf:sub(1, -#marker - 1)
        text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
        line = line:sub(1, pos) .. text .. line:sub(pos + 1)
        pos = pos + #text
        refresh()
        paste_buf = nil
      end

    elseif byte == 3 then  -- Ctrl+C
      io.write("^C\n")
      return ""

    elseif byte == 4 and #line == 0 then  -- Ctrl+D on empty line = EOF
      io.write("\n")
      return nil

    elseif byte == 13 or byte == 10 then  -- Enter: return line
      io.write("\n")
      return line

    elseif ch == "\27" then  -- escape sequence
      local next_ch = io.stdin:read(1)
      if not next_ch then break end
      if next_ch == "[" then
        local params, term = _read_csi()
        if term == "A" then  -- Up arrow
          if hist_idx == nil then
            saved_line = line
            hist_idx = 1
          elseif hist_idx < #history then
            hist_idx = hist_idx + 1
          end
          if hist_idx <= #history then
            _load_history(history[hist_idx])
          end

        elseif term == "B" then  -- Down arrow
          if hist_idx ~= nil then
            if hist_idx > 1 then
              hist_idx = hist_idx - 1
              _load_history(history[hist_idx])
            elseif hist_idx == 1 then
              hist_idx = nil
              _load_history(saved_line)
              saved_line = nil
            end
          end

        elseif term == "C" then  -- Right arrow
          _move_right()

        elseif term == "D" then  -- Left arrow
          _move_left()

        elseif term == "H" then  -- Home
          pos = 0
          refresh()

        elseif term == "F" then  -- End (xterm)
          pos = #line
          refresh()

        elseif term == "~" and params == "4" then  -- End (vt100 alternate)
          pos = #line
          refresh()

        elseif term == "~" and params == "3" then  -- Delete key
          if pos < #line then
            line = line:sub(1, pos) .. line:sub(pos + 2)
            refresh()
          end

        elseif term == "~" and params == "200" then  -- Bracketed paste start
          paste_buf = ""
        end
      end

    elseif byte == 127 or byte == 8 then  -- Backspace
      if pos > 0 then
        line = line:sub(1, pos - 1) .. line:sub(pos + 1)
        pos = pos - 1
        refresh()
      end

    elseif byte >= 32 then  -- printable ASCII + UTF-8 continuation bytes
      line = line:sub(1, pos) .. ch .. line:sub(pos + 1)
      pos = pos + 1
      refresh()
    end
  end
end

function lineedit.add_history(line)
  if not line or #line == 0 then return end
  if #history > 0 and history[1] == line then return end  -- no consecutive dupes
  table.insert(history, 1, line)
  if #history > history_max then
    history[#history] = nil
  end
end

-- test seams (not used at runtime)
lineedit._render = _render
function lineedit._set_tty(v) is_tty = v end

return lineedit
