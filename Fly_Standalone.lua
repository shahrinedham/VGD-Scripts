-- VGD Fly Standalone v60
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
local flyCameraFeelOn = false
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

-- v57 camera/flight-feel state. These are visual-only layers; they do not
-- replace the proven v56 movement/camera ownership architecture.
local flyCameraVelocityBlend = Vector3.zero
local flyCameraTurnLag = 0
local flyCameraFOVBlend = 0
local flyCameraLastYaw = nil
local flyCameraLastMoveVector = Vector3.zero

local flyAccelerationBlend = 0
local flyDecelerationBlend = 0
local flyDirectionChangeBlend = 0
local flyPreviousMoveDirection = Vector3.zero
local flyPreviousSpeed = 0

-- Read the same PlayerModule movement vector that Roblox mobile/keyboard
-- controls use. This keeps the joystick alive when Fly switches Humanoid
-- into PlatformStand, instead of relying only on Humanoid.MoveDirection.
local flyMoveControls = nil

-- Mobile joystick continuity. Roblox's PlatformStand state prevents the
-- Humanoid from moving, and community testing/source inspection shows the
-- default movement controller can therefore return zero even while the
-- physical thumbstick is still held. We keep a small independent copy of the
-- thumbstick state so Fly can consume the same input without asking the
-- Humanoid to walk.
local flyJoystickTouch = nil
local flyJoystickStartPosition = nil
local flyJoystickVector = Vector3.zero
local flyJoystickReleasedSinceLastStart = false
local flyJoystickConnections = {}

local function getDynamicThumbstickFrame()
    local playerGui = player:FindFirstChildOfClass("PlayerGui")
    local touchGui = playerGui and playerGui:FindFirstChild("TouchGui")
    if not touchGui then return nil end

    local touchControlFrame = touchGui:FindFirstChild("TouchControlFrame")
    return touchControlFrame and touchControlFrame:FindFirstChild("DynamicThumbstickFrame")
end

local function pointInsideGui(guiObject, position)
    if not guiObject or not guiObject.Visible then return false end
    local p = guiObject.AbsolutePosition
    local s = guiObject.AbsoluteSize
    return position.X >= p.X
        and position.X <= p.X + s.X
        and position.Y >= p.Y
        and position.Y <= p.Y + s.Y
end

local function getThumbstickCenter()
    local frame = getDynamicThumbstickFrame()
    if not frame then return nil end

    -- Roblox's DynamicThumbstick source moves ThumbstickStart to the exact
    -- touch-start position and ThumbstickEnd to the current touch position.
    -- Reading those UI positions lets us identify the existing held finger
    -- even when Fly is enabled after the finger was already placed.
    local startImage = frame:FindFirstChild("ThumbstickStart")
    if startImage then
        return startImage.AbsolutePosition + startImage.AbsoluteSize * 0.5
    end

    return nil
end

local function computeJoystickVector(startPosition, currentPosition)
    if not startPosition or not currentPosition then
        return Vector3.zero
    end

    local delta = currentPosition - startPosition
    local frame = getDynamicThumbstickFrame()
    local maxLength = 50

    if frame then
        -- Match the DynamicThumbstick's screen-size scaling as closely as
        -- possible. Its historical source uses a 50px max-radius on normal
        -- screens and doubles it on large screens.
        maxLength = math.min(frame.AbsoluteSize.X, frame.AbsoluteSize.Y)
        if maxLength <= 0 then maxLength = 50 end
        maxLength = math.min(50, maxLength)
        if math.min(frame.AbsoluteSize.X, frame.AbsoluteSize.Y) > 500 then
            maxLength = 100
        end
    end

    local magnitude = delta.Magnitude
    if magnitude < 2 then
        return Vector3.zero
    end

    local clamped = math.min(magnitude, maxLength)
    local unit = delta.Unit
    local scaled = clamped / maxLength

    -- Touch Y increases downward; Roblox movement Z increases backward.
    -- Therefore screen-right = +X and screen-up = -Z.
    return Vector3.new(
        unit.X * scaled,
        0,
        unit.Y * scaled
    )
end

local function clearFlyJoystick()
    flyJoystickTouch = nil
    flyJoystickStartPosition = nil
    flyJoystickVector = Vector3.zero
end

local function disconnectFlyJoystickTracking()
    for _, connection in pairs(flyJoystickConnections) do
        pcall(function() connection:Disconnect() end)
    end
    table.clear(flyJoystickConnections)
    clearFlyJoystick()
end

