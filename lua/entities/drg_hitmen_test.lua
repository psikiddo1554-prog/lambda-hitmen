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
    },
	
	Cleave = {
        key = "1",

        canActivate = function(self)
            return true
        end,

        func = function(self, finishAbility)
			local sequence = self:LookupSequence("Cleave")
			
			self:AddGestureSequence(sequence, true)
			self:SetPMeter(0)
			
			HitmenEffects.Apply(self, "speed", {
				duration = 1.4,
				multiplier = 2.35
			})
			
			self:SetPMeterMechanicsEnabled(false)
			
			self:EmitSound("pursuercleave.wav", 75, 100, 1, CHAN_AUTO)

			timer.Simple(0.6, function()
				if not self:IsValid() then return end

                self:CreateHitboxSequence({
					sequenceDuration = 0.3,
					
					followOwner = false,

					offset = Vector(5, 0, 40),
					mins = Vector(0, -30, -40),
					maxs = Vector(50, 30, 30),

					damage = 20,
					damageType = DMG_SLASH,
					force = 300,
					
					onHit = function(owner, target, hitbox, damageInfo)
						target:EmitSound("pursuercleavehit.wav", 75, 100, 1, CHAN_AUTO)
						ParticleEffect("blood_impact_backscatter", target:WorldSpaceCenter(), Angle(0, 0, 0))
						
						HitmenEffects.Apply(target, "bleeding", {
							duration = 6,
							multiplier = 1
						})
					end
				})
			end)
			
			timer.Simple(1.4, function()
				if not self:IsValid() then return end
				self:EmitSound("pursuerunsheath.mp3", 75, 100, 1, CHAN_AUTO)
				
				HitmenEffects.Apply(self, "speed", {
					duration = 1.5,
					multiplier = 0.35
				})
				
				self:AddGestureSequence(self:LookupSequence("CleaveEnd"), true)
			end)
			
			timer.Simple(2.9, function()
				if not self:IsValid() then return end
				
				self:SetPMeterMechanicsEnabled(true)
				finishAbility(22)
			end)
		end
    },
	
	Howl = {
        key = "2",

        canActivate = function(self)
            return true
        end,

        func = function(self, finishAbility)
			self:SetMovementEnabled(false)
			self:SetPMeter(0)
			self:SetPMeterMechanicsEnabled(false)
			
			self:EmitSound("pursuerhowl.wav", 75, 100, 1, CHAN_AUTO)
			
			local speedBoost = 1
			local rewardedTargets = setmetatable({}, { __mode = "k" })

			local function AddHowlSpeedBoost(target, amount)
				if not IsValid(target) or rewardedTargets[target] then
					return
				end

				rewardedTargets[target] = true
				speedBoost = speedBoost + amount
			end
			
			timer.Simple(0.3, function()
				if not self:IsValid() then return end
				
				self:CreateHitboxSequence({
					sequenceDuration = 0.65,
					
					followOwner = true,

					offset = Vector(0, 0, 30),
					mins = Vector(-80, -80, -30),
					maxs = Vector(80, 80, 30),

					damage = 0,
					force = 300,
					
					onHit = function(owner, target, hitbox, damageInfo)
						AddHowlSpeedBoost(target, 0.4)
					end
				})
				
				self:CreateHitboxSequence({
					sequenceDuration = 1.4,
					
					followOwner = true,

					offset = Vector(0, 0, 30),
					mins = Vector(-170, -170, -30),
					maxs = Vector(170, 170, 30),

					damage = 0,
					force = 0,
					
					onHit = function(owner, target, hitbox, damageInfo)
						HitmenEffects.Apply(target, "speed", {
							duration = 3,
							multiplier = 0.7,
							stackable = false,
							refreshable = false
						})
						AddHowlSpeedBoost(target, 0.35)
					end
				})
				
				self:CreateHitboxSequence({
					sequenceDuration = 1.4,
					
					followOwner = true,

					offset = Vector(0, 0, 30),
					mins = Vector(-410, -410, -30),
					maxs = Vector(410, 410, 30),

					damage = 0,
					force = 0,
					
					onHit = function(owner, target, hitbox, damageInfo)
						HitmenEffects.Apply(target, "speed", {
							duration = 5,
							multiplier = 0.5,
							stackable = false,
							refreshable = false
						})
						AddHowlSpeedBoost(target, 0.2)
					end
				})
			end)
			
			self:CallInCoroutine(function(self, delay)
				self:PlaySequenceAndMove("Howl")
				
				self:SetMovementEnabled(true)
				self:SetPMeterMechanicsEnabled(true)
				
				HitmenEffects.Apply(self, "speed", {
					duration = 4,
					multiplier = speedBoost
				})
				finishAbility(20)
			end)
		end
    }
}

AddCSLuaFile()
DrGBase.AddNextbot(ENT)