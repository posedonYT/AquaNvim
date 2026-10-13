-- Файловые инструменты: чтение, поиск, создание, редактирование, перенос, удаление.
local sandbox = require("aqua.ai.tools.sandbox")

local uv = vim.uv or vim.loop
local M = {}

local MAX_READ_BYTES = 1024 * 1024
local IGNORE_DIRS = { [".git"] = true, node_modules = true, [".venv"] = true, __pycache__ = true, target = true, [".DS_Store"] = true }

-- ── утилиты ─────────────────────────────────────────────────────────────────

---@return string? content, string? err
local function read_text(abs)
  local st = uv.fs_stat(abs)
  if not st then
    return nil, "Файл не найден"
  end
  if st.type ~= "file" then
    return nil, "Это не файл (" .. st.type .. ")"
  end
  if st.size > MAX_READ_BYTES then
    return nil, ("Файл слишком большой (%d КБ, лимит %d КБ)"):format(st.size / 1024, MAX_READ_BYTES / 1024)
  end
  local f = io.open(abs, "rb")
  if not f then
    return nil, "Не удалось открыть файл"
  end
  local data = f:read("*a")
  f:close()
  if data:sub(1, 8000):find("\0", 1, true) then
    return nil, "Бинарный файл — чтение невозможно"
  end
  return data
end
M.read_text = read_text

--- Загруженный буфер для файла, если есть.
local function buf_of(abs)
  local b = vim.fn.bufnr(abs)
  if b > 0 and vim.api.nvim_buf_is_loaded(b) then
    return b
  end
end

--- Запись файла. Отказывает, если в Neovim есть несохранённые изменения этого файла.
---@return boolean ok, string? err
local function write_text(abs, content)
  local b = buf_of(abs)
  if b and vim.bo[b].modified then
    return false, "В Neovim открыт буфер этого файла с несохранёнными изменениями — сначала сохраните его (пользователю: :w)"
  end
  vim.fn.mkdir(vim.fs.dirname(abs), "p")
  local f, err = io.open(abs, "wb")
  if not f then
    return false, "Не удалось записать: " .. tostring(err)
  end
  f:write(content)
  f:close()
  if b then
    pcall(vim.cmd, "checktime " .. b)
  end
  return true
end
M.write_text = write_text

local function diff_of(old, new)
  if old == new then
    return ""
  end
  local ensure = function(s) return (s ~= "" and s:sub(-1) ~= "\n") and (s .. "\n") or s end
  return vim.diff(ensure(old), ensure(new), { result_type = "unified", ctxlen = 3 }) or ""
end
M.diff_of = diff_of

local function count_lines(s)
  if s == "" then
    return 0
  end
  local _, n = s:gsub("\n", "")
  return s:sub(-1) == "\n" and n or n + 1
end

local function find_plain(s, needle, init)
  return s:find(needle, init, true)
end

