ENT.WalkSpeed = 175
ENT.RunSpeed = 350
ENT.PowerSpeed = 700

-- Forward propulsion settings
ENT.PropelSpeed = 5000
ENT.PropelSpeedMin = 100
ENT.PropelSpeedMax = 50000

ENT.PropelTurnSpeed = 1200

ENT.PropelAcceleration = 100000
ENT.PropelDeceleration = 100000

ENT.PMeterMax = 100
ENT.PMeterBuildRate = 50
ENT.PMeterDecayRate = 85
ENT.SlowWalkPMeterThreshold = 35

ENT.TurnResistance = 0.5
ENT.TurnDrainMultiplier = 10
ENT.TurnDrainPerDegree = 0.1

ENT.TurnSpeed = 1200
ENT.TurnEaseOut = 10

ENT.Acceleration = 10000
ENT.Deceleration = 10000

ENT.PowerRunAnimRate = 1.25

--------------------------------------------------
-- ANIMATION SPEEDS
--------------------------------------------------

function ENT:InitializeHitmenAnimationSpeeds()
    if self._HitmenAnimationBaseSpeeds then
        return self._HitmenAnimationBaseSpeeds
    end

    local walkSpeed = tonumber(self.WalkSpeed) or 175
    local runSpeed = tonumber(self.RunSpeed) or 350
    local powerSpeed = tonumber(self.PowerSpeed) or runSpeed

    if walkSpeed <= 0 then walkSpeed = 1 end
    if runSpeed <= 0 then runSpeed = 1 end
    if powerSpeed <= 0 then powerSpeed = runSpeed end

    self._HitmenAnimationBaseSpeeds = {
        walk = walkSpeed,
        run = runSpeed,
        power = powerSpeed
    }

    return self._HitmenAnimationBaseSpeeds
end

ENT.AnimationSpeedSensitivity = 0.65

function ENT:GetHitmenAnimationRate(rate, currentSpeed, referenceSpeed)
    rate = tonumber(rate) or 1
    currentSpeed = tonumber(currentSpeed)
    referenceSpeed = tonumber(referenceSpeed)

    if currentSpeed == nil
        or referenceSpeed == nil
        or referenceSpeed <= 0 then
        return rate
    end

    local sensitivity = math.Clamp(
        tonumber(self.AnimationSpeedSensitivity) or 0.65,
        0,
        1
    )

    local speedRatio = math.max(currentSpeed, 0) / referenceSpeed

    local adjustedRatio = 1
        + (speedRatio - 1) * sensitivity

    return rate * math.max(adjustedRatio, 0)
end

function ENT:GetHitmenPowerRunAnimationRate()
    local base = self:InitializeHitmenAnimationSpeeds()

    local meter = isfunction(self.GetPMeter)
        and self:GetPMeter()
        or 0

    local meterMax = math.max(
        tonumber(self.PMeterMax) or 100,
        1
    )

    local fraction = math.Clamp(meter / meterMax, 0, 1)

    local referenceSpeed = Lerp(
        fraction,
        base.run,
        base.power
    )

    local currentSpeed = isfunction(self.GetPMeterSpeed)
        and self:GetPMeterSpeed()
        or self.RunSpeed

    return self:GetHitmenAnimationRate(
        self.PowerRunAnimRate or 1.25,
        currentSpeed,
        referenceSpeed
    )
end

function ENT:OnUpdateAnimation()
    if self:IsDown() or self:IsDead() then
        return
    end

    if self:IsClimbingUp() then
        return self.ClimbUpAnimation, self.ClimbAnimRate
    elseif self:IsClimbingDown() then
        return self.ClimbDownAnimation, self.ClimbAnimRate
    elseif not self:IsOnGround() then
        return self.JumpAnimation, self.JumpAnimRate
    end

    local base = self:InitializeHitmenAnimationSpeeds()

    if self:IsMoving() then
        if self:IsSlowWalking() then
            return self.WalkAnimation,
                self:GetHitmenAnimationRate(
                    self.WalkAnimRate,
                    self.WalkSpeed,
                    base.walk
                )
        end

        return self.RunAnimation,
            self:GetHitmenAnimationRate(
                self.RunAnimRate,
                self.RunSpeed,
                base.run
            )
    end

    return self.IdleAnimation, self.IdleAnimRate
