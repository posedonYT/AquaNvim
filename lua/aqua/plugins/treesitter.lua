local headless = require("aqua").headless_test

--- Ставит недостающие парсеры. nvim-treesitter пишет прогресс через print(),
--- что в узком терминале вызывает «Press ENTER» — поэтому на время установки
--- перенаправляем вывод в одно обновляемое уведомление.
local function install_missing(langs)
  local parsers = require("nvim-treesitter.parsers")
  local missing = vim.tbl_filter(function(lang)
    return parsers.get_parser_configs()[lang] and not parsers.has_parser(lang)
  end, langs)
  if #missing == 0 then
    return
  end
  local orig = _G.print
  local function restore()
    if _G.print ~= orig then
      _G.print = orig
    end
  end
  _G.print = function(...)
    local msg = table.concat(vim.tbl_map(tostring, { ... }), " ")
    local done, total = msg:match("%[(%d+)/(%d+)%]")
    vim.schedule(function()
      vim.notify(msg:gsub("^%[nvim%-treesitter%]%s*", ""), vim.log.levels.INFO, {
        id = "aqua_ts_install",
        title = "󰖌 Treesitter",
      })
    end)
    if done and done == total then
      restore()
    end
  end
  vim.defer_fn(restore, 5 * 60 * 1000) -- страховка, если установка оборвалась
  require("nvim-treesitter.install").ensure_installed(missing)
end

return {
  {
    "nvim-treesitter/nvim-treesitter",
    branch = "master",
    build = ":TSUpdate",
    event = { "BufReadPost", "BufNewFile", "VeryLazy" },
    cmd = { "TSUpdate", "TSInstall", "TSInstallInfo" },
    dependencies = {
      { "nvim-treesitter/nvim-treesitter-textobjects", branch = "master" },
    },
    opts_extend = { "ensure_installed" },
    opts = {
      ensure_installed = {
        "bash", "diff", "html", "lua", "luadoc", "markdown", "markdown_inline",
        "query", "regex", "vim", "vimdoc", "toml", "gitcommit", "git_rebase",
      },
      auto_install = not headless,
      highlight = { enable = true },
      indent = { enable = true },
      incremental_selection = {
        enable = true,
        keymaps = {
          init_selection = "<C-space>",
          node_incremental = "<C-space>",
          scope_incremental = false,
          node_decremental = "<bs>",
        },
      },
      textobjects = {
        move = {
          enable = true,
          goto_next_start = { ["]f"] = "@function.outer", ["]c"] = "@class.outer", ["]a"] = "@parameter.inner" },
          goto_next_end = { ["]F"] = "@function.outer", ["]C"] = "@class.outer" },
          goto_previous_start = { ["[f"] = "@function.outer", ["[c"] = "@class.outer", ["[a"] = "@parameter.inner" },
          goto_previous_end = { ["[F"] = "@function.outer", ["[C"] = "@class.outer" },
        },
      },
    },
    config = function(_, opts)
      -- убираем дубликаты, которые приносят несколько extras
      local seen, list = {}, {}
      for _, lang in ipairs(opts.ensure_installed or {}) do
        if not seen[lang] then
          seen[lang] = true
          list[#list + 1] = lang
        end
      end
      opts.ensure_installed = {}
      require("nvim-treesitter.configs").setup(opts)
      if not headless then
        install_missing(list)
      end
    end,
  },
}
