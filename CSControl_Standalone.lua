-- VGD CS Control - Standalone Universal Module
-- Extracted from the VGD GUI CS Control system.
-- Direct execution auto-enables; the GUI can set _G.VGD_CSControl_GUIControlled = true
-- before loading this file so it starts disabled and can control it through the API.

local Players = game:GetService("Players")
local player = Players.LocalPlayer
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local csControlEnabled = false
local csControlRenderBound = false
local csControlCharacterConnection = nil
local csControlJumpConnection = nil
local csControlInputBegan = nil
local csControlInputChanged = nil
local csControlInputEnded = nil
local csControlControls = nil
local csControlSaved = nil
local csControlMoverStates = {}
local csDirectPosition = nil
local csDirectVelocityY = 0
local csLastPosition = nil
local csStuckTime = 0
local csDirectMode = false
local csJumpGraceUntil = 0
local CS_CONTROL_BIND_NAME = "VGD_CSControl_Movement"
local CS_DIRECT_SPEED = 18
local CS_JUMP_SPEED = 50
local CS_GRAVITY = workspace.Gravity
local CS_STUCK_THRESHOLD = 0.30

-- Universal fallback mobile controls. Some games completely disable/sink
-- Roblox's normal PlayerModule input during cutscenes, so we provide our own
-- joystick + jump button while CS Control is active.
local CS_TOUCH_DEADZONE = 0.08
local CS_JOYSTICK_RADIUS = 58
local CS_JOYSTICK_CENTER = Vector2.new(88, 0)
local csTouchGui = nil
local csJoystickBase = nil
local csJoystickKnob = nil
local csJumpButton = nil
local csJoystickTouch = nil
local csJoystickVector = Vector3.zero
local csJumpRequested = false
local csTouchStart = nil

local function getPlayerControls()
    local controls = nil
    pcall(function()
        local playerScripts = player:FindFirstChildOfClass("PlayerScripts")
        local playerModule = playerScripts and playerScripts:FindFirstChild("PlayerModule")
        if playerModule then
            local module = require(playerModule)
            if module and module.GetControls then
                controls = module:GetControls()
            end
        end
    end)
    return controls
end

local function getCSMoveVector()
    if csJoystickVector.Magnitude > CS_TOUCH_DEADZONE then
        return csJoystickVector
    end

    local moveVector = Vector3.zero
    if csControlControls then
        pcall(function()
            local value = csControlControls:GetMoveVector()
            if typeof(value) == "Vector3" then
                moveVector = value
            end
        end)
    end
    return moveVector
end

local function destroyCSCustomControls()
    csJoystickTouch = nil
    csJoystickVector = Vector3.zero
    csJumpRequested = false
    csTouchStart = nil
    if csTouchGui then
        csTouchGui:Destroy()
        csTouchGui = nil
        csJoystickBase = nil
        csJoystickKnob = nil
        csJumpButton = nil
    end
end

