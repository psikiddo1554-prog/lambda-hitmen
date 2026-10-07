-- lua/autorun/knockback.lua
-- Additive knockback with temporary server-side ragdolls.
-- The original entity is kept attached to its ragdoll while ragdolled, and
-- either side is cleaned up if the other is removed unexpectedly.
-- Supports Lambda Players, NPCs, NextBots, and other model entities
-- that can be represented by a prop_ragdoll.
-- Server + client: server creates the ragdoll; client receives Lambda playermodel color.

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

local WALL_CHECK_INTERVAL = 0.02
local MAX_RAGDOLL_DURATION = 10

-- Change this ConVar in the server console without editing the file.
-- Example: lambdahitmen_ragdoll_duration 1.25
local RAGDOLL_DURATION = CreateConVar(
    "lambdahitmen_ragdoll_duration",
    "0.75",
    FCVAR_ARCHIVE,
    "How long entities stay ragdolled after LambdaHitmen knockback.",
    0,
    MAX_RAGDOLL_DURATION
)

local activeRagdolls = {}

local function IsEntityDead(target)
    if not IsValid(target) then
        return true
    end

    -- Alive() is the safest general death-state check for entities that
    -- implement it. The GMod wiki notes that this checks the entity's internal life-state, which normally becomes dead when health reaches 0.
    if target.Alive and not target:Alive() then
        return true
    end

    -- For entities where Alive() is not meaningful, use health only when
    -- the entity actually reports a positive max-health value. This avoids
    -- treating ordinary props, which commonly report 0 health, as dead.
    if target.Health and target.GetMaxHealth then
        local maxHealth = target:GetMaxHealth()
        if maxHealth and maxHealth > 0 and target:Health() <= 0 then
            return true
        end
    end

    return false
end

local function GetRagdollDuration(value)
    if value ~= nil then
        return math.Clamp(
            tonumber(value) or RAGDOLL_DURATION:GetFloat(),
            0,
            MAX_RAGDOLL_DURATION
        )
    end

    return math.Clamp(
        RAGDOLL_DURATION:GetFloat(),
        0,
        MAX_RAGDOLL_DURATION
    )
end

local function GetEntityVelocity(ent)
    if not IsValid(ent) then
        return vector_origin
    end

    -- Lambda Players use their NextBot locomotion object.
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

    -- Do NOT use Entity:SetColor() for Lambda Players here. SetColor colors
    -- the whole rendered entity, while playermodel clothing is driven by the
    -- PlayerColor material proxy and a normalized Vector.
    -- The actual Lambda player color is sent to the client below, where the
    -- ragdoll receives a GetPlayerColor() function.
    if not source.IsLambdaPlayer and source.GetColor and ragdoll.SetColor then
        local color = source:GetColor()
        ragdoll:SetColor(Color(color.r, color.g, color.b, color.a))
    end

    if source.GetMaterial and ragdoll.SetMaterial then
        ragdoll:SetMaterial(source:GetMaterial())
    end

    if source.GetModelScale and ragdoll.SetModelScale then
        ragdoll:SetModelScale(source:GetModelScale(), 0)
    end

    if source.GetBodyGroups and source.GetBodygroup and ragdoll.SetBodygroup then
        for _, bodygroup in pairs(source:GetBodyGroups()) do
            ragdoll:SetBodygroup(
                bodygroup.id,
                source:GetBodygroup(bodygroup.id)
            )
        end
    end
end

local function SetRagdollVelocity(ragdoll, velocity)
    if not IsValid(ragdoll) or not ragdoll.GetPhysicsObjectCount then
        return
    end

    local count = ragdoll:GetPhysicsObjectCount()

    for i = 0, count - 1 do
        local phys = ragdoll:GetPhysicsObjectNum(i)

        if IsValid(phys) then
            phys:Wake()
            phys:SetVelocity(velocity)
        end
    end
end

local function AddRagdollVelocity(ragdoll, velocity)
    if not IsValid(ragdoll) or not ragdoll.GetPhysicsObjectCount then
        return
    end

    local count = ragdoll:GetPhysicsObjectCount()

    for i = 0, count - 1 do
        local phys = ragdoll:GetPhysicsObjectNum(i)

        if IsValid(phys) then
            -- Applying force equal to mass * velocity produces roughly the
            -- same velocity change for every ragdoll bone.
            phys:ApplyForceCenter(velocity * phys:GetMass())
            phys:Wake()
        end
    end
