---
-- @Liquipedia
-- wiki=mobilelegends
-- page=Module:Squad/Custom
--
-- Please see https://github.com/Liquipedia/Lua-Modules to contribute
--

local Array = require('Module:Array')
local Class = require('Module:Class')
local Lua = require('Module:Lua')
local ReferenceCleaner = require('Module:ReferenceCleaner')
local String = require('Module:StringUtils')
local Table = require('Module:Table')
local Widget = require('Module:Infobox/Widget/All')

local Squad = Lua.import('Module:Squad')
local SquadRow = Lua.import('Module:Squad/Row')
local SquadUtils = Lua.import('Module:Squad/Utils')
local Injector = Lua.import('Module:Infobox/Widget/Injector')

local CustomSquad = {}
local CustomInjector = Class.new(Injector)

function CustomInjector:parse(id, widgets)
	if id == 'header_role' then
		return {
			Widget.TableCell{}:addContent('Position')
		}
	end

	return widgets
end

---@class MobilelegendsSquadRow: SquadRow
local ExtendedSquadRow = Class.new(SquadRow)

---@param args table
---@return self
function ExtendedSquadRow:position(args)
	local cell = Widget.TableCell{}
	cell:addClass('Position')

	if String.isNotEmpty(args.position) or String.isNotEmpty(args.role) then
		cell:addContent(mw.html.create('div'):addClass('MobileStuff'):wikitext('Position:&nbsp;'))

		if String.isNotEmpty(args.position) then
			cell:addContent(args.position)
			if String.isNotEmpty(args.role) then
				cell:addContent('&nbsp;(' .. args.role .. ')')
			end
		elseif String.isNotEmpty(args.role) then
			cell:addContent(args.role)
		end
	end

	self.content:addCell(cell)

	self.lpdbData.position = args.position
	self.lpdbData.role = args.role or self.lpdbData.role

	return self
end

---@param frame Frame
---@return Html
function CustomSquad.run(frame)
	local squad = Squad():init(frame, CustomInjector()):title():header()

	local players = SquadUtils.parsePlayers(squad.args)

	Array.forEach(players, function(player)
		squad:row(CustomSquad._playerRow(player, squad.type))
	end)

	return squad:create()
end

---@param playerList table[]
---@param squadType integer
---@return Html?
function CustomSquad.runAuto(playerList, squadType)
	if Table.isEmpty(playerList) then
		return
	end

	local squad = Squad():init({}, CustomInjector):title()

	squad.type = squadType

	squad:header()

	Array.forEach(playerList, function(player)
		squad:row(CustomSquad._playerRow(SquadUtils.convertAutoParameters(player), squad.type))
	end)

	return squad:create()
end

---@param player table
---@param squadType integer
---@return WidgetTableRow
function CustomSquad._playerRow(player, squadType)
	local row = ExtendedSquadRow()

	row:status(squadType)
	row:id({
		(player.idleavedate or player.id),
		flag = player.flag,
		link = player.link,
		captain = player.captain,
		role = player.role,
		team = player.team,
		date = player.leavedate or player.inactivedate or player.leavedate,
	})
	row:name{name = player.name}
	row:position{role = player.role, position = player.position}
	row:date(player.joindate, 'Join Date:&nbsp;', 'joindate')

	if squadType == Squad.SquadType.FORMER then
		row:date(player.leavedate, 'Leave Date:&nbsp;', 'leavedate')
		row:newteam{
			newteam = player.newteam,
			newteamrole = player.newteamrole,
			newteamdate = player.newteamdate,
			leavedate = player.leavedate
		}
	elseif squadType == Squad.SquadType.INACTIVE then
		row:date(player.inactivedate, 'Inactive Date:&nbsp;', 'inactivedate')
	end

	return row:create(
		mw.title.getCurrentTitle().prefixedText .. '_' .. player.id .. '_' .. ReferenceCleaner.clean(player.joindate)
		.. (player.role and '_' .. player.role or '')
		.. '_' .. squadType
	)
end

return CustomSquad
