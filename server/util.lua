---@type table sd-phone config root (configs/config.lua); read for the number format + length.
local config = require 'configs.config'

---@type table Shared server helpers; the table returned at end of file.
local util = {}

-- Schema DDL is intentionally manual. Every store still declares its current CREATE TABLE shape
-- during boot, which keeps fresh installs usable, but repair/upgrade work is only registered here.
-- Running every information_schema audit on every resource restart is especially expensive on
-- MariaDB hosts where those catalogue reads take more than a second each.
---@type table<string, { key: string, phase: integer, sequence: integer, run: fun() }>
local schemaTasks = {}
local schemaTaskSequence = 0
local schemaMaintenanceActive = false
local schemaMaintenanceRunning = false
-- During the first install/upgrade pass, stores must be able to use columns immediately after
-- ensureColumns() returns. Outside that scoped pass, schema repairs stay deferred for the manual
-- sdphone:schema maintenance command.
local schemaBootstrapDepth = 0
local schemaMaintenanceWarnings = 0
local schemaCatalog = { columns = {}, indexes = {} }

---Returns one column's cached catalogue metadata. The first request for a table loads its columns
---in one read; later checks in the same maintenance run are in-memory lookups.
---@param tableName string
---@param columnName string
---@return table|nil column metadata
function util.schemaColumn(tableName, columnName)
    local byName = schemaCatalog.columns[tableName]
    if not byName then
        local rows = MySQL.query.await([[
            SELECT COLUMN_NAME AS name, IS_NULLABLE AS nullable, COLUMN_TYPE AS column_type
            FROM information_schema.columns
            WHERE table_schema = DATABASE() AND table_name = ?
        ]], { tableName }) or {}
        byName = {}
        for i = 1, #rows do byName[rows[i].name] = rows[i] end
        schemaCatalog.columns[tableName] = byName
    end
    return byName[columnName]
end