end

local function RestoreRagdolledEntity(target, state)
    if not state then return end

    local ragdoll = state.ragdoll
    local ragPos = state.lastPos
    local ragAng = state.lastAng

    -- Prefer the ragdoll's final transform when it still exists.
    if IsValid(ragdoll) then
        ragPos = ragdoll:GetPos()
        ragAng = ragdoll:GetAngles()
    end

    -- Keep the source hidden for the entire handoff. This prevents a frame
    -- where the client can render it at its old interpolated position.
    if IsValid(target) then
        if target.SetNoDraw then
            target:SetNoDraw(true)
        end

        if target.RemoveCallOnRemove then
            target:RemoveCallOnRemove("LambdaHitmen_RagdollSource")
        end

        if target.SetParent then
            target:SetParent(nil)
        end
    end

    -- Put the original entity exactly where the ragdoll ended up while it is
    -- still hidden. SetNetworkOrigin helps prevent the client from briefly
    -- showing the entity at its previous networked/interpolated position.
    if IsValid(target) and ragPos then
        target:SetPos(ragPos)

        if target.SetNetworkOrigin then
            target:SetNetworkOrigin(ragPos)
        end

        if ragAng then
            if target.IsLambdaPlayer then
                -- Lambdas generally only need their yaw restored.
                local restoredAng = Angle(0, ragAng.y, 0)
                target:SetAngles(restoredAng)
            else
                target:SetAngles(ragAng)
            end
        end

        -- Force the entity's bones to use the freshly restored transform
        -- before it becomes visible again.
        if target.SetupBones then
            target:SetupBones()
        end
    end

    if IsValid(target) then
        if target.SetNotSolid and state.notSolid ~= nil then
            target:SetNotSolid(state.notSolid)
        end

        if target.SetSolid and state.solid ~= nil then
            target:SetSolid(state.solid)
        end

        if target.SetCollisionGroup and state.collisionGroup ~= nil then
            target:SetCollisionGroup(state.collisionGroup)
        end

        if target.SetMoveType and state.moveType ~= nil then
            target:SetMoveType(state.moveType)
        end

        if target.IsLambdaPlayer and target.loco then
            if target.loco.SetVelocity then
                target.loco:SetVelocity(vector_origin)
            end

            if target.loco.SetDesiredSpeed and state.desiredSpeed ~= nil then
                target.loco:SetDesiredSpeed(state.desiredSpeed)
            end
        end
    end

    -- Let the position/angle update reach clients before making the source
    -- visible. This removes the one-frame teleport/flicker during unragdoll.
    local shouldDraw = state.noDraw == false

    if IsValid(target) then
        timer.Simple(0, function()
            if not IsValid(target) then return end

            if target.SetNoDraw then
                target:SetNoDraw(not shouldDraw)
            end

            if shouldDraw and target.SetupBones then
                target:SetupBones()
            end
        end)
    end

    -- Mark this as an intentional teardown before removing the ragdoll so its
    -- removal callback does not treat it as an externally-deleted ragdoll.
    state.restoring = true

    if IsValid(ragdoll) and not state.ragdollRemoved then
        ragdoll:Remove()
    end

    activeRagdolls[target] = nil
end

local function FinishRagdoll(target)
    local state = activeRagdolls[target]
    if not state then return end

    timer.Remove(state.timerName)
    RestoreRagdolledEntity(target, state)
end

