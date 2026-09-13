-- 🌀 VGD Bring + TP + ESP + View + Others GUI
-- Mobile + Emulator
-- AntiFling v20 - Aggressive Instant NDS Hazard Protection
-- + Global Unanchored-Part Collision Shield
-- + NDS Instant Hazard Disable
-- + NDS Instant TouchInterest Removal
-- + NDS Property Lock
-- + NDS Descendant Tracking
-- + High-Speed Burst / Spam Protection
-- + No Fall Damage
--
-- Barrier = physical walls + anti-stuck recovery
-- AntiFling = global unanchored-part no-collision
--            + nearby no-collision
--            + player no-collision
--            + local protection
--            + AGGRESSIVE NDS hazard protection
--            + Super Ring Parts V6 no-fall method
-- NFD = separate standalone Super Ring Parts V6 no-fall method
-- Float = unchanged


local Players = game:GetService("Players")
local player = Players.LocalPlayer
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Lighting = game:GetService("Lighting")
local PhysicsService = game:GetService("PhysicsService")


-- =========================================================
-- COLORS
-- =========================================================

local DEFAULT_BTN_COLOR = Color3.fromRGB(60, 60, 60)
local ACTIVE_BTN_COLOR = Color3.fromRGB(0, 200, 120)
local TAB_BTN_COLOR = Color3.fromRGB(50, 50, 50)
local TAB_ACTIVE_COLOR = Color3.fromRGB(0, 180, 255)
local SEARCH_BG_COLOR = Color3.fromRGB(45, 45, 45)
local CONTENT_BG_COLOR = Color3.fromRGB(35, 35, 35)
local LEFT_BG_COLOR = Color3.fromRGB(40, 40, 40)
local TITLE_BG_COLOR = Color3.fromRGB(30, 30, 30)


-- =========================================================
-- SCREEN GUI
-- =========================================================

local ScreenGui = Instance.new("ScreenGui")
ScreenGui.Name = "BringTPGui"
ScreenGui.ResetOnSpawn = false
ScreenGui.Parent = game.CoreGui


-- =========================================================
-- MAIN FRAME
-- =========================================================

local Frame = Instance.new("Frame")
Frame.Size = UDim2.new(0, 280, 0, 260)

-- Y changed from 20% to 5%
Frame.Position = UDim2.new(0.05, 0, 0.05, 0)

Frame.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
Frame.Active = true
Frame.Draggable = true
Frame.Parent = ScreenGui

Instance.new("UICorner", Frame).CornerRadius = UDim.new(0, 16)

local UIScale = Instance.new("UIScale")

-- Start at minimum scale
UIScale.Scale = 0.75

UIScale.Parent = Frame

local MIN_SCALE = 0.75
local MAX_SCALE = 1


-- =========================================================
-- TITLE BAR
-- =========================================================

local TitleBar = Instance.new("Frame")
TitleBar.Size = UDim2.new(1, 0, 0, 32)
TitleBar.BackgroundColor3 = TITLE_BG_COLOR
TitleBar.Parent = Frame

Instance.new("UICorner", TitleBar).CornerRadius = UDim.new(0, 16)

local Title = Instance.new("TextLabel")
Title.Size = UDim2.new(1, -120, 1, 0)
Title.Position = UDim2.new(0, 12, 0, 0)
Title.BackgroundTransparency = 1
Title.Text = "📍 Bring & TP & ESP GUI"
Title.TextColor3 = Color3.new(1, 1, 1)
Title.TextXAlignment = Enum.TextXAlignment.Left
Title.Font = Enum.Font.SourceSansBold
Title.TextSize = 18
Title.Parent = TitleBar


-- =========================================================
-- TOP-RIGHT BUTTONS
-- =========================================================

local BUTTON_WIDTH = 28
local BUTTON_HEIGHT = 24
local BUTTON_SPACING = 6
local RIGHT_MARGIN = 8

local function makeTopRightBtn(parent, index, text, color)

    local Btn = Instance.new("TextButton")

    Btn.Size = UDim2.new(
        0,
        BUTTON_WIDTH,
        0,
        BUTTON_HEIGHT
    )

    Btn.Position = UDim2.new(
        1,
        -RIGHT_MARGIN -
        (BUTTON_WIDTH + BUTTON_SPACING) * index +
        BUTTON_SPACING,
        0.5,
        -BUTTON_HEIGHT / 2
    )

    Btn.BackgroundColor3 = color
    Btn.Text = text
    Btn.TextColor3 = Color3.new(1, 1, 1)
    Btn.TextScaled = true
    Btn.Font = Enum.Font.SourceSansBold
    Btn.Parent = parent

    Instance.new("UICorner", Btn).CornerRadius =
        UDim.new(0, 8)

    return Btn
end

local CloseBtn = makeTopRightBtn(
    TitleBar,
    1,
    "X",
    Color3.fromRGB(180, 0, 0)
)

local MinBtn = makeTopRightBtn(
    TitleBar,
    2,
    "_",
    Color3.fromRGB(100, 100, 100)
)

local NcBtn = makeTopRightBtn(
    TitleBar,
    3,
    "NC",
    Color3.fromRGB(80, 80, 160)
)


-- =========================================================
-- LEFT MENU
-- =========================================================

local LeftMenu = Instance.new("Frame")
LeftMenu.Size = UDim2.new(0, 80, 1, -32)
LeftMenu.Position = UDim2.new(0, 0, 0, 32)
LeftMenu.BackgroundColor3 = LEFT_BG_COLOR
LeftMenu.Parent = Frame

Instance.new("UICorner", LeftMenu).CornerRadius = UDim.new(0, 16)

local TabButtons = {}
local SelectedTab = "Bring"

local function makeTabBtn(name, yPos)

    local Btn = Instance.new("TextButton")

    Btn.Size = UDim2.new(1, -8, 0, 32)
    Btn.Position = UDim2.new(0, 4, 0, yPos)

    Btn.Text = name
    Btn.Font = Enum.Font.SourceSansBold
    Btn.TextSize = 16
    Btn.TextColor3 = Color3.new(1, 1, 1)

    Btn.BackgroundColor3 =
        (SelectedTab == name)
        and TAB_ACTIVE_COLOR
        or TAB_BTN_COLOR

    Btn.Parent = LeftMenu

    Instance.new("UICorner", Btn).CornerRadius =
        UDim.new(0, 10)

    Btn.MouseButton1Click:Connect(function()

        SelectedTab = name

        for tName, tBtn in pairs(TabButtons) do

            tBtn.BackgroundColor3 =
                (tName == name)
                and TAB_ACTIVE_COLOR
                or TAB_BTN_COLOR

        end

        refreshPlayers()

    end)

    TabButtons[name] = Btn

end

makeTabBtn("Bring", 5)
makeTabBtn("TP to", 43)
makeTabBtn("View", 81)
makeTabBtn("ESP", 119)
makeTabBtn("Others", 157)


-- =========================================================
-- CONTENT FRAME
-- =========================================================

local ContentFrame = Instance.new("Frame")
ContentFrame.Size = UDim2.new(1, -80, 1, -32)
ContentFrame.Position = UDim2.new(0, 80, 0, 32)
ContentFrame.BackgroundColor3 = CONTENT_BG_COLOR
ContentFrame.Parent = Frame

Instance.new("UICorner", ContentFrame).CornerRadius = UDim.new(0, 16)


-- =========================================================
-- SEARCH BOX
-- =========================================================

local SearchBox = Instance.new("TextBox")
SearchBox.Size = UDim2.new(1, -12, 0, 32)
SearchBox.Position = UDim2.new(0, 6, 0, 6)
SearchBox.PlaceholderText = "Search Player..."
SearchBox.Text = ""
SearchBox.ClearTextOnFocus = false
SearchBox.BackgroundColor3 = SEARCH_BG_COLOR
SearchBox.TextColor3 = Color3.new(1, 1, 1)
SearchBox.Font = Enum.Font.SourceSansBold
SearchBox.TextSize = 16
SearchBox.Parent = ContentFrame

Instance.new("UICorner", SearchBox).CornerRadius = UDim.new(0, 10)


-- =========================================================
-- ALL BUTTON
-- =========================================================

local AllButtonContainer = Instance.new("Frame")
AllButtonContainer.Size = UDim2.new(1, -12, 0, 28)
AllButtonContainer.Position = UDim2.new(0, 6, 0, 44)
AllButtonContainer.BackgroundTransparency = 1
AllButtonContainer.Visible = true
AllButtonContainer.Parent = ContentFrame

local AllBtn = Instance.new("TextButton")
AllBtn.Size = UDim2.new(1, 0, 1, 0)
AllBtn.Text = "All : OFF"
AllBtn.Font = Enum.Font.SourceSansBold
AllBtn.TextSize = 16
AllBtn.TextColor3 = Color3.new(1, 1, 1)
AllBtn.BackgroundColor3 = DEFAULT_BTN_COLOR
AllBtn.Parent = AllButtonContainer

Instance.new("UICorner", AllBtn).CornerRadius = UDim.new(0, 8)


-- =========================================================
-- STOP VIEW BUTTON
-- =========================================================

local StopViewContainer = Instance.new("Frame")
StopViewContainer.Size = UDim2.new(1, -12, 0, 28)
StopViewContainer.Position = UDim2.new(0, 6, 0, 44)
StopViewContainer.BackgroundTransparency = 1
StopViewContainer.Visible = false
StopViewContainer.Parent = ContentFrame

local StopViewBtn = Instance.new("TextButton")
StopViewBtn.Size = UDim2.new(1, 0, 1, 0)
StopViewBtn.Text = "Stop Viewing"
StopViewBtn.Font = Enum.Font.SourceSansBold
StopViewBtn.TextSize = 16
StopViewBtn.TextColor3 = Color3.new(1, 1, 1)
StopViewBtn.BackgroundColor3 = DEFAULT_BTN_COLOR
StopViewBtn.Parent = StopViewContainer

Instance.new("UICorner", StopViewBtn).CornerRadius = UDim.new(0, 8)


-- =========================================================
-- PLAYER LIST
-- =========================================================

local PlayerList = Instance.new("ScrollingFrame")
PlayerList.Size = UDim2.new(1, 0, 1, -78)
PlayerList.Position = UDim2.new(0, 0, 0, 78)
PlayerList.CanvasSize = UDim2.new(0, 0, 0, 0)
PlayerList.ScrollBarThickness = 6
PlayerList.BackgroundTransparency = 1
PlayerList.Parent = ContentFrame


-- =========================================================
-- BRING
-- =========================================================

local BRING_DISTANCE = 4
local bringing = {}
local bringAll = false


-- =========================================================
-- INFINITE JUMP
-- =========================================================

local infiniteJump = false

UserInputService.JumpRequest:Connect(function()

    if not infiniteJump then
        return
    end

    local character = player.Character

    if not character then
        return
    end

    local humanoid =
        character:FindFirstChildOfClass("Humanoid")

    if humanoid then

        humanoid:ChangeState(
            Enum.HumanoidStateType.Jumping
        )

    end

end)


-- =========================================================
-- NCCAM
-- =========================================================

local ncCam = false

local originalCameraOcclusionMode =
    player.DevCameraOcclusionMode


-- =========================================================
-- MAXZOOM
-- =========================================================

local maxZoom = false

local originalCameraMaxZoom =
    player.CameraMaxZoomDistance

local originalCameraMinZoom =
    player.CameraMinZoomDistance

local originalCameraMode =
    player.CameraMode


-- =========================================================
-- FB
-- =========================================================

local FB = false

local originalLighting = {
    Brightness = Lighting.Brightness,
    ClockTime = Lighting.ClockTime,
    FogEnd = Lighting.FogEnd,
    GlobalShadows = Lighting.GlobalShadows,
    Ambient = Lighting.Ambient,
    OutdoorAmbient = Lighting.OutdoorAmbient
}


-- =========================================================
-- FLOAT
-- =========================================================

local floatEnabled = false
local floatHeight = 0
local floatPlatform = nil
local floatCharacterConnection = nil

local FLOAT_STEP = 3
local FLOAT_PLATFORM_SIZE = Vector3.new(6, 1, 6)

local FloatControls = Instance.new("Frame")

FloatControls.Name = "FloatControls"
FloatControls.Size = UDim2.new(0, 42, 0, 88)

-- Float itself is unchanged
FloatControls.Position = UDim2.new(1, -55, 0.55, -105)

FloatControls.BackgroundTransparency = 1
FloatControls.Visible = false
FloatControls.Active = true
FloatControls.Parent = ScreenGui

local function makeFloatControl(text, y)

    local button = Instance.new("TextButton")

    button.Size = UDim2.new(0, 42, 0, 38)
    button.Position = UDim2.new(0, 0, 0, y)
    button.BackgroundColor3 =
        Color3.fromRGB(35, 35, 35)

    button.Text = text
    button.TextColor3 = Color3.new(1, 1, 1)
    button.Font = Enum.Font.SourceSansBold
    button.TextSize = 22
    button.AutoButtonColor = false
    button.Active = true
    button.Parent = FloatControls

    Instance.new("UICorner", button).CornerRadius =
        UDim.new(0, 8)

    return button
end

local FloatUpBtn = makeFloatControl("▲", 0)
local FloatDownBtn = makeFloatControl("▼", 48)

local function destroyFloatPlatform()

    if floatPlatform then
        floatPlatform:Destroy()
        floatPlatform = nil
    end

end

