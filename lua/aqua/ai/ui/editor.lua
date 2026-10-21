-- Поле ввода чата внутри терминала: разбор байтов, которые терминал Neovim присылает
-- при нажатиях (включая kitty-протокол и bracketed paste), и редактирование строки,
-- как в Claude Code CLI / readline.
local M = {}

local function is_cont(b)
  return b ~= nil and b >= 0x80 and b < 0xC0
end

-- ── Разбор входных байтов → события ─────────────────────────────────────────

local CSI_TILDE = { ["1"] = "home", ["7"] = "home", ["4"] = "end", ["8"] = "end", ["3"] = "delete", ["2"] = "insert", ["5"] = "pageup", ["6"] = "pagedown" }
local CSI_FINAL = { A = "up", B = "down", C = "right", D = "left", H = "home", F = "end", Z = "shift_tab" }

--- Модификаторы kitty/xterm: 1 + битовая маска (1 shift, 2 alt, 4 ctrl).
local function mods(n)
  n = (tonumber(n) or 1) - 1
  return { shift = n % 2 == 1, alt = math.floor(n / 2) % 2 == 1, ctrl = math.floor(n / 4) % 2 == 1 }
end

local function key(name, m)
  return { type = "key", name = name, shift = m and m.shift, alt = m and m.alt, ctrl = m and m.ctrl }
end

--- CSI u (kitty): код клавиши + модификаторы.
local function csi_u(code, m)
  code = tonumber(code)
  if code == 13 then
    return key("enter", m)
  elseif code == 27 then
    return key("esc", m)
  elseif code == 9 then
    return key(m.shift and "shift_tab" or "tab", m)
  elseif code == 127 or code == 8 then
    return key("backspace", m)
  elseif code and code >= 32 then
    local ch = vim.fn.nr2char(code)
    if m.ctrl or m.alt then
      return key(ch:lower(), m)
    end
    return { type = "text", text = ch }
  end
end

---@class aqua.ai.Decoder
---@field paste? string[] накопленный текст вставки
---@field pending string незаконченная escape-последовательность

function M.decoder()
  return { pending = "" }
end

