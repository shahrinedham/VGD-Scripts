-- VGD Fly Standalone v198
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

-- V169 register-pressure fix: group camera state into one local table.
local flyState = {}
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
local flyCameraSavedMinZoom = nil
local flyCameraSavedMaxZoom = nil
local flySpectatingOtherPlayer = false
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
local flyCameraMouseLooking = false
local flyCameraConnections = {}

-- v57 camera/flight-feel state. These are visual-only layers; they do not
-- replace the proven v56 movement/camera ownership architecture.
flyState.flyCameraVelocityBlend = Vector3.zero
flyState.flyCameraTurnLag = 0
flyState.flyCameraFOVBlend = 0
flyState.flyCameraLastYaw = nil
local flyCameraLastMoveVector = Vector3.zero

flyState.flyAccelerationBlend = 0
flyState.flyDecelerationBlend = 0
flyState.flyDirectionChangeBlend = 0
flyState.flyPreviousMoveDirection = Vector3.zero
flyState.flyPreviousSpeed = 0

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

-- Best-effort access to Roblox's live CameraModule controller.
-- Current Roblox builds intentionally hide GetCameras() behind an API flag,
-- so this may return nil. When it is available, setting the controller's
-- nominal subject distance directly is the only way to seed the same internal
-- value that Custom camera uses without relying on the visible zoom-limit hack.
local function getRobloxCameraController()
    local controller = nil
    pcall(function()
        local playerScripts = player:FindFirstChildOfClass("PlayerScripts")
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
local BACKWARD_ANIMATION_ID = "rbxassetid://75806320773060"

-- V198 behavior preserved. Fidget configuration/state is supplied by the external module.
local FLY_FIDGET_MODULE_URL = "https://raw.githubusercontent.com/shahrinedham/VGD-Scripts/main/Modules/Fly_Fidget.lua"
local FlyFidgetModule = loadstring(game:HttpGet(FLY_FIDGET_MODULE_URL))()
local flyIdleFidget = FlyFidgetModule.new()

-- V178: Startup ON uses the new dedicated takeoff animation normally.
-- The animation begins in the desired landing/crouch pose, so there is no
-- reverse playback. Startup blends into frame 0, then releases the animation
-- immediately into the takeoff and Fly Idle handoff.
-- Runtime finder confirmed this animation as ID 112472797825991 with a length
-- of approximately 2.650 seconds.
local FLY_STARTUP_ANIMATION_ID = "rbxassetid://112472797825991"

-- V181 Startup ON timing: blend into the landing/crouch pose for 0.60s,
-- then start the asset immediately with no extra pose hold. The physical
-- root lift waits 0.30s into the asset so the animation can leave the crouch
-- before the character itself starts rising.
local FLY_STARTUP_POSE_BLEND_TIME = 0.60
local FLY_STARTUP_POSE_HOLD_TIME = 0.30
local FLY_STARTUP_CUT_TIME = 0.90

-- V183: use only the FIRST 4.000 seconds of the dedicated ascend animation.
-- The source asset is 7.000 seconds long, but only the first 4.000 seconds
-- are intentionally included. Compress the first 4.000 seconds into 0.60 seconds,
-- giving approximately a 6.67x playback speed.
local FLY_STARTUP_ASCEND_ANIMATION_ID = "rbxassetid://89651854762169"
local FLY_STARTUP_ASCEND_SOURCE_DURATION = 4.00
local FLY_STARTUP_ASCEND_PLAY_DURATION = 0.60
local FLY_STARTUP_ASCEND_BLEND_IN = 0.50
local FLY_STARTUP_ASCEND_FADE_OUT = 0.60
local FLY_STARTUP_LAUNCH_DELAY = 0.50
local FLY_STARTUP_LAUNCH_DURATION = 0.60
local FLY_STARTUP_ASSET_DURATION = 2.65
-- V169: user-facing master switch. The GUI can turn startup on/off without
-- changing any of the existing Fly camera, movement, joystick, or idle logic.
local flyStartupAnimationEnabled = true


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

-- V198: corrected interruption handoff; preserve the live fidget pose and smoothly redirect the incoming movement direction.
-- An interrupted fidget crossfades directly into the live Forward/Backward
-- direction over the fidget's configured blend-out window.
-- V196: V195 baseline plus fidget blend tuning.
-- After 10 seconds of true Fly Idle, the three fidgets cycle in order. Fidget #1 keeps
-- the tested 1.350s -> 6.350s window with a 0.700s blend-in and 1.000s blend-out;
-- Fidget #2 uses its full 7.458s source with a 0.350s blend-in and 1.000s blend-out;
-- Fidget #3 uses its full 10.000s source with a 0.700s blend-in and 0.800s blend-out.
-- V191 startup synchronization and V190.12 reversal behavior are preserved.
-- V191: V190.12 functional baseline plus synchronized startup crossfade and V190-like response curve for
-- Forward <-> Backward reversal feel. State handling and no-snap logic remain unchanged.
-- The Fly Idle track is used only as a temporary pose cushion while the
-- outgoing and incoming direction tracks remain continuously crossfaded.
-- Unlike the earlier neutral-bridge tests, Idle never becomes the visible
-- standalone state, so there is no stop/pause between directions.
local FLY_DIRECTION_CONTINUOUS_BLEND_TIME = 0.45
local FLY_DIRECTION_CONTINUOUS_IDLE_MAX = 0.30
local flyDirectionTransitionActive = false
local flyDirectionTransitionFrom = nil
local flyDirectionTransitionTo = nil
local flyDirectionTransitionTime = 0

-- V190.9 diagnostic: remember the actual requested animation state, not just
-- whichever directional track still has the larger weight. This prevents a
-- stopped Forward/Backward track from being mistaken for the active direction
-- when the player starts moving again in the opposite direction.
local flyPreviousDesiredState = "Idle"
local flyLastDirectionalState = nil
-- Require a tiny real Idle dwell before treating the next movement as a
-- fresh Idle -> Direction transition. This filters a one-frame mobile input
-- deadzone/flicker so a genuine reversal cannot accidentally bypass the blend.
local flyIdleStableTime = 0
local FLY_IDLE_STABLE_THRESHOLD = 0.05

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
local flyStartupActive = false
local flyStartupTime = 0
local flyStartupDuration = FLY_STARTUP_POSE_BLEND_TIME + FLY_STARTUP_POSE_HOLD_TIME + FLY_STARTUP_ASSET_DURATION
local flyStartupHeight = 4.15
local flyStartupStartPosition = nil
local flyStartupPoseJoints = nil
local flyStartupJointBases = nil
local flyStartupPreSimulationConnection = nil
local flyStartupSuppressedTracks = {}

-- V169 existing-emote AnimationTrack startup path.
local flyStartupAnimationTrack = nil
local flyStartupAnimationStoppedConnection = nil
local flyStartupAnimationMonitorConnection = nil
local flyStartupAnimationReady = false
local flyStartupAssetActive = false
local flyStartupLaunchActive = false
local flyStartupLaunchTime = 0
local flyStartupAscendTrack = nil
local flyStartupAscendStoppedConnection = nil
local flyStartupFinalBlendActive = false
local flyStartupFinalBlendTime = 0

-- V126 controlled joint diagnostic. This deliberately runs BEFORE the
-- procedural startup animation so we can prove that the live avatar rig
-- accepts PreSimulation Transform writes without changing camera/movement.
local flyJointDiagnosticActive = false
local flyJointDiagnosticTime = 0
local flyJointDiagnosticDuration = 1.8
local flyJointDiagnosticJoint = nil
local flyJointDiagnosticClass = "None"
local flyJointDiagnosticBodyPart = "RightUpperArm"

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
    flyJointDiagnosticActive = true
    flyJointDiagnosticTime = 0
    flyJointDiagnosticJoint, flyJointDiagnosticClass =
        findJointForBodyPart(character, flyJointDiagnosticBodyPart)

end

local function stopFlyJointDiagnostic()
    flyJointDiagnosticActive = false
    flyJointDiagnosticTime = 0

    if flyStartupPoseJoints then
        for _, joint in pairs(flyStartupPoseJoints) do
            if joint and joint.Parent then
                pcall(function() joint.Transform = CFrame.identity end)
            end
        end
    end
end

local function updateFlyJointDiagnostic(dt)
    if not flyJointDiagnosticActive then return false end

    flyJointDiagnosticTime += math.max(dt or 0, 0)

    -- Reset every cached joint so the diagnostic cannot accidentally inherit
    -- a player animation pose. Only the selected shoulder receives motion.
    if flyStartupPoseJoints then
        for _, joint in pairs(flyStartupPoseJoints) do
            if joint and joint.Parent then
                pcall(function() joint.Transform = CFrame.identity end)
            end
        end
    end

    local joint = flyJointDiagnosticJoint
    if joint and joint.Parent then
        local t = flyJointDiagnosticTime
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

    return flyJointDiagnosticTime < flyJointDiagnosticDuration
end

local R15_STARTUP_JOINTS = {
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
}

local function suppressStartupAnimatorTracks(humanoid)
    if not humanoid then return end

    local animator = humanoid:FindFirstChildOfClass("Animator")
    if not animator then return end

    for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
        if track and track.IsPlaying then
            flyStartupSuppressedTracks[track] = true
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
    table.clear(flyStartupSuppressedTracks)
end

local function cacheFlyStartupJoints(character)
    flyStartupPoseJoints = {}
    flyStartupJointBases = {}

    -- IMPORTANT: Roblox animation Pose channels are named after BODY PARTS,
    -- not after Motor6D objects. The corresponding joint is the Motor6D /
    -- AnimationConstraint connecting that body part to its parent.
    --
    -- Previous versions found joints by their joint names ("LeftHip",
    -- "LeftKnee", etc.) and then attempted to convert the authored pose
    -- through C0.Rotation. That was not equivalent to Roblox's animation
    -- system and was the main reason the crouch could look like a torso bend.
    for _, channelName in ipairs(R15_STARTUP_JOINTS) do
        local info = R15_POSE_PARTS[channelName]
        local joint = info and findJointForBodyPart(character, info.part)

        if joint then
            flyStartupPoseJoints[channelName] = joint

            -- Pose.CFrame is already the animation Transform. Do NOT convert
            -- it through C0.Rotation. Roblox applies the Pose CFrame directly
            -- to the corresponding joint's Transform.
            flyStartupJointBases[channelName] = nil

            pcall(function()
                joint.Transform = CFrame.identity
            end)
        end
    end
end

local function setStartupTransform(name, transform)
    local joint = flyStartupPoseJoints and flyStartupPoseJoints[name]
    if not joint or not joint.Parent then return end

    -- V150: direct Pose.CFrame -> Transform mapping.
    -- This matches Roblox's documented animation path and removes the custom
    -- basis conversion that was distorting the authored R15 axes.
    pcall(function()
        joint.Transform = transform
    end)
end

local function clearFlyStartupPose()
    if flyStartupPoseJoints then
        for _, joint in pairs(flyStartupPoseJoints) do
            if joint and joint.Parent then
                pcall(function()
                    joint.Transform = CFrame.identity
                end)
            end
        end
    end

    flyStartupPoseJoints = nil
    flyStartupJointBases = nil
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

local flyStartupSequence = nil
local flyStartupPoseMap = nil

local R15_POSE_PARTS = {
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
}

local function suppressStartupAnimatorTracks(humanoid)
    if not humanoid then return end

    local animator = humanoid:FindFirstChildOfClass("Animator")
    if not animator then return end

    for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
        if track and track.IsPlaying then
            flyStartupSuppressedTracks[track] = true
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
    table.clear(flyStartupSuppressedTracks)
end

local function cacheFlyStartupJoints(character)
    flyStartupPoseJoints = {}
    flyStartupJointBases = {}

    -- V150 IMPORTANT:
    -- This is the ACTIVE definition (Lua uses the last function definition).
    -- Resolve each animation channel by the R15 BODY PART it controls, exactly
    -- like Roblox Pose -> Motor6D.Transform animation mapping. Do not resolve
    -- by Motor6D object name and do not apply a C0.Rotation basis conversion.
    for _, channelName in ipairs(R15_STARTUP_JOINTS) do
        local info = R15_POSE_PARTS[channelName]
        local joint = info and findJointForBodyPart(character, info.part)

        if joint then
            flyStartupPoseJoints[channelName] = joint
            flyStartupJointBases[channelName] = nil

            pcall(function()
                joint.Transform = CFrame.identity
            end)
        end
    end
end

local function setStartupTransform(name, transform)
    local joint = flyStartupPoseJoints and flyStartupPoseJoints[name]
    if not joint or not joint.Parent then return end

    -- V150: Pose.CFrame is written directly to the resolved joint Transform.
    pcall(function()
        joint.Transform = transform
    end)
end

local function clearFlyStartupPose()
    if flyStartupPoseJoints then
        for _, joint in pairs(flyStartupPoseJoints) do
            if joint and joint.Parent then
                pcall(function()
                    joint.Transform = CFrame.identity
                end)
            end
        end
    end

    flyStartupPoseJoints = nil
    flyStartupSequence = nil
    flyStartupPoseMap = nil
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
                R15_POSE_PARTS[entry[1]].part,
                entry[2]
            )
        end

        -- Root is represented by the LowerTorso Pose under HumanoidRootPart.
        local root = makePose("HumanoidRootPart", CFrame.identity)
        root.Weight = 0
        root.Parent = parentPose

        for jointName, info in pairs(R15_POSE_PARTS) do
            local node = nodes[jointName]
            if node then
                local parentNode = root
                for otherName, otherInfo in pairs(R15_POSE_PARTS) do
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
                for jointName, info in pairs(R15_POSE_PARTS) do
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
    local frames = flyStartupPoseMap
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
    if not flyStartupPoseJoints then return end

    local previous, nextFrame, alpha = getStartupPoseAtTime(seconds)
    if not previous or not nextFrame then return end

    for _, name in ipairs(R15_STARTUP_JOINTS) do
        local a = previous.joints[name] or CFrame.identity
        local b = nextFrame.joints[name] or CFrame.identity
        setStartupTransform(name, a:Lerp(b, alpha))
    end
