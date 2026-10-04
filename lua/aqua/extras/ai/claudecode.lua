-- desc: Claude IDE-мост (claudecode.nvim): диффы правок Claude в Neovim, контекст выделения
-- Окна Claude по-прежнему открывает AquaNvim (<leader>c, по проекту), а этот плагин
-- поднимает WebSocket-сервер, к которому они подключаются автоматически.
return {
  {
    "coder/claudecode.nvim",
    dependencies = { "folke/snacks.nvim" },
    event = "VeryLazy",
    opts = {
      terminal = { provider = "none" }, -- терминалы Claude создаёт aqua.claude
      track_selection = true,
      diff_opts = { layout = "vertical", open_in_new_tab = false },
    },
    keys = {
      { "<leader>ab", "<cmd>ClaudeCodeAdd %<cr>", desc = "Add Buffer (IDE)" },
      { "<leader>aS", "<cmd>ClaudeCodeSend<cr>", mode = "x", desc = "Send Selection (IDE)" },
      { "<leader>ay", "<cmd>ClaudeCodeDiffAccept<cr>", desc = "Accept Diff" },
      { "<leader>an", "<cmd>ClaudeCodeDiffDeny<cr>", desc = "Deny Diff" },
      { "<leader>am", "<cmd>ClaudeCodeSelectModel<cr>", desc = "Select Model" },
      { "<leader>aI", "<cmd>ClaudeCodeStatus<cr>", desc = "IDE Bridge Status" },
    },
  },
}
