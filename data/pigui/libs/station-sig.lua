-- Copyright © 2008-2026 Pioneer Developers. See AUTHORS.txt for details
-- Licensed under the terms of the GPL v3. See licenses/GPL-3.txt

local Game = require 'Game'
local Lang = require 'Lang'

local ui = require 'pigui'
local pionillium = ui.fonts.pionillium
local colors = ui.theme.colors
local styleColors = ui.theme.styleColors
local icons = ui.theme.icons

local l = Lang.GetResource("ui-core")

local VERIFICATION_DURATION = 0.45

local StationSig = {}
StationSig.__index = StationSig

local function computeKeyFingerprint(label)
	local h1 = 0x5A17
	local h2 = 0xC391
	for i = 1, #label do
		local b = string.byte(label, i)
		h1 = (h1 * 33 + b) % 0x10000
		h2 = (h2 * 131 + b + i) % 0x10000
	end
	return string.format("%04X-%04X", h1, h2)
end

function StationSig.New(id, mode)
	local self = {
		id = id,
		mode = mode or "signature", -- "signature" or "encryption"
		startTime = ui.getTime(),
		keyFingerprint = "0000-0000",
	}
	self = setmetatable(self, StationSig)
	self:reset(mode)
	return self
end

function StationSig:reset(mode)
	if mode then self.mode = mode end
	self.startTime = ui.getTime()
	local isShipTerminal = (self.id:find("^InfoView") ~= nil)
	local seedStr
	if self.mode == "encryption" then
		local p = Game.player
		local ship = p and p.shipName or "VESSEL"
		local sys = Game.system and Game.system.name or "SECTOR"
		local station = p and p:GetDockedWith()
		seedStr = (station and station.label or "SYS") .. ":" .. ship .. ":" .. sys .. ":" .. tostring(self.id)
	elseif isShipTerminal then
		local p = Game.player
		local ship = p and p.shipName or "SHIP"
		seedStr = "SHIP_INTERNAL:" .. ship .. ":" .. tostring(self.id)
	else
		local station = Game.player and Game.player:GetDockedWith()
		seedStr = (station and station.label or "STATION") .. ":" .. tostring(self.id)
	end
	self.keyFingerprint = computeKeyFingerprint(seedStr)
end

function StationSig:render(drawContentFn)
	local now = ui.getTime()
	local frac = math.clamp((now - self.startTime) / VERIFICATION_DURATION, 0, 1)
	local verified = (frac >= 1)

	local isShipTerminal = (self.id:find("^InfoView") ~= nil)
	local isEnc = (self.mode == "encryption")
	local statusLabel, rightText, statusColor

	if isEnc then
		statusLabel = verified and (l.COMM_ENCRYPTED_SECURE or "SECURE ENCRYPTED CHANNEL ESTABLISHED")
			or (l.COMM_ENCRYPTING or "ESTABLISHING QUANTUM-ENCRYPTED LINK...")
		statusColor = verified and (colors.uiPrimaryLight or styleColors.success_300) or (colors.maneuver or colors.font)
		rightText = "CIPHER " .. self.keyFingerprint .. "  ·  4096-bit AES-GCM / Post-Quantum Kyber-1024"
	elseif isShipTerminal then
		statusLabel = verified and "SHIP SYSTEM PUBKEY VERIFIED"
			or "VERIFYING SHIP SYSTEM PUBKEY SIGNATURE..."
		statusColor = verified and (styleColors.success_300 or colors.econMajorImport) or (colors.maneuver or colors.font)
		rightText = "KEY " .. self.keyFingerprint .. "  ·  Post-quantum ECDSA-521 // LOCAL NODE"
	else
		statusLabel = verified and (l.SIG_VERIFIED or "STATION PUBKEY VERIFIED")
			or (l.SIG_VERIFYING or "VERIFYING STATION PUBKEY SIGNATURE...")
		statusColor = verified and (styleColors.success_300 or colors.econMajorImport) or (colors.maneuver or colors.font)
		rightText = "KEY " .. self.keyFingerprint .. "  ·  " .. (l.SIG_PROTOCOL or "Post-quantum ECDSA-521")
	end

	ui.dummy(Vector2(0, 1))

	local padX = ui.rescaleUI(Vector2(4, 0), Vector2(1920, 1080)).x
	ui.dummy(Vector2(padX, 0))
	ui.sameLine()

	ui.withFont(pionillium.details, function()
		local lineH = ui.getTextLineHeight()
		ui.icon(icons.shield_other, Vector2(lineH), statusColor)
		ui.sameLine()
		ui.textColored(statusColor, statusLabel)
		ui.sameLine()

		local avail = ui.getContentRegion().x - padX
		local rightW = ui.calcTextSize(rightText).x
		if avail > rightW then
			ui.addCursorPos(Vector2(avail - rightW, 0))
		end
		ui.textColored(colors.fontDim, rightText)
	end)

	local barStart = ui.getCursorScreenPos() + Vector2(padX, 0)
	local barWidth = ui.getContentRegion().x - padX * 2
	local barHeight = math.max(2, ui.rescaleUI(Vector2(0, 2), Vector2(1920, 1080)).y)
	ui.addRectFilled(barStart, barStart + Vector2(barWidth, barHeight), colors.tableBackground, 0, ui.RoundCornersNone)
	if barWidth > 0 then
		ui.addRectFilled(barStart, barStart + Vector2(barWidth * frac, barHeight), statusColor, 0, ui.RoundCornersNone)
	end
	ui.dummy(Vector2(0, barHeight + ui.rescaleUI(Vector2(0, 4), Vector2(1920, 1080)).y))

	local contentPos = ui.getCursorScreenPos()
	local contentSize = ui.getContentRegion()
	ui.child("##stationSigContent_" .. tostring(self.id), contentSize, drawContentFn)

	if not verified and contentSize.x > 0 and contentSize.y > 0 then
		ui.addRectFilled(contentPos, contentPos + contentSize, colors.windowBackground:opacity(0.35 * (1 - frac)), 0, ui.RoundCornersNone)
	end
end

return StationSig
