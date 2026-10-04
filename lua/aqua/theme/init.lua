-- Тема «aqua»: собственная палитра поверх движка tokyonight.nvim
-- (берём от него покрытие сотен плагинов, а цвета и акценты — свои).
local M = {}

M.palette = require("aqua.theme.palette")

---@param c table tokyonight colors
function M.on_colors(c)
  local p = M.palette
  local transparent = vim.g.aqua_transparent
  c.bg = transparent and "NONE" or p.deep
  c.bg_dark = p.abyss
  c.bg_dark1 = p.abyss
  c.bg_float = p.abyss
  c.bg_popup = p.abyss
  c.bg_sidebar = transparent and "NONE" or p.abyss
  c.bg_statusline = p.trench
  c.bg_highlight = p.current
  c.bg_visual = p.reef
  c.bg_search = p.tide
  c.border = p.kelp_dark
  c.border_highlight = p.lagoon
  c.fg = p.foam
  c.fg_dark = p.spray
  c.fg_float = p.foam
  c.fg_sidebar = p.spray
  c.fg_gutter = p.kelp_dark
  c.comment = p.drift
  c.dark3 = p.kelp_dark
  c.dark5 = p.mist
  c.terminal_black = p.kelp_dark
  c.black = p.abyss

  c.blue = p.wave
  c.blue0 = p.tide
  c.blue1 = p.turquoise
  c.blue2 = p.lagoon
  c.blue5 = p.ice
  c.blue6 = "#c8fbff"
  c.blue7 = p.reef
  c.cyan = p.lagoon
  c.teal = p.turquoise
  c.green = p.kelp
  c.green1 = p.seaglass
  c.green2 = "#2aa198"
  c.magenta = p.jelly
  c.magenta2 = p.anemone
  c.purple = "#9d8cff"
  c.orange = p.sunset
  c.yellow = p.sand
  c.red = p.coral
  c.red1 = "#e5505c"

  c.git = { add = p.kelp, change = p.wave, delete = p.coral, ignore = p.drift }
  c.diff = {
    add = "#123a33",
    delete = "#3a1a24",
    change = "#13304c",
    text = "#1d4a6e",
  }
  c.error = p.coral
  c.warning = p.sand
  c.info = p.lagoon
  c.hint = p.turquoise
end

