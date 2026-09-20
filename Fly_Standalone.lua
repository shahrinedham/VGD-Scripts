-- VGD Fly Standalone
-- Real-body flight controller for VGD.
-- Loaded by the VGD Self tab; it can also be executed independently.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ContextActionService = game:GetService("ContextActionService")

local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

local flyEnabled = false
local flySpeed = 55
local flyMinSpeed = 1
local flyMaxSpeed = 500
local flyVerticalInput = 0
local flyRenderConnection = nil
local flyCharacterConnection = nil
local flySaved = nil
local stateChangedEvent = Instance.new("BindableEvent")

local GUI_CONTROLLED = _G.VGD_Fly_GUIControlled == true

local function getCharacter()
    return player.Character
end

local function getHumanoidAndRoot()
    local character = getCharacter()
    if not character then return nil, nil end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local root = character:FindFirstChild("HumanoidRootPart")
    if not humanoid or not root then return nil, nil end
    return humanoid, root
end

local function saveCharacterState(humanoid, root)
    flySaved = {
        humanoid = humanoid,
        root = root,
        platformStand = humanoid.PlatformStand,
        autoRotate = humanoid.AutoRotate,
        rootVelocity = root.AssemblyLinearVelocity,
        rootAngularVelocity = root.AssemblyAngularVelocity,
    }
end

local function restoreCharacterState()
    local saved = flySaved
    flySaved = nil

    local humanoid, root = getHumanoidAndRoot()
    if saved and saved.humanoid and saved.humanoid.Parent == getCharacter() then
        humanoid = saved.humanoid
    end
    if saved and saved.root and saved.root.Parent == getCharacter() then
        root = saved.root
    end

    if humanoid then
        humanoid.PlatformStand = saved and saved.platformStand or false
        humanoid.AutoRotate = saved and saved.autoRotate or true
    end

    if root then
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
    end
end

local function setFlyVelocity()
    if not flyEnabled then return end

    local humanoid, root = getHumanoidAndRoot()
    if not humanoid or not root then return end

    local move = humanoid.MoveDirection
    local cam = workspace.CurrentCamera
    if not cam then return end

    -- Humanoid.MoveDirection is already camera-relative on Roblox's normal
    -- controls, so preserve it and add explicit vertical input separately.
    local horizontal = Vector3.new(move.X, 0, move.Z)
    local moveMagnitude = math.clamp(move.Magnitude, 0, 1)

    if horizontal.Magnitude > 1 then
        horizontal = horizontal.Unit
    end

    -- Looking upward/downward while moving also controls flight altitude.
    -- This keeps Fly usable on mobile where there is no keyboard Space/C.
    local cameraPitch = 0
    if moveMagnitude > 0.05 then
        cameraPitch = cam.LookVector.Y * moveMagnitude
    end

    local vertical = math.clamp(cameraPitch + flyVerticalInput, -1, 1)
    local velocity = horizontal * flySpeed
    velocity += Vector3.new(0, vertical * flySpeed, 0)
    root.AssemblyLinearVelocity = velocity
    root.AssemblyAngularVelocity = Vector3.zero

    -- Keep the character facing the direction of travel when moving.
    if horizontal.Magnitude > 0.05 then
        local look = horizontal.Unit
        root.CFrame = CFrame.lookAt(root.Position, root.Position + look)
    end
end

local function verticalAction(_, inputState, inputObject)
    if not flyEnabled then
        return Enum.ContextActionResult.Pass
    end

    local direction = 0
    if inputObject.KeyCode == Enum.KeyCode.Space then
        direction = 1
    elseif inputObject.KeyCode == Enum.KeyCode.LeftControl
        or inputObject.KeyCode == Enum.KeyCode.C then
        direction = -1
    end

    if inputState == Enum.UserInputState.Begin then
        flyVerticalInput = direction
        return Enum.ContextActionResult.Sink
    elseif inputState == Enum.UserInputState.End
        or inputState == Enum.UserInputState.Cancel then
        if flyVerticalInput == direction then
            flyVerticalInput = 0
        end
        return Enum.ContextActionResult.Sink
    end

    return Enum.ContextActionResult.Sink
end

local function bindVerticalControls()
    ContextActionService:BindActionAtPriority(
        "VGD_FlyVertical",
        verticalAction,
        false,
        Enum.ContextActionPriority.High.Value,
        Enum.KeyCode.Space,
        Enum.KeyCode.LeftControl,
        Enum.KeyCode.C
    )
end

local function unbindVerticalControls()
    ContextActionService:UnbindAction("VGD_FlyVertical")
    flyVerticalInput = 0
end

local function enableFly()
    if flyEnabled then return true end

    local humanoid, root = getHumanoidAndRoot()
    if not humanoid or not root then
        return false
    end

    saveCharacterState(humanoid, root)
    flyEnabled = true
    flyVerticalInput = 0

    humanoid.PlatformStand = true
    humanoid.AutoRotate = false
    bindVerticalControls()

    if flyRenderConnection then
        flyRenderConnection:Disconnect()
    end

    flyRenderConnection = RunService.RenderStepped:Connect(function()
        setFlyVelocity()
    end)

    stateChangedEvent:Fire(true)
    return true
