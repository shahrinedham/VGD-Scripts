-- VGD Fly Standalone v29
-- Real-body flight controller for VGD.
-- Uses the same flight-pose concepts as VGD Freecam:
-- animation blending, forward/side lean, turning bank, speed pose,
-- flight pitch and subtle hover motion. The difference is that the
-- player's REAL character is animated and moved instead of a hologram.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")
local GuiService = game:GetService("GuiService")

local player = Players.LocalPlayer
local flyEnabled = false
local flySpeed = 35
local flyMinSpeed = 1
local flyMaxSpeed = 1000
local flyVerticalInput = 0
local flyRenderConnection = nil
local flySaved = nil
local flyPosition = nil
local flyAnimateScript = nil
local flyAnimateScriptDisabled = false
local flyTracks = {}
local screenGui
local flyShiftLockButton
local flyShiftLockOn = true
local flyNoClipOn = true
local flySavedCanCollide = {}
local flyNoClipDescendantConnection = nil
local flyCollisionProxy = nil
local flyCollisionProxyParts = {}
local flyCollisionDebugOn = false
local flyCollisionDebugFolder = nil
local flyCollisionDebugParts = {}
local updateFlyCollisionDebug
local flyGravityForce = nil

-- Fly-owned camera state. This mirrors the Freecam camera architecture:
-- the Fly owns camera input, look smoothing, camera CFrame, and flight in
-- one render loop instead of reading Roblox CameraModule output and then
-- trying to push the real body back through it.
local flyCameraSavedType = nil
local flyCameraSavedSubject = nil
local flyCameraSavedCFrame = nil
local flyCameraSavedFOV = nil
local flyCameraYaw = 0
local flyCameraPitch = 0
local flyCameraTargetYaw = 0
local flyCameraTargetPitch = 0
local flyCameraZoomDistance = 8
local flyCameraTargetZoomDistance = 8
local flyCameraOffset = Vector3.zero
local flyCameraTouchStates = {}
local flyCameraZoomTouchPositions = {}
local flyCameraPinchLastDiameter = nil
local flyCameraTouchDelta = Vector2.new()
local flyCameraMouseDelta = Vector2.new()
local flyCameraMouseLooking = false
local flyCameraConnections = {}

local FLY_CAMERA_TOUCH_ROTATION_SPEED = Vector2.new(0.82, 0.54) * math.rad(1)
local FLY_CAMERA_MOUSE_ROTATION_SPEED = Vector2.new(1, 0.77) * math.rad(0.5)
local FLY_CAMERA_LOOK_SMOOTHNESS = 34
local FLY_CAMERA_MIN_PITCH = math.rad(-89)
local FLY_CAMERA_MAX_PITCH = math.rad(89)
local FLY_CAMERA_ZOOM_MIN = 0
local FLY_CAMERA_ZOOM_MAX = 40

-- The HumanoidRootPart is around the character's torso/pivot. Aim the
-- camera slightly below that pivot so the visible body sits a little higher
-- in the viewport instead of appearing low.
-- Raise the camera's subject point so the camera itself sits higher
-- relative to the HumanoidRootPart. This brings the visible character
-- DOWN toward the normal Roblox camera framing instead of leaving it high.
-- Preserve the normal Roblox camera's vertical relationship to the real
-- character instead of using an arbitrary fixed Y offset.
local flyCameraVerticalOffset = 0

local stateChangedEvent = Instance.new("BindableEvent")

local GUI_CONTROLLED = _G.VGD_Fly_GUIControlled == true

local IDLE_ANIMATION_ID = "rbxassetid://106706162821039"
local MOVE_ANIMATION_ID = "rbxassetid://92749812489844"
local BACKWARD_ANIMATION_ID = "rbxassetid://117465215021389"

local forwardBlend = 0
local rightBlend = 0
local flightPitchBlend = 0
local flightBankBlend = 0
local speedBlend = 0
local previousDesiredYaw = nil
local currentMoveVector = Vector3.zero
local hoverBlend = 0
local flyAnimState = "Idle"

local function getCharacter()
    return player.Character
end

local function getHumanoidAndRoot()
    local character = getCharacter()
    if not character then return nil, nil end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local root = character:FindFirstChild("HumanoidRootPart")
    if not humanoid or not root then return nil, nil end
    return humanoid, root
end

local function stopTracks()
    for _, track in pairs(flyTracks) do
        pcall(function() track:Stop(0.15) end)
    end
    flyTracks = {}
    flyAnimState = "Idle"
end

local function loadFlyAnimations(humanoid)
    stopTracks()
    local animator = humanoid:FindFirstChildOfClass("Animator")
    if not animator then
        animator = Instance.new("Animator")
        animator.Parent = humanoid
    end

    local function load(id, priority)
        local animation = Instance.new("Animation")
        animation.AnimationId = id
        animation.Parent = humanoid
        local ok, track = pcall(function()
            return animator:LoadAnimation(animation)
        end)
        animation:Destroy()
        if ok and track then
            track.Priority = priority
            track.Looped = true
            return track
        end
        return nil
    end

    flyTracks.idle = load(IDLE_ANIMATION_ID, Enum.AnimationPriority.Movement)
    flyTracks.move = load(MOVE_ANIMATION_ID, Enum.AnimationPriority.Movement)
    flyTracks.backward = load(BACKWARD_ANIMATION_ID, Enum.AnimationPriority.Action)

    if flyTracks.idle then flyTracks.idle:Play(0.12, 1, 1) end
end

local function updateFlyAnimations(isMoving, moveDirection, deltaTime, forwardInput)
    local idle = flyTracks.idle
    local move = flyTracks.move
    local backward = flyTracks.backward
    if not idle then return end

    -- Use the CURRENT frame's camera-relative forward input. Reading
    -- CurrentCamera.CFrame here would be one frame behind because Fly rebuilds
    -- the camera later in this same render step.
    local desiredState = "Idle"
    if isMoving and moveDirection.Magnitude > 0.001 then
        desiredState = (forwardInput or 0) < -0.15 and "Backward" or "Forward"
    end

    if desiredState ~= flyAnimState then
        local fadeOut = 0.16
        local fadeIn = 0.18
        if flyAnimState == "Idle" and idle then idle:Stop(fadeOut) end
        if flyAnimState == "Forward" and move then move:Stop(fadeOut) end
        if flyAnimState == "Backward" and backward then backward:Stop(fadeOut) end

        if desiredState == "Idle" and idle then
            idle:Play(fadeIn, 1, 1)
        elseif desiredState == "Forward" and move then
            move:Play(fadeIn, 1, 1)
        elseif desiredState == "Backward" and backward then
            backward:Play(fadeIn, 1, 1)
        end
        flyAnimState = desiredState
    end

    local speedTarget = isMoving and math.clamp(moveDirection.Magnitude, 0, 1) or 0
    speedBlend += (speedTarget - speedBlend) * (1 - math.exp(-deltaTime / 0.16))
    if move and move.IsPlaying then
        move:AdjustSpeed(math.clamp(0.75 + speedBlend * 0.75, 0.75, 1.5))
    end
    if backward and backward.IsPlaying then
        backward:AdjustSpeed(math.clamp(0.80 + speedBlend * 0.60, 0.80, 1.4))
    end
end

local function destroyFlyCollisionDebugShapes()
    for _, debugPart in ipairs(flyCollisionDebugParts) do
        pcall(function()
            debugPart:Destroy()
        end)
    end
    table.clear(flyCollisionDebugParts)

    if flyCollisionDebugFolder then
        pcall(function()
            flyCollisionDebugFolder:Destroy()
        end)
        flyCollisionDebugFolder = nil
    end
end