local function StartRagdoll(target, duration, launchVelocity)
    if not IsValid(target) or IsEntityDead(target) then
        return nil
    end

    -- If the target is already ragdolled, refresh the timer and add the new
    -- knockback to the existing ragdoll instead of spawning another one.
    local existing = activeRagdolls[target]

    if existing and IsValid(existing.ragdoll) then
        existing.endTime = CurTime() + duration
        timer.Create(
            existing.timerName,
            duration,
            1,
            function()
                FinishRagdoll(target)
            end
        )

        AddRagdollVelocity(existing.ragdoll, launchVelocity)
        return existing.ragdoll
    end

    local model = target.GetModel and target:GetModel()
    if not model or model == "" then
        return nil
    end

    local ragdoll = ents.Create("prop_ragdoll")
    if not IsValid(ragdoll) then
        return nil
    end

    ragdoll:SetModel(model)
    ragdoll:SetPos(target:GetPos())
    ragdoll:SetAngles(target:GetAngles())

    CopyEntityAppearance(target, ragdoll)

    ragdoll:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
    ragdoll:Spawn()
    ragdoll:Activate()

    -- Lambda Players use the PlayerColor material proxy for the colorable
    -- parts of their playermodel (for example, the shirt). That proxy reads
    -- GetPlayerColor(), so the ragdoll needs to expose the Lambda's color to
    -- clients instead of using Entity:SetColor(), which would tint everything.
    if target.IsLambdaPlayer and target.GetPlyColor then
        local plyColor = target:GetPlyColor()

        if isvector(plyColor) then
            net.Start("LambdaHitmen_SetRagdollPlayerColor")
                net.WriteEntity(ragdoll)
                net.WriteVector(plyColor)
            net.Broadcast()
        end
    end

    SetRagdollVelocity(ragdoll, launchVelocity)

    local state = {
        ragdoll = ragdoll,
        timerName = "LambdaHitmen_Ragdoll_" .. target:EntIndex(),
        endTime = CurTime() + duration,
        noDraw = target.GetNoDraw and target:GetNoDraw() or false,
        notSolid = target.GetNotSolid and target:GetNotSolid() or false,
        solid = target.GetSolid and target:GetSolid() or nil,
        collisionGroup = target.GetCollisionGroup and target:GetCollisionGroup() or nil,
        moveType = target.GetMoveType and target:GetMoveType() or nil,
        desiredSpeed = nil,
        lastPos = ragdoll:GetPos(),
        lastAng = ragdoll:GetAngles(),
        restoring = false,
        sourceRemoved = false,
        ragdollRemoved = false
    }

    if target.IsLambdaPlayer and target.loco then
        if target.loco.GetDesiredSpeed then
            state.desiredSpeed = target.loco:GetDesiredSpeed()
        end
    end

    activeRagdolls[target] = state

    -- Keep the original entity physically attached to the ragdoll's transform.
    -- Parenting gives us continuous following instead of waiting until the
    -- ragdoll timer expires to synchronize the source entity.
    if target.SetParent then
        target:SetParent(ragdoll)
    end

    -- If the source entity disappears, remove its ragdoll as well.
    target:CallOnRemove(
        "LambdaHitmen_RagdollSource",
        function(ent)
            local current = activeRagdolls[ent]
            if current and IsValid(current.ragdoll) then
                current.sourceRemoved = true
                current.restoring = true
                current.ragdoll:Remove()
            end

            activeRagdolls[ent] = nil
        end
    )

    -- If the ragdoll disappears unexpectedly, immediately restore the source
    -- entity instead of leaving it hidden and frozen forever.
    ragdoll:CallOnRemove(
        "LambdaHitmen_RagdollEntity",
        function(rag)
            local current = activeRagdolls[target]
            if not current or current.ragdoll ~= rag then return end

            timer.Remove(current.timerName)

            -- Preserve the final transform even though the ragdoll is in the
            -- process of being removed and may no longer be valid afterward.
            current.lastPos = rag:GetPos()
            current.lastAng = rag:GetAngles()
            current.ragdollRemoved = true

            if current.restoring or current.sourceRemoved then
                activeRagdolls[target] = nil
                return
            end

            -- The ragdoll was removed externally. Restore the entity at its
            -- last known ragdoll position while keeping the state coherent.
            RestoreRagdolledEntity(target, current)
        end
    )

    -- Hide and freeze the real entity while the ragdoll exists.
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

    if target.SetMoveType and target.IsLambdaPlayer then
        target:SetMoveType(MOVETYPE_NONE)
    end

    if target.IsLambdaPlayer and target.loco then
        if target.loco.SetVelocity then
            target.loco:SetVelocity(vector_origin)
        end

        if target.loco.SetDesiredSpeed then
            target.loco:SetDesiredSpeed(0)
        end
    end

    timer.Create(
        state.timerName,
        duration,
        1,
        function()
            FinishRagdoll(target)
        end
    )

    return ragdoll
