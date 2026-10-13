-- Ваши личные настройки AquaNvim. Файл выполняется до загрузки плагинов.
-- Здесь можно задавать vim.g.aqua_* и vim.opt.*.

-- ── Aqua AI: подключение вашей локальной нейросети ──────────────────────────
-- Профили: можно держать несколько серверов/моделей и переключаться (:AquaAI profile).
--   provider = "ollama"  — нативный API Ollama
--   provider = "openai"  — любой OpenAI-совместимый сервер (LM Studio, llama.cpp, vLLM, ...)
require("aqua.ai").setup({
  profiles = {
    default = {
      provider = "ollama",
      host = "http://localhost:11434",
      -- model = "gemma4:e4b", -- если не указать, выбор сохранится через :AquaAI model
      options = { num_ctx = 16384, temperature = 0.2 }, -- num_ctx: размер контекста (в Ollama по умолчанию всего 4096!)
    },
    -- lmstudio = { provider = "openai", host = "http://localhost:1234", model = "qwen2.5-coder-7b" },
    -- llamacpp = { provider = "openai", host = "http://localhost:8080", model = "local" },
  },
  -- Права инструментов: "allow" | "ask" | "deny"
  -- permissions = { read = "allow", write = "ask", delete = "ask", web = "ask" },
  -- Поиск в интернете: "duckduckgo" (по умолчанию, без ключа) | "searxng" | "brave"
  -- search = { engine = "searxng", url = "http://localhost:8888" },
})

-- ── Прочее ──────────────────────────────────────────────────────────────────
-- vim.g.aqua_claude_cmd = { "claude", "--model", "opus" }
-- vim.g.aqua_claude_width = 0.4
