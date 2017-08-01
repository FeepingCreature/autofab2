local util = require("util")
local libplan = require("libplan")
local libnav = require("libnav")
local libcapacity = require("libcapacity")
local robot = require("robot")
local component = require("component")

util.init()

local args = { ... }

local function help()
  print("Usage:")
  print("  get <count> <name>")
  print("  Fetches an item, or crafts it if it's not available.")
end

if not(#args == 2) then
  help()
  return
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

local progress = ""
local function make_available(plan, name, count)
  while true do
    local existing_available = plan.model:get_item_count(name)
    if existing_available >= count then
      return plan
    end
    if not recipes[name] then
      local missing = {}
      missing[name] = count
      return nil, missing
    end
    -- else
    local recipe_list = recipes[name]
    local missing = nil
    for _,recipe in ipairs(recipe_list) do
      local required = {}
      for k,action in pairs(recipe.actions) do
        if action.type == "fetch" then
          required[action.name] = (required[action.name] or 0) + action.count
        end
      end
      
      -- provision inputs
      -- this has to be a loop so that later requirements don't eat our earlier ones
      local provision_missing = nil
      local initplan = plan
      while true do
        local loopplan = plan
        
        local left = 0
        for k,v in pairs(required) do left = left + 1 end
        local backup_progress = progress
        progress = backup_progress .. left
        
        for k,v in pairs(required) do
          local new_missing
          local new_plan
          new_plan, new_missing = make_available(plan, k, v)
          
          left = left - 1
          progress = backup_progress .. left
          
          if new_plan then
            plan = new_plan
          else
            provision_missing = merge_missing("and", provision_missing, new_missing)
          end
        end
        progress = backup_progress
        
        if provision_missing then
          -- rollback
          plan = initplan
          break
        end
        
        -- keep going until all requirements are fulfilled
        if plan.id == loopplan.id then break end
      end
      -- print("progress: "..progress)
      
      if provision_missing then
        missing = merge_missing("or", missing, provision_missing)
      else
        -- execute actions
        for k,action in pairs(recipe.actions) do
          if action.type == "fetch" then
            assert(action.count == 1, "TODO?")
            -- print("fetch "..action.count.." "..action.name)
            plan, error = libplan.action_fetch(plan, action.slot, action.name, action.count, libcapacity.get_capacity(action.name))
            if not plan then
              print(error)
              os.exit()
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
            local location
            local itemname
            location, itemname = util.slice(action.name, " ")
            plan, error = libplan.action_drop(plan, "down", action.slot, location, itemname, action.count)
          elseif action.type == "suck" then
            local location
            local itemname
            location, itemname = util.slice(action.name, " ")
            plan, error = libplan.action_suck(plan, action.slot, location, itemname, action.count)
          else
            assert(false, "unknown recipe action")
          end
        end
        local new_available = plan.model:get_item_count(name)
        assert(new_available > existing_available, "'"..name.."': no progress by recipe: "..existing_available.." to "..new_available)
        missing = nil -- progress was made, discard
        break -- break out of the recipe loop
      end
    end
    if missing then
      missing = merge_missing("annotate", missing, "to make "..count.." "..name)
      return nil, missing
    end
  end
end

local count = tonumber(args[1])
local name = args[2]

local plan = libplan.plan_create()

plan, missing = make_available(plan, name, count)
if not plan then
  print("Inputs are missing and cannot be crafted: "..format_missing(missing))
  return
end

-- TODO distribute capacity
plan, error = libplan.action_fetch(plan, 1, name, count, count)
plan = libplan.opt1(plan)

local backup = libnav.get_location()

libplan.enact(plan)
-- libplan.dump(plan)

libnav.go_to(backup)
libnav.flush()
