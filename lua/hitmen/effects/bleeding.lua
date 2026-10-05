HitmenEffects.Register("bleeding", {
    duration = 5,
    multiplier = 1,
	
    thinkInterval = 1,
    damagePerTick = 2,
	
    OnThink = function(target, effect)
        if not IsValid(target) or not isfunction(target.TakeDamageInfo) then return end
        if isfunction(target.Health) and target:Health() <= 0 then return end

        local damage = math.max(tonumber(effect.definition.damagePerTick) or 1, 0)
            * math.max(tonumber(effect.multiplier) or 1, 0)
        if damage <= 0 then return end

        local source = IsValid(effect.source) and effect.source or game.GetWorld()
        local info = DamageInfo()
		
        info:SetDamage(damage)
        info:SetDamageType(DMG_SLASH)
        info:SetAttacker(source)
        info:SetInflictor(source)
        target:TakeDamageInfo(info)
		
		ParticleEffect("blood_impact_red_01", target:WorldSpaceCenter(), Angle(0, 0, 0))
		target:EmitSound("dieofdeath/general/bleedpertick.wav", 75, 100, 1, CHAN_AUTO)
    end
})