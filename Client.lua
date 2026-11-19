-- MinimapButtonTray: client abstraction.
--
-- One table, built once at load, that says which client we are on and which
-- capabilities it has. Everything else in the addon reads APIs that differ
-- between flavours through MBT.Client, never through _G directly. A missing
-- capability is a flag, not an error; code branches on flags, never on the
-- flavour name (that is for /mbt debug only).
local ADDON_NAME, MBT = ...
_G.MinimapButtonTray = MBT
MBT.ADDON_NAME = ADDON_NAME

local Client = {}
MBT.Client = Client

-- ---------------------------------------------------------------------------
-- flavour
-- ---------------------------------------------------------------------------
local buildVersion, buildNumber, _, interfaceNumber = GetBuildInfo()
Client.buildVersion = tostring(buildVersion or "?")
Client.buildNumber = tostring(buildNumber or "?")
Client.interface = tonumber(interfaceNumber) or 0
Client.projectID = WOW_PROJECT_ID

-- Forever reports WOW_PROJECT_MAINLINE with a 1.60.x version / 16001 interface,
-- so the project id alone cannot tell it from Retail.
if WOW_PROJECT_ID == WOW_PROJECT_CLASSIC then
  Client.flavour = "era"
elseif WOW_PROJECT_ID == WOW_PROJECT_MAINLINE and Client.interface >= 16000 and Client.interface < 20000 then
  Client.flavour = "forever"
elseif WOW_PROJECT_ID == WOW_PROJECT_MAINLINE then
  Client.flavour = "mainline"
else
  Client.flavour = "other"
end

-- ---------------------------------------------------------------------------
-- shims: same call shape on every client
-- ---------------------------------------------------------------------------

-- Forever can hand addon code opaque "secret" values that raise on any
-- comparison or arithmetic. Frame geometry of addon frames is not supposed to
-- be one of them, but the layout does maths on sizes and positions, so every
-- number read from the client goes through ReadNumber first.
local issecretvalue = _G.issecretvalue
Client.hasSecretValues = type(issecretvalue) == "function"

function Client.IsSecret(value)
  return Client.hasSecretValues and issecretvalue(value) or false
end

-- The value when it is a plain readable number, nil otherwise.
function Client.ReadNumber(value)
  if Client.IsSecret(value) then return nil end
  if type(value) ~= "number" then return nil end
  return value
end

-- The value when it is a plain readable string, nil otherwise.
function Client.ReadString(value)
  if Client.IsSecret(value) then return nil end
  if type(value) ~= "string" then return nil end
  return value
end

function Client.GetAddOnMetadata(name, field)
  if C_AddOns and C_AddOns.GetAddOnMetadata then return C_AddOns.GetAddOnMetadata(name, field) end
  if GetAddOnMetadata then return GetAddOnMetadata(name, field) end
  return nil
end

-- Frames under the mouse, newest API first. Era 1.15 has GetMouseFoci too, but
-- keep the single-focus fallback for anything older.
function Client.GetMouseFoci()
  if GetMouseFoci then return GetMouseFoci() end
  if GetMouseFocus then
    local focus = GetMouseFocus()
    if focus then return { focus } end
  end
  return {}
end

-- ---------------------------------------------------------------------------
-- capability flags
-- ---------------------------------------------------------------------------
Client.hasCompartment = _G.AddonCompartmentFrame ~= nil                       -- Forever/Retail yes, Era no
Client.hasEditMode = _G.EditModeManagerFrame ~= nil                            -- Forever/Retail yes, Era no
Client.hasFixedStrata = type(UIParent.SetFixedFrameStrata) == "function"      -- LibDBIcon pins strata/level with these
Client.hasIgnoreParentScale = type(UIParent.SetIgnoreParentScale) == "function"
Client.hasSettingsAPI = _G.Settings ~= nil and type(_G.Settings.RegisterCanvasLayoutCategory) == "function"
Client.hasLegacyOptions = type(_G.InterfaceOptions_AddCategory) == "function"
Client.hasSecureHooks = type(_G.hooksecurefunc) == "function"
Client.hasTimers = _G.C_Timer ~= nil and type(_G.C_Timer.After) == "function"
Client.backdropTemplate = _G.BackdropTemplateMixin and "BackdropTemplate" or nil

-- Frames whose named children are minimap-button candidates. The cluster
-- exists on every client; the backdrop is where older addons parent to.
Client.minimapParents = { "Minimap", "MinimapBackdrop", "MinimapCluster" }

-- ---------------------------------------------------------------------------
-- debug
-- ---------------------------------------------------------------------------

-- One line per field, sorted, for /mbt debug.
function Client.Describe()
  local lines = {}
  local keys = {}
  for key, value in pairs(Client) do
    if type(value) ~= "function" then keys[#keys + 1] = key end
  end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local value = Client[key]
    if type(value) == "table" then value = table.concat(value, ", ") end
    lines[#lines + 1] = key .. " = " .. tostring(value)
  end
  return lines
end
