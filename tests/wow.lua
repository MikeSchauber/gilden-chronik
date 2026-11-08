-- Nachbau der WoW-API, soweit das Addon sie nutzt, für Tests ohne Spiel.
-- Widgets kennen nur Methoden, die es in WoW gibt; ein Tippfehler im Addon
-- („SetTextColour“) wirft deshalb einen Fehler. Läuft mit Lua 5.1 bis 5.4.

unpack = unpack or table.unpack
tinsert = table.insert

-- Testzustand: T = Zeit, Timer, gesendete Nachrichten; W = Spielwelt.
T = { now = 1790000000, timers = {}, sent = {}, printed = {}, sendResult = 0 }
W = {
  cursor = { 0, 0 }, combat = false,
  player = "Ayky", inGuild = true, guild = "Yakman", level = 12, money = 12345,
  roster = {
    { "Ayky-Blackrock", 12, true, "HUNTER" },
    { "Brakmor-Blackrock", 20, true, "WARRIOR" },
    { "Liriel-Blackrock", 15, true, "PRIEST" },
  },
  -- Instanz (nil = offene Welt), Gruppe, Ziel
  instance = nil, zone = "Orgrimmar", map = 85,
  raid = nil,   -- { { name, zone, online }, … }
  party = nil,  -- { { name, realm, online, map, visible }, … } ohne den eigenen Charakter
  target = nil, -- { name, dead, player, guid }
  -- Abenteuerführer: Stufen mit Dungeons und Raids
  ej = {
    current = 1,
    tiers = {
      { name = "Classic",
        dungeons = { { id = 227, name = "Tiefschwarze Grotte", mapID = 48,
                       bosses = { { name = "Ghamoo-ra", encounter = 1667 } } } },
        raids = { { id = 741, name = "Geschmolzener Kern", mapID = 409,
                    bosses = { { name = "Lucifron", encounter = 663 }, { name = "Magmadar", encounter = 664 },
                               { name = "Ragnaros", encounter = 672 } } },
                  { id = 9999, name = "Ohne Karte", bosses = { { name = "Niemand" } } } } },
      { name = "Burning Crusade", dungeons = {}, raids = {
        { id = 745, name = "Karazhan", mapID = 532, bosses = { { name = "Attumen", encounter = 652 } } } } },
    },
  },
}

-- Secret Values (Midnight): sehen aus wie Werte, lassen sich aber nicht speichern oder vergleichen.
SECRET = setmetatable({}, { __tostring = function() return "<secret>" end })
function issecretvalue(v) return v == SECRET end

