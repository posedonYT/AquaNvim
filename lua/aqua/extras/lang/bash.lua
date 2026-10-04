-- desc: Bash / Shell: bashls, shellcheck, shfmt
return {
  {
    "nvim-treesitter/nvim-treesitter",
    opts = { ensure_installed = { "bash" } },
  },
  {
    "neovim/nvim-lspconfig",
    opts = { servers = { bashls = {} } },
  },
  { "mason-org/mason.nvim", opts = { ensure_installed = { "shellcheck", "shfmt" } } },
  {
    "stevearc/conform.nvim",
    opts = { formatters_by_ft = { sh = { "shfmt" }, bash = { "shfmt" }, zsh = { "shfmt" } } },
  },
}
