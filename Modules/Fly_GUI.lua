-- VGD Fly GUI Module
-- V198 UI behavior extracted into small helpers to avoid Luau local-register pressure.
local M = {}

local function createRoot(ctx)
    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "VGD_Fly_Standalone"
    screenGui.ResetOnSpawn = false
    screenGui.IgnoreGuiInset = true
    screenGui.DisplayOrder = 1998
    screenGui.Enabled = not ctx.GUI_CONTROLLED
    screenGui.Parent = ctx.player:WaitForChild("PlayerGui")

    local panel = Instance.new("Frame")
    panel.Size = UDim2.fromOffset(220, 232)
    panel.Position = UDim2.new(1, -188, 0, 92)
    panel.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
    panel.BackgroundTransparency = 0.08
    panel.BorderSizePixel = 0
    panel.Parent = screenGui
    Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 12)

    local scale = Instance.new("UIScale")
    scale.Scale = 0.80
    scale.Parent = panel

    ctx.ui.screenGui = screenGui
    ctx.ui.panel = panel
end

local function createLabels(ctx)
    local panel = ctx.ui.panel

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

    local versionLabel = Instance.new("TextLabel")
    versionLabel.Size = UDim2.fromOffset(34, 18)
    versionLabel.Position = UDim2.new(1, -67, 0, 10)
    versionLabel.BackgroundTransparency = 1
    versionLabel.Text = "V198"
    versionLabel.TextColor3 = Color3.fromRGB(145, 145, 145)
    versionLabel.Font = Enum.Font.Gotham
    versionLabel.TextSize = 9
    versionLabel.TextXAlignment = Enum.TextXAlignment.Right
    versionLabel.Parent = panel

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

    ctx.ui.closeButton = closeButton
    ctx.ui.status = status
end

local function createControls(ctx)
    local panel = ctx.ui.panel

    local speedBox = Instance.new("TextBox")
    speedBox.Size = UDim2.fromOffset(92, 30)
    speedBox.Position = UDim2.fromOffset(10, 54)
    speedBox.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
    speedBox.BorderSizePixel = 0
    speedBox.TextColor3 = Color3.new(1, 1, 1)
    speedBox.PlaceholderText = "Speed"
    speedBox.Text = tostring(ctx.getFlySpeed())
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

    local noClipToggle = Instance.new("TextButton")
    noClipToggle.Size = UDim2.fromOffset(200, 30)
    noClipToggle.Position = UDim2.fromOffset(10, 91)
    noClipToggle.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
    noClipToggle.BorderSizePixel = 0
    noClipToggle.TextColor3 = Color3.new(1, 1, 1)
    noClipToggle.Font = Enum.Font.GothamBold
    noClipToggle.TextSize = 11
    noClipToggle.Parent = panel
    Instance.new("UICorner", noClipToggle).CornerRadius = UDim.new(0, 8)

    local collisionDebugToggle = Instance.new("TextButton")
    collisionDebugToggle.Size = UDim2.fromOffset(97, 30)
    collisionDebugToggle.Position = UDim2.fromOffset(10, 126)
    collisionDebugToggle.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
    collisionDebugToggle.BorderSizePixel = 0
    collisionDebugToggle.TextColor3 = Color3.new(1, 1, 1)
    collisionDebugToggle.Font = Enum.Font.GothamBold
    collisionDebugToggle.TextSize = 10
    collisionDebugToggle.Parent = panel
    Instance.new("UICorner", collisionDebugToggle).CornerRadius = UDim.new(0, 8)

    local cameraFeelToggle = Instance.new("TextButton")
    cameraFeelToggle.Size = UDim2.fromOffset(97, 30)
    cameraFeelToggle.Position = UDim2.fromOffset(113, 126)
    cameraFeelToggle.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
    cameraFeelToggle.BorderSizePixel = 0
    cameraFeelToggle.TextColor3 = Color3.new(1, 1, 1)
    cameraFeelToggle.Font = Enum.Font.GothamBold
    cameraFeelToggle.TextSize = 10
    cameraFeelToggle.Parent = panel
    Instance.new("UICorner", cameraFeelToggle).CornerRadius = UDim.new(0, 8)

    local startupAnimationToggle = Instance.new("TextButton")
    startupAnimationToggle.Size = UDim2.fromOffset(200, 30)
    startupAnimationToggle.Position = UDim2.fromOffset(10, 161)
    startupAnimationToggle.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
    startupAnimationToggle.BorderSizePixel = 0
    startupAnimationToggle.TextColor3 = Color3.new(1, 1, 1)
    startupAnimationToggle.Font = Enum.Font.GothamBold
    startupAnimationToggle.TextSize = 10
    startupAnimationToggle.Parent = panel
    Instance.new("UICorner", startupAnimationToggle).CornerRadius = UDim.new(0, 8)

    local hint = Instance.new("TextLabel")
    hint.Size = UDim2.new(1, -20, 0, 28)
    hint.Position = UDim2.fromOffset(10, 198)
    hint.BackgroundTransparency = 1
    hint.Text = "Move + look to climb/dive   •   Space/Ctrl optional"
    hint.TextColor3 = Color3.fromRGB(145, 145, 145)
    hint.Font = Enum.Font.Gotham
    hint.TextSize = 9
    hint.TextXAlignment = Enum.TextXAlignment.Left
    hint.Parent = panel

    ctx.ui.speedBox = speedBox
    ctx.ui.toggle = toggle
    ctx.ui.noClipToggle = noClipToggle
    ctx.ui.collisionDebugToggle = collisionDebugToggle
    ctx.ui.cameraFeelToggle = cameraFeelToggle
    ctx.ui.startupAnimationToggle = startupAnimationToggle
