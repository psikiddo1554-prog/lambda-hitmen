
if not CLIENT then return end

local HUD_NAME = "Hitmen_PMeterHUD"

-- P-meter layout
local BAR_WIDTH = 500
local BAR_HEIGHT = 18
local BAR_BOTTOM_OFFSET = 70
local LERP_SPEED = 10

local COLOR_EMPTY = Color(45, 51, 62, 230)
local COLOR_FILL = Color(255, 190, 55, 255)
local COLOR_BORDER = Color(255, 255, 255, 255)
local COLOR_TEXT = Color(255, 255, 255, 255)

-- P-meter sound and flickering
local FULL_SOUND = "pmeter.wav"
local FULL_SOUND_VOLUME = 0.25
local FULL_SOUND_PITCH = 100

local COLOR_FLASH = Color(175, 110, 20, 255)
local FLICKER_RATE = 16

-- Ability row layout
local ABILITY_ICON_SIZE = 65
local ABILITY_ICON_GAP = 21
local ABILITY_ROW_GAP = 18

local ABILITY_NAME_MAX_WIDTH =
    ABILITY_ICON_SIZE + ABILITY_ICON_GAP - 8

local ABILITY_NAME_LINE_GAP = 1

-- Ability animations
local ABILITY_ACTIVE_SCALE = 1.12
local ABILITY_COOLDOWN_SCALE = 0.90
local ABILITY_TRANSITION_SPEED = 12

-- Plays once when an ability finishes its cooldown.
-- Replace this with a custom path such as "lambda-hitmen/ability_ready.wav"
-- if you add that file under your addon's sound/ folder.
local ABILITY_READY_SOUND = "ability_ready.wav"

local COLOR_ABILITY_COOLDOWN = Color(175, 110, 20, 255)
local COLOR_COOLDOWN_FILL = Color(175, 110, 20, 135)
local COLOR_ABILITY_BACKGROUND = Color(45, 51, 62, 230)

local COOLDOWN_FILL_EPSILON = 0.005

local ABILITY_GLYPH_SCALE = 0.85
local ABILITY_GLYPH_ACTIVE_ANGLE = 5
local ABILITY_GLYPH_TRANSITION_SPEED = 12

local HEALTHBAR_MAX_DISTANCE = 200
local HEALTHBAR_SCAN_DISTANCE = 1050
local HEALTHBAR_SCAN_INTERVAL = 0.10

local HEALTHBAR_WIDTH = 110
local HEALTHBAR_HEIGHT = 8
local HEALTHBAR_OFFSET_Y = 12
local HEALTHBAR_NAME_GAP = 4

local HEALTHBAR_FADE_SPEED = 18
local HEALTHBAR_COLOR_RETURN_SPEED = 7
local HEALTHBAR_DAMAGE_FLASH_TIME = 0.15

-- Damage shake
local HEALTHBAR_SHAKE_STRENGTH = 0.65
local HEALTHBAR_SHAKE_MAX = 18
local HEALTHBAR_SHAKE_FREQUENCY = 45
local HEALTHBAR_SHAKE_DECAY = 8

-- Healthbar colors
local COLOR_HEALTH_NORMAL = Color(255, 190, 55, 255)
local COLOR_HEALTH_DAMAGE = Color(255, 227, 171, 255)
local COLOR_HEALTH_BACKGROUND = Color(45, 51, 62, 230)

local displayedMeter = 0
local targetMeter = 0

local fullMeterSound = nil
local fullMeterSoundOwner = nil

-- Ability animation state
local abilityVisualStates = {}
local lastAbilityBotIndex = nil
local abilityIconMaterials = {}

surface.CreateFont("HitmenPMeterText", {
    font = "DermaDefaultBold",
    size = 11,
    weight = 600,
    antialias = true
})

surface.CreateFont("HitmenAbilityNameText", {
    font = "DermaDefaultBold",
    size = 12,
    weight = 600,
    antialias = true
})

surface.CreateFont("HitmenAbilityKeyText", {
    font = "DermaDefaultBold",
    size = 14,
    weight = 700,
    antialias = true
})

-- Color interpolation helper.
local function LerpColor(fraction, from, to)
    return Color(
        Lerp(fraction, from.r, to.r),
        Lerp(fraction, from.g, to.g),
        Lerp(fraction, from.b, to.b),
        Lerp(fraction, from.a, to.a)
    )
