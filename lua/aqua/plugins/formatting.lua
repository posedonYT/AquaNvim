-- Форматирование (conform) и линтинг (nvim-lint). Extras добавляют formatters_by_ft / linters_by_ft.
return {
  {
    "stevearc/conform.nvim",
    event = "BufWritePre",
    cmd = "ConformInfo",
    keys = {
      { "<leader>lf", function() require("conform").format({ async = true, lsp_format = "fallback" }) end, mode = { "n", "x" }, desc = "Format" },
    },
    opts = {
      formatters_by_ft = {
        lua = { "stylua" },
      },
      default_format_opts = { lsp_format = "fallback", timeout_ms = 3000 },
      format_on_save = function(buf)
        if vim.g.autoformat == false or vim.b[buf].autoformat == false then
          return
        end
        return {}
      end,
    },
  },

  {
    "mfussenegger/nvim-lint",
    event = { "BufReadPost", "BufNewFile", "BufWritePost" },
    opts = { linters_by_ft = {} },
    config = function(_, opts)
      local lint = require("lint")
      lint.linters_by_ft = opts.linters_by_ft
      vim.api.nvim_create_autocmd({ "BufWritePost", "BufReadPost", "InsertLeave" }, {
        group = vim.api.nvim_create_augroup("aqua_lint", { clear = true }),
        callback = function()
          -- Запускаем только установленные линтеры, чтобы не сыпать ошибками
          local names = lint._resolve_linter_by_ft(vim.bo.filetype)
          names = vim.tbl_filter(function(name)
            local linter = lint.linters[name]
            local cmd = type(linter) == "table" and linter.cmd
            if type(cmd) == "function" then cmd = cmd() end
            return cmd and vim.fn.executable(cmd) == 1
          end, names)
          if #names > 0 then
            lint.try_lint(names)
          end
        end,
      })
    end,
  },
}