end

-- V127: forward declaration because the startup PreSimulation driver
-- is defined before the character helper implementation.
local getHumanoidAndRoot

local function startFlyStartupPoseDriver()
    if flyStartupPreSimulationConnection then
        flyStartupPreSimulationConnection:Disconnect()
        flyStartupPreSimulationConnection = nil
    end

    if flyStartupAssetActive then
        -- V169: a real AnimationTrack owns the startup pose. Do not also
        -- write Motor6D.Transform procedurally, or the two animation systems
        -- would fight each other.
        return
    end

    flyStartupSequence = buildRuntimeKeyframeSequence()
    flyStartupPoseMap = buildStartupPoseMap(flyStartupSequence)

    flyStartupPreSimulationConnection = RunService.PreSimulation:Connect(function()
        if not flyEnabled or not flyStartupActive then
            return
        end

        local humanoid = getHumanoidAndRoot()
        maintainStartupAnimatorSuppression(humanoid)

        -- V127 diagnostic has priority over the startup player. It proves the
        -- actual live joint type and Transform write path before we spend any
        -- more time tuning the superhero choreography.
        if flyJointDiagnosticActive then
            updateFlyJointDiagnostic(1 / 60)
            return
        end

        -- This is the runtime equivalent of an AnimationTrack playing the
        -- KeyframeSequence. The timeline is continuous, and each joint is
        -- interpolated between the surrounding Pose.CFrame values.
        applySuperheroTakeoffPose(flyStartupTime)
    end)
end