local function createFloatPlatform()

    destroyFloatPlatform()

    local character = player.Character

    if not character then
        return
    end

    local root =
        character:FindFirstChild("HumanoidRootPart")

    if not root then
        return
    end

    floatHeight =
        root.Position.Y - 3

    local platform =
        Instance.new("Part")

    platform.Name = "VGD_FloatPlatform"
    platform.Size = FLOAT_PLATFORM_SIZE
    platform.Transparency = 1
    platform.Anchored = true
    platform.CanCollide = true
    platform.CanTouch = false
    platform.CanQuery = false

    platform.CFrame =
        CFrame.new(
            root.Position.X,
            floatHeight,
            root.Position.Z
        )

    platform.Parent = workspace
    floatPlatform = platform

end

local function getSafeFloatMovement(amount)

    if not floatPlatform
        or not floatPlatform.Parent then

        return 0

    end

    local character = player.Character

    if not character then
        return 0
    end

    local root =
        character:FindFirstChild("HumanoidRootPart")

    if not root then
        return 0
    end

    if amount == 0 then
        return 0
    end

    local movement =
        Vector3.new(0, amount, 0)

    local rayParams = RaycastParams.new()

    rayParams.FilterType =
        Enum.RaycastFilterType.Exclude

    rayParams.FilterDescendantsInstances = {
        character,
        floatPlatform
    }

    rayParams.IgnoreWater = true

    local characterCFrame
    local characterSize

    characterCFrame,
    characterSize =
        character:GetBoundingBox()

    local characterHit =
        workspace:Blockcast(
            characterCFrame,
            characterSize,
            movement,
            rayParams
        )

    local platformHit =
        workspace:Blockcast(
            floatPlatform.CFrame,
            floatPlatform.Size,
            movement,
            rayParams
        )

    local closestDistance =
        math.abs(amount)

    local hitFound = false

    if characterHit then

        hitFound = true

        if characterHit.Distance <
            closestDistance then

            closestDistance =
                characterHit.Distance

        end

    end

    if platformHit then

        hitFound = true

        if platformHit.Distance <
            closestDistance then

            closestDistance =
                platformHit.Distance

        end

    end

    if not hitFound then
        return amount
    end

    local SAFE_MARGIN = 0.05

    local safeDistance =
        math.max(
            0,
            closestDistance -
                SAFE_MARGIN
        )

    if amount > 0 then
        return safeDistance
    else
        return -safeDistance
    end

end

local function setFloatHeight(amount)

    if not floatEnabled then
        return
    end

    if not floatPlatform
        or not floatPlatform.Parent then

        return

    end

    local safeMovement =
        getSafeFloatMovement(amount)

    if safeMovement == 0 then
        return
    end

    floatHeight =
        floatHeight +
        safeMovement

    local currentPosition =
        floatPlatform.Position

    floatPlatform.CFrame =
        CFrame.new(
            currentPosition.X,
            floatHeight,
            currentPosition.Z
        )

end

local function enableFloat()

    floatEnabled = true

    createFloatPlatform()
    FloatControls.Visible = true

    if floatCharacterConnection then

        floatCharacterConnection:Disconnect()
        floatCharacterConnection = nil

    end

    floatCharacterConnection =
        player.CharacterAdded:Connect(
            function()

                if not floatEnabled then
                    return
                end

                task.wait(0.2)

                createFloatPlatform()
                FloatControls.Visible = true

            end
        )

end

local function disableFloat()

    floatEnabled = false

    destroyFloatPlatform()
    FloatControls.Visible = false

    if floatCharacterConnection then

        floatCharacterConnection:Disconnect()
        floatCharacterConnection = nil

    end

end

FloatUpBtn.Activated:Connect(function()

    if floatEnabled then
        setFloatHeight(FLOAT_STEP)
    end

end)

FloatDownBtn.Activated:Connect(function()

    if floatEnabled then
        setFloatHeight(-FLOAT_STEP)
    end

end)

local floatDragging = false
local floatDragStart
local floatStartPosition
local floatDragInput

FloatControls.InputBegan:Connect(function(input)

    if input.UserInputType ==
        Enum.UserInputType.MouseButton1
        or input.UserInputType ==
        Enum.UserInputType.Touch then

        floatDragging = true
        floatDragInput = input
        floatDragStart = input.Position
        floatStartPosition =
            FloatControls.Position

    end

end)

UserInputService.InputChanged:Connect(function(input)

    if not floatDragging then
        return
    end

    if input ~= floatDragInput then
        return
    end

    if input.UserInputType ==
        Enum.UserInputType.MouseMovement
        or input.UserInputType ==
        Enum.UserInputType.Touch then

        local delta =
            input.Position -
            floatDragStart

        FloatControls.Position =
            UDim2.new(
                floatStartPosition.X.Scale,
                floatStartPosition.X.Offset +
                    delta.X,
                floatStartPosition.Y.Scale,
                floatStartPosition.Y.Offset +
                    delta.Y
            )

    end

end)

UserInputService.InputEnded:Connect(function(input)

    if input == floatDragInput then

        floatDragging = false
        floatDragInput = nil

    end

end)


-- =========================================================
-- 🛡️ BARRIER
-- =========================================================

local barrierEnabled = false
local barrierFolder = nil

local BARRIER_DISTANCE = 6
local BARRIER_HEIGHT = 9
local BARRIER_WIDTH = 14
local BARRIER_THICKNESS = 1.5

local BARRIER_RECOVERY_MARGIN = 0.35
local BARRIER_RECOVERY_INTERVAL = 0.03

local lastBarrierRecovery = 0

local function destroyBarrier()

    if barrierFolder then
        barrierFolder:Destroy()
        barrierFolder = nil
    end

end

local function createBarrier()

    destroyBarrier()

    local folder = Instance.new("Folder")
    folder.Name = "VGD_Barrier"
    folder.Parent = workspace
    barrierFolder = folder

    local function makeWall(name, size)

        local part = Instance.new("Part")

        part.Name = name
        part.Size = size
        part.Transparency = 1
        part.Anchored = true
        part.CanCollide = true
        part.CanTouch = false
        part.CanQuery = false
        part.CastShadow = false
        part.Parent = folder

        return part

    end

    makeWall(
        "Front",
        Vector3.new(
            BARRIER_WIDTH,
            BARRIER_HEIGHT,
            BARRIER_THICKNESS
        )
    )

    makeWall(
        "Back",
        Vector3.new(
            BARRIER_WIDTH,
            BARRIER_HEIGHT,
            BARRIER_THICKNESS
        )
    )

    makeWall(
        "Left",
        Vector3.new(
            BARRIER_THICKNESS,
            BARRIER_HEIGHT,
            BARRIER_WIDTH
        )
    )

    makeWall(
        "Right",
        Vector3.new(
            BARRIER_THICKNESS,
            BARRIER_HEIGHT,
            BARRIER_WIDTH
        )
    )

    makeWall(
        "Top",
        Vector3.new(
            BARRIER_WIDTH,
            BARRIER_THICKNESS,
            BARRIER_WIDTH
        )
    )

    makeWall(
        "Bottom",
        Vector3.new(
            BARRIER_WIDTH,
            BARRIER_THICKNESS,
            BARRIER_WIDTH
        )
    )

    return folder

end

local function updateBarrier()

    if not barrierEnabled then
        return
    end

    if not barrierFolder
        or not barrierFolder.Parent then

        createBarrier()

    end

    local character = player.Character

    if not character then
        return
    end

    local root =
        character:FindFirstChild("HumanoidRootPart")

    if not root then
        return
    end

    local center = root.Position
    local halfHeight = BARRIER_HEIGHT / 2

    local front = barrierFolder:FindFirstChild("Front")
    local back = barrierFolder:FindFirstChild("Back")
    local left = barrierFolder:FindFirstChild("Left")
    local right = barrierFolder:FindFirstChild("Right")
    local top = barrierFolder:FindFirstChild("Top")
    local bottom = barrierFolder:FindFirstChild("Bottom")

    if front then

        front.CFrame =
            CFrame.new(
                center.X,
                center.Y,
                center.Z -
                    BARRIER_DISTANCE
            )

    end

    if back then

        back.CFrame =
            CFrame.new(
                center.X,
                center.Y,
                center.Z +
                    BARRIER_DISTANCE
            )

    end

    if left then

        left.CFrame =
            CFrame.new(
                center.X -
                    BARRIER_DISTANCE,
                center.Y,
                center.Z
            )

    end

    if right then

        right.CFrame =
            CFrame.new(
                center.X +
                    BARRIER_DISTANCE,
                center.Y,
                center.Z
            )

    end

    if top then

        top.CFrame =
            CFrame.new(
                center.X,
                center.Y +
                    halfHeight,
                center.Z
            )

    end

    if bottom then

        bottom.CFrame =
            CFrame.new(
                center.X,
                center.Y -
                    halfHeight,
                center.Z
            )

    end

end

local function shouldIgnoreBarrierPart(
    part,
    character
)

    if not part
        or not part:IsA("BasePart") then

        return true

    end

    if not part.Parent then
        return true
    end

    if character
        and part:IsDescendantOf(character) then

        return true

    end

    if barrierFolder
        and part:IsDescendantOf(barrierFolder) then

        return true

    end

    if part.Anchored then
        return true
    end

    local model =
        part:FindFirstAncestorOfClass("Model")

    if model
        and model:FindFirstChildOfClass("Humanoid") then

        return true

    end

    return false

end

local function getBarrierAssemblyParts(
    assemblyRoot
)

    local parts = {}

    if not assemblyRoot
        or not assemblyRoot.Parent then

        return parts

    end

    pcall(function()

        parts =
            assemblyRoot:GetConnectedParts(true)

    end)

    if #parts == 0 then
        parts = { assemblyRoot }
    end

    return parts

end

local function getAssemblyBounds(
    assemblyRoot
)

    local parts =
        getBarrierAssemblyParts(
            assemblyRoot
        )

    local minX = math.huge
    local minY = math.huge
    local minZ = math.huge

    local maxX = -math.huge
    local maxY = -math.huge
    local maxZ = -math.huge

    local found = false

    for _, part in ipairs(parts) do

        if part
            and part.Parent
            and part:IsA("BasePart") then

            local cf = part.CFrame
            local half = part.Size / 2

            local rightVector = cf.RightVector
            local upVector = cf.UpVector
            local lookVector = cf.LookVector

            local worldHalf =
                Vector3.new(
                    math.abs(rightVector.X) *
                        half.X +
                    math.abs(upVector.X) *
                        half.Y +
                    math.abs(lookVector.X) *
                        half.Z,

                    math.abs(rightVector.Y) *
                        half.X +
                    math.abs(upVector.Y) *
                        half.Y +
                    math.abs(lookVector.Y) *
                        half.Z,

                    math.abs(rightVector.Z) *
                        half.X +
                    math.abs(upVector.Z) *
                        half.Y +
                    math.abs(lookVector.Z) *
                        half.Z
                )

            local position = part.Position

            minX =
                math.min(
                    minX,
                    position.X -
                        worldHalf.X
                )

            minY =
                math.min(
                    minY,
                    position.Y -
                        worldHalf.Y
                )

            minZ =
                math.min(
                    minZ,
                    position.Z -
                        worldHalf.Z
                )

            maxX =
                math.max(
                    maxX,
                    position.X +
                        worldHalf.X
                )

            maxY =
                math.max(
                    maxY,
                    position.Y +
                        worldHalf.Y
                )

            maxZ =
                math.max(
                    maxZ,
                    position.Z +
                        worldHalf.Z
                )

            found = true

        end

    end

    if not found then
        return nil
    end

    return {
        minX = minX,
        minY = minY,
        minZ = minZ,

        maxX = maxX,
        maxY = maxY,
        maxZ = maxZ,

        center =
            Vector3.new(
                (minX + maxX) / 2,
                (minY + maxY) / 2,
                (minZ + maxZ) / 2
            )
    }

end

local function recoverBarrierAssembly(
    assemblyRoot,
    playerRoot
)

    if not assemblyRoot
        or not assemblyRoot.Parent then

        return

    end

    if assemblyRoot.Anchored then
        return
    end

    local bounds =
        getAssemblyBounds(
            assemblyRoot
        )

    if not bounds then
        return
    end

    local center = playerRoot.Position
    local objectCenter = bounds.center

    local relative =
        objectCenter -
        center

    local halfX =
        (bounds.maxX -
            bounds.minX) / 2

    local halfZ =
        (bounds.maxZ -
            bounds.minZ) / 2

    local requiredDistanceX =
        BARRIER_DISTANCE +
        BARRIER_THICKNESS / 2 +
        halfX +
        BARRIER_RECOVERY_MARGIN

    local requiredDistanceZ =
        BARRIER_DISTANCE +
        BARRIER_THICKNESS / 2 +
        halfZ +
        BARRIER_RECOVERY_MARGIN

    local penetrationX =
        requiredDistanceX -
        math.abs(relative.X)

    local penetrationZ =
        requiredDistanceZ -
        math.abs(relative.Z)

    local pushVector =
        Vector3.zero

    if penetrationX > 0
        or penetrationZ > 0 then

        if penetrationX < penetrationZ then

            if relative.X >= 0 then

                pushVector =
                    Vector3.new(
                        penetrationX,
                        0,
                        0
                    )

            else

                pushVector =
                    Vector3.new(
                        -penetrationX,
                        0,
                        0
                    )

            end

        else

            if relative.Z >= 0 then

                pushVector =
                    Vector3.new(
                        0,
                        0,
                        penetrationZ
                    )

            else

                pushVector =
                    Vector3.new(
                        0,
                        0,
                        -penetrationZ
                    )

            end

        end

    end

    if pushVector.Magnitude <= 0 then
        return
    end

    local currentCFrame =
        assemblyRoot.CFrame

    local rotation =
        currentCFrame -
        currentCFrame.Position

    local targetPosition =
        assemblyRoot.Position +
        pushVector

    pcall(function()

        assemblyRoot.CFrame =
            CFrame.new(targetPosition) *
            rotation

    end)

