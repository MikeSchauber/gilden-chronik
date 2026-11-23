-- Statistiken aus dem Charakterfenster (ab 1.6.0): Kreaturen getötet (auch je Kreaturtyp), Quests,
-- Dungeons, Endbosse, Tode nach Ursache, Kurioses … Gelesen wird wie im Fenster „Statistiken“ des
-- Spiels, nur mit dem Haken „Ich teile meine Statistiken mit der Chronik“ (DB.shareStats, Standard aus).
-- Was sich geändert hat, wartet je Charakter und Tag in DB.statsOut, bis ein Sammler es bestätigt: Das
-- Addon flüstert es ihm in Teilen zu (S;…), wenn Boss-Versuche und Verlauf nichts Fälliges haben. Der
-- Sammler setzt die Teile zusammen, speichert sie in DB.statReadings und liest zusätzlich die Namen aller
-- Statistiken (DB.statCatalog). Protokoll und Format: docs/architektur.md (Sammler-Repo, collector/docs).

local _, ns = ...

local STAT_PROTO = 1
local MAX_OUT = 60          -- Einträge im Postausgang; darüber wandern die ältesten in den nächsten desselben Charakters
local MAX_READINGS = 5000   -- Sammler: Stände in der Datei
local MAX_PARTS = 40        -- Nachrichten je Stand; mehr Werte gehen als eigener Stand eine Sekunde später
local MSG_MAX = 255
local PART_GAP = 1.2        -- Abstand zwischen zwei Nachrichten (Drosselung von WoW)
local ACK_WAIT = 60         -- nach der letzten Nachricht so lange auf die Bestätigung warten
local RETRY = 600           -- unbestätigt: frühestens nach 10 Minuten erneut, ohne Bestätigung auch keine neue Runde
local BLOCKED_PAUSE = 60    -- WoW hat eine Nachricht nicht gesendet: kurz warten
local ASSEMBLY_TIMEOUT = 120
local READ_DELAY = 15       -- nach dem Betreten der Welt
local READ_GAP = 60         -- nach CRITERIA_UPDATE höchstens jede Minute
local TICK = 120
local MIN_TS = 1577836800   -- 2020, ältere Zeitpunkte nimmt die Datenbank nicht
local CREATURES = 107       -- „Kreaturen getötet“, Kreaturtypen als Kriterien
local WEALTH = 140          -- Kategorie „Vermögen“
local FLAG_HIDDEN = 0x02
local FLAG_AVERAGE = 0x40   -- Durchschnitte (Quests und Gold pro Tag) zählen nicht

local DB
local frame = CreateFrame("Frame")
local inWorld = false
local readToken = 0         -- geplantes Lesen; ein neueres ersetzt es
local readAt                -- wann das geplante Lesen fällig ist
local readPending = false   -- im Kampf verschoben
local lastRead = 0
local catalogRead = false   -- Sammler: Katalog in dieser Sitzung gelesen
local sending               -- { seq, c, t } beim Senden und Warten auf Y
local seq = 0
local quietUntil = 0
local assembling = {}       -- Sammler: "<c>@<t>" -> { from, n, parts, at }
local dupAcked = {}         -- Sammler: "<c>@<t>" -> wann ein doppelter Stand zuletzt bestätigt wurde
local info = {}             -- Statistik-ID -> { name, flags } (GetAchievementInfo, diese Sitzung)
-- Sammler, nur diese Sitzung: neu gespeichert, schon da, kaputt, von Unbekannten, fremdes Konto, unvollständig
local recv = { ok = 0, dup = 0, invalid = 0, unknown = 0, foreign = 0, timeout = 0 }

local function now()
  return GetServerTime()
end

local function day(t)
  return date("%Y-%m-%d", t)
end

local function log(fmt, ...)
  if ns.log then ns.log(select("#", ...) > 0 and fmt:format(...) or fmt) end
end

local function plural(n, one, many)
  return n .. " " .. (n == 1 and one or many)
end

local function has(flags, bit)
  return type(flags) == "number" and math.floor(flags / bit) % 2 == 1
end