local function destroyFlyCollisionProxy()
    destroyFlyCollisionDebugShapes()

    if flyGravityForce then
        pcall(function()
            flyGravityForce:Destroy()
        end)
        flyGravityForce = nil
    end

    for _, proxyPart in ipairs(flyCollisionProxyParts) do
        pcall(function()
            proxyPart:Destroy()
        end)
    end
    table.clear(flyCollisionProxyParts)

    if flyCollisionProxy then
        pcall(function()
            flyCollisionProxy:Destroy()
        end)
        flyCollisionProxy = nil
    end
end

local function isBodyCollisionPart(instance)
    if not instance:IsA("BasePart") then
        return false
    end

    if instance.Name == "VGD_FlyCollisionProxy"
        or instance.Name == "VGD_FlyCollisionProxyWeld" then
        return false
    end

    -- Match the avatar's actual body geometry, not accessories/tools.
    -- This covers both R6 and R15 body parts, including custom body-part
    -- packages represented by BaseParts/MeshParts.
    local ancestor = instance.Parent
    while ancestor and ancestor ~= getCharacter() do
        if ancestor:IsA("Accessory") or ancestor:IsA("Tool") then
            return false
        end
        ancestor = ancestor.Parent
    end

    return ancestor == getCharacter()
end

local function createFlyCollisionProxy()
    destroyFlyCollisionProxy()

    local character = getCharacter()
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not character or not root then
        return nil
    end

    -- Create one invisible physical clone for EVERY body BasePart.
    -- Unlike the previous single bounding box, each proxy preserves the
    -- source part's exact geometry, size, orientation, MeshPart mesh and
    -- collision fidelity. Each proxy is welded directly to its source part,
    -- so the complete collision assembly follows animations and avatar scale.
    local proxyFolder = Instance.new("Folder")
    proxyFolder.Name = "VGD_FlyCollisionProxy"
    proxyFolder.Parent = character
    flyCollisionProxy = proxyFolder

    local sourceParts = {}
    for _, instance in ipairs(character:GetDescendants()) do
        if isBodyCollisionPart(instance) then
            table.insert(sourceParts, instance)
        end
    end

    for _, sourcePart in ipairs(sourceParts) do
        local ok, proxyPart = pcall(function()
            return sourcePart:Clone()
        end)

        if ok and proxyPart and proxyPart:IsA("BasePart") then
            -- Keep the physical geometry from the source part. Remove scripts,
            -- attachments, decals and other non-geometry children so the proxy
            -- remains lightweight while retaining Part/MeshPart collision data.
            for _, child in ipairs(proxyPart:GetChildren()) do
                child:Destroy()
            end

            proxyPart.Name = "VGD_FlyCollision_" .. sourcePart.Name
            proxyPart.Transparency = 1
            proxyPart.CanCollide = not flyNoClipOn
            proxyPart.CanTouch = false
            proxyPart.CanQuery = false
            proxyPart.CastShadow = false
            proxyPart.Massless = true
            proxyPart.Anchored = false
            proxyPart.CFrame = sourcePart.CFrame
            proxyPart.Parent = proxyFolder

            pcall(function()
                proxyPart.CollisionGroup = sourcePart.CollisionGroup
            end)

            local weld = Instance.new("WeldConstraint")
            weld.Name = "VGD_FlyCollisionWeld"
            weld.Part0 = sourcePart
            weld.Part1 = proxyPart
            weld.Parent = proxyPart

            table.insert(flyCollisionProxyParts, proxyPart)
        end
    end

    updateFlyCollisionDebug()

    -- Counteract gravity with a real force instead of repeatedly teleporting
    -- the root or relying on a tiny per-frame velocity correction. This keeps
    -- the flight height stable in BOTH No Clip states while still allowing
    -- camera-driven vertical flight and controlled descent.
    local attachment = Instance.new("Attachment")
    attachment.Name = "VGD_FlyGravityAttachment"
    attachment.Parent = root

    local vectorForce = Instance.new("VectorForce")
    vectorForce.Name = "VGD_FlyGravityForce"
    vectorForce.Attachment0 = attachment
    vectorForce.RelativeTo = Enum.ActuatorRelativeTo.World
    vectorForce.ApplyAtCenterOfMass = true
    vectorForce.Force = Vector3.new(0, root.AssemblyMass * workspace.Gravity, 0)
    vectorForce.Parent = root
    flyGravityForce = vectorForce

    return proxyFolder
end

local function createFlyCollisionDebugShape(proxyPart)
    if not proxyPart or not proxyPart.Parent then
        return nil
    end

    if not flyCollisionDebugFolder then
        flyCollisionDebugFolder = Instance.new("Folder")
        flyCollisionDebugFolder.Name = "VGD_FlyCollisionShapeDebug"
        flyCollisionDebugFolder.Parent = getCharacter() or proxyPart.Parent
    end

    local debugPart
    local isApproximation = false

    -- Show the collision primitive, NOT the avatar's rendered body geometry.
    -- Primitive Parts can be represented directly. MeshParts/other complex
    -- BaseParts do not expose Roblox's internal collision hull, so use their
    -- conservative bounding-box representation instead of displaying the mesh.
    if proxyPart:IsA("Part") then
        debugPart = Instance.new("Part")
        debugPart.Shape = proxyPart.Shape
        debugPart.Size = proxyPart.Size
    elseif proxyPart:IsA("WedgePart") then
        debugPart = Instance.new("WedgePart")
        debugPart.Size = proxyPart.Size
    elseif proxyPart:IsA("CornerWedgePart") then
        debugPart = Instance.new("CornerWedgePart")
        debugPart.Size = proxyPart.Size
    else
        debugPart = Instance.new("Part")
        debugPart.Shape = Enum.PartType.Block
        debugPart.Size = proxyPart.Size
        isApproximation = true
    end

    debugPart.Name = "VGD_CollisionShape_" .. proxyPart.Name
    debugPart.CFrame = proxyPart.CFrame
    debugPart.Anchored = false
    debugPart.CanCollide = false
    debugPart.CanTouch = false
    debugPart.CanQuery = false
    debugPart.Massless = true
    debugPart.CastShadow = false
    debugPart.Material = Enum.Material.Neon
    debugPart.Color = isApproximation
        and Color3.fromRGB(255, 170, 0)
        or Color3.fromRGB(0, 200, 255)
    debugPart.Transparency = 1
    debugPart.Parent = flyCollisionDebugFolder

    local weld = Instance.new("WeldConstraint")
    weld.Name = "VGD_CollisionShapeDebugWeld"
    weld.Part0 = proxyPart
    weld.Part1 = debugPart
    weld.Parent = debugPart

    table.insert(flyCollisionDebugParts, debugPart)
    return debugPart
end

updateFlyCollisionDebug = function()
    if not flyCollisionDebugOn then
        for _, debugPart in ipairs(flyCollisionDebugParts) do
            if debugPart and debugPart.Parent then
                debugPart.Transparency = 1
            end
        end
        return
    end

    -- Rebuild only the visualization. The actual collision proxies remain
    -- completely untouched, so enabling this debug mode cannot alter physics.
    destroyFlyCollisionDebugShapes()

    if not flyCollisionProxy then
        return
    end

    for _, proxyPart in ipairs(flyCollisionProxyParts) do
        if proxyPart and proxyPart.Parent then
            local debugPart = createFlyCollisionDebugShape(proxyPart)
            if debugPart then
                debugPart.Transparency = 0.55
            end
        end
    end
end

local function disconnectFlyNoClipWatcher()
    if flyNoClipDescendantConnection then
        flyNoClipDescendantConnection:Disconnect()
        flyNoClipDescendantConnection = nil
    end
end