local function createCSCustomControls()
    if not UserInputService.TouchEnabled or csTouchGui then
        return
    end

    local gui = Instance.new("ScreenGui")
    gui.Name = "VGD_CSControl_TouchGui"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.DisplayOrder = 2000
    gui.Parent = game.CoreGui
    csTouchGui = gui

    local base = Instance.new("Frame")
    base.Name = "JoystickBase"
    base.Size = UDim2.fromOffset(CS_JOYSTICK_RADIUS * 2, CS_JOYSTICK_RADIUS * 2)
    base.Position = UDim2.new(0, CS_JOYSTICK_CENTER.X - CS_JOYSTICK_RADIUS, 1, -145)
    base.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
    base.BackgroundTransparency = 0.35
    base.Active = true
    base.Parent = gui
    Instance.new("UICorner", base).CornerRadius = UDim.new(1, 0)
    csJoystickBase = base

    local knob = Instance.new("Frame")
    knob.Name = "JoystickKnob"
    knob.Size = UDim2.fromOffset(44, 44)
    knob.Position = UDim2.new(0.5, -22, 0.5, -22)
    knob.BackgroundColor3 = Color3.fromRGB(220, 220, 220)
    knob.BackgroundTransparency = 0.15
    knob.Active = false
    knob.Parent = base
    Instance.new("UICorner", knob).CornerRadius = UDim.new(1, 0)
    csJoystickKnob = knob

    local jump = Instance.new("TextButton")
    jump.Name = "JumpButton"
    jump.Size = UDim2.fromOffset(68, 68)
    jump.Position = UDim2.new(1, -100, 1, -145)
    jump.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
    jump.BackgroundTransparency = 0.25
    jump.Text = "JUMP"
    jump.TextColor3 = Color3.new(1, 1, 1)
    jump.Font = Enum.Font.SourceSansBold
    jump.TextSize = 16
    jump.AutoButtonColor = false
    jump.Active = true
    jump.Parent = gui
    Instance.new("UICorner", jump).CornerRadius = UDim.new(1, 0)
    csJumpButton = jump

    jump.Activated:Connect(function()
        csJumpRequested = true
    end)

    local function updateJoystick(position)
        if not csJoystickBase or not csJoystickKnob then return end
        local center = csJoystickBase.AbsolutePosition + csJoystickBase.AbsoluteSize / 2
        local delta = position - center
        if delta.Magnitude > CS_JOYSTICK_RADIUS then
            delta = delta.Unit * CS_JOYSTICK_RADIUS
        end
        csJoystickKnob.Position = UDim2.new(0.5, delta.X - 22, 0.5, delta.Y - 22)
        local x = delta.X / CS_JOYSTICK_RADIUS
        local y = delta.Y / CS_JOYSTICK_RADIUS
        local magnitude = math.sqrt(x * x + y * y)
        if magnitude < CS_TOUCH_DEADZONE then
            csJoystickVector = Vector3.zero
        else
            csJoystickVector = Vector3.new(x, 0, y)
        end
    end

    csControlInputBegan = UserInputService.InputBegan:Connect(function(input)
        if not csControlEnabled or input.UserInputType ~= Enum.UserInputType.Touch then
            return
        end
        if csJoystickTouch then return end
        if csJoystickBase and input.Position.X <= csJoystickBase.AbsolutePosition.X + csJoystickBase.AbsoluteSize.X
            and input.Position.Y >= csJoystickBase.AbsolutePosition.Y - 20 then
            csJoystickTouch = input
            csTouchStart = input.Position
            updateJoystick(input.Position)
        end
    end)

    csControlInputChanged = UserInputService.InputChanged:Connect(function(input)
        if not csControlEnabled or input ~= csJoystickTouch then return end
        updateJoystick(input.Position)
    end)

    csControlInputEnded = UserInputService.InputEnded:Connect(function(input)
        if input ~= csJoystickTouch then return end
        csJoystickTouch = nil
        csTouchStart = nil
        csJoystickVector = Vector3.zero
        if csJoystickKnob then
            csJoystickKnob.Position = UDim2.new(0.5, -22, 0.5, -22)
        end
    end)
end

local function disableCharacterCutsceneMovers(character)
    if not character then return end

    for _, obj in ipairs(character:GetDescendants()) do
        local className = obj.ClassName
        local isConstraint = className == "AlignPosition"
            or className == "AlignOrientation"
            or className == "LinearVelocity"
            or className == "AngularVelocity"
            or className == "VectorForce"
            or className == "Torque"
            or className == "LineForce"
            or className == "BodyPosition"
            or className == "BodyGyro"
            or className == "BodyVelocity"
            or className == "BodyForce"
            or className == "BodyAngularVelocity"
            or className == "BodyThrust"

        if isConstraint then
            if csControlMoverStates[obj] == nil then
                csControlMoverStates[obj] = {Parent = obj.Parent}
                pcall(function()
                    if obj:IsA("AlignPosition") or obj:IsA("AlignOrientation")
                        or obj:IsA("LinearVelocity") or obj:IsA("AngularVelocity")
                        or obj:IsA("VectorForce") or obj:IsA("Torque") or obj:IsA("LineForce") then
                        csControlMoverStates[obj].Enabled = obj.Enabled
                    end
                end)
            end

            -- Removing the mover from the character prevents common cutscene
            -- constraints from immediately snapping the root back.
            pcall(function() obj.Parent = nil end)
        end
    end
