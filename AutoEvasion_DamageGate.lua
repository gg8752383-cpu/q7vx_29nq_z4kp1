local Workspace = game:GetService("Workspace")

local AutoEvasionDamageGate = {}

function AutoEvasionDamageGate.IsProtected(target)
    if typeof(target) ~= "Instance" then
        return false
    end

    local character
    if target:IsA("Humanoid") then
        character = target.Parent
    elseif target:IsA("Model") then
        character = target
    else
        character = target:FindFirstAncestorOfClass("Model")
    end

    if not character or not character:IsA("Model") then
        return false
    end

    if character:GetAttribute("CombatIFrames") == true then
        return true
    end

    local protectedUntil = character:GetAttribute("CombatIFramesUntil")
    if typeof(protectedUntil) == "number"
        and protectedUntil > Workspace:GetServerTimeNow() then
        return true
    end

    return false
end

return AutoEvasionDamageGate
