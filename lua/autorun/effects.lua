if SERVER then
    AddCSLuaFile()
end

HitmenEffects = HitmenEffects or {}
HitmenEffects.Definitions = HitmenEffects.Definitions or {}
HitmenEffects._ActiveEntities = HitmenEffects._ActiveEntities or setmetatable({}, { __mode = "k" })

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

local function IsCallable(value)
    return isfunction(value)
end

local function EntityHasMethod(entity, name)
    return IsValid(entity) and isfunction(entity[name])
end

local function IsEntityType(entity, method)
    return EntityHasMethod(entity, method) and entity[method](entity) or false
end

local function LogError(context, err)
    ErrorNoHalt("[Hitmen Effects] " .. tostring(context) .. ": " .. tostring(err) .. "\n")
end

local function NearlyEqual(a, b)
    return isnumber(a) and isnumber(b) and math.abs(a - b) < 0.001
end

local function ReadField(entity, key)
    local value = entity[key]
    if isfunction(value) then return nil end
    return tonumber(value)
end

local function ReadGetter(entity, getterName)
    local getter = entity[getterName]
    if not isfunction(getter) then return nil end
    local ok, result = pcall(getter, entity)
    if ok then return tonumber(result) end
    return nil
end

local function ReconcileField(entity, state, key)
    local current = ReadField(entity, key)
    if current == nil then return state.baseFields[key] end

    local previousApplied = state.lastFields[key]
    if state.baseFields[key] == nil or (previousApplied ~= nil and not NearlyEqual(current, previousApplied)) then
        state.baseFields[key] = current
    end

    return state.baseFields[key]
end

local function ReconcileAccessor(entity, state, accessor)
    local current = ReadGetter(entity, accessor.getter)
    if current == nil then return nil end

    local base = state.baseAccessors[accessor.key]
    local last = state.lastAccessors[accessor.key]
    if base == nil or (last ~= nil and not NearlyEqual(current, last)) then
        state.baseAccessors[accessor.key] = current
    end

    return state.baseAccessors[accessor.key]
end

local function GetState(entity)
    local state = entity._HitmenEffectSpeedState
    if state then return state end

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
        if isfunction(entity[accessor.getter]) and isfunction(entity[accessor.setter]) then
            state.baseAccessors[accessor.key] = ReadGetter(entity, accessor.getter)
        end
    end

    entity._HitmenEffectSpeedState = state
    return state
end

local function GetRecordSpeedMultiplier(record)
    if record.useOverallMultiplierForSpeed then
        return math.max(tonumber(record.multiplier) or 1, 0)
    end

    return math.max(tonumber(record.speedMultiplier) or 1, 0)
end

local function GetCombinedSpeedMultiplier(entity)
    local combined = 1

    for id, record in pairs(entity._HitmenEffects or {}) do
        local definition = Definitions[id] or record.definition
        if not istable(definition) then continue end

        record.definition = definition
        combined = combined * GetRecordSpeedMultiplier(record)
    end

    return math.max(combined, 0)
end

local function ApplyField(entity, state, key, multiplier)
    local base = ReconcileField(entity, state, key)
    if base == nil then return end

    local result = math.max(base * multiplier, 0)
    entity[key] = result
    state.lastFields[key] = result
end

local function ApplySpeedAccessors(entity, state, multiplier)
    local appliedAny = false

    for _, accessor in ipairs(SPEED_ACCESSORS) do
        local getter = entity[accessor.getter]
        local setter = entity[accessor.setter]
        if not isfunction(getter) or not isfunction(setter) then continue end

        local base = ReconcileAccessor(entity, state, accessor)
        if base == nil then continue end

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
    local candidates = { "RunSpeed", "PowerRunSpeed", "PowerSpeed", "WalkSpeed", "Speed", "MoveSpeed" }

    for _, key in ipairs(candidates) do
        local value = ReadField(entity, key)
        if value and value > 0 then return value end
    end

    local getterNames = { "GetRunSpeed", "GetWalkSpeed" }
    for _, name in ipairs(getterNames) do
        local value = ReadGetter(entity, name)
        if value and value > 0 then return value end
    end

    return nil
end