end

--------------------------------------------------
-- MOVEMENT ENABLE/DISABLE
--------------------------------------------------

function ENT:SetMovementEnabled(enabled)
    self._HitmenMovementEnabled = enabled == true

    if not self._HitmenMovementEnabled and self.loco then
        local velocity = self:GetVelocity()

        self.loco:SetVelocity(
            Vector(0, 0, velocity.z)
        )
    end
end

function ENT:GetMovementEnabled()
    return self._HitmenMovementEnabled ~= false
end

--------------------------------------------------
-- FORWARD PROPULSION
--------------------------------------------------

-- Propels the hitman forward in the direction it faces.
--
-- duration:
--     Optional duration in seconds.
--     Omit to propel until StopPropellingForward() is called.
--
-- speed:
--     Optional propulsion speed.
--     Clamped to PropelSpeedMin and PropelSpeedMax.
--
-- turnRate:
--     Optional turning rate in degrees per second.
--     Defaults to PropelTurnSpeed.
--
-- Examples:
--     self:PropelForward(1, 15000, 350)
--     self:PropelForward(2, 30000, 700)
--     self:PropelForward(nil, 10000, 500)
--     self:PropelForward()

function ENT:PropelForward(duration, speed, turnRate)
    if not SERVER or not IsValid(self) then
        return false
    end

    -- Validate the optional duration.
    if duration ~= nil then
        duration = tonumber(duration)

        if duration == nil then
            return false
        end

        duration = math.max(duration, 0)
    end

    -- Resolve the allowed propulsion speed range.
    local minSpeed = math.max(
        tonumber(self.PropelSpeedMin) or 100,
        0
    )

    local maxSpeed = math.max(
        tonumber(self.PropelSpeedMax) or 50000,
        minSpeed
    )

    -- Resolve and clamp propulsion speed.
    speed = tonumber(speed)
        or tonumber(self.PropelSpeed)
        or tonumber(self.PowerSpeed)
        or 5000

    speed = math.Clamp(
        speed,
        minSpeed,
        maxSpeed
    )

    -- Resolve the independent steering rate.
    turnRate = tonumber(turnRate)
        or tonumber(self.PropelTurnSpeed)
        or 1200

    turnRate = math.max(turnRate, 0)

    -- Capture the current horizontal forward direction.
    local forward = self:GetForward()

    local direction = Vector(
        forward.x,
        forward.y,
        0
    )

    if direction:IsZero() then
        return false
    end

    direction:Normalize()

    local alreadyPropelling =
        self._HitmenForwardPropulsion == true

    -- Save the original locomotion settings only once.
    if self.loco and not alreadyPropelling then
        self._HitmenPropelOriginalAcceleration = nil
        self._HitmenPropelOriginalDeceleration = nil
        self._HitmenPropelOriginalDesiredSpeed = nil

        if isfunction(self.loco.GetAcceleration) then
            self._HitmenPropelOriginalAcceleration =
                self.loco:GetAcceleration()
        end

        if isfunction(self.loco.GetDeceleration) then
            self._HitmenPropelOriginalDeceleration =
                self.loco:GetDeceleration()
        end

        if isfunction(self.loco.GetDesiredSpeed) then
            self._HitmenPropelOriginalDesiredSpeed =
                self.loco:GetDesiredSpeed()
        end
    end

    -- Invalidate any older propulsion timer.
    self._HitmenForwardPropulsionToken =
        (self._HitmenForwardPropulsionToken or 0) + 1

    local token = self._HitmenForwardPropulsionToken

    -- Activate propulsion.
    self._HitmenForwardPropulsion = true

    self._HitmenForwardPropulsionDirection = direction
    self._HitmenForwardPropulsionSpeed = speed
    self._HitmenForwardPropulsionTurnSpeed = turnRate
    self._HitmenForwardPropulsionEnd = nil

    self._HitmenPropelLastTurnTime = CurTime()

    -- Raise locomotion acceleration for propulsion.
    if self.loco then
        if isfunction(self.loco.SetAcceleration) then
            self.loco:SetAcceleration(
                math.max(
                    tonumber(self.PropelAcceleration) or 100000,
                    1
                )
            )
        end

        if isfunction(self.loco.SetDeceleration) then
            self.loco:SetDeceleration(
                math.max(
                    tonumber(self.PropelDeceleration) or 100000,
                    1
                )
            )
        end

        if isfunction(self.loco.SetDesiredSpeed) then
            self.loco:SetDesiredSpeed(speed)
        end
    end

    -- Automatically stop after the specified duration.
    if duration ~= nil then
        self._HitmenForwardPropulsionEnd =
            CurTime() + duration

        timer.Simple(duration, function()
            if not IsValid(self) then
                return
            end

            -- Prevent stale timers from stopping a newer activation.
            if self._HitmenForwardPropulsionToken ~= token then
                return
            end

            self:StopPropellingForward()
        end)
    end

    return true