end

local function disableFly()
    if not flyEnabled then
        return false
    end

    flyEnabled = false
    unbindVerticalControls()

    if flyRenderConnection then
        flyRenderConnection:Disconnect()
        flyRenderConnection = nil
    end

    restoreCharacterState()
    stateChangedEvent:Fire(false)
    return false
end

local function onCharacterAdded(character)
    if flyCharacterConnection then
        flyCharacterConnection:Disconnect()
        flyCharacterConnection = nil
    end

    -- CharacterAdded is only used as a respawn watcher; do not store the
    -- Instance returned by WaitForChild as a Connection.
    task.spawn(function()
        character:WaitForChild("Humanoid", 10)
        character:WaitForChild("HumanoidRootPart", 10)

        if flyEnabled then
            task.defer(function()
                if flyEnabled then
                    local humanoid, root = getHumanoidAndRoot()
                    if humanoid and root then
                        flySaved = nil
                        saveCharacterState(humanoid, root)
                        humanoid.PlatformStand = true
                        humanoid.AutoRotate = false
                    end
                end
            end)
        end
    end)

end

player.CharacterAdded:Connect(onCharacterAdded)

-- Standalone GUI. When VGD loads this controller it is intentionally hidden;
-- the VGD Self tab remains the visible control surface.
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "VGD_Fly_Standalone"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.DisplayOrder = 1998
screenGui.Enabled = not GUI_CONTROLLED
screenGui.Parent = player:WaitForChild("PlayerGui")

local panel = Instance.new("Frame")
panel.Size = UDim2.fromOffset(230, 145)
panel.Position = UDim2.new(1, -242, 0, 90)
panel.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
panel.BackgroundTransparency = 0.08
panel.BorderSizePixel = 0
panel.Parent = screenGui
Instance.new("UICorner", panel).CornerRadius = UDim.new(0, 12)

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -20, 0, 28)
title.Position = UDim2.fromOffset(10, 8)
title.BackgroundTransparency = 1
title.Text = "VGD  •  FLY"
title.TextColor3 = Color3.new(1, 1, 1)
title.Font = Enum.Font.GothamBold
title.TextSize = 16
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = panel

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -20, 0, 20)
status.Position = UDim2.fromOffset(10, 38)
status.BackgroundTransparency = 1
status.Text = "OFF"
status.TextColor3 = Color3.fromRGB(170, 170, 170)
status.Font = Enum.Font.Gotham
status.TextSize = 12
status.TextXAlignment = Enum.TextXAlignment.Left
status.Parent = panel

local speedBox = Instance.new("TextBox")
speedBox.Size = UDim2.new(1, -20, 0, 32)
speedBox.Position = UDim2.fromOffset(10, 65)
speedBox.BackgroundColor3 = Color3.fromRGB(40, 40, 40)
speedBox.BorderSizePixel = 0
speedBox.TextColor3 = Color3.new(1, 1, 1)
speedBox.PlaceholderText = "Fly speed"
speedBox.Text = tostring(flySpeed)
speedBox.Font = Enum.Font.Gotham
speedBox.TextSize = 13
speedBox.ClearTextOnFocus = false
speedBox.Parent = panel
Instance.new("UICorner", speedBox).CornerRadius = UDim.new(0, 8)

local toggle = Instance.new("TextButton")
toggle.Size = UDim2.new(1, -20, 0, 32)
toggle.Position = UDim2.fromOffset(10, 104)
toggle.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
toggle.BorderSizePixel = 0
toggle.TextColor3 = Color3.new(1, 1, 1)
toggle.Text = "ENABLE FLY"
toggle.Font = Enum.Font.GothamBold
toggle.TextSize = 12
toggle.Parent = panel
Instance.new("UICorner", toggle).CornerRadius = UDim.new(0, 8)

toggle.Activated:Connect(function()
    if flyEnabled then
        disableFly()
    else
        enableFly()
    end
end)

speedBox.FocusLost:Connect(function()
    local value = tonumber(speedBox.Text)
    if value then
        flySpeed = math.clamp(value, flyMinSpeed, flyMaxSpeed)
    end
    speedBox.Text = tostring(math.floor(flySpeed + 0.5))
end)

local function refreshStandaloneUI()
    status.Text = flyEnabled and ("ON  •  Speed " .. tostring(math.floor(flySpeed + 0.5))) or "OFF"
    toggle.Text = flyEnabled and "DISABLE FLY" or "ENABLE FLY"
end

stateChangedEvent.Event:Connect(refreshStandaloneUI)
refreshStandaloneUI()

local Controller = {}

function Controller.Enable()
    return enableFly() == true
end

function Controller.Disable()
    return disableFly() == false
end

function Controller.IsEnabled()
    return flyEnabled == true
end

function Controller.SetSpeed(value)
    local n = tonumber(value)
    if not n then return flySpeed end
    flySpeed = math.clamp(n, flyMinSpeed, flyMaxSpeed)
    speedBox.Text = tostring(math.floor(flySpeed + 0.5))
    refreshStandaloneUI()
    return flySpeed
end

function Controller.GetSpeed()
    return flySpeed
end

Controller.Changed = stateChangedEvent.Event

return Controller
