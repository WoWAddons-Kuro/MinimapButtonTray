-- MinimapButtonTray: the main button and the tray that opens next to it. The
-- tray holds a grid of collected buttons and, under it, an optional list of
-- pinned buttons shown as [button] [name] rows. Shift-drag a button to
-- reorder the grid or move it between the grid and the pinned list.
local ADDON_NAME, MBT = ...
local Client = MBT.Client

local Tray = {}
MBT.Tray = Tray

local MAIN_SIZE = 30         -- main button
local PADDING = 4            -- inside the tray
local SPACING = 2            -- between two buttons
local GAP = 2                -- between the main button and the tray
local SECTION_GAP = 6        -- between the grid and the pinned list
local DEFAULT_CELL = 32
local MAX_CELL = 64
local PIN_LABEL_GAP = 6      -- between a pinned button and its label
local PIN_MIN_LABEL = 90     -- so the drop zone is wide enough to hit when empty
local POLL_INTERVAL = 0.1
local DRAG_ALPHA = 0.4       -- the button being dragged
local ICON_PATH = "Interface\\AddOns\\" .. ADDON_NAME .. "\\Media\\MinimapButtonTray"

local BACKGROUND = { 0.05, 0.05, 0.06, 0.92 }
local BORDER = { 0.25, 0.45, 0.55, 1 }
local BORDER_OPEN = { 0.40, 0.80, 1, 1 }
local DROP_HINT = { 0.40, 0.80, 1, 0.35 }
local PIN_ZONE = { 0.40, 0.80, 1, 0.10 }

-- Where the tray sits against the main button, per direction.
local TRAY_ANCHORS = {
  leftdown = { "TOPRIGHT", "TOPLEFT", -GAP, 0 },
  leftup = { "BOTTOMRIGHT", "BOTTOMLEFT", -GAP, 0 },
  rightdown = { "TOPLEFT", "TOPRIGHT", GAP, 0 },
  rightup = { "BOTTOMLEFT", "BOTTOMRIGHT", GAP, 0 },
  downleft = { "TOPRIGHT", "BOTTOMRIGHT", 0, -GAP },
  downright = { "TOPLEFT", "BOTTOMLEFT", 0, -GAP },
  upleft = { "BOTTOMRIGHT", "TOPRIGHT", 0, GAP },
  upright = { "BOTTOMLEFT", "TOPLEFT", 0, GAP },
}

local main, container, emptyLabel
local mainBorders = {}
local compartmentHooked, compartmentHidden = false, false

-- Pinned section widgets, created on demand.
local pinZone                -- frame under the grid; visible when pins exist or a drag is on
local pinZoneLabel           -- "drop here to pin" while empty
local pinLabels = {}         -- FontStrings, one per pinned row, reused

-- Drag state.
local drag = {
  frame = nil,               -- the collected button being dragged
  ghost = nil,               -- cursor-following frame with the icon copy
  slots = {},                -- { kind = "grid"|"pin", index =, left, right, top, bottom } in tray coords
  hint = nil,                -- texture highlighting the slot under the cursor
}

-- Geometry of the last layout, for hit tests during a drag.
local layoutInfo = { cellWidth = DEFAULT_CELL, cellHeight = DEFAULT_CELL, gridCount = 0, pinCount = 0 }

-- ---------------------------------------------------------------------------
-- drawing
-- ---------------------------------------------------------------------------
local function paint(texture, color)
  texture:SetColorTexture(color[1], color[2], color[3], color[4])
end

