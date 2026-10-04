-- Глобальные бинды AquaNvim. Группы для which-key описаны в lua/aqua/plugins/editor.lua.
local map = vim.keymap.set
local root = require("aqua.util.root")

local function pick(source, opts)
  return function()
    Snacks.picker[source](opts and (type(opts) == "function" and opts() or opts) or nil)
  end
end
local function in_root()
  return { cwd = root.get() }
end

-- ── Фирменные бинды AquaNvim ────────────────────────────────────────────────
map({ "n", "x", "s" }, "<C-s>", "<cmd>w<cr><esc>", { desc = "Save File" })
map("i", "<C-s>", "<esc><cmd>w<cr>", { desc = "Save File" })
map("n", "<C-a>", "ggVG", { desc = "Select All" })
map("x", "/", "gc", { remap = true, desc = "Toggle Comment" })
map("n", "<leader>n", function()
  vim.ui.input({ prompt = "󰝒 Новый файл: ", default = root.file_dir() .. "/", completion = "file" }, function(path)
    if path and path ~= "" then
      vim.cmd.edit(vim.fn.fnameescape(path))
    end
  end)
end, { desc = "New File" })

-- ── Окна ────────────────────────────────────────────────────────────────────
map("n", "<C-h>", "<C-w>h", { desc = "Go to Left Window" })
map("n", "<C-j>", "<C-w>j", { desc = "Go to Lower Window" })
map("n", "<C-k>", "<C-w>k", { desc = "Go to Upper Window" })
map("n", "<C-l>", "<C-w>l", { desc = "Go to Right Window" })
map("n", "<C-Left>", "<C-w>h", { desc = "Go to Left Window" })
map("n", "<C-Right>", "<C-w>l", { desc = "Go to Right Window" })
map("n", "<C-Up>", "<cmd>resize +2<cr>", { desc = "Increase Window Height" })
map("n", "<C-Down>", "<cmd>resize -2<cr>", { desc = "Decrease Window Height" })
map("n", "<leader>-", "<C-w>s", { desc = "Split Window Below" })
map("n", "<leader>|", "<C-w>v", { desc = "Split Window Right" })
map("n", "<leader>wd", "<C-w>c", { desc = "Delete Window" })
map("n", "<leader>wm", function() Snacks.zen.zoom() end, { desc = "Zoom Window" })
map("n", "<leader>w=", "<C-w>=", { desc = "Equalize Windows" })

-- ── Буферы ──────────────────────────────────────────────────────────────────
map("n", "<S-h>", "<cmd>bprevious<cr>", { desc = "Prev Buffer" })
map("n", "<S-l>", "<cmd>bnext<cr>", { desc = "Next Buffer" })
map("n", "[b", "<cmd>bprevious<cr>", { desc = "Prev Buffer" })
map("n", "]b", "<cmd>bnext<cr>", { desc = "Next Buffer" })
map("n", "<leader>`", "<cmd>e #<cr>", { desc = "Switch to Other Buffer" })
map("n", "<leader>bb", "<cmd>e #<cr>", { desc = "Switch to Other Buffer" })
map("n", "<leader>bd", function() Snacks.bufdelete() end, { desc = "Delete Buffer" })
map("n", "<leader>bo", function() Snacks.bufdelete.other() end, { desc = "Delete Other Buffers" })
map("n", "<leader>bD", "<cmd>bd<cr>", { desc = "Delete Buffer and Window" })

-- ── Редактирование ──────────────────────────────────────────────────────────
map({ "n", "x" }, "j", "v:count == 0 ? 'gj' : 'j'", { expr = true, silent = true })
map({ "n", "x" }, "k", "v:count == 0 ? 'gk' : 'k'", { expr = true, silent = true })
map("n", "<A-j>", "<cmd>execute 'move .+' . v:count1<cr>==", { desc = "Move Down" })
map("n", "<A-k>", "<cmd>execute 'move .-' . (v:count1 + 1)<cr>==", { desc = "Move Up" })
map("x", "<A-j>", ":<C-u>execute \"'<,'>move '>+\" . v:count1<cr>gv=gv", { desc = "Move Down" })
map("x", "<A-k>", ":<C-u>execute \"'<,'>move '<-\" . (v:count1 + 1)<cr>gv=gv", { desc = "Move Up" })
map("x", "<", "<gv")
map("x", ">", ">gv")
map({ "i", "n", "s" }, "<esc>", function()
  vim.cmd("noh")
  return "<esc>"
end, { expr = true, desc = "Escape and Clear hlsearch" })

