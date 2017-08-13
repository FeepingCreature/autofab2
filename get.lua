local util = require("util")
local libplan = require("libplan")
local libnav = require("libnav")
local libchest = require("libchest")
local libcapacity = require("libcapacity")
local robot = require("robot")
local component = require("component")
local computer = require("computer")

util.init()

print("startup: "..computer.freeMemory().." / "..computer.totalMemory())

local args = { ... }

local function help()
  print("Usage:")
  print("  get [--dump] [<count>] <name>")
  print("  Fetches an item, or crafts it if it's not available.")
end

local Location = {
  Home = 1,
  Chests = 2,
  Machines = 3
}

local recipes = {}

local fd = io.open("recipes.db", "r")
local text = fd:read("*all")
fd:close()
recp_lines = util.split(text, "\n")
local cur_name = nil
local cur_actions = {}
local hack_limit1 = false

local function flush()
  if not cur_name then return end
  if not recipes[cur_name] then recipes[cur_name] = {} end
  local obj = { actions = cur_actions }
  if hack_limit1 then obj.hack_limit1 = true end
  table.insert(recipes[cur_name], obj)
  cur_actions = {}
  hack_limit1 = false
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
    alias_map[name] = target
  elseif line:sub(1,3) == ":!A" then
    flush()
    cur_name = resolve_name(util.strip(line:sub(4, -1)))
    hack_limit1 = true
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

-- TODO Action, StepsAction, PrefetchAction

local Action = {}
Action.mt = { __index = Action }
function Action:new(label, steps, factor, effects, locks_grid, releases_grid)
  if not steps then steps = {} end
  assert(type(effects) == "table")
  
  local obj = {
    id = util.get_key("action"),
    label = label,
    steps = steps,
    effects = effects,
    locks_grid = locks_grid,
    releases_grid = releases_grid,
    depends = {},
    excludes = {},
    readyCbs = {},
    applyCbs = {},
    planCb = nil,
    factor = factor
  }
  
  setmetatable(obj, self.mt)
  obj.new = disabled
  
  obj:exclude(obj) -- action can't run twice
  
  return obj
end

function Action:exclude(action)
  table.insert(self.excludes, action)
end

function Action:depend(action)
  table.insert(self.depends, action)
end

function Action:addReadyCb(cb)
  assert(cb)
  table.insert(self.readyCbs, cb)
end

function Action:addApplyCb(cb)
  assert(cb)
  table.insert(self.applyCbs, cb)
end

function Action:setPlanCb(cb)
  assert(cb and not self.planCb)
  self.planCb = cb
end

function Action:reason(model)
  if model:completed(self) then return "is done" end
  if model:excluded(self) then return "is excluded" end
  
  for _,action in ipairs(self.depends) do
    if not model:completed(action) then return "waits on "..action.label end
  end
  
  for key, val in pairs(self.effects) do
    if val < 0 and model.store:get(key) < -val * self.factor then
      return "needs "..key -- not enough material
    end
  end
  return "for some reason"
end

function step_loc(step)
  assert(step.type)
  if step.type == "fetch" or step.type == "store" then
    return Location.Chests
  elseif step.type == "drop_down" or step.type == "suck" then
    return Location.Machines
  else
    -- print("where is a "..step.type.."??")
    return nil
  end
end

function move_cost(loc1, loc2)
  if not loc1 or not loc2 then return 0 end -- unknown cost
  if loc1 == loc2 then return 0 end -- free
  return 10 -- flat move tax (TODO?)
end

-- return false or a number "cost" indicating how much time this action will waste
function Action:ready(model)
  if model:excluded(self) then return false end
  if self.locks_grid and model.grid_locked then return false end
  
  for _,action in ipairs(self.depends) do
    if not model:completed(action) then return false end
  end
  
  for key, val in pairs(self.effects) do
    if val < 0 and model.store:get(key) < -val * self.factor then
      return false -- not enough material
    end
  end
  
  local res = 0
  
  for k, cb in pairs(self.readyCbs) do
    local cb_res = cb(self, model)
    if not cb_res then return false end
    res = res + cb_res
  end
  
  if #self.steps > 0 then
    local model_loc = model.location
    local first_step = self.steps[1]
    res = res + move_cost(model_loc, step_loc(first_step))
  end
  
  return res
