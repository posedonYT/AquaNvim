-- desc: Markdown: marksman (LSP, ссылки между файлами) и markdownlint (проверка стиля)
-- Красивый рендер и режим чтения (Space m r) входят в ядро AquaNvim.
return {
  {
    "nvim-treesitter/nvim-treesitter",
    opts = { ensure_installed = { "markdown", "markdown_inline" } },
  },
  {
    "neovim/nvim-lspconfig",
    opts = { servers = { marksman = {} } },
  },
  { "mason-org/mason.nvim", opts = { ensure_installed = { "markdownlint-cli2" } } },
  {
    "mfussenegger/nvim-lint",
    opts = {
      linters_by_ft = { markdown = { "markdownlint-cli2" } },
      -- Замечания по стилю (длина строки и т. п.) не засоряют текст: остаются знаком на полях и в <leader>sd
      diagnostics = { ["markdownlint-cli2"] = { virtual_text = false, underline = false } },
    },
  },
}
