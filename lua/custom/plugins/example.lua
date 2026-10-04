-- Ваши собственные плагины. Любой файл в lua/custom/plugins/ подключается автоматически.
-- Формат — обычная lazy.nvim спека: https://lazy.folke.io/spec
--
-- Примеры (раскомментируйте нужное):
return {
  -- Новый плагин:
  -- { "folke/zen-mode.nvim", cmd = "ZenMode", opts = {} },

  -- Переопределить настройки встроенного плагина AquaNvim (опции сливаются):
  -- { "folke/snacks.nvim", opts = { dashboard = { width = 60 } } },

  -- Добавить LSP-сервер без отдельного extra:
  -- { "neovim/nvim-lspconfig", opts = { servers = { zls = {} } } },

  -- Отключить плагин ядра:
  -- { "folke/flash.nvim", enabled = false },
}
