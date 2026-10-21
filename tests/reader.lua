-- Тесты режима чтения Markdown (Space m r). Подключаются из tests/run.lua.
return function(T)
  local describe, it, eq, ok, wait, tmp, real = T.describe, T.it, T.eq, T.ok, T.wait, T.tmp, T.real
  local reader = require("aqua.reader")

  local dir = real(tmp) .. "/readerproj"
  vim.fn.mkdir(dir, "p")
  local md = dir .. "/doc.md"
  vim.fn.writefile({
    "# Заголовок", "", "Текст с **жирным** и [ссылкой](https://example.com).", "",
    "## Раздел", "", "- [ ] задача", "", "```lua", "# не заголовок", "```", "",
    "### Подраздел", "", "конец",
  }, md)
  vim.fn.writefile({ "просто текст" }, dir .. "/a.txt")

  local function mapped(lhs)
    local m = vim.fn.maparg(lhs, "n", false, true)
    return not vim.tbl_isempty(m) and m.buffer == 1
  end

  local function flush_typeahead()
    vim.wait(50)
    vim.api.nvim_feedkeys("", "x", false) -- выполнить отложенное feedkeys (например, `i`) и вернуться в Normal
    if vim.fn.mode() ~= "n" then vim.cmd.stopinsert() end
  end

  describe("Режим чтения Markdown", function()
    it("ключи есть в markdown-буфере и нет в остальных", function()
      vim.cmd("only")
      vim.cmd.edit(md)
      ok(mapped(" mr") and mapped(" mo"), "<leader>mr / <leader>mo в markdown")
      vim.cmd.edit(dir .. "/a.txt")
      ok(not mapped(" mr"), "в текстовом файле бинда нет")
      vim.cmd.edit(md)
    end)

    it("доступен только для Markdown", function()
      vim.cmd.edit(dir .. "/a.txt")
      local msg
      local orig = vim.notify
      vim.notify = function(m) msg = m end
      reader.toggle()
      vim.notify = orig
      ok(not reader.is_active())
      ok(msg and msg:find("Markdown", 1, true), tostring(msg))
      vim.cmd.edit(md)
    end)

    it("вход: колонка по центру, без диагностик и орфографии, только чтение, разметка скрыта", function()
      vim.cmd("only")
      vim.cmd.edit(md)
      local buf = vim.api.nvim_get_current_buf()
      local orig_win = vim.api.nvim_get_current_win()
      vim.wo[orig_win].spell = true
      vim.diagnostic.set(vim.api.nvim_create_namespace("t_md"), buf, { { lnum = 0, col = 0, message = "MD013 line-length", severity = 2 } })
      ok(vim.diagnostic.is_enabled({ bufnr = buf }))

      vim.fn.maparg(" mr", "n", false, true).callback()
      ok(reader.is_active(), "режим чтения включён")
      local win = reader.active.win.win
      local c = vim.api.nvim_win_get_config(win)
      eq("editor", c.relative)
      ok(c.width <= 100 and c.width >= 60, "ширина колонки: " .. c.width)
      eq(vim.api.nvim_get_current_win(), win, "фокус в окне чтения")

      eq(false, vim.bo[buf].modifiable, "защита от правок")
      eq(false, vim.diagnostic.is_enabled({ bufnr = buf }), "диагностики скрыты")
      local wo = vim.wo[win]
      eq(true, wo.wrap); eq(true, wo.linebreak); eq(false, wo.number); eq(false, wo.relativenumber)
      eq("no", wo.signcolumn); eq(false, wo.spell, "без красной орфографии"); eq(3, wo.conceallevel)
      eq("nvic", wo.concealcursor); eq(false, wo.cursorline); eq(false, wo.list)
      ok(wo.winbar:find("Режим чтения", 1, true), "подсказка в winbar")
      eq(false, require("render-markdown.state").get(buf).anti_conceal.enabled, "разметка скрыта и на строке курсора")
      for _, lhs in ipairs({ "q", "<Esc>", "i", "a", "o", "I", "A", "O", "e", "]]", "[[" }) do
        ok(mapped(lhs), "нет бинда " .. lhs)
      end
      ok(mapped(" mr") and mapped(" mo"), "переключатель и оглавление остаются")
    end)

    it("]] и [[ перескакивают между заголовками, заголовки в блоках кода пропускаются", function()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local function press(lhs) vim.fn.maparg(lhs, "n", false, true).callback() end
      press("]]")
      eq(5, vim.api.nvim_win_get_cursor(0)[1], "## Раздел")
      press("]]")
      eq(13, vim.api.nvim_win_get_cursor(0)[1], "### Подраздел (строка «# не заголовок» в коде пропущена)")
      press("]]")
      eq(13, vim.api.nvim_win_get_cursor(0)[1], "дальше заголовков нет")
      press("[[")
      eq(5, vim.api.nvim_win_get_cursor(0)[1])
      press("[[")
      eq(1, vim.api.nvim_win_get_cursor(0)[1])
    end)

    it("оглавление: заголовки и уровни", function()
      local heads = reader.headings(vim.api.nvim_get_current_buf())
      eq({ { 1, 1 }, { 5, 2 }, { 13, 3 } }, vim.tbl_map(function(h) return { h.line, h.level } end, heads))
      reader.outline()
      wait(2000, function() return #Snacks.picker.get() > 0 end, "picker оглавления")
      local picker = Snacks.picker.get()[1]
      wait(2000, function() return picker:count() == 3 end, "три заголовка")
      picker:close()
      vim.wait(300) -- Snacks закрывает picker асинхронно
    end)

    it("выход (q / Esc / <leader>mr): всё возвращается как было", function()
      local st = reader.active
      local buf = st.buf
      local win = st.win.win
      vim.fn.maparg("q", "n", false, true).callback()
      ok(not reader.is_active())
      ok(not vim.api.nvim_win_is_valid(win), "окно чтения закрыто")
      eq(true, vim.bo[buf].modifiable)
      eq(true, vim.diagnostic.is_enabled({ bufnr = buf }), "диагностики вернулись")
      eq(true, require("render-markdown.state").get(buf).anti_conceal.enabled, "anti-conceal вернулся")
      eq(true, vim.wo[vim.api.nvim_get_current_win()].spell, "орфография в обычном окне не тронута: win=" .. vim.api.nvim_get_current_win() .. " buf=" .. vim.api.nvim_buf_get_name(0) .. " ft=" .. vim.bo.filetype .. " float=" .. vim.api.nvim_win_get_config(0).relative .. " wins=" .. #vim.api.nvim_list_wins())
      for _, lhs in ipairs({ "q", "<Esc>", "i", "a", "o", "]]", "[[", "e" }) do
        ok(not mapped(lhs), "бинд " .. lhs .. " должен исчезнуть")
      end
      ok(mapped(" mr") and mapped(" mo"), "<leader>mr остаётся в markdown-буфере")
    end)

    it("повторное включение и выключение тем же сочетанием", function()
      local toggle = vim.fn.maparg(" mr", "n", false, true).callback
      toggle()
      ok(reader.is_active())
      vim.fn.maparg(" mr", "n", false, true).callback()
      ok(not reader.is_active())
      toggle()
      ok(reader.is_active())
      vim.fn.maparg("<Esc>", "n", false, true).callback()
      ok(not reader.is_active())
    end)

    it("`i` выходит из чтения и начинает редактирование", function()
      reader.enter()
      local buf = reader.active.buf
      vim.fn.maparg("i", "n", false, true).callback()
      ok(not reader.is_active())
      eq(true, vim.bo[buf].modifiable)
      flush_typeahead()
      eq("n", vim.fn.mode())
    end)

    it("закрытие окна другим способом тоже всё восстанавливает", function()
      reader.enter()
      local st = reader.active
      vim.api.nvim_win_close(st.win.win, true)
      wait(2000, function() return not reader.is_active() end, "режим чтения выключен")
      eq(true, vim.bo[st.buf].modifiable)
      eq(true, vim.diagnostic.is_enabled({ bufnr = st.buf }))
      eq(true, require("render-markdown.state").get(st.buf).anti_conceal.enabled)
    end)

    it("диагностики других буферов не затрагиваются", function()
      local other = vim.fn.bufadd(dir .. "/a.txt")
      reader.enter()
      ok(vim.diagnostic.is_enabled({ bufnr = other }), "чужой буфер")
      reader.exit()
    end)

    it("ширина настраивается: vim.g.aqua_reader = { width = N }", function()
      vim.g.aqua_reader = { width = 60 }
      reader.enter()
      eq(60, vim.api.nvim_win_get_config(reader.active.win.win).width)
      reader.exit()
      vim.g.aqua_reader = nil
    end)

    it("which-key: группа <leader>m и тема читалки заданы", function()
      local opts = require("aqua.plugins.editor")[1].opts
      local found
      for _, spec in ipairs(opts.spec[1]) do
        if type(spec) == "table" and spec[1] == "<leader>m" then found = spec.group end
      end
      eq("markdown", found)
      for _, g in ipairs({ "AquaReaderNormal", "AquaReaderBar", "AquaReaderHint" }) do
        ok(next(vim.api.nvim_get_hl(0, { name = g })), g)
      end
    end)
  end)
end
