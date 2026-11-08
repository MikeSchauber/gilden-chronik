-- Boss-Versuche (Kills und Wipes) mit der Gruppe, Postausgang an den Sammler, Katalog der Dungeons
-- und Raids aus dem Spiel (Gruppensuche, Abenteuerführer), Messdaten und Log. Format und Protokoll: docs/architektur.md.
-- Alles, was es in einem Client vielleicht nicht gibt, läuft hinter pcall, jeder gelesene Wert
-- geht durch clean() (Secret Values). Log und Messdaten enthalten nichts Persönliches: keine
-- Konto-ID, kein Gold, keine Namen von Mitspielern, nur Anzahlen. Namen stehen nur in kills[].g.

local ADDON, ns = ...

local KILL_PROTO = 1
local MAX_KILLS_COLLECTOR = 5000 -- Sammler: alles, was er hochlädt
local MAX_KILLS = 500            -- sonst nur die eigenen, für die Seite „Kills & Diagnose“
local MAX_LOG = 300
local MAX_OUTBOX = 200
local OUTBOX_MAX_AGE = 30 * 86400
local SAME_ATTEMPT = 180         -- derselbe Boss-Versuch bei verschiedenen Meldern (Sekunden)
local ACK_WAIT = 60              -- nach dem Senden so lange auf die Bestätigung warten
local RETRY = 600                -- erneuter Versuch frühestens nach 10 Minuten
local PART_GAP = 1.2             -- Abstand zwischen zwei Nachrichten (Drosselung von WoW)
local ASSEMBLY_TIMEOUT = 120     -- Sammler: unvollständige Meldungen verwerfen
local CATALOG_MAX_AGE = 7 * 86400
local NAME_MAX = 40              -- Bytes für Boss- und Instanznamen in Nachrichten
local MSG_MAX = 255
local TICK = 120

local DB
local frame = CreateFrame("Frame")
local starts = {}               -- encounterID -> Startzeit (ENCOUNTER_START)
local sending                   -- { k, seq, target } beim Senden und Warten auf die Bestätigung
local seq = 0
local assembling = {}           -- Sammler: Schlüssel -> { head, parts, n, from, at }
local catalogQueued = false     -- Katalog einlesen, sobald der Kampf vorbei ist
local mergeQueue = {}           -- Boss-Versuche, deren Gruppe teils geheim war: nach dem Kampf ergänzen

local function now()
  return GetServerTime()
end

local function bump(t, key, n)
  t[key] = (t[key] or 0) + (n or 1)
end

-- Wie clean() im Kern, zählt aber für die Messdaten, woher Secret Values kamen.
local function clean(v, source)
  if issecretvalue and issecretvalue(v) then
    bump(DB.diag.secrets, source or "andere")
    return nil
  end
  return v
end

-- Rückgabewert für die Messdaten: Typ und Wert, „geheim“ bei Secret Values
local function describe(v)
  if issecretvalue and issecretvalue(v) then return "geheim" end
  if v == nil then return "nil" end
  local s = tostring(v)
  if #s > 40 then s = s:sub(1, 40) .. "…" end
  return type(v) .. " " .. s
end

local function short(name)
  return (tostring(name or ""):gsub("%-.*", ""))
end

-- Höchstens max Bytes, ohne Zeichen zu zerschneiden; ohne ; und Steuerzeichen (Trenner im Protokoll)
local function cut(s, max)
  s = strtrim((tostring(s or ""):gsub("[;|%c]", " ")))
  if #s <= max then return s end
  local i = max + 1
  while i > 1 and s:byte(i) >= 0x80 and s:byte(i) < 0xC0 do i = i - 1 end
  return s:sub(1, i - 1)
end