end

local function updateBarrierRecovery()

    if not barrierEnabled then
        return
    end

    local character =
        player.Character

    if not character then
        return
    end

    local root =
        character:FindFirstChild("HumanoidRootPart")

    if not root then
        return
    end

    local now = os.clock()

    if now -
        lastBarrierRecovery <
        BARRIER_RECOVERY_INTERVAL then

        return

    end

    lastBarrierRecovery = now

    local searchDistance =
        BARRIER_DISTANCE +
        BARRIER_WIDTH / 2 +
        8

    local searchHeight =
        BARRIER_HEIGHT + 8

    local overlapParams =
        OverlapParams.new()

    overlapParams.FilterType =
        Enum.RaycastFilterType.Exclude

    overlapParams.FilterDescendantsInstances = {
        character,
        barrierFolder
    }

    overlapParams.MaxParts = 150

    local nearbyParts

    pcall(function()

        nearbyParts =
            workspace:GetPartBoundsInBox(
                CFrame.new(root.Position),
                Vector3.new(
                    searchDistance * 2,
                    searchHeight,
                    searchDistance * 2
                ),
                overlapParams
            )

    end)

    if not nearbyParts then
        return
    end

    local assemblies = {}

    for _, part in ipairs(nearbyParts) do

        if not shouldIgnoreBarrierPart(
            part,
            character
        ) then

            local assemblyRoot =
                part.AssemblyRootPart

            if assemblyRoot
                and not assemblyRoot.Anchored then

                assemblies[assemblyRoot] = true

            end

        end

    end

    for assemblyRoot in pairs(assemblies) do

        recoverBarrierAssembly(
            assemblyRoot,
            root
        )

    end

end

local function enableBarrier()

    if barrierEnabled then
        return
    end

    barrierEnabled = true
    lastBarrierRecovery = 0

    createBarrier()
    updateBarrier()

end

local function disableBarrier()

    barrierEnabled = false
    lastBarrierRecovery = 0

    destroyBarrier()

end


-- =========================================================
-- 🚫 ANTIFLING
-- =========================================================

local antiFling = false

local antiFlingConnections = {}
local antiFlingPlayerConnections = {}

local antiFlingStoredParts = {}
local antiFlingTrackedAssemblies = {}
local antiFlingNoCollisionPairs = {}

local ANTI_FLING_CHARACTER_GROUP =
    "VGD_AntiFlingCharacter"

local ANTI_FLING_PART_GROUP =
    "VGD_AntiFlingParts"

local antiFlingOriginalCollisionGroups = {}
local antiFlingPartConnections = {}
local antiFlingCharacterParts = {}

local antiFlingGlobalScanCounter = 0

local ANTI_FLING_RADIUS = 14
local ANTI_FLING_HEIGHT = 16
local ANTI_FLING_SCAN_INTERVAL = 0.03
local ANTI_FLING_MAX_PARTS = 300

local ANTI_FLING_MAX_HORIZONTAL_VELOCITY = 100
local ANTI_FLING_MAX_ANGULAR_VELOCITY = 60
local ANTI_FLING_MAX_POSITION_DELTA = 15

local lastAntiFlingScan = 0
local antiFlingLastSafeCFrame = nil
local antiFlingLastRootPosition = nil


-- =========================================================
-- NDS HAZARD PROTECTION
-- =========================================================

local antiFlingHazardConnections = {}
local antiFlingHazardProtection = false

local antiFlingNDSHazards = {}
local antiFlingNDSPartConnections = {}
local antiFlingNDSHazardConnections = {}
local antiFlingNDSPartStates = {}


-- =========================================================
-- NDS NAME CHECKS
-- =========================================================

local function isNDSMeteor(instance)

    return instance
        and instance.Name == "MeteorTemplate"

end

local function isNDSLava(instance)

    return instance
        and instance.Name == "Lava"

end

local function isNDSAvalanche(instance)

    return instance
        and instance.Name == "AvalanchePart"

end


-- =========================================================
-- EXACT NDS HAZARD CHECK
-- =========================================================

local function isTargetNDSHazard(instance)

    if not instance
        or not instance.Parent then

        return false

    end

    local meteorFolder =
        workspace:FindFirstChild(
            "MeteorFolder"
        )

    if meteorFolder
        and instance.Parent == meteorFolder
        and isNDSMeteor(instance) then

        return true

    end

    local structure =
        workspace:FindFirstChild(
            "Structure"
        )

    if structure
        and instance.Parent == structure then

        if isNDSLava(instance)
            or isNDSAvalanche(instance) then

            return true

        end

    end

    return false

end


-- =========================================================
-- FIND DIRECT NDS HAZARD FROM DESCENDANT
-- =========================================================

local function findNDSHazardFromDescendant(
    descendant
)

    if not descendant then
        return nil
    end

    local meteorFolder =
        workspace:FindFirstChild(
            "MeteorFolder"
        )

    if meteorFolder then

        local current = descendant

        while current
            and current ~= workspace do

            if current.Parent == meteorFolder
                and isNDSMeteor(current) then

                return current

            end

            current = current.Parent

        end

    end

    local structure =
        workspace:FindFirstChild(
            "Structure"
        )

    if structure then

        local current = descendant

        while current
            and current ~= workspace do

            if current.Parent == structure
                and (
                    isNDSLava(current)
                    or isNDSAvalanche(current)
                ) then

                return current

            end

            current = current.Parent

        end

    end

    return nil

end


-- =========================================================
-- NDS TOUCH TRANSMITTER REMOVAL
-- =========================================================

local function removeNDSTouchTransmitter(instance)

    if not instance
        or not instance.Parent then

        return

    end

    pcall(function()

        for _, child in ipairs(
            instance:GetChildren()
        ) do

            if child:IsA("TouchTransmitter") then

                child:Destroy()

            end

        end

    end)

end

local function removeAllNDSTouchTransmitters(
    instance
)

    if not instance
        or not instance.Parent then

        return

    end

    removeNDSTouchTransmitter(instance)

    pcall(function()

        for _, descendant in ipairs(
            instance:GetDescendants()
        ) do

            if descendant:IsA(
                "TouchTransmitter"
            ) then

                descendant:Destroy()

            end

        end

    end)

end


-- =========================================================
-- NDS PART NEUTRALIZATION
-- =========================================================

local function neutralizeNDSPart(part)

    if not antiFlingHazardProtection then
        return
    end

    if not part
        or not part.Parent
        or not part:IsA("BasePart") then

        return

    end

    if not antiFlingNDSPartStates[part] then

        antiFlingNDSPartStates[part] = {

            CanCollide = part.CanCollide,
            CanTouch = part.CanTouch,
            CanQuery = part.CanQuery

        }

    end

    pcall(function()

        part.CanCollide = false
        part.CanTouch = false
        part.CanQuery = false

    end)

    removeNDSTouchTransmitter(part)

    if not antiFlingNDSPartConnections[part] then

        local connections = {}

        table.insert(
            connections,

            part:GetPropertyChangedSignal(
                "CanCollide"
            ):Connect(
                function()

                    if not antiFlingHazardProtection then
                        return
                    end

                    if part
                        and part.Parent
                        and part.CanCollide then

                        pcall(function()
                            part.CanCollide = false
                        end)

                    end

                end
            )
        )

        table.insert(
            connections,

            part:GetPropertyChangedSignal(
                "CanTouch"
            ):Connect(
                function()

                    if not antiFlingHazardProtection then
                        return
                    end

                    if part
                        and part.Parent
                        and part.CanTouch then

                        pcall(function()
                            part.CanTouch = false
                        end)

                    end

                end
            )
        )

        table.insert(
            connections,

            part:GetPropertyChangedSignal(
                "CanQuery"
            ):Connect(
                function()

                    if not antiFlingHazardProtection then
                        return
                    end

                    if part
                        and part.Parent
                        and part.CanQuery then

                        pcall(function()
                            part.CanQuery = false
                        end)

                    end

                end
            )
        )

        table.insert(
            connections,

            part.ChildAdded:Connect(
                function(child)

                    if not antiFlingHazardProtection then
                        return
                    end

                    if child:IsA(
                        "TouchTransmitter"
                    ) then

                        pcall(function()
                            child:Destroy()
                        end)

                    end

                end
            )
        )

        table.insert(
            connections,

            part.AncestryChanged:Connect(
                function()

                    if not antiFlingHazardProtection then
                        return
                    end

                    if part.Parent then

                        task.defer(function()

                            if antiFlingHazardProtection
                                and part.Parent then

                                neutralizeNDSPart(
                                    part
                                )

                            end

                        end)

                    end

                end
            )
        )

        antiFlingNDSPartConnections[part] =
            connections

    end

end


-- =========================================================
-- NDS HAZARD CHILD TRACKING
-- =========================================================

local function trackNDSHazard(hazard)

    if not antiFlingHazardProtection then
        return
    end

    if not hazard
        or not hazard.Parent then

        return

    end

    if not isTargetNDSHazard(hazard) then
        return
    end

    antiFlingNDSHazards[hazard] = true

    if hazard:IsA("BasePart") then

        neutralizeNDSPart(hazard)

    end

    pcall(function()

        for _, descendant in ipairs(
            hazard:GetDescendants()
        ) do

            if descendant:IsA("BasePart") then

                neutralizeNDSPart(
                    descendant
                )

            elseif descendant:IsA(
                "TouchTransmitter"
            ) then

                pcall(function()
                    descendant:Destroy()
                end)

            end

        end

    end)

    removeAllNDSTouchTransmitters(hazard)

    if not antiFlingNDSHazardConnections[
        hazard
    ] then

        local connections = {}

        table.insert(
            connections,

            hazard.DescendantAdded:Connect(
                function(descendant)

                    if not antiFlingHazardProtection then
                        return
                    end

                    if descendant:IsA("BasePart") then

                        neutralizeNDSPart(
                            descendant
                        )

                    elseif descendant:IsA(
                        "TouchTransmitter"
                    ) then

                        pcall(function()
                            descendant:Destroy()
                        end)

                    end

                end
            )
        )

        table.insert(
            connections,

            hazard.AncestryChanged:Connect(
                function()

                    if not antiFlingHazardProtection then
                        return
                    end

                    if hazard.Parent then

                        task.defer(function()

                            if antiFlingHazardProtection
                                and isTargetNDSHazard(
                                    hazard
                                ) then

                                trackNDSHazard(
                                    hazard
                                )

                            end

                        end)

                    else

                        antiFlingNDSHazards[
                            hazard
                        ] = nil

                    end

                end
            )
        )

        antiFlingNDSHazardConnections[
            hazard
        ] = connections

    end

end


-- =========================================================
-- PROCESS NDS HAZARD
-- =========================================================

local function processNDSHazard(instance)

    if not antiFlingHazardProtection then
        return
    end

    if not instance
        or not instance.Parent then

        return

    end

    if not isTargetNDSHazard(instance) then
        return
    end

    trackNDSHazard(instance)

end


-- =========================================================
-- PROCESS NEW NDS DESCENDANT
-- =========================================================

local function processNDSHazardDescendant(
    descendant
)

    if not antiFlingHazardProtection then
        return
    end

    if not descendant
        or not descendant.Parent then

        return

    end

    if isTargetNDSHazard(descendant) then

        processNDSHazard(descendant)
        return

    end

    local hazard =
        findNDSHazardFromDescendant(
            descendant
        )

    if hazard then

        if descendant:IsA("BasePart") then

            neutralizeNDSPart(
                descendant
            )

        elseif descendant:IsA(
            "TouchTransmitter"
        ) then

            pcall(function()
                descendant:Destroy()
            end)

        end

        trackNDSHazard(hazard)

    end

end


-- =========================================================
-- CLEAN NDS PART CONNECTIONS
-- =========================================================

local function clearNDSPartConnections()

    for part, connections in pairs(
        antiFlingNDSPartConnections
    ) do

        if connections then

            for _, connection in ipairs(
                connections
            ) do

                if connection then

                    pcall(function()
                        connection:Disconnect()
                    end)

                end

            end

        end

        antiFlingNDSPartConnections[
            part
        ] = nil

    end

end


-- =========================================================
-- CLEAN NDS HAZARD CONNECTIONS
-- =========================================================

local function clearNDSHazardConnections()

    for _, connection in ipairs(
        antiFlingHazardConnections
    ) do

        if connection then

            pcall(function()
                connection:Disconnect()
            end)

        end

    end

    table.clear(
        antiFlingHazardConnections
    )

    for hazard, connections in pairs(
        antiFlingNDSHazardConnections
    ) do

        if connections then

            for _, connection in ipairs(
                connections
            ) do

                if connection then

                    pcall(function()
                        connection:Disconnect()
                    end)

                end

            end

        end

        antiFlingNDSHazardConnections[
            hazard
        ] = nil

    end

    table.clear(
        antiFlingNDSHazards
    )

