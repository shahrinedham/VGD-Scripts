-- VGD Fly H18.5 / OP V262 — Fidget Action4 + Execute-Time Animation Preload
-- Protected behavior source: V255. No movement/animation behavior changes.
-- V229 baseline retained separately; Fly 2 integration is experimental.
-- Behavior baseline: H15. Stable Fly_Standalone.lua remains untouched.
-- V213: keep resumeAlpha in scope for the completion check; preserve the final resume frame.
-- H15.6 fidget handoff polish: preserve the live directional blend while
-- stopped, and make the interrupted-fidget -> Idle release slightly slower
-- so it matches the normal animation blend feel more closely.

-- V198 REGISTER-SAFE DEVELOPMENT: consolidated configuration
local FLY_CONFIG = {
    FLY2_STARTUP_ANIMATION_ID = "rbxassetid://79757971761739",
    FLY2_TORNADO_ANIMATION_ID = "rbxassetid://99288885472129",
    FLY2_TORNADO_SPEED = 1.5,
    FLY2_STARTUP_PLAY_SECONDS = 3.0,
    FLY2_TRANSITION_BLEND = 0.65,
    FLY2_TORNADO_RELEASE_AT = 0.90,
    FLY_DIRECTION_CONTINUOUS_BLEND_TIME = 0.45,
    FLY_DIRECTION_CONTINUOUS_IDLE_MAX = 0.30,
    -- H15.2: directional transitions remain responsive, while interrupted
    -- fidgets get a slightly longer handoff so distant poses never snap.
    FLY_DIRECTION_REDIRECT_RESPONSE = 0.18,
    -- H15.3: fidget exits no longer have a fixed mathematical deadline.
    -- This is the convergence response used to continuously reduce the
    -- outgoing fidget/Idle share until the handoff is perceptually complete.
    -- It replaces the old 1.45s hard cutoff while keeping a responsive early
    -- handoff.
    FLY_FIDGET_INTERRUPT_CONVERGENCE_RESPONSE = 0.55,
    FLY_FIDGET_INTERRUPT_WEIGHT_EPSILON = 0.001,
    -- H15.2/H15.3: direction changes while a fidget is still being released
    -- remain intentionally slower than normal joystick reversal so the incoming
    -- arm pose has time to redirect instead of snapping.
    FLY_FIDGET_DIRECTION_REDIRECT_RESPONSE = 0.32,
    FLY_IDLE_STABLE_THRESHOLD = 0.05,
    FLY_CAMERA_TOUCH_ROTATION_SPEED = Vector2.new(0.82, 0.54) * math.rad(1),
    FLY_CAMERA_MOUSE_ROTATION_SPEED = Vector2.new(1, 0.77) * math.rad(0.5),
    FLY_CAMERA_LOOK_SMOOTHNESS = 34,
    FLY_CAMERA_MOMENTUM_SMOOTHNESS = 8,
    FLY_CAMERA_MAX_LAG = 0.22,
    FLY_CAMERA_FOV_BASE = 70,
    FLY_CAMERA_FOV_MAX_BOOST = 7,
    FLY_CAMERA_MIN_PITCH = math.rad(-89),
    FLY_CAMERA_MAX_PITCH = math.rad(89),
    FLY_CAMERA_ZOOM_MIN = 0,
    FLY_CAMERA_ZOOM_MAX = 40,

    -- V198 animation/startup configuration (consolidated for register headroom).
    IDLE_ANIMATION_ID = "rbxassetid://106706162821039",
    MOVE_ANIMATION_ID = "rbxassetid://92749812489844",
    BACKWARD_ANIMATION_ID = "rbxassetid://75806320773060",
    FLY_STARTUP_ANIMATION_ID = "rbxassetid://112472797825991",
    FLY_STARTUP_POSE_BLEND_TIME = 0.60,
    FLY_STARTUP_POSE_HOLD_TIME = 0.30,
    FLY_STARTUP_CUT_TIME = 0.90,
    FLY_STARTUP_ASCEND_ANIMATION_ID = "rbxassetid://89651854762169",
    FLY_STARTUP_ASCEND_SOURCE_DURATION = 4.00,
    FLY_STARTUP_ASCEND_PLAY_DURATION = 0.60,
    FLY_STARTUP_ASCEND_BLEND_IN = 0.50,
    FLY_STARTUP_ASCEND_FADE_OUT = 0.60,
    FLY_STARTUP_LAUNCH_DELAY = 0.50,
    FLY_STARTUP_LAUNCH_DURATION = 0.60,
    FLY_STARTUP_ASSET_DURATION = 2.65,
}
-- Real-body flight controller for VGD.
-- Uses the same flight-pose concepts as VGD Freecam:
-- animation blending, forward/side lean, turning bank, speed pose,
-- flight pitch and subtle hover motion. The difference is that the
-- player's REAL character is animated and moved instead of a hologram.

local flyServices = {
    Players = game:GetService("Players"),
    RunService = game:GetService("RunService"),
    UserInputService = game:GetService("UserInputService"),
    ContextActionService = game:GetService("ContextActionService"),
    ContentProvider = game:GetService("ContentProvider"),
    GuiService = game:GetService("GuiService"),
    Player = nil,
}
flyServices.Player = flyServices.Players.LocalPlayer

-- V169 register-pressure fix: group camera state into one local table.
local flyState = {
    flyCameraVerticalOffset = 0,
    stateChangedEvent = nil,
}
local flyRuntime = {
    Enabled = false,
    Speed = 35,
    MinSpeed = 1,
    MaxSpeed = 1000,
    VerticalInput = 0,
    RenderConnection = nil,
    Saved = nil,
    Position = nil,
    AnimateScript = nil,
    AnimateScriptDisabled = false,
    Tracks = {},
    AnimationPreloadReady = false,
    AnimationPreloadError = nil,
    AnimationPreloadDeadline = os.clock() + 20,
    Fly2StartupPending = false,
    Fly2TornadoHandoffPending = false,
    NormalOrientationAttachment = nil,
    NormalOrientationAlign = nil,
    NormalOrientationTarget = CFrame.identity,
    NormalOrientationTargetEnabled = false,
    NormalVelocityAttachment = nil,
    NormalVelocityAlign = nil,
    NormalVelocityTarget = Vector3.zero,
    -- V250 telemetry state. Read-only diagnostics; does not steer motion.
}
local flyProfile = "Fly 1"
local flyGui = {
    GUI_CONTROLLED = false,
    ScreenGui = nil,
    ShiftLockButton = nil,
    ShiftLockOn = true,
    NoClipOn = true,
    MovementMode = "CFrame", -- V236: CFrame position backend or Normal physics backend; restored NoClip-compatible backend selection.
    CameraFeelOn = false,
}
local flyCollision = {
    SavedCanCollide = {},
    NoClipDescendantConnection = nil,
    Proxy = nil,
    ProxyParts = {},
    DebugOn = false,
    DebugFolder = nil,
    DebugParts = {},
    UpdateDebug = nil,
    GravityForce = nil,
}

-- Fly-owned camera state. This mirrors the Freecam camera architecture:
-- the Fly owns camera input, look smoothing, camera CFrame, and flight in
-- one render loop instead of reading Roblox CameraModule output and then
-- trying to push the real body back through it.
local flyCameraSaved = {}
local flyJoystick = {}
local flyStartup = {
    AnimationEnabled = true,
    Sequence = nil,
    PoseMap = nil,
    StartupJoints = {
        "Root",
        "Waist",
        "Neck",
        "LeftShoulder",
        "LeftElbow",
        "LeftWrist",
        "RightShoulder",
        "RightElbow",
        "RightWrist",
        "LeftHip",
        "LeftKnee",
        "LeftAnkle",
        "RightHip",
        "RightKnee",
        "RightAnkle",
    },
    PoseParts = {
        Root = {part = "LowerTorso", parent = "HumanoidRootPart"},
        Waist = {part = "UpperTorso", parent = "LowerTorso"},
        Neck = {part = "Head", parent = "UpperTorso"},
        LeftShoulder = {part = "LeftUpperArm", parent = "UpperTorso"},
        LeftElbow = {part = "LeftLowerArm", parent = "LeftUpperArm"},
        LeftWrist = {part = "LeftHand", parent = "LeftLowerArm"},
        RightShoulder = {part = "RightUpperArm", parent = "UpperTorso"},
        RightElbow = {part = "RightLowerArm", parent = "RightUpperArm"},
        RightWrist = {part = "RightHand", parent = "RightLowerArm"},
        LeftHip = {part = "LeftUpperLeg", parent = "LowerTorso"},
        LeftKnee = {part = "LeftLowerLeg", parent = "LeftUpperLeg"},
        LeftAnkle = {part = "LeftFoot", parent = "LeftLowerLeg"},
        RightHip = {part = "RightUpperLeg", parent = "LowerTorso"},
        RightKnee = {part = "RightLowerLeg", parent = "RightUpperLeg"},
        RightAnkle = {part = "RightFoot", parent = "RightLowerLeg"},
    },
}
local flyJointDiagnostic = {}

flyCameraSaved.Type = nil
flyCameraSaved.Subject = nil
flyCameraSaved.CFrame = nil
flyCameraSaved.FOV = nil
flyCameraSaved.MinZoom = nil
flyCameraSaved.MaxZoom = nil
local flyInput = {
    SpectatingOtherPlayer = false,
    CameraMouseLooking = false,
    CameraConnections = {},
    CameraLastMoveVector = Vector3.zero,
    MoveControls = nil,
    JoystickConnections = {},
}
flyState.flyCameraYaw = 0
flyState.flyCameraPitch = 0
flyState.flyCameraTargetYaw = 0
flyState.flyCameraTargetPitch = 0
flyState.flyCameraZoomDistance = 8
flyState.flyCameraTargetZoomDistance = 8
flyState.flyCameraOffset = Vector3.zero
flyState.flyCameraTouchStates = {}
flyState.flyCameraZoomTouchPositions = {}
flyState.flyCameraPinchLastDiameter = nil
flyState.flyCameraTouchDelta = Vector2.new()
flyState.flyCameraMouseDelta = Vector2.new()

-- v57 camera/flight-feel state. These are visual-only layers; they do not
-- replace the proven v56 movement/camera ownership architecture.
flyState.flyCameraVelocityBlend = Vector3.zero
flyState.flyCameraTurnLag = 0
flyState.flyCameraFOVBlend = 0
flyState.flyCameraLastYaw = nil

flyState.flyAccelerationBlend = 0
flyState.flyDecelerationBlend = 0
flyState.flyDirectionChangeBlend = 0
flyState.flyPreviousMoveDirection = Vector3.zero
flyState.flyPreviousSpeed = 0

-- Read the same PlayerModule movement vector that Roblox mobile/keyboard
-- controls use. This keeps the joystick alive when Fly switches Humanoid
-- into PlatformStand, instead of relying only on Humanoid.MoveDirection.

-- Mobile joystick continuity. Roblox's PlatformStand state prevents the
-- Humanoid from moving, and community testing/source inspection shows the
-- default movement controller can therefore return zero even while the
-- physical thumbstick is still held. We keep a small independent copy of the
-- thumbstick state so Fly can consume the same input without asking the
-- Humanoid to walk.
flyJoystick.Touch = nil
flyJoystick.StartPosition = nil
flyJoystick.Vector = Vector3.zero
flyJoystick.ReleasedSinceLastStart = false

local function getDynamicThumbstickFrame()
    local playerGui = flyServices.Player:FindFirstChildOfClass("PlayerGui")
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
    flyJoystick.Touch = nil
    flyJoystick.StartPosition = nil
    flyJoystick.Vector = Vector3.zero
end

local function disconnectFlyJoystickTracking()
    for _, connection in pairs(flyInput.JoystickConnections) do
        pcall(function() connection:Disconnect() end)
    end
    table.clear(flyInput.JoystickConnections)
    clearFlyJoystick()
end

local function connectFlyJoystickTracking()
    disconnectFlyJoystickTracking()

    if not flyServices.UserInputService.TouchEnabled then
        return
    end

    flyInput.JoystickConnections.TouchStarted = flyServices.UserInputService.TouchStarted:Connect(function(inputObject)
        local frame = getDynamicThumbstickFrame()
        if not frame or not pointInsideGui(frame, inputObject.Position) then
            return
        end

        -- Do not steal the camera's touch if Roblox has already assigned a
        -- different thumbstick touch. The dynamic thumbstick's StartImage is
        -- the stronger signal for an already-active joystick.
        if flyJoystick.Touch then
            return
        end

        flyJoystick.ReleasedSinceLastStart = false
        flyJoystick.Touch = inputObject
        flyJoystick.StartPosition = Vector2.new(
            inputObject.Position.X,
            inputObject.Position.Y
        )
        flyJoystick.Vector = computeJoystickVector(
            flyJoystick.StartPosition,
            flyJoystick.StartPosition
        )
    end)

    flyInput.JoystickConnections.TouchMoved = flyServices.UserInputService.TouchMoved:Connect(function(inputObject)
        local position = Vector2.new(inputObject.Position.X, inputObject.Position.Y)

        if flyJoystick.Touch == inputObject then
            flyJoystick.Vector = computeJoystickVector(
                flyJoystick.StartPosition,
                position
            )
            return
        end

        if flyJoystick.Touch then
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
                flyJoystick.Touch = inputObject
                flyJoystick.StartPosition = startCenter
                flyJoystick.Vector = computeJoystickVector(
                    flyJoystick.StartPosition,
                    position
                )
            end
        end
    end)

    flyInput.JoystickConnections.TouchEnded = flyServices.UserInputService.TouchEnded:Connect(function(inputObject)
        local frame = getDynamicThumbstickFrame()
        local endedInsideThumbstick = frame and pointInsideGui(frame, inputObject.Position)

        if flyJoystick.Touch == inputObject then
            flyJoystick.ReleasedSinceLastStart = true
            clearFlyJoystick()
            return
        end

        -- If Fly was enabled while the joystick finger was already held, we
        -- may never have obtained the InputObject identity. Use Roblox's
        -- ThumbstickEnd visual as the release-side fallback so the latched
        -- movement is cleared instead of continuing forever.
        if flyJoystick.Vector.Magnitude > 0.001 then
            local endImage = frame and frame:FindFirstChild("ThumbstickEnd")
            local position = Vector2.new(inputObject.Position.X, inputObject.Position.Y)
            if frame and endImage and endImage.Visible
                and pointInsideGui(frame, position) then
                local endCenter = endImage.AbsolutePosition + endImage.AbsoluteSize * 0.5
                if (position - endCenter).Magnitude <= 40 then
                    flyJoystick.ReleasedSinceLastStart = true
                    clearFlyJoystick()
                end
            end
        elseif endedInsideThumbstick then
            -- The joystick may have been released before our tracker could
            -- identify the original InputObject. Remember that release so the
            -- disable path cannot mistake stale ThumbstickStart/End visuals
            -- for a currently held joystick.
            flyJoystick.ReleasedSinceLastStart = true
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
        local playerScripts = flyServices.Player:FindFirstChildOfClass("PlayerScripts")
        local playerModule = playerScripts and playerScripts:FindFirstChild("PlayerModule")
        if not playerModule then return end
        local module = require(playerModule)
        if module and module.GetControls then
            controls = module:GetControls()
        end
    end)
    return controls
end

-- Best-effort access to Roblox's live CameraModule controller.
-- Current Roblox builds intentionally hide GetCameras() behind an API flag,
-- so this may return nil. When it is available, setting the controller's
-- nominal subject distance directly is the only way to seed the same internal
-- value that Custom camera uses without relying on the visible zoom-limit hack.
local function getRobloxCameraController()
    local controller = nil
    pcall(function()
        local playerScripts = flyServices.Player:FindFirstChildOfClass("PlayerScripts")
        local playerModule = playerScripts and playerScripts:FindFirstChild("PlayerModule")
        if not playerModule then return end
        local module = require(playerModule)
        if not module or not module.GetCameras then return end
        local cameras = module:GetCameras()
        if type(cameras) == "table" then
            controller = cameras.activeCameraController
                or cameras.ActiveCameraController
        end
    end)
    return controller
end

local function seedRobloxCameraZoom(distance)
    if not distance then return false end
    local controller = getRobloxCameraController()
    if not controller then return false end

    local ok = pcall(function()
        controller:SetCameraToSubjectDistance(distance)
    end)
    return ok
end

-- v97: seed Roblox CameraModule's live orientation state with the
-- FINAL Fly camera before returning CameraType=Custom. Simply assigning
-- Camera.CFrame is not enough because CameraModule keeps its own previous
-- transform/subject state between render updates.
local function syncRobloxCameraOrientation(finalCFrame, humanoid)
    if not finalCFrame then return false end

    local controller = getRobloxCameraController()
    if not controller then return false end

    local subjectPosition = nil
    local root = humanoid and humanoid.RootPart
    if humanoid and root then
        subjectPosition = getRobloxCameraSubjectPosition(humanoid, root)
    end

    local ok = pcall(function()
        controller.lastCameraTransform = finalCFrame
        controller.lastCameraFocus = subjectPosition
            and CFrame.new(subjectPosition)
            or finalCFrame
        controller.lastSubject = humanoid

        if subjectPosition then
            controller.lastSubjectPosition = subjectPosition
            controller.lastSubjectCFrame = root
                and root.CFrame
                or CFrame.new(subjectPosition)
        end

        if controller.rotateInput ~= nil then
            controller.rotateInput = Vector2.zero
        end
    end)

    return ok
end

local function getFlyMoveVector(humanoid)
    if not flyInput.MoveControls then
        flyInput.MoveControls = getFlyMoveControls()
    end

    if flyInput.MoveControls then
        -- PlayerModule:GetMoveVector() is INPUT SPACE, not world space:
        -- forward is -Z and right is +X. Keep that raw vector intact so the
        -- render loop can convert it to the current Fly camera basis exactly
        -- once. The previous v36 code fed this raw vector into the old
        -- Humanoid.MoveDirection world-space dot-product conversion, which
        -- inverted left/right and forward/backward.
        pcall(function() flyInput.MoveControls:Enable() end)
        local ok, value = pcall(function()
            return flyInput.MoveControls:GetMoveVector()
        end)
        if ok and typeof(value) == "Vector3" then
            if value.Magnitude > 0.001 then
                flyJoystick.Vector = value
                return value, true
            end

            -- ControlModule can report zero after PlatformStand. If the
            -- independent thumbstick tracker still sees the finger held, use
            -- that input instead of allowing the Fly to stop.
            if flyJoystick.Vector.Magnitude > 0.001 then
                return flyJoystick.Vector, true
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

-- v57 subtle cinematic camera response. Kept deliberately restrained so
-- camera control remains as responsive as v56.

-- The HumanoidRootPart is around the character's torso/pivot. Aim the
-- camera slightly below that pivot so the visible body sits a little higher
-- in the viewport instead of appearing low.
-- Raise the camera's subject point so the camera itself sits higher
-- relative to the HumanoidRootPart. This brings the visible character
-- DOWN toward the normal Roblox camera framing instead of leaving it high.
-- Preserve the normal Roblox camera's vertical relationship to the real
-- character instead of using an arbitrary fixed Y offset.
flyState.flyCameraVerticalOffset = 0

flyState.stateChangedEvent = Instance.new("BindableEvent")

flyGui.GUI_CONTROLLED = _G.VGD_Fly_GUIControlled == true


-- V198: delayed Fly Idle fidget variations with exact-pose interruption handoff and live direction redirection.
-- H15.3 replaces the interrupted-fidget hard deadline with continuous convergence;
-- ordinary Forward <-> Backward and joystick reversal timing remains unchanged.
-- Keep all fidget configuration/state in one table so this near-register-limit
-- script does not consume extra top-level local registers.
-- Fidget #1 uses the tested middle 5.000s of its 7.700s source.
-- Fidget #2 uses source 0.958–7.458s (6.500s effective) and deliberately fades back to Fly Idle
-- over the final 1.000s so its ending pose can differ slightly without snapping.
-- Fidget #3 uses its full 10.000s source with a 0.700s blend-in and 0.800s blend-out.
-- Fidget #4 uses its full 8.400s source; Fidget #5 uses the trimmed 8.900s segment.
-- Fidget #4 uses its full 8.400s source with a 0.700s blend-in and 0.800s blend-out.
-- Fidget #5 uses 0.067s -> 8.967s of its 9.967s source (8.900s total), with 0.700s blend-in and 0.800s blend-out.
local flyIdleFidget = {
    triggerDelay = 10.0,
    variants = {
        {
            animationId = "rbxassetid://123898554153621",
            sourceStart = 1.35,
            sourceEnd = 6.35,
            duration = 5.0,
            blendIn = 0.70,
            blendOut = 1.00,
            trackKey = "fidget1",
        },
        {
            animationId = "rbxassetid://83731054297898",
            sourceStart = 0.958,
            sourceEnd = 7.458,
            duration = 6.500,
            blendIn = 0.50,
            blendOut = 1.00,
            trackKey = "fidget2",
        },
        {
            animationId = "rbxassetid://86083258777928",
            sourceStart = 0.0,
            sourceEnd = 10.0,
            duration = 10.0,
            blendIn = 0.70,
            blendOut = 0.80,
            trackKey = "fidget3",
        },
        {
            animationId = "rbxassetid://110641029791216",
            sourceStart = 0.0,
            sourceEnd = 8.4,
            duration = 8.4,
            blendIn = 0.70,
            blendOut = 0.80,
            trackKey = "fidget4",
        },
        {
            animationId = "rbxassetid://81948954697233",
            sourceStart = 0.067,
            sourceEnd = 8.967,
            duration = 8.9,
            blendIn = 0.70,
            blendOut = 0.80,
            trackKey = "fidget5",
        },
    },
    idleTime = 0,
    active = false,
    elapsed = 0,
    activeVariant = 1,
    lastVariant = 0,
    interrupting = false,
    interruptElapsed = 0,
    interruptDuration = 0,
    interruptT = 0,
    interruptSmoothT = 0,
    interruptRemaining = 0,
    interruptStartFidgetWeight = 0,
    interruptStartIdleWeight = 1,
    interruptMoveWeight = 0,
    interruptBackwardWeight = 0,
    interruptDirectionBlend = 1,
    interruptStopElapsed = 0,
    interruptResumeElapsed = 0,
    interruptResumeStartIdleWeight = 0,
    interruptResumeStartMoveWeight = 0,
    interruptResumeStartBackwardWeight = 0,
    interruptResumingFromIdle = false,
    currentWeight = 0,
    diagnosticElapsed = 0,
}


-- V262: preload every Fly animation asset as soon as the script executes.
-- Track creation still uses the current character's Animator when Fly is enabled;
-- this warms the asset cache before the first startup/idle/fidget transition.
task.spawn(function()
    local animations = {}
    local seen = {}
    local animationIds = {
        FLY_CONFIG.FLY2_STARTUP_ANIMATION_ID,
        FLY_CONFIG.FLY2_TORNADO_ANIMATION_ID,
        FLY_CONFIG.IDLE_ANIMATION_ID,
        FLY_CONFIG.MOVE_ANIMATION_ID,
        FLY_CONFIG.BACKWARD_ANIMATION_ID,
        FLY_CONFIG.FLY_STARTUP_ANIMATION_ID,
        FLY_CONFIG.FLY_STARTUP_ASCEND_ANIMATION_ID,
    }

    for _, variant in ipairs(flyIdleFidget.variants) do
        table.insert(animationIds, variant.animationId)
    end

    for _, animationId in ipairs(animationIds) do
        if type(animationId) == "string" and animationId ~= "" and not seen[animationId] then
            seen[animationId] = true
            local animation = Instance.new("Animation")
            animation.Name = "VGD_Fly_V262_Preload"
            animation.AnimationId = animationId
            table.insert(animations, animation)
        end
    end

    local ok, preloadError = pcall(function()
        flyServices.ContentProvider:PreloadAsync(animations)
    end)

    for _, animation in ipairs(animations) do
        pcall(function() animation:Destroy() end)
    end

    if not ok then
        flyRuntime.AnimationPreloadError = tostring(preloadError)
    end
    flyRuntime.AnimationPreloadReady = true
end)

-- V178: Startup ON uses the new dedicated takeoff animation normally.
-- The animation begins in the desired landing/crouch pose, so there is no
-- reverse playback. Startup blends into frame 0, then releases the animation
-- immediately into the takeoff and Fly Idle handoff.
-- Runtime finder confirmed this animation as ID 112472797825991 with a length
-- of approximately 2.650 seconds.

-- V181 Startup ON timing: blend into the landing/crouch pose for 0.60s,
-- then start the asset immediately with no extra pose hold. The physical
-- root lift waits 0.30s into the asset so the animation can leave the crouch
-- before the character itself starts rising.

-- V183: use only the FIRST 4.000 seconds of the dedicated ascend animation.
-- The source asset is 7.000 seconds long, but only the first 4.000 seconds
-- are intentionally included. Compress the first 4.000 seconds into 0.60 seconds,
-- giving approximately a 6.67x playback speed.
-- V169: user-facing master switch. The GUI can turn startup on/off without
-- changing any of the existing Fly camera, movement, joystick, or idle logic.

-- V198: corrected interruption handoff; preserve the live fidget pose and smoothly redirect the incoming movement direction.
-- An interrupted fidget crossfades directly into the live Forward/Backward
-- direction over the fidget's configured blend-out window.
-- V196: V195 baseline plus fidget blend tuning.
-- After 10 seconds of true Fly Idle, the five fidgets cycle in order. Fidget #1 keeps
-- the tested 1.350s -> 6.350s window with a 0.700s blend-in and 1.000s blend-out;
-- Fidget #2 uses its full 7.458s source with a 0.350s blend-in and 1.000s blend-out;
-- Fidget #3 uses its full 10.000s source with a 0.700s blend-in and 0.800s blend-out.
-- Fidget #4 uses its full 8.400s source; Fidget #5 uses the trimmed 8.900s segment.
-- V191 startup synchronization and V190.12 reversal behavior are preserved.
-- V191: V190.12 functional baseline plus synchronized startup crossfade and V190-like response curve for
-- Forward <-> Backward reversal feel. State handling and no-snap logic remain unchanged.
-- The Fly Idle track is used only as a temporary pose cushion while the
-- outgoing and incoming direction tracks remain continuously crossfaded.
-- Unlike the earlier neutral-bridge tests, Idle never becomes the visible
-- standalone state, so there is no stop/pause between directions.

-- V190.9 diagnostic: remember the actual requested animation state, not just
-- whichever directional track still has the larger weight. This prevents a
-- stopped Forward/Backward track from being mistaken for the active direction
-- when the player starts moving again in the opposite direction.
-- Require a tiny real Idle dwell before treating the next movement as a
-- fresh Idle -> Direction transition. This filters a one-frame mobile input
-- deadzone/flicker so a genuine reversal cannot accidentally bypass the blend.

-- v121: true R15 pose/keyframe player.
--
-- Research-backed approach:
-- V151 now prefers a real Roblox Animation asset for the startup. The
-- procedural Pose.CFrame player remains only as a fallback while the asset
-- is being authored/published.
--
-- During startup the character's Animate script is already disabled by
-- saveCharacterState(), all Animator tracks are stopped, and this player
-- writes EVERY R15 joint in PreSimulation. That gives the startup complete
-- ownership of the rig instead of layering a few limb rotations over the
-- player's current pose.
local bankingState = {
    RightBlend = 0,
    FlightBankBlend = 0,
    FlightTurnRateBlend = 0,
    PreviousDesiredYaw = nil,
}

local animState = {
    forwardBlend = 0,
    flightPitchBlend = 0,
    speedBlend = 0,
    previousDesiredYaw = nil,
    currentMoveVector = Vector3.zero,
    hoverBlend = 0,
    flyAnimState = "Idle",
    flyDirectionTransitionActive = false,
    flyDirectionTransitionFrom = nil,
    flyDirectionTransitionTo = nil,
    flyDirectionTransitionTime = 0,
    flyPreviousDesiredState = "Idle",
    flyLastDirectionalState = nil,
    flyIdleStableTime = 0,
}

flyStartup.Active = false
flyStartup.Time = 0
flyStartup.Duration = FLY_CONFIG.FLY_STARTUP_POSE_BLEND_TIME + FLY_CONFIG.FLY_STARTUP_POSE_HOLD_TIME + FLY_CONFIG.FLY_STARTUP_ASSET_DURATION
flyStartup.Height = 4.15
flyStartup.StartPosition = nil
flyStartup.PoseJoints = nil
flyStartup.JointBases = nil
flyStartup.PreSimulationConnection = nil
flyStartup.SuppressedTracks = {}

-- V169 existing-emote AnimationTrack startup path.
flyStartup.AnimationTrack = nil
flyStartup.AnimationStoppedConnection = nil
flyStartup.AnimationMonitorConnection = nil
flyStartup.AnimationReady = false
flyStartup.AssetActive = false
flyStartup.LaunchActive = false
flyStartup.LaunchTime = 0
flyStartup.AscendTrack = nil
flyStartup.AscendStoppedConnection = nil
flyStartup.FinalBlendActive = false
flyStartup.FinalBlendTime = 0

-- V126 controlled joint diagnostic. This deliberately runs BEFORE the
-- procedural startup animation so we can prove that the live avatar rig
-- accepts PreSimulation Transform writes without changing camera/movement.
flyJointDiagnostic.Active = false
flyJointDiagnostic.Time = 0
flyJointDiagnostic.Duration = 1.8
flyJointDiagnostic.Joint = nil
flyJointDiagnostic.Class = "None"
flyJointDiagnostic.BodyPart = "RightUpperArm"

