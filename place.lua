local libplace = require("libplace")
local util = require("util")

util.init()

local args = { ... }

local function help()
  print("Usage: place (save|go) <name>")
end

if #args == 0 then
  help()
  return
end

local command = args[1];
if command == "save" then
  if not (#args == 2) then
    help()
    print("Wrong number of arguments.")
    return
  end
  libplace.save_as(args[2])
elseif command == "go" then
  if not (#args == 2) then
    help()
    print("Wrong number of arguments.")
    return
  end
  libplace.go_to(args[2])
else
  help()
  print("Unknown command: '"..command.."'")
end
