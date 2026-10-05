
if SERVER then
    AddCSLuaFile()
    util.AddNetworkString("HitmenEffects_VisualStart")
    util.AddNetworkString("HitmenEffects_VisualStop")
end

HitmenEffects = HitmenEffects or {}
HitmenEffects.Definitions = HitmenEffects.Definitions or {}
HitmenEffects._ActiveEntities = HitmenEffects._ActiveEntities
    or setmetatable({}, { __mode = "k" })

local Effects = HitmenEffects
local Definitions = Effects.Definitions
local ActiveEntities = Effects._ActiveEntities

local SPEED_FIELDS = {
    "Speed",
    "MoveSpeed",
    "WalkSpeed",
    "RunSpeed",
    "PowerSpeed",
    "SlowWalkSpeed",
    "SprintSpeed",
    "PowerRunSpeed"
}

local SPEED_ACCESSORS = {
    { key = "walk", getter = "GetWalkSpeed", setter = "SetWalkSpeed" },
    { key = "run", getter = "GetRunSpeed", setter = "SetRunSpeed" },
    { key = "slowWalk", getter = "GetSlowWalkSpeed", setter = "SetSlowWalkSpeed" },
    { key = "ladder", getter = "GetLadderClimbSpeed", setter = "SetLadderClimbSpeed" }
}

local NextVisualToken = 0
local ClientVisuals = {}

local function IsEntityType(entity, method)
    if not IsValid(entity) or not isfunction(entity[method]) then
        return false
    end

    local ok, result = pcall(entity[method], entity)
    return ok and result == true
end

local function LogError(context, err)
    ErrorNoHalt(
        "[Hitmen Effects] "
        .. tostring(context)
        .. ": "
        .. tostring(err)
        .. "\n"
    )
end

local function NearlyEqual(a, b)
    return isnumber(a)
        and isnumber(b)
        and math.abs(a - b) < 0.001
end

local function ReadField(entity, key)
    local value = entity[key]

    if isfunction(value) then
        return nil
    end

    return tonumber(value)
end

local function ReadGetter(entity, getterName)
    local getter = entity[getterName]

    if not isfunction(getter) then
        return nil
    end

    local ok, result = pcall(getter, entity)

    if ok then
        return tonumber(result)
    end

    return nil
end

local function ReconcileField(entity, state, key)
    local current = ReadField(entity, key)

    if current == nil then
        return state.baseFields[key]
    end

    local last = state.lastFields[key]

    if state.baseFields[key] == nil
        or (last ~= nil and not NearlyEqual(current, last))
    then
        state.baseFields[key] = current
    end

    return state.baseFields[key]
end

local function ReconcileAccessor(entity, state, accessor)
    local current = ReadGetter(entity, accessor.getter)

    if current == nil then
        return nil
    end

    local base = state.baseAccessors[accessor.key]
    local last = state.lastAccessors[accessor.key]

    if base == nil
        or (last ~= nil and not NearlyEqual(current, last))
    then
        state.baseAccessors[accessor.key] = current
    end

    return state.baseAccessors[accessor.key]
end

local function GetState(entity)
    local state = entity._HitmenEffectSpeedState

    if state then
        return state
    end

    state = {
        baseFields = {},
        lastFields = {},
        baseAccessors = {},
        lastAccessors = {},
        baseLocoSpeed = nil,
        lastLocoSpeed = nil,
        baseNPCMaxSpeed = nil,
        lastNPCMaxSpeed = nil,
        baseNPCArrivalSpeed = nil,
        lastNPCArrivalSpeed = nil,
        baseNPCGroundSpeed = nil,
        lastNPCGroundSpeed = nil
    }

    for _, key in ipairs(SPEED_FIELDS) do
        state.baseFields[key] = ReadField(entity, key)
    end

    for _, accessor in ipairs(SPEED_ACCESSORS) do
        if isfunction(entity[accessor.getter])
            and isfunction(entity[accessor.setter])
        then
            state.baseAccessors[accessor.key] =
                ReadGetter(entity, accessor.getter)
        end
    end

    entity._HitmenEffectSpeedState = state

    return state
