-- VGD CS Control - Standalone Universal Module
-- Extracted from the VGD GUI CS Control system.
-- Direct execution auto-enables; the GUI can set _G.VGD_CSControl_GUIControlled = true
-- before loading this file so it starts disabled and can control it through the API.

local Players = game:GetService("Players")
local player = Players.LocalPlayer
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

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
local csGrounded = false
local csLandingRecoveryUntil = 0
local CS_CONTROL_BIND_NAME = "VGD_CSControl_Movement"
local CS_DIRECT_SPEED = 18
local CS_JUMP_SPEED = 50
local CS_GRAVITY = workspace.Gravity
local CS_STUCK_THRESHOLD = 0.30
local CS_GROUND_OFFSET = 0.05
local csAnimationTracks = {}

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
local csTouchGuiWatchConnection = nil
local csDynamicFirstTouch = true

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
    csDynamicFirstTouch = true
    if csTouchGui then
        csTouchGui:Destroy()
        csTouchGui = nil
        csJoystickBase = nil
        csJoystickKnob = nil
        csJumpButton = nil
    end
end

local function createCSCustomControls()
    if not UserInputService.TouchEnabled then
        return
    end
    if csTouchGui and csTouchGui.Parent then
        csTouchGui.Enabled = true
        return
    end
    if csTouchGui then
        csTouchGui = nil
        csJoystickBase = nil
        csJoystickKnob = nil
        csJumpButton = nil
    end

    local gui = Instance.new("ScreenGui")
    gui.Name = "VGD_CSControl_TouchGui"
    gui.ResetOnSpawn = false
    gui.IgnoreGuiInset = true
    gui.ZIndexBehavior = Enum.ZIndexBehavior.Global
    gui.DisplayOrder = 1000000
    gui.Enabled = true
    local playerGui = player:FindFirstChildOfClass("PlayerGui")
    gui.Parent = playerGui or game.CoreGui
    csTouchGui = gui

    -- ================================================================
    -- Roblox Dynamic Thumbstick recreation.
    -- Based on Roblox's DynamicThumbstick CoreScript implementation:
    --   * 45px stick / 20px ring on normal mobile screens
    --   * all dimensions double when min(viewport.X, viewport.Y) > 500
    --   * portrait control zone = bottom 40% of the screen
    --   * landscape control zone = left 40%, lower 2/3 of the screen
    --   * thumbstick appears at the point where the finger first touches
    --   * the visual uses Roblox's TouchControlsSheetV2 sprite region
    -- ================================================================
    local DYNAMIC_SHEET = "rbxasset://textures/ui/Input/TouchControlsSheetV2.png"
    local ThumbstickSize = 45
    local ThumbstickRingSize = 20
    local MiddleSize = 10
    local MiddleSpacing = MiddleSize + 4
    local RadiusOfDeadZone = 2
    local RadiusOfMaxSpeed = 50

    local camera = workspace.CurrentCamera
    local viewport = camera and camera.ViewportSize or Vector2.new(800, 600)
    local isBigScreen = math.min(viewport.X, viewport.Y) > 500
    if isBigScreen then
        ThumbstickSize *= 2
        ThumbstickRingSize *= 2
        MiddleSize *= 2
        MiddleSpacing *= 2
        RadiusOfDeadZone *= 2
        RadiusOfMaxSpeed *= 2
    end

    local thumbstickFrame = Instance.new("Frame")
    thumbstickFrame.Name = "DynamicThumbstickFrame"
    thumbstickFrame.Active = true
    thumbstickFrame.Visible = true
    thumbstickFrame.BackgroundTransparency = 1
    thumbstickFrame.BorderSizePixel = 0
    thumbstickFrame.ZIndex = 90
    thumbstickFrame.Parent = gui

    local gestureArea = Instance.new("Frame")
    gestureArea.Name = "GestureArea"
    gestureArea.Active = false
    gestureArea.Visible = true
    gestureArea.BackgroundTransparency = 1
    gestureArea.BorderSizePixel = 0
    gestureArea.ZIndex = 89
    gestureArea.Parent = gui

    local function layoutDynamicFrame()
        local cam = workspace.CurrentCamera
        local size = cam and cam.ViewportSize or Vector2.new(800, 600)
        local portraitMode = size.X < size.Y

        if portraitMode then
            thumbstickFrame.Size = UDim2.new(1, 0, 0.4, 0)
            thumbstickFrame.Position = UDim2.new(0, 0, 0.6, 0)
            gestureArea.Size = UDim2.new(1, 0, 0.6, 0)
            gestureArea.Position = UDim2.new(0, 0, 0, 0)
        else
            thumbstickFrame.Size = UDim2.new(0.4, 0, 2 / 3, 0)
            thumbstickFrame.Position = UDim2.new(0, 0, 1 / 3, 0)
            gestureArea.Size = UDim2.new(1, 0, 1, 0)
            gestureArea.Position = UDim2.new(0, 0, 0, 0)
        end
    end

    layoutDynamicFrame()

    local startImage = Instance.new("ImageLabel")
    startImage.Name = "ThumbstickStart"
    startImage.Visible = true
    startImage.BackgroundTransparency = 1
    startImage.BorderSizePixel = 0
    startImage.Image = DYNAMIC_SHEET
    startImage.ImageRectOffset = Vector2.new(1, 1)
    startImage.ImageRectSize = Vector2.new(144, 144)
    startImage.ImageColor3 = Color3.new(0, 0, 0)
    startImage.ImageTransparency = 1
    startImage.AnchorPoint = Vector2.new(0.5, 0.5)
    startImage.Position = UDim2.new(0, ThumbstickRingSize * 3.3, 1, -ThumbstickRingSize * 2.8)
    startImage.Size = UDim2.fromOffset(ThumbstickRingSize * 3.7, ThumbstickRingSize * 3.7)
    startImage.ZIndex = 100
    startImage.Parent = thumbstickFrame

    local endImage = Instance.new("ImageLabel")
    endImage.Name = "ThumbstickEnd"
    endImage.Visible = true
    endImage.BackgroundTransparency = 1
    endImage.BorderSizePixel = 0
    endImage.Image = DYNAMIC_SHEET
    endImage.ImageRectOffset = Vector2.new(1, 1)
    endImage.ImageRectSize = Vector2.new(144, 144)
    endImage.AnchorPoint = Vector2.new(0.5, 0.5)
    endImage.Position = startImage.Position
    endImage.Size = UDim2.fromOffset(ThumbstickSize * 0.8, ThumbstickSize * 0.8)
    endImage.ImageTransparency = 1
    endImage.ZIndex = 100
    endImage.Parent = thumbstickFrame

    local middleImages = {}
    local middleTransparencies = {
        1 - 0.89,
        1 - 0.70,
        1 - 0.60,
        1 - 0.50,
        1 - 0.40,
        1 - 0.30,
        1 - 0.25,
    }

    for i, transparency in ipairs(middleTransparencies) do
        local image = Instance.new("ImageLabel")
        image.Name = "ThumbstickMiddle"
        image.Visible = false
        image.BackgroundTransparency = 1
        image.BorderSizePixel = 0
        image.Image = DYNAMIC_SHEET
        image.ImageRectOffset = Vector2.new(1, 1)
        image.ImageRectSize = Vector2.new(144, 144)
        image.ImageTransparency = transparency
        image.AnchorPoint = Vector2.new(0.5, 0.5)
        image.ZIndex = 99
        image.Parent = thumbstickFrame
        middleImages[i] = image
    end

    csJoystickBase = thumbstickFrame
    csJoystickKnob = endImage

    local moveTouchObject = nil
    local moveTouchStartPosition = nil
    local currentDynamicVector = Vector3.zero
    local dynamicMoveConnection = nil
    local dynamicEndConnection = nil
    local dynamicViewportConnection = nil

    local function setDynamicVector(direction)
        local magnitude = direction.Magnitude
        if magnitude < RadiusOfDeadZone then
            currentDynamicVector = Vector3.zero
            csJoystickVector = Vector3.zero
            return
        end

        -- Match Roblox DynamicThumbstick's scaled radial dead-zone exactly:
        -- after the dead-zone, output magnitude is the raw displacement
        -- divided by RadiusOfMaxSpeed, clamped only at the upper end.
        local normalized = direction.Unit
        local scaled = math.clamp(magnitude / RadiusOfMaxSpeed, 0, 1)
        currentDynamicVector = Vector3.new(normalized.X * scaled, 0, normalized.Y * scaled)
        csJoystickVector = currentDynamicVector
    end

    local function layoutMiddleImages(startPos, endPos)
        local startDist = (ThumbstickSize / 2) + MiddleSize
        local vector = endPos - startPos
        local distance = vector.Magnitude
        if distance < 0.001 then
            for _, image in ipairs(middleImages) do
                image.Visible = false
            end
            return
        end

        local distAvailable = distance - (ThumbstickRingSize / 2) - MiddleSize
        local direction = vector.Unit
        local distNeeded = MiddleSpacing * #middleImages
        local spacing = MiddleSpacing
        if distNeeded < distAvailable then
            spacing = distAvailable / #middleImages
        end

        for i, image in ipairs(middleImages) do
            local distWithout = startDist + (spacing * (i - 2))
            local currentDist = startDist + (spacing * (i - 1))
            if distWithout < distAvailable then
                local pos = endPos - direction * currentDist
                local exposedFraction = math.clamp(
                    1 - ((currentDist - distAvailable) / spacing),
                    0,
                    1
                )
                image.Visible = true
                image.Position = UDim2.fromOffset(pos.X, pos.Y)
                image.Size = UDim2.fromOffset(MiddleSize * exposedFraction, MiddleSize * exposedFraction)
            else
                image.Visible = false
            end
        end
    end

    local function moveDynamicStick(position)
        if not moveTouchStartPosition then return end

        local startPos = Vector2.new(
            moveTouchStartPosition.X - thumbstickFrame.AbsolutePosition.X,
            moveTouchStartPosition.Y - thumbstickFrame.AbsolutePosition.Y
        )
        local endPos = Vector2.new(
            position.X - thumbstickFrame.AbsolutePosition.X,
            position.Y - thumbstickFrame.AbsolutePosition.Y
        )

        local relative = endPos - startPos

        -- Roblox keeps using the ACTUAL finger position for movement and for
        -- the visual thumbstick. There is no local touch-distance clamp here.
        -- The movement vector itself is capped at full speed by setDynamicVector().
        endImage.Position = UDim2.fromOffset(endPos.X, endPos.Y)
        layoutMiddleImages(startPos, endPos)
        setDynamicVector(relative)
    end

    local fadeInfo = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut)

    local function fadeDynamicStick(visible)
        if visible then
            TweenService:Create(startImage, fadeInfo, {ImageTransparency = 0}):Play()
            TweenService:Create(endImage, fadeInfo, {ImageTransparency = 0.2}):Play()
            for i, image in ipairs(middleImages) do
                TweenService:Create(image, fadeInfo, {ImageTransparency = middleTransparencies[i]}):Play()
            end
        else
            TweenService:Create(startImage, fadeInfo, {ImageTransparency = 1}):Play()
            TweenService:Create(endImage, fadeInfo, {ImageTransparency = 1}):Play()
            for _, image in ipairs(middleImages) do
                TweenService:Create(image, fadeInfo, {ImageTransparency = 1}):Play()
            end
        end
    end

    local function hideDynamicStick()
        moveTouchObject = nil
        moveTouchStartPosition = nil
        currentDynamicVector = Vector3.zero
        csJoystickVector = Vector3.zero
        fadeDynamicStick(false)
    end

    local function showDynamicStick(input)
        moveTouchObject = input
        moveTouchStartPosition = input.Position

        local startPos = Vector2.new(
            input.Position.X - thumbstickFrame.AbsolutePosition.X,
            input.Position.Y - thumbstickFrame.AbsolutePosition.Y
        )

        startImage.Visible = true
        endImage.Visible = true
        startImage.Position = UDim2.fromOffset(startPos.X, startPos.Y)
        endImage.Position = startImage.Position

        if csDynamicFirstTouch then
            csDynamicFirstTouch = false
            startImage.Size = UDim2.fromOffset(ThumbstickRingSize * 3.7, ThumbstickRingSize * 3.7)
            endImage.Size = UDim2.fromOffset(ThumbstickSize * 0.8, ThumbstickSize * 0.8)

            TweenService:Create(
                startImage,
                TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
                {Size = UDim2.fromOffset(0, 0)}
            ):Play()

            TweenService:Create(
                endImage,
                TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
                {Size = UDim2.fromOffset(ThumbstickSize, ThumbstickSize), ImageColor3 = Color3.new(0, 0, 0)}
            ):Play()
        else
            startImage.Size = UDim2.fromOffset(0, 0)
            endImage.Size = UDim2.fromOffset(ThumbstickSize, ThumbstickSize)
            endImage.ImageColor3 = Color3.new(0, 0, 0)
        end

        for i, image in ipairs(middleImages) do
            image.ImageTransparency = middleTransparencies[i]
        end

        layoutMiddleImages(startPos, startPos)
        setDynamicVector(Vector2.zero)
        fadeDynamicStick(true)
    end

    csControlInputBegan = thumbstickFrame.InputBegan:Connect(function(input)
        if not csControlEnabled then return end
        if input.UserInputType ~= Enum.UserInputType.Touch then return end
        if input.UserInputState ~= Enum.UserInputState.Begin then return end
        if moveTouchObject then return end
        showDynamicStick(input)
        moveDynamicStick(input.Position)
    end)

    dynamicMoveConnection = UserInputService.TouchMoved:Connect(function(input)
        if not csControlEnabled then return end
        if input ~= moveTouchObject then return end
        moveDynamicStick(input.Position)
    end)

    dynamicEndConnection = UserInputService.TouchEnded:Connect(function(input)
        if input ~= moveTouchObject then return end
        hideDynamicStick()
    end)

    csControlInputChanged = dynamicMoveConnection
    csControlInputEnded = dynamicEndConnection

    dynamicViewportConnection = workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
        layoutDynamicFrame()
    end)

    local function connectViewportSize()
        local cam = workspace.CurrentCamera
        if not cam then return end
        return cam:GetPropertyChangedSignal("ViewportSize"):Connect(layoutDynamicFrame)
    end

    local viewportConnection = connectViewportSize()

    -- Roblox's Dynamic Thumbstick starts hidden and only appears at the
    -- finger's touch point. Keep the screen clean until the player touches.
    hideDynamicStick()

    -- Roblox-native jump button visual, matching v18.12 exactly.
    local jump = Instance.new("ImageButton")
    jump.Name = "JumpButton"
    jump.BackgroundTransparency = 1
    jump.BorderSizePixel = 0
    jump.AutoButtonColor = false
    jump.Active = true
    jump.Image = "rbxasset://textures/ui/Input/TouchControlsSheetV2.png"
    jump.ImageRectOffset = Vector2.new(1, 146)
    jump.ImageRectSize = Vector2.new(144, 144)
    jump.ZIndex = 100
    jump.Parent = gui

    local function updateJumpButtonLayout()
        if not jump or not jump.Parent then return end
        local cam = workspace.CurrentCamera
        local vp = cam and cam.ViewportSize or Vector2.new(800, 600)
        local minAxis = math.min(vp.X, vp.Y)
        local isSmallScreen = minAxis <= 500
        local jumpButtonSize = isSmallScreen and 70 or 120

        jump.Size = UDim2.fromOffset(jumpButtonSize, jumpButtonSize)
        jump.Position = isSmallScreen
            and UDim2.new(1, -(jumpButtonSize * 1.5 - 10), 1, -jumpButtonSize - 20)
            or UDim2.new(1, -(jumpButtonSize * 1.5 - 10), 1, -jumpButtonSize * 1.75)
    end

    updateJumpButtonLayout()
    csJumpButton = jump

    jump.Activated:Connect(function()
        csJumpRequested = true
    end)

    -- Keep jump layout responsive without touching the dynamic thumbstick's
    -- actual touch behavior.
    local jumpViewportConnection = workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(updateJumpButtonLayout)
    local jumpCamera = workspace.CurrentCamera
    local jumpViewportSizeConnection = jumpCamera and jumpCamera:GetPropertyChangedSignal("ViewportSize"):Connect(updateJumpButtonLayout) or nil

    -- Store cleanup connections on the GUI so destroying the GUI also releases
    -- all dynamic-thumbstick listeners cleanly.
    gui.Destroying:Connect(function()
        if dynamicMoveConnection then dynamicMoveConnection:Disconnect() end
        if dynamicEndConnection then dynamicEndConnection:Disconnect() end
        if dynamicViewportConnection then dynamicViewportConnection:Disconnect() end
        if viewportConnection then viewportConnection:Disconnect() end
        if jumpViewportConnection then jumpViewportConnection:Disconnect() end
        if jumpViewportSizeConnection then jumpViewportSizeConnection:Disconnect() end
    end)