function GetServerTime() return math.floor(T.now) end -- in WoW ganze Sekunden
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
function strtrim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
function strsplit(sep, s)
  local out, start = {}, 1
  while true do
    local i = s:find(sep, start, true)
    if not i then out[#out + 1] = s:sub(start) break end
    out[#out + 1] = s:sub(start, i - 1)
    start = i + 1
  end
  return unpack(out)
end
function print(...) T.printed[#T.printed + 1] = table.concat({ ... }, " ") end

C_Timer = {}
function C_Timer.After(sec, fn) T.timers[#T.timers + 1] = { at = T.now + sec, fn = fn } end
function C_Timer.NewTicker(sec, fn)
  local ticker = {}
  local function tick()
    if ticker.cancelled then return end
    fn()
    C_Timer.After(sec, tick)
  end
  C_Timer.After(sec, tick)
  function ticker:Cancel() self.cancelled = true end
  return ticker
end

-- Uhr vorstellen und fällige Timer in zeitlicher Reihenfolge ausführen.
function advance(sec)
  local target = T.now + sec
  while true do
    table.sort(T.timers, function(a, b) return a.at < b.at end)
    local nxt = T.timers[1]
    if not nxt or nxt.at > target then break end
    table.remove(T.timers, 1)
    T.now = nxt.at
    nxt.fn()
  end
  T.now = target
end

function GetNormalizedRealmName() return "Blackrock" end
function GetRealmName() return "Blackrock" end
function date(fmt, t) return os.date(fmt, t) end
function debugprofilestop() return os.clock() * 1000 end
function GetBuildInfo() return "12.1.0", "65000", "Oct 1 2026", 120100 end
function GetLocale() return "deDE" end
UNKNOWNOBJECT = "Unbekannt"

-- Einheiten: player, party1–4, target
local function partyMember(unit)
  local i = tonumber((unit or ""):match("^party(%d)$"))
  return i and W.party and W.party[i]
end
-- WoW Forever (W.regionalNames): Vor- und Nachname, UnitName liefert den Nachnamen als zweiten Wert
-- (in Retail der Realm anderer Spieler); Gildenliste und Absender „Vorname Nachname“ ohne Realm
function RegionalUniqueNamesEnabled() return W.regionalNames == true end
function UnitName(unit)
  if unit == nil or unit == "player" then return W.player, W.surname end
  local p = partyMember(unit)
  if p then return p.name, p.realm end
  if unit == "target" and W.target then return W.target.name end
end
function UnitExists(unit)
  if unit == "player" then return true end
  if unit == "target" then return W.target ~= nil end
  return partyMember(unit) ~= nil
end
function UnitIsConnected(unit) local p = partyMember(unit) return p and p.online end
function UnitIsVisible(unit) local p = partyMember(unit) return p and p.visible end
function UnitIsDead(unit) return unit == "target" and W.target and W.target.dead or false end
function UnitIsPlayer(unit) return unit == "player" or (unit == "target" and W.target and W.target.player) or false end
function UnitGUID(unit) if unit == "target" and W.target then return W.target.guid end end
C_Map = {
  GetBestMapForUnit = function(unit)
    if unit == "player" then return W.map end
    local p = partyMember(unit)
    return p and p.map
  end,
}

-- Instanz und Gruppe
function IsInInstance()
  local inst = W.instance
  return inst ~= nil and inst.type ~= "none", inst and inst.type or "none"
end
-- name, instanceType, difficultyID, difficultyName, maxPlayers, dynamicDifficulty, isDynamic, instanceID
function GetInstanceInfo()
  local i = W.instance
  if not i then return "Kalimdor", "none", 0, "", 0, 0, false, 1 end
  return i.name, i.type, i.difficulty, "Normal", i.maxPlayers, 0, false, i.id
end
-- Mit Instanz-ID: Name dieser Instanz (W.maps), unbekannt leer; W.zoneIgnoresId: wie ein Client,
-- der das Argument nicht kennt (immer die aktuelle Zone)
function GetRealZoneText(instanceID)
  if instanceID ~= nil and not W.zoneIgnoresId then return W.maps and W.maps[instanceID] or "" end
  return W.instance and W.instance.name or W.zone
end
function IsInRaid() return W.raid ~= nil end
function IsInGroup() return W.raid ~= nil or W.party ~= nil end
function GetNumGroupMembers()
  if W.raid then return #W.raid end
  if W.party then return #W.party + 1 end
  return 0
end
-- name, rank, subgroup, level, class, fileName, zone, online, isDead, role, isML
function GetRaidRosterInfo(i)
  local r = W.raid and W.raid[i]
  if not r then return nil end
  return r[1], 0, 1, 60, "Krieger", "WARRIOR", r[2], r[3], false, "NONE", false
end

-- Gruppensuche (C_LFGList): W.lfg = { categories = { … }, activities = { [activityID] = { fullName =,
-- categoryID =, mapID =, minLevel =, maxLevelSuggestion =, maxNumPlayers = } } }; ohne W.lfg leer
C_LFGList = {
  GetAvailableCategories = function() return W.lfg and W.lfg.categories or {} end,
  GetAvailableActivities = function(categoryID)
    local out = {}
    for id, a in pairs(W.lfg and W.lfg.activities or {}) do
      if categoryID == nil or a.categoryID == categoryID then out[#out + 1] = id end
    end
    table.sort(out)
    return out
  end,
  GetActivityInfoTable = function(activityID)
    local a = W.lfg and W.lfg.activities[activityID]
    if not a then return nil end
    local info = {}
    for k, v in pairs(a) do info[k] = v end
    return info
  end,
}

-- Abenteuerführer (EJ_*): Stufe wählen, dann Instanzen und Bosse je Index
local function ejTier() return W.ej.tiers[W.ej.current] end
local function ejInstance(journalId)
  for _, tier in ipairs(W.ej.tiers) do
    for _, list in ipairs({ tier.dungeons, tier.raids }) do
      for _, inst in ipairs(list) do
        if inst.id == journalId then return inst end
      end
    end
  end
end
function EJ_GetNumTiers() return #W.ej.tiers end
function EJ_GetCurrentTier() return W.ej.current end
function EJ_SelectTier(i) W.ej.current = i end
function EJ_GetTierInfo(i) return W.ej.tiers[i].name, "" end
function EJ_GetInstanceByIndex(index, isRaid)
  local inst = (isRaid and ejTier().raids or ejTier().dungeons)[index]
  if inst then return inst.id, inst.name, "", 0, 0, 0, 0, 0, "", true, inst.mapID end
end
-- name, description, bgImage, buttonImage1, loreImage, buttonImage2, dungeonAreaMapID, link, shouldDisplayDifficulty, mapID
function EJ_GetInstanceInfo(journalId)
  local inst = ejInstance(journalId)
  if inst then return inst.name, "", 0, 0, 0, 0, 0, "", true, inst.mapID end
end
-- name, description, journalEncounterID, rootSectionID, link, journalInstanceID, dungeonEncounterID, instanceID
function EJ_GetEncounterInfoByIndex(index, journalId)
  local inst = ejInstance(journalId)
  local b = inst and inst.bosses[index]
  if b then return b.name, "", index, 0, "", journalId, b.encounter, inst.mapID end
end
function UnitClass() return "Jäger", "HUNTER" end
function UnitLevel() return W.level end
function GetMoney() return W.money end
function IsInGuild() return W.inGuild end
function GetGuildInfo() if W.inGuild then return W.guild end end
function GetNumGuildMembers() return W.inGuild and #W.roster or 0 end
function GetGuildRosterInfo(i)
  local r = W.roster[i]
  return r[1], "Rang", 1, r[2], "Klasse", "Zone", "", "", r[3], 0, r[4]
end
function Ambiguate(name) return (name:gsub("%-.*", "")) end
function BreakUpLargeNumbers(n) return tostring(n) end

Enum = {
  SendAddonMessageResult = { Success = 0, AddonMessageThrottle = 3 },
  PlayerInteractionType = { GuildBanker = 10, Merchant = 5 },
}
function GetGuildBankMoney() return W.guildBank or 0 end
C_ChatInfo = {
  RegisterAddonMessagePrefix = function() end,
  SendAddonMessage = function(prefix, msg, channel, target)
    T.sent[#T.sent + 1] = { prefix = prefix, msg = msg, channel = channel, target = target }
    return T.sendResult
  end,
}
C_GuildInfo = { GuildRoster = function() end }

-- Berufe: Retail liefert Hauptberuf 1 und 2, Archäologie, Angeln, Kochen; Clients mit Erster Hilfe einen
-- Wert mehr. W.professions = Indizes (mit Lücken), W.professionInfo[i] = { Name, Skill }.
function GetProfessions()
  local p = W.professions or {}
  return p[1], p[2], p[3], p[4], p[5], p[6]
end
function GetProfessionInfo(i)
  local p = W.professionInfo and W.professionInfo[i]
  if p then return p[1], 136000, p[2], 300, 0, 0, 0, 0 end
end

C_UI = { Reload = function() T.reloaded = true end }
C_AddOns = { GetAddOnMetadata = function() return "0.0.0" end }
UISpecialFrames = {}
function InCombatLockdown() return W.combat == true end
function GetCursorPosition() return W.cursor[1], W.cursor[2] end
function GetMinimapShape() return "ROUND" end
-- Optionsmenü (Retail ab 10.0): merkt sich, was registriert und geöffnet wurde.
Settings = {
  RegisterCanvasLayoutCategory = function(frame, name)
    T.category = { frame = frame, name = name, GetID = function() return 42 end }
    return T.category
  end,
  RegisterAddOnCategory = function(c) T.addonCategory = c end,
  OpenToCategory = function(id)
    assert(id == 42, "OpenToCategory mit falscher ID")
    T.openedOptions = true
    T.category.frame:Show()
  end,
}
SlashCmdList = {}

-- Widgets ------------------------------------------------------------------

WIDGETS, FRAMES = {}, {}

-- Grobe Textmaße: 6 px pro Zeichen, 14 px pro Zeile.
local function lineCount(fs)
  if not fs._text or fs._text == "" then return 0 end
  if not fs._width then return 1 end
  local plain = fs._text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  return math.max(1, math.ceil(#plain * 6 / fs._width))
end

local M = {}
M.Region = {
  ClearAllPoints = function() end,
  SetSize = function(self, w, h) self._w, self._h = w, h end,
  SetWidth = function(self, w) self._w, self._width = w, w end,
  SetHeight = function(self, h) self._h = h end,
  GetWidth = function(self) return self._w or 0 end,
  GetHeight = function(self) return self._h or 0 end,
  GetCenter = function(self) return self._cx or 0, self._cy or 0 end,
  GetEffectiveScale = function() return 1 end,
  SetPoint = function(self, point, rel, relPoint, x, y)
    if point == "CENTER" and type(x) == "number" then self._x, self._y = x, y end
  end,
  Show = function(self) self:SetShown(true) end,
  Hide = function(self) self:SetShown(false) end,
  IsShown = function(self) return self._shown ~= false end,
  SetShown = function(self, v)
    local was = self:IsShown()
    self._shown = v and true or false
    local scripts = self._scripts or {}
    if v and not was and scripts.OnShow then scripts.OnShow(self) end
    if not v and was and scripts.OnHide then scripts.OnHide(self) end
  end,
}
M.Texture = {
  SetTexture = function() end,
  SetVertexColor = function(self, r, g, b) assert(r and g and b, "SetVertexColor ohne Farbe") end,
}
M.FontString = {
  SetTextColor = function(self, r, g, b) assert(r and g and b, "SetTextColor ohne Farbe") end,
  SetJustifyH = function() end,
  SetJustifyV = function() end,
  SetWordWrap = function() end,
  SetSpacing = function() end,
  SetText = function(self, t)
    assert(type(t) == "string" or type(t) == "number", "SetText mit " .. type(t))
    self._text = tostring(t)
  end,
  GetText = function(self) return self._text end,
  GetStringWidth = function(self) return #(self._text or "") * 6 end,
  GetStringHeight = function(self) return lineCount(self) * 14 end,
}
M.Frame = {
  SetFrameStrata = function() end,
  SetFrameLevel = function() end,
  SetToplevel = function() end,
  SetClampedToScreen = function() end,
  SetMovable = function() end,
  EnableMouse = function() end,
  RegisterForDrag = function() end,
  StartMoving = function() end,
  StopMovingOrSizing = function() end,
  SetHitRectInsets = function() end,
  SetScript = function(self, name, fn) self._scripts = self._scripts or {} self._scripts[name] = fn end,
  GetName = function(self) return self._name end,
  RegisterEvent = function(self, e) self._events = self._events or {} self._events[e] = true end,
  CreateTexture = function(self) return Widget("Texture", self) end,
  CreateFontString = function(self) return Widget("FontString", self) end,
}
M.Backdrop = {
  SetBackdrop = function(_, b) assert(type(b) == "table") end,
  SetBackdropColor = function(_, r, g, b) assert(r and g and b) end,
  SetBackdropBorderColor = function(_, r, g, b) assert(r and g and b) end,
}
M.Button = {
  SetNormalFontObject = function(self) self._fs = self._fs or Widget("FontString", self) end,
  SetDisabledFontObject = function() end,
  RegisterForClicks = function() end,
  SetHighlightTexture = function(_, tex) assert(type(tex) == "string") end,
  SetText = function(self, t) self._fs = self._fs or Widget("FontString", self) self._fs:SetText(t) end,
  GetText = function(self) return self._fs and self._fs._text end,
  GetFontString = function(self) return self._fs end,
  Enable = function(self) self._enabled = true end,
  Disable = function(self) self._enabled = false end,
  IsEnabled = function(self) return self._enabled ~= false end,
  Click = function(self)
    if self:IsEnabled() and self._scripts and self._scripts.OnClick then self._scripts.OnClick(self, "LeftButton") end
  end,
}
M.CheckButton = {
  SetChecked = function(self, v) self._checked = v and true or false end,
  GetChecked = function(self) return self._checked == true end,
  Click = function(self)
    self._checked = not self._checked
    M.Button.Click(self)
  end,
}
M.GameTooltip = { SetOwner = function() end, SetText = function() end, AddLine = function() end }
M.EditBox = {
  SetAutoFocus = function() end,
  SetMaxLetters = function() end,
  SetFontObject = function() end,
  SetText = function(self, t) assert(type(t) == "string", "SetText mit " .. type(t)) self._text = t end,
  GetText = function(self) return self._text or "" end,
  SetFocus = function(self) self._focus = true end,
  ClearFocus = function(self) self._focus = false end,
  HasFocus = function(self) return self._focus == true end,
  HighlightText = function() end,
}

local CHAINS = {
  Texture = { "Texture", "Region" },
  FontString = { "FontString", "Region" },
  Frame = { "Frame", "Region" },
  Button = { "Button", "Frame", "Region" },
  CheckButton = { "CheckButton", "Button", "Frame", "Region" },
  GameTooltip = { "GameTooltip", "Frame", "Region" },
  EditBox = { "EditBox", "Frame", "Region" },
}
local TEMPLATES = { BackdropTemplate = true, UIPanelCloseButton = true, UIPanelButtonTemplate = true, UICheckButtonTemplate = true, InputBoxTemplate = true }

function Widget(kind, parent, extra)
  local w = { _kind = kind, _parent = parent }
  WIDGETS[#WIDGETS + 1] = w
  if kind ~= "Texture" and kind ~= "FontString" then FRAMES[#FRAMES + 1] = w end
  return setmetatable(w, { __index = function(_, k)
    -- Eigene Felder (klein geschrieben) sind wie in WoW einfach nil.
    if type(k) ~= "string" or not k:match("^%u") then return nil end
    for _, part in ipairs(CHAINS[kind]) do
      if M[part][k] then return M[part][k] end
    end
    for _, part in ipairs(extra or {}) do
      if M[part][k] then return M[part][k] end
    end
    error(("%s hat keine Methode %s"):format(kind, k), 2)
  end })
end

function CreateFrame(kind, name, parent, template)
  assert(not template or TEMPLATES[template], "unbekanntes Template " .. tostring(template))
  local w = Widget(kind, parent, template == "BackdropTemplate" and { "Backdrop" } or nil)
  w._name = name
  if name then _G[name] = w end
  return w
end

UIParent = CreateFrame("Frame", "UIParent")
GameTooltip = CreateFrame("GameTooltip", "GameTooltip")
Minimap = CreateFrame("Frame", "Minimap", UIParent)
Minimap:SetSize(140, 140)

-- Hilfen für die Tests -----------------------------------------------------

function fire(event, ...)
  for _, f in ipairs(FRAMES) do
    if f._events and f._events[event] then f._scripts.OnEvent(f, event, ...) end
  end
end

-- Gesendete Nachrichten abholen und leeren.
function takeSent()
  local out = T.sent
  T.sent = {}
  return out
end