end

-- Keep Lambda Players from immediately walking away while they are hidden
-- inside a temporary ragdoll state.
hook.Add("Think", "LambdaHitmen_RagdollControl", function()
    for target, state in pairs(activeRagdolls) do
        if not IsValid(target) then
            -- The source entity is already gone. Remove the ragdoll too.
            if state and IsValid(state.ragdoll) then
                state.restoring = true
                state.sourceRemoved = true
                state.ragdoll:Remove()
            end

            activeRagdolls[target] = nil
            continue
        end

        if not IsValid(state.ragdoll) then
            -- The ragdoll was removed externally; the ragdoll callback should
            -- normally handle this, but keep a defensive fallback here.
            if not state.restoring and not state.sourceRemoved then
                state.ragdollRemoved = true
                FinishRagdoll(target)
            else
                activeRagdolls[target] = nil
            end
            continue
        end

        -- Keep a fallback transform so the source can still be restored even
        -- if the ragdoll disappears between Think ticks.
        state.lastPos = state.ragdoll:GetPos()
        state.lastAng = state.ragdoll:GetAngles()

        if CurTime() >= state.endTime then
            FinishRagdoll(target)
            continue
        end

        -- Parenting keeps the hidden entity attached to the ragdoll. If some
        -- external script breaks the parent relationship, restore it here so
        -- the source does not drift away from its ragdoll.
        if target.GetParent and target:GetParent() ~= state.ragdoll then
            target:SetParent(state.ragdoll)
        end

        if target.IsLambdaPlayer and target.loco then
            if target.loco.SetVelocity then
                target.loco:SetVelocity(vector_origin)
            end

            if target.loco.SetDesiredSpeed then
                target.loco:SetDesiredSpeed(0)
            end
        end
    end
end)

local function GetWallTraceEntity(target)
    local state = activeRagdolls[target]

    if state and IsValid(state.ragdoll) then
        return state.ragdoll
    end

    return target
end

local function WatchForWallHit(
    applier,
    target,
    launchDirection,
    onWallHit,
    duration
)
    local timerName =
        "LambdaHitmen_WallHit_" .. target:EntIndex()

    -- Replace an existing watcher for this target.
    timer.Remove(timerName)

    local repetitions = math.max(
        1,
        math.ceil(duration / WALL_CHECK_INTERVAL)
    )

    timer.Create(
        timerName,
        WALL_CHECK_INTERVAL,
        repetitions,
        function()
            if not IsValid(target) then
                timer.Remove(timerName)
                return
            end

            local movementEntity = GetWallTraceEntity(target)
            if not IsValid(movementEntity) then
                timer.Remove(timerName)
                return
            end

            -- Follow the ragdoll's current horizontal movement when the
            -- target is ragdolled; otherwise use the target's movement.
            local velocity = GetEntityVelocity(movementEntity)
            local direction = Vector(velocity.x, velocity.y, 0)
            local speed = direction:Length()

            -- Fall back to the original knockback direction.
            if speed < 20 then
                direction = Vector(
                    launchDirection.x,
                    launchDirection.y,
                    0
                )
            end

            if direction:LengthSqr() < 0.0001 then
                return
            end

            direction:Normalize()

            -- Trace using the entity's current collision bounds.
            local mins, maxs = movementEntity:GetCollisionBounds()
            local probeDistance = math.Clamp(
                speed * WALL_CHECK_INTERVAL + 6,
                8,
                48
            )

            local trace = util.TraceHull({
                start = movementEntity:GetPos(),
                endpos = movementEntity:GetPos()
                    + direction * probeDistance,
                mins = mins,
                maxs = maxs,
                filter = { movementEntity, applier },
                mask = MASK_PLAYERSOLID
            })

            -- Ignore floors and ceilings; look for a wall-like
            -- obstruction along the horizontal movement direction.
            if trace.Hit
                and (trace.StartSolid or trace.HitNormal.z < 0.5)
            then
                timer.Remove(timerName)

                -- Called once, with the applier, target and trace.
                onWallHit(applier, target, trace)
            end
        end
    )
end

