local UEHelpers = require("UEHelpers")
local LOCAL_APP_DATA = os.getenv("LOCALAPPDATA") or "."
local IPC_DIR = LOCAL_APP_DATA .. "\\Voyage\\Saved\\LastCaretakerCoop"
local OUTBOUND_PATH = IPC_DIR .. "\\outgoing.pose"
local INBOUND_PATH = IPC_DIR .. "\\incoming.pose"
local poseEpoch = tostring(os.time()) .. "-" .. tostring({})
local outputSequence = 0
local lastRemoteId = nil
local lastRemoteEpoch = nil
local lastRemoteSequence = -1
local latestRemotePose = nil
local lastRemotePacketAt = 0
local remoteController = nil
local remotePawn = nil
local localPlayerController = nil
local remoteCreateWarningShown = false
local remoteTransformWarningShown = false
local ioWarningShown = false
local rotationWarningShown = false

local function log(message)
    print("[LastCaretakerCoop] " .. tostring(message) .. "\n")
end

local function describeObject(label, object)
    if object == nil then
        log(label .. "=<nil>")
        return
    end

    local ok, value = pcall(function()
        if not object:IsValid() then
            return "<invalid>"
        end
        return object:GetFullName()
    end)

    if ok then
        log(label .. "=" .. tostring(value))
    else
        log(label .. "=<read failed: " .. tostring(value) .. ">")
    end
end

local function findValidObject(label, readValue)
    local ok, object = pcall(readValue)
    if not ok then
        log(label .. "=<read failed: " .. tostring(object) .. ">")
        return nil
    end
    if object == nil then
        log(label .. "=<nil>")
        return nil
    end

    local validOk, isValid = pcall(function()
        return object:IsValid()
    end)
    if validOk and isValid then
        describeObject(label, object)
        return object
    end

    log(label .. "=<invalid>")
    return nil
end

local function isValidObject(object)
    if object == nil then
        return false
    end
    local ok, valid = pcall(function()
        return object:IsValid()
    end)
    return ok and valid
end

local function getLocalPlayerController()
    if isValidObject(localPlayerController) then
        return localPlayerController
    end

    local candidate = UEHelpers:GetPlayerController()
    if isValidObject(candidate) and candidate ~= remoteController then
        localPlayerController = candidate
    end
    return localPlayerController
end

local function readNumberField(structure, candidates)
    for _, key in ipairs(candidates) do
        local ok, value = pcall(function()
            return structure[key]
        end)
        if ok and type(value) == "number" then
            return value, tostring(key)
        end
    end
    return nil, "<none>"
end

local function readVectorComponents(vector)
    local x = readNumberField(vector, {"X", "x", 1})
    local y = readNumberField(vector, {"Y", "y", 2})
    local z = readNumberField(vector, {"Z", "z", 3})
    return x, y, z
end

local function readRotationComponents(rotation)
    -- UE4SS usually exposes the reflected FRotator members by name. Keep the
    -- alternate keys here so a build with a different struct wrapper won't
    -- abort the probe or the pose loop.
    local pitch = readNumberField(rotation, {"Pitch", "pitch", "X", "x", 1})
    local yaw = readNumberField(rotation, {"Yaw", "yaw", "Y", "y", 2})
    local roll = readNumberField(rotation, {"Roll", "roll", "Z", "z", 3})
    return pitch, yaw, roll
end

local function describeRotationAccess(rotation)
    local pitch, pitchKey = readNumberField(rotation, {"Pitch", "pitch", "X", "x", 1})
    local yaw, yawKey = readNumberField(rotation, {"Yaw", "yaw", "Y", "y", 2})
    local roll, rollKey = readNumberField(rotation, {"Roll", "roll", "Z", "z", 3})
    local ok, structType = pcall(function()
        return rotation:type()
    end)
    if not ok then
        structType = type(rotation)
    end
    log(string.format("RotationFields type=%s pitch=%s[%s] yaw=%s[%s] roll=%s[%s]",
        tostring(structType), tostring(pitch), pitchKey, tostring(yaw), yawKey, tostring(roll), rollKey))
end

