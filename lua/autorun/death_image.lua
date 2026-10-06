
if SERVER then
    AddCSLuaFile()

    util.AddNetworkString("LambdaHitmen_DeathImage")

    -- Distribute the correct image and sound files.
    resource.AddFile(
        "materials/lambda_hitmen/death_icons/regular.png"
    )

    resource.AddFile("sound/death_bang.wav")

    --------------------------------------------------
    -- SERVER: Detect Lambda player deaths
    --------------------------------------------------

    hook.Add(
        "LambdaOnKilled",
        "LambdaHitmen_DeathImage",
        function(lambda)
            if not IsValid(lambda) then return end

            -- Capture the death position only once.
            local deathPos = lambda:WorldSpaceCenter()

            -- Send the fixed position to every client.
            net.Start("LambdaHitmen_DeathImage")
                net.WriteVector(deathPos)
            net.Broadcast()
        end
    )
end


if CLIENT then
    --------------------------------------------------
    -- CLIENT: Configuration
    --------------------------------------------------

    -- Deliberately omit "smooth" to avoid requesting
    -- smooth texture filtering.
    local IMAGE_MATERIAL = Material(
        "lambda_hitmen/death_icons/regular.png"
    )

    local SOUND_PATH = "death_bang.wav"

    -- Dimensions in world units.
    local IMAGE_WIDTH = 34
    local IMAGE_HEIGHT = 34

    -- Effect timing.
    local HOLD_TIME = 3.0
    local FADE_TIME = 3.0

    -- Active death images.
    local activeEffects = {}

    --------------------------------------------------
    -- CLIENT: Receive death effect
    --------------------------------------------------

    net.Receive("LambdaHitmen_DeathImage", function()
        local deathPos = net.ReadVector()

        -- Store a fixed world position.
        -- Never attach the image to the ragdoll.
        activeEffects[#activeEffects + 1] = {
            pos = deathPos,
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
    -- CLIENT: Draw pixelated billboards
    --------------------------------------------------

    hook.Add(
        "PostDrawTranslucentRenderables",
        "LambdaHitmen_DrawDeathImage",
        function(_, drawingSkybox)
            if drawingSkybox then return end
            if #activeEffects == 0 then return end

            -- Force point sampling for crisp, pixelated
            -- textures when enlarged or reduced.
            render.PushFilterMin(TEXFILTER.POINT)
            render.PushFilterMag(TEXFILTER.POINT)

            render.SetMaterial(IMAGE_MATERIAL)

            -- Iterate backwards so effects can be removed
            -- without skipping any other active effects.
            for i = #activeEffects, 1, -1 do
                local effect = activeEffects[i]

                local elapsed = CurTime() - effect.startTime
                local totalTime = HOLD_TIME + FADE_TIME

                if elapsed >= totalTime then
                    -- Effect has finished.
                    table.remove(activeEffects, i)
                else
                    local alpha = 255

                    -- Keep the image opaque during its hold.
                    -- Afterwards, smoothly fade it away.
                    if elapsed > HOLD_TIME then
                        local fadeProgress =
                            (elapsed - HOLD_TIME) / FADE_TIME

                        fadeProgress = math.Clamp(
                            fadeProgress,
                            0,
                            1
                        )

                        alpha = 255 * (1 - fadeProgress)
                    end

                    --------------------------------------------------
                    -- BILLBOARD ORIENTATION
                    --------------------------------------------------

                    -- Face the current viewer's camera.
                    -- Recalculated every frame, but the image's
                    -- world position never changes.
                    local normal = EyePos() - effect.pos

                    if normal:LengthSqr() > 0 then
                        normal:Normalize()
                    else
                        normal = -EyeAngles():Forward()
                    end

                    -- Draw a camera-facing quad with point
                    -- filtering to preserve sharp pixel edges.
                    render.DrawQuadEasy(
                        effect.pos,
                        normal,
                        IMAGE_WIDTH,
                        IMAGE_HEIGHT,
                        Color(255, 255, 255, alpha),
                        0
                    )
                end
            end

            -- Restore the previous texture filters.
            render.PopFilterMag()
            render.PopFilterMin()
        end
    )
end