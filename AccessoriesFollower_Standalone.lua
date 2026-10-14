--[[
    Accessory Follower Standalone v34
    Universal executor-side prototype; no VGD Hub or Studio scripts required.

    IMPORTANT:
    - This uses a legacy client-side accessory/physics technique. Replication is not
      guaranteed; the experience server may reject or undo changes.
    - Selected accessories are detached from your avatar while active.
    - CanCollide and CanTouch are disabled on moved handles to reduce side effects.
    - Use only with a consenting target. Keep movement away from collisions/obstruction.
    - ORBIT / STOP keeps detached handles unanchored in a continuously moving aerial orbit near your avatar.
    - Blank target input resolves to your own local player; enter a name to follow another player.
    - Orbit 3 uses smooth bounded per-accessory path variation while keeping stable spacing lanes.
    - The orbit uses continuous position correction plus the same legacy velocity used by the working follow loop.
    - Starting again reclaims an orbit-hold item without an anchor/unanchor cycle.
    - The existing follow loop remains based on v10, which restored v8 fresh-accessory startup timing.
    - Double-tap Dist/Speed control; orbit speed multiplier defaults to 1x.
    - Search field includes a clear button; blank target resolves to yourself.
    - GUI scale reduced by 10% from the prior 72% setting; title bar stays on-screen and touch drag tracks only its initiating finger; selection cap remains 8.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
    return
end

local GUI_NAME = "AccessoryFollowerStandaloneV34"
local ENV_KEY = "__AccessoryFollowerStandaloneV34Unload"
local PARKED_KEY = "__AccessoryFollowerParkedStates"
local SOURCE_VELOCITY = Vector3.new(-30, 0, 0)
local MAX_SELECTED = 8
local MIN_DISTANCE = 2
local MAX_DISTANCE = 10 -- User-requested maximum formation/orbit distance.
local MIN_ORBIT_SPEED_MULTIPLIER = 0.25
local MAX_ORBIT_SPEED_MULTIPLIER = 5.0 -- User-requested maximum orbit speed.
local ORBIT_SPEED_STEP = 0.25

-- Parked/idle accessories are kept in a moving aerial orbit around the local character.
-- Continuous position correction plus the known-working follow velocity may help avoid the
-- sleep/fall behavior seen with a stationary zero-velocity hold; replication remains best-effort.
local PARK_ORBIT_SPEED = 1.35
local PARK_ORBIT_RADIUS = 3.25
local PARK_ORBIT_HEIGHT = 4.4
local PARK_ORBIT_BOB_AMPLITUDE = 0.48
local PARK_ORBIT_BOB_SPEED = 2.0
local PARK_ORBIT_PULSE = 0.18
local PARK_ORBIT_WAVE = 0.42

local Modes = { "Trail", "Left", "Right", "Above", "Orbit" }
local State = {
    alive = true,
    target = nil,
    modeIndex = 5, -- Orbit is the default; keep the existing mode-cycle order.
    orbitStyle = 1, -- Orbit 1 preserves the original v19 Orbit formula.
    orbitStyleWeights = { 1, 0, 0 },
    orbitStyleStartWeights = { 1, 0, 0 },
    orbitStyleTarget = 1,
    orbitStyleElapsed = 0,
    orbitStyleDuration = 0.65,
    modeHoldInput = nil,
    modeHoldToken = 0,
    skipNextModeActivated = false,
    orbitDropdown = nil,
    orbitDropdownButtons = {},
    distance = 4,
    currentDistance = 4, -- Smoothly approaches the requested distance without snapping.
    orbitSpeed = 1.0, -- 1x preserves v13 orbit timing.
    orbitAngle = 0, -- Integrated phase: changing speed never resets the current orbit position.
    orbitBobAngle = 0,
    settingMode = "distance",
    lastSettingTap = 0,
    accessoryEntries = {},
    selectedAccessories = {},
    activeItems = {},
    parkedItems = {},
    parkedHeartbeatConnection = nil,
    parkClaimClock = 0,
    heartbeatConnection = nil,
    restoreGuardConnection = nil,
    restoreGuardItems = {},
    restoreGuardClock = 0,
    claimClock = 0,
    statusLabel = nil,
    compatibilityLabel = nil,
    mainFrame = nil,
    floatingButton = nil,
    shortcutButton = nil,
    targetList = nil,
    targetInput = nil,
    clearTargetButton = nil,
    targetSuggestions = nil,
    targetLabel = nil,
    suppressTargetTextChange = false,
    modeButton = nil,
    distanceLabel = nil,
    startButton = nil,
    stopButton = nil,
    gui = nil,
    connections = {},
}

local env = _G
if type(getgenv) == "function" then
    local ok, result = pcall(getgenv)
    if ok and type(result) == "table" then
        env = result
    end
end

-- Keep parked accessory state across this script's own re-executions.
-- This is only client-side state; the game server may still reclaim/destroy instances.
State.parkedItems = type(env[PARKED_KEY]) == "table" and env[PARKED_KEY] or {}
env[PARKED_KEY] = State.parkedItems

local function findParkedItem(accessory)
    -- A previously parked instance may have been re-equipped/reparented by the game.
    -- Only Workspace accessories are actually parked and reusable; discard stale
    -- records instead of treating a currently equipped accessory as detached.
    for index = #State.parkedItems, 1, -1 do
        local item = State.parkedItems[index]
        if not item or not item.accessory or not item.handle or not item.accessory.Parent or not item.handle.Parent then
            if item then item.parked = false end
            table.remove(State.parkedItems, index)
        elseif item.accessory == accessory then
            if item.accessory.Parent == workspace then
                return item, index
            end
            item.parked = false
            table.remove(State.parkedItems, index)
        end
    end
    return nil, nil
end

local function addParkedItem(item)
    if not item then
        return
    end
    if not findParkedItem(item.accessory) then
        table.insert(State.parkedItems, item)
    end
    item.parked = true
end

local function removeParkedItem(item)
    if not item then
        return
    end
    for index = #State.parkedItems, 1, -1 do
        if State.parkedItems[index] == item or State.parkedItems[index].accessory == item.accessory then
            table.remove(State.parkedItems, index)
        end
    end
    item.parked = false
end

local function safeDisconnect(connection)
    if connection then
        pcall(function()
            connection:Disconnect()
        end)
    end
end

local function addConnection(connection)
    table.insert(State.connections, connection)
    return connection
end

local function setStatus(message, kind)
    -- Diagnostics go to the executor/Roblox console, not the GUI status label.
    local prefix = "[Accessory Follower v34] "
    local line = prefix .. tostring(message)
    if kind == "error" then
        warn(line)
    else
        print(line)
    end
end

local function claimSimulationRadius()
    local worked = false
    if type(setsimulationradius) == "function" then
        local ok = pcall(function()
            setsimulationradius(math.huge, math.huge)
        end)
        worked = worked or ok
    end
    if type(sethiddenproperty) == "function" then
        local ok1 = pcall(function()
            sethiddenproperty(LocalPlayer, "SimulationRadius", math.huge)
        end)
        local ok2 = pcall(function()
            sethiddenproperty(LocalPlayer, "MaximumSimulationRadius", math.huge)
        end)
        worked = worked or ok1 or ok2
    end
    return worked
end

local function getCharacter(player)
    return player and player.Character
end

local function getRoot(player)
    local character = getCharacter(player)
    if not character then
        return nil
    end
    local root = character:FindFirstChild("HumanoidRootPart")
    if root and root:IsA("BasePart") then
        return root
    end
    return nil
end

local function getCurrentAccessories()
    local found = {}
    local seen = {}
    local character = LocalPlayer.Character
    if character then
        for _, child in ipairs(character:GetChildren()) do
            if child:IsA("Accessory") then
                local handle = child:FindFirstChild("Handle")
                if handle and handle:IsA("BasePart") then
                    seen[child] = true
                    table.insert(found, {
                        accessory = child,
                        handle = handle,
                        name = child.Name,
                        accessoryType = tostring(child.AccessoryType),
                        parked = false,
                    })
                end
            end
        end
    end

    -- Parked accessories live in Workspace while detached. Keep them selectable so the
    -- user can restart following without needing to restore/re-detach the same instance.
    for _, item in ipairs(State.parkedItems or {}) do
        local accessory = item and item.accessory
        local handle = item and item.handle
        if accessory and handle and accessory.Parent == workspace and handle.Parent and not seen[accessory] then
            seen[accessory] = true
            table.insert(found, {
                accessory = accessory,
                handle = handle,
                name = accessory.Name,
                accessoryType = tostring(accessory.AccessoryType),
                parked = true,
            })
        end
    end

    table.sort(found, function(a, b)
        if a.parked ~= b.parked then
            return not a.parked
        end
        return string.lower(a.name) < string.lower(b.name)
    end)
    return found
end

local function selectedCount()
    local count = 0
    for _, entry in ipairs(State.accessoryEntries) do
        if State.selectedAccessories[entry.accessory] then
            count = count + 1
        end
    end
    return count
end

local function create(className, props, parent)
    local object = Instance.new(className)
    for property, value in pairs(props or {}) do
        object[property] = value
    end
    object.Parent = parent
    return object
end

local Colors = {
    background = Color3.fromRGB(14, 16, 22),
    panel = Color3.fromRGB(18, 26, 34),
    row = Color3.fromRGB(35, 43, 57),
    accent = Color3.fromRGB(0, 170, 255),
    selected = Color3.fromRGB(32, 91, 69),
    red = Color3.fromRGB(126, 48, 58),
    text = Color3.fromRGB(243, 246, 252),
    muted = Color3.fromRGB(183, 193, 212),
}

local function round(object, radius)
    create("UICorner", { CornerRadius = UDim.new(0, radius or 8) }, object)
end

local function outline(object, color, transparency)
    create("UIStroke", {
        Color = color or Colors.accent,
        Transparency = transparency or 0.6,
        Thickness = 1,
    }, object)
end

local function makeLabel(parent, text, size, position, fontSize, color)
    return create("TextLabel", {
        Size = size,
        Position = position,
        BackgroundTransparency = 1,
        Text = text,
        TextColor3 = color or Colors.text,
        Font = Enum.Font.Gotham,
        TextSize = fontSize or 12,
        TextWrapped = true,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
    }, parent)
end

local function makeButton(parent, text, size, position, color)
    local button = create("TextButton", {
        Size = size,
        Position = position,
        BackgroundColor3 = color or Colors.row,
        BackgroundTransparency = 0.06,
        BorderSizePixel = 0,
        Text = text,
        TextColor3 = Colors.text,
        Font = Enum.Font.GothamMedium,
        TextSize = 13,
        TextWrapped = true,
        AutoButtonColor = true,
    }, parent)
    round(button, 7)
    return button
end

local function clearGuiRows(scrollingFrame)
    for _, child in ipairs(scrollingFrame:GetChildren()) do
        if child:IsA("GuiObject") and not child:IsA("UIListLayout") then
            child:Destroy()
        end
    end
end

local function refreshAccessoryList()
    State.accessoryEntries = getCurrentAccessories()
    local valid = {}
    for _, entry in ipairs(State.accessoryEntries) do
        valid[entry.accessory] = true
    end
    for accessory in pairs(State.selectedAccessories) do
        if not valid[accessory] then
            State.selectedAccessories[accessory] = nil
        end
    end

    if not State.accessoryList then
        return
    end
    clearGuiRows(State.accessoryList)

    if #State.accessoryEntries == 0 then
        makeLabel(State.accessoryList, "No wearable accessories found. Respawn or tap Refresh.", UDim2.new(1, -12, 0, 40), UDim2.new(0, 6, 0, 2), 11, Colors.muted)
        State.accessoryList.CanvasSize = UDim2.new(0, 0, 0, 44)
        return
    end

    for index, entry in ipairs(State.accessoryEntries) do
        local selected = State.selectedAccessories[entry.accessory] == true
        local button = makeButton(
            State.accessoryList,
            (selected and "✓  " or "+  ") .. entry.name .. "  ·  " .. entry.accessoryType .. (entry.parked and "  ·  ORBIT HOLD" or ""),
            UDim2.new(1, -12, 0, 32),
            UDim2.new(0, 6, 0, 4 + (index - 1) * 36),
            selected and Colors.selected or Colors.row
        )
        button.TextXAlignment = Enum.TextXAlignment.Left
        create("UIPadding", {
            PaddingLeft = UDim.new(0, 12),
            PaddingRight = UDim.new(0, 8),
        }, button)
        button.TextTruncate = Enum.TextTruncate.AtEnd
        button.TextSize = 11
        button.Activated:Connect(function()
            if State.selectedAccessories[entry.accessory] then
                State.selectedAccessories[entry.accessory] = nil
            else
                if selectedCount() >= MAX_SELECTED then
                    setStatus("Select up to " .. tostring(MAX_SELECTED) .. " accessories at once.", "error")
                    return
                end
                State.selectedAccessories[entry.accessory] = true
            end
            refreshAccessoryList()
        end)
    end
    State.accessoryList.CanvasSize = UDim2.new(0, 0, 0, #State.accessoryEntries * 36 + 4)
end

local function getTargetMatches(query)
    local targets = {}
    local q = string.lower((query or ""):match("^%s*(.-)%s*$") or "")
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer then
            local name = string.lower(player.Name)
            local display = string.lower(player.DisplayName or "")
            local rank = 99
            if q == "" then
                rank = 50
            elseif name == q or display == q then
                rank = 1
            elseif name:sub(1, #q) == q then
                rank = 2
            elseif display:sub(1, #q) == q then
                rank = 3
            elseif name:find(q, 1, true) then
                rank = 4
            elseif display:find(q, 1, true) then
                rank = 5
            end
            if rank < 99 then
                table.insert(targets, { player = player, rank = rank })
            end
        end
    end
    table.sort(targets, function(a, b)
        if a.rank ~= b.rank then
            return a.rank < b.rank
        end
        return string.lower(a.player.Name) < string.lower(b.player.Name)
    end)
    local result = {}
    for _, item in ipairs(targets) do
        table.insert(result, item.player)
    end
    return result
end

local function resolveTargetInput()
    local query = State.targetInput and State.targetInput.Text or ""
    query = string.lower((query or ""):match("^%s*(.-)%s*$") or "")
    if query == "" then
        State.target = LocalPlayer
        if State.targetLabel then
            State.targetLabel.Text = "Target: YOU (local player)"
        end
        return LocalPlayer
    end

    local matches = getTargetMatches(query)
    if #matches == 0 then
        State.target = nil
        return nil, "No player matches '" .. query .. "'."
    end

    local bestRank = 99
    local best = {}
    for _, player in ipairs(matches) do
        local name = string.lower(player.Name)
        local display = string.lower(player.DisplayName or "")
        local rank = 99
        if name == query or display == query then
            rank = 1
        elseif name:sub(1, #query) == query then
            rank = 2
        elseif display:sub(1, #query) == query then
            rank = 3
        elseif name:find(query, 1, true) then
            rank = 4
        elseif display:find(query, 1, true) then
            rank = 5
        end
        if rank < bestRank then
            bestRank = rank
            best = { player }
        elseif rank == bestRank then
            table.insert(best, player)
        end
    end

    if #best ~= 1 then
        State.target = nil
        return nil, "More than one player matches. Choose from the dropdown."
    end

    State.target = best[1]
    State.targetLabel.Text = "Target: @" .. State.target.Name
    return State.target
end

local function refreshTargetSuggestions()
    if not State.targetSuggestions or not State.targetInput then
        return
    end
    clearGuiRows(State.targetSuggestions)
    local query = State.targetInput.Text or ""
    local trimmedQuery = (query:match("^%s*(.-)%s*$") or "")
    if trimmedQuery == "" then
        State.targetSuggestions.Visible = false
        State.targetSuggestions.CanvasSize = UDim2.new(0, 0, 0, 0)
        return
    end
    local matches = getTargetMatches(query)
    local maxRows = 3
    local shown = math.min(#matches, maxRows)
    local rowHeight = 25
    local listHeight = shown > 0 and (shown * rowHeight + 4) or 27
    State.targetSuggestions.Size = UDim2.new(1, -20, 0, listHeight)
    State.targetSuggestions.CanvasSize = UDim2.new(0, 0, 0, #matches * rowHeight + 4)
    State.targetSuggestions.Visible = State.targetInput:IsFocused() and #matches > 0

    if #matches == 0 then
        return
    end

    for index = 1, math.min(#matches, 12) do
        local player = matches[index]
        local isCurrent = State.target == player
        local button = makeButton(
            State.targetSuggestions,
            (isCurrent and "✓  " or "") .. player.Name .. "  (" .. player.DisplayName .. ")",
            UDim2.new(1, -8, 0, rowHeight - 2),
            UDim2.new(0, 4, 0, 2 + (index - 1) * rowHeight),
            isCurrent and Color3.fromRGB(44, 73, 117) or Colors.row
        )
        button.ZIndex = 32
        button.TextSize = 11
        button.TextXAlignment = Enum.TextXAlignment.Left
        button.TextTruncate = Enum.TextTruncate.AtEnd
        button.Activated:Connect(function()
            State.target = player
            State.suppressTargetTextChange = true
            State.targetInput.Text = player.Name
            State.suppressTargetTextChange = false
            State.targetLabel.Text = "Target: @" .. player.Name
            State.targetSuggestions.Visible = false
        end)
    end
end

local function handleConnectedToCharacter(handle, character)
    if not handle or not character or not handle.Parent then
        return false
    end
    if handle:IsDescendantOf(character) then
        return true
    end

    -- A handle must not remain in the character's physical assembly. Check both the
    -- assembly root and recursively connected parts; this catches failed/custom weld
    -- removal before CFrame or velocity writes can pull the avatar toward the target.
    local assemblyRoot = nil
    pcall(function()
        assemblyRoot = handle.AssemblyRootPart
    end)
    if assemblyRoot and assemblyRoot:IsDescendantOf(character) then
        return true
    end

    local ok, connectedParts = pcall(function()
        return handle:GetConnectedParts(true)
    end)
    if ok and connectedParts then
        for _, part in ipairs(connectedParts) do
            if part and part:IsDescendantOf(character) then
                return true
            end
        end
    end
    return false
end

local function rollbackAccessoryDetachment(state)
    if not state then
        return
    end
    pcall(function()
        if state.accessory and state.originalParent then
            state.accessory.Parent = state.originalParent
        end
    end)
    for _, jointState in ipairs(state.joints or {}) do
        local joint = jointState.object
        if joint and jointState.parent then
            pcall(function()
                if jointState.part0 then joint.Part0 = jointState.part0 end
                if jointState.part1 then joint.Part1 = jointState.part1 end
                if jointState.c0 then joint.C0 = jointState.c0 end
                if jointState.c1 then joint.C1 = jointState.c1 end
                if jointState.enabled ~= nil then joint.Enabled = jointState.enabled end
                joint.Parent = jointState.parent
            end)
        end
    end
    for _, constraintState in ipairs(state.constraints or {}) do
        local constraint = constraintState.object
        if constraint and constraintState.parent then
            pcall(function()
                constraint.Attachment0 = constraintState.attachment0
                constraint.Attachment1 = constraintState.attachment1
                constraint.Parent = constraintState.parent
                constraint.Enabled = constraintState.enabled
            end)
        end
    end
    local handle = state.handle
    if handle and handle.Parent then
        for property, value in pairs(state.originalProperties or {}) do
            pcall(function() handle[property] = value end)
        end
        pcall(function()
            handle.AssemblyLinearVelocity = state.originalLinearVelocity or Vector3.zero
            handle.AssemblyAngularVelocity = state.originalAngularVelocity or Vector3.zero
        end)
    end
end

local function dumpAccessoryConnectionDiagnostics(accessory, handle, character)
    local prefix = "[Accessory Follower v34] DETACH DIAG: "
    local function emit(label, value)
        print(prefix .. label .. tostring(value))
    end
    local function shortName(object)
        if not object then return "nil" end
        return object.ClassName .. "(" .. object.Name .. ")"
    end

    emit("Accessory=", accessory:GetFullName())
    emit("Handle=", handle:GetFullName())
    emit("Handle direct children=", (function()
        local out = {}
        for _, child in ipairs(handle:GetChildren()) do
            table.insert(out, shortName(child))
        end
        return #out > 0 and table.concat(out, ", ") or "<none>"
    end)())

    local okParts, connectedParts = pcall(function()
        return handle:GetConnectedParts(true)
    end)
    if okParts then
        local out = {}
        for i, part in ipairs(connectedParts) do
            if i > 20 then
                table.insert(out, "...")
                break
            end
            table.insert(out, part:GetFullName())
        end
        emit("Handle connected parts=", #out > 0 and table.concat(out, " | ") or "<none>")
    else
        emit("GetConnectedParts failed=", connectedParts)
    end

    local jointCount, constraintCount = 0, 0
    for _, object in ipairs(character:GetDescendants()) do
        if object:IsA("JointInstance") or object:IsA("WeldConstraint") then
            local ok, part0, part1 = pcall(function()
                return object.Part0, object.Part1
            end)
            if ok and ((part0 and part0:IsDescendantOf(accessory)) or (part1 and part1:IsDescendantOf(accessory))) then
                jointCount = jointCount + 1
                emit("Accessory-related joint=", shortName(object) .. " parent=" .. object.Parent:GetFullName()
                    .. " Part0=" .. (part0 and part0:GetFullName() or "nil")
                    .. " Part1=" .. (part1 and part1:GetFullName() or "nil"))
            end
        elseif object:IsA("Constraint") then
            local ok, a0, a1 = pcall(function()
                return object.Attachment0, object.Attachment1
            end)
            if ok and ((a0 and a0:IsDescendantOf(accessory)) or (a1 and a1:IsDescendantOf(accessory))) then
                constraintCount = constraintCount + 1
                emit("Accessory-related constraint=", shortName(object)
                    .. " Attachment0=" .. (a0 and a0:GetFullName() or "nil")
                    .. " Attachment1=" .. (a1 and a1:GetFullName() or "nil"))
            end
        end
    end
    emit("Accessory-related joint count=", jointCount)
    emit("Accessory-related constraint count=", constraintCount)

    local attachmentNames = {}
    for _, object in ipairs(accessory:GetDescendants()) do
        if object:IsA("Attachment") then
            table.insert(attachmentNames, object.Name .. " @ " .. object.Parent:GetFullName())
        end
    end
    emit("Accessory attachments=", #attachmentNames > 0 and table.concat(attachmentNames, " | ") or "<none>")
end

local function rigidConstraintConnectsHandleToCharacter(constraint, handle, character)
    if not constraint or not handle or not character or not constraint:IsA("RigidConstraint") then
        return false
    end
    local ok, attachment0, attachment1 = pcall(function()
        return constraint.Attachment0, constraint.Attachment1
    end)
    if not ok or not attachment0 or not attachment1 then
        return false
    end
    local parent0 = attachment0.Parent
    local parent1 = attachment1.Parent
    local handleSide = parent0 == handle or (parent0 and parent0:IsDescendantOf(handle))
    local characterSide = parent1 and parent1:IsDescendantOf(character) and not parent1:IsDescendantOf(handle)
    if handleSide and characterSide then
        return true
    end
    handleSide = parent1 == handle or (parent1 and parent1:IsDescendantOf(handle))
    characterSide = parent0 and parent0:IsDescendantOf(character) and not parent0:IsDescendantOf(handle)
    return handleSide and characterSide or false
end

local function makeAccessoryState(accessory)
    local character = LocalPlayer.Character
    if not character or not accessory or not accessory:IsDescendantOf(character) then
        return nil, "That accessory is no longer equipped. Refresh the list."
    end
    local handle = accessory:FindFirstChild("Handle")
    if not handle or not handle:IsA("BasePart") then
        return nil, "Accessory has no usable Handle."
    end

    local state = {
        accessory = accessory,
        handle = handle,
        originalParent = accessory.Parent,
        originalCharacter = character,
        originalCFrame = handle.CFrame,
        originalProperties = {},
        joints = {},
        constraints = {},
        originalLinearVelocity = handle.AssemblyLinearVelocity,
        originalAngularVelocity = handle.AssemblyAngularVelocity,
    }

    local props = { "Anchored", "CanCollide", "CanTouch", "CanQuery", "Massless", "Transparency", "LocalTransparencyModifier" }
    for _, property in ipairs(props) do
        pcall(function()
            state.originalProperties[property] = handle[property]
        end)
    end

    for _, object in ipairs(character:GetDescendants()) do
        local isJoint = object:IsA("JointInstance") or object:IsA("WeldConstraint")
        if isJoint then
            local ok, part0, part1 = pcall(function()
                return object.Part0, object.Part1
            end)
            if ok and (part0 == handle or part1 == handle) then
                local jointState = {
                    object = object,
                    parent = object.Parent,
                    className = object.ClassName,
                    name = object.Name,
                }
                pcall(function()
                    jointState.part0 = object.Part0
                    jointState.part1 = object.Part1
                end)
                pcall(function()
                    jointState.c0 = object.C0
                    jointState.c1 = object.C1
                    jointState.enabled = object.Enabled
                end)
                table.insert(state.joints, jointState)
                pcall(function()
                    object.Parent = nil
                end)
            end
        end
    end

    -- Newer avatar accessories can use RigidConstraint + Attachments instead of
    -- Weld/Motor6D. Save and disable only constraints that directly join this Handle
    -- to a body part; never disable constraints joining it to unrelated accessories.
    for _, object in ipairs(character:GetDescendants()) do
        if object:IsA("RigidConstraint") and rigidConstraintConnectsHandleToCharacter(object, handle, character) then
            local enabled = true
            pcall(function() enabled = object.Enabled end)
            if enabled then
                local constraintState = {
                    object = object,
                    parent = object.Parent,
                    attachment0 = object.Attachment0,
                    attachment1 = object.Attachment1,
                    enabled = enabled,
                    name = object.Name,
                }
                table.insert(state.constraints, constraintState)
                print("[Accessory Follower v34] Using RigidConstraint detach path: " .. object:GetFullName())
                local disabled = pcall(function() object.Enabled = false end)
                if not disabled then
                    rollbackAccessoryDetachment(state)
                    return nil, "Safety stop: could not disable the accessory RigidConstraint for " .. accessory.Name .. ". Nothing was moved."
                end
            end
        end
    end

    if #state.joints == 0 and #state.constraints == 0 then
        -- Fail closed, but print the actual connection topology so a compatible path can
        -- be implemented from evidence instead of guessing at the game's rig.
        dumpAccessoryConnectionDiagnostics(accessory, handle, character)
        return nil, "Safety stop: no removable accessory joint or RigidConstraint was found for " .. accessory.Name .. ". Detailed connection diagnostics were printed to the console; nothing was moved."
    end

    for _, jointState in ipairs(state.joints) do
        local joint = jointState.object
        if joint and joint.Parent ~= nil then
            rollbackAccessoryDetachment(state)
            return nil, "Safety stop: the accessory joint could not be detached for " .. accessory.Name .. ". Nothing will be moved."
        end
    end
    for _, constraintState in ipairs(state.constraints) do
        local constraint = constraintState.object
        if constraint and constraint.Enabled then
            rollbackAccessoryDetachment(state)
            return nil, "Safety stop: the accessory RigidConstraint remained enabled for " .. accessory.Name .. ". Nothing will be moved."
        end
    end

    local moved, moveError = pcall(function()
        accessory.Parent = workspace
        handle.Anchored = false
        handle.CanCollide = false
        handle.CanTouch = false
        pcall(function() handle.CanQuery = false end)
        handle.Massless = true
    end)

    if not moved then
        rollbackAccessoryDetachment(state)
        return nil, "Could not detach " .. accessory.Name .. ": " .. tostring(moveError)
    end

    -- Verify physical separation before applying the legacy velocity. Some experiences
    -- recreate a weld or use a custom connection when an accessory is reparented.
    if handleConnectedToCharacter(handle, character) then
        rollbackAccessoryDetachment(state)
        return nil, "Safety stop: " .. accessory.Name .. " is still connected to your character in this game. Follow was blocked to prevent your whole avatar moving."
    end

    local velocityOk = pcall(function()
        handle.AssemblyLinearVelocity = SOURCE_VELOCITY
        handle.AssemblyAngularVelocity = Vector3.zero
    end)
    if not velocityOk or handleConnectedToCharacter(handle, character) then
        rollbackAccessoryDetachment(state)
        return nil, "Safety stop: " .. accessory.Name .. " failed the final separation check. Follow was blocked."
    end

    return state
end

local function jointConnectsHandle(joint, handle)
    if not joint or not handle then
        return false
    end
    local ok, part0, part1 = pcall(function()
        return joint.Part0, joint.Part1
    end)
    return ok and (part0 == handle or part1 == handle)
end

local function hasCharacterAccessoryJoint(character, handle, accessory)
    if not character or not handle or not accessory then
        return false
    end
    -- Checking for a joint alone can produce a false positive: a saved joint may be
    -- parented under a body part while the accessory itself is still in Workspace.
    if accessory.Parent ~= character or not handle:IsDescendantOf(character) then
        return false
    end
    for _, object in ipairs(character:GetDescendants()) do
        if (object:IsA("JointInstance") or object:IsA("WeldConstraint")) and jointConnectsHandle(object, handle) then
            local ok, part0, part1 = pcall(function()
                return object.Part0, object.Part1
            end)
            if ok then
                local other = part0 == handle and part1 or part0
                if other and other:IsA("BasePart") and other ~= handle and other:IsDescendantOf(character) then
                    local enabled = true
                    pcall(function()
                        enabled = object.Enabled
                    end)
                    if enabled then
                        return true
                    end
                end
            end
        elseif object:IsA("RigidConstraint") and rigidConstraintConnectsHandleToCharacter(object, handle, character) then
            local enabled = false
            pcall(function() enabled = object.Enabled end)
            if enabled then
                return true
            end
        end
    end
    return false
end

local function restoreHandleProperties(state)
    local handle = state.handle
    if handle and handle.Parent then
        for property, value in pairs(state.originalProperties or {}) do
            pcall(function()
                handle[property] = value
            end)
        end
        pcall(function()
            handle.AssemblyLinearVelocity = Vector3.zero
            handle.AssemblyAngularVelocity = Vector3.zero
        end)
    end
end

local function chooseJointParent(jointState, character, handle)
    local parent = jointState.parent
    if parent == handle then
        return handle
    end
    if parent then
        local isCharacterDescendant = false
        pcall(function()
            isCharacterDescendant = parent:IsDescendantOf(character)
        end)
        if isCharacterDescendant then
            return parent
        end
    end
    return handle
end

local function configureJointFromSnapshot(joint, jointState, character, handle, parent)
    local part0 = jointState.part0
    local part1 = jointState.part1
    if part0 ~= handle and (not part0 or not part0:IsDescendantOf(character)) then
        return false
    end
    if part1 ~= handle and (not part1 or not part1:IsDescendantOf(character)) then
        return false
    end
    if part0 == handle and part1 == handle then
        return false
    end

    local ok = pcall(function()
        joint.Part0 = part0
        joint.Part1 = part1
        if jointState.c0 then joint.C0 = jointState.c0 end
        if jointState.c1 then joint.C1 = jointState.c1 end
        if jointState.enabled ~= nil then joint.Enabled = jointState.enabled end
        joint.Parent = parent
    end)
    if not ok then
        return false
    end
    return joint.Parent == parent and jointConnectsHandle(joint, handle)
end

local function restoreOriginalJoints(state, character, handle)
    local restoredCount = 0
    local jointCount = #(state.joints or {})
    for _, jointState in ipairs(state.joints or {}) do
        local jointParent = chooseJointParent(jointState, character, handle)
        local joint = jointState.object
        local restored = false
        if joint then
            restored = configureJointFromSnapshot(joint, jointState, character, handle, jointParent)
        end

        -- If Roblox removed the old joint while the accessory was moved out of the
        -- character, recreate the same joint type and saved endpoints/offsets.
        if not restored then
            local className = jointState.className
            if className == "Weld" or className == "WeldConstraint" or className == "Motor6D" then
                local ok, replacement = pcall(function()
                    return Instance.new(className)
                end)
                if ok and replacement then
                    replacement.Name = jointState.name or "AccessoryWeld"
                    if configureJointFromSnapshot(replacement, jointState, character, handle, jointParent) then
                        jointState.replacement = replacement
                        restored = true
                    else
                        pcall(function() replacement:Destroy() end)
                    end
                end
            end
        end
        jointState.restored = restored
        if restored then
            restoredCount = restoredCount + 1
        end
    end
    local fullyRestored = jointCount > 0 and restoredCount == jointCount
        and hasCharacterAccessoryJoint(character, handle, state.accessory)
    if fullyRestored then
        return true
    end

    -- Do not leave a partial set of original joints active while trying the native
    -- attachment fallback; duplicate/partial joints can pin the Handle in place.
    for _, jointState in ipairs(state.joints or {}) do
        if jointState.restored then
            local candidate = jointState.replacement or jointState.object
            if candidate then
                pcall(function() candidate.Parent = nil end)
            end
            jointState.restored = false
        end
    end
    return false
end

local function findMatchingAccessoryAttachments(character, accessory, handle)
    if not character or not accessory or not handle then
        return nil
    end

    local handleAttachments = {}
    for _, object in ipairs(handle:GetDescendants()) do
        if object:IsA("Attachment") then
            table.insert(handleAttachments, object)
        end
    end
    if #handleAttachments == 0 then
        return nil
    end

    for _, handleAttachment in ipairs(handleAttachments) do
        for _, object in ipairs(character:GetDescendants()) do
            local insideAnyAccessory = false
            local ancestor = object
            while ancestor and ancestor ~= character do
                if ancestor:IsA("Accessory") then
                    insideAnyAccessory = true
                    break
                end
                ancestor = ancestor.Parent
            end
            -- Only match against the avatar's body parts, never another accessory's
            -- Handle. Other equipped accessories may contain identically named
            -- Attachments and would otherwise become an accidental attachment target.
            if object:IsA("BasePart") and object ~= handle and not insideAnyAccessory then
                for _, bodyAttachment in ipairs(object:GetChildren()) do
                    if bodyAttachment:IsA("Attachment") and bodyAttachment.Name == handleAttachment.Name then
                        return {
                            bodyPart = object,
                            bodyAttachment = bodyAttachment,
                            handleAttachment = handleAttachment,
                        }
                    end
                end
            end
        end
    end
    return nil
end

local function removeActiveHandleJoints(character, handle)
    -- When Roblox recreates a default AccessoryWeld during reparenting, remove it
    -- before creating our own precisely-offset weld. Duplicate active welds can pin
    -- the handle between two different offsets.
    for _, object in ipairs(character:GetDescendants()) do
        local isJoint = object:IsA("JointInstance") or object:IsA("WeldConstraint")
        if isJoint and jointConnectsHandle(object, handle) then
            pcall(function()
                object:Destroy()
            end)
        end
    end
end

local function tryAttachmentWeld(character, accessory, handle)
    -- Prefer reconstructing the standard accessory attachment relationship. This
    -- gives the handle a fresh live weld, rather than trusting a joint whose parent
    -- and physics assembly changed while the accessory was in Workspace.
    local pair = findMatchingAccessoryAttachments(character, accessory, handle)
    if not pair then
        return false, nil
    end

    local bodyPart = pair.bodyPart
    local bodyAttachment = pair.bodyAttachment
    local handleAttachment = pair.handleAttachment
    if not bodyPart or not bodyPart.Parent or not bodyAttachment.Parent or not handleAttachment.Parent then
        return false, nil
    end

    local targetCFrame = bodyPart.CFrame * bodyAttachment.CFrame * handleAttachment.CFrame:Inverse()
    local positioned = pcall(function()
        handle.CFrame = targetCFrame
        handle.AssemblyLinearVelocity = Vector3.zero
        handle.AssemblyAngularVelocity = Vector3.zero
    end)
    if not positioned then
        return false, nil
    end

    removeActiveHandleJoints(character, handle)
    local weld = Instance.new("Weld")
    weld.Name = "AccessoryWeld"
    weld.Part0 = bodyPart
    weld.Part1 = handle
    weld.C0 = bodyAttachment.CFrame
    weld.C1 = handleAttachment.CFrame
    weld.Parent = handle

    if hasCharacterAccessoryJoint(character, handle, accessory) then
        return true, weld, pair
    end
    pcall(function() weld:Destroy() end)
    return false, nil
end

local function isRestoredAndAligned(state, character)
    local accessory = state and state.accessory
    local handle = state and state.handle
    if not character or not accessory or not handle then
        return false
    end
    if accessory.Parent ~= character or not handle:IsDescendantOf(character) then
        return false
    end
    if not hasCharacterAccessoryJoint(character, handle, accessory) then
        return false
    end

    local pair = findMatchingAccessoryAttachments(character, accessory, handle)
    if pair then
        local expected = pair.bodyPart.CFrame * pair.bodyAttachment.CFrame * pair.handleAttachment.CFrame:Inverse()
        if (handle.Position - expected.Position).Magnitude > 1.25 then
            return false
        end
        if handle.CFrame.LookVector:Dot(expected.LookVector) < 0.78 then
            return false
        end
        return true
    end

    -- For older accessories without matching Attachment objects, validate the saved
    -- weld transform where possible. A joint existing by itself is not proof that the
    -- handle is actually moving with its character body part.
    for _, object in ipairs(character:GetDescendants()) do
        if (object:IsA("JointInstance") or object:IsA("WeldConstraint")) and jointConnectsHandle(object, handle) then
            if object:IsA("JointInstance") then
                local ok, part0, part1, c0, c1 = pcall(function()
                    return object.Part0, object.Part1, object.C0, object.C1
                end)
                if ok and part0 and part1 and c0 and c1 then
                    local expected
                    if part1 == handle then
                        expected = part0.CFrame * c0 * c1:Inverse()
                    elseif part0 == handle then
                        expected = part1.CFrame * c1 * c0:Inverse()
                    end
                    if expected and (handle.Position - expected.Position).Magnitude > 1.25 then
                        return false
                    end
                end
            end
            return true
        end
    end
    return false
end

local function cleanupDetachedOriginalJoints(state)
    for _, jointState in ipairs(state.joints or {}) do
        local joint = jointState.object
        if joint and not joint.Parent then
            pcall(function() joint:Destroy() end)
        end
    end
end

local function restoreItem(state)
    if not state then
        return false, "missing"
    end
    local accessory = state.accessory
    local handle = state.handle
    if not accessory or not handle then
        return false, "missing"
    end

    local character = state.originalCharacter
    if not character or not character.Parent or character ~= LocalPlayer.Character then
        character = LocalPlayer.Character
    end
    if not character then
        return false, "no-character"
    end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local originalParent = state.originalParent
    local originalParentValid = originalParent == character
    if originalParent and not originalParentValid then
        pcall(function()
            originalParentValid = originalParent:IsDescendantOf(character)
        end)
    end
    if not originalParent or not originalParentValid then
        originalParent = character
    end

    -- Stop Follow's Heartbeat before calling this routine. Parent the Accessory first,
    -- then prefer a fresh matching-attachment weld instead of trusting a possibly stale
    -- joint object from the detached Workspace assembly.
    local parented = pcall(function()
        accessory.Parent = originalParent
    end)
    if not parented or accessory.Parent ~= character or not handle:IsDescendantOf(character) then
        pcall(function() accessory.Parent = character end)
    end
    if accessory.Parent ~= character or not handle:IsDescendantOf(character) then
        return false, "parent-failed"
    end

    pcall(function()
        handle.Anchored = false
    end)

    -- Restore native RigidConstraint accessories directly before attempting a new Weld.
    -- This avoids leaving the game's original attachment constraint disabled or creating
    -- two competing physical connections for the same Handle.
    if #(state.constraints or {}) > 0 then
        local constraintRestored = false
        local pair = findMatchingAccessoryAttachments(character, accessory, handle)
        if pair then
            pcall(function()
                handle.CFrame = pair.bodyPart.CFrame * pair.bodyAttachment.CFrame * pair.handleAttachment.CFrame:Inverse()
            end)
        end
        for _, constraintState in ipairs(state.constraints) do
            local constraint = constraintState.object
            if constraint and constraint.Parent then
                local ok = pcall(function()
                    constraint.Attachment0 = constraintState.attachment0
                    constraint.Attachment1 = constraintState.attachment1
                    constraint.Enabled = constraintState.enabled
                end)
                if ok and constraintState.enabled then
                    constraintRestored = true
                end
            end
        end
        if constraintRestored and hasCharacterAccessoryJoint(character, handle, accessory) and isRestoredAndAligned(state, character) then
            restoreHandleProperties(state)
            return true, "original-rigid-constraint"
        end
        -- If native restoration did not verify, disable it again before any fallback weld.
        for _, constraintState in ipairs(state.constraints) do
            local constraint = constraintState.object
            if constraint then pcall(function() constraint.Enabled = false end) end
        end
    end

    local attachmentAttached = false
    local attachmentWeld = nil
    local attachmentPair = findMatchingAccessoryAttachments(character, accessory, handle)
    if attachmentPair then
        attachmentAttached, attachmentWeld = tryAttachmentWeld(character, accessory, handle)
        if attachmentAttached and isRestoredAndAligned(state, character) then
            state.restoredWeld = attachmentWeld
            state.restoredAttachmentPair = attachmentPair
            restoreHandleProperties(state)
            cleanupDetachedOriginalJoints(state)
            return true, "fresh-attachment-weld"
        end
        if attachmentWeld then
            pcall(function() attachmentWeld:Destroy() end)
        end
    end

    -- Fallback for classic accessories which do not provide matching Attachment names.
    pcall(function()
        handle.CFrame = state.originalCFrame
        handle.AssemblyLinearVelocity = Vector3.zero
        handle.AssemblyAngularVelocity = Vector3.zero
    end)
    local originalJointRestore = restoreOriginalJoints(state, character, handle)
    if originalJointRestore and isRestoredAndAligned(state, character) then
        restoreHandleProperties(state)
        cleanupDetachedOriginalJoints(state)
        return true, "original-joint"
    end

    -- Roblox documents that client-side AddAccessory calls may not always create the
    -- intended weld. Keep this as a fallback, then explicitly rebuild the matching weld.
    if humanoid then
        local nativeOk = pcall(function()
            accessory.Parent = nil
            humanoid:AddAccessory(accessory)
        end)
        if nativeOk and accessory.Parent == character and handle:IsDescendantOf(character) then
            local nativeAttached = hasCharacterAccessoryJoint(character, handle, accessory)
            if nativeAttached and isRestoredAndAligned(state, character) then
                restoreHandleProperties(state)
                cleanupDetachedOriginalJoints(state)
                return true, "native"
            end
        end
    end

    if accessory.Parent ~= character then
        pcall(function() accessory.Parent = character end)
    end
    if accessory.Parent == character and handle:IsDescendantOf(character) then
        attachmentAttached, attachmentWeld = tryAttachmentWeld(character, accessory, handle)
        if attachmentAttached and isRestoredAndAligned(state, character) then
            state.restoredWeld = attachmentWeld
            restoreHandleProperties(state)
            cleanupDetachedOriginalJoints(state)
            return true, "attachment-rebuilt"
        end
        if attachmentWeld then
            pcall(function() attachmentWeld:Destroy() end)
        end
    end

    restoreHandleProperties(state)
    local fallbackAttached = isRestoredAndAligned(state, character)
    if fallbackAttached then
        cleanupDetachedOriginalJoints(state)
        return true, "fallback"
    end
    -- Keep saved detached joints intact after a failed restoration attempt so the
    -- post-restore guard can retry instead of destroying its own recovery data.
    return false, "fallback"
end

local function stopRestoreGuard()
    safeDisconnect(State.restoreGuardConnection)
    State.restoreGuardConnection = nil
    State.restoreGuardItems = {}
    State.restoreGuardClock = 0
end

local function startRestoreGuard(items)
    stopRestoreGuard()
    if not State.alive or not items or #items == 0 then
        return
    end
    for _, item in ipairs(items) do
        item.restoreGuardFailures = 0
        table.insert(State.restoreGuardItems, item)
    end

    State.restoreGuardConnection = RunService.Heartbeat:Connect(function(deltaTime)
        if not State.alive then
            stopRestoreGuard()
            return
        end
        if #State.activeItems > 0 then
            stopRestoreGuard()
            return
        end
        State.restoreGuardClock = State.restoreGuardClock + deltaTime
        if State.restoreGuardClock < 0.25 then
            return
        end
        State.restoreGuardClock = 0

        local character = LocalPlayer.Character
        if not character then
            return
        end
        local remaining = {}
        local recoveredAny = false
        local newlyDetected = false
        local gaveUp = false
        for _, item in ipairs(State.restoreGuardItems) do
            local accessory = item.accessory
            local handle = item.handle
            if accessory and handle and isRestoredAndAligned(item, character) then
                item.restoreGuardFailures = 0
                table.insert(remaining, item)
            elseif accessory and handle and item.restoreGuardFailures < 12 then
                if item.restoreGuardFailures == 0 then
                    newlyDetected = true
                end
                item.restoreGuardFailures = item.restoreGuardFailures + 1
                local recovered = restoreItem(item)
                table.insert(remaining, item)
                if recovered then
                    recoveredAny = true
                end
            else
                -- A game may destroy/reclaim the instance or reject repeated client-side
                -- restoration. Stop retrying this item rather than fighting forever.
                gaveUp = true
            end
        end
        State.restoreGuardItems = remaining
        if gaveUp then
            setStatus("Restore retries exhausted for an accessory. The game may reject client-side reattachment; respawn may be required.", "error")
        elseif recoveredAny then
            setStatus("Recovered an accessory attachment after it shifted.", "success")
        elseif newlyDetected then
            setStatus("An accessory shifted after restore; checking its attachment…", "info")
        end
        if #State.restoreGuardItems == 0 then
            stopRestoreGuard()
        end
    end)
end

local startParkKeeper

local function advanceMotion(deltaTime)
    local dt = math.max(0, math.min(tonumber(deltaTime) or 0, 0.1))
    -- Integrate phase rather than multiplying absolute time by speed. This preserves the
    -- exact current orbit phase when the user changes speed while accessories are moving.
    State.orbitAngle = (State.orbitAngle + dt * PARK_ORBIT_SPEED * State.orbitSpeed) % (math.pi * 2000)
    State.orbitBobAngle = (State.orbitBobAngle + dt * PARK_ORBIT_BOB_SPEED * State.orbitSpeed) % (math.pi * 2000)
    -- Exponential easing blends the requested distance into the live orbit/formation.
    local blend = 1 - math.exp(-math.max(0, dt) * 5)
    State.currentDistance = State.currentDistance + (State.distance - State.currentDistance) * blend
    if math.abs(State.distance - State.currentDistance) < 0.001 then
        State.currentDistance = State.distance
    end

    -- Smoothly blend orbit-style weights. Starting a new transition copies the current
    -- weights first, so changing styles again mid-transition does not snap.
    if State.orbitStyleElapsed < State.orbitStyleDuration then
        State.orbitStyleElapsed = math.min(State.orbitStyleDuration, State.orbitStyleElapsed + dt)
        local t = State.orbitStyleElapsed / math.max(State.orbitStyleDuration, 0.001)
        local blend = t * t * (3 - 2 * t)
        for styleIndex = 1, 3 do
            local startWeight = State.orbitStyleStartWeights[styleIndex] or 0
            local targetWeight = styleIndex == State.orbitStyleTarget and 1 or 0
            State.orbitStyleWeights[styleIndex] = startWeight * (1 - blend) + targetWeight * blend
        end
        if t >= 1 then
            State.orbitStyleWeights[1] = State.orbitStyleTarget == 1 and 1 or 0
            State.orbitStyleWeights[2] = State.orbitStyleTarget == 2 and 1 or 0
            State.orbitStyleWeights[3] = State.orbitStyleTarget == 3 and 1 or 0
        end
    end
end

local function calculateParkingOffset(slot)
    -- Initial placement only; the heartbeat immediately begins the continuously moving orbit.
    local parkIndex = math.max(1, tonumber(slot) or 1)
    local phase = ((parkIndex - 1) % MAX_SELECTED) * (math.pi * 2 / MAX_SELECTED)
    local angle = State.orbitAngle + phase
    local row = math.floor((parkIndex - 1) / 4)
    local radius = PARK_ORBIT_RADIUS + ((parkIndex - 1) % 2) * 0.45 + math.sin(angle * 0.55 + phase) * PARK_ORBIT_PULSE
    local bob = math.sin(State.orbitBobAngle + phase) * PARK_ORBIT_BOB_AMPLITUDE
    local wave = math.sin(angle * 1.35 + phase) * PARK_ORBIT_WAVE
    return CFrame.new(math.cos(angle) * radius, PARK_ORBIT_HEIGHT + row * 0.85 + bob + wave, math.sin(angle) * radius)
end

local function calculateParkingOrbit(item, index, total, baseCFrame, now)
    if not baseCFrame then
        return nil
    end
    local safeTotal = math.max(1, tonumber(total) or 1)
    local safeIndex = math.max(1, tonumber(index) or 1)
    local phase = ((safeIndex - 1) / safeTotal) * math.pi * 2
    local angle = State.orbitAngle + phase
    local bobPhase = State.orbitBobAngle + phase
    local row = math.floor((safeIndex - 1) / 4)
    local radius = PARK_ORBIT_RADIUS + ((safeIndex - 1) % 2) * 0.45 + math.sin(angle * 0.55 + phase) * PARK_ORBIT_PULSE
    local bob = math.sin(bobPhase) * PARK_ORBIT_BOB_AMPLITUDE
    local wave = math.sin(angle * 1.35 + phase) * PARK_ORBIT_WAVE
    local offset = CFrame.new(
        math.cos(angle) * radius,
        PARK_ORBIT_HEIGHT + row * 0.85 + bob + wave,
        math.sin(angle) * radius
    )
    return baseCFrame * offset
end

local function parkItem(item, slot)
    if not item then
        return false, "missing state"
    end
    local accessory = item.accessory
    local handle = item.handle
    if not accessory or not handle or not handle.Parent then
        return false, "accessory handle no longer exists"
    end

    -- Do not force an instance back into Workspace if the experience has reparented it.
    -- That can fight the server and turn a recoverable re-equip into a lost object.
    if accessory.Parent ~= workspace then
        if LocalPlayer.Character and accessory:IsDescendantOf(LocalPlayer.Character) then
            removeParkedItem(item)
            return false, "the experience re-equipped this accessory; it was left in place"
        end
        return false, "the experience reparented this accessory; it was left untouched"
    end

    local root = getRoot(LocalPlayer)
    local parkIndex = math.max(1, tonumber(slot) or (#State.parkedItems + 1))
    local parkingOffset = calculateParkingOffset(parkIndex)
    local baseCFrame = root and root.CFrame or item.parkOrbitBaseCFrame
    if not baseCFrame then
        baseCFrame = CFrame.new(handle.Position - Vector3.new(0, PARK_ORBIT_HEIGHT, 0))
    end
    local parkingCFrame = calculateParkingOrbit(
        item,
        parkIndex,
        math.max(#State.parkedItems + 1, 1),
        baseCFrame,
        os.clock()
    ) or (baseCFrame * parkingOffset)

    local ok, err = pcall(function()
        -- Regression fix: never anchor while parked. Anchored BaseParts are server-owned;
        -- unanchoring resets ownership to automatic, which can break the next follow.
        -- For legacy v9-anchored items, unanchor once as a migration and immediately
        -- place them back into the live hold.
        if handle.Anchored then
            handle.Anchored = false
        end
        handle.CanCollide = false
        handle.CanTouch = false
        pcall(function() handle.CanQuery = false end)
        handle.Massless = true
        handle.CFrame = parkingCFrame
        -- Reuse the known-working follow velocity rather than zeroing the part or
        -- switching to a lower tangential velocity during the orbit hold.
        handle.AssemblyLinearVelocity = SOURCE_VELOCITY
        handle.AssemblyAngularVelocity = Vector3.zero
    end)
    if not ok then
        return false, tostring(err)
    end

    item.parkedOffset = parkingOffset
    item.parkedCFrame = parkingCFrame
    item.parkOrbitBaseCFrame = baseCFrame
    item.parkedAt = os.clock()
    addParkedItem(item)
    if startParkKeeper then
        startParkKeeper()
    end
    return true
end

local function unparkItem(item, targetCFrame)
    if not item or not item.accessory or not item.handle or not item.handle.Parent then
        return false, "parked accessory is no longer available"
    end
    local accessory = item.accessory
    local handle = item.handle
    if accessory.Parent ~= workspace then
        removeParkedItem(item)
        return false, "parked accessory was reparented by the experience; refresh the accessory list"
    end

    local ok, err = pcall(function()
        -- Keep the parked instance in Workspace; do not reparent or remove/rebuild joints
        -- during an ordinary PARK -> FOLLOW transition.
        if handle.Anchored then
            handle.Anchored = false
        end
        if targetCFrame then
            handle.CFrame = targetCFrame
        elseif item.parkedCFrame then
            handle.CFrame = item.parkedCFrame
        end
        handle.CanCollide = false
        handle.CanTouch = false
        pcall(function() handle.CanQuery = false end)
        handle.Massless = true
        handle.AssemblyAngularVelocity = Vector3.zero
        handle.AssemblyLinearVelocity = SOURCE_VELOCITY
    end)
    if not ok then
        return false, tostring(err)
    end
    removeParkedItem(item)
    return true
end

startParkKeeper = function()
    if not State.alive or State.parkedHeartbeatConnection then
        return
    end
    if #State.parkedItems == 0 then
        return
    end

    State.parkClaimClock = 0
    State.parkedHeartbeatConnection = RunService.Heartbeat:Connect(function(deltaTime)
        if not State.alive or #State.parkedItems == 0 then
            safeDisconnect(State.parkedHeartbeatConnection)
            State.parkedHeartbeatConnection = nil
            return
        end

        advanceMotion(deltaTime)
        State.parkClaimClock = State.parkClaimClock + (deltaTime or 0)
        if State.parkClaimClock >= 1 then
            State.parkClaimClock = 0
            claimSimulationRadius()
        end

        local root = getRoot(LocalPlayer)
        local currentBaseCFrame = root and root.CFrame or nil
        local now = os.clock()
        local total = #State.parkedItems
        for index = #State.parkedItems, 1, -1 do
            local item = State.parkedItems[index]
            local accessory = item and item.accessory
            local handle = item and item.handle
            if not accessory or not handle or not handle.Parent or not accessory.Parent then
                if item then item.parked = false end
                table.remove(State.parkedItems, index)
            elseif accessory.Parent ~= workspace then
                -- If the experience reclaimed/re-equipped it, stop treating it as parked.
                -- Never continually force a server-reparented instance back into Workspace.
                item.parked = false
                table.remove(State.parkedItems, index)
            else
                pcall(function()
                    -- Keep detached handles unanchored but actively orbiting in open air.
                    -- A moving CFrame plus the known-working follow velocity avoids restoring
                    -- the static/zero-velocity state that could go to sleep and then fall.
                    if handle.Anchored then
                        handle.Anchored = false
                    end
                    local baseCFrame = currentBaseCFrame or item.parkOrbitBaseCFrame
                    if not baseCFrame then
                        baseCFrame = CFrame.new(handle.Position - Vector3.new(0, PARK_ORBIT_HEIGHT, 0))
                    end
                    if currentBaseCFrame then
                        item.parkOrbitBaseCFrame = currentBaseCFrame
                    end
                    local orbitCFrame = calculateParkingOrbit(item, index, total, baseCFrame, now)
                    if orbitCFrame then
                        handle.CFrame = orbitCFrame
                        item.parkedCFrame = orbitCFrame
                    end
                    -- Match the same source velocity used by the working follow loop.
                    -- A changing orbit position plus this established velocity is a
                    -- closer analogue to the tested follow path than setting velocity to zero.
                    handle.AssemblyLinearVelocity = SOURCE_VELOCITY
                    handle.AssemblyAngularVelocity = Vector3.zero
                end)
            end
        end
    end)
end

local function stopFollowing(message, suppressRestoreGuard)
    safeDisconnect(State.heartbeatConnection)
    State.heartbeatConnection = nil
    stopRestoreGuard()

    local items = State.activeItems
    State.activeItems = {}
    local parkedCount = 0
    local total = #items
    local failures = 0
    for index, item in ipairs(items) do
        local ok = parkItem(item, #State.parkedItems + 1)
        if ok then
            parkedCount = parkedCount + 1
        else
            failures = failures + 1
        end
    end

    if State.startButton then
        State.startButton.Text = "START FOLLOW"
        State.startButton.BackgroundColor3 = Colors.selected
    end

    if message then
        if total == 0 then
            setStatus("No active follow. Detached accessories orbit above you while this script stays active.", "info")
        elseif failures == 0 then
            setStatus("Stopped. Orbit-holding " .. tostring(parkedCount) .. " accessories above you; select a target and START FOLLOW to reuse them.", "success")
        else
            setStatus("Stopped. Orbit-holding " .. tostring(parkedCount) .. "/" .. tostring(total) .. " accessories; " .. tostring(failures) .. " were reclaimed or unavailable.", "error")
        end
    end
    if State.accessoryList and State.alive then
        refreshAccessoryList()
    end
end

local function emergencyRestoreAll(message)
    -- Unlike normal STOP, a safety stop must never park/reposition a handle that may
    -- still be physically connected to the local avatar.
    safeDisconnect(State.heartbeatConnection)
    State.heartbeatConnection = nil
    safeDisconnect(State.parkedHeartbeatConnection)
    State.parkedHeartbeatConnection = nil
    stopRestoreGuard()

    local restoreItems = {}
    local seen = {}
    for _, list in ipairs({ State.activeItems, State.parkedItems }) do
        for _, item in ipairs(list) do
            if item and item.accessory and not seen[item.accessory] then
                seen[item.accessory] = true
                table.insert(restoreItems, item)
            end
        end
    end
    State.activeItems = {}
    State.parkedItems = {}
    env[PARKED_KEY] = State.parkedItems

    local restored, failed = 0, 0
    for _, item in ipairs(restoreItems) do
        local ok, result = pcall(restoreItem, item)
        if ok and result then
            restored = restored + 1
        else
            failed = failed + 1
        end
    end

    if State.startButton then
        State.startButton.Text = "START FOLLOW"
        State.startButton.BackgroundColor3 = Colors.selected
    end
    if State.accessoryList and State.alive then
        refreshAccessoryList()
    end
    setStatus((message or "Safety stop triggered.") .. " Restored " .. tostring(restored) .. "; failed " .. tostring(failed) .. ". Do not retry this accessory in this game until its rig connection is understood.", failed == 0 and "success" or "error")
end

local function calculateOffset(index, total, now, item)
    local x = (index - (total + 1) / 2) * 1.15
    local distance = State.currentDistance
    local mode = Modes[State.modeIndex]

    if mode == "Trail" then
        return CFrame.new(x, 1.2, distance)
    elseif mode == "Left" then
        return CFrame.new(-distance, 1.2 + (index - 1) * 0.3, x)
    elseif mode == "Right" then
        return CFrame.new(distance, 1.2 + (index - 1) * 0.3, x)
    elseif mode == "Above" then
        return CFrame.new(x, distance + 1.1, 0)
    elseif mode == "Orbit" then
        -- Orbit 1 keeps the original v19 formula. Orbit 2 is a stronger wave.
        -- Orbit 3 deliberately does NOT give each accessory a different angular speed:
        -- those speed differences make their paths overtake and cross one another.
        -- Instead, each keeps an evenly spaced phase on the same rotating system,
        -- with a random-but-stable seed, small eased angle/radius wander, and distinct
        -- radial/vertical lanes. That gives less predictable motion without chaotic crossings.
        local safeTotal = math.max(total, 1)
        local safeIndex = math.max(1, tonumber(index) or 1)
        local phase1 = ((safeIndex - 1) / safeTotal) * math.pi * 2
        local baseRadius = math.max(distance, 2.5)
        local offsets = {}

        do
            local angle = State.orbitAngle + phase1
            local radius = baseRadius + math.sin(angle * 0.55 + phase1) * PARK_ORBIT_PULSE
            local bob = math.sin(State.orbitBobAngle + phase1) * PARK_ORBIT_BOB_AMPLITUDE
            local wave = math.sin(angle * 1.35 + phase1) * PARK_ORBIT_WAVE
            local row = math.floor((safeIndex - 1) / 4)
            offsets[1] = Vector3.new(
                math.cos(angle) * radius,
                1.25 + row * 0.55 + bob + wave,
                math.sin(angle) * radius
            )
        end

        do
            local angle = State.orbitAngle + phase1
            local radius = baseRadius
                + math.sin(angle * 0.52 + phase1) * 0.48
                + math.sin(angle * 0.91 + phase1 * 0.85) * 0.22
            local bob = math.sin(State.orbitBobAngle * 1.2 + phase1) * 0.72
            local wave = math.sin(angle * 1.65 + phase1) * 0.70
                + math.sin(angle * 2.17 + phase1 * 0.7) * 0.24
            local row = math.floor((safeIndex - 1) / 4)
            offsets[2] = Vector3.new(
                math.cos(angle) * radius,
                1.25 + row * 0.55 + bob + wave,
                math.sin(angle) * radius
            )
        end

        do
            -- A seed is assigned once per detached item. The fallback handles parked
            -- entries created by older versions before they are reclaimed for following.
            local seed = item and tonumber(item.orbitSeed)
            if not seed then
                seed = (safeIndex * 2.399963229728653) % (math.pi * 2)
            end
            local lane = (safeIndex - 1) % 3
            local row = math.floor((safeIndex - 1) / 3)
            -- All accessories share the same main orbit rate. Only bounded, slow
            -- oscillations vary their direction slightly, so they do not race past slots.
            local angleDrift = math.sin(State.orbitAngle * 0.19 + seed) * 0.105
                + math.sin(State.orbitAngle * 0.37 + seed * 1.31) * 0.045
            local angle = State.orbitAngle + phase1 + angleDrift
            local laneRadius = lane * 0.68
            local radiusWander = math.sin(State.orbitAngle * 0.23 + seed * 0.91) * 0.19
                + math.sin(State.orbitAngle * 0.41 + seed * 1.73) * 0.085
            local radius = baseRadius + laneRadius + radiusWander
            local laneHeight = lane * 0.62 + row * 0.16
            local bob = math.sin(State.orbitBobAngle * 0.47 + seed) * 0.16
                + math.sin(State.orbitBobAngle * 0.79 + seed * 1.47) * 0.075
            local smallWave = math.sin(State.orbitAngle * 0.31 + seed * 0.83) * 0.12
            offsets[3] = Vector3.new(
                math.cos(angle) * radius,
                1.10 + laneHeight + bob + smallWave,
                math.sin(angle) * radius
            )
        end

        local blendedOffset = Vector3.zero
        for styleIndex = 1, 3 do
            local weight = State.orbitStyleWeights[styleIndex] or 0
            if weight > 0 then
                blendedOffset = blendedOffset + offsets[styleIndex] * weight
            end
        end
        return CFrame.new(blendedOffset)
    end
    return CFrame.new(x, 1.2, distance)
end

local function selectOrbitStyle(styleIndex)
    local nextStyle = math.max(1, math.min(3, tonumber(styleIndex) or 1))
    State.orbitStyleStartWeights = {
        State.orbitStyleWeights[1] or 0,
        State.orbitStyleWeights[2] or 0,
        State.orbitStyleWeights[3] or 0,
    }
    State.orbitStyleTarget = nextStyle
    State.orbitStyle = nextStyle
    State.orbitStyleElapsed = 0
end

-- Death/respawn cleanup is intentionally different from a normal STOP: do not park
-- the just-detached accessories again. Stop both loops and release their old references
-- so the game's normal character cleanup can remove stale instances without our script
-- continuously moving them back into an orbit.
local function discardOrbitStateForRespawn()
    safeDisconnect(State.heartbeatConnection)
    State.heartbeatConnection = nil
    safeDisconnect(State.parkedHeartbeatConnection)
    State.parkedHeartbeatConnection = nil
    stopRestoreGuard()

    for _, item in ipairs(State.activeItems) do
        if item then
            item.parked = false
        end
    end
    for _, item in ipairs(State.parkedItems) do
        if item then
            item.parked = false
        end
    end
    State.activeItems = {}
    State.parkedItems = {}
    env[PARKED_KEY] = State.parkedItems
    State.selectedAccessories = {}
    State.accessoryEntries = {}
    State.claimClock = 0
    State.parkClaimClock = 0

    if State.startButton then
        State.startButton.Text = "START FOLLOW"
        State.startButton.BackgroundColor3 = Colors.selected
    end
    if State.orbitDropdown then
        State.orbitDropdown.Visible = false
    end
    if State.alive then
        setStatus("Respawn detected. Old accessory orbit stopped; new character accessories can be selected.", "info")
    end
end

local function startFollowing()
    stopRestoreGuard()
    if #State.activeItems > 0 then
        stopFollowing("Previous follow stopped; accessories orbit-hold before reuse.", true)
    end
    local resolvedTarget, targetError = resolveTargetInput()
    if not resolvedTarget or resolvedTarget.Parent ~= Players then
        setStatus(targetError or "Choose a target player first.", "error")
        refreshTargetSuggestions()
        return
    end
    if not getRoot(State.target) then
        setStatus("Target character is not ready yet.", "error")
        return
    end

    local selected = {}
    for _, entry in ipairs(State.accessoryEntries) do
        if State.selectedAccessories[entry.accessory] then
            table.insert(selected, entry.accessory)
        end
    end
    if #selected == 0 then
        setStatus("Select at least one accessory first.", "error")
        return
    end
    if #selected > MAX_SELECTED then
        setStatus("Select no more than " .. tostring(MAX_SELECTED) .. " accessories.", "error")
        return
    end

    local claimWorked = claimSimulationRadius()
    for index, accessory in ipairs(selected) do
        local item, message
        local parkedItem = findParkedItem(accessory)
        if parkedItem then
            if not parkedItem.orbitSeed then
                parkedItem.orbitSeed = math.random() * math.pi * 2
            end
            local targetRoot = getRoot(State.target)
            local expectedCFrame = targetRoot and (targetRoot.CFrame * calculateOffset(index, #selected, os.clock(), parkedItem)) or nil
            local ok
            ok, message = unparkItem(parkedItem, expectedCFrame)
            if ok then
                item = parkedItem
            end
        else
            -- Match v8's known-working fresh-detach path: let the first Heartbeat position
            -- the handle, rather than teleporting + setting velocity before the loop exists.
            item, message = makeAccessoryState(accessory)
        end

        if item then
            if not item.orbitSeed then
                item.orbitSeed = math.random() * math.pi * 2
            end
            table.insert(State.activeItems, item)
        else
            setStatus(message or "Could not activate an accessory.", "error")
            stopFollowing("Could not activate every selected accessory; successful ones are orbit-holding above you.")
            return
        end
    end

    if #State.activeItems == 0 then
        setStatus("No accessories could be moved.", "error")
        return
    end

    State.startButton.Text = "FOLLOWING..."
    State.startButton.BackgroundColor3 = Color3.fromRGB(43, 91, 70)
    if claimWorked then
        setStatus("Following started. Keep the script active for best-effort accessory hold; verify from your alt.", "info")
    else
        setStatus("Started locally. Ownership/replication is experience-dependent; verify from your alt.", "info")
    end

    State.claimClock = 0
    State.heartbeatConnection = RunService.Heartbeat:Connect(function(deltaTime)
        if not State.alive then
            stopFollowing()
            return
        end

        local targetRoot = getRoot(State.target)
        if not targetRoot then
            stopFollowing("Target character disappeared. Accessories orbit-holding above you for reuse.")
            return
        end

        advanceMotion(deltaTime)
        local now = os.clock()
        State.claimClock = State.claimClock + deltaTime
        if State.claimClock >= 1 then
            State.claimClock = 0
            claimSimulationRadius()
        end

        -- If an experience reclaims/reparents an active accessory, stop moving it and
        -- park what remains usable. The server may still override client-side changes.
        for _, item in ipairs(State.activeItems) do
            local handle = item.handle
            local accessory = item.accessory
            if handle and handleConnectedToCharacter(handle, LocalPlayer.Character) then
                emergencyRestoreAll("Safety stop: an active accessory became connected to your character again. Movement was stopped before another follow update.")
                return
            end
            if not handle or not handle.Parent or not accessory or accessory.Parent ~= workspace then
                stopFollowing("The experience reclaimed or reparented an accessory. Others are orbit-holding; the reclaimed instance was left untouched.")
                return
            end
        end

        for index, item in ipairs(State.activeItems) do
            local handle = item.handle
            local offset = calculateOffset(index, #State.activeItems, now, item)
            pcall(function()
                handle.CFrame = targetRoot.CFrame * offset
                -- Legacy Source -30 velocity write. This can help in some experiences,
                -- but it cannot override server ownership or guarantee replication.
                handle.AssemblyLinearVelocity = SOURCE_VELOCITY
                handle.AssemblyAngularVelocity = Vector3.zero
            end)
        end
    end)
end

local function unload()
    if not State.alive then
        return
    end

    -- Stop all writers before attempting to reattach accessories.
    safeDisconnect(State.heartbeatConnection)
    State.heartbeatConnection = nil
    safeDisconnect(State.parkedHeartbeatConnection)
    State.parkedHeartbeatConnection = nil
    stopRestoreGuard()
    for _, connection in ipairs(State.connections) do
        safeDisconnect(connection)
    end
    State.connections = {}

    -- Unload means leave the avatar in a recoverable state, not leave detached
    -- handles behind with their controller disconnected. Deduplicate shared state.
    local restoreItems = {}
    local seenItems = {}
    local function queueRestore(item)
        if item and not seenItems[item] then
            seenItems[item] = true
            table.insert(restoreItems, item)
        end
    end
    for _, item in ipairs(State.activeItems or {}) do
        queueRestore(item)
    end
    for _, item in ipairs(State.parkedItems or {}) do
        queueRestore(item)
    end
    State.activeItems = {}
    State.parkedItems = {}
    env[PARKED_KEY] = State.parkedItems

    local restored = 0
    local failed = 0
    for _, item in ipairs(restoreItems) do
        local ok, result = pcall(restoreItem, item)
        if ok and result then
            restored = restored + 1
        else
            failed = failed + 1
        end
    end

    State.alive = false
    if State.gui then
        pcall(function()
            State.gui:Destroy()
        end)
    end
    if env[ENV_KEY] then
        env[ENV_KEY] = nil
    end
end

-- Clean up previous executions, including the earlier UI versions.
for _, oldKey in ipairs({ ENV_KEY, "__AccessoryFollowerStandaloneV33Unload", "__AccessoryFollowerStandaloneV32Unload", "__AccessoryFollowerStandaloneV31Unload", "__AccessoryFollowerStandaloneV30Unload", "__AccessoryFollowerStandaloneV29Unload", "__AccessoryFollowerStandaloneV28Unload", "__AccessoryFollowerStandaloneV27Unload", "__AccessoryFollowerStandaloneV26Unload", "__AccessoryFollowerStandaloneV25Unload", "__AccessoryFollowerStandaloneV24Unload", "__AccessoryFollowerStandaloneV23Unload", "__AccessoryFollowerStandaloneV22Unload", "__AccessoryFollowerStandaloneV21Unload", "__AccessoryFollowerStandaloneV20Unload", "__AccessoryFollowerStandaloneV19Unload", "__AccessoryFollowerStandaloneV15Unload", "__AccessoryFollowerStandaloneV14Unload", "__AccessoryFollowerStandaloneV13Unload", "__AccessoryFollowerStandaloneV12Unload", "__AccessoryFollowerStandaloneV11Unload", "__AccessoryFollowerStandaloneV10Unload", "__AccessoryFollowerStandaloneV9Unload", "__AccessoryFollowerStandaloneV8Unload", "__AccessoryFollowerStandaloneV7Unload", "__AccessoryFollowerStandaloneV6Unload", "__AccessoryFollowerStandaloneV5Unload", "__AccessoryFollowerStandaloneV4Unload", "__AccessoryFollowerStandaloneV3Unload", "__AccessoryFollowerStandaloneV2Unload" }) do
    if type(env[oldKey]) == "function" then
        pcall(env[oldKey])
    end
end
env[ENV_KEY] = unload

-- Run migration after the previous version unloads. v9's unload may park active items
-- after this script begins, so starting the keeper earlier can miss that just-created state.
for index = #State.parkedItems, 1, -1 do
    local item = State.parkedItems[index]
    if not item or not item.accessory or not item.handle or not item.accessory.Parent or not item.handle.Parent then
        if item then item.parked = false end
        table.remove(State.parkedItems, index)
    elseif item.accessory.Parent == workspace then
        item.parked = true
        item.parkedOffset = item.parkedOffset or calculateParkingOffset(index)
    else
        item.parked = false
        table.remove(State.parkedItems, index)
    end
end
startParkKeeper()

local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")
for _, oldName in ipairs({ GUI_NAME, "AccessoryFollowerStandaloneV33", "AccessoryFollowerStandaloneV32", "AccessoryFollowerStandaloneV31", "AccessoryFollowerStandaloneV30", "AccessoryFollowerStandaloneV29", "AccessoryFollowerStandaloneV28", "AccessoryFollowerStandaloneV27", "AccessoryFollowerStandaloneV26", "AccessoryFollowerStandaloneV25", "AccessoryFollowerStandaloneV24", "AccessoryFollowerStandaloneV23", "AccessoryFollowerStandaloneV22", "AccessoryFollowerStandaloneV21", "AccessoryFollowerStandaloneV20", "AccessoryFollowerStandaloneV19", "AccessoryFollowerStandaloneV15", "AccessoryFollowerStandaloneV14", "AccessoryFollowerStandaloneV13", "AccessoryFollowerStandaloneV12", "AccessoryFollowerStandaloneV10", "AccessoryFollowerStandaloneV9", "AccessoryFollowerStandaloneV8", "AccessoryFollowerStandaloneV7", "AccessoryFollowerStandaloneV6", "AccessoryFollowerStandaloneV5", "AccessoryFollowerStandaloneV4", "AccessoryFollowerStandaloneV3", "AccessoryFollowerStandaloneV2" }) do
    local oldGui = PlayerGui:FindFirstChild(oldName)
    if oldGui then
        oldGui:Destroy()
    end
end

State.gui = create("ScreenGui", {
    Name = GUI_NAME,
    ResetOnSpawn = false,
    IgnoreGuiInset = true,
    ZIndexBehavior = Enum.ZIndexBehavior.Global,
    DisplayOrder = 1000000,
}, PlayerGui)

-- Compact, responsive panel. UIScale reduces the whole layout uniformly on smaller screens.
local PANEL_WIDTH = 370
local PANEL_HEIGHT = 452
local camera = workspace.CurrentCamera
local viewport = camera and camera.ViewportSize or Vector2.new(800, 600)
local uiScale = create("UIScale", { Scale = 0.648 }, nil) -- 10% smaller than 0.72.
local function getResponsiveScale()
    local currentCamera = workspace.CurrentCamera
    local size = currentCamera and currentCamera.ViewportSize or viewport
    local widthScale = math.max(0.495, (size.X - 18) / PANEL_WIDTH)
    local heightScale = math.max(0.495, (size.Y - 28) / PANEL_HEIGHT)
    return math.min(0.648, widthScale, heightScale)
end

local mainFrame = create("Frame", {
    Name = "Main",
    AnchorPoint = Vector2.new(1, 0.5),
    Position = UDim2.new(1, -3, 0.5, 0),
    Size = UDim2.fromOffset(PANEL_WIDTH, PANEL_HEIGHT),
    BackgroundColor3 = Color3.fromRGB(14, 16, 22),
    BackgroundTransparency = 0.14,
    BorderSizePixel = 0,
    ClipsDescendants = true,
}, State.gui)
State.mainFrame = mainFrame
uiScale.Parent = mainFrame
uiScale.Scale = getResponsiveScale()
round(mainFrame, 10)
create("UIStroke", {
    Color = Color3.fromRGB(0, 170, 255),
    Thickness = 1.5,
    Transparency = 0.15,
}, mainFrame)

-- Header has rounded top corners and a flat lower edge, matching WallWalk's panel style.
local titleBar = create("Frame", {
    Name = "TitleBar",
    Position = UDim2.fromOffset(1, 1),
    Size = UDim2.new(1, -2, 0, 36),
    BackgroundColor3 = Color3.fromRGB(18, 26, 34),
    BackgroundTransparency = 0.08,
    BorderSizePixel = 0,
}, mainFrame)
round(titleBar, 9)
create("Frame", {
    Name = "HeaderFlatBottom",
    Position = UDim2.new(0, 0, 1, -9),
    Size = UDim2.new(1, 0, 0, 9),
    BackgroundColor3 = titleBar.BackgroundColor3,
    BackgroundTransparency = titleBar.BackgroundTransparency,
    BorderSizePixel = 0,
}, titleBar)
local title = makeLabel(titleBar, "ACCESSORY FOLLOWER  ·  v34", UDim2.new(1, -38, 1, 0), UDim2.new(0, 11, 0, 0), 12, Colors.text)
title.Font = Enum.Font.GothamBold
title.TextTruncate = Enum.TextTruncate.AtEnd


makeLabel(mainFrame, "TARGET PLAYER  ·  type part of a username", UDim2.new(1, -20, 0, 14), UDim2.fromOffset(10, 42), 10, Colors.muted)
State.targetLabel = makeLabel(mainFrame, "Target: YOU (local player)", UDim2.new(1, -20, 0, 14), UDim2.fromOffset(10, 57), 10, Colors.text)
-- Use a visible wrapper with an inset TextBox, matching the console's mobile-safe
-- search layout. Roblox's mobile text-entry overlay can ignore UIPadding on a
-- TextBox while typing, so the actual editable region starts 9 px inside the frame.
State.targetInputFrame = create("Frame", {
    Name = "TargetInputFrame",
    Position = UDim2.fromOffset(10, 73),
    Size = UDim2.new(1, -20, 0, 29),
    BackgroundColor3 = Color3.fromRGB(35, 43, 57),
    BackgroundTransparency = 0.10,
    BorderSizePixel = 0,
}, mainFrame)
round(State.targetInputFrame, 7)
outline(State.targetInputFrame, Color3.fromRGB(64, 82, 102), 0.6)
State.targetInput = create("TextBox", {
    Name = "TargetInput",
    Position = UDim2.new(0, 9, 0, 0),
    Size = UDim2.new(1, -39, 1, 0),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    ClearTextOnFocus = false,
    PlaceholderText = "Blank = follow yourself · or enter a player...",
    PlaceholderColor3 = Color3.fromRGB(143, 154, 173),
    Text = "",
    TextColor3 = Colors.text,
    TextSize = 12,
    Font = Enum.Font.Gotham,
    TextXAlignment = Enum.TextXAlignment.Left,
    TextYAlignment = Enum.TextYAlignment.Center,
    TextTruncate = Enum.TextTruncate.AtEnd,
    ZIndex = 31,
}, State.targetInputFrame)
State.clearTargetButton = create("TextButton", {
    Name = "ClearTargetButton",
    Position = UDim2.new(1, -35, 0, 77),
    Size = UDim2.fromOffset(22, 21),
    BackgroundColor3 = Color3.fromRGB(45, 56, 72),
    BackgroundTransparency = 0.14,
    BorderSizePixel = 0,
    Text = "×",
    TextColor3 = Color3.fromRGB(218, 228, 241),
    Font = Enum.Font.GothamBold,
    TextSize = 16,
    AutoButtonColor = true,
    Visible = false,
    ZIndex = 32,
}, mainFrame)
round(State.clearTargetButton, 5)
State.targetSuggestions = create("ScrollingFrame", {
    Name = "TargetSuggestions",
    Position = UDim2.fromOffset(10, 104),
    Size = UDim2.new(1, -20, 0, 0),
    BackgroundColor3 = Color3.fromRGB(18, 26, 34),
    BackgroundTransparency = 0.10,
    BorderSizePixel = 0,
    ScrollBarThickness = 2,
    ScrollBarImageColor3 = Color3.fromRGB(65, 133, 185),
    CanvasSize = UDim2.new(0, 0, 0, 0),
    Visible = false,
    ZIndex = 31,
}, mainFrame)
round(State.targetSuggestions, 7)
outline(State.targetSuggestions, Color3.fromRGB(64, 82, 102), 0.25)

makeLabel(mainFrame, "YOUR ACCESSORIES  ·  select up to 8", UDim2.new(1, -105, 0, 16), UDim2.fromOffset(10, 116), 10, Colors.muted)
local refreshButton = makeButton(mainFrame, "Refresh", UDim2.fromOffset(74, 27), UDim2.new(1, -84, 0, 110), Color3.fromRGB(35, 48, 63))
refreshButton.TextSize = 11
refreshButton.TextWrapped = false
round(refreshButton, 8)
State.accessoryList = create("ScrollingFrame", {
    Name = "AccessoryList",
    Position = UDim2.fromOffset(10, 143),
    Size = UDim2.new(1, -20, 0, 176),
    BackgroundColor3 = Color3.fromRGB(18, 26, 34),
    BackgroundTransparency = 0.10,
    BorderSizePixel = 0,
    ScrollBarThickness = 3,
    ScrollBarImageColor3 = Color3.fromRGB(65, 133, 185),
    CanvasSize = UDim2.new(0, 0, 0, 0),
}, mainFrame)
round(State.accessoryList, 8)
outline(State.accessoryList, Color3.fromRGB(64, 82, 102), 0.72)

-- Slimmer action row: more room is reserved for the accessory list, the primary content.
State.modeButton = makeButton(mainFrame, "Mode: " .. Modes[State.modeIndex], UDim2.new(0.5, -14, 0, 28), UDim2.fromOffset(10, 327), Color3.fromRGB(35, 43, 57))
State.modeButton.TextSize = 11

State.orbitDropdown = create("Frame", {
    Name = "OrbitStyleDropdown",
    Position = UDim2.fromOffset(10, 229),
    Size = UDim2.fromOffset(174, 84),
    BackgroundColor3 = Color3.fromRGB(18, 26, 34),
    BackgroundTransparency = 0.08,
    BorderSizePixel = 0,
    Visible = false,
    ZIndex = 80,
}, mainFrame)
round(State.orbitDropdown, 8)
outline(State.orbitDropdown, Color3.fromRGB(64, 82, 102), 0.25)

local function updateModeButtonText()
    if not State.modeButton then
        return
    end
    if Modes[State.modeIndex] == "Orbit" then
        State.modeButton.Text = "Mode: Orbit [" .. tostring(State.orbitStyle) .. "]"
    else
        State.modeButton.Text = "Mode: " .. Modes[State.modeIndex]
    end
end

local function updateOrbitDropdown()
    for styleIndex = 1, 3 do
        local button = State.orbitDropdownButtons[styleIndex]
        if button then
            if State.orbitStyle == styleIndex then
                button.Text = "✓  Orbit " .. tostring(styleIndex)
                button.BackgroundColor3 = Color3.fromRGB(44, 73, 117)
            else
                button.Text = "Orbit " .. tostring(styleIndex)
                button.BackgroundColor3 = Colors.row
            end
        end
    end
    updateModeButtonText()
end

for styleIndex = 1, 3 do
    local selectedStyle = styleIndex
    local orbitButton = makeButton(
        State.orbitDropdown,
        "Orbit " .. tostring(selectedStyle),
        UDim2.new(1, -8, 0, 24),
        UDim2.fromOffset(4, 3 + (selectedStyle - 1) * 27),
        Colors.row
    )
    orbitButton.ZIndex = 81
    orbitButton.TextSize = 11
    round(orbitButton, 6)
    State.orbitDropdownButtons[selectedStyle] = orbitButton
    orbitButton.Activated:Connect(function()
        selectOrbitStyle(selectedStyle)
        State.orbitDropdown.Visible = false
        updateOrbitDropdown()
        setStatus("Orbit " .. tostring(selectedStyle) .. " selected; blending smoothly.", "success")
    end)
end
updateOrbitDropdown()

State.modeButton.InputBegan:Connect(function(input)
    if input.UserInputType ~= Enum.UserInputType.MouseButton1
        and input.UserInputType ~= Enum.UserInputType.Touch then
        return
    end
    State.modeHoldToken = State.modeHoldToken + 1
    local token = State.modeHoldToken
    State.modeHoldInput = input
    task.delay(0.45, function()
        if not State.alive or token ~= State.modeHoldToken or State.modeHoldInput ~= input then
            return
        end
        if Modes[State.modeIndex] == "Orbit" then
            State.orbitDropdown.Visible = true
            State.skipNextModeActivated = true
        end
    end)
end)

addConnection(UserInputService.InputEnded:Connect(function(input)
    local matchingTouch = State.modeHoldInput
        and State.modeHoldInput.UserInputType == Enum.UserInputType.Touch
        and input == State.modeHoldInput
    local matchingMouse = State.modeHoldInput
        and State.modeHoldInput.UserInputType == Enum.UserInputType.MouseButton1
        and input.UserInputType == Enum.UserInputType.MouseButton1
    if matchingTouch or matchingMouse then
        State.modeHoldInput = nil
        State.modeHoldToken = State.modeHoldToken + 1
        if State.skipNextModeActivated then
            task.delay(0.30, function()
                State.skipNextModeActivated = false
            end)
        end
    end
end))

State.modeButton.Activated:Connect(function()
    if State.skipNextModeActivated then
        State.skipNextModeActivated = false
        return
    end
    State.modeIndex = State.modeIndex + 1
    if State.modeIndex > #Modes then
        State.modeIndex = 1
    end
    if Modes[State.modeIndex] ~= "Orbit" then
        State.orbitDropdown.Visible = false
    end
    updateModeButtonText()
end)

local distanceMinus = makeButton(mainFrame, "−", UDim2.fromOffset(27, 28), UDim2.new(0.5, 4, 0, 327), Color3.fromRGB(35, 43, 57))
distanceMinus.TextSize = 12
local distanceLabel = create("TextButton", {
    Name = "DistanceSpeedToggle",
    Size = UDim2.fromOffset(117, 28),
    Position = UDim2.new(0.5, 31, 0, 327),
    BackgroundTransparency = 1,
    BorderSizePixel = 0,
    Text = "Dist: 4",
    TextColor3 = Colors.text,
    Font = Enum.Font.Gotham,
    TextSize = 10,
    TextWrapped = false,
    TextXAlignment = Enum.TextXAlignment.Center,
    TextYAlignment = Enum.TextYAlignment.Center,
    AutoButtonColor = false,
}, mainFrame)
State.distanceLabel = distanceLabel
local distancePlus = makeButton(mainFrame, "+", UDim2.fromOffset(27, 28), UDim2.new(1, -37, 0, 327), Color3.fromRGB(35, 43, 57))
distancePlus.TextSize = 12

local function updateSettingLabel()
    if State.settingMode == "speed" then
        local speedText = string.format("%.2f", State.orbitSpeed):gsub("0+$", ""):gsub("%.$", "")
        State.distanceLabel.Text = "Speed: " .. speedText .. "x"
    else
        State.distanceLabel.Text = "Dist: " .. tostring(State.distance)
    end
end

local function adjustDisplayedSetting(direction)
    if State.settingMode == "speed" then
        local nextSpeed = State.orbitSpeed + direction * ORBIT_SPEED_STEP
        State.orbitSpeed = math.max(MIN_ORBIT_SPEED_MULTIPLIER,
            math.min(MAX_ORBIT_SPEED_MULTIPLIER, math.floor(nextSpeed * 100 + 0.5) / 100))
    else
        State.distance = math.max(MIN_DISTANCE, math.min(MAX_DISTANCE, State.distance + direction))
    end
    updateSettingLabel()
end

distanceLabel.Activated:Connect(function()
    local now = os.clock()
    if now - State.lastSettingTap <= 0.38 then
        State.settingMode = State.settingMode == "distance" and "speed" or "distance"
        State.lastSettingTap = 0
        updateSettingLabel()
    else
        State.lastSettingTap = now
    end
end)
-- Press-and-hold support for +/-: change once immediately, then repeat after a
-- short hold delay. Releasing anywhere ends repetition; ordinary taps still work.
local heldAdjustButton = nil
local holdAdjustToken = 0
local function stopHeldAdjustment()
    holdAdjustToken = holdAdjustToken + 1
    heldAdjustButton = nil
end
local function beginHeldAdjustment(button, direction, input)
    if input.UserInputType ~= Enum.UserInputType.MouseButton1
        and input.UserInputType ~= Enum.UserInputType.Touch then
        return
    end
    stopHeldAdjustment()
    heldAdjustButton = button
    local token = holdAdjustToken
    State.lastSettingTap = 0
    adjustDisplayedSetting(direction)
    task.spawn(function()
        task.wait(0.30)
        while State.alive and token == holdAdjustToken and heldAdjustButton == button do
            adjustDisplayedSetting(direction)
            task.wait(0.075)
        end
    end)
end

distanceMinus.InputBegan:Connect(function(input)
    beginHeldAdjustment(distanceMinus, -1, input)
end)
distancePlus.InputBegan:Connect(function(input)
    beginHeldAdjustment(distancePlus, 1, input)
end)
local heldInputEndedConnection = UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
        or input.UserInputType == Enum.UserInputType.Touch then
        stopHeldAdjustment()
    end
end)
addConnection(heldInputEndedConnection)

State.startButton = makeButton(mainFrame, "START FOLLOW", UDim2.new(0.5, -14, 0, 33), UDim2.fromOffset(10, 362), Color3.fromRGB(32, 91, 69))
State.stopButton = makeButton(mainFrame, "ORBIT / STOP", UDim2.new(0.5, -14, 0, 33), UDim2.new(0.5, 4, 0, 362), Color3.fromRGB(126, 48, 58))
State.startButton.TextSize = 11
State.stopButton.TextSize = 11

local statusCard = create("Frame", {
    Name = "StatusCard",
    Position = UDim2.fromOffset(10, 398),
    Size = UDim2.new(1, -20, 0, 36),
    BackgroundColor3 = Color3.fromRGB(23, 30, 41),
    BackgroundTransparency = 0.12,
    BorderSizePixel = 0,
}, mainFrame)
round(statusCard, 8)
outline(statusCard, Color3.fromRGB(64, 82, 102), 0.82)
State.compatibilityLabel = makeLabel(statusCard, "Cross-player visibility: checking experience…", UDim2.new(1, -12, 0, 15), UDim2.fromOffset(6, 1), 9, Colors.muted)
State.compatibilityLabel.TextYAlignment = Enum.TextYAlignment.Center
State.compatibilityLabel.TextTruncate = Enum.TextTruncate.AtEnd
State.statusLabel = makeLabel(statusCard, "Diagnostics are printed to the console.", UDim2.new(1, -12, 0, 16), UDim2.fromOffset(6, 17), 9, Colors.muted)
State.statusLabel.TextYAlignment = Enum.TextYAlignment.Center
State.statusLabel.TextWrapped = true

-- Live local Workspace check. This deliberately does not hardcode experience IDs.
-- Client code cannot directly inspect what another player's client renders, so the
-- indicator reports observable local detach/connection state and never claims that
-- cross-client visibility has been proven without an alt-side observation.
local workspaceCheckClock = 0
local function inspectWorkspaceCompatibility()
    local tracked = 0
    local reclaimed = 0
    local connectedToCharacter = 0
    local character = LocalPlayer.Character
    local seen = {}

    local function inspectItem(item)
        if not item or seen[item] then
            return
        end
        seen[item] = true
        local accessory = item.accessory
        local handle = item.handle
        if not accessory or not handle or not accessory.Parent or not handle.Parent then
            reclaimed = reclaimed + 1
            return
        end
        tracked = tracked + 1
        if character and accessory.Parent == character and handle:IsDescendantOf(character) then
            if hasCharacterAccessoryJoint(character, handle, accessory) then
                connectedToCharacter = connectedToCharacter + 1
            else
                reclaimed = reclaimed + 1
            end
            return
        end
        if accessory.Parent ~= workspace or not handle:IsDescendantOf(workspace) then
            reclaimed = reclaimed + 1
        end
    end

    for _, item in ipairs(State.activeItems or {}) do
        inspectItem(item)
    end
    for _, item in ipairs(State.parkedItems or {}) do
        inspectItem(item)
    end

    if not State.compatibilityLabel then
        return
    end
    if tracked == 0 then
        State.compatibilityLabel.Text = "Local check: waiting for a tracked accessory"
        State.compatibilityLabel.TextColor3 = Color3.fromRGB(183, 193, 212)
    elseif reclaimed > 0 then
        State.compatibilityLabel.Text = "Local check: accessory missing/reparented"
        State.compatibilityLabel.TextColor3 = Color3.fromRGB(255, 151, 117)
    elseif connectedToCharacter > 0 then
        State.compatibilityLabel.Text = "Local check: accessory is still connected to character"
        State.compatibilityLabel.TextColor3 = Color3.fromRGB(255, 151, 117)
    else
        State.compatibilityLabel.Text = "Local detach: OK | Alt visibility: UNCONFIRMED"
        State.compatibilityLabel.TextColor3 = Color3.fromRGB(238, 198, 106)
    end
end

addConnection(RunService.Heartbeat:Connect(function(deltaTime)
    workspaceCheckClock = workspaceCheckClock + (deltaTime or 0)
    if workspaceCheckClock >= 0.5 then
        workspaceCheckClock = 0
        inspectWorkspaceCompatibility()
    end
end))
inspectWorkspaceCompatibility()

-- WallWalk-style fixed screen shortcut. Unlike the draggable panel, its screen position
-- does not follow panel movement; it stays at the same viewport-relative location.
State.shortcutButton = create("TextButton", {
    Name = "AccessoryFollowerShortcut",
    Size = UDim2.fromOffset(20, 20),
    Position = UDim2.new(1, -28, 0.5, -(PANEL_HEIGHT * uiScale.Scale / 2) + 4),
    BackgroundColor3 = Color3.fromRGB(18, 26, 34),
    BackgroundTransparency = 0.12,
    BorderSizePixel = 0,
    Text = "<",
    TextColor3 = Color3.fromRGB(235, 247, 255),
    Font = Enum.Font.GothamBold,
    TextSize = 14,
    AutoButtonColor = false,
    ZIndex = 50,
}, State.gui)
round(State.shortcutButton, 6)
create("UIStroke", {
    ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
    Color = Color3.fromRGB(48, 139, 218),
    Thickness = 1,
    Transparency = 0.48,
}, State.shortcutButton)

local function updateShortcut()
    -- Position is intentionally independent of mainFrame.AbsolutePosition so dragging
    -- the panel never drags the shortcut away from its WallWalk-like fixed location.
    State.shortcutButton.Position = UDim2.new(1, -28, 0.5, -(PANEL_HEIGHT * uiScale.Scale / 2) + 4)
    State.shortcutButton.Visible = true
end
State.shortcutButton.Activated:Connect(function()
    State.mainFrame.Visible = not State.mainFrame.Visible
    updateShortcut()
end)
State.targetInput:GetPropertyChangedSignal("Text"):Connect(function()
    if State.clearTargetButton then
        State.clearTargetButton.Visible = (State.targetInput.Text or "") ~= ""
    end
    if State.suppressTargetTextChange then
        return
    end
    State.target = nil
    local resolved = resolveTargetInput()
    if not resolved then
        State.targetLabel.Text = "Target: choose a matching suggestion"
    end
    refreshTargetSuggestions()
end)
State.targetInput.Focused:Connect(function()
    refreshTargetSuggestions()
end)
State.clearTargetButton.Activated:Connect(function()
    State.targetInput.Text = ""
    State.target = LocalPlayer
    State.targetLabel.Text = "Target: YOU (local player)"
    State.targetSuggestions.Visible = false
    State.targetSuggestions.CanvasSize = UDim2.new(0, 0, 0, 0)
end)
State.targetInput.FocusLost:Connect(function(enterPressed)
    -- Delay closing the dropdown briefly so a tap that moves focus from the TextBox
    -- onto a suggestion button can finish its Activated event first.
    task.delay(0.25, function()
        if not State.alive or not State.targetInput then
            return
        end
        if not State.targetInput:IsFocused() then
            local resolved = resolveTargetInput()
            if resolved then
                State.targetLabel.Text = "Target: @" .. resolved.Name
            end
            if State.targetSuggestions then
                State.targetSuggestions.Visible = false
            end
        end
    end)
end)
refreshButton.Activated:Connect(function()
    refreshAccessoryList()
    refreshTargetSuggestions()
    setStatus("Accessory list refreshed.", "success")
end)
-- Log every start attempt and any startup error to the console.
local lastStartDispatch = 0
local function dispatchStartFollow()
    local now = os.clock()
    if now - lastStartDispatch < 1.0 or not State.alive then
        return
    end
    lastStartDispatch = now
    print("[Accessory Follower v34] START FOLLOW tapped; checking target and accessories...")
    local ok, err = pcall(startFollowing)
    if not ok then
        warn("[Accessory Follower v34] START FOLLOW error: " .. tostring(err))
    end
end
State.startButton.Activated:Connect(dispatchStartFollow)
-- MouseButton1Click is a fallback for executors/environments where Activated is not delivered.
State.startButton.MouseButton1Click:Connect(dispatchStartFollow)
State.stopButton.Activated:Connect(function()
    stopFollowing("Follow stopped; accessories now orbit above you for reuse.")
end)

-- Responsive scale + shortcut position refresh on viewport changes.
local function syncGuiGeometry()
    uiScale.Scale = getResponsiveScale()
    task.defer(updateShortcut)
end
local cameraViewportConnection = nil
local function bindCameraViewport()
    safeDisconnect(cameraViewportConnection)
    cameraViewportConnection = nil
    local currentCamera = workspace.CurrentCamera
    if currentCamera then
        cameraViewportConnection = currentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(syncGuiGeometry)
    end
end
bindCameraViewport()
addConnection(workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    bindCameraViewport()
    syncGuiGeometry()
end))
addConnection(State.gui.Destroying:Connect(function()
    safeDisconnect(cameraViewportConnection)
end))
addConnection(mainFrame:GetPropertyChangedSignal("Visible"):Connect(function()
    task.defer(updateShortcut)
end))

-- Drag the panel using only the exact touch that began on the title bar (console-style).
-- This prevents a second finger on the movement joystick from moving the panel.
-- Horizontal position keeps the full title bar inside the viewport; vertically, the
-- panel body may extend off-screen, but the title bar itself remains fully reachable.
do
    local dragging = false
    local activeInput = nil
    local dragStart = nil
    local initialPosition = nil
    local dragMoved = false

    local function clampPanelPosition(position)
        local currentCamera = workspace.CurrentCamera
        local viewportSize = currentCamera and currentCamera.ViewportSize or viewport
        local frameSize = mainFrame.AbsoluteSize
        local barSize = titleBar.AbsoluteSize
        if viewportSize.X <= 0 or viewportSize.Y <= 0 or frameSize.X <= 0 or frameSize.Y <= 0 then
            return position
        end

        local left = viewportSize.X * position.X.Scale + position.X.Offset - frameSize.X * mainFrame.AnchorPoint.X
        local top = viewportSize.Y * position.Y.Scale + position.Y.Offset - frameSize.Y * mainFrame.AnchorPoint.Y
        left = math.clamp(left, 0, math.max(0, viewportSize.X - frameSize.X))
        top = math.clamp(top, 0, math.max(0, viewportSize.Y - barSize.Y))

        local offsetX = left + frameSize.X * mainFrame.AnchorPoint.X - viewportSize.X * position.X.Scale
        local offsetY = top + frameSize.Y * mainFrame.AnchorPoint.Y - viewportSize.Y * position.Y.Scale
        return UDim2.new(position.X.Scale, offsetX, position.Y.Scale, offsetY)
    end

    titleBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            activeInput = input
            dragStart = input.Position
            initialPosition = mainFrame.Position
            dragMoved = false
        end
    end)

    addConnection(UserInputService.InputChanged:Connect(function(input)
        if not dragging or not activeInput then
            return
        end
        local isActiveTouch = activeInput.UserInputType == Enum.UserInputType.Touch and input == activeInput
        local isActiveMouseMove = activeInput.UserInputType == Enum.UserInputType.MouseButton1
            and input.UserInputType == Enum.UserInputType.MouseMovement
        if not isActiveTouch and not isActiveMouseMove then
            return
        end

        local delta = input.Position - dragStart
        if math.abs(delta.X) > 2 or math.abs(delta.Y) > 2 then
            dragMoved = true
        end
        if not dragMoved then
            return
        end
        mainFrame.Position = clampPanelPosition(UDim2.new(
            initialPosition.X.Scale,
            initialPosition.X.Offset + delta.X,
            initialPosition.Y.Scale,
            initialPosition.Y.Offset + delta.Y
        ))
    end))

    addConnection(UserInputService.InputEnded:Connect(function(input)
        if not dragging or not activeInput then
            return
        end
        local isActiveTouchEnd = activeInput.UserInputType == Enum.UserInputType.Touch and input == activeInput
        local isActiveMouseEnd = activeInput.UserInputType == Enum.UserInputType.MouseButton1
            and input.UserInputType == Enum.UserInputType.MouseButton1
        if isActiveTouchEnd or isActiveMouseEnd then
            dragging = false
            activeInput = nil
            dragStart = nil
            initialPosition = nil
            dragMoved = false
        end
    end))

    -- Re-clamp after viewport/scale changes so the top bar stays reachable on rotation.
    local function reclampPanel()
        mainFrame.Position = clampPanelPosition(mainFrame.Position)
    end
    addConnection(mainFrame:GetPropertyChangedSignal("AbsoluteSize"):Connect(reclampPanel))
    addConnection(titleBar:GetPropertyChangedSignal("AbsoluteSize"):Connect(reclampPanel))
    task.defer(reclampPanel)
end

addConnection(Players.PlayerAdded:Connect(function() refreshTargetSuggestions() end))
addConnection(Players.PlayerRemoving:Connect(function(player)
    if player == State.target then
        stopFollowing("Target left. Accessories restored.")
        State.target = nil
        if State.targetInput then
            State.targetInput.Text = ""
        end
        if State.targetLabel then
            State.targetLabel.Text = "Target: YOU (local player)"
        end
    end
    refreshTargetSuggestions()
end))

addConnection(LocalPlayer.CharacterRemoving:Connect(function()
    discardOrbitStateForRespawn()
end))

addConnection(LocalPlayer.CharacterAdded:Connect(function()
    -- Fallback for respawn paths where CharacterRemoving was missed. This function
    -- only disconnects stale accessory loops; it intentionally does not park items.
    discardOrbitStateForRespawn()
    task.wait(1)
    State.selectedAccessories = {}
    refreshAccessoryList()
end))

-- Re-execution/unload restores active accessories and removes this UI.
State.unload = unload
setStatus("Ready. Check the compatibility indicator; only your alt can confirm visibility.", "info")
refreshTargetSuggestions()
refreshAccessoryList()
updateSettingLabel()
updateShortcut()

