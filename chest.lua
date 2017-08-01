local libchest = require("libchest")
local util = require("util")

util.init()

local args = { ... }

local function help()
  print("Usage:")
  print("  chest define <name> <location>")
end

if #args == 0 then
  help()
  return
end

local command = args[1];
if command == "define" then
  if not (#args == 3) then
    help()
    print("Wrong number of arguments.")
    return
  end
  libchest.define(args[2], args[3])
elseif command == "store" then
  if not (#args == 1) then
    help()
    print("'store' does not take arguments.")
    return
  end
  print("TODO")
  assert(false)
else
  help()
  print("Unknown command: '"..command.."'")
end
