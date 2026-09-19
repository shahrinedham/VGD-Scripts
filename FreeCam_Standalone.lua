-- VGD Freecam Standalone
-- Extracted from VGD_Design2_v130_HOVER_ONLY.lua
-- Controller API: Enable(), Disable(), IsEnabled()

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local ContextActionService = game:GetService("ContextActionService")
local player = Players.LocalPlayer

local StandaloneGui = Instance.new("ScreenGui")
StandaloneGui.Name = "VGD_FreecamStandalone"
StandaloneGui.ResetOnSpawn = false
StandaloneGui.IgnoreGuiInset = true
StandaloneGui.DisplayOrder = 2000
StandaloneGui.Parent = game:GetService("CoreGui")

local freecamEnabled = false
local stateChangedEvent = Instance.new("BindableEvent")
local freecamConnection = nil
local freecamCharacterConnection = nil
local freecamDeathConnection = nil
local freecamRespawnConnection = nil
-- Physical-character state is tracked per character so a respawn can be
-- locked without overwriting the original character's state.
local freecamCharacterStates = setmetatable({}, {__mode = "k"})
local freecamLockedCharacter = nil
local freecamSavedCFrame = nil
local freecamSavedCameraType = nil
local freecamSavedCameraSubject = nil
local freecamSavedAnchored = nil
local freecamPosition = nil
local freecamInitialPosition = nil
local freecamHologram = nil
local freecamHologramCameraOffset = Vector3.new()
local freecamCameraOffset = Vector3.new()
-- Roblox-style Freecam Shift Lock.  The button is shown only while Freecam
-- is active, and the Settings toggle controls whether the feature is shown.
local freecamShiftLockOn = true
local freecamShiftLockButton = nil
local freecamShiftLockShiftedOffset = Vector3.new()
local freecamShiftLockUnshiftedOffset = Vector3.new()
local freecamShiftLockRightVector = Vector3.new(1, 0, 0)
local freecamBodyYaw = 0
local freecamFlightBankBlend = 0
local freecamFlightSpeedBlend = 0
local freecamFlightPreviousDesiredYaw = nil
local freecamFlightPreviousMoveDirection = Vector3.new()

-- FREECAM INPUT / CAMERA FEEL
-- =========================================================
-- This follows the same input model used by Roblox's current CameraModule:
-- touch movement is accumulated from InputObject.Delta and consumed once per
-- render frame, while the dynamic thumbstick touch is explicitly ignored.
-- This makes the freecam look control feel much closer to Roblox's normal
-- mobile camera instead of reacting directly to every InputChanged event.

-- Adjustable in the top slider while Freecam is enabled.
local FREECAM_SPEED = 35
local FREECAM_SPEED_MIN = 1
local FREECAM_SPEED_MAX = 1000

-- Roblox CameraInput uses Vector2.new(1, 0.66) * 1 degree per touch pixel.
local FREECAM_TOUCH_ROTATION_SPEED = Vector2.new(0.82, 0.54) * math.rad(1)
local FREECAM_MOUSE_ROTATION_SPEED = Vector2.new(1, 0.77) * math.rad(0.5)
local FREECAM_LOOK_SMOOTHNESS = 34
local FREECAM_MIN_PITCH = math.rad(-89)
local FREECAM_MAX_PITCH = math.rad(89)

local freecamTouchStates = {}
local freecamTouchDelta = Vector2.new()
local freecamMouseDelta = Vector2.new()

-- Pinch zoom is handled inside the same ContextActionService touch path as
-- mobile camera look. Binding all world touches at high priority can prevent
-- UserInputService.TouchPinch from firing, so keeping the two touch positions
-- here makes pinch zoom reliable while preserving joystick + camera swipe.
local freecamZoomTouchPositions = {}
local freecamPinchLastDiameter = nil
local freecamTouchEndedCleanupConnection = nil

local function freecamIsInDynamicThumbstickArea(position)
    local playerGui = player:FindFirstChildOfClass("PlayerGui")
    local touchGui = playerGui and playerGui:FindFirstChild("TouchGui")

    if not touchGui or not touchGui.Enabled then
        return false
    end

    local touchFrame = touchGui:FindFirstChild("TouchControlFrame")
    local thumbstickFrame = touchFrame and touchFrame:FindFirstChild("DynamicThumbstickFrame")

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

local function freecamIsOverGui(position)
    if not position then
        return false
    end

    -- Only block touches that are actually over VGD's own GUI.
    -- Roblox/CoreGui can otherwise make a world touch look "processed".
    local ok, objects = pcall(function()
        return GuiService:GetGuiObjectsAtPosition(position.X, position.Y)
    end)

    if not ok or not objects then
        return false
    end

    for _, object in ipairs(objects) do
        if object:IsDescendantOf(StandaloneGui) then
            return true
        end
    end

    return false
end

local function freecamAdjustTouchPitchSensitivity(delta)
    local camera = workspace.CurrentCamera
    if not camera then
        return delta
    end

    local pitch = camera.CFrame:ToEulerAnglesYXZ()

    -- Match Roblox's reduced touch-pitch sensitivity near the vertical limits.
    if delta.Y * pitch >= 0 then
        return delta
    end

    local minimumFraction = 0.25
    local curveY = 1 - (2 * math.abs(pitch) / math.pi) ^ 0.75
    local sensitivity =
        curveY * (1 - minimumFraction) + minimumFraction

    return Vector2.new(delta.X, delta.Y * sensitivity)
end

local function freecamResetInput()
    table.clear(freecamTouchStates)
    freecamTouchDelta = Vector2.new()
    freecamMouseDelta = Vector2.new()
    freecamLastLookPosition = nil
    freecamMouseLooking = false
    table.clear(freecamZoomTouchPositions)
    local freecamPinchLastDiameter = nil
end

function freecamSmoothLook(dt)
    local alpha = 1 - math.exp(-FREECAM_LOOK_SMOOTHNESS * math.max(dt, 0))
    freecamYaw = freecamYaw + (freecamTargetYaw - freecamYaw) * alpha
    freecamPitch = freecamPitch + (freecamTargetPitch - freecamPitch) * alpha
end

local function freecamApplyLookInput()
    local touchDelta = freecamTouchDelta
    local mouseDelta = freecamMouseDelta

    freecamTouchDelta = Vector2.new()
    freecamMouseDelta = Vector2.new()

    if touchDelta.Magnitude > 0 then
        touchDelta = freecamAdjustTouchPitchSensitivity(touchDelta)

        local rotation = Vector2.new(
            touchDelta.X * FREECAM_TOUCH_ROTATION_SPEED.X,
            touchDelta.Y * FREECAM_TOUCH_ROTATION_SPEED.Y
        )

        -- Same direction convention as Roblox's mobile camera:
        -- swipe left -> camera looks left, swipe up -> camera looks up.
        freecamTargetYaw = freecamTargetYaw - rotation.X
        freecamTargetPitch = math.clamp(
            freecamTargetPitch - rotation.Y,
            FREECAM_MIN_PITCH,
            FREECAM_MAX_PITCH
        )
    end

    if mouseDelta.Magnitude > 0 then
        local rotation = Vector2.new(
            mouseDelta.X * FREECAM_MOUSE_ROTATION_SPEED.X,
            mouseDelta.Y * FREECAM_MOUSE_ROTATION_SPEED.Y
        )

        freecamTargetYaw = freecamTargetYaw - rotation.X
        freecamTargetPitch = math.clamp(
            freecamTargetPitch - rotation.Y,
            FREECAM_MIN_PITCH,
            FREECAM_MAX_PITCH
        )
    end
end


-- Standalone FPS/Ping display used by the Freecam speed control.
-- In v130 this lived in the main VGD GUI; it must be recreated here so
-- Freecam has no dependency on the main panel.
local fpsPing = false
local fpsPingConnection = nil
local fpsPingFrames = 0
local fpsPingElapsed = 0
local fpsPingValue = 0
local pingValue = 0

