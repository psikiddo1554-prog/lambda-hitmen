if not SERVER then return end

local Hitbox = {}
Hitbox.__index = Hitbox

local DEFAULT_INTERVAL = 0.05

local function LogHitboxError(id, err)
    ErrorNoHalt("[Hitmen Hitbox] " .. tostring(id) .. ": " .. tostring(err) .. "\n")
end

local function AddAngles(a, b)
    return Angle(a.p + b.p, a.y + b.y, a.r + b.r)
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
end

function Hitbox:GetPosition()
    if not IsValid(self.owner) then return self.startPosition end

    return self.owner:LocalToWorld(self.offset)
end

function Hitbox:GetAngles()
    if not IsValid(self.owner) then return self.startAngles end

    return AddAngles(self.owner:GetAngles(), self.angleOffset)
end

function Hitbox:ShouldHit(target)
    if not IsValid(target) or target:IsWorld() or target == self.owner then
        return false
    end

    if not target.WorldSpaceAABB or not target.TakeDamageInfo then
        return false
    end

    if target.GetSolid and target:GetSolid() == SOLID_NONE then
        return false
    end

    if istable(self.filter) then
        if self.filter[target] then return false end
        for _, excluded in ipairs(self.filter) do
            if excluded == target then return false end
        end
    end

    if isfunction(self.shouldHit) then
        local ok, result = pcall(self.shouldHit, self.owner, target, self)
        if not ok then
            LogHitboxError("shouldHit", result)
            return false
        end
        return result == true
    end

    return true
end

local function GetBoxBoundsInLocalSpace(target, position, angles)
    local worldMin, worldMax = target:WorldSpaceAABB()
    if not worldMin or not worldMax then return nil end

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

    local localMin = Vector(math.huge, math.huge, math.huge)
    local localMax = Vector(-math.huge, -math.huge, -math.huge)

    for _, corner in ipairs(corners) do
        local localCorner = WorldToLocal(corner, angle_zero, position, angles)
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

    if self.shape == "sphere" then
        local worldMin, worldMax = target:WorldSpaceAABB()
        if not worldMin or not worldMax then return false end

        local closest = Vector(
            math.Clamp(position.x, worldMin.x, worldMax.x),
            math.Clamp(position.y, worldMin.y, worldMax.y),
            math.Clamp(position.z, worldMin.z, worldMax.z)
        )

        return position:DistToSqr(closest) <= self.radius * self.radius
    end

    local targetMin, targetMax = GetBoxBoundsInLocalSpace(target, position, angles)
    if not targetMin or not targetMax then return false end

    return targetMax.x >= self.mins.x and targetMin.x <= self.maxs.x
        and targetMax.y >= self.mins.y and targetMin.y <= self.maxs.y
        and targetMax.z >= self.mins.z and targetMin.z <= self.maxs.z
end

function Hitbox:ApplyTo(target)
    if self.hitOnce and self.hitTargets[target] then return end

    local damage = self.damage
    if isfunction(damage) then
        local ok, result = pcall(damage, self.owner, target, self)
        if not ok then
            LogHitboxError("damage", result)
            return
        end
        damage = result
    end
    damage = math.max(tonumber(damage) or 0, 0)

    local position = self:GetPosition()
    local damageInfo = DamageInfo()
    local attacker = IsValid(self.attacker) and self.attacker or self.owner
    local inflictor = IsValid(self.inflictor) and self.inflictor or attacker

    damageInfo:SetDamage(damage)
    damageInfo:SetDamageType(self.damageType)
    if IsValid(attacker) then damageInfo:SetAttacker(attacker) end
    if IsValid(inflictor) then damageInfo:SetInflictor(inflictor) end

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

    local ok, err = pcall(target.TakeDamageInfo, target, damageInfo)
    if not ok then
        LogHitboxError("TakeDamageInfo", err)
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
        if self:ShouldHit(target) and self:Intersects(target) then
            self:ApplyTo(target)
        end
    end
end

function ENT:CreateHitbox(settings)
    if not IsValid(self) then return nil end
    if not istable(settings) then
        LogHitboxError("CreateHitbox", "expected a settings table")
        return nil
    end

    local duration = tonumber(settings.duration)
    if not duration or duration <= 0 then
        LogHitboxError("CreateHitbox", "duration must be a number greater than 0")
        return nil
    end

    self._CustomHitboxes = self._CustomHitboxes or {}
    self._HitboxSerial = (self._HitboxSerial or 0) + 1

    local offset = isvector(settings.offset) and settings.offset or vector_origin
    local angleOffset = isangle(settings.angleOffset) and settings.angleOffset or angle_zero
    local shape = settings.shape == "sphere" and "sphere" or "box"
    local radius = math.max(tonumber(settings.radius) or 32, 0)
    local mins = isvector(settings.mins) and settings.mins or Vector(-16, -16, -16)
    local maxs = isvector(settings.maxs) and settings.maxs or Vector(16, 16, 16)

    if shape == "box" and (mins.x > maxs.x or mins.y > maxs.y or mins.z > maxs.z) then
        LogHitboxError("CreateHitbox", "mins must not be greater than maxs")
        return nil
    end
    if shape == "sphere" and radius <= 0 then
        LogHitboxError("CreateHitbox", "sphere radius must be greater than 0")
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
        interval = math.max(tonumber(settings.interval) or DEFAULT_INTERVAL, 0.01),
        shape = shape,
        offset = offset,
        angleOffset = angleOffset,
        radius = radius,
        mins = mins,
        maxs = maxs,
        damage = settings.damage ~= nil and settings.damage or 10,
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
        startAngles = AddAngles(self:GetAngles(), angleOffset)
    }, Hitbox)

    hitbox.timerName = "HitmenCustomHitbox_" .. self:EntIndex() .. "_" .. id
    self._CustomHitboxes[id] = hitbox

    local function runHitbox()
        if not hitbox.active then
            timer.Remove(hitbox.timerName)
            return
        end

        if not IsValid(hitbox.owner) or CurTime() >= hitbox.expiresAt then
            hitbox:Remove()
            return
        end

        hitbox:Tick()
    end

    hitbox:Tick()
    if hitbox.active then
        timer.Create(hitbox.timerName, hitbox.interval, 0, runHitbox)
    end

    return hitbox
end

function ENT:CancelHitboxes()
    if not self._CustomHitboxes then return end

    local activeHitboxes = {}
    for _, hitbox in pairs(self._CustomHitboxes) do
        activeHitboxes[#activeHitboxes + 1] = hitbox
    end

    for _, hitbox in ipairs(activeHitboxes) do
        hitbox:Remove()
    end
end