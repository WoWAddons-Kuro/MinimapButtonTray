-- MinimapButtonTray: namespace, saved variables, events, scan scheduling and
-- the /mbt slash command. See SPEC.md.
local ADDON_NAME, MBT = ...
local Client = MBT.Client

MBT.version = Client.GetAddOnMetadata(ADDON_NAME, "Version") or "dev"

local CHAT_PREFIX = "|cff66ccffMinimapButtonTray|r "

-- Grow directions: rows fill in the first direction, extra rows go the second way.
local DIRECTIONS = {
  "leftdown", "leftup", "rightdown", "rightup",
  "downleft", "downright", "upleft", "upright",
}
MBT.DIRECTIONS = DIRECTIONS

local DIRECTION_LABELS = {
  leftdown = "Left, then down",
  leftup = "Left, then up",
  rightdown = "Right, then down",
  rightup = "Right, then up",
  downleft = "Down, then left",
  downright = "Down, then right",
  upleft = "Up, then left",
  upright = "Up, then right",
}

local DEFAULTS = {
  direction = "leftdown",
  perRow = 5,               -- 1..12
  scale = 1,                -- main button and tray, 0.5..2
  buttonScale = 1,          -- collected buttons, on top of scale, 0.5..2
  autoHideSeconds = 5,      -- idle seconds before the tray closes itself; 0 = never; 0..15 in 0.25 steps
  locked = false,           -- the main button cannot be dragged
  hideCompartment = false,  -- hide Blizzard's addon compartment (clients that have one)
  posX = nil,               -- main button centre offset from the minimap centre, UIParent units
  posY = nil,               -- nil = default spot on the ring
  ignore = {},              -- [frameName] = true, never collected
  include = {},             -- [framePath] = true, always collected ("Frame" or "Frame.child")
  order = {},               -- array of names: grid order after shift-drag; unlisted sort alphabetically after
  pinned = {},              -- array of names: shown as [button] [name] rows under the grid
}
MBT.DEFAULTS = DEFAULTS

local AUTO_HIDE_MAX = 15
local AUTO_HIDE_STEP = 0.25
MBT.AUTO_HIDE_MAX = AUTO_HIDE_MAX
MBT.AUTO_HIDE_STEP = AUTO_HIDE_STEP

local db
local loggedIn = false
local rescanQueued = false
local dispatcher = CreateFrame("Frame")
local commands = {}

-- ---------------------------------------------------------------------------
-- utils
-- ---------------------------------------------------------------------------
local function Print(fmt, ...)
  if select("#", ...) > 0 then fmt = string.format(fmt, ...) end
  print(CHAT_PREFIX .. fmt)
end
MBT.Print = Print

function MBT.DirectionLabel(direction)
  return DIRECTION_LABELS[direction] or tostring(direction)
end

local function isDirection(value)
  for _, direction in ipairs(DIRECTIONS) do
    if direction == value then return true end
  end
  return false
end

local function clamp(value, low, high)
  if value < low then return low end
  if value > high then return high end
  return value
end
MBT.Clamp = clamp

local function yesNo(value)
  return value and "|cff00ff00yes|r" or "|cffff0000no|r"
end

local function sortedKeys(set)
  local keys = {}
  for key in pairs(set) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return a:lower() < b:lower() end)
  return keys
end

-- ---------------------------------------------------------------------------
-- saved variables
-- ---------------------------------------------------------------------------

