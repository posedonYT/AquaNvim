return {
  {
  "folke/tokyonight.nvim",
  priority = 1000,
  config = function()
    require("tokyonight").setup({
        style = "storm",
        transparent = false,
    })
    vim.cmd.colorscheme("tokyonight-storm")
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
                    "                    AquaNvim                   ",
                  },
          shortcut = {
            { desc = "📂 File Explorer", group = "Label", action = "NvimTreeToggle", key = "Space + e" },
            { desc = "🔍 Find Files", group = "Label", action = "Telescope find_files", key = "ff" },
            { desc = "💾 Save File", group = "Label", action = "w", key = "Ctrl + s" },
            { desc = "🗑️ Close Buffer", group = "Label", action = "bd", key = "Space + c" },
            { desc = "🖱️ Select All", group = "Label", action = "ggVG", key = "Ctrl + a" },
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
  {
  "windwp/nvim-autopairs",
  event = "InsertEnter",
  config = function()
    require("nvim-autopairs").setup({
      disable_filetype = { "TelescopePrompt", "spectre_panel" },
      fast_wrap = {}, -- Автоматический выбор при быстром наборе
    })
    end
  }
}
