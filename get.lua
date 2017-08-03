local util = require("util")
local libplan = require("libplan")
local libnav = require("libnav")
local libchest = require("libchest")
local libcapacity = require("libcapacity")
local robot = require("robot")
local component = require("component")
local computer = require("computer")

util.init()

local args = { ... }

local function help()
  print("Usage:")
  print("  get [--dump] <count> <name>")
  print("  Fetches an item, or crafts it if it's not available.")
end

local recipes = {}

local fd = io.open("recipes.db", "r")
local text = fd:read("*all")
fd:close()
recp_lines = util.split(text, "\n")
local cur_name = nil
local cur_actions = {}

local function flush()
  if not cur_name then return end
  if not recipes[cur_name] then recipes[cur_name] = {} end
  table.insert(recipes[cur_name], { actions = cur_actions })
  cur_actions = {}
end

for k,line in ipairs(recp_lines) do
  line = util.strip(line)
  if line:len() == 0 then
  elseif line:sub(1,1) == ":" then
    flush()
    cur_name = util.strip(line:sub(2, -1))
  else
    -- fetch 1@1 1@5 minecraft:planks
    -- craft store 4@1 stick
    local cmds = {}
    while true do
      local rest
      local cmd
      cmd, rest = util.slice(line, " ")
      if cmd:find("@") then break end
      table.insert(cmds, cmd)
      line = rest
    end
    local stats = {}
    while true do
      local rest
      local stat
      stat, rest = util.slice(line, " ")
      if not stat:find("@") then break end
      table.insert(stats, stat)
      line = rest
    end
    local name = util.strip(line)
    for _,cmd in ipairs(cmds) do
      for _,stat in ipairs(stats) do
        local count
        local slot
        count, slot = util.slice(stat, "@")
        count = tonumber(count)
        slot = tonumber(slot)
        assert(count >= 1)
        assert(slot >= 1 and slot <= 9)
        -- match 1-9 slots to 1-16 slots
        if slot > 3 then slot = slot + 1 end
        if slot > 7 then slot = slot + 1 end
        assert(cmd == "fetch" or cmd == "store" or cmd == "craft" or cmd == "drop_down" or "suck")
        table.insert(cur_actions, { type = cmd, name = name, count = count, slot = slot })
      end
    end
  end
end

flush()

-- recipes expressed in terms of gained/lost
local recipe_effects = {}
for name, recipes in pairs(recipes) do
  recipe_effects[name] = {}
  for i, recipe in ipairs(recipes) do
    local effects = {}
    recipe_effects[name][i] = effects
    for k,action in pairs(recipe.actions) do
      if action.type == "store" then
        effects[action.name] = (effects[action.name] or 0) + action.count
      elseif action.type == "fetch" then
        effects[action.name] = (effects[action.name] or 0) - action.count
      elseif action.type == "craft" or action.type == "drop_down" or action.type == "suck" then
      else
        assert(false, "unaccounted-for action type: "..action.type)
      end
    end
  end
end

local StorageInfo = {}
function StorageInfo.new(self, parent)
  local obj = {
    parent = parent,
    items = nil
  }
  for k,v in pairs(self) do obj[k] = v end
  if not parent then
    -- init from chest
    obj.items = {}
    local chestnames = libchest.list_chests()
    for k,v in ipairs(chestnames) do
      local info = libchest.get_info(v)
      for i = 1, info.capacity do
        local slot = info.slots[i]
        if slot.name then
          obj.items[slot.name] = (obj.items[slot.name] or 0) + slot.count
        end
      end
    end
  end
  obj.new = nil -- but unset 
  return obj
end

function StorageInfo.get(self, name)
  local obj = self
  while obj.parent and (not obj.items or not obj.items[name]) do
    obj = obj.parent
  end
  return obj.items[name] or 0
end