end

-- Find the nextbot possessed by the local player.
local function FindPossessedHitman()
    local ply = LocalPlayer()

    if not IsValid(ply) then
        return nil
    end

    for _, ent in ipairs(ents.GetAll()) do
        if IsValid(ent)
            and ent:GetNW2Entity("HitmenPossessor") == ply then
            return ent
        end
    end

    return nil
end

-- P-meter sound functions.
local function StopFullMeterSound()
    if fullMeterSound then
        fullMeterSound:Stop()
    end
end

local function StartFullMeterSound()
    local ply = LocalPlayer()

    if not IsValid(ply) then
        return
    end

    if not fullMeterSound or fullMeterSoundOwner ~= ply then
        StopFullMeterSound()

        fullMeterSound = CreateSound(ply, FULL_SOUND)
        fullMeterSoundOwner = ply
    end

    if fullMeterSound and not fullMeterSound:IsPlaying() then
        fullMeterSound:PlayEx(
            FULL_SOUND_VOLUME,
            FULL_SOUND_PITCH
        )
    end
end

-- Convert configured ability bindings into readable labels.
local function GetAbilityKeyLabel(ability)
    local key = ability.key or ability.mouse

    if key == nil then
        return "-"
    end

    if isnumber(key) then
        local keyName = input.GetKeyName(key)

        if keyName and keyName ~= "" then
            return string.upper(keyName)
        end

        return tostring(key)
    end

    key = string.upper(string.Trim(tostring(key)))

    local aliases = {
        LEFT = "M1",
        LEFT_CLICK = "M1",
        LEFTCLICK = "M1",
        MOUSE1 = "M1",

        RIGHT = "RMB",
        RIGHT_CLICK = "RMB",
        RIGHTCLICK = "RMB",
        MOUSE2 = "RMB",

        MIDDLE = "MMB",
        MIDDLE_CLICK = "MMB",
        MIDDLECLICK = "MMB",
        MOUSE3 = "MMB",

        MOUSE4 = "M4",
        MOUSE_4 = "M4",
        MOUSE5 = "M5",
        MOUSE_5 = "M5"
    }

    return aliases[key] or string.gsub(key, "^KEY_", "")
end

-- Get the display name of an ability.
local function GetAbilityDisplayName(id, ability)
    if isstring(ability.name) and ability.name ~= "" then
        return ability.name
    end

    if isstring(ability.displayName)
        and ability.displayName ~= "" then
        return ability.displayName
    end

    local name = string.gsub(tostring(id), "_", " ")

    return string.upper(string.sub(name, 1, 1))
        .. string.sub(name, 2)
end

local function WrapAbilityName(text, maxWidth, font)
    text = tostring(text or "")

    surface.SetFont(font)

    local lines = {}
    local currentLine = ""

    local function FinishLine()
        table.insert(lines, currentLine)
        currentLine = ""
    end

    -- Preserve explicitly entered line breaks.
    for paragraph in string.gmatch(text .. "\n", "(.-)\n") do
        local hadWords = false

        for word in string.gmatch(paragraph, "%S+") do
            hadWords = true

            local candidate = currentLine == ""
                and word
                or currentLine .. " " .. word

            local candidateWidth = surface.GetTextSize(candidate)

            if candidateWidth <= maxWidth then
                currentLine = candidate
            else
                -- Finish the current line before starting this word.
                if currentLine ~= "" then
                    FinishLine()
                end

                local wordWidth = surface.GetTextSize(word)

                if wordWidth <= maxWidth then
                    currentLine = word
                else
                    -- Break extremely long words into smaller pieces.
                    for i = 1, #word do
                        local character = string.sub(word, i, i)
                        local nextText = currentLine .. character
                        local nextWidth = surface.GetTextSize(nextText)

                        if currentLine ~= "" and nextWidth > maxWidth then
                            FinishLine()
                        end

                        currentLine = currentLine .. character
                    end

                    FinishLine()
                end
            end
        end

        if currentLine ~= "" then
            FinishLine()
        elseif not hadWords then
            -- Preserve empty lines from explicit line breaks.
            table.insert(lines, "")
        end
    end

    if #lines == 0 then
        lines[1] = text
    end

    return lines
