---@type table Store module; the table returned at end of file.
local store = {}

local util = require 'server.util'
local credentialStore = require 'server.accounts.store'
local mailConfig = require('configs.config').Mail

local function newId() return util.newId(10) end
store.newId = newId

-- Mail uses the same salted scrypt format as the account engine. These aliases retain the
-- public store API and the legacy verifier while ensuring nothing new is written with Mail's
-- old deterministic 96-bit digest.
store.hashPassword = credentialStore.hashPassword
store.needsPasswordRehash = credentialStore.needsRehash

local LEGACY_MAIL_PEPPER = 'sd-phone-v1::mail::do-not-leak-this-string'

---@param password string
---@return string
local function legacyMailHash(password)
    local input = password .. LEGACY_MAIL_PEPPER
    local h1, h2, h3 = 0x12345678, 0x87654321, 0xABCDEF01
    for i = 1, #input do
        local b = input:byte(i)
        h1 = (h1 * 31 + b) & 0xFFFFFFFF
        h2 = ((h2 ~ ((b << (i % 8)) & 0xFFFFFFFF)) + 0x9E3779B9) & 0xFFFFFFFF
        h3 = (((h3 << 5) | (h3 >> 27)) + b * (h1 + 1)) & 0xFFFFFFFF
    end
    return ('%08x%08x%08x'):format(h1, h2, h3)
end

-- Exported only for the account engine's one-time verification of rows imported from old Mail.
store.legacyHashPassword = legacyMailHash

---@param plain string
---@param stored any
---@return boolean
function store.verifyPassword(plain, stored)
    return credentialStore.verifyPassword(plain, stored)
        or (type(stored) == 'string' and legacyMailHash(plain) == stored)
end

---@param value any
---@return table
local function decodeJson(value)
    if value == nil then return {} end
    if type(value) == 'table' then return value end
    if type(value) == 'string' then
        local ok, decoded = pcall(json.decode, value)
        if ok and type(decoded) == 'table' then return decoded end
    end
    return {}
end

---@param tbl table|nil
---@return string
local function encodeJson(tbl)
    return json.encode(tbl or {})
end

local MAX_MESSAGE_BODY = 10000
local MAX_ATTACHMENTS_JSON = 2 * 1024 * 1024
local MESSAGE_RETENTION = math.max(1, math.min(tonumber(mailConfig.MaxMessagesPerAccount) or 200, 1000))
local ACCOUNT_LIST_CAP = math.max(1, math.min(tonumber(mailConfig.MaxAccountsPerPlayer) or 3, 10))
local SAVED_EMAIL_LIST_CAP = 200

---@param attachments any
---@return string|nil
local function encodeAttachments(attachments)
    if type(attachments) ~= 'table' then return nil end
    local encoded = encodeJson(attachments)
    return #encoded <= MAX_ATTACHMENTS_JSON and encoded or nil
end

---@param value any
---@return boolean
local function dbBool(value)
    return value == true or tonumber(value) == 1
end

---@param row table
---@return table
local function hydrateMessage(row)
    return {
        id = row.id,
        folder = row.folder or 'inbox',
        from = { name = row.from_name or '', email = row.from_email or '' },
        to = decodeJson(row.recipients),
        subject = row.subject or '',
        body = row.body or '',
        sentAt = row.sent_at or '',
        read = dbBool(row.read_flag),
        flagged = dbBool(row.flagged),
        attachments = row.attachments == nil and nil or decodeJson(row.attachments),
        loaded = row.loaded == nil or dbBool(row.loaded),
    }
end

---@param rows table[]
---@return string, table
local function placeholdersFor(rows)
    local marks, params = {}, {}
    for i = 1, #rows do
        marks[i] = '?'
        params[i] = rows[i].email
    end
    return table.concat(marks, ','), params
end