local function ApplyNextBotSpeed(entity, state, multiplier)
    local loco = entity.loco
    if type(loco) ~= "table" and type(loco) ~= "userdata" then return end
    if not isfunction(loco.GetDesiredSpeed) or not isfunction(loco.SetDesiredSpeed) then return end

    local ok, current = pcall(loco.GetDesiredSpeed, loco)
    if not ok or not isnumber(current) then return end

    if state.baseLocoSpeed == nil then
        state.baseLocoSpeed = current > 0 and current or GetFallbackNextBotSpeed(entity)
    elseif state.lastLocoSpeed ~= nil and not NearlyEqual(current, state.lastLocoSpeed) then
        state.baseLocoSpeed = current > 0 and current or GetFallbackNextBotSpeed(entity)
    end

    local base = state.baseLocoSpeed or GetFallbackNextBotSpeed(entity)
    if not base or base < 0 then return end

    local result = math.max(base * multiplier, 0)
    local setOK, err = pcall(loco.SetDesiredSpeed, loco, result)
    if setOK then
        state.lastLocoSpeed = result
    else
        LogError("loco:SetDesiredSpeed", err)
    end
end

local function ApplyNPCSpeed(entity, state, multiplier)
    if isfunction(entity.GetMaxSpeed) and isfunction(entity.SetMaxSpeed) then
        local ok, current = pcall(entity.GetMaxSpeed, entity)
        if ok and isnumber(current) then
            if state.baseNPCMaxSpeed == nil or (state.lastNPCMaxSpeed ~= nil and not NearlyEqual(current, state.lastNPCMaxSpeed)) then
                state.baseNPCMaxSpeed = current
            end
            local result = math.max(state.baseNPCMaxSpeed * multiplier, 0)
            local setOK = pcall(entity.SetMaxSpeed, entity, result)
            if setOK then state.lastNPCMaxSpeed = result end
        end
    end

    if isfunction(entity.GetArrivalSpeed) and isfunction(entity.SetArrivalSpeed) then
        local ok, current = pcall(entity.GetArrivalSpeed, entity)
        if ok and isnumber(current) then
            if state.baseNPCArrivalSpeed == nil or (state.lastNPCArrivalSpeed ~= nil and not NearlyEqual(current, state.lastNPCArrivalSpeed)) then
                state.baseNPCArrivalSpeed = current
            end
            local result = math.max(state.baseNPCArrivalSpeed * multiplier, 0)
            local setOK = pcall(entity.SetArrivalSpeed, entity, result)
            if setOK then state.lastNPCArrivalSpeed = result end
        end
    end

    if isfunction(entity.GetInternalVariable) and isfunction(entity.SetSaveValue) then
        local ok, current = pcall(entity.GetInternalVariable, entity, "m_flGroundSpeed")
        current = ok and tonumber(current) or nil
        if current then
            if state.baseNPCGroundSpeed == nil or (state.lastNPCGroundSpeed ~= nil and not NearlyEqual(current, state.lastNPCGroundSpeed)) then
                state.baseNPCGroundSpeed = current
            end
            local result = math.max(state.baseNPCGroundSpeed * multiplier, 0)
            local setOK = pcall(entity.SetSaveValue, entity, "m_flGroundSpeed", result)
            if setOK then state.lastNPCGroundSpeed = result end
        end
    end
end

local function ApplySpeed(entity)
    if not IsValid(entity) then return end

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
    if not state then return end

    local multiplier = GetCombinedSpeedMultiplier(entity)

    for _, key in ipairs(SPEED_FIELDS) do
        ApplyField(entity, state, key, multiplier)
    end

    local hasAccessors = ApplySpeedAccessors(entity, state, multiplier)

    if IsEntityType(entity, "IsNPC") then
        if not hasAccessors then ApplyNPCSpeed(entity, state, multiplier) end
    elseif IsEntityType(entity, "IsNextBot") and not hasAccessors then
        ApplyNextBotSpeed(entity, state, multiplier)
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

    if multiplierOverride ~= nil then options.multiplier = multiplierOverride end
    return options
end

local function NormalizeID(id)
    if not isstring(id) then return nil end
    id = string.lower(string.Trim(id))
    if id == "" then return nil end
    return id
end

