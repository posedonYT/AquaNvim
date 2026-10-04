return {
  -- Движок темы aqua
  {
    "folke/tokyonight.nvim",
    lazy = false,
    priority = 1000,
    config = function()
      vim.cmd.colorscheme("aqua")
    end,
  },

  -- Иконки
  {
    "echasnovski/mini.icons",
    lazy = true,
    opts = {
      file = {
        ["aquanvim.json"] = { glyph = "󰖌", hl = "MiniIconsCyan" },
        [".keep"] = { glyph = "󰊢", hl = "MiniIconsGrey" },
      },
    },
    init = function()
      package.preload["nvim-web-devicons"] = function()
        require("mini.icons").mock_nvim_web_devicons()
        return package.loaded["nvim-web-devicons"]
      end
    end,
  },

  -- Статусная строка
  {
    "nvim-lualine/lualine.nvim",
    event = "VeryLazy",
    init = function()
      vim.g.lualine_laststatus = vim.o.laststatus
      if vim.fn.argc(-1) > 0 then
        vim.o.statusline = " " -- пустая строка до загрузки lualine
      else
        vim.o.laststatus = 0 -- прячем на дашборде
      end
    end,
    opts = function()
      vim.o.laststatus = vim.g.lualine_laststatus
      local p = require("aqua.theme.palette")
      local root = require("aqua.util.root")

      local function root_name()
        if not root.is_file_buf(0) then
          return ""
        end
        return "󱂵 " .. vim.fn.fnamemodify(root.get(0), ":t")
      end

      local function lsp_clients()
        local names = {}
        for _, c in ipairs(vim.lsp.get_clients({ bufnr = 0 })) do
          names[#names + 1] = c.name
        end
        return #names > 0 and ("󰒋 " .. table.concat(names, " ")) or ""
      end

      return {
        options = {
          theme = require("aqua.theme").lualine(),
          globalstatus = true,
          component_separators = { left = "\u{e0b5}", right = "\u{e0b7}" },
          section_separators = { left = "\u{e0b4}", right = "\u{e0b6}" },
          disabled_filetypes = { statusline = { "snacks_dashboard" } },
        },
        sections = {
          lualine_a = { { "mode", icon = "󰖌" } },
          lualine_b = { { "branch", icon = "\u{e725}" } },
          lualine_c = {
            { root_name, color = { fg = p.sunset, gui = "bold" } },
            { "diagnostics", symbols = { error = "\u{f057} ", warn = "\u{f071} ", info = "\u{f05a} ", hint = "󰌵 " } },
            { "filetype", icon_only = true, separator = "", padding = { left = 1, right = 0 } },
            {
              "filename",
              path = 1,
              symbols = { modified = " ●", readonly = " 󰌾", unnamed = "" },
              cond = function() return vim.bo.buftype ~= "terminal" end,
            },
            {
              function()
                local cwd = vim.b.aqua_claude_cwd
                if cwd then
                  return "󰚩 Claude · " .. vim.fn.fnamemodify(cwd, ":~")
                end
                return "\u{f120} " .. vim.fn.fnamemodify(vim.fn.getcwd(), ":~")
              end,
              cond = function() return vim.bo.buftype == "terminal" end,
              color = { fg = p.sunset, gui = "bold" },
            },
          },
          lualine_x = {
            {
              function() return require("aqua.claude").status() end,
              color = { fg = p.sunset, gui = "bold" },
            },
            {
              function() return require("noice").api.status.mode.get() end,
              cond = function() return package.loaded["noice"] and require("noice").api.status.mode.has() end,
              color = { fg = p.jelly },
            },
            {
              function() return "\u{f188} " .. require("dap").status() end,
              cond = function() return package.loaded["dap"] and require("dap").status() ~= "" end,
              color = { fg = p.coral },
            },
            { "diff", symbols = { added = "\u{f457} ", modified = "\u{f459} ", removed = "\u{f458} " } },
            { lsp_clients, color = { fg = p.mist } },
          },
          lualine_y = {
            { "progress", separator = " ", padding = { left = 1, right = 0 } },
            { "location", padding = { left = 0, right = 1 } },
          },
          lualine_z = {
            function() return "󰥔 " .. os.date("%H:%M") end,
          },
        },
        extensions = { "lazy", "fzf", "quickfix", "trouble", "mason" },
      }
    end,
  },

  -- Вкладки буферов
  {
    "akinsho/bufferline.nvim",
    event = "VeryLazy",
    keys = {
      { "<leader>bp", "<cmd>BufferLineTogglePin<cr>", desc = "Toggle Pin" },
      { "<leader>bP", "<cmd>BufferLineGroupClose ungrouped<cr>", desc = "Delete Non-Pinned Buffers" },
      { "<leader>br", "<cmd>BufferLineCloseRight<cr>", desc = "Delete Buffers to the Right" },
      { "<leader>bl", "<cmd>BufferLineCloseLeft<cr>", desc = "Delete Buffers to the Left" },
      { "[B", "<cmd>BufferLineMovePrev<cr>", desc = "Move Buffer Prev" },
      { "]B", "<cmd>BufferLineMoveNext<cr>", desc = "Move Buffer Next" },
    },
    opts = function()
      local p = require("aqua.theme.palette")
      return {
        options = {
          close_command = function(n) Snacks.bufdelete(n) end,
          right_mouse_command = function(n) Snacks.bufdelete(n) end,
          diagnostics = "nvim_lsp",
          always_show_bufferline = false,
          separator_style = "thin",
          indicator = { style = "underline" },
          modified_icon = "●",
          diagnostics_indicator = function(_, _, diag)
            local icons = { error = "\u{f057} ", warning = "\u{f071} " }
            local ret = (diag.error and icons.error .. diag.error .. " " or "")
              .. (diag.warning and icons.warning .. diag.warning or "")
            return vim.trim(ret)
          end,
          offsets = {
            { filetype = "snacks_layout_box", text = "󰖌 Explorer", highlight = "Directory", separator = true },
          },
          get_element_icon = function(opts)
            return require("mini.icons").get("filetype", opts.filetype)
          end,
        },
        highlights = {
          buffer_selected = { fg = p.foam, bold = true, italic = false },
          indicator_selected = { fg = p.turquoise, sp = p.turquoise },
          modified_selected = { fg = p.sand },
          fill = { bg = p.abyss },
        },
      }
    end,
    config = function(_, opts)
      require("bufferline").setup(opts)
      -- Обновляем bufferline после восстановления сессии
      vim.api.nvim_create_autocmd({ "BufAdd", "BufDelete", "SessionLoadPost" }, {
        callback = function()
          vim.schedule(function() pcall(nvim_bufferline) end)
        end,
      })
    end,
  },
}
