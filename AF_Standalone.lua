-- 🚫 AF STANDALONE
-- Standalone AntiFling extracted from the VGD GUI.
-- Auto-starts when loaded.

local Players = game:GetService("Players")
local player = Players.LocalPlayer
local RunService = game:GetService("RunService")
local PhysicsService = game:GetService("PhysicsService")

-- 🚫 ANTIFLING
-- =========================================================

local antiFling = false

local antiFlingConnections = {}
local antiFlingPlayerConnections = {}

local antiFlingStoredParts = {}
local antiFlingTrackedAssemblies = {}
local antiFlingNoCollisionPairs = {}

local ANTI_FLING_CHARACTER_GROUP =
    "VGD_AntiFlingCharacter"

local ANTI_FLING_PART_GROUP =
    "VGD_AntiFlingParts"

local antiFlingOriginalCollisionGroups = {}
local antiFlingPartConnections = {}
local antiFlingCharacterParts = {}

-- Stronger zero-contact protection
local antiFlingCollisionLocks = {}

local antiFlingGlobalScanCounter = 0

local ANTI_FLING_RADIUS = 14
local ANTI_FLING_HEIGHT = 16
local ANTI_FLING_SCAN_INTERVAL = 0.03
local ANTI_FLING_MAX_PARTS = 300

local ANTI_FLING_MAX_HORIZONTAL_VELOCITY = 100
local ANTI_FLING_MAX_ANGULAR_VELOCITY = 60
local ANTI_FLING_MAX_POSITION_DELTA = 15

local lastAntiFlingScan = 0
local antiFlingLastSafeCFrame = nil
local antiFlingLastRootPosition = nil


-- =========================================================
-- NDS HAZARD PROTECTION
-- =========================================================

local antiFlingHazardConnections = {}
local antiFlingHazardProtection = false

local antiFlingNDSHazards = {}
local antiFlingNDSPartConnections = {}
local antiFlingNDSHazardConnections = {}
local antiFlingNDSPartStates = {}


-- =========================================================
-- NDS NAME CHECKS
-- =========================================================

local function isNDSMeteor(instance)

    return instance
        and instance.Name == "MeteorTemplate"

end

local function isNDSLava(instance)

    return instance
        and instance.Name == "Lava"

end

local function isNDSAvalanche(instance)

    return instance
        and instance.Name == "AvalanchePart"

end


-- =========================================================
-- EXACT NDS HAZARD CHECK
-- =========================================================

local function isTargetNDSHazard(instance)

    if not instance
        or not instance.Parent then

        return false

    end

    local meteorFolder =
        workspace:FindFirstChild(
            "MeteorFolder"
        )

    if meteorFolder
        and instance.Parent == meteorFolder
        and isNDSMeteor(instance) then

        return true

    end

    local structure =
        workspace:FindFirstChild(
            "Structure"
        )

    if structure
        and instance.Parent == structure then

        if isNDSLava(instance)
            or isNDSAvalanche(instance) then

            return true

        end

    end

    return false

end


-- =========================================================
-- FIND DIRECT NDS HAZARD FROM DESCENDANT
-- =========================================================

local function findNDSHazardFromDescendant(
    descendant
)

    if not descendant then
        return nil
    end

    local meteorFolder =
        workspace:FindFirstChild(
            "MeteorFolder"
        )

    if meteorFolder then

        local current = descendant

        while current
            and current ~= workspace do

            if current.Parent == meteorFolder
                and isNDSMeteor(current) then

                return current

            end

            current = current.Parent

        end

    end

    local structure =
        workspace:FindFirstChild(
            "Structure"
        )

    if structure then

        local current = descendant

        while current
            and current ~= workspace do

            if current.Parent == structure
                and (
                    isNDSLava(current)
                    or isNDSAvalanche(current)
                ) then

                return current

            end

            current = current.Parent

        end

    end

    return nil

end


-- =========================================================
-- NDS TOUCH TRANSMITTER REMOVAL
-- =========================================================

local function removeNDSTouchTransmitter(instance)

    if not instance
        or not instance.Parent then

        return

    end

    pcall(function()

        for _, child in ipairs(
            instance:GetChildren()
        ) do

            if child:IsA("TouchTransmitter") then

                child:Destroy()

            end

        end

    end)

end

local function removeAllNDSTouchTransmitters(
    instance
)

    if not instance
        or not instance.Parent then

        return

    end

    removeNDSTouchTransmitter(instance)

    pcall(function()

        for _, descendant in ipairs(
            instance:GetDescendants()
        ) do

            if descendant:IsA(
                "TouchTransmitter"
            ) then

                descendant:Destroy()

            end

        end

    end)

end


-- =========================================================
-- NDS PART NEUTRALIZATION
-- =========================================================

local function neutralizeNDSPart(part)

    if not antiFlingHazardProtection then
        return
    end

    if not part
        or not part.Parent
        or not part:IsA("BasePart") then

        return

    end

    if not antiFlingNDSPartStates[part] then

        antiFlingNDSPartStates[part] = {

            CanCollide = part.CanCollide,
            CanTouch = part.CanTouch,
            CanQuery = part.CanQuery

        }

    end

    pcall(function()

        part.CanCollide = false
        part.CanTouch = false
        part.CanQuery = false

    end)

    removeNDSTouchTransmitter(part)

    if not antiFlingNDSPartConnections[part] then

        local connections = {}

        table.insert(
            connections,

            part:GetPropertyChangedSignal(
                "CanCollide"
            ):Connect(
                function()

                    if not antiFlingHazardProtection then
                        return
                    end

                    if part
                        and part.Parent
                        and part.CanCollide then

                        pcall(function()
                            part.CanCollide = false
                        end)

                    end

                end
            )
        )

        table.insert(
            connections,

            part:GetPropertyChangedSignal(
                "CanTouch"
            ):Connect(
                function()

                    if not antiFlingHazardProtection then
                        return
                    end

                    if part
                        and part.Parent
                        and part.CanTouch then

                        pcall(function()
                            part.CanTouch = false
                        end)

                    end

                end
            )
        )

        table.insert(
            connections,

            part:GetPropertyChangedSignal(
                "CanQuery"
            ):Connect(
                function()

                    if not antiFlingHazardProtection then
                        return
                    end

                    if part
                        and part.Parent
                        and part.CanQuery then

                        pcall(function()
                            part.CanQuery = false
                        end)

                    end

                end
            )
        )

        table.insert(
            connections,

            part.ChildAdded:Connect(
                function(child)

                    if not antiFlingHazardProtection then
                        return
                    end

                    if child:IsA(
                        "TouchTransmitter"
                    ) then

                        pcall(function()
                            child:Destroy()
                        end)

                    end

                end
            )
        )

        table.insert(
            connections,

            part.AncestryChanged:Connect(
                function()

                    if not antiFlingHazardProtection then
                        return
                    end

                    if part.Parent then

                        task.defer(function()

                            if antiFlingHazardProtection
                                and part.Parent then

                                neutralizeNDSPart(
                                    part
                                )

                            end

                        end)

                    end

                end
            )
        )

        antiFlingNDSPartConnections[part] =
            connections

    end)

