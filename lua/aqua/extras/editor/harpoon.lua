-- desc: Harpoon 2: закрепление ключевых файлов и мгновенный переход (<leader>h, <leader>1..5)
local keys = {
  { "<leader>H", function() require("harpoon"):list():add() end, desc = "Harpoon File" },
  {
    "<leader>h",
    function()
      local harpoon = require("harpoon")
      harpoon.ui:toggle_quick_menu(harpoon:list(), { border = "rounded", title_pos = "center" })
    end,
    desc = "Harpoon Quick Menu",
  },
}
for i = 1, 5 do
  keys[#keys + 1] = { "<leader>" .. i, function() require("harpoon"):list():select(i) end, desc = "Harpoon to File " .. i }
end

return {
  {
    "ThePrimeagen/harpoon",
    branch = "harpoon2",
    dependencies = { "nvim-lua/plenary.nvim" },
    opts = { menu = { width = vim.api.nvim_win_get_width(0) - 4 }, settings = { save_on_toggle = true } },
    keys = keys,
  },
}
