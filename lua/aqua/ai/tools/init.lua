-- Реестр инструментов Aqua AI и их безопасное выполнение:
-- проверка аргументов → подготовка (предпросмотр diff) → запрос разрешения → выполнение.
local M = {}

---@class aqua.ai.Tool
---@field name string
---@field category "read"|"write"|"delete"|"web"
---@field description string
---@field parameters table
---@field summarize? fun(args: table): string
---@field prepare? fun(args: table, ctx: table): any?, table|string
---@field run fun(args: table, ctx: table, done: fun(result?: string, err?: string), plan?: any)

---@type aqua.ai.Tool[]
M.list = {}
---@type table<string, aqua.ai.Tool>
M.by_name = {}

local function register(tool)
  M.list[#M.list + 1] = tool
  M.by_name[tool.name] = tool
end

for _, mod in ipairs({ "aqua.ai.tools.fs", "aqua.ai.tools.md", "aqua.ai.tools.web", "aqua.ai.tools.stack" }) do
  for _, tool in ipairs(require(mod).tools) do
    register(tool)
  end
end

--- Добавить собственный инструмент (из lua/custom/*).
---@param tool aqua.ai.Tool
function M.register(tool)
  assert(tool.name and tool.run and tool.parameters, "tool: нужны name, parameters, run")
  tool.category = tool.category or "write"
  if M.by_name[tool.name] then
    for i, t in ipairs(M.list) do
      if t.name == tool.name then table.remove(M.list, i) break end
    end
  end
  register(tool)
end

---@param name string
function M.get(name)
  return M.by_name[name]
end

--- Инструменты, доступные модели (запрещённые настройками категории скрываются).
function M.available(cfg)
  return vim.tbl_filter(function(t)
    return (cfg.permissions[t.category] or "ask") ~= "deny"
  end, M.list)
end

--- Привести аргументы к типам схемы (малые модели часто присылают "5" вместо 5) и проверить обязательные.
---@return table? args, string? err
local function normalize(tool, args)
  local props = (tool.parameters.properties or {})
  local out = {}
  for k, v in pairs(args) do
    local spec = props[k]
    if spec then
      if spec.type == "integer" or spec.type == "number" then
        v = tonumber(v) or v
        if type(v) == "number" and spec.type == "integer" then v = math.floor(v) end
      elseif spec.type == "boolean" and type(v) == "string" then
        v = v == "true"
      elseif spec.type == "string" and type(v) ~= "string" and v ~= nil then
        v = type(v) == "table" and vim.json.encode(v) or tostring(v)
      end
    end
    out[k] = v
  end
  for _, req in ipairs(tool.parameters.required or {}) do
    if out[req] == nil then
      return nil, ("Не хватает обязательного параметра «%s» (инструмент %s)"):format(req, tool.name)
    end
  end
  return out
end

local MAX_RESULT = 24000

local function truncate(s)
  s = s or ""
  if #s > MAX_RESULT then
    return s:sub(1, MAX_RESULT) .. ("\n... [результат обрезан: %d из %d символов]"):format(MAX_RESULT, #s)
  end
  return s
end

--- Краткое описание вызова для интерфейса.
function M.summary(name, args)
  local tool = M.by_name[name]
  if tool and tool.summarize then
    local ok, s = pcall(tool.summarize, type(args) == "table" and args or {})
    if ok and s then return s end
  end
  return ""
end

---@param name string
---@param args table
---@param ctx aqua.ai.Ctx
---@param cb fun(result: string, is_err: boolean, denied?: boolean)
function M.execute(name, args, ctx, cb)
  local tool = M.by_name[name]
  if not tool then
    return cb(("Неизвестный инструмент «%s». Доступные: %s"):format(name, table.concat(vim.tbl_map(function(t) return t.name end, M.list), ", ")), true)
  end
  local nargs, err = normalize(tool, type(args) == "table" and args or {})
  if not nargs then
    return cb(err, true)
  end
  args = nargs

  local plan, info
  if tool.prepare then
    local ok, p, i = pcall(tool.prepare, args, ctx)
    if not ok then return cb("Внутренняя ошибка инструмента: " .. tostring(p), true) end
    if p == nil then return cb(tostring(i), true) end
    plan, info = p, i
  end

  require("aqua.ai.permissions").request(tool.category, info or { title = tool.name }, ctx, function(allowed, note)
    if not allowed then
      return cb(("Пользователь отклонил действие%s. Не повторяйте его без запроса — уточните, как поступить."):format(note and note ~= "" and (": " .. note) or ""), true, true)
    end
    local finished = false
    local function done(result, e)
      if finished then return end
      finished = true
      if e then return cb(truncate(e), true) end
      cb(truncate(result), false)
    end
    local ok, run_err = pcall(tool.run, args, ctx, done, plan)
    if not ok then
      done(nil, "Внутренняя ошибка инструмента: " .. tostring(run_err))
    end
  end)
end

return M
