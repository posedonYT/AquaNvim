-- desc: Python: pyright, ruff (линт + формат), treesitter
return {
  {
    "nvim-treesitter/nvim-treesitter",
    opts = { ensure_installed = { "python", "ninja", "rst" } },
  },
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        pyright = {
          settings = {
            pyright = { disableOrganizeImports = true },
            python = { analysis = { typeCheckingMode = "basic", autoImportCompletions = true } },
          },
        },
        ruff = {
          on_attach = function(client)
            client.server_capabilities.hoverProvider = false -- hover отдаём pyright
          end,
        },
      },
    },
  },
  {
    "stevearc/conform.nvim",
    opts = { formatters_by_ft = { python = { "ruff_organize_imports", "ruff_format" } } },
  },
}
