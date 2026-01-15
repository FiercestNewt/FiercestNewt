local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Janitor = require(ReplicatedStorage.Packages.Janitor)
local Knit = require(ReplicatedStorage.Packages.Knit)

local Match = {}
Match.__index = Match

-- ENUM-LIKE STATE CONSTANTS
local State = {
	Init = "Init",
	PlayerSetup = "PlayerSetup",
	PreRoundSetup = "PreRoundSetup",
	Placement = "Placement",
	TurnStart = "TurnStart",
	PlayerDecision = "PlayerDecision",
	ResolveAction = "ResolveAction",
	CheckRoundEnd = "CheckRoundEnd",
	CheckMatchEnd = "CheckMatchEnd",
	EndMatch = "EndMatch",
	Cleanup = "Cleanup",
}

local drinkAnim = Instance.new("Animation")
drinkAnim.AnimationId = "rbxassetid://76761885807516"
drinkAnim.Parent = script
local curseAnim = Instance.new("Animation")
curseAnim.AnimationId = "rbxassetid://77641191101332"
curseAnim.Parent = script
local animations = {
	drinkAnim = drinkAnim,
	curseAnim = curseAnim,
}
local BottleTemplate = ReplicatedStorage.bottle
local wand = ReplicatedStorage.Wand

-- CONFIG
local Constants = require(ReplicatedStorage.Source.Shared.Constants)
local PLACEMENT_TIME = Constants.PLACEMENT_TIME
local TURN_TIME = Constants.TURN_TIME
local BOARD_SIZE = Constants.BOARD_SIZE
local CURSES_PER_ROUND = Constants.CURSES_PER_ROUND

local function loadAnimation(hum, anim)
	if hum:FindFirstChild("Animator") then
		hum = hum.Animator
	end
	return hum:LoadAnimation(anim)
end

local function SpawnBottlesForPlayer(self, tableModel, seatIndex, playerId, janitor)
	local BottlesFolder = tableModel:FindFirstChild("Bottles")
	if not BottlesFolder then
		BottlesFolder = Instance.new("Folder")
		BottlesFolder.Name = "Bottles"
		BottlesFolder.Parent = tableModel
	end
	local function makeUI(bottle, id)
		local g = Instance.new("BillboardGui")
		g.Size = UDim2.fromScale(1, 0.5)
		g.ExtentsOffsetWorldSpace = Vector3.new(0, 1, 0)
		local l = Instance.new("TextLabel")
		l.Size = UDim2.fromScale(1, 1)
		l.TextScaled = true
		l.Text = id
		l.BackgroundTransparency = 0.5
		l.Parent = g
		g.Parent = bottle
		g.Adornee = bottle
	end

	local playerBottles = {}
	local matCF = tableModel:FindFirstChild("Mat" .. seatIndex).CFrame

	for i = 1, Constants.BOARD_SIZE do
		local x = (i - 1) % 3 -- 0,1,2
		local z = math.floor((i - 1) / 3) -- 0,1,2,3

		local bottle = BottleTemplate:Clone()
		makeUI(bottle, i)
		-- cd.CursorIcon = "rbxassetid://89112624996739"
		bottle:SetAttribute("Id", i)
		bottle:SetAttribute("UserId", playerId)
		bottle.Name = "Bottle_" .. i
		bottle:PivotTo(
			matCF * Constants.BOTTLE_OFFSET
				- Vector3.new(x * Constants.BOTTLE_DISTANCE, 0, z * Constants.BOTTLE_DISTANCE)
		)
		bottle.Parent = BottlesFolder

		-- Store reference to board state
		playerBottles[i] = bottle
		janitor:Add(bottle)
	end

	return playerBottles
end

function Match.new(id, table, players, matchmakingService)
	local self = setmetatable({}, Match)

	self.Id = id
	self.Table = table
	self.MatchmakingService = matchmakingService
	self.Players = players -- {PlayerA, PlayerB}
	self.State = State.Init

	self.Winner = nil

	self.Score = {}

	self.CurrentPlayer = nil
	self.OpponentPlayer = nil

	self.RoundNumber = 0
	self.CursesEaten = {}

	self.Boards = {}

	self.PlacementDone = {}

	self.Animations = {}
	for _, player in players do
		self.Score[player] = 0
		self.CursesEaten[player] = 0
		self.Boards[player] = self:_CreateEmptyBoard()
		self.PlacementDone[player] = false
		self.Animations[player] = {}
	end

	self._cleanup = Janitor.new()
	self.PlayerBottles = {}
	return self