end


-- =========================================================
-- NDS HAZARD CHILD TRACKING
-- =========================================================

local function trackNDSHazard(hazard)

    if not antiFlingHazardProtection then
        return
    end

    if not hazard
        or not hazard.Parent then

        return

    end

    if not isTargetNDSHazard(hazard) then
        return
    end

    antiFlingNDSHazards[hazard] = true

    if hazard:IsA("BasePart") then

        neutralizeNDSPart(hazard)

    end

    pcall(function()

        for _, descendant in ipairs(
            hazard:GetDescendants()
        ) do

            if descendant:IsA("BasePart") then

                neutralizeNDSPart(
                    descendant
                )

            elseif descendant:IsA(
                "TouchTransmitter"
            ) then

                pcall(function()
                    descendant:Destroy()
                end)

            end

        end

    end)

    removeAllNDSTouchTransmitters(hazard)

    if not antiFlingNDSHazardConnections[
        hazard
    ] then

        local connections = {}

        table.insert(
            connections,

            hazard.DescendantAdded:Connect(
                function(descendant)

                    if not antiFlingHazardProtection then
                        return
                    end

                    if descendant:IsA("BasePart") then

                        neutralizeNDSPart(
                            descendant
                        )

                    elseif descendant:IsA(
                        "TouchTransmitter"
                    ) then

                        pcall(function()
                            descendant:Destroy()
                        end)

                    end

                end
            )
        )

        table.insert(
            connections,

            hazard.AncestryChanged:Connect(
                function()

                    if not antiFlingHazardProtection then
                        return
                    end

                    if hazard.Parent then

                        task.defer(function()

                            if antiFlingHazardProtection
                                and isTargetNDSHazard(
                                    hazard
                                ) then

                                trackNDSHazard(
                                    hazard
                                )

                            end

                        end)

                    else

                        antiFlingNDSHazards[
                            hazard
                        ] = nil

                    end

                end
            )
        )

        antiFlingNDSHazardConnections[
            hazard
        ] = connections

    end

end


-- =========================================================
-- PROCESS NDS HAZARD
-- =========================================================

local function processNDSHazard(instance)

    if not antiFlingHazardProtection then
        return
    end

    if not instance
        or not instance.Parent then

        return

    end

    if not isTargetNDSHazard(instance) then
        return
    end

    trackNDSHazard(instance)

end


-- =========================================================
-- PROCESS NEW NDS DESCENDANT
-- =========================================================

local function processNDSHazardDescendant(
    descendant
)

    if not antiFlingHazardProtection then
        return
    end

    if not descendant
        or not descendant.Parent then

        return

    end

    if isTargetNDSHazard(descendant) then

        processNDSHazard(descendant)
        return

    end

    local hazard =
        findNDSHazardFromDescendant(
            descendant
        )

    if hazard then

        if descendant:IsA("BasePart") then

            neutralizeNDSPart(
                descendant
            )

        elseif descendant:IsA(
            "TouchTransmitter"
        ) then

            pcall(function()
                descendant:Destroy()
            end)

        end

        trackNDSHazard(hazard)

    end

end


-- =========================================================
-- CLEAN NDS PART CONNECTIONS
-- =========================================================

local function clearNDSPartConnections()

    for part, connections in pairs(
        antiFlingNDSPartConnections
    ) do

        if connections then

            for _, connection in ipairs(
                connections
            ) do

                if connection then

                    pcall(function()
                        connection:Disconnect()
                    end)

                end

            end

        end

        antiFlingNDSPartConnections[
            part
        ] = nil

    end

end


-- =========================================================
-- CLEAN NDS HAZARD CONNECTIONS
-- =========================================================

local function clearNDSHazardConnections()

    for _, connection in ipairs(
        antiFlingHazardConnections
    ) do

        if connection then

            pcall(function()
                connection:Disconnect()
            end)

        end

    end

    table.clear(
        antiFlingHazardConnections
    )

    for hazard, connections in pairs(
        antiFlingNDSHazardConnections
    ) do

        if connections then

            for _, connection in ipairs(
                connections
            ) do

                if connection then

                    pcall(function()
                        connection:Disconnect()
                    end)

                end

            end

        end

        antiFlingNDSHazardConnections[
            hazard
        ] = nil

    end

    table.clear(
        antiFlingNDSHazards
    )

end


-- =========================================================
-- RESTORE NDS PARTS
-- =========================================================

local function restoreNDSParts()

    for part, state in pairs(
        antiFlingNDSPartStates
    ) do

        if part
            and part.Parent
            and state then

            pcall(function()

                part.CanCollide =
                    state.CanCollide

                part.CanTouch =
                    state.CanTouch

                part.CanQuery =
                    state.CanQuery

            end)

        end

    end

    table.clear(
        antiFlingNDSPartStates
    )

end


-- =========================================================
-- SCAN EXISTING NDS HAZARDS
-- =========================================================

