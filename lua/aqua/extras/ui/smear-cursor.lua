-- desc: Smear cursor: плавный «шлейф» курсора, как след на воде
return {
  {
    "sphamba/smear-cursor.nvim",
    event = "VeryLazy",
    opts = {
      cursor_color = "#2ee6d6",
      stiffness = 0.7,
      trailing_stiffness = 0.4,
      distance_stop_animating = 0.5,
    },
  },
}