end

-- STATE MACHINE CORE

function Match:SetState(newState)
	if self.State == newState then
		return
	end
	self.State = newState

	-- Optionally print for debugging:
	-- print(("[Match %d] State -> %s"):format(self.Id, newState))

	local handlerName = "OnEnter_" .. newState
	local handler = self[handlerName]
	if handler then
		handler(self)
	end
end

function Match:Start()
	for i, player in self.Players do
		if player:IsA("Bot") then
			continue
		end
		local dataPacket = {
			matchId = self.Id,
			playerId = i,
			TableModel = self.Table,
		}
		self.MatchmakingService.Client.MatchStarted:Fire(player, dataPacket)
	end
	self:SetState(State.PlayerSetup)
end

-- STATE HANDLERS

function Match:OnEnter_Init()
	-- not used directly; Start() jumps to WaitingForPlayers
end

function Match:OnEnter_PlayerSetup()
	-- confirm players are still in game
	for _, plr in ipairs(self.Players) do
		if not plr or plr.Parent ~= Players then
			self:EndEarly()
			return
		end
	end

	for i, player in self.Players do
		local char = player.Character
		local hum = char.Humanoid
		hum.JumpHeight = 0
		-- char.HumanoidRootPart.Anchored = true
		for name, anim in animations do
			self.Animations[player][name] = self._cleanup:Add(loadAnimation(hum, anim))
		end
		self.PlayerBottles[player] = SpawnBottlesForPlayer(self, self.Table, i, player.UserId, self._cleanup)
	end

	local conn
	local startT = os.clock()
	conn = RunService.Heartbeat:Connect(function(_deltaTime)
		if self.State ~= State.PlayerSetup then
			conn:Disconnect()
		end
		if os.clock() - startT > Constants.PRE_ROUND_DELAY then
			conn:Disconnect()
			self:SetState(State.PreRoundSetup)
		end
	end)
end

function Match:_CreateEmptyBoard()
	local board = {}
	for i = 1, BOARD_SIZE do
		board[i] = {
			HasCurse = false,
			Eaten = false,
			Revealed = false,
		}
	end
	return board
end

function Match:OnEnter_PreRoundSetup()
	local p1, p2 = self.Players[1], self.Players[2]
	self.CurrentPlayer = p1
	self.OpponentPlayer = p2

	self:SetState(State.Placement)
end

function Match:_HandlePlayerBottleInteract(player, id)
	if self.State == State.Placement then
		if not self.PlacementDone[player] then
			self:OnPlacementSubmitted(player, id)
		end
	elseif self.State == State.PlayerDecision then
		if self.CurrentPlayer == player then
			self:_HandleEat(player, id)
		end
	end
end

function Match:OnEnter_Placement()
	-- Signal clients to open placement UI
	for id, plr in ipairs(self.Players) do
		if plr:IsA("Bot") then
			continue
		end
		local allowed = plr == self.CurrentPlayer and self.OpponentPlayer.UserId or self.CurrentPlayer.UserId
		self.MatchmakingService.Client.PlacementState:Fire(plr, self.Id, allowed)
	end

	local start = tick()
	local conn
	conn = self._cleanup:Add(RunService.Heartbeat:Connect(function()
		if self.State ~= State.Placement then
			conn:Disconnect()
			return
		end
		if tick() - start >= PLACEMENT_TIME then
			conn:Disconnect()
			-- auto-fill any missing placements
			for _, plr in ipairs(self.Players) do
				if not self.PlacementDone[plr] then
					-- print("Auto assigneing", plr)
					self:_AutoAssignCurses(plr)
					self.PlacementDone[plr] = true
				end
			end
			self:SetState(State.TurnStart)
		end
	end))
end

