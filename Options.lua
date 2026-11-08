-- Symbol an der Minimap und Einstellungen (Spielmenü → Optionen → AddOns).
-- Das Symbol lässt sich ausblenden; /gchr und das Addon-Menü an der Minimap gehen
-- immer. Logik und Zustand in GildenChronik.lua, das Fenster in UI.lua.

local ADDON, ns = ...

local ICON = "Interface\\AddOns\\" .. ADDON .. "\\media\\yak"
local GOLD = { 0.878, 0.706, 0.345 }   -- gold-400
local MUTED = { 0.690, 0.639, 0.541 }  -- ink-400
local atan2 = math.atan2 or math.atan  -- Lua 5.1 (WoW) bzw. 5.3 (Tests)

-- Symbol an der Minimap ----------------------------------------------------
-- Aufbau wie bei LibDBIcon, damit es zu den anderen Symbolen passt.

local mm = CreateFrame("Button", "GildenChronikMinimapButton", Minimap)
mm:SetSize(31, 31)
mm:SetFrameStrata("MEDIUM")
mm:SetFrameLevel(8)
mm:RegisterForClicks("LeftButtonUp", "RightButtonUp")
mm:RegisterForDrag("LeftButton")
mm:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
mm:Hide() -- bis PLAYER_LOGIN, dann laut Einstellung

local mmBorder = mm:CreateTexture(nil, "OVERLAY")
mmBorder:SetSize(53, 53)
mmBorder:SetPoint("TOPLEFT")
mmBorder:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

local mmBack = mm:CreateTexture(nil, "BACKGROUND")
mmBack:SetSize(20, 20)
mmBack:SetPoint("TOPLEFT", 7, -5)
mmBack:SetTexture("Interface\\Minimap\\UI-Minimap-Background")

local mmIcon = mm:CreateTexture(nil, "ARTWORK")
mmIcon:SetSize(18, 18)
mmIcon:SetPoint("TOPLEFT", 6, -6)
mmIcon:SetTexture(ICON)

-- Am Rand der Minimap, Winkel in Grad (0 = rechts, gegen den Uhrzeigersinn).
local function place()
  local a = math.rad(ns.db().minimap.angle or 225)
  local x, y = math.cos(a), math.sin(a)
  local r = Minimap:GetWidth() / 2 + 5
  if GetMinimapShape and GetMinimapShape() == "SQUARE" then
    -- eckige Minimap: an der Kante entlang statt auf dem Kreis
    x = math.max(-1, math.min(1, x * 1.41421))
    y = math.max(-1, math.min(1, y * 1.41421))
  end
  mm:ClearAllPoints()
  mm:SetPoint("CENTER", Minimap, "CENTER", x * r, y * r)
end

local function onDrag()
  local mx, my = Minimap:GetCenter()
  local px, py = GetCursorPosition()
  local scale = Minimap:GetEffectiveScale()
  ns.db().minimap.angle = math.floor(math.deg(atan2(py / scale - my, px / scale - mx)) + 0.5)
  place()
end

mm:SetScript("OnDragStart", function(self)
  GameTooltip:Hide()
  self:SetScript("OnUpdate", onDrag)
end)
mm:SetScript("OnDragStop", function(self)
  self:SetScript("OnUpdate", nil)
end)
mm:SetScript("OnClick", function(_, button)
  if button == "RightButton" then
    ns.openOptions()
  elseif ns.toggleWindow then
    ns.toggleWindow()
  end
end)
mm:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  GameTooltip:SetText("Gilden-Chronik", unpack(GOLD))
  GameTooltip:AddLine("Linksklick: Status und Anleitung", 1, 1, 1)
  GameTooltip:AddLine("Rechtsklick: Einstellungen", 1, 1, 1)
  GameTooltip:AddLine("Ziehen: Symbol verschieben", MUTED[1], MUTED[2], MUTED[3])
  GameTooltip:Show()
end)
mm:SetScript("OnLeave", function() GameTooltip:Hide() end)

function ns.minimapShown()
  return not ns.db().minimap.hide
end

local refreshOptions

function ns.setMinimapShown(on)
  ns.db().minimap.hide = (not on) or nil
  if on then place() end
  mm:SetShown(on)
  if refreshOptions then refreshOptions() end
end

-- Einstellungen ------------------------------------------------------------

local panel = CreateFrame("Frame")
panel.name = "Gilden-Chronik" -- für das alte Optionsmenü (InterfaceOptions)
-- Das Optionsmenü ruft diese auf, falls vorhanden; alles wird sofort übernommen.
panel.OnCommit = function() end
panel.OnDefault = function() end
panel.OnRefresh = function() end

local TEXT_W = 560

local function text(font, color, width)
  local fs = panel:CreateFontString(nil, "OVERLAY", font)
  fs:SetTextColor(unpack(color))
  fs:SetJustifyH("LEFT")
  if width then
    fs:SetWidth(width)
    fs:SetWordWrap(true)
  end
  return fs
end

