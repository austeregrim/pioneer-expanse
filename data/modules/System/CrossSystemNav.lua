-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Game       = require 'Game'
local Space      = require 'Space'
local Event      = require 'Event'
local Comms      = require 'Comms'
local Serializer = require 'Serializer'

local CrossSystemNav = {}

-- Persistent cross-system target state:
-- { path = SystemPath, bodyName = string, systemName = string }
local pendingTarget = nil

local function resolveBodyInCurrentSystem(path)
	if not Game.system or not path then return nil end
	local okSame, isSame = pcall(function() return path:IsSameSystem(Game.system.path) end)
	if not okSame or not isSame then return nil end

	local okSb, sBody = pcall(function() return path:GetSystemBody() end)
	if okSb and sBody and sBody.physicsBody and sBody.physicsBody:exists() then
		return sBody.physicsBody
	end

	for _, b in ipairs(Space.GetBodies()) do
		if b and b:exists() and b.path == path then
			return b
		end
	end

	return nil
end

function CrossSystemNav.GetPendingTarget()
	return pendingTarget
end

function CrossSystemNav.IsPendingTarget(sBodyOrPath)
	if not pendingTarget or not pendingTarget.path or not sBodyOrPath then
		return false
	end
	local okPath, targetPath = pcall(function()
		if type(sBodyOrPath) == "userdata" or type(sBodyOrPath) == "table" then
			return sBodyOrPath.path or sBodyOrPath
		end
		return nil
	end)
	if not okPath or not targetPath then return false end
	local okEq, eq = pcall(function() return pendingTarget.path == targetPath end)
	return okEq and eq == true
end

function CrossSystemNav.ClearPendingTarget()
	pendingTarget = nil
end

function CrossSystemNav.SetPendingTarget(sBody)
	if not sBody or not sBody.path then
		return false, "Invalid target body."
	end
	if sBody.type == "GRAVPOINT" then
		return false, "Barycenter cannot be targeted."
	end

	if Game.system then
		local okSame, isSame = pcall(function() return sBody.path:IsSameSystem(Game.system.path) end)
		if okSame and isSame then
			local phys = resolveBodyInCurrentSystem(sBody.path)
			if phys then
				Game.player:SetNavTarget(phys)
				pendingTarget = nil
				return true, "LOCKED"
			end
			return false, "Body not instantiated in current system."
		end
	end

	local sysName = nil
	if sBody.system and sBody.system.name then
		sysName = sBody.system.name
	else
		local okSys, sys = pcall(function() return sBody.path:GetStarSystem() end)
		if okSys and sys and sys.name then
			sysName = sys.name
		end
	end
	sysName = sysName or "Target System"

	pendingTarget = {
		path = sBody.path,
		bodyName = sBody.name or "Destination",
		systemName = sysName,
	}

	local sysPath = sBody.path:SystemOnly()
	if Game.sectorView and Game.sectorView.SetSelectedPath then
		pcall(function() Game.sectorView:SetSelectedPath(sysPath) end)
	end

	local queuedJump = false
	local okPlanner, hyperJumpPlanner = pcall(require, 'pigui.modules.hyperjump-planner')
	if okPlanner and hyperJumpPlanner and Game.sectorView then
		local route = hyperJumpPlanner.getJumpRouteList and hyperJumpPlanner.getJumpRouteList() or {}
		if #route == 0 and Game.system and Game.player then
			local okChk, status = pcall(function()
				return Game.player:GetHyperspaceDetails(Game.system.path, sysPath)
			end)
			if okChk and status == 'OK' then
				pcall(function() hyperJumpPlanner.addJump(sysPath) end)
				queuedJump = true
			end
		end
	end

	if queuedJump then
		Comms.Message(string.format("Queued cross-system target: %s (%s). Hyperjump target set.",
			pendingTarget.bodyName, sysName))
	else
		Comms.Message(string.format("Queued cross-system target: %s (%s). Plot jump route in Sector Map.",
			pendingTarget.bodyName, sysName))
	end

	return true, "QUEUED"
end

local function onEnterSystem(ship)
	if ship ~= Game.player or not pendingTarget or not pendingTarget.path or not Game.system then
		return
	end
	local okSame, isSame = pcall(function() return pendingTarget.path:IsSameSystem(Game.system.path) end)
	if not okSame or not isSame then
		return
	end

	local phys = resolveBodyInCurrentSystem(pendingTarget.path)
	if phys and Game.player then
		Game.player:SetNavTarget(phys)
		Comms.ImportantMessage(string.format("Nav computer auto-locked queued destination: %s",
			pendingTarget.bodyName or phys.label or "Destination"))
	end
	pendingTarget = nil
end

local function onGameEnd()
	pendingTarget = nil
end

local function serialize()
	return {
		pendingTarget = pendingTarget,
	}
end

local function unserialize(data)
	pendingTarget = data and data.pendingTarget or nil
end

Event.Register("onEnterSystem", onEnterSystem)
Event.Register("onGameEnd", onGameEnd)
Serializer:Register("CrossSystemNav", serialize, unserialize)

return CrossSystemNav
