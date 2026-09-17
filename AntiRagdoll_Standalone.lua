-- VGD Anti-Ragdoll - Standalone Universal Module
-- Client-side protection against common Roblox ragdoll / knockdown states.
-- Direct execution auto-enables; the GUI can set _G.VGD_AntiRagdoll_GUIControlled = true
-- before loading so it starts disabled and can control it through the API.
--
-- Designed as a separate module first so it can be tested safely before being
-- folded into AntiFling. It avoids deleting character objects blindly.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local player = Players.LocalPlayer

local enabled = false
local renderConnection = nil
local characterConnection = nil
local descendantConnection = nil
local stateChangedConnection = nil

local savedStates = {}
local watchedCharacter = nil
local recoveryUntil = 0
local lastRecovery = 0

local BIND_NAME = "VGD_AntiRagdoll"
local RECOVERY_INTERVAL = 0.03
local RECOVERY_HOLD = 0.18

local BLOCKED_STATES = {
    [Enum.HumanoidStateType.Ragdoll] = true,
    [Enum.HumanoidStateType.FallingDown] = true,
    [Enum.HumanoidStateType.Physics] = true,
    [Enum.HumanoidStateType.PlatformStanding] = true,
}

local function getCharacterParts(character)
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    return humanoid, root
end

local function snapshotCharacter(character)
    if not character then return end
    savedStates = {}
    watchedCharacter = character

    for _, obj in ipairs(character:GetDescendants()) do
        if obj:IsA("Motor6D") then
            savedStates[obj] = {kind = "Motor6D", Enabled = obj.Enabled}
        elseif obj:IsA("BallSocketConstraint")
            or obj:IsA("HingeConstraint")
            or obj:IsA("RodConstraint")
            or obj:IsA("RopeConstraint")
            or obj:IsA("SpringConstraint")
            or obj:IsA("CylindricalConstraint")
            or obj:IsA("PrismaticConstraint")
            or obj:IsA("UniversalConstraint")
            or obj:IsA("RigidConstraint") then
            savedStates[obj] = {kind = "Constraint", Enabled = obj.Enabled}
        end
    end
end

local function restoreSnapshot(character)
    if not character then return end
    for obj, state in pairs(savedStates) do
        if obj and obj.Parent and state then
            if state.kind == "Motor6D" then
                pcall(function() obj.Enabled = state.Enabled end)
            elseif state.kind == "Constraint" then
                pcall(function() obj.Enabled = state.Enabled end)
            end
        end
    end
end

local function refreshSnapshotForNewObjects(obj)
    if not enabled or not obj or not watchedCharacter then return end
    if not obj:IsDescendantOf(watchedCharacter) then return end

    if obj:IsA("Motor6D") then
        if savedStates[obj] == nil then
            savedStates[obj] = {kind = "Motor6D", Enabled = obj.Enabled}
        end
    elseif obj:IsA("BallSocketConstraint")
        or obj:IsA("HingeConstraint")
        or obj:IsA("RodConstraint")
        or obj:IsA("RopeConstraint")
        or obj:IsA("SpringConstraint")
        or obj:IsA("CylindricalConstraint")
        or obj:IsA("PrismaticConstraint")
        or obj:IsA("UniversalConstraint")
        or obj:IsA("RigidConstraint") then
        -- Newly-created constraints are not assumed to be harmful. They are
        -- only acted on during an active abnormal Humanoid state.
        if savedStates[obj] == nil then
            savedStates[obj] = {kind = "Constraint", Enabled = obj.Enabled}
        end
    end
end

local function isAbnormalState(humanoid)
    if not humanoid then return false end
    local ok, state = pcall(function() return humanoid:GetState() end)
    return ok and BLOCKED_STATES[state] == true
end

local function hasMovementBlocked(humanoid)
    if not humanoid then return false end
    local platform = false
    pcall(function() platform = humanoid.PlatformStand end)
    if platform then return true end

    local state = nil
    pcall(function() state = humanoid:GetState() end)
    if state == Enum.HumanoidStateType.PlatformStanding
        or state == Enum.HumanoidStateType.Ragdoll
        or state == Enum.HumanoidStateType.FallingDown
        or state == Enum.HumanoidStateType.Physics then
        return true
    end

    return false
end

