return {
  { 
    "catppuccin/nvim", 
    name = "catppuccin", 
    priority = 1000,
    config = function()
      vim.cmd.colorscheme "catppuccin"
    end
  },
  {
    "nvim-lualine/lualine.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    config = function()
      require('lualine').setup({
        options = {
          theme = 'catppuccin',
          component_separators = { left = '', right = '' },
          section_separators = { left = '', right = '' },
        },
        sections = {
          lualine_a = {'mode'},
          lualine_b = {'branch', 'diff', 'diagnostics'},
          lualine_c = {'filename'},
          lualine_x = {'encoding', 'fileformat', 'filetype'},
          lualine_y = {'progress'},
          lualine_z = {'location'}
        },
      })
    end
  },
  {
    "nvim-tree/nvim-tree.lua",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    config = function()
      -- disable netrw
      vim.g.loaded_netrw = 1
      vim.g.loaded_netrwPlugin = 1
      
      require("nvim-tree").setup({
        view = { width = 30 },
        renderer = { group_empty = true },
        filters = { dotfiles = false },
      })
      
      -- Keymaps
      vim.keymap.set('n', '<C-n>', ':NvimTreeToggle<CR>', { silent = true })
    end
  },
  {
    "nvimdev/dashboard-nvim",
    event = "VimEnter",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    config = function()
      require("dashboard").setup({
        theme = "hyper",
        config = {
          header = {
                    "    _                      ____          _      ",
                    "   / \\   __ _ _   _  __ _ / ___|___   __| | ___ ",
                    "  / _ \\ / _` | | | |/ _` | |   / _ \\ / _` |/ _ \\",
                    " / ___ \\ (_| | |_| | (_| | |__| (_) | (_| |  __/",
                    "/_/   \\_\\__, |\\__,_|\\__,_|\\____\\___/ \\__,_|\\___|",
                    "           |_|                                 ",
                    "                    AquaCode                   ",
                  },
          shortcut = {
            { desc = "📝 New file", group = "Label", action = "ene | startinsert", key = "e" },
            { desc = "📂 File Explorer", group = "Label", action = "NvimTreeToggle", key = "<leader>e" },
            { desc = "🔍 Find Files", group = "Label", action = "Telescope find_files", key = "<leader>ff" },
            { desc = "💾 Save File", group = "Label", action = "w", key = "<C-s>" },
            { desc = "🗑️ Close Buffer", group = "Label", action = "bd", key = "<leader>c" },
            { desc = "🖱️ Select All", group = "Label", action = "ggVG", key = "<C-a>" },
            { desc = "🚪 Quit", group = "Label", action = "qa", key = "q" },
          },
          mru = { limit = 0, enable = false }, -- Отключаем Recent Files
          project = { enable = false }, -- Отключаем Recent Projects
        },
      })
    end
  },
  {
    "akinsho/bufferline.nvim",
    dependencies = { "nvim-tree/nvim-web-devicons" },
    config = true,
  },
}