-- In der Instanz und im Kampf sperrt WoW Addon-Nachrichten oft
local function blocked()
  local ok, inside = pcall(IsInInstance)
  if ok and inside and not (issecretvalue and issecretvalue(inside)) then return true end
  return InCombatLockdown and InCombatLockdown() and true or false
end

-- Lesen --------------------------------------------------------------------

local secrets = 0
local function clean(v)
  if issecretvalue and issecretvalue(v) then
    secrets = secrets + 1
    return nil
  end
  return v
end

-- Wert wie im Fenster „Statistiken“ als ganze Zahl: Ziffern, auch mit Tausender-Trennern („1.234“,
-- „1,234“), Geld mit Münz-Symbolen in Kupfer (zweiter Wert true). nil: keine Zahl („--“, Text).
local function parseValue(v)
  if type(v) == "number" then
    if v >= 0 and math.floor(v) == v then return v, false end
    return nil
  end
  if type(v) ~= "string" then return nil end
  local s = v:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("\194\160", " ")
  if s:find("|[TA]") then
    local copper, found = 0, false
    for amount, icon in s:gmatch("([%d%.,' ]+)|[TA]([^|]*)|[ta]") do
      local n = tonumber((amount:gsub("%D", "")))
      local l = icon:lower()
      local mult = (l:find("gold", 1, true) and 10000) or (l:find("silver", 1, true) and 100)
        or (l:find("copper", 1, true) and 1)
      if n and mult then
        copper = copper + n * mult
        found = true
      end
    end
    if found then return copper, true end
    return nil
  end
  s = strtrim(s)
  if s:find("^%d+$") then return tonumber(s), false end
  if s:find("^%d%d?%d?[%.,' ]%d%d%d") and s:gsub("^%d%d?%d?", ""):gsub("[%.,' ]%d%d%d", "") == "" then
    return tonumber((s:gsub("%D", ""))), false
  end
  return nil
end
ns.parseStatValue = parseValue -- für die Tests

local function infoOf(id)
  local i = info[id]
  if not i then
    local ok, _, name, _, _, _, _, _, _, flags = pcall(GetAchievementInfo, id)
    name, flags = ok and clean(name) or nil, ok and clean(flags) or nil
    i = { name = type(name) == "string" and name ~= "" and name or nil, flags = type(flags) == "number" and flags or 0 }
    info[id] = i
  end
  return i
end