end

-- Stops propulsion and restores saved locomotion settings.
function ENT:StopPropellingForward()
    if not SERVER or not IsValid(self) then
        return false
    end

    local wasPropelling =
        self._HitmenForwardPropulsion == true

    -- Invalidate pending propulsion timers.
    self._HitmenForwardPropulsionToken =
        (self._HitmenForwardPropulsionToken or 0) + 1

    self._HitmenForwardPropulsion = nil
    self._HitmenForwardPropulsionDirection = nil
    self._HitmenForwardPropulsionSpeed = nil
    self._HitmenForwardPropulsionTurnSpeed = nil
    self._HitmenForwardPropulsionEnd = nil
    self._HitmenPropelLastTurnTime = nil

    if self.loco then
        local originalAcceleration =
            self._HitmenPropelOriginalAcceleration

        local originalDeceleration =
            self._HitmenPropelOriginalDeceleration

        local originalDesiredSpeed =
            self._HitmenPropelOriginalDesiredSpeed

        if isfunction(self.loco.SetAcceleration) then
            self.loco:SetAcceleration(
                tonumber(originalAcceleration)
                    or tonumber(self.Acceleration)
                    or 10000
            )
        end

        if isfunction(self.loco.SetDeceleration) then
            self.loco:SetDeceleration(
                tonumber(originalDeceleration)
                    or tonumber(self.Deceleration)
                    or 10000
            )
        end

        if isfunction(self.loco.SetDesiredSpeed) then
            self.loco:SetDesiredSpeed(
                tonumber(originalDesiredSpeed)
                    or tonumber(self.RunSpeed)
                    or 350
            )
        end

        -- Cancel horizontal velocity, retaining vertical velocity.
        local velocity = self:GetVelocity()

        self.loco:SetVelocity(
            Vector(0, 0, velocity.z)
        )
    end

    self._HitmenPropelOriginalAcceleration = nil
    self._HitmenPropelOriginalDeceleration = nil
    self._HitmenPropelOriginalDesiredSpeed = nil

    return wasPropelling
end

-- Returns whether propulsion is active.
function ENT:IsPropellingForward()
    if self._HitmenForwardPropulsion ~= true then
        return false
    end

    local endTime = self._HitmenForwardPropulsionEnd

    if endTime and CurTime() >= endTime then
        self:StopPropellingForward()
        return false
    end

    return true
end

--------------------------------------------------
-- P-METER
--------------------------------------------------

function ENT:InitializePMeter()
    self._PMeter = 0
    self._PMeterLastUpdate = CurTime()
    self._SlowWalking = false
	
	if SERVER then
		self:SetNW2Float("HitmenPMeter", 0)
		self:SetNW2Float("HitmenPMeterMax", self.PMeterMax or 100)
	end

    local forward = self:GetForward()

    self._PMeterDirection = Vector(
        forward.x,
        forward.y,
        0
    )

    if not self._PMeterDirection:IsZero() then
        self._PMeterDirection:Normalize()
    end

    self:InitializeHitmenAnimationSpeeds()
