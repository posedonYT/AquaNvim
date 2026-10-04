-- desc: Docker: dockerls, docker compose LS, hadolint
return {
  {
    "nvim-treesitter/nvim-treesitter",
    opts = { ensure_installed = { "dockerfile" } },
  },
  {
    "neovim/nvim-lspconfig",
    opts = { servers = { dockerls = {}, docker_compose_language_service = {} } },
  },
  { "mason-org/mason.nvim", opts = { ensure_installed = { "hadolint" } } },
  {
    "mfussenegger/nvim-lint",
    opts = { linters_by_ft = { dockerfile = { "hadolint" } } },
  },
}
