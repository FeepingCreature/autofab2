local filesystem = require("filesystem")
local internet = require("internet")

local base = "http://feep.life/~feep/ftblua2/"
local function update(file)
  if filesystem.exists(file..".txt") then
    file = file..".txt"
  elseif file:sub(-3) == ".db" then -- load normally
  else
    package.loaded[file] = nil
    file = file..".lua"
  end
  local fd = io.open(file, "w")
  local url = base..file
  local req = internet.request(url)
  for chunk in req do
    fd:write(chunk)
  end
  fd:close()
end

local args = { ... }
if #args > 0 then
  for k, v in pairs(args) do
    update(v)
  end
else
  update("update")
  update("util")
  update("libnav")
  update("libplace")
  update("libchest")
  update("librecipe")
  update("libcapacity")
  update("libplan")
  update("mov")
  update("place")
  update("chest")
  update("dump")
  update("fetch")
  update("get")
  update("cleanup")
  update("recipes.db")
  -- os.reboot()
end
