local M = {}

M.version = "2.0.0"

--- Тестовый / CI режим: не ставим LSP-серверы и парсеры автоматически.
M.headless_test = vim.env.AQUA_TEST == "1"

local function bootstrap_lazy()
  local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
  if not (vim.uv or vim.loop).fs_stat(lazypath) then
    local out = vim.fn.system({
      "git", "clone", "--filter=blob:none", "--branch=stable",
      "https://github.com/folke/lazy.nvim.git", lazypath,
    })
    if vim.v.shell_error ~= 0 then
      vim.api.nvim_echo({
        { "Не удалось склонировать lazy.nvim:\n", "ErrorMsg" },
        { out, "WarningMsg" },
      }, true, {})
      return false
    end
  end
  vim.opt.rtp:prepend(lazypath)
  return true
end

--- Есть ли хотя бы один файл в lua/custom/plugins (иначе lazy ругается на пустой import).
local function has_custom_plugins()
  local dir = vim.fn.stdpath("config") .. "/lua/custom/plugins"
  for name, type in vim.fs.dir(dir) do
    if (type == "file" and name:match("%.lua$")) or type == "directory" then
      return true
    end
  end
  return false
end

function M.spec()
  local spec = { { import = "aqua.plugins" } }
  vim.list_extend(spec, require("aqua.extras").spec())
  if has_custom_plugins() then
    table.insert(spec, { import = "custom.plugins" })
  end
  return spec
end

function M.setup()
  require("aqua.config.options")
  if not bootstrap_lazy() then
    return
  end

  -- Автокоманды и бинды грузим заранее (до VeryLazy), чтобы дашборд их уже видел.
  require("aqua.config.autocmds")
  require("aqua.config.keymaps")

  require("lazy").setup({
    spec = M.spec(),
    defaults = { lazy = false, version = false },
    install = { colorscheme = { "aqua", "habamax" }, missing = true },
    checker = { enabled = not M.headless_test, notify = false },
    change_detection = { notify = false },
    ui = {
      border = "rounded",
      title = " 󰖌 AquaNvim · Lazy ",
      backdrop = 70,
    },
    performance = {
      rtp = {
        disabled_plugins = {
          "gzip", "tarPlugin", "tohtml", "tutor", "zipPlugin", "netrwPlugin",
        },
      },
    },
  })

  require("aqua.extras").create_command()
end

return M