function StorageInfo.set(self, name, count)
  assert(name and count >= 0)
  assert(self.parent, "don't set items manually on the root state")
  if not self.items then self.items = {} end
  self.items[name] = count
end

function StorageInfo.commit(self)
  assert(self.parent)
  for k,v in pairs(self.items) do
    self.parent:set(k, v)
  end
end

-- build recipe tree
-- return value: [ children: [*], actions: { name, index } ]

local function format_missing(missing)
  if type(missing) == "string" then return missing end
  local parts = {}
  for k,v in pairs(missing) do table.insert(parts, ""..v.." "..k) end
  return util.join(parts, ", ")
end

local function merge_missing(mode, a, b)
  if not a and not b then return nil end
  if a and not b then return a end
  if b and not a then return b end
  if mode == "and" then return "("..format_missing(a)..") and ("..format_missing(b)..")" end
  if mode == "or" then return "("..format_missing(a)..") or ("..format_missing(b)..")" end
  if mode == "annotate" then return format_missing(a) .. " " .. b end
  assert(false)
end

-- Consume name counts, crafting inputs as required
-- if it can't consume the full count, returns the number of names it could have consumed
-- return tree, count, missing
function consume(store, name, count)
  local consumed = 0
  local existing = store:get(name)
  if existing >= count then
    store:set(name, existing - count)
    consumed = count
    return true, consumed, nil
  end
  
  consumed = consumed + existing
  store:set(name, 0)
  
  local children = {}
  local actions = {}
  local outer_consumes = {}
  local missing = nil
  
  local recipe_list = recipes[name] or {}
  for recipe_id, recipe in ipairs(recipe_list) do
    local effects = recipe_effects[name][recipe_id]
    
    local produced
    for key, val in pairs(effects) do
      if val > 0 and key == name then
        produced = val
        break
      end
    end
    assert(produced, name.." recipe does not produce "..name)
    
    local attempt = math.ceil((count - consumed) / produced)
    local provision_missing = nil
    ::retry::
    local trial = StorageInfo:new(store)
    consumes = {}
    for key, val in pairs(effects) do
      if val < 0 then
        consumes[key] = true
        local success, subcount, missing = consume(trial, key, -val * attempt)
        if success then
          if not (success == true) then
            table.insert(children, success)
          end
        else
          local could_consume = math.floor(subcount / -val)
          assert(could_consume < attempt)
          attempt = could_consume
          provision_missing = merge_missing("and", provision_missing, missing)
          goto retry
        end
      end
    end
    
    for key, val in pairs(effects) do
      if val > 0 then
        trial:set(key, trial:get(key) + val * attempt)
      end
    end
    
    if provision_missing then
      missing = merge_missing("or", missing, provision_missing)
    end
    
    if attempt > 0 then
      table.insert(actions, { name = name, index = recipe_id, count = attempt })
      for k,_ in pairs(consumes) do outer_consumes[k] = true end
    end
    
    trial:commit()
    
    local consume = math.min(count - consumed, attempt * produced)
    consumed = consumed + consume
    store:set(name, store:get(name) - consume)
    
    if consumed == count then break end
  end
  
  if consumed < count then
    if missing then
      missing = merge_missing("annotate", missing, "to make "..(count - consumed).." "..name)
    else
      missing = {}
      missing[name] = count - consumed
    end
    return nil, consumed, missing
  end
  
  return {
    name = name,
    children = children,
    actions = actions,
    consumes = outer_consumes
  }
end

local dump = false
if args[1] == "--dump" then
  dump = true
  local nargs = {}
  for i=2,#args do nargs[i - 1] = args[i] end
  args = nargs
end

