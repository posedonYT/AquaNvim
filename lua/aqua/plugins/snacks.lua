local logo = {
  [[ █████╗  ██████╗ ██╗   ██╗ █████╗ ███╗   ██╗██╗   ██╗██╗███╗   ███╗]],
  [[██╔══██╗██╔═══██╗██║   ██║██╔══██╗████╗  ██║██║   ██║██║████╗ ████║]],
  [[███████║██║   ██║██║   ██║███████║██╔██╗ ██║██║   ██║██║██╔████╔██║]],
  [[██╔══██║██║▄▄ ██║██║   ██║██╔══██║██║╚██╗██║╚██╗ ██╔╝██║██║╚██╔╝██║]],
  [[██║  ██║╚██████╔╝╚██████╔╝██║  ██║██║ ╚████║ ╚████╔╝ ██║██║ ╚═╝ ██║]],
  [[╚═╝  ╚═╝ ╚══▀▀═╝  ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═══╝  ╚═══╝  ╚═╝╚═╝     ╚═╝]],
}

-- Компактный логотип для узких окон (сплиты, панели терминала)
local logo_small = {
  [[┏━┓┏━┓╻ ╻┏━┓┏┓╻╻ ╻╻┏┳┓]],
  [[┣━┫┃┓┃┃ ┃┣━┫┃┗┫┃┏┛┃┃┃┃]],
  [[╹ ╹┗┻┛┗━┛╹ ╹╹ ╹┗┛ ╹╹ ╹]],
}

local wide = vim.o.columns >= 72