local function connectFlyJoystickTracking()
    disconnectFlyJoystickTracking()

    if not UserInputService.TouchEnabled then
        return
    end

    flyJoystickConnections.TouchStarted = UserInputService.TouchStarted:Connect(function(inputObject)
        local frame = getDynamicThumbstickFrame()
        if not frame or not pointInsideGui(frame, inputObject.Position) then
            return
        end

        -- Do not steal the camera's touch if Roblox has already assigned a
        -- different thumbstick touch. The dynamic thumbstick's StartImage is
        -- the stronger signal for an already-active joystick.
        if flyJoystickTouch then
            return
        end

        flyJoystickReleasedSinceLastStart = false
        flyJoystickTouch = inputObject
        flyJoystickStartPosition = Vector2.new(
            inputObject.Position.X,
            inputObject.Position.Y
        )
        flyJoystickVector = computeJoystickVector(
            flyJoystickStartPosition,
            flyJoystickStartPosition
        )
    end)

    flyJoystickConnections.TouchMoved = UserInputService.TouchMoved:Connect(function(inputObject)
        local position = Vector2.new(inputObject.Position.X, inputObject.Position.Y)

        if flyJoystickTouch == inputObject then
            flyJoystickVector = computeJoystickVector(
                flyJoystickStartPosition,
                position
            )
            return
        end

        if flyJoystickTouch then
            return
        end

        -- Fly may have been enabled while the joystick finger was already
        -- down. In that case TouchStarted happened before our connection.
        -- Match the current touch against Roblox's live ThumbstickEnd visual
        -- and recover the original center from ThumbstickStart.
        local frame = getDynamicThumbstickFrame()
        local startCenter = getThumbstickCenter()
        local endImage = frame and frame:FindFirstChild("ThumbstickEnd")
        if frame and startCenter and endImage and endImage.Visible
            and pointInsideGui(frame, position) then
            local endCenter = endImage.AbsolutePosition + endImage.AbsoluteSize * 0.5
            if (position - endCenter).Magnitude <= 35 then
                flyJoystickTouch = inputObject
                flyJoystickStartPosition = startCenter
                flyJoystickVector = computeJoystickVector(
                    flyJoystickStartPosition,
                    position
                )
            end
        end
    end)

    flyJoystickConnections.TouchEnded = UserInputService.TouchEnded:Connect(function(inputObject)
        local frame = getDynamicThumbstickFrame()
        local endedInsideThumbstick = frame and pointInsideGui(frame, inputObject.Position)

        if flyJoystickTouch == inputObject then
            flyJoystickReleasedSinceLastStart = true
            clearFlyJoystick()
            return
        end

        -- If Fly was enabled while the joystick finger was already held, we
        -- may never have obtained the InputObject identity. Use Roblox's
        -- ThumbstickEnd visual as the release-side fallback so the latched
        -- movement is cleared instead of continuing forever.
        if flyJoystickVector.Magnitude > 0.001 then
            local endImage = frame and frame:FindFirstChild("ThumbstickEnd")
            local position = Vector2.new(inputObject.Position.X, inputObject.Position.Y)
            if frame and endImage and endImage.Visible
                and pointInsideGui(frame, position) then
                local endCenter = endImage.AbsolutePosition + endImage.AbsoluteSize * 0.5
                if (position - endCenter).Magnitude <= 40 then
                    flyJoystickReleasedSinceLastStart = true
                    clearFlyJoystick()
                end
            end
        elseif endedInsideThumbstick then
            -- The joystick may have been released before our tracker could
            -- identify the original InputObject. Remember that release so the
            -- disable path cannot mistake stale ThumbstickStart/End visuals
            -- for a currently held joystick.
            flyJoystickReleasedSinceLastStart = true
        end
    end)
end

-- Keep the DynamicThumbstick tracker alive even when Fly is OFF.
-- This is important for the transition where the player starts holding the
-- joystick BEFORE pressing Fly ENABLE. If we only connect after Fly starts,
-- TouchStarted for that finger has already happened and we lose the exact
-- InputObject needed for the handoff back to the normal Humanoid controller.
connectFlyJoystickTracking()

local function getFlyMoveControls()
    local controls = nil
    pcall(function()
        local playerScripts = player:FindFirstChildOfClass("PlayerScripts")
        local playerModule = playerScripts and playerScripts:FindFirstChild("PlayerModule")
        if not playerModule then return end
        local module = require(playerModule)
        if module and module.GetControls then
            controls = module:GetControls()
        end
    end)
    return controls
end

local function getFlyMoveVector(humanoid)
    if not flyMoveControls then
        flyMoveControls = getFlyMoveControls()
    end

    if flyMoveControls then
        -- PlayerModule:GetMoveVector() is INPUT SPACE, not world space:
        -- forward is -Z and right is +X. Keep that raw vector intact so the
        -- render loop can convert it to the current Fly camera basis exactly
        -- once. The previous v36 code fed this raw vector into the old
        -- Humanoid.MoveDirection world-space dot-product conversion, which
        -- inverted left/right and forward/backward.
        pcall(function() flyMoveControls:Enable() end)
        local ok, value = pcall(function()
            return flyMoveControls:GetMoveVector()
        end)
        if ok and typeof(value) == "Vector3" then
            if value.Magnitude > 0.001 then
                flyJoystickVector = value
                return value, true
            end

            -- ControlModule can report zero after PlatformStand. If the
            -- independent thumbstick tracker still sees the finger held, use
            -- that input instead of allowing the Fly to stop.
            if flyJoystickVector.Magnitude > 0.001 then
                return flyJoystickVector, true
            end

            return Vector3.zero, true
        end
    end

    -- Fallback: Humanoid.MoveDirection IS already world-space.
    if humanoid then
        return humanoid.MoveDirection, false
    end

    return Vector3.zero, false
end

local FLY_CAMERA_TOUCH_ROTATION_SPEED = Vector2.new(0.82, 0.54) * math.rad(1)
local FLY_CAMERA_MOUSE_ROTATION_SPEED = Vector2.new(1, 0.77) * math.rad(0.5)
local FLY_CAMERA_LOOK_SMOOTHNESS = 34

-- v57 subtle cinematic camera response. Kept deliberately restrained so
-- camera control remains as responsive as v56.
local FLY_CAMERA_MOMENTUM_SMOOTHNESS = 8
local FLY_CAMERA_MAX_LAG = 0.22
local FLY_CAMERA_FOV_BASE = 70
local FLY_CAMERA_FOV_MAX_BOOST = 7

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
local flightTurnRateBlend = 0
local speedBlend = 0
local previousDesiredYaw = nil
local currentMoveVector = Vector3.zero
local hoverBlend = 0
local flyAnimState = "Idle"