end

-- Must match the network prefix in abilities.lua.
local function GetAbilityNetworkPrefix(id)
    return "HitmenAbilityHUD_" .. tostring(id) .. "_"
end

-- Collect non-passive abilities in a stable display order.
local function GetDisplayedAbilities(hitman)
    local entries = {}

    for id, ability in pairs(hitman.Abilities or {}) do
        if istable(ability) then
            local name = GetAbilityDisplayName(id, ability)

            local isBaseClass =
                string.lower(tostring(id)) == "baseclass"
                or string.lower(name) == "baseclass"

            if not isBaseClass
                and ability.passive ~= true
                and ability.showInHUD ~= false then

                entries[#entries + 1] = {
                    id = id,
                    data = ability,
                    order = tonumber(ability.order)
                        or tonumber(ability.hudOrder)
                        or math.huge,
                    name = name,
                    key = GetAbilityKeyLabel(ability)
                }
            end
        end
    end

    table.sort(entries, function(a, b)
        if a.order ~= b.order then
            return a.order < b.order
        end

        return tostring(a.id) < tostring(b.id)
    end)

    return entries
end

-- Get or initialize animation state for an ability.
local function GetAbilityVisualState(hitman, id)
    local cacheKey = hitman:EntIndex() .. "_" .. tostring(id)

    if not abilityVisualStates[cacheKey] then
        abilityVisualStates[cacheKey] = {
            scale = 1,

            color = Color(
                COLOR_BORDER.r,
                COLOR_BORDER.g,
                COLOR_BORDER.b,
                COLOR_BORDER.a
            ),

            backgroundAlpha = COLOR_ABILITY_BACKGROUND.a,
            cooldownFill = 0,

            -- Cooldown sound tracking (prevents repeated playback each frame).
            wasCooldownTimerRunning = false,
            pendingReadySound = false,

            glyphAlpha = 255,
            glyphAngle = 0
        }
    end

    return abilityVisualStates[cacheKey]
end

-- Cache ability icon materials.
local function GetAbilityMaterial(path)
    if not isstring(path) or path == "" then
        return nil
    end

    if not abilityIconMaterials[path] then
        abilityIconMaterials[path] = Material(path, "smooth")
    end

    local mat = abilityIconMaterials[path]

    if mat and not mat:IsError() then
        return mat
    end

    return nil
end

