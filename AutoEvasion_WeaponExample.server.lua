-- Add this call to your EXISTING server-side weapon/attack damage handler.
-- Do not run this text file as a standalone Script.

local ServerScriptService = game:GetService("ServerScriptService")
local DamageService = require(
    ServerScriptService:WaitForChild("AutoEvasionDamageService")
)

-- Replace targetHumanoid and damageAmount with values from your attack system.
local applied, reason = DamageService.ApplyDamage(targetHumanoid, damageAmount)

if not applied and reason == "IFrames" then
    return -- The target's server-authoritative dodge iFrames blocked this hit.
end
