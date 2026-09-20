-- VGD Fly Standalone v2
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
local flySpeed = 55
local flyMinSpeed = 1
local flyMaxSpeed = 500
local flyVerticalInput = 0
local flyRenderConnection = nil
local flySaved = nil
local flyPosition = nil
local flyAnimateScript = nil
local flyAnimateScriptDisabled = false
local flyTracks = {}
local screenGui

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
local flyCameraTouchDelta = Vector2.new()
local flyCameraMouseDelta = Vector2.new()
local flyCameraMouseLooking = false
local flyCameraConnections = {}

local FLY_CAMERA_TOUCH_ROTATION_SPEED = Vector2.new(0.82, 0.54) * math.rad(1)
local FLY_CAMERA_MOUSE_ROTATION_SPEED = Vector2.new(1, 0.77) * math.rad(0.5)
local FLY_CAMERA_LOOK_SMOOTHNESS = 34
local FLY_CAMERA_MIN_PITCH = math.rad(-89)
local FLY_CAMERA_MAX_PITCH = math.rad(89)
local FLY_CAMERA_ZOOM_MIN = 2
local FLY_CAMERA_ZOOM_MAX = 24

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
end

local function connectFlyCameraInput()
    disconnectFlyCameraInput()

    -- Match Freecam's proven mobile touch architecture:
    -- ContextActionService owns the world touch, while render-step code
    -- consumes the accumulated delta. The joystick and VGD GUI are excluded.
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
            return Enum.ContextActionResult.Sink
        end

        if flyCameraTouchStates[inputObject] then
            if inputState == Enum.UserInputState.Change then
                -- Match Freecam exactly: consume this touch delta immediately.
                -- Do not accumulate it for another input layer to process.
                local delta = inputObject.Delta
                if delta.Magnitude > 0 then
                    delta = flyCameraAdjustTouchPitchSensitivity(delta)

                    local rotation = Vector2.new(
                        delta.X * FLY_CAMERA_TOUCH_ROTATION_SPEED.X,
                        delta.Y * FLY_CAMERA_TOUCH_ROTATION_SPEED.Y
                    )

                    flyCameraTargetYaw =
                        flyCameraTargetYaw - rotation.X

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

    -- Cleanup only; TouchEnded never drives the camera.
    flyCameraConnections.TouchEnded =
        UserInputService.TouchEnded:Connect(function(input)
            flyCameraTouchStates[input] = nil
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
    -- EXACT HOLOGRAM POSITION MODEL
    -- ================================================================
    flyPosition = flyPosition + moveVector * flySpeed * dt

    -- ================================================================
    -- EXACT HOLOGRAM BASE CFRAME
    -- ================================================================
    local flatLook = horizontalLook
    local baseCFrame = CFrame.lookAt(
        flyPosition,
        flyPosition + flatLook,
        Vector3.new(0, 1, 0)
    )

    -- ================================================================
    -- EXACT HOLOGRAM HEADING / TURN BANK
    -- ================================================================
    -- Match Freecam's default Shift Lock ON behavior exactly: the hologram
    -- faces the camera yaw, whether moving or idle.
    local desiredFlightYaw = flyCameraYaw

    local yawDelta = shortestAngleDelta(flyBodyYaw or 0, desiredFlightYaw)
    local yawDuration = 0.06
    local yawAlpha = 1 - math.exp(-dt / yawDuration)
    flyBodyYaw = (flyBodyYaw or 0) + yawDelta * yawAlpha

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

    -- Same output as the hologram, except the real HumanoidRootPart is the
    -- subject. There is no camera-follow delta and no Roblox CameraModule
    -- feedback here: Fly owns both the camera and the body in this render pass.
    root.CFrame = animatedCFrame
    root.AssemblyLinearVelocity = Vector3.zero
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

local function enableFly()
    if flyEnabled then return true end
    local humanoid, root = getHumanoidAndRoot()
    if not humanoid or not root then return false end

    saveCharacterState(humanoid, root)
    flyEnabled = true
    flyVerticalInput = 0
    forwardBlend, rightBlend, flightPitchBlend, flightBankBlend, speedBlend, hoverBlend = 0, 0, 0, 0, 0, 0
    flyBodyYaw = math.atan2(root.CFrame.LookVector.X, -root.CFrame.LookVector.Z)
    flyFlightPreviousDesiredYaw = flyBodyYaw
    flyHologramMoveBlend = 0
    flyAnimTime = 0
    humanoid.PlatformStand = true
    humanoid.AutoRotate = false
    root.Anchored = false
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
    unbindVerticalControls()
    if flyRenderConnection then
        RunService:UnbindFromRenderStep("VGD_FlySmooth")
        flyRenderConnection = nil
    end
    disconnectFlyCameraInput()

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
panel.Size = UDim2.fromOffset(220, 128)
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

local hint = Instance.new("TextLabel")
hint.Size = UDim2.new(1, -20, 0, 28)
hint.Position = UDim2.fromOffset(10, 91)
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

local function refreshUI()
    status.Text = flyEnabled and ("ON  •  Speed " .. tostring(math.floor(flySpeed + 0.5))) or "OFF"
    toggle.Text = flyEnabled and "DISABLE" or "ENABLE"
    shortcut.Text = flyEnabled and "✈  ON" or "✈  FLY"
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

speedBox.FocusLost:Connect(function()
    local value = tonumber(speedBox.Text)
    if value then flySpeed = math.clamp(value, flyMinSpeed, flyMaxSpeed) end
    speedBox.Text = tostring(math.floor(flySpeed + 0.5))
    refreshUI()
end)

stateChangedEvent.Event:Connect(function(enabled)
    refreshUI()
    if enabled then
        showMiniGui(true)
    end
end)

refreshUI()

local Controller = {}
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
