ENT.WalkSpeed = 175
ENT.RunSpeed = 350
ENT.PowerSpeed = 700

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

function ENT:InitializePMeter()
    self._PMeter = 0
    self._PMeterLastUpdate = CurTime()
    self._SlowWalking = false

    local forward = self:GetForward()
    self._PMeterDirection = Vector(forward.x, forward.y, 0)

    if not self._PMeterDirection:IsZero() then
        self._PMeterDirection:Normalize()
    end
end

function ENT:IsSlowWalking()
    return self._SlowWalking == true and self:IsPossessed()
end

function ENT:GetPMeter()
    return self._PMeter or 0
end

function ENT:SetPMeter(value)
    self._PMeter = math.Clamp(value, 0, self.PMeterMax)
end

function ENT:UpdatePMeter(dt, running)
    local meter = self:GetPMeter()

    if running then
        meter = meter + self.PMeterBuildRate * dt
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

function ENT:DrainPMeterForTurn(oldDirection, newDirection)
    if self:GetPMeter() <= 0 then return end
    if not oldDirection or not newDirection then return end
    if oldDirection:IsZero() or newDirection:IsZero() then return end

    oldDirection = Vector(oldDirection.x, oldDirection.y, 0)
    newDirection = Vector(newDirection.x, newDirection.y, 0)

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
    oldForward = Vector(oldForward.x, oldForward.y, 0)

    if oldForward:IsZero() then return end

    oldForward:Normalize()

    local currentAngle = self:GetAngles().y
    local desiredAngle = targetDirection:Angle().y
    local difference = math.AngleDifference(
        desiredAngle,
        currentAngle
    )

    local speed = math.max(turnSpeed or self.TurnSpeed, 0)
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
        self:SetAngles(Angle(0, desiredAngle, 0))
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
    newForward = Vector(newForward.x, newForward.y, 0)

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

function ENT:PossessionControls(forward, backward, right, left, moveDir)
    if not self:IsPossessed() then return end

    local possessor = self:GetPossessor()
    if not IsValid(possessor) then return end

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

    self:UpdatePMeter(
        dt,
        pRunning and movingForward
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

function ENT:BodyUpdate()
    local powerRun = false

    if self:IsPossessed() then
        local possessor = self:GetPossessor()

        powerRun = IsValid(possessor)
            and possessor:KeyDown(IN_SPEED)
    end

    if powerRun then
        self:BodyMoveXY({rate = false})
        self:SetPlaybackRate(self.PowerRunAnimRate or 1.25)
    else
        self:BodyMoveXY()
    end
end