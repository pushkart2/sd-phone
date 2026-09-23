-- Casino NUI callbacks share this one bridge into their server modules.
---@type string[] NUI action suffixes proxied 1:1 to sd-phone:server:games:<action>.
local ACTIONS = {
    'stats', 'record', 'leaderboard', 'submitScore', 'scoreboard',
    'chipsGet', 'chipsBuy', 'chipsSell',
    'bjDeal', 'bjHit', 'bjStand', 'bjDouble',
    'slotsSpin', 'rouletteSpin',
    'baccaratDeal',
    -- No crashWatch here: the subscription is gated on the phone being open, and that gate lives in
    -- client/apps/casino.lua. A second ungated route would just overwrite it.
    'crashBet', 'crashCashout',
    'holdemTables', 'holdemCreate', 'holdemSit', 'holdemLeave', 'holdemAct', 'holdemSync',
}

-- Thin delegates into the registered casino server callbacks.
for _, name in ipairs(ACTIONS) do
    RegisterNUICallback('sd-phone:games:' .. name, function(payload, cb)
        local result = lib.callback.await('sd-phone:server:games:' .. name, false, payload)
        cb(result or { success = false, message = 'No response from server' })
    end)
end
