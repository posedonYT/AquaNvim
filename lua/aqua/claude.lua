-- Интеграция Claude CLI (подробности — в aqua/agent.lua).
--
-- <leader>c  — открыть/скрыть Claude справа в корне проекта текущего файла.
-- <leader>aC — то же, но в папке текущего файла.
local M = require("aqua.agent").new({
  id = "claude",
  name = "Claude",
  icon = "\u{f06a9}",
  cmd_var = "aqua_claude_cmd",
  default_cmd = "claude",
  width_var = "aqua_claude_width",
  hl = "AquaClaude",
  cwd_var = "aqua_claude_cwd",
  install_hint = "Claude CLI не найден в PATH.\nУстановите: npm i -g @anthropic-ai/claude-code\nили задайте vim.g.aqua_claude_cmd",
})

--- Переменные окружения для Claude. Если включён extra ai.claudecode и его
--- WebSocket-сервер запущен — Claude автоматически подключается к Neovim как к IDE
--- (диффы правок прямо в редакторе, контекст выделения).
function M.env()
  local env = { AQUANVIM = "1" }
  local ok, cc = pcall(function()
    return package.loaded["claudecode"] and require("claudecode")
  end)
  local port = ok and cc and cc.state and cc.state.port
  if port then
    env.ENABLE_IDE_INTEGRATION = "true"
    env.FORCE_CODE_TERMINAL = "true"
    env.CLAUDE_CODE_SSE_PORT = tostring(port)
  end
  return env
end
M.spec.env = M.env

return M