local FPSPingScreenGui = Instance.new("ScreenGui")
FPSPingScreenGui.Name = "VGD_FreecamFPSPingGui"
FPSPingScreenGui.ResetOnSpawn = false
FPSPingScreenGui.IgnoreGuiInset = true
FPSPingScreenGui.DisplayOrder = 1999
FPSPingScreenGui.Parent = game:GetService("CoreGui")

local FPSPingDisplay = Instance.new("Frame")
FPSPingDisplay.Name = "VGD_FreecamFPSPingDisplay"
FPSPingDisplay.Size = UDim2.new(0, 130, 0, 43)
FPSPingDisplay.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
FPSPingDisplay.BackgroundTransparency = 0.1
FPSPingDisplay.Visible = false
FPSPingDisplay.ZIndex = 1999
FPSPingDisplay.Parent = FPSPingScreenGui

Instance.new("UICorner", FPSPingDisplay).CornerRadius = UDim.new(0, 22)

local FPSPingLabel = Instance.new("TextLabel")
FPSPingLabel.Size = UDim2.new(1, -16, 1, 0)
FPSPingLabel.Position = UDim2.new(0, 8, 0, 0)
FPSPingLabel.BackgroundTransparency = 1
FPSPingLabel.Text = "0 FPS | 0ms"
FPSPingLabel.TextColor3 = Color3.new(1, 1, 1)
FPSPingLabel.Font = Enum.Font.SourceSansBold
FPSPingLabel.TextSize = 18
FPSPingLabel.TextXAlignment = Enum.TextXAlignment.Center
FPSPingLabel.ZIndex = 2000
FPSPingLabel.Parent = FPSPingDisplay

function positionFPSPingDisplay()
    local camera = workspace.CurrentCamera
    local viewport = camera and camera.ViewportSize or Vector2.new(1536, 864)
    local x = math.floor(viewport.X * 0.295)
    FPSPingDisplay.Position = UDim2.new(0, x, 0.031, 0)
end

positionFPSPingDisplay()

local fpsViewportConnection = workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
    positionFPSPingDisplay()
end)

if workspace.CurrentCamera then
    workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
        positionFPSPingDisplay()
        if FreecamSpeedInput then
            positionFreecamSpeedInput()
        end
    end)
end

local function getCurrentPing()
    local ping = 0

    pcall(function()
        local network = game:GetService("Stats"):FindFirstChild("Network")
        local serverStats = network and network:FindFirstChild("ServerStatsItem")
        local dataPing = serverStats and serverStats:FindFirstChild("Data Ping")

        if dataPing then
            local raw = dataPing:GetValueString()
            local number = string.match(raw, "%d+")
            if number then
                ping = tonumber(number) or 0
            end
        end
    end)

    return ping
end

local function stopFPSPing()
    fpsPing = false
    FPSPingDisplay.Visible = false

    if fpsPingConnection then
        fpsPingConnection:Disconnect()
        fpsPingConnection = nil
    end
end

local function startFPSPing(updateText)
    stopFPSPing()
    fpsPing = true
    positionFPSPingDisplay()
    if FreecamSpeedInput then
        positionFreecamSpeedInput()
    end
    FPSPingDisplay.Visible = true
    fpsPingFrames = 0
    fpsPingElapsed = 0

    fpsPingConnection = RunService.RenderStepped:Connect(function(dt)
        if not fpsPing then
            return
        end

        fpsPingFrames = fpsPingFrames + 1
        fpsPingElapsed = fpsPingElapsed + dt

        if fpsPingElapsed >= 0.5 then
            fpsPingValue = math.floor((fpsPingFrames / fpsPingElapsed) + 0.5)
            pingValue = getCurrentPing()
            fpsPingFrames = 0
            fpsPingElapsed = 0

            FPSPingLabel.Text = string.format("%d FPS | %dms", fpsPingValue, pingValue)

            if updateText then
                updateText(fpsPingValue, pingValue)
            end
        end
    end)
end

freecamHologramIdleTrack = nil
freecamHologramMoveTrack = nil
freecamHologramBackwardTrack = nil
freecamHologramAnimMoving = false
freecamHologramAnimState = "Idle"

function createFreecamHologram()
    if freecamHologramIdleTrack then pcall(function() freecamHologramIdleTrack:Stop(0) end) end
    if freecamHologramMoveTrack then pcall(function() freecamHologramMoveTrack:Stop(0) end) end
    if freecamHologramBackwardTrack then pcall(function() freecamHologramBackwardTrack:Stop(0) end) end
    freecamHologramIdleTrack = nil
    freecamHologramMoveTrack = nil
    freecamHologramBackwardTrack = nil
    freecamHologramAnimMoving = false
    freecamHologramAnimState = "Idle"

    if freecamHologram then
        pcall(function() freecamHologram:Destroy() end)
        local freecamHologram = nil
    end

    local character = player.Character
    if not character then
        return
    end

    -- Character models can have Archivable disabled, which makes :Clone()
    -- silently return nil. Temporarily enable it so the visual soul can be
    -- created, then restore the original setting immediately.
    local clone
    local oldArchivable = character.Archivable
    character.Archivable = true
    local ok = pcall(function()
        clone = character:Clone()
    end)
    character.Archivable = oldArchivable
    if not ok or not clone then
        return
    end

    clone.Name = "VGD_FreecamHologram"

    -- Floating Sorceress animation tracks. These are kept separate from the
    -- v98 directional lean, so the animation drives the limbs while the
    -- hologram root CFrame continues to provide the directional lean.
    freecamHologramIdleTrack = nil
    freecamHologramMoveTrack = nil
    freecamHologramBackwardTrack = nil
    freecamHologramAnimMoving = false
    freecamHologramAnimState = "Idle"


    for _, object in ipairs(clone:GetDescendants()) do
        if object:IsA("Script") or object:IsA("LocalScript") or object:IsA("ModuleScript") then
            object:Destroy()
        elseif object:IsA("BasePart") then
            -- Only the hologram's root stays anchored. Anchoring every body
            -- part prevents Motor6D/Animator poses from visibly moving the
            -- limbs, which makes the hologram look frozen even when a track
            -- is successfully playing.
            object.Anchored = (object.Name == "HumanoidRootPart")
            object.CanCollide = false
            object.CanTouch = false
            object.CanQuery = false
            object.Massless = true
            object.Transparency = math.max(object.Transparency, 0.28)
        elseif object:IsA("Decal") or object:IsA("Texture") then
            object.Transparency = math.max(object.Transparency, 0.35)
        elseif object:IsA("Humanoid") then
            object.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
            object.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
            object.NameDisplayDistance = 0
        end
    end

    -- IMPORTANT: the clone must already be parented to Workspace before
    -- Animator:LoadAnimation(). Roblox requires the Animator to be in the
    -- live DataModel for animation loading/playback to work reliably.
    clone.Parent = workspace
    freecamHologram = clone

    local humanoid = clone:FindFirstChildOfClass("Humanoid")
    if humanoid then
        local animator = humanoid:FindFirstChildOfClass("Animator")
        if not animator then
            animator = Instance.new("Animator")
            animator.Parent = humanoid
        end

        -- Keep the cloned Humanoid passive while allowing its Animator to
        -- drive the Motor6D joints on the unanchored body parts.
        humanoid.AutoRotate = false
        humanoid.PlatformStand = true

        local idleAnimation = Instance.new("Animation")
        idleAnimation.Name = "VGD_FloatingSorceress_Idle"
        idleAnimation.AnimationId = "rbxassetid://106706162821039"
        idleAnimation.Parent = clone

        local moveAnimation = Instance.new("Animation")
        moveAnimation.Name = "VGD_FloatingSorceress_Run"
        moveAnimation.AnimationId = "rbxassetid://92749812489844"
        moveAnimation.Parent = clone

        local backwardAnimation = Instance.new("Animation")
        backwardAnimation.Name = "VGD_BackwardRun_Emote"
        backwardAnimation.AnimationId = "rbxassetid://117465215021389"
        backwardAnimation.Parent = clone

        local okIdle, idleTrack = pcall(function()
            return animator:LoadAnimation(idleAnimation)
        end)
        if okIdle and idleTrack then
            idleTrack.Priority = Enum.AnimationPriority.Movement
            idleTrack.Looped = true
            freecamHologramIdleTrack = idleTrack
            freecamHologramIdleTrack:Play(0.1, 1, 1)
            freecamHologramIdleTrack:AdjustSpeed(1)
        else
            warn("[VGD Freecam] Floating Sorceress IDLE animation failed to load: rbxassetid://106706162821039")
        end

        local okMove, moveTrack = pcall(function()
            return animator:LoadAnimation(moveAnimation)
        end)
        if okMove and moveTrack then
            moveTrack.Priority = Enum.AnimationPriority.Movement
            moveTrack.Looped = true
            freecamHologramMoveTrack = moveTrack
        else
            warn("[VGD Freecam] Floating Sorceress RUN animation failed to load: rbxassetid://92749812489844")
        end

        local okBackward, backwardTrack = pcall(function()
            return animator:LoadAnimation(backwardAnimation)
        end)
        if okBackward and backwardTrack then
            backwardTrack.Priority = Enum.AnimationPriority.Action
            backwardTrack.Looped = true
            freecamHologramBackwardTrack = backwardTrack
            warn(string.format(
                "[VGD Backward Emote] LOADED | ID=%s | Length=%.3f | Priority=%s",
                backwardAnimation.AnimationId,
                backwardTrack.Length or 0,
                tostring(backwardTrack.Priority)
            ))
        else
            warn("[VGD Backward Emote] FAILED TO LOAD | ID=rbxassetid://117465215021389")
        end
    else
        warn("[VGD Freecam] Hologram clone has no Humanoid; animations cannot play.")
    end

    local highlight = Instance.new("Highlight")
    highlight.Name = "VGD_HologramHighlight"
    highlight.FillColor = Color3.fromRGB(80, 180, 255)
    highlight.FillTransparency = 0.58
    highlight.OutlineColor = Color3.fromRGB(120, 210, 255)
    highlight.OutlineTransparency = 0.08
    highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
    highlight.Parent = clone