--- Байты из терминала → список событий: {type="text"}, {type="key", name=...}, {type="paste"}.
---@param d aqua.ai.Decoder
---@param data string
---@return table[]
function M.decode(d, data)
  local evs = {}
  local s = d.pending .. data
  d.pending = ""
  local i, n = 1, #s
  local text = {}
  local function flush()
    if #text > 0 then
      evs[#evs + 1] = { type = "text", text = table.concat(text) }
      text = {}
    end
  end
  while i <= n do
    if d.paste then
      local e = s:find("\27[201~", i, true)
      if e then
        d.paste[#d.paste + 1] = s:sub(i, e - 1)
        evs[#evs + 1] = { type = "paste", text = table.concat(d.paste) }
        d.paste = nil
        i = e + 6
      else
        -- конец вставки может прийти следующим куском
        local tail = s:sub(i)
        local keep = 0
        for k = math.min(5, #tail), 1, -1 do
          if ("\27[201~"):sub(1, k) == tail:sub(-k) then
            keep = k
            break
          end
        end
        d.paste[#d.paste + 1] = tail:sub(1, #tail - keep)
        d.pending = tail:sub(#tail - keep + 1)
        if keep == 0 then d.pending = "" end
        break
      end
    else
      local c = s:sub(i, i)
      local b = s:byte(i)
      if c == "\27" then
        flush()
        local nx = s:sub(i + 1, i + 1)
        if nx == "" then
          evs[#evs + 1] = key("esc")
          i = i + 1
        elseif nx == "[" then
          local params, final = s:match("^([%d;:?>]*)([%a~])", i + 2)
          if not final then
            if not s:find("[%a~]", i + 2) and n - i < 16 then
              d.pending = s:sub(i) -- последовательность пришла не целиком
              break
            end
            i = i + 2
          else
            local len = 2 + #params + 1
            if params == "200" and final == "~" then
              d.paste = {}
            else
              local p1, p2 = params:match("^([%d]*)[;:]?([%d]*)")
              local m = mods(p2 ~= "" and p2 or nil)
              local ev
              if final == "u" then
                ev = csi_u(p1, m)
              elseif final == "~" then
                ev = CSI_TILDE[p1] and key(CSI_TILDE[p1], m)
              elseif CSI_FINAL[final] then
                ev = key(CSI_FINAL[final], m)
              end
              if ev then evs[#evs + 1] = ev end
            end
            i = i + len
          end
        elseif nx == "O" then
          local f = s:sub(i + 2, i + 2)
          if CSI_FINAL[f] then
            evs[#evs + 1] = key(CSI_FINAL[f])
          end
          i = i + 3
        else
          -- Alt + клавиша
          local m = { alt = true }
          if nx == "\r" then
            evs[#evs + 1] = key("enter", m)
          elseif nx == "\127" or nx == "\8" then
            evs[#evs + 1] = key("backspace", m)
          else
            evs[#evs + 1] = key(nx:lower(), m)
          end
          i = i + 2
        end
      elseif c == "\r" then
        flush()
        evs[#evs + 1] = key("enter")
        i = i + 1
      elseif c == "\n" then
        flush()
        evs[#evs + 1] = key("j", { ctrl = true })
        i = i + 1
      elseif c == "\127" or c == "\8" then
        flush()
        evs[#evs + 1] = key("backspace")
        i = i + 1
      elseif c == "\t" then
        flush()
        evs[#evs + 1] = key("tab")
        i = i + 1
      elseif b < 32 then
        flush()
        evs[#evs + 1] = key(string.char(b + 96), { ctrl = true })
        i = i + 1
      else
        text[#text + 1] = c
        i = i + 1
      end
    end
  end
  flush()
  return evs
end

-- ── Редактирование ──────────────────────────────────────────────────────────

---@class aqua.ai.Editor
---@field text string
---@field cur integer байтов до курсора
---@field history string[]
---@field hidx? integer
---@field draft? string

function M.new()
  return { text = "", cur = 0, history = {} }
end

local function left(s, p)
  if p <= 0 then return 0 end
  local i = p - 1
  while i > 0 and is_cont(s:byte(i + 1)) do
    i = i - 1
  end
  return i
end

local function right(s, p)
  if p >= #s then return #s end
  local i = p + 1
  while i < #s and is_cont(s:byte(i + 1)) do
    i = i + 1
  end
  return i
end

local function line_start(s, p)
  local i = p
  while i > 0 and s:sub(i, i) ~= "\n" do
    i = i - 1
  end
  return i
end

local function line_end(s, p)
  local e = s:find("\n", p + 1, true)
  return e and e - 1 or #s
end

local function word_left(s, p)
  while p > 0 and s:sub(p, p):match("%s") do p = p - 1 end
  while p > 0 and not s:sub(p, p):match("%s") do p = p - 1 end
  return p
end

local function word_right(s, p)
  while p < #s and s:sub(p + 1, p + 1):match("%s") do p = p + 1 end
  while p < #s and not s:sub(p + 1, p + 1):match("%s") do p = p + 1 end
  return p
end

--- Вставить текст в позицию курсора.
---@param e aqua.ai.Editor
---@param text string
function M.insert(e, text)
  text = text:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\t", "    "):gsub("[%z\1-\9\11-\31\127]", "")
  e.text = e.text:sub(1, e.cur) .. text .. e.text:sub(e.cur + 1)
  e.cur = e.cur + #text
end

---@param e aqua.ai.Editor
function M.set(e, text)
  e.text, e.cur = text, #text
end

local function delete(e, a, b)
  if b > a then
    e.text = e.text:sub(1, a) .. e.text:sub(b + 1)
    e.cur = a
  end
end

--- Перейти на строку выше/ниже, сохраняя колонку. false — если строки нет (тогда — история).
local function vertical(e, dir)
  local s, p = e.text, e.cur
  local ls = line_start(s, p)
  local col = vim.fn.strchars(s:sub(ls + 1, p))
  local target
  if dir < 0 then
    if ls == 0 then return false end
    target = line_start(s, ls - 1)
  else
    local le = line_end(s, p)
    if le >= #s then return false end
    target = le + 1
  end
  local tend = line_end(s, target)
  local q = target
  for _ = 1, col do
    if q >= tend then break end
    q = right(s, q)
  end
  e.cur = q
  return true
end

---@param e aqua.ai.Editor
---@param dir integer -1 назад, 1 вперёд
function M.recall(e, dir)
  local h = e.history
  if #h == 0 then return end
  if not e.hidx then
    e.draft = e.text
  end
  local idx = (e.hidx or (#h + 1)) + dir
  idx = math.max(1, math.min(#h + 1, idx))
  e.hidx = idx
  M.set(e, h[idx] or e.draft or "")
  if idx == #h + 1 then
    e.hidx, e.draft = nil, nil
  end
end

--- Применить событие клавиши. Возвращает действие для интерфейса:
--- "submit" | "esc" | "interrupt" | "tab" | "redraw" | "scroll_up" | "scroll_down" | nil.
---@param e aqua.ai.Editor
---@param ev table
function M.apply(e, ev)
  local s = e.text
  if ev.type == "text" or ev.type == "paste" then
    M.insert(e, ev.text)
    return
  end
  local k = ev.name
  if k == "enter" then
    if ev.shift or ev.alt or ev.ctrl then
      M.insert(e, "\n")
    elseif e.cur > 0 and s:sub(e.cur, e.cur) == "\\" then
      -- запасной способ для терминалов без Shift+Enter: «\» в конце + Enter
      e.text = s:sub(1, e.cur - 1) .. "\n" .. s:sub(e.cur + 1)
    else
      return "submit"
    end
  elseif ev.ctrl and k == "j" then
    M.insert(e, "\n")
  elseif k == "backspace" then
    if ev.alt or ev.ctrl then
      delete(e, word_left(s, e.cur), e.cur)
    else
      delete(e, left(s, e.cur), e.cur)
    end
  elseif k == "delete" or (ev.ctrl and k == "d") then
    delete(e, e.cur, right(s, e.cur))
  elseif k == "left" or (ev.ctrl and k == "b") then
    e.cur = (ev.ctrl and k == "left" or ev.alt) and word_left(s, e.cur) or left(s, e.cur)
  elseif k == "right" or (ev.ctrl and k == "f") then
    e.cur = (ev.ctrl and k == "right" or ev.alt) and word_right(s, e.cur) or right(s, e.cur)
  elseif ev.alt and k == "b" then
    e.cur = word_left(s, e.cur)
  elseif ev.alt and k == "f" then
    e.cur = word_right(s, e.cur)
  elseif ev.alt and k == "d" then
    delete(e, e.cur, word_right(s, e.cur))
  elseif k == "home" or (ev.ctrl and k == "a") then
    e.cur = line_start(s, e.cur)
  elseif k == "end" or (ev.ctrl and k == "e") then
    e.cur = line_end(s, e.cur)
  elseif ev.ctrl and k == "k" then
    local le = line_end(s, e.cur)
    delete(e, e.cur, le == e.cur and math.min(#s, le + 1) or le)
  elseif ev.ctrl and k == "u" then
    delete(e, line_start(s, e.cur), e.cur)
  elseif ev.ctrl and k == "w" then
    delete(e, word_left(s, e.cur), e.cur)
  elseif k == "up" then
    if not vertical(e, -1) then M.recall(e, -1) end
  elseif k == "down" then
    if not vertical(e, 1) then M.recall(e, 1) end
  elseif ev.ctrl and k == "p" then
    M.recall(e, -1)
  elseif ev.ctrl and k == "n" then
    M.recall(e, 1)
  elseif ev.ctrl and k == "c" then
    return "interrupt"
  elseif k == "esc" then
    return "esc"
  elseif k == "tab" then
    return "tab"
  elseif ev.ctrl and k == "l" then
    return "redraw"
  elseif k == "pageup" then
    return "scroll_up"
  elseif k == "pagedown" then
    return "scroll_down"
  end
end

return M
