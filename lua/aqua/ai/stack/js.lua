-- JavaScript / TypeScript: package.json, lock-файлы, .nvmrc, tsconfig, установленный node.
local version = require("aqua.ai.stack.version")
local probe = require("aqua.ai.stack.probe")

local M = {}

local function json(text)
  if not text then return nil end
  local ok, obj = pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  if ok and type(obj) == "table" then return obj end
  -- tsconfig и т. п. допускают комментарии и висячие запятые
  local cleaned = text:gsub("/%*.-%*/", ""):gsub("\n%s*//[^\n]*", "\n"):gsub(",(%s*[}%]])", "%1")
  ok, obj = pcall(vim.json.decode, cleaned, { luanil = { object = true, array = true } })
  return ok and type(obj) == "table" and obj or nil
end
M.json = json

--- Точные версии из lock-файлов: { [name] = version }.
function M.parse_lock(name, text)
  local res = {}
  if not text then return res end
  if name == "package-lock.json" then
    local obj = json(text) or {}
    for path, info in pairs(obj.packages or {}) do
      local pkg = path:match("^node_modules/(.+)$")
      if pkg and not pkg:find("/node_modules/", 1, true) and type(info) == "table" and info.version then
        res[pkg] = info.version
      end
    end
    for pkg, info in pairs(obj.dependencies or {}) do -- lockfile v1
      if res[pkg] == nil and type(info) == "table" and info.version then res[pkg] = info.version end
    end
  elseif name == "pnpm-lock.yaml" then
    -- "  /express@4.21.2:" (v6) или "  express@4.21.2:" (v9)
    for pkg, ver in text:gmatch("\n%s+'?/?(@?[^@%s'\n]+)@(%d[^:'%s(\n]*)'?:") do
      res[pkg] = res[pkg] or ver
    end
  elseif name == "yarn.lock" then
    for header, ver in text:gmatch('\n"?([^\n]-):\n%s+version:?%s+"?([^"\n]+)"?') do
      local pkg = header:match("^(@?[^@,]+)@")
      if pkg then res[pkg] = res[pkg] or ver end
    end
  end
  return res
end

---@param ctx aqua.stack.Ctx
function M.detect(ctx)
  local pj_path = ctx.files["package.json"] and ctx.files["package.json"][1]
  if not pj_path then return nil end
  local dir = vim.fs.dirname(pj_path)
  local pj = json(ctx.read(pj_path)) or {}

  local eco = {
    id = "js", name = "JavaScript/TypeScript", manifests = { ctx.rel(pj_path) }, deps = {},
    warnings = {}, targets = {}, dir = dir, indirect_count = 0,
  }
  eco.package_manager = pj.packageManager

  local resolved, lock_name = {}, nil
  for _, lock in ipairs({ "package-lock.json", "pnpm-lock.yaml", "yarn.lock" }) do
    local text = ctx.read(dir .. "/" .. lock)
    if text then
      resolved = M.parse_lock(lock, text)
      lock_name = lock
      table.insert(eco.manifests, ctx.rel(dir .. "/" .. lock))
      break
    end
  end
  eco.lockfile = lock_name

  local function add(deps, dev)
    local names = vim.tbl_keys(deps or {})
    table.sort(names)
    for _, n in ipairs(names) do
      table.insert(eco.deps, { name = n, version = resolved[n] or deps[n], range = deps[n], direct = true, dev = dev or nil })
    end
  end
  add(pj.dependencies, false)
  add(pj.devDependencies, true)

  -- node: .nvmrc / .node-version / engines
  local nvmrc = ctx.read(dir .. "/.nvmrc") or ctx.read(dir .. "/.node-version")
  eco.declared = (nvmrc and vim.trim(nvmrc)) or (pj.engines and pj.engines.node)
  eco.installed = probe.version("node")
  if eco.installed and eco.declared and version.parse(eco.declared) then
    local want = version.parse(eco.declared)
    if tonumber(version.major(eco.installed)) < want.nums[1] then
      table.insert(eco.warnings, ("установлен Node %s, а проект требует %s"):format(eco.installed, eco.declared))
    end
  end
  local node_ver = version.major(eco.installed or eco.declared)
  if node_ver then
    table.insert(eco.targets, { lang = "node", version = node_ver, label = "Node.js " .. node_ver })
  end
  eco.language_version = node_ver

  -- TypeScript: версия из lock / node_modules / диапазона
  local ts = resolved.typescript
  if not ts then
    local tspj = json(ctx.read(dir .. "/node_modules/typescript/package.json"))
    ts = tspj and tspj.version
  end
  ts = ts or (pj.devDependencies and pj.devDependencies.typescript) or (pj.dependencies and pj.dependencies.typescript)
  if ts and version.parse(ts) then
    eco.typescript = version.clean(ts)
    local mm = version.major_minor(ts)
    table.insert(eco.targets, { lang = "typescript", version = mm, label = "TypeScript " .. mm })
    local tsconfig = json(ctx.read(dir .. "/tsconfig.json"))
    eco.ts_target = tsconfig and tsconfig.compilerOptions and tsconfig.compilerOptions.target
    if ctx.read(dir .. "/tsconfig.json") then table.insert(eco.manifests, ctx.rel(dir .. "/tsconfig.json")) end
  end
  if next(pj.dependencies or {}) or next(pj.devDependencies or {}) then
    if not lock_name then
      table.insert(eco.warnings, "нет lock-файла — точные версии зависимостей неизвестны (показаны диапазоны)")
    end
  end
  return eco
end

return M
