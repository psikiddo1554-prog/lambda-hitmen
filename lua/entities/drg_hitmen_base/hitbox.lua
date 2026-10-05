local HITBOX_VISUAL_NET = "HitmenCustomHitboxVisual"

local DEFAULT_CHECK_INTERVAL = 0.01
local DEFAULT_PULSE_DURATION = 0.1
local DEFAULT_SPAWN_INTERVAL = 0.025
local DEFAULT_SEQUENCE_DURATION = 0.25

local DRAW_HITBOXES = true

local HITBOX_FILL_COLOR = Color(255, 0, 0, 65)
local HITBOX_OUTLINE_COLOR = Color(255, 0, 0, 220)

local function AddAngles(a, b)
    return Angle(
        a.p + b.p,
        a.y + b.y,
        a.r + b.r
    )
end

if CLIENT then
    local ActiveVisuals = {}

    local function GetVisualKey(owner, id)
        return owner:EntIndex() .. "_" .. id
    end

    net.Receive(HITBOX_VISUAL_NET, function()
        local creating = net.ReadBool()
        local owner = net.ReadEntity()
        local id = net.ReadUInt(32)

        if not IsValid(owner) then return end

        local key = GetVisualKey(owner, id)

        if not creating then
            ActiveVisuals[key] = nil
            return
        end

        local expiresAt = net.ReadFloat()
        local followOwner = net.ReadBool()
        local offset = net.ReadVector()
        local angleOffset = net.ReadAngle()
        local mins = net.ReadVector()
        local maxs = net.ReadVector()
        local position = net.ReadVector()
        local angles = net.ReadAngle()

        ActiveVisuals[key] = {
            owner = owner,
            id = id,
            expiresAt = expiresAt,
            followOwner = followOwner,
            offset = offset,
            angleOffset = angleOffset,
            mins = mins,
            maxs = maxs,
            position = position,
            angles = angles
        }
    end)

    hook.Add(
        "PostDrawTranslucentRenderables",
        "Hitmen_DrawCustomHitboxes",
        function(bDrawingDepth, bDrawingSkybox)
            if not DRAW_HITBOXES then return end
            if bDrawingDepth or bDrawingSkybox then return end

            render.SetColorMaterial()

            for key, hitbox in pairs(ActiveVisuals) do
                local owner = hitbox.owner

                if not IsValid(owner)
                    or CurTime() >= hitbox.expiresAt then

                    ActiveVisuals[key] = nil
                    continue
                end

                local position
                local angles

                if hitbox.followOwner then
                    position = owner:LocalToWorld(hitbox.offset)

                    angles = AddAngles(
                        owner:GetAngles(),
                        hitbox.angleOffset
                    )
                else
                    position = hitbox.position
                    angles = hitbox.angles
                end

                render.DrawBox(
                    position,
                    angles,
                    hitbox.mins,
                    hitbox.maxs,
                    HITBOX_FILL_COLOR
                )

                render.DrawWireframeBox(
                    position,
                    angles,
                    hitbox.mins,
                    hitbox.maxs,
                    HITBOX_OUTLINE_COLOR,
                    false
                )
            end
        end
    )

    return
end

if not SERVER then return end

util.AddNetworkString(HITBOX_VISUAL_NET)

local Hitbox = {}
Hitbox.__index = Hitbox

local function LogHitboxError(id, err)
    ErrorNoHalt(
        "[Hitmen Hitbox] "
        .. tostring(id)
        .. ": "
        .. tostring(err)
        .. "\n"
    )
end

local function SendHitboxVisual(hitbox, creating)
    local owner = hitbox.owner

    if not IsValid(owner) then return end

    net.Start(HITBOX_VISUAL_NET)
    net.WriteBool(creating)
    net.WriteEntity(owner)
    net.WriteUInt(hitbox.id, 32)

    if creating then
        net.WriteFloat(hitbox.expiresAt)
        net.WriteBool(hitbox.followOwner)
        net.WriteVector(hitbox.offset)
        net.WriteAngle(hitbox.angleOffset)
        net.WriteVector(hitbox.mins)
        net.WriteVector(hitbox.maxs)
        net.WriteVector(hitbox.startPosition)
        net.WriteAngle(hitbox.startAngles)
    end

    net.Broadcast()
end

function Hitbox:IsActive()
    return self.active == true
end

