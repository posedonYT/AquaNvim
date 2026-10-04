-- desc: Rust: rustaceanvim (rust-analyzer + clippy), crates.nvim, taplo
return {
  {
    "nvim-treesitter/nvim-treesitter",
    opts = { ensure_installed = { "rust", "ron", "toml" } },
  },
  { "mason-org/mason.nvim", opts = { ensure_installed = { "rust-analyzer" } } },
  {
    "mrcjkb/rustaceanvim",
    version = "^6",
    ft = { "rust" },
    init = function()
      vim.g.rustaceanvim = {
        server = {
          on_attach = function(_, buf)
            vim.keymap.set("n", "<leader>la", function() vim.cmd.RustLsp("codeAction") end, { buffer = buf, desc = "Code Action (Rust)" })
            vim.keymap.set("n", "<leader>dr", function() vim.cmd.RustLsp("debuggables") end, { buffer = buf, desc = "Rust Debuggables" })
            vim.keymap.set("n", "<leader>lx", function() vim.cmd.RustLsp("explainError") end, { buffer = buf, desc = "Explain Error" })
          end,
          default_settings = {
            ["rust-analyzer"] = {
              cargo = { allFeatures = true, loadOutDirsFromCheck = true, buildScripts = { enable = true } },
              check = { command = "clippy" },
              procMacro = { enable = true },
            },
          },
        },
      }
    end,
  },
  {
    "saecki/crates.nvim",
    event = { "BufRead Cargo.toml" },
    opts = {
      completion = { crates = { enabled = true } },
      lsp = { enabled = true, actions = true, completion = true, hover = true },
    },
  },
  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        taplo = {},
        rust_analyzer = false, -- запускает rustaceanvim
      },
    },
  },
}