--- Apply additive knockback and temporary ragdoll to an entity.
--
-- @param applier Entity Entity applying the knockback.
-- @param target Entity Entity being knocked back.
-- @param force number Horizontal velocity impulse.
-- @param upForce number|nil Additional upward velocity.
-- @param onWallHit function|nil Optional wall-impact callback.
-- @param wallCheckDuration number|nil Duration of wall checking.
-- @param ragdollDuration number|nil Duration of ragdoll; defaults to the ConVar.
-- @return boolean Whether the initial knockback was applied.
function LambdaHitmen.ApplyKnockback(
    applier,
    target,
    force,
    upForce,
    onWallHit,
    wallCheckDuration,
    ragdollDuration
)
    if not IsValid(applier) or not IsValid(target) then
        return false
    end

    -- If the damage that triggered this call has already killed the target,
    -- do not apply any knockback or start any wall-hit tracking.
    -- This check happens before calculating or applying the impulse.
    if IsEntityDead(target) then
        return false
    end

    -- Leave real human players alone; Lambda Players are NextBot entities,
    -- so they are still supported here.
    if target:IsPlayer() and not target.IsLambdaPlayer then
        return false
    end

    force = math.max(tonumber(force) or 600, 0)
    upForce = tonumber(upForce) or 0

    -- Determine the direction away from the applier.
    local direction =
        target:WorldSpaceCenter() - applier:WorldSpaceCenter()

    direction.z = 0

    if direction:LengthSqr() < 0.0001 then
        if applier.GetForward then
            direction = applier:GetForward()
            direction.z = 0
        end
    end

    if direction:LengthSqr() < 0.0001 then
        return false
    end

    direction:Normalize()

    local impulse =
        direction * force + Vector(0, 0, upForce)

    -- Capture the pre-knockback velocity so the temporary ragdoll inherits
    -- the same total motion without accidentally doubling the impulse.
    local baseVelocity = GetEntityVelocity(target)

    -- Lambda Players use their NextBot locomotion velocity.
    if target.IsLambdaPlayer then
        local loco = target.loco

        if not loco
            or not loco.GetVelocity
            or not loco.SetVelocity
        then
            return false
        end

        -- Jump before applying velocity, as in Lambda Players' own
        -- golf-club weapon implementation.
        if loco.Jump then
            loco:Jump()
        end

        loco:SetVelocity(loco:GetVelocity() + impulse)
    else
        local phys = target.GetPhysicsObject and target:GetPhysicsObject()

        if IsValid(phys) then
            -- Physics entities receive a true impulse.
            phys:ApplyForceCenter(impulse * phys:GetMass())
            phys:Wake()
        elseif target.SetVelocity then
            -- NPCs/NextBots and other non-physics entities.
            target:SetVelocity(impulse)
        else
            return false
        end
    end

    -- Inherit the entity's existing motion plus the new knockback impulse.
    local ragdollVelocity = baseVelocity + impulse

    local duration = GetRagdollDuration(ragdollDuration)

    -- The target is still alive here, so a temporary ragdoll can be created.
    if duration > 0 and not IsEntityDead(target) then
        StartRagdoll(
            target,
            duration,
            ragdollVelocity
        )
    end

    -- Wall monitoring is optional.
    if isfunction(onWallHit) then
        local wallDuration = math.Clamp(
            tonumber(wallCheckDuration) or 1.0,
            0.05,
            10
        )

        WatchForWallHit(
            applier,
            target,
            direction,
            onWallHit,
            wallDuration
        )
    end

    return true
end

-- Backwards-compatible shorthand.
ApplyLambdaKnockback = LambdaHitmen.ApplyKnockback

-- Optional public helpers if another script needs to manually ragdoll or wake
-- an entity without applying knockback.
function LambdaHitmen.RagdollEntity(target, duration, velocity)
    if not IsValid(target) or IsEntityDead(target) then
        return nil
    end

    if target:IsPlayer() and not target.IsLambdaPlayer then
        return nil
    end

    duration = GetRagdollDuration(duration)
    velocity = velocity or GetEntityVelocity(target)

    if duration <= 0 then
        return nil
    end

    return StartRagdoll(target, duration, velocity)
end

function LambdaHitmen.UnragdollEntity(target)
    if not IsValid(target) then
        return false
    end

    if not activeRagdolls[target] then
        return false
    end

    FinishRagdoll(target)
    return true
end
