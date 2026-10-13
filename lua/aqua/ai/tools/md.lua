-- Инструменты для Markdown: структура документа и правка по разделам.
-- Работают с заголовками `#`..`######` (заголовки внутри блоков кода игнорируются).
local sandbox = require("aqua.ai.tools.sandbox")
local fs = require("aqua.ai.tools.fs")

local M = {}

--- Разбор заголовков документа.
---@param lines string[]
---@return { line: integer, level: integer, title: string }[]
function M.headings(lines)
  local heads, fence = {}, nil
  for i, l in ipairs(lines) do
    local f = l:match("^%s*(```+)") or l:match("^%s*(~~~+)")
    if f then
      if not fence then
        fence = f:sub(1, 3)
      elseif f:sub(1, 3) == fence then
        fence = nil
      end
    elseif not fence then
      local hashes, title = l:match("^(#+)%s+(.-)%s*$")
      if hashes and #hashes <= 6 then
        title = title:gsub("%s+#+$", "")
        heads[#heads + 1] = { line = i, level = #hashes, title = title }
      end
    end
  end
  return heads
end

--- Найти раздел по заголовку: "Установка", "## Установка", без учёта регистра.
---@return table? head, integer? index
function M.find(heads, query, occurrence)
  query = vim.trim(query or "")
  local level, title = query:match("^(#+)%s+(.*)$")
  title = vim.trim(title or query):lower()
  level = level and #level or nil
  local n = 0
  for i, h in ipairs(heads) do
    if h.title:lower() == title and (not level or h.level == level) then
      n = n + 1
      if n == (occurrence or 1) then
        return h, i
      end
    end
  end
end

--- Границы раздела: от заголовка до следующего (любого уровня или не глубже своего).
---@return integer first, integer last
function M.range(heads, idx, total, with_children)
  local h = heads[idx]
  for j = idx + 1, #heads do
    local nx = heads[j]
    if not with_children or nx.level <= h.level then
      return h.line, nx.line - 1
    end
  end
  return h.line, total
end

local function is_item(l)
  return l ~= nil and (l:match("^%s*[-*+]%s") or l:match("^%s*%d+[.)]%s")) ~= nil
end

local function split(content)
  local lines = vim.split(content, "\n", { plain = true })
  local trailing = false
  if lines[#lines] == "" then
    table.remove(lines)
    trailing = true
  end
  return lines, trailing
end

local function join(lines, trailing)
  return table.concat(lines, "\n") .. (trailing and "\n" or "")
end

local function load(ctx, path)
  local abs, rel = sandbox.resolve(ctx, path)
  if not abs then
    return nil, rel
  end
  local content, err = fs.read_text(abs)
  if not content then
    return nil, ("%s: %s"):format(rel, err)
  end
  return { abs = abs, rel = rel, content = content }
end

M.tools = {
  {
    name = "md_outline",
    category = "read",
    description = "Show the heading structure (outline) of a Markdown file with line numbers. Use it before editing sections.",
    parameters = {
      type = "object",
      properties = { path = { type = "string", description = "Markdown file path" } },
      required = { "path" },
    },
    summarize = function(a) return a.path end,
    run = function(a, ctx, done)
      local f, err = load(ctx, a.path)
      if not f then return done(nil, err) end
      local lines = split(f.content)
      local heads = M.headings(lines)
      if #heads == 0 then return done(("%s: заголовков нет (%d строк)"):format(f.rel, #lines)) end
      local out = { ("%s (%d строк)"):format(f.rel, #lines) }
      for _, h in ipairs(heads) do
        out[#out + 1] = ("L%d %s%s %s"):format(h.line, ("  "):rep(h.level - 1), ("#"):rep(h.level), h.title)
      end
      done(table.concat(out, "\n"))
    end,
  },

  {
    name = "md_read_section",
    category = "read",
    description = "Read one section of a Markdown file by its heading text (e.g. 'Installation' or '## Installation'). Includes subsections by default.",
    parameters = {
      type = "object",
      properties = {
        path = { type = "string", description = "Markdown file path" },
        heading = { type = "string", description = "Heading text, optionally with leading #'s to pin the level" },
        include_subsections = { type = "boolean", description = "Include nested sections (default true)" },
        occurrence = { type = "integer", description = "Which one if several headings match (default 1)" },
      },
      required = { "path", "heading" },
    },
    summarize = function(a) return ("%s › %s"):format(a.path, a.heading) end,
    run = function(a, ctx, done)
      local f, err = load(ctx, a.path)
      if not f then return done(nil, err) end
      local lines = split(f.content)
      local heads = M.headings(lines)
      local h, idx = M.find(heads, a.heading, a.occurrence)
      if not h then return done(nil, ("Раздел «%s» не найден. Используйте md_outline, чтобы увидеть заголовки."):format(a.heading)) end
      local first, last = M.range(heads, idx, #lines, a.include_subsections ~= false)
      done(("%s, строки %d–%d\n%s"):format(f.rel, first, last, table.concat(vim.list_slice(lines, first, last), "\n")))
    end,
  },

  {
    name = "md_write_section",
    category = "write",
    description = "Change one section of a Markdown file. mode: 'replace' (replace the section's own text, keeping the heading and subsections), 'append' (add to the end of the section's own text), 'prepend' (add right after the heading). If the heading does not exist it is created at the end of the file (set level, default 2).",
    parameters = {
      type = "object",
      properties = {
        path = { type = "string", description = "Markdown file path (created if missing)" },
        heading = { type = "string", description = "Heading text (without #)" },
        content = { type = "string", description = "Markdown text for the section body" },
        mode = { type = "string", enum = { "replace", "append", "prepend" }, description = "Default: replace" },
        level = { type = "integer", description = "Heading level when creating a new section (1-6, default 2)" },
        occurrence = { type = "integer", description = "Which one if several headings match" },
      },
      required = { "path", "heading", "content" },
    },
    summarize = function(a) return ("%s › %s"):format(a.path, a.heading) end,
    prepare = function(a, ctx)
      local abs, rel = sandbox.resolve(ctx, a.path, { write = true })
      if not abs then return nil, rel end
      local old = ""
      local st = (vim.uv or vim.loop).fs_stat(abs)
      if st then
        local c, err = fs.read_text(abs)
        if not c then return nil, ("%s: %s"):format(rel, err) end
        old = c
      end
      local lines, trailing = split(old)
      if old == "" then trailing = true end
      local body = vim.split((a.content:gsub("\n+$", "")), "\n", { plain = true })
      local heads = M.headings(lines)
      local clean = (a.heading:gsub("^#+%s*", ""))
      local h, idx = M.find(heads, clean, a.occurrence)
      local mode = a.mode or "replace"
      local new_lines
      if not h then
        new_lines = vim.deepcopy(lines)
        if #new_lines > 0 and new_lines[#new_lines] ~= "" then new_lines[#new_lines + 1] = "" end
        new_lines[#new_lines + 1] = ("#"):rep(math.max(1, math.min(a.level or 2, 6))) .. " " .. clean
        new_lines[#new_lines + 1] = ""
        vim.list_extend(new_lines, body)
      else
        local first, last = M.range(heads, idx, #lines, false) -- без подразделов
        local before = vim.list_slice(lines, 1, first)
        local own = vim.list_slice(lines, first + 1, last)
        local after = vim.list_slice(lines, last + 1, #lines)
        while #own > 0 and own[#own] == "" do own[#own] = nil end
        while #own > 0 and own[1] == "" do table.remove(own, 1) end
        local sect = { "" }
        if mode == "replace" then
          vim.list_extend(sect, body)
        elseif mode == "append" then
          vim.list_extend(sect, own)
          -- пункт списка продолжает список, без пустой строки между ними
          if #own > 0 and not (is_item(own[#own]) and is_item(body[1])) then sect[#sect + 1] = "" end
          vim.list_extend(sect, body)
        else -- prepend
          vim.list_extend(sect, body)
          if #own > 0 and not (is_item(body[#body]) and is_item(own[1])) then sect[#sect + 1] = "" end
          vim.list_extend(sect, own)
        end
        if #after > 0 then sect[#sect + 1] = "" end
        new_lines = before
        vim.list_extend(new_lines, sect)
        vim.list_extend(new_lines, after)
      end
      local new = join(new_lines, trailing)
      return { abs = abs, rel = rel, new = new, created = h == nil, existed = st ~= nil },
        { title = ("Markdown %s › %s (%s)"):format(rel, clean, h and mode or "новый раздел"), diff = fs.diff_of(old, new) }
    end,
    run = function(_, _, done, plan)
      local ok, err = fs.write_text(plan.abs, plan.new)
      if not ok then return done(nil, err) end
      done(("%s: раздел %s"):format(plan.rel, plan.created and "создан" or "обновлён"))
    end,
  },
}

return M