end


-- =========================================================
-- RESTORE NDS PARTS
-- =========================================================

local function restoreNDSParts()

    for part, state in pairs(
        antiFlingNDSPartStates
    ) do

        if part
            and part.Parent
            and state then

            pcall(function()

                part.CanCollide =
                    state.CanCollide

                part.CanTouch =
                    state.CanTouch

                part.CanQuery =
                    state.CanQuery

            end)

        end

    end

    table.clear(
        antiFlingNDSPartStates
    )

end


-- =========================================================
-- SCAN EXISTING NDS HAZARDS
-- =========================================================

local function scanExistingNDSHazards()

    if not antiFlingHazardProtection then
        return
    end

    local meteorFolder =
        workspace:FindFirstChild(
            "MeteorFolder"
        )

    if meteorFolder then

        for _, child in ipairs(
            meteorFolder:GetChildren()
        ) do

            if isNDSMeteor(child) then

                processNDSHazard(child)

            end

        end

    end

    local structure =
        workspace:FindFirstChild(
            "Structure"
        )

    if structure then

        for _, child in ipairs(
            structure:GetChildren()
        ) do

            if isNDSLava(child)
                or isNDSAvalanche(child) then

                processNDSHazard(child)

            end

        end

    end

end


-- =========================================================
-- RAPID NDS MAINTENANCE
-- =========================================================

local function maintainTrackedNDSHazards()

    if not antiFlingHazardProtection then
        return
    end

    for hazard in pairs(
        antiFlingNDSHazards
    ) do

        if not hazard
            or not hazard.Parent then

            antiFlingNDSHazards[
                hazard
            ] = nil

        elseif isTargetNDSHazard(hazard) then

            if hazard:IsA("BasePart") then

                neutralizeNDSPart(
                    hazard
                )

            end

            pcall(function()

                for _, descendant in ipairs(
                    hazard:GetDescendants()
                ) do

                    if descendant:IsA("BasePart") then

                        neutralizeNDSPart(
                            descendant
                        )

                    elseif descendant:IsA(
                        "TouchTransmitter"
                    ) then

                        pcall(function()
                            descendant:Destroy()
                        end)

                    end

                end

            end)

        else

            antiFlingNDSHazards[
                hazard
            ] = nil

        end

    end

end


-- =========================================================
-- START NDS HAZARD PROTECTION
-- =========================================================

local function startNDSHazardProtection()

    if antiFlingHazardProtection then
        return
    end

    antiFlingHazardProtection = true

    clearNDSHazardConnections()
    clearNDSPartConnections()


    -- =====================================================
    -- METEOR FOLDER
    -- =====================================================

    local meteorFolder =
        workspace:FindFirstChild(
            "MeteorFolder"
        )

    if meteorFolder then

        table.insert(
            antiFlingHazardConnections,

            meteorFolder.ChildAdded:Connect(
                function(child)

                    if not antiFlingHazardProtection then
                        return
                    end

                    if isNDSMeteor(child) then

                        processNDSHazard(
                            child
                        )

                    end

                end
            )
        )

        for _, child in ipairs(
            meteorFolder:GetChildren()
        ) do

            if isNDSMeteor(child) then

                processNDSHazard(
                    child
                )

            end

        end

    end


    -- =====================================================
    -- STRUCTURE
    -- =====================================================

    local structure =
        workspace:FindFirstChild(
            "Structure"
        )

    if structure then

        table.insert(
            antiFlingHazardConnections,

            structure.ChildAdded:Connect(
                function(child)

                    if not antiFlingHazardProtection then
                        return
                    end

                    if isNDSLava(child)
                        or isNDSAvalanche(child) then

                        processNDSHazard(
                            child
                        )

                    end

                end
            )
        )

        for _, child in ipairs(
            structure:GetChildren()
        ) do

            if isNDSLava(child)
                or isNDSAvalanche(child) then

                processNDSHazard(
                    child
                )

            end

        end

    end


    -- =====================================================
    -- GLOBAL DESCENDANT EVENT
    -- =====================================================

    table.insert(
        antiFlingHazardConnections,

        workspace.DescendantAdded:Connect(
            function(descendant)

                if not antiFlingHazardProtection then
                    return
                end

                processNDSHazardDescendant(
                    descendant
                )

            end
        )
    )


    -- =====================================================
    -- FOLDER CREATION WATCH
    -- =====================================================

    table.insert(
        antiFlingHazardConnections,

        workspace.ChildAdded:Connect(
            function(child)

                if not antiFlingHazardProtection then
                    return
                end

                if child.Name ==
                    "MeteorFolder" then

                    table.insert(
                        antiFlingHazardConnections,

                        child.ChildAdded:Connect(
                            function(hazard)

                                if not antiFlingHazardProtection then
                                    return
                                end

                                if isNDSMeteor(
                                    hazard
                                ) then

                                    processNDSHazard(
                                        hazard
                                    )

                                end

                            end
                        )
                    )

                    for _, hazard in ipairs(
                        child:GetChildren()
                    ) do

                        if isNDSMeteor(hazard) then

                            processNDSHazard(
                                hazard
                            )

                        end

                    end

                elseif child.Name ==
                    "Structure" then

                    table.insert(
                        antiFlingHazardConnections,

                        child.ChildAdded:Connect(
                            function(hazard)

                                if not antiFlingHazardProtection then
                                    return
                                end

                                if isNDSLava(
                                    hazard
                                )
                                    or isNDSAvalanche(
                                        hazard
                                    ) then

                                    processNDSHazard(
                                        hazard
                                    )

                                end

                            end
                        )
                    )

                    for _, hazard in ipairs(
                        child:GetChildren()
                    ) do

                        if isNDSLava(hazard)
                            or isNDSAvalanche(
                                hazard
                            ) then

                            processNDSHazard(
                                hazard
                            )

                        end

                    end

                end

            end
        )
    )


    -- =====================================================
    -- INITIAL SCAN
    -- =====================================================

    scanExistingNDSHazards()

end


-- =========================================================
-- STOP NDS HAZARD PROTECTION
-- =========================================================

local function stopNDSHazardProtection()

    antiFlingHazardProtection = false

    clearNDSHazardConnections()
    clearNDSPartConnections()
    restoreNDSParts()

end


-- =========================================================
-- COLLISION GROUP SETUP
-- =========================================================

local function setupAntiFlingCollisionGroups()

    pcall(function()

        if not PhysicsService:IsCollisionGroupRegistered(
            ANTI_FLING_CHARACTER_GROUP
        ) then

            PhysicsService:RegisterCollisionGroup(
                ANTI_FLING_CHARACTER_GROUP
            )

        end

    end)

    pcall(function()

        if not PhysicsService:IsCollisionGroupRegistered(
            ANTI_FLING_PART_GROUP
        ) then

            PhysicsService:RegisterCollisionGroup(
                ANTI_FLING_PART_GROUP
            )

        end

    end)

    pcall(function()

        PhysicsService:CollisionGroupSetCollidable(
            ANTI_FLING_CHARACTER_GROUP,
            ANTI_FLING_PART_GROUP,
            false
        )

    end)

end

local function restoreAntiFlingCollisionGroup(part)

    if not part then
        return
    end

    local originalGroup =
        antiFlingOriginalCollisionGroups[part]

    if originalGroup then

        if part.Parent then

            pcall(function()

                part.CollisionGroup =
                    originalGroup

            end)

        end

        antiFlingOriginalCollisionGroups[part] =
            nil

    end

    local connection =
        antiFlingPartConnections[part]

    if connection then

        pcall(function()
            connection:Disconnect()
        end)

        antiFlingPartConnections[part] =
            nil

    end

end

local function protectAntiFlingCollisionPart(part)

    if not antiFling then
        return
    end

    if not part
        or not part.Parent
        or not part:IsA("BasePart") then

        return

    end

    local character =
        player.Character

    if character
        and part:IsDescendantOf(character) then

        return

    end

    local model =
        part:FindFirstAncestorOfClass("Model")

    if model
        and model:FindFirstChildOfClass(
            "Humanoid"
        ) then

        return

    end

    if part.Anchored then

        if antiFlingOriginalCollisionGroups[part] then

            restoreAntiFlingCollisionGroup(
                part
            )

        end

        return

    end

    if not antiFlingOriginalCollisionGroups[part] then

        local originalGroup

        pcall(function()

            originalGroup =
                part.CollisionGroup

        end)

        if originalGroup then

            antiFlingOriginalCollisionGroups[part] =
                originalGroup

        end

    end

    pcall(function()

        part.CollisionGroup =
            ANTI_FLING_PART_GROUP

    end)

    if not antiFlingPartConnections[part] then

        antiFlingPartConnections[part] =
            part:GetPropertyChangedSignal(
                "Anchored"
            ):Connect(
                function()

                    if not antiFling then
                        return
                    end

                    if part
                        and part.Parent
                        and not part.Anchored then

                        protectAntiFlingCollisionPart(
                            part
                        )

                    else

                        restoreAntiFlingCollisionGroup(
                            part
                        )

                    end

                end
            )

    end

end

local function scanAllAntiFlingCollisionParts()

    if not antiFling then
        return
    end

    setupAntiFlingCollisionGroups()

    local descendants

    pcall(function()

        descendants =
            workspace:GetDescendants()

    end)

    if not descendants then
        return
    end

    for _, descendant in ipairs(
        descendants
    ) do

        if not antiFling then
            break
        end

        if descendant:IsA("BasePart") then

            protectAntiFlingCollisionPart(
                descendant
            )

        end

    end

end

local function protectAntiFlingCharacter()

    if not antiFling then
        return
    end

    local character =
        player.Character

    if not character then
        return
    end

    setupAntiFlingCollisionGroups()

    for _, part in ipairs(
        character:GetDescendants()
    ) do

        if part:IsA("BasePart") then

            if not antiFlingCharacterParts[part] then

                local originalGroup

                pcall(function()

                    originalGroup =
                        part.CollisionGroup

                end)

                antiFlingCharacterParts[part] =
                    originalGroup

            end

            pcall(function()

                part.CollisionGroup =
                    ANTI_FLING_CHARACTER_GROUP

            end)

        end

    end

end

local function restoreAntiFlingCharacter()

    for part, originalGroup in pairs(
        antiFlingCharacterParts
    ) do

        if part
            and part.Parent
            and originalGroup then

            pcall(function()

                part.CollisionGroup =
                    originalGroup

            end)

        end

    end

    table.clear(
        antiFlingCharacterParts
    )

end

local function restoreAllAntiFlingCollisionGroups()

    for part in pairs(
        antiFlingOriginalCollisionGroups
    ) do

        restoreAntiFlingCollisionGroup(
            part
        )

    end

    for part, connection in pairs(
        antiFlingPartConnections
    ) do

        if connection then

            pcall(function()
                connection:Disconnect()
            end)

        end

        antiFlingPartConnections[part] =
            nil

    end

    table.clear(
        antiFlingOriginalCollisionGroups
    )

    restoreAntiFlingCharacter()

end


-- =========================================================
-- SUPER RING PARTS V6 NO-FALL
-- =========================================================

local antiFlingNoFallConnection = nil

local function startAntiFlingNoFall()

    if antiFlingNoFallConnection then
        return
    end

    antiFlingNoFallConnection =
        RunService.Heartbeat:Connect(
            function()

                if not antiFling then
                    return
                end

                local character =
                    player.Character

                if not character then
                    return
                end

                local root =
                    character:FindFirstChild(
                        "HumanoidRootPart"
                    )

                if not root then
                    return
                end

                if not root.Parent then
                    return
                end

                local oldvel =
                    root.AssemblyLinearVelocity

                root.AssemblyLinearVelocity =
                    Vector3.zero

                RunService.RenderStepped:Wait()

                if not antiFling then
                    return
                end

                if not root
                    or not root.Parent then

                    return

                end

                root.AssemblyLinearVelocity =
                    oldvel

            end
        )

end

local function stopAntiFlingNoFall()

    if antiFlingNoFallConnection then

        antiFlingNoFallConnection:Disconnect()
        antiFlingNoFallConnection = nil

    end

end


-- =========================================================
-- CLEAR ANTIFLING CONNECTIONS
-- =========================================================

local function clearAntiFlingConnections()

    for _, connection in ipairs(
        antiFlingConnections
    ) do

        if connection then

            pcall(function()
                connection:Disconnect()
            end)

        end

    end

    table.clear(
        antiFlingConnections
    )

    for plr, connections in pairs(
        antiFlingPlayerConnections
    ) do

        if type(connections) == "table" then

            for _, connection in ipairs(
                connections
            ) do

                if connection then

                    pcall(function()
                        connection:Disconnect()
                    end)

                end

            end

        end

        antiFlingPlayerConnections[plr] =
            nil

    end

end

local function antiFlingIsCharacterModel(model)

    if not model then
        return false
    end

    return model:FindFirstChildOfClass(
        "Humanoid"
    ) ~= nil

end

local function getAntiFlingCharacterFromPart(part)

    if not part then
        return nil
    end

    local model =
        part:FindFirstAncestorOfClass(
            "Model"
        )

    if antiFlingIsCharacterModel(model) then
        return model
    end

    return nil

end

local function shouldIgnoreAntiFlingPart(
    part,
    character
)

    if not part
        or not part:IsA("BasePart") then

        return true

    end

    if not part.Parent then
        return true
    end

    if character
        and part:IsDescendantOf(character) then

        return true

    end

    local model =
        part:FindFirstAncestorOfClass(
            "Model"
        )

    if antiFlingIsCharacterModel(model) then
        return true
    end

    return false

