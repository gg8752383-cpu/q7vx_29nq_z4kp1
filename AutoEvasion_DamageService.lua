local ServerScriptService = game:GetService("ServerScriptService")

local damageGate = require(
    ServerScriptService:WaitForChild("AutoEvasionDamageGate")
)

local DamageService = {}

function DamageService.ApplyDamage(target, amount)
    if typeof(target) ~= "Instance" or not target:IsA("Humanoid") then
        return false, "InvalidTarget"
    end

    if typeof(amount) ~= "number"
        or amount ~= amount
        or amount <= 0
        or amount == math.huge then
        return false, "InvalidAmount"
    end

    if target.Health <= 0 then
        return false, "TargetDead"
    end

    if damageGate.IsProtected(target) then
        return false, "IFrames"
    end

    target:TakeDamage(amount)
    return true, "Applied"
end

return DamageService
