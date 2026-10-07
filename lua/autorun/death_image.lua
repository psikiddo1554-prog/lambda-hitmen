if SERVER then
    AddCSLuaFile()

    util.AddNetworkString("LambdaHitmen_DeathImage")

    --------------------------------------------------
    -- SERVER: CONFIGURATION
    --------------------------------------------------

    -- The normal image used most of the time.
    -- This path is relative to the materials/ folder.
    local REGULAR_ICON = "lambda_hitmen/death_icons/regular.png"

    -- Put alternate PNGs in:
    -- materials/lambda_hitmen/death_icons/variants/
    local VARIANT_FOLDER = "materials/lambda_hitmen/death_icons/variants/"
    local VARIANT_SEARCH = VARIANT_FOLDER .. "*.png"

    -- Chance that a death uses a random variant instead of regular.png.
    -- 0.10 = 10%, 0.25 = 25%, 1 = 100%, 0 = never.
    local RANDOM_ICON_CHANCE = 0.85

    -- Distribute the regular icon to clients.
    resource.AddFile("materials/" .. REGULAR_ICON)

    -- Find and distribute all alternate PNGs, then keep their material paths.
    local variantFiles = file.Find(VARIANT_SEARCH, "GAME") or {}
    local variantIcons = {}

    for _, filename in ipairs(variantFiles) do
        if string.EndsWith(string.lower(filename), ".png") then
            local iconPath = "lambda_hitmen/death_icons/variants/" .. filename

            variantIcons[#variantIcons + 1] = iconPath
            resource.AddFile("materials/" .. iconPath)
        end
    end

    -- Helpful server startup information.
    print("[LambdaHitmen DeathImage] Found " .. #variantIcons .. " alternate death icon(s).")

    --------------------------------------------------
    -- SERVER: DETECT LAMBDA PLAYER DEATHS
    --------------------------------------------------

    hook.Add(
        "LambdaOnKilled",
        "LambdaHitmen_DeathImage",
        function(lambda)
            if not IsValid(lambda) then return end

            -- Capture the death position only once.
            local deathPos = lambda:WorldSpaceCenter()

            -- Pick the image on the server so everyone sees the same one
            -- for this death event.
            local chosenIcon = REGULAR_ICON

            if #variantIcons > 0
                and math.Rand(0, 1) < RANDOM_ICON_CHANCE then
                chosenIcon = variantIcons[math.random(#variantIcons)]
            end

            net.Start("LambdaHitmen_DeathImage")
                net.WriteVector(deathPos)
                net.WriteString(chosenIcon)
            net.Broadcast()
        end
    )
end


if CLIENT then
    --------------------------------------------------
    -- CLIENT: CONFIGURATION
    --------------------------------------------------

    -- Must match the regular icon path above.
    local REGULAR_ICON = "lambda_hitmen/death_icons/regular.png"
    local SOUND_PATH = "death_bang.wav"

    -- Dimensions in world units.
    local IMAGE_WIDTH = 34
    local IMAGE_HEIGHT = 34

    -- Effect timing.
    local HOLD_TIME = 3.0
    local FADE_TIME = 3.0

    -- Cache materials by path, since each death can use a different image.
    local imageMaterials = {}

    local function GetImageMaterial(path)
        if not isstring(path) or path == "" then
            path = REGULAR_ICON
        end

        if not imageMaterials[path] then
            -- Deliberately omit "smooth" for crisp, pixelated textures.
            imageMaterials[path] = Material(path)
        end

        local mat = imageMaterials[path]

        -- Fall back to the regular image if a variant is missing or invalid.
        if not mat or mat:IsError() then
            if path ~= REGULAR_ICON then
                return GetImageMaterial(REGULAR_ICON)
            end

            return mat
        end

        return mat
    end

    -- Active death images.
    local activeEffects = {}

    --------------------------------------------------
    -- CLIENT: RECEIVE DEATH EFFECT
    --------------------------------------------------

    net.Receive("LambdaHitmen_DeathImage", function()
        local deathPos = net.ReadVector()
        local iconPath = net.ReadString()
        local iconMaterial = GetImageMaterial(iconPath)

        -- Store a fixed world position and the image selected for this death.
        -- Never attach the image to the ragdoll.
        activeEffects[#activeEffects + 1] = {
            pos = deathPos,
            material = iconMaterial,
            startTime = CurTime()
        }

        -- Play the sound once when the image appears.
        sound.Play(
            SOUND_PATH,
            deathPos,
            75,  -- Sound level
            100, -- Pitch
            1    -- Volume
        )
    end)

    --------------------------------------------------
    -- CLIENT: DRAW PIXELATED BILLBOARDS
    --------------------------------------------------

    hook.Add(
        "PostDrawTranslucentRenderables",
        "LambdaHitmen_DrawDeathImage",
        function(_, drawingSkybox)
            if drawingSkybox then return end
            if #activeEffects == 0 then return end

            -- Force point sampling for crisp, pixelated textures when enlarged
            -- or reduced.
            render.PushFilterMin(TEXFILTER.POINT)
            render.PushFilterMag(TEXFILTER.POINT)

            -- Iterate backwards so effects can be removed without skipping
            -- any other active effects.
            for i = #activeEffects, 1, -1 do
                local effect = activeEffects[i]

                local elapsed = CurTime() - effect.startTime
                local totalTime = HOLD_TIME + FADE_TIME

                if elapsed >= totalTime then
                    table.remove(activeEffects, i)
                else
                    local alpha = 255

                    -- Keep the image opaque during its hold, then fade it.
                    if elapsed > HOLD_TIME then
                        local fadeProgress =
                            (elapsed - HOLD_TIME) / FADE_TIME

                        fadeProgress = math.Clamp(fadeProgress, 0, 1)
                        alpha = 255 * (1 - fadeProgress)
                    end

                    -- Face the current viewer's camera. The image's world
                    -- position itself never changes.
                    local normal = EyePos() - effect.pos

                    if normal:LengthSqr() > 0 then
                        normal:Normalize()
                    else
                        normal = -EyeAngles():Forward()
                    end

                    -- Each active effect uses the material selected for it.
                    if effect.material and not effect.material:IsError() then
                        render.SetMaterial(effect.material)

                        render.DrawQuadEasy(
                            effect.pos,
                            normal,
                            IMAGE_WIDTH,
                            IMAGE_HEIGHT,
                            Color(255, 255, 255, alpha),
                            180 -- Rotate the billboard 180 degrees to correct upside-down texture orientation.
                        )
                    end
                end
            end

            -- Restore the previous texture filters.
            render.PopFilterMag()
            render.PopFilterMin()
        end
    )
end