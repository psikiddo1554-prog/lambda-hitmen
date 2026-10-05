if not DrGBase then return end

ENT.Base = "drg_hitmen_base"

ENT.PrintName = "TEST"
ENT.Category = "Hitmen"
ENT.Spawnable = true

ENT.Abilities = {
    Test = {
        mouse = "LEFT",

        canActivate = function(self)
            return true
        end,

        func = function(self)
			print("Hi")
            return 8
        end
    }
}

AddCSLuaFile()
DrGBase.AddNextbot(ENT)