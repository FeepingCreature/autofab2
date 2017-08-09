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
  print("  get [--dump] [<count>] <name>")
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

print("Reading recipes.")

local alias_map = {}
local function resolve_name(name)
  if alias_map[name] then
    return alias_map[name]
  else
    return name
  end
end

local function reverse_name(name)
  for k,v in pairs(alias_map) do
    if v == name then return k end
  end
  return name
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
    alias_map[name] = target;
  elseif line:sub(1,1) == ":" then
    flush()
    cur_name = resolve_name(util.strip(line:sub(2, -1)))
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
        count = tonumber(count)
        slot = tonumber(slot)
        assert(count >= 1)
        assert(slot >= 1 and slot <= 9)
        -- match 1-9 slots to 1-16 slots
        if slot > 3 then slot = slot + 1 end
        if slot > 7 then slot = slot + 1 end
        assert(cmd == "fetch" or cmd == "store" or cmd == "craft" or cmd == "drop_down" or "suck")
        
        local obj = { type = cmd, count = count, slot = slot }
        if cmd == "drop_down" or cmd == "suck" then
          local location, itemname = util.slice(name, " ")
          name = util.strip(itemname)
          obj.location = util.strip(location)
        end
        obj.name = resolve_name(name)
        
        table.insert(cur_actions, obj)
      end
    end
  end
end

flush()

print("Gathering recipe effects.")

-- recipes expressed in terms of gained/lost
local recipe_effects = {}
local recipe_occupies = {}
for name, recipes in pairs(recipes) do
  recipe_effects[name] = {}
  recipe_occupies[name] = {}
  for i, recipe in ipairs(recipes) do
    local effects = {}
    recipe_effects[name][i] = effects
    local occupies = {}
    recipe_occupies[name][i] = occupies
    for k,action in pairs(recipe.actions) do
      if action.type == "store" then
        effects[action.name] = (effects[action.name] or 0) + action.count
      elseif action.type == "fetch" then
        effects[action.name] = (effects[action.name] or 0) - action.count
      elseif action.type == "drop_down" then
        occupies[util.slice(action.location, ":")] = true
      elseif action.type == "craft" or action.type == "suck" then
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
  for k,v in pairs(missing) do table.insert(parts, ""..v.." "..reverse_name(k)) end
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
    for key, val in pairs(effects) do
      if val < 0 then
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
      table.insert(actions, { id = util.get_key("step"), name = name, index = recipe_id, count = attempt })
    end
    
    trial:commit()
    
    local consume = math.min(count - consumed, attempt * produced)
    consumed = consumed + consume
    store:set(name, store:get(name) - consume)
    
    if consumed == count then break end
  end
  
  if consumed < count then
    if missing then
      missing = merge_missing("annotate", missing, "to make "..(count - consumed).." "..reverse_name(name))
    else
      missing = {}
      missing[name] = count - consumed
    end
    return nil, consumed, missing
  end
  
  return {
    children = children,
    actions = actions
  }
end

local dump = false
if args[1] == "--dump" then
  dump = true
  local nargs = {}
  for i=2,#args do table.insert(nargs, args[i]) end
  args = nargs
end