end

local function startCSCustomControlsWatchdog()
    if csTouchGuiWatchConnection then return end
    if not UserInputService.TouchEnabled then return end

    csTouchGuiWatchConnection = RunService.RenderStepped:Connect(function()
        if not csControlEnabled then return end

        -- Cutscenes can disable/destroy custom ScreenGuis or rebuild PlayerGui.
        -- Keep our independent controls alive while CS Control is active.
        if not csTouchGui or not csTouchGui.Parent then
            createCSCustomControls()
        else
            csTouchGui.Enabled = true
            if csJumpButton then
                local camera = workspace.CurrentCamera
                local viewport = camera and camera.ViewportSize or Vector2.new(800, 600)
                local minAxis = math.min(viewport.X, viewport.Y)
                local isSmallScreen = minAxis <= 500
                local jumpButtonSize = isSmallScreen and 70 or 120

                if csJumpButton.AbsoluteSize.X ~= jumpButtonSize or
                   csJumpButton.AbsoluteSize.Y ~= jumpButtonSize then
                    csJumpButton.Size = UDim2.fromOffset(jumpButtonSize, jumpButtonSize)
                end

                local targetPosition = isSmallScreen
                    and UDim2.new(1, -(jumpButtonSize * 1.5 - 10), 1, -jumpButtonSize - 20)
                    or UDim2.new(1, -(jumpButtonSize * 1.5 - 10), 1, -jumpButtonSize * 1.75)

                if csJumpButton.Position ~= targetPosition then
                    csJumpButton.Position = targetPosition
                end
            end
        end
    end)
