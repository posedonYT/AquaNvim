-- desc: Подсветка цветов (#2ee6d6, rgb(), tailwind-классы) прямо в коде
return {
  {
    "catgoose/nvim-colorizer.lua",
    event = "BufReadPre",
    opts = {
      user_default_options = { names = false, tailwind = true, mode = "virtualtext", virtualtext = "■" },
    },
  },
}