if not(#args >= 2) then
  help()
  return
end

local count = tonumber(args[1])
local name = {}
for i=2,#args do table.insert(name, args[i]) end
name = util.join(name, " ")

local store = StorageInfo:new(StorageInfo:new())
local tree, produced, missing = consume(store, name, count)
if not tree then
  print("Inputs are missing and cannot be crafted: "..format_missing(missing))
  print("managed to make "..produced.." / "..count)
  return
end

-- print("Plan tree:")
-- util.print(tree)

local all_action_names = {}
local function scan_actions(action)
  all_action_names[action.name] = true
  for k,v in pairs(action.children) do scan_actions(v) end
end
scan_actions(tree)

local ordered_actions = {}

local ready = {}
function pick_action()
  local leaves = {}
  local exclude = {}
  -- find all leaves with no children that aren't already ready
  local function scan(action)
    if #action.children > 0 then
      for _,v in ipairs(action.children) do
        scan(v)
      end
      exclude[action.name] = true
    else
      local safe = true
      assert(action.consumes)
      for _,key in pairs(action.consumes) do
        if all_action_names[key] and not ready[key] then
          safe = false
        end
      end
      if safe then leaves[action.name] = true end
    end
  end
  scan(tree)
  
  local leaf = nil
  for k,v in pairs(leaves) do
    if not exclude[k] then
      leaf = k
      break
    end
  end
  if not leaf then
    print("No valid leaf found.")
    util.print(tree)
  end
  assert(leaf)
  
  local function remove(action)
    if action.name == leaf then
      assert(#action.children == 0)
      for _,sub_action in ipairs(action.actions) do
        table.insert(ordered_actions, sub_action)
      end
      return nil
    end
    
    local new_children = {}
    for _,child in ipairs(action.children) do
      child = remove(child)
      if child then table.insert(new_children, child) end
    end
    action.children = new_children
    return action
  end
  tree = remove(tree)
  ready[leaf] = true
end

while tree do
  pick_action()
end

-- free
all_action_names = nil
ready = nil

-- print("Order:")
-- util.print(ordered_actions)

local plan = libplan.plan:new()

for step_id, step in ipairs(ordered_actions) do
  local recipe = recipes[step.name][step.index]
  assert(recipe)
  for count_id = 1, step.count do
    for k,action in pairs(recipe.actions) do
      if action.type == "fetch" then
        -- print("fetch "..action.count.." "..action.name)
        plan, error = libplan.action_fetch(plan, action.slot, action.name, action.count, libcapacity.get_capacity(action.name))
        if not plan then
          print("While executing part "..count_id.." of step "..step_id..", "..step.name.."["..step.index.."]:")
          print(error)
          assert(false)
        end
        assert(plan, error)
        plan = libplan.opt1(plan)
      elseif action.type == "craft" then
        plan, error = libplan.action_craft(plan, action.slot, action.name, action.count)
        assert(plan, error)
        plan = libplan.opt1(plan)
      elseif action.type == "store" then
        plan, error = libplan.action_store(plan, action.slot, action.name, action.count, libcapacity.get_capacity(action.name))
        plan = libplan.opt1(plan)
      elseif action.type == "drop_down" then
        local location, itemname = util.slice(action.name, " ")
        plan, error = libplan.action_drop(plan, "down", action.slot, location, itemname, action.count)
      elseif action.type == "suck" then
        local location, itemname = util.slice(action.name, " ")
        plan, error = libplan.action_suck(plan, action.slot, location, itemname, action.count)
      else
        assert(false, "unknown recipe action")
      end
    end
    plan = libplan.opt1(plan)
  end
end

print("Optimize slots")
-- side slots are general registers
for _, value in ipairs({4, 8, 12, 13, 14, 15, 16}) do
  plan = libplan.action_occupy(plan, value, 0)
  plan = libplan.opt1(plan)
end

-- TODO distribute capacity
plan, error = libplan.action_fetch(plan, 1, name, count, count)
print("Final opt")
libplan.final_opt = true
plan = libplan.opt(plan)

local backup = libnav.get_location()

if dump then
  libplan.dump(plan)
else
  libplan.enact(plan)
end

libnav.go_to(backup)
libnav.flush()
