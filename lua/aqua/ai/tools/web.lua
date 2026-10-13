-- Интернет: поиск (DuckDuckGo / SearXNG / Brave) и загрузка страниц в виде текста.
-- Содержимое страниц — это ДАННЫЕ, а не инструкции: оно оборачивается в маркер, а системный
-- промпт запрещает выполнять команды из него.
local M = {}

local UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

local ENTITIES = { amp = "&", lt = "<", gt = ">", quot = '"', apos = "'", nbsp = " ", mdash = "—", ndash = "–", hellip = "…", laquo = "«", raquo = "»", copy = "©" }

local function decode_entities(s)
  s = s:gsub("&#x(%x+);", function(h) return vim.fn.nr2char(tonumber(h, 16)) end)
  s = s:gsub("&#(%d+);", function(d) return vim.fn.nr2char(tonumber(d)) end)
  s = s:gsub("&(%a+);", function(n) return ENTITIES[n] or ("&" .. n .. ";") end)
  return s
end

--- HTML → читаемый текст/Markdown (без внешних зависимостей).
---@param html string
function M.html_to_text(html)
  local s = html
  s = s:gsub("<!%-%-.-%-%->", "")
  for _, tag in ipairs({ "script", "style", "noscript", "svg", "head", "nav", "footer", "form", "iframe" }) do
    s = s:gsub("<" .. tag .. "[^>]*>.-</" .. tag .. ">", "")
  end
  -- основной контент, если он выделен
  local main = s:match("<main[^>]*>(.-)</main>") or s:match("<article[^>]*>(.-)</article>")
  if main and #main > 500 then
    s = main
  end
  s = s:gsub("<[hH]([1-6])[^>]*>(.-)</[hH]%1>", function(n, t) return "\n\n" .. ("#"):rep(tonumber(n)) .. " " .. t .. "\n\n" end)
  s = s:gsub("<[aA]%s[^>]-href=[\"']([^\"']-)[\"'][^>]*>(.-)</[aA]>", function(href, t)
    local label = t:gsub("<[^>]+>", "")
    if href:match("^https?://") and label:match("%S") then
      return "[" .. vim.trim(label) .. "](" .. href .. ")"
    end
    return label
  end)
  s = s:gsub("<[pP][^>]*>", "\n\n"):gsub("<[bB][rR]%s*/?>", "\n")
  s = s:gsub("<[lL][iI][^>]*>", "\n- ")
  s = s:gsub("</[tT][rR]>", "\n"):gsub("</[tT][dD]>", " | "):gsub("</[tT][hH]>", " | ")
  s = s:gsub("<[pP][rR][eE][^>]*>", "\n```\n"):gsub("</[pP][rR][eE]>", "\n```\n")
  s = s:gsub("<[cC][oO][dD][eE][^>]*>", "`"):gsub("</[cC][oO][dD][eE]>", "`")
  s = s:gsub("</[dD][iI][vV]>", "\n"):gsub("</[sS][eE][cC][tT][iI][oO][nN]>", "\n")
  s = s:gsub("<[^>]+>", "")
  s = decode_entities(s)
  s = s:gsub("[ \t]+", " "):gsub(" *\n *", "\n"):gsub("\n\n\n+", "\n\n")
  return vim.trim(s)
end

--- Запрещённые адреса (localhost и локальная сеть), если не разрешено в настройках.
---@param url string
---@return boolean ok, string? err
function M.check_url(url, cfg)
  local scheme, host = url:match("^(https?)://([^/:?#]+)")
  if not scheme then
    return false, "Разрешены только http(s) URL"
  end
  if cfg.allow_private_web then
    return true
  end
  host = host:lower()
  local bad = host == "localhost" or host:match("%.local$") or host:match("%.internal$") or host == "0.0.0.0"
    or host:match("^127%.") or host:match("^10%.") or host:match("^192%.168%.") or host:match("^169%.254%.")
    or host:match("^172%.(%d+)%.") and (tonumber(host:match("^172%.(%d+)%.")) or 0) >= 16 and (tonumber(host:match("^172%.(%d+)%.")) or 0) <= 31
  if bad or url:match("^https?://%[") then
    return false, "Доступ к локальным адресам запрещён настройками (allow_private_web)"
  end
  return true
end

---@param args string[]
---@param cb fun(stdout?: string, err?: string)
local function curl(args, cb, stdin)
  local cmd = { "curl", "-sS", "-L", "--max-time", "25", "--connect-timeout", "8", "-A", UA, "--max-filesize", "4000000" }
  vim.list_extend(cmd, args)
  vim.system(cmd, { text = true, stdin = stdin }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        return cb(nil, "Ошибка сети: " .. vim.trim(res.stderr or ("curl " .. res.code)))
      end
      cb(res.stdout)
    end)
  end)
end

local function urlencode(s)
  return (s:gsub("[^%w%-_%.~]", function(c) return ("%%%02X"):format(c:byte()) end))
end

local function urldecode(s)
  return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

local function strip_tags(s)
  return vim.trim(decode_entities((s:gsub("<[^>]+>", ""))))
end