end

freecamHologramLeanBlend = 0
freecamHologramForwardBlend = 0
freecamHologramRightBlend = 0
    freecamHologramSideLeanBlend = 0
freecamHologramSideLeanBlend = 0
freecamHologramFlightPitchBlend = 0
-- v130 flight polish: subtle hover motion only. Takeoff/landing removed.

function updateFreecamHologram(cameraCFrame, moveDirection, isMoving, dt, flightPitchTarget)
    if not freecamHologram or not freecamHologram.Parent then
        return
    end

    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local realBodyCFrame = root and root.CFrame or freecamSavedCFrame
    if not realBodyCFrame or not freecamInitialPosition then
        return
    end

    local position = cameraCFrame:PointToWorldSpace(freecamHologramCameraOffset)

    local look = cameraCFrame.LookVector
    local flatLook = Vector3.new(look.X, 0, look.Z)
    if flatLook.Magnitude < 0.001 then
        flatLook = Vector3.new(0, 0, -1)
    else
        flatLook = flatLook.Unit
    end

    local baseCFrame = CFrame.lookAt(position, position + flatLook, Vector3.new(0, 1, 0))

    -- Flight direction smoothing / momentum. The hologram does not snap to a
    -- new travel direction. In unshifted mode its yaw eases toward movement;
    -- in Shift Lock mode it continues to face the camera as before.
    local horizontalMove = Vector3.new(0, 0, 0)
    if moveDirection and moveDirection.Magnitude > 0.001 then
        horizontalMove = Vector3.new(moveDirection.X, 0, moveDirection.Z)
    end

    local desiredFlightYaw = freecamBodyYaw or 0
    if freecamShiftLockOn then
        desiredFlightYaw = freecamYaw
    elseif horizontalMove.Magnitude > 0.001 and isMoving then
        horizontalMove = horizontalMove.Unit
        desiredFlightYaw = math.atan2(-horizontalMove.X, -horizontalMove.Z)
    end

    local function shortestAngleDelta(fromAngle, toAngle)
        return math.atan2(math.sin(toAngle - fromAngle), math.cos(toAngle - fromAngle))
    end

    local yawDelta = shortestAngleDelta(freecamBodyYaw or 0, desiredFlightYaw)
    local yawDuration = (isMoving and not freecamShiftLockOn) and 0.14 or 0.06
    local yawAlpha = 1 - math.exp(-math.max(dt or 0, 0) / yawDuration)
    freecamBodyYaw = (freecamBodyYaw or 0) + yawDelta * yawAlpha

    -- Keep the latest desired heading so abrupt direction changes can create
    -- a controlled bank instead of an instant roll.
    local previousDesiredYaw = freecamFlightPreviousDesiredYaw
    local desiredYawDelta = previousDesiredYaw and shortestAngleDelta(previousDesiredYaw, desiredFlightYaw) or 0
    freecamFlightPreviousDesiredYaw = desiredFlightYaw

    -- Turning creates a subtle aircraft/superhero-style roll. The sign is
    -- chosen so a right turn banks right and a left turn banks left.
    local turnRate = desiredYawDelta / math.max(dt or 0, 1 / 240)
    local targetBank = 0
    if isMoving and math.abs(turnRate) > 0.001 then
        targetBank = math.clamp(-turnRate * 0.11, math.rad(-18), math.rad(18))
    end
    local bankDuration = isMoving and 0.10 or 0.24
    local bankAlpha = 1 - math.exp(-math.max(dt or 0, 0) / bankDuration)
    freecamFlightBankBlend = (freecamFlightBankBlend or 0)
        + (targetBank - (freecamFlightBankBlend or 0)) * bankAlpha

    -- Speed-based aerodynamic pose. Higher flight speed adds a gentle forward
    -- pitch, while the existing travel-direction pitch still handles climbing
    -- and diving. Normalize against the current Freecam speed so the effect
    -- scales naturally if the user changes the speed setting.
    local speedRatio = 0
    if moveDirection and moveDirection.Magnitude > 0.001 and isMoving then
        speedRatio = math.clamp(moveDirection.Magnitude, 0, 1)
    end
    local speedTarget = speedRatio
    local speedAlpha = 1 - math.exp(-math.max(dt or 0, 0) / (isMoving and 0.16 or 0.30))
    freecamFlightSpeedBlend = (freecamFlightSpeedBlend or 0)
        + (speedTarget - (freecamFlightSpeedBlend or 0)) * speedAlpha

    -- Keep the animation procedural and deterministic. The previous version
    -- multiplied the HumanoidRootPart's current CFrame every frame, which
    -- accumulated tiny rotations/translations and made the soul look like it
    -- was wobbling. Always build animation from the clean base CFrame instead.
    freecamHologramAnimTime = freecamHologramAnimTime + math.max(dt or 0, 0)
    local deltaTime = math.max(dt or 0, 0)

    -- Use a short, fixed-duration state transition. The previous version used
    -- a long timeline and, more importantly, calculated the lean directly from
    -- the CURRENT movement vector. That made the lean disappear immediately
    -- when the stick was released, even while the flying pose was still meant
    -- to be transitioning.
    local targetMove = isMoving and 1 or 0
    local transitionDuration = targetMove > freecamHologramMoveBlend and 0.18 or 0.30
    local direction = targetMove > freecamHologramMoveBlend and 1 or -1
    if math.abs(targetMove - freecamHologramMoveBlend) > 0.0001 then
        freecamHologramMoveBlend = freecamHologramMoveBlend
            + direction * (deltaTime / transitionDuration)
    end
    freecamHologramMoveBlend = math.clamp(freecamHologramMoveBlend, 0, 1)

    -- Smoothstep makes the pose ease in and ease out rather than changing
    -- linearly. This is intentionally separate from the lean transition.
    local rawMoveBlend = freecamHologramMoveBlend
    local b = rawMoveBlend * rawMoveBlend * (3 - 2 * rawMoveBlend)

    -- Direction-aware animation state:
    -- Idle = stopped
    -- Forward/sideways = Floating Sorceress run
    -- Backward = the user's dedicated backward-run emote
    --
    -- Crossfade the old and new tracks instead of snapping between them.
    -- Nothing here touches camera input, movement, zoom, or hologram CFrame.
    local desiredAnimState = "Idle"
    if isMoving and moveDirection and moveDirection.Magnitude > 0.001 then
        local moveUnit = moveDirection.Unit
        local flatForward = flatLook
        local forwardDot = moveUnit:Dot(flatForward)

        if forwardDot < -0.15 then
            desiredAnimState = "Backward"
        else
            desiredAnimState = "Forward"
        end
    end

    if freecamHologramAnimState ~= desiredAnimState then
        local fadeOut = 0.16
        local fadeIn = 0.18

        if freecamHologramAnimState == "Idle" then
            if freecamHologramIdleTrack then
                freecamHologramIdleTrack:Stop(fadeOut)
            end
        elseif freecamHologramAnimState == "Forward" then
            if freecamHologramMoveTrack then
                freecamHologramMoveTrack:Stop(fadeOut)
            end
        elseif freecamHologramAnimState == "Backward" then
            if freecamHologramBackwardTrack then
                freecamHologramBackwardTrack:Stop(fadeOut)
            end
        end

        if desiredAnimState == "Idle" then
            if freecamHologramIdleTrack then
                freecamHologramIdleTrack:Play(fadeIn, 1, 1)
            end
        elseif desiredAnimState == "Forward" then
            if freecamHologramMoveTrack then
                freecamHologramMoveTrack:Play(fadeIn, 1, 1)
                freecamHologramMoveTrack:AdjustSpeed(1)
            end
        elseif desiredAnimState == "Backward" then
            if freecamHologramBackwardTrack then
                freecamHologramBackwardTrack:Play(fadeIn, 1, 1)
                freecamHologramBackwardTrack:AdjustSpeed(1)
                warn(string.format(
                    "[VGD Backward Emote] PLAY | Playing=%s | Length=%.3f | Speed=%.3f | Time=%.3f",
                    tostring(freecamHologramBackwardTrack.IsPlaying),
                    freecamHologramBackwardTrack.Length or 0,
                    freecamHologramBackwardTrack.Speed or 0,
                    freecamHologramBackwardTrack.TimePosition or 0
                ))

                task.delay(0.4, function()
                    if freecamHologramBackwardTrack then
                        warn(string.format(
                            "[VGD Backward Emote] VERIFY | Playing=%s | Time=%.3f | Weight=%.3f",
                            tostring(freecamHologramBackwardTrack.IsPlaying),
                            freecamHologramBackwardTrack.TimePosition or 0,
                            freecamHologramBackwardTrack.WeightCurrent or 0
                        ))
                    end
                end)
            else
                warn("[VGD Backward Emote] PLAY REQUESTED, BUT TRACK IS NIL")
            end
        end

        freecamHologramAnimState = desiredAnimState
        freecamHologramAnimMoving = desiredAnimState ~= "Idle"
    end

    -- Keep the last flight direction after the player stops moving. The old
    -- code set forwardAmount to zero immediately when moveDirection became
    -- zero, which is why stopping looked like an instant snap back to upright.
    local targetLean = 0
    if moveDirection and moveDirection.Magnitude > 0.001 and isMoving then
        targetLean = math.clamp(moveDirection.Unit:Dot(flatLook), -1, 1)
    end

    local currentLean = freecamHologramLeanBlend or 0
    local leanDuration = targetLean ~= 0 and 0.12 or 0.24
    local leanAlpha = math.clamp(deltaTime / leanDuration, 0, 1)
    -- Keep directional changes responsive. A slower eased response made
    -- front-to-back, left-to-right, and circular movement feel delayed and
    -- caused the hologram to look dizzy.
    leanAlpha = 1 - math.exp(-deltaTime / leanDuration)
    freecamHologramLeanBlend = currentLean
        + (targetLean - currentLean) * leanAlpha
    local leanAmount = freecamHologramLeanBlend

    -- Superhero flight tilt: when the flight vector has a vertical component,
    -- smoothly pitch the whole hologram so its body points along the 3D travel
    -- direction. Horizontal flight remains unchanged; only the vertical angle
    -- is added here. This keeps the existing Shift Lock / Unshift yaw behavior
    -- while making climbs and dives look physically directional.
    local targetFlightPitch = 0
    if isMoving and flightPitchTarget then
        targetFlightPitch = math.clamp(flightPitchTarget, math.rad(-75), math.rad(75))
    end

    local currentFlightPitch = freecamHologramFlightPitchBlend or 0
    local flightPitchDuration = isMoving and 0.10 or 0.22
    local flightPitchAlpha = 1 - math.exp(-deltaTime / flightPitchDuration)
    freecamHologramFlightPitchBlend = currentFlightPitch
        + (targetFlightPitch - currentFlightPitch) * flightPitchAlpha
    local flightPitch = freecamHologramFlightPitchBlend * b

    local t = freecamHologramAnimTime

    -- Idle: very small float, with no banking/rolling.
    -- Flying: gentle forward lean and a controlled arm/leg swimming motion.
    local idleBob = math.sin(t * 1.8) * 0.025
    local flyBob = math.sin(t * 3.6) * 0.045
    local bob = idleBob * (1 - b) + flyBob * b
    -- Lean in the full horizontal movement direction. Forward/backward
    -- movement controls pitch, while left/right movement controls roll.
    -- Diagonal movement naturally combines both, so the hologram can lean
    -- forward-right, forward-left, backward-right, or backward-left.
    local targetForward = freecamHologramForwardBlend or 0
    local targetRight = freecamHologramRightBlend or 0
    if moveDirection and moveDirection.Magnitude > 0.001 and isMoving then
        local moveUnit = moveDirection.Unit
        targetForward = math.clamp(moveUnit:Dot(flatLook), -1, 1)
        local flatRight = flatLook:Cross(Vector3.new(0, 1, 0))
        if flatRight.Magnitude > 0.001 then
            flatRight = flatRight.Unit
            targetRight = math.clamp(moveUnit:Dot(flatRight), -1, 1)
        else
            targetRight = 0
        end
    else
        -- Keep the last movement direction while the flying pose blends out.
        -- This prevents the lean from snapping upright on the first idle frame.
        targetForward = freecamHologramForwardBlend or 0
        targetRight = freecamHologramRightBlend or 0
    end

    local forwardTarget = 0
    local rightTarget = 0
    if moveDirection and moveDirection.Magnitude > 0.001 and isMoving then
        local moveUnit = moveDirection.Unit
        forwardTarget = math.clamp(moveUnit:Dot(flatLook), -1, 1)
        local flatRight = flatLook:Cross(Vector3.new(0, 1, 0))
        if flatRight.Magnitude > 0.001 then
            flatRight = flatRight.Unit
            rightTarget = math.clamp(moveUnit:Dot(flatRight), -1, 1)
        end
    end

    -- The movement direction itself needs its own transition. When movement
    -- stops, smoothly carry the last forward/side direction back to neutral
    -- instead of reading the now-zero moveDirection immediately.
    local directionDuration = isMoving and 0.08 or 0.48
    local directionAlpha = math.clamp(deltaTime / directionDuration, 0, 1)
    directionAlpha = 1 - math.exp(-deltaTime / directionDuration)
    freecamHologramForwardBlend = (freecamHologramForwardBlend or 0)
        + (forwardTarget - (freecamHologramForwardBlend or 0)) * directionAlpha
    freecamHologramRightBlend = (freecamHologramRightBlend or 0)
        + (rightTarget - (freecamHologramRightBlend or 0)) * directionAlpha

    local movementForward = freecamHologramForwardBlend
    local movementRight = freecamHologramRightBlend

    local flyLeanPitch = math.rad(16) * movementForward * b
    local flyLeanRoll = math.rad(14) * movementRight * b

    -- #4 Speed-based pose: at higher speed the hologram becomes slightly more
    -- aerodynamic. Keep this modest so it complements, rather than replaces,
    -- the climb/dive pitch and directional lean.
    local verticalTravelRatio = 0
    if moveDirection and moveDirection.Magnitude > 0.001 then
        verticalTravelRatio = math.clamp(math.abs(moveDirection.Unit.Y), 0, 1)
    end
    local horizontalSpeedPose = 1 - verticalTravelRatio
    local speedPosePitch = math.rad(10) * (freecamFlightSpeedBlend or 0) * horizontalSpeedPose * b

    -- #3 Banking: turning rolls the body into the turn. Existing directional
    -- roll remains available for diagonal movement, and the bank blends out
    -- smoothly after the turn finishes.
    local flightBank = freecamFlightBankBlend or 0

    -- #2 Hovering: when completely stationary in Freecam, give the hologram
    -- a subtle "staying airborne" motion instead of leaving it perfectly
    -- static. The existing idle animation still drives the limbs; this only
    -- adds a very small root-level vertical drift and roll/yaw.
    local hoverTarget = (not isMoving) and 1 or 0
    local hoverAlpha = 1 - math.exp(-deltaTime / ((hoverTarget > 0.5) and 0.20 or 0.16))
    freecamHologramHoverBlend = (freecamHologramHoverBlend or 0)
        + (hoverTarget - (freecamHologramHoverBlend or 0)) * hoverAlpha
    local hoverBlend = freecamHologramHoverBlend or 0
    local hoverBob = math.sin(t * 1.55) * 0.10 * hoverBlend
    local hoverRoll = math.sin(t * 1.10 + 0.7) * math.rad(1.2) * hoverBlend
    local hoverYaw = math.sin(t * 0.82 + 1.4) * math.rad(0.8) * hoverBlend

    local animatedCFrame =
        baseCFrame *
        CFrame.new(0, bob + hoverBob, 0) *
        CFrame.Angles(
            flightPitch - flyLeanPitch - speedPosePitch,
            hoverYaw,
            -flyLeanRoll - flightBank + hoverRoll
        )

    pcall(function()
        freecamHologram:PivotTo(animatedCFrame)
    end)

