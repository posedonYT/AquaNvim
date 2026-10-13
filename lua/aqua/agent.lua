-- Фабрика AI-агентов в терминале (Claude CLI и т. п.).
--
-- Агент открывается справа в корне проекта текущего файла (scope = "root")
-- либо в папке файла (scope = "file").
--
-- На каждую директорию — свой экземпляр: скрытие окна не убивает процесс,
-- при переходе в другой проект открывается его собственный экземпляр.
-- Если фокус в explorer / терминале, директория берётся из последнего файлового буфера.
-- Одновременно виден только один агент: открытие одного прячет окна другого.
local root = require("aqua.util.root")

local M = {}

---@type table<string, aqua.Agent>
M.agents = {}

---@class aqua.agent.Spec
---@field id string            "claude"
---@field name string          "Claude"
---@field icon string
---@field cmd_var string       имя vim.g-переменной с командой, напр. "aqua_claude_cmd"
---@field default_cmd string
---@field width_var string
---@field hl string            префикс групп подсветки: AquaClaude → AquaClaudeNormal/Bar/Dir
---@field cwd_var string       имя b:-переменной буфера с cwd
---@field env? fun(): table<string,string>
---@field install_hint string

---@class aqua.agent.Opts
---@field scope? "root"|"file"
---@field cwd? string
---@field args? string[]
---@field restart? boolean пересоздать экземпляр (например для --continue)

---@class aqua.Agent
---@field spec aqua.agent.Spec
---@field terms table<string, snacks.win>

---@param term? snacks.win
local function alive(term)
  return term ~= nil and term.buf ~= nil and vim.api.nvim_buf_is_valid(term.buf)
end