function Effects.Register(id, definition)
    id = NormalizeID(id)
    if not id then return false, "Effect ID must be a non-empty string." end
    if not istable(definition) then return false, "Effect definition must be a table." end

    local stored = table.Copy(definition)
    stored.id = id
    stored.duration = math.max(tonumber(stored.duration) or 0, 0)
    stored.speedMultiplier = math.max(tonumber(stored.speedMultiplier) or 1, 0)
    stored.multiplier = math.max(tonumber(stored.multiplier) or 1, 0)

    if stored.useOverallMultiplierForSpeed == nil then
        stored.useOverallMultiplierForSpeed = stored.useOverallMultiplier == true
            or stored.speedMultiplierUsesOverallMultiplier == true
    end

    Definitions[id] = stored

    for entity in pairs(ActiveEntities) do
        if IsValid(entity) and entity._HitmenEffects and entity._HitmenEffects[id] then
            entity._HitmenEffects[id].definition = stored
            ApplySpeed(entity)
        end
    end

    return true
end

function Effects.Unregister(id)
    id = NormalizeID(id)
    if not id or not Definitions[id] then return false end

    Definitions[id] = nil
    for entity in pairs(ActiveEntities) do
        if IsValid(entity) and entity._HitmenEffects and entity._HitmenEffects[id] then
            Effects.Remove(entity, id, "unregistered")
        end
    end
    return true
end

function Effects.SetDefaultMultiplier(id, value)
    id = NormalizeID(id)
    value = tonumber(value)
    if not id or not value or not Definitions[id] then return false end

    Definitions[id].multiplier = math.max(value, 0)
    for entity in pairs(ActiveEntities) do
        if IsValid(entity) and entity._HitmenEffects then
            local record = entity._HitmenEffects[id]
            if record and not record.multiplierOverridden then
                record.multiplier = Definitions[id].multiplier
            end
            ApplySpeed(entity)
        end
    end
    return true
end

function Effects.Apply(entity, id, durationOrOptions, multiplierOverride)
    if not SERVER or not IsValid(entity) then return false end
    id = NormalizeID(id)
    local definition = id and Definitions[id]
    if not definition then return false end

    local options = ParseOptions(durationOrOptions, multiplierOverride)
    local active = entity._HitmenEffects or {}
    local oldRecord = active[id]
    local isRefresh = oldRecord ~= nil

    local duration = options.duration
    if duration == nil then duration = definition.duration end
    duration = math.max(tonumber(duration) or 0, 0)

    local record = oldRecord or { id = id, data = {} }
    record.definition = definition
    record.duration = duration
    record.expiresAt = duration > 0 and (CurTime() + duration) or nil
    record.nextThink = CurTime() + math.max(tonumber(definition.thinkInterval) or 0.1, 0.01)

    local suppliedMultiplier = options.multiplier
    if suppliedMultiplier ~= nil then
        record.multiplier = math.max(tonumber(suppliedMultiplier) or definition.multiplier, 0)
        record.multiplierOverridden = true
    elseif not oldRecord then
        record.multiplier = definition.multiplier
        record.multiplierOverridden = false
    elseif not record.multiplierOverridden then
        record.multiplier = definition.multiplier
    end

    if options.speedMultiplier ~= nil then
        record.speedMultiplier = math.max(tonumber(options.speedMultiplier) or definition.speedMultiplier, 0)
        record.speedMultiplierOverridden = true
    elseif not oldRecord then
        record.speedMultiplier = definition.speedMultiplier
        record.speedMultiplierOverridden = false
    elseif not record.speedMultiplierOverridden then
        record.speedMultiplier = definition.speedMultiplier
    end

    local useOverall = options.useOverallMultiplierForSpeed
    if useOverall == nil then useOverall = options.useOverallMultiplier end
    if useOverall == nil then useOverall = options.speedMultiplierUsesOverallMultiplier end
    if useOverall ~= nil then
        record.useOverallMultiplierForSpeed = tobool(useOverall)
        record.useOverallMultiplierOverridden = true
    elseif not oldRecord then
        record.useOverallMultiplierForSpeed = definition.useOverallMultiplierForSpeed == true
        record.useOverallMultiplierOverridden = false
    elseif not record.useOverallMultiplierOverridden then
        record.useOverallMultiplierForSpeed = definition.useOverallMultiplierForSpeed == true
    end

    if options.source ~= nil then record.source = options.source end
    if options.data ~= nil then record.data = options.data end

    active[id] = record
    entity._HitmenEffects = active
    ActiveEntities[entity] = true

    ApplySpeed(entity)

    local callbackName = isRefresh and "OnRefresh" or "OnApply"
    local callback = definition[callbackName]
    if isfunction(callback) then
        local ok, err = pcall(callback, entity, record, options, isRefresh)
        if not ok then LogError(id .. "." .. callbackName, err) end
    end

    hook.Run("HitmenEffectApplied", entity, id, record, isRefresh)
    return true, record