end

local function createShortcut(ctx)
    local screenGui = ctx.ui.screenGui
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
    ctx.ui.shortcut = shortcut
end

local function createShiftLock(ctx)
    local button = Instance.new("ImageButton")
    button.Name = "VGD_FlyShiftLock"
    button.Size = UDim2.fromOffset(30, 30)
    button.AnchorPoint = Vector2.new(0, 0.5)
    button.Position = UDim2.new(0, 18, 0.5, 0)
    button.BackgroundTransparency = 1
    button.BorderSizePixel = 0
    button.AutoButtonColor = false
    button.ScaleType = Enum.ScaleType.Fit
    button.Visible = false
    button.ZIndex = 2001
    button.Parent = ctx.ui.screenGui
    ctx.ui.shiftLockButton = button
end

local function refreshUI(ctx)
    local ui = ctx.ui
    local enabled = ctx.getFlyEnabled()
    local startup = ctx.getFlyStartupActive()
    local speed = math.floor(ctx.getFlySpeed() + 0.5)
    ui.status.Text = startup and ("TAKEOFF  •  Speed " .. tostring(speed))
        or enabled and ("ON  •  Speed " .. tostring(speed))
        or "OFF"
    ui.toggle.Text = enabled and "DISABLE" or "ENABLE"
    ui.shortcut.Text = enabled and "✈  ON" or "✈  FLY"
    ui.noClipToggle.Text = "NO CLIP  •  " .. (ctx.getFlyNoClipOn() and "ON" or "OFF")
    ui.collisionDebugToggle.Text = "COLLISION  •  " .. (ctx.getFlyCollisionDebugOn() and "ON" or "OFF")
    ui.cameraFeelToggle.Text = "CAMERA FEEL  •  " .. (ctx.getFlyCameraFeelOn() and "ON" or "OFF")
    ui.startupAnimationToggle.Text = "STARTUP ANIMATION  •  " .. (ctx.getFlyStartupAnimationEnabled() and "ON" or "OFF")
end

local function updateShiftLockButton(ctx)
    local button = ctx.ui.shiftLockButton
    if not button then return end
    button.Visible = ctx.getFlyEnabled()
    button.Image = ctx.getFlyShiftLockOn()
        and "rbxasset://textures/ui/mouseLock_on@2x.png"
        or "rbxasset://textures/ui/mouseLock_off@2x.png"
end

local function wireBasicEvents(ctx)
    local ui = ctx.ui
    ui.closeButton.Activated:Connect(function()
        if ui.screenGui.Enabled then
            ui.panel.Visible = false
            ui.shortcut.Visible = true
        end
    end)
    ui.toggle.Activated:Connect(function()
        if ctx.getFlyEnabled() then ctx.disableFly() else ctx.enableFly() end
    end)
    ui.shortcut.Activated:Connect(function()
        ui.panel.Visible = true
        ui.shortcut.Visible = false
    end)
    ui.speedBox.FocusLost:Connect(function()
        local value = tonumber(ui.speedBox.Text)
        if value then ctx.setFlySpeed(value) end
        ui.speedBox.Text = tostring(math.floor(ctx.getFlySpeed() + 0.5))
        refreshUI(ctx)
    end)
end

