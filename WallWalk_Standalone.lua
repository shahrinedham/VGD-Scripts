--[[
VGD WallWalk Standalone v48.76.113 Idle-to-Locomotion Crossfade Polish.
Source parent: v48.76.112_Floor_Edge_Underside_Near_Miss_Reacquire. Canonical historical rollback baseline remains v48.76.82.
This candidate preserves all v48.76.112 transition logic and changes only grounded idle/locomotion animation handoff timing: idle fades out over the same 0.20s used to fade Walk/Run in, and Walk/Run fade out over 0.20s as idle fades in. Gravity, transitions, support detection, movement forces, and animation assets are unchanged. Static validation only; Roblox runtime still needs testing.
Each top-level function is compiled separately and initialized in source order.
Top-level state/functions are shared through one environment; function locals remain local.
]]

local compiler = loadstring
if type(compiler) ~= "function" then
    warn("VGD WallWalk v48.76.113: loadstring is unavailable; no modules were started.")
    return
end

local baseEnvironment = _G
if type(getfenv) == "function" then
    local ok, currentEnvironment = pcall(getfenv)
    if ok and type(currentEnvironment) == "table" then
        baseEnvironment = currentEnvironment
    end
end

local sharedEnvironment = baseEnvironment
if type(setfenv) == "function" then
    sharedEnvironment = setmetatable({}, { __index = baseEnvironment })
end

local modules = {
    { name = '00_initial_state', source = [=[--[[
    VGD WallWalk Standalone v48.76.105 Walk/Run Animation + Diagnostic Integrity Bootstrap
    Client Gravity Override + Surface-Relative Gravity + Ceiling Stair Lift Fix

    Base: v6 GravityController_Rebuild

    v8 goals:
      * Keep the v6 multi-ray surface sensor and VectorForce gravity model.
      * While WallWalk owns wall/ceiling physics, set Workspace.Gravity to 0 locally
        and apply the saved Roblox gravity strength through the custom VectorForce.
      * Restore the exact pre-WallWalk Workspace.Gravity value when custom control ends.
      * Keep surface-normal jumping: floor / wall / ceiling all use currentUp.
      * Make joystick/WASD directions intuitive on every surface.
      * Make wall -> ceiling transitions easier by using predictive feelers and
        stronger candidate confirmation near the current surface.
      * Add a real ON/OFF button that restores Roblox movement, jumping,
        AutoRotate, PlatformStand and Animate cleanly.
      * Re-enable WallWalk cleanly after being turned OFF.
]]

Players =  game:GetService("Players")
RunService =  game:GetService("RunService")
UserInputService =  game:GetService("UserInputService")
GuiService =  game:GetService("GuiService")

-- Initialize shared basis vectors before any state uses UP.
ZERO = Vector3.zero
UP = Vector3.yAxis

player =  Players.LocalPlayer
playerGui =  player:WaitForChild("PlayerGui")

CFG =  {
    WalkSpeed = 16,

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

    -- Only a genuinely near-vertical face is treated as a riser by the
    -- first-riser gravity guard. Steeper ramps remain valid surface candidates.
    StairRiserGravityVerticalDot = 0.25,
    StairRiserContinuationHeight = 1.30,
    StairRiserContinuationLength = 1.25,
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

    -- v48.64: when the owned surface is an upside-down ceiling staircase,
    -- allow the safety sensor to use a wider near-contact fallback fan when
    -- the main gravity scan temporarily lands on a riser/edge instead of a
    -- tread. Flat upside-down surfaces keep the exact same normal path; this
    -- fallback only runs after the authoritative support result is absent.
    UpsideDownStairSafetyDot = -0.985,
    UpsideDownStairSafetyFanRadius = 1.75,
    UpsideDownStairSafetyProbeLength = 4.25,
    UpsideDownStairSafetyDistance = 3.25,
    UpsideDownStairSafetyGrace = 1.50,
    UpsideDownStairTraversalSafetyHold = 1.50,

    -- Upside-down stair steps need a brief movement component toward -currentUp
    -- (toward the ceiling). During the short active step ramp, reduce the normal
    -- custom gravity load and give the requested climb vector more authority.
    -- This is scoped only to ceiling steps; floor/wall gravity and the first-riser
    -- guard are unchanged.
    -- With native Workspace.Gravity suppressed locally, this is now the actual
    -- fraction of Roblox gravity used during an upside-down stair step. 0.35g
    -- keeps a gentle pull toward the ceiling without the old native-gravity fight.
    StairCeilingStepGravityScale = 0.35,
    StairCeilingStepForceMultiplier = 1.15,
    StairCeilingStepLiftAcceleration = 360,
    StairCeilingStepHoldTime = 0.24,

    -- v48.75: ceiling stairs use the same surface-relative stair ramp method
    -- as v48.65. Geometry detection is separate from movement actuation: the
    -- target tread supplies rise/run, then the existing custom movement solver
    -- follows that short ramp toward the next underside tread.
    StairCeilingStepForwardLead = 0.10,
    StairCeilingStepDetectRange = 3.20,
    StairCeilingStepDetectStart = 0.35,
    StairCeilingStepSupportDistance = 4.50,
    StairCeilingStepSideProbe = 0.80,
    StairCeilingProbeLength = 4.50,
    StairCeilingProbeOffset = 0.12,

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
    TransitionProbeLength = 6.5,
    TransitionProbeHeight = 1.15,
    TransitionProbeSide = 1.05,

    -- v48.76.30: edge wall acquisition is based on the physical radial fan,
    -- not the current movement direction. A real adjacent wall must be vertical,
    -- below the current support plane, close to the character, and corroborated
    -- by distinct down-fan rays. Stair detection remains an exclusion.
    RadialEdgeWallMaxDistance = 6.25,
    RadialEdgeWallMinDrop = 0.25,
    RadialEdgeWallNormalDot = 0.94,
    RadialEdgeWallMinSamples = 3,
    -- Preserve independent ray evidence briefly across frames at running speed.
    RadialEdgeWallEvidenceWindow = 0.36,

    -- A fan-ray point may be several studs below the character even when the
    -- wall itself is beside the torso. Confirm the wall plane with fixed-range
    -- probes at the character's current height band before using the shared gap.
    EdgeTransitionPendingLifetime = 0.85,
    EdgeTransitionProbeOffsets = {-1.35, -0.60, 0.15, 0.80},
    EdgeTransitionContactSpeedLead = 0.02,
    EdgeTransitionContactSpeedLeadMax = 0.45,
    -- Edge and movement-facing transitions have separate pending ownership.
    -- A horizontal target near a wall edge is scanned independently from the
    -- forward-facing transition probes, then must pass a direction/contact gate.
    EdgeHorizontalProbeLength = 5.50,
    -- Preserve the established contact threshold for ordinary transitions.
    -- Floor returns measure body clearance from the actual floor plane plus the
    -- tangent distance from the hit to the projected body footprint; root height
    -- is diagnostic only and cannot veto a real body-to-floor contact.
    VerticalSurfaceContactGap = 0.25,
    -- An angled floor ray may hit slightly ahead of the body footprint. Keep
    -- true body-to-plane clearance strict, but forgive this tangent-only offset.
    FloorContactTangentAllowance = 0.50,
    -- Do not let the source floor reclaim gravity immediately after floor->wall.
    -- Release only after target support is stable AND the source floor was cleared,
    -- or at the bounded timeout. Directed contact can still authorize a real return.
    FloorToWallReturnLockMaxTime = 1.80,
    FloorToWallReturnLockReleaseProgress = 2.75,
    -- A single safety-fan frame is not enough to complete a gravity handoff.
    TransitionSupportConfirmTime = 0.12,
    TransitionReturnGuardTime = 0.20,
    -- Speed lead is bounded and applies only to edge contact geometry; ordinary
    -- forward transitions still use their fixed plane-clearance threshold.
    EdgeHorizontalContactLeadMax = 1.20,
    -- Bounded progressive lead for ceiling/underside edge transitions.
    EdgeUndersideFastContactLeadMax = 2.25,
    -- Direction-confirmed floor-edge -> wall-underside reacquisition limits.
    FloorEdgeUndersideMinContactLead = 0.75,
    FloorEdgeUndersideFastContactLeadMax = 2.55,
    -- A rare undirected near-miss may still have an independent wall-plane ray.
    -- Give that case a small extra gap cap only when the candidate point is close.
    FloorEdgeUndersideUndirectedNearMissPointLimit = 4.25,
    FloorEdgeUndersideUndirectedNearMissLeadMax = 2.70,
    -- Separate, slightly larger reach for wall-edge -> ceiling underside only.
    WallEdgeCeilingFastContactLeadMax = 3.00,
    -- Approach-only floor edge range. This tracks a directional floor candidate
    -- before/after support loss; it never permits a gravity switch at this range.
    EdgeFloorApproachDistance = 9.00,
    EdgeFloorApproachProbeLength = 9.00,
    EdgeFloorApproachMaxHold = 1.50,
    EdgeFloorApproachCandidateLifetime = 1.60,
    -- After wall support is explicitly lost, a nearby world-up floor can be the
    -- safe gravity destination even when tangential movement points away from it.
    -- Keep this exception bounded by root distance and real body/tangent geometry.
    WallEdgeFloorLostSupportPointLead = 1.75,
    WallEdgeFloorLostSupportSurfaceGap = 2.75,
    WallEdgeFloorLostSupportPlaneGap = 2.25,
    WallEdgeFloorLostSupportTangentExtra = 0.15,
    EdgeFloorApproachInputDot = 0.20,
    EdgeFloorApproachVelocityDot = 0.15,
    EdgeFloorApproachMinVelocity = 0.75,
    TransitionSupportGrace = 0.65,
    -- These routes can be accepted with speed-based edge lead before the full
    -- character body reaches the target plane. Keep the claim bounded but allow
    -- the body to rotate/contact before the normal fall-safety timer takes over.
    FloorEdgeWallHandoffGrace = 1.75,
    WallToCeilingHandoffGrace = 1.75,
    CeilingToWallHandoffGrace = 1.75,
    -- Wall-edge -> ceiling needs longer to acquire underside support after the
    -- gravity snap: the valid ceiling ray can be farther from the root plane.
    WallEdgeCeilingHandoffGrace = 1.75,
    WallEdgeCeilingHandoffMaxDistance = 6.50,
    -- Only a validated wall-edge -> ceiling handoff may use this
    -- extended root probe while it is the active ceiling entry path. Match the
    -- v42-style 5-stud candidate reach so the root can acquire the same plane.
    LegacyWallEdgeCeilingSupportDistance = 5.00,
    LegacyWallEdgeCeilingSourceWallClearProgress = 0.75,
    -- Briefly suppress only the wall used as the source of an edge-to-floor handoff.
    LegacyWallEdgeFloorSourceWallHoldTime = 0.55,
    -- Do not interpret the movement held during the wall-to-floor landing as a
    -- new request to climb back onto that same wall. Only after this brief settle
    -- interval can neutral/away input arm a fresh, deliberate return.
    LegacyWallEdgeFloorSourceWallFreshIntentDelay = 0.12,
    LegacyWallEdgeFloorSourceWallClearProgress = 0.60,
    -- Keep the source ceiling from stealing gravity back during a forward
    -- ceiling -> wall handoff. Release only after real wall contact and enough
    -- movement away from the source ceiling, or let ordinary safety recover.
    CeilingToWallLockMaxTime = 1.80,
    CeilingToWallLockReleaseProgress = 2.75,
    CeilingToWallLockSupportDistance = 2.25,
    TransitionHandoffMaxDistance = 5.25,

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

    ToggleWidth = 62,
    ToggleHeight = 24,
    CameraUpResponsiveness = 12,
    PanelWidth = 140,
    PanelHeight = 102,
}

character = nil
humanoid = nil
root = nil
controls = nil
rayParams = nil

gravityAttachment = nil
gravityForce = nil

-- While custom WallWalk physics is active, native Workspace.Gravity is locally
-- suppressed so there is exactly one gravity owner. Keep the latest real Roblox
-- gravity value here so the custom force can reproduce it on any surface.
wallWalkGravity =  workspace.Gravity
workspaceGravitySuppressed =  false

orientationAttachment = nil
orientation = nil

enabled =  true
customActive =  false
controllerPhysicsActive =  false
currentUp =  Vector3.yAxis
targetUp =  Vector3.yAxis
lastDetectedUp =  Vector3.yAxis
lastSurfaceSeen =  0

jumpRequested =  false
jumpInputHeld =  false
lastJump =  0
jumped =  false
jumpStartedAt =  0
jumpLaunchUp =  UP
jumpLaunchPosition =  nil
jumpLaunchPlaneCrossed =  false
justLanded =  false
jumpLocked =  false
jumpRequestLatched =  false
lastJumpRequestAt =  0
surfaceLostAt =  0
safetyReleased =  false
ceilingApproachHoldStartedAt = 0
ceilingApproachHoldExpired = false
ceilingApproachHoldInstance = nil
ceilingApproachHoldPoint = nil
ceilingApproachHoldNormal = nil
nativeFloorHandoffInProgress = false

-- Gravity-transition state. This is only armed by an actual gravity-plane
-- change detected by updateSurface(). It does NOT alter normal wall/ceiling
-- support detection or the existing safety timer.
gravityTransitionActive =  false
-- Recent radial wall hits survive a few frames so fast movement does not need
-- three separate fan rays to hit the wall in one exact frame.
radialEdgeMemory = nil
edgeTransitionPending = nil
forwardTransitionPending = nil
-- Set by getGravityUp for the exact detector that supplied the accepted target.
-- The coordinator consumes this metadata only when a real gravity side commits.
transitionCandidateRoute = nil
transitionCandidateHit = nil
transitionCandidateNormal = nil
transitionCandidateSupportGap = false
transitionClaim = nil
-- True only after the v42-style wall-edge -> ceiling route commits.
-- It lets that one route finish attachment with its observed root gap.
legacyEdgeCeilingSupportActive = false
ceilingContactSupportReachActive = false
legacyEdgeCeilingSourceWallHoldActive = false
legacyEdgeCeilingHandoffPending = false
legacyEdgeCeilingSourceUp = nil
legacyEdgeCeilingHandoffPosition = nil
legacyEdgeCeilingStartedAt = 0
-- Active only after the isolated wall-edge -> floor route commits.
legacyEdgeFloorSourceWallActive = false
legacyEdgeFloorSourceUp = nil
legacyEdgeFloorHandoffPosition = nil
legacyEdgeFloorStartedAt = 0
legacyEdgeFloorSourceWallIntentReleased = false
legacyEdgeFloorSourceWallInputDot = 0
-- The legacy detector route remains "forward"/"edge" for compatibility.
-- This separate key names the exact transition controller that accepted it.
transitionResolvedRoute = nil
transitionRouteStates = {}
-- v48.76.102 keeps the v48.76.99 source-wall hold fix; this build adds speed-based Walk/Run selection and diagnostic clarity.
transitionCandidateAuditSequence = 0
transitionCandidateAuditCurrent = nil
transitionCandidateAuditLatest = nil
transitionCandidateAuditByRoute = {}
transitionCandidateAuditBySequence = {}
transitionCandidateAuditHistoryLimit = 128
transitionCandidateAuditHistoryCount = 0
transitionCandidateAuditPruneCursor = 1
transitionCandidateAuditErrorCount = 0
transitionCandidateAuditStats = {
    offered = 0,
    authorized = 0,
    rejected = 0,
    unmanaged = 0,
    committed = 0,
    completed = 0,
    claimReplacements = 0,
    expired = 0,
    aborted = 0,
}
orientationTransitionUntil =  0
-- Carry the character's SURFACE-PATH direction across a real gravity-side
-- change. The important part is that this is transported by the same rotation
-- that changes oldUp -> newUp, rather than simply projected onto the new plane.
-- That makes a forward wall/ceiling transition behave like walking around a
-- physical corner: the heading follows the surface instead of becoming random.
transitionFacing =  nil
lastFacingDirection =  nil
transitionMoveCandidate =  nil

-- During a gravity-side handoff, the character should not acquire a large
-- velocity component AWAY from the newly selected surface. The final physics
-- diagnostic showed that the remaining launch is a post-solver contact impulse
--, so limiting AlignOrientation angular speed alone is not sufficient. This
-- guard removes only excessive outward normal velocity during the 0.32s handoff;
-- tangent movement and normal WallWalk gravity are left untouched.]=] },
    { name = '00a_wallTransitionDiagnostics', source = [=[
wwWallDiagLastAt = wwWallDiagLastAt or {}
wwTransitionPhaseLogAt = wwTransitionPhaseLogAt or {}

function wwDescribeSurfaceOrientation(up)
    if typeof(up) ~= "Vector3" then return "Unknown" end
    if up.Y > 0.82 then return "Floor" end
    if up.Y < -0.82 then return "Ceiling" end
    if math.abs(up.X) > math.abs(up.Z) then
        return up.X > 0 and "Right Wall" or "Left Wall"
    end
    return up.Z > 0 and "Back Wall" or "Front Wall"
end

function wwWallDiagDue(eventName, interval)
    local last = wwWallDiagLastAt[eventName] or 0
    return os.clock() - last >= (interval or 0.5)
end

function wwWallDiag(eventName, detail, interval)
    local now = os.clock()
    local last = wwWallDiagLastAt[eventName] or 0
    if now - last < (interval or 0.5) then return end
    wwWallDiagLastAt[eventName] = now
    print("[WW DIAG v48.76.113] " .. tostring(eventName) .. " | t=" .. string.format("%.2f", now) .. " | " .. tostring(detail or ""))
end

function wwWallDiagCheckFloorApproach(oldUp, hit, moveDir, distance, moveVector)
    local approach = isWallFloorApproach(oldUp, hit, moveDir)
    wwWallDiag(
        approach and "WALL_FLOOR_CANDIDATE_AHEAD" or "WALL_FLOOR_CANDIDATE_REJECTED",
        "dist=" .. string.format("%.2f", distance)
            .. ", posY=" .. string.format("%.2f", root.Position.Y)
            .. ", moveMag=" .. string.format("%.2f", moveVector and moveVector.Magnitude or 0),
        0.45
    )
    return approach
end

-- Forensic-only wall-edge trace state. This records observations and already-computed
-- gate results; it does not feed any transition decision.
wwEdgeForensicScan = nil
wwEdgeForensicFloorGateInfo = {}
legacyEdgeFloorQualificationReason = nil

function wwEdgeForensicVector(value)
    if typeof(value) ~= "Vector3" then return "n/a" end
    return string.format("%.3f,%.3f,%.3f", value.X, value.Y, value.Z)
end

function wwEdgeForensicInstancePath(instance)
    if not instance then return "none" end
    local ok, path = pcall(function() return instance:GetFullName() end)
    if ok and path then return tostring(path) end
    return tostring(instance)
end

function wwBeginEdgeForensicScan(oldUp, moveVector, currentSupportSeen, worldMove, velocity)
    local now = os.clock()
    local floorLast = wwWallDiagLastAt["EDGE_FORENSIC_FLOOR"] or 0
    local ceilingLast = wwWallDiagLastAt["EDGE_FORENSIC_CEILING"] or 0
    if not root or (now - floorLast < 0.50 and now - ceilingLast < 0.50) then
        wwEdgeForensicScan = nil
        return
    end
    wwEdgeForensicScan = {
        at = now,
        rootPosition = root.Position,
        rootVelocity = velocity or root.AssemblyLinearVelocity,
        rootUp = safeUnit(oldUp, UP),
        moveVector = moveVector or ZERO,
        worldMove = worldMove or ZERO,
        supportSeen = currentSupportSeen == true,
        rawFloor = nil,
        rawCeiling = nil,
        acceptedFloor = nil,
        acceptedCeiling = nil,
    }
end

function wwRecordEdgeForensicHit(hit, normal, probeOrigin, rayDirection, probeLength,
    kind, planeDistance, pointDistance, surfaceGap, maxSurfaceGap, withinContactGap,
    extendedFloorApproach, directionCompatible, movingTowardPlane, movingTowardTarget,
    inputTowardTarget, velocityTowardTarget, gateAccepted, floorGateInfo, usedPointDistanceFallback)
    local scan = wwEdgeForensicScan
    if not scan or not hit or not hit.Instance or not normal then return end
    local rawKey = kind == "floor" and "rawFloor" or "rawCeiling"
    local acceptedKey = kind == "floor" and "acceptedFloor" or "acceptedCeiling"
    local priorRaw = scan[rawKey]
    local priorAccepted = scan[acceptedKey]
    local betterRaw = not priorRaw or planeDistance < priorRaw.planeDistance
    local betterAccepted = gateAccepted
        and (not priorAccepted or planeDistance < priorAccepted.planeDistance)
    if not betterRaw and not betterAccepted then return end
    local record = {
        instance = hit.Instance,
        position = hit.Position,
        rawNormal = hit.Normal,
        normal = normal,
        probeOrigin = probeOrigin,
        rayDirection = rayDirection,
        probeLength = probeLength,
        hitDistance = hit.Distance,
        kind = kind,
        planeDistance = planeDistance,
        pointDistance = pointDistance,
        surfaceGap = surfaceGap,
        maxSurfaceGap = maxSurfaceGap,
        withinContactGap = withinContactGap == true,
        extendedFloorApproach = extendedFloorApproach == true,
        directionCompatible = directionCompatible == true,
        movingTowardPlane = movingTowardPlane == true,
        movingTowardTarget = movingTowardTarget == true,
        inputTowardTarget = inputTowardTarget == true,
        velocityTowardTarget = velocityTowardTarget == true,
        gateAccepted = gateAccepted == true,
        usedPointDistanceFallback = usedPointDistanceFallback == true,
    }
    if floorGateInfo then
        record.floorGateInfo = {
            contactAccepted = floorGateInfo.contactAccepted,
            planeGap = floorGateInfo.planeGap,
            tangentGap = floorGateInfo.tangentGap,
            tangentLimit = floorGateInfo.tangentLimit,
            movingToward = floorGateInfo.movingToward,
            inputToward = floorGateInfo.inputToward,
            velocityToward = floorGateInfo.velocityToward,
            planeLimit = floorGateInfo.planeLimit,
            pointLimit = floorGateInfo.pointLimit,
        }
    end
    if betterRaw then scan[rawKey] = record end
    if betterAccepted then scan[acceptedKey] = record end
end

function wwEdgeForensicDescribeRecord(record, selectedHit, selectedRoute)
    if not record then return "NONE" end
    local canCollide = "n/a"
    local canQuery = "n/a"
    local className = "n/a"
    local physicalContactGate = "not-applicable"
    local bodyPlaneGap = "not-applicable"
    local tangentGap = "not-applicable"
    local tangentLimit = "not-applicable"
    if record.floorGateInfo then
        physicalContactGate = tostring(record.floorGateInfo.contactAccepted)
        bodyPlaneGap = string.format("%.3f", tonumber(record.floorGateInfo.planeGap) or math.huge)
        tangentGap = string.format("%.3f", tonumber(record.floorGateInfo.tangentGap) or math.huge)
        tangentLimit = string.format("%.3f", tonumber(record.floorGateInfo.tangentLimit) or 0)
    end
    local ok, isPart = pcall(function() return record.instance:IsA("BasePart") end)
    if ok and isPart then
        local flagsOk, collide, query, class = pcall(function()
            return record.instance.CanCollide, record.instance.CanQuery, record.instance.ClassName
        end)
        if flagsOk then
            canCollide = tostring(collide)
            canQuery = tostring(query)
            className = tostring(class)
        end
    end
    local selected = selectedHit ~= nil
        and selectedHit.Instance == record.instance
        and (selectedHit.Position - record.position).Magnitude < 0.001
    return "kind=" .. tostring(record.kind)
        .. ", part=" .. wwEdgeForensicInstancePath(record.instance)
        .. ", normalDotWorldUp=" .. string.format("%.4f", record.normal:Dot(UP))
        .. ", class=" .. className
        .. ", canCollide=" .. canCollide
        .. ", canQuery=" .. canQuery
        .. ", hit=" .. wwEdgeForensicVector(record.position)
        .. ", rawNormal=" .. wwEdgeForensicVector(record.rawNormal)
        .. ", orientedNormal=" .. wwEdgeForensicVector(record.normal)
        .. ", origin=" .. wwEdgeForensicVector(record.probeOrigin)
        .. ", rayDir=" .. wwEdgeForensicVector(record.rayDirection)
        .. ", rayLength=" .. string.format("%.3f", tonumber(record.probeLength) or 0)
        .. ", rayHitDist=" .. string.format("%.3f", tonumber(record.hitDistance) or math.huge)
        .. ", planeDist=" .. string.format("%.3f", record.planeDistance)
        .. ", rootPointDist=" .. string.format("%.3f", record.pointDistance)
        .. ", surfaceGap=" .. string.format("%.3f", record.surfaceGap)
        .. ", gapLimit=" .. string.format("%.3f", record.maxSurfaceGap)
        .. ", scannerPrequalified=" .. tostring(record.withinContactGap)
        .. ", physicalPlaneTangentContact=" .. physicalContactGate
        .. ", bodyPlaneGap=" .. bodyPlaneGap
        .. ", tangentGap=" .. tangentGap
        .. ", tangentLimit=" .. tangentLimit
        .. ", legacyPointDistanceFallback=" .. tostring(record.usedPointDistanceFallback)
        .. ", extendedApproach=" .. tostring(record.extendedFloorApproach)
        .. ", directionCompatible=" .. tostring(record.directionCompatible)
        .. ", movingTowardPlane=" .. tostring(record.movingTowardPlane)
        .. ", movingTowardTarget=" .. tostring(record.movingTowardTarget)
        .. ", inputToward=" .. tostring(record.inputTowardTarget)
        .. ", velocityToward=" .. tostring(record.velocityTowardTarget)
        .. ", routeGateAccepted=" .. tostring(record.gateAccepted)
        .. ", scannerSelected=" .. tostring(selected)
        .. ", edgeDiscontinuity=not-tested-by-this-scanner"
        .. ", selectedRoute=" .. tostring(selected and selectedRoute or "none")
end

function wwEmitEdgeForensicScan(selectedHit, selectedNormal, selectedRoute, selectedDistance)
    local scan = wwEdgeForensicScan
    if not scan then return end
    local common = "probeFamily=edge-horizontal-probes"
        .. ", root=" .. wwEdgeForensicVector(scan.rootPosition)
        .. ", sourceUp=" .. wwEdgeForensicVector(scan.rootUp)
        .. ", velocity=" .. wwEdgeForensicVector(scan.rootVelocity)
        .. ", inputWorld=" .. wwEdgeForensicVector(scan.worldMove)
        .. ", supportSeen=" .. tostring(scan.supportSeen)
        .. ", selectedRoute=" .. tostring(selectedRoute or "none")
        .. ", selectedPlaneDist=" .. string.format("%.3f", tonumber(selectedDistance) or math.huge)
    wwWallDiag("EDGE_FORENSIC_FLOOR",
        common .. ", raw={" .. wwEdgeForensicDescribeRecord(scan.rawFloor, selectedHit, selectedRoute)
            .. "}, acceptedNearest={" .. wwEdgeForensicDescribeRecord(scan.acceptedFloor, selectedHit, selectedRoute) .. "}",
        0.50)
    wwWallDiag("EDGE_FORENSIC_CEILING",
        common .. ", raw={" .. wwEdgeForensicDescribeRecord(scan.rawCeiling, selectedHit, selectedRoute)
            .. "}, acceptedNearest={" .. wwEdgeForensicDescribeRecord(scan.acceptedCeiling, selectedHit, selectedRoute) .. "}",
        0.50)
    wwEdgeForensicScan = nil
end
]=] },
    { name = '00b_transitionGapHelpers', source = [=[
-- Measure distance from the surface hit point to the nearest actual body-part
-- box. Do not use one model-wide box: that box includes empty space between limbs
-- and accessory extents, both of which can report false contact with a floor.
surfaceGapCacheCharacter = nil
surfaceGapBodyParts = nil
surfaceGapBodyPartsAt = 0

function getBodyPartSurfaceGap(point)
    if not character or not point then return math.huge end

    local now = os.clock()
    if surfaceGapCacheCharacter ~= character
        or not surfaceGapBodyParts
        or now - surfaceGapBodyPartsAt > 0.75
    then
        local parts = {}
        for _, child in ipairs(character:GetChildren()) do
            -- R6/R15 visible body parts are direct BasePart children. Exclude the
            -- invisible/non-colliding HumanoidRootPart when other body parts exist.
            -- Accessory handles and tool parts are nested under Accessory/Tool and
            -- must not make the avatar appear to touch a surface prematurely.
            if child:IsA("BasePart") and child ~= root and child.Name ~= "HumanoidRootPart" then
                table.insert(parts, child)
            end
        end
        if #parts == 0 and root then
            table.insert(parts, root)
        end
        surfaceGapCacheCharacter = character
        surfaceGapBodyParts = parts
        surfaceGapBodyPartsAt = now
    end

    local bestGap = math.huge
    local parts = surfaceGapBodyParts
    if not parts then return bestGap end

    for _, part in ipairs(parts) do
        if part and part.Parent == character then
            local localPoint = part.CFrame:PointToObjectSpace(point)
            local halfSize = part.Size * 0.5
            local dx = math.max(math.abs(localPoint.X) - halfSize.X, 0)
            local dy = math.max(math.abs(localPoint.Y) - halfSize.Y, 0)
            local dz = math.max(math.abs(localPoint.Z) - halfSize.Z, 0)
            local partGap = math.sqrt(dx * dx + dy * dy + dz * dz)
            if partGap < bestGap then
                bestGap = partGap
            end
        end
    end

    return bestGap
end

-- Floor contact is plane-based, not point-based. An angled approach ray can hit
-- the floor ahead of the character, so its 3D point-to-box distance overstates
-- clearance even when a body part is already at floor height. Measure (1) the
-- part OBB's clearance along the floor normal and (2) the tangential distance
-- from the hit point to that OBB. The adjusted score still requires true near-plane body clearance.
function getBodyPartFloorContactGap(point, normal)
    if not character or not point or not normal then
        return math.huge, math.huge, math.huge
    end
    if normal.Magnitude <= 0.001 then
        return math.huge, math.huge, math.huge
    end
    local n = normal.Unit

    local now = os.clock()
    if surfaceGapCacheCharacter ~= character
        or not surfaceGapBodyParts
        or now - surfaceGapBodyPartsAt > 0.75
    then
        local parts = {}
        for _, child in ipairs(character:GetChildren()) do
            if child:IsA("BasePart") and child ~= root and child.Name ~= "HumanoidRootPart" then
                table.insert(parts, child)
            end
        end
        if #parts == 0 and root then
            table.insert(parts, root)
        end
        surfaceGapCacheCharacter = character
        surfaceGapBodyParts = parts
        surfaceGapBodyPartsAt = now
    end

    local bestGap = math.huge
    local bestPlaneGap = math.huge
    local bestTangentGap = math.huge
    local parts = surfaceGapBodyParts
    if not parts then
        return bestGap, bestPlaneGap, bestTangentGap
    end

    for _, part in ipairs(parts) do
        if part and part.Parent == character then
            local cf = part.CFrame
            local half = part.Size * 0.5
            local centerDistance = math.abs((part.Position - point):Dot(n))
            local planeRadius = math.abs(cf.RightVector:Dot(n)) * half.X
                + math.abs(cf.UpVector:Dot(n)) * half.Y
                + math.abs(cf.LookVector:Dot(n)) * half.Z
            local planeGap = math.max(centerDistance - planeRadius, 0)

            local localPoint = cf:PointToObjectSpace(point)
            local nearestLocal = Vector3.new(
                math.clamp(localPoint.X, -half.X, half.X),
                math.clamp(localPoint.Y, -half.Y, half.Y),
                math.clamp(localPoint.Z, -half.Z, half.Z)
            )
            local nearestPoint = cf:PointToWorldSpace(nearestLocal)
            local delta = point - nearestPoint
            local tangentDelta = delta - n * delta:Dot(n)
            local tangentGap = tangentDelta.Magnitude
            local tangentExcess = math.max(tangentGap - CFG.FloorContactTangentAllowance, 0)
            local contactGap = math.sqrt(planeGap * planeGap + tangentExcess * tangentExcess)

            if contactGap < bestGap then
                bestGap = contactGap
                bestPlaneGap = planeGap
                bestTangentGap = tangentGap
            end
        end
    end

    return bestGap, bestPlaneGap, bestTangentGap
end

-- Cache the established model-bounds metric for ordinary transition acquisition.
-- The final wall->floor reset uses the stricter body-part metric separately.
edgeSurfaceGapCacheCharacter = nil
edgeSurfaceGapCacheAt = 0
edgeSurfaceGapCacheCFrame = nil
edgeSurfaceGapCacheSize = nil

function getLegacyCharacterBoundsGap(point)
    if not character or not point then return math.huge end

    local now = os.clock()
    if edgeSurfaceGapCacheCharacter ~= character
        or now - edgeSurfaceGapCacheAt > 0.006
    then
        local ok, boxCFrame, boxSize = pcall(function()
            return character:GetBoundingBox()
        end)
        if not ok or not boxCFrame or not boxSize then
            edgeSurfaceGapCacheCharacter = nil
            edgeSurfaceGapCacheCFrame = nil
            edgeSurfaceGapCacheSize = nil
            return math.huge
        end
        edgeSurfaceGapCacheCharacter = character
        edgeSurfaceGapCacheAt = now
        edgeSurfaceGapCacheCFrame = boxCFrame
        edgeSurfaceGapCacheSize = boxSize
    end

    local boxCFrame = edgeSurfaceGapCacheCFrame
    local boxSize = edgeSurfaceGapCacheSize
    if not boxCFrame or not boxSize then return math.huge end

    local localPoint = boxCFrame:PointToObjectSpace(point)
    local halfSize = boxSize * 0.5
    local dx = math.max(math.abs(localPoint.X) - halfSize.X, 0)
    local dy = math.max(math.abs(localPoint.Y) - halfSize.Y, 0)
    local dz = math.max(math.abs(localPoint.Z) - halfSize.Z, 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

-- Preserve the established v48.76.66 contact metric for ordinary transition
-- acquisition. The stricter body-part gap is applied separately by the final
-- wall-to-floor gravity-reset gate, where the false early reset was observed.
function getCharacterSurfaceGap(point)
    return getLegacyCharacterBoundsGap(point)
end

-- Determine whether input/velocity is aimed at a candidate along the currently
-- owned surface. World-Y-only checks fail when the player approaches a floor by
-- moving sideways/forward around a wall edge rather than directly downward.
function isMovementTowardSurfacePoint(point, oldUp, moveVector)
    if not root or not point then return false, false, false end

    local up = safeUnit(oldUp, UP)
    local toTarget = projectOnPlane(point - root.Position, up)
    if toTarget.Magnitude <= 0.10 then
        return false, false, false
    end
    local targetDirection = toTarget.Unit

    local worldMove = ZERO
    if moveVector and moveVector.Magnitude > 0.05 then
        worldMove = getWorldMove(moveVector, up)
        worldMove = projectOnPlane(worldMove, up)
    end
    local tangentVelocity = projectOnPlane(root.AssemblyLinearVelocity, up)

    local inputToward = worldMove.Magnitude > 0.05
        and worldMove.Unit:Dot(targetDirection) >= CFG.EdgeFloorApproachInputDot
    local velocityToward = tangentVelocity.Magnitude >= CFG.EdgeFloorApproachMinVelocity
        and tangentVelocity.Unit:Dot(targetDirection) >= CFG.EdgeFloorApproachVelocityDot

    return inputToward or velocityToward, inputToward, velocityToward
end

-- An approach candidate is tracking/safety evidence only. It never authorizes a
-- gravity switch outside VerticalSurfaceContactGap.
edgeFloorApproachHit = nil
edgeFloorApproachNormal = nil
edgeFloorApproachAt = 0
edgeFloorApproachHoldStartedAt = 0

function clearEdgeFloorApproach()
    edgeFloorApproachHit = nil
    edgeFloorApproachNormal = nil
    edgeFloorApproachAt = 0
    edgeFloorApproachHoldStartedAt = 0
end
-- Speed lead for wall-edge -> floor/ceiling traversal only. Direct forward
-- transitions never call this to widen their contact acceptance.
function getEdgeHorizontalSpeedLead(oldUp, moveVector)
    if not root then return 0 end
    local up = safeUnit(oldUp, UP)
    local planarSpeed = projectOnPlane(root.AssemblyLinearVelocity, up).Magnitude
    local commandedSpeed = 0
    if humanoid then
        commandedSpeed = math.max(0, tonumber(humanoid.WalkSpeed) or 0)
            * math.clamp(moveVector and moveVector.Magnitude or 0, 0, 1)
    end
    local transitionSpeed = math.max(planarSpeed, commandedSpeed)
    return math.clamp((transitionSpeed - 9) * 0.12, 0, CFG.EdgeHorizontalContactLeadMax)
end

-- Wall-edge -> ceiling underside needs its own reach: this route loses its target
-- quickly at speed, while ceiling-edge -> wall underside is already validated at WS 21.
-- Keep this larger allowance scoped to wall-source / ceiling-target transitions.
function wwGetWallEdgeToCeilingSpeedLead(fromUp, moveVector)
    if not root then return 0 end
    local up = safeUnit(fromUp, UP)
    if math.abs(up:Dot(UP)) >= 0.985 then return 0 end
    local planarSpeed = projectOnPlane(root.AssemblyLinearVelocity, up).Magnitude
    local commandedSpeed = 0
    if humanoid then
        commandedSpeed = math.max(0, tonumber(humanoid.WalkSpeed) or 0)
            * math.clamp(moveVector and moveVector.Magnitude or 0, 0, 1)
    end
    local transitionSpeed = math.max(planarSpeed, commandedSpeed)
    local lead = math.clamp(
        (transitionSpeed - 9) * 0.25,
        0,
        CFG.WallEdgeCeilingFastContactLeadMax
    )
    local baseLead = getEdgeHorizontalSpeedLead(up, moveVector)
    if baseLead > lead then return baseLead end
    return lead
end

-- Shared geometry decision for wall-edge -> floor. The scanner, route controller,
-- and final candidate gate must all agree on plane clearance plus bounded tangent reach.
function wwGetWallEdgeFloorContact(point, normal, fromUp, moveVector)
    if not point or not normal then
        return false, math.huge, math.huge, math.huge, 0, false, false, false
    end
    local surfaceGap, planeGap, tangentGap = getBodyPartFloorContactGap(point, normal)
    local movingToward, inputToward, velocityToward =
        isMovementTowardSurfacePoint(point, fromUp, moveVector)
    -- A low-speed character's body edge can contact the floor while its root
    -- remains slightly outside the old 0.95-stud tangent allowance. Add only
    -- 0.15 studs to this edge-specific contact envelope; plane clearance stays
    -- strict and speed-based extension remains bounded.
    local tangentLimit = CFG.FloorContactTangentAllowance + 0.60
        + getEdgeHorizontalSpeedLead(fromUp, moveVector)
    local planeLimit = CFG.VerticalSurfaceContactGap + 0.10
    -- Plane clearance plus bounded tangent reach is the physical contact test.
    -- Switchback permission is decided separately and uses INPUT intent, not
    -- inherited velocity, because momentum can point back at the old floor.
    local accepted = planeGap <= planeLimit and tangentGap <= tangentLimit
    return accepted, surfaceGap, planeGap, tangentGap, tangentLimit,
        movingToward, inputToward, velocityToward
end

-- v48.76.42's wall-edge ceiling acquisition allowance. WalkSpeed is intentionally
-- not multiplied by input magnitude here: this is the old bounded edge-distance
-- rule, and is called only for a validated wall-edge -> ceiling candidate.
function wwGetLegacyWallEdgeCeilingPointLimit(fromUp)
    if not root then return CFG.SurfaceSwitchDistance end
    local up = safeUnit(fromUp, UP)
    local planarSpeed = projectOnPlane(root.AssemblyLinearVelocity, up).Magnitude
    local commandedSpeed = 0
    if humanoid then
        commandedSpeed = math.max(0, tonumber(humanoid.WalkSpeed) or 0)
    end
    local transitionSpeed = math.max(planarSpeed, commandedSpeed)
    local speedLead = math.clamp((transitionSpeed - 14) * 0.75, 0, 2.25)
    local pointLimit = 2.75 + speedLead
    wwWallDiag("WW_LEGACY_EDGE_CEILING_SPEED_LIMIT",
        "walkSpeed=" .. string.format("%.2f", commandedSpeed)
            .. ", planarSpeed=" .. string.format("%.2f", planarSpeed)
            .. ", speedBasis=max(planarSpeed,walkSpeed)=" .. string.format("%.2f", transitionSpeed)
            .. ", pointLimit=" .. string.format("%.2f", pointLimit),
        0.50
    )
    return pointLimit
end

-- The scanner uses the old bounded hit-point reach only when ordinary floor
-- body/plane contact rejects the target and input or velocity points toward it.
-- Keep this helper separate from the large scanner to reduce live registers.
function wwGetWallEdgeFloorCandidateGate(point, normal, fromUp, moveVector)
    local accepted, surfaceGap, planeGap, tangentGap, tangentLimit, movingToward,
        inputToward, velocityToward =
        wwGetWallEdgeFloorContact(point, normal, fromUp, moveVector)
    if not point or not root then
        return accepted, surfaceGap, false, math.huge
    end
    local pointDistance = (point - root.Position).Magnitude
    local legacyFallback = not accepted
        and movingToward
        and pointDistance <= CFG.SurfaceSwitchDistance
    local auditInfo = nil
    if wwEdgeForensicScan then
        auditInfo = wwEdgeForensicFloorGateInfo
        auditInfo.contactAccepted = accepted
        auditInfo.planeGap = planeGap
        auditInfo.tangentGap = tangentGap
        auditInfo.tangentLimit = tangentLimit
        auditInfo.movingToward = movingToward
        auditInfo.inputToward = inputToward
        auditInfo.velocityToward = velocityToward
        auditInfo.planeLimit = CFG.VerticalSurfaceContactGap + 0.10
        auditInfo.pointLimit = CFG.SurfaceSwitchDistance
    end
    return accepted or legacyFallback, surfaceGap, legacyFallback, pointDistance, auditInfo
end

-- Select the legacy transition mechanism only for the two requested edge routes.
-- Other transitions still run through wwAuthorizeTransitionCandidate unchanged.
function wwGetLegacyWallEdgeHandoffRoute(fromUp, toUp, hasCandidate, legacyRoute, hit, normal, moveVector, switchBackBlocked, sourceSupportSeen)
    legacyEdgeFloorQualificationReason = nil
    if not hasCandidate or legacyRoute ~= "edge" or not root then return nil end
    if not hit or not hit.Instance or not hit.Instance.Parent or not hit.Position or not normal then
        return nil
    end
    local up = safeUnit(fromUp, UP)
    local targetUp = safeUnit(toUp, up)
    if math.abs(up:Dot(UP)) >= 0.985 then return nil end
    if safeUnit(normal, targetUp):Dot(targetUp) < 0.90 then return nil end

    local pointDistance = (hit.Position - root.Position).Magnitude
    local pointLimit = 0
    local routeName = nil
    local floorGuardOverride = false
    if targetUp:Dot(UP) >= 0.985 then
        pointLimit = CFG.SurfaceSwitchDistance
        local contactAccepted, surfaceGap, planeGap, tangentGap, tangentLimit,
            movingToward, inputToward, velocityToward =
            wwGetWallEdgeFloorContact(hit.Position, normal, up, moveVector)
        local floorGrounded = getGrounded(UP)
        -- Do not let the long GroundProbeLength ray claim the floor is ready
        -- while the body is still climbing the source wall. A valid handoff needs
        -- measured body-plane contact and a bounded tangent offset. While the
        -- floor-to-wall return lock is active, velocity alone must not override it:
        -- the character can still be carrying momentum toward the old floor.
        local boundedDistance = pointDistance <= pointLimit
        local directionalNearContact = inputToward
            and boundedDistance
            and surfaceGap <= CFG.VerticalSurfaceContactGap + 0.25
            and planeGap <= CFG.VerticalSurfaceContactGap + 0.25
            and tangentGap <= tangentLimit
        local contactQualified = false
        local qualificationBranch = "rejected-no-qualification-branch"
        if contactAccepted and inputToward then
            contactQualified = true
            qualificationBranch = "contactAccepted-and-inputToward"
        elseif directionalNearContact and (not switchBackBlocked or inputToward) then
            contactQualified = true
            qualificationBranch = "boundedDirectionalNearContact"
        elseif contactAccepted and not switchBackBlocked and surfaceGap <= 0.08 then
            -- A true near-zero landing may settle without input after the guard ends;
            -- a nearby floor or inherited momentum alone cannot trigger a handoff.
            contactQualified = true
            qualificationBranch = "contactAccepted-nearZeroSurfaceGap-noSwitchback"
        elseif wwQualifiesGroundedWallEdgeFloorApproach(
            pointDistance, surfaceGap, planeGap, tangentGap, tangentLimit,
            movingToward, floorGrounded, sourceSupportSeen
        ) then
            -- Preserve the existing grounded, direction-qualified recovery first.
            contactQualified = true
            qualificationBranch = "grounded-floor-approach-after-source-support-loss"
        elseif wwQualifiesLostSupportWallEdgeFloorHandoff(
            pointDistance, surfaceGap, planeGap, tangentGap, tangentLimit, sourceSupportSeen
        ) then
            -- The scanner has already confirmed support loss and a close, top-facing
            -- floor. Do not require reverse input or a grounded Humanoid flag here.
            contactQualified = true
            qualificationBranch = "bounded-floor-proximity-after-source-support-loss"
        end
        if wwWallDiagDue("EDGE_FLOOR_HANDOFF_GATE", 0.20) then
            wwWallDiag("EDGE_FLOOR_HANDOFF_GATE",
                "outcome=" .. tostring(contactQualified)
                    .. ", qualification=" .. qualificationBranch
                    .. ", target=" .. wwEdgeForensicInstancePath(hit.Instance)
                    .. ", point=" .. wwEdgeForensicVector(hit.Position)
                    .. ", normal=" .. wwEdgeForensicVector(normal)
                    .. ", root=" .. wwEdgeForensicVector(root.Position)
                    .. ", pointDist=" .. string.format("%.3f", pointDistance)
                    .. ", pointLimit=" .. string.format("%.3f", pointLimit)
                    .. ", pointWithinLimit=" .. tostring(boundedDistance)
                    .. ", contactAccepted=" .. tostring(contactAccepted)
                    .. ", surfaceGap=" .. string.format("%.3f", surfaceGap)
                    .. ", planeGap=" .. string.format("%.3f", planeGap)
                    .. ", tangentGap=" .. string.format("%.3f", tangentGap)
                    .. ", tangentLimit=" .. string.format("%.3f", tangentLimit)
                    .. ", movingToward=" .. tostring(movingToward)
                    .. ", inputToward=" .. tostring(inputToward)
                    .. ", velocityToward=" .. tostring(velocityToward)
                    .. ", switchbackBlocked=" .. tostring(switchBackBlocked)
                    .. ", floorGrounded=" .. tostring(floorGrounded)
                    .. ", sourceSupportSeen=" .. tostring(sourceSupportSeen == true),
                0.20
            )
        end
        if contactQualified then
            legacyEdgeFloorQualificationReason = qualificationBranch
            routeName = "wall-edge-to-floor"
            if switchBackBlocked then
                floorGuardOverride = true
                wwWallDiag("WW_LEGACY_EDGE_FLOOR_GUARD_OVERRIDE",
                    "reason=" .. tostring(qualificationBranch)
                        .. ", planeGap=" .. string.format("%.2f", planeGap)
                        .. ", tangentGap=" .. string.format("%.2f", tangentGap)
                        .. ", tangentLimit=" .. string.format("%.2f", tangentLimit)
                        .. ", pointDist=" .. string.format("%.2f", pointDistance)
                        .. ", movingToward=" .. tostring(movingToward)
                        .. ", inputToward=" .. tostring(inputToward)
                        .. ", velocityToward=" .. tostring(velocityToward),
                    0.12
                )
            end
        elseif switchBackBlocked and surfaceGap <= CFG.VerticalSurfaceContactGap + 0.10 then
            wwWallDiag("WW_LEGACY_EDGE_HANDOFF_DEFERRED",
                "route=wall-edge-to-floor, reason=contact-direction-not-confirmed"
                    .. ", pointDist=" .. string.format("%.2f", pointDistance)
                    .. ", planeGap=" .. string.format("%.2f", planeGap)
                    .. ", tangentGap=" .. string.format("%.2f", tangentGap)
                    .. ", tangentLimit=" .. string.format("%.2f", tangentLimit)
                    .. ", movingToward=" .. tostring(movingToward)
                    .. ", inputToward=" .. tostring(inputToward)
                    .. ", velocityToward=" .. tostring(velocityToward),
                0.12
            )
        elseif pointDistance <= pointLimit + 1.00
            or surfaceGap <= CFG.VerticalSurfaceContactGap + 0.50 then
            wwWallDiag("WW_LEGACY_EDGE_FLOOR_GATE_REJECTED",
                "pointDist=" .. string.format("%.2f", pointDistance)
                    .. ", pointLimit=" .. string.format("%.2f", pointLimit)
                    .. ", contactAccepted=" .. tostring(contactAccepted)
                    .. ", groundedFloor=" .. tostring(floorGrounded)
                    .. ", boundedDistance=" .. tostring(boundedDistance)
                    .. ", surfaceGap=" .. string.format("%.2f", surfaceGap)
                    .. ", planeGap=" .. string.format("%.2f", planeGap)
                    .. ", tangentGap=" .. string.format("%.2f", tangentGap)
                    .. ", tangentLimit=" .. string.format("%.2f", tangentLimit)
                    .. ", movingToward=" .. tostring(movingToward)
                    .. ", switchbackBlocked=" .. tostring(switchBackBlocked),
                0.12
            )
        end
    elseif targetUp:Dot(UP) <= -0.985 then
        pointLimit = wwGetLegacyWallEdgeCeilingPointLimit(up)
        local legacyHit, legacyNormal = findLegacyWallEdgeCeilingSurface(up, moveVector)
        if legacyHit and legacyNormal then
            pointDistance = (legacyHit.Position - root.Position).Magnitude
            if pointDistance <= pointLimit and safeUnit(legacyNormal, targetUp):Dot(targetUp) >= 0.90 then
                transitionCandidateHit = legacyHit
                transitionCandidateNormal = safeUnit(legacyNormal, targetUp)
                routeName = "wall-edge-to-ceiling-underside"
            end
        end
    end

    if routeName then
        wwWallDiag("WW_LEGACY_EDGE_HANDOFF_SELECTED",
            "route=" .. routeName
                .. ", pointDist=" .. string.format("%.2f", pointDistance)
                .. ", pointLimit=" .. string.format("%.2f", pointLimit),
            0.12
        )
    end
    return routeName, floorGuardOverride
end

function getDirectionalEdgeHorizontalSpeedLead(oldUp, moveVector, targetNormal)
    if not root or not targetNormal then return 0 end
    local up = safeUnit(oldUp, UP)
    local worldMove = ZERO
    if moveVector and moveVector.Magnitude > 0.05 then
        worldMove = getWorldMove(moveVector, up)
    end
    local verticalMove = worldMove:Dot(UP)
    local verticalVelocity = root.AssemblyLinearVelocity:Dot(UP)

    if targetNormal:Dot(UP) >= 0.985 then
        if math.abs(verticalMove) > 0.06 then
            if verticalMove < -0.06 then
                return getEdgeHorizontalSpeedLead(up, moveVector)
            end
        elseif verticalVelocity < -0.50 then
            return getEdgeHorizontalSpeedLead(up, moveVector)
        end
    elseif targetNormal:Dot(UP) <= -0.985 then
        if math.abs(verticalMove) > 0.06 then
            if verticalMove > 0.06 then
                return getEdgeHorizontalSpeedLead(up, moveVector)
            end
        elseif verticalVelocity > 0.50 then
            return getEdgeHorizontalSpeedLead(up, moveVector)
        end
    end
    return 0
end



-- Release an edge-only source-wall hold only for a deliberate ordinary wall
-- transition. Velocity by itself is not sufficient: leftover momentum should not
-- defeat the anti-flip guard. This helper is shared by the two hold state checks.
function wwIsIntentionalSourceWallTransition(hit, currentUp, moveVector)
    if not root or not hit or not hit.Position then return false, math.huge end
    local _, inputTowardWall = isMovementTowardSurfacePoint(hit.Position, currentUp, moveVector)
    local gap = getCharacterSurfaceGap(hit.Position)
    local accepted = inputTowardWall and gap <= CFG.VerticalSurfaceContactGap + 0.10
    return accepted, gap
end
]=] },
    { name = '00c_grounded_wall_floor_approach_gate', source = [=[
-- Permit a narrow wall-edge -> floor handoff when the current support
-- sensor explicitly reports that the old wall is no longer supporting the
-- character, a floor is grounded below, and tangent motion is aimed toward it.
-- This is not a generic nearby-floor fallback.
function wwQualifiesGroundedWallEdgeFloorApproach(pointDistance, surfaceGap, planeGap, tangentGap, tangentLimit, movingToward, floorGrounded, sourceSupportSeen)
    if not floorGrounded then return false end
    if sourceSupportSeen ~= false then return false end
    if not movingToward then return false end
    if pointDistance > CFG.SurfaceSwitchDistance + 1.50 then return false end
    if surfaceGap > CFG.VerticalSurfaceContactGap + 2.50 then return false end
    if planeGap > CFG.VerticalSurfaceContactGap + 1.50 then return false end
    if tangentGap > tangentLimit + 1.25 then return false end
    return true
end

-- A wall-edge fall can lose support while the player's input still points up the
-- wall. In that case, a floor directly below the body must not be discarded just
-- because input/velocity is not aimed at it. This is stricter than the grounded
-- approach recovery above: it requires explicit source-support loss and bounded
-- body-plane and tangent geometry, not merely a long ground-probe hit.
function wwQualifiesLostSupportWallEdgeFloorHandoff(pointDistance, surfaceGap, planeGap, tangentGap, tangentLimit, sourceSupportSeen)
    if sourceSupportSeen ~= false then return false end
    if pointDistance > CFG.SurfaceSwitchDistance + CFG.WallEdgeFloorLostSupportPointLead then return false end
    if surfaceGap > CFG.WallEdgeFloorLostSupportSurfaceGap then return false end
    if planeGap > CFG.WallEdgeFloorLostSupportPlaneGap then return false end
    if tangentGap > tangentLimit + CFG.WallEdgeFloorLostSupportTangentExtra then return false end
    return true
end
]=] },
    { name = '01_guardTransitionOutwardVelocity', source = [=[function guardTransitionOutwardVelocity()
    if not root or not customActive or jumped then return end
    if os.clock() >= orientationTransitionUntil then return end

    local velocity = root.AssemblyLinearVelocity
    local outwardSpeed = velocity:Dot(currentUp)
    local maxOutward = CFG.TransitionMaxOutwardSpeed

    if outwardSpeed > maxOutward then
        root.AssemblyLinearVelocity = velocity - currentUp * (outwardSpeed - maxOutward)
    end
end
gravitySwitchBackUp =  nil
gravitySwitchBackAt =  0
ceilingToWallLock = nil
floorToWallLock = nil
safetySupportPoint =  nil
safetySupportNormal =  nil
safetySupportDistance =  nil
safetySupportAt =  0
surfaceSupportSeen =  false
surfaceSupportPoint =  nil
surfaceSupportNormal =  nil
surfaceSupportDistance =  math.huge

-- Motion history used by the safety handoff. We intentionally track position
-- and world-down speed instead of relying only on ray visibility.
safetyPreviousPosition =  nil
safetyPreviousWorldDownSpeed =  0
safetyAwayDistance =  0
safetyAwaySpeed =  0
safetyWorldFallSpeed =  0
safetyWorldFallAcceleration =  0

filteredAdhesionDistance =  nil

microStepBlend =  0
microStepTargetBlend =  0
microStepUntil =  0
microStepMove =  Vector3.zero

stairStepBlend =  0
stairStepTargetBlend =  0
stairStepUntil =  0
stairStepMove =  Vector3.zero

-- Continuous stair traversal state. The state follows the staircase as
-- the player moves from one riser to the next instead of locking to one
-- physical step for a single short timer.
stairTraversalActive =  false
stairTraversalUntil =  0
stairTraversalPoint =  nil
stairTraversalNormal =  nil
stairTraversalMoveDir =  nil
stairTraversalTopHeight =  nil
stairTraversalTopPoint =  nil

animateScript = nil
animateWasDisabled =  false
animator = nil
animationTracks =  {Idle = {}, Walk = {}, Run = {}, Jump = {}, Fall = {}}
activeLocomotion = nil
activeAir = nil
activeIdle = nil
emoteTrack = nil
AnimationClipProvider =  game:GetService("AnimationClipProvider")
emoteLoopCache =  {}
emoteTrackConnection = nil
emoteHandlerGuardConnection = nil
installWallWalkEmoteHandler = nil
emoteMenuOpen =  false
emoteStateBridge =  false
emoteStateRestoreAt =  0

gui = nil
toggleButton = nil
cameraPOVButton = nil
cameraPOVEnabled =  true
cameraModuleObject = nil
cameraModuleOriginalUpdate = nil
cameraModuleOriginalOwnUpdate = nil
wrappedCameraModuleUpdate = nil
cameraModuleHookInstalled =  false
restoreCameraModuleHook = nil
cameraUpVector =  UP
cameraUpFrame =  CFrame.identity
cameraCollisionParams =  RaycastParams.new()
cameraCollisionParams.FilterType = Enum.RaycastFilterType.Exclude
cameraCollisionParams.IgnoreWater = true
cameraCollisionCharacter = nil
jumpButton = nil
guiConnections =  {}
lifecycleConnections =  {}
heartbeatConnection = nil
cameraConnection = nil
destroyed =  false
GUIControlled = (VGD_WallWalk_GUIControlled == true)
setJumpButtonVisible = nil

-- Snapshot Roblox-owned state so the X button can leave no WallWalk residue.
originalState =  {
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

]=] },
    { name = '02_safeUnit', source = [=[function safeUnit(v, fallback)
    if typeof(v) ~= "Vector3" then
        return fallback or UP
    end
    if v.Magnitude > 1e-5 then
        return v.Unit
    end
    return fallback or UP
end
]=] },
    { name = '03_projectOnPlane', source = [=[function projectOnPlane(v, normal)
    return v - normal * v:Dot(normal)
end

-- Transport a direction through the exact shortest rotation that maps the
-- previous surface normal to the new surface normal. Projection alone is not
-- enough for FORWARD transitions: when the old movement direction points
-- toward the new surface, its projection onto that new plane can collapse or
-- choose an arbitrary fallback. Rotating the tangent frame preserves the
-- actual path around the corner instead.]=] },
    { name = '04_transportDirection', source = [=[function transportDirection(oldDirection, oldUp, newUp)
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
]=] },
    { name = '05_stopTrack', source = [=[function stopTrack(track, fade)
    if track and track.IsPlaying then
        pcall(function() track:Stop(fade or 0.08) end)
    end
end
]=] },
    { name = '06_stopGroup', source = [=[function stopGroup(group, fade)
    for _, track in ipairs(group or {}) do
        stopTrack(track, fade)
    end
end
]=] },
    { name = '07_destroyAnimationTracks', source = [=[function destroyAnimationTracks()
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
]=] },
    { name = '08_loadAnimationGroup', source = [=[function loadAnimationGroup(container)
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
]=] },
    { name = '09_loadCharacterAnimations', source = [=[function loadCharacterAnimations()
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
        if priority == Enum.AnimationPriority.Action or priority == Enum.AnimationPriority.Action2 or priority == Enum.AnimationPriority.Action3 or priority == Enum.AnimationPriority.Action4 then
            emoteTrack = track
            track.Stopped:Connect(function()
                if emoteTrack == track then
                    emoteTrack = nil
                end
            end)
        end
    end)
end
]=] },
    { name = '10_cancelActiveEmote', source = [=[function cancelActiveEmote()
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
]=] },
    { name = '11_updateAnimations', source = [=[local filteredLocomotionSpeed = nil

local function stopWallWalkLocomotion(fade)
    if activeLocomotion ~= nil then
        stopGroup(animationTracks.Walk, fade)
        stopGroup(animationTracks.Run, fade)
        activeLocomotion = nil
    end
    filteredLocomotionSpeed = nil
end

local function ensureLocomotionTrack(track, fade, smallWeight)
    if not track then return false end

    local targetWeight = track.WeightTarget
    local needsStart = not track.IsPlaying or targetWeight <= 0.00001
    if needsStart then
        pcall(function()
            track:Play(fade, smallWeight, 1)
        end)
    end
    return needsStart
end

local function setLocomotionWeight(track, weight, fade)
    if not track or not track.IsPlaying then return end
    local targetWeight = track.WeightTarget
    if targetWeight == nil or math.abs(targetWeight - weight) > 0.015 then
        pcall(function()
            track:AdjustWeight(weight, fade)
        end)
    end
end

local function setLocomotionSpeed(track, speed)
    if not track or not track.IsPlaying then return end
    local currentSpeed = track.Speed
    if currentSpeed == nil or math.abs(currentSpeed - speed) > 0.025 then
        pcall(function()
            track:AdjustSpeed(speed)
        end)
    end
end

function updateAnimations(moving, grounded, speed, deltaTime)
    if not animator then return end

    -- Movement cancels an emote. Check this before the active-emote early return
    -- so locomotion cannot trap the emote in place.
    local movingNow = moving
    if humanoid and humanoid.MoveDirection.Magnitude > 0.05 then
        movingNow = true
    end
    if emoteTrack and emoteTrack.IsPlaying and movingNow then
        cancelActiveEmote()
    end

    -- Never restart locomotion while an emote is active.
    if emoteTrack and emoteTrack.IsPlaying then
        stopWallWalkLocomotion(0.08)
        stopTrack(activeIdle, 0.08)
        activeIdle = nil
        stopTrack(activeAir, 0.08)
        activeAir = nil
        return
    end

    if not grounded then
        stopWallWalkLocomotion(0.06)
        stopTrack(activeIdle, 0.06)
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

    if not movingNow then
        -- Match the idle fade-in to the locomotion fade-out. The shorter old
        -- fade made the gait appear to snap when custom gravity owned Animate.
        stopWallWalkLocomotion(0.20)
        local idle = animationTracks.Idle[1]
        if idle then
            if activeIdle ~= idle then
                stopTrack(activeIdle, 0.20)
                activeIdle = idle
            end
            if not idle.IsPlaying or idle.WeightTarget <= 0.00001 then
                pcall(function() idle:Play(0.20, 1, 1) end)
            end
        end
        return
    end

    -- Cross-fade idle out over the same interval used to fade Walk/Run in.
    stopTrack(activeIdle, 0.20)
    activeIdle = nil

    local movementSpeed = CFG.WalkSpeed
    if humanoid then
        local liveWalkSpeed = tonumber(humanoid.WalkSpeed)
        if liveWalkSpeed and liveWalkSpeed >= 0 then
            movementSpeed = liveWalkSpeed
        end
    end
    local speedBase = math.max(movementSpeed, 1)

    local rawSpeed = math.max(0, tonumber(speed) or 0)
    local dt = tonumber(deltaTime)
    if not dt or dt <= 0 then
        dt = 1 / 60
    end
    dt = math.min(dt, 0.1)

    -- AssemblyLinearVelocity can spike while the wall controller applies
    -- contact/adhesion corrections. Filter the measured tangent speed so one
    -- physics sample cannot flip the locomotion blend from all-walk to all-run.
    if filteredLocomotionSpeed == nil then
        filteredLocomotionSpeed = rawSpeed
    else
        local alpha = math.clamp(dt / 0.12, 0, 1)
        filteredLocomotionSpeed = filteredLocomotionSpeed
            + (rawSpeed - filteredLocomotionSpeed) * alpha
    end
    local animationSpeed = filteredLocomotionSpeed

    local walkTrack = animationTracks.Walk[1]
    local runTrack = animationTracks.Run[1]
    local smallWeight = 0.0001
    local blendTime = 0.2

    if walkTrack and runTrack then
        -- Follow the default R15 Animate pattern: keep both locomotion tracks
        -- available and cross-fade their weights rather than repeatedly
        -- stopping and restarting the selected track.
        local walkWasActive = walkTrack.IsPlaying and walkTrack.WeightTarget > 0.00001
        local runWasActive = runTrack.IsPlaying and runTrack.WeightTarget > 0.00001
        local syncPhase = nil

        if walkWasActive and walkTrack.Length > 0 then
            syncPhase = math.clamp(walkTrack.TimePosition / walkTrack.Length, 0, 1)
        elseif runWasActive and runTrack.Length > 0 then
            syncPhase = math.clamp(runTrack.TimePosition / runTrack.Length, 0, 1)
        end

        local walkNeedsStart = ensureLocomotionTrack(walkTrack, blendTime, smallWeight)
        local runNeedsStart = ensureLocomotionTrack(runTrack, blendTime, smallWeight)

        -- New/restarted tracks join the existing gait phase to avoid a visible
        -- cycle reset when the blend weights change.
        if syncPhase ~= nil then
            if walkNeedsStart and walkTrack.Length > 0 then
                pcall(function()
                    walkTrack.TimePosition = syncPhase * walkTrack.Length
                end)
            end
            if runNeedsStart and runTrack.Length > 0 then
                pcall(function()
                    runTrack.TimePosition = syncPhase * runTrack.Length
                end)
            end
        elseif walkNeedsStart and runNeedsStart
            and walkTrack.Length > 0 and runTrack.Length > 0 then
            pcall(function()
                runTrack.TimePosition =
                    (walkTrack.TimePosition / walkTrack.Length) * runTrack.Length
            end)
        end

        -- This follows the common R15 blend range: Run fades in gradually from
        -- roughly 40% of configured WalkSpeed and reaches full weight near 73%.
        -- Preserve WallWalk's existing per-track playback-rate tuning.
        local normalizedRunSpeed = animationSpeed * 1.25
            / math.max(speedBase * 0.90625, 0.01)
        local runWeight = math.clamp((normalizedRunSpeed - 0.5) / 0.5, 0, 1)
        local walkWeight = 1 - runWeight

        local walkPlaybackSpeed = math.clamp(
            animationSpeed / math.max(speedBase * 0.62, 0.01), 0.35, 1.4)
        local runPlaybackSpeed = math.clamp(
            animationSpeed / math.max(speedBase * 0.72, 0.01), 0.35, 1.4)

        setLocomotionWeight(walkTrack, math.max(smallWeight, walkWeight), blendTime)
        setLocomotionWeight(runTrack, math.max(smallWeight, runWeight), blendTime)
        setLocomotionSpeed(walkTrack, walkPlaybackSpeed)
        setLocomotionSpeed(runTrack, runPlaybackSpeed)

        local dominantTrack = walkTrack
        local dominantMode = "Walk"
        if runWeight > walkWeight then
            dominantTrack = runTrack
            dominantMode = "Run"
        end
        activeLocomotion = dominantTrack

        wwWallDiag("WW_ANIMATION_BLEND_STATE",
            "dominant=" .. dominantMode
                .. ", rawSpeed=" .. string.format("%.2f", rawSpeed)
                .. ", filteredSpeed=" .. string.format("%.2f", animationSpeed)
                .. ", walkWeight=" .. string.format("%.3f", walkWeight)
                .. ", runWeight=" .. string.format("%.3f", runWeight)
                .. ", walkPlayback=" .. string.format("%.2f", walkPlaybackSpeed)
                .. ", runPlayback=" .. string.format("%.2f", runPlaybackSpeed)
                .. ", walkSpeed=" .. string.format("%.2f", movementSpeed)
                .. ", walkTrackPlaying=" .. tostring(walkTrack.IsPlaying)
                .. ", runTrackPlaying=" .. tostring(runTrack.IsPlaying),
            0.25
        )
        return
    end

    -- Fallback for characters whose Animate script provides only one locomotion
    -- track. This path retains the existing single-track behavior.
    local track = runTrack or walkTrack
    if not track then return end

    if activeLocomotion ~= track then
        stopTrack(activeLocomotion, blendTime)
        activeLocomotion = track
    end
    if not track.IsPlaying or track.WeightTarget <= 0.00001 then
        pcall(function() track:Play(blendTime, 1, 1) end)
    end

    local referenceSpeed = movementSpeed
        * (track == runTrack and 0.72 or 0.62)
    local playbackSpeed = math.clamp(
        animationSpeed / math.max(referenceSpeed, 0.01), 0.35, 1.4)
    setLocomotionSpeed(track, playbackSpeed)

    wwWallDiag("WW_ANIMATION_BLEND_STATE",
        "dominant=" .. (track == runTrack and "RunOnly" or "WalkOnly")
            .. ", rawSpeed=" .. string.format("%.2f", rawSpeed)
            .. ", filteredSpeed=" .. string.format("%.2f", animationSpeed)
            .. ", playback=" .. string.format("%.2f", playbackSpeed)
            .. ", walkTrackAvailable=" .. tostring(walkTrack ~= nil)
            .. ", runTrackAvailable=" .. tostring(runTrack ~= nil),
        0.25
    )
end
]=] },
    { name = '12_installWallWalkEmoteHandler', source = [=[function installWallWalkEmoteHandler()
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
]=] },
    { name = '13_getPlayerControls', source = [=[function getPlayerControls()
    local scripts = player:FindFirstChildOfClass("PlayerScripts")
    local module = scripts and scripts:FindFirstChild("PlayerModule")
    if not module then return nil end

    local ok, playerModule = pcall(require, module)
    if not ok or not playerModule or not playerModule.GetControls then return nil end

    local success, result = pcall(function() return playerModule:GetControls() end)
    return success and result or nil
end
]=] },
    { name = '14_getMoveVector', source = [=[function getMoveVector()
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
]=] },
    { name = '15_cast', source = [=[function cast(origin, direction, length)
    if not rayParams or direction.Magnitude <= 1e-5 then return nil end

    -- Player characters are not valid WallWalk gravity surfaces. If a ray
    -- first hits another player's character, exclude that character and cast
    -- again so map geometry behind them can still be detected.
    local originalFilter = rayParams.FilterDescendantsInstances
    local castFilter = {}
    for i = 1, #originalFilter do
        castFilter[#castFilter + 1] = originalFilter[i]
    end

    local unitDirection = direction.Unit
    local result = nil
    local attempts = 0

    while attempts < 8 do
        rayParams.FilterDescendantsInstances = castFilter
        result = workspace:Raycast(origin, unitDirection * length, rayParams)
        if not result then break end

        local hitModel = result.Instance and result.Instance:FindFirstAncestorOfClass("Model")
        local hitPlayer = hitModel and Players:GetPlayerFromCharacter(hitModel)
        if not hitPlayer or hitPlayer == player then
            break
        end

        castFilter[#castFilter + 1] = hitModel
        attempts = attempts + 1
    end

    rayParams.FilterDescendantsInstances = originalFilter
    if result then
        local finalModel = result.Instance and result.Instance:FindFirstAncestorOfClass("Model")
        local finalPlayer = finalModel and Players:GetPlayerFromCharacter(finalModel)
        if finalPlayer and finalPlayer ~= player then
            return nil
        end
    end
    return result
end
]=] },
    { name = '16_orientSurfaceNormal', source = [=[function orientSurfaceNormal(hit, rayDirection)
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
]=] },
    { name = '17_getExactSupportFace', source = [=[function getExactSupportFace(oldUp, moveVector)
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
-- riser when a valid walkable top is confirmed ahead.]=] },
    { name = '18_confirmStairRiser', source = [=[function confirmStairRiser(basePoint, moveDir, side, rise, up)
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
                    if facing >= CFG.StairStepRiserMinDot and up:Dot(n) < 0.35 and height <= rise + 0.24 then
                        return true
                    end
                end
            end
        end
    end
    return false
end

-- First-riser gravity guard.
-- A short stair riser should not be able to become a gravity plane merely
-- because a probe hits its vertical face. A real wall continues above the
-- maximum supported step height, so a short high slice through the same face
-- distinguishes the two. This is independent of stairTraversal state.]=] },
    { name = '19_hasVerticalWallContinuation', source = [=[function hasVerticalWallContinuation(hit, normal, up, moveDir)
    if not hit or not normal or not moveDir or moveDir.Magnitude <= 0.05 then
        return false
    end

    local floorOrCeiling = math.abs(up:Dot(UP)) > 0.985
    if not floorOrCeiling then
        return true
    end

    local facing = (-moveDir):Dot(normal)
    if facing < CFG.StairStepRiserMinDot then
        return false
    end

    local nearVertical = math.abs(normal:Dot(UP)) < CFG.StairRiserGravityVerticalDot
    if not nearVertical then
        return true
    end

    -- Start slightly outside the hit face and probe the same corridor above
    -- normal stair height. A full wall still produces a matching vertical hit;
    -- a one-step riser does not.
    local highOrigin = hit.Position
        - moveDir * 0.10
        + up * CFG.StairRiserContinuationHeight

    local highHit = cast(
        highOrigin,
        moveDir,
        CFG.StairRiserContinuationLength
    )

    if not highHit then
        return false
    end

    local highNormal = orientSurfaceNormal(highHit, moveDir)
    if not highNormal then
        return false
    end

    local highFacing = (-moveDir):Dot(highNormal)
    if highFacing < CFG.StairStepRiserMinDot then
        return false
    end

    return math.abs(highNormal:Dot(UP)) < CFG.TransitionWallDot
end
]=] },
    { name = '20_getStairMoveDirection', source = [=[function getStairMoveDirection(up, moveVector)
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
]=] },
    { name = '21_clearStairTraversal', source = [=[function clearStairTraversal()
    stairTraversalActive = false
    stairTraversalUntil = 0
    stairTraversalPoint = nil
    stairTraversalNormal = nil
    stairTraversalMoveDir = nil
    stairTraversalTopHeight = nil
    stairTraversalTopPoint = nil
end
]=] },
    { name = '22_detectStairRiserGeometry', source = [=[function detectStairRiserGeometry(oldUp, moveVector)
    if not root or not humanoid then return false end

    local moveDir = getStairMoveDirection(oldUp, moveVector)
    if not moveDir then return false end

    local side = safeUnit(moveDir:Cross(oldUp), root.CFrame.RightVector)

    local maxRise = CFG.StairStepMaxHeight
    local probeUp = oldUp
    if oldUp:Dot(UP) < -0.985 then
        probeUp = -oldUp
    end
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
    local bestTopPoint = nil
    local bestScore = math.huge

    for _, sideOffset in ipairs(offsets) do
        for _, forwardStart in ipairs(forwardStarts) do
            for _, heightOffset in ipairs(riserHeights) do
                local riserOrigin = basePoint
                    + side * sideOffset
                    + moveDir * forwardStart
                    + probeUp * heightOffset

                local riserHit = cast(riserOrigin, moveDir, probeLength)

                if riserHit then
                    local riserNormal = orientSurfaceNormal(riserHit, moveDir)

                    if riserNormal then
                        local facing = (-moveDir):Dot(riserNormal)
                        local surfaceDot = math.abs(oldUp:Dot(riserNormal))
                        local riserRise = (riserHit.Position - basePoint):Dot(oldUp)
                        if oldUp:Dot(UP) < -0.985 then
                            riserRise = -riserRise
                        end
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
                                + probeUp * (maxRise + 0.34)

                            local topHit = cast(topOrigin, -probeUp, topProbeLength)

                            if topHit then
                                local topNormal = orientSurfaceNormal(topHit, -probeUp)

                                if topNormal then
                                    local topNormalDot = oldUp:Dot(topNormal)
                                    local topHeight = topHit.Position:Dot(oldUp)
                                    local topRise = topHeight - baseHeight
                                    if oldUp:Dot(UP) < -0.985 then
                                        topRise = -topRise
                                    end
                                    local topRun = (topHit.Position - root.Position):Dot(moveDir)
                                    local runAfter = topRun - riserRun

                                    local topNormalValid = topNormalDot > 0.955
                                    local topRiseValid = topRise >= CFG.StairStepMinRise
                                        and topRise <= maxRise + 0.15
                                    -- The detected stair top must still be AHEAD of the
                                    -- root. Without this lower bound, a riser that is
                                    -- already under/behind the character could keep the
                                    -- gravity detector in stair-ownership mode even
                                    -- though the movement solver has nothing left to climb.
                                    -- The first stair can be very close to the R15 root.
                                    -- Only require the top to be beyond the riser itself.
                                    local topRunValid = runAfter >= 0.02
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
                                                bestTopPoint = topHit.Position
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

    return true, bestPoint, bestNormal, moveDir, bestTopHeight, bestTopPoint
end
]=] },
    { name = '23_isStairRiserAhead', source = [=[function isStairRiserAhead(oldUp, moveVector)
    local now = os.clock()
    local moveDir = getStairMoveDirection(oldUp, moveVector)

    if not moveDir then
        if stairTraversalActive and now < stairTraversalUntil then
            return true
        end

        clearStairTraversal()
        return false
    end

    local detected, point, normal, detectedMoveDir, topHeight, topPoint = detectStairRiserGeometry(oldUp, moveVector)

    if detected then
        stairTraversalActive = true
        stairTraversalUntil = now + CFG.StairTraversalHoldTime
        stairTraversalPoint = point
        stairTraversalNormal = normal
        stairTraversalMoveDir = detectedMoveDir
        stairTraversalTopHeight = topHeight
        stairTraversalTopPoint = topPoint
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
]=] },
    { name = '24_isOwnedStairRiserHit', source = [=[function isOwnedStairRiserHit(hit, normal, oldUp, moveDir)
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
]=] },
    { name = '24b_radial_edge_wall_acquisition', source = [=[
-- Source-oriented forensic trace for the radial wall-acquisition path used
-- while gravity is floor/ceiling aligned. This is diagnostic-only state.
wwRadialEdgeForensic = nil
wwRadialEdgeForensicLastScanAt = 0

function wwBeginRadialEdgeForensicScan(oldUp, origin, moveDir, stairRiserAhead)
    local now = os.clock()
    if not root or now - (wwRadialEdgeForensicLastScanAt or 0) < 0.50 then
        wwRadialEdgeForensic = nil
        return
    end
    wwRadialEdgeForensicLastScanAt = now
    wwRadialEdgeForensic = {
        at = now,
        sourceUp = oldUp,
        rootPosition = origin,
        moveDir = moveDir,
        stairRiserAhead = stairRiserAhead == true,
        hits = {},
        counts = {},
        resolver = "not-run-yet",
        resolvedPart = nil,
        resolvedPosition = nil,
        resolvedNormal = nil,
        resolvedDistance = math.huge,
        initialAccept = nil,
        finalAccept = nil,
        rejection = "not-evaluated-yet",
        maxRadialDistance = nil,
        sideOK = nil,
    }
end

function wwRecordRadialEdgeForensic(hit, normal, rayIndex, origin, oldUp, rayDirection, reason)
    local scan = wwRadialEdgeForensic
    if not scan or not hit or not hit.Instance or not normal then return end
    scan.counts[reason] = (scan.counts[reason] or 0) + 1
    local delta = hit.Position - origin
    local distance = delta.Magnitude
    local drop = -delta:Dot(oldUp)
    local key = tostring(reason)
    local prior = scan.hits[key]
    if prior and prior.distance <= distance then return end
    local rayUnit = rayDirection and safeUnit(rayDirection, ZERO) or ZERO
    local probeOrigin = hit.Position
    if rayUnit.Magnitude > 0.05 and type(hit.Distance) == "number" then
        probeOrigin = hit.Position - rayUnit * hit.Distance
    end
    scan.hits[key] = {
        reason = reason,
        rayIndex = rayIndex,
        instance = hit.Instance,
        className = hit.Instance.ClassName,
        position = hit.Position,
        normal = normal,
        rayOrigin = probeOrigin,
        rayDirection = rayUnit,
        rayHitDistance = hit.Distance,
        rootDistance = distance,
        drop = drop,
        normalWorldUpDot = normal:Dot(UP),
        normalSourceUpDot = normal:Dot(oldUp),
        canCollide = nil,
        canQuery = nil,
    }
    local partOk, partIsBase = pcall(function() return hit.Instance:IsA("BasePart") end)
    if partOk and partIsBase then
        local flagsOk, collideValue, queryValue = pcall(function()
            return hit.Instance.CanCollide, hit.Instance.CanQuery
        end)
        if flagsOk then
            scan.hits[key].canCollide = collideValue
            scan.hits[key].canQuery = queryValue
        end
    end
end

function wwDescribeRadialEdgeForensicHit(item)
    if not item then return "NONE" end
    local path = "none"
    if item.instance then
        local ok, value = pcall(function() return item.instance:GetFullName() end)
        if ok then path = tostring(value) end
    end
    return "reason=" .. tostring(item.reason)
        .. ",rayIndex=" .. tostring(item.rayIndex)
        .. ",part=" .. path
        .. ",class=" .. tostring(item.className)
        .. ",CanCollide=" .. tostring(item.canCollide)
        .. ",CanQuery=" .. tostring(item.canQuery)
        .. ",rayOrigin=" .. wwEdgeForensicVector(item.rayOrigin)
        .. ",rayDir=" .. wwEdgeForensicVector(item.rayDirection)
        .. ",rayHitDist=" .. string.format("%.3f", tonumber(item.rayHitDistance) or math.huge)
        .. ",hit=" .. wwEdgeForensicVector(item.position)
        .. ",normal=" .. wwEdgeForensicVector(item.normal)
        .. ",normalWorldUpDot=" .. string.format("%.3f", item.normalWorldUpDot)
        .. ",normalSourceUpDot=" .. string.format("%.3f", item.normalSourceUpDot)
        .. ",rootPointDist=" .. string.format("%.3f", item.rootDistance)
        .. ",sourceDrop=" .. string.format("%.3f", item.drop)
end

function wwEmitRadialEdgeForensicScan(radialState, supportSeen, transitionRoute, transitionHit, transitionNormal, transitionDistance)
    local scan = wwRadialEdgeForensic
    if not scan then return end
    local clusterParts = {}
    for _, cluster in ipairs(radialState and radialState.clusters or {}) do
        local path = "none"
        if cluster.bestHit and cluster.bestHit.Instance then
            local ok, value = pcall(function() return cluster.bestHit.Instance:GetFullName() end)
            if ok then path = tostring(value) end
        end
        table.insert(clusterParts, "{part=" .. path
            .. ",samples=" .. tostring(cluster.sampleCount or 0)
            .. ",distance=" .. string.format("%.3f", tonumber(cluster.bestDistance) or math.huge)
            .. ",maxDrop=" .. string.format("%.3f", tonumber(cluster.maxDrop) or -math.huge)
            .. ",normal=" .. wwEdgeForensicVector(cluster.bestNormal) .. "}")
    end
    local counts = {}
    for reason, count in pairs(scan.counts) do
        table.insert(counts, tostring(reason) .. ":" .. tostring(count))
    end
    table.sort(counts)
    local resolved = "NONE"
    if scan.resolvedPart then
        local ok, value = pcall(function() return scan.resolvedPart:GetFullName() end)
        if ok then resolved = tostring(value) end
    end
    local function describeHit(hit)
        if not hit or not hit.Instance then return "NONE" end
        local path = "none"
        local ok, value = pcall(function() return hit.Instance:GetFullName() end)
        if ok then path = tostring(value) end
        return path .. "@" .. wwEdgeForensicVector(hit.Position)
    end
    local detail = "sourceUp=" .. wwEdgeForensicVector(scan.sourceUp)
        .. ",root=" .. wwEdgeForensicVector(scan.rootPosition)
        .. ",moveDir=" .. wwEdgeForensicVector(scan.moveDir)
        .. ",stairRiserAhead=" .. tostring(scan.stairRiserAhead)
        .. ",supportSeen=" .. tostring(supportSeen == true)
        .. ",clusterCount=" .. tostring(radialState and #radialState.clusters or 0)
        .. ",clusters=" .. table.concat(clusterParts, ";")
        .. ",rawGateCounts=" .. table.concat(counts, ";")
        .. ",nearestByGate={"
    local gates = {}
    for reason, item in pairs(scan.hits) do
        table.insert(gates, "[" .. tostring(reason) .. "]=" .. wwDescribeRadialEdgeForensicHit(item))
    end
    table.sort(gates)
    detail = detail .. table.concat(gates, " | ") .. "}"
        .. ",resolver=" .. tostring(scan.resolver)
        .. ",resolved=" .. resolved
        .. ",resolvedPos=" .. wwEdgeForensicVector(scan.resolvedPosition)
        .. ",resolvedNormal=" .. wwEdgeForensicVector(scan.resolvedNormal)
        .. ",resolvedDist=" .. string.format("%.3f", tonumber(scan.resolvedDistance) or math.huge)
        .. ",initialAccept=" .. tostring(scan.initialAccept)
        .. ",finalAccept=" .. tostring(scan.finalAccept)
        .. ",rejectReason=" .. tostring(scan.rejection)
        .. ",maxRadialDist=" .. tostring(scan.maxRadialDistance)
        .. ",sideOK=" .. tostring(scan.sideOK)
        .. ",transitionRoute=" .. tostring(transitionRoute or "none")
        .. ",transitionHit=" .. describeHit(transitionHit)
        .. ",transitionNormal=" .. wwEdgeForensicVector(transitionNormal)
        .. ",transitionDist=" .. string.format("%.3f", tonumber(transitionDistance) or math.huge)
        .. ",physicalEdgeDiscontinuity=not-directly-measured-by-this-radial-detector"
    wwWallDiag("RADIAL_EDGE_SOURCE_FORENSIC", detail, 0.50)
    wwRadialEdgeForensic = nil
end

function registerRadialEdgeWallHit(state, hit, normal, rayIndex, origin, oldUp, rayDirection)
    if not state or not hit or not normal then return end
    if math.abs(normal:Dot(UP)) >= CFG.StairRiserGravityVerticalDot then
        pcall(wwRecordRadialEdgeForensic, hit, normal, rayIndex, origin, oldUp, rayDirection, "rejected-horizontal-normal")
        return
    end
    if math.abs(oldUp:Dot(normal)) >= CFG.TransitionWallDot then
        pcall(wwRecordRadialEdgeForensic, hit, normal, rayIndex, origin, oldUp, rayDirection, "rejected-normal-aligned-to-source")
        return
    end

    local delta = hit.Position - origin
    local distance = delta.Magnitude
    if distance > CFG.RadialEdgeWallMaxDistance then
        pcall(wwRecordRadialEdgeForensic, hit, normal, rayIndex, origin, oldUp, rayDirection, "rejected-too-far")
        return
    end

    local drop = -delta:Dot(oldUp)
    if drop < CFG.RadialEdgeWallMinDrop then
        pcall(wwRecordRadialEdgeForensic, hit, normal, rayIndex, origin, oldUp, rayDirection, "rejected-insufficient-source-drop")
        return
    end

    -- Do not flip a back-facing hit. A ray can see the far side of a wall
    -- before the character has actually reached that face.
    local horizontalDelta = delta - oldUp * delta:Dot(oldUp)
    local candidateNormal = safeUnit(normal, UP)
    if horizontalDelta.Magnitude > 0.10 then
        if candidateNormal:Dot(horizontalDelta) > 0.10 then
            pcall(wwRecordRadialEdgeForensic, hit, normal, rayIndex, origin, oldUp, rayDirection, "rejected-back-facing")
            return
        end
    end
    pcall(wwRecordRadialEdgeForensic, hit, normal, rayIndex, origin, oldUp, rayDirection, "registered-into-cluster")

    local cluster = nil
    for _, item in ipairs(state.clusters) do
        if item.normal:Dot(candidateNormal) >= CFG.RadialEdgeWallNormalDot then
            cluster = item
            break
        end
    end

    if not cluster then
        cluster = {
            normal = candidateNormal,
            samples = {},
            sampleCount = 0,
            bestHit = hit,
            bestNormal = candidateNormal,
            bestDistance = distance,
            maxDrop = drop,
        }
        table.insert(state.clusters, cluster)
    end

    -- Store the latest hit per radial ray index, not only a boolean. The
    -- resolver revalidates its distance/drop from the current root position.
    cluster.samples[rayIndex] = {
        hit = hit,
        normal = candidateNormal,
        time = os.clock(),
    }
end

function pruneRadialEdgeWallState(state, oldUp)
    if not state or not root then return end

    local now = os.clock()
    for clusterIndex = #state.clusters, 1, -1 do
        local cluster = state.clusters[clusterIndex]
        cluster.sampleCount = 0
        cluster.maxDrop = -math.huge
        cluster.bestDistance = math.huge
        cluster.bestHit = nil
        cluster.bestNormal = nil

        for rayIndex, sample in pairs(cluster.samples) do
            local valid = type(sample) == "table"
                and sample.hit ~= nil
                and now - (sample.time or 0) <= CFG.RadialEdgeWallEvidenceWindow

            if valid then
                local delta = sample.hit.Position - root.Position
                local distance = delta.Magnitude
                local drop = -delta:Dot(oldUp)
                valid = distance <= CFG.RadialEdgeWallMaxDistance
                    and drop >= CFG.RadialEdgeWallMinDrop

                if valid then
                    cluster.sampleCount = cluster.sampleCount + 1
                    if drop > cluster.maxDrop then
                        cluster.maxDrop = drop
                    end
                    if distance < cluster.bestDistance then
                        cluster.bestDistance = distance
                        cluster.bestHit = sample.hit
                        cluster.bestNormal = sample.normal
                    end
                end
            end

            if not valid then
                cluster.samples[rayIndex] = nil
            end
        end

        if cluster.sampleCount == 0 then
            table.remove(state.clusters, clusterIndex)
        end
    end
end

function hasRadialWallContinuation(hit, normal, up)
    if not hit or not normal then return false end
    if math.abs(normal:Dot(UP)) >= CFG.StairRiserGravityVerticalDot then return false end

    -- Probe the same face above the sample without using movement direction.
    -- A short stair riser normally ends before this height; a long wall persists.
    local probeOrigin = hit.Position
        + up * CFG.StairRiserContinuationHeight
        + normal * 0.10
    local highHit = cast(probeOrigin, -normal, CFG.StairRiserContinuationLength)
    if not highHit then return false end

    local highNormal = orientSurfaceNormal(highHit, -normal)
    if not highNormal then return false end
    return math.abs(highNormal:Dot(normal)) >= 0.75
end

function resolveRadialEdgeWall(state, oldUp, moveDir, stairRiserAhead)
    if not state then return nil, nil, math.huge end
    if stairRiserAhead then return nil, nil, math.huge end

    pruneRadialEdgeWallState(state, oldUp)
    local chosen = nil
    local twoSampleFallback = nil
    for _, cluster in ipairs(state.clusters) do
        if cluster.sampleCount >= CFG.RadialEdgeWallMinSamples then
            if not chosen or cluster.bestDistance < chosen.bestDistance then
                chosen = cluster
            end
        elseif cluster.sampleCount >= 2 then
            if not twoSampleFallback or cluster.bestDistance < twoSampleFallback.bestDistance then
                twoSampleFallback = cluster
            end
        end
    end

    -- A two-ray cluster is permitted only if it either continues above the
    -- ordinary step height, or the hit evidence already spans that much drop.
    if not chosen and twoSampleFallback then
        local hit = twoSampleFallback.bestHit
        local normal = twoSampleFallback.bestNormal
        local tallEnough = twoSampleFallback.maxDrop >= CFG.StairRiserContinuationHeight + 0.15
        if tallEnough or hasRadialWallContinuation(hit, normal, oldUp) then
            chosen = twoSampleFallback
        end
    end

    if not chosen or not chosen.bestHit or not chosen.bestNormal then
        return nil, nil, math.huge
    end
    if chosen.maxDrop < CFG.RadialEdgeWallMinDrop then
        return nil, nil, math.huge
    end

    -- Keep cached stair-traversal ownership protection, but never require a
    -- move direction merely to observe a wall under the edge.
    if moveDir and moveDir.Magnitude > 0.05 then
        if isOwnedStairRiserHit(chosen.bestHit, chosen.bestNormal, oldUp, moveDir) then
            return nil, nil, math.huge
        end
    end

    return safeUnit(chosen.bestNormal, oldUp), chosen.bestHit, chosen.bestDistance
end
]=] },
    { name = '24c_floor_wall_edge_transition_timing', source = [=[function getEdgeWallContactDistance(referenceHit, referenceNormal, up, maxDistance)
    if not root or not referenceHit or not referenceHit.Instance then
        return math.huge
    end

    local normal = safeUnit(referenceNormal, UP)
    local bestDistance = math.huge

    -- Sample across the body's height so a downward fan hit does not have to
    -- be physically close to the root's exact 3D point. Every accepted sample
    -- must ray-hit the wall plane itself at the current character height.
    for _, heightOffset in ipairs(CFG.EdgeTransitionProbeOffsets) do
        local probeOrigin = root.Position + up * heightOffset
        local contactHit = cast(probeOrigin, -normal, maxDistance)

        if contactHit and contactHit.Instance then
            local contactNormal = orientSurfaceNormal(contactHit, -normal)
            if contactNormal and contactNormal:Dot(normal) >= 0.80 then
                local planeOffset = math.abs(
                    (contactHit.Position - referenceHit.Position):Dot(normal)
                )
                local samePart = contactHit.Instance == referenceHit.Instance

                -- Also permit separate, coplanar wall parts, but reject a
                -- different parallel wall that merely lies along the same ray.
                if samePart or planeOffset <= 0.65 then
                    if contactHit.Distance < bestDistance then
                        bestDistance = contactHit.Distance
                    end
                end
            end
        end
    end

    return bestDistance
end

function updateFloorWallEdgeTransition(candidateHit, candidateNormal, oldUp, moveDir, allowFastLead, routeName, moveMagnitude)
    if not root then
        edgeTransitionPending = nil
        forwardTransitionPending = nil
        return nil, nil
    end

    local route = routeName == "forward" and "forward" or "edge"
    local now = os.clock()
    local up = safeUnit(oldUp, UP)
    local floorOrCeiling = math.abs(up:Dot(UP)) > 0.985
    if not floorOrCeiling then
        edgeTransitionPending = nil
        forwardTransitionPending = nil
        return nil, nil
    end

    local pending
    if route == "forward" then
        pending = forwardTransitionPending
    else
        pending = edgeTransitionPending
    end

    if candidateHit and candidateHit.Instance and candidateNormal
        and math.abs(candidateNormal:Dot(UP)) < CFG.StairRiserGravityVerticalDot
    then
        -- One route owns the pending transition at a time. New evidence from
        -- either route invalidates the other route's stale pending face.
        if route == "forward" then
            edgeTransitionPending = nil
        else
            forwardTransitionPending = nil
        end
        local normal = safeUnit(candidateNormal, UP)
        local replacePending = not pending

        if pending then
            if not pending.normal or not pending.oldUp then
                replacePending = true
            elseif pending.oldUp:Dot(up) < 0.90 then
                replacePending = true
            elseif pending.normal:Dot(normal) < 0.88 then
                replacePending = true
            elseif pending.route ~= route then
                replacePending = true
            elseif now - (pending.lastSeen or 0) > CFG.EdgeTransitionPendingLifetime then
                replacePending = true
            end
        end

        if replacePending then
            pending = {
                hit = candidateHit,
                normal = normal,
                oldUp = up,
                route = route,
                lastSeen = now,
            }
        else
            pending.hit = candidateHit
            pending.normal = normal
            pending.oldUp = up
            pending.route = route
            pending.lastSeen = now
        end

        if route == "forward" then
            forwardTransitionPending = pending
        else
            edgeTransitionPending = pending
        end
    end

    if route == "forward" then
        pending = forwardTransitionPending
    else
        pending = edgeTransitionPending
    end
    if not pending then return nil, nil end

    if not pending.hit or not pending.hit.Instance or not pending.hit.Instance.Parent
        or not pending.normal or not pending.oldUp
        or pending.oldUp:Dot(up) < 0.90
        or pending.route ~= route
        or now - (pending.lastSeen or 0) > CFG.EdgeTransitionPendingLifetime
    then
        if route == "forward" then
            forwardTransitionPending = nil
        else
            edgeTransitionPending = nil
        end
        return nil, nil
    end

    local velocity = root.AssemblyLinearVelocity
    local planarSpeed = projectOnPlane(velocity, up).Magnitude
    local commandedSpeed = 0
    if humanoid then
        commandedSpeed = math.max(0, tonumber(humanoid.WalkSpeed) or 0)
            * math.clamp(tonumber(moveMagnitude) or 0, 0, 1)
    end
    local transitionSpeed = math.max(planarSpeed, commandedSpeed)
    local speedLead = 0

    -- Speed-based surface-gap lead belongs only to classified floor/ceiling
    -- edge -> vertical-wall-underneath routes. Ordinary forward approaches remain
    -- fixed-gap at every speed.
    if route == "edge" and math.abs(up:Dot(UP)) >= 0.985 then
        speedLead = math.clamp(
            planarSpeed * CFG.EdgeTransitionContactSpeedLead,
            0,
            CFG.EdgeTransitionContactSpeedLeadMax
        )
        if allowFastLead ~= false then
            if up:Dot(UP) >= 0.985 then
                -- Match the floor-edge controller's bounded, direction-qualified lead.
                speedLead = wwGetFloorEdgeRouteLead(up, moveVector, pending.hit.Position)
            else
                -- Ceiling-edge lead remains unchanged.
                local fastSpeedLead = math.clamp(
                    (transitionSpeed - 9) * 0.1875,
                    0,
                    CFG.EdgeUndersideFastContactLeadMax
                )
                if fastSpeedLead > speedLead then
                    speedLead = fastSpeedLead
                end
            end
        end
    end
    -- Ray length is detection only. All forward transitions use the same physical
    -- surface-gap acceptance; speed can widen only the dedicated edge route.
    local contactProbeReach = CFG.TransitionProbeLength
    local surfaceGapLimit = CFG.VerticalSurfaceContactGap
    if route == "edge" then
        surfaceGapLimit = surfaceGapLimit + speedLead
    end
    local candidateSurfaceGap = getCharacterSurfaceGap(pending.hit.Position)
    if route == "edge" then
        -- Keep the established speed-assisted platform-edge -> wall-underneath
        -- route's previous candidate metric; ordinary forward routes use body parts.
        candidateSurfaceGap = getLegacyCharacterBoundsGap(pending.hit.Position)
    end
    local wallDistance = getEdgeWallContactDistance(
        pending.hit,
        pending.normal,
        up,
        contactProbeReach
    )

    -- The height-spread probes can all miss a confirmed face at an edge even
    -- though the accepted candidate itself proves that the same wall plane is
    -- directly reachable. Use the candidate's perpendicular plane distance only
    -- as a miss fallback, and only when the actual candidate point is also close.
    if wallDistance == math.huge and pending.hit.Position then
        local candidatePointDistance = (pending.hit.Position - root.Position).Magnitude
        local candidatePlaneDistance = math.abs((root.Position - pending.hit.Position):Dot(safeUnit(pending.normal, up)))
        -- Removed the old +1.35 hit-point allowance. The fallback must satisfy
        -- the same body-to-surface gap as the direct contact route.
        if candidatePlaneDistance <= contactProbeReach and candidateSurfaceGap <= surfaceGapLimit then
            wallDistance = candidatePlaneDistance
            wwWallDiag("PLANE_TO_WALL_CONTACT_FALLBACK",
                "route=" .. route
                    .. ", fromUpY=" .. string.format("%.2f", up:Dot(UP))
                    .. ", pointDist=" .. string.format("%.2f", candidatePointDistance)
                    .. ", planeDist=" .. string.format("%.2f", candidatePlaneDistance)
                    .. ", surfaceGap=" .. string.format("%.2f", candidateSurfaceGap)
                    .. ", gapLimit=" .. string.format("%.2f", surfaceGapLimit)
                    .. ", probeReach=" .. string.format("%.2f", contactProbeReach),
                0.35
            )
        end
    end

    -- Input need not point at an edge wall. The edge route can be approached
    -- from the side, while the forward route is always contact-gated separately.
    local hasMovement = (moveDir and moveDir.Magnitude > 0.05)
        or velocity.Magnitude > 0.50

    if hasMovement and wallDistance < math.huge and candidateSurfaceGap <= surfaceGapLimit then
        local hit = pending.hit
        local normal = safeUnit(pending.normal, up)
        if route == "forward" then
            forwardTransitionPending = nil
        else
            edgeTransitionPending = nil
        end
        transitionCandidateRoute = route
        transitionCandidateHit = hit
        transitionCandidateNormal = normal
        transitionCandidateSupportGap = false
        wwWallDiag("PLANE_TO_WALL_ROUTE_ACCEPTED",
            "fromUpY=" .. string.format("%.2f", up:Dot(UP))
                .. ", route=" .. route
                .. ", dist=" .. string.format("%.2f", wallDistance)
                .. ", probeReach=" .. string.format("%.2f", contactProbeReach)
                .. ", surfaceGap=" .. string.format("%.2f", candidateSurfaceGap)
                .. ", gapLimit=" .. string.format("%.2f", surfaceGapLimit),
            0.35
        )
        return normal, hit
    end

    if hasMovement then
        wwWallDiag("PLANE_TO_WALL_CONTACT_REJECTED",
            "fromUpY=" .. string.format("%.2f", up:Dot(UP))
                .. ", route=" .. route
                .. ", wallDist=" .. tostring(wallDistance)
                .. ", probeReach=" .. string.format("%.2f", contactProbeReach)
                .. ", pointDist=" .. string.format("%.2f", (pending.hit.Position - root.Position).Magnitude)
                .. ", surfaceGap=" .. string.format("%.2f", candidateSurfaceGap)
                .. ", gapLimit=" .. string.format("%.2f", surfaceGapLimit)
                .. ", moveMag=" .. string.format("%.2f", tonumber(moveMagnitude) or 0),
            0.35
        )
    end

    return nil, nil
end
]=] },
    { name = '24d_falling_radial_wall_acquisition', source = [=[function findFallingRadialWall(oldUp)
    if not root then return nil, nil, math.huge end

    local up = safeUnit(oldUp, UP)
    local axisA = root.CFrame.LookVector:Cross(up)
    if axisA.Magnitude < 1e-4 then
        axisA = root.CFrame.RightVector:Cross(up)
    end
    axisA = safeUnit(axisA, Vector3.xAxis)
    local axisB = safeUnit(up:Cross(axisA), Vector3.zAxis)
    local offsets = {-1.00, -0.35, 0.30, 0.95}
    local clusters = {}

    -- Scan around the body at four heights and twelve angles. The denser fan
    -- reduces missed wall evidence when running moves the character several
    -- studs between sensor updates. This fallback runs only after support is
    -- lost, so ordinary grounded stair risers cannot claim gravity here.
    for heightIndex, heightOffset in ipairs(offsets) do
        local probeOrigin = root.Position + up * heightOffset
        for i = 1, 12 do
            local angle = math.pi * 2 * ((i - 1) / 12)
            local direction = axisA * math.cos(angle) + axisB * math.sin(angle)
            local hit = cast(probeOrigin, direction, 7.00)
            if hit and hit.Instance then
                local normal = orientSurfaceNormal(hit, direction)
                if normal
                    and math.abs(normal:Dot(UP)) < CFG.StairRiserGravityVerticalDot
                    and math.abs(up:Dot(normal)) < CFG.TransitionWallDot
                then
                    local distance = (hit.Position - root.Position).Magnitude
                    local cluster = nil
                    for _, item in ipairs(clusters) do
                        if item.normal:Dot(normal) >= 0.80 then
                            local planeGap = math.abs((hit.Position - item.hit.Position):Dot(item.normal))
                            if hit.Instance == item.hit.Instance or planeGap <= 0.65 then
                                cluster = item
                                break
                            end
                        end
                    end
                    if not cluster then
                        cluster = {
                            hit = hit,
                            normal = normal,
                            distance = distance,
                            heights = {},
                            count = 0,
                            rayCount = 0,
                            rayDirections = {},
                        }
                        table.insert(clusters, cluster)
                    end
                    if not cluster.heights[heightIndex] then
                        cluster.heights[heightIndex] = true
                        cluster.count = cluster.count + 1
                    end
                    local rayKey = tostring(i)
                    if not cluster.rayDirections[rayKey] then
                        cluster.rayDirections[rayKey] = true
                        cluster.rayCount = cluster.rayCount + 1
                    end
                    if distance < cluster.distance then
                        cluster.hit = hit
                        cluster.normal = normal
                        cluster.distance = distance
                    end
                end
            end
        end
    end

    local best = nil
    for _, cluster in ipairs(clusters) do
        if (cluster.count >= 2 or cluster.rayCount >= 3) and (not best or cluster.distance < best.distance) then
            best = cluster
        end
    end
    if not best then return nil, nil, math.huge end
    return best.hit, safeUnit(best.normal, up), best.distance
end
]=] },
    { name = '24e_wall_to_ceiling_acquisition', source = [=[function findWallToCeilingSurface(oldUp, moveVector, approachOnly)
    if not root then return nil, nil end

    local up = safeUnit(oldUp, UP)
    -- This path is only for wall gravity. Floor/ceiling edge acquisition has
    -- its own logic and must not be affected by this scan.
    if math.abs(up:Dot(UP)) >= 0.985 then return nil, nil end

    -- Detection is independent of input direction. When a player loses the
    -- wall and begins falling, their input/velocity may point away from the
    -- ceiling even though the ceiling is the next reachable support surface.

    local side = safeUnit(up:Cross(UP), root.CFrame.RightVector)
    local origins = {
        root.Position,
        root.Position + side * 0.75,
        root.Position - side * 0.75,
        root.Position + up * 0.45,
        root.Position - up * 0.35,
    }
    local directions = {
        UP,
        safeUnit(UP + side * 0.30, UP),
        safeUnit(UP - side * 0.30, UP),
        safeUnit(UP + up * 0.20, UP),
        safeUnit(UP - up * 0.20, UP),
    }

    local bestHit = nil
    local bestNormal = nil
    local bestDistance = math.huge
    local bestSurfaceGap = math.huge
    local confirmations = 0
    local seenParts = {}

    for _, probeOrigin in ipairs(origins) do
        local originConfirmed = false
        for _, direction in ipairs(directions) do
            local velocity = root.AssemblyLinearVelocity
            local planarSpeed = projectOnPlane(velocity, up).Magnitude
            local commandedSpeed = 0
            if humanoid then
                commandedSpeed = math.max(0, tonumber(humanoid.WalkSpeed) or 0)
                    * math.clamp(moveVector and moveVector.Magnitude or 0, 0, 1)
            end
            local transitionSpeed = math.max(planarSpeed, commandedSpeed)
            local probeLength = CFG.TransitionProbeLength + math.clamp(transitionSpeed * 0.10, 0, 3.00)
            local hit = cast(probeOrigin, direction, probeLength)
            if hit and hit.Instance then
                local normal = orientSurfaceNormal(hit, direction)
                if normal and normal:Dot(UP) <= -0.78 then
                    local distance = (hit.Position - root.Position).Magnitude
                    local surfaceGap = getCharacterSurfaceGap(hit.Position)
                    local betterHit = false
                    if approachOnly then
                        betterHit = distance < bestDistance
                    else
                        betterHit = surfaceGap < bestSurfaceGap
                    end
                    if betterHit then
                        bestHit = hit
                        bestNormal = normal
                        bestDistance = distance
                        bestSurfaceGap = surfaceGap
                    end
                    if not originConfirmed then
                        originConfirmed = true
                        confirmations = confirmations + 1
                    end
                    seenParts[hit.Instance] = true
                end
            end
        end
    end

    -- Normal wall-to-ceiling gravity acceptance is a fixed geometric gate.
    -- Probe length may still expand at speed so a fast approach is detected,
    -- but speed must not let a distant ceiling claim gravity early.
    local maxCeilingHandoffDistance = CFG.SurfaceSwitchDistance
    if approachOnly then
        -- This special mode only protects the safety timer while actively
        -- approaching a confirmed ceiling; it does not switch gravity.
        local velocity = root.AssemblyLinearVelocity
        local planarSpeed = projectOnPlane(velocity, up).Magnitude
        local commandedSpeed = 0
        if humanoid then
            commandedSpeed = math.max(0, tonumber(humanoid.WalkSpeed) or 0)
                * math.clamp(moveVector and moveVector.Magnitude or 0, 0, 1)
        end
        local transitionSpeed = math.max(planarSpeed, commandedSpeed)
        local maxApproachDistance = CFG.TransitionProbeLength
            + math.clamp(transitionSpeed * 0.10, 0, 3.00) + 0.75
        maxCeilingHandoffDistance = math.max(maxCeilingHandoffDistance, maxApproachDistance)
    end
    if confirmations >= 2 and bestHit and bestNormal then
        if approachOnly then
            -- Safety grace is still allowed to see an approaching ceiling farther
            -- away; this path only delays safety release and does not switch gravity.
            if bestDistance <= maxCeilingHandoffDistance then
                return bestHit, safeUnit(bestNormal, -UP)
            end
        else
            if bestSurfaceGap <= CFG.VerticalSurfaceContactGap then
                return bestHit, safeUnit(bestNormal, -UP)
            end
        end
    end
    return nil, nil
end

-- A floor hit can be close to a climber without being the surface they are
-- moving onto. Only allow a wall-to-floor handoff when the floor hit is ahead
-- along the character's intended tangent movement on the current wall.
function isWallFloorApproach(oldUp, hit, moveDir)
    if not root or not hit or not hit.Position or not moveDir or moveDir.Magnitude <= 0.05 then
        return false
    end

    local direction = safeUnit(projectOnPlane(moveDir, oldUp), moveDir)
    local toFloor = hit.Position - root.Position

    -- When wall gravity is active, the world floor below the player is not
    -- the intended destination while the player is still climbing upward.
    -- The camera-relative tangent vector can point partly toward a floor hit
    -- near a corner, so explicitly reject this opposing vertical approach.
    if toFloor:Dot(UP) < -0.50 and direction:Dot(UP) > 0.10 then
        return false
    end

    return toFloor:Dot(direction) >= 0.35
end

-- Isolated v48.76.42 ceiling detector for the wall-edge -> ceiling-underside
-- handoff. It retains the old five-origin / five-direction scan and requires hits
-- from at least two origins. It is never used by ordinary wall-to-ceiling routes.
function findLegacyWallEdgeCeilingSurface(oldUp, moveVector)
    if not root then return nil, nil end
    local up = safeUnit(oldUp, UP)
    if math.abs(up:Dot(UP)) >= 0.985 then return nil, nil end

    local side = safeUnit(up:Cross(UP), root.CFrame.RightVector)
    local origins = {
        root.Position,
        root.Position + side * 0.75,
        root.Position - side * 0.75,
        root.Position + up * 0.45,
        root.Position - up * 0.35,
    }
    local directions = {
        UP,
        safeUnit(UP + side * 0.30, UP),
        safeUnit(UP - side * 0.30, UP),
        safeUnit(UP + up * 0.20, UP),
        safeUnit(UP - up * 0.20, UP),
    }

    local bestHit = nil
    local bestNormal = nil
    local bestDistance = math.huge
    local confirmations = 0
    for _, probeOrigin in ipairs(origins) do
        local originConfirmed = false
        for _, direction in ipairs(directions) do
            local planarSpeed = projectOnPlane(root.AssemblyLinearVelocity, up).Magnitude
            local commandedSpeed = 0
            if humanoid then
                commandedSpeed = math.max(0, tonumber(humanoid.WalkSpeed) or 0)
            end
            local transitionSpeed = math.max(planarSpeed, commandedSpeed)
            local probeLength = CFG.TransitionProbeLength
                + math.clamp(transitionSpeed * 0.10, 0, 3.00)
            local hit = cast(probeOrigin, direction, probeLength)
            if hit and hit.Instance then
                local normal = orientSurfaceNormal(hit, direction)
                if normal and normal:Dot(UP) <= -0.78 then
                    local distance = (hit.Position - root.Position).Magnitude
                    if distance < bestDistance then
                        bestHit = hit
                        bestNormal = normal
                        bestDistance = distance
                    end
                    if not originConfirmed then
                        originConfirmed = true
                        confirmations = confirmations + 1
                    end
                end
            end
        end
    end

    local planarSpeed = projectOnPlane(root.AssemblyLinearVelocity, up).Magnitude
    local commandedSpeed = 0
    if humanoid then
        commandedSpeed = math.max(0, tonumber(humanoid.WalkSpeed) or 0)
    end
    local transitionSpeed = math.max(planarSpeed, commandedSpeed)
    local baseLead = math.clamp(transitionSpeed * 0.10, 0, 2.00)
    local fastLead = math.clamp((transitionSpeed - 9) * 0.90, 0, 3.50)
    local maxHandoffDistance = 3.25 + baseLead + fastLead
    if confirmations >= 2 and bestHit and bestNormal and bestDistance <= maxHandoffDistance then
        return bestHit, safeUnit(bestNormal, -UP)
    end
    return nil, nil
end

-- EDGE SYSTEM: while attached to a vertical wall, independently inspect the
-- horizontal plane around the wall edge. This is not the forward-facing system:
-- it samples world-up/world-down from a small tangent fan and only commits when
-- the plane is near and movement, velocity, or a real support gap points to it.
function findWallEdgeHorizontalTransition(oldUp, moveVector, currentSupportSeen)
    if not root then return nil, nil, math.huge end

    local now = os.clock()
    local up = safeUnit(oldUp, UP)
    if math.abs(up:Dot(UP)) >= 0.985 then
        return nil, nil, math.huge
    end

    local worldMove = ZERO
    if moveVector and moveVector.Magnitude > 0.05 then
        worldMove = getWorldMove(moveVector, up)
    end
    local velocity = root.AssemblyLinearVelocity
    local verticalMove = worldMove:Dot(UP)
    local verticalVelocity = velocity:Dot(UP)
    wwBeginEdgeForensicScan(up, moveVector, currentSupportSeen, worldMove, velocity)
    local tangentUp = projectOnPlane(UP, up)
    tangentUp = safeUnit(tangentUp, UP)
    local tangentSide = projectOnPlane(root.CFrame.RightVector, up)
    tangentSide = safeUnit(tangentSide, Vector3.xAxis)
    local offsets = {
        ZERO,
        tangentUp * 0.70,
        -tangentUp * 0.70,
        tangentSide * 0.60,
        -tangentSide * 0.60,
    }

    local bestHit = nil
    local bestNormal = nil
    local bestDistance = math.huge
    local bestRoute = nil
    local bestSurfaceGap = math.huge
    local bestGapLimit = CFG.VerticalSurfaceContactGap
    local bestPointDistance = math.huge
    local bestPointDistanceLimit = 0
    local bestUsedPointDistanceFallback = false
    local bestApproachOnly = false
    local approachFloorHit = nil
    local approachFloorNormal = nil
    local approachFloorDistance = math.huge
    local approachInputToward = false
    local approachVelocityToward = false

    for _, offset in ipairs(offsets) do
        local probeOrigin = root.Position + offset
        local directions = {-UP, UP}

        -- The old floor-edge scanner only cast straight world-down. At the foot
        -- of a wall, the floor may begin forward of the character, so a vertical
        -- ray can miss it until after the 0.20s safety timer releases gravity.
        -- Add target-directed down-slanting probes for floor discovery only.
        -- These rays are for candidate tracking; the 0.25-stud final contact gap
        -- still decides when gravity can actually switch.
        local floorApproachMove = projectOnPlane(worldMove, up)
        if floorApproachMove.Magnitude <= 0.05 then
            -- After the joystick is released, preserve a directional probe along
            -- the actual tangent momentum instead of losing floor discovery.
            floorApproachMove = projectOnPlane(velocity, up)
        end
        if floorApproachMove.Magnitude > 0.05
            and safeUnit(floorApproachMove, ZERO):Dot(UP) <= 0.35
        then
            local floorMoveDirection = safeUnit(floorApproachMove, -UP)
            table.insert(directions, safeUnit(floorMoveDirection - UP * 0.65, -UP))
            table.insert(directions, safeUnit(floorMoveDirection - UP * 1.35, -UP))
        end

        -- A fast wall climb may reach the edge before the vertical probe sits under
        -- the ceiling. On the centre origin only, add two upward/forward rays.
        -- Strict ceiling-normal validation below still distinguishes an underside.
        if offset == ZERO and (verticalMove > 0.06 or verticalVelocity > 0.50) then
            local ceilingLateralMove = projectOnPlane(floorApproachMove, UP)
            if ceilingLateralMove.Magnitude > 0.15 then
                local ceilingSideDirection = safeUnit(ceilingLateralMove, ZERO)
                table.insert(directions, safeUnit(ceilingSideDirection + UP * 0.75, UP))
                table.insert(directions, safeUnit(ceilingSideDirection + UP * 1.50, UP))
            end
        end

        for _, direction in ipairs(directions) do
            local probeLength = CFG.EdgeHorizontalProbeLength
            if direction:Dot(-UP) > 0.20 then
                probeLength = math.max(probeLength, CFG.EdgeFloorApproachProbeLength)
            end
            local hit = cast(probeOrigin, direction, probeLength)
            if hit and hit.Instance then
                local normal = orientSurfaceNormal(hit, direction)
                if normal then
                    -- Classify floor by its oriented surface normal rather than
                    -- requiring a nearly vertical ray; floor-directed probes are
                    -- intentionally angled toward the player's movement.
                    local floorTarget = normal:Dot(UP) >= 0.985
                    local ceilingTarget = normal:Dot(UP) <= -0.985 and direction:Dot(UP) >= 0.45
                    if floorTarget or ceilingTarget then
                        local planeDistance = math.abs((root.Position - hit.Position):Dot(normal))
                        local pointDistance = (root.Position - hit.Position).Magnitude
                        local surfaceGap = getCharacterSurfaceGap(hit.Position)
                        if floorTarget then
                            surfaceGap = getBodyPartFloorContactGap(hit.Position, normal)
                        elseif ceilingTarget then
                            -- This is the tested wall-edge -> underneath-ceiling
                            -- route. Preserve its previous gap metric and speed lead.
                            surfaceGap = getLegacyCharacterBoundsGap(hit.Position)
                        end
                        local movingTowardTarget, inputTowardTarget, velocityTowardTarget =
                            isMovementTowardSurfacePoint(hit.Position, up, moveVector)
                        local hasVerticalInput = math.abs(verticalMove) > 0.06
                        local hasVerticalVelocity = math.abs(verticalVelocity) > 0.75
                        local movingTowardPlane = false
                        local directionCompatible = true
                        local edgeLead = 0

                        if floorTarget then
                            -- Floor-edge intent follows the target along the wall's
                            -- tangent, not just world Y. This supports angled and
                            -- camera-relative joystick movement toward the edge.
                            movingTowardPlane = movingTowardTarget
                            directionCompatible = movingTowardTarget
                                or surfaceGap <= CFG.VerticalSurfaceContactGap
                        else
                            movingTowardPlane = (hasVerticalInput and verticalMove > 0.06)
                                or (not hasVerticalInput and verticalVelocity > 0.50)
                            if hasVerticalInput then
                                directionCompatible = verticalMove > 0.06
                            elseif hasVerticalVelocity then
                                directionCompatible = verticalVelocity > 0.50
                            end
                            -- Match the wall-edge -> ceiling controller's progressive
                            -- speed lead; upward intent/velocity is still required above.
                            if movingTowardPlane then
                                edgeLead = wwGetWallEdgeToCeilingSpeedLead(up, moveVector)
                            end
                        end

                        local maxSurfaceGap = CFG.VerticalSurfaceContactGap + edgeLead
                        local pointDistanceLimit = 0
                        local usedPointDistanceFallback = false
                        local floorGateInfo = nil
                        local withinContactGap = surfaceGap <= maxSurfaceGap
                        if floorTarget then
                            -- Use the same floor geometry as the route controller,
                            -- plus v42's bounded point-distance fallback for this edge only.
                            local floorAccepted, floorContactGap, floorLegacyFallback, floorPointDistance, floorGateInfoResult =
                                wwGetWallEdgeFloorCandidateGate(hit.Position, normal, up, moveVector)
                            floorGateInfo = floorGateInfoResult
                            withinContactGap = floorAccepted
                            surfaceGap = floorContactGap
                            pointDistance = floorPointDistance
                            pointDistanceLimit = CFG.SurfaceSwitchDistance
                            usedPointDistanceFallback = floorLegacyFallback
                            maxSurfaceGap = CFG.VerticalSurfaceContactGap + 0.10
                        elseif ceilingTarget then
                            -- Restore the old speed-scaled edge reach only for this
                            -- route. The later route-specific handoff uses the old point reach
                            -- and a route-only support envelope; ordinary ceiling acquisition
                            -- continues to use its existing fixed geometry gate.
                            pointDistanceLimit = wwGetLegacyWallEdgeCeilingPointLimit(up)
                            usedPointDistanceFallback = surfaceGap > maxSurfaceGap
                                and movingTowardPlane
                                and pointDistance <= pointDistanceLimit
                            withinContactGap = withinContactGap or usedPointDistanceFallback
                        end

                        -- Pre-acquire the floor target while still supported so a
                        -- one-frame support loss does not erase the destination.
                        -- Target direction is normally required; after support is
                        -- explicitly lost, a near floor may instead qualify through
                        -- the bounded body/tangent fallback below.
                        local lostSupportFloorHandoff = false
                        if floorTarget and currentSupportSeen == false then
                            local lostSurfaceGap, lostPlaneGap, lostTangentGap =
                                getBodyPartFloorContactGap(hit.Position, normal)
                            local lostTangentLimit = CFG.FloorContactTangentAllowance + 0.60
                                + getEdgeHorizontalSpeedLead(up, moveVector)
                            lostSupportFloorHandoff = wwQualifiesLostSupportWallEdgeFloorHandoff(
                                pointDistance, lostSurfaceGap, lostPlaneGap, lostTangentGap,
                                lostTangentLimit, currentSupportSeen
                            )
                            if lostSupportFloorHandoff then
                                wwWallDiag("EDGE_FLOOR_LOST_SUPPORT_CANDIDATE",
                                    "sourceSupport=false, pointDist=" .. string.format("%.2f", pointDistance)
                                        .. ", surfaceGap=" .. string.format("%.2f", lostSurfaceGap)
                                        .. ", planeGap=" .. string.format("%.2f", lostPlaneGap)
                                        .. ", tangentGap=" .. string.format("%.2f", lostTangentGap)
                                        .. ", tangentLimit=" .. string.format("%.2f", lostTangentLimit)
                                        .. ", directionCompatible=" .. tostring(directionCompatible)
                                        .. ", directionBypass=true",
                                    0.25
                                )
                            end
                        end
                        local floorApproachEligible = floorTarget
                            and planeDistance <= CFG.EdgeFloorApproachDistance
                            and movingTowardTarget
                        if floorApproachEligible and planeDistance < approachFloorDistance then
                            approachFloorHit = hit
                            approachFloorNormal = normal
                            approachFloorDistance = planeDistance
                            approachInputToward = inputTowardTarget
                            approachVelocityToward = velocityTowardTarget
                        end

                        -- Only return a distant floor as an approach candidate after
                        -- support is actually lost. The final reset still requires
                        -- the same 0.25-stud body-part contact gap as other forward
                        -- transitions.
                        local extendedFloorApproach = (floorApproachEligible or lostSupportFloorHandoff)
                            and currentSupportSeen ~= true
                            and surfaceGap > CFG.VerticalSurfaceContactGap
                        local routeAcceptedForensic = false

                        if withinContactGap or extendedFloorApproach or lostSupportFloorHandoff then
                            local toTarget = projectOnPlane(hit.Position - root.Position, up)
                            local targetAhead = false
                            if worldMove.Magnitude > 0.05 and toTarget.Magnitude > 0.05 then
                                targetAhead = toTarget.Unit:Dot(worldMove.Unit) >= 0.20
                            end

                            local nearSupportGap = currentSupportSeen ~= true
                                and withinContactGap
                            local ambiguousEdgeApproach = not hasVerticalInput and not hasVerticalVelocity
                            local accepted = lostSupportFloorHandoff
                                or (directionCompatible
                                    and (movingTowardPlane
                                        or (ambiguousEdgeApproach and (targetAhead or nearSupportGap))
                                        or extendedFloorApproach
                                        or (floorTarget and withinContactGap)))
                            routeAcceptedForensic = accepted

                            if accepted and planeDistance < bestDistance then
                                bestHit = hit
                                bestNormal = normal
                                bestDistance = planeDistance
                                bestRoute = floorTarget and "wall-edge-to-floor" or "wall-edge-to-ceiling"
                                bestSurfaceGap = surfaceGap
                                bestGapLimit = maxSurfaceGap
                                bestPointDistance = pointDistance
                                bestPointDistanceLimit = lostSupportFloorHandoff
                                    and (CFG.SurfaceSwitchDistance + CFG.WallEdgeFloorLostSupportPointLead)
                                    or pointDistanceLimit
                                bestUsedPointDistanceFallback = usedPointDistanceFallback
                                bestApproachOnly = floorTarget and (extendedFloorApproach or lostSupportFloorHandoff)
                            end
                        end
                        if wwEdgeForensicScan then
                            wwRecordEdgeForensicHit(
                                hit, normal, probeOrigin, direction, probeLength,
                                floorTarget and "floor" or "ceiling",
                                planeDistance, pointDistance, surfaceGap, maxSurfaceGap,
                                withinContactGap, extendedFloorApproach, directionCompatible,
                                movingTowardPlane, movingTowardTarget, inputTowardTarget,
                                velocityTowardTarget, routeAcceptedForensic, floorGateInfo,
                                usedPointDistanceFallback
                            )
                        end
                    end
                end
            end
        end
    end

    -- The radial probe fan can miss a broad floor directly under a character
    -- after wall contact is lost, especially while movement is still upward along
    -- the source wall. Use one centered world-down probe as a bounded fallback.
    -- This only runs when the scanner has no competing target and support is false.
    if not bestHit and currentSupportSeen == false and root then
        local lostFloorProbeLength = CFG.SurfaceSwitchDistance + CFG.WallEdgeFloorLostSupportPointLead
        local lostFloorHit = cast(root.Position, -UP, lostFloorProbeLength)
        if lostFloorHit and lostFloorHit.Instance then
            local lostFloorNormal = orientSurfaceNormal(lostFloorHit, -UP)
            if lostFloorNormal and lostFloorNormal:Dot(UP) >= 0.985 then
                local lostPointDistance = (lostFloorHit.Position - root.Position).Magnitude
                local lostPlaneDistance = math.abs((root.Position - lostFloorHit.Position):Dot(lostFloorNormal))
                local lostSurfaceGap, lostPlaneGap, lostTangentGap =
                    getBodyPartFloorContactGap(lostFloorHit.Position, lostFloorNormal)
                local lostTangentLimit = CFG.FloorContactTangentAllowance + 0.60
                    + getEdgeHorizontalSpeedLead(up, moveVector)
                local lostFloorQualified = wwQualifiesLostSupportWallEdgeFloorHandoff(
                    lostPointDistance, lostSurfaceGap, lostPlaneGap, lostTangentGap,
                    lostTangentLimit, currentSupportSeen
                )
                wwWallDiag("EDGE_FLOOR_LOST_SUPPORT_DIRECT_PROBE",
                    "result=" .. (lostFloorQualified and "accepted" or "rejected-geometry")
                        .. ", target=" .. wwEdgeForensicInstancePath(lostFloorHit.Instance)
                        .. ", pointDist=" .. string.format("%.2f", lostPointDistance)
                        .. ", planeDist=" .. string.format("%.2f", lostPlaneDistance)
                        .. ", surfaceGap=" .. string.format("%.2f", lostSurfaceGap)
                        .. ", planeGap=" .. string.format("%.2f", lostPlaneGap)
                        .. ", tangentGap=" .. string.format("%.2f", lostTangentGap)
                        .. ", tangentLimit=" .. string.format("%.2f", lostTangentLimit)
                        .. ", directionBypass=true",
                    0.25
                )
                if lostFloorQualified then
                    bestHit = lostFloorHit
                    bestNormal = lostFloorNormal
                    bestDistance = lostPlaneDistance
                    bestRoute = "wall-edge-to-floor"
                    bestSurfaceGap = lostSurfaceGap
                    bestGapLimit = CFG.VerticalSurfaceContactGap
                    bestPointDistance = lostPointDistance
                    bestPointDistanceLimit = CFG.SurfaceSwitchDistance + CFG.WallEdgeFloorLostSupportPointLead
                    bestUsedPointDistanceFallback = false
                    bestApproachOnly = true
                end
            else
                wwWallDiag("EDGE_FLOOR_LOST_SUPPORT_DIRECT_PROBE",
                    "result=rejected-normal, target=" .. wwEdgeForensicInstancePath(lostFloorHit.Instance)
                        .. ", normal=" .. wwEdgeForensicVector(lostFloorNormal)
                        .. ", directionBypass=true",
                    0.25
                )
            end
        else
            wwWallDiag("EDGE_FLOOR_LOST_SUPPORT_DIRECT_PROBE",
                "result=no-direct-floor-hit, probeLength=" .. string.format("%.2f", lostFloorProbeLength)
                    .. ", sourceSupport=false",
                0.25
            )
        end
    end

    wwEmitEdgeForensicScan(bestHit, bestNormal, bestRoute, bestDistance)

    if approachFloorHit then
        edgeFloorApproachHit = approachFloorHit
        edgeFloorApproachNormal = approachFloorNormal
        edgeFloorApproachAt = now
        wwWallDiag("EDGE_FLOOR_APPROACH_TRACKED",
            "planeDist=" .. string.format("%.2f", approachFloorDistance)
                .. ", surfaceGap=" .. string.format("%.2f", (getBodyPartFloorContactGap(approachFloorHit.Position, approachFloorNormal)))
                .. ", inputToward=" .. tostring(approachInputToward)
                .. ", velocityToward=" .. tostring(approachVelocityToward)
                .. ", support=" .. tostring(currentSupportSeen),
            0.35
        )
    elseif bestRoute == "wall-edge-to-floor" and bestSurfaceGap <= CFG.VerticalSurfaceContactGap then
        clearEdgeFloorApproach()
    elseif now - (edgeFloorApproachAt or 0) > CFG.EdgeFloorApproachCandidateLifetime then
        clearEdgeFloorApproach()
    end

    if bestHit and bestNormal then
        wwWallDiag("EDGE_HORIZONTAL_CANDIDATE",
            "route=" .. tostring(bestRoute)
                .. ", dist=" .. string.format("%.2f", bestDistance)
                .. ", surfaceGap=" .. string.format("%.2f", bestSurfaceGap)
                .. ", maxGap=" .. string.format("%.2f", bestGapLimit)
                .. ", pointDist=" .. string.format("%.2f", bestPointDistance)
                .. ", pointLimit=" .. string.format("%.2f", bestPointDistanceLimit)
                .. ", pointFallback=" .. tostring(bestUsedPointDistanceFallback)
                .. ", approachOnly=" .. tostring(bestApproachOnly)
                .. ", moveY=" .. string.format("%.2f", verticalMove)
                .. ", velY=" .. string.format("%.2f", verticalVelocity)
                .. ", support=" .. tostring(currentSupportSeen)
                .. ", floorApproachReach=" .. string.format("%.2f", CFG.EdgeFloorApproachProbeLength),
            0.35
        )
        if bestRoute == "wall-edge-to-floor" and bestApproachOnly then
            wwWallDiag("EDGE_FLOOR_APPROACH_ONLY_CANDIDATE",
                "qualification=approach-only-not-contact-confirmed"
                    .. ", planeDist=" .. string.format("%.2f", bestDistance)
                    .. ", surfaceGap=" .. string.format("%.2f", bestSurfaceGap)
                    .. ", gapLimit=" .. string.format("%.2f", CFG.VerticalSurfaceContactGap)
                    .. ", moveY=" .. string.format("%.2f", verticalMove)
                    .. ", velY=" .. string.format("%.2f", verticalVelocity),
                0.20
            )
        end
        return bestHit, bestNormal, bestDistance
    end

    return nil, nil, math.huge
end
]=] },
    { name = '24f_transition_route_core', source = [=[
-- Exact-route controller core. Geometry probes supply candidates; these
-- controllers independently decide whether each route may proceed.
function wwIsManagedTransitionRoute(routeName)
    return routeName == "floor-to-wall"
        or routeName == "floor-edge-to-wall-underside"
        or routeName == "wall-to-ceiling"
        or routeName == "wall-edge-to-ceiling-underside"
        or routeName == "ceiling-to-wall"
        or routeName == "ceiling-edge-to-wall-underside"
        or routeName == "wall-to-floor"
        or routeName == "wall-edge-to-floor"
end

function wwClearTransitionRouteState(routeName, terminalPhase, reason, stateOverride)
    if not routeName then return end
    local state = stateOverride
    if not state and transitionRouteStates then
        state = transitionRouteStates[routeName]
    end
    if state then
        wwSetTransitionPipelinePhase(state, terminalPhase or "aborted", os.clock(), reason or "route-state-cleared")
    end
end
function wwResetTransitionRouteStates()
    transitionRouteStates = {}
    transitionResolvedRoute = nil
end

function wwGetFloorEdgeRouteLead(fromUp, moveVector, targetPoint)
    local up = safeUnit(fromUp, UP)
    local planarSpeed = 0
    if root then
        planarSpeed = projectOnPlane(root.AssemblyLinearVelocity, up).Magnitude
    end
    local commandedSpeed = 0
    if humanoid then
        commandedSpeed = math.max(0, tonumber(humanoid.WalkSpeed) or 0)
            * math.clamp(moveVector and moveVector.Magnitude or 0, 0, 1)
    end
    local transitionSpeed = math.max(planarSpeed, commandedSpeed)
    local lead = math.clamp(
        planarSpeed * CFG.EdgeTransitionContactSpeedLead,
        0,
        CFG.EdgeTransitionContactSpeedLeadMax
    )

    local movingToward = false
    local inputToward = false
    local velocityToward = false
    if targetPoint and root then
        movingToward, inputToward, velocityToward =
            isMovementTowardSurfacePoint(targetPoint, up, moveVector)
    end

    -- Direction-confirmed contact keeps its existing limit. If direction evidence
    -- is absent, allow only a smaller near-miss cap when the floor-edge target point
    -- is physically close; the caller still requires a real wall-plane ray hit.
    local fastLeadLimit = CFG.EdgeUndersideFastContactLeadMax
    local nearMissCapActive = false
    if movingToward then
        fastLeadLimit = CFG.FloorEdgeUndersideFastContactLeadMax
    elseif targetPoint and root and up:Dot(UP) >= 0.985
        and (targetPoint - root.Position).Magnitude <= CFG.FloorEdgeUndersideUndirectedNearMissPointLimit
    then
        fastLeadLimit = CFG.FloorEdgeUndersideUndirectedNearMissLeadMax
        nearMissCapActive = true
    end
    local fastLead = math.clamp((transitionSpeed - 9) * 0.90, 0, fastLeadLimit)
    if fastLead > lead then
        lead = fastLead
    end

    local minLeadApplied = false
    if movingToward and lead < CFG.FloorEdgeUndersideMinContactLead then
        lead = CFG.FloorEdgeUndersideMinContactLead
        minLeadApplied = true
    end

    if targetPoint and root and wwWallDiagDue("FLOOR_EDGE_UNDERSIDE_CONTACT_LEAD", 0.25) then
        wwWallDiag("FLOOR_EDGE_UNDERSIDE_CONTACT_LEAD",
            "directedToward=" .. tostring(movingToward)
                .. ", inputToward=" .. tostring(inputToward)
                .. ", velocityToward=" .. tostring(velocityToward)
                .. ", planarSpeed=" .. string.format("%.2f", planarSpeed)
                .. ", commandedSpeed=" .. string.format("%.2f", commandedSpeed)
                .. ", baseLead=" .. string.format("%.2f", math.clamp(
                    planarSpeed * CFG.EdgeTransitionContactSpeedLead, 0, CFG.EdgeTransitionContactSpeedLeadMax))
                .. ", minLeadApplied=" .. tostring(minLeadApplied)
                .. ", nearMissCapActive=" .. tostring(nearMissCapActive)
                .. ", effectiveLead=" .. string.format("%.2f", lead)
                .. ", gapLimit=" .. string.format("%.2f", CFG.VerticalSurfaceContactGap + lead)
                .. ", candidatePointDist=" .. string.format("%.2f", (targetPoint - root.Position).Magnitude),
            0.25
        )
    end
    return lead
end

-- Progressive contact lead for wall-edge -> ceiling underside and ceiling-edge
-- -> wall underside. It reaches 2.25 studs at WS 21, rather than hitting the cap
-- at low speeds; normal contact rules for non-edge routes are unchanged.
function wwGetUndersideEdgeSpeedLead(fromUp, moveVector)
    local planarSpeed = 0
    if root then
        planarSpeed = projectOnPlane(root.AssemblyLinearVelocity, safeUnit(fromUp, UP)).Magnitude
    end
    local commandedSpeed = 0
    if humanoid then
        commandedSpeed = math.max(0, tonumber(humanoid.WalkSpeed) or 0)
            * math.clamp(moveVector and moveVector.Magnitude or 0, 0, 1)
    end
    local transitionSpeed = math.max(planarSpeed, commandedSpeed)
    local baseLead = math.clamp(
        planarSpeed * CFG.EdgeTransitionContactSpeedLead,
        0,
        CFG.EdgeTransitionContactSpeedLeadMax
    )
    local fastLead = math.clamp(
        (transitionSpeed - 9) * 0.1875,
        0,
        CFG.EdgeUndersideFastContactLeadMax
    )
    if fastLead > baseLead then
        baseLead = fastLead
    end
    return baseLead
end

function wwClassifyTransitionRoute(fromUp, toUp, legacyRoute)
    if not fromUp or not toUp then return nil end
    if legacyRoute ~= "forward" and legacyRoute ~= "edge" then return nil end

    local fromY = safeUnit(fromUp, UP):Dot(UP)
    local toY = safeUnit(toUp, UP):Dot(UP)
    local fromHorizontalPlane = math.abs(fromY) >= 0.985
    -- Wall-to-ceiling acquisition already accepts underside normals well short
    -- of perfectly horizontal. Keep floor handoffs strict, but classify a clear
    -- underside (Y <= -0.90) as a ceiling destination so it receives the managed
    -- route's bounded support grace instead of a short generic "forward" lease.
    local toFloorPlane = toY >= 0.985
    local toCeilingUnderside = toY <= -0.90
    local toWall = math.abs(toY) < CFG.StairRiserGravityVerticalDot
    local edgeRoute = legacyRoute == "edge"

    if fromHorizontalPlane and toWall then
        if fromY >= 0.985 then
            if edgeRoute then return "floor-edge-to-wall-underside" end
            return "floor-to-wall"
        end
        if edgeRoute then return "ceiling-edge-to-wall-underside" end
        return "ceiling-to-wall"
    end

    if not fromHorizontalPlane and (toFloorPlane or toCeilingUnderside) then
        if toCeilingUnderside then
            if edgeRoute then return "wall-edge-to-ceiling-underside" end
            return "wall-to-ceiling"
        end
        if edgeRoute then return "wall-edge-to-floor" end
        return "wall-to-floor"
    end

    return nil
end

function wwRecordTransitionRoute(routeName, fromUp, toUp, hit, normal, now, gap, gapLimit)
    if not wwIsManagedTransitionRoute(routeName) then return false end
    if not root or not hit or not hit.Instance or not hit.Instance.Parent or not hit.Position then
        return false
    end
    if not normal or safeUnit(normal, toUp):Dot(safeUnit(toUp, fromUp)) < 0.90 then
        return false
    end

    gap = tonumber(gap) or math.huge
    gapLimit = tonumber(gapLimit) or 0
    if gap ~= gap or gapLimit ~= gapLimit or gap > gapLimit then
        wwWallDiag("WW_ROUTE_CONTACT_REJECTED",
            "route=" .. routeName
                .. ", gap=" .. tostring(gap)
                .. ", limit=" .. tostring(gapLimit),
            0.15
        )
        return false
    end

    now = now or os.clock()
    local state = transitionRouteStates[routeName]
    local sourceUp = safeUnit(fromUp, UP)
    local targetUp = safeUnit(toUp, sourceUp)
    local targetNormal = safeUnit(normal, targetUp)
    local sameState = state ~= nil
        and not wwIsTerminalTransitionPhase(state.phase)
        and state.fromUp ~= nil
        and state.toUp ~= nil
        and state.fromUp:Dot(sourceUp) >= 0.90
        and state.toUp:Dot(targetUp) >= 0.90
        and state.normal ~= nil
        and safeUnit(state.normal, targetNormal):Dot(targetNormal) >= 0.85
        and state.instance == hit.Instance
        and state.point ~= nil
        and math.abs((state.point - hit.Position):Dot(targetNormal)) <= 0.65
        and now - (state.lastSeenAt or 0) <= CFG.EdgeTransitionPendingLifetime

    if not sameState then
        wwSupersedeTransitionPipelineStateIfUnowned(state, now, "validated-target-changed")
        transitionRouteAttemptSequence = transitionRouteAttemptSequence + 1
        state = {
            route = routeName,
            legacyRoute = (string.find(routeName, "edge", 1, true) and "edge" or "forward"),
            attemptId = transitionRouteAttemptSequence,
            phase = "idle",
            fromUp = sourceUp,
            toUp = targetUp,
            startedAt = now,
            firstSeenAt = now,
            lastSeenAt = now,
            hit = hit,
            instance = hit.Instance,
            point = hit.Position,
            normal = targetNormal,
            gap = gap,
            gapLimit = gapLimit,
            observations = 1,
            lastObservedFrame = transitionPipelineSensorFrame or 0,
            phaseHistory = {},
        }
        transitionRouteStates[routeName] = state
        wwSetTransitionPipelinePhase(state, "validated", now, "route-controller-accepted")
    else
        state.lastSeenAt = now
        state.hit = hit
        state.instance = hit.Instance
        state.point = hit.Position
        state.normal = targetNormal
        state.legacyRoute = (string.find(routeName, "edge", 1, true) and "edge" or "forward")
        state.gap = gap
        state.gapLimit = gapLimit
        local frameToken = transitionPipelineSensorFrame or 0
        if state.lastObservedFrame ~= frameToken then
            state.observations = (state.observations or 0) + 1
            state.lastObservedFrame = frameToken
        end
        if state.phase == "candidate" or state.phase == "idle" then
            wwSetTransitionPipelinePhase(state, "validated", now, "route-controller-accepted")
        end
        -- Critical: do not downgrade queued/authorized/committed/confirming states
        -- merely because the sensor sees the same route again.
    end
    return true
end
function wwPruneTransitionRouteStates(now)
    if not transitionRouteStates then
        transitionRouteStates = {}
        return
    end
    now = now or os.clock()
    for routeName, state in pairs(transitionRouteStates) do
        local age = now - (state.lastSeenAt or state.startedAt or now)
        local timeout = CFG.EdgeTransitionPendingLifetime
        if routeName == "floor-to-wall" then
            timeout = CFG.FloorToWallReturnLockMaxTime
        elseif routeName == "ceiling-to-wall" then
            timeout = CFG.CeilingToWallLockMaxTime
        end

        if wwIsTerminalTransitionPhase(state.phase) then
            if now - (state.finishedAt or state.phaseChangedAt or now) > timeout then
                transitionRouteStates[routeName] = nil
            end
        elseif state.phase == "committed" or state.phase == "confirming" then
            if transitionClaim == nil then
                wwSetTransitionPipelinePhase(state, "aborted", now, "active-claim-no-longer-exists")
            end
        elseif age > timeout then
            wwSetTransitionPipelinePhase(state, "expired", now, "route-candidate-stale")
            wwWallDiag("WW_ROUTE_STATE_EXPIRED",
                "route=" .. routeName .. ", attempt=" .. tostring(state.attemptId)
                    .. ", absentFor=" .. string.format("%.2f", age),
                0
            )
        end
    end
end
function wwControllerHitIsValid(fromUp, toUp, hit, normal)
    if not root or not hit or not hit.Instance or not hit.Instance.Parent or not hit.Position then
        return false
    end
    if not normal then return false end
    if safeUnit(normal, toUp):Dot(safeUnit(toUp, fromUp)) < 0.90 then
        return false
    end
    return true
end

function wwControllerReject(routeName, reason)
    wwWallDiag("WW_ROUTE_CONTROLLER_REJECTED",
        "route=" .. tostring(routeName) .. ", reason=" .. tostring(reason),
        0.20
    )
    return false
end
]=] },
    { name = '24f1_controller_floor_to_wall', source = [=[function wwControlFloorToWall(fromUp, toUp, legacyRoute, hit, normal, moveVector, now)
    if fromUp:Dot(UP) < 0.985 then return wwControllerReject("floor-to-wall", "source-not-floor") end
    if math.abs(toUp:Dot(UP)) >= CFG.StairRiserGravityVerticalDot then return wwControllerReject("floor-to-wall", "target-not-wall") end
    if legacyRoute ~= "forward" then return wwControllerReject("floor-to-wall", "wrong-route-class") end
    if not wwControllerHitIsValid(fromUp, toUp, hit, normal) then return wwControllerReject("floor-to-wall", "invalid-target") end
    local gap = getCharacterSurfaceGap(hit.Position)
    return wwRecordTransitionRoute("floor-to-wall", fromUp, toUp, hit, normal, now, gap, CFG.VerticalSurfaceContactGap)
end
]=] },
    { name = '24f2_controller_floor_edge_to_wall_underside', source = [=[function wwControlFloorEdgeToWallUnderside(fromUp, toUp, legacyRoute, hit, normal, moveVector, now)
    if fromUp:Dot(UP) < 0.985 then return wwControllerReject("floor-edge-to-wall-underside", "source-not-floor") end
    if math.abs(toUp:Dot(UP)) >= CFG.StairRiserGravityVerticalDot then return wwControllerReject("floor-edge-to-wall-underside", "target-not-wall") end
    if legacyRoute ~= "edge" then return wwControllerReject("floor-edge-to-wall-underside", "wrong-route-class") end
    if not wwControllerHitIsValid(fromUp, toUp, hit, normal) then return wwControllerReject("floor-edge-to-wall-underside", "invalid-target") end
    local gap = getLegacyCharacterBoundsGap(hit.Position)
    local gapLimit = CFG.VerticalSurfaceContactGap + wwGetFloorEdgeRouteLead(fromUp, moveVector, hit.Position)
    return wwRecordTransitionRoute("floor-edge-to-wall-underside", fromUp, toUp, hit, normal, now, gap, gapLimit)
end
]=] },
    { name = '24f3_controller_wall_to_ceiling', source = [=[function wwControlWallToCeiling(fromUp, toUp, legacyRoute, hit, normal, moveVector, now)
    if math.abs(fromUp:Dot(UP)) >= 0.985 then return wwControllerReject("wall-to-ceiling", "source-not-wall") end
    if toUp:Dot(UP) > -0.90 then return wwControllerReject("wall-to-ceiling", "target-not-ceiling") end
    if legacyRoute ~= "forward" then return wwControllerReject("wall-to-ceiling", "wrong-route-class") end
    if not wwControllerHitIsValid(fromUp, toUp, hit, normal) then return wwControllerReject("wall-to-ceiling", "invalid-target") end
    local gap = getCharacterSurfaceGap(hit.Position)
    return wwRecordTransitionRoute("wall-to-ceiling", fromUp, toUp, hit, normal, now, gap, CFG.VerticalSurfaceContactGap)
end
]=] },
    { name = '24f4_controller_wall_edge_to_ceiling_underside', source = [=[function wwControlWallEdgeToCeilingUnderside(fromUp, toUp, legacyRoute, hit, normal, moveVector, now)
    if math.abs(fromUp:Dot(UP)) >= 0.985 then return wwControllerReject("wall-edge-to-ceiling-underside", "source-not-wall") end
    if toUp:Dot(UP) > -0.90 then return wwControllerReject("wall-edge-to-ceiling-underside", "target-not-ceiling") end
    if legacyRoute ~= "edge" then return wwControllerReject("wall-edge-to-ceiling-underside", "wrong-route-class") end
    if not wwControllerHitIsValid(fromUp, toUp, hit, normal) then return wwControllerReject("wall-edge-to-ceiling-underside", "invalid-target") end
    local gap = getLegacyCharacterBoundsGap(hit.Position)
    local gapLimit = CFG.VerticalSurfaceContactGap + wwGetWallEdgeToCeilingSpeedLead(fromUp, moveVector)
    return wwRecordTransitionRoute("wall-edge-to-ceiling-underside", fromUp, toUp, hit, normal, now, gap, gapLimit)
end
]=] },
    { name = '24f5_controller_ceiling_to_wall', source = [=[function wwControlCeilingToWall(fromUp, toUp, legacyRoute, hit, normal, moveVector, now)
    if fromUp:Dot(UP) > -0.985 then return wwControllerReject("ceiling-to-wall", "source-not-ceiling") end
    if math.abs(toUp:Dot(UP)) >= CFG.StairRiserGravityVerticalDot then return wwControllerReject("ceiling-to-wall", "target-not-wall") end
    if legacyRoute ~= "forward" then return wwControllerReject("ceiling-to-wall", "wrong-route-class") end
    if not wwControllerHitIsValid(fromUp, toUp, hit, normal) then return wwControllerReject("ceiling-to-wall", "invalid-target") end
    local gap = getCharacterSurfaceGap(hit.Position)
    return wwRecordTransitionRoute("ceiling-to-wall", fromUp, toUp, hit, normal, now, gap, CFG.VerticalSurfaceContactGap)
end
]=] },
    { name = '24f6_controller_ceiling_edge_to_wall_underside', source = [=[function wwControlCeilingEdgeToWallUnderside(fromUp, toUp, legacyRoute, hit, normal, moveVector, now)
    if fromUp:Dot(UP) > -0.985 then return wwControllerReject("ceiling-edge-to-wall-underside", "source-not-ceiling") end
    if math.abs(toUp:Dot(UP)) >= CFG.StairRiserGravityVerticalDot then return wwControllerReject("ceiling-edge-to-wall-underside", "target-not-wall") end
    if legacyRoute ~= "edge" then return wwControllerReject("ceiling-edge-to-wall-underside", "wrong-route-class") end
    if not wwControllerHitIsValid(fromUp, toUp, hit, normal) then return wwControllerReject("ceiling-edge-to-wall-underside", "invalid-target") end
    local gap = getLegacyCharacterBoundsGap(hit.Position)
    -- Keep the ceiling-edge contact gate progressive at higher speeds. This route
    -- is already classified as an edge, while ordinary ceiling -> wall stays fixed-gap.
    local gapLimit = CFG.VerticalSurfaceContactGap + wwGetUndersideEdgeSpeedLead(fromUp, moveVector)
    return wwRecordTransitionRoute("ceiling-edge-to-wall-underside", fromUp, toUp, hit, normal, now, gap, gapLimit)
end
]=] },
    { name = '24f7_controller_wall_to_floor', source = [=[function wwControlWallToFloor(fromUp, toUp, legacyRoute, hit, normal, moveVector, now)
    if math.abs(fromUp:Dot(UP)) >= 0.985 then return wwControllerReject("wall-to-floor", "source-not-wall") end
    if toUp:Dot(UP) < 0.985 then return wwControllerReject("wall-to-floor", "target-not-floor") end
    if legacyRoute ~= "forward" then return wwControllerReject("wall-to-floor", "wrong-route-class") end
    if not wwControllerHitIsValid(fromUp, toUp, hit, normal) then return wwControllerReject("wall-to-floor", "invalid-target") end
    local unusedGap, planeGap, tangentGap = getBodyPartFloorContactGap(hit.Position, normal)
    local planeLimit = CFG.VerticalSurfaceContactGap + 0.10
    local tangentLimit = CFG.FloorContactTangentAllowance + 0.30
    local movingToward = isMovementTowardSurfacePoint(hit.Position, fromUp, moveVector)
    if planeGap > planeLimit or tangentGap > tangentLimit
        or (tangentGap > CFG.FloorContactTangentAllowance and not movingToward)
    then
        wwWallDiag("WW_FLOOR_ROUTE_CONTACT_REJECTED",
            "route=wall-to-floor, planeGap=" .. string.format("%.2f", planeGap)
                .. ", tangentGap=" .. string.format("%.2f", tangentGap)
                .. ", movingToward=" .. tostring(movingToward),
            0.15
        )
        return false
    end
    wwWallDiag("WW_FLOOR_ROUTE_CONTACT_ACCEPTED",
        "route=wall-to-floor, planeGap=" .. string.format("%.2f", planeGap)
            .. ", tangentGap=" .. string.format("%.2f", tangentGap),
        0.15
    )
    return wwRecordTransitionRoute("wall-to-floor", fromUp, toUp, hit, normal, now, planeGap, planeLimit)
end
]=] },
    { name = '24f8_controller_wall_edge_to_floor', source = [=[function wwControlWallEdgeToFloor(fromUp, toUp, legacyRoute, hit, normal, moveVector, now)
    if math.abs(fromUp:Dot(UP)) >= 0.985 then return wwControllerReject("wall-edge-to-floor", "source-not-wall") end
    if toUp:Dot(UP) < 0.985 then return wwControllerReject("wall-edge-to-floor", "target-not-floor") end
    if legacyRoute ~= "edge" then return wwControllerReject("wall-edge-to-floor", "wrong-route-class") end
    if not wwControllerHitIsValid(fromUp, toUp, hit, normal) then return wwControllerReject("wall-edge-to-floor", "invalid-target") end
    local contactAccepted, surfaceGap, planeGap, tangentGap, tangentLimit, movingToward =
        wwGetWallEdgeFloorContact(hit.Position, normal, fromUp, moveVector)
    local planeLimit = CFG.VerticalSurfaceContactGap + 0.10
    if not contactAccepted then
        wwWallDiag("WW_FLOOR_ROUTE_CONTACT_REJECTED",
            "route=wall-edge-to-floor, contactGap=" .. string.format("%.2f", surfaceGap)
                .. ", planeGap=" .. string.format("%.2f", planeGap)
                .. ", tangentGap=" .. string.format("%.2f", tangentGap)
                .. ", movingToward=" .. tostring(movingToward)
                .. ", tangentLimit=" .. string.format("%.2f", tangentLimit),
            0.15
        )
        return false
    end
    wwWallDiag("WW_FLOOR_ROUTE_CONTACT_ACCEPTED",
        "route=wall-edge-to-floor, contactGap=" .. string.format("%.2f", surfaceGap)
            .. ", planeGap=" .. string.format("%.2f", planeGap)
            .. ", tangentGap=" .. string.format("%.2f", tangentGap)
            .. ", tangentLimit=" .. string.format("%.2f", tangentLimit),
        0.15
    )
    return wwRecordTransitionRoute("wall-edge-to-floor", fromUp, toUp, hit, normal, now, planeGap, planeLimit)
end
]=] },
    { name = '24f9_transition_route_arbiter', source = [=[function wwGetTransitionRootContactLimit(claim)
    -- Claim completion must be possible only inside the range of the same
    -- root-centered probe used by the adhesion actuator and safety controller.
    -- A hand/foot can brush a surface while the root is still too far away for
    -- updateGravityAndMovement() to see it; that is not a stable handoff.
    local reach = CFG.AdhesionProbeLength
    local hipHeight = 0
    if humanoid then
        hipHeight = tonumber(humanoid.HipHeight) or 0
    end
    if hipHeight + 0.25 > reach then
        reach = hipHeight + 0.25
    end
    if CFG.SurfaceSafetySupportDistance and reach > CFG.SurfaceSafetySupportDistance then
        reach = CFG.SurfaceSafetySupportDistance
    end
    -- Keep a small margin so the next center probe is not operating exactly
    -- on the ray-length boundary on a moving physics frame.
    local normalLimit = math.max(0.10, reach - 0.12)
    if legacyEdgeCeilingSupportActive and claim
        and claim.route == "wall-edge-to-ceiling-underside" then
        return math.max(normalLimit, CFG.LegacyWallEdgeCeilingSupportDistance)
    end
    return normalLimit
end

-- Root-to-plane distance alone is not a reliable contact proof for these rotated
-- character poses: the body can touch a matching target face while the root remains
-- about 3.25 studs away. Allow a bypass only with strict body clearance and a hit
-- that remains on the claimed target plane. Other transitions keep the root gate.
function wwCanConfirmTransitionByBodyContact(route, bodyGap, planeOffset)
    if (tonumber(bodyGap) or math.huge) > CFG.VerticalSurfaceContactGap + 0.10 then
        return false
    end
    if (tonumber(planeOffset) or math.huge) > 0.65 then
        return false
    end
    return route == "floor-to-wall"
        or route == "floor-edge-to-wall-underside"
        or route == "ceiling-to-wall"
        or route == "ceiling-edge-to-wall-underside"
        or route == "wall-to-ceiling"
        or route == "wall-edge-to-ceiling-underside"
        or route == "wall-to-floor"
        or route == "wall-edge-to-floor"
end

function wwIsTransitionTargetSupport(up, claim, point, normal, distance)
    if not root or not claim or not claim.point or not claim.normal or not claim.instance then
        return false
    end
    if not claim.instance.Parent or not point or not normal then
        return false
    end

    local current = safeUnit(up, UP)
    local targetNormal = safeUnit(claim.normal, current)
    local supportNormal = safeUnit(normal, current)
    if current:Dot(targetNormal) < CFG.SurfaceSafetySupportNormalDot then
        return false
    end
    if supportNormal:Dot(targetNormal) < 0.90 then
        return false
    end

    local maxDistance = CFG.TransitionHandoffMaxDistance
    if claim.route == "wall-edge-to-ceiling-underside" then
        maxDistance = CFG.WallEdgeCeilingHandoffMaxDistance
    end
    if (tonumber(distance) or math.huge) > maxDistance then
        return false
    end

    local planeOffset = math.abs((point - claim.point):Dot(targetNormal))
    if planeOffset > 0.65 then
        return false
    end

    local bodyGap = getBodyPartSurfaceGap(point)
    if bodyGap > CFG.VerticalSurfaceContactGap + 0.50 then
        return false
    end

    -- This second, stricter distance is deliberately root-to-plane distance,
    -- not hit-to-limb distance. The same physical hit can be near an extended
    -- limb while the root remains outside the actual adhesion probe's range.
    local rootPlaneGap = math.abs((root.Position - point):Dot(targetNormal))
    local rootContactLimit = wwGetTransitionRootContactLimit(claim)
    if rootPlaneGap > rootContactLimit then
        if wwCanConfirmTransitionByBodyContact(claim.route, bodyGap, planeOffset) then
            wwWallDiag("TRANSITION_SUPPORT_BODY_CONTACT_ROOT_BYPASS",
                "route=" .. tostring(claim.route)
                    .. ", bodyGap=" .. string.format("%.2f", bodyGap)
                    .. ", rootGap=" .. string.format("%.2f", rootPlaneGap)
                    .. ", rootLimit=" .. string.format("%.2f", rootContactLimit)
                    .. ", planeOffset=" .. string.format("%.2f", planeOffset),
                0.20
            )
            return true
        end
        wwWallDiag("TRANSITION_SUPPORT_WAIT_ROOT_CONTACT",
            "route=" .. tostring(claim.route)
                .. ", rootGap=" .. string.format("%.2f", rootPlaneGap)
                .. ", rootLimit=" .. string.format("%.2f", rootContactLimit),
            0.30
        )
        return false
    end
    return true
end

function wwFindTransitionTargetSupport(up, claim)
    if not root or not claim or not claim.point or not claim.normal or not claim.instance then
        return false, nil, nil, math.huge
    end
    if not claim.instance.Parent then return false, nil, nil, math.huge end

    local route = claim.route
    if route ~= "floor-edge-to-wall-underside"
        and route ~= "floor-to-wall"
        and route ~= "ceiling-edge-to-wall-underside"
        and route ~= "ceiling-to-wall"
        and route ~= "wall-edge-to-ceiling-underside"
        and route ~= "wall-to-ceiling"
        and route ~= "wall-edge-to-floor"
        and route ~= "wall-to-floor"
    then
        return false, nil, nil, math.huge
    end

    local current = safeUnit(up, UP)
    local targetNormal = safeUnit(claim.normal, current)
    if current:Dot(targetNormal) < CFG.SurfaceSafetySupportNormalDot then
        return false, nil, nil, math.huge
    end

    local reach = CFG.TransitionHandoffMaxDistance
    if route == "wall-edge-to-ceiling-underside" then
        reach = CFG.WallEdgeCeilingHandoffMaxDistance
    end
    local rootContactLimit = wwGetTransitionRootContactLimit(claim)
    local contactLimit = CFG.VerticalSurfaceContactGap + 0.50

    local tangentA = projectOnPlane(root.CFrame.RightVector, current)
    tangentA = safeUnit(tangentA, safeUnit(current:Cross(root.CFrame.LookVector), Vector3.xAxis))
    local tangentB = safeUnit(tangentA:Cross(current), root.CFrame.LookVector)
    tangentB = safeUnit(projectOnPlane(tangentB, current), Vector3.zAxis)
    local radius = CFG.SurfaceSafetyFanRadius
    local offsets = {
        ZERO,
        tangentA * radius,
        -tangentA * radius,
        tangentB * radius,
        -tangentB * radius,
    }

    local bestHit = nil
    local bestNormal = nil
    local bestDistance = math.huge
    local bestBodyGap = math.huge
    local bestPlaneOffset = math.huge
    local bestRootPlaneGap = math.huge
    local bestIsRootContact = false

    for _, offset in ipairs(offsets) do
        local probeOrigin = root.Position + offset
        local hit = cast(probeOrigin, -current, reach)
        if hit and hit.Instance and hit.Position then
            local normal = orientSurfaceNormal(hit, -current)
            if normal and normal:Dot(targetNormal) >= 0.90
                and normal:Dot(current) >= CFG.SurfaceSafetySupportNormalDot
            then
                local planeOffset = math.abs((hit.Position - claim.point):Dot(targetNormal))
                if planeOffset <= 0.65 then
                    local bodyGap = getBodyPartSurfaceGap(hit.Position)
                    local distance = math.abs((probeOrigin - hit.Position):Dot(normal))
                    local rootPlaneGap = math.abs((root.Position - hit.Position):Dot(targetNormal))
                    local bodyContactQualified = wwCanConfirmTransitionByBodyContact(
                        route, bodyGap, planeOffset
                    )
                    local isRootContact = bodyGap <= contactLimit
                        and (rootPlaneGap <= rootContactLimit or bodyContactQualified)
                    if bodyContactQualified and rootPlaneGap > rootContactLimit then
                        wwWallDiag("TRANSITION_SUPPORT_BODY_CONTACT_ROOT_BYPASS",
                            "route=" .. tostring(route)
                                .. ", bodyGap=" .. string.format("%.2f", bodyGap)
                                .. ", rootGap=" .. string.format("%.2f", rootPlaneGap)
                                .. ", rootLimit=" .. string.format("%.2f", rootContactLimit)
                                .. ", planeOffset=" .. string.format("%.2f", planeOffset),
                            0.20
                        )
                    end
                    local replaceBest = false
                    if not bestHit then
                        replaceBest = true
                    elseif isRootContact and not bestIsRootContact then
                        replaceBest = true
                    elseif isRootContact == bestIsRootContact and bodyGap < bestBodyGap then
                        replaceBest = true
                    end
                    if replaceBest then
                        bestHit = hit
                        bestNormal = normal
                        bestDistance = distance
                        bestBodyGap = bodyGap
                        bestPlaneOffset = planeOffset
                        bestRootPlaneGap = rootPlaneGap
                        bestIsRootContact = isRootContact
                    end
                end
            end
        end
    end

    if bestHit and bestNormal and bestIsRootContact then
        return true, bestHit.Position, bestNormal, bestDistance
    end

    if bestHit and bestBodyGap <= contactLimit and bestRootPlaneGap > rootContactLimit then
        wwWallDiag("TRANSITION_TARGET_SUPPORT_WAIT_ROOT_CONTACT",
            "route=" .. tostring(route)
                .. ", rootGap=" .. string.format("%.2f", bestRootPlaneGap)
                .. ", rootLimit=" .. string.format("%.2f", rootContactLimit)
                .. ", bodyGap=" .. string.format("%.2f", bestBodyGap)
                .. ", planeOffset=" .. string.format("%.2f", bestPlaneOffset),
            0.30
        )
    elseif bestHit then
        wwWallDiag("TRANSITION_TARGET_SUPPORT_NOT_CONTACT",
            "route=" .. tostring(route)
                .. ", bodyGap=" .. string.format("%.2f", bestBodyGap)
                .. ", contactLimit=" .. string.format("%.2f", contactLimit)
                .. ", rootGap=" .. string.format("%.2f", bestDistance)
                .. ", planeOffset=" .. string.format("%.2f", bestPlaneOffset)
                .. ", reach=" .. string.format("%.2f", reach),
            0.40
        )
    else
        wwWallDiag("TRANSITION_TARGET_SUPPORT_PROBE_MISS",
            "route=" .. tostring(route)
                .. ", reach=" .. string.format("%.2f", reach)
                .. ", pointDist=" .. string.format("%.2f", (claim.point - root.Position).Magnitude),
            0.40
        )
    end
    return false, nil, nil, math.huge
end

function wwResolveTransitionTargetSupport(up, claim, supportSeen, supportPoint, supportNormal, supportDistance)
    if not claim then
        return supportSeen, supportPoint, supportNormal, supportDistance
    end

    if supportSeen and wwIsTransitionTargetSupport(
        up, claim, supportPoint, supportNormal, supportDistance
    ) then
        return supportSeen, supportPoint, supportNormal, supportDistance
    end

    local targetSeen, targetPoint, targetNormal, targetDistance =
        wwFindTransitionTargetSupport(up, claim)
    if targetSeen then
        wwWallDiag("TRANSITION_TARGET_SUPPORT_CONFIRMED",
            "route=" .. tostring(claim.route)
                .. ", dist=" .. string.format("%.2f", targetDistance),
            0.12
        )
        return true, targetPoint, targetNormal, targetDistance
    end

    if supportSeen and supportPoint and supportNormal then
        local targetNormal = safeUnit(claim.normal, safeUnit(up, UP))
        local seenNormal = safeUnit(supportNormal, targetNormal)
        local normalDot = seenNormal:Dot(targetNormal)
        local planeOffset = math.abs((supportPoint - claim.point):Dot(targetNormal))
        local bodyGap = getBodyPartSurfaceGap(supportPoint)
        wwWallDiag("TRANSITION_SUPPORT_NOT_TARGET",
            "route=" .. tostring(claim.route)
                .. ", dist=" .. string.format("%.2f", tonumber(supportDistance) or math.huge)
                .. ", normalDot=" .. string.format("%.2f", normalDot)
                .. ", planeOffset=" .. string.format("%.2f", planeOffset)
                .. ", bodyGap=" .. string.format("%.2f", bodyGap),
            0.40
        )
    end

    return supportSeen, supportPoint, supportNormal, supportDistance
end

-- Shared ownership predicate: body contact alone is not a completed handoff.
-- Keep this as a small helper to avoid adding locals to the large updateSurface function.
function wwIsTransitionClaimSupportStable(claim, now)
    if not claim or claim.supportSince == nil then return false end
    now = now or os.clock()
    return math.max(0, now - claim.supportSince) >= CFG.TransitionSupportConfirmTime
end

function wwAuthorizeTransitionCandidate(fromUp, toUp, hasCandidate, legacyRoute, hit, normal, moveVector, now)
    now = now or os.clock()
    transitionResolvedRoute = nil
    wwPruneTransitionRouteStates(now)

    local safeFrom = safeUnit(fromUp, UP)
    local safeTo = safeUnit(toUp, safeFrom)
    local routeName = wwClassifyTransitionRoute(safeFrom, safeTo, legacyRoute)

    -- Expire a stale physical-transition lease before validating the new route.
    local claim = transitionClaim
    if claim then
        local claimAge = now - (claim.startedAt or now)
        local ownerValid = root ~= nil
            and claim.instance ~= nil and claim.instance.Parent ~= nil
            and claim.normal ~= nil and claim.point ~= nil
            and claimAge <= (claim.grace or CFG.TransitionSupportGrace)
        if ownerValid then
            local ownerDistance = math.abs((root.Position - claim.point):Dot(claim.normal))
            local ownerDistanceLimit = CFG.TransitionHandoffMaxDistance
            if claim.route == "wall-edge-to-ceiling-underside" then
                ownerDistanceLimit = CFG.WallEdgeCeilingHandoffMaxDistance
            end
            if ownerDistance > ownerDistanceLimit then ownerValid = false end
        end

        if not ownerValid then
            wwWallDiag("WW_ROUTE_OWNER_EXPIRED",
                "route=" .. tostring(claim.route)
                    .. ", attempt=" .. tostring(claim.ownerAttemptId or "none")
                    .. ", age=" .. string.format("%.2f", claimAge),
                0
            )
            wwSafeTransitionAuditCall("expiry", wwRecordTransitionAuditExpiry, claim, "arbiter-owner-invalid-or-out-of-range")
            wwFinishTransitionClaimRoute(claim, "expired", "arbiter-owner-invalid-or-out-of-range", now)
            transitionClaim = nil
            gravityTransitionActive = false
            claim = nil
        end
    end

    if not hasCandidate or not routeName then
        return true, nil
    end

    -- Each route validates its own geometry and maintains its own timeline before
    -- the shared arbiter decides whether the one physical commit lane is available.
    local accepted = false
    if routeName == "floor-to-wall" then
        accepted = wwControlFloorToWall(safeFrom, safeTo, legacyRoute, hit, normal, moveVector, now)
    elseif routeName == "floor-edge-to-wall-underside" then
        accepted = wwControlFloorEdgeToWallUnderside(safeFrom, safeTo, legacyRoute, hit, normal, moveVector, now)
    elseif routeName == "wall-to-ceiling" then
        accepted = wwControlWallToCeiling(safeFrom, safeTo, legacyRoute, hit, normal, moveVector, now)
    elseif routeName == "wall-edge-to-ceiling-underside" then
        accepted = wwControlWallEdgeToCeilingUnderside(safeFrom, safeTo, legacyRoute, hit, normal, moveVector, now)
    elseif routeName == "ceiling-to-wall" then
        accepted = wwControlCeilingToWall(safeFrom, safeTo, legacyRoute, hit, normal, moveVector, now)
    elseif routeName == "ceiling-edge-to-wall-underside" then
        accepted = wwControlCeilingEdgeToWallUnderside(safeFrom, safeTo, legacyRoute, hit, normal, moveVector, now)
    elseif routeName == "wall-to-floor" then
        accepted = wwControlWallToFloor(safeFrom, safeTo, legacyRoute, hit, normal, moveVector, now)
    elseif routeName == "wall-edge-to-floor" then
        accepted = wwControlWallEdgeToFloor(safeFrom, safeTo, legacyRoute, hit, normal, moveVector, now)
    end

    if not accepted then
        -- A failed observation must not terminate a previously queued attempt for
        -- another target on the same route. That attempt expires on its own timer.
        return false, routeName
    end

    local routeState = transitionRouteStates[routeName]
    claim = transitionClaim
    if claim then
        local claimAge = now - (claim.startedAt or now)
        local claimedTargetUp = safeUnit(claim.targetUp, safeFrom)
        local targetDot = safeTo:Dot(claimedTargetUp)

        if targetDot < CFG.GravitySwitchBackDot then
            local sourceReachedClaimTarget = safeFrom:Dot(claimedTargetUp) >= 0.90
            local claimSource = safeUnit(claim.fromUp, safeFrom)
            local returningToClaimSource = safeTo:Dot(claimSource) >= 0.90

            -- Preserve the pre-existing, narrowly scoped edge-ceiling exception.
            local edgeCeilingReturnQualified = routeName == "wall-edge-to-ceiling-underside"
                and legacyRoute == "edge"
                and hit and hit.Instance and hit.Instance.Parent and hit.Position
                and normal and safeUnit(normal, safeTo):Dot(safeTo) >= 0.90
            local edgeCeilingReturnGuardBypass = edgeCeilingReturnQualified
                and claimAge < CFG.TransitionReturnGuardTime
            local directedSourceReturnQualified = false
            if returningToClaimSource then
                directedSourceReturnQualified = wwIsIntentionalSurfaceReturn(
                    safeTo, moveVector, hit, normal
                )
            end
            local returnGuardActive = returningToClaimSource
                and not edgeCeilingReturnGuardBypass
                and not directedSourceReturnQualified

            if edgeCeilingReturnGuardBypass and returningToClaimSource then
                wwWallDiag("WW_ROUTE_EDGE_RETURN_ALLOWED",
                    "owner=" .. tostring(claim.route)
                        .. ", candidate=" .. routeName
                        .. ", age=" .. string.format("%.2f", claimAge),
                    0.15
                )
            elseif directedSourceReturnQualified then
                wwWallDiag("WW_ROUTE_DIRECTED_SOURCE_RETURN_ALLOWED",
                    "owner=" .. tostring(claim.route)
                        .. ", candidate=" .. tostring(routeName)
                        .. ", age=" .. string.format("%.2f", claimAge),
                    0.15
                )
            end

            local chainAllowed = false
            local ownerSupportStable = wwIsTransitionClaimSupportStable(claim, now)
            -- Keep the narrow, previously existing edge-ceiling return exception.
            -- All other cross-route takeovers wait until the current owner's target
            -- support has completed its real stabilization interval. A single body
            -- contact frame is not enough: it can occur during a floor->wall rotation.
            if sourceReachedClaimTarget and routeName ~= nil and not returnGuardActive then
                if ownerSupportStable or (edgeCeilingReturnGuardBypass
                    and routeName == "wall-edge-to-ceiling-underside") then
                    chainAllowed = wwIsClaimTargetPhysicallyReached(safeFrom, claim)
                else
                    wwWallDiag("WW_ROUTE_OWNER_SUPPORT_NOT_STABLE",
                        "owner=" .. tostring(claim.route)
                            .. ", candidate=" .. tostring(routeName)
                            .. ", ownerAttempt=" .. tostring(claim.ownerAttemptId or "none")
                            .. ", supportStableFor=" .. string.format("%.3f", claim.supportSince and math.max(0, now - claim.supportSince) or 0)
                            .. ", required=" .. string.format("%.3f", CFG.TransitionSupportConfirmTime)
                            .. ", ownerContactMayBeTrue=true, ownerPhase=" .. tostring(claim.leasePhase),
                        0.12
                    )
                end
            end

            if chainAllowed then
                wwWallDiag("WW_ROUTE_OWNER_CHAIN_ALLOWED",
                    "owner=" .. tostring(claim.route)
                        .. ", ownerAttempt=" .. tostring(claim.ownerAttemptId or "none")
                        .. ", candidate=" .. tostring(routeName)
                        .. ", candidateAttempt=" .. tostring(routeState and routeState.attemptId or "none")
                        .. ", physicalContact=true, age=" .. string.format("%.2f", claimAge),
                    0.12
                )
            else
                if routeState and not wwIsTerminalTransitionPhase(routeState.phase)
                    and routeState.phase ~= "committed" and routeState.phase ~= "confirming" then
                    wwSetTransitionPipelinePhase(routeState, "queued", now,
                        returnGuardActive and "waiting-for-directed-source-return" or "waiting-for-active-owner-contact")
                end
                local eventName = returnGuardActive
                    and "WW_ROUTE_RETURN_GUARD_BLOCKED"
                    or "WW_ROUTE_OWNER_BLOCKED_CANDIDATE"
                wwWallDiag(eventName,
                    "owner=" .. tostring(claim.route)
                        .. ", ownerAttempt=" .. tostring(claim.ownerAttemptId or "none")
                        .. ", candidate=" .. tostring(routeName or legacyRoute or "unknown")
                        .. ", targetDot=" .. string.format("%.2f", targetDot)
                        .. ", sourceReachedTarget=" .. tostring(sourceReachedClaimTarget)
                        .. ", returningToSource=" .. tostring(returningToClaimSource)
                        .. ", ownerContact=" .. tostring(chainAllowed)
                        .. ", age=" .. string.format("%.2f", claimAge),
                    0.15
                )
                return false, routeName
            end
        end
    end

    if routeState and not wwIsTerminalTransitionPhase(routeState.phase)
        and routeState.phase ~= "committed" and routeState.phase ~= "confirming" then
        wwSetTransitionPipelinePhase(routeState, "authorized", now, "route-valid-and-arbiter-granted")
    end
    transitionResolvedRoute = routeName
    return true, routeName
end
]=] },
    { name = '24fa_transition_pipeline_audit', source = [=[
-- Observational compatibility adapter for the legacy candidate mailbox.
-- This module does not choose routes, modify thresholds, or affect physics.
-- Every hook is called through a fail-open wrapper so observer errors cannot
-- interrupt updateSurface(), claim commit, or support-safety execution.
function wwSafeTransitionAuditCall(label, callback, ...)
    local ok, result = pcall(callback, ...)
    if not ok then
        transitionCandidateAuditErrorCount = transitionCandidateAuditErrorCount + 1
        if transitionCandidateAuditErrorCount <= 3 then
            pcall(wwWallDiag, "WW_PIPE_AUDIT_ERROR",
                "hook=" .. tostring(label)
                    .. ", count=" .. tostring(transitionCandidateAuditErrorCount)
                    .. ", error=" .. string.sub(tostring(result), 1, 180),
                0
            )
        end
        if label == "capture" then
            transitionCandidateAuditCurrent = nil
        end
        return nil
    end
    return result
end

function wwTransitionAuditFormatVector(value)
    if not value then return "nil" end
    return string.format("%.2f,%.2f,%.2f", value.X, value.Y, value.Z)
end

function wwTrimTransitionAuditHistory(protectedCandidateSequence)
    local limit = transitionCandidateAuditHistoryLimit or 128
    while transitionCandidateAuditHistoryCount > limit do
        local sequence = transitionCandidateAuditPruneCursor or 1
        local record = transitionCandidateAuditBySequence[sequence]
        local activeSequence = transitionClaim and transitionClaim.auditSequence or nil
        if record and (sequence == activeSequence or sequence == protectedCandidateSequence) then
            transitionCandidateAuditPruneCursor = sequence + 1
        else
            if record then
                transitionCandidateAuditBySequence[sequence] = nil
                transitionCandidateAuditHistoryCount = transitionCandidateAuditHistoryCount - 1
            end
            transitionCandidateAuditPruneCursor = sequence + 1
        end
        if transitionCandidateAuditPruneCursor > transitionCandidateAuditSequence then
            break
        end
    end
end

function wwCaptureTransitionCandidate(fromUp, toUp, hasCandidate, legacyRoute, hit, normal, moveVector, now)
    if not hasCandidate then
        transitionCandidateAuditCurrent = nil
        return nil
    end

    now = now or os.clock()
    local sourceUp = safeUnit(fromUp, UP)
    local targetUp = safeUnit(toUp, sourceUp)
    local routeName = wwClassifyTransitionRoute(sourceUp, targetUp, legacyRoute)
    local routeKey = routeName or ("legacy-" .. tostring(legacyRoute or "unknown"))
    local instance = hit and hit.Instance or nil
    local point = hit and hit.Position or nil
    local targetNormal = normal and safeUnit(normal, targetUp) or nil
    local record = transitionCandidateAuditByRoute[routeKey]
    local sameAttempt = record ~= nil
        and record.phase ~= "completed"
        and record.phase ~= "superseded"
        and record.phase ~= "expired"
        and record.phase ~= "aborted"
        and now - (record.lastSeenAt or 0) <= (CFG.EdgeTransitionPendingLifetime or 0.40)
        and record.instance == instance
        and record.fromUp ~= nil
        and record.fromUp:Dot(sourceUp) >= 0.985
        and record.toUp ~= nil
        and record.toUp:Dot(targetUp) >= 0.985
        and ((record.normal == nil and targetNormal == nil)
            or (record.normal ~= nil and targetNormal ~= nil
                and record.normal:Dot(targetNormal) >= 0.985))

    if not sameAttempt then
        transitionCandidateAuditSequence = transitionCandidateAuditSequence + 1
        record = {
            sequence = transitionCandidateAuditSequence,
            route = routeKey,
            classifiedRoute = routeName,
            legacyRoute = legacyRoute,
            phase = "candidate",
            firstSeenAt = now,
            lastSeenAt = now,
            observations = 1,
            fromUp = sourceUp,
            toUp = targetUp,
            hit = hit,
            instance = instance,
            point = point,
            normal = targetNormal,
            lastDecision = nil,
        }
        transitionCandidateAuditByRoute[routeKey] = record
        transitionCandidateAuditBySequence[record.sequence] = record
        transitionCandidateAuditHistoryCount = transitionCandidateAuditHistoryCount + 1
        wwTrimTransitionAuditHistory(record.sequence)
        transitionCandidateAuditStats.offered = transitionCandidateAuditStats.offered + 1
        wwWallDiag("WW_PIPE_CANDIDATE_CAPTURED",
            "seq=" .. tostring(record.sequence)
                .. ", route=" .. routeKey
                .. ", legacy=" .. tostring(legacyRoute)
                .. ", fromY=" .. string.format("%.2f", sourceUp:Dot(UP))
                .. ", toY=" .. string.format("%.2f", targetUp:Dot(UP))
                .. ", target=" .. tostring(instance and instance.Name or "none")
                .. ", point=" .. wwTransitionAuditFormatVector(point)
                .. ", normal=" .. wwTransitionAuditFormatVector(targetNormal),
            0
        )
    else
        record.lastSeenAt = now
        record.observations = (record.observations or 0) + 1
        record.legacyRoute = legacyRoute
        record.hit = hit
        record.instance = instance
        record.point = point
        record.normal = targetNormal
        record.moveMagnitude = moveVector and moveVector.Magnitude or 0
        record.toUp = targetUp
    end

    record.lastSeenAt = now
    record.lastPoint = point
    record.lastNormal = targetNormal
    record.moveMagnitude = moveVector and moveVector.Magnitude or 0
    transitionCandidateAuditCurrent = record
    transitionCandidateAuditLatest = record
    if routeName and wwBeginTransitionPipelineCandidate then
        local pipelineOk, pipelineError = pcall(
            wwBeginTransitionPipelineCandidate,
            routeName, sourceUp, targetUp, hit, targetNormal, legacyRoute, now
        )
        if not pipelineOk then
            transitionCandidateAuditErrorCount = transitionCandidateAuditErrorCount + 1
            if transitionCandidateAuditErrorCount <= 3 then
                pcall(wwWallDiag, "WW_PIPELINE_CANDIDATE_ERROR",
                    "route=" .. tostring(routeName) .. ", error=" .. string.sub(tostring(pipelineError), 1, 160), 0)
            end
        end
    end
    return record
end

function wwRecordTransitionCandidateDecision(record, allowed, resolvedRoute, now)
    if not record then return end
    now = now or os.clock()
    record.lastDecisionAt = now
    record.resolvedRoute = resolvedRoute

    local decision = "unmanaged"
    if not allowed then
        local pendingState = resolvedRoute and transitionRouteStates
            and transitionRouteStates[resolvedRoute] or nil
        if pendingState and pendingState.phase == "queued" then
            decision = "queued"
        else
            decision = "rejected"
        end
    elseif wwIsManagedTransitionRoute(resolvedRoute) then
        decision = "authorized"
    end

    -- Do not downgrade a claim that has already committed or finished.
    if record.phase ~= "committed"
        and record.phase ~= "confirming"
        and record.phase ~= "completed"
        and record.phase ~= "superseded"
        and record.phase ~= "expired"
        and record.phase ~= "aborted"
    then
        record.phase = decision
    end

    if record.lastDecision ~= decision then
        record.lastDecision = decision
        if decision == "authorized" then
            transitionCandidateAuditStats.authorized = transitionCandidateAuditStats.authorized + 1
        elseif decision == "rejected" then
            transitionCandidateAuditStats.rejected = transitionCandidateAuditStats.rejected + 1
        elseif decision == "queued" then
            transitionCandidateAuditStats.queued = (transitionCandidateAuditStats.queued or 0) + 1
        else
            transitionCandidateAuditStats.unmanaged = transitionCandidateAuditStats.unmanaged + 1
        end
        wwWallDiag("WW_PIPE_CANDIDATE_" .. string.upper(decision),
            "seq=" .. tostring(record.sequence)
                .. ", route=" .. tostring(record.route)
                .. ", resolved=" .. tostring(resolvedRoute)
                .. ", legacy=" .. tostring(record.legacyRoute)
                .. ", age=" .. string.format("%.3f", now - (record.firstSeenAt or now))
                .. ", seen=" .. tostring(record.observations),
            0
        )
    end
end

function wwTransitionAuditRouteForClaim(claim)
    if not claim then return nil end
    if wwIsManagedTransitionRoute(claim.route) then return claim.route end
    return wwClassifyTransitionRoute(claim.fromUp, claim.targetUp, claim.legacyRoute)
end

function wwFindTransitionAuditRecordForClaim(claim)
    if not claim then return nil end
    local record = nil
    if claim.auditSequence and transitionCandidateAuditBySequence then
        record = transitionCandidateAuditBySequence[claim.auditSequence]
    end
    if record and record.instance == claim.instance then
        return record
    end
    local routeKey = wwTransitionAuditRouteForClaim(claim)
    record = routeKey and transitionCandidateAuditByRoute[routeKey] or nil
    if record and record.instance == claim.instance then
        return record
    end
    return nil
end

function wwSetTransitionAuditPhaseForClaim(claim, phase, detail)
    if not claim then return end
    local record = wwFindTransitionAuditRecordForClaim(claim)
    if record then
        claim.auditSequence = record.sequence
        if record.phase ~= "completed" and record.phase ~= "superseded" and record.phase ~= "expired" and record.phase ~= "aborted" then
            record.phase = phase
            record.phaseAt = os.clock()
            record.phaseDetail = detail
        end
    end
end

function wwRecordTransitionAuditCommit(claim)
    if not claim then return end
    local record = wwFindTransitionAuditRecordForClaim(claim)
    if record then claim.auditSequence = record.sequence end
    transitionCandidateAuditStats.committed = transitionCandidateAuditStats.committed + 1
    wwSetTransitionAuditPhaseForClaim(claim, "committed", "gravity-side-changed")
    wwWallDiag("WW_PIPE_COMMIT",
        "seq=" .. tostring(claim.auditSequence or "unlinked")
            .. ", route=" .. tostring(claim.route)
            .. ", target=" .. tostring(claim.instance and claim.instance.Name or "none")
            .. ", age=" .. string.format("%.3f", os.clock() - (claim.startedAt or os.clock()))
            .. ", grace=" .. string.format("%.3f", tonumber(claim.grace) or 0)
            .. ", point=" .. wwTransitionAuditFormatVector(claim.point)
            .. ", normal=" .. wwTransitionAuditFormatVector(claim.normal),
        0
    )
end

function wwRecordTransitionAuditClaimReplacement(oldClaim, newRoute, newUp, now)
    if not oldClaim then return end
    now = now or os.clock()
    transitionCandidateAuditStats.claimReplacements = transitionCandidateAuditStats.claimReplacements + 1
    wwSetTransitionAuditPhaseForClaim(oldClaim, "superseded", "new-claim-before-confirmation")
    local stable = 0
    if oldClaim.supportSince then stable = math.max(0, now - oldClaim.supportSince) end
    local oldTargetDot = -1
    if oldClaim.targetUp and newUp then
        oldTargetDot = safeUnit(oldClaim.targetUp, UP):Dot(safeUnit(newUp, UP))
    end
    wwWallDiag("WW_PIPE_CLAIM_REPLACED_BEFORE_CONFIRMATION",
        "seq=" .. tostring(oldClaim.auditSequence or "unlinked")
            .. ", old=" .. tostring(oldClaim.route)
            .. ", new=" .. tostring(newRoute)
            .. ", oldAge=" .. string.format("%.3f", now - (oldClaim.startedAt or now))
            .. ", oldStable=" .. string.format("%.3f", stable)
            .. ", newTargetDot=" .. string.format("%.3f", oldTargetDot)
            .. ", oldTarget=" .. tostring(oldClaim.instance and oldClaim.instance.Name or "none"),
        0
    )
end

function wwRecordTransitionAuditCompletion(claim, supportDistance, stableDuration)
    if not claim then return end
    transitionCandidateAuditStats.completed = transitionCandidateAuditStats.completed + 1
    wwSetTransitionAuditPhaseForClaim(claim, "completed", "stable-target-support")
    wwWallDiag("WW_PIPE_COMPLETED",
        "seq=" .. tostring(claim.auditSequence or "unlinked")
            .. ", route=" .. tostring(claim.route)
            .. ", stable=" .. string.format("%.3f", tonumber(stableDuration) or 0)
            .. ", supportDist=" .. string.format("%.3f", tonumber(supportDistance) or math.huge),
        0
    )
end

function wwRecordTransitionAuditExpiry(claim, reason)
    if not claim then return end
    transitionCandidateAuditStats.expired = transitionCandidateAuditStats.expired + 1
    wwSetTransitionAuditPhaseForClaim(claim, "expired", reason or "expired")
    wwWallDiag("WW_PIPE_EXPIRED",
        "seq=" .. tostring(claim.auditSequence or "unlinked")
            .. ", route=" .. tostring(claim.route)
            .. ", reason=" .. tostring(reason or "expired")
            .. ", age=" .. string.format("%.3f", os.clock() - (claim.startedAt or os.clock()))
            .. ", target=" .. tostring(claim.instance and claim.instance.Name or "none"),
        0
    )
end


function wwRecordTransitionAuditAbort(claim, reason)
    if not claim then return end
    transitionCandidateAuditStats.aborted = transitionCandidateAuditStats.aborted + 1
    wwSetTransitionAuditPhaseForClaim(claim, "aborted", reason or "claim-cleared-without-completion")
    wwWallDiag("WW_PIPE_ABORTED",
        "seq=" .. tostring(claim.auditSequence or "unlinked")
            .. ", route=" .. tostring(claim.route)
            .. ", reason=" .. tostring(reason or "claim-cleared-without-completion")
            .. ", age=" .. string.format("%.3f", os.clock() - (claim.startedAt or os.clock()))
            .. ", target=" .. tostring(claim.instance and claim.instance.Name or "none"),
        0
    )
end
]=] },
    { name = '24fb_independent_transition_pipelines', source = [=[
-- v48.76.97: route-owned attempt timelines with one physical commit owner.
-- Geometry and route thresholds remain in the existing route controllers.
transitionRouteAttemptSequence = transitionRouteAttemptSequence or 0
transitionCommitSequence = transitionCommitSequence or 0
transitionRoutePhaseHistoryLimit = 12
transitionRouteHistoryLimit = 8
transitionRouteHistory = transitionRouteHistory or {}

function wwIsTerminalTransitionPhase(phase)
    return phase == "completed"
        or phase == "expired"
        or phase == "aborted"
        or phase == "superseded"
        or phase == "failed"
end

function wwArchiveTransitionPipelineState(state, phase, now)
    if not state or state.historyArchived then return end
    local routeName = state.route or "unknown"
    local history = transitionRouteHistory[routeName]
    if not history then
        history = {}
        transitionRouteHistory[routeName] = history
    end
    table.insert(history, {
        route = routeName,
        attemptId = state.attemptId,
        phase = phase,
        startedAt = state.startedAt,
        finishedAt = now,
        fromUp = state.fromUp,
        toUp = state.toUp,
        instance = state.instance,
        point = state.point,
        normal = state.normal,
        observations = state.observations or 0,
        phaseHistory = state.phaseHistory,
        rejectReason = state.rejectReason,
        finishDetail = state.lastPhaseDetail,
    })
    while #history > transitionRouteHistoryLimit do
        table.remove(history, 1)
    end
    state.historyArchived = true
end

function wwSetTransitionPipelinePhase(state, phase, now, detail)
    if not state or not phase then return false end
    now = now or os.clock()
    local previous = state.phase or "idle"
    if wwIsTerminalTransitionPhase(previous) then return false end
    if previous == phase then
        state.lastPhaseDetail = detail or state.lastPhaseDetail
        return false
    end

    state.phase = phase
    state.phaseChangedAt = now
    state.lastPhaseDetail = detail

    if not state.phaseHistory then state.phaseHistory = {} end
    if #state.phaseHistory >= transitionRoutePhaseHistoryLimit then
        table.remove(state.phaseHistory, 1)
    end
    table.insert(state.phaseHistory, {
        phase = phase,
        previous = previous,
        at = now,
        detail = detail,
    })

    local terminal = wwIsTerminalTransitionPhase(phase)
    if terminal then
        state.finishedAt = now
        wwArchiveTransitionPipelineState(state, phase, now)
    end
    local phaseLogKey = tostring(state.route or "unknown") .. ":" .. tostring(phase)
    local lastRoutePhaseLog = wwTransitionPhaseLogAt[phaseLogKey] or 0
    local transientPhase = phase == "candidate" or phase == "validated"
    local logAllowed = terminal or not transientPhase
        or now - lastRoutePhaseLog >= 0.30
    if logAllowed then
        state.lastPhaseLogAt = now
        if transientPhase then
            wwTransitionPhaseLogAt[phaseLogKey] = now
        end
        wwWallDiag("WW_PIPELINE_PHASE",
            "attempt=" .. tostring(state.attemptId or "none")
                .. ", route=" .. tostring(state.route)
                .. ", " .. tostring(previous) .. "->" .. tostring(phase)
                .. ", elapsed=" .. string.format("%.3f", math.max(0, now - (state.startedAt or now)))
                .. ", detail=" .. tostring(detail or "none"),
            0
        )
    end
    return true
end

function wwSetTransitionRoutePhase(routeName, phase, now, detail, stateOverride)
    local state = stateOverride
    if not state and transitionRouteStates then
        state = transitionRouteStates[routeName]
    end
    if not state then return false end
    return wwSetTransitionPipelinePhase(state, phase, now, detail)
end

function wwSupersedeTransitionPipelineStateIfUnowned(state, now, reason)
    if not state or wwIsTerminalTransitionPhase(state.phase) then return false end
    if transitionClaim and transitionClaim.pipelineState == state then return false end
    return wwSetTransitionPipelinePhase(state, "superseded", now or os.clock(), reason or "replaced-by-new-attempt")
end

function wwObserveTransitionPipelineCandidate(fromUp, toUp, legacyRoute, hit, normal, now)
    local routeName = wwClassifyTransitionRoute(fromUp, toUp, legacyRoute)
    if not routeName then return nil end
    local ok, state = pcall(wwBeginTransitionPipelineCandidate,
        routeName, fromUp, toUp, hit, normal, legacyRoute, now or os.clock())
    if not ok then
        transitionCandidateAuditErrorCount = (transitionCandidateAuditErrorCount or 0) + 1
        if transitionCandidateAuditErrorCount <= 3 then
            pcall(wwWallDiag, "WW_PIPELINE_CANDIDATE_ERROR",
                "route=" .. tostring(routeName) .. ", error=" .. string.sub(tostring(state), 1, 160), 0)
        end
        return nil
    end
    return state
end

function wwBeginTransitionPipelineCandidate(routeName, fromUp, toUp, hit, normal, legacyRoute, now)
    if not wwIsManagedTransitionRoute(routeName) then return nil end
    if not root or not hit or not hit.Instance or not hit.Instance.Parent or not hit.Position or not normal then
        return nil
    end
    now = now or os.clock()
    legacyRoute = legacyRoute or (string.find(routeName, "edge", 1, true) and "edge" or "forward")
    local state = transitionRouteStates and transitionRouteStates[routeName] or nil
    local sourceUp = safeUnit(fromUp, UP)
    local targetUp = safeUnit(toUp, sourceUp)
    local targetNormal = safeUnit(normal, targetUp)
    local sameAttempt = state ~= nil
        and not wwIsTerminalTransitionPhase(state.phase)
        and state.instance == hit.Instance
        and state.fromUp ~= nil
        and state.toUp ~= nil
        and state.fromUp:Dot(sourceUp) >= 0.90
        and state.toUp:Dot(targetUp) >= 0.90
        and state.normal ~= nil
        and safeUnit(state.normal, targetNormal):Dot(targetNormal) >= 0.85
        and state.point ~= nil
        and math.abs((state.point - hit.Position):Dot(targetNormal)) <= 0.65
        and now - (state.lastSeenAt or state.startedAt or 0) <= CFG.EdgeTransitionPendingLifetime

    if not sameAttempt then
        wwSupersedeTransitionPipelineStateIfUnowned(state, now, "candidate-target-changed")
        transitionRouteAttemptSequence = transitionRouteAttemptSequence + 1
        state = {
            route = routeName,
            legacyRoute = legacyRoute,
            attemptId = transitionRouteAttemptSequence,
            phase = "idle",
            fromUp = sourceUp,
            toUp = targetUp,
            startedAt = now,
            firstSeenAt = now,
            lastSeenAt = now,
            hit = hit,
            instance = hit.Instance,
            point = hit.Position,
            normal = targetNormal,
            observations = 1,
            lastObservedFrame = transitionPipelineSensorFrame or 0,
            phaseHistory = {},
        }
        transitionRouteStates[routeName] = state
        wwSetTransitionPipelinePhase(state, "candidate", now, "sensor-candidate-observed")
    else
        state.lastSeenAt = now
        state.hit = hit
        state.instance = hit.Instance
        state.point = hit.Position
        state.normal = targetNormal
        state.legacyRoute = legacyRoute
        state.fromUp = sourceUp
        state.toUp = targetUp
        local frameToken = transitionPipelineSensorFrame or 0
        if state.lastObservedFrame ~= frameToken then
            state.observations = (state.observations or 0) + 1
            state.lastObservedFrame = frameToken
        end
        if state.phase == "idle" then
            wwSetTransitionPipelinePhase(state, "candidate", now, "sensor-candidate-observed")
        end
    end
    return state
end

function wwEnsureTransitionPipelineState(routeName, fromUp, toUp, hit, normal, now)
    if not wwIsManagedTransitionRoute(routeName) then return nil end
    now = now or os.clock()
    local state = transitionRouteStates and transitionRouteStates[routeName] or nil
    local sourceUp = safeUnit(fromUp, UP)
    local targetUp = safeUnit(toUp, sourceUp)
    local hitInstance = hit and hit.Instance or nil
    local hitPoint = hit and hit.Position or nil
    local sameAttempt = state ~= nil
        and not wwIsTerminalTransitionPhase(state.phase)
        and state.instance == hitInstance
        and state.fromUp ~= nil
        and state.toUp ~= nil
        and state.fromUp:Dot(sourceUp) >= 0.985
        and state.toUp:Dot(targetUp) >= 0.985
        and state.point ~= nil
        and hitPoint ~= nil
        and math.abs((state.point - hitPoint):Dot(safeUnit(normal, targetUp))) <= 0.65

    if not sameAttempt then
        wwSupersedeTransitionPipelineStateIfUnowned(state, now, "commit-target-changed")
        transitionRouteAttemptSequence = transitionRouteAttemptSequence + 1
        state = {
            route = routeName,
            attemptId = transitionRouteAttemptSequence,
            phase = "idle",
            fromUp = sourceUp,
            toUp = targetUp,
            hit = hit,
            instance = hitInstance,
            point = hitPoint,
            normal = normal and safeUnit(normal, targetUp) or nil,
            startedAt = now,
            firstSeenAt = now,
            lastSeenAt = now,
            observations = 1,
            lastObservedFrame = transitionPipelineSensorFrame or 0,
            phaseHistory = {},
        }
        transitionRouteStates[routeName] = state
        wwSetTransitionPipelinePhase(state, "validated", now, "route-controller-accepted")
    else
        state.lastSeenAt = now
        local frameToken = transitionPipelineSensorFrame or 0
        if state.lastObservedFrame ~= frameToken then
            state.observations = (state.observations or 0) + 1
            state.lastObservedFrame = frameToken
        end
        state.hit = hit
        state.instance = hitInstance
        state.point = hitPoint
        state.normal = normal and safeUnit(normal, targetUp) or state.normal
        state.fromUp = sourceUp
        state.toUp = targetUp
    end
    return state
end

function wwFinishTransitionClaimRoute(claim, phase, reason, now)
    if not claim then return end
    local state = claim.pipelineState
    if not state and transitionRouteStates then
        state = transitionRouteStates[claim.route]
    end
    if state then
        wwSetTransitionPipelinePhase(state, phase or "aborted", now or os.clock(), reason)
    end
end

-- The active claim is a single physical-transition lease. A new route may chain
-- only after the old target is actually reachable at the existing strict contact
-- envelope, except for the explicit legacy return paths handled by the arbiter.
function wwIsClaimTargetPhysicallyReached(currentUp, claim)
    if not claim or not root or not claim.instance or not claim.instance.Parent then
        return false
    end
    local seen = false
    if surfaceSupportSeen and surfaceSupportPoint and surfaceSupportNormal then
        seen = wwIsTransitionTargetSupport(
            currentUp, claim, surfaceSupportPoint, surfaceSupportNormal, surfaceSupportDistance
        )
    end
    if seen then return true end
    local targetSeen = false
    targetSeen = wwFindTransitionTargetSupport(currentUp, claim)
    return targetSeen == true
end

-- Retry one queued route only after the previous physical claim has completed.
-- The stored hit is not trusted by itself: its instance, age, reach, source plane,
-- input direction, and original route controller are checked again every retry.
function wwTryResumeQueuedTransitionCandidate(currentUp, moveVector, now)
    now = now or os.clock()
    if transitionClaim ~= nil or not root or not transitionRouteStates then return nil end
    if not moveVector or moveVector.Magnitude <= 0.05 then return nil end

    local worldMove = getWorldMove(moveVector, safeUnit(currentUp, UP))
    if worldMove.Magnitude <= 0.05 then return nil end

    local chosen = nil
    for routeName, state in pairs(transitionRouteStates) do
        if state and state.phase == "queued"
            and state.fromUp and state.toUp and state.hit and state.instance
            and state.instance.Parent and state.point and state.normal
            and state.legacyRoute
            and now - (state.lastSeenAt or state.startedAt or now) <= CFG.EdgeTransitionPendingLifetime
            and safeUnit(state.fromUp, currentUp):Dot(safeUnit(currentUp, UP)) >= 0.90
        then
            local age = now - (state.startedAt or now)
            local pointDistance = (state.point - root.Position).Magnitude
            local reach = CFG.TransitionHandoffMaxDistance
            if routeName == "wall-edge-to-ceiling-underside" then
                reach = CFG.WallEdgeCeilingHandoffMaxDistance
            end
            local targetUp = safeUnit(state.toUp, currentUp)
            local moveTowardTarget = worldMove.Unit:Dot(-targetUp) >= CFG.EdgeFloorApproachInputDot
            if moveTowardTarget and pointDistance <= reach then
                if not chosen or (state.startedAt or now) < (chosen.startedAt or now) then
                    chosen = state
                end
            end
        end
    end
    if not chosen then return nil end

    -- Confirm the target is still directly reachable now. A cached hit from a
    -- previous frame is only a hint; it cannot wake a queued transition by itself.
    local chosenDelta = chosen.point - root.Position
    local chosenPointDistance = chosenDelta.Magnitude
    if chosenPointDistance <= 0.05 then return nil end
    local freshHit = cast(root.Position, chosenDelta, chosenPointDistance + 0.35)
    if not freshHit or freshHit.Instance ~= chosen.instance or not freshHit.Normal
        or safeUnit(freshHit.Normal, chosen.normal):Dot(safeUnit(chosen.normal, freshHit.Normal)) < 0.85
        or (freshHit.Position - chosen.point).Magnitude > 1.50
    then
        wwWallDiag("WW_PIPE_QUEUED_CANDIDATE_STALE_RAY",
            "attempt=" .. tostring(chosen.attemptId)
                .. ", route=" .. tostring(chosen.route)
                .. ", pointDist=" .. string.format("%.2f", chosenPointDistance)
                .. ", freshTarget=" .. tostring(freshHit and freshHit.Instance and freshHit.Instance.Name or "none")
                .. ", reason=cached-candidate-not-reconfirmed-by-current-ray", 0.20)
        return nil
    end
    chosen.hit = freshHit
    chosen.instance = freshHit.Instance
    chosen.point = freshHit.Position
    chosen.normal = safeUnit(freshHit.Normal, chosen.normal)

    local accepted = false
    local routeName = chosen.route
    if routeName == "floor-to-wall" then
        accepted = wwControlFloorToWall(chosen.fromUp, chosen.toUp, chosen.legacyRoute,
            chosen.hit, chosen.normal, moveVector, now)
    elseif routeName == "floor-edge-to-wall-underside" then
        accepted = wwControlFloorEdgeToWallUnderside(chosen.fromUp, chosen.toUp, chosen.legacyRoute,
            chosen.hit, chosen.normal, moveVector, now)
    elseif routeName == "wall-to-ceiling" then
        accepted = wwControlWallToCeiling(chosen.fromUp, chosen.toUp, chosen.legacyRoute,
            chosen.hit, chosen.normal, moveVector, now)
    elseif routeName == "wall-edge-to-ceiling-underside" then
        accepted = wwControlWallEdgeToCeilingUnderside(chosen.fromUp, chosen.toUp, chosen.legacyRoute,
            chosen.hit, chosen.normal, moveVector, now)
    elseif routeName == "ceiling-to-wall" then
        accepted = wwControlCeilingToWall(chosen.fromUp, chosen.toUp, chosen.legacyRoute,
            chosen.hit, chosen.normal, moveVector, now)
    elseif routeName == "ceiling-edge-to-wall-underside" then
        accepted = wwControlCeilingEdgeToWallUnderside(chosen.fromUp, chosen.toUp, chosen.legacyRoute,
            chosen.hit, chosen.normal, moveVector, now)
    elseif routeName == "wall-to-floor" then
        accepted = wwControlWallToFloor(chosen.fromUp, chosen.toUp, chosen.legacyRoute,
            chosen.hit, chosen.normal, moveVector, now)
    elseif routeName == "wall-edge-to-floor" then
        accepted = wwControlWallEdgeToFloor(chosen.fromUp, chosen.toUp, chosen.legacyRoute,
            chosen.hit, chosen.normal, moveVector, now)
    end

    if not accepted then return nil end
    local queuedAge = now - (chosen.startedAt or now)
    local queuedPointDistance = (chosen.point - root.Position).Magnitude
    wwWallDiag("WW_PIPE_QUEUED_CANDIDATE_REVALIDATED",
        "attempt=" .. tostring(chosen.attemptId)
            .. ", route=" .. tostring(routeName)
            .. ", age=" .. string.format("%.3f", queuedAge)
            .. ", pointDist=" .. string.format("%.2f", queuedPointDistance)
            .. ", target=" .. tostring(chosen.instance.Name), 0)
    return chosen
end

]=] },
    { name = '25_getGravityUp', source = [=[function getGravityUp(oldUp, moveVector)
    transitionPipelineSensorFrame = (transitionPipelineSensorFrame or 0) + 1
    transitionResolvedRoute = nil
    transitionCandidateRoute = nil
    transitionCandidateHit = nil
    transitionCandidateNormal = nil
    transitionCandidateSupportGap = false
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
    local transitionHit
    local transitionIsRadialEdge = false
    local transitionDistance = math.huge
    local supportSeen = false
    local supportPoint
    local supportNormal
    local supportDistance = math.huge
    local edgeNow = os.clock()
    if not radialEdgeMemory or not radialEdgeMemory.oldUp
        or radialEdgeMemory.oldUp:Dot(oldUp) < 0.90
        or edgeNow - (radialEdgeMemory.updatedAt or 0) > CFG.RadialEdgeWallEvidenceWindow
    then
        radialEdgeMemory = { clusters = {}, oldUp = oldUp, updatedAt = edgeNow }
    end
    radialEdgeMemory.oldUp = oldUp
    radialEdgeMemory.updatedAt = edgeNow
    pruneRadialEdgeWallState(radialEdgeMemory, oldUp)
    local radialEdgeState = radialEdgeMemory

    -- v48.64: keep first-riser filtering independent of continuous stair ownership
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
    if floorOrCeiling then
        pcall(wwBeginRadialEdgeForensicScan, oldUp, origin, stairMoveDir, stairRiserAhead)
    else
        wwRadialEdgeForensic = nil
    end

    local function addHit(hit, weight, rayDirection, edgeRayIndex)
        if not hit then return end

        local normal = orientSurfaceNormal(hit, rayDirection)
        if not normal then return end

        -- Generic down-rays/feeler rays must never turn the first stair riser
        -- into a gravity candidate while we are on the ordinary floor/ceiling.
        -- Real walls are acquired through the dedicated transition sensor.
        local floorOrCeiling = math.abs(oldUp:Dot(UP)) > 0.985
        local nearVerticalRiser = floorOrCeiling
            and math.abs(normal:Dot(UP)) < CFG.StairRiserGravityVerticalDot

        -- Save vertical wall evidence from the existing down-fan before the
        -- normal surface average rejects it as a possible stair riser.
        if edgeRayIndex and floorOrCeiling then
            registerRadialEdgeWallHit(
                radialEdgeState,
                hit,
                normal,
                edgeRayIndex,
                origin,
                oldUp,
                rayDirection
            )
        end

        if nearVerticalRiser then
            return
        end

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
        if oldUp:Dot(normal) >= CFG.SurfaceSafetySupportNormalDot and perpendicularDistance <= CFG.AdhesionProbeLength then
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
        normalSum = normalSum + normal * weight
        hitWeight = hitWeight + weight
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
            addHit(hit, weight, direction, i)
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
                                transitionHit = hit
                                transitionCandidateRoute = "forward"
                                transitionCandidateHit = hit
                                transitionCandidateNormal = hitNormal
                                wwObserveTransitionPipelineCandidate(oldUp, hitNormal, "forward", hit, hitNormal, edgeNow)
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
                    safeUnit(moveDir + right * 0.35, moveDir),
                    safeUnit(moveDir - right * 0.35, moveDir),
                }

                local planarSpeed = projectOnPlane(root.AssemblyLinearVelocity, oldUp).Magnitude
                local commandedSpeed = 0
                if humanoid then
                    commandedSpeed = math.max(0, tonumber(humanoid.WalkSpeed) or 0)
                    * math.clamp(moveVector and moveVector.Magnitude or 0, 0, 1)
                end
                local transitionSpeed = math.max(planarSpeed, commandedSpeed)
                local sharedProbeLength = CFG.TransitionProbeLength
                    + math.clamp(transitionSpeed * 0.12, 0, 2.50)

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

                    -- A nearly-vertical face coming from an ordinary floor or
                    -- ceiling must continue above normal stair height before it
                    -- can claim gravity. This is the key first-riser protection.
                    if floorOrCeiling and math.abs(hitNormal:Dot(UP)) < CFG.StairRiserGravityVerticalDot then
                        if not hasVerticalWallContinuation(hit, hitNormal, oldUp, moveDir) then
                            return
                        end
                    end

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
                        local hit = cast(origin + offset, direction, sharedProbeLength)
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
                        sampleCount = sampleCount + 1
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
                        if math.abs(cluster.bestNormal:Dot(UP)) < CFG.StairRiserGravityVerticalDot then
                            stairRiser = not hasVerticalWallContinuation(
                                cluster.bestHit,
                                cluster.bestNormal,
                                oldUp,
                                moveDir
                            )
                        end

                        if not stairRiser and stairRiserAhead then
                            stairRiser = true
                        end
                    end

                    if confirmed and not stairRiser and (not chosenCluster or cluster.bestDistance < chosenCluster.bestDistance) then
                        chosenCluster = cluster
                    end
                end

                if chosenCluster then
                    transitionNormal = chosenCluster.bestNormal
                    transitionHit = chosenCluster.bestHit
                    transitionIsRadialEdge = false
                    transitionDistance = chosenCluster.bestDistance
                    transitionCandidateRoute = "forward"
                    transitionCandidateHit = transitionHit
                    transitionCandidateNormal = transitionNormal
                    wwObserveTransitionPipelineCandidate(oldUp, transitionNormal, "forward", transitionHit, transitionNormal, edgeNow)
                end
            end
        end
    end

    -- A nearby world-floor hit is not enough to end wall gravity. While
    -- climbing upward or sideways, the floor is behind/below the movement path;
    -- discard that candidate before the wall-to-ceiling scan gets its chance.
    -- This avoids the 2.75-stud distance gate mistaking the original floor for
    -- the intended destination during sustained wall climbing.
    if not floorOrCeiling and transitionNormal and transitionNormal:Dot(UP) > 0.985 then
        if not wwWallDiagCheckFloorApproach(oldUp, transitionHit, stairMoveDir, transitionDistance, moveVector) then
            transitionNormal = nil
            transitionHit = nil
            transitionIsRadialEdge = false
            transitionDistance = math.huge
            transitionCandidateRoute = nil
            transitionCandidateHit = nil
            transitionCandidateNormal = nil
        end
    end

    -- The EDGE SYSTEM inspects horizontal planes independently of forward probes.
    -- If both systems see a horizontal target, preserve a validated edge ceiling
    -- candidate when upward intent selects that route. Otherwise the forward
    -- candidate can mask the edge route and bypass its longer handoff grace.
    -- A forward-facing vertical wall candidate keeps ownership.
    if not floorOrCeiling then
        local edgePlaneHit, edgePlaneNormal, edgePlaneDistance = findWallEdgeHorizontalTransition(
            oldUp,
            moveVector,
            supportSeen
        )
        local edgeOwnsTarget = edgePlaneHit ~= nil and edgePlaneNormal ~= nil and not transitionNormal

        if edgePlaneHit and edgePlaneNormal and transitionNormal
            and math.abs(transitionNormal:Dot(UP)) > 0.985
        then
            local edgeFloor = edgePlaneNormal:Dot(UP) > 0.985
            local currentTargetFloor = transitionNormal:Dot(UP) > 0.985
            local worldMove = ZERO
            if moveVector and moveVector.Magnitude > 0.05 then
                worldMove = getWorldMove(moveVector, oldUp)
            end
            local verticalMove = worldMove:Dot(UP)
            local verticalVelocity = root.AssemblyLinearVelocity:Dot(UP)
            if edgeFloor ~= currentTargetFloor then
                if edgeFloor then
                    local towardFloor = isMovementTowardSurfacePoint(edgePlaneHit.Position, oldUp, moveVector)
                    local edgeFloorGap = getBodyPartFloorContactGap(edgePlaneHit.Position, edgePlaneNormal)
                    edgeOwnsTarget = towardFloor or edgeFloorGap <= CFG.VerticalSurfaceContactGap
                else
                    edgeOwnsTarget = verticalMove > 0.06
                        or (math.abs(verticalMove) <= 0.06 and verticalVelocity > 0.50)
                end
            else
                if edgeFloor then
                    -- Keep the existing nearer-floor preference.
                    edgeOwnsTarget = edgePlaneDistance < transitionDistance
                else
                    -- Both sensors have selected the ceiling plane. If the edge
                    -- scanner's own speed-scaled contact test passed and upward
                    -- intent is present, keep its edge route instead of silently
                    -- downgrading the same face to ordinary wall-to-ceiling.
                    -- The edge scanner already accepted this exact ceiling hit
                    -- using getLegacyCharacterBoundsGap and the same speed-lead
                    -- helper. Do not run a second gap test here: it can downgrade
                    -- a valid edge candidate to ordinary wall-to-ceiling, losing
                    -- the route-specific handoff policy.
                    edgeOwnsTarget = transitionNormal:Dot(UP) <= -0.985
                        and edgePlaneNormal:Dot(UP) <= -0.985
                        and (verticalMove > 0.06
                            or (math.abs(verticalMove) <= 0.06 and verticalVelocity > 0.50))
                end
            end
        end

        if edgeOwnsTarget then
            transitionCandidateRoute = "edge"
            transitionCandidateHit = edgePlaneHit
            transitionCandidateNormal = edgePlaneNormal
            wwObserveTransitionPipelineCandidate(oldUp, edgePlaneNormal, "edge", edgePlaneHit, edgePlaneNormal, edgeNow)
            transitionCandidateSupportGap = supportSeen ~= true
            wwWallDiag("EDGE_HORIZONTAL_CANDIDATE_ACCEPTED",
                "stage=scanner-selected-not-final-commit"
                    .. ", route=" .. (edgePlaneNormal:Dot(UP) > 0.985 and "wall-edge-to-floor" or "wall-edge-to-ceiling")
                    .. ", dist=" .. string.format("%.2f", edgePlaneDistance)
                    .. ", sourceGap=" .. tostring(transitionCandidateSupportGap),
                0.25
            )
            -- Candidate acceptance selects the target gravity plane, but is not
            -- proof of physical support. The transition claim bridges the approach;
            -- the safety fan confirms support only after near-contact is real.
            return safeUnit(edgePlaneNormal, oldUp), true, false,
                nil, nil, math.huge
        end
    end

    -- Wall -> ceiling uses a separate surface-relative scan. The falling
    -- radial wall scan intentionally rejects upward-facing ceiling normals;
    -- without this path, slow wall climbs can reach the ceiling without ever
    -- producing a valid transition candidate.
    if not transitionNormal and math.abs(oldUp:Dot(UP)) < 0.985 then
        local ceilingHit, ceilingNormal = findWallToCeilingSurface(oldUp, moveVector)
        if ceilingHit and ceilingNormal then
            local ceilingDistance = (ceilingHit.Position - root.Position).Magnitude
            local ceilingSurfaceGap = getCharacterSurfaceGap(ceilingHit.Position)
            local ceilingBodyGap = getBodyPartSurfaceGap(ceilingHit.Position)
            local maxCeilingSurfaceGap = CFG.VerticalSurfaceContactGap
            wwWallDiag("CEILING_SCAN_FOUND",
                "orientation=" .. wwDescribeSurfaceOrientation(oldUp)
                    .. ", rootDist=" .. string.format("%.2f", ceilingDistance)
                    .. ", boundsGap=" .. string.format("%.2f", ceilingSurfaceGap)
                    .. ", bodyGap=" .. string.format("%.2f", ceilingBodyGap)
                    .. ", gapLimit=" .. string.format("%.2f", maxCeilingSurfaceGap)
                    .. ", normalY=" .. string.format("%.2f", ceilingNormal:Dot(UP))
                    .. ", evidence=raycast-candidate-not-support-confirmation"
                    .. ", posY=" .. string.format("%.2f", root.Position.Y),
                0.35
            )
            if ceilingSurfaceGap <= maxCeilingSurfaceGap then
                wwWallDiag("CEILING_SCAN_CANDIDATE_ACCEPTED", "orientation=" .. wwDescribeSurfaceOrientation(oldUp)
                    .. ", rootDist=" .. string.format("%.2f", ceilingDistance)
                    .. ", boundsGap=" .. string.format("%.2f", ceilingSurfaceGap)
                    .. ", bodyGap=" .. string.format("%.2f", ceilingBodyGap)
                    .. ", bodyContact=" .. tostring(ceilingBodyGap <= CFG.VerticalSurfaceContactGap + 0.10)
                    .. ", gate=bounds-gap, support-confirmation=separate", 0.35)
                transitionNormal = ceilingNormal
                transitionHit = ceilingHit
                transitionIsRadialEdge = false
                transitionDistance = ceilingDistance
                transitionCandidateRoute = "forward"
                transitionCandidateHit = ceilingHit
                transitionCandidateNormal = ceilingNormal
                wwObserveTransitionPipelineCandidate(oldUp, ceilingNormal, "forward", ceilingHit, ceilingNormal, edgeNow)
            else
                wwWallDiag("CEILING_SCAN_REJECTED_DISTANCE", "rootDist=" .. string.format("%.2f", ceilingDistance)
                    .. ", surfaceGap=" .. string.format("%.2f", ceilingSurfaceGap)
                    .. ", gapLimit=" .. string.format("%.2f", maxCeilingSurfaceGap), 0.35)
            end
        else
            local moveMagnitude = moveVector and moveVector.Magnitude or 0
            local currentSupportDot = -1
            if supportSeen and supportNormal then
                currentSupportDot = safeUnit(supportNormal, oldUp):Dot(safeUnit(oldUp, UP))
            elseif surfaceSupportSeen and surfaceSupportNormal then
                currentSupportDot = safeUnit(surfaceSupportNormal, oldUp):Dot(safeUnit(oldUp, UP))
            end
            local currentWallSupport = currentSupportDot >= CFG.SurfaceSafetySupportNormalDot
            local upwardInput = 0
            if moveMagnitude > 0.05 then
                upwardInput = getWorldMove(moveVector, oldUp):Dot(UP)
            end
            local upwardVelocity = root.AssemblyLinearVelocity:Dot(UP)
            -- A ceiling search can fail while the player is correctly supported
            -- on a wall. Suppress idle misses when wall support is confirmed;
            -- otherwise name the scan result and the independent support state.
            if moveMagnitude > 0.05 or not currentWallSupport then
                wwWallDiag("CEILING_SCAN_NO_CANDIDATE",
                    "orientation=" .. wwDescribeSurfaceOrientation(oldUp)
                        .. ", probe=world-up-ceiling-search"
                        .. ", orientationSource=gravity-axis"
                        .. ", currentWallSupport=" .. tostring(currentWallSupport)
                        .. ", primarySupportSensorCurrent=" .. tostring(supportSeen == true)
                        .. ", lastPublishedSupportMatches=" .. tostring(surfaceSupportSeen == true and surfaceSupportNormal ~= nil and safeUnit(surfaceSupportNormal, oldUp):Dot(safeUnit(oldUp, UP)) >= CFG.SurfaceSafetySupportNormalDot)
                        .. ", supportDot=" .. string.format("%.2f", currentSupportDot)
                        .. ", supportDist=" .. tostring(supportDistance)
                        .. ", moveMag=" .. string.format("%.2f", moveMagnitude)
                        .. ", upwardInput=" .. string.format("%.2f", upwardInput)
                        .. ", worldYVelocity=" .. string.format("%.2f", upwardVelocity)
                        .. ", result=no-ceiling-candidate;not-a-wall-support-verdict"
                        .. ", posY=" .. string.format("%.2f", root.Position.Y), 0.8)
            end
        end
    end

    -- Check the radial wall candidate before and after support is lost. A
    -- speed-scaled acquisition envelope catches fast approaches, while the
    -- contact gate below prevents early gravity commitment from this evidence.
    if floorOrCeiling and #radialEdgeState.clusters > 0 then
        local edgeStillGrounded = getGrounded(oldUp)
        local radialNormal, radialHit, radialDistance = resolveRadialEdgeWall(
            radialEdgeState,
            oldUp,
            stairMoveDir,
            stairRiserAhead
        )
        if wwRadialEdgeForensic then
            wwRadialEdgeForensic.resolver = "ran"
            wwRadialEdgeForensic.resolvedPart = radialHit and radialHit.Instance or nil
            wwRadialEdgeForensic.resolvedPosition = radialHit and radialHit.Position or nil
            wwRadialEdgeForensic.resolvedNormal = radialNormal
            wwRadialEdgeForensic.resolvedDistance = radialDistance
            wwRadialEdgeForensic.initialAccept = radialNormal ~= nil and radialHit ~= nil
            wwRadialEdgeForensic.rejection = (radialNormal ~= nil and radialHit ~= nil) and "pending-grounded-distance-side-checks" or "resolver-returned-no-wall-candidate"
        end
        local acceptRadial = radialNormal ~= nil and radialHit ~= nil
        if wwRadialEdgeForensic then
            wwRadialEdgeForensic.edgeStillGrounded = edgeStillGrounded == true
        end
        if acceptRadial and edgeStillGrounded then
            acceptRadial = false
            if wwRadialEdgeForensic then wwRadialEdgeForensic.rejection = "grounded-until-distance-and-side-allowance" end
            local planarSpeed = projectOnPlane(root.AssemblyLinearVelocity, oldUp).Magnitude
            local commandedSpeed = 0
            if humanoid then
                commandedSpeed = math.max(0, tonumber(humanoid.WalkSpeed) or 0)
                    * math.clamp(moveVector and moveVector.Magnitude or 0, 0, 1)
            end
            local transitionSpeed = math.max(planarSpeed, commandedSpeed)
            local speedLead = math.clamp(
                planarSpeed * CFG.EdgeTransitionContactSpeedLead,
                0,
                CFG.EdgeTransitionContactSpeedLeadMax
            )
            local fastSpeedLead = math.clamp((transitionSpeed - 9) * 0.90, 0, 2.25)
            if fastSpeedLead > speedLead then
                speedLead = fastSpeedLead
            end
            local maxRadialDistance = 4.25 + speedLead
            if wwRadialEdgeForensic then
                wwRadialEdgeForensic.maxRadialDistance = maxRadialDistance
                wwRadialEdgeForensic.radialDistanceWithinLimit = radialDistance <= maxRadialDistance
            end
            if radialDistance <= maxRadialDistance then
                local sideOK = true
                if stairMoveDir and stairMoveDir.Magnitude > 0.05 then
                    local toWall = radialHit.Position - origin
                    local forwardOffset = toWall:Dot(stairMoveDir)
                    local sideOffset = (toWall - stairMoveDir * forwardOffset).Magnitude
                    local maxSide = 2.50 + speedLead * 0.50
                    if sideOffset > maxSide then
                        sideOK = false
                    end
                end
                if wwRadialEdgeForensic then wwRadialEdgeForensic.sideOK = sideOK end
                if sideOK then
                    acceptRadial = true
                    if wwRadialEdgeForensic then wwRadialEdgeForensic.rejection = "accepted-by-distance-and-side" end
                else
                    if wwRadialEdgeForensic then wwRadialEdgeForensic.rejection = "rejected-side-offset" end
                end
            elseif wwRadialEdgeForensic then
                wwRadialEdgeForensic.rejection = "rejected-distance-limit"
            end
        end
        if wwRadialEdgeForensic then
            wwRadialEdgeForensic.finalAccept = acceptRadial == true
            if acceptRadial and not edgeStillGrounded then
                wwRadialEdgeForensic.rejection = "accepted-source-support-already-lost"
            end
            if acceptRadial and radialDistance >= transitionDistance then
                wwRadialEdgeForensic.rejection = "valid-radial-candidate-not-nearest-transition"
            elseif not acceptRadial and wwRadialEdgeForensic.rejection == "pending-grounded-distance-side-checks" then
                wwRadialEdgeForensic.rejection = "rejected-by-radial-qualification"
            end
        end
        if acceptRadial and radialDistance < transitionDistance then
            transitionNormal = radialNormal
            transitionHit = radialHit
            transitionIsRadialEdge = true
            transitionDistance = radialDistance
            transitionCandidateRoute = "edge"
            transitionCandidateHit = radialHit
            transitionCandidateNormal = radialNormal
            wwObserveTransitionPipelineCandidate(oldUp, radialNormal, "edge", radialHit, radialNormal, edgeNow)
        end
    end

    -- Emit source-floor/source-ceiling radial diagnostics even when no cluster
    -- formed. This distinguishes “no qualifying wall hit” from “candidate found
    -- but rejected by resolver/contact/distance/side checks”.
    if wwRadialEdgeForensic then
        if wwRadialEdgeForensic.resolver == "not-run-yet" then
            if #radialEdgeState.clusters == 0 then
                wwRadialEdgeForensic.resolver = "not-run-no-clusters"
                wwRadialEdgeForensic.rejection = "no-registered-wall-cluster"
            else
                wwRadialEdgeForensic.resolver = "not-run-clusters-present-but-radial-gate-skipped"
                wwRadialEdgeForensic.rejection = "radial-resolver-gate-not-entered"
            end
        end
        pcall(wwEmitRadialEdgeForensicScan, radialEdgeState, supportSeen, transitionCandidateRoute,
            transitionCandidateHit, transitionCandidateNormal, transitionDistance)
    end

    -- If the down-fan missed the wall, do a direct 360-degree scan at body
    -- height only after support is actually lost. This addresses
    -- the case where falling beside a wall never creates a radial down-fan
    -- candidate, so the later contact gate was never reached.
    if floorOrCeiling and not transitionNormal and not stairRiserAhead then
        if not getGrounded(oldUp) then
            local fallHit, fallNormal, fallDistance = findFallingRadialWall(oldUp)
            local planarSpeed = projectOnPlane(root.AssemblyLinearVelocity, oldUp).Magnitude
            local commandedSpeed = 0
            if humanoid then
                commandedSpeed = math.max(0, tonumber(humanoid.WalkSpeed) or 0)
                    * math.clamp(moveVector and moveVector.Magnitude or 0, 0, 1)
            end
            local transitionSpeed = math.max(planarSpeed, commandedSpeed)
            local speedLead = math.clamp(transitionSpeed * 0.16, 0, 4.00)
            local fallAcquireDistance = 4.25 + speedLead
            if fallHit and fallNormal and fallDistance <= fallAcquireDistance then
                transitionNormal = fallNormal
                transitionHit = fallHit
                transitionIsRadialEdge = true
                transitionDistance = fallDistance
                transitionCandidateRoute = "edge"
                transitionCandidateHit = fallHit
                transitionCandidateNormal = fallNormal
                wwObserveTransitionPipelineCandidate(oldUp, fallNormal, "edge", fallHit, fallNormal, edgeNow)
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
                -- acquisition path too, so it must publish its real support
                -- metadata when the broader fan misses. Without this, callers
                -- receive supportSeen=true with a nil point and infinite
                -- distance, which can erase the safety controller's last
                -- confirmed support reference.
                supportSeen = true
                if exactHit and exactNormal and exactDistance < supportDistance then
                    supportPoint = exactHit.Position
                    supportNormal = exactNormal
                    supportDistance = exactDistance
                end
                return safeUnit(exactNormal, oldUp), true, supportSeen, supportPoint, supportNormal, supportDistance
            end
        end
    end

    local floorOrCeilingNow = math.abs(oldUp:Dot(UP)) > 0.985
    local targetIsVerticalWall = transitionNormal
        and math.abs(transitionNormal:Dot(UP)) < CFG.StairRiserGravityVerticalDot
    local targetDrop = transitionHit and (origin - transitionHit.Position):Dot(oldUp) or 0
    -- A ray hitting the lower part of a wall does not by itself make this an
    -- underneath-edge transition. The usual path requires independent radial
    -- edge evidence, or lost source support plus a target point below the root.
    local supportLostEdgeCandidate = supportSeen ~= true
        and targetDrop >= CFG.RadialEdgeWallMinDrop

    -- Startup recovery: while Roblox still reports floor support, offset rays
    -- can keep supportSeen=true for several frames as the player approaches an
    -- overhang. The movement-facing wall probes have already required a tall
    -- continuation test before producing this non-radial candidate. Reuse that
    -- independent evidence so a real lower wall can use the edge controller on
    -- the first transition after respawn; do not depend on gravity having been
    -- changed once already. hasVerticalWallContinuation also preserves the
    -- short-stair-riser rejection and demands movement facing the candidate.
    local supportedTallWallEdgeCandidate = false
    if not transitionIsRadialEdge
        and supportSeen == true
        and floorOrCeilingNow
        and targetIsVerticalWall
        and targetDrop >= CFG.RadialEdgeWallMinDrop
        and stairMoveDir
        and stairMoveDir.Magnitude > 0.05
    then
        supportedTallWallEdgeCandidate = hasVerticalWallContinuation(
            transitionHit, transitionNormal, oldUp, stairMoveDir
        )
    end

    local edgeBelowCandidate = transitionIsRadialEdge
        or supportLostEdgeCandidate
        or supportedTallWallEdgeCandidate

    if supportedTallWallEdgeCandidate then
        wwWallDiag("FLOOR_EDGE_STARTUP_ROUTE_EVIDENCE",
            "supportStillSeen=true, targetDrop=" .. string.format("%.2f", targetDrop)
                .. ", wallContinuation=true, route=edge",
            0.25
        )
    end

    if floorOrCeilingNow and targetIsVerticalWall then
        -- Speed lead is allowed only after the edge route has actual edge/drop
        -- evidence. A forward wall remains fixed-gap even if an angled probe hit
        -- a lower or upper point on that same wall.
        local routeName = edgeBelowCandidate and "edge" or "forward"
        local allowFastLead = routeName == "edge" and edgeBelowCandidate
        local readyNormal, readyHit = updateFloorWallEdgeTransition(
            transitionHit,
            transitionNormal,
            oldUp,
            stairMoveDir,
            allowFastLead,
            routeName,
            moveVector and moveVector.Magnitude or 0
        )
        if readyNormal and readyHit then
            -- Record whether source support was already lost before this edge
            -- candidate was accepted. Keep it for diagnostics and handoff state.
            transitionCandidateSupportGap = supportSeen ~= true
            -- This is an accepted destination, not support yet. Do not publish
            -- the prediction distance as a successful support-sensor reading.
            return safeUnit(readyNormal, oldUp), true, false,
                nil, nil, math.huge
        end
        transitionNormal = nil
        transitionCandidateSupportGap = false
        transitionCandidateRoute = nil
        transitionCandidateHit = nil
        transitionCandidateNormal = nil
    elseif transitionNormal then
        -- From a floor/ceiling, a vertical wall must pass the dedicated
        -- contact-gated path above. From wall gravity, horizontal-plane candidates
        -- keep their own near-contact/direction checks before claiming gravity.
        local transitionIsHorizontalPlane = math.abs(transitionNormal:Dot(UP)) > 0.985
        local transitionIsCeilingUnderside = transitionNormal:Dot(UP) < -0.985
        local rejectDistantHorizontalSurface = false

        if transitionIsHorizontalPlane then
            if transitionNormal:Dot(UP) >= 0.985
                and oldUp:Dot(UP) < 0.985
                and transitionCandidateRoute == "edge"
                and transitionHit and transitionHit.Position
            then
                -- Same plane-clearance/tangent rule as the wall-edge floor controller.
                rejectDistantHorizontalSurface = not wwGetWallEdgeFloorContact(
                    transitionHit.Position, transitionNormal, oldUp, moveVector
                )
            else
                local targetSurfaceGap = math.huge
                if transitionHit and transitionHit.Position then
                    if transitionNormal:Dot(UP) >= 0.985 and oldUp:Dot(UP) < 0.985 then
                        targetSurfaceGap = getBodyPartFloorContactGap(transitionHit.Position, transitionNormal)
                    else
                        targetSurfaceGap = getCharacterSurfaceGap(transitionHit.Position)
                        if transitionCandidateRoute == "edge" and transitionNormal:Dot(UP) <= -0.985 then
                            targetSurfaceGap = getLegacyCharacterBoundsGap(transitionHit.Position)
                        end
                    end
                end
                local targetGapLimit = CFG.VerticalSurfaceContactGap
                if transitionCandidateRoute == "edge" and transitionNormal:Dot(UP) <= -0.985 then
                    targetGapLimit = targetGapLimit + wwGetWallEdgeToCeilingSpeedLead(oldUp, moveVector)
                end
                rejectDistantHorizontalSurface = targetSurfaceGap > targetGapLimit
            end
        end

        if rejectDistantHorizontalSurface then
            edgeTransitionPending = nil
            forwardTransitionPending = nil
            transitionCandidateRoute = nil
            transitionCandidateHit = nil
            transitionCandidateNormal = nil
            transitionCandidateSupportGap = false
            return oldUp, false, supportSeen, supportPoint, supportNormal, supportDistance
        end
        edgeTransitionPending = nil
        forwardTransitionPending = nil
        -- A target face is accepted independently from support confirmation.
        -- Its normal/instance remain in transitionCandidate* for handoff logic,
        -- while the support return values below describe actual near-contact only.
        if not floorOrCeilingNow and transitionIsHorizontalPlane then
            transitionCandidateRoute = transitionCandidateRoute or "forward"
            transitionCandidateHit = transitionHit
            transitionCandidateNormal = transitionNormal
            transitionCandidateSupportGap = supportSeen ~= true
            wwObserveTransitionPipelineCandidate(oldUp, transitionNormal, transitionCandidateRoute,
                transitionHit, transitionNormal, edgeNow)
            -- The target-plane distance is candidate evidence only. Let the
            -- transition claim hold the handoff until a near-contact probe confirms it.
            return safeUnit(transitionNormal, oldUp), true, false,
                nil, nil, math.huge
        end
        transitionCandidateRoute = transitionCandidateRoute or "forward"
        transitionCandidateHit = transitionHit
        transitionCandidateNormal = transitionNormal
        transitionCandidateSupportGap = supportSeen ~= true
        wwObserveTransitionPipelineCandidate(oldUp, transitionNormal, transitionCandidateRoute,
            transitionHit, transitionNormal, edgeNow)
        -- Any accepted change to another face is a candidate, not support on
        -- that destination. Do not carry old-face support across the gravity switch.
        return safeUnit(transitionNormal, oldUp), true, false, nil, nil, math.huge
    else
        local readyNormal, readyHit = updateFloorWallEdgeTransition(
            nil, nil, oldUp, stairMoveDir, true, "edge",
            moveVector and moveVector.Magnitude or 0
        )
        if not readyNormal then
            readyNormal, readyHit = updateFloorWallEdgeTransition(
                nil, nil, oldUp, stairMoveDir, false, "forward",
                moveVector and moveVector.Magnitude or 0
            )
        end
        if readyNormal and readyHit then
            transitionCandidateSupportGap = supportSeen ~= true
            -- This is an accepted destination, not support yet. Do not publish
            -- the prediction distance as a successful support-sensor reading.
            return safeUnit(readyNormal, oldUp), true, false,
                nil, nil, math.huge
        end
    end

    if hitWeight > 0 and normalSum.Magnitude > 1e-5 then
        local candidate = normalSum.Unit

        -- While wall gravity is active, a floor underneath/behind the player
        -- can bias the broad fan toward world-up even when it is not a valid
        -- wall-to-floor handoff. Horizontal transitions must pass the direct,
        -- contact-gated candidate path above instead of this averaged fallback.
        if oldUp:Dot(UP) < 0.985 and candidate:Dot(UP) > 0.985 then
            return oldUp, false, supportSeen, supportPoint, supportNormal, supportDistance
        end

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
        local changedSurface = nearEnough and (changed or strongSurface)
        if changedSurface then
            transitionCandidateRoute = "support"
            transitionCandidateHit = nil
            transitionCandidateNormal = candidate
        end
        return candidate, changedSurface, supportSeen, supportPoint, supportNormal, supportDistance
    end

    return oldUp, false, supportSeen, supportPoint, supportNormal, supportDistance
end
]=] },
    { name = '26_getGrounded', source = [=[function getGrounded(up)
    if not root then return false end
    local hit = cast(root.Position, -up, CFG.GroundProbeLength)
    if not hit then return false end
    local normal = orientSurfaceNormal(hit, -up)
    if not normal then return false end
    local slopeLimit = math.cos(math.rad(CFG.GroundSlopeAngle))
    return up:Dot(normal) >= slopeLimit
end
]=] },
    { name = '27_getActualSurfaceContact', source = [=[function getActualSurfaceContact(up)
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
-- identical on floor, wall and ceiling.]=] },
    { name = '28_getWorldMove', source = [=[function getWorldMove(moveVector, up)
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
]=] },
    { name = '29_getMicroStepRampMove', source = [=[function getMicroStepRampMove(worldMove, up, dt)
    -- The important distinction here is between GRAVITY ownership and the
    -- PATH used to reach the next tiny support face. Gravity remains locked to
    -- `up`; only the commanded locomotion path temporarily follows a short,
    -- low-angle ramp between the current and next support planes.
    if not customActive or not root or not humanoid or worldMove.Magnitude < 0.05 then
        microStepTargetBlend = 0
        microStepBlend = microStepBlend + (microStepTargetBlend - microStepBlend)
            * (1 - math.exp(-CFG.MicroStepBlendResponse * dt))
        if microStepBlend < 0.01 then
            microStepMove = ZERO
        end
        return worldMove, false
    end

    local moveDir = safeUnit(projectOnPlane(worldMove, up), worldMove.Unit)
    local probeUp = up
    if up:Dot(UP) < -0.985 then
        probeUp = -up
    end
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
                local hit = cast(topOrigin, -probeUp, CFG.MicroStepProbeLength)
                if hit then
                    local normal = orientSurfaceNormal(hit, -probeUp)
                    if normal and up:Dot(normal) > 0.965 then
                        local topHeight = hit.Position:Dot(up)
                        local rise = topHeight - baseHeight
                        if up:Dot(UP) < -0.985 then
                            rise = -rise
                        end
                        local run = math.max(0.45,
                            (hit.Position - root.Position):Dot(moveDir))
                        local slope = math.deg(math.atan2(math.max(rise, 0), run))

                        if rise >= CFG.MicroStepMinRise and rise <= CFG.MicroStepMaxHeight and slope <= CFG.MicroStepMaxSlope then
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
            local rampUp = up
            if up:Dot(UP) < -0.985 then
                rampUp = -up
            end
            local rampVector = moveDir * bestRun + rampUp * bestRise
            local rampDirection = safeUnit(rampVector, moveDir)
            microStepMove = rampDirection
            microStepUntil = os.clock() + CFG.MicroStepHoldTime
            microStepTargetBlend = 1
        elseif os.clock() >= microStepUntil then
            microStepTargetBlend = 0
        end
    end

    microStepBlend = microStepBlend + (microStepTargetBlend - microStepBlend)
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
]=] },
    { name = '30_decayStairStepBlend', source = [=[function decayStairStepBlend(dt)
    stairStepTargetBlend = 0
    stairStepBlend = stairStepBlend + (stairStepTargetBlend - stairStepBlend)
        * (1 - math.exp(-CFG.StairStepBlendResponse * dt))
    if stairStepBlend <= 0.01 then
        stairStepBlend = 0
        stairStepMove = ZERO
    end
end
]=] },
    { name = '31_getStairStepRampMove', source = [=[function getStairStepRampMove(worldMove, up, dt)
    -- v48.75: PHYSICAL ACTUATION IS RESTORED TO THE v48.65 METHOD.
    -- This function creates a surface-relative ramp direction (run + rise),
    -- and updateGravityAndMovement turns that direction into the root's movement
    -- force. The v74 direct underside scan below is only the ceiling TARGET
    -- detector; it does not replace the proven ramp movement method.
    -- v48.59: prefer the exact stair top that the gravity detector already
    -- confirmed this frame. The old v48.58 solver performed a SECOND, slightly
    -- different stair scan here. That could create a bad state where gravity
    -- correctly ignored a riser while the movement solver failed to generate a
    -- usable climb vector. One geometry decision must drive both systems.
    if not customActive or not root or not humanoid or worldMove.Magnitude < 0.05 then
        decayStairStepBlend(dt)
        return worldMove, false
    end

    local moveDir = safeUnit(projectOnPlane(worldMove, up), worldMove.Unit)
    local probeUp = up
    if up:Dot(UP) < -0.985 then
        probeUp = -up
    end
    local targetRise
    local targetRun
    local useTraversalTarget = false

    -- v48.70: direct underside-tread scan for ceiling stairs.
    -- The previous solver depended too heavily on finding the vertical riser
    -- first. That is fragile for Roblox staircases made from separate blocks,
    -- especially when the riser is partly hidden by the character/camera.
    -- For an upside-down staircase, the reliable signal is simpler: cast from
    -- several points ahead of the root toward the underside and look for a
    -- tread whose surface is higher than the current ceiling support.
    -- This is geometry-driven and independent of the walk animation.
    if up:Dot(UP) <= CFG.UpsideDownStairSafetyDot then
        local baseHeight = nil
        if surfaceSupportSeen and surfaceSupportPoint and surfaceSupportNormal and up:Dot(surfaceSupportNormal) > 0.92 then
            baseHeight = surfaceSupportPoint:Dot(up)
        end

        if baseHeight then
            local side = safeUnit(moveDir:Cross(up), root.CFrame.RightVector)
            local forwardDistances = {0.35, 0.65, 1.00, 1.40, 1.80, 2.20, 2.60}
            local sideOffsets = {-0.70, 0, 0.70}
            local bestRise = nil
            local bestRun = nil
            local bestScore = math.huge

            for _, forwardDistance in ipairs(forwardDistances) do
                for _, sideOffset in ipairs(sideOffsets) do
                    -- IMPORTANT v48.71: for an upside-down staircase the
                    -- underside is ABOVE the character in the probeUp direction.
                    -- v48.70 moved the ray origin 1.65 studs toward the ceiling
                    -- and then cast BACK downward. On the small ceiling stairs
                    -- in testing this can place the ray origin inside the solid
                    -- stair block, so Roblox returns no hit. That is why moving
                    -- toward the stair produced literally no stair response.
                    -- Start just below the character and cast TOWARD the underside.
                    local origin = root.Position
                        + moveDir * forwardDistance
                        + side * sideOffset
                        + probeUp * CFG.StairCeilingProbeOffset

                    local hit = cast(origin, probeUp, CFG.StairCeilingProbeLength)
                    if hit then
                        local normal = orientSurfaceNormal(hit, probeUp)
                        if normal and up:Dot(normal) > 0.965 then
                            local run = (hit.Position - root.Position):Dot(moveDir)
                            local rise = baseHeight - hit.Position:Dot(up)

                            if rise >= CFG.StairStepMinRise and rise <= CFG.StairStepMaxHeight + 0.15 and run >= CFG.StairStepClearance and run <= CFG.StairTraversalForwardRange + 0.45 then
                                local slope = math.deg(math.atan2(rise, math.max(run, 0.05)))
                                if slope <= CFG.StairStepMaxSlope then
                                    local score = run + math.abs(sideOffset) * 0.08
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
                targetRise = bestRise
                targetRun = bestRun
                useTraversalTarget = true
            end
        end
    end

    if not useTraversalTarget and stairTraversalActive and stairTraversalTopPoint and stairTraversalMoveDir then
        local directionDot = moveDir:Dot(stairTraversalMoveDir)
        if directionDot >= CFG.StairTraversalMoveDot then
            local topOffset = stairTraversalTopPoint - root.Position
            local rise = topOffset:Dot(up)
            if up:Dot(UP) < -0.985 then
                rise = -rise
            end
            local run = topOffset:Dot(moveDir)

            if rise >= CFG.StairStepMinRise and rise <= CFG.StairStepMaxHeight + 0.15 and run >= CFG.StairStepClearance and run <= CFG.StairTraversalForwardRange + 0.45 then
                targetRise = rise
                targetRun = run
                useTraversalTarget = true
            end
        end
    end

    -- Fallback scan: if the shared ownership target has already been reached,
    -- look for the NEXT top. This keeps continuous stairs moving instead of
    -- waiting for the ownership timer to expire before acquiring another step.
    if not useTraversalTarget then
        local side = safeUnit(moveDir:Cross(up), root.CFrame.RightVector)
        local hip = humanoid.HipHeight > 0 and humanoid.HipHeight or 2
        local supportLength = math.max(CFG.AdhesionProbeLength, hip + 0.75)

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
                    + probeUp * CFG.StairStepProbeAbove

                local hit = cast(probeOrigin, -probeUp, CFG.StairStepProbeLength)
                if hit then
                    local normal = orientSurfaceNormal(hit, -probeUp)
                    if normal and up:Dot(normal) > 0.965 then
                        local topHeight = hit.Position:Dot(up)
                        local rise = topHeight - baseHeight
                        if up:Dot(UP) < -0.985 then
                            rise = -rise
                        end
                        local run = (hit.Position - root.Position):Dot(moveDir)
                        local slope = math.deg(math.atan2(math.max(rise, 0), math.max(run, 0.05)))

                        if rise >= CFG.StairStepMinRise and rise <= CFG.StairStepMaxHeight and run >= CFG.StairStepClearance and run <= CFG.StairStepLookahead + 0.20 and slope <= CFG.StairStepMaxSlope then
                            local riserHeight = math.clamp(
                                math.min(rise * 0.55, CFG.StairStepRiserProbeHeight),
                                0.08,
                                CFG.StairStepRiserProbeHeight
                            )
                            local riserOrigin = basePoint
                                + moveDir * 0.10
                                + side * sideOffset
                                + probeUp * riserHeight

                            local riserHit = cast(
                                riserOrigin,
                                moveDir,
                                math.max(CFG.StairStepRiserProbeLength, run + 0.35)
                            )

                            local hasRiser = false
                            if riserHit then
                                local riserNormal = orientSurfaceNormal(riserHit, moveDir)
                                if riserNormal then
                                    local facingIntoRiser = (-moveDir):Dot(riserNormal)
                                    hasRiser = facingIntoRiser >= CFG.StairStepRiserMinDot
                                        and up:Dot(riserNormal) < 0.35
                                        and math.abs((riserHit.Position - basePoint):Dot(up))
                                            <= rise + 0.22
                                end
                            end

                            if hasRiser then
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
            targetRise = bestRise
            targetRun = bestRun
        end
    end

    if targetRise and targetRun then
        -- The ramp is a movement command in the current surface tangent frame.
        -- Keep its magnitude equal to the player's requested horizontal speed,
        -- while adding only the amount of currentUp motion required to clear
        -- this particular riser.
        local rampUp = up
        if up:Dot(UP) < -0.985 then
            rampUp = -up
        end
        local rampVector = moveDir * targetRun + rampUp * targetRise
        local rampDirection = safeUnit(rampVector, moveDir)
        stairStepMove = rampDirection
        local stepHold = currentUp:Dot(UP) <= CFG.UpsideDownStairSafetyDot
            and CFG.StairCeilingStepHoldTime
            or CFG.StairStepHoldTime
        stairStepUntil = os.clock() + stepHold
        stairStepTargetBlend = 1
    elseif os.clock() >= stairStepUntil then
        stairStepTargetBlend = 0
    end

    stairStepBlend = stairStepBlend + (stairStepTargetBlend - stairStepBlend)
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
]=] },
    { name = '32_createControllers', source = [=[function createControllers()
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
]=] },
    { name = '33_isFloorUp', source = [=[function isFloorUp(up)
    return up:Dot(UP) > 0.985
end
]=] },
    { name = '34_suppressNativeWorkspaceGravity', source = [=[function suppressNativeWorkspaceGravity()
    if not workspaceGravitySuppressed then
        wallWalkGravity = workspace.Gravity
        workspaceGravitySuppressed = true
    elseif workspace.Gravity ~= 0 then
        -- If the experience changes its gravity while WallWalk is active,
        -- adopt that new local value and suppress it again. This keeps the
        -- custom system synchronized with the game's current gravity setting.
        wallWalkGravity = workspace.Gravity
    end

    if workspace.Gravity ~= 0 then
        pcall(function()
            workspace.Gravity = 0
        end)
    end
end
]=] },
    { name = '35_restoreNativeWorkspaceGravity', source = [=[function restoreNativeWorkspaceGravity()
    if not workspaceGravitySuppressed then
        return
    end

    local gravityToRestore = tonumber(wallWalkGravity) or 0
    workspaceGravitySuppressed = false

    pcall(function()
        workspace.Gravity = gravityToRestore
    end)
end
]=] },
    { name = '36_setControllerMode', source = [=[function setControllerMode(useCustomPhysics)
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
]=] },
    { name = '37_enterCustom', source = [=[function enterCustom(up)
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

    -- Remove native world gravity from the local simulation before the custom
    -- VectorForce becomes authoritative. The saved value is the actual Roblox
    -- gravity strength we will reproduce along currentUp.
    suppressNativeWorkspaceGravity()

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
]=] },
    { name = '38_leaveCustom', source = [=[function leaveCustom(forceFreefall)
    customActive = false
    if transitionClaim then
        local claimRoute = transitionClaim.route
        local claimTargetUp = safeUnit(transitionClaim.targetUp, UP)
        local isIntentionalFloorHandoff = nativeFloorHandoffInProgress == true
            and forceFreefall ~= true
            and claimTargetUp:Dot(UP) >= 0.985
            and (claimRoute == "wall-edge-to-floor" or claimRoute == "wall-to-floor")
        if isIntentionalFloorHandoff then
            wwWallDiag("WW_PIPE_NATIVE_FLOOR_HANDOFF",
                "route=" .. tostring(claimRoute)
                    .. ", seq=" .. tostring(transitionClaim.auditSequence or "unlinked")
                    .. ", outcome=completed-native-gravity-restored", 0)
            transitionCandidateAuditStats.completed = (transitionCandidateAuditStats.completed or 0) + 1
            wwSafeTransitionAuditCall("native-floor-completion", wwSetTransitionAuditPhaseForClaim,
                transitionClaim, "completed", "native-floor-handoff")
            wwFinishTransitionClaimRoute(transitionClaim, "completed", "native-floor-handoff", os.clock())
        else
            wwSafeTransitionAuditCall("native-release", wwRecordTransitionAuditAbort,
                transitionClaim, "leaveCustom-native-gravity-release"
            )
        end
    end
    transitionClaim = nil
    nativeFloorHandoffInProgress = false
    legacyEdgeCeilingSupportActive = false
    ceilingContactSupportReachActive = false
    legacyEdgeCeilingSourceWallHoldActive = false
    legacyEdgeCeilingHandoffPending = false
    legacyEdgeFloorSourceWallActive = false
    legacyEdgeFloorSourceUp = nil
    legacyEdgeFloorHandoffPosition = nil
    legacyEdgeFloorStartedAt = 0
    legacyEdgeFloorSourceWallIntentReleased = false
    wwResetTransitionRouteStates()
    floorToWallLock = nil
    edgeTransitionPending = nil
    forwardTransitionPending = nil
    transitionCandidateRoute = nil
    transitionCandidateHit = nil
    transitionCandidateNormal = nil
    transitionCandidateSupportGap = false
    restoreNativeWorkspaceGravity()
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
]=] },
    { name = '39_resetGravitySwitchBackState', source = [=[function resetGravitySwitchBackState()
    gravitySwitchBackUp = nil
    gravitySwitchBackAt = 0
    floorToWallLock = nil
end
]=] },
    { name = '40_resetSafeSurfaceState', source = [=[function resetSafeSurfaceState()
    surfaceLostAt = 0
    ceilingApproachHoldStartedAt = 0
    ceilingApproachHoldExpired = false
    ceilingApproachHoldInstance = nil
    ceilingApproachHoldPoint = nil
    ceilingApproachHoldNormal = nil
    nativeFloorHandoffInProgress = false
    wwResetTransitionRouteStates()
    gravityTransitionActive = false
    ceilingToWallLock = nil
    floorToWallLock = nil
    orientationTransitionUntil = 0
    transitionFacing = nil
    lastFacingDirection = nil
    transitionMoveCandidate = nil
    radialEdgeMemory = nil
    edgeTransitionPending = nil
    forwardTransitionPending = nil
    transitionCandidateRoute = nil
    transitionCandidateHit = nil
    transitionCandidateNormal = nil
    transitionCandidateSupportGap = false
    clearEdgeFloorApproach()
    if transitionClaim then
        wwSafeTransitionAuditCall("safe-state-reset", wwRecordTransitionAuditAbort,
            transitionClaim, "resetSafeSurfaceState-cleared-claim"
        )
    end
    transitionClaim = nil
    ceilingContactSupportReachActive = false
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
-- the new side and does not block switching to a third side.]=] },
    { name = '41_isGravitySwitchBackBlocked', source = [=[-- A transition can return to its source when actual body-to-surface contact
-- is verified. Input direction may provide intent, but it is not required when
-- physical contact itself proves the source surface has been regained. Cached
-- or distant candidate hits cannot clear the directional guard.
function wwIsIntentionalSurfaceReturn(candidateUp, moveVector, hit, normal)
    if not root or not moveVector or moveVector.Magnitude <= 0.05 then return false end
    if not hit or not hit.Instance or not hit.Instance.Parent or not hit.Position or not normal then
        return false
    end

    local candidate = safeUnit(candidateUp, currentUp)
    local surfaceNormal = safeUnit(normal, candidate)
    if surfaceNormal:Dot(candidate) < 0.90 then return false end

    -- Source returns require deliberate movement toward the candidate surface.
    -- Physical proximity by itself must never reverse a transition that has only
    -- just committed (for example floor->wall->floor on the next physics frame).
    local worldMove = getWorldMove(moveVector, safeUnit(currentUp, UP))
    local inputToward = worldMove.Magnitude > 0.05
        and worldMove.Unit:Dot(-candidate) >= CFG.EdgeFloorApproachInputDot
    if not inputToward then return false end

    if math.abs(candidate:Dot(UP)) >= 0.985 then
        -- For floor/ceiling returns, the ray point can be ahead along the plane.
        -- Test perpendicular body clearance plus a bounded tangent distance so a
        -- near-plane candidate is not rejected solely by point-to-box distance.
        local unusedContactGap, planeGap, tangentGap = getBodyPartFloorContactGap(
            hit.Position, surfaceNormal
        )
        local planeLimit = CFG.VerticalSurfaceContactGap + 0.10
        local tangentLimit = CFG.FloorContactTangentAllowance + 0.60
        local physicalPlaneContact = planeGap <= planeLimit and tangentGap <= tangentLimit
        if physicalPlaneContact then
            return true
        end
        local boundsGap = getCharacterSurfaceGap(hit.Position)
        if boundsGap <= planeLimit then
            wwWallDiag("WW_ROUTE_SOURCE_RETURN_REJECTED_BODY_GAP",
                "surface=" .. wwDescribeSurfaceOrientation(candidate)
                    .. ", boundsGap=" .. string.format("%.2f", boundsGap)
                    .. ", planeGap=" .. string.format("%.2f", planeGap)
                    .. ", tangentGap=" .. string.format("%.2f", tangentGap)
                    .. ", inputToward=true"
                    .. ", bodyPlaneContact=false"
                    .. ", planeLimit=" .. string.format("%.2f", planeLimit)
                    .. ", tangentLimit=" .. string.format("%.2f", tangentLimit), 0.20)
        end
        return false
    end

    local bodyGap = getBodyPartSurfaceGap(hit.Position)
    local physicalSurfaceContact = bodyGap <= CFG.VerticalSurfaceContactGap + 0.10
    if physicalSurfaceContact then return true end

    local boundsGap = getCharacterSurfaceGap(hit.Position)
    if boundsGap <= CFG.VerticalSurfaceContactGap + 0.10 then
        wwWallDiag("WW_ROUTE_SOURCE_RETURN_REJECTED_BODY_GAP",
            "surface=" .. wwDescribeSurfaceOrientation(candidate)
                .. ", boundsGap=" .. string.format("%.2f", boundsGap)
                .. ", bodyGap=" .. string.format("%.2f", bodyGap)
                .. ", inputToward=true"
                .. ", bodyContact=false"
                .. ", requiredBodyGap=" .. string.format("%.2f", CFG.VerticalSurfaceContactGap + 0.10), 0.20)
    end
    return false
end
function isGravitySwitchBackBlocked(candidateUp, now, moveVector, hit, normal)
    local candidate = safeUnit(candidateUp, currentUp)
    local deliberateSourceReturn = wwIsIntentionalSurfaceReturn(
        candidate, moveVector, hit, normal
    )
    local lock = ceilingToWallLock

    if lock then
        local age = now - (lock.startedAt or now)
        local sourceUp = safeUnit(lock.sourceUp, UP)
        local targetUp = safeUnit(lock.targetUp, currentUp)
        local candidateIsSourceCeiling = candidate:Dot(sourceUp) >= CFG.GravitySwitchBackDot
        local targetInstanceValid = lock.targetInstance ~= nil
            and lock.targetInstance.Parent ~= nil

        local sourceProgress = 0
        if root and lock.startPosition then
            sourceProgress = (root.Position - lock.startPosition):Dot(sourceUp)
        end
        local movedAway = sourceProgress >= CFG.CeilingToWallLockReleaseProgress
        local wallSupport = surfaceSupportSeen == true
            and typeof(surfaceSupportNormal) == "Vector3"
            and surfaceSupportNormal:Dot(targetUp) >= 0.90
            and (tonumber(surfaceSupportDistance) or math.huge) <= CFG.CeilingToWallLockSupportDistance

        if age > CFG.CeilingToWallLockMaxTime or not targetInstanceValid then
            ceilingToWallLock = nil
            wwWallDiag("CEILING_TO_WALL_LOCK_EXPIRED",
                "age=" .. string.format("%.2f", age)
                    .. ", progress=" .. string.format("%.2f", sourceProgress)
                    .. ", wallSupport=" .. tostring(wallSupport),
                0
            )
        elseif not candidateIsSourceCeiling and movedAway and wallSupport then
            ceilingToWallLock = nil
            wwWallDiag("CEILING_TO_WALL_LOCK_RELEASED",
                "age=" .. string.format("%.2f", age)
                    .. ", progress=" .. string.format("%.2f", sourceProgress)
                    .. ", supportDist=" .. string.format("%.2f", tonumber(surfaceSupportDistance) or math.huge),
                0
            )
        elseif candidateIsSourceCeiling and not deliberateSourceReturn then
            wwWallDiag("CEILING_TO_WALL_RETURN_BLOCKED",
                "age=" .. string.format("%.2f", age)
                    .. ", progress=" .. string.format("%.2f", sourceProgress)
                    .. ", wallSupport=" .. tostring(wallSupport)
                    .. ", supportDist=" .. tostring(surfaceSupportDistance),
                0.20
            )
            return true
        elseif candidateIsSourceCeiling and deliberateSourceReturn then
            wwWallDiag("CEILING_TO_WALL_RETURN_ALLOWED",
                "reason=directed-input-and-body-contact"
                    .. ", age=" .. string.format("%.2f", age)
                    .. ", progress=" .. string.format("%.2f", sourceProgress),
                0.15
            )
        end
    end

    local floorLock = floorToWallLock
    if floorLock then
        local lockAge = now - (floorLock.startedAt or now)
        local lockRise = 0
        if root and floorLock.startPosition then
            lockRise = (root.Position - floorLock.startPosition):Dot(UP)
        end
        local targetUp = safeUnit(floorLock.targetUp, currentUp)
        local targetAligned = floorLock.targetUp ~= nil
            and safeUnit(currentUp, UP):Dot(targetUp) >= CFG.GravitySwitchBackDot
        local targetSupportNormalMatches = safetySupportNormal ~= nil
            and safeUnit(safetySupportNormal, targetUp):Dot(targetUp) >= 0.90
        local targetSupportRootNear = (tonumber(safetySupportDistance) or math.huge)
            <= wwGetTransitionRootContactLimit()
        local targetSupportBodyGap = safetySupportPoint
            and getBodyPartSurfaceGap(safetySupportPoint) or math.huge
        local targetSupportBodyContact = targetSupportBodyGap
            <= CFG.VerticalSurfaceContactGap + 0.10
        local targetSupportNear = targetSupportNormalMatches
            and (targetSupportRootNear or targetSupportBodyContact)
        -- One body-contact frame on the new wall does not mean the character has
        -- cleared the old floor. Keep the source-floor guard until measurable
        -- separation occurs or the bounded timeout expires. Directed, verified
        -- contact back to the source floor is handled by the exception above.
        local sourceFloorCleared = lockRise >= CFG.FloorToWallReturnLockReleaseProgress
        local targetStable = transitionClaim == nil and targetAligned and targetSupportNear
            and sourceFloorCleared
        local candidateIsSourceFloor = candidate:Dot(UP) >= CFG.GravitySwitchBackDot

        if lockAge > CFG.FloorToWallReturnLockMaxTime or targetStable then
            floorToWallLock = nil
            wwWallDiag("FLOOR_TO_WALL_LOCK_RELEASED",
                "age=" .. string.format("%.2f", lockAge)
                    .. ", rise=" .. string.format("%.2f", lockRise)
                    .. ", targetStable=" .. tostring(targetStable)
                    .. ", targetSupportNear=" .. tostring(targetSupportNear)
                    .. ", targetSupportBodyGap=" .. string.format("%.2f", targetSupportBodyGap),
                0
            )
        elseif candidateIsSourceFloor and not deliberateSourceReturn then
            wwWallDiag("FLOOR_TO_WALL_RETURN_BLOCKED",
                "age=" .. string.format("%.2f", lockAge)
                    .. ", rise=" .. string.format("%.2f", lockRise)
                    .. ", targetAligned=" .. tostring(targetAligned)
                    .. ", targetSupportNear=" .. tostring(targetSupportNear),
                0.20
            )
            return true
        elseif candidateIsSourceFloor and deliberateSourceReturn then
            wwWallDiag("FLOOR_TO_WALL_RETURN_ALLOWED",
                "reason=directed-input-and-body-contact"
                    .. ", age=" .. string.format("%.2f", lockAge)
                    .. ", rise=" .. string.format("%.2f", lockRise),
                0.15
            )
        end
    end

    if deliberateSourceReturn then
        return false
    end

    if not gravitySwitchBackUp then
        return false
    end

    if now - gravitySwitchBackAt >= CFG.GravitySwitchBackCooldown then
        return false
    end

    return candidate:Dot(gravitySwitchBackUp) >= CFG.GravitySwitchBackDot
end
]=] },
    { name = '42_commitGravitySide', source = [=[function commitGravitySide(newUp)
    local oldUp = safeUnit(currentUp, UP)
    local committedUp = safeUnit(newUp, oldUp)
    ceilingContactSupportReachActive = committedUp:Dot(UP) <= -0.985
    if committedUp:Dot(UP) < 0.985 then
        legacyEdgeFloorSourceWallActive = false
        legacyEdgeFloorSourceUp = nil
        legacyEdgeFloorHandoffPosition = nil
        legacyEdgeFloorStartedAt = 0
        legacyEdgeFloorSourceWallIntentReleased = false
    end

    -- Only an explicit selection by the isolated v42-style wall-edge handler
    -- may enable the longer root-contact/adhesion envelope.
    local useLegacyEdgeCeilingSupport = legacyEdgeCeilingHandoffPending
    legacyEdgeCeilingHandoffPending = false
    if useLegacyEdgeCeilingSupport
        and transitionResolvedRoute == "wall-edge-to-ceiling-underside"
        and math.abs(oldUp:Dot(UP)) < 0.985
        and committedUp:Dot(UP) <= -0.985
    then
        legacyEdgeCeilingSupportActive = true
        legacyEdgeCeilingSourceWallHoldActive = true
        legacyEdgeCeilingSourceUp = oldUp
        legacyEdgeCeilingHandoffPosition = root and root.Position or nil
        legacyEdgeCeilingStartedAt = os.clock()
        wwWallDiag("WW_LEGACY_EDGE_CEILING_SUPPORT_MODE", "enabled=true, rootReach="
            .. string.format("%.2f", CFG.LegacyWallEdgeCeilingSupportDistance)
            .. ", sourceWallHold=directional-until-input-or-clear", 0)
    elseif committedUp:Dot(UP) > -0.985 then
        legacyEdgeCeilingSupportActive = false
        legacyEdgeCeilingSourceWallHoldActive = false
        legacyEdgeCeilingSourceUp = nil
        legacyEdgeCeilingHandoffPosition = nil
        legacyEdgeCeilingStartedAt = 0
    end

    if customActive and oldUp:Dot(committedUp) < CFG.GravitySwitchBackDot then
        local legacyRoute = transitionCandidateRoute
        local route = transitionResolvedRoute or legacyRoute
        local hit = transitionCandidateHit
        local normal = transitionCandidateNormal
        local validRoute = wwIsManagedTransitionRoute(route)
            or legacyRoute == "edge" or legacyRoute == "forward"
        if validRoute and hit and hit.Instance and hit.Instance.Parent and normal then
            local targetNormal = safeUnit(normal, committedUp)
            if targetNormal:Dot(committedUp) >= 0.90 then
                local handoffGrace = CFG.TransitionSupportGrace
                if oldUp:Dot(UP) <= -0.985
                    and math.abs(committedUp:Dot(UP)) < 0.30
                    and (route == "ceiling-to-wall" or route == "ceiling-edge-to-wall-underside"
                        or legacyRoute == "forward")
                then
                    handoffGrace = CFG.CeilingToWallHandoffGrace
                elseif route == "floor-edge-to-wall-underside" then
                    handoffGrace = CFG.FloorEdgeWallHandoffGrace
                elseif route == "wall-to-ceiling" then
                    handoffGrace = CFG.WallToCeilingHandoffGrace
                elseif route == "wall-edge-to-ceiling-underside" then
                    handoffGrace = CFG.WallEdgeCeilingHandoffGrace
                end
                local commitNow = os.clock()
                local oldClaim = transitionClaim
                local pipelineState = nil
                if wwIsManagedTransitionRoute(route) then
                    pipelineState = wwEnsureTransitionPipelineState(
                        route, oldUp, committedUp, hit, targetNormal, commitNow
                    )
                end
                if oldClaim then
                    wwSafeTransitionAuditCall("claim-replacement", wwRecordTransitionAuditClaimReplacement,
                        oldClaim, route, committedUp, commitNow
                    )
                    if oldClaim.pipelineState and oldClaim.pipelineState ~= pipelineState then
                        wwFinishTransitionClaimRoute(oldClaim, "superseded", "replaced-by-authorized-chain", commitNow)
                    end
                end
                transitionCommitSequence = transitionCommitSequence + 1
                transitionClaim = {
                    route = route,
                    legacyRoute = legacyRoute,
                    fromUp = oldUp,
                    targetUp = committedUp,
                    point = hit.Position,
                    normal = targetNormal,
                    instance = hit.Instance,
                    startedAt = commitNow,
                    grace = handoffGrace,
                    leaseId = transitionCommitSequence,
                    ownerAttemptId = pipelineState and pipelineState.attemptId or nil,
                    parentLeaseId = oldClaim and oldClaim.leaseId or nil,
                    pipelineState = pipelineState,
                    leasePhase = "committed",
                }
                wwSafeTransitionAuditCall("commit", wwRecordTransitionAuditCommit, transitionClaim)
                if pipelineState then
                    pipelineState.committedAt = commitNow
                    wwSetTransitionPipelinePhase(pipelineState, "committed", commitNow, "gravity-side-committed")
                end
                gravityTransitionActive = true
                wwWallDiag("TRANSITION_CLAIM_ARMED",
                    "route=" .. route
                        .. ", fromY=" .. string.format("%.2f", oldUp:Dot(UP))
                        .. ", toY=" .. string.format("%.2f", committedUp:Dot(UP)),
                    0
                )
            end
        end
    end

    -- Only remember a meaningful side change. Tiny normal drift should not
    -- restart the 0.1s anti-flip window every frame.
    if oldUp:Dot(committedUp) < CFG.GravitySwitchBackDot then
        gravitySwitchBackUp = oldUp
        gravitySwitchBackAt = os.clock()

        if oldUp:Dot(UP) >= 0.985 and math.abs(committedUp:Dot(UP)) < 0.30 then
            floorToWallLock = {
                targetUp = committedUp,
                startPosition = root and root.Position or nil,
                startedAt = os.clock(),
            }
            wwWallDiag("FLOOR_TO_WALL_LOCK_ARMED",
                "targetY=" .. string.format("%.2f", committedUp:Dot(UP))
                    .. ", maxTime=" .. string.format("%.2f", CFG.FloorToWallReturnLockMaxTime),
                0
            )
        elseif oldUp:Dot(UP) < 0.985 and committedUp:Dot(UP) >= 0.985 then
            floorToWallLock = nil
        end

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

    if ceilingToWallLock
        and committedUp:Dot(safeUnit(ceilingToWallLock.sourceUp, committedUp)) >= CFG.GravitySwitchBackDot
    then
        ceilingToWallLock = nil
        wwWallDiag("CEILING_TO_WALL_LOCK_CLEARED", "reason=returned-to-source-ceiling", 0)
    end

    if oldUp:Dot(UP) <= -0.985
        and math.abs(committedUp:Dot(UP)) < 0.30
        and transitionCandidateRoute == "forward"
        and transitionCandidateHit
        and transitionCandidateHit.Instance
    then
        ceilingToWallLock = {
            sourceUp = oldUp,
            targetUp = committedUp,
            startPosition = root and root.Position or nil,
            startedAt = os.clock(),
            targetInstance = transitionCandidateHit.Instance,
        }
        wwWallDiag("CEILING_TO_WALL_LOCK_ARMED",
            "route=forward, targetY=" .. string.format("%.2f", committedUp:Dot(UP))
                .. ", maxTime=" .. string.format("%.2f", CFG.CeilingToWallLockMaxTime),
            0
        )
    end

    currentUp = committedUp
    return committedUp
end
]=] },
    { name = '42f_updateLegacyEdgeFloorFreshIntent', source = [=[function wwUpdateLegacyEdgeFloorFreshIntent(moveVector)
    legacyEdgeFloorSourceWallInputDot = 0
    if not legacyEdgeFloorSourceWallActive then return end

    local sourceWallAge = os.clock() - (legacyEdgeFloorStartedAt or 0)
    local sourceWallUp = safeUnit(legacyEdgeFloorSourceUp, UP)
    if moveVector and moveVector.Magnitude > 0.05 then
        legacyEdgeFloorSourceWallInputDot = moveVector.Unit:Dot(-sourceWallUp)
    end

    -- Ignore the landing frame and its immediate follow-up, when the movement
    -- vector may still reflect the source-wall orientation. After the settle
    -- delay, neutral/away input arms a new deliberate return to the same wall.
    if sourceWallAge >= CFG.LegacyWallEdgeFloorSourceWallFreshIntentDelay
        and legacyEdgeFloorSourceWallInputDot < CFG.EdgeFloorApproachInputDot
        and legacyEdgeFloorSourceWallIntentReleased ~= true
    then
        legacyEdgeFloorSourceWallIntentReleased = true
        wwWallDiag("WW_LEGACY_EDGE_FLOOR_FRESH_INTENT_ARMED",
            "age=" .. string.format("%.2f", sourceWallAge)
                .. ", sourceWallInputDot=" .. string.format("%.2f", legacyEdgeFloorSourceWallInputDot)
                .. ", threshold=" .. string.format("%.2f", CFG.EdgeFloorApproachInputDot)
                .. ", reason=neutral-or-away-input-after-settle", 0)
    end
end
]=] },
    { name = '43_updateSurface', source = [=[function wwFindCurrentOwnedPlaneBodyContactSupport(currentUp)
    if not customActive or not root or not currentUp then return nil end
    local ownedUp = safeUnit(currentUp, UP)
    local ownedHit = cast(root.Position, -ownedUp, CFG.FaceProbeMaxSupportDistance)
    if not ownedHit or not ownedHit.Instance or not ownedHit.Instance.Parent or not ownedHit.Position then
        return nil
    end

    local ownedNormal = orientSurfaceNormal(ownedHit, -ownedUp)
    if not ownedNormal or ownedUp:Dot(ownedNormal) < CFG.SurfaceSafetySupportNormalDot then
        return nil
    end

    local ownedCanCollide = true
    if ownedHit.Instance:IsA("BasePart") then
        ownedCanCollide = ownedHit.Instance.CanCollide
    end
    if not ownedCanCollide then return nil end

    local ownedRootGap = math.abs((root.Position - ownedHit.Position):Dot(ownedNormal))
    local ownedBodyGap, ownedBodyPlaneGap, ownedBodyTangentGap =
        getBodyPartFloorContactGap(ownedHit.Position, ownedNormal)
    local ownedContactLimit = CFG.VerticalSurfaceContactGap + 0.10
    if ownedRootGap > CFG.FaceProbeMaxSupportDistance
        or ownedBodyGap > ownedContactLimit
        or ownedBodyPlaneGap > ownedContactLimit then
        return nil
    end

    wwWallDiag("WW_CURRENT_SUPPORT_FROM_OWNED_PLANE_CONTACT",
        "target=" .. tostring(ownedHit.Instance.Name)
            .. ", orientation=" .. wwDescribeSurfaceOrientation(ownedUp)
            .. ", supportDot=" .. string.format("%.2f", ownedUp:Dot(ownedNormal))
            .. ", rootPlaneGap=" .. string.format("%.2f", ownedRootGap)
            .. ", bodyContactGap=" .. string.format("%.2f", ownedBodyGap)
            .. ", bodyPlaneGap=" .. string.format("%.2f", ownedBodyPlaneGap)
            .. ", bodyTangentGap=" .. string.format("%.2f", ownedBodyTangentGap)
            .. ", reason=current-plane-ray-and-body-contact-confirmation", 0.20)

    return {
        point = ownedHit.Position,
        normal = ownedNormal,
        distance = ownedRootGap,
    }
end

function updateSurface(dt, moveVector)
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
    if surfaceCandidate ~= true then
        local resumedState = wwTryResumeQueuedTransitionCandidate(currentUp, moveVector, os.clock())
        if resumedState then
            detected = safeUnit(resumedState.toUp, currentUp)
            surfaceCandidate = true
            transitionCandidateRoute = resumedState.legacyRoute
            transitionCandidateHit = resumedState.hit
            transitionCandidateNormal = resumedState.normal
            transitionCandidateSupportGap = false
            wwWallDiag("WW_PIPE_QUEUED_CANDIDATE_RETRIED",
                "attempt=" .. tostring(resumedState.attemptId)
                    .. ", route=" .. tostring(resumedState.route)
                    .. ", state=queued-to-live-candidate", 0)
        end
    end
    if surfaceCandidate == true then
        wwSafeTransitionAuditCall("capture", wwCaptureTransitionCandidate,
            currentUp,
            detected,
            true,
            transitionCandidateRoute,
            transitionCandidateHit,
            transitionCandidateNormal,
            moveVector,
            os.clock()
        )
    else
        transitionCandidateAuditCurrent = nil
    end
    -- Edge-only landing handoff. The source wall must not steal gravity back
    -- while native floor physics is settling, but a deliberate input into that
    -- same wall must still be allowed to use the ordinary floor-to-wall route.
    if legacyEdgeFloorSourceWallActive then
        local floorSourceAge = os.clock() - (legacyEdgeFloorStartedAt or 0)
        wwUpdateLegacyEdgeFloorFreshIntent(moveVector)
        local floorSourceCandidate = currentUp:Dot(UP) >= 0.985
            and surfaceCandidate == true
            and math.abs(detected:Dot(UP)) < 0.985
            and (transitionCandidateRoute == "forward" or transitionCandidateRoute == "edge")
            and transitionCandidateHit and transitionCandidateNormal
            and legacyEdgeFloorSourceUp and legacyEdgeFloorHandoffPosition
        if floorSourceCandidate then
            local floorSourceUp = safeUnit(legacyEdgeFloorSourceUp, UP)
            local floorSourceNormal = safeUnit(transitionCandidateNormal, floorSourceUp)
            local floorSourceProgress = (root.Position - legacyEdgeFloorHandoffPosition):Dot(floorSourceUp)
            local floorSourcePlaneOffset = math.abs((transitionCandidateHit.Position - legacyEdgeFloorHandoffPosition):Dot(floorSourceUp))
            local sameSourceWall = detected:Dot(floorSourceUp) >= 0.90
                and floorSourceNormal:Dot(floorSourceUp) >= 0.90
                and floorSourcePlaneOffset <= 3.50
            if sameSourceWall then
                local deliberateWallIntent, sourceWallGap = wwIsIntentionalSourceWallTransition(
                    transitionCandidateHit, UP, moveVector
                )
                local floorGrounded = getGrounded(UP)
                -- Honor the configured settling hold before positional progress
                -- can release this guard. A fast step previously bypassed the
                -- 0.55s window (the .98 log showed progress=1.01 at ~0.08s).
                if deliberateWallIntent and legacyEdgeFloorSourceWallIntentReleased == true then
                    legacyEdgeFloorSourceWallActive = false
                    legacyEdgeFloorSourceUp = nil
                    legacyEdgeFloorHandoffPosition = nil
                    legacyEdgeFloorStartedAt = 0
                    legacyEdgeFloorSourceWallIntentReleased = false
                    wwWallDiag("WW_LEGACY_EDGE_FLOOR_SOURCE_WALL_RELEASED",
                        "reason=fresh-directed-floor-to-wall, gap=" .. string.format("%.2f", sourceWallGap)
                            .. ", groundedFloor=" .. tostring(floorGrounded)
                            .. ", freshIntentReady=true", 0)
                elseif floorGrounded or floorSourceAge <= CFG.LegacyWallEdgeFloorSourceWallHoldTime then
                    detected = currentUp
                    surfaceCandidate = false
                    transitionCandidateRoute = nil
                    transitionCandidateHit = nil
                    transitionCandidateNormal = nil
                    transitionCandidateSupportGap = false
                    wwWallDiag("WW_LEGACY_EDGE_FLOOR_SOURCE_WALL_HELD",
                        "age=" .. string.format("%.2f", floorSourceAge)
                            .. ", groundedFloor=" .. tostring(floorGrounded)
                            .. ", progress=" .. string.format("%.2f", floorSourceProgress)
                            .. ", planeOffset=" .. string.format("%.2f", floorSourcePlaneOffset)
                            .. ", deliberateWallIntent=" .. tostring(deliberateWallIntent)
                            .. ", freshIntentReady=" .. tostring(legacyEdgeFloorSourceWallIntentReleased == true)
                            .. ", sourceWallInputDot=" .. string.format("%.2f", legacyEdgeFloorSourceWallInputDot),
                        0.12
                    )
                elseif floorSourceProgress >= CFG.LegacyWallEdgeFloorSourceWallClearProgress then
                    legacyEdgeFloorSourceWallActive = false
                    legacyEdgeFloorSourceUp = nil
                    legacyEdgeFloorHandoffPosition = nil
                    legacyEdgeFloorStartedAt = 0
                    legacyEdgeFloorSourceWallIntentReleased = false
                    wwWallDiag("WW_LEGACY_EDGE_FLOOR_SOURCE_WALL_RELEASED",
                        "reason=source-wall-cleared, progress=" .. string.format("%.2f", floorSourceProgress), 0)
                else
                    legacyEdgeFloorSourceWallActive = false
                    legacyEdgeFloorSourceUp = nil
                    legacyEdgeFloorHandoffPosition = nil
                    legacyEdgeFloorStartedAt = 0
                    legacyEdgeFloorSourceWallIntentReleased = false
                    wwWallDiag("WW_LEGACY_EDGE_FLOOR_SOURCE_WALL_RELEASED",
                        "reason=unsupported-timeout, groundedFloor=false", 0)
                end
            else
                -- A different wall is not part of this handoff and must never be blocked.
                legacyEdgeFloorSourceWallActive = false
                legacyEdgeFloorSourceUp = nil
                legacyEdgeFloorHandoffPosition = nil
                legacyEdgeFloorStartedAt = 0
                legacyEdgeFloorSourceWallIntentReleased = false
                wwWallDiag("WW_LEGACY_EDGE_FLOOR_SOURCE_WALL_RELEASED",
                    "reason=different-wall-candidate", 0)
            end
        elseif floorSourceAge > CFG.LegacyWallEdgeFloorSourceWallHoldTime and not getGrounded(UP) then
            legacyEdgeFloorSourceWallActive = false
            legacyEdgeFloorSourceUp = nil
            legacyEdgeFloorHandoffPosition = nil
            legacyEdgeFloorStartedAt = 0
            legacyEdgeFloorSourceWallIntentReleased = false
            wwWallDiag("WW_LEGACY_EDGE_FLOOR_SOURCE_WALL_RELEASED",
                "reason=unsupported-timeout", 0)
        end
    end

    -- Keep ceiling adhesion support and source-wall suppression as separate states.
    -- Only suppress the previous wall while the legacy ceiling handoff is settling;
    -- pressing toward that wall with verified near-contact releases suppression so
    -- the ordinary ceiling-to-wall route can run immediately.
    if legacyEdgeCeilingSourceWallHoldActive
        and legacyEdgeCeilingSupportActive
        and currentUp:Dot(UP) <= -0.985
        and surfaceCandidate == true
        and math.abs(detected:Dot(UP)) < 0.985
        and (transitionCandidateRoute == "forward" or transitionCandidateRoute == "edge")
        and transitionCandidateHit and transitionCandidateNormal
        and legacyEdgeCeilingSourceUp
        and legacyEdgeCeilingHandoffPosition
    then
        local sourceUp = safeUnit(legacyEdgeCeilingSourceUp, UP)
        local candidateNormal = safeUnit(transitionCandidateNormal, sourceUp)
        local sourceAge = os.clock() - (legacyEdgeCeilingStartedAt or 0)
        local sourceProgress = (root.Position - legacyEdgeCeilingHandoffPosition):Dot(sourceUp)
        local sourcePlaneOffset = math.abs((transitionCandidateHit.Position - legacyEdgeCeilingHandoffPosition):Dot(sourceUp))
        local sameSourceWall = detected:Dot(sourceUp) >= 0.90
            and candidateNormal:Dot(sourceUp) >= 0.90
            and sourcePlaneOffset <= 3.50
        if sameSourceWall then
            local deliberateWallIntent, sourceWallGap = wwIsIntentionalSourceWallTransition(
                transitionCandidateHit, currentUp, moveVector
            )
            if deliberateWallIntent then
                legacyEdgeCeilingSourceWallHoldActive = false
                wwWallDiag("WW_LEGACY_EDGE_CEILING_SOURCE_WALL_RELEASED",
                    "reason=directed-ceiling-to-wall, age=" .. string.format("%.2f", sourceAge)
                        .. ", gap=" .. string.format("%.2f", sourceWallGap), 0)
            elseif sourceProgress < CFG.LegacyWallEdgeCeilingSourceWallClearProgress then
                detected = currentUp
                surfaceCandidate = false
                transitionCandidateRoute = nil
                transitionCandidateHit = nil
                transitionCandidateNormal = nil
                transitionCandidateSupportGap = false
                wwWallDiag("WW_LEGACY_EDGE_CEILING_SOURCE_WALL_HELD",
                    "age=" .. string.format("%.2f", sourceAge)
                        .. ", progress=" .. string.format("%.2f", sourceProgress)
                        .. ", planeOffset=" .. string.format("%.2f", sourcePlaneOffset),
                    0.20
                )
            else
                legacyEdgeCeilingSourceWallHoldActive = false
                wwWallDiag("WW_LEGACY_EDGE_CEILING_SOURCE_WALL_RELEASED",
                    "reason=source-wall-cleared, age=" .. string.format("%.2f", sourceAge)
                        .. ", progress=" .. string.format("%.2f", sourceProgress), 0)
            end
        else
            -- A different wall is an independent destination, not the previous source.
            legacyEdgeCeilingSourceWallHoldActive = false
            wwWallDiag("WW_LEGACY_EDGE_CEILING_SOURCE_WALL_RELEASED",
                "reason=different-wall-candidate, age=" .. string.format("%.2f", sourceAge), 0)
        end
    end

    local legacyEdgeFloorSwitchbackBlocked = false
    if surfaceCandidate == true
        and transitionCandidateRoute == "edge"
        and math.abs(currentUp:Dot(UP)) < 0.985
        and detected:Dot(UP) >= 0.985
    then
        legacyEdgeFloorSwitchbackBlocked = isGravitySwitchBackBlocked(
            detected, os.clock(), moveVector, transitionCandidateHit, transitionCandidateNormal
        )
    end
    local legacyEdgeHandoffRoute, legacyEdgeFloorGuardOverride = wwGetLegacyWallEdgeHandoffRoute(
        currentUp,
        detected,
        surfaceCandidate == true,
        transitionCandidateRoute,
        transitionCandidateHit,
        transitionCandidateNormal,
        moveVector,
        legacyEdgeFloorSwitchbackBlocked,
        supportSeen == true
    )
    if legacyEdgeHandoffRoute and transitionClaim
        and transitionClaim.route ~= legacyEdgeHandoffRoute
    then
        local ownerTargetContact = wwIsClaimTargetPhysicallyReached(currentUp, transitionClaim)
        local ownerSupportStable = wwIsTransitionClaimSupportStable(transitionClaim, os.clock())
        -- Preserve the existing special edge-ceiling path. Other legacy fast paths
        -- cannot skip the owner's stable-support confirmation merely because limbs
        -- briefly touch its target plane during rotation.
        local edgeCeilingException = legacyEdgeHandoffRoute == "wall-edge-to-ceiling-underside"
        if not ownerTargetContact or (not ownerSupportStable and not edgeCeilingException) then
            wwWallDiag("WW_LEGACY_EDGE_HANDOFF_DEFERRED_BY_OWNER",
                "owner=" .. tostring(transitionClaim.route)
                    .. ", candidate=" .. tostring(legacyEdgeHandoffRoute)
                    .. ", ownerAge=" .. string.format("%.3f", os.clock() - (transitionClaim.startedAt or os.clock()))
                    .. ", ownerTargetContact=" .. tostring(ownerTargetContact)
                    .. ", ownerSupportStable=" .. tostring(ownerSupportStable)
                    .. ", supportStableFor=" .. string.format("%.3f", transitionClaim.supportSince and math.max(0, os.clock() - transitionClaim.supportSince) or 0)
                    .. ", required=" .. string.format("%.3f", CFG.TransitionSupportConfirmTime)
                    .. ", reason=legacy-edge-cannot-replace-unconfirmed-owner", 0.08)
            legacyEdgeHandoffRoute = nil
            legacyEdgeFloorGuardOverride = false
        end
    end
    legacyEdgeCeilingHandoffPending = legacyEdgeHandoffRoute == "wall-edge-to-ceiling-underside"
    local routeAllowed = true
    local resolvedRoute = legacyEdgeHandoffRoute
    if not legacyEdgeHandoffRoute then
        routeAllowed, resolvedRoute = wwAuthorizeTransitionCandidate(
            currentUp,
            detected,
            surfaceCandidate == true,
            transitionCandidateRoute,
            transitionCandidateHit,
            transitionCandidateNormal,
            moveVector,
            os.clock()
        )
    end
    if transitionCandidateAuditCurrent then
        wwSafeTransitionAuditCall("decision", wwRecordTransitionCandidateDecision,
            transitionCandidateAuditCurrent, routeAllowed, resolvedRoute, os.clock()
        )
    end
    transitionResolvedRoute = resolvedRoute
    if not routeAllowed then
        detected = currentUp
        surfaceCandidate = false
        transitionResolvedRoute = nil
        transitionCandidateRoute = nil
        transitionCandidateHit = nil
        transitionCandidateNormal = nil
        transitionCandidateSupportGap = false
    end

    -- v48.76.105: a managed ceiling candidate may itself be the current support.
    -- The ordinary support fan gates on AdhesionProbeLength (2.75 studs), which
    -- can miss while the avatar's head/body already touches an underside and the
    -- root remains about 3.4 studs from that plane. Do not infer support from a
    -- nearby candidate alone: require a managed ceiling route, a collidable
    -- target, a matching current gravity normal, and measured body-part contact.
    if not supportSeen and surfaceCandidate == true and root
        and transitionCandidateHit and transitionCandidateHit.Instance
        and transitionCandidateHit.Instance.Parent
        and transitionCandidateHit.Position and transitionCandidateNormal
        and (transitionResolvedRoute == "wall-to-ceiling"
            or transitionCandidateRoute == "wall-to-ceiling"
            or transitionResolvedRoute == "wall-edge-to-ceiling-underside"
            or transitionCandidateRoute == "wall-edge-to-ceiling-underside")
    then
        local contactUp = safeUnit(currentUp, UP)
        local candidateNormal = safeUnit(transitionCandidateNormal, contactUp)
        local candidateInstance = transitionCandidateHit.Instance
        local candidateCanCollide = true
        if candidateInstance:IsA("BasePart") then
            candidateCanCollide = candidateInstance.CanCollide
        end
        local supportDot = contactUp:Dot(candidateNormal)
        local rootPlaneGap = math.abs((root.Position - transitionCandidateHit.Position):Dot(candidateNormal))
        local bodyContactGap, bodyPlaneGap, bodyTangentGap =
            getBodyPartFloorContactGap(transitionCandidateHit.Position, candidateNormal)
        local bodyContactLimit = CFG.VerticalSurfaceContactGap + 0.10
        if candidateCanCollide
            and supportDot >= CFG.SurfaceSafetySupportNormalDot
            and rootPlaneGap <= CFG.FaceProbeMaxSupportDistance
            and bodyContactGap <= bodyContactLimit
            and bodyPlaneGap <= bodyContactLimit
        then
            supportSeen = true
            supportPoint = transitionCandidateHit.Position
            supportNormal = candidateNormal
            supportDistance = rootPlaneGap
            wwWallDiag("WW_CURRENT_SUPPORT_FROM_CONTACT_CANDIDATE",
                "route=" .. tostring(transitionResolvedRoute or transitionCandidateRoute)
                    .. ", target=" .. tostring(candidateInstance.Name)
                    .. ", supportDot=" .. string.format("%.2f", supportDot)
                    .. ", rootPlaneGap=" .. string.format("%.2f", rootPlaneGap)
                    .. ", bodyContactGap=" .. string.format("%.2f", bodyContactGap)
                    .. ", bodyPlaneGap=" .. string.format("%.2f", bodyPlaneGap)
                    .. ", bodyTangentGap=" .. string.format("%.2f", bodyTangentGap)
                    .. ", reason=managed-target-body-contact-confirms-current-support", 0.25)
        end
    end

    -- v48.76.106: after a wall/ceiling handoff, a competing candidate can
    -- replace transitionCandidateHit before the ordinary support fan reacquires
    -- the currently owned face. Test that face independently, with real body
    -- contact, rather than trusting the unrelated transition candidate.
    if not supportSeen and customActive and root
        and math.abs(currentUp:Dot(UP)) < 0.985 then
        local ownedContactSupport = wwFindCurrentOwnedPlaneBodyContactSupport(currentUp)
        if ownedContactSupport then
            supportSeen = true
            supportPoint = ownedContactSupport.point
            supportNormal = ownedContactSupport.normal
            supportDistance = ownedContactSupport.distance
        end
    end

    surfaceSupportSeen = supportSeen == true
    surfaceSupportPoint = supportPoint
    surfaceSupportNormal = supportNormal
    surfaceSupportDistance = supportDistance
    local detectionDot = math.clamp(currentUp:Dot(detected), -1, 1)

    if customActive and math.abs(currentUp:Dot(UP)) < 0.985 then
        if surfaceCandidate and detected:Dot(UP) < -0.985 then
            wwWallDiag("WALL_TO_CEILING_CANDIDATE",
                "dot=" .. string.format("%.2f", detectionDot)
                    .. ", support=" .. tostring(surfaceSupportSeen)
                    .. ", supportDist=" .. tostring(surfaceSupportDistance)
                    .. ", moveMag=" .. string.format("%.2f", moveVector and moveVector.Magnitude or 0)
                    .. ", posY=" .. string.format("%.2f", root.Position.Y),
                0.35
            )
        elseif surfaceCandidate and detected:Dot(UP) > 0.985 then
            if wwWallDiagDue("VERTICAL_WALL_FLOOR_NORMAL_CANDIDATE", 0.35) then
                wwWallDiag("VERTICAL_WALL_FLOOR_NORMAL_CANDIDATE",
                "meaning=upward-normal-floor-candidate-not-proof-of-edge"
                    .. ", candidateRoute=" .. tostring(transitionCandidateRoute)
                    .. ", resolvedRoute=" .. tostring(transitionResolvedRoute)
                    .. ", target=" .. wwEdgeForensicInstancePath(transitionCandidateHit and transitionCandidateHit.Instance)
                    .. ", point=" .. wwEdgeForensicVector(transitionCandidateHit and transitionCandidateHit.Position)
                    .. ", normal=" .. wwEdgeForensicVector(transitionCandidateNormal)
                    .. ", root=" .. wwEdgeForensicVector(root.Position)
                    .. ", pointDist=" .. string.format("%.3f", transitionCandidateHit and (transitionCandidateHit.Position - root.Position).Magnitude or math.huge)
                    .. ", support=" .. tostring(surfaceSupportSeen)
                    .. ", supportDist=" .. tostring(surfaceSupportDistance)
                    .. ", supportPoint=" .. wwEdgeForensicVector(surfaceSupportPoint)
                    .. ", supportNormal=" .. wwEdgeForensicVector(surfaceSupportNormal)
                    .. ", moveMag=" .. string.format("%.2f", moveVector and moveVector.Magnitude or 0)
                    .. ", posY=" .. string.format("%.2f", root.Position.Y),
                0.35
                )
            end
        end
    end

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
    local switchBackBlocked = isGravitySwitchBackBlocked(
        detected, os.clock(), moveVector, transitionCandidateHit, transitionCandidateNormal
    )

    -- v42 floor-edge behaviour: once the edge candidate is within the old
    -- bounded point-distance and direction/contact qualification, return native
    -- gravity directly. Do not send this one route through the newer body/tangent
    -- contact gate or a stale floor-to-wall return claim.
    if customActive and legacyEdgeHandoffRoute == "wall-edge-to-floor"
        and (not switchBackBlocked or legacyEdgeFloorGuardOverride) then
        local edgeFloorPointDistance = (transitionCandidateHit.Position - root.Position).Magnitude
        local edgeFloorSurfaceGap, edgeFloorPlaneGap, edgeFloorTangentGap =
            getBodyPartFloorContactGap(transitionCandidateHit.Position, transitionCandidateNormal)
        local edgeFloorMovingToward = isMovementTowardSurfacePoint(transitionCandidateHit.Position, currentUp, moveVector)
        local edgeFloorCommitReason = legacyEdgeFloorQualificationReason or "qualification-branch-not-captured"
        local edgeFloorTangentLimit = CFG.FloorContactTangentAllowance + 0.60
            + getEdgeHorizontalSpeedLead(currentUp, moveVector)
        local edgeFloorSourceWallUp = safeUnit(currentUp, UP)
        local edgeFloorHandoffPosition = root.Position
        wwWallDiag("EDGE_FLOOR_GRAVITY_COMMIT",
            "reason=" .. edgeFloorCommitReason
                .. ", pointDist=" .. string.format("%.2f", edgeFloorPointDistance)
                .. ", pointLimit=" .. string.format("%.2f", CFG.SurfaceSwitchDistance)
                .. ", surfaceGap=" .. string.format("%.2f", edgeFloorSurfaceGap)
                .. ", bodyPlaneGap=" .. string.format("%.2f", edgeFloorPlaneGap)
                .. ", tangentGap=" .. string.format("%.2f", edgeFloorTangentGap)
                .. ", tangentLimit=" .. string.format("%.2f", edgeFloorTangentLimit)
                .. ", pointWithinLimit=" .. tostring(edgeFloorPointDistance <= CFG.SurfaceSwitchDistance)
                .. ", planeWithinLimit=" .. tostring(edgeFloorPlaneGap <= CFG.VerticalSurfaceContactGap + 0.10)
                .. ", tangentWithinLimit=" .. tostring(edgeFloorTangentGap <= edgeFloorTangentLimit)
                .. ", movingToward=" .. tostring(edgeFloorMovingToward)
                .. ", switchbackOverride=" .. tostring(switchBackBlocked)
                .. ", contactGuardOverride=" .. tostring(legacyEdgeFloorGuardOverride),
            0
        )
        clearEdgeFloorApproach()
        commitGravitySide(UP)
        nativeFloorHandoffInProgress = true
        leaveCustom()
        legacyEdgeFloorSourceWallActive = true
        legacyEdgeFloorSourceUp = edgeFloorSourceWallUp
        legacyEdgeFloorHandoffPosition = edgeFloorHandoffPosition
        legacyEdgeFloorStartedAt = os.clock()
        legacyEdgeFloorSourceWallIntentReleased = false
        wwWallDiag("WW_LEGACY_EDGE_FLOOR_SOURCE_WALL_HOLD",
            "enabled=true, hold=" .. string.format("%.2f", CFG.LegacyWallEdgeFloorSourceWallHoldTime), 0)
        return
    end

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
    if customActive and surfaceCandidate and not microSurfaceChange and (strongChange or meaningfulChange) and not switchBackBlocked then
        gravityTransitionActive = true
    end

    if not customActive then
        -- On the ordinary floor, DO NOT enter custom mode merely because the
        -- controller is ON. Roblox must keep native walking/jumping here.
        -- We only take over when the sensor sees a genuinely different surface.
        local nonFloor = detected:Dot(UP) < 0.985
        if surfaceCandidate and nonFloor and (strongChange or meaningfulChange) and not switchBackBlocked then
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
        -- If floor return is blocked briefly by the anti-flip cooldown, log it
        -- separately from a missing edge candidate or a failed contact gate.
        if surfaceCandidate and detected:Dot(UP) > 0.985
            and currentUp:Dot(UP) < 0.985 and switchBackBlocked
        then
            wwWallDiag("FLOOR_RESET_SWITCHBACK_BLOCKED",
                "currentUpY=" .. string.format("%.2f", currentUp:Dot(UP))
                    .. ", moveMag=" .. string.format("%.2f", moveVector and moveVector.Magnitude or 0)
                    .. ", surfaceGap=" .. string.format("%.2f", transitionCandidateHit and transitionCandidateHit.Position and transitionCandidateNormal and getBodyPartFloorContactGap(transitionCandidateHit.Position, transitionCandidateNormal) or math.huge),
                0
            )
        end

        -- If the detector has reached the ordinary floor again, immediately
        -- hand the Humanoid back to Roblox. Do this BEFORE the generic
        -- surfaceCandidate branch so a floor normal cannot keep the custom
        -- controller alive indefinitely.
        if surfaceCandidate and detected:Dot(UP) > 0.985
            and currentUp:Dot(UP) < 0.985
        then
            -- Floor acceptance uses body clearance perpendicular to the floor
            -- plus a bounded tangential allowance. A forward ray can hit ahead
            -- of the body, so the combined 3D score alone delayed real landings.
            -- Tangential reach remains bounded to avoid accepting a distant floor.
            local floorGapLimit = CFG.VerticalSurfaceContactGap
            local supportFloorPointDistance = surfaceSupportPoint and (surfaceSupportPoint - root.Position).Magnitude or math.huge
            local supportFloorPlaneDistance = surfaceSupportPoint and surfaceSupportNormal
                and math.abs((root.Position - surfaceSupportPoint):Dot(surfaceSupportNormal)) or math.huge
            local supportFloorSurfaceGap = math.huge
            local supportFloorBodyPlaneGap = math.huge
            local supportFloorTangentGap = math.huge
            if surfaceSupportPoint and surfaceSupportNormal then
                supportFloorSurfaceGap, supportFloorBodyPlaneGap, supportFloorTangentGap =
                    getBodyPartFloorContactGap(surfaceSupportPoint, surfaceSupportNormal)
            end
            local confirmedSupportFloorContact = surfaceSupportSeen
                and surfaceSupportNormal ~= nil
                and surfaceSupportNormal:Dot(UP) >= 0.985
                and supportFloorBodyPlaneGap <= floorGapLimit + 0.10
                and supportFloorTangentGap <= CFG.FloorContactTangentAllowance + 0.45

            local candidateFloorDistance = math.huge
            local candidateFloorPointDistance = math.huge
            local candidateFloorSurfaceGap = math.huge
            local candidateFloorBodyPlaneGap = math.huge
            local candidateFloorTangentGap = math.huge
            local candidateFloorTangentLimit = CFG.FloorContactTangentAllowance + 0.45
            local candidateFloorMovingToward = false
            local candidateFloorContact = false
            local floorCandidateHit = transitionCandidateHit
            local floorCandidateNormal = transitionCandidateNormal
            local floorCandidateRoute = transitionCandidateRoute
            if (floorCandidateRoute == "edge" or floorCandidateRoute == "forward")
                and floorCandidateHit and floorCandidateHit.Instance and floorCandidateHit.Instance.Parent
                and floorCandidateNormal and floorCandidateNormal:Dot(UP) >= 0.985
            then
                candidateFloorDistance = math.abs((root.Position - floorCandidateHit.Position):Dot(floorCandidateNormal))
                candidateFloorPointDistance = (root.Position - floorCandidateHit.Position).Magnitude
                candidateFloorSurfaceGap, candidateFloorBodyPlaneGap, candidateFloorTangentGap =
                    getBodyPartFloorContactGap(floorCandidateHit.Position, floorCandidateNormal)
                if floorCandidateRoute == "edge" then
                    candidateFloorMovingToward = isMovementTowardSurfacePoint(
                        floorCandidateHit.Position, currentUp, moveVector
                    )
                    candidateFloorTangentLimit = candidateFloorTangentLimit
                        + getEdgeHorizontalSpeedLead(currentUp, moveVector)
                end
                candidateFloorContact = candidateFloorBodyPlaneGap <= floorGapLimit + 0.10
                    and candidateFloorTangentGap <= candidateFloorTangentLimit
                    and (candidateFloorTangentGap <= CFG.FloorContactTangentAllowance
                        or candidateFloorMovingToward)
            end

            local confirmedFloorContact = confirmedSupportFloorContact or candidateFloorContact
            -- A validated wall-edge -> floor contact is the intended destination,
            -- not a spurious return to the source floor. Let its plane/tangent
            -- geometry outrank the short anti-flip guard from the preceding wall
            -- transition; all other floor returns keep the guard.
            local intentionalEdgeFloorReturn = floorCandidateRoute == "edge"
                and transitionResolvedRoute == "wall-edge-to-floor"
                and candidateFloorContact
            if confirmedFloorContact and switchBackBlocked and not intentionalEdgeFloorReturn then
                wwWallDiag("FLOOR_RESET_SOURCE_GUARD_BLOCKED",
                    "sourceFloor=true"
                        .. ", contactGap=" .. string.format("%.2f", confirmedSupportFloorContact and supportFloorSurfaceGap or candidateFloorSurfaceGap)
                        .. ", bodyPlaneGap=" .. string.format("%.2f", confirmedSupportFloorContact and supportFloorBodyPlaneGap or candidateFloorBodyPlaneGap)
                        .. ", tangentGap=" .. string.format("%.2f", confirmedSupportFloorContact and supportFloorTangentGap or candidateFloorTangentGap),
                    0.15
                )
                return
            end
            if confirmedFloorContact then
                if floorCandidateRoute == "edge"
                    and transitionResolvedRoute == "wall-edge-to-floor"
                    and candidateFloorContact
                then
                    wwWallDiag("EDGE_FLOOR_GRAVITY_COMMIT",
                        "reason=validated-edge-contact"
                            .. ", bodyPlaneGap=" .. string.format("%.2f", candidateFloorBodyPlaneGap)
                            .. ", tangentGap=" .. string.format("%.2f", candidateFloorTangentGap)
                            .. ", switchbackOverride=" .. tostring(switchBackBlocked),
                        0
                    )
                end
                local floorDistance = confirmedSupportFloorContact
                    and supportFloorPlaneDistance
                    or candidateFloorDistance
                local floorSource = confirmedSupportFloorContact and "support-sensor" or "target-plane"
                wwWallDiag("FLOOR_GRAVITY_RESET",
                    "source=" .. floorSource
                        .. ", route=" .. tostring(floorCandidateRoute)
                        .. ", currentUpY=" .. string.format("%.2f", currentUp:Dot(UP))
                        .. ", detectedY=" .. string.format("%.2f", detected:Dot(UP))
                        .. ", support=" .. tostring(surfaceSupportSeen)
                        .. ", floorPlaneDist=" .. string.format("%.2f", floorDistance)
                        .. ", floorPointDist=" .. string.format("%.2f", confirmedSupportFloorContact and supportFloorPointDistance or candidateFloorPointDistance)
                        .. ", contactGap=" .. string.format("%.2f", confirmedSupportFloorContact and supportFloorSurfaceGap or candidateFloorSurfaceGap)
                        .. ", bodyPlaneGap=" .. string.format("%.2f", confirmedSupportFloorContact and supportFloorBodyPlaneGap or candidateFloorBodyPlaneGap)
                        .. ", tangentGap=" .. string.format("%.2f", confirmedSupportFloorContact and supportFloorTangentGap or candidateFloorTangentGap)
                        .. ", gapLimit=" .. string.format("%.2f", floorGapLimit)
                        .. ", gapMetric=plane-clearance+tangent-excess"
                        .. ", tangentLimit=" .. string.format("%.2f", confirmedSupportFloorContact
                            and (CFG.FloorContactTangentAllowance + 0.45) or candidateFloorTangentLimit)
                        .. ", movingToward=" .. tostring(confirmedSupportFloorContact or candidateFloorMovingToward)
                        .. ", moveMag=" .. string.format("%.2f", moveVector and moveVector.Magnitude or 0)
                        .. ", posY=" .. string.format("%.2f", root.Position.Y),
                    0
                )
                clearEdgeFloorApproach()
                commitGravitySide(UP)
                nativeFloorHandoffInProgress = transitionResolvedRoute == "wall-edge-to-floor"
                    or transitionResolvedRoute == "wall-to-floor"
                leaveCustom()
                return
            else
                -- A broad floor-facing candidate is not enough to cancel wall
                -- gravity. A route-qualified target must be within the same
                -- body-to-surface gap; a distant floor underneath the climb
                -- cannot steal gravity prematurely.
                wwWallDiag("FLOOR_RESET_REJECTED_NO_CONTACT",
                    "support=" .. tostring(surfaceSupportSeen)
                        .. ", supportSensorDistance=" .. tostring(surfaceSupportDistance)
                        .. ", supportPointDist=" .. string.format("%.2f", supportFloorPointDistance)
                        .. ", rootPlaneDist=" .. string.format("%.2f", candidateFloorDistance)
                        .. ", supportContactGap=" .. string.format("%.2f", supportFloorSurfaceGap)
                        .. ", supportBodyPlaneGap=" .. string.format("%.2f", supportFloorBodyPlaneGap)
                        .. ", supportTangentGap=" .. string.format("%.2f", supportFloorTangentGap)
                        .. ", candidateContactGap=" .. string.format("%.2f", candidateFloorSurfaceGap)
                        .. ", candidateBodyPlaneGap=" .. string.format("%.2f", candidateFloorBodyPlaneGap)
                        .. ", candidateTangentGap=" .. string.format("%.2f", candidateFloorTangentGap)
                        .. ", gapLimit=" .. string.format("%.2f", floorGapLimit)
                        .. ", gapMetric=plane-clearance+tangent-excess"
                        .. ", worldYVel=" .. string.format("%.2f", root.AssemblyLinearVelocity:Dot(UP))
                        .. ", posY=" .. string.format("%.2f", root.Position.Y),
                    0.25
                )
                return
            end
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
]=] },
    { name = '44_getSafetySupport', source = [=[function getSafetySupport()
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
    local supportDistanceLimit = CFG.SurfaceSafetySupportDistance
    if legacyEdgeCeilingSupportActive and up:Dot(UP) <= -0.985 then
        supportLength = math.max(supportLength, CFG.LegacyWallEdgeCeilingSupportDistance)
        supportDistanceLimit = math.max(supportDistanceLimit, CFG.LegacyWallEdgeCeilingSupportDistance)
    end

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
                if distance <= supportDistanceLimit and distance < bestDistance then
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
]=] },
    { name = '45_checkSurfaceSafety', source = [=[function checkSurfaceSafety(dt, moveVector)
    if not customActive or not root or isFloorUp(currentUp) then
        resetSafeSurfaceState()
        return false
    end

    dt = math.max(tonumber(dt) or (1 / 60), 1 / 240)

    local now = os.clock()
    local up = safeUnit(currentUp, UP)

    -- v48.25: start with the support result produced by the SAME multi-ray
    -- surface scan that updateSurface() just ran. Do not replace that result
    -- with a generic look-ahead sensor.
    local supportSeen = surfaceSupportSeen
    local supportPoint = surfaceSupportPoint
    local supportNormal = surfaceSupportNormal
    local supportDistance = surfaceSupportDistance

    -- Never trust the boolean alone. An earlier exact-face path could mark
    -- supportSeen=true without returning a point/normal/distance. That is not
    -- confirmed support and must not clear the loss timer or overwrite the last
    -- valid support reference with nil values.
    local supportDistanceValue = tonumber(supportDistance) or math.huge
    if supportSeen and (not supportPoint or not supportNormal or supportDistanceValue >= math.huge
        or up:Dot(safeUnit(supportNormal, up)) < CFG.SurfaceSafetySupportNormalDot)
    then
        wwWallDiag("SAFETY_INVALID_SUPPORT_REJECTED",
            "point=" .. tostring(supportPoint ~= nil)
                .. ", normal=" .. tostring(supportNormal ~= nil)
                .. ", dist=" .. tostring(supportDistance)
                .. ", matchesUp=" .. tostring(supportNormal ~= nil
                    and up:Dot(safeUnit(supportNormal, up)) >= CFG.SurfaceSafetySupportNormalDot),
            0.50
        )
        supportSeen = false
        supportPoint = nil
        supportNormal = nil
        supportDistance = math.huge
    end

    -- Recheck actual nearby geometry before treating a brief primary-sensor
    -- miss as a fall. This uses the existing short support fan; it does not
    -- extend the safety timer and cannot confirm a wall from a distant hit.
    if not supportSeen then
        local fanSeen, fanPoint, fanNormal, fanDistance = getSafetySupport()
        if fanSeen and fanPoint and fanNormal and fanDistance < math.huge then
            supportSeen = true
            supportPoint = fanPoint
            supportNormal = fanNormal
            supportDistance = fanDistance
            wwWallDiag("SAFETY_FAN_SUPPORT_CONFIRMED",
                "dist=" .. string.format("%.2f", fanDistance)
                    .. ", upY=" .. string.format("%.2f", up:Dot(UP)),
                0.40
            )
        end
    end

    -- Resolve the claimed destination separately from generic support. A stale
    -- source face or another same-normal face may keep safety alive, but it cannot
    -- complete the current handoff. Edge-target probes now follow the support axis.
    if transitionClaim then
        supportSeen, supportPoint, supportNormal, supportDistance =
            wwResolveTransitionTargetSupport(up, transitionClaim, supportSeen,
                supportPoint, supportNormal, supportDistance)
    end

    -- v48.66: a confirmed ceiling stair is valid support even when the root
    -- support rays momentarily land on the narrow riser/edge. This is the key
    -- fix for the smaller-tread staircase: geometry can be temporarily absent
    -- from every support ray without meaning that the character detached.
    if not supportSeen and up:Dot(UP) <= CFG.UpsideDownStairSafetyDot and stairTraversalActive and stairTraversalNormal then
        local traversalStartedAt = stairTraversalUntil - CFG.StairTraversalHoldTime
        local traversalAge = now - traversalStartedAt
        local movingIntoStair = false

        if moveVector and moveVector.Magnitude > 0.05 and stairTraversalMoveDir then
            local moveDir = safeUnit(projectOnPlane(moveVector, up), stairTraversalMoveDir)
            movingIntoStair = moveDir:Dot(safeUnit(stairTraversalMoveDir, moveDir)) >= 0.55
        end

        -- A confirmed stair-riser detection is itself proof that the player is
        -- still interacting with the staircase. Small ceiling treads can leave
        -- every support ray on an edge for several frames, so requiring a
        -- cached tread point here was still enough to trip safety in v48.66.
        -- While actively moving into the confirmed stair, keep the surface
        -- ownership alive for the bounded stair-traversal window. After that
        -- window the normal fall safety timer is allowed to take over.
        if traversalAge <= CFG.UpsideDownStairTraversalSafetyHold and movingIntoStair then
            supportSeen = true
            supportPoint = stairTraversalPoint or root.Position
            supportNormal = stairTraversalNormal
            supportDistance = 0
        end
    end

    -- v48.65 UPSIDE-DOWN STAIR SUPPORT BRIDGE:
    -- The ceiling stair can temporarily expose a riser while the next tread is
    -- still physically close. Do not require the center ray to see the tread.
    -- Search a wider tangent fan and keep the last confirmed ceiling support for
    -- a very short grace window when the character is still close to it.
    if up:Dot(UP) <= CFG.UpsideDownStairSafetyDot and stairTraversalActive then
        local tangentA = projectOnPlane(root.CFrame.RightVector, up)
        tangentA = safeUnit(tangentA, Vector3.xAxis)
        local tangentB = safeUnit(tangentA:Cross(up), root.CFrame.LookVector)
        tangentB = safeUnit(projectOnPlane(tangentB, up), Vector3.zAxis)

        local fanRadius = CFG.UpsideDownStairSafetyFanRadius
        local offsets = {
            ZERO,
            tangentA * fanRadius,
            -tangentA * fanRadius,
            tangentB * fanRadius,
            -tangentB * fanRadius,
            tangentA * (fanRadius * 0.55),
            -tangentA * (fanRadius * 0.55),
            tangentB * (fanRadius * 0.55),
            -tangentB * (fanRadius * 0.55),
        }

        local bestFallbackHit
        local bestFallbackNormal
        local bestFallbackDistance = math.huge

        for _, offset in ipairs(offsets) do
            local probeOrigin = root.Position + offset
            local hit = cast(probeOrigin, -up, CFG.UpsideDownStairSafetyProbeLength)

            if hit then
                local normal = orientSurfaceNormal(hit, -up)
                if normal then
                    local supportDot = up:Dot(normal)
                    if supportDot >= CFG.SurfaceSafetySupportNormalDot then
                        local distance = math.abs((probeOrigin - hit.Position):Dot(normal))
                        if distance <= CFG.UpsideDownStairSafetyDistance and distance < bestFallbackDistance then
                            bestFallbackHit = hit
                            bestFallbackNormal = normal
                            bestFallbackDistance = distance
                        end
                    end
                end
            end
        end

        if bestFallbackHit then
            supportSeen = true
            supportPoint = bestFallbackHit.Position
            supportNormal = bestFallbackNormal
            supportDistance = bestFallbackDistance
        end

        -- If every fan ray is on a stair edge, preserve the last real ceiling
        -- support briefly. This is deliberately short and distance-limited, so
        -- an actual fall still reaches the normal safety handoff.
        if not supportSeen and safetySupportPoint and safetySupportNormal then
            local separation = (root.Position - safetySupportPoint):Dot(safetySupportNormal)
            local supportAge = now - safetySupportAt
            if separation <= CFG.SurfaceSafetyAwayDistance + 0.35 and supportAge <= CFG.UpsideDownStairSafetyGrace then
                supportSeen = true
                supportPoint = safetySupportPoint
                supportNormal = safetySupportNormal
                supportDistance = math.max(0, separation)
            end
        end
    end

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
        ceilingApproachHoldStartedAt = 0
        ceilingApproachHoldExpired = false
        ceilingApproachHoldInstance = nil
        ceilingApproachHoldPoint = nil
        ceilingApproachHoldNormal = nil
        if surfaceLostAt > 0 then
            wwWallDiag("SAFETY_SUPPORT_REGAINED",
                "lostFor=" .. string.format("%.2f", now - surfaceLostAt)
                    .. ", upY=" .. string.format("%.2f", up:Dot(UP))
                    .. ", dist=" .. tostring(supportDistance)
                    .. ", posY=" .. string.format("%.2f", root.Position.Y),
                0
            )
        end
        surfaceLostAt = 0
        edgeFloorApproachHoldStartedAt = 0
        safetySupportPoint = supportPoint
        safetySupportNormal = supportNormal
        safetySupportDistance = supportDistance
        safetySupportAt = now
        safetyAwayDistance = 0
        safetyAwaySpeed = 0
        safetyWorldFallSpeed = 0
        safetyWorldFallAcceleration = 0

        -- The transition is complete only when support matches the newly-owned
        -- plane, not merely when any surface remains inside the broad fan.
        if supportNormal
            and up:Dot(safeUnit(supportNormal, up)) >= CFG.SurfaceSafetySupportNormalDot
            and ((transitionClaim and wwIsTransitionTargetSupport(
                up, transitionClaim, supportPoint, supportNormal, supportDistance
            )) or (not transitionClaim
                and (tonumber(supportDistance) or math.huge) <= CFG.SurfaceSafetySupportDistance))
        then
            if transitionClaim then
                wwSafeTransitionAuditCall("support-phase", wwSetTransitionAuditPhaseForClaim,
                    transitionClaim, "confirming", "target-support-currently-valid"
                )
                transitionClaim.leasePhase = "confirming"
                wwSetTransitionRoutePhase(transitionClaim.route, "confirming", now,
                    "target-support-currently-valid", transitionClaim.pipelineState)
                if transitionClaim.supportSince == nil then
                    transitionClaim.supportSince = now
                end
                if now - transitionClaim.supportSince >= CFG.TransitionSupportConfirmTime then
                    gravityTransitionActive = false
                    wwWallDiag("TRANSITION_CLAIM_CONFIRMED",
                        "route=" .. tostring(transitionClaim.route)
                            .. ", dist=" .. string.format("%.2f", supportDistance)
                            .. ", stable=" .. string.format("%.2f", now - transitionClaim.supportSince),
                        0
                    )
                    wwSafeTransitionAuditCall("completion", wwRecordTransitionAuditCompletion,
                        transitionClaim, supportDistance, now - transitionClaim.supportSince
                    )
                    if wwIsManagedTransitionRoute(transitionClaim.route) then
                        wwWallDiag("WW_ROUTE_COMPLETED", "route=" .. transitionClaim.route, 0)
                        wwClearTransitionRouteState(transitionClaim.route, "completed",
                            "stable-target-support", transitionClaim.pipelineState)
                    end
                    transitionClaim.leasePhase = "completed"
                    transitionClaim = nil
                else
                    wwWallDiag("TRANSITION_SUPPORT_STABILIZING",
                        "route=" .. tostring(transitionClaim.route)
                            .. ", stable=" .. string.format("%.2f", now - transitionClaim.supportSince)
                            .. ", required=" .. string.format("%.2f", CFG.TransitionSupportConfirmTime),
                        0.12
                    )
                end
            else
                gravityTransitionActive = false
            end
        elseif transitionClaim then
            transitionClaim.supportSince = nil
            transitionClaim.leasePhase = "committed"
            wwSetTransitionRoutePhase(transitionClaim.route, "committed", now,
                "target-support-not-currently-valid", transitionClaim.pipelineState)
            wwSafeTransitionAuditCall("support-reset", wwSetTransitionAuditPhaseForClaim,
                transitionClaim, "committed", "target-support-not-currently-valid"
            )
        end

        return false
    end

    if transitionClaim then
        transitionClaim.supportSince = nil
        transitionClaim.leasePhase = "committed"
        wwSetTransitionRoutePhase(transitionClaim.route, "committed", now,
            "support-not-seen", transitionClaim.pipelineState)
        wwSafeTransitionAuditCall("support-reset", wwSetTransitionAuditPhaseForClaim,
            transitionClaim, "committed", "support-not-seen"
        )
    end

    -- Edge floor approach hold: retain wall gravity while the cached real floor
    -- hit remains fresh/reachable and input or velocity is directed toward it.
    -- Candidate freshness must cover the bounded hold; a 0.20s cache timeout
    -- would expire alongside the safety timer before slow approaches reach contact.
    -- The fixed contact-gap gate still decides when gravity can actually switch.
    if not jumped and math.abs(up:Dot(UP)) < 0.985
        and edgeFloorApproachHit and edgeFloorApproachHit.Position
        and edgeFloorApproachHit.Instance and edgeFloorApproachHit.Instance.Parent
        and edgeFloorApproachNormal and edgeFloorApproachNormal:Dot(UP) >= 0.985
        and now - (edgeFloorApproachAt or 0) <= CFG.EdgeFloorApproachCandidateLifetime
    then
        local floorPoint = edgeFloorApproachHit.Position
        local floorNormal = safeUnit(edgeFloorApproachNormal, UP)
        local floorPlaneDistance = math.abs((root.Position - floorPoint):Dot(floorNormal))
        local floorSurfaceGap = getBodyPartFloorContactGap(floorPoint, floorNormal)
        local worldMove = ZERO
        if moveVector and moveVector.Magnitude > 0.05 then
            worldMove = getWorldMove(moveVector, up)
        end
        local movingTowardFloor, inputTowardFloor, velocityTowardFloor =
            isMovementTowardSurfacePoint(floorPoint, up, moveVector)
        local verticalMove = worldMove:Dot(UP)
        local verticalVelocity = root.AssemblyLinearVelocity:Dot(UP)

        if floorPlaneDistance <= CFG.EdgeFloorApproachDistance
            and movingTowardFloor
            and floorSurfaceGap > CFG.VerticalSurfaceContactGap
        then
            if edgeFloorApproachHoldStartedAt <= 0 then
                edgeFloorApproachHoldStartedAt = now
            end
            local holdAge = now - edgeFloorApproachHoldStartedAt
            if holdAge <= CFG.EdgeFloorApproachMaxHold then
                surfaceLostAt = 0
                wwWallDiag("EDGE_FLOOR_APPROACH_HOLD",
                    "planeDist=" .. string.format("%.2f", floorPlaneDistance)
                        .. ", surfaceGap=" .. string.format("%.2f", floorSurfaceGap)
                        .. ", switchGap=" .. string.format("%.2f", CFG.VerticalSurfaceContactGap)
                        .. ", moveY=" .. string.format("%.2f", verticalMove)
                        .. ", velY=" .. string.format("%.2f", verticalVelocity)
                        .. ", inputToward=" .. tostring(inputTowardFloor)
                        .. ", velocityToward=" .. tostring(velocityTowardFloor)
                        .. ", holdAge=" .. string.format("%.2f", holdAge),
                    0.20
                )
                return false
            else
                wwWallDiag("EDGE_FLOOR_APPROACH_HOLD_EXPIRED",
                    "holdAge=" .. string.format("%.2f", holdAge)
                        .. ", planeDist=" .. string.format("%.2f", floorPlaneDistance)
                        .. ", surfaceGap=" .. string.format("%.2f", floorSurfaceGap),
                    0
                )
                clearEdgeFloorApproach()
            end
        else
            edgeFloorApproachHoldStartedAt = 0
            if floorSurfaceGap <= CFG.VerticalSurfaceContactGap then
                clearEdgeFloorApproach()
            end
        end
    end

    -- Before the near-contact wall gate accepts a ceiling -> vertical-wall
    -- transition, a valid wall candidate may already be visible while the player
    -- has just left the ceiling edge. Hold only while the candidate remains
    -- fresh/reachable and input or velocity is actually aimed toward it. This is
    -- target-conditioned approach protection, not a longer general safety timer.
    if not jumped and up:Dot(UP) <= -0.985 then
        local pendingWall = forwardTransitionPending
        if edgeTransitionPending and (not pendingWall
            or (edgeTransitionPending.lastSeen or 0) > (pendingWall.lastSeen or 0))
        then
            pendingWall = edgeTransitionPending
        end

        if pendingWall and pendingWall.hit and pendingWall.hit.Instance and pendingWall.hit.Instance.Parent
            and pendingWall.normal and pendingWall.oldUp
            and pendingWall.oldUp:Dot(up) >= 0.90
            and math.abs(pendingWall.normal:Dot(UP)) < CFG.StairRiserGravityVerticalDot
            and now - (pendingWall.lastSeen or 0) <= CFG.EdgeTransitionPendingLifetime
        then
            local toTarget = projectOnPlane(pendingWall.hit.Position - root.Position, up)
            local moveWorld = ZERO
            if moveVector and moveVector.Magnitude > 0.05 then
                moveWorld = getWorldMove(moveVector, up)
            end

            local inputToward = moveWorld.Magnitude > 0.05 and toTarget.Magnitude > 0.05
                and moveWorld.Unit:Dot(toTarget.Unit) >= 0.15
            local tangentVelocity = projectOnPlane(root.AssemblyLinearVelocity, up)
            local velocityToward = tangentVelocity.Magnitude > 0.50 and toTarget.Magnitude > 0.05
                and tangentVelocity.Unit:Dot(toTarget.Unit) >= 0.15
            local intendedSpeed = 0
            if humanoid then
                intendedSpeed = math.max(0, tonumber(humanoid.WalkSpeed) or 0)
                    * math.clamp(moveVector and moveVector.Magnitude or 0, 0, 1)
            end
            local approachSpeed = math.max(tangentVelocity.Magnitude, intendedSpeed)
            local approachReach = CFG.TransitionProbeLength
                + math.clamp(approachSpeed * 0.12, 0, 2.50)
            local candidateDistance = toTarget.Magnitude
            local candidatePointDistance = (pendingWall.hit.Position - root.Position).Magnitude

            if candidateDistance <= approachReach and (inputToward or velocityToward) then
                surfaceLostAt = 0
                wwWallDiag("CEILING_TO_WALL_APPROACH_HOLD",
                    "route=" .. tostring(pendingWall.route)
                        .. ", tangentDist=" .. string.format("%.2f", candidateDistance)
                        .. ", pointDist=" .. string.format("%.2f", candidatePointDistance)
                        .. ", reach=" .. string.format("%.2f", approachReach)
                        .. ", inputToward=" .. tostring(inputToward)
                        .. ", velocityToward=" .. tostring(velocityToward)
                        .. ", moveMag=" .. string.format("%.2f", moveVector and moveVector.Magnitude or 0),
                    0.25
                )
                return false
            end
        end
    end

    -- A route-qualified handoff may temporarily lose its support ray while the
    -- body rotates/settles onto the destination plane. Keep gravity only while
    -- the original confirmed target still exists, the target normal matches
    -- currentUp, its plane remains reachable, and the bounded grace has not
    -- elapsed. This does not extend the ordinary safety timer for arbitrary falls.
    if not jumped and transitionClaim then
        local claim = transitionClaim
        local claimAge = now - (claim.startedAt or now)
        local claimValid = wwIsManagedTransitionRoute(claim.route)
            or claim.route == "edge" or claim.route == "forward"
        if not claim.instance or not claim.instance.Parent or not claim.normal or not claim.point then
            claimValid = false
        end
        if claimValid and claim.normal:Dot(up) < 0.90 then
            claimValid = false
        end
        if claimAge > (claim.grace or CFG.TransitionSupportGrace) then
            claimValid = false
        end

        local claimDistance = math.huge
        if claimValid then
            claimDistance = math.abs((root.Position - claim.point):Dot(claim.normal))
            local claimDistanceLimit = CFG.TransitionHandoffMaxDistance
            if claim.route == "wall-edge-to-ceiling-underside" then
                claimDistanceLimit = CFG.WallEdgeCeilingHandoffMaxDistance
            end
            if claimDistance > claimDistanceLimit then
                claimValid = false
            end
        end

        if claimValid then
            surfaceLostAt = 0
            wwWallDiag("TRANSITION_HANDOFF_HOLD",
                "route=" .. tostring(claim.route)
                    .. ", age=" .. string.format("%.2f", claimAge)
                    .. ", dist=" .. string.format("%.2f", claimDistance),
                0.20
            )
            return false
        end

        wwWallDiag("TRANSITION_CLAIM_EXPIRED",
            "route=" .. tostring(claim.route)
                .. ", age=" .. string.format("%.2f", claimAge)
                .. ", dist=" .. string.format("%.2f", claimDistance),
            0
        )
        wwSafeTransitionAuditCall("expiry", wwRecordTransitionAuditExpiry, transitionClaim, "surface-safety-claim-expired")
        if wwIsManagedTransitionRoute(transitionClaim.route) then
            wwClearTransitionRouteState(transitionClaim.route, "expired",
                "surface-safety-claim-expired", transitionClaim.pipelineState)
        end
        transitionClaim.leasePhase = "expired"
        transitionClaim = nil
        gravityTransitionActive = false
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

    -- A blocked return-to-ceiling candidate must not immediately turn into a
    -- native-gravity fall while the player is still deliberately approaching
    -- that same ceiling. Hold only for a bounded window and only while an actual
    -- ceiling candidate is reachable and movement is directed upward. Body-part
    -- contact is logged separately from the broader character-bounds candidate.
    do
        local wallOriented = not jumped and math.abs(up:Dot(UP)) < 0.985
        local approachMove = ZERO
        local upwardIntent = 0
        local moveMagnitude = moveVector and moveVector.Magnitude or 0
        if wallOriented and moveMagnitude > 0.05 then
            approachMove = getWorldMove(moveVector, up)
            upwardIntent = approachMove:Dot(UP)
        end
        local upwardSpeed = root.AssemblyLinearVelocity:Dot(UP)
        local directedTowardCeiling = upwardIntent > 0.05
            or (moveMagnitude <= 0.05 and upwardSpeed > 0.35)
        local approachHit, approachNormal = nil, nil
        local approachSource = "none"
        local approachDistance = math.huge
        if wallOriented and directedTowardCeiling then
            approachHit, approachNormal = findWallToCeilingSurface(up, approachMove, true)
            if approachHit and approachNormal then
                approachSource = "wall-to-ceiling-scan"
            end
            -- During an owned ceiling-edge handoff, use the legacy edge fan as
            -- a bounded safety fallback. This avoids dropping safety grace just
            -- because the ordinary wall-to-ceiling ray fan misses one frame.
            if not approachHit and (legacyEdgeCeilingSupportActive == true
                or legacyEdgeCeilingHandoffPending == true
                or (transitionClaim and (transitionClaim.route == "ceiling-to-wall"
                    or transitionClaim.route == "ceiling-edge-to-wall-underside"
                    or transitionClaim.route == "wall-edge-to-ceiling-underside"))
                or transitionResolvedRoute == "wall-edge-to-ceiling-underside") then
                approachHit, approachNormal = findLegacyWallEdgeCeilingSurface(up, approachMove)
                if approachHit and approachNormal then
                    approachSource = "legacy-edge-ceiling-scan"
                end
            end
            -- Ray fans can flicker for a frame while the character crosses the
            -- lip. Reuse only the last confirmed ceiling ray hit, for this same
            -- bounded approach window and only while the target remains nearby.
            if not approachHit and ceilingApproachHoldInstance
                and ceilingApproachHoldInstance.Parent and ceilingApproachHoldPoint
                and ceilingApproachHoldNormal and ceilingApproachHoldNormal:Dot(UP) <= -0.90
            then
                approachDistance = (ceilingApproachHoldPoint - root.Position).Magnitude
                if approachDistance <= CFG.WallEdgeCeilingHandoffMaxDistance
                    and (ceilingApproachHoldPoint - root.Position):Dot(UP) >= -0.50
                then
                    approachHit = {
                        Instance = ceilingApproachHoldInstance,
                        Position = ceilingApproachHoldPoint,
                    }
                    approachNormal = ceilingApproachHoldNormal
                    approachSource = "recent-ceiling-hit-cache"
                end
            end
        end
        -- During a jump between ceiling platforms, the live wall-to-ceiling
        -- scan can disappear for a frame even though updateSurface still has a
        -- recent, nearby ceiling destination candidate. Bridge that sensor gap
        -- using only the same managed route, a downward-facing ceiling normal,
        -- a fresh candidate audit, and a strict distance limit. This does not
        -- confirm support or commit gravity; it only preserves bounded safety
        -- grace while the candidate remains reachable.
        if not approachHit and up:Dot(UP) <= -0.90
            and transitionCandidateHit and transitionCandidateHit.Instance
            and transitionCandidateHit.Instance.Parent
            and transitionCandidateHit.Position and transitionCandidateNormal
            and transitionCandidateNormal:Dot(UP) <= -0.90
            and (transitionResolvedRoute == "wall-to-ceiling"
                or transitionCandidateRoute == "wall-to-ceiling") then
            local candidateAuditAge = transitionCandidateAuditLatest
                and (now - (transitionCandidateAuditLatest.lastSeenAt or now)) or math.huge
            local candidateDistance = (transitionCandidateHit.Position - root.Position).Magnitude
            if candidateAuditAge <= CFG.EdgeTransitionPendingLifetime
                and candidateDistance <= CFG.WallEdgeCeilingHandoffMaxDistance then
                approachHit = transitionCandidateHit
                approachNormal = transitionCandidateNormal
                approachSource = "recent-managed-ceiling-candidate"
                approachDistance = candidateDistance
                wwWallDiag("SAFETY_CEILING_CANDIDATE_BRIDGE",
                    "route=wall-to-ceiling"
                        .. ", target=" .. tostring(transitionCandidateHit.Instance.Name)
                        .. ", candidateAge=" .. string.format("%.2f", candidateAuditAge)
                        .. ", dist=" .. string.format("%.2f", candidateDistance)
                        .. ", normalY=" .. string.format("%.2f", transitionCandidateNormal:Dot(UP))
                        .. ", reason=recent-nearby-target-bridges-scan-miss", 0.20)
            end
        end

        if approachHit and approachNormal and approachNormal:Dot(UP) <= -0.90 then
            approachDistance = (approachHit.Position - root.Position).Magnitude
            local approachBodyGap = getBodyPartSurfaceGap(approachHit.Position)
            if approachDistance <= CFG.WallEdgeCeilingHandoffMaxDistance then
                if ceilingApproachHoldStartedAt <= 0 then
                    ceilingApproachHoldStartedAt = now
                    ceilingApproachHoldExpired = false
                end
                ceilingApproachHoldInstance = approachHit.Instance
                ceilingApproachHoldPoint = approachHit.Position
                ceilingApproachHoldNormal = safeUnit(approachNormal, -UP)
                local holdAge = now - ceilingApproachHoldStartedAt
                local holdLimit = math.max(CFG.EdgeTransitionPendingLifetime, 0.65)
                if holdAge <= holdLimit then
                    surfaceLostAt = 0
                    wwWallDiag("SAFETY_CEILING_APPROACH_HOLD",
                        "orientation=" .. wwDescribeSurfaceOrientation(up)
                            .. ", targetSource=" .. approachSource
                            .. ", target=" .. tostring(approachHit.Instance.Name)
                            .. ", supportSensor=miss"
                            .. ", dist=" .. string.format("%.2f", approachDistance)
                            .. ", boundsGap=" .. string.format("%.2f", getCharacterSurfaceGap(approachHit.Position))
                            .. ", bodyGap=" .. string.format("%.2f", approachBodyGap)
                            .. ", inputUp=" .. string.format("%.2f", upwardIntent)
                            .. ", worldYVel=" .. string.format("%.2f", upwardSpeed)
                            .. ", holdAge=" .. string.format("%.2f", holdAge)
                            .. ", holdLimit=" .. string.format("%.2f", holdLimit)
                            .. ", reason=bounded-directed-ceiling-approach", 0.25)
                    return false
                elseif not ceilingApproachHoldExpired then
                    ceilingApproachHoldExpired = true
                    wwWallDiag("SAFETY_CEILING_APPROACH_HOLD_EXPIRED",
                        "orientation=" .. wwDescribeSurfaceOrientation(up)
                            .. ", targetSource=" .. approachSource
                            .. ", target=" .. tostring(approachHit.Instance.Name)
                            .. ", dist=" .. string.format("%.2f", approachDistance)
                            .. ", bodyGap=" .. string.format("%.2f", approachBodyGap)
                            .. ", holdAge=" .. string.format("%.2f", holdAge)
                            .. ", outcome=normal-safety-timer-resumes", 0)
                end
            else
                ceilingApproachHoldStartedAt = 0
                ceilingApproachHoldExpired = false
                ceilingApproachHoldInstance = nil
                ceilingApproachHoldPoint = nil
                ceilingApproachHoldNormal = nil
            end
        else
            ceilingApproachHoldStartedAt = 0
            ceilingApproachHoldExpired = false
            ceilingApproachHoldInstance = nil
            ceilingApproachHoldPoint = nil
            ceilingApproachHoldNormal = nil
        end
    end

    if surfaceLostAt <= 0 then
        surfaceLostAt = now
        wwWallDiag("SAFETY_LOST_START",
            "upY=" .. string.format("%.2f", up:Dot(UP))
                .. ", moveMag=" .. string.format("%.2f", moveVector and moveVector.Magnitude or 0)
                .. ", stair=" .. tostring(stairTraversalActive)
                .. ", posY=" .. string.format("%.2f", root.Position.Y),
            0
        )
        return false
    end

    local safetyDelay = CFG.SurfaceSafetyDelay

    if up:Dot(UP) <= CFG.UpsideDownStairSafetyDot and stairTraversalActive then
        -- Ceiling stairs need a longer continuous-loss window because a narrow
        -- tread can disappear from the probes while the root is physically
        -- crossing the riser. This is still a hard timeout, not permanent grace.
        safetyDelay = math.max(safetyDelay, CFG.UpsideDownStairTraversalSafetyHold)
    end

    if now - surfaceLostAt < safetyDelay then
        return false
    end

    -- Continuous loss for the full delay: release custom gravity and let
    -- Roblox take over. No teleport and no saved-position recovery.
    local releaseSupportDot = -1
    if supportNormal then
        releaseSupportDot = safeUnit(supportNormal, up):Dot(up)
    end
    wwWallDiag("SAFETY_RELEASE",
        "lostFor=" .. string.format("%.2f", now - surfaceLostAt)
            .. ", orientation=" .. wwDescribeSurfaceOrientation(up)
            .. ", upY=" .. string.format("%.2f", up:Dot(UP))
            .. ", supportSensor=" .. tostring(supportSeen == true)
            .. ", supportDot=" .. string.format("%.2f", releaseSupportDot)
            .. ", supportDist=" .. tostring(supportDistance)
            .. ", claimRoute=" .. tostring(transitionClaim and transitionClaim.route or "none")
            .. ", candidateRoute=" .. tostring(transitionResolvedRoute or transitionCandidateRoute or "none")
            .. ", lastAuditRoute=" .. tostring(transitionCandidateAuditLatest and transitionCandidateAuditLatest.route or "none")
            .. ", lastAuditPhase=" .. tostring(transitionCandidateAuditLatest and transitionCandidateAuditLatest.phase or "none")
            .. ", lastAuditAge=" .. string.format("%.2f", transitionCandidateAuditLatest and (now - (transitionCandidateAuditLatest.lastSeenAt or now)) or math.huge)
            .. ", moveMag=" .. string.format("%.2f", moveVector and moveVector.Magnitude or 0)
            .. ", worldYVelocity=" .. string.format("%.2f", root.AssemblyLinearVelocity:Dot(UP))
            .. ", stair=" .. tostring(stairTraversalActive)
            .. ", posY=" .. string.format("%.2f", root.Position.Y),
        0
    )
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
]=] },
    { name = '46_updateGravityAndMovement', source = [=[function updateGravityAndMovement(dt, worldMove, microStepActive)
    if not root or not gravityForce or not customActive then return end

    local mass = root.AssemblyMass
    if mass <= 0 then return end

    -- Keep native Workspace.Gravity at zero while custom physics is active.
    -- If another local script/game update changes it, capture the new value and
    -- suppress it again before calculating this frame's custom gravity.
    suppressNativeWorkspaceGravity()

    local gravity = wallWalkGravity
    local velocity = root.AssemblyLinearVelocity
    local normalVelocity = velocity:Dot(currentUp)
    local tangentVelocity = velocity - normalVelocity * currentUp
    local movementSpeed = CFG.WalkSpeed
    if humanoid then
        local liveWalkSpeed = tonumber(humanoid.WalkSpeed)
        if liveWalkSpeed and liveWalkSpeed >= 0 then
            movementSpeed = liveWalkSpeed
        end
    end
    local desired = movementSpeed * worldMove
    local delta = desired - tangentVelocity

    -- The ceiling staircase has a short active ramp window. Native gravity is
    -- already zero here, so the scale below is the REAL custom gravity fraction
    -- instead of a compensation value fighting Roblox's world gravity.
    -- Keep these as simple Luau statements. Some mobile/executor parsers are
    -- stricter about multiline boolean/and-or expressions than the Luau parser.
    local ceilingStepActive = false
    if currentUp:Dot(UP) <= CFG.UpsideDownStairSafetyDot then
        if stairStepBlend > 0.01 then
            if stairStepTargetBlend > 0.01 then
                ceilingStepActive = true
            end
        end
    end

    local gravityScale = 1
    if ceilingStepActive then
        gravityScale = CFG.StairCeilingStepGravityScale
    end

    local walkForce = CFG.WalkForce
    if ceilingStepActive then
        walkForce = CFG.WalkForce * CFG.StairCeilingStepForceMultiplier
    end

    -- Exact surface-relative copy of Roblox gravity. Because native gravity is
    -- suppressed locally, there is no UP-currentUp compensation term needed.
    -- currentUp points away from the support surface, so -currentUp is gravity
    -- toward that surface on floor, wall and ceiling alike.
    local force = -currentUp * (gravity * mass * gravityScale)

    -- The v48.74 ceiling-step lift direction was correct; v48.75 retained the
    -- ramp geometry but the actuation block tested/pushed +currentUp, which is
    -- the wrong side for an upside-down stair. Reuse the proven lift direction
    -- here so the root can clear the riser independently of foot-animation height.
    if ceilingStepActive and stairStepMove.Magnitude > 0.05 then
        local stepDirection = safeUnit(stairStepMove, worldMove)
        local liftDirection = -currentUp
        local stepNormalComponent = math.max(0, stepDirection:Dot(liftDirection))

        if stepNormalComponent > 0.01 then
            local smoothBlend = math.max(stairStepBlend, 0.35)
            local liftAcceleration = CFG.StairCeilingStepLiftAcceleration * stepNormalComponent * smoothBlend
            local liftForce = liftDirection * (liftAcceleration * mass)
            force = force + liftForce
        end
    end

    if delta.Magnitude > 0.001 then
        -- Apply acceleration-like steering instead of an oversized per-frame
        -- force. This makes starts/stops feel much closer to Roblox movement.
        local acceleration = math.min(CFG.MaxWalkForce / math.max(mass, 1),
            walkForce * delta.Magnitude)
        force = force + delta.Unit * acceleration * mass
    end

    local adhesionProbeLength = CFG.AdhesionProbeLength
    if ceilingContactSupportReachActive and currentUp:Dot(UP) <= -0.985 then
        adhesionProbeLength = math.max(adhesionProbeLength, CFG.LegacyWallEdgeCeilingSupportDistance)
        wwWallDiag("CEILING_CONTACT_ADHESION_REACH_ARMED",
            "extendedProbe=true, probeReach=" .. string.format("%.2f", adhesionProbeLength), 1.00)
    end
    if legacyEdgeCeilingSupportActive and currentUp:Dot(UP) <= -0.985 then
        adhesionProbeLength = math.max(adhesionProbeLength, CFG.LegacyWallEdgeCeilingSupportDistance)
    end
    local hit = cast(root.Position, -currentUp, adhesionProbeLength)
    local surfaceNormal = hit and orientSurfaceNormal(hit, -currentUp)
    if ceilingContactSupportReachActive and currentUp:Dot(UP) <= -0.985
        and hit and surfaceNormal and currentUp:Dot(surfaceNormal) > 0.92
        and math.abs((root.Position - hit.Position):Dot(surfaceNormal)) <= CFG.AdhesionProbeLength - 0.12
    then
        ceilingContactSupportReachActive = false
        wwWallDiag("CEILING_CONTACT_ADHESION_REACH_CLEARED", "extendedProbe=false, reason=root-contact", 1.00)
    end
    if legacyEdgeCeilingSupportActive and currentUp:Dot(UP) <= -0.985 then
        if hit and surfaceNormal and currentUp:Dot(surfaceNormal) > 0.92 then
            if math.abs((root.Position - hit.Position):Dot(surfaceNormal)) <= CFG.AdhesionProbeLength - 0.12 then
                legacyEdgeCeilingSupportActive = false
                legacyEdgeCeilingSourceWallHoldActive = false
                legacyEdgeCeilingSourceUp = nil
                legacyEdgeCeilingHandoffPosition = nil
                legacyEdgeCeilingStartedAt = 0
                wwWallDiag("WW_LEGACY_EDGE_CEILING_SUPPORT_MODE", "enabled=false, reason=normal-root-contact", 0)
            end
        end
    end
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
                filteredAdhesionDistance = filteredAdhesionDistance + distanceDelta * alpha
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
            force = force + -currentUp * correction * mass
        end
    else
        filteredAdhesionDistance = nil
    end

    gravityForce.Force = force
end
]=] },
    { name = '47_updateOrientation', source = [=[function updateOrientation(worldMove)
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

cameraOffsetY =  0
]=] },
    { name = '48_getRotationBetweenUpVectors', source = [=[function getRotationBetweenUpVectors(fromUp, toUp, axisHint)
    local from = safeUnit(fromUp, UP)
    local to = safeUnit(toUp, UP)
    local dot = math.clamp(from:Dot(to), -1, 1)
    if dot > 0.999999 then
        return CFrame.identity
    end

    local axis = from:Cross(to)
    if axis.Magnitude < 1e-5 then
        -- A 180-degree turn has no unique cross-product axis. Use the camera's
        -- right axis, projected off the current up vector, for a stable result.
        axis = projectOnPlane(axisHint or Vector3.xAxis, from)
        if axis.Magnitude < 1e-5 then
            axis = projectOnPlane(Vector3.zAxis, from)
        end
    end
    axis = safeUnit(axis, Vector3.xAxis)
    return CFrame.fromAxisAngle(axis, math.acos(dot))
end
]=] },
    { name = '49_applyCameraModuleUpTransform', source = [=[function getCameraTargetUp()
    if cameraPOVEnabled and not destroyed and enabled and customActive then
        return safeUnit(currentUp, UP)
    end
    return UP
end

-- CameraModule's classic controller calculates yaw/pitch in Roblox's ordinary
-- world-up frame. Before it processes touch input, temporarily remove the
-- gravity camera frame from the previous rendered CFrame. CameraModule then
-- sees the same coordinate space it expects on a normal floor.
function prepareCameraModuleUpTransform()
    local camera = workspace.CurrentCamera
    if not camera then return end
    if camera.CameraType ~= Enum.CameraType.Custom then return end
    if not cameraUpFrame then cameraUpFrame = CFrame.identity end

    local focus = camera.Focus
    local relativePose = focus:ToObjectSpace(camera.CFrame)
    local neutralPose = cameraUpFrame:Inverse() * relativePose
    camera.CFrame = focus * neutralPose
end

-- Apply gravity orientation AFTER Roblox has processed its normal camera input.
-- The input controller and its own cached state remain in the standard frame;
-- only the final rendered orbit is gravity-rotated.
function applyCameraModuleUpTransform(cameraModule, dt)
    local camera = workspace.CurrentCamera
    if not camera then return end
    if camera.CameraType ~= Enum.CameraType.Custom then return end
    if not cameraUpFrame then cameraUpFrame = CFrame.identity end

    local gravityPOVActive = cameraPOVEnabled and not destroyed and enabled and customActive
    local targetUp = getCameraTargetUp()
    dt = math.clamp(tonumber(dt) or (1 / 60), 0, 0.1)

    if gravityPOVActive then
        local fullTurn = getRotationBetweenUpVectors(
            cameraUpVector,
            targetUp,
            camera.CFrame.RightVector
        )
        local _, fullAngle = fullTurn:ToAxisAngle()
        local stepRotation = fullTurn

        if math.abs(fullAngle) > math.rad(0.06) then
            local alpha = 1 - math.exp(-CFG.CameraUpResponsiveness * dt)
            stepRotation = CFrame.identity:Lerp(fullTurn, alpha)
        end

        local nextUp = safeUnit(stepRotation:VectorToWorldSpace(cameraUpVector), targetUp)
        local remainingTurn = getRotationBetweenUpVectors(
            nextUp,
            targetUp,
            camera.CFrame.RightVector
        )
        local _, remainingAngle = remainingTurn:ToAxisAngle()
        if math.abs(remainingAngle) < math.rad(0.2) then
            stepRotation = remainingTurn * stepRotation
            nextUp = targetUp
        end

        -- Accumulate turns along the actual surface path. This preserves a
        -- continuous gravity frame across wall and ceiling transitions.
        cameraUpFrame = stepRotation * cameraUpFrame
        cameraUpVector = safeUnit(cameraUpFrame:VectorToWorldSpace(UP), nextUp)
    else
        -- POV off, normal floor, disabled, or destroyed: smoothly return the
        -- COMPLETE frame to identity, not just its up axis. Otherwise a hidden
        -- residual twist can keep changing the camera's heading after returning
        -- to ordinary gravity.
        local _, frameAngle = cameraUpFrame:ToAxisAngle()
        if math.abs(frameAngle) > math.rad(0.06) then
            local alpha = 1 - math.exp(-CFG.CameraUpResponsiveness * dt)
            cameraUpFrame = cameraUpFrame:Lerp(CFrame.identity, alpha)
        else
            cameraUpFrame = CFrame.identity
        end
        cameraUpVector = safeUnit(cameraUpFrame:VectorToWorldSpace(UP), UP)
    end

    local focus = camera.Focus
    local relativePose = focus:ToObjectSpace(camera.CFrame)
    local adjustedCFrame = focus * (cameraUpFrame * relativePose)

    -- CameraModule's occlusion pass ran in the standard frame. Check the
    -- gravity-rotated orbit too, and move it inward if the new path hits geometry.
    if cameraCollisionCharacter ~= character then
        cameraCollisionCharacter = character
        cameraCollisionParams.FilterDescendantsInstances = character and {character} or {}
    end
    local cameraRay = adjustedCFrame.Position - focus.Position
    if cameraRay.Magnitude > 0.05 then
        cameraCollisionParams.FilterDescendantsInstances = character and {character} or {}
        local ignoredForCamera = {}
        local hit = nil
        local rayStart = focus.Position
        local rayDirection = cameraRay
        local tries = 0

        -- The normal Roblox camera ignores character bodies and often passes
        -- through non-collidable/glass parts. Mirror that behavior for this
        -- extra gravity-oriented collision check instead of pulling the camera
        -- in whenever it touches a player or a window.
        while tries < 16 do
            hit = workspace:Raycast(rayStart, rayDirection, cameraCollisionParams)
            if not hit then
                break
            end

            local hitInstance = hit.Instance
            local skipHit = false
            if hitInstance and hitInstance:IsA("BasePart") then
                if not hitInstance.CanCollide
                    or hitInstance.Transparency >= 0.35
                    or hitInstance.Material == Enum.Material.Glass then
                    skipHit = true
                end
            end

            local hitModel = hitInstance and hitInstance:FindFirstAncestorOfClass("Model")
            if hitModel and hitModel ~= character
                and hitModel:FindFirstChildOfClass("Humanoid") then
                skipHit = true
            end

            if not skipHit then
                break
            end

            ignoredForCamera[#ignoredForCamera + 1] = hitInstance
            local filterList = {}
            if character then
                filterList[#filterList + 1] = character
            end
            for ignoreIndex = 1, #ignoredForCamera do
                filterList[#filterList + 1] = ignoredForCamera[ignoreIndex]
            end
            cameraCollisionParams.FilterDescendantsInstances = filterList
            tries = tries + 1
        end

        if hit then
            local safeDistance = math.max(0.05, (hit.Position - focus.Position).Magnitude - 0.25)
            if safeDistance < cameraRay.Magnitude then
                local safePosition = focus.Position + cameraRay.Unit * safeDistance
                adjustedCFrame = adjustedCFrame + (safePosition - adjustedCFrame.Position)
            end
        end
    end

    camera.CFrame = adjustedCFrame

    local _, finalFrameAngle = cameraUpFrame:ToAxisAngle()
    if (destroyed or not enabled) and not customActive
        and cameraUpVector:Dot(UP) > 0.99999
        and math.abs(finalFrameAngle) < math.rad(0.25)
    then
        cameraUpVector = UP
        cameraUpFrame = CFrame.identity
        if restoreCameraModuleHook then
            restoreCameraModuleHook()
        end
    end
end]=] },
    { name = '50_getPlayerCameraModule', source = [=[function getPlayerCameraModule()
    local scripts = player:FindFirstChildOfClass("PlayerScripts")
    local playerModuleScript = scripts and scripts:FindFirstChild("PlayerModule")
    if not playerModuleScript then return nil end

    local ok, playerModule = pcall(require, playerModuleScript)
    if not ok or not playerModule then return nil end

    if type(playerModule.GetCameras) == "function" then
        local camerasOK, cameras = pcall(function()
            return playerModule:GetCameras()
        end)
        if camerasOK and cameras then
            return cameras
        end
    end

    return playerModule.cameras
end

-- Older v48.76.4/v48.76.5 builds replaced CameraModule.Update directly.
-- If one of those wrappers survived a script re-execution, recover its captured
-- original method when the executor exposes debug.getupvalue. This avoids two
-- independent gravity transforms being applied to the same camera.
function removeLegacyCameraModuleWrapper()
    local cameras = getPlayerCameraModule()
    if not cameras then return end
    local currentUpdate = cameras.Update
    if type(currentUpdate) ~= "function" then return end

    local debugLibrary = debug
    if type(debugLibrary) ~= "table" then return end
    local getUpvalue = debugLibrary.getupvalue
    if type(getUpvalue) ~= "function" then return end

    local originalUpdate = nil
    local foundWallWalkTransform = false
    for index = 1, 40 do
        local ok, upvalueName, upvalueValue = pcall(getUpvalue, currentUpdate, index)
        if not ok or upvalueName == nil then break end
        if upvalueName == "cameraModuleOriginalUpdate" and type(upvalueValue) == "function" then
            originalUpdate = upvalueValue
        end
        if upvalueName == "applyCameraModuleUpTransform" then
            foundWallWalkTransform = true
        end
    end

    if originalUpdate and foundWallWalkTransform then
        pcall(function()
            if cameras.Update == currentUpdate then
                cameras.Update = originalUpdate
            end
        end)
    end
end

restoreCameraModuleHook = function()
    pcall(function()
        RunService:UnbindFromRenderStep("VGDWallWalkPOV_PreCamera_48_76_16")
        RunService:UnbindFromRenderStep("VGDWallWalkPOV_PostCamera_48_76_16")
    end)

    cameraModuleHookInstalled = false
    cameraModuleObject = nil
    cameraModuleOriginalUpdate = nil
    cameraModuleOriginalOwnUpdate = nil
    wrappedCameraModuleUpdate = nil
    cameraUpVector = UP
    cameraUpFrame = CFrame.identity
end]=] },
    { name = '51_installCameraModuleHook', source = [=[function installCameraModuleHook()
    if cameraModuleHookInstalled then
        return true
    end

    -- Remove this script's previous render-step hooks from older versions.
    -- This prevents an old post-camera transform from fighting this one when
    -- the user executes the updated standalone without rejoining the game.
    removeLegacyCameraModuleWrapper()

    pcall(function()
        RunService:UnbindFromRenderStep("VGDWallWalkPOV_Camera_48_76_9")
        RunService:UnbindFromRenderStep("VGDWallWalkPOV_Camera_48_76_10")
        RunService:UnbindFromRenderStep("VGDWallWalkPOV_Camera_48_76_8")
        RunService:UnbindFromRenderStep("VGDWallWalkPOV_PreCamera_48_76_11")
        RunService:UnbindFromRenderStep("VGDWallWalkPOV_PostCamera_48_76_11")
        RunService:UnbindFromRenderStep("VGDWallWalkPOV_PreCamera_48_76_16")
        RunService:UnbindFromRenderStep("VGDWallWalkPOV_PostCamera_48_76_16")
    end)

    local preOK, preError = pcall(function()
        RunService:BindToRenderStep(
            "VGDWallWalkPOV_PreCamera_48_76_16",
            Enum.RenderPriority.Camera.Value - 1,
            function()
                prepareCameraModuleUpTransform()
            end
        )
    end)
    if not preOK then
        warn("VGD WallWalk POV: failed to bind pre-camera update: " .. tostring(preError))
        return false
    end

    local postOK, postError = pcall(function()
        RunService:BindToRenderStep(
            "VGDWallWalkPOV_PostCamera_48_76_16",
            Enum.RenderPriority.Camera.Value + 1,
            function(dt)
                applyCameraModuleUpTransform(nil, dt)
            end
        )
    end)
    if not postOK then
        pcall(function()
            RunService:UnbindFromRenderStep("VGDWallWalkPOV_PreCamera_48_76_16")
        end)
        warn("VGD WallWalk POV: failed to bind post-camera update: " .. tostring(postError))
        return false
    end

    cameraModuleHookInstalled = true
    return true
end]=] },
    { name = '52_updateCameraStabilization', source = [=[function updateCameraStabilization(dt)
    if destroyed then return end
    local camera = workspace.CurrentCamera
    if not camera or not humanoid or not root then return end

    -- Never replace Roblox's camera controller. We only remove tiny vertical
    -- physics chatter while WallWalk is active on the normal floor.
    if not enabled or not customActive or currentUp:Dot(Vector3.yAxis) < 0.985 then
        cameraOffsetY = 0
        return
    end

    local normalSpeed = root.AssemblyLinearVelocity:Dot(currentUp)
    local targetOffset = math.clamp(normalSpeed * 0.018, -0.22, 0.22)
    local alpha = 1 - math.exp(-12 * dt)
    cameraOffsetY = cameraOffsetY + (targetOffset - cameraOffsetY) * alpha

    -- CameraOffset is applied by Roblox's normal camera scripts, so this
    -- keeps mouse/joystick orbit, zoom, occlusion and camera collision intact.
    humanoid.CameraOffset = Vector3.new(0, -cameraOffsetY, 0)
end
]=] },
    { name = '53_resetCameraStabilization', source = [=[function resetCameraStabilization()
    cameraOffsetY = 0
    if humanoid then
        humanoid.CameraOffset = Vector3.zero
    end
end
]=] },
    { name = '54_setEmoteStateBridge', source = [=[function setEmoteStateBridge(active)
    -- Emotes are handled through Animate.PlayEmote below.
    -- Never leave WallWalk Physics just because the emote wheel is open.
    emoteStateBridge = false
end
]=] },
    { name = '55_updateEmoteStateBridge', source = [=[function updateEmoteStateBridge()
    -- Intentionally a no-op. WallWalk must remain in custom Physics while
    -- the Roblox emote menu is open; switching to Running makes the normal
    -- world controller fight the custom wall/ceiling gravity.
    emoteMenuOpen = false
    emoteStateRestoreAt = 0
    emoteStateBridge = false
end
]=] },
    { name = '56_enforceRagdollProtection', source = [=[function enforceRagdollProtection()
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
]=] },
    { name = '57_getJumpSurfaceSupport', source = [=[function getJumpSurfaceSupport(up)
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
]=] },
    { name = '58_requestJump', source = [=[function requestJump()
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
]=] },
    { name = '59_performJump', source = [=[function performJump()
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
]=] },
    { name = '60_captureOriginalCharacterState', source = [=[function captureOriginalCharacterState()
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
]=] },
    { name = '61_restoreOriginalCharacterState', source = [=[function restoreOriginalCharacterState()
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
]=] },
    { name = '62_restoreNormal', source = [=[function restoreNormal()
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
]=] },
    { name = '63_activateWallWalk', source = [=[function activateWallWalk()
    if not character or not humanoid or not root then return end

    enabled = true
    safetyReleased = false
    setJumpButtonVisible(UserInputService.TouchEnabled)
    controls = controls or getPlayerControls()
    installCameraModuleHook()
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
]=] },
    { name = '64_setupCharacter', source = [=[function setupCharacter(newCharacter)
    -- A respawn can replace the old character while WallWalk is still on a
    -- wall/ceiling. Restore the client's native gravity before adopting the new
    -- character so a stale zero-gravity state cannot leak across respawns.
    restoreNativeWorkspaceGravity()
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
]=] },
    { name = '65_update', source = [=[function update(dt)
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

    do
        local stateUp = safeUnit(currentUp, UP)
        local supportDot = -1
        local supportBodyGap = math.huge
        if surfaceSupportNormal then
            supportDot = safeUnit(surfaceSupportNormal, stateUp):Dot(stateUp)
        end
        if surfaceSupportPoint then
            supportBodyGap = getBodyPartSurfaceGap(surfaceSupportPoint)
        end
        local claimRoute = transitionClaim and transitionClaim.route or "none"
        local routeName = transitionResolvedRoute or transitionCandidateRoute or "none"
        local bodyUpDot = root.CFrame.UpVector:Dot(stateUp)
        local safetyLostFor = surfaceLostAt > 0 and (os.clock() - surfaceLostAt) or 0
        local lastAudit = transitionCandidateAuditLatest
        local lastAuditRoute = lastAudit and lastAudit.route or "none"
        local lastAuditPhase = lastAudit and lastAudit.phase or "none"
        local lastAuditAge = lastAudit and (os.clock() - (lastAudit.lastSeenAt or os.clock())) or math.huge
        wwWallDiag("WW_SURFACE_STATE",
            "orientation=" .. wwDescribeSurfaceOrientation(stateUp)
                .. ", gravityOwner=" .. tostring(customActive and "WallWalk" or "Roblox")
                .. ", supportSensor=" .. tostring(surfaceSupportSeen == true)
                .. ", supportMatchesGravity=" .. tostring(surfaceSupportSeen == true and supportDot >= CFG.SurfaceSafetySupportNormalDot)
                .. ", supportDot=" .. string.format("%.2f", supportDot)
                .. ", supportDist=" .. tostring(surfaceSupportDistance)
                .. ", supportBodyGap=" .. string.format("%.2f", supportBodyGap)
                .. ", bodyUpDot=" .. string.format("%.2f", bodyUpDot)
                .. ", claimRoute=" .. tostring(claimRoute)
                .. ", candidateRoute=" .. tostring(routeName)
                .. ", lastAuditRoute=" .. tostring(lastAuditRoute)
                .. ", lastAuditPhase=" .. tostring(lastAuditPhase)
                .. ", lastAuditAge=" .. string.format("%.2f", lastAuditAge)
                .. ", safetyLostFor=" .. string.format("%.2f", safetyLostFor)
                .. ", worldYVelocity=" .. string.format("%.2f", root.AssemblyLinearVelocity:Dot(UP)),
            0.50)
    end

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

    -- v48.75: CEILING STAIR MOVEMENT USES THE PROVEN v48.65 RAMP METHOD.
    -- The stair geometry is surface-relative: on a ceiling, the ramp's lift
    -- component points toward -currentUp (toward the underside). The resulting
    -- direction is fed through the SAME custom movement-force path used by v48.65.
    -- No separate position constraint, no animation-driven step, and no separate root teleporter.
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
        if landedNow and normalVelocity <= 1.5 and os.clock() - jumpStartedAt > 0.08 then
            jumped = false
            jumpLaunchUp = UP
            jumpLaunchPosition = nil
            jumpLaunchPlaneCrossed = false
            jumpLocked = false
            justLanded = true
            if normalVelocity < 0 then
                root.AssemblyLinearVelocity =
                    root.AssemblyLinearVelocity - currentUp * normalVelocity
            end
        end
    end

    if isFloorUp(currentUp) then
        -- Native Roblox floor movement owns the character here. The custom
        -- controller only takes over after a real wall/ceiling transition.
        setControllerMode(false)
    else
        setControllerMode(true)
        updateGravityAndMovement(dt, movementMove, microStepActive)
        updateOrientation(movementMove)
    end

    local tangentSpeed = projectOnPlane(root.AssemblyLinearVelocity, currentUp).Magnitude
    local grounded = getGrounded(currentUp)
    if customActive then
        updateAnimations(worldMove.Magnitude > 0.05, grounded, tangentSpeed, dt)
    end
end
]=] },
    { name = '66_disconnectGuiConnections', source = [=[function disconnectGuiConnections()
    for _, c in ipairs(guiConnections) do
        if c then c:Disconnect() end
    end
    table.clear(guiConnections)
end

setJumpButtonVisible = function(visible)
    if jumpButton and jumpButton.Parent then
        jumpButton.Visible = visible
    end
end
]=] },
    { name = '67_updateJumpButtonLayout', source = [=[function updateJumpButtonLayout()
    if not jumpButton or not jumpButton.Parent then return end
    local camera = workspace.CurrentCamera
    local viewport = camera and camera.ViewportSize or Vector2.new(800, 600)
    local small = math.min(viewport.X, viewport.Y) <= 500
    local size = small and 70 or 120
    jumpButton.Size = UDim2.fromOffset(size, size)
    jumpButton.Position = small
        and UDim2.new(1, -(size * 1.5 - 10), 1, -size - 20)
        or UDim2.new(1, -(size * 1.5 - 10), 1, -size * 1.75)
end

updateUI = nil
]=] },
    { name = '68_createUI', source = [=[function destroyWallWalk()
    if destroyed then return end
    destroyed = true
    enabled = false
    restoreNormal()
    resetCameraStabilization()
    restoreOriginalCharacterState()

    for _, c in ipairs(guiConnections) do
        if c then c:Disconnect() end
    end
    table.clear(guiConnections)
    for _, c in ipairs(lifecycleConnections) do
        if c then c:Disconnect() end
    end
    table.clear(lifecycleConnections)
    if transitionGuardConnection then transitionGuardConnection:Disconnect(); transitionGuardConnection = nil end
    if heartbeatConnection then heartbeatConnection:Disconnect(); heartbeatConnection = nil end
    if emoteHandlerGuardConnection then emoteHandlerGuardConnection:Disconnect(); emoteHandlerGuardConnection = nil end
    if emoteTrackConnection then emoteTrackConnection:Disconnect(); emoteTrackConnection = nil end
    if cameraConnection then cameraConnection:Disconnect(); cameraConnection = nil end
    if gravityForce then gravityForce:Destroy(); gravityForce = nil end
    if gravityAttachment then gravityAttachment:Destroy(); gravityAttachment = nil end
    if orientation then orientation:Destroy(); orientation = nil end
    if orientationAttachment then orientationAttachment:Destroy(); orientationAttachment = nil end
    if gui then gui:Destroy(); gui = nil end
end

function createUI()
    if gui then gui:Destroy() end
    disconnectGuiConnections()

    gui = Instance.new("ScreenGui")
    gui.Name = "VGD_WallWalk_Standalone"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Global
    gui.DisplayOrder = 1000000
    gui.Parent = playerGui

    local panel = Instance.new("Frame")
    panel.Size = UDim2.fromOffset(CFG.PanelWidth, CFG.PanelHeight)
    panel.Position = UDim2.new(1, -(CFG.PanelWidth + 3), 0.5, -(CFG.PanelHeight / 2))
    panel.BackgroundColor3 = Color3.fromRGB(14, 16, 22)
    panel.BackgroundTransparency = 0.08
    panel.BorderSizePixel = 0
    panel.Parent = gui

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 10)
    corner.Parent = panel

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(0, 170, 255)
    stroke.Thickness = 1.5
    stroke.Transparency = 0.15
    stroke.Parent = panel

    local title = Instance.new("TextLabel")
    title.BackgroundTransparency = 1
    title.Position = UDim2.fromOffset(11, 6)
    title.Size = UDim2.new(1, -40, 0, 17)
    title.Font = Enum.Font.GothamBold
    title.TextSize = 11
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.TextColor3 = Color3.new(1, 1, 1)
    title.Text = "WallWalk v48.76.113"
    title.TextTruncate = Enum.TextTruncate.AtEnd
    title.Parent = panel

    local headerLine = Instance.new("Frame")
    headerLine.Name = "HeaderDivider"
    headerLine.Position = UDim2.fromOffset(11, 26)
    headerLine.Size = UDim2.new(1, -22, 0, 1)
    headerLine.BackgroundColor3 = Color3.fromRGB(64, 82, 102)
    headerLine.BackgroundTransparency = 0.35
    headerLine.BorderSizePixel = 0
    headerLine.Parent = panel

    -- Compact two-column control area:
    -- left = gravity indicator, right = ON/OFF + POV.
    -- Keep generous padding so the two-line indicator is vertically centered
    -- rather than sitting against the bottom-left corner.
    local gravityLabel = Instance.new("TextLabel")
    gravityLabel.Name = "GravityIndicator"
    gravityLabel.BackgroundTransparency = 1
    gravityLabel.Position = UDim2.fromOffset(10, 32)
    gravityLabel.Size = UDim2.new(0, 66, 0, 56)
    gravityLabel.Font = Enum.Font.Gotham
    gravityLabel.TextSize = 11
    gravityLabel.TextXAlignment = Enum.TextXAlignment.Left
    gravityLabel.TextYAlignment = Enum.TextYAlignment.Center
    gravityLabel.TextWrapped = false
    gravityLabel.TextColor3 = Color3.fromRGB(170, 180, 195)
    gravityLabel.Text = "Gravity\nFloor"
    gravityLabel.Parent = panel

    toggleButton = Instance.new("TextButton")
    toggleButton.Name = "WallWalkToggle"
    toggleButton.Size = UDim2.fromOffset(CFG.ToggleWidth, CFG.ToggleHeight)
    toggleButton.Position = UDim2.new(1, -(CFG.ToggleWidth + 9), 0, 33)
    toggleButton.BackgroundColor3 = Color3.fromRGB(20, 120, 180)
    toggleButton.TextColor3 = Color3.new(1, 1, 1)
    toggleButton.Font = Enum.Font.GothamBold
    toggleButton.TextSize = 11
    toggleButton.Text = "ON"
    toggleButton.BorderSizePixel = 0
    toggleButton.Parent = panel

    local buttonCorner = Instance.new("UICorner")
    buttonCorner.CornerRadius = UDim.new(0, 6)
    buttonCorner.Parent = toggleButton

    cameraPOVButton = Instance.new("TextButton")
    cameraPOVButton.Name = "CameraPOVToggle"
    cameraPOVButton.Size = UDim2.fromOffset(CFG.ToggleWidth, CFG.ToggleHeight)
    cameraPOVButton.Position = UDim2.new(1, -(CFG.ToggleWidth + 9), 0, 62)
    cameraPOVButton.BackgroundColor3 = Color3.fromRGB(20, 120, 180)
    cameraPOVButton.TextColor3 = Color3.new(1, 1, 1)
    cameraPOVButton.Font = Enum.Font.GothamBold
    cameraPOVButton.TextSize = 10
    cameraPOVButton.Text = "POV ON"
    cameraPOVButton.BorderSizePixel = 0
    cameraPOVButton.Parent = panel

    local cameraButtonCorner = Instance.new("UICorner")
    cameraButtonCorner.CornerRadius = UDim.new(0, 6)
    cameraButtonCorner.Parent = cameraPOVButton

    local closeButton = Instance.new("TextButton")
    closeButton.Name = "WallWalkChevron"
    closeButton.Size = UDim2.fromOffset(20, 20)
    closeButton.Position = UDim2.new(1, -28, 0.5, -(CFG.PanelHeight / 2) + 4)
    closeButton.BackgroundColor3 = Color3.fromRGB(18, 26, 34)
    closeButton.BackgroundTransparency = 0.04
    closeButton.BorderSizePixel = 0
    closeButton.Text = "<"
    closeButton.TextColor3 = Color3.fromRGB(235, 247, 255)
    closeButton.Font = Enum.Font.GothamBold
    closeButton.TextSize = 14
    closeButton.AutoButtonColor = false
    closeButton.ZIndex = 50
    -- Keep the chevron outside the panel so it remains visible when the panel is hidden.
    closeButton.Parent = gui

    local hubChevronCorner = Instance.new("UICorner")
    hubChevronCorner.CornerRadius = UDim.new(0, 6)
    hubChevronCorner.Parent = closeButton
    local hubChevronStroke = Instance.new("UIStroke")
    hubChevronStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    hubChevronStroke.Color = Color3.fromRGB(48, 139, 218)
    hubChevronStroke.Thickness = 1
    hubChevronStroke.Transparency = 0.48
    hubChevronStroke.Parent = closeButton
    closeButton.Activated:Connect(function()
        panel.Visible = not panel.Visible
        closeButton.Visible = true
    end)

    toggleButton.Activated:Connect(function()
        if enabled then
            enabled = false
            restoreNormal()
        else
            activateWallWalk()
        end
    end)

    cameraPOVButton.Activated:Connect(function()
        cameraPOVEnabled = not cameraPOVEnabled
        if cameraPOVEnabled and enabled then
            installCameraModuleHook()
        end
        updateUI()
    end)


    if UserInputService.TouchEnabled then
        jumpButton = Instance.new("ImageButton")
        jumpButton.Name = "WallWalkJumpButton"
        jumpButton.BackgroundTransparency = 1
        jumpButton.BorderSizePixel = 0
        jumpButton.AutoButtonColor = false
        jumpButton.Active = true
        jumpButton.Image = "rbxasset://textures/ui/Input/TouchControlsSheetV2.png"
        jumpButton.ImageRectOffset = Vector2.new(1, 146)
        jumpButton.ImageRectSize = Vector2.new(144, 144)
        jumpButton.ZIndex = 100
        jumpButton.Visible = enabled
        jumpButton.Parent = gui
        jumpButton.Activated:Connect(requestJump)
        updateJumpButtonLayout()

        table.insert(guiConnections, workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(updateJumpButtonLayout))
        if workspace.CurrentCamera then
            table.insert(guiConnections, workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(updateJumpButtonLayout))
        end
    end

end
]=] },
    { name = '69_getSurfaceName', source = [=[function getSurfaceName()
    if not customActive then return "Floor" end
    if currentUp.Y > 0.82 then return "Floor" end
    if currentUp.Y < -0.82 then return "Ceiling" end
    if math.abs(currentUp.X) > math.abs(currentUp.Z) then
        return currentUp.X > 0 and "Right Wall" or "Left Wall"
    end
    return currentUp.Z > 0 and "Back Wall" or "Front Wall"
end
]=] },
    { name = '70_updateUI', source = [=[function updateUI()
    if toggleButton then
        toggleButton.Text = enabled and "ON" or "OFF"
        toggleButton.BackgroundColor3 = enabled
            and Color3.fromRGB(20, 120, 180)
            or Color3.fromRGB(60, 65, 72)
    end

    local gravityLabel = gui and gui:FindFirstChild("GravityIndicator", true)
    if gravityLabel then
        gravityLabel.Text = "Gravity\n" .. getSurfaceName()
    end

    if cameraPOVButton then
        cameraPOVButton.Text = cameraPOVEnabled and "POV ON" or "POV OFF"
        cameraPOVButton.BackgroundColor3 = cameraPOVEnabled
            and Color3.fromRGB(20, 120, 180)
            or Color3.fromRGB(60, 65, 72)
    end
end

createUI()
updateUI()

if player.Character then
    setupCharacter(player.Character)
end

table.insert(lifecycleConnections, player.CharacterAdded:Connect(function(newCharacter)
    task.defer(function() setupCharacter(newCharacter) end)
end))

table.insert(lifecycleConnections, UserInputService.JumpRequest:Connect(function()
    if enabled then requestJump() end
end))

table.insert(lifecycleConnections, UserInputService.InputBegan:Connect(function(input, processed)
    if processed then return end
    if input.KeyCode == Enum.KeyCode.Space and enabled then requestJump() end
end))

-- PostSimulation is intentionally used for the transition impulse guard: it
-- runs after the physics solver has produced any contact impulse, so the guard
-- can remove only the newly-created outward launch before the next frame's
-- safety detector sees it.
transitionGuardConnection = nil
if RunService.PostSimulation then
    transitionGuardConnection = RunService.PostSimulation:Connect(function()
        if destroyed then return end
        guardTransitionOutwardVelocity()
    end)
end

heartbeatConnection = RunService.Heartbeat:Connect(function(dt)
    if destroyed then return end
    guardTransitionOutwardVelocity()
    update(dt)
    updateCameraStabilization(dt)
    updateUI()
end)]=] },
}

for _, module in ipairs(modules) do
    local chunk, compileError = compiler(module.source)
    if not chunk then
        warn("VGD WallWalk v48.76.113 compile failure in " .. module.name .. ": " .. tostring(compileError))
        return
    end
    if type(setfenv) == "function" then
        local envOk, envError = pcall(setfenv, chunk, sharedEnvironment)
        if not envOk then
            warn("VGD WallWalk v48.76.113 environment failure in " .. module.name .. ": " .. tostring(envError))
            return
        end
    end
    local runOk, runError = pcall(chunk)
    if not runOk then
        warn("VGD WallWalk v48.76.113 runtime failure in " .. module.name .. ": " .. tostring(runError))
        return
    end
end

print("VGD WallWalk v48.76.113: all " .. tostring(#modules) .. " source segments loaded.")

-- The controller is returned from the outer bootstrap environment, while the
-- actual WallWalk state/functions live in sharedEnvironment. Always address
-- that environment explicitly so Enable/Destroy cannot call nil globals.
local controller = {}
function controller.Enable()
    if sharedEnvironment.destroyed then return false end
    if sharedEnvironment.gui then sharedEnvironment.gui.Enabled = true end
    if not sharedEnvironment.enabled then
        local fn = sharedEnvironment.activateWallWalk
        if type(fn) ~= "function" then error("activateWallWalk API is unavailable") end
        fn()
    end
    return true
end
function controller.Disable()
    if sharedEnvironment.destroyed then return true end
    sharedEnvironment.enabled = false
    local restoreFn = sharedEnvironment.restoreNormal
    if type(restoreFn) ~= "function" then error("restoreNormal API is unavailable") end
    restoreFn()
    local updateFn = sharedEnvironment.updateUI
    if type(updateFn) == "function" then updateFn() end
    if sharedEnvironment.gui then sharedEnvironment.gui.Enabled = false end
    return true
end
function controller.SetVisible(visible)
    if sharedEnvironment.destroyed then return false end
    if sharedEnvironment.gui then sharedEnvironment.gui.Enabled = visible == true end
    return true
end
function controller.Destroy()
    local fn = sharedEnvironment.destroyWallWalk
    if type(fn) ~= "function" then error("destroyWallWalk API is unavailable") end
    fn()
    return true
end
function controller.IsEnabled()
    return sharedEnvironment.enabled == true and sharedEnvironment.destroyed ~= true
end
return controller