end
local function updateFreecamShiftLockButton()
    if not freecamShiftLockButton then
        return
    end

    freecamShiftLockButton.Visible = freecamEnabled == true
    freecamShiftLockButton.Image = freecamShiftLockOn
        and "rbxasset://textures/ui/mouseLock_on@2x.png"
        or "rbxasset://textures/ui/mouseLock_off@2x.png"
end

local function applyFreecamShiftLockState()
    if freecamShiftLockOn then
        freecamCameraOffset = freecamShiftLockShiftedOffset
    else
        freecamCameraOffset = freecamShiftLockUnshiftedOffset
    end

    updateFreecamShiftLockButton()
end

local function toggleFreecamShiftLock()
    if not freecamEnabled then
        return
    end

    freecamShiftLockOn = not freecamShiftLockOn
    applyFreecamShiftLockState()
end

local function lockCharacterForFreecam(character)
    if not freecamEnabled or not character then
        return nil
    end

    local root = character:FindFirstChild("HumanoidRootPart")
    if not root then
        return nil
    end

    if not freecamCharacterStates[character] then
        freecamCharacterStates[character] = {
            root = root,
            anchored = root.Anchored,
        }
    else
        -- Refresh the root reference if Roblox replaced the part during
        -- character initialization.
        freecamCharacterStates[character].root = root
    end

    -- The physical body must stay completely out of the Freecam session.
    -- Anchoring only the root preserves Humanoid.MoveDirection, which the
    -- Freecam uses as its movement input, while preventing the real body from
    -- walking/jumping away from its spawn point.
    root.Anchored = true
    freecamLockedCharacter = character

    return root
