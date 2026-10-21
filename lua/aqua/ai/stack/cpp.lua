-- C / C++: стандарт (C++23/26, C17/23) из CMake / compile_commands / meson / Makefile,
-- компилятор (clang/gcc/Apple clang), зависимости vcpkg/conan/find_package.
local version = require("aqua.ai.stack.version")
local probe = require("aqua.ai.stack.probe")

local M = {}

local CXX_ALIASES = { ["2c"] = "26", ["2b"] = "23", ["2a"] = "20", ["1z"] = "17", ["1y"] = "14", ["0x"] = "11" }
local C_ALIASES = { ["2x"] = "23", ["2y"] = "2y", ["1x"] = "11" }

--- "-std=gnu++2b" → "c++", "23"
function M.normalize_std(flag)
  local lang, v = flag:match("^%a*(c%+%+)(%w+)$")
  if not lang then
    lang, v = flag:match("^gnu(%+%+)(%w+)$")
    if lang then lang = "c++" end
  end
  if lang then
    return "c++", CXX_ALIASES[v] or v
  end
  local cv = flag:match("^[%a]*c(%w+)$") or flag:match("^gnu(%w+)$") or flag:match("^iso9899:(%d+)$")
  if cv then
    cv = C_ALIASES[cv] or cv
    if cv == "99" or cv == "11" or cv == "17" or cv == "18" or cv == "23" or cv == "89" or cv == "90" then
      return "c", cv == "18" and "17" or cv
    end
  end
  return nil
end

function M.parse_cmake(text)
  local res = { find_packages = {} }
  text = text or ""
  res.cxx = text:match("set%s*%(%s*CMAKE_CXX_STANDARD%s+(%d+)") or text:match("cxx_std_(%d+)")
  res.c = text:match("set%s*%(%s*CMAKE_C_STANDARD%s+(%d+)") or text:match("c_std_(%d+)")
  res.minimum = text:match("cmake_minimum_required%s*%(%s*VERSION%s+([%d%.]+)")
  local langs = text:match("project%s*%b()")
  res.languages = langs and langs:match("LANGUAGES%s+([%u%s]+)") or nil
  for name in text:gmatch("find_package%s*%(%s*([%w_%-]+)") do
    table.insert(res.find_packages, name)
  end
  return res
end

--- compile_commands.json → { std = {lang, ver}, compiler = path }
function M.parse_compile_commands(text)
  local ok, entries = pcall(vim.json.decode, text or "[]")
  if not ok or type(entries) ~= "table" then return {} end
  local res = { files = {} }
  for _, e in ipairs(entries) do
    local args = e.arguments or vim.split(e.command or "", "%s+")
    res.compiler = res.compiler or args[1]
    for _, a in ipairs(args) do
      local std = a:match("^%-std=(%S+)$")
      if std then
        local lang, v = M.normalize_std(std)
        if lang == "c++" then res.cxx = res.cxx or v elseif lang == "c" then res.c = res.c or v end
      end
    end
    if e.file then
      local f = e.file:sub(1, 1) == "/" and e.file or ((e.directory or "") .. "/" .. e.file)
      res.files[vim.fs.normalize(f)] = { directory = e.directory, arguments = args }
    end
  end
  return res
end

local function stds_in_flags(text, res)
  for std in (text or ""):gmatch("%-std=([%w%+:]+)") do
    local lang, v = M.normalize_std(std)
    if lang == "c++" then res.cxx = res.cxx or v elseif lang == "c" then res.c = res.c or v end
  end
  local meson_cpp = (text or ""):match("cpp_std%s*=%s*'?([%w%+]+)'?")
  if meson_cpp then local _, v = M.normalize_std(meson_cpp) res.cxx = res.cxx or v end
  local meson_c = (text or ""):match("c_std%s*=%s*'?([%w]+)'?")
  if meson_c then local _, v = M.normalize_std(meson_c) res.c = res.c or v end
end

