-- Fenster mit Status und Anleitung. Öffnet sich beim allerersten Start von selbst,
-- danach über /gchr, das Yak-Symbol an der Minimap (Options.lua) oder das Addon-Menü. Farben aus dem Theme der
-- Web-App (app/assets/css/main.css), Logik und Zustand in GildenChronik.lua. Zweite Seite
-- „Kills & Diagnose“ mit Boss-Versuchen, Postausgang, Messdaten und Log aus Kills.lua; die Zeile
-- „Verlauf“ zeigt den Postausgang der Levelaufstiege aus Verlauf.lua.

local ADDON, ns = ...

local WHITE = "Interface\\Buttons\\WHITE8X8"
local ICON = "Interface\\AddOns\\" .. ADDON .. "\\media\\yak"
local WIDTH, PAD, HEADER_H, LABEL_W = 540, 18, 76, 112
local TEXT_W = WIDTH - 2 * PAD

local C = {
  bg = { 0.082, 0.071, 0.055 },      -- ink-950
  panel = { 0.161, 0.137, 0.106 },   -- ink-800
  line = { 0.231, 0.196, 0.153 },    -- ink-700
  border = { 0.361, 0.263, 0.008 },  -- gold-800
  gold = { 0.878, 0.706, 0.345 },    -- gold-400
  text = { 0.945, 0.910, 0.831 },    -- ink-100
  muted = { 0.690, 0.639, 0.541 },   -- ink-400
  ok = { 0.561, 0.820, 0.541 },      -- moss-400
  warn = { 0.878, 0.706, 0.345 },    -- gold-400
  bad = { 0.878, 0.478, 0.373 },     -- ember-400
  idle = { 0.557, 0.502, 0.416 },    -- ink-500
}

local function hl(s)
  return "|cffe0b458" .. s .. "|r"
end

local function ago(t)
  local d = math.max(0, GetServerTime() - t)
  if d < 60 then return "gerade eben" end
  if d < 3600 then return ("vor %d Min."):format(math.floor(d / 60)) end
  if d < 86400 then return ("vor %d Std."):format(math.floor(d / 3600)) end
  local days = math.floor(d / 86400)
  return days == 1 and "vor 1 Tag" or ("vor %d Tagen"):format(days)
end
ns.ago = ago

-- Satzende ergänzen; „vor 3 Min.“ bringt den Punkt schon mit.
local function sentence(s)
  return s:sub(-1) == "." and s or s .. "."
end

local function num(n)
  return BreakUpLargeNumbers and BreakUpLargeNumbers(n) or tostring(n)
end

local function count(n, one, many)
  return num(n) .. " " .. (n == 1 and one or many)
end

local function short(name)
  if Ambiguate then return Ambiguate(name, "short") end
  return (name:gsub("%-.*", ""))
end

-- Rahmen -------------------------------------------------------------------

local f = CreateFrame("Frame", "GildenChronikFrame", UIParent, "BackdropTemplate")
f:SetSize(WIDTH, 600)
f:SetPoint("CENTER")
f:SetFrameStrata("HIGH")
f:SetToplevel(true)
f:SetClampedToScreen(true)
f:SetMovable(true)
f:EnableMouse(true)
f:RegisterForDrag("LeftButton")
f:SetScript("OnDragStart", function(self) self:StartMoving() end)
f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
f:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
f:SetBackdropColor(C.bg[1], C.bg[2], C.bg[3], 0.97)
f:SetBackdropBorderColor(unpack(C.border))
f:Hide()
tinsert(UISpecialFrames, f:GetName()) -- Escape schließt

local function text(font, color, width)
  local fs = f:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
  fs:SetTextColor(unpack(color or C.text))
  fs:SetJustifyH("LEFT")
  fs:SetJustifyV("TOP")
  if width then
    fs:SetWidth(width)
    fs:SetWordWrap(true)
    fs:SetSpacing(2)
  end
  return fs
end

local function line()
  local tex = f:CreateTexture(nil, "ARTWORK")
  tex:SetTexture(WHITE)
  tex:SetVertexColor(unpack(C.line))
  tex:SetHeight(1)
  return tex
end

local icon = f:CreateTexture(nil, "ARTWORK")
icon:SetSize(48, 48)
icon:SetPoint("TOPLEFT", PAD - 4, -12)
icon:SetTexture(ICON)

local title = text("GameFontNormalLarge", C.gold)
title:SetPoint("TOPLEFT", icon, "TOPRIGHT", 10, -8)
title:SetText("Gilden-Chronik")

local subtitle = text("GameFontHighlightSmall", C.muted)
subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -5)

local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", -2, -2)
close:SetScript("OnClick", function() f:Hide() end)