---@param hl table
---@param c table
function M.on_highlights(hl, c)
  local p = M.palette
  local float_bg = p.abyss

  hl.CursorLineNr = { fg = p.turquoise, bold = true }
  hl.LineNr = { fg = p.kelp_dark }
  hl.LineNrAbove = { fg = p.kelp_dark }
  hl.LineNrBelow = { fg = p.kelp_dark }
  hl.WinSeparator = { fg = p.reef, bold = true }
  hl.FloatBorder = { fg = p.lagoon, bg = float_bg }
  hl.FloatTitle = { fg = p.abyss, bg = p.turquoise, bold = true }
  hl.NormalFloat = { fg = p.foam, bg = float_bg }
  hl.Pmenu = { fg = p.foam, bg = float_bg }
  hl.PmenuSel = { bg = p.reef, bold = true }
  hl.Visual = { bg = p.reef }
  hl.Search = { fg = p.abyss, bg = p.lagoon }
  hl.IncSearch = { fg = p.abyss, bg = p.turquoise, bold = true }
  hl.CurSearch = { link = "IncSearch" }
  hl.MatchParen = { fg = p.turquoise, bold = true, underline = true }

  -- Snacks: explorer, picker, dashboard, indent
  hl.SnacksPickerBorder = { fg = p.lagoon, bg = float_bg }
  hl.SnacksPickerInputBorder = { fg = p.sunset, bg = float_bg }
  hl.SnacksPickerInputTitle = { fg = p.sunset, bold = true }
  hl.SnacksPickerBoxTitle = { fg = p.sunset, bold = true }
  hl.SnacksPickerTitle = { fg = p.abyss, bg = p.turquoise, bold = true }
  hl.SnacksPickerPreviewTitle = { fg = p.abyss, bg = p.wave, bold = true }
  hl.SnacksPickerListCursorLine = { bg = p.reef }
  hl.SnacksPickerMatch = { fg = p.turquoise, bold = true }
  hl.SnacksPickerPrompt = { fg = p.turquoise }
  hl.SnacksPickerDir = { fg = p.mist }
  hl.SnacksPickerTree = { fg = p.kelp_dark }
  hl.SnacksPickerDirectory = { fg = p.wave, bold = true }
  hl.SnacksIndent = { fg = "#14304a" }
  hl.SnacksIndentScope = { fg = p.lagoon }
  hl.SnacksDashboardKey = { fg = p.turquoise, bold = true }
  hl.SnacksDashboardIcon = { fg = p.lagoon }
  hl.SnacksDashboardDesc = { fg = p.foam }
  hl.SnacksDashboardFooter = { fg = p.drift, italic = true }
  hl.SnacksDashboardSpecial = { fg = p.jelly }
  hl.SnacksDashboardTitle = { fg = p.sunset, bold = true }
  hl.SnacksNotifierBorderInfo = { fg = p.lagoon }
  hl.SnacksNotifierTitleInfo = { fg = p.turquoise, bold = true }

  -- Градиент заголовка дашборда (поверхность → глубина)
  local gradient = { "#9ff0ff", "#6fe6ea", "#2ee6d6", "#3fc6d9", "#4aa8ff", "#2b7bd1", "#1f5ea8" }
  for i, color in ipairs(gradient) do
    hl["AquaHeader" .. i] = { fg = color, bold = true }
  end
  hl.AquaWave = { fg = p.reef }
  hl.AquaTagline = { fg = p.mist, italic = true }

  -- which-key
  hl.WhichKey = { fg = p.turquoise }
  hl.WhichKeyGroup = { fg = p.wave }
  hl.WhichKeyDesc = { fg = p.jelly }
  hl.WhichKeySeparator = { fg = p.drift }
  hl.WhichKeyBorder = { fg = p.lagoon, bg = float_bg }
  hl.WhichKeyTitle = { fg = p.sunset, bold = true }
  hl.WhichKeyNormal = { bg = float_bg }

  -- Claude
  hl.AquaClaudeNormal = { fg = p.foam, bg = p.abyss }
  hl.AquaClaudeBar = { fg = p.abyss, bg = p.sunset, bold = true }
  hl.AquaClaudeDir = { fg = p.sand, bg = p.trench, italic = true }

  -- Bufferline / lualine fallback
  hl.TabLineSel = { fg = p.turquoise, bg = p.deep, bold = true }

  -- Diagnostics
  hl.DiagnosticVirtualTextError = { fg = p.coral, bg = "#2a1a24", italic = true }
  hl.DiagnosticVirtualTextWarn = { fg = p.sand, bg = "#2a2a22", italic = true }
  hl.DiagnosticVirtualTextInfo = { fg = p.lagoon, bg = "#0f2a3a", italic = true }
  hl.DiagnosticVirtualTextHint = { fg = p.turquoise, bg = "#0f2a33", italic = true }

  -- blink.cmp
  hl.BlinkCmpMenuBorder = { fg = p.lagoon, bg = float_bg }
  hl.BlinkCmpDocBorder = { fg = p.lagoon, bg = float_bg }
  hl.BlinkCmpMenuSelection = { bg = p.reef, bold = true }
  hl.BlinkCmpLabelMatch = { fg = p.turquoise, bold = true }
  _ = c
end

function M.opts()
  return {
    style = "night",
    transparent = vim.g.aqua_transparent,
    terminal_colors = true,
    styles = {
      comments = { italic = true },
      keywords = { italic = true },
      sidebars = vim.g.aqua_transparent and "transparent" or "dark",
      floats = vim.g.aqua_transparent and "transparent" or "dark",
    },
    on_colors = M.on_colors,
    on_highlights = M.on_highlights,
    cache = false, -- on_highlights должны применяться всегда
    plugins = { all = true, auto = true },
  }
end

function M.load()
  local ok, tokyonight = pcall(require, "tokyonight")
  if not ok then
    vim.notify("tokyonight.nvim не установлен — тема aqua недоступна", vim.log.levels.WARN)
    return
  end
  tokyonight.load(M.opts())
  vim.g.colors_name = "aqua"
end

--- Цвета lualine
function M.lualine()
  local p = M.palette
  local function mode(color)
    return {
      a = { fg = p.abyss, bg = color, gui = "bold" },
      b = { fg = color, bg = p.current },
      c = { fg = p.spray, bg = p.trench },
    }
  end
  return {
    normal = mode(p.turquoise),
    insert = mode(p.kelp),
    visual = mode(p.jelly),
    replace = mode(p.coral),
    command = mode(p.sand),
    terminal = mode(p.sunset),
    inactive = {
      a = { fg = p.drift, bg = p.trench },
      b = { fg = p.drift, bg = p.trench },
      c = { fg = p.drift, bg = p.trench },
    },
  }
end

return M