local function enforceFlyNoClip()
    if not flyNoClipOn then
        return
    end

    local character = getCharacter()
    if character then
        for _, instance in ipairs(character:GetDescendants()) do
            if instance:IsA("BasePart") and not instance:IsDescendantOf(flyCollisionProxy) then
                if instance.CanCollide then
                    instance.CanCollide = false
                end
            end
        end
    end

    for _, proxyPart in ipairs(flyCollisionProxyParts) do
        if proxyPart and proxyPart.Parent and proxyPart.CanCollide then
            proxyPart.CanCollide = false
        end
    end
end

local function setFlyNoClip(enabled)
    local character = getCharacter()
    if not character then return end

    disconnectFlyNoClipWatcher()

    if enabled then
        table.clear(flySavedCanCollide)
        for _, instance in ipairs(character:GetDescendants()) do
            if instance:IsA("BasePart") and not instance:IsDescendantOf(flyCollisionProxy) then
                flySavedCanCollide[instance] = instance.CanCollide
                instance.CanCollide = false
            end
        end

        -- Roblox can create/replace character parts after Fly is already active
        -- (avatar loading, package parts, accessories, tools, etc.). If that
        -- happens, immediately apply No Clip to the new part and remember its
        -- original collision state so disabling No Clip can restore it.
        flyNoClipDescendantConnection = character.DescendantAdded:Connect(function(instance)
            if not flyNoClipOn then
                return
            end

            if instance:IsA("BasePart") and not instance:IsDescendantOf(flyCollisionProxy) then
                flySavedCanCollide[instance] = instance.CanCollide
                instance.CanCollide = false
            end
        end)
    else
        for part, canCollide in pairs(flySavedCanCollide) do
            if part and part.Parent then
                part.CanCollide = canCollide
            end
        end
        table.clear(flySavedCanCollide)
    end

    for _, proxyPart in ipairs(flyCollisionProxyParts) do
        if proxyPart and proxyPart.Parent then
            proxyPart.CanCollide = not enabled
        end
    end
end

local function saveCharacterState(humanoid, root)
    flySaved = {
        humanoid = humanoid,
        root = root,
        platformStand = humanoid.PlatformStand,
        autoRotate = humanoid.AutoRotate,
        anchored = root.Anchored,
        rootVelocity = root.AssemblyLinearVelocity,
        rootAngularVelocity = root.AssemblyAngularVelocity,
    }

    -- The hologram has no default Animate script because its scripts are
    -- stripped from the clone. The real character still has Roblox's Animate
    -- controller, which can fight the flight tracks and cause visible jitter.
    local character = humanoid.Parent
    local animate = character and character:FindFirstChild("Animate")
    flyAnimateScript = animate
    flyAnimateScriptDisabled = false
    if animate and (animate:IsA("LocalScript") or animate:IsA("Script")) then
        flyAnimateScriptDisabled = animate.Disabled
        animate.Disabled = true
    end
end

local function restoreCharacterState()
    local saved = flySaved
    flySaved = nil
    stopTracks()

    local humanoid, root = getHumanoidAndRoot()
    if saved and saved.humanoid and saved.humanoid.Parent == getCharacter() then humanoid = saved.humanoid end
    if saved and saved.root and saved.root.Parent == getCharacter() then root = saved.root end

    if humanoid then
        humanoid.PlatformStand = saved and saved.platformStand or false
        humanoid.AutoRotate = saved and saved.autoRotate or true
    end

    if flyAnimateScript and flyAnimateScript.Parent then
        flyAnimateScript.Disabled = flyAnimateScriptDisabled
    end
    flyAnimateScript = nil
    flyAnimateScriptDisabled = false
    if root then
        root.Anchored = saved and saved.anchored or false
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end
    currentMoveVector = Vector3.zero
    flyPosition = nil
end

local flyBodyYaw = 0
local flyFlightPreviousDesiredYaw = nil
local flyHologramMoveBlend = 0
local flyAnimTime = 0

local function shortestAngleDelta(fromAngle, toAngle)
    return math.atan2(math.sin(toAngle - fromAngle), math.cos(toAngle - fromAngle))
end

local function flyCameraIsInDynamicThumbstickArea(position)
    local playerGui = player:FindFirstChildOfClass("PlayerGui")
    local touchGui = playerGui and playerGui:FindFirstChild("TouchGui")
    if not touchGui or not touchGui.Enabled then
        return false
    end

    local touchFrame = touchGui:FindFirstChild("TouchControlFrame")
    local thumbstickFrame =
        touchFrame and touchFrame:FindFirstChild("DynamicThumbstickFrame")
    if not thumbstickFrame then
        return false
    end

    local topLeft = thumbstickFrame.AbsolutePosition
    local bottomRight = topLeft + thumbstickFrame.AbsoluteSize

    return position.X >= topLeft.X
        and position.X <= bottomRight.X
        and position.Y >= topLeft.Y
        and position.Y <= bottomRight.Y
end

local function flyCameraIsOverGui(position)
    if not position then
        return false
    end

    local ok, objects = pcall(function()
        return GuiService:GetGuiObjectsAtPosition(position.X, position.Y)
    end)

    if not ok or not objects then
        return false
    end

    for _, object in ipairs(objects) do
        if object:IsDescendantOf(screenGui) then
            return true
        end
    end

    return false
end

local function flyCameraAdjustTouchPitchSensitivity(delta)
    local camera = workspace.CurrentCamera
    if not camera then
        return delta
    end

    local pitch = camera.CFrame:ToEulerAnglesYXZ()

    if delta.Y * pitch >= 0 then
        return delta
    end

    local minimumFraction = 0.25
    local curveY = 1 - (2 * math.abs(pitch) / math.pi) ^ 0.75
    local sensitivity =
        curveY * (1 - minimumFraction) + minimumFraction

    return Vector2.new(delta.X, delta.Y * sensitivity)
end

local function flyCameraResetInput()
    table.clear(flyCameraTouchStates)
    table.clear(flyCameraZoomTouchPositions)
    flyCameraPinchLastDiameter = nil
    flyCameraTouchDelta = Vector2.new()
    flyCameraMouseDelta = Vector2.new()
    flyCameraMouseLooking = false
end

local function flyCameraSmoothLook(dt)
    local alpha =
        1 - math.exp(-FLY_CAMERA_LOOK_SMOOTHNESS * math.max(dt, 0))

    flyCameraYaw =
        flyCameraYaw + (flyCameraTargetYaw - flyCameraYaw) * alpha

    flyCameraPitch =
        flyCameraPitch + (flyCameraTargetPitch - flyCameraPitch) * alpha
end

local function flyCameraApplyLookInput()
    local mouseDelta = flyCameraMouseDelta
    flyCameraMouseDelta = Vector2.new()

    if mouseDelta.Magnitude > 0 then
        local rotation = Vector2.new(
            mouseDelta.X * FLY_CAMERA_MOUSE_ROTATION_SPEED.X,
            mouseDelta.Y * FLY_CAMERA_MOUSE_ROTATION_SPEED.Y
        )

        flyCameraTargetYaw =
            flyCameraTargetYaw - rotation.X

        flyCameraTargetPitch = math.clamp(
            flyCameraTargetPitch - rotation.Y,
            FLY_CAMERA_MIN_PITCH,
            FLY_CAMERA_MAX_PITCH
        )
    end
end

local function disconnectFlyCameraInput()
    ContextActionService:UnbindAction("VGD_FlyCameraTouch")

    for _, connection in pairs(flyCameraConnections) do
        pcall(function()
            connection:Disconnect()
        end)
    end

    table.clear(flyCameraConnections)
    flyCameraResetInput()
    flyCameraPinchLastDiameter = nil
    table.clear(flyCameraZoomTouchPositions)
end

