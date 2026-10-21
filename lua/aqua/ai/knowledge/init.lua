-- База знаний о версиях стека: заметки о выпусках языков и документация пакетов,
-- загруженные из официальных источников и сохранённые в кэш (один раз на версию,
-- общий для всех проектов): stdpath("state")/aqua_ai/knowledge/<вид>/<имя>@<версия>.md
local sources = require("aqua.ai.knowledge.sources")
local digest = require("aqua.ai.knowledge.digest")
local version = require("aqua.ai.stack.version")

local M = {}

M.MAX_NOTE = 400 * 1024

function M.dir()
  return vim.fn.stdpath("state") .. "/aqua_ai/knowledge"
end

local function safe(s)
  return (tostring(s):gsub("[^%w%.%-_@+]", "_"))
end

---@param kind string "lang" | "go" | "npm" | "pypi" | "crates"
function M.path(kind, name, ver)
  return ("%s/%s/%s@%s.md"):format(M.dir(), kind, safe(name), safe(ver or "latest"))
end

--- Прочитать заметку: тело и метаданные из front-matter.
---@return string? body, table? meta
function M.read_note(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  local meta = {}
  local fm, body = s:match("^%-%-%-\n(.-)\n%-%-%-\n(.*)$")
  if fm then
    for k, v in fm:gmatch("([%w_]+):%s*([^\n]*)") do meta[k] = v end
  else
    body = s
  end
  return body, meta
end

function M.write_note(path, meta, body)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local f = assert(io.open(path, "w"))
  local keys = vim.tbl_keys(meta)
  table.sort(keys)
  f:write("---\n")
  for _, k in ipairs(keys) do f:write(("%s: %s\n"):format(k, tostring(meta[k]):gsub("\n", " "))) end
  f:write("---\n")
  f:write(body)
  f:close()
end

local function cfg_knowledge(cfg)
  return (cfg and cfg.knowledge) or {}
end

--- Загрузка только с официальных доменов (категория прав docs).
---@param url string
---@param cfg table
---@param cb fun(body?: string, err?: string)
function M.fetch(url, cfg, cb, opts)
  local k = cfg_knowledge(cfg)
  if not sources.is_official(url, k.official_domains) then
    return cb(nil, "Источник не входит в список официальных (" .. url .. "). Для произвольных сайтов используйте web_fetch.")
  end
  require("aqua.ai.tools.web").fetch(url, vim.tbl_extend("force", { fail = true, max_bytes = 8000000, timeout = 40 }, opts or {}), cb)
end

-- ── Языки ───────────────────────────────────────────────────────────────────

--- Описание цели: канонический язык, нормализованная версия, путь кэша, url, подпись.
---@return table? info, string? err
function M.language_info(name, v, cfg)
  local lang = sources.language(name)
  if not lang then
    return nil, ("Неизвестный язык «%s». Доступно: %s"):format(tostring(name), table.concat(vim.tbl_keys(sources.languages), ", "))
  end
  if not v or v == "" then
    return nil, "Не указана версия для " .. lang
  end
  local url, ver, spec = sources.language_url(lang, v, cfg_knowledge(cfg).sources)
  if not url then
    return nil, ("Не удалось разобрать версию «%s» для %s"):format(tostring(v), lang)
  end
  return { lang = lang, version = ver, url = url, spec = spec, path = M.path("lang", lang, ver), label = spec.label:gsub("{v}", ver) }
end

--- Есть ли заметка в кэше.
function M.has(lang, v, cfg)
  local info = M.language_info(lang, v, cfg)
  return info ~= nil and vim.fn.filereadable(info.path) == 1
end

--- Загрузить (или взять из кэша) заметки о выпуске версии языка.
---@param cb fun(body?: string, err?: string, info?: table, from_cache?: boolean)
function M.ensure_language(lang, v, cfg, cb, force)
  local info, err = M.language_info(lang, v, cfg)
  if not info then return cb(nil, err) end
  if not force then
    local body = M.read_note(info.path)
    if body then return cb(body, nil, info, true) end
  end
  M.fetch(info.url, cfg, function(content, ferr)
    if not content then
      return cb(nil, ferr, info)
    end
    local md = digest.to_markdown(content, info.spec.format)
    if info.spec.section then
      local title = info.spec.section:gsub("{v}", info.version)
      local sect = digest.section(md, title, M.MAX_NOTE, { setext = info.spec.format == "markdown" })
      if not sect then
        return cb(nil, ("В %s нет раздела «%s» (возможно, версия ещё не вышла)"):format(info.url, title), info)
      end
      md = sect
    end
    if #vim.trim(md) < 200 then
      return cb(nil, "Страница почти пустая: " .. info.url, info)
    end
    if #md > M.MAX_NOTE then md = md:sub(1, M.MAX_NOTE) end
    M.write_note(info.path, { title = info.label, source = info.url, version = info.version, fetched = os.date("%Y-%m-%d"), format = info.spec.format or "html" }, md)
    cb(md, nil, info, false)
  end)
end

-- ── Пакеты ──────────────────────────────────────────────────────────────────

--- Извлечь читаемый текст из ответа реестра.
local function package_text(registry, content, spec)
  if spec.format == "json" then
    local ok, obj = pcall(vim.json.decode, content, { luanil = { object = true, array = true } })
    if not ok or type(obj) ~= "table" then return nil end
    if registry == "pypi" then
      local i = obj.info or {}
      return ("# %s %s\n\n%s\n\nrequires-python: %s\nhome: %s\n\n%s"):format(i.name or "", i.version or "", i.summary or "",
        i.requires_python or "?", i.home_page or (i.project_urls and i.project_urls.Homepage) or "", i.description or "")
    elseif registry == "go" then
      return ("Module version: %s (published %s)"):format(obj.Version or "?", obj.Time or "?")
    end
    return vim.inspect(obj)
  end
  return digest.to_markdown(content, spec.format)
end

--- Документация пакета (кэш по реестру/имени/версии).
---@param registry "go"|"npm"|"pypi"|"crates"
---@param cb fun(body?: string, err?: string, meta?: table, from_cache?: boolean)
function M.ensure_package(registry, name, v, cfg, cb, force)
  if not name:match("^[@%w%._%-/~]+$") or name:find("..", 1, true) then
    return cb(nil, "Некорректное имя пакета: " .. name)
  end
  local exact = v and version.parse(v) and version.clean(v) or nil
  if registry == "go" and v then exact = v:match("^v") and v or ("v" .. (exact or v)) end
  local path = M.path(registry, name, exact)
  if not force then
    local body, meta = M.read_note(path)
    if body then return cb(body, nil, meta, true) end
  end
  local url, spec = sources.package_url(registry, name, exact, cfg_knowledge(cfg).sources)
  if not url then return cb(nil, "Неизвестный реестр: " .. tostring(registry)) end
  local function done(content, used_url)
    local text = package_text(registry, content, spec)
    if not text or #vim.trim(text) == 0 then
      return cb(nil, "Пустой ответ реестра: " .. used_url)
    end
    if #text > M.MAX_NOTE then text = text:sub(1, M.MAX_NOTE) end
    local meta = { title = name .. " " .. (exact or "latest"), source = used_url, version = exact or "latest", fetched = os.date("%Y-%m-%d"),
      format = (spec.format == "json" or spec.format == "markdown") and "markdown" or "html" }
    M.write_note(path, meta, text)
    cb(text, nil, meta, false)
  end
  M.fetch(url, cfg, function(content, err)
    if content then return done(content, url) end
    -- точной версии нет (например, «>=0.115») — пробуем последнюю
    if exact then
      local latest = sources.package_url(registry, name, nil, cfg_knowledge(cfg).sources)
      return M.fetch(latest, cfg, function(c2, e2)
        if c2 then return done(c2, latest) end
        cb(nil, err .. "; " .. tostring(e2))
      end)
    end
    cb(nil, err)
  end)
end

--- Параметры разбора по метаданным заметки (setext — только для Markdown-источников).
function M.opts(meta)
  return { setext = meta ~= nil and meta.format == "markdown" }
end

-- ── Для системного промпта ──────────────────────────────────────────────────

--- Оглавления сохранённых заметок для целей стека, в пределах бюджета.
---@param targets table[] из stack.targets()
---@param cfg table
---@param budget integer
function M.prompt_notes(targets, cfg, budget)
  if #targets == 0 then return nil end
  local per = math.floor(budget / #targets)
  local out = {}
  for _, t in ipairs(targets) do
    local info = M.language_info(t.lang, t.version, cfg)
    local body, meta
    if info then body, meta = M.read_note(info.path) end -- (`a and f()` теряет второе значение)
    if body then
      out[#out + 1] = ("### %s — official release notes are cached (%s)\nSections (read any with lookup_docs name=%q version=%q section=\"<title>\"):\n%s")
        :format(info.label, meta and meta.source or info.url, t.lang, t.version, digest.index(body, per, M.opts(meta)))
    else
      out[#out + 1] = ("### %s — notes NOT available yet: call lookup_docs(name=%q, version=%q) before writing code that may rely on new features.")
        :format(t.label, t.lang, t.version)
    end
  end
  return table.concat(out, "\n\n")
end

--- Все сохранённые заметки (для :AquaAI knowledge).
function M.list()
  local res = {}
  local dir = M.dir()
  for kind, t in vim.fs.dir(dir) do
    if t == "directory" then
      for name, ft in vim.fs.dir(dir .. "/" .. kind) do
        if ft == "file" then res[#res + 1] = { kind = kind, file = dir .. "/" .. kind .. "/" .. name, name = name } end
      end
    end
  end
  table.sort(res, function(a, b) return a.file < b.file end)
  return res
end

return M
