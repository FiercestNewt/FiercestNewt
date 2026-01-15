--[[
	NPCInteractionService
	---------------------
	Handles player interaction with NPCs.

	Responsibilities:
	- Grabbing NPCs
	- Throwing NPCs
	- Clearing held NPCs on death/leave

	Client Signals:
	- RagdollCarried
	- ThrowRagdoll
	- RagdollStopped
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Knit = require(ReplicatedStorage.Packages.Knit)

local Constants = require(ReplicatedStorage.Source.Shared.Constants)
local NPCState = require(ReplicatedStorage.Source.Shared.NPCState)

local DataService = require(script.Parent.PlayerData.DataService)
local Physics = require(ReplicatedStorage.Source.Shared.Util.Physics)
local Strength = require(ReplicatedStorage.Source.Shared.GameData.Upgrades).Strength

local function getLaunchMultiplier(player)
	local upgrades = DataService:Get(player, "Upgrades")
	return Physics.getLaunchMult(upgrades.Strength, Strength.EffectPerLevel)
end
local NPCInteractionService = Knit.CreateService({
	Name = "NPCInteractionService",
	Client = {
		NPCCarried = Knit.CreateSignal(),
		ThrowNPC = Knit.CreateSignal(),
	},
})

---------------------------------------------------------
-- STATE
---------------------------------------------------------

-- [player] = npc
NPCInteractionService.Held = {}

local NPCThrownService
local DataService

---------------------------------------------------------
-- LIFECYCLE
---------------------------------------------------------

function NPCInteractionService:KnitStart()
	NPCThrownService = Knit.GetService("NPCThrownService")
	DataService = Knit.GetService("DataService")

	self.Client.ThrowNPC:Connect(function(player, dir)
		self:ThrowNPC(player, dir)
	end)

	Players.PlayerRemoving:Connect(function(player)
		self:ClearHeldNPC(player)
	end)
end

---------------------------------------------------------
-- PUBLIC API
---------------------------------------------------------

-- Player grabs an NPC
function NPCInteractionService:GrabNPC(player, npc)
	if self.Held[player] then
		return
	end

	npc.State = NPCState.Held
	npc:Carried(player)

	self.Held[player] = npc
	self.Client.NPCCarried:Fire(player, npc.Model)
end

-- Player throws held NPC
function NPCInteractionService:ThrowNPC(player, dir)
	local npc = self.Held[player]
	if not npc then
		return
	end

	-- Validation (anti-exploit)
	if typeof(dir) ~= "Vector3" then
		return
	end

	if dir.Magnitude < 0.9 or dir.Magnitude > 1.1 then
		return
	end

	local trail = DataService:Get(player, "Cosmetics").Trails.Equipped
	if trail then
		npc.Model:SetAttribute("Trail", trail)
	end
	npc.Model:SetAttribute("Player", player.UserId)

	self.Held[player] = nil
	NPCThrownService:RegisterThrownNPC(player, npc, dir.Unit)
	local launchMult = getLaunchMultiplier(player) * Constants.LAUNCH_FACTOR
	self.Client.ThrowNPC:FireFilter(function(p)
		return p.Character and (p.Character.HumanoidRootPart.Position - npc.HRP.Position).Magnitude <= 200
	end, npc.Model, dir.Unit, launchMult)
end

-- Clears held NPC safely
function NPCInteractionService:ClearHeldNPC(player)
	local npc = self.Held[player]
	if not npc then
		return
	end

	self.Held[player] = nil
	npc.State = NPCState.Idle
	npc.player = nil
end

--[[
	NPCThrownService
	----------------
	Handles airborne NPC logic.

	Responsibilities:
	- Track distance traveled
	- Trigger mutations
	- Detect finish conditions
	- Award currency
]]
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Knit = require(ReplicatedStorage.Packages.Knit)

local DistanceMonitor = require(ReplicatedStorage.Source.Modules.DistanceMonitor)
local Constants = require(ReplicatedStorage.Source.Shared.Constants)
local NPCState = require(ReplicatedStorage.Source.Shared.NPCState)

local MultiplierUtil = require(ReplicatedStorage.Source.Shared.Util.Multiplier)
local PartValues = require(ReplicatedStorage.Source.Shared.GameData.PartValues)

local baseValue = {}
for name in PartValues do
	baseValue[name] = 1
end

local Ring = require(script.Parent.Parent.Components.Ring)

-- local function setPhysics(model)
-- 	for _, part in model:GetDescendants() do
-- 		if part:IsA("BasePart") then
-- 			if partMap[part.Name] then
-- 				part.CollisionGroup = "NPC"
-- 			end
-- 		end
-- 	end
-- end

local NPCThrownService = Knit.CreateService({
	Name = "NPCThrownService",
	Client = {
		NPCStopped = Knit.CreateSignal(),
	},
})

---------------------------------------------------------
-- STATE
---------------------------------------------------------

-- [npc] = data
NPCThrownService.Thrown = {}
NPCThrownService.ZoneVolumes = {}

local AwardService
local MutationService
local NPCZoneService

---------------------------------------------------------
-- LIFECYCLE
---------------------------------------------------------

function NPCThrownService:KnitStart()
	AwardService = Knit.GetService("AwardService")
	MutationService = Knit.GetService("MutationService")
	NPCZoneService = Knit.GetService("NPCZoneService")
	self._heartbeatAccum = 0

	-- self:_cacheMutationVolumes()

	RunService.Heartbeat:Connect(function(dt)
		self._heartbeatAccum += dt
		if self._heartbeatAccum < 0.05 then
			return
		end
		self:_update(self._heartbeatAccum)
		self._heartbeatAccum = 0
	end)
end

---------------------------------------------------------
-- PUBLIC API
---------------------------------------------------------

-- Registers an NPC as thrown
function NPCThrownService:RegisterThrownNPC(player, npc, dir)
	-- TODO: handle edge case where npc is destroyed and finish is not called (falls off cliff, destroyed by roblox)
	npc.State = NPCState.Thrown
	npc:onThrown()

	-- setPhysics(npc.Model)
	npc.Blackboard.lastHit = os.clock()
	if npc.Blackboard.CanMutate then
		self:_setupImpactSensors(npc)
	end

	for _, ring in Ring:GetAll() do
		ring:TrackItem(npc.Model)
	end
	local baseValues = Knit.GetService("DataService"):GetProfile(npc.player).Data.Levels
	npc.BaseValues = {}
	for name, baseName in PartValues do
		-- local multName = PartValues[name]
		npc.BaseValues[name] = MultiplierUtil.getBaseMultForLevel(baseValues[baseName]) * npc.BaseMultiplier or 1
	end
	-- print("NPC base values:", npc.BaseValues)
	npc.Values = table.clone(baseValue)


	self.Thrown[npc] = {
		player = player,
		monitor = DistanceMonitor.new(npc.HRP),
		lastHit = os.clock(),
	}
end

function NPCThrownService:giveMult(model, mult)
	-- local npc = self:_getNpcFromModel(model)
	-- if not npc then
	-- return
	-- end

	-- npc.Value *= mult
	-- npc.Model:SetAttribute("Value", npc.Value)
end

function NPCThrownService:NpcEnterRing(model)
	-- local npc = self:_getNpcFromModel(model)
	-- if not npc then
	-- return
	-- end

	-- npc.Value += Constants.RING_VALUE
	-- npc.Model:SetAttribute("Value", npc.Value)
end

---------------------------------------------------------
-- INTERNAL
---------------------------------------------------------

function NPCThrownService:_getNpcFromModel(model)
	for npc in self.Thrown do
		if npc.Model == model then
			return npc
		end
	end
end

function NPCThrownService:_setupImpactSensors(npc)
	npc.Blackboard.LastHits = {}
	for partname, _use in PartValues do
		local part = npc.Model:FindFirstChild(partname)
		if not part then
			warn(partname, "not found in model")
			return
		end
		npc.Blackboard.LastHits[partname] = os.clock()
		npc._cleanup:Add(part.Touched:Connect(function(otherPart: BasePart)
			self:_handleCollision(npc, part, otherPart)
		end))
	end
end

function NPCThrownService:_handleCollision(npc, p1, otherPart)
	if otherPart:IsDescendantOf(npc.Model) or otherPart:GetAttribute("DontCollide") then
		return
	end
	if os.clock() - npc.Blackboard.LastHits[p1.Name] < Constants.COLLISION_DEBOUNCE then
		return
	end
	-- can collide
	local vel = npc.HRP.AssemblyLinearVelocity.Magnitude
	if vel < Constants.MIN_SPEED_FOR_MUTATION then
		return
	end
	npc.Blackboard.LastHits[p1.Name] = os.clock()
	-- print("NPC impact detected. Part:", p1.Name, "With:", otherPart.Name, "Velocity:", vel)
	MutationService:attemptTriggerMutation(npc, p1, vel)
end

function NPCThrownService:_update(dt)
	for npc, data in pairs(self.Thrown) do
		data.monitor:update(dt)

		if data.monitor.finished then
			self:_finishNPC(npc, data)
		end
	end
end

function NPCThrownService:_finishNPC(npc, data)
	if npc.State == NPCState.Finishing then
		return
	end
	npc.State = NPCState.Finishing

	local mult = MultiplierUtil.getMultiplierForPlayer(npc.player)
	local value = 0
	for name, partValue in npc.Values do
		-- local multName = PartValues[name]
		-- print("Part:", name, partMultiplier, "Level Mult Name:", multName, "Base Level:", baseValues[multName])
		-- value += MultiplierUtil.getBaseMultForLevel(baseValues[multName]) * partMultiplier
		value += partValue
	end

	local totalMoney = value * mult
	-- print("Awarding throw value:", value * mult)
	AwardService:AwardThrowMoney(data.player, totalMoney)
	Knit.GetService("GameAnalyticsService"):OnThrow(npc.player, npc, self.Thrown[npc].monitor.totalDistance, totalMoney)

	NPCZoneService:UnregisterNPC(npc)
	self.Client.NPCStopped:Fire(npc.player)
	self.Thrown[npc] = nil
	npc:Destroy()
end

--[[
	NPCZoneService
	--------------
	Manages NPC population per zone.

	Responsibilities:
	- Track desired NPC count per zone
	- Spawn NPCs when under target
	- Safely despawn idle NPCs when over target
	- Owns zone → NPC relationships

	Public API:
	- SetZonePopulation(zoneId, playerCount)
	- RegisterNPC(npc)
	- UnregisterNPC(npc)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Knit = require(ReplicatedStorage.Packages.Knit)

local Zones = require(ReplicatedStorage.Source.Shared.GameData.Zones)
local Constants = require(ReplicatedStorage.Source.Shared.Constants)
local NPCState = require(ReplicatedStorage.Source.Shared.NPCState)
local WeightedPicker = require(ReplicatedStorage.Source.Shared.Util.WeightedPicker)
local NPCTypes = require(ReplicatedStorage.Source.Shared.GameData.NPCTypes)

local NPCClass = require(script.Parent.Parent.Modules.NPC)

local NPCZoneService = Knit.CreateService({
	Name = "NPCZoneService",
})

---------------------------------------------------------
-- INTERNAL STATE
---------------------------------------------------------

-- [zoneId] = { npc }
NPCZoneService.ZoneNPCs = {}

-- [zoneId] = number
NPCZoneService.ZoneTargets = {}

-- [zoneId] = timestamp
NPCZoneService.LastSpawn = {}

local ZonesFolder = workspace.Zones
local DummyLoaderService, NPCInteractionService

local rng = Random.new(tick())

---------------------------------------------------------
-- LIFECYCLE
---------------------------------------------------------

function NPCZoneService:KnitInit()
	for _, zone in Zones do
		self.ZoneNPCs[zone.Id] = {}
		self.ZoneTargets[zone.Id] = 0
		self.LastSpawn[zone.Id] = 0
	end
end

function NPCZoneService:KnitStart()
	DummyLoaderService = Knit.GetService("DummyLoaderService")
	NPCInteractionService = Knit.GetService("NPCInteractionService")

	RunService.Heartbeat:Connect(function(dt)
		self:_updateZones()
		for _, npcs in ipairs(self.ZoneNPCs) do
			for _, npc in ipairs(npcs) do
				if npc.State == "Idle" and npc.HRP.Position.Y < 5 then
					self:UnregisterNPC(npc)
					npc:Destroy()
					break
				end
				npc:Update(dt)
			end
		end
	end)
end

---------------------------------------------------------
-- PUBLIC API
---------------------------------------------------------

-- Sets how many NPCs should exist in a zone
-- @param zoneId number
-- @param playerCount number
function NPCZoneService:SetZonePopulation(zoneId, playerCount)
	self.ZoneTargets[zoneId] = math.min(playerCount * Constants.NPC_PER_PLAYER, Constants.MAX_NPC_PER_ZONE)
end

-- Registers a newly created NPC
-- @param npc NPC
function NPCZoneService:RegisterNPC(npc)
	npc.Grabbed:Once(function(p)
		NPCInteractionService:GrabNPC(p, npc)
	end)
	table.insert(self.ZoneNPCs[npc.Zone], npc)
end

-- Removes an NPC from its zone
-- @param npc NPC
function NPCZoneService:UnregisterNPC(npc)
	local list = self.ZoneNPCs[npc.Zone]
	for i, v in ipairs(list) do
		if v == npc then
			table.remove(list, i)
			return
		end
	end
end

---------------------------------------------------------
-- INTERNAL
---------------------------------------------------------

function NPCZoneService:_updateZones()
	for zoneId, target in pairs(self.ZoneTargets) do
		local list = self.ZoneNPCs[zoneId]
		local count = #list

		if tick() - self.LastSpawn[zoneId] < Constants.SPAWN_INTERVAL then
			continue
		end

		if count < target then
			self.LastSpawn[zoneId] = tick()
			self:_spawnNPC(zoneId)
		elseif count > target then
			local npc = self:_getIdleNPC(zoneId)
			if npc then
				self.LastSpawn[zoneId] = tick()
				self:UnregisterNPC(npc)
				npc:Destroy()
			end
		end
	end
end

-- Only despawn NPCs that are safe to remove
function NPCZoneService:_getIdleNPC(zoneId)
	for _, npc in ipairs(self.ZoneNPCs[zoneId]) do
		if npc.State == NPCState.Idle then
			return npc
		end
	end
end

function NPCZoneService:_spawnNPC(zoneId)
	local zoneFolder = ZonesFolder:FindFirstChild("Zone" .. zoneId)
	if not zoneFolder then
		return
	end

	local spawners = zoneFolder:FindFirstChild("NpcSpawners")
	if not spawners then
		return
	end

	local spawn = spawners:GetChildren()[math.random(#spawners:GetChildren())]
	local dummy = DummyLoaderService:GetNextDummy(zoneId)
	dummy:PivotTo(spawn.CFrame)

	local dummyType = WeightedPicker.pickWeighted(NPCTypes, rng)
	local npc = NPCClass.new(dummy)
	npc.Zone = zoneId
	npc.State = NPCState.Idle
	npc.Type = dummyType.Id

	npc.BaseMultiplier = dummyType.Multiplier or 1

	if dummyType.Announce then
		print("New Friend spawned with " .. dummyType.Id .. " Mutation! Catch him first for extra rewards!")
	end

	self:RegisterNPC(npc)
	npc:Wander()
	task.defer(dummyType.Apply, dummy)
end