local headerLine = line()
headerLine:SetPoint("TOPLEFT", 1, -(HEADER_H - 8))
headerLine:SetPoint("TOPRIGHT", -1, -(HEADER_H - 8))

-- Status -------------------------------------------------------------------

local statusTitle = text("GameFontNormalSmall", C.gold)
statusTitle:SetText("STATUS")

local rows, rowByLabel = {}, {}
for _, label in ipairs({ "Gilde", "Konto", "Gold", "Sammler", "Deine Meldung", "Verlauf", "Empfangen", "Gesammelt", "Datei" }) do
  local row = {
    dot = f:CreateTexture(nil, "ARTWORK"),
    label = text("GameFontHighlight", C.muted, LABEL_W - 14),
    value = text("GameFontHighlight", C.text, TEXT_W - LABEL_W),
  }
  row.dot:SetTexture(WHITE)
  row.dot:SetSize(6, 6)
  row.label:SetText(label)
  rows[#rows + 1] = row
  rowByLabel[label] = row
end

local function setRow(label, color, value)
  rowByLabel[label].dot:SetVertexColor(unpack(color))
  rowByLabel[label].value:SetText(value)
end

local statusLine = line()

-- Anleitung ----------------------------------------------------------------

local guideTitle = text("GameFontNormalSmall", C.gold)
guideTitle:SetText("SO KOMMEN IHRE DATEN IN DIE CHRONIK")

local PATH = "World of Warcraft\\_<Version>_\\WTF\\Account\\<Account>\\SavedVariables\\GildenChronik.lua"

local GUIDE = {
  member = {
    "Das Addon meldet deinen Charakter beim Einloggen und bei jeder Änderung an die Gilde: Level, Berufe und Tode. Gold nur, wenn du unter " .. hl("Einstellungen") .. " " .. hl("Ich teile mein Gold mit der Chronik") .. " anhakst.",
    "Einmal die Konto-ID einfügen: In der Web-App unter Mein Profil auf " .. hl("ID kopieren") .. " klicken, oben unter " .. hl("Konto") .. " mit Strg+V einfügen und " .. hl("Übernehmen") .. ". Dann gehören deine Charaktere direkt zu deinem Konto.",
    "Ankommen müssen die Daten beim " .. hl("Sammler") .. ". Gleichzeitig spielen müsst ihr dafür nicht: Dein Addon merkt sich jeden Levelaufstieg mit deinem ganzen Stand (Gold, Berufe, Tode) und schickt diesen " .. hl("Verlauf") .. " dem Sammler, sobald er online ist, auch für deine anderen Charaktere. So fehlt in der Chronik kein Level.",
    "Ob deine Daten angekommen sind, steht oben unter " .. hl("Sammler") .. ". " .. hl("Jetzt senden") .. " schickt deinen Stand sofort.",
    "Bosskämpfe: In Dungeons und Raids merkt sich das Addon jeden Kill und Wipe mit deiner Gruppe und schickt ihn dem Sammler, sobald du wieder draußen bist. Weltbosse meldest du oben unter " .. hl("Kills & Diagnose") .. " mit " .. hl("Kill melden") .. ".",
    "Ohne Addon kennt die Chronik von einem Mitglied nur das Level aus der Gildenliste, kein Gold, keine Berufe, keine Tode und keine Bosskämpfe.",
  },
  collector = {
    "Eine Person pro Gilde reicht. Unten " .. hl("Ich sammle für die Gilde") .. " anhaken: Dann schicken dir alle Addons beim Einloggen ihren Stand und bekommen eine Bestätigung.",
    "Online sein, während die Gilde spielt. Mit Haken speichert dein Addon alles, was es hört, dazu die Level aus der Gildenliste. Ohne Haken speichert es nur deine eigenen Charaktere.",
    "Die Gildenliste merkt sich dein Addon auch ganz: Wer die Gilde verlässt oder entfernt wird, wird in der Web-App inaktiv. Dafür muss der Gildenname in der Web-App (Einstellungen) genau so lauten wie im Spiel.",
    hl("Speichern") .. ": WoW schreibt die Daten erst bei /reload oder beim Ausloggen in die Datei. Liegt Neues ungespeichert herum, erinnert das Addon alle 30 Minuten im Chat daran.",
    hl("Hochladen") .. ": Das Programm " .. hl("GildenChronik-Sammler.exe") .. " läuft auf deinem PC im Hintergrund, findet die Datei selbst und lädt Neues nach jedem Speichern in die Chronik der Web-App. Eintragen musst du dort nichts.",
    "Findet das Programm die Datei nicht, im Menü des Yak-Symbols unter " .. hl("Datei wählen") .. " auswählen. Sie liegt unter |cff7fb2e5" .. PATH .. "|r (für <Version> den Ordner deines Spiels, in Retail _retail_, für <Account> den Ordner deines Accounts).",
  },
}

local steps = {}
for key, list in pairs(GUIDE) do
  steps[key] = {}
  for i, s in ipairs(list) do
    local n = text("GameFontHighlight", C.gold)
    n:SetText(i .. ".")
    local body = text("GameFontHighlight", C.text, TEXT_W - 20)
    body:SetText(s)
    steps[key][i] = { n = n, body = body }
  end
end

local tab -- "member" oder "collector"
local refresh

local function makeTab(label, key)
  local b = CreateFrame("Button", nil, f)
  local fs = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  fs:SetPoint("TOPLEFT")
  fs:SetText(label)
  b.label = fs
  b:SetSize(fs:GetStringWidth() + 2, 22)
  local bar = b:CreateTexture(nil, "ARTWORK")
  bar:SetTexture(WHITE)
  bar:SetHeight(2)
  bar:SetPoint("BOTTOMLEFT")
  bar:SetPoint("BOTTOMRIGHT")
  b.bar = bar
  b.key = key
  b:SetScript("OnClick", function()
    tab = key
    refresh()
  end)
  b:SetScript("OnEnter", function(self) self.label:SetTextColor(unpack(C.text)) end)
  b:SetScript("OnLeave", function(self)
    self.label:SetTextColor(unpack(tab == self.key and C.gold or C.muted))
  end)
  return b
end

local tabs = { makeTab("Alle Mitglieder", "member"), makeTab("Sammler", "collector") }

local guideLine = line()

-- Fußzeile -----------------------------------------------------------------

local function button(label, tip, onClick)
  local b = CreateFrame("Button", nil, f, "BackdropTemplate")
  b:SetBackdrop({ bgFile = WHITE, edgeFile = WHITE, edgeSize = 1 })
  b:SetBackdropColor(unpack(C.panel))
  b:SetBackdropBorderColor(unpack(C.border))
  b:SetNormalFontObject("GameFontHighlight")
  b:SetDisabledFontObject("GameFontDisable")
  b:SetText(label)
  b:SetSize(b:GetFontString():GetStringWidth() + 28, 26)
  b:SetScript("OnClick", onClick)
  b:SetScript("OnEnter", function(self)
    self:SetBackdropBorderColor(unpack(C.gold))
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(label, unpack(C.gold))
    GameTooltip:AddLine(tip, C.text[1], C.text[2], C.text[3], true)
    GameTooltip:Show()
  end)
  b:SetScript("OnLeave", function(self)
    self:SetBackdropBorderColor(unpack(C.border))
    GameTooltip:Hide()
  end)
  return b
end

local saveButton = button("Speichern (/reload)",
  "Lädt die Oberfläche neu. Dabei schreibt WoW die gesammelten Daten in die Datei, die der Sammler auf dem PC hochlädt.",
  function()
    if C_UI and C_UI.Reload then C_UI.Reload() else ReloadUI() end
  end)

local sendButton
sendButton = button("Jetzt senden",
  "Schickt deinen Stand sofort an die Gilde. Sonst passiert das beim Einloggen und bei jeder Änderung von selbst.",
  function()
    if not ns.sendNow() then return end
    sendButton.cooling = true
    sendButton:Disable()
    C_Timer.After(10, function()
      sendButton.cooling = nil
      if IsInGuild() then sendButton:Enable() end
    end)
  end)

local check = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
check:SetSize(26, 26)
local checkLabel = text("GameFontHighlight", C.text)
checkLabel:SetPoint("LEFT", check, "RIGHT", 2, 1)
checkLabel:SetText("Ich sammle für die Gilde")
check:SetHitRectInsets(0, -(checkLabel:GetStringWidth() + 4), 0, 0)
check:SetScript("OnClick", function(self)
  local on = self:GetChecked() and true or false
  ns.setCollector(on)
  if on then tab = "collector" end
  refresh()
end)
check:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_TOP")
  GameTooltip:SetText("Sammler", unpack(C.gold))
  GameTooltip:AddLine("Für die Person, die die Datei hochlädt. Die anderen Addons schicken dir dann ihren Stand und sehen, dass er angekommen ist. Gilt für alle Charaktere dieses Accounts.",
    C.text[1], C.text[2], C.text[3], true)
  GameTooltip:Show()
end)
check:SetScript("OnLeave", function() GameTooltip:Hide() end)