local function probePlayer()
    local ok, err = pcall(function()
        local controller = getLocalPlayerController()
        if not isValidObject(controller) then
            log("No valid player controller yet; load into a save and try again.")
            return
        end

        local pawn = controller.Pawn
        if pawn == nil or not pawn:IsValid() then
            log("The player controller has no valid pawn yet.")
            return
        end

        local location = pawn:K2_GetActorLocation()
        local rotation = pawn:K2_GetActorRotation()
        local pawnClass = pawn:GetClass()

        describeObject("Pawn", pawn)
        describeObject("PawnClass", pawnClass)

        if location ~= nil then
            local x, y, z = readVectorComponents(location)
            local pitch, yaw, roll = readRotationComponents(rotation)
            if x ~= nil and y ~= nil and z ~= nil then
                if pitch ~= nil and yaw ~= nil and roll ~= nil then
                    log(string.format(
                        "Transform location=(%.2f, %.2f, %.2f) rotation=(%.2f, %.2f, %.2f)",
                        x, y, z, pitch, yaw, roll
                    ))
                else
                    log(string.format("Transform location=(%.2f, %.2f, %.2f) rotation=<unreadable>", x, y, z))
                    describeRotationAccess(rotation)
                end
            else
                log("Transform=<location fields unavailable>")
            end
        else
            log("Transform=<unavailable>")
        end

        -- UE character blueprints commonly expose their body as Mesh. The probe
        -- treats this as optional because the exact pawn class is build-specific.
        local mesh = pawn.Mesh
        describeObject("PawnMesh", mesh)
        if mesh ~= nil and mesh:IsValid() then
            -- Confirmed on the current game build: SkeletalMesh is the valid
            -- reflected property; SkeletalMeshAsset exists but is invalid.
            local meshAsset = findValidObject("PawnMeshAsset", function()
                return mesh.SkeletalMesh
            end)
            if meshAsset == nil then
                meshAsset = findValidObject("PawnMeshAsset.GetSkeletalMeshAsset()", function()
                    return mesh:GetSkeletalMeshAsset()
                end)
            end
            if meshAsset == nil then
                meshAsset = findValidObject("PawnMesh.SkeletalMeshAsset", function()
                    return mesh.SkeletalMeshAsset
                end)
            end
            if meshAsset == nil then
                log("PawnMeshAsset=<not resolved from available UE4SS accessors>")
            end

            local animInstance = mesh:GetAnimInstance()
            describeObject("PawnAnimInstance", animInstance)
        end
    end)

    if not ok then
        log("Probe failed: " .. tostring(err))
    end
end

RegisterKeyBind(Key.F8, function()
        ExecuteInGameThread(probePlayer)
end)

RegisterConsoleCommandHandler("lccoop_probe", function()
    ExecuteInGameThread(probePlayer)
    return true
end)

local function reportRemotePose()
    if latestRemotePose == nil then
        log("No peer pose received yet. Start the LAN bridge on both PCs.")
        return
    end

    log(string.format("Peer transform location=(%.2f, %.2f, %.2f) rotation=(%.2f, %.2f, %.2f)",
        latestRemotePose.X, latestRemotePose.Y, latestRemotePose.Z,
        latestRemotePose.Pitch, latestRemotePose.Yaw, latestRemotePose.Roll))
end

RegisterKeyBind(Key.F9, function()
    ExecuteInGameThread(reportRemotePose)
end)

RegisterConsoleCommandHandler("lccoop_peer", function()
    ExecuteInGameThread(reportRemotePose)
    return true
end)

log("Loaded for the two-player prototype. In a loaded save, press F8 or run lccoop_probe.")

local function replaceSmallFile(path, contents)
    local tempPath = path .. ".tmp"
    local file = io.open(tempPath, "w")
    if file == nil then
        return false
    end

    file:write(contents)
    file:close()

    -- Windows rename does not replace an existing destination, so remove the
    -- old tiny IPC file first. A missed sample is harmless; the next tick writes
    -- a fresh one.
    os.remove(path)
    local renamed = os.rename(tempPath, path)
    return renamed ~= nil
end

local function writeLocalPose()
    local controller = getLocalPlayerController()
    if not isValidObject(controller) then
        return
    end

    local pawn = controller.Pawn
    if pawn == nil or not pawn:IsValid() then
        return
    end

    local location = pawn:K2_GetActorLocation()
    local rotation = pawn:K2_GetActorRotation()
    if location == nil or rotation == nil then
        return
    end

    local x, y, z = readVectorComponents(location)
    local pitch, yaw, roll = readRotationComponents(rotation)
    if x == nil or y == nil or z == nil or pitch == nil or yaw == nil or roll == nil then
        if not rotationWarningShown then
            rotationWarningShown = true
            log("Pose transmission paused because this build exposes an unreadable transform field; F8 records the field diagnostics.")
        end
        return
    end

    outputSequence = outputSequence + 1
    local line = string.format("%s,%d,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f\n",
        poseEpoch, outputSequence,
        x, y, z, pitch, yaw, roll)

    if not replaceSmallFile(OUTBOUND_PATH, line) and not ioWarningShown then
        ioWarningShown = true
        log("Pose bridge file is unavailable. Start coop_bridge.py first.")
    end
end

