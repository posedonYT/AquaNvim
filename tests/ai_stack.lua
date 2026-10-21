-- Тесты «стек проекта и знания о версиях» для Aqua AI. Подключаются из tests/run.lua.
-- Сеть не нужна: документация и модель — tests/mock_llm.py; компиляторы — поддельные скрипты в PATH.
return function(T)
  local describe, it, eq, ok, wait, tmp, real = T.describe, T.it, T.eq, T.ok, T.wait, T.tmp, T.real
  local uv = vim.uv or vim.loop

  local version = require("aqua.ai.stack.version")
  local toml = require("aqua.ai.stack.toml")
  local probe = require("aqua.ai.stack.probe")
  local stack = require("aqua.ai.stack")
  local golang = require("aqua.ai.stack.go")
  local js = require("aqua.ai.stack.js")
  local python = require("aqua.ai.stack.python")
  local cpp = require("aqua.ai.stack.cpp")
  local digest = require("aqua.ai.knowledge.digest")
  local sources = require("aqua.ai.knowledge.sources")
  local kn = require("aqua.ai.knowledge")
  local config = require("aqua.ai.config")
  local tools = require("aqua.ai.tools")
  local permissions = require("aqua.ai.permissions")
  local session_mod = require("aqua.ai.session")

  local base = real(tmp) .. "/stack"
  local orig_path = vim.env.PATH
  local real_python = vim.fn.exepath("python3")

  local function write(path, content)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "w"))
    f:write(content)
    f:close()
  end

  local function fakebin(dir, name, script)
    write(dir .. "/" .. name, "#!/bin/sh\n" .. script .. "\n")
    vim.fn.setfperm(dir .. "/" .. name, "rwxr-xr-x")
  end

  -- Поддельные инструменты: «новые» версии, «старые» и GNU gcc
  local bin_new, bin_old, bin_gnu = base .. "/bin_new", base .. "/bin_old", base .. "/bin_gnu"
  fakebin(bin_new, "go", [[
case "$1" in
  env) echo go1.27.2 ;;
  doc) if [ "$2" = "uuid" ]; then echo "package uuid // import \"uuid\""; echo "func NewV7() UUID"; else echo "doc: no symbol $2" >&2; exit 1; fi ;;
  build) echo "./main.go:3:2: undefined: Foo" >&2; exit 1 ;;
  vet) echo "vet: ok" ;;
  test) sleep 10 ;;
