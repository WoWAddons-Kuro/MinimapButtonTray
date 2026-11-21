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
local guardedGroups = {}      -- [animationGroup] = { play =, restart = } original methods while locked
local failedFrames = {}       -- [frame] = true when Grab raised; never retried

-- The real widget methods, taken from a frame nobody touches. Collected
-- buttons get their own copies replaced by no-ops, so the tray goes around them.
local Original = {}
local LOCKED_METHODS = { "SetPoint", "ClearAllPoints", "SetParent", "SetScale", "SetAllPoints", "SetAlpha" }
for _, method in ipairs(LOCKED_METHODS) do Original[method] = UIParent[method] end
Original.SetScript = UIParent.SetScript   -- wrapped (not no-op'd) on held frames, see Grab
Original.Show, Original.Hide = UIParent.Show, UIParent.Hide   -- wrapped on held frames, see Grab
Collector.Original = Original

-- Click handlers that are wrapped on a held frame so Alt-clicks (the reorder
-- modifier) never reach the addon.
local CLICK_SCRIPTS = { "OnClick", "OnMouseDown", "OnMouseUp", "OnDoubleClick" }

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
-- showOnMouseover); those are stopped and locked while we hold the frame.
-- Groups on the frame's regions and child frames count too: some addons
-- animate the icon texture rather than the button.
local function collectAlphaGroups(owner, groups)
  if type(owner) ~= "table" or type(owner.GetAnimationGroups) ~= "function" then return end
  local ok, list = pcall(function() return { owner:GetAnimationGroups() } end)
  if not ok then return end
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
end

local function alphaGroupsOf(frame)
  local groups = {}
  collectAlphaGroups(frame, groups)
  if type(frame.GetRegions) == "function" then
    local ok, regions = pcall(function() return { frame:GetRegions() } end)
    if ok then for _, region in ipairs(regions) do collectAlphaGroups(region, groups) end end
  end
  if type(frame.GetChildren) == "function" then
    local ok, children = pcall(function() return { frame:GetChildren() } end)
    if ok then for _, child in ipairs(children) do collectAlphaGroups(child, groups) end end
  end
  return groups
end