local function findJointForBodyPart(character, bodyPartName)
    if not character or not bodyPartName then return nil, "None" end

    -- Standard Motor6D R15: Part1 is the child body part controlled by
    -- this joint.
    for _, instance in ipairs(character:GetDescendants()) do
        if instance:IsA("Motor6D") then
            local part1 = instance.Part1
            if part1 and part1.Name == bodyPartName then
                return instance, "Motor6D"
            end
        end
    end

    -- Avatar Joint Upgrade / AnimationConstraint R15: Attachment1.Parent is
    -- the child body part controlled by this constraint.
    for _, instance in ipairs(character:GetDescendants()) do
        if instance:IsA("AnimationConstraint") then
            local attachment1 = instance.Attachment1
            local parentPart = attachment1 and attachment1.Parent
            if parentPart and parentPart.Name == bodyPartName then
                return instance, "AnimationConstraint"
            end
        end
    end

    -- Fallback for rigs that retain the classic joint name.
    local fallback = character:FindFirstChild("RightShoulder", true)
    if fallback and (fallback:IsA("Motor6D") or fallback:IsA("AnimationConstraint")) then
        return fallback, fallback.ClassName
    end

    return nil, "None"
end

local function beginFlyJointDiagnostic(character)
    flyJointDiagnostic.Active = true
    flyJointDiagnostic.Time = 0
    flyJointDiagnostic.Joint, flyJointDiagnostic.Class =
        findJointForBodyPart(character, flyJointDiagnostic.BodyPart)

end

local function stopFlyJointDiagnostic()
    flyJointDiagnostic.Active = false
    flyJointDiagnostic.Time = 0

    if flyStartup.PoseJoints then
        for _, joint in pairs(flyStartup.PoseJoints) do
            if joint and joint.Parent then
                pcall(function() joint.Transform = CFrame.identity end)
            end
        end
    end
end

local function updateFlyJointDiagnostic(dt)
    if not flyJointDiagnostic.Active then return false end

    flyJointDiagnostic.Time += math.max(dt or 0, 0)

    -- Reset every cached joint so the diagnostic cannot accidentally inherit
    -- a player animation pose. Only the selected shoulder receives motion.
    if flyStartup.PoseJoints then
        for _, joint in pairs(flyStartup.PoseJoints) do
            if joint and joint.Parent then
                pcall(function() joint.Transform = CFrame.identity end)
            end
        end
    end

    local joint = flyJointDiagnostic.Joint
    if joint and joint.Parent then
        local t = flyJointDiagnostic.Time
        local phase = math.floor(t / 0.6) % 3
        local angle = math.rad(90)
        local transform

        if phase == 0 then
            transform = CFrame.Angles(0, 0, angle)
        elseif phase == 1 then
            transform = CFrame.Angles(angle, 0, 0)
        else
            transform = CFrame.Angles(0, angle, 0)
        end

        pcall(function() joint.Transform = transform end)
    end

    return flyJointDiagnostic.Time < flyJointDiagnostic.Duration
end


local function suppressStartupAnimatorTracks(humanoid)
    if not humanoid then return end

    local animator = humanoid:FindFirstChildOfClass("Animator")
    if not animator then return end

    for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
        if track and track.IsPlaying then
            flyStartup.SuppressedTracks[track] = true
            pcall(function()
                track:AdjustWeight(0, 0)
                track:Stop(0)
            end)
        end
    end
end

local function maintainStartupAnimatorSuppression(humanoid)
    if not humanoid then return end

    local animator = humanoid:FindFirstChildOfClass("Animator")
    if not animator then return end

    for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
        pcall(function()
            track:AdjustWeight(0, 0)
            track:Stop(0)
        end)
    end
end

local function clearStartupAnimatorSuppression()
    table.clear(flyStartup.SuppressedTracks)
end

local function cacheFlyStartupJoints(character)
    flyStartup.PoseJoints = {}
    flyStartup.JointBases = {}

    -- IMPORTANT: Roblox animation Pose channels are named after BODY PARTS,
    -- not after Motor6D objects. The corresponding joint is the Motor6D /
    -- AnimationConstraint connecting that body part to its parent.
    --
    -- Previous versions found joints by their joint names ("LeftHip",
    -- "LeftKnee", etc.) and then attempted to convert the authored pose
    -- through C0.Rotation. That was not equivalent to Roblox's animation
    -- system and was the main reason the crouch could look like a torso bend.
    for _, channelName in ipairs(flyStartup.StartupJoints) do
        local info = flyStartup.PoseParts[channelName]
        local joint = info and findJointForBodyPart(character, info.part)

        if joint then
            flyStartup.PoseJoints[channelName] = joint

            -- Pose.CFrame is already the animation Transform. Do NOT convert
            -- it through C0.Rotation. Roblox applies the Pose CFrame directly
            -- to the corresponding joint's Transform.
            flyStartup.JointBases[channelName] = nil

            pcall(function()
                joint.Transform = CFrame.identity
            end)
        end
    end
end

local function setStartupTransform(name, transform)
    local joint = flyStartup.PoseJoints and flyStartup.PoseJoints[name]
    if not joint or not joint.Parent then return end

    -- V150: direct Pose.CFrame -> Transform mapping.
    -- This matches Roblox's documented animation path and removes the custom
    -- basis conversion that was distorting the authored R15 axes.
    pcall(function()
        joint.Transform = transform
    end)
end

local function clearFlyStartupPose()
    if flyStartup.PoseJoints then
        for _, joint in pairs(flyStartup.PoseJoints) do
            if joint and joint.Parent then
                pcall(function()
                    joint.Transform = CFrame.identity
                end)
            end
        end
    end

    flyStartup.PoseJoints = nil
    flyStartup.JointBases = nil
    clearStartupAnimatorSuppression()
end

local function d(x, y, z)
    return CFrame.Angles(
        math.rad(x or 0),
        math.rad(y or 0),
        math.rad(z or 0)
    )
end

local function pose(...)
    return {...}
end

-- These are deliberately authored as FULL R15 poses rather than target
-- positions. Each keyframe specifies the visible relationship of the whole
-- body. Missing joints are never left with a previous keyframe's value.
--
-- R15 animation convention:
--   Root       -> HumanoidRootPart -> LowerTorso
--   Waist      -> LowerTorso -> UpperTorso
--   Neck       -> UpperTorso -> Head
-- and the remaining entries correspond to their named R15 joints.
--
-- The airborne pose is asymmetric: one arm leads, the other trails, and the
-- legs are staggered. This creates a readable superhero-flight silhouette.
-- V126: runtime KeyframeSequence-style R15 player.
--
-- Research-backed change: Roblox KeyframeSequence animation data is a
-- hierarchy of Keyframes -> Pose objects. Pose.CFrame is the value that is
-- ultimately applied to the corresponding Motor6D.Transform. For a normal
-- R15 rig the Pose hierarchy is based on the connected BaseParts, not the
-- Motor6D names. Because a locally-created KeyframeSequence cannot simply be
-- played through Animator without an uploaded Animation asset, V126 builds
-- that exact hierarchy in memory and runs the timeline locally. This mirrors
-- the open-source runtime KeyframeSequence players while retaining complete
-- client-side control of the startup.
--
-- Sources used while rebuilding this layer:
-- Roblox Keyframe documentation: Keyframes contain Pose hierarchies and Pose
-- CFrames are interpolated over time.
-- Roblox KeyframeSequence documentation: KeyframeSequence can be instantiated
-- in code and contains Keyframes.
-- DevForum runtime KeyframeSequence player examples: read the sequence,
-- interpolate Pose.CFrame values, and apply them to Motor6D.Transform.



local function suppressStartupAnimatorTracks(humanoid)
    if not humanoid then return end

    local animator = humanoid:FindFirstChildOfClass("Animator")
    if not animator then return end

    for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
        if track and track.IsPlaying then
            flyStartup.SuppressedTracks[track] = true
            pcall(function()
                track:AdjustWeight(0, 0)
                track:Stop(0)
            end)
        end
    end
end

local function maintainStartupAnimatorSuppression(humanoid)
    if not humanoid then return end

    local animator = humanoid:FindFirstChildOfClass("Animator")
    if not animator then return end

    for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
        pcall(function()
            track:AdjustWeight(0, 0)
            track:Stop(0)
        end)
    end
end

local function clearStartupAnimatorSuppression()
    table.clear(flyStartup.SuppressedTracks)
end

local function cacheFlyStartupJoints(character)
    flyStartup.PoseJoints = {}
    flyStartup.JointBases = {}

    -- V150 IMPORTANT:
    -- This is the ACTIVE definition (Lua uses the last function definition).
    -- Resolve each animation channel by the R15 BODY PART it controls, exactly
    -- like Roblox Pose -> Motor6D.Transform animation mapping. Do not resolve
    -- by Motor6D object name and do not apply a C0.Rotation basis conversion.
    for _, channelName in ipairs(flyStartup.StartupJoints) do
        local info = flyStartup.PoseParts[channelName]
        local joint = info and findJointForBodyPart(character, info.part)

        if joint then
            flyStartup.PoseJoints[channelName] = joint
            flyStartup.JointBases[channelName] = nil

            pcall(function()
                joint.Transform = CFrame.identity
            end)
        end
    end
end

local function setStartupTransform(name, transform)
    local joint = flyStartup.PoseJoints and flyStartup.PoseJoints[name]
    if not joint or not joint.Parent then return end

    -- V150: Pose.CFrame is written directly to the resolved joint Transform.
    pcall(function()
        joint.Transform = transform
    end)
end

local function clearFlyStartupPose()
    if flyStartup.PoseJoints then
        for _, joint in pairs(flyStartup.PoseJoints) do
            if joint and joint.Parent then
                pcall(function()
                    joint.Transform = CFrame.identity
                end)
            end
        end
    end

    flyStartup.PoseJoints = nil
    flyStartup.Sequence = nil
    flyStartup.PoseMap = nil
    clearStartupAnimatorSuppression()
end

local function d(x, y, z)
    return CFrame.Angles(
        math.rad(x or 0),
        math.rad(y or 0),
        math.rad(z or 0)
    )
end

local function pose(...)
    return {...}
end

-- V151 fallback R15 startup choreography.
--
-- Deep-research / runtime-mapping correction:
-- V147 now has a real lower-body bend, but in the actual camera view the
-- crouch still reads as a small dip rather than a deliberate superhero
-- preparation. V148 makes the crouch visually unambiguous by:
--   * keeping the chest/waist almost neutral
--   * dropping the entire body farther
--   * using a stronger knee fold
--   * keeping the crouch for a longer readable beat
--   * delaying the arm/torso launch pose until AFTER the squat is complete
--
-- Both arms remain at the sides.
-- V151 keeps the corrected procedural path as a fallback while the real Animation asset is used as the primary path:
-- Pose.CFrame is written directly to the joint Transform in PreSimulation,
-- with each channel resolved from its corresponding R15 body part. This is
-- the documented Roblox animation path. The crouch values below are therefore
-- now interpreted in the same local joint space as an actual R15 animation.
local STARTUP_POSES = {
    -- HYBRID V169 PREVIEW TIMELINE
    -- This is the same choreography we intend to author as the final Roblox
    -- Animation asset later. The procedural path remains only as a mobile-
    -- testable preview; the published AnimationId will become the primary path.
    {
        time = 0.00,
        pose = pose(
            {"Root", CFrame.identity}, {"Waist", CFrame.identity}, {"Neck", CFrame.identity},
            {"LeftShoulder", d(0,0,-2)}, {"LeftElbow", d(0,0,-2)}, {"LeftWrist", CFrame.identity},
            {"RightShoulder", d(0,0,2)}, {"RightElbow", d(0,0,2)}, {"RightWrist", CFrame.identity},
            {"LeftHip", d(0,0,-1)}, {"LeftKnee", d(0,0,1)}, {"LeftAnkle", CFrame.identity},
            {"RightHip", d(0,0,1)}, {"RightKnee", d(0,0,-1)}, {"RightAnkle", CFrame.identity}
        ),
    },

    -- 0.14s: anticipation begins. Keep chest almost neutral.
    {
        time = 0.14,
        pose = pose(
            {"Root", d(-2,0,0)}, {"Waist", d(-1,0,0)}, {"Neck", d(1,0,0)},
            {"LeftShoulder", d(-2,0,-3)}, {"LeftElbow", d(7,0,-2)}, {"LeftWrist", d(2,0,0)},
            {"RightShoulder", d(-2,0,3)}, {"RightElbow", d(7,0,2)}, {"RightWrist", d(2,0,0)},
            {"LeftHip", d(-4,0,-2)}, {"LeftKnee", d(58,0,0)}, {"LeftAnkle", d(-20,0,-2)},
            {"RightHip", d(-4,0,2)}, {"RightKnee", d(58,0,0)}, {"RightAnkle", d(-20,0,2)}
        ),
    },

    -- 0.28s: deep crouch. This is deliberately held as a readable silhouette.
    {
        time = 0.28,
        pose = pose(
            {"Root", d(-3,0,0)}, {"Waist", d(-2,0,0)}, {"Neck", d(1,0,0)},
            {"LeftShoulder", d(-3,0,-4)}, {"LeftElbow", d(10,0,-2)}, {"LeftWrist", d(3,0,0)},
            {"RightShoulder", d(-3,0,4)}, {"RightElbow", d(10,0,2)}, {"RightWrist", d(3,0,0)},
            {"LeftHip", d(-26,0,-3)}, {"LeftKnee", d(124,0,0)}, {"LeftAnkle", d(-38,0,-3)},
            {"RightHip", d(-26,0,3)}, {"RightKnee", d(124,0,0)}, {"RightAnkle", d(-38,0,3)}
        ),
    },

    -- 0.40s: anticipation hold. Root trajectory supplies the extra visual drop.
    {
        time = 0.40,
        pose = pose(
            {"Root", d(-3,0,0)}, {"Waist", d(-2,0,0)}, {"Neck", d(1,0,0)},
            {"LeftShoulder", d(-3,0,-4)}, {"LeftElbow", d(10,0,-2)}, {"LeftWrist", d(3,0,0)},
            {"RightShoulder", d(-3,0,4)}, {"RightElbow", d(10,0,2)}, {"RightWrist", d(3,0,0)},
            {"LeftHip", d(-26,0,-3)}, {"LeftKnee", d(124,0,0)}, {"LeftAnkle", d(-38,0,-3)},
            {"RightHip", d(-26,0,3)}, {"RightKnee", d(124,0,0)}, {"RightAnkle", d(-38,0,3)}
        ),
    },

    -- 0.46s: explosive extension. Arms remain beside the torso.
    {
        time = 0.46,
        pose = pose(
            {"Root", d(4,0,0)}, {"Waist", d(3,0,0)}, {"Neck", d(-1,0,0)},
            {"LeftShoulder", d(-8,-1,-10)}, {"LeftElbow", d(22,-1,-2)}, {"LeftWrist", d(5,0,0)},
            {"RightShoulder", d(-8,1,10)}, {"RightElbow", d(22,1,2)}, {"RightWrist", d(5,0,0)},
            {"LeftHip", d(-8,-1,-2)}, {"LeftKnee", d(30,0,0)}, {"LeftAnkle", d(-10,0,-2)},
            {"RightHip", d(-8,1,2)}, {"RightKnee", d(30,0,0)}, {"RightAnkle", d(-10,0,2)}
        ),
    },

    -- 0.56s: feet leaving the ground.
    {
        time = 0.56,
        pose = pose(
            {"Root", d(-6,-1,0)}, {"Waist", d(-3,-1,0)}, {"Neck", d(2,0,0)},
            {"LeftShoulder", d(-15,-2,-16)}, {"LeftElbow", d(35,-1,-2)}, {"LeftWrist", d(7,0,0)},
            {"RightShoulder", d(-15,2,16)}, {"RightElbow", d(35,1,2)}, {"RightWrist", d(7,0,0)},
            {"LeftHip", d(10,-2,-2)}, {"LeftKnee", d(5,0,0)}, {"LeftAnkle", d(-2,0,-2)},
            {"RightHip", d(10,2,2)}, {"RightKnee", d(5,0,0)}, {"RightAnkle", d(-2,0,2)}
        ),
    },

    -- 0.72s: airborne superhero silhouette.
    {
        time = 0.72,
        pose = pose(
            {"Root", d(-10,0,-4)}, {"Waist", d(-6,0,-2)}, {"Neck", d(3,0,1)},
            {"LeftShoulder", d(-14,-2,-15)}, {"LeftElbow", d(32,-1,-2)}, {"LeftWrist", d(7,0,0)},
            {"RightShoulder", d(-14,2,15)}, {"RightElbow", d(32,1,2)}, {"RightWrist", d(7,0,0)},
            {"LeftHip", d(8,-2,-2)}, {"LeftKnee", d(0,0,0)}, {"LeftAnkle", d(1,0,-1)},
            {"RightHip", d(8,2,2)}, {"RightKnee", d(0,0,0)}, {"RightAnkle", d(1,0,1)}
        ),
    },

    -- 0.92s: brief held pose with only a tiny secondary settling motion.
    {
        time = 0.92,
        pose = pose(
            {"Root", d(-7,0,-2)}, {"Waist", d(-4,0,-1)}, {"Neck", d(2,0,1)},
            {"LeftShoulder", d(-10,-2,-11)}, {"LeftElbow", d(25,-1,-2)}, {"LeftWrist", d(5,0,0)},
            {"RightShoulder", d(-10,2,11)}, {"RightElbow", d(25,1,2)}, {"RightWrist", d(5,0,0)},
            {"LeftHip", d(6,-2,-2)}, {"LeftKnee", d(1,0,0)}, {"LeftAnkle", d(1,0,-1)},
            {"RightHip", d(6,2,2)}, {"RightKnee", d(1,0,0)}, {"RightAnkle", d(1,0,1)}
        ),
    },

    -- 1.12s: settle toward the existing Fly Idle silhouette.
    {
        time = 1.12,
        pose = pose(
            {"Root", d(-3,0,-1)}, {"Waist", d(-2,0,0)}, {"Neck", d(1,0,0)},
            {"LeftShoulder", d(-5,0,-6)}, {"LeftElbow", d(12,0,-1)}, {"LeftWrist", d(2,0,0)},
            {"RightShoulder", d(-5,0,6)}, {"RightElbow", d(12,0,1)}, {"RightWrist", d(2,0,0)},
            {"LeftHip", d(4,0,-1)}, {"LeftKnee", d(2,0,0)}, {"LeftAnkle", CFrame.identity},
            {"RightHip", d(4,0,1)}, {"RightKnee", d(2,0,0)}, {"RightAnkle", CFrame.identity}
        ),
    },

    -- 1.30s: near-idle.
    {
        time = 1.30,
        pose = pose(
            {"Root", d(-1,0,0)}, {"Waist", d(-1,0,0)}, {"Neck", d(1,0,0)},
            {"LeftShoulder", d(-3,0,-3)}, {"LeftElbow", d(7,0,-1)}, {"LeftWrist", d(1,0,0)},
            {"RightShoulder", d(-3,0,3)}, {"RightElbow", d(7,0,1)}, {"RightWrist", d(1,0,0)},
            {"LeftHip", d(4,0,-1)}, {"LeftKnee", d(2,0,0)}, {"LeftAnkle", CFrame.identity},
            {"RightHip", d(4,0,1)}, {"RightKnee", d(2,0,0)}, {"RightAnkle", CFrame.identity}
        ),
    },

    -- 1.42s: clean handoff pose.
    {
        time = 1.42,
        pose = pose(
            {"Root", CFrame.identity}, {"Waist", CFrame.identity}, {"Neck", CFrame.identity},
            {"LeftShoulder", CFrame.identity}, {"LeftElbow", CFrame.identity}, {"LeftWrist", CFrame.identity},
            {"RightShoulder", CFrame.identity}, {"RightElbow", CFrame.identity}, {"RightWrist", CFrame.identity},
            {"LeftHip", CFrame.identity}, {"LeftKnee", CFrame.identity}, {"LeftAnkle", CFrame.identity},
            {"RightHip", CFrame.identity}, {"RightKnee", CFrame.identity}, {"RightAnkle", CFrame.identity}
        ),
    },
}

local function buildRuntimeKeyframeSequence()
    local sequence = Instance.new("KeyframeSequence")
    sequence.Name = "VGD_FlyStartup_V169_Fallback"
    sequence.Loop = false
    sequence.Priority = Enum.AnimationPriority.Action

    local function makePose(name, cframe)
        local p = Instance.new("Pose")
        p.Name = name
        p.CFrame = cframe
        p.Weight = 1
        p.EasingStyle = Enum.PoseEasingStyle.Cubic
        p.EasingDirection = Enum.PoseEasingDirection.In
        return p
    end

    local function buildTree(parentPose, poseEntries)
        local nodes = {}
        for _, entry in ipairs(poseEntries) do
            nodes[entry[1]] = makePose(
                flyStartup.PoseParts[entry[1]].part,
                entry[2]
            )
        end

        -- Root is represented by the LowerTorso Pose under HumanoidRootPart.
        local root = makePose("HumanoidRootPart", CFrame.identity)
        root.Weight = 0
        root.Parent = parentPose

        for jointName, info in pairs(flyStartup.PoseParts) do
            local node = nodes[jointName]
            if node then
                local parentNode = root
                for otherName, otherInfo in pairs(flyStartup.PoseParts) do
                    if otherInfo.part == info.parent then
                        parentNode = nodes[otherName] or root
                        break
                    end
                end
                node.Parent = parentNode
            end
        end
    end

    for _, authored in ipairs(STARTUP_POSES) do
        local keyframe = Instance.new("Keyframe")
        keyframe.Time = authored.time
        buildTree(keyframe, authored.pose)
        keyframe.Parent = sequence
    end

    return sequence
end

local function buildStartupPoseMap(sequence)
    local map = {}
    for _, keyframe in ipairs(sequence:GetKeyframes()) do
        local frame = {time = keyframe.Time, joints = {}}
        for _, poseObject in ipairs(keyframe:GetDescendants()) do
            if poseObject:IsA("Pose") then
                local partName = poseObject.Name
                for jointName, info in pairs(flyStartup.PoseParts) do
                    if info.part == partName then
                        frame.joints[jointName] = poseObject.CFrame
                        break
                    end
                end
            end
        end
        table.insert(map, frame)
    end
    table.sort(map, function(a, b) return a.time < b.time end)
    return map
end