local footerLine = line()

local optionsButton = button("Einstellungen",
  "Symbol an der Minimap, Sammler und Erinnerung an /reload. Auch im Spielmenü unter Optionen → AddOns.",
  function()
    if ns.openOptions then ns.openOptions() end
  end)
optionsButton:SetSize(optionsButton:GetWidth() - 8, 22)
optionsButton:SetPoint("RIGHT", close, "LEFT", -4, 0)

local page = "status" -- oder "kills"

-- Wechselt zwischen Status und „Kills & Diagnose“; die Beschriftung nennt die andere Seite.
local pageButton = button("Kills & Diagnose",
  "Deine letzten Bosskämpfe, was noch zum Sammler muss, Messdaten und Log. Zurück zu Status und Anleitung mit demselben Knopf.",
  function()
    page = page == "kills" and "status" or "kills"
    refresh()
  end)
pageButton:SetSize(pageButton:GetWidth() - 8, 22)
pageButton:SetPoint("RIGHT", optionsButton, "LEFT", -6, 0)

-- Web-App-Konto: ID aus „Mein Profil“ einfügen ----------------------------

local accountNote -- Rückmeldung nach „Übernehmen“: { Farbe, Text }, bis das Fenster zugeht

local idBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
idBox:SetAutoFocus(false)
idBox:SetMaxLetters(64)
idBox:SetFontObject("GameFontHighlight")
idBox:SetSize(TEXT_W - LABEL_W - 120, 24)