function Hitbox:Remove()
    if not self.active then return end

    self.active = false

    timer.Remove(self.timerName)

    local owner = self.owner

    if IsValid(owner) and owner._CustomHitboxes then
        owner._CustomHitboxes[self.id] = nil
    end

    if self.visualSent then
        SendHitboxVisual(self, false)
        self.visualSent = false
    end
end

function Hitbox:GetPosition()
    if not self.followOwner or not IsValid(self.owner) then
        return self.startPosition
    end

    return self.owner:LocalToWorld(self.offset)
end

function Hitbox:GetAngles()
    if not self.followOwner or not IsValid(self.owner) then
        return self.startAngles
    end

    return AddAngles(
        self.owner:GetAngles(),
        self.angleOffset
    )
end

function Hitbox:ShouldHit(target)
    if not IsValid(target)
        or target:IsWorld()
        or target == self.owner then
        return false
    end

    if target:IsPlayer() and isfunction(target.DrG_Possessing) then
        if target:DrG_Possessing() == self.owner then
            return false
        end
    end

    local isPlayer = target:IsPlayer()
    local isNPC = target:IsNPC()
    local isNextBot = target:IsNextBot()

    if not isPlayer and not isNPC and not isNextBot then
        return false
    end

    if isPlayer and not target:Alive() then
        return false
    end

    if (isNPC or isNextBot) and target.Health then
        if target:Health() <= 0 then
            return false
        end
    end

    if not target.WorldSpaceAABB
        or not target.TakeDamageInfo then
        return false
    end

    if target.GetSolid and target:GetSolid() == SOLID_NONE then
        return false
    end

    if istable(self.filter) then
        if self.filter[target] then return false end

        for _, excluded in ipairs(self.filter) do
            if excluded == target then
                return false
            end
        end
    end

    if isfunction(self.shouldHit) then
        local ok, result = pcall(
            self.shouldHit,
            self.owner,
            target,
            self
        )

        if not ok then
            LogHitboxError("shouldHit", result)
            return false
        end

        return result == true
    end

    return true
end

local function GetBoxBoundsInLocalSpace(
    target,
    position,
    angles
)
    local worldMin, worldMax = target:WorldSpaceAABB()

    if not worldMin or not worldMax then
        return nil
    end

    local corners = {
        Vector(worldMin.x, worldMin.y, worldMin.z),
        Vector(worldMin.x, worldMin.y, worldMax.z),
        Vector(worldMin.x, worldMax.y, worldMin.z),
        Vector(worldMin.x, worldMax.y, worldMax.z),
        Vector(worldMax.x, worldMin.y, worldMin.z),
        Vector(worldMax.x, worldMin.y, worldMax.z),
        Vector(worldMax.x, worldMax.y, worldMin.z),
        Vector(worldMax.x, worldMax.y, worldMax.z)
    }

    local localMin = Vector(
        math.huge,
        math.huge,
        math.huge
    )

    local localMax = Vector(
        -math.huge,
        -math.huge,
        -math.huge
    )

    for _, corner in ipairs(corners) do
        local localCorner = WorldToLocal(
            corner,
            angle_zero,
            position,
            angles
        )

        localMin.x = math.min(localMin.x, localCorner.x)
        localMin.y = math.min(localMin.y, localCorner.y)
        localMin.z = math.min(localMin.z, localCorner.z)

        localMax.x = math.max(localMax.x, localCorner.x)
        localMax.y = math.max(localMax.y, localCorner.y)
        localMax.z = math.max(localMax.z, localCorner.z)
    end

    return localMin, localMax
end

function Hitbox:Intersects(target)
    local position = self:GetPosition()
    local angles = self:GetAngles()

    local targetMin, targetMax = GetBoxBoundsInLocalSpace(
        target,
        position,
        angles
    )

    if not targetMin or not targetMax then
        return false
    end

    return targetMax.x >= self.mins.x
        and targetMin.x <= self.maxs.x
        and targetMax.y >= self.mins.y
        and targetMin.y <= self.maxs.y
        and targetMax.z >= self.mins.z
        and targetMin.z <= self.maxs.z
end

