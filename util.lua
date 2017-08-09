local util = {}

local filesystem = require("filesystem")
local shell = require("shell")

function util.strip(str)
  while str:len() > 0 and (str:sub(1,1) == " " or str:sub(1,1) == "\n")
  do str = str:sub(2,-1)
  end
  while str:len() > 0 and (str:sub(-1,-1) == " " or str:sub(-1,-1) == "\n")
  do str = str:sub(1,-2)
  end
  return str
end

function util.tprint(tbl, indent)
  for k, v in pairs(tbl) do
    util.print(v, indent+1, k)
  end
end

function util.print(value, indent, index)
  if not indent then indent = 0 end
  local posinfo = ""
  if index then posinfo = index .. ": " end
  formatting = string.rep(" ", indent) .. posinfo
  if type(value) == "table" then
    if posinfo:len() > 0 then print(formatting) end
    util.tprint(value, indent)
  elseif type(value) == "string" then
    print(formatting .. "\"" .. value .. "\"")
  else
    print(formatting .. tostring(value))
  end
end

function util.slice(str, marker)
  local pos = str:find(marker, 1, true)
  if pos then
    return str:sub(1, pos - 1), str:sub(pos + marker:len(), str:len())
  else
    return str, ""
  end
end

function util.starts_with(str, marker)
  if str:len() < marker:len() then return nil end
  local cmp = str:sub(1, marker:len())
  if cmp == marker then
    return str:sub(marker:len() + 1)
  end
  return nil
end

assert(util.starts_with("Hello World", "Hello ") == "World")

function util.ends_with(str, marker)
  if str:len() < marker:len() then return nil end
  local cmp = str:sub(-marker:len())
  if cmp == marker then
    return str:sub(1, -marker:len() - 1)
  end
  return nil
end

assert(util.ends_with("Hello World", " World") == "Hello")

function util.split(str, marker)
  local res = {}
  if str:len() == 0 then return res end
  
  local from = 1
  while true do
    local to = str:find(marker, from, true)
    -- print(from.." - "..tostring(to).." in "..str:len())
    if to then
      table.insert(res, str:sub(from, to - 1))
      from = to + marker:len()
    else
      table.insert(res, str:sub(from, str:len()))
      from = str:len() + 1
      break
    end
  end
  return res
end

function util.join(table, marker)
  marker = marker or "\n"
  local str = ""
  for i, v in ipairs(table) do
    if str:len() > 0 then str = str .. marker end
    str = str .. v
  end
  return str
end

-- split, strip into object (keys); value = true
function util.split_so(str, marker)
  local res = {}
  local array = util.split(str, marker)
  for i,v in pairs(array) do
    res[util.strip(array[i])] = true
  end
  return res
end

-- join, add spacing for object's keys; opposite of split_so
function util.join_so(obj, marker)
  local array = {}
  for k,v in pairs(obj) do
    table.insert(array, k)
  end
  return util.join(array, " "..marker.." ")
end

-- split, strip into array
function util.split_sa(str, marker)
  local array = util.split(util.strip(str), marker)
  for k,v in pairs(array) do
    -- this is safe since we neither create nor remove keys
    array[k] = util.strip(v)
  end
  return array
end


function util.check_stack(stack)
  -- damage name hack
  if stack.maxDamage == 0 and stack.damage > 0 then
    stack.name = stack.name .. ":" .. stack.damage
  end
  -- identifying stack information stored in tag 😞 use label 😞
  if stack.hasTag then
    assert(stack.label)
    stack.name = stack.label
  end
  -- can only take, not place (handle damage as a hack)
  if stack.maxDamage > 0 and stack.damage > 0 then
    stack.maxSize = 1 -- force limit to avoid problems
  end
end

local fscache = {}

function util.cache_read(filename)
  if fscache[filename] then return fscache[filename] end
  local fd = io.open(filename, "r")
  local text = fd:read("*all")
  fd:close()
  fscache[filename] = text
  return text
end

function util.cache_write(filename, text)
  fscache[filename] = data
  local fd = io.open(filename, "w")
  assert(fd, "Could not open "..filename.." for writing.")
  fd:write(text)
  fd:close()
end

function util.config(filename)
  assert(filename)
  local lines = {}
  if not filesystem.exists(filename) and not(filename:sub(1,1) == "/") then
    filename = shell.getWorkingDirectory().."/"..filename
  end
  
  local fresh
  if filesystem.exists(filename) then
    fresh = false
    -- print("read "..filename)
    local text = util.cache_read(filename)
    lines = util.split(text, "\n")
    while #lines > 0 and util.strip(lines[#lines]):len() == 0 do
      table.remove(lines, #lines)
    end
  else
    fresh = true
    print("WARN: no file '"..filename.."'")
  end
  
  local cfg = {
    filename = filename,
    lines = lines,
    fresh = fresh,
    invalid = false,
    changed = false
  }
  function cfg.get(self, key, deflt)
    assert(not self.invalid)
    assert(key and key.find and not key:find("="))
    
    if not deflt then deflt = false end
    for k,line in pairs(self.lines) do
      if (line:find("=")) then
        local lkey
        lkey, rest = util.slice(line, "=")
        lkey = util.strip(lkey)
        if lkey == key then
          return util.strip(rest)
        end
      end
    end
    return deflt
  end
  function cfg.set(self, key, value)
    assert(not self.invalid)
    assert(key and key.find and not key:find("="))
    
    self.changed = true
    for k,line in pairs(self.lines) do
      if (line:find("=")) then
        local lkey
        lkey, rest = util.slice(line, "=")
        lkey = util.strip(lkey)
        if lkey == key then
          self.lines[k] = key .. " = " .. value
          return
        end
      end
    end
    table.insert(self.lines, key .. " = " .. value)
  end
  function cfg.close(self)
    assert(not self.invalid)
    if self.changed then
      table.insert(self.lines, "")
      -- print("save "..self.filename)
      local text = util.join(self.lines, "\n")
      util.cache_write(self.filename, text)
    end
    self.invalid = true
  end
  return cfg
end

function util.config_get(file, key, deflt)
  assert(key)
  local cfg = util.config(file)
  local res = cfg:get(key, deflt)
  cfg:close()
  return res
end

function util.config_set(file, key, value)
  assert(key)
  local cfg = util.config(file)
  cfg:set(key, value)
  cfg:close()
end

function util.init()
  fscache = {}
end

local keymap = {}
function util.get_key(info)
  local res = keymap[info] or 0
  keymap[info] = res + 1
  return res
end

return util