if not(#args >= 1) then
  help()
  return
end

local requests = {}
local count = 1
local name = ""
for _,arg in ipairs(args) do
  local ncount = tonumber(arg)
  if ncount then
    if name:len() > 0 then
      table.insert(requests, { name = name, count = count })
      name = ""
    end
    count = ncount
  elseif name:len() > 0 then
    name = name .. " " .. arg
  else
    name = arg
  end
end
if name:len() > 0 then
  table.insert(requests, { name = name, count = count })
end
count = nil
name = nil

print("Generating requirement tree.")

local store = StorageInfo:new()

local trees = {}

for _,request in ipairs(requests) do
  local tree, produced, missing = consume(store, request.name, request.count)
  if not tree then
    print("Inputs are missing and cannot be crafted: "..format_missing(missing))
    print("managed to make "..produced.." / "..request.count)
    return
  end
  if not (tree == true) then
    table.insert(trees, tree)
  end
end

-- free
store = nil

-- print("Plan trees:")
-- util.print(trees)

local Planner = {}
function Planner:new()
  local obj = {
    time = 0,
    store = StorageInfo:new(),
    selected = {},
    machine_busy_until = {}
  }
    
  for k,v in pairs(self) do obj[k] = v end
  obj.new = nil -- but not that one.
  
  return obj
end

function Planner:already_done(step)
  return self.selected[step.id]
end

function Planner:select(step, time_add)
  self.time = self.time + time_add + 1
  self.selected[step.id] = true
  local effects = recipe_effects[step.name][step.index]
  local occupies = recipe_occupies[step.name][step.index]
  for key, val in pairs(effects) do
    self.store:set(key, self.store:get(key) + val * step.count)
  end
  
  -- TODO factor out between ready and here
  for machine, _ in pairs(occupies) do
    local start_after = self.time
    if (self.machine_busy_until[machine] or self.time) > self.time then
      start_after = self.machine_busy_until[machine]
    end
    self.machine_busy_until[machine] = start_after + step.count
  end
end

-- return nil if not runnable, otherwise return the expected time until it will finish
function Planner:ready(step)
  if self:already_done(step) then return end -- already executed
  local recipe = recipes[step.name][step.index]
  local effects = recipe_effects[step.name][step.index]
  local occupies = recipe_occupies[step.name][step.index]
  assert(effects and occupies)
  for key, val in pairs(effects) do
    if val < 0 and self.store:get(key) < -val * step.count then
      return -- not ready
    end
  end
  
  local res = 0
  for machine, _ in pairs(occupies) do
    local wait_to_start = 0
    if (self.machine_busy_until[machine] or self.time) > self.time then
      wait_to_start = wait_to_start + (self.machine_busy_until[machine] - self.time)
    end
    res = math.max(res, wait_to_start)
  end
  
  local recipe = recipes[step.name][step.index]
  -- TODO more detailed please
  res = res + step.count * #recipe.actions
  
  return res
end

local flat_actions = {}
local function scan(steps)
  for _,step in ipairs(steps) do
    for _,action in ipairs(step.actions) do
      table.insert(flat_actions, action)
    end
    if #step.children > 0 then
      scan(step.children)
    end
  end
end
scan(trees)

local ordered_actions = {}

function pick_action(planner)
  -- find all ready (all preconditions done) and unselected actions
  local ready = {}
  local future_tasks = 0
  for _,action in ipairs(flat_actions) do
    local time_until = planner:ready(action)
    if time_until then
      table.insert(ready, { action = action, time_until = time_until })
    elseif not planner:already_done(action) then
      future_tasks = future_tasks + 1
    end
  end
  
  if not (#ready > 0) then
    print("No valid leaf found")
    assert(false)
  end
  
  local selected_action = nil
  local selected_action_time = nil
  for _, poss in ipairs(ready) do
    if not selected_action or poss.time_until < selected_action_time then
      selected_action = poss.action
      selected_action_time = poss.time_until
    end
  end
  -- selected_action = ready[1].action
  -- selected_action_time = ready[1].time_until
  assert(selected_action)
  
  -- done, TODO signal more sanely
  if future_tasks == 0 and #ready == 1 then trees = {} end
  
  print("Pick action "..selected_action.name.."["..selected_action.index.."]")
  return selected_action, selected_action_time
end

local planner = Planner:new()
while #trees > 0 do
  local action, time_until = pick_action(planner)
  planner:select(action, time_until)
  table.insert(ordered_actions, action)
end

-- free
all_action_names = nil
ready = nil

-- print("Time: "..planner.time)
-- os.exit()

print("Order:")
util.print(ordered_actions)

print("Generating plan.")
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
        assert(action.location)
        plan, error = libplan.action_drop(plan, "down", action.slot, action.location, action.name, action.count)
      elseif action.type == "suck" then
        assert(action.location)
        plan, error = libplan.action_suck(plan, action.slot, action.location, action.name, action.count)
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
for index,request in ipairs(requests) do
  plan, error = libplan.action_fetch(plan, index, request.name, request.count, request.count)
  assert(plan, error)
end

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