local function wireFeatureEvents(ctx)
    local ui = ctx.ui
    ui.noClipToggle.Activated:Connect(function()
        if not ctx.getFlyEnabled() then return end
        local value = not ctx.getFlyNoClipOn()
        ctx.setFlyNoClipOn(value)
        ctx.setFlyNoClip(value)
        refreshUI(ctx)
    end)
    ui.collisionDebugToggle.Activated:Connect(function()
        if not ctx.getFlyEnabled() then return end
        ctx.setFlyCollisionDebugOn(not ctx.getFlyCollisionDebugOn())
        ctx.updateFlyCollisionDebug()
        refreshUI(ctx)
    end)
    ui.cameraFeelToggle.Activated:Connect(function()
        if not ctx.getFlyEnabled() then return end
        local value = not ctx.getFlyCameraFeelOn()
        ctx.setFlyCameraFeelOn(value)
        if not value then
            ctx.flyState.flyCameraVelocityBlend = Vector3.zero
            ctx.flyState.flyCameraTurnLag = 0
            ctx.flyState.flyCameraFOVBlend = 0
            ctx.flyState.flyCameraLastYaw = ctx.flyState.flyCameraYaw
        end
        refreshUI(ctx)
    end)
end

local function wireStartupEvent(ctx)
    ctx.ui.startupAnimationToggle.Activated:Connect(function()
        local enabled = not ctx.getFlyStartupAnimationEnabled()
        ctx.setFlyStartupAnimationEnabled(enabled)
        if not enabled and ctx.getFlyEnabled() and ctx.getFlyStartupActive() then
            ctx.setFlyStartupActive(false)
            ctx.setFlyStartupTime(0)
            ctx.setFlyStartupStartPosition(nil)
            ctx.stopFlyStartupAnimation()
            ctx.stopFlyStartupPoseDriver()
            ctx.clearFlyStartupPose()
            ctx.clearStartupAnimatorSuppression()
            ctx.startNormalFlyAnimationSet()
        end
        refreshUI(ctx)
    end)
end

local function wireShiftLock(ctx)
    ctx.ui.shiftLockButton.Activated:Connect(function()
        if not ctx.getFlyEnabled() then return end
        ctx.setFlyShiftLockOn(not ctx.getFlyShiftLockOn())
        updateShiftLockButton(ctx)
    end)
end

local function wireStateEvent(ctx)
    ctx.stateChangedEvent.Event:Connect(function()
        refreshUI(ctx)
    end)
end

local function makeController(ctx)
    local Controller = {}
    function Controller.EnableUI()
        ctx.ui.screenGui.Enabled = true
        ctx.ui.panel.Visible = false
        ctx.ui.shortcut.Visible = true
        refreshUI(ctx)
        return true
    end
    function Controller.DisableUI()
        ctx.disableFly()
        refreshUI(ctx)
        ctx.ui.panel.Visible = false
        ctx.ui.shortcut.Visible = false
        ctx.ui.screenGui.Enabled = false
        return true
    end
    function Controller.Enable()
        local ok = ctx.enableFly() == true
        ctx.ui.screenGui.Enabled = true
        ctx.ui.panel.Visible = true
        ctx.ui.shortcut.Visible = false
        return ok
    end
    function Controller.Disable()
        local result = ctx.disableFly()
        refreshUI(ctx)
        return result == false
    end
    function Controller.IsEnabled()
        return ctx.getFlyEnabled() == true
    end
    function Controller.SetSpeed(value)
        local n = tonumber(value)
        if not n then return ctx.getFlySpeed() end
        ctx.setFlySpeed(n)
        ctx.ui.speedBox.Text = tostring(math.floor(ctx.getFlySpeed() + 0.5))
        refreshUI(ctx)
        return ctx.getFlySpeed()
    end
    function Controller.GetSpeed() return ctx.getFlySpeed() end
    function Controller.ShowUI()
        ctx.ui.screenGui.Enabled = true
        ctx.ui.panel.Visible = true
        ctx.ui.shortcut.Visible = false
    end
    function Controller.HideUI()
        if ctx.ui.screenGui.Enabled then
            ctx.ui.panel.Visible = false
            ctx.ui.shortcut.Visible = true
        end
    end
    function Controller.UpdateShiftLockButton() updateShiftLockButton(ctx) end
    Controller.Changed = ctx.stateChangedEvent.Event
    return Controller
end

function M.build(ctx)
    ctx.ui = {}
    createRoot(ctx)
    createLabels(ctx)
    createControls(ctx)
    createShortcut(ctx)
    createShiftLock(ctx)
    wireBasicEvents(ctx)
    wireFeatureEvents(ctx)
    wireStartupEvent(ctx)
    wireShiftLock(ctx)
    wireStateEvent(ctx)
    refreshUI(ctx)
    return makeController(ctx)
end

return M
