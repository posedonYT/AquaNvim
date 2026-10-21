-- Документация → дерево разделов → компактный конспект.
-- Работает с Markdown (в т. ч. setext-заголовками "Title\n=====") и с HTML (через web.html_to_text).
local cut = require("aqua.util.text").cut

local M = {}

local function looks_html(s)
  local head = s:sub(1, 3000):lower()
  return head:find("<html", 1, true) or head:find("<!doctype html", 1, true) or head:find("<body", 1, true)
end

--- Привести загруженный текст к Markdown.
---@param content string
---@param format? "html"|"markdown"|"text"
function M.to_markdown(content, format)
  if format == "markdown" or format == "text" then
    return content
  end
  if format == "html" or looks_html(content) then
    return require("aqua.ai.tools.web").html_to_text(content)
  end
  return content
end

--- Заголовок без «¶», якорей и Markdown-ссылок: "[PEP 649](https://…) & …¶" → "PEP 649 & …"
function M.clean_title(t)
  t = t:gsub("%[([^%]]*)%]%b()", "%1"):gsub("¶", ""):gsub("%s*#+%s*$", "")
  return vim.trim(t)
end

-- Служебные разделы HTML-страниц, которые не нужны в оглавлении
M.SKIP = { navigation = true, contents = true, ["table of contents"] = true, ["on this page"] = true,
  ["external links"] = true, ["see also"] = true, ["this page"] = true }

---@class aqua.digest.Section
---@field level integer
---@field title string
---@field first integer строка заголовка
---@field last integer последняя строка раздела (включая подразделы)

--- Заголовки документа (ATX и — для Markdown — setext), блоки кода пропускаются.
--- Для текста, полученного из HTML, setext выключен: подчёркивания таблиц дают ложные заголовки.
---@param lines string[]
---@param opts? { setext?: boolean }
---@return aqua.digest.Section[]
function M.headings(lines, opts)
  local setext = not opts or opts.setext ~= false
  local res, fence = {}, nil
  local i = 1
  while i <= #lines do
    local l = lines[i]
    local f = l:match("^%s*(```+)") or l:match("^%s*(~~~+)")
    if f then
      if not fence then fence = f:sub(1, 3) elseif f:sub(1, 3) == fence then fence = nil end
    elseif not fence then
      local hashes, title = l:match("^(#+)%s+(.-)%s*#*%s*$")
      local nxt = lines[i + 1]
      if hashes and #hashes <= 6 and title ~= "" then
        res[#res + 1] = { level = #hashes, title = M.clean_title(title), first = i }
      elseif setext and nxt and l:match("%S") and not l:match("^%s*[-*+>|]") and (nxt:match("^=+%s*$") or nxt:match("^%-%-%-+%s*$")) then
        res[#res + 1] = { level = nxt:match("^=") and 1 or 2, title = M.clean_title(l), first = i, setext = true }
        i = i + 1
      end
    end
    i = i + 1
  end
  for k, h in ipairs(res) do
    h.last = #lines
    for j = k + 1, #res do
      if res[j].level <= h.level then
        h.last = res[j].first - 1
        break
      end
    end
  end
  return res
end

local function split(md)
  return vim.split(md or "", "\n", { plain = true })
end

--- Найти раздел по заголовку (без учёта регистра: точное совпадение, затем подстрока).
---@param md string
---@param query string
---@param max? integer
---@return string? text, string? title
function M.section(md, query, max, opts)
  local lines = split(md)
  local heads = M.headings(lines, opts)
  local q = vim.trim(query or ""):lower():gsub("^#+%s*", "")
  local best
  for _, h in ipairs(heads) do
    local t = h.title:lower()
    if t == q then best = h break end
  end
  if not best then
    for _, h in ipairs(heads) do
      if h.title:lower():find(q, 1, true) then best = h break end
    end
  end
  if not best then
    return nil
  end
  local text = table.concat(vim.list_slice(lines, best.first, best.last), "\n")
  max = max or 16000
  if #text > max then
    text = cut(text, max) .. "\n... [раздел обрезан]"
  end
  return text, best.title
end

--- Собственный текст раздела (до первого подзаголовка), первый абзац.
local function first_paragraph(lines, h, heads, idx)
  local stop = h.last
  local nxt = heads[idx + 1]
  if nxt and nxt.first - 1 < stop then stop = nxt.first - 1 end
  local buf, started, fence = {}, false, false
  for i = h.first + (h.setext and 2 or 1), stop do
    local l = lines[i]
    if l:match("^%s*```") then fence = not fence end
    if not fence and not l:match("^%s*```") then
      if l:match("%S") then
        started = true
        buf[#buf + 1] = vim.trim(l)
      elseif started then
        break
      end
    end
  end
  return table.concat(buf, " ")
end

--- Конспект: дерево заголовков + начало каждого раздела, не длиннее max.
---@param md string
---@param max? integer
function M.digest(md, max, opts)
  max = max or 16000
  if #md <= max then
    return md
  end
  local lines = split(md)
  local heads = vim.tbl_filter(function(h) return not M.SKIP[h.title:lower()] end, M.headings(lines, opts))
  if #heads == 0 then
    return cut(md, max) .. "\n... [обрезано]"
  end
  local function build(snip, max_level)
    local out = {}
    for i, h in ipairs(heads) do
      if h.level <= max_level then
        out[#out + 1] = ("#"):rep(h.level) .. " " .. h.title
        if snip > 0 then
          local p = first_paragraph(lines, h, heads, i)
          if p ~= "" then
            out[#out + 1] = #p > snip and (cut(p, snip) .. "…") or p
          end
        end
      end
    end
    return table.concat(out, "\n")
  end
  local snip, level = 400, 6
  local text = build(snip, level)
  while #text > max and snip > 60 do
    snip = math.floor(snip * 0.7)
    text = build(snip, level)
  end
  while #text > max and level > 2 do
    level = level - 1
    text = build(snip, level)
  end
  if #text > max then
    text = build(0, level)
  end
  if #text > max then
    text = cut(text, max) .. "\n…"
  end
  return text .. "\n\n(Конспект. Полный текст раздела: lookup_docs с параметром section.)"
end

--- Оглавление для системного промпта: заголовки уровней 1–3 (и до 3 подзаголовков 3-го уровня на раздел).
---@param md string
---@param max integer
function M.index(md, max, opts)
  local heads = M.headings(split(md), opts)
  local out = {}
  for _, h in ipairs(heads) do
    if h.level <= 3 and not M.SKIP[h.title:lower()] then
      out[#out + 1] = ("  "):rep(math.max(0, h.level - 1)) .. "- " .. h.title
    end
  end
  local text = table.concat(out, "\n")
  if #text > max then
    text = cut(text, math.max(0, max - 4)) .. " …"
  end
  return text
end

return M