end

local function isAntiFlingPartNearCharacter(
    part,
    character,
    root
)

    if not part
        or not part.Parent
        or not part:IsA("BasePart") then

        return false

    end

    if part.Anchored then
        return false
    end

    if shouldIgnoreAntiFlingPart(
        part,
        character
    ) then

        return false

    end

    if not root then
        return false
    end

    local offset =
        part.Position -
        root.Position

    local horizontalDistance =
        Vector3.new(
            offset.X,
            0,
            offset.Z
        ).Magnitude

    local verticalDistance =
        math.abs(offset.Y)

    return horizontalDistance <=
        ANTI_FLING_RADIUS
        and verticalDistance <=
        ANTI_FLING_HEIGHT / 2

end

local function storeAntiFlingPart(part)

    if not part
        or not part:IsA("BasePart") then

        return

    end

    if antiFlingStoredParts[part] then
        return
    end

    antiFlingStoredParts[part] = {

        CanCollide = part.CanCollide,
        CanTouch = part.CanTouch,
        CanQuery = part.CanQuery

    }

end

local function neutralizeAntiFlingPart(part)

    if not part
        or not part.Parent
        or not part:IsA("BasePart") then

        return

    end

    storeAntiFlingPart(part)

    pcall(function()

        part.CanCollide = false
        part.CanTouch = false
        part.CanQuery = false

    end)

    protectAntiFlingCollisionPart(part)

end

local function restoreAntiFlingPart(part)

    local saved =
        antiFlingStoredParts[part]

    if not saved then
        return
    end

    if part
        and part.Parent then

        pcall(function()

            part.CanCollide =
                saved.CanCollide

            part.CanTouch =
                saved.CanTouch

            part.CanQuery =
                saved.CanQuery

        end)

    end

    antiFlingStoredParts[part] =
        nil

end

local function restoreAllAntiFlingParts()

    for part in pairs(
        antiFlingStoredParts
    ) do

        restoreAntiFlingPart(part)

    end

    table.clear(
        antiFlingStoredParts
    )

    table.clear(
        antiFlingTrackedAssemblies
    )

end

local function destroyPlayerNoCollisionPair(
    character
)

    local pair =
        antiFlingNoCollisionPairs[
            character
        ]

    if not pair then
        return
    end

    if pair.connections then

        for _, connection in ipairs(
            pair.connections
        ) do

            if connection then

                pcall(function()
                    connection:Disconnect()
                end)

            end

        end

    end

    if pair.constraints then

        for _, constraint in ipairs(
            pair.constraints
        ) do

            if constraint then

                pcall(function()
                    constraint:Destroy()
                end)

            end

        end

    end

    antiFlingNoCollisionPairs[
        character
    ] = nil

end

local function removeAntiFlingNoCollision()

    for character in pairs(
        antiFlingNoCollisionPairs
    ) do

        destroyPlayerNoCollisionPair(
            character
        )

    end

    table.clear(
        antiFlingNoCollisionPairs
    )

end

local function createAntiFlingNoCollision(
    pair,
    part0,
    part1
)

    if not pair
        or not part0
        or not part1 then

        return

    end

    if not part0:IsA("BasePart")
        or not part1:IsA("BasePart") then

        return

    end

    if not part0.Parent
        or not part1.Parent then

        return

    end

    pair.seen[part0] =
        pair.seen[part0] or {}

    if pair.seen[part0][part1] then
        return
    end

    pair.seen[part0][part1] = true

    local constraint =
        Instance.new(
            "NoCollisionConstraint"
        )

    constraint.Name =
        "VGD_AntiFling_NoCollision"

    constraint.Part0 = part0
    constraint.Part1 = part1
    constraint.Parent = part0

    table.insert(
        pair.constraints,
        constraint
    )

end

local function addLocalPartToPair(
    pair,
    localPart,
    otherCharacter
)

    if not localPart
        or not localPart:IsA("BasePart") then

        return

    end

    if not localPart.Parent then
        return
    end

    for _, otherPart in ipairs(
        otherCharacter:GetDescendants()
    ) do

        if otherPart:IsA("BasePart") then

            createAntiFlingNoCollision(
                pair,
                localPart,
                otherPart
            )

        end

    end

end

local function addOtherPartToPair(
    pair,
    otherPart,
    localCharacter
)

    if not otherPart
        or not otherPart:IsA("BasePart") then

        return

    end

    if not otherPart.Parent then
        return

    end

    for _, localPart in ipairs(
        localCharacter:GetDescendants()
    ) do

        if localPart:IsA("BasePart") then

            createAntiFlingNoCollision(
                pair,
                localPart,
                otherPart
            )

        end

    end

end

local function ensurePlayerNoCollision(
    otherCharacter,
    localCharacter
)

    if not otherCharacter
        or not otherCharacter.Parent then

        return

    end

    if not localCharacter
        or not localCharacter.Parent then

        return

    end

    if otherCharacter == localCharacter then
        return
    end

    local existing =
        antiFlingNoCollisionPairs[
            otherCharacter
        ]

    if existing
        and existing.localCharacter ==
            localCharacter then

        return

    end

    if existing then

        destroyPlayerNoCollisionPair(
            otherCharacter
        )

    end

    local pair = {

        constraints = {},
        connections = {},
        seen = {},
        localCharacter = localCharacter

    }

    antiFlingNoCollisionPairs[
        otherCharacter
    ] = pair

    for _, localPart in ipairs(
        localCharacter:GetDescendants()
    ) do

        if localPart:IsA("BasePart") then

            for _, otherPart in ipairs(
                otherCharacter:GetDescendants()
            ) do

                if otherPart:IsA("BasePart") then

                    createAntiFlingNoCollision(
                        pair,
                        localPart,
                        otherPart
                    )

                end

            end

        end

    end

    table.insert(
        pair.connections,

        localCharacter.DescendantAdded:Connect(
            function(descendant)

                if not antiFling then
                    return
                end

                if descendant:IsA("BasePart") then

                    addLocalPartToPair(
                        pair,
                        descendant,
                        otherCharacter
                    )

                end

            end
        )
    )

    table.insert(
        pair.connections,

        otherCharacter.DescendantAdded:Connect(
            function(descendant)

                if not antiFling then
                    return
                end

                if descendant:IsA("BasePart") then

                    addOtherPartToPair(
                        pair,
                        descendant,
                        localCharacter
                    )

                end

            end
        )
    )

end

local function updatePlayerNoCollision()

    if not antiFling then
        return
    end

    local character =
        player.Character

    if not character then
        return
    end

    for _, otherPlayer in ipairs(
        Players:GetPlayers()
    ) do

        if otherPlayer ~= player then

            local otherCharacter =
                otherPlayer.Character

            if otherCharacter then

                ensurePlayerNoCollision(
                    otherCharacter,
                    character
                )

            end

        end

    end

end

local function neutralizeAntiFlingAssembly(
    root,
    character
)

    if not root
        or not root.Parent
        or not root:IsA("BasePart")
        or root.Anchored then

        return

    end

    local parts = {}

    pcall(function()

        parts =
            root:GetConnectedParts(true)

    end)

    if #parts == 0 then
        parts = { root }
    end

    local count = 0

    for _, part in ipairs(parts) do

        if count >= ANTI_FLING_MAX_PARTS then
            break
        end

        if part
            and part.Parent
            and part:IsA("BasePart")
            and not part.Anchored
            and not shouldIgnoreAntiFlingPart(
                part,
                character
            ) then

            local partCharacter =
                getAntiFlingCharacterFromPart(
                    part
                )

            if not partCharacter then

                neutralizeAntiFlingPart(
                    part
                )

                count =
                    count + 1

            end

        end

    end

    antiFlingTrackedAssemblies[root] =
        true

end

local function antiFlingNewPartCheck(part)

    if not antiFling then
        return
    end

    if not part
        or not part.Parent
        or not part:IsA("BasePart") then

        return

    end

    protectAntiFlingCollisionPart(part)

    if part.Anchored then
        return
    end

    local character =
        player.Character

    if not character then
        return
    end

    local root =
        character:FindFirstChild(
            "HumanoidRootPart"
        )

    if not root then
        return
    end

    if not isAntiFlingPartNearCharacter(
        part,
        character,
        root
    ) then

        return

    end

    local partCharacter =
        getAntiFlingCharacterFromPart(
            part
        )

    if partCharacter then
        return
    end

    local assemblyRoot =
        part.AssemblyRootPart

    if assemblyRoot
        and not assemblyRoot.Anchored then

        neutralizeAntiFlingAssembly(
            assemblyRoot,
            character
        )

    else

        neutralizeAntiFlingPart(part)

    end

end

local function protectLocalCharacter()

    if not antiFling then
        return
    end

    local character =
        player.Character

    if not character then
        return
    end

    protectAntiFlingCharacter()

    local root =
        character:FindFirstChild(
            "HumanoidRootPart"
        )

    if not root then
        return
    end

    local currentPosition =
        root.Position

    if antiFlingLastRootPosition then

        local delta =
            currentPosition -
            antiFlingLastRootPosition

        if delta.Magnitude >
            ANTI_FLING_MAX_POSITION_DELTA then

            if antiFlingLastSafeCFrame then

                pcall(function()

                    root.CFrame =
                        antiFlingLastSafeCFrame

                end)

                currentPosition =
                    root.Position

            end

        else

            antiFlingLastSafeCFrame =
                root.CFrame

        end

    else

        antiFlingLastSafeCFrame =
            root.CFrame

    end

    antiFlingLastRootPosition =
        currentPosition

    pcall(function()

        local velocity =
            root.AssemblyLinearVelocity

        local horizontal =
            Vector3.new(
                velocity.X,
                0,
                velocity.Z
            )

        if horizontal.Magnitude >
            ANTI_FLING_MAX_HORIZONTAL_VELOCITY then

            local safeHorizontal =
                horizontal.Unit *
                ANTI_FLING_MAX_HORIZONTAL_VELOCITY

            root.AssemblyLinearVelocity =
                Vector3.new(
                    safeHorizontal.X,
                    velocity.Y,
                    safeHorizontal.Z
                )

        end

    end)

    pcall(function()

        if root.AssemblyAngularVelocity.Magnitude >
            ANTI_FLING_MAX_ANGULAR_VELOCITY then

            root.AssemblyAngularVelocity =
                Vector3.zero

        end

    end)

end

local function scanAntiFlingParts()

    if not antiFling then
        return
    end

    local character =
        player.Character

    if not character then
        return
    end

    local root =
        character:FindFirstChild(
            "HumanoidRootPart"
        )

    if not root then
        return
    end

    local overlapParams =
        OverlapParams.new()

    overlapParams.FilterType =
        Enum.RaycastFilterType.Exclude

    overlapParams.FilterDescendantsInstances = {
        character
    }

    overlapParams.MaxParts =
        ANTI_FLING_MAX_PARTS

    local nearbyParts

    pcall(function()

        nearbyParts =
            workspace:GetPartBoundsInBox(
                CFrame.new(root.Position),
                Vector3.new(
                    ANTI_FLING_RADIUS * 2,
                    ANTI_FLING_HEIGHT,
                    ANTI_FLING_RADIUS * 2
                ),
                overlapParams
            )

    end)

    if not nearbyParts then
        return
    end

    local assemblies = {}

    for _, part in ipairs(
        nearbyParts
    ) do

        if part
            and part.Parent
            and part:IsA("BasePart")
            and not part.Anchored
            and not shouldIgnoreAntiFlingPart(
                part,
                character
            ) then

            local partCharacter =
                getAntiFlingCharacterFromPart(
                    part
                )

            if not partCharacter then

                protectAntiFlingCollisionPart(
                    part
                )

                local assemblyRoot =
                    part.AssemblyRootPart

                if assemblyRoot
                    and not assemblyRoot.Anchored then

                    assemblies[assemblyRoot] =
                        true

                end

            end

        end

    end

    for assemblyRoot in pairs(
        assemblies
    ) do

        neutralizeAntiFlingAssembly(
            assemblyRoot,
            character
        )

    end

end

local function recheckTrackedAntiFlingAssemblies()

    if not antiFling then
        return
    end

    local character =
        player.Character

    if not character then
        return
    end

    local root =
        character:FindFirstChild(
            "HumanoidRootPart"
        )

    if not root then
        return
    end

    for assemblyRoot in pairs(
        antiFlingTrackedAssemblies
    ) do

        if not assemblyRoot
            or not assemblyRoot.Parent then

            antiFlingTrackedAssemblies[
                assemblyRoot
            ] = nil

        elseif assemblyRoot.Anchored then

            antiFlingTrackedAssemblies[
                assemblyRoot
            ] = nil

        else

            local parts = {}

            pcall(function()

                parts =
                    assemblyRoot:GetConnectedParts(
                        true
                    )

            end)

            for _, part in ipairs(parts) do

                if part
                    and part.Parent
                    and part:IsA("BasePart")
                    and not part.Anchored then

                    protectAntiFlingCollisionPart(
                        part
                    )

                end

            end

            local distance =
                (
                    assemblyRoot.Position -
                    root.Position
                ).Magnitude

            if distance <=
                ANTI_FLING_RADIUS + 3 then

                neutralizeAntiFlingAssembly(
                    assemblyRoot,
                    character
                )

            else

                antiFlingTrackedAssemblies[
                    assemblyRoot
                ] = nil

            end

        end

    end

