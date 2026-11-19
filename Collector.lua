-- MinimapButtonTray: finds the minimap buttons of other addons and takes them
-- into the tray; gives them back exactly as they were.
--
-- Sources, each scan: LibDBIcon's own list, LibMapButton's list, the player's
-- hand-picked paths, then a name scan of _G for frames parented to the minimap.
-- The minimap's children are never enumerated: with map-pin addons there are
-- hundreds and the Forever client dies on it (an assertion, not a Lua error).
local ADDON_NAME, MBT = ...
local Client = MBT.Client

local Collector = {}
MBT.Collector = Collector

Collector.buttons = {}        -- collected frames, sorted by name
Collector.pending = false     -- a scan was refused by combat; run one on PLAYER_REGEN_ENABLED
Collector.lastError = nil
Collector.nameScanAt = nil
Collector.nameScans = 0
Collector.libHooked = false

local recordByFrame = {}      -- [frame] = what the frame looked like before we took it
local hookedFrames = {}       -- [frame] = true once Show/Hide hooks are installed (hooks cannot be removed)
local guardedGroups = {}      -- [animationGroup] = true once its OnPlay is hooked
local failedFrames = {}       -- [frame] = true when Grab raised; never retried

-- The real widget methods, taken from a frame nobody touches. Collected
-- buttons get their own copies replaced by no-ops, so the tray goes around them.
local Original = {}
local LOCKED_METHODS = { "SetPoint", "ClearAllPoints", "SetParent", "SetScale", "SetAllPoints", "SetAlpha" }
for _, method in ipairs(LOCKED_METHODS) do Original[method] = UIParent[method] end
Collector.Original = Original

local function noop() end

local MAX_BUTTON_SIZE = 80    -- anything bigger is an overlay, not a button
local NAME_SCAN_INTERVAL = 5  -- seconds, for the throttled scan the tray triggers on open

-- Lower-cased patterns a scanned frame's name must match.
local BUTTON_PATTERNS = {
  "^libdbicon10_", "minimapbutton", "minimapbtn", "minimapicon", "minimapframe", "[-_]minimap[-_]", "minimap$",
}
-- Lower-cased prefixes of map-pin frames that would otherwise match above.
local PIN_PATTERNS = {
  "^handynotes", "^tomtom", "^herebedragons", "^questie", "^gathermate", "^routes", "^easyfind", "^pin",
}
-- Names ending in a digit are pins (HandyNotesPin12) unless they start with one of these.
local NUMBERED_OK_PATTERNS = { "^libdbicon10_", "^tomcats%-" }

-- Keys in _G worth a look: cheap pre-filter before touching the value.
local NAME_HINTS = { "[Mm][Ii][Nn][Ii][Mm][Aa][Pp]", "^LibDBIcon10_" }

