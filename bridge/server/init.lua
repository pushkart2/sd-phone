-- ox_lib has shipped multiple string-helper surfaces. Older installations expose `lib.string`
-- without startsWith, while sd-phone uses that helper in several independently loaded server
-- modules. Install the tiny compatibility operation before any app module is required so one old
-- ox_lib cannot turn an otherwise valid database row into a runtime crash.
local libString = lib.string
if type(libString) == 'table' and type(libString.startsWith) ~= 'function' then
    function libString.startsWith(value, prefix)
        return type(value) == 'string' and type(prefix) == 'string'
            and value:sub(1, #prefix) == prefix
    end
end

-- Loaded for side effects: eager-loads every server bridge module.
require 'bridge.server.player'
require 'bridge.server.notify'
require 'bridge.server.inventory'
require 'bridge.server.money'
require 'bridge.server.job'
require 'bridge.server.gang'
require 'bridge.server.version'
-- Detection modules, loaded here so they resolve once at boot rather than on first use.
require 'bridge.shared.framework'
require 'bridge.shared.inventory_id'
