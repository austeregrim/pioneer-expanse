-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Player = package.core["Player"]
local Engine = require 'Engine'
local Commodities = require 'Commodities'

function Player:SpawnMiningContainer(body)
	-- this function is called from C++ when a mining laser shot hits the surface of an asteroid body and chips off a peice
	-- body is a valid SystemBody object
	-- return value needs to be a valid CommodityType object

	local r = Engine.rand:Number()
	local m = body.metallicity

	if (r*20 < m) then
		return Commodities.precious_metals
	elseif (r*8 < m) then
		return Commodities.metal_alloys
	elseif r < m then
		return Commodities.metal_ore
	elseif r < 0.5 then
		return Commodities.carbon_ore
	end
	return Commodities.rubbish
end

function Player:SpawnRingMiningContainer(body, composition, reserveGrade)
	local gradeBias = {
		Depleted = 0.25,
		Low = 0.55,
		Common = 1.0,
		Major = 1.6,
		Pristine = 2.4,
	}
	local mult = gradeBias[reserveGrade] or 1.0
	local r = Engine.rand:Number(0, 1)

	if composition == "Icy (Water)" then
		if r < 0.08 * mult then
			return Commodities.liquid_oxygen
		elseif r < 0.25 * mult then
			return Commodities.hydrogen
		elseif r < 0.72 then
			return Commodities.water
		end
		return Commodities.carbon_ore
	elseif composition == "Icy (Ammonia/Methane)" then
		if r < 0.14 * mult then
			return Commodities.chemicals
		elseif r < 0.28 * mult then
			return Commodities.fertilizer
		elseif r < 0.52 then
			return Commodities.plastics
		elseif r < 0.78 then
			return Commodities.water
		end
		return Commodities.liquid_oxygen
	elseif composition == "Rocky" then
		if r < 0.06 * mult then
			return Commodities.precious_metals
		elseif r < 0.22 * mult then
			return Commodities.metal_alloys
		elseif r < 0.58 then
			return Commodities.metal_ore
		end
		return Commodities.carbon_ore
	elseif composition == "Metal-Rich" then
		if r < 0.12 * mult then
			return Commodities.precious_metals
		elseif r < 0.34 * mult then
			return Commodities.metal_alloys
		elseif r < 0.76 then
			return Commodities.metal_ore
		end
		return Commodities.carbon_ore
	elseif composition == "Metallic" then
		if r < 0.28 * mult then
			return Commodities.precious_metals
		elseif r < 0.56 * mult then
			return Commodities.metal_alloys
		end
		return Commodities.metal_ore
	end

	return self:SpawnMiningContainer(body)
end