--- Заголовок дашборда: логотип с градиентом «от поверхности в глубину» + волны.
local function header()
  local items = {}
  local lines = wide and logo or logo_small
  for i, line in ipairs(lines) do
    local hl = "AquaHeader" .. (wide and i or (i * 2 + 1))
    items[#items + 1] = { text = { { line, hl = hl } }, align = "center" }
  end
  items[#items + 1] = {
    text = {
      { wide and "≋≋≋≈≈≈∼∼∼  " or "≈∼ ", hl = "AquaWave" },
      { "dive deep · code clear", hl = "AquaTagline" },
      { wide and "  ∼∼∼≈≈≈≋≋≋" or " ∼≈", hl = "AquaWave" },
    },
    align = "center",
    padding = 2,
  }
  return items
end

local function root()
  return require("aqua.util.root").get()
end

return {
  {
    "folke/snacks.nvim",
    priority = 1000,
    lazy = false,
    ---@type snacks.Config
    opts = {
      bigfile = { enabled = true },
      quickfile = { enabled = true },
      input = { enabled = true },
      notifier = { enabled = true, timeout = 3000, style = "compact", top_down = false },
      indent = { enabled = true, animate = { enabled = false } },
      scope = { enabled = true },
      scroll = { enabled = true, animate = { duration = { step = 12, total = 160 } } },
      statuscolumn = { enabled = true },
      words = { enabled = true },
      image = { enabled = false },
      terminal = {
        win = {
          position = "bottom",
          height = 0.3,
          keys = {
            nav_h = { "<C-h>", function() vim.cmd.wincmd("h") end, desc = "Go to Left Window", mode = "t" },
            nav_k = { "<C-k>", function() vim.cmd.wincmd("k") end, desc = "Go to Upper Window", mode = "t" },
          },
        },
      },
      explorer = { enabled = true, replace_netrw = true },
      picker = {
        enabled = true,
        ui_select = true,
        prompt = " 󰖌 ",
        layout = { preset = "default", cycle = true },
        matcher = { frecency = true },
        sources = {
          explorer = {
            title = "󰖌 Explorer",
            hidden = true,
            ignored = false,
            follow_file = true,
            auto_close = false,
            layout = { preset = "sidebar", preview = false, layout = { width = 34 } },
          },
          files = { hidden = true },
          grep = { hidden = true },
          projects = {
            dev = { "~/Documents/Programming", "~/projects", "~/dev" },
            patterns = { ".git", "package.json", "Cargo.toml", "go.mod", "pyproject.toml" },
          },
        },
        icons = {
          tree = { vertical = "│ ", middle = "├╴", last = "└╴" },
        },
      },
      dashboard = {
        enabled = true,
        width = wide and 68 or math.max(40, vim.o.columns - 6),
        preset = {
          keys = {
            { icon = "\u{f002} ", key = "f", desc = "Find File", action = function() Snacks.picker.files({ cwd = root() }) end },
            { icon = "\u{f15b} ", key = "n", desc = "New File", action = ":ene | startinsert" },
            { icon = "\u{f422} ", key = "g", desc = "Find Text", action = function() Snacks.picker.grep() end },
            { icon = "\u{f1da} ", key = "r", desc = "Recent Files", action = function() Snacks.picker.recent() end },
            { icon = "\u{f07c} ", key = "p", desc = "Projects", action = function() Snacks.picker.projects() end },
            { icon = "󰦛 ", key = "s", desc = "Restore Session", action = function() require("persistence").load() end },
            { icon = "󰚩 ", key = "c", desc = "Claude", action = function() require("aqua.claude").open() end },
            { icon = "󰐱 ", key = "x", desc = "Aqua Extras", action = ":AquaExtras" },
            { icon = "\u{f013} ", key = "C", desc = "Config", action = function() Snacks.picker.files({ cwd = vim.fn.stdpath("config") }) end },
            { icon = "󰒲 ", key = "l", desc = "Lazy", action = ":Lazy", enabled = package.loaded.lazy ~= nil },
            { icon = "\u{f426} ", key = "q", desc = "Quit", action = ":qa" },
          },
        },
        sections = {
          header,
          { section = "keys", gap = 1, padding = 2 },
          { icon = "\u{f1da} ", title = "Recent Files", section = "recent_files", cwd = true, indent = 2, padding = 2, limit = 5 },
          { section = "startup", icon = "󰖌 " },
        },
      },
      styles = {
        notification = { wo = { wrap = true } },
        terminal = { wo = { winbar = "" } },
      },
    },
    init = function()
      vim.api.nvim_create_autocmd("User", {
        pattern = "VeryLazy",
        callback = function()
          -- Отладочные хелперы
          _G.dd = function(...) Snacks.debug.inspect(...) end
          _G.bt = function() Snacks.debug.backtrace() end
          vim.print = _G.dd

          -- Переключатели <leader>u*
          Snacks.toggle.option("spell", { name = "Spelling" }):map("<leader>us")
          Snacks.toggle.option("wrap", { name = "Wrap" }):map("<leader>uw")
          Snacks.toggle.option("relativenumber", { name = "Relative Number" }):map("<leader>uL")
          Snacks.toggle.line_number():map("<leader>ul")
          Snacks.toggle.diagnostics():map("<leader>ud")
          Snacks.toggle.inlay_hints():map("<leader>uh")
          Snacks.toggle.treesitter():map("<leader>uT")
          Snacks.toggle.indent():map("<leader>ug")
          Snacks.toggle.dim():map("<leader>uD")
          Snacks.toggle.zen():map("<leader>uz")
          Snacks.toggle.zoom():map("<leader>uZ")
          Snacks.toggle.option("conceallevel", { off = 0, on = 2, name = "Conceal" }):map("<leader>uc")
          Snacks.toggle.option("background", { off = "light", on = "dark", name = "Dark Background" }):map("<leader>ub")
          Snacks.toggle({
            name = "Auto Format (global)",
            get = function() return vim.g.autoformat end,
            set = function(state) vim.g.autoformat = state end,
          }):map("<leader>uf")
          Snacks.toggle({
            name = "Transparent Background",
            get = function() return vim.g.aqua_transparent == true end,
            set = function(state)
              vim.g.aqua_transparent = state
              vim.cmd.colorscheme("aqua")
            end,
          }):map("<leader>uB")
          Snacks.toggle({
            name = "Session Autorestore",
            get = function() return vim.g.aqua_autorestore == true end,
            set = function(state) vim.g.aqua_autorestore = state end,
          }):map("<leader>qa")
        end,
      })
    end,
  },
}
