local util = require("util")

local librecipe = {}

librecipe.recipes = {}

local fd = io.open("recipes.db", "r")
local text = fd:read("*all")
fd:close()
recp_lines = util.split(text, "\n")
local cur_name = nil
local cur_actions = {}
local hack_limit1 = false

local function flush()
  if not cur_name then return end
  if not librecipe.recipes[cur_name] then librecipe.recipes[cur_name] = {} end
  local obj = { actions = cur_actions }
  if hack_limit1 then obj.hack_limit1 = true end
  table.insert(librecipe.recipes[cur_name], obj)
  cur_actions = {}
  hack_limit1 = false
end

print("Reading recipes.")

local alias_map = {}
function librecipe.resolve_name(name)
  if alias_map[name] then
    return alias_map[name]
  else
    return name
  end
end

function librecipe.reverse_name(name, return_nil)
  for k,v in pairs(alias_map) do
    if v == name then return k end
  end
  if return_nil then return nil end
  return name
end

local function slotcheck(slot)
  assert((slot >= 1 and slot <= 9) or slot == 0)
  -- match 1-9 slots to 1-16 slots
  if slot > 3 then slot = slot + 1 end
  if slot > 7 then slot = slot + 1 end
  if slot == 0 then slot = 16 end -- reserved slot
  return slot
end

for k,line in ipairs(recp_lines) do
  local full_line = line
  if line:find("--", 1, true) then
    line = util.slice(line, "--") -- comment
  end
  line = util.strip(line)
  if line:len() == 0 then
  elseif line:sub(1,1) == "=" then
    flush()
    aliases = util.split_sa(line:sub(2, -1), ",")
    assert(#aliases == 2, "more than two aliases "..full_line)
    local name, target = aliases[1], aliases[2]
    assert(not alias_map[name], "alias defined twice: "..name)
    alias_map[name] = target
  elseif line:sub(1,3) == ":!A" then
    flush()
    cur_name = librecipe.resolve_name(util.strip(line:sub(4, -1)))
    hack_limit1 = true
  elseif line:sub(1,1) == ":" then
    flush()
    cur_name = librecipe.resolve_name(util.strip(line:sub(2, -1)))
  else
    -- fetch 1@1 1@5 minecraft:planks
    -- craft store 4@1 stick
    local cmds = {}
    while line:len() > 0 do
      local cmd, rest = util.slice(line, " ")
      if cmd:find("@") then break end
      table.insert(cmds, cmd)
      line = util.strip(rest)
    end
    assert(line:len() > 0, "bad line "..full_line)
    
    local stats = {}
    while line:len() > 0 do
      local stat, rest = util.slice(line, " ")
      if not stat:find("@") then break end
      table.insert(stats, stat)
      line = util.strip(rest)
    end
    assert(line:len() > 0, "bad line "..full_line)
      
    local name = util.strip(line)
    for _,cmd in ipairs(cmds) do
      for _,stat in ipairs(stats) do
        local count
        local slot
        count, slot = util.slice(stat, "@")
        if count == "" then
          count = 1
        else
          count = tonumber(count)
        end
        assert(count >= 1)
        
        local slots = {}
        if slot:find(",") then
          local slot_ids = util.split_sa(slot, ",")
          for _, v in ipairs(slot_ids) do
            local slot = tonumber(v)
            slot = slotcheck(slot)
            table.insert(slots, slot)
          end
        else
          slot = tonumber(slot)
          slot = slotcheck(slot)
          table.insert(slots, slot)
        end
        
        assert(cmd == "fetch" or cmd == "store" or cmd == "craft" or cmd == "drop" or cmd == "drop_down" or cmd == "suck" or cmd == "suck_up")
        
        for _, slot in ipairs(slots) do
          local obj = { type = cmd, count = count, slot = slot }
          if cmd == "drop" or cmd == "drop_down" or cmd == "suck" or cmd == "suck_up" then
            local location, itemname = util.slice(name, " ")
            name = util.strip(itemname)
            obj.location = util.strip(location)
          end
          obj.name = librecipe.resolve_name(name)
          
          table.insert(cur_actions, obj)
        end
      end
    end
  end
end

flush()

print("Gathering recipe effects.")

-- recipes expressed in terms of gained/lost
librecipe.effects = {}
librecipe.occupies = {}
for name, recipes in pairs(librecipe.recipes) do
  librecipe.effects[name] = {}
  librecipe.occupies[name] = {}
  for i, recipe in ipairs(recipes) do
    local effects = {}
    librecipe.effects[name][i] = effects
    local occupies = {}
    librecipe.occupies[name][i] = occupies
    for k,action in pairs(recipe.actions) do
      if action.type == "store" then
        effects[action.name] = (effects[action.name] or 0) + action.count
      elseif action.type == "fetch" then
        effects[action.name] = (effects[action.name] or 0) - action.count
      elseif action.type == "drop" or action.type == "drop_down" then
        occupies[util.slice(action.location, ":")] = true
      elseif action.type == "craft" or action.type == "suck" or action.type == "suck_up" then
      else
        assert(false, "unaccounted-for action type: "..action.type)
      end
    end
  end
end

return librecipe