end

local function restoreCharacterCutsceneMovers()
    for obj, state in pairs(csControlMoverStates) do
        if obj and obj.Parent == nil and state.Parent then
            pcall(function() obj.Parent = state.Parent end)
        end
        if obj and state.Enabled ~= nil then
            pcall(function() obj.Enabled = state.Enabled end)
        end
    end
    csControlMoverStates = {}
end

local function getDirectMoveDirection(moveVector)
    if typeof(moveVector) ~= "Vector3" or moveVector.Magnitude < CS_TOUCH_DEADZONE then
        return Vector3.zero
    end

    local camera = workspace.CurrentCamera
    if not camera then return Vector3.zero end

    local look = camera.CFrame.LookVector
    local right = camera.CFrame.RightVector
    local flatLook = Vector3.new(look.X, 0, look.Z)
    local flatRight = Vector3.new(right.X, 0, right.Z)

    if flatLook.Magnitude < 0.001 then
        flatLook = Vector3.new(0, 0, -1)
    else
        flatLook = flatLook.Unit
    end
    if flatRight.Magnitude < 0.001 then
        flatRight = Vector3.new(1, 0, 0)
    else
        flatRight = flatRight.Unit
    end

    local direction = flatRight * moveVector.X + flatLook * (-moveVector.Z)
    if direction.Magnitude > 1 then direction = direction.Unit end
    return direction
end

local function directCSJump(root, humanoid)
    if not root or not humanoid then return end
    local now = os.clock()
    if now < csJumpGraceUntil then return end

    -- Re-enable the normal jumping state and request a normal Humanoid jump.
    pcall(function() humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true) end)
    pcall(function() humanoid.Jump = true end)
    pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.Jumping) end)

    -- Also give the root a direct vertical impulse. This is the fallback for
    -- cutscenes that swallow JumpRequest or disable the default jump button.
    csDirectVelocityY = CS_JUMP_SPEED
    csJumpGraceUntil = now + 0.12
    pcall(function()
        local velocity = root.AssemblyLinearVelocity
        root.AssemblyLinearVelocity = Vector3.new(velocity.X, CS_JUMP_SPEED, velocity.Z)
    end)
end

local function updateDirectCSMovement(moveVector, dt, root, humanoid)
    if not root then return end

    if not csDirectPosition then
        csDirectPosition = root.Position
    end

    local direction = getDirectMoveDirection(moveVector)
    local moved = (csLastPosition and (root.Position - csLastPosition).Magnitude) or 0

    if direction.Magnitude > CS_TOUCH_DEADZONE then
        if moved < 0.05 then
            csStuckTime += dt
        else
            csStuckTime = 0
        end
    else
        csStuckTime = 0
    end

    -- Only take over the root when normal Humanoid movement is demonstrably
    -- being blocked. Once takeover begins, keep our own position instead of
    -- copying root.Position every frame; cutscene scripts may continuously
    -- snap the HumanoidRootPart back to their own target.
    if csDirectMode or csStuckTime >= CS_STUCK_THRESHOLD then
        if not csDirectMode then
            csDirectMode = true
            csDirectPosition = root.Position
        end

        if direction.Magnitude > CS_TOUCH_DEADZONE then
            csDirectPosition += direction * CS_DIRECT_SPEED * dt
        end

        -- Simple local jump/fall integration for the hard fallback.
        if csDirectVelocityY ~= 0 then
            csDirectVelocityY -= CS_GRAVITY * dt
            csDirectPosition += Vector3.new(0, csDirectVelocityY * dt, 0)

            local rayParams = RaycastParams.new()
            rayParams.FilterType = Enum.RaycastFilterType.Exclude
            rayParams.FilterDescendantsInstances = {player.Character}
            local hit = workspace:Raycast(csDirectPosition + Vector3.new(0, 2, 0), Vector3.new(0, -5, 0), rayParams)
            if hit and csDirectVelocityY <= 0 then
                csDirectPosition = Vector3.new(csDirectPosition.X, hit.Position.Y + humanoid.HipHeight + 0.5, csDirectPosition.Z)
                csDirectVelocityY = 0
            end
        end

        local currentLook = root.CFrame.LookVector
        local faceDirection = direction.Magnitude > 0.05 and direction or Vector3.new(currentLook.X, 0, currentLook.Z)
        if faceDirection.Magnitude > 0.01 then
            faceDirection = Vector3.new(faceDirection.X, 0, faceDirection.Z).Unit
            pcall(function()
                root.CFrame = CFrame.lookAt(csDirectPosition, csDirectPosition + faceDirection)
            end)
        else
            pcall(function() root.CFrame = CFrame.new(csDirectPosition) * (root.CFrame - root.CFrame.Position) end)
        end
    end

    csLastPosition = root.Position