local function getStartupPoseAtTime(seconds)
    local frames = flyStartup.PoseMap
    if not frames or #frames == 0 then return nil, nil, 0 end

    local previous = frames[1]
    local nextFrame = frames[#frames]

    for i = 2, #frames do
        if seconds <= frames[i].time then
            previous = frames[i - 1]
            nextFrame = frames[i]
            break
        end
    end

    local span = math.max(nextFrame.time - previous.time, 0.0001)
    local rawAlpha = math.clamp((seconds - previous.time) / span, 0, 1)

    -- Smoothstep: 3a^2 - 2a^3.  It gives zero velocity at each authored
    -- pose endpoint, so the joints do not travel at a constant robotic rate.
    local alpha = rawAlpha * rawAlpha * (3 - 2 * rawAlpha)

    return previous, nextFrame, alpha
end

local function applySuperheroTakeoffPose(seconds)
    if not flyStartup.PoseJoints then return end

    local previous, nextFrame, alpha = getStartupPoseAtTime(seconds)
    if not previous or not nextFrame then return end

    for _, name in ipairs(flyStartup.StartupJoints) do
        local a = previous.joints[name] or CFrame.identity
        local b = nextFrame.joints[name] or CFrame.identity
        setStartupTransform(name, a:Lerp(b, alpha))
    end
end

-- V127: forward declaration because the startup PreSimulation driver
-- is defined before the character helper implementation.
local getHumanoidAndRoot

local function startFlyStartupPoseDriver()
    if flyStartup.PreSimulationConnection then
        flyStartup.PreSimulationConnection:Disconnect()
        flyStartup.PreSimulationConnection = nil
    end

    if flyStartup.AssetActive then
        -- V169: a real AnimationTrack owns the startup pose. Do not also
        -- write Motor6D.Transform procedurally, or the two animation systems
        -- would fight each other.
        return
    end

    flyStartup.Sequence = buildRuntimeKeyframeSequence()
    flyStartup.PoseMap = buildStartupPoseMap(flyStartup.Sequence)

    flyStartup.PreSimulationConnection = flyServices.RunService.PreSimulation:Connect(function()
        if not flyRuntime.Enabled or not flyStartup.Active then
            return
        end

        local humanoid = getHumanoidAndRoot()
        maintainStartupAnimatorSuppression(humanoid)

        -- V127 diagnostic has priority over the startup player. It proves the
        -- actual live joint type and Transform write path before we spend any
        -- more time tuning the superhero choreography.
        if flyJointDiagnostic.Active then
            updateFlyJointDiagnostic(1 / 60)
            return
        end

        -- This is the runtime equivalent of an AnimationTrack playing the
        -- KeyframeSequence. The timeline is continuous, and each joint is
        -- interpolated between the surrounding Pose.CFrame values.
        applySuperheroTakeoffPose(flyStartup.Time)
    end)
end

local function stopFlyStartupAnimation()
    if flyStartup.AnimationStoppedConnection then
        flyStartup.AnimationStoppedConnection:Disconnect()
        flyStartup.AnimationStoppedConnection = nil
    end

    if flyStartup.AnimationMonitorConnection then
        flyStartup.AnimationMonitorConnection:Disconnect()
        flyStartup.AnimationMonitorConnection = nil
    end

    local track = flyStartup.AnimationTrack
    flyStartup.AnimationTrack = nil
    flyStartup.AnimationReady = false
    flyStartup.AssetActive = false
    flyStartup.FinalBlendActive = false
    flyStartup.FinalBlendTime = 0

    if track then
        pcall(function()
            track:AdjustWeight(0, 0.10)
        end)
        pcall(function()
            track:AdjustSpeed(0)
        end)
        pcall(function()
            track:Stop(0.10)
        end)
        pcall(function()
            track:Destroy()
        end)
    end

    if flyStartup.AscendStoppedConnection then
        flyStartup.AscendStoppedConnection:Disconnect()
        flyStartup.AscendStoppedConnection = nil
    end
    local ascendTrack = flyStartup.AscendTrack
    flyStartup.AscendTrack = nil
    if ascendTrack then
        pcall(function() ascendTrack:AdjustSpeed(0) end)
        pcall(function() ascendTrack:AdjustWeight(0, 0.10) end)
        pcall(function() ascendTrack:Stop(0.10) end)
        pcall(function() ascendTrack:Destroy() end)
    end
end

local function startNormalFlyAnimationSet(smoothBlend)
    local humanoidNow = getHumanoidAndRoot()
    if not humanoidNow then
        return
    end

    -- Fly 2 owns one persistent animation; never enter Fly 1's idle/move/fidget
    -- state machine from startup completion or recovery callbacks.
    if flyProfile == "Fly 2" then
        local tornado = flyRuntime.Tracks.tornado
        if tornado then
            if not tornado.IsPlaying then
                tornado:Play(FLY_CONFIG.FLY2_TRANSITION_BLEND, 0, FLY_CONFIG.FLY2_TORNADO_SPEED)
            else
                tornado:AdjustWeight(1, FLY_CONFIG.FLY2_TRANSITION_BLEND)
                tornado:AdjustSpeed(FLY_CONFIG.FLY2_TORNADO_SPEED)
            end
        end
        flyStartup.Active = false
        flyStartup.Time = 0
        flyStartup.StartPosition = nil
        return
    end

    local animate = flyRuntime.AnimateScript
    local idle = flyRuntime.Tracks.idle
    local move = flyRuntime.Tracks.move
    local backward = flyRuntime.Tracks.backward

    -- V169: true crossfade handoff. Roblox's live idle remains untouched while
    -- the Fly Idle track starts at ZERO weight. The per-frame animation blender
    -- then raises Fly Idle naturally; we do NOT call AdjustWeight(1, 0.22)
    -- here, because that creates the chunky jump the previous build showed.
    --
    -- The important part is the order:
    --   Roblox Idle (100%) -> Fly Idle (0% -> ~100%) -> disable Animate
    --
    -- Animate is disabled only after the incoming Fly Idle has had enough time
    -- to reach essentially full weight. PlatformStand is also delayed until
    -- after that handoff, so Roblox cannot replace the live idle with its
    -- platform-standing pose halfway through the crossfade.
    if idle then
        if smoothBlend then
            idle:Play(0, 0, 1)
            idle:AdjustWeight(0, 0)
        else
            idle:Play(0, 1, 1)
            idle:AdjustWeight(1, 0)
        end
    end

    if move then
        move:Play(0, 0, 1)
        move:AdjustWeight(0, 0)
    end
    if backward then
        backward:Play(0, 0, 1)
        backward:AdjustWeight(0, 0)
    end

    flyIdleWeight = smoothBlend and 0 or 1
    flyMoveWeight = 0
    flyBackwardWeight = 0
    animState.flyAnimState = "Idle"
    animState.flyPreviousDesiredState = "Idle"
    animState.flyIdleStableTime = 0
    flyIdleFidget.idleTime = 0
    flyIdleFidget.active = false
    flyIdleFidget.elapsed = 0
    flyIdleFidget.activeVariant = 1
    local fidget1 = flyRuntime.Tracks.fidget1
    local fidget2 = flyRuntime.Tracks.fidget2
    local fidget3 = flyRuntime.Tracks.fidget3
    local fidget4 = flyRuntime.Tracks.fidget4
    local fidget5 = flyRuntime.Tracks.fidget5
    if fidget1 then
        pcall(function()
            fidget1:AdjustWeight(0, 0)
            fidget1:Stop(0)
        end)
    end
    if fidget2 then
        pcall(function()
            fidget2:AdjustWeight(0, 0)
            fidget2:Stop(0)
        end)
    end
    if fidget3 then
        pcall(function()
            fidget3:AdjustWeight(0, 0)
            fidget3:Stop(0)
        end)
    end
    if fidget4 then
        pcall(function()
            fidget4:AdjustWeight(0, 0)
            fidget4:Stop(0)
        end)
    end
    if fidget5 then
        pcall(function()
            fidget5:AdjustWeight(0, 0)
            fidget5:Stop(0)
        end)
    end

    if smoothBlend then
        -- V169: DO NOT disable Roblox Animate at the end of the handoff.
        -- The Fly tracks already use Action priority, so they can blend over
        -- the live Roblox idle without forcing the Animator to rebuild the
        -- pose on one frame. Disabling Animate here was the remaining source
        -- of the visible Startup OFF snap after PlatformStand was removed.
        task.delay(0.90, function()
            if not flyRuntime.Enabled or flyStartup.Active then
                return
            end

            flyIdleWeight = 1
        end)
    else
        if animate and animate.Parent
            and (animate:IsA("LocalScript") or animate:IsA("Script")) then
            animate.Disabled = true
        end
    end

end

local function finishFlyStartupAnimation()
    if not flyRuntime.Enabled or not flyStartup.Active then
        return
    end

    flyStartup.AssetActive = false
    flyStartup.AnimationReady = false
    flyStartup.Active = false
    flyStartup.Time = 0
    flyStartup.StartPosition = nil

    if flyStartup.AnimationMonitorConnection then
        flyStartup.AnimationMonitorConnection:Disconnect()
        flyStartup.AnimationMonitorConnection = nil
    end

    if flyStartup.AnimationStoppedConnection then
        flyStartup.AnimationStoppedConnection:Disconnect()
        flyStartup.AnimationStoppedConnection = nil
    end

    local track = flyStartup.AnimationTrack
    flyStartup.AnimationTrack = nil
    if track then
        pcall(function()
            track:AdjustSpeed(0)
            track:AdjustWeight(0, 0.12)
            track:Stop(0.12)
        end)
        pcall(function()
            track:Destroy()
        end)
    end

    clearStartupAnimatorSuppression()
    -- Fade from the final startup pose into Fly Idle instead of replacing it
    -- on one frame. This is the same incoming-track handoff used by Startup OFF.
    startNormalFlyAnimationSet(true)

end

local function startFlyStartupAscendAnimation(humanoid)
    if not humanoid then
        return false
    end

    local animator = humanoid:FindFirstChildOfClass("Animator")
    if not animator then
        animator = Instance.new("Animator")
        animator.Parent = humanoid
    end

    local animation = Instance.new("Animation")
    animation.Name = "VGD_FlyStartupAscend_V183"
    animation.AnimationId = FLY_CONFIG.FLY_STARTUP_ASCEND_ANIMATION_ID
    animation.Parent = humanoid

    local ok, track = pcall(function()
        return animator:LoadAnimation(animation)
    end)
    animation:Destroy()
    if not ok or not track then
        return false
    end

    track.Priority = Enum.AnimationPriority.Action4
    track.Looped = false
    flyStartup.AscendTrack = track

    -- Start invisible and frozen at frame 0. The weight ramp supplies the
    -- 0.90 -> 1.40s crouch-to-ascend transition.
    track:Play(0, 0.001, 0)
    track.TimePosition = 0
    track:AdjustWeight(0, 0)
    track:AdjustSpeed(FLY_CONFIG.FLY_STARTUP_ASCEND_SOURCE_DURATION / FLY_CONFIG.FLY_STARTUP_ASCEND_PLAY_DURATION)
    track:AdjustWeight(1, FLY_CONFIG.FLY_STARTUP_ASCEND_BLEND_IN)

    flyStartup.AscendStoppedConnection = track.Stopped:Connect(function()
        if flyStartup.AscendTrack == track then
            flyStartup.AscendTrack = nil
        end
    end)

    -- Keep the final ascend pose visible until the 1.40 -> 2.00s Fly Idle
    -- handoff is complete, then clean the track up.
    task.delay(FLY_CONFIG.FLY_STARTUP_ASCEND_PLAY_DURATION, function()
        if flyStartup.AscendTrack ~= track then
            return
        end
        track:AdjustSpeed(0)
    end)

    return true
end

local function startFlyStartupAnimation(humanoid)
    stopFlyStartupAnimation()

    if not humanoid or FLY_CONFIG.FLY_STARTUP_ANIMATION_ID == "" then
        return false
    end

    local animator = humanoid:FindFirstChildOfClass("Animator")
    if not animator then
        animator = Instance.new("Animator")
        animator.Parent = humanoid
    end

    local animation = Instance.new("Animation")
    animation.Name = "VGD_FlyStartup_V181"
    animation.AnimationId = FLY_CONFIG.FLY_STARTUP_ANIMATION_ID
    animation.Parent = humanoid

    local ok, track = pcall(function()
        return animator:LoadAnimation(animation)
    end)
    animation:Destroy()

    if not ok or not track then
        return false
    end

    track.Priority = Enum.AnimationPriority.Action4
    track.Looped = false

    flyStartup.AnimationTrack = track
    flyStartup.AssetActive = true
    flyStartup.AnimationReady = false

    -- V181: Startup ON begins from frame 0 of the new dedicated takeoff
    -- animation. Keep the track frozen and effectively invisible while it
    -- blends from the player's current pose into the landing/crouch pose.
    -- After the 0.60s blend, playback is released forward immediately.
    track:Play(0, 0.001, 0)
    track:AdjustSpeed(0)
    track:AdjustWeight(0.001, 0)

    flyStartup.AnimationStoppedConnection = track.Stopped:Connect(function()
        -- An explicit Fly disable or our controlled finish path stops the track.
        -- Only an unexpected stop while startup is still active should trigger
        -- the safe normal-Fly handoff.
        if flyRuntime.Enabled and flyStartup.Active and flyStartup.AssetActive then
            finishFlyStartupAnimation()
        end
    end)

    task.spawn(function()
        local deadline = os.clock() + 1.50

        while flyRuntime.Enabled
            and flyStartup.Active
            and flyStartup.AssetActive
            and track.IsPlaying
            and track.Length <= 0.05
            and os.clock() < deadline do
            task.wait()
        end

        if not flyRuntime.Enabled
            or not flyStartup.Active
            or not flyStartup.AssetActive
            or flyStartup.AnimationTrack ~= track
            or not track.IsPlaying then
            return
        end

        local length = track.Length
        if length <= 0.05 then
            -- Target game did not deliver the animation. Fail safely into normal
            -- Fly instead of leaving the character locked in startup.
            finishFlyStartupAnimation()
            return
        end

        flyStartup.Duration = FLY_CONFIG.FLY_STARTUP_POSE_BLEND_TIME
            + FLY_CONFIG.FLY_STARTUP_POSE_HOLD_TIME
            + length
        flyStartup.Time = 0

        -- Frame 0 is the desired landing/crouch pose. The track remains frozen
        -- there while its weight is blended in over 0.60s. Playback then starts
        -- immediately so the animation can leave the crouch before root lift.
        if not track.IsPlaying then
            track:Play(0, 0.001, 0)
            track:AdjustSpeed(0)
        end

        track.TimePosition = 0
        flyStartup.AnimationReady = true
        track:AdjustWeight(1, FLY_CONFIG.FLY_STARTUP_POSE_BLEND_TIME)

        task.delay(FLY_CONFIG.FLY_STARTUP_POSE_BLEND_TIME + FLY_CONFIG.FLY_STARTUP_POSE_HOLD_TIME, function()
            if not flyRuntime.Enabled
                or not flyStartup.Active
                or not flyStartup.AssetActive
                or flyStartup.AnimationTrack ~= track
                or not track.IsPlaying then
                return
            end

            track.TimePosition = 0
            track:AdjustSpeed(1)
        end)

        flyStartup.AnimationMonitorConnection = flyServices.RunService.Heartbeat:Connect(function()
            if not flyRuntime.Enabled
                or not flyStartup.Active
                or not flyStartup.AssetActive
                or flyStartup.AnimationTrack ~= track then
                return
            end

            -- V181: the landing asset is intentionally used only for the visible
            -- crouch/landing portion. Do NOT let its long crouched section
            -- continue for the remaining ~2 seconds. At 0.90s total startup
            -- time, freeze the current pose, fade it out, and hand the body
            -- to Fly Idle while the real root begins a slow upward launch.
            if flyStartup.Time >= FLY_CONFIG.FLY_STARTUP_CUT_TIME then
                track.TimePosition = math.min(track.TimePosition, FLY_CONFIG.FLY_STARTUP_CUT_TIME)
                track:AdjustSpeed(0)
                track:AdjustWeight(0, FLY_CONFIG.FLY_STARTUP_LAUNCH_DURATION)

                flyStartup.AssetActive = false
                flyStartup.AnimationReady = false
                -- Keep flyStartup.Active true through 0.90 -> 1.40s so the
                -- dedicated ascend animation fully owns the pose before Fly Idle
                -- is introduced. It is released at the launch point below.
                if flyStartup.AnimationMonitorConnection then
                    flyStartup.AnimationMonitorConnection:Disconnect()
                    flyStartup.AnimationMonitorConnection = nil
                end
                flyStartup.LaunchActive = true
                flyStartup.LaunchTime = 0
                local _, launchRoot = getHumanoidAndRoot()
                flyStartup.StartPosition = flyStartup.StartPosition
                    or (launchRoot and launchRoot.Position)

                if flyStartup.AnimationStoppedConnection then
                    flyStartup.AnimationStoppedConnection:Disconnect()
                    flyStartup.AnimationStoppedConnection = nil
                end

                flyStartup.AnimationTrack = nil
                clearStartupAnimatorSuppression()

                -- V181: immediately introduce the dedicated 7-second ascend
                -- animation, compressed into 0.60s. Keep Fly Idle suppressed
                -- until 1.40s so the ascend pose owns the body during the
                -- crouch-to-ascend transition.
                local ascendStarted = startFlyStartupAscendAnimation(humanoid)
                if not ascendStarted then
                    -- Safe fallback: if the ascend asset cannot load, keep the
                    -- previous direct Fly Idle handoff rather than locking startup.
                    flyStartup.Active = false
                    startNormalFlyAnimationSet(true)
                end

                pcall(function() track:Stop(FLY_CONFIG.FLY_STARTUP_ASCEND_BLEND_IN) end)
                task.delay(FLY_CONFIG.FLY_STARTUP_ASCEND_BLEND_IN, function()
                    pcall(function() track:Destroy() end)
                end)
            end
        end)
    end)

    return true
end

local function stopFlyStartupPoseDriver()
    if flyStartup.PreSimulationConnection then
        flyStartup.PreSimulationConnection:Disconnect()
        flyStartup.PreSimulationConnection = nil
    end
end

-- H17.2 / OP V220: preserve dormant directional phase hold against speed updates.
-- v56: explicit per-track blend weights owned by Fly.
local flyIdleWeight = 1
local flyMoveWeight = 0
local flyBackwardWeight = 0

-- V220: hold playback phase while a directional track is genuinely dormant.
-- The per-frame movement-speed updater must not override AdjustSpeed(0) while held.
local FLY_DIRECTION_PHASE_DORMANT_EPSILON = 0.01
local FLY_DIRECTION_PHASE_ACTIVATE_EPSILON = 0.03
local flyDirectionalPaused = { Forward = false, Backward = false }

local function applyDirectionalWeightWithPhaseGuard(track, directionKey, targetWeight)
    if not track then return end
    local target = math.clamp(targetWeight, 0, 1)
    local currentWeight = 1
    local ok = pcall(function() currentWeight = track.WeightCurrent end)
    if not ok then currentWeight = 1 end

    if target >= FLY_DIRECTION_PHASE_ACTIVATE_EPSILON then
        if flyDirectionalPaused[directionKey] then
            pcall(function() track:AdjustSpeed(1) end)
            flyDirectionalPaused[directionKey] = false
        end
    elseif target <= FLY_DIRECTION_PHASE_DORMANT_EPSILON
        and currentWeight <= FLY_DIRECTION_PHASE_DORMANT_EPSILON then
        if not flyDirectionalPaused[directionKey] then
            pcall(function() track:AdjustSpeed(0) end)
            flyDirectionalPaused[directionKey] = true
        end
    end

    track:AdjustWeight(target, 0)
end

local function getCharacter()
    return flyServices.Player.Character
end

getHumanoidAndRoot = function()
    local character = getCharacter()
    if not character then return nil, nil end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local root = character:FindFirstChild("HumanoidRootPart")
    if not humanoid or not root then return nil, nil end
    return humanoid, root
end

local function stopTracks()
    for _, track in pairs(flyRuntime.Tracks) do
        pcall(function() track:Stop(0.15) end)
    end
    flyRuntime.Tracks = {}
    animState.flyAnimState = "Idle"
    animState.flyPreviousDesiredState = "Idle"
    animState.flyIdleStableTime = 0
    flyIdleFidget.idleTime = 0
    flyIdleFidget.active = false
    flyIdleFidget.elapsed = 0
end

local function loadFlyAnimations(humanoid)
    stopTracks()
    local animator = humanoid:FindFirstChildOfClass("Animator")
    if not animator then
        animator = Instance.new("Animator")
        animator.Parent = humanoid
    end

    -- V169: do NOT stop the character's existing Animate tracks here.
    -- Startup OFF needs a real idle -> Fly Idle blend, while Startup ON
    -- needs the reversed Action4 emote to fade directly over the current idle.

    local function load(id, priority, looped)
        local animation = Instance.new("Animation")
        animation.AnimationId = id
        animation.Parent = humanoid
        local ok, track = pcall(function()
            return animator:LoadAnimation(animation)
        end)
        animation:Destroy()
        if ok and track then
            track.Priority = priority
            track.Looped = looped ~= false
            return track
        end
        return nil
    end

    -- v54: all custom Fly tracks use Action priority so they can
    -- reliably override any existing avatar animation tracks while
    -- the Animate controller is disabled.
    if flyProfile == "Fly 2" then
        flyRuntime.Tracks.tornado = load(FLY_CONFIG.FLY2_TORNADO_ANIMATION_ID, Enum.AnimationPriority.Action)
    else
        flyRuntime.Tracks.idle = load(FLY_CONFIG.IDLE_ANIMATION_ID, Enum.AnimationPriority.Action)
        flyRuntime.Tracks.move = load(FLY_CONFIG.MOVE_ANIMATION_ID, Enum.AnimationPriority.Action)
        flyRuntime.Tracks.backward = load(FLY_CONFIG.BACKWARD_ANIMATION_ID, Enum.AnimationPriority.Action)
    end
    if flyProfile == "Fly 1" then
    flyRuntime.Tracks.fidget1 = load(flyIdleFidget.variants[1].animationId, Enum.AnimationPriority.Action4, false)
    end
    if flyProfile == "Fly 1" then
    flyRuntime.Tracks.fidget2 = load(flyIdleFidget.variants[2].animationId, Enum.AnimationPriority.Action4, false)
    end
    if flyProfile == "Fly 1" then
    flyRuntime.Tracks.fidget3 = load(flyIdleFidget.variants[3].animationId, Enum.AnimationPriority.Action4, false)
    end
    if flyProfile == "Fly 1" then
    flyRuntime.Tracks.fidget4 = load(flyIdleFidget.variants[4].animationId, Enum.AnimationPriority.Action4, false)
    end
    if flyProfile == "Fly 1" then
    flyRuntime.Tracks.fidget5 = load(flyIdleFidget.variants[5].animationId, Enum.AnimationPriority.Action4, false)
    end

    -- V169: NEVER start a Fly-owned animation at full weight during loading.
    -- Fly 2's Tornado is started by the profile's explicit startup/handoff path.
    -- This prevents Tornado from appearing underneath Fall/Shatter on startup ON.
    flyIdleWeight = 0
    flyMoveWeight = 0
    flyBackwardWeight = 0

end

local function updateFlyAnimations(isMoving, moveDirection, deltaTime, forwardInput)
    local idle = flyRuntime.Tracks.idle
    local move = flyRuntime.Tracks.move
    local backward = flyRuntime.Tracks.backward
    if flyProfile == "Fly 2" then
        local startupTrack = flyRuntime.Tracks.fly2Startup
        local startupStillRunning = flyRuntime.Fly2StartupPending
            and startupTrack ~= nil and startupTrack.IsPlaying
        if not startupStillRunning then
            local tornado = flyRuntime.Tracks.tornado
            if tornado then
                if not tornado.IsPlaying then
                    tornado:Play(FLY_CONFIG.FLY2_TRANSITION_BLEND, 1, FLY_CONFIG.FLY2_TORNADO_SPEED)
                end
                if not flyRuntime.Fly2TornadoHandoffPending then
                    tornado:AdjustSpeed(FLY_CONFIG.FLY2_TORNADO_SPEED)
                end
            end
        end
        return
    end
    if not idle then return end

    -- During the procedural takeoff, the custom Fly animation tracks must
    -- NOT contribute to the pose. The startup pose is authored directly on
    -- Motor6D.Transform, so leaving the Fly Idle track at weight 1 would make
    -- the character look like it is doing the normal Fly idle while the root
    -- is being lifted.
    if flyStartup.Active then
        animState.flyAnimState = "Startup"
        flyIdleWeight = 0
        flyMoveWeight = 0
        flyBackwardWeight = 0
        flyIdleFidget.idleTime = 0
        if not flyIdleFidget.interrupting then
            flyIdleFidget.active = false
            flyIdleFidget.elapsed = 0
        end
        flyIdleFidget.interrupting = false
        flyIdleFidget.interruptElapsed = 0
        flyIdleFidget.interruptRemaining = 0
        local startupFidget = flyRuntime.Tracks.fidget
        if startupFidget then
            pcall(function()
                startupFidget:AdjustWeight(0, 0)
                startupFidget:Stop(0)
            end)
        end
        animState.flyDirectionTransitionActive = false
        -- Keep every Fly track stopped until the procedural startup finishes.
        -- The startup pose owns Motor6D.Transform directly.
        return
    end

    local desiredState = "Idle"
    if isMoving and moveDirection.Magnitude > 0.001 then
        desiredState = (forwardInput or 0) < -0.15 and "Backward" or "Forward"
    end

    animState.flyAnimState = desiredState

    -- V190.9: use hysteresis for Idle detection. A transient zero from the
    -- joystick/controller is NOT allowed to convert the previous direction
    -- into Idle for the next frame. Only a continuously held Idle state past
    -- the threshold commits the state machine to Idle. This prevents the old
    -- direction bug from returning when input briefly flickers during a
    -- Forward <-> Backward reversal.
    local requestedState = desiredState
    if desiredState == "Idle" then
        animState.flyIdleStableTime = math.min(
            animState.flyIdleStableTime + math.max(deltaTime, 0),
            FLY_CONFIG.FLY_IDLE_STABLE_THRESHOLD
        )

        if animState.flyIdleStableTime < FLY_CONFIG.FLY_IDLE_STABLE_THRESHOLD
            and (animState.flyPreviousDesiredState == "Forward" or animState.flyPreviousDesiredState == "Backward") then
            -- Treat this as a transient input gap. Keep the previous committed
            -- direction alive so the active reversal blend is not destroyed.
            requestedState = animState.flyPreviousDesiredState
        else
            requestedState = "Idle"
        end
    else
        animState.flyIdleStableTime = 0
    end

    animState.flyAnimState = requestedState

    local fidgetVariant = flyIdleFidget.variants[flyIdleFidget.activeVariant] or flyIdleFidget.variants[1]
    local fidget = flyRuntime.Tracks[fidgetVariant.trackKey]
    if desiredState ~= "Idle" then
        -- V197: interrupt the active fidget through the SAME direction handoff
        -- window instead of simply stopping the fidget and letting the normal
        -- movement blend start independently. The current fidget becomes the
        -- outgoing pose, while the requested Forward/Backward track becomes the
        -- incoming pose. This makes Fidget -> movement feel like one continuous
        -- transition and follows the live requested direction immediately.
        flyIdleFidget.idleTime = 0
        if flyIdleFidget.active and not flyIdleFidget.interrupting and fidget then
            -- V197.3: LOCK the exact fidget track and its current pose at the
            -- instant movement begins. The fidget stays alive/frozen while
            -- its weight is handed directly to Forward/Backward. We do NOT
            -- mark it inactive until the handoff is completely finished.
            flyIdleFidget.interrupting = true
            flyIdleFidget.interruptElapsed = 0
            flyIdleFidget.diagnosticElapsed = 0
            flyIdleFidget.interruptStartFidgetWeight = math.clamp(
                fidget.WeightCurrent, 0, 1
            )
            flyIdleFidget.interruptStartIdleWeight = math.clamp(
                flyIdleWeight, 0, 1
            )
            flyIdleFidget.interruptMoveWeight = 0
            flyIdleFidget.interruptBackwardWeight = 0
            flyIdleFidget.interruptRemaining = 1
            -- Start from the requested direction, but thereafter the target
            -- is continuously redirected from the live directional share.
            flyIdleFidget.interruptDirectionBlend = requestedState == "Forward" and 1 or 0
            -- Freeze the authored fidget at the exact pose where movement began.
            -- If the track keeps advancing while its weight fades, it can reach
            -- another keyframe or loop boundary and create a visible pose
            -- discontinuity even though the weights themselves are smooth.
            pcall(function()
                fidget:AdjustSpeed(0)
            end)
        elseif not flyIdleFidget.interrupting then
            flyIdleFidget.interrupting = false
            flyIdleFidget.interruptElapsed = 0
            flyIdleFidget.activeVariant = 1
        end
        -- Keep the original fidget active/frozen for the entire interruption.
        -- It is the actual outgoing pose, not a placeholder that gets replaced
        -- by Fly Idle. The interruption block below clears it only after the
        -- outgoing weight has reached zero.
        if not flyIdleFidget.interrupting then
            flyIdleFidget.active = false
            flyIdleFidget.elapsed = 0
        end
    elseif requestedState == "Idle" and not flyIdleFidget.active then
        flyIdleFidget.idleTime = math.min(
            flyIdleFidget.idleTime + math.max(deltaTime, 0),
            flyIdleFidget.triggerDelay
        )

        if flyIdleFidget.idleTime >= flyIdleFidget.triggerDelay then
            -- Cycle through all configured fidgets so the same variation is not
            -- repeated every time the player remains idle.
            local variantCount = #flyIdleFidget.variants
            local nextVariant = (flyIdleFidget.lastVariant % variantCount) + 1
            flyIdleFidget.activeVariant = nextVariant
            flyIdleFidget.lastVariant = nextVariant
            fidgetVariant = flyIdleFidget.variants[nextVariant]
            fidget = flyRuntime.Tracks[fidgetVariant.trackKey]

            if fidget then
                flyIdleFidget.active = true
                flyIdleFidget.interrupting = false
                flyIdleFidget.interruptElapsed = 0
                flyIdleFidget.elapsed = 0
                flyIdleFidget.idleTime = 0
                pcall(function()
                    fidget:Play(0, 0, 1)
                    fidget.TimePosition = fidgetVariant.sourceStart
                    fidget:AdjustSpeed(1)
                    fidget:AdjustWeight(0, 0)
                end)
            end
        end
    end

    -- V190.11: keep logical direction independent from animation residue.
    -- A real stop commits Idle, but we remember the last committed directional
    -- state separately so a quick Idle -> opposite-direction restart can still
    -- use the continuous reversal blend without changing the requested state.
    local startedMovingFromIdle =
        animState.flyPreviousDesiredState == "Idle"
        and (requestedState == "Forward" or requestedState == "Backward")

    local residualReversalFrom = nil
    if startedMovingFromIdle then
        -- Use the last directional state before the committed Idle instead of
        -- guessing from current animation weights. This preserves symmetrical
        -- Forward -> Stop -> Backward and Backward -> Stop -> Forward behavior.
        local lastDirectionalState = animState.flyLastDirectionalState
        if lastDirectionalState == "Forward" or lastDirectionalState == "Backward" then
            if lastDirectionalState ~= requestedState then
                residualReversalFrom = lastDirectionalState
            end
        end
    end

    -- V190.9 diagnostic:
    -- Forward <-> Backward uses a continuous THREE-WAY blend instead of
    -- Forward -> Idle -> Backward. Idle acts only as a temporary pose cushion.
    -- The outgoing and incoming direction tracks never both reach zero, and
    -- the Idle track never reaches weight 1, so the character never visibly
    -- stops in Idle during a reversal.
    local directDirectionReversal =
        (animState.flyAnimState == "Forward" and animState.flyDirectionTransitionTo == "Backward")
        or (animState.flyAnimState == "Backward" and animState.flyDirectionTransitionTo == "Forward")

    -- H15.2 keeps the existing continuous three-way transition, but never
    -- replaces its live source with a newly computed target pose. This is
    -- important when a joystick is rapidly circled: the current animation
    -- mix remains the source while the destination is redirected.

    -- H15.5: preserve smooth directional -> Idle handoff during fidget interruption.
-- H15.4: freeze the exact interrupted fidget pose and let the handoff remain
    -- valid even if movement stops before the fidget fade has completed.
    -- H15.3: preserve the exact current fidget pose on the first movement
    -- frame, then continuously converge from that pose into the live direction.
    -- There is deliberately NO fixed interruption deadline here. The outgoing
    -- fidget/Idle share decays toward zero every frame and the handoff finishes
    -- only when the remaining outgoing weight is below a tiny perceptual
    -- threshold. This prevents a distant authored pose from being forcibly
    -- killed while a visible body/arm difference still remains.
    -- Capture controller ownership for this frame before the interruption
    -- block can release itself. The normal mixer must not run on the same
    -- frame that the fidget handoff finishes; it takes ownership next frame.
    flyIdleFidget.interruptOwnedThisFrame = flyIdleFidget.interrupting

    if flyIdleFidget.interrupting then
        local convergenceResponse = math.max(
            FLY_CONFIG.FLY_FIDGET_INTERRUPT_CONVERGENCE_RESPONSE,
            0.05
        )
        local convergenceAlpha = 1 - math.exp(
            -math.max(deltaTime, 0) / convergenceResponse
        )

        flyIdleFidget.interruptElapsed += math.max(deltaTime, 0)
        flyIdleFidget.interruptRemaining = flyIdleFidget.interruptRemaining
            * (1 - convergenceAlpha)
        flyIdleFidget.interruptT = 1 - flyIdleFidget.interruptRemaining
        flyIdleFidget.interruptSmoothT = flyIdleFidget.interruptT

        local outgoingScale = flyIdleFidget.interruptRemaining
        local t = 1 - outgoingScale
        local fidgetWeight = flyIdleFidget.interruptStartFidgetWeight * outgoingScale

        -- H16.1: update the requested direction BEFORE the resume branch
        -- calculates this frame's output weights. V207/V208 placed this update
        -- after that branch, so its first output frame could use stale direction.
        -- Idle deliberately holds the last directional share; it is not Backward.
        if requestedState == "Forward" or requestedState == "Backward" then
            local desiredDirectionBlend = requestedState == "Forward" and 1 or 0
            local directionRedirectAlpha = 1 - math.exp(
                -math.max(deltaTime, 0) / FLY_CONFIG.FLY_FIDGET_DIRECTION_REDIRECT_RESPONSE
            )
            flyIdleFidget.interruptDirectionBlend =
                flyIdleFidget.interruptDirectionBlend
                + (desiredDirectionBlend - flyIdleFidget.interruptDirectionBlend)
                    * directionRedirectAlpha
        end

        -- H15.5: stopping during an interrupted-fidget handoff is itself a
        -- transition. Do NOT zero Forward/Backward on the first Idle frame.
        -- Preserve the live directional mix, then continuously decay it into
        -- Fly Idle while the frozen fidget continues its own fade. This keeps
        -- the total animation weight continuous and removes the Idle snap.
        -- Keep resumeAlpha in the enclosing interruption scope because the
        -- completion check below runs after both the Idle and moving branches.
        local resumeAlpha = 0

        if requestedState == "Idle" then
            -- V214: a stop cancels any in-progress Idle->movement resume blend.
            -- The Idle branch below derives a fresh live stop mix from the current
            -- interruption progress. Keeping the old resume flag/timer alive here
            -- would make a later restart reuse stale elapsed time and stale source
            -- weights, potentially skipping the intended resume transition.
            if flyIdleFidget.interruptResumingFromIdle then
                flyIdleFidget.interruptResumingFromIdle = false
                flyIdleFidget.interruptResumeElapsed = 0
                flyIdleFidget.interruptResumeStartIdleWeight = 0
                flyIdleFidget.interruptResumeStartMoveWeight = 0
                flyIdleFidget.interruptResumeStartBackwardWeight = 0
            end
            flyIdleFidget.interruptStopElapsed += math.max(deltaTime, 0)
            -- H15.6: the V203 stop release was a little faster than the
            -- normal animation blend. Give this handoff a slightly longer
            -- response so stopping after a fidget feels consistent.
            local stopAlpha = 1 - math.exp(
                -flyIdleFidget.interruptStopElapsed / 0.22
            )
            local stopRemaining = 1 - stopAlpha

            local liveMoveWeight = t * flyIdleFidget.interruptDirectionBlend
            local liveBackwardWeight = t * (1 - flyIdleFidget.interruptDirectionBlend)

            flyMoveWeight = liveMoveWeight * stopRemaining
            flyBackwardWeight = liveBackwardWeight * stopRemaining
            flyIdleWeight = math.clamp(
                1 - fidgetWeight - flyMoveWeight - flyBackwardWeight,
                0,
                1
            )
        else
            -- H15.7: if the player stopped during the fidget handoff and then
            -- starts moving again before that handoff has fully completed, do
            -- not expose the already-developed directional weight immediately.
            -- Treat it as a genuine Idle -> movement transition for this one
            -- post-fidget window, so the next movement blends in normally.
            if flyIdleFidget.interruptStopElapsed > 0
                and not flyIdleFidget.interruptResumingFromIdle then
                -- H15.8: capture the EXACT live pose weights at the first
                -- movement frame after a fidget-interruption stop. Do not
                -- reconstruct the source from t/directionBlend; that can make
                -- the first resumed frame inherit a stale directional share.
                flyIdleFidget.interruptResumingFromIdle = true
                flyIdleFidget.interruptResumeElapsed = 0
                flyIdleFidget.interruptResumeStartIdleWeight = math.clamp(flyIdleWeight, 0, 1)
                flyIdleFidget.interruptResumeStartMoveWeight = math.clamp(flyMoveWeight, 0, 1)
                flyIdleFidget.interruptResumeStartBackwardWeight = math.clamp(flyBackwardWeight, 0, 1)
            end

            flyIdleFidget.interruptStopElapsed = 0

            if flyIdleFidget.interruptResumingFromIdle then
                -- H15.8: resolve the NEW direction before calculating this
                -- frame's weights. This prevents the old directional share
                -- from appearing for one frame when resuming Forward.
                flyIdleFidget.interruptResumeElapsed += math.max(deltaTime, 0)
                resumeAlpha = 1 - math.exp(
                    -flyIdleFidget.interruptResumeElapsed / 0.18
                )
                local availableWeight = math.clamp(1 - fidgetWeight, 0, 1)
                local startIdle = flyIdleFidget.interruptResumeStartIdleWeight
                local startMove = flyIdleFidget.interruptResumeStartMoveWeight
                local startBackward = flyIdleFidget.interruptResumeStartBackwardWeight
                local startTotal = math.max(startIdle + startMove + startBackward, 0.0001)
                local sourceScale = math.clamp(availableWeight / startTotal, 0, 1)

                local sourceIdle = startIdle * sourceScale
                local sourceMove = startMove * sourceScale
                local sourceBackward = startBackward * sourceScale
                local targetMove = availableWeight * flyIdleFidget.interruptDirectionBlend
                local targetBackward = availableWeight * (1 - flyIdleFidget.interruptDirectionBlend)

                flyIdleWeight = sourceIdle + (0 - sourceIdle) * resumeAlpha
                flyMoveWeight = sourceMove + (targetMove - sourceMove) * resumeAlpha
                flyBackwardWeight = sourceBackward + (targetBackward - sourceBackward) * resumeAlpha

            else
                flyIdleWeight = flyIdleFidget.interruptStartIdleWeight * outgoingScale
            end
        end

        -- Preserve the final calculated resume-blend output for this frame.
        -- The previous ordering cleared interruptResumingFromIdle first, which
        -- allowed the direct directional-weight assignment below to overwrite
        -- the resume interpolation on its completion frame.
        if requestedState ~= "Idle" and not flyIdleFidget.interruptResumingFromIdle then
            flyMoveWeight = t * flyIdleFidget.interruptDirectionBlend
            flyBackwardWeight = t * (1 - flyIdleFidget.interruptDirectionBlend)
        end

        if flyIdleFidget.interruptResumingFromIdle and resumeAlpha >= 0.995 then
            flyIdleFidget.interruptResumingFromIdle = false
            flyIdleFidget.interruptResumeElapsed = 0
            flyIdleFidget.interruptResumeStartIdleWeight = 0
            flyIdleFidget.interruptResumeStartMoveWeight = 0
            flyIdleFidget.interruptResumeStartBackwardWeight = 0
        end
        flyIdleFidget.interruptMoveWeight = flyMoveWeight
        flyIdleFidget.interruptBackwardWeight = flyBackwardWeight

        if idle and not idle.IsPlaying then idle:Play(0, 1, 1) end
        if move and not move.IsPlaying then move:Play(0, 1, 1) end
        if backward and not backward.IsPlaying then backward:Play(0, 1, 1) end
        if idle then idle:AdjustWeight(flyIdleWeight, 0) end
        if move then applyDirectionalWeightWithPhaseGuard(move, "Forward", flyMoveWeight) end
        if backward then applyDirectionalWeightWithPhaseGuard(backward, "Backward", flyBackwardWeight) end

        if fidget then
            pcall(function()
                fidget:AdjustWeight(fidgetWeight, 0)
                if flyIdleFidget.interruptRemaining <= FLY_CONFIG.FLY_FIDGET_INTERRUPT_WEIGHT_EPSILON then
                    fidget:AdjustWeight(0, 0)
                    fidget:AdjustSpeed(1)
                    fidget:Stop(0)
                end
            end)
        end

        -- V210 diagnostic only: sample the interrupted-fidget handoff at 4 Hz.
        -- This does not alter animation weights, playback, or controller state.
        flyIdleFidget.diagnosticElapsed += math.max(deltaTime, 0)
        if flyIdleFidget.diagnosticElapsed >= 0.25 then
            flyIdleFidget.diagnosticElapsed -= 0.25
            local function diagnosticTrack(track)
                if not track then return "none" end
                return string.format("w=%.3f/%.3f t=%.3f playing=%s",
                    track.WeightCurrent, track.WeightTarget, track.TimePosition,
                    tostring(track.IsPlaying))
            end
            print(string.format(
                "[V210 FIDGET] state=%s elapsed=%.2f stop=%.2f resume=%.2f remain=%.4f resuming=%s dir=%.3f logical(I/F/B)=%.3f/%.3f/%.3f | idle{%s} forward{%s} backward{%s} fidget{%s}",
                requestedState,
                flyIdleFidget.interruptElapsed,
                flyIdleFidget.interruptStopElapsed,
                flyIdleFidget.interruptResumeElapsed,
                flyIdleFidget.interruptRemaining,
                tostring(flyIdleFidget.interruptResumingFromIdle),
                flyIdleFidget.interruptDirectionBlend,
                flyIdleWeight, flyMoveWeight, flyBackwardWeight,
                diagnosticTrack(idle), diagnosticTrack(move),
                diagnosticTrack(backward), diagnosticTrack(fidget)
            ))
        end

        -- H16.0 / OP V208: fidget fade completion is NOT sufficient to
        -- release transition ownership. Keep this controller alive until any
        -- resume blend has settled, and until an Idle stop handoff has reached
        -- its own settling threshold. This prevents a time-dependent handoff
        -- to the normal controller while its source mix is still changing.
        local fidgetFadeComplete =
            flyIdleFidget.interruptRemaining <= FLY_CONFIG.FLY_FIDGET_INTERRUPT_WEIGHT_EPSILON
        local resumeBlendComplete = not flyIdleFidget.interruptResumingFromIdle
        local stopBlendComplete = requestedState ~= "Idle"
            or flyIdleFidget.interruptStopElapsed >= 1.2

        if fidgetFadeComplete and resumeBlendComplete and stopBlendComplete then
            flyIdleFidget.interrupting = false
            flyIdleFidget.interruptElapsed = 0
            flyIdleFidget.active = false
            flyIdleFidget.activeVariant = 1
            flyIdleFidget.interruptDuration = 0
            flyIdleFidget.interruptT = 0
            flyIdleFidget.interruptSmoothT = 0
            flyIdleFidget.interruptRemaining = 0
            flyIdleFidget.interruptStartFidgetWeight = 0
            flyIdleFidget.interruptStartIdleWeight = 0
            flyIdleFidget.interruptMoveWeight = 0
            flyIdleFidget.interruptBackwardWeight = 0
            flyIdleFidget.interruptDirectionBlend = 1
            flyIdleFidget.interruptStopElapsed = 0
            flyIdleFidget.interruptResumeElapsed = 0
            flyIdleFidget.interruptResumingFromIdle = false
            flyIdleFidget.currentWeight = 0
        end
    end

    if requestedState == "Forward" or requestedState == "Backward" then
        if flyIdleFidget.interruptOwnedThisFrame then
            -- The dedicated fidget handoff above owns this frame even if it
            -- marked itself complete. The normal controller starts next frame.
            -- weights for this frame. Keep the normal transition state neutral
            -- so the existing reversal system takes over cleanly on the next
            -- frame without a second blend being layered on top.
            animState.flyDirectionTransitionActive = false
            animState.flyDirectionTransitionFrom = nil
            animState.flyDirectionTransitionTo = nil
            animState.flyDirectionTransitionTime = 0
        elseif startedMovingFromIdle and not residualReversalFrom then
            -- A genuine Idle -> movement start. No directional residue remains
            -- strong enough to justify a reversal transition.
            animState.flyDirectionTransitionActive = false
            animState.flyDirectionTransitionFrom = nil
            animState.flyDirectionTransitionTo = nil
            animState.flyDirectionTransitionTime = 0
            flyIdleWeight = 1
            flyMoveWeight = 0
            flyBackwardWeight = 0
        elseif residualReversalFrom and not animState.flyDirectionTransitionActive then
            -- Idle-gap continuation: preserve the exact logical three-way mix
            -- that existed when movement resumed. Do not reconstruct it as a
            -- canonical 100%-directional source pose.
            animState.flyIdleGapSourceIdle = math.clamp(flyIdleWeight, 0, 1)
            animState.flyIdleGapSourceForward = math.clamp(flyMoveWeight, 0, 1)
            animState.flyIdleGapSourceBackward = math.clamp(flyBackwardWeight, 0, 1)
            animState.flyIdleGapTransitionActive = true
            animState.flyDirectionTransitionActive = true
            animState.flyDirectionTransitionFrom = residualReversalFrom
            animState.flyDirectionTransitionTo = requestedState
            animState.flyDirectionTransitionTime = 0

        elseif not animState.flyDirectionTransitionActive then
            local currentDominant
            if flyMoveWeight >= flyBackwardWeight then
                currentDominant = "Forward"
            else
                currentDominant = "Backward"
            end

            if currentDominant ~= requestedState then
                animState.flyDirectionTransitionActive = true
                animState.flyDirectionTransitionFrom = currentDominant
                animState.flyDirectionTransitionTo = requestedState
                animState.flyDirectionTransitionTime = 0

            end
        elseif animState.flyDirectionTransitionTo ~= requestedState then
            -- A new reversal supersedes an Idle-gap continuation; use the
            -- existing direct live-direction redirect path from this point.
            animState.flyIdleGapTransitionActive = false
            -- H15.2: redirect from the ACTUAL live directional mix, not from
            -- the old transition timer. This matters when the joystick is
            -- rapidly circled and the requested direction flips repeatedly:
            -- the current Forward/Backward weights remain the source pose,
            -- while only the destination changes.
            local previousTo = animState.flyDirectionTransitionTo
            local currentForwardWeight = math.clamp(flyMoveWeight, 0, 1)
            local currentBackwardWeight = math.clamp(flyBackwardWeight, 0, 1)
            local currentDirectionalTotal = currentForwardWeight + currentBackwardWeight

            animState.flyDirectionTransitionTo = requestedState
            animState.flyDirectionTransitionFrom = previousTo

            if currentDirectionalTotal > 0.0001 then
                local requestedWeight = requestedState == "Forward"
                    and currentForwardWeight
                    or currentBackwardWeight
                local liveProgress = math.clamp(
                    requestedWeight / currentDirectionalTotal,
                    0,
                    1
                )
                animState.flyDirectionTransitionTime =
                    liveProgress * FLY_CONFIG.FLY_DIRECTION_CONTINUOUS_BLEND_TIME
            else
                animState.flyDirectionTransitionTime = 0
            end

        end
    else
        animState.flyIdleGapTransitionActive = false
        animState.flyIdleGapSourceIdle = nil
        animState.flyIdleGapSourceForward = nil
        animState.flyIdleGapSourceBackward = nil
        -- Entering Idle explicitly ends any reversal state. The next movement
        -- must therefore start from Idle, even if the previous direction track
        -- is still fading out underneath it.
        animState.flyDirectionTransitionActive = false
        animState.flyDirectionTransitionFrom = nil
        animState.flyDirectionTransitionTo = nil
        animState.flyDirectionTransitionTime = 0
    end

    if requestedState == "Forward" or requestedState == "Backward" then
        animState.flyLastDirectionalState = requestedState
    end

    animState.flyPreviousDesiredState = requestedState

    if not flyIdleFidget.interruptOwnedThisFrame and animState.flyDirectionTransitionActive
        and (animState.flyDirectionTransitionFrom == "Forward" or animState.flyDirectionTransitionFrom == "Backward")
        and (animState.flyDirectionTransitionTo == "Forward" or animState.flyDirectionTransitionTo == "Backward") then

        animState.flyDirectionTransitionTime = math.min(
            animState.flyDirectionTransitionTime + deltaTime,
            FLY_CONFIG.FLY_DIRECTION_CONTINUOUS_BLEND_TIME
        )

        local rawT = math.clamp(
            animState.flyDirectionTransitionTime / FLY_CONFIG.FLY_DIRECTION_CONTINUOUS_BLEND_TIME,
            0,
            1
        )
        -- V191: keep the V190.11 no-snap three-way path, but restore a
        -- response curve closer to V190's normal exponential animation blend.
        -- The reversal still has a fixed 0.45s window, but the directional
        -- handoff starts and settles more like V190 instead of the slower
        -- smoothstep trajectory used by the previous diagnostic versions.
        local responseEnd = 1 - math.exp(
            -FLY_CONFIG.FLY_DIRECTION_CONTINUOUS_BLEND_TIME / FLY_CONFIG.FLY_DIRECTION_REDIRECT_RESPONSE
        )
        local t = 0
        if responseEnd > 0.000001 then
            t = (1 - math.exp(
                -animState.flyDirectionTransitionTime / FLY_CONFIG.FLY_DIRECTION_REDIRECT_RESPONSE
            )) / responseEnd
        end
        t = math.clamp(t, 0, 1)
        if animState.flyIdleGapTransitionActive then
            -- Interpolate from the captured release-gap mix to the requested
            -- direction. This path is isolated from ordinary direct reversals.
            local sourceIdle = animState.flyIdleGapSourceIdle or flyIdleWeight
            local sourceForward = animState.flyIdleGapSourceForward or flyMoveWeight
            local sourceBackward = animState.flyIdleGapSourceBackward or flyBackwardWeight
            local idleTarget = requestedState == "Idle" and 1 or 0
            local forwardTarget = requestedState == "Forward" and 1 or 0
            local backwardTarget = requestedState == "Backward" and 1 or 0
            flyIdleWeight = sourceIdle + (idleTarget - sourceIdle) * t
            flyMoveWeight = sourceForward + (forwardTarget - sourceForward) * t
            flyBackwardWeight = sourceBackward + (backwardTarget - sourceBackward) * t
        else
            local idlePulse = math.sin(math.pi * t) * FLY_CONFIG.FLY_DIRECTION_CONTINUOUS_IDLE_MAX
            local directionalShare = 1 - idlePulse
            local fromWeight = directionalShare * (1 - t)
            local toWeight = directionalShare * t
            flyIdleWeight = idlePulse
            if animState.flyDirectionTransitionFrom == "Forward" then
                flyMoveWeight = fromWeight
                flyBackwardWeight = toWeight
            else
                flyBackwardWeight = fromWeight
                flyMoveWeight = toWeight
            end
        end

        if idle and not idle.IsPlaying then
            idle:Play(0, 1, 1)
        end
        if move and not move.IsPlaying then
            move:Play(0, 1, 1)
        end
        if backward and not backward.IsPlaying then
            backward:Play(0, 1, 1)
        end

        idle:AdjustWeight(flyIdleWeight, 0)
        applyDirectionalWeightWithPhaseGuard(move, "Forward", flyMoveWeight)
        applyDirectionalWeightWithPhaseGuard(backward, "Backward", flyBackwardWeight)

        if rawT >= 1 then
            animState.flyIdleGapTransitionActive = false
            animState.flyIdleGapSourceIdle = nil
            animState.flyIdleGapSourceForward = nil
            animState.flyIdleGapSourceBackward = nil
            animState.flyDirectionTransitionActive = false
            animState.flyDirectionTransitionFrom = nil
            animState.flyDirectionTransitionTo = nil
            animState.flyDirectionTransitionTime = 0

            -- Finish exactly on the requested direction, with no Idle tail.
            flyIdleWeight = 0
            flyMoveWeight = requestedState == "Forward" and 1 or 0
            flyBackwardWeight = requestedState == "Backward" and 1 or 0

            idle:AdjustWeight(0, 0)
            applyDirectionalWeightWithPhaseGuard(move, "Forward", flyMoveWeight)
            applyDirectionalWeightWithPhaseGuard(backward, "Backward", flyBackwardWeight)

        end
    elseif not flyIdleFidget.interruptOwnedThisFrame then
        -- Normal V190 behavior resumes on the frame after handoff ownership ends.
        local idleTarget = requestedState == "Idle" and 1 or 0
        local moveTarget = requestedState == "Forward" and 1 or 0
        local backwardTarget = requestedState == "Backward" and 1 or 0

        local blendAlpha
        if flyStartup.FinalBlendActive then
            -- V191: synchronize the animation crossfade to the SAME physical
            -- launch progress instead of letting Fly Idle ease in independently.
            -- This keeps the Ascend pose continuously moving toward Idle while
            -- the character is rising, so there is no end-of-launch pose snap.
            local launchElapsed = math.max(
                flyStartup.LaunchTime - FLY_CONFIG.FLY_STARTUP_LAUNCH_DELAY,
                0
            )
            local launchP = math.clamp(
                launchElapsed / math.max(FLY_CONFIG.FLY_STARTUP_LAUNCH_DURATION, 0.05),
                0,
                1
            )
            local smoothP = launchP * launchP * (3 - 2 * launchP)

            flyStartup.FinalBlendTime = launchElapsed
            flyIdleWeight = smoothP
            flyMoveWeight = 0
            flyBackwardWeight = 0

            local ascendTrack = flyStartup.AscendTrack
            if ascendTrack then
                pcall(function()
                    ascendTrack:AdjustWeight(1 - smoothP, 0)
                end)
            end

            blendAlpha = 0
        else
            blendAlpha = 1 - math.exp(-deltaTime / 0.18)

            flyIdleWeight = flyIdleWeight
                + (idleTarget - flyIdleWeight) * blendAlpha
            flyMoveWeight = flyMoveWeight
                + (moveTarget - flyMoveWeight) * blendAlpha
            flyBackwardWeight = flyBackwardWeight
                + (backwardTarget - flyBackwardWeight) * blendAlpha
        end

        if flyIdleFidget.active and not flyIdleFidget.interrupting and requestedState == "Idle" and fidget then
            -- Crossfade the active fidget against Fly Idle across its complete
            -- configured source window. Fidget #2 deliberately uses a 1.000s
            -- fade-out, so its different ending pose is already blending toward
            -- the normal Fly Idle pose before the source reaches its final frame.
            flyIdleFidget.elapsed = math.min(
                flyIdleFidget.elapsed + math.max(deltaTime, 0),
                fidgetVariant.duration
            )

            local elapsed = flyIdleFidget.elapsed
            local fidgetWeight = 1

            if elapsed < fidgetVariant.blendIn then
                local p = math.clamp(elapsed / fidgetVariant.blendIn, 0, 1)
                fidgetWeight = p * p * (3 - 2 * p)
            elseif elapsed > fidgetVariant.duration - fidgetVariant.blendOut then
                local p = math.clamp(
                    (fidgetVariant.duration - elapsed) / fidgetVariant.blendOut,
                    0,
                    1
                )
                fidgetWeight = p * p * (3 - 2 * p)
            end

            flyIdleWeight = 1 - fidgetWeight
            flyMoveWeight = 0
            flyBackwardWeight = 0
            flyIdleFidget.currentWeight = fidgetWeight

            pcall(function()
                fidget.TimePosition = fidgetVariant.sourceStart + elapsed
                fidget:AdjustWeight(fidgetWeight, 0)
            end)

            if elapsed >= fidgetVariant.duration then
                flyIdleFidget.active = false
                flyIdleFidget.elapsed = 0
                flyIdleFidget.idleTime = 0
                pcall(function()
                    fidget:AdjustWeight(0, 0)
                    fidget:Stop(0)
                end)
                flyIdleWeight = 1
                flyIdleFidget.currentWeight = 0
            end
        elseif fidget and not flyIdleFidget.active then
            fidget:AdjustWeight(0, 0)
        end

        -- Keep every inactive fidget track fully suppressed. This remains
        -- scalable as additional idle variations are added.
        for _, variant in ipairs(flyIdleFidget.variants) do
            local variantTrack = flyRuntime.Tracks[variant.trackKey]
            if variantTrack and (not flyIdleFidget.active and not flyIdleFidget.interrupting) then
                variantTrack:AdjustWeight(0, 0)
            end
        end

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
        if move then applyDirectionalWeightWithPhaseGuard(move, "Forward", flyMoveWeight) end
        if backward then applyDirectionalWeightWithPhaseGuard(backward, "Backward", flyBackwardWeight) end
    end

    local speedTarget = isMoving
        and math.clamp(moveDirection.Magnitude, 0, 1)
        or 0

    animState.speedBlend += (speedTarget - animState.speedBlend)
        * (1 - math.exp(-deltaTime / 0.16))

    if move and move.IsPlaying and not flyDirectionalPaused.Forward then
        move:AdjustSpeed(
            math.clamp(0.75 + animState.speedBlend * 0.75, 0.75, 1.5)
        )
    end
    if backward and backward.IsPlaying and not flyDirectionalPaused.Backward then
        backward:AdjustSpeed(
            math.clamp(0.80 + animState.speedBlend * 0.60, 0.80, 1.4)
        )
    end
end

local function destroyFlyCollisionDebugShapes()
    for _, debugPart in ipairs(flyCollision.DebugParts) do
        pcall(function()
            debugPart:Destroy()
        end)
    end
    table.clear(flyCollision.DebugParts)

    if flyCollision.DebugFolder then
        pcall(function()
            flyCollision.DebugFolder:Destroy()
        end)
        flyCollision.DebugFolder = nil
    end
end

local function destroyFlyCollisionProxy()
    destroyFlyCollisionDebugShapes()

    if flyCollision.GravityForce then
        pcall(function()
            flyCollision.GravityForce:Destroy()
        end)
        flyCollision.GravityForce = nil
    end

    for _, proxyPart in ipairs(flyCollision.ProxyParts) do
        pcall(function()
            proxyPart:Destroy()
        end)
    end
    table.clear(flyCollision.ProxyParts)

    if flyCollision.Proxy then
        pcall(function()
            flyCollision.Proxy:Destroy()
        end)
        flyCollision.Proxy = nil
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
    flyCollision.Proxy = proxyFolder

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
            proxyPart.CanCollide = not flyGui.NoClipOn
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

            table.insert(flyCollision.ProxyParts, proxyPart)
        end
    end

    flyCollision.UpdateDebug()

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
    flyCollision.GravityForce = vectorForce

    return proxyFolder
end

local function createFlyCollisionDebugShape(proxyPart)
    if not proxyPart or not proxyPart.Parent then
        return nil
    end

    if not flyCollision.DebugFolder then
        flyCollision.DebugFolder = Instance.new("Folder")
        flyCollision.DebugFolder.Name = "VGD_FlyCollisionShapeDebug"
        flyCollision.DebugFolder.Parent = getCharacter() or proxyPart.Parent
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
    debugPart.Parent = flyCollision.DebugFolder

    local weld = Instance.new("WeldConstraint")
    weld.Name = "VGD_CollisionShapeDebugWeld"
    weld.Part0 = proxyPart
    weld.Part1 = debugPart
    weld.Parent = debugPart

    table.insert(flyCollision.DebugParts, debugPart)
    return debugPart
end

flyCollision.UpdateDebug = function()
    if not flyCollision.DebugOn then
        for _, debugPart in ipairs(flyCollision.DebugParts) do
            if debugPart and debugPart.Parent then
                debugPart.Transparency = 1
            end
        end
        return
    end

    -- Rebuild only the visualization. The actual collision proxies remain
    -- completely untouched, so enabling this debug mode cannot alter physics.
    destroyFlyCollisionDebugShapes()

    if not flyCollision.Proxy then
        return
    end

    for _, proxyPart in ipairs(flyCollision.ProxyParts) do
        if proxyPart and proxyPart.Parent then
            local debugPart = createFlyCollisionDebugShape(proxyPart)
            if debugPart then
                debugPart.Transparency = 0.55
            end
        end
    end
end

local function disconnectFlyNoClipWatcher()
    if flyCollision.NoClipDescendantConnection then
        flyCollision.NoClipDescendantConnection:Disconnect()
        flyCollision.NoClipDescendantConnection = nil
    end
end

local function enforceFlyNoClip()
    if not flyGui.NoClipOn then
        return
    end

    -- v57 performance: setFlyNoClip() already caches every character
    -- BasePart in flyCollision.SavedCanCollide and DescendantAdded keeps that cache
    -- current. Iterate the cache instead of scanning the entire character
    -- hierarchy every render frame.
    for instance, _ in pairs(flyCollision.SavedCanCollide) do
        if instance and instance.Parent
            and (not flyCollision.Proxy or not instance:IsDescendantOf(flyCollision.Proxy))
            and instance.CanCollide then
            instance.CanCollide = false
        end
    end

    for _, proxyPart in ipairs(flyCollision.ProxyParts) do
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
        table.clear(flyCollision.SavedCanCollide)
        for _, instance in ipairs(character:GetDescendants()) do
            if instance:IsA("BasePart") and (not flyCollision.Proxy or not instance:IsDescendantOf(flyCollision.Proxy)) then
                flyCollision.SavedCanCollide[instance] = instance.CanCollide
                instance.CanCollide = false
            end
        end

        -- Roblox can create/replace character parts after Fly is already active
        -- (avatar loading, package parts, accessories, tools, etc.). If that
        -- happens, immediately apply No Clip to the new part and remember its
        -- original collision state so disabling No Clip can restore it.
        flyCollision.NoClipDescendantConnection = character.DescendantAdded:Connect(function(instance)
            if not flyGui.NoClipOn then
                return
            end

            if instance:IsA("BasePart") and (not flyCollision.Proxy or not instance:IsDescendantOf(flyCollision.Proxy)) then
                flyCollision.SavedCanCollide[instance] = instance.CanCollide
                instance.CanCollide = false
            end
        end)
    else
        for part, canCollide in pairs(flyCollision.SavedCanCollide) do
            if part and part.Parent then
                part.CanCollide = canCollide
            end
        end
        table.clear(flyCollision.SavedCanCollide)
    end

    for _, proxyPart in ipairs(flyCollision.ProxyParts) do
        if proxyPart and proxyPart.Parent then
            proxyPart.CanCollide = not enabled
        end
    end
end

local function saveCharacterState(humanoid, root)
    flyRuntime.Saved = {
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
    flyRuntime.AnimateScript = animate
    flyRuntime.AnimateScriptDisabled = false
    if animate and (animate:IsA("LocalScript") or animate:IsA("Script")) then
        flyRuntime.AnimateScriptDisabled = animate.Disabled

        -- V169: keep the player's current Roblox idle/emote track alive during
        -- Fly activation. Startup OFF uses it as the source of the smooth
        -- idle -> Fly Idle blend. Startup ON uses it as the source underneath
        -- the reversed Action4 startup emote. Animate is disabled only after
        -- the relevant handoff is ready.
        animate.Disabled = flyRuntime.AnimateScriptDisabled
    end
end

local function restoreCharacterState()
    local saved = flyRuntime.Saved
    flyRuntime.Saved = nil
    stopFlyStartupPoseDriver()
    stopFlyStartupAnimation()
    stopTracks()

    local humanoid, root = getHumanoidAndRoot()
    if saved and saved.humanoid and saved.humanoid.Parent == getCharacter() then humanoid = saved.humanoid end
    if saved and saved.root and saved.root.Parent == getCharacter() then root = saved.root end

    if humanoid then
        humanoid.PlatformStand = saved and saved.platformStand or false
        humanoid.AutoRotate = saved and saved.autoRotate or true
    end

    if flyRuntime.AnimateScript and flyRuntime.AnimateScript.Parent then
        flyRuntime.AnimateScript.Disabled = flyRuntime.AnimateScriptDisabled
    end
    flyRuntime.AnimateScript = nil
    flyRuntime.AnimateScriptDisabled = false
    if root then
        root.Anchored = saved and saved.anchored or false
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end
    animState.currentMoveVector = Vector3.zero
    flyRuntime.Position = nil
end

local flyBodyYaw = 0
-- Preserved body heading across Fly OFF -> ON when Shift Lock is OFF.
local flyHologramMoveBlend = 0
local flyAnimTime = 0

local function shortestAngleDelta(fromAngle, toAngle)
    return math.atan2(math.sin(toAngle - fromAngle), math.cos(toAngle - fromAngle))
end

local function flyCameraIsInDynamicThumbstickArea(position)
    local playerGui = flyServices.Player:FindFirstChildOfClass("PlayerGui")
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
        return flyServices.GuiService:GetGuiObjectsAtPosition(position.X, position.Y)
    end)

    if not ok or not objects then
        return false
    end

    for _, object in ipairs(objects) do
        if object:IsDescendantOf(flyGui.ScreenGui) then
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
    table.clear(flyState.flyCameraTouchStates)
    table.clear(flyState.flyCameraZoomTouchPositions)
    flyState.flyCameraPinchLastDiameter = nil
    flyState.flyCameraTouchDelta = Vector2.new()
    flyState.flyCameraMouseDelta = Vector2.new()
    flyInput.CameraMouseLooking = false
end

local function flyCameraSmoothLook(dt)
    local alpha =
        1 - math.exp(-FLY_CONFIG.FLY_CAMERA_LOOK_SMOOTHNESS * math.max(dt, 0))

    flyState.flyCameraYaw =
        flyState.flyCameraYaw + (flyState.flyCameraTargetYaw - flyState.flyCameraYaw) * alpha

    flyState.flyCameraPitch =
        flyState.flyCameraPitch + (flyState.flyCameraTargetPitch - flyState.flyCameraPitch) * alpha
end

local function flyCameraApplyLookInput()
    local mouseDelta = flyState.flyCameraMouseDelta
    flyState.flyCameraMouseDelta = Vector2.new()

    if mouseDelta.Magnitude > 0 then
        local rotation = Vector2.new(
            mouseDelta.X * FLY_CONFIG.FLY_CAMERA_MOUSE_ROTATION_SPEED.X,
            mouseDelta.Y * FLY_CONFIG.FLY_CAMERA_MOUSE_ROTATION_SPEED.Y
        )

        flyState.flyCameraTargetYaw =
            flyState.flyCameraTargetYaw - rotation.X

        flyState.flyCameraTargetPitch = math.clamp(
            flyState.flyCameraTargetPitch - rotation.Y,
            FLY_CONFIG.FLY_CAMERA_MIN_PITCH,
            FLY_CONFIG.FLY_CAMERA_MAX_PITCH
        )
    end
end

-- During the Fly -> normal-camera handoff, the joystick finger is still physically
-- held. Roblox's CameraModule can see that same TouchInput and interpret its movement
-- as camera-look/pinch input for one or more frames. Block ONLY that already-held
-- joystick InputObject until TouchEnded. Other fingers remain completely available
-- to the normal Roblox camera.
-- v90/v93: camera-handoff lifecycle state. Kept as one early-declared table
-- so all handoff callbacks share the same state without changing behavior.
local flyCameraHandoff = {
    JoystickBlockTouch = nil,
    JoystickBlockConnection = nil,
    Active = false,
    RenderConnection = false,
    QuietFrames = 0,
    SessionId = 0,
    DiedConnection = nil,
}

local function clearFlyJoystickHandoffBlock()
    flyServices.ContextActionService:UnbindAction("VGD_FlyJoystickHandoffBlock")

    if flyCameraHandoff.JoystickBlockConnection then
        pcall(function()
            flyCameraHandoff.JoystickBlockConnection:Disconnect()
        end)
        flyCameraHandoff.JoystickBlockConnection = nil
    end

    flyCameraHandoff.JoystickBlockTouch = nil
end

local function blockFlyJoystickDuringCameraHandoff(touch)
    clearFlyJoystickHandoffBlock()

    if not touch or touch.UserInputType ~= Enum.UserInputType.Touch then
        return
    end

    flyCameraHandoff.JoystickBlockTouch = touch

    local function handoffTouchAction(_, inputState, inputObject)
        if inputObject ~= flyCameraHandoff.JoystickBlockTouch then
            return Enum.ContextActionResult.Pass
        end

        if inputState == Enum.UserInputState.End
            or inputState == Enum.UserInputState.Cancel then
            clearFlyJoystickHandoffBlock()
            return Enum.ContextActionResult.Sink
        end

        -- Sink Begin/Change for the joystick touch so CameraModule cannot
        -- reinterpret the movement as camera rotation or pinch zoom.
        return Enum.ContextActionResult.Sink
    end

    flyServices.ContextActionService:BindActionAtPriority(
        "VGD_FlyJoystickHandoffBlock",
        handoffTouchAction,
        false,
        Enum.ContextActionPriority.High.Value + 1,
        Enum.UserInputType.Touch
    )

    flyCameraHandoff.JoystickBlockConnection = flyServices.UserInputService.TouchEnded:Connect(function(inputObject)
        if inputObject == flyCameraHandoff.JoystickBlockTouch then
            clearFlyJoystickHandoffBlock()
        end
    end)
end

local function disconnectFlyCameraInput()
    flyServices.ContextActionService:UnbindAction("VGD_FlyCameraTouch")

    for _, connection in pairs(flyInput.CameraConnections) do
        pcall(function()
            connection:Disconnect()
        end)
    end

    table.clear(flyInput.CameraConnections)
    flyCameraResetInput()
    flyState.flyCameraPinchLastDiameter = nil
    table.clear(flyState.flyCameraZoomTouchPositions)
end

local function connectFlyCameraInput()
    disconnectFlyCameraInput()

    -- Match Freecam's proven mobile touch architecture exactly.
    -- ContextActionService owns world touches, and the same touch table is
    -- used to detect a two-finger pinch because the touch action consumes
    -- the touches before UserInputService.TouchPinch can be relied on.
    local touchAction = function(_, inputState, inputObject)
        if (not flyRuntime.Enabled and not flyCameraHandoff.Active)
            or inputObject.UserInputType ~= Enum.UserInputType.Touch then
            return Enum.ContextActionResult.Pass
        end

        if flyInput.SpectatingOtherPlayer then
            return Enum.ContextActionResult.Pass
        end

        if inputState == Enum.UserInputState.Begin then
            -- The mobile joystick is a separate input stream. If the player
            -- keeps the joystick held while using a second finger to look
            -- around, NEVER let that joystick touch enter the camera's pinch
            -- table. Otherwise the camera sees the joystick + look finger as
            -- a two-finger pinch and changes zoom instead of yaw/pitch.
            local isJoystickTouch = inputObject == flyJoystick.Touch
                or flyCameraIsInDynamicThumbstickArea(inputObject.Position)

            if isJoystickTouch or flyCameraIsOverGui(inputObject.Position) then
                return Enum.ContextActionResult.Pass
            end

            flyState.flyCameraTouchStates[inputObject] = true
            flyState.flyCameraZoomTouchPositions[inputObject] = inputObject.Position

            local zoomTouchCount = 0
            local firstZoomPosition = nil
            local secondZoomPosition = nil
            for _, position in pairs(flyState.flyCameraZoomTouchPositions) do
                zoomTouchCount += 1
                if not firstZoomPosition then
                    firstZoomPosition = position
                elseif not secondZoomPosition then
                    secondZoomPosition = position
                end
            end

            if zoomTouchCount >= 2 then
                flyState.flyCameraPinchLastDiameter =
                    (firstZoomPosition - secondZoomPosition).Magnitude
            end

            return Enum.ContextActionResult.Sink
        end

        if flyState.flyCameraTouchStates[inputObject] then
            -- Defensive cleanup for the rare case where Roblox reuses an
            -- InputObject/state during a joystick transition. The joystick
            -- must never participate in camera pinch detection.
            if inputObject == flyJoystick.Touch
                or flyCameraIsInDynamicThumbstickArea(inputObject.Position) then
                flyState.flyCameraTouchStates[inputObject] = nil
                flyState.flyCameraZoomTouchPositions[inputObject] = nil
                local remaining = 0
                for _ in pairs(flyState.flyCameraZoomTouchPositions) do
                    remaining += 1
                end
                if remaining < 2 then
                    flyState.flyCameraPinchLastDiameter = nil
                end
                return Enum.ContextActionResult.Pass
            end

            if inputState == Enum.UserInputState.Change then
                flyState.flyCameraZoomTouchPositions[inputObject] = inputObject.Position

                local zoomTouchCount = 0
                local firstZoomPosition = nil
                local secondZoomPosition = nil
                for _, position in pairs(flyState.flyCameraZoomTouchPositions) do
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

                    if flyState.flyCameraPinchLastDiameter then
                        local pinchDelta =
                            diameter - flyState.flyCameraPinchLastDiameter
                        local zoomDelta = -pinchDelta * 0.04
                        local currentZoom = flyState.flyCameraTargetZoomDistance
                        local newZoom

                        if zoomDelta > 0 then
                            newZoom = currentZoom
                                + zoomDelta * (1 + currentZoom * 0.5)
                        else
                            newZoom = (currentZoom + zoomDelta)
                                / (1 - zoomDelta * 0.5)
                        end

                        flyState.flyCameraTargetZoomDistance = math.clamp(
                            newZoom,
                            FLY_CONFIG.FLY_CAMERA_ZOOM_MIN,
                            FLY_CONFIG.FLY_CAMERA_ZOOM_MAX
                        )
                    end

                    flyState.flyCameraPinchLastDiameter = diameter
                    return Enum.ContextActionResult.Sink
                end

                local delta = inputObject.Delta
                if delta.Magnitude > 0 then
                    delta = flyCameraAdjustTouchPitchSensitivity(delta)
                    local rotation = Vector2.new(
                        delta.X * FLY_CONFIG.FLY_CAMERA_TOUCH_ROTATION_SPEED.X,
                        delta.Y * FLY_CONFIG.FLY_CAMERA_TOUCH_ROTATION_SPEED.Y
                    )
                    flyState.flyCameraTargetYaw = flyState.flyCameraTargetYaw - rotation.X
                    flyState.flyCameraTargetPitch = math.clamp(
                        flyState.flyCameraTargetPitch - rotation.Y,
                        FLY_CONFIG.FLY_CAMERA_MIN_PITCH,
                        FLY_CONFIG.FLY_CAMERA_MAX_PITCH
                    )
                end
                return Enum.ContextActionResult.Sink
            end

            if inputState == Enum.UserInputState.End
                or inputState == Enum.UserInputState.Cancel then
                flyState.flyCameraTouchStates[inputObject] = nil
                flyState.flyCameraZoomTouchPositions[inputObject] = nil

                local zoomTouchCount = 0
                for _ in pairs(flyState.flyCameraZoomTouchPositions) do
                    zoomTouchCount += 1
                end
                if zoomTouchCount < 2 then
                    flyState.flyCameraPinchLastDiameter = nil
                end

                return Enum.ContextActionResult.Sink
            end

            return Enum.ContextActionResult.Sink
        end

        return Enum.ContextActionResult.Pass
    end

    flyServices.ContextActionService:BindActionAtPriority(
        "VGD_FlyCameraTouch",
        touchAction,
        false,
        Enum.ContextActionPriority.High.Value,
        Enum.UserInputType.Touch
    )

    flyInput.CameraConnections.TouchEnded = flyServices.UserInputService.TouchEnded:Connect(function(input)
        flyState.flyCameraTouchStates[input] = nil
        flyState.flyCameraZoomTouchPositions[input] = nil

        local zoomTouchCount = 0
        for _ in pairs(flyState.flyCameraZoomTouchPositions) do
            zoomTouchCount += 1
        end
        if zoomTouchCount < 2 then
            flyState.flyCameraPinchLastDiameter = nil
        end
    end)

    -- Desktop: same right-mouse drag behavior as Freecam.
    flyInput.CameraConnections.MouseBegan =
        flyServices.UserInputService.InputBegan:Connect(function(
            input,
            gameProcessedEvent
        )
            if (not flyRuntime.Enabled and not flyCameraHandoff.Active) or flyInput.SpectatingOtherPlayer or gameProcessedEvent then
                return
            end

            if input.UserInputType == Enum.UserInputType.MouseButton2 then
                flyInput.CameraMouseLooking = true
            end
        end)

    flyInput.CameraConnections.MouseChanged =
        flyServices.UserInputService.InputChanged:Connect(function(input)
            if (not flyRuntime.Enabled and not flyCameraHandoff.Active) or flyInput.SpectatingOtherPlayer or not flyInput.CameraMouseLooking then
                return
            end

            if input.UserInputType == Enum.UserInputType.MouseMovement then
                flyState.flyCameraMouseDelta += input.Delta
            end
        end)

    flyInput.CameraConnections.MouseEnded =
        flyServices.UserInputService.InputEnded:Connect(function(input)
            if input.UserInputType == Enum.UserInputType.MouseButton2 then
                flyInput.CameraMouseLooking = false
            end
        end)

    -- Match Freecam's desktop zoom exactly.
    flyInput.CameraConnections.MouseWheel = flyServices.UserInputService.InputChanged:Connect(function(input)
        if (not flyRuntime.Enabled and not flyCameraHandoff.Active) or flyInput.SpectatingOtherPlayer then
            return
        end

        if input.UserInputType == Enum.UserInputType.MouseWheel then
            local wheel = input.Position.Z

            if wheel ~= 0 then
                local zoomDelta = -wheel
                local currentZoom = flyState.flyCameraTargetZoomDistance
                local newZoom

                if zoomDelta > 0 then
                    newZoom = currentZoom
                        + zoomDelta * (1 + currentZoom * 0.5)
                else
                    newZoom = (currentZoom + zoomDelta)
                        / (1 - zoomDelta * 0.5)
                end

                flyState.flyCameraTargetZoomDistance = math.clamp(
                    newZoom,
                    FLY_CONFIG.FLY_CAMERA_ZOOM_MIN,
                    FLY_CONFIG.FLY_CAMERA_ZOOM_MAX
                )
            end
        end
    end)

end

-- Mirror Roblox CameraModule's living-Humanoid subject point instead of
-- using HumanoidRootPart.Position directly. CameraModule follows a point
-- above the root (plus Humanoid.CameraOffset), and that vertical offset is
-- exactly what makes the apparent exit distance depend on camera pitch.
local function getRobloxCameraSubjectPosition(humanoid, root)
    if not humanoid or not root or not root:IsA("BasePart") then
        return root and root.Position or Vector3.zero
    end

    local heightOffset

    if humanoid.RigType == Enum.HumanoidRigType.R15 then
        if humanoid.AutomaticScalingEnabled then
            heightOffset = Vector3.new(0, 1.5, 0)

            -- Current Roblox CameraModule adds this root-size correction when
            -- the root is the body part being followed. Mirror that behavior
            -- so scaled R15 avatars use the same camera subject height.
            local rootPartSizeOffset = (root.Size.Y - 2) / 2
            heightOffset += Vector3.new(0, rootPartSizeOffset, 0)
        else
            heightOffset = Vector3.new(0, 2, 0)
        end
    else
        -- R6 CameraModule subject height.
        heightOffset = Vector3.new(0, 1.5, 0)
    end

    return root.CFrame:PointToWorldSpace(heightOffset + humanoid.CameraOffset)
end

local function getFlyCameraCFrame(subjectPosition)
    local cameraLookCFrame =
        CFrame.new(subjectPosition) *
        CFrame.Angles(0, flyState.flyCameraYaw, 0) *
        CFrame.Angles(flyState.flyCameraPitch, 0, 0)

    local cameraLook = cameraLookCFrame.LookVector
    local cameraUp = cameraLookCFrame.UpVector

    -- The lateral/shoulder offset is intentionally zero. Preserve only the
    -- normal camera's vertical framing, expressed along the camera's own
    -- UpVector so rotating the camera cannot introduce a world-space offset
    -- that makes the body drift or twitch.
    local cameraPosition =
        subjectPosition
        - cameraLook * flyState.flyCameraZoomDistance
        + cameraUp * flyState.flyCameraVerticalOffset

    return CFrame.lookAt(cameraPosition, cameraPosition + cameraLook, cameraUp)
end

local function syncRobloxCameraZoomState(distance)
    if not distance or flyInput.SpectatingOtherPlayer then return end

    -- Keep Roblox CameraModule's own nominal zoom distance synchronized
    -- while Fly is active. CameraModule stores currentSubjectDistance
    -- separately from Camera.CFrame, so merely moving the Scriptable camera
    -- cannot teach the normal camera about Fly's zoom. Using matching limits
    -- forces CameraModule to clamp its internal distance to the live Fly
    -- distance. The limits are restored on Fly exit.
    local clamped = math.clamp(
        distance,
        0.5,
        40
    )

    if not flyCameraSaved.MinZoom or not flyCameraSaved.MaxZoom then
        return
    end

    if math.abs(flyServices.Player.CameraMinZoomDistance - clamped) > 0.02
        or math.abs(flyServices.Player.CameraMaxZoomDistance - clamped) > 0.02 then
        flyServices.Player.CameraMinZoomDistance = clamped
        flyServices.Player.CameraMaxZoomDistance = clamped
    end
end

local function computeFlyCameraVisualState(moveVector, currentSpeed, dt, cameraSubjectPosition)
    -- Kept separate from updateFly() so the large flight loop does not hit
    -- Luau's local-register limit. Camera behavior itself is unchanged.
    local cameraPosition = nil
    local cameraRotation = nil

    if flyGui.CameraFeelOn then
        local horizontalVelocity = Vector3.new(moveVector.X, 0, moveVector.Z)
        local cameraLagTarget = Vector3.zero

        if horizontalVelocity.Magnitude > 0.001 then
            local speedRatio = math.clamp(currentSpeed, 0, 1)
            local travelDirection = horizontalVelocity.Unit
            cameraLagTarget = -travelDirection * (FLY_CONFIG.FLY_CAMERA_MAX_LAG * speedRatio)

            cameraLagTarget *= 1
                + flyState.flyAccelerationBlend * 0.18
                + flyState.flyDecelerationBlend * 0.08
        end

        local cameraLagAlpha = 1 - math.exp(-FLY_CONFIG.FLY_CAMERA_MOMENTUM_SMOOTHNESS * dt)
        flyState.flyCameraVelocityBlend = flyState.flyCameraVelocityBlend
            + (cameraLagTarget - flyState.flyCameraVelocityBlend) * cameraLagAlpha

        local cameraYawDelta = flyState.flyCameraLastYaw
            and shortestAngleDelta(flyState.flyCameraLastYaw, flyState.flyCameraYaw)
            or 0
        flyState.flyCameraLastYaw = flyState.flyCameraYaw

        local turnLagTarget = math.clamp(
            -cameraYawDelta / math.max(dt, 1 / 240) * 0.006,
            math.rad(-1.8),
            math.rad(1.8)
        )
        flyState.flyCameraTurnLag = flyState.flyCameraTurnLag
            + (turnLagTarget - flyState.flyCameraTurnLag)
            * (1 - math.exp(-dt / 0.09))

        local baseCameraCFrame = getFlyCameraCFrame(cameraSubjectPosition)
        cameraPosition = baseCameraCFrame.Position + flyState.flyCameraVelocityBlend
        cameraRotation =
            CFrame.lookAt(
                Vector3.zero,
                baseCameraCFrame.LookVector,
                baseCameraCFrame.UpVector
            ).Rotation
            * CFrame.Angles(0, 0, flyState.flyCameraTurnLag)

        local speedFOVTarget = math.clamp(currentSpeed, 0, 1)
            * FLY_CONFIG.FLY_CAMERA_FOV_MAX_BOOST
        flyState.flyCameraFOVBlend = flyState.flyCameraFOVBlend
            + (speedFOVTarget - flyState.flyCameraFOVBlend)
            * (1 - math.exp(-dt / 0.20))
    else
        flyState.flyCameraVelocityBlend = Vector3.zero
        flyState.flyCameraTurnLag = 0
        flyState.flyCameraFOVBlend = 0
        flyState.flyCameraLastYaw = flyState.flyCameraYaw

        local baseCameraCFrame = getFlyCameraCFrame(cameraSubjectPosition)
        cameraPosition = baseCameraCFrame.Position
        cameraRotation = baseCameraCFrame.Rotation
    end

    return cameraPosition, cameraRotation
end

local function updateFly(deltaTime)
    local frame = {}
    if not flyRuntime.Enabled then return end

    local humanoid, root = getHumanoidAndRoot()
    local cam = workspace.CurrentCamera
    if not humanoid or not root or not cam then return end

    -- This is the same subject point that Roblox CameraModule uses for the
    -- local living Humanoid. Fly camera geometry and Camera.Focus must use
    -- this point, not the root pivot, so pitch cannot create an artificial
    -- zoom change when CameraModule resumes control.
    frame.cameraSubjectPosition = getRobloxCameraSubjectPosition(humanoid, root)

    -- v61: allow external spectate systems to own the camera while Fly stays
    -- enabled. Roblox's normal/spectate camera uses CameraSubject, so Fly must
    -- not overwrite Camera.CFrame when the subject is another player's
    -- character. When spectating ends, resume Fly from the camera orientation
    -- the player is actually looking at instead of the pre-Fly orientation.
    frame.cameraSubject = cam.CameraSubject
    frame.subjectCharacter = frame.cameraSubject and frame.cameraSubject.Parent
    frame.subjectPlayer = frame.subjectCharacter
        and flyServices.Players:GetPlayerFromCharacter(frame.subjectCharacter)
    frame.spectatingOtherPlayer = frame.subjectPlayer ~= nil and frame.subjectPlayer ~= flyServices.Player

    if frame.spectatingOtherPlayer then
        if not flyInput.SpectatingOtherPlayer then
            flyCameraResetInput()
            table.clear(flyState.flyCameraTouchStates)
            table.clear(flyState.flyCameraZoomTouchPositions)
            flyState.flyCameraPinchLastDiameter = nil
        end
        flyInput.SpectatingOtherPlayer = true
    elseif flyInput.SpectatingOtherPlayer then
        -- The spectate target has been released. The CameraModule has now
        -- returned the camera to our character; adopt its current orientation
        -- before Fly takes Scriptable ownership back.
        flyInput.SpectatingOtherPlayer = false
        frame.resumePitch, frame.resumeYaw = cam.CFrame:ToOrientation()
        flyState.flyCameraPitch = frame.resumePitch
        flyState.flyCameraYaw = frame.resumeYaw
        flyState.flyCameraTargetPitch = frame.resumePitch
        flyState.flyCameraTargetYaw = frame.resumeYaw

        frame.resumeSubjectPosition = getRobloxCameraSubjectPosition(humanoid, root)
        frame.resumeDistance = (cam.CFrame.Position - frame.resumeSubjectPosition):Dot(-cam.CFrame.LookVector)
        if frame.resumeDistance <= 0.01 then
            frame.resumeDistance = (cam.CFrame.Position - frame.resumeSubjectPosition).Magnitude
        end
        flyState.flyCameraZoomDistance = math.clamp(
            frame.resumeDistance,
            FLY_CONFIG.FLY_CAMERA_ZOOM_MIN,
            FLY_CONFIG.FLY_CAMERA_ZOOM_MAX
        )
        flyState.flyCameraTargetZoomDistance = flyState.flyCameraZoomDistance
        flyState.flyCameraLastYaw = nil
        flyState.flyCameraVelocityBlend = Vector3.zero
        flyState.flyCameraTurnLag = 0
        flyState.flyCameraFOVBlend = 0
        cam.CameraType = Enum.CameraType.Custom
    end

    -- Apply the same smooth target->current zoom interpolation used by
    -- Freecam. v28 updated flyState.flyCameraTargetZoomDistance correctly, but it
    -- never copied that target into flyState.flyCameraZoomDistance, so the camera
    -- stayed at the original distance forever.
    frame.zoomAlpha = 1 - math.exp(-14 * math.max(deltaTime, 0))
    flyState.flyCameraZoomDistance = flyState.flyCameraZoomDistance
        + (flyState.flyCameraTargetZoomDistance - flyState.flyCameraZoomDistance) * frame.zoomAlpha

    syncRobloxCameraZoomState(flyState.flyCameraZoomDistance)

    -- No Clip is authoritative while enabled. Re-assert the state every
    -- render frame so a transient Roblox physics/avatar update cannot leave
    -- one body part or collision proxy collidable for a frame. The actual
    -- v21 physics collision system is untouched when No Clip is OFF.
    enforceFlyNoClip()

    frame.dt = math.max(deltaTime or 0, 0)
    if not flyRuntime.Position then
        flyRuntime.Position = root.Position
    end

    -- ================================================================
    -- FLY STARTUP / SUPERHERO TAKEOFF
    -- ================================================================
    local startupPitch = 0
    local startupFrame = flyStartup.Active or flyStartup.LaunchActive
    local t = 0
    if flyStartup.Active then
        flyStartup.Time += frame.dt
        t = math.clamp(
            flyStartup.Time / math.max(flyStartup.Duration, 0.001),
            0,
            1
        )
    end

    -- V191: the landing animation owns the 0.00 -> 0.90s crouch. The
    -- dedicated ascend animation uses only its first 4.00s over 0.60s.
    -- From 1.40s -> 2.00s, the physical rise and Ascend -> Fly Idle crossfade
    -- share one normalized progress value so the character reaches the top
    -- already blended into Fly Idle instead of holding the Ascend pose first.
    local startupOffset = 0
    if flyStartup.LaunchActive and flyStartup.StartPosition then
        -- 0.90 -> 1.40s: ascend animation owns the pose; stay grounded.
        -- 1.40 -> 2.00s: begin the physical lift and crossfade to Fly Idle.
        local elapsed = flyStartup.LaunchTime
        if elapsed >= FLY_CONFIG.FLY_STARTUP_LAUNCH_DELAY then
            local p = math.clamp(
                (elapsed - FLY_CONFIG.FLY_STARTUP_LAUNCH_DELAY)
                    / math.max(FLY_CONFIG.FLY_STARTUP_LAUNCH_DURATION, 0.05),
                0,
                1
            )
            local eased = 1 - (1 - p) ^ 3
            startupOffset = flyStartup.Height * eased

            if flyStartup.Active then
                flyStartup.Active = false
                flyStartup.FinalBlendActive = true
                flyStartup.FinalBlendTime = 0
                startNormalFlyAnimationSet(true)

                -- The dedicated Ascend track stays fully continuous here.
                -- V191 fades it by the same normalized progress used for the
                -- physical rise, rather than scheduling a separate delayed
                -- fade at the top.
                local ascendTrack = flyStartup.AscendTrack
                if ascendTrack then
                    pcall(function() ascendTrack:AdjustWeight(1, 0) end)
                end
            end
        end

        flyStartup.LaunchTime += frame.dt
        if flyStartup.LaunchTime >= FLY_CONFIG.FLY_STARTUP_LAUNCH_DELAY + FLY_CONFIG.FLY_STARTUP_LAUNCH_DURATION then
            flyStartup.LaunchActive = false
            flyStartup.LaunchTime = 0
            flyStartup.FinalBlendActive = false
            flyStartup.FinalBlendTime = 0
            flyStartup.StartPosition = nil
            local ascendTrack = flyStartup.AscendTrack
            flyStartup.AscendTrack = nil
            if flyStartup.AscendStoppedConnection then
                flyStartup.AscendStoppedConnection:Disconnect()
                flyStartup.AscendStoppedConnection = nil
            end
            if ascendTrack then
                pcall(function() ascendTrack:AdjustSpeed(0) end)
                -- The weight has already reached zero through the synchronized
                -- launch crossfade. Stop only after the blend has completed.
                pcall(function() ascendTrack:AdjustWeight(0, 0) end)
                task.delay(0.05, function()
                    pcall(function() ascendTrack:Stop(0) end)
                    pcall(function() ascendTrack:Destroy() end)
                end)
            end
        end
    elseif flyStartup.Active and flyStartup.AnimationReady then
        -- During the 0.60s visual blend and the short asset section, stay grounded.
        startupOffset = 0
    end

    if startupFrame and flyStartup.StartPosition then
        flyRuntime.Position = flyStartup.StartPosition
            + Vector3.new(0, startupOffset, 0)
    end

    if startupFrame then
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end

    if flyStartup.Active and flyJointDiagnostic.Active and flyJointDiagnostic.Time >= flyJointDiagnostic.Duration then
            stopFlyJointDiagnostic()
            flyStartup.Active = false
            flyStartup.Time = 0
            flyStartup.StartPosition = nil
            stopFlyStartupPoseDriver()
            clearFlyStartupPose()
            clearStartupAnimatorSuppression()
            startNormalFlyAnimationSet()
        elseif flyStartup.Active and t >= 1 and not flyJointDiagnostic.Active and not flyStartup.AssetActive then
            -- V181: normal startup completion is handled by
            -- finishFlyStartupAnimation(). This branch remains only for the
            -- legacy diagnostic/procedural path.
            flyStartup.Active = false
            flyStartup.Time = 0
            flyStartup.StartPosition = nil
            stopFlyStartupPoseDriver()
            clearFlyStartupPose()
            clearStartupAnimatorSuppression()
            startNormalFlyAnimationSet()
        end

    -- ================================================================
    -- THIS IS THE FREECAM HOLOGRAM FLIGHT ALGORITHM, PORTED DIRECTLY.
    -- The hologram's PivotTo() is replaced only by root.CFrame = ... .
    -- No velocity flight, no physics smoothing, no separate body steering.
    -- ================================================================

    -- The Fly now owns the camera exactly like Freecam. Look input has
    -- already been consumed/smoothed for this render frame, so movement is
    -- derived from Fly's own camera orientation instead of Roblox CameraModule.
    -- V113: body heading is driven by Fly's own camera input state, not by
    -- reading CameraModule's resulting CFrame. This breaks the mobile
    -- Shift-Lock camera <-> HRP feedback loop that caused the vibration.
    flyCameraApplyLookInput()
    flyCameraSmoothLook(frame.dt)

    frame.cameraLookCFrame =
        CFrame.new(flyRuntime.Position) *
        CFrame.Angles(0, flyState.flyCameraYaw, 0) *
        CFrame.Angles(flyState.flyCameraPitch, 0, 0)
    frame.cameraLook = frame.cameraLookCFrame.LookVector
    frame.cameraRight = frame.cameraLookCFrame.RightVector
    -- Get the actual current joystick/controller vector directly.
    -- PlatformStand can make Humanoid.MoveDirection drop to zero for the
    -- transition frame when Fly is enabled while the player is already walking.
    -- PlayerModule:GetMoveVector() preserves the held joystick state.
    frame.moveDirection, frame.isRawControlVector = getFlyMoveVector(humanoid)

    frame.horizontalLook = Vector3.new(frame.cameraLook.X, 0, frame.cameraLook.Z)
    frame.horizontalRight = Vector3.new(frame.cameraRight.X, 0, frame.cameraRight.Z)

    if frame.horizontalLook.Magnitude > 0.001 then
        frame.horizontalLook = frame.horizontalLook.Unit
    else
        frame.horizontalLook = Vector3.new(0, 0, -1)
    end

    if frame.horizontalRight.Magnitude > 0.001 then
        frame.horizontalRight = frame.horizontalRight.Unit
    else
        frame.horizontalRight = Vector3.new(1, 0, 0)
    end

    frame.forwardInput = nil
    frame.rightInput = nil
    if frame.isRawControlVector then
        -- PlayerModule input: X = right, Z = backward.
        -- Convert it into camera-relative world movement once.
        frame.forwardInput = math.clamp(-frame.moveDirection.Z, -1, 1)
        frame.rightInput = math.clamp(frame.moveDirection.X, -1, 1)
    else
        -- Humanoid.MoveDirection fallback: already world-space.
        frame.horizontalMove = Vector3.new(frame.moveDirection.X, 0, frame.moveDirection.Z)
        frame.forwardInput = math.clamp(frame.horizontalMove:Dot(frame.horizontalLook), -1, 1)
        frame.rightInput = math.clamp(frame.horizontalMove:Dot(frame.horizontalRight), -1, 1)
    end

    frame.moveVector =
        (frame.cameraLook * frame.forwardInput) +
        (frame.horizontalRight * frame.rightInput)

    if frame.moveVector.Magnitude > 1 then
        frame.moveVector = frame.moveVector.Unit
    end

    -- Keep a world-space horizontal movement vector available for the
    -- Shift Lock OFF body-heading logic below. In the raw PlayerModule
    -- input path, the old code only created `frame.horizontalMove` inside the
    -- fallback branch, so disabling Shift Lock left it nil and caused the
    -- render loop to error before updating the camera/body.
    frame.horizontalMove = Vector3.new(frame.moveVector.X, 0, frame.moveVector.Z)

    -- A held joystick must not cancel the takeoff. The live control vector is
    -- consumed normally as soon as the startup state finishes.
    if flyStartup.Active then
        frame.moveVector = Vector3.zero
        frame.horizontalMove = Vector3.zero
    end

    -- The real-body Fly follows the same camera-pitch flight as the hologram.
    -- Space/Ctrl remains an optional extra vertical input, but the normal
    -- flight path itself is entirely driven by joystick + camera look.
    if math.abs(flyRuntime.VerticalInput) > 0.001 then
        frame.moveVector = frame.moveVector + Vector3.new(0, flyRuntime.VerticalInput, 0)
        if frame.moveVector.Magnitude > 1 then
            frame.moveVector = frame.moveVector.Unit
        end
    end

    frame.isMoving = frame.moveVector.Magnitude > 0.05
    if flyStartup.Active then
        frame.isMoving = false
    end

    -- ================================================================
    -- v57 FLIGHT DYNAMICS / MOMENTUM VISUALS
    -- ================================================================
    -- These values are visual response layers. The actual movement vector and
    -- position integration remain exactly v56.
    frame.currentSpeed = frame.moveVector.Magnitude
    frame.speedDelta = frame.currentSpeed - flyState.flyPreviousSpeed
    frame.speedDeltaAlpha = 1 - math.exp(-frame.dt / 0.09)

    frame.accelerationTarget = math.clamp(math.max(frame.speedDelta, 0) * 5, 0, 1)
    frame.decelerationTarget = math.clamp(math.max(-frame.speedDelta, 0) * 5, 0, 1)

    flyState.flyAccelerationBlend = flyState.flyAccelerationBlend
        + (frame.accelerationTarget - flyState.flyAccelerationBlend) * frame.speedDeltaAlpha
    flyState.flyDecelerationBlend = flyState.flyDecelerationBlend
        + (frame.decelerationTarget - flyState.flyDecelerationBlend) * frame.speedDeltaAlpha

    frame.directionChangeTarget = 0
    if frame.isMoving and flyState.flyPreviousMoveDirection.Magnitude > 0.05 then
        frame.previousUnit = flyState.flyPreviousMoveDirection.Unit
        frame.currentUnit = frame.moveVector.Unit
        frame.directionDot = math.clamp(frame.previousUnit:Dot(frame.currentUnit), -1, 1)
        frame.directionChangeTarget = math.clamp((1 - frame.directionDot) * 0.85, 0, 1)
    end

    frame.directionChangeAlpha = 1 - math.exp(-frame.dt / 0.075)
    flyState.flyDirectionChangeBlend = flyState.flyDirectionChangeBlend
        + (frame.directionChangeTarget - flyState.flyDirectionChangeBlend) * frame.directionChangeAlpha

    -- Keep the previous movement vector alive until the procedural pose has
    -- consumed it below. This is what makes v57's frame.direction-change reaction
    -- compare the actual previous frame against the current frame.
    flyState.flyPreviousSpeed = frame.currentSpeed

    -- ================================================================
    -- PHYSICS-DRIVEN POSITION / REAL COLLISION
    -- ================================================================
    -- No Clip OFF uses the exact v21 individual body-part collision proxies
    -- and real assembly velocity. The physics solver owns translation here.
    --
    -- V238 base behavior: restore the V234-tested selection after the V235
    -- NoClip regression. CFrame + NoClip ON uses manual position; Normal uses
    -- physics-driven translation. CFrame + NoClip OFF retains the legacy
    -- physics path. Collision and movement are therefore not fully orthogonal.
    local useManualPosition = startupFrame or (flyGui.MovementMode == "CFrame" and flyGui.NoClipOn)
    if useManualPosition then
        if flyCollision.GravityForce and flyCollision.GravityForce.Parent then
            flyCollision.GravityForce.Force = Vector3.zero
        end

        if not startupFrame then
            flyRuntime.Position = flyRuntime.Position + frame.moveVector * flyRuntime.Speed * frame.dt
        end
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    else
        if flyCollision.GravityForce and flyCollision.GravityForce.Parent then
            flyCollision.GravityForce.Force = Vector3.new(
                0,
                root.AssemblyMass * workspace.Gravity,
                0
            )
        end

        if flyGui.MovementMode == "Normal" and flyRuntime.NormalVelocityAlign then
            flyRuntime.NormalVelocityAlign.Enabled = not startupFrame
            flyRuntime.NormalVelocityTarget = startupFrame and Vector3.zero or (frame.moveVector * flyRuntime.Speed)
        else
            root.AssemblyLinearVelocity = frame.moveVector * flyRuntime.Speed
        end

        -- The physics solver owns the position in No Clip OFF mode.
        flyRuntime.Position = root.Position
    end

    -- ================================================================
    -- EXACT HOLOGRAM BASE CFRAME
    -- ================================================================
    -- ================================================================
    -- EXACT HOLOGRAM HEADING / TURN BANK
    -- ================================================================
    -- Shift Lock ON  = body follows camera yaw.
    -- Shift Lock OFF = body follows the horizontal movement frame.direction.
    --
    -- IMPORTANT: build the actual body base CFrame from flyBodyYaw. The old
    -- v11 code built it directly from camera look, so the body continued to
    -- face the camera even after the button was switched OFF.
    -- Match Freecam exactly:
    -- Shift Lock ON  -> body follows the camera yaw.
    -- Shift Lock OFF -> camera yaw is completely ignored unless the player
    -- is actually moving; while stationary, keep the current body heading.
    frame.desiredFlightYaw = flyBodyYaw or 0
    if flyGui.ShiftLockOn then
        frame.desiredFlightYaw = flyState.flyCameraYaw
    elseif frame.horizontalMove.Magnitude > 0.001 and frame.isMoving then
        frame.movementUnit = frame.horizontalMove.Unit
        frame.desiredFlightYaw = math.atan2(-frame.movementUnit.X, -frame.movementUnit.Z)
    end

    frame.yawDelta = shortestAngleDelta(flyBodyYaw or 0, frame.desiredFlightYaw)
    if flyGui.MovementMode == "Normal" and flyGui.ShiftLockOn then
        -- Normal-only experiment: bypass software yaw smoothing; physics gyro
        -- remains responsible for rotating the assembly toward this target.
        flyBodyYaw = frame.desiredFlightYaw
    else
        -- Restore V235 yaw timing for CFrame and Normal Shift Lock OFF.
        -- Keep the direct-yaw experiment scoped to Normal + Shift Lock ON only.
        frame.yawDuration = (frame.isMoving and not flyGui.ShiftLockOn) and 0.14 or 0.06
        frame.yawAlpha = 1 - math.exp(-frame.dt / frame.yawDuration)
        flyBodyYaw = (flyBodyYaw or 0) + frame.yawDelta * frame.yawAlpha
    end

    -- Now that flyBodyYaw has been smoothed, use it as the character's actual
    -- horizontal facing. Camera yaw remains independent from body yaw when
    -- Shift Lock is OFF.
    frame.bodyLook = Vector3.new(
        -math.sin(flyBodyYaw),
        0,
        -math.cos(flyBodyYaw)
    )
    frame.baseCFrame = CFrame.lookAt(
        flyRuntime.Position,
        flyRuntime.Position + frame.bodyLook,
        Vector3.new(0, 1, 0)
    )

    -- Pose/lean directions still use the CAMERA's horizontal look, exactly
    -- like Freecam. Only the body's YAW is decoupled when Shift Lock is off.
    frame.flatLook = frame.horizontalLook

    -- H1 banking behavior: snapshot the live previous desired yaw before
    -- calculating the turn delta. H2 incorrectly replaced this local with
    -- animState.previousDesiredYaw without ever updating that field, which
    -- made desiredYawDelta stay zero and disabled banking.
    local previousDesiredYaw = bankingState.PreviousDesiredYaw
    frame.desiredYawDelta = previousDesiredYaw
        and shortestAngleDelta(previousDesiredYaw, frame.desiredFlightYaw)
        or 0
    bankingState.PreviousDesiredYaw = frame.desiredFlightYaw

    -- Turn bank: filter the actual heading change before converting it into
    -- roll. This keeps the real body from snapping into a bank when the camera
    -- turns quickly, while still letting the bank build naturally during a
    -- sustained turn and recover smoothly when the turn stops.
    frame.rawTurnRate = frame.desiredYawDelta / math.max(frame.dt, 1 / 240)
    frame.turnRateDuration = frame.isMoving and 0.075 or 0.16
    frame.turnRateAlpha = 1 - math.exp(-frame.dt / frame.turnRateDuration)
    bankingState.FlightTurnRateBlend = bankingState.FlightTurnRateBlend
        + (frame.rawTurnRate - bankingState.FlightTurnRateBlend) * frame.turnRateAlpha

    frame.targetBank = 0
    if frame.isMoving and math.abs(bankingState.FlightTurnRateBlend) > 0.001 then
        frame.targetBank = math.clamp(
            -bankingState.FlightTurnRateBlend * 0.10,
            math.rad(-20),
            math.rad(20)
        )
    end

    -- Enter a turn quickly, but let the body recover a little more lazily.
    -- That small asymmetry makes the real character feel like it has weight
    -- instead of mechanically matching the camera every frame.
    local bankDuration
    if math.abs(frame.targetBank) > math.abs(bankingState.FlightBankBlend) then
        bankDuration = frame.isMoving and 0.085 or 0.20
    else
        bankDuration = frame.isMoving and 0.15 or 0.30
    end
    frame.bankAlpha = 1 - math.exp(-frame.dt / bankDuration)
    bankingState.FlightBankBlend = bankingState.FlightBankBlend
        + (frame.targetBank - bankingState.FlightBankBlend) * frame.bankAlpha

    -- ================================================================
    -- EXACT HOLOGRAM POSE BLEND
    -- ================================================================
    flyAnimTime = flyAnimTime + frame.dt

    frame.targetMove = frame.isMoving and 1 or 0

    -- v57: slightly more deliberate visual settle on stopping. The manual
    -- animation blender remains responsible for animation; this value only
    -- controls the procedural flight pose/hover envelope.
    local transitionDuration
    if frame.targetMove > flyHologramMoveBlend then
        transitionDuration = 0.18
    else
        transitionDuration = 0.34
    end
    frame.direction = frame.targetMove > flyHologramMoveBlend and 1 or -1

    if math.abs(frame.targetMove - flyHologramMoveBlend) > 0.0001 then
        flyHologramMoveBlend = flyHologramMoveBlend
            + frame.direction * (frame.dt / transitionDuration)
    end
    flyHologramMoveBlend = math.clamp(flyHologramMoveBlend, 0, 1)

    frame.rawMoveBlend = flyHologramMoveBlend
    local b = frame.rawMoveBlend * frame.rawMoveBlend * (3 - 2 * frame.rawMoveBlend)

    -- Animation frame.direction must follow the character's actual body heading,
    -- not the camera heading, when Shift Lock is OFF. In that mode the body
    -- turns to face the movement frame.direction, so a joystick input that is
    -- "backward" relative to the camera is still FORWARD relative to the
    -- character. Shift Lock ON keeps the old camera-relative behavior.
    -- Use frame.desiredFlightYaw (the intended body heading) rather than the
    -- smoothed flyBodyYaw so a quick frame.direction change cannot briefly select
    -- the backward animation while the body is visually catching up.
    frame.animationBodyLook = Vector3.new(
        -math.sin(frame.desiredFlightYaw),
        0,
        -math.cos(frame.desiredFlightYaw)
    )
    frame.animationForwardInput = 0
    if frame.horizontalMove.Magnitude > 0.001 and frame.isMoving then
        frame.animationForwardInput = math.clamp(
            frame.horizontalMove.Unit:Dot(frame.animationBodyLook),
            -1,
            1
        )
    end

    -- Same animation state test/crossfade as the hologram.
    updateFlyAnimations(
        frame.isMoving,
        frame.moveVector,
        frame.dt,
        frame.animationForwardInput
    )

    -- v117: the procedural startup is applied by the PreSimulation driver.
    -- Do not write Motor6D.Transform from the camera/render loop; Animator
    -- evaluation and render timing can otherwise leave the old locomotion pose
    -- underneath the takeoff.
    frame.forwardTarget = 0
    frame.rightTarget = 0
    if frame.moveVector.Magnitude > 0.001 and frame.isMoving then
        frame.moveUnit = frame.moveVector.Unit

        if flyGui.ShiftLockOn then
            -- Shift Lock ON: keep the original camera-relative pose.
            -- Backward input relative to the camera is allowed to produce
            -- the backward/negative-forward flight lean.
            frame.forwardTarget = math.clamp(frame.moveUnit:Dot(frame.flatLook), -1, 1)

            frame.flatRight = frame.flatLook:Cross(Vector3.new(0, 1, 0))
            if frame.flatRight.Magnitude > 0.001 then
                frame.flatRight = frame.flatRight.Unit
                frame.rightTarget = math.clamp(frame.moveUnit:Dot(frame.flatRight), -1, 1)
            end
        else
            -- Shift Lock OFF: the body itself turns to face the movement
            -- frame.direction. Therefore a joystick pushed backward relative to
            -- the camera is still FORWARD relative to the character.
            -- Build the pose from the same intended body heading so both
            -- joystick directions produce the exact same forward lean/bank.
            frame.bodyPoseLook = frame.animationBodyLook
            frame.bodyPoseRight = frame.bodyPoseLook:Cross(Vector3.new(0, 1, 0))

            if frame.bodyPoseRight.Magnitude > 0.001 then
                frame.bodyPoseRight = frame.bodyPoseRight.Unit
            else
                frame.bodyPoseRight = Vector3.new(1, 0, 0)
            end

            frame.forwardTarget = math.clamp(frame.moveUnit:Dot(frame.bodyPoseLook), -1, 1)
            frame.rightTarget = math.clamp(frame.moveUnit:Dot(frame.bodyPoseRight), -1, 1)
        end
    end

    frame.directionDuration = frame.isMoving and 0.08 or 0.48
    frame.directionAlpha = 1 - math.exp(-frame.dt / frame.directionDuration)
    animState.forwardBlend = animState.forwardBlend
        + (frame.forwardTarget - animState.forwardBlend) * frame.directionAlpha
    bankingState.RightBlend = bankingState.RightBlend
        + (frame.rightTarget - bankingState.RightBlend) * frame.directionAlpha

    frame.movementForward = animState.forwardBlend
    frame.movementRight = bankingState.RightBlend

    -- v57 acceleration/deceleration body response. This supplements the
    -- existing v56 directional lean rather than replacing it.
    frame.accelerationPitch = math.rad(7)
        * flyState.flyAccelerationBlend * b
    frame.brakingPitch = math.rad(5)
        * flyState.flyDecelerationBlend * b

    frame.flyLeanPitch = math.rad(16) * frame.movementForward * b
        + frame.accelerationPitch
        - frame.brakingPitch
    frame.flyLeanRoll = math.rad(14) * frame.movementRight * b

    -- Direction-change reaction: briefly counter-roll into a sharp change,
    -- then let the existing turn-bank system take over.
    frame.directionSign = 0
    if frame.moveVector.Magnitude > 0.001 and flyState.flyPreviousMoveDirection.Magnitude > 0.05 then
        frame.crossY = flyState.flyPreviousMoveDirection.Unit:Cross(frame.moveVector.Unit).Y
        frame.directionSign = math.clamp(frame.crossY, -1, 1)
    end
    frame.directionChangeRoll = math.rad(4)
        * frame.directionSign
        * flyState.flyDirectionChangeBlend
        * b

    frame.verticalTravelRatio = 0
    if frame.moveVector.Magnitude > 0.001 then
        frame.verticalTravelRatio = math.clamp(math.abs(frame.moveVector.Unit.Y), 0, 1)
    end
    frame.horizontalSpeedPose = 1 - frame.verticalTravelRatio

    frame.speedTarget = frame.isMoving
        and math.clamp(frame.moveVector.Magnitude, 0, 1)
        or 0
    animState.speedBlend = animState.speedBlend
        + (frame.speedTarget - animState.speedBlend)
        * (1 - math.exp(-frame.dt / (frame.isMoving and 0.16 or 0.30)))

    frame.speedPosePitch = math.rad(10)
        * animState.speedBlend
        * frame.horizontalSpeedPose
        * b

    -- Exact hologram flight pitch from the 3D travel vector.
    frame.travelHorizontalMagnitude = Vector3.new(
        frame.moveVector.X, 0, frame.moveVector.Z
    ).Magnitude

    frame.flightPitchTarget = 0
    if frame.isMoving then
        if frame.travelHorizontalMagnitude > 0.001 then
            frame.flightPitchTarget = math.atan2(
                frame.moveVector.Y,
                frame.travelHorizontalMagnitude
            )
        elseif math.abs(frame.moveVector.Y) > 0.001 then
            frame.flightPitchTarget = frame.moveVector.Y > 0
                and math.rad(90)
                or math.rad(-90)
        end
    end

    frame.flightPitchTarget = math.clamp(
        frame.flightPitchTarget,
        math.rad(-75),
        math.rad(75)
    )

    -- v57 vertical-flight inertia: quick enough to follow the joystick, but
    -- with a slightly heavier settle so upward/downward changes do not snap.
    frame.verticalAcceleration = math.clamp(math.abs(frame.moveVector.Y), 0, 1)
    frame.flightPitchDuration = nil
    if frame.isMoving and frame.verticalAcceleration > 0.25 then
        frame.flightPitchDuration = 0.13
    else
        frame.flightPitchDuration = frame.isMoving and 0.10 or 0.24
    end

    animState.flightPitchBlend = animState.flightPitchBlend
        + (frame.flightPitchTarget - animState.flightPitchBlend)
        * (1 - math.exp(-frame.dt / frame.flightPitchDuration))

    frame.flightPitch = animState.flightPitchBlend * b

    -- Exact hologram frame.bob + hover. This was missing from the previous Fly
    -- version and is one of the reasons the real body felt different.
    frame.idleBob = math.sin(flyAnimTime * 1.8) * 0.025
    frame.flyBob = math.sin(flyAnimTime * 3.6) * 0.045
    frame.bob = frame.idleBob * (1 - b) + frame.flyBob * b

    frame.hoverTarget = (not frame.isMoving) and 1 or 0
    frame.hoverAlpha = 1 - math.exp(-frame.dt / ((frame.hoverTarget > 0.5) and 0.20 or 0.16))
    animState.hoverBlend = animState.hoverBlend
        + (frame.hoverTarget - animState.hoverBlend) * frame.hoverAlpha

    frame.hoverBob = math.sin(flyAnimTime * 1.55) * 0.10 * animState.hoverBlend
    frame.hoverRoll = math.sin(flyAnimTime * 1.10 + 0.7)
        * math.rad(1.2) * animState.hoverBlend
    frame.hoverYaw = math.sin(flyAnimTime * 0.82 + 1.4)
        * math.rad(0.8) * animState.hoverBlend

    -- EXACT same final pose equation as the hologram.
    frame.animatedCFrame =
        frame.baseCFrame *
        CFrame.new(0, frame.bob + frame.hoverBob, 0) *
        CFrame.Angles(
            frame.flightPitch - frame.flyLeanPitch - frame.speedPosePitch + startupPitch,
            frame.hoverYaw,
            -frame.flyLeanRoll - bankingState.FlightBankBlend
                + frame.directionChangeRoll
                + frame.hoverRoll
        )

    -- Preserve the original NoClip-based position ownership so the existing
    -- collision/proxy system and manual movement remain synchronized.
    if flyRuntime.NormalOrientationAlign then
        flyRuntime.NormalOrientationAlign.MaxTorque = startupFrame and 0 or 1e7
        flyRuntime.NormalOrientationTargetEnabled = not startupFrame
    end
    if flyRuntime.NormalVelocityAlign then
        flyRuntime.NormalVelocityAlign.Enabled = not startupFrame
    end
    if flyGui.MovementMode == "Normal" and not startupFrame and flyRuntime.NormalOrientationAlign then
        -- V245: Normal mode delegates root orientation to AlignOrientation.
        -- Keep translation physics-owned; do not write root.CFrame here.
        flyRuntime.NormalOrientationTarget = frame.animatedCFrame.Rotation
        flyRuntime.Position = root.Position

    elseif useManualPosition then
        -- Startup owns the root position even when No Clip is OFF so physics
        -- cannot cancel the procedural takeoff. Once startup finishes, the
        -- normal No Clip ON/OFF position ownership resumes unchanged.
        root.CFrame = CFrame.new(flyRuntime.Position) * frame.animatedCFrame.Rotation
        root.AssemblyLinearVelocity = Vector3.zero
    else
        root.CFrame = CFrame.new(root.Position) * frame.animatedCFrame.Rotation
        flyRuntime.Position = root.Position
    end
    -- Normal mode delegates angular response to its physics actuator. Zeroing
    -- angular velocity every render step would continually oppose that actuator.
    if not (flyGui.MovementMode == "Normal" and not startupFrame and flyRuntime.NormalOrientationAlign) then
        root.AssemblyAngularVelocity = Vector3.zero
    end

    -- The root may have moved during this render step. Re-evaluate the
    -- CameraModule-style subject point from the final character position so
    -- the Fly camera remains attached to the same point Roblox will follow
    -- when normal camera control resumes.
    frame.cameraSubjectPosition = getRobloxCameraSubjectPosition(humanoid, root)

    -- Commit the movement frame.direction after all visual frame.direction-change
    -- calculations have consumed the previous frame's value.
    flyState.flyPreviousMoveDirection = frame.moveVector

    -- ================================================================
    -- v58 OPTIONAL CAMERA FLIGHT FEEL
    -- ================================================================
    -- Kept in a helper to avoid exceeding Luau's local-register budget.
    frame.cameraPosition, frame.cameraRotation =
        computeFlyCameraVisualState(
            frame.moveVector,
            frame.currentSpeed,
            frame.dt,
            frame.cameraSubjectPosition
        )

    if not flyInput.SpectatingOtherPlayer then
        -- v113: Scriptable camera means Roblox CameraModule cannot overwrite
        -- the camera from the character rotation that this same frame creates.
        cam.CameraType = Enum.CameraType.Scriptable
        cam.CFrame = CFrame.new(frame.cameraPosition) * frame.cameraRotation
        cam.FieldOfView = (flyCameraSaved.FOV or FLY_CONFIG.FLY_CAMERA_FOV_BASE)
            + (flyGui.CameraFeelOn and flyState.flyCameraFOVBlend or 0)
        cam.Focus = CFrame.new(frame.cameraSubjectPosition)
    end
end

local function verticalAction(_, inputState, inputObject)
    if not flyRuntime.Enabled then return Enum.ContextActionResult.Pass end
    local direction = 0
    if inputObject.KeyCode == Enum.KeyCode.Space then direction = 1
    elseif inputObject.KeyCode == Enum.KeyCode.LeftControl or inputObject.KeyCode == Enum.KeyCode.C then direction = -1 end
    if inputState == Enum.UserInputState.Begin then
        flyRuntime.VerticalInput = direction
    elseif inputState == Enum.UserInputState.End or inputState == Enum.UserInputState.Cancel then
        if flyRuntime.VerticalInput == direction then flyRuntime.VerticalInput = 0 end
    end
    return Enum.ContextActionResult.Sink
end

local function bindVerticalControls()
    flyServices.ContextActionService:BindActionAtPriority("VGD_FlyVertical", verticalAction, false, Enum.ContextActionPriority.High.Value, Enum.KeyCode.Space, Enum.KeyCode.LeftControl, Enum.KeyCode.C)
end

local function unbindVerticalControls()
    flyServices.ContextActionService:UnbindAction("VGD_FlyVertical")
    flyRuntime.VerticalInput = 0
end

local updateFlyShiftLockButton

local function cancelPendingFlyExitHandoffForReenable()
    -- A held-joystick disable intentionally keeps a temporary Scriptable
    -- camera bridge alive. If Fly is enabled again before that bridge fully
    -- releases, the old bridge MUST NOT be allowed to keep writing camera
    -- CFrames underneath the new Fly session. Capture the live camera first,
    -- then tear the old bridge down without restoring the old pre-Fly camera.
    local camera = workspace.CurrentCamera
    local liveCFrame = camera and camera.CFrame or nil

    flyServices.RunService:UnbindFromRenderStep("VGD_FlyExitCameraHandoff")

    if flyCameraHandoff.Active or flyCameraHandoff.RenderConnection then
        flyCameraHandoff.Active = false
        flyCameraHandoff.QuietFrames = 0
        if flyCameraHandoff.RenderConnection then
            flyServices.RunService:UnbindFromRenderStep("VGD_FlyCameraHandoff")
            flyCameraHandoff.RenderConnection = false
        end
        disconnectFlyCameraInput()
    end

    -- The live bridge CFrame is the player's actual latest view. Do not put
    -- CameraModule back through the old saved CFrame here; the next Fly
    -- session must start from what the player is looking at NOW.
    if camera and liveCFrame then
        camera.CFrame = liveCFrame
    end

    flyCameraSaved.Type = nil
    flyCameraSaved.Subject = nil
    flyCameraSaved.CFrame = nil
    flyCameraSaved.FOV = nil
    flyCameraSaved.MinZoom = nil
    flyCameraSaved.MaxZoom = nil
end

local function cancelPendingFlyExitHandoffClean()
    -- Used for a final clean exit. Never leave an old render-step callback
    -- alive after a Fly session ends; otherwise a later walk/camera update can
    -- be overwritten by a callback belonging to a previous session.
    flyServices.RunService:UnbindFromRenderStep("VGD_FlyExitCameraHandoff")
    if flyCameraHandoff.RenderConnection then
        flyServices.RunService:UnbindFromRenderStep("VGD_FlyCameraHandoff")
        flyCameraHandoff.RenderConnection = false
    end
    flyCameraHandoff.Active = false
    flyCameraHandoff.QuietFrames = 0
end

local function disconnectFlyDeathConnection()
    if flyCameraHandoff.DiedConnection then
        pcall(function() flyCameraHandoff.DiedConnection:Disconnect() end)
        flyCameraHandoff.DiedConnection = nil
    end
end

local function bindFlyDeathCleanup(humanoid, sessionId)
    disconnectFlyDeathConnection()

    flyCameraHandoff.DiedConnection = humanoid.Died:Connect(function()
        if sessionId ~= flyCameraHandoff.SessionId then return end

        flyRuntime.Enabled = false
        flyInput.SpectatingOtherPlayer = false
        updateFlyShiftLockButton()
        unbindVerticalControls()

        if flyRuntime.RenderConnection then
            flyServices.RunService:UnbindFromRenderStep("VGD_FlySmooth")
            flyRuntime.RenderConnection = nil
        end

        flyServices.RunService:UnbindFromRenderStep("VGD_FlyExitCameraHandoff")
        flyServices.RunService:UnbindFromRenderStep("VGD_FlyCameraHandoff")
        flyCameraHandoff.Active = false
        flyCameraHandoff.RenderConnection = false
        flyCameraHandoff.QuietFrames = 0

        clearFlyJoystickHandoffBlock()
        disconnectFlyCameraInput()
        clearFlyJoystick()
        disconnectFlyNoClipWatcher()
        destroyFlyCollisionProxy()
        restoreCharacterState()

        -- Never restore the dead character's saved camera.
        flyCameraSaved.Type = Enum.CameraType.Custom
        flyCameraSaved.Subject = nil
        flyCameraSaved.CFrame = nil
        flyCameraSaved.FOV = nil
        flyCameraSaved.MinZoom = nil
        flyCameraSaved.MaxZoom = nil

        local camera = workspace.CurrentCamera
        if camera then
            camera.CameraType = Enum.CameraType.Custom
            camera.CameraSubject = nil
        end

        flyState.stateChangedEvent:Fire(false)
    end)
end

local function startFly2Startup(humanoid)
    local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
    if not humanoid then return false end
    if not animator then
        animator = Instance.new("Animator")
        animator.Parent = humanoid
    end

    local animation = Instance.new("Animation")
    animation.Name = "VGD_Fly2_FallShatter"
    animation.AnimationId = FLY_CONFIG.FLY2_STARTUP_ANIMATION_ID
    animation.Parent = humanoid
    local ok, track = pcall(function()
        return animator:LoadAnimation(animation)
    end)
    animation:Destroy()
    if not ok or not track then return false end

    track.Priority = Enum.AnimationPriority.Action
    track.Looped = false
    flyRuntime.Fly2StartupPending = true
    flyRuntime.Tracks.fly2Startup = track
    track:Play(0.12, 1, 1)

    local sessionId = flyCameraHandoff.SessionId
    task.delay(FLY_CONFIG.FLY2_STARTUP_PLAY_SECONDS, function()
        if not flyRuntime.Enabled or not flyRuntime.Fly2StartupPending
            or sessionId ~= flyCameraHandoff.SessionId or flyProfile ~= "Fly 2" then
            return
        end
        flyRuntime.Fly2StartupPending = false
        local tornado = flyRuntime.Tracks.tornado
        if tornado then
            -- Begin Tornado at its first pose, hold its playback while its weight
            -- blends in, then release movement at the 90% handoff point.
            flyRuntime.Fly2TornadoHandoffPending = true
            tornado:Play(0, 0, 0)
            tornado:AdjustWeight(1, FLY_CONFIG.FLY2_TRANSITION_BLEND)
            local releaseDelay = FLY_CONFIG.FLY2_TRANSITION_BLEND * FLY_CONFIG.FLY2_TORNADO_RELEASE_AT
            task.delay(releaseDelay, function()
                if not flyRuntime.Enabled or sessionId ~= flyCameraHandoff.SessionId
                    or flyProfile ~= "Fly 2" or flyRuntime.Tracks.tornado ~= tornado then
                    return
                end
                flyRuntime.Fly2TornadoHandoffPending = false
                pcall(function() tornado:AdjustSpeed(FLY_CONFIG.FLY2_TORNADO_SPEED) end)
            end)
        end
        pcall(function() track:Stop(FLY_CONFIG.FLY2_TRANSITION_BLEND) end)
        task.delay(FLY_CONFIG.FLY2_TRANSITION_BLEND + 0.1, function()
            if flyRuntime.Tracks.fly2Startup == track then
                flyRuntime.Tracks.fly2Startup = nil
            end
            pcall(function() track:Destroy() end)
        end)
    end)
    return true
end

local function enableFly()
    if flyRuntime.Enabled then return true end

    -- V262: don't begin the first transition while the execute-time asset preload is still running.
    while not flyRuntime.AnimationPreloadReady
        and os.clock() < flyRuntime.AnimationPreloadDeadline do
        task.wait()
    end

    -- v93: invalidate every callback belonging to the previous session.
    flyCameraHandoff.SessionId += 1
    local thisFlySession = flyCameraHandoff.SessionId
    disconnectFlyDeathConnection()
    flyServices.RunService:UnbindFromRenderStep("VGD_FlyExitCameraHandoff")
    flyServices.RunService:UnbindFromRenderStep("VGD_FlyCameraHandoff")
    flyCameraHandoff.Active = false
    flyCameraHandoff.RenderConnection = false
    flyCameraHandoff.QuietFrames = 0

    -- v92: repeated OFF -> ON -> OFF cycles must start from the LIVE camera
    -- state of the previous session, never from an old exit-handoff callback.
    cancelPendingFlyExitHandoffForReenable()

    -- A new Fly session takes ownership of camera input again, so any previous
    -- normal-camera handoff blocker can be removed now.
    clearFlyJoystickHandoffBlock()

    local humanoid, root = getHumanoidAndRoot()
    if not humanoid or not root then return false end
    local character = humanoid.Parent
    if not character then return false end

    -- V188: snapshot the character's LIVE facing direction at the exact
    -- moment Fly is enabled, before Fly/camera ownership changes anything.
    local enableBodyYaw = math.atan2(
        -root.CFrame.LookVector.X,
        -root.CFrame.LookVector.Z
    )

    saveCharacterState(humanoid, root)
    bindFlyDeathCleanup(humanoid, thisFlySession)

    -- Resolve and enable Roblox's movement controller BEFORE PlatformStand is
    -- applied. This preserves the currently-held mobile joystick instead of
    -- allowing the transition into Fly to make the ControlModule go idle.
    flyInput.MoveControls = getFlyMoveControls()
    if flyInput.MoveControls then
        pcall(function() flyInput.MoveControls:Enable() end)
    end

    -- Start tracking BEFORE PlatformStand. This is important because the
    -- joystick may already be held when Fly is enabled, so TouchStarted for
    -- that finger may have happened earlier. We also sample the current raw
    -- controller vector below so the transition does not lose momentum.
    -- The joystick tracker is persistent. Do NOT reconnect it here because
    -- reconnecting would lose a touch that began before Fly was enabled.
    local preStandMove = Vector3.zero
    if flyInput.MoveControls then
        pcall(function()
            local value = flyInput.MoveControls:GetMoveVector()
            if typeof(value) == "Vector3" then
                preStandMove = value
            end
        end)
    end
    if preStandMove.Magnitude > 0.001 then
        flyJoystick.Vector = preStandMove
    end

    flyRuntime.Enabled = true
    -- Preserve the user's Shift Lock state across Fly disable/enable.
    -- It defaults to ON for the first session, then follows the user's last choice.
    -- Do not reset flyGui.ShiftLockOn here.
    -- Preserve the user's last No Clip preference across Fly disable/enable.
    -- No Clip is ON by default only for the first Fly session; after the user
    -- turns it OFF, disabling and re-enabling Fly keeps it OFF.
    updateFlyShiftLockButton()
    flyRuntime.VerticalInput = 0
    animState.forwardBlend, bankingState.RightBlend, animState.flightPitchBlend, bankingState.FlightBankBlend, bankingState.FlightTurnRateBlend, animState.speedBlend, animState.hoverBlend = 0, 0, 0, 0, 0, 0, 0
    flyState.flyCameraVelocityBlend = Vector3.zero
    flyState.flyCameraTurnLag = 0
    flyState.flyCameraFOVBlend = 0
    flyState.flyCameraLastYaw = nil
    flyInput.CameraLastMoveVector = Vector3.zero
    flyState.flyAccelerationBlend = 0
    flyState.flyDecelerationBlend = 0
    flyState.flyDirectionChangeBlend = 0
    flyState.flyPreviousMoveDirection = Vector3.zero
    flyState.flyPreviousSpeed = 0
    if flyGui.ShiftLockOn then
        flyBodyYaw = flyState.flyCameraYaw
    else
        flyBodyYaw = enableBodyYaw
    end
    bankingState.PreviousDesiredYaw = flyBodyYaw
    flyHologramMoveBlend = 0
    flyAnimTime = 0
    flyIdleWeight = 1
    flyMoveWeight = 0
    flyBackwardWeight = 0
    flyStartup.Active = flyStartup.AnimationEnabled
    flyStartup.Time = 0
    flyStartup.LaunchActive = false
    flyStartup.LaunchTime = 0
    flyStartup.AscendTrack = nil
    flyStartup.AscendStoppedConnection = nil
    flyStartup.FinalBlendActive = false
    flyStartup.FinalBlendTime = 0
    flyStartup.StartPosition = flyStartup.AnimationEnabled and root.Position or nil
    stopFlyStartupAnimation()

    -- Startup OFF now uses the same character-state takeover as V162 Startup ON.
    -- Keep PlatformStand enabled during Fly ownership and let the existing Fly
    -- controller take over exactly as that older, tested activation path did.
    humanoid.PlatformStand = true
    humanoid.AutoRotate = false
    root.Anchored = false
    -- V247 diagnostic: only CFrame mode builds the auxiliary collision assembly.
    -- Normal Fly controls the real character assembly directly.
    if flyGui.MovementMode == "CFrame" then
        createFlyCollisionProxy()
    else
        destroyFlyCollisionProxy()
    end
    if flyGui.MovementMode == "Normal" then
        local attachment = Instance.new("Attachment")
        attachment.Name = "VGD_NormalFlyOrientationAttachment"
        attachment.Parent = root

        local align = Instance.new("AlignOrientation")
        align.Name = "VGD_NormalFlyOrientation"
        align.Mode = Enum.OrientationAlignmentMode.OneAttachment
        align.AlignType = Enum.AlignType.AllAxes
        align.Attachment0 = attachment
        align.RigidityEnabled = false
        align.Responsiveness = 60
        align.MaxTorque = 0
        align.MaxAngularVelocity = 1000
        align.CFrame = root.CFrame.Rotation
        align.Parent = root

        flyRuntime.NormalOrientationAttachment = attachment
        flyRuntime.NormalOrientationAlign = align
        flyRuntime.NormalOrientationTarget = root.CFrame.Rotation
        flyRuntime.NormalOrientationTargetEnabled = false

        local velocityAttachment = Instance.new("Attachment")
        velocityAttachment.Name = "VGD_NormalFlyVelocityAttachment"
        velocityAttachment.Parent = root

        local velocity = Instance.new("LinearVelocity")
        velocity.Name = "VGD_NormalFlyVelocity"
        velocity.Attachment0 = velocityAttachment
        velocity.RelativeTo = Enum.ActuatorRelativeTo.World
        velocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
        velocity.ForceLimitsEnabled = false
        velocity.VectorVelocity = Vector3.zero
        velocity.Enabled = true
        velocity.Parent = root

        flyRuntime.NormalVelocityAttachment = velocityAttachment
        flyRuntime.NormalVelocityAlign = velocity

        flyRuntime.NormalVelocityTarget = Vector3.zero
        flyServices.RunService.PreSimulation:Connect(function(dt)
            if not flyRuntime.Enabled or flyGui.MovementMode ~= "Normal" then
                return
            end
            local activeVelocity = flyRuntime.NormalVelocityAlign
            if activeVelocity and activeVelocity.Parent then
                activeVelocity.VectorVelocity = flyRuntime.NormalVelocityTarget
            end
            local activeOrientation = flyRuntime.NormalOrientationAlign
            if activeOrientation and activeOrientation.Parent
                and flyRuntime.NormalOrientationTargetEnabled then
                activeOrientation.CFrame = flyRuntime.NormalOrientationTarget
            end
        end)
    end
    -- V238: apply NoClip after proxy creation so the newly-created collision
    -- proxies and the live character receive one synchronized initial state.
    setFlyNoClip(flyGui.NoClipOn)
    animState.currentMoveVector = Vector3.zero

    -- Take ownership of the camera, using the same starting viewpoint model
    -- as Freecam. The camera is then reconstructed from yaw/pitch every render
    -- frame, so body rotation can never feed back into camera rotation.
    flyCameraSaved.Type = workspace.CurrentCamera.CameraType
    flyCameraSaved.Subject = workspace.CurrentCamera.CameraSubject
    flyCameraSaved.CFrame = workspace.CurrentCamera.CFrame
    flyInput.SpectatingOtherPlayer = false
    flyCameraSaved.FOV = workspace.CurrentCamera.FieldOfView
    flyCameraSaved.MinZoom = flyServices.Player.CameraMinZoomDistance
    flyCameraSaved.MaxZoom = flyServices.Player.CameraMaxZoomDistance

    local startCamera = workspace.CurrentCamera
    local startLook = startCamera.CFrame.LookVector
    local startPosition = startCamera.CFrame.Position
    local startSubjectPosition = getRobloxCameraSubjectPosition(humanoid, root)

    -- CameraModule follows startSubjectPosition, not the HumanoidRootPart
    -- pivot. Using the same subject here is the important v81 change: the
    -- vertical subject offset now participates in the Fly camera geometry in
    -- exactly the same way it does in the normal camera.
    local startDistanceAlongLook =
        (startPosition - startSubjectPosition):Dot(-startLook)

    if startDistanceAlongLook <= 0.01 then
        startDistanceAlongLook =
            (startPosition - startSubjectPosition).Magnitude
    end

    local normalCameraLinePosition =
        startSubjectPosition - startLook * startDistanceAlongLook
    local normalCameraOffset =
        startPosition - normalCameraLinePosition

    -- Preserve the normal camera's vertical framing component. Because the
    -- Fly camera later adds this offset perpendicular to LookVector, the old
    -- code used startDistanceAlongLook directly as the Fly zoom distance.
    -- That made the final Fly camera slightly farther from the character than
    -- the normal camera whenever this offset was non-zero.
    flyState.flyCameraVerticalOffset =
        normalCameraOffset:Dot(startCamera.CFrame.UpVector)

    -- Match the REAL starting camera-to-subject distance, not just its
    -- projection along LookVector. The Fly camera position is constructed as
    --   subject - LookVector * depth + UpVector * verticalOffset
    -- so its true distance is sqrt(depth^2 + verticalOffset^2). Solve that
    -- geometry here so enabling Fly does not introduce a small distance jump
    -- even when the player never touches zoom.
    local startActualDistance =
        (startPosition - startSubjectPosition).Magnitude
    local verticalOffsetMagnitude = math.abs(flyState.flyCameraVerticalOffset)
    local depthSquared =
        (startActualDistance * startActualDistance)
        - (verticalOffsetMagnitude * verticalOffsetMagnitude)

    local correctedStartDepth = math.sqrt(math.max(depthSquared, 0))

    flyState.flyCameraZoomDistance = math.clamp(
        correctedStartDepth,
        FLY_CONFIG.FLY_CAMERA_ZOOM_MIN,
        FLY_CONFIG.FLY_CAMERA_ZOOM_MAX
    )
    flyState.flyCameraTargetZoomDistance = flyState.flyCameraZoomDistance

    flyState.flyCameraOffset = Vector3.zero
    flyState.flyCameraPitch, flyState.flyCameraYaw = startCamera.CFrame:ToOrientation()
    flyState.flyCameraTargetPitch = flyState.flyCameraPitch
    flyState.flyCameraTargetYaw = flyState.flyCameraYaw

    -- V188: Shift Lock OFF uses the live character heading captured when
    -- enableFly() began. Camera yaw must not overwrite that heading.
    if flyGui.ShiftLockOn then
        flyBodyYaw = flyState.flyCameraYaw
    else
        flyBodyYaw = enableBodyYaw
    end
    bankingState.PreviousDesiredYaw = flyBodyYaw
    flyCameraResetInput()
    flyInput.MoveControls = getFlyMoveControls()

    flyRuntime.Position = root.Position
    flyStartup.StartPosition = flyRuntime.Position
    cacheFlyStartupJoints(character)
    -- V128: the Motor6D diagnostic is complete; Fly now enters the
    -- actual procedural superhero takeoff immediately.
    loadFlyAnimations(humanoid)

    -- V178: use the dedicated takeoff animation normally.
    -- If it cannot be delivered, cancel startup cleanly and enter normal Fly;
    -- never fall back into the old procedural startup lock.
    if flyProfile == "Fly 2" then
        flyStartup.Active = false
        flyStartup.Time = 0
        flyStartup.StartPosition = nil
        if flyStartup.AnimationEnabled then
            if not startFly2Startup(humanoid) then
                startNormalFlyAnimationSet(true)
            end
        else
            startNormalFlyAnimationSet(true)
        end
    elseif flyStartup.AnimationEnabled then
        local usingStartupAsset = startFlyStartupAnimation(humanoid)
        if not usingStartupAsset then
            flyStartup.Active = false
            flyStartup.Time = 0
            flyStartup.StartPosition = nil
            startNormalFlyAnimationSet(true)
        end
    else
        flyStartup.Active = false
        flyStartup.Time = 0
        flyStartup.StartPosition = nil
        startNormalFlyAnimationSet()
    end

    bindVerticalControls()
    connectFlyCameraInput()
    -- V113: use the proven v60 camera ownership model. The default
    -- CameraModule must not rebuild a camera from an HRP that Fly is rotating;
    -- on mobile Shift Lock that creates a feedback loop and visible jitter.
    -- Fly owns the camera CFrame while active, while the existing Fly camera
    -- input/zoom implementation remains unchanged.
    startCamera.CameraType = Enum.CameraType.Scriptable

    if flyRuntime.RenderConnection then
        flyServices.RunService:UnbindFromRenderStep("VGD_FlySmooth")
        flyRuntime.RenderConnection = nil
    end

    -- V113: render after Camera priority, but the camera is Scriptable while
    -- Fly is active, so the default CameraModule has no competing write.
    flyServices.RunService:BindToRenderStep(
        "VGD_FlySmooth",
        Enum.RenderPriority.Camera.Value + 1,
        updateFly
    )
    flyRuntime.RenderConnection = true
    flyState.stateChangedEvent:Fire(true)
    return true
end

local function stopFlyCameraHandoff()
    if not flyCameraHandoff.Active then
        return
    end

    flyCameraHandoff.Active = false
    flyCameraHandoff.QuietFrames = 0

    if flyCameraHandoff.RenderConnection then
        flyServices.RunService:UnbindFromRenderStep("VGD_FlyCameraHandoff")
        flyCameraHandoff.RenderConnection = false
    end

    disconnectFlyCameraInput()

    local camera = workspace.CurrentCamera
    if not camera then
        return
    end

    local finalCFrame = camera.CFrame
    local savedType = flyCameraSaved.Type or Enum.CameraType.Custom
    local savedSubject = flyCameraSaved.Subject
    local savedFOV = flyCameraSaved.FOV
    local savedMinZoom = flyCameraSaved.MinZoom
    local savedMaxZoom = flyCameraSaved.MaxZoom

    -- Let Roblox regain ownership immediately after the bridge. The final
    -- Fly orientation is seeded before CameraModule's next Custom update,
    -- while the saved subject is restored at the same time. This avoids the
    -- stale Scriptable camera state that could freeze the camera after the
    -- joystick was released and the player started walking again.
    camera.CameraSubject = savedSubject
    camera.CameraType = savedType
    if savedType == Enum.CameraType.Custom and savedSubject then
        camera.CFrame = finalCFrame
        camera.Focus = CFrame.new(finalCFrame.Position + finalCFrame.LookVector * 20)
    end
    if savedFOV then
        camera.FieldOfView = savedFOV
    end

    local handoffName = "VGD_FlyExitCameraHandoff"
    flyServices.RunService:UnbindFromRenderStep(handoffName)
    local applied = false
    flyServices.RunService:BindToRenderStep(handoffName, Enum.RenderPriority.Camera.Value + 1, function()
        if applied then return end
        applied = true
        flyServices.RunService:UnbindFromRenderStep(handoffName)
        if camera.Parent then
            camera.CFrame = finalCFrame
        end
        if savedMinZoom ~= nil then
            flyServices.Player.CameraMinZoomDistance = savedMinZoom
        end
        if savedMaxZoom ~= nil then
            flyServices.Player.CameraMaxZoomDistance = savedMaxZoom
        end
    end)

    flyCameraSaved.Type = nil
    flyCameraSaved.Subject = nil
    flyCameraSaved.CFrame = nil
    flyCameraSaved.FOV = nil
    flyCameraSaved.MinZoom = nil
    flyCameraSaved.MaxZoom = nil
end

local function startFlyCameraHandoff(finalFlyCameraCFrame)
    local camera = workspace.CurrentCamera
    if not camera or not finalFlyCameraCFrame then
        return false
    end

    flyCameraHandoff.Active = true
    flyCameraHandoff.QuietFrames = 0

    -- Keep the camera Scriptable while the old joystick finger exists. The
    -- normal movement controller remains enabled and therefore still receives
    -- the physical thumbstick. Only camera ownership is temporarily bridged.
    camera.CameraType = Enum.CameraType.Scriptable
    camera.CFrame = finalFlyCameraCFrame
    camera.Focus = CFrame.new(finalFlyCameraCFrame.Position + finalFlyCameraCFrame.LookVector * 20)

    if not flyCameraHandoff.RenderConnection then
        local handoffSessionId = flyCameraHandoff.SessionId
        flyServices.RunService:BindToRenderStep(
            "VGD_FlyCameraHandoff",
            Enum.RenderPriority.Camera.Value + 1,
            function(dt)
                if handoffSessionId ~= flyCameraHandoff.SessionId then
                    flyServices.RunService:UnbindFromRenderStep("VGD_FlyCameraHandoff")
                    flyCameraHandoff.Active = false
                    flyCameraHandoff.RenderConnection = false
                    return
                end
                if not flyCameraHandoff.Active then
                    return
                end

                local humanoid, root = getHumanoidAndRoot()
                local cam = workspace.CurrentCamera
                if not humanoid or not root or not cam then
                    stopFlyCameraHandoff()
                    return
                end

                -- The old joystick is intentionally NOT part of the camera
                -- touch table. New right-side touches continue through the same
                -- proven Fly camera interpreter, so one-finger movement remains
                -- movement and two-finger pinch cannot be synthesized from it.
                flyCameraSmoothLook(dt)

                local zoomAlpha = 1 - math.exp(-14 * math.max(dt or 0, 0))
                flyState.flyCameraZoomDistance = flyState.flyCameraZoomDistance
                    + (flyState.flyCameraTargetZoomDistance - flyState.flyCameraZoomDistance) * zoomAlpha

                local subjectPosition = getRobloxCameraSubjectPosition(humanoid, root)
                local bridgeCFrame = getFlyCameraCFrame(subjectPosition)
                cam.CameraType = Enum.CameraType.Scriptable
                cam.CFrame = bridgeCFrame
                cam.Focus = CFrame.new(subjectPosition)

                -- Do not release the bridge merely because the joystick vector
                -- reaches zero: the thumb may still be physically down. The
                -- exact tracker clears flyJoystick.Touch only on TouchEnded.
                local joystickStillHeld = flyJoystick.Touch ~= nil
                    or not flyJoystick.ReleasedSinceLastStart
                        and flyJoystick.Vector.Magnitude > 0.001

                local cameraTouchCount = 0
                for _ in pairs(flyState.flyCameraTouchStates) do
                    cameraTouchCount += 1
                end

                if not joystickStillHeld and cameraTouchCount == 0 then
                    -- Two quiet frames let Roblox finish the release processing
                    -- before CameraModule receives ownership again. This avoids
                    -- the stale one-frame pinch/rotation state seen on exit.
                    flyCameraHandoff.QuietFrames += 1
                    if flyCameraHandoff.QuietFrames >= 2 then
                        stopFlyCameraHandoff()
                    end
                else
                    flyCameraHandoff.QuietFrames = 0
                end
            end
        )
        flyCameraHandoff.RenderConnection = true
    end

    return true
end

local function disableFly()
    if not flyRuntime.Enabled then return false end

    -- v117: never leave the procedural PreSimulation driver alive across a
    -- Fly session boundary.
    stopFlyStartupPoseDriver()
    flyRuntime.NormalVelocityTarget = Vector3.zero
    flyRuntime.NormalOrientationTargetEnabled = false
    if flyRuntime.NormalVelocityAlign then
        pcall(function() flyRuntime.NormalVelocityAlign:Destroy() end)
        flyRuntime.NormalVelocityAlign = nil
    end
    if flyRuntime.NormalVelocityAttachment then
        pcall(function() flyRuntime.NormalVelocityAttachment:Destroy() end)
        flyRuntime.NormalVelocityAttachment = nil
    end
    if flyRuntime.NormalOrientationAlign then
        pcall(function() flyRuntime.NormalOrientationAlign:Destroy() end)
        flyRuntime.NormalOrientationAlign = nil
    end
    if flyRuntime.NormalOrientationAttachment then
        pcall(function() flyRuntime.NormalOrientationAttachment:Destroy() end)
        flyRuntime.NormalOrientationAttachment = nil
    end

    -- Invalidate this session before any exit work. This prevents repeated
    -- ON/OFF cycles from leaving an old lifecycle callback alive.
    flyCameraHandoff.SessionId += 1
    disconnectFlyDeathConnection()

    -- Capture the joystick state BEFORE disconnectFlyJoystickTracking() clears it.
    -- If the thumb is still held, we hand that movement back to the normal
    -- Humanoid controller after PlatformStand is restored. This fixes both
    -- transition cases: a touch held before Fly was enabled, and a new touch
    -- started while already flying. If no touch is held, no movement is handed
    -- back, so disabling Fly still stops movement normally.
    local handoffMoveVector = nil
    if not flyJoystick.ReleasedSinceLastStart
        and flyJoystick.Touch
        and (flyJoystick.Touch.UserInputState == Enum.UserInputState.Begin
            or flyJoystick.Touch.UserInputState == Enum.UserInputState.Change)
        and flyJoystick.Vector.Magnitude > 0.001 then
        handoffMoveVector = flyJoystick.Vector
    elseif not flyJoystick.ReleasedSinceLastStart and flyServices.UserInputService.TouchEnabled then
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

    -- Capture the actual FINAL Fly camera orientation before releasing
    -- ownership. Never use flyCameraSaved.CFrame here: that is the pre-Fly
    -- orientation and would restore North after the player turned East.
    -- Build the exit CFrame from Fly's OWN live camera state rather than
    -- trusting whatever CameraModule happened to leave in CurrentCamera on
    -- the exact disable frame. This prevents the intermittent return to the
    -- pre-Fly direction after repeated enable/disable cycles.
    local finalFlyCameraCFrame = nil
    do
        local exitHumanoid, exitRoot = getHumanoidAndRoot()
        local camera = workspace.CurrentCamera
        if exitHumanoid and exitRoot then
            local subjectPosition = getRobloxCameraSubjectPosition(exitHumanoid, exitRoot)
            finalFlyCameraCFrame = getFlyCameraCFrame(subjectPosition)
        elseif camera then
            finalFlyCameraCFrame = camera.CFrame
        end
    end

    -- v97 camera ownership rule:
    -- Never bridge the normal camera through Scriptable on Fly exit.
    -- The movement joystick is handed back separately below; camera ownership
    -- is returned directly to Roblox's Custom CameraModule. This keeps one
    -- ON/OFF while moving from leaving a stale Scriptable camera behind.
    --
    -- Also cancel any legacy bridge that might still exist from a previous
    -- session before we hand the camera back.
    if flyCameraHandoff.Active or flyCameraHandoff.RenderConnection then
        cancelPendingFlyExitHandoffClean()
    end

    flyRuntime.Enabled = false
    flyRuntime.Fly2StartupPending = false
    flyRuntime.Fly2TornadoHandoffPending = false
    if flyProfile == "Fly 2" then
        -- Tear down both profile-owned tracks on the same session boundary.
        -- The delayed startup transition is separately invalidated by SessionId.
        for _, track in pairs(flyRuntime.Tracks) do
            pcall(function() track:Stop(0.15) end)
        end
        flyRuntime.Tracks = {}
    end
    updateFlyShiftLockButton()
    unbindVerticalControls()
    if flyRuntime.RenderConnection then
        flyServices.RunService:UnbindFromRenderStep("VGD_FlySmooth")
        flyRuntime.RenderConnection = nil
    end
    if not flyCameraHandoff.Active then
        disconnectFlyCameraInput()
    end
    -- Keep the joystick tracker connected after Fly is disabled so a touch
    -- that started before Fly can remain available for the normal movement
    -- controller and for the next Fly transition.
    flyInput.MoveControls = nil
    disconnectFlyNoClipWatcher()
    disconnectFlyDeathConnection()

    local camera = workspace.CurrentCamera
    local wasSpectatingOtherPlayer = flyInput.SpectatingOtherPlayer

    if camera then
        if wasSpectatingOtherPlayer then
            -- External spectate owns this camera. Do not interfere with its
            -- current camera state when Fly is disabled.
            camera.CameraType = flyCameraSaved.Type or Enum.CameraType.Custom
            camera.CameraSubject = flyCameraSaved.Subject
        else
            local humanoid = select(1, getHumanoidAndRoot())

            -- v97: return directly to Roblox's normal camera. Do NOT restore
            -- the pre-Fly CameraSubject/CameraType and do NOT seed private
            -- CameraModule orientation state. Both approaches can resurrect a
            -- stale camera transform or leave the normal follow camera in a
            -- broken state after a single ON/OFF while the player is moving.
            --
            -- Roblox's documented Custom camera requires a valid subject, so
            -- for a normal Fly session the subject is ALWAYS the CURRENT
            -- Humanoid. The final Fly CFrame is applied once after the normal
            -- CameraModule update, exactly like Roblox's documented custom
            -- camera render-step pattern. After that single write, this script
            -- never touches the normal camera again.
            local savedFOV = flyCameraSaved.FOV
            local savedMinZoom = flyCameraSaved.MinZoom
            local savedMaxZoom = flyCameraSaved.MaxZoom

            flyServices.RunService:UnbindFromRenderStep("VGD_FlyExitCameraHandoff")

            if humanoid then
                camera.CameraType = Enum.CameraType.Custom
                camera.CameraSubject = humanoid
            else
                camera.CameraType = Enum.CameraType.Custom
                camera.CameraSubject = nil
            end

            if savedFOV then
                camera.FieldOfView = savedFOV
            end

            local handoffName = "VGD_FlyExitCameraHandoff"
            local exitSessionId = flyCameraHandoff.SessionId
            local handoffApplied = false
            flyServices.RunService:BindToRenderStep(
                handoffName,
                Enum.RenderPriority.Camera.Value + 1,
                function()
                    if exitSessionId ~= flyCameraHandoff.SessionId then
                        flyServices.RunService:UnbindFromRenderStep(handoffName)
                        return
                    end
                    if handoffApplied then return end
                    handoffApplied = true
                    flyServices.RunService:UnbindFromRenderStep(handoffName)

                    local currentHumanoid = select(1, getHumanoidAndRoot())
                    if camera and camera.Parent and currentHumanoid then
                        camera.CameraType = Enum.CameraType.Custom
                        camera.CameraSubject = currentHumanoid
                        if finalFlyCameraCFrame then
                            camera.CFrame = finalFlyCameraCFrame
                            camera.Focus = CFrame.new(
                                finalFlyCameraCFrame.Position
                                    + finalFlyCameraCFrame.LookVector * 20
                            )
                        end
                    end

                    if savedMinZoom ~= nil then
                        flyServices.Player.CameraMinZoomDistance = savedMinZoom
                    end
                    if savedMaxZoom ~= nil then
                        flyServices.Player.CameraMaxZoomDistance = savedMaxZoom
                    end
                end
            )
        end
    end

    flyCameraSaved.Type = nil
    flyCameraSaved.Subject = nil
    flyCameraSaved.CFrame = nil
    flyInput.SpectatingOtherPlayer = false
    flyCameraSaved.FOV = nil
    flyCameraSaved.MinZoom = nil
    flyCameraSaved.MaxZoom = nil
    flyStartup.Active = false
    flyStartup.Time = 0
    flyStartup.StartPosition = nil
    stopFlyStartupAnimation()
    clearFlyStartupPose()
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
    if not handoffMoveVector and flyServices.UserInputService.TouchEnabled then
        local stoppedHumanoid = select(1, getHumanoidAndRoot())
        if stoppedHumanoid then
            local resetControls = getFlyMoveControls()
            if resetControls then
                pcall(function() resetControls:Disable() end)
                pcall(function() resetControls:Enable() end)
            end

            stoppedHumanoid:Move(Vector3.zero, false)

            local stopUntil = os.clock() + 0.12
            flyServices.RunService:BindToRenderStep(
                "VGD_FlyJoystickDisableStop",
                Enum.RenderPriority.Character.Value + 2,
                function()
                    if os.clock() >= stopUntil then
                        flyServices.RunService:UnbindFromRenderStep("VGD_FlyJoystickDisableStop")
                        return
                    end
                    if stoppedHumanoid.Parent then
                        stoppedHumanoid:Move(Vector3.zero, false)
                    else
                        flyServices.RunService:UnbindFromRenderStep("VGD_FlyJoystickDisableStop")
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

            local handoffTouch = flyJoystick.Touch

            -- V113.1: keep the already-held joystick touch out of Roblox's
            -- CameraModule during the exit handoff. Without this, the normal
            -- camera sees the held left joystick + a second right-side touch
            -- as a two-finger pinch, so rotating with the second finger
            -- accidentally zooms instead. The existing movement handoff still
            -- feeds the captured joystick vector to Humanoid:Move(). Other
            -- touches remain available to the normal camera.
            blockFlyJoystickDuringCameraHandoff(handoffTouch)

            -- V190: keep the held joystick touch blocked for the ENTIRE
            -- handoff, not just the first 0.18 seconds. The old timed release
            -- allowed the left joystick finger to become visible to Roblox's
            -- CameraModule again while it was still physically held. When a
            -- second finger was then used to rotate the camera, Roblox saw
            -- two touches and interpreted them as a pinch, causing zoom.
            --
            -- clearFlyJoystickHandoffBlock() is called by TouchEnded for the
            -- exact joystick InputObject, so normal camera pinch/zoom behavior
            -- returns automatically once the joystick finger is actually
            -- released.
            local handoffReleased = false
            local handoffReleaseConnection = nil
            local handoffNewTouchConnection = nil

            -- If the joystick touch was already held before Fly was enabled,
            -- flyJoystick.Touch can be unavailable. In that case a TouchEnded
            -- occurring inside the DynamicThumbstick area is the release of
            -- the joystick that produced handoffMoveVector.
            handoffReleaseConnection = flyServices.UserInputService.TouchEnded:Connect(function(inputObject)
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
            handoffNewTouchConnection = flyServices.UserInputService.TouchStarted:Connect(function(inputObject)
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

            flyServices.RunService:BindToRenderStep(
                "VGD_FlyJoystickHandoff",
                Enum.RenderPriority.Character.Value + 1,
                function()
                    if not humanoid.Parent then
                        cleanupHandoffConnections()
                        flyServices.RunService:UnbindFromRenderStep("VGD_FlyJoystickHandoff")
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
                        flyServices.RunService:UnbindFromRenderStep("VGD_FlyJoystickHandoff")

                        -- Humanoid:Move() is a per-frame command and Roblox's
                        -- ControlModule can update movement on its own render
                        -- pass. Give the zero command a tiny post-release
                        -- window so the previous handoff vector cannot remain
                        -- latched for another frame or two.
                        local stopUntil = os.clock() + 0.12
                        flyServices.RunService:BindToRenderStep(
                            "VGD_FlyJoystickHardStop",
                            Enum.RenderPriority.Character.Value + 2,
                            function()
                                if os.clock() >= stopUntil then
                                    flyServices.RunService:UnbindFromRenderStep("VGD_FlyJoystickHardStop")
                                    return
                                end
                                if humanoid.Parent then
                                    humanoid:Move(Vector3.zero, false)
                                else
                                    flyServices.RunService:UnbindFromRenderStep("VGD_FlyJoystickHardStop")
                                end
                            end
                        )
                        return
                    end

                    -- Keep using the exact tracked vector while the original
                    -- touch remains held. For a pre-Fly touch, recover the
                    -- current vector from DynamicThumbstick's live visuals.
                    local vector = nil
                    if handoffTouch and flyJoystick.Touch == handoffTouch
                        and flyJoystick.Vector.Magnitude > 0.001 then
                        vector = flyJoystick.Vector
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

    flyState.stateChangedEvent:Fire(false)
    return false
end

flyServices.Player.CharacterAdded:Connect(function(character)
    task.spawn(function()
        local humanoid = character:WaitForChild("Humanoid", 10)
        character:WaitForChild("HumanoidRootPart", 10)

        -- A character replacement invalidates every camera state belonging to
        -- the dead character. Never carry a Scriptable death camera through
        -- respawn.
        flyServices.RunService:UnbindFromRenderStep("VGD_FlyExitCameraHandoff")
        flyServices.RunService:UnbindFromRenderStep("VGD_FlyCameraHandoff")
        flyCameraHandoff.Active = false
        flyCameraHandoff.RenderConnection = false
        flyCameraHandoff.QuietFrames = 0
        clearFlyJoystickHandoffBlock()
        disconnectFlyCameraInput()

        local camera = workspace.CurrentCamera
        if camera then
            camera.CameraType = Enum.CameraType.Custom
            camera.CameraSubject = humanoid
        end

        if flyRuntime.Enabled then
            -- Start a fresh Fly session on the new character. The old
            -- Humanoid, root, camera CFrame and camera subject are discarded.
            flyCameraHandoff.SessionId += 1
            local thisFlySession = flyCameraHandoff.SessionId

            task.defer(function()
                if not flyRuntime.Enabled or thisFlySession ~= flyCameraHandoff.SessionId then
                    return
                end

                local newHumanoid, root = getHumanoidAndRoot()
                if not newHumanoid or not root then
                    flyRuntime.Enabled = false
                    flyState.stateChangedEvent:Fire(false)
                    return
                end

                flyRuntime.Saved = nil
                saveCharacterState(newHumanoid, root)
                bindFlyDeathCleanup(newHumanoid, thisFlySession)

                flyInput.MoveControls = getFlyMoveControls()
                if flyInput.MoveControls then
                    pcall(function() flyInput.MoveControls:Enable() end)
                end

                -- V247 diagnostic: collision proxies/gravity compensation are
                -- retained for CFrame mode only. Normal mode uses its native
                -- character assembly and its LinearVelocity actuator.
                if flyGui.MovementMode == "CFrame" then
                    createFlyCollisionProxy()
                else
                    destroyFlyCollisionProxy()
                end
                setFlyNoClip(flyGui.NoClipOn)
                -- V169: keep the live idle visible through the shared startup
                -- handoff; PlatformStand is applied after the same short window
                -- used by the main enable path.
                newHumanoid.AutoRotate = false
                root.Anchored = false
                animState.currentMoveVector = Vector3.zero
                flyRuntime.Position = root.Position
                flyStartup.Active = flyStartup.AnimationEnabled
                flyStartup.Time = 0
                flyStartup.StartPosition = flyStartup.AnimationEnabled and flyRuntime.Position or nil
                stopFlyStartupAnimation()
                cacheFlyStartupJoints(newHumanoid.Parent)
                if flyGui.ShiftLockOn then
                    flyBodyYaw = flyState.flyCameraYaw
                else
                    flyBodyYaw = math.atan2(
                        root.CFrame.LookVector.X,
                        -root.CFrame.LookVector.Z
                    )
                end
                bankingState.PreviousDesiredYaw = flyBodyYaw
                if flyStartup.AnimationEnabled then
                    local usingStartupAsset = startFlyStartupAnimation(newHumanoid)
                    if not usingStartupAsset then
                        flyStartup.Active = false
                        flyStartup.Time = 0
                        flyStartup.StartPosition = nil
                        startNormalFlyAnimationSet(true)
                    end
                else
                    flyStartup.Active = false
                    flyStartup.Time = 0
                    flyStartup.StartPosition = nil
                    startNormalFlyAnimationSet(true)
                end

                -- V169: keep PlatformStand out of the startup animation itself.
                -- V169: PlatformStand is not forced during activation.
                -- This keeps the animation handoff completely visual; the
                -- custom Fly controller already owns movement.

                local newCamera = workspace.CurrentCamera
                if newCamera then
                    flyCameraSaved.Type = Enum.CameraType.Custom
                    flyCameraSaved.Subject = newHumanoid
                    flyCameraSaved.CFrame = newCamera.CFrame
                    flyCameraSaved.FOV = newCamera.FieldOfView
                    flyCameraSaved.MinZoom = flyServices.Player.CameraMinZoomDistance
                    flyCameraSaved.MaxZoom = flyServices.Player.CameraMaxZoomDistance

                    flyState.flyCameraPitch, flyState.flyCameraYaw = newCamera.CFrame:ToOrientation()
                    flyState.flyCameraTargetPitch = flyState.flyCameraPitch
                    flyState.flyCameraTargetYaw = flyState.flyCameraYaw

                    -- V188: the new character's live facing is authoritative
                    -- when Shift Lock is OFF; never restore an old session yaw.
                    if flyGui.ShiftLockOn then
                        flyBodyYaw = flyState.flyCameraYaw
                    else
                        flyBodyYaw = math.atan2(
                            root.CFrame.LookVector.X,
                            -root.CFrame.LookVector.Z
                        )
                    end
                    bankingState.PreviousDesiredYaw = flyBodyYaw

                    local subjectPosition = getRobloxCameraSubjectPosition(newHumanoid, root)
                    local startDistance = (newCamera.CFrame.Position - subjectPosition).Magnitude
                    flyState.flyCameraVerticalOffset = 0
                    flyState.flyCameraZoomDistance = math.clamp(
                        startDistance,
                        FLY_CONFIG.FLY_CAMERA_ZOOM_MIN,
                        FLY_CONFIG.FLY_CAMERA_ZOOM_MAX
                    )
                    flyState.flyCameraTargetZoomDistance = flyState.flyCameraZoomDistance
                    flyCameraResetInput()
                    flyInput.SpectatingOtherPlayer = false

                    connectFlyCameraInput()
                    newCamera.CameraType = Enum.CameraType.Scriptable
                end

                if flyRuntime.RenderConnection then
                    flyServices.RunService:UnbindFromRenderStep("VGD_FlySmooth")
                end
                flyServices.RunService:BindToRenderStep(
                    "VGD_FlySmooth",
                    Enum.RenderPriority.Camera.Value + 1,
                    updateFly
                )
                flyRuntime.RenderConnection = true
            end)
        end
    end)
end)

-- =========================================================
-- MINI GUI
-- =========================================================
-- Keep the large GUI construction in its own function so its local UI
-- references do not consume the top-level chunk's local-register budget.
-- This is structural only; GUI layout/behavior is unchanged.

local function buildMiniGui()
    local ui = {}

flyGui.ScreenGui = Instance.new("ScreenGui")
flyGui.ScreenGui.Name = "VGD_Fly_Standalone"
flyGui.ScreenGui.ResetOnSpawn = false
flyGui.ScreenGui.IgnoreGuiInset = true
flyGui.ScreenGui.DisplayOrder = 1998
flyGui.ScreenGui.Enabled = not flyGui.GUI_CONTROLLED
flyGui.ScreenGui.Parent = flyServices.Player:WaitForChild("PlayerGui")

ui.panel = Instance.new("Frame")
ui.panel.Size = UDim2.fromOffset(220, 305)
-- Compact the entire mini GUI without changing the shortcut.
-- Keep the same 12px right margin after scaling.
ui.panel.Position = UDim2.new(1, -188, 0, 92)
ui.panel.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
ui.panel.BackgroundTransparency = 0.08
ui.panel.BorderSizePixel = 0
ui.panel.Parent = flyGui.ScreenGui
Instance.new("UICorner", ui.panel).CornerRadius = UDim.new(0, 12)

ui.miniGuiScale = Instance.new("UIScale")
ui.miniGuiScale.Scale = 0.80
ui.miniGuiScale.Parent = ui.panel

ui.title = Instance.new("TextLabel")
ui.title.Size = UDim2.new(1, -20, 0, 24)
ui.title.Position = UDim2.fromOffset(10, 7)
ui.title.BackgroundTransparency = 1
ui.title.Text = "VGD  •  FLY"
ui.title.TextColor3 = Color3.new(1, 1, 1)
ui.title.Font = Enum.Font.GothamBold
ui.title.TextSize = 15
ui.title.TextXAlignment = Enum.TextXAlignment.Left
ui.title.Parent = ui.panel

ui.versionLabel = Instance.new("TextLabel")
ui.versionLabel.Size = UDim2.fromOffset(34, 18)
ui.versionLabel.Position = UDim2.new(1, -67, 0, 10)
ui.versionLabel.BackgroundTransparency = 1
ui.versionLabel.Text = "V262"
ui.versionLabel.TextColor3 = Color3.fromRGB(145, 145, 145)
ui.versionLabel.Font = Enum.Font.Gotham
ui.versionLabel.TextSize = 9
ui.versionLabel.TextXAlignment = Enum.TextXAlignment.Right
ui.versionLabel.Parent = ui.panel

ui.closeButton = Instance.new("TextButton")
ui.closeButton.Size = UDim2.fromOffset(22, 22)
ui.closeButton.Position = UDim2.new(1, -29, 0, 5)
ui.closeButton.BackgroundTransparency = 1
ui.closeButton.Text = "×"
ui.closeButton.TextColor3 = Color3.fromRGB(180, 180, 180)
ui.closeButton.Font = Enum.Font.GothamBold
ui.closeButton.TextSize = 18
ui.closeButton.Parent = ui.panel

ui.status = Instance.new("TextLabel")
ui.status.Size = UDim2.new(1, -20, 0, 18)
ui.status.Position = UDim2.fromOffset(10, 31)
ui.status.BackgroundTransparency = 1
ui.status.Text = "OFF"
ui.status.TextColor3 = Color3.fromRGB(170, 170, 170)
ui.status.Font = Enum.Font.Gotham
ui.status.TextSize = 11
ui.status.TextXAlignment = Enum.TextXAlignment.Left
ui.status.Parent = ui.panel

ui.speedBox = Instance.new("TextBox")
ui.speedBox.Size = UDim2.fromOffset(92, 30)
ui.speedBox.Position = UDim2.fromOffset(10, 54)
ui.speedBox.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
ui.speedBox.BorderSizePixel = 0
ui.speedBox.TextColor3 = Color3.new(1, 1, 1)
ui.speedBox.PlaceholderText = "Speed"
ui.speedBox.Text = tostring(flyRuntime.Speed)
ui.speedBox.Font = Enum.Font.Gotham
ui.speedBox.TextSize = 12
ui.speedBox.ClearTextOnFocus = false
ui.speedBox.Parent = ui.panel
Instance.new("UICorner", ui.speedBox).CornerRadius = UDim.new(0, 8)

ui.toggle = Instance.new("TextButton")
ui.toggle.Size = UDim2.fromOffset(102, 30)
ui.toggle.Position = UDim2.fromOffset(108, 54)
ui.toggle.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
ui.toggle.BorderSizePixel = 0
ui.toggle.TextColor3 = Color3.new(1, 1, 1)
ui.toggle.Text = "ENABLE"
ui.toggle.Font = Enum.Font.GothamBold
ui.toggle.TextSize = 11
ui.toggle.Parent = ui.panel
Instance.new("UICorner", ui.toggle).CornerRadius = UDim.new(0, 8)

ui.noClipToggle = Instance.new("TextButton")
ui.noClipToggle.Size = UDim2.fromOffset(200, 30)
ui.movementModeToggle = Instance.new("TextButton")
ui.movementModeToggle.Size = UDim2.fromOffset(200, 30)
ui.movementModeToggle.Position = UDim2.fromOffset(10, 91)
ui.movementModeToggle.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
ui.movementModeToggle.BorderSizePixel = 0
ui.movementModeToggle.TextColor3 = Color3.new(1, 1, 1)
ui.movementModeToggle.Font = Enum.Font.GothamBold
ui.movementModeToggle.TextSize = 11
ui.movementModeToggle.Parent = ui.panel
Instance.new("UICorner", ui.movementModeToggle).CornerRadius = UDim.new(0, 8)

ui.noClipToggle.Position = UDim2.fromOffset(10, 126)
ui.noClipToggle.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
ui.noClipToggle.BorderSizePixel = 0
ui.noClipToggle.TextColor3 = Color3.new(1, 1, 1)
ui.noClipToggle.Font = Enum.Font.GothamBold
ui.noClipToggle.TextSize = 11
ui.noClipToggle.Parent = ui.panel
Instance.new("UICorner", ui.noClipToggle).CornerRadius = UDim.new(0, 8)

ui.collisionDebugToggle = Instance.new("TextButton")
ui.collisionDebugToggle.Size = UDim2.fromOffset(97, 30)
ui.collisionDebugToggle.Position = UDim2.fromOffset(10, 161)
ui.collisionDebugToggle.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
ui.collisionDebugToggle.BorderSizePixel = 0
ui.collisionDebugToggle.TextColor3 = Color3.new(1, 1, 1)
ui.collisionDebugToggle.Font = Enum.Font.GothamBold
ui.collisionDebugToggle.TextSize = 10
ui.collisionDebugToggle.Parent = ui.panel
Instance.new("UICorner", ui.collisionDebugToggle).CornerRadius = UDim.new(0, 8)

ui.cameraFeelToggle = Instance.new("TextButton")
ui.cameraFeelToggle.Size = UDim2.fromOffset(97, 30)
ui.cameraFeelToggle.Position = UDim2.fromOffset(113, 161)
ui.cameraFeelToggle.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
ui.cameraFeelToggle.BorderSizePixel = 0
ui.cameraFeelToggle.TextColor3 = Color3.new(1, 1, 1)
ui.cameraFeelToggle.Font = Enum.Font.GothamBold
ui.cameraFeelToggle.TextSize = 10
ui.cameraFeelToggle.Parent = ui.panel
Instance.new("UICorner", ui.cameraFeelToggle).CornerRadius = UDim.new(0, 8)

-- V169: startup animation master toggle.
ui.startupAnimationToggle = Instance.new("TextButton")
ui.startupAnimationToggle.Size = UDim2.fromOffset(200, 30)
ui.startupAnimationToggle.Position = UDim2.fromOffset(10, 196)
ui.startupAnimationToggle.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
ui.startupAnimationToggle.BorderSizePixel = 0
ui.startupAnimationToggle.TextColor3 = Color3.new(1, 1, 1)
ui.startupAnimationToggle.Font = Enum.Font.GothamBold
ui.startupAnimationToggle.TextSize = 10
ui.startupAnimationToggle.Parent = ui.panel
Instance.new("UICorner", ui.startupAnimationToggle).CornerRadius = UDim.new(0, 8)

ui.hint = Instance.new("TextLabel")
ui.hint.Size = UDim2.new(1, -20, 0, 28)
ui.hint.Position = UDim2.fromOffset(10, 268)
ui.hint.BackgroundTransparency = 1
ui.hint.Text = "Move + look to climb/dive   •   Space/Ctrl optional"
ui.hint.TextColor3 = Color3.fromRGB(145, 145, 145)
ui.hint.Font = Enum.Font.Gotham
ui.hint.TextSize = 9
ui.hint.TextXAlignment = Enum.TextXAlignment.Left
ui.profileToggle = Instance.new("TextButton")
ui.profileToggle.Size = UDim2.fromOffset(200, 30)
ui.profileToggle.Position = UDim2.fromOffset(10, 233)
ui.profileToggle.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
ui.profileToggle.BorderSizePixel = 0
ui.profileToggle.TextColor3 = Color3.new(1, 1, 1)
ui.profileToggle.Font = Enum.Font.GothamBold
ui.profileToggle.TextSize = 10
ui.profileToggle.Parent = ui.panel
Instance.new("UICorner", ui.profileToggle).CornerRadius = UDim.new(0, 8)

ui.hint.Parent = ui.panel

-- Small shortcut button used after the mini GUI is hidden.
ui.shortcut = Instance.new("TextButton")
ui.shortcut.Size = UDim2.fromOffset(74, 32)
ui.shortcut.Position = UDim2.new(1, -84, 0, 92)
ui.shortcut.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
ui.shortcut.BackgroundTransparency = 0.08
ui.shortcut.BorderSizePixel = 0
ui.shortcut.TextColor3 = Color3.new(1, 1, 1)
ui.shortcut.Text = "✈  FLY"
ui.shortcut.Font = Enum.Font.GothamBold
ui.shortcut.TextSize = 11
ui.shortcut.Visible = false
ui.shortcut.Parent = flyGui.ScreenGui
Instance.new("UICorner", ui.shortcut).CornerRadius = UDim.new(0, 10)

-- Freecam-style Shift Lock button.
-- EXACT FreeCam_Standalone.lua dimensions/placement:
--   Size = 30x30
--   AnchorPoint = (0, 0.5)
--   Position = (0, 18, 0.5, 0)
--   ZIndex = 2001
flyGui.ShiftLockButton = Instance.new("ImageButton")
flyGui.ShiftLockButton.Name = "VGD_FlyShiftLock"
flyGui.ShiftLockButton.Size = UDim2.fromOffset(30,30)
flyGui.ShiftLockButton.AnchorPoint = Vector2.new(0,0.5)
flyGui.ShiftLockButton.Position = UDim2.new(0,18,0.5,0)
flyGui.ShiftLockButton.BackgroundTransparency = 1
flyGui.ShiftLockButton.BorderSizePixel = 0
flyGui.ShiftLockButton.AutoButtonColor = false
flyGui.ShiftLockButton.ScaleType = Enum.ScaleType.Fit
flyGui.ShiftLockButton.Visible = false
flyGui.ShiftLockButton.ZIndex = 2001
flyGui.ShiftLockButton.Parent = flyGui.ScreenGui

updateFlyShiftLockButton = function()
    if not flyGui.ShiftLockButton then return end
    flyGui.ShiftLockButton.Visible = flyRuntime.Enabled
    flyGui.ShiftLockButton.Image = flyGui.ShiftLockOn
        and "rbxasset://textures/ui/mouseLock_on@2x.png"
        or "rbxasset://textures/ui/mouseLock_off@2x.png"
end

flyGui.ShiftLockButton.Activated:Connect(function()
    if not flyRuntime.Enabled then return end
    flyGui.ShiftLockOn = not flyGui.ShiftLockOn
    updateFlyShiftLockButton()
end)

local function refreshUI()
    if flyRuntime.Enabled and flyStartup.Active then
        ui.status.Text = "TAKEOFF  •  Speed " .. tostring(math.floor(flyRuntime.Speed + 0.5))
    elseif flyRuntime.Enabled then
        ui.status.Text = "ON  •  Speed " .. tostring(math.floor(flyRuntime.Speed + 0.5))
    else
        ui.status.Text = "OFF"
    end
    ui.toggle.Text = flyRuntime.Enabled and "DISABLE" or "ENABLE"
    ui.shortcut.Text = flyRuntime.Enabled and "✈  ON" or "✈  FLY"
    ui.movementModeToggle.Text = "MODE  •  " .. flyGui.MovementMode
    ui.noClipToggle.Text = "NO CLIP  •  " .. (flyGui.NoClipOn and "ON" or "OFF")
    ui.collisionDebugToggle.Text = "COLLISION  •  " .. (flyCollision.DebugOn and "ON" or "OFF")
    ui.cameraFeelToggle.Text = "CAMERA FEEL  •  " .. (flyGui.CameraFeelOn and "ON" or "OFF")
    ui.startupAnimationToggle.Text = "STARTUP ANIMATION  •  " .. (flyStartup.AnimationEnabled and "ON" or "OFF")
    ui.profileToggle.Text = "PROFILE  •  " .. flyProfile
end

local function showMiniGui(show)
    flyGui.ScreenGui.Enabled = show == true
    if flyGui.ScreenGui.Enabled then
        ui.panel.Visible = true
        ui.shortcut.Visible = false
    end
end

ui.closeButton.Activated:Connect(function()
    if flyGui.ScreenGui.Enabled then
        ui.panel.Visible = false
        ui.shortcut.Visible = true
    end
end)

ui.profileToggle.Activated:Connect(function()
    if flyRuntime.Enabled then return end
    flyProfile = flyProfile == "Fly 1" and "Fly 2" or "Fly 1"
    refreshUI()
end)

ui.toggle.Activated:Connect(function()
    if flyRuntime.Enabled then disableFly() else enableFly() end
end)

ui.shortcut.Activated:Connect(function()
    ui.panel.Visible = true
    ui.shortcut.Visible = false
end)

ui.movementModeToggle.Activated:Connect(function()
    if flyRuntime.Enabled then return end
    flyGui.MovementMode = flyGui.MovementMode == "CFrame" and "Normal" or "CFrame"
    refreshUI()
end)

ui.noClipToggle.Activated:Connect(function()
    if not flyRuntime.Enabled then return end
    flyGui.NoClipOn = not flyGui.NoClipOn
    setFlyNoClip(flyGui.NoClipOn)
    refreshUI()
end)

ui.collisionDebugToggle.Activated:Connect(function()
    if not flyRuntime.Enabled then return end
    flyCollision.DebugOn = not flyCollision.DebugOn
    flyCollision.UpdateDebug()
    refreshUI()
end)

ui.cameraFeelToggle.Activated:Connect(function()
    if not flyRuntime.Enabled then return end
    flyGui.CameraFeelOn = not flyGui.CameraFeelOn
    if not flyGui.CameraFeelOn then
        flyState.flyCameraVelocityBlend = Vector3.zero
        flyState.flyCameraTurnLag = 0
        flyState.flyCameraFOVBlend = 0
        flyState.flyCameraLastYaw = flyState.flyCameraYaw
    end
    refreshUI()
end)

ui.startupAnimationToggle.Activated:Connect(function()
    flyStartup.AnimationEnabled = not flyStartup.AnimationEnabled

    -- If the user turns startup OFF while it is currently playing, cancel it
    -- cleanly and hand control straight to normal Fly Idle. Turning it ON
    -- affects the next Fly activation (not the current session).
    if not flyStartup.AnimationEnabled and flyRuntime.Enabled then
        local fly2StartupTrack = flyRuntime.Tracks.fly2Startup
        if flyProfile == "Fly 2" and flyRuntime.Fly2StartupPending then
            flyRuntime.Fly2StartupPending = false
            flyRuntime.Fly2TornadoHandoffPending = false
            if fly2StartupTrack then
                pcall(function() fly2StartupTrack:Stop(FLY_CONFIG.FLY2_TRANSITION_BLEND) end)
            end
            startNormalFlyAnimationSet(true)
        elseif flyStartup.Active then
            flyStartup.Active = false
            flyStartup.Time = 0
            flyStartup.StartPosition = nil
            stopFlyStartupAnimation()
            stopFlyStartupPoseDriver()
            clearFlyStartupPose()
            clearStartupAnimatorSuppression()

            startNormalFlyAnimationSet()
        end
    end

    refreshUI()
end)

ui.speedBox.FocusLost:Connect(function()
    local value = tonumber(ui.speedBox.Text)
    if value then flyRuntime.Speed = math.clamp(value, flyRuntime.MinSpeed, flyRuntime.MaxSpeed) end
    ui.speedBox.Text = tostring(math.floor(flyRuntime.Speed + 0.5))
    refreshUI()
end)

flyState.stateChangedEvent.Event:Connect(function(enabled)
    -- Changing Fly state must never change GUI visibility.
    -- ENABLE/DISABLE only controls the Fly feature itself.
    -- The X button is the only thing that closes the panel.
    refreshUI()
end)

refreshUI()

local Controller = {}
function Controller.EnableUI()
    -- VGD Self-page Toggle ON: expose the Fly feature without starting flight.
    flyGui.ScreenGui.Enabled = true
    ui.panel.Visible = false
    ui.shortcut.Visible = true
    refreshUI()
    return true
end
function Controller.DisableUI()
    -- VGD Self-page Toggle OFF: stop flight if necessary and remove the whole
    -- Fly UI (shortcut + mini GUI).
    disableFly()
    refreshUI()
    ui.panel.Visible = false
    ui.shortcut.Visible = false
    flyGui.ScreenGui.Enabled = false
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
function Controller.IsEnabled() return flyRuntime.Enabled == true end
function Controller.SetSpeed(value)
    local n = tonumber(value)
    if not n then return flyRuntime.Speed end
    flyRuntime.Speed = math.clamp(n, flyRuntime.MinSpeed, flyRuntime.MaxSpeed)
    ui.speedBox.Text = tostring(math.floor(flyRuntime.Speed + 0.5))
    refreshUI()
    return flyRuntime.Speed
end
function Controller.GetSpeed() return flyRuntime.Speed end
function Controller.ShowUI() showMiniGui(true) end
function Controller.HideUI()
    if flyGui.ScreenGui.Enabled then
        ui.panel.Visible = false
        ui.shortcut.Visible = true
    end
end
Controller.Changed = flyState.stateChangedEvent.Event
return Controller
end

return buildMiniGui()
