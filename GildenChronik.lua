-- Gilden-Chronik
-- Jeder Client mit Addon meldet seinen Charakter per Addon-Nachricht an die Gilde und
-- speichert nur die eigenen Charaktere. Wer das Sammler-Programm laufen hat, ist der
-- Sammler (Haken „Ich sammle für die Gilde“): Nur er speichert alles, was er von anderen
-- hört, und die Level aus der Gildenliste, also auch für Mitglieder ohne Addon.
-- Die Daten landen erst bei /reload oder Logout auf der Platte.
-- Das Fenster (Status und Anleitung) steckt in UI.lua, Boss-Versuche und Diagnose in Kills.lua,
-- der Verlauf (Levelaufstiege, die der Sammler verpasst hat, nachliefern) in Verlauf.lua.

local ADDON, ns = ...
local PREFIX = "GCHR"
local PROTO = 1
local SEND_THROTTLE = 60      -- Sekunden zwischen zwei eigenen Meldungen
local MANUAL_THROTTLE = 10    -- „Jetzt senden“ höchstens alle 10 Sekunden
local ROSTER_THROTTLE = 300   -- Sekunden zwischen zwei Gildenlisten-Scans (nur als Sammler)
local REMIND_INTERVAL = 1800  -- Sammler: Hinweis auf /reload höchstens alle 30 Minuten
local ACK_INTERVAL = 600      -- Sammler: Empfang je Mitglied höchstens alle 10 Minuten bestätigen
local ACK_GAP = 1.2           -- Abstand zwischen zwei Nachrichten der Postausgänge (Drosselung von WoW)
local MIN_TS = 1577836800     -- 2020: ältere Zeitpunkte nimmt die Datenbank nicht
local MAX_SNAPSHOTS = 20000

local DB
local lastSend, lastRoster, lastRemind, sendQueued = 0, 0, 0, false
-- Beim Ausloggen und auf Ladebildschirmen liefern GetMoney() & Co. schon 0 oder nichts.
-- Deshalb nur in der Welt abfragen; live ist der zuletzt dort gesehene eigene Stand.
local inWorld, live = false, nil
local frame = CreateFrame("Frame")

-- Was in dieser Sitzung passiert ist, für das Fenster. Wird nicht gespeichert.
local state = {
  sentAt = nil,     -- letzte eigene Meldung, die rausging
  blockedAt = nil,  -- letzte, die WoW nicht senden ließ (Kampf, Instanz, Drosselung)
  heard = {},       -- Charakter -> Zeit seiner letzten Meldung
  heardCount = 0,
  lastHeard = nil,
  confirmed = {},   -- Sammler -> Zeit, zu der er den Empfang bestätigt hat
  acked = {},       -- nur als Sammler: Charakter -> Zeit der letzten Bestätigung
  newEntries = 0,   -- Snapshots seit dem Laden, noch nicht in der Datei
  loginAt = 0,
}
ns.state = state

local function changed()
  if ns.onChange then ns.onChange() end
end
ns.changed = changed

-- Midnight-Regel: Secret Values dürfen nicht gespeichert oder verglichen werden.
local function clean(v)
  if issecretvalue and issecretvalue(v) then return nil end
  return v
end

local function realm()
  local r = GetNormalizedRealmName()
  if not r or r == "" then r = (GetRealmName() or ""):gsub("%s", "") end
  return r
end

local function fullName(name)
  if not name or name == "" then return nil end
  if name:find("-", 1, true) then return name end
  return name .. "-" .. realm()
end
ns.fullName = fullName

-- WoW Forever: Vor- und Nachname („Arthas Menethil“), eindeutig ist nur beides zusammen. Gildenliste und
-- Absender von Addon-Nachrichten liefern „Vorname Nachname“, UnitName den Nachnamen als zweiten Wert, wo
-- in Retail der Realm steht (beim eigenen Charakter steht dort in Retail nie etwas).
local function surnames()
  if RegionalUniqueNamesEnabled then
    local ok, on = pcall(RegionalUniqueNamesEnabled)
    if ok and on == true then return true end
  end
  local ok, _, last = pcall(UnitName, "player")
  last = ok and clean(last) or nil
  return type(last) == "string" and last ~= ""
end
ns.surnames = surnames