local function connectFlyCameraInput()
    disconnectFlyCameraInput()

    -- Match Freecam's proven mobile touch architecture exactly.
    -- ContextActionService owns world touches, and the same touch table is
    -- used to detect a two-finger pinch because the touch action consumes
    -- the touches before UserInputService.TouchPinch can be relied on.
    local touchAction = function(_, inputState, inputObject)
        if not flyEnabled
            or inputObject.UserInputType ~= Enum.UserInputType.Touch then
            return Enum.ContextActionResult.Pass
        end

        if inputState == Enum.UserInputState.Begin then
            if flyCameraIsInDynamicThumbstickArea(inputObject.Position)
                or flyCameraIsOverGui(inputObject.Position) then
                return Enum.ContextActionResult.Pass
            end

            flyCameraTouchStates[inputObject] = true
            flyCameraZoomTouchPositions[inputObject] = inputObject.Position

            local zoomTouchCount = 0
            local firstZoomPosition = nil
            local secondZoomPosition = nil
            for _, position in pairs(flyCameraZoomTouchPositions) do
                zoomTouchCount += 1
                if not firstZoomPosition then
                    firstZoomPosition = position
                elseif not secondZoomPosition then
                    secondZoomPosition = position
                end
            end

            if zoomTouchCount >= 2 then
                flyCameraPinchLastDiameter =
                    (firstZoomPosition - secondZoomPosition).Magnitude
            end

            return Enum.ContextActionResult.Sink
        end

        if flyCameraTouchStates[inputObject] then
            if inputState == Enum.UserInputState.Change then
                flyCameraZoomTouchPositions[inputObject] = inputObject.Position

                local zoomTouchCount = 0
                local firstZoomPosition = nil
                local secondZoomPosition = nil
                for _, position in pairs(flyCameraZoomTouchPositions) do
                    zoomTouchCount += 1
                    if not firstZoomPosition then
                        firstZoomPosition = position
                    elseif not secondZoomPosition then
                        secondZoomPosition = position
                    end
                end

                if zoomTouchCount >= 2 then
                    local diameter =
                        (firstZoomPosition - secondZoomPosition).Magnitude

                    if flyCameraPinchLastDiameter then
                        local pinchDelta =
                            diameter - flyCameraPinchLastDiameter
                        local zoomDelta = -pinchDelta * 0.04
                        local currentZoom = flyCameraTargetZoomDistance
                        local newZoom

                        if zoomDelta > 0 then
                            newZoom = currentZoom
                                + zoomDelta * (1 + currentZoom * 0.5)
                        else
                            newZoom = (currentZoom + zoomDelta)
                                / (1 - zoomDelta * 0.5)
                        end

                        flyCameraTargetZoomDistance = math.clamp(
                            newZoom,
                            FLY_CAMERA_ZOOM_MIN,
                            FLY_CAMERA_ZOOM_MAX
                        )
                    end

                    flyCameraPinchLastDiameter = diameter
                    return Enum.ContextActionResult.Sink
                end

                local delta = inputObject.Delta
                if delta.Magnitude > 0 then
                    delta = flyCameraAdjustTouchPitchSensitivity(delta)
                    local rotation = Vector2.new(
                        delta.X * FLY_CAMERA_TOUCH_ROTATION_SPEED.X,
                        delta.Y * FLY_CAMERA_TOUCH_ROTATION_SPEED.Y
                    )
                    flyCameraTargetYaw = flyCameraTargetYaw - rotation.X
                    flyCameraTargetPitch = math.clamp(
                        flyCameraTargetPitch - rotation.Y,
                        FLY_CAMERA_MIN_PITCH,
                        FLY_CAMERA_MAX_PITCH
                    )
                end
                return Enum.ContextActionResult.Sink
            end

            if inputState == Enum.UserInputState.End
                or inputState == Enum.UserInputState.Cancel then
                flyCameraTouchStates[inputObject] = nil
                flyCameraZoomTouchPositions[inputObject] = nil

                local zoomTouchCount = 0
                for _ in pairs(flyCameraZoomTouchPositions) do
                    zoomTouchCount += 1
                end
                if zoomTouchCount < 2 then
                    flyCameraPinchLastDiameter = nil
                end

                return Enum.ContextActionResult.Sink
            end

            return Enum.ContextActionResult.Sink
        end

        return Enum.ContextActionResult.Pass
    end

    ContextActionService:BindActionAtPriority(
        "VGD_FlyCameraTouch",
        touchAction,
        false,
        Enum.ContextActionPriority.High.Value,
        Enum.UserInputType.Touch
    )

    flyCameraConnections.TouchEnded = UserInputService.TouchEnded:Connect(function(input)
        flyCameraTouchStates[input] = nil
        flyCameraZoomTouchPositions[input] = nil

        local zoomTouchCount = 0
        for _ in pairs(flyCameraZoomTouchPositions) do
            zoomTouchCount += 1
        end
        if zoomTouchCount < 2 then
            flyCameraPinchLastDiameter = nil
        end
    end)

    -- Desktop: same right-mouse drag behavior as Freecam.
    flyCameraConnections.MouseBegan =
        UserInputService.InputBegan:Connect(function(
            input,
            gameProcessedEvent
        )
            if not flyEnabled or gameProcessedEvent then
                return
            end

            if input.UserInputType == Enum.UserInputType.MouseButton2 then
                flyCameraMouseLooking = true
            end
        end)

    flyCameraConnections.MouseChanged =
        UserInputService.InputChanged:Connect(function(input)
            if not flyEnabled or not flyCameraMouseLooking then
                return
            end

            if input.UserInputType == Enum.UserInputType.MouseMovement then
                flyCameraMouseDelta += input.Delta
            end
        end)

    flyCameraConnections.MouseEnded =
        UserInputService.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton2 then
                flyCameraMouseLooking = false
            end
        end)

    -- Match Freecam's desktop zoom exactly.
    flyCameraConnections.MouseWheel = UserInputService.InputChanged:Connect(function(input)
        if not flyEnabled then
            return
        end

        if input.UserInputType == Enum.UserInputType.MouseWheel then
            local wheel = input.Position.Z

            if wheel ~= 0 then
                local zoomDelta = -wheel
                local currentZoom = flyCameraTargetZoomDistance
                local newZoom

                if zoomDelta > 0 then
                    newZoom = currentZoom
                        + zoomDelta * (1 + currentZoom * 0.5)
                else
                    newZoom = (currentZoom + zoomDelta)
                        / (1 - zoomDelta * 0.5)
                end

                flyCameraTargetZoomDistance = math.clamp(
                    newZoom,
                    FLY_CAMERA_ZOOM_MIN,
                    FLY_CAMERA_ZOOM_MAX
                )
            end
        end
    end)

end

local function getFlyCameraCFrame(subjectPosition)
    local cameraLookCFrame =
        CFrame.new(subjectPosition) *
        CFrame.Angles(0, flyCameraYaw, 0) *
        CFrame.Angles(flyCameraPitch, 0, 0)

    local cameraLook = cameraLookCFrame.LookVector
    local cameraUp = cameraLookCFrame.UpVector

    -- The lateral/shoulder offset is intentionally zero. Preserve only the
    -- normal camera's vertical framing, expressed along the camera's own
    -- UpVector so rotating the camera cannot introduce a world-space offset
    -- that makes the body drift or twitch.
    local cameraPosition =
        subjectPosition
        - cameraLook * flyCameraZoomDistance
        + cameraUp * flyCameraVerticalOffset

    return CFrame.lookAt(cameraPosition, cameraPosition + cameraLook, cameraUp)
end

