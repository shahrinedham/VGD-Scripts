-- VGD Standalone Animation ID Finder v1
-- Extracted from the VGD Design2 v120 animation-ID finder.
--
-- Purpose:
--   Watch the LOCAL CHARACTER's playing AnimationTracks and report
--   previously unknown animation IDs to the Developer Console (F9).
--
-- Usage:
--   1. Execute this script.
--   2. Play/equip the animation you want to identify.
--   3. Press F9 and check the Log/Output.
--   4. Look for:
--      [VGD ANIMATION FINDER] NEW UNKNOWN | ID=...
--
-- This script does not contain the VGD GUI, Fly, Freecam, ESP, etc.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer

-- IDs already identified in the original VGD finder.
-- These are ignored so the console focuses on new animations.
local KNOWN_ANIMATION_IDS = {
    ["106706162821039"] = "Known Idle",
    ["122267405214601"] = "Known Walk",
    ["92749812489844"] = "Known Run",
    ["117465215021389"] = "Known Backward Emote",
    ["3303162967"] = "Known Udzal Walk (unrelated)",
    ["18537384940"] = "Known Adidas Sports Run (unrelated)",
    ["96700657317980"] = "Known/old candidate",
    ["9249714289844"] = "Known/old candidate",
}

local animationFinderConnection = nil
local animationFinderSeen = {}

local function scanAnimations()
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")

    if not animator then
        return
    end

    for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
        local animation = track.Animation
        local rawId = animation and animation.AnimationId or ""
        local id = string.match(rawId, "%d+")

        if id
            and not KNOWN_ANIMATION_IDS[id]
            and track.IsPlaying
            and (track.Length or 0) > 0.05
        then
            if not animationFinderSeen[id] then
                animationFinderSeen[id] = true

                warn(string.format(
                    "[VGD ANIMATION FINDER] NEW UNKNOWN | ID=%s | Priority=%s | Length=%.3f | Speed=%.3f | Weight=%.3f | Playing=%s",
                    id,
                    tostring(track.Priority),
                    track.Length or 0,
                    track.Speed or 0,
                    track.WeightCurrent or 0,
                    tostring(track.IsPlaying)
                ))
            end
        end
    end
end

local function startAnimationFinder()
    if animationFinderConnection then
        animationFinderConnection:Disconnect()
        animationFinderConnection = nil
    end

    animationFinderSeen = {}

    animationFinderConnection = RunService.Heartbeat:Connect(scanAnimations)

    warn("[VGD ANIMATION FINDER] v1 ACTIVE.")
    warn("[VGD ANIMATION FINDER] Known IDs are blocked: Idle=106706162821039, Walk=122267405214601, Run=92749812489844, Backward=117465215021389.")
    warn("[VGD ANIMATION FINDER] Play/equip the animation you want to identify and look for NEW UNKNOWN.")
end

startAnimationFinder()

player.CharacterAdded:Connect(function()
    animationFinderSeen = {}
    warn("[VGD ANIMATION FINDER] Character changed; finder remains active.")
end)
