
-- lua/autorun/knockback.lua
-- Additive Lambda Player knockback with an optional wall-hit callback.
-- Server-side only.

if not SERVER then return end

LambdaHitmen = LambdaHitmen or {}

local WALL_CHECK_INTERVAL = 0.02

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
            if not IsValid(target) or not target.IsLambdaPlayer then
                timer.Remove(timerName)
                return
            end

            local loco = target.loco
            if not loco or not loco.GetVelocity then
                timer.Remove(timerName)
                return
            end

            -- Follow the target's current horizontal movement.
            local velocity = loco:GetVelocity()
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

            -- Trace using the Lambda Player's collision bounds.
            local mins, maxs = target:GetCollisionBounds()
            local probeDistance = math.Clamp(
                speed * WALL_CHECK_INTERVAL + 6,
                8,
                48
            )

            local trace = util.TraceHull({
                start = target:GetPos(),
                endpos = target:GetPos()
                    + direction * probeDistance,
                mins = mins,
                maxs = maxs,
                filter = { target, applier },
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

--- Apply additive knockback to a Lambda Player.
-- @param applier Entity Entity applying the knockback.
-- @param target Entity Lambda Player being knocked back.
-- @param force number Horizontal velocity impulse.
-- @param upForce number|nil Additional upward velocity.
-- @param onWallHit function|nil Optional wall-impact callback.
-- @param wallCheckDuration number|nil Duration of wall checking.
-- @return boolean Whether the initial knockback was applied.
function LambdaHitmen.ApplyKnockback(
    applier,
    target,
    force,
    upForce,
    onWallHit,
    wallCheckDuration
)
    if not IsValid(applier) or not IsValid(target) then
        return false
    end

    if not target.IsLambdaPlayer then
        return false
    end

    local loco = target.loco

    if not loco
        or not loco.GetVelocity
        or not loco.SetVelocity
    then
        return false
    end

    force = math.max(tonumber(force) or 600, 0)
    upForce = tonumber(upForce) or 0

    -- Determine the direction away from the applier.
    local direction =
        target:WorldSpaceCenter() - applier:WorldSpaceCenter()

    direction.z = 0

    if direction:LengthSqr() < 0.0001 then
        direction = applier:GetForward()
        direction.z = 0
    end

    if direction:LengthSqr() < 0.0001 then
        return false
    end

    direction:Normalize()

    -- Jump before applying velocity, as in Lambda Players'
    -- own golf-club weapon implementation.
    if loco.Jump then
        loco:Jump()
    end

    -- Preserve existing locomotion velocity.
    local impulse =
        direction * force + Vector(0, 0, upForce)

    loco:SetVelocity(loco:GetVelocity() + impulse)

    -- Wall monitoring is optional.
    if isfunction(onWallHit) then
        local duration = math.Clamp(
            tonumber(wallCheckDuration) or 1.0,
            0.05,
            10
        )

        WatchForWallHit(
            applier,
            target,
            direction,
            onWallHit,
            duration
        )
    end

    return true
end

-- Optional shorthand.
ApplyLambdaKnockback = LambdaHitmen.ApplyKnockback