local function scanExistingNDSHazards()

    if not antiFlingHazardProtection then
        return
    end

    local meteorFolder =
        workspace:FindFirstChild(
            "MeteorFolder"
        )

    if meteorFolder then

        for _, child in ipairs(
            meteorFolder:GetChildren()
        ) do

            if isNDSMeteor(child) then

                processNDSHazard(child)

            end

        end

    end

    local structure =
        workspace:FindFirstChild(
            "Structure"
        )

    if structure then

        for _, child in ipairs(
            structure:GetChildren()
        ) do

            if isNDSLava(child)
                or isNDSAvalanche(child) then

                processNDSHazard(child)

            end

        end

    end

end


-- =========================================================
-- RAPID NDS MAINTENANCE
-- =========================================================

local function maintainTrackedNDSHazards()

    if not antiFlingHazardProtection then
        return
    end

    for hazard in pairs(
        antiFlingNDSHazards
    ) do

        if not hazard
            or not hazard.Parent then

            antiFlingNDSHazards[
                hazard
            ] = nil

        elseif isTargetNDSHazard(hazard) then

            if hazard:IsA("BasePart") then

                neutralizeNDSPart(
                    hazard
                )

            end

            pcall(function()

                for _, descendant in ipairs(
                    hazard:GetDescendants()
                ) do

                    if descendant:IsA("BasePart") then

                        neutralizeNDSPart(
                            descendant
                        )

                    elseif descendant:IsA(
                        "TouchTransmitter"
                    ) then

                        pcall(function()
                            descendant:Destroy()
                        end)

                    end

                end

            end)

        else

            antiFlingNDSHazards[
                hazard
            ] = nil

        end

    end

end


-- =========================================================
-- START NDS HAZARD PROTECTION
-- =========================================================

local function startNDSHazardProtection()

    if antiFlingHazardProtection then
        return
    end

    antiFlingHazardProtection = true

    clearNDSHazardConnections()
    clearNDSPartConnections()


    -- =====================================================
    -- METEOR FOLDER
    -- =====================================================

    local meteorFolder =
        workspace:FindFirstChild(
            "MeteorFolder"
        )

    if meteorFolder then

        table.insert(
            antiFlingHazardConnections,

            meteorFolder.ChildAdded:Connect(
                function(child)

                    if not antiFlingHazardProtection then
                        return
                    end

                    if isNDSMeteor(child) then

                        processNDSHazard(
                            child
                        )

                    end

                end
            )
        )

        for _, child in ipairs(
            meteorFolder:GetChildren()
        ) do

            if isNDSMeteor(child) then

                processNDSHazard(
                    child
                )

            end

        end

    end


    -- =====================================================
    -- STRUCTURE
    -- =====================================================

    local structure =
        workspace:FindFirstChild(
            "Structure"
        )

    if structure then

        table.insert(
            antiFlingHazardConnections,

            structure.ChildAdded:Connect(
                function(child)

                    if not antiFlingHazardProtection then
                        return
                    end

                    if isNDSLava(child)
                        or isNDSAvalanche(child) then

                        processNDSHazard(
                            child
                        )

                    end

                end
            )
        )

        for _, child in ipairs(
            structure:GetChildren()
        ) do

            if isNDSLava(child)
                or isNDSAvalanche(child) then

                processNDSHazard(
                    child
                )

            end

        end

    end


    -- =====================================================
    -- GLOBAL DESCENDANT EVENT
    -- =====================================================

    table.insert(
        antiFlingHazardConnections,

        workspace.DescendantAdded:Connect(
            function(descendant)

                if not antiFlingHazardProtection then
                    return
                end

                processNDSHazardDescendant(
                    descendant
                )

            end
        )
    )


    -- =====================================================
    -- FOLDER CREATION WATCH
    -- =====================================================

    table.insert(
        antiFlingHazardConnections,

        workspace.ChildAdded:Connect(
            function(child)

                if not antiFlingHazardProtection then
                    return
                end

                if child.Name ==
                    "MeteorFolder" then

                    table.insert(
                        antiFlingHazardConnections,

                        child.ChildAdded:Connect(
                            function(hazard)

                                if not antiFlingHazardProtection then
                                    return
                                end

                                if isNDSMeteor(
                                    hazard
                                ) then

                                    processNDSHazard(
                                        hazard
                                    )

                                end

                            end
                        )
                    )

                    for _, hazard in ipairs(
                        child:GetChildren()
                    ) do

                        if isNDSMeteor(hazard) then

                            processNDSHazard(
                                hazard
                            )

                        end

                    end

                elseif child.Name ==
                    "Structure" then

                    table.insert(
                        antiFlingHazardConnections,

                        child.ChildAdded:Connect(
                            function(hazard)

                                if not antiFlingHazardProtection then
                                    return
                                end

                                if isNDSLava(
                                    hazard
                                )
                                    or isNDSAvalanche(
                                        hazard
                                    ) then

                                    processNDSHazard(
                                        hazard
                                    )

                                end

                            end
                        )
                    )

                    for _, hazard in ipairs(
                        child:GetChildren()
                    ) do

                        if isNDSLava(hazard)
                            or isNDSAvalanche(
                                hazard
                            ) then

                            processNDSHazard(
                                hazard
                            )

                        end

                    end

                end

            end
        )
    )


    -- =====================================================
    -- INITIAL SCAN
    -- =====================================================

    scanExistingNDSHazards()

end


-- =========================================================
-- STOP NDS HAZARD PROTECTION
-- =========================================================

local function stopNDSHazardProtection()

    antiFlingHazardProtection = false

    clearNDSHazardConnections()
    clearNDSPartConnections()
    restoreNDSParts()

end


-- =========================================================
-- COLLISION GROUP SETUP
-- =========================================================