-- Die zwei Werte von UnitName zu einem Namen wie in der Gildenliste: Forever „Vorname Nachname“,
-- Retail „Name“ bzw. „Name-Realm“ bei anderen Realms
local function joinName(name, second)
  if type(second) ~= "string" or second == "" then return name end
  return name .. (surnames() and " " or "-") .. second
end
ns.joinName = joinName

-- Bleibt der Name einmal unlesbar (Secret Value), gilt der zuletzt gelesene: ohne Nachnamen wäre es
-- in Forever ein anderer Charakter
local myName
local function me()
  local ok, name, second = pcall(UnitName, "player")
  if ok and type(clean(name)) == "string" and name ~= "" and (second == nil or clean(second) ~= nil) then
    myName = fullName(joinName(name, second))
  end
  return myName
end
ns.me = me

-- Ziel fürs Flüstern so, wie WoW den Absender liefert: in Forever ohne Realm („Vorname Nachname“).
-- Retail-Namen haben kein Leerzeichen und bleiben, wie sie sind.
function ns.whisperTarget(char)
  if char and char:find(" ", 1, true) then
    local suffix = "-" .. realm()
    if char:sub(-#suffix) == suffix then return char:sub(1, -#suffix - 1) end
  end
  return char
end

-- Konto-ID aus der Web-App („Mein Profil“ → „ID kopieren“), z. B. 1a2b3c4d-…-…; gilt für alle
-- Charaktere dieses Accounts. Geht mit jeder Meldung an die Gilde; der Sammler gibt die
-- Zuordnung Charakter → Konto an die Chronik weiter, die den Charakter dem Konto zuordnet.
local UUID = "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"

local function validId(id)
  id = strtrim(tostring(id or "")):lower()
  if id:match(UUID) then return id end
end
ns.validId = validId

-- Ältere Clients geben nichts oder true/false zurück, neuere ein Enum.SendAddonMessageResult.
local function trySend(msg, channel, target)
  local ok, res = pcall(C_ChatInfo.SendAddonMessage, PREFIX, msg, channel, target)
  if not ok or res == false then return false end
  if type(res) == "number" then
    local results = Enum and Enum.SendAddonMessageResult
    return res == ((results and results.Success) or 0)
  end
  return true
end

-- Jedes Ergebnis landet in den Messdaten (Kills.lua): wo WoW Nachrichten sperrt
local function send(msg, channel, target)
  if channel == "WHISPER" then target = ns.whisperTarget(target) end
  local ok = trySend(msg, channel, target)
  if ns.noteSend then ns.noteSend(channel, ok) end
  return ok
end
ns.send = send

-- Bestätigungen des Sammlers an die Gilde (A;… für Boss-Versuche, Q;… für den Verlauf): der Reihe
-- nach mit Abstand, sobald Senden geht. Jeder Schlüssel steht höchstens einmal in der Schlange.
-- build() liefert die Nachricht (nil: nichts mehr zu bestätigen), sent() nach dem Senden, ob noch
-- etwas übrig ist; dann bleibt der Eintrag vorne und geht als nächste Nachricht raus.
local ackQueue, ackSet, flushing = {}, {}, false

function ns.flushAcks()
  if flushing or #ackQueue == 0 or not IsInGuild() then return end
  flushing = true
  local function step()
    local item = ackQueue[1]
    if not item then
      flushing = false
      return
    end
    local msg = item.build()
    if msg and not send(msg, "GUILD") then
      flushing = false -- später noch einmal (Ticker, nach dem Kampf, beim Betreten der Welt)
      return
    end
    if not (msg and item.sent and item.sent()) then
      table.remove(ackQueue, 1)
      ackSet[item.id] = nil
    end
    if msg then C_Timer.After(ACK_GAP, step) else step() end
  end
  step()
end

function ns.queueAck(id, build, sent)
  if not ackSet[id] then
    ackSet[id] = true
    ackQueue[#ackQueue + 1] = { id = id, build = build, sent = sent }
  end
  ns.flushAcks()
end

-- Postausgänge an den Sammler (Boss-Versuche in Kills.lua, Verlauf in Verlauf.lua): Immer nur einer
-- flüstert und wartet auf seine Bestätigung, sonst greift die Drosselung von WoW. Wer fertig ist,
-- gibt frei und stößt die anderen an (Boss-Versuche zuerst, die braucht der Kalender noch am selben
-- Abend, dann der Verlauf).
local outboxOwner

function ns.claimOutbox(who)
  if outboxOwner and outboxOwner ~= who then return false end
  outboxOwner = who
  return true
end

function ns.releaseOutbox(who)
  if outboxOwner ~= who then return end
  outboxOwner = nil
  C_Timer.After(ACK_GAP, function()
    if ns.pumpKills then ns.pumpKills() end
    if ns.pumpHistory then ns.pumpHistory() end
  end)
end

local function packed(...)
  return { n = select("#", ...), ... }
end

-- "Kürschnerei=250,Kochen=150". Die Berufe-API in Forever ist noch ungetestet,
-- deshalb alles hinter pcall: lieber keine Berufe als ein kaputtes Addon. Retail liefert
-- Hauptberuf 1 und 2, Archäologie, Angeln und Kochen; Clients mit Erster Hilfe einen Wert mehr,
-- deshalb alle Werte.
local function professions()
  if not GetProfessions or not GetProfessionInfo then return "" end
  local res = packed(pcall(GetProfessions))
  if not res[1] then return "" end
  local parts, seen = {}, {}
  for i = 2, res.n do
    local idx = res[i]
    local okInfo, name, _, rank
    if idx ~= nil and not seen[idx] then
      seen[idx] = true
      okInfo, name, _, rank = pcall(GetProfessionInfo, idx)
    end
    rank = clean(rank)
    if okInfo and name and rank then
      parts[#parts + 1] = name .. "=" .. rank
    end
  end
  table.sort(parts)
  return table.concat(parts, ",")
end

local function same(a, b)
  return a.l == b.l and a.cls == b.cls and a.m == b.m and a.d == b.d and a.p == b.p
end
ns.sameSnapshot = same

-- Stand in die Datei, in der Reihenfolge des Speicherns. latest nur, wenn er der neueste dieses
-- Charakters ist: Nachgelieferte Stände (Verlauf) sind meist älter.
local function store(s)
  DB.snapshots[#DB.snapshots + 1] = s
  local last = DB.latest[s.c]
  if not last or (last.t or 0) <= s.t then DB.latest[s.c] = s end
  if #DB.snapshots > MAX_SNAPSHOTS then table.remove(DB.snapshots, 1) end
  state.newEntries = state.newEntries + 1
  changed()
end
ns.storeSnapshot = store

-- Neuer Stand, wenn sich etwas geändert hat; liefert ihn dann. at: Zeitpunkt des Stands laut
-- Absender (ab 1.1.0), sonst jetzt. Weicht er ab, merkt sich rt, wann dieser Account ihn
-- gespeichert hat: Danach richtet sich das Sammler-Programm beim Hochladen.
local function record(char, s, at)
  if not char then return end
  local last = DB.latest[char]
  if last and same(last, s) then return end
  local t = GetServerTime()
  s.c = char
  s.t = at or t
  if s.t ~= t then s.rt = t end
  store(s)
  return s
end

local function selfSnapshot()
  local _, classFile = UnitClass("player")
  local name = me()
  return name, {
    l = clean(UnitLevel("player")),
    cls = classFile,
    m = DB.shareGold and clean(GetMoney()) or nil, -- nur mit Haken „Ich teile mein Gold“
    d = DB.deaths[name] or 0,
    p = professions(),
    src = "a",
  }
end

local function copy(t)
  local c = {}
  for k, v in pairs(t) do c[k] = v end
  return c
end

-- Eigenen Stand neu abfragen, aber nur in der Welt; sonst bleibt der letzte.
local function refreshLive()
  if inWorld then
    local name, s = selfSnapshot()
    live = { name = name, s = s }
  end
  return live
end

local function broadcast(force)
  if not IsInGuild() or not inWorld then return end
  local t = GetServerTime()
  if not force and t - lastSend < SEND_THROTTLE then
    if not sendQueued then
      sendQueued = true
      C_Timer.After(SEND_THROTTLE, function()
        sendQueued = false
        broadcast(true)
      end)
    end
    return
  end
  lastSend = t
  local cur = refreshLive()
  local s = copy(cur.s)
  local recorded = record(cur.name, s)
  -- Zeitpunkt des Stands: jetzt, wenn er neu ist, sonst seit wann er gilt. Ein Sammler, der ihn
  -- verpasst hat, speichert ihn so mit der richtigen Zeit (z. B. Levelaufstieg, als er offline war).
  local last = DB.latest[cur.name]
  local at = s.t or (last and same(last, s) and last.t) or ""
  -- Höchstens etwa 180 Byte (Grenze 255), auch mit fünf langen Berufen und der Konto-ID
  local msg = table.concat({ PROTO, s.l or "", s.cls or "", s.m or "", s.d, s.p, DB.profileId or "", at }, ";")
  -- Kann in Instanzen/Kampf gesperrt sein; dann geht die Meldung verloren und
  -- die nächste (Level-up, Gold, Login) holt es nach, Levelaufstiege auch der Verlauf.
  local ok = send(msg, "GUILD")
  if ok then state.sentAt = t else state.blockedAt = t end
  -- Verlauf (Verlauf.lua): Levelaufstiege immer, sonst nur, was gerade kein Sammler hören konnte
  if recorded and ns.onOwnSnapshot then ns.onOwnSnapshot(recorded, ok and ns.onlineCollector() ~= nil) end
  changed()
end

-- „Jetzt senden“ im Fenster. false ohne Gilde, wenn die letzte Meldung gerade erst
-- rausging oder WoW sie blockiert hat.
function ns.sendNow()
  if not IsInGuild() or GetServerTime() - lastSend < MANUAL_THROTTLE then return false end
  broadcast(true)
  return state.sentAt == lastSend
end

function ns.profileId()
  return DB.profileId
end

-- Konto-ID übernehmen; leer entfernt sie. false: keine gültige ID.
function ns.setProfileId(raw)
  if strtrim(tostring(raw or "")) == "" then
    DB.profileId, DB.links[me()] = nil, nil
    changed()
    return true
  end
  local id = validId(raw)
  if not id then return false end
  DB.profileId = id
  DB.links[me()] = id
  if IsInGuild() then broadcast(true) end -- sofort, damit der Sammler sie hat
  changed()
  return true
end

-- Sammler-Modus (gilt für den ganzen Account, wie die SavedVariables-Datei):
-- Der Sammler meldet sich beim Login mit „C;1“ im Gildenkanal, darauf schicken alle
-- Addons ihren Stand noch einmal. Meldungen bestätigt er per Flüstern mit „C;1“,
-- je Mitglied höchstens alle 10 Minuten. „C;0“ heißt: sammelt nicht mehr.
local function announce(on)
  if IsInGuild() then send(on and "C;1" or "C;0", "GUILD") end
end

function ns.isCollector()
  return DB.collector == true
end

-- Gold geht nur mit, wenn der Account es freigibt (Standard aus, gilt für alle
-- Charaktere). Wer es in der Web-App sieht, regelt dort „Gold teilen“. Ohne Haken
-- bleibt das Feld in der Meldung leer, die Chronik kennt dann kein neues Gold.
function ns.sharesGold()
  return DB.shareGold == true
end

function ns.setShareGold(on)
  DB.shareGold = on or nil
  refreshLive()
  if IsInGuild() then broadcast(true) end -- gleich mit bzw. ohne Gold melden
  changed()
end

-- Erinnerung an /reload (nur als Sammler), abschaltbar in den Einstellungen.
function ns.remindOn()
  return not DB.noRemind
end

function ns.setRemind(on)
  DB.noRemind = (not on) or nil
  changed()
end

local scanRoster -- Gildenliste, weiter unten

function ns.setCollector(on)
  DB.collector = on or nil
  wipe(state.acked)
  announce(on)
  -- Gleich die Gildenliste lesen: Ohne Haken stand nichts davon in der Datei, und erst danach
  -- kennt der Sammler die Mitglieder, deren Boss-Versuche und Verlauf er annimmt.
  if on then scanRoster(true) end
  -- Eigene Boss-Versuche und der Verlauf im Postausgang gehören jetzt in die eigene Datei
  if on and ns.pumpKills then ns.pumpKills() end
  if on and ns.pumpHistory then ns.pumpHistory() end
  changed()
end

-- Wer aus der Gilde gerade online ist, laut Gildenliste.
local function guildOnline()
  local online = {}
  for i = 1, GetNumGuildMembers() do
    local name, _, _, _, _, _, _, _, isOnline = GetGuildRosterInfo(i)
    local char = fullName(name)
    if char then online[char] = isOnline and true or false end
  end
  return online
end
ns.guildOnline = guildOnline

-- Ein Sammler, der gerade online ist (für das Flüstern aus dem Postausgang), sonst nil.
-- Online heißt: laut Gildenliste oder in den letzten 5 Minuten gehört. Flüstern an jemanden,
-- der offline ist, bringt eine Fehlermeldung in den Chat.
function ns.onlineCollector()
  local online, t, self = guildOnline(), GetServerTime(), me()
  local best, bestRank, bestT
  for name, heard in pairs(DB.collectors) do
    if name ~= self and (online[name] or t - heard < 300) then
      local rank = state.confirmed[name] and 2 or 1
      if not best or rank > bestRank or (rank == bestRank and heard > bestT) then
        best, bestRank, bestT = name, rank, heard
      end
    end
  end
  return best
end

local function onCollector(char, on, whisper)
  local t = GetServerTime()
  if not on then
    DB.collectors[char], state.confirmed[char] = nil, nil
  else
    DB.collectors[char] = t -- zuletzt gehört, wird auch bei jeder Datenmeldung aktualisiert
    if whisper then
      state.confirmed[char] = t
    else
      -- Der Sammler ist gerade online gekommen: eigenen Stand nachliefern. Zufällig
      -- verzögert, damit nicht die ganze Gilde in derselben Sekunde sendet.
      C_Timer.After(math.random(3, 30), function() broadcast(true) end)
      if ns.onCollectorOnline then ns.onCollectorOnline() end -- Postausgang (Kills.lua)
      if ns.onCollectorOnlineHistory then ns.onCollectorOnlineHistory() end -- Verlauf (Verlauf.lua)
    end
  end
  changed()
end

-- Meldung eines anderen Mitglieds. Speichern (Stand, Konto-ID) und bestätigen nur als Sammler;
-- alle anderen Addons merken sich nur, wen sie in dieser Sitzung gehört haben.
local function onData(char, sender, msg)
  local v, l, cls, m, d, p, pid, at = strsplit(";", msg)
  if tonumber(v) ~= PROTO then return end
  local t = GetServerTime()
  if DB.collectors[char] then DB.collectors[char] = t end
  if not state.heard[char] then state.heardCount = state.heardCount + 1 end
  state.heard[char] = t
  state.lastHeard = char
  if DB.collector then
    local id = validId(pid)
    if id then DB.links[char] = id end
    -- Ab 1.1.0 mit dem Zeitpunkt des Stands; ältere Addons und Unplausibles: jetzt
    at = tonumber(at)
    if at and (at < MIN_TS or at > t + 60) then at = nil end
    record(char, {
      l = tonumber(l),
      cls = (cls ~= "" and cls) or nil,
      m = tonumber(m),
      d = tonumber(d) or 0,
      p = p or "",
      src = "a",
    }, at)
    local acked = state.acked[char]
    if (not acked or t - acked >= ACK_INTERVAL) and send("C;1", "WHISPER", sender) then
      state.acked[char] = t
    end
  end
  changed()
end

-- Gildenbank: Gold beim Öffnen der Bank lesen und an die Gilde melden („B;<Kupfer>“),
-- damit der Sammler es hat, auch wenn jemand anderes die Bank geöffnet hat.
local function setGuildBank(money, char)
  local last = DB.guildBank
  if last and last.m == money then return end
  DB.guildBank = { m = money, t = GetServerTime(), c = char }
  changed()
end

-- fromUpdate: GUILDBANK_UPDATE_MONEY, dann ist der Wert geladen (auch 0 ist echt)
local function readGuildBank(fromUpdate)
  if not GetGuildBankMoney or not IsInGuild() then return end
  local money = clean(GetGuildBankMoney())
  if type(money) ~= "number" or money < 0 or (money == 0 and not fromUpdate) then return end
  local last = DB.guildBank
  setGuildBank(money, me())
  if not last or last.m ~= money then send("B;" .. money, "GUILD") end
end

local function onAddonMessage(prefix, msg, channel, sender)
  if prefix ~= PREFIX then return end
  local char = fullName(sender)
  if not char or char == me() then return end
  local kind, flag = strsplit(";", msg)
  if kind == "B" then
    local money = tonumber(flag)
    if channel == "GUILD" and money and money >= 0 then setGuildBank(money, char) end
  elseif kind == "C" then
    if channel == "GUILD" or channel == "WHISPER" then
      onCollector(char, flag == "1", channel == "WHISPER")
    end
  elseif kind == "K" or kind == "G" or kind == "A" then
    -- Boss-Versuche (Kills.lua)
    if ns.onKillMessage then ns.onKillMessage(kind, msg, channel, sender, char) end
  elseif kind == "H" or kind == "Q" then
    -- Verlauf (Verlauf.lua)
    if ns.onHistoryMessage then ns.onHistoryMessage(kind, msg, channel, sender, char) end
  elseif channel == "GUILD" then
    onData(char, sender, msg)
  end
end

-- Level aus der Gildenliste: deckt Mitglieder ohne Addon ab, nur als Sammler (ab 1.3.0; alle
-- anderen Addons speichern nur die eigenen Charaktere). Dabei lernt der Sammler die Mitglieder
-- kennen, deren Boss-Versuche und Verlauf er annimmt. Gold/Berufe/Tode werden vom letzten
-- bekannten Stand übernommen. force: ohne Drosselung (Haken gerade gesetzt).
-- Dazu die ganze Liste in DB.roster (ab 1.5.0, ersetzt die vorige): Wer in der Web-App fehlt,
-- wird dort inaktiv. Nur vollständig gelesene Listen, direkt nach dem Login ist sie oft noch leer.
scanRoster = function(force)
  local guild = GetGuildInfo("player")
  DB.guild = guild or DB.guild
  if not DB.collector or not IsInGuild() then return end
  local t = GetServerTime()
  if not force and t - lastRoster < ROSTER_THROTTLE then return end
  lastRoster = t
  local mine = me()
  local members, complete = {}, guild ~= nil
  local total = GetNumGuildMembers()
  for i = 1, total do
    local name, _, _, level, _, _, _, _, _, _, classFile = GetGuildRosterInfo(i)
    local char = fullName(name)
    level = clean(level)
    if char then members[#members + 1] = char else complete = false end
    -- Den eigenen Charakter meldet das Addon selbst, mit dem Zeitpunkt des Levelaufstiegs
    if char and level and char ~= mine then
      local last = DB.latest[char]
      if not last or (last.l or 0) < level then
        record(char, {
          l = level,
          cls = classFile or (last and last.cls),
          m = last and last.m,
          d = (last and last.d) or 0,
          p = (last and last.p) or "",
          src = "r",
        })
      end
    end
  end
  if complete and #members > 0 then
    table.sort(members)
    DB.roster = { t = t, g = guild, m = members }
  end
end

-- Der Sammler soll ab und zu /reload machen, sonst sieht das Sammler-Programm nichts Neues.
local function remind()
  local t = GetServerTime()
  if not DB.collector or DB.noRemind or state.newEntries == 0 then return end
  if t - math.max(state.loginAt, lastRemind) < REMIND_INTERVAL then return end
  lastRemind = t
  print(("|cffe0b458Gilden-Chronik|r: %d neue Einträge seit dem letzten Speichern. /reload schreibt sie in die Datei, dann lädt der Sammler auf dem PC sie hoch.")
    :format(state.newEntries))
end

local function init()
  GildenChronikDB = GildenChronikDB or {}
  DB = GildenChronikDB
  DB.v = 1
  DB.snapshots = DB.snapshots or {}
  DB.latest = DB.latest or {}
  DB.deaths = DB.deaths or {}
  DB.collectors = DB.collectors or {}
  DB.links = DB.links or {} -- Charakter -> Konto-ID (eigene und gehörte)
  DB.minimap = DB.minimap or {} -- Symbol an der Minimap: hide, angle (Grad)
  if ns.initKills then ns.initKills(DB) end -- kills, outbox, catalog, diag, log
  if ns.initHistory then ns.initHistory(DB) end -- history, own
  -- Rezepte aus dem Berufsfenster (nur 1.3.0) gibt es nicht mehr: Listen nicht weiter mitschleppen
  DB.recipes = nil
end

function ns.db()
  return DB
end

-- Bis 1.1.1 fehlte in Forever der eigene Nachname: Was unter „Vorname-Realm“ liegt, gehört dem vollen
-- Namen. Sonst finge der Todeszähler bei 0 an und der Verlauf von vorn. Läuft bei jedem Login für den
-- eingeloggten Charakter, danach gibt es nichts mehr umzuschreiben.
local function migrateOwnName()
  local full = me()
  local ok, first = pcall(UnitName, "player")
  first = ok and clean(first) or nil
  if not full or type(first) ~= "string" or first == "" then return end
  local old = fullName(first)
  if old == full then return end
  local moved = 0
  for _, list in ipairs({ DB.snapshots, DB.history or {} }) do
    for _, s in ipairs(list) do
      if s.c == old then
        s.c = full
        moved = moved + 1
      end
    end
  end
  local last, cur = DB.latest[old], DB.latest[full]
  if last then
    -- Das Echo der eigenen Meldungen lag schon unter dem vollen Namen: der neuere Stand gilt
    if not cur or (cur.t or 0) < (last.t or 0) then DB.latest[full] = last end
    DB.latest[full].c = full
    DB.latest[old] = nil
  end
  if DB.deaths[old] then
    DB.deaths[full] = math.max(DB.deaths[full] or 0, DB.deaths[old])
    DB.deaths[old] = nil
  end
  for _, t in ipairs({ DB.links, DB.own or {} }) do
    if t[old] ~= nil then
      if t[full] == nil then t[full] = t[old] end
      t[old] = nil
    end
  end
  if DB.guildBank and DB.guildBank.c == old then DB.guildBank.c = full end
  for _, kill in ipairs(DB.kills or {}) do
    if kill.r == old then kill.r = full end
  end
  if ns.log then ns.log(("Name mit Nachnamen: %d Einträge von %s auf %s umgeschrieben"):format(moved, old, full)) end
end

frame:SetScript("OnEvent", function(_, event, ...)
  if event == "ADDON_LOADED" then
    if ... == ADDON then init() end
  elseif event == "PLAYER_LOGIN" then
    state.loginAt = GetServerTime()
    migrateOwnName()
    DB.char = me() -- wer gesammelt hat, steht so beim Upload in der Chronik
    if DB.profileId then DB.links[me()] = DB.profileId end
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
    C_Timer.After(10, function()
      if C_GuildInfo and C_GuildInfo.GuildRoster then C_GuildInfo.GuildRoster() end
      broadcast(true)
      if DB.collector then announce(true) end
    end)
    C_Timer.NewTicker(300, remind)
    -- Beim allerersten Start erklärt sich das Addon selbst.
    if not DB.welcomed then
      DB.welcomed = true
      C_Timer.After(5, function() if ns.showWindow then ns.showWindow() end end)
    end
  elseif event == "PLAYER_ENTERING_WORLD" then
    inWorld = true
    -- Kurz warten, bis Gold und Berufe sicher geladen sind
    C_Timer.After(3, refreshLive)
  elseif event == "PLAYER_LEAVING_WORLD" then
    inWorld = false
  elseif event == "PLAYER_LEVEL_UP" then
    -- UnitLevel hängt beim Event noch einen Tick hinterher.
    C_Timer.After(1, function() broadcast(true) end)
  elseif event == "PLAYER_MONEY" or event == "SKILL_LINES_CHANGED" then
    -- Sofort merken, auch wenn die Meldung wegen der Drosselung erst später rausgeht
    refreshLive()
    broadcast(false)
  elseif event == "PLAYER_DEAD" then
    local name = me()
    DB.deaths[name] = (DB.deaths[name] or 0) + 1
    refreshLive()
    broadcast(false)
  elseif event == "CHAT_MSG_ADDON" then
    onAddonMessage(...)
  elseif event == "GUILD_ROSTER_UPDATE" then
    scanRoster()
    changed()
  elseif event == "GUILDBANK_UPDATE_MONEY" then
    readGuildBank(true)
  elseif event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" or event == "GUILDBANKFRAME_OPENED" then
    local kind = ...
    local banker = Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.GuildBanker
    if event == "GUILDBANKFRAME_OPENED" or (banker and kind == banker) then
      C_Timer.After(1, function() readGuildBank(false) end)
    end
  elseif event == "PLAYER_LOGOUT" then
    -- Kommt auch bei /reload, danach schreibt WoW die Datei. Beim Charakterwechsel liefert
    -- GetMoney() hier schon 0: deshalb den zuletzt in der Welt gesehenen Stand speichern.
    -- Geht nicht mehr an die Gilde, deshalb in den Verlauf (Stand am Ende des Tages).
    if live then
      local s = record(live.name, copy(live.s))
      if s and ns.onOwnSnapshot then ns.onOwnSnapshot(s, false) end
    end
    DB.savedAt = GetServerTime()
  end
end)

for _, e in ipairs({
  "ADDON_LOADED", "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "PLAYER_LEAVING_WORLD", "PLAYER_LEVEL_UP", "PLAYER_MONEY",
  "SKILL_LINES_CHANGED", "PLAYER_DEAD", "CHAT_MSG_ADDON", "GUILD_ROSTER_UPDATE",
  "PLAYER_LOGOUT",
}) do
  frame:RegisterEvent(e)
end

-- Gildenbank-Events gibt es nicht in jedem Client; unbekannte Events werfen beim Registrieren
for _, e in ipairs({ "GUILDBANK_UPDATE_MONEY", "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", "GUILDBANKFRAME_OPENED" }) do
  pcall(frame.RegisterEvent, frame, e)
end

local function say(s)
  print("|cffe0b458Gilden-Chronik|r: " .. s)
end

SLASH_GILDENCHRONIK1 = "/gchr"
SLASH_GILDENCHRONIK2 = "/chronik"
SlashCmdList.GILDENCHRONIK = function(msg)
  local cmd = strtrim(msg or ""):lower()
  local killsMissing = (cmd == "kill" or cmd:match("^kill%s") or cmd == "kills" or cmd == "diag" or cmd == "log")
    and not ns.reportKill
  if killsMissing then
    -- Kills.lua fehlt: WoW liest neue Dateien aus der .toc erst nach einem Neustart.
    say("Boss-Kills gibt es erst nach einem Neustart von WoW, /reload reicht nicht.")
  elseif cmd == "kill" or cmd:match("^kill%s") then
    local _, text = ns.reportKill(strtrim(strtrim(msg or ""):sub(5)))
    say(text)
  elseif cmd == "kills" then
    if ns.showWindow then ns.showWindow("kills") end
  elseif cmd == "diag" then
    say("Diagnose (Messdaten, bleiben auf deinem PC):")
    for _, l in ipairs(ns.diagLines()) do print(("  %s: %s"):format(l[1], l[2])) end
  elseif cmd == "log" then
    local lines = ns.logTail(20)
    say(#lines == 0 and "Das Log ist leer." or ("Die letzten %d Zeilen des Logs:"):format(#lines))
    for _, l in ipairs(lines) do print("  " .. l) end
  elseif cmd == "senden" then
    if ns.sendNow() then
      say("Stand an die Gilde gesendet.")
    else
      say("Nicht gesendet (keine Gilde, gerade erst gesendet oder von WoW blockiert).")
    end
  elseif cmd == "id" or cmd:match("^id%s") then
    local raw = strtrim(msg or ""):sub(3)
    if ns.setProfileId(raw) then
      say(DB.profileId and "Konto-ID gespeichert." or "Konto-ID entfernt.")
    else
      say("Das ist keine gültige ID. In der Web-App unter Mein Profil auf „ID kopieren“ klicken.")
    end
  elseif cmd == "minimap" and ns.setMinimapShown then
    ns.setMinimapShown(DB.minimap.hide == true)
    say(DB.minimap.hide and "Symbol an der Minimap ausgeblendet. /gchr minimap zeigt es wieder." or "Symbol an der Minimap eingeblendet.")
  elseif (cmd == "optionen" or cmd == "einstellungen") and ns.openOptions then
    ns.openOptions()
  elseif cmd == "status" then
    local chars = 0
    for _ in pairs(DB.latest) do chars = chars + 1 end
    say(("%d Snapshots von %d Charakteren, %d neu seit dem letzten Speichern.")
      :format(#DB.snapshots, chars, state.newEntries))
    if DB.collector and DB.roster then
      say(("Gildenliste: %d Mitglieder in %s, gelesen um %s."):format(#DB.roster.m, DB.roster.g, date("%H:%M", DB.roster.t)))
    end
    if ns.historyView and not ns.isCollector() then
      local h = ns.historyView()
      say(h.open == 0 and "Verlauf: alles beim Sammler."
        or ("Verlauf: %d Stände warten auf den Sammler, davon %d Levelaufstiege."):format(h.open, h.levels))
    end
  elseif ns.toggleWindow then
    ns.toggleWindow()
  else
    -- UI.lua fehlt: WoW liest neue Dateien aus der .toc erst nach einem Neustart.
    say("Das Fenster fehlt noch. Nach einem Update WoW komplett neu starten, /reload reicht nicht.")
  end
end
