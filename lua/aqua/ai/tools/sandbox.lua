-- Песочница путей: файловые инструменты работают только внутри корня проекта.
-- Защита от `..`, симлинков наружу и записи в .git.
local M = {}

local uv = vim.uv or vim.loop

local function inside(root, p)
  return p == root or p:sub(1, #root + 1) == root .. "/"
end

--- Ближайший существующий предок пути (для проверки симлинков у ещё не созданных файлов).
local function existing_ancestor(p)
  while p and p ~= "/" and not uv.fs_stat(p) do
    p = vim.fs.dirname(p)
  end
  return p
end

---@class aqua.ai.Ctx
---@field root string   корень проекта (realpath)
---@field cfg table

---@param ctx aqua.ai.Ctx
---@param path? string
---@param opts? { write?: boolean }
---@return string? abs, string? rel_or_err
function M.resolve(ctx, path, opts)
  opts = opts or {}
  local root = ctx.root
  if type(path) ~= "string" or path == "" then
    path = "."
  end
  if path:sub(1, 1) == "~" then
    path = vim.fn.expand(path)
  end
  local abs = path:sub(1, 1) == "/" and path or (root .. "/" .. path)
  abs = vim.fs.normalize(abs):gsub("/+$", "")
  if abs == "" then
    abs = "/"
  end

  if not ctx.cfg.allow_outside_root then
    if not inside(root, abs) then
      return nil, ("Путь вне проекта запрещён: %s (корень проекта: %s)"):format(path, root)
    end
    local anc = existing_ancestor(abs)
    local real = anc and uv.fs_realpath(anc)
    if real and not inside(root, real) then
      return nil, ("Путь ведёт за пределы проекта через симлинк: %s"):format(path)
    end
  end

  local rel = abs == root and "." or (inside(root, abs) and abs:sub(#root + 2) or abs)
  if opts.write then
    for seg in rel:gmatch("[^/]+") do
      if seg == ".git" then
        return nil, "Запись в .git запрещена"
      end
    end
  end
  return abs, rel
end

--- Нужен ли этому файлу/папке путь «относительно корня» для показа пользователю.
function M.rel(ctx, abs)
  return abs == ctx.root and "." or (inside(ctx.root, abs) and abs:sub(#ctx.root + 2) or abs)
end

return M
