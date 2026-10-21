-- Отрисовка чата Aqua AI в терминале: Markdown → цветные строки (ANSI), перенос по словам,
-- рамка поля ввода. Чистые функции — без окон и буферов, поэтому легко тестируются.
--
-- Строка экрана (row) — { segs = { {text, hl, bold?, italic?, underline?, strike?, bg?}, ... }, w = ширина }.
-- Цвета берутся из групп подсветки темы (AquaAI*, @keyword...), поэтому чат следует теме.
local M = {}

local CHAR = "[%z\1-\127\194-\244][\128-\191]*"

--- Ширина строки в ячейках терминала.
function M.width(s)
  return vim.api.nvim_strwidth(s)
end

--- Убрать управляющие символы (кроме \n), табуляцию заменить пробелами.
---@param s string
function M.sanitize(s)
  s = s:gsub("\r\n", "\n"):gsub("\r", "\n"):gsub("\t", "    ")
  return (s:gsub("[%z\1-\8\11-\31\127]", ""))
end

-- ── Цвета: группа подсветки → SGR ───────────────────────────────────────────

local sgr_cache = {}

function M.clear_cache()
  sgr_cache = {}
end

---@param name? string
local function get_hl(name)
  while name and name ~= "" do
    local hl = vim.api.nvim_get_hl(0, { name = name, link = false })
    if next(hl) then
      return hl
    end
    -- @keyword.function.go → @keyword.function → @keyword
    local parent = name:match("^(.+)%.[^.]+$")
    name = parent
  end
  return {}
end

local function rgb(n)
  return ("%d;%d;%d"):format(math.floor(n / 65536) % 256, math.floor(n / 256) % 256, n % 256)
end