--- Подстановка без шаблонов. Возвращает новую строку и число замен.
local function replace_plain(s, old, new, all)
  local out, pos, n = {}, 1, 0
  while true do
    local a, b = find_plain(s, old, pos)
    if not a then
      break
    end
    out[#out + 1] = s:sub(pos, a - 1)
    out[#out + 1] = new
    pos = b + 1
    n = n + 1
    if not all then
      break
    end
  end
  out[#out + 1] = s:sub(pos)
  return table.concat(out), n
end

local function count_plain(s, needle)
  local n, pos = 0, 1
  while true do
    local a, b = find_plain(s, needle, pos)
    if not a then
      return n
    end
    n = n + 1
    pos = b + 1
  end
end

local function walk(abs, depth, max_depth, rel_prefix, out, limit)
  if #out >= limit then
    return
  end
  local entries = {}
  for name, t in vim.fs.dir(abs) do
    if not IGNORE_DIRS[name] then
      entries[#entries + 1] = { name = name, type = t }
    end
  end
  table.sort(entries, function(a, b)
    if (a.type == "directory") ~= (b.type == "directory") then
      return a.type == "directory"
    end
    return a.name < b.name
  end)
  for _, e in ipairs(entries) do
    if #out >= limit then
      return
    end
    local rel = rel_prefix == "" and e.name or (rel_prefix .. "/" .. e.name)
    out[#out + 1] = { rel = rel, type = e.type, depth = depth }
    if e.type == "directory" and depth < max_depth then
      walk(abs .. "/" .. e.name, depth + 1, max_depth, rel, out, limit)
    end
  end
end

-- ── инструменты ─────────────────────────────────────────────────────────────

M.tools = {
  {
    name = "list_dir",
    category = "read",
    description = "List files and folders in a directory of the project. Use depth>1 to see nested structure. Directories end with '/'.",
    parameters = {
      type = "object",
      properties = {
        path = { type = "string", description = "Directory relative to the project root (default: root)" },
        depth = { type = "integer", description = "How many levels to show, 1-4 (default 1)" },
      },
    },
    summarize = function(a) return a.path or "." end,
    run = function(a, ctx, done)
      local abs, rel = sandbox.resolve(ctx, a.path)
      if not abs then return done(nil, rel) end
      local st = uv.fs_stat(abs)
      if not st or st.type ~= "directory" then return done(nil, "Директория не найдена: " .. rel) end
      local out = {}
      walk(abs, 1, math.max(1, math.min(a.depth or 1, 4)), "", out, 300)
      local lines = { ("%s/ (%d элементов%s)"):format(rel, #out, #out >= 300 and ", список обрезан" or "") }
      for _, e in ipairs(out) do
        lines[#lines + 1] = ("  "):rep(e.depth - 1) .. (e.rel:match("[^/]+$")) .. (e.type == "directory" and "/" or "")
      end
      done(table.concat(lines, "\n"))
    end,
  },

  {
    name = "read_file",
    category = "read",
    description = "Read a text file. Returns lines prefixed with line numbers. For big files use start_line/end_line.",
    parameters = {
      type = "object",
      properties = {
        path = { type = "string", description = "File path relative to the project root" },
        start_line = { type = "integer", description = "First line to read (1-based)" },
        end_line = { type = "integer", description = "Last line to read (inclusive)" },
      },
      required = { "path" },
    },
    summarize = function(a) return a.path end,
    run = function(a, ctx, done)
      local abs, rel = sandbox.resolve(ctx, a.path)
      if not abs then return done(nil, rel) end
      local content, err = read_text(abs)
      if not content then return done(nil, ("%s: %s"):format(rel, err)) end
      local lines = vim.split(content, "\n", { plain = true })
      if lines[#lines] == "" then table.remove(lines) end
      local s = math.max(1, a.start_line or 1)
      local e = math.min(#lines, a.end_line or #lines)
      local out, size = {}, 0
      for i = s, e do
        local l = ("%d\t%s"):format(i, lines[i])
        size = size + #l + 1
        if size > 40000 or #out >= 2000 then
          out[#out + 1] = ("... [обрезано на строке %d из %d — используйте start_line=%d]"):format(i - 1, #lines, i)
          break
        end
        out[#out + 1] = l
      end
      done(("%s (%d строк)\n%s"):format(rel, #lines, table.concat(out, "\n")))
    end,
  },

  {
    name = "find_files",
    category = "read",
    description = "Find files by glob pattern, e.g. '**/*.lua', '*.md', 'src/**/test_*.py'. A pattern without '/' matches in all folders.",
    parameters = {
      type = "object",
      properties = {
        pattern = { type = "string", description = "Glob pattern" },
        path = { type = "string", description = "Directory to search in (default: project root)" },
      },
      required = { "pattern" },
    },
    summarize = function(a) return a.pattern end,
    run = function(a, ctx, done)
      local abs, rel = sandbox.resolve(ctx, a.path)
      if not abs then return done(nil, rel) end
      local pattern = a.pattern:find("/", 1, true) and a.pattern or ("**/" .. a.pattern)
      local ok, lpeg = pcall(vim.glob.to_lpeg, pattern)
      if not ok then return done(nil, "Некорректный glob: " .. a.pattern) end
      local all, found = {}, {}
      walk(abs, 1, 12, "", all, 20000)
      for _, e in ipairs(all) do
        if e.type == "file" and lpeg:match(e.rel) then
          found[#found + 1] = e.rel
          if #found >= 200 then break end
        end
      end
      if #found == 0 then return done("Ничего не найдено по шаблону " .. a.pattern) end
      done(table.concat(found, "\n") .. (#found >= 200 and "\n... [показаны первые 200]" or ""))
    end,
  },

  {
    name = "grep",
    category = "read",
    description = "Search file contents with a regular expression (ripgrep syntax). Returns 'path:line:text' matches.",
    parameters = {
      type = "object",
      properties = {
        pattern = { type = "string", description = "Regular expression" },
        path = { type = "string", description = "File or directory to search in (default: project root)" },
        glob = { type = "string", description = "Only files matching this glob, e.g. '*.lua'" },
        ignore_case = { type = "boolean", description = "Case-insensitive search" },
      },
      required = { "pattern" },
    },
    summarize = function(a) return a.pattern end,
    run = function(a, ctx, done)
      local abs, rel = sandbox.resolve(ctx, a.path)
      if not abs then return done(nil, rel) end
      local cmd
      if vim.fn.executable("rg") == 1 then
        cmd = { "rg", "--line-number", "--no-heading", "--color=never", "--max-count=50", "--max-columns=300" }
        if a.ignore_case then cmd[#cmd + 1] = "-i" end
        if a.glob then vim.list_extend(cmd, { "-g", a.glob }) end
        vim.list_extend(cmd, { "-e", a.pattern, "--", abs })
      else
        cmd = { "grep", "-rnE", "-m", "50", "--exclude-dir=.git", "--exclude-dir=node_modules" }
        if a.ignore_case then cmd[#cmd + 1] = "-i" end
        if a.glob then cmd[#cmd + 1] = "--include=" .. a.glob end
        vim.list_extend(cmd, { "-e", a.pattern, "--", abs })
      end
      vim.system(cmd, { text = true, cwd = ctx.root }, function(res)
        vim.schedule(function()
          if res.code == 1 then return done("Совпадений нет") end
          if res.code ~= 0 then return done(nil, "Ошибка поиска: " .. vim.trim(res.stderr or "")) end
          local lines = vim.split(vim.trim(res.stdout), "\n", { plain = true })
          local out = {}
          for i, l in ipairs(lines) do
            if i > 100 then out[#out + 1] = "... [показаны первые 100 совпадений]" break end
            out[#out + 1] = l:gsub("^" .. vim.pesc(ctx.root) .. "/", "")
          end
          done(table.concat(out, "\n"))
        end)
      end)
    end,
  },

  {
    name = "write_file",
    category = "write",
    description = "Create a new file or fully overwrite an existing one with the given content. Parent folders are created automatically. For small changes to existing files prefer edit_file.",
    parameters = {
      type = "object",
      properties = {
        path = { type = "string", description = "File path relative to the project root" },
        content = { type = "string", description = "Full file content" },
      },
      required = { "path", "content" },
    },
    summarize = function(a) return a.path end,
    prepare = function(a, ctx)
      local abs, rel = sandbox.resolve(ctx, a.path, { write = true })
      if not abs then return nil, rel end
      local st = uv.fs_stat(abs)
      if st and st.type ~= "file" then return nil, rel .. " — это не файл" end
      local old = ""
      if st then
        local c, err = read_text(abs)
        if not c then return nil, ("%s: %s"):format(rel, err) end
        old = c
      end
      return { abs = abs, rel = rel, existed = st ~= nil },
        { title = (st and "Перезаписать файл " or "Создать файл ") .. rel, diff = diff_of(old, a.content) }
    end,
    run = function(a, ctx, done, plan)
      local ok, err = write_text(plan.abs, a.content)
      if not ok then return done(nil, err) end
      done(("%s %s (%d строк)"):format(plan.existed and "Перезаписан" or "Создан", plan.rel, count_lines(a.content)))
    end,
  },

  {
    name = "edit_file",
    category = "write",
    description = "Edit an existing file by replacing an exact piece of text. old_string must match the file exactly (including whitespace) and be unique unless replace_all is true. Read the file first.",
    parameters = {
      type = "object",
      properties = {
        path = { type = "string", description = "File path relative to the project root" },
        old_string = { type = "string", description = "Exact text to replace" },
        new_string = { type = "string", description = "Replacement text" },
        replace_all = { type = "boolean", description = "Replace every occurrence (default false)" },
      },
      required = { "path", "old_string", "new_string" },
    },
    summarize = function(a) return a.path end,
    prepare = function(a, ctx)
      local abs, rel = sandbox.resolve(ctx, a.path, { write = true })
      if not abs then return nil, rel end
      if a.old_string == "" then return nil, "old_string не может быть пустым (для нового файла используйте write_file)" end
      if a.old_string == a.new_string then return nil, "old_string и new_string совпадают — менять нечего" end
      local content, err = read_text(abs)
      if not content then return nil, ("%s: %s"):format(rel, err) end
      local n = count_plain(content, a.old_string)
      if n == 0 then
        return nil, "old_string не найден в файле. Перечитайте файл (read_file) и скопируйте фрагмент точно, с пробелами и переводами строк."
      end
      if n > 1 and not a.replace_all then
        return nil, ("old_string встречается %d раз(а). Добавьте контекст, чтобы фрагмент был уникальным, или укажите replace_all=true."):format(n)
      end
      local new = replace_plain(content, a.old_string, a.new_string, a.replace_all)
      return { abs = abs, rel = rel, new = new, n = a.replace_all and n or 1 },
        { title = "Изменить файл " .. rel, diff = diff_of(content, new) }
    end,
    run = function(_, _, done, plan)
      local ok, err = write_text(plan.abs, plan.new)
      if not ok then return done(nil, err) end
      done(("Изменён %s (замен: %d)"):format(plan.rel, plan.n))
    end,
  },

  {
    name = "create_dir",
    category = "write",
    description = "Create a directory (with parents).",
    parameters = {
      type = "object",
      properties = { path = { type = "string", description = "Directory path relative to the project root" } },
      required = { "path" },
    },
    summarize = function(a) return a.path end,
    prepare = function(a, ctx)
      local abs, rel = sandbox.resolve(ctx, a.path, { write = true })
      if not abs then return nil, rel end
      if uv.fs_stat(abs) then return nil, rel .. " уже существует" end
      return { abs = abs, rel = rel }, { title = "Создать папку " .. rel }
    end,
    run = function(_, _, done, plan)
      vim.fn.mkdir(plan.abs, "p")
      done("Создана папка " .. plan.rel)
    end,
  },

  {
    name = "move_path",
    category = "write",
    description = "Move or rename a file or directory. Fails if the destination already exists.",
    parameters = {
      type = "object",
      properties = {
        from = { type = "string", description = "Source path" },
        to = { type = "string", description = "Destination path" },
      },
      required = { "from", "to" },
    },
    summarize = function(a) return ("%s → %s"):format(a.from, a.to) end,
    prepare = function(a, ctx)
      local src, srel = sandbox.resolve(ctx, a.from, { write = true })
      if not src then return nil, srel end
      local dst, drel = sandbox.resolve(ctx, a.to, { write = true })
      if not dst then return nil, drel end
      if src == ctx.root then return nil, "Корень проекта переносить нельзя" end
      if not uv.fs_stat(src) then return nil, srel .. " не найден" end
      if uv.fs_stat(dst) then return nil, drel .. " уже существует" end
      return { src = src, dst = dst, srel = srel, drel = drel }, { title = ("Переместить %s → %s"):format(srel, drel) }
    end,
    run = function(_, _, done, plan)
      vim.fn.mkdir(vim.fs.dirname(plan.dst), "p")
      local ok, err = uv.fs_rename(plan.src, plan.dst)
      if not ok then return done(nil, "Не удалось переместить: " .. tostring(err)) end
      done(("Перемещено %s → %s"):format(plan.srel, plan.drel))
    end,
  },

  {
    name = "delete_path",
    category = "delete",
    description = "Delete a file or directory. It is moved to a recoverable trash folder, not erased permanently.",
    parameters = {
      type = "object",
      properties = { path = { type = "string", description = "Path to delete" } },
      required = { "path" },
    },
    summarize = function(a) return a.path end,
    prepare = function(a, ctx)
      local abs, rel = sandbox.resolve(ctx, a.path, { write = true })
      if not abs then return nil, rel end
      if abs == ctx.root then return nil, "Корень проекта удалять нельзя" end
      local st = uv.fs_lstat(abs)
      if not st then return nil, rel .. " не найден" end
      return { abs = abs, rel = rel, type = st.type }, { title = ("Удалить %s %s (в корзину)"):format(st.type == "directory" and "папку" or "файл", rel) }
    end,
    run = function(_, ctx, done, plan)
      local trash = ("%s/aqua_ai/trash/%s/%s"):format(vim.fn.stdpath("state"), os.date("%Y%m%d-%H%M%S"), vim.fn.fnamemodify(ctx.root, ":t"))
      local dst = trash .. "/" .. plan.rel
      vim.fn.mkdir(vim.fs.dirname(dst), "p")
      local ok, err = uv.fs_rename(plan.abs, dst)
      if not ok then
        -- rename между томами может не сработать — копируем и удаляем
        local r = vim.system({ "cp", "-R", plan.abs, dst }):wait()
        if r.code ~= 0 then return done(nil, "Не удалось удалить: " .. tostring(err)) end
        vim.fn.delete(plan.abs, "rf")
      end
      local b = buf_of(plan.abs)
      if b then pcall(vim.cmd, "silent! bwipeout! " .. b) end
      done(("Удалено %s (копия в корзине: %s)"):format(plan.rel, dst))
    end,
  },

  {
    name = "open_in_editor",
    category = "read",
    description = "Open a file in the user's Neovim editor (optionally at a line) so the user can see it.",
    parameters = {
      type = "object",
      properties = {
        path = { type = "string", description = "File path" },
        line = { type = "integer", description = "Line to jump to" },
      },
      required = { "path" },
    },
    summarize = function(a) return a.path end,
    run = function(a, ctx, done)
      local abs, rel = sandbox.resolve(ctx, a.path)
      if not abs then return done(nil, rel) end
      if not uv.fs_stat(abs) then return done(nil, rel .. " не найден") end
      require("aqua.ai.ui").open_in_editor(abs, a.line)
      done("Открыт " .. rel .. (a.line and (":" .. a.line) or ""))
    end,
  },
}

return M