esac]])
  fakebin(bin_new, "node", "echo v24.11.0")
  fakebin(bin_new, "rustc", "echo 'rustc 1.91.0 (f8297e351 2025-10-28)'")
  fakebin(bin_new, "clang", "echo 'Apple clang version 21.0.0 (clang-2100.3.34.2)'; echo 'Target: arm64-apple-darwin'")
  fakebin(bin_new, "python3", ('if [ "$1" = "--version" ]; then echo "Python 3.14.8"; else exec %q "$@"; fi'):format(real_python))
  fakebin(bin_old, "go", "echo go1.26.1")
  fakebin(bin_old, "python3", 'echo "Python 3.11.4"')
  fakebin(bin_old, "node", "echo v20.1.0")
  fakebin(bin_gnu, "gcc", "echo 'gcc (GCC) 15.1.0'")

  local function use_bin(dir)
    vim.env.PATH = dir .. ":" .. orig_path
  end
  local function restore_path()
    vim.env.PATH = orig_path
  end

  -- PATH возвращается на место после каждого теста, даже упавшего (иначе следующие тесты
  -- увидят поддельные компиляторы)
  local base_it = it
  it = function(name, fn)
    base_it(name, function()
      local okk, err = xpcall(fn, debug.traceback)
      restore_path()
      if not okk then error(err, 0) end
    end)
  end

  -- ── Фикстуры проектов ─────────────────────────────────────────────────────
  local goproj = base .. "/goproj"
  write(goproj .. "/go.mod", [[
// Сервис
module example.com/app

go 1.27

toolchain go1.27.2

require (
	example.com/a v1.2.3
	example.com/b v2.0.0 // pinned
	example.com/ind v0.1.0 // indirect
)

require example.com/single v0.9.0

replace example.com/a => ../a-local

replace (
	example.com/x v1.0.0 => example.com/y v1.1.0
)

exclude example.com/bad v0.0.1

retract v1.0.0 // oops
]])
  write(goproj .. "/go.sum", [[
example.com/a v1.2.3 h1:abc=
example.com/a v1.2.3/go.mod h1:def=
example.com/single v0.9.0 h1:x=
example.com/ind v0.1.0/go.mod h1:y=
]])
  write(goproj .. "/main.go", "package main\n\nfunc main() {}\n")
  write(goproj .. "/Makefile", "race:\n\tgo test -race ./...\n")

  local jsproj = base .. "/jsproj"
  write(jsproj .. "/package.json", vim.json.encode({
    name = "w", packageManager = "pnpm@9", engines = { node = ">=22" },
    dependencies = { express = "^4.21.0", ["@scope/lib"] = "~1.0.0" },
    devDependencies = { typescript = "^5.9.0" },
  }))
  write(jsproj .. "/package-lock.json", vim.json.encode({
    lockfileVersion = 3,
    packages = {
      [""] = { name = "w" },
      ["node_modules/express"] = { version = "4.21.2" },
      ["node_modules/@scope/lib"] = { version = "1.0.4" },
      ["node_modules/typescript"] = { version = "5.9.3" },
      ["node_modules/express/node_modules/debug"] = { version = "2.6.9" },
    },
  }))
  write(jsproj .. "/.nvmrc", "22.11.0\n")
  write(jsproj .. "/tsconfig.json", '{\n  // comment\n  "compilerOptions": { "target": "ES2023", "strict": true, },\n}\n')
  write(jsproj .. "/node_modules/ignored/package.json", '{"name":"ignored"}')
  write(jsproj .. "/node_modules/typed/package.json", '{"name":"typed","types":"lib/index.d.ts"}')
  write(jsproj .. "/node_modules/typed/lib/index.d.ts", "export interface Options {\n  retries: number;\n}\nexport declare function connect(url: string, opts?: Options): Promise<void>;\n")

  local pyproj = base .. "/pyproj"
  write(pyproj .. "/pyproject.toml", [[
[project]
name = "svc"
requires-python = ">=3.12"
dependencies = [
  "fastapi>=0.115",
  "uvicorn[standard]==0.30.1 ; python_version >= '3.12'",  # server
]
]])
  write(pyproj .. "/uv.lock", "version = 1\n\n[[package]]\nname = \"fastapi\"\nversion = \"0.115.6\"\n\n[[package]]\nname = \"uvicorn\"\nversion = \"0.30.1\"\n")
  write(pyproj .. "/.python-version", "3.13\n")
  write(pyproj .. "/app.py", "def ok():\n    return 1\n")
  write(pyproj .. "/bad.py", "def broken(:\n    pass\n")

  local rsproj = base .. "/rsproj"
  write(rsproj .. "/Cargo.toml", [[
[package]
name = "r"
edition = "2024"
rust-version = "1.85"

[dependencies]
serde = { version = "1.0", features = ["derive"] }
tokio = "1.40"
local = { path = "../local" }

[dev-dependencies]
proptest = "1"
]])
  write(rsproj .. "/Cargo.lock", "version = 4\n\n[[package]]\nname = \"serde\"\nversion = \"1.0.219\"\n\n[[package]]\nname = \"tokio\"\nversion = \"1.40.0\"\n")
  write(rsproj .. "/rust-toolchain.toml", "[toolchain]\nchannel = \"1.91\"\n")

  local cppproj = base .. "/cppproj"
  write(cppproj .. "/CMakeLists.txt", [[
cmake_minimum_required(VERSION 3.28)
project(demo VERSION 1.0 LANGUAGES CXX)
find_package(fmt REQUIRED)
add_executable(demo main.cpp)
target_compile_features(demo PRIVATE cxx_std_23)
]])
  write(cppproj .. "/main.cpp", "int main() { return 0; }\n")
  write(cppproj .. "/build/compile_commands.json", vim.json.encode({
    { directory = cppproj .. "/build", file = cppproj .. "/main.cpp",
      arguments = { "/usr/bin/clang++", "-std=c++2c", "-Wall", "-o", "CMakeFiles/demo.dir/main.cpp.o", "-c", cppproj .. "/main.cpp" } },
  }))

  local cproj = base .. "/cproj"
  write(cproj .. "/Makefile", "CFLAGS = -std=c17 -Wall\n\nall:\n\t$(CC) $(CFLAGS) main.c -o app\n")
  write(cproj .. "/main.c", "int main(void) { return 0; }\n")

  local gccproj = base .. "/gccproj"
  write(gccproj .. "/compile_commands.json", vim.json.encode({
    { directory = gccproj, file = "main.cpp", command = "/usr/bin/g++ -std=gnu++2b -c main.cpp -o main.o" },
  }))
  write(gccproj .. "/main.cpp", "int main() {}\n")

  local mono = base .. "/mono"
  write(mono .. "/go.mod", "module example.com/mono\n\ngo 1.27\n")
  write(mono .. "/web/package.json", '{"name":"web","dependencies":{"react":"19.2.0"}}')
  write(mono .. "/web/node_modules/react/package.json", '{"name":"react"}')

  local empty = base .. "/empty"
  vim.fn.mkdir(empty, "p")
  write(empty .. "/Makefile", "build:\n\tgo build ./...\n")

  -- ════════════════════════════════════════════════════════════════════════
  describe("Стек · версии и TOML", function()
    it("разбор и сравнение версий", function()
      eq(1, version.compare("go1.27.2", "1.27"))
      eq(0, version.compare("1.27", "1.27.0"))
      eq(-1, version.compare("1.26.1", "1.27"))
      eq(-1, version.compare("1.27rc1", "1.27"), "предрелиз меньше релиза")
      eq(1, version.compare("v9.10.0", "v9.7.0"), "числовое, а не строковое сравнение")
      eq("4.21.0", version.clean("^4.21.0"))
      eq("3.12", version.major_minor(">=3.12,<4"))
      eq("3.12", version.major_minor("~=3.12"))
      eq("24", version.major("v24.11.0"))
      eq("9.7.0", version.clean("v9.7.0"))
      eq(nil, version.parse("latest"))
    end)

    it("TOML: секции, массивы таблиц, многострочные массивы, inline-таблицы, комментарии", function()
      local t = toml.parse([=[
# comment
[project]
name = "x # not a comment"
deps = [
  "a>=1",  # c
  'b',
]
[dependencies]
serde = { version = "1.0", features = ["derive"] }
[[package]]
name = "p1"
version = "1.0.0"
[[package]]
name = "p2"
version = 2
enabled = true
]=])
      eq("x # not a comment", t.project.name)
      eq({ "a>=1", "b" }, t.project.deps)
      eq("1.0", t.dependencies.serde.version)
      eq({ "derive" }, t.dependencies.serde.features)
      eq(2, #t.package)
      eq("p2", t.package[2].name)
      eq(2, t.package[2].version)
      eq(true, t.package[2].enabled)
    end)
  end)

  describe("Стек · парсеры манифестов", function()
    it("go.mod: module, go, toolchain, require (блок и строка), indirect, replace, exclude, retract", function()
      local m = golang.parse_gomod(io.open(goproj .. "/go.mod"):read("*a"))
      eq("example.com/app", m.module)
      eq("1.27", m.go)
      eq("go1.27.2", m.toolchain)
      eq(4, #m.requires)
      eq({ name = "example.com/ind", version = "v0.1.0", direct = false }, m.requires[3])
      eq({ name = "example.com/single", version = "v0.9.0", direct = true }, m.requires[4])
      eq(true, m.requires[2].direct, "обычный комментарий ≠ indirect")
      eq("../a-local", m.replaces[1].to)
      eq("example.com/y", m.replaces[2].to)
      eq("v1.1.0", m.replaces[2].version)
      eq("example.com/bad", m.excludes[1].name)
      eq(1, #m.retracts)
    end)

    it("go.sum и go.work", function()
      local sum, n = golang.parse_gosum("example.com/a v1.2.3 h1:x=\nexample.com/a v1.2.3/go.mod h1:y=\nexample.com/b v0.1.0/go.mod h1:z=\n")
      eq(2, n)
      ok(sum["example.com/a"]["v1.2.3"] and sum["example.com/b"]["v0.1.0"])
      local w = golang.parse_gowork("go 1.27\n\nuse (\n\t./api\n\t./web // ui\n)\nuse ./tools\n")
      eq("1.27", w.go)
      eq({ "./api", "./web", "./tools" }, w.use)
    end)

    it("lock-файлы JS: package-lock v3 (без вложенных), pnpm, yarn", function()
      local pl = js.parse_lock("package-lock.json", io.open(jsproj .. "/package-lock.json"):read("*a"))
      eq("4.21.2", pl.express)
      eq("1.0.4", pl["@scope/lib"])
      eq(nil, pl.debug, "вложенные node_modules не считаются прямыми")
      local pn = js.parse_lock("pnpm-lock.yaml", "lockfileVersion: '9.0'\npackages:\n\n  express@4.21.2:\n    resolution: {}\n\n  '@types/node@22.10.1':\n    resolution: {}\n")
      eq("4.21.2", pn.express)
      eq("22.10.1", pn["@types/node"])
      local y = js.parse_lock("yarn.lock", '\n"express@^4.21.0":\n  version "4.21.2"\n\nreact@19.2.0, react@^19:\n  version "19.2.0"\n')
      eq("4.21.2", y.express)
      eq("19.2.0", y.react)
    end)

    it("Python: требования с extras и маркерами, requirements.txt, uv.lock", function()
      eq({ "uvicorn", "==0.30.1" }, { python.parse_requirement("uvicorn[standard]==0.30.1 ; python_version >= '3.12'") })
      eq({ "my-pkg", ">=1" }, { python.parse_requirement("My_Pkg>=1  # c") })
      eq(nil, python.parse_requirement("-r base.txt"))
      eq(2, #python.parse_requirements("a==1\n# c\n\nb>=2\n-e .\n"))
      eq("0.115.6", python.parse_lock(io.open(pyproj .. "/uv.lock"):read("*a")).fastapi)
    end)

    it("C/C++: стандарты из флагов, CMake, compile_commands", function()
      eq({ "c++", "26" }, { cpp.normalize_std("c++2c") })
      eq({ "c++", "23" }, { cpp.normalize_std("gnu++2b") })
      eq({ "c++", "17" }, { cpp.normalize_std("c++17") })
      eq({ "c", "17" }, { cpp.normalize_std("c17") })
      eq({ "c", "23" }, { cpp.normalize_std("gnu2x") })
      local c = cpp.parse_cmake(io.open(cppproj .. "/CMakeLists.txt"):read("*a"))
      eq("23", c.cxx)
      eq("3.28", c.minimum)
      eq({ "fmt" }, c.find_packages)
      local cc = cpp.parse_compile_commands(io.open(cppproj .. "/build/compile_commands.json"):read("*a"))
      eq("26", cc.cxx)
      eq("/usr/bin/clang++", cc.compiler)
      ok(cc.files[cppproj .. "/main.cpp"], "команда компиляции для файла")
    end)
  end)

  describe("Стек · определение проекта", function()
    it("Go: версии, toolchain, прямые и косвенные зависимости, go.sum, replace", function()
      use_bin(bin_new)
      local st = stack.detect(goproj)
      eq(1, #st.ecosystems, "Makefile с go-командами не считается C-проектом")
      local g = st.ecosystems[1]
      eq("go", g.id)
      eq("1.27", g.declared)
      eq("go1.27.2", g.toolchain)
      eq("1.27.2", g.installed)
      eq({ { lang = "go", version = "1.27", label = "Go 1.27" } }, g.targets)
      eq(3, #g.deps)
      eq(1, g.indirect_count)
      eq("../a-local", g.deps[1].replaced)
      local w = table.concat(g.warnings, "\n")
      ok(w:find("нет записи в go.sum: example.com/b v2.0.0", 1, true), w)
      ok(not w:find("example.com/a ", 1, true), "replace-зависимость не требует go.sum")
      ok(not w:find("установлен", 1, true), "версии совпадают")
      local s = stack.summary(st)
      ok(s:find("Go 1.27", 1, true) and s:find("toolchain go1.27.2", 1, true) and s:find("installed: go1.27.2", 1, true), s)
      ok(s:find("example.com/b v2.0.0", 1, true) and s:find("1 indirect", 1, true), s)
      restore_path()
    end)

    it("Go: установленный тулчейн старее требуемого → предупреждения", function()
      use_bin(bin_old)
      local g = stack.detect(goproj).ecosystems[1]
      local w = table.concat(g.warnings, "\n")
      ok(w:find("установлен Go 1.26.1, а go.mod требует go 1.27", 1, true), w)
      ok(w:find("toolchain в go.mod: go1.27.2", 1, true), w)
      restore_path()
    end)

    it("JS/TS: node из .nvmrc и установленный, TypeScript, точные версии из lock, tsconfig с комментариями", function()
      use_bin(bin_new)
      local st = stack.detect(jsproj)
      eq(1, #st.ecosystems, "node_modules не сканируется")
      local e = st.ecosystems[1]
      eq("22.11.0", e.declared)
      eq("24.11.0", e.installed)
      eq("5.9.3", e.typescript)
      eq("ES2023", e.ts_target)
      eq({ "node", "typescript" }, vim.tbl_map(function(t) return t.lang end, e.targets))
      eq("5.9", e.targets[2].version)
      local by = {}
      for _, d in ipairs(e.deps) do by[d.name] = d end
      eq("4.21.2", by.express.version)
      eq("^4.21.0", by.express.range)
      eq("1.0.4", by["@scope/lib"].version)
      eq(true, by.typescript.dev)
      eq(0, #e.warnings)
      restore_path()
    end)

    it("JS: установленный Node старее требуемого → предупреждение", function()
      use_bin(bin_old)
      local w = table.concat(stack.detect(jsproj).ecosystems[1].warnings, "\n")
      ok(w:find("установлен Node 20.1.0", 1, true), w)
      restore_path()
    end)

    it("Python: .python-version, requires-python, версии из uv.lock", function()
      use_bin(bin_new)
      local e = stack.detect(pyproj).ecosystems[1]
      eq("python", e.id)
      eq("3.13", e.declared)
      eq("3.14.8", e.installed)
      eq({ { lang = "python", version = "3.13", label = "Python 3.13" } }, e.targets)
      eq("0.115.6", e.deps[1].version)
      eq("uvicorn", e.deps[2].name)
      eq("0.30.1", e.deps[2].version)
      restore_path()
      use_bin(bin_old)
      local w = table.concat(stack.detect(pyproj).ecosystems[1].warnings, "\n")
      ok(w:find("установлен Python 3.11.4, а проект требует >=3.12", 1, true), w)
      restore_path()
    end)

    it("Rust: edition, rust-version, toolchain, версии из Cargo.lock, path-зависимости", function()
      use_bin(bin_new)
      local e = stack.detect(rsproj).ecosystems[1]
      eq("rust", e.id)
      eq("2024", e.edition)
      eq("1.91", e.toolchain)
      eq("1.91.0", e.installed)
      eq({ { lang = "rust", version = "1.91.0", label = "Rust 1.91" } }, e.targets)
      local by = {}
      for _, d in ipairs(e.deps) do by[d.name] = d end
      eq("1.0.219", by.serde.version)
      eq("1.40.0", by.tokio.version)
      eq("path", by["local"].version)
      eq(true, by.proptest.dev)
      restore_path()
    end)

    it("C++: стандарт из CMake важнее compile_commands, Apple clang, find_package", function()
      use_bin(bin_new)
      local e = stack.detect(cppproj).ecosystems[1]
      eq("cpp", e.id)
      eq("23", e.cxx_std)
      eq("Apple clang 21.0.0", e.compiler)
      eq({ { lang = "c++", version = "23", label = "C++23" } }, e.targets, "у Apple clang своя нумерация — изучаем стандарт")
      eq("fmt", e.deps[1].name)
      restore_path()
    end)

    it("C: стандарт из Makefile; GCC: заметки о выпуске компилятора", function()
      use_bin(bin_new)
      local c = stack.detect(cproj).ecosystems[1]
      eq("17", c.c_std)
      eq("c", c.targets[1].lang)
      restore_path()
      use_bin(bin_gnu)
      local g = stack.detect(gccproj).ecosystems[1]
      eq("23", g.cxx_std)
      eq("gcc 15.1.0", g.compiler)
      eq({ "c++", "gcc" }, vim.tbl_map(function(t) return t.lang end, g.targets))
      eq("15", g.targets[2].version)
      restore_path()
    end)

    it("монорепозиторий: Go в корне + JS во вложенной папке", function()
      use_bin(bin_new)
      local st = stack.detect(mono)
      eq({ "go", "js" }, vim.tbl_map(function(e) return e.id end, st.ecosystems))
      eq({ "Go 1.27", "Node.js 24" }, vim.tbl_map(function(t) return t.label end, stack.targets(st)))
      local dep = stack.find_dep(st, "react")
      eq("19.2.0", dep.version)
      restore_path()
    end)

    it("пустой проект: понятная сводка, нет целей", function()
      local st = stack.detect(empty)
      eq(0, #st.ecosystems)
      eq(0, #stack.targets(st))
      ok(stack.summary(st):find("No known project manifests", 1, true))
    end)

    it("кэш: повторный вызов без изменений не пересчитывает, изменение манифеста — пересчитывает", function()
      use_bin(bin_new)
      local a = stack.detect(goproj)
      eq(a, stack.detect(goproj), "тот же объект из кэша")
      local mtime = os.time() + 5
      local f = io.open(goproj .. "/go.mod", "a")
      f:write("\nrequire example.com/new v1.0.0\n")
      f:close()
      uv.fs_utime(goproj .. "/go.mod", mtime, mtime)
      local b = stack.detect(goproj)
      ok(a ~= b, "пересчитан")
      eq(4, #b.ecosystems[1].deps)
      restore_path()
    end)

    it("сводка укладывается в лимит даже при сотнях зависимостей", function()
      local big = base .. "/big"
      local lines = { "module big", "", "go 1.27", "", "require (" }
      for i = 1, 500 do lines[#lines + 1] = ("\texample.com/dep%03d v1.%d.0"):format(i, i) end
      lines[#lines + 1] = ")"
      write(big .. "/go.mod", table.concat(lines, "\n"))
      local st = stack.detect(big)
      local s = stack.summary(st, 1500)
      ok(#s <= 1500, "длина " .. #s)
      ok(s:find("more (see project_stack)", 1, true), s)
      ok(#stack.report(st) > 10000, "полный отчёт — все зависимости")
    end)

    it("проба зависшего бинарника не вешает Neovim", function()
      fakebin(base .. "/bin_slow", "slowtool", "sleep 10; echo 1.0.0")
      probe.specs.slowtool = { cmd = { base .. "/bin_slow/slowtool" }, parse = function(o) return o:match("[%d%.]+") end }
      local saved = probe.timeout
      probe.timeout = 300
      local t0 = uv.hrtime()
      local v = probe.version("slowtool")
      local ms = (uv.hrtime() - t0) / 1e6
      probe.timeout = saved
      probe.specs.slowtool = nil
      eq(nil, v)
      ok(ms < 2500, "вернулись за " .. math.floor(ms) .. " мс")
    end)
  end)

  -- ════════════════════════════════════════════════════════════════════════
  describe("Знания · разбор документации", function()
    local md = table.concat({
      "# Title¶", "intro", "", "## Changes to the [language](https://x.y/z)", "Lang text.", "", "```go", "# not heading", "```",
      "", "## Standard library", "Lib intro.", "", "### New uuid package", "uuid text", "", "### slices", "Chunk text",
      "", "## Navigation", "menu", "", "## Ports", "ports text",
    }, "\n")

    it("заголовки: ¶ и ссылки убираются, код пропускается, границы разделов", function()
      local h = digest.headings(vim.split(md, "\n"))
      eq({ "Title", "Changes to the language", "Standard library", "New uuid package", "slices", "Navigation", "Ports" },
        vim.tbl_map(function(x) return x.title end, h))
      eq(h[6].first - 1, h[3].last, "раздел включает подразделы")
    end)

    it("setext-заголовки — только для Markdown-источников", function()
      local text = "Version 1.91.0 (2025-10-30)\n==========\n\nLanguage\n--------\n- x\n"
      eq(2, #digest.headings(vim.split(text, "\n")))
      eq(0, #digest.headings(vim.split(text, "\n"), { setext = false }))
    end)

    it("раздел по названию: точное совпадение, подстрока, с подразделами", function()
      local s = digest.section(md, "standard library")
      ok(s:find("New uuid package", 1, true) and s:find("Chunk text", 1, true) and not s:find("ports text", 1, true), s)
      local s2, title = digest.section(md, "uuid")
      eq("New uuid package", title)
      ok(s2:find("uuid text", 1, true) and not s2:find("Chunk", 1, true))
      eq(nil, digest.section(md, "нет такого"))
    end)

    it("конспект: все заголовки + начало разделов в пределах лимита", function()
      local long = md .. "\n" .. ("## Extra section\n" .. ("слово "):rep(300) .. "\n\n"):rep(40)
      local d = digest.digest(long, 3000)
      ok(#d <= 3200, "длина " .. #d)
      ok(d:find("## Standard library", 1, true) and d:find("### New uuid package", 1, true), d)
      ok(not d:find("## Navigation", 1, true), "служебные разделы скрыты")
      eq(md, digest.digest(md, 100000), "короткий текст не трогаем")
    end)

    it("оглавление для промпта: уровни 1–3, служебные разделы скрыты, лимит", function()
      local idx = digest.index(md, 1000)
      ok(idx:find("- Changes to the language", 1, true) and idx:find("    - slices", 1, true) and not idx:find("Navigation", 1, true), idx)
      ok(#digest.index(md, 30) <= 32)
    end)

    it("HTML → Markdown: заголовки, код, без навигации и скриптов", function()
      local m = digest.to_markdown("<html><body><nav>MENU</nav><main>" .. ("<p>filler</p>"):rep(80)
        .. "<h2>Changes</h2><p>Use <code>uuid.New()</code></p><pre>x := 1</pre></main><script>bad()</script></body></html>")
      ok(m:find("## Changes", 1, true) and m:find("`uuid.New()`", 1, true) and m:find("x := 1", 1, true), m)
      ok(not m:find("MENU", 1, true) and not m:find("bad()", 1, true))
    end)

    it("официальные домены: точный хост и префикс пути, без подмены поддоменом", function()
      ok(sources.is_official("https://go.dev/doc/go1.27"))
      ok(sources.is_official("https://raw.githubusercontent.com/rust-lang/rust/master/RELEASES.md"))
      ok(not sources.is_official("https://raw.githubusercontent.com/evil/x/main/README.md"))
      ok(not sources.is_official("https://go.dev.evil.com/doc"))
      ok(not sources.is_official("https://evil.com/go.dev"))
      ok(not sources.is_official("file:///etc/passwd"))
    end)

    it("URL источников: версии, языки-синонимы, экранирование Go-модулей", function()
      eq("https://go.dev/doc/go1.27", (sources.language_url("go", "1.27.2")))
      eq("https://www.typescriptlang.org/docs/handbook/release-notes/typescript-5-9.html", (sources.language_url("typescript", "5.9.3")))
      eq("https://nodejs.org/en/blog/release/v24.0.0", (sources.language_url("node", "24.11.0")))
      eq("https://en.cppreference.com/w/cpp/23", (sources.language_url("c++", "23")))
      eq("go", sources.language("golang"))
      eq("c++", sources.language("cpp"))
      eq(nil, sources.language("cobol"))
      eq("https://proxy.golang.org/github.com/!azure/sdk/@v/v1.0.0.info", (sources.package_url("go", "github.com/Azure/sdk", "v1.0.0")))
    end)
  end)

  -- ════════════════════════════════════════════════════════════════════════
  local have_python = vim.fn.executable("python3") == 1
  if not have_python then
    return
  end
  local port, host
  local server = vim.system({ "python3", vim.fn.stdpath("config") .. "/tests/mock_llm.py" }, {
    text = true,
    stdout = function(_, d)
      if d and not port then port = d:match("(%d+)") end
    end,
  })
  vim.wait(5000, function() return port ~= nil end, 20)
  host = "http://127.0.0.1:" .. port

  local function requests()
    return vim.json.decode(vim.system({ "curl", "-s", host .. "/requests" }, { text = true }):wait().stdout)
  end
  local function count_get(path)
    local n = 0
    for _, r in ipairs(requests()) do
      if r.method == "GET" and r.path == path then n = n + 1 end
    end
    return n
  end

  local function setup(extra)
    config.user = {}
    config.setup(vim.tbl_deep_extend("force", {
      profiles = { default = { provider = "ollama", host = host, model = "mock:1b" } },
      permissions = { read = "allow", write = "allow", delete = "allow", web = "allow", docs = "allow", exec = "allow" },
      knowledge = {
        official_domains = { "127.0.0.1" },
        sources = {
          go = host .. "/doc/go{v}", python = host .. "/py/whatsnew/{v}.html", rust = host .. "/rust/RELEASES.md",
          ["c++"] = host .. "/cpp/{v}", node = host .. "/node/v{v}", typescript = host .. "/ts/{v_dash}",
          npm = host .. "/npm/{name}@{v}/README.md", pypi = host .. "/pypi/{name}/{v}/json", pypi_latest = host .. "/pypi/{name}/json",
          crates = host .. "/crates/{name}/{v}/readme", go_latest = host .. "/proxy/{escaped}/@latest",
        },
      },
    }, extra or {}))
    config.set_profile("default")
    config.set_model("default", "mock:1b")
  end

  local function clear_knowledge()
    local dir = kn.dir()
    if dir:find("/.tests/", 1, true) then vim.fn.delete(dir, "rf") end
  end

  local function cfg()
    return select(2, config.profile())
  end

  local function ensure(lang, v, force)
    local res
    kn.ensure_language(lang, v, cfg(), function(body, err, info, cached) res = { body, err, info, cached } end, force)
    wait(8000, function() return res ~= nil end, "ensure " .. lang)
    return res[1], res[2], res[3], res[4]
  end

  local function exec(name, args, c)
    local res
    tools.execute(name, args, c, function(r, e, d) res = { r, e, d } end)
    wait(15000, function() return res ~= nil end, "инструмент " .. name)
    return res[1], res[2], res[3]
  end

  local function ctx_for(root, session)
    return { root = root, cfg = cfg(), session = session }
  end

  describe("Знания · загрузка и кэш (мок официальных источников)", function()
    setup()
    clear_knowledge()

    it("заметки Go 1.27: загрузка, сохранение с метаданными, повтор — из кэша", function()
      local body, err, info, cached = ensure("go", "1.27.2")
      eq(nil, err)
      eq(false, cached)
      ok(body:find("## Changes to the language", 1, true) and body:find("### New uuid package", 1, true), body)
      ok(not body:find("Docs menu", 1, true), "навигация вырезана")
      eq(kn.dir() .. "/lang/go@1.27.md", info.path)
      local _, meta = kn.read_note(info.path)
      eq(host .. "/doc/go1.27", meta.source)
      eq("1.27", meta.version)
      eq("html", meta.format)
      local before = count_get("/doc/go1.27")
      local _, _, _, cached2 = ensure("go", "1.27")
      eq(true, cached2)
      eq(before, count_get("/doc/go1.27"), "в сеть повторно не ходили")
      ok(kn.has("go", "1.27.0", cfg()))
      ensure("go", "1.27", true)
      eq(before + 1, count_get("/doc/go1.27"), "force перезагружает")
    end)

    it("Python: ¶ и ссылки в заголовках очищены", function()
      local body = ensure("python", "3.14")
      local idx = digest.index(body, 2000, kn.opts({ format = "html" }))
      ok(idx:find("PEP 649: Deferred evaluation of annotations", 1, true) and not idx:find("¶", 1, true), idx)
    end)

    it("Rust: из RELEASES.md вырезается раздел только своей версии", function()
      local body, err = ensure("rust", "1.91.0")
      eq(nil, err)
      ok(body:find("Version 1.91.0", 1, true) and body:find("Path::file_prefix", 1, true), body)
      ok(not body:find("OLD_1_90_FEATURE", 1, true) and not body:find("Feature from the future", 1, true), body)
      local _, err2 = ensure("rust", "1.70.0")
      ok(err2 and err2:find("нет раздела", 1, true), tostring(err2))
    end)

    it("несуществующая версия (404) и неофициальный источник — понятные ошибки", function()
      local body, err = ensure("go", "1.99")
      eq(nil, body)
      ok(err:find("HTTP", 1, true), err)
      config.setup({ knowledge = { official_domains = { "go.dev" } } })
      local _, err2 = ensure("go", "1.98")
      ok(err2:find("не входит в список официальных", 1, true), err2)
      setup()
    end)

    it("документация пакетов: npm, PyPI (с откатом на последнюю), crates", function()
      local res
      kn.ensure_package("npm", "express", "4.21.2", cfg(), function(b, e) res = { b, e } end)
      wait(5000, function() return res end)
      ok(res[1] and res[1]:find("Routing", 1, true), tostring(res[2]))
      res = nil
      kn.ensure_package("pypi", "fastapi", "0.115.6", cfg(), function(b, e) res = { b, e } end)
      wait(5000, function() return res end)
      ok(res[1]:find("Use Depends()", 1, true) and res[1]:find("requires-python: >=3.8", 1, true), res[1])
      res = nil
      kn.ensure_package("pypi", "fastapi", "0.1.0", cfg(), function(b, e, m) res = { b, e, m } end)
      wait(5000, function() return res end)
      ok(res[1] and res[1]:find("FastAPI latest", 1, true), "откат на последнюю версию: " .. tostring(res[2]))
      res = nil
      kn.ensure_package("crates", "tokio", "1.40.0", cfg(), function(b, e) res = { b, e } end)
      wait(5000, function() return res end)
      ok(res[1] and res[1]:find("# Tokio", 1, true), tostring(res[2]))
      res = nil
      kn.ensure_package("npm", "../etc", "1", cfg(), function(b, e) res = { b, e } end)
      ok(res and res[2]:find("Некорректное имя", 1, true))
    end)

    it("заметки для промпта из Markdown-источника (Rust): разделы и источник", function()
      local text = kn.prompt_notes({ { lang = "rust", version = "1.91.0", label = "Rust 1.91" } }, cfg(), 2000)
      ok(text:find("Stabilized APIs", 1, true) and text:find("Cargo", 1, true), text)
      ok(text:find(host .. "/rust/RELEASES.md", 1, true), "источник из метаданных: " .. text)
    end)

    it("заметки для системного промпта: изученное — оглавлением, неизученное — указанием", function()
      local text = kn.prompt_notes({ { lang = "go", version = "1.27", label = "Go 1.27" }, { lang = "c++", version = "26", label = "C++26" } }, cfg(), 2500)
      ok(text:find("Go 1.27 — official release notes are cached", 1, true) and text:find("New uuid package", 1, true), text)
      ok(text:find("C++26 — notes NOT available yet", 1, true) and text:find('lookup_docs(name="c++", version="26")', 1, true), text)
      ok(#text < 3500)
    end)
  end)

  -- ════════════════════════════════════════════════════════════════════════
  describe("Знания · инструменты для модели", function()
    setup()

    it("схемы всех инструментов кодируются как объекты (Ollama отклоняет properties = [])", function()
      for _, schema in ipairs(require("aqua.ai.provider").tool_schemas(tools.list)) do
        local enc = vim.json.encode(schema)
        ok(not enc:find('"properties":%[%]'), schema["function"].name .. ": " .. enc)
        ok(enc:find('"properties":{', 1, true), schema["function"].name .. ": нет объекта properties")
      end
      local fixed = require("aqua.ai.provider").fix_schema({ type = "object", properties = { a = { type = "object", properties = {} } } })
      eq("{}", vim.json.encode(fixed.properties.a.properties), "вложенная пустая схема — тоже объект")
    end)

    it("project_stack: полный отчёт", function()
      use_bin(bin_new)
      local r, e = exec("project_stack", {}, ctx_for(goproj))
      eq(false, e)
      ok(r:find("Go 1.27", 1, true) and r:find("example.com/single v0.9.0", 1, true) and r:find("go.sum", 1, true), r)
      restore_path()
    end)

    it("lookup_docs: язык без версии — версия из стека; раздел целиком; неизвестный раздел", function()
      use_bin(bin_new)
      local r, e = exec("lookup_docs", { name = "go" }, ctx_for(goproj))
      eq(false, e)
      ok(r:find("Go 1.27", 1, true) and r:find("Standard library", 1, true), r)
      r, e = exec("lookup_docs", { name = "golang", section = "uuid" }, ctx_for(goproj))
      eq(false, e)
      ok(r:find("UUIDv7", 1, true) and not r:find("Changes to the language", 1, true), r)
      r, e = exec("lookup_docs", { name = "go", section = "квантовые вычисления" }, ctx_for(goproj))
      ok(e and r:find("не найден", 1, true) and r:find("Standard library", 1, true), r)
      restore_path()
    end)

    it("lookup_docs: пакет из зависимостей — версия из lock-файла", function()
      use_bin(bin_new)
      local r, e = exec("lookup_docs", { name = "express", section = "Routing" }, ctx_for(jsproj))
      eq(false, e)
      ok(r:find("app.get", 1, true), r)
      eq(1, count_get("/npm/express@4.21.2/README.md"), "запрошена именно версия из package-lock")
      local r2, e2 = exec("lookup_docs", { name = "fastapi" }, ctx_for(pyproj))
      eq(false, e2)
      ok(r2:find("0.115.6", 1, true), r2)
      local r3, e3 = exec("lookup_docs", { name = "left-pad" }, ctx_for(goproj))
      ok(e3 and r3:find("ecosystem", 1, true), r3)
      restore_path()
    end)

    it("lookup_docs: пакет стандартной библиотеки Go (нет в зависимостях) → go doc + раздел заметок о выпуске", function()
      use_bin(bin_new)
      local r, e = exec("lookup_docs", { name = "uuid", section = "UUID v7" }, ctx_for(goproj))
      eq(false, e, r)
      ok(r:find("go doc uuid", 1, true) and r:find("func NewV7() UUID", 1, true), r)
      ok(r:find("standard library", 1, true) and r:find("no third-party dependency", 1, true), r)
      ok(r:find("New uuid package", 1, true) and r:find("UUIDv7", 1, true), "раздел из заметок Go 1.27: " .. r)
      restore_path()
    end)

    it("lookup_docs: не зависимость, но есть в заметках о выпуске языка (Rust › Cargo)", function()
      use_bin(bin_new)
      local r, e = exec("lookup_docs", { name = "cargo" }, ctx_for(rsproj))
      eq(false, e, r)
      ok(r:find("Rust 1.91.0 release notes", 1, true) and r:find("build.build-dir", 1, true), r)
      restore_path()
    end)

    it("права docs: ask спрашивает, deny скрывает инструмент", function()
      local asked
      permissions.handler = function(cat, info, cb) asked = { cat, info.title } cb("yes") end
      exec("lookup_docs", { name = "go", version = "1.27" }, { root = goproj, cfg = vim.tbl_deep_extend("force", cfg(), { permissions = { docs = "ask" } }) })
      permissions.handler = nil
      eq("docs", asked[1])
      ok(asked[2]:find("go", 1, true))
      local names = vim.tbl_map(function(t) return t.name end, tools.available(vim.tbl_deep_extend("force", cfg(), { permissions = { docs = "deny", exec = "deny" } })))
      ok(not vim.tbl_contains(names, "lookup_docs") and not vim.tbl_contains(names, "check_project"))
      ok(vim.tbl_contains(names, "project_stack") and vim.tbl_contains(names, "api_docs"))
    end)

    it("api_docs (TS): объявления типов пакета и поиск символа", function()
      local r, e = exec("api_docs", { symbol = "typed", member = "connect", language = "ts" }, ctx_for(jsproj))
      eq(false, e)
      ok(r:find("export declare function connect", 1, true) and r:find("lib/index.d.ts", 1, true), r)
      local r2, e2 = exec("api_docs", { symbol = "nope", language = "ts" }, ctx_for(jsproj))
      ok(e2 and r2:find("Нет объявлений", 1, true), r2)
      local r3, e3 = exec("api_docs", { symbol = "../../etc", language = "ts" }, ctx_for(jsproj))
      ok(e3 and r3:find("Некорректное", 1, true), r3)
    end)

    if vim.fn.executable("go") == 1 then
      it("api_docs (Go): настоящий `go doc` установленной версии stdlib", function()
        local mod = base .. "/realgo"
        write(mod .. "/go.mod", "module realgo\n\ngo 1.21\n")
        local r, e = exec("api_docs", { symbol = "strings.Cut", language = "go" }, ctx_for(mod))
        eq(false, e, r)
        ok(r:find("func Cut(s, sep string)", 1, true), r)
        local r2, e2 = exec("api_docs", { symbol = "-all", language = "go" }, ctx_for(mod))
        ok(e2 and r2:find("Некорректное", 1, true), r2)
        local r3, e3 = exec("api_docs", { symbol = "strings.NoSuchFunc", language = "go" }, ctx_for(mod))
        ok(e3 and r3:find("NoSuchFunc", 1, true), r3)
      end)
    end

    it("check_project (Go): команда выбирается харнесом, подтверждение показывает её, ошибки компилятора — модели", function()
      use_bin(bin_new)
      local asked
      permissions.handler = function(cat, info, cb) asked = { cat, info.title } cb("yes") end
      local c = { root = goproj, cfg = vim.tbl_deep_extend("force", cfg(), { permissions = { exec = "ask" } }) }
      local r, e = exec("check_project", {}, c)
      permissions.handler = nil
      eq("exec", asked[1])
      ok(asked[2]:find("go build ./...", 1, true), asked[2])
      ok(e and r:find("exit code: 1", 1, true) and r:find("undefined: Foo", 1, true), r)
      ok(not r:find(goproj, 1, true), "пути относительные")
      r, e = exec("check_project", { mode = "vet" }, ctx_for(goproj))
      eq(false, e)
      ok(r:find("go vet ./...", 1, true) and r:find("без ошибок", 1, true), r)
      restore_path()
    end)

    it("check_project: таймаут убивает процесс", function()
      use_bin(bin_new)
      local c = { root = goproj, cfg = vim.tbl_deep_extend("force", cfg(), { check = { timeout = 1 } }) }
      local t0 = uv.hrtime()
      local r, e = exec("check_project", { mode = "test" }, c)
      ok(e and r:find("превышено время", 1, true), r)
      ok((uv.hrtime() - t0) / 1e6 < 5000)
      restore_path()
    end)

    it("check_project: отмена сессии убивает проверку", function()
      use_bin(bin_new)
      local fake_session = { allowed = {}, emit_status = function() end }
      local res
      tools.execute("check_project", { mode = "test" }, ctx_for(goproj, fake_session), function(r, e) res = { r, e } end)
      wait(2000, function() return fake_session.child ~= nil end, "процесс запущен")
      fake_session.child:kill(15)
      wait(3000, function() return res ~= nil end, "завершился после kill")
      ok(res[2])
      restore_path()
    end)

    it("check_project (Python): синтаксис файлов, без записи __pycache__; файлы вне проекта запрещены", function()
      use_bin(bin_new)
      local r, e = exec("check_project", { files = { "app.py" } }, ctx_for(pyproj))
      eq(false, e, r)
      ok(r:find("syntax ok: 1", 1, true), r)
      eq(0, vim.fn.isdirectory(pyproj .. "/__pycache__"))
      r, e = exec("check_project", { files = { "bad.py" } }, ctx_for(pyproj))
      ok(e and r:find("SyntaxError", 1, true), r)
      r, e = exec("check_project", { files = { "../goproj/main.go" } }, ctx_for(pyproj))
      ok(e and r:find("вне проекта", 1, true), r)
      r, e = exec("check_project", {}, ctx_for(pyproj))
      ok(e and r:find("укажите files", 1, true), r)
      restore_path()
    end)

    it("check_project (C/C++): -fsyntax-only по команде из compile_commands; выбор экосистемы", function()
      use_bin(bin_new)
      local st = stack.detect(cppproj)
      local plan = require("aqua.ai.tools.stack").check_command(st, { files = { "main.cpp" } }, ctx_for(cppproj))
      eq("/usr/bin/clang++", plan.cmd[1])
      ok(vim.tbl_contains(plan.cmd, "-std=c++2c") and vim.tbl_contains(plan.cmd, "-fsyntax-only"), vim.inspect(plan.cmd))
      ok(not vim.tbl_contains(plan.cmd, "-o") and not vim.tbl_contains(plan.cmd, "-c"), vim.inspect(plan.cmd))
      local cplan = require("aqua.ai.tools.stack").check_command(stack.detect(cproj), { files = { "main.c" } }, ctx_for(cproj))
      ok(vim.tbl_contains(cplan.cmd, "-std=c17"), vim.inspect(cplan.cmd))
      local _, err = require("aqua.ai.tools.stack").check_command(stack.detect(mono), {}, ctx_for(mono))
      ok(err:find("Укажите ecosystem: go, js", 1, true), err)
      local _, err2 = require("aqua.ai.tools.stack").check_command(stack.detect(jsproj), { mode = "test" }, ctx_for(jsproj))
      ok(err2:find("не поддерживается", 1, true), err2)
      restore_path()
    end)
  end)

  -- ════════════════════════════════════════════════════════════════════════
  describe("Знания · авто-изучение в цикле агента", function()
    local function fresh(root)
      session_mod.sessions[root] = nil
      local s = session_mod.get(root)
      s:reset()
      local events = {}
      s.cb = function(ev, ...) events[#events + 1] = { ev, ... } end
      return s, events
    end
    local function collect(events, ev)
      return vim.tbl_filter(function(e) return e[1] == ev end, events)
    end
    local function ask(s, events, text)
      s:send(text)
      wait(15000, function() return #collect(events, "done") > 0 end, "ответ")
    end
    local function last_system()
      local reqs = requests()
      for i = #reqs, 1, -1 do
        if reqs[i].path == "/api/chat" then return reqs[i].system end
      end
    end

    it("первый запрос в Go-проекте: изучение Go 1.27 до ответа, промпт со стеком и заметками", function()
      setup()
      clear_knowledge()
      use_bin(bin_new)
      local s, events = fresh(goproj)
      ask(s, events, "привет")
      local names = vim.tbl_map(function(e) return e[1] end, events)
      local ts = collect(events, "tool_start")[1]
      ok(ts and ts[2].name == "research" and ts[3] == "Go 1.27" and ts[4] == "docs", vim.inspect(ts))
      local i_research, i_answer
      for i, n in ipairs(names) do
        if n == "tool_end" and not i_research then i_research = i end
        if n == "assistant_start" and not i_answer then i_answer = i end
      end
      ok(i_research < i_answer, "изучение до ответа модели")
      eq(false, collect(events, "tool_end")[1][4], "без ошибки")
      local sys = last_system()
      ok(sys:find("## Project stack", 1, true) and sys:find("Go 1.27 (go.mod: go 1.27; toolchain go1.27.2", 1, true), sys)
      ok(sys:find("Go 1.27 — official release notes are cached", 1, true) and sys:find("New uuid package", 1, true), sys)
      ok(sys:find("Version rules", 1, true) and sys:find("check_project", 1, true), sys)
      ok(sys:find("example.com/b v2.0.0", 1, true), "зависимости в промпте")
      eq({ "user", "assistant" }, vim.tbl_map(function(m) return m.role end, s.messages), "изучение не засоряет историю")
      restore_path()
    end)

    it("повторные запросы и новые сессии не изучают заново (кэш)", function()
      use_bin(bin_new)
      local s, events = fresh(goproj)
      ask(s, events, "ещё")
      eq(0, #collect(events, "tool_start"), "заметки уже в кэше")
      restore_path()
    end)

    it("ошибка загрузки не ломает ответ; в промпте — указание изучить вручную", function()
      setup({ knowledge = { sources = { go = host .. "/missing/go{v}" } } })
      clear_knowledge()
      use_bin(bin_new)
      local s, events = fresh(goproj)
      ask(s, events, "привет")
      local te = collect(events, "tool_end")[1]
      ok(te[4] and te[3]:find("не удалось изучить", 1, true), vim.inspect(te))
      eq(1, #collect(events, "assistant_end"), "модель ответила")
      ok(last_system():find("Go 1.27 — notes NOT available yet", 1, true))
      restore_path()
      setup()
    end)

    it("knowledge.auto = false — без изучения", function()
      setup({ knowledge = { auto = false } })
      clear_knowledge()
      use_bin(bin_new)
      local s, events = fresh(goproj)
      ask(s, events, "привет")
      eq(0, #collect(events, "tool_start"))
      restore_path()
      setup()
    end)

    it("permissions.docs = ask: отказ — изучение пропущено, ответ есть", function()
      setup({ permissions = { docs = "ask" } })
      clear_knowledge()
      use_bin(bin_new)
      permissions.handler = function(_, _, cb) cb("no") end
      local s, events = fresh(goproj)
      ask(s, events, "привет")
      permissions.handler = nil
      local te = collect(events, "tool_end")[1]
      ok(te[5] and te[3]:find("пропущено", 1, true), vim.inspect(te))
      eq(1, #collect(events, "assistant_end"))
      restore_path()
      setup()
    end)

    it("Ctrl-C во время изучения: модель не вызывается", function()
      setup({ knowledge = { sources = { go = host .. "/slowdoc/go{v}" } } })
      clear_knowledge()
      use_bin(bin_new)
      local s, events = fresh(goproj)
      s:send("привет")
      wait(2000, function() return #collect(events, "tool_start") > 0 end, "изучение началось")
      s:cancel()
      vim.wait(3500)
      eq(0, #collect(events, "assistant_start"))
      eq(true, collect(events, "done")[1][2])
      restore_path()
      setup()
    end)

    it("правила в промпте: стандартная библиотека версии вместо сторонних зависимостей", function()
      ok(session_mod.VERSION_RULES:find("Prefer the standard library of THIS version", 1, true))
      ok(session_mod.VERSION_RULES:find("Do not add new third-party dependencies", 1, true))
    end)

    it("модель изменила код и не проверила → харнес один раз напоминает, модель вызывает check_project", function()
      setup()
      use_bin(bin_new)
      local s, events = fresh(goproj)
      ask(s, events, "make-go please")
      eq(1, vim.fn.filereadable(goproj .. "/extra.go"))
      eq(1, #collect(events, "notice"), "одно напоминание")
      local checks = vim.tbl_filter(function(e) return e[2].name == "check_project" end, collect(events, "tool_start"))
      eq(1, #checks, "модель проверила сборку")
      local harness = vim.tbl_filter(function(m) return m.harness end, s.messages)
      eq(1, #harness)
      ok(harness[1].content:find("check_project", 1, true))
      eq("assistant", s.messages[#s.messages].role)
      eq(false, s.running)
      os.remove(goproj .. "/extra.go")
      restore_path()
    end)

    it("без напоминания: правка не кода (Markdown) и запрещённая проверка (exec = deny)", function()
      setup()
      use_bin(bin_new)
      local s, events = fresh(goproj)
      ask(s, events, "make-file")
      eq(0, #collect(events, "notice"), "Markdown не требует компиляции")
      vim.fn.delete(goproj .. "/notes", "rf")
      setup({ permissions = { exec = "deny" } })
      s, events = fresh(goproj)
      ask(s, events, "make-go")
      eq(0, #collect(events, "notice"), "проверка запрещена — не напоминаем")
      os.remove(goproj .. "/extra.go")
      setup({ check = { require_after_edit = false } })
      s, events = fresh(goproj)
      ask(s, events, "make-go")
      eq(0, #collect(events, "notice"), "напоминания отключены настройкой")
      os.remove(goproj .. "/extra.go")
      setup()
      restore_path()
    end)

    it("проект без манифестов: без изучения и без раздела стека в промпте", function()
      setup()
      local s, events = fresh(empty)
      ask(s, events, "привет")
      eq(0, #collect(events, "tool_start"))
      ok(not last_system():find("Project stack", 1, true))
    end)
  end)

  describe("Знания · интерфейс", function()
    it("в чате видно изучение (📚), /stack и :AquaAI stack показывают стек", function()
      setup()
      clear_knowledge()
      use_bin(bin_new)
      local ui = require("aqua.ai.ui")
      local ai = require("aqua.ai")
      session_mod.sessions[goproj] = nil
      ui.states[goproj] = nil
      vim.cmd("only")
      vim.cmd.edit(goproj .. "/main.go")
      local st = ai.open()
      st.session:send("привет")
      wait(10000, function() return not st.session.running end, "ответ")
      wait(3000, function() return ui.text(st):find("research Go 1.27", 1, true) end, "строка изучения в чате")
      local text = ui.text(st)
      ok(text:find("⎿  ✓ заметки о выпуске Go 1.27", 1, true), text)
      local report = ai.stack_report()
      ok(report:find("Go 1.27", 1, true) and report:find("изучено", 1, true), report)
      local before = #vim.api.nvim_list_wins()
      ai.show_stack()
      ok(#vim.api.nvim_list_wins() > before, "окно со стеком открыто")
      vim.cmd("close")
      local subs = vim.fn.getcompletion("AquaAI ", "cmdline")
      ok(vim.tbl_contains(subs, "stack") and vim.tbl_contains(subs, "research") and vim.tbl_contains(subs, "knowledge"), vim.inspect(subs))
      ok(vim.fn.maparg(" aoS", "n") ~= "" and vim.fn.maparg(" aoK", "n") ~= "")
      ui.hide(st)
      restore_path()
    end)
  end)

  -- ── Уборка ────────────────────────────────────────────────────────────────
  restore_path()
  probe.clear()
  pcall(function() server:kill(15) end)
  config.user = {}
  clear_knowledge()
end
