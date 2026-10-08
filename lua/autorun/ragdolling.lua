if SERVER then
    AddCSLuaFile()
else
    net.Receive("LambdaHitmen_SetRagdollPlayerColor", function()
        local ragdoll = net.ReadEntity()
        if not IsValid(ragdoll) then return end

        local color = net.ReadVector()

        ragdoll.GetPlayerColor = function()
            return color
        end
    end)

    return
end

LambdaHitmen = LambdaHitmen or {}

util.AddNetworkString("LambdaHitmen_SetRagdollPlayerColor")

local MAX_RAGDOLL_DURATION = 10

local TEMP_RAGDOLL_DURATION = CreateConVar(
    "lambdahitmen_ragdoll_duration",
    "0.75",
    FCVAR_ARCHIVE,
    "Default temporary ragdoll duration.",
    0,
    MAX_RAGDOLL_DURATION
)

local DEATH_RAGDOLL_DURATION = CreateConVar(
    "lambdahitmen_death_ragdoll_duration",
    "0",
    FCVAR_ARCHIVE,
    "How long Lambda death ragdolls remain. 0 means no automatic cleanup.",
    0,
    300
)

local activeRagdolls = {}
local suppressedDeaths = {}
local pendingDeathVelocity = {}
local pendingDeathInfo = {}

local function IsEntityDead(target)
    if not IsValid(target) then
        return true
    end

    if target.Alive and not target:Alive() then
        return true
    end

    if target.Health and target.GetMaxHealth then
        local maxHealth = target:GetMaxHealth()

        if maxHealth and maxHealth > 0 and target:Health() <= 0 then
            return true
        end
    end

    return false
end

local function GetEntityVelocity(ent)
    if not IsValid(ent) then
        return vector_origin
    end

    if ent.IsLambdaPlayer then
        local loco = ent.loco

        if loco and loco.GetVelocity then
            return loco:GetVelocity()
        end
    end

    if ent.GetVelocity then
        return ent:GetVelocity()
    end

    local phys = ent.GetPhysicsObject and ent:GetPhysicsObject()

    if IsValid(phys) then
        return phys:GetVelocity()
    end

    return vector_origin
end

local function CopyEntityAppearance(source, ragdoll)
    if source.GetSkin and ragdoll.SetSkin then
        ragdoll:SetSkin(source:GetSkin())
    end

    if not source.IsLambdaPlayer
        and source.GetColor
        and ragdoll.SetColor
    then
        local color = source:GetColor()

        ragdoll:SetColor(
            Color(
                color.r,
                color.g,
                color.b,
                color.a
            )
        )
    end

    if source.GetMaterial and ragdoll.SetMaterial then
        ragdoll:SetMaterial(source:GetMaterial())
    end

    if source.GetModelScale and ragdoll.SetModelScale then
        ragdoll:SetModelScale(source:GetModelScale(), 0)
    end

    if source.GetBodyGroups
        and source.GetBodygroup
        and ragdoll.SetBodygroup
    then
        for _, bodygroup in pairs(source:GetBodyGroups()) do
            ragdoll:SetBodygroup(
                bodygroup.id,
                source:GetBodygroup(bodygroup.id)
            )
        end
    end
end

local function SendLambdaPlayerColor(source, ragdoll)
    if not source.IsLambdaPlayer then
        return
    end

    if not source.GetPlyColor then
        return
    end

    local plyColor = source:GetPlyColor()

    if not isvector(plyColor) then
        return
    end

    net.Start("LambdaHitmen_SetRagdollPlayerColor")
        net.WriteEntity(ragdoll)
        net.WriteVector(plyColor)
    net.Broadcast()
end

local function SetRagdollVelocity(ragdoll, velocity)
    if not IsValid(ragdoll) then
        return
    end

    if not ragdoll.GetPhysicsObjectCount then
        return
    end

    velocity = velocity or vector_origin

    local count = ragdoll:GetPhysicsObjectCount()

    for i = 0, count - 1 do
        local phys = ragdoll:GetPhysicsObjectNum(i)

        if IsValid(phys) then
            phys:AddVelocity(velocity)
            phys:Wake()
        end
    end
