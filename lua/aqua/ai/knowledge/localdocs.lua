-- Локальная документация точной установленной версии — без сети и без исполнения кода проекта:
--   Go: `go doc` (разбирает исходники stdlib и модулей из кэша, код не запускает)
--   TypeScript/JS: объявления типов .d.ts из node_modules
local M = {}

M.go_timeout = 15000

--- Символ для go doc: только «пакет[.Символ[.Метод]]», без флагов.
function M.valid_go_symbol(s)
  return type(s) == "string" and s ~= "" and s:sub(1, 1) ~= "-" and s:match("^[%w%._/%-~]+$") ~= nil
end

--- go doc [-all] <symbol> в каталоге модуля.
---@param dir string
---@param symbol string
---@param all boolean?
---@param cb fun(text?: string, err?: string)
function M.go_doc(dir, symbol, all, cb)
  if vim.fn.executable("go") ~= 1 then
    return cb(nil, "Go не установлен (нет go в PATH)")
  end
  if not M.valid_go_symbol(symbol) then
    return cb(nil, "Некорректное имя для go doc: " .. tostring(symbol) .. " (пример: slices.Collect, net/http.Client)")
  end
  local cmd = { "go", "doc" }
  if all then cmd[#cmd + 1] = "-all" end
  cmd[#cmd + 1] = symbol
  vim.system(cmd, {
    cwd = dir,
    text = true,
    timeout = M.go_timeout,
    env = { GOTOOLCHAIN = "local", GOFLAGS = "-mod=readonly", GOWORK = "off" },
  }, function(res)
    vim.schedule(function()
      local out = vim.trim((res.stdout or "") .. "\n" .. (res.stderr or ""))
      if res.code ~= 0 then
        return cb(nil, ("go doc %s: %s"):format(symbol, out ~= "" and out or ("код " .. res.code)))
      end
      if #out > 30000 then
        out = out:sub(1, 30000) .. "\n... [обрезано — уточните символ, например pkg.Type]"
      end
      cb(out)
    end)
  end)
end

local function read(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

--- Файл объявлений типов пакета (types/typings/index.d.ts или @types/<pkg>).
---@return string? path
function M.ts_types_path(dir, pkg)
  local function from(base)
    local pj = read(base .. "/package.json")
    local ok, obj = pcall(vim.json.decode, pj or "")
    local rel = ok and type(obj) == "table" and (obj.types or obj.typings) or nil
    for _, cand in ipairs({ rel, "index.d.ts", "dist/index.d.ts" }) do
      if cand and vim.fn.filereadable(base .. "/" .. cand) == 1 then
        return base .. "/" .. cand
      end
    end
  end
  return from(dir .. "/node_modules/" .. pkg) or from(dir .. "/node_modules/@types/" .. pkg:gsub("^@", ""):gsub("/", "__"))
end

--- Объявления типов пакета (с фильтром по символу).
---@param dir string каталог с node_modules
---@param pkg string
---@param symbol? string
function M.ts_types(dir, pkg, symbol)
  if not pkg:match("^[@%w%._%-/]+$") or pkg:find("..", 1, true) then
    return nil, "Некорректное имя пакета: " .. pkg
  end
  local path = M.ts_types_path(dir, pkg)
  if not path then
    return nil, ("Нет объявлений типов для %s в node_modules (пакет не установлен или без .d.ts)"):format(pkg)
  end
  local text = read(path) or ""
  local header = ("%s (%s)\n"):format(pkg, path:sub(#dir + 2))
  if not symbol or symbol == "" then
    return header .. (#text > 30000 and (text:sub(1, 30000) .. "\n... [обрезано — укажите символ]") or text)
  end
  local lines = vim.split(text, "\n", { plain = true })
  local out, shown = {}, 0
  for i, l in ipairs(lines) do
    if l:find(symbol, 1, true) and (l:match("^%s*export") or l:match("^%s*declare") or l:match("^%s*interface")
      or l:match("^%s*type") or l:match("^%s*function") or l:match("^%s*class") or l:match("^%s*%w+%s*[%(:<]")) then
      out[#out + 1] = ("-- %s:%d"):format(path:sub(#dir + 2), i)
      for j = math.max(1, i - 3), math.min(#lines, i + 25) do out[#out + 1] = lines[j] end
      shown = shown + 1
      if shown >= 5 then break end
    end
  end
  if shown == 0 then
    return nil, ("«%s» не найден в объявлениях %s"):format(symbol, pkg)
  end
  return header .. table.concat(out, "\n")
end

return M