function Hitbox:ApplyTo(target)
	if not IsValid(target) or target == self.owner then
		return
	end
	
    if not self:ShouldHit(target) then return end

    if self.hitOnce and self.hitTargets[target] then
        return
    end

    local damage = self.damage

    if isfunction(damage) then
        local ok, result = pcall(
            damage,
            self.owner,
            target,
            self
        )

        if not ok then
            LogHitboxError("damage", result)
            return
        end

        damage = result
    end

    damage = math.max(tonumber(damage) or 0, 0)

    local position = self:GetPosition()
    local damageInfo = DamageInfo()

    local attacker = IsValid(self.attacker)
        and self.attacker
        or self.owner

    local inflictor = IsValid(self.inflictor)
        and self.inflictor
        or attacker

    damageInfo:SetDamage(damage)
    damageInfo:SetDamageType(self.damageType)

    if IsValid(attacker) then
        damageInfo:SetAttacker(attacker)
    end

    if IsValid(inflictor) then
        damageInfo:SetInflictor(inflictor)
    end

    local targetPosition = target:WorldSpaceCenter()
    damageInfo:SetDamagePosition(targetPosition)

    if isnumber(self.force) then
        local direction = targetPosition - position

        if direction:LengthSqr() > 0 then
            direction:Normalize()
        else
            direction = Vector(0, 0, 1)
        end

        damageInfo:SetDamageForce(direction * self.force)
    elseif isvector(self.force) then
        damageInfo:SetDamageForce(self.force)
    end

    if self.hitOnce then
        self.hitTargets[target] = true
    end

    local ok, err = pcall(
        target.TakeDamageInfo,
        target,
        damageInfo
    )

    if not ok then
        if self.hitOnce then
            self.hitTargets[target] = nil
        end

        LogHitboxError("TakeDamageInfo", err)
        return
    end

    if isfunction(self.onHit) then
        local callbackOK, callbackErr = pcall(
            self.onHit,
            self.owner,
            target,
            self,
            damageInfo
        )

        if not callbackOK then
            LogHitboxError("onHit", callbackErr)
        end
    end
end

function Hitbox:Tick()
    if not self.active or not IsValid(self.owner) then
        self:Remove()
        return
    end

    if CurTime() >= self.expiresAt then
        self:Remove()
        return
    end

    for _, target in ipairs(ents.GetAll()) do
        if self:ShouldHit(target)
            and self:Intersects(target) then
            self:ApplyTo(target)
        end
    end
end

function ENT:CreateHitbox(settings)
    if not IsValid(self) then return nil end

    if not istable(settings) then
        LogHitboxError(
            "CreateHitbox",
            "expected a settings table"
        )
        return nil
    end

    local duration = tonumber(settings.duration)
        or DEFAULT_PULSE_DURATION

    if duration <= 0 then
        LogHitboxError(
            "CreateHitbox",
            "duration must be greater than 0"
        )
        return nil
    end

    self._CustomHitboxes = self._CustomHitboxes or {}
    self._HitboxSerial = (self._HitboxSerial or 0) + 1

    local offset = isvector(settings.offset)
        and settings.offset
        or vector_origin

    local angleOffset = isangle(settings.angleOffset)
        and settings.angleOffset
        or angle_zero

    local mins = isvector(settings.mins)
        and settings.mins
        or Vector(-16, -16, -16)

    local maxs = isvector(settings.maxs)
        and settings.maxs
        or Vector(16, 16, 16)

    if mins.x > maxs.x
        or mins.y > maxs.y
        or mins.z > maxs.z then
        LogHitboxError(
            "CreateHitbox",
            "mins must not be greater than maxs"
        )
        return nil
    end

    local id = self._HitboxSerial

    local hitbox = setmetatable({
        id = id,
        owner = self,
        active = true,

        createdAt = CurTime(),
        expiresAt = CurTime() + duration,
        duration = duration,

        interval = math.max(
            tonumber(settings.checkInterval or settings.interval)
                or DEFAULT_CHECK_INTERVAL,
            0.01
        ),

        followOwner = settings.followOwner ~= false,

        offset = offset,
        angleOffset = angleOffset,
        mins = mins,
        maxs = maxs,

        damage = settings.damage ~= nil
            and settings.damage
            or 10,

        damageType = tonumber(settings.damageType) or DMG_CLUB,
        attacker = settings.attacker or self,
        inflictor = settings.inflictor or self,
        force = settings.force,
        filter = settings.filter,
        shouldHit = settings.shouldHit,
        hitOnce = settings.hitOnce ~= false,
        hitTargets = {},
        onHit = settings.onHit,

        startPosition = self:LocalToWorld(offset),

        startAngles = AddAngles(
            self:GetAngles(),
            angleOffset
        )
    }, Hitbox)

    hitbox.timerName = "HitmenCustomHitbox_"
        .. self:EntIndex()
        .. "_"
        .. id

    self._CustomHitboxes[id] = hitbox

    hitbox.visualSent = true
    SendHitboxVisual(hitbox, true)

    local function RunHitbox()
        if not hitbox.active then
            timer.Remove(hitbox.timerName)
            return
        end

        if not IsValid(hitbox.owner)
            or CurTime() >= hitbox.expiresAt then
            hitbox:Remove()
            return
        end

        hitbox:Tick()
    end

    hitbox:Tick()

    if hitbox.active then
        timer.Create(
            hitbox.timerName,
            hitbox.interval,
            0,
            RunHitbox
        )
    end

    return hitbox