local title = text("GameFontNormalLarge", GOLD)
title:SetPoint("TOPLEFT", 16, -16)
title:SetText("Gilden-Chronik")

local intro = text("GameFontHighlight", MUTED, TEXT_W)
intro:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
intro:SetText("Status und Anleitung stehen im Fenster der Gilden-Chronik: /gchr, Linksklick auf das Yak-Symbol an der Minimap oder Eintrag im Addon-Menü.")

local openButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
openButton:SetText("Fenster öffnen")
openButton:SetSize(160, 24)
openButton:SetPoint("TOPLEFT", intro, "BOTTOMLEFT", 0, -10)
openButton:SetScript("OnClick", function()
  if ns.showWindow then ns.showWindow() end
end)

local checks = {}

-- Haken mit Beschriftung und Erklärung darunter; get/set lesen und schreiben die Einstellung.
local function option(label, note, get, set)
  local anchor = checks[#checks] and checks[#checks].note or openButton
  local cb = CreateFrame("CheckButton", nil, panel, "UICheckButtonTemplate")
  cb:SetSize(26, 26)
  cb:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", #checks == 0 and -2 or -28, -14)
  local fs = text("GameFontHighlight", { 1, 1, 1 })
  fs:SetPoint("LEFT", cb, "RIGHT", 2, 1)
  fs:SetText(label)
  cb:SetHitRectInsets(0, -(fs:GetStringWidth() + 4), 0, 0)
  local desc = text("GameFontHighlightSmall", MUTED, TEXT_W - 28)
  desc:SetPoint("TOPLEFT", cb, "BOTTOMLEFT", 28, 0)
  desc:SetText(note)
  cb:SetScript("OnClick", function(self)
    set(self:GetChecked() and true or false)
    refreshOptions()
  end)
  checks[#checks + 1] = { cb = cb, note = desc, get = get }
  return cb
end

option("Ich teile mein Gold mit der Chronik",
  "Aus: Dein Gold geht nicht an die Chronik, auch nicht an dein eigenes Konto. An: Das Addon schickt es mit, wer es in der Web-App sieht, legst du dort unter Mein Profil mit „Gold teilen“ fest. Gilt für alle Charaktere dieses Accounts, schon gesendetes Gold bleibt in der Chronik.",
  function() return ns.sharesGold() end,
  function(on) ns.setShareGold(on) end)

option("Symbol an der Minimap anzeigen",
  "Linksklick öffnet das Fenster, Rechtsklick diese Einstellungen, mit gedrückter Maustaste verschieben. Ohne Symbol geht es weiter über /gchr und das Addon-Menü an der Minimap.",
  function() return ns.minimapShown() end,
  function(on) ns.setMinimapShown(on) end)

option("Ich sammle für die Gilde",
  "Für die Person, die die Datei mit dem Sammler-Programm hochlädt. Die anderen Addons schicken dir dann ihren Stand und sehen, dass er angekommen ist. Nur mit Haken speichert das Addon auch die Meldungen der anderen und die Level aus der Gildenliste, ohne Haken nur deine eigenen Charaktere. Gilt für alle Charaktere dieses Accounts.",
  function() return ns.isCollector() end,
  function(on) ns.setCollector(on) end)

option("An /reload erinnern",
  "Nur als Sammler: alle 30 Minuten ein Hinweis im Chat, solange neue Einträge noch nicht in der Datei sind.",
  function() return ns.remindOn() end,
  function(on) ns.setRemind(on) end)

local account = text("GameFontHighlight", { 1, 1, 1 }, TEXT_W)
account:SetPoint("TOPLEFT", checks[#checks].note, "BOTTOMLEFT", -28, -18)

function refreshOptions()
  if not ns.db() then return end
  for _, c in ipairs(checks) do c.cb:SetChecked(c.get()) end
  local id = ns.profileId()
  account:SetText(id and ("Konto-ID: %s… (ändern im Fenster unter Konto)"):format(id:sub(1, 8))
    or "Konto-ID: noch keine. Im Fenster unter Konto einfügen, dann gehören deine Charaktere zu deinem Konto in der Web-App.")
end

panel:SetScript("OnShow", refreshOptions)

local category
if Settings and Settings.RegisterCanvasLayoutCategory then
  category = Settings.RegisterCanvasLayoutCategory(panel, panel.name)
  Settings.RegisterAddOnCategory(category)
elseif InterfaceOptions_AddCategory then
  InterfaceOptions_AddCategory(panel)
end

function ns.openOptions()
  if InCombatLockdown() then
    print("|cffe0b458Gilden-Chronik|r: Die Einstellungen öffnen sich nicht im Kampf.")
    return
  end
  if ns.hideWindow then ns.hideWindow() end
  if category and Settings.OpenToCategory then
    Settings.OpenToCategory(category:GetID())
  elseif InterfaceOptionsFrame_OpenToCategory then
    InterfaceOptionsFrame_OpenToCategory(panel)
  end
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:SetScript("OnEvent", function()
  ns.setMinimapShown(ns.minimapShown())
end)