---Attaches sessions and, optionally, messages to account rows with a constant number of indexed
---queries. This avoids both N+1 reads and the former JSON_SEARCH full-table scan.
---@param rows table[]
---@param includeMessages? boolean|'summary'
---@return table[]
local function hydrateAccounts(rows, includeMessages)
    if #rows == 0 then return rows end
    local marks, params = placeholdersFor(rows)
    local sessions = MySQL.query.await(([[
        SELECT email, citizenid
        FROM phone_mail_sessions
        WHERE email IN (%s)
        ORDER BY email, citizenid
    ]]):format(marks), params) or {}

    local sessionsByEmail = {}
    for i = 1, #sessions do
        local list = sessionsByEmail[sessions[i].email]
        if not list then list = {}; sessionsByEmail[sessions[i].email] = list end
        list[#list + 1] = sessions[i].citizenid
    end

    local messagesByEmail = {}
    if includeMessages ~= false then
        local messageSql
        if includeMessages == 'summary' then
            -- The first Mail snapshot is only a recent window of lightweight previews. Full
            -- bodies and attachments are fetched by getMessage after a row is opened.
            messageSql = ([[
                SELECT account_email, id, folder, from_name, from_email, recipients, subject,
                       LEFT(body, 240) AS body, sent_at, read_flag, flagged,
                       NULL AS attachments, 0 AS loaded
                FROM (
                    SELECT account_email, id, folder, from_name, from_email, recipients, subject,
                           body, sent_at, read_flag, flagged, seq,
                           ROW_NUMBER() OVER (PARTITION BY account_email ORDER BY seq DESC) AS row_num
                    FROM phone_mail_messages
                    WHERE account_email IN (%s)
                ) recent
                WHERE row_num <= 20
                ORDER BY account_email, seq ASC
            ]]):format(marks)
        else
            messageSql = ([[
            SELECT account_email, id, folder, from_name, from_email, recipients, subject,
                   LEFT(body, 10000) AS body,
                   sent_at, read_flag, flagged, attachments, 1 AS loaded
            FROM phone_mail_messages
            WHERE account_email IN (%s)
            ORDER BY seq ASC
            ]]):format(marks)
        end
        local messages = MySQL.query.await(messageSql, params) or {}
        for i = 1, #messages do
            local list = messagesByEmail[messages[i].account_email]
            if not list then list = {}; messagesByEmail[messages[i].account_email] = list end
            list[#list + 1] = hydrateMessage(messages[i])
        end
    end

    for i = 1, #rows do
        local row = rows[i]
        rows[i] = {
            email = row.email,
            password_hash = row.password_hash,
            display_name = row.display_name,
            messages = messagesByEmail[row.email] or {},
            logged_in_citizens = sessionsByEmail[row.email] or {},
        }
    end
    return rows
end

---@type integer
local MIGRATION_CHUNK = 300

---@param email string
---@param cap? number
---@return number removed
local function pruneAccount(email, cap)
    cap = math.max(1, math.min(math.floor(tonumber(cap) or MESSAGE_RETENTION), 1000))
    local threshold = MySQL.scalar.await(([[
        SELECT seq FROM phone_mail_messages
        WHERE account_email = ?
        ORDER BY seq DESC
        LIMIT 1 OFFSET %d
    ]]):format(cap - 1), { email })
    if not threshold then return 0 end
    return tonumber(MySQL.update.await(
        'DELETE FROM phone_mail_messages WHERE account_email = ? AND seq < ?',
        { email, threshold })) or 0
end

---Imports legacy logged_in_citizens JSON into the authoritative junction table. It deliberately
---never removes junction rows: current sessions must not be destroyed by stale import JSON.
---The legacy column is cleared after each account so future boots do no table-wide reconciliation.
---@return integer added
---@return integer removed always zero; retained for importer compatibility
local function reconcileSessions()
    local accounts = MySQL.query.await([[
        SELECT email, logged_in_citizens
        FROM phone_mail_accounts
        WHERE logged_in_citizens IS NOT NULL AND JSON_LENGTH(logged_in_citizens) > 0
    ]]) or {}
    local pairs, seen = {}, {}
    for i = 1, #accounts do
        local email = accounts[i].email
        local list = decodeJson(accounts[i].logged_in_citizens)
        for j = 1, #list do
            local cid = list[j]
            local key = tostring(cid) .. '\0' .. tostring(email):lower()
            if type(cid) == 'string' and cid ~= '' and not seen[key] then
                seen[key] = true
                pairs[#pairs + 1] = { cid, email }
            end
        end
    end

    local added = 0
    for i = 1, #pairs, MIGRATION_CHUNK do
        local groups, params = {}, {}
        for j = i, math.min(i + MIGRATION_CHUNK - 1, #pairs) do
            groups[#groups + 1] = '(?,?)'
            params[#params + 1] = pairs[j][1]
            params[#params + 1] = pairs[j][2]
        end
        added = added + (tonumber(MySQL.update.await(
            'INSERT IGNORE INTO phone_mail_sessions (citizenid, email) VALUES ' .. table.concat(groups, ','),
            params
        )) or 0)
    end
    if #accounts > 0 then
        MySQL.update.await([[
            UPDATE phone_mail_accounts
            SET logged_in_citizens = '[]'
            WHERE logged_in_citizens IS NOT NULL AND JSON_LENGTH(logged_in_citizens) > 0
        ]])
    end
    return added, 0
end
store.reconcileSessions = reconcileSessions

---Imports legacy messages JSON into row storage. Exposed for the live lb-phone importer, which
---can write legacy account rows after the normal boot migration has already completed.
---@return table stats
local function reconcileMessages()
    local accounts = MySQL.query.await([[
        SELECT email, messages
        FROM phone_mail_accounts
        WHERE messages IS NOT NULL AND JSON_LENGTH(messages) > 0
    ]]) or {}
    local copied = 0
    for i = 1, #accounts do
        local messages = decodeJson(accounts[i].messages)
        for j = 1, #messages do
            local message = messages[j]
            if type(message) == 'table' then
                local from = type(message.from) == 'table' and message.from or {}
                local id = tostring(message.id or newId()):sub(1, 64)
                local affected = MySQL.update.await([[
                    INSERT IGNORE INTO phone_mail_messages
                        (account_email, id, folder, from_name, from_email, recipients, subject,
                         body, sent_at, read_flag, flagged, attachments)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ]], {
                    accounts[i].email,
                    id,
                    tostring(message.folder or 'inbox'):sub(1, 16),
                    tostring(from.name or ''):sub(1, 64),
                    tostring(from.email or ''):sub(1, 128),
                    encodeJson(message.to),
                    tostring(message.subject or ''):sub(1, 255),
                    tostring(message.body or ''):sub(1, MAX_MESSAGE_BODY),
                    tostring(message.sentAt or ''):sub(1, 32),
                    message.read == true and 1 or 0,
                    message.flagged == true and 1 or 0,
                    encodeAttachments(message.attachments),
                })
                copied = copied + (tonumber(affected) or 0)
            end
        end
        pruneAccount(accounts[i].email)
        MySQL.update.await("UPDATE phone_mail_accounts SET messages = '[]' WHERE email = ?", { accounts[i].email })
    end
    return { accounts = #accounts, messages = copied }
end
store.reconcileMessages = reconcileMessages

---Creates normalized Mail storage and migrates both legacy JSON arrays idempotently.
function store.ensureSchema()
    util.rescueLegacyTable('phone_mail_accounts', 'password_hash')
    -- lb-phone uses this exact table name with a recipient/sender/content shape. IF NOT EXISTS
    -- cannot distinguish that table from ours, so move it aside before creating normalized rows.
    -- Without this guard the first later query for account_email fails during bootstrap.
    util.rescueLegacyTable('phone_mail_messages', 'account_email')

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS phone_mail_accounts (
            email              VARCHAR(64)  NOT NULL,
            password_hash      VARCHAR(255) NOT NULL,
            display_name       VARCHAR(64)  NOT NULL,
            messages           JSON         NOT NULL,
            logged_in_citizens JSON         NOT NULL,
            created_by_cid     VARCHAR(64)  NULL,
            created_at         TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (email),
            INDEX idx_phone_mail_accounts_creator (created_by_cid)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])
    util.ensureColumns('phone_mail_accounts', {
        display_name = "display_name VARCHAR(64) NOT NULL DEFAULT ''",
        messages = 'messages JSON NULL',
        logged_in_citizens = 'logged_in_citizens JSON NULL',
        created_by_cid = 'created_by_cid VARCHAR(64) NULL',
        created_at = 'created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP',
    })
    util.ensureColumnWidth('phone_mail_accounts', 'password_hash', 'password_hash VARCHAR(255) NOT NULL', 255)
    util.ensureIndex('phone_mail_accounts', 'idx_phone_mail_accounts_creator', '(created_by_cid)')
    util.ensureCollation('phone_mail_accounts')

    util.ensureTable('phone_mail_sessions', 'citizenid', [[
        CREATE TABLE IF NOT EXISTS phone_mail_sessions (
            citizenid VARCHAR(64) NOT NULL,
            email     VARCHAR(64) NOT NULL,
            PRIMARY KEY (citizenid, email),
            INDEX idx_phone_mail_sessions_email (email)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS phone_mail_messages (
            seq           BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
            account_email VARCHAR(64)      NOT NULL,
            id            VARCHAR(64)      NOT NULL,
            folder        VARCHAR(16)      NOT NULL,
            from_name     VARCHAR(64)      NOT NULL,
            from_email    VARCHAR(128)     NOT NULL,
            recipients    JSON             NOT NULL,
            subject       VARCHAR(255)     NOT NULL,
            body          MEDIUMTEXT       NOT NULL,
            sent_at       VARCHAR(32)      NOT NULL,
            read_flag     TINYINT(1)       NOT NULL DEFAULT 0,
            flagged       TINYINT(1)       NOT NULL DEFAULT 0,
            attachments   JSON             NULL,
            created_at    TIMESTAMP        NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (seq),
            UNIQUE KEY uq_mail_message_account_id (account_email, id),
            INDEX idx_mail_messages_account_seq (account_email, seq),
            INDEX idx_mail_messages_unread (account_email, folder, read_flag)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])

    util.ensureTable('phone_mail_saved_emails', 'citizenid', [[
        CREATE TABLE IF NOT EXISTS phone_mail_saved_emails (
            citizenid  VARCHAR(64)  NOT NULL,
            email      VARCHAR(128) NOT NULL,
            declined   TINYINT(1)   NOT NULL DEFAULT 0,
            created_at TIMESTAMP    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            PRIMARY KEY (citizenid, email)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])
    util.ensureColumns('phone_mail_saved_emails', {
        declined = 'declined TINYINT(1) NOT NULL DEFAULT 0',
    })

    local added = reconcileSessions()
    -- v1 could be stamped on a foreign-shaped phone_mail_messages table when every legacy account
    -- happened to have an empty messages array. Use fresh markers after adding shape rescue so a
    -- server that experienced that partial boot still performs the real migration and retention.
    util.runOnce('mail_messages_normalized_v2', reconcileMessages)
    util.runOnce('mail_messages_retention_v2', function()
        local rows = MySQL.query.await('SELECT DISTINCT account_email AS email FROM phone_mail_messages') or {}
        local removed = 0
        for i = 1, #rows do removed = removed + pruneAccount(rows[i].email) end
        return { accounts = #rows, removed = removed, cap = MESSAGE_RETENTION }
    end)

    util.ensureForeignKey('phone_mail_sessions', 'email', 'phone_mail_accounts', 'email', 'fk_mail_sessions_account')
    util.ensureForeignKey('phone_mail_messages', 'account_email', 'phone_mail_accounts', 'email', 'fk_mail_messages_account')
    if added > 0 then
        print(('^3[sd-phone]^0 migrated %d Mail session(s) out of JSON'):format(added))
    end
end

---@param email string
---@return boolean
function store.accountExists(email)
    if type(email) ~= 'string' or email == '' then return false end
    return MySQL.scalar.await('SELECT 1 FROM phone_mail_accounts WHERE email = ? LIMIT 1', { email }) ~= nil
end

---@param email string
---@return table|nil
function store.getAccount(email)
    if type(email) ~= 'string' or email == '' then return nil end
    local row = MySQL.single.await([[
        SELECT email, password_hash, display_name
        FROM phone_mail_accounts WHERE email = ?
    ]], { email })
    if not row then return nil end
    return hydrateAccounts({ row }, true)[1]
end

---Loads account identity and sessions but not message bodies.
---@param email string
---@return table|nil
function store.getAccountHeader(email)
    if type(email) ~= 'string' or email == '' then return nil end
    local row = MySQL.single.await([[
        SELECT email, password_hash, display_name
        FROM phone_mail_accounts WHERE email = ?
    ]], { email })
    if not row then return nil end
    return hydrateAccounts({ row }, false)[1]
end

---Loads several account identities and their sessions in two indexed queries total.
---@param emails string[]
---@return table<string, table> accounts keyed by email
function store.getAccountHeaders(emails)
    local seen, marks, params = {}, {}, {}
    for i = 1, #(emails or {}) do
        local email = emails[i]
        if type(email) == 'string' and email ~= '' and not seen[email] then
            seen[email] = true
            marks[#marks + 1] = '?'
            params[#params + 1] = email
        end
    end
    if #marks == 0 then return {} end
    local rows = MySQL.query.await(([[
        SELECT email, password_hash, display_name
        FROM phone_mail_accounts
        WHERE email IN (%s)
    ]]):format(table.concat(marks, ',')), params) or {}
    hydrateAccounts(rows, false)
    local out = {}
    for i = 1, #rows do out[rows[i].email] = rows[i] end
    return out
end

---@param email string
---@param messageId string
---@return table|nil
function store.getMessage(email, messageId)
    local row = MySQL.single.await([[
        SELECT account_email, id, folder, from_name, from_email, recipients, subject,
               LEFT(body, 10000) AS body,
               sent_at, read_flag, flagged, attachments, 1 AS loaded
        FROM phone_mail_messages
        WHERE account_email = ? AND id = ?
        LIMIT 1
    ]], { email, messageId })
    return row and hydrateMessage(row) or nil
end

---@param email string
---@param passwordHash string
---@param displayName string
---@param createdByCid string|nil
---@return boolean
function store.insertAccount(email, passwordHash, displayName, createdByCid)
    local ok, result = pcall(MySQL.update.await, [[
        INSERT INTO phone_mail_accounts
            (email, password_hash, display_name, messages, logged_in_citizens, created_by_cid)
        VALUES (?, ?, ?, '[]', '[]', ?)
    ]], { email, passwordHash, displayName, createdByCid })
    return ok and (tonumber(result) or 0) > 0
end

---@param citizenid string
---@return number
function store.countAccountsCreatedBy(citizenid)
    return tonumber(MySQL.scalar.await(
        'SELECT COUNT(*) FROM phone_mail_accounts WHERE created_by_cid = ?', { citizenid })) or 0
end

---@param email string
---@param citizenid string
---@return boolean
function store.addSession(email, citizenid)
    local affected = MySQL.update.await([[
        INSERT IGNORE INTO phone_mail_sessions (citizenid, email)
        SELECT ?, email FROM phone_mail_accounts WHERE email = ?
    ]], { citizenid, email })
    return (tonumber(affected) or 0) > 0 or store.hasSession(email, citizenid)
end

---@param email string
---@param citizenid string
---@return boolean
function store.hasSession(email, citizenid)
    return MySQL.scalar.await([[
        SELECT 1 FROM phone_mail_sessions WHERE citizenid = ? AND email = ? LIMIT 1
    ]], { citizenid, email }) ~= nil
end

---@param citizenid string
---@return number
function store.countSessionsForCitizen(citizenid)
    return tonumber(MySQL.scalar.await(
        'SELECT COUNT(*) FROM phone_mail_sessions WHERE citizenid = ?', { citizenid })) or 0
end

---@param email string
---@param citizenid string
---@return boolean
function store.removeSession(email, citizenid)
    local affected = MySQL.update.await(
        'DELETE FROM phone_mail_sessions WHERE citizenid = ? AND email = ?',
        { citizenid, email })
    return (tonumber(affected) or 0) > 0
end

---Returns only mailbox identity for lightweight ownership, picker and export paths. This must not
---hydrate messages: every social-app auth screen calls it to offer recovery-email choices.
---@param citizenid string
---@return { email: string, display_name: string }[]
function store.listAccountsForCitizen(citizenid)
    return MySQL.query.await(([[
        SELECT a.email, a.display_name
        FROM phone_mail_sessions s
        JOIN phone_mail_accounts a ON a.email = s.email
        WHERE s.citizenid = ?
        ORDER BY a.created_at ASC
        LIMIT %d
    ]]):format(ACCOUNT_LIST_CAP), { citizenid }) or {}
end

---Returns mailbox identity plus bounded message previews for the Mail app's initial list. Full
---bodies and attachments stay behind getMessage() and are fetched only when a row is opened.
---@param citizenid string
---@return table[]
function store.listAccountsWithMessagesForCitizen(citizenid)
    local rows = MySQL.query.await(([[
        SELECT a.email, a.display_name
        FROM phone_mail_sessions s
        JOIN phone_mail_accounts a ON a.email = s.email
        WHERE s.citizenid = ?
        ORDER BY a.created_at ASC
        LIMIT %d
    ]]):format(ACCOUNT_LIST_CAP), { citizenid }) or {}
    return hydrateAccounts(rows, 'summary')
end

---@param email string
---@param message table
---@param maxRetained number
---@return boolean
function store.appendMessage(email, message, maxRetained)
    local from = type(message.from) == 'table' and message.from or {}
    local ok, affected = pcall(MySQL.update.await, [[
        INSERT INTO phone_mail_messages
            (account_email, id, folder, from_name, from_email, recipients, subject, body,
             sent_at, read_flag, flagged, attachments)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]], {
        email,
        tostring(message.id or newId()):sub(1, 64),
        tostring(message.folder or 'inbox'):sub(1, 16),
        tostring(from.name or ''):sub(1, 64),
        tostring(from.email or ''):sub(1, 128),
        encodeJson(message.to),
        tostring(message.subject or ''):sub(1, 255),
        tostring(message.body or ''):sub(1, MAX_MESSAGE_BODY),
        tostring(message.sentAt or ''):sub(1, 32),
        message.read == true and 1 or 0,
        message.flagged == true and 1 or 0,
        encodeAttachments(message.attachments),
    })
    if not ok or (tonumber(affected) or 0) == 0 then return false end

    pruneAccount(email, maxRetained)
    return true
end

---@param email string
---@param messageId string
---@param apply fun(msg: table): table|nil
---@return boolean
function store.mutateMessage(email, messageId, apply)
    local row = MySQL.single.await([[
        SELECT account_email, id, folder, from_name, from_email, recipients, subject,
               LEFT(body, 10000) AS body,
               sent_at, read_flag, flagged, attachments
        FROM phone_mail_messages
        WHERE account_email = ? AND id = ?
    ]], { email, messageId })
    if not row then return false end
    local message = apply(hydrateMessage(row))
    if message == nil then
        return (tonumber(MySQL.update.await(
            'DELETE FROM phone_mail_messages WHERE account_email = ? AND id = ?',
            { email, messageId })) or 0) > 0
    end

    local from = type(message.from) == 'table' and message.from or {}
    local affected = MySQL.update.await([[
        UPDATE phone_mail_messages
        SET folder = ?, from_name = ?, from_email = ?, recipients = ?, subject = ?, body = ?,
            sent_at = ?, read_flag = ?, flagged = ?, attachments = ?
        WHERE account_email = ? AND id = ?
    ]], {
        tostring(message.folder or 'inbox'):sub(1, 16),
        tostring(from.name or ''):sub(1, 64),
        tostring(from.email or ''):sub(1, 128),
        encodeJson(message.to),
        tostring(message.subject or ''):sub(1, 255),
        tostring(message.body or ''):sub(1, MAX_MESSAGE_BODY),
        tostring(message.sentAt or ''):sub(1, 32),
        message.read == true and 1 or 0,
        message.flagged == true and 1 or 0,
        encodeAttachments(message.attachments),
        email,
        messageId,
    })
    return (tonumber(affected) or 0) > 0
end

---@param email string
---@param ids string[]
---@return number
function store.markManyRead(email, ids)
    local marks, params, seen = {}, { email }, {}
    for i = 1, #ids do
        local id = ids[i]
        if type(id) == 'string' and id ~= '' and not seen[id] then
            seen[id] = true
            marks[#marks + 1] = '?'
            params[#params + 1] = id
        end
    end
    if #marks == 0 then return 0 end
    return tonumber(MySQL.update.await(([[
        UPDATE phone_mail_messages
        SET read_flag = 1
        WHERE account_email = ? AND read_flag = 0 AND id IN (%s)
    ]]):format(table.concat(marks, ',')), params)) or 0
end

---@param email string
---@param passwordHash string
function store.setPasswordHash(email, passwordHash)
    MySQL.update.await(
        'UPDATE phone_mail_accounts SET password_hash = ? WHERE email = ?',
        { passwordHash, email })
end

---@param email string
function store.deleteAccount(email)
    if type(email) ~= 'string' or email == '' then return end
    MySQL.update.await('DELETE FROM phone_mail_accounts WHERE email = ?', { email })
end

---@param citizenid string
---@return number
function store.unreadCount(citizenid)
    return tonumber(MySQL.scalar.await([[
        SELECT COUNT(*)
        FROM phone_mail_sessions s
        JOIN phone_mail_messages m ON m.account_email = s.email
        WHERE s.citizenid = ? AND m.folder = 'inbox' AND m.read_flag = 0
    ]], { citizenid })) or 0
end

---@param citizenid string
---@return string[]
function store.listSavedEmails(citizenid)
    local rows = MySQL.query.await([[
        SELECT email FROM phone_mail_saved_emails
        WHERE citizenid = ? AND declined = 0
        ORDER BY created_at ASC, email ASC
        LIMIT 200
    ]], { citizenid }) or {}
    local out = {}
    for i = 1, #rows do out[#out + 1] = rows[i].email end
    return out
end

---@param citizenid string
---@return string[]
function store.listDeclinedEmails(citizenid)
    local rows = MySQL.query.await([[
        SELECT email FROM phone_mail_saved_emails
        WHERE citizenid = ? AND declined = 1
        ORDER BY created_at ASC, email ASC
        LIMIT 200
    ]], { citizenid }) or {}
    local out = {}
    for i = 1, #rows do out[#out + 1] = rows[i].email end
    return out
end

---@param citizenid string
---@param email string
---@param maxSaved integer
---@return boolean
function store.addSavedEmail(citizenid, email, maxSaved)
    local count = tonumber(MySQL.scalar.await(
        'SELECT COUNT(*) FROM phone_mail_saved_emails WHERE citizenid = ? AND declined = 0',
        { citizenid })) or 0
    if count >= maxSaved then return false end
    MySQL.update.await([[
        INSERT INTO phone_mail_saved_emails (citizenid, email, declined) VALUES (?, ?, 0)
        ON DUPLICATE KEY UPDATE declined = 0
    ]], { citizenid, email })
    return true
end

---@param citizenid string
---@param email string
function store.declineSavedEmail(citizenid, email)
    local exists = MySQL.scalar.await([[
        SELECT 1 FROM phone_mail_saved_emails
        WHERE citizenid = ? AND email = ? LIMIT 1
    ]], { citizenid, email }) ~= nil
    if not exists then
        local count = tonumber(MySQL.scalar.await(
            'SELECT COUNT(*) FROM phone_mail_saved_emails WHERE citizenid = ?', { citizenid })) or 0
        if count >= SAVED_EMAIL_LIST_CAP then return false end
    end
    local affected = MySQL.update.await([[
        INSERT IGNORE INTO phone_mail_saved_emails (citizenid, email, declined) VALUES (?, ?, 1)
    ]], { citizenid, email })
    return exists or (tonumber(affected) or 0) > 0
end

---@param citizenid string
---@param email string
function store.removeSavedEmail(citizenid, email)
    MySQL.update.await(
        'DELETE FROM phone_mail_saved_emails WHERE citizenid = ? AND email = ?',
        { citizenid, email })
end

return store
