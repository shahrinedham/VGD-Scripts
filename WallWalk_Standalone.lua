--[[
    VGD WallWalk Standalone v48.58 Continuous Stair Traversal
    Exact Face Gravity / In-Out Surface Rework + Emote Rebind Fix + Continuous Stair Ownership

    Base: v6 GravityController_Rebuild

    v8 goals:
      * Keep the v6 multi-ray surface sensor and VectorForce gravity model.
      * Keep Workspace.Gravity untouched.
      * Keep surface-normal jumping: floor / wall / ceiling all use currentUp.
      * Make joystick/WASD directions intuitive on every surface.
      * Make wall -> ceiling transitions easier by using predictive feelers and
        stronger candidate confirmation near the current surface.
      * Add a real ON/OFF button that restores Roblox movement, jumping,
        AutoRotate, PlatformStand and Animate cleanly.
      * Re-enable WallWalk cleanly after being turned OFF.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local CFG = {
    WalkSpeed = 16,
    Gravity = workspace.Gravity,

    -- Multi-ray surface sensor.
    DownRayLength = 18,
    FeelerLength = 7,
    SurfaceSwitchDistance = 2.75,
    PredictiveProbeLength = 4.5,
    PredictiveProbeVerticalBias = 0.85,
    PredictiveProbeStartOffset = 0.35,
    DownRayCount = 24,
    FeelerCount = 12,
    DownRayStartRadiusOdd = 3,
    DownRayStartRadiusEven = 2,
    DownRayEndRadiusOdd = 1.666,
    DownRayEndRadiusEven = 1,
    DownRayLowerOffset = 3,
    FeelerRadius = 3.5,
    FeelerStartOffset = 1.5,
    FeelerApexOffset = 1,
    FeelerWeight = 10,

    -- Higher value = quicker surface changes. This build intentionally responds
    -- faster near corners so wall -> ceiling does not require many attempts.
    GravityTransition = 0.32,
    -- After a real gravity-side switch, block ONLY an immediate switch back
    -- to the side we just left. The new side still commits immediately; this
    -- 0.1s lock prevents rapid A -> B -> A -> B detector chatter at corners.
    GravitySwitchBackCooldown = 0.10,
    GravitySwitchBackDot = 0.94,
    GravitySwitchDot = 0.996,
    StrongSwitchDot = 0.94,
    SurfaceSnapDot = 0.80,
    WallAdhesionOnly = true,

    -- Softer forces keep the controller from feeling dense/heavy while
    -- still giving enough authority for wall/ceiling locomotion.
    WalkForce = 42,
    MaxWalkForce = 4500,
    AdhesionStrength = 18,
    AdhesionDamping = 7,

    JumpModifier = 1.0,
    JumpCooldown = 0.18,
    JumpSpeedFallback = 50,

    OrientationResponsiveness = 90,
    FloorOrientationResponsiveness = 24,
    OrientationMaxTorque = 1000000,
    OrientationMaxAngularVelocity = 1000,
    TransitionMaxAngularVelocity = 40,
    TransitionMaxOutwardSpeed = 2.0,

    GroundProbeLength = 5.0,

    -- Exact local face probe. It samples a hemisphere centered on the
    -- character's current support direction. The selected face is NEVER
    -- averaged with neighboring faces, so polygon/hexagon facets stay exact.
    FaceProbeLength = 4.25,
    FaceProbeRings = 3,
    FaceProbeSides = 12,
    FaceProbeMaxAngle = 88,
    FaceProbeMaxSupportDistance = 3.60,
    AdhesionProbeLength = 2.75,
    SurfaceContactSnapDot = 0.985,

    -- Micro-surface immunity. Tiny brick seams, bumps and bevels should not
    -- become new gravity planes while walking. Large polygon/hexagon face
    -- changes still switch immediately.
    MicroSurfaceAngle = 7.0,
    MicroSurfaceDistance = 0.32,
    MicroSurfaceVelocityTolerance = 1.75,
    MicroAdhesionResponse = 18.0,

    -- Micro-step ramp controller. A small raised support face is treated as
    -- a very short ramp in the movement solver instead of a collision that
    -- the controller repeatedly pushes into. This remains intentionally
    -- conservative; the dedicated stair solver below handles taller, discrete
    -- steps without changing the old micro-step behavior.
    MicroStepMaxHeight = 0.34,
    MicroStepLookahead = 1.15,
    MicroStepProbeAbove = 1.45,
    MicroStepProbeLength = 3.15,
    MicroStepSideOffset = 0.65,
    MicroStepMinRise = 0.018,
    MicroStepMaxSlope = 28,
    MicroStepBlendResponse = 18,
    MicroStepHoldTime = 0.10,
    MicroStepClearance = 0.10,

    -- Discrete stair-step controller. This is deliberately separate from the
    -- micro-step system so tiny seams/bumps keep their old behavior while
    -- normal Roblox stair risers can be climbed on walls and ceilings.
    StairStepMaxHeight = 1.15,
    StairStepLookahead = 1.80,
    StairStepProbeAbove = 1.80,
    StairStepProbeLength = 4.20,
    StairStepSideOffset = 0.75,
    StairStepMinRise = 0.06,
    StairStepMaxSlope = 68,
    StairStepRiserProbeHeight = 0.24,
    StairStepRiserProbeLength = 2.40,
    StairStepRiserMinDot = 0.62,
    StairStepClearance = 0.08,
    StairStepBlendResponse = 20,
    StairStepHoldTime = 0.09,

    -- Continuous stair-ownership window. This is deliberately separate from
    -- the movement ramp timer. Gravity ownership can remain on the current
    -- surface while the next riser is being acquired.
    StairTraversalHoldTime = 0.72,
    StairTraversalForwardRange = 3.60,
    StairTraversalSideRange = 1.60,
    StairTraversalMoveDot = 0.70,
    StairTraversalNormalDot = 0.55,
    -- Surface-loss safety. The support fan is deliberately wider/longer than
    -- the old single center ray so an idle wall/ceiling player is still seen as
    -- supported even when the root ray lands near an edge/seam.
    SurfaceSafetyProbeLength = 3.25,
    SurfaceSafetyDelay = 0.2,
    SurfaceSafetySupportDistance = 3.10,
    SurfaceSafetyFanRadius = 0.85,
    SurfaceSafetySupportNormalDot = 0.88,

    -- Motion-based detachment detector.
    -- AwaySpeed/AwayDistance use the currently-owned surface axis (currentUp).
    -- WorldFallSpeed/WorldFallAcceleration catch the important wall case:
    -- when a character is no longer supported by a wall, Roblox's world
    -- gravity makes them accelerate downward even though currentUp is
    -- horizontal. This is deliberately independent of a support-ray hit.
    SurfaceSafetyAwaySpeed = 2.0,
    SurfaceSafetyAwayDistance = 0.45,
    SurfaceSafetyFallSpeed = 26.0,
    SurfaceSafetyFallAcceleration = 18.0,

    -- Dedicated movement-facing transition sensor. The old feeler system was
    -- excellent for corners but too indirect for the first floor -> wall
    -- handoff. These rays deliberately look where the player is moving.
    TransitionProbeLength = 5.5,
    TransitionProbeHeight = 1.15,
    TransitionProbeSide = 1.05,
    TransitionNormalDot = 0.82,
    TransitionWallDot = 0.78,
    -- Floor/ceiling -> wall ownership requires multi-sample confirmation.
    -- the upper transition feeler; small raised lips therefore cannot claim
    -- gravity just because their side face is in front of the player.
    FloorWallUpperConfirmation = true,
    SurfaceWallTwoHeightConfirmation = true,
    -- A transition face must be seen by at least this many distinct
    -- movement-probe offsets before it can steal gravity ownership.
    TransitionConfirmSamples = 2,
    -- The exact-face fallback is a SUPPORT-face refiner, not a single-ray
    -- corner detector. Faces ~90 degrees away must be confirmed by the
    -- dedicated movement-facing transition sensor instead.
    ExactFaceSupportMinDot = 0.45,
    GroundSlopeAngle = 89,

    ToggleWidth = 58,
    ToggleHeight = 26,
    PanelWidth = 190,
    PanelHeight = 50,
}

local character
local humanoid
local root
local controls
local rayParams

local gravityAttachment
local gravityForce
local orientationAttachment
local orientation

local enabled = true
local customActive = false
local controllerPhysicsActive = false
local currentUp = Vector3.yAxis
local targetUp = Vector3.yAxis
local lastDetectedUp = Vector3.yAxis
local lastSurfaceSeen = 0

local jumpRequested = false
local jumpInputHeld = false
local lastJump = 0
local jumped = false
local jumpStartedAt = 0
local jumpLaunchUp = UP
local jumpLaunchPosition = nil
local jumpLaunchPlaneCrossed = false
local justLanded = false
local jumpLocked = false
local jumpRequestLatched = false
local lastJumpRequestAt = 0
local surfaceLostAt = 0
local safetyReleased = false

-- Gravity-transition state. This is only armed by an actual gravity-plane
-- change detected by updateSurface(). It does NOT alter normal wall/ceiling
-- support detection or the existing safety timer.
local gravityTransitionActive = false
local orientationTransitionUntil = 0
-- Carry the character's SURFACE-PATH direction across a real gravity-side
-- change. The important part is that this is transported by the same rotation
-- that changes oldUp -> newUp, rather than simply projected onto the new plane.
-- That makes a forward wall/ceiling transition behave like walking around a
-- physical corner: the heading follows the surface instead of becoming random.
local transitionFacing = nil
local lastFacingDirection = nil
local transitionMoveCandidate = nil

-- During a gravity-side handoff, the character should not acquire a large
-- velocity component AWAY from the newly selected surface. The final physics
-- diagnostic showed that the remaining launch is a post-solver contact impulse
--, so limiting AlignOrientation angular speed alone is not sufficient. This
-- guard removes only excessive outward normal velocity during the 0.32s handoff;
-- tangent movement and normal WallWalk gravity are left untouched.
local function guardTransitionOutwardVelocity()
    if not root or not customActive or jumped then return end
    if os.clock() >= orientationTransitionUntil then return end

    local velocity = root.AssemblyLinearVelocity
    local outwardSpeed = velocity:Dot(currentUp)
    local maxOutward = CFG.TransitionMaxOutwardSpeed

    if outwardSpeed > maxOutward then
        root.AssemblyLinearVelocity = velocity - currentUp * (outwardSpeed - maxOutward)
    end
end
local gravitySwitchBackUp = nil
local gravitySwitchBackAt = 0
local safetySupportPoint = nil
local safetySupportNormal = nil
local safetySupportDistance = nil
local safetySupportAt = 0
local surfaceSupportSeen = false
local surfaceSupportPoint = nil
local surfaceSupportNormal = nil
local surfaceSupportDistance = math.huge

-- Motion history used by the safety handoff. We intentionally track position
-- and world-down speed instead of relying only on ray visibility.
local safetyPreviousPosition = nil
local safetyPreviousWorldDownSpeed = 0
local safetyAwayDistance = 0
local safetyAwaySpeed = 0
local safetyWorldFallSpeed = 0
local safetyWorldFallAcceleration = 0

local filteredAdhesionDistance = nil

local microStepBlend = 0
local microStepTargetBlend = 0
local microStepUntil = 0
local microStepMove = Vector3.zero

local stairStepBlend = 0
local stairStepTargetBlend = 0
local stairStepUntil = 0
local stairStepMove = Vector3.zero

-- Continuous stair traversal state. The state follows the staircase as
-- the player moves from one riser to the next instead of locking to one
-- physical step for a single short timer.
local stairTraversalActive = false
local stairTraversalUntil = 0
local stairTraversalPoint = nil
local stairTraversalNormal = nil
local stairTraversalMoveDir = nil
local stairTraversalTopHeight = nil

local animateScript
local animateWasDisabled = false
local animator
local animationTracks = {Idle = {}, Walk = {}, Run = {}, Jump = {}, Fall = {}}
local activeLocomotion
local activeAir
local activeIdle
local emoteTrack
local AnimationClipProvider = game:GetService("AnimationClipProvider")
local emoteLoopCache = {}
local emoteTrackConnection
local emoteHandlerGuardConnection
local installWallWalkEmoteHandler
local emoteMenuOpen = false
local emoteStateBridge = false
local emoteStateRestoreAt = 0

local gui
local statusLabel
local toggleButton
local jumpButton
local guiConnections = {}
local lifecycleConnections = {}
local heartbeatConnection
local cameraConnection
local destroyed = false
local setJumpButtonVisible

-- Snapshot Roblox-owned state so the X button can leave no WallWalk residue.
local originalState = {
    valid = false,
    animateDisabled = false,
    autoRotate = true,
    platformStand = false,
    walkSpeed = 16,
    cameraOffset = Vector3.zero,
    ragdollEnabled = true,
    fallingDownEnabled = true,
    physicsEnabled = true,
    runningEnabled = true,
    runningNoPhysicsEnabled = true,
    jumpingEnabled = true,
    freefallEnabled = true,
    landedEnabled = true,
    emoteOnInvoke = nil,
    emoteCaptured = false,
}

local ZERO = Vector3.zero
local UP = Vector3.yAxis

local function safeUnit(v, fallback)
    if v.Magnitude > 1e-5 then
        return v.Unit
    end
    return fallback
end

local function projectOnPlane(v, normal)
    return v - normal * v:Dot(normal)
end

-- Transport a direction through the exact shortest rotation that maps the
-- previous surface normal to the new surface normal. Projection alone is not
-- enough for FORWARD transitions: when the old movement direction points
-- toward the new surface, its projection onto that new plane can collapse or
-- choose an arbitrary fallback. Rotating the tangent frame preserves the
-- actual path around the corner instead.
local function transportDirection(oldDirection, oldUp, newUp)
    local direction = safeUnit(oldDirection, Vector3.zAxis)
    local from = safeUnit(oldUp, UP)
    local to = safeUnit(newUp, from)
    local dot = math.clamp(from:Dot(to), -1, 1)

    if dot > 0.999999 then
        return direction
    end

    local axis = from:Cross(to)
    local axisMagnitude = axis.Magnitude
    if axisMagnitude < 1e-5 then
        -- 180-degree flip: choose a stable axis perpendicular to from.
        local helper = math.abs(from.Y) < 0.9 and Vector3.yAxis or Vector3.xAxis
        axis = from:Cross(helper)
        axisMagnitude = axis.Magnitude
        if axisMagnitude < 1e-5 then
            helper = Vector3.zAxis
            axis = from:Cross(helper)
            axisMagnitude = axis.Magnitude
        end
    end
    axis = axis / math.max(axisMagnitude, 1e-5)

    local angle = math.acos(dot)
    local rotated = CFrame.fromAxisAngle(axis, angle):VectorToWorldSpace(direction)
    return safeUnit(rotated, projectOnPlane(direction, to))
end

local function stopTrack(track, fade)
    if track and track.IsPlaying then
        pcall(function() track:Stop(fade or 0.08) end)
    end
end

local function stopGroup(group, fade)
    for _, track in ipairs(group or {}) do
        stopTrack(track, fade)
    end
end

local function destroyAnimationTracks()
    emoteTrack = nil
    for _, group in pairs(animationTracks) do
        for _, track in ipairs(group) do
            pcall(function()
                track:Stop(0)
                track:Destroy()
            end)
        end
    end
    animationTracks = {Idle = {}, Walk = {}, Run = {}, Jump = {}, Fall = {}}
    activeLocomotion = nil
    activeAir = nil
    activeIdle = nil
end

local function loadAnimationGroup(container)
    local result = {}
    if not container or not animator then return result end

    for _, object in ipairs(container:GetChildren()) do
        if object:IsA("Animation") and object.AnimationId ~= "" then
            local ok, track = pcall(function()
                local t = animator:LoadAnimation(object)
                t.Looped = true
                t.Priority = Enum.AnimationPriority.Movement
                return t
            end)
            if ok and track then table.insert(result, track) end
        end
    end
    return result
end

local function loadCharacterAnimations()
    destroyAnimationTracks()
    if emoteTrackConnection then
        emoteTrackConnection:Disconnect()
        emoteTrackConnection = nil
    end
    if not humanoid then return end

    animator = humanoid:FindFirstChildOfClass("Animator")
        or humanoid:WaitForChild("Animator", 3)
    if not animator then return end

    animateScript = animateScript or (character and character:FindFirstChild("Animate"))
    if not animateScript then return end

    animationTracks.Idle = loadAnimationGroup(animateScript:FindFirstChild("idle"))
    animationTracks.Walk = loadAnimationGroup(animateScript:FindFirstChild("walk"))
    animationTracks.Run = loadAnimationGroup(animateScript:FindFirstChild("run"))
    animationTracks.Jump = loadAnimationGroup(animateScript:FindFirstChild("jump"))
    animationTracks.Fall = loadAnimationGroup(animateScript:FindFirstChild("fall"))

    animateWasDisabled = animateScript.Disabled
    animateScript.Disabled = true

    -- Roblox emotes are played through the character Animator. WallWalk uses
    -- Movement-priority tracks for locomotion, so Action-priority emotes can
    -- coexist with the custom gravity controller. Keep the emote track alive
    -- instead of letting the locomotion updater restart over it every frame.
    emoteTrackConnection = animator.AnimationPlayed:Connect(function(track)
        if not track then return end
        local priority = track.Priority
        if priority == Enum.AnimationPriority.Action
            or priority == Enum.AnimationPriority.Action2
            or priority == Enum.AnimationPriority.Action3
            or priority == Enum.AnimationPriority.Action4 then
            emoteTrack = track
            track.Stopped:Connect(function()
                if emoteTrack == track then
                    emoteTrack = nil
                end
            end)
        end
    end)
end

local function cancelActiveEmote()
    if not emoteTrack then return false end

    local track = emoteTrack
    emoteTrack = nil
    pcall(function()
        if track.IsPlaying then
            track:Stop(0.05)
        end
    end)
    return true
end

local function updateAnimations(moving, grounded, speed)
    if not animator then return end

    -- Movement always cancels an emote. Check this BEFORE the active-emote
    -- early-return so locomotion cannot trap the emote in place.
    local movingNow = moving
    if humanoid and humanoid.MoveDirection.Magnitude > 0.05 then
        movingNow = true
    end
    if emoteTrack and emoteTrack.IsPlaying and movingNow then
        cancelActiveEmote()
    end

    -- Never restart WallWalk locomotion while an emote is active. Roblox
    -- emotes normally use Action priorities, while our movement tracks use
    -- Movement, so the emote gets full body priority without affecting physics.
    if emoteTrack and emoteTrack.IsPlaying then
        stopTrack(activeLocomotion, 0.08)
        stopTrack(activeIdle, 0.08)
        activeLocomotion = nil
        activeIdle = nil
        stopTrack(activeAir, 0.08)
        activeAir = nil
        return
    end

    if not grounded then
        stopTrack(activeLocomotion, 0.06)
        stopTrack(activeIdle, 0.06)
        activeLocomotion = nil
        activeIdle = nil

        local group = jumped and animationTracks.Jump or animationTracks.Fall
        local track = group[1]
        if track and activeAir ~= track then
            stopTrack(activeAir, 0.06)
            activeAir = track
            pcall(function() track:Play(0.06, 1, 1) end)
        elseif track and not track.IsPlaying then
            pcall(function() track:Play(0.06, 1, 1) end)
        end
        return
    end

    stopTrack(activeAir, 0.06)
    activeAir = nil

    if not moving then
        stopTrack(activeLocomotion, 0.08)
        activeLocomotion = nil
        local idle = animationTracks.Idle[1]
        if idle then
            if activeIdle ~= idle then
                stopTrack(activeIdle, 0.06)
                activeIdle = idle
            end
            if not idle.IsPlaying then pcall(function() idle:Play(0.08, 1, 1) end) end
        end
        return
    end

    stopTrack(activeIdle, 0.06)
    activeIdle = nil

    local group = #animationTracks.Run > 0 and animationTracks.Run or animationTracks.Walk
    local track = group[1]
    if not track then return end

    if activeLocomotion ~= track then
        stopTrack(activeLocomotion, 0.06)
        activeLocomotion = track
    end
    if not track.IsPlaying then pcall(function() track:Play(0.08, 1, 1) end) end

    pcall(function()
        track:AdjustSpeed(math.clamp(speed / math.max(CFG.WalkSpeed, 0.01), 0.55, 1.4))
    end)
end


function installWallWalkEmoteHandler()
    if not character or not humanoid then return end

    local animate = character:FindFirstChild("Animate")
    if not animate then return end

    local playEmote = animate:FindFirstChild("PlayEmote")
    if not playEmote or not playEmote:IsA("BindableFunction") then
        if playEmote then playEmote:Destroy() end
        playEmote = Instance.new("BindableFunction")
        playEmote.Name = "PlayEmote"
        playEmote.Parent = animate
    end

    -- IMPORTANT:
    -- Current Roblox emote dispatch can invoke Animate.PlayEmote with the
    -- actual Animation instance, not only a string name. Older versions of
    -- this handler only accepted strings, so the CoreGui wheel got a false
    -- result even though the emote itself was valid. Support BOTH forms.
    playEmote.OnInvoke = function(emoteInput)
        if not humanoid or humanoid.Health <= 0 or not animator then
            return false
        end

        local sourceAnimation
        local ownedAnimation = false
        local requestedName

        if typeof(emoteInput) == "Instance" and emoteInput:IsA("Animation") then
            -- This is the important path for the Roblox emote wheel.
            sourceAnimation = emoteInput
            requestedName = emoteInput.Name
            if sourceAnimation.AnimationId == "" then
                return false
            end
        elseif type(emoteInput) == "string" and emoteInput ~= "" then
            -- Keep compatibility with string-name callers such as explicit
            -- Humanoid:PlayEmote("Wave") calls, chat /e commands and older
            -- emote dispatchers. The classic Roblox emotes are not guaranteed
            -- to appear in HumanoidDescription:GetEmotes(), so handle their
            -- built-in Animate names explicitly first.
            requestedName = emoteInput

            local normalizedName = string.lower(emoteInput)
            local legacyEmotes = {
                wave = {507770239},
                point = {507770453},
                dance = {507771019, 507771955, 507772104},
                dance1 = {507771019},
                dance2 = {507776043},
                dance3 = {507777268},
                laugh = {507770818},
                cheer = {507770677},
                salute = {3360689775},
            }

            local ids = legacyEmotes[normalizedName]
            if ids and #ids > 0 then
                local assetId = ids[math.random(1, #ids)]
                sourceAnimation = Instance.new("Animation")
                sourceAnimation.Name = "VGD_DefaultEmote_" .. normalizedName
                sourceAnimation.AnimationId = "rbxassetid://" .. tostring(assetId)
                ownedAnimation = true
            end

            if not sourceAnimation then
                local description = humanoid:FindFirstChildOfClass("HumanoidDescription")
                if not description then
                    local ok, result = pcall(function()
                        return humanoid:GetAppliedDescription()
                    end)
                    if ok then description = result end
                end
                if not description then return false end

                local ok, emotes = pcall(function()
                    return description:GetEmotes()
                end)
                if not ok or type(emotes) ~= "table" then return false end

                local ids = emotes[emoteInput]
                if type(ids) ~= "table" or #ids == 0 then
                    local lower = string.lower(emoteInput)
                    ids = emotes[lower] or emotes[string.upper(string.sub(lower,1,1)) .. string.sub(lower,2)]
                    if (type(ids) ~= "table" or #ids == 0) and lower == "dance" then
                        ids = emotes.dance1 or emotes.Dance1
                            or emotes.dance2 or emotes.Dance2
                            or emotes.dance3 or emotes.Dance3
                    end
                end
                if type(ids) ~= "table" or #ids == 0 then return false end

                local assetId = ids[math.random(1, #ids)]
                if not assetId then return false end

                sourceAnimation = Instance.new("Animation")
                sourceAnimation.Name = "VGD_Emote_" .. emoteInput
                sourceAnimation.AnimationId = "rbxassetid://" .. tostring(assetId)
                ownedAnimation = true
            end
        else
            return false
        end

        -- Replace an older emote cleanly instead of allowing multiple Action
        -- tracks to accumulate when the user taps the wheel twice.
        if emoteTrack and emoteTrack.IsPlaying then
            pcall(function() emoteTrack:Stop(0.05) end)
        end
        emoteTrack = nil

        local okTrack, track = pcall(function()
            return animator:LoadAnimation(sourceAnimation)
        end)
        if not okTrack or not track then
            if ownedAnimation then
                pcall(function() sourceAnimation:Destroy() end)
            end
            return false
        end

        track.Priority = Enum.AnimationPriority.Action
        local lowerRequestedName = string.lower(tostring(requestedName or ""))

        -- Keep the v42 acceptance/play path EXACTLY intact for the Roblox
        -- emote wheel. Do not wait for asset metadata inside OnInvoke: doing
        -- network/asset work there can make CoreGui reject the emote as if it
        -- were unavailable. For wheel-provided Animation instances, Roblox's
        -- loaded track already has its normal authored default. We resolve the
        -- definitive AnimationClip.Loop asynchronously after the emote has
        -- been accepted and started.
        local wheelAnimation = typeof(emoteInput) == "Instance"
            and emoteInput:IsA("Animation")

        if not wheelAnimation then
            track.Looped = lowerRequestedName == "dance"
                or lowerRequestedName == "dance1"
                or lowerRequestedName == "dance2"
                or lowerRequestedName == "dance3"
        else
            local animationId = tostring(sourceAnimation.AnimationId or "")
            local assetId = animationId:match("(%d+)%s*$")
            if assetId then
                local cachedLoop = emoteLoopCache[assetId]
                if type(cachedLoop) == "boolean" then
                    track.Looped = cachedLoop
                else
                    task.spawn(function()
                        local okClip, clip = pcall(function()
                            return AnimationClipProvider:GetAnimationClipAsync(
                                "rbxassetid://" .. assetId
                            )
                        end)
                        if okClip and clip and type(clip.Loop) == "boolean" then
                            local loopValue = clip.Loop
                            emoteLoopCache[assetId] = loopValue
                            if emoteTrack == track and track.IsPlaying then
                                pcall(function()
                                    track.Looped = loopValue
                                end)
                            end
                            pcall(function() clip:Destroy() end)
                        end
                    end)
                end
            end
        end

        emoteTrack = track

        local stoppedConnection
        stoppedConnection = track.Stopped:Connect(function()
            if stoppedConnection then stoppedConnection:Disconnect() end
            if emoteTrack == track then emoteTrack = nil end
            pcall(function() track:Destroy() end)
            if ownedAnimation then
                pcall(function() sourceAnimation:Destroy() end)
            end
        end)

        local okPlay, playResult = pcall(function()
            track:Play(0.08, 1, 1)
            return true
        end)
        if not okPlay or not playResult then
            if stoppedConnection then stoppedConnection:Disconnect() end
            emoteTrack = nil
            pcall(function() track:Destroy() end)
            if ownedAnimation then
                pcall(function() sourceAnimation:Destroy() end)
            end
            return false
        end

        -- Roblox's Animate emote hook treats a successful true return as
        -- acceptance of the request. Returning the track as the second value
        -- also matches the common Animate hook contract.
        return true, track
    end
end

local function getPlayerControls()
    local scripts = player:FindFirstChildOfClass("PlayerScripts")
    local module = scripts and scripts:FindFirstChild("PlayerModule")
    if not module then return nil end

    local ok, playerModule = pcall(require, module)
    if not ok or not playerModule or not playerModule.GetControls then return nil end

    local success, result = pcall(function() return playerModule:GetControls() end)
    return success and result or nil
end

local function getMoveVector()
    if controls then
        local ok, value = pcall(function() return controls:GetMoveVector() end)
        if ok and typeof(value) == "Vector3" then
            return value
        end
    end

    -- Fallback used by the older stable controller. This keeps keyboard/mobile
    -- movement available even if PlayerModule's Controls object is late.
    if humanoid and humanoid.MoveDirection.Magnitude > 0.001 then
        local camera = workspace.CurrentCamera
        if camera then
            local look = camera.CFrame.LookVector
            local right = camera.CFrame.RightVector
            local flatLook = safeUnit(Vector3.new(look.X, 0, look.Z), Vector3.zAxis)
            local flatRight = safeUnit(Vector3.new(right.X, 0, right.Z), Vector3.xAxis)
            return Vector3.new(
                humanoid.MoveDirection:Dot(flatRight),
                0,
                -humanoid.MoveDirection:Dot(flatLook)
            )
        end
    end

    return ZERO
end

local function cast(origin, direction, length)
    if not rayParams or direction.Magnitude <= 1e-5 then return nil end
    return workspace:Raycast(origin, direction.Unit * length, rayParams)
end

local function orientSurfaceNormal(hit, rayDirection)
    if not hit then return nil end

    local normal = safeUnit(hit.Normal, UP)
    if rayDirection and rayDirection.Magnitude > 1e-5 then
        local direction = rayDirection.Unit
        -- We want character-up to point from the surface toward the character.
        -- This works for both the outside and inside of polygonal geometry and
        -- also protects us from meshes whose face winding points the other way.
        if normal:Dot(direction) > 0 then
            normal = -normal
        end
    end

    return normal
end

local function getExactSupportFace(oldUp, moveVector)
    if not root or not customActive then return nil, nil, math.huge end

    local origin = root.Position
    local tangent = projectOnPlane(root.CFrame.LookVector, oldUp)
    if tangent.Magnitude < 0.05 and moveVector and moveVector.Magnitude > 0.05 then
        local camera = workspace.CurrentCamera
        if camera then
            tangent = projectOnPlane(camera.CFrame.LookVector, oldUp)
        end
    end
    tangent = safeUnit(tangent, Vector3.zAxis)

    local side = safeUnit(oldUp:Cross(tangent), Vector3.xAxis)
    tangent = safeUnit(side:Cross(oldUp), tangent)

    local moveDir = ZERO
    if moveVector and moveVector.Magnitude > 0.05 then
        local camera = workspace.CurrentCamera
        if camera then
            local forward = projectOnPlane(camera.CFrame.LookVector, oldUp)
            if forward.Magnitude < 0.05 then
                forward = projectOnPlane(camera.CFrame.UpVector, oldUp)
            end
            forward = safeUnit(forward, tangent)
            local right = safeUnit(forward:Cross(oldUp), side)
            forward = safeUnit(oldUp:Cross(right), forward)
            moveDir = right * moveVector.X + forward * (-moveVector.Z)
            if moveDir.Magnitude > 0.05 then
                moveDir = moveDir.Unit
            else
                moveDir = ZERO
            end
        end
    end

    local bestNormal
    local bestHit
    local bestDistance = math.huge
    local bestScore = math.huge
    local maxAngle = math.rad(math.clamp(CFG.FaceProbeMaxAngle, 1, 89))

    local function consider(direction)
        local hit = cast(origin, direction, CFG.FaceProbeLength)
        if not hit then return end

        local normal = orientSurfaceNormal(hit, direction)
        if not normal then return end

        -- IMPORTANT: this sensor is a support-face refiner, not a one-ray
        -- transition detector. A face that is roughly 90 degrees away from
        -- the currently-owned plane is normally a corner/riser. Those faces
        -- must be confirmed by the dedicated movement-facing transition sensor
        -- so a tiny step cannot rotate gravity for one frame. We still allow
        -- substantial but supportable facet changes (30/45/60 degree faces).
        local supportDot = math.clamp(oldUp:Dot(normal), -1, 1)
        if supportDot < CFG.ExactFaceSupportMinDot then return end

        -- Reject surfaces that are effectively tangent to the ray. Those are
        -- edge/graze hits and are too unstable to own gravity.
        local facing = math.abs(normal:Dot(direction.Unit))
        if facing < 0.18 then return end

        local rayDistance = (hit.Position - origin).Magnitude
        local perpendicularDistance = math.abs((origin - hit.Position):Dot(normal))
        if perpendicularDistance > CFG.FaceProbeMaxSupportDistance then return end

        local supportChange = 1 - math.clamp(oldUp:Dot(normal), -1, 1)
        local movementBias = 0
        if moveDir.Magnitude > 0.05 then
            movementBias = math.max(0, normal:Dot(moveDir))
        end

        -- Perpendicular distance is the primary owner signal: it measures how
        -- far the character is from the actual planar face, not how long an
        -- angled ray travelled. Movement alignment breaks near-equal edge ties
        -- in favor of the face the player is walking onto.
        local score = perpendicularDistance + rayDistance * 0.025
            - movementBias * 0.18 - supportChange * 0.002

        if score < bestScore then
            bestScore = score
            bestDistance = perpendicularDistance
            bestNormal = normal
            bestHit = hit
        end
    end

    consider(-oldUp)

    for ring = 1, CFG.FaceProbeRings do
        local alpha = ring / CFG.FaceProbeRings
        local angle = maxAngle * alpha
        local upWeight = math.cos(angle)
        local tangentWeight = math.sin(angle)

        for i = 1, CFG.FaceProbeSides do
            local theta = math.pi * 2 * ((i - 1) / CFG.FaceProbeSides)
            local radial = tangent * math.cos(theta) + side * math.sin(theta)
            local direction = safeUnit(-oldUp * upWeight + radial * tangentWeight, -oldUp)
            consider(direction)
        end
    end

    if bestNormal then
        return bestNormal, bestHit, bestDistance
    end

    return nil, nil, math.huge
end

-- Stair-riser ownership guard.
-- A stair riser is intentionally allowed to be a collision obstacle, but it
-- must NOT become a new gravity plane while the player is walking on the
-- current floor/wall/ceiling. The dedicated stair solver below already knows
-- how to climb it; this helper only tells the gravity detector to ignore the
-- riser when a valid walkable top is confirmed ahead.
local function confirmStairRiser(basePoint, moveDir, side, rise, up)
    local heights = {
        0.10,
        math.clamp(rise * 0.55, 0.10, CFG.StairStepRiserProbeHeight),
        math.clamp(rise * 0.80, 0.12, CFG.StairStepRiserProbeHeight + 0.04),
    }
    local offsets = {-CFG.StairStepSideOffset, 0, CFG.StairStepSideOffset}
    for _, h in ipairs(heights) do
        for _, o in ipairs(offsets) do
            local origin = basePoint + moveDir * 0.04 + side * o + up * h
            local hit = cast(origin, moveDir, math.max(CFG.StairStepRiserProbeLength, rise + 1.0))
            if hit then
                local n = orientSurfaceNormal(hit, moveDir)
                if n then
                    local facing = (-moveDir):Dot(n)
                    local height = math.abs((hit.Position - basePoint):Dot(up))
                    if facing >= CFG.StairStepRiserMinDot
                        and up:Dot(n) < 0.35
                        and height <= rise + 0.24
                    then
                        return true
                    end
                end
            end
        end
    end
    return false
end

local function getStairMoveDirection(up, moveVector)
    if not moveVector then return nil end
    if moveVector.Magnitude < 0.05 then return nil end

    local camera = workspace.CurrentCamera
    if not camera then return nil end

    local forward = projectOnPlane(camera.CFrame.LookVector, up)
    if forward.Magnitude < 0.05 then
        forward = projectOnPlane(camera.CFrame.UpVector, up)
    end

    forward = safeUnit(forward, root.CFrame.LookVector)

    local right = safeUnit(forward:Cross(up), root.CFrame.RightVector)
    forward = safeUnit(up:Cross(right), forward)

    local move = right * moveVector.X + forward * (-moveVector.Z)
    if move.Magnitude < 0.05 then return nil end

    return move.Unit
end

local function clearStairTraversal()
    stairTraversalActive = false
    stairTraversalUntil = 0
    stairTraversalPoint = nil
    stairTraversalNormal = nil
    stairTraversalMoveDir = nil
    stairTraversalTopHeight = nil
end

local function detectStairRiserGeometry(oldUp, moveVector)
    if not root or not humanoid then return false end

    local moveDir = getStairMoveDirection(oldUp, moveVector)
    if not moveDir then return false end

    local side = safeUnit(moveDir:Cross(oldUp), root.CFrame.RightVector)

    local maxRise = CFG.StairStepMaxHeight
    local probeLength = CFG.StairStepRiserProbeLength + 0.70
    local topProbeLength = CFG.StairStepProbeLength + 0.80

    if probeLength < 2.60 then
        probeLength = 2.60
    end

    if topProbeLength < maxRise + 1.80 then
        topProbeLength = maxRise + 1.80
    end

    -- Prefer the previously confirmed support point. This removes the race in
    -- which a slow-moving character is already close to the riser and the
    -- three support rays temporarily disagree about the current floor height.
    local basePoint = nil
    local baseHeight = nil

    if surfaceSupportSeen and surfaceSupportPoint and surfaceSupportNormal then
        local supportDot = oldUp:Dot(surfaceSupportNormal)
        if supportDot > 0.92 then
            basePoint = surfaceSupportPoint
            baseHeight = surfaceSupportPoint:Dot(oldUp)
        end
    end

    if not basePoint then
        local hip = humanoid.HipHeight
        if hip <= 0 then
            hip = 2
        end

        local supportLength = math.max(CFG.AdhesionProbeLength, hip + 0.75)
        local offsets = {
            -CFG.StairStepSideOffset,
            0,
            CFG.StairStepSideOffset,
        }
        local heights = {}

        for _, sideOffset in ipairs(offsets) do
            local supportOrigin = root.Position + side * sideOffset
            local supportHit = cast(supportOrigin, -oldUp, supportLength)

            if supportHit then
                local supportNormal = orientSurfaceNormal(supportHit, -oldUp)
                if supportNormal then
                    local supportDot = oldUp:Dot(supportNormal)
                    if supportDot > 0.92 then
                        table.insert(heights, supportHit.Position:Dot(oldUp))
                    end
                end
            end
        end

        if #heights > 0 then
            table.sort(heights)
            local middle = math.ceil(#heights / 2)
            baseHeight = heights[middle]
            local rootHeight = root.Position:Dot(oldUp)
            local offset = rootHeight - baseHeight
            basePoint = root.Position - oldUp * offset
        end
    end

    if not basePoint or not baseHeight then
        return false
    end

    -- Keep the pre-riser scan deliberately small. WallWalk already has a
    -- large surface sensor, so the stair detector only needs a compact
    -- three-position forward sweep plus several height slices.
    local forwardStarts = {
        0.05,
        0.45,
        0.90,
    }

    local riserHeights = {
        0.10,
        0.30,
        0.55,
        0.80,
        1.02,
    }

    local offsets = {
        -CFG.StairTraversalSideRange * 0.55,
        0,
        CFG.StairTraversalSideRange * 0.55,
    }

    local bestPoint = nil
    local bestNormal = nil
    local bestTopHeight = nil
    local bestScore = math.huge

    for _, sideOffset in ipairs(offsets) do
        for _, forwardStart in ipairs(forwardStarts) do
            for _, heightOffset in ipairs(riserHeights) do
                local riserOrigin = basePoint
                    + side * sideOffset
                    + moveDir * forwardStart
                    + oldUp * heightOffset

                local riserHit = cast(riserOrigin, moveDir, probeLength)

                if riserHit then
                    local riserNormal = orientSurfaceNormal(riserHit, moveDir)

                    if riserNormal then
                        local facing = (-moveDir):Dot(riserNormal)
                        local surfaceDot = math.abs(oldUp:Dot(riserNormal))
                        local riserRise = (riserHit.Position - basePoint):Dot(oldUp)
                        local riserRun = (riserHit.Position - root.Position):Dot(moveDir)

                        local facingValid = facing >= CFG.StairStepRiserMinDot
                        local surfaceValid = surfaceDot < 0.50
                        local riseValid = riserRise >= CFG.StairStepMinRise
                            and riserRise <= maxRise + 0.15
                        local runValid = riserRun >= -0.15
                            and riserRun <= CFG.StairTraversalForwardRange

                        if facingValid and surfaceValid and riseValid and runValid then
                            -- Probe just beyond the actual riser. This is more
                            -- reliable at low movement speed than probing from
                            -- the root by a fixed total distance.
                            local topOrigin = riserHit.Position
                                + moveDir * 0.10
                                + oldUp * (maxRise + 0.34)

                            local topHit = cast(topOrigin, -oldUp, topProbeLength)

                            if topHit then
                                local topNormal = orientSurfaceNormal(topHit, -oldUp)

                                if topNormal then
                                    local topNormalDot = oldUp:Dot(topNormal)
                                    local topHeight = topHit.Position:Dot(oldUp)
                                    local topRise = topHeight - baseHeight
                                    local topRun = (topHit.Position - root.Position):Dot(moveDir)
                                    local runAfter = topRun - riserRun

                                    local topNormalValid = topNormalDot > 0.955
                                    local topRiseValid = topRise >= CFG.StairStepMinRise
                                        and topRise <= maxRise + 0.15
                                    local topRunValid = runAfter >= 0.06
                                        and topRun <= CFG.StairTraversalForwardRange + 0.45

                                    if topNormalValid and topRiseValid and topRunValid then
                                        local slopeRise = math.max(topRise, 0)
                                        local slopeRun = math.max(topRun, 0.05)
                                        local slopeRatio = slopeRise / slopeRun
                                        local slopeRadians = math.atan(slopeRatio)
                                        local slopeDegrees = math.deg(slopeRadians)
                                        local slopeValid = slopeDegrees <= CFG.StairStepMaxSlope

                                        if slopeValid then
                                            local sidePenalty = math.abs(sideOffset) * 0.10
                                            local score = riserRun + sidePenalty

                                            if score < bestScore then
                                                bestScore = score
                                                bestPoint = riserHit.Position
                                                bestNormal = riserNormal
                                                bestTopHeight = topHeight
                                            end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    if not bestPoint or not bestNormal then
        return false
    end

    return true, bestPoint, bestNormal, moveDir, bestTopHeight
end

local function isStairRiserAhead(oldUp, moveVector)
    local now = os.clock()
    local moveDir = getStairMoveDirection(oldUp, moveVector)

    if not moveDir then
        if stairTraversalActive and now < stairTraversalUntil then
            return true
        end

        clearStairTraversal()
        return false
    end

    local detected, point, normal, detectedMoveDir, topHeight = detectStairRiserGeometry(oldUp, moveVector)

    if detected then
        stairTraversalActive = true
        stairTraversalUntil = now + CFG.StairTraversalHoldTime
        stairTraversalPoint = point
        stairTraversalNormal = normal
        stairTraversalMoveDir = detectedMoveDir
        stairTraversalTopHeight = topHeight
        return true
    end

    if not stairTraversalActive then
        return false
    end

    if now >= stairTraversalUntil then
        clearStairTraversal()
        return false
    end

    if not stairTraversalMoveDir then
        clearStairTraversal()
        return false
    end

    local directionDot = moveDir:Dot(stairTraversalMoveDir)
    if directionDot < CFG.StairTraversalMoveDot then
        clearStairTraversal()
        return false
    end

    if not stairTraversalPoint then
        clearStairTraversal()
        return false
    end

    local toRoot = root.Position - stairTraversalPoint
    local forwardFromLast = toRoot:Dot(stairTraversalMoveDir)
    local side = safeUnit(stairTraversalMoveDir:Cross(oldUp), root.CFrame.RightVector)
    local sideFromLast = math.abs(toRoot:Dot(side))

    if forwardFromLast > CFG.StairTraversalForwardRange + 0.45 then
        clearStairTraversal()
        return false
    end

    if sideFromLast > CFG.StairTraversalSideRange + 0.80 then
        clearStairTraversal()
        return false
    end

    -- If the current support has already moved onto the detected stair top,
    -- keep the traversal alive even when no new riser is visible for one or
    -- several slow frames. This is what makes the system speed-independent.
    if surfaceSupportSeen and surfaceSupportPoint and stairTraversalTopHeight then
        local currentHeight = surfaceSupportPoint:Dot(oldUp)
        local heightDelta = math.abs(currentHeight - stairTraversalTopHeight)
        if heightDelta <= CFG.StairStepMaxHeight + 0.20 then
            return true
        end
    end

    return true
end

local function isOwnedStairRiserHit(hit, normal, oldUp, moveDir)
    if not hit or not normal or not moveDir then
        return false
    end

    if not stairTraversalActive then
        return false
    end

    if os.clock() >= stairTraversalUntil then
        clearStairTraversal()
        return false
    end

    if not stairTraversalPoint or not stairTraversalMoveDir then
        clearStairTraversal()
        return false
    end

    local moveDot = moveDir:Dot(stairTraversalMoveDir)
    if moveDot < CFG.StairTraversalMoveDot then
        return false
    end

    local currentSurfaceDot = math.abs(oldUp:Dot(normal))
    if currentSurfaceDot > 0.75 then
        return false
    end

    local normalDot = normal:Dot(stairTraversalNormal or normal)
    if normalDot < CFG.StairTraversalNormalDot then
        return false
    end

    local toHit = hit.Position - stairTraversalPoint
    local forwardOffset = toHit:Dot(stairTraversalMoveDir)
    if forwardOffset < -0.90 then
        return false
    end

    if forwardOffset > CFG.StairTraversalForwardRange then
        return false
    end

    local side = safeUnit(stairTraversalMoveDir:Cross(oldUp), root.CFrame.RightVector)
    local sideOffset = math.abs(toHit:Dot(side))
    if sideOffset > CFG.StairTraversalSideRange then
        return false
    end

    return true
end

local function getGravityUp(oldUp, moveVector)
    if not root then return oldUp, false, false, nil, nil, math.huge end

    local origin = root.Position
    local radial = root.CFrame.LookVector:Cross(oldUp)
    if radial.Magnitude < 1e-4 then
        radial = root.CFrame.RightVector:Cross(oldUp)
    end
    radial = safeUnit(radial, Vector3.xAxis)

    local normalSum = ZERO
    local hitWeight = 0
    local closestDistance = math.huge
    local closestNormal
    local transitionNormal
    local transitionDistance = math.huge
    local supportSeen = false
    local supportPoint
    local supportNormal
    local supportDistance = math.huge

    -- v48.58: decide continuous stair ownership BEFORE any gravity-support
    -- rays are added. Every gravity acquisition path below consults the same
    -- traversal state so a riser cannot become the new gravity plane.
    local floorOrCeiling = math.abs(oldUp:Dot(UP)) > 0.985
    local stairRiserAhead = false
    local stairMoveDir = nil

    if moveVector and moveVector.Magnitude > 0.05 then
        local camera = workspace.CurrentCamera
        if camera then
            local forward = projectOnPlane(camera.CFrame.LookVector, oldUp)

            if forward.Magnitude < 0.05 then
                forward = projectOnPlane(camera.CFrame.UpVector, oldUp)
            end

            forward = safeUnit(forward, root.CFrame.LookVector)

            local right = safeUnit(forward:Cross(oldUp), root.CFrame.RightVector)
            forward = safeUnit(oldUp:Cross(right), forward)

            local candidateMoveDir = right * moveVector.X + forward * (-moveVector.Z)

            if candidateMoveDir.Magnitude > 0.05 then
                stairMoveDir = candidateMoveDir.Unit
            end
        end

        -- Stair detection is surface-relative. It must work on floor, wall,
        -- and ceiling gravity, so it cannot be limited to world-horizontal
        -- floor/ceiling states.
        stairRiserAhead = isStairRiserAhead(oldUp, moveVector)
    end

    local function addHit(hit, weight, rayDirection)
        if not hit then return end

        local normal = orientSurfaceNormal(hit, rayDirection)
        if not normal then return end

        if stairMoveDir and isOwnedStairRiserHit(hit, normal, oldUp, stairMoveDir) then
            return
        end

        local distance = (hit.Position - origin).Magnitude
        local perpendicularDistance = math.abs((origin - hit.Position):Dot(normal))

        -- Safety support must mean NEAR CONTACT with the currently-owned face,
        -- not merely that one of the angled acquisition rays happened to hit
        -- something within its travel distance. The old path-distance test
        -- could keep the safety timer alive for several seconds after the
        -- character had already moved away because the offset down-rays could
        -- still reach the old wall.
        if oldUp:Dot(normal) >= CFG.SurfaceSafetySupportNormalDot
            and perpendicularDistance <= CFG.AdhesionProbeLength
        then
            supportSeen = true
            if perpendicularDistance < supportDistance then
                supportDistance = perpendicularDistance
                supportPoint = hit.Position
                supportNormal = normal
            end
        end
        if distance < closestDistance then
            closestDistance = distance
            closestNormal = normal
        end
        normalSum += normal * weight
        hitWeight += weight
    end

    local center = cast(origin, -oldUp, CFG.DownRayLength)
    if center then addHit(center, 1.5, -oldUp) end

    for i = 1, CFG.DownRayCount do
        local theta = math.pi * 2 * ((i - 1) / CFG.DownRayCount)
        local rotation = CFrame.fromAxisAngle(oldUp, theta)
        local offset = rotation * radial
        local even = (i % 2) == 0
        local startRadius = even and CFG.DownRayStartRadiusEven or CFG.DownRayStartRadiusOdd
        local endRadius = even and CFG.DownRayEndRadiusEven or CFG.DownRayEndRadiusOdd
        local direction = CFG.DownRayLowerOffset * -oldUp + (endRadius - startRadius) * offset
        local hit = cast(origin + startRadius * offset, direction, CFG.DownRayLength)
        if hit then
            local weight = 0.35 + 0.65 * math.abs(math.cos(theta))
            addHit(hit, weight, direction)
        end
    end

    -- Radial feelers only become transition candidates when the next face is
    -- genuinely close. This preserves normal world gravity while approaching
    -- a distant wall.
    --
    -- Stair exception: radial feelers can hit the same vertical stair riser
    -- that the dedicated stair detector is claiming. Continuous traversal
    -- ownership prevents those hits from sneaking back into gravity.
    for i = 1, CFG.FeelerCount do
        local theta = math.pi * 2 * ((i - 1) / CFG.FeelerCount)
        local rotation = CFrame.fromAxisAngle(oldUp, theta)
        local offset = rotation * radial
        local direction = safeUnit(offset * CFG.FeelerRadius - oldUp * 1.15, offset)
        local feelerOrigin = origin + offset * CFG.FeelerStartOffset + oldUp * CFG.FeelerApexOffset
        local hit = cast(feelerOrigin, direction, CFG.FeelerLength)
        if hit then
            local distance = (hit.Position - origin).Magnitude
            local hitNormal = orientSurfaceNormal(hit, direction)
            local dot = hitNormal and math.clamp(oldUp:Dot(hitNormal), -1, 1) or 1
            if distance <= CFG.SurfaceSwitchDistance and dot < CFG.SurfaceSnapDot then
                local ownedRiser = false

                if stairMoveDir then
                    ownedRiser = isOwnedStairRiserHit(hit, hitNormal, oldUp, stairMoveDir)
                end

                if not ownedRiser then
                    local weight = CFG.FeelerWeight * (0.45 + 0.55 * math.abs(math.cos(theta)))
                    addHit(hit, weight, direction)
                end
            end
        end
    end

    -- Edge detector: use short rays, not a large sphere. A large sphere can
    -- see a wall several studs ahead and falsely change gravity on an ordinary
    -- floor. These probes are only accepted inside the root's near-contact
    -- envelope, so a real edge can be caught without predicting distant faces.
    if moveVector and moveVector.Magnitude > 0.05 then
        local camera = workspace.CurrentCamera
        if camera then
            local forward = projectOnPlane(camera.CFrame.LookVector, oldUp)
            if forward.Magnitude < 0.05 then
                forward = projectOnPlane(camera.CFrame.UpVector, oldUp)
            end
            forward = safeUnit(forward, root.CFrame.LookVector)
            local right = safeUnit(forward:Cross(oldUp), root.CFrame.RightVector)
            forward = safeUnit(oldUp:Cross(right), forward)
            local moveDir = right * moveVector.X + forward * (-moveVector.Z)

            if moveDir.Magnitude > 0.05 then
                moveDir = moveDir.Unit
                local probeOrigin = origin + moveDir * 0.55
                local probes = {
                    moveDir,
                    safeUnit(moveDir - oldUp * 0.65, moveDir),
                    safeUnit(moveDir + oldUp * 0.65, moveDir),
                }

                for _, direction in ipairs(probes) do
                    local hit = cast(probeOrigin, direction, 2.15)
                    if hit then
                        local distance = (hit.Position - origin).Magnitude
                        local hitNormal = orientSurfaceNormal(hit, direction)
                        if hitNormal then
                            local dot = math.clamp(oldUp:Dot(hitNormal), -1, 1)
                            local floorOrCeiling = math.abs(oldUp:Dot(UP)) > 0.985
                            local verticalFace = math.abs(hitNormal:Dot(UP)) < CFG.TransitionWallDot
                            local allowed = distance <= 2.25 and dot < 0.65
                            -- On ordinary floor or ceiling, a short vertical riser is not a
                            -- gravity surface. Let the dedicated tall-wall test
                            -- below decide whether this is a real wall.
                            if floorOrCeiling and verticalFace then
                                allowed = false
                            end

                            local stairHit = false
                            if allowed and stairMoveDir then
                                stairHit = isOwnedStairRiserHit(hit, hitNormal, oldUp, stairMoveDir)
                            end

                            if allowed and not stairHit and distance < transitionDistance then
                                transitionDistance = distance
                                transitionNormal = hitNormal
                            end
                        end
                    end
                end
            end
        end
    end

    -- Dedicated movement-facing probes. This is intentionally separate from
    -- the radial feelers: walking directly into a wall must be enough to
    -- acquire it, even when none of the circular feelers happens to line up
    -- with the wall face.
    --
    -- v35 ownership rule: a transition candidate is only a CANDIDATE until
    -- more than one independent probe sees the same face normal. This makes
    -- the logic symmetric on floor, wall and ceiling: a one-ray micro-riser
    -- can be detected, but it cannot own gravity. A real wall/ceiling face is
    -- broad enough to be seen by multiple offsets in the same frame.
    if moveVector and moveVector.Magnitude > 0.05 then
        local camera = workspace.CurrentCamera
        if camera then
            local forward = projectOnPlane(camera.CFrame.LookVector, oldUp)
            if forward.Magnitude < 0.05 then
                forward = projectOnPlane(camera.CFrame.UpVector, oldUp)
            end
            forward = safeUnit(forward, root.CFrame.LookVector)
            local right = safeUnit(forward:Cross(oldUp), root.CFrame.RightVector)
            forward = safeUnit(oldUp:Cross(right), forward)
            local moveDir = right * moveVector.X + forward * (-moveVector.Z)
            if moveDir.Magnitude > 0.05 then
                moveDir = moveDir.Unit

                local offsets = {
                    ZERO,
                    oldUp * CFG.TransitionProbeHeight,
                    -oldUp * CFG.TransitionProbeHeight,
                    right * CFG.TransitionProbeSide,
                    -right * CFG.TransitionProbeSide,
                }

                local directions = {
                    moveDir,
                    safeUnit(moveDir + oldUp * 0.72, moveDir),
                    safeUnit(moveDir - oldUp * 0.72, moveDir),
                }

                local candidates = {}

                local function registerCandidate(hit, hitNormal, distance, offsetIndex)
                    if stairMoveDir then
                        local ownedRiser = isOwnedStairRiserHit(hit, hitNormal, oldUp, stairMoveDir)
                        if ownedRiser then
                            return
                        end
                    end

                    local normalDot = math.clamp(oldUp:Dot(hitNormal), -1, 1)
                    local floorOrCeiling = math.abs(oldUp:Dot(UP)) > 0.985
                    local verticalFace = math.abs(hitNormal:Dot(UP)) < CFG.TransitionWallDot
                    local isDifferentSurface = normalDot < CFG.TransitionNormalDot
                    if not isDifferentSurface then return end

                    -- Merge only normals that are effectively the same physical
                    -- face. We never average them; one real hit remains the
                    -- representative exact normal for the winning cluster.
                    local bestCluster
                    for _, cluster in ipairs(candidates) do
                        if cluster.normal:Dot(hitNormal) >= 0.965 then
                            bestCluster = cluster
                            break
                        end
                    end

                    if not bestCluster then
                        bestCluster = {
                            normal = hitNormal,
                            bestNormal = hitNormal,
                            bestHit = hit,
                            bestDistance = distance,
                            offsets = {},
                            upper = false,
                            lower = false,
                            vertical = verticalFace,
                        }
                        table.insert(candidates, bestCluster)
                    end

                    bestCluster.offsets[offsetIndex] = true
                    if distance < bestCluster.bestDistance then
                        bestCluster.bestDistance = distance
                        bestCluster.bestNormal = hitNormal
                        bestCluster.bestHit = hit
                    end

                    if floorOrCeiling and verticalFace then
                        local heightOffset = offsets[offsetIndex]:Dot(oldUp)
                        if heightOffset > 0.5 then
                            bestCluster.upper = true
                        elseif heightOffset < -0.5 then
                            bestCluster.lower = true
                        end
                    end
                end

                for offsetIndex, offset in ipairs(offsets) do
                    for _, direction in ipairs(directions) do
                        local hit = cast(origin + offset, direction, CFG.TransitionProbeLength)
                        if hit then
                            local distance = (hit.Position - origin).Magnitude
                            local hitNormal = orientSurfaceNormal(hit, direction)
                            if hitNormal then
                                registerCandidate(hit, hitNormal, distance, offsetIndex)
                            end
                        end
                    end
                end

                local floorOrCeiling = math.abs(oldUp:Dot(UP)) > 0.985
                local chosenCluster
                for _, cluster in ipairs(candidates) do
                    local sampleCount = 0
                    for _ in pairs(cluster.offsets) do
                        sampleCount += 1
                    end

                    local confirmed
                    if floorOrCeiling and cluster.vertical then
                        -- Keep the floor/ceiling safety from v33/v34: a vertical
                        -- face coming from a plane must occupy both the upper and
                        -- lower probe heights to be a real wall, not a tiny lip.
                        confirmed = (not CFG.SurfaceWallTwoHeightConfirmation)
                            or (cluster.upper and cluster.lower)
                    else
                        confirmed = sampleCount >= CFG.TransitionConfirmSamples
                    end

                    -- A confirmed stair riser is an obstacle to climb, not a
                    -- new gravity plane. Let the stair solver handle its height
                    -- instead of allowing the transition sensor to rotate the
                    -- character onto the riser. Real walls still pass normally.
                    local stairRiser = false
                    if confirmed and floorOrCeiling and cluster.vertical then
                        stairRiser = stairRiserAhead
                    end

                    if confirmed and not stairRiser
                        and (not chosenCluster
                            or cluster.bestDistance < chosenCluster.bestDistance)
                    then
                        chosenCluster = cluster
                    end
                end

                if chosenCluster then
                    transitionNormal = chosenCluster.bestNormal
                    transitionDistance = chosenCluster.bestDistance
                end
            end
        end
    end

    -- If a dedicated movement probe did not explicitly claim the edge, use
    -- the exact local support-face sensor. It samples a 3D hemisphere around
    -- -currentUp, so it works on both the inner and outer side of the same
    -- polygon. The result is one collision normal, never an average.
    if not transitionNormal and oldUp:Dot(UP) < 0.985 then
        local exactNormal, exactHit, exactDistance = getExactSupportFace(oldUp, moveVector)
        if exactNormal and exactDistance <= CFG.FaceProbeMaxSupportDistance then
            local supportDot = math.clamp(oldUp:Dot(exactNormal), -1, 1)
            local exactIsStair = false

            if stairMoveDir and exactHit then
                exactIsStair = isOwnedStairRiserHit(exactHit, exactNormal, oldUp, stairMoveDir)
            end

            if supportDot >= CFG.ExactFaceSupportMinDot and not exactIsStair then
                -- The exact-face probe is part of the normal WallWalk
                -- acquisition path too, so it must count as valid support for
                -- the safety handoff when the broader fan happens to miss.
                supportSeen = true
                return safeUnit(exactNormal, oldUp), true, supportSeen, supportPoint, supportNormal, supportDistance
            end
        end
    end

    if transitionNormal then
        -- A true movement-facing hit has priority. Stair risers have already
        -- been filtered against the cached physical stair geometry above.
        return safeUnit(transitionNormal, oldUp), true, supportSeen, supportPoint, supportNormal, supportDistance
    end

    if hitWeight > 0 and normalSum.Magnitude > 1e-5 then
        local candidate = normalSum.Unit
        local nearEnough = closestDistance <= CFG.SurfaceSwitchDistance
        local closestDot = closestNormal and math.clamp(oldUp:Dot(closestNormal), -1, 1) or 1
        local changed = candidate:Dot(oldUp) < CFG.GravitySwitchDot
        local strongSurface = closestNormal and closestDot < CFG.SurfaceSnapDot

        -- FACE-LOCKED SURFACE POLICY:
        -- Once a real support face is close enough, its actual collision
        -- normal is authoritative. Do not let the multi-ray average produce
        -- a diagonal normal between two faces of a polygon/hexagon. This is
        -- especially important while crossing repeated 60-degree facets.
        -- The normal is still taken from the closest physical hit, so a flat
        -- face remains exactly flat and an adjacent face becomes exactly its
        -- own normal as soon as it becomes the nearest support face.
        if nearEnough and closestNormal then
            candidate = safeUnit(closestNormal, candidate)
            changed = candidate:Dot(oldUp) < CFG.GravitySwitchDot
            strongSurface = candidate:Dot(oldUp) < CFG.SurfaceContactSnapDot
        end
        return candidate, (nearEnough and (changed or strongSurface)), supportSeen, supportPoint, supportNormal, supportDistance
    end

    return oldUp, false, supportSeen, supportPoint, supportNormal, supportDistance
end

local function getGrounded(up)
    if not root then return false end
    local hit = cast(root.Position, -up, CFG.GroundProbeLength)
    if not hit then return false end
    local normal = orientSurfaceNormal(hit, -up)
    if not normal then return false end
    local slopeLimit = math.cos(math.rad(CFG.GroundSlopeAngle))
    return up:Dot(normal) >= slopeLimit
end

local function getActualSurfaceContact(up)
    if not root then return false end

    -- GroundProbeLength is intentionally long for surface acquisition, but it
    -- is too long to decide whether a jump has actually landed. During a wall
    -- jump the wall can remain inside that long ray even while the character
    -- is several studs away. Use a short contact envelope for jump landing.
    local hip = humanoid and humanoid.HipHeight or 2
    local contactLength = math.max(2.35, hip + 0.55)
    local hit = cast(root.Position, -up, contactLength)
    if not hit then return false end

    local normal = orientSurfaceNormal(hit, -up)
    if not normal then return false end
    local distance = math.abs((root.Position - hit.Position):Dot(normal))
    local slopeLimit = math.cos(math.rad(CFG.GroundSlopeAngle))
    return distance <= contactLength
        and up:Dot(normal) >= slopeLimit
end

-- Consistent tangent basis. Roblox PlayerModule's MoveVector uses X for
-- right/left and negative Z for forward/back, so the mapping below is kept
-- identical on floor, wall and ceiling.
local function getWorldMove(moveVector, up)
    if moveVector.Magnitude <= 0.05 then return ZERO end

    local camera = workspace.CurrentCamera
    if not camera then return ZERO end

    local forward = projectOnPlane(camera.CFrame.LookVector, up)

    -- Looking directly into the surface makes LookVector unusable. In that
    -- case use camera UpVector, with the sign chosen from the camera view.
    if forward.Magnitude < 0.05 then
        local cameraUp = projectOnPlane(camera.CFrame.UpVector, up)
        if cameraUp.Magnitude > 0.05 then
            forward = cameraUp
        else
            forward = projectOnPlane(root.CFrame.LookVector, up)
        end
    end

    forward = safeUnit(forward, Vector3.zAxis)
    local right = safeUnit(forward:Cross(up), Vector3.xAxis)
    forward = safeUnit(up:Cross(right), forward)

    local world = right * moveVector.X + forward * (-moveVector.Z)
    if world.Magnitude <= 1e-5 then return ZERO end
    return world.Unit * math.clamp(Vector2.new(moveVector.X, moveVector.Z).Magnitude, 0, 1)
end

local function getMicroStepRampMove(worldMove, up, dt)
    -- The important distinction here is between GRAVITY ownership and the
    -- PATH used to reach the next tiny support face. Gravity remains locked to
    -- `up`; only the commanded locomotion path temporarily follows a short,
    -- low-angle ramp between the current and next support planes.
    if not customActive or not root or not humanoid or worldMove.Magnitude < 0.05 then
        microStepTargetBlend = 0
        microStepBlend += (microStepTargetBlend - microStepBlend)
            * (1 - math.exp(-CFG.MicroStepBlendResponse * dt))
        if microStepBlend < 0.01 then
            microStepMove = ZERO
        end
        return worldMove, false
    end

    local moveDir = safeUnit(projectOnPlane(worldMove, up), worldMove.Unit)
    local side = safeUnit(moveDir:Cross(up), root.CFrame.RightVector)
    local hip = humanoid.HipHeight > 0 and humanoid.HipHeight or 2
    local supportLength = math.max(CFG.AdhesionProbeLength, hip + 0.75)

    -- Sample the current support at three lateral points. Using more than one
    -- point matters on brick edges: a single ray can land on a seam and invent
    -- a height change that the rest of the character is not actually crossing.
    local baseHeights = {}
    local offsets = {-CFG.MicroStepSideOffset, 0, CFG.MicroStepSideOffset}
    for _, sideOffset in ipairs(offsets) do
        local hit = cast(root.Position + side * sideOffset, -up, supportLength)
        if hit then
            local normal = orientSurfaceNormal(hit, -up)
            if normal and up:Dot(normal) > 0.92 then
                table.insert(baseHeights, hit.Position:Dot(up))
            end
        end
    end

    if #baseHeights == 0 then
        microStepTargetBlend = 0
    else
        table.sort(baseHeights)
        local baseHeight = baseHeights[math.ceil(#baseHeights / 2)]
        local bestRise = nil
        local bestRun = nil
        local bestScore = math.huge

        -- Probe ahead at two distances. The farther probe catches the top of
        -- a short step before the capsule is already jammed into its lip; the
        -- nearer probe lets the ramp finish naturally as the character arrives.
        local lookaheads = {CFG.MicroStepLookahead * 0.72, CFG.MicroStepLookahead}
        for _, forwardDistance in ipairs(lookaheads) do
            for _, sideOffset in ipairs(offsets) do
                local topOrigin = root.Position
                    + moveDir * forwardDistance
                    + side * sideOffset
                    + up * CFG.MicroStepProbeAbove
                local hit = cast(topOrigin, -up, CFG.MicroStepProbeLength)
                if hit then
                    local normal = orientSurfaceNormal(hit, -up)
                    if normal and up:Dot(normal) > 0.965 then
                        local topHeight = hit.Position:Dot(up)
                        local rise = topHeight - baseHeight
                        local run = math.max(0.45,
                            (hit.Position - root.Position):Dot(moveDir))
                        local slope = math.deg(math.atan2(math.max(rise, 0), run))

                        if rise >= CFG.MicroStepMinRise
                            and rise <= CFG.MicroStepMaxHeight
                            and slope <= CFG.MicroStepMaxSlope
                        then
                            -- Favor the nearest consistent top face. The small
                            -- lateral penalty keeps a centerline support plane
                            -- preferred without requiring all three rays to hit.
                            local score = run + math.abs(sideOffset) * 0.12
                            if score < bestScore then
                                bestScore = score
                                bestRise = rise
                                bestRun = run
                            end
                        end
                    end
                end
            end
        end

        if bestRise and bestRun then
            local rampVector = moveDir * bestRun + up * bestRise
            local rampDirection = safeUnit(rampVector, moveDir)
            microStepMove = rampDirection
            microStepUntil = os.clock() + CFG.MicroStepHoldTime
            microStepTargetBlend = 1
        elseif os.clock() >= microStepUntil then
            microStepTargetBlend = 0
        end
    end

    microStepBlend += (microStepTargetBlend - microStepBlend)
        * (1 - math.exp(-CFG.MicroStepBlendResponse * dt))

    if microStepBlend <= 0.01 then
        microStepMove = ZERO
        return worldMove, false
    end

    local tangentMagnitude = worldMove.Magnitude
    local adjustedDirection = safeUnit(
        moveDir:Lerp(safeUnit(microStepMove, moveDir), microStepBlend),
        moveDir
    )

    return adjustedDirection * tangentMagnitude, true
end

local function decayStairStepBlend(dt)
    stairStepTargetBlend = 0
    stairStepBlend += (stairStepTargetBlend - stairStepBlend)
        * (1 - math.exp(-CFG.StairStepBlendResponse * dt))
    if stairStepBlend <= 0.01 then
        stairStepBlend = 0
        stairStepMove = ZERO
    end
end

local function getStairStepRampMove(worldMove, up, dt)
    -- This solver is only a FALLBACK after the original micro-step solver.
    -- That keeps v48.35's known-good tiny-step behavior untouched.
    if not customActive or not root or not humanoid or worldMove.Magnitude < 0.05 then
        decayStairStepBlend(dt)
        return worldMove, false
    end

    local moveDir = safeUnit(projectOnPlane(worldMove, up), worldMove.Unit)
    local side = safeUnit(moveDir:Cross(up), root.CFrame.RightVector)
    local hip = humanoid.HipHeight > 0 and humanoid.HipHeight or 2
    local supportLength = math.max(CFG.AdhesionProbeLength, hip + 0.75)

    -- Establish the current support plane from the same three-point method
    -- used by the existing micro-step solver. This keeps step height measured
    -- along WallWalk's CURRENT UP, not world Y, so the exact same detector works
    -- on floors, walls and ceilings.
    local baseSamples = {}
    local offsets = {-CFG.StairStepSideOffset, 0, CFG.StairStepSideOffset}
    for _, sideOffset in ipairs(offsets) do
        local hit = cast(root.Position + side * sideOffset, -up, supportLength)
        if hit then
            local normal = orientSurfaceNormal(hit, -up)
            if normal and up:Dot(normal) > 0.92 then
                table.insert(baseSamples, {height = hit.Position:Dot(up), point = hit.Position})
            end
        end
    end

    if #baseSamples == 0 then
        decayStairStepBlend(dt)
        return worldMove, false
    end

    table.sort(baseSamples, function(a, b) return a.height < b.height end)
    local baseSample = baseSamples[math.ceil(#baseSamples / 2)]
    local baseHeight = baseSample.height
    local basePoint = root.Position
        - up * (root.Position:Dot(up) - baseHeight)

    local bestRise
    local bestRun
    local bestScore = math.huge

    local lookaheads = {
        math.clamp(CFG.StairStepLookahead * 0.45, 0.45, CFG.StairStepLookahead),
        math.clamp(CFG.StairStepLookahead * 0.72, 0.60, CFG.StairStepLookahead),
        CFG.StairStepLookahead,
    }

    for _, forwardDistance in ipairs(lookaheads) do
        for _, sideOffset in ipairs(offsets) do
            local probeOrigin = root.Position
                + moveDir * forwardDistance
                + side * sideOffset
                + up * CFG.StairStepProbeAbove

            local hit = cast(probeOrigin, -up, CFG.StairStepProbeLength)
            if hit then
                local normal = orientSurfaceNormal(hit, -up)
                if normal and up:Dot(normal) > 0.965 then
                    local topHeight = hit.Position:Dot(up)
                    local rise = topHeight - baseHeight
                    local run = (hit.Position - root.Position):Dot(moveDir)
                    local slope = math.deg(math.atan2(math.max(rise, 0), math.max(run, 0.05)))

                    if rise >= CFG.StairStepMinRise
                        and rise <= CFG.StairStepMaxHeight
                        and run >= CFG.StairStepClearance
                        and run <= CFG.StairStepLookahead + 0.20
                        and slope <= CFG.StairStepMaxSlope
                    then
                        -- Confirm this is a DISCRETE riser. A smooth ramp should
                        -- not be claimed by the stair solver; the old micro-step
                        -- path remains responsible for low-angle continuous ramps.
                        local hasRiser = confirmStairRiser(basePoint, moveDir, side, rise, up)

                        if hasRiser then
                            -- Prefer the nearest confirmed stair top. A small
                            -- side penalty keeps centerline stairs favored while
                            -- still allowing narrow/off-center steps.
                            local score = run + math.abs(sideOffset) * 0.10
                            if score < bestScore then
                                bestScore = score
                                bestRise = rise
                                bestRun = run
                            end
                        end
                    end
                end
            end
        end
    end

    if bestRise and bestRun then
        local rampVector = moveDir * bestRun + up * bestRise
        local rampDirection = safeUnit(rampVector, moveDir)
        stairStepMove = rampDirection
        stairStepUntil = os.clock() + CFG.StairStepHoldTime
        stairStepTargetBlend = 1
    elseif os.clock() >= stairStepUntil then
        stairStepTargetBlend = 0
    end

    stairStepBlend += (stairStepTargetBlend - stairStepBlend)
        * (1 - math.exp(-CFG.StairStepBlendResponse * dt))

    if stairStepBlend <= 0.01 then
        stairStepMove = ZERO
        return worldMove, false
    end

    local tangentMagnitude = worldMove.Magnitude
    local adjustedDirection = safeUnit(
        moveDir:Lerp(safeUnit(stairStepMove, moveDir), stairStepBlend),
        moveDir
    )

    return adjustedDirection * tangentMagnitude, true
end

local function createControllers()
    if gravityForce then gravityForce:Destroy() end
    if gravityAttachment then gravityAttachment:Destroy() end
    if orientation then orientation:Destroy() end
    if orientationAttachment then orientationAttachment:Destroy() end

    if not root then return end

    gravityAttachment = Instance.new("Attachment")
    gravityAttachment.Name = "VGD_WallWalk_GravityAttachment"
    gravityAttachment.Parent = root

    gravityForce = Instance.new("VectorForce")
    gravityForce.Name = "VGD_WallWalk_Gravity"
    gravityForce.Attachment0 = gravityAttachment
    gravityForce.RelativeTo = Enum.ActuatorRelativeTo.World
    gravityForce.ApplyAtCenterOfMass = true
    gravityForce.Force = ZERO
    gravityForce.Enabled = false
    gravityForce.Parent = root

    orientationAttachment = Instance.new("Attachment")
    orientationAttachment.Name = "VGD_WallWalk_OrientationAttachment"
    orientationAttachment.Parent = root

    orientation = Instance.new("AlignOrientation")
    orientation.Name = "VGD_WallWalk_Orientation"
    orientation.Mode = Enum.OrientationAlignmentMode.OneAttachment
    orientation.AlignType = Enum.AlignType.AllAxes
    orientation.Attachment0 = orientationAttachment
    orientation.RigidityEnabled = false
    orientation.Responsiveness = CFG.OrientationResponsiveness
    orientation.MaxTorque = CFG.OrientationMaxTorque
    orientation.MaxAngularVelocity = CFG.OrientationMaxAngularVelocity
    orientation.Enabled = false
    orientation.Parent = root
end

local function isFloorUp(up)
    return up:Dot(UP) > 0.985
end

local function setControllerMode(useCustomPhysics)
    if not humanoid then return end
    if controllerPhysicsActive == useCustomPhysics then
        -- Keep the constraint enable state synchronized without repeatedly
        -- forcing Humanoid state changes every Heartbeat.
        if useCustomPhysics then
            if gravityForce then gravityForce.Enabled = true end
            if orientation then orientation.Enabled = true end
        else
            if gravityForce then gravityForce.Enabled = false end
            if orientation then orientation.Enabled = false end
        end
        return
    end

    controllerPhysicsActive = useCustomPhysics

    if useCustomPhysics then
        humanoid.AutoRotate = false
        pcall(function()
            humanoid:SetStateEnabled(Enum.HumanoidStateType.Physics, true)
            humanoid:ChangeState(Enum.HumanoidStateType.Physics)
        end)
        if gravityForce then gravityForce.Enabled = true end
        if orientation then orientation.Enabled = true end
    else
        -- On the ordinary floor, give the Humanoid its native movement,
        -- jumping and collision pipeline back. WallWalk remains ON, but it
        -- does not fight Roblox for control until a wall/ceiling is actually
        -- detected.
        if gravityForce then
            gravityForce.Force = ZERO
            gravityForce.Enabled = false
        end
        if orientation then orientation.Enabled = false end
        humanoid.AutoRotate = true
        pcall(function()
            humanoid:SetStateEnabled(Enum.HumanoidStateType.Running, true)
            humanoid:SetStateEnabled(Enum.HumanoidStateType.RunningNoPhysics, true)
            humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
            humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, true)
            humanoid:SetStateEnabled(Enum.HumanoidStateType.Landed, true)
            humanoid:ChangeState(Enum.HumanoidStateType.Running)
        end)
    end
end

local function enterCustom(up)
    targetUp = safeUnit(up, currentUp)
    if not customActive then
        filteredAdhesionDistance = nil
        microStepBlend = 0
        microStepTargetBlend = 0
        microStepUntil = 0
        microStepMove = ZERO
        stairStepBlend = 0
        stairStepTargetBlend = 0
        stairStepUntil = 0
        stairStepMove = ZERO
    end
    lastDetectedUp = targetUp
    lastSurfaceSeen = os.clock()

    if customActive then
        return
    end

    -- FLOOR -> WALL/CEILING HANDOFF:
    -- Roblox owns the character completely on ordinary floor. Only take over
    -- the Humanoid once a real non-floor surface has been detected.
    customActive = true

    if animateScript then
        animateWasDisabled = animateScript.Disabled
    end

    if humanoid then
        humanoid.AutoRotate = false
        humanoid.PlatformStand = true
        pcall(function()
            humanoid:SetStateEnabled(Enum.HumanoidStateType.Physics, true)
        end)
        pcall(function()
            humanoid:ChangeState(Enum.HumanoidStateType.Physics)
        end)
    end

    loadCharacterAnimations()

    if gravityForce then gravityForce.Enabled = true end
    if orientation then orientation.Enabled = true end
end

local function leaveCustom(forceFreefall)
    customActive = false
    filteredAdhesionDistance = nil
    microStepBlend = 0
    microStepTargetBlend = 0
    microStepUntil = 0
    microStepMove = ZERO
    stairStepBlend = 0
    stairStepTargetBlend = 0
    stairStepUntil = 0
    stairStepMove = ZERO
    clearStairTraversal()
    targetUp = UP
    currentUp = UP
    lastDetectedUp = UP

    if gravityForce then
        gravityForce.Force = ZERO
        gravityForce.Enabled = false
    end
    if orientation then orientation.Enabled = false end

    -- WALL/CEILING -> FLOOR HANDOFF:
    -- Return ownership to Roblox rather than leaving the Humanoid in Physics.
    if animateScript then
        animateScript.Disabled = animateWasDisabled
    end
    destroyAnimationTracks()

    if humanoid then
        humanoid.PlatformStand = false
        humanoid.AutoRotate = true
        pcall(function()
            humanoid:SetStateEnabled(Enum.HumanoidStateType.Physics, false)
            humanoid:SetStateEnabled(Enum.HumanoidStateType.Running, true)
            humanoid:SetStateEnabled(Enum.HumanoidStateType.RunningNoPhysics, true)
            humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
            humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, true)
            humanoid:SetStateEnabled(Enum.HumanoidStateType.Landed, true)
            humanoid:ChangeState(
                forceFreefall and Enum.HumanoidStateType.Freefall
                    or Enum.HumanoidStateType.Running
            )
        end)
    end
end

local function resetGravitySwitchBackState()
    gravitySwitchBackUp = nil
    gravitySwitchBackAt = 0
end

local function resetSafeSurfaceState()
    surfaceLostAt = 0
    gravityTransitionActive = false
    orientationTransitionUntil = 0
    transitionFacing = nil
    lastFacingDirection = nil
    transitionMoveCandidate = nil
    safetySupportPoint = nil
    safetySupportNormal = nil
    safetySupportDistance = nil
    safetySupportAt = 0

    safetyPreviousPosition = root and root.Position or nil
    safetyPreviousWorldDownSpeed = root and root.AssemblyLinearVelocity:Dot(-UP) or 0
    safetyAwayDistance = 0
    safetyAwaySpeed = 0
    safetyWorldFallSpeed = 0
    safetyWorldFallAcceleration = 0
end

-- Gravity-side anti-flip guard. A real side switch happens immediately,
-- but for 0.1s we refuse ONLY the previously-owned side. This does not delay
-- the new side and does not block switching to a third side.
local function isGravitySwitchBackBlocked(candidateUp, now)
    if not gravitySwitchBackUp then
        return false
    end

    if now - gravitySwitchBackAt >= CFG.GravitySwitchBackCooldown then
        return false
    end

    local candidate = safeUnit(candidateUp, currentUp)
    return candidate:Dot(gravitySwitchBackUp) >= CFG.GravitySwitchBackDot
end

local function commitGravitySide(newUp)
    local oldUp = safeUnit(currentUp, UP)
    local committedUp = safeUnit(newUp, oldUp)

    -- Only remember a meaningful side change. Tiny normal drift should not
    -- restart the 0.1s anti-flip window every frame.
    if oldUp:Dot(committedUp) < CFG.GravitySwitchBackDot then
        gravitySwitchBackUp = oldUp
        gravitySwitchBackAt = os.clock()

        -- Preserve the SURFACE PATH, not just a world-space LookVector.
        -- Prefer the movement direction from immediately before the surface
        -- switch; that is the heading the player is actually walking along.
        -- Then transport that direction with the exact oldUp -> newUp rotation.
        -- This is what makes a forward transition look like one continuous walk
        -- around a corner. For sideways motion, the same transport naturally
        -- keeps the direction running along the shared edge.
        local oldForward = transitionMoveCandidate
        if not oldForward or oldForward.Magnitude < 0.05 then
            oldForward = lastFacingDirection
        end
        if not oldForward or oldForward.Magnitude < 0.05 then
            oldForward = root and root.CFrame.LookVector or nil
        end

        if oldForward then
            local carried = transportDirection(oldForward, oldUp, committedUp)
            if carried.Magnitude >= 0.05 then
                transitionFacing = safeUnit(carried, oldForward)
            else
                transitionFacing = nil
            end
        else
            transitionFacing = nil
        end

        -- The gravity side changes immediately, but do not let AlignOrientation
        -- rotate the R15 assembly at an extreme one-frame angular speed. The
        -- final diagnostic showed that these large rotation steps can sweep
        -- limbs into nearby Tower geometry and produce a solver impulse that
        -- launches the character. Keep this protection local to the handoff;
        -- normal orientation speed returns automatically afterward.
        orientationTransitionUntil = os.clock() + CFG.GravityTransition
    end

    currentUp = committedUp
    return committedUp
end

local function updateSurface(dt, moveVector)
    if not root then return end

    -- Once the safety handoff has returned control to Roblox gravity, do not
    -- immediately reacquire the last wall/ceiling from the previous frame.
    -- Stay in native gravity until the character is actually grounded again.
    if safetyReleased then
        if getGrounded(UP) then
            safetyReleased = false
            currentUp = UP
            targetUp = UP
            lastDetectedUp = UP
            lastSurfaceSeen = os.clock()
            resetSafeSurfaceState()
        else
            return
        end
    end

    local detected, surfaceCandidate, supportSeen, supportPoint, supportNormal, supportDistance = getGravityUp(currentUp, moveVector)
    surfaceSupportSeen = supportSeen == true
    surfaceSupportPoint = supportPoint
    surfaceSupportNormal = supportNormal
    surfaceSupportDistance = supportDistance
    local detectionDot = math.clamp(currentUp:Dot(detected), -1, 1)

    -- MICRO-SURFACE DEAD BAND:
    -- A brick seam, tiny bevel or 1cm step can produce a perfectly valid
    -- collision normal that is nevertheless too small to deserve a new
    -- gravity plane. Keep the currently-owned plane in that case.
    --
    -- This is intentionally angular, not a generic smoothing filter: a real
    -- polygon/hexagon face (for example 30/45/60/90 degrees away) still
    -- snaps immediately and remains exact.
    local microAngleDot = math.cos(math.rad(CFG.MicroSurfaceAngle))
    local microSurfaceChange = detectionDot >= microAngleDot
    local strongChange = detectionDot < CFG.StrongSwitchDot
    local meaningfulChange = detectionDot < CFG.GravitySwitchDot
    local grounded = getGrounded(currentUp)
    local switchBackBlocked = isGravitySwitchBackBlocked(detected, os.clock())

    if customActive and surfaceCandidate and microSurfaceChange then
        -- Do not let a tiny support-normal fluctuation rotate gravity. We still
        -- keep the confirmed support/contact sensor active for adhesion.
        detected = currentUp
        detectionDot = 1
        strongChange = false
        meaningfulChange = false
    end

    -- A real macro surface change means gravity ownership is changing.
    -- Arm the transition guard BEFORE the existing ownership logic. This is
    -- intentionally the only new input to the safety system; all normal
    -- support detection remains exactly the v48.27 path.
    if customActive and surfaceCandidate and not microSurfaceChange
        and (strongChange or meaningfulChange)
        and not switchBackBlocked
    then
        gravityTransitionActive = true
    end

    if not customActive then
        -- On the ordinary floor, DO NOT enter custom mode merely because the
        -- controller is ON. Roblox must keep native walking/jumping here.
        -- We only take over when the sensor sees a genuinely different surface.
        local nonFloor = detected:Dot(UP) < 0.985
        if surfaceCandidate and nonFloor and (strongChange or meaningfulChange)
            and not switchBackBlocked
        then
            enterCustom(detected)
            commitGravitySide(detected)
        elseif not grounded then
            -- If we are airborne from a normal Roblox jump, don't hijack it.
            -- A wall/ceiling must be detected independently before takeover.
            return
        else
            currentUp = UP
            targetUp = UP
            return
        end
    else
        -- If the detector has reached the ordinary floor again, immediately
        -- hand the Humanoid back to Roblox. Do this BEFORE the generic
        -- surfaceCandidate branch so a floor normal cannot keep the custom
        -- controller alive indefinitely.
        if detected:Dot(UP) > 0.985 and currentUp:Dot(UP) < 0.985
            and not switchBackBlocked
        then
            commitGravitySide(UP)
            leaveCustom()
            return
        elseif surfaceCandidate and (strongChange or meaningfulChange)
            and not switchBackBlocked
        then
            enterCustom(detected)
            -- A confirmed close support face is already the exact collision
            -- normal. Snap immediately instead of blending through a tilted
            -- intermediate gravity vector.
            commitGravitySide(detected)
        elseif grounded and currentUp:Dot(UP) > 0.985 then
            leaveCustom()
            return
        elseif os.clock() - lastSurfaceSeen < 0.22 then
            -- Keep the last confirmed surface through brief raycast gaps.
            -- Losing one frame of contact must never hand gravity back to the
            -- world, or wall/ceiling movement immediately falls away.
            enterCustom(lastDetectedUp)
        else
            -- IMPORTANT: a temporary sensor miss is NOT a floor transition.
            -- Keep the custom gravity/orientation owner until an actual floor
            -- normal is positively detected. This provides hysteresis at
            -- corners and prevents the old 0.22s gravity-drop failure.
            return
        end
    end

    if not customActive then return end

    if surfaceCandidate and not switchBackBlocked then
        -- Confirmed macro face: no interpolation. This is what makes each
        -- hexagon facet behave as a true gravity plane instead of a slanted
        -- blend. Micro faces were filtered above and therefore cannot chatter
        -- the gravity vector while crossing brick-sized surface detail.
        commitGravitySide(detected)
        targetUp = currentUp
        lastDetectedUp = currentUp
        lastSurfaceSeen = os.clock()
    else
        local blend = 1 - math.exp(-CFG.GravityTransition * dt * 60)
        currentUp = safeUnit(currentUp:Lerp(targetUp, blend), currentUp)
    end
end

local function getSafetySupport()
    if not root then return false, nil, nil, math.huge end

    local origin = root.Position
    local up = safeUnit(currentUp, UP)

    -- IMPORTANT:
    -- Safety is about REAL NEAR-CONTACT with the currently owned surface.
    -- A long probe can still hit the old wall after the character has already
    -- detached and started falling through open space, which makes the safety
    -- timer believe WallWalk is supported forever.
    --
    -- Keep the fan wide enough to survive seams/brick gaps, but keep its
    -- normal distance close to the same envelope used by the adhesion solver.
    local supportLength = math.min(
        CFG.SurfaceSafetyProbeLength,
        CFG.AdhesionProbeLength + 0.40,
        CFG.SurfaceSafetySupportDistance + 0.35
    )

    local tangentA = projectOnPlane(root.CFrame.RightVector, up)
    tangentA = safeUnit(tangentA, safeUnit(up:Cross(root.CFrame.LookVector), Vector3.xAxis))
    local tangentB = safeUnit(tangentA:Cross(up), root.CFrame.LookVector)
    tangentB = safeUnit(projectOnPlane(tangentB, up), Vector3.zAxis)

    -- Five nearby support probes. The center probe is authoritative when it
    -- sees the owned face; the four small offsets make brief seam misses
    -- harmless without turning a distant surface into "support".
    local offsets = {
        ZERO,
        tangentA * CFG.SurfaceSafetyFanRadius,
        -tangentA * CFG.SurfaceSafetyFanRadius,
        tangentB * CFG.SurfaceSafetyFanRadius,
        -tangentB * CFG.SurfaceSafetyFanRadius,
    }

    local bestHit
    local bestNormal
    local bestDistance = math.huge

    for _, offset in ipairs(offsets) do
        local probeOrigin = origin + offset
        local hit = cast(probeOrigin, -up, supportLength)
        if hit then
            local normal = orientSurfaceNormal(hit, -up)
            if normal and up:Dot(normal) >= CFG.SurfaceSafetySupportNormalDot then
                local distance = math.abs((probeOrigin - hit.Position):Dot(normal))
                if distance <= CFG.SurfaceSafetySupportDistance
                    and distance < bestDistance
                then
                    bestHit = hit
                    bestNormal = normal
                    bestDistance = distance
                end
            end
        end
    end

    if not bestHit then
        return false, nil, nil, math.huge
    end

    return true, bestHit.Position, bestNormal, bestDistance
end

local function checkSurfaceSafety(dt, moveVector)
    if not customActive or not root or isFloorUp(currentUp) then
        resetSafeSurfaceState()
        return false
    end

    dt = math.max(tonumber(dt) or (1 / 60), 1 / 240)

    local now = os.clock()
    local up = safeUnit(currentUp, UP)

    -- v48.25: use the support result produced by the SAME multi-ray surface
    -- scan that updateSurface() just ran. Do not run a separate fan here.
    -- The scan already distinguishes a currently-owned face from distant
    -- transition candidates by requiring an aligned hit inside the adhesion
    -- envelope. This keeps stable wall/ceiling support alive without letting
    -- a long look-ahead ray extend the handoff timer.
    local supportSeen = surfaceSupportSeen
    local supportPoint = surfaceSupportPoint
    local supportNormal = surfaceSupportNormal
    local supportDistance = surfaceSupportDistance

    -- If the player is actively moving away from the last owned face, do not
    -- wait for the angled multi-ray scan to stop seeing that face. This is the
    -- exact moment the safety timer should begin. Tangential wall movement does
    -- not trigger this because the displacement is measured along currentUp.
    if not supportSeen and safetySupportPoint and safetySupportNormal then
        local separation = (root.Position - safetySupportPoint):Dot(safetySupportNormal)
        if separation > CFG.SurfaceSafetyAwayDistance then
            supportSeen = false
        end
    end

    if supportSeen then
        surfaceLostAt = 0
        safetySupportPoint = supportPoint
        safetySupportNormal = supportNormal
        safetySupportDistance = supportDistance
        safetySupportAt = now
        safetyAwayDistance = 0
        safetyAwaySpeed = 0
        safetyWorldFallSpeed = 0
        safetyWorldFallAcceleration = 0

        -- The transition is complete only when the normal support sensor sees
        -- the currently-owned gravity plane again. This keeps the guard from
        -- becoming a permanent grace state.
        if gravityTransitionActive
            and supportNormal
            and up:Dot(safeUnit(supportNormal, up)) >= CFG.SurfaceSafetySupportNormalDot
        then
            gravityTransitionActive = false
        end

        return false
    end

    -- During a confirmed gravity-plane handoff, do not allow the normal 0.2s
    -- support-loss timer to cancel WallWalk while AlignOrientation is still
    -- physically rotating the character onto the new gravity plane.
    --
    -- IMPORTANT: this is completion-based, not time-based. A slow/laggy frame,
    -- a large corner rotation, or a heavy character must not be treated as a
    -- failed transition merely because 0.2s elapsed. The transition guard
    -- ends when the new support face is actually detected, using the existing
    -- support sensor. If the new face has not been positively reacquired yet
    -- but the character body is still physically rotating, keep waiting. Once
    -- the body has caught up to currentUp without support, the transition is
    -- genuinely over and the normal safety timer is allowed to run.
    if gravityTransitionActive then
        local bodyUp = safeUnit(root.CFrame.UpVector, up)
        local bodyAligned = bodyUp:Dot(up) >= CFG.SurfaceSafetySupportNormalDot

        if not bodyAligned then
            surfaceLostAt = 0
            return false
        end

        -- The target gravity plane has been reached physically, but the safety
        -- sensor has not reacquired supporting geometry. At this point there is
        -- no longer a transition in progress, so fall-back safety may resume.
        gravityTransitionActive = false
    end

    -- Jump-specific safety handling:
    -- Losing the launch surface is expected for the entire airborne portion of
    -- a wall/ceiling jump. Do NOT resume the 0.2s safety timer at the apex:
    -- a static jump reaches an apex before returning to its launch wall.
    --
    -- The jump grace phase ends only when the character has crossed back
    -- through the actual launch-surface plane. If another valid surface was
    -- not reacquired by then, the existing 0.2s safety timer can hand control
    -- back to Roblox gravity.
    if jumped then
        local launchUp = safeUnit(jumpLaunchUp, up)

        if jumpLaunchPosition then
            local launchOffset = (root.Position - jumpLaunchPosition):Dot(launchUp)

            if not jumpLaunchPlaneCrossed then
                if launchOffset <= 0.10 then
                    jumpLaunchPlaneCrossed = true
                else
                    surfaceLostAt = 0
                    return false
                end
            end
        else
            -- Defensive fallback: never let a missing launch position make a
            -- stale jump state trigger safety immediately.
            surfaceLostAt = 0
            return false
        end
    end

    if surfaceLostAt <= 0 then
        surfaceLostAt = now
        return false
    end

    if now - surfaceLostAt < CFG.SurfaceSafetyDelay then
        return false
    end

    -- Continuous loss for the full delay: release custom gravity and let
    -- Roblox take over. No teleport and no saved-position recovery.
    surfaceLostAt = 0
    safetyReleased = true
    safetySupportPoint = nil
    safetySupportNormal = nil
    safetySupportDistance = nil
    safetySupportAt = 0
    safetyAwayDistance = 0
    safetyAwaySpeed = 0

    -- If this handoff happens after a wall/ceiling jump never found another
    -- surface, the WallWalk jump lifecycle is over as well. Clear it before
    -- returning to Roblox gravity so the next wall contact cannot inherit a
    -- stale jump lock or launch direction.
    jumped = false
    jumpLaunchUp = UP
    jumpLaunchPosition = nil
    jumpLaunchPlaneCrossed = false
    jumpLocked = false

    leaveCustom(true)
    return true
end

local function updateGravityAndMovement(dt, worldMove, microStepActive)
    if not root or not gravityForce or not customActive then return end

    local mass = root.AssemblyMass
    if mass <= 0 then return end

    local gravity = CFG.Gravity
    local velocity = root.AssemblyLinearVelocity
    local normalVelocity = velocity:Dot(currentUp)
    local tangentVelocity = velocity - normalVelocity * currentUp
    local desired = CFG.WalkSpeed * worldMove
    local delta = desired - tangentVelocity

    local force = gravity * mass * (UP - currentUp)

    if delta.Magnitude > 0.001 then
        -- Apply acceleration-like steering instead of an oversized per-frame
        -- force. This makes starts/stops feel much closer to Roblox movement.
        local acceleration = math.min(CFG.MaxWalkForce / math.max(mass, 1),
            CFG.WalkForce * delta.Magnitude)
        force += delta.Unit * acceleration * mass
    end

    local hit = cast(root.Position, -currentUp, CFG.AdhesionProbeLength)
    local surfaceNormal = hit and orientSurfaceNormal(hit, -currentUp)
    local normalSpeed = velocity:Dot(currentUp)
    local groundedNow = surfaceNormal and currentUp:Dot(surfaceNormal) > 0.92 and normalSpeed <= 1.5
    if groundedNow and not jumped and not justLanded and (not CFG.WallAdhesionOnly or currentUp:Dot(UP) < 0.985) then
        -- MICRO-BUMP STABILITY:
        -- Keep the support measurement smooth, but do NOT directly rewrite
        -- AssemblyLinearVelocity every frame. Roblox documents VectorForce as
        -- the preferred continuous force controller, while direct velocity
        -- writes can produce unrealistic motion. The step ramp above now gives
        -- the solver a legitimate path instead of fighting the collision.
        local distance = math.abs((root.Position - hit.Position):Dot(currentUp))
        if filteredAdhesionDistance == nil then
            filteredAdhesionDistance = distance
        else
            local distanceDelta = distance - filteredAdhesionDistance
            if math.abs(distanceDelta) <= CFG.MicroSurfaceDistance then
                local alpha = 1 - math.exp(-CFG.MicroAdhesionResponse * dt)
                filteredAdhesionDistance += distanceDelta * alpha
            else
                filteredAdhesionDistance = distance
            end
        end

        -- While the commanded movement is temporarily following a tiny ramp,
        -- gravity + collision provide the normal support. Applying the spring
        -- at the same time would create two competing normal controllers at
        -- the exact lip where the jitter occurs.
        if not microStepActive then
            local targetDistance = humanoid.HipHeight
            local error = filteredAdhesionDistance - targetDistance
            local correction = math.clamp(
                error * CFG.AdhesionStrength - normalSpeed * CFG.AdhesionDamping,
                -24,
                24
            )
            force += -currentUp * correction * mass
        end
    else
        filteredAdhesionDistance = nil
    end

    gravityForce.Force = force
end

local function updateOrientation(worldMove)
    if not orientation or not customActive or not root then return end

    local facing
    local inFacingTransition = os.clock() < orientationTransitionUntil and transitionFacing

    if inFacingTransition then
        -- During the side handoff, keep the transported surface-path heading.
        -- It has already been rotated together with the gravity frame, so do
        -- not replace it with camera movement until the handoff is complete.
        facing = projectOnPlane(transitionFacing, currentUp)
    else
        -- Once the handoff is finished, return to the normal camera/movement
        -- facing behavior that existed before this polish change.
        facing = projectOnPlane(worldMove, currentUp)
        if facing.Magnitude < 0.05 then
            facing = projectOnPlane(root.CFrame.LookVector, currentUp)
        end
    end

    if facing.Magnitude < 0.05 then
        facing = projectOnPlane(root.CFrame.LookVector, currentUp)
    end
    facing = safeUnit(facing, Vector3.zAxis)

    -- Keep the actual heading produced by this frame available to the next
    -- surface transition. This is better than sampling root.CFrame.LookVector,
    -- which can lag behind the intended movement heading during a handoff.
    lastFacingDirection = facing

    local right = safeUnit(facing:Cross(currentUp), root.CFrame.RightVector)
    local correctedForward = safeUnit(currentUp:Cross(right), facing)

    orientation.Responsiveness = currentUp:Dot(Vector3.yAxis) > 0.985
        and CFG.FloorOrientationResponsiveness
        or CFG.OrientationResponsiveness

    -- Cap only the transition handoff. The target/current gravity side still
    -- commits immediately; this changes only how fast the physical assembly
    -- is allowed to rotate toward that target.
    orientation.MaxAngularVelocity = os.clock() < orientationTransitionUntil
        and CFG.TransitionMaxAngularVelocity
        or CFG.OrientationMaxAngularVelocity

    orientation.CFrame = CFrame.fromMatrix(Vector3.zero, right, currentUp, -correctedForward)
end

local cameraBaseCFrame
local cameraBaseUp
local cameraOffsetY = 0

local function updateCameraStabilization(dt)
    if destroyed then return end
    local camera = workspace.CurrentCamera
    if not camera or not humanoid or not root then return end

    -- Never replace Roblox's camera controller. We only remove tiny vertical
    -- physics chatter while WallWalk is active on the normal floor.
    if not enabled or not customActive or currentUp:Dot(Vector3.yAxis) < 0.985 then
        cameraBaseCFrame = nil
        cameraOffsetY = 0
        return
    end

    local normalSpeed = root.AssemblyLinearVelocity:Dot(currentUp)
    local targetOffset = math.clamp(normalSpeed * 0.018, -0.22, 0.22)
    local alpha = 1 - math.exp(-12 * dt)
    cameraOffsetY += (targetOffset - cameraOffsetY) * alpha

    -- CameraOffset is applied by Roblox's normal camera scripts, so this
    -- keeps mouse/joystick orbit, zoom, occlusion and camera collision intact.
    humanoid.CameraOffset = Vector3.new(0, -cameraOffsetY, 0)
end

local function resetCameraStabilization()
    cameraOffsetY = 0
    if humanoid then
        humanoid.CameraOffset = Vector3.zero
    end
    cameraBaseCFrame = nil
    cameraBaseUp = nil
end

local function setEmoteStateBridge(active)
    -- Emotes are handled through Animate.PlayEmote below.
    -- Never leave WallWalk Physics just because the emote wheel is open.
    emoteStateBridge = false
end

local function updateEmoteStateBridge()
    -- Intentionally a no-op. WallWalk must remain in custom Physics while
    -- the Roblox emote menu is open; switching to Running makes the normal
    -- world controller fight the custom wall/ceiling gravity.
    emoteMenuOpen = false
    emoteStateRestoreAt = 0
    emoteStateBridge = false
end

local function enforceRagdollProtection()
    if not humanoid then return end

    -- WallWalk may use the Humanoid Physics state internally, but Ragdoll and
    -- FallingDown are never valid controller states. Disable those states so
    -- an external/default humanoid state transition cannot turn the rig limp
    -- while the custom gravity controller is active.
    pcall(function()
        humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
        humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
    end)

    local state = humanoid:GetState()
    if state == Enum.HumanoidStateType.Ragdoll or state == Enum.HumanoidStateType.FallingDown then
        pcall(function()
            humanoid:ChangeState(customActive and Enum.HumanoidStateType.Physics or Enum.HumanoidStateType.Running)
        end)
    end
end

local function getJumpSurfaceSupport(up)
    if not root then return false end
    if getActualSurfaceContact(up) then return true end

    -- WallWalk deliberately keeps a small adhesion gap. This support check is
    -- only for jump eligibility / landing unlock, never for surface acquisition.
    local supportLength = math.max(3.45, CFG.AdhesionProbeLength + 0.70)
    local hit = cast(root.Position, -up, supportLength)
    if not hit then return false end

    local normal = orientSurfaceNormal(hit, -up)
    return normal and up:Dot(normal) >= 0.80
end

local function requestJump()
    if not enabled then return end

    -- JumpRequest can fire more than once for one physical press (especially
    -- on mobile). Use a very short event debounce rather than a persistent
    -- latch. The old latch could remain stuck after the first jump, which
    -- forced an OFF/ON cycle before another jump was accepted.
    local now = os.clock()
    if now - lastJumpRequestAt < 0.12 then return end
    lastJumpRequestAt = now

    if customActive and jumpLocked then return end
    jumpRequested = true
end

local function performJump()
    if not customActive or not root or not humanoid then return end
    if os.clock() - lastJump < CFG.JumpCooldown then return end
    if jumpLocked then return end

    -- Jump eligibility is intentionally a little more forgiving than the
    -- landing detector. The controller keeps a small adhesion gap from walls
    -- and ceilings, so the strict contact ray can miss even though the player
    -- is genuinely attached to the current surface.
    if not getJumpSurfaceSupport(currentUp) then return end

    lastJump = os.clock()
    jumpStartedAt = lastJump
    jumpLaunchUp = safeUnit(currentUp, UP)
    jumpLaunchPosition = root.Position
    jumpLaunchPlaneCrossed = false
    jumped = true
    jumpLocked = true

    local velocity = root.AssemblyLinearVelocity
    local tangent = projectOnPlane(velocity, currentUp)
    local jumpPower = humanoid.UseJumpPower and humanoid.JumpPower or CFG.JumpSpeed
    local jumpSpeed = jumpPower * CFG.JumpModifier

    root.AssemblyLinearVelocity = tangent + currentUp * jumpSpeed
end

local function captureOriginalCharacterState()
    if not humanoid then return end

    originalState.valid = true
    originalState.animateDisabled = animateWasDisabled
    originalState.autoRotate = humanoid.AutoRotate
    originalState.platformStand = humanoid.PlatformStand
    originalState.walkSpeed = humanoid.WalkSpeed
    originalState.cameraOffset = humanoid.CameraOffset

    local states = {
        {"ragdollEnabled", Enum.HumanoidStateType.Ragdoll},
        {"fallingDownEnabled", Enum.HumanoidStateType.FallingDown},
        {"physicsEnabled", Enum.HumanoidStateType.Physics},
        {"runningEnabled", Enum.HumanoidStateType.Running},
        {"runningNoPhysicsEnabled", Enum.HumanoidStateType.RunningNoPhysics},
        {"jumpingEnabled", Enum.HumanoidStateType.Jumping},
        {"freefallEnabled", Enum.HumanoidStateType.Freefall},
        {"landedEnabled", Enum.HumanoidStateType.Landed},
    }
    for _, item in ipairs(states) do
        local ok, value = pcall(function()
            return humanoid:GetStateEnabled(item[2])
        end)
        if ok then originalState[item[1]] = value end
    end

    local animate = character and character:FindFirstChild("Animate")
    local playEmote = animate and animate:FindFirstChild("PlayEmote")
    if playEmote and playEmote:IsA("BindableFunction") then
        local ok, callback = pcall(function() return playEmote.OnInvoke end)
        if ok then
            originalState.emoteOnInvoke = callback
            originalState.emoteCaptured = true
        end
    end
end

local function restoreOriginalCharacterState()
    if not originalState.valid or not humanoid then return end

    if animateScript then
        animateScript.Disabled = originalState.animateDisabled
    end
    humanoid.AutoRotate = originalState.autoRotate
    humanoid.PlatformStand = originalState.platformStand
    humanoid.WalkSpeed = originalState.walkSpeed
    humanoid.CameraOffset = originalState.cameraOffset

    local states = {
        {"ragdollEnabled", Enum.HumanoidStateType.Ragdoll},
        {"fallingDownEnabled", Enum.HumanoidStateType.FallingDown},
        {"physicsEnabled", Enum.HumanoidStateType.Physics},
        {"runningEnabled", Enum.HumanoidStateType.Running},
        {"runningNoPhysicsEnabled", Enum.HumanoidStateType.RunningNoPhysics},
        {"jumpingEnabled", Enum.HumanoidStateType.Jumping},
        {"freefallEnabled", Enum.HumanoidStateType.Freefall},
        {"landedEnabled", Enum.HumanoidStateType.Landed},
    }
    for _, item in ipairs(states) do
        pcall(function() humanoid:SetStateEnabled(item[2], originalState[item[1]]) end)
    end

    local animate = character and character:FindFirstChild("Animate")
    local playEmote = animate and animate:FindFirstChild("PlayEmote")
    if playEmote and playEmote:IsA("BindableFunction") and originalState.emoteCaptured then
        pcall(function() playEmote.OnInvoke = originalState.emoteOnInvoke end)
    end
end

local function restoreNormal()
    resetCameraStabilization()
    setJumpButtonVisible(false)
    leaveCustom()
    jumped = false
    jumpLaunchUp = UP
    jumpLaunchPosition = nil
    jumpLaunchPlaneCrossed = false
    justLanded = false
    jumpRequested = false
    jumpInputHeld = false
    jumpRequestLatched = false
    lastJumpRequestAt = 0
    jumpLocked = false
    resetGravitySwitchBackState()
    resetSafeSurfaceState()

    if animateScript then
        animateScript.Disabled = originalState.valid and originalState.animateDisabled or animateWasDisabled
    end
    destroyAnimationTracks()

    if controls then
        pcall(function()
            controls:Enable()
        end)
    end

    if humanoid then
        -- Restore the exact Roblox-owned state captured when this character
        -- was initialized instead of assuming the defaults. This makes the X
        -- button a true unload/cleanup path, not merely WallWalk OFF.
        restoreOriginalCharacterState()
    end
end

local function activateWallWalk()
    if not character or not humanoid or not root then return end

    enabled = true
    safetyReleased = false
    setJumpButtonVisible(UserInputService.TouchEnabled)
    controls = controls or getPlayerControls()
    if controls then pcall(function() controls:Enable() end) end

    currentUp = UP
    targetUp = UP
    lastDetectedUp = UP
    lastSurfaceSeen = os.clock()
    customActive = false
    jumped = false
    jumpLaunchUp = UP
    jumpLaunchPosition = nil
    jumpLaunchPlaneCrossed = false
    justLanded = false
    jumpRequested = false
    jumpInputHeld = false
    jumpRequestLatched = false
    lastJumpRequestAt = 0
    jumpLocked = false
    resetGravitySwitchBackState()
    resetSafeSurfaceState()

    -- WallWalk ON is NOT the same thing as Physics ON.
    -- Start in completely native Roblox floor mode.
    humanoid.PlatformStand = false
    humanoid.AutoRotate = true
    pcall(function()
        humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
        humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
    end)
    pcall(function()
        humanoid:SetStateEnabled(Enum.HumanoidStateType.Physics, false)
        humanoid:SetStateEnabled(Enum.HumanoidStateType.Running, true)
        humanoid:SetStateEnabled(Enum.HumanoidStateType.RunningNoPhysics, true)
        humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
        humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, true)
        humanoid:SetStateEnabled(Enum.HumanoidStateType.Landed, true)
    end)

    if gravityForce then
        gravityForce.Force = ZERO
        gravityForce.Enabled = false
    end
    if orientation then orientation.Enabled = false end

    -- Leave the game's Animate script running while on the floor. It will be
    -- replaced by our controller only after a wall/ceiling takeover.
    if animateScript then
        animateScript.Disabled = false
    end
end

local function setupCharacter(newCharacter)
    character = newCharacter
    humanoid = character:WaitForChild("Humanoid")
    root = character:WaitForChild("HumanoidRootPart")

    -- Persistent ragdoll protection. Do not rely on Heartbeat timing: if
    -- another script requests Ragdoll/FallingDown between frames, immediately
    -- reject it. This remains installed while this WallWalk instance exists,
    -- including while the toggle is OFF.
    pcall(function()
        humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
        humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
    end)
    table.insert(lifecycleConnections, humanoid.StateChanged:Connect(function(_, newState)
        if destroyed or not humanoid then return end
        if newState == Enum.HumanoidStateType.Ragdoll or newState == Enum.HumanoidStateType.FallingDown then
            pcall(function()
                humanoid:ChangeState((enabled and customActive and not emoteStateBridge) and Enum.HumanoidStateType.Physics or Enum.HumanoidStateType.Running)
            end)
        end
    end))
    -- Animate can appear slightly after HumanoidRootPart on respawn. Wait for
    -- it before activating the custom animation controller.
    animateScript = character:WaitForChild("Animate", 5)
    animateWasDisabled = animateScript and animateScript.Disabled or false
    captureOriginalCharacterState()
    animator = humanoid:FindFirstChildOfClass("Animator")
        or humanoid:WaitForChild("Animator", 5)
    installWallWalkEmoteHandler()

    -- Keep the emote hook authoritative across Animate's floor/wall handoff.
    -- Re-enabling Animate on the floor can restore its own PlayEmote.OnInvoke;
    -- when WallWalk takes Physics control again, the wheel may otherwise hit
    -- Roblox's temporary-unavailable path. Guard the actual BindableFunction
    -- every frame instead of relying on a one-time/deferred rebind.
    if emoteHandlerGuardConnection then
        emoteHandlerGuardConnection:Disconnect()
        emoteHandlerGuardConnection = nil
    end
    emoteHandlerGuardConnection = RunService.Heartbeat:Connect(function()
        if destroyed or not character or not humanoid then return end
        local animate = character:FindFirstChild("Animate")
        if animate then
            installWallWalkEmoteHandler()
        end
    end)

    controls = getPlayerControls()

    rayParams = RaycastParams.new()
    rayParams.FilterType = Enum.RaycastFilterType.Exclude
    rayParams.FilterDescendantsInstances = {character}
    rayParams.IgnoreWater = true

    createControllers()

    currentUp = UP
    targetUp = UP
    lastDetectedUp = UP
    customActive = false
    controllerPhysicsActive = false
    activeLocomotion = nil
    activeAir = nil
    activeIdle = nil
    animationTracks = {Idle = {}, Walk = {}, Run = {}, Jump = {}, Fall = {}}
    jumped = false
    jumpLaunchUp = UP
    jumpLaunchPosition = nil
    jumpLaunchPlaneCrossed = false
    justLanded = false
    jumpRequested = false
    jumpInputHeld = false
    jumpRequestLatched = false
    lastJumpRequestAt = 0
    jumpLocked = false
    lastSurfaceSeen = os.clock()

    if enabled then
        activateWallWalk()
    else
        restoreNormal()
    end
end

local function update(dt)
    if destroyed then return end
    if not enabled or not character or not humanoid or not root or humanoid.Health <= 0 then return end

    enforceRagdollProtection()

    if controls then pcall(function() controls:Enable() end) end

    local moveVector = getMoveVector()

    -- Capture the movement heading using the OLD surface frame before
    -- updateSurface() is allowed to commit a new gravity side. This is the key
    -- input for a forward corner transition: the heading gets transported
    -- with oldUp -> newUp instead of being rebuilt after the switch.
    transitionMoveCandidate = nil
    if moveVector.Magnitude > 0.05 then
        local preSurfaceMove = getWorldMove(moveVector, currentUp)
        if preSurfaceMove.Magnitude > 0.05 then
            transitionMoveCandidate = preSurfaceMove
        end
    end

    -- Cancel an active emote as soon as movement input is detected, rather
    -- than waiting for the animation update later in the frame.
    if emoteTrack and emoteTrack.IsPlaying and moveVector.Magnitude > 0.05 then
        cancelActiveEmote()
    end

    updateSurface(dt, moveVector)

    if checkSurfaceSafety(dt, moveVector) then return end

    if not customActive then
        if jumpRequested then
            jumpRequested = false
            if humanoid then
                humanoid.Jump = true
                pcall(function()
                    humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
                end)
            end
        end
        return
    end

    -- Walking cancels the active emote. The movement vector comes directly
    -- from PlayerModule, so simply opening the emote wheel does not cancel it;
    -- an actual WASD/joystick input does.
    if moveVector.Magnitude > 0.05 and emoteTrack then
        cancelActiveEmote()
    end

    local worldMove = getWorldMove(moveVector, currentUp)
    local movementMove, microStepActive = getMicroStepRampMove(worldMove, currentUp, dt)

    -- Only invoke the new stair solver when the original micro-step solver is
    -- not already handling the geometry. This is the key regression guard:
    -- v48.35's established micro-step path remains authoritative for tiny
    -- seams/bumps and low ramps.
    if not microStepActive then
        movementMove, microStepActive = getStairStepRampMove(movementMove, currentUp, dt)
    else
        decayStairStepBlend(dt)
    end

    if jumpRequested then
        jumpRequested = false
        if isFloorUp(currentUp) then
            if humanoid then
                humanoid.Jump = true
                pcall(function()
                    humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
                end)
            end
        else
            performJump()
        end
    end

    justLanded = false

    if jumped then
        local normalVelocity = root.AssemblyLinearVelocity:Dot(currentUp)
        local landedNow = getActualSurfaceContact(currentUp)
        if not landedNow and normalVelocity <= 1.5 then
            landedNow = getJumpSurfaceSupport(currentUp)
        end
        -- Keep the jump state until the character is descending and the
        -- current surface is positively supporting it. This prevents both
        -- infinite jumps and a permanent wall-jump lock.
        if landedNow and normalVel
Preview truncated for large file