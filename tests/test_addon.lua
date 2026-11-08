-- Test des Addons ohne Spiel, gegen den API-Nachbau in wow.lua.
--   lua tests/test_addon.lua                                     (Lua 5.1 bis 5.4)
--   npx -y -p fengari-node-cli fengari tests/test_addon.lua      (ohne Lua, nur Node)
-- Prüft Login, Meldungen, Sammler-Modus, Boss-Versuche mit Postausgang und die Texte im
-- Fenster. Ob das Fenster im Spiel gut aussieht, kann der Test nicht sagen.

local out = print
local dir = (arg and arg[0] or ""):match("^(.*)[/\\]") or "."
local addonDir = dir .. "/../GildenChronik/"
dofile(dir .. "/wow.lua")

local passed = 0
local function check(cond, msg)
  if not cond then error("FEHLGESCHLAGEN: " .. msg, 2) end
  passed = passed + 1
end

local before = {}
for k in pairs(_G) do before[k] = true end
local ns = {}
for _, file in ipairs({ "GildenChronik.lua", "Kills.lua", "Verlauf.lua", "UI.lua", "Options.lua" }) do
  assert(loadfile(addonDir .. file))("GildenChronik", ns)
end
local globals = {}
for k in pairs(_G) do
  if not before[k] then globals[#globals + 1] = k end
end
table.sort(globals)
check(table.concat(globals, ",") ==
  "GildenChronikFrame,GildenChronikMinimapButton,GildenChronik_OnAddonCompartmentClick,SLASH_GILDENCHRONIK1,SLASH_GILDENCHRONIK2",
  "keine versehentlichen Globals: " .. table.concat(globals, ","))

if io and io.open then
  local toc = assert(io.open(addonDir .. "GildenChronik.toc")):read("*a")
  check(toc:find("AddonCompartmentFunc: GildenChronik_OnAddonCompartmentClick", 1, true), ".toc: Addon-Menü")
  local tga = assert(io.open(addonDir .. "media/yak.tga", "rb")):read("*a")
  -- WoW liest die Zeilen von oben nach unten, egal was im Kopf steht: Ursprung oben links.
  check(#tga == 18 + 64 * 64 * 4 and tga:byte(3) == 2 and tga:byte(17) == 32 and tga:byte(18) == 0x28,
    "Icon: 64×64, 32 Bit, unkomprimiert, Ursprung oben links")
  check(toc:find("\nGildenChronik.lua\nKills.lua\nVerlauf.lua\nUI.lua\nOptions.lua\n", 1, true), ".toc: Dateien in dieser Reihenfolge")
end

local ui = GildenChronikFrame
local mm = GildenChronikMinimapButton

-- Sichtbare Texte im Fenster; nebenbei: nirgends ein doppelter Punkt.
local function texts()
  local list = {}
  for _, w in ipairs(WIDGETS) do
    if w._kind == "FontString" and w._text and w:IsShown() and w._parent == ui then
      check(not w._text:find("..", 1, true), "doppelter Punkt in: " .. w._text)
      list[#list + 1] = w._text
    end
  end
  return list
end

local function shows(s)
  for _, t in ipairs(texts()) do
    if t:find(s, 1, true) then return true end
  end
  return false
end

local function find(kind, label)
  for _, w in ipairs(WIDGETS) do
    if w._kind == kind and (not label or w:GetText() == label) then return w end
  end
end

-- Erster Login: Fenster nach 5 s, eigene Meldung nach 10 s. Rezeptlisten aus Addon 1.3.0 fallen weg.
GildenChronikDB = { recipes = { ["Ayky-Blackrock"] = { Kochen = { t = 1793700000, r = { "Gewürzbrot" } } } } }
fire("ADDON_LOADED", "GildenChronik")
fire("PLAYER_LOGIN")
fire("PLAYER_ENTERING_WORLD")
check(GildenChronikDB.recipes == nil, "Rezeptlisten aus 1.3.0 entfernt")
check(not ui:IsShown(), "Fenster nicht sofort")
check(mm:IsShown() and mm._x < 0 and mm._y < 0, "Minimap-Symbol sichtbar, unten links")
check(T.addonCategory and T.addonCategory.name == "Gilden-Chronik", "Einstellungen im Optionsmenü registriert")
advance(5)
check(ui:IsShown(), "Fenster öffnet sich beim ersten Start")
check(GildenChronikDB.welcomed == true, "welcomed gesetzt")
check(GildenChronikDB.char == "Ayky-Blackrock", "eingeloggter Charakter gemerkt")
check(shows("Noch kein Sammler bekannt."), "Hinweis ohne Sammler")
advance(6)
local sent = takeSent()
-- Ab 1.1.0 am Ende der Zeitpunkt des Stands
local t0 = GildenChronikDB.latest["Ayky-Blackrock"].t
check(t0 == T.now - 1 and #sent == 1 and sent[1].channel == "GUILD" and sent[1].msg == "1;12;HUNTER;;0;;;" .. t0,
  "Meldung beim Login (ohne Konto-ID, ohne Gold, mit Zeitpunkt)", sent[1] and sent[1].msg)
check(GildenChronikDB.latest["Ayky-Blackrock"].m == nil, "eigenes Gold ohne Haken nicht gespeichert")
advance(1)
check(shows("Gesendet gerade eben."), "Deine Meldung: gesendet")
check(shows("Wird nicht gesendet."), "Gold: nicht geteilt")

-- Konto-ID einfügen (aus „Mein Profil“), erst falsch, dann richtig
local ID = "1A2B3C4D-1111-4111-8111-111111111111"
check(shows("Nicht verknüpft."), "Konto: nicht verknüpft")
local idBox = find("EditBox")
local apply = find("Button", "Übernehmen")
idBox:SetText("Quatsch")
apply:Click()
advance(1)
check(shows("Das ist keine gültige ID."), "ungültige ID abgelehnt")
check(GildenChronikDB.profileId == nil and #takeSent() == 0, "ungültige ID nicht gespeichert, nichts gesendet")
idBox:SetFocus()
idBox:SetText("  " .. ID .. " ")
idBox._scripts.OnEnterPressed(idBox) -- Enter im Feld
advance(1)
check(GildenChronikDB.profileId == ID:lower() and GildenChronikDB.links["Ayky-Blackrock"] == ID:lower(), "ID gespeichert (klein, ohne Leerzeichen)")
check(not idBox:HasFocus() and shows("Gespeichert. Beim nächsten Upload"), "Rückmeldung nach Übernehmen")
sent = takeSent()
check(#sent == 1 and sent[1].msg == "1;12;HUNTER;;0;;" .. ID:lower() .. ";" .. t0,
  "Meldung mit Konto-ID geht sofort raus, mit dem Zeitpunkt, seit dem der Stand gilt", sent[1] and sent[1].msg)
SlashCmdList.GILDENCHRONIK("id nix")
check(T.printed[#T.printed]:find("keine gültige ID", 1, true) and GildenChronikDB.profileId == ID:lower(), "/gchr id prüft auch")
takeSent()

-- Daten von Brakmor, dann Bestätigung per Flüstern. Ohne Haken „Ich sammle für die Gilde“ speichert
-- das Addon nur die eigenen Charaktere: keine fremden Meldungen, keine Gildenliste.
local snapsBefore = #GildenChronikDB.snapshots
fire("CHAT_MSG_ADDON", "GCHR", "1;20;WARRIOR;55000;2;Bergbau=50;22222222-2222-4222-8222-222222222222", "GUILD", "Brakmor-Blackrock")
fire("CHAT_MSG_ADDON", "GCHR", "1;16;PRIEST;100;0;;kaputt", "GUILD", "Liriel-Blackrock")
fire("GUILD_ROSTER_UPDATE")
check(#GildenChronikDB.snapshots == snapsBefore and GildenChronikDB.latest["Brakmor-Blackrock"] == nil
  and GildenChronikDB.latest["Liriel-Blackrock"] == nil, "ohne Haken: fremde Meldungen und Gildenliste nicht gespeichert")
check(GildenChronikDB.links["Brakmor-Blackrock"] == nil, "ohne Haken: fremde Konto-ID nicht gespeichert")
check(GildenChronikDB.guild == "Yakman", "Gildenname trotzdem gemerkt")
fire("CHAT_MSG_ADDON", "GCHR", "C;1", "WHISPER", "Brakmor-Blackrock")
advance(66) -- das Fenster aktualisiert sich alle 5 s
-- Keine neue Meldung, aber der Verlauf: Der erste eigene Stand geht per Flüstern an den Sammler
sent = takeSent()
check(#sent == 1 and sent[1].channel == "WHISPER" and sent[1].target == "Brakmor-Blackrock"
  and sent[1].msg == "H;1;Ayky-Blackrock;" .. t0 .. ";12;HUNTER;;0;;" .. ID:lower(),
  "Bestätigung löst keine Meldung aus, nur den Verlauf an den Sammler", sent[1] and sent[1].msg)
check(#GildenChronikDB.history == 1 and GildenChronikDB.history[1].w == "f" and GildenChronikDB.history[1].a,
  "erster Stand im Verlauf, als gesendet markiert")
fire("CHAT_MSG_ADDON", "GCHR", "Q;Ayky-Blackrock;" .. t0, "GUILD", "Liriel-Blackrock")
check(#GildenChronikDB.history == 1, "Bestätigung nur von bekannten Sammlern")
fire("CHAT_MSG_ADDON", "GCHR", "Q;Ayky-Blackrock;" .. t0, "GUILD", "Brakmor-Blackrock")
check(#GildenChronikDB.history == 0, "vom Sammler bestätigt: Verlauf leer")
advance(2)
check(#takeSent() == 0, "danach nichts mehr")
check(shows("Brakmor sammelt und hat deine Daten vor 1 Min. bestätigt."), "Sammler hat bestätigt")
check(shows("2 Mitglieder mit Addon in dieser Sitzung, zuletzt Liriel vor 1 Min."), "Empfangen")

-- Ein Sammler kommt online: eigenen Stand verzögert nachliefern
fire("CHAT_MSG_ADDON", "GCHR", "C;1", "GUILD", "Liriel-Blackrock")
check(#takeSent() == 0, "nicht in derselben Sekunde")
advance(30)
sent = takeSent()
check(#sent == 1 and sent[1].msg:sub(1, 2) == "1;", "Stand nachgeliefert")

-- Brakmor sammelt nicht mehr, Liriel ist online
fire("CHAT_MSG_ADDON", "GCHR", "C;0", "GUILD", "Brakmor-Blackrock")
check(GildenChronikDB.collectors["Brakmor-Blackrock"] == nil, "C;0 entfernt den Sammler")
advance(1)
check(shows("Liriel sammelt und ist online."), "anderer Sammler online")

-- Liriel laut Gildenliste offline und länger nicht gehört
W.roster[3][3] = false
advance(600)
check(shows("Liriel sammelt, ist aber offline"), "Sammler offline")

-- Eigene Meldung von WoW blockiert
T.sendResult = Enum.SendAddonMessageResult.AddonMessageThrottle
check(ns.sendNow() == false, "Jetzt senden meldet die Blockade")
advance(1)
check(shows("Von WoW blockiert gerade eben"), "Blockade angezeigt")
T.sendResult = 0
takeSent()

-- Knopf „Jetzt senden“: sendet und sperrt 10 s
advance(10)
local sendButton = find("Button", "Jetzt senden")
sendButton:Click()
check(#takeSent() == 1 and not sendButton:IsEnabled(), "Jetzt senden sendet und sperrt")
advance(10)
check(sendButton:IsEnabled(), "nach 10 s wieder frei")

-- Selbst Sammler werden: liest sofort die Gildenliste, ohne den eigenen Charakter (den meldet das Addon selbst,
-- mit dem Zeitpunkt des Levelaufstiegs)
local box = find("CheckButton")
W.roster[1][2] = 99
box:Click()
W.roster[1][2] = 12
sent = takeSent()
check(GildenChronikDB.collector == true and #sent == 1 and sent[1].channel == "GUILD" and sent[1].msg == "C;1",
  "Haken meldet den Sammler an")
local fromRoster = GildenChronikDB.latest["Brakmor-Blackrock"]
check(fromRoster and fromRoster.l == 20 and fromRoster.cls == "WARRIOR" and fromRoster.src == "r"
  and GildenChronikDB.latest["Liriel-Blackrock"].l == 15, "Haken liest sofort die Gildenliste")
check(GildenChronikDB.latest["Ayky-Blackrock"].src == "a" and GildenChronikDB.latest["Ayky-Blackrock"].l == 12,
  "Gildenliste überspringt den eigenen Charakter")
local roster = GildenChronikDB.roster
check(roster and roster.g == "Yakman" and roster.t == GetServerTime() and #roster.m == 3 and roster.m[1] == "Ayky-Blackrock"
  and roster.m[3] == "Liriel-Blackrock", "Haken speichert die ganze Gildenliste, mit dem eigenen Charakter")
check(shows("Eine Person pro Gilde reicht."), "Reiter Sammler aktiv")
fire("CHAT_MSG_ADDON", "GCHR", "1;16;PRIEST;100;0;", "GUILD", "Liriel-Blackrock")
advance(300)
fire("CHAT_MSG_ADDON", "GCHR", "1;16;PRIEST;200;0;", "GUILD", "Liriel-Blackrock")
advance(300)
fire("CHAT_MSG_ADDON", "GCHR", "1;16;PRIEST;300;0;", "GUILD", "Liriel-Blackrock")
sent = takeSent()
check(#sent == 2 and sent[1].channel == "WHISPER" and sent[1].target == "Liriel-Blackrock" and sent[1].msg == "C;1",
  "Bestätigung je Mitglied höchstens alle 10 Minuten")
advance(1)
check(shows("Du sammelst. In dieser Sitzung hast du 1 Mitglied den Empfang bestätigt."), "Status als Sammler")

advance(1800)
local reminded = false
for _, line in ipairs(T.printed) do
  if line:find("/reload schreibt sie in die Datei", 1, true) then reminded = true end
end
check(reminded, "Erinnerung an /reload")

box:Click()
sent = takeSent()
check(GildenChronikDB.collector == nil and #sent == 1 and sent[1].msg == "C;0", "Haken weg meldet ab")

-- Ohne Gilde
W.inGuild = false
advance(5)
check(shows("Keine Gilde."), "Hinweis ohne Gilde")
check(not sendButton:IsEnabled(), "Jetzt senden ohne Gilde gesperrt")
W.inGuild = true

-- Gildenbank: beim Öffnen lesen und an die Gilde melden
takeSent()
W.guildBank = 0
fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", Enum.PlayerInteractionType.GuildBanker)
advance(2)
check(GildenChronikDB.guildBank == nil and #takeSent() == 0, "0 vor dem Laden der Bank wird ignoriert")
W.guildBank = 5000000
fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", Enum.PlayerInteractionType.Merchant)
advance(2)
check(GildenChronikDB.guildBank == nil, "anderes Fenster als die Gildenbank: nichts")
fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", Enum.PlayerInteractionType.GuildBanker)
advance(2)
check(GildenChronikDB.guildBank.m == 5000000 and GildenChronikDB.guildBank.c == "Ayky-Blackrock", "Gold der Gildenbank gemerkt")
sent = takeSent()
check(#sent == 1 and sent[1].msg == "B;5000000" and sent[1].channel == "GUILD", "Gildenbank an die Gilde gemeldet")
fire("GUILDBANK_UPDATE_MONEY")
check(#takeSent() == 0, "unverändert: keine zweite Meldung")
W.guildBank = 0
fire("GUILDBANK_UPDATE_MONEY")
check(GildenChronikDB.guildBank.m == 0 and #takeSent() == 1, "echte 0 aus dem Update wird übernommen")
fire("CHAT_MSG_ADDON", "GCHR", "B;777", "GUILD", "Brakmor-Blackrock")
check(GildenChronikDB.guildBank.m == 777 and GildenChronikDB.guildBank.c == "Brakmor-Blackrock", "Gildenbank aus fremder Meldung übernommen")
fire("CHAT_MSG_ADDON", "GCHR", "B;viel", "GUILD", "Brakmor-Blackrock")
check(GildenChronikDB.guildBank.m == 777, "kaputte Meldung ignoriert")

-- Slash-Befehl, Addon-Menü, Speichern, Logout
local toggle = ns.toggleWindow
ns.toggleWindow = nil -- wie mit alter .toc nach einem Update ohne Neustart
SlashCmdList.GILDENCHRONIK("")
check(T.printed[#T.printed]:find("WoW komplett neu starten", 1, true), "Hinweis, wenn UI.lua fehlt")
ns.toggleWindow = toggle
SlashCmdList.GILDENCHRONIK("")
check(not ui:IsShown(), "/gchr schließt")
GildenChronik_OnAddonCompartmentClick()
check(ui:IsShown(), "Addon-Menü öffnet")
GildenChronik_OnAddonCompartmentClick("GildenChronik", "RightButton")
check(T.openedOptions and not ui:IsShown(), "Rechtsklick im Addon-Menü öffnet die Einstellungen")

-- Minimap-Symbol: Klicks, Verschieben, Ausblenden
T.openedOptions = nil
mm._scripts.OnClick(mm, "LeftButton")
check(ui:IsShown(), "Linksklick öffnet das Fenster")
mm._scripts.OnClick(mm, "RightButton")
check(T.openedOptions and not ui:IsShown(), "Rechtsklick öffnet die Einstellungen, schließt das Fenster")
T.openedOptions = nil
W.combat = true
SlashCmdList.GILDENCHRONIK("optionen")
check(not T.openedOptions and T.printed[#T.printed]:find("nicht im Kampf", 1, true), "Einstellungen nicht im Kampf")
W.combat = false
SlashCmdList.GILDENCHRONIK("einstellungen")
check(T.openedOptions, "/gchr einstellungen")
W.cursor = { 0, 100 } -- Mitte der Minimap ist 0,0
mm._scripts.OnDragStart(mm)
mm._scripts.OnUpdate(mm)
mm._scripts.OnDragStop(mm)
check(GildenChronikDB.minimap.angle == 90 and math.abs(mm._x) < 0.01 and mm._y == 75, "Ziehen setzt das Symbol oben an den Rand")
check(mm._scripts.OnUpdate == nil, "nach dem Ziehen kein OnUpdate mehr")

-- Einstellungen: Haken spiegeln den Zustand und ändern ihn
local panel = T.category.frame
-- Der Haken entsteht direkt vor seiner Beschriftung.
local function option(label)
  for i, w in ipairs(WIDGETS) do
    if w._kind == "FontString" and w._parent == panel and w._text == label then
      local cb = WIDGETS[i - 1]
      if cb._kind == "CheckButton" then return cb end
    end
  end
end
local goldCheck, mmCheck, collectorCheck, remindCheck = option("Ich teile mein Gold mit der Chronik"),
  option("Symbol an der Minimap anzeigen"), option("Ich sammle für die Gilde"), option("An /reload erinnern")
check(goldCheck and mmCheck and collectorCheck and remindCheck, "vier Haken in den Einstellungen")
check(not goldCheck:GetChecked() and GildenChronikDB.shareGold == nil, "Gold teilen ist aus")
check(mmCheck:GetChecked() and not collectorCheck:GetChecked() and remindCheck:GetChecked(), "Haken zeigen den Zustand")
mmCheck:Click()
check(GildenChronikDB.minimap.hide == true and not mm:IsShown(), "Haken weg blendet das Symbol aus")
SlashCmdList.GILDENCHRONIK("minimap")
check(GildenChronikDB.minimap.hide == nil and mm:IsShown() and mmCheck:GetChecked(), "/gchr minimap blendet es wieder ein")
remindCheck:Click()
check(GildenChronikDB.noRemind == true and not ns.remindOn(), "Erinnerung abgeschaltet")
collectorCheck:Click()
check(GildenChronikDB.collector == true, "Sammler über die Einstellungen")
takeSent()
-- Als Sammler: fremde Meldungen mit Konto-ID speichern
fire("CHAT_MSG_ADDON", "GCHR", "1;20;WARRIOR;55000;2;Bergbau=50;22222222-2222-4222-8222-222222222222", "GUILD", "Brakmor-Blackrock")
local heardBrakmor = GildenChronikDB.latest["Brakmor-Blackrock"]
check(heardBrakmor.l == 20 and heardBrakmor.m == 55000 and heardBrakmor.p == "Bergbau=50" and heardBrakmor.src == "a",
  "als Sammler: fremde Meldung gespeichert")
check(GildenChronikDB.links["Brakmor-Blackrock"] == "22222222-2222-4222-8222-222222222222", "Konto-ID aus fremder Meldung gemerkt")
fire("CHAT_MSG_ADDON", "GCHR", "1;16;PRIEST;100;0;;kaputt", "GUILD", "Liriel-Blackrock")
check(GildenChronikDB.links["Liriel-Blackrock"] == nil, "kaputte Konto-ID ignoriert")
takeSent()
local printedBefore = #T.printed
fire("CHAT_MSG_ADDON", "GCHR", "1;16;PRIEST;400;0;", "GUILD", "Liriel-Blackrock")
advance(3600)
local remindedAgain = false
for i = printedBefore + 1, #T.printed do
  if T.printed[i]:find("/reload schreibt sie", 1, true) then remindedAgain = true end
end
check(not remindedAgain, "ohne Erinnerung kein Hinweis im Chat")
collectorCheck:Click()
remindCheck:Click()
check(GildenChronikDB.collector == nil and GildenChronikDB.noRemind == nil, "zurückgesetzt")
takeSent()

find("Button", "Speichern (/reload)"):Click()
check(T.reloaded, "Speichern lädt die Oberfläche neu")
-- Gold teilen: sofort eine Meldung mit Gold, wieder aus: ohne
takeSent()
advance(60)
goldCheck:Click()
sent = takeSent()
check(GildenChronikDB.shareGold == true and #sent == 1 and sent[1].msg:find("^1;12;HUNTER;12345;"), "Haken schickt das Gold sofort", sent[1] and sent[1].msg)
check(GildenChronikDB.latest["Ayky-Blackrock"].m == 12345, "eigenes Gold gespeichert")
ui:Show()
advance(1)
check(shows("Geht mit deinen Meldungen an die Chronik."), "Gold: geteilt")
advance(60)
goldCheck:Click()
sent = takeSent()
check(GildenChronikDB.shareGold == nil and #sent == 1 and sent[1].msg:find("^1;12;HUNTER;;"), "ohne Haken wieder ohne Gold")
advance(60)
goldCheck:Click()
takeSent()

-- Charakterwechsel: Beim Ausloggen liefert WoW schon 0 Gold. Gespeichert wird der
-- letzte Stand aus der Welt, nicht die 0.
W.money = 77777
fire("PLAYER_MONEY")
fire("PLAYER_LEAVING_WORLD")
W.money, W.level = 0, 0
fire("PLAYER_MONEY")
takeSent()
fire("PLAYER_LOGOUT")
local latest = GildenChronikDB.latest["Ayky-Blackrock"]
check(latest.m == 77777 and latest.l == 12, "Logout speichert den letzten Stand aus der Welt, nicht 0", latest.m)
check(#takeSent() == 0, "außerhalb der Welt geht keine Meldung raus")
local zeros = 0
for _, snap in ipairs(GildenChronikDB.snapshots) do
  if snap.c == "Ayky-Blackrock" and snap.m == 0 then zeros = zeros + 1 end
end
check(zeros == 0, "kein Stand mit 0 Gold in der Datei")
check(GildenChronikDB.savedAt == T.now, "savedAt beim Logout")

-- Boss-Versuche (Kills.lua) -----------------------------------------------

local db = GildenChronikDB
local function sentOf(kind, channel)
  local list = {}
  for _, m in ipairs(takeSent()) do
    if m.msg:sub(1, #kind + 1) == kind .. ";" and (not channel or m.channel == channel) then list[#list + 1] = m end
  end
  return list
end
-- In den letzten Zeilen des Logs (der Verlauf schreibt dazwischen)
local function logHas(s)
  for i = #db.log, math.max(1, #db.log - 5), -1 do
    if db.log[i]:find(s, 1, true) then return true end
  end
  return false
end
local function printedHas(s)
  for _, l in ipairs(T.printed) do
    if l:find(s, 1, true) then return true end
  end
  return false
end

check(db.diag.registered.ENCOUNTER_END == true and db.diag.build == "12.1.0.65000" and db.diag.locale == "deDE",
  "Messdaten: Boss-Events registriert, Build und Sprache")

-- Katalog: 20 s nach dem Login aus dem Abenteuerführer eingelesen
local cat = db.catalog
check(cat and cat.build == "12.1.0.65000" and cat.locale == "deDE" and #cat.instances == 3, "Katalog eingelesen")
local mc = cat.instances[2]
check(mc.i == 409 and mc.j == 741 and mc.n == "Geschmolzener Kern" and mc.raid == true and mc.tier == "Classic"
  and #mc.b == 3 and mc.b[3].e == 672 and mc.b[3].n == "Ragnaros" and mc.b[3].pos == 3, "Raid mit Bossen und Encounter-IDs")
check(cat.instances[1].raid == false and cat.instances[1].i == 48 and cat.instances[3].i == 532
  and cat.instances[3].tier == "Burning Crusade", "Dungeon und zweite Stufe")
check(db.diag.ej.skipped == 2 and db.diag.ej.instances == 3 and db.diag.ej.bosses == 5, "Instanz ohne Karte und Boss ohne ID übersprungen")
check(W.ej.current == 1, "Abenteuerführer wieder auf der vorherigen Stufe")

-- Kill im Raid: Gruppe mit Zone und Online-Status aus der Raidliste
fire("PLAYER_ENTERING_WORLD")
takeSent()
W.instance = { name = "Geschmolzener Kern", type = "raid", difficulty = 9, maxPlayers = 40, id = 409 }
W.raid = {
  { "Ayky", "Geschmolzener Kern", true },
  { "Brakmor", "Geschmolzener Kern", true },
  { "Liriel", "Orgrimmar", true },
  { "Nyx-Frostwolf", "Offline", false },
}
fire("ENCOUNTER_START", 663, "Lucifron", 9, 40)
local start = T.now
advance(150)
fire("ENCOUNTER_END", 663, "Lucifron", 9, 40, 1)
local kill = db.kills[#db.kills]
check(kill.k == ("663-%d-Ayky"):format(T.now) and kill.e == 663 and kill.n == "Lucifron" and kill.i == 409
  and kill.inm == "Geschmolzener Kern" and kill.it == "raid" and kill.df == 9 and kill.gs == 40 and kill.ok == true
  and kill.st == start and kill.t == T.now and kill.src == "e" and kill.r == "Ayky-Blackrock" and kill.rt == T.now,
  "Kill mit allen Feldern")
check(kill.g == "Ayky-Blackrock:11,Brakmor-Blackrock:11,Liriel-Blackrock:10,Nyx-Frostwolf:00",
  "Gruppe: drinnen, draußen, offline: " .. kill.g)
check(db.outbox[kill.k] == 0, "Kill im Postausgang")
check(db.log[#db.log]:find("Kill Lucifron (Geschmolzener Kern), 4 in der Gruppe erkannt", 1, true), "Kill im Log")
check(db.diag.group.method == "raid" and db.diag.group.inside == 2 and db.diag.group.outside == 2, "Messdaten der Gruppe")

advance(300)
fire("ENCOUNTER_START", 672, "Ragnaros", 9, 40)
advance(200)
fire("ENCOUNTER_END", 672, "Ragnaros", 9, 40, 0)
local wipe1 = db.kills[#db.kills]
check(wipe1.ok == false and wipe1.e == 672 and db.outbox[wipe1.k] == 0, "Wipe gespeichert und im Postausgang")
fire("BOSS_KILL", 663, "Lucifron")
check(db.diag.events.BOSS_KILL == 1 and db.diag.lastBossKill.args[2] == "string Lucifron", "BOSS_KILL nur in den Messdaten")

-- In der Instanz geht nichts raus, auch nicht an einen Sammler
local deferred = db.diag.deferred.instance or 0
advance(120)
check(#sentOf("K") == 0 and (db.diag.deferred.instance or 0) > deferred, "in der Instanz wartet der Postausgang")

-- Draußen, aber kein Sammler online (Liriel laut Gildenliste offline, lange nicht gehört)
W.instance, W.raid = nil, nil
fire("PLAYER_ENTERING_WORLD")
advance(46)
check(#sentOf("K") == 0 and (db.diag.deferred.noCollector or 0) > 0, "ohne Sammler online wartet der Postausgang")

-- Der Sammler kommt online: Kopf und Gruppe per Flüstern, der älteste Versuch zuerst
W.roster[3][3] = true
fire("CHAT_MSG_ADDON", "GCHR", "C;1", "GUILD", "Liriel-Blackrock")
advance(43) -- 5 bis 40 s zufällig, dazu 1,2 s zwischen den Nachrichten
local all = takeSent()
local wh = {}
for _, m in ipairs(all) do
  if m.channel == "WHISPER" then wh[#wh + 1] = m end
end
check(#wh == 2 and wh[1].target == "Liriel-Blackrock", "zwei Nachrichten an den Sammler")
check(wh[1].msg == table.concat({ "K", 1, kill.k, 663, 409, 9, 40, 1, kill.st, kill.t, "e", "", 1, "Lucifron",
  "Geschmolzener Kern", "raid" }, ";"), "Kopf: " .. wh[1].msg)
check(wh[2].msg == "G;" .. kill.k .. ";1;" .. kill.g, "Gruppe: " .. wh[2].msg)

-- Bestätigung: Eintrag weg, gleich der nächste Versuch
fire("CHAT_MSG_ADDON", "GCHR", "A;" .. kill.k, "GUILD", "Liriel-Blackrock")
check(db.outbox[kill.k] == nil, "bestätigter Kill aus dem Postausgang")
advance(4)
wh = sentOf("K", "WHISPER")
check(#wh == 1 and wh[1].msg:find("^K;1;672%-") and wh[1].msg:find(";40;0;", 1, true), "danach der Wipe")

-- Keine Bestätigung: frühestens nach 10 Minuten erneut
advance(61)
check(logHas("Keine Bestätigung vom Sammler"), "fehlende Bestätigung im Log")
advance(240)
check(#sentOf("K") == 0, "nicht sofort noch einmal")
advance(360)
check(#sentOf("K", "WHISPER") == 1, "nach 10 Minuten erneut")
advance(61)

-- Bestätigungen zählen nur vom Sammler; ein anderer Melder desselben Versuchs genügt
fire("CHAT_MSG_ADDON", "GCHR", "A;" .. wipe1.k, "GUILD", "Brakmor-Blackrock")
check(db.outbox[wipe1.k] == 0 or db.outbox[wipe1.k] > 0, "Bestätigung von Nicht-Sammler ignoriert")
fire("CHAT_MSG_ADDON", "GCHR", ("A;672-%d-Brakmor"):format(wipe1.t + 20), "GUILD", "Liriel-Blackrock")
check(db.outbox[wipe1.k] == nil, "Bestätigung für denselben Versuch eines anderen Melders")

-- Abgelaufene Einträge (älter als 30 Tage) fliegen raus
local old = { k = ("663-%d-Ayky"):format(T.now - 31 * 86400), e = 663, n = "Lucifron", t = T.now - 31 * 86400,
  ok = true, src = "e", g = "", rt = T.now - 31 * 86400 }
table.insert(db.kills, 1, old)
db.outbox[old.k] = 0
ns.pumpKills()
check(db.outbox[old.k] == nil and #sentOf("K") == 0, "alter Eintrag gestrichen, nichts gesendet")
advance(120)

-- Lange Gruppe: mehrere Teile, jede Nachricht höchstens 255 Byte, Namen UTF-8-sicher gekürzt
local members = {}
for i = 1, 40 do members[i] = ("Mitglied%02dü-Blackrock:1%s"):format(i, i % 3 == 0 and "?" or "1") end
local big = { k = ("665-%d-Brakmor"):format(T.now), e = 665, i = 409, df = 9, gs = 40, ok = true, st = T.now - 100,
  t = T.now, src = "e", n = ("Gehennas der Übermächtige; "):rep(3), inm = "Geschmolzener Kern", it = "raid",
  g = table.concat(members, ",") }
local msgs = ns.killMessages(big)
local joined = {}
for i, m in ipairs(msgs) do
  check(#m <= 255, ("Nachricht %d hat %d Byte"):format(i, #m))
  if i > 1 then joined[#joined + 1] = m:match("^G;[^;]+;%d+;(.*)$") end
end
check(#msgs > 3 and table.concat(joined, ",") == big.g, "Gruppe in Teilen, vollständig")
local headName = select(14, strsplit(";", msgs[1]))
check(#headName <= 40 and not headName:find(";", 1, true) and headName:find("^Gehennas der Übermächtige"),
  "Bossname gekürzt, ohne Trenner: " .. headName)
check(not headName:byte(-1) or headName:byte(-1) < 0x80 or headName:byte(-1) >= 0xC0 or headName:sub(-2) == "ü",
  "kein halbes UTF-8-Zeichen am Ende")

-- Als Sammler: Teile in beliebiger Reihenfolge zusammensetzen, speichern, an die Gilde bestätigen
ns.setCollector(true)
takeSent()
local count0 = #db.kills
for i = #msgs, 2, -1 do fire("CHAT_MSG_ADDON", "GCHR", msgs[i], "WHISPER", "Brakmor-Blackrock") end
check(#db.kills == count0, "ohne Kopf noch nicht gespeichert")
fire("CHAT_MSG_ADDON", "GCHR", msgs[1], "WHISPER", "Brakmor-Blackrock")
local got = db.kills[#db.kills]
check(#db.kills == count0 + 1 and got.k == big.k and got.r == "Brakmor-Blackrock" and got.g == big.g
  and got.e == 665 and got.ok == true and got.rt == T.now and got.st == big.st, "Boss-Versuch vom Mitglied gespeichert")
local acks = sentOf("A", "GUILD")
check(#acks == 1 and acks[1].msg == "A;" .. big.k, "Sammler bestätigt an die Gilde")
fire("CHAT_MSG_ADDON", "GCHR", msgs[1], "WHISPER", "Brakmor-Blackrock")
advance(2)
check(#db.kills == count0 + 1 and #sentOf("A", "GUILD") == 1, "doppelter Kopf: nicht doppelt gespeichert, erneut bestätigt")
fire("CHAT_MSG_ADDON", "GCHR", msgs[1]:gsub("Brakmor", "Fremd"), "WHISPER", "Fremd-Blackrock")
check(db.diag.received.unknown == 1, "nur von bekannten Gildenmitgliedern")
fire("CHAT_MSG_ADDON", "GCHR", "K;2;" .. big.k, "WHISPER", "Brakmor-Blackrock")
check(db.diag.received.invalid == 1, "andere Protokollversion ungültig")
fire("CHAT_MSG_ADDON", "GCHR", msgs[1], "GUILD", "Brakmor-Blackrock")
check(#db.kills == count0 + 1, "Kopf im Gildenkanal ignoriert")

-- Eigener Kill des Sammlers: direkt in die Datei, Bestätigung an die Gilde
W.instance = { name = "Onyxias Hort", type = "raid", difficulty = 9, maxPlayers = 40, id = 249 }
fire("ENCOUNTER_END", 1084, "Onyxia", 9, 40, 1)
local own = db.kills[#db.kills]
check(own.e == 1084 and db.outbox[own.k] == nil, "eigener Kill des Sammlers ohne Postausgang")
advance(3) -- Bestätigungen gehen mit Abstand raus
acks = sentOf("A", "GUILD")
check(#acks == 1 and acks[1].msg == "A;" .. own.k, "Sammler bestätigt den eigenen Kill")
W.instance = nil
ns.setCollector(false)
takeSent()

-- Gruppe mit Secret Values: nach dem Kampf ergänzen
W.instance = { name = "Tiefschwarze Grotte", type = "party", difficulty = 1, maxPlayers = 5, id = 48 }
W.map = 221
W.party = {
  { name = "Brakmor", online = true, map = 221 },
  { name = "Liriel", online = true, map = nil, visible = true },
  { name = "Grumbold", realm = "Frostwolf", online = false, map = 1 },
  { name = SECRET, online = true, map = 221 },
}
W.combat = true
fire("ENCOUNTER_END", 1667, "Ghamoo-ra", 1, 5, 1)
local party = db.kills[#db.kills]
check(party.g == "Ayky-Blackrock:11,Brakmor-Blackrock:11,Liriel-Blackrock:11,Grumbold-Frostwolf:00",
  "Gruppe: Karte, Sichtweite, anderer Server, geheimer Name fehlt: " .. party.g)
check(db.diag.secrets.group == 1 and db.diag.group.how.map == 2 and db.diag.group.how.visible == 1, "geheimer Wert gezählt")
W.party[4].name = "Nyx"
W.combat = false
fire("PLAYER_REGEN_ENABLED")
check(party.g == "Ayky-Blackrock:11,Brakmor-Blackrock:11,Liriel-Blackrock:11,Grumbold-Frostwolf:00,Nyx-Blackrock:11",
  "nach dem Kampf ergänzt: " .. party.g)
check(db.diag.group.secrets == 1, "Messdaten vom Kill bleiben")
W.instance, W.party, W.map = nil, nil, 85

-- Sammler geht offline, laufender Versand läuft ohne Bestätigung aus
W.roster[3][3] = false
advance(75)
takeSent()

-- /gchr kill: Weltboss im Ziel, von Hand
local before = #db.kills
SlashCmdList.GILDENCHRONIK("kill")
check(printedHas("Visiere den toten Boss an") and #db.kills == before, "ohne Ziel und Namen kein Kill")
W.zone = "Azshara"
W.target = { name = "Azuregos", dead = true, guid = "Creature-0-1-2-3-6109-0000ABCDEF" }
SlashCmdList.GILDENCHRONIK("kill")
local wb = db.kills[#db.kills]
check(wb.n == "Azuregos" and wb.npc == 6109 and wb.k == ("n6109-%d-Ayky"):format(T.now) and wb.src == "m"
  and wb.ok == true and wb.e == nil and wb.inm == "Kalimdor" and wb.i == 1 and wb.it == "none" and wb.gs == 1
  and wb.g == "Ayky-Blackrock:11" and db.outbox[wb.k] == 0, "Weltboss mit NPC-ID")
check(T.printed[#T.printed]:find("Kill gemeldet: Azuregos, 1 in der Gruppe erkannt.", 1, true), "Rückmeldung im Chat")
advance(30)
SlashCmdList.GILDENCHRONIK("kill")
check(T.printed[#T.printed]:find("Azuregos ist schon gemeldet.", 1, true) and #db.kills == before + 1, "nicht doppelt")
W.target = { name = "Brakmor", dead = true, player = true, guid = "Player-1-0ABC" }
SlashCmdList.GILDENCHRONIK("kill Lord Kazzak")
local kz = db.kills[#db.kills]
check(kz.n == "Lord Kazzak" and kz.npc == nil and kz.k:find("^m%-") and #db.kills == before + 2,
  "toter Spieler im Ziel zählt nicht, Name von Hand")
W.target = nil

-- Fenster: Seite „Kills & Diagnose“
SlashCmdList.GILDENCHRONIK("kills")
advance(1)
check(ui:IsShown() and shows("LETZTE BOSSKÄMPFE") and not shows("STATUS"), "/gchr kills öffnet die Seite")
check(shows("Lord Kazzak · Kalimdor · 1 Charakter · gerade eben · wartet im Postausgang."), "eigener Kill im Postausgang")
check(shows("Gehennas der Übermächtige") and shows("· von Brakmor."), "empfangener Kill mit Melder")
check(shows("3 Boss-Versuche warten. Das Addon schickt sie dem Sammler, sobald er online ist"), "Postausgang mit Hinweis")
check(shows("ENCOUNTER_START 2, ENCOUNTER_END 4, BOSS_KILL 1."), "Boss-Events gezählt")
check(shows("3 Stufen") == false and shows("2 Stufen, 3 Instanzen, 5 Bosse, 2 übersprungen"), "Abenteuerführer in der Diagnose")
check(shows("Gruppe 1"), "geheime Werte in der Diagnose")
find("Button", "Kill melden"):Click()
advance(1)
check(shows("Visiere den toten Boss an"), "Kill melden ohne Ziel: Hinweis im Fenster")
find("Button", "Katalog neu einlesen"):Click()
advance(1)
check(shows("Katalog eingelesen: 1 Dungeon, 2 Raids, 5 Bosse aus dem Abenteuerführer. Der Sammler lädt ihn hoch."), "Katalog neu eingelesen")
find("Button", "Log leeren"):Click()
check(#db.log == 1 and db.log[1]:find("Log geleert", 1, true), "Log geleert")
SlashCmdList.GILDENCHRONIK("diag")
check(printedHas("Diagnose (Messdaten") and printedHas("  Abenteuerführer: 2 Stufen"), "/gchr diag")
SlashCmdList.GILDENCHRONIK("log")
check(T.printed[#T.printed]:find("Log geleert", 1, true), "/gchr log")
-- Leerer Abenteuerführer und leere Gruppensuche: Hinweis, vorhandener Katalog bleibt; den
-- Abenteuerführer bis zum nächsten Patch nicht neu lesen
local tiers, catalog = W.ej.tiers, db.catalog
W.ej.tiers = {}
find("Button", "Katalog neu einlesen"):Click()
advance(1)
check(shows("Die Gruppensuche liefert gerade keine Dungeons. Später noch einmal versuchen."), "leer: Hinweis nach dem Knopf")
check(shows("Leer, 0 Stufen (gerade eben). Bosse kommen mit den Boss-Versuchen."), "leer: Diagnose Abenteuerführer")
check(shows("0 Dungeons, 0 Raids aus 0 Aktivitäten, 0 übersprungen (gerade eben)"), "leer: Diagnose Gruppensuche")
check(db.catalog == catalog and db.diag.ej.empty == true and logHas("Abenteuerführer leer (0 Stufen)"), "leer: alter Katalog bleibt")
local ejAt = db.diag.ej.at
advance(60)
W.combat = true
local okScan, note = ns.scanCatalog()
check(not okScan and note:find("Im Kampf", 1, true), "im Kampf: erst danach")
W.combat = false
fire("PLAYER_REGEN_ENABLED")
advance(10)
check(db.diag.ej.at == ejAt and db.diag.lfg.at > ejAt, "nach dem Kampf: Gruppensuche ja, leerer Abenteuerführer im selben Build nicht")
W.ej.tiers, W.ej.current = tiers, 1
find("Button", "Katalog neu einlesen"):Click()
advance(1)
check(db.catalog and #db.catalog.instances == 3 and db.diag.ej.empty == nil and db.catalog.src == "ej"
  and not db.catalog.complete, "wieder gefüllt: Katalog aus dem Abenteuerführer, nicht vollständig")
find("Button", "Status"):Click()
check(shows("STATUS") and not shows("LETZTE BOSSKÄMPFE"), "zurück zum Status")
ui:Hide()

-- Ohne Kills.lua (alte .toc nach einem Update ohne Neustart)
local reportKill = ns.reportKill
ns.reportKill = nil
SlashCmdList.GILDENCHRONIK("kill Azuregos")
check(T.printed[#T.printed]:find("erst nach einem Neustart", 1, true), "Hinweis, wenn Kills.lua fehlt")
ns.reportKill = reportKill

-- Verlauf (Verlauf.lua) ----------------------------------------------------

local me = "Ayky-Blackrock"
local function history(w)
  local list = {}
  for _, e in ipairs(db.history) do
    if not w or e.w == w then list[#list + 1] = e end
  end
  return list
end
local function sentH()
  local list = {}
  for _, m in ipairs(takeSent()) do
    if m.msg:sub(1, 2) == "H;" then list[#list + 1] = m end
  end
  return list
end

wipe(db.outbox) -- Boss-Versuche hätten Vorrang
wipe(db.history)
W.roster[3][3] = false -- Liriel (Sammler) offline und lange nicht gehört
advance(600)
takeSent()

-- Levelaufstieg ohne Sammler: der ganze Stand zu diesem Zeitpunkt im Verlauf
W.level, W.money = 13, 50000
fire("PLAYER_ENTERING_WORLD")
advance(4)
fire("PLAYER_LEVEL_UP", 13)
advance(1)
local up = db.latest[me]
check(up.l == 13 and up.m == 50000 and up.t == T.now, "Levelaufstieg gespeichert")
local ups = history("l")
check(#ups == 1 and ups[1].c == me and ups[1].t == up.t and ups[1].l == 13 and ups[1].cls == "HUNTER"
  and ups[1].m == 50000 and ups[1].d == up.d and ups[1].p == up.p and ups[1].g == "Yakman" and not ups[1].a,
  "Levelaufstieg mit Gold, Toden, Berufen und Gilde im Verlauf")
sent = takeSent()
check(#sent == 1 and sent[1].msg == ("1;13;HUNTER;50000;%d;;%s;%d"):format(up.d, ID:lower(), up.t),
  "Meldung mit Zeitpunkt des Levelaufstiegs", sent[1] and sent[1].msg)

-- Ohne Sammler: vom Tag nur der letzte Stand, am nächsten Tag ein neuer
advance(61)
W.money = 60000
fire("PLAYER_MONEY")
advance(61)
W.money = 70000
fire("PLAYER_MONEY")
local states = history("s")
check(#states == 1 and states[1].m == 70000 and states[1].t == T.now, "Tagesstand: der letzte des Tages")
advance(86400)
W.money = 80000
fire("PLAYER_MONEY")
states = history("s")
check(#states == 2 and states[2].m == 80000, "neuer Tag, neuer Tagesstand")
check(#history() == 3, "Verlauf: Levelaufstieg und zwei Tagesstände")
takeSent()

-- Sammler online: Ganzer Stand je Nachricht per Flüstern, älteste zuerst
W.roster[3][3] = true
fire("CHAT_MSG_ADDON", "GCHR", "C;1", "GUILD", "Liriel-Blackrock")
advance(65) -- Meldung nach 3 bis 30 s, Verlauf nach 20 bis 60 s
local hs = sentH()
check(#hs == 3 and hs[1].channel == "WHISPER" and hs[1].target == "Liriel-Blackrock", "drei Stände an den Sammler")
check(hs[1].msg == ("H;1;%s;%d;13;HUNTER;50000;%d;;%s"):format(me, up.t, up.d, ID:lower()), "Levelaufstieg: " .. hs[1].msg)
check(hs[2].msg:find(";70000;", 1, true) and hs[3].msg:find(";80000;", 1, true), "danach die Tagesstände")
check(ns.historyView().sending, "wartet auf die Bestätigung")

-- Bestätigung für zwei davon, der dritte kommt nach 10 Minuten noch einmal
fire("CHAT_MSG_ADDON", "GCHR", ("Q;%s;%d,%d"):format(me, up.t, states[1].t), "GUILD", "Liriel-Blackrock")
check(#history() == 1 and history()[1].m == 80000, "bestätigte Stände aus dem Verlauf")
advance(61)
check(not ns.historyView().sending and logHas("Verlauf: keine Bestätigung"), "ohne Bestätigung: neuer Versuch später")
advance(400)
check(#sentH() == 0, "nicht sofort noch einmal")
advance(260)
hs = sentH()
check(#hs == 1 and hs[1].msg:find(";80000;", 1, true), "nach 10 Minuten erneut")
fire("CHAT_MSG_ADDON", "GCHR", ("Q;%s;%d"):format(me, states[2].t), "GUILD", "Liriel-Blackrock")
check(#history() == 0 and not ns.historyView().sending, "alles bestätigt")

-- Mit Sammler online: Levelaufstieg geht trotzdem in den Verlauf, ein Tagesstand nicht
advance(30)
W.level = 14
fire("PLAYER_LEVEL_UP", 14)
advance(1)
advance(61)
W.money = 90000
fire("PLAYER_MONEY")
check(#history("l") == 1 and #history("s") == 0, "Sammler hört mit: nur der Levelaufstieg wartet")
advance(130)
hs = sentH()
check(#hs == 1 and hs[1].msg:find(";14;HUNTER;", 1, true), "Levelaufstieg auch so zum Sammler (spätestens nach 2 Min.)")
fire("CHAT_MSG_ADDON", "GCHR", ("Q;%s;%d"):format(me, history("l")[1].t), "GUILD", "Liriel-Blackrock")
check(#history() == 0, "bestätigt")

-- In Runden zu zehn, Twinks des Accounts gehen mit, andere Gilden bleiben liegen
for i = 1, 12 do
  db.history[#db.history + 1] = { c = "Zweit-Blackrock", t = T.now - 1000 + i, l = 10 + i, cls = "MAGE", d = 0, p = "",
    g = "Yakman", w = "l" }
end
db.history[#db.history + 1] = { c = "Dritt-Blackrock", t = T.now - 5000, l = 30, cls = "ROGUE", d = 1, p = "", g = "Andere Gilde", w = "l" }
advance(130)
hs = sentH()
check(#hs == 10 and hs[1].msg:find("^H;1;Zweit%-Blackrock;") and hs[1].msg:find(";11;MAGE;", 1, true)
  and hs[10].msg:find(";20;MAGE;", 1, true), "zehn Stände je Runde, auch vom Twink, ohne die andere Gilde")
local ts = {}
for _, e in ipairs(history()) do
  if e.c == "Zweit-Blackrock" and e.l <= 20 then ts[#ts + 1] = e.t end
end
fire("CHAT_MSG_ADDON", "GCHR", "Q;Zweit-Blackrock;" .. table.concat(ts, ","), "GUILD", "Liriel-Blackrock")
advance(4)
hs = sentH()
check(#hs == 2 and hs[1].msg:find(";21;MAGE;", 1, true) and hs[2].msg:find(";22;MAGE;", 1, true),
  "nach der Bestätigung gleich die nächste Runde")
ts = {}
for _, e in ipairs(history()) do
  if e.c == "Zweit-Blackrock" then ts[#ts + 1] = e.t end
end
fire("CHAT_MSG_ADDON", "GCHR", "Q;Zweit-Blackrock;" .. table.concat(ts, ","), "GUILD", "Liriel-Blackrock")
advance(2)
check(#history() == 1 and history()[1].g == "Andere Gilde" and ns.historyView().otherGuild == 1,
  "nur der Stand aus der anderen Gilde wartet")
wipe(db.history)

-- Sammler bestätigt gar nichts (Addon vor 1.1.0): nach der Runde 10 Minuten Pause, nicht die nächste
for i = 1, 12 do
  db.history[#db.history + 1] = { c = "Sechst-Blackrock", t = T.now - 2000 + i, l = 30 + i, cls = "DRUID", d = 0, p = "",
    g = "Yakman", w = "l" }
end
advance(130)
check(#sentH() == 10, "erste Runde")
advance(300)
check(#sentH() == 0 and logHas("Verlauf: keine Bestätigung"), "ohne jede Bestätigung keine weitere Runde")
-- Eine späte Bestätigung hebt die Pause auf: gleich die nächste Runde mit den beiden übrigen
ts = {}
for _, e in ipairs(history()) do
  if e.a then ts[#ts + 1] = e.t end
end
fire("CHAT_MSG_ADDON", "GCHR", "Q;Sechst-Blackrock;" .. table.concat(ts, ","), "GUILD", "Liriel-Blackrock")
advance(4)
hs = sentH()
check(#hs == 2 and hs[1].msg:find(";41;DRUID;", 1, true), "späte Bestätigung: Pause aufgehoben")
ts = {}
for _, e in ipairs(history()) do ts[#ts + 1] = e.t end
fire("CHAT_MSG_ADDON", "GCHR", "Q;Sechst-Blackrock;" .. table.concat(ts, ","), "GUILD", "Liriel-Blackrock")
check(#history() == 0, "alle bestätigt")
advance(2)

-- WoW blockiert mitten in der Runde: Was nicht rausging, ist nach einer Minute wieder dran
for i = 1, 4 do
  db.history[#db.history + 1] = { c = "Siebt-Blackrock", t = T.now - 3000 + i, l = 20 + i, cls = "MAGE", d = 0, p = "",
    g = "Yakman", w = "l" }
end
ns.pumpHistory()
check(#sentH() == 1, "erste Nachricht der Runde raus")
T.sendResult = Enum.SendAddonMessageResult.AddonMessageThrottle
advance(2)
T.sendResult = 0
takeSent() -- der gesperrte Versuch
local marked = 0
for _, e in ipairs(history()) do
  if e.a then marked = marked + 1 end
end
check(marked == 1 and logHas("blockiert (Nachricht 2 von 4)"), "nur die gesendete gilt als versucht")
advance(50)
check(#sentH() == 0, "kurz Pause")
advance(130)
hs = sentH()
check(#hs == 3 and hs[1].msg:find(";22;MAGE;", 1, true), "danach die drei übrigen")
ts = {}
for _, e in ipairs(history()) do ts[#ts + 1] = e.t end
fire("CHAT_MSG_ADDON", "GCHR", "Q;Siebt-Blackrock;" .. table.concat(ts, ","), "GUILD", "Liriel-Blackrock")
check(#history() == 0, "alle bestätigt")
advance(2)

-- In der Instanz wartet der Verlauf
db.history[1] = { c = me, t = T.now - 10, l = 14, cls = "HUNTER", d = 0, p = "", g = "Yakman", w = "l" }
W.instance = { name = "Tiefschwarze Grotte", type = "party", difficulty = 1, maxPlayers = 5, id = 48 }
advance(250)
check(#sentH() == 0, "in der Instanz kein Verlauf")
W.instance = nil
advance(130)
check(#sentH() == 1, "draußen wieder")
fire("CHAT_MSG_ADDON", "GCHR", ("Q;%s;%d"):format(me, db.history[1].t), "GUILD", "Liriel-Blackrock")
check(#db.history == 0, "bestätigt")
wipe(db.history)

-- Nachricht höchstens 255 Byte: erst ohne Konto-ID, dann Berufe gekürzt (ganze Einträge)
local profs = {}
for i = 1, 20 do profs[i] = ("Beruf%02d=300"):format(i) end
local long = { c = "Überlangername-Zirkeldesärgernisses", t = T.now, l = 60, cls = "DEATHKNIGHT", m = 99999999999, d = 99999,
  p = table.concat(profs, ",") }
local lm = ns.historyMessage(long)
local lp = select(9, strsplit(";", lm))
check(#lm <= 255 and not lm:find(ID:lower(), 1, true) and lm:sub(-1) == ";" and lp ~= ""
  and long.p:sub(1, #lp) == lp and long.p:sub(#lp + 1, #lp + 1) == ",", "lange Nachricht ohne Konto-ID, Berufe ganz gekürzt: " .. #lm)
local mid = ns.historyMessage({ c = me, t = T.now, l = 60, cls = "DEATHKNIGHT", m = 99999999999, d = 99999, p = table.concat(profs, ",", 1, 14) })
check(#mid <= 255 and not mid:find(ID:lower(), 1, true) and select(9, strsplit(";", mid)) == table.concat(profs, ",", 1, 14),
  "erst ohne Konto-ID, Berufe bleiben, wenn es dann passt: " .. #mid)
local short = ns.historyMessage({ c = me, t = T.now, l = 14, cls = "HUNTER", d = 0, p = "Kochen=10" })
check(short == ("H;1;%s;%d;14;HUNTER;;0;Kochen=10;%s"):format(me, T.now, ID:lower()), "normale Nachricht mit Konto-ID: " .. short)

-- Gildenliste ohne Haken (wieder abgemeldet): nichts gespeichert
W.roster[1][2], W.roster[2][2] = 99, 45
local rosterBefore = #db.snapshots
fire("GUILD_ROSTER_UPDATE")
check(#db.snapshots == rosterBefore and db.latest[me].src == "a" and db.latest[me].l == 14
  and db.latest["Brakmor-Blackrock"].l < 45, "ohne Haken: Gildenliste nicht gespeichert")
W.roster[1][2], W.roster[2][2] = 12, 20

-- Erstes Mal mit 1.1.0 (kein Eintrag in own): alle eigenen Stände aus der Datei durchgehen
db.own[me] = nil
local firstOwn
for _, s in ipairs(db.snapshots) do
  if s.c == me and s.src ~= "r" and (not firstOwn or s.t < firstOwn.t) then firstOwn = s end
end
advance(61)
W.money = 95000
fire("PLAYER_MONEY")
local f = history("f")
local levels = history("l")
check(#f == 1 and f[1].t == firstOwn.t and f[1].l == 12 and db.own[me].f and db.own[me].l == 14, "erster Stand aus der Datei")
check(#levels == 2 and levels[1].l == 13 and levels[1].t == up.t and levels[2].l == 14, "frühere Levelaufstiege aus der Datei")
local days, last = {}, {}
for _, s in ipairs(db.snapshots) do
  if s.c == me and s.src ~= "r" then
    local d = date("%Y-%m-%d", s.t)
    if not last[d] or s.t > last[d].t then last[d] = s end
  end
end
for _, e in ipairs(history("s")) do
  local d = date("%Y-%m-%d", e.t)
  check(not days[d] and last[d] and last[d].t == e.t, "je Tag der letzte Stand: " .. d)
  days[d] = true
end
check(days[date("%Y-%m-%d", T.now)], "heute dabei")
takeSent()

-- Fenster: Zeile „Verlauf“
ui:Show()
advance(1)
check(shows(("%d Stände, davon 2 Levelaufstiege warten auf den Sammler."):format(#history()))
  or shows("Wird gerade an den Sammler gesendet"), "Verlauf im Fenster")
SlashCmdList.GILDENCHRONIK("status")
check(printedHas("Verlauf: ") and printedHas("Levelaufstiege."), "/gchr status mit Verlauf")

-- Sammler werden: Offenes landet in der eigenen Datei, fehlende Stände mit rt
local missing = { c = "Viert-Blackrock", t = T.now - 7200, l = 33, cls = "PRIEST", d = 2, p = "", g = "Yakman", w = "l" }
db.history[#db.history + 1] = missing
local before, becameAt = #db.snapshots, T.now
ns.setCollector(true)
advance(1)
check(#db.history == 0, "als Sammler kein Verlauf mehr offen")
local absorbed = db.snapshots[#db.snapshots]
check(#db.snapshots == before + 1 and absorbed.c == "Viert-Blackrock" and absorbed.t == missing.t and absorbed.rt == becameAt
  and absorbed.l == 33, "fehlender Stand mit rt in die Datei, vorhandene nicht doppelt")
check(shows("Du sammelst: Dein eigener Verlauf steht direkt in deiner Datei."), "Fenster als Sammler")
takeSent()

-- Sammler empfängt: speichern mit dem Zeitpunkt des Stands, rt = jetzt, Bestätigung an die Gilde
local latestBrakmor = db.latest["Brakmor-Blackrock"]
local bt = latestBrakmor.t - 3600 -- älter als alles von Brakmor
local function entry(c, t, l, id) return ("H;1;%s;%d;%d;WARRIOR;55000;2;Bergbau=50;%s"):format(c, t, l, id or "") end
local B2 = "22222222-2222-4222-8222-222222222222"
fire("CHAT_MSG_ADDON", "GCHR", entry("Brakmor-Blackrock", bt, 18, B2), "WHISPER", "Brakmor-Blackrock")
local got = db.snapshots[#db.snapshots]
check(got.c == "Brakmor-Blackrock" and got.t == bt and got.rt == T.now and got.l == 18 and got.m == 55000 and got.d == 2
  and got.p == "Bergbau=50" and got.cls == "WARRIOR" and got.src == "a", "nachgelieferter Stand gespeichert")
check(db.latest["Brakmor-Blackrock"] == latestBrakmor, "älterer Stand ändert latest nicht")
local qs = sentOf("Q", "GUILD")
check(#qs == 1 and qs[1].msg == ("Q;Brakmor-Blackrock;%d"):format(bt), "Bestätigung an die Gilde")
-- Mehrere auf einmal: eine Bestätigung mit allen Zeitpunkten
fire("CHAT_MSG_ADDON", "GCHR", entry("Brakmor-Blackrock", bt + 60, 19, B2), "WHISPER", "Brakmor-Blackrock")
fire("CHAT_MSG_ADDON", "GCHR", entry("Brakmor-Blackrock", bt + 120, 20, B2), "WHISPER", "Brakmor-Blackrock")
fire("CHAT_MSG_ADDON", "GCHR", entry("Brakmor-Blackrock", bt, 18, B2), "WHISPER", "Brakmor-Blackrock")
advance(2)
qs = sentOf("Q", "GUILD")
check(#qs == 1 and qs[1].msg == ("Q;Brakmor-Blackrock;%d,%d,%d"):format(bt + 60, bt + 120, bt),
  "Bestätigungen zusammengefasst: " .. (qs[1] and qs[1].msg or "-"))
local copies = 0
for _, s in ipairs(db.snapshots) do
  if s.c == "Brakmor-Blackrock" and s.t == bt then copies = copies + 1 end
end
check(copies == 1 and ns.historyView().stats.dup == 1, "doppelt: nicht noch einmal gespeichert, aber bestätigt")
-- Twink des Accounts (noch ohne Konto): angenommen, Konto-ID gemerkt; Charakter eines anderen Kontos: nicht
fire("CHAT_MSG_ADDON", "GCHR", entry("Brakmortwink-Blackrock", bt, 5, B2), "WHISPER", "Brakmor-Blackrock")
check(db.snapshots[#db.snapshots].c == "Brakmortwink-Blackrock" and db.links["Brakmortwink-Blackrock"] == B2, "Twink angenommen")
local count1 = #db.snapshots
fire("CHAT_MSG_ADDON", "GCHR", entry(me, bt, 5, B2), "WHISPER", "Brakmor-Blackrock")
check(#db.snapshots == count1 and ns.historyView().stats.foreign == 1, "fremdes Konto abgelehnt")
advance(3)
qs = sentOf("Q", "GUILD")
check(#qs == 2 and qs[2].msg == ("Q;%s;%d"):format(me, bt), "abgelehnt, aber bestätigt (sonst endlos)")
fire("CHAT_MSG_ADDON", "GCHR", entry("Fremd-Blackrock", bt, 5), "WHISPER", "Fremd-Blackrock")
fire("CHAT_MSG_ADDON", "GCHR", (entry("Brakmor-Blackrock", bt, 5)):gsub("^H;1;", "H;2;"), "WHISPER", "Brakmor-Blackrock")
fire("CHAT_MSG_ADDON", "GCHR", entry("Brakmor-Blackrock", T.now + 3600, 5), "WHISPER", "Brakmor-Blackrock")
fire("CHAT_MSG_ADDON", "GCHR", entry("Brakmor-Blackrock", bt, 18, B2), "GUILD", "Brakmor-Blackrock")
advance(3)
local st = ns.historyView().stats
check(st.unknown == 1 and st.invalid == 2 and #sentOf("Q") == 0 and #db.snapshots == count1,
  "Unbekannte, falsche Version, Zukunft und Gildenkanal: nichts gespeichert, nichts bestätigt")

-- Meldung ab 1.1.0 mit Zeitpunkt: so gespeichert, rt = jetzt; Unplausibles mit der Empfangszeit
fire("CHAT_MSG_ADDON", "GCHR", "1;21;WARRIOR;56000;2;Bergbau=60;" .. B2 .. ";" .. (T.now - 3600), "GUILD", "Brakmor-Blackrock")
got = db.latest["Brakmor-Blackrock"]
check(got.l == 21 and got.t == T.now - 3600 and got.rt == T.now, "Meldung mit dem Zeitpunkt des Stands")
fire("CHAT_MSG_ADDON", "GCHR", "1;22;WARRIOR;56000;2;Bergbau=60;" .. B2 .. ";" .. (T.now + 999), "GUILD", "Brakmor-Blackrock")
got = db.latest["Brakmor-Blackrock"]
check(got.l == 22 and got.t == T.now and got.rt == nil, "Zeitpunkt aus der Zukunft: Empfangszeit")
advance(1)
check(shows("Du sammelst. In dieser Sitzung von anderen nachgeliefert: 4 Stände, dazu 1 Stand schon da."), "Fenster als Sammler mit Zahlen")
ns.setCollector(false)
ui:Hide()
takeSent()

-- WoW Forever: Vor- und Nachname -------------------------------------------

check(not ns.surnames() and ns.joinName("Grumbold", "Frostwolf") == "Grumbold-Frostwolf", "Retail: zweiter Wert ist der Realm")
check(ns.whisperTarget("Brakmor-Blackrock") == "Brakmor-Blackrock", "Retail: Flüstern mit Realm wie bisher")

-- Bis 1.1.1 stand der eigene Charakter in Forever ohne Nachnamen in der Datei: beim Login umschreiben
local full = "Ayky Sturmwind-Blackrock"
db.deaths[me] = 7
db.history[#db.history + 1] = { c = me, t = T.now - 60, l = 14, cls = "HUNTER", d = 7, p = "", g = "Yakman", w = "l" }
db.guildBank = { m = 5000, t = T.now - 60, c = me }
local ownSnaps, ownLatest, ownState = 0, db.latest[me], db.own[me]
for _, list in ipairs({ db.snapshots, db.history }) do
  for _, s in ipairs(list) do
    if s.c == me then ownSnaps = ownSnaps + 1 end
  end
end
check(ownSnaps > 0 and ownLatest and ownState and db.links[me] == ID:lower(), "vorher: eigene Einträge ohne Nachnamen")
W.regionalNames, W.surname = true, "Sturmwind"
check(ns.surnames() and ns.joinName("Liriel", "Mondschein") == "Liriel Mondschein", "Forever: zweiter Wert ist der Nachname")
check(ns.me() == full, "eigener Name mit Nachnamen")
fire("PLAYER_LOGIN")
check(db.char == full, "Sammler-Charakter mit Nachnamen")
local left, moved = 0, 0
for _, list in ipairs({ db.snapshots, db.history }) do
  for _, s in ipairs(list) do
    if s.c == me then left = left + 1 end
    if s.c == full then moved = moved + 1 end
  end
end
check(left == 0 and moved == ownSnaps, "eigene Stände und Offenes im Verlauf umgeschrieben")
check(db.latest[me] == nil and db.latest[full] == ownLatest and ownLatest.c == full, "letzter Stand umgeschrieben")
check(db.deaths[me] == nil and db.deaths[full] == 7, "Todeszähler bleibt")
check(db.own[me] == nil and db.own[full] == ownState, "Verlauf fängt nicht von vorn an")
check(db.links[me] == nil and db.links[full] == ID:lower(), "Konto-ID am vollen Namen")
check(db.guildBank.c == full, "Gildenbank umgeschrieben")
check(logHas(("Name mit Nachnamen: %d Einträge von %s auf %s umgeschrieben"):format(ownSnaps, me, full)), "im Log")
fire("PLAYER_LOGIN")
check(db.deaths[full] == 7 and db.latest[full] == ownLatest, "zweiter Login: nichts mehr umzuschreiben")
advance(11)
local own1 = sentOf("1", "GUILD")
check(#own1 >= 1, "Meldung an die Gilde")
local snapCount = #db.snapshots
fire("CHAT_MSG_ADDON", "GCHR", own1[1].msg:gsub(";HUNTER;", ";MAGE;"), "GUILD", "Ayky Sturmwind")
check(#db.snapshots == snapCount and db.latest[full].cls == "HUNTER", "Echo der eigenen Meldung nicht gespeichert")

-- Gildenliste und Absender: „Vorname Nachname“ ohne Realm (gespeichert erst als Sammler)
fire("CHAT_MSG_ADDON", "GCHR", "1;30;MAGE;;0;;;", "GUILD", "Liriel Mondschein")
table.insert(W.roster, { "Grumbold Stein", 33, true, "WARRIOR" })
advance(301)
fire("GUILD_ROSTER_UPDATE")
check(db.latest["Liriel Mondschein-Blackrock"] == nil and db.latest["Grumbold Stein-Blackrock"] == nil,
  "ohne Haken: Doppelnamen aus Meldung und Gildenliste nicht gespeichert")
check(ns.whisperTarget("Brakmor Eisenfaust-Blackrock") == "Brakmor Eisenfaust"
  and ns.whisperTarget("Grumbold Stein-Frostwolf") == "Grumbold Stein-Frostwolf", "Flüstern an Doppelnamen ohne eigenen Realm")
takeSent()

-- Als Sammler: Gildenliste und Meldung mit Doppelnamen, Bestätigung an den Absender, Verlauf angenommen
ns.setCollector(true)
takeSent()
check(db.latest["Grumbold Stein-Blackrock"] and db.latest["Grumbold Stein-Blackrock"].l == 33, "Gildenliste mit Doppelnamen")
check(#db.roster.m == 4 and db.roster.m[3] == "Grumbold Stein-Blackrock", "ganze Gildenliste mit Doppelnamen")
-- Grumbold verlässt die Gilde: Die nächste Liste ersetzt die vorige, er fehlt darin
table.remove(W.roster)
advance(301)
fire("GUILD_ROSTER_UPDATE")
local rosterNow = db.roster
check(rosterNow.t == GetServerTime() and #rosterNow.m == 3 and rosterNow.m[3] == "Liriel-Blackrock", "neue Gildenliste ohne Ausgetretenen")
-- Unvollständig (Name noch nicht geladen) oder leer: Die alte Liste bleibt
W.roster[#W.roster + 1] = { nil, 10, true, "MAGE" }
advance(301)
fire("GUILD_ROSTER_UPDATE")
check(db.roster == rosterNow, "unvollständige Gildenliste nicht gespeichert")
W.roster[#W.roster] = nil
local rosterSaved = W.roster
W.roster = {}
advance(301)
fire("GUILD_ROSTER_UPDATE")
check(db.roster == rosterNow, "leere Gildenliste nicht gespeichert")
W.roster = rosterSaved
SlashCmdList.GILDENCHRONIK("status")
check(T.printed[#T.printed]:find("Gildenliste: 3 Mitglieder in Yakman", 1, true), "/gchr status nennt die Gildenliste",
  T.printed[#T.printed])
fire("CHAT_MSG_ADDON", "GCHR", "1;31;MAGE;;0;;;", "GUILD", "Liriel Mondschein")
check(db.latest["Liriel Mondschein-Blackrock"] and db.latest["Liriel Mondschein-Blackrock"].l == 31, "Meldung mit Doppelnamen")
local acked = sentOf("C", "WHISPER")
check(#acked == 1 and acked[1].target == "Liriel Mondschein", "Bestätigung an „Liriel Mondschein“")
local ht = T.now - 7200
fire("CHAT_MSG_ADDON", "GCHR", ("H;1;Liriel Mondschein-Blackrock;%d;29;MAGE;;0;;"):format(ht), "WHISPER", "Liriel Mondschein")
got = db.snapshots[#db.snapshots]
check(got.c == "Liriel Mondschein-Blackrock" and got.t == ht and got.l == 29, "Verlauf mit Doppelnamen gespeichert")
advance(3)
local qd = sentOf("Q", "GUILD")
check(#qd == 1 and qd[1].msg == ("Q;Liriel Mondschein-Blackrock;%d"):format(ht), "und bestätigt")
fire("CHAT_MSG_ADDON", "GCHR", ("H;1;Liriel  Mondschein-Blackrock;%d;29;MAGE;;0;;"):format(ht + 1), "WHISPER", "Liriel Mondschein")
fire("CHAT_MSG_ADDON", "GCHR", ("H;1;Liriel Mond schein-Blackrock;%d;29;MAGE;;0;;"):format(ht + 2), "WHISPER", "Liriel Mondschein")
check(db.snapshots[#db.snapshots] == got, "Namen mit mehr als einem Leerzeichen abgelehnt")
ns.setCollector(false)
takeSent()

-- Boss-Versuch in der Gruppe: Namen mit Nachnamen, Schlüssel ohne Leerzeichen; geheimer Nachname wie ein
-- geheimer Name, nach dem Kampf ergänzt
W.instance = { name = "Tiefschwarze Grotte", type = "party", difficulty = 1, maxPlayers = 5, id = 48 }
W.map = 221
W.party = {
  { name = "Liriel", realm = "Mondschein", online = true, map = 221 },
  { name = "Brakmor", realm = SECRET, online = true, map = 221 },
}
W.combat = true
fire("ENCOUNTER_END", 1667, "Ghamoo-ra", 1, 5, 1)
local fk = db.kills[#db.kills]
check(fk.k == ("1667-%d-AykySturmwind"):format(T.now) and fk.r == full, "Schlüssel ohne Leerzeichen: " .. fk.k)
check(fk.g == "Ayky Sturmwind-Blackrock:11,Liriel Mondschein-Blackrock:11", "Gruppe mit Nachnamen: " .. fk.g)
W.party[2].realm = "Eisenfaust"
W.combat = false
fire("PLAYER_REGEN_ENABLED")
advance(6)
check(fk.g == "Ayky Sturmwind-Blackrock:11,Liriel Mondschein-Blackrock:11,Brakmor Eisenfaust-Blackrock:11",
  "geheimer Nachname nach dem Kampf ergänzt: " .. fk.g)
W.instance, W.party, W.map = nil, nil, 85
ui:Show()
advance(1)
check(shows("Ayky Sturmwind · Blackrock · Version"), "Fenster zeigt den vollen Namen")
ui:Hide()
W.regionalNames, W.surname = nil, nil
takeSent()

-- Katalog in WoW Forever: kein Abenteuerführer, Dungeons und Raids aus der Gruppensuche ----------

local function inst(id)
  for _, e in ipairs(db.catalog.instances) do
    if e.i == id then return e end
  end
end
W.ej.tiers = {}
W.maps = { [389] = "Ragefireabgrund", [189] = "Scharlachrotes Kloster", [229] = "Blackrockspitze",
  [48] = "Tiefschwarze Grotte", [409] = "Geschmolzener Kern" }
W.lfg = {
  categories = { 2, 114, 116, 118 },
  activities = {
    [798] = { fullName = "Ragefireabgrund", categoryID = 2, mapID = 389, minLevel = 13, maxLevelSuggestion = 18, maxNumPlayers = 5 },
    [805] = { fullName = "Scharlachrotes Kloster - Friedhof", categoryID = 2, mapID = 189, minLevel = 30, maxLevelSuggestion = 38, maxNumPlayers = 5 },
    [829] = { fullName = "Scharlachrotes Kloster - Bibliothek", categoryID = 2, mapID = 189, minLevel = 33, maxLevelSuggestion = 41, maxNumPlayers = 5 },
    [812] = { fullName = "Untere Blackrockspitze", categoryID = 2, mapID = 229, minLevel = 55, maxLevelSuggestion = 60, maxNumPlayers = 5 },
    [837] = { fullName = "Obere Blackrockspitze", categoryID = 2, mapID = 229, minLevel = 59, maxLevelSuggestion = 60, maxNumPlayers = 10 },
    [801] = { fullName = "Tiefschwarze Grotte", categoryID = 2, mapID = 48, minLevel = 24, maxLevelSuggestion = 32, maxNumPlayers = 5 },
    [1604] = { fullName = "Tiefschwarze Grotte", categoryID = 114, mapID = 48, minLevel = 25, maxLevelSuggestion = 32, maxNumPlayers = 10 },
    [839] = { fullName = "Geschmolzener Kern", categoryID = 114, mapID = 409, minLevel = 60, maxLevelSuggestion = 60, maxNumPlayers = 40 },
    [1613] = { fullName = "Geschmolzener Kern", categoryID = 114, mapID = 409, minLevel = 60, maxLevelSuggestion = 60, maxNumPlayers = 40 },
    [853] = { fullName = "Wald von Elwynn", categoryID = 116, mapID = 0, minLevel = 1, maxLevelSuggestion = 14, maxNumPlayers = 0 },
    [919] = { fullName = "Kriegshymnenschlucht", categoryID = 118, mapID = 489, minLevel = 10, maxLevelSuggestion = 19, maxNumPlayers = 10 },
    [999] = { fullName = "Ohne Instanz", categoryID = 2, minLevel = 20, maxNumPlayers = 5 },
  },
}
db.catalog = nil
db.diag.ej = {}
advance(60)
fire("PLAYER_LOGIN")
advance(21)
local fc = db.catalog
check(fc and fc.src == "lfg" and fc.complete == true and fc.ej == nil and fc.t == T.now - 1 and #fc.instances == 5,
  "Forever: Katalog nach dem Login aus der Gruppensuche, vollständig")
local order = {}
for _, e in ipairs(fc.instances) do order[#order + 1] = e.i .. (e.raid and "r" or "d") .. e.pos end
check(table.concat(order, ",") == "389d1,48d2,189d3,229d4,409r1", "Dungeons nach Mindestlevel, dann Raids: " .. table.concat(order, ","))
local rfc, sm, brs, bfd, mc = inst(389), inst(189), inst(229), inst(48), inst(409)
check(rfc.n == "Ragefireabgrund" and rfc.min == 13 and rfc.max == 18 and rfc.size == 5 and not rfc.raid and #rfc.b == 0
  and rfc.j == nil, "Dungeon mit Level und Spielerzahl, ohne Bosse")
check(sm.n == "Scharlachrotes Kloster" and sm.min == 30 and sm.max == 41, "Flügel: eine Instanz, Name über die ID, Level von bis")
check(brs.min == 55 and brs.max == 60 and brs.size == 10, "untere und obere Spitze: eine Instanz, größte Gruppe")
check(not bfd.raid and bfd.size == 5 and bfd.min == 24, "Dungeon und Raid derselben Instanz: der Dungeon")
check(mc.raid and mc.size == 40 and mc.min == 60 and mc.n == "Geschmolzener Kern", "Raid aus zwei Schwierigkeiten")
check(db.diag.lfg.activities == 9 and db.diag.lfg.skipped == 1 and db.diag.lfg.dungeons == 4 and db.diag.lfg.raids == 1,
  "Messdaten: Zonen und Schlachtfelder nicht gelesen, Aktivität ohne Instanz übersprungen")
check(logHas("Katalog eingelesen (lfg): 4 Dungeons, 1 Raid"), "Log")
ui:Show()
SlashCmdList.GILDENCHRONIK("kills")
advance(1)
check(shows("4 Dungeons, 1 Raid aus 9 Aktivitäten, 1 übersprungen") and shows("4 Dungeons, 1 Raid, Stand"), "Diagnose: Gruppensuche und Katalog")
ui:Hide()

-- Nächster Login ohne Änderung: gleicher Zeitpunkt (kein neuer Upload), nur geprüft
local firstT = fc.t
advance(3600)
fire("PLAYER_LOGIN")
advance(21)
check(db.catalog.t == firstT and db.catalog.checked == T.now - 1, "unverändert: kein neuer Zeitpunkt")
check(select(2, ns.scanCatalog()):find("Katalog unverändert: 4 Dungeons, 1 Raid.", 1, true), "Rückmeldung unverändert")
-- Ein Patch bringt einen neuen Dungeon: neuer Zeitpunkt
W.lfg.activities[1984] = { fullName = "Halle der Thane", categoryID = 2, mapID = 3065, minLevel = 13, maxLevelSuggestion = 20, maxNumPlayers = 5 }
W.maps[3065] = "Die Halle der Thane"
advance(60)
local okNew, noteNew = ns.scanCatalog()
check(okNew and db.catalog.t == T.now and inst(3065) and inst(3065).n == "Die Halle der Thane" and #db.catalog.instances == 6
  and noteNew:find("5 Dungeons, 1 Raid aus der Gruppensuche", 1, true), "neuer Dungeon: neuer Zeitpunkt")
-- Knopf: neuer Zeitpunkt auch ohne Änderung (alles noch einmal hochladen)
advance(60)
find("Button", "Katalog neu einlesen"):Click()
check(db.catalog.t == T.now, "Knopf: neuer Zeitpunkt")

-- Client ohne Namen über die ID: Name aus den Aktivitäten (gemeinsamer Anfang, sonst der kürzeste)
W.zoneIgnoresId = true
advance(60)
ns.scanCatalog()
check(inst(189).n == "Scharlachrotes Kloster" and inst(389).n == "Ragefireabgrund" and inst(3065).n == "Halle der Thane"
  and inst(229).n == "Obere Blackrockspitze", "Namen aus den Aktivitäten: " .. inst(189).n .. ", " .. inst(229).n)
W.zoneIgnoresId = nil
W.lfg.activities[805].fullName = "Scharlachrotes Kloster - Fänge"
W.lfg.activities[829].fullName = "Scharlachrotes Kloster - Fäulnis"
W.maps[189] = nil
ns.scanCatalog()
check(inst(189).n == "Scharlachrotes Kloster", "gemeinsamer Anfang ohne halbe Umlaute: " .. inst(189).n)

-- Retail: Gruppensuche und Abenteuerführer zusammen (Level aus der einen, Bosse aus der anderen)
W.ej.tiers, W.ej.current = tiers, 1
W.maps[189] = "Scharlachrotes Kloster"
find("Button", "Katalog neu einlesen"):Click()
local both = db.catalog
check(both.src == "lfg+ej" and both.ej and both.complete and inst(409).j == 741 and #inst(409).b == 3 and inst(409).size == 40
  and inst(409).tier == "Classic" and inst(48).j and inst(48).min == 24 and inst(532) and inst(532).j == 745 and inst(532).min == nil,
  "Retail: Gruppensuche und Abenteuerführer zusammengeführt")
-- Abenteuerführer nicht fällig: seine Einträge aus dem letzten Katalog bleiben
advance(60)
ns.scanCatalog()
check(db.catalog.src == "lfg+ej" and #inst(409).b == 3 and db.catalog.t == both.t, "Abenteuerführer nicht fällig: Bosse bleiben")
W.lfg = nil
advance(60)
ns.scanCatalog()
check(db.catalog.src == "ej" and not db.catalog.complete, "ohne Gruppensuche: nur Abenteuerführer, nicht vollständig")
W.maps = nil
takeSent()

-- Berufe: alle Werte von GetProfessions, auch ein sechster (Erste Hilfe) ---------
local meP = ns.me()
W.professions = { 1, 2, nil, 4, 5, 6 }
W.professionInfo = { { "Kürschnerei", 120 }, { "Lederverarbeitung", 120 }, nil, { "Angeln", 30 }, { "Kochen", 50 },
  { "Erste Hilfe", 75 } }
advance(61)
fire("PLAYER_MONEY")
check(ns.sendNow() ~= nil and db.latest[meP].p == "Angeln=30,Erste Hilfe=75,Kochen=50,Kürschnerei=120,Lederverarbeitung=120",
  "alle Berufe, auch Erste Hilfe als sechster Wert: " .. tostring(db.latest[meP].p))
W.professions, W.professionInfo = nil, nil
takeSent()

out(("OK: %d Prüfungen"):format(passed))
