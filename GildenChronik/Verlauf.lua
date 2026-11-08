-- Verlauf: Jeder Levelaufstieg eines eigenen Charakters als vollständiger Stand zu genau diesem
-- Zeitpunkt (Level, Klasse, Gold wenn geteilt, Tode, Berufe), dazu der erste Stand jedes
-- Charakters und der Stand am Ende eines Tages, wenn ihn gerade kein Sammler hören konnte. Die
-- Einträge warten in DB.history, bis ein Sammler sie bestätigt: Das Addon flüstert sie ihm in
-- Runden zu, sobald er online ist, auch die der anderen Charaktere dieses WoW-Accounts. Der
-- Sammler speichert sie mit ihrem Zeitpunkt in snapshots. So bleibt die Chronik lückenlos, auch
-- wenn nie jemand gleichzeitig mit dem Sammler spielt. Protokoll: docs/architektur.md.

local _, ns = ...

local HIST_PROTO = 1
local MAX_HISTORY = 2000   -- darüber fliegen zuerst die ältesten Tagesstände raus
local BATCH = 10           -- Einträge je Runde, dann auf die Bestätigung warten
local PART_GAP = 1.2       -- Abstand zwischen zwei Nachrichten (Drosselung von WoW)
local ACK_WAIT = 60        -- nach der letzten Nachricht so lange auf die Bestätigung warten
local RETRY = 600          -- unbestätigte Einträge frühestens nach 10 Minuten erneut; ohne jede
                           -- Bestätigung (Sammler mit altem Addon) auch keine weitere Runde
local BLOCKED_PAUSE = 60   -- WoW hat eine Nachricht nicht gesendet: kurz warten
local MSG_MAX = 255
local TICK = 120
local MIN_TS = 1577836800  -- 2020, ältere Zeitpunkte nimmt die Datenbank nicht
local SAME_STATE = 5       -- dieselben Werte höchstens so viele Sekunden daneben: derselbe Stand

local DB
local frame = CreateFrame("Frame")
local sending              -- { seq, open = { [Schlüssel] = true }, acked } beim Senden und Warten
local seq = 0
local quietUntil = 0       -- vorher keine neue Runde
local ackTimes = {}        -- Sammler: Charakter -> Zeitpunkte, die er noch bestätigen muss
-- Sammler, nur diese Sitzung: neu gespeichert, schon da, kaputt, von Unbekannten, fremdes Konto
local stats = { ok = 0, dup = 0, invalid = 0, unknown = 0, foreign = 0 }

local function now()
  return GetServerTime()
end

local function key(c, t)
  return c .. "@" .. t
end

local function day(t)
  return date("%Y-%m-%d", t)
end

local function guildName()
  return IsInGuild() and GetGuildInfo("player") or nil
end

local function num(v)
  return v ~= nil and tostring(v) or ""
end

-- In der Instanz und im Kampf sperrt WoW Addon-Nachrichten oft
local function blocked()
  local ok, inside = pcall(IsInInstance)
  if ok and inside and not (issecretvalue and issecretvalue(inside)) then return true end
  return InCombatLockdown and InCombatLockdown() and true or false
end

-- Postausgang --------------------------------------------------------------

-- w: f = erster Stand des Charakters, l = Levelaufstieg, s = Stand am Ende des Tages
local function entryOf(s, w)
  return { c = s.c, t = s.t, l = s.l, cls = s.cls, m = s.m, d = s.d, p = s.p, g = guildName(), w = w }
end

local function inFlight(e)
  return sending ~= nil and sending.open[key(e.c, e.t)] == true
end

-- Über der Grenze: zuerst der älteste Tagesstand, sonst der älteste Eintrag
local function trim()
  local h = DB.history
  while #h > MAX_HISTORY do
    local drop = 1
    for i, e in ipairs(h) do
      if e.w == "s" and not inFlight(e) then
        drop = i
        break
      end
    end
    table.remove(h, drop)
  end
end

