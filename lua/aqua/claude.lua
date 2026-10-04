-- Интеграция Claude CLI.
--
-- <leader>c  — открыть/скрыть Claude справа в корне проекта текущего файла.
-- <leader>aC — то же, но в папке текущего файла.
--
-- На каждую директорию — свой экземпляр Claude: скрытие окна не убивает процесс,
-- при переходе в другой проект открывается его собственный Claude.
-- Если фокус в explorer / терминале, директория берётся из последнего файлового буфера.
local root = require("aqua.util.root")

local M = {}

---@type table<string, snacks.win>
M.terms = {}

---@class aqua.claude.Opts
---@field scope? "root"|"file"
---@field cwd? string
---@field args? string[]
---@field restart? boolean пересоздать экземпляр (например для --resume)

---@param opts? aqua.claude.Opts
function M.resolve_cwd(opts)
  opts = opts or {}
  if opts.cwd then
    return opts.cwd
  end
  if opts.scope == "file" then
    return root.file_dir()
  end
  return root.get()
end

local function base_cmd()
  local cmd = vim.g.aqua_claude_cmd or "claude"
  return type(cmd) == "table" and vim.deepcopy(cmd) or { cmd }
end

---@param args? string[]
function M.cmd(args)
  local cmd = base_cmd()
  vim.list_extend(cmd, args or {})
  return cmd
end

function M.available()
  return vim.fn.executable(base_cmd()[1]) == 1
end

---@param term? snacks.win
local function alive(term)
  return term ~= nil and term.buf ~= nil and vim.api.nvim_buf_is_valid(term.buf)
end

--- Экземпляр Claude для директории (если уже запущен).
---@param cwd string
function M.get(cwd)
  local term = M.terms[cwd]
  if alive(term) then
    return term
  end
  M.terms[cwd] = nil
end

--- Все запущенные экземпляры: { cwd = term }.
function M.list()
  local res = {}
  for cwd, term in pairs(M.terms) do
    if alive(term) then
      res[cwd] = term
    else
      M.terms[cwd] = nil
    end
  end
  return res
end

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

local function winbar(cwd)
  return "%#AquaClaudeBar#  󰚩 Claude %#AquaClaudeDir# " .. vim.fn.fnamemodify(cwd, ":~") .. " "
end

---@param cwd string
---@param args? string[]
local function spawn(cwd, args)
  local term = Snacks.terminal.open(M.cmd(args), {
    cwd = cwd,
    env = M.env(),
    interactive = true,
    auto_close = true,
    win = {
      position = "right",
      width = vim.g.aqua_claude_width or 0.4,
      fixbuf = true,
      wo = {
        winbar = winbar(cwd),
        winhighlight = "Normal:AquaClaudeNormal,NormalNC:AquaClaudeNormal,WinBar:AquaClaudeBar,WinBarNC:AquaClaudeBar",
      },
      bo = { filetype = "snacks_terminal" },
      keys = {
        claude_hide = { "<C-,>", function(self) self:hide() end, mode = { "n", "t" }, desc = "Hide Claude" },
        claude_hide_n = { "q", function(self) self:hide() end, mode = "n", desc = "Hide Claude" },
      },
    },
  })
  vim.b[term.buf].aqua_claude_cwd = cwd
  M.terms[cwd] = term
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = term.buf,
    once = true,
    callback = function()
      if M.terms[cwd] == term then
        M.terms[cwd] = nil
      end
    end,
  })
  return term
end

--- Открыть (или показать) Claude. Возвращает snacks.win и признак «только что создан».
---@param opts? aqua.claude.Opts
---@return snacks.win?, boolean?
function M.open(opts)
  opts = opts or {}
  if not M.available() then
    vim.notify(
      "Claude CLI не найден в PATH.\nУстановите: npm i -g @anthropic-ai/claude-code\nили задайте vim.g.aqua_claude_cmd",
      vim.log.levels.ERROR,
      { title = "AquaNvim · Claude" }
    )
    return
  end
  local cwd = M.resolve_cwd(opts)
  local term = M.get(cwd)
  if term and opts.restart then
    term:close()
    term = nil
  end
  if term then
    if not term:valid() then
      term:show()
    end
    term:focus()
    vim.cmd.startinsert()
    return term, false
  end
  return spawn(cwd, opts.args), true
end

--- Показать / скрыть Claude для текущей директории.
---@param opts? aqua.claude.Opts
---@return snacks.win?
function M.toggle(opts)
  opts = opts or {}
  -- Из окна Claude — просто прячем его
  local cur = vim.api.nvim_get_current_buf()
  local cur_cwd = vim.b[cur].aqua_claude_cwd
  if cur_cwd and M.get(cur_cwd) then
    M.terms[cur_cwd]:hide()
    return M.terms[cur_cwd]
  end
  local term = M.get(M.resolve_cwd(opts))
  if term and term:valid() then
    term:hide()
    return term
  end
  return (M.open(opts))
end

