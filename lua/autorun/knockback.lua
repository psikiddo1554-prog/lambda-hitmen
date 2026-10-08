-- lua/autorun/knockback.lua
--
-- Knockback + wall-impact handling.
-- Ragdoll management is handled entirely by ragdolling.lua.

if not SERVER then return end

LambdaHitmen = LambdaHitmen or {}

local WALL_CHECK_INTERVAL = 0.02

----------------------------------------------------------------
-- Utility
----------------------------------------------------------------

local function IsEntityDead(target)
    if not IsValid(target) then
        return true
    end

    if target.Alive and not target:Alive() then
        return true
    end

    if target.Health and target.GetMaxHealth then
        local maxHealth = target:GetMaxHealth()

        if maxHealth and maxHealth > 0
            and target:Health() <= 0
        then
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

    local phys =
        ent.GetPhysicsObject
        and ent:GetPhysicsObject()

    if IsValid(phys) then
        return phys:GetVelocity()
    end

    return vector_origin
end

----------------------------------------------------------------
-- Wall checking
----------------------------------------------------------------

local function GetWallTraceEntity(target)
    local ragdoll =
        LambdaHitmen.GetRagdoll(target)

    if IsValid(ragdoll) then
        return ragdoll
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
        "LambdaHitmen_WallHit_"
        .. target:EntIndex()

    timer.Remove(timerName)

    local repetitions = math.max(
        1,
        math.ceil(
            duration / WALL_CHECK_INTERVAL
        )
    )

    timer.Create(
        timerName,
        WALL_CHECK_INTERVAL,
        repetitions,
        function()
            if not IsValid(target)
                or IsEntityDead(target)
            then
                timer.Remove(timerName)
                return
            end

            local movementEntity =
                GetWallTraceEntity(target)

            if not IsValid(movementEntity) then
                timer.Remove(timerName)
                return
            end

            local velocity =
                GetEntityVelocity(movementEntity)

            local direction =
                Vector(
                    velocity.x,
                    velocity.y,
                    0
                )

            local speed =
                direction:Length()

            if speed < 20 then
                direction =
                    Vector(
                        launchDirection.x,
                        launchDirection.y,
                        0
                    )
            end

            if direction:LengthSqr() < 0.0001 then
                return
            end

            direction:Normalize()

            local mins, maxs =
                movementEntity:GetCollisionBounds()

            local probeDistance =
                math.Clamp(
                    speed
                        * WALL_CHECK_INTERVAL
                        + 6,
                    8,
                    48
                )

            local trace =
                util.TraceHull({
                    start =
                        movementEntity:GetPos(),

                    endpos =
                        movementEntity:GetPos()
                        + direction
                        * probeDistance,

                    mins = mins,
                    maxs = maxs,

                    filter = {
                        movementEntity,
                        applier
                    },

                    mask = MASK_PLAYERSOLID
                })

            if trace.Hit
                and (
                    trace.StartSolid
                    or trace.HitNormal.z < 0.5
                )
            then
                timer.Remove(timerName)

                onWallHit(
                    applier,
                    target,
                    trace
                )
            end
        end
    )
end

----------------------------------------------------------------
-- Knockback
----------------------------------------------------------------

function LambdaHitmen.ApplyKnockback(
    applier,
    target,
    force,
    upForce,
    onWallHit,
    wallCheckDuration,
    ragdollDuration
)
    if not IsValid(applier)
        or not IsValid(target)
    then
        return false
    end

    if IsEntityDead(target) then
        return false
    end

    -- Real human players are intentionally excluded.
    if target:IsPlayer()
        and not target.IsLambdaPlayer
    then
        return false
    end

    force =
        math.max(
            tonumber(force) or 600,
            0
        )

    upForce =
        tonumber(upForce) or 0

    ------------------------------------------------------------
    -- Direction
    ------------------------------------------------------------

    local direction =
        target:WorldSpaceCenter()
        - applier:WorldSpaceCenter()

    direction.z = 0

    if direction:LengthSqr() < 0.0001 then
        if applier.GetForward then
            direction =
                applier:GetForward()

            direction.z = 0
        end
    end

    if direction:LengthSqr() < 0.0001 then
        return false
    end

    direction:Normalize()

    local impulse =
        direction * force
        + Vector(0, 0, upForce)

    ------------------------------------------------------------
    -- Existing ragdoll
    ------------------------------------------------------------

    local existingRagdoll =
        LambdaHitmen.GetRagdoll(target)

    if IsValid(existingRagdoll) then
        -- Don't try to move the hidden Lambda itself.
        LambdaHitmen.AddRagdollVelocity(
            target,
            impulse
        )

        if ragdollDuration ~= nil then
            local duration =
                math.Clamp(
                    tonumber(ragdollDuration) or 0,
                    0,
                    10
                )

            if duration > 0 then
                LambdaHitmen.RefreshRagdoll(
                    target,
                    duration
                )
            end
        end
    else
        --------------------------------------------------------
        -- Normal entity knockback
        --------------------------------------------------------

        local baseVelocity =
            GetEntityVelocity(target)

        if target.IsLambdaPlayer then
            local loco = target.loco

            if not loco
                or not loco.GetVelocity
                or not loco.SetVelocity
            then
                return false
            end

            if loco.Jump then
                loco:Jump()
            end

            loco:SetVelocity(
                loco:GetVelocity()
                + impulse
            )
        else
            local phys =
                target.GetPhysicsObject
                and target:GetPhysicsObject()

            if IsValid(phys) then
                phys:ApplyForceCenter(
                    impulse * phys:GetMass()
                )

                phys:Wake()
            elseif target.SetVelocity then
                target:SetVelocity(impulse)
            else
                return false
            end
        end

        --------------------------------------------------------
        -- Optional temporary ragdoll
        --------------------------------------------------------

        if ragdollDuration ~= nil then
            local duration =
                math.Clamp(
                    tonumber(ragdollDuration) or 0,
                    0,
                    10
                )

            if duration > 0
                and not IsEntityDead(target)
            then
                LambdaHitmen.RagdollEntity(
                    target,
                    duration,
                    baseVelocity + impulse
                )
            end
        end
    end

    ------------------------------------------------------------
    -- Optional wall monitoring
    ------------------------------------------------------------

    if isfunction(onWallHit) then
        local wallDuration =
            math.Clamp(
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

----------------------------------------------------------------
-- Backwards-compatible shorthand
----------------------------------------------------------------

ApplyLambdaKnockback =
    LambdaHitmen.ApplyKnockback