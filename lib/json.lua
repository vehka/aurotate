-- json: a small JSON decoder (pure Lua 5.3), for the Freesound API
--
--   Json.decode(s) -> value, or nil and an error ("at byte n: ...")
--
-- Objects become tables with string keys, arrays become lists, null becomes
-- Json.null (so a key whose value is null is still there; use Json.val(v) to
-- turn it into nil). Numbers are Lua numbers (integers stay integers).
-- Strings: every escape, \uXXXX with surrogate pairs, written as UTF-8.

local Json = {}

Json.null = setmetatable({}, { __tostring = function() return 'null' end })

function Json.val(v)
  if v == Json.null then return nil end
  return v
end

local escapes = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }

local function fail(i, msg) error({ at = i, msg = msg }, 0) end

local function skip(s, i)
  return s:find('[^ \t\r\n]', i) or #s + 1
end

local decode_value

local function decode_string(s, i)
  -- s:sub(i, i) == '"'
  local out, j = {}, i + 1
  while true do
    local k = s:find('["\\%c]', j)
    if not k then fail(i, 'unterminated string') end
    local c = s:sub(k, k)
    out[#out + 1] = s:sub(j, k - 1)
    if c == '"' then
      return table.concat(out), k + 1
    elseif c == '\\' then
      local e = s:sub(k + 1, k + 1)
      if e == 'u' then
        local hex = s:match('^%x%x%x%x', k + 2)
        if not hex then fail(k, 'bad \\u escape') end
        local cp = tonumber(hex, 16)
        j = k + 6
        if cp >= 0xD800 and cp <= 0xDBFF then
          local lo = s:match('^\\u(%x%x%x%x)', j)
          lo = lo and tonumber(lo, 16)
          if lo and lo >= 0xDC00 and lo <= 0xDFFF then
            cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
            j = j + 6
          else
            cp = 0xFFFD
          end
        elseif cp >= 0xDC00 and cp <= 0xDFFF then
          cp = 0xFFFD
        end
        out[#out + 1] = utf8.char(cp)
      elseif escapes[e] then
        out[#out + 1] = escapes[e]
        j = k + 2
      else
        fail(k, 'bad escape')
      end
    else
      fail(k, 'control character in string')
    end
  end
end

local function decode_number(s, i)
  local num = s:match('^-?%d+%.?%d*[eE]?[-+]?%d*', i)
  if not num or num == '' or num == '-' then fail(i, 'bad number') end
  local n = math.tointeger(tonumber(num)) or tonumber(num)
  if not n then fail(i, 'bad number') end
  return n, i + #num
end

local literals = { ['true'] = true, ['false'] = false, null = Json.null }

function decode_value(s, i, depth)
  if depth > 200 then fail(i, 'too deep') end
  i = skip(s, i)
  local c = s:sub(i, i)
  if c == '{' then
    local t = {}
    i = skip(s, i + 1)
    if s:sub(i, i) == '}' then return t, i + 1 end
    while true do
      if s:sub(i, i) ~= '"' then fail(i, 'expected a key') end
      local k
      k, i = decode_string(s, i)
      i = skip(s, i)
      if s:sub(i, i) ~= ':' then fail(i, 'expected :') end
      t[k], i = decode_value(s, i + 1, depth + 1)
      i = skip(s, i)
      c = s:sub(i, i)
      if c == '}' then return t, i + 1 end
      if c ~= ',' then fail(i, 'expected , or }') end
      i = skip(s, i + 1)
    end
  elseif c == '[' then
    local t, n = {}, 0
    i = skip(s, i + 1)
    if s:sub(i, i) == ']' then return t, i + 1 end
    while true do
      n = n + 1
      t[n], i = decode_value(s, i, depth + 1)
      i = skip(s, i)
      c = s:sub(i, i)
      if c == ']' then return t, i + 1 end
      if c ~= ',' then fail(i, 'expected , or ]') end
      i = i + 1
    end
  elseif c == '"' then
    return decode_string(s, i)
  elseif c == '-' or c:match('%d') then
    return decode_number(s, i)
  else
    for word, v in pairs(literals) do
      if s:sub(i, i + #word - 1) == word then return v, i + #word end
    end
    fail(i, c == '' and 'unexpected end' or ('unexpected ' .. c))
  end
end

function Json.decode(s)
  if type(s) ~= 'string' then return nil, 'not a string' end
  local ok, v, i = pcall(decode_value, s, 1, 0)
  if not ok then
    if type(v) == 'table' then return nil, 'at byte ' .. v.at .. ': ' .. v.msg end
    return nil, tostring(v)
  end
  i = skip(s, i)
  if i <= #s then return nil, 'at byte ' .. i .. ': trailing data' end
  return v
end

return Json