local function setupAntiFlingCollisionGroups()

    pcall(function()

        if not PhysicsService:IsCollisionGroupRegistered(
            ANTI_FLING_CHARACTER_GROUP
        ) then

            PhysicsService:RegisterCollisionGroup(
                ANTI_FLING_CHARACTER_GROUP
            )

        end

    end)

    pcall(function()

        if not PhysicsService:IsCollisionGroupRegistered(
            ANTI_FLING_PART_GROUP
        ) then

            PhysicsService:RegisterCollisionGroup(
                ANTI_FLING_PART_GROUP
            )

        end

    end)

    pcall(function()

        PhysicsService:CollisionGroupSetCollidable(
            ANTI_FLING_CHARACTER_GROUP,
            ANTI_FLING_PART_GROUP,
            false
        )

    end)

end

local function restoreAntiFlingCollisionGroup(part)

    if not part then
        return
    end

    local originalGroup =
        antiFlingOriginalCollisionGroups[part]

    if originalGroup then

        if part.Parent then

            pcall(function()

                part.CollisionGroup =
                    originalGroup

            end)

        end

        antiFlingOriginalCollisionGroups[part] =
            nil

    end

    local connection =
        antiFlingPartConnections[part]

    if connection then

        pcall(function()
            connection:Disconnect()
        end)

        antiFlingPartConnections[part] =
            nil

    end

end


-- =========================================================
-- STRONGER ZERO-CONTACT COLLISION PROTECTION
-- =========================================================

local function protectAntiFlingCollisionPart(part)

    if not antiFling then
        return
    end

    if not part
        or not part.Parent
        or not part:IsA("BasePart") then

        return

    end

    local character =
        player.Character

    if character
        and part:IsDescendantOf(character) then

        return

    end

    local model =
        part:FindFirstAncestorOfClass("Model")

    if model
        and model:FindFirstChildOfClass(
            "Humanoid"
        ) then

        return

    end

    if part.Anchored then

        if antiFlingOriginalCollisionGroups[part] then

            restoreAntiFlingCollisionGroup(
                part
            )

        end

        return

    end

    if not antiFlingOriginalCollisionGroups[part] then

        local originalGroup

        pcall(function()

            originalGroup =
                part.CollisionGroup

        end)

        if originalGroup then

            antiFlingOriginalCollisionGroups[part] =
                originalGroup

        end

    end

    -- =====================================================
    -- IMMEDIATE ZERO-CONTACT SHIELD
    -- =====================================================

    pcall(function()

        part.CollisionGroup =
            ANTI_FLING_PART_GROUP

        part.CanCollide = false
        part.CanTouch = false
        part.CanQuery = false

    end)

    -- =====================================================
    -- PROPERTY LOCK
    -- =====================================================

    if not antiFlingCollisionLocks[part] then

        local connections = {}

        table.insert(
            connections,

            part:GetPropertyChangedSignal(
                "CanCollide"
            ):Connect(
                function()

                    if not antiFling then
                        return
                    end

                    if part
                        and part.Parent
                        and not part.Anchored
                        and part.CanCollide then

                        pcall(function()
                            part.CanCollide = false
                        end)

                    end

                end
            )
        )

        table.insert(
            connections,

            part:GetPropertyChangedSignal(
                "CanTouch"
            ):Connect(
                function()

                    if not antiFling then
                        return
                    end

                    if part
                        and part.Parent
                        and not part.Anchored
                        and part.CanTouch then

                        pcall(function()
                            part.CanTouch = false
                        end)

                    end

                end
            )
        )

        table.insert(
            connections,

            part:GetPropertyChangedSignal(
                "CanQuery"
            ):Connect(
                function()

                    if not antiFling then
                        return
                    end

                    if part
                        and part.Parent
                        and not part.Anchored
                        and part.CanQuery then

                        pcall(function()
                            part.CanQuery = false
                        end)

                    end

                end
            )
        )

        table.insert(
            connections,

            part:GetPropertyChangedSignal(
                "CollisionGroup"
            ):Connect(
                function()

                    if not antiFling then
                        return
                    end

                    if part
                        and part.Parent
                        and not part.Anchored
                        and part.CollisionGroup ~=
                            ANTI_FLING_PART_GROUP then

                        pcall(function()

                            part.CollisionGroup =
                                ANTI_FLING_PART_GROUP

                        end)

                    end

                end
            )
        )

        table.insert(
            connections,

            part:GetPropertyChangedSignal(
                "Anchored"
            ):Connect(
                function()

                    if not antiFling then
                        return
                    end

                    if not part
                        or not part.Parent then

                        return

                    end

                    if not part.Anchored then

                        protectAntiFlingCollisionPart(
                            part
                        )

                    else

                        restoreAntiFlingCollisionGroup(
                            part
                        )

                    end

                end
            )
        )

        table.insert(
            connections,

            part.AncestryChanged:Connect(
                function()

                    if not antiFling then
                        return
                    end

                    if part.Parent then

                        task.defer(function()

                            if antiFling
                                and part.Parent
                                and not part.Anchored then

                                protectAntiFlingCollisionPart(
                                    part
                                )

                            end

                        end)

                    end

                end
            )
        )

        antiFlingCollisionLocks[part] =
            connections

    end

end


local function scanAllAntiFlingCollisionParts()

    if not antiFling then
        return
    end

    setupAntiFlingCollisionGroups()

    local descendants

    pcall(function()

        descendants =
            workspace:GetDescendants()

    end)

    if not descendants then
        return
    end

    for _, descendant in ipairs(
        descendants
    ) do

        if not antiFling then
            break
        end

        if descendant:IsA("BasePart") then

            protectAntiFlingCollisionPart(
                descendant
            )

        end

    end

end

local function protectAntiFlingCharacter()

    if not antiFling then
        return
    end

    local character =
        player.Character

    if not character then
        return
    end

    setupAntiFlingCollisionGroups()

    for _, part in ipairs(
        character:GetDescendants()
    ) do

        if part:IsA("BasePart") then

            if not antiFlingCharacterParts[part] then

                local originalGroup

                pcall(function()

                    originalGroup =
                        part.CollisionGroup

                end)

                antiFlingCharacterParts[part] =
                    originalGroup

            end

            pcall(function()

                part.CollisionGroup =
                    ANTI_FLING_CHARACTER_GROUP

            end)

        end

    end