local function log(fmt, ...)
  if not DB then return end
  local msg = select("#", ...) > 0 and fmt:format(...) or fmt
  local l = DB.log
  l[#l + 1] = date("%Y-%m-%d %H:%M:%S", now()) .. " " .. msg
  while #l > MAX_LOG do table.remove(l, 1) end
end
ns.log = log

local function buildInfo()
  local ok, version, build, _, toc = pcall(GetBuildInfo)
  if not ok then return nil, nil, nil end
  local locale = GetLocale and GetLocale() or nil
  return tostring(version or "?") .. "." .. tostring(build or "?"), locale, toc
end

local function inInstance()
  local ok, inside = pcall(IsInInstance)
  return ok and clean(inside, "instance") and true or false
end

local function inCombat()
  return InCombatLockdown and InCombatLockdown() and true or false
end

-- GetInstanceInfo(): Name, Typ, Schwierigkeit, …, instanceID (8.)
local function instanceInfo()
  local ok, name, itype, difficulty, _, maxPlayers, _, _, instanceID = pcall(GetInstanceInfo)
  if not ok then return {} end
  DB.diag.lastInstance = {
    t = now(),
    args = { describe(name), describe(itype), describe(difficulty), describe(maxPlayers), describe(instanceID) },
  }
  name, itype = clean(name, "instance"), clean(itype, "instance")
  difficulty, instanceID = clean(difficulty, "instance"), clean(instanceID, "instance")
  return {
    name = type(name) == "string" and name ~= "" and name or nil,
    type = type(itype) == "string" and itype ~= "" and itype or nil,
    difficulty = type(difficulty) == "number" and difficulty or nil,
    id = type(instanceID) == "number" and instanceID or nil,
  }
end

-- Gruppe -------------------------------------------------------------------

-- Zweiter Wert: Retail Realm, Forever Nachname. Ist er geheim, fehlt der ganze Name (nach dem Kampf
-- ergänzt): Ohne Nachnamen wäre es in Forever ein anderer Charakter.
local function unitFullName(unit)
  local ok, name, second = pcall(UnitName, unit)
  if not ok then return nil end
  name = clean(name, "group")
  if second ~= nil and clean(second, "group") == nil then return nil end
  if type(name) ~= "string" or name == "" or name == UNKNOWNOBJECT then return nil end
  return ns.fullName(ns.joinName(name, second))
end

local function mapOf(unit)
  if not (C_Map and C_Map.GetBestMapForUnit) then return nil end
  local ok, map = pcall(C_Map.GetBestMapForUnit, unit)
  map = ok and clean(map, "group") or nil
  return type(map) == "number" and map or nil
end

local function zoneText()
  local ok, zone = pcall(GetRealZoneText)
  zone = ok and clean(zone, "instance") or nil
  return type(zone) == "string" and zone ~= "" and zone or nil
end

-- Gruppe beim Kill als "Name-Realm:<online><in der Instanz>", z. B. "Liriel-Blackrock:11";
-- in der Instanz: 1 ja, 0 nein, ? unbekannt. Ohne Gruppe nur der eigene Charakter.
-- Liefert die Liste und die Messdaten (Methode, Anzahlen, wie die Zone erkannt wurde); die
-- Messdaten landen nur mit measure in DB.diag (nicht beim Nachtragen nach dem Kampf).
local function capture(instName, measure)
  local list, seen = {}, {}
  local secretsBefore = DB.diag.secrets.group or 0
  local g = { t = now(), method = "solo", members = 0, inside = 0, outside = 0, unknown = 0, how = {} }
  local function add(char, online, inside, how)
    if not char or seen[char] then return end
    seen[char] = true
    local flag = (inside == true and "1") or (inside == false and "0") or "?"
    list[#list + 1] = char .. ":" .. (online and "1" or "0") .. flag
    g.members = g.members + 1
    if flag == "1" then
      g.inside = g.inside + 1
    elseif flag == "0" then
      g.outside = g.outside + 1
    else
      g.unknown = g.unknown + 1
    end
    bump(g.how, how)
  end

  local okRaid, raid = pcall(IsInRaid)
  local okGroup, group = pcall(IsInGroup)
  raid, group = okRaid and clean(raid, "group"), okGroup and clean(group, "group")
  local zone = zoneText()
  if raid then
    g.method = "raid"
    local okN, n = pcall(GetNumGroupMembers)
    n = okN and clean(n, "group") or 0
    for i = 1, (type(n) == "number" and n or 0) do
      local ok, name, _, _, _, _, _, where, online = pcall(GetRaidRosterInfo, i)
      if ok then
        name, where, online = clean(name, "group"), clean(where, "group"), clean(online, "group")
        local char = type(name) == "string" and name ~= "" and ns.fullName(name) or nil
        local inside
        if type(where) == "string" then inside = where == instName or where == zone end
        add(char, online and true or false, inside, inside == nil and "unknown" or "zone")
      end
    end
  elseif group then
    g.method = "party"
    local myMap = mapOf("player")
    add(unitFullName("player"), true, true, "self")
    for i = 1, 4 do
      local unit = "party" .. i
      local okE, exists = pcall(UnitExists, unit)
      if okE and clean(exists, "group") then
        local okC, connected = pcall(UnitIsConnected, unit)
        connected = okC and clean(connected, "group")
        local inside, how
        local map = mapOf(unit)
        if map and myMap then
          inside, how = map == myMap, "map"
        else
          local okV, visible = pcall(UnitIsVisible, unit)
          if okV and clean(visible, "group") then inside, how = true, "visible" else how = "unknown" end
        end
        add(unitFullName(unit), connected and true or false, inside, how)
      end
    end
  end
  -- Der eigene Charakter ist immer dabei, auch wenn seine Zeile geheim war
  add(ns.me(), true, true, "self")
  g.secrets = (DB.diag.secrets.group or 0) - secretsBefore
  if measure then DB.diag.group = g end
  return table.concat(list, ","), g
end

-- Boss-Versuche ------------------------------------------------------------

local function byKey()
  local map = {}
  for _, kill in ipairs(DB.kills) do map[kill.k] = kill end
  return map
end

local function findKill(k)
  for i = #DB.kills, 1, -1 do
    if DB.kills[i].k == k then return DB.kills[i] end
  end
end

-- "672-1793728800-Liriel" -> "672", 1793728800
local function keyParts(k)
  local id, t = tostring(k or ""):match("^([%w]+)%-(%d+)%-")
  return id, tonumber(t)
end

local function validKey(k)
  return type(k) == "string" and #k <= 80 and k:match("^[%w]+%-%d+%-[^;,:%s]+$") ~= nil
end

local function sameAttempt(a, b)
  local ida, ta = keyParts(a)
  local idb, tb = keyParts(b)
  return ida ~= nil and ida == idb and ta and tb and math.abs(ta - tb) <= SAME_ATTEMPT
end

local function store(kill)
  kill.rt = now()
  DB.kills[#DB.kills + 1] = kill
  local max = ns.isCollector() and MAX_KILLS_COLLECTOR or MAX_KILLS
  while #DB.kills > max do
    local old = table.remove(DB.kills, 1)
    DB.outbox[old.k] = nil
  end
end

-- Bestätigungen des Sammlers an die Gilde („A;<Schlüssel>“), der Reihe nach, sobald Senden geht;
-- die Schlange im Kern teilen sie sich mit den Bestätigungen des Verlaufs
local function queueAck(k)
  ns.queueAck("A" .. k, function() return "A;" .. k end)
end

-- Eigener Boss-Versuch: beim Sammler direkt in die Datei, sonst zusätzlich in den Postausgang
local function record(kill)
  local me = ns.me()
  kill.r = me
  kill.t = kill.t or now()
  local id = (kill.e and tostring(kill.e)) or (kill.npc and ("n" .. kill.npc)) or "m"
  -- Ohne Leerzeichen („Vorname Nachname“ in Forever): Sammler bis 1.1.1 lehnen sonst ab
  kill.k = ("%s-%d-%s"):format(id, kill.t, (short(me):gsub("%s", "")))
  if findKill(kill.k) then return nil end
  store(kill)
  if ns.isCollector() then
    queueAck(kill.k)
  else
    DB.outbox[kill.k] = 0
  end
  ns.changed()
  return kill
end

-- Gruppe nachträglich ergänzen, wenn beim Kill Namen geheim waren (z. B. noch im Kampf)
local function mergeGroups()
  if inCombat() or #mergeQueue == 0 then return end
  for _, kill in ipairs(mergeQueue) do
    local have = {}
    for entry in (kill.g or ""):gmatch("[^,]+") do have[entry:match("^[^:]+")] = true end
    local list, added = kill.g ~= "" and { kill.g } or {}, 0
    for entry in (capture(kill.inm)):gmatch("[^,]+") do
      if not have[entry:match("^[^:]+")] then
        list[#list + 1] = entry
        added = added + 1
      end
    end
    kill.g = table.concat(list, ",")
    log("Gruppe nach dem Kampf ergänzt: %d weitere", added)
  end
  wipe(mergeQueue)
  ns.changed()
end

local function onEncounterStart(...)
  bump(DB.diag.events, "ENCOUNTER_START")
  local id = clean((...), "encounter")
  if type(id) == "number" then starts[id] = now() end
end

local function onEncounterEnd(...)
  bump(DB.diag.events, "ENCOUNTER_END")
  local args = { ... }
  local d = {}
  for i = 1, 5 do d[i] = describe(args[i]) end
  DB.diag.lastEnd = { t = now(), args = d }
  local id, name = clean(args[1], "encounter"), clean(args[2], "encounter")
  local difficulty, size, success = clean(args[3], "encounter"), clean(args[4], "encounter"), clean(args[5], "encounter")
  if type(id) ~= "number" then
    log("ENCOUNTER_END ohne lesbare Boss-ID, nicht gespeichert")
    return
  end
  local inst = instanceInfo()
  local kill = {
    e = id,
    n = type(name) == "string" and name ~= "" and name or nil,
    i = inst.id, inm = inst.name, it = inst.type,
    df = type(difficulty) == "number" and difficulty or inst.difficulty,
    gs = type(size) == "number" and size or nil,
    ok = success == 1 or success == true,
    st = starts[id],
    src = "e",
  }
  starts[id] = nil
  local g
  kill.g, g = capture(inst.name, true)
  if record(kill) then
    log("%s %s (%s), %d in der Gruppe erkannt", kill.ok and "Kill" or "Wipe", kill.n or ("Boss " .. id),
      kill.inm or "?", g.members)
    if g.secrets > 0 then
      mergeQueue[#mergeQueue + 1] = kill
      C_Timer.After(5, mergeGroups)
    end
  end
end

local function onBossKill(...)
  bump(DB.diag.events, "BOSS_KILL")
  local args = { ... }
  DB.diag.lastBossKill = { t = now(), args = { describe(args[1]), describe(args[2]) } }
end

-- Weltbosse und alles ohne ENCOUNTER_END: „/gchr kill [Name]“ oder der Knopf auf der Seite
-- „Kills & Diagnose“. Liefert ok und einen Satz für Chat oder Fenster.
function ns.reportKill(name)
  if not DB then return false, "Das Addon ist noch nicht geladen." end
  local bossName, npc
  local okE, exists = pcall(UnitExists, "target")
  local okD, dead = pcall(UnitIsDead, "target")
  local okP, player = pcall(UnitIsPlayer, "target")
  -- Nur ein toter NPC zählt; ein toter Mitspieler im Ziel ist kein Boss
  if okE and clean(exists, "target") and okD and clean(dead, "target") and not (okP and clean(player, "target")) then
    local okN, n = pcall(UnitName, "target")
    n = okN and clean(n, "target") or nil
    if type(n) == "string" and n ~= "" then bossName = cut(n, NAME_MAX) end
    local okG, guid = pcall(UnitGUID, "target")
    guid = okG and clean(guid, "target") or nil
    if type(guid) == "string" then
      local kind, _, _, _, _, id = strsplit("-", guid)
      if kind == "Creature" or kind == "Vehicle" then npc = tonumber(id) end
    end
  end
  if not bossName then
    local given = strtrim(tostring(name or ""))
    if given ~= "" then bossName = cut(given, NAME_MAX) end
  end
  if not bossName then
    return false, "Visiere den toten Boss an oder gib seinen Namen mit an, z. B. /gchr kill Azuregos."
  end
  local t = now()
  for i = #DB.kills, math.max(1, #DB.kills - 50), -1 do
    local k = DB.kills[i]
    if k.ok and math.abs(t - (k.t or 0)) <= SAME_ATTEMPT
      and ((npc and k.npc == npc) or (k.n and k.n:lower() == bossName:lower())) then
      return false, ("%s ist schon gemeldet."):format(k.n or bossName)
    end
  end
  local inst = instanceInfo()
  local okN, size = pcall(GetNumGroupMembers)
  size = okN and clean(size, "group") or nil
  local kill = {
    n = bossName, npc = npc,
    i = inst.id, inm = inst.name or zoneText(), it = inst.type, df = inst.difficulty,
    gs = (type(size) == "number" and size > 0) and size or 1,
    ok = true, src = "m",
  }
  local g
  kill.g, g = capture(inst.name, true)
  if not record(kill) then return false, ("%s ist schon gemeldet."):format(bossName) end
  log("Kill gemeldet (von Hand): %s%s, %d in der Gruppe erkannt", bossName, npc and (" (NPC " .. npc .. ")") or "", g.members)
  return true, ("Kill gemeldet: %s, %d in der Gruppe erkannt."):format(bossName, g.members)
end

-- Postausgang --------------------------------------------------------------

-- Abgelaufene und überzählige Einträge streichen; liefert die übrigen, ältester zuerst.
local function outboxList()
  local kills, t, list = byKey(), now(), {}
  for k in pairs(DB.outbox) do
    local kill = kills[k]
    if not kill or t - (kill.t or 0) > OUTBOX_MAX_AGE then
      DB.outbox[k] = nil
    else
      list[#list + 1] = kill
    end
  end
  table.sort(list, function(a, b) return (a.t or 0) < (b.t or 0) end)
  while #list > MAX_OUTBOX do
    DB.outbox[table.remove(list, 1).k] = nil
  end
  return list
end

local function num(v)
  return v ~= nil and tostring(v) or ""
end

-- Kopf (K) und Gruppe in Teilen (G), jede Nachricht höchstens 255 Byte
local function messages(kill)
  local parts, cur, len = {}, {}, 0
  local function overhead(nr) return #("G;" .. kill.k .. ";" .. nr .. ";") end
  len = overhead(1)
  for entry in (kill.g or ""):gmatch("[^,]+") do
    local add = #entry + (#cur > 0 and 1 or 0)
    if #cur > 0 and len + add > MSG_MAX then
      parts[#parts + 1] = table.concat(cur, ",")
      cur = {}
      len = overhead(#parts + 1)
      add = #entry
    end
    cur[#cur + 1] = entry
    len = len + add
  end
  if #cur > 0 then parts[#parts + 1] = table.concat(cur, ",") end
  local head
  for max = NAME_MAX, 0, -10 do
    head = table.concat({
      "K", KILL_PROTO, kill.k, num(kill.e), num(kill.i), num(kill.df), num(kill.gs), kill.ok and "1" or "0",
      num(kill.st), num(kill.t), kill.src or "e", num(kill.npc), #parts,
      cut(kill.n, max), cut(kill.inm, max), cut(kill.it, 16),
    }, ";")
    if #head <= MSG_MAX then break end -- Namen kürzen, bis es passt (Schlüssel sind kurz)
  end
  local msgs = { head }
  for i, p in ipairs(parts) do msgs[#msgs + 1] = ("G;%s;%d;%s"):format(kill.k, i, p) end
  return msgs
end
ns.killMessages = messages -- für die Tests

-- Ein Boss-Versuch ist fällig: Dann wartet der Verlauf (Verlauf.lua), die Versuche haben Vorrang
function ns.killsDue()
  if not DB or ns.isCollector() or next(DB.outbox) == nil then return false end
  local kills, t = byKey(), now()
  for k, last in pairs(DB.outbox) do
    local kill = kills[k]
    if kill and t - (kill.t or 0) <= OUTBOX_MAX_AGE and (last == 0 or t - last >= RETRY) then return true end
  end
  return false
end

-- Versand beendet (bestätigt, abgelaufen oder blockiert): Postausgang für den Verlauf freigeben
local function stop()
  sending = nil
  ns.releaseOutbox("kills")
end

-- Eigene Boss-Versuche an einen Sammler, der gerade online ist: einer nach dem anderen,
-- nicht in einer Instanz und nicht im Kampf (dort sperrt WoW Addon-Nachrichten oft).
-- Sendet gerade der Verlauf, kommt der nächste Versuch, sobald der fertig ist.
local function pump()
  if not DB or sending or not IsInGuild() then return end
  if ns.isCollector() then
    -- Was noch im Postausgang lag, steht jetzt in der eigenen Datei
    for k in pairs(DB.outbox) do
      DB.outbox[k] = nil
      queueAck(k)
    end
    return
  end
  local list = outboxList()
  local t, due = now(), nil
  for _, kill in ipairs(list) do
    local last = DB.outbox[kill.k]
    if last == 0 or t - last >= RETRY then
      due = kill
      break
    end
  end
  if not due then return end
  if inInstance() then
    bump(DB.diag.deferred, "instance")
    return
  end
  if inCombat() then
    bump(DB.diag.deferred, "combat")
    return
  end
  local target = ns.onlineCollector and ns.onlineCollector()
  if not target then
    bump(DB.diag.deferred, "noCollector")
    return
  end
  if not ns.claimOutbox("kills") then return end

  seq = seq + 1
  local my = seq
  sending = { k = due.k, seq = my, target = target }
  DB.outbox[due.k] = t
  local msgs = messages(due)
  log("Boss-Versuch an den Sammler: %s (%d Nachrichten)", due.n or "?", #msgs)
  local i = 0
  local function nextPart()
    if not sending or sending.seq ~= my then return end
    i = i + 1
    if i > #msgs then
      C_Timer.After(ACK_WAIT, function()
        if sending and sending.seq == my then
          stop()
          log("Keine Bestätigung vom Sammler, neuer Versuch in 10 Minuten")
          ns.changed()
        end
      end)
      return
    end
    if not ns.send(msgs[i], "WHISPER", target) then
      stop()
      log("Senden an den Sammler blockiert (Nachricht %d von %d), neuer Versuch in 10 Minuten", i, #msgs)
      ns.changed()
      return
    end
    C_Timer.After(PART_GAP, nextPart)
  end
  nextPart()
  ns.changed()
end

-- „A;<Schlüssel>“: Der Sammler hat diesen Boss-Versuch. Gilt für alle Meldungen desselben
-- Versuchs (gleiche ID, höchstens 3 Minuten auseinander), auch die anderer Melder.
local function onAck(k)
  if not keyParts(k) then return end
  local removed = 0
  for key in pairs(DB.outbox) do
    if sameAttempt(key, k) then
      DB.outbox[key] = nil
      removed = removed + 1
    end
  end
  if sending and (sameAttempt(sending.k, k) or not DB.outbox[sending.k]) then
    stop()
    C_Timer.After(PART_GAP, pump)
  end
  if removed > 0 then
    log("Vom Sammler bestätigt: %d Boss-Versuch%s", removed, removed == 1 and "" or "e")
    ns.changed()
  end
end

-- Sammler: Meldungen zusammensetzen ---------------------------------------

local function complete(k)
  local a = assembling[k]
  if not a or not a.head or not a.n then return end
  for nr = 1, a.n do
    if not a.parts[nr] then return end
  end
  assembling[k] = nil
  local members = {}
  for nr = 1, a.n do
    for entry in a.parts[nr]:gmatch("[^,]+") do
      if entry:match("^[^:,;]+:[01][01?]$") then members[#members + 1] = entry end
    end
  end
  local kill = a.head
  kill.k = k
  kill.g = table.concat(members, ",")
  kill.t = kill.t or select(2, keyParts(k))
  if not findKill(k) then
    store(kill)
    bump(DB.diag.received, "ok")
    log("Boss-Versuch empfangen: %s (%s), %d in der Gruppe", kill.n or "?", kill.ok and "Kill" or "Wipe", #members)
  end
  queueAck(k)
  ns.changed()
end

local function onKillMessage(kind, msg, channel, sender, char)
  if not DB then return end
  if kind == "A" then
    -- Nur von bekannten Sammlern, sonst könnte jeder fremde Postausgänge leeren
    if channel == "GUILD" and char and DB.collectors[char] then onAck((select(2, strsplit(";", msg)))) end
    return
  end
  if channel ~= "WHISPER" or not ns.isCollector() then return end
  if not char or not DB.latest[char] then
    bump(DB.diag.received, "unknown") -- nur von bekannten Gildenmitgliedern
    return
  end
  local t = now()
  for key, a in pairs(assembling) do
    if t - a.at > ASSEMBLY_TIMEOUT then
      assembling[key] = nil
      bump(DB.diag.received, "timeout")
    end
  end

  local k
  if kind == "K" then
    local _, v, key, e, i, df, gs, ok, st, kt, src, npc, n, bossName, inm, it = strsplit(";", msg)
    if tonumber(v) ~= KILL_PROTO or not validKey(key) or not tonumber(n) then
      bump(DB.diag.received, "invalid")
      return
    end
    k = key
    if findKill(k) then
      queueAck(k)
      return
    end
    local a = assembling[k] or { parts = {}, at = t, from = char }
    if a.from ~= char then return end
    a.n = math.min(tonumber(n), 50)
    a.head = {
      e = tonumber(e), i = tonumber(i), df = tonumber(df), gs = tonumber(gs), ok = ok == "1",
      st = tonumber(st), t = tonumber(kt), src = src == "m" and "m" or "e", npc = tonumber(npc),
      n = bossName ~= "" and bossName or nil, inm = inm ~= "" and inm or nil, it = it ~= "" and it or nil,
      r = char,
    }
    assembling[k] = a
  elseif kind == "G" then
    local _, key, nr, entries = strsplit(";", msg)
    nr = tonumber(nr)
    if not validKey(key) or not nr or nr < 1 or nr > 50 then
      bump(DB.diag.received, "invalid")
      return
    end
    k = key
    local a = assembling[k] or { parts = {}, at = t, from = char }
    if a.from ~= char then return end
    a.parts[nr] = entries or ""
    assembling[k] = a
  else
    return
  end
  complete(k)
end
ns.onKillMessage = onKillMessage

-- Katalog aus dem Spiel ----------------------------------------------------
-- Welche Dungeons und Raids es gibt, liest das Addon aus dem Client, nichts davon steht fest im Code.
-- Wie bei AtlasLoot hängt alles an den IDs des Spiels (Instanz = instanceID wie im 8. Wert von
-- GetInstanceInfo, Boss = encounterID wie bei ENCOUNTER_END), die Namen kommen in der Sprache des
-- Clients. AtlasLoot liefert die Liste selbst mit; hier kommt sie aus dem Spiel:
--   • Gruppensuche (C_LFGList): jede verfügbare Aktivität der Kategorien Dungeons und Raids mit
--     Instanz (mapID), Mindestlevel, empfohlenem Höchstlevel und Spielerzahl. In WoW Forever die
--     einzige Liste (kein Abenteuerführer), dort bringen Patches neue Dungeons und Raids so von selbst
--     mit. Mehrere Aktivitäten einer Instanz (Flügel, Schwierigkeiten) werden eine Instanz.
--   • Abenteuerführer (EJ_*, Retail): Bosse mit encounterID und Erweiterung, in Forever leer.
-- Bosse ohne Abenteuerführer kommen mit jedem Boss-Versuch dazu (ENCOUNTER_END). Eingelesen wird
-- 20 s nach jedem Login, den Abenteuerführer nur nach Patch, Sprachwechsel oder 7 Tagen. t ändert
-- sich nur, wenn sich etwas geändert hat (oder per Knopf): Dann lädt der Sammler den Katalog hoch.

-- Kategorien der Gruppensuche: 2 Dungeons, 114 Raids (Classic und Forever), 3 Raids (Retail)
local LFG_CATEGORIES = { [2] = false, [3] = true, [114] = true }

local function journalDue()
  local c, d = DB.catalog, DB.diag.ej
  local build, locale = buildInfo()
  -- Leerer Abenteuerführer (WoW Forever): erst nach Patch, Sprachwechsel oder 7 Tagen wieder versuchen
  if d.empty and d.build == build and d.locale == locale and now() - (d.at or 0) <= CATALOG_MAX_AGE then
    return false
  end
  return d.build ~= build or d.locale ~= locale or now() - (d.at or 0) > CATALOG_MAX_AGE
    or not c or (c.ej == nil and not d.empty)
end

-- Abenteuerführer: alle Stufen, Dungeons und Raids mit ihren Bossen. Liefert die Liste (leer: nichts
-- im Client) oder nil und einen Satz.
local function scanJournal()
  local d = DB.diag.ej
  d.at = now()
  if not (EJ_GetNumTiers and EJ_SelectTier and EJ_GetInstanceByIndex and EJ_GetEncounterInfoByIndex) then
    d.available, d.error, d.empty = false, nil, true
    return {}
  end
  local build, locale = buildInfo()
  d.build, d.locale, d.empty = build, locale, nil
  local started = debugprofilestop and debugprofilestop()
  local okPrev, prev = pcall(EJ_GetCurrentTier)
  local instances, seen = {}, {}
  local stats = { tiers = 0, instances = 0, bosses = 0, skipped = 0 }
  local ok, err = pcall(function()
    local tiers = clean(EJ_GetNumTiers(), "ej")
    stats.tiers = type(tiers) == "number" and tiers or 0
    for tier = 1, stats.tiers do
      EJ_SelectTier(tier)
      local tierName = EJ_GetTierInfo and clean((EJ_GetTierInfo(tier)), "ej") or nil
      for _, isRaid in ipairs({ false, true }) do
        for index = 1, 500 do
          local journalId, name = EJ_GetInstanceByIndex(index, isRaid)
          journalId, name = clean(journalId, "ej"), clean(name, "ej")
          if type(journalId) ~= "number" then break end
          local mapId
          if EJ_GetInstanceInfo then mapId = clean((select(10, EJ_GetInstanceInfo(journalId))), "ej") end
          local bosses = {}
          for b = 1, 100 do
            local bossName, _, _, _, _, _, encounterId, instanceId = EJ_GetEncounterInfoByIndex(b, journalId)
            bossName = clean(bossName, "ej")
            if type(bossName) ~= "string" then break end
            encounterId, instanceId = clean(encounterId, "ej"), clean(instanceId, "ej")
            if type(mapId) ~= "number" and type(instanceId) == "number" then mapId = instanceId end
            if type(encounterId) == "number" then
              bosses[#bosses + 1] = { e = encounterId, n = bossName, pos = b }
              stats.bosses = stats.bosses + 1
            else
              stats.skipped = stats.skipped + 1
            end
          end
          if type(mapId) == "number" and not seen[mapId] then
            seen[mapId] = true
            instances[#instances + 1] = {
              i = mapId, j = journalId, n = type(name) == "string" and name or nil, raid = isRaid,
              tier = type(tierName) == "string" and tierName or nil, pos = index, b = bosses,
            }
            stats.instances = stats.instances + 1
          elseif type(mapId) ~= "number" then
            stats.skipped = stats.skipped + 1
          end
        end
      end
    end
  end)
  if okPrev and type(prev) == "number" then pcall(EJ_SelectTier, prev) end
  d.available = true
  d.tiers, d.instances, d.bosses, d.skipped = stats.tiers, stats.instances, stats.bosses, stats.skipped
  d.ms = started and debugprofilestop and math.floor(debugprofilestop() - started) or nil
  if not ok then
    d.error = cut(err, 200)
    log("Abenteuerführer: Fehler beim Einlesen: %s", d.error)
    return nil
  end
  d.error = nil
  if #instances == 0 then
    -- In WoW Forever normal (keine Stufen): bis zum nächsten Patch nicht bei jedem Login neu versuchen
    d.empty = true
    log("Abenteuerführer leer (%d Stufen), bis zum nächsten Patch kein neuer Versuch", stats.tiers)
  end
  return instances
end

-- Name einer Instanz aus ihren Aktivitäten, wenn der Client ihn nicht über die ID liefert: der
-- gemeinsame Anfang bis zum letzten Trenner („Scharlachrotes Kloster - Friedhof“, „… - Bibliothek“),
-- sonst der kürzeste
local function commonName(names)
  local prefix, same = names[1], true
  for i = 2, #names do
    local n, k = names[i], 0
    while k < #prefix and k < #n and prefix:byte(k + 1) == n:byte(k + 1) do k = k + 1 end
    if k < #prefix or k < #n then same = false end
    prefix = prefix:sub(1, k)
  end
  if not same then prefix = prefix:match("^(.*)[%s%(%-:]") or "" end
  prefix = strtrim((prefix:gsub("[%s%-%(:]+$", "")))
  if #prefix >= 3 then return prefix end
  local shortest = names[1]
  for _, n in ipairs(names) do
    if #n < #shortest then shortest = n end
  end
  return shortest
end

-- Gruppensuche: verfügbare Dungeons und Raids. Liefert die Instanzen (leer: nichts gefunden) oder nil,
-- wenn es die Gruppensuche im Client nicht gibt.
local function scanGroupFinder()
  local d = DB.diag.lfg
  d.at = now()
  local api = C_LFGList
  if not (api and api.GetAvailableActivities and api.GetActivityInfoTable) then
    d.available, d.error = false, nil
    return nil
  end
  d.available = true
  local stats = { activities = 0, skipped = 0 }
  local byKey = {} -- "<mapID>:<raid>" -> Instanz der Art
  local ok, err = pcall(function()
    local categories = {}
    if api.GetAvailableCategories then
      local okC, list = pcall(api.GetAvailableCategories)
      if okC and type(list) == "table" then
        for _, id in ipairs(list) do categories[#categories + 1] = clean(id, "lfg") end
      end
    end
    if #categories == 0 then categories = { 2, 114, 3 } end
    for _, category in ipairs(categories) do
      local raid = LFG_CATEGORIES[category]
      local okA, activities = false, nil
      if raid ~= nil then okA, activities = pcall(api.GetAvailableActivities, category) end
      for _, id in ipairs(okA and type(activities) == "table" and activities or {}) do
        local info = api.GetActivityInfoTable(id)
        local map = type(info) == "table" and clean(info.mapID, "lfg") or nil
        local name = type(info) == "table" and clean(info.fullName, "lfg") or nil
        if type(map) == "number" and map > 0 and type(name) == "string" and name ~= "" then
          stats.activities = stats.activities + 1
          local key = map .. ":" .. tostring(raid)
          local e = byKey[key]
          if not e then
            e = { i = map, raid = raid, names = {} }
            byKey[key] = e
          end
          e.names[#e.names + 1] = name
          local minLevel, maxLevel = clean(info.minLevel, "lfg"), clean(info.maxLevelSuggestion, "lfg")
          local size = clean(info.maxNumPlayers, "lfg")
          if type(minLevel) == "number" and minLevel > 0 then e.min = math.min(e.min or minLevel, minLevel) end
          if type(maxLevel) == "number" and maxLevel > 0 then e.max = math.max(e.max or maxLevel, maxLevel) end
          if type(size) == "number" and size > 0 then e.size = math.max(e.size or size, size) end
        else
          stats.skipped = stats.skipped + 1
        end
      end
    end
  end)
  d.activities, d.skipped = stats.activities, stats.skipped
  if not ok then
    d.error = cut(err, 200)
    log("Gruppensuche: Fehler beim Einlesen: %s", d.error)
    return {}
  end
  d.error = nil

  -- Dieselbe Instanz als Dungeon und als Raid (z. B. Varianten aus Season of Discovery): Dungeon
  local list = {}
  for _, e in pairs(byKey) do
    if not (e.raid and byKey[e.i .. ":false"]) then list[#list + 1] = e end
  end
  -- Namen über die ID (wie im Spiel, z. B. „Scharlachrotes Kloster“ statt des Flügels). Liefert der
  -- Client für alle denselben Namen, kennt er das Argument nicht: dann aus den Aktivitäten.
  local zones, counts = {}, {}
  for _, e in ipairs(list) do
    local okZ, zone = pcall(GetRealZoneText, e.i)
    zone = okZ and clean(zone, "lfg") or nil
    if type(zone) == "string" and zone ~= "" then
      zones[e.i] = zone
      counts[zone] = (counts[zone] or 0) + 1
    end
  end
  local trusted = true
  for _, n in pairs(counts) do
    if #list >= 3 and n > #list / 2 then trusted = false end
  end
  local dungeons, raids = 0, 0
  for _, e in ipairs(list) do
    e.n = (trusted and zones[e.i]) or commonName(e.names)
    e.names = nil
    if e.raid then raids = raids + 1 else dungeons = dungeons + 1 end
  end
  d.dungeons, d.raids = dungeons, raids
  return list
end

-- „1 Dungeon, 2 Raids, 5 Bosse“ (Bosse nur, wenn es welche gibt)
local function contentCount(dungeons, raids, bosses)
  local text = ("%d %s, %d %s"):format(dungeons, dungeons == 1 and "Dungeon" or "Dungeons", raids, raids == 1 and "Raid" or "Raids")
  if bosses and bosses > 0 then text = text .. (", %d %s"):format(bosses, bosses == 1 and "Boss" or "Bosse") end
  return text
end

-- Vergleichbarer Text des Katalogs: ändert er sich, gibt es einen neuen Zeitpunkt (Upload)
local function signature(instances)
  local parts = {}
  for _, e in ipairs(instances or {}) do
    local bosses = {}
    for _, b in ipairs(e.b or {}) do bosses[#bosses + 1] = ("%s:%s:%s"):format(b.e or "", b.n or "", b.pos or "") end
    parts[#parts + 1] = table.concat({ e.i, e.n or "", e.raid and 1 or 0, e.min or "", e.max or "", e.size or "",
      e.j or "", e.tier or "", e.pos or "", table.concat(bosses, ",") }, "|")
  end
  table.sort(parts)
  return table.concat(parts, ";")
end

-- Liest den Katalog (force: auch den Abenteuerführer, neuer Zeitpunkt auch ohne Änderung).
-- Liefert ok und einen Satz.
function ns.scanCatalog(force)
  if not DB then return false, "Das Addon ist noch nicht geladen." end
  if inCombat() then
    catalogQueued = true
    return false, "Im Kampf geht das nicht, das Addon liest den Katalog danach ein."
  end
  local prev = DB.catalog
  local lfg = scanGroupFinder()
  local journal
  if force or journalDue() then journal = scanJournal() end
  if journal == nil and prev then
    -- Abenteuerführer nicht fällig (oder Fehler): seine Einträge aus dem letzten Katalog
    journal = {}
    for _, e in ipairs(prev.instances or {}) do
      if e.j then journal[#journal + 1] = e end
    end
  end

  -- Zusammenführen über die Instanz: Gruppensuche (Level, Größe, Name), Abenteuerführer (Bosse, Erweiterung)
  local instances, byId = {}, {}
  for _, e in ipairs(lfg or {}) do
    local copy = { i = e.i, n = e.n, raid = e.raid, min = e.min, max = e.max, size = e.size, b = {} }
    instances[#instances + 1] = copy
    byId[e.i] = copy
  end
  local journalCount = 0
  for _, e in ipairs(journal or {}) do
    journalCount = journalCount + 1
    local into = byId[e.i]
    if into then
      into.j, into.tier, into.b = e.j, e.tier, e.b or {}
    else
      local copy = { i = e.i, n = e.n, raid = e.raid, j = e.j, tier = e.tier, pos = e.pos, b = e.b or {} }
      instances[#instances + 1] = copy
      byId[e.i] = copy
    end
  end
  if #instances == 0 then
    ns.changed()
    if lfg == nil then
      log("Gruppensuche und Abenteuerführer liefern nichts")
      return false, "Weder Gruppensuche noch Abenteuerführer liefern Dungeons. Die Web-App behält ihre Liste."
    end
    log("Katalog leer (Gruppensuche %d Aktivitäten)", DB.diag.lfg.activities or 0)
    return false, "Die Gruppensuche liefert gerade keine Dungeons. Später noch einmal versuchen."
  end
  -- Reihenfolge je Art: Gruppensuche nach Mindestlevel, sonst wie im Abenteuerführer
  table.sort(instances, function(a, b)
    if a.raid ~= b.raid then return not a.raid end
    if (a.min or 999) ~= (b.min or 999) then return (a.min or 999) < (b.min or 999) end
    if (a.pos or 0) ~= (b.pos or 0) then return (a.pos or 0) < (b.pos or 0) end
    return (a.n or "") < (b.n or "")
  end)
  local pos = { [true] = 0, [false] = 0 }
  for _, e in ipairs(instances) do
    pos[e.raid] = pos[e.raid] + 1
    e.pos = pos[e.raid]
  end

  local build, locale = buildInfo()
  local fromLfg = lfg ~= nil and #lfg > 0
  local src = fromLfg and (journalCount > 0 and "lfg+ej" or "lfg") or "ej"
  local changed = not prev or signature(prev.instances) ~= signature(instances) or prev.src ~= src
  local t = (changed or force or not prev.t) and now() or prev.t
  DB.catalog = {
    t = t, checked = now(), build = build, locale = locale, src = src,
    -- vollständig: die Gruppensuche listet alles, was es gibt; was fehlt, blendet die Web-App aus
    complete = fromLfg or nil,
    ej = journalCount > 0 and true or nil,
    instances = instances,
  }
  local bosses = 0
  for _, e in ipairs(instances) do bosses = bosses + #e.b end
  local summary = contentCount(pos[false], pos[true], bosses)
  ns.changed()
  if not changed and not force then
    return true, ("Katalog unverändert: %s."):format(summary)
  end
  log("Katalog eingelesen (%s): %s", src, summary)
  return true, ("Katalog eingelesen: %s %s. Der Sammler lädt ihn hoch."):format(summary,
    ({ lfg = "aus der Gruppensuche", ej = "aus dem Abenteuerführer" })[src] or "aus Gruppensuche und Abenteuerführer")
end

local function scanCatalogSoon()
  if inCombat() then catalogQueued = true else ns.scanCatalog() end
end

-- Messdaten ----------------------------------------------------------------

local function when(t)
  if not t then return "" end
  if ns.ago then return " (" .. ns.ago(t) .. ")" end
  return " (" .. date("%d.%m. %H:%M", t) .. ")"
end

local function pairsText(t, names)
  local out = {}
  for _, key in ipairs(names) do
    if t[key[1]] and t[key[1]] > 0 then out[#out + 1] = key[2] .. " " .. t[key[1]] end
  end
  return out
end

-- Zeilen für /gchr diag und die Seite „Kills & Diagnose“: { Bezeichnung, Wert, Ton }
-- Ton: ok, warn, bad, idle
function ns.diagLines()
  local d = DB.diag
  local lines = {}
  local function add(label, value, tone) lines[#lines + 1] = { label, value, tone or "ok" } end

  local version = (C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata)(ADDON, "Version") or "?"
  add("Spiel", ("Build %s, %s, Addon %s"):format(d.build or "?", d.locale or "?", version))

  local e = d.events
  local missing = {}
  for _, name in ipairs({ "ENCOUNTER_START", "ENCOUNTER_END" }) do
    if d.registered[name] == false then missing[#missing + 1] = name end
  end
  if #missing > 0 then
    add("Boss-Events", "Nicht registrierbar: " .. table.concat(missing, ", ") .. ". Kills nur von Hand (/gchr kill).", "bad")
  else
    add("Boss-Events", ("ENCOUNTER_START %d, ENCOUNTER_END %d, BOSS_KILL %d"):format(
      e.ENCOUNTER_START or 0, e.ENCOUNTER_END or 0, e.BOSS_KILL or 0), (e.ENCOUNTER_END or 0) > 0 and "ok" or "idle")
  end
  if d.lastEnd then
    add("Letztes Ende", table.concat(d.lastEnd.args, ", ") .. when(d.lastEnd.t))
  else
    add("Letztes Ende", "Noch kein ENCOUNTER_END in diesem Account.", "idle")
  end
  if d.lastInstance then
    add("Instanz", table.concat(d.lastInstance.args, ", ") .. when(d.lastInstance.t))
  end

  local g = d.group
  if g then
    local how = pairsText(g.how, { { "zone", "Zone" }, { "map", "Karte" }, { "visible", "Sichtweite" }, { "unknown", "unklar" }, { "self", "selbst" } })
    add("Gruppe", ("%s, %d erkannt: %d in der Instanz, %d draußen, %d unklar (%s)%s"):format(
      g.method, g.members, g.inside, g.outside, g.unknown, table.concat(how, ", "), when(g.t)),
      g.unknown > 0 and "warn" or "ok")
  else
    add("Gruppe", "Noch nicht gemessen, erst beim ersten Boss-Versuch.", "idle")
  end

  local parts = {}
  for _, ctx in ipairs({ { "world", "Welt" }, { "instance", "Instanz" }, { "world+combat", "Welt im Kampf" }, { "instance+combat", "Instanz im Kampf" } }) do
    local s = d.send[ctx[1]]
    if s then parts[#parts + 1] = ("%s %d/%d"):format(ctx[2], s.ok or 0, s.fail or 0) end
  end
  local blockedInInstance = d.send.instance and (d.send.instance.fail or 0) > 0
  add("Senden", #parts > 0 and (table.concat(parts, ", ") .. " (gesendet/blockiert)") or "Noch nichts gesendet.",
    blockedInInstance and "warn" or (#parts > 0 and "ok" or "idle"))
  local waited = pairsText(d.deferred, { { "instance", "Instanz" }, { "combat", "Kampf" }, { "noCollector", "kein Sammler" } })
  if #waited > 0 then add("Postausgang wartete", table.concat(waited, ", "), "idle") end

  local lfg = d.lfg
  if lfg.available == nil then
    add("Gruppensuche", "Noch nicht eingelesen.", "idle")
  elseif lfg.available == false then
    add("Gruppensuche", "Nicht verfügbar (C_LFGList fehlt).", "warn")
  elseif lfg.error then
    add("Gruppensuche", "Fehler: " .. lfg.error, "bad")
  else
    add("Gruppensuche", ("%s aus %d Aktivitäten, %d übersprungen%s"):format(
      contentCount(lfg.dungeons or 0, lfg.raids or 0), lfg.activities or 0, lfg.skipped or 0, when(lfg.at)),
      (lfg.dungeons or 0) > 0 and "ok" or "warn")
  end

  local ej = d.ej
  if ej.available == nil then
    add("Abenteuerführer", "Noch nicht eingelesen.", "idle")
  elseif ej.available == false then
    add("Abenteuerführer", "Nicht verfügbar. Bosse kommen mit den Boss-Versuchen.", "idle")
  elseif ej.error then
    add("Abenteuerführer", "Fehler: " .. ej.error, "bad")
  elseif (ej.instances or 0) == 0 then
    add("Abenteuerführer", ("Leer, %d Stufen%s. Bosse kommen mit den Boss-Versuchen."):format(ej.tiers or 0, when(ej.at)), "idle")
  else
    add("Abenteuerführer", ("%d Stufen, %d Instanzen, %d Bosse, %d übersprungen%s"):format(
      ej.tiers or 0, ej.instances or 0, ej.bosses or 0, ej.skipped or 0, when(ej.at)), "ok")
  end

  local c = DB.catalog
  if c and c.instances then
    local raids, bosses = 0, 0
    for _, e in ipairs(c.instances) do
      if e.raid then raids = raids + 1 end
      bosses = bosses + #(e.b or {})
    end
    add("Katalog", ("%s, Stand%s, geprüft%s"):format(contentCount(#c.instances - raids, raids, bosses), when(c.t),
      when(c.checked or c.t)), "ok")
  else
    add("Katalog", "Noch keiner. Kommt 20 s nach dem Login aus dem Spiel.", "idle")
  end

  local secrets = pairsText(d.secrets, { { "encounter", "Boss" }, { "instance", "Instanz" }, { "group", "Gruppe" }, { "target", "Ziel" }, { "ej", "Abenteuerführer" }, { "lfg", "Gruppensuche" }, { "andere", "andere" } })
  add("Geheime Werte", #secrets > 0 and table.concat(secrets, ", ") or "keine", #secrets > 0 and "warn" or "ok")

  if ns.isCollector() then
    local r = d.received
    add("Empfangen", ("%d angenommen, %d ungültig, %d von Unbekannten, %d unvollständig"):format(
      r.ok or 0, r.invalid or 0, r.unknown or 0, r.timeout or 0), "ok")
  end
  return lines
end

-- Für die Seite „Kills & Diagnose“: die letzten Boss-Versuche (neueste zuerst) und Zahlen
function ns.killsView(limit)
  local list = {}
  for i = #DB.kills, math.max(1, #DB.kills - (limit or 6) + 1), -1 do
    local kill = DB.kills[i]
    list[#list + 1] = { kill = kill, open = DB.outbox[kill.k] ~= nil, own = kill.r == ns.me() }
  end
  local open = 0
  for _ in pairs(DB.outbox) do open = open + 1 end
  return { kills = list, total = #DB.kills, open = open, sending = sending ~= nil }
end

function ns.logTail(n)
  local out = {}
  for i = math.max(1, #DB.log - n + 1), #DB.log do out[#out + 1] = DB.log[i] end
  return out
end

function ns.clearLog()
  wipe(DB.log)
  log("Log geleert")
  ns.changed()
end

-- Ablauf -------------------------------------------------------------------

function ns.initKills(db)
  DB = db
  DB.kills = DB.kills or {}
  DB.outbox = DB.outbox or {}
  DB.log = DB.log or {}
  DB.diag = DB.diag or {}
  local d = DB.diag
  d.events = d.events or {}
  d.registered = d.registered or {}
  d.secrets = d.secrets or {}
  d.send = d.send or {}
  d.deferred = d.deferred or {}
  d.received = d.received or {}
  d.ej = d.ej or {}
  d.lfg = d.lfg or {}
end

-- Jede Addon-Nachricht (auch die Meldungen im Kern): Ergebnis je Lage zählen
function ns.noteSend(channel, ok)
  if not DB then return end
  local ctx = (inInstance() and "instance" or "world") .. (inCombat() and "+combat" or "")
  local s = DB.diag.send[ctx] or {}
  DB.diag.send[ctx] = s
  bump(s, ok and "ok" or "fail")
  DB.diag.sendLast = { t = now(), channel = channel, ok = ok, ctx = ctx }
end

-- Ein Sammler ist online gekommen: Postausgang nach kurzer, zufälliger Pause
function ns.onCollectorOnline()
  C_Timer.After(math.random(5, 40), pump)
end

ns.pumpKills = pump

-- Boss-Events gibt es vielleicht nicht in jedem Client; unbekannte Events werfen beim Registrieren.
-- Ob es geklappt hat, steht ab dem Login in den Messdaten.
local registered = {}

frame:SetScript("OnEvent", function(_, event, ...)
  if not DB then return end
  if event == "ENCOUNTER_START" then
    onEncounterStart(...)
  elseif event == "ENCOUNTER_END" then
    onEncounterEnd(...)
  elseif event == "BOSS_KILL" then
    onBossKill(...)
  elseif event == "PLAYER_LOGIN" then
    local build, locale, toc = buildInfo()
    DB.diag.build, DB.diag.locale, DB.diag.toc = build, locale, toc
    for e, ok in pairs(registered) do DB.diag.registered[e] = ok end
    log("Login, Build %s, %s, %d Boss-Versuche gespeichert", build or "?", locale or "?", #DB.kills)
    C_Timer.After(20, scanCatalogSoon)
    C_Timer.NewTicker(TICK, function()
      pump()
      ns.flushAcks()
      mergeGroups()
    end)
  elseif event == "PLAYER_ENTERING_WORLD" then
    if not inInstance() then C_Timer.After(math.random(15, 45), pump) end
    ns.flushAcks()
  elseif event == "PLAYER_REGEN_ENABLED" then
    mergeGroups()
    ns.flushAcks()
    if catalogQueued then
      catalogQueued = false
      C_Timer.After(5, scanCatalogSoon)
    end
    C_Timer.After(math.random(3, 10), pump)
  end
end)

for _, e in ipairs({ "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_ENABLED" }) do
  frame:RegisterEvent(e)
end
for _, e in ipairs({ "ENCOUNTER_START", "ENCOUNTER_END", "BOSS_KILL" }) do
  registered[e] = pcall(frame.RegisterEvent, frame, e)
end