end

local function AddRagdollVelocity(ragdoll, velocity)
    if not IsValid(ragdoll) then
        return
    end

    if not ragdoll.GetPhysicsObjectCount then
        return
    end

    velocity = velocity or vector_origin

    local count = ragdoll:GetPhysicsObjectCount()

    for i = 0, count - 1 do
        local phys = ragdoll:GetPhysicsObjectNum(i)

        if IsValid(phys) then
            phys:ApplyForceCenter(
                velocity * phys:GetMass()
            )

            phys:Wake()
        end
    end
end

local function ApplyDeathDamageForce(ragdoll, info)
    if not IsValid(ragdoll) then
        return
    end

    if not info or not info.GetDamageForce then
        return
    end

    local damageForce = info:GetDamageForce()
    local damagePosition = info:GetDamagePosition()

    if not isvector(damageForce)
        or damageForce:LengthSqr() <= 0.0001
    then
        return
    end

    if not isvector(damagePosition) then
        damagePosition = ragdoll:GetPos()
    end

    local forceScale = 3

    local attacker = info.GetAttacker
        and info:GetAttacker()
        or nil

    if IsValid(attacker)
        and attacker:GetClass() == "trigger_hurt"
    then
        forceScale = 0.25
    elseif info.IsExplosionDamage
        and info:IsExplosionDamage()
    then
        forceScale = 7
    end

    local count = ragdoll:GetPhysicsObjectCount()

    for i = 0, count - 1 do
        local phys = ragdoll:GetPhysicsObjectNum(i)

        if IsValid(phys) then
            local distance = phys:GetPos():Distance(damagePosition)

            local distanceScale = math.max(
                distance / forceScale,
                1
            )

            phys:ApplyForceOffset(
                damageForce / distanceScale,
                damagePosition
            )

            phys:Wake()
        end
    end
end

local function CreateRagdollEntity(target, velocity)
    if not IsValid(target) then
        return nil
    end

    local model = target.GetModel and target:GetModel()

    if not model or model == "" then
        return nil
    end

    local ragdoll = ents.Create("prop_ragdoll")

    if not IsValid(ragdoll) then
        return nil
    end

    local visualEntity = target

    if IsValid(target.l_BecomeRagdollEntity) then
        visualEntity = target.l_BecomeRagdollEntity
    end

    if IsValid(visualEntity)
        and visualEntity.GetModel
        and visualEntity:GetModel() ~= ""
    then
        model = visualEntity:GetModel()
    end

    ragdoll:SetModel(model)
    ragdoll:SetPos(target:GetPos())
    ragdoll:SetAngles(target:GetAngles())

    if ragdoll.SetOwner then
        ragdoll:SetOwner(target)
    end

    CopyEntityAppearance(visualEntity, ragdoll)

    ragdoll.LambdaOwner = target
    ragdoll.IsLambdaSpawned = true
    ragdoll.LambdaHitmenRagdoll = true

    ragdoll:Spawn()
    ragdoll:Activate()

    ragdoll:SetCollisionGroup(COLLISION_GROUP_DEBRIS)

    SetRagdollVelocity(
        ragdoll,
        velocity or vector_origin
    )

    SendLambdaPlayerColor(
        target,
        ragdoll
    )

    return ragdoll
end

local function HideRagdolledEntity(target)
    if not IsValid(target) then
        return
    end

    target:SetNoDraw(true)

    if target.SetNotSolid then
        target:SetNotSolid(true)
    end

    if target.SetSolid then
        target:SetSolid(SOLID_NONE)
    end

    if target.SetCollisionGroup then
        target:SetCollisionGroup(COLLISION_GROUP_IN_VEHICLE)
    end

    if target.IsLambdaPlayer
        and target.SetMoveType
    then
        target:SetMoveType(MOVETYPE_NONE)
    end

    if target.IsLambdaPlayer
        and target.loco
    then
        if target.loco.SetVelocity then
            target.loco:SetVelocity(vector_origin)
        end

        if target.loco.SetDesiredSpeed then
            target.loco:SetDesiredSpeed(0)
        end
    end
