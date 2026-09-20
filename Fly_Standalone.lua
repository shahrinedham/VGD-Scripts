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

local player = Players.LocalPlayer
local flyEnabled = false
local flySpeed = 55
local flyMinSpeed = 1
local flyMaxSpeed = 500
local flyVerticalInput = 0
local flyRenderConnection = nil
local flySaved = nil
local flyPosition = nil
local flyTracks = {}
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

local function updateFlyAnimations(isMoving, moveDirection, deltaTime)
    local idle = flyTracks.idle
    local move = flyTracks.move
    local backward = flyTracks.backward
    if not idle then return end

    local cam = workspace.CurrentCamera
    local flatLook = cam and Vector3.new(cam.CFrame.LookVector.X, 0, cam.CFrame.LookVector.Z) or Vector3.new(0, 0, -1)
    if flatLook.Magnitude < 0.001 then flatLook = Vector3.new(0, 0, -1) else flatLook = flatLook.Unit end

    local desiredState = "Idle"
    if isMoving and moveDirection.Magnitude > 0.001 then
        local forwardDot = moveDirection.Unit:Dot(flatLook)
        desiredState = forwardDot < -0.15 and "Backward" or "Forward"
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

    local moveDirection = humanoid.MoveDirection
    local horizontalMove = Vector3.new(moveDirection.X, 0, moveDirection.Z)
    local cameraLook = cam.CFrame.LookVector
    local cameraRight = cam.CFrame.RightVector

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
    local desiredFlightYaw = flyBodyYaw or 0
    -- Freecam v150 has Shift Lock ON by default, so the hologram's desired
    -- heading is the Freecam camera yaw. For the real body, the camera's flat
    -- look is the equivalent heading.
    if isMoving then
        desiredFlightYaw = math.atan2(-horizontalLook.X, -horizontalLook.Z)
    end

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
    updateFlyAnimations(isMoving, moveVector, dt)

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

    -- The ONLY output difference from the hologram version:
    -- PivotTo(animatedCFrame) -> real HumanoidRootPart.CFrame.
    root.CFrame = animatedCFrame
    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero
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
    root.Anchored = true
    currentMoveVector = Vector3.zero
    flyPosition = root.Position
    loadFlyAnimations(humanoid)
    bindVerticalControls()

    if flyRenderConnection then flyRenderConnection:Disconnect() end
    flyRenderConnection = RunService.RenderStepped:Connect(updateFly)
    stateChangedEvent:Fire(true)
    return true
end

local function disableFly()
    if not flyEnabled then return false end
    flyEnabled = false
    unbindVerticalControls()
    if flyRenderConnection then flyRenderConnection:Disconnect(); flyRenderConnection = nil end
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
                        root.Anchored = true
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

local screenGui = Instance.new("ScreenGui")
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
