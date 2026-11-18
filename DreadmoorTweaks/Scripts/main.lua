--[[----------------------------------------------------------------------------
    DreadmoorTweaks
    Third-person camera plus a set of quality-of-life / debug helpers for
    Dreadmoor (UE 5.6, UE4SS v4).

    Install:
        ue4ss/Mods/DreadmoorTweaks/Scripts/main.lua   (this file)
        ue4ss/Mods/DreadmoorTweaks/enabled.txt
        ue4ss/Mods/mods.txt  ->  DreadmoorTweaks : 1

    The whole mod is intentionally a single file so it cannot fail on a
    missing local require. Tune the CONFIG table below.

    Keys:
        F1                  Print help + current status
        F2                  Toggle third person
        F4                  Cycle shoulder preset (right / left / center)
        PAGE_UP / PAGE_DOWN Camera distance
        OEM_PLUS / OEM_MINUS Camera field of view
        HOME                Reset camera distance / FOV / shoulder
        END                 Toggle camera collision
        F6                  Cycle movement speed
        F7                  Toggle god mode
        F8                  Toggle infinite stamina / oxygen
        F10                 Toggle infinite ship fuel
        F11                 Open the game's built-in cheat panel
        INS                 Teleport to ship
        DEL                 Cycle slow motion (1.0 / 0.5 / 0.25)
        NUM1                Toggle flashlight
        NUM2                Cycle time of day
        NUM3                Cycle ship speed multiplier
        NUM4                Cycle graphics quality preset

    Console: dmt help
----------------------------------------------------------------------------]]--

local UEHelpers = require("UEHelpers")

-- ============================================================================
-- CONFIG
-- ============================================================================

local CONFIG = {
    -- Start with third person already enabled. Kept off by default so a fresh
    -- install never changes the game on its own; press F2 (or set to true).
    startEnabled = false,

    -- Game-thread polling interval in milliseconds.
    updateIntervalMs = 50,

    -- Re-assert mesh visibility / camera state every N polls (0 = never).
    reassertEveryTicks = 10,

    -- Camera boom
    armLength = 320.0,
    minArmLength = 100.0,
    maxArmLength = 800.0,
    armLengthStep = 40.0,
    targetOffsetZ = 55.0,
    shoulderPresets = {
        { label = "right",  Y =  45.0, Z = 55.0 },
        { label = "left",   Y = -45.0, Z = 55.0 },
        { label = "center", Y =   0.0, Z = 62.0 },
    },

    -- Camera lens
    fieldOfView = 90.0,
    minFieldOfView = 55.0,
    maxFieldOfView = 120.0,
    fovStep = 5.0,

    -- Boom feel
    enableCameraLag = false,
    cameraLagSpeed = 10.0,
    collisionProbeSize = 12.0,

    -- Behaviour
    bodyFollowsCamera = true,   -- actor yaw follows the camera while active
    suspendWhileAiming = false, -- release third person while IsAiming is true
    hideCameraAttachments = true, -- hide first-person viewmodel children of BP Camera

    -- Cheats
    speedMultipliers = { 1.0, 1.5, 2.0, 3.0 },
    shipSpeedMultipliers = { 1.0, 1.5, 2.0, 3.0 },
    slowMotionScales = { 1.0, 0.5, 0.25 },

    -- Extras found in the dump
    timeOfDayPresets = { 6.0, 12.0, 18.0, 0.0 }, -- dawn, noon, dusk, midnight
    qualityLevels = { 0, 1, 2, 3 },               -- low .. epic
}

-- ============================================================================
-- Logging / small utilities
-- ============================================================================

local PREFIX = "[DreadmoorTweaks]"

local function log(message)
    print(string.format("%s %s\n", PREFIX, tostring(message)))
end

local KSL = nil
local KML = nil
local GS = nil

local function kismetSystem()
    if not KSL or not KSL:IsValid() then
        KSL = UEHelpers.GetKismetSystemLibrary()
    end
    return KSL
end

local function kismetMath()
    if not KML or not KML:IsValid() then
        KML = UEHelpers.GetKismetMathLibrary()
    end
    return KML
end

local function gameplayStatics()
    if not GS or not GS:IsValid() then
        GS = UEHelpers.GetGameplayStatics()
    end
    return GS
end

local function tryGet(object, property)
    if not object or not object:IsValid() then return nil end
    local ok, value = pcall(function() return object[property] end)
    if ok then return value end
    return nil
end

local function trySet(object, property, value)
    if not object or not object:IsValid() then return false end
    local ok = pcall(function() object[property] = value end)
    return ok
end

local function tryCall(object, method, ...)
    if not object or not object:IsValid() then return false end
    local args = { n = select("#", ...), ... }
    local ok = pcall(function()
        object[method](object, table.unpack(args, 1, args.n))
    end)
    return ok
end

-- Array elements returned by UFUNCTIONs are RemoteUnrealParam wrappers in
-- UE4SS 4.x. They expose :get() instead of :IsValid(), so unwrap them.
local function deref(value)
    if value == nil then return nil end
    local ok, getter = pcall(function() return value.get end)
    if ok and type(getter) == "function" then
        local getOk, result = pcall(function() return value:get() end)
        if getOk then return result end
    end
    return value
end

local classCache = {}

local function findClass(path)
    local cached = classCache[path]
    if cached and cached:IsValid() then return cached end
    local found = StaticFindObject(path)
    if found and found:IsValid() then
        classCache[path] = found
        return found
    end
    return nil
end

local function isCharacter(actor)
    local characterClass = findClass("/Script/Engine.Character")
    if not characterClass or not actor or not actor:IsValid() then return false end
    local ok, result = pcall(function() return actor:IsA(characterClass) end)
    return ok and result == true
end

local function isPrimitive(object)
    local primitiveClass = findClass("/Script/Engine.PrimitiveComponent")
    if not primitiveClass or not object or not object:IsValid() then return false end
    local ok, result = pcall(function() return object:IsA(primitiveClass) end)
    return ok and result == true
end

-- ============================================================================
-- Player / world resolution with caching
-- ============================================================================

local controllerCache = nil
local nextControllerSearch = 0

local function getController()
    if controllerCache and controllerCache:IsValid() then
        return controllerCache
    end
    controllerCache = nil

    local now = os.time()
    if now < nextControllerSearch then return nil end
    nextControllerSearch = now + 1

    local controller = UEHelpers.GetPlayerController()
    if controller and controller:IsValid() then
        controllerCache = controller
        return controller
    end
    return nil
end

local function getPawn()
    local controller = getController()
    if not controller then return nil end
    local pawn = tryGet(controller, "Pawn")
    if pawn and pawn:IsValid() then return pawn end
    return nil
end

local function notify(message, duration)
    local context = getPawn() or getController()
    if not context then return end
    local ok = pcall(function()
        kismetSystem():PrintString(
            context,
            tostring(message),
            true,
            false,
            { R = 0.35, G = 0.85, B = 1.0, A = 1.0 },
            duration or 3.0,
            FName("DreadmoorTweaksHUD")
        )
    end)
    if not ok then log(message) end
end

-- ============================================================================
-- Attributes (GAS)
-- ============================================================================

local function getAttribute(attributeSet, attributeName)
    if not attributeSet or not attributeSet:IsValid() then return nil end
    local value = nil
    pcall(function()
        local data = attributeSet[attributeName]
        if data ~= nil then
            value = data.CurrentValue
        end
    end)
    return value
end

local function setAttribute(attributeSet, attributeName, value)
    if not attributeSet or not attributeSet:IsValid() then return false end

    local ok = pcall(function()
        local data = attributeSet[attributeName]
        if data == nil then error("attribute not found") end
        data.BaseValue = value
        data.CurrentValue = value
        attributeSet[attributeName] = data
    end)
    if ok then return true end

    -- Fallback: assign the whole struct from a Lua table.
    return pcall(function()
        attributeSet[attributeName] = { BaseValue = value, CurrentValue = value }
    end)
end

local function fillAttribute(attributeSet, currentName, maxName)
    if not attributeSet or not attributeSet:IsValid() then return end
    local maximum = getAttribute(attributeSet, maxName)
    if not maximum or maximum <= 0 then return end
    local current = getAttribute(attributeSet, currentName)
    if not current or current < maximum then
        setAttribute(attributeSet, currentName, maximum)
    end
end

-- ============================================================================
-- Ship lookup (only one small boat exists in the level)
-- ============================================================================

local shipCache = nil

local function findShip()
    if shipCache and shipCache:IsValid() then return shipCache end
    shipCache = nil
    local ok, ship = pcall(function() return FindFirstOf("BP_SmallBoat_V2_C") end)
    if ok and ship and ship:IsValid() then
        shipCache = ship
        return ship
    end
    return nil
end

-- ============================================================================
-- Input action lookup (needed when invoking BP Enhanced Input events)
-- ============================================================================

local inputActionCache = {}