--- SGR-последовательность для сегмента (цвет текста и атрибуты из hl, фон — из hl или bg).
function M.sgr(seg)
  local key = ("%s|%s|%s%s%s%s"):format(seg.hl or "", seg.bg or "", seg.bold and "b" or "", seg.italic and "i" or "", seg.underline and "u" or "", seg.strike and "s" or "")
  local c = sgr_cache[key]
  if c then
    return c
  end
  local hl = get_hl(seg.hl)
  local parts = { "0" }
  if hl.bold or seg.bold then parts[#parts + 1] = "1" end
  if hl.italic or seg.italic then parts[#parts + 1] = "3" end
  if hl.underline or seg.underline then parts[#parts + 1] = "4" end
  if hl.strikethrough or seg.strike then parts[#parts + 1] = "9" end
  if hl.fg then parts[#parts + 1] = "38;2;" .. rgb(hl.fg) end
  local bg = hl.bg
  if not bg and seg.bg then
    bg = get_hl(seg.bg).bg
  end
  if bg then parts[#parts + 1] = "48;2;" .. rgb(bg) end
  c = "\27[" .. table.concat(parts, ";") .. "m"
  sgr_cache[key] = c
  return c
end

local function seg(text, hl, extra)
  local s = { text = text, hl = hl }
  for k, v in pairs(extra or {}) do
    s[k] = v
  end
  return s
end
M.seg = seg

--- Строка экрана → текст с ANSI. fill — группа фона, которым строка добивается до width.
---@param row table
---@param width? integer
---@param fill? string
function M.ansi(row, width, fill)
  local out = {}
  for _, s in ipairs(row.segs) do
    if fill and not s.bg then
      s = vim.tbl_extend("force", s, { bg = fill })
    end
    out[#out + 1] = M.sgr(s) .. s.text
  end
  if fill and width and row.w < width then
    out[#out + 1] = M.sgr({ hl = fill }) .. string.rep(" ", width - row.w)
  end
  out[#out + 1] = "\27[0m"
  return table.concat(out)
end

--- Простой текст строки (для тестов и отладки).
function M.plain(row)
  local out = {}
  for _, s in ipairs(row.segs) do
    out[#out + 1] = s.text
  end
  return table.concat(out)
end

-- ── Перенос строк ───────────────────────────────────────────────────────────

--- Разложить сегменты по строкам ширины width.
---@param segs table[]
---@param width integer
---@param opts? { first?: table[], rest?: table[], char?: boolean, fill?: string, keep_lead?: boolean }
---@return table[] rows
function M.wrap(segs, width, opts)
  opts = opts or {}
  width = math.max(width, 8)
  local rows = {}
  local row
  local prefix = opts.first or {}
  local content = false -- в строке уже есть текст (не только префикс)

  local function new_row()
    row = { segs = {}, w = 0, fill = opts.fill }
    for _, p in ipairs(prefix) do
      row.segs[#row.segs + 1] = p
      row.w = row.w + M.width(p.text)
    end
    prefix = opts.rest or opts.first or {}
    content = false
    rows[#rows + 1] = row
  end

  local function push(s, text, w)
    local last = row.segs[#row.segs]
    if last and content and last.hl == s.hl and last.bold == s.bold and last.italic == s.italic and last.underline == s.underline and last.strike == s.strike and last.bg == s.bg then
      last.text = last.text .. text
    else
      local n = vim.deepcopy(s)
      n.text = text
      row.segs[#row.segs + 1] = n
    end
    row.w = row.w + w
    content = true
  end

  local function hard(s, text)
    for ch in text:gmatch(CHAR) do
      local cw = M.width(ch)
      if row.w + cw > width and content then
        new_row()
      end
      push(s, ch, cw)
    end
  end

  new_row()
  for _, s in ipairs(segs) do
    local text = s.text
    local pos = 1
    while pos <= #text do
      local a, b
      if opts.char then
        a, b = text:find("^" .. CHAR, pos)
      elseif text:sub(pos, pos):match("%s") then
        a, b = text:find("^%s+", pos)
      else
        a, b = text:find("^%S+", pos)
      end
      local atom = text:sub(a, b)
      pos = b + 1
      local aw = M.width(atom)
      if opts.char then
        if row.w + aw > width and content then
          new_row()
        end
        push(s, atom, aw)
      elseif atom:match("^%s") then
        if row.w + aw <= width then
          if content or (opts.keep_lead and #rows == 1) then push(s, atom, aw) end
        else
          new_row()
        end
      elseif row.w + aw <= width then
        push(s, atom, aw)
      elseif not content then
        hard(s, atom)
      else
        new_row()
        if row.w + aw <= width then
          push(s, atom, aw)
        else
          hard(s, atom)
        end
      end
    end
  end
  -- пробелы в конце строк не нужны
  for _, r in ipairs(rows) do
    local last = r.segs[#r.segs]
    if last and last.text:match("%s$") and #r.segs > #(opts.first or {}) then
      local trimmed = last.text:gsub("%s+$", "")
      r.w = r.w - (M.width(last.text) - M.width(trimmed))
      last.text = trimmed
    end
  end
  return rows
end

-- ── Markdown ────────────────────────────────────────────────────────────────

--- Строчная разметка: **жирный**, *курсив*, `код`, ~~зачёркнутый~~, [ссылка](url).
---@param s string
---@param base? string группа подсветки текста
---@param extra? table атрибуты базового текста
function M.inline(s, base, extra)
  local segs, buf = {}, {}
  local state = { bold = false, italic = false, strike = false }
  local function flush()
    if #buf > 0 then
      local attrs = vim.tbl_extend("force", extra or {}, {})
      if state.bold then attrs.bold = true end
      if state.italic then attrs.italic = true end
      if state.strike then attrs.strike = true end
      segs[#segs + 1] = seg(table.concat(buf), base, attrs)
      buf = {}
    end
  end
  local i, n = 1, #s
  while i <= n do
    local c = s:sub(i, i)
    local two = s:sub(i, i + 1)
    if c == "`" then
      local ticks = s:match("^`+", i)
      local j = s:find(ticks, i + #ticks, true)
      if j then
        flush()
        local code = s:sub(i + #ticks, j - 1)
        if #ticks > 1 then code = vim.trim(code) end
        segs[#segs + 1] = seg(code, "AquaAICodeInline")
        i = j + #ticks
        goto continue
      end
    elseif (two == "**" or two == "__") then
      if state.bold == two then
        flush()
        state.bold = false
        i = i + 2
        goto continue
      elseif not state.bold and s:find(two, i + 2, true) and s:sub(i + 2, i + 2):match("%S") then
        flush()
        state.bold = two
        i = i + 2
        goto continue
      end
    elseif two == "~~" then
      if state.strike then
        flush()
        state.strike = false
        i = i + 2
        goto continue
      elseif s:find("~~", i + 2, true) then
        flush()
        state.strike = true
        i = i + 2
        goto continue
      end
    elseif c == "*" or c == "_" then
      local prev, nxt = s:sub(i - 1, i - 1), s:sub(i + 1, i + 1)
      if state.italic == c and prev:match("%S") then
        flush()
        state.italic = false
        i = i + 1
        goto continue
      elseif not state.italic and nxt:match("[^%s*_]") and (c == "*" or not prev:match("[%w]")) then
        local close = s:find(c, i + 1, true)
        if close and (c == "*" or not s:sub(close + 1, close + 1):match("[%w]")) then
          flush()
          state.italic = c
          i = i + 1
          goto continue
        end
      end
    elseif c == "[" then
      local text, url, e = s:match("^%[([^%]]*)%]%(([^%)%s]*)%)()", i)
      if text then
        flush()
        segs[#segs + 1] = seg(text ~= "" and text or url, "AquaAILink", { underline = true })
        if url:match("^https?://") and text ~= url and text ~= "" then
          segs[#segs + 1] = seg(" (" .. url .. ")", "AquaAIDim")
        end
        i = e
        goto continue
      end
    end
    buf[#buf + 1] = c
    i = i + 1
    ::continue::
  end
  flush()
  return segs
end

-- Подсветка кода через treesitter (по строке; если парсера нет — одним цветом).
local query_cache = {}

---@param line string
---@param lang? string
function M.code_segs(line, lang)
  local plain = { seg(line, "AquaAICodeText") }
  if not lang or lang == "" or line == "" then
    return plain
  end
  local ok, res = pcall(function()
    local tslang = vim.treesitter.language.get_lang(lang) or lang
    if not vim.treesitter.language.add(tslang) then
      return nil
    end
    local q = query_cache[tslang]
    if q == nil then
      q = vim.treesitter.query.get(tslang, "highlights") or false
      query_cache[tslang] = q
    end
    if not q then
      return nil
    end
    local parser = vim.treesitter.get_string_parser(line, tslang)
    local tree = parser:parse()[1]
    local marks = {}
    for id, node in q:iter_captures(tree:root(), line, 0, 1) do
      local name = q.captures[id]
      if not name:match("^_") and name ~= "spell" and name ~= "nospell" and name ~= "conceal" then
        local sr, sc, er, ec = node:range()
        if sr == 0 then
          if er > 0 then ec = #line end
          for b = sc + 1, ec do
            marks[b] = "@" .. name
          end
        end
      end
    end
    local segs, cur, buf = {}, nil, {}
    local pos = 1
    for ch in line:gmatch(CHAR) do
      local h = marks[pos] or "AquaAICodeText"
      if h ~= cur and #buf > 0 then
        segs[#segs + 1] = seg(table.concat(buf), cur)
        buf = {}
      end
      cur = h
      buf[#buf + 1] = ch
      pos = pos + #ch
    end
    if #buf > 0 then
      segs[#segs + 1] = seg(table.concat(buf), cur)
    end
    return segs
  end)
  return ok and res or plain
end

--- Одна строка Markdown → строки экрана. state хранит, внутри ли мы блока кода.
---@param line string
---@param state table  { fence?: string, lang?: string }
---@param width integer
---@return table[] rows
function M.markdown_line(line, state, width)
  line = M.sanitize(line)
  -- блок кода
  local fence, info = line:match("^%s*(```+)%s*([^`%s]*)")
  if not fence then
    fence, info = line:match("^%s*(~~~+)%s*(%S*)")
  end
  if state.fence then
    if fence and fence:sub(1, 1) == state.fence:sub(1, 1) and #fence >= #state.fence and vim.trim(line) == fence then
      state.fence, state.lang = nil, nil
      return { { segs = {}, w = 0, fill = "AquaAICode" } }
    end
    return M.wrap(M.code_segs(line, state.lang), width, { char = true, first = { seg(" ", "AquaAICode") }, fill = "AquaAICode" })
  end
  if fence then
    state.fence, state.lang = fence, info ~= "" and info or nil
    return { { segs = { seg(" " .. (state.lang or "code"), "AquaAICodeLabel") }, w = 1 + M.width(state.lang or "code"), fill = "AquaAICode" } }
  end

  if vim.trim(line) == "" then
    return { { segs = {}, w = 0 } }
  end
  -- заголовок
  local hashes, title = line:match("^%s*(#+)%s+(.-)%s*#*%s*$")
  if hashes and #hashes <= 6 then
    local hl = #hashes == 1 and "AquaAIH1" or (#hashes == 2 and "AquaAIH2" or "AquaAIH3")
    return M.wrap(M.inline(title, hl, { bold = true }), width)
  end
  -- горизонтальная линия
  if line:match("^%s*%-%-%-+%s*$") or line:match("^%s*%*%*%*+%s*$") or line:match("^%s*___+%s*$") then
    return { { segs = { seg(string.rep("─", width), "AquaAIDim") }, w = width } }
  end
  -- цитата
  local quote = line:match("^%s*>%s?(.*)$")
  if quote then
    local p = { seg("▎ ", "AquaAIQuoteBar") }
    return M.wrap(M.inline(quote, "AquaAIQuote"), width, { first = p, rest = p })
  end
  -- таблица (строки приходят по одной, поэтому без выравнивания колонок)
  if line:match("^%s*|.*|%s*$") then
    local inner = vim.trim(line):gsub("^|", ""):gsub("|$", "")
    if inner:match("^[%s|:%-]+$") then
      local s = inner:gsub("%s", ""):gsub("[-:]", "─"):gsub("|", "┼")
      return M.wrap({ seg(s, "AquaAIDim") }, width, { char = true })
    end
    local segs = {}
    for i, cell in ipairs(vim.split(inner, "|", { plain = true })) do
      if i > 1 then
        segs[#segs + 1] = seg(" │ ", "AquaAIDim")
      end
      vim.list_extend(segs, M.inline(vim.trim(cell), "AquaAIText"))
    end
    return M.wrap(segs, width)
  end
  -- списки
  local indent, bullet, rest = line:match("^(%s*)([-*+])%s+(.*)$")
  if bullet then
    local mark = "• "
    local box, after = rest:match("^%[([ xX])%]%s+(.*)$")
    if box then
      mark, rest = (box == " " and "☐ " or "☑ "), after
    end
    local pad = string.rep(" ", math.min(#indent, 8))
    return M.wrap(M.inline(rest, "AquaAIText"), width, {
      first = { seg(pad .. mark, "AquaAIBullet") },
      rest = { seg(pad .. string.rep(" ", M.width(mark)), "AquaAIText") },
    })
  end
  local oindent, num, orest = line:match("^(%s*)(%d+[.)])%s+(.*)$")
  if num then
    local pad = string.rep(" ", math.min(#oindent, 8))
    return M.wrap(M.inline(orest, "AquaAIText"), width, {
      first = { seg(pad .. num .. " ", "AquaAIBullet") },
      rest = { seg(pad .. string.rep(" ", #num + 1), "AquaAIText") },
    })
  end
  return M.wrap(M.inline(vim.trim(line), "AquaAIText"), width)
end

--- Markdown-текст целиком → строки экрана.
---@param text string
---@param width integer
---@param state? table
function M.markdown(text, width, state)
  state = state or {}
  local rows = {}
  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    vim.list_extend(rows, M.markdown_line(line, state, width))
  end
  return rows
end

--- Добавить к строкам внешний отступ: первой — first, остальным — rest.
---@param rows table[]
---@param first table[]
---@param rest table[]
function M.indent(rows, first, rest)
  for i, r in ipairs(rows) do
    local p = i == 1 and first or rest
    local w = 0
    for _, s in ipairs(p) do
      w = w + M.width(s.text)
    end
    r.segs = vim.list_extend(vim.deepcopy(p), r.segs)
    r.w = r.w + w
    r.indent = w
  end
  return rows
end

--- Строки экрана → ANSI (с заливкой фона, если она задана у строки).
---@param rows table[]
---@param width integer
function M.to_ansi(rows, width)
  local out = {}
  for i, r in ipairs(rows) do
    if r.fill then
      -- отступ слева не заливаем: фон начинается с текста
      local ind = r.indent or 0
      local head, body = {}, {}
      local acc = 0
      for _, s in ipairs(r.segs) do
        if acc < ind then
          head[#head + 1] = s
          acc = acc + M.width(s.text)
        else
          body[#body + 1] = s
        end
      end
      out[i] = M.ansi({ segs = head, w = acc }):gsub("\27%[0m$", "") .. M.ansi({ segs = body, w = r.w - acc }, width - acc, r.fill)
    else
      out[i] = M.ansi(r)
    end
  end
  return out
end

-- ── Рамки ───────────────────────────────────────────────────────────────────

--- Отрезать строку до ширины n ячеек.
function M.cut(s, n)
  if M.width(s) <= n then
    return s
  end
  local out, w = {}, 0
  for ch in s:gmatch(CHAR) do
    local cw = M.width(ch)
    if w + cw > n - 1 then
      break
    end
    out[#out + 1] = ch
    w = w + cw
  end
  return table.concat(out) .. "…"
end

--- Рамка вокруг строк-сегментов.
---@param lines table[][] список строк, каждая — список сегментов
---@param width integer
---@param border string группа подсветки рамки
---@param title? table[] сегменты заголовка (в верхней линии)
function M.box(lines, width, border, title)
  width = math.max(width, 10)
  local inner = width - 4
  local rows = {}
  local top = { seg("╭─", border) }
  local tw = 0
  if title then
    for _, s in ipairs(title) do
      top[#top + 1] = s
      tw = tw + M.width(s.text)
    end
  end
  top[#top + 1] = seg(string.rep("─", math.max(0, width - 3 - tw)) .. "╮", border)
  rows[1] = { segs = top, w = width }
  for _, segs in ipairs(lines) do
    local r = { seg("│ ", border) }
    local w = 0
    for _, s in ipairs(segs) do
      local t = s.text
      if w + M.width(t) > inner then
        t = M.cut(t, inner - w)
      end
      r[#r + 1] = seg(t, s.hl, s)
      r[#r].text = t
      w = w + M.width(t)
      if w >= inner then break end
    end
    r[#r + 1] = seg(string.rep(" ", math.max(0, inner - w)) .. " │", border)
    rows[#rows + 1] = { segs = r, w = width }
  end
  rows[#rows + 1] = { segs = { seg("╰" .. string.rep("─", width - 2) .. "╯", border) }, w = width }
  return rows
end

--- Поле ввода: рамка, «❯», перенос по ширине, курсор.
---@param text string
---@param cur integer позиция курсора (байт)
---@param width integer
---@param opts? { max_rows?: integer, placeholder?: string, border?: string }
---@return table[] rows, integer cursor_row (1-based в rows), integer cursor_col (0-based ячейки)
function M.input_box(text, cur, width, opts)
  opts = opts or {}
  width = math.max(width, 12)
  local tw = width - 6 -- "│ ❯ " + текст + " │"
  local vrows = { { chars = {}, w = 0 } }
  local crow, ccol
  local pos = 0
  local function mark()
    if pos == cur and not crow then
      local r = vrows[#vrows]
      if r.w >= tw then
        vrows[#vrows + 1] = { chars = {}, w = 0 }
        r = vrows[#vrows]
      end
      crow, ccol = #vrows, r.w
    end
  end
  for ch in text:gmatch(CHAR) do
    mark()
    if ch == "\n" then
      vrows[#vrows + 1] = { chars = {}, w = 0 }
    else
      local cw = M.width(ch)
      local r = vrows[#vrows]
      if r.w + cw > tw then
        vrows[#vrows + 1] = { chars = {}, w = 0 }
        r = vrows[#vrows]
      end
      r.chars[#r.chars + 1] = ch
      r.w = r.w + cw
    end
    pos = pos + #ch
  end
  mark()
  crow, ccol = crow or #vrows, ccol or vrows[#vrows].w
  -- окно видимых строк вокруг курсора
  local max = opts.max_rows or 8
  local first = 1
  if #vrows > max then
    first = math.max(1, math.min(crow - max + 1, #vrows - max + 1))
    if crow < first then first = crow end
  end
  local last = math.min(#vrows, first + max - 1)
  local lines = {}
  for i = first, last do
    local r = vrows[i]
    local p = i == 1 and seg("❯ ", "AquaAIPromptChar") or seg("  ", "AquaAIText")
    if text == "" and opts.placeholder then
      lines[#lines + 1] = { p, seg(M.cut(opts.placeholder, tw), "AquaAIPlaceholder") }
    else
      lines[#lines + 1] = { p, seg(table.concat(r.chars), "AquaAIText") }
    end
  end
  local rows = M.box(lines, width, opts.border or "AquaAIBox")
  return rows, crow - first + 2, 4 + ccol
end

return M