function Match:_AutoAssignCurses(player)
	local board = self.Boards[player]
	local available = {}
	local total = 0
	for i = 1, BOARD_SIZE do
		if not board[i].HasCurse then
			table.insert(available, i)
		else
			total += 1
			if total >= Constants.CURSES_PER_ROUND then
				return
			end
		end
	end
	while total < Constants.CURSES_PER_ROUND and #available > 0 do
		local idx = table.remove(available, math.random(1, #available))
		board[idx].HasCurse = true
		total += 1
	end
	self:_BroadcastBoard()
end

function Match:OnEnter_TurnStart()
	local function tileToString(tile)
		if tile.HasCurse then
			if not tile.Revealed then
				return "❎"
			end
			return "⏹️"
		end
		if not tile.Revealed then
			return "🟧"
		end

		if tile.Eaten then
			return "⬛"
		end

		return "EMP"
	end

	-- Quick helper to print board
	local function PrintBoard(label, board)
		print("=== " .. label .. " ===")
		local columns = 3
		local row = {}

		for i, tile in ipairs(board) do
			table.insert(row, tileToString(tile))

			if i % columns == 0 then
				-- Join row into a single string and print it
				print(table.concat(row, " "))
				row = {}
			end
		end
	end
	for p, board in self.Boards do
		PrintBoard(p.Name, board)
	end
	-- Round could have ended in the background
	if self.State ~= State.TurnStart then
		return
	end
	self:SetState(State.PlayerDecision)
end

function Match:OnEnter_PlayerDecision()
	local localTurnPlayer = self.CurrentPlayer

	-- notify both clients whose turn it is
	for _, plr in ipairs(self.Players) do
		if plr:IsA("Bot") then
			continue
		end
		self.MatchmakingService.Client.TurnChanged:Fire(plr, self.Id, localTurnPlayer.UserId)
	end
	local turnStart = tick()

	local conn
	conn = self._cleanup:Add(RunService.Heartbeat:Connect(function()
		if self.State ~= State.PlayerDecision then
			conn:Disconnect()
			return
		end

		-- If player left, end match
		if not localTurnPlayer or localTurnPlayer.Parent ~= Players then
			conn:Disconnect()
			self:EndEarly()
			return
		end

		if tick() - turnStart >= TURN_TIME then
			conn:Disconnect()
			-- TODO: perform random eat for localTurnPlayer
			self:ResolveMove(localTurnPlayer, {
				Type = "EatRandom",
			})
		end
	end))
end

function Match:ResolveMove(player, moveData)
	if self.State ~= State.PlayerDecision then
		return
	end
	if player ~= self.CurrentPlayer then
		return
	end

	-- TODO: validate moveData (eat tile / ability use)
	-- TODO: update board, update self.CursesEaten[player] if needed

	if moveData.Type == "EatRandom" then
		-- local otherPlayer = if self.Players[1] == player then self.Players[2] else self.Players[1]

		local active = {}
		for i, tile in self.Boards[player] do
			if not tile.Eaten then
				table.insert(active, i)
			end
		end
		local randomIndex = active[math.random(1, #active)]
		self:_HandleEat(player, randomIndex)
	end

	self:SetState(State.ResolveAction)
end

function Match:_HandleEat(player, index)
	local board = self.Boards[player]
	local tile = board[index]
	if tile.Eaten then
		self.State = State.PlayerDecision
		self:ResolveMove(player, {
			Type = "EatRandom",
		})
		return
	end

	self:SetState("ResolvingEat")

	for _, plr in ipairs(self.Players) do
		if plr:IsA("Bot") then
			continue
		end
		self.MatchmakingService.Client.TurnChanged:Fire(plr, self.Id, -1)
	end

	tile.Eaten = true
	tile.Revealed = true

	-- Hide the physical bottle
	local bottle = self.PlayerBottles[player] and self.PlayerBottles[player][index]
	if bottle then
		local char = player.Character
		bottle.Parent = char
		for _, part in bottle:GetChildren() do
			if not part:IsA("BasePart") then
				continue
			end
			part.Anchored = false
		end
		local m = Instance.new("Motor6D")
		m.Parent = char.RightHand
		m.Part0 = char.RightHand
		m.Part1 = bottle.Bottle
		local anim: AnimationTrack = self.Animations[player].drinkAnim
		-- anim:AdjustSpeed(0.15)
		anim:Play()
		anim.Stopped:Wait()
		bottle:Destroy()
		m:Destroy()
	end

	if tile.HasCurse then
		local otherPlayer = if self.Players[1] == player then self.Players[2] else self.Players[1]
		self.CursesEaten[player] += 1

		local c = wand:Clone()
		c.Parent = otherPlayer.Character
		local m = Instance.new("Motor6D")
		m.Parent = otherPlayer.Character.RightHand
		m.Part0 = m.Parent
		m.Part1 = c.BodyAttach

		local anim = self.Animations[otherPlayer].curseAnim
		-- anim:AdjustSpeed(0.25)
		anim:Play()
		anim.Stopped:Wait()
		c:Destroy()

		Knit.GetService("VFXService"):PlaceCurse(player, otherPlayer)
		task.wait(1)
	end

	-- self:_BroadcastBoard()
	self:SetState(State.ResolveAction)
end

function Match:OnEnter_ResolveAction()
	-- For now, we just delay briefly for FX, then move on
	task.delay(0.5, function()
		if self.State == State.ResolveAction then
			self:SetState(State.CheckMatchEnd)
		end
	end)
end

function Match:OnEnter_CheckMatchEnd()
	local loser = nil
	for _, plr in ipairs(self.Players) do
		if self.CursesEaten[plr] >= 3 then
			loser = plr
			break
		end
	end

	if loser then
		local winner = (loser == self.Players[1]) and self.Players[2] or self.Players[1]
		-- TODO: send round result to clients
		self.Winner = winner
		self:SetState(State.EndMatch)
	else
		local p1, p2 = self.OpponentPlayer, self.CurrentPlayer
		self.CurrentPlayer = p1
		self.OpponentPlayer = p2
		self:SetState(State.TurnStart)
	end
end

function Match:OnEnter_EndMatch()
	-- TODO: reward players, save stats, show results UI
	task.delay(3, function()
		if self.State == State.EndMatch then
			self:SetState(State.Cleanup)
		end
	end)
end

function Match:OnEnter_Cleanup()
	-- Clean up connections
	self._cleanup:Destroy()

	-- Inform matchmaking service
	if self.MatchmakingService then
		self.MatchmakingService:_OnMatchEnded(self, self.Winner)
	end

	-- TODO: optionally teleport players back to lobby, etc.
end

-- EXTERNAL EVENTS

function Match:OnPlacementSubmitted(player, index)
	local otherPlayer = self.Players[1] == player and self.Players[2] or self.Players[1]
	if self.State ~= State.Placement then
		return
	end
	if not self.Boards[otherPlayer] then
		return
	end
	if self.PlacementDone[otherPlayer] then
		return
	end

	local board = self.Boards[otherPlayer]
	if board[index].HasCurse then
		return
	end

	board[index].HasCurse = true
	local curses = 0
	for _, value in board do
		if value.HasCurse then
			curses += 1
		end
	end

	if curses >= Constants.CURSES_PER_ROUND then
		self.PlacementDone[otherPlayer] = true
	end

	-- If both are done, move on
	if self.PlacementDone[self.Players[1]] and self.PlacementDone[self.Players[2]] then
		self:SetState(State.TurnStart)
	end
end

function Match:OnPlayerLeft(player)
	-- If someone leaves, just end early and award win to the other
	if self.State == State.Cleanup or self.State == State.EndMatch then
		return
	end
	self:EndEarly(player)
end

function Match:EndEarly(leaver)
	-- Simple logic: other player wins instantly
	if self.State == State.Cleanup then
		return
	end

	-- TODO: mark winner, give partial rewards, etc.
	local otherPlayer = leaver == self.Players[1] and self.Players[2] or self.Players[1]
	self.Winner = otherPlayer
	self:SetState(State.Cleanup)
end

function Match:_SerializeBoards()
	local data = {}
	for _, plr in ipairs(self.Players) do
		local board = self.Boards[plr]
		local tiles = {}
		for i = 1, 12 do
			local t = board[i]
			tiles[i] = {
				Eaten = t.Eaten,
				Revealed = t.Revealed,
				HasCurse = t.HasCurse,
			}
		end
		data[plr.UserId] = tiles
	end
	return data
end

function Match:_BroadcastBoard()
	local serialized = self:_SerializeBoards()
	for _i, plr in ipairs(self.Players) do
		if plr:IsA("Bot") then
			continue
		end
		local otherPlayer = if self.Players[1] == plr then self.Players[2] else self.Players[1]
		self.MatchmakingService.Client.BoardUpdated:Fire(plr, self.Id, serialized[otherPlayer.UserId], otherPlayer.UserId)
	end
end

return Match
