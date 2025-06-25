local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system({
    "git", "clone", "--filter=blob:none",
    "https://github.com/folke/lazy.nvim", lazypath
  })
end
vim.opt.rtp:prepend(lazypath)

-- Функция для безопасного подключения модулей
local function safe_require(module_name)
  local ok, module = pcall(require, module_name)
  if ok and type(module) == "table" then
    return module
  else
    print("Warning: Module " .. module_name .. " not found or invalid")
    return {}
  end
end

-- Собираем все плагины
local plugins = {}

-- Добавляем плагины из каждого модуля
vim.list_extend(plugins, safe_require("plugins.ui"))
vim.list_extend(plugins, safe_require("plugins.lsp"))
vim.list_extend(plugins, safe_require("plugins.completion"))
vim.list_extend(plugins, safe_require("plugins.treesitter"))
vim.list_extend(plugins, safe_require("plugins.rust"))

require("lazy").setup(plugins)
