-- ≋≋≋ AquaNvim ≋≋≋
-- Точка входа. Вся логика живёт в lua/aqua, пользовательские плагины — в lua/custom/plugins.
vim.g.mapleader = " "
vim.g.maplocalleader = " "

require("aqua").setup()
