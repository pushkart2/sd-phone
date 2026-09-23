---@type table Company inbox store module; the table returned at end of file.
local store = {}

---@type table Shared server helpers (server.util): id generation and idempotent indexes.
local util = require 'server.util'

---Creates the company-inbox tables: one flat message table keyed by (job, citizen_number) and a
---per-(viewer, thread) read-state table.
function store.ensureSchema()
    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS phone_service_messages (
            id             VARCHAR(64)  NOT NULL,
            job            VARCHAR(64)  NOT NULL,
            citizen_number VARCHAR(32)  NOT NULL,
            citizen_name   VARCHAR(128) DEFAULT NULL,
            sender         VARCHAR(8)   NOT NULL,          -- 'citizen' | 'staff'
            staff_cid      VARCHAR(64)  DEFAULT NULL,
            staff_name     VARCHAR(128) DEFAULT NULL,
            body           TEXT         NOT NULL,
            created_at     INT          NOT NULL,
            PRIMARY KEY (id),
            INDEX idx_job (job, citizen_number, created_at),
            INDEX idx_cit (citizen_number, created_at)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])
    util.ensureColumns('phone_service_messages', {
        kind = "kind VARCHAR(16) NOT NULL DEFAULT 'text'",
        meta = 'meta TEXT NULL',
    })

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS phone_service_msg_reads (
            viewer         VARCHAR(64) NOT NULL,
            job            VARCHAR(64) NOT NULL,
            citizen_number VARCHAR(32) NOT NULL,
            last_read      INT         NOT NULL DEFAULT 0,
            PRIMARY KEY (viewer, job, citizen_number)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci;
    ]])

    -- The original indexes could find a thread, but not the unread scans that filter by sender.
    -- Keep the lookup prefixes and add covering order for the two badge queries.
    util.ensureIndex('phone_service_messages', 'idx_service_job_sender',
        '(job, sender, created_at, citizen_number)')
    util.ensureIndex('phone_service_messages', 'idx_service_cit_sender',
        '(citizen_number, sender, created_at, job)')
end

local function newId() return util.newId(7) end
store.newId = newId

