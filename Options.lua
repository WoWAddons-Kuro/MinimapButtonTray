-- MinimapButtonTray: options page in the Blizzard Settings panel (legacy
-- Interface Options on clients without the Settings API). Sections: Layout,
-- Behaviour, Buttons (tick list: collected / ignored).
local ADDON_NAME, MBT = ...
local Client = MBT.Client

local Options = {}
MBT.Options = Options

local BOX_WIDTH, PAD = 580, 10
local LIST_ROWS = 10
local LIST_ROW_HEIGHT = 20

local optionsCategory, optionsFrame
local controls = {}           -- widgets with an :Update() method
local listRows, listEntries = {}, {}
local listOffset = 0
local listEmptyText, listRangeText

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------
local function percent(value)
  return ("%d%%"):format(math.floor(value * 100 + 0.5))
end

local function friendlyName(name)
  return (name:gsub("^LibDBIcon10_", ""):gsub("^LibMapButton_", ""))
end

-- ---------------------------------------------------------------------------
-- button list: collected ticked, ignored unticked; one click moves a button
-- between the tray and the minimap
-- ---------------------------------------------------------------------------
local function buildListEntries()
  listEntries = {}
  for _, button in ipairs(MBT.Collector.buttons) do
    local name = MBT.Collector.LabelOf(button)
    if name then listEntries[#listEntries + 1] = { name = name, collected = true, hidden = not button:IsShown() } end
  end
  for name in pairs(MBT.db.ignore) do
    listEntries[#listEntries + 1] = { name = name, collected = false }
  end
  table.sort(listEntries, function(a, b) return friendlyName(a.name):lower() < friendlyName(b.name):lower() end)
end

local function drawListRows()
  local maxOffset = math.max(0, #listEntries - LIST_ROWS)
  if listOffset > maxOffset then listOffset = maxOffset end
  if listOffset < 0 then listOffset = 0 end

  for index, row in ipairs(listRows) do
    local entry = listEntries[listOffset + index]
    row.entry = entry
    if entry then
      local text = friendlyName(entry.name)
      if entry.hidden then text = text .. "  |cff808080(hidden by its addon)|r" end
      row.Text:SetText(text)
      row.Text:SetTextColor(entry.collected and 0.9 or 0.5, entry.collected and 0.9 or 0.5, entry.collected and 0.9 or 0.5)
      row:SetChecked(entry.collected)
      row:Show()
    else
      row:Hide()
    end
  end

  listEmptyText:SetShown(#listEntries == 0)
  if #listEntries > LIST_ROWS then
    listRangeText:SetText(("%d-%d / %d"):format(listOffset + 1, math.min(listOffset + LIST_ROWS, #listEntries), #listEntries))
  else
    listRangeText:SetText("")
  end
end

local function rowTooltip(row)
  local entry = row.entry
  if not entry or not GameTooltip then return end
  GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
  GameTooltip:AddLine(entry.name, 1, 1, 1)
  GameTooltip:AddLine(entry.collected and "Untick to put it back on the minimap" or "Tick to collect it again", 0.8, 0.8, 0.8)
  GameTooltip:Show()
end

local function buildList(parent)
  local list = CreateFrame("Frame", nil, parent)
  list:SetSize(BOX_WIDTH - 2 * PAD, LIST_ROWS * LIST_ROW_HEIGHT + 4)
  list:EnableMouseWheel(true)
  list:SetScript("OnMouseWheel", function(_, delta)
    listOffset = listOffset - delta
    drawListRows()
  end)

  for index = 1, LIST_ROWS do
    local row = CreateFrame("CheckButton", nil, list, "InterfaceOptionsCheckButtonTemplate")
    row:SetPoint("TOPLEFT", 0, -(index - 1) * LIST_ROW_HEIGHT)
    row:SetSize(LIST_ROW_HEIGHT, LIST_ROW_HEIGHT)
    row.Text:SetFontObject("GameFontHighlightSmall")
    row:SetScript("OnEnter", rowTooltip)
    row:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
    row:SetScript("OnClick", function(self)
      local entry = self.entry
      if not entry then return end
      if entry.collected then MBT.Collector.Ignore(entry.name) else MBT.Collector.Unignore(entry.name) end
      Options.RefreshList()
      rowTooltip(self)
    end)
    listRows[index] = row
  end

  listEmptyText = list:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  listEmptyText:SetPoint("TOPLEFT", 4, -4)
  listEmptyText:SetText("No minimap button found yet")
  listEmptyText:SetTextColor(0.6, 0.6, 0.6)
  return list
end

function Options.RefreshList()
  if not optionsFrame then return end
  buildListEntries()
  drawListRows()
end

-- ---------------------------------------------------------------------------
-- page
-- ---------------------------------------------------------------------------
local function createOptions()
  local db = MBT.db
  optionsFrame = CreateFrame("Frame", "MinimapButtonTray_Options")
  optionsFrame.name = "MinimapButtonTray"

  -- Scrolling container: the registered canvas holds a ScrollFrame whose child
  -- carries every widget. Mouse wheel scrolls; a standard scrollbar on the right.
  local scroll = CreateFrame("ScrollFrame", "MinimapButtonTray_OptionsScroll", optionsFrame, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 0, -4)
  scroll:SetPoint("BOTTOMRIGHT", -28, 4)
  local content = CreateFrame("Frame", nil, scroll)
  content:SetSize(620, 900)
  scroll:SetScrollChild(content)
  scroll:SetScript("OnSizeChanged", function(_, width) content:SetWidth(math.max(620, width)) end)
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", function(self, delta)
    local range = self:GetVerticalScrollRange()
    self:SetVerticalScroll(math.max(0, math.min(range, self:GetVerticalScroll() - delta * 40)))
  end)

  local title = content:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 16, -16)
  title:SetText("MinimapButtonTray  |cff999999v" .. MBT.version .. "|r")
  local sub = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
  sub:SetWidth(560)
  sub:SetJustifyH("LEFT")
  sub:SetText("Gathers the minimap buttons of your addons into one tray. Left-click the tray button to open it, right-click for this page, drag to move it. More in /mbt help.")

  -- Layout grid: every widget hangs off `last` at a fixed left column; sections
  -- are bordered boxes with a header.
  local last, lastDy = sub, -14
  local function Place(widget, dy)
    widget:SetPoint("TOPLEFT", last, "BOTTOMLEFT", 0, dy or lastDy)
    last, lastDy = widget, -6
  end

  local function Check(parent, key, label, tip, onChange)
    local box = CreateFrame("CheckButton", nil, parent, "InterfaceOptionsCheckButtonTemplate")
    box.Text:SetText(label)
    box.tooltipText = tip
    box:SetScript("OnClick", function(self)
      db[key] = self:GetChecked() and true or false
      if onChange then onChange() end
    end)
    box.Update = function(self) self:SetChecked(db[key] and true or false) end
    controls[#controls + 1] = box
    return box
  end

  -- Slider with its label above-left so it lines up with the checkboxes.
  -- step may be fractional (scales); the value is snapped to it.
  local function Slider(parent, name, key, minV, maxV, step, labelFn, onChange)
    local holder = CreateFrame("Frame", nil, parent)
    holder:SetSize(BOX_WIDTH - 2 * PAD, 44)
    local label = holder:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    label:SetPoint("TOPLEFT", 4, 0)
    local slider = CreateFrame("Slider", name, holder, "OptionsSliderTemplate")
    slider:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 2, -6)
    slider:SetWidth(220)
    slider:SetMinMaxValues(minV, maxV)
    slider:SetValueStep(step)
    slider:SetObeyStepOnDrag(true)
    _G[name .. "Low"]:SetText(labelFn(minV, true))
    _G[name .. "High"]:SetText(labelFn(maxV, true))
    _G[name .. "Text"]:SetText("")
    local function snap(value)
      value = math.floor(value / step + 0.5) * step
      return tonumber(("%.4f"):format(MBT.Clamp(value, minV, maxV)))
    end
    slider:SetScript("OnValueChanged", function(self, value)
      value = snap(value)
      label:SetText(labelFn(value))
      if self.loading then return end
      db[key] = value
      if onChange then onChange() end
    end)
    holder.Update = function()
      slider.loading = true
      slider:SetValue(db[key])
      label:SetText(labelFn(db[key]))
      slider.loading = nil
    end
    controls[#controls + 1] = holder
    return holder
  end

  -- Radio group laid out in two columns inside a section.
  local function Radios(parent, key, items, onChange)
    local holder = CreateFrame("Frame", nil, parent)
    local columns = 2
    local rowsNeeded = math.ceil(#items / columns)
    holder:SetSize(BOX_WIDTH - 2 * PAD, rowsNeeded * 20)
    local radios = {}
    for index, item in ipairs(items) do
      local radio = CreateFrame("CheckButton", nil, holder, "UIRadioButtonTemplate")
      radio:SetSize(16, 16)
      local column, row = (index - 1) % columns, math.floor((index - 1) / columns)
      radio:SetPoint("TOPLEFT", 4 + column * 270, -row * 20)
      radio.text = radio:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
      radio.text:SetPoint("LEFT", radio, "RIGHT", 4, 0)
      radio.text:SetText(item.label)
      radio.value = item.value
      radio:SetScript("OnClick", function()
        db[key] = item.value
        for _, other in ipairs(radios) do other:SetChecked(other.value == item.value) end
        if onChange then onChange() end
      end)
      radios[#radios + 1] = radio
    end
    holder.Update = function()
      for _, radio in ipairs(radios) do radio:SetChecked(radio.value == db[key]) end
    end
    controls[#controls + 1] = holder
    return holder
  end

  -- Bordered section with a header; children are added top to bottom and the
  -- box is sized from the running height once Finish() is called.
  local function Section(header)
    local box = CreateFrame("Frame", nil, content, Client.backdropTemplate)
    box:SetWidth(BOX_WIDTH)
    if box.SetBackdrop then
      box:SetBackdrop({ bgFile = "Interface\\Tooltips\\UI-Tooltip-Background", edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 } })
      box:SetBackdropColor(0, 0, 0, 0.25)
      box:SetBackdropBorderColor(0.6, 0.6, 0.6, 0.6)
    end
    local heading = box:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    heading:SetPoint("TOPLEFT", PAD, -PAD)
    heading:SetText(header)
    box.heading = heading
    box.innerLast, box.innerHeight = heading, PAD + 14
    function box:Add(widget, height, dy, dx)
      dy = dy or -6
      widget:SetPoint("TOPLEFT", self.innerLast, "BOTTOMLEFT", dx or 0, dy)
      self.innerLast, self.innerHeight = widget, self.innerHeight - dy + height
      return widget
    end
    function box:Finish() self:SetHeight(self.innerHeight + PAD) end
    Place(box, -14)
    return box
  end

  local Tray = MBT.Tray

  -- Section: Layout
  local layout = Section("Layout")
  local growLabel = layout:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  growLabel:SetText("Grow direction")
  layout:Add(growLabel, 14, -8, 4)
  local directions = {}
  for index, direction in ipairs(MBT.DIRECTIONS) do
    directions[index] = { value = direction, label = MBT.DirectionLabel(direction) }
  end
  layout:Add(Radios(layout, "direction", directions, Tray.Refresh), math.ceil(#directions / 2) * 20, -6)
  layout:Add(Slider(layout, "MinimapButtonTray_OptionsPerRow", "perRow", 1, 12, 1,
    function(v, short) return short and tostring(v) or ("Buttons per row: " .. v) end, Tray.Refresh), 44, -10)
  layout:Add(Slider(layout, "MinimapButtonTray_OptionsScale", "scale", 0.5, 2, 0.05,
    function(v, short) return short and percent(v) or ("Size of the button and the tray: " .. percent(v)) end, Tray.ApplyScale), 44, -10)
  layout:Add(Slider(layout, "MinimapButtonTray_OptionsButtonScale", "buttonScale", 0.5, 2, 0.05,
    function(v, short) return short and percent(v) or ("Size of the collected buttons: " .. percent(v)) end, Tray.ApplyButtonScale), 44, -10)
  local reset = CreateFrame("Button", nil, layout, "UIPanelButtonTemplate")
  reset:SetSize(160, 22)
  reset:SetText("Reset button position")
  reset:SetScript("OnClick", Tray.ResetPosition)
  layout:Add(reset, 22, -10, 4)
  layout:Finish()

  -- Section: Behaviour
  local behaviour = Section("Behaviour")
  behaviour:Add(Slider(behaviour, "MinimapButtonTray_OptionsAutoHide", "autoHideSeconds", 0, MBT.AUTO_HIDE_MAX, 1,
    function(v, short)
      if short then return tostring(v) end
      return v == 0 and "Auto-hide the tray: never" or ("Auto-hide the tray after " .. v .. " s without the mouse on it")
    end), 44, -8)
  behaviour:Add(Check(behaviour, "closeOnLeave", "Close the tray as soon as the mouse leaves it",
    "Closes about a second after the mouse leaves the tray and the main button. Off: only the auto-hide timer (or a click) closes it."), 26, -8)
  if Client.hasCompartment then
    behaviour:Add(Check(behaviour, "hideCompartment", "Hide Blizzard's addon compartment",
      "The addon list button on the minimap. Most of its entries are the same addons whose buttons are in the tray.", Tray.ApplyCompartment), 26)
  end
  behaviour:Finish()

  -- Section: Buttons
  local buttons = Section("Buttons")
  listRangeText = buttons:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  listRangeText:SetPoint("TOPRIGHT", -PAD, -PAD)
  listRangeText:SetTextColor(0.6, 0.6, 0.6)
  local hint = buttons:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  hint:SetText("Untick a button to leave it on the minimap. Mouse wheel scrolls. A frame that is not found on its own: /mbt add <name>.")
  hint:SetTextColor(0.6, 0.6, 0.6)
  buttons:Add(hint, 12, -6, 4)
  buttons:Add(buildList(buttons), LIST_ROWS * LIST_ROW_HEIGHT + 4, -8, 4)
  local rescan = CreateFrame("Button", nil, buttons, "UIPanelButtonTemplate")
  rescan:SetSize(160, 22)
  rescan:SetText("Look for new buttons")
  rescan:SetScript("OnClick", function()
    MBT.Collector.Scan()
    Options.RefreshList()
  end)
  buttons:Add(rescan, 22, -8, 4)
  buttons:Finish()

  -- Content height from the last section so the scroll range is right.
  content:SetHeight(16 + 20 + 6 + 40 + 14 + layout:GetHeight() + 14 + behaviour:GetHeight() + 14 + buttons:GetHeight() + 40)

  optionsFrame:SetScript("OnShow", function()
    MBT.Collector.Scan(true)
    Options.Refresh()
  end)

  if Client.hasSettingsAPI then
    optionsCategory = Settings.RegisterCanvasLayoutCategory(optionsFrame, "MinimapButtonTray")
    Settings.RegisterAddOnCategory(optionsCategory)
  elseif Client.hasLegacyOptions then
    InterfaceOptions_AddCategory(optionsFrame)
  end
end

function Options.Init()
  if not optionsFrame then createOptions() end
end

function Options.Refresh()
  if not optionsFrame then return end
  for _, control in ipairs(controls) do control:Update() end
  Options.RefreshList()
end

function Options.Open()
  Options.Init()
  if Client.hasSettingsAPI and Settings.OpenToCategory and optionsCategory then
    Settings.OpenToCategory(optionsCategory:GetID())
  elseif InterfaceOptionsFrame_OpenToCategory then
    -- Called twice on purpose: the first call on an old client only opens the panel.
    InterfaceOptionsFrame_OpenToCategory(optionsFrame)
    InterfaceOptionsFrame_OpenToCategory(optionsFrame)
  end
end