-- v56: explicit per-track blend weights owned by Fly.
local flyIdleWeight = 1
local flyMoveWeight = 0
local flyBackwardWeight = 0

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

    -- v54: Fly takes explicit ownership of the Animator while active.
    -- The Animate script may be disabled while its already-playing tracks
    -- remain alive, so stop those pre-existing tracks before loading the
    -- custom Fly tracks. This is intentionally limited to Fly enable time.
    for _, existingTrack in ipairs(animator:GetPlayingAnimationTracks()) do
        pcall(function()
            existingTrack:Stop(0)
        end)
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

    -- v54: all custom Fly tracks use Action priority so they can
    -- reliably override any existing avatar animation tracks while
    -- the Animate controller is disabled.
    flyTracks.idle = load(IDLE_ANIMATION_ID, Enum.AnimationPriority.Action)
    flyTracks.move = load(MOVE_ANIMATION_ID, Enum.AnimationPriority.Action)
    flyTracks.backward = load(BACKWARD_ANIMATION_ID, Enum.AnimationPriority.Action)

    -- v52: keep every custom Fly track actively playing while using
    -- explicit weights for state blending. Use the normal Play() weight
    -- parameter so the custom tracks are actually registered as active;
    -- then immediately set their intended blend weights.
    if flyTracks.idle then
        flyTracks.idle:Play(0.12, 1, 1)
        flyTracks.idle:AdjustWeight(1, 0)
    end
    if flyTracks.move then
        flyTracks.move:Play(0.12, 1, 1)
        flyTracks.move:AdjustWeight(0, 0)
    end
    flyIdleWeight = 1
    flyMoveWeight = 0
    flyBackwardWeight = 0

    if flyTracks.backward then
        flyTracks.backward:Play(0.12, 1, 1)
        flyTracks.backward:AdjustWeight(0, 0)
    end
end