end

function ENT:IsSlowWalking()
    return self._SlowWalking == true and self:IsPossessed()
end

function ENT:GetPMeter()
    return self._PMeter or 0
end

function ENT:SetPMeter(value)
    local meterMax = math.max(
        tonumber(self.PMeterMax) or 100,
        1
    )

    self._PMeter = math.Clamp(value, 0, meterMax)

    if SERVER then
        self:SetNW2Float(
            "HitmenPMeter",
            self._PMeter
        )

        self:SetNW2Float(
            "HitmenPMeterMax",
            meterMax
        )
    end
end

function ENT:SetPMeterMechanicsEnabled(enabled)
    self._HitmenPMeterMechanicsEnabled = enabled ~= false
end

function ENT:GetPMeterMechanicsEnabled()
    return self._HitmenPMeterMechanicsEnabled ~= false
end

function ENT:UpdatePMeter(dt, running, maintaining)
    local meter = self:GetPMeter()

    if not self:GetPMeterMechanicsEnabled() then
        meter = meter - self.PMeterDecayRate * dt
    elseif running then
        meter = meter + self.PMeterBuildRate * dt
    elseif maintaining then
        return
    else
        meter = meter - self.PMeterDecayRate * dt
    end

    self:SetPMeter(meter)
end

function ENT:GetPMeterSpeed()
    local fraction = self:GetPMeter() / self.PMeterMax

    return Lerp(
        fraction,
        self.RunSpeed,
        self.PowerSpeed
    )
end

--------------------------------------------------
-- P-METER TURNING
--------------------------------------------------

function ENT:DrainPMeterForTurn(oldDirection, newDirection)
    if self:GetPMeter() <= 0 then return end
    if not oldDirection or not newDirection then return end
    if oldDirection:IsZero() or newDirection:IsZero() then return end

    oldDirection = Vector(
        oldDirection.x,
        oldDirection.y,
        0
    )

    newDirection = Vector(
        newDirection.x,
        newDirection.y,
        0
    )

    if oldDirection:IsZero() or newDirection:IsZero() then return end

    oldDirection:Normalize()
    newDirection:Normalize()

    local dot = math.Clamp(
        oldDirection:Dot(newDirection),
        -1,
        1
    )

    local angle = math.deg(math.acos(dot))

    local resistance = math.max(self.TurnResistance or 0, 0)
    local multiplier = math.max(self.TurnDrainMultiplier or 0, 0)
    local perDegree = math.max(self.TurnDrainPerDegree or 0, 0)

    local drain = angle * resistance * multiplier * perDegree

    self:SetPMeter(self:GetPMeter() - drain)
end

function ENT:TurnTowardDirection(targetDirection, dt, turnSpeed, drainTurn)
    if not targetDirection then return end

    targetDirection = Vector(
        targetDirection.x,
        targetDirection.y,
        0
    )

    if targetDirection:IsZero() then return end

    targetDirection:Normalize()

    local oldForward = self:GetForward()

    oldForward = Vector(
        oldForward.x,
        oldForward.y,
        0
    )

    if oldForward:IsZero() then return end

    oldForward:Normalize()

    local currentAngle = self:GetAngles().y
    local desiredAngle = targetDirection:Angle().y

    local difference = math.AngleDifference(
        desiredAngle,
        currentAngle
    )

    local speed = math.max(
        turnSpeed or self.TurnSpeed,
        0
    )

    local easeOut = math.max(self.TurnEaseOut or 10, 0)

    local maxTurn = speed * dt
    local easedTurn = math.abs(difference) * easeOut * dt

    local turnAmount = math.min(
        math.abs(difference),
        maxTurn,
        easedTurn
    )

    if difference < 0 then
        turnAmount = -turnAmount
    end

    if math.abs(difference) <= 0.1 then
        self:SetAngles(
            Angle(0, desiredAngle, 0)
        )
    elseif math.abs(turnAmount) > 0 then
        self:SetAngles(
            Angle(
                0,
                currentAngle + turnAmount,
                0
            )
        )
    end

    local newForward = self:GetForward()

    newForward = Vector(
        newForward.x,
        newForward.y,
        0
    )

    if not newForward:IsZero() then
        newForward:Normalize()

        if drainTurn and self:GetPMeter() > 0 then
            self:DrainPMeterForTurn(
                oldForward,
                newForward
            )
        end

        self._PMeterDirection = newForward
    end