end

local function maintainAntiFlingCollisionShield()

    if not antiFling then
        return
    end

    antiFlingGlobalScanCounter =
        antiFlingGlobalScanCounter + 1

    if antiFlingGlobalScanCounter >= 8 then

        antiFlingGlobalScanCounter = 0

        scanAllAntiFlingCollisionParts()

    end

    protectAntiFlingCharacter()

end

local function updateAntiFling()

    if not antiFling then
        return
    end

    local character =
        player.Character

    if not character then
        return
    end

    local root =
        character:FindFirstChild(
            "HumanoidRootPart"
        )

    if not root then
        return
    end

    protectLocalCharacter()

    maintainAntiFlingCollisionShield()

    updatePlayerNoCollision()

    maintainTrackedNDSHazards()

    local now = os.clock()

    if now -
        lastAntiFlingScan <
        ANTI_FLING_SCAN_INTERVAL then

        return

    end

    lastAntiFlingScan = now

    scanAntiFlingParts()
    recheckTrackedAntiFlingAssemblies()

end


-- =========================================================
-- ENABLE ANTIFLING
-- =========================================================

local function enableAntiFling()

    if antiFling then
        return
    end

    antiFling = true

    lastAntiFlingScan = 0
    antiFlingLastSafeCFrame = nil
    antiFlingLastRootPosition = nil
    antiFlingGlobalScanCounter = 0

    table.clear(
        antiFlingTrackedAssemblies
    )

    setupAntiFlingCollisionGroups()

    startNDSHazardProtection()

    startAntiFlingNoFall()

    task.spawn(function()

        if antiFling then

            scanAllAntiFlingCollisionParts()
            protectAntiFlingCharacter()

        end

    end)

    table.insert(
        antiFlingConnections,

        player.CharacterAdded:Connect(
            function()

                if not antiFling then
                    return
                end

                antiFlingLastSafeCFrame = nil
                antiFlingLastRootPosition = nil

                restoreAntiFlingCharacter()
                removeAntiFlingNoCollision()

                task.wait(0.2)

                if antiFling then

                    lastAntiFlingScan = 0

                    protectAntiFlingCharacter()
                    updatePlayerNoCollision()

                end

            end
        )
    )

    table.insert(
        antiFlingConnections,

        workspace.DescendantAdded:Connect(
            function(descendant)

                if not antiFling then
                    return
                end

                if not descendant:IsA("BasePart") then
                    return
                end

                task.defer(function()

                    if not antiFling then
                        return
                    end

                    antiFlingNewPartCheck(
                        descendant
                    )

                end)

            end
        )
    )

    for _, otherPlayer in ipairs(
        Players:GetPlayers()
    ) do

        if otherPlayer ~= player then

            local connections = {}

            table.insert(
                connections,

                otherPlayer.CharacterAdded:Connect(
                    function(newCharacter)

                        if not antiFling then
                            return
                        end

                        task.wait(0.15)

                        if antiFling
                            and newCharacter
                            and player.Character then

                            ensurePlayerNoCollision(
                                newCharacter,
                                player.Character
                            )

                        end

                    end
                )
            )

            table.insert(
                connections,

                otherPlayer.CharacterRemoving:Connect(
                    function(oldCharacter)

                        destroyPlayerNoCollisionPair(
                            oldCharacter
                        )

                    end
                )
            )

            table.insert(
                connections,

                otherPlayer.AncestryChanged:Connect(
                    function(_, parent)

                        if parent == nil then

                            if otherPlayer.Character then

                                destroyPlayerNoCollisionPair(
                                    otherPlayer.Character
                                )

                            end

                        end

                    end
                )
            )

            antiFlingPlayerConnections[
                otherPlayer
            ] = connections

            if otherPlayer.Character
                and player.Character then

                ensurePlayerNoCollision(
                    otherPlayer.Character,
                    player.Character
                )

            end

        end

    end

    table.insert(
        antiFlingConnections,

        Players.PlayerAdded:Connect(
            function(otherPlayer)

                if not antiFling then
                    return
                end

                local connections = {}

                table.insert(
                    connections,

                    otherPlayer.CharacterAdded:Connect(
                        function(newCharacter)

                            if not antiFling then
                                return
                            end

                            task.wait(0.15)

                            if antiFling
                                and newCharacter
                                and player.Character then

                                ensurePlayerNoCollision(
                                    newCharacter,
                                    player.Character
                                )

                            end

                        end
                    )
                )

                table.insert(
                    connections,

                    otherPlayer.CharacterRemoving:Connect(
                        function(oldCharacter)

                            destroyPlayerNoCollisionPair(
                                oldCharacter
                            )

                        end
                    )
                )

                table.insert(
                    connections,

                    otherPlayer.AncestryChanged:Connect(
                        function(_, parent)

                            if parent == nil then

                                if otherPlayer.Character then

                                    destroyPlayerNoCollisionPair(
                                        otherPlayer.Character
                                    )

                                end

                            end

                        end
                    )
                )

                antiFlingPlayerConnections[
                    otherPlayer
                ] = connections

                if otherPlayer.Character
                    and player.Character then

                    ensurePlayerNoCollision(
                        otherPlayer.Character,
                        player.Character
                    )

                end

            end
        )
    )

    updatePlayerNoCollision()
    protectAntiFlingCharacter()

    scanAllAntiFlingCollisionParts()
    scanAntiFlingParts()

    scanExistingNDSHazards()

end


-- =========================================================
-- DISABLE ANTIFLING
-- =========================================================

local function disableAntiFling()

    antiFling = false

    stopNDSHazardProtection()
    stopAntiFlingNoFall()

    clearAntiFlingConnections()

    removeAntiFlingNoCollision()

    restoreAllAntiFlingParts()

    restoreAllAntiFlingCollisionGroups()

    antiFlingLastSafeCFrame = nil
    antiFlingLastRootPosition = nil

    lastAntiFlingScan = 0
    antiFlingGlobalScanCounter = 0

end


-- =========================================================
-- 🟢 STANDALONE NFD
-- SUPER RING PARTS V6
-- =========================================================

local nfd = false
local nfdConnection = nil

local function startNFD()

    if nfdConnection then
        return
    end

    nfdConnection =
        RunService.Heartbeat:Connect(
            function()

                if not nfd then
                    return
                end

                local character =
                    player.Character

                if not character then
                    return
                end

                local root =
                    character:FindFirstChild(
                        "HumanoidRootPart"
                    )

                if not root then
                    return
                end

                if not root.Parent then
                    return
                end

                local oldvel =
                    root.AssemblyLinearVelocity

                root.AssemblyLinearVelocity =
                    Vector3.zero

                RunService.RenderStepped:Wait()

                if not nfd then
                    return
                end

                if not root
                    or not root.Parent then

                    return

                end

                root.AssemblyLinearVelocity =
                    oldvel

            end
        )

end

local function stopNFD()

    if nfdConnection then

        nfdConnection:Disconnect()
        nfdConnection = nil

    end

end


-- =========================================================
-- BARRIER + ANTIFLING UPDATE
-- =========================================================

RunService.RenderStepped:Connect(function()

    if barrierEnabled then

        updateBarrier()
        updateBarrierRecovery()

    end

    if antiFling then

        updateAntiFling()

    end

end)


-- =========================================================
-- VIEW
-- =========================================================

local viewingPlayer = nil
local viewCharacterConnection = nil

local function stopViewing()

    viewingPlayer = nil

    if viewCharacterConnection then

        viewCharacterConnection:Disconnect()
        viewCharacterConnection = nil

    end

    local character =
        player.Character

    if character then

        local humanoid =
            character:FindFirstChildOfClass(
                "Humanoid"
            )

        if humanoid then

            workspace.CurrentCamera.CameraSubject =
                humanoid

        end

    end

    StopViewBtn.BackgroundColor3 =
        DEFAULT_BTN_COLOR

    StopViewBtn.Text =
        "Stop Viewing"

end

local function viewPlayer(targetPlayer)

    if not targetPlayer
        or targetPlayer == player then

        return

    end

    if viewCharacterConnection then

        viewCharacterConnection:Disconnect()
        viewCharacterConnection = nil

    end

    viewingPlayer = targetPlayer

    local function spectateCharacter(
        character
    )

        if viewingPlayer ~= targetPlayer then
            return
        end

        if not character then
            return
        end

        local humanoid =
            character:FindFirstChildOfClass(
                "Humanoid"
            )

        if not humanoid then

            humanoid =
                character:WaitForChild(
                    "Humanoid",
                    5
                )

        end

        if humanoid
            and viewingPlayer == targetPlayer then

            workspace.CurrentCamera.CameraSubject =
                humanoid

        end

    end

    if targetPlayer.Character then

        spectateCharacter(
            targetPlayer.Character
        )

    end

    viewCharacterConnection =
        targetPlayer.CharacterAdded:Connect(
            function(newCharacter)

                if viewingPlayer ~= targetPlayer then
                    return
                end

                task.wait(0.1)

                spectateCharacter(
                    newCharacter
                )

            end
        )

    StopViewBtn.BackgroundColor3 =
        ACTIVE_BTN_COLOR

    StopViewBtn.Text =
        "Viewing: " ..
        targetPlayer.Name

end

AllBtn.MouseButton1Click:Connect(function()

    bringAll =
        not bringAll

    AllBtn.Text =
        bringAll
        and "All : ON"
        or "All : OFF"

    AllBtn.BackgroundColor3 =
        bringAll
        and ACTIVE_BTN_COLOR
        or DEFAULT_BTN_COLOR

end)

StopViewBtn.MouseButton1Click:Connect(function()

    stopViewing()
    refreshPlayers()

end)


local function setButtonStateForPlayer(
    plr,
    btn,
    on
)

    if btn and btn.Parent then

        btn.BackgroundColor3 =
            on
            and ACTIVE_BTN_COLOR
            or DEFAULT_BTN_COLOR

    end

end


-- =========================================================
-- ESP
-- =========================================================

local espEnabled = {
    highlight = false,
    names = false
}

local espBoxes = {}

local function updateESP()

    for _, plr in ipairs(
        Players:GetPlayers()
    ) do

        if plr ~= player
            and plr.Character
            and plr.Character:FindFirstChild(
                "HumanoidRootPart"
            ) then

            local hrp =
                plr.Character.HumanoidRootPart

            if espEnabled.highlight then

                if not espBoxes[plr] then

                    local box =
                        Instance.new(
                            "BoxHandleAdornment"
                        )

                    box.Adornee = hrp
                    box.Size = hrp.Size

                    box.Color3 =
                        Color3.fromRGB(
                            0,
                            255,
                            0
                        )

                    box.AlwaysOnTop = true
                    box.ZIndex = 10
                    box.Parent = hrp

                    espBoxes[plr] =
                        box

                end

            else

                if espBoxes[plr] then

                    espBoxes[plr]:Destroy()
                    espBoxes[plr] = nil

                end

            end

            if espEnabled.names then

                if not hrp:FindFirstChild(
                    "ESP_Name"
                ) then

                    local billboard =
                        Instance.new(
                            "BillboardGui",
                            hrp
                        )

                    billboard.Name =
                        "ESP_Name"

                    billboard.Size =
                        UDim2.new(
                            0,
                            100,
                            0,
                            25
                        )

                    billboard.Adornee = hrp
                    billboard.AlwaysOnTop = true

                    local label =
                        Instance.new(
                            "TextLabel",
                            billboard
                        )

                    label.Text =
                        plr.Name

                    label.Size =
                        UDim2.new(
                            1,
                            0,
                            1,
                            0
                        )

                    label.BackgroundTransparency =
                        1

                    label.TextColor3 =
                        Color3.fromRGB(
                            0,
                            255,
                            0
                        )

                    label.Font =
                        Enum.Font.SourceSansBold

                    label.TextScaled = true

                end

            else

                local b =
                    hrp:FindFirstChild(
                        "ESP_Name"
                    )

                if b then
                    b:Destroy()
                end

            end

        end

    end

end


-- =========================================================
-- REFRESH PLAYERS
-- =========================================================