end

local function restoreAntiFlingCharacter()

    for part, originalGroup in pairs(
        antiFlingCharacterParts
    ) do

        if part
            and part.Parent
            and originalGroup then

            pcall(function()

                part.CollisionGroup =
                    originalGroup

            end)

        end

    end

    table.clear(
        antiFlingCharacterParts
    )

end

local function restoreAllAntiFlingCollisionGroups()

    for part in pairs(
        antiFlingOriginalCollisionGroups
    ) do

        restoreAntiFlingCollisionGroup(
            part
        )

    end

    for part, connection in pairs(
        antiFlingPartConnections
    ) do

        if connection then

            pcall(function()
                connection:Disconnect()
            end)

        end

        antiFlingPartConnections[part] =
            nil

    end

    -- Clear stronger collision property locks
    for part, connections in pairs(
        antiFlingCollisionLocks
    ) do

        if connections then

            for _, connection in ipairs(
                connections
            ) do

                if connection then

                    pcall(function()
                        connection:Disconnect()
                    end)

                end

            end

        end

        antiFlingCollisionLocks[part] =
            nil

    end

    table.clear(
        antiFlingOriginalCollisionGroups
    )

    restoreAntiFlingCharacter()

end


-- =========================================================
-- SUPER RING PARTS V6 NO-FALL
-- =========================================================

local antiFlingNoFallConnection = nil

local function startAntiFlingNoFall()

    if antiFlingNoFallConnection then
        return
    end

    antiFlingNoFallConnection =
        RunService.Heartbeat:Connect(
            function()

                if not antiFling then
                    return
                end

                local character =
                    player.Character

                if not character then
                    return
                end

                local root =
                    character:FindFirstChild(
                        "HumanoidRootPart"
                    )

                if not root then
                    return
                end

                if not root.Parent then
                    return
                end

                local oldvel =
                    root.AssemblyLinearVelocity

                root.AssemblyLinearVelocity =
                    Vector3.zero

                RunService.RenderStepped:Wait()

                if not antiFling then
                    return
                end

                if not root
                    or not root.Parent then

                    return

                end

                root.AssemblyLinearVelocity =
                    oldvel

            end
        )

end

local function stopAntiFlingNoFall()

    if antiFlingNoFallConnection then

        antiFlingNoFallConnection:Disconnect()
        antiFlingNoFallConnection = nil

    end

end


-- =========================================================
-- CLEAR ANTIFLING CONNECTIONS
-- =========================================================

local function clearAntiFlingConnections()

    for _, connection in ipairs(
        antiFlingConnections
    ) do

        if connection then

            pcall(function()
                connection:Disconnect()
            end)

        end

    end

    table.clear(
        antiFlingConnections
    )

    for plr, connections in pairs(
        antiFlingPlayerConnections
    ) do

        if type(connections) == "table" then

            for _, connection in ipairs(
                connections
            ) do

                if connection then

                    pcall(function()
                        connection:Disconnect()
                    end)

                end

            end

        end

        antiFlingPlayerConnections[plr] =
            nil

    end

end

local function antiFlingIsCharacterModel(model)

    if not model then
        return false
    end

    return model:FindFirstChildOfClass(
        "Humanoid"
    ) ~= nil

end

local function getAntiFlingCharacterFromPart(part)

    if not part then
        return nil
    end

    local model =
        part:FindFirstAncestorOfClass(
            "Model"
        )

    if antiFlingIsCharacterModel(model) then
        return model
    end

    return nil

end

local function shouldIgnoreAntiFlingPart(
    part,
    character
)

    if not part
        or not part:IsA("BasePart") then

        return true

    end

    if not part.Parent then
        return true
    end

    if character
        and part:IsDescendantOf(character) then

        return true

    end

    local model =
        part:FindFirstAncestorOfClass(
            "Model"
        )

    if antiFlingIsCharacterModel(model) then
        return true
    end

    return false

end

local function isAntiFlingPartNearCharacter(
    part,
    character,
    root
)

    if not part
        or not part.Parent
        or not part:IsA("BasePart") then

        return false

    end

    if part.Anchored then
        return false
    end

    if shouldIgnoreAntiFlingPart(
        part,
        character
    ) then

        return false

    end

    if not root then
        return false
    end

    local offset =
        part.Position -
        root.Position

    local horizontalDistance =
        Vector3.new(
            offset.X,
            0,
            offset.Z
        ).Magnitude

    local verticalDistance =
        math.abs(offset.Y)

    return horizontalDistance <=
        ANTI_FLING_RADIUS
        and verticalDistance <=
        ANTI_FLING_HEIGHT / 2

end

local function storeAntiFlingPart(part)

    if not part
        or not part:IsA("BasePart") then

        return

    end

    if antiFlingStoredParts[part] then
        return
    end

    antiFlingStoredParts[part] = {

        CanCollide = part.CanCollide,
        CanTouch = part.CanTouch,
        CanQuery = part.CanQuery

    }

end

local function neutralizeAntiFlingPart(part)

    if not part
        or not part.Parent
        or not part:IsA("BasePart") then

        return

    end

    storeAntiFlingPart(part)

    pcall(function()

        part.CanCollide = false
        part.CanTouch = false
        part.CanQuery = false

    end)

    protectAntiFlingCollisionPart(part)

end

local function restoreAntiFlingPart(part)

    local saved =
        antiFlingStoredParts[part]

    if not saved then
        return
    end

    if part
        and part.Parent then

        pcall(function()

            part.CanCollide =
                saved.CanCollide

            part.CanTouch =
                saved.CanTouch

            part.CanQuery =
                saved.CanQuery

        end)

    end

    antiFlingStoredParts[part] =
        nil

end

local function restoreAllAntiFlingParts()

    for part in pairs(
        antiFlingStoredParts
    ) do

        restoreAntiFlingPart(part)

    end

    table.clear(
        antiFlingStoredParts
    )

    table.clear(
        antiFlingTrackedAssemblies
    )