end

local function stopCSCustomControlsWatchdog()
    if csTouchGuiWatchConnection then
        csTouchGuiWatchConnection:Disconnect()
        csTouchGuiWatchConnection = nil
    end
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

    -- Preserve the Dynamic Thumbstick magnitude. Roblox's movement pipeline
    -- receives both direction AND analog magnitude; the previous fallback
    -- normalized this vector and therefore made partial thumbstick input move
    -- at full speed.
    local inputMagnitude = math.clamp(moveVector.Magnitude, 0, 1)
    local direction = flatRight * moveVector.X + flatLook * (-moveVector.Z)
    if direction.Magnitude < 0.001 then
        return Vector3.zero
    end

    -- Keep the camera-relative direction normalized, but retain the original
    -- thumbstick magnitude for the direct movement fallback.
    return direction.Unit * inputMagnitude
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

local function getCSGroundY(character, root, humanoid, hitPositionY)
    -- Use Roblox's Humanoid root/hip geometry instead of estimating the
    -- lowest body-part position. The previous body-part scan could be affected
    -- by rotated/custom parts and leave the feet slightly inside the floor.
    -- Root center -> ground is approximately HipHeight + half the root height.
    local rootHalfHeight = root.Size.Y * 0.5
    local rootToGround = humanoid.HipHeight + rootHalfHeight
    return hitPositionY + rootToGround + CS_GROUND_OFFSET