local function stopFlyStartupAnimation()
    if flyStartupAnimationStoppedConnection then
        flyStartupAnimationStoppedConnection:Disconnect()
        flyStartupAnimationStoppedConnection = nil
    end

    if flyStartupAnimationMonitorConnection then
        flyStartupAnimationMonitorConnection:Disconnect()
        flyStartupAnimationMonitorConnection = nil
    end

    local track = flyStartupAnimationTrack
    flyStartupAnimationTrack = nil
    flyStartupAnimationReady = false
    flyStartupAssetActive = false
    flyStartupFinalBlendActive = false
    flyStartupFinalBlendTime = 0

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

    if flyStartupAscendStoppedConnection then
        flyStartupAscendStoppedConnection:Disconnect()
        flyStartupAscendStoppedConnection = nil
    end
    local ascendTrack = flyStartupAscendTrack
    flyStartupAscendTrack = nil
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

    local animate = flyAnimateScript
    local idle = flyTracks.idle
    local move = flyTracks.move
    local backward = flyTracks.backward

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
    flyAnimState = "Idle"
    flyPreviousDesiredState = "Idle"
    flyIdleStableTime = 0
    flyIdleFidget.idleTime = 0
    flyIdleFidget.active = false
    flyIdleFidget.elapsed = 0
    flyIdleFidget.activeVariant = 1
    FlyFidgetModule.resetTracks(flyTracks)

    if smoothBlend then
        -- V169: DO NOT disable Roblox Animate at the end of the handoff.
        -- The Fly tracks already use Action priority, so they can blend over
        -- the live Roblox idle without forcing the Animator to rebuild the
        -- pose on one frame. Disabling Animate here was the remaining source
        -- of the visible Startup OFF snap after PlatformStand was removed.
        task.delay(0.90, function()
            if not flyEnabled or flyStartupActive then
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
    if not flyEnabled or not flyStartupActive then
        return
    end

    flyStartupAssetActive = false
    flyStartupAnimationReady = false
    flyStartupActive = false
    flyStartupTime = 0
    flyStartupStartPosition = nil

    if flyStartupAnimationMonitorConnection then
        flyStartupAnimationMonitorConnection:Disconnect()
        flyStartupAnimationMonitorConnection = nil
    end

    if flyStartupAnimationStoppedConnection then
        flyStartupAnimationStoppedConnection:Disconnect()
        flyStartupAnimationStoppedConnection = nil
    end

    local track = flyStartupAnimationTrack
    flyStartupAnimationTrack = nil
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
    animation.AnimationId = FLY_STARTUP_ASCEND_ANIMATION_ID
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
    flyStartupAscendTrack = track

    -- Start invisible and frozen at frame 0. The weight ramp supplies the
    -- 0.90 -> 1.40s crouch-to-ascend transition.
    track:Play(0, 0.001, 0)
    track.TimePosition = 0
    track:AdjustWeight(0, 0)
    track:AdjustSpeed(FLY_STARTUP_ASCEND_SOURCE_DURATION / FLY_STARTUP_ASCEND_PLAY_DURATION)
    track:AdjustWeight(1, FLY_STARTUP_ASCEND_BLEND_IN)

    flyStartupAscendStoppedConnection = track.Stopped:Connect(function()
        if flyStartupAscendTrack == track then
            flyStartupAscendTrack = nil
        end
    end)

    -- Keep the final ascend pose visible until the 1.40 -> 2.00s Fly Idle
    -- handoff is complete, then clean the track up.
    task.delay(FLY_STARTUP_ASCEND_PLAY_DURATION, function()
        if flyStartupAscendTrack ~= track then
            return
        end
        track:AdjustSpeed(0)
    end)

    return true
end

local function startFlyStartupAnimation(humanoid)
    stopFlyStartupAnimation()

    if not humanoid or FLY_STARTUP_ANIMATION_ID == "" then
        return false
    end

    local animator = humanoid:FindFirstChildOfClass("Animator")
    if not animator then
        animator = Instance.new("Animator")
        animator.Parent = humanoid
    end

    local animation = Instance.new("Animation")
    animation.Name = "VGD_FlyStartup_V181"
    animation.AnimationId = FLY_STARTUP_ANIMATION_ID
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

    flyStartupAnimationTrack = track
    flyStartupAssetActive = true
    flyStartupAnimationReady = false

    -- V181: Startup ON begins from frame 0 of the new dedicated takeoff
    -- animation. Keep the track frozen and effectively invisible while it
    -- blends from the player's current pose into the landing/crouch pose.
    -- After the 0.60s blend, playback is released forward immediately.
    track:Play(0, 0.001, 0)
    track:AdjustSpeed(0)
    track:AdjustWeight(0.001, 0)

    flyStartupAnimationStoppedConnection = track.Stopped:Connect(function()
        -- An explicit Fly disable or our controlled finish path stops the track.
        -- Only an unexpected stop while startup is still active should trigger
        -- the safe normal-Fly handoff.
        if flyEnabled and flyStartupActive and flyStartupAssetActive then
            finishFlyStartupAnimation()
        end
    end)

    task.spawn(function()
        local deadline = os.clock() + 1.50

        while flyEnabled
            and flyStartupActive
            and flyStartupAssetActive
            and track.IsPlaying
            and track.Length <= 0.05
            and os.clock() < deadline do
            task.wait()
        end

        if not flyEnabled
            or not flyStartupActive
            or not flyStartupAssetActive
            or flyStartupAnimationTrack ~= track
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

        flyStartupDuration = FLY_STARTUP_POSE_BLEND_TIME
            + FLY_STARTUP_POSE_HOLD_TIME
            + length
        flyStartupTime = 0

        -- Frame 0 is the desired landing/crouch pose. The track remains frozen
        -- there while its weight is blended in over 0.60s. Playback then starts
        -- immediately so the animation can leave the crouch before root lift.
        if not track.IsPlaying then
            track:Play(0, 0.001, 0)
            track:AdjustSpeed(0)
        end

        track.TimePosition = 0
        flyStartupAnimationReady = true
        track:AdjustWeight(1, FLY_STARTUP_POSE_BLEND_TIME)

        task.delay(FLY_STARTUP_POSE_BLEND_TIME + FLY_STARTUP_POSE_HOLD_TIME, function()
            if not flyEnabled
                or not flyStartupActive
                or not flyStartupAssetActive
                or flyStartupAnimationTrack ~= track
                or not track.IsPlaying then
                return
            end

            track.TimePosition = 0
            track:AdjustSpeed(1)
        end)

        flyStartupAnimationMonitorConnection = RunService.Heartbeat:Connect(function()
            if not flyEnabled
                or not flyStartupActive
                or not flyStartupAssetActive
                or flyStartupAnimationTrack ~= track then
                return
            end

            -- V181: the landing asset is intentionally used only for the visible
            -- crouch/landing portion. Do NOT let its long crouched section
            -- continue for the remaining ~2 seconds. At 0.90s total startup
            -- time, freeze the current pose, fade it out, and hand the body
            -- to Fly Idle while the real root begins a slow upward launch.
            if flyStartupTime >= FLY_STARTUP_CUT_TIME then
                track.TimePosition = math.min(track.TimePosition, FLY_STARTUP_CUT_TIME)
                track:AdjustSpeed(0)
                track:AdjustWeight(0, FLY_STARTUP_LAUNCH_DURATION)

                flyStartupAssetActive = false
                flyStartupAnimationReady = false
                -- Keep flyStartupActive true through 0.90 -> 1.40s so the
                -- dedicated ascend animation fully owns the pose before Fly Idle
                -- is introduced. It is released at the launch point below.
                if flyStartupAnimationMonitorConnection then
                    flyStartupAnimationMonitorConnection:Disconnect()
                    flyStartupAnimationMonitorConnection = nil
                end
                flyStartupLaunchActive = true
                flyStartupLaunchTime = 0
                local _, launchRoot = getHumanoidAndRoot()
                flyStartupStartPosition = flyStartupStartPosition
                    or (launchRoot and launchRoot.Position)

                if flyStartupAnimationStoppedConnection then
                    flyStartupAnimationStoppedConnection:Disconnect()
                    flyStartupAnimationStoppedConnection = nil
                end

                flyStartupAnimationTrack = nil
                clearStartupAnimatorSuppression()

                -- V181: immediately introduce the dedicated 7-second ascend
                -- animation, compressed into 0.60s. Keep Fly Idle suppressed
                -- until 1.40s so the ascend pose owns the body during the
                -- crouch-to-ascend transition.
                local ascendStarted = startFlyStartupAscendAnimation(humanoid)
                if not ascendStarted then
                    -- Safe fallback: if the ascend asset cannot load, keep the
                    -- previous direct Fly Idle handoff rather than locking startup.
                    flyStartupActive = false
                    startNormalFlyAnimationSet(true)
                end

                pcall(function() track:Stop(FLY_STARTUP_ASCEND_BLEND_IN) end)
                task.delay(FLY_STARTUP_ASCEND_BLEND_IN, function()
                    pcall(function() track:Destroy() end)
                end)
            end
        end)
    end)

    return true
end

local function stopFlyStartupPoseDriver()
    if flyStartupPreSimulationConnection then
        flyStartupPreSimulationConnection:Disconnect()
        flyStartupPreSimulationConnection = nil
    end
end

-- v56: explicit per-track blend weights owned by Fly.
local flyIdleWeight = 1
local flyMoveWeight = 0
local flyBackwardWeight = 0

local function getCharacter()
    return player.Character
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
    for _, track in pairs(flyTracks) do
        pcall(function() track:Stop(0.15) end)
    end
    flyTracks = {}
    flyAnimState = "Idle"
    flyPreviousDesiredState = "Idle"
    flyIdleStableTime = 0
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
    flyTracks.idle = load(IDLE_ANIMATION_ID, Enum.AnimationPriority.Action)
    flyTracks.move = load(MOVE_ANIMATION_ID, Enum.AnimationPriority.Action)
    flyTracks.backward = load(BACKWARD_ANIMATION_ID, Enum.AnimationPriority.Action)
    FlyFidgetModule.loadTracks(flyTracks, load)

    -- V169: NEVER start a Fly-owned animation at full weight during loading.
    -- Both startup modes now enter through the same handoff model:
    --
    --   current Roblox idle -> Fly Idle
    --
    -- Startup ON additionally inserts the reversed landing emote between those
    -- states. Startup OFF simply performs the same smooth handoff without the
    -- emote. Starting Fly Idle here at weight 1 was the source of the visible
    -- one-frame snap before startNormalFlyAnimationSet() could fade it back out.
    flyIdleWeight = 0
    flyMoveWeight = 0
    flyBackwardWeight = 0

end

local function updateFlyAnimations(isMoving, moveDirection, deltaTime, forwardInput)
    local idle = flyTracks.idle
    local move = flyTracks.move
    local backward = flyTracks.backward
    if not idle then return end

    -- During the procedural takeoff, the custom Fly animation tracks must
    -- NOT contribute to the pose. The startup pose is authored directly on
    -- Motor6D.Transform, so leaving the Fly Idle track at weight 1 would make
    -- the character look like it is doing the normal Fly idle while the root
    -- is being lifted.
    if flyStartupActive then
        flyAnimState = "Startup"
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
        local startupFidget = flyTracks.fidget
        if startupFidget then
            pcall(function()
                startupFidget:AdjustWeight(0, 0)
                startupFidget:Stop(0)
            end)
        end
        flyDirectionTransitionActive = false
        -- Keep every Fly track stopped until the procedural startup finishes.
        -- The startup pose owns Motor6D.Transform directly.
        return
    end

    local desiredState = "Idle"
    if isMoving and moveDirection.Magnitude > 0.001 then
        desiredState = (forwardInput or 0) < -0.15 and "Backward" or "Forward"
    end

    flyAnimState = desiredState

    -- V190.9: use hysteresis for Idle detection. A transient zero from the
    -- joystick/controller is NOT allowed to convert the previous direction
    -- into Idle for the next frame. Only a continuously held Idle state past
    -- the threshold commits the state machine to Idle. This prevents the old
    -- direction bug from returning when input briefly flickers during a
    -- Forward <-> Backward reversal.
    local requestedState = desiredState
    if desiredState == "Idle" then
        flyIdleStableTime = math.min(
            flyIdleStableTime + math.max(deltaTime, 0),
            FLY_IDLE_STABLE_THRESHOLD
        )

        if flyIdleStableTime < FLY_IDLE_STABLE_THRESHOLD
            and (flyPreviousDesiredState == "Forward" or flyPreviousDesiredState == "Backward") then
            -- Treat this as a transient input gap. Keep the previous committed
            -- direction alive so the active reversal blend is not destroyed.
            requestedState = flyPreviousDesiredState
        else
            requestedState = "Idle"
        end
    else
        flyIdleStableTime = 0
    end

    flyAnimState = requestedState

    local fidgetVariant = flyIdleFidget.variants[flyIdleFidget.activeVariant] or flyIdleFidget.variants[1]
    local fidget = flyTracks[fidgetVariant.trackKey]
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
            flyIdleFidget.interruptStartFidgetWeight = math.clamp(
                fidget.WeightCurrent, 0, 1
            )
            flyIdleFidget.interruptStartIdleWeight = math.clamp(
                flyIdleWeight, 0, 1
            )
            flyIdleFidget.interruptMoveWeight = 0
            flyIdleFidget.interruptBackwardWeight = 0
            flyIdleFidget.interruptDirectionBlend = requestedState == "Forward" and 1 or 0
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
            fidget = flyTracks[fidgetVariant.trackKey]

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
        flyPreviousDesiredState == "Idle"
        and (requestedState == "Forward" or requestedState == "Backward")

    local residualReversalFrom = nil
    if startedMovingFromIdle then
        -- Use the last directional state before the committed Idle instead of
        -- guessing from current animation weights. This preserves symmetrical
        -- Forward -> Stop -> Backward and Backward -> Stop -> Forward behavior.
        local lastDirectionalState = flyLastDirectionalState
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
        (flyAnimState == "Forward" and flyDirectionTransitionTo == "Backward")
        or (flyAnimState == "Backward" and flyDirectionTransitionTo == "Forward")

    -- V198: preserve the exact current fidget pose on the first movement
    -- frame, then continuously crossfade it into the live direction and allow
    -- the live directional target to redirect without a snap.
    if flyIdleFidget.interrupting and (requestedState == "Forward" or requestedState == "Backward") then
        flyIdleFidget.interruptDuration = math.max(fidgetVariant.blendOut, 0.05)
        flyIdleFidget.interruptElapsed = math.min(
            flyIdleFidget.interruptElapsed + math.max(deltaTime, 0),
            flyIdleFidget.interruptDuration
        )
        flyIdleFidget.interruptT = math.clamp(
            flyIdleFidget.interruptElapsed / flyIdleFidget.interruptDuration,
            0,
            1
        )
        flyIdleFidget.interruptSmoothT =
            flyIdleFidget.interruptT * flyIdleFidget.interruptT
            * (3 - 2 * flyIdleFidget.interruptT)

        local t = flyIdleFidget.interruptSmoothT
        local outgoingScale = 1 - t
        local fidgetWeight = flyIdleFidget.interruptStartFidgetWeight * outgoingScale
        flyIdleWeight = flyIdleFidget.interruptStartIdleWeight * outgoingScale

        -- V198: the interruption target is LIVE. If the player changes from
        -- Forward to Backward (or vice versa) while the fidget handoff is still
        -- in progress, do not restart the blend and do not snap the directional
        -- animation. Redirect the incoming movement share from its CURRENT mix.
        local desiredDirectionBlend = requestedState == "Forward" and 1 or 0
        local directionRedirectAlpha = 1 - math.exp(-math.max(deltaTime, 0) / 0.12)
        flyIdleFidget.interruptDirectionBlend =
            flyIdleFidget.interruptDirectionBlend
            + (desiredDirectionBlend - flyIdleFidget.interruptDirectionBlend)
                * directionRedirectAlpha

        flyMoveWeight = t * flyIdleFidget.interruptDirectionBlend
        flyBackwardWeight = t * (1 - flyIdleFidget.interruptDirectionBlend)
        flyIdleFidget.interruptMoveWeight = flyMoveWeight
        flyIdleFidget.interruptBackwardWeight = flyBackwardWeight

        if idle and not idle.IsPlaying then idle:Play(0, 1, 1) end
        if move and not move.IsPlaying then move:Play(0, 1, 1) end
        if backward and not backward.IsPlaying then backward:Play(0, 1, 1) end
        if idle then idle:AdjustWeight(flyIdleWeight, 0) end
        if move then move:AdjustWeight(flyMoveWeight, 0) end
        if backward then backward:AdjustWeight(flyBackwardWeight, 0) end

        if fidget then
            pcall(function()
                fidget:AdjustWeight(fidgetWeight, 0)
                if flyIdleFidget.interruptT >= 1 then
                    fidget:AdjustWeight(0, 0)
                    fidget:Stop(0)
                end
            end)
        end

        if flyIdleFidget.interruptT >= 1 then
            flyIdleFidget.interrupting = false
            flyIdleFidget.interruptElapsed = 0
            flyIdleFidget.active = false
            flyIdleFidget.activeVariant = 1
            flyIdleFidget.interruptDuration = 0
            flyIdleFidget.interruptT = 0
            flyIdleFidget.interruptSmoothT = 0
            flyIdleFidget.interruptStartFidgetWeight = 0
            flyIdleFidget.interruptStartIdleWeight = 0
            flyIdleFidget.interruptMoveWeight = 0
            flyIdleFidget.interruptBackwardWeight = 0
            flyIdleFidget.interruptDirectionBlend = 1
            flyIdleFidget.currentWeight = 0
        end
    end

    if requestedState == "Forward" or requestedState == "Backward" then
        if flyIdleFidget.interrupting then
            -- The dedicated fidget handoff above already owns the directional
            -- weights for this frame. Keep the normal transition state neutral
            -- so the existing reversal system takes over cleanly on the next
            -- frame without a second blend being layered on top.
            flyDirectionTransitionActive = false
            flyDirectionTransitionFrom = nil
            flyDirectionTransitionTo = nil
            flyDirectionTransitionTime = 0
        elseif startedMovingFromIdle then
            -- A genuine Idle -> movement start. No directional residue remains
            -- strong enough to justify a reversal transition.
            flyDirectionTransitionActive = false
            flyDirectionTransitionFrom = nil
            flyDirectionTransitionTo = nil
            flyDirectionTransitionTime = 0
            flyIdleWeight = 1
            flyMoveWeight = 0
            flyBackwardWeight = 0
        elseif residualReversalFrom and not flyDirectionTransitionActive then
            -- A short stop left enough of the previous direction alive to make
            -- this a real reversal. Start the same V190.9 continuous 3-way
            -- blend from that residual direction instead of resetting to Idle.
            flyDirectionTransitionActive = true
            flyDirectionTransitionFrom = residualReversalFrom
            flyDirectionTransitionTo = requestedState
            flyDirectionTransitionTime = 0

        elseif not flyDirectionTransitionActive then
            local currentDominant
            if flyMoveWeight >= flyBackwardWeight then
                currentDominant = "Forward"
            else
                currentDominant = "Backward"
            end

            if currentDominant ~= requestedState then
                flyDirectionTransitionActive = true
                flyDirectionTransitionFrom = currentDominant
                flyDirectionTransitionTo = requestedState
                flyDirectionTransitionTime = 0

            end
        elseif flyDirectionTransitionTo ~= requestedState then
            -- Reverse an active transition without dropping through Idle.
            -- Mirror the progress so the currently dominant direction stays
            -- dominant instead of resetting weights and creating a second snap.
            local previousTo = flyDirectionTransitionTo
            flyDirectionTransitionTo = requestedState
            flyDirectionTransitionFrom = previousTo
            flyDirectionTransitionTime =
                math.max(FLY_DIRECTION_CONTINUOUS_BLEND_TIME - flyDirectionTransitionTime, 0)

        end
    else
        -- Entering Idle explicitly ends any reversal state. The next movement
        -- must therefore start from Idle, even if the previous direction track
        -- is still fading out underneath it.
        flyDirectionTransitionActive = false
        flyDirectionTransitionFrom = nil
        flyDirectionTransitionTo = nil
        flyDirectionTransitionTime = 0
    end

    if requestedState == "Forward" or requestedState == "Backward" then
        flyLastDirectionalState = requestedState
    end

    flyPreviousDesiredState = requestedState

    if not flyIdleFidget.interrupting and flyDirectionTransitionActive
        and (flyDirectionTransitionFrom == "Forward" or flyDirectionTransitionFrom == "Backward")
        and (flyDirectionTransitionTo == "Forward" or flyDirectionTransitionTo == "Backward") then

        flyDirectionTransitionTime = math.min(
            flyDirectionTransitionTime + deltaTime,
            FLY_DIRECTION_CONTINUOUS_BLEND_TIME
        )

        local rawT = math.clamp(
            flyDirectionTransitionTime / FLY_DIRECTION_CONTINUOUS_BLEND_TIME,
            0,
            1
        )
        -- V191: keep the V190.11 no-snap three-way path, but restore a
        -- response curve closer to V190's normal exponential animation blend.
        -- The reversal still has a fixed 0.45s window, but the directional
        -- handoff starts and settles more like V190 instead of the slower
        -- smoothstep trajectory used by the previous diagnostic versions.
        local V190_REVERSAL_RESPONSE = 0.18
        local responseEnd = 1 - math.exp(-FLY_DIRECTION_CONTINUOUS_BLEND_TIME / V190_REVERSAL_RESPONSE)
        local t = 0
        if responseEnd > 0.000001 then
            t = (1 - math.exp(
                -flyDirectionTransitionTime / V190_REVERSAL_RESPONSE
            )) / responseEnd
        end
        t = math.clamp(t, 0, 1)
        local idlePulse = math.sin(math.pi * t) * FLY_DIRECTION_CONTINUOUS_IDLE_MAX
        local directionalShare = 1 - idlePulse

        local fromWeight = directionalShare * (1 - t)
        local toWeight = directionalShare * t

        flyIdleWeight = idlePulse
        if flyDirectionTransitionFrom == "Forward" then
            flyMoveWeight = fromWeight
            flyBackwardWeight = toWeight
        else
            flyBackwardWeight = fromWeight
            flyMoveWeight = toWeight
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
        move:AdjustWeight(flyMoveWeight, 0)
        backward:AdjustWeight(flyBackwardWeight, 0)

        if rawT >= 1 then
            flyDirectionTransitionActive = false
            flyDirectionTransitionFrom = nil
            flyDirectionTransitionTo = nil
            flyDirectionTransitionTime = 0

            -- Finish exactly on the requested direction, with no Idle tail.
            flyIdleWeight = 0
            flyMoveWeight = requestedState == "Forward" and 1 or 0
            flyBackwardWeight = requestedState == "Backward" and 1 or 0

            idle:AdjustWeight(0, 0)
            move:AdjustWeight(flyMoveWeight, 0)
            backward:AdjustWeight(flyBackwardWeight, 0)

        end
    elseif not flyIdleFidget.interrupting then
        -- Normal V190 behavior for Idle and for ordinary non-reversal states.
        local idleTarget = requestedState == "Idle" and 1 or 0
        local moveTarget = requestedState == "Forward" and 1 or 0
        local backwardTarget = requestedState == "Backward" and 1 or 0

        local blendAlpha
        if flyStartupFinalBlendActive then
            -- V191: synchronize the animation crossfade to the SAME physical
            -- launch progress instead of letting Fly Idle ease in independently.
            -- This keeps the Ascend pose continuously moving toward Idle while
            -- the character is rising, so there is no end-of-launch pose snap.
            local launchElapsed = math.max(
                flyStartupLaunchTime - FLY_STARTUP_LAUNCH_DELAY,
                0
            )
            local launchP = math.clamp(
                launchElapsed / math.max(FLY_STARTUP_LAUNCH_DURATION, 0.05),
                0,
                1
            )
            local smoothP = launchP * launchP * (3 - 2 * launchP)

            flyStartupFinalBlendTime = launchElapsed
            flyIdleWeight = smoothP
            flyMoveWeight = 0
            flyBackwardWeight = 0

            local ascendTrack = flyStartupAscendTrack
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
            local variantTrack = flyTracks[variant.trackKey]
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
        if move then move:AdjustWeight(flyMoveWeight, 0) end
        if backward then backward:AdjustWeight(flyBackwardWeight, 0) end
    end

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

        -- V169: keep the player's current Roblox idle/emote track alive during
        -- Fly activation. Startup OFF uses it as the source of the smooth
        -- idle -> Fly Idle blend. Startup ON uses it as the source underneath
        -- the reversed Action4 startup emote. Animate is disabled only after
        -- the relevant handoff is ready.
        animate.Disabled = flyAnimateScriptDisabled
    end
end

local function restoreCharacterState()
    local saved = flySaved
    flySaved = nil
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
-- Preserved body heading across Fly OFF -> ON when Shift Lock is OFF.
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
    table.clear(flyState.flyCameraTouchStates)
    table.clear(flyState.flyCameraZoomTouchPositions)
    flyState.flyCameraPinchLastDiameter = nil
    flyState.flyCameraTouchDelta = Vector2.new()
    flyState.flyCameraMouseDelta = Vector2.new()
    flyCameraMouseLooking = false
end

local function flyCameraSmoothLook(dt)
    local alpha =
        1 - math.exp(-FLY_CAMERA_LOOK_SMOOTHNESS * math.max(dt, 0))

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
            mouseDelta.X * FLY_CAMERA_MOUSE_ROTATION_SPEED.X,
            mouseDelta.Y * FLY_CAMERA_MOUSE_ROTATION_SPEED.Y
        )

        flyState.flyCameraTargetYaw =
            flyState.flyCameraTargetYaw - rotation.X

        flyState.flyCameraTargetPitch = math.clamp(
            flyState.flyCameraTargetPitch - rotation.Y,
            FLY_CAMERA_MIN_PITCH,
            FLY_CAMERA_MAX_PITCH
        )
    end
