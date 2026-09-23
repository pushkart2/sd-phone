---@type table Shared schema-maintenance queue (server.util).
local util = require 'server.util'
local boot = require 'server.boot'

-- Increment this when a release adds schema work that must be applied to already-validated servers.
local SCHEMA_VERSION = 1
local INSTALL_VERSION = 1
local VALIDATION_KEY = 'sd-phone'
local running = false
local validatedVersion

---@param message string
local function log(message)
    print(('^6[sd-phone:schema]^0 %s'):format(message))
end

local function ensureValidationTable()
    local exists, result = pcall(MySQL.scalar.await,
        'SELECT 1 FROM phone_schema_validation WHERE validation_key = ? LIMIT 1', { VALIDATION_KEY })
    if exists then return result end

    MySQL.query.await([[
        CREATE TABLE IF NOT EXISTS phone_schema_validation (
            validation_key VARCHAR(64) NOT NULL,
            schema_version INT UNSIGNED NOT NULL,
            validated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
            operations_completed INT UNSIGNED NOT NULL DEFAULT 0,
            imported TINYINT(1) NOT NULL DEFAULT 0,
            PRIMARY KEY (validation_key)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
    ]])
end

local function saveImportedMarker()
    MySQL.query.await([[
        INSERT INTO phone_schema_validation
            (validation_key, schema_version, operations_completed, imported)
        VALUES (?, ?, 0, 1)
        ON DUPLICATE KEY UPDATE imported = 1, schema_version = VALUES(schema_version)
    ]], { VALIDATION_KEY, INSTALL_VERSION })
end

local function runValidation(force)
    if running then
        log('^3maintenance is already running.^0')
        return
    end

    running = true
    CreateThread(function()
        local registryOk, registryErr = pcall(ensureValidationTable)
        if not registryOk then
            running = false
            log(('^1could not access validation registry:^0 %s'):format(tostring(registryErr)))
            return
        end

        local storedVersion = tonumber(MySQL.scalar.await(
            'SELECT schema_version FROM phone_schema_validation WHERE validation_key = ? LIMIT 1',
            { VALIDATION_KEY }))
        validatedVersion = storedVersion
        if not force and storedVersion == SCHEMA_VERSION and util.schemaTaskCount() == 0 then
            running = false
            if not boot.hasSchemaFailures() then
                local saved, saveErr = pcall(saveImportedMarker)
                if not saved then
                    log(('^1could not save imported marker:^0 %s'):format(tostring(saveErr)))
                    return
                end
            end
            log(('schema already validated at version %d; skipping catalogue checks.'):format(SCHEMA_VERSION))
            return
        end

        local startedAt = GetGameTimer()
        log(('running %d queued schema operation(s)...'):format(util.schemaTaskCount()))
        local ok, result = pcall(util.runSchemaMaintenance)
        running = false
        if not ok then
            log(('^1maintenance aborted:^0 %s'):format(tostring(result)))
            return
        end

        local elapsed = (GetGameTimer() - startedAt) / 1000
        log(('finished in %.1fs: %d completed, %d failed, %d warning(s).'):format(
            elapsed, result.completed, result.failed, result.warnings or 0))
        for i = 1, #result.failures do
            log(('^1FAILED^0 %s'):format(result.failures[i]))
        end

        if result.failed ~= 0 or (result.warnings or 0) ~= 0 or boot.hasSchemaFailures() then
            log('^3validation marker was not saved; checks will run again next start.^0')
            return
        end

        local saved, saveResult = pcall(MySQL.update.await, [[
            INSERT INTO phone_schema_validation
                (validation_key, schema_version, operations_completed)
            VALUES (?, ?, ?)
            ON DUPLICATE KEY UPDATE schema_version = VALUES(schema_version),
                validated_at = CURRENT_TIMESTAMP, operations_completed = VALUES(operations_completed)
        ]], { VALIDATION_KEY, SCHEMA_VERSION, result.completed })
        if not saved then
            log(('^1schema is ready but validation marker could not be saved:^0 %s'):format(tostring(saveResult)))
            return
        end

        validatedVersion = SCHEMA_VERSION
        local imported, importErr = pcall(saveImportedMarker)
        if not imported then
            log(('^1schema validated but imported marker could not be saved:^0 %s'):format(tostring(importErr)))
            return
        end
        log(('schema is ready; version %d saved. Future restarts will skip catalogue checks.')
            :format(SCHEMA_VERSION))
    end)
end

-- Inspect or explicitly rerun schema checks from the server console. "force" bypasses the marker.
RegisterCommand('sdphone:schema', function(source, args)
    if source ~= 0 then return end
    local action = (args[1] or ''):lower()
    if action == 'status' then
        log(('%d maintenance operation(s) queued; validated version: %s.')
            :format(util.schemaTaskCount(), validatedVersion and tostring(validatedVersion) or 'unknown'))
        return
    end
    runValidation(action == 'force')
end, true)

-- Store bootstraps register maintenance tasks asynchronously. Wait until the boot reporter sees a
-- quiet period, ensuring the automatic first-run validation executes the complete queue.
CreateThread(function()
    while not boot.isSchemaSettled() do Wait(250) end
    runValidation(false)
end)

return {}
