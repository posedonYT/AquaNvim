-- desc: Мультикурсоры (vim-visual-multi): <C-n> по слову, <C-Up>/<C-Down> вертикально
return {
  {
    "mg979/vim-visual-multi",
    branch = "master",
    event = "VeryLazy",
    init = function()
      vim.g.VM_maps = { ["Find Under"] = "<C-d>", ["Find Subword Under"] = "<C-d>" }
      vim.g.VM_theme = "ocean"
    end,
  },
}