end

local function destroyPlayerNoCollisionPair(
    character
)

    local pair =
        antiFlingNoCollisionPairs[
            character
        ]

    if not pair then
        return
    end

    if pair.connections then

        for _, connection in ipairs(
            pair.connections
        ) do

            if connection then

                pcall(function()
                    connection:Disconnect()
                end)

            end

        end

    end

    if pair.constraints then

        for _, constraint in ipairs(
            pair.constraints
        ) do

            if constraint then

                pcall(function()
                    constraint:Destroy()
                end)

            end

        end

    end

    antiFlingNoCollisionPairs[
        character
    ] = nil

end

local function removeAntiFlingNoCollision()

    for character in pairs(
        antiFlingNoCollisionPairs
    ) do

        destroyPlayerNoCollisionPair(
            character
        )

    end

    table.clear(
        antiFlingNoCollisionPairs
    )

end

local function createAntiFlingNoCollision(
    pair,
    part0,
    part1
)

    if not pair
        or not part0
        or not part1 then

        return

    end

    if not part0:IsA("BasePart")
        or not part1:IsA("BasePart") then

        return

    end

    if not part0.Parent
        or not part1.Parent then

        return

    end

    pair.seen[part0] =
        pair.seen[part0] or {}

    if pair.seen[part0][part1] then
        return
    end

    pair.seen[part0][part1] = true

    local constraint =
        Instance.new(
            "NoCollisionConstraint"
        )

    constraint.Name =
        "VGD_AntiFling_NoCollision"

    constraint.Part0 = part0
    constraint.Part1 = part1
    constraint.Parent = part0

    table.insert(
        pair.constraints,
        constraint
    )

end

local function addLocalPartToPair(
    pair,
    localPart,
    otherCharacter
)

    if not localPart
        or not localPart:IsA("BasePart") then

        return

    end

    if not localPart.Parent then
        return
    end

    for _, otherPart in ipairs(
        otherCharacter:GetDescendants()
    ) do

        if otherPart:IsA("BasePart") then

            createAntiFlingNoCollision(
                pair,
                localPart,
                otherPart
            )

        end

    end

end

local function addOtherPartToPair(
    pair,
    otherPart,
    localCharacter
)

    if not otherPart
        or not otherPart:IsA("BasePart") then

        return

    end

    if not otherPart.Parent then
        return
    end

    for _, localPart in ipairs(
        localCharacter:GetDescendants()
    ) do

        if localPart:IsA("BasePart") then

            createAntiFlingNoCollision(
                pair,
                localPart,
                otherPart
            )

        end

    end

end

local function ensurePlayerNoCollision(
    otherCharacter,
    localCharacter
)

    if not otherCharacter
        or not otherCharacter.Parent then

        return

    end

    if not localCharacter
        or not localCharacter.Parent then

        return

    end

    if otherCharacter == localCharacter then
        return
    end

    local existing =
        antiFlingNoCollisionPairs[
            otherCharacter
        ]

    if existing
        and existing.localCharacter ==
            localCharacter then

        return

    end

    if existing then

        destroyPlayerNoCollisionPair(
            otherCharacter
        )

    end

    local pair = {

        constraints = {},
        connections = {},
        seen = {},
        localCharacter = localCharacter

    }

    antiFlingNoCollisionPairs[
        otherCharacter
    ] = pair

    for _, localPart in ipairs(
        localCharacter:GetDescendants()
    ) do

        if localPart:IsA("BasePart") then

            for _, otherPart in ipairs(
                otherCharacter:GetDescendants()
            ) do

                if otherPart:IsA("BasePart") then

                    createAntiFlingNoCollision(
                        pair,
                        localPart,
                        otherPart
                    )

                end

            end

        end

    end

    table.insert(
        pair.connections,

        localCharacter.DescendantAdded:Connect(
            function(descendant)

                if not antiFling then
                    return
                end

                if descendant:IsA("BasePart") then

                    addLocalPartToPair(
                        pair,
                        descendant,
                        otherCharacter
                    )

                end

            end
        )
    )

    table.insert(
        pair.connections,

        otherCharacter.DescendantAdded:Connect(
            function(descendant)

                if not antiFling then
                    return
                end

                if descendant:IsA("BasePart") then

                    addOtherPartToPair(
                        pair,
                        descendant,
                        localCharacter
                    )

                end

            end
        )
    )

end

local function updatePlayerNoCollision()

    if not antiFling then
        return
    end

    local character =
        player.Character

    if not character then
        return
    end

    for _, otherPlayer in ipairs(
        Players:GetPlayers()
    ) do

        if otherPlayer ~= player then

            local otherCharacter =
                otherPlayer.Character

            if otherCharacter then

                ensurePlayerNoCollision(
                    otherCharacter,
                    character
                )

            end

        end

    end

end

local function neutralizeAntiFlingAssembly(
    root,
    character
)

    if not root
        or not root.Parent
        or not root:IsA("BasePart")
        or root.Anchored then

        return

    end

    local parts = {}

    pcall(function()

        parts =
            root:GetConnectedParts(true)

    end)

    if #parts == 0 then
        parts = { root }
    end

    local count = 0

    for _, part in ipairs(parts) do

        if count >= ANTI_FLING_MAX_PARTS then
            break
        end

        if part
            and part.Parent
            and part:IsA("BasePart")
            and not part.Anchored
            and not shouldIgnoreAntiFlingPart(
                part,
                character
            ) then

            local partCharacter =
                getAntiFlingCharacterFromPart(
                    part
                )

            if not partCharacter then

                neutralizeAntiFlingPart(
                    part
                )

                count =
                    count + 1

            end

        end

    end

    antiFlingTrackedAssemblies[root] =
        true

end