end

local function saveCSControlState(humanoid, root)
    csControlSaved = {
        WalkSpeed = humanoid.WalkSpeed,
        JumpPower = humanoid.JumpPower,
        JumpHeight = humanoid.JumpHeight,
        UseJumpPower = humanoid.UseJumpPower,
        AutoRotate = humanoid.AutoRotate,
        PlatformStand = humanoid.PlatformStand,
        RootAnchored = root.Anchored,
        JumpingEnabled = humanoid:GetStateEnabled(Enum.HumanoidStateType.Jumping),
        FreefallEnabled = humanoid:GetStateEnabled(Enum.HumanoidStateType.Freefall),
        RunningEnabled = humanoid:GetStateEnabled(Enum.HumanoidStateType.Running),
        PlatformStandingEnabled = humanoid:GetStateEnabled(Enum.HumanoidStateType.PlatformStanding),
    }
end

local function restoreCSControlState(humanoid, root)
    if not csControlSaved then return end
    pcall(function() humanoid.WalkSpeed = csControlSaved.WalkSpeed end)
    pcall(function() humanoid.JumpPower = csControlSaved.JumpPower end)
    pcall(function() humanoid.JumpHeight = csControlSaved.JumpHeight end)
    pcall(function() humanoid.UseJumpPower = csControlSaved.UseJumpPower end)
    pcall(function() humanoid.AutoRotate = csControlSaved.AutoRotate end)
    pcall(function() humanoid.PlatformStand = csControlSaved.PlatformStand end)
    pcall(function() root.Anchored = csControlSaved.RootAnchored end)
    pcall(function() humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, csControlSaved.JumpingEnabled) end)
    pcall(function() humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, csControlSaved.FreefallEnabled) end)
    pcall(function() humanoid:SetStateEnabled(Enum.HumanoidStateType.Running, csControlSaved.RunningEnabled) end)
    pcall(function() humanoid:SetStateEnabled(Enum.HumanoidStateType.PlatformStanding, csControlSaved.PlatformStandingEnabled) end)
end

local function forceCSControlCharacter(dt)
    if not csControlEnabled then return end
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not humanoid or not root then return end

    -- In hard takeover mode, locally anchor the root so common cutscene
    -- Humanoid movement/physics cannot immediately take control back. Our
    -- direct CFrame mover below becomes the movement source instead.
    pcall(function() root.Anchored = csDirectMode end)
    pcall(function() humanoid.PlatformStand = false end)
    disableCharacterCutsceneMovers(character)
    pcall(function() humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true) end)
    pcall(function() humanoid:SetStateEnabled(Enum.HumanoidStateType.Freefall, true) end)
    pcall(function() humanoid:SetStateEnabled(Enum.HumanoidStateType.Running, true) end)
    pcall(function() humanoid:SetStateEnabled(Enum.HumanoidStateType.PlatformStanding, true) end)

    if csControlSaved then
        pcall(function() humanoid.WalkSpeed = math.max(1, csControlSaved.WalkSpeed) end)
        pcall(function() humanoid.JumpPower = math.max(1, csControlSaved.JumpPower) end)
        pcall(function() humanoid.JumpHeight = math.max(1, csControlSaved.JumpHeight) end)
    end

    local moveVector = getCSMoveVector()
    pcall(function() humanoid:Move(moveVector, true) end)

    if csJumpRequested then
        csJumpRequested = false
        directCSJump(root, humanoid)
    end

    updateDirectCSMovement(moveVector, dt or 1/60, root, humanoid)

    if false then
        csJumpRequested = false
        pcall(function()
            humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
            humanoid.Jump = true
            humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
        end)
    end