end

local function GetEffectRecords(entry)
    if not istable(entry) then
        return {}
    end

    if entry.id ~= nil then
        return { entry }
    end

    return entry
end

local function ForEachEffectRecord(active, callback)
    for id, entry in pairs(active or {}) do
        if not istable(entry) then
            continue
        end

        if entry.id ~= nil then
            callback(id, entry)
        else
            for _, record in ipairs(entry) do
                if istable(record) and record.id ~= nil then
                    callback(id, record)
                end
            end
        end
    end
end

local function GetLatestRecord(entry)
    if not istable(entry) then
        return nil
    end

    if entry.id ~= nil then
        return entry
    end

    return entry[#entry]
end

local function AddEffectRecord(active, id, record)
    local entry = active[id]

    if entry == nil then
        active[id] = record
    elseif entry.id ~= nil then
        active[id] = { entry, record }
    else
        entry[#entry + 1] = record
    end
end

local function GetRecordSpeedMultiplier(record)
    local definition = Definitions[record.id] or record.definition

    if not istable(definition) then
        return 1
    end

    local multiplier

    if record.useOverallMultiplierForSpeed then
        multiplier = record.multiplier

        if multiplier == nil then
            multiplier = definition.multiplier
        end
    else
        multiplier = record.speedMultiplier

        if multiplier == nil then
            multiplier = definition.speedMultiplier
        end
    end

    return math.max(tonumber(multiplier) or 1, 0)
end

local function GetCombinedSpeedMultiplier(entity)
    local combined = 1

    ForEachEffectRecord(entity._HitmenEffects, function(id, record)
        local definition = Definitions[id] or record.definition

        if not istable(definition) then
            return
        end

        record.definition = definition
        combined = combined * GetRecordSpeedMultiplier(record)
    end)

    return math.max(combined, 0)
end

local function ApplyField(entity, state, key, multiplier)
    local base = ReconcileField(entity, state, key)

    if base == nil then
        return false
    end

    local result = math.max(base * multiplier, 0)

    entity[key] = result
    state.lastFields[key] = result

    return true
end

local function HasCustomSpeedFields(state)
    for _, key in ipairs(SPEED_FIELDS) do
        if state.baseFields[key] ~= nil then
            return true
        end
    end

    return false
end

local function ApplySpeedAccessors(entity, state, multiplier)
    local appliedAny = false

    for _, accessor in ipairs(SPEED_ACCESSORS) do
        local getter = entity[accessor.getter]
        local setter = entity[accessor.setter]

        if not isfunction(getter) or not isfunction(setter) then
            continue
        end

        local base = ReconcileAccessor(entity, state, accessor)

        if base == nil then
            continue
        end

        local result = math.max(base * multiplier, 0)
        local ok, err = pcall(setter, entity, result)

        if ok then
            state.lastAccessors[accessor.key] = result
            appliedAny = true
        else
            LogError(accessor.setter, err)
        end
    end

    return appliedAny
end

local function GetFallbackNextBotSpeed(entity)
    local candidates = {
        "RunSpeed",
        "PowerRunSpeed",
        "PowerSpeed",
        "WalkSpeed",
        "Speed",
        "MoveSpeed"
    }

    for _, key in ipairs(candidates) do
        local value = ReadField(entity, key)

        if value and value > 0 then
            return value
        end
    end

    return nil
end

local function ApplyNextBotSpeed(entity, state, multiplier)
    local loco = entity.loco

    if not loco
        or not isfunction(loco.GetDesiredSpeed)
        or not isfunction(loco.SetDesiredSpeed)
    then
        return
    end

    local ok, current = pcall(loco.GetDesiredSpeed, loco)

    if not ok or not isnumber(current) then
        return
    end

    if state.baseLocoSpeed == nil then
        state.baseLocoSpeed = current > 0
            and current
            or GetFallbackNextBotSpeed(entity)
    elseif state.lastLocoSpeed ~= nil
        and not NearlyEqual(current, state.lastLocoSpeed)
    then
        state.baseLocoSpeed = current > 0
            and current
            or GetFallbackNextBotSpeed(entity)
    end

    local base = state.baseLocoSpeed
        or GetFallbackNextBotSpeed(entity)

    if not base or base < 0 then
        return
    end

    local result = math.max(base * multiplier, 0)
    local setOK, err = pcall(loco.SetDesiredSpeed, loco, result)

    if setOK then
        state.lastLocoSpeed = result
    else
        LogError("loco:SetDesiredSpeed", err)
    end
end

local function ApplyNPCSpeed(entity, state, multiplier)
    if isfunction(entity.GetMaxSpeed)
        and isfunction(entity.SetMaxSpeed)
    then
        local ok, current = pcall(entity.GetMaxSpeed, entity)

        if ok and isnumber(current) then
            if state.baseNPCMaxSpeed == nil
                or (
                    state.lastNPCMaxSpeed ~= nil
                    and not NearlyEqual(current, state.lastNPCMaxSpeed)
                )
            then
                state.baseNPCMaxSpeed = current
            end

            local result = math.max(
                state.baseNPCMaxSpeed * multiplier,
                0
            )

            if pcall(entity.SetMaxSpeed, entity, result) then
                state.lastNPCMaxSpeed = result
            end
        end
    end

    if isfunction(entity.GetArrivalSpeed)
        and isfunction(entity.SetArrivalSpeed)
    then
        local ok, current = pcall(entity.GetArrivalSpeed, entity)

        if ok and isnumber(current) then
            if state.baseNPCArrivalSpeed == nil
                or (
                    state.lastNPCArrivalSpeed ~= nil
                    and not NearlyEqual(current, state.lastNPCArrivalSpeed)
                )
            then
                state.baseNPCArrivalSpeed = current
            end

            local result = math.max(
                state.baseNPCArrivalSpeed * multiplier,
                0
            )

            if pcall(entity.SetArrivalSpeed, entity, result) then
                state.lastNPCArrivalSpeed = result
            end
        end
    end

    if isfunction(entity.GetInternalVariable)
        and isfunction(entity.SetSaveValue)
    then
        local ok, current = pcall(
            entity.GetInternalVariable,
            entity,
            "m_flGroundSpeed"
        )

        current = ok and tonumber(current) or nil

        if current then
            if state.baseNPCGroundSpeed == nil
                or (
                    state.lastNPCGroundSpeed ~= nil
                    and not NearlyEqual(current, state.lastNPCGroundSpeed)
                )
            then
                state.baseNPCGroundSpeed = current
            end

            local result = math.max(
                state.baseNPCGroundSpeed * multiplier,
                0
            )

            if pcall(
                entity.SetSaveValue,
                entity,
                "m_flGroundSpeed",
                result
            ) then
                state.lastNPCGroundSpeed = result
            end
        end
    end
end

local function ApplySpeed(entity)
    if not IsValid(entity) then
        return
    end

    local active = entity._HitmenEffects
    local state = entity._HitmenEffectSpeedState

    if not istable(active) or table.IsEmpty(active) then
        if not state then
            ActiveEntities[entity] = nil
            return
        end
    else
        state = GetState(entity)
    end

    if not state then
        return
    end

    local multiplier = GetCombinedSpeedMultiplier(entity)
    local hasCustomFields = HasCustomSpeedFields(state)

    for _, key in ipairs(SPEED_FIELDS) do
        ApplyField(entity, state, key, multiplier)
    end

    local hasAccessors = ApplySpeedAccessors(
        entity,
        state,
        multiplier
    )

    if entity.IsLambdaPlayer == true then
        entity.l_nextspeedupdate = 0
    elseif IsEntityType(entity, "IsPlayer") then
        -- Player movement is controlled by speed accessors.
    elseif IsEntityType(entity, "IsNPC") then
        if not hasCustomFields and not hasAccessors then
            ApplyNPCSpeed(entity, state, multiplier)
        end
    elseif IsEntityType(entity, "IsNextBot") then
        if not hasCustomFields and not hasAccessors then
            ApplyNextBotSpeed(entity, state, multiplier)
        end
    end

    if not active or table.IsEmpty(active) then
        entity._HitmenEffectSpeedState = nil
        ActiveEntities[entity] = nil
    else
        ActiveEntities[entity] = true
    end
end

local function ParseOptions(durationOrOptions, multiplierOverride)
    local options = {}

    if istable(durationOrOptions) then
        options = table.Copy(durationOrOptions)
    elseif isnumber(durationOrOptions) then
        options.duration = durationOrOptions
    end

    if multiplierOverride ~= nil then
        options.multiplier = multiplierOverride
    end

    return options
end

local function NormalizeID(id)
    if not isstring(id) then
        return nil
    end

    id = string.lower(string.Trim(id))

    if id == "" then
        return nil
    end

    return id
end

-- Particle visuals ------------------------------------------------------------

-- A missing bone means all valid bones by default.
-- Use bone = "origin" to attach to the entity rather than its bones.
local function NormalizeParticles(particles)
    if not istable(particles) then
        return {}
    end

    -- Accept a single particle definition as well as a list.
    if particles.effect or particles.name or particles.particle then
        particles = { particles }
    end

    local result = {}

    for _, particle in ipairs(particles) do
        if not istable(particle) then
            continue
        end

        local effectName = particle.effect
            or particle.name
            or particle.particle

        if not isstring(effectName) or effectName == "" then
            continue
        end

        local bone = particle.bone

        if particle.allBones == true
            or bone == nil
            or bone == ""
        then
            bone = "*"
        elseif not isstring(bone) then
            bone = "*"
        end

        result[#result + 1] = {
            effect = effectName,
            bone = bone,
            offset = isvector(particle.offset)
                and particle.offset
                or Vector(0, 0, 0),
            angles = isangle(particle.angles)
                and particle.angles
                or Angle(0, 0, 0)
        }
    end

    return result
end

local function StopEffectVisuals(record)
    if not SERVER or not record.visualToken then
        return
    end

    net.Start("HitmenEffects_VisualStop")
    net.WriteUInt(record.visualToken, 32)
    net.Broadcast()

    record.visualToken = nil
end

local function StartEffectVisuals(entity, record, definition)
    if not SERVER or not IsValid(entity) then
        return
    end

    StopEffectVisuals(record)

    local particles = record.particleOverride

    if particles == nil then
        particles = definition.particles or definition.visuals
    end

    particles = NormalizeParticles(particles)

    if #particles == 0 then
        return
    end

    NextVisualToken = NextVisualToken + 1

    if NextVisualToken > 2147483646 then
        NextVisualToken = 1
    end

    record.visualToken = NextVisualToken

    net.Start("HitmenEffects_VisualStart")
    net.WriteEntity(entity)
    net.WriteUInt(record.visualToken, 32)
    net.WriteTable(particles)
    net.Broadcast()
end

if CLIENT then
    local function RemoveClientVisual(token)
        local visualSet = ClientVisuals[token]

        if not visualSet then
            return
        end

        for _, visual in ipairs(visualSet.anchors) do
            if IsValid(visual.anchor) then
                visual.anchor:StopParticles()
                visual.anchor:Remove()
            end
        end

        ClientVisuals[token] = nil
    end

    local function CreateParticleAnchor(entity, particle, boneIndex)
        local anchor = ClientsideModel(
            "models/props_junk/PopCan01a.mdl",
            RENDERGROUP_OTHER
        )

        if not IsValid(anchor) then
            return nil
        end

        anchor:SetNoDraw(true)
        anchor:SetNotSolid(true)
        anchor:SetMoveType(MOVETYPE_NONE)

        local followingBone = false

        if boneIndex ~= nil
            and boneIndex >= 0
            and isfunction(anchor.FollowBone)
        then
            local ok = pcall(
                anchor.FollowBone,
                anchor,
                entity,
                boneIndex
            )

            followingBone = ok
        end

        if not followingBone then
            anchor:SetParent(entity)
        end

        anchor:SetLocalPos(particle.offset or vector_origin)
        anchor:SetLocalAngles(particle.angles or angle_zero)

        local ok, err = pcall(
            ParticleEffectAttach,
            particle.effect,
            PATTACH_ABSORIGIN_FOLLOW,
            anchor,
            0
        )

        if not ok then
            LogError("ParticleEffectAttach", err)
            anchor:Remove()
            return nil
        end

        return {
            anchor = anchor,
            owner = entity
        }
    end

    local function AddParticleForBone(entity, particle, boneIndex, visuals)
        local visual = CreateParticleAnchor(
            entity,
            particle,
            boneIndex
        )

        if visual then
            visuals[#visuals + 1] = visual
        end
    end

    net.Receive("HitmenEffects_VisualStart", function()
        local entity = net.ReadEntity()
        local token = net.ReadUInt(32)
        local particles = net.ReadTable()

        RemoveClientVisual(token)

        if not IsValid(entity) or not istable(particles) then
            return
        end

        local visuals = {}

        for _, particle in ipairs(particles) do
            if not istable(particle)
                or not isstring(particle.effect)
            then
                continue
            end

            local bone = particle.bone

            -- Missing bone names are treated as all bones.
            if bone == nil or bone == "" then
                bone = "*"
            end

            if bone == "*" or particle.allBones == true then
                local boneCount = 0

                if isfunction(entity.GetBoneCount) then
                    boneCount = entity:GetBoneCount() or 0
                end

                local createdForParticle = 0

                for boneIndex = 0, boneCount - 1 do
                    local boneName

                    if isfunction(entity.GetBoneName) then
                        boneName = entity:GetBoneName(boneIndex)
                    end

                    if not isstring(boneName)
                        or boneName == ""
                        or boneName == "__INVALIDBONE__"
                    then
                        continue
                    end

                    AddParticleForBone(
                        entity,
                        particle,
                        boneIndex,
                        visuals
                    )

                    createdForParticle = createdForParticle + 1
                end

                -- Models without usable bone data fall back to their origin.
                if createdForParticle == 0 then
                    AddParticleForBone(
                        entity,
                        particle,
                        -1,
                        visuals
                    )
                end
            elseif bone == "origin" then
                AddParticleForBone(
                    entity,
                    particle,
                    -1,
                    visuals
                )
            else
                local boneIndex = -1

                if isfunction(entity.LookupBone) then
                    boneIndex = entity:LookupBone(bone) or -1
                end

                AddParticleForBone(
                    entity,
                    particle,
                    boneIndex,
                    visuals
                )
            end
        end

        if #visuals > 0 then
            ClientVisuals[token] = {
                owner = entity,
                anchors = visuals
            }
        end
    end)

    net.Receive("HitmenEffects_VisualStop", function()
        local token = net.ReadUInt(32)
        RemoveClientVisual(token)
    end)

    hook.Add("Think", "HitmenEffects_ClientVisualCleanup", function()
        for token, visualSet in pairs(ClientVisuals) do
            local shouldRemove = not IsValid(visualSet.owner)

            if not shouldRemove then
                for _, visual in ipairs(visualSet.anchors) do
                    if not IsValid(visual.anchor) then
                        shouldRemove = true
                        break
                    end
                end
            end

            if shouldRemove then
                RemoveClientVisual(token)
            end
        end
    end)

    hook.Add("EntityRemoved", "HitmenEffects_ClientEntityRemoved", function(entity)
        for token, visualSet in pairs(ClientVisuals) do
            if visualSet.owner == entity then
                RemoveClientVisual(token)
            end
        end
    end)
end

-- Effect callbacks ------------------------------------------------------------

local function RunEffectCallback(entity, id, record, callbackName, ...)
    local definition = Definitions[id] or record.definition
    local callback = definition and definition[callbackName]

    if not isfunction(callback) then
        return
    end

    local ok, err = pcall(callback, entity, record, ...)

    if not ok then
        LogError(id .. "." .. callbackName, err)
    end
end

local function RemoveEffectRecord(entity, id, record, reason)
    if not IsValid(entity) then
        return false
    end

    local active = entity._HitmenEffects

    if not istable(active) then
        return false
    end

    local entry = active[id]

    if not istable(entry) then
        return false
    end

    if entry.id ~= nil then
        if entry ~= record then
            return false
        end

        active[id] = nil
    else
        local found = false

        for index, candidate in ipairs(entry) do
            if candidate == record then
                table.remove(entry, index)
                found = true
                break
            end
        end

        if not found then
            return false
        end

        if #entry == 0 then
            active[id] = nil
        elseif #entry == 1 then
            active[id] = entry[1]
        end
    end

    StopEffectVisuals(record)

    reason = reason or "removed"

    RunEffectCallback(entity, id, record, "OnRemove", reason)

    if reason == "expired" then
        RunEffectCallback(entity, id, record, "OnExpire", reason)
    end

    hook.Run("HitmenEffectRemoved", entity, id, record, reason)

    if table.IsEmpty(active) then
        entity._HitmenEffects = nil
    end

    ApplySpeed(entity)

    return true
end

function Effects.Register(id, definition)
    id = NormalizeID(id)

    if not id then
        return false, "Effect ID must be a non-empty string."
    end

    if not istable(definition) then
        return false, "Effect definition must be a table."
    end

    local stored = table.Copy(definition)

    stored.id = id
    stored.duration = math.max(tonumber(stored.duration) or 0, 0)
    stored.speedMultiplier = math.max(
        tonumber(stored.speedMultiplier) or 1,
        0
    )
    stored.multiplier = math.max(tonumber(stored.multiplier) or 1, 0)
    stored.stackable = stored.stackable == true
    stored.refreshable = stored.refreshable ~= false

    if stored.useOverallMultiplierForSpeed == nil then
        stored.useOverallMultiplierForSpeed =
            stored.useOverallMultiplier == true
            or stored.speedMultiplierUsesOverallMultiplier == true
    end

    Definitions[id] = stored

    for entity in pairs(ActiveEntities) do
        if not IsValid(entity) then
            continue
        end

        local active = entity._HitmenEffects

        if not istable(active) or active[id] == nil then
            continue
        end

        ForEachEffectRecord({ [id] = active[id] }, function(_, record)
            record.definition = stored

            if not record.multiplierOverridden then
                record.multiplier = stored.multiplier
            end

            if not record.speedMultiplierOverridden then
                record.speedMultiplier = stored.speedMultiplier
            end

            if not record.useOverallMultiplierOverridden then
                record.useOverallMultiplierForSpeed =
                    stored.useOverallMultiplierForSpeed == true
            end

            StartEffectVisuals(entity, record, stored)
        end)

        ApplySpeed(entity)
    end

    return true
end

function Effects.Unregister(id)
    id = NormalizeID(id)

    if not id or not Definitions[id] then
        return false
    end

    Definitions[id] = nil

    for entity in pairs(ActiveEntities) do
        if IsValid(entity)
            and entity._HitmenEffects
            and entity._HitmenEffects[id] ~= nil
        then
            Effects.Remove(entity, id, "unregistered")
        end
    end

    return true
end

function Effects.Apply(entity, id, durationOrOptions, multiplierOverride)
    if not SERVER or not IsValid(entity) then
        return false
    end

    id = NormalizeID(id)

    local definition = id and Definitions[id]

    if not definition then
        return false
    end

    local options = ParseOptions(durationOrOptions, multiplierOverride)
    local active = entity._HitmenEffects or {}
    local entry = active[id]
    local existingRecord = GetLatestRecord(entry)

    if existingRecord ~= nil
        and definition.stackable ~= true
        and definition.refreshable == false
    then
        return false, "This effect is already active and cannot be refreshed."
    end

    local isRefresh = existingRecord ~= nil
        and definition.stackable ~= true

    local record

    if isRefresh then
        record = existingRecord
    else
        record = {
            id = id,
            data = {}
        }
    end

    local duration = options.duration

    if duration == nil then
        duration = definition.duration
    end

    duration = math.max(tonumber(duration) or 0, 0)

    record.definition = definition
    record.duration = duration
    record.expiresAt = duration > 0
        and (CurTime() + duration)
        or nil

    if options.multiplier ~= nil then
        record.multiplier = math.max(
            tonumber(options.multiplier) or definition.multiplier,
            0
        )
        record.multiplierOverridden = true
    elseif not isRefresh then
        record.multiplier = definition.multiplier
        record.multiplierOverridden = false
    elseif not record.multiplierOverridden then
        record.multiplier = definition.multiplier
    end

    if options.speedMultiplier ~= nil then
        record.speedMultiplier = math.max(
            tonumber(options.speedMultiplier) or definition.speedMultiplier,
            0
        )
        record.speedMultiplierOverridden = true
    elseif not isRefresh then
        record.speedMultiplier = definition.speedMultiplier
        record.speedMultiplierOverridden = false
    elseif not record.speedMultiplierOverridden then
        record.speedMultiplier = definition.speedMultiplier
    end

    local useOverall = options.useOverallMultiplierForSpeed

    if useOverall == nil then
        useOverall = options.useOverallMultiplier
    end

    if useOverall == nil then
        useOverall = options.speedMultiplierUsesOverallMultiplier
    end

    if useOverall ~= nil then
        record.useOverallMultiplierForSpeed = tobool(useOverall)
        record.useOverallMultiplierOverridden = true
    elseif not isRefresh then
        record.useOverallMultiplierForSpeed =
            definition.useOverallMultiplierForSpeed == true

        record.useOverallMultiplierOverridden = false
    elseif not record.useOverallMultiplierOverridden then
        record.useOverallMultiplierForSpeed =
            definition.useOverallMultiplierForSpeed == true
    end

    if options.source ~= nil then
        record.source = options.source
    end

    if options.data ~= nil then
        record.data = options.data
    end

    -- Preserve per-application visual overrides on refresh.
    -- An empty particle table explicitly disables definition particles.
    if options.particles ~= nil then
        record.particleOverride = options.particles
    elseif not isRefresh then
        record.particleOverride = nil
    end

    if not isRefresh then
        AddEffectRecord(active, id, record)
    end

    entity._HitmenEffects = active
    ActiveEntities[entity] = true

    ApplySpeed(entity)
    StartEffectVisuals(entity, record, definition)

    local callbackName = isRefresh and "OnRefresh" or "OnApply"
    local callback = definition[callbackName]

    if isfunction(callback) then
        local ok, err = pcall(
            callback,
            entity,
            record,
            options,
            isRefresh
        )

        if not ok then
            LogError(id .. "." .. callbackName, err)
        end
    end

    hook.Run("HitmenEffectApplied", entity, id, record, isRefresh)

    return true, record
end

function Effects.Refresh(entity, id, durationOrOptions, multiplierOverride)
    return Effects.Apply(
        entity,
        id,
        durationOrOptions,
        multiplierOverride
    )
end

function Effects.Remove(entity, id, reason)
    if not SERVER or not IsValid(entity) then
        return false
    end

    id = NormalizeID(id)

    local active = entity._HitmenEffects
    local entry = id and active and active[id]

    if not entry then
        return false
    end

    local records = {}

    for _, record in ipairs(GetEffectRecords(entry)) do
        records[#records + 1] = record
    end

    reason = reason or "removed"

    for _, record in ipairs(records) do
        RemoveEffectRecord(entity, id, record, reason)
    end

    return #records > 0
end

function Effects.Clear(entity, reason)
    if not SERVER
        or not IsValid(entity)
        or not istable(entity._HitmenEffects)
    then
        return false
    end

    local ids = {}

    for id in pairs(entity._HitmenEffects) do
        ids[#ids + 1] = id
    end

    for _, id in ipairs(ids) do
        Effects.Remove(entity, id, reason or "cleared")
    end

    return #ids > 0
end

function Effects.Has(entity, id)
    id = NormalizeID(id)

    return IsValid(entity)
        and id ~= nil
        and entity._HitmenEffects ~= nil
        and entity._HitmenEffects[id] ~= nil
end

function Effects.Get(entity, id)
    if not IsValid(entity)
        or not istable(entity._HitmenEffects)
    then
        return nil
    end

    if id == nil then
        return entity._HitmenEffects
    end

    id = NormalizeID(id)

    if not id then
        return nil
    end

    return GetLatestRecord(entity._HitmenEffects[id])
end

function Effects.GetAll(entity, id)
    if not IsValid(entity)
        or not istable(entity._HitmenEffects)
    then
        return {}
    end

    local result = {}

    if id ~= nil then
        id = NormalizeID(id)

        if not id then
            return result
        end

        for _, record in ipairs(
            GetEffectRecords(entity._HitmenEffects[id])
        ) do
            result[#result + 1] = record
        end

        return result
    end

    ForEachEffectRecord(entity._HitmenEffects, function(_, record)
        result[#result + 1] = record
    end)

    return result
end

function Effects.GetMultiplier(entity, id)
    local record = Effects.Get(entity, id)

    return record and record.multiplier or nil
end

function Effects.GetSpeedMultiplier(entity)
    if not IsValid(entity) then
        return nil
    end

    return GetCombinedSpeedMultiplier(entity)
end

Effects.RegisterEffect = Effects.Register
Effects.ApplyEffect = Effects.Apply
Effects.RefreshEffect = Effects.Refresh
Effects.RemoveEffect = Effects.Remove
Effects.HasEffect = Effects.Has
Effects.GetEffect = Effects.Get
Effects.ClearEffects = Effects.Clear

-- No thinkInterval or nextThink scheduling.
-- OnThink runs once per server Think update for each active effect.

hook.Add("Think", "HitmenEffects_Update", function()
    if not SERVER then
        return
    end

    local now = CurTime()

    for entity in pairs(ActiveEntities) do
        if not IsValid(entity) then
            ActiveEntities[entity] = nil
            continue
        end

        local active = entity._HitmenEffects

        if not istable(active) or table.IsEmpty(active) then
            ApplySpeed(entity)
            continue
        end

        local expired = {}

        ForEachEffectRecord(active, function(id, record)
            if record.expiresAt and now >= record.expiresAt then
                expired[#expired + 1] = {
                    id = id,
                    record = record
                }
                return
            end

            local definition = Definitions[id] or record.definition
            local callback = definition and definition.OnThink

            if isfunction(callback) then
                local ok, err = pcall(
                    callback,
                    entity,
                    record,
                    now,
                    FrameTime()
                )

                if not ok then
                    LogError(id .. ".OnThink", err)
                end
            end
        end)

        for _, item in ipairs(expired) do
            if IsValid(entity) then
                RemoveEffectRecord(
                    entity,
                    item.id,
                    item.record,
                    "expired"
                )
            end
        end

        if IsValid(entity)
            and entity._HitmenEffects
            and not table.IsEmpty(entity._HitmenEffects)
        then
            ApplySpeed(entity)
        end
    end
end)

local function LoadEffectFiles()
    if not SERVER then
        return
    end

    local files = file.Find("hitmen/effects/*.lua", "LUA")
    table.sort(files)

    for _, name in ipairs(files) do
        include("hitmen/effects/" .. name)
    end
end

LoadEffectFiles()