end

local function RestoreRagdolledEntity(target, state)
    if not state then
        return
    end

    local ragdoll = state.ragdoll

    local restorePos = state.lastPos
    local restoreAng = state.lastAng

    if IsValid(ragdoll) then
        restorePos = ragdoll:GetPos()
        restoreAng = ragdoll:GetAngles()
    end

    if IsValid(target) then
        target:SetNoDraw(true)

        if target.RemoveCallOnRemove then
            target:RemoveCallOnRemove(
                "LambdaHitmen_TemporaryRagdoll"
            )
        end

        if target.SetParent then
            target:SetParent(nil)
        end

        if restorePos then
            target:SetPos(restorePos)

            if target.SetNetworkOrigin then
                target:SetNetworkOrigin(restorePos)
            end
        end

        if restoreAng then
            if target.IsLambdaPlayer then
                target:SetAngles(
                    Angle(
                        0,
                        restoreAng.y,
                        0
                    )
                )
            else
                target:SetAngles(restoreAng)
            end
        end

        if target.SetupBones then
            target:SetupBones()
        end

        if target.SetNotSolid
            and state.notSolid ~= nil
        then
            target:SetNotSolid(state.notSolid)
        end

        if target.SetSolid
            and state.solid ~= nil
        then
            target:SetSolid(state.solid)
        end

        if target.SetCollisionGroup
            and state.collisionGroup ~= nil
        then
            target:SetCollisionGroup(
                state.collisionGroup
            )
        end

        if target.SetMoveType
            and state.moveType ~= nil
        then
            target:SetMoveType(
                state.moveType
            )
        end

        if state.parent
            and IsValid(state.parent)
        then
            target:SetParent(state.parent)
        end

        if target.IsLambdaPlayer
            and target.loco
        then
            if target.loco.SetVelocity then
                target.loco:SetVelocity(
                    vector_origin
                )
            end

            if target.loco.SetDesiredSpeed
                and state.desiredSpeed ~= nil
            then
                target.loco:SetDesiredSpeed(
                    state.desiredSpeed
                )
            end
        end
    end

    state.restoring = true

    if IsValid(ragdoll) then
        ragdoll:Remove()
    end

    activeRagdolls[target] = nil

    if IsValid(target) then
        timer.Simple(0, function()
            if not IsValid(target) then
                return
            end

            target:SetNoDraw(
                state.noDraw
            )

            if not state.noDraw
                and target.SetupBones
            then
                target:SetupBones()
            end
        end)
    end
end

local function FinishTemporaryRagdoll(target)
    local state = activeRagdolls[target]

    if not state
        or state.permanent
    then
        return
    end

    if state.timerName then
        timer.Remove(
            state.timerName
        )
    end

    RestoreRagdolledEntity(
        target,
        state
    )
end