-- ---------------------------------------------------------------------------
-- frame helpers (every call pcall'd: any table can sit in _G, some raise)
-- ---------------------------------------------------------------------------
local function matchesAny(text, patterns)
  for _, pattern in ipairs(patterns) do
    if text:find(pattern) then return true end
  end
  return false
end

function Collector.NameOf(frame)
  if type(frame) ~= "table" or type(frame.GetName) ~= "function" then return nil end
  local ok, name = pcall(frame.GetName, frame)
  if not ok then return nil end
  return Client.ReadString(name)
end

local function isFrame(value)
  if type(value) ~= "table" or type(value.IsObjectType) ~= "function" then return false end
  local ok, result = pcall(value.IsObjectType, value, "Frame")
  return ok and result == true
end

local function flag(frame, method)
  if type(frame[method]) ~= "function" then return false end
  local ok, result = pcall(frame[method], frame)
  return ok and result == true
end

local function call(frame, method, ...)
  if type(frame[method]) == "function" then pcall(frame[method], frame, ...) end
end

local function scriptOf(frame, which)
  local ok, handler = pcall(frame.GetScript, frame, which)
  if ok then return handler end
  return nil
end

-- Blizzard's own frames are global variables set by secure code; anything an
-- addon created is tainted by that addon.
local function isBlizzardGlobal(name)
  if not issecurevariable then return false end
  local ok, secure = pcall(issecurevariable, _G, name)
  return ok and secure == true
end

local function findKey(set, name)
  if set[name] then return name end
  local lower = name:lower()
  for key in pairs(set) do
    if key:lower() == lower then return key end
  end
  return nil
end

local function isOwnFrame(frame)
  local Tray = MBT.Tray
  return frame == Tray.main or frame == Tray.container
end

-- ---------------------------------------------------------------------------
-- rules
-- ---------------------------------------------------------------------------

-- Why a frame would not be collected, or nil when it can be.
-- source: "scan" (found by name on the minimap), "include" (named by the
-- player), "library" (handed over by LibDBIcon / LibMapButton). Only a scan is
-- judged by its name and size. label: what to call a frame without a global name.
function Collector.Reject(frame, source, label)
  if not isFrame(frame) then return "not a frame" end
  if flag(frame, "IsForbidden") then return "forbidden" end
  if isOwnFrame(frame) then return "own frame" end
  if recordByFrame[frame] then return "collected" end

  local name = Collector.NameOf(frame) or label
  if not name then return "no name" end
  if findKey(MBT.db.ignore, name) then return "ignored" end

  -- A protected frame cannot be moved in combat, and a tray holding one
  -- could not be opened in combat either.
  if flag(frame, "IsProtected") then return "protected" end

  if source ~= "scan" then return nil end

  if isBlizzardGlobal(name) then return "Blizzard" end
  local lower = name:lower()
  if matchesAny(lower, PIN_PATTERNS) then return "map pin" end
  if lower:find("%d$") and not matchesAny(lower, NUMBERED_OK_PATTERNS) then return "map pin" end
  if not matchesAny(lower, BUTTON_PATTERNS) then return "name" end

  local width = Client.ReadNumber(frame:GetWidth())
  local height = Client.ReadNumber(frame:GetHeight())
  if (width and width > MAX_BUTTON_SIZE) or (height and height > MAX_BUTTON_SIZE) then return "too big" end
  return nil
end

-- ---------------------------------------------------------------------------
-- hooks
-- ---------------------------------------------------------------------------

-- An addon hiding its button (a "hide minimap icon" option) must not leave a
-- hole in the grid. Show/Hide are hooked on the frame itself, so the hook only
-- runs when the addon calls them, not when the tray opens or closes.
local function onVisibilityChanged(frame)
  local record = recordByFrame[frame]
  if not record then return end
  local shown = frame:IsShown() and true or false
  if record.shown ~= shown then
    record.shown = shown
    MBT.Tray.Refresh()
  end
end

local function hookVisibilityOnce(frame)
  if hookedFrames[frame] or not Client.hasSecureHooks then return end
  hookedFrames[frame] = true
  for _, method in ipairs({ "Show", "Hide", "SetShown" }) do
    if type(frame[method]) == "function" then pcall(hooksecurefunc, frame, method, onVisibilityChanged) end
  end
end

-- Fade guard. Addons fade their button two ways: calling SetAlpha over time
-- (UIFrameFadeOut and friends; blocked by the SetAlpha no-op installed in
-- Grab) and playing an AnimationGroup holding an Alpha animation (LibDBIcon's
-- showOnMouseover); those are stopped here and re-stopped whenever their owner
-- plays them while we hold the frame.
local function alphaGroupsOf(frame)
  local groups = {}
  if type(frame.GetAnimationGroups) ~= "function" then return groups end
  local ok, list = pcall(function() return { frame:GetAnimationGroups() } end)
  if not ok then return groups end
  for _, group in ipairs(list) do
    local okAnims, anims = pcall(function() return { group:GetAnimations() } end)
    if okAnims then
      for _, anim in ipairs(anims) do
        local okType, isAlpha = pcall(anim.IsObjectType, anim, "Alpha")
        if okType and isAlpha then
          groups[#groups + 1] = group
          break
        end
      end
    end
  end
  return groups
end

local function onFadeGroupPlay(group)
  local frame = group:GetParent()
  if frame and recordByFrame[frame] then
    pcall(group.Stop, group)
    Original.SetAlpha(frame, 1)
  end
end

local function guardFades(frame)
  for _, group in ipairs(alphaGroupsOf(frame)) do
    pcall(group.Stop, group)
    if not guardedGroups[group] and type(group.HookScript) == "function" then
      guardedGroups[group] = true
      pcall(group.HookScript, group, "OnPlay", onFadeGroupPlay)
    end
  end
  Original.SetAlpha(frame, 1)
end

-- Called from the tray layout: a cheap belt-and-braces against anything the
-- guards above did not see (a group created after Grab, for example).
function Collector.EnforceAlpha(frame)
  if not recordByFrame[frame] then return end
  local alpha = Client.ReadNumber(frame:GetAlpha())
  if alpha ~= 1 then guardFades(frame) end
end

-- ---------------------------------------------------------------------------
-- take and give back
-- ---------------------------------------------------------------------------
local function sortButtons()
  table.sort(Collector.buttons, function(a, b)
    return recordByFrame[a].name:lower() < recordByFrame[b].name:lower()
  end)
end

-- LibDBIcon pins its buttons to MEDIUM strata and level 8 (SetFixedFrameStrata,
-- SetFixedFrameLevel), where the tray drawn above would darken them and take
-- their clicks. Unpin, move, then pin again as the button was.
local function restack(frame, strata, level, fixedStrata, fixedLevel)
  if Client.hasFixedStrata then
    call(frame, "SetFixedFrameStrata", false)
    call(frame, "SetFixedFrameLevel", false)
  end
  if strata then call(frame, "SetFrameStrata", strata) end
  if level then call(frame, "SetFrameLevel", level) end
  if Client.hasFixedStrata then
    if fixedStrata then call(frame, "SetFixedFrameStrata", true) end
    if fixedLevel then call(frame, "SetFixedFrameLevel", true) end
  end
end

function Collector.Grab(frame, label)
  local container = MBT.Tray.container
  local record = {
    name = Collector.NameOf(frame) or label,
    parent = frame:GetParent(),
    strata = frame:GetFrameStrata(),
    level = Client.ReadNumber(frame:GetFrameLevel()),
    fixedStrata = Client.hasFixedStrata and flag(frame, "IsFixedFrameStrata") or false,
    fixedLevel = Client.hasFixedStrata and flag(frame, "IsFixedFrameLevel") or false,
    scale = Client.ReadNumber(frame:GetScale()),
    alpha = Client.ReadNumber(frame:GetAlpha()),
    points = {},
    previousMethods = {},
    dragStart = scriptOf(frame, "OnDragStart"),
    dragStop = scriptOf(frame, "OnDragStop"),
  }
  local count = Client.ReadNumber(frame:GetNumPoints()) or 0
  for index = 1, count do record.points[index] = { frame:GetPoint(index) } end

  Original.SetParent(frame, container)
  Original.ClearAllPoints(frame)
  local trayLevel = Client.ReadNumber(container:GetFrameLevel()) or 1
  restack(frame, container:GetFrameStrata(), trayLevel + 2, record.fixedStrata, record.fixedLevel)
  if Client.hasIgnoreParentScale then pcall(frame.SetIgnoreParentScale, frame, false) end
  Original.SetScale(frame, MBT.db.buttonScale)
  -- Dragging would move the button around the minimap ring.
  pcall(frame.SetScript, frame, "OnDragStart", nil)
  pcall(frame.SetScript, frame, "OnDragStop", nil)

  for _, method in ipairs(LOCKED_METHODS) do
    record.previousMethods[method] = rawget(frame, method)
    rawset(frame, method, noop)
  end
  guardFades(frame)

  hookVisibilityOnce(frame)
  record.shown = frame:IsShown() and true or false
  recordByFrame[frame] = record
  Collector.buttons[#Collector.buttons + 1] = frame
end

-- Puts a button back exactly where its addon left it.
function Collector.Release(frame)
  local record = recordByFrame[frame]
  if not record then return false end
  recordByFrame[frame] = nil
  for index, button in ipairs(Collector.buttons) do
    if button == frame then
      table.remove(Collector.buttons, index)
      break
    end
  end

  for _, method in ipairs(LOCKED_METHODS) do rawset(frame, method, record.previousMethods[method]) end

  Original.SetParent(frame, record.parent)
  Original.ClearAllPoints(frame)
  for _, point in ipairs(record.points) do pcall(Original.SetPoint, frame, unpack(point)) end
  Original.SetScale(frame, record.scale or 1)
  Original.SetAlpha(frame, record.alpha or 1)
  restack(frame, record.strata, record.level, record.fixedStrata, record.fixedLevel)
  pcall(frame.SetScript, frame, "OnDragStart", record.dragStart)
  pcall(frame.SetScript, frame, "OnDragStop", record.dragStop)
  return true
end

function Collector.IsCollected(frame)
  return recordByFrame[frame] ~= nil
end

-- The name a collected button is listed and ignored under.
function Collector.LabelOf(frame)
  local record = recordByFrame[frame]
  return record and record.name
end

function Collector.Find(name)
  local lower = name:lower()
  for _, frame in ipairs(Collector.buttons) do
    if recordByFrame[frame].name:lower() == lower then return frame end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- sources
-- ---------------------------------------------------------------------------
local function getLibrary(name)
  local LibStub = _G.LibStub
  if type(LibStub) ~= "table" or type(LibStub.GetLibrary) ~= "function" then return nil end
  local ok, lib = pcall(LibStub.GetLibrary, LibStub, name, true)
  if ok and type(lib) == "table" then return lib end
  return nil
end

function Collector.GetLibDBIcon() return getLibrary("LibDBIcon-1.0") end

local function libraryButtons()
  local found = {}
  local dbicon = Collector.GetLibDBIcon()
  if dbicon and type(dbicon.GetButtonList) == "function" and type(dbicon.GetMinimapButton) == "function" then
    local ok, names = pcall(dbicon.GetButtonList, dbicon)
    if ok and type(names) == "table" then
      for _, name in ipairs(names) do
        local okButton, frame = pcall(dbicon.GetMinimapButton, dbicon, name)
        if okButton and frame then found[#found + 1] = { frame = frame, label = "LibDBIcon10_" .. tostring(name) } end
      end
    end
  end
  local mapButton = getLibrary("LibMapButton-1.1")
  if mapButton and type(mapButton.buttons) == "table" then
    for name, frame in pairs(mapButton.buttons) do
      found[#found + 1] = { frame = frame, label = "LibMapButton_" .. tostring(name) }
    end
  end
  return found
end

-- "Frame" or "Frame.child.child", as /mbt add takes it.
function Collector.Resolve(path)
  local current = _G
  for part in path:gmatch("[^%.]+") do
    if type(current) ~= "table" then return nil end
    current = rawget(current, part) or current[part]
  end
  if current == _G or not isFrame(current) then return nil end
  return current
end

local function hinted(key)
  for _, hint in ipairs(NAME_HINTS) do
    if key:find(hint) then return true end
  end
  return false
end

local function parentOf(value)
  if not isFrame(value) then return nil end
  return value:GetParent()
end

-- Named frames sitting directly on a minimap frame: { frame =, parent = name }.
local function namedMinimapChildren()
  local parents = {}
  for _, name in ipairs(Client.minimapParents) do
    local parent = _G[name]
    if isFrame(parent) then parents[parent] = name end
  end
  Collector.nameScans = Collector.nameScans + 1

  local found, seen = {}, {}
  for key, value in pairs(_G) do
    if type(key) == "string" and type(value) == "table" and not seen[value] and hinted(key) then
      seen[value] = true
      local ok, parent = pcall(parentOf, value)
      local where = ok and parent and parents[parent]
      if where then found[#found + 1] = { frame = value, parent = where } end
    end
  end
  return found
end

-- Collects everything that should be. Returns how many buttons were added.
-- throttled: the name scan runs at most every NAME_SCAN_INTERVAL seconds (the
-- tray opening); events and /mbt rescan always search.
function Collector.Scan(throttled)
  if not MBT.Tray.container then return 0 end
  if InCombatLockdown and InCombatLockdown() then
    -- Nothing we take is protected, but a frame half way through its addon's
    -- setup is better left alone until the fight ends.
    Collector.pending = true
    return 0
  end
  Collector.pending = false

  local before = #Collector.buttons
  -- One odd frame must not stop the others, nor be retried on every scan.
  local function try(frame, source, label)
    if failedFrames[frame] or Collector.Reject(frame, source, label) then return end
    local ok, err = pcall(Collector.Grab, frame, label)
    if not ok then
      failedFrames[frame] = true
      Collector.lastError = (Collector.NameOf(frame) or label or "?") .. ": " .. tostring(err)
    end
  end

  for _, entry in ipairs(libraryButtons()) do try(entry.frame, "library", entry.label) end
  for path in pairs(MBT.db.include) do
    local frame = Collector.Resolve(path)
    if frame then try(frame, "include", path) end
  end
  local now = GetTime and GetTime() or 0
  if not throttled or not Collector.nameScanAt or now - Collector.nameScanAt >= NAME_SCAN_INTERVAL then
    Collector.nameScanAt = now
    for _, entry in ipairs(namedMinimapChildren()) do try(entry.frame, "scan") end
  end

  local added = #Collector.buttons - before
  if added > 0 then
    sortButtons()
    MBT.Tray.Refresh()
  end
  return added
end

-- LibDBIcon announces the buttons it creates after login.
function Collector.HookLibDBIcon()
  local lib = Collector.GetLibDBIcon()
  if not lib or Collector.libHooked or type(lib.RegisterCallback) ~= "function" then return end
  local ok = pcall(lib.RegisterCallback, ADDON_NAME, "LibDBIcon_IconCreated", function() MBT.QueueRescan(0) end)
  Collector.libHooked = ok
end

-- ---------------------------------------------------------------------------
-- player lists
-- ---------------------------------------------------------------------------

-- Returns the name as stored (the frame's own spelling when it is collected).
function Collector.Ignore(name)
  local frame = Collector.Find(name)
  local key = (frame and recordByFrame[frame].name) or findKey(MBT.db.ignore, name) or name
  -- Left in the hand-picked list if it is there: ignoring wins, and
  -- unignoring brings it back through that list.
  MBT.db.ignore[key] = true
  if frame then
    Collector.Release(frame)
    MBT.Tray.Refresh()
  end
  return key
end

function Collector.Unignore(name)
  local key = findKey(MBT.db.ignore, name)
  if not key then return nil end
  MBT.db.ignore[key] = nil
  Collector.Scan()
  return key
end

-- true when the frame exists right now (it is then collected at once).
function Collector.Include(path)
  local ignored = findKey(MBT.db.ignore, path)
  if ignored then MBT.db.ignore[ignored] = nil end
  MBT.db.include[path] = true
  Collector.Scan()
  return Collector.Resolve(path) ~= nil
end

function Collector.Uninclude(path)
  local key = findKey(MBT.db.include, path)
  if not key then return nil end
  MBT.db.include[key] = nil
  -- Give it back, then let the normal rules take it again if they would.
  local frame = Collector.Resolve(key)
  if frame and Collector.Release(frame) then MBT.Tray.Refresh() end
  Collector.Scan()
  return key
end

-- ---------------------------------------------------------------------------
-- debug
-- ---------------------------------------------------------------------------
function Collector.Describe()
  local lines = {}
  for _, frame in ipairs(Collector.buttons) do
    local alpha = Client.ReadNumber(frame:GetAlpha())
    lines[#lines + 1] = "|cff00ff00collected|r " .. recordByFrame[frame].name
      .. (frame:IsShown() and "" or " (hidden by its addon)")
      .. ((alpha and alpha < 1) and (" |cffff6666alpha " .. alpha .. "|r") or "")
  end
  for _, entry in ipairs(namedMinimapChildren()) do
    if not recordByFrame[entry.frame] then
      lines[#lines + 1] = ("|cff999999skipped|r %s (%s, in %s)"):format(
        Collector.NameOf(entry.frame) or "?", Collector.Reject(entry.frame, "scan") or "?", entry.parent)
    end
  end
  -- A count is one number: safe to ask, unlike the children themselves.
  local counts = {}
  for _, parentName in ipairs(Client.minimapParents) do
    local parent = _G[parentName]
    if isFrame(parent) and type(parent.GetNumChildren) == "function" then
      local ok, count = pcall(parent.GetNumChildren, parent)
      count = ok and Client.ReadNumber(count)
      if count then counts[#counts + 1] = parentName .. " " .. count end
    end
  end
  if #counts > 0 then lines[#lines + 1] = "children (map pins included): " .. table.concat(counts, ", ") end
  if Collector.lastError then lines[#lines + 1] = "|cffff6666last error|r " .. Collector.lastError end
  return lines
end
