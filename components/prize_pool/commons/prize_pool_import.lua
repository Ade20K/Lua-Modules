---
-- @Liquipedia
-- wiki=commons
-- page=Module:PrizePool/Import
--
-- Please see https://github.com/Liquipedia/Lua-Modules to contribute
--

local Lua = require('Module:Lua')
local Array = require('Module:Array')
local DateExt = require('Module:Date/Ext')
local Logic = require('Module:Logic')
local MathUtil = require('Module:MathUtil')
local String = require('Module:StringUtils')
local Table = require('Module:Table')

local MatchGroupCoordinates = Lua.import('Module:MatchGroup/Coordinates')
local MatchGroupUtil = Lua.import('Module:MatchGroup/Util')
local Placement = Lua.import('Module:PrizePool/Placement')
local TournamentStructure = Lua.import('Module:TournamentStructure')

local OpponentLibrary = require('Module:OpponentLibraries')
local Opponent = OpponentLibrary.Opponent

local AUTOMATION_START_DATE = '2023-01-01'
local GROUPSCORE_DELIMITER = '/'
local SCORE_STATUS = 'S'
local DEFAULT_ELIMINATION_STATUS = 'down'
local THIRD_PLACE_MATCH_ID = 'RxMTP'
local GSL_GROUP_OPPONENT_NUMBER = 4
local SWISS_GROUP_TYPE = 'swiss'
local GSL_STYLE_SCORES = {
	{w = 2, d = 0, l = 0},
	{w = 2, d = 0, l = 1},
	{w = 1, d = 0, l = 2},
	{w = 0, d = 0, l = 2},
}
local BYE_OPPONENT_NAME = 'bye'

local _parent
local _last_vs_group_cache = {}

local Import = {}

function Import.run(parent)
	_parent = parent

	Import.config = Import._getConfig(parent.args, parent.placements)

	if Import.config.importLimit == 0 or not Import.config.matchGroupsSpec then
		return parent.placements
	end

	return Import._importPlacements(parent.placements)
end

function Import._getConfig(args, placements)
	if String.isEmpty(args.matchGroupId1) and String.isEmpty(args.tournament1)
		and String.isEmpty(args.matchGroupId) and String.isEmpty(args.tournament)
		and not Import._enableImport(args.import) then

		return {}
	end

	return {
		ignoreNonScoreEliminations = Logic.readBool(args.ignoreNonScoreEliminations),
		importLimit = Import._importLimit(args.importLimit, placements, args.placementsExtendImportLimit),
		placementsToSkip = tonumber(args.placementsToSkip),
		matchGroupsSpec = TournamentStructure.readMatchGroupsSpec(args)
			or TournamentStructure.currentPageSpec(),
		groupElimStatuses = Array.map(
			mw.text.split(args.groupElimStatuses or DEFAULT_ELIMINATION_STATUS, ','),
			String.trim
		),
		groupScoreDelimiter = args.groupScoreDelimiter or GROUPSCORE_DELIMITER,
		allGroupsUseWdl = Logic.readBool(args.allGroupsUseWdl),
		stageImportLimits = Table.mapArguments(
			args,
			function(key) return tonumber(string.match(key, '^stage(%d+)importLimit$')) end,
			function(key) return tonumber(args[key]) end,
			true
		),
		stagePlacementsToSkip = Table.mapArguments(
			args,
			function(key) return tonumber(string.match(key, '^stage(%d+)placementsToSkip$')) end,
			function(key) return tonumber(args[key]) end,
			true
		),
		stageImportWinners = Table.mapArguments(
			args,
			function(key) return tonumber(string.match(key, '^stage(%d+)importWinners$')) end,
			function(key) return Logic.readBoolOrNil(args[key]) end,
			true
		),
		stageGroupElimStatuses = Table.mapArguments(
			args,
			function(key) return tonumber(string.match(key, '^stage(%d+)groupElimStatuses$')) end,
			function(key) return Array.map(
				mw.text.split(args[key], ','),
				String.trim
			) end,
			true
		),
	}
end

function Import._enableImport(importInput)
	local date = DateExt.getContextualDateOrNow()
	return Logic.nilOr(
		Logic.readBoolOrNil(importInput),
		date >= AUTOMATION_START_DATE
	)
end

