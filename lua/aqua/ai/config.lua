-- Конфигурация Aqua AI: профили моделей, права, лимиты.
--
-- Настройка — в lua/custom/options.lua:
--   require("aqua.ai").setup({
--     profiles = {
--       default = { provider = "ollama", host = "http://localhost:11434", model = "gemma4:e4b" },
--       lmstudio = { provider = "openai", host = "http://localhost:1234", model = "qwen2.5-coder" },
--     },
--   })
-- либо через vim.g.aqua_ai = { ... } (только данные, без функций).
local M = {}

M.defaults = {
  --- Имя активного профиля (можно сменить на лету: :AquaAI profile).
  profile = "default",
  ---@type table<string, aqua.ai.Profile>
  profiles = {
    default = {
      provider = "ollama", -- "ollama" | "openai" (любой OpenAI-совместимый сервер)
      host = "http://localhost:11434",
      model = nil, -- nil → выберете через :AquaAI model (запоминается)
      options = { num_ctx = 16384, temperature = 0.2 },
    },
  },
  --- Права инструментов: "allow" | "ask" | "deny".
  ---   docs — официальная документация (только домены из knowledge.official_domains)
  ---   exec — проверка компилятором (check_project: go build/vet/test, cargo check, tsc...)
  permissions = { read = "allow", write = "ask", delete = "ask", web = "ask", docs = "allow", exec = "ask" },
  --- Знания о версиях стека
  knowledge = {
    auto = true, -- изучать заметки о выпуске версий стека перед первым запросом в проекте (один раз на версию)
    prompt_chars = 2500, -- бюджет оглавлений заметок в системном промпте
    stack_chars = 1500, -- бюджет сводки стека в системном промпте
    max_chars = 16000, -- максимум текста, который lookup_docs возвращает за раз
    official_domains = nil, -- nil → список из aqua/ai/knowledge/sources.lua
    sources = {}, -- переопределение URL: { go = "https://.../go{v}", npm = "...{name}@{v}..." }
  },
  check = {
    timeout = 120, -- секунд на check_project
    require_after_edit = true, -- если модель изменила код и не проверила — один раз напомнить вызвать check_project
  },
  max_steps = 30, -- максимум обращений к модели за один запрос пользователя
  context_chars = 60000, -- бюджет истории (символы); старые результаты инструментов сжимаются
  timeout = 600, -- секунд на один ответ модели
  search = { engine = "duckduckgo", url = nil, api_key_env = "BRAVE_API_KEY" }, -- duckduckgo | searxng | brave
  web_max_chars = 12000,
  allow_outside_root = false, -- разрешить файловые операции вне корня проекта
  allow_private_web = false, -- разрешить web_fetch к localhost / локальной сети
  instructions_files = { "AQUA.md", "AGENTS.md", "CLAUDE.md" }, -- проектные инструкции для модели
  system_prompt = nil, -- дополнительный текст к системному промпту
  width = 0.4, -- ширина чата-терминала (доля экрана, минимум 40 колонок)
  persist = true, -- сохранять историю чата по проектам
}

---@class aqua.ai.Profile
---@field provider "ollama"|"openai"
---@field host string
---@field model? string
---@field api_key? string
---@field api_key_env? string
---@field headers? table<string,string>
---@field options? table
---@field think? boolean

M.user = {}

--- Пользовательские настройки (глубокое слияние с defaults).
---@param opts? table
function M.setup(opts)
  M.user = vim.tbl_deep_extend("force", M.user, opts or {})
end

function M.get()
  local g = type(vim.g.aqua_ai) == "table" and vim.g.aqua_ai or {}
  return vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), g, M.user)
end

-- ── Сохраняемое состояние: выбранный профиль и модели ───────────────────────

local function state_path()
  return vim.fn.stdpath("state") .. "/aqua_ai/state.json"
end

local function read_state()
  local f = io.open(state_path(), "r")
  if not f then
    return {}
  end
  local content = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, content)
  return ok and type(data) == "table" and data or {}
end

local function write_state(st)
  vim.fn.mkdir(vim.fs.dirname(state_path()), "p")
  local f = io.open(state_path(), "w")
  if f then
    f:write(vim.json.encode(st))
    f:close()
  end
end

---@param name string
function M.set_profile(name)
  local st = read_state()
  st.profile = name
  write_state(st)
end

---@param profile string
---@param model string
function M.set_model(profile, model)
  local st = read_state()
  st.models = st.models or {}
  st.models[profile] = model
  write_state(st)
end

--- Активный профиль (с учётом сохранённого выбора) и вся конфигурация.
---@return aqua.ai.Profile profile, table cfg
function M.profile()
  local cfg = M.get()
  local st = read_state()
  local name = st.profile
  if not (name and cfg.profiles[name]) then
    name = cfg.profile
  end
  if not cfg.profiles[name] then
    name = next(cfg.profiles)
  end
  local p = vim.deepcopy(cfg.profiles[name])
  p.name = name
  p.model = (st.models and st.models[name]) or p.model
  p.host = (p.host or "http://localhost:11434"):gsub("/+$", "")
  if not p.api_key and p.api_key_env then
    p.api_key = vim.env[p.api_key_env]
  end
  return p, cfg
end

return M
