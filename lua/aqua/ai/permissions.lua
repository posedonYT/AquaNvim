-- Запрос разрешений: чтение — свободно, изменения/удаление/интернет — с подтверждением.
-- В окне подтверждения показывается diff. Клавиши: y — разрешить, a — разрешать эту категорию
-- до конца сессии, n / Esc — отклонить.
local M = {}

-- Вы можете печатать следующее сообщение, пока модель просит разрешение. Чтобы случайная
-- буква не разрешила действие, «разрешающие» клавиши (y / a / Enter) работают только если
-- вы в этот момент не печатаете; Ctrl-Y / Ctrl-A работают всегда, «отклонить» — тоже всегда.
local uv = vim.uv or vim.loop
M.last_key = 0
vim.on_key(function()
  M.last_key = uv.now()
end, vim.api.nvim_create_namespace("aqua_ai_keys"))

--- Печатает ли пользователь прямо сейчас (недавние клавиши или набранный текст в поле ввода).
function M.user_is_typing()
  if uv.now() - M.last_key < 1500 then
    return true
  end
  local root = vim.b[vim.api.nvim_get_current_buf()].aqua_ai_root
  local st = root and package.loaded["aqua.ai.ui"] and require("aqua.ai.ui").states[root]
  return st ~= nil and st.ed.text:match("%S") ~= nil
end

--- Переопределяемый обработчик (для тестов и пользовательских сценариев):
--- function(category, info, cb) где cb("yes"|"always"|"no").
---@type fun(category: string, info: table, cb: fun(decision: string))|nil
M.handler = nil

local CATEGORY_NAMES = {
  write = "изменение файлов", delete = "удаление", web = "интернет", read = "чтение",
  docs = "официальная документация", exec = "проверка компилятором",
}

---@param category string
---@param info { title: string, diff?: string }
---@param cb fun(decision: string)
local function prompt(category, info, cb, ctx)
  local lines = { " 󰌾 " .. info.title, "" }
  local hl = {}
  if info.diff and info.diff ~= "" then
    local diff = vim.split(info.diff:gsub("\n$", ""), "\n", { plain = true })
    local limit = 40
    for i, l in ipairs(diff) do
      if i > limit then
        lines[#lines + 1] = ("… ещё %d строк"):format(#diff - limit)
        break
      end
      lines[#lines + 1] = l
    end
    lines[#lines + 1] = ""
  end
  local armed = not M.user_is_typing()
  local function footer()
    if armed then
      return (" [y] разрешить   [a] разрешать «%s» до конца сессии   [n] отклонить "):format(CATEGORY_NAMES[category] or category)
    end
    return " Вы печатаете — разрешить: Ctrl-Y · всегда («" .. (CATEGORY_NAMES[category] or category) .. "»): Ctrl-A · отклонить: n / Esc "
  end
  lines[#lines + 1] = footer()

  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  width = math.min(math.max(width + 2, 50), vim.o.columns - 6)
  local height = math.min(#lines, vim.o.lines - 6)

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = "diff"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modifiable = false
  local prev = vim.api.nvim_get_current_win()
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " 󰖌 Aqua AI · разрешение ",
    title_pos = "center",
    zindex = 200,
  })
  vim.wo[win].winhighlight = "NormalFloat:AquaAIPrompt,FloatBorder:AquaAIPromptBorder,FloatTitle:AquaAIPromptTitle"
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false
  -- заголовок и подсказка
  local ns = vim.api.nvim_create_namespace("aqua_ai_prompt")
  vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, { line_hl_group = "AquaAIPromptTitle", priority = 200 })
  vim.api.nvim_buf_set_extmark(buf, ns, #lines - 1, 0, { line_hl_group = "AquaAIPromptKeys", priority = 200 })

  local opened = uv.now()
  local decided = false
  local timer
  local function stop_timer()
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end
  end
  -- Если вы печатали — «вооружаемся» после паузы в 2 секунды
  if not armed then
    timer = assert(uv.new_timer())
    timer:start(300, 300, vim.schedule_wrap(function()
      if decided or not vim.api.nvim_buf_is_valid(buf) then
        return stop_timer()
      end
      if uv.now() - M.last_key > 2000 then
        armed = true
        stop_timer()
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, #lines - 1, #lines, false, { footer() })
        vim.bo[buf].modifiable = false
      end
    end))
  end
  --- Разрешающая клавиша без Ctrl: только если вооружено и прошла короткая пауза после появления окна.
  local function plain_allowed()
    return armed and uv.now() - opened > 300
  end
  local function decide(decision)
    if decided then
      return
    end
    decided = true
    stop_timer()
    if ctx and ctx.session then
      ctx.session.cancel_prompt = nil
    end
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
    if vim.api.nvim_win_is_valid(prev) then
      pcall(vim.api.nvim_set_current_win, prev)
      -- вернулись в чат — можно сразу продолжать печатать
      if vim.bo[vim.api.nvim_win_get_buf(prev)].filetype == "aqua_ai" then
        vim.schedule(function() vim.cmd.startinsert() end)
      end
    end
    cb(decision)
  end
  if ctx and ctx.session then
    ctx.session.cancel_prompt = function() decide("no") end
  end
  vim.keymap.set("n", "<C-y>", function() decide("yes") end, { buffer = buf, nowait = true })
  vim.keymap.set("n", "<C-a>", function() decide("always") end, { buffer = buf, nowait = true })
  for _, key in ipairs({ "y", "<CR>" }) do
    vim.keymap.set("n", key, function() if plain_allowed() then decide("yes") end end, { buffer = buf, nowait = true })
  end
  vim.keymap.set("n", "a", function() if plain_allowed() then decide("always") end end, { buffer = buf, nowait = true })
  for _, key in ipairs({ "n", "q", "<Esc>", "<C-c>", "<C-n>" }) do
    vim.keymap.set("n", key, function() decide("no") end, { buffer = buf, nowait = true })
  end
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function() vim.schedule(function() decide("no") end) end,
  })
  vim.cmd.stopinsert()
end

---@param category string
---@param info { title: string, diff?: string }
---@param ctx aqua.ai.Ctx
---@param cb fun(allowed: boolean, note?: string)
function M.request(category, info, ctx, cb)
  local mode = ctx.cfg.permissions[category] or "ask"
  local session = ctx.session
  if mode ~= "deny" and session and (session.yolo or session.allowed[category]) then
    mode = "allow"
  end
  if mode == "allow" then
    return cb(true)
  elseif mode == "deny" then
    return cb(false, "запрещено настройками (permissions." .. category .. ")")
  end
  local function handle(decision)
    if decision == "always" then
      if session then session.allowed[category] = true end
      return cb(true)
    end
    cb(decision == "yes")
  end
  if session and session.emit_status then
    session:emit_status("approval")
  end
  if M.handler then
    return M.handler(category, info, handle)
  end
  prompt(category, info, handle, ctx)
end

return M
