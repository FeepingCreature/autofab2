local libplan = require("libplan")
local libnav = require("libnav")
local libcapacity = require("libcapacity")
local robot = require("robot")
local component = require("component")
local util = require("util")

util.init()

local args = { ... }

local function help()
  print("Usage:")
  print("  fetch <count> <name>")
  print("  Fetches an item from storage.")
end

if not(#args == 2) then
  help()
  return
end

local count = tonumber(args[1])
local name = args[2]
assert(name and count)

local plan = libplan.plan_create()

-- todo split stacks
plan, error = libplan.action_fetch(plan, 1, name, count, count)
if not plan then
  print("ERR: Cannot fetch "..count.." "..name..": "..error)
  return
end
plan = libplan.opt1(plan)

local backup = libnav.get_location()

libplan.enact(plan)

libnav.go_to(backup)
libnav.flush()