-- Missing or broken values fall back to the default one key at a time, so a
-- hand-edited or older file never takes the whole addon down.
function MBT.InitDatabase()
  if db then return db end
  local saved = MinimapButtonTrayDB
  if type(saved) ~= "table" then saved = {} end

  for key, value in pairs(DEFAULTS) do
    if type(value) == "table" then
      if type(saved[key]) ~= "table" then saved[key] = {} end
    elseif value ~= nil and type(saved[key]) ~= type(value) then
      saved[key] = value
    end
  end
  if not isDirection(saved.direction) then saved.direction = DEFAULTS.direction end
  saved.perRow = clamp(math.floor(saved.perRow + 0.5), 1, 12)
  saved.scale = clamp(saved.scale, 0.5, 2)
  saved.buttonScale = clamp(saved.buttonScale, 0.5, 2)
  saved.autoHideSeconds = clamp(math.floor(saved.autoHideSeconds / AUTO_HIDE_STEP + 0.5) * AUTO_HIDE_STEP, 0, AUTO_HIDE_MAX)
  if type(saved.posX) ~= "number" or type(saved.posY) ~= "number" then
    saved.posX, saved.posY = nil, nil
  end

  MinimapButtonTrayDB = saved
  db = saved
  MBT.db = saved
  return saved
end

-- ---------------------------------------------------------------------------
-- scan scheduling
-- ---------------------------------------------------------------------------

-- One rescan per burst: an addon loading on demand can create its button a
-- little after ADDON_LOADED, and several of them often load together.
function MBT.QueueRescan(delay)
  if rescanQueued or not Client.hasTimers then return end
  rescanQueued = true
  C_Timer.After(delay or 0.5, function()
    rescanQueued = false
    MBT.Collector.Scan()
  end)
end

local function onLogin()
  MBT.InitDatabase()
  loggedIn = true
  MBT.Tray.Init()
  MBT.Tray.ApplyCompartment()
  MBT.Options.Init()
  -- Most addons make their button on PLAYER_LOGIN, some a bit later (next
  -- frame, a timer): scan now, next frame and after a while.
  MBT.Collector.Scan()
  if Client.hasTimers then
    C_Timer.After(0, function() MBT.Collector.Scan() end)
    C_Timer.After(2, function() MBT.Collector.Scan() end)
    C_Timer.After(8, function() MBT.Collector.Scan() end)
  end
  MBT.Collector.HookLibDBIcon()
end

dispatcher:RegisterEvent("ADDON_LOADED")
dispatcher:RegisterEvent("PLAYER_LOGIN")
dispatcher:RegisterEvent("PLAYER_ENTERING_WORLD")
dispatcher:RegisterEvent("PLAYER_REGEN_ENABLED")

dispatcher:SetScript("OnEvent", function(_, event, arg1)
  if event == "ADDON_LOADED" then
    if arg1 == ADDON_NAME then
      MBT.InitDatabase()
    elseif loggedIn then
      MBT.QueueRescan(0.5)
    end
  elseif event == "PLAYER_LOGIN" then
    onLogin()
  elseif event == "PLAYER_ENTERING_WORLD" then
    if loggedIn then MBT.QueueRescan(1) end
  elseif event == "PLAYER_REGEN_ENABLED" then
    if MBT.Collector.pending then MBT.Collector.Scan() end
  end
end)

-- ---------------------------------------------------------------------------
-- slash commands
-- ---------------------------------------------------------------------------
local HELP = {
  "/mbt - options",
  "/mbt toggle | show | hide - the tray",
  "/mbt list - collected, ignored and hand-picked buttons",
  "/mbt ignore <name> - leave a button on the minimap",
  "/mbt unignore <name> - collect it again",
  "/mbt add <path> - collect a frame that is not recognised on its own (Frame or Frame.child)",
  "/mbt remove <path> - undo /mbt add",
  "/mbt reset - put the button back next to the minimap",
  "/mbt rescan - look for new buttons",
  "/mbt status - current settings",
  "/mbt debug - client, every frame on the minimap and why it was collected or skipped",
}

local function usage()
  Print("commands:")
  for _, line in ipairs(HELP) do print("  " .. line) end
end

commands.options = function() MBT.Options.Open() end
commands.settings = commands.options
commands.config = commands.options

commands.toggle = function() MBT.Tray.Toggle() end
commands.show = function() MBT.Tray.Open() end
commands.hide = function() MBT.Tray.Close() end

