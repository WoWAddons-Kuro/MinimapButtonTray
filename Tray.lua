-- MinimapButtonTray: the main button and the tray that opens next to it with
-- the collected buttons in a grid.
local ADDON_NAME, MBT = ...
local Client = MBT.Client

local Tray = {}
MBT.Tray = Tray

local MAIN_SIZE = 30         -- main button
local PADDING = 4            -- inside the tray
local SPACING = 2            -- between two buttons
local GAP = 2                -- between the main button and the tray
local DEFAULT_CELL = 32
local MAX_CELL = 64
local LEAVE_CLOSE_DELAY = 0.8  -- seconds away before closeOnLeave fires
local POLL_INTERVAL = 0.1
local ICON_PATH = "Interface\\AddOns\\" .. ADDON_NAME .. "\\Media\\MinimapButtonTray"

local BACKGROUND = { 0.05, 0.05, 0.06, 0.92 }
local BORDER = { 0.25, 0.45, 0.55, 1 }
local BORDER_OPEN = { 0.40, 0.80, 1, 1 }

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

-- ---------------------------------------------------------------------------
-- drawing
-- ---------------------------------------------------------------------------
local function paint(texture, color)
  texture:SetColorTexture(color[1], color[2], color[3], color[4])
end

-- Flat background plus a 1px border; returns the border textures.
local function frameBox(frame)
  local background = frame:CreateTexture(nil, "BACKGROUND")
  paint(background, BACKGROUND)
  background:SetAllPoints()
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
  local color = (open or (main and main.hover)) and BORDER_OPEN or BORDER
  for _, line in ipairs(mainBorders) do paint(line, color) end
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
-- grid
-- ---------------------------------------------------------------------------
function Tray.Refresh()
  if not container then return end
  local db = MBT.db
  local Collector = MBT.Collector
  local Original = Collector.Original

  local visible = {}
  local cellWidth, cellHeight = 0, 0
  for _, button in ipairs(Collector.buttons) do
    Collector.EnforceAlpha(button)
    if button:IsShown() then
      visible[#visible + 1] = button
      local scale = Client.ReadNumber(button:GetScale()) or 1
      local width, height = Client.ReadNumber(button:GetWidth()), Client.ReadNumber(button:GetHeight())
      if width and width * scale > cellWidth then cellWidth = width * scale end
      if height and height * scale > cellHeight then cellHeight = height * scale end
    end
  end
  if cellWidth <= 0 then cellWidth = DEFAULT_CELL end
  if cellHeight <= 0 then cellHeight = DEFAULT_CELL end
  cellWidth, cellHeight = math.min(cellWidth, MAX_CELL), math.min(cellHeight, MAX_CELL)

  local anchor = TRAY_ANCHORS[db.direction] or TRAY_ANCHORS.leftdown
  container:ClearAllPoints()
  container:SetPoint(anchor[1], main, anchor[2], anchor[3], anchor[4])

  local count = #visible
  emptyLabel:SetShown(count == 0)
  if count == 0 then
    local width = Client.ReadNumber(emptyLabel:GetStringWidth()) or 170
    container:SetSize(width + 20, 26)
    return
  end

  -- "leftdown": rows fill leftwards, extra rows go down.
  local primary, second = db.direction:match("^(left)(%a+)$")
  if not primary then primary, second = db.direction:match("^(right)(%a+)$") end
  if not primary then primary, second = db.direction:match("^(up)(%a+)$") end
  if not primary then primary, second = db.direction:match("^(down)(%a+)$") end
  local horizontal = primary == "left" or primary == "right"
  local fromRight = primary == "left" or second == "left"
  local fromBottom = primary == "up" or second == "up"
  local corner = (fromBottom and "BOTTOM" or "TOP") .. (fromRight and "RIGHT" or "LEFT")

  local perRow = db.perRow
  local along = math.min(count, perRow)
  local across = math.ceil(count / perRow)
  local columns = horizontal and along or across
  local rows = horizontal and across or along
  container:SetSize(PADDING * 2 + columns * cellWidth + (columns - 1) * SPACING,
    PADDING * 2 + rows * cellHeight + (rows - 1) * SPACING)

  for index, button in ipairs(visible) do
    local first = (index - 1) % perRow
    local other = math.floor((index - 1) / perRow)
    local column = horizontal and first or other
    local row = horizontal and other or first
    local x = PADDING + column * (cellWidth + SPACING) + cellWidth / 2
    local y = PADDING + row * (cellHeight + SPACING) + cellHeight / 2
    if fromRight then x = -x end
    if not fromBottom then y = -y end
    -- Offsets are in the button's own units.
    local scale = Client.ReadNumber(button:GetScale()) or 1
    if scale <= 0 then scale = 1 end
    Original.ClearAllPoints(button)
    Original.SetPoint(button, "CENTER", container, corner, x / scale, y / scale)
  end
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
-- opening and closing
-- ---------------------------------------------------------------------------
function Tray.IsOpen()
  return container ~= nil and container:IsShown()
end

function Tray.Open()
  if not container then return end
  MBT.Collector.Scan(true)   -- a quick look; events do the full search
  Tray.Refresh()
  container.awaySeconds = 0
  container.idleSeconds = 0
  container:Show()
  paintMainBorder()
end

function Tray.Close()
  if not container then return end
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
-- Two timers: awaySeconds (closeOnLeave) and idleSeconds (autoHideSeconds),
-- both reset while the mouse is over the main button or the tray.
local function poll(self, elapsed)
  self.throttle = (self.throttle or 0) + elapsed
  if self.throttle < POLL_INTERVAL then return end
  local step = self.throttle
  self.throttle = 0

  -- A fade that slipped past the locks (a group created after Grab) is undone
  -- within a tick instead of staying dim until the next layout.
  MBT.Collector.EnforceAllAlpha()

  local db = MBT.db
  if mouseNear() then
    self.awaySeconds = 0
    self.idleSeconds = 0
    return
  end
  self.awaySeconds = (self.awaySeconds or 0) + step
  self.idleSeconds = (self.idleSeconds or 0) + step
  if db.closeOnLeave and self.awaySeconds >= LEAVE_CLOSE_DELAY then
    Tray.Close()
  elseif db.autoHideSeconds > 0 and self.idleSeconds >= db.autoHideSeconds then
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
  mainBorders = frameBox(main)

  local icon = main:CreateTexture(nil, "ARTWORK")
  icon:SetTexture(ICON_PATH)
  icon:SetPoint("TOPLEFT", 2, -2)
  icon:SetPoint("BOTTOMRIGHT", -2, 2)
  main.icon = icon
  local highlight = main:CreateTexture(nil, "HIGHLIGHT")
  highlight:SetColorTexture(1, 1, 1, 0.12)
  highlight:SetAllPoints(icon)

  main:SetScript("OnClick", function(_, mouseButton)
    if mouseButton == "RightButton" then MBT.Options.Open() else Tray.Toggle() end
  end)
  main:SetScript("OnDragStart", function(self)
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
