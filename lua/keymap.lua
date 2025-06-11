vim.keymap.set("n", "<leader>e", "<cmd>NvimTreeToggle<CR>", { desc = "File Explorer" })
vim.keymap.set("n", "<leader>ff", "<cmd>Telescope find_files<CR>", { desc = "Find Files" })

-- Переключение между окнами (файловое дерево и редактор)
vim.keymap.set("n", "<C-h>", "<C-w>h", { desc = "Move to Left Window" })
vim.keymap.set("n", "<C-l>", "<C-w>l", { desc = "Move to Right Window" })
vim.keymap.set("n", "<C-Left>", "<C-w>h", { desc = "Move to Left Window" })
vim.keymap.set("n", "<C-Right>", "<C-w>l", { desc = "Move to Right Window" })

-- Закрытие буфера с переходом на предыдущий
vim.keymap.set("n", "<leader>c", function()
    local current_buf = vim.api.nvim_get_current_buf()
    vim.cmd("silent! bp")   -- Пытаемся перейти на предыдущий буфер (без ошибки если невозможно)
    if vim.api.nvim_get_current_buf() == current_buf then
        vim.cmd("bd")       -- Если остались в том же буфере (начало списка) - просто закрываем
    else
        vim.cmd("bd " .. current_buf)  -- Закрываем исходный буфер после перехода
    end
end, { desc = "Close Buffer and switch to previous" })

-- Сохранение файла
vim.keymap.set("n", "<C-s>", "<cmd>w<CR>", { desc = "Save File" })
vim.keymap.set("i", "<C-s>", "<Esc><cmd>w<CR>", { desc = "Save File" })

-- Копирование и вставка
vim.keymap.set("n", "yy", "yy", { desc = "Copy Line" })
vim.keymap.set("v", "yy", "y", { desc = "Copy Selection" })
vim.keymap.set("n", "p", "p", { desc = "Paste" })
vim.keymap.set("v", "p", "p", { desc = "Paste" })

-- Выделение
vim.keymap.set("n", "v", "v", { desc = "Visual Mode" })
vim.keymap.set("n", "<S-v>", "V", { desc = "Visual Line Mode" })

-- Выделение всего файла
vim.keymap.set("n", "<C-a>", "ggVG", { desc = "Select All" })

-- Навигация в визуальном режиме стрелочками
vim.keymap.set("v", "<Up>", "k", { desc = "Move Up" })
vim.keymap.set("v", "<Down>", "j", { desc = "Move Down" })
vim.keymap.set("v", "<Left>", "h", { desc = "Move Left" })
vim.keymap.set("v", "<Right>", "l", { desc = "Move Right" })

-- Комментирование/раскомментирование выделенных строк по нажатию /
vim.keymap.set("v", "/", function()
    vim.cmd("normal! gv")
    local mode = vim.fn.visualmode()
    if mode ~= "V" then
        vim.notify("Комментирование поддерживается только в строчном визуальном режиме (Shift + V)", vim.log.levels.WARN)
        return
    end

    local start_line = vim.fn.line("'<") - 1
    local end_line = vim.fn.line("'>")
    local total_lines = vim.api.nvim_buf_line_count(0)
    if start_line < 0 or end_line > total_lines or start_line >= end_line then
        vim.notify("Недопустимый или пустой диапазон выделения: start=" .. start_line .. ", end=" .. end_line, vim.log.levels.ERROR)
        return
    end

    local filetype = vim.api.nvim_buf_get_option(0, "filetype")
    local comment_map = {
        lua = "-- ",
        python = "# ",
        cpp = "// ",
        c = "// ",
        javascript = "// ",
        typescript = "// ",
        rust = "// "
    }
    local comment_str = comment_map[filetype] or "# "

    local lines = vim.api.nvim_buf_get_lines(0, start_line, end_line, false)
    if not lines or #lines == 0 then
        vim.notify("В выделении нет строк", vim.log.levels.ERROR)
        return
    end

    local all_commented = true
    for _, line in ipairs(lines) do
        if not line:match("^%s*" .. vim.pesc(comment_str)) then
            all_commented = false
            break
        end
    end

    for i = 1, #lines do
        if all_commented then
            lines[i] = lines[i]:gsub("^(%s*)" .. vim.pesc(comment_str), "%1")
        else
            lines[i] = comment_str .. (lines[i] or "")
        end
    end

    local success, err = pcall(function()
        vim.api.nvim_buf_set_lines(0, start_line, end_line, false, lines)
    end)
    if not success then
        vim.notify("Ошибка при комментировании/раскомментировании строк: " .. tostring(err), vim.log.levels.ERROR)
        return
    end

    local line_count = end_line - start_line
    if line_count > 0 then
        vim.api.nvim_command("normal! " .. (start_line + 1) .. "GV" .. (line_count - 1) .. "j")
    else
        vim.api.nvim_command("normal! " .. (start_line + 1) .. "GV")
    end
end, { desc = "Comment or uncomment selected lines" })

vim.keymap.set("n", "<leader>n", function()
  local api = require("nvim-tree.api")
  api.fs.create()
end, { desc = "Создать файл в nvim-tree" })