--- Ждём, пока CLI отрисует интерфейс, и только потом отправляем текст.
---@param term snacks.win
---@param fresh boolean
---@param cb fun()
local function when_ready(term, fresh, cb)
  if not fresh then
    return cb()
  end
  local tries = 0
  local timer = assert((vim.uv or vim.loop).new_timer())
  timer:start(300, 200, vim.schedule_wrap(function()
    tries = tries + 1
    local ready = false
    if alive(term) then
      for _, line in ipairs(vim.api.nvim_buf_get_lines(term.buf, 0, -1, false)) do
        if line:match("%S") then
          ready = true
          break
        end
      end
    end
    if ready or tries > 40 then
      timer:stop()
      timer:close()
      vim.defer_fn(cb, ready and 600 or 0)
    end
  end))
end

--- Отправить текст в Claude (через bracketed paste, Enter не нажимается).
---@param text string
---@param opts? aqua.claude.Opts
function M.send(text, opts)
  local term, fresh = M.open(opts)
  if not term then
    return
  end
  when_ready(term, fresh or false, function()
    if not alive(term) then
      return
    end
    local chan = vim.bo[term.buf].channel
    local payload = text:find("\n") and ("\27[200~" .. text .. "\27[201~") or text
    vim.api.nvim_chan_send(chan, payload)
    if term:valid() then
      term:focus()
      vim.cmd.startinsert()
    end
  end)
end

---@param buf integer
---@param cwd string
function M.relpath(buf, cwd)
  local file = vim.fs.normalize(vim.api.nvim_buf_get_name(buf))
  file = (vim.uv or vim.loop).fs_realpath(file) or file
  local rel = vim.fs.relpath and vim.fs.relpath(cwd, file)
  return rel or vim.fn.fnamemodify(file, ":~")
end

--- Добавить текущий файл в контекст: `@path/to/file `.
function M.send_file()
  local buf = root.context_buf()
  if not root.is_file_buf(buf) then
    return vim.notify("Нет файла для отправки", vim.log.levels.WARN, { title = "AquaNvim · Claude" })
  end
  M.send("@" .. M.relpath(buf, M.resolve_cwd()) .. " ")
end

--- Сформировать сообщение для выделенного фрагмента.
---@param buf integer
---@param l1 integer
---@param l2 integer
---@param cwd string
function M.format_selection(buf, l1, l2, cwd)
  local lines = vim.api.nvim_buf_get_lines(buf, l1 - 1, l2, false)
  local ft = vim.bo[buf].filetype
  local range = l1 == l2 and ("L" .. l1) or ("L" .. l1 .. "-" .. l2)
  return ("@%s#%s\n```%s\n%s\n```\n"):format(M.relpath(buf, cwd), range, ft, table.concat(lines, "\n"))
end

--- Отправить визуальное выделение (с путём и номерами строк).
function M.send_selection()
  local buf = vim.api.nvim_get_current_buf()
  local l1, l2 = vim.fn.line("v"), vim.fn.line(".")
  if l1 > l2 then
    l1, l2 = l2, l1
  end
  vim.api.nvim_feedkeys(vim.keycode("<esc>"), "nx", false)
  M.send(M.format_selection(buf, l1, l2, M.resolve_cwd()))
end

--- Отправить диагностику текущей строки.
function M.send_diagnostics()
  local buf = vim.api.nvim_get_current_buf()
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local diags = vim.diagnostic.get(buf, { lnum = lnum - 1 })
  if #diags == 0 then
    return vim.notify("На строке нет диагностик", vim.log.levels.INFO, { title = "AquaNvim · Claude" })
  end
  local msgs = {}
  for _, d in ipairs(diags) do
    msgs[#msgs + 1] = ("- [%s] %s"):format(vim.diagnostic.severity[d.severity], d.message)
  end
  M.send(M.format_selection(buf, lnum, lnum, M.resolve_cwd()) .. "Диагностика:\n" .. table.concat(msgs, "\n") .. "\n")
end

--- Выбрать один из запущенных экземпляров Claude.
function M.select()
  local items = vim.tbl_keys(M.list())
  if #items == 0 then
    return vim.notify("Нет запущенных экземпляров Claude", vim.log.levels.INFO, { title = "AquaNvim · Claude" })
  end
  table.sort(items)
  vim.ui.select(items, {
    prompt = "󰚩 Claude",
    format_item = function(cwd) return vim.fn.fnamemodify(cwd, ":~") end,
  }, function(cwd)
    if cwd then
      M.open({ cwd = cwd })
    end
  end)
end

--- Завершить Claude текущего проекта.
---@param opts? aqua.claude.Opts
function M.kill(opts)
  local cwd = M.resolve_cwd(opts)
  local term = M.get(cwd)
  if term then
    term:close()
    M.terms[cwd] = nil
  end
end

--- Для статусной строки: запущен ли Claude для текущего проекта.
function M.status()
  if next(M.terms) == nil then
    return ""
  end
  local n = vim.tbl_count(M.list())
  if n == 0 then
    return ""
  end
  return M.get(root.get()) and ("󰚩 " .. (n > 1 and n or "")) or ("󰚩 " .. n)
end

return M