local function StartTemporaryRagdoll(
    target,
    duration,
    velocity
)
    if not IsValid(target) then
        return nil
    end

    if IsEntityDead(target) then
        return nil
    end

    local existing =
        activeRagdolls[target]

    if existing
        and IsValid(existing.ragdoll)
        and not existing.permanent
    then
        existing.endTime =
            CurTime() + duration

        AddRagdollVelocity(
            existing.ragdoll,
            velocity
        )

        timer.Create(
            existing.timerName,
            duration,
            1,
            function()
                FinishTemporaryRagdoll(
                    target
                )
            end
        )

        return existing.ragdoll
    end

    local ragdoll =
        CreateRagdollEntity(
            target,
            velocity
        )

    if not IsValid(ragdoll) then
        return nil
    end

    local oldParent = nil

    if target.GetParent then
        oldParent =
            target:GetParent()

        if not IsValid(oldParent) then
            oldParent = nil
        end
    end

    local desiredSpeed = nil

    if target.IsLambdaPlayer
        and target.loco
        and target.loco.GetDesiredSpeed
    then
        desiredSpeed =
            target.loco:GetDesiredSpeed()
    end

    local state = {
        ragdoll = ragdoll,

        timerName =
            "LambdaHitmen_Ragdoll_"
            .. target:EntIndex(),

        endTime =
            CurTime() + duration,

        permanent = false,

        noDraw =
            target.GetNoDraw
                and target:GetNoDraw()
                or false,

        notSolid =
            target.GetNotSolid
                and target:GetNotSolid()
                or false,

        solid =
            target.GetSolid
                and target:GetSolid()
                or nil,

        collisionGroup =
            target.GetCollisionGroup
                and target:GetCollisionGroup()
                or nil,

        moveType =
            target.GetMoveType
                and target:GetMoveType()
                or nil,

        parent = oldParent,

        desiredSpeed = desiredSpeed,

        lastPos = ragdoll:GetPos(),
        lastAng = ragdoll:GetAngles(),

        restoring = false,
        sourceRemoved = false,
        ragdollRemoved = false
    }

    activeRagdolls[target] = state

    if target.SetParent then
        target:SetParent(ragdoll)
    end

    target:CallOnRemove(
        "LambdaHitmen_TemporaryRagdoll",
        function(ent)
            local current =
                activeRagdolls[ent]

            if not current then
                return
            end

            current.sourceRemoved = true

            if not current.permanent
                and IsValid(current.ragdoll)
            then
                current.ragdoll:Remove()
            end

            activeRagdolls[ent] = nil
        end
    )

    ragdoll:CallOnRemove(
        "LambdaHitmen_TemporaryRagdollEntity",
        function(rag)
            local current =
                activeRagdolls[target]

            if not current
                or current.ragdoll ~= rag
            then
                return
            end

            current.lastPos =
                rag:GetPos()

            current.lastAng =
                rag:GetAngles()

            current.ragdollRemoved = true

            if current.restoring
                or current.sourceRemoved
            then
                activeRagdolls[target] = nil
                return
            end

            RestoreRagdolledEntity(
                target,
                current
            )
        end
    )

    HideRagdolledEntity(target)

    timer.Create(
        state.timerName,
        duration,
        1,
        function()
            FinishTemporaryRagdoll(
                target
            )
        end
    )

    return ragdoll
end

