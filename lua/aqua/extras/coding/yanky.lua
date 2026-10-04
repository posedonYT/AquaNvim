-- desc: Yanky: история копирований (<leader>p) и циклическая вставка
return {
  {
    "gbprod/yanky.nvim",
    event = "VeryLazy",
    opts = { highlight = { timer = 150 } },
    keys = {
      { "<leader>p", function() Snacks.picker.yanky() end, mode = { "n", "x" }, desc = "Yank History" },
      { "y", "<Plug>(YankyYank)", mode = { "n", "x" }, desc = "Yank Text" },
      { "p", "<Plug>(YankyPutAfter)", mode = { "n", "x" }, desc = "Put Text After Cursor" },
      { "P", "<Plug>(YankyPutBefore)", mode = { "n", "x" }, desc = "Put Text Before Cursor" },
      { "[y", "<Plug>(YankyCycleForward)", desc = "Cycle Forward Through Yank History" },
      { "]y", "<Plug>(YankyCycleBackward)", desc = "Cycle Backward Through Yank History" },
    },
  },
}