local function recover(character, humanoid, root)
    if not humanoid or not root then return end

    local now = os.clock()
    if now - lastRecovery < RECOVERY_INTERVAL then return end
    lastRecovery = now
    recoveryUntil = now + RECOVERY_HOLD

    -- Restore only states/objects that were captured for this character.
    restoreSnapshot(character)

    pcall(function() humanoid.PlatformStand = false end)
    pcall(function() humanoid:SetStateEnabled(Enum.HumanoidStateType.GettingUp, true) end)
    pcall(function() humanoid:SetStateEnabled(Enum.HumanoidStateType.Running, true) end)
    pcall(function() humanoid:SetStateEnabled(Enum.HumanoidStateType.Landed, true) end)
    pcall(function() humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true) end)
    pcall(function() humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, true) end)
    pcall(function() humanoid.AutoRotate = true end)

    -- Prefer GettingUp first; Roblox will transition to a normal locomotion
    -- state when the character is physically able to stand.
    pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.GettingUp) end)

    task.defer(function()
        if not enabled or player.Character ~= character then return end
        local h, r = getCharacterParts(character)
        if not h or not r then return end
        pcall(function() h.PlatformStand = false end)
        if hasMovementBlocked(h) then
            pcall(function() h:ChangeState(Enum.HumanoidStateType.Running) end)
        end
    end)
end

local function monitor()
    if not enabled then return end

    local character = player.Character
    if not character then return end
    local humanoid, root = getCharacterParts(character)
    if not humanoid or not root then return end

    if character ~= watchedCharacter then
        snapshotCharacter(character)
    end

    local abnormal = isAbnormalState(humanoid) or hasMovementBlocked(humanoid)
    if abnormal then
        recover(character, humanoid, root)
        return
    end

    -- During the short recovery window, make sure the game did not immediately
    -- re-apply PlatformStand or an abnormal state.
    if os.clock() < recoveryUntil then
        pcall(function() humanoid.PlatformStand = false end)
        local state = humanoid:GetState()
        if BLOCKED_STATES[state] then
            pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.GettingUp) end)
        end
    end
end

local function disconnectAll()
    if renderConnection then
        renderConnection:Disconnect()
        renderConnection = nil
    end
    if characterConnection then
        characterConnection:Disconnect()
        characterConnection = nil
    end
    if descendantConnection then
        descendantConnection:Disconnect()
        descendantConnection = nil
    end
    if stateChangedConnection then
        stateChangedConnection:Disconnect()
        stateChangedConnection = nil
    end
end

local function enable()
    if enabled then return true end
    local character = player.Character
    local humanoid, root = getCharacterParts(character)
    if not humanoid or not root then return false end

    enabled = true
    recoveryUntil = 0
    lastRecovery = 0
    snapshotCharacter(character)

    characterConnection = player.CharacterAdded:Connect(function(newCharacter)
        if not enabled then return end
        task.defer(function()
            if not enabled or player.Character ~= newCharacter then return end
            local h, r = getCharacterParts(newCharacter)
            if h and r then
                snapshotCharacter(newCharacter)
            end
        end)
    end)

    descendantConnection = character.DescendantAdded:Connect(function(obj)
        refreshSnapshotForNewObjects(obj)
    end)

    stateChangedConnection = humanoid.StateChanged:Connect(function(_, newState)
        if not enabled then return end
        if BLOCKED_STATES[newState] then
            local currentCharacter = player.Character
            if currentCharacter == character then
                local h, r = getCharacterParts(character)
                if h and r then
                    task.defer(function()
                        if enabled and player.Character == character then
                            recover(character, h, r)
                        end
                    end)
                end
            end
        end
    end)

    renderConnection = RunService.RenderStepped:Connect(monitor)
    monitor()
    return true
end

local function disable()
    enabled = false
    disconnectAll()

    if watchedCharacter and watchedCharacter.Parent then
        restoreSnapshot(watchedCharacter)
    end

    savedStates = {}
    watchedCharacter = nil
    recoveryUntil = 0
    lastRecovery = 0
    return false
end

local function toggle()
    if enabled then
        return disable()
    end
    return enable()
end

local VGD_AntiRagdoll = {}
VGD_AntiRagdoll.Enable = enable
VGD_AntiRagdoll.Disable = disable
VGD_AntiRagdoll.Toggle = toggle
VGD_AntiRagdoll.IsEnabled = function() return enabled end

if not _G.VGD_AntiRagdoll_GUIControlled then
    task.defer(enable)
end

return VGD_AntiRagdoll