end

function Action:applyToModel(model)
  for _, cb in ipairs(self.applyCbs) do
    cb(self, model)
  end
  
  if self.locks_grid then
    assert(not model.grid_locked)
    model.grid_locked = true
  end
  if self.releases_grid then
    assert(model.grid_locked)
    model.grid_locked = false
  end
  
  for _,action in ipairs(self.excludes) do
    model:exclude(action)
  end
  
  for key, val in pairs(self.effects) do
    model.store:set(key, model.store:get(key) + val * self.factor)
  end
  
  if #self.steps > 0 then
    local last_step = self.steps[#self.steps]
    model.location = step_loc(last_step)
  end
end

function step_to_plan(plan, step, factor)
  local error
  if step.type == "fetch" then
    plan, error = libplan.action_fetch(plan, step.slot, step.name, step.count * factor, libcapacity.get_capacity(step.name))
    assert(plan, error)
  elseif step.type == "craft" then
    plan, error = libplan.action_craft(plan, step.slot, step.name, step.count * factor)
    assert(plan, error)
  elseif step.type == "store" then
    plan, error = libplan.action_store(plan, step.slot, step.name, step.count * factor, libcapacity.get_capacity(step.name))
  elseif step.type == "drop_down" then
    assert(step.location)
    plan, error = libplan.action_drop(plan, "down", step.slot, step.location, step.name, step.count * factor)
  elseif step.type == "suck" then
    assert(step.location)
    plan, error = libplan.action_suck(plan, step.slot, step.location, step.name, step.count * factor)
  else
    assert(false, "unknown recipe action")
  end
  return plan
end

function Action:addToPlan(plan)
  assert(plan)
  if self.planCb then
    assert(#self.steps == 0)
    plan = self.planCb(self, plan)
    assert(plan)
    plan = libplan.opt1(plan)
    return plan
  end
  
  for _,step in ipairs(self.steps) do
    plan = step_to_plan(plan, step, self.factor)
    plan = libplan.opt1(plan)
  end
  return plan
end

local function get_step_info(step)
  local effects, machines = {}, {}
  if step.type == "store" then
    effects[step.name] = (effects[step.name] or 0) + step.count
  elseif step.type == "fetch" then
    effects[step.name] = (effects[step.name] or 0) - step.count
  elseif step.type == "drop_down" or step.type == "suck" then
    machines[util.slice(step.location, ":")] = true
  elseif step.type == "suck" or step.type == "craft" then
  else
    assert(false, "unaccounted-for step type: "..step.type)
  end
  return effects, machines
end

local function any_completed(actions)
  return function(self, model)
    for _,action in ipairs(actions) do
      if model:completed(action) then
        return 0
      end
    end
    return false
  end
end

local function setup_wait_any_completed_fn(set)
  if #set == 0 then
    return function(action) end
  elseif #set == 1 then
    return function(action) action:depend(set[1]) end
  else
    return function(action) action:addReadyCb(any_completed(set)) end
  end
end

local function require_free_registers(self, model)
  if not (model:numFreeRegisters() >= 1) then return false end
  return 1
end

local value_fn_cache = {}
local function value_fn(value)
  if not value_fn_cache[value] then
    value_fn_cache[value] = function() return value end
  end
  return value_fn_cache[value]
end

local function prefetch_action_claim_register_cb(self, model)
  self.prefetch_register = model:claimRegister()
end

local function prefetch_action_prefetch_plan_cb(self, plan)
  local step = self.step
  local factor = self.factor
  plan, error = libplan.action_fetch(plan, self.prefetch_register, step.name, step.count * factor, libcapacity.get_capacity(step.name))
  assert(plan, error)
  return plan
end

local function prefetch_move_action_release_register_cb(self, model)
  model:releaseRegister(self.prefetch_action.prefetch_register)
end

local function prefetch_move_action_plan_cb(self, plan)
  assert(plan)
  local prefetch_action = self.prefetch_action
  local prefetch_register = prefetch_action.prefetch_register
  local step = prefetch_action.step
  plan = libplan.action_move(plan, prefetch_register, step.slot, step.count * self.factor)
  return plan
end

local function configure_prefetch_actions(prefetch_action, move_action, step, factor)
  prefetch_action.prefetch_register = nil
  prefetch_action.step = step
  prefetch_action.factor = factor
  move_action.prefetch_action = prefetch_action
  
  prefetch_action:addApplyCb(prefetch_action_claim_register_cb)
  prefetch_action:setPlanCb(prefetch_action_prefetch_plan_cb)
  
  move_action:addApplyCb(prefetch_move_action_release_register_cb)
  move_action:setPlanCb(prefetch_move_action_plan_cb)
end

local function crafting_grid_available(action, model)
  if model.grid_locked then return false end
  return 0
end

local function machines_free_cb(self, model)
  for k, _ in pairs(self.total_occupies) do
    if model:machineClaimed(k) then return false end
  end
  return 0
end

local function claim_machines_cb(self, model)
  for k, _ in pairs(self.total_occupies) do
    -- print("model claim machine '"..k.."'")
    model:claimMachine(k)
  end
end

local function setup_machine_fns(action, total_occupies)
  action.total_occupies = total_occupies
  action:addReadyCb(machines_free_cb)
  action:addApplyCb(claim_machines_cb)
end

local function free_machine_cb(self, model)
  model:releaseMachine(self.machine_to_free)
end

local function setup_free_machine(action, k)
  action.machine_to_free = k
  action:addApplyCb(free_machine_cb)
end

local function lazy_store_move_apply_cb(self, model)
  self.lazy_register = model:claimRegister()
end

local function lazy_store_move_plan_cb(self, plan)
  local step = self.step
  plan = libplan.action_move(plan, step.slot, self.lazy_register, step.count * self.factor)
  return plan
end

local function lazy_store_execute_release_lazy_register_cb(self, model)
  local lazy_register = self.store_move.lazy_register
  model:releaseRegister(lazy_register)
end

local function lazy_store_execute_plan_cb(self, plan)
  local step = self.store_move.step
  local lazy_register = self.store_move.lazy_register
  plan, error = libplan.action_store(plan, lazy_register, step.name, step.count * self.factor, libcapacity.get_capacity(step.name))
  assert(plan, error)
  return plan
end

function configure_lazy_store_actions(store_move, store_execute, step)
  store_move.lazy_register = nil
  store_move.store_execute = store_execute
  store_move.step = step
  store_execute.store_move = store_move
  
  store_move:addApplyCb(lazy_store_move_apply_cb)
  store_move:setPlanCb(lazy_store_move_plan_cb)
  
  store_execute:addApplyCb(lazy_store_execute_release_lazy_register_cb)
  store_execute:setPlanCb(lazy_store_execute_plan_cb)
end

local function addRecipeActions(recipe_actions, name, index, count)
  -- print("add recipe actions, "..name.."["..index.."]")
  
  local recipe = recipes[name][index]
  local effects = recipe_effects[name][index]
  local total_occupies = recipe_occupies[name][index]
  
  local steps = recipe.actions
  
  local max_factor = count -- factor we can multiply the recipe by
  
  local num_fetchs = 0
  for key, val in pairs(effects) do
    if val < 0 then num_fetchs = num_fetchs + 1 end
    -- we want a stack of size0
    local stacksize = math.abs(val)
    -- we can store at most a stack of
    local cap = libcapacity.get_capacity(key)
    -- TODO max_stack_size instead of effects
    -- assert(stacksize <= cap, "stacksize "..stacksize.." exceeds cap "..cap.." for "..key.." in "..name.."["..index.."]")
    if stacksize > cap then
      max_factor = 1
    else
      local factor = math.floor(cap / stacksize)
      -- print("factor = "..factor.." of "..cap.." / "..stacksize)
      max_factor = math.min(max_factor, factor)
    end
  end
  
  if recipe.hack_limit1 then max_factor = 1 end
  
  -- we have to queue the recipe at most `times` times
  local times = math.ceil(count / max_factor)
  
  local total_consume_effects, total_produce_effects = {}, {}
  for key, val in pairs(effects) do
    if val < 0 then
      total_consume_effects[key] = val
    else
      total_produce_effects[key] = val
    end
  end
  
  for _ = 1,times do
    local factor = math.min(count, max_factor)
    -- print(name.."["..index.."]: "..factor.." of "..count)
    count = count - factor
    
    -- number of items fetched into the 3x3 craftgrid
    -- if this is 0, we can only run if the craftgrid is actually empty
    -- note that this blocks the FETCH, not the PREFETCH!
    local items_live = 0
    
    -- claim all required resources up front, to avoid deadlocks
    local claim_resources = Action:new(reverse_name(name).."["..index.."] claim resources", {}, factor, total_consume_effects, false, false)
    table.insert(recipe_actions, claim_resources)

    local head = claim_resources
    
    local any_occupies = false
    for _, _ in pairs(total_occupies) do
      any_occupies = true
      break
    end
    
    local worth_prefetching = any_occupies -- only prefetch if we're going to go to machines
    
    if any_occupies then
      -- claim all required machines
      local claim_machines = Action:new(reverse_name(name).."["..index.."] claim machines", {}, factor, {}, false, false)
      table.insert(recipe_actions, claim_machines)
      claim_machines:depend(head)
      setup_machine_fns(claim_machines, total_occupies)
      head = claim_machines
    end
    
    local last_machine_action = {}
    for i, step in ipairs(steps) do
      local step_effects, step_machines = get_step_info(step)
      for k, _ in pairs(step_machines) do
        last_machine_action[k] = i
      end
    end
    
    local prev_actions = { head }
    for i, step in ipairs(steps) do
      local step_effects, step_machines = get_step_info(step)
      local step_locks_grid = items_live == 0
      local step_label = reverse_name(name).."["..index.."] step "..i.." "..step.type
      -- print("step "..i..": "..step_label)
      -- since we claimed all resources upfront, we can pretend to have no effect
      if step.type == "fetch" then
        step_effects = {}
      end
      local action = Action:new(step_label, { step }, factor, step_effects, step_locks_grid)
      local step_actions = { action }
      
      for k, _ in pairs(total_occupies) do
        if i == last_machine_action[k] then
          assert(not (step.type == "fetch" or step.type == "store"))
          setup_free_machine(action, k)
        end
      end
      
      local setup_wait_any_completed = setup_wait_any_completed_fn(prev_actions)
      setup_wait_any_completed(action)
      
      if step.type == "suck" then
        -- probably a bunch of waiting
        action:addReadyCb(value_fn(50))
      end
      
      if step.type == "fetch" and worth_prefetching then
        assert(items_live)
        -- can't start a new fetch-drop sequence if another sequence is already running
        if items_live == 0 then action:addReadyCb(crafting_grid_available) end
        
        local prefetch_action = Action:new(step_label.." prefetch", {}, factor, {}, false, false)
        action:exclude(prefetch_action)
        prefetch_action:exclude(action)
        prefetch_action:depend(claim_resources)
        table.insert(recipe_actions, prefetch_action)
        
        prefetch_action:addReadyCb(require_free_registers)
        
        local move_action = Action:new(step_label.." move", {}, factor, {}, step_locks_grid)
        action:exclude(move_action) -- prevent it from waiting forever
        move_action:depend(prefetch_action)
        setup_wait_any_completed(move_action)
        table.insert(step_actions, move_action)
        table.insert(recipe_actions, move_action)
        
        configure_prefetch_actions(prefetch_action, move_action, step, factor)
      end
      
      if step.type == "fetch" or step.type == "suck" then
        items_live = items_live + factor * step.count
      end
      if step.type == "store" or step.type == "drop_down" then
        if items_live then
          items_live = items_live - factor * step.count
          assert(items_live >= 0)
        end
      end
      if step.type == "craft" then items_live = nil end -- cannot be known
      
      -- at the end, the craftgrid must be empty
      local last_step = i == #steps
      local grid_now_empty = items_live == 0
      if last_step then assert(not items_live or grid_now_empty, "last step, but grid definitely still occupied") end
      action.releases_grid = last_step or grid_now_empty
      table.insert(recipe_actions, action)
      
      if step.type == "store" then
        action:addReadyCb(value_fn(5000)) -- much rather do store move/store do
        assert(not (#action.applyCbs > 0), "weird action state to lazy-store")
        local store_move = Action:new(step_label.." move", {}, factor, {}, false, action.releases_grid)
        local store_execute = Action:new(step_label.." do", {}, factor, step_effects, false, false)
        setup_wait_any_completed(store_move)
        table.insert(step_actions, store_move)
        table.insert(recipe_actions, store_move)
        table.insert(recipe_actions, store_execute)
        action:exclude(store_move)
        action:exclude(store_execute)
        store_move:exclude(action)
        store_execute:depend(store_move)
        store_move:addReadyCb(require_free_registers)
        store_execute:addReadyCb(value_fn(500)) -- lot of cost so we hold off until we have to do it; lets us optimize storefetch into move
        configure_lazy_store_actions(store_move, store_execute, step)
      end
      
      prev_actions = step_actions
    end
  end
  -- print("done. "..computer.freeMemory())
end

-- Consume count names, crafting inputs as required
-- if it can't consume the full count, returns the number of names it could have consumed
-- return success, count, missing
local function consume(store, name, count, runs)
  local consumed = 0
  local existing = store:get(name)
  if existing >= count then
    store:set(name, existing - count)
    consumed = count
    return true, consumed, nil
  else
    consumed = existing
  end
  
  store:set(name, 0)
  
  local children = {}
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
    local trial_runs = {}
    for key, val in pairs(effects) do
      if val < 0 then
        local success, subcount, missing = consume(trial, key, -val * attempt, trial_runs)
        if not success then
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
    
    trial:commit()
    for k,v in pairs(trial_runs) do
      if runs[k] then
        runs[k].attempt = runs[k].attempt + v.attempt
      else
        runs[k] = v
      end
    end
    
    local key = name.." - "..recipe_id
    if runs[key] then
      runs[key].attempt = runs[key].attempt + attempt
    else
      runs[key] = { name = name, recipe_id = recipe_id, attempt = attempt }
    end
    
    local actually_consume = math.min(count - consumed, attempt * produced)
    consumed = consumed + actually_consume
    store:set(name, store:get(name) - actually_consume)
    
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
  
  return true, consumed, nil
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
      table.insert(requests, { name = resolve_name(name), count = count })
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
  table.insert(requests, { name = resolve_name(name), count = count })
end
count = nil
name = nil

print("Generating requirement tree.")

local store = StorageInfo:new()

local runs = {}

for _,request in ipairs(requests) do
  print("run outer")
  local success, produced, missing = consume(store, request.name, request.count, runs)
  print("done outer")
  if not success then
    print("Inputs are missing and cannot be crafted: "..format_missing(missing))
    print("managed to make "..produced.." / "..request.count)
    return
  end
end

local recipe_actions = {}

for k, v in pairs(runs) do
  if v.attempt > 0 then
    addRecipeActions(recipe_actions, v.name, v.recipe_id, v.attempt)
  end
end

-- free
store = nil
runs = nil

-- print("Recipe actions:")
-- hits large recursion! bad!
-- util.print(recipe_actions)

local Model = {}
function Model:new()
  local obj = {
    time = 0,
    store = StorageInfo:new(),
    registers = {},
    register_keys = {4, 8, 12, 13, 14, 15, 16},
    excludes = {}, -- actions that can't run, ever
    completes = {}, -- actions that have been selected
    location = Location.Home,
    machine_claimed = {},
    machine_busy_until = {},
    grid_locked = false
  }
  
  for k,v in pairs(self) do obj[k] = v end
  obj.new = nil -- but not that one.
  
  return obj
end

function Model:go_to(loc)
  self.location = loc
end

function Model:cost_go_to(loc)
  if self.location == loc then return 0 end
  return 10 -- average moves chest to machines
end

function Model:numFreeRegisters()
  local res = 0
  for _, v in ipairs(self.register_keys) do
    if not self.registers[v] then res = res + 1 end
  end
  return res
end

function Model:machineClaimed(k)
  return self.machine_claimed[k]
end

function Model:claimMachine(k)
  assert(not self.machine_claimed[k])
  self.machine_claimed[k] = true
end

function Model:releaseMachine(k)
  assert(self.machine_claimed[k], "machine '"..k.."' not claimed.")
  self.machine_claimed[k] = nil
end

function Model:claimRegister()
  for _, v in ipairs(self.register_keys) do
    if not self.registers[v] then
      self.registers[v] = true
      return v
    end
  end
  assert(false)
end

function Model:releaseRegister(reg)
  assert(self.registers[reg], "register not claimed: '"..reg.."'")
  self.registers[reg] = nil
end

function Model:exclude(action)
  self.excludes[action.id] = true
end

function Model:excluded(action)
  return self.excludes[action.id] or false
end

function Model:completed(action)
  return self.completes[action.id] or false
end

function Model:apply(action)
  action:applyToModel(self)
  
  self.completes[action.id] = true
end

local function all_actions_done(model)
  for _,action in ipairs(recipe_actions) do
    if not model:completed(action) and not model:excluded(action) then
      return false -- still one action unfinished and waiting
    end
  end
  return true -- all actions excluded or done
end

local function pick_action(model)
  -- find all available actions
  local ready = {}
  local future_tasks = 0
  for _,action in ipairs(recipe_actions) do
    local cost = action:ready(model)
    if cost then
      table.insert(ready, { action = action, cost = cost })
    elseif not model:excluded(action) then
      future_tasks = future_tasks + 1
    end
  end
  
  if not (#ready > 0) then
    print("No valid leaf found - "..future_tasks)
    print("Blocked tasks:")
    for i,action in ipairs(recipe_actions) do
      if not action:ready(model) then
        print(i..": "..action.label.." "..action:reason(model))
      end
    end
    assert(false)
  end
  
  local selected_action = nil
  local selected_action_cost = nil
  for _, poss in ipairs(ready) do
    if not selected_action or poss.cost < selected_action_cost then
      selected_action = poss.action
      selected_action_cost = poss.cost
    end
  end
  -- selected_action = ready[1].action
  -- selected_action_time = ready[1].time_until
  assert(selected_action)
  
  if dump then
    print("Pick: "..selected_action.label.." x"..selected_action.factor)
  end
  return selected_action, selected_action_time
end

print("Selecting actions.");

local ordered_actions = {}
local model = Model:new()

while not all_actions_done(model) do 
  local action, time_until = pick_action(model)
  model:apply(action, time_until)
  table.insert(ordered_actions, action)
end

-- free
model = nil
recipe_actions = nil

-- print("Time: "..model.time)
-- os.exit()

-- print("Order:")
-- for k,v in ipairs(ordered_actions) do
--   print("  "..k..": "..v.label.." x"..v.factor)
-- end

print("Generating plan.")
local plan = libplan.plan:new()
assert(plan)

for step_id, step in ipairs(ordered_actions) do
  plan = step:addToPlan(plan)
  assert(plan)
end

ordered_actions = nil
os.sleep(0)

print("Fetching product.")

-- TODO distribute capacity
for index,request in ipairs(requests) do
  plan, error = libplan.action_fetch(plan, index, request.name, request.count, request.count)
  assert(plan, error)
  plan = libplan.opt1(plan)
end

local backup = libnav.get_location()

if dump then
  libplan.dump(plan)
else
  libplan.enact(plan)
end

libnav.go_to(backup)
libnav.flush()