end

local function restoreCharacterAfterFreecam(character)
    local state = character and freecamCharacterStates[character]
    if not state then
        return
    end

    local root = state.root
    if root and root.Parent then
        root.Anchored = state.anchored
    end

    freecamCharacterStates[character] = nil

    if freecamLockedCharacter == character then
        freecamLockedCharacter = nil
    end
end

local function lockCurrentCharacterForFreecam()
    if not freecamEnabled then
        return nil
    end

    local character = player.Character
    if not character then
        return nil
    end

    return lockCharacterForFreecam(character)
end

local function disableFreecam()
    local wasFreecamActive = freecamEnabled

    freecamEnabled = false
    stateChangedEvent:Fire(false)

    if freecamHologramIdleTrack then pcall(function() freecamHologramIdleTrack:Stop(0) end) end
    if freecamHologramMoveTrack then pcall(function() freecamHologramMoveTrack:Stop(0) end) end
    if freecamHologramBackwardTrack then pcall(function() freecamHologramBackwardTrack:Stop(0) end) end
    freecamHologramIdleTrack = nil
    freecamHologramMoveTrack = nil
    freecamHologramBackwardTrack = nil
    freecamHologramAnimMoving = false
    freecamHologramAnimState = "Idle"

    if freecamHologram then
        pcall(function() freecamHologram:Destroy() end)
        local freecamHologram = nil
    end
    if FreecamSpeedInput then
        FreecamSpeedInput.Visible = false
    end
    local freecamShiftLockOn = true
    local freecamShiftLockShiftedOffset = Vector3.new()
    local freecamShiftLockUnshiftedOffset = Vector3.new()
    local freecamCameraOffset = Vector3.new()
    updateFreecamShiftLockButton()

    pcall(function()
        game:GetService("ContextActionService"):UnbindAction("VGD_FreecamTouchCamera")
    end)

    if freecamConnection then
        if freecamConnection.Render then freecamConnection.Render:Disconnect() end
        if freecamConnection.LookBegan then freecamConnection.LookBegan:Disconnect() end
        if freecamConnection.LookChanged then freecamConnection.LookChanged:Disconnect() end
        if freecamConnection.LookEnded then freecamConnection.LookEnded:Disconnect() end
        if freecamConnection.InputChanged then freecamConnection.InputChanged:Disconnect() end
        if freecamConnection.TouchPan then freecamConnection.TouchPan:Disconnect() end
        freecamConnection = nil
    end

    if freecamDeathConnection then
        freecamDeathConnection:Disconnect()
        local freecamDeathConnection = nil
    end

    if freecamCharacterConnection then
        freecamCharacterConnection:Disconnect()
        freecamCharacterConnection = nil
    end

    if freecamTouchEndedCleanupConnection then
        freecamTouchEndedCleanupConnection:Disconnect()
        local freecamTouchEndedCleanupConnection = nil
    end

    freecamResetInput()

    -- Restore whichever physical character was last locked by Freecam.
    -- This matters after a respawn: player.Character is the NEW character,
    -- while the enable-time saved state belongs to the old character.
    local character = player.Character
    restoreCharacterAfterFreecam(character)

    if freecamLockedCharacter then
        restoreCharacterAfterFreecam(freecamLockedCharacter)
    end

    local root = character and character:FindFirstChild("HumanoidRootPart")
    if root and freecamSavedAnchored ~= nil and not freecamCharacterStates[character] then
        -- Compatibility fallback for a character that was locked before the
        -- per-character state table was introduced.
        root.Anchored = freecamSavedAnchored
    end

    local camera = workspace.CurrentCamera
    if camera then
        if freecamSavedCameraType then
            camera.CameraType = freecamSavedCameraType
        end

        if freecamSavedCameraSubject then
            camera.CameraSubject = freecamSavedCameraSubject
        end

        if freecamSavedFOV then
            camera.FieldOfView = freecamSavedFOV
        end
    end

    local freecamSavedFOV = nil
    local freecamFOV = 70
    local freecamTargetFOV = 70
    local freecamPinchBaseFOV = 70
    local freecamHologramCameraOffset = Vector3.new()
    freecamHologramAnimTime = 0
    freecamHologramHoverBlend = 0
    freecamHologramMoveBlend = 0
    freecamHologramLeanBlend = 0
    freecamHologramSideLeanBlend = 0
    local freecamCameraOffset = Vector3.new()
    freecamSavedCFrame = nil
    freecamSavedCameraType = nil
    freecamSavedCameraSubject = nil
    freecamSavedAnchored = nil
    freecamLockedCharacter = nil
    table.clear(freecamCharacterStates)
    freecamPosition = nil
    local freecamInitialPosition = nil
    local freecamPitch = 0
    local freecamYaw = 0
    local freecamBodyYaw = 0
    local freecamFlightBankBlend = 0
    local freecamFlightSpeedBlend = 0
    local freecamFlightPreviousDesiredYaw = nil
    local freecamFlightPreviousMoveDirection = Vector3.new()
    local freecamLookInput = nil