---@param ctx aqua.stack.Ctx
function M.detect(ctx)
  local f = ctx.files
  local cmake = f["CMakeLists.txt"] and f["CMakeLists.txt"][1]
  local ccj = f["compile_commands.json"] and f["compile_commands.json"][1]
  local meson = f["meson.build"] and f["meson.build"][1]
  local makefile = f["Makefile"] and f["Makefile"][1]
  local vcpkg = f["vcpkg.json"] and f["vcpkg.json"][1]
  local conan = f["conanfile.txt"] and f["conanfile.txt"][1]

  local res = { find_packages = {} }
  local eco = { id = "cpp", name = "C/C++", manifests = {}, deps = {}, warnings = {}, targets = {}, indirect_count = 0 }
  local mk_text = makefile and ctx.read(makefile)
  local mk_is_c = mk_text and (mk_text:find("-std=", 1, true) or mk_text:find("$(CC)", 1, true) or mk_text:find("$(CXX)", 1, true)
    or mk_text:find("g++", 1, true) or mk_text:find("clang", 1, true))
  if not (cmake or ccj or meson or mk_is_c or vcpkg or conan or (ctx.sources or 0) > 0) then
    return nil
  end

  if cmake then
    table.insert(eco.manifests, ctx.rel(cmake))
    res = M.parse_cmake(ctx.read(cmake))
    eco.dir = vim.fs.dirname(cmake)
  end
  if ccj then
    table.insert(eco.manifests, ctx.rel(ccj))
    local cc = M.parse_compile_commands(ctx.read(ccj))
    res.cxx = res.cxx or cc.cxx
    res.c = res.c or cc.c
    eco.compiler_path = cc.compiler
    eco.compile_commands = cc.files
  end
  if meson then
    table.insert(eco.manifests, ctx.rel(meson))
    stds_in_flags(ctx.read(meson), res)
    eco.dir = eco.dir or vim.fs.dirname(meson)
  end
  if mk_is_c then
    table.insert(eco.manifests, ctx.rel(makefile))
    stds_in_flags(mk_text, res)
    eco.dir = eco.dir or vim.fs.dirname(makefile)
  end
  eco.dir = eco.dir or ctx.root

  for _, name in ipairs(res.find_packages or {}) do
    table.insert(eco.deps, { name = name, version = "find_package", direct = true })
  end
  if vcpkg then
    table.insert(eco.manifests, ctx.rel(vcpkg))
    local ok, obj = pcall(vim.json.decode, ctx.read(vcpkg) or "{}")
    for _, d in ipairs(ok and type(obj) == "table" and obj.dependencies or {}) do
      local name = type(d) == "table" and d.name or d
      table.insert(eco.deps, { name = name, version = type(d) == "table" and d["version>="] or "vcpkg", direct = true })
    end
  end
  if conan then
    table.insert(eco.manifests, ctx.rel(conan))
    local in_req = false
    for line in (ctx.read(conan) or ""):gmatch("[^\n]+") do
      local sect = line:match("^%[(.-)%]")
      if sect then in_req = sect == "requires" elseif in_req then
        local name, ver = vim.trim(line):match("^([^/]+)/([^@%s]+)")
        if name then table.insert(eco.deps, { name = name, version = ver, direct = true }) end
      end
    end
  end

  eco.cxx_std, eco.c_std = res.cxx, res.c
  -- компилятор
  local compiler_name = eco.compiler_path and vim.fs.basename(eco.compiler_path) or ""
  local v, info
  -- «clang++» содержит подстроку «g++», поэтому сравниваем имя целиком
  if compiler_name:match("^g%+%+") or compiler_name:match("gcc") or compiler_name:match("%-g%+%+") then
    v, info = probe.version("gcc")
  else
    v, info = probe.version("clang")
    if not v then v, info = probe.version("gcc") end
  end
  if v then
    eco.installed = v
    eco.compiler = ((info and info.name) or "compiler") .. " " .. v
    if info and info.name == "gcc" then
      table.insert(eco.targets, { lang = "gcc", version = version.major(v), label = "GCC " .. version.major(v) })
    elseif info and not info.apple then
      table.insert(eco.targets, { lang = "clang", version = version.clean(v), label = "Clang " .. version.major(v) })
    end
  else
    table.insert(eco.warnings, "компилятор C/C++ (clang/gcc) не найден в PATH")
  end
  if res.cxx then
    table.insert(eco.targets, 1, { lang = "c++", version = res.cxx, label = "C++" .. res.cxx })
  end
  if res.c then
    table.insert(eco.targets, { lang = "c", version = res.c, label = "C" .. res.c })
  end
  if not res.cxx and not res.c then
    table.insert(eco.warnings, "стандарт языка не указан (CMAKE_CXX_STANDARD / -std=) — используется стандарт компилятора по умолчанию")
  end
  eco.declared = res.cxx and ("C++" .. res.cxx) or (res.c and ("C" .. res.c)) or nil
  eco.language_version = eco.declared
  return eco
end

return M