function Import._importLimit(importLimitInput, placements, placementsExtendImportLimit)
	local importLimit = tonumber(importLimitInput)

	if not importLimit then
		return
	end

	if not Logic.readBool(placementsExtendImportLimit) then
		return importLimit
	end

	-- if the number of entered entries is higher use that instead
	return math.max(placements[#placements].placeEnd or 0, importLimit)
end

-- fills in placements and opponents using data fetched from LPDB
function Import._importPlacements(inputPlacements)
	local stages = TournamentStructure.fetchStages(Import.config.matchGroupsSpec)

	local placementEntries = Array.flatten(Array.map(Array.reverse(stages), function(stage, reverseStageIndex)
				local stageIndex = #stages + 1 - reverseStageIndex
				return Import._computeStagePlacementEntries(stage, {
						importWinners = Import.config.stageImportWinners[stageIndex] or
							(Import.config.stageImportWinners[stageIndex] == nil and reverseStageIndex == 1),
						groupElimStatuses = Import.config.stageGroupElimStatuses[stageIndex] or
							Import.config.groupElimStatuses,
						importLimit = Import.config.stageImportLimits[stageIndex] or 0,
						placementsToSkip = Import.config.stagePlacementsToSkip[stageIndex],
					})
			end))

	placementEntries = Array.sub(placementEntries, 1 + (Import.config.placementsToSkip or 0))

	-- Apply importLimit if set
	if Import.config.importLimit then
		-- array of partial sums of the number of entries until a given placement/slot
		local importedEntriesSums = MathUtil.partialSums(Array.map(placementEntries, function(entries) return #entries end))
		-- slotIndex of the slot until which we want to import based on importLimit
		local slotIndex = Array.indexOf(importedEntriesSums, function(sum) return Import.config.importLimit <= sum end)
		if slotIndex ~= 0 then
			placementEntries = Array.sub(placementEntries, 1, slotIndex - 1)
		end
	end

	return Import._mergePlacements(placementEntries, inputPlacements)
end

-- Compute placements and their entries of all brackets or all group tables in a
-- tournament stage. The placements are ordered from high placement to low.
function Import._computeStagePlacementEntries(stage, options)
	local groupPlacementEntries = Array.map(stage, function(matchGroup)
		return TournamentStructure.isGroupTable(matchGroup)
			and Import._computeGroupTablePlacementEntries(matchGroup, options)
			or Import._computeBracketPlacementEntries(matchGroup, options)
	end)

	local startingPlacement = 1 + (options.placementsToSkip or 0)
	local endingPlacement = options.importLimit
	if options.importLimit > 0 and startingPlacement > 1 then
		endingPlacement = options.importLimit + options.placementsToSkip
	end

	local maxPlacementCount = Array.max(Array.map(
			groupPlacementEntries,
			function(placementEntries) return #placementEntries end
		)) or 0

	maxPlacementCount = endingPlacement > 0
		and math.min(maxPlacementCount, endingPlacement)
		or maxPlacementCount

	return Array.map(Array.range(startingPlacement, maxPlacementCount), function(placementIndex)
		return Array.flatten(Array.map(groupPlacementEntries, function(placementEntries)
			return placementEntries[placementIndex]
		end))
	end)
end

-- Compute placements and their entries from a GroupTableLeague record.
function Import._computeGroupTablePlacementEntries(standingRecords, options)
	local needsLastVs = Import._needsLastVs(standingRecords)
	local placementEntries = {}
	local placementIndexes = {}

	for _, record in ipairs(standingRecords) do
		if options.importWinners or Table.includes(options.groupElimStatuses, record.currentstatus) then
			local entry = {
				date = record.extradata.enddate and DateExt.toYmdInUtc(record.extradata.enddate),
				hasDraw = record.hasDraw,
				hasOvertime = record.hasOvertime,
			}

			if not record.extradata.placeRange and Logic.readBool(record.extradata.finished) then
				record.extradata.placeRange = {record.placement, record.placement}
			end
			if record.extradata.placeRange and record.extradata.placeRange[1] == record.extradata.placeRange[2] then
				Table.mergeInto(entry, {
					scoreBoard = record.scoreboard,
					opponent = record.opponent,
				})
				if entry.opponent.name then
					entry.opponent.isResolved = true
				end
			end

			entry.needsLastVs = needsLastVs
			entry.matches = record.matches

			if not placementIndexes[record.placement] then
				table.insert(placementEntries, {entry})
				placementIndexes[record.placement] = #placementEntries
			else
				table.insert(placementEntries[placementIndexes[record.placement]], entry)
			end
		end
	end

	return placementEntries
end

function Import._needsLastVs(standingRecords)
	if Import.config.allGroupsUseWdl then
		return false
	elseif (standingRecords[1] or {}).type == SWISS_GROUP_TYPE then
		return true
	elseif #standingRecords ~= GSL_GROUP_OPPONENT_NUMBER then
		return false
	end

	for _, record in pairs(standingRecords) do
		local placement = record.placement
		if not placement or not GSL_STYLE_SCORES[placement] or
			not Table.deepEquals(GSL_STYLE_SCORES[placement], record.scoreboard.match) then
			return false
		end
	end

	return true
end

-- Compute placements and their entries from the match records of a bracket.
function Import._computeBracketPlacementEntries(matchRecords, options)
	local bracket = MatchGroupUtil.makeBracketFromRecords(matchRecords)

	local slots = Array.map(
		Import._computeBracketPlacementGroups(bracket, options),
		function(group)
			return Array.map(group, function(placementEntry)
				local match = bracket.matchesById[placementEntry.matchId]
				if match.bracketData.bracketResetMatchId then
					local resetMatchId = match.bracketData.bracketResetMatchId
					match = bracket.matchesById[resetMatchId] or match
				end
				return Import._makeEntryFromMatch(placementEntry, match)
			end)
		end
	)

	-- Remove `bye`s from slotentries
	for slotIndex, slotEntries in pairs(slots) do
		slots[slotIndex] = Array.filter(slotEntries, function(entry)
			return not (
				entry.opponent
				and entry.opponent.type == Opponent.literal
				and Opponent.toName(entry.opponent):lower() == BYE_OPPONENT_NAME
			) and (not Import.config.ignoreNonScoreEliminations or not entry.opponent or entry.opponent.status == SCORE_STATUS)
		end)
	end

	return slots
end

function Import._makeEntryFromMatch(placementEntry, match)
	local entry = {
		date = DateExt.toYmdInUtc(match.date),
	}

	if match.winner and 1 <= match.winner and #match.opponents == 2 then
		local entryOpponentIndex = placementEntry.matchPlacement == 1
			and match.winner
			or #match.opponents - match.winner + 1
		local opponent = match.opponents[entryOpponentIndex]
		local vsOpponent = match.opponents[#match.opponents - entryOpponentIndex + 1]
		opponent.isResolved = true
		vsOpponent.isResolved = true

		Table.mergeInto(entry, {
			lastGameScore = {opponent.score, 0, vsOpponent.score},
			lastStatuses = {opponent.status, vsOpponent.status},
			opponent = opponent,
			vsOpponent = vsOpponent,
		})
	end

	return entry
end

-- Computes the placements of a LPDB bracket
-- @options.importWinners: Whether to include placements for non-eliminated opponents.
function Import._computeBracketPlacementGroups(bracket, options)
	local firstDropdownRoundIndexes = Import._findBracketFirstDropdownRounds(bracket)
	local preTiebreakMatchIds = Import._getPreTiebreakMatchIds(bracket)

	local function getGroupKeys(matchId)
		local coordinates = bracket.coordinatesByMatchId[matchId]

		-- Winners and losers of grand finals
		if coordinates.semanticDepth == 0 then
			return Array.append({},
				options.importWinners and {1, coordinates.sectionIndex, 1} or nil,
				{1, coordinates.sectionIndex, 2}
			)

		-- Third place match
		elseif String.endsWith(matchId, THIRD_PLACE_MATCH_ID) then
			return {
				{2, coordinates.depth + 0.5, 1},
				{2, coordinates.depth + 0.5, 2},
			}

		-- Semifinals into third place match
		elseif preTiebreakMatchIds[matchId] then
			return {}

		else
			local function shouldImportKnockedOutOpponents()
				if bracket.bracketDatasById[matchId].qualLose and not options.importWinners then
					return false
				elseif coordinates.sectionIndex == #bracket.sections then
					-- Always include lowest bracket section
					return true
				elseif not firstDropdownRoundIndexes[coordinates.sectionIndex] then
					-- No dropdown opponents for this level
					return false
				elseif coordinates.roundIndex < firstDropdownRoundIndexes[coordinates.sectionIndex] then
					-- Also include opponents directly knocked out from an upper bracket
					return true
				end
				return false
			end

			local groupKeys = {}
			if coordinates.depth == 0 and options.importWinners then
				-- Winners of root matches
				table.insert(groupKeys, {0, coordinates.sectionIndex, 1})
				-- in case of qualLose also Loser of root match if not lower bracket (lower bracket gets handled below)
				if bracket.bracketDatasById[matchId].qualLose and coordinates.sectionIndex ~= #bracket.sections then
					table.insert(groupKeys, {0, coordinates.sectionIndex, 2})
				end
			end
			if shouldImportKnockedOutOpponents() then
				-- Opponents knocked out from sole section (se) or lower sections (de/te/etc.)
				table.insert(groupKeys, {2, coordinates.depth, 2})
			end

			return groupKeys
		end
	end

	local placementEntries = {}
	for matchId in MatchGroupCoordinates.dfs(bracket) do
		for _, groupKey in ipairs(getGroupKeys(matchId)) do
			table.insert(placementEntries, {
				groupKey = groupKey,
				matchId = matchId,
				matchPlacement = groupKey[3],
			})
		end
	end

	Array.sortInPlaceBy(placementEntries, function(entry)
		return Array.extend(
			entry.groupKey,
			bracket.coordinatesByMatchId[entry.matchId].matchIndexInRound
		)
	end)

	return Array.groupBy(placementEntries, function(entry)
		return table.concat(entry.groupKey, '.')
	end)
end

-- Returns the semifinals match IDs of a bracket if the losers also play in a
-- third place match to determine placement.
function Import._getPreTiebreakMatchIds(bracket)
	local firstBracketData = bracket.bracketDatasById[bracket.rootMatchIds[1]]
	local thirdPlaceMatchId = firstBracketData.thirdPlaceMatchId

	local sfMatchIds = {}
	if thirdPlaceMatchId and bracket.matchesById[thirdPlaceMatchId] then
		for _, lowerMatchId in ipairs(firstBracketData.lowerMatchIds) do
			sfMatchIds[lowerMatchId] = true
		end
	end
	return sfMatchIds
end

-- Gets the first round of each level (section) of a bracket where losers drop to the level below.
-- Returns empty array if the bracket is single elimination. If no losers drop to a lower level, then
-- the array will contain `-1` for that level.
---@return number[]
function Import._findBracketFirstDropdownRounds(bracket)
	local countsByRound = MatchGroupCoordinates.computeRawCounts(bracket)
	local roundIndexes = Array.range(1, #bracket.rounds)

	return Array.map(Array.range(2, #bracket.sections), function(sectionIndex)
		local firstRoundWithPositiveCount = Array.find(roundIndexes, function(roundIndex)
			return countsByRound[roundIndex][sectionIndex] >= 0 end)

		return firstRoundWithPositiveCount and countsByRound[firstRoundWithPositiveCount][sectionIndex] == 0
			and firstRoundWithPositiveCount or -1
	end)
end

function Import._mergePlacements(lpdbEntries, placements)
	for placementIndex, lpdbPlacement in ipairs(lpdbEntries) do
		placements[placementIndex] = Import._mergePlacement(
			lpdbPlacement,
			placements[placementIndex] or Import._emptyPlacement(placements[placementIndex - 1], #lpdbPlacement)
		)
	end

	return placements
end

function Import._emptyPlacement(priorPlacement, placementSize)
	priorPlacement = priorPlacement or {}
	local placeStart = (priorPlacement.placeEnd or 0) + 1
	local placeEnd = (priorPlacement.placeEnd or 0) + placementSize

	return Placement(
		{placeStart = placeStart, placeEnd = placeEnd, count = placementSize},
		_parent
	):create(priorPlacement.placeEnd or 0)
end

function Import._mergePlacement(lpdbEntries, placement)
	for opponentIndex, opponent in ipairs(lpdbEntries) do
		placement.opponents[opponentIndex] = Import._removeDefaultDate(Import._mergeEntry(
			opponent,
			Table.mergeInto(placement:parseOpponents{{}}[1], placement.opponents[opponentIndex]),
			placement
		))
	end

	assert(
		#placement.opponents <= placement.count,
		'Import: Too many opponents returned from query for placement range '
			.. placement:_displayPlace():gsub('&#045;', '-')
	)

	return placement
end

function Import._mergeEntry(lpdbEntry, entry, placement)
	if
		not Opponent.isTbd(entry.opponentData) -- valid manual input
		or Table.isEmpty(lpdbEntry.opponent) -- irrelevant lpdbEntry
		or Opponent.isTbd(lpdbEntry.opponent)
	then
		return entry
	end

	entry.opponentData = Import._removeTbdIdentifiers(entry.opponentData)

	lpdbEntry = Import._entryToOpponent(lpdbEntry, placement)

	entry.date = lpdbEntry.date or entry.date

	return Table.deepMergeInto(lpdbEntry, entry)
end

function Import._removeTbdIdentifiers(opponent)
	if Table.isEmpty(opponent) then
		return {}
	elseif not Opponent.isTbd(opponent) then
		return opponent
	-- Entry is a TBD Opponent, but could contain data (e.g. flag or faction) for party opponents
	elseif not opponent.type or not Opponent.typeIsParty(opponent.type) then
		return {}
	end

	opponent.type = nil
	for _, player in pairs(opponent.players or {}) do
		if Opponent.playerIsTbd(player) then
			player.displayName = nil
			player.pageIsResolved = nil
			player.pageName = nil
		end
	end

	return opponent
end

function Import._entryToOpponent(lpdbEntry, placement)
	local additionalData = {}
	if lpdbEntry.needsLastVs then
		additionalData = Import._groupLastVsAdditionalData(lpdbEntry)
	end

	local score = additionalData.score or Import._getScore(lpdbEntry.opponent)
	local vsScore = additionalData.vsScore or Import._getScore(lpdbEntry.vsOpponent)
	local lastVsScore
	if score or vsScore then
		lastVsScore = (score or '') .. '-' .. (vsScore or '')
	end

	local lastVs = Import._checkIfParsed(additionalData.lastVs or Import._removeTbdIdentifiers(lpdbEntry.vsOpponent))

	return placement:parseOpponents{{
		Import._checkIfParsed(Import._removeTbdIdentifiers(lpdbEntry.opponent)),
		wdl = (not lpdbEntry.needsLastVs) and Import._formatGroupScore(lpdbEntry) or nil,
		lastvs = Table.isNotEmpty(lastVs) and {lastVs} or nil,
		lastvsscore = lastVsScore,
		date = additionalData.date or lpdbEntry.date,
	}}[1]
end

function Import._checkIfParsed(opponent)
	if Table.isNotEmpty(opponent) then
		opponent.isAlreadyParsed = true
	end

	return opponent
end

function Import._formatGroupScore(lpdbEntry)
	if not lpdbEntry.scoreBoard then
		return
	end

	local matches = lpdbEntry.scoreBoard.match
	local overtime = lpdbEntry.scoreBoard.overtime
	local wdl = {matches.w or '', matches.l or ''}
	if lpdbEntry.hasDraw then
		table.insert(wdl, 2, matches.d or '')
	end
	if lpdbEntry.hasOvertime then
		table.insert(wdl, 2, overtime.w or '')
		table.insert(wdl, #wdl, overtime.l or '')
	end

	return table.concat(wdl, Import.config.groupScoreDelimiter)
end

function Import._getScore(opponentData)
	if not opponentData then
		return
	end

	return opponentData.status == SCORE_STATUS and opponentData.score
		or opponentData.status
end

function Import._groupLastVsAdditionalData(lpdbEntry)
	local opponentName = Opponent.toName(lpdbEntry.opponent)
	local matchConditions = {}
	for _, matchId in pairs(lpdbEntry.matches) do
		table.insert(matchConditions, '[[match2id::' .. matchId .. ']]')
	end

	local conditions = table.concat(matchConditions, ' OR ')

	if conditions ~= _last_vs_group_cache.conditions then
		_last_vs_group_cache.conditions = conditions
		Import._lastVsMatchesDataToCache(mw.ext.LiquipediaDB.lpdb('match2', {
			conditions = conditions,
			order = 'date desc, match2id desc',
			query = 'date, match2opponents, winner',
			limit = 1000,
		}))
	end

	local matchData = _last_vs_group_cache.data[opponentName]

	if not matchData then
		return {}
	end

	return Import._makeAdditionalDataFromMatch(opponentName, matchData)
end

function Import._lastVsMatchesDataToCache(queryData)
	local byOpponent = {}

	for _, match in ipairs(queryData) do
		for _, opponent in pairs(match.match2opponents) do
			local name = opponent.name
			if not byOpponent[name] then
				byOpponent[name] = match
			end
		end
	end

	_last_vs_group_cache.data = byOpponent
end

function Import._makeAdditionalDataFromMatch(opponentName, match)
	-- catch unfinished or invalid match
	local winner = tonumber(match.winner)
	if not winner or winner < 1 or #match.match2opponents ~= 2 then
		return {}
	end

	local score, vsScore, lastVs
	for _, opponent in pairs(match.match2opponents) do
		if opponent.name == opponentName then
			score = Import._getScore(opponent)
		else
			vsScore = Import._getScore(opponent)
			lastVs = MatchGroupUtil.opponentFromRecord(opponent)
		end
	end

	return {
		date = match.date,
		lastVs = lastVs,
		score = score,
		vsScore = vsScore,
	}
end

function Import._removeDefaultDate(entry)
	entry.date = String.isNotEmpty(entry.date) and DateExt.readTimestamp(entry.date) ~= DateExt.defaultTimestamp and
		entry.date or nil

	return entry
end

return Import