end

local function enableFreecam()
    disableFreecam()

    local character = player.Character
    if not character then
        return false
    end

    local root = character:FindFirstChild("HumanoidRootPart")
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local camera = workspace.CurrentCamera

    if not root or not humanoid or not camera then
        return false
    end

    freecamEnabled = true
    stateChangedEvent:Fire(true)
    freecamHologramHoverBlend = 0
    if FreecamSpeedInput then
        FreecamSpeedInput.Text = tostring(math.floor(FREECAM_SPEED + 0.5))
        FreecamSpeedInput.Visible = true
    end
    freecamSavedCFrame = root.CFrame
    freecamSavedCameraType = camera.CameraType
    freecamSavedCameraSubject = camera.CameraSubject
    freecamSavedAnchored = root.Anchored
    freecamSavedFOV = camera.FieldOfView
    freecamFOV = freecamSavedFOV
    freecamTargetFOV = freecamSavedFOV
    freecamPinchBaseFOV = freecamSavedFOV

    -- Start Freecam from the REAL camera viewpoint. Keep its own 2-24
    -- stud zoom range, but preserve the normal camera's small vertical /
    -- lateral offset from the character so enabling Freecam does not make
    -- the viewpoint visibly jump downward.
    local normalCameraLook = camera.CFrame.LookVector
    local cameraToRoot = root.Position - camera.CFrame.Position
    local normalCameraDistance = cameraToRoot:Dot(normalCameraLook)

    if normalCameraDistance <= 0.01 then
        normalCameraDistance =
            (camera.CFrame.Position - root.Position).Magnitude
    end

    local freecamZoomMin = 2
    local freecamZoomMax = 24
    freecamZoomDistance = math.clamp(
        normalCameraDistance,
        freecamZoomMin,
        freecamZoomMax
    )
    freecamTargetZoomDistance = freecamZoomDistance

    -- The normal Roblox camera is not necessarily on the exact line from
    -- the HumanoidRootPart to the camera. Capture that perpendicular offset
    -- and carry it into Freecam. This preserves the original camera height
    -- (and any small side offset) while still allowing independent zoom.
    local normalCameraLinePosition =
        root.Position - normalCameraLook * normalCameraDistance
    freecamCameraOffset =
        camera.CFrame.Position - normalCameraLinePosition

    -- Preserve the exact starting camera offset as the "shifted" state.
    -- Unshift removes only the lateral (shoulder) component, while keeping
    -- the normal camera's vertical/depth offset intact.
    freecamShiftLockRightVector = camera.CFrame.RightVector
    local shoulderAmount = freecamCameraOffset:Dot(freecamShiftLockRightVector)
    freecamShiftLockShiftedOffset = freecamCameraOffset
    freecamShiftLockUnshiftedOffset =
        freecamCameraOffset - freecamShiftLockRightVector * shoulderAmount
    local freecamShiftLockOn = true
    applyFreecamShiftLockState()

    freecamPitch, freecamYaw = camera.CFrame:ToOrientation()
    -- In Freecam Shift Lock mode the hologram follows the camera. When
    -- unshifted, it behaves like a normal character: it keeps its current
    -- facing direction while idle and turns toward its movement direction.
    freecamBodyYaw = freecamYaw
    local freecamFlightBankBlend = 0
    local freecamFlightSpeedBlend = 0
    freecamFlightPreviousDesiredYaw = freecamYaw
    local freecamFlightPreviousMoveDirection = Vector3.new()

    -- The hologram is the subject, so start it exactly on the real body.
    -- The camera itself starts at the same distance as the normal camera
    -- (clamped to 2-24 studs) and can still be changed with pinch/wheel.
    freecamPosition = root.Position
    freecamInitialPosition = freecamPosition
    local freecamHologramCameraOffset = Vector3.new()
    createFreecamHologram()

    -- Put the hologram at the real body immediately. It will then mirror
    -- Freecam displacement from this starting point.
    if freecamHologram then
        pcall(function()
            freecamHologram:PivotTo(freecamSavedCFrame)
        end)
    end
    freecamTargetPitch = freecamPitch
    freecamTargetYaw = freecamYaw
    freecamResetInput()

    -- Lock the physical body without disabling its Humanoid input. The
    -- joystick still supplies MoveDirection to Freecam, but the real body
    -- cannot walk or jump away from the point where the soul departed.
    lockCharacterForFreecam(character)
    camera.CameraType = Enum.CameraType.Scriptable

    local freecamRenderConnection = RunService:BindToRenderStep(
        "VGD_FreecamCamera",
        Enum.RenderPriority.Camera.Value + 1,
        function(dt)
            if not freecamEnabled then
                return
            end

            local currentCharacter = player.Character
            local currentRoot = currentCharacter and currentCharacter:FindFirstChild("HumanoidRootPart")

            -- Respawn is NOT a Freecam state transition. Keep the soul/camera
            -- session alive and lock the newly spawned physical body as soon
            -- as its root exists. The camera remains Scriptable throughout.
            if currentCharacter and currentCharacter ~= freecamLockedCharacter and currentRoot then
                lockCharacterForFreecam(currentCharacter)
            elseif currentCharacter and currentRoot and not freecamCharacterStates[currentCharacter] then
                lockCharacterForFreecam(currentCharacter)
            end

            local currentHumanoid = currentCharacter and currentCharacter:FindFirstChildOfClass("Humanoid")
            local currentCamera = workspace.CurrentCamera

            if not currentRoot or not currentHumanoid or not currentCamera then
                return
            end

            -- Consume buffered mouse input, then smoothly follow the target
            -- orientation so mobile camera movement stays responsive without jitter.
            freecamApplyLookInput()
            freecamSmoothLook(dt)

            local zoomAlpha = 1 - math.exp(-14 * math.max(dt, 0))
            freecamFOV = freecamFOV + (freecamTargetFOV - freecamFOV) * zoomAlpha
            freecamZoomDistance = freecamZoomDistance
                + (freecamTargetZoomDistance - freecamZoomDistance) * zoomAlpha

            local moveDirection = currentHumanoid.MoveDirection
            local horizontalMove = Vector3.new(moveDirection.X, 0, moveDirection.Z)
            local cameraLook = currentCamera.CFrame.LookVector
            local right = currentCamera.CFrame.RightVector

            local horizontalLook = Vector3.new(cameraLook.X, 0, cameraLook.Z)
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

            local forwardInput = math.clamp(horizontalMove:Dot(horizontalLook), -1, 1)
            local rightInput = math.clamp(horizontalMove:Dot(horizontalRight), -1, 1)

            local moveVector =
                (cameraLook * forwardInput) +
                (horizontalRight * rightInput)

            if moveVector.Magnitude > 1 then
                moveVector = moveVector.Unit
            end

            freecamPosition = freecamPosition + moveVector * FREECAM_SPEED * dt

            -- Freecam Shift Lock ON: the hologram faces wherever the camera
            -- is looking, matching the current Shift Lock behavior.
            -- Freecam Shift Lock OFF: the camera is independent from the
            -- hologram, like normal unshifted Roblox camera behavior. The
            -- hologram keeps its facing direction while idle and turns toward
            -- its actual movement direction when the player moves.
            -- Body yaw is smoothed inside updateFreecamHologram so direction
            -- changes have visible momentum instead of snapping.
            local hologramCFrame =
                CFrame.new(freecamPosition) *
                CFrame.Angles(0, freecamBodyYaw, 0) *
                CFrame.Angles(freecamPitch, 0, 0)

            -- The hologram is the Freecam subject. In unshifted mode the
            -- camera direction is independent, so looking around no longer
            -- rotates the hologram. Zoom still uses the same physical camera
            -- distance and the existing camera offset remains untouched.
            local subjectPosition = freecamPosition
            local cameraLookCFrame =
                CFrame.new(subjectPosition) *
                CFrame.Angles(0, freecamYaw, 0) *
                CFrame.Angles(freecamPitch, 0, 0)
            local freecamCameraLook = cameraLookCFrame.LookVector
            local cameraPosition =
                subjectPosition - freecamCameraLook * freecamZoomDistance
                + freecamCameraOffset

            local cameraCFrame = CFrame.lookAt(
                cameraPosition,
                cameraPosition + freecamCameraLook
            )

            currentCamera.CFrame = cameraCFrame
            currentCamera.FieldOfView = freecamFOV
            currentCamera.Focus = CFrame.new(subjectPosition)
            local isHologramMoving = moveVector.Magnitude > 0.05
            local flightPitchTarget = 0
            if isHologramMoving then
                local travelHorizontalMagnitude = Vector3.new(moveVector.X, 0, moveVector.Z).Magnitude
                if travelHorizontalMagnitude > 0.001 then
                    flightPitchTarget = math.atan2(moveVector.Y, travelHorizontalMagnitude)
                elseif math.abs(moveVector.Y) > 0.001 then
                    flightPitchTarget = moveVector.Y > 0 and math.rad(90) or math.rad(-90)
                end
            end

            updateFreecamHologram(
                hologramCFrame,
                moveVector,
                isHologramMoving,
                dt,
                flightPitchTarget
            )
        end
    )

    -- Mobile touch camera:
    -- Capture world touches through ContextActionService. This mirrors the
    -- proven mobile Scriptable-camera pattern: Begin selects the finger,
    -- Change consumes InputObject.Delta, and End releases it.
    --
    -- This is deliberately direct instead of routing touch deltas through
    -- TouchPan -> a render-step accumulator. That removes gesture arbitration
    -- and frame-ordering as failure points on mobile/executor clients.
    local contextActionService = game:GetService("ContextActionService")
    local freecamTouchActionName = "VGD_FreecamTouchCamera"

    contextActionService:UnbindAction(freecamTouchActionName)

    local freecamTouchAction = function(actionName, inputState, inputObject)
        if not freecamEnabled then
            return Enum.ContextActionResult.Pass
        end

        if inputObject.UserInputType ~= Enum.UserInputType.Touch then
            return Enum.ContextActionResult.Pass
        end

        if inputState == Enum.UserInputState.Begin then
            if freecamIsInDynamicThumbstickArea(inputObject.Position) then
                return Enum.ContextActionResult.Pass
            end

            if freecamIsOverGui(inputObject.Position) then
                return Enum.ContextActionResult.Pass
            end

            freecamTouchStates[inputObject] = true
            freecamZoomTouchPositions[inputObject] = inputObject.Position

            -- Start/reset the pinch baseline as soon as the second world
            -- touch appears. This avoids a jump in zoom when two fingers land.
            local zoomTouchCount = 0
            local firstZoomPosition = nil
            local secondZoomPosition = nil
            for _, position in pairs(freecamZoomTouchPositions) do
                zoomTouchCount += 1
                if not firstZoomPosition then
                    firstZoomPosition = position
                elseif not secondZoomPosition then
                    secondZoomPosition = position
                end
            end
            if zoomTouchCount >= 2 then
                freecamPinchLastDiameter =
                    (firstZoomPosition - secondZoomPosition).Magnitude
            end

            return Enum.ContextActionResult.Sink
        end

        if freecamTouchStates[inputObject] then
            if inputState == Enum.UserInputState.Change then
                freecamZoomTouchPositions[inputObject] = inputObject.Position

                local zoomTouchCount = 0
                local firstZoomPosition = nil
                local secondZoomPosition = nil
                for _, position in pairs(freecamZoomTouchPositions) do
                    zoomTouchCount += 1
                    if not firstZoomPosition then
                        firstZoomPosition = position
                    elseif not secondZoomPosition then
                        secondZoomPosition = position
                    end
                end

                -- Two world touches = pinch. Do not also rotate the camera.
                if zoomTouchCount >= 2 then
                    local diameter =
                        (firstZoomPosition - secondZoomPosition).Magnitude

                    if freecamPinchLastDiameter then
                        local pinchDelta =
                            diameter - freecamPinchLastDiameter
                        local zoomDelta = -pinchDelta * 0.04
                        local currentZoom = freecamTargetZoomDistance
                        local newZoom

                        if zoomDelta > 0 then
                            newZoom = currentZoom
                                + zoomDelta * (1 + currentZoom * 0.5)
                        else
                            newZoom = (currentZoom + zoomDelta)
                                / (1 - zoomDelta * 0.5)
                        end

                        freecamTargetZoomDistance = math.clamp(
                            newZoom,
                            freecamZoomMin,
                            freecamZoomMax
                        )
                    end

                    freecamPinchLastDiameter = diameter
                    return Enum.ContextActionResult.Sink
                end

                local delta = inputObject.Delta
                if delta.Magnitude > 0 then
                    delta = freecamAdjustTouchPitchSensitivity(delta)
                    local rotation = Vector2.new(
                        delta.X * FREECAM_TOUCH_ROTATION_SPEED.X,
                        delta.Y * FREECAM_TOUCH_ROTATION_SPEED.Y
                    )
                    freecamTargetYaw = freecamTargetYaw - rotation.X
                    freecamTargetPitch = math.clamp(
                        freecamTargetPitch - rotation.Y,
                        FREECAM_MIN_PITCH,
                        FREECAM_MAX_PITCH
                    )
                end
                return Enum.ContextActionResult.Sink
            end

            if inputState == Enum.UserInputState.End
                or inputState == Enum.UserInputState.Cancel then
                freecamTouchStates[inputObject] = nil
                freecamZoomTouchPositions[inputObject] = nil

                local zoomTouchCount = 0
                for _ in pairs(freecamZoomTouchPositions) do
                    zoomTouchCount += 1
                end
                if zoomTouchCount < 2 then
                    local freecamPinchLastDiameter = nil
                end

                return Enum.ContextActionResult.Sink
            end

            return Enum.ContextActionResult.Sink
        end

        return Enum.ContextActionResult.Pass
    end

    contextActionService:BindActionAtPriority(
        freecamTouchActionName,
        freecamTouchAction,
        false,
        Enum.ContextActionPriority.High.Value,
        Enum.UserInputType.Touch
    )

    -- Safety cleanup: on some mobile/executor combinations a high-priority
    -- ContextActionService touch can occasionally miss its End callback.
    -- If that happens, a released finger could remain in the pinch table and
    -- make the next single-finger swipe look like a two-finger zoom.
    -- UserInputService.TouchEnded is used only for cleanup; it never controls
    -- the camera or consumes the touch.
    freecamTouchEndedCleanupConnection = UserInputService.TouchEnded:Connect(function(input)
        freecamTouchStates[input] = nil
        freecamZoomTouchPositions[input] = nil

        local zoomTouchCount = 0
        for _ in pairs(freecamZoomTouchPositions) do
            zoomTouchCount += 1
        end

        if zoomTouchCount < 2 then
            local freecamPinchLastDiameter = nil
        end
    end)

    -- Pinch zoom is handled by the ContextActionService touch action above.
    -- This keeps zoom working even though the camera action consumes touches.

    local freecamMouseWheelConnection =
        UserInputService.InputChanged:Connect(function(input)
            if not freecamEnabled then
                return
            end

            if input.UserInputType == Enum.UserInputType.MouseWheel then
                local wheel = input.Position.Z

                if wheel ~= 0 then
                    local zoomDelta = -wheel
                    local currentZoom = freecamTargetZoomDistance
                    local newZoom

                    if zoomDelta > 0 then
                        newZoom = currentZoom
                            + zoomDelta * (1 + currentZoom * 0.5)
                    else
                        newZoom = (currentZoom + zoomDelta)
                            / (1 - zoomDelta * 0.5)
                    end

                    freecamTargetZoomDistance = math.clamp(
                        newZoom,
                        freecamZoomMin,
                        freecamZoomMax
                    )
                end
            end
        end)

    -- Desktop: right-mouse drag retains normal freecam-style camera control.
    local freecamMouseBegan = UserInputService.InputBegan:Connect(function(input, gameProcessedEvent)
        if not freecamEnabled or gameProcessedEvent then
            return
        end

        if input.UserInputType == Enum.UserInputType.MouseButton2 then
            freecamMouseLooking = true
        end
    end)

    local freecamMouseChanged = UserInputService.InputChanged:Connect(function(input)
        if not freecamEnabled or not freecamMouseLooking then
            return
        end

        if input.UserInputType == Enum.UserInputType.MouseMovement then
            freecamMouseDelta += input.Delta
        end
    end)

    local freecamMouseEnded = UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton2 then
            freecamMouseLooking = false
        end
    end)

    freecamConnection = {
        Render = {
            Disconnect = function()
                RunService:UnbindFromRenderStep("VGD_FreecamCamera")
            end
        },
        MouseBegan = freecamMouseBegan,
        MouseChanged = freecamMouseChanged,
        MouseEnded = freecamMouseEnded,
        MouseWheel = freecamMouseWheelConnection,
    }

    -- Extend cleanup to the desktop mouse connections too.
    local originalDisconnect = freecamConnection.Render.Disconnect
    freecamConnection.Render.Disconnect = function()
        originalDisconnect()
        if freecamConnection and freecamConnection.MouseBegan then
            freecamConnection.MouseBegan:Disconnect()
            freecamConnection.MouseBegan = nil
        end
        if freecamConnection and freecamConnection.MouseChanged then
            freecamConnection.MouseChanged:Disconnect()
            freecamConnection.MouseChanged = nil
        end
        if freecamConnection and freecamConnection.MouseEnded then
            freecamConnection.MouseEnded:Disconnect()
            freecamConnection.MouseEnded = nil
        end
        if freecamConnection and freecamConnection.Pinch then
            freecamConnection.Pinch:Disconnect()
            freecamConnection.Pinch = nil
        end
        if freecamConnection and freecamConnection.MouseWheel then
            freecamConnection.MouseWheel:Disconnect()
            freecamConnection.MouseWheel = nil
        end
    end

    return true
