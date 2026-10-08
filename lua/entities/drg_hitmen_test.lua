if not DrGBase then return end

ENT.Base = "drg_hitmen_base"
ENT.PrintName = "TEST"
ENT.Category = "Hitmen"
ENT.Spawnable = true

ENT.WalkSpeed = 165
ENT.RunSpeed = 335
ENT.PowerSpeed = 400

ENT.PMeterBuildRate = 95
ENT.PMeterDecayRate = 95
ENT.TurnResistance = 0.45

ENT.PowerRunAnimRate = 1.15

ENT.Abilities = {
	Swing = {
		mouse = "LEFT",
		showInHUD = false,
		canActivate = function(self) return true end,
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
					damage = 25,
					damageType = DMG_SLASH,
					force = 2200,
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
		name = "Meat Cleave",
		glyph = "lambda_hitmen/ability_icons/cleave.png",
		key = "1",
		canActivate = function(self) return true end,
		func = function(self, finishAbility)
			local WINDUP_DURATION = 0.6
			local BASE_CLEAVE_DURATION = 0.5
			local SWEET_SPOT_EXTENSION = 0.2
			local HITBOX_INTERVAL = 0.025
			local HITBOX_DURATION = 0.05

			self:AddGestureSequence(self:LookupSequence("Cleave"), true)
			self:SetPMeter(0)
			self:SetPMeterMechanicsEnabled(false)
			HitmenEffects.Apply(self, "speed", {duration = 0.6, multiplier = 0.35})
			self:EmitSound("pursuercleave.wav", 75, 100, 1, CHAN_AUTO)

			local carried = nil
			local alreadyHit = {}
			local cleaveActive = false
			local cleaveEndTime = 0
			local hitboxTimerName = nil

			local function StopCleaveHitboxes()
				cleaveActive = false
				if hitboxTimerName then
					timer.Remove(hitboxTimerName)
					hitboxTimerName = nil
				end
			end

			timer.Simple(WINDUP_DURATION, function()
				if not IsValid(self) then return end

				self:SetMovementEnabled(false)
				self:PropelForward(2000, 1200)
				cleaveActive = true
				cleaveEndTime = CurTime() + BASE_CLEAVE_DURATION
				hitboxTimerName = "HitmenCleaveHitboxes_" .. self:EntIndex() .. "_" .. math.floor(CurTime() * 1000)
				
				self:CreateHitboxSequence({
					sequenceDuration = 0.1,
					
					followOwner = false,

					offset = Vector(75, 0, 40),
					mins = Vector(0, -15, -40),
					maxs = Vector(50, 15, 30),

					damage = 15,
					damageType = DMG_SLASH,
					force = 3300,
					
					onHit = function(owner, target, hitbox, damageInfo)
						alreadyHit[target] = true
						carried = target
						target:EmitSound("pursuercleavehit.wav", 75, 100, 1, CHAN_AUTO)
						HitmenDrag.Drag(
							target,
							owner,
							Vector(40, 0, 0)
						)
						cleaveEndTime = cleaveEndTime + SWEET_SPOT_EXTENSION
					end
				})

				local function EmitCleaveHitboxes()
					if not IsValid(self) or not cleaveActive or CurTime() >= cleaveEndTime then
						StopCleaveHitboxes()
						return
					end

					self:CreateHitbox({
						duration = HITBOX_DURATION,
						followOwner = false,
						offset = Vector(5, 0, 40),
						mins = Vector(0, -30, -40),
						maxs = Vector(50, 30, 30),
						damage = 20,
						damageType = DMG_SLASH,
						force = 3300,
						ignore = carried,
						shouldHit = function(owner, target, hitbox)
							return not alreadyHit[target]
						end,
						onHit = function(owner, target, hitbox, damageInfo)
							alreadyHit[target] = true
							target:EmitSound("pursuercleavehit.wav", 75, 100, 1, CHAN_AUTO)
							ParticleEffect("blood_impact_backscatter", target:WorldSpaceCenter(), Angle(0, 0, 0))
							LambdaHitmen.ApplyKnockback(owner, target, 1300, 100, nil)
							HitmenEffects.Apply(target, "bleeding", {duration = 6})
						end
					})
				end

				EmitCleaveHitboxes()

				if cleaveActive then
					timer.Create(hitboxTimerName, HITBOX_INTERVAL, 0, EmitCleaveHitboxes)
				end
			end)

			local function CheckForCleaveEnd()
				if not IsValid(self) or not cleaveActive then return end

				if CurTime() < cleaveEndTime then
					timer.Simple(0.01, CheckForCleaveEnd)
					return
				end

				StopCleaveHitboxes()
				self:EmitSound("pursuerunsheath.mp3", 75, 100, 1, CHAN_AUTO)
				self:SetMovementEnabled(true)

				if IsValid(carried) and carried:Health() > 0 then
					carried:EmitSound("pursuerswinghit.mp3", 75, 100, 1, CHAN_AUTO)
					HitmenDrag.Undrag(carried)
					
					for i = 1, 2 do
						ParticleEffect("blood_impact_backscatter", carried:WorldSpaceCenter(), Angle(0, 0, 0))
					end
					
					LambdaHitmen.ApplyKnockback(self, carried, 950, 0, nil, 1.0, 1.5)
					
					local dmg = DamageInfo()

					dmg:SetDamage(10)
					dmg:SetAttacker(self)
					dmg:SetInflictor(self)
					dmg:SetDamageType(DMG_SLASH)
					carried:TakeDamageInfo(dmg)

					HitmenEffects.Apply(carried, "bleeding", {duration = 4, multiplier = 1.5})
					HitmenEffects.Apply(self, "speed", {
						duration = 1.5,
						multiplier = 0.45
					})
				end
				
				self:AddGestureSequence(self:LookupSequence("CleaveEnd"), true)
				
				self:StopPropellingForward(true)

				timer.Simple(1.4, function()
					if not IsValid(self) then return end
					self:SetPMeterMechanicsEnabled(true)
					finishAbility(2)
				end)
			end

			timer.Simple(WINDUP_DURATION, CheckForCleaveEnd)
		end
	},
	
	Howl = {
		name = "Apex's Howl",
		glyph = "lambda_hitmen/ability_icons/cleave.png",
		key = "2",
		canActivate = function(self) return true end,
		func = function(self, finishAbility)
			self:AddGestureSequence(self:LookupSequence("Howl"), true)
			
			self:EmitSound("pursuerhowl.wav", 120, 100, 1, CHAN_AUTO)

			self:SetPMeterMechanicsEnabled(false)
			
			HitmenEffects.Apply(self, "speed", {
				duration = 2.1,
				multiplier = 0.3
			})
			
			timer.Simple(2.1, function()
				if not IsValid(self) then return end
				self:SetPMeterMechanicsEnabled(true)
				
				finishAbility(13)
			end)
		end
	}
}

AddCSLuaFile()
DrGBase.AddNextbot(ENT)