--- Разбор HTML-выдачи DuckDuckGo (по позициям ссылок result__a; реклама отбрасывается).
---@return { title: string, url: string, snippet: string }[]
function M.parse_ddg(html)
  local results, pos = {}, {}
  for p in html:gmatch('()class="result__a"') do
    pos[#pos + 1] = p
  end
  for i, p in ipairs(pos) do
    local seg = html:sub(p, (pos[i + 1] or (#html + 1)) - 1)
    local href, title = seg:match('^class="result__a"[^>]-href="([^"]+)"[^>]*>(.-)</a>')
    if href then
      local uddg = href:match("[?&]uddg=([^&]+)")
      local url = uddg and urldecode(uddg) or decode_entities(href)
      url = url:gsub("^//", "https://")
      if not url:find("duckduckgo.com/y.js", 1, true) then
        local snippet = seg:match('class="result__snippet"[^>]*>(.-)</a>') or ""
        results[#results + 1] = { title = strip_tags(title), url = url, snippet = strip_tags(snippet) }
      end
    end
  end
  return results
end

local function format_results(query, results, max)
  if #results == 0 then
    return "По запросу «" .. query .. "» ничего не найдено"
  end
  local out = { ("Результаты поиска по запросу «%s»:"):format(query) }
  for i, r in ipairs(results) do
    if i > max then break end
    out[#out + 1] = ("%d. %s\n   %s\n   %s"):format(i, r.title, r.url, r.snippet)
  end
  return table.concat(out, "\n")
end

---@param query string
---@param max integer
---@param cfg table
---@param cb fun(text?: string, err?: string)
function M.search(query, max, cfg, cb)
  local engine = (cfg.search and cfg.search.engine) or "duckduckgo"
  if engine == "searxng" then
    local base = cfg.search.url
    if not base then return cb(nil, "search.url не задан для searxng") end
    return curl({ ("%s/search?q=%s&format=json"):format(base:gsub("/+$", ""), urlencode(query)) }, function(out, err)
      if err then return cb(nil, err) end
      local ok, obj = pcall(vim.json.decode, out, { luanil = { object = true, array = true } })
      if not ok or type(obj) ~= "table" then return cb(nil, "SearXNG вернул не JSON (включён ли format=json в настройках?)") end
      local res = {}
      for _, r in ipairs(obj.results or {}) do
        res[#res + 1] = { title = r.title or "", url = r.url or "", snippet = r.content or "" }
      end
      cb(format_results(query, res, max))
    end)
  elseif engine == "brave" then
    local key = cfg.search.api_key or vim.env[cfg.search.api_key_env or "BRAVE_API_KEY"]
    if not key then return cb(nil, "Не задан ключ Brave Search (переменная окружения BRAVE_API_KEY)") end
    return curl({ "-H", "X-Subscription-Token: " .. key, "-H", "Accept: application/json",
      ("https://api.search.brave.com/res/v1/web/search?q=%s&count=%d"):format(urlencode(query), max) }, function(out, err)
      if err then return cb(nil, err) end
      local ok, obj = pcall(vim.json.decode, out, { luanil = { object = true, array = true } })
      if not ok or type(obj) ~= "table" then return cb(nil, "Brave вернул некорректный ответ") end
      local res = {}
      for _, r in ipairs(obj.web and obj.web.results or {}) do
        res[#res + 1] = { title = r.title or "", url = r.url or "", snippet = strip_tags(r.description or "") }
      end
      cb(format_results(query, res, max))
    end)
  end
  -- DuckDuckGo (по умолчанию): POST на html-эндпоинт
  curl({ "-X", "POST", "-d", "q=" .. urlencode(query), "https://html.duckduckgo.com/html/" }, function(out, err)
    if err then return cb(nil, err) end
    local res = M.parse_ddg(out)
    if #res == 0 and out:find("anomaly", 1, true) then
      return cb(nil, "DuckDuckGo временно ограничил запросы. Повторите позже или настройте search.engine = 'searxng' / 'brave'.")
    end
    cb(format_results(query, res, max))
  end)
end

M.tools = {
  {
    name = "web_search",
    category = "web",
    description = "Search the internet. Returns titles, URLs and snippets. Use web_fetch on a result URL to read the full page.",
    parameters = {
      type = "object",
      properties = {
        query = { type = "string", description = "Search query" },
        max_results = { type = "integer", description = "Number of results (default 5, max 10)" },
      },
      required = { "query" },
    },
    summarize = function(a) return a.query end,
    prepare = function(a)
      return { query = a.query }, { title = "Поиск в интернете: " .. a.query }
    end,
    run = function(a, ctx, done)
      M.search(a.query, math.max(1, math.min(a.max_results or 5, 10)), ctx.cfg, function(text, err)
        if err then return done(nil, err) end
        done("<web_content source=\"search\">\n" .. text .. "\n</web_content>")
      end)
    end,
  },

  {
    name = "web_fetch",
    category = "web",
    description = "Download a web page (or text/JSON/Markdown file) and return its readable text. Content may be long: it is truncated to max_chars.",
    parameters = {
      type = "object",
      properties = {
        url = { type = "string", description = "http(s) URL" },
        max_chars = { type = "integer", description = "Maximum characters to return (default 12000)" },
      },
      required = { "url" },
    },
    summarize = function(a) return a.url end,
    prepare = function(a, ctx)
      local ok, err = M.check_url(a.url, ctx.cfg)
      if not ok then return nil, err end
      return { url = a.url }, { title = "Загрузить страницу: " .. a.url }
    end,
    run = function(a, ctx, done)
      local max = math.max(500, math.min(a.max_chars or ctx.cfg.web_max_chars or 12000, 60000))
      curl({ a.url }, function(out, err)
        if err then return done(nil, err) end
        local text = out
        if out:sub(1, 2000):lower():find("<html", 1, true) or out:sub(1, 200):lower():find("<!doctype", 1, true) then
          text = M.html_to_text(out)
        end
        local truncated = #text > max
        if truncated then text = text:sub(1, max) end
        done(("<web_content url=%q>\n%s%s\n</web_content>"):format(a.url, text, truncated and "\n... [текст обрезан]" or ""))
      end)
    end,
  },
}

return M