end

-- Keep one persistent respawn watcher. It must NOT be owned by the Freecam
-- session itself, otherwise disableFreecam() would disconnect the very
-- watcher responsible for catching the next character replacement.
if freecamRespawnConnection then
    freecamRespawnConnection:Disconnect()
end
freecamRespawnConnection = player.CharacterAdded:Connect(function(character)
    if not freecamEnabled then
        return
    end

    -- CharacterAdded itself is cheap and does not touch the camera. Lock the
    -- root as soon as it is available. The RenderStep below repeats the lock
    -- as a safety net without doing any per-frame allocations.
    local root = character:FindFirstChild("HumanoidRootPart")
    if root then
        lockCharacterForFreecam(character)
    end

    task.spawn(function()
        if not freecamEnabled or not character.Parent then
            return
        end

        local readyRoot = character:WaitForChild("HumanoidRootPart", 2)
        if freecamEnabled and readyRoot and character.Parent then
            lockCharacterForFreecam(character)
        end
    end)
end)

FreecamSpeedInput = Instance.new("TextBox")
FreecamSpeedInput.Name = "FreecamSpeedInput"
FreecamSpeedInput.Size = UDim2.fromOffset(73, 43)
FreecamSpeedInput.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
FreecamSpeedInput.BackgroundTransparency = 0.1
FreecamSpeedInput.TextColor3 = Color3.new(1, 1, 1)
FreecamSpeedInput.PlaceholderColor3 = Color3.fromRGB(170, 170, 170)
FreecamSpeedInput.Font = Enum.Font.SourceSansBold
FreecamSpeedInput.TextSize = 18
FreecamSpeedInput.Text = tostring(math.floor(FREECAM_SPEED + 0.5))
FreecamSpeedInput.PlaceholderText = "Speed"
FreecamSpeedInput.ClearTextOnFocus = false
FreecamSpeedInput.TextXAlignment = Enum.TextXAlignment.Center
FreecamSpeedInput.Visible = false
FreecamSpeedInput.Active = true
FreecamSpeedInput.ZIndex = 2000
FreecamSpeedInput.Parent = StandaloneGui

