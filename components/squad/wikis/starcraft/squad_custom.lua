---
-- @Liquipedia
-- wiki=starcraft
-- page=Module:Squad/Custom
--
-- Please see https://github.com/Liquipedia/Lua-Modules to contribute
--

local Array = require('Module:Array')
local Class = require('Module:Class')
local Logic = require('Module:Logic')
local Lua = require('Module:Lua')
local String = require('Module:StringUtils')

local Squad = Lua.import('Module:Squad')
local SquadRow = Lua.import('Module:Squad/Row')
local SquadUtils = Lua.import('Module:Squad/Utils')

local CustomSquad = {}

---@param self Squad
---@return Squad
function CustomSquad.headerTlpd(self)
	local makeHeader = function(wikiText)
		return mw.html.create('th'):wikitext(wikiText):addClass('divCell')
	end

	local headerRow = mw.html.create('tr'):addClass('HeaderRow')

	headerRow:node(makeHeader('ID'))
		:node(makeHeader(''))
		:node(makeHeader('Name'))
		:node(makeHeader('ELO'))
		:node(makeHeader('ELO Peak'))

	self.content:node(headerRow)

	return self
end

---@class StarcraftSquadRow: SquadRow
local ExtendedSquadRow = Class.new(SquadRow)

---@param args table
---@return self
function ExtendedSquadRow:elo(args)
	self.content:node(mw.html.create('td'):wikitext(args.eloCurrent and (args.eloCurrent .. ' pts') or '-'))
	self.content:node(mw.html.create('td'):wikitext(args.eloPeak and (args.eloPeak .. ' pts') or '-'))

	return self
end

---@param frame Frame
---@return Html
function CustomSquad.run(frame)
	local squad = Squad()
	squad:init(frame)

	local args = squad.args

	local tlpd = Logic.readBool(args.tlpd)
	if tlpd then
		squad.header = CustomSquad.headerTlpd
	else
		squad:title()
	end

	squad:header()
	local players = SquadUtils.parsePlayers(args)

	Array.forEach(players, function(player)
		local row = ExtendedSquadRow()

		local faction = CustomSquad._queryTLPD(player.id, 'race') or player.race
		local id = CustomSquad._queryTLPD(player.id, 'name') or player.id
		local link = player.link or player.altname or id
		local currentTeam = CustomSquad._queryTLPD(player.id, 'team_name')
		local name = CustomSquad._queryTLPD(player.id, 'name_korean') or ''
		local localizedName = CustomSquad._queryTLPD(player.id, 'name_romanized') or player.name or ''
		local elo = CustomSquad._queryTLPD(player.id, 'elo')
		local eloPeak = CustomSquad._queryTLPD(player.id, 'peak_elo')

		row:status(squad.type)
		row:id{
			id,
			race = faction,
			link = link,
			team = currentTeam,
			flag = player.flag,
			captain = player.captain,
			role = player.role,
			date = player.leavedate or player.inactivedate or player.leavedate,
		}
		row:name{name = name .. ' ' .. localizedName}

		if tlpd then
			row:elo{eloCurrent = elo, eloPeak = eloPeak}
		else
			row:role{role = player.role}
			row:date(player.joindate, 'Join Date:&nbsp;', 'joindate')

			if squad.type == SquadUtils.SquadType.FORMER then
				row:date(player.leavedate, 'Leave Date:&nbsp;', 'leavedate')
				row:newteam{
					newteam = player.newteam,
					newteamrole = player.newteamrole,
					newteamdate = player.newteamdate,
					leavedate = player.leavedate
				}
			elseif squad.type == SquadUtils.SquadType.INACTIVE then
				row:date(player.inactivedate, 'Inactive Date:&nbsp;', 'inactivedate')
			end
		end

		squad:row(row:create(SquadUtils.defaultObjectName(player, squad.type)))
	end)

	return squad:create()
end

---@param id number?
---@param value string
---@return string?
function CustomSquad._queryTLPD(id, value)
	if not Logic.isNumeric(id) then
		return
	end

	return String.nilIfEmpty(mw.getCurrentFrame():callParserFunction{
		name = '#external_info:tlpd_player',
		args = {id, value}
	})
end

return CustomSquad