function refreshPlayers()

    PlayerList:ClearAllChildren()

    SearchBox.Visible =
        SelectedTab == "Bring"
        or SelectedTab == "TP to"
        or SelectedTab == "View"

    if SelectedTab == "View" then

        SearchBox.Visible = true
        AllButtonContainer.Visible = false
        StopViewContainer.Visible = true

        PlayerList.Size =
            UDim2.new(
                1,
                0,
                1,
                -78
            )

        PlayerList.Position =
            UDim2.new(
                0,
                0,
                0,
                78
            )

        local filterText =
            SearchBox.Text:lower()

        local y = 0
        local BOTTOM_GAP = 10

        local otherPlayers = {}

        for _, plr in ipairs(
            Players:GetPlayers()
        ) do

            if plr ~= player then

                table.insert(
                    otherPlayers,
                    plr
                )

            end

        end

        table.sort(
            otherPlayers,

            function(a, b)

                return a.Name:lower()
                    <
                    b.Name:lower()

            end
        )

        for _, plrRef in ipairs(
            otherPlayers
        ) do

            if plrRef.Name:lower():find(
                filterText
            ) then

                local Btn =
                    Instance.new(
                        "TextButton",
                        PlayerList
                    )

                Btn.Size =
                    UDim2.new(
                        1,
                        -6,
                        0,
                        28
                    )

                Btn.Position =
                    UDim2.new(
                        0,
                        6,
                        0,
                        y
                    )

                Btn.Text =
                    plrRef.Name

                Btn.Font =
                    Enum.Font.SourceSansBold

                Btn.TextSize = 16

                Btn.TextColor3 =
                    Color3.new(
                        1,
                        1,
                        1
                    )

                Btn.BackgroundColor3 =
                    viewingPlayer == plrRef
                    and ACTIVE_BTN_COLOR
                    or DEFAULT_BTN_COLOR

                Btn.MouseButton1Click:Connect(
                    function()

                        if viewingPlayer ==
                            plrRef then

                            stopViewing()

                        else

                            viewPlayer(
                                plrRef
                            )

                        end

                        refreshPlayers()

                    end
                )

                y =
                    y + 28

            end

        end

        PlayerList.CanvasSize =
            UDim2.new(
                0,
                0,
                0,
                y + BOTTOM_GAP
            )

        return

    end

    if SelectedTab == "ESP" then

        SearchBox.Visible = false
        AllButtonContainer.Visible = false
        StopViewContainer.Visible = false

        PlayerList.Size =
            UDim2.new(
                1,
                0,
                1,
                -8
            )

        PlayerList.Position =
            UDim2.new(
                0,
                0,
                0,
                8
            )

        local function makeToggle(
            text,
            yPos,
            varName
        )

            local Btn =
                Instance.new(
                    "TextButton",
                    PlayerList
                )

            Btn.Size =
                UDim2.new(
                    1,
                    -12,
                    0,
                    28
                )

            Btn.Position =
                UDim2.new(
                    0,
                    6,
                    0,
                    yPos
                )

            Btn.Text =
                text ..
                " : " ..
                (
                    espEnabled[varName]
                    and "ON"
                    or "OFF"
                )

            Btn.Font =
                Enum.Font.SourceSansBold

            Btn.TextSize = 16

            Btn.TextColor3 =
                Color3.new(
                    1,
                    1,
                    1
                )

            Btn.BackgroundColor3 =
                espEnabled[varName]
                and ACTIVE_BTN_COLOR
                or DEFAULT_BTN_COLOR

            Instance.new(
                "UICorner",
                Btn
            ).CornerRadius =
                UDim.new(
                    0,
                    8
                )

            Btn.MouseButton1Click:Connect(
                function()

                    espEnabled[varName] =
                        not espEnabled[varName]

                    Btn.Text =
                        text ..
                        " : " ..
                        (
                            espEnabled[varName]
                            and "ON"
                            or "OFF"
                        )

                    Btn.BackgroundColor3 =
                        espEnabled[varName]
                        and ACTIVE_BTN_COLOR
                        or DEFAULT_BTN_COLOR

                    updateESP()

                end
            )

        end

        makeToggle(
            "Highlight Players",
            8,
            "highlight"
        )

        makeToggle(
            "Show Names",
            48,
            "names"
        )

        PlayerList.CanvasSize =
            UDim2.new(
                0,
                0,
                0,
                88
            )

        return

    end


    -- =====================================================
    -- OTHERS
    -- =====================================================

    if SelectedTab == "Others" then

        SearchBox.Visible = false
        AllButtonContainer.Visible = false
        StopViewContainer.Visible = false

        PlayerList.Size =
            UDim2.new(
                1,
                0,
                1,
                -8
            )

        PlayerList.Position =
            UDim2.new(
                0,
                0,
                0,
                8
            )

        local FeatureRow =
            Instance.new(
                "Frame",
                PlayerList
            )

        FeatureRow.Size =
            UDim2.new(
                1,
                -12,
                0,
                274
            )

        FeatureRow.Position =
            UDim2.new(
                0,
                6,
                0,
                2
            )

        FeatureRow.BackgroundTransparency =
            1

        local function createFeatureButton(
            text,
            xScale,
            xOffset,
            y,
            enabled
        )

            local Btn =
                Instance.new(
                    "TextButton",
                    FeatureRow
                )

            Btn.Size =
                UDim2.new(
                    0.5,
                    -3,
                    0,
                    32
                )

            Btn.Position =
                UDim2.new(
                    xScale,
                    xOffset,
                    0,
                    y
                )

            Btn.Text = text

            Btn.Font =
                Enum.Font.SourceSansBold

            Btn.TextSize = 16

            Btn.TextColor3 =
                Color3.new(
                    1,
                    1,
                    1
                )

            Btn.BackgroundColor3 =
                enabled
                and ACTIVE_BTN_COLOR
                or DEFAULT_BTN_COLOR

            Instance.new(
                "UICorner",
                Btn
            ).CornerRadius =
                UDim.new(
                    0,
                    8
                )

            return Btn

        end


        -- =====================================================
        -- TP TOOL
        -- =====================================================

        local TPToolBtn =
            createFeatureButton(
                "TP Tool",
                0,
                0,
                0,
                false
            )

        TPToolBtn.MouseButton1Click:Connect(
            function()

                local backpack =
                    player:FindFirstChildOfClass(
                        "Backpack"
                    )

                local character =
                    player.Character

                if not backpack then
                    return
                end

                if backpack:FindFirstChild(
                    "TP Tool"
                )
                    or (
                        character
                        and character:FindFirstChild(
                            "TP Tool"
                        )
                    ) then

                    return

                end

                local tool =
                    Instance.new("Tool")

                tool.Name =
                    "TP Tool"

                tool.RequiresHandle =
                    false

                tool.CanBeDropped =
                    false

                tool.Activated:Connect(
                    function()

                        local mouse =
                            player:GetMouse()

                        if not mouse then
                            return
                        end

                        local currentCharacter =
                            player.Character

                        if not currentCharacter then
                            return
                        end

                        local root =
                            currentCharacter:FindFirstChild(
                                "HumanoidRootPart"
                            )

                        if not root then
                            return
                        end

                        local hit =
                            mouse.Hit

                        if hit then

                            root.CFrame =
                                CFrame.new(
                                    hit.Position +
                                    Vector3.new(
                                        0,
                                        3,
                                        0
                                    )
                                )

                        end

                    end
                )

                tool.Parent =
                    backpack

            end
        )


        -- =====================================================
        -- INFJUMP
        -- =====================================================

        local InfJumpBtn =
            createFeatureButton(
                infiniteJump
                and "InfJump : ON"
                or "InfJump : OFF",
                0.5,
                3,
                0,
                infiniteJump
            )

        InfJumpBtn.MouseButton1Click:Connect(
            function()

                infiniteJump =
                    not infiniteJump

                InfJumpBtn.Text =
                    infiniteJump
                    and "InfJump : ON"
                    or "InfJump : OFF"

                InfJumpBtn.BackgroundColor3 =
                    infiniteJump
                    and ACTIVE_BTN_COLOR
                    or DEFAULT_BTN_COLOR

            end
        )


        -- =====================================================
        -- NCCAM
        -- =====================================================

        local NCCamBtn =
            createFeatureButton(
                ncCam
                and "NCCam : ON"
                or "NCCam : OFF",
                0,
                0,
                44,
                ncCam
            )

        NCCamBtn.MouseButton1Click:Connect(
            function()

                ncCam =
                    not ncCam

                if ncCam then

                    player.DevCameraOcclusionMode =
                        Enum.DevCameraOcclusionMode.Invisicam

                else

                    player.DevCameraOcclusionMode =
                        originalCameraOcclusionMode

                end

                NCCamBtn.Text =
                    ncCam
                    and "NCCam : ON"
                    or "NCCam : OFF"

                NCCamBtn.BackgroundColor3 =
                    ncCam
                    and ACTIVE_BTN_COLOR
                    or DEFAULT_BTN_COLOR

            end
        )


        -- =====================================================
        -- MAXZOOM
        -- =====================================================

        local MaxZoomBtn =
            createFeatureButton(
                maxZoom
                and "MaxZoom : ON"
                or "MaxZoom : OFF",
                0.5,
                3,
                44,
                maxZoom
            )

        MaxZoomBtn.MouseButton1Click:Connect(
            function()

                maxZoom =
                    not maxZoom

                if maxZoom then

                    player.CameraMode =
                        Enum.CameraMode.Classic

                    player.CameraMinZoomDistance =
                        0.5

                    player.CameraMaxZoomDistance =
                        5000

                else

                    player.CameraMode =
                        originalCameraMode

                    player.CameraMinZoomDistance =
                        originalCameraMinZoom

                    player.CameraMaxZoomDistance =
                        originalCameraMaxZoom

                end

                MaxZoomBtn.Text =
                    maxZoom
                    and "MaxZoom : ON"
                    or "MaxZoom : OFF"

                MaxZoomBtn.BackgroundColor3 =
                    maxZoom
                    and ACTIVE_BTN_COLOR
                    or DEFAULT_BTN_COLOR

            end
        )


        -- =====================================================
        -- FB
        -- =====================================================

        local FBBtn =
            createFeatureButton(
                FB
                and "FB : ON"
                or "FB : OFF",
                0,
                0,
                88,
                FB
            )

        FBBtn.MouseButton1Click:Connect(
            function()

                FB =
                    not FB

                if FB then

                    Lighting.Brightness = 2
                    Lighting.ClockTime = 14
                    Lighting.FogEnd = 100000
                    Lighting.GlobalShadows = false

                    Lighting.Ambient =
                        Color3.new(
                            1,
                            1,
                            1
                        )

                    Lighting.OutdoorAmbient =
                        Color3.new(
                            1,
                            1,
                            1
                        )

                else

                    Lighting.Brightness =
                        originalLighting.Brightness

                    Lighting.ClockTime =
                        originalLighting.ClockTime

                    Lighting.FogEnd =
                        originalLighting.FogEnd

                    Lighting.GlobalShadows =
                        originalLighting.GlobalShadows

                    Lighting.Ambient =
                        originalLighting.Ambient

                    Lighting.OutdoorAmbient =
                        originalLighting.OutdoorAmbient

                end

                FBBtn.Text =
                    FB
                    and "FB : ON"
                    or "FB : OFF"

                FBBtn.BackgroundColor3 =
                    FB
                    and ACTIVE_BTN_COLOR
                    or DEFAULT_BTN_COLOR

            end
        )


        -- =====================================================
        -- FLOAT
        -- =====================================================

        local FloatBtn =
            createFeatureButton(
                floatEnabled
                and "Float : ON"
                or "Float : OFF",
                0.5,
                3,
                88,
                floatEnabled
            )

        FloatBtn.MouseButton1Click:Connect(
            function()

                floatEnabled =
                    not floatEnabled

                if floatEnabled then

                    enableFloat()

                else

                    disableFloat()

                end

                FloatBtn.Text =
                    floatEnabled
                    and "Float : ON"
                    or "Float : OFF"

                FloatBtn.BackgroundColor3 =
                    floatEnabled
                    and ACTIVE_BTN_COLOR
                    or DEFAULT_BTN_COLOR

                FloatControls.Visible =
                    floatEnabled

            end
        )


        -- =====================================================
        -- BARRIER
        -- =====================================================

        local BarrierBtn =
            createFeatureButton(
                barrierEnabled
                and "Barrier : ON"
                or "Barrier : OFF",
                0,
                0,
                132,
                barrierEnabled
            )

        BarrierBtn.MouseButton1Click:Connect(
            function()

                if barrierEnabled then

                    disableBarrier()

                else

                    enableBarrier()

                end

                BarrierBtn.Text =
                    barrierEnabled
                    and "Barrier : ON"
                    or "Barrier : OFF"

                BarrierBtn.BackgroundColor3 =
                    barrierEnabled
                    and ACTIVE_BTN_COLOR
                    or DEFAULT_BTN_COLOR

            end
        )


        -- =====================================================
        -- ANTIFLING
        -- =====================================================

        local AntiFlingBtn =
            createFeatureButton(
                antiFling
                and "AntiFling : ON"
                or "AntiFling : OFF",
                0.5,
                3,
                132,
                antiFling
            )

        AntiFlingBtn.MouseButton1Click:Connect(
            function()

                if antiFling then

                    disableAntiFling()

                else

                    enableAntiFling()

                end

                AntiFlingBtn.Text =
                    antiFling
                    and "AntiFling : ON"
                    or "AntiFling : OFF"

                AntiFlingBtn.BackgroundColor3 =
                    antiFling
                    and ACTIVE_BTN_COLOR
                    or DEFAULT_BTN_COLOR

            end
        )


        -- =====================================================
        -- NFD
        -- =====================================================

        local NFDBtn =
            createFeatureButton(
                nfd
                and "NFD : ON"
                or "NFD : OFF",
                0,
                0,
                176,
                nfd
            )

        NFDBtn.MouseButton1Click:Connect(
            function()

                nfd =
                    not nfd

                if nfd then

                    startNFD()

                else

                    stopNFD()

                end

                NFDBtn.Text =
                    nfd
                    and "NFD : ON"
                    or "NFD : OFF"

                NFDBtn.BackgroundColor3 =
                    nfd
                    and ACTIVE_BTN_COLOR
                    or DEFAULT_BTN_COLOR

            end
        )

        PlayerList.CanvasSize =
            UDim2.new(
                0,
                0,
                0,
                264
            )

        return

    end


    -- =====================================================
    -- BRING / TP
    -- =====================================================

    if SelectedTab == "Bring" then

        SearchBox.Visible = true
        AllButtonContainer.Visible = true
        StopViewContainer.Visible = false

        PlayerList.Size =
            UDim2.new(
                1,
                0,
                1,
                -78
            )

        PlayerList.Position =
            UDim2.new(
                0,
                0,
                0,
                78
            )

    else

        SearchBox.Visible = true
        AllButtonContainer.Visible = false
        StopViewContainer.Visible = false

        PlayerList.Size =
            UDim2.new(
                1,
                0,
                1,
                -44
            )

        PlayerList.Position =
            UDim2.new(
                0,
                0,
                0,
                44
            )

    end

    local filterText =
        SearchBox.Text:lower()

    local y = 0
    local BOTTOM_GAP = 10

    local otherPlayers = {}

    for _, plr in ipairs(
        Players:GetPlayers()
    ) do

        if plr ~= player then

            table.insert(
                otherPlayers,
                plr
            )

        end

    end

    table.sort(
        otherPlayers,

        function(a, b)

            return a.Name:lower()
                <
                b.Name:lower()

        end
    )

    for _, plrRef in ipairs(
        otherPlayers
    ) do

        if plrRef.Name:lower():find(
            filterText
        ) then

            local Btn =
                Instance.new(
                    "TextButton",
                    PlayerList
                )

            Btn.Size =
                UDim2.new(
                    1,
                    -6,
                    0,
                    28
                )

            Btn.Position =
                UDim2.new(
                    0,
                    6,
                    0,
                    y
                )

            Btn.Text =
                plrRef.Name

            Btn.Font =
                Enum.Font.SourceSansBold

            Btn.TextSize = 16

            Btn.TextColor3 =
                Color3.new(1, 1, 1)

            Btn.BackgroundColor3 =
                DEFAULT_BTN_COLOR

            if SelectedTab == "Bring" then

                if bringing[plrRef]
                    and bringing[plrRef].active then

                    setButtonStateForPlayer(
                        plrRef,
                        Btn,
                        true
                    )

                    bringing[plrRef].btn =
                        Btn

                end

                Btn.MouseButton1Click:Connect(
                    function()

                        if bringing[plrRef]
                            and bringing[plrRef].active then

                            bringing[plrRef] =
                                nil

                            setButtonStateForPlayer(
                                plrRef,
                                Btn,
                                false
                            )

                        else

                            bringing[plrRef] = {

                                active = true,
                                btn = Btn

                            }

                            setButtonStateForPlayer(
                                plrRef,
                                Btn,
                                true
                            )

                        end

                    end
                )

            elseif SelectedTab == "TP to" then

                Btn.MouseButton1Click:Connect(
                    function()

                        if plrRef.Character
                            and plrRef.Character:FindFirstChild(
                                "HumanoidRootPart"
                            )
                            and player.Character
                            and player.Character:FindFirstChild(
                                "HumanoidRootPart"
                            ) then

                            player.Character.HumanoidRootPart.CFrame =
                                plrRef.Character.HumanoidRootPart.CFrame
                                + Vector3.new(
                                    0,
                                    3,
                                    0
                                )

                        end

                    end
                )

            end

            y =
                y + 28

        end

    end

    PlayerList.CanvasSize =
        UDim2.new(
            0,
            0,
            0,
            y + BOTTOM_GAP
        )