local function readRemotePose()
    local file = io.open(INBOUND_PATH, "r")
    if file == nil then
        return
    end

    local line = file:read("*l")
    file:close()
    if line == nil then
        return
    end

    local values = {}
    for value in line:gmatch("[^,]+") do
        values[#values + 1] = value
    end
    if #values ~= 9 then
        return
    end

    local peerId = values[1]
    local epoch = values[2]
    local sequence = tonumber(values[3])
    local x, y, z = tonumber(values[4]), tonumber(values[5]), tonumber(values[6])
    local pitch, yaw, roll = tonumber(values[7]), tonumber(values[8]), tonumber(values[9])
    if sequence == nil or x == nil or y == nil or z == nil
        or pitch == nil or yaw == nil or roll == nil then
        return
    end

    if peerId ~= lastRemoteId then
        if lastRemoteId ~= nil and remoteController ~= nil then
            local ok, err = pcall(function()
                UEHelpers:GetGameplayStatics():RemovePlayer(remoteController, true)
            end)
            if not ok then
                log("Could not remove the previous peer puppet: " .. tostring(err))
            end
            remoteController = nil
            remotePawn = nil
        end
        lastRemoteId = peerId
        lastRemoteEpoch = nil
        lastRemoteSequence = -1
        latestRemotePose = nil
        log("Receiving peer pose stream from " .. peerId .. ".")
    end

    if epoch ~= lastRemoteEpoch then
        lastRemoteEpoch = epoch
        lastRemoteSequence = -1
    end

    if sequence > lastRemoteSequence then
        lastRemoteSequence = sequence
        lastRemotePacketAt = os.time()
        -- The latest transform drives the presentation-only pawn on this
        -- game-thread tick.
        latestRemotePose = {
            X = x, Y = y, Z = z,
            Pitch = pitch, Yaw = yaw, Roll = roll
        }
    end
end

local function removeRemotePlayer(reason)
    if isValidObject(remoteController) then
        local ok, err = pcall(function()
            UEHelpers:GetGameplayStatics():RemovePlayer(remoteController, true)
        end)
        if not ok then
            log("Could not remove the remote player: " .. tostring(err))
            if isValidObject(remotePawn) then
                pcall(function() remotePawn:K2_DestroyActor() end)
            end
        end
    elseif isValidObject(remotePawn) then
        pcall(function() remotePawn:K2_DestroyActor() end)
    end

    remoteController = nil
    remotePawn = nil
    if reason ~= nil then
        log("Remote player removed: " .. reason)
    end
end

local function ensureRemotePlayer()
    if isValidObject(remoteController) then
        if not isValidObject(remotePawn) then
            local ok, pawn = pcall(function()
                return remoteController.Pawn
            end)
            if ok and isValidObject(pawn) then
                remotePawn = pawn
                pcall(function() remotePawn:SetActorEnableCollision(false) end)
                pcall(function() remotePawn:DisableInput(remoteController) end)
                local fullName = "<name unavailable>"
                pcall(function() fullName = remotePawn:GetFullName() end)
                log("Remote player pawn ready: " .. fullName .. " (collision and input disabled).")
            end
        end
        return isValidObject(remotePawn)
    end

    local localController = getLocalPlayerController()
    if not isValidObject(localController) then
        return false
    end

    local ok, newController = pcall(function()
        return UEHelpers:GetGameplayStatics():CreatePlayer(localController, 1, true)
    end)
    if not ok or not isValidObject(newController) then
        if not remoteCreateWarningShown then
            remoteCreateWarningShown = true
            log("Could not create the remote player controller: " .. tostring(newController))
        end
        return false
    end

    remoteCreateWarningShown = false
    remoteController = newController
    log("Created a local presentation-only player controller for the remote peer.")
    return ensureRemotePlayer()
end

local function applyRemotePose()
    if latestRemotePose == nil then
        return
    end
    if not ensureRemotePlayer() then
        return
    end

    local pose = latestRemotePose
    local ok, err = pcall(function()
        remotePawn:K2_SetActorLocationAndRotation(
            { X = pose.X, Y = pose.Y, Z = pose.Z },
            { Pitch = pose.Pitch, Yaw = pose.Yaw, Roll = pose.Roll },
            false, {}, false
        )
    end)
    if not ok and not remoteTransformWarningShown then
        remoteTransformWarningShown = true
        log("Could not move the remote player pawn: " .. tostring(err))
    end
end

local function poseTick()
    local ok, err = pcall(function()
        writeLocalPose()
        readRemotePose()
        if latestRemotePose ~= nil and lastRemotePacketAt > 0
            and os.time() - lastRemotePacketAt > 5 then
            latestRemotePose = nil
            lastRemotePacketAt = 0
            lastRemoteId = nil
            lastRemoteEpoch = nil
            lastRemoteSequence = -1
            removeRemotePlayer("peer pose timed out")
        else
            applyRemotePose()
        end
    end)
    if not ok and not ioWarningShown then
        ioWarningShown = true
        log("Pose bridge stopped: " .. tostring(err))
    end
end

local function schedulePoseTick()
    ExecuteWithDelay(100, function()
        ExecuteInGameThread(poseTick)
        schedulePoseTick()
    end)
end

schedulePoseTick()
