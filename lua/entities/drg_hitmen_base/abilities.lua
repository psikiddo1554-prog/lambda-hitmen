ENT.Abilities = ENT.Abilities or {}

local ABILITY_INPUT_STATE_NET = "Hitmen_AbilityInputBlocked"
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

-- Completes one particular activation.
-- The execution token prevents an old timer from
-- accidentally finishing a newer activation.
local function FinishAbilityExecution(ent, id, execution, cooldown)
    if not SERVER or not IsValid(ent) then
        return false
    end

    if not istable(ent._AbilityExecuting)
        or ent._AbilityExecuting[id] ~= execution then
        return false
    end

    local ability = execution.ability

    cooldown = tonumber(cooldown)

    if cooldown == nil then
        cooldown = tonumber(ability and ability.cooldown) or 0
    end

    cooldown = math.max(cooldown, 0)

    -- Mark the ability as finished.
    ent._AbilityExecuting[id] = nil

    -- The cooldown begins when the ability finishes.
    ent._AbilityCooldowns = ent._AbilityCooldowns or {}
    ent._AbilityCooldowns[id] = CurTime() + cooldown

    return true, cooldown
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

-- Public completion function.
-- Usage: self:FinishAbility("AbilityName", cooldown)
function ENT:FinishAbility(id, cooldown)
    if not SERVER or not IsValid(self) then
        return false
    end

    local execution = self._AbilityExecuting
        and self._AbilityExecuting[id]

    if not execution then
        return false
    end

    return FinishAbilityExecution(self, id, execution, cooldown)
end

-- Optional alternative name.
ENT.EndAbility = ENT.FinishAbility

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

    -- Do not restart an ability that is still active.
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

    -- Each activation gets its own execution token.
    local execution = {
        ability = ability
    }

    self._AbilityExecuting[id] = execution

    -- This callback can be saved and invoked later.
    -- It does not require the ability to return anything.
    local function finishAbility(cooldown)
        return FinishAbilityExecution(
            self,
            id,
            execution,
            cooldown
        )
    end

    -- The second argument is the completion callback.
    -- The third argument is the ability ID.
    local ok, returnedCooldown = pcall(
        ability.func,
        self,
        finishAbility,
        id
    )

    if not ok then
        -- Avoid leaving a broken ability permanently active.
        FinishAbilityExecution(self, id, execution, 0)

        ErrorNoHalt(
            "[Hitmen Abilities] "
            .. tostring(id)
            .. ": "
            .. tostring(returnedCooldown)
            .. "\n"
        )

        return false
    end

    if not IsValid(self) then
        return false
    end

    -- Backwards compatibility:
    -- returning a number still finishes immediately.
    if isnumber(returnedCooldown) then
        FinishAbilityExecution(
            self,
            id,
            execution,
            returnedCooldown
        )
    end

    -- No numeric return means the ability stays active
    -- unless its completion callback has already fired.
    if self._AbilityExecuting
        and self._AbilityExecuting[id] == execution then
        return true
    end

    local readyAt = self._AbilityCooldowns[id]
    local remainingCooldown = readyAt
        and math.max(readyAt - CurTime(), 0)
        or nil

    return true, remainingCooldown
end

function ENT:CancelAbilities()
    self._AbilityExecuting = {}

    for id, timerName in pairs(self._AbilityPassiveTimers or {}) do
        timer.Remove(timerName)
        self._AbilityPassiveTimers[id] = nil
    end
end

if SERVER then
    util.AddNetworkString(ABILITY_INPUT_STATE_NET)

    net.Receive(ABILITY_INPUT_STATE_NET, function(_, ply)
        if not IsValid(ply) then return end

        ply._HitmenAbilityInputBlocked = net.ReadBool()
    end)

    local function InitializeEntityAbilities(ent)
        if not IsValid(ent) then return end
        if not isfunction(ent.InitializeAbilities) then return end
        if not istable(ent.Abilities) then return end

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
            if not IsValid(ply) then return end
            if not IsFirstTimePredicted() then return end

            if ply._HitmenAbilityInputBlocked then
                return
            end

            if game.GetTimeScale() <= 0.001 then
                return
            end

            local hostTimeScale = GetConVar("host_timescale")

            if hostTimeScale
                and hostTimeScale:GetFloat() <= 0.001 then
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

elseif CLIENT then
    local lastBlockedState = nil

    local function IsPanelOpen(panel)
        return IsValid(panel) and panel:IsVisible()
    end

    local function IsAbilityInputBlocked()
        if gui.IsGameUIVisible() or gui.IsConsoleVisible() then
            return true
        end

        if IsPanelOpen(g_SpawnMenu)
            or IsPanelOpen(g_ContextMenu) then
            return true
        end

        if vgui.CursorVisible() then
            return true
        end

        local focusedPanel = vgui.GetKeyboardFocus()

        if IsValid(focusedPanel)
            and focusedPanel ~= vgui.GetWorldPanel() then
            return true
        end

        return false
    end

    local function SetAbilityInputBlocked(blocked, force)
        blocked = blocked == true

        if not force and lastBlockedState == blocked then
            return
        end

        lastBlockedState = blocked

        net.Start(ABILITY_INPUT_STATE_NET)
        net.WriteBool(blocked)
        net.SendToServer()
    end

    local function RefreshAbilityInputState()
        SetAbilityInputBlocked(IsAbilityInputBlocked())
    end

    hook.Add(
        "Think",
        "Hitmen_AbilityInputUIState",
        RefreshAbilityInputState
    )

    hook.Add(
        "OnSpawnMenuOpen",
        "Hitmen_BlockAbilitiesSpawnMenu",
        function()
            SetAbilityInputBlocked(true)
        end
    )

    hook.Add(
        "OnContextMenuOpen",
        "Hitmen_BlockAbilitiesContextMenu",
        function()
            SetAbilityInputBlocked(true)
        end
    )

    hook.Add(
        "OnPauseMenuShow",
        "Hitmen_BlockAbilitiesPauseMenu",
        function()
            SetAbilityInputBlocked(true)
        end
    )

    hook.Add(
        "OnSpawnMenuClose",
        "Hitmen_UnblockAbilitiesSpawnMenu",
        function()
            timer.Simple(0, RefreshAbilityInputState)
        end
    )

    hook.Add(
        "OnContextMenuClose",
        "Hitmen_UnblockAbilitiesContextMenu",
        function()
            timer.Simple(0, RefreshAbilityInputState)
        end
    )

    timer.Simple(0, function()
        SetAbilityInputBlocked(IsAbilityInputBlocked(), true)
    end)
end