---Returns the ordered columns of one index. The first request for a table loads its index shape
---in one read; later checks in the same maintenance run are in-memory lookups.
---@param tableName string
---@param indexName string
---@return table[] columns
function util.schemaIndex(tableName, indexName)
    local byName = schemaCatalog.indexes[tableName]
    if not byName then
        local rows = MySQL.query.await([[
            SELECT INDEX_NAME AS name, COLUMN_NAME AS col, NON_UNIQUE AS non_unique,
                   SEQ_IN_INDEX AS seq
            FROM information_schema.statistics
            WHERE table_schema = DATABASE() AND table_name = ?
            ORDER BY INDEX_NAME, SEQ_IN_INDEX
        ]], { tableName }) or {}
        byName = {}
        for i = 1, #rows do
            local index = byName[rows[i].name]
            if not index then index = {}; byName[rows[i].name] = index end
            index[#index + 1] = rows[i]
        end
        schemaCatalog.indexes[tableName] = byName
    end
    return byName[indexName] or {}
end

---@param key string stable operation identity
---@param phase integer lower phases run first (columns, indexes, drops, then foreign keys)
---@param fn fun()
---@return boolean queued
local function queueSchemaTask(key, phase, fn)
    if schemaMaintenanceActive or schemaBootstrapDepth > 0 then return false end
    if not schemaTasks[key] then
        schemaTaskSequence = schemaTaskSequence + 1
        schemaTasks[key] = { key = key, phase = phase, sequence = schemaTaskSequence, run = fn }
    end
    return true
end

---Registers arbitrary schema repair work with the manual maintenance queue. This is for legacy
---shape checks that cannot be expressed by ensureColumns/ensureIndex; normal data-path work must
---not use it. When called by the maintenance runner, the operation executes immediately.
---@param key string stable operation identity
---@param phase integer dependency phase
---@param fn fun()
---@return boolean ran true only while an explicit maintenance run is active
function util.registerSchemaTask(key, phase, fn)
    if type(key) ~= 'string' or key == '' or type(phase) ~= 'number' or type(fn) ~= 'function' then
        error('invalid schema task')
    end
    if queueSchemaTask(('custom:%s'):format(key), math.floor(phase), function()
        util.registerSchemaTask(key, phase, fn)
    end) then return false end
    fn()
    return true
end

---How many schema maintenance operations this resource start registered.
---@return integer count
function util.schemaTaskCount()
    local count = 0
    for _ in pairs(schemaTasks) do count = count + 1 end
    return count
end

---Runs every registered DDL repair in dependency order. Called only by the console command in
---server/schema.lua; stores never invoke it automatically.
---@return { total: integer, completed: integer, failed: integer, failures: string[] }
function util.runSchemaMaintenance()
    if schemaMaintenanceRunning then error('schema maintenance is already running') end

    schemaCatalog = { columns = {}, indexes = {} }
    local ordered = {}
    for _, task in pairs(schemaTasks) do ordered[#ordered + 1] = task end
    table.sort(ordered, function(a, b)
        return a.phase == b.phase and a.sequence < b.sequence or a.phase < b.phase
    end)

    schemaMaintenanceRunning = true
    schemaMaintenanceActive = true
    schemaMaintenanceWarnings = 0
    local completed, failures = 0, {}
    for i = 1, #ordered do
        local ok, err = pcall(ordered[i].run)
        if ok then
            completed = completed + 1
        else
            failures[#failures + 1] = ('%s: %s'):format(ordered[i].key, tostring(err))
        end
    end
    schemaMaintenanceActive = false
    schemaMaintenanceRunning = false

    return {
        total = #ordered,
        completed = completed,
        failed = #failures,
        warnings = schemaMaintenanceWarnings,
        failures = failures,
    }
end

---@type table<string, boolean> Apps switched off in configs/apps.lua. Keyed on the disabled ones
---rather than the enabled ones, so an id this file has never heard of still counts as on.
local DISABLED_APPS = {}
for _, app in ipairs((config.Apps or {}).Apps or {}) do
    if app.id and app.enabled == false then DISABLED_APPS[app.id] = true end
end

---Whether an app is switched on in configs/apps.lua. Background work belonging to a single app is
---gated on this, so a disabled app costs no threads, no ticks and no writes.
---@param id string app id as configs/apps.lua names it
---@return boolean enabled
function util.appEnabled(id)
    return not DISABLED_APPS[id]
end

---Whether a player is carrying a phone right now. A server that gates the phone behind an item
---answers from the inventory; one with no phone items configured has no item to lose, so everyone
---carries one. Read on demand, never cached, so a dropped phone counts the moment it leaves.
---@param src number player server id
---@return boolean carrying
function util.carriesPhone(src)
    if #((config.Phone or {}).Items or {}) == 0 then return true end
    return exports['sd-phone']:hasPhone(src) ~= nil
end

---Success response envelope - the shape every callback/action returns on the happy path. `data`
---is optional and passed straight through to the React side.
---@param data? any payload the caller wants the frontend to receive
---@return { success: true, data?: any }
function util.ok(data) return { success = true, data = data } end

---Failure response envelope - the shape every callback/action returns when it refuses. The server
---has no per-player language, so it sends both halves: `messageKey` is the catalogue key the NUI
---resolves against the player's own locale, and `message` is the English text it falls back to.
---Called with one argument the message is passed through unkeyed and stays English.
---`vars` fills {placeholder} spans in both halves, so a message carrying a number stays one
---catalogue entry: fail('contacts.atMost', 'You can store at most {n} contacts', { n = 50 }).
---@param key string catalogue key, e.g. 'banking.insufficientFunds'
---@param message? string English text the NUI shows when the key is not in the player's catalogue
---@param vars? table<string, any> {placeholder} replacements applied by the NUI
---@return { success: false, messageKey?: string, message: string, messageVars?: table }
function util.fail(key, message, vars, field)
    local response
    if message == nil then
        response = { success = false, message = key }
    else
        local fields = { username = true, password = true, email = true, phone = true, name = true }
        if vars == nil and fields[message] then
            response = { success = false, message = key, field = message }
        else
            response = { success = false, messageKey = key, message = message, messageVars = vars }
        end
    end
    if field then response.field = field end
    return response
end

---Enables synchronous schema repairs while a store is bootstrapping its tables.
---Nested store bootstraps share the scope, so one finishing cannot re-enable queuing for another.
function util.beginSchemaBootstrap()
    schemaBootstrapDepth = schemaBootstrapDepth + 1
end

---Leaves the synchronous schema-repair scope.
function util.endSchemaBootstrap()
    schemaBootstrapDepth = math.max(0, schemaBootstrapDepth - 1)
end

---@type string Alphabet for generated row ids (base-36, lowercase) - matches the frontend's id shape.
local ID_CHARS = '0123456789abcdefghijklmnopqrstuvwxyz'

---Generates a random base-36 id of `len` characters.
---@param len integer id length in characters
---@return string
function util.newId(len)
    local out = {}
    for i = 1, len do
        local n = math.random(1, #ID_CHARS)
        out[i] = ID_CHARS:sub(n, n)
    end
    return table.concat(out)
end

---Strips everything but the digits from a value. An integral float formats as a plain integer
---first; non-string and nil inputs coerce to ''.
---@param s any
---@return string digits only
function util.digits(s)
    if math.type(s) == 'float' and s % 1 == 0 then s = ('%.0f'):format(s) end
    return (tostring(s or ''):gsub('%D', ''))
end

---Interprets a value as a boolean the way oxmysql hands back a TINYINT(1): a real boolean, the
---number 1, or the string '1' are all true; everything else is false.
---@param v any raw column value
---@return boolean
function util.truthy(v) return v == true or v == 1 or v == '1' end

---Trims leading/trailing whitespace. A non-string coerces to '' (never nil).
---@param s any
---@return string trimmed, or '' when not a string
-- Linear, and it has to stay that way. The obvious `s:gsub('%s+$', '')` is
-- quadratic on interior whitespace: for 'x' .. (' '):rep(n) .. 'x' the matcher
-- re-expands the run at every start position and backtracks it against `$`.
-- Measured on Lua 5.4: n=50k took 12.8s, n=100k 58s, n=200k 235s, all of it on
-- the server thread. trim runs before every length cap, so the cap cannot save
-- us; the trim itself must be safe on unbounded input.
function util.trim(s)
    if type(s) ~= 'string' then return '' end
    local from = s:match('^%s*()')
    return from > #s and '' or s:match('.*%S', from)
end

---Escapes LIKE wildcards so player text matches literally. Pair with `ESCAPE '\\'` in the query.
---@param s string
---@return string
function util.escapeLike(s)
    return (tostring(s):gsub('[%%_\\]', '\\%0'))
end

---Two-letter uppercase initials from a display name (first letters of the first two words), for
---avatar fallbacks. Falls back to the first character, then '#'. Nil-safe.
---@param name any display name
---@return string initials (1-2 chars, or '#')
function util.initialsFor(name)
    local words = {}
    for w in tostring(name or ''):gmatch('%S+') do words[#words + 1] = w end
    local a = words[1] and words[1]:sub(1, 1) or ''
    local b = words[2] and words[2]:sub(1, 1) or ''
    local out = (a .. b):upper()
    if out == '' then out = tostring(name or ''):sub(1, 1):upper() end
    return out ~= '' and out or '#'
end

---@type table Number settings (config.Phone.Number), defaulted so a config written before this
---section existed keeps the original US shape.
local NUMBER = (type(config.Phone) == 'table' and type(config.Phone.Number) == 'table')
    and config.Phone.Number or {}

---@type table<number, string> Display pattern per digit count, from config.
local FORMATS = type(NUMBER.Formats) == 'table' and NUMBER.Formats or { [10] = '(XXX) XXX-XXXX' }

---@type integer Digits in a newly generated number.
local LENGTH = math.floor(tonumber(NUMBER.Length) or 10)
if LENGTH < 3 then LENGTH = 3 end
if LENGTH > 15 then LENGTH = 15 end

---@type integer Random digits a generated number keeps however long the prefix is. Four leaves ten
---thousand numbers behind each prefix, which the twenty-attempt uniqueness retry in
---server.sim.store can still find a free slot in.
local MIN_RANDOM = 4

---@type string Digits every new number starts with, from config.Phone.Number.Prefix. An unusable
---prefix is refused outright rather than half-applied, and says so on boot: silently handing out
---numbers in a shape the server owner did not ask for is worse than ignoring the setting.
local PREFIX = (function()
    local raw = (tostring(NUMBER.Prefix or ''):gsub('%D', ''))
    if raw == '' then return '' end

    local lead = raw:sub(1, 1)
    if lead == '0' or lead == '1' then
        print(('^3[sd-phone]^0 Number.Prefix "%s" ignored: it cannot start with 0 or 1, because a leading zero is lost the first time the number passes through tonumber.'):format(raw))
        return ''
    end
    if #raw > LENGTH - MIN_RANDOM then
        print(('^3[sd-phone]^0 Number.Prefix "%s" ignored: it leaves fewer than %d random digits at Length %d, so numbers would collide.'):format(raw, MIN_RANDOM, LENGTH))
        return ''
    end
    return raw
end)()

---@type string The configured prefix as it is actually being applied, empty when there is none.
util.numberPrefix = PREFIX

---Renders digits into a display pattern: every X takes the next digit, every other character is
---literal. Digits past the pattern's last X are appended so nothing is ever silently dropped.
---@param pattern string
---@param d string bare digits
---@return string
local function applyPattern(pattern, d)
    local out, i = {}, 1
    for c in pattern:gmatch('.') do
        if c == 'X' then
            if i > #d then break end
            out[#out + 1] = d:sub(i, i)
            i = i + 1
        else
            out[#out + 1] = c
        end
    end
    if i <= #d then out[#out + 1] = d:sub(i) end
    return table.concat(out)
end

---Formats raw digits for display using config.Phone.Number.Formats. A digit count with no
---configured pattern (short codes, a length the server has since changed away from) passes
---through as bare digits rather than being forced into the wrong shape.
---@param number any
---@return string
function util.formatNumber(number)
    local d = util.digits(number)
    local pattern = FORMATS[#d]
    if type(pattern) ~= 'string' or pattern == '' then return d end
    return applyPattern(pattern, d)
end

---A random phone number as bare digits, at the configured length. Without a prefix the leading
---digit avoids 0 and 1 so numbers still read like real ones (and so the digit count never shrinks
---through a tonumber round-trip somewhere downstream). With one, the prefix leads and is already
---held to the same rule.
---@return string number bare digits, `config.Phone.Number.Length` of them
function util.randomNumber()
    local out = { PREFIX ~= '' and PREFIX or tostring(math.random(2, 9)) }
    for _ = #out[1] + 1, LENGTH do out[#out + 1] = tostring(math.random(0, 9)) end
    return table.concat(out)
end

---@type integer Digits a newly generated number gets; exposed for callers that report it.
util.numberLength = LENGTH

---@type integer[] Digit counts that count as a real number: the generated length plus every
---length with a display format, so numbers minted before a Length change stay valid. Ascending.
util.numberLengths = (function()
    local seen, out = { [LENGTH] = true }, { LENGTH }
    for length in pairs(FORMATS) do
        local n = tonumber(length)
        if n and n > 0 and not seen[n] then
            seen[n] = true
            out[#out + 1] = n
        end
    end
    table.sort(out)
    return out
end)()

---@type { min: integer, max: integer }|nil Digit counts a hand-assigned number may ALSO have, from
---config.Phone.Number.Custom. Generated numbers never use it; it only widens what phoneadmin and
---the setSimNumber export accept, so a premium player can be handed a 2 or 3 digit number. Held
---to 2..15 (a single digit collides with keypad shortcuts, 15 is the storage bound); a range that
---breaks that or runs backwards is dropped with the reason printed on boot, like a bad Prefix.
util.customNumberRange = (function()
    local raw = NUMBER.Custom
    if type(raw) ~= 'table' then return nil end
    local min = math.floor(tonumber(raw.MinLength) or 0)
    local max = math.floor(tonumber(raw.MaxLength) or 0)
    if min < 2 or max > 15 or min > max then
        print(('^3[sd-phone]^0 Number.Custom { MinLength = %s, MaxLength = %s } ignored: it must sit inside 2 to 15 with MinLength <= MaxLength.'):format(tostring(raw.MinLength), tostring(raw.MaxLength)))
        return nil
    end
    return { min = min, max = max }
end)()

---True when `digits` is a length this server accepts: one it generates or formats, or one inside
---the custom range.
---@param digits string bare digits
---@return boolean
function util.validNumberLength(digits)
    for _, n in ipairs(util.numberLengths) do
        if #digits == n then return true end
    end
    local custom = util.customNumberRange
    return custom ~= nil and #digits >= custom.min and #digits <= custom.max
end

---The accepted digit counts as prose for an error message: "10", "7 or 10", "2 to 3 or 10".
---@return string
function util.numberLengthsText()
    local parts = {}
    local custom = util.customNumberRange
    if custom then
        parts[1] = custom.min == custom.max and tostring(custom.min) or ('%d to %d'):format(custom.min, custom.max)
    end
    for _, n in ipairs(util.numberLengths) do
        if not (custom and n >= custom.min and n <= custom.max) then parts[#parts + 1] = tostring(n) end
    end
    return table.concat(parts, ' or ')
end

---Why `digits` cannot be handed to a player as their number, nil when it can. Shared by
---phoneadmin's number change and the setSimNumber export so both refuse the same shapes: a
---length this server does not accept, a leading zero (lost the first time the number passes
---through tonumber, which turns 077 into 77 and then into someone else's number), and a company
---or emergency line, which the dialler resolves ahead of player numbers, so a player holding 911
---could never be called.
---@param digits string bare digits
---@return 'length'|'zero'|'reserved'|nil reason
function util.numberAssignError(digits)
    if not util.validNumberLength(digits) then return 'length' end
    if digits:sub(1, 1) == '0' then return 'zero' end
    -- Required lazily: server.services.actions requires this module at load.
    local services = require 'server.services.actions'
    if services.jobForCallNumber(digits) then return 'reserved' end
    return nil
end

---@type string[] iOS system-colour palette, mirrored from the frontend.
local PALETTE = {
    '#0a84ff', '#30d158', '#ff375f', '#ff9f0a', '#bf5af2',
    '#ff453a', '#5e5ce6', '#64d2ff', '#ffd60a', '#636366',
}

---Deterministically picks a palette colour for a string via a 32-bit rolling hash, identical to
---the frontend hash (the & 0xffffffff wrap and the signed fold match JS).
---@param str string key to colour (a name, number, or handle)
---@return string hex colour
function util.colorFor(str)
    local h = 0
    for i = 1, #str do
        h = (h * 31 + str:byte(i)) & 0xffffffff
        if h >= 0x80000000 then h = h - 0x100000000 end
    end
    if h < 0 then h = -h end
    return PALETTE[(h % #PALETTE) + 1]
end

---True when a number is finite (not NaN, not +/-inf). Non-numbers are not finite.
---@param n any
---@return boolean
function util.finite(n)
    return type(n) == 'number' and n == n and n ~= math.huge and n ~= -math.huge
end

---@type table<string, boolean> Tables whose schema work failed this boot, keyed to dedupe: one
---bad table usually fails several statements and is still one line in the summary.
local degradedTables = {}
---@type string[] The same names in the order they first failed.
local degradedOrder = {}

---Records a table whose schema work could not be completed, and prints why. Schema statements are
---survivable precisely BECAUSE this exists: a shape sd-phone does not own has to leave a name in
---the boot summary, or a non-fatal failure is just a silent one.
---@param tbl string table the statement targeted
---@param what string the step that failed, e.g. 'index idx_foo'
---@param err any error raised
function util.schemaWarn(tbl, what, err)
    if schemaMaintenanceActive then schemaMaintenanceWarnings = schemaMaintenanceWarnings + 1 end
    if not degradedTables[tbl] then
        degradedTables[tbl] = true
        degradedOrder[#degradedOrder + 1] = tbl
    end
    print(('^3[sd-phone]^0 %s: skipped %s (%s)'):format(tbl, what, err))
end

---Every table degraded this boot, in first-failure order. Read by the boot summary.
---@return string[] table names
function util.degraded()
    return degradedOrder
end

---Validates the simple `(column, column)` shape accepted by the index helpers.
---@param tableName string
---@param indexName string
---@param columnsDDL string
---@return string[] columns
local function indexSpec(tableName, indexName, columnsDDL)
    for _, identifier in ipairs({ tableName, indexName }) do
        if type(identifier) ~= 'string' or not identifier:match('^[%w_]+$') then
            error('unsafe index identifier')
        end
    end
    local inner = type(columnsDDL) == 'string' and columnsDDL:match('^%s*%((.-)%)%s*$') or nil
    if not inner then error('invalid index column list') end
    local columns = {}
    for part in inner:gmatch('[^,]+') do
        local column = part:match('^%s*`?([%w_]+)`?%s*$')
        if not column then error('invalid index column') end
        columns[#columns + 1] = column
    end
    if #columns == 0 then error('empty index column list') end
    return columns
end

---@param tableName string
---@param indexName string
---@return table[] rows
local function existingIndex(tableName, indexName)
    return MySQL.query.await([[
        SELECT COLUMN_NAME AS col, NON_UNIQUE AS non_unique
        FROM information_schema.statistics
        WHERE table_schema = DATABASE() AND table_name = ? AND index_name = ?
        ORDER BY SEQ_IN_INDEX
    ]], { tableName, indexName }) or {}
end

---@param rows table[]
---@param columns string[]
---@param requireUnique? boolean
---@return boolean
local function indexMatches(rows, columns, requireUnique)
    if #rows ~= #columns then return false end
    for i = 1, #columns do
        if rows[i].col ~= columns[i] then return false end
        if requireUnique and rows[i].non_unique ~= false and tonumber(rows[i].non_unique) ~= 0 then
            return false
        end
    end
    return true
end

---Adds or repairs an index after the CREATE TABLE. An existing index with the right name but
---wrong column order is not silently accepted.
---@param tableName string
---@param indexName string
---@param columnsDDL string column list incl. parens, e.g. "(recipient, seen)"
---@return boolean created true when the index was added on this call
function util.ensureIndex(tableName, indexName, columnsDDL)
    if queueSchemaTask(('index:%s:%s'):format(tableName, indexName), 20, function()
        util.ensureIndex(tableName, indexName, columnsDDL)
    end) then return end

    local columns = indexSpec(tableName, indexName, columnsDDL)
    local rows = existingIndex(tableName, indexName)
    if indexMatches(rows, columns, false) then return end
    if #rows > 0 then
        -- One ALTER keeps the old index if the replacement definition is rejected. A two-step
        -- DROP then ADD could turn a harmless stale definition into a missing production index.
        local repaired, err = pcall(MySQL.query.await,
            ('ALTER TABLE `%s` DROP INDEX `%s`, ADD INDEX `%s` %s')
                :format(tableName, indexName, indexName, columnsDDL))
        if not repaired then
            util.schemaWarn(tableName, 'repairing index ' .. indexName, err)
            return false
        end
        return true
    end
    local added, err = pcall(MySQL.query.await,
        ('ALTER TABLE `%s` ADD INDEX `%s` %s'):format(tableName, indexName, columnsDDL))
    if not added then
        util.schemaWarn(tableName, 'index ' .. indexName, err)
        return false
    end
    return true
end

---Adds a UNIQUE index if absent. Distinct from ensureIndex because a unique index is a constraint,
---not just a lookup aid: it is what makes INSERT IGNORE actually ignore. Existing duplicate rows
---make the ALTER fail, so it is logged and skipped rather than fatal.
---@param tableName string
---@param indexName string
---@param columnsDDL string column list incl. parens, e.g. "(src_id)"
function util.ensureUniqueIndex(tableName, indexName, columnsDDL)
    if queueSchemaTask(('unique-index:%s:%s'):format(tableName, indexName), 20, function()
        util.ensureUniqueIndex(tableName, indexName, columnsDDL)
    end) then return end

    local columns = indexSpec(tableName, indexName, columnsDDL)
    local rows = existingIndex(tableName, indexName)
    if indexMatches(rows, columns, true) then return end
    if #rows > 0 then
        local repaired, err = pcall(MySQL.query.await,
            ('ALTER TABLE `%s` DROP INDEX `%s`, ADD UNIQUE INDEX `%s` %s')
                :format(tableName, indexName, indexName, columnsDDL))
        if not repaired then
            print(('^3[sd-phone]^0 could not repair unique index %s on %s: %s')
                :format(indexName, tableName, err))
        end
        return
    end

    local ok, err = pcall(MySQL.query.await,
        ('ALTER TABLE `%s` ADD UNIQUE INDEX `%s` %s'):format(tableName, indexName, columnsDDL))
    if not ok then
        print(('^3[sd-phone]^0 could not add unique index %s on %s: %s'):format(indexName, tableName, err))
    end
end

---True when a table already exists. Call BEFORE the CREATE TABLE so a module can tell a fresh
---install from an upgrade: on a fresh install the CREATE already declares every column, so the
---backfills below can be skipped entirely rather than probed for.
---@param tbl string table name
---@return boolean exists
function util.tableExists(tbl)
    local n = MySQL.scalar.await([[
        SELECT COUNT(*) FROM information_schema.tables
        WHERE table_schema = DATABASE() AND table_name = ? AND table_type = 'BASE TABLE'
    ]], { tbl })
    return (tonumber(n) or 0) > 0
end

---Queues a repair that adds every missing column with ONE catalogue read and at most ONE ALTER.
---Replaces the old per-column probe pattern and executes only through `sdphone:schema`.
---@param tbl string table name
---@param defs table<string, string> column name -> full DDL fragment, e.g. `locale VARCHAR(8) NULL`
---@return boolean added true when at least one column was created, false when none were or the ALTER failed
function util.ensureColumns(tbl, defs)
    local names = {}
    for name in pairs(defs) do names[#names + 1] = tostring(name) end
    table.sort(names)
    if queueSchemaTask(('columns:%s:%s'):format(tbl, table.concat(names, ',')), 10, function()
        util.ensureColumns(tbl, defs)
    end) then return false end

    local rows = MySQL.query.await([[
        SELECT COLUMN_NAME AS name FROM information_schema.columns
        WHERE table_schema = DATABASE() AND table_name = ?
    ]], { tbl }) or {}

    local have = {}
    for i = 1, #rows do have[rows[i].name] = true end

    local add = {}
    for name, ddl in pairs(defs) do
        if not have[name] then add[#add + 1] = ('ADD COLUMN %s'):format(ddl) end
    end
    if #add == 0 then return false end

    local ok, err = pcall(MySQL.query.await, ('ALTER TABLE `%s` %s'):format(tbl, table.concat(add, ', ')))
    if not ok then
        util.schemaWarn(tbl, 'column back-fill', err)
        return false
    end
    return true
end

---Queues a VARCHAR width repair for `sdphone:schema`.
---@param tbl string table name
---@param col string column name
---@param ddl string full column definition to MODIFY to
---@param want integer minimum CHARACTER_MAXIMUM_LENGTH required
---@return boolean widened false when already wide enough or the MODIFY failed
function util.ensureColumnWidth(tbl, col, ddl, want)
    if queueSchemaTask(('column-width:%s:%s'):format(tbl, col), 10, function()
        util.ensureColumnWidth(tbl, col, ddl, want)
    end) then return false end

    local have = MySQL.scalar.await([[
        SELECT CHARACTER_MAXIMUM_LENGTH FROM information_schema.columns
        WHERE table_schema = DATABASE() AND table_name = ? AND COLUMN_NAME = ?
    ]], { tbl, col })
    if not have or tonumber(have) == nil or tonumber(have) >= want then return false end

    local ok, err = pcall(MySQL.query.await, ('ALTER TABLE `%s` MODIFY COLUMN %s'):format(tbl, ddl))
    if not ok then
        util.schemaWarn(tbl, 'widening ' .. col, err)
        return false
    end
    return true
end

---Drops a named foreign key if it exists. Identifiers are deliberately restricted because
---MariaDB cannot bind table/column names as query parameters.
---@param child string child table
---@param name string constraint name
---@return boolean dropped
function util.dropForeignKey(child, name)
    if queueSchemaTask(('drop-foreign-key:%s:%s'):format(child, name), 30, function()
        util.dropForeignKey(child, name)
    end) then return false end

    if not child:match('^[%w_]+$') or not name:match('^[%w_]+$') then
        error('unsafe foreign-key identifier')
    end
    local present = MySQL.scalar.await([[
        SELECT COUNT(*) FROM information_schema.TABLE_CONSTRAINTS
        WHERE CONSTRAINT_SCHEMA = DATABASE() AND TABLE_NAME = ?
          AND CONSTRAINT_NAME = ? AND CONSTRAINT_TYPE = 'FOREIGN KEY'
    ]], { child, name })
    if (tonumber(present) or 0) == 0 then return false end
    local ok, err = pcall(MySQL.query.await,
        ('ALTER TABLE `%s` DROP FOREIGN KEY `%s`'):format(child, name))
    if not ok then
        print(('^3[sd-phone]^0 could not drop foreign key %s on %s: %s'):format(name, child, err))
        return false
    end
    return true
end

---Drops a redundant named secondary index after its replacement is in place. Missing indexes are
---a no-op; PRIMARY is deliberately forbidden.
---@param tableName string
---@param indexName string
---@return boolean dropped
function util.dropIndex(tableName, indexName)
    if queueSchemaTask(('drop-index:%s:%s'):format(tableName, indexName), 30, function()
        util.dropIndex(tableName, indexName)
    end) then return false end

    for _, identifier in ipairs({ tableName, indexName }) do
        if type(identifier) ~= 'string' or not identifier:match('^[%w_]+$') then
            error('unsafe index identifier')
        end
    end
    if indexName == 'PRIMARY' then error('cannot drop primary index') end
    if #existingIndex(tableName, indexName) == 0 then return false end
    local ok, err = pcall(MySQL.query.await,
        ('ALTER TABLE `%s` DROP INDEX `%s`'):format(tableName, indexName))
    if not ok then
        print(('^3[sd-phone]^0 could not drop redundant index %s on %s: %s')
            :format(indexName, tableName, err))
        return false
    end
    return true
end

---Adds or repairs a FOREIGN KEY during an explicit `sdphone:schema` run. Column
---compatibility is verified before any cleanup. The caller chooses what deletion means instead
---of every relationship silently cascading; existing constraints can be replaced when their
---rules are wrong. A failed ALTER is logged and skipped so one optional constraint never stops
---the resource from starting.
---@param child string child table
---@param col string child column
---@param parent string parent table
---@param parentCol string parent column (its primary key)
---@param name string constraint name, unique per database
---@param options? { onDelete?: 'CASCADE'|'SET NULL'|'RESTRICT'|'NO ACTION', onUpdate?: 'CASCADE'|'SET NULL'|'RESTRICT'|'NO ACTION', cleanup?: 'delete'|'null'|false, replace?: boolean }
---@return boolean created true when the constraint was added on this call
function util.ensureForeignKey(child, col, parent, parentCol, name, options)
    if queueSchemaTask(('foreign-key:%s:%s'):format(child, name), 40, function()
        util.ensureForeignKey(child, col, parent, parentCol, name, options)
    end) then return false end

    for _, identifier in ipairs({ child, col, parent, parentCol, name }) do
        if type(identifier) ~= 'string' or not identifier:match('^[%w_]+$') then
            error('unsafe foreign-key identifier')
        end
    end
    options = options or {}
    local validRules = { CASCADE = true, ['SET NULL'] = true, RESTRICT = true, ['NO ACTION'] = true }
    local onDelete = (options.onDelete or 'CASCADE'):upper()
    local onUpdate = (options.onUpdate or 'CASCADE'):upper()
    if not validRules[onDelete] or not validRules[onUpdate] then
        error('invalid foreign-key action')
    end

    local columns = MySQL.query.await([[
        SELECT TABLE_NAME AS tbl, COLUMN_NAME AS col, COLUMN_TYPE AS column_type,
               IS_NULLABLE AS nullable, COLLATION_NAME AS collation_name
        FROM information_schema.COLUMNS
        WHERE TABLE_SCHEMA = DATABASE()
          AND ((TABLE_NAME = ? AND COLUMN_NAME = ?) OR (TABLE_NAME = ? AND COLUMN_NAME = ?))
    ]], { child, col, parent, parentCol }) or {}
    if #columns ~= 2 then
        print(('^3[sd-phone]^0 skipped foreign key %s: a referenced table or column is missing'):format(name))
        return false
    end
    local childMeta, parentMeta
    for i = 1, #columns do
        local meta = columns[i]
        if meta.tbl == child and meta.col == col then childMeta = meta else parentMeta = meta end
    end
    if not childMeta or not parentMeta
        or childMeta.column_type ~= parentMeta.column_type
        or (childMeta.collation_name or '') ~= (parentMeta.collation_name or '') then
        print(('^3[sd-phone]^0 skipped foreign key %s: %s.%s and %s.%s have incompatible definitions')
            :format(name, child, col, parent, parentCol))
        return false
    end
    if (onDelete == 'SET NULL' or onUpdate == 'SET NULL') and childMeta.nullable ~= 'YES' then
        print(('^3[sd-phone]^0 skipped foreign key %s: %s.%s must be nullable for SET NULL')
            :format(name, child, col))
        return false
    end

    local existing = MySQL.single.await([[
        SELECT rc.CONSTRAINT_NAME AS constraint_name,
               rc.DELETE_RULE AS delete_rule, rc.UPDATE_RULE AS update_rule,
               kcu.COLUMN_NAME AS child_column,
               kcu.REFERENCED_TABLE_NAME AS parent_table,
               kcu.REFERENCED_COLUMN_NAME AS parent_column
        FROM information_schema.REFERENTIAL_CONSTRAINTS rc
        JOIN information_schema.KEY_COLUMN_USAGE kcu
          ON kcu.CONSTRAINT_SCHEMA = rc.CONSTRAINT_SCHEMA
         AND kcu.CONSTRAINT_NAME = rc.CONSTRAINT_NAME
         AND kcu.TABLE_NAME = rc.TABLE_NAME
        WHERE rc.CONSTRAINT_SCHEMA = DATABASE() AND rc.TABLE_NAME = ?
          AND rc.CONSTRAINT_NAME = ?
        LIMIT 1
    ]], { child, name })
    if not existing then
        -- Older resources often chose a different constraint name. Treat the relationship itself
        -- as identity so we neither stack duplicate FKs nor leave a stale delete rule in force.
        existing = MySQL.single.await([[
            SELECT rc.CONSTRAINT_NAME AS constraint_name,
                   rc.DELETE_RULE AS delete_rule, rc.UPDATE_RULE AS update_rule,
                   kcu.COLUMN_NAME AS child_column,
                   kcu.REFERENCED_TABLE_NAME AS parent_table,
                   kcu.REFERENCED_COLUMN_NAME AS parent_column
            FROM information_schema.REFERENTIAL_CONSTRAINTS rc
            JOIN information_schema.KEY_COLUMN_USAGE kcu
              ON kcu.CONSTRAINT_SCHEMA = rc.CONSTRAINT_SCHEMA
             AND kcu.CONSTRAINT_NAME = rc.CONSTRAINT_NAME
             AND kcu.TABLE_NAME = rc.TABLE_NAME
            WHERE rc.CONSTRAINT_SCHEMA = DATABASE() AND rc.TABLE_NAME = ?
              AND kcu.COLUMN_NAME = ? AND kcu.REFERENCED_TABLE_NAME = ?
              AND kcu.REFERENCED_COLUMN_NAME = ?
            LIMIT 1
        ]], { child, col, parent, parentCol })
    end
    if existing then
        local matches = existing.delete_rule == onDelete and existing.update_rule == onUpdate
            and existing.child_column == col
            and existing.parent_table == parent and existing.parent_column == parentCol
        if matches or options.replace == false then return false end
        local existingName = tostring(existing.constraint_name or name)
        local dropOk, dropped = pcall(util.dropForeignKey, child, existingName)
        if not dropOk or not dropped then
            print(('^3[sd-phone]^0 could not replace foreign key %s on %s: %s')
                :format(existingName, child, tostring(dropped)))
            return false
        end
    end

    local cleanup = options.cleanup
    if cleanup == nil then cleanup = onDelete == 'SET NULL' and 'null' or 'delete' end
    local repairOk, orphans = true, 0
    if cleanup == 'delete' then
        repairOk, orphans = pcall(MySQL.update.await, ([[
            DELETE c FROM `%s` c
            LEFT JOIN `%s` p ON p.`%s` = c.`%s`
            WHERE c.`%s` IS NOT NULL AND p.`%s` IS NULL
        ]]):format(child, parent, parentCol, col, col, parentCol))
    elseif cleanup == 'null' then
        repairOk, orphans = pcall(MySQL.update.await, ([[
            UPDATE `%s` c
            LEFT JOIN `%s` p ON p.`%s` = c.`%s`
            SET c.`%s` = NULL
            WHERE c.`%s` IS NOT NULL AND p.`%s` IS NULL
        ]]):format(child, parent, parentCol, col, col, col, parentCol))
    elseif cleanup ~= false then
        error('invalid foreign-key cleanup policy')
    end
    if not repairOk then
        print(('^3[sd-phone]^0 skipped foreign key %s: orphan cleanup failed: %s')
            :format(name, tostring(orphans)))
        return false
    end
    if (tonumber(orphans) or 0) > 0 then
        print(('^3[sd-phone]^0 %s: repaired %d orphaned row(s) before adding %s'):format(child, orphans, name))
    end

    -- InnoDB only needs the FK column to LEAD an index. Reuse a composite/primary index when one
    -- already does; creating a named single-column duplicate here bloats every child table.
    local supporting = MySQL.scalar.await([[
        SELECT 1 FROM information_schema.statistics
        WHERE table_schema = DATABASE() AND table_name = ? AND column_name = ?
          AND seq_in_index = 1
        LIMIT 1
    ]], { child, col })
    if not supporting then
        util.ensureIndex(child, 'idx_' .. name, ('(`%s`)'):format(col))
    end

    local ok, err = pcall(MySQL.query.await, ([[
        ALTER TABLE `%s` ADD CONSTRAINT `%s` FOREIGN KEY (`%s`)
        REFERENCES `%s`(`%s`) ON DELETE %s ON UPDATE %s
    ]]):format(child, name, col, parent, parentCol, onDelete, onUpdate))
    if not ok then
        print(('^3[sd-phone]^0 skipped foreign key %s on %s: %s'):format(name, child, err))
        return false
    end
    return true
end

---Runs a one-shot repair or backfill exactly once per database, recording it in phone_migrations
---so later boots skip it. Use for work whose predicate can't be indexed and would otherwise
---re-scan a whole table every start to match nothing.
---@param name string unique migration name
---@param fn fun(): table|nil the work; may return stats to stamp on the marker row
---@return boolean ran true when the work executed on this call
function util.runOnce(name, fn)
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS phone_migrations (
            name       VARCHAR(64) NOT NULL,
            applied_at TIMESTAMP   NOT NULL DEFAULT CURRENT_TIMESTAMP,
            stats      JSON        NULL,
            PRIMARY KEY (name)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])
    if MySQL.scalar.await('SELECT 1 FROM phone_migrations WHERE name = ? LIMIT 1', { name }) ~= nil then
        return false
    end
    local stats = fn()
    MySQL.query.await(
        'INSERT IGNORE INTO phone_migrations (name, stats) VALUES (?, ?)',
        { name, json.encode(stats or {}) }
    )
    return true
end

-- All known lb-phone/sd-phone name collisions are inventoried in one catalogue read. Previously
-- every rescue call made two information_schema queries on every restart, even after the tables
-- had long since been normalized.
local RESCUE_TABLES = {
    phone_messages = true,
    phone_message_reactions = true,
    phone_documents = true,
    phone_document_folders = true,
    phone_mail_accounts = true,
    phone_mail_messages = true,
    phone_photos = true,
    phone_photo_albums = true,
    phone_notes = true,
}
---@type table<string, table<string, boolean>>|nil
local rescueShapes
local rescueShapesLoading = false

local function loadRescueShapes()
    if rescueShapes then return end
    while rescueShapesLoading do Wait(0) end
    if rescueShapes then return end

    rescueShapesLoading = true
    local ok, rows = pcall(MySQL.query.await, [[
            SELECT c.TABLE_NAME AS tbl, c.COLUMN_NAME AS col
            FROM information_schema.COLUMNS c
            JOIN information_schema.TABLES t
              ON t.TABLE_SCHEMA = c.TABLE_SCHEMA AND t.TABLE_NAME = c.TABLE_NAME
            WHERE c.TABLE_SCHEMA = DATABASE() AND t.TABLE_TYPE = 'BASE TABLE'
              AND c.TABLE_NAME IN (
                'phone_messages', 'phone_message_reactions', 'phone_documents',
                'phone_document_folders', 'phone_mail_accounts', 'phone_mail_messages',
                'phone_photos', 'phone_photo_albums', 'phone_notes'
              )
        ]])
    rescueShapesLoading = false
    if not ok then error(rows) end

    rescueShapes = {}
    rows = rows or {}
    for i = 1, #rows do
        local columns = rescueShapes[rows[i].tbl]
        if not columns then columns = {}; rescueShapes[rows[i].tbl] = columns end
        columns[rows[i].col] = true
    end
end

---Rescues a same-named table left behind by another phone resource. When `tbl` exists but is
---missing the sd-phone marker column, it is renamed to `<tbl>_lb` (or the next free numbered
---suffix) so the following CREATE TABLE builds the real sd-phone table. The old data is preserved
---for the explicit lb-phone importer. Call before CREATE TABLE.
---@param tbl string table name
---@param markerColumn string column only the sd-phone shape has (e.g. 'citizenid')
---@return boolean renamed true when a foreign-shaped table was moved aside
function util.rescueLegacyTable(tbl, markerColumn)
    if type(tbl) ~= 'string' or not tbl:match('^[%w_]+$')
        or type(markerColumn) ~= 'string' or not markerColumn:match('^[%w_]+$') then
        error('unsafe legacy table identifier')
    end

    local columns
    if RESCUE_TABLES[tbl] then
        loadRescueShapes()
        columns = rescueShapes[tbl]
    else
        local rows = MySQL.query.await([[
            SELECT c.COLUMN_NAME AS col
            FROM information_schema.COLUMNS c
            JOIN information_schema.TABLES t
              ON t.TABLE_SCHEMA = c.TABLE_SCHEMA AND t.TABLE_NAME = c.TABLE_NAME
            WHERE c.TABLE_SCHEMA = DATABASE() AND c.TABLE_NAME = ?
              AND t.TABLE_TYPE = 'BASE TABLE'
        ]], { tbl }) or {}
        if #rows > 0 then
            columns = {}
            for i = 1, #rows do columns[rows[i].col] = true end
        end
    end
    if not columns or columns[markerColumn] then return false end

    local target = tbl .. '_lb'
    local suffix = 1
    while (tonumber(MySQL.scalar.await([[
        SELECT COUNT(*) FROM information_schema.tables
        WHERE table_schema = DATABASE() AND table_name = ?
    ]], { target })) or 0) > 0 do
        suffix = suffix + 1
        if suffix > 99 then error(('no free legacy backup name for %s'):format(tbl)) end
        target = ('%s_lb%d'):format(tbl, suffix)
    end

    MySQL.query.await(('RENAME TABLE `%s` TO `%s`'):format(tbl, target))
    if rescueShapes then rescueShapes[tbl] = nil end
    print(('^3[sd-phone]^0 foreign-shaped table %s (no `%s` column) moved aside to %s'):format(tbl, markerColumn, target))
    return true
end

---Declares a table: moves a foreign-shaped one aside, then runs the CREATE. The pair belongs
---together, because a CREATE TABLE IF NOT EXISTS on its own silently keeps whatever table already
---owns the name, and every read afterwards fails on columns that table never had. Taking the
---marker column as an argument is the point: it forces each store to say which column proves a
---table is sd-phone's, rather than leaving the question unasked.
---@param name string table name
---@param markerColumn string column that only sd-phone's version of this table has
---@param ddl string the full CREATE TABLE IF NOT EXISTS statement
---@return boolean rescued true when a foreign table was moved aside first
function util.ensureTable(name, markerColumn, ddl)
    local rescued = util.rescueLegacyTable(name, markerColumn)
    MySQL.query.await(ddl)
    return rescued
end

---Converts a table to utf8mb4_unicode_ci when its collation differs. Newer MariaDB defaults to
---utf8mb4_uca1400_ai_ci, and a CREATE without an explicit COLLATE then can't be joined against
---the explicitly-collated tables. A no-op when the table is absent or already matches, and a
---failing conversion is recorded and skipped rather than raised.
---@param tbl string table name
function util.ensureCollation(tbl)
    if queueSchemaTask(('collation:%s'):format(tbl), 10, function()
        util.ensureCollation(tbl)
    end) then return end

    local collation = MySQL.scalar.await([[
        SELECT table_collation FROM information_schema.tables
        WHERE table_schema = DATABASE() AND table_name = ?
    ]], { tbl })
    if not collation or collation == 'utf8mb4_unicode_ci' then return end

    local ok, err = pcall(MySQL.query.await,
        ('ALTER TABLE `%s` CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci'):format(tbl))
    if not ok then
        util.schemaWarn(tbl, 'collation conversion', err)
        return
    end
    print(('^3[sd-phone]^0 converted %s from %s to utf8mb4_unicode_ci'):format(tbl, collation))
end

---Coerces a client-supplied value to a whole, non-negative amount: non-numbers and NaN/inf
---collapse to 0, everything else floors and clamps at 0.
---@param v any
---@return integer amount >= 0
function util.wholeAmount(v)
    local n = tonumber(v)
    if not util.finite(n) then return 0 end
    return math.max(0, math.floor(n))
end

---@type integer How often stale limiter buckets are swept (ms). The walk is over live buckets
---only, so this can stay infrequent without the table growing between passes.
local SWEEP_MS = 5 * 60 * 1000

---@type table<string, { last: integer, ttl: integer, events: integer[]? }>
---"<citizenid>\0<kind>\0<key>" -> bucket. Keyed by citizenid and never by source, so dropping and
---reconnecting cannot reset a limit. A stamp in the future (GetGameTimer wrapping on a server with
---weeks of uptime) counts as expired everywhere, so a wrap can never leave a limit stuck closed.
local buckets = {}

---Minimum gap between accepted calls for one citizenid + key. A blocked call is NOT recorded, so
---the gap never extends under spam: a flooding client still gets exactly one call every `ms`.
---A missing cid (server-side exports, a player still loading) is never blocked.
---@param cid string|nil citizenid, never a source (a non-string is treated as missing, so never blocked)
---@param key string limiter name, a call-site constant (a client-supplied key allocates a bucket per value)
---@param ms integer minimum gap between accepted calls
---@return boolean ok true when the call may proceed
function util.cooldown(cid, key, ms)
    if type(cid) ~= 'string' or cid == '' then return true end
    local gap = tonumber(ms) or 0
    local now = GetGameTimer()
    local k = cid .. '\0c\0' .. tostring(key)
    local b = buckets[k]
    if b then
        local since = now - b.last
        if since >= 0 and since < gap then return false end
        b.last, b.ttl = now, gap
    else
        buckets[k] = { last = now, ttl = gap }
    end
    return true
end

---Milliseconds left before `util.cooldown` would accept the same key again, or 0 when it is
---already clear. Read-only: it neither opens a bucket nor refreshes one, so a UI may poll it to
---show a countdown without pushing the cooldown out.
---@param cid string|nil citizenid (a non-string reads as clear)
---@param key string limiter name, matching the cooldown call
---@param ms integer window length the matching cooldown call uses
---@return integer remaining milliseconds, 0 when clear
function util.cooldownLeft(cid, key, ms)
    if type(cid) ~= 'string' or cid == '' then return 0 end
    local b = buckets[cid .. '\0c\0' .. tostring(key)]
    if not b then return 0 end
    local left = (tonumber(ms) or 0) - (GetGameTimer() - b.last)
    return left > 0 and math.floor(left) or 0
end

---Rolling-window budget for one citizenid + key: at most `maxInWindow` accepted calls in any
---`windowMs`. Blocked calls are not recorded, so a caller who backs off recovers as the window
---drains instead of serving a penalty. A missing cid is never blocked.
---@param cid string|nil citizenid, never a source (a non-string is treated as missing, so never blocked)
---@param key string limiter name, a call-site constant (a client-supplied key allocates a bucket per value)
---@param windowMs integer rolling window length in ms
---@param maxInWindow integer accepted calls allowed inside one window
---@return boolean ok true when the call may proceed
function util.rateLimit(cid, key, windowMs, maxInWindow)
    if type(cid) ~= 'string' or cid == '' then return true end
    local window = tonumber(windowMs) or 0
    local max = tonumber(maxInWindow) or 0
    local now = GetGameTimer()
    local k = cid .. '\0r\0' .. tostring(key)
    local b = buckets[k]
    if not b then
        if max < 1 then return false end
        buckets[k] = { last = now, ttl = window, events = { now } }
        return true
    end

    -- Compacted in place rather than rebuilt: the array can only hold `max` accepted stamps, so
    -- the reject path stays O(max) and allocates nothing.
    local events, kept = b.events, 0
    for i = 1, #events do
        local t = events[i]
        local age = now - t
        if age >= 0 and age < window then
            kept = kept + 1
            events[kept] = t
        end
    end
    for i = #events, kept + 1, -1 do events[i] = nil end
    if kept >= max then return false end

    events[kept + 1] = now
    b.last, b.ttl = now, window
    return true
end

-- Periodic sweep: a bucket whose window has fully elapsed rebuilds identically from scratch, so
-- drop it instead of holding one entry per citizenid per call site for the server's uptime.
CreateThread(function()
    while true do
        Wait(SWEEP_MS)
        local now = GetGameTimer()
        for k, b in pairs(buckets) do
            local age = now - b.last
            if age < 0 or age >= b.ttl then buckets[k] = nil end
        end
    end
end)

---Cuts a byte-capped string back to the last whole UTF-8 codepoint, so a cap can never leave the
---half sequence that a utf8mb4 column rejects.
---@param s string
---@return string
local function wholeUtf8(s)
    local i = #s
    while i > 0 do
        local b = s:byte(i)
        if b < 0x80 or b >= 0xC0 then break end
        i = i - 1
    end
    if i == 0 then return s end
    local lead = s:byte(i)
    local need = lead < 0x80 and 1 or lead < 0xE0 and 2 or lead < 0xF0 and 3 or 4
    if i + need - 1 > #s then return s:sub(1, i - 1) end
    return s
end

---Trims a client string and caps it to `maxLen` BYTES, matching what the column actually stores.
---Non-strings and empty-after-trim collapse to nil so a caller rejects with one `if not v then`.
---@param v any raw client value
---@param maxLen integer maximum byte length
---@return string|nil
function util.limitedString(v, maxLen)
    if type(v) ~= 'string' then return nil end
    local s = util.trim(v)
    if s == '' then return nil end
    local max = tonumber(maxLen) or 0
    if max < 1 then return nil end
    if #s > max then s = wholeUtf8(s:sub(1, max)) end
    return s ~= '' and s or nil
end

---True when a value's JSON encoding fits in `maxBytes`. Encodes once; nil is always within budget,
---and an encode failure (a cycle, excessive nesting, a function value) counts as over budget.
---@param v any
---@param maxBytes integer
---@return boolean ok
function util.encodedSize(v, maxBytes)
    local max = tonumber(maxBytes) or 0
    if v == nil then return true end
    if type(v) == 'string' then return #v <= max end
    local ok, encoded = pcall(json.encode, v)
    if not ok or type(encoded) ~= 'string' then return false end
    return #encoded <= max
end

---Validates a client-supplied table before it is stored or relayed: a table, at most `maxEntries`
---pairs at each level, at most one level of nesting, scalar leaves only, and an encoded size
---within `maxBytes` so one huge string value cannot pass a cheap entry count.
---@param v any raw client value
---@param maxEntries integer maximum pairs at each level
---@param maxBytes integer maximum JSON-encoded size
---@return table|nil value the original table, or nil when it fails any check
function util.smallTable(v, maxEntries, maxBytes)
    if type(v) ~= 'table' then return nil end
    local max = tonumber(maxEntries) or 0
    -- String leaves are tallied as they are walked so a multi-megabyte value is refused before the
    -- encoder ever runs; a leaf can only grow under encoding, so this rejects nothing extra.
    local budget = tonumber(maxBytes) or 0
    local n, bytes = 0, 0
    for _, val in pairs(v) do
        n = n + 1
        if n > max then return nil end
        local t = type(val)
        if t == 'table' then
            local inner = 0
            for _, leaf in pairs(val) do
                inner = inner + 1
                if inner > max then return nil end
                local lt = type(leaf)
                if lt == 'table' or lt == 'function' or lt == 'userdata' or lt == 'thread' then return nil end
                if lt == 'string' then
                    bytes = bytes + #leaf
                    if bytes > budget then return nil end
                end
            end
        elseif t == 'function' or t == 'userdata' or t == 'thread' then
            return nil
        elseif t == 'string' then
            bytes = bytes + #val
            if bytes > budget then return nil end
        end
    end
    if not util.encodedSize(v, maxBytes) then return nil end
    return v
end

---@type fun(source: integer, citizenid: string|nil)[] Registered disconnect sweeps.
local cleanups = {}

---Registers a sweep to run when a player disconnects, so a module that keys a table on source can
---drop its row without adding another playerDropped handler. `citizenid` is best effort: the
---framework may already have unloaded the character, so key on `source` and treat cid as a hint.
---@param fn fun(source: integer, citizenid: string|nil)
function util.onCleanup(fn)
    if type(fn) ~= 'function' then return end
    cleanups[#cleanups + 1] = fn
end

AddEventHandler('playerDropped', function()
    local src = source
    -- Required here rather than at file scope so util stays the lowest-level module, loadable
    -- without the bridge; ox_lib caches the module so this is a table lookup after the first drop.
    local ok, cid = pcall(function() return require('bridge.server.player').getIdentifier(src) end)
    for i = 1, #cleanups do pcall(cleanups[i], src, ok and cid or nil) end
end)

---@type boolean Whether this server's ox_lib carries the triggerClientEvent module.
---
---Probed by reading the file, NOT by testing `lib.triggerClientEvent` for nil. ox_lib's loader
---(`@ox_lib/init.lua`, the `call` metamethod) answers a MISSING module with a stub that forwards to
---an ox_lib export of the same name, so the field is always truthy and a nil check would pass on
---every version and then fail at the call with "No such export".
---
---sd-phone declares `dependencies { 'ox_lib' }` with no version floor and ships to servers running
---whatever they already had, and the module carries its own "may be deprecated" note upstream - so
---the probe guards both directions in time.
local HAS_BATCHED_PUSH = LoadResourceFile('ox_lib', 'imports/triggerClientEvent/server.lua') ~= nil

---Sends one event to many players. Prefers ox_lib's batched push, which msgpacks the arguments once
---and reuses the buffer per target instead of re-packing them for each; falls back to a plain loop
---of TriggerClientEvent, which is what the batched version does internally anyway.
---
---Every fan-out in the resource goes through here, so an ox_lib that drops the module is one edit
---to absorb rather than ten.
---@param event string client event name
---@param targets integer[] player server ids; an empty list is a no-op
---@param ... any event arguments
function util.pushMany(event, targets, ...)
    if type(targets) ~= 'table' or not targets[1] then return end

    if HAS_BATCHED_PUSH then
        return lib.triggerClientEvent(event, targets, ...)
    end

    for i = 1, #targets do
        TriggerClientEvent(event, targets[i], ...)
    end
end

---@type string base64url alphabet, matching b64urlEncode in web/src/lib/waypointCode.ts.
local WP_B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_'

---@type table<string, boolean> Pin glyphs decodeWaypoint accepts; anything else falls back to MapPin.
local WP_ICONS = {
    MapPin = true, Home = true, Star = true, Flag = true, Skull = true, DollarSign = true,
    Car = true, Crosshair = true, Heart = true, Wrench = true, ShoppingCart = true, Fuel = true,
}

---base64url encode, unpadded.
---@param data string
---@return string
local function b64url(data)
    local out = {}
    for i = 1, #data, 3 do
        local a, b, c = data:byte(i, i + 2)
        local n = a * 65536 + (b or 0) * 256 + (c or 0)
        out[#out + 1] = table.concat({
            WP_B64:sub((n >> 18) + 1, (n >> 18) + 1),
            WP_B64:sub(((n >> 12) & 63) + 1, ((n >> 12) & 63) + 1),
            b and WP_B64:sub(((n >> 6) & 63) + 1, ((n >> 6) & 63) + 1) or '',
            c and WP_B64:sub((n & 63) + 1, (n & 63) + 1) or '',
        })
    end
    return table.concat(out)
end

---Builds the shared-waypoint code a location message carries in its `wpCode` meta field. Mirrors
---encodeWaypoint in web/src/lib/waypointCode.ts: an `SDW1:` prefix over base64url of { l,x,y,i,c }.
---@param x number world x
---@param y number world y
---@param label string|nil pin label, capped at 40 chars by the decoder
---@param icon string|nil one of WP_ICONS, default MapPin
---@param color string|nil hex colour, default #5c6cf3
---@return string|nil code nil when the position is not finite
function util.waypointCode(x, y, label, icon, color)
    x, y = tonumber(x), tonumber(y)
    if not util.finite(x) or not util.finite(y) then return nil end

    local text = util.trim(label)
    return 'SDW1:' .. b64url(json.encode({
        l = text ~= '' and text:sub(1, 40) or 'Shared location',
        x = math.floor(x + 0.5),
        y = math.floor(y + 0.5),
        i = WP_ICONS[icon] and icon or 'MapPin',
        c = type(color) == 'string' and color:match('^#%x%x%x+$') or '#5c6cf3',
    }))
end

return util