local function antiFlingNewPartCheck(part)

    if not antiFling then
        return
    end

    if not part
        or not part.Parent
        or not part:IsA("BasePart") then

        return

    end

    -- Immediate zero-contact protection
    protectAntiFlingCollisionPart(part)

    if part.Anchored then
        return
    end

    local character =
        player.Character

    if not character then
        return
    end

    local root =
        character:FindFirstChild(
            "HumanoidRootPart"
        )

    if not root then
        return
    end

    if not isAntiFlingPartNearCharacter(
        part,
        character,
        root
    ) then

        return

    end

    local partCharacter =
        getAntiFlingCharacterFromPart(
            part
        )

    if partCharacter then
        return
    end

    local assemblyRoot =
        part.AssemblyRootPart

    if assemblyRoot
        and not assemblyRoot.Anchored then

        neutralizeAntiFlingAssembly(
            assemblyRoot,
            character
        )

    else

        neutralizeAntiFlingPart(part)

    end

end

local function protectLocalCharacter()

    if not antiFling then
        return
    end

    local character =
        player.Character

    if not character then
        return
    end

    protectAntiFlingCharacter()

    local root =
        character:FindFirstChild(
            "HumanoidRootPart"
        )

    if not root then
        return
    end

    local currentPosition =
        root.Position

    if antiFlingLastRootPosition then

        local delta =
            currentPosition -
            antiFlingLastRootPosition

        if delta.Magnitude >
            ANTI_FLING_MAX_POSITION_DELTA then

            if antiFlingLastSafeCFrame then

                pcall(function()

                    root.CFrame =
                        antiFlingLastSafeCFrame

                end)

                currentPosition =
                    root.Position

            end

        else

            antiFlingLastSafeCFrame =
                root.CFrame

        end

    else

        antiFlingLastSafeCFrame =
            root.CFrame

    end

    antiFlingLastRootPosition =
        currentPosition

    pcall(function()

        local velocity =
            root.AssemblyLinearVelocity

        local horizontal =
            Vector3.new(
                velocity.X,
                0,
                velocity.Z
            )

        if horizontal.Magnitude >
            ANTI_FLING_MAX_HORIZONTAL_VELOCITY then

            local safeHorizontal =
                horizontal.Unit *
                ANTI_FLING_MAX_HORIZONTAL_VELOCITY

            root.AssemblyLinearVelocity =
                Vector3.new(
                    safeHorizontal.X,
                    velocity.Y,
                    safeHorizontal.Z
                )

        end

    end)

    pcall(function()

        if root.AssemblyAngularVelocity.Magnitude >
            ANTI_FLING_MAX_ANGULAR_VELOCITY then

            root.AssemblyAngularVelocity =
                Vector3.zero

        end

    end)

end

local function scanAntiFlingParts()

    if not antiFling then
        return
    end

    local character =
        player.Character

    if not character then
        return
    end

    local root =
        character:FindFirstChild(
            "HumanoidRootPart"
        )

    if not root then
        return
    end

    local overlapParams =
        OverlapParams.new()

    overlapParams.FilterType =
        Enum.RaycastFilterType.Exclude

    overlapParams.FilterDescendantsInstances = {
        character
    }

    overlapParams.MaxParts =
        ANTI_FLING_MAX_PARTS

    local nearbyParts

    pcall(function()

        nearbyParts =
            workspace:GetPartBoundsInBox(
                CFrame.new(root.Position),
                Vector3.new(
                    ANTI_FLING_RADIUS * 2,
                    ANTI_FLING_HEIGHT,
                    ANTI_FLING_RADIUS * 2
                ),
                overlapParams
            )

    end)

    if not nearbyParts then
        return
    end

    local assemblies = {}

    for _, part in ipairs(
        nearbyParts
    ) do

        if part
            and part.Parent
            and part:IsA("BasePart")
            and not part.Anchored
            and not shouldIgnoreAntiFlingPart(
                part,
                character
            ) then

            local partCharacter =
                getAntiFlingCharacterFromPart(
                    part
                )

            if not partCharacter then

                -- Immediate zero-contact protection
                protectAntiFlingCollisionPart(
                    part
                )

                local assemblyRoot =
                    part.AssemblyRootPart

                if assemblyRoot
                    and not assemblyRoot.Anchored then

                    assemblies[assemblyRoot] =
                        true

                end

            end

        end

    end

    for assemblyRoot in pairs(
        assemblies
    ) do

        neutralizeAntiFlingAssembly(
            assemblyRoot,
            character
        )

    end

end

local function recheckTrackedAntiFlingAssemblies()

    if not antiFling then
        return
    end

    local character =
        player.Character

    if not character then
        return
    end

    local root =
        character:FindFirstChild(
            "HumanoidRootPart"
        )

    if not root then
        return
    end

    for assemblyRoot in pairs(
        antiFlingTrackedAssemblies
    ) do

        if not assemblyRoot
            or not assemblyRoot.Parent then

            antiFlingTrackedAssemblies[
                assemblyRoot
            ] = nil

        elseif assemblyRoot.Anchored then

            antiFlingTrackedAssemblies[
                assemblyRoot
            ] = nil

        else

            local parts = {}

            pcall(function()

                parts =
                    assemblyRoot:GetConnectedParts(
                        true
                    )

            end)

            for _, part in ipairs(parts) do

                if part
                    and part.Parent
                    and part:IsA("BasePart")
                    and not part.Anchored then

                    protectAntiFlingCollisionPart(
                        part
                    )

                end

            end

            local distance =
                (
                    assemblyRoot.Position -
                    root.Position
                ).Magnitude

            if distance <=
                ANTI_FLING_RADIUS + 3 then

                neutralizeAntiFlingAssembly(
                    assemblyRoot,
                    character
                )

            else

                antiFlingTrackedAssemblies[
                    assemblyRoot
                ] = nil

            end

        end

    end

end

local function maintainAntiFlingCollisionShield()

    if not antiFling then
        return
    end

    antiFlingGlobalScanCounter =
        antiFlingGlobalScanCounter + 1

    if antiFlingGlobalScanCounter >= 8 then

        antiFlingGlobalScanCounter = 0

        scanAllAntiFlingCollisionParts()

    end

    protectAntiFlingCharacter()