end

function Effects.Refresh(entity, id, durationOrOptions, multiplierOverride)
    return Effects.Apply(entity, id, durationOrOptions, multiplierOverride)
end

function Effects.Remove(entity, id, reason)
    if not SERVER or not IsValid(entity) then return false end
    id = NormalizeID(id)
    local active = entity._HitmenEffects
    local record = id and active and active[id]
    if not record then return false end

    active[id] = nil
    reason = reason or "removed"
    local definition = Definitions[id] or record.definition

    local callbackNames = { "OnRemove" }
    if reason == "expired" then callbackNames[#callbackNames + 1] = "OnExpire" end
    for _, callbackName in ipairs(callbackNames) do
        local callback = definition and definition[callbackName]
        if isfunction(callback) then
            local ok, err = pcall(callback, entity, record, reason)
            if not ok then LogError(id .. "." .. callbackName, err) end
        end
    end

    hook.Run("HitmenEffectRemoved", entity, id, record, reason)
    if table.IsEmpty(active) then entity._HitmenEffects = nil end
    ApplySpeed(entity)
    return true
end

function Effects.Clear(entity, reason)
    if not SERVER or not IsValid(entity) or not istable(entity._HitmenEffects) then return false end
    local ids = {}
    for id in pairs(entity._HitmenEffects) do ids[#ids + 1] = id end
    for _, id in ipairs(ids) do Effects.Remove(entity, id, reason or "cleared") end
    return #ids > 0
end

function Effects.Has(entity, id)
    id = NormalizeID(id)
    return IsValid(entity) and id ~= nil and entity._HitmenEffects ~= nil and entity._HitmenEffects[id] ~= nil
end

function Effects.Get(entity, id)
    if not IsValid(entity) or not istable(entity._HitmenEffects) then return nil end
    if id == nil then return entity._HitmenEffects end
    id = NormalizeID(id)
    return id and entity._HitmenEffects[id] or nil
end

function Effects.GetMultiplier(entity, id)
    local record = Effects.Get(entity, id)
    return record and record.multiplier or nil
end

function Effects.GetSpeedMultiplier(entity)
    if not IsValid(entity) then return nil end
    return GetCombinedSpeedMultiplier(entity)
end

Effects.RegisterEffect = Effects.Register
Effects.ApplyEffect = Effects.Apply
Effects.RefreshEffect = Effects.Refresh
Effects.RemoveEffect = Effects.Remove
Effects.HasEffect = Effects.Has
Effects.GetEffect = Effects.Get
Effects.ClearEffects = Effects.Clear

hook.Add("Think", "HitmenEffects_Update", function()
    if not SERVER then return end
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
        for id, record in pairs(active) do
            if record.expiresAt and now >= record.expiresAt then
                expired[#expired + 1] = id
            elseif now >= (record.nextThink or now) then
                local definition = Definitions[id] or record.definition
                local interval = math.max(tonumber(definition and definition.thinkInterval) or 0.1, 0.01)
                record.nextThink = now + interval
                local callback = definition and definition.OnThink
                if isfunction(callback) then
                    local ok, err = pcall(callback, entity, record, now, interval)
                    if not ok then LogError(id .. ".OnThink", err) end
                end
            end
        end

        for _, id in ipairs(expired) do
            if entity._HitmenEffects and entity._HitmenEffects[id] then
                Effects.Remove(entity, id, "expired")
            end
        end

        if IsValid(entity) and entity._HitmenEffects and not table.IsEmpty(entity._HitmenEffects) then
            ApplySpeed(entity)
        end
    end
end)

local function LoadEffectFiles()
    if not SERVER then return end

    local files = file.Find("hitmen/effects/*.lua", "LUA")
    table.sort(files)

    for _, name in ipairs(files) do
        include("hitmen/effects/" .. name)
    end
end

LoadEffectFiles()

LoadEffectFiles()