-- Flat background plus a 1px border; returns the border textures.
-- Flat background plus a 1px border; returns the border textures. The main
-- button passes noBackground: only its icon shows, the border is hover-only.
local function frameBox(frame, noBackground)
  if not noBackground then
    local background = frame:CreateTexture(nil, "BACKGROUND")
    paint(background, BACKGROUND)
    background:SetAllPoints()
  end
  local borders = {}
  for _, edge in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
    local line = frame:CreateTexture(nil, "BORDER")
    paint(line, BORDER)
    if edge == "TOP" or edge == "BOTTOM" then
      line:SetHeight(1)
      line:SetPoint(edge .. "LEFT")
      line:SetPoint(edge .. "RIGHT")
    else
      line:SetWidth(1)
      line:SetPoint("TOP" .. edge)
      line:SetPoint("BOTTOM" .. edge)
    end
    borders[#borders + 1] = line
  end
  return borders
end

local function paintMainBorder()
  local open = container and container:IsShown()
  -- No border at rest: the icon stands on its own. Blue while hovered or
  -- while the tray is open, as the "this is the active thing" cue.
  local show = open or (main and main.hover)
  for _, line in ipairs(mainBorders) do line:SetShown(show and true or false); if show then paint(line, BORDER_OPEN) end end
end

-- ---------------------------------------------------------------------------
-- position: offset of the main button centre from the minimap centre, in
-- UIParent units, so it follows the minimap when that moves and stays put
-- when either is rescaled.
-- ---------------------------------------------------------------------------
local function scales()
  local button = Client.ReadNumber(main:GetEffectiveScale()) or 1
  local minimap = Minimap and Client.ReadNumber(Minimap:GetEffectiveScale()) or 1
  local ui = Client.ReadNumber(UIParent:GetEffectiveScale()) or 1
  if button <= 0 then button = 1 end
  if minimap <= 0 then minimap = 1 end
  if ui <= 0 then ui = 1 end
  return button, minimap, ui
end

-- Bottom left of the minimap ring, where a minimap button would sit.
function Tray.DefaultPosition()
  local _, minimap, ui = scales()
  local width = Minimap and Client.ReadNumber(Minimap:GetWidth()) or 140
  local radius = width / 2 + 5
  local offset = -radius * 0.7071 * minimap / ui
  return offset, offset
end

function Tray.ApplyPosition()
  if not main then return end
  main:ClearAllPoints()
  if not Minimap then
    main:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    return
  end
  local x, y = MBT.db.posX, MBT.db.posY
  if not x or not y then x, y = Tray.DefaultPosition() end
  local button, _, ui = scales()
  main:SetPoint("CENTER", Minimap, "CENTER", x * ui / button, y * ui / button)
end

function Tray.SavePosition()
  if not main or not Minimap then return end
  local bx, by = main:GetCenter()
  local mx, my = Minimap:GetCenter()
  bx, by, mx, my = Client.ReadNumber(bx), Client.ReadNumber(by), Client.ReadNumber(mx), Client.ReadNumber(my)
  if not (bx and by and mx and my) then return end
  local button, minimap, ui = scales()
  MBT.db.posX = (bx * button - mx * minimap) / ui
  MBT.db.posY = (by * button - my * minimap) / ui
  Tray.ApplyPosition()
end

function Tray.ResetPosition()
  MBT.db.posX, MBT.db.posY = nil, nil
  Tray.ApplyPosition()
end

-- ---------------------------------------------------------------------------
-- layout
-- ---------------------------------------------------------------------------

-- Anchors a collected button's centre at (x, y) measured from the tray's
-- top-left corner, x rightwards, y downwards, in tray units.
local function placeButton(button, x, y)
  local Original = MBT.Collector.Original
  local scale = Client.ReadNumber(button:GetScale()) or 1
  if scale <= 0 then scale = 1 end
  Original.ClearAllPoints(button)
  Original.SetPoint(button, "CENTER", container, "TOPLEFT", x / scale, -y / scale)
end

local function ensurePinZone()
  if pinZone then return end
  pinZone = CreateFrame("Frame", nil, container)
  pinZone:EnableMouse(false)
  pinZone.background = pinZone:CreateTexture(nil, "BACKGROUND")
  paint(pinZone.background, PIN_ZONE)
  pinZone.background:SetAllPoints()
  pinZone.topLine = pinZone:CreateTexture(nil, "BORDER")
  paint(pinZone.topLine, BORDER)
  pinZone.topLine:SetHeight(1)
  pinZone.topLine:SetPoint("TOPLEFT")
  pinZone.topLine:SetPoint("TOPRIGHT")
  pinZoneLabel = pinZone:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  pinZoneLabel:SetPoint("CENTER")
  pinZoneLabel:SetText("drop here to pin")
  pinZoneLabel:SetTextColor(0.6, 0.8, 0.9, 0.8)
  pinZone:Hide()
end

local function pinLabel(index)
  local label = pinLabels[index]
  if not label then
    label = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    label:SetJustifyH("LEFT")
    pinLabels[index] = label
  end
  return label
end

-- Lays out the grid section and the pinned section, sizes the tray, and
-- records every drop slot for the drag hit test.
function Tray.Refresh()
  if not container then return end
  local db = MBT.db
  local Collector = MBT.Collector

  -- Visible buttons, cell size from the biggest of them.
  local grid, pinned = {}, {}
  local cellWidth, cellHeight = 0, 0
  local function measure(button)
    Collector.EnforceAlpha(button)
    if not button:IsShown() then return false end
    local scale = Client.ReadNumber(button:GetScale()) or 1
    local width, height = Client.ReadNumber(button:GetWidth()), Client.ReadNumber(button:GetHeight())
    if width and width * scale > cellWidth then cellWidth = width * scale end
    if height and height * scale > cellHeight then cellHeight = height * scale end
    return true
  end
  for _, button in ipairs(Collector.GridButtons()) do if measure(button) then grid[#grid + 1] = button end end
  for _, button in ipairs(Collector.PinnedButtons()) do if measure(button) then pinned[#pinned + 1] = button end end
  if cellWidth <= 0 then cellWidth = DEFAULT_CELL end
  if cellHeight <= 0 then cellHeight = DEFAULT_CELL end
  cellWidth, cellHeight = math.min(cellWidth, MAX_CELL), math.min(cellHeight, MAX_CELL)

  -- Direction: the configured one, flipped on either axis when the tray
  -- would run off the screen on that side (a button on the left edge opens
  -- rightwards; on the bottom edge, upwards). Sizes are estimated from the
  -- counts before layout; a SetClampedToScreen tray would otherwise slide
  -- back over the main button.
  local direction = db.direction
  do
    local uiScale = Client.ReadNumber(UIParent:GetEffectiveScale()) or 1
    local mainScale = Client.ReadNumber(main:GetEffectiveScale()) or 1
    local screenW = (Client.ReadNumber(GetScreenWidth and GetScreenWidth()) or 1920) * uiScale / mainScale
    local screenH = (Client.ReadNumber(GetScreenHeight and GetScreenHeight()) or 1080) * uiScale / mainScale
    local left, right = Client.ReadNumber(main:GetLeft()), Client.ReadNumber(main:GetRight())
    local bottom, top = Client.ReadNumber(main:GetBottom()), Client.ReadNumber(main:GetTop())
    if left and right and bottom and top then
      -- Rough footprint in tray units for the fit test.
      local total = #grid + (drag.frame and 1 or 0)
      local perRowEst = math.max(1, db.perRow)
      local alongN, acrossN = math.min(math.max(total, 1), perRowEst), math.max(1, math.ceil(math.max(total, 1) / perRowEst))
      local horiz = direction:find("^left") or direction:find("^right")
      local estW = PADDING * 2 + (horiz and alongN or acrossN) * (cellWidth + SPACING)
      local estH = PADDING * 2 + (horiz and acrossN or alongN) * (cellHeight + SPACING)
        + (#pinned > 0 and (#pinned * (cellHeight + SPACING) + SECTION_GAP) or 0)
      local function flipH(d) return (d:gsub("left", "\0"):gsub("right", "left"):gsub("%z", "right")) end
      local function flipV(d) return (d:gsub("down", "\0"):gsub("up", "down"):gsub("%z", "up")) end
      -- Horizontal side the tray extends towards, and whether it fits.
      local towardsLeft = direction:find("left") ~= nil
      if towardsLeft and left - GAP - estW < 0 and right + GAP + estW <= screenW then direction = flipH(direction)
      elseif not towardsLeft and right + GAP + estW > screenW and left - GAP - estW >= 0 then direction = flipH(direction) end
      local towardsDown = direction:find("down") ~= nil
      if towardsDown and bottom - GAP - estH < 0 and top + GAP + estH <= screenH then direction = flipV(direction)
      elseif not towardsDown and top + GAP + estH > screenH and bottom - GAP - estH >= 0 then direction = flipV(direction) end
    end
  end
  Tray.effectiveDirection = direction

  local anchor = TRAY_ANCHORS[direction] or TRAY_ANCHORS.leftdown
  container:ClearAllPoints()
  container:SetPoint(anchor[1], main, anchor[2], anchor[3], anchor[4])

  local dragging = drag.frame ~= nil
  local showPins = #pinned > 0 or dragging
  local slots = {}
  drag.slots = slots

  -- Grid geometry. "leftdown": rows fill leftwards, extra rows go down.
  local primary, second = direction:match("^(left)(%a+)$")
  if not primary then primary, second = direction:match("^(right)(%a+)$") end
  if not primary then primary, second = direction:match("^(up)(%a+)$") end
  if not primary then primary, second = direction:match("^(down)(%a+)$") end
  local horizontal = primary == "left" or primary == "right"
  local fromRight = primary == "left" or second == "left"
  local fromBottom = primary == "up" or second == "up"

  local perRow = db.perRow
  local gridCount = #grid
  -- While dragging there is one extra slot so a button can be dropped last.
  local slotCount = dragging and (gridCount + 1) or gridCount
  local along = math.min(slotCount, perRow)
  local across = math.ceil(slotCount / perRow)
  local columns = horizontal and along or across
  local rows = horizontal and across or along
  -- Zero when everything is pinned: the pinned list then starts at the top.
  local gridWidth = slotCount > 0 and (columns * cellWidth + (columns - 1) * SPACING) or 0
  local gridHeight = slotCount > 0 and (rows * cellHeight + (rows - 1) * SPACING) or 0
  local sectionGap = (gridHeight > 0 and showPins) and SECTION_GAP or 0

  -- Pinned rows: one per line, button then label.
  local pinRowHeight = cellHeight
  local pinLabelWidth = PIN_MIN_LABEL
  for index, button in ipairs(pinned) do
    local label = pinLabel(index)
    label:SetText(Collector.DisplayName(Collector.LabelOf(button) or "?"))
    local width = Client.ReadNumber(label:GetStringWidth()) or 0
    if width > pinLabelWidth then pinLabelWidth = width end
  end
  local pinRowWidth = cellWidth + PIN_LABEL_GAP + pinLabelWidth
  local pinCount = #pinned
  local pinRows = dragging and (pinCount + 1) or pinCount   -- the extra one is the drop row
  local pinHeight = showPins and (pinRows * pinRowHeight + (pinRows - 1) * SPACING) or 0
  if showPins and pinCount == 0 then pinHeight = pinRowHeight end

  -- Tray size.
  local emptyGrid = gridCount == 0 and not dragging
  local innerWidth = math.max(gridWidth, showPins and pinRowWidth or 0)
  if emptyGrid and not showPins then
    emptyLabel:Show()
    local width = Client.ReadNumber(emptyLabel:GetStringWidth()) or 170
    container:SetSize(width + 20, 26)
    if pinZone then pinZone:Hide() end
    for _, label in ipairs(pinLabels) do label:Hide() end
    layoutInfo = { cellWidth = cellWidth, cellHeight = cellHeight, gridCount = 0, pinCount = 0 }
    return
  end
  emptyLabel:Hide()
  local innerHeight = gridHeight + sectionGap + (showPins and pinHeight or 0)
  container:SetSize(PADDING * 2 + innerWidth, PADDING * 2 + innerHeight)

  -- The grid is placed inside its own box (gridWidth x gridHeight) that is
  -- aligned to the side the direction grows from; the box sits at the top
  -- of the tray. Slot (column, row) centres, in tray coords from top-left.
  local gridLeft = PADDING + (fromRight and (innerWidth - gridWidth) or 0)
  local gridTop = PADDING
  local function slotCentre(index)
    local first = (index - 1) % perRow
    local other = math.floor((index - 1) / perRow)
    local column = horizontal and first or other
    local row = horizontal and other or first
    if fromRight then column = columns - 1 - column end
    if fromBottom then row = rows - 1 - row end
    local x = gridLeft + column * (cellWidth + SPACING) + cellWidth / 2
    local y = gridTop + row * (cellHeight + SPACING) + cellHeight / 2
    return x, y
  end
  for index, button in ipairs(grid) do
    local x, y = slotCentre(index)
    placeButton(button, x, y)
  end
  if dragging then
    for index = 1, slotCount do
      local x, y = slotCentre(index)
      slots[#slots + 1] = { kind = "grid", index = index,
        left = x - cellWidth / 2 - SPACING / 2, right = x + cellWidth / 2 + SPACING / 2,
        top = y - cellHeight / 2 - SPACING / 2, bottom = y + cellHeight / 2 + SPACING / 2 }
    end
  end

  -- Pinned section.
  for index = pinCount + 1, #pinLabels do pinLabels[index]:Hide() end
  if showPins then
    ensurePinZone()
    local zoneTop = gridTop + gridHeight + sectionGap
    pinZone:ClearAllPoints()
    pinZone:SetPoint("TOPLEFT", container, "TOPLEFT", PADDING, -(zoneTop - sectionGap / 2))
    pinZone:SetSize(innerWidth, pinHeight + sectionGap / 2)
    pinZone.topLine:SetShown(pinCount > 0 or dragging)
    pinZoneLabel:SetShown(pinCount == 0)
    pinZone:Show()
    for index, button in ipairs(pinned) do
      local rowTop = zoneTop + (index - 1) * (pinRowHeight + SPACING)
      placeButton(button, PADDING + cellWidth / 2, rowTop + pinRowHeight / 2)
      local label = pinLabel(index)
      label:ClearAllPoints()
      label:SetPoint("LEFT", container, "TOPLEFT", PADDING + cellWidth + PIN_LABEL_GAP, -(rowTop + pinRowHeight / 2))
      label:SetWidth(innerWidth - cellWidth - PIN_LABEL_GAP)
      label:Show()
    end
    if dragging then
      for index = 1, pinRows do
        local rowTop = zoneTop + (index - 1) * (pinRowHeight + SPACING)
        slots[#slots + 1] = { kind = "pin", index = index,
          left = PADDING, right = PADDING + innerWidth,
          top = rowTop - SPACING / 2, bottom = rowTop + pinRowHeight + SPACING / 2 }
      end
    end
  elseif pinZone then
    pinZone:Hide()
  end

  layoutInfo = { cellWidth = cellWidth, cellHeight = cellHeight, gridCount = gridCount, pinCount = pinCount }
end

function Tray.ApplyScale()
  if not main then return end
  main:SetScale(MBT.db.scale)
  Tray.ApplyPosition()
end

function Tray.ApplyButtonScale()
  local SetScale = MBT.Collector.Original.SetScale
  for _, button in ipairs(MBT.Collector.buttons) do SetScale(button, MBT.db.buttonScale) end
  Tray.Refresh()
end

-- ---------------------------------------------------------------------------
-- shift-drag
-- ---------------------------------------------------------------------------

-- Cursor position in tray coordinates (from the top-left, y downwards).
local function cursorInTray()
  local cx, cy = GetCursorPosition()
  local scale = Client.ReadNumber(container:GetEffectiveScale()) or 1
  if scale <= 0 then scale = 1 end
  local left, top = container:GetLeft(), container:GetTop()
  left, top = Client.ReadNumber(left), Client.ReadNumber(top)
  if not left or not top then return nil end
  return cx / scale - left, top - cy / scale
end

local function slotUnderCursor()
  local x, y = cursorInTray()
  if not x then return nil end
  for _, slot in ipairs(drag.slots) do
    if x >= slot.left and x <= slot.right and y >= slot.top and y <= slot.bottom then return slot end
  end
  return nil
end

local function ensureGhost()
  if drag.ghost then return end
  local ghost = CreateFrame("Frame", nil, UIParent)
  ghost:SetFrameStrata("TOOLTIP")
  ghost:EnableMouse(false)
  ghost.icon = ghost:CreateTexture(nil, "OVERLAY")
  ghost.icon:SetAllPoints()
  ghost:Hide()
  drag.ghost = ghost
  drag.hint = container:CreateTexture(nil, "OVERLAY")
  paint(drag.hint, DROP_HINT)
  drag.hint:Hide()
end

local function updateDrag()
  if not drag.frame then return end
  local cx, cy = GetCursorPosition()
  local scale = Client.ReadNumber(UIParent:GetEffectiveScale()) or 1
  drag.ghost:ClearAllPoints()
  drag.ghost:SetPoint("CENTER", UIParent, "BOTTOMLEFT", cx / scale, cy / scale)
  local slot = slotUnderCursor()
  if slot then
    drag.hint:ClearAllPoints()
    drag.hint:SetPoint("TOPLEFT", container, "TOPLEFT", slot.left, -slot.top)
    drag.hint:SetSize(slot.right - slot.left, slot.bottom - slot.top)
    drag.hint:Show()
  else
    drag.hint:Hide()
  end
end

-- /mbt dragdebug: say why a drag did or did not start.
Tray.dragDebug = false
local function dragLog(fmt, ...)
  if Tray.dragDebug then MBT.Print("drag: " .. fmt, ...) end
end

local function beginDrag(button)
  local name = MBT.Collector.LabelOf(button) or "?"
  if drag.frame then dragLog("%s: ignored, already dragging", name) return end
  if not IsShiftKeyDown() then dragLog("%s: shift not held", name) return end
  if not MBT.Collector.IsCollected(button) then dragLog("%s: not collected", name) return end
  if not container:IsShown() then dragLog("%s: tray closed", name) return end
  dragLog("%s: start", name)
  ensureGhost()
  drag.frame = button
  local size = layoutInfo.cellWidth
  drag.ghost:SetSize(size, size)
  local texture = MBT.Collector.IconOf(button)
  if texture then drag.ghost.icon:SetTexture(texture) else drag.ghost.icon:SetTexture(ICON_PATH) end
  drag.ghost.icon:SetAlpha(0.85)
  drag.ghost:Show()
  MBT.Collector.Original.SetAlpha(button, DRAG_ALPHA)
  if GameTooltip then GameTooltip:Hide() end
  Tray.Refresh()   -- adds the extra slot and shows the pin zone
  updateDrag()
end

local function endDrag()
  local button = drag.frame
  if not button then return end
  local slot = slotUnderCursor()
  dragLog("%s: drop on %s", MBT.Collector.LabelOf(button) or "?", slot and (slot.kind .. " " .. slot.index) or "nothing")
  drag.frame = nil
  drag.ghost:Hide()
  drag.hint:Hide()
  MBT.Collector.Original.SetAlpha(button, 1)
  if slot and slot.kind == "grid" then
    MBT.Collector.MoveToGrid(button, slot.index)
  elseif slot and slot.kind == "pin" then
    MBT.Collector.MoveToPinned(button, slot.index)
  else
    Tray.Refresh()
  end
end

-- Installed on each collected button by the Collector (we own the drag
-- scripts while the button is held). Only a shift-drag does anything.
function Tray.OnButtonDragStart(button) beginDrag(button) end
function Tray.OnButtonDragStop(button) if drag.frame == button then endDrag() end end

-- The button being shift-dragged, or nil. Its alpha is ours while it moves.
function Tray.DraggedButton() return drag.frame end

-- ---------------------------------------------------------------------------
-- opening and closing
-- ---------------------------------------------------------------------------
function Tray.IsOpen()
  return container ~= nil and container:IsShown()
end

function Tray.Open()
  if not container then return end
  MBT.Collector.Scan(true)   -- a quick look; events do the full search
  Tray.Refresh()
  container.idleSeconds = 0
  container:Show()
  paintMainBorder()
end

function Tray.Close()
  if not container then return end
  if drag.frame then endDrag() end
  container:Hide()
  paintMainBorder()
end

function Tray.Toggle()
  if Tray.IsOpen() then Tray.Close() else Tray.Open() end
end

local function mouseNear()
  if main:IsMouseOver() then return true end
  return container:IsMouseOver(6, -6, -6, 6) and true or false
end

-- Polled rather than driven by OnLeave: a collected button's own OnLeave may
-- not reach us, and moving from one button to the next must not close it.
-- idleSeconds counts towards autoHideSeconds; it resets while the mouse is
-- over the main button or the tray, or a shift-drag is in progress.
local function poll(self, elapsed)
  if drag.frame then updateDrag() end

  self.throttle = (self.throttle or 0) + elapsed
  if self.throttle < POLL_INTERVAL then return end
  local step = self.throttle
  self.throttle = 0

  -- A fade that slipped past the locks (a group created after Grab) is undone
  -- within a tick instead of staying dim until the next layout.
  MBT.Collector.EnforceAllAlpha()

  local db = MBT.db
  if mouseNear() or drag.frame then
    self.idleSeconds = 0
    return
  end
  self.idleSeconds = (self.idleSeconds or 0) + step
  if db.autoHideSeconds > 0 and self.idleSeconds >= db.autoHideSeconds then
    Tray.Close()
  end
end

-- ---------------------------------------------------------------------------
-- Blizzard's addon compartment (clients that have one)
-- ---------------------------------------------------------------------------
function Tray.ApplyCompartment()
  if not Client.hasCompartment then return end
  local frame = _G.AddonCompartmentFrame
  if not frame then return end
  if not compartmentHooked and type(frame.HookScript) == "function" then
    compartmentHooked = true
    frame:HookScript("OnShow", function(self)
      if MBT.db.hideCompartment then
        compartmentHidden = true
        self:Hide()
      end
    end)
  end
  if MBT.db.hideCompartment then
    compartmentHidden = true
    frame:Hide()
  elseif compartmentHidden then
    -- Only undo what we did: Blizzard decides when it is shown otherwise.
    compartmentHidden = false
    frame:Show()
  end
end

-- ---------------------------------------------------------------------------
-- frames
-- ---------------------------------------------------------------------------
local function showTooltip(self)
  if not GameTooltip then return end
  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  GameTooltip:AddLine("MinimapButtonTray")
  GameTooltip:AddLine(("%d button(s) collected"):format(#MBT.Collector.buttons), 1, 1, 1)
  GameTooltip:AddLine("Left click: show or hide the buttons", 0.8, 0.8, 0.8)
  GameTooltip:AddLine("Right click: options", 0.8, 0.8, 0.8)
  GameTooltip:AddLine("Drag: move", 0.6, 0.6, 0.6)
  GameTooltip:AddLine("Shift-drag a button in the tray: reorder, or pin it as a named row", 0.6, 0.6, 0.6)
  GameTooltip:Show()
end

function Tray.Init()
  if main then return end

  main = CreateFrame("Button", "MinimapButtonTray_Main", UIParent)
  Tray.main = main
  main:SetSize(MAIN_SIZE, MAIN_SIZE)
  main:SetFrameStrata("MEDIUM")
  main:SetFrameLevel(8)
  main:SetClampedToScreen(true)
  main:SetMovable(true)
  main:EnableMouse(true)
  main:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  main:RegisterForDrag("LeftButton")
  mainBorders = frameBox(main, true)

  local icon = main:CreateTexture(nil, "ARTWORK")
  icon:SetTexture(ICON_PATH)
  icon:SetAllPoints()
  main.icon = icon
  local highlight = main:CreateTexture(nil, "HIGHLIGHT")
  highlight:SetColorTexture(1, 1, 1, 0.12)
  highlight:SetAllPoints(icon)

  main:SetScript("OnClick", function(_, mouseButton)
    if mouseButton == "RightButton" then MBT.Options.Open() else Tray.Toggle() end
  end)
  main:SetScript("OnDragStart", function(self)
    if MBT.db.locked then return end
    if GameTooltip then GameTooltip:Hide() end
    self:StartMoving()
  end)
  main:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    -- Keep the client from restoring its own copy of the position.
    if self.SetUserPlaced then pcall(self.SetUserPlaced, self, false) end
    Tray.SavePosition()
  end)
  main:SetScript("OnEnter", function(self)
    self.hover = true
    paintMainBorder()
    showTooltip(self)
  end)
  main:SetScript("OnLeave", function(self)
    self.hover = false
    paintMainBorder()
    if GameTooltip then GameTooltip:Hide() end
  end)

  container = CreateFrame("Frame", "MinimapButtonTray_Tray", main)
  Tray.container = container
  -- Above the buffs and the objective tracker that sit around the minimap.
  container:SetFrameStrata("HIGH")
  container:SetClampedToScreen(true)
  -- The tray never takes the mouse (hover is polled): a button that somehow
  -- ends up under it stays clickable.
  container:EnableMouse(false)
  container:Hide()
  frameBox(container)
  container:SetScript("OnUpdate", poll)

  emptyLabel = container:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  emptyLabel:SetPoint("CENTER")
  emptyLabel:SetText("No minimap button found")
  emptyLabel:SetTextColor(0.7, 0.7, 0.7)

  Tray.ApplyScale()
  Tray.Refresh()
  paintMainBorder()
end
