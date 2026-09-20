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

    flyTracks.idle = load(IDLE_ANIMATION_ID, Enum.AnimationPriority.Action)
    flyTracks.move = load(MOVE_ANIMATION_ID, Enum.AnimationPriority.Action)
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
end

local function updateFly(deltaTime)
    if not flyEnabled then return end
    local humanoid, root = getHumanoidAndRoot()
    local cam = workspace.CurrentCamera
    if not humanoid or not root or not cam then return end

    -- Match Freecam's movement model instead of fighting Roblox physics.
    -- The real body is anchored while flying, then moved directly by CFrame.
    -- This removes the tiny physics corrections that made full-body flight
    -- feel heavier/jitterier than the hologram.
    local moveInput = humanoid.MoveDirection
    local horizontalMove = Vector3.new(moveInput.X, 0, moveInput.Z)

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

    -- This is intentionally the same directional construction used by the
    -- Freecam hologram. Looking up/down naturally adds a vertical component.
    local moveVector = (cameraLook * forwardInput) + (horizontalRight * rightInput)
    if moveVector.Magnitude > 1 then
        moveVector = moveVector.Unit
    end

    -- Preserve the Fly-specific Space/C vertical controls on top of camera
    -- pitch. They affect the travel vector rather than applying a physics force.
    local horizontalMoveMagnitude = Vector3.new(moveVector.X, 0, moveVector.Z).Magnitude
    local cameraVertical = forwardInput * cameraLook.Y
    local vertical = math.clamp(cameraVertical + flyVerticalInput, -1, 1)
    moveVector = Vector3.new(moveVector.X, vertical, moveVector.Z)
    if moveVector.Magnitude > 1 then
        moveVector = moveVector.Unit
    end

    local isMoving = moveVector.Magnitude > 0.001

    -- Very light directional smoothing keeps the real character from looking
    -- mechanically snapped while still preserving Freecam's responsive input.
    local moveAlpha = 1 - math.exp(-deltaTime / 0.055)
    currentMoveVector = currentMoveVector:Lerp(moveVector, moveAlpha)
    if not isMoving and currentMoveVector.Magnitude < 0.01 then
        currentMoveVector = Vector3.zero
    end

    local travel = currentMoveVector
    local travelMagnitude = travel.Magnitude
    local travelHorizontal = Vector3.new(travel.X, 0, travel.Z)
    local travelHorizontalMagnitude = travelHorizontal.Magnitude

    -- Move the anchored real body exactly like Freecam moves its hologram.
    if travelMagnitude > 0.001 then
        root.CFrame = root.CFrame + travel.Unit * flySpeed * deltaTime
    end
    root.AssemblyLinearVelocity = Vector3.zero
    root.AssemblyAngularVelocity = Vector3.zero

    local flatLook = horizontalLook

    -- Direction/heading smoothing copied from Freecam.
    local desiredYaw = math.atan2(flatLook.X, -flatLook.Z)
    if travelHorizontalMagnitude > 0.001 then
        desiredYaw = math.atan2(travelHorizontal.X, -travelHorizontal.Z)
    end

    local currentYaw = math.atan2(root.CFrame.LookVector.X, -root.CFrame.LookVector.Z)
    local yawDelta = math.atan2(math.sin(desiredYaw - currentYaw), math.cos(desiredYaw - currentYaw))
    local yawDuration = isMoving and 0.14 or 0.06
    local yawAlpha = 1 - math.exp(-deltaTime / yawDuration)
    local smoothedYaw = currentYaw + yawDelta * yawAlpha

    -- Turning bank uses the change in desired heading, exactly like Freecam.
    local previousYaw = previousDesiredYaw
    local desiredYawDelta = previousYaw and math.atan2(
        math.sin(desiredYaw - previousYaw),
        math.cos(desiredYaw - previousYaw)
    ) or 0
    previousDesiredYaw = desiredYaw

    local turnRate = desiredYawDelta / math.max(deltaTime, 1 / 240)
    local targetBank = isMoving and math.clamp(-turnRate * 0.11, math.rad(-18), math.rad(18)) or 0
    local bankDuration = isMoving and 0.10 or 0.24
    flightBankBlend += (targetBank - flightBankBlend) * (1 - math.exp(-deltaTime / bankDuration))

    -- Travel-direction pitch, matching the hologram's ±75° flight pitch.
    local targetPitch = 0
    if isMoving and travelMagnitude > 0.001 then
        targetPitch = math.atan2(travel.Y, math.max(travelHorizontalMagnitude, 0.01))
        targetPitch = math.clamp(targetPitch, math.rad(-75), math.rad(75))
    end
    flightPitchBlend += (targetPitch - flightPitchBlend)
        * (1 - math.exp(-deltaTime / (isMoving and 0.10 or 0.22)))

    -- Animation state is based on actual travel direction, not the raw input.
    updateFlyAnimations(isMoving, travel, deltaTime)

    -- Directional pose blending copied from Freecam. The old Fly version never
    -- updated forwardBlend/rightBlend, so the body could not lean with travel.
    local forwardTarget = 0
    local rightTarget = 0
    if isMoving and travelMagnitude > 0.001 then
        local moveUnit = travel.Unit
        forwardTarget = math.clamp(moveUnit:Dot(flatLook), -1, 1)
        local flatRight = flatLook:Cross(Vector3.new(0, 1, 0))
        if flatRight.Magnitude > 0.001 then
            rightTarget = math.clamp(moveUnit:Dot(flatRight.Unit), -1, 1)
        end
    end

    local directionDuration = isMoving and 0.08 or 0.48
    local directionAlpha = 1 - math.exp(-deltaTime / directionDuration)
    forwardBlend += (forwardTarget - forwardBlend) * directionAlpha
    rightBlend += (rightTarget - rightBlend) * directionAlpha

    local poseBlend = math.clamp(travelMagnitude, 0, 1)
    local flyLeanPitch = math.rad(16) * forwardBlend * poseBlend
    local flyLeanRoll = math.rad(14) * rightBlend * poseBlend

    local verticalTravelRatio = travelMagnitude > 0.001
        and math.clamp(math.abs(travel.Unit.Y), 0, 1)
        or 0
    local horizontalSpeedPose = 1 - verticalTravelRatio
    local speedTarget = isMoving and math.clamp(travelMagnitude, 0, 1) or 0
    speedBlend += (speedTarget - speedBlend)
        * (1 - math.exp(-deltaTime / (isMoving and 0.16 or 0.30)))
    local speedPosePitch = math.rad(10) * speedBlend * horizontalSpeedPose * poseBlend

    -- Hover motion and smooth idle transition match the Freecam hologram.
    local hoverTarget = isMoving and 0 or 1
    hoverBlend += (hoverTarget - hoverBlend)
        * (1 - math.exp(-deltaTime / (hoverTarget > 0.5 and 0.20 or 0.16)))
    local t = os.clock()
    local hoverBob = math.sin(t * 1.55) * 0.10 * hoverBlend
    local hoverRoll = math.sin(t * 1.10 + 0.7) * math.rad(1.2) * hoverBlend
    local hoverYaw = math.sin(t * 0.82 + 1.4) * math.rad(0.8) * hoverBlend

    -- Always build the pose from a clean positional/yaw frame. Never multiply
    -- the previous animated CFrame, which would accumulate rotation errors.
    local baseLook = travelHorizontalMagnitude > 0.001
        and travelHorizontal.Unit
        or flatLook
    local baseCFrame = CFrame.lookAt(root.Position, root.Position + baseLook, Vector3.yAxis)
    local yawOnly = CFrame.new(root.Position) * CFrame.Angles(0, smoothedYaw, 0)
    local animatedCFrame = yawOnly
        * CFrame.new(0, hoverBob, 0)
        * CFrame.Angles(
            flightPitchBlend - flyLeanPitch - speedPosePitch,
            hoverYaw,
            -flyLeanRoll - flightBankBlend + hoverRoll
        )

    -- Keep the clean base orientation's position while using the smoothed yaw.
    -- This is the same separation Freecam uses between movement and pose.
    animatedCFrame = CFrame.new(root.Position) * CFrame.Angles(0, smoothedYaw, 0)
        * CFrame.new(0, hoverBob, 0)
        * CFrame.Angles(
            flightPitchBlend - flyLeanPitch - speedPosePitch,
            hoverYaw,
            -flyLeanRoll - flightBankBlend + hoverRoll
        )

    root.CFrame = animatedCFrame
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
    humanoid.PlatformStand = true
    humanoid.AutoRotate = false
    root.Anchored = true
    currentMoveVector = Vector3.zero
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
hint.Text = "Space ↑   Ctrl/C ↓   •   Look to climb/dive"
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