local function getInputAction(fragment)
    local cached = inputActionCache[fragment]
    if cached ~= nil then
        if cached == false then return nil end
        if cached:IsValid() then return cached end
    end

    local found = nil
    local ok, actions = pcall(function() return FindAllOf("InputAction") end)
    if ok and actions then
        for index = 1, #actions do
            local action = deref(actions[index])
            if action and action:IsValid() then
                local fullName = ""
                pcall(function() fullName = action:GetFullName() end)
                if string.find(fullName, fragment, 1, true) then
                    found = action
                    break
                end
            end
        end
    end

    inputActionCache[fragment] = found or false
    return found
end

local function callActorEvent(actor, eventName, actionFragment, actionValue)
    if not actor or not actor:IsValid() then return false end

    local functionRef = nil
    pcall(function() functionRef = actor[eventName] end)
    if not functionRef then
        log("Input event not found: " .. eventName)
        return false
    end

    local sourceAction = actionFragment and getInputAction(actionFragment) or nil
    local ok, err = pcall(function()
        -- FInputActionValue is an opaque 0x20-byte struct. An empty table is a
        -- zeroed value; digital handlers that read the value need X != 0.
        functionRef(actor, actionValue or {}, 0.0, 0.0, sourceAction)
    end)
    if not ok then
        log("Input event failed: " .. eventName .. " (" .. tostring(err) .. ")")
    end
    return ok
end

local function callControllerEvent(eventName, actionFragment, actionValue)
    local controller = getController()
    if not controller then return false end
    return callActorEvent(controller, eventName, actionFragment, actionValue)
end

-- Digital Enhanced Input events only need a non-zero X on UE's
-- FInputActionValue; try that shape first, then fall back to the raw struct.
local function callDigitalEvent(actor, eventName, actionFragment)
    local pressed = {
        Value = { X = 1.0, Y = 0.0, Z = 0.0 },
        bIsBoolean = true,
    }
    if callActorEvent(actor, eventName, actionFragment, pressed) then
        return true
    end
    return callActorEvent(actor, eventName, actionFragment, {})
end

-- ============================================================================
-- Third-person rig
-- ============================================================================

local state = {
    enabled = CONFIG.startEnabled,
    rigPawn = nil,
    arm = nil,
    camera = nil,
    rigActive = false,
    orig = nil,
    tick = 0,
    errorCount = 0,

    shoulderIndex = 1,
    armLength = CONFIG.armLength,
    fieldOfView = CONFIG.fieldOfView,
    collisionEnabled = true,

    godMode = false,
    infiniteVitals = false,
    infiniteFuel = false,

    speedIndex = 1,
    speedOrig = nil,

    shipSpeedIndex = 1,
    shipSpeedOrig = nil,

    timeIndex = 0,
    qualityIndex = 1,

    slowIndex = 1,
}

local function identityTransform()
    return kismetMath():MakeTransform(
        { X = 0.0, Y = 0.0, Z = 0.0 },
        { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 },
        { X = 1.0, Y = 1.0, Z = 1.0 }
    )
end

local function currentShoulder()
    return CONFIG.shoulderPresets[state.shoulderIndex] or CONFIG.shoulderPresets[1]
end

local function applyCameraSettings()
    local arm = state.arm
    local camera = state.camera
    if not arm or not arm:IsValid() then return end

    local shoulder = currentShoulder()

    pcall(function()
        arm.TargetArmLength = state.armLength
        arm.SocketOffset = { X = 0.0, Y = shoulder.Y, Z = shoulder.Z }
        arm.TargetOffset = { X = 0.0, Y = 0.0, Z = CONFIG.targetOffsetZ }
        arm.bDoCollisionTest = state.collisionEnabled
        arm.ProbeSize = CONFIG.collisionProbeSize
        arm.bUsePawnControlRotation = true
        arm.bInheritPitch = true
        arm.bInheritYaw = true
        arm.bInheritRoll = true
        arm.bEnableCameraLag = CONFIG.enableCameraLag
        arm.CameraLagSpeed = CONFIG.cameraLagSpeed
        arm.bEnableCameraRotationLag = false
    end)

    if camera and camera:IsValid() then
        pcall(function() camera:SetFieldOfView(state.fieldOfView) end)
    end
end

local function createRig(pawn)
    local armClass = findClass("/Script/Engine.SpringArmComponent")
    local cameraClass = findClass("/Script/Engine.CameraComponent")
    if not armClass or not cameraClass then
        log("Could not resolve SpringArmComponent / CameraComponent classes")
        return false
    end

    local arm = nil
    local ok = pcall(function()
        arm = pawn:AddComponentByClass(armClass, false, identityTransform(), false)
    end)
    if not ok or not arm or not arm:IsValid() then
        log("Failed to add spring arm component")
        return false
    end
    pcall(function() pawn:FinishAddComponent(arm, false, identityTransform()) end)

    local camera = nil
    ok = pcall(function()
        camera = pawn:AddComponentByClass(cameraClass, false, identityTransform(), false)
    end)
    if not ok or not camera or not camera:IsValid() then
        log("Failed to add camera component")
        pcall(function() arm:K2_DestroyComponent(arm) end)
        return false
    end
    pcall(function() pawn:FinishAddComponent(camera, true, identityTransform()) end)

    state.arm = arm
    state.camera = camera

    applyCameraSettings()

    local attached = false
    pcall(function()
        attached = camera:K2_AttachToComponent(
            arm,
            FName("SpringEndpoint"),
            2, -- EAttachmentRule::SnapToTarget
            2,
            2,
            false
        )
    end)
    if not attached then
        -- Socket may not be registered yet; retry without a socket name.
        pcall(function()
            camera:K2_AttachToComponent(arm, FName("None"), 2, 2, 2, false)
        end)
    end

    local parent = nil
    pcall(function() parent = camera:GetAttachParent() end)
    if not parent or not parent:IsValid() then
        log("Failed to attach the camera to the spring arm")
        pcall(function() camera:K2_DestroyComponent(camera) end)
        pcall(function() arm:K2_DestroyComponent(arm) end)
        state.arm = nil
        state.camera = nil
        return false
    end

    pcall(function() camera:SetActive(true) end)
    pcall(function() arm:SetActive(true) end)

    state.rigPawn = pawn
    log(string.format("Third-person rig created on %s", pawn:GetFullName()))
    return true
end

local function captureMeshState(pawn)
    local entries = {}

    local primitiveClass = findClass("/Script/Engine.PrimitiveComponent")
    if primitiveClass then
        local components = nil
        pcall(function() components = pawn:K2_GetComponentsByClass(primitiveClass) end)
        if components then
            for index = 1, #components do
                local component = deref(components[index])
                if component and component:IsValid() then
                    entries[#entries + 1] = {
                        comp = component,
                        ownerNoSee = tryGet(component, "bOwnerNoSee"),
                        firstPersonType = tryGet(component, "FirstPersonPrimitiveType"),
                    }
                end
            end
        end
    end

    return entries
end