end

-- During the Fly -> normal-camera handoff, the joystick finger is still physically
-- held. Roblox's CameraModule can see that same TouchInput and interpret its movement
-- as camera-look/pinch input for one or more frames. Block ONLY that already-held
-- joystick InputObject until TouchEnded. Other fingers remain completely available
-- to the normal Roblox camera.
local flyJoystickHandoffBlockTouch = nil
local flyJoystickHandoffBlockConnection = nil

-- v90 camera bridge: while the DynamicThumbstick finger is still held, keep
-- the camera on Fly's proven touch interpreter while normal ControlModule owns
-- movement. This avoids forcing Roblox CameraInput to reinterpret an already-held
-- joystick as a camera/pinch gesture.
local flyCameraHandoffActive = false
local flyCameraHandoffRenderConnection = false
local flyCameraHandoffQuietFrames = 0

-- v93: hard session ownership. Old exit/death callbacks are never allowed
-- to write camera state into a later Fly session or a respawned character.
local flySessionId = 0
local flyDiedConnection = nil

local function clearFlyJoystickHandoffBlock()
    ContextActionService:UnbindAction("VGD_FlyJoystickHandoffBlock")

    if flyJoystickHandoffBlockConnection then
        pcall(function()
            flyJoystickHandoffBlockConnection:Disconnect()
        end)
        flyJoystickHandoffBlockConnection = nil
    end

    flyJoystickHandoffBlockTouch = nil
end

local function blockFlyJoystickDuringCameraHandoff(touch)
    clearFlyJoystickHandoffBlock()

    if not touch or touch.UserInputType ~= Enum.UserInputType.Touch then
        return
    end

    flyJoystickHandoffBlockTouch = touch

    local function handoffTouchAction(_, inputState, inputObject)
        if inputObject ~= flyJoystickHandoffBlockTouch then
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

    ContextActionService:BindActionAtPriority(
        "VGD_FlyJoystickHandoffBlock",
        handoffTouchAction,
        false,
        Enum.ContextActionPriority.High.Value + 1,
        Enum.UserInputType.Touch
    )

    flyJoystickHandoffBlockConnection = UserInputService.TouchEnded:Connect(function(inputObject)
        if inputObject == flyJoystickHandoffBlockTouch then
            clearFlyJoystickHandoffBlock()
        end
    end)
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
    flyState.flyCameraPinchLastDiameter = nil
    table.clear(flyState.flyCameraZoomTouchPositions)