-- Draw one ability icon.
local function DrawAbilityIcon(hitman, entry, centerX, baseY)
    local id = entry.id
    local ability = entry.data
    local state = GetAbilityVisualState(hitman, id)

    local prefix = GetAbilityNetworkPrefix(id)

    local active = hitman:GetNW2Bool(
        prefix .. "Active",
        false
    )

    local cooldownEnd = hitman:GetNW2Float(
        prefix .. "CooldownEnd",
        0
    )

    local cooldownDuration = hitman:GetNW2Float(
        prefix .. "CooldownDuration",
        0
    )

    local now = CurTime()

    -- Track the cooldown timer independently of the active visual state.
    -- If the timer finishes while the ability is still active, queue the
    -- sound until it is no longer active and can actually be used again.
    local cooldownTimerRunning = cooldownEnd > now
        and cooldownDuration > 0

    if state.wasCooldownTimerRunning and not cooldownTimerRunning then
        state.pendingReadySound = true
    end

    state.wasCooldownTimerRunning = cooldownTimerRunning

    if state.pendingReadySound and not active then
        EmitSound(
			ABILITY_READY_SOUND,
			vector_origin,
			-2,
			CHAN_AUTO,
			0.75,
			75,
			0,
			100
		)
        state.pendingReadySound = false
    end

    local onCooldown = not active and cooldownTimerRunning

    -- Cooldown progress fills from bottom to top.
    local cooldownProgress = 0

    if onCooldown then
        cooldownProgress = math.Clamp(
            1 - ((cooldownEnd - now) / cooldownDuration),
            0,
            1
        )
    end

    -- Default appearance.
    local targetScale = 1
    local targetColor = COLOR_BORDER
    local targetBackgroundAlpha = COLOR_ABILITY_BACKGROUND.a

    if active then
        -- Active: enlarge, turn yellow, hide background.
        targetScale = ABILITY_ACTIVE_SCALE
        targetColor = COLOR_FILL
        targetBackgroundAlpha = 0

    elseif onCooldown then
        -- Cooldown: shrink and turn darker yellow.
        -- The cooldown fill is the ONLY background layer.
        targetScale = ABILITY_COOLDOWN_SCALE
        targetColor = COLOR_ABILITY_COOLDOWN
        targetBackgroundAlpha = 0
    end

    -- Smooth the icon size, color, and normal background.
    local transition = math.Clamp(
        FrameTime() * ABILITY_TRANSITION_SPEED,
        0,
        1
    )

    state.scale = Lerp(
        transition,
        state.scale,
        targetScale
    )

    state.color = LerpColor(
        transition,
        state.color,
        targetColor
    )

    state.backgroundAlpha = Lerp(
        transition,
        state.backgroundAlpha,
        targetBackgroundAlpha
    )
	
	local targetGlyphAlpha = onCooldown and 0 or 255

	-- Tilt during use; return to the normal angle otherwise.
	local targetGlyphAngle = active
		and ABILITY_GLYPH_ACTIVE_ANGLE
		or 0

	local glyphTransition = math.Clamp(
		FrameTime() * ABILITY_GLYPH_TRANSITION_SPEED,
		0,
		1
	)

	state.glyphAlpha = Lerp(
		glyphTransition,
		state.glyphAlpha or 255,
		targetGlyphAlpha
	)

	state.glyphAngle = Lerp(
		glyphTransition,
		state.glyphAngle or 0,
		targetGlyphAngle
	)

    local size = ABILITY_ICON_SIZE * state.scale
    local x = centerX - size * 0.5
    local y = baseY + (ABILITY_ICON_SIZE - size) * 0.5

    -- Draw the normal background only when ready.
    -- Its opacity smoothly returns after cooldown ends.
    if not active
        and not onCooldown
        and state.backgroundAlpha > 1 then

        draw.RoundedBox(
            0,
            x,
            y,
            size,
            size,
            Color(
                COLOR_ABILITY_BACKGROUND.r,
                COLOR_ABILITY_BACKGROUND.g,
                COLOR_ABILITY_BACKGROUND.b,
                math.Clamp(state.backgroundAlpha, 0, 255)
            )
        )
    end

    -- Draw exactly ONE cooldown background.
    -- No interpolated leftover fill, so it cannot
    -- drain backward after the ability becomes ready.
    if onCooldown and cooldownProgress > 0 then
        local fillHeight = (size - 2) * cooldownProgress

        surface.SetDrawColor(
            COLOR_COOLDOWN_FILL.r,
            COLOR_COOLDOWN_FILL.g,
            COLOR_COOLDOWN_FILL.b,
            COLOR_COOLDOWN_FILL.a
        )

        surface.DrawRect(
            x + 1,
            y + size - 1 - fillHeight,
            size - 2,
            fillHeight
        )
    end

    -- Draw the image if the ability has one.
    -- No fallback icon letters or text.
    local material = GetAbilityMaterial(ability.icon)

    if material then
        surface.SetMaterial(material)
        surface.SetDrawColor(state.color)

        surface.DrawTexturedRect(
            x + 5,
            y + 5,
            size - 10,
            size - 10
        )
    end
	
	local glyphMaterial = GetAbilityMaterial(ability.glyph)

	if glyphMaterial and state.glyphAlpha > 1 then
		local glyphSize = size * ABILITY_GLYPH_SCALE

		surface.SetMaterial(glyphMaterial)

		-- Use the same animated color as the icon's border.
		surface.SetDrawColor(
			state.color.r,
			state.color.g,
			state.color.b,
			math.Clamp(state.glyphAlpha, 0, 255)
		)

		-- Rotate around the exact center of the icon.
		surface.DrawTexturedRectRotated(
			centerX,
			y + size * 0.5,
			glyphSize,
			glyphSize,
			state.glyphAngle
		)
	end

    -- Square outline.
    surface.SetDrawColor(state.color)

    surface.DrawOutlinedRect(
        x,
        y,
        size,
        size,
        1
    )

    -- Ability name above the icon.
    local nameFont = "HitmenAbilityNameText"

	local nameLines = WrapAbilityName(
		entry.name,
		ABILITY_NAME_MAX_WIDTH,
		nameFont
	)

	surface.SetFont(nameFont)

	local _, lineHeight = surface.GetTextSize("Ag")
	local lineSpacing = lineHeight + ABILITY_NAME_LINE_GAP

	local totalTextHeight =
		#nameLines * lineHeight
		+ (#nameLines - 1) * ABILITY_NAME_LINE_GAP

	local textTopY = y - 6 - totalTextHeight

	for index, line in ipairs(nameLines) do
		draw.SimpleTextOutlined(
			line,
			nameFont,
			centerX,
			textTopY + (index - 1) * lineSpacing,
			state.color,
			TEXT_ALIGN_CENTER,
			TEXT_ALIGN_TOP,
			1,
			Color(0, 0, 0, 220)
		)
	end

    draw.SimpleTextOutlined(
        entry.key,
        "HitmenAbilityKeyText",
        x + size - 7,
        y + 5,
        state.color,
        TEXT_ALIGN_RIGHT,
        TEXT_ALIGN_TOP,
        1,
        Color(0, 0, 0, 220)
    )
end

-- Draw all abilities in a horizontal row above the P-meter.
local function DrawAbilityRow(hitman)
    local entries = GetDisplayedAbilities(hitman)
    local count = #entries

    if count == 0 then
        return
    end

    local totalWidth =
        count * ABILITY_ICON_SIZE
        + (count - 1) * ABILITY_ICON_GAP

    local startX = (ScrW() - totalWidth) * 0.5

    local meterY = ScrH() - BAR_BOTTOM_OFFSET

    local iconY = meterY
        - ABILITY_ROW_GAP
        - ABILITY_ICON_SIZE

    for index, entry in ipairs(entries) do
        local centerX = startX
            + (index - 1)
                * (ABILITY_ICON_SIZE + ABILITY_ICON_GAP)
            + ABILITY_ICON_SIZE * 0.5

        DrawAbilityIcon(
            hitman,
            entry,
            centerX,
            iconY
        )
    end
end

-- Main HUD drawing.
hook.Add("HUDPaint", HUD_NAME, function()
    local hitman = FindPossessedHitman()

    if not IsValid(hitman) then
        targetMeter = 0

        displayedMeter = Lerp(
            math.Clamp(FrameTime() * LERP_SPEED, 0, 1),
            displayedMeter,
            targetMeter
        )

        StopFullMeterSound()

        abilityVisualStates = {}
        lastAbilityBotIndex = nil

        return
    end

    -- Reset animation states when possession changes.
    local botIndex = hitman:EntIndex()

    if lastAbilityBotIndex ~= botIndex then
        abilityVisualStates = {}
        lastAbilityBotIndex = botIndex
    end

    -- Read the networked P-meter values.
    local meterMax = math.max(
        hitman:GetNW2Float("HitmenPMeterMax", 100),
        1
    )

    targetMeter = math.Clamp(
        hitman:GetNW2Float("HitmenPMeter", 0),
        0,
        meterMax
    )

    -- Smooth the bar's fill.
    displayedMeter = Lerp(
        math.Clamp(FrameTime() * LERP_SPEED, 0, 1),
        displayedMeter,
        targetMeter
    )

    if math.abs(displayedMeter - targetMeter) < 0.05 then
        displayedMeter = targetMeter
    end

    -- Preserve the existing sound threshold.
    if displayedMeter >= (meterMax / 1.15) then
        StartFullMeterSound()
    else
        StopFullMeterSound()
    end

    -- Flicker the border/text while the sound is playing.
    local accentColor = COLOR_BORDER

    if fullMeterSound and fullMeterSound:IsPlaying() then
        if math.floor(CurTime() * FLICKER_RATE) % 2 == 1 then
            accentColor = COLOR_FLASH
        end
    end

    local fraction = math.Clamp(
        displayedMeter / meterMax,
        0,
        1
    )

    local x = (ScrW() - BAR_WIDTH) * 0.5
    local y = ScrH() - BAR_BOTTOM_OFFSET
    local centerX = x + BAR_WIDTH * 0.5
    local centerY = y + BAR_HEIGHT * 0.5

    local fillWidth = (BAR_WIDTH - 4) * fraction

    -- Square-cornered P-meter background.
    draw.RoundedBox(
        0,
        x,
        y,
        BAR_WIDTH,
        BAR_HEIGHT,
        COLOR_EMPTY
    )

    -- Fill from the center outward.
    if fillWidth > 0 then
        surface.SetDrawColor(COLOR_FILL)

        surface.DrawRect(
            centerX - fillWidth * 0.5,
            y + 2,
            fillWidth,
            BAR_HEIGHT - 4
        )
    end

    -- P-meter outline.
    surface.SetDrawColor(accentColor)

    surface.DrawOutlinedRect(
        x,
        y,
        BAR_WIDTH,
        BAR_HEIGHT,
        1
    )

    -- P-meter label.
    draw.SimpleTextOutlined(
        "POWER",
        "HitmenPMeterText",
        centerX,
        centerY,
        accentColor,
        TEXT_ALIGN_CENTER,
        TEXT_ALIGN_CENTER,
        1,
        Color(0, 0, 0, 220)
    )

    -- Draw the abilities above the P-meter.
    DrawAbilityRow(hitman)
end)

-- Stop the looping sound when the client shuts down.
hook.Add("ShutDown", HUD_NAME .. "_StopSound", function()
    StopFullMeterSound()
end)

local HEALTHBAR_HOOK = HUD_NAME .. "_NearbyHealthBars"

local healthbarStates = {}
local healthbarScanList = {}
local nextHealthbarScan = 0

-- Detect Lambda Players.
local function IsLambdaHealthbarTarget(ent)
    return ent.IsLambdaPlayer == true
        or ent:GetClass() == "npc_lambdaplayer"
end

-- Get current and maximum health.
-- Lambda Players use their replicated lambda_health value
-- when available, with the normal entity health as fallback.
local function GetHealthbarValues(ent)
    if not IsValid(ent) then
        return nil, nil
    end

    local health
    local maxHealth

    if IsLambdaHealthbarTarget(ent) then
        health = ent:GetNW2Float("lambda_health", -1)

        if health < 0 then
            health = ent:GetNWFloat("lambda_health", -1)
        end

        if isfunction(ent.GetNWMaxHealth) then
            local ok, result = pcall(ent.GetNWMaxHealth, ent)

            if ok and isnumber(result) then
                maxHealth = result
            end
        end
    end

    -- Fallback for ordinary players, NPCs, and nextbots.
    if not isnumber(health) or health < 0 then
        if not isfunction(ent.Health) then
            return nil, nil
        end

        health = ent:Health()
    end

    if not isnumber(maxHealth) or maxHealth <= 0 then
        if isfunction(ent.GetMaxHealth) then
            maxHealth = ent:GetMaxHealth()
        end
    end

    -- Some custom entities expose their spawn health instead.
    if (not isnumber(maxHealth) or maxHealth <= 0)
        and isnumber(ent.SpawnHealth)
        and ent.SpawnHealth > 0 then

        maxHealth = ent.SpawnHealth
    end

    if not isnumber(health)
        or not isnumber(maxHealth)
        or maxHealth <= 0 then

        return nil, nil
    end

    return math.max(health, 0), maxHealth
end

-- Check whether an entity is a reasonable healthbar target.
local function IsHealthbarTarget(ent, localPlayer)
    if not IsValid(ent) or ent == localPlayer then
        return false
    end

    if ent:IsWorld() then
        return false
    end

    local isLambda = IsLambdaHealthbarTarget(ent)

    if not isLambda
        and not ent:IsPlayer()
        and not ent:IsNPC()
        and not ent:IsNextBot() then

        return false
    end

    -- Do not create new bars for dead real players.
    if ent:IsPlayer() and not ent:Alive() then
        return false
    end

    local health, maxHealth = GetHealthbarValues(ent)

    return health ~= nil
        and maxHealth ~= nil
        and maxHealth > 0
end

local function CreateHealthbarState(ent)
    local health = GetHealthbarValues(ent)

    return {
        entity = ent,

        alpha = 0,

        lastHealth = health,

        fillColor = Color(
            COLOR_HEALTH_NORMAL.r,
            COLOR_HEALTH_NORMAL.g,
            COLOR_HEALTH_NORMAL.b,
            COLOR_HEALTH_NORMAL.a
        ),

        flashUntil = 0,

        shakeStart = 0,
        shakeAmplitude = 0,

        lastSeen = CurTime()
    }
end

-- Use the possessed Hitman as the proximity origin when possible.
-- This keeps the scan centered on the current gameplay camera's
-- controlled entity rather than the player's original position.
local function GetHealthbarReferencePosition(localPlayer)
    local possessedHitman = FindPossessedHitman()

    if IsValid(possessedHitman) then
        return possessedHitman:GetPos()
    end

    return localPlayer:GetPos()
end

local function UpdateHealthbarScan(localPlayer, referencePosition)
    local now = CurTime()

    if now < nextHealthbarScan then
        return
    end

    nextHealthbarScan = now + HEALTHBAR_SCAN_INTERVAL

    healthbarScanList = ents.FindInSphere(
        referencePosition,
        HEALTHBAR_SCAN_DISTANCE
    )

    for _, ent in ipairs(healthbarScanList) do
        if IsHealthbarTarget(ent, localPlayer) then
            if not healthbarStates[ent] then
                healthbarStates[ent] = CreateHealthbarState(ent)
            end

            healthbarStates[ent].lastSeen = now
        end
    end
end

local function DrawEntityHealthbar(ent, state, alpha)
    local health, maxHealth = GetHealthbarValues(ent)

    if health == nil or maxHealth == nil then
        return
    end

    -- Use damage to trigger a brief yellow flash and shake.
    local previousHealth = state.lastHealth

    if previousHealth ~= nil and health < previousHealth then
        local damageTaken = previousHealth - health

        state.flashUntil = CurTime() + HEALTHBAR_DAMAGE_FLASH_TIME

        state.fillColor = Color(
            COLOR_HEALTH_DAMAGE.r,
            COLOR_HEALTH_DAMAGE.g,
            COLOR_HEALTH_DAMAGE.b,
            COLOR_HEALTH_DAMAGE.a
        )

        state.shakeStart = CurTime()

        state.shakeAmplitude = math.Clamp(
            damageTaken * HEALTHBAR_SHAKE_STRENGTH,
            1.5,
            HEALTHBAR_SHAKE_MAX
        )
    end

    state.lastHealth = health

    -- Flash yellow briefly, then smoothly return to green.
    local targetFillColor = CurTime() < state.flashUntil
        and COLOR_HEALTH_DAMAGE
        or COLOR_HEALTH_NORMAL

    state.fillColor = LerpColor(
        math.Clamp(
            FrameTime() * HEALTHBAR_COLOR_RETURN_SPEED,
            0,
            1
        ),
        state.fillColor,
        targetFillColor
    )

    -- Smoothly damp the horizontal impact shake.
    local shakeOffset = 0
    local shakeAge = CurTime() - state.shakeStart

    if state.shakeAmplitude > 0 and shakeAge >= 0 then
        shakeOffset =
            math.cos(shakeAge * HEALTHBAR_SHAKE_FREQUENCY)
            * state.shakeAmplitude
            * math.exp(-shakeAge * HEALTHBAR_SHAKE_DECAY)

        if shakeAge > 1 then
            state.shakeAmplitude = 0
            shakeOffset = 0
        end
    end

    -- Project the entity's origin to screen coordinates.
    -- The bar and its name are placed below that point.
    local screen = ent:GetPos():ToScreen()

    if not screen.visible then
        return
    end

    local barCenterX = screen.x + shakeOffset
    local barY = screen.y + HEALTHBAR_OFFSET_Y

    local barX = barCenterX - HEALTHBAR_WIDTH * 0.5
    local fraction = math.Clamp(health / maxHealth, 0, 1)

    local fade = math.Clamp(alpha / 255, 0, 1)

    -- Background.
    draw.RoundedBox(
        0,
        barX,
        barY,
        HEALTHBAR_WIDTH,
        HEALTHBAR_HEIGHT,
        Color(
            COLOR_HEALTH_BACKGROUND.r,
            COLOR_HEALTH_BACKGROUND.g,
            COLOR_HEALTH_BACKGROUND.b,
            COLOR_HEALTH_BACKGROUND.a * fade
        )
    )

    -- Remaining-health fill.
    -- Like the P-meter, this fill expands from the center.
    local fillWidth = (HEALTHBAR_WIDTH - 2) * fraction

    if fillWidth > 0 then
        surface.SetDrawColor(
            state.fillColor.r,
            state.fillColor.g,
            state.fillColor.b,
            state.fillColor.a * fade
        )

        surface.DrawRect(
            barCenterX - fillWidth * 0.5,
            barY + 1,
            fillWidth,
            HEALTHBAR_HEIGHT - 2
        )
    end

    -- Square outline.
    surface.SetDrawColor(
        COLOR_BORDER.r,
        COLOR_BORDER.g,
        COLOR_BORDER.b,
        COLOR_BORDER.a * fade
    )

    surface.DrawOutlinedRect(
        barX,
        barY,
        HEALTHBAR_WIDTH,
        HEALTHBAR_HEIGHT,
        1
    )

    -- Only Lambda Players receive a name label.
    if IsLambdaHealthbarTarget(ent) then
        local lambdaName = nil

        if isfunction(ent.GetLambdaName) then
            local ok, result = pcall(ent.GetLambdaName, ent)

            if ok and isstring(result) then
                lambdaName = result
            end
        end

        if not lambdaName or lambdaName == "" then
            lambdaName = "Lambda Player"
        end

        draw.SimpleTextOutlined(
            lambdaName,
            "HitmenAbilityNameText",
            barCenterX,
            barY + HEALTHBAR_HEIGHT + HEALTHBAR_NAME_GAP,
            Color(
                COLOR_TEXT.r,
                COLOR_TEXT.g,
                COLOR_TEXT.b,
                COLOR_TEXT.a * fade
            ),
            TEXT_ALIGN_CENTER,
            TEXT_ALIGN_TOP,
            1,
            Color(0, 0, 0, 220 * fade)
        )
    end
end

hook.Add("HUDPaint", HEALTHBAR_HOOK, function()
    local localPlayer = LocalPlayer()

    if not IsValid(localPlayer) then
        return
    end

    local referencePosition =
        GetHealthbarReferencePosition(localPlayer)

    UpdateHealthbarScan(
        localPlayer,
        referencePosition
    )

    local now = CurTime()
    local frameTransition = math.Clamp(
        FrameTime() * HEALTHBAR_FADE_SPEED,
        0,
        1
    )

    for ent, state in pairs(healthbarStates) do
        if not IsValid(ent) then
            healthbarStates[ent] = nil
            continue
        end
		
		if ent:GetNW2Entity("HitmenPossessor") == localPlayer then
			healthbarStates[ent] = nil
			continue
		end

        local distanceSqr = referencePosition:DistToSqr(
            ent:GetPos()
        )

        local withinRange =
            distanceSqr <= HEALTHBAR_MAX_DISTANCE ^ 2

        local health, maxHealth = GetHealthbarValues(ent)

        local screen = ent:GetPos():ToScreen()

        local onScreen = screen.visible
            and screen.x > -HEALTHBAR_WIDTH
            and screen.x < ScrW() + HEALTHBAR_WIDTH
            and screen.y > -50
            and screen.y < ScrH()
                - HEALTHBAR_HEIGHT
                - HEALTHBAR_NAME_GAP
                - 10

        local aliveEnough = health ~= nil
            and maxHealth ~= nil
            and health > 0

        local isTarget = IsHealthbarTarget(
            ent,
            localPlayer
        )

        local targetAlpha = 0

        if withinRange and onScreen and aliveEnough and isTarget then
            targetAlpha = 255
        end

        -- Fade quickly in range and out when distant or off-screen.
        state.alpha = Lerp(
            frameTransition,
            state.alpha,
            targetAlpha
        )

        if state.alpha > 1 and onScreen then
            DrawEntityHealthbar(
                ent,
                state,
                state.alpha
            )
        end

        -- Remove old states after their bars have faded away.
        if state.alpha < 1
            and distanceSqr > HEALTHBAR_SCAN_DISTANCE ^ 2
            and now - state.lastSeen > 0.5 then

            healthbarStates[ent] = nil
        end
    end
end)

hook.Add(
    "HUDShouldDraw",
    HUD_NAME .. "_HideHealthWhilePossessing",
    function(name)
        if name ~= "CHudHealth" then
            return
        end

        if IsValid(FindPossessedHitman()) then
            return false
        end
    end
)