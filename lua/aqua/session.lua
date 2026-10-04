-- Сессии AquaNvim поверх persistence.nvim:
--  * отдельная сессия на каждую директорию + git-ветку;
--  * перед сохранением закрываются служебные окна (explorer, Claude, терминалы, дашборд),
--    чтобы при восстановлении не появлялись пустые «мёртвые» окна;
--  * при смене проекта (:cd, picker проектов) сессия старого проекта сохраняется автоматически;
--  * опционально — автовосстановление при запуске `nvim` без аргументов.
local M = {}

M.loading = false

local special_ft = {
  snacks_dashboard = true,
  snacks_picker_list = true,
  snacks_picker_input = true,
  snacks_picker_preview = true,
  snacks_layout_box = true,
  snacks_terminal = true,
  snacks_notif = true,
  lazy = true,
  mason = true,
  trouble = true,
  ["neo-tree"] = true,
  dbui = true,
  help = true,
  qf = true,
}

---@param win integer
function M.is_special_win(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local bt = vim.bo[buf].buftype
  return special_ft[vim.bo[buf].filetype] == true or bt == "terminal" or bt == "prompt"
    or (bt == "nofile" and vim.api.nvim_win_get_config(win).relative ~= "")
end

--- Закрывает служебные окна. Если закрыть нельзя (последнее окно) — пропускаем.
function M.cleanup()
  -- explorer / picker закрываем через snacks, чтобы корректно разрушить layout
  local ok, Snacks = pcall(require, "snacks")
  if ok and Snacks.picker then
    for _, p in ipairs(Snacks.picker.get() or {}) do
      pcall(function() p:close() end)
    end
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and M.is_special_win(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

local function has_file_buffers()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.bo[buf].buflisted and require("aqua.util.root").is_file_buf(buf) then
      return true
    end
  end
  return false
end

--- Сохранить сессию прямо сейчас (persistence сам чистит окна только при выходе).
--- Claude при этом лишь скрывается — процесс продолжает работать.
---@param opts? { reopen?: boolean } вернуть explorer после сохранения
function M.save(opts)
  local ok, persistence = pcall(require, "persistence")
  if not (ok and persistence.active() and has_file_buffers()) then
    return false
  end
  local had_explorer = ok and Snacks and #Snacks.picker.get({ source = "explorer" }) > 0
  local win = vim.api.nvim_get_current_win()
  M.cleanup()
  persistence.save()
  if vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
  end
  if opts and opts.reopen and had_explorer then
    Snacks.explorer()
    vim.api.nvim_set_current_win(win)
  end
  return true
end

function M.setup_autocmds()
  local group = vim.api.nvim_create_augroup("aqua_session", { clear = true })

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "PersistenceSavePre",
    callback = M.cleanup,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "PersistenceLoadPre",
    callback = function()
      M.loading = true
      M.cleanup()
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "PersistenceLoadPost",
    callback = function()
      M.loading = false
      vim.schedule(function()
        vim.notify("Сессия восстановлена: " .. vim.fn.fnamemodify(vim.fn.getcwd(), ":~"), vim.log.levels.INFO, { title = "AquaNvim" })
      end)
    end,
  })

  -- Перед глобальной сменой директории сохраняем сессию текущего проекта
  vim.api.nvim_create_autocmd("DirChangedPre", {
    group = group,
    callback = function()
      if vim.v.event.scope == "global" and not M.loading and vim.v.vim_did_enter == 1 then
        M.save()
      end
    end,
  })

  -- Автовосстановление: `nvim` без аргументов в папке с сохранённой сессией
  vim.api.nvim_create_autocmd("VimEnter", {
    group = group,
    nested = true,
    callback = function()
      if not vim.g.aqua_autorestore or vim.fn.argc(-1) > 0 or vim.g.aqua_started_with_stdin then
        return
      end
      local ok, persistence = pcall(require, "persistence")
      if ok and vim.fn.filereadable(persistence.current()) == 1 then
        persistence.load()
      end
    end,
  })
  vim.api.nvim_create_autocmd("StdinReadPre", {
    group = group,
    callback = function()
      vim.g.aqua_started_with_stdin = true
    end,
  })
end

return M