end

local function updateAntiFling()

    if not antiFling then
        return
    end

    local character =
        player.Character

    if not character then
        return
    end

    local root =
        character:FindFirstChild(
            "HumanoidRootPart"
        )

    if not root then
        return
    end

    protectLocalCharacter()

    maintainAntiFlingCollisionShield()

    updatePlayerNoCollision()

    maintainTrackedNDSHazards()

    local now = os.clock()

    if now -
        lastAntiFlingScan <
        ANTI_FLING_SCAN_INTERVAL then

        return

    end

    lastAntiFlingScan = now

    scanAntiFlingParts()
    recheckTrackedAntiFlingAssemblies()

end


-- =========================================================
-- ENABLE ANTIFLING
-- =========================================================

local function enableAntiFling()

    if antiFling then
        return
    end

    antiFling = true

    lastAntiFlingScan = 0
    antiFlingLastSafeCFrame = nil
    antiFlingLastRootPosition = nil
    antiFlingGlobalScanCounter = 0

    table.clear(
        antiFlingTrackedAssemblies
    )

    setupAntiFlingCollisionGroups()

    startNDSHazardProtection()

    startAntiFlingNoFall()

    task.spawn(function()

        if antiFling then

            scanAllAntiFlingCollisionParts()
            protectAntiFlingCharacter()

        end

    end)

    table.insert(
        antiFlingConnections,

        player.CharacterAdded:Connect(
            function()

                if not antiFling then
                    return
                end

                antiFlingLastSafeCFrame = nil
                antiFlingLastRootPosition = nil

                restoreAntiFlingCharacter()
                removeAntiFlingNoCollision()

                task.wait(0.2)

                if antiFling then

                    lastAntiFlingScan = 0

                    protectAntiFlingCharacter()
                    updatePlayerNoCollision()

                end

            end
        )
    )

    table.insert(
        antiFlingConnections,

        workspace.DescendantAdded:Connect(
            function(descendant)

                if not antiFling then
                    return
                end

                if not descendant:IsA("BasePart") then
                    return
                end

                -- IMPORTANT:
                -- Protect immediately.
                -- No task.defer here.
                protectAntiFlingCollisionPart(
                    descendant
                )

                -- Additional nearby/assembly protection
                antiFlingNewPartCheck(
                    descendant
                )

            end
        )
    )

    for _, otherPlayer in ipairs(
        Players:GetPlayers()
    ) do

        if otherPlayer ~= player then

            local connections = {}

            table.insert(
                connections,

                otherPlayer.CharacterAdded:Connect(
                    function(newCharacter)

                        if not antiFling then
                            return
                        end

                        task.wait(0.15)

                        if antiFling
                            and newCharacter
                            and player.Character then

                            ensurePlayerNoCollision(
                                newCharacter,
                                player.Character
                            )

                        end

                    end
                )
            )

            table.insert(
                connections,

                otherPlayer.CharacterRemoving:Connect(
                    function(oldCharacter)

                        destroyPlayerNoCollisionPair(
                            oldCharacter
                        )

                    end
                )
            )

            table.insert(
                connections,

                otherPlayer.AncestryChanged:Connect(
                    function(_, parent)

                        if parent == nil then

                            if otherPlayer.Character then

                                destroyPlayerNoCollisionPair(
                                    otherPlayer.Character
                                )

                            end

                        end

                    end
                )
            )

            antiFlingPlayerConnections[
                otherPlayer
            ] = connections

            if otherPlayer.Character
                and player.Character then

                ensurePlayerNoCollision(
                    otherPlayer.Character,
                    player.Character
                )

            end

        end

    end

    table.insert(
        antiFlingConnections,

        Players.PlayerAdded:Connect(
            function(otherPlayer)

                if not antiFling then
                    return
                end

                local connections = {}

                table.insert(
                    connections,

                    otherPlayer.CharacterAdded:Connect(
                        function(newCharacter)

                            if not antiFling then
                                return
                            end

                            task.wait(0.15)

                            if antiFling
                                and newCharacter
                                and player.Character then

                                ensurePlayerNoCollision(
                                    newCharacter,
                                    player.Character
                                )

                            end

                        end
                    )
                )

                table.insert(
                    connections,

                    otherPlayer.CharacterRemoving:Connect(
                        function(oldCharacter)

                            destroyPlayerNoCollisionPair(
                                oldCharacter
                            )

                        end
                    )
                )

                table.insert(
                    connections,

                    otherPlayer.AncestryChanged:Connect(
                        function(_, parent)

                            if parent == nil then

                                if otherPlayer.Character then

                                    destroyPlayerNoCollisionPair(
                                        otherPlayer.Character
                                    )

                                end

                            end

                        end
                    )
                )

                antiFlingPlayerConnections[
                    otherPlayer
                ] = connections

                if otherPlayer.Character
                    and player.Character then

                    ensurePlayerNoCollision(
                        otherPlayer.Character,
                        player.Character
                    )

                end

            end
        )
    )

    updatePlayerNoCollision()
    protectAntiFlingCharacter()

    scanAllAntiFlingCollisionParts()
    scanAntiFlingParts()

    scanExistingNDSHazards()

end


-- =========================================================
-- DISABLE ANTIFLING
-- =========================================================

local function disableAntiFling()

    antiFling = false

    stopNDSHazardProtection()
    stopAntiFlingNoFall()

    clearAntiFlingConnections()

    removeAntiFlingNoCollision()

    restoreAllAntiFlingParts()

    restoreAllAntiFlingCollisionGroups()

    antiFlingLastSafeCFrame = nil
    antiFlingLastRootPosition = nil

    lastAntiFlingScan = 0
    antiFlingGlobalScanCounter = 0

end


-- =========================================================

-- =========================================================
-- STANDALONE ANTIFLING UPDATE LOOP
-- =========================================================

RunService.RenderStepped:Connect(function()
    if antiFling then
        updateAntiFling()
    end
end)

-- =========================================================
-- AUTO-START
-- =========================================================

enableAntiFling()
