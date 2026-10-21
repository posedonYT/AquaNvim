-- Версии установленных инструментов (компиляторов, рантаймов). Только запуск «--version»,
-- код проекта не исполняется. Таймаут, чтобы зависший бинарник не подвешивал Neovim;
-- кэш на время работы Neovim (с учётом $PATH).
local M = {}

M.timeout = 3000

---@type table<string, { cmd: string[], parse: fun(out: string): (string?, table?) }>
M.specs = {
  go = {
    cmd = { "go", "env", "GOVERSION" },
    parse = function(out) return out:match("go(%d[%w%.]*)") end,
  },
  node = {
    cmd = { "node", "--version" },
    parse = function(out) return out:match("v?(%d+%.%d+%.%d+)") end,
  },
  python = {
    cmd = { "python3", "--version" },
    parse = function(out) return out:match("Python%s+(%d+%.%d+[%.%d]*)") end,
  },
  rustc = {
    cmd = { "rustc", "--version" },
    parse = function(out) return out:match("rustc%s+(%d+%.%d+%.%d+)") end,
  },
  clang = {
    cmd = { "clang", "--version" },
    parse = function(out)
      local v = out:match("clang version%s+(%d+%.%d+%.?%d*)")
      return v, { apple = out:find("Apple clang", 1, true) ~= nil, name = out:find("Apple clang", 1, true) and "Apple clang" or "clang" }
    end,
  },
  gcc = {
    cmd = { "gcc", "--version" },
    parse = function(out)
      if out:find("clang", 1, true) then
        -- на macOS gcc — это обёртка над Apple clang
        local v = out:match("clang version%s+(%d+%.%d+%.?%d*)")
        return v, { apple = true, alias_of = "clang", name = "Apple clang (gcc)" }
      end
      return out:match("%)%s+(%d+%.%d+%.?%d*)") or out:match("gcc[^%d]*(%d+%.%d+%.?%d*)"), { name = "gcc" }
    end,
  },
}

M.cache = {}

function M.clear()
  M.cache = {}
end

--- Версия инструмента или nil (не установлен / не ответил).
---@param tool string ключ из M.specs
---@return string? version, table? info
function M.version(tool)
  local spec = M.specs[tool]
  if not spec then
    return nil
  end
  local key = tool .. "\0" .. (vim.env.PATH or "")
  local hit = M.cache[key]
  if hit then
    return hit.version, hit.info
  end
  local version, info
  if vim.fn.executable(spec.cmd[1]) == 1 then
    local ok, res = pcall(function()
      return vim.system(spec.cmd, { text = true, env = { GOTOOLCHAIN = "local" } }):wait(M.timeout)
    end)
    if ok and res and res.code == 0 then
      version, info = spec.parse((res.stdout or "") .. (res.stderr or ""))
    end
  end
  M.cache[key] = { version = version, info = info }
  return version, info
end

return M
