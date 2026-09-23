---@type table Framework detection (bridge.shared.framework): name ('qb'|'esx') + live core handle.
local framework = require 'bridge.shared.framework'
---@type table Money bridge (bridge.server.money): framework personal-account operations.
local money     = require 'bridge.server.money'
---@type table Player bridge (bridge.server.player): citizenid/identifier lookups from src.
---
---Identity here is ALWAYS read with getRealIdentifier, never getIdentifier: under unique phones
---(configs/uniqueandsim.lua) that one is rewrapped to return the acting SIM identity, and the
---resources called below key their records by citizenid.
local player    = require 'bridge.server.player'

---@type table Banking module; the table returned at end of file. Multi-banking adapter: reads and
---moves a player's personal bank balance through a dedicated provider path where one exists, else
---the framework bank account.
local banking = {}

-- Dedicated-path export shapes:
--   wasabi_banking : AddMoney/RemoveMoney/GetAccountBalance(identifier, amount, reason)
--   omes_banking   : AddBankMoney/RemoveBankMoney/GetBankBalance(source, amount, desc)
--   prism_banking  : AddBankingTransaction(source, type, amount, spendType, tax, name, desc)
--   tgg-banking    : GetPersonalAccountByPlayerId(source).balance (read only)
---@type string[] Banking resources, in detection-priority order.
local KNOWN = {
    'wasabi_banking', 'omes_banking', 'prism_banking', 'tgg-banking', 'okokBanking',
    'Renewed-Banking', 'qb-banking', 'esx_banking', 'qs-banking', 'fd_banking',
    'new_banking', 'ps-banking',
}

---@type table<string, boolean> Resources that store the personal balance in their own tables.
local OWN_TABLE = {
    wasabi_banking = true, omes_banking = true, okokBanking = true, ['tgg-banking'] = true,
    prism_banking  = true, fd_banking  = true,
}

---@type boolean, string|nil Detection-ran flag + cached provider name (nil = framework account).
local resolved, providerName = false, nil

---The active banking resource, resolved lazily and cached on first use. Nil when none is
---started; every operation then uses the framework bank account directly.
---@return string|nil
local function provider()
    if not resolved then
        for _, name in ipairs(KNOWN) do
            if GetResourceState(name) == 'started' then providerName = name; break end
        end
        resolved = true
        print(('^2[sd-phone:banking]^0 banking provider: ^3%s^0'):format(providerName or 'framework account'))
    end
    return providerName
end

-- `banking.name` reads through the lazy resolver.
setmetatable(banking, { __index = function(_, k) if k == 'name' then return provider() end end })

---True when the player's bank balance is the framework account; false for OWN_TABLE resources.
---@return boolean
function banking.balanceIsFramework()
    local name = provider()
    return not (name and OWN_TABLE[name])
end

---Runs a provider export call. False when the call errored or the provider returned false.
---@param fn function
---@return boolean
local function try(fn)
    local ok, res = pcall(fn)
    return ok and res ~= false
end

---The player's current bank balance. Read-only. Own-table providers are read through their
---exports; a failed own-ledger read returns zero rather than silently switching ledgers.
---@param src number
---@return number
function banking.getBalance(src)
    local name = banking.name
    if name == 'wasabi_banking' then
        local id = player.getRealIdentifier(src)
        if id then
            local ok, bal = pcall(function() return exports.wasabi_banking:GetAccountBalance(id) end)
            if ok and type(bal) == 'number' then return bal end
        end
    elseif name == 'omes_banking' then
        local ok, bal = pcall(function() return exports['omes_banking']:GetBankBalance(src) end)
        if ok and type(bal) == 'number' then return bal end
    elseif name == 'tgg-banking' then
        local ok, acc = pcall(function() return exports['tgg-banking']:GetPersonalAccountByPlayerId(src) end)
        if ok and type(acc) == 'table' and type(acc.balance) == 'number' then return acc.balance end
    elseif name == 'prism_banking' then
        local ok, accs = pcall(function() return exports['prism_banking']:GetBankAccounts(src) end)
        if ok and type(accs) == 'table' then
            for _, a in pairs(accs) do
                if type(a) == 'table' and type(a.balance) == 'number' then return a.balance end
            end
        end
    end
    -- Never read a different ledger after an own-table adapter failed. Returning the framework
    -- balance here made the UI display spendable money that the active provider did not own.
    if name and OWN_TABLE[name] then return 0 end
    return money.get(src, 'bank')
