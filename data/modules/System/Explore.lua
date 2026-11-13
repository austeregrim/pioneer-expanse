-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Game = require 'Game'
local Space = require 'Space'
local Event = require 'Event'
local Comms = require 'Comms'
local Timer = require 'Timer'
local Lang = require 'Lang'
local utils = require 'utils'

local l = Lang.GetResource("module-system")

local exploreSystem = function (system)
	Comms.Message(l.GETTING_SENSOR_DATA)
	local starports = #Space.GetBodies("SpaceStation")
	local major_bodies = #Space.GetBodies("TerrainBody")
	local bodies
	if major_bodies == 1 then
		bodies = l.BODY
	else
		bodies = l.BODIES
	end
	Timer:CallAt(Game.time+major_bodies, function ()
		system:Explore()
		Comms.Message(l.EXPLORED_SYSTEM:interp({bodycount=major_bodies, bodies=bodies}))
	end)
	if starports > 0 then
		local bases
		if starports == 1 then
			bases = l.BASE
		else
			bases = l.BASES
		end
		Timer:CallAt(Game.time+major_bodies+starports, function ()
				Comms.ImportantMessage(l.DISCOVERED_HIDDEN_BASES:interp({portcount=starports, bases=bases}))
			end)
	end
end

local onEnterSystem = function (player)
	-- Exploration is now triggered manually via the System Discovery Scanner
end

local onGameStart = function ()
	-- Exploration is now triggered manually via the System Discovery Scanner
end

Event.Register("onEnterSystem", onEnterSystem)
Event.Register("onGameStart", onGameStart)