-- ── Поиск / файлы (Snacks picker) ───────────────────────────────────────────
map("n", "<leader><space>", pick("files", in_root), { desc = "Find Files (Root Dir)" })
map("n", "<leader>/", pick("grep", in_root), { desc = "Grep (Root Dir)" })
map("n", "<leader>,", pick("buffers"), { desc = "Buffers" })
map("n", "<leader>:", pick("command_history"), { desc = "Command History" })
map("n", "<leader>ff", pick("files", in_root), { desc = "Find Files (Root Dir)" })
map("n", "<leader>fF", pick("files"), { desc = "Find Files (cwd)" })
map("n", "<leader>fr", pick("recent"), { desc = "Recent Files" })
map("n", "<leader>fR", pick("recent", { filter = { cwd = true } }), { desc = "Recent Files (cwd)" })
map("n", "<leader>fb", pick("buffers"), { desc = "Buffers" })
map("n", "<leader>fc", pick("files", function() return { cwd = vim.fn.stdpath("config") } end), { desc = "Find Config File" })
map("n", "<leader>fp", pick("projects"), { desc = "Projects" })
map("n", "<leader>fg", pick("git_files"), { desc = "Find Files (git)" })
map("n", "<leader>fn", "<cmd>enew<cr>", { desc = "New Buffer" })
map("n", "<leader>fy", function()
  local path = vim.fn.expand("%:p")
  vim.fn.setreg("+", path)
  vim.notify("Скопировано: " .. path)
end, { desc = "Yank File Path" })

map("n", "<leader>sg", pick("grep", in_root), { desc = "Grep (Root Dir)" })
map("n", "<leader>sG", pick("grep"), { desc = "Grep (cwd)" })
map({ "n", "x" }, "<leader>sw", pick("grep_word", in_root), { desc = "Word / Selection" })
map("n", "<leader>sb", pick("lines"), { desc = "Buffer Lines" })
map("n", "<leader>sh", pick("help"), { desc = "Help Pages" })
map("n", "<leader>sk", pick("keymaps"), { desc = "Keymaps" })
map("n", "<leader>sc", pick("commands"), { desc = "Commands" })
map("n", "<leader>sd", pick("diagnostics"), { desc = "Diagnostics" })
map("n", "<leader>sD", pick("diagnostics_buffer"), { desc = "Buffer Diagnostics" })
map("n", "<leader>sm", pick("marks"), { desc = "Marks" })
map("n", "<leader>sj", pick("jumps"), { desc = "Jumps" })
map("n", "<leader>sq", pick("qflist"), { desc = "Quickfix List" })
map("n", "<leader>sr", pick("resume"), { desc = "Resume Last Search" })
map("n", "<leader>su", pick("undo"), { desc = "Undo History" })
map("n", "<leader>sn", pick("notifications"), { desc = "Notification History" })
map("n", "<leader>ss", pick("lsp_symbols"), { desc = "LSP Symbols" })
map("n", "<leader>sS", pick("lsp_workspace_symbols"), { desc = "LSP Workspace Symbols" })
map("n", "<leader>s\"", pick("registers"), { desc = "Registers" })
map("n", "<leader>?", function() require("which-key").show({ global = false }) end, { desc = "Buffer Keymaps (which-key)" })

-- ── Explorer ────────────────────────────────────────────────────────────────
map("n", "<leader>e", function() Snacks.explorer({ cwd = root.get() }) end, { desc = "Explorer (Root Dir)" })
map("n", "<leader>E", function() Snacks.explorer() end, { desc = "Explorer (cwd)" })
map("n", "<C-n>", function() Snacks.explorer({ cwd = root.get() }) end, { desc = "Explorer (Root Dir)" })

-- ── Git ─────────────────────────────────────────────────────────────────────
map("n", "<leader>gg", function() Snacks.lazygit({ cwd = root.get() }) end, { desc = "Lazygit (Root Dir)" })
map("n", "<leader>gs", pick("git_status"), { desc = "Git Status" })
map("n", "<leader>gl", pick("git_log"), { desc = "Git Log" })
map("n", "<leader>gf", pick("git_log_file"), { desc = "Git File History" })
map("n", "<leader>gB", pick("git_branches"), { desc = "Git Branches" })
map("n", "<leader>gd", pick("git_diff"), { desc = "Git Diff (hunks)" })
map({ "n", "x" }, "<leader>go", function() Snacks.gitbrowse() end, { desc = "Git Browse (open)" })