end

local function getCSAnimationObjects(character)
    local walkAnimations = {}
    local runAnimations = {}

    local animate = character and character:FindFirstChild("Animate")
    if not animate then
        return walkAnimations, runAnimations
    end

    for _, obj in ipairs(animate:GetDescendants()) do
        if obj:IsA("Animation") then
            local pathNames = {}
            local current = obj
            while current and current ~= animate do
                table.insert(pathNames, string.lower(current.Name or ""))
                current = current.Parent
            end

            local path = table.concat(pathNames, "/")
            if string.find(path, "run", 1, true) then
                table.insert(runAnimations, obj)
            elseif string.find(path, "walk", 1, true) then
                table.insert(walkAnimations, obj)
            end
        end
    end

    return walkAnimations, runAnimations
end

local function loadCSAnimationTracks(humanoid)
    if not humanoid then return end

    local animator = humanoid:FindFirstChildOfClass("Animator")
    if not animator then
        pcall(function()
            animator = Instance.new("Animator")
            animator.Parent = humanoid
        end)
    end
    if not animator then return end

    local character = humanoid.Parent
    local walkAnimations, runAnimations = getCSAnimationObjects(character)

    -- Keep the joystick/input system completely separate. This only refreshes
    -- the animation tracks used by the direct movement fallback.
    csAnimationTracks = {
        Walk = {},
        Run = {},
        Animator = animator,
    }

    for _, animation in ipairs(walkAnimations) do
        pcall(function()
            local track = animator:LoadAnimation(animation)
            track.Priority = Enum.AnimationPriority.Movement
            table.insert(csAnimationTracks.Walk, track)
        end)
    end

    for _, animation in ipairs(runAnimations) do
        pcall(function()
            local track = animator:LoadAnimation(animation)
            track.Priority = Enum.AnimationPriority.Movement
            table.insert(csAnimationTracks.Run, track)
        end)
    end
