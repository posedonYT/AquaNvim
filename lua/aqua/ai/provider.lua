-- Провайдеры моделей со стримингом ответа и вызовом инструментов.
--   ollama — нативный API Ollama (/api/chat)
--   openai — OpenAI-совместимый (/v1/chat/completions): LM Studio, llama.cpp, vLLM, Ollama /v1 ...
--
-- Внутренний формат сообщений (не зависит от провайдера):
--   { role = "system"|"user", content }
--   { role = "assistant", content, tool_calls = { { id, name, args } } }
--   { role = "tool", tool_call_id, name, content }
local M = {}

local function edict(t)
  if t == nil or next(t) == nil then
    return vim.empty_dict()
  end
  return t
end

--- Схемы инструментов в формате function-calling (одинаковы для обоих провайдеров).
---@param tools { name: string, description: string, parameters: table }[]
function M.tool_schemas(tools)
  local out = {}
  for _, t in ipairs(tools) do
    out[#out + 1] = {
      type = "function",
      ["function"] = { name = t.name, description = t.description, parameters = t.parameters },
    }
  end
  return out
end

-- ── Сериализация сообщений ──────────────────────────────────────────────────

function M.to_ollama(messages)
  local out = {}
  for _, m in ipairs(messages) do
    if m.role == "assistant" then
      local msg = { role = "assistant", content = m.content or "" }
      if m.tool_calls and #m.tool_calls > 0 then
        msg.tool_calls = {}
        for _, c in ipairs(m.tool_calls) do
          msg.tool_calls[#msg.tool_calls + 1] = { ["function"] = { name = c.name, arguments = edict(c.args) } }
        end
      end
      out[#out + 1] = msg
    elseif m.role == "tool" then
      out[#out + 1] = { role = "tool", tool_name = m.name, content = m.content }
    else
      out[#out + 1] = { role = m.role, content = m.content }
    end
  end
  return out
end

function M.to_openai(messages)
  local out = {}
  for _, m in ipairs(messages) do
    if m.role == "assistant" then
      local msg = { role = "assistant", content = m.content or "" }
      if m.tool_calls and #m.tool_calls > 0 then
        msg.tool_calls = {}
        for _, c in ipairs(m.tool_calls) do
          msg.tool_calls[#msg.tool_calls + 1] = {
            id = c.id,
            type = "function",
            ["function"] = { name = c.name, arguments = vim.json.encode(edict(c.args)) },
          }
        end
      end
      out[#out + 1] = msg
    elseif m.role == "tool" then
      out[#out + 1] = { role = "tool", tool_call_id = m.tool_call_id, content = m.content }
    else
      out[#out + 1] = { role = m.role, content = m.content }
    end
  end
  return out
end

-- ── Разбор потока ───────────────────────────────────────────────────────────

local JSON_OPTS = { luanil = { object = true, array = true } }

local function decode(s)
  local ok, obj = pcall(vim.json.decode, s, JSON_OPTS)
  if ok and type(obj) == "table" then
    return obj
  end
end

local function err_text(e)
  if type(e) == "string" then
    return e
  elseif type(e) == "table" then
    return e.message or e.error or vim.inspect(e)
  end
  return tostring(e)
end

--- Аргументы вызова: таблица или JSON-строка. Второй результат — «не удалось разобрать».
local function parse_args(a)
  if type(a) == "table" then
    return a, false
  end
  if type(a) == "string" and a:match("%S") then
    local obj = decode(a)
    if obj then
      return obj, false
    end
    return {}, true
  end
  return {}, false
end

--- Инкрементальный разборщик потока ответа. Не зависит от сети — удобно тестировать.
---@param kind "ollama"|"openai"
---@param h { on_text?: fun(s: string), on_thinking?: fun(s: string) }
function M.new_parser(kind, h)
  h = h or {}
  local P = { buf = "", text = {}, calls = {}, slots = {}, raw = {}, done = false, err = nil }

  function P:_ollama(line)
    local obj = decode(line)
    if not obj then
      self.raw[#self.raw + 1] = line
      return
    end
    if obj.error then
      self.err = err_text(obj.error)
      return
    end
    local msg = obj.message
    if msg then
      if msg.thinking and msg.thinking ~= "" and h.on_thinking then
        h.on_thinking(msg.thinking)
      end
      if msg.content and msg.content ~= "" then
        self.text[#self.text + 1] = msg.content
        if h.on_text then h.on_text(msg.content) end
      end
      for _, tc in ipairs(msg.tool_calls or {}) do
        local fn = tc["function"] or {}
        self.calls[#self.calls + 1] = {
          id = tc.id or ("call_" .. (#self.calls + 1)),
          name = fn.name,
          args = (parse_args(fn.arguments)),
        }
      end
    end
    if obj.done then
      self.done = true
    end
  end

  function P:_openai(line)
    if line:sub(1, 1) == ":" then
      return
    end
    if line:sub(1, 5) ~= "data:" then
      self.raw[#self.raw + 1] = line
      return
    end
    local payload = vim.trim(line:sub(6))
    if payload == "[DONE]" then
      self.done = true
      return
    end
    local obj = decode(payload)
    if not obj then
      return
    end
    if obj.error then
      self.err = err_text(obj.error)
      return
    end
    local ch = obj.choices and obj.choices[1]
    local delta = ch and ch.delta
    if delta then
      local think = delta.reasoning_content or delta.reasoning
      if think and think ~= "" and h.on_thinking then
        h.on_thinking(think)
      end
      if delta.content and delta.content ~= "" then
        self.text[#self.text + 1] = delta.content
        if h.on_text then h.on_text(delta.content) end
      end
      for _, tc in ipairs(delta.tool_calls or {}) do
        local idx = (tc.index or 0) + 1
        local slot = self.slots[idx] or { args = "" }
        self.slots[idx] = slot
        if tc.id then slot.id = tc.id end
        local fn = tc["function"]
        if fn then
          if fn.name and fn.name ~= "" then slot.name = slot.name or fn.name end
          if fn.arguments then slot.args = slot.args .. fn.arguments end
        end
      end
    end
    if ch and ch.finish_reason then
      self.done = true
    end
  end

  function P:_line(line)
    line = line:gsub("\r$", "")
    if not line:match("%S") then
      return
    end
    if kind == "ollama" then
      self:_ollama(line)
    else
      self:_openai(line)
    end
  end

  function P:feed(chunk)
    self.buf = self.buf .. chunk
    while true do
      local nl = self.buf:find("\n", 1, true)
      if not nl then
        break
      end
      local line = self.buf:sub(1, nl - 1)
      self.buf = self.buf:sub(nl + 1)
      self:_line(line)
    end
  end

  --- Завершить разбор. Возвращает итоговое сообщение ассистента или nil, ошибку.
  function P:finish()
    if self.buf:match("%S") then
      self:_line(self.buf)
      self.buf = ""
    end
    for i = 1, table.maxn(self.slots) do
      local slot = self.slots[i]
      if slot and slot.name then
        local args, bad = parse_args(slot.args)
        self.calls[#self.calls + 1] = { id = slot.id or ("call_" .. i), name = slot.name, args = args, bad_args = bad or nil }
      end
    end
    if self.err then
      return nil, self.err
    end
    if #self.raw > 0 and not self.done and #self.text == 0 and #self.calls == 0 then
      local raw = table.concat(self.raw, "\n")
      local obj = decode(raw)
      if obj and (obj.error or obj.message) then
        return nil, err_text(obj.error or obj.message)
      end
      return nil, raw:sub(1, 300)
    end
    return { role = "assistant", content = table.concat(self.text), tool_calls = self.calls }
  end

  return P
end

-- ── Сеть (curl) ─────────────────────────────────────────────────────────────

local function headers(profile)
  local h = { "Content-Type: application/json" }
  if profile.api_key and profile.api_key ~= "" then
    h[#h + 1] = "Authorization: Bearer " .. profile.api_key
  end
  for k, v in pairs(profile.headers or {}) do
    h[#h + 1] = k .. ": " .. v
  end
  return h
end

local function curl_error(code, stderr, host)
  if code == 7 then
    return ("Не удалось подключиться к %s — сервер модели запущен? (для Ollama: `ollama serve`)"):format(host)
  elseif code == 28 then
    return "Превышено время ожидания ответа модели"
  end
  stderr = vim.trim(stderr or "")
  return stderr ~= "" and stderr or ("curl завершился с кодом " .. code)
end

---@class aqua.ai.ChatHandlers
---@field on_text? fun(s: string)
---@field on_thinking? fun(s: string)
---@field on_done fun(msg: table)
---@field on_error fun(err: string)

--- Запрос к модели со стримингом. Все колбэки вызываются в основном потоке Neovim.
---@param profile aqua.ai.Profile
---@param req { messages: table[], tools?: table[], timeout?: integer }
---@param h aqua.ai.ChatHandlers
---@return { cancel: fun() }
function M.chat(profile, req, h)
  local kind = profile.provider
  local url = profile.host .. (kind == "ollama" and "/api/chat" or "/v1/chat/completions")
  local body = { model = profile.model, stream = true }
  if kind == "ollama" then
    body.messages = M.to_ollama(req.messages)
    body.options = profile.options
    if profile.think ~= nil then body.think = profile.think end
  else
    body.messages = M.to_openai(req.messages)
    body.temperature = profile.options and profile.options.temperature
  end
  if req.tools and #req.tools > 0 then
    body.tools = req.tools
  end

  local cmd = { "curl", "-sS", "-N", "--no-buffer", "--connect-timeout", "5", "--max-time", tostring(req.timeout or 600), "-X", "POST", url }
  for _, hd in ipairs(headers(profile)) do
    vim.list_extend(cmd, { "-H", hd })
  end
  vim.list_extend(cmd, { "--data-binary", "@-" })

  local parser = M.new_parser(kind, { on_text = h.on_text, on_thinking = h.on_thinking })
  local cancelled = false
  local stderr = {}
  local obj = vim.system(cmd, {
    stdin = vim.json.encode(body),
    text = true,
    stdout = function(_, data)
      if data then
        vim.schedule(function()
          if not cancelled then parser:feed(data) end
        end)
      end
    end,
    stderr = function(_, data)
      if data then stderr[#stderr + 1] = data end
    end,
  }, function(res)
    vim.schedule(function()
      if cancelled then
        return
      end
      local msg, err = parser:finish()
      if res.code ~= 0 and not msg then
        return h.on_error(curl_error(res.code, table.concat(stderr), profile.host))
      end
      if res.code ~= 0 and msg and #msg.content == 0 and #msg.tool_calls == 0 then
        return h.on_error(curl_error(res.code, table.concat(stderr), profile.host))
      end
      if not msg then
        return h.on_error(err or "Неизвестная ошибка провайдера")
      end
      h.on_done(msg)
    end)
  end)

  return {
    cancel = function()
      cancelled = true
      pcall(function() obj:kill(15) end)
    end,
  }
end

--- Список моделей сервера.
---@param profile aqua.ai.Profile
---@param cb fun(models?: string[], err?: string)
function M.list_models(profile, cb)
  local url = profile.host .. (profile.provider == "ollama" and "/api/tags" or "/v1/models")
  local cmd = { "curl", "-sS", "--connect-timeout", "3", "--max-time", "10", url }
  for _, hd in ipairs(headers(profile)) do
    vim.list_extend(cmd, { "-H", hd })
  end
  vim.system(cmd, { text = true }, function(res)
    vim.schedule(function()
      if res.code ~= 0 then
        return cb(nil, curl_error(res.code, res.stderr, profile.host))
      end
      local obj = decode(res.stdout)
      if not obj then
        return cb(nil, "Некорректный ответ сервера: " .. (res.stdout or ""):sub(1, 200))
      end
      local names = {}
      for _, m in ipairs(profile.provider == "ollama" and (obj.models or {}) or (obj.data or {})) do
        names[#names + 1] = m.name or m.id or m.model
      end
      table.sort(names)
      cb(names)
    end)
  end)
end

return M
