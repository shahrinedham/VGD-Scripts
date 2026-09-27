-- VGD Fly Fidget Module
-- Extracted from VGD Fly Standalone v198 without changing fidget timings or state fields.

local M = {}

local CONFIG = {
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
            sourceStart = 0.0,
            sourceEnd = 7.458,
            duration = 7.458,
            blendIn = 0.35,
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
    interruptStartFidgetWeight = 0,
    interruptStartIdleWeight = 1,
    interruptMoveWeight = 0,
    interruptBackwardWeight = 0,
    interruptDirectionBlend = 1,
    currentWeight = 0,
}


-- Return a fresh state/config table for each Fly instance.
function M.new()
    local state = {}
    for k, v in pairs(CONFIG) do
        if type(v) == "table" then
            local copy = {}
            for k2, v2 in pairs(v) do
                if type(v2) == "table" then
                    local inner = {}
                    for k3, v3 in pairs(v2) do inner[k3] = v3 end
                    copy[k2] = inner
                else
                    copy[k2] = v2
                end
            end
            state[k] = copy
        else
            state[k] = v
        end
    end
    return state
end

-- Load only the Fidget AnimationTracks. The main Fly script remains the owner
-- of the tracks and its animation update loop.
function M.loadTracks(flyTracks, load)
    flyTracks.fidget1 = load(CONFIG.variants[1].animationId, Enum.AnimationPriority.Action, false)
    flyTracks.fidget2 = load(CONFIG.variants[2].animationId, Enum.AnimationPriority.Action, false)
    flyTracks.fidget3 = load(CONFIG.variants[3].animationId, Enum.AnimationPriority.Action, false)
end

function M.resetTracks(flyTracks)
    for i = 1, #CONFIG.variants do
        local track = flyTracks[CONFIG.variants[i].trackKey]
        if track then
            pcall(function()
                track:AdjustWeight(0, 0)
                track:Stop(0)
            end)
        end
    end
end

return M
