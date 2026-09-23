---@type table Gate evaluator (server.gates): reads the `requires` spec both app catalogs share.
local gates  = require 'server.gates'

---@type table App gate; the table returned at end of file. Answers one question for the client:
---which apps must NOT appear on this player's home screen right now.
---
---configs/apps.lua decides which apps a SERVER has. This decides which of them a PLAYER can see,
---and it exists because the answer changes with the job they are holding. The client has no job
---awareness of its own, so it asks on every open and gets the answer for the character that is
---actually loaded.
---
---The answer comes from any `requires` an app entry carries, which server.gates evaluates.
local appgate = {}

---Every app id this player must not be shown.
---@param src integer player server id
---@return string[] ids
function appgate.hidden(src)
    local out = {}

    -- Anything an entry gates for itself.
    for _, id in ipairs(gates.hiddenBaseApps(src)) do
        out[#out + 1] = id
    end

    table.sort(out)
    return out
end

---The client asks on every open, so a job change between opens is picked up with no event to miss.
---Deliberately ungated: a civilian is a valid caller and gets the full hidden list back.
lib.callback.register('sd-phone:server:apps:hidden', function(src)
    return appgate.hidden(src)
end)

return appgate
