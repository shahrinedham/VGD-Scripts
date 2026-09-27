-- =========================================================
-- VGD STANDALONE ANIMATION ID FINDER v6
-- VGD-STYLE C CONSOLE SHORTCUT
-- =========================================================

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local StarterGui = game:GetService("StarterGui")

local player = Players.LocalPlayer

-- =========================================================
-- KNOWN ANIMATION IDS
-- =========================================================

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

-- =========================================================
-- ANIMATION FINDER
-- =========================================================

local animationFinderConnection = nil
local animationFinderSeen = {}

-- Console output policy:
--   * Normal startup/known-ID information: print() -> normal/white
--   * Newly detected unknown animation IDs: warn() -> yellow

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

    animationFinderConnection =
        RunService.Heartbeat:Connect(scanAnimations)

    -- Normal informational messages use print(), so they appear
    -- as normal console text instead of yellow warnings.
    print("[VGD ANIMATION FINDER] v5 ACTIVE.")
    print("[VGD ANIMATION FINDER] Known IDs are blocked:")
    print("[VGD ANIMATION FINDER] Idle=106706162821039")
    print("[VGD ANIMATION FINDER] Walk=122267405214601")
    print("[VGD ANIMATION FINDER] Run=92749812489844")
    print("[VGD ANIMATION FINDER] Backward=117465215021389")
end

-- =========================================================
-- GUI
-- =========================================================

local playerGui = player:WaitForChild("PlayerGui")

local oldGui = playerGui:FindFirstChild("VGD_AnimationFinder")
if oldGui then
    oldGui:Destroy()
end

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "VGD_AnimationFinder"
ScreenGui.ResetOnSpawn = false
ScreenGui.IgnoreGuiInset = true
ScreenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
ScreenGui.Parent = playerGui

-- =========================================================
-- VGD-STYLE C SHORTCUT
-- =========================================================

local ConsoleButton = Instance.new("TextButton", ScreenGui)

ConsoleButton.Name = "ConsoleShortcut"

ConsoleButton.Size = UDim2.new(
    0, 44,
    0, 44
)

ConsoleButton.Position = UDim2.new(
    1, -55,
    0.55, -150
)

ConsoleButton.AnchorPoint = Vector2.new(0.5, 0.5)

ConsoleButton.BackgroundColor3 = Color3.fromRGB(18, 26, 34)

ConsoleButton.Text = "C"
ConsoleButton.TextColor3 = Color3.new(1, 1, 1)
ConsoleButton.Font = Enum.Font.SourceSansBold
ConsoleButton.TextSize = 22

ConsoleButton.AutoButtonColor = false
ConsoleButton.Active = true

local ConsoleCorner = Instance.new("UICorner")
ConsoleCorner.CornerRadius = UDim.new(0, 8)
ConsoleCorner.Parent = ConsoleButton

local ConsoleShortcutStroke = Instance.new("UIStroke")
ConsoleShortcutStroke.Color = Color3.fromRGB(45, 170, 255)
ConsoleShortcutStroke.Thickness = 1.5
ConsoleShortcutStroke.Transparency = 0.15
ConsoleShortcutStroke.Parent = ConsoleButton

-- =========================================================
-- C BUTTON DRAG STATE
-- =========================================================

local consoleDragging = false
local consoleDragStart = nil
local consoleStartPosition = nil
local consoleActiveInput = nil
local consoleMoved = false

local function clampConsolePosition(position)
    local parent = ConsoleButton.Parent

    if not parent then
        return position
    end

    local parentSize = parent.AbsoluteSize
    local buttonSize = ConsoleButton.AbsoluteSize

    if parentSize.X <= 0
        or parentSize.Y <= 0
        or buttonSize.X <= 0
        or buttonSize.Y <= 0
    then
        return position
    end

    local centerX =
        parentSize.X * position.X.Scale
        + position.X.Offset

    local centerY =
        parentSize.Y * position.Y.Scale
        + position.Y.Offset

    local halfWidth = buttonSize.X * 0.5
    local halfHeight = buttonSize.Y * 0.5

    local minCenterX = halfWidth
    local maxCenterX = math.max(
        minCenterX,
        parentSize.X - halfWidth
    )

    local minCenterY = halfHeight
    local maxCenterY = math.max(
        halfHeight,
        parentSize.Y - halfHeight
    )

    centerX = math.clamp(
        centerX,
        minCenterX,
        maxCenterX
    )

    centerY = math.clamp(
        centerY,
        minCenterY,
        maxCenterY
    )

    return UDim2.new(
        position.X.Scale,
        centerX - (
            parentSize.X * position.X.Scale
        ),
        position.Y.Scale,
        centerY - (
            parentSize.Y * position.Y.Scale
        )
    )
end

-- =========================================================
-- CONSOLE TOGGLE
-- =========================================================
--
-- Use Roblox's actual DevConsoleVisible core state instead of
-- maintaining our own boolean. This is important because the
-- Developer Console can also be closed by its own X button.
--
-- Roblox documents:
--   StarterGui:GetCore("DevConsoleVisible")
-- as returning the current Developer Console visibility.
-- =========================================================

local function getConsoleVisible()
    for _ = 1, 3 do
        local success, visible = pcall(function()
            return StarterGui:GetCore("DevConsoleVisible")
        end)

        if success and type(visible) == "boolean" then
            return visible
        end

        task.wait(0.05)
    end

    return nil
end

local function setConsoleVisible(visible)
    for _ = 1, 3 do
        local success = pcall(function()
            StarterGui:SetCore(
                "DevConsoleVisible",
                visible
            )
        end)

        if success then
            return true
        end

        task.wait(0.05)
    end

    return false
end

local function toggleConsole()
    local currentVisible = getConsoleVisible()

    if currentVisible == nil then
        -- If Roblox has not exposed the state yet, default to opening.
        setConsoleVisible(true)
        return
    end

    setConsoleVisible(not currentVisible)
end

-- =========================================================
-- C BUTTON INPUT
-- =========================================================

ConsoleButton.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.Touch
        or input.UserInputType == Enum.UserInputType.MouseButton1
    then
        consoleDragging = true
        consoleMoved = false
        consoleActiveInput = input

        consoleDragStart = input.Position
        consoleStartPosition = ConsoleButton.Position
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if not consoleDragging then
        return
    end

    if input ~= consoleActiveInput then
        return
    end

    local delta = input.Position - consoleDragStart

    if math.abs(delta.X) > 5
        or math.abs(delta.Y) > 5
    then
        consoleMoved = true
    end

    local newPosition = UDim2.new(
        consoleStartPosition.X.Scale,
        consoleStartPosition.X.Offset + delta.X,
        consoleStartPosition.Y.Scale,
        consoleStartPosition.Y.Offset + delta.Y
    )

    ConsoleButton.Position =
        clampConsolePosition(newPosition)
end)

UserInputService.InputEnded:Connect(function(input)
    if not consoleDragging then
        return
    end

    if input ~= consoleActiveInput then
        return
    end

    consoleDragging = false

    -- Same VGD behavior:
    -- tap = action
    -- drag = move only
    if not consoleMoved then
        toggleConsole()
    end

    consoleActiveInput = nil
end)

-- =========================================================
-- CHARACTER CHANGE
-- =========================================================

player.CharacterAdded:Connect(function()
    animationFinderSeen = {}
end)

-- =========================================================
-- START
-- =========================================================

startAnimationFinder()