local function MakeDeathRagdoll(
    target,
    damageInfo,
    inheritedVelocity
)
    if not IsValid(target) then
        return nil
    end

    local existing =
        activeRagdolls[target]

    if existing
        and IsValid(existing.ragdoll)
    then
        if existing.timerName then
            timer.Remove(
                existing.timerName
            )
        end

        existing.permanent = true
        existing.deathRagdoll = true

        local ragdoll =
            existing.ragdoll

        if isvector(inheritedVelocity)
            and inheritedVelocity:LengthSqr() > 0
        then
            AddRagdollVelocity(
                ragdoll,
                inheritedVelocity
            )
        end

        ApplyDeathDamageForce(
            ragdoll,
            damageInfo
        )

        target.ragdoll =
            ragdoll

        if target.SetNW2Entity then
            target:SetNW2Entity(
                "lambda_serversideragdoll",
                ragdoll
            )
        end

        local count =
            ragdoll:GetPhysicsObjectCount()

        for i = 0, count - 1 do
            local phys =
                ragdoll:GetPhysicsObjectNum(i)

            if IsValid(phys) then
                phys:Wake()
            end
        end

        return ragdoll
    end

    local velocity =
        inheritedVelocity

    if not isvector(velocity) then
        velocity =
            GetEntityVelocity(target)
    end

    local ragdoll =
        CreateRagdollEntity(
            target,
            velocity
        )

    if not IsValid(ragdoll) then
        return nil
    end

    ragdoll.deathRagdoll = true

    ApplyDeathDamageForce(
        ragdoll,
        damageInfo
    )

    target.ragdoll =
        ragdoll

    if target.SetNW2Entity then
        target:SetNW2Entity(
            "lambda_serversideragdoll",
            ragdoll
        )
    end

    HideRagdolledEntity(target)

    local state = {
        ragdoll = ragdoll,

        permanent = true,
        deathRagdoll = true,

        lastPos =
            ragdoll:GetPos(),

        lastAng =
            ragdoll:GetAngles()
    }

    activeRagdolls[target] =
        state

    target:CallOnRemove(
        "LambdaHitmen_DeathRagdoll",
        function(ent)
            local current =
                activeRagdolls[ent]

            if current
                and current.ragdoll == ragdoll
            then
                activeRagdolls[ent] = nil
            end
        end
    )

    ragdoll:CallOnRemove(
        "LambdaHitmen_DeathRagdollEntity",
        function(rag)
            local current =
                activeRagdolls[target]

            if current
                and current.ragdoll == rag
            then
                activeRagdolls[target] = nil
            end
        end
    )

    if _LambdaGamemodeHooksOverriden then
        hook.Run(
            "CreateEntityRagdoll",
            target,
            ragdoll
        )
    end

    local lifetime =
        DEATH_RAGDOLL_DURATION:GetFloat()

    if lifetime > 0 then
        timer.Simple(
            lifetime,
            function()
                if not IsValid(ragdoll) then
                    return
                end

                ragdoll:Remove()
            end
        )
    end

    return ragdoll
end

function LambdaHitmen.GetRagdoll(target)
    local state =
        activeRagdolls[target]

    if not state then
        return nil
    end

    if not IsValid(state.ragdoll) then
        return nil
    end

    return state.ragdoll
end

function LambdaHitmen.IsRagdolled(target)
    return IsValid(
        LambdaHitmen.GetRagdoll(target)
    )
end

function LambdaHitmen.RefreshRagdoll(
    target,
    duration
)
    local state =
        activeRagdolls[target]

    if not state
        or state.permanent
        or not IsValid(state.ragdoll)
    then
        return false
    end

    duration = math.Clamp(
        tonumber(duration)
            or TEMP_RAGDOLL_DURATION:GetFloat(),
        0,
        MAX_RAGDOLL_DURATION
    )

    if duration <= 0 then
        return false
    end

    state.endTime =
        CurTime() + duration

    timer.Create(
        state.timerName,
        duration,
        1,
        function()
            FinishTemporaryRagdoll(
                target
            )
        end
    )

    return true
end

function LambdaHitmen.AddRagdollVelocity(
    target,
    velocity
)
    local ragdoll =
        LambdaHitmen.GetRagdoll(target)

    if not IsValid(ragdoll) then
        return false
    end

    AddRagdollVelocity(
        ragdoll,
        velocity or vector_origin
    )

    return true
end

function LambdaHitmen.RagdollEntity(
    target,
    duration,
    velocity
)
    if not IsValid(target) then
        return nil
    end

    if target:IsPlayer()
        and not target.IsLambdaPlayer
    then
        return nil
    end

    if IsEntityDead(target) then
        return nil
    end

    duration = math.Clamp(
        tonumber(duration)
            or TEMP_RAGDOLL_DURATION:GetFloat(),
        0,
        MAX_RAGDOLL_DURATION
    )

    if duration <= 0 then
        return nil
    end

    velocity =
        velocity
        or GetEntityVelocity(target)

    return StartTemporaryRagdoll(
        target,
        duration,
        velocity
    )
end

function LambdaHitmen.UnragdollEntity(target)
    local state =
        activeRagdolls[target]

    if not state or state.permanent then
        return false
    end

    FinishTemporaryRagdoll(target)

    return true
end

function LambdaHitmen.GetRagdollVelocity(
    target
)
    local ragdoll =
        LambdaHitmen.GetRagdoll(target)

    if not IsValid(ragdoll) then
        return vector_origin
    end

    return GetEntityVelocity(ragdoll)