local function add(e)
  local h = DB.history
  for i, x in ipairs(h) do
    if x.c == e.c and x.t == e.t then
      -- Derselbe Zeitpunkt (z. B. Ausloggen in der Sekunde des Levelaufstiegs): neuere Werte,
      -- die Art bleibt
      if not inFlight(x) then
        if x.w ~= "s" then e.w = x.w end
        h[i] = e
      end
      return
    end
  end
  if e.w == "s" then
    -- Vom Tag reicht der letzte Stand
    for i, x in ipairs(h) do
      if x.c == e.c and x.w == "s" and day(x.t) == day(e.t) and not inFlight(x) then
        h[i] = e
        return
      end
    end
  end
  h[#h + 1] = e
  trim()
end

-- own: letztes eigenes Level (erkennt den Levelaufstieg), f = erster Stand schon im Verlauf.
-- Beim Sammler nur mitgeführt: Seine Stände stehen ohnehin in der eigenen Datei.
local function consider(own, s, delivered)
  local w
  if not own.f then
    w = "f"
  elseif s.l and own.l and s.l > own.l then
    w = "l"
  elseif not delivered then
    w = "s"
  end
  own.f = true
  if s.l then own.l = s.l end
  if w and not ns.isCollector() then add(entryOf(s, w)) end
end

-- Erster eigener Stand eines Charakters mit dieser Version: einmal alle Stände durchgehen, die
-- schon in der Datei liegen (seit der Installation des Addons). So kommen auch frühere
-- Levelaufstiege zum Sammler. Fremde Meldungen gibt es für eigene Charaktere nicht (ein Account
-- ist nie zweimal online), die Gildenliste zählt nicht.
local function seed(c)
  local own = {}
  DB.own[c] = own
  local list = {}
  for _, s in ipairs(DB.snapshots) do
    if s.c == c and s.src ~= "r" and s.t then list[#list + 1] = s end
  end
  table.sort(list, function(a, b) return a.t < b.t end)
  for _, s in ipairs(list) do consider(own, s, false) end
end

-- Eigener Stand aus dem Kern (Meldung an die Gilde oder Ausloggen). delivered: Die Meldung ging
-- raus, während ein Sammler online war; dann braucht es keinen Tagesstand.
function ns.onOwnSnapshot(s, delivered)
  if not DB or not s or not s.c then return end
  local own = DB.own[s.c]
  if own then
    consider(own, s, delivered)
  else
    seed(s.c) -- der neue Stand liegt schon in der Datei
  end
  ns.changed()
end

-- Fällig: noch nie gesendet oder seit RETRY unbestätigt, älteste zuerst. Einträge aus einer
-- anderen Gilde warten, bis man wieder dort ist.
local function due(t)
  local guild = guildName()
  local list = {}
  for _, e in ipairs(DB.history) do
    if (not e.g or e.g == guild) and (not e.a or t - e.a >= RETRY) then list[#list + 1] = e end
  end
  table.sort(list, function(a, b) return a.t < b.t end)
  while #list > BATCH do table.remove(list) end
  return list
end

-- „H;1;<Charakter>;<Zeit>;<Level>;<Klasse>;<Kupfer>;<Tode>;<Berufe>;<Konto-ID>“, höchstens 255 Byte:
-- notfalls ohne Konto-ID, dann die Berufe von hinten gekürzt
local function message(e)
  local id, p = ns.profileId() or "", e.p or ""
  local function build()
    return table.concat({ "H", HIST_PROTO, e.c, e.t, num(e.l), e.cls or "", num(e.m), num(e.d), p, id }, ";")
  end
  local msg = build()
  if #msg > MSG_MAX then
    id = ""
    msg = build()
  end
  while #msg > MSG_MAX and p ~= "" do
    p = p:match("^(.*),[^,]*$") or ""
    msg = build()
  end
  return msg
end
ns.historyMessage = message -- für die Tests

local function finish(my, note, pause)
  if not sending or sending.seq ~= my then return end
  sending = nil
  if pause then quietUntil = now() + pause end
  if note and ns.log then ns.log(note) end
  ns.releaseOutbox("history")
  ns.changed()
end

-- Schon in der Datei? Derselbe Charakter und Zeitpunkt, oder dieselben Werte ein paar Sekunden
-- daneben (Meldung eines Addons vor 1.1.0, gespeichert mit der Empfangszeit)
local function known(s)
  local snaps = DB.snapshots
  for i = #snaps, 1, -1 do
    local x = snaps[i]
    if x.c == s.c and x.t and math.abs(x.t - s.t) <= SAME_STATE and (x.t == s.t or ns.sameSnapshot(x, s)) then
      return true
    end
  end
  return false
end

local function snapshotOf(e)
  return { c = e.c, t = e.t, l = e.l, cls = e.cls, m = e.m, d = e.d, p = e.p or "", src = "a" }
end

-- Als Sammler: Was noch im Postausgang lag, gehört in die eigene Datei. Fehlt ein Stand dort
-- (älteste fliegen bei 20.000 raus), mit rt: Das Sammler-Programm lädt nach dem Zeitpunkt des
-- Speicherns hoch, auch Älteres.
local function absorb()
  local h = DB.history
  if #h == 0 then return end
  for _, e in ipairs(h) do
    local s = snapshotOf(e)
    if not known(s) then
      s.rt = now()
      ns.storeSnapshot(s)
    end
  end
  wipe(h)
  ns.changed()
end

-- Eine Runde an einen Sammler, der gerade online ist: nicht in einer Instanz, nicht im Kampf und
-- nicht, solange die Boss-Versuche senden. Weiter geht es mit der Bestätigung (Q).
local function pump()
  if not DB or not IsInGuild() then return end
  if ns.isCollector() then
    if sending then finish(sending.seq) end -- gerade Sammler geworden
    absorb()
    return
  end
  if sending then return end
  local t = now()
  if t < quietUntil then return end
  local list = due(t)
  if #list == 0 or blocked() or (ns.killsDue and ns.killsDue()) then return end
  local target = ns.onlineCollector and ns.onlineCollector()
  if not target or not ns.claimOutbox("history") then return end
  seq = seq + 1
  local my = seq
  sending = { seq = my, open = {}, acked = 0 }
  for _, e in ipairs(list) do
    e.a = t
    sending.open[key(e.c, e.t)] = true
  end
  if ns.log then ns.log(("Verlauf an den Sammler: %d %s"):format(#list, #list == 1 and "Stand" or "Stände")) end
  local i = 0
  local function nextPart()
    if not sending or sending.seq ~= my then return end
    i = i + 1
    if i > #list then
      C_Timer.After(ACK_WAIT, function()
        if not sending or sending.seq ~= my then return end
        -- Gar keine Bestätigung: Der Sammler kennt den Verlauf wohl nicht (Addon vor 1.1.0)
        local none = sending.acked == 0
        finish(my, "Verlauf: keine Bestätigung vom Sammler, neuer Versuch in 10 Minuten", none and RETRY or nil)
      end)
      return
    end
    if not ns.send(message(list[i]), "WHISPER", target) then
      -- Was nicht rausging, ist gleich wieder fällig
      for j = i, #list do list[j].a = nil end
      finish(my, ("Verlauf: Senden an den Sammler blockiert (Nachricht %d von %d), neuer Versuch gleich")
        :format(i, #list), BLOCKED_PAUSE)
      return
    end
    C_Timer.After(PART_GAP, nextPart)
  end
  nextPart()
  ns.changed()
end
ns.pumpHistory = pump

-- „Q;<Charakter>;<Zeit>,<Zeit>,…“ vom Sammler: Diese Einträge sind angekommen
local function onAck(msg, char)
  if not char or not DB.collectors[char] then return end -- nur von bekannten Sammlern
  local _, c, list = strsplit(";", msg)
  if not c or not list then return end
  local acked = {}
  for x in list:gmatch("%d+") do acked[tonumber(x)] = true end
  local h, removed = DB.history, 0
  for i = #h, 1, -1 do
    if h[i].c == c and acked[h[i].t] then
      table.remove(h, i)
      removed = removed + 1
    end
  end
  if sending then
    for t in pairs(acked) do
      local k = key(c, t)
      if sending.open[k] then
        sending.open[k] = nil
        sending.acked = sending.acked + 1
      end
    end
    if next(sending.open) == nil then finish(sending.seq) end
  end
  if removed > 0 then
    if ns.log then ns.log(("Verlauf vom Sammler bestätigt: %d %s"):format(removed, removed == 1 and "Stand" or "Stände")) end
    -- Späte Bestätigung: Der Sammler kennt den Verlauf, also keine Pause
    if quietUntil > 0 then
      quietUntil = 0
      if not sending then C_Timer.After(PART_GAP, pump) end
    end
    ns.changed()
  end
end

-- Sammler ------------------------------------------------------------------

-- Bestätigung an die Gilde, so viele Zeitpunkte je Nachricht, wie in 255 Byte passen. Die
-- Schlange im Kern teilen sich Verlauf und Boss-Versuche.
local function queueAck(c, t)
  local list = ackTimes[c]
  if not list then
    list = {}
    ackTimes[c] = list
  end
  local seen = false
  for _, x in ipairs(list) do
    if x == t then seen = true end
  end
  if not seen then list[#list + 1] = t end
  local prefix, take = "Q;" .. c .. ";", 0
  ns.queueAck("Q" .. c, function()
    local l = ackTimes[c]
    if not l or #l == 0 then return nil end
    local parts, len = {}, #prefix
    for _, x in ipairs(l) do
      local s = tostring(x)
      if #parts > 0 and len + 1 + #s > MSG_MAX then break end
      len = len + #s + (#parts > 0 and 1 or 0)
      parts[#parts + 1] = s
    end
    take = #parts
    return prefix .. table.concat(parts, ",")
  end, function()
    local l = ackTimes[c]
    for _ = 1, take do table.remove(l, 1) end
    if #l > 0 then return true end
    ackTimes[c] = nil
    return false
  end)
end

-- „Name-Realm“, in WoW Forever „Vorname Nachname-Realm“
local function validChar(c)
  return type(c) == "string" and #c <= 80
    and (c:find("^[^;,:%s]+%-[^;,:%s]+$") ~= nil or c:find("^[^;,:%s]+ [^;,:%s]+%-[^;,:%s]+$") ~= nil)
end

-- „H;…“ per Flüstern von einem Mitglied: speichern (ohne Doppeltes) und bestätigen. Andere
-- Charaktere seines Accounts gehen mit, aber nie die eines anderen Kontos.
local function onEntry(msg, char)
  if not ns.isCollector() then return end
  if not char or not DB.latest[char] then
    stats.unknown = stats.unknown + 1 -- nur von bekannten Gildenmitgliedern, später noch einmal
    return
  end
  local _, v, c, ts, l, cls, m, d, p, pid = strsplit(";", msg)
  local t = tonumber(ts)
  l, m, d = tonumber(l), tonumber(m), tonumber(d)
  if tonumber(v) ~= HIST_PROTO or not validChar(c) or not t or t < MIN_TS or t > now() + 60
    or (l and (l < 1 or l > 100)) or (m and m < 0) or (d and d < 0) then
    stats.invalid = stats.invalid + 1
    return
  end
  local id = ns.validId(pid)
  local account = id or DB.links[char]
  if c ~= char and DB.links[c] and DB.links[c] ~= account then
    stats.foreign = stats.foreign + 1
    queueAck(c, t) -- bestätigen, sonst versucht es der Absender immer wieder
    return
  end
  if id and (c == char or not DB.links[c]) then DB.links[c] = id end
  local s = snapshotOf({ c = c, t = t, l = l, cls = cls ~= "" and cls or nil, m = m, d = d, p = p })
  if known(s) then
    stats.dup = stats.dup + 1
  else
    s.rt = now()
    ns.storeSnapshot(s)
    stats.ok = stats.ok + 1
  end
  queueAck(c, t)
end

function ns.onHistoryMessage(kind, msg, channel, sender, char)
  if not DB then return end
  if kind == "Q" then
    if channel == "GUILD" then onAck(msg, char) end
  elseif channel == "WHISPER" then
    onEntry(msg, char)
  end
end

-- Für das Fenster und /gchr status
function ns.historyView()
  local guild = guildName()
  local view = { open = #DB.history, levels = 0, otherGuild = 0, sending = sending ~= nil, stats = stats }
  for _, e in ipairs(DB.history) do
    if e.w == "l" then view.levels = view.levels + 1 end
    if e.g and guild and e.g ~= guild then view.otherGuild = view.otherGuild + 1 end
  end
  return view
end

-- Ablauf -------------------------------------------------------------------

function ns.initHistory(db)
  DB = db
  DB.history = DB.history or {}
  DB.own = DB.own or {}
end

-- Ein Sammler ist online gekommen: nach den Meldungen (3 bis 30 s) und den Boss-Versuchen
function ns.onCollectorOnlineHistory()
  C_Timer.After(math.random(20, 60), pump)
end

frame:SetScript("OnEvent", function(_, event)
  if not DB then return end
  if event == "PLAYER_LOGIN" then
    -- Ohne neuen Stand seit dem Update (nichts geändert): Verlauf trotzdem einmal aus der Datei
    C_Timer.After(15, function()
      local c = ns.me()
      if c and not DB.own[c] and DB.latest[c] then
        seed(c)
        ns.changed()
      end
    end)
    C_Timer.NewTicker(TICK, pump)
  elseif event == "PLAYER_ENTERING_WORLD" then
    if not blocked() then C_Timer.After(math.random(20, 50), pump) end
  elseif event == "PLAYER_REGEN_ENABLED" then
    C_Timer.After(math.random(5, 15), pump)
  end
end)

for _, e in ipairs({ "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "PLAYER_REGEN_ENABLED" }) do
  frame:RegisterEvent(e)
end