end

---@type table<number, { amount: number, minus: boolean, expires: number }[]> Phone-initiated
---movements awaiting their framework echo, so the generic Wallet logger can skip them.
local expected = {}

---Registers a movement about to hit the player's bank account.
---@param src number
---@param amount number
---@param minus boolean
local function expect(src, amount, minus)
    local list = expected[src]
    if not list then list = {} expected[src] = list end
    list[#list + 1] = { amount = math.floor(tonumber(amount) or 0), minus = minus, expires = GetGameTimer() + 3000 }
end

---Withdraws a registration made by `expect` when the announced movement never happened.
---@param src number
---@param amount number
---@param minus boolean
local function unexpect(src, amount, minus)
    local list = expected[src]
    if not list then return end
    local want = math.floor(tonumber(amount) or 0)
    for i = #list, 1, -1 do
        if list[i].amount == want and list[i].minus == minus then
            table.remove(list, i)
            return
        end
    end
end

---Consumes one matching expected movement; false means the change came from another script.
---@param src number
---@param amount number
---@param minus boolean
---@return boolean consumed
function banking.consumeExpected(src, amount, minus)
    local list = expected[src]
    if not list then return false end
    local now = GetGameTimer()
    for i = #list, 1, -1 do
        if list[i].expires < now then
            table.remove(list, i)
        elseif list[i].amount == amount and list[i].minus == minus then
            table.remove(list, i)
            return true
        end
    end
    return false
end

---@type table<number, boolean> Serializes balance-check + debit per live player.
local accountLocks = {}

---@param src number
---@param fn fun(): boolean
---@return boolean
local function withAccountLock(src, fn)
    if accountLocks[src] then return false end
    accountLocks[src] = true
    local ok, result = xpcall(fn, debug.traceback)
    accountLocks[src] = nil
    if not ok then
        print(('^1[sd-phone:banking]^0 account operation failed: %s'):format(result))
        return false
    end
    return result == true
end

AddEventHandler('playerDropped', function()
    accountLocks[source] = nil
    expected[source] = nil
end)

---@param src number
---@param amount number
---@param reason string
---@return boolean attempted, boolean succeeded
local function providerAdd(src, amount, reason)
    local name = banking.name
    if name == 'wasabi_banking' then
        local id = player.getIdentifier(src)
        return true, id ~= nil and try(function()
            return exports.wasabi_banking:AddMoney(id, amount, reason)
        end)
    elseif name == 'omes_banking' then
        return true, try(function()
            return exports['omes_banking']:AddBankMoney(src, amount, reason)
        end)
    elseif name == 'prism_banking' then
        return true, try(function()
            return exports['prism_banking']:AddBankingTransaction(
                src, 'deposit', amount, 'phone', false, reason, reason)
        end)
    end
    return name ~= nil and OWN_TABLE[name] == true, false
end

---@param src number
---@param amount number
---@param reason string
---@return boolean attempted, boolean succeeded
local function providerRemove(src, amount, reason)
    local name = banking.name
    if name == 'wasabi_banking' then
        local id = player.getRealIdentifier(src)
        return true, id ~= nil and try(function()
            return exports.wasabi_banking:RemoveMoney(id, amount, reason)
        end)
    elseif name == 'omes_banking' then
        return true, try(function()
            return exports['omes_banking']:RemoveBankMoney(src, amount, reason)
        end)
    elseif name == 'prism_banking' then
        return true, try(function()
            return exports['prism_banking']:AddBankingTransaction(
                src, 'withdraw', amount, 'phone', false, reason, reason)
        end)
    end
    return name ~= nil and OWN_TABLE[name] == true, false
end

---Credit the player's bank account, falling back to the framework account when no provider path
---handles it. True when a path was taken without error.
---@param src number
---@param amount number
---@param reason? string
---@return boolean added
function banking.addMoney(src, amount, reason)
    amount = tonumber(amount)
    if not amount or amount ~= amount or amount == math.huge or amount == -math.huge then return false end
    amount = math.floor(amount)
    if amount <= 0 or amount > 2147483647 then return false end
    reason = reason or 'Phone transfer'

    return withAccountLock(src, function()
        expect(src, amount, false)
        local attempted, succeeded = providerAdd(src, amount, reason)
        if attempted then
            if not succeeded then unexpect(src, amount, false) end
            return succeeded
        end
        local added = money.add(src, 'bank', amount, reason)
        if not added then unexpect(src, amount, false) end
        return added
    end)
end

---Debit the player's bank account, re-reading the balance to confirm the money moved. True only
---when it left the account; callers must not credit anyone on a false.
---@param src number
---@param amount number
---@param reason? string
---@return boolean removed
function banking.removeMoney(src, amount, reason)
    amount = tonumber(amount)
    if not amount or amount ~= amount or amount == math.huge or amount == -math.huge then return false end
    amount = math.floor(amount)
    if amount <= 0 or amount > 2147483647 then return false end
    reason = reason or 'Phone transfer'

    return withAccountLock(src, function()
        local before = banking.getBalance(src) or 0
        if before < amount then return false end

        expect(src, amount, true)
        local attempted, succeeded = providerRemove(src, amount, reason)
        if attempted then
            if not succeeded or (banking.getBalance(src) or 0) > before - amount then
                unexpect(src, amount, true)
                return false
            end
            return true
        end

        if money.remove(src, 'bank', amount, reason) then return true end
        unexpect(src, amount, true)
        return false
    end)
end

---Best-effort credit to an offline character's framework bank account via a parameterized DB
---write against each framework's default schema. True only when a row was actually updated.
---@param citizenid string
---@param amount number
---@return boolean ok
function banking.addOffline(citizenid, amount)
    amount = tonumber(amount)
    if type(citizenid) ~= 'string' or citizenid == '' or not amount or amount ~= amount
        or amount == math.huge or amount == -math.huge then return false end
    amount = math.floor(amount)
    if amount <= 0 or amount > 2147483647 then return false end
    if framework.qb then
        local ok, affected = pcall(function()
            return MySQL.update.await(
                "UPDATE players SET money = JSON_SET(money, '$.bank', JSON_EXTRACT(money, '$.bank') + ?) WHERE citizenid = ?",
                { amount, citizenid })
        end)
        return ok and (tonumber(affected) or 0) > 0
    elseif framework.name == 'esx' then
        local ok, affected = pcall(function()
            return MySQL.update.await(
                "UPDATE users SET accounts = JSON_SET(accounts, '$.bank', JSON_EXTRACT(accounts, '$.bank') + ?) WHERE identifier = ?",
                { amount, citizenid })
        end)
        return ok and (tonumber(affected) or 0) > 0
    elseif framework.name == 'ox' then
        -- ox_core keeps balances in its own `accounts` table rather than on the character row;
        -- the character's default account is the one the phone treats as their bank.
        local ok, affected = pcall(function()
            return MySQL.update.await(
                'UPDATE accounts SET balance = balance + ? WHERE owner = ? AND isDefault = 1',
                { amount, tonumber(citizenid) })
        end)
        return ok and (tonumber(affected) or 0) > 0
    elseif framework.name == 'nd' then
        -- charid is an INT column, so the identifier has to go back to a number: passed as the
        -- string the phone carries it as, the row never matches and the credit silently vanishes.
        local ok, affected = pcall(function()
            return MySQL.update.await(
                'UPDATE nd_characters SET bank = bank + ? WHERE charid = ?',
                { amount, tonumber(citizenid) })
        end)
        return ok and (tonumber(affected) or 0) > 0
    end
    return false
end

---Best-effort: mirrors a phone transfer into the active banking resource's own transaction log.
---Failures are swallowed; providers without a personal-log export are skipped.
---@param src number
---@param label string
---@param amount number positive magnitude
---@param isCredit boolean
function banking.logToResource(src, label, amount, isCredit)
    local name = banking.name
    if name == 'esx_banking' then
        try(function() exports['esx_banking']:logTransaction(src, label, isCredit and 'DEPOSIT' or 'WITHDRAW', amount) end)
    elseif name == 'qb-banking' then
        local cid = player.getRealIdentifier(src)
        try(function() exports['qb-banking']:CreateBankStatement(src, cid, amount, label, isCredit and 'deposit' or 'withdraw', 'player') end)
    elseif name == 'okokBanking' then
        local cid = player.getRealIdentifier(src)
        try(function() exports['okokBanking']:AddTransaction(cid, { type = isCredit and 'deposit' or 'withdraw', amount = amount, reason = label }, src) end)
    elseif name == 'omes_banking' then
        try(function() exports['omes_banking']:LogCustomTransaction(src, isCredit and 'deposit' or 'withdraw', amount, label) end)
    end
end

return banking