local function updateFly(deltaTime)
    if not flyEnabled then return end

    local humanoid, root = getHumanoidAndRoot()
    local cam = workspace.CurrentCamera
    if not humanoid or not root or not cam then return end

    -- Apply the same smooth target->current zoom interpolation used by
    -- Freecam. v28 updated flyCameraTargetZoomDistance correctly, but it
    -- never copied that target into flyCameraZoomDistance, so the camera
    -- stayed at the original distance forever.
    local zoomAlpha = 1 - math.exp(-14 * math.max(deltaTime, 0))
    flyCameraZoomDistance = flyCameraZoomDistance
        + (flyCameraTargetZoomDistance - flyCameraZoomDistance) * zoomAlpha

    -- No Clip is authoritative while enabled. Re-assert the state every
    -- render frame so a transient Roblox physics/avatar update cannot leave
    -- one body part or collision proxy collidable for a frame. The actual
    -- v21 physics collision system is untouched when No Clip is OFF.
    enforceFlyNoClip()

    local dt = math.max(deltaTime or 0, 0)
    if not flyPosition then
        flyPosition = root.Position
    end

    -- ================================================================
    -- THIS IS THE FREECAM HOLOGRAM FLIGHT ALGORITHM, PORTED DIRECTLY.
    -- The hologram's PivotTo() is replaced only by root.CFrame = ... .
    -- No velocity flight, no physics smoothing, no separate body steering.
    -- ================================================================

    -- The Fly now owns the camera exactly like Freecam. Look input has
    -- already been consumed/smoothed for this render frame, so movement is
    -- derived from Fly's own camera orientation instead of Roblox CameraModule.
    flyCameraApplyLookInput()
    flyCameraSmoothLook(dt)

    local cameraLookCFrame =
        CFrame.new(flyPosition) *
        CFrame.Angles(0, flyCameraYaw, 0) *
        CFrame.Angles(flyCameraPitch, 0, 0)
    local cameraLook = cameraLookCFrame.LookVector
    local cameraRight = cameraLookCFrame.RightVector
    local moveDirection = humanoid.MoveDirection
    local horizontalMove = Vector3.new(moveDirection.X, 0, moveDirection.Z)

    local horizontalLook = Vector3.new(cameraLook.X, 0, cameraLook.Z)
    local horizontalRight = Vector3.new(cameraRight.X, 0, cameraRight.Z)

    if horizontalLook.Magnitude > 0.001 then
        horizontalLook = horizontalLook.Unit
    else
        horizontalLook = Vector3.new(0, 0, -1)
    end

    if horizontalRight.Magnitude > 0.001 then
        horizontalRight = horizontalRight.Unit
    else
        horizontalRight = Vector3.new(1, 0, 0)
    end

    local forwardInput = math.clamp(horizontalMove:Dot(horizontalLook), -1, 1)
    local rightInput = math.clamp(horizontalMove:Dot(horizontalRight), -1, 1)

    local moveVector =
        (cameraLook * forwardInput) +
        (horizontalRight * rightInput)

    if moveVector.Magnitude > 1 then
        moveVector = moveVector.Unit
    end

    -- The real-body Fly follows the same camera-pitch flight as the hologram.
    -- Space/Ctrl remains an optional extra vertical input, but the normal
    -- flight path itself is entirely driven by joystick + camera look.
    if math.abs(flyVerticalInput) > 0.001 then
        moveVector = moveVector + Vector3.new(0, flyVerticalInput, 0)
        if moveVector.Magnitude > 1 then
            moveVector = moveVector.Unit
        end
    end

    local isMoving = moveVector.Magnitude > 0.05

    -- ================================================================
    -- PHYSICS-DRIVEN POSITION / REAL COLLISION
    -- ================================================================
    -- No Clip OFF uses the exact v21 individual body-part collision proxies
    -- and real assembly velocity. The physics solver owns translation here.
    --
    -- No Clip ON is intentionally different: it becomes a TRUE ghost mode.
    -- We do not let the physics solver translate the character at all. The
    -- desired position is advanced directly and the body is re-applied from
    -- that position later in this render step. This prevents a touching
    -- object OR another player's character from getting one physics frame to
    -- push the Fly before the CanCollide state catches up.
    if flyNoClipOn then
        if flyGravityForce and flyGravityForce.Parent then
            flyGravityForce.Force = Vector3.zero
        end

        flyPosition = flyPosition + moveVector * flySpeed * dt
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    else
        if flyGravityForce and flyGravityForce.Parent then
            flyGravityForce.Force = Vector3.new(
                0,
                root.AssemblyMass * workspace.Gravity,
                0
            )
        end

        root.AssemblyLinearVelocity = moveVector * flySpeed

        -- The physics solver owns the position in No Clip OFF mode.
        flyPosition = root.Position
    end

    -- ================================================================
    -- EXACT HOLOGRAM BASE CFRAME
    -- ================================================================
    -- ================================================================
    -- EXACT HOLOGRAM HEADING / TURN BANK
    -- ================================================================
    -- Shift Lock ON  = body follows camera yaw.
    -- Shift Lock OFF = body follows the horizontal movement direction.
    --
    -- IMPORTANT: build the actual body base CFrame from flyBodyYaw. The old
    -- v11 code built it directly from camera look, so the body continued to
    -- face the camera even after the button was switched OFF.
    -- Match Freecam exactly:
    -- Shift Lock ON  -> body follows the camera yaw.
    -- Shift Lock OFF -> camera yaw is completely ignored unless the player
    -- is actually moving; while stationary, keep the current body heading.
    local desiredFlightYaw = flyBodyYaw or 0
    if flyShiftLockOn then
        desiredFlightYaw = flyCameraYaw
    elseif horizontalMove.Magnitude > 0.001 and isMoving then
        local movementUnit = horizontalMove.Unit
        desiredFlightYaw = math.atan2(-movementUnit.X, -movementUnit.Z)
    end

    local yawDelta = shortestAngleDelta(flyBodyYaw or 0, desiredFlightYaw)
    local yawDuration = (isMoving and not flyShiftLockOn) and 0.14 or 0.06
    local yawAlpha = 1 - math.exp(-dt / yawDuration)
    flyBodyYaw = (flyBodyYaw or 0) + yawDelta * yawAlpha

    -- Now that flyBodyYaw has been smoothed, use it as the character's actual
    -- horizontal facing. Camera yaw remains independent from body yaw when
    -- Shift Lock is OFF.
    local bodyLook = Vector3.new(
        -math.sin(flyBodyYaw),
        0,
        -math.cos(flyBodyYaw)
    )
    local baseCFrame = CFrame.lookAt(
        flyPosition,
        flyPosition + bodyLook,
        Vector3.new(0, 1, 0)
    )

    -- Pose/lean directions still use the CAMERA's horizontal look, exactly
    -- like Freecam. Only the body's YAW is decoupled when Shift Lock is off.
    local flatLook = horizontalLook

    local previousDesiredYaw = flyFlightPreviousDesiredYaw
    local desiredYawDelta = previousDesiredYaw
        and shortestAngleDelta(previousDesiredYaw, desiredFlightYaw)
        or 0
    flyFlightPreviousDesiredYaw = desiredFlightYaw

    local turnRate = desiredYawDelta / math.max(dt, 1 / 240)
    local targetBank = 0
    if isMoving and math.abs(turnRate) > 0.001 then
        targetBank = math.clamp(
            -turnRate * 0.11,
            math.rad(-18),
            math.rad(18)
        )
    end

    local bankDuration = isMoving and 0.10 or 0.24
    local bankAlpha = 1 - math.exp(-dt / bankDuration)
    flightBankBlend = flightBankBlend
        + (targetBank - flightBankBlend) * bankAlpha

    -- ================================================================
    -- EXACT HOLOGRAM POSE BLEND
    -- ================================================================
    flyAnimTime = flyAnimTime + dt

    local targetMove = isMoving and 1 or 0
    local transitionDuration = targetMove > flyHologramMoveBlend and 0.18 or 0.30
    local direction = targetMove > flyHologramMoveBlend and 1 or -1

    if math.abs(targetMove - flyHologramMoveBlend) > 0.0001 then
        flyHologramMoveBlend = flyHologramMoveBlend
            + direction * (dt / transitionDuration)
    end
    flyHologramMoveBlend = math.clamp(flyHologramMoveBlend, 0, 1)

    local rawMoveBlend = flyHologramMoveBlend
    local b = rawMoveBlend * rawMoveBlend * (3 - 2 * rawMoveBlend)

    -- Same animation state test/crossfade as the hologram.
    updateFlyAnimations(isMoving, moveVector, dt, forwardInput)

    local forwardTarget = 0
    local rightTarget = 0
    if moveVector.Magnitude > 0.001 and isMoving then
        local moveUnit = moveVector.Unit
        forwardTarget = math.clamp(moveUnit:Dot(flatLook), -1, 1)

        local flatRight = flatLook:Cross(Vector3.new(0, 1, 0))
        if flatRight.Magnitude > 0.001 then
            flatRight = flatRight.Unit
            rightTarget = math.clamp(moveUnit:Dot(flatRight), -1, 1)
        end
    end

    local directionDuration = isMoving and 0.08 or 0.48
    local directionAlpha = 1 - math.exp(-dt / directionDuration)
    forwardBlend = forwardBlend
        + (forwardTarget - forwardBlend) * directionAlpha
    rightBlend = rightBlend
        + (rightTarget - rightBlend) * directionAlpha

    local movementForward = forwardBlend
    local movementRight = rightBlend

    local flyLeanPitch = math.rad(16) * movementForward * b
    local flyLeanRoll = math.rad(14) * movementRight * b

    local verticalTravelRatio = 0
    if moveVector.Magnitude > 0.001 then
        verticalTravelRatio = math.clamp(math.abs(moveVector.Unit.Y), 0, 1)
    end
    local horizontalSpeedPose = 1 - verticalTravelRatio

    local speedTarget = isMoving
        and math.clamp(moveVector.Magnitude, 0, 1)
        or 0
    speedBlend = speedBlend
        + (speedTarget - speedBlend)
        * (1 - math.exp(-dt / (isMoving and 0.16 or 0.30)))

    local speedPosePitch = math.rad(10)
        * speedBlend
        * horizontalSpeedPose
        * b

    -- Exact hologram flight pitch from the 3D travel vector.
    local travelHorizontalMagnitude = Vector3.new(
        moveVector.X, 0, moveVector.Z
    ).Magnitude

    local flightPitchTarget = 0
    if isMoving then
        if travelHorizontalMagnitude > 0.001 then
            flightPitchTarget = math.atan2(
                moveVector.Y,
                travelHorizontalMagnitude
            )
        elseif math.abs(moveVector.Y) > 0.001 then
            flightPitchTarget = moveVector.Y > 0
                and math.rad(90)
                or math.rad(-90)
        end
    end

    flightPitchTarget = math.clamp(
        flightPitchTarget,
        math.rad(-75),
        math.rad(75)
    )

    local flightPitchDuration = isMoving and 0.10 or 0.22
    flightPitchBlend = flightPitchBlend
        + (flightPitchTarget - flightPitchBlend)
        * (1 - math.exp(-dt / flightPitchDuration))

    local flightPitch = flightPitchBlend * b

    -- Exact hologram bob + hover. This was missing from the previous Fly
    -- version and is one of the reasons the real body felt different.
    local idleBob = math.sin(flyAnimTime * 1.8) * 0.025
    local flyBob = math.sin(flyAnimTime * 3.6) * 0.045
    local bob = idleBob * (1 - b) + flyBob * b

    local hoverTarget = (not isMoving) and 1 or 0
    local hoverAlpha = 1 - math.exp(-dt / ((hoverTarget > 0.5) and 0.20 or 0.16))
    hoverBlend = hoverBlend
        + (hoverTarget - hoverBlend) * hoverAlpha

    local hoverBob = math.sin(flyAnimTime * 1.55) * 0.10 * hoverBlend
    local hoverRoll = math.sin(flyAnimTime * 1.10 + 0.7)
        * math.rad(1.2) * hoverBlend
    local hoverYaw = math.sin(flyAnimTime * 0.82 + 1.4)
        * math.rad(0.8) * hoverBlend

    -- EXACT same final pose equation as the hologram.
    local animatedCFrame =
        baseCFrame *
        CFrame.new(0, bob + hoverBob, 0) *
        CFrame.Angles(
            flightPitch - flyLeanPitch - speedPosePitch,
            hoverYaw,
            -flyLeanRoll - flightBankBlend + hoverRoll
        )

    -- No Clip ON owns the position directly so the character cannot be
    -- physically pushed back by another player or an object. No Clip OFF keeps
    -- the v21 physics-resolved position completely untouched.
    if flyNoClipOn then
        root.CFrame = CFrame.new(flyPosition) * animatedCFrame.Rotation
        root.AssemblyLinearVelocity = Vector3.zero
    else
        root.CFrame = CFrame.new(root.Position) * animatedCFrame.Rotation
        flyPosition = root.Position
    end
    root.AssemblyAngularVelocity = Vector3.zero

    -- Aim above the HumanoidRootPart so the camera is raised relative to
    -- the body. The body itself is never moved for framing.
    cam.CFrame = getFlyCameraCFrame(flyPosition)
    cam.FieldOfView = flyCameraSavedFOV or cam.FieldOfView
    cam.Focus = CFrame.new(flyPosition)