local function captureCameraChildren()
    local list = {}
    local root = state.orig and state.orig.bpCamera
    if not root or not root:IsValid() then return list end

    local stack = { root }
    local visited = 0
    while #stack > 0 and visited < 64 do
        local parent = table.remove(stack)
        local count = 0
        pcall(function() count = parent:GetNumChildrenComponents() end)
        for index = 0, count - 1 do
            local child = nil
            pcall(function() child = parent:GetChildComponent(index) end)
            if child and child:IsValid() then
                visited = visited + 1
                list[#list + 1] = {
                    comp = child,
                    visible = tryGet(child, "bVisible"),
                }
                if visited < 64 then
                    stack[#stack + 1] = child
                end
            end
        end
    end

    return list
end

local function captureOriginalState(pawn)
    local original = {
        bpCamera = tryGet(pawn, "Camera"),
        mesh = tryGet(pawn, "Mesh"),
        movement = tryGet(pawn, "CharacterMovement"),
        viewTarget = nil,
    }

    local controller = getController()
    if controller and controller:IsValid() then
        pcall(function() original.viewTarget = controller:GetViewTarget() end)
    end

    if original.bpCamera and original.bpCamera:IsValid() then
        original.bpCameraActive = original.bpCamera:IsActive()
    else
        original.bpCamera = nil
        original.bpCameraActive = false
    end

    original.findCamera = tryGet(pawn, "bFindCameraComponentWhenViewTarget")
    original.useControllerYaw = tryGet(pawn, "bUseControllerRotationYaw")
    original.useControllerPitch = tryGet(pawn, "bUseControllerRotationPitch")
    original.useControllerRoll = tryGet(pawn, "bUseControllerRotationRoll")

    if original.movement and original.movement:IsValid() then
        original.orientToMovement = tryGet(original.movement, "bOrientRotationToMovement")
    end

    if original.mesh and original.mesh:IsValid() then
        original.meshOwnerNoSee = tryGet(original.mesh, "bOwnerNoSee")
        original.meshVisible = tryGet(original.mesh, "bVisible")
        original.meshHiddenInGame = tryGet(original.mesh, "bHiddenInGame")
    end

    original.meshEntries = captureMeshState(pawn)
    original.cameraChildren = {}

    state.orig = original

    if CONFIG.hideCameraAttachments then
        original.cameraChildren = captureCameraChildren()
    end

    return original
end

local function applyMeshState()
    local original = state.orig
    if not original then return end

    if original.mesh and original.mesh:IsValid() then
        pcall(function() original.mesh:SetOwnerNoSee(false) end)
        pcall(function() original.mesh:SetHiddenInGame(false, false) end)
        pcall(function() original.mesh:SetVisibility(true, false) end)
        pcall(function() original.mesh:SetFirstPersonPrimitiveType(0) end)
    end

    local entries = original.meshEntries
    if entries then
        for index = 1, #entries do
            local entry = entries[index]
            local component = entry.comp
            if component and component:IsValid() then
                pcall(function() component:SetOwnerNoSee(false) end)
                pcall(function() component:SetFirstPersonPrimitiveType(0) end)
            end
        end
    end

    local children = original.cameraChildren
    if children then
        for index = 1, #children do
            local entry = children[index]
            local component = entry.comp
            if component and component:IsValid() and isPrimitive(component) then
                pcall(function() component:SetVisibility(false, true) end)
            end
        end
    end
end

local function restoreMeshState()
    local original = state.orig
    if not original then return end

    local mesh = original.mesh
    if mesh and mesh:IsValid() then
        if original.meshOwnerNoSee ~= nil then
            pcall(function() mesh:SetOwnerNoSee(original.meshOwnerNoSee) end)
        end
        if original.meshHiddenInGame ~= nil then
            pcall(function() mesh:SetHiddenInGame(original.meshHiddenInGame, false) end)
        end
        if original.meshVisible ~= nil then
            pcall(function() mesh:SetVisibility(original.meshVisible, false) end)
        end
    end

    local entries = original.meshEntries
    if entries then
        for index = 1, #entries do
            local entry = entries[index]
            local component = entry.comp
            if component and component:IsValid() then
                if entry.ownerNoSee ~= nil then
                    pcall(function() component:SetOwnerNoSee(entry.ownerNoSee) end)
                end
                if entry.firstPersonType ~= nil then
                    pcall(function() component:SetFirstPersonPrimitiveType(entry.firstPersonType) end)
                end
            end
        end
    end

    local children = original.cameraChildren
    if children then
        for index = 1, #children do
            local entry = children[index]
            local component = entry.comp
            if component and component:IsValid() and entry.visible ~= nil then
                pcall(function() component:SetVisibility(entry.visible, true) end)
            end
        end
    end
end

local function setRigActive(active)
    if active == state.rigActive then return end
    if not state.rigPawn or not state.rigPawn:IsValid() then
        state.rigActive = false
        state.orig = nil
        return
    end

    if active then
        local pawn = state.rigPawn
        if not captureOriginalState(pawn) then return end

        state.rigActive = true

        local original = state.orig
        if original.bpCamera and original.bpCamera:IsValid() then
            pcall(function() original.bpCamera:SetActive(false, true) end)
        else
            log("BP camera not found/invalid")
        end
        if state.camera and state.camera:IsValid() then
            pcall(function() state.camera:SetActive(true) end)
        end

        trySet(pawn, "bFindCameraComponentWhenViewTarget", true)

        local controller = getController()
        if controller and controller:IsValid() then
            -- Force the view target to the pawn so CalcCamera re-evaluates
            -- the pawn's camera components.
            pcall(function() controller:SetViewTargetWithBlend(pawn, 0.0, 0, 0.0, false) end)
        end

        trySet(pawn, "bFindCameraComponentWhenViewTarget", true)
        if CONFIG.bodyFollowsCamera then
            trySet(pawn, "bUseControllerRotationYaw", true)
            trySet(pawn, "bUseControllerRotationPitch", false)
            trySet(pawn, "bUseControllerRotationRoll", false)
            if original.movement and original.movement:IsValid() then
                trySet(original.movement, "bOrientRotationToMovement", false)
            end
        end

        applyMeshState()
    else
        local original = state.orig
        state.rigActive = false

        if state.camera and state.camera:IsValid() then
            pcall(function() state.camera:SetActive(false) end)
        end

        if original then
            local pawn = state.rigPawn
            if pawn and pawn:IsValid() then
                if original.bpCamera and original.bpCamera:IsValid() then
                    pcall(function() original.bpCamera:SetActive(original.bpCameraActive) end)
                end
                if original.findCamera ~= nil then
                    trySet(pawn, "bFindCameraComponentWhenViewTarget", original.findCamera)
                end
                if original.useControllerYaw ~= nil then
                    trySet(pawn, "bUseControllerRotationYaw", original.useControllerYaw)
                end
                if original.useControllerPitch ~= nil then
                    trySet(pawn, "bUseControllerRotationPitch", original.useControllerPitch)
                end
                if original.useControllerRoll ~= nil then
                    trySet(pawn, "bUseControllerRotationRoll", original.useControllerRoll)
                end
                if original.movement and original.movement:IsValid() and original.orientToMovement ~= nil then
                    trySet(original.movement, "bOrientRotationToMovement", original.orientToMovement)
                end
            end
            restoreMeshState()
        end

        state.orig = nil
    end
end

local function destroyRig()
    if not state.rigPawn and not state.arm and not state.camera then return end

    setRigActive(false)

    local camera = state.camera
    local arm = state.arm

    if camera and camera:IsValid() then
        pcall(function() camera:K2_DestroyComponent(camera) end)
    end
    if arm and arm:IsValid() then
        pcall(function() arm:K2_DestroyComponent(arm) end)
    end

    state.camera = nil
    state.arm = nil
    state.rigPawn = nil
    state.rigActive = false
    state.orig = nil
end

local function ensureRig(pawn)
    if state.rigPawn == pawn
        and state.arm and state.arm:IsValid()
        and state.camera and state.camera:IsValid() then
        return true
    end
    destroyRig()
    if not isCharacter(pawn) then return false end
    return createRig(pawn)
end

local function isSuspended(pawn)
    if tryGet(pawn, "bIsDead") == true then return true end
    if tryGet(pawn, "bDialogueSequenceCameraActive") == true then return true end
    if CONFIG.suspendWhileAiming and tryGet(pawn, "IsAiming") == true then return true end
    return false
end

local function enforceThirdPerson()
    if not state.rigActive or not state.orig then return end

    local original = state.orig
    local bpCamera = original.bpCamera
    if bpCamera and bpCamera:IsValid() and bpCamera:IsActive() then
        pcall(function() bpCamera:SetActive(false) end)
        applyMeshState()
    end

    if state.camera and state.camera:IsValid() and not state.camera:IsActive() then
        pcall(function() state.camera:SetActive(true) end)
    end

    if state.rigPawn and state.rigPawn:IsValid() then
        if CONFIG.bodyFollowsCamera and tryGet(state.rigPawn, "bUseControllerRotationYaw") ~= true then
            trySet(state.rigPawn, "bUseControllerRotationYaw", true)
        end
    end

    if CONFIG.reassertEveryTicks > 0 and state.tick % CONFIG.reassertEveryTicks == 0 then
        applyMeshState()
    end
end

-- ============================================================================
-- Camera / feature actions
-- ============================================================================

local function toggleThirdPerson()
    state.enabled = not state.enabled

    if state.enabled then
        local pawn = getPawn()
        if not pawn or not isCharacter(pawn) then
            notify("Third person: ON (waiting for player character)")
        else
            notify("Third person: ON")
        end
    else
        if state.rigPawn then destroyRig() end
        notify("Third person: OFF")
    end
end

local function cycleShoulder()
    state.shoulderIndex = state.shoulderIndex + 1
    if state.shoulderIndex > #CONFIG.shoulderPresets then
        state.shoulderIndex = 1
    end
    applyCameraSettings()
    notify(string.format("Camera shoulder: %s", currentShoulder().label))
end

local function adjustDistance(delta)
    state.armLength = state.armLength + delta
    if state.armLength < CONFIG.minArmLength then state.armLength = CONFIG.minArmLength end
    if state.armLength > CONFIG.maxArmLength then state.armLength = CONFIG.maxArmLength end
    applyCameraSettings()
    notify(string.format("Camera distance: %.0f", state.armLength), 1.5)
end

local function adjustFieldOfView(delta)
    state.fieldOfView = state.fieldOfView + delta
    if state.fieldOfView < CONFIG.minFieldOfView then state.fieldOfView = CONFIG.minFieldOfView end
    if state.fieldOfView > CONFIG.maxFieldOfView then state.fieldOfView = CONFIG.maxFieldOfView end
    applyCameraSettings()
    notify(string.format("Camera FOV: %.0f", state.fieldOfView), 1.5)
end

local function resetCamera()
    state.armLength = CONFIG.armLength
    state.fieldOfView = CONFIG.fieldOfView
    state.shoulderIndex = 1
    state.collisionEnabled = true
    applyCameraSettings()
    notify("Camera reset")
end

local function toggleCollision()
    state.collisionEnabled = not state.collisionEnabled
    applyCameraSettings()
    notify(string.format("Camera collision: %s", state.collisionEnabled and "ON" or "OFF"))
end

local function toggleHud()
    local controller = getController()
    if not controller then return end
    if tryCall(controller, "SwitchUIHidden") then
        notify("HUD toggled")
    else
        notify("HUD toggle unavailable")
    end
end

-- Both cheat helpers live on a static Blueprint function library; its CDO is
-- the callable object (`/Script/Dreadmoor.Default__DrdBlueprintFunctionsDebug`).
local debugLibrary = nil

local function getDebugLibrary()
    if debugLibrary and debugLibrary:IsValid() then return debugLibrary end
    debugLibrary = nil
    local ok, found = pcall(function()
        return StaticFindObject("/Script/Dreadmoor.Default__DrdBlueprintFunctionsDebug")
    end)
    if ok and found and found:IsValid() then
        debugLibrary = found
        return found
    end
    return nil
end

local function setCheatInvulnerable(enabled)
    local library = getDebugLibrary()
    if not library then
        log("DrdBlueprintFunctionsDebug CDO not found; using health refill fallback")
        return false
    end
    local ok, err = pcall(function() library:SetCheatInvulnerable(enabled) end)
    if not ok then
        log("SetCheatInvulnerable failed: " .. tostring(err))
    end
    return ok
end

local function isCheatInvulnerable()
    local library = getDebugLibrary()
    if not library then return nil end
    local ok, value = pcall(function() return library:IsCheatInvulnerable() end)
    if ok then return value end
    return nil
end

local function toggleGodMode()
    state.godMode = not state.godMode
    local applied = setCheatInvulnerable(state.godMode)
    notify(string.format(
        "God mode: %s%s",
        state.godMode and "ON" or "OFF",
        applied and "" or " (refill only)"
    ))
    log(string.format(
        "God mode %s | engine invulnerable: %s",
        state.godMode and "ON" or "OFF",
        tostring(isCheatInvulnerable())
    ))
end

local function toggleInfiniteVitals()
    state.infiniteVitals = not state.infiniteVitals
    local pawn = getPawn()
    if pawn then
        local characterSet = tryGet(pawn, "AttributeSetPlayerChar")
        local oxygenSet = tryGet(pawn, "OxygenAttributeSet") or tryGet(pawn, "AttributeSetOxygen")
        log(string.format(
            "Vitals %s | stamina set: %s | oxygen set: %s",
            state.infiniteVitals and "ON" or "OFF",
            tostring(characterSet and characterSet:IsValid()),
            tostring(oxygenSet and oxygenSet:IsValid())
        ))
        if characterSet and characterSet:IsValid() then
            log(string.format(
                "  Stamina %.1f / %.1f",
                getAttribute(characterSet, "Stamina") or -1,
                getAttribute(characterSet, "StaminaMax") or -1
            ))
        end
    end
    notify(string.format("Infinite vitals: %s", state.infiniteVitals and "ON" or "OFF"))
end

local function toggleInfiniteFuel()
    state.infiniteFuel = not state.infiniteFuel
    local ship = findShip()
    if ship then
        local fuelSet = tryGet(ship, "AttributeSetShip")
        log(string.format(
            "Ship fuel %s | %s | set: %s",
            state.infiniteFuel and "ON" or "OFF",
            ship:GetFullName(),
            tostring(fuelSet and fuelSet:IsValid())
        ))
        if fuelSet and fuelSet:IsValid() then
            log(string.format(
                "  Fuel %.1f / %.1f",
                getAttribute(fuelSet, "Fuel") or -1,
                getAttribute(fuelSet, "FuelMax") or -1
            ))
        end
    else
        log("Ship fuel toggle: no BP_SmallBoat_V2_C found")
    end
    notify(string.format("Infinite ship fuel: %s", state.infiniteFuel and "ON" or "OFF"))
end

local widgetLibrary = nil
local cheatPanelWidget = nil

local function getWidgetLibrary()
    if widgetLibrary and widgetLibrary:IsValid() then return widgetLibrary end
    widgetLibrary = nil
    local ok, found = pcall(function()
        return StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    end)
    if ok and found and found:IsValid() then
        widgetLibrary = found
        return found
    end
    return nil
end

-- TSoftClassPtr is exposed as userdata in UE4SS 4.x, not as a string. The
-- underlying FSoftObjectPath exposes these accessors; FName/FString results
-- need ToString() before they can be handed to LoadClassAsset_Blocking.
local function softMethod(value, method)
    local ok, result = pcall(function() return value[method](value) end)
    if not ok or result == nil then return nil end
    if type(result) == "string" then return result end
    local textOk, text = pcall(function() return result:ToString() end)
    if textOk and type(text) == "string" and text ~= "" then return text end
    return nil
end

local function softClassPath(value)
    if value == nil then return nil end
    if type(value) == "string" then
        if value ~= "" and value ~= "None" then return value end
        return nil
    end
    if type(value) ~= "table" and type(value) ~= "userdata" then return nil end

    -- Already resolved to a class: its full name is a loadable class path.
    local classOk, resolved = pcall(function() return value:Get() end)
    if classOk and resolved ~= nil then
        local fullOk, fullName = pcall(function() return resolved:GetFullName() end)
        if fullOk and type(fullName) == "string" and fullName ~= "" then
            return fullName
        end
    end

    local asset = softMethod(value, "GetAssetPathName")
        or softMethod(value, "GetAssetPathString")
        or softMethod(value, "GetPathName")
        or softMethod(value, "ToString")

    -- FSoftObjectPath in UE 4.x is a struct with these members.
    if not asset and type(value) == "table" then
        for _, key in ipairs({ "AssetPathName", "AssetPath", "Path" }) do
            local field = value[key]
            if field ~= nil then
                if type(field) == "string" then
                    asset = field
                else
                    asset = softMethod(field, "ToString")
                end
                if asset and asset ~= "" and asset ~= "None" then break end
                asset = nil
            end
        end
    end

    if not asset or asset == "" or asset == "None" then return nil end

    local subPath = softMethod(value, "GetSubPathString")
    if subPath and subPath ~= "" then
        asset = asset .. ":" .. subPath
    end
    return asset
end

-- The retail controller ships with an empty CheatPanelClass, but the widget
-- asset itself is cooked (WBP_CheatPanel.uasset). Ask the Asset Registry for
-- its real package path once, then remember the generated-class path. This
-- keeps F11 working without hardcoding a folder that may change between
-- patches.
local cheatPanelClassPath = nil -- false means "looked up and not found"

-- Discovered from the cooked package index (Dreadmoor-Windows.utoc). This is
-- the first place the retail build ships WBP_CheatPanel; the Asset Registry
-- scan below is the fallback if the path changes between patches.
local CHEAT_PANEL_CLASS_CANDIDATES = {
    "/Game/Dreadmoor/UI/Debug/WBP_CheatPanel.WBP_CheatPanel_C",
}

local function assetObjectName(helpers, data)
    local fullName = nil
    pcall(function() fullName = helpers:GetFullName(data) end)
    if type(fullName) ~= "string" then
        fullName = softMethod(fullName, "ToString")
    end
    if type(fullName) == "string" and fullName ~= "" then
        return fullName
    end

    -- FAssetData in UE 5.1+ stores the path as PackageName + AssetName. Fall
    -- back to those fields if GetFullName was not callable on this build.
    local packageName = nil
    pcall(function() packageName = data.PackageName end)
    packageName = deref(packageName)
    if type(packageName) ~= "string" then
        packageName = softMethod(packageName, "ToString")
    end
    local assetName = nil
    pcall(function() assetName = data.AssetName end)
    assetName = deref(assetName)
    if type(assetName) ~= "string" then
        assetName = softMethod(assetName, "ToString")
    end
    if type(packageName) == "string" and type(assetName) == "string"
        and packageName ~= "" and assetName ~= "" then
        return packageName .. "." .. assetName
    end
    return nil
end

local function findCheatPanelClassPath()
    if cheatPanelClassPath ~= nil then
        return cheatPanelClassPath or nil
    end

    local helpers = nil
    local helpersOk = pcall(function()
        helpers = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
    end)
    if not helpersOk or not helpers or not helpers:IsValid() then
        log("Cheat panel lookup: AssetRegistryHelpers unavailable")
        cheatPanelClassPath = false
        return nil
    end

    local registry = nil
    local registryOk = pcall(function() registry = helpers:GetAssetRegistry() end)
    registry = deref(registry)
    if not registryOk or not registry then
        log("Cheat panel lookup: asset registry unavailable")
        cheatPanelClassPath = false
        return nil
    end

    local assets = {}
    local scanPath = "/Game"
    pcall(function() scanPath = UEHelpers.FindOrAddFName("/Game") end)

    -- Interface UFunctions are not always reachable through the object's
    -- method table, so try the reflected UFunction explicitly first. UE4SS
    -- lets a context-free UFunction be called with the object as first arg.
    local assetsByPath = nil
    pcall(function()
        assetsByPath = StaticFindObject("/Script/AssetRegistry.AssetRegistry:GetAssetsByPath")
    end)

    local scanOk, scanErr = false, nil
    if assetsByPath and assetsByPath:IsValid() then
        scanOk, scanErr = pcall(function()
            assetsByPath(registry, scanPath, assets, true, true)
        end)
    end
    if not scanOk then
        assets = {}
        scanOk, scanErr = pcall(function()
            registry:GetAssetsByPath(scanPath, assets, true, true)
        end)
    end

    -- If the interface call succeeded but returned nothing, try the simpler
    -- GetAllAssets entry point before giving up.
    if scanOk and #assets == 0 then
        assets = {}
        local allAssets = nil
        pcall(function()
            allAssets = StaticFindObject("/Script/AssetRegistry.AssetRegistry:GetAllAssets")
        end)
        if allAssets and allAssets:IsValid() then
            scanOk, scanErr = pcall(function()
                allAssets(registry, assets, true)
            end)
        else
            scanOk, scanErr = pcall(function()
                registry:GetAllAssets(assets, true)
            end)
        end
    end

    if not scanOk then
        log("Cheat panel lookup: scan failed (" .. tostring(scanErr) .. ")")
        cheatPanelClassPath = false
        return nil
    end

    local total = #assets
    log(string.format("Cheat panel lookup: scanning %d assets", total))

    for index = 1, total do
        local data = deref(assets[index])
        local fullName = assetObjectName(helpers, data)
        if type(fullName) == "string" and fullName:find("WBP_CheatPanel", 1, true) then
            -- GetFullName returns /Package/Path/Asset.Asset; the generated
            -- class object is that same path with _C appended.
            local classPath = fullName
            if classPath:sub(-3) ~= "_C" then classPath = classPath .. "_C" end
            log("Cheat panel asset found: " .. classPath)
            cheatPanelClassPath = classPath
            return classPath
        end
    end

    log("Cheat panel lookup: WBP_CheatPanel not present in the asset registry")
    cheatPanelClassPath = false
    return nil
end

-- TSoftClassPtr values cannot be fabricated from a string directly, but
-- Kismet can turn a class path into one. Try the game-provided soft pointer
-- first, then rebuild it from the registry path, then fall back to the global
-- LoadAsset (which loads the package and makes the generated class findable).
local function loadWidgetClass(softRef, classPath)
    local kismet = kismetSystem()
    if not kismet then
        log("Cheat panel class load: KismetSystemLibrary unavailable")
        return nil
    end

    if softRef ~= nil and type(softRef) ~= "string" then
        local ok, class = pcall(function()
            return kismet:LoadClassAsset_Blocking(softRef)
        end)
        if ok and class and class:IsValid() then
            log("Cheat panel class loaded from the game soft pointer")
            return class
        end
    end

    if not classPath then return nil end

    local built = nil
    pcall(function()
        local softPath = kismet:MakeSoftClassPath(classPath)
        built = kismet:Conv_SoftClassPathToSoftClassRef(softPath)
    end)
    if built ~= nil then
        local ok, class = pcall(function()
            return kismet:LoadClassAsset_Blocking(built)
        end)
        if ok and class and class:IsValid() then
            log("Cheat panel class loaded from the registry path")
            return class
        end
    end

    local packagePath = classPath
    if packagePath:sub(-3) == "_C" then packagePath = packagePath:sub(1, -3) end
    if packagePath:find("%.") then
        packagePath = packagePath:gsub("%.[^%.]+$", "")
    end

    local loaded = nil
    local loadOk = pcall(function() loaded = LoadAsset(packagePath) end)
    loaded = deref(loaded)

    local class = nil
    pcall(function() class = StaticFindObject(classPath) end)
    class = deref(class)
    if class and class:IsValid() then
        log("Cheat panel class loaded via LoadAsset")
        return class
    end

    if loadOk and loaded and loaded:IsValid() then
        local generated = nil
        pcall(function() generated = loaded.GeneratedClass end)
        generated = deref(generated)
        if generated and generated:IsValid() then
            log("Cheat panel class resolved from the blueprint asset")
            return generated
        end

        local isClass = false
        pcall(function()
            isClass = loaded:IsA(findClass("/Script/CoreUObject.Class"))
        end)
        if isClass then
            log("Cheat panel class returned by LoadAsset")
            return loaded
        end
    end

    return nil
end

local function openCheatPanelDirect()
    local controller = getController()
    if not controller then return false end

    -- Pressing the key again closes the panel we created last time.
    if cheatPanelWidget and cheatPanelWidget:IsValid() then
        local removed = pcall(function()
            pcall(function() cheatPanelWidget:DeactivateWidget() end)
            cheatPanelWidget:RemoveFromParent()
        end)
        cheatPanelWidget = nil
        local library = getWidgetLibrary()
        if library then
            pcall(function()
                library:SetInputMode_GameOnly(controller, false)
            end)
        end
        pcall(function() controller:SetShowMouseCursor(false) end)
        if removed then
            log("Cheat panel widget closed")
            return true
        end
    end

    local rawClass = deref(tryGet(controller, "CheatPanelClass"))
    local classPath = softClassPath(rawClass)
    log(string.format(
        "CheatPanelClass lua=%s path=%s",
        type(rawClass),
        tostring(classPath)
    ))

    local softRef = nil
    if rawClass ~= nil and type(rawClass) ~= "string" then
        softRef = rawClass
    end

    if not classPath then
        -- These two are definitely set in the shipped game and open normally;
        -- logging them tells us whether soft-pointer reads work at all.
        for _, property in ipairs({ "PausePanelClass", "MapPanelClass" }) do
            local other = softClassPath(deref(tryGet(controller, property)))
            log(string.format("%s path=%s", property, tostring(other)))
        end
        log("CheatPanelClass is empty on the player controller, looking for the panel")

        -- The widget class may already be loaded even when the soft property
        -- was cleared for the retail build; FindObject needs only its name.
        local preloaded = nil
        pcall(function()
            preloaded = FindObject("WidgetBlueprintGeneratedClass", "WBP_CheatPanel_C")
        end)
        preloaded = deref(preloaded)
        if preloaded and preloaded:IsValid() then
            local fullName = nil
            pcall(function() fullName = preloaded:GetFullName() end)
            if type(fullName) ~= "string" then
                fullName = softMethod(fullName, "ToString")
            end
            if type(fullName) == "string" and fullName ~= "" then
                classPath = fullName
                log("Cheat panel class already loaded: " .. classPath)
            end
        end
        if not classPath then
            -- The cooked package index gives a reliable path; try it before
            -- paying for a full Asset Registry scan.
            for _, candidate in ipairs(CHEAT_PANEL_CLASS_CANDIDATES) do
                local candidateClass = loadWidgetClass(nil, candidate)
                if candidateClass then
                    classPath = candidate
                    break
                end
            end
        end
        if not classPath then
            classPath = findCheatPanelClassPath()
        end
    end

    if not classPath then
        log("Cheat panel class could not be resolved")
        return false
    end

    local panelClass = loadWidgetClass(softRef, classPath)
    if not panelClass then
        log("Failed to load cheat panel class: " .. tostring(classPath))
        return false
    end

    local library = getWidgetLibrary()
    if not library then
        log("WidgetBlueprintLibrary CDO not found")
        return false
    end

    local widget = nil
    local ok = pcall(function()
        widget = library:Create(controller, panelClass, controller)
    end)
    if not ok or not widget or not widget:IsValid() then
        log("Failed to create the cheat panel widget")
        return false
    end

    pcall(function() widget:AddToViewport(0) end)
    pcall(function() if widget.ActivateWidget then widget:ActivateWidget() end end)
    pcall(function() if widget.SetFocus then widget:SetFocus() end end)
    -- Created outside the game's CommonUI stack, so set the input mode here;
    -- otherwise the cursor is visible but the panel does not receive clicks.
    pcall(function()
        library:SetInputMode_GameAndUIEx(controller, widget, 0, false, false)
    end)
    pcall(function() controller:SetShowMouseCursor(true) end)
    cheatPanelWidget = widget
    log("Cheat panel widget created directly from " .. (classPath or "?"))
    return true
end

local function openCheatPanel()
    -- Creating the widget ourselves is deterministic; the BP event mainly
    -- loads the same soft class and pushes it. Fall back to the event if the
    -- direct route is unavailable.
    if openCheatPanelDirect() then
        notify("Cheat panel")
        return
    end
    local controller = getController()
    if controller and callDigitalEvent(controller, "InpActEvt_IA_Dev_CheatPanel_K2Node_EnhancedInputActionEvent_13", "IA_Dev_CheatPanel") then
        log("Cheat panel event fired (no direct widget)")
        notify("Cheat panel (event)")
    else
        notify("Cheat panel unavailable")
    end
end

local function quickSave()
    local controller = getController()
    if controller and callDigitalEvent(
        controller,
        "InpActEvt_IA_QuickSave_K2Node_EnhancedInputActionEvent_19",
        "IA_QuickSave"
    ) then
        notify("Quick save")
    else
        notify("Quick save unavailable")
    end
end

local function quickLoad()
    local controller = getController()
    if controller and callDigitalEvent(
        controller,
        "InpActEvt_IA_QuickLoad_K2Node_EnhancedInputActionEvent_18",
        "IA_QuickLoad"
    ) then
        notify("Quick load")
    else
        notify("Quick load unavailable")
    end
end

local function teleportToShipDirect()
    local pawn = getPawn()
    local ship = findShip()
    if not pawn or not ship then return false end

    local marker = tryGet(ship, "TeleportToOnUnpossess")
    if not marker or not marker:IsValid() then return false end

    local location = nil
    local rotation = nil
    pcall(function() location = marker:K2_GetComponentLocation() end)
    pcall(function() rotation = marker:K2_GetComponentRotation() end)
    if not location or not rotation then return false end

    log(string.format(
        "Teleport marker: %s at (%.0f, %.0f, %.0f)",
        marker:GetFullName(),
        location.X or 0,
        location.Y or 0,
        location.Z or 0
    ))

    local ok = pcall(function()
        pawn:K2_SetActorLocationAndRotation(location, rotation, false, {}, true)
    end)
    if not ok then
        log("Direct teleport failed")
    end
    return ok
end

local function teleportToShip()
    -- Direct move is deterministic; the dev event mainly handles the same
    -- teleport plus any UI/camera bookkeeping, so try the move first.
    if teleportToShipDirect() then
        notify("Teleported to ship")
        return
    end

    local controller = getController()
    if controller and callDigitalEvent(
        controller,
        "InpActEvt_IA_Dev_TeleportToShip_K2Node_EnhancedInputActionEvent_10",
        "IA_Dev_TeleportToShip"
    ) then
        log("Teleport event fired (direct move unavailable)")
        notify("Teleported to ship (event)")
    else
        notify("Teleport to ship unavailable")
    end
end

local function cycleSlowMotion()
    state.slowIndex = state.slowIndex + 1
    if state.slowIndex > #CONFIG.slowMotionScales then state.slowIndex = 1 end

    local scale = CONFIG.slowMotionScales[state.slowIndex]
    local context = getPawn() or getController()
    if not context then return end

    local ok, err = pcall(function()
        gameplayStatics():SetGlobalTimeDilation(context, scale)
    end)
    notify(string.format("Time dilation: %.2f", scale))
    log(string.format(
        "Time dilation %.2f | applied=%s%s",
        scale,
        tostring(ok),
        ok and "" or (" (" .. tostring(err) .. ")")
    ))
end

local SPEED_FIELDS = {
    "MaxWalkSpeed",
    "MaxWalkSpeedCrouched",
    "MaxSwimSpeed",
    "MaxFlySpeed",
}

local function restoreSpeed()
    local original = state.speedOrig
    if not original then return end

    if original.movement and original.movement:IsValid() then
        for _, field in ipairs(SPEED_FIELDS) do
            local base = original.base and original.base[field]
            if base ~= nil then trySet(original.movement, field, base) end
        end
    end

    if original.attributeSet and original.attributeSet:IsValid() then
        if original.walkSpeed ~= nil then
            setAttribute(original.attributeSet, "WalkSpeed", original.walkSpeed)
        end
        if original.runSpeed ~= nil then
            setAttribute(original.attributeSet, "RunSpeed", original.runSpeed)
        end
    end

    state.speedOrig = nil
end

local reapplySpeedMovement

local function applySpeed(pawn)
    local multiplier = CONFIG.speedMultipliers[state.speedIndex] or 1.0
    if multiplier <= 1.0001 then
        restoreSpeed()
        return
    end

    if not state.speedOrig or state.speedOrig.pawn ~= pawn then
        state.speedOrig = {
            pawn = pawn,
            movement = tryGet(pawn, "CharacterMovement"),
            attributeSet = tryGet(pawn, "AttributeSetPlayerChar"),
            base = {},
            last = {},
        }

        local original = state.speedOrig
        if original.movement and original.movement:IsValid() then
            for _, field in ipairs(SPEED_FIELDS) do
                local value = tryGet(original.movement, field)
                if type(value) == "number" then original.base[field] = value end
            end
        end
        if original.attributeSet and original.attributeSet:IsValid() then
            original.walkSpeed = getAttribute(original.attributeSet, "WalkSpeed")
            original.runSpeed = getAttribute(original.attributeSet, "RunSpeed")
        end
    end

    local original = state.speedOrig
    if not original then return end

    -- Scale the GAS attributes from their captured base values (sprint and
    -- stamina systems read these, not only CharacterMovement).
    if original.attributeSet and original.attributeSet:IsValid() then
        if original.walkSpeed ~= nil then
            setAttribute(original.attributeSet, "WalkSpeed", original.walkSpeed * multiplier)
        end
        if original.runSpeed ~= nil then
            setAttribute(original.attributeSet, "RunSpeed", original.runSpeed * multiplier)
        end
    end

    reapplySpeedMovement(pawn)
end

-- The game rewrites MaxWalkSpeed when sprinting / swimming. Instead of
-- forcing one cached value (which would cancel sprint), adopt any change the
-- game makes as a new baseline and scale that.
reapplySpeedMovement = function(pawn)
    local original = state.speedOrig
    if not original or original.pawn ~= pawn then return end
    local movement = original.movement
    if not movement or not movement:IsValid() then return end

    local multiplier = CONFIG.speedMultipliers[state.speedIndex] or 1.0
    for _, field in ipairs(SPEED_FIELDS) do
        local current = tryGet(movement, field)
        if type(current) == "number" then
            local lastApplied = original.last[field]
            if lastApplied == nil or math.abs(current - lastApplied) > 0.01 then
                original.base[field] = current
            end
            local base = original.base[field] or current
            local target = base * multiplier
            if math.abs(current - target) > 0.01 then
                trySet(movement, field, target)
            end
            original.last[field] = target
        end
    end
end

local function cycleSpeed()
    state.speedIndex = state.speedIndex + 1
    if state.speedIndex > #CONFIG.speedMultipliers then
        state.speedIndex = 1
    end
    local pawn = getPawn()
    if pawn then applySpeed(pawn) end
    local multiplier = CONFIG.speedMultipliers[state.speedIndex]
    notify(string.format("Speed: x%.1f", multiplier))
    if pawn then
        local movement = tryGet(pawn, "CharacterMovement")
        local set = tryGet(pawn, "AttributeSetPlayerChar")
        log(string.format(
            "Speed x%.1f | movement=%s walk=%.1f crouch=%.1f swim=%.1f | attrWalk=%.1f attrRun=%.1f",
            multiplier,
            tostring(movement and movement:IsValid()),
            movement and tryGet(movement, "MaxWalkSpeed") or -1,
            movement and tryGet(movement, "MaxWalkSpeedCrouched") or -1,
            movement and tryGet(movement, "MaxSwimSpeed") or -1,
            set and getAttribute(set, "WalkSpeed") or -1,
            set and getAttribute(set, "RunSpeed") or -1
        ))
    end
end

-- ============================================================================
-- Ship speed
-- ============================================================================

local SHIP_SPEED_FIELDS = {
    "MaxSpeed",
    "MaxBackwardSpeed",
    "AccelerationAtMinSpeed",
    "AccelerationAtMaxSpeed",
    "MaxAngularSpeed",
    "AngularAcceleration",
}

local function restoreShipSpeed()
    local original = state.shipSpeedOrig
    if not original then return end
    if original.set and original.set:IsValid() then
        for _, field in ipairs(SHIP_SPEED_FIELDS) do
            local base = original.base[field]
            if base ~= nil then setAttribute(original.set, field, base) end
        end
    end
    state.shipSpeedOrig = nil
end

local function applyShipSpeed()
    local multiplier = CONFIG.shipSpeedMultipliers[state.shipSpeedIndex] or 1.0
    if multiplier <= 1.0001 then
        restoreShipSpeed()
        return
    end

    local ship = findShip()
    if not ship then
        notify("Ship not found")
        return
    end

    if not state.shipSpeedOrig or state.shipSpeedOrig.ship ~= ship then
        state.shipSpeedOrig = {
            ship = ship,
            set = tryGet(ship, "AttributeSetShip"),
            base = {},
        }
        local set = state.shipSpeedOrig.set
        if set and set:IsValid() then
            for _, field in ipairs(SHIP_SPEED_FIELDS) do
                local value = getAttribute(set, field)
                if value ~= nil then state.shipSpeedOrig.base[field] = value end
            end
        end
    end

    local original = state.shipSpeedOrig
    if not original or not original.set or not original.set:IsValid() then
        notify("Ship attribute set unavailable")
        return
    end

    for _, field in ipairs(SHIP_SPEED_FIELDS) do
        local base = original.base[field]
        if base ~= nil then
            setAttribute(original.set, field, base * multiplier)
        end
    end
end

local function maintainShipSpeed()
    local original = state.shipSpeedOrig
    if not original then return end
    local set = original.set
    if not set or not set:IsValid() then return end

    local multiplier = CONFIG.shipSpeedMultipliers[state.shipSpeedIndex] or 1.0
    for _, field in ipairs(SHIP_SPEED_FIELDS) do
        local base = original.base[field]
        if base ~= nil then
            local current = getAttribute(set, field)
            local target = base * multiplier
            if current == nil or math.abs(current - target) > 0.01 then
                setAttribute(set, field, target)
            end
        end
    end
end

local function cycleShipSpeed()
    state.shipSpeedIndex = state.shipSpeedIndex + 1
    if state.shipSpeedIndex > #CONFIG.shipSpeedMultipliers then
        state.shipSpeedIndex = 1
    end
    applyShipSpeed()
    local multiplier = CONFIG.shipSpeedMultipliers[state.shipSpeedIndex]
    notify(string.format("Ship speed: x%.1f", multiplier))

    local ship = findShip()
    local set = ship and tryGet(ship, "AttributeSetShip") or nil
    log(string.format(
        "Ship speed x%.1f | ship=%s | set=%s | max=%.1f",
        multiplier,
        tostring(ship ~= nil),
        tostring(set and set:IsValid()),
        (set and getAttribute(set, "MaxSpeed")) or -1
    ))
end

local function repairShip()
    local ship = findShip()
    if not ship then
        notify("Ship not found")
        return false
    end

    local ok = pcall(function() ship:RestoreHealthOnRevive() end)
    pcall(function() ship:HealAllCosmeticHullElements(1000000.0) end)
    if ok then
        notify("Ship repaired")
        log("Ship repair requested: " .. ship:GetFullName())
    else
        notify("Ship repair unavailable")
    end
    return ok
end

-- ============================================================================
-- Flashlight (BP_PlayerCharacter.SpotLight / bFlashlightIsOn)
-- ============================================================================

local function toggleFlashlight()
    local pawn = getPawn()
    if not pawn then
        log("Flashlight: no pawn")
        return
    end

    local wasOn = tryGet(pawn, "bFlashlightIsOn")

    -- Prefer the game's own input handler so audio and the flag stay in sync.
    -- The Enhanced Input event is exposed as a non-callable object by UE4SS in
    -- this build, so calling it always fails. Keep the attempt as a best
    -- effort (it may work on a different UE4SS revision) but only trust its
    -- result when it actually succeeded.
    local eventOk = false
    if callDigitalEvent(pawn, "InpActEvt_IA_CharLight_K2Node_EnhancedInputActionEvent_2", "IA_CharLight") then
        eventOk = true
    end
    local nowOn = tryGet(pawn, "bFlashlightIsOn")
    if eventOk and nowOn ~= nil and nowOn ~= wasOn then
        notify(string.format("Flashlight: %s", nowOn and "ON" or "OFF"))
        log(string.format("Flashlight %s | event=%s", nowOn and "ON" or "OFF", tostring(eventOk)))
        return
    end

    -- Fallback: drive the spotlight component directly.
    local spot = tryGet(pawn, "SpotLight")
    local targetOn = not (wasOn == true)
    if spot and spot:IsValid() then
        -- Drive the component directly: visibility + active state + intensity.
        -- The game's own tick may override these, so also flip the flag the
        -- BP reads so the two stay in sync.
        pcall(function() spot:SetVisibility(targetOn, true) end)
        pcall(function() spot:SetHiddenInGame(not targetOn, true) end)
        pcall(function() spot:SetActive(targetOn) end)
        pcall(function()
            if targetOn then
                spot:SetIntensity(5000.0)
            else
                spot:SetIntensity(0.0)
            end
        end)
        trySet(pawn, "bFlashlightIsOn", targetOn)
        notify(string.format("Flashlight: %s", targetOn and "ON" or "OFF"))
        log(string.format(
            "Flashlight %s | direct fallback | event=%s | spot=%s",
            targetOn and "ON" or "OFF",
            tostring(eventOk),
            spot:GetFullName()
        ))
    else
        notify("Flashlight unavailable")
        log("Flashlight unavailable: SpotLight not found")
    end
end

-- ============================================================================
-- Time of day (Ultra_Dynamic_Sky_C)
-- ============================================================================

local skyCache = nil

local function findSky()
    if skyCache and skyCache:IsValid() then return skyCache end
    skyCache = nil
    local ok, sky = pcall(function() return FindFirstOf("Ultra_Dynamic_Sky_C") end)
    if ok and sky and sky:IsValid() then
        skyCache = sky
        return sky
    end
    return nil
end

local function setTimeOfDay(hour)
    local sky = findSky()
    if not sky then
        notify("Dynamic sky not found")
        return false
    end

    local ok, err = pcall(function()
        local transition = sky["Transition Time of Day"]
        if transition then
            -- New time, duration, easing (0 = linear), exponent, allow backwards.
            transition(sky, hour, 0.75, 0, 2.0, true)
        else
            sky["Time Of Day"] = hour
            local instant = sky["UDW Instant Update"]
            if instant then instant(sky) end
        end
    end)
    if not ok then
        log("Set time of day failed: " .. tostring(err))
        notify("Time of day unavailable")
        return false
    end

    notify(string.format("Time of day: %02d:00", math.floor(hour + 0.5) % 24))
    log(string.format("Time of day set to %.2f", hour))
    return true
end

local function cycleTimeOfDay()
    state.timeIndex = state.timeIndex + 1
    if state.timeIndex > #CONFIG.timeOfDayPresets then
        state.timeIndex = 1
    end
    setTimeOfDay(CONFIG.timeOfDayPresets[state.timeIndex])
end

-- ============================================================================
-- Graphics quality presets
-- ============================================================================

local QUALITY_COMMANDS = {
    "sg.ViewDistanceQuality %d",
    "sg.AntiAliasingQuality %d",
    "sg.ShadowQuality %d",
    "sg.GlobalIlluminationQuality %d",
    "sg.ReflectionQuality %d",
    "sg.PostProcessQuality %d",
    "sg.TextureQuality %d",
    "sg.EffectsQuality %d",
    "sg.FoliageQuality %d",
    "sg.ShadingQuality %d",
}

local function applyQualityLevel(level)
    local context = getPawn() or getController()
    if not context then return false end

    local controller = getController()
    local applied = false
    for _, command in ipairs(QUALITY_COMMANDS) do
        local ok = pcall(function()
            kismetSystem():ExecuteConsoleCommand(context, string.format(command, level), controller)
        end)
        applied = applied or ok
    end

    if applied then
        notify(string.format("Quality preset: %d", level))
        log(string.format("Quality preset set to %d", level))
    else
        notify("Quality preset failed")
    end
    return applied
end

local function cycleQuality()
    state.qualityIndex = state.qualityIndex + 1
    if state.qualityIndex > #CONFIG.qualityLevels then
        state.qualityIndex = 1
    end
    applyQualityLevel(CONFIG.qualityLevels[state.qualityIndex])
end

-- ============================================================================
-- Per-tick cheats
-- ============================================================================

local function maintainGodMode(pawn)
    local healthSet = tryGet(pawn, "AttributeSetHealth")
    if not healthSet or not healthSet:IsValid() then return end

    fillAttribute(healthSet, "Health", "MaxHealth")

    local radiation = getAttribute(healthSet, "Radiation")
    if radiation and radiation > 0 then
        setAttribute(healthSet, "Radiation", 0)
    end
end

local function maintainVitals(pawn)
    local characterSet = tryGet(pawn, "AttributeSetPlayerChar")
    if characterSet and characterSet:IsValid() then
        fillAttribute(characterSet, "Stamina", "StaminaMax")
    end

    -- The main player character does not own an oxygen attribute set; that
    -- lives on the diver character, which the player possesses only when
    -- diving. Search the world for any DrdAttributeSetOxygen owner (the diver
    -- pawn, or a shared component) and refill it too.
    local oxygenSet = tryGet(pawn, "OxygenAttributeSet")
    if not oxygenSet or not oxygenSet:IsValid() then
        oxygenSet = tryGet(pawn, "AttributeSetOxygen")
    end
    if not oxygenSet or not oxygenSet:IsValid() then
        local sets = nil
        pcall(function() sets = FindAllOf("DrdAttributeSetOxygen") end)
        if sets then
            for index = 1, #sets do
                local candidate = deref(sets[index])
                if candidate and candidate:IsValid() then
                    oxygenSet = candidate
                    break
                end
            end
        end
    end
    if oxygenSet and oxygenSet:IsValid() then
        fillAttribute(oxygenSet, "Oxygen", "MaxOxygen")
    end
end

local function maintainShipFuel()
    local ship = findShip()
    if not ship then return end
    local fuelSet = tryGet(ship, "AttributeSetShip")
    if not fuelSet or not fuelSet:IsValid() then return end
    fillAttribute(fuelSet, "Fuel", "FuelMax")
end

-- ============================================================================
-- Update loop
-- ============================================================================

local function updateInternal()
    state.tick = state.tick + 1

    local pawn = getPawn()

    if state.enabled then
        if pawn and isCharacter(pawn) then
            if state.rigPawn ~= pawn then
                destroyRig()
                ensureRig(pawn)
            end

            if state.rigPawn == pawn then
                if isSuspended(pawn) then
                    setRigActive(false)
                else
                    setRigActive(true)
                    enforceThirdPerson()
                end
            end
        else
            setRigActive(false)
            destroyRig()
        end
    else
        if state.rigPawn then destroyRig() end
    end

    if pawn and isCharacter(pawn) then
        if state.godMode then maintainGodMode(pawn) end
        if state.infiniteVitals then maintainVitals(pawn) end
        if state.speedIndex > 1 then
            if not state.speedOrig or state.speedOrig.pawn ~= pawn then
                applySpeed(pawn)
            else
                reapplySpeedMovement(pawn)
            end
        elseif state.speedOrig then
            restoreSpeed()
        end
    end

    if state.infiniteFuel then maintainShipFuel() end
    if state.shipSpeedIndex > 1 then maintainShipSpeed() end
end

local function onUpdate()
    local ok, err = pcall(updateInternal)
    if not ok then
        state.errorCount = state.errorCount + 1
        if state.errorCount <= 5 then
            log("Update error: " .. tostring(err))
        elseif state.errorCount == 6 then
            log("Further update errors suppressed")
        end
    end
end

-- ============================================================================
-- Status / help text
-- ============================================================================

local HELP_TEXT = table.concat({
    "DreadmoorTweaks",
    "F2  third person on/off     F4  shoulder preset",
    "PgUp/PgDn  distance         +/-  field of view",
    "Home  reset camera          End  camera collision",
    "F6  speed  F7  god  F8  vitals  F10  ship fuel",
    "F11 cheat panel   INS teleport to ship   DEL slow motion",
    "NUM1 flashlight  NUM2 time of day  NUM3 ship speed  NUM4 quality",
    "Console: dmt status tp hud cheat qsave qload god vitals fuel",
    "         speed shipspeed repair slowmo teleport flashlight time",
    "         quality shoulder collision reset dist <n> fov <n>",
}, "\n")

local function statusText()
    local pawn = getPawn()
    local lines = {}
    lines[#lines + 1] = "DreadmoorTweaks status"
    lines[#lines + 1] = string.format("Third person: %s", state.enabled and "ON" or "OFF")
    lines[#lines + 1] = string.format("Rig active: %s", state.rigActive and "yes" or "no")
    lines[#lines + 1] = string.format("Pawn: %s", pawn and pawn:GetFullName() or "none")
    lines[#lines + 1] = string.format(
        "Distance %.0f | FOV %.0f | Shoulder %s | Collision %s",
        state.armLength,
        state.fieldOfView,
        currentShoulder().label,
        state.collisionEnabled and "on" or "off"
    )
    lines[#lines + 1] = string.format(
        "God %s | Vitals %s | Fuel %s | Speed x%.1f | Slowmo %.2f",
        state.godMode and "on" or "off",
        state.infiniteVitals and "on" or "off",
        state.infiniteFuel and "on" or "off",
        CONFIG.speedMultipliers[state.speedIndex] or 1.0,
        CONFIG.slowMotionScales[state.slowIndex] or 1.0
    )
    lines[#lines + 1] = string.format(
        "Ship speed x%.1f | Quality %d | Invulnerable %s",
        CONFIG.shipSpeedMultipliers[state.shipSpeedIndex] or 1.0,
        CONFIG.qualityLevels[state.qualityIndex] or 0,
        tostring(isCheatInvulnerable())
    )
    return table.concat(lines, "\n")
end

local function printStatus()
    log(statusText())
end

-- ============================================================================
-- Console command: dmt
-- ============================================================================

RegisterConsoleCommandHandler("dmt", function(FullCommand, Parameters, OutputDevice)
    local subcommand = "help"
    if Parameters and Parameters[1] then
        subcommand = string.lower(Parameters[1])
    end

    local reply = function(message)
        if OutputDevice then
            pcall(function() OutputDevice:Log(tostring(message)) end)
        end
        log(message)
    end

    ExecuteInGameThread(function()
        local ok, err = pcall(function()
            if subcommand == "help" then
                reply(HELP_TEXT)
            elseif subcommand == "status" then
                reply(statusText())
            elseif subcommand == "tp" or subcommand == "thirdperson" then
                toggleThirdPerson()
                reply(string.format("Third person: %s", state.enabled and "ON" or "OFF"))
            elseif subcommand == "hud" then
                toggleHud()
                reply("HUD toggled")
            elseif subcommand == "cheat" then
                openCheatPanel()
                reply("Cheat panel requested")
            elseif subcommand == "qsave" or subcommand == "quicksave" then
                quickSave()
                reply("Quick save requested")
            elseif subcommand == "qload" or subcommand == "quickload" then
                quickLoad()
                reply("Quick load requested")
            elseif subcommand == "god" then
                toggleGodMode()
                reply(string.format("God mode: %s", state.godMode and "ON" or "OFF"))
            elseif subcommand == "vitals" then
                toggleInfiniteVitals()
                reply(string.format("Infinite vitals: %s", state.infiniteVitals and "ON" or "OFF"))
            elseif subcommand == "fuel" then
                toggleInfiniteFuel()
                reply(string.format("Infinite ship fuel: %s", state.infiniteFuel and "ON" or "OFF"))
            elseif subcommand == "flashlight" then
                toggleFlashlight()
                reply("Flashlight toggled")
            elseif subcommand == "time" then
                local value = tonumber(Parameters[2])
                if value then
                    setTimeOfDay(math.max(0, math.min(24, value)))
                else
                    cycleTimeOfDay()
                end
                reply("Time of day changed")
            elseif subcommand == "shipspeed" then
                cycleShipSpeed()
                reply(string.format("Ship speed: x%.1f", CONFIG.shipSpeedMultipliers[state.shipSpeedIndex]))
            elseif subcommand == "repair" then
                repairShip()
                reply("Ship repair requested")
            elseif subcommand == "quality" then
                local value = tonumber(Parameters[2])
                if value then
                    applyQualityLevel(math.floor(math.max(0, math.min(3, value))))
                else
                    cycleQuality()
                end
                reply(string.format("Quality preset: %d", CONFIG.qualityLevels[state.qualityIndex]))
            elseif subcommand == "speed" then
                cycleSpeed()
                reply(string.format("Speed: x%.1f", CONFIG.speedMultipliers[state.speedIndex]))
            elseif subcommand == "slowmo" then
                cycleSlowMotion()
                reply(string.format("Time dilation: %.2f", CONFIG.slowMotionScales[state.slowIndex]))
            elseif subcommand == "teleport" or subcommand == "ship" then
                teleportToShip()
                reply("Teleport requested")
            elseif subcommand == "shoulder" then
                cycleShoulder()
                reply(string.format("Shoulder: %s", currentShoulder().label))
            elseif subcommand == "collision" then
                toggleCollision()
                reply(string.format("Camera collision: %s", state.collisionEnabled and "ON" or "OFF"))
            elseif subcommand == "reset" then
                resetCamera()
                reply("Camera reset")
            elseif subcommand == "dist" then
                local value = tonumber(Parameters[2])
                if value then
                    state.armLength = math.max(CONFIG.minArmLength, math.min(CONFIG.maxArmLength, value))
                    applyCameraSettings()
                end
                reply(string.format("Camera distance: %.0f", state.armLength))
            elseif subcommand == "fov" then
                local value = tonumber(Parameters[2])
                if value then
                    state.fieldOfView = math.max(CONFIG.minFieldOfView, math.min(CONFIG.maxFieldOfView, value))
                    applyCameraSettings()
                end
                reply(string.format("Camera FOV: %.0f", state.fieldOfView))
            else
                reply(string.format("Unknown subcommand '%s'. Try: dmt help", subcommand))
            end
        end)

        if not ok then
            reply("dmt error: " .. tostring(err))
        end
    end)

    return true
end)

-- ============================================================================
-- Key binds
-- ============================================================================

local function bind(key, callback, modifiers)
    local handler = function()
        ExecuteInGameThread(function()
            local ok, err = pcall(callback)
            if not ok then
                log("Keybind error: " .. tostring(err))
            end
        end)
    end

    local ok, err
    if modifiers then
        ok, err = pcall(function() RegisterKeyBind(key, modifiers, handler) end)
    else
        ok, err = pcall(function() RegisterKeyBind(key, handler) end)
    end
    if not ok then
        log("Failed to bind " .. tostring(key) .. ": " .. tostring(err))
    end
end

bind(Key.F1, function()
    log(HELP_TEXT)
    printStatus()
    notify("DreadmoorTweaks: F2 third person, F1 help in log", 4.0)
end)
bind(Key.F2, toggleThirdPerson)
bind(Key.F4, cycleShoulder)
bind(Key.PAGE_UP, function() adjustDistance(CONFIG.armLengthStep) end)
bind(Key.PAGE_DOWN, function() adjustDistance(-CONFIG.armLengthStep) end)
bind(Key.OEM_PLUS, function() adjustFieldOfView(CONFIG.fovStep) end)
bind(Key.OEM_MINUS, function() adjustFieldOfView(-CONFIG.fovStep) end)
bind(Key.HOME, resetCamera)
bind(Key.END, toggleCollision)
bind(Key.F6, cycleSpeed)
bind(Key.F7, toggleGodMode)
bind(Key.F8, toggleInfiniteVitals)
bind(Key.F10, toggleInfiniteFuel)
bind(Key.F11, openCheatPanel)
bind(Key.INS, teleportToShip)
bind(Key.DEL, cycleSlowMotion)
bind(Key.NUM_ONE, toggleFlashlight)
bind(Key.NUM_TWO, cycleTimeOfDay)
bind(Key.NUM_THREE, cycleShipSpeed)
bind(Key.NUM_FOUR, cycleQuality)

-- ============================================================================
-- Startup
-- ============================================================================

local updateHandle = LoopInGameThreadWithDelay(CONFIG.updateIntervalMs, onUpdate)
if not updateHandle then
    log("Failed to start the update loop; the mod will not work")
end

log("Loaded. Press F1 for help, F2 for third person.")
if CONFIG.startEnabled then
    log("startEnabled = true: third person will engage when the player character is ready")
end
