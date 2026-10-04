-- desc: Markdown: marksman, красивый рендер прямо в буфере, markdownlint
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
    opts = { linters_by_ft = { markdown = { "markdownlint-cli2" } } },
  },
  {
    "MeanderingProgrammer/render-markdown.nvim",
    ft = { "markdown" },
    opts = {
      code = { sign = false, width = "block", right_pad = 1 },
      heading = { sign = false, icons = { "󰲡 ", "󰲣 ", "󰲥 ", "󰲧 ", "󰲩 ", "󰲫 " } },
      checkbox = { enabled = true },
    },
    keys = {
      { "<leader>um", function() require("render-markdown").toggle() end, desc = "Toggle Markdown Render", ft = "markdown" },
    },
  },
}