end

--------------------------------------------------
-- POSSESSION CONTROLS
--------------------------------------------------

function ENT:PossessionControls(forward, backward, right, left, moveDir)

    --------------------------------------------------
    -- FORWARD PROPULSION OVERRIDE
    --------------------------------------------------

    if self:IsPropellingForward() then
        local direction =
            self._HitmenForwardPropulsionDirection

        local speed =
            self._HitmenForwardPropulsionSpeed
            or self.PropelSpeed
            or 5000

        if self.loco and direction and not direction:IsZero() then

            -- Permit steering while possessed.
            -- This does not enable the slow-walking state.
            if self:IsPossessed() then
                local possessor = self:GetPossessor()

                if IsValid(possessor) then
                    local targetDirection =
                        self:PossessorForward()

                    if targetDirection
                        and not targetDirection:IsZero() then

                        local now = CurTime()

                        local turnDT = math.Clamp(
                            now - (self._HitmenPropelLastTurnTime or now),
                            0,
                            0.1
                        )

                        self._HitmenPropelLastTurnTime = now

                        self:TurnTowardDirection(
                            targetDirection,
                            turnDT,
                            self._HitmenForwardPropulsionTurnSpeed
                                or self.PropelTurnSpeed
                                or 1200,
                            false
                        )
                    end
                end
            end

            -- Keep propulsion aligned with the entity's
            -- newly adjusted facing direction.
            local forwardDirection = self:GetForward()

            direction = Vector(
                forwardDirection.x,
                forwardDirection.y,
                0
            )

            if not direction:IsZero() then
                direction:Normalize()

                self._HitmenForwardPropulsionDirection =
                    direction
            else
                self:StopPropellingForward()
                return
            end

            -- Maintain the selected propulsion speed.
            self:SetSpeed(speed)

            if isfunction(self.loco.SetDesiredSpeed) then
                self.loco:SetDesiredSpeed(speed)
            end

            -- Approach a point farther ahead to accommodate
            -- very high propulsion speeds.
            local targetDistance = math.max(speed, 1000)

            self:Approach(
                self:GetPos() + direction * targetDistance
            )

            return
        end

        self:StopPropellingForward()
    end

    --------------------------------------------------
    -- NORMAL POSSESSION MOVEMENT
    --------------------------------------------------

    if not self:IsPossessed() then return end

    if not self:GetMovementEnabled() then
        if self.loco then
            local velocity = self:GetVelocity()

            self.loco:SetVelocity(
                Vector(0, 0, velocity.z)
            )
        end

        return
    end

    local possessor = self:GetPossessor()

	if not IsValid(possessor) then return end

	self:SetNW2Entity(
		"HitmenPossessor",
		possessor
	)

    local now = CurTime()

    local dt = math.Clamp(
        now - (self._PMeterLastUpdate or now),
        0,
        0.1
    )

    self._PMeterLastUpdate = now

    local forwardDir = self:PossessorForward()
    local rightDir = self:PossessorRight()

    forwardDir = Vector(
        forwardDir.x,
        forwardDir.y,
        0
    )

    rightDir = Vector(
        rightDir.x,
        rightDir.y,
        0
    )

    if forwardDir:IsZero() then
        local currentForward = self:GetForward()

        forwardDir = Vector(
            currentForward.x,
            currentForward.y,
            0
        )
    end

    if not forwardDir:IsZero() then
        forwardDir:Normalize()
    end

    if rightDir:IsZero() and not forwardDir:IsZero() then
        rightDir = Vector(
            -forwardDir.y,
            forwardDir.x,
            0
        )
    end

    if not rightDir:IsZero() then
        rightDir:Normalize()
    end

    local direction = Vector(0, 0, 0)

    if forward then
        direction = direction + forwardDir
    end

    if backward then
        direction = direction - forwardDir
    end

    if right then
        direction = direction + rightDir
    end

    if left then
        direction = direction - rightDir
    end

    direction.z = 0

    local hasInput = not direction:IsZero()

    if hasInput then
        direction:Normalize()
    end

    local anyMovementInput = forward or backward or right or left
    local noDirectionalInput = not anyMovementInput
    local movingForward = forward and not backward

    local wantsPower = possessor:KeyDown(IN_SPEED)
    local wantsWalkInput = possessor:KeyDown(IN_WALK)

    local threshold = math.Clamp(
        self.SlowWalkPMeterThreshold or 0,
        0,
        self.PMeterMax
    )

    local pRunning = wantsPower

    local wantsWalk = wantsWalkInput
        and not wantsPower
        and self:GetPMeter() <= threshold

    if wantsWalk then
        self:SetPMeter(0)
    end

    self._SlowWalking = wantsWalk

    local meterWasActive = self:GetPMeter() > 0

    if wantsWalk then
        self:TurnTowardDirection(
            forwardDir,
            dt,
            self.TurnSpeed,
            false
        )
    elseif pRunning or meterWasActive then
        local shouldTurnWhileLocked =
            movingForward
            or (noDirectionalInput and meterWasActive)

        if shouldTurnWhileLocked then
            self:TurnTowardDirection(
                forwardDir,
                dt,
                self.TurnSpeed,
                meterWasActive
            )
        end
    end

    local isBuildingPMeter = pRunning and movingForward

    local isMaintainingPMeter = pRunning
        and meterWasActive
        and not isBuildingPMeter

    self:UpdatePMeter(
        dt,
        isBuildingPMeter,
        isMaintainingPMeter
    )

    local meterLocked = pRunning or self:GetPMeter() > 0

    if meterLocked then
        self:SetSpeed(self:GetPMeterSpeed())

        local shouldMoveForward =
            movingForward
            or (
                noDirectionalInput
                and self:GetPMeter() > 0
            )

        if shouldMoveForward then
            local runDirection = self:GetForward()

            runDirection = Vector(
                runDirection.x,
                runDirection.y,
                0
            )

            if not runDirection:IsZero() then
                runDirection:Normalize()

                self._PMeterDirection = runDirection

                self:Approach(
                    self:GetPos() + runDirection
                )
            else
                local velocity = self:GetVelocity()

                self.loco:SetVelocity(
                    Vector(0, 0, velocity.z)
                )
            end
        else
            local velocity = self:GetVelocity()

            self.loco:SetVelocity(
                Vector(0, 0, velocity.z)
            )
        end

        return
    end

    if wantsWalk then
        self:SetSpeed(self.WalkSpeed)
    else
        self:SetSpeed(self.RunSpeed)
    end

    if hasInput then
        if not wantsWalk then
            self:TurnTowardDirection(
                direction,
                dt,
                self.TurnSpeed,
                false
            )
        end

        self:Approach(
            self:GetPos() + direction
        )

        return
    end

    local velocity = self:GetVelocity()

    self.loco:SetVelocity(
        Vector(0, 0, velocity.z)
    )
end

--------------------------------------------------
-- BODY ANIMATION UPDATE
--------------------------------------------------

function ENT:BodyUpdate()
    local powerRun = false

    if self:IsPossessed() then
        local possessor = self:GetPossessor()

        powerRun = IsValid(possessor)
            and possessor:KeyDown(IN_SPEED)
    end

    if powerRun then
        self:BodyMoveXY({rate = false})

        self:SetPlaybackRate(
            self:GetHitmenPowerRunAnimationRate()
        )
    else
        self:BodyMoveXY()
    end
end

--------------------------------------------------
-- INITIALIZATION
--------------------------------------------------

function ENT:CustomInitialize()
    self:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
    self:InitializeHitmenAnimationSpeeds()
    self:InitializePMeter()
end