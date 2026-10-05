ENT.Abilities = ENT.Abilities or {}

local DEFAULT_PASSIVE_INTERVAL = 0.05

local MOUSE_ALIASES = {
    LEFT = "MOUSE_LEFT",
    LEFT_CLICK = "MOUSE_LEFT",
    LEFTCLICK = "MOUSE_LEFT",
    MOUSE1 = "MOUSE_LEFT",

    RIGHT = "MOUSE_RIGHT",
    RIGHT_CLICK = "MOUSE_RIGHT",
    RIGHTCLICK = "MOUSE_RIGHT",
    MOUSE2 = "MOUSE_RIGHT",

    MIDDLE = "MOUSE_MIDDLE",
    MIDDLE_CLICK = "MOUSE_MIDDLE",
    MIDDLECLICK = "MOUSE_MIDDLE",
    MOUSE3 = "MOUSE_MIDDLE",

    MOUSE4 = "MOUSE_4",
    MOUSE5 = "MOUSE_5"
}

local function ResolveAbilityKey(key)
    if isnumber(key) then
        return key
    end

    if not isstring(key) then
        return nil
    end

    key = string.upper(string.Trim(key))

    key = MOUSE_ALIASES[key] or key

    if isnumber(_G[key]) then
        return _G[key]
    end

    if isnumber(_G["KEY_" .. key]) then
        return _G["KEY_" .. key]
    end

    return nil
end

local function AbilityMatchesButton(ability, button)
    if not istable(ability) then
        return false
    end

    if ability.key ~= nil
        and ResolveAbilityKey(ability.key) == button then
        return true
    end

    if ability.mouse ~= nil
        and ResolveAbilityKey(ability.mouse) == button then
        return true
    end

    return false
end

local function GetPassiveTimerName(ent, id)
    return "HitmenPassiveAbility_"
        .. ent:EntIndex()
        .. "_"
        .. tostring(id)
end

local function StopPassiveAbility(ent, id, timerName)
    timer.Remove(timerName)

    if IsValid(ent) and ent._AbilityPassiveTimers then
        ent._AbilityPassiveTimers[id] = nil
    end
end

local function StartPassiveAbility(ent, id, ability)
    if not SERVER or not IsValid(ent) then
        return
    end

    if not istable(ability)
        or ability.passive ~= true
        or not isfunction(ability.func) then
        return
    end

    ent._AbilityPassiveTimers = ent._AbilityPassiveTimers or {}

    local timerName = ent._AbilityPassiveTimers[id]

    if timerName and timer.Exists(timerName) then
        return
    end

    timerName = GetPassiveTimerName(ent, id)

    if timer.Exists(timerName) then
        ent._AbilityPassiveTimers[id] = timerName
        return
    end

    local interval = math.max(
        tonumber(ability.passiveInterval)
            or DEFAULT_PASSIVE_INTERVAL,
        0.01
    )

    ent._AbilityPassiveTimers[id] = timerName

    timer.Create(timerName, interval, 0, function()
        if not IsValid(ent) then
            timer.Remove(timerName)
            return
        end

        local currentAbility = ent.Abilities
            and ent.Abilities[id]

        if currentAbility ~= ability
            or not istable(currentAbility)
            or currentAbility.passive ~= true
            or not isfunction(currentAbility.func) then

            StopPassiveAbility(ent, id, timerName)
            return
        end

        if isfunction(ent.IsDead) and ent:IsDead() then
            return
        end

        local ok, err = pcall(ability.func, ent)

        if not ok then
            ErrorNoHalt(
                "[Hitmen Passive Ability] "
                .. tostring(id)
                .. ": "
                .. tostring(err)
                .. "\n"
            )

            StopPassiveAbility(ent, id, timerName)
        end
    end)
end

function ENT:InitializeAbilities()
    if not SERVER then
        return
    end

    self._AbilityCooldowns = self._AbilityCooldowns or {}
    self._AbilityExecuting = self._AbilityExecuting or {}
    self._AbilityPassiveTimers = self._AbilityPassiveTimers or {}

    for id, ability in pairs(self.Abilities or {}) do
        if istable(ability) and ability.passive == true then
            StartPassiveAbility(self, id, ability)
        end
    end
end

function ENT:ActivateAbility(id)
    if not SERVER or not IsValid(self) then
        return false
    end

    if not self.IsPossessed or not self:IsPossessed() then
        return false
    end

    self:InitializeAbilities()

    local ability = self.Abilities and self.Abilities[id]

    if not istable(ability) or not isfunction(ability.func) then
        return false
    end

    if ability.passive == true then
        return false
    end

    self._AbilityCooldowns = self._AbilityCooldowns or {}
    self._AbilityExecuting = self._AbilityExecuting or {}

    local now = CurTime()

    if self._AbilityExecuting[id] then
        return false
    end

    if now < (self._AbilityCooldowns[id] or 0) then
        return false
    end

    if isfunction(ability.canActivate)
        and ability.canActivate(self) ~= true then
        return false
    end

    self._AbilityExecuting[id] = true

    local ok, cooldown = pcall(ability.func, self)

    if IsValid(self) and self._AbilityExecuting then
        self._AbilityExecuting[id] = nil
    end

    if not ok then
        ErrorNoHalt(
            "[Hitmen Abilities] "
            .. tostring(id)
            .. ": "
            .. tostring(cooldown)
            .. "\n"
        )

        return false
    end

    if not IsValid(self) then
        return false
    end

    cooldown = tonumber(cooldown) or 0
    cooldown = math.max(cooldown, 0)

    self._AbilityCooldowns[id] = CurTime() + cooldown

    return true, cooldown
end

function ENT:CancelAbilities()
    self._AbilityExecuting = {}

    for id, timerName in pairs(self._AbilityPassiveTimers or {}) do
        timer.Remove(timerName)
        self._AbilityPassiveTimers[id] = nil
    end
end

if SERVER then
    local function InitializeEntityAbilities(ent)
        if not IsValid(ent) then
            return
        end

        if not isfunction(ent.InitializeAbilities) then
            return
        end

        if not istable(ent.Abilities) then
            return
        end

        ent:InitializeAbilities()
    end

    hook.Add(
        "OnEntityCreated",
        "Hitmen_InitializeAbilities",
        function(ent)
            timer.Simple(0, function()
                InitializeEntityAbilities(ent)
            end)
        end
    )

    timer.Simple(0, function()
        for _, ent in ipairs(ents.GetAll()) do
            InitializeEntityAbilities(ent)
        end
    end)

    hook.Add(
        "PlayerButtonDown",
        "Hitmen_AbilityKeybinds",
        function(ply, button)
            if not IsValid(ply) then
                return
            end

            if not IsFirstTimePredicted() then
                return
            end

            for _, bot in ipairs(ents.GetAll()) do
                if not IsValid(bot)
                    or not istable(bot.Abilities)
                    or not isfunction(bot.GetPossessor)
                    or bot:GetPossessor() ~= ply then
                    continue
                end

                for id, ability in pairs(bot.Abilities) do
                    if istable(ability)
                        and ability.passive ~= true
                        and AbilityMatchesButton(ability, button) then

                        bot:ActivateAbility(id)
                        return
                    end
                end
            end
        end
    )
end