-- Alle Statistiken wie das Fenster „Statistiken“: Kategorien nach Index, je Kategorie Wert, skip und ID.
-- values: Werte über 0, ohne skip und Durchschnitte, Vermögen nur mit „Gold teilen“; catalog: Kategorien,
-- Statistiken (auch ausgeblendete Endbosse, h) und Kreaturtypen mit Namen in der Sprache des Clients.
local function scan(wantValues, wantCatalog)
  local started = debugprofilestop and debugprofilestop() or 0
  secrets = 0
  local d = { at = now(), categories = 0, statistics = 0, values = 0, criteria = 0, noGold = 0, shared = wantValues }
  if not (GetStatisticsCategoryList and GetCategoryNumAchievements and GetStatistic) then
    d.available = false
    return nil, nil, d
  end
  d.available = true
  local ok, cats = pcall(GetStatisticsCategoryList)
  if not ok or type(cats) ~= "table" then
    d.error = "GetStatisticsCategoryList: " .. tostring(ok and type(cats) or cats)
    return nil, nil, d
  end
  local values = wantValues and {} or nil
  local catalog = wantCatalog and { c = {}, s = {}, k = {} } or nil
  local parentOf, names = {}, {}
  for _, id in ipairs(cats) do
    id = clean(id)
    if type(id) == "number" then
      local okI, name, parent = pcall(GetCategoryInfo, id)
      parent = okI and clean(parent) or nil
      parentOf[id] = type(parent) == "number" and parent > 0 and parent or nil
      names[id] = okI and type(clean(name)) == "string" and name ~= "" and name or nil
    end
  end
  local function wealth(id)
    for _ = 1, 10 do
      if id == nil then return false end
      if id == WEALTH then return true end
      id = parentOf[id]
    end
    return false
  end

  local siblings = {}
  for _, cat in ipairs(cats) do
    cat = clean(cat)
    if type(cat) == "number" then
      d.categories = d.categories + 1
      if catalog and names[cat] then
        local p = parentOf[cat] or 0
        siblings[p] = (siblings[p] or 0) + 1
        catalog.c[#catalog.c + 1] = { id = cat, n = names[cat], p = parentOf[cat], pos = siblings[p] }
      end
      local okN, n = pcall(GetCategoryNumAchievements, cat)
      n = okN and clean(n) or nil
      for i = 1, type(n) == "number" and n or 0 do
        local okS, quantity, skip, id = pcall(GetStatistic, cat, i)
        if okS then
          quantity, skip, id = clean(quantity), clean(skip), clean(id)
          if id == nil then
            -- Ohne dritten Wert: die ID wie im Fenster über den Erfolg an dieser Stelle
            local okA, aid = pcall(GetAchievementInfo, cat, i)
            id = okA and clean(aid) or nil
          end
          if type(id) == "number" then
            d.statistics = d.statistics + 1
            local meta = infoOf(id)
            if catalog and meta.name and not (skip and has(meta.flags, FLAG_HIDDEN)) then
              catalog.s[#catalog.s + 1] = { id = id, n = meta.name, c = cat, pos = i, f = meta.flags, h = skip and true or nil }
            end
            if values and not skip and not has(meta.flags, FLAG_AVERAGE) then
              local v, money = parseValue(quantity)
              if v and v > 0 then
                if (money or wealth(cat)) and not ns.sharesGold() then
                  d.noGold = d.noGold + 1
                else
                  values[id] = v
                  d.values = d.values + 1
                end
              end
            end
          end
        end
      end
    end
  end

  -- Kreaturtypen von „Kreaturen getötet“: Name, Zahl, criteriaID (10. Wert)
  if GetAchievementNumCriteria and GetAchievementCriteriaInfo then
    local okC, nc = pcall(GetAchievementNumCriteria, CREATURES)
    nc = okC and clean(nc) or nil
    for j = 1, type(nc) == "number" and nc or 0 do
      local okI, cname, _, _, quantity, _, _, _, _, _, criteriaID = pcall(GetAchievementCriteriaInfo, CREATURES, j)
      if okI then
        cname, quantity, criteriaID = clean(cname), clean(quantity), clean(criteriaID)
        if type(criteriaID) == "number" then
          if catalog and type(cname) == "string" and cname ~= "" then
            catalog.k[#catalog.k + 1] = { s = CREATURES, id = criteriaID, n = cname, pos = j }
          end
          local v = parseValue(quantity)
          if values and v and v > 0 then
            values[CREATURES .. ":" .. criteriaID] = v
            d.criteria = d.criteria + 1
          end
        end
      end
    end
  end
  d.secret = secrets
  if debugprofilestop then d.ms = math.floor(debugprofilestop() - started + 0.5) end
  return values, catalog, d
end

-- Katalog (nur Sammler): t ändert sich nur, wenn sich der Inhalt geändert hat, sonst nur checked
local function signature(cat)
  local parts = {}
  for _, c in ipairs(cat.c or {}) do parts[#parts + 1] = ("c%s|%s|%s|%s"):format(c.id, c.n, c.p or "", c.pos or "") end
  for _, s in ipairs(cat.s or {}) do
    parts[#parts + 1] = ("s%s|%s|%s|%s|%s|%s"):format(s.id, s.n, s.c, s.pos or "", s.f or "", s.h and 1 or "")
  end
  for _, k in ipairs(cat.k or {}) do parts[#parts + 1] = ("k%s|%s|%s|%s"):format(k.s, k.id, k.n, k.pos or "") end
  return table.concat(parts, "\n")
end

local function buildId()
  local ok, version, build = pcall(GetBuildInfo)
  if not ok then return nil end
  return tostring(version or "?") .. "." .. tostring(build or "?")
end

local function setCatalog(cat)
  if #cat.s == 0 then return false end -- nichts gelesen: der alte Katalog bleibt, beim nächsten Lesen erneut
  local t, old = now(), DB.statCatalog
  cat.build = buildId()
  cat.locale = GetLocale and GetLocale() or nil
  cat.checked = t
  if old and old.t and signature(old) == signature(cat) and old.build == cat.build and old.locale == cat.locale then
    cat.t = old.t
  else
    cat.t = t
    log("Statistik-Katalog gelesen: %d Kategorien, %d Statistiken, %d Kreaturtypen", #cat.c, #cat.s, #cat.k)
  end
  DB.statCatalog = cat
  return true
end

-- Sammler: Stand in die eigene Datei (nach rt, danach lädt das Sammler-Programm); doppelte nicht noch einmal
local function knownReading(c, t)
  local list = DB.statReadings
  for i = #list, 1, -1 do
    if list[i].c == c and list[i].t == t then return true end
  end
  return false
end

local function storeReading(c, t, v)
  if knownReading(c, t) or next(v) == nil then return false end
  local list = DB.statReadings
  list[#list + 1] = { c = c, t = t, rt = now(), v = v }
  while #list > MAX_READINGS do table.remove(list, 1) end
  ns.state.newEntries = ns.state.newEntries + 1
  ns.changed()
  return true
end

-- Postausgang --------------------------------------------------------------

local function inFlight(e)
  return sending ~= nil and sending.c == e.c and sending.t == e.t
end

local function findOut(c, t)
  for _, e in ipairs(DB.statsOut) do
    if e.c == c and e.t == t then return e end
  end
end

-- Über der Grenze: Der älteste Eintrag wandert in den nächsten desselben Charakters (dessen Werte
-- sind neuer), sonst fliegt er raus.
local function trim()
  local out = DB.statsOut
  while #out > MAX_OUT do
    local order = {}
    for i, e in ipairs(out) do
      if not inFlight(e) then order[#order + 1] = i end
    end
    if #order == 0 then break end
    table.sort(order, function(a, b) return out[a].t < out[b].t end)
    local drop = order[1]
    for _, i in ipairs(order) do
      local e, nextE = out[i], nil
      for _, j in ipairs(order) do
        local x = out[j]
        if j ~= i and x.c == e.c and x.t >= e.t and (not nextE or x.t < nextE.t) then nextE = x end
      end
      if nextE then
        for k, v in pairs(e.v) do
          if nextE.v[k] == nil then nextE.v[k] = v end
        end
        drop = i
        break
      end
    end
    table.remove(out, drop)
  end
end

-- Geänderte Werte in den Eintrag des Charakters von heute (solange er nicht gerade gesendet wird)
local function addOut(c, t, changed)
  local d = day(t)
  for _, e in ipairs(DB.statsOut) do
    if e.c == c and e.d == d and not inFlight(e) then
      for k, v in pairs(changed) do e.v[k] = v end
      e.t = math.max(e.t, t)
      return
    end
  end
  DB.statsOut[#DB.statsOut + 1] = { c = c, t = t, d = d, v = changed }
  trim()
end

local function keyParts(k)
  if type(k) == "number" then return k, 0 end
  local a, b = tostring(k):match("^(%d+):(%d+)$")
  return tonumber(a) or 0, tonumber(b) or 0
end

local function sortedKeys(v)
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b)
    local a1, a2 = keyParts(a)
    local b1, b2 = keyParts(b)
    if a1 ~= b1 then return a1 < b1 end
    return a2 < b2
  end)
  return keys
end

-- Werte als „<id>=<wert>“ bzw. „<id>:<kriterium>=<wert>“ in Teile zu je höchstens 255 Byte (mit Kopf).
-- Passen sie nicht in 40 Teile, gehen die übrigen als eigener Eintrag eine Sekunde später.
local function chunks(e)
  local overhead = #("S;" .. STAT_PROTO .. ";" .. e.c .. ";" .. e.t .. ";" .. MAX_PARTS .. ";" .. MAX_PARTS .. ";")
  local room = MSG_MAX - overhead
  local list, cur, len = {}, {}, 0
  for _, k in ipairs(sortedKeys(e.v)) do
    local item = tostring(k) .. "=" .. ("%.0f"):format(e.v[k])
    local add = #item + (#cur > 0 and 1 or 0)
    if #cur > 0 and len + add > room then
      list[#list + 1] = cur
      cur, len, add = {}, 0, #item
    end
    cur[#cur + 1] = { k = k, s = item }
    len = len + add
  end
  if #cur > 0 then list[#list + 1] = cur end
  return list
end

local function messages(e)
  local list = chunks(e)
  if #list > MAX_PARTS then
    local t = e.t + 1
    while findOut(e.c, t) do t = t + 1 end
    local rest = { c = e.c, t = t, d = e.d, v = {} }
    for i = MAX_PARTS + 1, #list do
      for _, item in ipairs(list[i]) do
        rest.v[item.k] = e.v[item.k]
        e.v[item.k] = nil
      end
      list[i] = nil
    end
    DB.statsOut[#DB.statsOut + 1] = rest
  end
  local msgs = {}
  for i, items in ipairs(list) do
    local parts = {}
    for _, item in ipairs(items) do parts[#parts + 1] = item.s end
    msgs[i] = table.concat({ "S", STAT_PROTO, e.c, e.t, i, #list, table.concat(parts, ",") }, ";")
  end
  return msgs
end
ns.statMessages = messages -- für die Tests

local function finish(my, note, pause)
  if not sending or sending.seq ~= my then return end
  sending = nil
  if pause then quietUntil = now() + pause end
  if note then log(note) end
  ns.releaseOutbox("stats")
  ns.changed()
end

local function nextDue(t)
  local best
  for _, e in ipairs(DB.statsOut) do
    if (not e.a or t - e.a >= RETRY) and (not best or e.t < best.t) then best = e end
  end
  return best
end

-- Als Sammler: Was noch im eigenen Postausgang lag, gehört in die eigene Datei
local function absorb()
  if #DB.statsOut == 0 then return end
  for _, e in ipairs(DB.statsOut) do storeReading(e.c, e.t, e.v) end
  wipe(DB.statsOut)
  ns.changed()
end

-- Ein Eintrag an einen Sammler, der gerade online ist: nicht in einer Instanz, nicht im Kampf und erst,
-- wenn Boss-Versuche und Verlauf nichts Fälliges haben. Weiter geht es mit der Bestätigung (Y).
local function pump()
  if not DB or not IsInGuild() then return end
  if ns.isCollector() then
    if sending then finish(sending.seq) end -- gerade Sammler geworden
    absorb()
    return
  end
  if not ns.sharesStats() then
    if sending then finish(sending.seq) end
    if #DB.statsOut > 0 then
      wipe(DB.statsOut)
      ns.changed()
    end
    return
  end
  if sending then return end
  local t = now()
  if t < quietUntil then return end
  local e = nextDue(t)
  if not e then return end
  if next(e.v) == nil then
    for i, x in ipairs(DB.statsOut) do
      if x == e then table.remove(DB.statsOut, i) break end
    end
    return
  end
  if blocked() or (ns.killsDue and ns.killsDue()) or (ns.historyDue and ns.historyDue()) then return end
  local target = ns.onlineCollector and ns.onlineCollector()
  if not target or not ns.claimOutbox("stats") then return end
  local msgs = messages(e)
  seq = seq + 1
  local my = seq
  sending = { seq = my, c = e.c, t = e.t }
  e.a = t
  log("Statistiken an den Sammler: %s, %d %s", plural(#sortedKeys(e.v), "Wert", "Werte"), #msgs,
    #msgs == 1 and "Nachricht" or "Nachrichten")
  local i = 0
  local function nextPart()
    if not sending or sending.seq ~= my then return end
    i = i + 1
    if i > #msgs then
      C_Timer.After(ACK_WAIT, function()
        if sending and sending.seq == my then
          finish(my, "Statistiken: keine Bestätigung vom Sammler, neuer Versuch in 10 Minuten", RETRY)
        end
      end)
      return
    end
    if not ns.send(msgs[i], "WHISPER", target) then
      e.a = nil -- gleich wieder fällig
      finish(my, ("Statistiken: Senden an den Sammler blockiert (Nachricht %d von %d), neuer Versuch gleich")
        :format(i, #msgs), BLOCKED_PAUSE)
      return
    end
    C_Timer.After(PART_GAP, nextPart)
  end
  nextPart()
  ns.changed()
end
ns.pumpStats = pump

-- Gelesene Werte: Was sich seit dem letzten Lesen geändert hat (beim ersten Mal alles), geht in den
-- Postausgang bzw. beim Sammler direkt in die Datei
local function onRead(c, values, t)
  local last = DB.stats[c]
  local changed, n = {}, 0
  for k, v in pairs(values) do
    if not last or last.v[k] ~= v then
      changed[k] = v
      n = n + 1
    end
  end
  DB.stats[c] = { t = t, v = values }
  if n == 0 then return 0 end
  if ns.isCollector() then
    storeReading(c, t, changed)
  else
    addOut(c, t, changed)
  end
  return n
end

local function read()
  if not DB then return end
  local wantValues = ns.sharesStats()
  local wantCatalog = ns.isCollector() and not catalogRead
  if not wantValues and not wantCatalog then return end
  if not inWorld then return end
  if InCombatLockdown and InCombatLockdown() then
    readPending = true
    return
  end
  local c = ns.me()
  if not c then wantValues = false end
  lastRead = now()
  local values, catalog, d = scan(wantValues, wantCatalog)
  DB.diag.stats = d
  if catalog and setCatalog(catalog) then catalogRead = true end
  if values then
    local n = onRead(c, values, lastRead)
    if n > 0 then
      log("Statistiken gelesen: %s, %d geändert", plural(d.values + d.criteria, "Wert", "Werte"), n)
      C_Timer.After(PART_GAP, pump)
    end
  elseif d.available == false or d.error then
    log("Statistiken nicht lesbar: %s", d.error or "kein Statistikfenster in diesem Client")
  end
  ns.changed()
end

-- Lesen planen: frühestens nach delay, ohne force höchstens jede Minute. Ein früheres ersetzt ein späteres.
local function readSoon(delay, force)
  if not DB then return end
  local wait = delay or 0
  if not force then wait = math.max(wait, lastRead + READ_GAP - now()) end
  wait = math.max(wait, 0)
  local at = now() + wait
  if readAt and readAt <= at then return end
  readToken = readToken + 1
  local my = readToken
  readAt = at
  C_Timer.After(wait, function()
    if my ~= readToken then return end
    readAt = nil
    read()
  end)
end
ns.readStatsSoon = function(force) readSoon(force and 1 or 2, force) end

-- „Ich teile meine Statistiken“ umgeschaltet. Aus: laufenden Versand abbrechen und alles Eigene
-- verwerfen, was noch nicht beim Sammler ist (beim Sammler die eigenen Stände in der Datei).
function ns.onShareStats(on)
  if not DB then return end
  if on then
    readSoon(2, true)
    return
  end
  if sending then finish(sending.seq) end
  local mine = {}
  for c in pairs(DB.stats) do mine[c] = true end
  for c in pairs(DB.own or {}) do mine[c] = true end
  local me = ns.me()
  if me then mine[me] = true end
  local dropped = #DB.statsOut
  wipe(DB.statsOut)
  wipe(DB.stats)
  local list = DB.statReadings
  for i = #list, 1, -1 do
    if mine[list[i].c] then
      table.remove(list, i)
      dropped = dropped + 1
    end
  end
  if dropped > 0 then log("Statistiken nicht mehr geteilt: %s verworfen", plural(dropped, "Stand", "Stände")) end
  ns.changed()
end

-- Bestätigung „Y;<Charakter>;<Zeit>“ vom Sammler: Dieser Eintrag ist angekommen
local function onAck(msg, char)
  if not char or not DB.collectors[char] then return end -- nur von bekannten Sammlern
  local _, c, ts = strsplit(";", msg)
  local t = tonumber(ts)
  if not c or not t then return end
  local removed = false
  for i = #DB.statsOut, 1, -1 do
    local e = DB.statsOut[i]
    if e.c == c and e.t == t then
      table.remove(DB.statsOut, i)
      removed = true
    end
  end
  if sending and sending.c == c and sending.t == t then
    finish(sending.seq)
  end
  if removed then
    log("Statistiken vom Sammler bestätigt")
    -- Späte Bestätigung: Der Sammler kennt die Statistiken, also keine Pause
    if quietUntil > 0 then
      quietUntil = 0
      if not sending then C_Timer.After(PART_GAP, pump) end
    end
    ns.changed()
  end
end

-- Sammler ------------------------------------------------------------------

local function queueAck(c, t)
  ns.queueAck("Y" .. c .. "@" .. t, function() return "Y;" .. c .. ";" .. t end)
end

-- „Name-Realm“, in WoW Forever „Vorname Nachname-Realm“
local function validChar(c)
  return type(c) == "string" and #c <= 80
    and (c:find("^[^;,:=%s]+%-[^;,:=%s]+$") ~= nil or c:find("^[^;,:=%s]+ [^;,:=%s]+%-[^;,:=%s]+$") ~= nil)
end

local function parseValues(text, into)
  local bad = 0
  for item in text:gmatch("[^,]+") do
    local id, crit, v = item:match("^(%d+):(%d+)=(%d+)$")
    if not id then
      id, v = item:match("^(%d+)=(%d+)$")
    end
    local n = tonumber(v)
    if id and #id <= 9 and (not crit or #crit <= 9) and n and n < 1e15 then
      into[crit and (id .. ":" .. crit) or tonumber(id)] = n
    else
      bad = bad + 1
    end
  end
  return bad
end

-- „S;1;<Charakter>;<Zeit>;<Teil>;<Teile>;<Werte>“ per Flüstern: zusammensetzen, speichern, bestätigen.
-- Andere Charaktere des Absenders gehen mit, nie die eines anderen Kontos.
local function onPart(msg, char)
  if not ns.isCollector() then return end
  if not char or not DB.latest[char] then
    recv.unknown = recv.unknown + 1 -- nur von bekannten Gildenmitgliedern, später noch einmal
    return
  end
  local t0 = now()
  for k, a in pairs(assembling) do
    if t0 - a.at > ASSEMBLY_TIMEOUT then
      assembling[k] = nil
      recv.timeout = recv.timeout + 1
    end
  end
  local _, v, c, ts, part, parts, payload = strsplit(";", msg)
  local t, nr, n = tonumber(ts), tonumber(part), tonumber(parts)
  if tonumber(v) ~= STAT_PROTO or not validChar(c) or not t or t % 1 ~= 0 then
    recv.invalid = recv.invalid + 1
    return
  end
  local key = c .. "@" .. t
  if t < MIN_TS or t > t0 + 60 or not nr or not n or nr % 1 ~= 0 or n % 1 ~= 0 or nr < 1 or n < 1 or n > MAX_PARTS or nr > n then
    recv.invalid = recv.invalid + 1
    assembling[key] = nil
    queueAck(c, t) -- kaputt: bestätigen, sonst versucht es der Absender immer wieder
    return
  end
  if knownReading(c, t) then
    if not dupAcked[key] or t0 - dupAcked[key] > ASSEMBLY_TIMEOUT then
      dupAcked[key] = t0
      recv.dup = recv.dup + 1
      queueAck(c, t)
    end
    return
  end
  if c ~= char and DB.links[c] and DB.links[c] ~= DB.links[char] then
    if not dupAcked[key] or t0 - dupAcked[key] > ASSEMBLY_TIMEOUT then
      dupAcked[key] = t0
      recv.foreign = recv.foreign + 1
      queueAck(c, t) -- abgelehnt, aber bestätigt
    end
    return
  end
  local a = assembling[key]
  if not a or a.from ~= char or a.n ~= n then
    a = { from = char, n = n, parts = {}, at = t0 }
    assembling[key] = a
  end
  a.parts[nr] = payload or ""
  for i = 1, a.n do
    if not a.parts[i] then return end
  end
  assembling[key] = nil
  local values, bad = {}, 0
  for i = 1, a.n do bad = bad + parseValues(a.parts[i], values) end
  if next(values) == nil then
    recv.invalid = recv.invalid + 1
  elseif storeReading(c, t, values) then
    recv.ok = recv.ok + 1
    log("Statistiken empfangen: %s, %s", c:gsub("%-.*", ""), plural(#sortedKeys(values), "Wert", "Werte"))
  end
  if bad > 0 then recv.invalid = recv.invalid + 1 end
  queueAck(c, t)
  ns.changed()
end

function ns.onStatsMessage(kind, msg, channel, sender, char)
  if not DB then return end
  if kind == "Y" then
    if channel == "GUILD" then onAck(msg, char) end
  elseif kind == "S" and channel == "WHISPER" then
    onPart(msg, char)
  end
end

-- Fenster, /gchr status und /gchr diag --------------------------------------

function ns.statsView()
  local me = ns.me()
  local mine = me and DB.stats[me]
  local values = 0
  if mine then
    for _ in pairs(mine.v) do values = values + 1 end
  end
  return {
    shared = ns.sharesStats(), open = #DB.statsOut, sending = sending ~= nil, readAt = mine and mine.t,
    values = values, recv = recv, readings = #DB.statReadings, diag = DB.diag.stats,
  }
end

function ns.statsDiagLine()
  local d = DB.diag.stats
  local label = "Statistiken"
  if not ns.sharesStats() and not ns.isCollector() then
    return { label, "Nicht geteilt (Einstellungen: „Ich teile meine Statistiken mit der Chronik“), nichts gelesen", "idle" }
  end
  if not d then return { label, "Noch nicht gelesen. Kommt 15 s nach dem Betreten der Welt", "idle" } end
  if d.available == false then return { label, "Nicht verfügbar: Dieser Client hat kein Statistikfenster", "warn" } end
  if d.error then return { label, "Fehler: " .. d.error, "bad" } end
  local parts = { ("%d Kategorien, %d Statistiken"):format(d.categories or 0, d.statistics or 0) }
  if d.shared then
    parts[#parts + 1] = ("%d Werte, %d Kreaturtypen"):format(d.values or 0, d.criteria or 0)
  else
    parts[#parts + 1] = "eigene nicht geteilt, nur der Katalog"
  end
  if (d.noGold or 0) > 0 then parts[#parts + 1] = ("%d zum Vermögen nicht geteilt"):format(d.noGold) end
  if (d.secret or 0) > 0 then parts[#parts + 1] = ("%d geheime Werte"):format(d.secret) end
  if ns.isCollector() then
    parts[#parts + 1] = ("empfangen %d, %d schon da, %d ungültig, %d von Unbekannten, %d fremdes Konto, %d unvollständig")
      :format(recv.ok, recv.dup, recv.invalid, recv.unknown, recv.foreign, recv.timeout)
  end
  local when = ns.ago and (" (" .. ns.ago(d.at) .. ")") or ""
  local tone = (d.statistics or 0) > 0 and "ok" or "warn"
  return { label, table.concat(parts, ", ") .. when, tone }
end

-- Ablauf -------------------------------------------------------------------

function ns.initStats(db)
  DB = db
  DB.stats = DB.stats or {}
  DB.statsOut = DB.statsOut or {}
  DB.statReadings = DB.statReadings or {}
  -- Ohne Haken bleibt nichts Eigenes liegen (z. B. aus einer Version ohne Haken)
  if not DB.shareStats then wipe(DB.statsOut) end
end

-- Ein Sammler ist online gekommen: nach Meldung, Boss-Versuchen und Verlauf
function ns.onCollectorOnlineStats()
  C_Timer.After(math.random(40, 90), pump)
end

frame:SetScript("OnEvent", function(_, event)
  if not DB then return end
  if event == "PLAYER_LOGIN" then
    C_Timer.NewTicker(TICK, pump)
  elseif event == "PLAYER_ENTERING_WORLD" then
    inWorld = true
    readSoon(READ_DELAY)
    if not blocked() then C_Timer.After(math.random(30, 60), pump) end
  elseif event == "PLAYER_LEAVING_WORLD" then
    inWorld = false -- beim Ausloggen nie lesen, dann liefert WoW womöglich schon Unsinn
  elseif event == "CRITERIA_UPDATE" then
    if ns.sharesStats() then readSoon(5) end
  elseif event == "PLAYER_REGEN_ENABLED" then
    if readPending then
      readPending = false
      readSoon(3)
    end
    C_Timer.After(math.random(10, 20), pump)
  end
end)

for _, e in ipairs({ "PLAYER_LOGIN", "PLAYER_ENTERING_WORLD", "PLAYER_LEAVING_WORLD", "PLAYER_REGEN_ENABLED" }) do
  frame:RegisterEvent(e)
end
-- Gibt es vielleicht nicht in jedem Client; unbekannte Events werfen beim Registrieren
pcall(frame.RegisterEvent, frame, "CRITERIA_UPDATE")