end

function ENT:CreateHitboxSequence(settings)
    if not IsValid(self) then return nil end

    if not istable(settings) then
        LogHitboxError(
            "CreateHitboxSequence",
            "expected a settings table"
        )
        return nil
    end

    local sequenceDuration = tonumber(settings.sequenceDuration)
        or DEFAULT_SEQUENCE_DURATION

    if sequenceDuration <= 0 then return nil end

    local spawnInterval = math.max(
        tonumber(settings.spawnInterval)
            or DEFAULT_SPAWN_INTERVAL,
        0.01
    )

    local pulseDuration = math.max(
        tonumber(settings.pulseDuration)
            or DEFAULT_PULSE_DURATION,
        0.01
    )

    local hitSettings = table.Copy(settings)

    hitSettings.sequenceDuration = nil
    hitSettings.totalDuration = nil
    hitSettings.spawnInterval = nil
    hitSettings.pulseDuration = nil

    hitSettings.duration = pulseDuration

    hitSettings.checkInterval = tonumber(settings.checkInterval)
        or DEFAULT_CHECK_INTERVAL

    hitSettings.interval = nil

    local alreadyHit = {}

    if hitSettings.hitOnce ~= false then
        local originalShouldHit = hitSettings.shouldHit
        local originalOnHit = hitSettings.onHit

        hitSettings.shouldHit = function(owner, target, hitbox)
            if alreadyHit[target] then
                return false
            end

            if isfunction(originalShouldHit) then
                return originalShouldHit(
                    owner,
                    target,
                    hitbox
                ) == true
            end

            return true
        end

        hitSettings.onHit = function(
            owner,
            target,
            hitbox,
            damageInfo
        )
            alreadyHit[target] = true

            if isfunction(originalOnHit) then
                originalOnHit(
                    owner,
                    target,
                    hitbox,
                    damageInfo
                )
            end
        end
    end

    self._HitboxSequenceTimers =
        self._HitboxSequenceTimers or {}

    self._HitboxSequenceSerial =
        (self._HitboxSequenceSerial or 0) + 1

    local sequenceID = self._HitboxSequenceSerial

    local timerName = "HitmenHitboxSequence_"
        .. self:EntIndex()
        .. "_"
        .. sequenceID

    local endTime = CurTime() + sequenceDuration

    self._HitboxSequenceTimers[timerName] = true

    local function StopSequence()
        timer.Remove(timerName)

        if IsValid(self) and self._HitboxSequenceTimers then
            self._HitboxSequenceTimers[timerName] = nil
        end
    end

    local function SpawnNextHitbox()
        if not IsValid(self) then
            StopSequence()
            return
        end

        if CurTime() >= endTime then
            StopSequence()
            return
        end

        self:CreateHitbox(hitSettings)
    end

    SpawnNextHitbox()

    timer.Create(timerName, spawnInterval, 0, function()
        if not IsValid(self) then
            timer.Remove(timerName)
            return
        end

        if CurTime() >= endTime then
            StopSequence()
            return
        end

        SpawnNextHitbox()
    end)

    return timerName
end

function ENT:CancelHitboxes()
    for timerName in pairs(self._HitboxSequenceTimers or {}) do
        timer.Remove(timerName)
    end

    self._HitboxSequenceTimers = {}

    local activeHitboxes = {}

    for _, hitbox in pairs(self._CustomHitboxes or {}) do
        activeHitboxes[#activeHitboxes + 1] = hitbox
    end

    for _, hitbox in ipairs(activeHitboxes) do
        hitbox:Remove()
    end
end