end

local function enableCSControl()
    if csControlEnabled then return true end

    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not humanoid or not root then return false end

    csControlControls = getPlayerControls()
    saveCSControlState(humanoid, root)
    csDirectPosition = root.Position
    csDirectVelocityY = 0
    csLastPosition = root.Position
    csStuckTime = 0
    csDirectMode = false
    csJumpGraceUntil = 0
    csControlEnabled = true

    if csControlControls then
        pcall(function() csControlControls:Enable() end)
    end

    createCSCustomControls()

    if not csControlRenderBound then
        RunService:BindToRenderStep(CS_CONTROL_BIND_NAME, Enum.RenderPriority.Last.Value, function(dt)
            if not csControlEnabled then return end
            if not csControlControls then csControlControls = getPlayerControls() end
            if csControlControls then pcall(function() csControlControls:Enable() end) end
            forceCSControlCharacter(dt)
        end)
        csControlRenderBound = true
    end

    csControlJumpConnection = UserInputService.JumpRequest:Connect(function()
        if csControlEnabled then csJumpRequested = true end
    end)

    forceCSControlCharacter()

    csControlCharacterConnection = player.CharacterAdded:Connect(function()
        if not csControlEnabled then return end
        task.defer(function()
            if not csControlEnabled then return end
            local newCharacter = player.Character
            local newHumanoid = newCharacter and newCharacter:FindFirstChildOfClass("Humanoid")
            local newRoot = newCharacter and newCharacter:FindFirstChild("HumanoidRootPart")
            if newHumanoid and newRoot then
                csControlControls = getPlayerControls()
                saveCSControlState(newHumanoid, newRoot)
                if csControlControls then pcall(function() csControlControls:Enable() end) end
                createCSCustomControls()
                forceCSControlCharacter()
            end
        end)
    end)

    return true
end

local function disableCSControl()
    csControlEnabled = false

    if csControlRenderBound then
        pcall(function() RunService:UnbindFromRenderStep(CS_CONTROL_BIND_NAME) end)
        csControlRenderBound = false
    end
    if csControlCharacterConnection then csControlCharacterConnection:Disconnect(); csControlCharacterConnection = nil end
    if csControlJumpConnection then csControlJumpConnection:Disconnect(); csControlJumpConnection = nil end
    if csControlInputBegan then csControlInputBegan:Disconnect(); csControlInputBegan = nil end
    if csControlInputChanged then csControlInputChanged:Disconnect(); csControlInputChanged = nil end
    if csControlInputEnded then csControlInputEnded:Disconnect(); csControlInputEnded = nil end

    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if humanoid and root then restoreCSControlState(humanoid, root) end
    restoreCharacterCutsceneMovers()
    csDirectPosition = nil
    csDirectVelocityY = 0
    csLastPosition = nil
    csStuckTime = 0
    csDirectMode = false
    csJumpGraceUntil = 0

    destroyCSCustomControls()
    csControlControls = nil
    csControlSaved = nil
end



-- =========================================================
-- PUBLIC API
-- =========================================================

local VGD_CSControl = {}
local VGD_CSControlGUIControlled = _G.VGD_CSControl_GUIControlled == true

if not VGD_CSControlGUIControlled then
    enableCSControl()
end

function VGD_CSControl.Enable()
    if not csControlEnabled then
        enableCSControl()
    end
    return csControlEnabled
end

function VGD_CSControl.Disable()
    if csControlEnabled then
        disableCSControl()
    end
    return csControlEnabled
end

function VGD_CSControl.Toggle()
    if csControlEnabled then
        disableCSControl()
    else
        enableCSControl()
    end
    return csControlEnabled
end

function VGD_CSControl.IsEnabled()
    return csControlEnabled
end

return VGD_CSControl