-- Stops every alpha animation on the frame and locks its Play/Restart with
-- no-ops: an OnPlay hook would run after the animation had started and show
-- a frame or two of fade. Newly locked groups are remembered on the record so
-- Release can unlock them.
local function guardFades(frame, record)
  for _, group in ipairs(alphaGroupsOf(frame)) do
    pcall(group.Stop, group)
    if not guardedGroups[group] then
      guardedGroups[group] = { play = rawget(group, "Play"), restart = rawget(group, "Restart") }
      rawset(group, "Play", noop)
      rawset(group, "Restart", noop)
      record.lockedGroups[#record.lockedGroups + 1] = group
    end
  end
  Original.SetAlpha(frame, 1)
end

local function unguardFades(record)
  for _, group in ipairs(record.lockedGroups) do
    local saved = guardedGroups[group]
    if saved then
      rawset(group, "Play", saved.play)
      rawset(group, "Restart", saved.restart)
      guardedGroups[group] = nil
    end
  end
end

-- Called from the tray layout: a cheap belt-and-braces against anything the
-- guards above did not see (a group created after Grab, for example).
function Collector.EnforceAlpha(frame)
  local record = recordByFrame[frame]
  if not record then return end
  -- The tray dims the button it is Alt-dragging; that alpha is the tray's.
  if MBT.Tray.DraggedButton and MBT.Tray.DraggedButton() == frame then return end
  local alpha = Client.ReadNumber(frame:GetAlpha())
  if alpha ~= 1 then guardFades(frame, record) end
end

function Collector.EnforceAllAlpha()
  for _, frame in ipairs(Collector.buttons) do Collector.EnforceAlpha(frame) end
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
    lockedGroups = {},
    dragStart = scriptOf(frame, "OnDragStart"),
    dragStop = scriptOf(frame, "OnDragStop"),
    clickScripts = {},         -- [which] = the addon's handler, run unless Alt is held
    addonShown = frame:IsShown() and true or false,   -- what the addon wants; we may override (db.showHidden)
  }
  local count = Client.ReadNumber(frame:GetNumPoints()) or 0
  for index = 1, count do record.points[index] = { frame:GetPoint(index) } end

  Original.SetParent(frame, container)
  Original.ClearAllPoints(frame)
  local trayLevel = Client.ReadNumber(container:GetFrameLevel()) or 1
  restack(frame, container:GetFrameStrata(), trayLevel + 2, record.fixedStrata, record.fixedLevel)
  if Client.hasIgnoreParentScale then pcall(frame.SetIgnoreParentScale, frame, false) end
  Original.SetScale(frame, MBT.db.buttonScale)
  -- The addon's own drag handlers would move the button around the minimap
  -- ring; ours only act on an Alt-drag (reorder / pin inside the tray).
  pcall(Original.SetScript, frame, "OnDragStart", MBT.Tray.OnButtonDragStart)
  pcall(Original.SetScript, frame, "OnDragStop", MBT.Tray.OnButtonDragStop)
  -- Addons (LibDBIcon:Refresh, :Unlock, lock toggles) re-set their drag
  -- handlers at any time. While held, SetScript on the frame keeps ours in
  -- place and remembers theirs so Release restores the latest.
  record.previousMethods.SetScript = rawget(frame, "SetScript")
  rawset(frame, "SetScript", function(self, which, handler, ...)
    if which == "OnDragStart" then
      record.dragStart, handler = handler, MBT.Tray.OnButtonDragStart
    elseif which == "OnDragStop" then
      record.dragStop, handler = handler, MBT.Tray.OnButtonDragStop
    end
    return Original.SetScript(self, which, handler, ...)
  end)
  -- A button that never registered for drag (some hand-rolled ones) gets it
  -- now; there is no getter to read the previous registration, so Release
  -- leaves LeftButton registered - harmless with its own handlers restored.
  if type(frame.RegisterForDrag) == "function" then
    pcall(frame.RegisterForDrag, frame, "LeftButton")
  end
  -- Alt is the reorder/pin modifier. While it is held, every click on a held
  -- button is ours: the addon's handler never runs (many addons bind a
  -- modified click to "hide my minimap icon", which is exactly what a short
  -- drag used to trigger).
  for _, which in ipairs(CLICK_SCRIPTS) do
    local handler = scriptOf(frame, which)
    if handler then
      record.clickScripts[which] = handler
      pcall(Original.SetScript, frame, which, function(self, ...)
        if IsAltKeyDown() then return end
        return handler(self, ...)
      end)
    end
  end
  -- The addon's own Show/Hide still decide visibility, unless db.showHidden
  -- forces hidden buttons to show. Record the addon's wish via the secure
  -- hooks (onVisibilityChanged) and re-apply ours afterwards.
  -- Hook the real methods first (hooks cannot be removed and must not wrap
  -- the per-grab closures below), then install the wrappers.
  hookVisibilityOnce(frame)
  record.previousMethods.Show = rawget(frame, "Show")
  record.previousMethods.Hide = rawget(frame, "Hide")
  record.previousMethods.SetShown = rawget(frame, "SetShown")
  rawset(frame, "Show", function(self) record.addonShown = true; Original.Show(self); onVisibilityChanged(self) end)
  rawset(frame, "Hide", function(self) record.addonShown = false; if not MBT.db.showHidden then Original.Hide(self) end; onVisibilityChanged(self) end)
  rawset(frame, "SetShown", function(self, shown) if shown then self:Show() else self:Hide() end end)

  for _, method in ipairs(LOCKED_METHODS) do
    record.previousMethods[method] = rawget(frame, method)
    rawset(frame, method, noop)
  end
  guardFades(frame, record)

  hookVisibilityOnce(frame)
  record.shown = frame:IsShown() and true or false
  recordByFrame[frame] = record
  Collector.buttons[#Collector.buttons + 1] = frame
  if MBT.db.showHidden and not record.addonShown then Original.Show(frame) end
end

-- db.showHidden: a button its addon has hidden is shown in the tray anyway
-- (the addon's "hide my minimap icon" is usually a hide-from-the-ring option,
-- which the tray makes moot). Off: back to what each addon wants.
function Collector.ApplyShowHidden()
  for _, frame in ipairs(Collector.buttons) do
    local record = recordByFrame[frame]
    if not record.addonShown then
      if MBT.db.showHidden then Original.Show(frame) else Original.Hide(frame) end
    end
  end
  MBT.Tray.Refresh()
end

-- true when the addon itself has hidden the button (whatever the tray shows).
function Collector.HiddenByAddon(frame)
  local record = recordByFrame[frame]
  return record ~= nil and not record.addonShown
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
  for _, method in ipairs({ "Show", "Hide", "SetShown" }) do rawset(frame, method, record.previousMethods[method]) end
  unguardFades(record)

  Original.SetParent(frame, record.parent)
  Original.ClearAllPoints(frame)
  for _, point in ipairs(record.points) do pcall(Original.SetPoint, frame, unpack(point)) end
  Original.SetScale(frame, record.scale or 1)
  Original.SetAlpha(frame, record.alpha or 1)
  restack(frame, record.strata, record.level, record.fixedStrata, record.fixedLevel)
  pcall(frame.SetScript, frame, "OnDragStart", record.dragStart)
  pcall(frame.SetScript, frame, "OnDragStop", record.dragStop)
  for which, handler in pairs(record.clickScripts) do pcall(Original.SetScript, frame, which, handler) end
  -- Back to what the addon wanted, in case showHidden had it forced on.
  if record.addonShown then Original.Show(frame) else Original.Hide(frame) end
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
-- grid order and pins (Alt-drag in the tray)
-- ---------------------------------------------------------------------------
local function indexIn(list, name)
  for index, entry in ipairs(list) do
    if entry == name then return index end
  end
  return nil
end

local function removeFrom(list, name)
  local index = indexIn(list, name)
  if index then table.remove(list, index) end
  return index
end

function Collector.IsPinned(frame)
  local record = recordByFrame[frame]
  return record ~= nil and indexIn(MBT.db.pinned, record.name) ~= nil
end

-- Collected pinned buttons in db.pinned order. Each frame appears once; a
-- name listed twice, or two frames sharing a name, cannot drop one of them.
function Collector.PinnedButtons()
  local result, placed = {}, {}
  for _, name in ipairs(MBT.db.pinned) do
    for _, frame in ipairs(Collector.buttons) do
      if not placed[frame] and recordByFrame[frame].name == name then
        placed[frame] = true
        result[#result + 1] = frame
      end
    end
  end
  return result
end

-- Everything collected that is not a pinned row, in grid order: db.order
-- first, then the rest alphabetically. Defined as the complement of
-- PinnedButtons so no collected button can be in neither list.
function Collector.GridButtons()
  local pinned, placed, result = {}, {}, {}
  for _, frame in ipairs(Collector.PinnedButtons()) do pinned[frame] = true end
  for _, name in ipairs(MBT.db.order) do
    for _, frame in ipairs(Collector.buttons) do
      if not pinned[frame] and not placed[frame] and recordByFrame[frame].name == name then
        placed[frame] = true
        result[#result + 1] = frame
      end
    end
  end
  for _, frame in ipairs(Collector.buttons) do   -- already sorted by name
    if not pinned[frame] and not placed[frame] then result[#result + 1] = frame end
  end
  return result
end

-- Keeps a name list free of duplicates (first occurrence wins).
local function dedupe(list)
  local seen, index = {}, 1
  while index <= #list do
    if seen[list[index]] then table.remove(list, index) else seen[list[index]] = true; index = index + 1 end
  end
end

-- Puts the button at gridIndex of the grid (1-based; nil = last), unpinning
-- it if needed. db.order is rewritten as the whole resulting grid so buttons
-- collected later sort after it.
function Collector.MoveToGrid(frame, gridIndex)
  local record = recordByFrame[frame]
  if not record then return end
  while removeFrom(MBT.db.pinned, record.name) do end
  local grid = Collector.GridButtons()
  for index, other in ipairs(grid) do
    if other == frame then table.remove(grid, index) break end
  end
  table.insert(grid, MBT.Clamp(gridIndex or (#grid + 1), 1, #grid + 1), frame)
  local order = {}
  for index, other in ipairs(grid) do order[index] = recordByFrame[other].name end
  MBT.db.order = order
  dedupe(MBT.db.order)
  MBT.Tray.Refresh()
end

-- Pins the button at pinIndex of db.pinned (1-based; nil = last).
function Collector.MoveToPinned(frame, pinIndex)
  local record = recordByFrame[frame]
  if not record then return end
  while removeFrom(MBT.db.pinned, record.name) do end
  while removeFrom(MBT.db.order, record.name) do end
  table.insert(MBT.db.pinned, MBT.Clamp(pinIndex or (#MBT.db.pinned + 1), 1, #MBT.db.pinned + 1), record.name)
  dedupe(MBT.db.pinned)
  MBT.Tray.Refresh()
end

-- Run at login: the two name lists must be arrays of unique strings with no
-- name in both. Anything else is dropped (the button then simply sorts
-- alphabetically in the grid, which is never lost).
function Collector.SanitiseLists()
  local db = MBT.db
  for _, key in ipairs({ "order", "pinned" }) do
    local clean = {}
    for _, name in ipairs(db[key]) do if type(name) == "string" then clean[#clean + 1] = name end end
    db[key] = clean
    dedupe(db[key])
  end
  for _, name in ipairs(db.pinned) do while removeFrom(db.order, name) do end end
end

-- Human label for a frame name: library prefixes and the usual button
-- suffixes removed, CamelCase split. "LibDBIcon10_GotJunk" -> "GotJunk",
-- "ChatSyncMinimapButton" -> "Chat Sync".
function Collector.DisplayName(name)
  local label = name:gsub("^LibDBIcon10_", ""):gsub("^LibMapButton_", "")
  label = label:gsub("[-_]?[Mm]inimap[-_]?[Bb]utton$", ""):gsub("[-_]?[Mm]inimap[-_]?[Ii]con$", "")
  label = label:gsub("[-_]?[Mm]inimap$", ""):gsub("[-_]?[Bb]utton$", "")
  if label == "" then label = name end
  label = label:gsub("(%l)(%u)", "%1 %2"):gsub("[-_]+", " ")
  return label
end

-- First texture file on the frame or its direct children, for the drag ghost.
function Collector.IconOf(frame)
  local function textureOf(owner)
    if type(owner.GetRegions) ~= "function" then return nil end
    local ok, regions = pcall(function() return { owner:GetRegions() } end)
    if not ok then return nil end
    for _, region in ipairs(regions) do
      if type(region.GetTexture) == "function" and type(region.IsObjectType) == "function"
        and region:IsObjectType("Texture") then
        local okTex, texture = pcall(region.GetTexture, region)
        if okTex and texture and texture ~= "" and not Client.IsSecret(texture) then return texture end
      end
    end
    return nil
  end
  local texture = textureOf(frame)
  if texture then return texture end
  if type(frame.GetChildren) == "function" then
    local ok, children = pcall(function() return { frame:GetChildren() } end)
    if ok then
      for _, child in ipairs(children) do
        texture = textureOf(child)
        if texture then return texture end
      end
    end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- debug
-- ---------------------------------------------------------------------------
function Collector.Describe()
  local lines = {}
  for _, frame in ipairs(Collector.buttons) do
    local alpha = Client.ReadNumber(frame:GetAlpha())
    -- Drag diagnostics: whose OnDragStart is on the frame right now (ours is
    -- needed for Alt-drag), and does it take the mouse at all.
    local dragHandler = scriptOf(frame, "OnDragStart")
    local dragState = dragHandler == MBT.Tray.OnButtonDragStart and "drag ours"
      or (dragHandler and "|cffff6666drag theirs|r") or "|cffff6666drag none|r"
    local mouse = flag(frame, "IsMouseEnabled") and "" or ", |cffff6666mouse off|r"
    lines[#lines + 1] = "|cff00ff00collected|r " .. recordByFrame[frame].name
      .. (Collector.HiddenByAddon(frame) and (MBT.db.showHidden and " (hidden by its addon, shown anyway)" or " (hidden by its addon)") or "")
      .. ((alpha and alpha < 1) and (" |cffff6666alpha " .. alpha .. "|r") or "")
      .. "  [" .. dragState .. mouse .. "]"
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