local function applyId()
  local ok = ns.setProfileId(idBox:GetText())
  idBox:ClearFocus()
  if not ok then
    accountNote = { C.bad, "Das ist keine gültige ID. In der Web-App unter Mein Profil auf „ID kopieren“ klicken und hier mit Strg+V einfügen." }
  elseif ns.profileId() then
    accountNote = { C.ok, "Gespeichert. Beim nächsten Upload des Sammlers gehören deine Charaktere zu deinem Konto." }
  else
    accountNote = { C.idle, "ID entfernt." }
  end
  refresh()
end

idBox:SetScript("OnEnterPressed", applyId)
idBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

local idButton = button("Übernehmen",
  "Speichert die Konto-ID aus der Web-App für alle Charaktere dieses Accounts. Sie geht mit deiner nächsten Meldung an den Sammler.",
  applyId)

-- Kills & Diagnose --------------------------------------------------------

local TONE = { ok = C.ok, warn = C.warn, bad = C.bad, idle = C.idle }
local KILL_ROWS, LOG_LINES = 5, 6

local killsTitle = text("GameFontNormalSmall", C.gold)
killsTitle:SetText("LETZTE BOSSKÄMPFE")
local killsEmpty = text("GameFontHighlight", C.muted, TEXT_W)
killsEmpty:SetText("Noch keine Bosskämpfe. Kills und Wipes in Dungeons und Raids merkt sich das Addon von selbst. Weltbosse meldest du mit " .. hl("Kill melden") .. " (den toten Boss im Ziel) oder mit /gchr kill <Name>.")
local killNote -- Rückmeldung nach „Kill melden“ bzw. „Katalog neu einlesen“: { Farbe, Text }
local killNoteText = text("GameFontHighlight", C.text, TEXT_W)
local killsLine = line()
local diagTitle = text("GameFontNormalSmall", C.gold)
diagTitle:SetText("DIAGNOSE")
local diagLine = line()
local logTitle = text("GameFontNormalSmall", C.gold)
logTitle:SetText("LOG")
local logEmpty = text("GameFontHighlightSmall", C.muted, TEXT_W)
logEmpty:SetText("Leer.")

-- Zeilen wie im Status (Punkt, Bezeichnung, Wert), so viele wie gebraucht
local function makeRow()
  local row = {
    dot = f:CreateTexture(nil, "ARTWORK"),
    label = text("GameFontHighlight", C.muted, LABEL_W - 14),
    value = text("GameFontHighlight", C.text, TEXT_W - LABEL_W),
  }
  row.dot:SetTexture(WHITE)
  row.dot:SetSize(6, 6)
  return row
end

local killRows, diagRows, logLines = {}, {}, {}

local function rowAt(list, i)
  list[i] = list[i] or makeRow()
  return list[i]
end

local function showRow(row, on)
  row.dot:SetShown(on)
  row.label:SetShown(on)
  row.value:SetShown(on)
end

local function killNoteFrom(ok, msg)
  killNote = { ok and C.ok or C.warn, msg }
  refresh()
end

local reportButton = button("Kill melden",
  "Für Weltbosse und alles, was das Addon nicht von selbst merkt: den toten Boss ins Ziel nehmen und klicken. Ohne Ziel /gchr kill <Name>.",
  function() killNoteFrom(ns.reportKill()) end)