---@param spec aqua.agent.Spec
function M.new(spec)
  local A = { spec = spec, terms = {} }
  local title = "AquaNvim · " .. spec.name

  ---@param opts? aqua.agent.Opts
  function A.resolve_cwd(opts)
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
    local cmd = vim.g[spec.cmd_var] or spec.default_cmd
    return type(cmd) == "table" and vim.deepcopy(cmd) or { cmd }
  end

  ---@param args? string[]
  function A.cmd(args)
    local cmd = base_cmd()
    vim.list_extend(cmd, args or {})
    return cmd
  end

  function A.available()
    return vim.fn.executable(base_cmd()[1]) == 1
  end

  --- Экземпляр для директории (если уже запущен).
  ---@param cwd string
  function A.get(cwd)
    local term = A.terms[cwd]
    if alive(term) then
      return term
    end
    A.terms[cwd] = nil
  end

  --- Все запущенные экземпляры: { cwd = term }.
  function A.list()
    local res = {}
    for cwd, term in pairs(A.terms) do
      if alive(term) then
        res[cwd] = term
      else
        A.terms[cwd] = nil
      end
    end
    return res
  end

  --- Спрятать все видимые окна этого агента.
  function A.hide_all()
    for _, term in pairs(A.list()) do
      if term:valid() then
        term:hide()
      end
    end
  end

  local function hide_others()
    for _, other in pairs(M.agents) do
      if other ~= A then
        other.hide_all()
      end
    end
    -- чат Aqua AI занимает то же место справа
    if package.loaded["aqua.ai"] then
      require("aqua.ai").hide_all()
    end
  end

  local function winbar(cwd)
    return ("%%#%sBar#  %s %s %%#%sDir# %s "):format(spec.hl, spec.icon, spec.name, spec.hl, vim.fn.fnamemodify(cwd, ":~"))
  end

  ---@param cwd string
  ---@param args? string[]
  local function spawn(cwd, args)
    local hide = function(self) self:hide() end
    local term = Snacks.terminal.open(A.cmd(args), {
      cwd = cwd,
      env = spec.env and spec.env() or { AQUANVIM = "1" },
      interactive = true,
      auto_close = true,
      win = {
        position = "right",
        width = vim.g[spec.width_var] or 0.4,
        fixbuf = true,
        wo = {
          winbar = winbar(cwd),
          winhighlight = ("Normal:%sNormal,NormalNC:%sNormal,WinBar:%sBar,WinBarNC:%sBar"):format(spec.hl, spec.hl, spec.hl, spec.hl),
        },
        bo = { filetype = "snacks_terminal" },
        keys = {
          agent_hide = { "<C-,>", hide, mode = { "n", "t" }, desc = "Hide " .. spec.name },
          agent_hide_n = { "q", hide, mode = "n", desc = "Hide " .. spec.name },
        },
      },
    })
    vim.b[term.buf][spec.cwd_var] = cwd
    vim.b[term.buf].aqua_agent = { id = spec.id, name = spec.name, icon = spec.icon, cwd = cwd }
    A.terms[cwd] = term
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = term.buf,
      once = true,
      callback = function()
        if A.terms[cwd] == term then
          A.terms[cwd] = nil
        end
      end,
    })
    return term
  end

  --- Открыть (или показать). Возвращает snacks.win и признак «только что создан».
  ---@param opts? aqua.agent.Opts
  ---@return snacks.win?, boolean?
  function A.open(opts)
    opts = opts or {}
    if not A.available() then
      vim.notify(spec.install_hint, vim.log.levels.ERROR, { title = title })
      return
    end
    local cwd = A.resolve_cwd(opts)
    local term = A.get(cwd)
    if term and opts.restart then
      term:close()
      term = nil
    end
    hide_others()
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

  --- Показать / скрыть для текущей директории.
  ---@param opts? aqua.agent.Opts
  ---@return snacks.win?
  function A.toggle(opts)
    opts = opts or {}
    -- Из окна агента — просто прячем его
    local cur_cwd = vim.b[vim.api.nvim_get_current_buf()][spec.cwd_var]
    if cur_cwd and A.get(cur_cwd) then
      A.terms[cur_cwd]:hide()
      return A.terms[cur_cwd]
    end
    local term = A.get(A.resolve_cwd(opts))
    if term and term:valid() then
      term:hide()
      return term
    end
    return (A.open(opts))
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

  --- Отправить текст (через bracketed paste, Enter не нажимается).
  ---@param text string
  ---@param opts? aqua.agent.Opts
  function A.send(text, opts)
    local term, fresh = A.open(opts)
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
  function A.relpath(buf, cwd)
    local file = vim.fs.normalize(vim.api.nvim_buf_get_name(buf))
    file = (vim.uv or vim.loop).fs_realpath(file) or file
    local rel = vim.fs.relpath and vim.fs.relpath(cwd, file)
    return rel or vim.fn.fnamemodify(file, ":~")
  end

  --- Добавить текущий файл в контекст: `@path/to/file `.
  function A.send_file()
    local buf = root.context_buf()
    if not root.is_file_buf(buf) then
      return vim.notify("Нет файла для отправки", vim.log.levels.WARN, { title = title })
    end
    A.send("@" .. A.relpath(buf, A.resolve_cwd()) .. " ")
  end

  --- Сформировать сообщение для выделенного фрагмента.
  ---@param buf integer
  ---@param l1 integer
  ---@param l2 integer
  ---@param cwd string
  function A.format_selection(buf, l1, l2, cwd)
    local lines = vim.api.nvim_buf_get_lines(buf, l1 - 1, l2, false)
    local ft = vim.bo[buf].filetype
    local range = l1 == l2 and ("L" .. l1) or ("L" .. l1 .. "-" .. l2)
    return ("@%s#%s\n```%s\n%s\n```\n"):format(A.relpath(buf, cwd), range, ft, table.concat(lines, "\n"))
  end

  --- Отправить визуальное выделение (с путём и номерами строк).
  function A.send_selection()
    local buf = vim.api.nvim_get_current_buf()
    local l1, l2 = vim.fn.line("v"), vim.fn.line(".")
    if l1 > l2 then
      l1, l2 = l2, l1
    end
    vim.api.nvim_feedkeys(vim.keycode("<esc>"), "nx", false)
    A.send(A.format_selection(buf, l1, l2, A.resolve_cwd()))
  end

  --- Отправить диагностику текущей строки.
  function A.send_diagnostics()
    local buf = vim.api.nvim_get_current_buf()
    local lnum = vim.api.nvim_win_get_cursor(0)[1]
    local diags = vim.diagnostic.get(buf, { lnum = lnum - 1 })
    if #diags == 0 then
      return vim.notify("На строке нет диагностик", vim.log.levels.INFO, { title = title })
    end
    local msgs = {}
    for _, d in ipairs(diags) do
      msgs[#msgs + 1] = ("- [%s] %s"):format(vim.diagnostic.severity[d.severity], d.message)
    end
    A.send(A.format_selection(buf, lnum, lnum, A.resolve_cwd()) .. "Диагностика:\n" .. table.concat(msgs, "\n") .. "\n")
  end

  --- Выбрать один из запущенных экземпляров.
  function A.select()
    local items = vim.tbl_keys(A.list())
    if #items == 0 then
      return vim.notify("Нет запущенных экземпляров " .. spec.name, vim.log.levels.INFO, { title = title })
    end
    table.sort(items)
    vim.ui.select(items, {
      prompt = spec.icon .. " " .. spec.name,
      format_item = function(cwd) return vim.fn.fnamemodify(cwd, ":~") end,
    }, function(cwd)
      if cwd then
        A.open({ cwd = cwd })
      end
    end)
  end

  --- Завершить экземпляр текущего проекта.
  ---@param opts? aqua.agent.Opts
  function A.kill(opts)
    local cwd = A.resolve_cwd(opts)
    local term = A.get(cwd)
    if term then
      term:close()
      A.terms[cwd] = nil
    end
  end

  --- Для статусной строки: иконка и число запущенных экземпляров.
  function A.status()
    local n = vim.tbl_count(A.list())
    if n == 0 then
      return ""
    end
    return spec.icon .. " " .. (n > 1 and n or "")
  end

  M.agents[spec.id] = A
  return A
end

return M