end


-- =========================================================
-- SEARCH / PLAYERS
-- =========================================================

SearchBox:GetPropertyChangedSignal(
    "Text"
):Connect(
    refreshPlayers
)

Players.PlayerAdded:Connect(
    refreshPlayers
)

Players.PlayerRemoving:Connect(
    function(plr)

        bringing[plr] = nil
        espBoxes[plr] = nil

        if viewingPlayer == plr then
            stopViewing()
        end

        refreshPlayers()

    end
)

task.spawn(function()

    while ScreenGui.Parent do

        refreshPlayers()
        updateESP()

        task.wait(1)

    end

end)


-- =========================================================
-- BRING
-- =========================================================

RunService.RenderStepped:Connect(
    function()

        if SelectedTab ~= "Bring" then
            return
        end

        local myRoot =
            player.Character
            and player.Character:FindFirstChild(
                "HumanoidRootPart"
            )

        if not myRoot then
            return
        end

        if bringAll then

            for _, plr in ipairs(
                Players:GetPlayers()
            ) do

                if plr ~= player
                    and plr.Character
                    and plr.Character:FindFirstChild(
                        "HumanoidRootPart"
                    ) then

                    plr.Character.HumanoidRootPart.CFrame =
                        myRoot.CFrame *
                        CFrame.new(
                            0,
                            0,
                            -BRING_DISTANCE
                        )

                end

            end

        end

        for plr, info in pairs(
            bringing
        ) do

            if info
                and info.active
                and plr
                and plr.Character
                and plr.Character:FindFirstChild(
                    "HumanoidRootPart"
                ) then

                plr.Character.HumanoidRootPart.CFrame =
                    myRoot.CFrame *
                    CFrame.new(
                        0,
                        0,
                        -BRING_DISTANCE
                    )

            end

        end

    end
)


-- =========================================================
-- FLOAT UPDATE
-- =========================================================

local lastFloatRootPosition = nil

RunService.RenderStepped:Connect(
    function()

        if not floatEnabled then

            lastFloatRootPosition = nil
            return

        end

        local character =
            player.Character

        if not character then
            return
        end

        local root =
            character:FindFirstChild(
                "HumanoidRootPart"
            )

        if not root then
            return
        end

        if not floatPlatform
            or not floatPlatform.Parent then

            createFloatPlatform()

            lastFloatRootPosition =
                root.Position

            return

        end

        if lastFloatRootPosition then

            local rootDelta =
                root.Position -
                lastFloatRootPosition

            if rootDelta.Magnitude > 6 then

                floatHeight =
                    root.Position.Y - 3

            end

        end

        lastFloatRootPosition =
            root.Position

        floatPlatform.CFrame =
            CFrame.new(
                root.Position.X,
                floatHeight,
                root.Position.Z
            )

    end
)


-- =========================================================
-- NOCLIP
-- =========================================================

local noclip = false
local NcConnection
local charAddedConn
local storedCollisions = {}

local function storeCollisionsForChar(char)

    if not char then
        return
    end

    storedCollisions = {}

    for _, part in ipairs(
        char:GetDescendants()
    ) do

        if part:IsA("BasePart") then

            storedCollisions[part] =
                part.CanCollide

        end

    end

end

NcBtn.MouseButton1Click:Connect(
    function()

        noclip =
            not noclip

        NcBtn.BackgroundColor3 =
            noclip
            and ACTIVE_BTN_COLOR
            or TAB_BTN_COLOR

        if noclip then

            local char =
                player.Character

            if char then
                storeCollisionsForChar(char)
            end

            charAddedConn =
                player.CharacterAdded:Connect(
                    function(newChar)

                        storeCollisionsForChar(
                            newChar
                        )

                        for _, part in ipairs(
                            newChar:GetDescendants()
                        ) do

                            if part:IsA(
                                "BasePart"
                            ) then

                                part.CanCollide =
                                    false

                            end

                        end

                    end
                )

            NcConnection =
                RunService.Stepped:Connect(
                    function()

                        local char =
                            player.Character

                        if char then

                            for _, part in ipairs(
                                char:GetDescendants()
                            ) do

                                if part:IsA(
                                    "BasePart"
                                ) then

                                    part.CanCollide =
                                        false

                                end

                            end

                        end

                    end
                )

        else

            if NcConnection then

                NcConnection:Disconnect()
                NcConnection = nil

            end

            if charAddedConn then

                charAddedConn:Disconnect()
                charAddedConn = nil

            end

            for part, val in pairs(
                storedCollisions
            ) do

                if part
                    and part.Parent then

                    pcall(
                        function()

                            part.CanCollide =
                                val

                        end
                    )

                end

            end

            storedCollisions = {}

        end

    end
)


-- =========================================================
-- MINIMIZE
-- =========================================================

local minimized = false

MinBtn.MouseButton1Click:Connect(
    function()

        minimized =
            not minimized

        ContentFrame.Visible =
            not minimized

        LeftMenu.Visible =
            not minimized

        Frame.Size =
            minimized
            and UDim2.new(
                0,
                280,
                0,
                32
            )
            or UDim2.new(
                0,
                280,
                0,
                260
            )

    end
)


-- =========================================================
-- RESIZE HANDLE
-- =========================================================

local ResizeHandle =
    Instance.new(
        "TextButton",
        Frame
    )

ResizeHandle.Name =
    "ResizeHandle"

ResizeHandle.Size =
    UDim2.new(
        0,
        18,
        0,
        18
    )

ResizeHandle.Position =
    UDim2.new(
        1,
        -18,
        1,
        -18
    )

ResizeHandle.BackgroundTransparency =
    1

ResizeHandle.Text = "◢"

ResizeHandle.TextColor3 =
    Color3.fromRGB(
        130,
        130,
        130
    )

ResizeHandle.TextSize = 14
ResizeHandle.Font =
    Enum.Font.SourceSansBold

ResizeHandle.AutoButtonColor =
    false

local resizing = false
local resizeStartPosition
local resizeStartScale

ResizeHandle.InputBegan:Connect(
    function(input)

        if input.UserInputType ==
            Enum.UserInputType.MouseButton1
            or input.UserInputType ==
            Enum.UserInputType.Touch then

            resizing = true

            resizeStartPosition =
                input.Position

            resizeStartScale =
                UIScale.Scale

        end

    end
)

UserInputService.InputChanged:Connect(
    function(input)

        if not resizing then
            return
        end

        if input.UserInputType ==
            Enum.UserInputType.MouseMovement
            or input.UserInputType ==
            Enum.UserInputType.Touch then

            local delta =
                input.Position -
                resizeStartPosition

            local scaleDeltaX =
                delta.X / 280

            local scaleDeltaY =
                delta.Y / 260

            local scaleDelta =
                math.max(
                    scaleDeltaX,
                    scaleDeltaY
                )

            local newScale =
                math.clamp(
                    resizeStartScale +
                        scaleDelta,
                    MIN_SCALE,
                    MAX_SCALE
                )

            UIScale.Scale =
                newScale

        end

    end
)

UserInputService.InputEnded:Connect(
    function(input)

        if input.UserInputType ==
            Enum.UserInputType.MouseButton1
            or input.UserInputType ==
            Enum.UserInputType.Touch then

            resizing = false

        end

    end
)


-- =========================================================
-- VGD SHORTCUT
-- =========================================================

local VGDButton =
    Instance.new(
        "TextButton",
        ScreenGui
    )

VGDButton.Name =
    "VGDShortcut"

VGDButton.Size =
    UDim2.new(
        0,
        42,
        0,
        32
    )

-- Moved above Float controls
VGDButton.Position =
    UDim2.new(
        1,
        -55,
        0.55,
        -150
    )

VGDButton.AnchorPoint =
    Vector2.new(
        0.5,
        0.5
    )

VGDButton.BackgroundColor3 =
    Color3.fromRGB(
        35,
        35,
        35
    )

VGDButton.Text = "VGD"

VGDButton.TextColor3 =
    Color3.new(
        1,
        1,
        1
    )

VGDButton.Font =
    Enum.Font.SourceSansBold

VGDButton.TextSize = 14

VGDButton.AutoButtonColor =
    false

VGDButton.Active =
    true

Instance.new(
    "UICorner",
    VGDButton
).CornerRadius =
    UDim.new(
        0,
        8
    )

local vgdState = {
    dragging = false,
    dragStart = nil,
    startPosition = nil,
    activeInput = nil,
    moved = false
}

VGDButton.InputBegan:Connect(
    function(input)

        if input.UserInputType ==
            Enum.UserInputType.Touch
            or input.UserInputType ==
            Enum.UserInputType.MouseButton1 then

            vgdState.dragging = true
            vgdState.moved = false
            vgdState.activeInput = input

            vgdState.dragStart =
                input.Position

            vgdState.startPosition =
                VGDButton.Position

        end

    end
)

UserInputService.InputChanged:Connect(
    function(input)

        if not vgdState.dragging then
            return
        end

        if input ~= vgdState.activeInput then
            return
        end

        local delta =
            input.Position -
            vgdState.dragStart

        if math.abs(delta.X) > 5
            or math.abs(delta.Y) > 5 then

            vgdState.moved = true

        end

        VGDButton.Position =
            UDim2.new(
                vgdState.startPosition.X.Scale,
                vgdState.startPosition.X.Offset +
                    delta.X,
                vgdState.startPosition.Y.Scale,
                vgdState.startPosition.Y.Offset +
                    delta.Y
            )

    end
)

UserInputService.InputEnded:Connect(
    function(input)

        if not vgdState.dragging then
            return
        end

        if input ~= vgdState.activeInput then
            return
        end

        vgdState.dragging = false

        if not vgdState.moved then

            Frame.Visible =
                not Frame.Visible

        end

        vgdState.activeInput = nil

    end
)


-- =========================================================
-- CLOSE
-- =========================================================

CloseBtn.MouseButton1Click:Connect(
    function()

        if viewingPlayer then
            stopViewing()
        end

        disableFloat()
        disableBarrier()
        disableAntiFling()

        nfd = false
        stopNFD()

        FloatControls.Visible =
            false

        ScreenGui:Destroy()

    end
)


-- =========================================================
-- INITIAL
-- =========================================================

refreshPlayers()

-- Main GUI hidden by default.
-- VGD shortcut remains visible.
Frame.Visible = false
