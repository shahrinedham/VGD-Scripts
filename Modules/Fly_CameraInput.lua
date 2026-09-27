-- VGD Fly Camera Input Module
-- Extracted from V198 without changing touch/mouse behavior.
local M = {}

local function countTouches(positions)
    local count = 0
    local first = nil
    local second = nil
    for _, position in pairs(positions) do
        count += 1
        if not first then first = position
        elseif not second then second = position end
    end
    return count, first, second
end

local function makeTouchAction(ctx)
    return function(_, inputState, inputObject)
        if (not ctx.getFlyEnabled() and not ctx.getFlyCameraHandoffActive())
            or inputObject.UserInputType ~= Enum.UserInputType.Touch then
            return Enum.ContextActionResult.Pass
        end
        if ctx.getFlySpectatingOtherPlayer() then
            return Enum.ContextActionResult.Pass
        end

        local state = ctx.flyState
        local isJoystickTouch = inputObject == ctx.getFlyJoystickTouch()
            or ctx.flyCameraIsInDynamicThumbstickArea(inputObject.Position)

        if inputState == Enum.UserInputState.Begin then
            if isJoystickTouch or ctx.flyCameraIsOverGui(inputObject.Position) then
                return Enum.ContextActionResult.Pass
            end
            state.flyCameraTouchStates[inputObject] = true
            state.flyCameraZoomTouchPositions[inputObject] = inputObject.Position
            local count, first, second = countTouches(state.flyCameraZoomTouchPositions)
            if count >= 2 then
                state.flyCameraPinchLastDiameter = (first - second).Magnitude
            end
            return Enum.ContextActionResult.Sink
        end

        if state.flyCameraTouchStates[inputObject] then
            if isJoystickTouch then
                state.flyCameraTouchStates[inputObject] = nil
                state.flyCameraZoomTouchPositions[inputObject] = nil
                local remaining = countTouches(state.flyCameraZoomTouchPositions)
                if remaining < 2 then state.flyCameraPinchLastDiameter = nil end
                return Enum.ContextActionResult.Pass
            end

            if inputState == Enum.UserInputState.Change then
                state.flyCameraZoomTouchPositions[inputObject] = inputObject.Position
                local count, first, second = countTouches(state.flyCameraZoomTouchPositions)
                if count >= 2 then
                    local diameter = (first - second).Magnitude
                    if state.flyCameraPinchLastDiameter then
                        local pinchDelta = diameter - state.flyCameraPinchLastDiameter
                        local zoomDelta = -pinchDelta * 0.04
                        local currentZoom = state.flyCameraTargetZoomDistance
                        local newZoom
                        if zoomDelta > 0 then
                            newZoom = currentZoom + zoomDelta * (1 + currentZoom * 0.5)
                        else
                            newZoom = (currentZoom + zoomDelta) / (1 - zoomDelta * 0.5)
                        end
                        state.flyCameraTargetZoomDistance = math.clamp(
                            newZoom, ctx.FLY_CAMERA_ZOOM_MIN, ctx.FLY_CAMERA_ZOOM_MAX
                        )
                    end
                    state.flyCameraPinchLastDiameter = diameter
                    return Enum.ContextActionResult.Sink
                end

                local delta = inputObject.Delta
                if delta.Magnitude > 0 then
                    delta = ctx.flyCameraAdjustTouchPitchSensitivity(delta)
                    local rotation = Vector2.new(
                        delta.X * ctx.FLY_CAMERA_TOUCH_ROTATION_SPEED.X,
                        delta.Y * ctx.FLY_CAMERA_TOUCH_ROTATION_SPEED.Y
                    )
                    state.flyCameraTargetYaw = state.flyCameraTargetYaw - rotation.X
                    state.flyCameraTargetPitch = math.clamp(
                        state.flyCameraTargetPitch - rotation.Y,
                        ctx.FLY_CAMERA_MIN_PITCH,
                        ctx.FLY_CAMERA_MAX_PITCH
                    )
                end
                return Enum.ContextActionResult.Sink
            end

            if inputState == Enum.UserInputState.End
                or inputState == Enum.UserInputState.Cancel then
                state.flyCameraTouchStates[inputObject] = nil
                state.flyCameraZoomTouchPositions[inputObject] = nil
                local count = countTouches(state.flyCameraZoomTouchPositions)
                if count < 2 then state.flyCameraPinchLastDiameter = nil end
                return Enum.ContextActionResult.Sink
            end
            return Enum.ContextActionResult.Sink
        end
        return Enum.ContextActionResult.Pass
    end
end

local function bindTouch(ctx, touchAction)
    ctx.ContextActionService:BindActionAtPriority(
        "VGD_FlyCameraTouch",
        touchAction,
        false,
        Enum.ContextActionPriority.High.Value,
        Enum.UserInputType.Touch
    )

    ctx.flyCameraConnections.TouchEnded = ctx.UserInputService.TouchEnded:Connect(function(input)
        local state = ctx.flyState
        state.flyCameraTouchStates[input] = nil
        state.flyCameraZoomTouchPositions[input] = nil
        local count = countTouches(state.flyCameraZoomTouchPositions)
        if count < 2 then state.flyCameraPinchLastDiameter = nil end
    end)
end

local function bindMouse(ctx)
    ctx.flyCameraConnections.MouseBegan = ctx.UserInputService.InputBegan:Connect(function(input, gameProcessedEvent)
        if (not ctx.getFlyEnabled() and not ctx.getFlyCameraHandoffActive())
            or ctx.getFlySpectatingOtherPlayer() or gameProcessedEvent then return end
        if input.UserInputType == Enum.UserInputType.MouseButton2 then
            ctx.setFlyCameraMouseLooking(true)
        end
    end)

    ctx.flyCameraConnections.MouseChanged = ctx.UserInputService.InputChanged:Connect(function(input)
        if (not ctx.getFlyEnabled() and not ctx.getFlyCameraHandoffActive())
            or ctx.getFlySpectatingOtherPlayer() or not ctx.getFlyCameraMouseLooking() then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement then
            ctx.flyState.flyCameraMouseDelta += input.Delta
        end
    end)

    ctx.flyCameraConnections.MouseEnded = ctx.UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton2 then
            ctx.setFlyCameraMouseLooking(false)
        end
    end)

    ctx.flyCameraConnections.MouseWheel = ctx.UserInputService.InputChanged:Connect(function(input)
        if (not ctx.getFlyEnabled() and not ctx.getFlyCameraHandoffActive())
            or ctx.getFlySpectatingOtherPlayer() then return end
        if input.UserInputType ~= Enum.UserInputType.MouseWheel then return end
        local wheel = input.Position.Z
        if wheel == 0 then return end
        local zoomDelta = -wheel
        local currentZoom = ctx.flyState.flyCameraTargetZoomDistance
        local newZoom
        if zoomDelta > 0 then
            newZoom = currentZoom + zoomDelta * (1 + currentZoom * 0.5)
        else
            newZoom = (currentZoom + zoomDelta) / (1 - zoomDelta * 0.5)
        end
        ctx.flyState.flyCameraTargetZoomDistance = math.clamp(
            newZoom, ctx.FLY_CAMERA_ZOOM_MIN, ctx.FLY_CAMERA_ZOOM_MAX
        )
    end)
end

function M.connect(ctx)
    ctx.disconnect()
    local touchAction = makeTouchAction(ctx)
    bindTouch(ctx, touchAction)
    bindMouse(ctx)
end

return M