end

local function verticalAction(_, inputState, inputObject)
    if not flyEnabled then return Enum.ContextActionResult.Pass end
    local direction = 0
    if inputObject.KeyCode == Enum.KeyCode.Space then direction = 1
    elseif inputObject.KeyCode == Enum.KeyCode.LeftControl or inputObject.KeyCode == Enum.KeyCode.C then direction = -1 end
    if inputState == Enum.UserInputState.Begin then
        flyVerticalInput = direction
    elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
        if flyVerticalInput == direction then flyVerticalInput = 0 end
    end
    return Enum.ContextActionResult.Sink
end

local function bindVerticalControls()
    ContextActionService:BindActionAtPriority("VGD_FlyVertical", verticalAction, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.Space, Enum.KeyCode.LeftControl, Enum.KeyCode.C)
end

local function unbindVerticalControls()
    ContextActionService:UnbindAction("VGD_FlyVertical")
    flyVerticalInput = 0
end

local updateFlyShiftLockButton

local function enableFly()
    if flyEnabled then return true end
    local humanoid, root = getHumanoidAndRoot()
    if not humanoid or not root then return false end

    saveCharacterState(humanoid, root)
    flyEnabled = true
    flyShiftLockOn = true
    flyNoClipOn = true
    updateFlyShiftLockButton()
    setFlyNoClip(true)
    flyVerticalInput = 0
    forwardBlend, rightBlend, flightPitchBlend, flightBankBlend, speedBlend, hoverBlend = 0, 0, 0, 0, 0, 0
    flyBodyYaw = math.atan2(root.CFrame.LookVector.X, -root.CFrame.LookVector.Z)
    flyFlightPreviousDesiredYaw = flyBodyYaw
    flyHologramMoveBlend = 0
    flyAnimTime = 0
    humanoid.PlatformStand = true
    humanoid.AutoRotate = false
    root.Anchored = false
    createFlyCollisionProxy()
    currentMoveVector = Vector3.zero

    -- Take ownership of the camera, using the same starting viewpoint model
    -- as Freecam. The camera is then reconstructed from yaw/pitch every render
    -- frame, so body rotation can never feed back into camera rotation.
    flyCameraSavedType = workspace.CurrentCamera.CameraType
    flyCameraSavedSubject = workspace.CurrentCamera.CameraSubject
    flyCameraSavedCFrame = workspace.CurrentCamera.CFrame
    flyCameraSavedFOV = workspace.CurrentCamera.FieldOfView

    local startCamera = workspace.CurrentCamera
    local startLook = startCamera.CFrame.LookVector
    local startPosition = startCamera.CFrame.Position

    -- Match the actual normal Roblox camera relationship used by Freecam:
    -- project the camera position onto the look axis from the character, then
    -- preserve the normal camera's vertical component only. We deliberately
    -- discard lateral/shoulder offset so the real body remains centered.
    local startDistanceAlongLook =
        (startPosition - root.Position):Dot(-startLook)

    if startDistanceAlongLook <= 0.01 then
        startDistanceAlongLook =
            (startPosition - root.Position).Magnitude
    end

    flyCameraZoomDistance = math.clamp(
        startDistanceAlongLook,
        FLY_CAMERA_ZOOM_MIN,
        FLY_CAMERA_ZOOM_MAX
    )
    flyCameraTargetZoomDistance = flyCameraZoomDistance

    local normalCameraLinePosition =
        root.Position - startLook * startDistanceAlongLook
    local normalCameraOffset =
        startPosition - normalCameraLinePosition

    -- Keep only the vertical component of the normal camera offset. Express it
    -- in the starting camera's UpVector so it can rotate naturally with the
    -- camera without creating lateral drift.
    flyCameraVerticalOffset =
        normalCameraOffset:Dot(startCamera.CFrame.UpVector)

    flyCameraOffset = Vector3.zero
    flyCameraPitch, flyCameraYaw = startCamera.CFrame:ToOrientation()
    flyCameraTargetPitch = flyCameraPitch
    flyCameraTargetYaw = flyCameraYaw
    flyBodyYaw = flyCameraYaw
    flyFlightPreviousDesiredYaw = flyCameraYaw
    flyCameraResetInput()

    flyPosition = root.Position
    loadFlyAnimations(humanoid)
    bindVerticalControls()
    connectFlyCameraInput()
    -- Fly owns the camera while enabled, just like Freecam.\n    startCamera.CameraType = Enum.CameraType.Scriptable

    if flyRenderConnection then
        RunService:UnbindFromRenderStep("VGD_FlySmooth")
        flyRenderConnection = nil
    end

    -- Run immediately AFTER Roblox's CameraModule. This is the critical
    -- difference from v3: the flight controller now reads the freshly updated
    -- camera direction in the same render frame, exactly like Freecam's own
    -- Camera.Value + 1 render pass. We then translate the camera by the body's
    -- exact displacement so there is no visible one-frame follow lag.
    RunService:BindToRenderStep(
        "VGD_FlySmooth",
        Enum.RenderPriority.Camera.Value + 1,
        updateFly
    )
    flyRenderConnection = true
    stateChangedEvent:Fire(true)
    return true
