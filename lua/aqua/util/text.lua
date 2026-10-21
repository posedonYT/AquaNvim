-- Текстовые утилиты.
local M = {}

--- Обрезать строку до n байт, не разрезая символ UTF-8 посередине.
---@param s string
---@param n integer
function M.cut(s, n)
  if #s <= n then
    return s
  end
  while n > 0 do
    local b = s:byte(n + 1)
    if not b or b < 0x80 or b >= 0xC0 then
      break
    end
    n = n - 1
  end
  return s:sub(1, n)
end

return M
