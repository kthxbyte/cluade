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

-- Full redraw: restore to anchor, clear to end of screen,
-- rewrite line, position cursor using CUU + CUF (avoids CUB wrapping issues)
local function _redraw(prompt, line, pos)
  local term_w = tonumber(os.getenv("COLUMNS")) or 80
  local pw = _visual_width(prompt)

  io.write("\27[u")             -- restore cursor to anchor (just after prompt)
  io.write("\27[J")             -- clear from anchor to end of screen
  io.write(line)                -- write line content; cursor is now at end

  -- Calculate cursor position relative to anchor
  local abs_end = pw + #line    -- absolute column of line end from start of prompt
  local abs_target = pw + pos   -- absolute column of target position

  local end_row = math.floor(abs_end / term_w)
  local target_row = math.floor(abs_target / term_w)
  local target_col = abs_target % term_w

  -- Go up from end row to target row (CUU handles row boundaries)
  if end_row > target_row then
    io.write("\27[" .. (end_row - target_row) .. "A")
  end
  -- Go to column 0 of target row, then right (CUF stays within row)
  io.write("\r")
  if target_col > 0 then
    io.write("\27[" .. target_col .. "C")
  end

  io.flush()
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
  io.write("\27[s")     -- save anchor: cursor position just after prompt
  io.write("\27[?25h")   -- ensure cursor is visible
  io.write("\27[?2004h") -- enable bracketed paste mode
  local line = ""
  local pos = 0
  local hist_idx = nil   -- nil = editing current line; number = history index (1-based)
  local paste_buf = nil  -- non-nil = accumulating pasted text

  io.flush()

  local function _move_left()
    if pos > 0 then
      pos = pos - 1
      _redraw(prompt, line, pos)
    end
  end

  local function _move_right()
    if pos < #line then
      pos = pos + 1
      _redraw(prompt, line, pos)
    end
  end

  local function _load_history(entry)
    line = entry or ""
    pos = #line
    _redraw(prompt, line, pos)
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
        _redraw(prompt, line, pos)
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
          _redraw(prompt, line, pos)

        elseif term == "F" then  -- End (xterm)
          pos = #line
          _redraw(prompt, line, pos)

        elseif term == "~" and params == "4" then  -- End (vt100 alternate)
          pos = #line
          _redraw(prompt, line, pos)

        elseif term == "~" and params == "3" then  -- Delete key
          if pos < #line then
            line = line:sub(1, pos) .. line:sub(pos + 2)
            _redraw(prompt, line, pos)
          end

        elseif term == "~" and params == "200" then  -- Bracketed paste start
          paste_buf = ""
        end
      end

    elseif byte == 127 or byte == 8 then  -- Backspace
      if pos > 0 then
        line = line:sub(1, pos - 1) .. line:sub(pos + 1)
        pos = pos - 1
        _redraw(prompt, line, pos)
      end

    elseif byte >= 32 then  -- printable ASCII + UTF-8 continuation bytes
      line = line:sub(1, pos) .. ch .. line:sub(pos + 1)
      pos = pos + 1
      _redraw(prompt, line, pos)
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

return lineedit
