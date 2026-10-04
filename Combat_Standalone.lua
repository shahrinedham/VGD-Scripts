--[[
    VGD Combat v1 — Standalone R15 Extended Kick Combo

    Controls:
      - Tap floating kick button to execute the full sequence.
      - Tap STOP to cancel.
      - Drag the floating button to reposition it.

    Notes:
      - Animations are loaded through the local character's Animator.
      - Each track is played once even if its source asset is marked looped.
      - Consecutive tracks use a crossfade; tune transition values after testing.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local GUI_NAME = "VGDCombatStandalone"
local oldGui = playerGui:FindFirstChild(GUI_NAME)
if oldGui then oldGui:Destroy() end

local CONFIG = {
    ButtonSize = 52,
    RightOffset = 24,
    VerticalScale = 0.56,
    -- Longer entry/exit fades help avoid snapping from the default idle pose.
    EntryFade = 0.48,
    EntryBlendReadyRatio = 0.95,
    DefaultCrossfade = 0.28,
    MajorCrossfade = 0.42,
    MinimumHold = 0.08,
    RecoveryFade = 0.42,
    -- Used only at the final-to-first boundary when Loop is enabled.
    LoopCrossfade = 0.34,
    SpeedOptions = {0.5, 0.75, 1.0, 1.5, 3.0, 10.0},
    -- Blend durations adapt to playback speed; high speeds retain a minimum fade.
    BlendSpeedMultipliers = {[0.5] = 1.5, [0.75] = 1.25, [1.0] = 1.0, [1.5] = 0.8, [3.0] = 0.5, [10.0] = 0.35},
    -- A little extra transition time for larger movement changes.
    Transitions = {0.70, 0.28, 0.42, 0.32, 0.42},
    EditorStep = 0.05,
}

local sequence = {
    {name = "Triple Roundhouse Kick", id = "91454113537761", looped = false, holdDuration = 1.0},
    {name = "Front Kick", id = "89221612334280", endTrim = 0.10},
    {name = "MMA Kick", id = "82599509502243", endTrim = 0.50, startAt = 0.10},
    {name = "Spinning Kick", id = "131192933653877", endTrim = 0.45},
    {name = "DeltaRune - Tenna Kick", id = "118139885865308", startAt = 0.45},
    {name = "Back Kick Taekwondo", id = "81390895799759", startAt = 0.20},
}

local character, humanoid, animator
local activeTracks = {}
local running = false
local cancelRequested = false
local loopEnabled = false
local runToken = 0
local speedIndex = 3
local currentSpeed = CONFIG.SpeedOptions[speedIndex]
local editorOpen = false
local selectedTransition = 1
local hudExpanded = false
local pressHeld = false
local holdStopTriggered = false
local pressToken = 0
local pointerDown = false
local dragging = false
local dragMoved = false
local activePointerType = nil
local activeTouchInput = nil
local dragStartPosition = nil
local buttonStartPosition = nil

local gui = Instance.new("ScreenGui")
gui.Name = GUI_NAME
gui.ResetOnSpawn = false
gui.IgnoreGuiInset = true
gui.ZIndexBehavior = Enum.ZIndexBehavior.Global
gui.DisplayOrder = 10000
gui.Parent = playerGui

local button = Instance.new("TextButton")
button.Name = "KickButton"
button.AnchorPoint = Vector2.new(1, 0.5)
button.Position = UDim2.new(1, -CONFIG.RightOffset, CONFIG.VerticalScale, 0)
button.Size = UDim2.fromOffset(CONFIG.ButtonSize, CONFIG.ButtonSize)
button.BackgroundColor3 = Color3.fromRGB(29, 27, 43)
button.AutoButtonColor = false
button.Text = "K"
button.TextStrokeTransparency = 1
button.TextColor3 = Color3.fromRGB(238, 230, 255)
button.TextSize = 19
button.Font = Enum.Font.GothamBold
button.ZIndex = 3
button.Parent = gui

local buttonCorner = Instance.new("UICorner")
buttonCorner.CornerRadius = UDim.new(1, 0)
buttonCorner.Parent = button

local buttonStroke = Instance.new("UIStroke")
buttonStroke.Color = Color3.fromRGB(160, 119, 255)
buttonStroke.Thickness = 1.8
buttonStroke.Transparency = 0.08
buttonStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
buttonStroke.Parent = button
local glowTween = TweenService:Create(
    buttonStroke,
    TweenInfo.new(1.15, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
    {Thickness = 2.5, Transparency = 0.18}
)
-- Idle glow is started by the state controller below; it is paused during interaction.

-- Segmented progress ring: each segment lights as the six-move combo advances.
local ringSegments = {}
for i = 1, 12 do
    local angle = (i - 1) * math.pi / 6 - math.pi / 2
    local dot = Instance.new("Frame")
    dot.Name = "ProgressSegment" .. i
    dot.AnchorPoint = Vector2.new(0.5, 0.5)
    dot.Size = UDim2.fromOffset(4, 4)
    dot.Position = UDim2.new(0.5, math.cos(angle) * 31, 0.5, math.sin(angle) * 31)
    dot.BackgroundColor3 = Color3.fromRGB(160, 119, 255)
    dot.BackgroundTransparency = 0.72
    dot.BorderSizePixel = 0
    dot.ZIndex = 4
    dot.Parent = button
    local dotCorner = Instance.new("UICorner")
    dotCorner.CornerRadius = UDim.new(1, 0)
    dotCorner.Parent = dot
    ringSegments[i] = dot
end

local ringTweens = {}
local function updateRing(moveIndex)
    local lit = math.clamp(math.floor((moveIndex / #sequence) * #ringSegments + 0.5), 0, #ringSegments)
    for i, dot in ipairs(ringSegments) do
        if ringTweens[i] then ringTweens[i]:Cancel() end
        local active = i <= lit
        local target = {
            BackgroundTransparency = active and 0.04 or 0.78,
            BackgroundColor3 = active and Color3.fromRGB(190, 153, 255) or Color3.fromRGB(130, 105, 175),
        }
        ringTweens[i] = TweenService:Create(dot, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), target)
        ringTweens[i]:Play()
    end
end

local buttonScale = Instance.new("UIScale")
buttonScale.Scale = 1
buttonScale.Parent = button

-- Button feedback is state-driven so quick taps, drag releases, combo playback,
-- and stop requests all return to the correct visual state without changing layout.
local BUTTON_STATES = {
    Idle = {color = Color3.fromRGB(29, 27, 43), stroke = Color3.fromRGB(160, 119, 255), thickness = 1.8, transparency = 0.08, scale = 1},
    Pressed = {color = Color3.fromRGB(48, 39, 70), stroke = Color3.fromRGB(196, 165, 255), thickness = 2.3, transparency = 0.02, scale = 0.91},
    Playing = {color = Color3.fromRGB(42, 34, 65), stroke = Color3.fromRGB(184, 145, 255), thickness = 2.2, transparency = 0.02, scale = 0.96},
    Stopping = {color = Color3.fromRGB(67, 35, 49), stroke = Color3.fromRGB(255, 135, 157), thickness = 2.1, transparency = 0.04, scale = 0.96},
}
local buttonStateTween
local strokeStateTween
local scaleStateTween
local currentButtonState = "Idle"
local buttonStateGeneration = 0
local function setKickVisualState(stateName, duration)
    local state = BUTTON_STATES[stateName] or BUTTON_STATES.Idle
    buttonStateGeneration += 1
    local generation = buttonStateGeneration
    currentButtonState = stateName
    if glowTween then glowTween:Cancel() end
    if buttonStateTween then buttonStateTween:Cancel() end
    if strokeStateTween then strokeStateTween:Cancel() end
    if scaleStateTween then scaleStateTween:Cancel() end
    buttonStateTween = TweenService:Create(
        button,
        TweenInfo.new(duration or 0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
        {BackgroundColor3 = state.color}
    )
    buttonStateTween:Play()
    strokeStateTween = TweenService:Create(buttonStroke, TweenInfo.new(duration or 0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
        Color = state.stroke,
        Thickness = state.thickness,
        Transparency = state.transparency,
    })
    strokeStateTween:Play()
    scaleStateTween = TweenService:Create(buttonScale, TweenInfo.new(duration or 0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {Scale = state.scale})
    scaleStateTween:Play()
    if stateName == "Idle" then
        task.delay(duration or 0.12, function()
            -- Only the latest transition may restart the idle pulse. This prevents
            -- stale delayed callbacks from overriding a rapid press or respawn.
            if generation == buttonStateGeneration and currentButtonState == "Idle" and glowTween then
                glowTween:Play()
            end
        end)
    end
end
setKickVisualState("Idle", 0)

-- Compact status cluster paired with the draggable kick emblem.
-- Keeping the labels and action buttons inside one card prevents the loose,
-- widely separated layout seen on tall mobile screens.
local hudCard = Instance.new("Frame")
hudCard.Name = "HudInfoCard"
hudCard.AnchorPoint = Vector2.new(1, 0)
hudCard.Position = UDim2.new(1, -CONFIG.RightOffset - 1, CONFIG.VerticalScale, 44)
hudCard.Size = UDim2.fromOffset(116, 104)
hudCard.BackgroundColor3 = Color3.fromRGB(29, 27, 43)
hudCard.BackgroundTransparency = 0.12
hudCard.BorderSizePixel = 0
hudCard.ZIndex = 2
hudCard.Parent = gui
hudCard.Visible = false
local hudCardCorner = Instance.new("UICorner")
hudCardCorner.CornerRadius = UDim.new(0, 12)
hudCardCorner.Parent = hudCard
local hudCardStroke = Instance.new("UIStroke")
hudCardStroke.Color = Color3.fromRGB(125, 94, 201)
hudCardStroke.Thickness = 1
hudCardStroke.Transparency = 0.48
hudCardStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
hudCardStroke.Parent = hudCard

local status = Instance.new("TextLabel")
status.Name = "Status"
status.Position = UDim2.fromOffset(8, 6)
status.Size = UDim2.new(1, -16, 0, 15)
status.BackgroundTransparency = 1
status.Text = "KICK COMBO"
status.TextColor3 = Color3.fromRGB(205, 195, 230)
status.TextSize = 10
status.Font = Enum.Font.GothamSemibold
status.TextXAlignment = Enum.TextXAlignment.Center
status.ZIndex = 3
status.Parent = hudCard

local progress = Instance.new("TextLabel")
progress.Name = "Progress"
progress.Position = UDim2.fromOffset(8, 23)
progress.Size = UDim2.new(1, -16, 0, 15)
progress.BackgroundTransparency = 1
progress.Text = string.format("MOVE · 0/%d", #sequence)
progress.TextColor3 = Color3.fromRGB(205, 195, 230)
progress.TextSize = 10
progress.Font = Enum.Font.GothamSemibold
progress.TextXAlignment = Enum.TextXAlignment.Center
progress.ZIndex = 3
progress.Parent = hudCard

local speedButton = Instance.new("TextButton")
speedButton.Name = "SpeedButton"
speedButton.Position = UDim2.fromOffset(8, 44)
speedButton.Size = UDim2.new(1, -16, 0, 24)
speedButton.BackgroundColor3 = Color3.fromRGB(48, 42, 68)
speedButton.Text = string.format("SPEED  %gx", currentSpeed)
speedButton.TextColor3 = Color3.fromRGB(224, 214, 255)
speedButton.TextSize = 10
speedButton.Font = Enum.Font.GothamBold
speedButton.AutoButtonColor = false
speedButton.ZIndex = 4
speedButton.Parent = hudCard
local speedCorner = Instance.new("UICorner")
speedCorner.CornerRadius = UDim.new(0, 8)
speedCorner.Parent = speedButton

local stopButton = Instance.new("TextButton")
stopButton.Name = "StopButton"
stopButton.Position = UDim2.fromOffset(8, 72)
stopButton.Size = UDim2.new(1, -16, 0, 24)
stopButton.BackgroundColor3 = Color3.fromRGB(85, 43, 55)
stopButton.Text = "■  STOP"
stopButton.TextColor3 = Color3.fromRGB(255, 225, 230)
stopButton.TextSize = 10
stopButton.Font = Enum.Font.GothamBold
stopButton.Visible = false
stopButton.AutoButtonColor = false
stopButton.ZIndex = 4
stopButton.Parent = hudCard
local stopCorner = Instance.new("UICorner")
stopCorner.CornerRadius = UDim.new(0, 8)
stopCorner.Parent = stopButton

local loopButton = Instance.new("TextButton")
loopButton.Name = "LoopButton"
loopButton.Position = stopButton.Position
loopButton.Size = stopButton.Size
loopButton.BackgroundColor3 = Color3.fromRGB(39, 35, 56)
loopButton.Text = ""
loopButton.TextColor3 = Color3.fromRGB(190, 181, 215)
loopButton.TextSize = 11
loopButton.Font = Enum.Font.GothamBold
loopButton.AutoButtonColor = false
loopButton.Visible = true
loopButton.ZIndex = 4
loopButton.Parent = hudCard
local loopCorner = Instance.new("UICorner")
loopCorner.CornerRadius = UDim.new(0, 9)
loopCorner.Parent = loopButton
local loopStroke = Instance.new("UIStroke")
loopStroke.Color = Color3.fromRGB(105, 88, 137)
loopStroke.Thickness = 1
loopStroke.Transparency = 0.28
loopStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
loopStroke.Parent = loopButton
-- Keep only the loop glyph and ON/OFF state in a compact, centered group.
local loopTextGroup = Instance.new("Frame")
loopTextGroup.Name = "LoopTextGroup"
loopTextGroup.AnchorPoint = Vector2.new(0.5, 0.5)
loopTextGroup.Position = UDim2.new(0.5, 0, 0.5, 0)
loopTextGroup.Size = UDim2.fromOffset(84, 24)
loopTextGroup.BackgroundTransparency = 1
loopTextGroup.BorderSizePixel = 0
loopTextGroup.ZIndex = 5
loopTextGroup.Parent = loopButton

local loopSymbol = Instance.new("TextLabel")
loopSymbol.Name = "LoopSymbol"
loopSymbol.BackgroundTransparency = 1
loopSymbol.Position = UDim2.fromOffset(0, 0)
loopSymbol.Size = UDim2.fromOffset(36, 24)
loopSymbol.Font = Enum.Font.GothamMedium
loopSymbol.Text = "∞"
loopSymbol.TextSize = 23
loopSymbol.TextXAlignment = Enum.TextXAlignment.Center
loopSymbol.TextYAlignment = Enum.TextYAlignment.Center
loopSymbol.TextColor3 = Color3.fromRGB(190, 181, 215)
loopSymbol.ZIndex = 6
loopSymbol.Parent = loopTextGroup

local loopStateLabel = Instance.new("TextLabel")
loopStateLabel.Name = "LoopState"
loopStateLabel.BackgroundTransparency = 1
loopStateLabel.Position = UDim2.fromOffset(46, 0)
loopStateLabel.Size = UDim2.fromOffset(38, 24)
loopStateLabel.Font = Enum.Font.GothamBold
loopStateLabel.Text = "OFF"
loopStateLabel.TextSize = 10
loopStateLabel.TextXAlignment = Enum.TextXAlignment.Center
loopStateLabel.TextYAlignment = Enum.TextYAlignment.Center
loopStateLabel.TextColor3 = Color3.fromRGB(155, 145, 176)
loopStateLabel.ZIndex = 6
loopStateLabel.Parent = loopTextGroup

local function refreshLoopButton(animate)
    local on = loopEnabled
    loopStateLabel.Text = on and "ON" or "OFF"
    local duration = animate and 0.14 or 0
    local goals = on and {
        BackgroundColor3 = Color3.fromRGB(65, 45, 94),
        TextColor3 = Color3.fromRGB(239, 226, 255),
    } or {
        BackgroundColor3 = Color3.fromRGB(39, 35, 56),
        TextColor3 = Color3.fromRGB(190, 181, 215),
    }
    local strokeGoals = on and {Color = Color3.fromRGB(174, 133, 255), Transparency = 0.05, Thickness = 1.35}
        or {Color = Color3.fromRGB(105, 88, 137), Transparency = 0.28, Thickness = 1}
    local primaryTextColor = on and Color3.fromRGB(239, 226, 255) or Color3.fromRGB(190, 181, 215)
    local stateTextColor = on and Color3.fromRGB(218, 192, 255) or Color3.fromRGB(145, 136, 164)
    if animate then
        local textTweenInfo = TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
        TweenService:Create(loopButton, textTweenInfo, goals):Play()
        TweenService:Create(loopStroke, textTweenInfo, strokeGoals):Play()
        TweenService:Create(loopSymbol, textTweenInfo, {TextColor3 = primaryTextColor}):Play()
        TweenService:Create(loopStateLabel, textTweenInfo, {TextColor3 = stateTextColor}):Play()
    else
        for key, value in pairs(goals) do loopButton[key] = value end
        for key, value in pairs(strokeGoals) do loopStroke[key] = value end
        loopSymbol.TextColor3 = primaryTextColor
        loopStateLabel.TextColor3 = stateTextColor
    end
end

-- Compact chevron shortcut sits directly below the kick button.
local hudToggle = Instance.new("TextButton")
hudToggle.Name = "HudToggle"
hudToggle.AnchorPoint = Vector2.new(0.5, 0)
local HUD_TOGGLE_WIDTH, HUD_TOGGLE_HEIGHT = 21, 18
hudToggle.Size = UDim2.fromOffset(HUD_TOGGLE_WIDTH, HUD_TOGGLE_HEIGHT)
hudToggle.BackgroundColor3 = Color3.fromRGB(39, 35, 55)
hudToggle.BackgroundTransparency = 0.04
hudToggle.BorderSizePixel = 0
hudToggle.Text = "v"
hudToggle.TextStrokeTransparency = 1
hudToggle.TextColor3 = Color3.fromRGB(224, 214, 255)
hudToggle.TextSize = 12
hudToggle.Font = Enum.Font.GothamBold
hudToggle.AutoButtonColor = false
hudToggle.ZIndex = 5
hudToggle.Parent = gui
local hudToggleCorner = Instance.new("UICorner")
hudToggleCorner.CornerRadius = UDim.new(0, 7)
hudToggleCorner.Parent = hudToggle
local hudToggleStroke = Instance.new("UIStroke")
hudToggleStroke.Color = Color3.fromRGB(145, 111, 226)
hudToggleStroke.Thickness = 1.25
hudToggleStroke.Transparency = 0.22
hudToggleStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
hudToggleStroke.Parent = hudToggle

local function positionHudElements()
    -- Card opens beneath the button; toggle is centered directly under its lower edge.
    hudCard.AnchorPoint = Vector2.new(1, 0)
    hudCard.Position = UDim2.new(button.Position.X.Scale, button.Position.X.Offset, button.Position.Y.Scale, button.Position.Y.Offset + CONFIG.ButtonSize / 2 + 4 + HUD_TOGGLE_HEIGHT + 5)
    hudToggle.Position = UDim2.new(button.Position.X.Scale, button.Position.X.Offset - CONFIG.ButtonSize / 2, button.Position.Y.Scale, button.Position.Y.Offset + CONFIG.ButtonSize / 2 + 4)
end
positionHudElements()

-- Animated HUD open/close controller. A generation token prevents an old
-- collapse delay from hiding the card after the user quickly reopens it.
local HUD_OPEN_SIZE = UDim2.fromOffset(116, 104)
local HUD_CLOSED_SIZE = UDim2.fromOffset(116, 0)
local HUD_TWEEN_INFO = TweenInfo.new(0.22, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local hudAnimationGeneration = 0
local hudCardTween
local hudStrokeTween
local hudContentTweens = {}
local hudContent = {status, progress, speedButton, stopButton, loopButton}

hudCard.ClipsDescendants = true
hudCard.Size = HUD_CLOSED_SIZE
hudCard.BackgroundTransparency = 1
hudCardStroke.Transparency = 1
for _, object in ipairs(hudContent) do
    if object:IsA("TextLabel") then
        object.TextTransparency = 1
    else
        object.BackgroundTransparency = 1
        object.TextTransparency = 1
    end
end

local function setHudExpanded(expanded)
    hudExpanded = expanded
    hudAnimationGeneration += 1
    local generation = hudAnimationGeneration

    if hudCardTween then hudCardTween:Cancel() end
    if hudStrokeTween then hudStrokeTween:Cancel() end
    for _, tween in ipairs(hudContentTweens) do tween:Cancel() end
    table.clear(hudContentTweens)

    hudToggle.Text = expanded and "^" or "v"
    hudToggle.TextColor3 = expanded and Color3.fromRGB(196, 165, 255) or Color3.fromRGB(224, 214, 255)

    if expanded then
        local wasHidden = not hudCard.Visible
        hudCard.Visible = true
        -- Only initialize from fully closed when opening from hidden. If the
        -- user reverses a closing animation, continue from its current size.
        if wasHidden then
            hudCard.Size = HUD_CLOSED_SIZE
            hudCard.BackgroundTransparency = 1
            hudCardStroke.Transparency = 1
        end
    end

    hudCardTween = TweenService:Create(hudCard, HUD_TWEEN_INFO, {
        Size = expanded and HUD_OPEN_SIZE or HUD_CLOSED_SIZE,
        BackgroundTransparency = expanded and 0.12 or 1,
    })
    hudStrokeTween = TweenService:Create(hudCardStroke, HUD_TWEEN_INFO, {
        Transparency = expanded and 0.48 or 1,
    })
    hudCardTween:Play()
    hudStrokeTween:Play()

    for _, object in ipairs(hudContent) do
        local goal = {TextTransparency = expanded and 0 or 1}
        if object:IsA("TextButton") then
            goal.BackgroundTransparency = expanded and (object == stopButton and 0 or 0) or 1
        end
        local tween = TweenService:Create(object, HUD_TWEEN_INFO, goal)
        table.insert(hudContentTweens, tween)
        tween:Play()
    end

    if not expanded then
        task.delay(HUD_TWEEN_INFO.Time + 0.03, function()
            if generation == hudAnimationGeneration and not hudExpanded then
                hudCard.Visible = false
            end
        end)
    end
end

hudToggle.Activated:Connect(function()
    setHudExpanded(not hudExpanded)
end)

local settingsToggle = Instance.new("TextButton")
settingsToggle.Name = "SettingsToggle"
settingsToggle.AnchorPoint = Vector2.new(1, 0)
settingsToggle.Position = UDim2.new(1, -12, 0, 12)
settingsToggle.Size = UDim2.fromOffset(56, 24)
settingsToggle.BackgroundColor3 = Color3.fromRGB(39, 35, 55)
settingsToggle.BackgroundTransparency = 0.02
settingsToggle.BorderSizePixel = 0
settingsToggle.Text = "EDIT"
settingsToggle.TextStrokeTransparency = 1
settingsToggle.TextColor3 = Color3.fromRGB(224, 214, 255)
settingsToggle.TextSize = 10
settingsToggle.Font = Enum.Font.GothamBold
settingsToggle.AutoButtonColor = false
settingsToggle.ZIndex = 30
settingsToggle.Parent = gui
local settingsCorner = Instance.new("UICorner")
settingsCorner.CornerRadius = UDim.new(0, 10)
settingsCorner.Parent = settingsToggle
local settingsStroke = Instance.new("UIStroke")
settingsStroke.Color = Color3.fromRGB(145, 111, 226)
settingsStroke.Thickness = 1.25
settingsStroke.Transparency = 0.2
settingsStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
settingsStroke.Parent = settingsToggle

-- Compact Bar + Values editor layout.
-- Every child uses the same content inset and computed column widths so the
-- left/right edges and gaps stay symmetrical when the editor is scaled.
local EDITOR_WIDTH = 232
local EDITOR_HEIGHT = 250
local EDITOR_PAD = 12
local EDITOR_COL_GAP = 8
local EDITOR_INNER_WIDTH = EDITOR_WIDTH - EDITOR_PAD * 2
local EDITOR_COL_WIDTH = (EDITOR_INNER_WIDTH - EDITOR_COL_GAP * 3) / 4

local editor = Instance.new("Frame")
editor.Name = "TimelineEditor"
editor.AnchorPoint = Vector2.new(1, 0)
editor.Position = UDim2.new(1, -12, 0, 44)
editor.Size = UDim2.fromOffset(EDITOR_WIDTH, EDITOR_HEIGHT)
editor.BackgroundColor3 = Color3.fromRGB(29, 27, 43)
editor.BackgroundTransparency = 0.04
editor.Visible = false
editor.ZIndex = 20
editor.Parent = gui
local editorCorner = Instance.new("UICorner")
editorCorner.CornerRadius = UDim.new(0, 14)
editorCorner.Parent = editor
local editorStroke = Instance.new("UIStroke")
editorStroke.Color = Color3.fromRGB(160, 119, 255)
editorStroke.Transparency = 0.08
editorStroke.Thickness = 1.5
editorStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
editorStroke.Parent = editor
local editorScale = Instance.new("UIScale")
editorScale.Scale = 0.82
editorScale.Parent = editor

local function makeEditorLabel(name, text, y, height)
    local label = Instance.new("TextLabel")
    label.Name = name
    label.Position = UDim2.fromOffset(EDITOR_PAD, y)
    label.Size = UDim2.new(1, -EDITOR_PAD * 2, 0, height or 22)
    label.BackgroundTransparency = 1
    label.Text = text
    label.TextColor3 = Color3.fromRGB(235, 228, 250)
    label.TextSize = 11
    label.Font = Enum.Font.GothamSemibold
    label.TextXAlignment = Enum.TextXAlignment.Center
    label.ZIndex = 21
    label.Parent = editor
    return label
end

local editorTitle = makeEditorLabel("EditorTitle", "COMBO TIMELINE", EDITOR_PAD, 16)
editorTitle.TextSize = 10
editorTitle.TextColor3 = Color3.fromRGB(174, 145, 255)
local transitionLabel = makeEditorLabel("TransitionLabel", "1  →  2", 28, 24)
transitionLabel.TextSize = 16
transitionLabel.Font = Enum.Font.GothamBold

-- Decorative transition rail: endpoints update with the selected pair.
local timelineRail = Instance.new("Frame")
timelineRail.Name = "TransitionRail"
timelineRail.Position = UDim2.fromOffset(EDITOR_PAD, 58)
timelineRail.Size = UDim2.new(1, -EDITOR_PAD * 2, 0, 20)
timelineRail.BackgroundColor3 = Color3.fromRGB(43, 40, 60)
timelineRail.BorderSizePixel = 0
timelineRail.ClipsDescendants = true
timelineRail.ZIndex = 21
timelineRail.Parent = editor
local railCorner = Instance.new("UICorner")
railCorner.CornerRadius = UDim.new(1, 0)
railCorner.Parent = timelineRail
local railFill = Instance.new("Frame")
railFill.Name = "RailFill"
railFill.Size = UDim2.new(0.56, 0, 1, 0)
railFill.BackgroundColor3 = Color3.fromRGB(125, 88, 231)
railFill.BorderSizePixel = 0
railFill.ZIndex = 22
railFill.Parent = timelineRail
local railFillCorner = Instance.new("UICorner")
railFillCorner.CornerRadius = UDim.new(1, 0)
railFillCorner.Parent = railFill
local railGradient = Instance.new("UIGradient")
railGradient.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Color3.fromRGB(160, 119, 255)),
    ColorSequenceKeypoint.new(1, Color3.fromRGB(64, 173, 255)),
})
railGradient.Parent = railFill
local railArrows = Instance.new("TextLabel")
railArrows.Name = "RailArrows"
railArrows.BackgroundTransparency = 1
railArrows.Size = UDim2.new(1, -32, 1, 0)
railArrows.Position = UDim2.fromOffset(16, 0)
railArrows.Text = "›  ›  ›"
railArrows.TextColor3 = Color3.fromRGB(245, 239, 255)
railArrows.TextTransparency = 0.08
railArrows.TextSize = 14
railArrows.Font = Enum.Font.GothamBold
railArrows.TextXAlignment = Enum.TextXAlignment.Center
railArrows.ZIndex = 23
railArrows.Parent = timelineRail

local function makeRailNode(name, text, xScale, color)
    local node = Instance.new("TextLabel")
    node.Name = name
    node.AnchorPoint = Vector2.new(0.5, 0.5)
    node.Position = UDim2.new(xScale, 0, 0.5, 0)
    node.Size = UDim2.fromOffset(18, 18)
    node.BackgroundColor3 = color
    node.BorderSizePixel = 0
    node.Text = text
    node.TextColor3 = Color3.fromRGB(255, 255, 255)
    node.TextSize = 9
    node.Font = Enum.Font.GothamBold
    node.ZIndex = 24
    node.Parent = timelineRail
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(1, 0)
    corner.Parent = node
    return node
end
local railFromNode = makeRailNode("RailFromNode", "1", 0.045, Color3.fromRGB(145, 99, 246))
local railToNode = makeRailNode("RailToNode", "2", 0.955, Color3.fromRGB(55, 155, 238))

-- Three equal metric tiles share one computed row width and gap.
local METRIC_GAP = 6
local METRIC_WIDTH = (EDITOR_INNER_WIDTH - METRIC_GAP * 2) / 3
local metricY = 86
local metricHeight = 38
local function makeMetric(name, title, value, x)
    local card = Instance.new("Frame")
    card.Name = name
    card.Position = UDim2.fromOffset(x, metricY)
    card.Size = UDim2.fromOffset(METRIC_WIDTH, metricHeight)
    card.BackgroundColor3 = Color3.fromRGB(39, 35, 56)
    card.BorderSizePixel = 0
    card.ZIndex = 21
    card.Parent = editor
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 7)
    corner.Parent = card
    local heading = Instance.new("TextLabel")
    heading.Name = "Heading"
    heading.BackgroundTransparency = 1
    heading.Position = UDim2.fromOffset(2, 4)
    heading.Size = UDim2.new(1, -4, 0, 11)
    heading.Text = title
    heading.TextColor3 = Color3.fromRGB(177, 164, 207)
    heading.TextSize = 7
    heading.Font = Enum.Font.GothamSemibold
    heading.TextXAlignment = Enum.TextXAlignment.Center
    heading.ZIndex = 22
    heading.Parent = card
    local valueLabel = Instance.new("TextLabel")
    valueLabel.Name = "Value"
    valueLabel.BackgroundTransparency = 1
    valueLabel.Position = UDim2.fromOffset(2, 17)
    valueLabel.Size = UDim2.new(1, -4, 0, 16)
    valueLabel.Text = value
    valueLabel.TextColor3 = Color3.fromRGB(244, 239, 255)
    valueLabel.TextSize = 11
    valueLabel.Font = Enum.Font.GothamBold
    valueLabel.TextXAlignment = Enum.TextXAlignment.Center
    valueLabel.ZIndex = 22
    valueLabel.Parent = card
    return valueLabel
end
local blendMetricValue = makeMetric("BlendMetric", "LINK  /  BLEND", "0.70s", EDITOR_PAD)
local startMetricValue = makeMetric("StartMetric", "▶  IN START", "0.00s", EDITOR_PAD + METRIC_WIDTH + METRIC_GAP)
local endMetricValue = makeMetric("TrimMetric", "✂  OUT TRIM", "0.00s", EDITOR_PAD + (METRIC_WIDTH + METRIC_GAP) * 2)

local function makeEditorButton(name, text, x, y, w)
    local b = Instance.new("TextButton")
    b.Name = name
    b.Position = UDim2.fromOffset(x, y)
    b.Size = UDim2.fromOffset(w, 28)
    b.BackgroundColor3 = Color3.fromRGB(49, 43, 68)
    b.Text = text
    b.TextColor3 = Color3.fromRGB(242, 236, 255)
    b.TextSize = 12
    b.Font = Enum.Font.GothamBold
    b.ZIndex = 21
    b.Parent = editor
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, 8)
    c.Parent = b
    return b
end

local col1 = EDITOR_PAD
local col2 = col1 + EDITOR_COL_WIDTH + EDITOR_COL_GAP
local col3 = col2 + EDITOR_COL_WIDTH + EDITOR_COL_GAP
local col4 = col3 + EDITOR_COL_WIDTH + EDITOR_COL_GAP
local previousTransitionButton = makeEditorButton("PreviousTransition", "‹", col1, 134, EDITOR_COL_WIDTH)
local blendMinusButton = makeEditorButton("BlendMinus", "B −", col2, 134, EDITOR_COL_WIDTH)
local blendPlusButton = makeEditorButton("BlendPlus", "B +", col3, 134, EDITOR_COL_WIDTH)
local nextTransitionButton = makeEditorButton("NextTransition", "›", col4, 134, EDITOR_COL_WIDTH)
local trimMinusButton = makeEditorButton("TrimMinus", "T −", col1, 168, EDITOR_COL_WIDTH)
local trimPlusButton = makeEditorButton("TrimPlus", "T +", col2, 168, EDITOR_COL_WIDTH)
local startMinusButton = makeEditorButton("StartMinus", "S −", col3, 168, EDITOR_COL_WIDTH)
local startPlusButton = makeEditorButton("StartPlus", "S +", col4, 168, EDITOR_COL_WIDTH)

local ACTION_GAP = 8
local ACTION_WIDTH = (EDITOR_INNER_WIDTH - ACTION_GAP) / 2
local replayButton = makeEditorButton("ReplayPreview", "▶  REPLAY", EDITOR_PAD, EDITOR_HEIGHT - EDITOR_PAD - 28, ACTION_WIDTH)
local stopPreviewButton = makeEditorButton("StopPreview", "■  STOP", EDITOR_PAD + ACTION_WIDTH + ACTION_GAP, EDITOR_HEIGHT - EDITOR_PAD - 28, ACTION_WIDTH)

local function refreshEditor()
    local incoming = selectedTransition + 1
    local outgoingItem = sequence[selectedTransition]
    local incomingItem = sequence[incoming]
    transitionLabel.Text = string.format("%d  →  %d", selectedTransition, incoming)
    railFromNode.Text = tostring(selectedTransition)
    railToNode.Text = tostring(incoming)
    blendMetricValue.Text = string.format("%.2fs", CONFIG.Transitions[selectedTransition] or CONFIG.DefaultCrossfade)
    startMetricValue.Text = string.format("%.2fs", incomingItem.startAt or 0)
    endMetricValue.Text = string.format("%.2fs", outgoingItem.endTrim or 0)
end

local function adjustTrim(delta)
    local item = sequence[selectedTransition]
    item.endTrim = math.clamp((item.endTrim or 0) + delta, 0, 1.5)
    refreshEditor()
end
local function adjustStart(delta)
    local item = sequence[selectedTransition + 1]
    item.startAt = math.clamp((item.startAt or 0) + delta, 0, 1.5)
    refreshEditor()
end

local function scaledBlend(baseDuration, speed)
    local multiplier = CONFIG.BlendSpeedMultipliers[speed] or 1.0
    return math.max(0.05, baseDuration * multiplier)
end

local previewToken = 0
local previewTracks = {}
local IDLE_RAIL_FILL = 0.56
local function setPreviewProgress(fraction)
    railFill.Size = UDim2.new(math.clamp(fraction, 0, 1), 0, 1, 0)
end

local function stopPreview()
    previewToken += 1
    for _, track in ipairs(previewTracks) do
        pcall(function() if track.IsPlaying then track:Stop(0.12) end end)
        pcall(function() track:Destroy() end)
    end
    table.clear(previewTracks)
    setPreviewProgress(IDLE_RAIL_FILL)
end

local function previewSelectedTransition()
    if running or not animator or not editorOpen then return end
    stopPreview()
    local token = previewToken
    local outIndex = selectedTransition
    local outItem, inItem = sequence[outIndex], sequence[outIndex + 1]

    local function load(item)
        local anim = Instance.new("Animation")
        anim.AnimationId = "rbxassetid://" .. item.id
        local ok, track = pcall(function() return animator:LoadAnimation(anim) end)
        anim:Destroy()
        if not ok or not track then return nil end
        track.Priority = Enum.AnimationPriority.Action4
        track.Looped = false
        table.insert(previewTracks, track)
        return track
    end

    local outgoing, incoming = load(outItem), load(inItem)
    if not outgoing or not incoming then stopPreview(); return end

    local speed = currentSpeed
    local blend = scaledBlend(CONFIG.Transitions[outIndex] or CONFIG.DefaultCrossfade, speed)
    local outLength = outgoing.Length > 0 and outgoing.Length or (outItem.holdDuration or 1)
    local inLength = incoming.Length > 0 and incoming.Length or 1
    local outTrim = math.clamp(outItem.endTrim or 0, 0, math.max(0, outLength - 0.05))
    local inStart = math.clamp(inItem.startAt or 0, 0, math.max(0, inLength - 0.02))
    local outgoingDuration = math.max(CONFIG.MinimumHold, (outItem.holdDuration or outLength) - outTrim)
    local incomingDuration = math.max(CONFIG.MinimumHold, inLength - inStart)
    local outgoingSeconds = outgoingDuration / speed
    local incomingSeconds = incomingDuration / speed
    local totalPreviewSeconds = math.max(0.01, outgoingSeconds + incomingSeconds)

    task.spawn(function()
        setPreviewProgress(0)
        outgoing:Play(0.08, 1, speed)
        local elapsed = 0
        while elapsed < outgoingSeconds do
            if token ~= previewToken or not editorOpen or running then return end
            local dt = RunService.Heartbeat:Wait()
            elapsed += dt
            setPreviewProgress(elapsed / totalPreviewSeconds)
        end
        if token ~= previewToken or not editorOpen or running then return end

        incoming:Play(blend, 1, 0)
        incoming.TimePosition = inStart
        incoming:AdjustSpeed(speed)
        if outgoing.IsPlaying then outgoing:Stop(blend) end

        elapsed = 0
        while elapsed < incomingSeconds do
            if token ~= previewToken or not editorOpen or running then return end
            local dt = RunService.Heartbeat:Wait()
            elapsed += dt
            setPreviewProgress((outgoingSeconds + elapsed) / totalPreviewSeconds)
        end
        if token == previewToken then stopPreview() end
    end)
end

local function setStatus(text, color)
    status.Text = text
    if color then status.TextColor3 = color end
end

local function bindCharacter(char)
    character = char
    humanoid = char:WaitForChild("Humanoid", 10)
    animator = nil
    if humanoid then
        animator = humanoid:FindFirstChildOfClass("Animator")
        if not animator then
            animator = humanoid:WaitForChild("Animator", 5)
        end
    end
end

bindCharacter(player.Character or player.CharacterAdded:Wait())
player.CharacterAdded:Connect(function(char)
    cancelRequested = true
    runToken += 1
    pressToken += 1
    pointerDown = false
    dragging = false
    dragMoved = false
    activePointerType = nil
    activeTouchInput = nil
    dragStartPosition = nil
    buttonStartPosition = nil
    holdStopTriggered = false
    running = false
    for _, track in ipairs(activeTracks) do
        pcall(function() track:Stop(0.1) end)
        pcall(function() track:Destroy() end)
    end
    table.clear(activeTracks)
    bindCharacter(char)
    stopButton.Visible = false
    loopButton.Visible = true
    refreshLoopButton(false)
    button.Text = "K"
    setKickVisualState("Idle", 0.16)
    setStatus("KICK COMBO", Color3.fromRGB(205, 195, 230))
    progress.Text = string.format("MOVE · 0/%d", #sequence)
    updateRing(0)
end)

local function cloneAndValidateSequence(source)
    local snapshot = {}
    if type(source) ~= "table" or #source == 0 then
        return nil, "Combo must contain at least one move"
    end
    for index, item in ipairs(source) do
        if type(item) ~= "table" then return nil, "Move " .. index .. " is invalid" end
        local id = tostring(item.id or ""):match("^%s*(%d+)%s*$")
        if not id or #id < 6 then return nil, "Move " .. index .. " has an invalid animation ID" end
        local copy = {}
        for key, value in pairs(item) do copy[key] = value end
        copy.id = id
        copy.name = tostring(copy.name or ("Move " .. index)):sub(1, 48)
        copy.startAt = math.clamp(tonumber(copy.startAt) or 0, 0, 30)
        copy.endTrim = math.clamp(tonumber(copy.endTrim) or 0, 0, 30)
        if copy.holdDuration ~= nil then
            copy.holdDuration = math.clamp(tonumber(copy.holdDuration) or 0.08, CONFIG.MinimumHold, 60)
        end
        if copy.speed ~= nil then copy.speed = math.clamp(tonumber(copy.speed) or 1, 0.1, 10) end
        copy.looped = copy.looped == true
        snapshot[index] = copy
    end
    return snapshot
end

local function loadTracks(sourceSequence)
    if not humanoid or humanoid.Health <= 0 or not animator then
        return nil, "Character or Animator is unavailable"
    end

    local tracks = {}
    for index, item in ipairs(sourceSequence) do
        local animation = Instance.new("Animation")
        animation.Name = "VGDCombat_" .. index
        animation.AnimationId = "rbxassetid://" .. item.id

        local ok, trackOrError = pcall(function()
            return animator:LoadAnimation(animation)
        end)
        animation:Destroy()

        if not ok or not trackOrError then
            for _, loaded in ipairs(tracks) do
                pcall(function() loaded:Destroy() end)
            end
            return nil, "Could not load: " .. item.name
        end

        local track = trackOrError
        track.Priority = Enum.AnimationPriority.Action4
        track.Looped = item.looped == true
        tracks[index] = track
    end
    return tracks
end

local function waitCancelable(seconds, token)
    local elapsed = 0
    while elapsed < seconds do
        if cancelRequested or token ~= runToken then return false end
        if not character or not humanoid or humanoid.Health <= 0 then return false end
        elapsed += RunService.Heartbeat:Wait()
    end
    return true
end

local function stopTracks(tracks, fade)
    for _, track in ipairs(tracks or {}) do
        pcall(function()
            if track.IsPlaying then track:Stop(fade or 0.1) end
        end)
    end
end

local executeCombo

local function finishCombo(tracks, token, completedNormally)
    stopTracks(tracks, CONFIG.RecoveryFade)
    task.wait(CONFIG.RecoveryFade)
    for _, track in ipairs(tracks or {}) do
        pcall(function() track:Destroy() end)
    end
    if token == runToken then
        table.clear(activeTracks)
        running = false
        cancelRequested = false
        stopButton.Visible = false
        loopButton.Visible = true
        button.Text = "K"
        if completedNormally then
            setStatus("COMPLETE", Color3.fromRGB(190, 255, 218))
            progress.Text = string.format("%d/%d · COMBO CLEAR", #sequence, #sequence)
            updateRing(#sequence)
            setKickVisualState("Idle", 0.16)
            task.delay(0.72, function()
                if token == runToken and not running and not loopEnabled then
                    setStatus("KICK COMBO", Color3.fromRGB(205, 195, 230))
                    progress.Text = string.format("MOVE · 0/%d", #sequence)
                    updateRing(0)
                end
            end)
        else
            setStatus("KICK COMBO", Color3.fromRGB(205, 195, 230))
            progress.Text = string.format("MOVE · 0/%d", #sequence)
            updateRing(0)
            setKickVisualState("Idle", 0.16)
        end
    end
end

executeCombo = function()
    if running then return end
    stopPreview()
    local runSequence, validationError = cloneAndValidateSequence(sequence)
    if not runSequence then
        setStatus("INVALID COMBO", Color3.fromRGB(255, 125, 135))
        warn("[VGD Combat] " .. tostring(validationError))
        return
    end
    local tracks, err = loadTracks(runSequence)
    if not tracks then
        setStatus("ANIMATION LOAD ERROR", Color3.fromRGB(255, 125, 135))
        warn("[VGD Combat] " .. tostring(err))
        return
    end

    runToken += 1
    local token = runToken
    cancelRequested = false
    running = true
    activeTracks = tracks
    stopButton.Visible = true
    loopButton.Visible = false
    button.Text = "✦"
    setStatus(string.format("PLAYING · 00/%02d", #runSequence), Color3.fromRGB(205, 195, 230))
    progress.Text = "Preparing first move..."
    updateRing(0)
    setKickVisualState("Playing", 0.16)

    task.spawn(function()
        local previousTrack = nil
        local completedNormally = false
        local nextIndex = 1

        while not cancelRequested and token == runToken do
            local loopToNextCycle = false
            for index = nextIndex, #tracks do
                if cancelRequested or token ~= runToken then break end
                local track = tracks[index]
                local item = runSequence[index]
                setStatus(string.format("PLAYING · %02d/%02d", index, #runSequence), Color3.fromRGB(196, 174, 255))
                progress.Text = item.name
                updateRing(index)

                local duration = item.holdDuration or track.Length
                if not duration or duration <= 0 then duration = 1.5 end
                duration = math.max(CONFIG.MinimumHold, duration - (item.endTrim or 0) - (item.startAt or 0))
                local baseFade = index == 1 and CONFIG.EntryFade or (CONFIG.Transitions[index - 1] or CONFIG.DefaultCrossfade)
                local moveSpeed = item.speed or currentSpeed
                local fade = scaledBlend(baseFade, moveSpeed)

                local ok, playErr = pcall(function()
                    if index == 1 then
                        -- Initial entry blends into the opening pose before releasing the timeline.
                        track.TimePosition = 0
                        track:Play(fade, 1, 0)
                    elseif index == 2 then
                        -- Preserve the existing Front Kick entry blend behavior.
                        track.TimePosition = 0
                        track:Play(fade, 1, 0)
                    elseif item.startAt and item.startAt > 0 then
                        track:Play(fade, 1, 0)
                        track.TimePosition = math.min(item.startAt, math.max(0, track.Length - 0.01))
                        track:AdjustSpeed(moveSpeed)
                    else
                        track.TimePosition = 0
                        track:Play(fade, 1, moveSpeed)
                    end
                end)
                if not ok then
                    warn("[VGD Combat] Playback error for " .. item.name .. ": " .. tostring(playErr))
                    break
                end

                if index == 1 or index == 2 then
                    local blendSettle = fade * CONFIG.EntryBlendReadyRatio
                    if not waitCancelable(blendSettle, token) then break end
                    pcall(function() track:AdjustSpeed(moveSpeed) end)
                end

                -- Start incoming animation before fading the previous one.
                if previousTrack then
                    pcall(function()
                        if previousTrack.IsPlaying then previousTrack:Stop(fade) end
                    end)
                end

                if index < #tracks then
                    -- Preserve the authored clip duration; the incoming clip overlaps its transition.
                    local hold = math.max(CONFIG.MinimumHold, duration / moveSpeed)
                    if not waitCancelable(hold, token) then break end
                    previousTrack = track
                else
                    local totalHold = math.max(CONFIG.MinimumHold, duration / moveSpeed)
                    if loopEnabled and not cancelRequested and token == runToken then
                        -- Bring the next cycle's first kick in during the tail of the final kick.
                        -- This is the only final-to-first crossfade; non-loop playback keeps recovery fade.
                        local seamFade = math.min(
                            scaledBlend(CONFIG.LoopCrossfade, moveSpeed),
                            math.max(0.03, totalHold * 0.45)
                        )
                        local leadWait = math.max(0, totalHold - seamFade)
                        if not waitCancelable(leadWait, token) then break end

                        local firstTrack = tracks[1]
                        local seamOK, seamError = pcall(function()
                            firstTrack.TimePosition = 0
                            firstTrack:Play(seamFade, 1, 0)
                        end)
                        if not seamOK then
                            warn("[VGD Combat] Loop seam error: " .. tostring(seamError))
                            break
                        end
                        setStatus(string.format("LOOPING · 01/%02d", #runSequence), Color3.fromRGB(205, 185, 255))
                        progress.Text = runSequence[1].name
                        updateRing(1)
                        if not waitCancelable(seamFade * CONFIG.EntryBlendReadyRatio, token) then break end
                        local firstMoveSpeed = runSequence[1].speed or currentSpeed
                        pcall(function() firstTrack:AdjustSpeed(firstMoveSpeed) end)
                        pcall(function() if track.IsPlaying then track:Stop(seamFade) end end)
                        local firstDuration = runSequence[1].holdDuration or firstTrack.Length
                        if not firstDuration or firstDuration <= 0 then firstDuration = 1.5 end
                        firstDuration = math.max(CONFIG.MinimumHold, firstDuration - (runSequence[1].endTrim or 0) - (runSequence[1].startAt or 0))
                        if not waitCancelable(firstDuration / firstMoveSpeed, token) then break end
                        previousTrack = firstTrack
                        nextIndex = 2
                        loopToNextCycle = true
                    else
                        if not waitCancelable(totalHold, token) then break end
                        pcall(function()
                            if track.IsPlaying then track:Stop(CONFIG.RecoveryFade) end
                        end)
                        completedNormally = not cancelRequested and token == runToken
                    end
                end
                if loopToNextCycle then break end
            end
            if not loopToNextCycle then break end
        end
        finishCombo(tracks, token, completedNormally)
    end)
end

speedButton.Activated:Connect(function()
    speedIndex = speedIndex % #CONFIG.SpeedOptions + 1
    currentSpeed = CONFIG.SpeedOptions[speedIndex]
    speedButton.Text = string.format("SPEED %gx", currentSpeed)
end)

-- Single-panel editor: retain the original compact timeline editor only.
local function refreshTiming()
    selectedTransition = math.clamp(selectedTransition, 1, math.max(1, #sequence - 1))
end
refreshTiming()

settingsToggle.Activated:Connect(function()
    editorOpen = not editorOpen
    editor.Visible = editorOpen
    if not editorOpen then stopPreview() end
    settingsToggle.Text = editorOpen and "X" or "EDIT"
    if editorOpen then refreshTiming() end
end)
previousTransitionButton.Activated:Connect(function()
    selectedTransition = (selectedTransition - 2) % (#sequence - 1) + 1
    refreshEditor()
    previewSelectedTransition()
end)
nextTransitionButton.Activated:Connect(function()
    selectedTransition = selectedTransition % (#sequence - 1) + 1
    refreshEditor()
    previewSelectedTransition()
end)
blendMinusButton.Activated:Connect(function()
    CONFIG.Transitions[selectedTransition] = math.clamp((CONFIG.Transitions[selectedTransition] or CONFIG.DefaultCrossfade) - CONFIG.EditorStep, 0.05, 1.5)
    refreshEditor()
    previewSelectedTransition()
end)
blendPlusButton.Activated:Connect(function()
    CONFIG.Transitions[selectedTransition] = math.clamp((CONFIG.Transitions[selectedTransition] or CONFIG.DefaultCrossfade) + CONFIG.EditorStep, 0.05, 1.5)
    refreshEditor()
    previewSelectedTransition()
end)
trimMinusButton.Activated:Connect(function() adjustTrim(-CONFIG.EditorStep); previewSelectedTransition() end)
trimPlusButton.Activated:Connect(function() adjustTrim(CONFIG.EditorStep); previewSelectedTransition() end)
startMinusButton.Activated:Connect(function() adjustStart(-CONFIG.EditorStep); previewSelectedTransition() end)
startPlusButton.Activated:Connect(function() adjustStart(CONFIG.EditorStep); previewSelectedTransition() end)
replayButton.Activated:Connect(previewSelectedTransition)
stopPreviewButton.Activated:Connect(stopPreview)

local function requestComboStop()
    if not running or cancelRequested then return end
    cancelRequested = true
    setStatus("STOPPING", Color3.fromRGB(255, 170, 175))
    setKickVisualState("Stopping", 0.12)
    stopTracks(activeTracks, 0.16)
end

local HOLD_TO_STOP_SECONDS = 0.55
local DRAG_THRESHOLD = 8
local pressStartedAt = 0

local function activateKickButton()
    if not running then
        executeCombo()
    end
end

loopButton.Activated:Connect(function()
    if running then return end
    loopEnabled = not loopEnabled
    refreshLoopButton(true)
end)

stopButton.Activated:Connect(requestComboStop)

-- Kick gestures are resolved ONLY on pointer release. We intentionally do not
-- connect KickButton.Activated: Roblox may fire Activated after a drag release,
-- which is the source of the accidental kick-on-drag behavior.
button.InputBegan:Connect(function(input)
    local kind = input.UserInputType
    if kind ~= Enum.UserInputType.MouseButton1 and kind ~= Enum.UserInputType.Touch then return end
    if pointerDown then return end

    pointerDown = true
    dragging = false
    dragMoved = false
    activePointerType = kind
    activeTouchInput = kind == Enum.UserInputType.Touch and input or nil
    dragStartPosition = input.Position
    buttonStartPosition = button.Position
    pressStartedAt = os.clock()
    holdStopTriggered = false
    setKickVisualState("Pressed", 0.075)
    pressToken += 1
    local thisPress = pressToken

    if running then
        task.delay(HOLD_TO_STOP_SECONDS, function()
            if pointerDown and pressToken == thisPress and running and not dragging then
                holdStopTriggered = true
                requestComboStop()
            end
        end)
    end
end)

local function updatePointerPosition(input)
    if not pointerDown or not dragStartPosition or not buttonStartPosition then return end
    local kind = input.UserInputType
    local isMatchingPointer = (activePointerType == Enum.UserInputType.Touch and kind == Enum.UserInputType.Touch and input == activeTouchInput)
        or (activePointerType == Enum.UserInputType.MouseButton1 and kind == Enum.UserInputType.MouseMovement)
    if not isMatchingPointer then return end

    local delta = input.Position - dragStartPosition
    if not running and not dragging and delta.Magnitude >= DRAG_THRESHOLD then
        dragging = true
        dragMoved = true
    end
    if dragging then
        button.Position = UDim2.new(
            buttonStartPosition.X.Scale,
            buttonStartPosition.X.Offset + delta.X,
            buttonStartPosition.Y.Scale,
            buttonStartPosition.Y.Offset + delta.Y
        )
        positionHudElements()
    end
end

-- Keep global input connections owned by this GUI instance. Re-executing the
-- standalone script destroys the previous GUI; disconnect its UIS listeners too
-- so old closures cannot keep updating stale UI or accumulate across reruns.
local managedConnections = {}
local function connectManaged(signal, callback)
    local connection = signal:Connect(callback)
    table.insert(managedConnections, connection)
    return connection
end

gui.Destroying:Connect(function()
    for _, connection in ipairs(managedConnections) do
        if connection.Connected then
            connection:Disconnect()
        end
    end
    table.clear(managedConnections)
end)

connectManaged(UserInputService.InputChanged, updatePointerPosition)

connectManaged(UserInputService.InputEnded, function(input)
    local kind = input.UserInputType
    if not pointerDown then return end
    local matchingRelease = (activePointerType == Enum.UserInputType.Touch and kind == Enum.UserInputType.Touch and input == activeTouchInput)
        or (activePointerType == Enum.UserInputType.MouseButton1 and kind == Enum.UserInputType.MouseButton1)
    if not matchingRelease then return end

    -- Snapshot gesture state before clearing it. A drag can never fall through
    -- to the tap action, regardless of Roblox's Activated event ordering.
    local wasDrag = dragMoved
    local wasLongPress = (os.clock() - pressStartedAt) >= HOLD_TO_STOP_SECONDS
    local wasHoldStop = holdStopTriggered or wasLongPress
    pointerDown = false
    pressToken += 1
    dragging = false
    dragMoved = false
    activePointerType = nil
    activeTouchInput = nil
    dragStartPosition = nil
    buttonStartPosition = nil
    setKickVisualState(running and (cancelRequested and "Stopping" or "Playing") or "Idle", 0.12)

    if not wasDrag and not wasHoldStop and not running then
        activateKickButton()
    end
end)

print("[VGD Combat] Standalone v1 loaded. Tap the kick button to play; hold it during playback to stop.")


-- Controller API for VGD Hub. Direct execution still starts the standalone GUI.
local VGDCombatController = {}
function VGDCombatController.SetEnabled(enabled)
    enabled = enabled == true
    if not enabled then
        runToken += 1
        cancelRequested = true
        stopTracks(activeTracks, 0)
        table.clear(activeTracks)
        stopPreview()
        running = false
        cancelRequested = false
        if stopButton then stopButton.Visible = false end
        if loopButton then loopButton.Visible = true end
        if button then button.Text = "K" end
    end
    gui.Enabled = enabled
    return true
end
function VGDCombatController.IsEnabled() return gui.Enabled end
return VGDCombatController