---Appends one message to a (job, citizen) thread.
---@param rec { id: string, job: string, citizenNumber: string, citizenName?: string, sender: string, staffCid?: string, staffName?: string, body: string, kind?: string, meta?: string, createdAt: number }
function store.insert(rec)
    MySQL.insert.await([[
        INSERT INTO phone_service_messages
            (id, job, citizen_number, citizen_name, sender, staff_cid, staff_name, body, kind, meta, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ]], {
        rec.id, rec.job, rec.citizenNumber, rec.citizenName,
        rec.sender, rec.staffCid, rec.staffName, rec.body,
        rec.kind or 'text', rec.meta, rec.createdAt,
    })
end

---Every message in a (job, citizen) thread, oldest first. Read-only.
---@param job string
---@param citizenNumber string
---@param limit? number row cap (default 100)
---@return table[]
function store.threadMessages(job, citizenNumber, limit)
    return MySQL.query.await([[
        SELECT id, sender, staff_cid, staff_name, citizen_name, body, kind, meta, created_at
        FROM (
            SELECT id, sender, staff_cid, staff_name, citizen_name, body, kind, meta, created_at
            FROM phone_service_messages
            WHERE job = ? AND citizen_number = ?
            ORDER BY created_at DESC, id DESC
            LIMIT ?
        ) recent
        ORDER BY created_at ASC, id ASC
    ]], { job, citizenNumber, limit or 100 }) or {}
end

---True when a (job, citizen) thread already has at least one message. Staff replies are gated on
---this: without it a client-chosen number mints a brand-new thread per call. Read-only.
---@param job string
---@param citizenNumber string
---@return boolean
function store.threadExists(job, citizenNumber)
    if not job or job == '' or not citizenNumber or citizenNumber == '' then return false end
    return MySQL.scalar.await(
        'SELECT 1 FROM phone_service_messages WHERE job = ? AND citizen_number = ? LIMIT 1',
        { job, citizenNumber }) ~= nil
end

---Distinct customer threads for a job (one row per customer, newest first), each carrying the
---latest body + the customer's most recent known display name. Read-only.
---@param job string
---@param limit? number thread cap (default 50)
---@return { citizen_number: string, citizen_name?: string, last_body?: string, created_at: number }[]
function store.jobThreads(job, limit)
    return MySQL.query.await([[
        SELECT citizen_number, latest_citizen_name AS citizen_name,
               LEFT(body, 240) AS last_body, created_at
        FROM (
            SELECT citizen_number, citizen_name, body, created_at,
                   FIRST_VALUE(citizen_name) OVER (
                       PARTITION BY citizen_number
                       ORDER BY (citizen_name IS NULL OR citizen_name = '') ASC,
                                created_at DESC, id DESC
                   ) AS latest_citizen_name,
                   ROW_NUMBER() OVER (
                       PARTITION BY citizen_number ORDER BY created_at DESC, id DESC
                   ) AS row_num
            FROM phone_service_messages
            WHERE job = ?
        ) ranked
        WHERE row_num = 1
        ORDER BY created_at DESC
        LIMIT ?
    ]], { job, limit or 50 }) or {}
end

---Marks a (viewer, job, citizen) thread read up to `ts`; the stored timestamp never moves
---backwards.
---@param viewer string
---@param job string
---@param citizenNumber string
---@param ts number
function store.markRead(viewer, job, citizenNumber, ts)
    if not viewer or viewer == '' or not job or job == '' or not citizenNumber or citizenNumber == '' then return end
    MySQL.update.await([[
        INSERT INTO phone_service_msg_reads (viewer, job, citizen_number, last_read) VALUES (?, ?, ?, ?)
        ON DUPLICATE KEY UPDATE last_read = GREATEST(last_read, VALUES(last_read))
    ]], { viewer, job, citizenNumber, ts or 0 })
end

---Unread customer messages per thread for a STAFF viewer of `job` (citizen_number -> count).
---Only counts messages from the customer side. Read-only.
---@param viewer string
---@param job string
---@return table<string, number>
function store.jobUnread(viewer, job)
    local rows = MySQL.query.await([[
        SELECT m.citizen_number AS k, COUNT(*) AS unread
        FROM phone_service_messages m
        LEFT JOIN phone_service_msg_reads r
            ON r.viewer = ? AND r.job = m.job AND r.citizen_number = m.citizen_number
        WHERE m.job = ? AND m.sender = 'citizen' AND m.created_at > COALESCE(r.last_read, 0)
        GROUP BY m.citizen_number
    ]], { viewer, job }) or {}
    local map = {}
    for _, row in ipairs(rows) do map[row.k] = tonumber(row.unread) or 0 end
    return map
end

---Unread company replies per thread for a CUSTOMER viewer (job -> count). Only counts messages
---from the staff side. Read-only.
---@param viewer string
---@param citizenNumber string
---@return table<string, number>
function store.personalUnread(viewer, citizenNumber)
    local rows = MySQL.query.await([[
        SELECT m.job AS k, COUNT(*) AS unread
        FROM phone_service_messages m
        LEFT JOIN phone_service_msg_reads r
            ON r.viewer = ? AND r.job = m.job AND r.citizen_number = m.citizen_number
        WHERE m.citizen_number = ? AND m.sender = 'staff' AND m.created_at > COALESCE(r.last_read, 0)
        GROUP BY m.job
    ]], { viewer, citizenNumber }) or {}
    local map = {}
    for _, row in ipairs(rows) do map[row.k] = tonumber(row.unread) or 0 end
    return map
end

---Distinct company threads for a customer (one row per job, newest first), each carrying the
---latest body. Read-only.
---@param citizenNumber string
---@param limit? number thread cap (default 50)
---@return { job: string, last_body?: string, created_at: number }[]
function store.citizenThreads(citizenNumber, limit)
    return MySQL.query.await([[
        SELECT job, LEFT(body, 240) AS last_body, created_at
        FROM (
            SELECT job, body, created_at,
                   ROW_NUMBER() OVER (PARTITION BY job ORDER BY created_at DESC, id DESC) AS row_num
            FROM phone_service_messages
            WHERE citizen_number = ?
        ) ranked
        WHERE row_num = 1
        ORDER BY created_at DESC
        LIMIT ?
    ]], { citizenNumber, limit or 50 }) or {}
end

return store
