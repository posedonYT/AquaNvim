return {
    {
  "simrat39/rust-tools.nvim",
  dependencies = "neovim/nvim-lspconfig",
  config = function()
    require("rust-tools").setup({
      server = {
            on_attach = function(_, bufnr)
            vim.keymap.set("n", "K", vim.lsp.buf.hover, { buffer = bufnr })
            vim.keymap.set("n", "gd", vim.lsp.buf.definition, { buffer = bufnr })
            end,
            settings = {
            ["rust-analyzer"] = {
                checkOnSave = { command = "clippy" },
                procMacro = { enable = true }
                }
            }
        }
    })
    end
    },
    {
        "saecki/crates.nvim",
        event = "BufRead Cargo.toml",
        config = true
    }
}
