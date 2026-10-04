-- desc: Oil: редактирование файловой системы как обычного буфера (клавиша -)
return {
  {
    "stevearc/oil.nvim",
    cmd = "Oil",
    keys = { { "-", "<cmd>Oil<cr>", desc = "Open Parent Directory (Oil)" } },
    opts = {
      default_file_explorer = false, -- основной explorer — Snacks
      view_options = { show_hidden = true },
      float = { border = "rounded" },
    },
  },
}
