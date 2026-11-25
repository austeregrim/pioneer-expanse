-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

-- Legacy NewsEventCommodity BBS module retired in favor of InterCast + MacroGalaxyEngine.
-- Serializer stub preserved for backward savefile compatibility.

local Serializer = require 'Serializer'

Serializer:Register("NewsEventCommodity",
	function ()
		return { ads = {}, news = {} }
	end,
	function (_data)
	end
)