local catalogButton = button("Katalog neu einlesen",
  "Liest Dungeons und Raids aus der Gruppensuche des Spiels (Level, Spielerzahl), in Retail auch die Bosse aus dem Abenteuerführer. Passiert sonst nach jedem Login von selbst.",
  function() killNoteFrom(ns.scanCatalog(true)) end)

local clearLogButton = button("Log leeren",
  "Löscht das Log auf diesem PC. Kills und Postausgang bleiben.",
  function()
    ns.clearLog()
    refresh()
  end)

local killsOnly = { killsTitle, killsEmpty, killNoteText, killsLine, diagTitle, diagLine, logTitle, logEmpty,
  reportButton, catalogButton, clearLogButton }

local function killText(entry)
  local kill = entry.kill
  local parts = { kill.n or "Unbekannter Boss" }
  if kill.inm then parts[#parts + 1] = kill.inm end
  local members = 0
  for _ in (kill.g or ""):gmatch("[^,]+") do members = members + 1 end
  parts[#parts + 1] = count(members, "Charakter", "Charaktere")
  parts[#parts + 1] = ago(kill.t or kill.rt or GetServerTime())
  if not entry.own then
    parts[#parts + 1] = "von " .. short(kill.r or "?")
  elseif entry.open then
    parts[#parts + 1] = "wartet im Postausgang"
  elseif ns.isCollector() then
    parts[#parts + 1] = "in deiner Datei"
  else
    parts[#parts + 1] = "beim Sammler"
  end
  return sentence(table.concat(parts, " · "))
end

-- Postausgang als erste Zeile der Diagnose
local function outboxLine(view)
  if ns.isCollector() then
    return { "Postausgang", "Du sammelst: Deine Boss-Versuche landen direkt in deiner Datei.", "ok" }
  elseif view.sending then
    return { "Postausgang", "Wird gerade an den Sammler gesendet.", "ok" }
  elseif view.open == 0 then
    return { "Postausgang", "Leer. Alles ist beim Sammler.", "ok" }
  end
  return { "Postausgang", ("%s %s. Das Addon schickt sie dem Sammler, sobald er online ist und du nicht in einer Instanz oder im Kampf bist.")
    :format(count(view.open, "Boss-Versuch", "Boss-Versuche"), view.open == 1 and "wartet" or "warten"), "warn" }
end

local function updateKills()
  local view = ns.killsView(KILL_ROWS)
  for i, entry in ipairs(view.kills) do
    local row = rowAt(killRows, i)
    row.dot:SetVertexColor(unpack(entry.kill.ok and C.ok or C.bad))
    row.label:SetText(entry.kill.ok and "Kill" or "Wipe")
    row.value:SetText(killText(entry))
  end
  for i, row in ipairs(killRows) do showRow(row, i <= #view.kills) end
  killsEmpty:SetShown(#view.kills == 0)

  killNoteText:SetShown(killNote ~= nil)
  if killNote then
    killNoteText:SetTextColor(unpack(killNote[1]))
    killNoteText:SetText(killNote[2])
  end

  local lines = ns.diagLines()
  table.insert(lines, 1, outboxLine(view))
  for i, l in ipairs(lines) do
    local row = rowAt(diagRows, i)
    row.dot:SetVertexColor(unpack(TONE[l[3]] or C.idle))
    row.label:SetText(l[1])
    row.value:SetText(sentence(l[2]))
  end
  for i, row in ipairs(diagRows) do showRow(row, i <= #lines) end

  local log = ns.logTail(LOG_LINES)
  for i, l in ipairs(log) do
    logLines[i] = logLines[i] or text("GameFontHighlightSmall", C.muted, TEXT_W)
    logLines[i]:SetText(l)
  end
  for i, fs in ipairs(logLines) do fs:SetShown(i <= #log) end
  logEmpty:SetShown(#log == 0)
end

-- Inhalt -------------------------------------------------------------------

local function collectorStatus(inGuild)
  local st = ns.state
  if not inGuild then return C.idle, "–" end
  if ns.isCollector() then
    local n = 0
    for _ in pairs(st.acked) do n = n + 1 end
    if n == 0 then return C.ok, "Du sammelst. In dieser Sitzung hat sich noch niemand gemeldet." end
    return C.ok, ("Du sammelst. In dieser Sitzung hast du %s den Empfang bestätigt.")
      :format(count(n, "Mitglied", "Mitgliedern"))
  end
  -- Bester bekannter Sammler: bestätigt > online > offline, dann zuletzt gehört.
  -- Online heißt: laut Gildenliste oder in den letzten 5 Minuten gehört (die
  -- Gildenliste hinkt nach einem Login etwas hinterher).
  local online, now = ns.guildOnline(), GetServerTime()
  local best, bestRank, bestT
  for name, t in pairs(ns.db().collectors) do
    local isOnline = online[name] or now - t < 300
    local rank = (not isOnline and 1) or (st.confirmed[name] and 3) or 2
    if not best or rank > bestRank or (rank == bestRank and t > bestT) then
      best, bestRank, bestT = name, rank, t
    end
  end
  if not best then
    return C.bad, "Noch kein Sammler bekannt. Ohne Sammler kommt nichts in die Chronik. Wer hochlädt, setzt unten den Haken."
  end
  local who = short(best)
  if bestRank == 3 then
    return C.ok, ("%s sammelt und hat deine Daten %s bestätigt."):format(who, ago(st.confirmed[best]))
  elseif bestRank == 2 then
    return C.ok, ("%s sammelt und ist online. Deine Meldungen kommen an."):format(who)
  end
  return C.warn, ("%s sammelt, ist aber offline (zuletzt gehört %s). Kommt %s online, schickt dein Addon deinen Stand und den Verlauf von selbst.")
    :format(who, ago(bestT), who)
end

-- Postausgang des Verlaufs (Verlauf.lua): Levelaufstiege und Tagesstände für den Sammler
local function historyStatus(inGuild)
  if not ns.historyView then
    return C.warn, "Kommt erst nach einem Neustart von WoW, /reload reicht dafür nicht."
  end
  if not inGuild then return C.idle, "–" end
  local h = ns.historyView()
  if ns.isCollector() then
    local s = h.stats
    if s.ok + s.dup == 0 then return C.ok, "Du sammelst: Dein eigener Verlauf steht direkt in deiner Datei." end
    return C.ok, ("Du sammelst. In dieser Sitzung von anderen nachgeliefert: %s, dazu %s schon da.")
      :format(count(s.ok, "Stand", "Stände"), count(s.dup, "Stand", "Stände"))
  end
  if h.open == 0 then return C.ok, "Alles beim Sammler, jeder Levelaufstieg ist angekommen." end
  if h.sending then
    return C.ok, ("Wird gerade an den Sammler gesendet (%s offen)."):format(count(h.open, "Stand", "Stände"))
  end
  local levels = h.levels > 0 and (", davon " .. count(h.levels, "Levelaufstieg", "Levelaufstiege")) or ""
  return C.warn, ("%s%s %s auf den Sammler. Dein Addon schickt sie, sobald er online ist und du nicht in einer Instanz oder im Kampf bist.")
    :format(count(h.open, "Stand", "Stände"), levels, h.open == 1 and "wartet" or "warten")
end

local function update()
  local db, st = ns.db(), ns.state
  local inGuild = IsInGuild()
  local guild = inGuild and (GetGuildInfo("player") or db.guild)

  local version = (C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata)(ADDON, "Version") or ""
  -- Voller Name, in Forever mit Nachnamen: so steht er auch in der Chronik
  subtitle:SetText(("%s · %s · Version %s"):format(short(ns.me() or ""), GetRealmName() or "", version))

  if inGuild then
    setRow("Gilde", C.ok, guild or "wird geladen")
  else
    setRow("Gilde", C.bad, "Keine Gilde. Das Addon sendet und sammelt nur in einer Gilde.")
  end

  local id = ns.profileId()
  if accountNote then
    setRow("Konto", accountNote[1], accountNote[2])
  elseif id then
    setRow("Konto", C.ok, ("ID gespeichert (%s…). Über den Sammler gehören deine Charaktere damit zu deinem Konto in der Web-App."):format(id:sub(1, 8)))
  else
    setRow("Konto", C.warn, "Nicht verknüpft. In der Web-App unter Mein Profil auf „ID kopieren“ klicken und die ID hier mit Strg+V einfügen.")
  end
  if not idBox:HasFocus() then idBox:SetText(id or "") end

  if ns.sharesGold() then
    setRow("Gold", C.ok, "Geht mit deinen Meldungen an die Chronik. Wer es sieht, legst du in der Web-App unter Mein Profil mit „Gold teilen“ fest.")
  else
    setRow("Gold", C.idle, "Wird nicht gesendet. Zum Teilen oben unter Einstellungen „Ich teile mein Gold mit der Chronik“ anhaken.")
  end

  setRow("Sammler", collectorStatus(inGuild))

  if not inGuild then
    setRow("Deine Meldung", C.idle, "–")
  elseif st.blockedAt and (not st.sentAt or st.blockedAt > st.sentAt) then
    setRow("Deine Meldung", C.warn, ("Von WoW blockiert %s (Kampf oder Instanz). Die nächste Meldung holt es nach.")
      :format(ago(st.blockedAt)))
  elseif st.sentAt then
    setRow("Deine Meldung", C.ok, sentence("Gesendet " .. ago(st.sentAt)))
  else
    setRow("Deine Meldung", C.idle, "Geht ein paar Sekunden nach dem Einloggen raus.")
  end

  setRow("Verlauf", historyStatus(inGuild))

  if st.heardCount > 0 then
    setRow("Empfangen", C.ok, sentence(("%s mit Addon in dieser Sitzung, zuletzt %s %s")
      :format(count(st.heardCount, "Mitglied", "Mitglieder"), short(st.lastHeard), ago(st.heard[st.lastHeard]))))
  else
    setRow("Empfangen", C.idle, "In dieser Sitzung noch niemand. Dein Addon hört nur Mitglieder, die das Addon haben und gerade online sind.")
  end

  local chars = 0
  for _ in pairs(db.latest) do chars = chars + 1 end
  setRow("Gesammelt", chars > 0 and C.ok or C.idle, ("%s, %s.")
    :format(count(chars, "Charakter", "Charaktere"), count(#db.snapshots, "Eintrag", "Einträge")))

  -- Die Datei zählt nur beim Sammler; die anderen müssen nichts speichern.
  local saved = db.savedAt and sentence("Zuletzt gespeichert " .. ago(db.savedAt)) or "Noch nie gespeichert."
  if st.newEntries == 0 then
    setRow("Datei", C.ok, saved)
  elseif ns.isCollector() then
    setRow("Datei", C.warn, ("%s Neu seit dem Laden: %s. Speichern mit /reload.")
      :format(saved, count(st.newEntries, "Eintrag", "Einträge")))
  else
    setRow("Datei", C.idle, ("%s Neu seit dem Laden: %s. Wichtig nur für den Sammler.")
      :format(saved, count(st.newEntries, "Eintrag", "Einträge")))
  end

  check:SetChecked(ns.isCollector())
  if not inGuild then sendButton:Disable() elseif not sendButton.cooling then sendButton:Enable() end
end

local function height(fs)
  return math.max(fs:GetStringHeight() or 0, 12)
end

local function at(region, x, y)
  region:ClearAllPoints()
  region:SetPoint("TOPLEFT", f, "TOPLEFT", x, y)
end

local function span(tex, y)
  tex:ClearAllPoints()
  tex:SetPoint("TOPLEFT", f, "TOPLEFT", 1, y)
  tex:SetPoint("TOPRIGHT", f, "TOPRIGHT", -1, y)
end

local function placeRow(row, y)
  at(row.dot, PAD, y - 5)
  at(row.label, PAD + 14, y)
  at(row.value, PAD + LABEL_W, y)
  return y - math.max(height(row.label), height(row.value)) - 8
end

-- Seite „Kills & Diagnose“ ab y; liefert das untere Ende
local function layoutKills(y)
  at(killsTitle, PAD, y)
  y = y - height(killsTitle) - 10
  if killsEmpty:IsShown() then
    at(killsEmpty, PAD, y)
    y = y - height(killsEmpty) - 8
  end
  for _, row in ipairs(killRows) do
    if row.value:IsShown() then y = placeRow(row, y) end
  end
  if killNoteText:IsShown() then
    at(killNoteText, PAD, y)
    y = y - height(killNoteText) - 8
  end

  y = y - 6
  span(killsLine, y)
  y = y - 16
  at(diagTitle, PAD, y)
  y = y - height(diagTitle) - 10
  for _, row in ipairs(diagRows) do
    if row.value:IsShown() then y = placeRow(row, y) end
  end

  y = y - 6
  span(diagLine, y)
  y = y - 16
  at(logTitle, PAD, y)
  y = y - height(logTitle) - 8
  if logEmpty:IsShown() then
    at(logEmpty, PAD, y)
    y = y - height(logEmpty) - 4
  end
  for _, fs in ipairs(logLines) do
    if fs:IsShown() then
      at(fs, PAD, y)
      y = y - height(fs) - 4
    end
  end

  y = y - 10
  span(footerLine, y)
  y = y - 14
  at(reportButton, PAD, y)
  catalogButton:ClearAllPoints()
  catalogButton:SetPoint("LEFT", reportButton, "RIGHT", 8, 0)
  clearLogButton:ClearAllPoints()
  clearLogButton:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, y)
  return y - 26 - PAD
end

local statusOnly -- Regionen der Statusseite, gefüllt beim ersten Layout

-- Alles von oben nach unten setzen; die Höhe des Fensters ergibt sich aus den Texten.
local function layout()
  if not statusOnly then
    statusOnly = { statusTitle, statusLine, guideTitle, guideLine, idBox, idButton, check, checkLabel, saveButton, sendButton }
    for _, row in ipairs(rows) do
      statusOnly[#statusOnly + 1] = row.dot
      statusOnly[#statusOnly + 1] = row.label
      statusOnly[#statusOnly + 1] = row.value
    end
    for _, b in ipairs(tabs) do statusOnly[#statusOnly + 1] = b end
  end
  local kills = page == "kills"
  for _, r in ipairs(statusOnly) do r:SetShown(not kills) end
  for _, r in ipairs(killsOnly) do r:SetShown(kills) end
  pageButton:SetText(kills and "Status" or "Kills & Diagnose")
  pageButton:SetSize(pageButton:GetFontString():GetStringWidth() + 20, 22)
  if kills then
    for _, list in pairs(steps) do
      for _, s in ipairs(list) do
        s.n:Hide()
        s.body:Hide()
      end
    end
    -- killsEmpty, Notiz und Log-Hinweis zeigt updateKills() je nach Inhalt
    updateKills()
    f:SetHeight(-layoutKills(-HEADER_H))
    return
  end
  for _, list in ipairs({ killRows, diagRows }) do
    for _, row in ipairs(list) do showRow(row, false) end
  end
  for _, fs in ipairs(logLines) do fs:Hide() end

  local y = -HEADER_H
  at(statusTitle, PAD, y)
  y = y - height(statusTitle) - 10
  for _, row in ipairs(rows) do
    y = placeRow(row, y)
    if row == rowByLabel.Konto then
      -- Eingabefeld unter der Zeile; InputBoxTemplate zeichnet links etwas über den Rand
      at(idBox, PAD + LABEL_W + 6, y + 2)
      idButton:ClearAllPoints()
      idButton:SetPoint("LEFT", idBox, "RIGHT", 10, 0)
      y = y - 30
    end
  end

  y = y - 6
  span(statusLine, y)
  y = y - 16
  at(guideTitle, PAD, y)
  y = y - height(guideTitle) - 10

  local x = PAD
  for _, b in ipairs(tabs) do
    at(b, x, y)
    x = x + b:GetWidth() + 20
    local active = tab == b.key
    b.label:SetTextColor(unpack(active and C.gold or C.muted))
    b.bar:SetVertexColor(unpack(active and C.gold or C.line))
  end
  y = y - 22
  span(guideLine, y)
  y = y - 12

  for key, list in pairs(steps) do
    for _, s in ipairs(list) do
      s.n:SetShown(key == tab)
      s.body:SetShown(key == tab)
    end
  end
  for _, s in ipairs(steps[tab]) do
    at(s.n, PAD, y)
    at(s.body, PAD + 20, y)
    y = y - height(s.body) - 8
  end

  y = y - 6
  span(footerLine, y)
  y = y - 14
  at(check, PAD - 4, y + 1)
  saveButton:ClearAllPoints()
  saveButton:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, y)
  sendButton:ClearAllPoints()
  sendButton:SetPoint("TOPRIGHT", saveButton, "TOPLEFT", -8, 0)
  y = y - 26 - PAD
  f:SetHeight(-y)
end

function refresh()
  if not ns.db() then return end
  tab = tab or (ns.isCollector() and "collector" or "member")
  update()
  layout()
end

-- Anzeige ------------------------------------------------------------------

-- Gildenliste nachfragen (Online-Status des Sammlers); WoW drosselt das selbst.
local function tick()
  if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster() end
  refresh()
end

local ticker
f:SetScript("OnShow", function()
  tick()
  ticker = C_Timer.NewTicker(5, tick) -- auch damit „vor X Min.“ stimmt
end)
f:SetScript("OnHide", function()
  if ticker then ticker:Cancel() end
  ticker = nil
  accountNote, killNote = nil, nil
end)

-- GildenChronik.lua meldet jede Änderung; gesammelt und kurz verzögert neu zeichnen.
local pending = false
ns.onChange = function()
  if pending or not f:IsShown() then return end
  pending = true
  C_Timer.After(0.2, function()
    pending = false
    if f:IsShown() then refresh() end
  end)
end

-- page: "status" oder "kills" (/gchr kills); ohne bleibt die zuletzt gezeigte Seite
function ns.showWindow(show)
  if show then page = show end
  if f:IsShown() then refresh() else f:Show() end
end

function ns.hideWindow()
  f:Hide()
end

function ns.toggleWindow()
  f:SetShown(not f:IsShown())
end

-- Addon-Menü an der Minimap (Retail), eingetragen in der .toc. Rechtsklick: Einstellungen.
function GildenChronik_OnAddonCompartmentClick(_, button)
  if button == "RightButton" and ns.openOptions then
    ns.openOptions()
  else
    ns.toggleWindow()
  end
end