Instance.new("UICorner", FreecamSpeedInput).CornerRadius = UDim.new(0, 22)

FreecamSpeedInput.FocusLost:Connect(function()
    local value = tonumber(FreecamSpeedInput.Text)
    if value == nil then
        FreecamSpeedInput.Text = tostring(math.floor(FREECAM_SPEED + 0.5))
        return
    end

    FREECAM_SPEED = math.clamp(value, FREECAM_SPEED_MIN, FREECAM_SPEED_MAX)
    FreecamSpeedInput.Text = tostring(math.floor(FREECAM_SPEED + 0.5))
end)

FreecamSpeedInput:GetPropertyChangedSignal("Text"):Connect(function()
    -- Keep the field numeric while allowing the user to type normally.
    local cleaned = string.gsub(FreecamSpeedInput.Text, "[^%d%.]", "")
    if cleaned ~= FreecamSpeedInput.Text then
        FreecamSpeedInput.Text = cleaned
    end
end)

function positionFreecamSpeedInput()
    -- Match the FPS/Ping display height and place the speed input
    -- immediately to its right with the same compact visual gap.
    local fpsPosition = FPSPingDisplay.AbsolutePosition
    local fpsSize = FPSPingDisplay.AbsoluteSize
    local gap = 12
    local x = math.floor(fpsPosition.X + fpsSize.X + gap)
    local y = math.floor(fpsPosition.Y)

    FreecamSpeedInput.Position = UDim2.new(0, x, 0, y)
end

positionFreecamSpeedInput()

if task and task.defer then
    task.defer(positionFreecamSpeedInput)
end

if workspace.CurrentCamera then
    workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
        positionFreecamSpeedInput()
        if freecamShiftLockButton then
            freecamShiftLockButton.Position = UDim2.new(0, 18, 0.5, 0)
        end
    end)
end

-- =========================================================
-- FREECAM SHIFT LOCK BUTTON
-- =========================================================
-- Use Roblox's own Shift Lock textures so the control matches the native
-- icon instead of drawing a look-alike. It is deliberately smaller and
-- placed at the middle-left of the screen, and exists only during Freecam.
freecamShiftLockButton = Instance.new("ImageButton")
freecamShiftLockButton.Name = "VGD_FreecamShiftLock"
freecamShiftLockButton.Size = UDim2.fromOffset(30, 30)
freecamShiftLockButton.AnchorPoint = Vector2.new(0, 0.5)
freecamShiftLockButton.Position = UDim2.new(0, 18, 0.5, 0)
freecamShiftLockButton.BackgroundTransparency = 1
freecamShiftLockButton.BorderSizePixel = 0
freecamShiftLockButton.AutoButtonColor = false
freecamShiftLockButton.Image = "rbxasset://textures/ui/mouseLock_on@2x.png"
freecamShiftLockButton.ScaleType = Enum.ScaleType.Fit
freecamShiftLockButton.Visible = false
freecamShiftLockButton.Active = true
freecamShiftLockButton.ZIndex = 2001
freecamShiftLockButton.Parent = StandaloneGui

freecamShiftLockButton.MouseButton1Click:Connect(function()
    toggleFreecamShiftLock()
end)

updateFreecamShiftLockButton()

-- Public standalone controller.
local Controller = {}

function Controller.Enable()
    return enableFreecam() == true
end

function Controller.Disable()
    disableFreecam()
    return false
end

function Controller.IsEnabled()
    return freecamEnabled == true
end

Controller.Changed = stateChangedEvent.Event

function Controller.SetSpeed(value)
    local n = tonumber(value)
    if not n then return FREECAM_SPEED end
    FREECAM_SPEED = math.clamp(n, FREECAM_SPEED_MIN, FREECAM_SPEED_MAX)
    if FreecamSpeedInput then
        FreecamSpeedInput.Text = tostring(math.floor(FREECAM_SPEED + 0.5))
    end
    return FREECAM_SPEED
end

return Controller