end

local function RestoreNativeDeathRagdoll(target)
    local saved =
        suppressedDeaths[target]

    if not saved then
        return
    end

    if IsValid(target) then
        target.CreateClientsideRagdoll =
            saved.client

        target.CreateServersideRagdoll =
            saved.server
    end

    suppressedDeaths[target] = nil
end

local function SuppressNativeDeathRagdoll(target)
    if not IsValid(target) then
        return
    end

    if suppressedDeaths[target] then
        return
    end

    suppressedDeaths[target] = {
        client =
            target.CreateClientsideRagdoll,

        server =
            target.CreateServersideRagdoll
    }

    target.CreateClientsideRagdoll =
        function(self)
            return self
        end

    target.CreateServersideRagdoll =
        function(self)
            return self
        end

    timer.Simple(0, function()
        if suppressedDeaths[target] then
            RestoreNativeDeathRagdoll(target)
        end
    end)
end

hook.Add(
    "LambdaOnPreKilled",
    "LambdaHitmen_SuppressNativeDeathRagdoll",
    function(lambda, info, silent)
        if not IsValid(lambda)
            or not lambda.IsLambdaPlayer
        then
            return
        end

        if silent then
            return
        end

        pendingDeathVelocity[lambda] =
            GetEntityVelocity(lambda)

        pendingDeathInfo[lambda] =
            info

        SuppressNativeDeathRagdoll(
            lambda
        )
    end
)

hook.Add(
    "LambdaOnKilled",
    "LambdaHitmen_CreateDeathRagdoll",
    function(lambda, info, silent)
        if not IsValid(lambda)
            or not lambda.IsLambdaPlayer
        then
            return
        end

        RestoreNativeDeathRagdoll(
            lambda
        )

        if silent then
            pendingDeathVelocity[lambda] = nil
            pendingDeathInfo[lambda] = nil
            return
        end

        MakeDeathRagdoll(
            lambda,
            info,
            pendingDeathVelocity[lambda]
        )

        pendingDeathVelocity[lambda] = nil
        pendingDeathInfo[lambda] = nil
    end
)

hook.Add(
    "Think",
    "LambdaHitmen_RagdollController",
    function()
        for target, state in pairs(activeRagdolls) do
            if not state then
                activeRagdolls[target] = nil
                continue
            end

            if state.permanent then
                continue
            end

            if not IsValid(target) then
                if IsValid(state.ragdoll) then
                    state.sourceRemoved = true
                    state.ragdoll:Remove()
                end

                activeRagdolls[target] = nil
                continue
            end

            if IsEntityDead(target) then
                MakeDeathRagdoll(
                    target,
                    pendingDeathInfo[target],
                    pendingDeathVelocity[target]
                        or GetEntityVelocity(state.ragdoll)
                )

                pendingDeathVelocity[target] = nil
                pendingDeathInfo[target] = nil

                continue
            end

            if not IsValid(state.ragdoll) then
                if state.restoring
                    or state.sourceRemoved
                then
                    activeRagdolls[target] = nil
                else
                    state.ragdollRemoved = true

                    RestoreRagdolledEntity(
                        target,
                        state
                    )
                end

                continue
            end

            state.lastPos =
                state.ragdoll:GetPos()

            state.lastAng =
                state.ragdoll:GetAngles()

            if CurTime() >= state.endTime then
                FinishTemporaryRagdoll(target)
                continue
            end

            if target.GetParent
                and target:GetParent() ~= state.ragdoll
            then
                target:SetParent(
                    state.ragdoll
                )
            end

            if target.IsLambdaPlayer
                and target.loco
            then
                if target.loco.SetVelocity then
                    target.loco:SetVelocity(
                        vector_origin
                    )
                end

                if target.loco.SetDesiredSpeed then
                    target.loco:SetDesiredSpeed(0)
                end
            end
        end
    end
)