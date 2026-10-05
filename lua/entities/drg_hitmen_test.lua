if not DrGBase then return end

ENT.Base = "drg_hitmen_base"

ENT.PrintName = "TEST"
ENT.Category = "Hitmen"
ENT.Spawnable = true

ENT.Abilities = {
    Swing = {
        mouse = "LEFT",

        canActivate = function(self)
            return true
        end,

        func = function(self, finishAbility)
            local sequence = self:LookupSequence("swing")
			local length = self:SequenceDuration(sequence)
			
			self:AddGestureSequence(sequence, true)
			
			self:EmitSound("pursuerswing.mp3", 75, 100, 1, CHAN_AUTO)

			timer.Simple(0.2, function()
				if not self:IsValid() then return end

                self:CreateHitboxSequence({
					sequenceDuration = 0.25,
					
					followOwner = false,

					offset = Vector(5, 0, 40),
					mins = Vector(0, -30, -40),
					maxs = Vector(50, 30, 30),

					damage = 20,
					damageType = DMG_SLASH,
					force = 300,
					
					onHit = function(owner, target, hitbox, damageInfo)
						target:EmitSound("pursuerswinghit.mp3", 75, 100, 1, CHAN_AUTO)
						ParticleEffect("blood_impact_red_01", target:WorldSpaceCenter(), Angle(0, 0, 0))
					end
				})
			end)
			
			timer.Simple(0.4, function()
				if not self:IsValid() then return end
				finishAbility(0.9)
			end)
        end
    }
}

AddCSLuaFile()
DrGBase.AddNextbot(ENT)