end

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
        + cameraUp * flyCameraVerticalOffset

    return CFrame.lookAt(cameraPosition, cameraPosition + cameraLook, cameraUp)
end

local function syncRobloxCameraZoomState(distance)
    if not distance or flySpectatingOtherPlayer then return end

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

    if not flyCameraSavedMinZoom or not flyCameraSavedMaxZoom then
        return
    end

    if math.abs(player.CameraMinZoomDistance - clamped) > 0.02
        or math.abs(player.CameraMaxZoomDistance - clamped) > 0.02 then
        player.CameraMinZoomDistance = clamped
        player.CameraMaxZoomDistance = clamped
    end
end

local function computeFlyCameraVisualState(moveVector, currentSpeed, dt, cameraSubjectPosition)
    -- Kept separate from updateFly() so the large flight loop does not hit
    -- Luau's local-register limit. Camera behavior itself is unchanged.
    local cameraPosition = nil
    local cameraRotation = nil

    if flyCameraFeelOn then
        local horizontalVelocity = Vector3.new(moveVector.X, 0, moveVector.Z)
        local cameraLagTarget = Vector3.zero

        if horizontalVelocity.Magnitude > 0.001 then
            local speedRatio = math.clamp(currentSpeed, 0, 1)
            local travelDirection = horizontalVelocity.Unit
            cameraLagTarget = -travelDirection * (FLY_CAMERA_MAX_LAG * speedRatio)

            cameraLagTarget *= 1
                + flyState.flyAccelerationBlend * 0.18
                + flyState.flyDecelerationBlend * 0.08
        end

        local cameraLagAlpha = 1 - math.exp(-FLY_CAMERA_MOMENTUM_SMOOTHNESS * dt)
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
            * FLY_CAMERA_FOV_MAX_BOOST
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
    if not flyEnabled then return end

    local humanoid, root = getHumanoidAndRoot()
    local cam = workspace.CurrentCamera
    if not humanoid or not root or not cam then return end

    -- This is the same subject point that Roblox CameraModule uses for the
    -- local living Humanoid. Fly camera geometry and Camera.Focus must use
    -- this point, not the root pivot, so pitch cannot create an artificial
    -- zoom change when CameraModule resumes control.
    local cameraSubjectPosition = getRobloxCameraSubjectPosition(humanoid, root)

    -- v61: allow external spectate systems to own the camera while Fly stays
    -- enabled. Roblox's normal/spectate camera uses CameraSubject, so Fly must
    -- not overwrite Camera.CFrame when the subject is another player's
    -- character. When spectating ends, resume Fly from the camera orientation
    -- the player is actually looking at instead of the pre-Fly orientation.
    local cameraSubject = cam.CameraSubject
    local subjectCharacter = cameraSubject and cameraSubject.Parent
    local subjectPlayer = subjectCharacter
        and Players:GetPlayerFromCharacter(subjectCharacter)
    local spectatingOtherPlayer = subjectPlayer ~= nil and subjectPlayer ~= player

    if spectatingOtherPlayer then
        if not flySpectatingOtherPlayer then
            flyCameraResetInput()
            table.clear(flyState.flyCameraTouchStates)
            table.clear(flyState.flyCameraZoomTouchPositions)
            flyState.flyCameraPinchLastDiameter = nil
        end
        flySpectatingOtherPlayer = true
    elseif flySpectatingOtherPlayer then
        -- The spectate target has been released. The CameraModule has now
        -- returned the camera to our character; adopt its current orientation
        -- before Fly takes Scriptable ownership back.
        flySpectatingOtherPlayer = false
        local resumePitch, resumeYaw = cam.CFrame:ToOrientation()
        flyState.flyCameraPitch = resumePitch
        flyState.flyCameraYaw = resumeYaw
        flyState.flyCameraTargetPitch = resumePitch
        flyState.flyCameraTargetYaw = resumeYaw

        local resumeSubjectPosition = getRobloxCameraSubjectPosition(humanoid, root)
        local resumeDistance = (cam.CFrame.Position - resumeSubjectPosition):Dot(-cam.CFrame.LookVector)
        if resumeDistance <= 0.01 then
            resumeDistance = (cam.CFrame.Position - resumeSubjectPosition).Magnitude
        end
        flyState.flyCameraZoomDistance = math.clamp(
            resumeDistance,
            FLY_CAMERA_ZOOM_MIN,
            FLY_CAMERA_ZOOM_MAX
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
    local zoomAlpha = 1 - math.exp(-14 * math.max(deltaTime, 0))
    flyState.flyCameraZoomDistance = flyState.flyCameraZoomDistance
        + (flyState.flyCameraTargetZoomDistance - flyState.flyCameraZoomDistance) * zoomAlpha

    syncRobloxCameraZoomState(flyState.flyCameraZoomDistance)

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
    -- FLY STARTUP / SUPERHERO TAKEOFF
    -- ================================================================
    local startupPitch = 0
    local startupFrame = flyStartupActive or flyStartupLaunchActive
    local t = 0
    if flyStartupActive then
        flyStartupTime += dt
        t = math.clamp(
            flyStartupTime / math.max(flyStartupDuration, 0.001),
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
    if flyStartupLaunchActive and flyStartupStartPosition then
        -- 0.90 -> 1.40s: ascend animation owns the pose; stay grounded.
        -- 1.40 -> 2.00s: begin the physical lift and crossfade to Fly Idle.
        local elapsed = flyStartupLaunchTime
        if elapsed >= FLY_STARTUP_LAUNCH_DELAY then
            local p = math.clamp(
                (elapsed - FLY_STARTUP_LAUNCH_DELAY)
                    / math.max(FLY_STARTUP_LAUNCH_DURATION, 0.05),
                0,
                1
            )
            local eased = 1 - (1 - p) ^ 3
            startupOffset = flyStartupHeight * eased

            if flyStartupActive then
                flyStartupActive = false
                flyStartupFinalBlendActive = true
                flyStartupFinalBlendTime = 0
                startNormalFlyAnimationSet(true)

                -- The dedicated Ascend track stays fully continuous here.
                -- V191 fades it by the same normalized progress used for the
                -- physical rise, rather than scheduling a separate delayed
                -- fade at the top.
                local ascendTrack = flyStartupAscendTrack
                if ascendTrack then
                    pcall(function() ascendTrack:AdjustWeight(1, 0) end)
                end
            end
        end

        flyStartupLaunchTime += dt
        if flyStartupLaunchTime >= FLY_STARTUP_LAUNCH_DELAY + FLY_STARTUP_LAUNCH_DURATION then
            flyStartupLaunchActive = false
            flyStartupLaunchTime = 0
            flyStartupFinalBlendActive = false
            flyStartupFinalBlendTime = 0
            flyStartupStartPosition = nil
            local ascendTrack = flyStartupAscendTrack
            flyStartupAscendTrack = nil
            if flyStartupAscendStoppedConnection then
                flyStartupAscendStoppedConnection:Disconnect()
                flyStartupAscendStoppedConnection = nil
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
    elseif flyStartupActive and flyStartupAnimationReady then
        -- During the 0.60s visual blend and the short asset section, stay grounded.
        startupOffset = 0
    end

    if startupFrame and flyStartupStartPosition then
        flyPosition = flyStartupStartPosition
            + Vector3.new(0, startupOffset, 0)
    end

    if startupFrame then
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end

    if flyStartupActive and flyJointDiagnosticActive and flyJointDiagnosticTime >= flyJointDiagnosticDuration then
            stopFlyJointDiagnostic()
            flyStartupActive = false
            flyStartupTime = 0
            flyStartupStartPosition = nil
            stopFlyStartupPoseDriver()
            clearFlyStartupPose()
            clearStartupAnimatorSuppression()
            startNormalFlyAnimationSet()
        elseif flyStartupActive and t >= 1 and not flyJointDiagnosticActive and not flyStartupAssetActive then
            -- V181: normal startup completion is handled by
            -- finishFlyStartupAnimation(). This branch remains only for the
            -- legacy diagnostic/procedural path.
            flyStartupActive = false
            flyStartupTime = 0
            flyStartupStartPosition = nil
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
    flyCameraSmoothLook(dt)

    local cameraLookCFrame =
        CFrame.new(flyPosition) *
        CFrame.Angles(0, flyState.flyCameraYaw, 0) *
        CFrame.Angles(flyState.flyCameraPitch, 0, 0)
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

    -- A held joystick must not cancel the takeoff. The live control vector is
    -- consumed normally as soon as the startup state finishes.
    if flyStartupActive then
        moveVector = Vector3.zero
        horizontalMove = Vector3.zero
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
    if flyStartupActive then
        isMoving = false
    end

    -- ================================================================
    -- v57 FLIGHT DYNAMICS / MOMENTUM VISUALS
    -- ================================================================
    -- These values are visual response layers. The actual movement vector and
    -- position integration remain exactly v56.
    local currentSpeed = moveVector.Magnitude
    local speedDelta = currentSpeed - flyState.flyPreviousSpeed
    local speedDeltaAlpha = 1 - math.exp(-dt / 0.09)

    local accelerationTarget = math.clamp(math.max(speedDelta, 0) * 5, 0, 1)
    local decelerationTarget = math.clamp(math.max(-speedDelta, 0) * 5, 0, 1)

    flyState.flyAccelerationBlend = flyState.flyAccelerationBlend
        + (accelerationTarget - flyState.flyAccelerationBlend) * speedDeltaAlpha
    flyState.flyDecelerationBlend = flyState.flyDecelerationBlend
        + (decelerationTarget - flyState.flyDecelerationBlend) * speedDeltaAlpha

    local directionChangeTarget = 0
    if isMoving and flyState.flyPreviousMoveDirection.Magnitude > 0.05 then
        local previousUnit = flyState.flyPreviousMoveDirection.Unit
        local currentUnit = moveVector.Unit
        local directionDot = math.clamp(previousUnit:Dot(currentUnit), -1, 1)
        directionChangeTarget = math.clamp((1 - directionDot) * 0.85, 0, 1)
    end

    local directionChangeAlpha = 1 - math.exp(-dt / 0.075)
    flyState.flyDirectionChangeBlend = flyState.flyDirectionChangeBlend
        + (directionChangeTarget - flyState.flyDirectionChangeBlend) * directionChangeAlpha

    -- Keep the previous movement vector alive until the procedural pose has
    -- consumed it below. This is what makes v57's direction-change reaction
    -- compare the actual previous frame against the current frame.
    flyState.flyPreviousSpeed = currentSpeed

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
    if flyNoClipOn or startupFrame then
        if flyGravityForce and flyGravityForce.Parent then
            flyGravityForce.Force = Vector3.zero
        end

        if not startupFrame then
            flyPosition = flyPosition + moveVector * flySpeed * dt
        end
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
        desiredFlightYaw = flyState.flyCameraYaw
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

    -- Animation direction must follow the character's actual body heading,
    -- not the camera heading, when Shift Lock is OFF. In that mode the body
    -- turns to face the movement direction, so a joystick input that is
    -- "backward" relative to the camera is still FORWARD relative to the
    -- character. Shift Lock ON keeps the old camera-relative behavior.
    -- Use desiredFlightYaw (the intended body heading) rather than the
    -- smoothed flyBodyYaw so a quick direction change cannot briefly select
    -- the backward animation while the body is visually catching up.
    local animationBodyLook = Vector3.new(
        -math.sin(desiredFlightYaw),
        0,
        -math.cos(desiredFlightYaw)
    )
    local animationForwardInput = 0
    if horizontalMove.Magnitude > 0.001 and isMoving then
        animationForwardInput = math.clamp(
            horizontalMove.Unit:Dot(animationBodyLook),
            -1,
            1
        )
    end

    -- Same animation state test/crossfade as the hologram.
    updateFlyAnimations(
        isMoving,
        moveVector,
        dt,
        animationForwardInput
    )

    -- v117: the procedural startup is applied by the PreSimulation driver.
    -- Do not write Motor6D.Transform from the camera/render loop; Animator
    -- evaluation and render timing can otherwise leave the old locomotion pose
    -- underneath the takeoff.
    local forwardTarget = 0
    local rightTarget = 0
    if moveVector.Magnitude > 0.001 and isMoving then
        local moveUnit = moveVector.Unit

        if flyShiftLockOn then
            -- Shift Lock ON: keep the original camera-relative pose.
            -- Backward input relative to the camera is allowed to produce
            -- the backward/negative-forward flight lean.
            forwardTarget = math.clamp(moveUnit:Dot(flatLook), -1, 1)

            local flatRight = flatLook:Cross(Vector3.new(0, 1, 0))
            if flatRight.Magnitude > 0.001 then
                flatRight = flatRight.Unit
                rightTarget = math.clamp(moveUnit:Dot(flatRight), -1, 1)
            end
        else
            -- Shift Lock OFF: the body itself turns to face the movement
            -- direction. Therefore a joystick pushed backward relative to
            -- the camera is still FORWARD relative to the character.
            -- Build the pose from the same intended body heading so both
            -- joystick directions produce the exact same forward lean/bank.
            local bodyPoseLook = animationBodyLook
            local bodyPoseRight = bodyPoseLook:Cross(Vector3.new(0, 1, 0))

            if bodyPoseRight.Magnitude > 0.001 then
                bodyPoseRight = bodyPoseRight.Unit
            else
                bodyPoseRight = Vector3.new(1, 0, 0)
            end

            forwardTarget = math.clamp(moveUnit:Dot(bodyPoseLook), -1, 1)
            rightTarget = math.clamp(moveUnit:Dot(bodyPoseRight), -1, 1)
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
        * flyState.flyAccelerationBlend * b
    local brakingPitch = math.rad(5)
        * flyState.flyDecelerationBlend * b

    local flyLeanPitch = math.rad(16) * movementForward * b
        + accelerationPitch
        - brakingPitch
    local flyLeanRoll = math.rad(14) * movementRight * b

    -- Direction-change reaction: briefly counter-roll into a sharp change,
    -- then let the existing turn-bank system take over.
    local directionSign = 0
    if moveVector.Magnitude > 0.001 and flyState.flyPreviousMoveDirection.Magnitude > 0.05 then
        local crossY = flyState.flyPreviousMoveDirection.Unit:Cross(moveVector.Unit).Y
        directionSign = math.clamp(crossY, -1, 1)
    end
    local directionChangeRoll = math.rad(4)
        * directionSign
        * flyState.flyDirectionChangeBlend
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
            flightPitch - flyLeanPitch - speedPosePitch + startupPitch,
            hoverYaw,
            -flyLeanRoll - flightBankBlend
                + directionChangeRoll
                + hoverRoll
        )

    -- No Clip ON owns the position directly so the character cannot be
    -- physically pushed back by another player or an object. No Clip OFF keeps
    -- the v21 physics-resolved position completely untouched.
    if flyNoClipOn or startupFrame then
        -- Startup owns the root position even when No Clip is OFF so physics
        -- cannot cancel the procedural takeoff. Once startup finishes, the
        -- normal No Clip ON/OFF position ownership resumes unchanged.
        root.CFrame = CFrame.new(flyPosition) * animatedCFrame.Rotation
        root.AssemblyLinearVelocity = Vector3.zero
    else
        root.CFrame = CFrame.new(root.Position) * animatedCFrame.Rotation
        flyPosition = root.Position
    end
    root.AssemblyAngularVelocity = Vector3.zero

    -- The root may have moved during this render step. Re-evaluate the
    -- CameraModule-style subject point from the final character position so
    -- the Fly camera remains attached to the same point Roblox will follow
    -- when normal camera control resumes.
    cameraSubjectPosition = getRobloxCameraSubjectPosition(humanoid, root)

    -- Commit the movement direction after all visual direction-change
    -- calculations have consumed the previous frame's value.
    flyState.flyPreviousMoveDirection = moveVector

    -- ================================================================
    -- v58 OPTIONAL CAMERA FLIGHT FEEL
    -- ================================================================
    -- Kept in a helper to avoid exceeding Luau's local-register budget.
    local cameraPosition, cameraRotation =
        computeFlyCameraVisualState(
            moveVector,
            currentSpeed,
            dt,
            cameraSubjectPosition
        )

    if not flySpectatingOtherPlayer then
        -- v113: Scriptable camera means Roblox CameraModule cannot overwrite
        -- the camera from the character rotation that this same frame creates.
        cam.CameraType = Enum.CameraType.Scriptable
        cam.CFrame = CFrame.new(cameraPosition) * cameraRotation
        cam.FieldOfView = (flyCameraSavedFOV or FLY_CAMERA_FOV_BASE)
            + (flyCameraFeelOn and flyState.flyCameraFOVBlend or 0)
        cam.Focus = CFrame.new(cameraSubjectPosition)
    end
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

local function cancelPendingFlyExitHandoffForReenable()
    -- A held-joystick disable intentionally keeps a temporary Scriptable
    -- camera bridge alive. If Fly is enabled again before that bridge fully
    -- releases, the old bridge MUST NOT be allowed to keep writing camera
    -- CFrames underneath the new Fly session. Capture the live camera first,
    -- then tear the old bridge down without restoring the old pre-Fly camera.
    local camera = workspace.CurrentCamera
    local liveCFrame = camera and camera.CFrame or nil

    RunService:UnbindFromRenderStep("VGD_FlyExitCameraHandoff")

    if flyCameraHandoffActive or flyCameraHandoffRenderConnection then
        flyCameraHandoffActive = false
        flyCameraHandoffQuietFrames = 0
        if flyCameraHandoffRenderConnection then
            RunService:UnbindFromRenderStep("VGD_FlyCameraHandoff")
            flyCameraHandoffRenderConnection = false
        end
        disconnectFlyCameraInput()
    end

    -- The live bridge CFrame is the player's actual latest view. Do not put
    -- CameraModule back through the old saved CFrame here; the next Fly
    -- session must start from what the player is looking at NOW.
    if camera and liveCFrame then
        camera.CFrame = liveCFrame
    end

    flyCameraSavedType = nil
    flyCameraSavedSubject = nil
    flyCameraSavedCFrame = nil
    flyCameraSavedFOV = nil
    flyCameraSavedMinZoom = nil
    flyCameraSavedMaxZoom = nil
end

local function cancelPendingFlyExitHandoffClean()
    -- Used for a final clean exit. Never leave an old render-step callback
    -- alive after a Fly session ends; otherwise a later walk/camera update can
    -- be overwritten by a callback belonging to a previous session.
    RunService:UnbindFromRenderStep("VGD_FlyExitCameraHandoff")
    if flyCameraHandoffRenderConnection then
        RunService:UnbindFromRenderStep("VGD_FlyCameraHandoff")
        flyCameraHandoffRenderConnection = false
    end
    flyCameraHandoffActive = false
    flyCameraHandoffQuietFrames = 0
end

local function disconnectFlyDeathConnection()
    if flyDiedConnection then
        pcall(function() flyDiedConnection:Disconnect() end)
        flyDiedConnection = nil
    end
end

local function bindFlyDeathCleanup(humanoid, sessionId)
    disconnectFlyDeathConnection()

    flyDiedConnection = humanoid.Died:Connect(function()
        if sessionId ~= flySessionId then return end

        flyEnabled = false
        flySpectatingOtherPlayer = false
        updateFlyShiftLockButton()
        unbindVerticalControls()

        if flyRenderConnection then
            RunService:UnbindFromRenderStep("VGD_FlySmooth")
            flyRenderConnection = nil
        end

        RunService:UnbindFromRenderStep("VGD_FlyExitCameraHandoff")
        RunService:UnbindFromRenderStep("VGD_FlyCameraHandoff")
        flyCameraHandoffActive = false
        flyCameraHandoffRenderConnection = false
        flyCameraHandoffQuietFrames = 0

        clearFlyJoystickHandoffBlock()
        disconnectFlyCameraInput()
        clearFlyJoystick()
        disconnectFlyNoClipWatcher()
        destroyFlyCollisionProxy()
        restoreCharacterState()

        -- Never restore the dead character's saved camera.
        flyCameraSavedType = Enum.CameraType.Custom
        flyCameraSavedSubject = nil
        flyCameraSavedCFrame = nil
        flyCameraSavedFOV = nil
        flyCameraSavedMinZoom = nil
        flyCameraSavedMaxZoom = nil

        local camera = workspace.CurrentCamera
        if camera then
            camera.CameraType = Enum.CameraType.Custom
            camera.CameraSubject = nil
        end

        stateChangedEvent:Fire(false)
    end)
end

local function enableFly()
    if flyEnabled then return true end

    -- v93: invalidate every callback belonging to the previous session.
    flySessionId += 1
    local thisFlySession = flySessionId
    disconnectFlyDeathConnection()
    RunService:UnbindFromRenderStep("VGD_FlyExitCameraHandoff")
    RunService:UnbindFromRenderStep("VGD_FlyCameraHandoff")
    flyCameraHandoffActive = false
    flyCameraHandoffRenderConnection = false
    flyCameraHandoffQuietFrames = 0

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
    -- Preserve the user's Shift Lock state across Fly disable/enable.
    -- It defaults to ON for the first session, then follows the user's last choice.
    -- Do not reset flyShiftLockOn here.
    -- Preserve the user's last No Clip preference across Fly disable/enable.
    -- No Clip is ON by default only for the first Fly session; after the user
    -- turns it OFF, disabling and re-enabling Fly keeps it OFF.
    updateFlyShiftLockButton()
    setFlyNoClip(flyNoClipOn)
    flyVerticalInput = 0
    forwardBlend, rightBlend, flightPitchBlend, flightBankBlend, flightTurnRateBlend, speedBlend, hoverBlend = 0, 0, 0, 0, 0, 0, 0
    flyState.flyCameraVelocityBlend = Vector3.zero
    flyState.flyCameraTurnLag = 0
    flyState.flyCameraFOVBlend = 0
    flyState.flyCameraLastYaw = nil
    flyCameraLastMoveVector = Vector3.zero
    flyState.flyAccelerationBlend = 0
    flyState.flyDecelerationBlend = 0
    flyState.flyDirectionChangeBlend = 0
    flyState.flyPreviousMoveDirection = Vector3.zero
    flyState.flyPreviousSpeed = 0
    if flyShiftLockOn then
        flyBodyYaw = flyState.flyCameraYaw
    else
        flyBodyYaw = enableBodyYaw
    end
    flyFlightPreviousDesiredYaw = flyBodyYaw
    flyHologramMoveBlend = 0
    flyAnimTime = 0
    flyIdleWeight = 1
    flyMoveWeight = 0
    flyBackwardWeight = 0
    flyStartupActive = flyStartupAnimationEnabled
    flyStartupTime = 0
    flyStartupLaunchActive = false
    flyStartupLaunchTime = 0
    flyStartupAscendTrack = nil
    flyStartupAscendStoppedConnection = nil
    flyStartupFinalBlendActive = false
    flyStartupFinalBlendTime = 0
    flyStartupStartPosition = flyStartupAnimationEnabled and root.Position or nil
    stopFlyStartupAnimation()

    -- Startup OFF now uses the same character-state takeover as V162 Startup ON.
    -- Keep PlatformStand enabled during Fly ownership and let the existing Fly
    -- controller take over exactly as that older, tested activation path did.
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
    flySpectatingOtherPlayer = false
    flyCameraSavedFOV = workspace.CurrentCamera.FieldOfView
    flyCameraSavedMinZoom = player.CameraMinZoomDistance
    flyCameraSavedMaxZoom = player.CameraMaxZoomDistance

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
    flyCameraVerticalOffset =
        normalCameraOffset:Dot(startCamera.CFrame.UpVector)

    -- Match the REAL starting camera-to-subject distance, not just its
    -- projection along LookVector. The Fly camera position is constructed as
    --   subject - LookVector * depth + UpVector * verticalOffset
    -- so its true distance is sqrt(depth^2 + verticalOffset^2). Solve that
    -- geometry here so enabling Fly does not introduce a small distance jump
    -- even when the player never touches zoom.
    local startActualDistance =
        (startPosition - startSubjectPosition).Magnitude
    local verticalOffsetMagnitude = math.abs(flyCameraVerticalOffset)
    local depthSquared =
        (startActualDistance * startActualDistance)
        - (verticalOffsetMagnitude * verticalOffsetMagnitude)

    local correctedStartDepth = math.sqrt(math.max(depthSquared, 0))

    flyState.flyCameraZoomDistance = math.clamp(
        correctedStartDepth,
        FLY_CAMERA_ZOOM_MIN,
        FLY_CAMERA_ZOOM_MAX
    )
    flyState.flyCameraTargetZoomDistance = flyState.flyCameraZoomDistance

    flyState.flyCameraOffset = Vector3.zero
    flyState.flyCameraPitch, flyState.flyCameraYaw = startCamera.CFrame:ToOrientation()
    flyState.flyCameraTargetPitch = flyState.flyCameraPitch
    flyState.flyCameraTargetYaw = flyState.flyCameraYaw

    -- V188: Shift Lock OFF uses the live character heading captured when
    -- enableFly() began. Camera yaw must not overwrite that heading.
    if flyShiftLockOn then
        flyBodyYaw = flyState.flyCameraYaw
    else
        flyBodyYaw = enableBodyYaw
    end
    flyFlightPreviousDesiredYaw = flyBodyYaw
    flyCameraResetInput()
    flyMoveControls = getFlyMoveControls()

    flyPosition = root.Position
    flyStartupStartPosition = flyPosition
    cacheFlyStartupJoints(character)
    -- V128: the Motor6D diagnostic is complete; Fly now enters the
    -- actual procedural superhero takeoff immediately.
    loadFlyAnimations(humanoid)

    -- V178: use the dedicated takeoff animation normally.
    -- If it cannot be delivered, cancel startup cleanly and enter normal Fly;
    -- never fall back into the old procedural startup lock.
    if flyStartupAnimationEnabled then
        local usingStartupAsset = startFlyStartupAnimation(humanoid)
        if not usingStartupAsset then
            flyStartupActive = false
            flyStartupTime = 0
            flyStartupStartPosition = nil
            startNormalFlyAnimationSet(true)
        end
    else
        flyStartupActive = false
        flyStartupTime = 0
        flyStartupStartPosition = nil
        -- Startup OFF uses the V162 Startup ON activation state, but skips the
        -- startup emote itself. Enter the normal Fly animation set immediately
        -- after the same PlatformStand/body/camera ownership setup.
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

    if flyRenderConnection then
        RunService:UnbindFromRenderStep("VGD_FlySmooth")
        flyRenderConnection = nil
    end

    -- V113: render after Camera priority, but the camera is Scriptable while
    -- Fly is active, so the default CameraModule has no competing write.
    RunService:BindToRenderStep(
        "VGD_FlySmooth",
        Enum.RenderPriority.Camera.Value + 1,
        updateFly
    )
    flyRenderConnection = true
    stateChangedEvent:Fire(true)
    return true
end

local function stopFlyCameraHandoff()
    if not flyCameraHandoffActive then
        return
    end

    flyCameraHandoffActive = false
    flyCameraHandoffQuietFrames = 0

    if flyCameraHandoffRenderConnection then
        RunService:UnbindFromRenderStep("VGD_FlyCameraHandoff")
        flyCameraHandoffRenderConnection = false
    end

    disconnectFlyCameraInput()

    local camera = workspace.CurrentCamera
    if not camera then
        return
    end

    local finalCFrame = camera.CFrame
    local savedType = flyCameraSavedType or Enum.CameraType.Custom
    local savedSubject = flyCameraSavedSubject
    local savedFOV = flyCameraSavedFOV
    local savedMinZoom = flyCameraSavedMinZoom
    local savedMaxZoom = flyCameraSavedMaxZoom

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
    RunService:UnbindFromRenderStep(handoffName)
    local applied = false
    RunService:BindToRenderStep(handoffName, Enum.RenderPriority.Camera.Value + 1, function()
        if applied then return end
        applied = true
        RunService:UnbindFromRenderStep(handoffName)
        if camera.Parent then
            camera.CFrame = finalCFrame
        end
        if savedMinZoom ~= nil then
            player.CameraMinZoomDistance = savedMinZoom
        end
        if savedMaxZoom ~= nil then
            player.CameraMaxZoomDistance = savedMaxZoom
        end
    end)

    flyCameraSavedType = nil
    flyCameraSavedSubject = nil
    flyCameraSavedCFrame = nil
    flyCameraSavedFOV = nil
    flyCameraSavedMinZoom = nil
    flyCameraSavedMaxZoom = nil
end

local function startFlyCameraHandoff(finalFlyCameraCFrame)
    local camera = workspace.CurrentCamera
    if not camera or not finalFlyCameraCFrame then
        return false
    end

    flyCameraHandoffActive = true
    flyCameraHandoffQuietFrames = 0

    -- Keep the camera Scriptable while the old joystick finger exists. The
    -- normal movement controller remains enabled and therefore still receives
    -- the physical thumbstick. Only camera ownership is temporarily bridged.
    camera.CameraType = Enum.CameraType.Scriptable
    camera.CFrame = finalFlyCameraCFrame
    camera.Focus = CFrame.new(finalFlyCameraCFrame.Position + finalFlyCameraCFrame.LookVector * 20)

    if not flyCameraHandoffRenderConnection then
        local handoffSessionId = flySessionId
        RunService:BindToRenderStep(
            "VGD_FlyCameraHandoff",
            Enum.RenderPriority.Camera.Value + 1,
            function(dt)
                if handoffSessionId ~= flySessionId then
                    RunService:UnbindFromRenderStep("VGD_FlyCameraHandoff")
                    flyCameraHandoffActive = false
                    flyCameraHandoffRenderConnection = false
                    return
                end
                if not flyCameraHandoffActive then
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
                -- exact tracker clears flyJoystickTouch only on TouchEnded.
                local joystickStillHeld = flyJoystickTouch ~= nil
                    or not flyJoystickReleasedSinceLastStart
                        and flyJoystickVector.Magnitude > 0.001

                local cameraTouchCount = 0
                for _ in pairs(flyState.flyCameraTouchStates) do
                    cameraTouchCount += 1
                end

                if not joystickStillHeld and cameraTouchCount == 0 then
                    -- Two quiet frames let Roblox finish the release processing
                    -- before CameraModule receives ownership again. This avoids
                    -- the stale one-frame pinch/rotation state seen on exit.
                    flyCameraHandoffQuietFrames += 1
                    if flyCameraHandoffQuietFrames >= 2 then
                        stopFlyCameraHandoff()
                    end
                else
                    flyCameraHandoffQuietFrames = 0
                end
            end
        )
        flyCameraHandoffRenderConnection = true
    end

    return true
end

local function disableFly()
    if not flyEnabled then return false end

    -- v117: never leave the procedural PreSimulation driver alive across a
    -- Fly session boundary.
    stopFlyStartupPoseDriver()

    -- Invalidate this session before any exit work. This prevents repeated
    -- ON/OFF cycles from leaving an old lifecycle callback alive.
    flySessionId += 1
    disconnectFlyDeathConnection()

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

    -- Capture the actual FINAL Fly camera orientation before releasing
    -- ownership. Never use flyCameraSavedCFrame here: that is the pre-Fly
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
    if flyCameraHandoffActive or flyCameraHandoffRenderConnection then
        cancelPendingFlyExitHandoffClean()
    end

    flyEnabled = false
    updateFlyShiftLockButton()
    unbindVerticalControls()
    if flyRenderConnection then
        RunService:UnbindFromRenderStep("VGD_FlySmooth")
        flyRenderConnection = nil
    end
    if not flyCameraHandoffActive then
        disconnectFlyCameraInput()
    end
    -- Keep the joystick tracker connected after Fly is disabled so a touch
    -- that started before Fly can remain available for the normal movement
    -- controller and for the next Fly transition.
    flyMoveControls = nil
    disconnectFlyNoClipWatcher()
    disconnectFlyDeathConnection()

    local camera = workspace.CurrentCamera
    local wasSpectatingOtherPlayer = flySpectatingOtherPlayer

    if camera then
        if wasSpectatingOtherPlayer then
            -- External spectate owns this camera. Do not interfere with its
            -- current camera state when Fly is disabled.
            camera.CameraType = flyCameraSavedType or Enum.CameraType.Custom
            camera.CameraSubject = flyCameraSavedSubject
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
            local savedFOV = flyCameraSavedFOV
            local savedMinZoom = flyCameraSavedMinZoom
            local savedMaxZoom = flyCameraSavedMaxZoom

            RunService:UnbindFromRenderStep("VGD_FlyExitCameraHandoff")

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
            local exitSessionId = flySessionId
            local handoffApplied = false
            RunService:BindToRenderStep(
                handoffName,
                Enum.RenderPriority.Camera.Value + 1,
                function()
                    if exitSessionId ~= flySessionId then
                        RunService:UnbindFromRenderStep(handoffName)
                        return
                    end
                    if handoffApplied then return end
                    handoffApplied = true
                    RunService:UnbindFromRenderStep(handoffName)

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
                        player.CameraMinZoomDistance = savedMinZoom
                    end
                    if savedMaxZoom ~= nil then
                        player.CameraMaxZoomDistance = savedMaxZoom
                    end
                end
            )
        end
    end

    flyCameraSavedType = nil
    flyCameraSavedSubject = nil
    flyCameraSavedCFrame = nil
    flySpectatingOtherPlayer = false
    flyCameraSavedFOV = nil
    flyCameraSavedMinZoom = nil
    flyCameraSavedMaxZoom = nil
    flyStartupActive = false
    flyStartupTime = 0
    flyStartupStartPosition = nil
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
        local humanoid = character:WaitForChild("Humanoid", 10)
        character:WaitForChild("HumanoidRootPart", 10)

        -- A character replacement invalidates every camera state belonging to
        -- the dead character. Never carry a Scriptable death camera through
        -- respawn.
        RunService:UnbindFromRenderStep("VGD_FlyExitCameraHandoff")
        RunService:UnbindFromRenderStep("VGD_FlyCameraHandoff")
        flyCameraHandoffActive = false
        flyCameraHandoffRenderConnection = false
        flyCameraHandoffQuietFrames = 0
        clearFlyJoystickHandoffBlock()
        disconnectFlyCameraInput()

        local camera = workspace.CurrentCamera
        if camera then
            camera.CameraType = Enum.CameraType.Custom
            camera.CameraSubject = humanoid
        end

        if flyEnabled then
            -- Start a fresh Fly session on the new character. The old
            -- Humanoid, root, camera CFrame and camera subject are discarded.
            flySessionId += 1
            local thisFlySession = flySessionId

            task.defer(function()
                if not flyEnabled or thisFlySession ~= flySessionId then
                    return
                end

                local newHumanoid, root = getHumanoidAndRoot()
                if not newHumanoid or not root then
                    flyEnabled = false
                    stateChangedEvent:Fire(false)
                    return
                end

                flySaved = nil
                saveCharacterState(newHumanoid, root)
                bindFlyDeathCleanup(newHumanoid, thisFlySession)

                flyMoveControls = getFlyMoveControls()
                if flyMoveControls then
                    pcall(function() flyMoveControls:Enable() end)
                end

                createFlyCollisionProxy()
                setFlyNoClip(flyNoClipOn)
                -- V169: keep the live idle visible through the shared startup
                -- handoff; PlatformStand is applied after the same short window
                -- used by the main enable path.
                newHumanoid.AutoRotate = false
                root.Anchored = false
                currentMoveVector = Vector3.zero
                flyPosition = root.Position
                flyStartupActive = flyStartupAnimationEnabled
                flyStartupTime = 0
                flyStartupStartPosition = flyStartupAnimationEnabled and flyPosition or nil
                stopFlyStartupAnimation()
                cacheFlyStartupJoints(newHumanoid.Parent)
                if flyShiftLockOn then
                    flyBodyYaw = flyState.flyCameraYaw
                else
                    flyBodyYaw = math.atan2(
                        root.CFrame.LookVector.X,
                        -root.CFrame.LookVector.Z
                    )
                end
                flyFlightPreviousDesiredYaw = flyBodyYaw
                if flyStartupAnimationEnabled then
                    local usingStartupAsset = startFlyStartupAnimation(newHumanoid)
                    if not usingStartupAsset then
                        flyStartupActive = false
                        flyStartupTime = 0
                        flyStartupStartPosition = nil
                        startNormalFlyAnimationSet(true)
                    end
                else
                    flyStartupActive = false
                    flyStartupTime = 0
                    flyStartupStartPosition = nil
                    startNormalFlyAnimationSet(true)
                end

                -- V169: keep PlatformStand out of the startup animation itself.
                -- V169: PlatformStand is not forced during activation.
                -- This keeps the animation handoff completely visual; the
                -- custom Fly controller already owns movement.

                local newCamera = workspace.CurrentCamera
                if newCamera then
                    flyCameraSavedType = Enum.CameraType.Custom
                    flyCameraSavedSubject = newHumanoid
                    flyCameraSavedCFrame = newCamera.CFrame
                    flyCameraSavedFOV = newCamera.FieldOfView
                    flyCameraSavedMinZoom = player.CameraMinZoomDistance
                    flyCameraSavedMaxZoom = player.CameraMaxZoomDistance

                    flyState.flyCameraPitch, flyState.flyCameraYaw = newCamera.CFrame:ToOrientation()
                    flyState.flyCameraTargetPitch = flyState.flyCameraPitch
                    flyState.flyCameraTargetYaw = flyState.flyCameraYaw

                    -- V188: the new character's live facing is authoritative
                    -- when Shift Lock is OFF; never restore an old session yaw.
                    if flyShiftLockOn then
                        flyBodyYaw = flyState.flyCameraYaw
                    else
                        flyBodyYaw = math.atan2(
                            root.CFrame.LookVector.X,
                            -root.CFrame.LookVector.Z
                        )
                    end
                    flyFlightPreviousDesiredYaw = flyBodyYaw

                    local subjectPosition = getRobloxCameraSubjectPosition(newHumanoid, root)
                    local startDistance = (newCamera.CFrame.Position - subjectPosition).Magnitude
                    flyCameraVerticalOffset = 0
                    flyState.flyCameraZoomDistance = math.clamp(
                        startDistance,
                        FLY_CAMERA_ZOOM_MIN,
                        FLY_CAMERA_ZOOM_MAX
                    )
                    flyState.flyCameraTargetZoomDistance = flyState.flyCameraZoomDistance
                    flyCameraResetInput()
                    flySpectatingOtherPlayer = false

                    connectFlyCameraInput()
                    newCamera.CameraType = Enum.CameraType.Scriptable
                end

                if flyRenderConnection then
                    RunService:UnbindFromRenderStep("VGD_FlySmooth")
                end
                RunService:BindToRenderStep(
                    "VGD_FlySmooth",
                    Enum.RenderPriority.Camera.Value + 1,
                    updateFly
                )
                flyRenderConnection = true
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

local FLY_GUI_MODULE_URL =
    "https://raw.githubusercontent.com/shahrinedham/VGD-Scripts/main/Modules/Fly_GUI.lua"
local FlyGuiModule = loadstring(game:HttpGet(FLY_GUI_MODULE_URL))()

local FLY_CAMERA_INPUT_MODULE_URL =
    "https://raw.githubusercontent.com/shahrinedham/VGD-Scripts/main/Modules/Fly_CameraInput.lua"
local FlyCameraInputModule = loadstring(game:HttpGet(FLY_CAMERA_INPUT_MODULE_URL))()

local FlyGuiContext = {
        player = player,
        GUI_CONTROLLED = GUI_CONTROLLED,
        stateChangedEvent = stateChangedEvent,
        getFlyEnabled = function() return flyEnabled == true end,
        getFlySpeed = function() return flySpeed end,
        setFlySpeed = function(value) flySpeed = math.clamp(value, flyMinSpeed, flyMaxSpeed) end,
        getFlyMinSpeed = function() return flyMinSpeed end,
        getFlyMaxSpeed = function() return flyMaxSpeed end,
        getFlyNoClipOn = function() return flyNoClipOn end,
        setFlyNoClipOn = function(value) flyNoClipOn = value end,
        setFlyNoClip = setFlyNoClip,
        getFlyCollisionDebugOn = function() return flyCollisionDebugOn end,
        setFlyCollisionDebugOn = function(value) flyCollisionDebugOn = value end,
        updateFlyCollisionDebug = updateFlyCollisionDebug,
        getFlyCameraFeelOn = function() return flyCameraFeelOn end,
        setFlyCameraFeelOn = function(value) flyCameraFeelOn = value end,
        flyState = flyState,
        getFlyStartupAnimationEnabled = function() return flyStartupAnimationEnabled end,
        setFlyStartupAnimationEnabled = function(value) flyStartupAnimationEnabled = value end,
        getFlyStartupActive = function() return flyStartupActive end,
        setFlyStartupActive = function(value) flyStartupActive = value end,
        getFlyStartupTime = function() return flyStartupTime end,
        setFlyStartupTime = function(value) flyStartupTime = value end,
        getFlyStartupStartPosition = function() return flyStartupStartPosition end,
        setFlyStartupStartPosition = function(value) flyStartupStartPosition = value end,
        stopFlyStartupAnimation = stopFlyStartupAnimation,
        stopFlyStartupPoseDriver = stopFlyStartupPoseDriver,
        clearFlyStartupPose = clearFlyStartupPose,
        clearStartupAnimatorSuppression = clearStartupAnimatorSuppression,
        startNormalFlyAnimationSet = startNormalFlyAnimationSet,
        enableFly = enableFly,
        disableFly = disableFly,
        getFlyShiftLockOn = function() return flyShiftLockOn end,
        setFlyShiftLockOn = function(value) flyShiftLockOn = value end,
    }

local FlyCameraInputContext = {
        disconnect = disconnectFlyCameraInput,
        flyCameraConnections = flyCameraConnections,
        flyState = flyState,
        getFlyEnabled = function() return flyEnabled end,
        getFlyCameraHandoffActive = function() return flyCameraHandoffActive end,
        getFlySpectatingOtherPlayer = function() return flySpectatingOtherPlayer end,
        getFlyJoystickTouch = function() return flyJoystickTouch end,
        setFlyCameraMouseLooking = function(value) flyCameraMouseLooking = value end,
        getFlyCameraMouseLooking = function() return flyCameraMouseLooking end,
        flyCameraIsInDynamicThumbstickArea = flyCameraIsInDynamicThumbstickArea,
        flyCameraIsOverGui = flyCameraIsOverGui,
        flyCameraAdjustTouchPitchSensitivity = flyCameraAdjustTouchPitchSensitivity,
        FLY_CAMERA_ZOOM_MIN = FLY_CAMERA_ZOOM_MIN,
        FLY_CAMERA_ZOOM_MAX = FLY_CAMERA_ZOOM_MAX,
        FLY_CAMERA_MIN_PITCH = FLY_CAMERA_MIN_PITCH,
        FLY_CAMERA_TOUCH_ROTATION_SPEED = FLY_CAMERA_TOUCH_ROTATION_SPEED,
        ContextActionService = ContextActionService,
        UserInputService = UserInputService,
    }

local function buildMiniGui()
    local controller = FlyGuiModule.build(FlyGuiContext)
    updateFlyShiftLockButton = controller.UpdateShiftLockButton
    controller.UpdateShiftLockButton()
    return controller
end

local function connectFlyCameraInput()
    FlyCameraInputModule.connect(FlyCameraInputContext)
end

local Controller = buildMiniGui()
return Controller
