local opt = vim.opt

-- Глобальные переключатели AquaNvim (можно переопределить в lua/custom/*)
vim.g.autoformat = true -- форматирование при сохранении (<leader>uf)
vim.g.aqua_autorestore = false -- восстанавливать сессию при запуске `nvim` без аргументов
vim.g.aqua_transparent = vim.g.aqua_transparent or false
vim.g.aqua_claude_cmd = vim.g.aqua_claude_cmd or "claude"
vim.g.aqua_claude_width = vim.g.aqua_claude_width or 0.4

-- Отображение
opt.number = true
opt.relativenumber = true
opt.termguicolors = true
opt.cursorline = true
opt.signcolumn = "yes"
opt.showmode = false -- режим показывает lualine
opt.laststatus = 3 -- одна статусная строка на весь экран
opt.cmdheight = 1
opt.pumheight = 12
opt.pumblend = 8
opt.winborder = "rounded"
opt.scrolloff = 6
opt.sidescrolloff = 8
opt.wrap = false
opt.linebreak = true
opt.list = true
opt.listchars = { tab = "» ", trail = "·", nbsp = "␣" }
opt.fillchars = { eob = " ", fold = " ", foldopen = "\u{f47c}", foldclose = "\u{f460}", foldsep = " ", diff = "╱" }
opt.smoothscroll = true

-- Отступы (как в оригинальном AquaNvim)
opt.tabstop = 4
opt.shiftwidth = 4
opt.expandtab = true
opt.shiftround = true
opt.smartindent = true

-- Поиск
opt.ignorecase = true
opt.smartcase = true
opt.inccommand = "nosplit"
opt.grepprg = "rg --vimgrep"
opt.grepformat = "%f:%l:%c:%m"

-- Окна и поведение
opt.splitright = true
opt.splitbelow = true
opt.splitkeep = "screen"
opt.mouse = "a"
opt.confirm = true
opt.undofile = true
opt.undolevels = 10000
opt.updatetime = 200
opt.timeoutlen = 300
opt.autoread = true -- подхватываем правки, сделанные Claude CLI
opt.virtualedit = "block"
opt.wildmode = "longest:full,full"
opt.completeopt = "menu,menuone,noselect"
opt.shortmess:append({ W = true, I = true, c = true, C = true })

-- Сворачивание через treesitter
opt.foldlevel = 99
opt.foldmethod = "expr"
opt.foldexpr = "v:lua.vim.treesitter.foldexpr()"
opt.foldtext = ""

-- Сессии: не сохраняем терминалы, пустые и служебные буферы
opt.sessionoptions = { "buffers", "curdir", "tabpages", "winsize", "globals", "skiprtp" }

-- Системный буфер обмена (асинхронно, чтобы не тормозить старт)
vim.schedule(function()
  opt.clipboard = vim.env.SSH_TTY and "" or "unnamedplus"
end)

vim.g.markdown_recommended_style = 0