local function updateFlyAnimations(isMoving, moveDirection, deltaTime, forwardInput)
    local idle = flyTracks.idle
    local move = flyTracks.move
    local backward = flyTracks.backward
    if not idle then return end

    local desiredState = "Idle"
    if isMoving and moveDirection.Magnitude > 0.001 then
        desiredState = (forwardInput or 0) < -0.15 and "Backward" or "Forward"
    end

    flyAnimState = desiredState

    -- v56: manually blend the three continuously-playing tracks. This avoids
    -- Stop()/Play() snaps and avoids leaving Roblox's internal weight target
    -- stuck after a state transition.
    local idleTarget = desiredState == "Idle" and 1 or 0
    local moveTarget = desiredState == "Forward" and 1 or 0
    local backwardTarget = desiredState == "Backward" and 1 or 0

    local blendAlpha = 1 - math.exp(-deltaTime / 0.18)

    flyIdleWeight = flyIdleWeight
        + (idleTarget - flyIdleWeight) * blendAlpha
    flyMoveWeight = flyMoveWeight
        + (moveTarget - flyMoveWeight) * blendAlpha
    flyBackwardWeight = flyBackwardWeight
        + (backwardTarget - flyBackwardWeight) * blendAlpha

    if idle and not idle.IsPlaying then
        idle:Play(0, 1, 1)
    end
    if move and not move.IsPlaying then
        move:Play(0, 1, 1)
    end
    if backward and not backward.IsPlaying then
        backward:Play(0, 1, 1)
    end

    if idle then idle:AdjustWeight(flyIdleWeight, 0) end
    if move then move:AdjustWeight(flyMoveWeight, 0) end
    if backward then backward:AdjustWeight(flyBackwardWeight, 0) end

    local speedTarget = isMoving
        and math.clamp(moveDirection.Magnitude, 0, 1)
        or 0

    speedBlend += (speedTarget - speedBlend)
        * (1 - math.exp(-deltaTime / 0.16))

    if move and move.IsPlaying then
        move:AdjustSpeed(
            math.clamp(0.75 + speedBlend * 0.75, 0.75, 1.5)
        )
    end
    if backward and backward.IsPlaying then
        backward:AdjustSpeed(
            math.clamp(0.80 + speedBlend * 0.60, 0.80, 1.4)
        )
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

    -- v57 performance: setFlyNoClip() already caches every character
    -- BasePart in flySavedCanCollide and DescendantAdded keeps that cache
    -- current. Iterate the cache instead of scanning the entire character
    -- hierarchy every render frame.
    for instance, _ in pairs(flySavedCanCollide) do
        if instance and instance.Parent
            and not instance:IsDescendantOf(flyCollisionProxy)
            and instance.CanCollide then
            instance.CanCollide = false
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
    -- Get the actual current joystick/controller vector directly.
    -- PlatformStand can make Humanoid.MoveDirection drop to zero for the
    -- transition frame when Fly is enabled while the player is already walking.
    -- PlayerModule:GetMoveVector() preserves the held joystick state.
    local moveDirection, isRawControlVector = getFlyMoveVector(humanoid)

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

    local forwardInput
    local rightInput

    if isRawControlVector then
        -- PlayerModule input: X = right, Z = backward.
        -- Convert it into camera-relative world movement once.
        forwardInput = math.clamp(-moveDirection.Z, -1, 1)
        rightInput = math.clamp(moveDirection.X, -1, 1)
    else
        -- Humanoid.MoveDirection fallback: already world-space.
        local horizontalMove = Vector3.new(moveDirection.X, 0, moveDirection.Z)
        forwardInput = math.clamp(horizontalMove:Dot(horizontalLook), -1, 1)
        rightInput = math.clamp(horizontalMove:Dot(horizontalRight), -1, 1)
    end

    local moveVector =
        (cameraLook * forwardInput) +
        (horizontalRight * rightInput)

    if moveVector.Magnitude > 1 then
        moveVector = moveVector.Unit
    end

    -- Keep a world-space horizontal movement vector available for the
    -- Shift Lock OFF body-heading logic below. In the raw PlayerModule
    -- input path, the old code only created `horizontalMove` inside the
    -- fallback branch, so disabling Shift Lock left it nil and caused the
    -- render loop to error before updating the camera/body.
    local horizontalMove = Vector3.new(moveVector.X, 0, moveVector.Z)

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
    -- v57 FLIGHT DYNAMICS / MOMENTUM VISUALS
    -- ================================================================
    -- These values are visual response layers. The actual movement vector and
    -- position integration remain exactly v56.
    local currentSpeed = moveVector.Magnitude
    local speedDelta = currentSpeed - flyPreviousSpeed
    local speedDeltaAlpha = 1 - math.exp(-dt / 0.09)

    local accelerationTarget = math.clamp(math.max(speedDelta, 0) * 5, 0, 1)
    local decelerationTarget = math.clamp(math.max(-speedDelta, 0) * 5, 0, 1)

    flyAccelerationBlend = flyAccelerationBlend
        + (accelerationTarget - flyAccelerationBlend) * speedDeltaAlpha
    flyDecelerationBlend = flyDecelerationBlend
        + (decelerationTarget - flyDecelerationBlend) * speedDeltaAlpha

    local directionChangeTarget = 0
    if isMoving and flyPreviousMoveDirection.Magnitude > 0.05 then
        local previousUnit = flyPreviousMoveDirection.Unit
        local currentUnit = moveVector.Unit
        local directionDot = math.clamp(previousUnit:Dot(currentUnit), -1, 1)
        directionChangeTarget = math.clamp((1 - directionDot) * 0.85, 0, 1)
    end

    local directionChangeAlpha = 1 - math.exp(-dt / 0.075)
    flyDirectionChangeBlend = flyDirectionChangeBlend
        + (directionChangeTarget - flyDirectionChangeBlend) * directionChangeAlpha

    -- Keep the previous movement vector alive until the procedural pose has
    -- consumed it below. This is what makes v57's direction-change reaction
    -- compare the actual previous frame against the current frame.
    flyPreviousSpeed = currentSpeed

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

    -- Turn bank: filter the actual heading change before converting it into
    -- roll. This keeps the real body from snapping into a bank when the camera
    -- turns quickly, while still letting the bank build naturally during a
    -- sustained turn and recover smoothly when the turn stops.
    local rawTurnRate = desiredYawDelta / math.max(dt, 1 / 240)
    local turnRateDuration = isMoving and 0.075 or 0.16
    local turnRateAlpha = 1 - math.exp(-dt / turnRateDuration)
    flightTurnRateBlend = flightTurnRateBlend
        + (rawTurnRate - flightTurnRateBlend) * turnRateAlpha

    local targetBank = 0
    if isMoving and math.abs(flightTurnRateBlend) > 0.001 then
        targetBank = math.clamp(
            -flightTurnRateBlend * 0.10,
            math.rad(-20),
            math.rad(20)
        )
    end

    -- Enter a turn quickly, but let the body recover a little more lazily.
    -- That small asymmetry makes the real character feel like it has weight
    -- instead of mechanically matching the camera every frame.
    local bankDuration
    if math.abs(targetBank) > math.abs(flightBankBlend) then
        bankDuration = isMoving and 0.085 or 0.20
    else
        bankDuration = isMoving and 0.15 or 0.30
    end
    local bankAlpha = 1 - math.exp(-dt / bankDuration)
    flightBankBlend = flightBankBlend
        + (targetBank - flightBankBlend) * bankAlpha

    -- ================================================================
    -- EXACT HOLOGRAM POSE BLEND
    -- ================================================================
    flyAnimTime = flyAnimTime + dt

    local targetMove = isMoving and 1 or 0

    -- v57: slightly more deliberate visual settle on stopping. The manual
    -- animation blender remains responsible for animation; this value only
    -- controls the procedural flight pose/hover envelope.
    local transitionDuration
    if targetMove > flyHologramMoveBlend then
        transitionDuration = 0.18
    else
        transitionDuration = 0.34
    end
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

    -- v57 acceleration/deceleration body response. This supplements the
    -- existing v56 directional lean rather than replacing it.
    local accelerationPitch = math.rad(7)
        * flyAccelerationBlend * b
    local brakingPitch = math.rad(5)
        * flyDecelerationBlend * b

    local flyLeanPitch = math.rad(16) * movementForward * b
        + accelerationPitch
        - brakingPitch
    local flyLeanRoll = math.rad(14) * movementRight * b

    -- Direction-change reaction: briefly counter-roll into a sharp change,
    -- then let the existing turn-bank system take over.
    local directionSign = 0
    if moveVector.Magnitude > 0.001 and flyPreviousMoveDirection.Magnitude > 0.05 then
        local crossY = flyPreviousMoveDirection.Unit:Cross(moveVector.Unit).Y
        directionSign = math.clamp(crossY, -1, 1)
    end
    local directionChangeRoll = math.rad(4)
        * directionSign
        * flyDirectionChangeBlend
        * b

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

    -- v57 vertical-flight inertia: quick enough to follow the joystick, but
    -- with a slightly heavier settle so upward/downward changes do not snap.
    local verticalAcceleration = math.clamp(math.abs(moveVector.Y), 0, 1)
    local flightPitchDuration
    if isMoving and verticalAcceleration > 0.25 then
        flightPitchDuration = 0.13
    else
        flightPitchDuration = isMoving and 0.10 or 0.24
    end

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
            -flyLeanRoll - flightBankBlend
                + directionChangeRoll
                + hoverRoll
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

    -- Commit the movement direction after all visual direction-change
    -- calculations have consumed the previous frame's value.
    flyPreviousMoveDirection = moveVector

    -- ================================================================
    -- v58 OPTIONAL CAMERA FLIGHT FEEL
    -- ================================================================
    -- The camera-feel layer is fully optional because the translation lag,
    -- turn follow-through and speed FOV can be uncomfortable for players
    -- who are sensitive to motion. Turning it OFF restores the direct v56/v57
    -- camera position, rotation and saved FOV without changing flight movement.
    local cameraPosition = nil
    local cameraRotation = nil

    if flyCameraFeelOn then
        local horizontalVelocity = Vector3.new(moveVector.X, 0, moveVector.Z)
        local cameraLagTarget = Vector3.zero

        if horizontalVelocity.Magnitude > 0.001 then
            local speedRatio = math.clamp(currentSpeed, 0, 1)
            local travelDirection = horizontalVelocity.Unit
            cameraLagTarget = -travelDirection
                * (FLY_CAMERA_MAX_LAG * speedRatio)

            -- Acceleration/deceleration briefly changes how much the camera lags,
            -- creating a restrained sense of mass without making aiming sluggish.
            cameraLagTarget *= 1
                + flyAccelerationBlend * 0.18
                + flyDecelerationBlend * 0.08
        end

        local cameraLagAlpha = 1 - math.exp(-FLY_CAMERA_MOMENTUM_SMOOTHNESS * dt)
        flyCameraVelocityBlend = flyCameraVelocityBlend
            + (cameraLagTarget - flyCameraVelocityBlend) * cameraLagAlpha

        -- Camera turn inertia: tiny rotational follow-through, while the actual
        -- camera yaw remains fully responsive.
        local cameraYawDelta = flyCameraLastYaw
            and shortestAngleDelta(flyCameraLastYaw, flyCameraYaw)
            or 0
        flyCameraLastYaw = flyCameraYaw

        local turnLagTarget = math.clamp(
            -cameraYawDelta / math.max(dt, 1 / 240) * 0.006,
            math.rad(-1.8),
            math.rad(1.8)
        )
        flyCameraTurnLag = flyCameraTurnLag
            + (turnLagTarget - flyCameraTurnLag)
            * (1 - math.exp(-dt / 0.09))

        local baseCameraCFrame = getFlyCameraCFrame(flyPosition)
        cameraPosition = baseCameraCFrame.Position
            + flyCameraVelocityBlend

        local cameraLookVector = baseCameraCFrame.LookVector
        local cameraUpVector = baseCameraCFrame.UpVector

        cameraRotation =
            CFrame.lookAt(
                Vector3.zero,
                cameraLookVector,
                cameraUpVector
            ).Rotation
            * CFrame.Angles(0, 0, flyCameraTurnLag)

        -- Speed FOV is intentionally subtle. The baseline FOV is restored when
        -- stopped, while faster flight opens the view smoothly.
        local speedFOVTarget = math.clamp(currentSpeed, 0, 1)
            * FLY_CAMERA_FOV_MAX_BOOST
        flyCameraFOVBlend = flyCameraFOVBlend
            + (speedFOVTarget - flyCameraFOVBlend)
            * (1 - math.exp(-dt / 0.20))
    else
        -- Hard-disable all optional camera-feel offsets. This makes the toggle
        -- immediately useful for motion-sensitive players instead of waiting
        -- for the old inertia layers to decay.
        flyCameraVelocityBlend = Vector3.zero
        flyCameraTurnLag = 0
        flyCameraFOVBlend = 0
        flyCameraLastYaw = flyCameraYaw

        local baseCameraCFrame = getFlyCameraCFrame(flyPosition)
        cameraPosition = baseCameraCFrame.Position
        cameraRotation = baseCameraCFrame.Rotation
    end

    cam.CFrame = CFrame.new(cameraPosition) * cameraRotation
    cam.FieldOfView = (flyCameraSavedFOV or FLY_CAMERA_FOV_BASE)
        + (flyCameraFeelOn and flyCameraFOVBlend or 0)
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

    -- Resolve and enable Roblox's movement controller BEFORE PlatformStand is
    -- applied. This preserves the currently-held mobile joystick instead of
    -- allowing the transition into Fly to make the ControlModule go idle.
    flyMoveControls = getFlyMoveControls()
    if flyMoveControls then
        pcall(function() flyMoveControls:Enable() end)
    end

    -- Start tracking BEFORE PlatformStand. This is important because the
    -- joystick may already be held when Fly is enabled, so TouchStarted for
    -- that finger may have happened earlier. We also sample the current raw
    -- controller vector below so the transition does not lose momentum.
    -- The joystick tracker is persistent. Do NOT reconnect it here because
    -- reconnecting would lose a touch that began before Fly was enabled.
    local preStandMove = Vector3.zero
    if flyMoveControls then
        pcall(function()
            local value = flyMoveControls:GetMoveVector()
            if typeof(value) == "Vector3" then
                preStandMove = value
            end
        end)
    end
    if preStandMove.Magnitude > 0.001 then
        flyJoystickVector = preStandMove
    end

    flyEnabled = true
    flyShiftLockOn = true
    -- Preserve the user's last No Clip preference across Fly disable/enable.
    -- No Clip is ON by default only for the first Fly session; after the user
    -- turns it OFF, disabling and re-enabling Fly keeps it OFF.
    updateFlyShiftLockButton()
    setFlyNoClip(flyNoClipOn)
    flyVerticalInput = 0
    forwardBlend, rightBlend, flightPitchBlend, flightBankBlend, flightTurnRateBlend, speedBlend, hoverBlend = 0, 0, 0, 0, 0, 0, 0
    flyCameraVelocityBlend = Vector3.zero
    flyCameraTurnLag = 0
    flyCameraFOVBlend = 0
    flyCameraLastYaw = nil
    flyCameraLastMoveVector = Vector3.zero
    flyAccelerationBlend = 0
    flyDecelerationBlend = 0
    flyDirectionChangeBlend = 0
    flyPreviousMoveDirection = Vector3.zero
    flyPreviousSpeed = 0
    flyBodyYaw = math.atan2(root.CFrame.LookVector.X, -root.CFrame.LookVector.Z)
    flyFlightPreviousDesiredYaw = flyBodyYaw
    flyHologramMoveBlend = 0
    flyAnimTime = 0
    flyIdleWeight = 1
    flyMoveWeight = 0
    flyBackwardWeight = 0
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
    flyMoveControls = getFlyMoveControls()

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

    -- Capture the joystick state BEFORE disconnectFlyJoystickTracking() clears it.
    -- If the thumb is still held, we hand that movement back to the normal
    -- Humanoid controller after PlatformStand is restored. This fixes both
    -- transition cases: a touch held before Fly was enabled, and a new touch
    -- started while already flying. If no touch is held, no movement is handed
    -- back, so disabling Fly still stops movement normally.
    local handoffMoveVector = nil
    if not flyJoystickReleasedSinceLastStart
        and flyJoystickTouch
        and (flyJoystickTouch.UserInputState == Enum.UserInputState.Begin
            or flyJoystickTouch.UserInputState == Enum.UserInputState.Change)
        and flyJoystickVector.Magnitude > 0.001 then
        handoffMoveVector = flyJoystickVector
    elseif not flyJoystickReleasedSinceLastStart and UserInputService.TouchEnabled then
        -- Case 1 can reach here when the joystick finger was already down
        -- before Fly started, so our TouchStarted listener never received
        -- that InputObject. Roblox's DynamicThumbstick still exposes the
        -- live Start/End visuals while the finger is held. Recover the exact
        -- current joystick vector from those visuals before tearing Fly down.
        local frame = getDynamicThumbstickFrame()
        local startImage = frame and frame:FindFirstChild("ThumbstickStart")
        local endImage = frame and frame:FindFirstChild("ThumbstickEnd")
        if frame and startImage and endImage
            and startImage.Visible and endImage.Visible then
            local startCenter = startImage.AbsolutePosition + startImage.AbsoluteSize * 0.5
            local endCenter = endImage.AbsolutePosition + endImage.AbsoluteSize * 0.5
            local recovered = computeJoystickVector(startCenter, endCenter)
            if recovered.Magnitude > 0.001 then
                handoffMoveVector = recovered
            end
        end
    end

    flyEnabled = false
    updateFlyShiftLockButton()
    unbindVerticalControls()
    if flyRenderConnection then
        RunService:UnbindFromRenderStep("VGD_FlySmooth")
        flyRenderConnection = nil
    end
    disconnectFlyCameraInput()
    -- Keep the joystick tracker connected after Fly is disabled so a touch
    -- that started before Fly can remain available for the normal movement
    -- controller and for the next Fly transition.
    flyMoveControls = nil
    disconnectFlyNoClipWatcher()

    local camera = workspace.CurrentCamera
    local exitCameraCFrame = camera and camera.CFrame or nil
    if camera then
        camera.CameraType = flyCameraSavedType or Enum.CameraType.Custom
        camera.CameraSubject = flyCameraSavedSubject

        -- Keep the direction the player was actually looking at when Fly
        -- was disabled. The old v59 behavior restored flyCameraSavedCFrame,
        -- which was captured BEFORE Fly started and caused the camera to snap
        -- back to the pre-Fly direction.
        if exitCameraCFrame then
            camera.CFrame = exitCameraCFrame
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

    -- If the joystick was released WHILE Fly was enabled, there is no active
    -- handoff vector to bridge back to Roblox. However, the normal ControlModule
    -- can still have one render frame of its previous movement command queued
    -- from before PlatformStand was enabled. Explicitly reset the movement
    -- controller before returning full ownership, then issue a short zero-move
    -- window. This specifically fixes: move joystick -> enable Fly -> release
    -- joystick -> disable Fly, where the character could otherwise start walking
    -- again even though the thumb was already released.
    if not handoffMoveVector and UserInputService.TouchEnabled then
        local stoppedHumanoid = select(1, getHumanoidAndRoot())
        if stoppedHumanoid then
            local resetControls = getFlyMoveControls()
            if resetControls then
                pcall(function() resetControls:Disable() end)
                pcall(function() resetControls:Enable() end)
            end

            stoppedHumanoid:Move(Vector3.zero, false)

            local stopUntil = os.clock() + 0.12
            RunService:BindToRenderStep(
                "VGD_FlyJoystickDisableStop",
                Enum.RenderPriority.Character.Value + 2,
                function()
                    if os.clock() >= stopUntil then
                        RunService:UnbindFromRenderStep("VGD_FlyJoystickDisableStop")
                        return
                    end
                    if stoppedHumanoid.Parent then
                        stoppedHumanoid:Move(Vector3.zero, false)
                    else
                        RunService:UnbindFromRenderStep("VGD_FlyJoystickDisableStop")
                    end
                end
            )
        end
    end

    -- Handoff v44: do NOT use InputObject.UserInputState as the only release
    -- signal. Roblox owns the DynamicThumbstick InputObject and its state can
    -- be cleared by the CoreScript before our render handoff sees the same
    -- transition. UserInputService.TouchEnded is the explicit release event,
    -- so the handoff installs its own release watcher for the exact touch.
    if handoffMoveVector and handoffMoveVector.Magnitude > 0.001 then
        local humanoid = select(1, getHumanoidAndRoot())
        if humanoid then
            local handoffControls = getFlyMoveControls()
            if handoffControls then
                pcall(function() handoffControls:Enable() end)
            end

            local handoffTouch = flyJoystickTouch
            local handoffReleased = false
            local handoffReleaseConnection = nil
            local handoffNewTouchConnection = nil

            -- If the joystick touch was already held before Fly was enabled,
            -- flyJoystickTouch can be unavailable. In that case a TouchEnded
            -- occurring inside the DynamicThumbstick area is the release of
            -- the joystick that produced handoffMoveVector.
            handoffReleaseConnection = UserInputService.TouchEnded:Connect(function(inputObject)
                if handoffReleased then
                    return
                end

                if handoffTouch then
                    if inputObject == handoffTouch then
                        handoffReleased = true
                    end
                    return
                end

                local frame = getDynamicThumbstickFrame()
                if frame and pointInsideGui(frame, inputObject.Position) then
                    handoffReleased = true
                end
            end)

            -- If the player releases the old thumb and immediately starts a
            -- fresh joystick touch, do not let the release hard-stop below
            -- suppress the new walking input.
            handoffNewTouchConnection = UserInputService.TouchStarted:Connect(function(inputObject)
                if handoffReleased then
                    return
                end

                local frame = getDynamicThumbstickFrame()
                if frame and pointInsideGui(frame, inputObject.Position) then
                    -- A new joystick touch is a new movement session. The old
                    -- handoff must stop being responsible for movement.
                    handoffReleased = true
                end
            end)

            local function cleanupHandoffConnections()
                if handoffReleaseConnection then
                    pcall(function() handoffReleaseConnection:Disconnect() end)
                    handoffReleaseConnection = nil
                end
                if handoffNewTouchConnection then
                    pcall(function() handoffNewTouchConnection:Disconnect() end)
                    handoffNewTouchConnection = nil
                end
            end

            RunService:BindToRenderStep(
                "VGD_FlyJoystickHandoff",
                Enum.RenderPriority.Character.Value + 1,
                function()
                    if not humanoid.Parent then
                        cleanupHandoffConnections()
                        RunService:UnbindFromRenderStep("VGD_FlyJoystickHandoff")
                        return
                    end

                    -- TouchEnded is the authoritative release signal for this
                    -- handoff. Once it fires, stop feeding Humanoid:Move()
                    -- immediately; do not wait for ThumbstickEnd visibility or
                    -- InputObject.UserInputState to change.
                    if handoffReleased then
                        cleanupHandoffConnections()
                        clearFlyJoystick()
                        humanoid:Move(Vector3.zero, false)
                        RunService:UnbindFromRenderStep("VGD_FlyJoystickHandoff")

                        -- Humanoid:Move() is a per-frame command and Roblox's
                        -- ControlModule can update movement on its own render
                        -- pass. Give the zero command a tiny post-release
                        -- window so the previous handoff vector cannot remain
                        -- latched for another frame or two.
                        local stopUntil = os.clock() + 0.12
                        RunService:BindToRenderStep(
                            "VGD_FlyJoystickHardStop",
                            Enum.RenderPriority.Character.Value + 2,
                            function()
                                if os.clock() >= stopUntil then
                                    RunService:UnbindFromRenderStep("VGD_FlyJoystickHardStop")
                                    return
                                end
                                if humanoid.Parent then
                                    humanoid:Move(Vector3.zero, false)
                                else
                                    RunService:UnbindFromRenderStep("VGD_FlyJoystickHardStop")
                                end
                            end
                        )
                        return
                    end

                    -- Keep using the exact tracked vector while the original
                    -- touch remains held. For a pre-Fly touch, recover the
                    -- current vector from DynamicThumbstick's live visuals.
                    local vector = nil
                    if handoffTouch and flyJoystickTouch == handoffTouch
                        and flyJoystickVector.Magnitude > 0.001 then
                        vector = flyJoystickVector
                    else
                        local frame = getDynamicThumbstickFrame()
                        local startImage = frame and frame:FindFirstChild("ThumbstickStart")
                        local endImage = frame and frame:FindFirstChild("ThumbstickEnd")
                        if frame and startImage and endImage
                            and startImage.Visible and endImage.Visible then
                            local startCenter =
                                startImage.AbsolutePosition
                                + startImage.AbsoluteSize * 0.5
                            local endCenter =
                                endImage.AbsolutePosition
                                + endImage.AbsoluteSize * 0.5
                            vector = computeJoystickVector(startCenter, endCenter)
                        end
                    end

                    if not vector or vector.Magnitude <= 0.001 then
                        humanoid:Move(Vector3.zero, false)
                        return
                    end

                    local camera = workspace.CurrentCamera
                    local cameraCFrame = camera and camera.CFrame
                    if not cameraCFrame then
                        return
                    end

                    local look = cameraCFrame.LookVector
                    local right = cameraCFrame.RightVector
                    local horizontalLook = Vector3.new(look.X, 0, look.Z)
                    local horizontalRight = Vector3.new(right.X, 0, right.Z)

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

                    -- PlayerModule input space: X = right, Z = backward.
                    -- Humanoid:Move() with relativeToCamera=false expects a
                    -- world-space direction, so convert against the CURRENT
                    -- normal camera every frame just like Roblox movement.
                    local worldMove =
                        (horizontalLook * (-vector.Z))
                        + (horizontalRight * vector.X)
                    if worldMove.Magnitude > 1 then
                        worldMove = worldMove.Unit
                    end

                    humanoid:Move(worldMove, false)
                end
            )
        end
    end

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
                        flyMoveControls = getFlyMoveControls()
                        if flyMoveControls then
                            pcall(function() flyMoveControls:Enable() end)
                        end
                        -- The joystick tracker is persistent across Fly state
                        -- changes and character respawns. Do not reconnect it
                        -- here or an already-held touch would be lost.
                        if flyMoveControls then
                            pcall(function()
                                local value = flyMoveControls:GetMoveVector()
                                if typeof(value) == "Vector3" and value.Magnitude > 0.001 then
                                    flyJoystickVector = value
                                end
                            end)
                        end
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

                        -- A respawn replaces the old Humanoid/character.
                        -- Fly can keep running through the respawn, but the
                        -- camera state saved before the death must NEVER be
                        -- restored after the new character exists. Otherwise
                        -- disabling Fly later sends Roblox back to the exact
                        -- camera CFrame/subject from the death position.
                        -- Rebind the saved subject to the new Humanoid and
                        -- let Roblox rebuild the normal camera from it.
                        local camera = workspace.CurrentCamera
                        if camera then
                            flyCameraSavedSubject = humanoid
                            flyCameraSavedCFrame = nil
                        end
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
-- Compact the entire mini GUI without changing the shortcut.
-- Keep the same 12px right margin after scaling.
panel.Position = UDim2.new(1, -188, 0, 92)
panel.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
panel.BackgroundTransparency = 0.08
panel.BorderSizePixel = 0
panel.Parent = screenGui
Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 12)