-- ── Сессии ──────────────────────────────────────────────────────────────────
map("n", "<leader>qs", function() require("persistence").load() end, { desc = "Restore Session (cwd)" })
map("n", "<leader>qS", function() require("persistence").select() end, { desc = "Select Session" })
map("n", "<leader>ql", function() require("persistence").load({ last = true }) end, { desc = "Restore Last Session" })
map("n", "<leader>qw", function()
  if require("aqua.session").save({ reopen = true }) then
    vim.notify("Сессия сохранена", vim.log.levels.INFO, { title = "AquaNvim" })
  end
end, { desc = "Save Session Now" })
map("n", "<leader>qd", function()
  require("persistence").stop()
  vim.notify("Сессия не будет сохранена при выходе", vim.log.levels.WARN, { title = "AquaNvim" })
end, { desc = "Don't Save Current Session" })
map("n", "<leader>qq", "<cmd>qa<cr>", { desc = "Quit All" })

-- ── Claude CLI ──────────────────────────────────────────────────────────────
local claude = function(fn, ...)
  local args = { ... }
  return function()
    require("aqua.claude")[fn](unpack(args))
  end
end
map("n", "<leader>c", claude("toggle"), { desc = "Claude (Project Root)" })
map({ "n", "t" }, "<C-,>", claude("toggle"), { desc = "Toggle Claude" })
map("n", "<leader>aa", claude("toggle"), { desc = "Toggle Claude (Root)" })
map("n", "<leader>aC", claude("toggle", { scope = "file" }), { desc = "Claude (File Dir)" })
map("n", "<leader>ac", claude("open", { args = { "--continue" }, restart = true }), { desc = "Continue Last Chat" })
map("n", "<leader>ar", claude("open", { args = { "--resume" }, restart = true }), { desc = "Resume Chat (pick)" })
map("n", "<leader>af", claude("send_file"), { desc = "Add Current File" })
map("x", "<leader>as", function()
  require("aqua.claude").send_selection()
end, { desc = "Send Selection" })
map("n", "<leader>ad", claude("send_diagnostics"), { desc = "Send Line Diagnostics" })
map("n", "<leader>ap", claude("select"), { desc = "Pick Claude Instance" })
map("n", "<leader>ak", claude("kill"), { desc = "Kill Claude (Root)" })

-- ── Терминал ────────────────────────────────────────────────────────────────
map({ "n", "t" }, "<C-/>", function() Snacks.terminal(nil, { cwd = root.get() }) end, { desc = "Terminal (Root Dir)" })
map({ "n", "t" }, "<C-_>", function() Snacks.terminal(nil, { cwd = root.get() }) end, { desc = "which_key_ignore" })
map("n", "<leader>ft", function() Snacks.terminal(nil, { cwd = root.get() }) end, { desc = "Terminal (Root Dir)" })
map("n", "<leader>fT", function() Snacks.terminal() end, { desc = "Terminal (cwd)" })

-- ── Scratch / прочее ────────────────────────────────────────────────────────
map("n", "<leader>.", function() Snacks.scratch() end, { desc = "Toggle Scratch Buffer" })
map("n", "<leader>S", function() Snacks.scratch.select() end, { desc = "Select Scratch Buffer" })
map("n", "<leader>L", "<cmd>Lazy<cr>", { desc = "Lazy" })
map("n", "<leader>M", "<cmd>Mason<cr>", { desc = "Mason" })
map("n", "<leader>X", "<cmd>AquaExtras<cr>", { desc = "Aqua Extras" })
map("n", "<leader>K", "<cmd>norm! K<cr>", { desc = "Keywordprg" })

-- ── Диагностика ─────────────────────────────────────────────────────────────
local function diag_jump(count, severity)
  return function()
    vim.diagnostic.jump({ count = count, float = true, severity = severity and vim.diagnostic.severity[severity] or nil })
  end
end
map("n", "]d", diag_jump(1), { desc = "Next Diagnostic" })
map("n", "[d", diag_jump(-1), { desc = "Prev Diagnostic" })
map("n", "]e", diag_jump(1, "ERROR"), { desc = "Next Error" })
map("n", "[e", diag_jump(-1, "ERROR"), { desc = "Prev Error" })
map("n", "]w", diag_jump(1, "WARN"), { desc = "Next Warning" })
map("n", "[w", diag_jump(-1, "WARN"), { desc = "Prev Warning" })
map("n", "<leader>xl", "<cmd>lopen<cr>", { desc = "Location List" })
map("n", "<leader>xq", "<cmd>copen<cr>", { desc = "Quickfix List" })