end

local function disableFly()
    if not flyEnabled then return false end
    flyEnabled = false
    updateFlyShiftLockButton()
    unbindVerticalControls()
    if flyRenderConnection then
        RunService:UnbindFromRenderStep("VGD_FlySmooth")
        flyRenderConnection = nil
    end
    disconnectFlyCameraInput()
    disconnectFlyNoClipWatcher()

    local camera = workspace.CurrentCamera
    if camera then
        camera.CameraType = flyCameraSavedType or Enum.CameraType.Custom
        camera.CameraSubject = flyCameraSavedSubject
        if flyCameraSavedCFrame then
            camera.CFrame = flyCameraSavedCFrame
        end
        if flyCameraSavedFOV then
            camera.FieldOfView = flyCameraSavedFOV
        end
    end
    flyCameraSavedType = nil
    flyCameraSavedSubject = nil
    flyCameraSavedCFrame = nil
    flyCameraSavedFOV = nil
    setFlyNoClip(false)
    destroyFlyCollisionProxy()
    restoreCharacterState()
    stateChangedEvent:Fire(false)
    return false
end

player.CharacterAdded:Connect(function(character)
    task.spawn(function()
        character:WaitForChild("Humanoid", 10)
        character:WaitForChild("HumanoidRootPart", 10)
        if flyEnabled then
            task.defer(function()
                if flyEnabled then
                    local humanoid, root = getHumanoidAndRoot()
                    if humanoid and root then
                        flySaved = nil
                        saveCharacterState(humanoid, root)
                        createFlyCollisionProxy()
                        setFlyNoClip(flyNoClipOn)
                        humanoid.PlatformStand = true
                        humanoid.AutoRotate = false
                        root.Anchored = false
                        currentMoveVector = Vector3.zero
                        flyPosition = root.Position
                        flyBodyYaw = math.atan2(root.CFrame.LookVector.X, -root.CFrame.LookVector.Z)
                        flyFlightPreviousDesiredYaw = flyBodyYaw
                        loadFlyAnimations(humanoid)
                    end
                end
            end)
        end
    end)
end)

-- =========================================================
-- MINI GUI
-- =========================================================

screenGui = Instance.new("ScreenGui")
screenGui.Name = "VGD_Fly_Standalone"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.DisplayOrder = 1998
screenGui.Enabled = not GUI_CONTROLLED
screenGui.Parent = player:WaitForChild("PlayerGui")

local panel = Instance.new("Frame")
panel.Size = UDim2.fromOffset(220, 197)
panel.Position = UDim2.new(1, -232, 0, 92)
panel.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
panel.BackgroundTransparency = 0.08
panel.BorderSizePixel = 0
panel.Parent = screenGui
Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 12)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -20, 0, 24)
title.Position = UDim2.fromOffset(10, 7)
title.BackgroundTransparency = 1
title.Text = "VGD  •  FLY"
title.TextColor3 = Color3.new(1, 1, 1)
title.Font = Enum.Font.GothamBold
title.TextSize = 15
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = panel

local closeButton = Instance.new("TextButton")
closeButton.Size = UDim2.fromOffset(22, 22)
closeButton.Position = UDim2.new(1, -29, 0, 5)
closeButton.BackgroundTransparency = 1
closeButton.Text = "×"
closeButton.TextColor3 = Color3.fromRGB(180, 180, 180)
closeButton.Font = Enum.Font.GothamBold
closeButton.TextSize = 18
closeButton.Parent = panel

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -20, 0, 18)
status.Position = UDim2.fromOffset(10, 31)
status.BackgroundTransparency = 1
status.Text = "OFF"
status.TextColor3 = Color3.fromRGB(170, 170, 170)
status.Font = Enum.Font.Gotham
status.TextSize = 11
status.TextXAlignment = Enum.TextXAlignment.Left
status.Parent = panel

local speedBox = Instance.new("TextBox")
speedBox.Size = UDim2.fromOffset(92, 30)
speedBox.Position = UDim2.fromOffset(10, 54)
speedBox.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
speedBox.BorderSizePixel = 0
speedBox.TextColor3 = Color3.new(1, 1, 1)
speedBox.PlaceholderText = "Speed"
speedBox.Text = tostring(flySpeed)
speedBox.Font = Enum.Font.Gotham
speedBox.TextSize = 12
speedBox.ClearTextOnFocus = false
speedBox.Parent = panel
Instance.new("UICorner", speedBox).CornerRadius = UDim.new(0, 8)

