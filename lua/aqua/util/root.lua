-- Определение «корня проекта» для текущего файла.
-- Порядок: .git → корень LSP → маркеры проекта → папка файла → cwd.
local M = {}

M.markers = {
  "package.json", "Cargo.toml", "go.mod", "pyproject.toml", "setup.py",
  "requirements.txt", "composer.json", "Gemfile", "deno.json", "Makefile",
}

--- Последний «настоящий» файловый буфер (не explorer / терминал / picker).
M.last_file_buf = nil

---@param buf? integer
function M.is_file_buf(buf)
  buf = buf or 0
  return vim.api.nvim_buf_is_valid(buf)
    and vim.bo[buf].buftype == ""
    and vim.api.nvim_buf_get_name(buf) ~= ""
end

--- Буфер, относительно которого считаем директории: текущий, если он файловый,
--- иначе последний файловый (когда фокус в explorer, Claude или терминале).
function M.context_buf()
  local cur = vim.api.nvim_get_current_buf()
  if M.is_file_buf(cur) then
    return cur
  end
  if M.last_file_buf and M.is_file_buf(M.last_file_buf) then
    return M.last_file_buf
  end
  return cur
end

local function realpath(path)
  if not path or path == "" then
    return nil
  end
  path = vim.fs.normalize(path)
  return (vim.uv or vim.loop).fs_realpath(path) or path
end

--- Папка файла в буфере (или cwd, если у буфера нет файла).
---@param buf? integer
function M.file_dir(buf)
  buf = buf or M.context_buf()
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" or vim.bo[buf].buftype ~= "" then
    return realpath(vim.fn.getcwd())
  end
  return realpath(vim.fs.dirname(name))
end

---@param buf integer
local function lsp_root(buf)
  local path = vim.api.nvim_buf_get_name(buf)
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
    local folders = client.config.workspace_folders or {}
    for _, ws in ipairs(folders) do
      local root = vim.uri_to_fname(ws.uri)
      if path:find(root, 1, true) == 1 then
        return root
      end
    end
    local root = client.config.root_dir
    if type(root) == "string" and path:find(root, 1, true) == 1 then
      return root
    end
  end
end

--- Корень проекта для буфера.
---@param buf? integer
function M.get(buf)
  buf = buf or M.context_buf()
  if not M.is_file_buf(buf) then
    return realpath(vim.fn.getcwd())
  end
  local root = vim.fs.root(buf, { ".git" }) or lsp_root(buf) or vim.fs.root(buf, M.markers)
  return realpath(root) or M.file_dir(buf)
end

function M.setup()
  vim.api.nvim_create_autocmd("BufEnter", {
    group = vim.api.nvim_create_augroup("aqua_root_track", { clear = true }),
    callback = function(ev)
      if M.is_file_buf(ev.buf) then
        M.last_file_buf = ev.buf
      end
    end,
  })
end

return M