local miniGuiScale = Instance.new("UIScale")
miniGuiScale.Scale = 0.80
miniGuiScale.Parent = panel

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

local versionLabel = Instance.new("TextLabel")
versionLabel.Size = UDim2.fromOffset(34, 18)
versionLabel.Position = UDim2.new(1, -67, 0, 10)
versionLabel.BackgroundTransparency = 1
versionLabel.Text = "V60"
versionLabel.TextColor3 = Color3.fromRGB(145, 145, 145)
versionLabel.Font = Enum.Font.Gotham
versionLabel.TextSize = 9
versionLabel.TextXAlignment = Enum.TextXAlignment.Right
versionLabel.Parent = panel

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
collisionDebugToggle.Size = UDim2.fromOffset(97, 30)
collisionDebugToggle.Position = UDim2.fromOffset(10, 126)
collisionDebugToggle.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
collisionDebugToggle.BorderSizePixel = 0
collisionDebugToggle.TextColor3 = Color3.new(1, 1, 1)
collisionDebugToggle.Font = Enum.Font.GothamBold
collisionDebugToggle.TextSize = 10
collisionDebugToggle.Parent = panel
Instance.new("UICorner", collisionDebugToggle).CornerRadius = UDim.new(0, 8)

local cameraFeelToggle = Instance.new("TextButton")
cameraFeelToggle.Size = UDim2.fromOffset(97, 30)
cameraFeelToggle.Position = UDim2.fromOffset(113, 126)
cameraFeelToggle.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
cameraFeelToggle.BorderSizePixel = 0
cameraFeelToggle.TextColor3 = Color3.new(1, 1, 1)
cameraFeelToggle.Font = Enum.Font.GothamBold
cameraFeelToggle.TextSize = 10
cameraFeelToggle.Parent = panel
Instance.new("UICorner", cameraFeelToggle).CornerRadius = UDim.new(0, 8)

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
    collisionDebugToggle.Text = "COLLISION  •  " .. (flyCollisionDebugOn and "ON" or "OFF")
    cameraFeelToggle.Text = "CAMERA FEEL  •  " .. (flyCameraFeelOn and "ON" or "OFF")
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

cameraFeelToggle.Activated:Connect(function()
    if not flyEnabled then return end
    flyCameraFeelOn = not flyCameraFeelOn
    if not flyCameraFeelOn then
        flyCameraVelocityBlend = Vector3.zero
        flyCameraTurnLag = 0
        flyCameraFOVBlend = 0
        flyCameraLastYaw = flyCameraYaw
    end
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
