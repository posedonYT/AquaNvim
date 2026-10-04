-- LSP на нативном API Neovim 0.11 (vim.lsp.config / vim.lsp.enable).
-- Extras добавляют серверы через opts.servers, инструменты — через mason opts.ensure_installed.
local auto_install = not require("aqua").headless_test

local function on_attach(client, buf)
  local function map(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { buffer = buf, desc = desc, silent = true })
  end
  map("n", "gd", function() Snacks.picker.lsp_definitions() end, "Goto Definition")
  map("n", "gr", function() Snacks.picker.lsp_references() end, "References")
  map("n", "gI", function() Snacks.picker.lsp_implementations() end, "Goto Implementation")
  map("n", "gy", function() Snacks.picker.lsp_type_definitions() end, "Goto Type Definition")
  map("n", "gD", vim.lsp.buf.declaration, "Goto Declaration")
  map("n", "K", function() vim.lsp.buf.hover({ border = "rounded" }) end, "Hover")
  map("n", "gK", function() vim.lsp.buf.signature_help({ border = "rounded" }) end, "Signature Help")
  map("i", "<C-k>", function() vim.lsp.buf.signature_help({ border = "rounded" }) end, "Signature Help")
  map({ "n", "x" }, "<leader>la", vim.lsp.buf.code_action, "Code Action")
  map("n", "<leader>lr", vim.lsp.buf.rename, "Rename")
  map("n", "<leader>lR", function() Snacks.rename.rename_file() end, "Rename File")
  map("n", "<leader>ld", vim.diagnostic.open_float, "Line Diagnostics")
  map("n", "<leader>li", "<cmd>checkhealth vim.lsp<cr>", "LSP Info")
  map("n", "<leader>ll", "<cmd>LspRestart<cr>", "Restart LSP")
  map({ "n", "x" }, "<leader>lc", vim.lsp.codelens.run, "Run Codelens")
  map("n", "<leader>ls", function() Snacks.picker.lsp_symbols() end, "Document Symbols")
  map("n", "]]", function() Snacks.words.jump(vim.v.count1) end, "Next Reference")
  map("n", "[[", function() Snacks.words.jump(-vim.v.count1) end, "Prev Reference")
  if client:supports_method("textDocument/inlayHint") and vim.bo[buf].buftype == "" then
    vim.lsp.inlay_hint.enable(true, { bufnr = buf })
  end
end

return {
  -- Менеджер LSP-серверов, форматтеров и линтеров
  {
    "mason-org/mason.nvim",
    cmd = "Mason",
    build = ":MasonUpdate",
    opts_extend = { "ensure_installed" },
    opts = {
      ensure_installed = { "stylua" },
      ui = {
        border = "rounded",
        icons = { package_installed = "󰖌", package_pending = "➜", package_uninstalled = "○" },
      },
    },
    config = function(_, opts)
      require("mason").setup(opts)
      if not auto_install then
        return
      end
      local mr = require("mason-registry")
      mr.refresh(function()
        for _, tool in ipairs(opts.ensure_installed or {}) do
          local ok, pkg = pcall(mr.get_package, tool)
          if ok and not pkg:is_installed() and not pkg:is_installing() then
            pkg:install()
          end
        end
      end)
    end,
  },

  {
    "neovim/nvim-lspconfig",
    event = { "BufReadPre", "BufNewFile" },
    dependencies = {
      "mason-org/mason.nvim",
      "mason-org/mason-lspconfig.nvim",
    },
    opts = {
      ---@type vim.diagnostic.Opts
      diagnostics = {
        underline = true,
        update_in_insert = false,
        severity_sort = true,
        virtual_text = { spacing = 4, source = "if_many", prefix = "●" },
        float = { border = "rounded", source = true },
        signs = {
          text = {
            [vim.diagnostic.severity.ERROR] = "\u{f057} ",
            [vim.diagnostic.severity.WARN] = "\u{f071} ",
            [vim.diagnostic.severity.HINT] = "󰌵",
            [vim.diagnostic.severity.INFO] = "\u{f05a} ",
          },
        },
      },
      --- Серверы: имя → конфиг для vim.lsp.config. `false` — отключить, mason = false — не ставить через mason.
      ---@type table<string, table|false>
      servers = {
        lua_ls = {
          settings = {
            Lua = {
              workspace = { checkThirdParty = false },
              completion = { callSnippet = "Replace" },
              hint = { enable = true, setType = false, paramType = true, arrayIndex = "Disable" },
              diagnostics = { globals = { "vim", "Snacks" } },
            },
          },
        },
      },
      --- Кастомная настройка: вернуть true, чтобы AquaNvim не трогал сервер (например rustaceanvim).
      ---@type table<string, fun(server: string, config: table): boolean?>
      setup = {},
    },
    config = function(_, opts)
      vim.diagnostic.config(vim.deepcopy(opts.diagnostics))

      vim.api.nvim_create_autocmd("LspAttach", {
        group = vim.api.nvim_create_augroup("aqua_lsp_attach", { clear = true }),
        callback = function(ev)
          local client = vim.lsp.get_client_by_id(ev.data.client_id)
          if client then
            on_attach(client, ev.buf)
          end
        end,
      })

      local has_blink, blink = pcall(require, "blink.cmp")
      vim.lsp.config("*", {
        capabilities = has_blink and blink.get_lsp_capabilities() or vim.lsp.protocol.make_client_capabilities(),
      })

      local mason_servers = {}
      for server, conf in pairs(opts.servers) do
        if conf then
          conf = vim.deepcopy(conf)
          local use_mason = conf.mason ~= false
          conf.mason = nil
          local custom = opts.setup[server] or opts.setup["*"]
          if not (custom and custom(server, conf)) then
            vim.lsp.config(server, conf)
            vim.lsp.enable(server)
          end
          if use_mason then
            mason_servers[#mason_servers + 1] = server
          end
        end
      end

      require("mason-lspconfig").setup({
        ensure_installed = auto_install and mason_servers or {},
        automatic_enable = false, -- включаем сами выше
      })
    end,
  },

  { "mason-org/mason-lspconfig.nvim", lazy = true, config = function() end },

  -- Lua: автодополнение API Neovim при редактировании конфига
  {
    "folke/lazydev.nvim",
    ft = "lua",
    cmd = "LazyDev",
    opts = {
      library = {
        { path = "${3rd}/luv/library", words = { "vim%.uv" } },
        { path = "snacks.nvim", words = { "Snacks" } },
        { path = "lazy.nvim", words = { "LazySpec" } },
      },
    },
  },
}
