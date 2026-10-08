if not DrGBase then return end

ENT.Base = "drgbase_nextbot"

ENT.Models = {
    "models/Pursuer.mdl"
}

ENT.SpawnHealth = 100

ENT.MeleeAttackRange = 0
ENT.RangeAttackRange = 0
ENT.Factions = {}

ENT.IdleAnimation = "idle"
ENT.IdleAnimRate = 1

ENT.WalkAnimation = "walk"
ENT.WalkAnimRate = 1

ENT.RunAnimation = "run"
ENT.RunAnimRate = 0.85

function ENT:OnUpdateAnimation()
    if self:IsDown() or self:IsDead() then return end

    if self:IsClimbingUp() then
        return self.ClimbUpAnimation, self.ClimbAnimRate
    elseif self:IsClimbingDown() then
        return self.ClimbDownAnimation, self.ClimbAnimRate
    elseif not self:IsOnGround() then
        return self.JumpAnimation, self.JumpAnimRate
    end

    if self:IsMoving() then
        if self:IsSlowWalking() then
            return self.WalkAnimation, self.WalkAnimRate
        end

        return self.RunAnimation, self.RunAnimRate
    end

    return self.IdleAnimation, self.IdleAnimRate
end

ENT.BehaviourType = AI_BEHAV_CUSTOM

if SERVER then
    AddCSLuaFile("possession.lua")
    AddCSLuaFile("movement.lua")
	AddCSLuaFile("abilities.lua")
	AddCSLuaFile("hitbox.lua")
	AddCSLuaFile("hud.lua")
	AddCSLuaFile("drag.lua")
end

include("movement.lua")
include("possession.lua")
include("abilities.lua")
include("hitbox.lua")
include("hud.lua")
include("drag.lua")

if SERVER then
    function ENT:CustomInitialize()
        self:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
    end

    function ENT:OnIdle()
    end
end

AddCSLuaFile()
DrGBase.AddNextbot(ENT)