end

local function stopCSLocomotionTracks()
    for _, group in pairs({csAnimationTracks.Walk or {}, csAnimationTracks.Run or {}}) do
        for _, track in ipairs(group) do
            pcall(function() track:Stop(0.10) end)
        end
    end
end

local function updateCSAnimations(humanoid, moving, grounded)
    if not humanoid or not grounded then return end

    if not csAnimationTracks.Animator or csAnimationTracks.Animator.Parent ~= humanoid then
        loadCSAnimationTracks(humanoid)
    end

    if not moving then
        stopCSLocomotionTracks()
        return
    end

    -- Direct CFrame movement does not always feed Roblox's Animate script a
    -- physical velocity, so explicitly drive the game's own walk/run assets.
    -- We prefer Run when the game provides one, otherwise Walk.
    local preferred = csAnimationTracks.Run
    if not preferred or #preferred == 0 then
        preferred = csAnimationTracks.Walk
    end

    if not preferred or #preferred == 0 then return end

    for _, track in ipairs(preferred) do
        pcall(function()
            if not track.IsPlaying then
                track:Play(0.10, 1, 1)
            end
            track.Priority = Enum.AnimationPriority.Movement
            track:AdjustSpeed(1)
        end)
    end

    -- Prevent idle locomotion conflicts while our movement track is active.
    local animator = csAnimationTracks.Animator
    if animator then
        for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
            local name = string.lower(track.Name or "")
            if string.find(name, "idle", 1, true) and track ~= preferred[1] then
                pcall(function() track:Stop(0.10) end)
            end
        end
    end
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
            -- Match Roblox Dynamic Thumbstick analog speed: a half-pushed
            -- thumbstick should move at roughly half of full movement speed.
            csDirectPosition += direction * CS_DIRECT_SPEED * dt
        end

        -- Local jump/fall integration for the hard fallback. Keep the working
        -- joystick/input path from v18.1 untouched. Only adjust vertical landing
        -- placement and avoid forcing Running, so the normal Animate script can
        -- choose idle/walk/run naturally.
        local grounded = false
        local rayParams = RaycastParams.new()
        rayParams.FilterType = Enum.RaycastFilterType.Exclude
        rayParams.FilterDescendantsInstances = {player.Character}

        local groundHit = workspace:Raycast(
            csDirectPosition + Vector3.new(0, 2, 0),
            Vector3.new(0, -8, 0),
            rayParams
        )

        if groundHit then
            local groundY = getCSGroundY(player.Character, root, humanoid, groundHit.Position.Y)
            local distanceToGround = csDirectPosition.Y - groundY
            grounded = distanceToGround <= 0.18 and csDirectVelocityY <= 0
        end

        if csDirectVelocityY ~= 0 then
            csDirectVelocityY -= CS_GRAVITY * dt
            csDirectPosition += Vector3.new(0, csDirectVelocityY * dt, 0)

            groundHit = workspace:Raycast(
                csDirectPosition + Vector3.new(0, 2, 0),
                Vector3.new(0, -8, 0),
                rayParams
            )

            if groundHit and csDirectVelocityY <= 0 then
                local groundY = getCSGroundY(player.Character, root, humanoid, groundHit.Position.Y)
                if csDirectPosition.Y <= groundY then
                    csDirectPosition = Vector3.new(csDirectPosition.X, groundY, csDirectPosition.Z)
                    csDirectVelocityY = 0
                    grounded = true
                    csGrounded = true
                    csLandingRecoveryUntil = os.clock() + 0.12
                    -- Clear the jump flag on touchdown. Do not force Running:
                    -- Roblox's Animate script should select idle/walk/run from
                    -- the actual movement speed.
                    pcall(function() humanoid.Jump = false end)
                    pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.Landed) end)
                end
            end
        end

        if grounded and csDirectVelocityY == 0 then
            csGrounded = true
            pcall(function() humanoid.Jump = false end)
            -- Do not force Landed every frame. Doing that prevents Roblox's
            -- Animate script from seeing a normal running state, which makes
            -- the run animation fall back to idle. Only enter Landed on the
            -- actual touchdown; while moving, let Humanoid:Move drive Running.
            if direction.Magnitude > CS_TOUCH_DEADZONE then
                pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.Running) end)
            end
        elseif csDirectVelocityY > 0 then
            csGrounded = false
            pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.Jumping) end)
        elseif csDirectVelocityY < 0 then
            csGrounded = false
            pcall(function() humanoid:ChangeState(Enum.HumanoidStateType.Freefall) end)
        end

        if csGrounded and os.clock() < csLandingRecoveryUntil then
            pcall(function() humanoid.Jump = false end)
        end

        updateCSAnimations(
            humanoid,
            direction.Magnitude > CS_TOUCH_DEADZONE,
            csGrounded and csDirectVelocityY == 0
        )

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
        AutoJumpEnabled = humanoid.AutoJumpEnabled,
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
    if csControlSaved.AutoJumpEnabled ~= nil then
        pcall(function() humanoid.AutoJumpEnabled = csControlSaved.AutoJumpEnabled end)
    end
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

    if UserInputService.TouchEnabled then
        -- Dynamic Thumbstick enables AutoJump while it is active.
        pcall(function() humanoid.AutoJumpEnabled = true end)
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
    csAnimationTracks = {}
    csGrounded = false
    csLandingRecoveryUntil = 0
    csControlEnabled = true

    if csControlControls then
        pcall(function() csControlControls:Enable() end)
    end

    createCSCustomControls()
    startCSCustomControlsWatchdog()

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
    csAnimationTracks = {}
    csGrounded = false
    csLandingRecoveryUntil = 0

    local restoreCharacter = player.Character
    local restoreHumanoid = restoreCharacter and restoreCharacter:FindFirstChildOfClass("Humanoid")
    if restoreHumanoid then
        local animator = restoreHumanoid:FindFirstChildOfClass("Animator")
        if animator then
            for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
                local name = string.lower(track.Name or "")
                if string.find(name, "walk", 1, true) or string.find(name, "run", 1, true) then
                    pcall(function() track:Stop(0.1) end)
                end
            end
        end
    end

    destroyCSCustomControls()
    stopCSCustomControlsWatchdog()
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
