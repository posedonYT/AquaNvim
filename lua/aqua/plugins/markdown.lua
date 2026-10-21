-- Markdown: красивый рендер прямо в буфере (render-markdown) и режим чтения (aqua.reader).
return {
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
