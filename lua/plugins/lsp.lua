return {
  {
    "neovim/nvim-lspconfig",
  },
  {
    "williamboman/mason.nvim",
    build = ":MasonUpdate",
    config = true,
  },
  {
    "prisma/vim-prisma",
    ft = "prisma"
  },
  {
    "williamboman/mason-lspconfig.nvim",
    config = function()
      require("mason").setup()
      require("mason-lspconfig").setup({
        ensure_installed = { "lua_ls", "ts_ls", "pyright", "rust_analyzer", "vtsls", "prismals" },
      })

      local lspconfig = require("lspconfig")
      for _, server in ipairs({ "lua_ls", "ts_ls", "pyright", "rust_analyzer", "vtsls", "prismals" }) do
        lspconfig[server].setup({})
      end
    end
  }
}