commands.list = function()
  local Collector = MBT.Collector
  Collector.Scan()
  if #Collector.buttons == 0 then
    Print("No minimap button collected")
  else
    Print("Collected buttons (%d):", #Collector.buttons)
    for _, button in ipairs(Collector.buttons) do
      local name = Collector.LabelOf(button) or "?"
      print("  " .. name .. (button:IsShown() and "" or "  |cff999999(hidden by its addon)|r"))
    end
  end
  local ignored, included = sortedKeys(db.ignore), sortedKeys(db.include)
  if #ignored > 0 then
    Print("Ignored:")
    for _, name in ipairs(ignored) do print("  " .. name) end
  end
  if #included > 0 then
    Print("Added by hand:")
    for _, name in ipairs(included) do print("  " .. name) end
  end
end

commands.ignore = function(argument)
  if argument == "" then return usage() end
  local name = MBT.Collector.Ignore(argument)
  Print("%s is no longer collected", name)
  MBT.Options.Refresh()
end

commands.unignore = function(argument)
  if argument == "" then return usage() end
  local name = MBT.Collector.Unignore(argument)
  if name then Print("%s is collected again", name) else Print("%s was not ignored", argument) end
  MBT.Options.Refresh()
end

commands.add = function(argument)
  if argument == "" then return usage() end
  if MBT.Collector.Include(argument) then
    Print("%s added", argument)
  else
    Print("%s saved, but no such frame right now: it will be collected when it appears", argument)
  end
  MBT.Options.Refresh()
end
commands.include = commands.add

commands.remove = function(argument)
  if argument == "" then return usage() end
  local name = MBT.Collector.Uninclude(argument)
  if name then Print("%s removed from the hand-picked list", name) else Print("%s was not in the hand-picked list", argument) end
  MBT.Options.Refresh()
end

commands.reset = function()
  MBT.Tray.ResetPosition()
  Print("Button moved back next to the minimap")
end

commands.rescan = function()
  local before = #MBT.Collector.buttons
  MBT.Collector.Scan()
  Print("%d button(s) collected (%d new)", #MBT.Collector.buttons, #MBT.Collector.buttons - before)
end
commands.scan = commands.rescan

commands.status = function()
  Print("v%s on %s (interface %d)", MBT.version, Client.flavour, Client.interface)
  print("  Buttons collected: " .. #MBT.Collector.buttons)
  print("  Layout: " .. MBT.DirectionLabel(db.direction) .. ", " .. db.perRow .. " per row")
  print("  Auto-hide: " .. (db.autoHideSeconds > 0 and (db.autoHideSeconds .. " s idle") or "never"))
  print("  Button locked: " .. yesNo(db.locked))
  if Client.hasCompartment then print("  Hide the addon compartment: " .. yesNo(db.hideCompartment)) end
end

-- Everything a missing-button report needs on a new build.
commands.debug = function()
  Print("v%s - client %s build %s", MBT.version, Client.buildVersion, Client.buildNumber)
  for _, line in ipairs(Client.Describe()) do print("  " .. line) end
  print("  LibStub: " .. yesNo(_G.LibStub ~= nil) .. ", LibDBIcon: " .. yesNo(MBT.Collector.GetLibDBIcon() ~= nil))
  for _, line in ipairs(MBT.Collector.Describe()) do print("  " .. line) end
end

commands.dragdebug = function()
  MBT.Tray.dragDebug = not MBT.Tray.dragDebug
  Print("drag debug %s - shift-drag a button and watch the chat", MBT.Tray.dragDebug and "on" or "off")
end

commands.help = usage

local function handler(input)
  local command, argument = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
  command = (command or ""):lower()
  if command == "" then command = "options" end
  local action = commands[command]
  if action then action(argument or "") else usage() end
end
MBT.SlashHandler = handler

SLASH_MINIMAPBUTTONTRAY1 = "/mbt"
SLASH_MINIMAPBUTTONTRAY2 = "/minimapbuttontray"
SlashCmdList["MINIMAPBUTTONTRAY"] = handler