local toggle = Instance.new("TextButton")
toggle.Size = UDim2.fromOffset(102, 30)
toggle.Position = UDim2.fromOffset(108, 54)
toggle.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
toggle.BorderSizePixel = 0
toggle.TextColor3 = Color3.new(1, 1, 1)
toggle.Text = "ENABLE"
toggle.Font = Enum.Font.GothamBold
toggle.TextSize = 11
toggle.Parent = panel
Instance.new("UICorner", toggle).CornerRadius = UDim.new(0, 8)

local noClipToggle = Instance.new("TextButton")
noClipToggle.Size = UDim2.fromOffset(200, 30)
noClipToggle.Position = UDim2.fromOffset(10, 91)
noClipToggle.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
noClipToggle.BorderSizePixel = 0
noClipToggle.TextColor3 = Color3.new(1, 1, 1)
noClipToggle.Font = Enum.Font.GothamBold
noClipToggle.TextSize = 11
noClipToggle.Parent = panel
Instance.new("UICorner", noClipToggle).CornerRadius = UDim.new(0, 8)

local collisionDebugToggle = Instance.new("TextButton")
collisionDebugToggle.Size = UDim2.fromOffset(200, 30)
collisionDebugToggle.Position = UDim2.fromOffset(10, 126)
collisionDebugToggle.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
collisionDebugToggle.BorderSizePixel = 0
collisionDebugToggle.TextColor3 = Color3.new(1, 1, 1)
collisionDebugToggle.Font = Enum.Font.GothamBold
collisionDebugToggle.TextSize = 11
collisionDebugToggle.Parent = panel
Instance.new("UICorner", collisionDebugToggle).CornerRadius = UDim.new(0, 8)

local hint = Instance.new("TextLabel")
hint.Size = UDim2.new(1, -20, 0, 28)
hint.Position = UDim2.fromOffset(10, 163)
hint.BackgroundTransparency = 1
hint.Text = "Move + look to climb/dive   •   Space/Ctrl optional"
hint.TextColor3 = Color3.fromRGB(145, 145, 145)
hint.Font = Enum.Font.Gotham
hint.TextSize = 9
hint.TextXAlignment = Enum.TextXAlignment.Left
hint.Parent = panel

-- Small shortcut button used after the mini GUI is hidden.
local shortcut = Instance.new("TextButton")
shortcut.Size = UDim2.fromOffset(74, 32)
shortcut.Position = UDim2.new(1, -84, 0, 92)
shortcut.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
shortcut.BackgroundTransparency = 0.08
shortcut.BorderSizePixel = 0
shortcut.TextColor3 = Color3.new(1, 1, 1)
shortcut.Text = "✈  FLY"
shortcut.Font = Enum.Font.GothamBold
shortcut.TextSize = 11
shortcut.Visible = false
shortcut.Parent = screenGui
Instance.new("UICorner", shortcut).CornerRadius = UDim.new(0, 10)

-- Freecam-style Shift Lock button.
-- EXACT FreeCam_Standalone.lua dimensions/placement:
--   Size = 30x30
--   AnchorPoint = (0, 0.5)
--   Position = (0, 18, 0.5, 0)
--   ZIndex = 2001
flyShiftLockButton = Instance.new("ImageButton")
flyShiftLockButton.Name = "VGD_FlyShiftLock"
flyShiftLockButton.Size = UDim2.fromOffset(30,30)
flyShiftLockButton.AnchorPoint = Vector2.new(0,0.5)
flyShiftLockButton.Position = UDim2.new(0,18,0.5,0)
flyShiftLockButton.BackgroundTransparency = 1
flyShiftLockButton.BorderSizePixel = 0
flyShiftLockButton.AutoButtonColor = false
flyShiftLockButton.ScaleType = Enum.ScaleType.Fit
flyShiftLockButton.Visible = false
flyShiftLockButton.ZIndex = 2001
flyShiftLockButton.Parent = screenGui

updateFlyShiftLockButton = function()
    if not flyShiftLockButton then return end
    flyShiftLockButton.Visible = flyEnabled
    flyShiftLockButton.Image = flyShiftLockOn
        and "rbxasset://textures/ui/mouseLock_on@2x.png"
        or "rbxasset://textures/ui/mouseLock_off@2x.png"
end

flyShiftLockButton.Activated:Connect(function()
    if not flyEnabled then return end
    flyShiftLockOn = not flyShiftLockOn
    updateFlyShiftLockButton()
end)

local function refreshUI()
    status.Text = flyEnabled and ("ON  •  Speed " .. tostring(math.floor(flySpeed + 0.5))) or "OFF"
    toggle.Text = flyEnabled and "DISABLE" or "ENABLE"
    shortcut.Text = flyEnabled and "✈  ON" or "✈  FLY"
    noClipToggle.Text = "NO CLIP  •  " .. (flyNoClipOn and "ON" or "OFF")
    collisionDebugToggle.Text = "COLLISION SHAPE  •  " .. (flyCollisionDebugOn and "ON" or "OFF")
end

local function showMiniGui(show)
    screenGui.Enabled = show == true
    if screenGui.Enabled then
        panel.Visible = true
        shortcut.Visible = false
    end
end

closeButton.Activated:Connect(function()
    if screenGui.Enabled then
        panel.Visible = false
        shortcut.Visible = true
    end
end)

toggle.Activated:Connect(function()
    if flyEnabled then disableFly() else enableFly() end
end)

shortcut.Activated:Connect(function()
    panel.Visible = true
    shortcut.Visible = false
end)

noClipToggle.Activated:Connect(function()
    if not flyEnabled then return end
    flyNoClipOn = not flyNoClipOn
    setFlyNoClip(flyNoClipOn)
    refreshUI()
end)

collisionDebugToggle.Activated:Connect(function()
    if not flyEnabled then return end
    flyCollisionDebugOn = not flyCollisionDebugOn
    updateFlyCollisionDebug()
    refreshUI()
end)

speedBox.FocusLost:Connect(function()
    local value = tonumber(speedBox.Text)
    if value then flySpeed = math.clamp(value, flyMinSpeed, flyMaxSpeed) end
    speedBox.Text = tostring(math.floor(flySpeed + 0.5))
    refreshUI()
end)

stateChangedEvent.Event:Connect(function(enabled)
    -- Changing Fly state must never change GUI visibility.
    -- ENABLE/DISABLE only controls the Fly feature itself.
    -- The X button is the only thing that closes the panel.
    refreshUI()
end)

refreshUI()

local Controller = {}
function Controller.EnableUI()
    -- VGD Self-page Toggle ON: expose the Fly feature without starting flight.
    screenGui.Enabled = true
    panel.Visible = false
    shortcut.Visible = true
    refreshUI()
    return true
end
function Controller.DisableUI()
    -- VGD Self-page Toggle OFF: stop flight if necessary and remove the whole
    -- Fly UI (shortcut + mini GUI).
    disableFly()
    refreshUI()
    panel.Visible = false
    shortcut.Visible = false
    screenGui.Enabled = false
    return true
end
-- Keep Enable/Disable for the standalone mini GUI/API: these control actual flight.
function Controller.Enable()
    local ok = enableFly() == true
    showMiniGui(true)
    return ok
end
function Controller.Disable()
    local result = disableFly()
    refreshUI()
    return result == false
end
function Controller.IsEnabled() return flyEnabled == true end
function Controller.SetSpeed(value)
    local n = tonumber(value)
    if not n then return flySpeed end
    flySpeed = math.clamp(n, flyMinSpeed, flyMaxSpeed)
    speedBox.Text = tostring(math.floor(flySpeed + 0.5))
    refreshUI()
    return flySpeed
end
function Controller.GetSpeed() return flySpeed end
function Controller.ShowUI() showMiniGui(true) end
function Controller.HideUI()
    if screenGui.Enabled then
        panel.Visible = false
        shortcut.Visible = true
    end
end
Controller.Changed = stateChangedEvent.Event
return Controller
