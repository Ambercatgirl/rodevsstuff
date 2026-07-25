ambwuwu // thecatofalltime

--[[
	This script is pretty much the thing that carries my game and allows for ~25,000,000 blocks to be generated in the mine at a time (excluding air blocks).
]]

--!native
local EncodingService = game:GetService("EncodingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ChunkSize : number = 16

--Modules
local GenEnum = require(ReplicatedStorage.Gen.GenEnum).Enums
local GenerationUtility = require(ReplicatedStorage.Gen.GenerationUtility)
local CaveTypes = require(ReplicatedStorage.Modules.CaveTypes)
local Util = require(ReplicatedStorage.Modules.CaveTypes)

local ChunkParseService = {}
ChunkParseService.__index = ChunkParseService

local CompressionStates = {
	["Decompressed"] = 0;
	["Compressing"] = 1;
	["Decompressing"] = 2;
	["Compressed"] = 3;
}

function ChunkParseService.new()
	local NewChunk = {
		ActualOres = 0 :: number;
		OreCount = 0 :: number;
		OreList = {} :: {[number] : buffer|number};
		
		PlayersLoaded = 0 :: number;
		IsActive = true :: boolean;
		InactiveIn = 15 :: number;
		CompressionState = CompressionStates.Decompressed :: number;
		Waiting = CompressionStates.Decompressed;
		CompressedBuffer = nil :: buffer;
		
		ProcessingQueue = false;
		Queue = {};
	}
	
	return setmetatable(NewChunk,ChunkParseService)
end

export type ChunkParser = typeof(ChunkParseService.new())

--[[
	Removes all large data from a chunk
]]
function ChunkParseService.Clean(self : ChunkParser) : nil
	setmetatable(self,nil)
end

--[[
	Gets an ores coordinates inside of local chunk space instead of gloal space
]]
function ChunkParseService.GetLocalCoords(self : ChunkParser, X : number,Y : number,Z : number) : (number,number,number)
	return bit32.band(X,ChunkSize-1), bit32.band(Y,ChunkSize-1), bit32.band(Z,ChunkSize-1)
end

--[[
	Gets a unique position key for an ore in a chunk
]]
function ChunkParseService.GetOreKey(self : ChunkParser, X : number,Y : number,Z : number) : number
	X,Y,Z = self:GetLocalCoords(X/6,Y/6,Z/6)
	return bit32.bor(X, bit32.lshift(Y, 4), bit32.lshift(Z, 8))
end

--[[
	Returns the world coordinates from a local ore key
]]
function ChunkParseService.UnpackKey(self : ChunkParser, Key : number) : (number,number,number)
	local X : number = bit32.band(Key, ChunkSize-1)
	local Y : number = bit32.band(Key.rshift(Key, 5), ChunkSize-1)
	local Z : number = bit32.band(bit32.rshift(Key, 10), ChunkSize-1)
	return X,Y,Z
end

--[[
	Because chunks compress when inactive, I have to queue all actions that happened while it was decompressing and run them in order.
	Queueing an action will cause the thread to yield and this just unyields all the threads whenn a chunk finishes decompressing
]]
function ChunkParseService.ParseQueue(self : ChunkParser)
	if self.ProcessingQueue then
		return
	end
	
	self.ProcessingQueue = true
	
	local i = 1
	while i <= #self.Queue do
		coroutine.resume(self.Queue[i])
		i += 1
	end
	
	self.Queue = {}
	
	self.ProcessingQueue = false
end

--[[
	Queues an action to be run after a chunk has finished decompressing
]]
function ChunkParseService.QueueAction(self : ChunkParser)
	local Thread = coroutine.running()
	table.insert(self.Queue,Thread)
	
	self:DecompressBuffer()
	if self.CompressionState == CompressionStates.Decompressed then
		return
	end
	
	coroutine.yield()
end

--[[
	Compresses an ores data into a buffer and sets the ores unique key to the buffer
]]
function ChunkParseService.WriteOreData(self : ChunkParser, X : number, Y : number, Z : number, UpdateTable : {[string] : any})
	if self.CompressionState ~= CompressionStates.Decompressed then
		self:QueueAction()
	end
	
	self.InactiveIn = 15
	
	local OreKey : number = self:GetOreKey(X,Y,Z)
	
	local State : number = UpdateTable.Attributes and GenEnum.States.AttributeCreation or GenEnum.States.Create
	
	self.ActualOres += 1

	--This just calculates the size of the buffer thatll be made depending on if it has attributes or not
	local Size : number = GenerationUtility.GetComponentSize(State) + GenerationUtility.GetAttributesSize(UpdateTable.Attributes or {}) + 1
	local Buffer : buffer = buffer.create(Size)
	
	--This handles all the different values an ore can have (theres a set amount of important values and a variable amount of attribute values)
	GenerationUtility.CreateComponent(State,Buffer,0,UpdateTable)
	self.OreList[OreKey] = Buffer
	
	return true
end

--[[
	Returns the basic data about an ore
]]
function ChunkParseService.ParseBufferAt(self : ChunkParser, X : number,Y : number,Z : number) : nil|{}
	if self.CompressionState ~= CompressionStates.Decompressed then
		self:QueueAction()
	end
	
	self.InactiveIn = 15
	
	local OreKey : number = self:GetOreKey(X,Y,Z)
	local AtKey : number?|buffer? = self.OreList[OreKey]
	
	if typeof(AtKey) == "buffer" then
		local State : number = buffer.readu8(AtKey,0)

		--This will read all data for the given state and return it, it'll contain the Name, Position, Owner, Variant, Spawn Context, and Attributes
		return GenerationUtility.ReadComponent(State,AtKey,1)
	end
	
	return nil
end

--[[
	Removes an ore, marks it as air (air = 0)
]]
function ChunkParseService.RemoveOreAt(self : ChunkParser, X : number,Y : number,Z : number) : boolean
	if self.CompressionState ~= CompressionStates.Decompressed then
		self:QueueAction()
	end
	
	self.InactiveIn = 15
	
	local OreKey : number = self:GetOreKey(X,Y,Z)
	self.OreList[OreKey] = 0
	self.ActualOres -= 1
	
	return true
end

--[[
	Checks if a given position is air
]]
function ChunkParseService.IsAir(self : ChunkParser, X : number,Y : number,Z : number) : boolean
	if self.CompressionState ~= CompressionStates.Decompressed then
		self:QueueAction()
	end
	
	self.InactiveIn = 15
	
	return self.OreList[self:GetOreKey(X,Y,Z)] == 0
end

--[[
	Checks if a given position doesn't exist (not air, not a block)
]]
function ChunkParseService.IsNonexistant(self : ChunkParser, X : number,Y : number,Z : number) : boolean
	if self.CompressionState ~= CompressionStates.Decompressed then
		self:QueueAction()
	end
	
	self.InactiveIn = 15
	
	return self.OreList[self:GetOreKey(X,Y,Z)] == nil
end

--[[
	Returns if an ore exists at the given position
]]
function ChunkParseService.OreExistsAt(self : ChunkParser, X : number,Y : number,Z : number) : boolean
	if self.CompressionState ~= CompressionStates.Decompressed then
		self:QueueAction()
	end
	
	self.InactiveIn = 15
	
	return typeof(self.OreList[self:GetOreKey(X,Y,Z)]) == "buffer"
end

--[[
	Marks the location as air OR as special cave type air to make it possible to know if the player is standing inside of a cave
]]
function ChunkParseService.CreateAirAt(self : ChunkParser, X : number,Y : number,Z : number,Extra : number?) : boolean
	if self.CompressionState ~= CompressionStates.Decompressed then
		self:QueueAction()
	end
	
	self.InactiveIn = 15
	
	local OreKey : number = self:GetOreKey(X,Y,Z)
	
	if self.OreList[OreKey] == nil or type(self.OreList[OreKey]) == "number" then
		self.OreList[OreKey] = (Extra or 0)
	end
	
	return true
end

--[[
	Marks the location as nonexistant if the location was air
]]
function ChunkParseService.RemoveAirAt(self : ChunkParser, X : number,Y : number,Z : number) : boolean
	if self.CompressionState ~= CompressionStates.Decompressed then
		self:QueueAction()
	end
	
	self.InactiveIn = 15
	
	local OreKey : number = self:GetOreKey(X,Y,Z)
	local AtKey : number?|buffer? = self.OreList[OreKey]
	if typeof(AtKey) == "number" then
		self.OreList[OreKey] = nil
		return true
	end

	return false
end

--[[
	Returns every buffer in a chunk compressed into 1
]]
function ChunkParseService.GetChunkBuffers(self : ChunkParser) : buffer
	if self.CompressionState ~= CompressionStates.Decompressed then
		self:QueueAction()
	end
	
	self.InactiveIn = 15
	
	local ByteCount : number = 0
	local SavedSizes : {[number] : number} = {}

	--Combines all buffer sizes to create the full buffer
	for Key : number,Info : number|buffer in pairs(self.OreList) do
		if typeof(Info) == "number" then
			continue
		end

		local Len : number = buffer.len(Info)
		ByteCount += Len
		SavedSizes[Key] = Len
	end

	local OreBuffer : buffer = buffer.create(ByteCount)
	local Offset : number = 0

	--Copies all the buffer data based on its saved size from the previous loop
	for Key : number,Info : number|buffer in pairs(self.OreList) do
		if typeof(Info) == "number" then
			continue
		end

		buffer.copy(OreBuffer,Offset,Info,0,SavedSizes[Key])
		Offset += SavedSizes[Key]
	end

	return OreBuffer
end

--[[
	Takes an inactive chunk and compresses all of its data into 1 buffer, then uses encoding service to compress it even further to make long term storage of chunks more viable
]]
function ChunkParseService.CreateCompressedBuffer(self : ChunkParser) : buffer
	if self.Waiting == CompressionStates.Compressing or self.CompressionState == CompressionStates.Compressing or self.CompressionState == CompressionStates.Compressed then
		return
	end
	
	self.IsActive = false
	
	if self.CompressionState ~= CompressionStates.Decompressed then
		self.Waiting = CompressionStates.Compressing
		self:QueueAction()
		self.Waiting = CompressionStates.Decompressed
	end

	self.CompressionState = CompressionStates.Compressing
	local ByteCount : number = 0
	local SavedSizes = {} :: {[number] : number}

	--Same action as combining in the previous step but now also includes the number values as those need to be saved too
	for Key : number, Buffer : number|buffer in pairs(self.OreList) do
		local Size = 3
		if typeof(Buffer) == "number" then
			Size += 1
			SavedSizes[Key] = 1
		else
			local Len = buffer.len(Buffer)
			Size += Len
			SavedSizes[Key] = Len
		end
		
		ByteCount += Size
	end
	
	local ToCompress = buffer.create(ByteCount)
	local Offset : number = 0

	--Writes all the air and buffer values to the newly created buffer
	for Key : number, Value : number|buffer in pairs(self.OreList) do
		if typeof(Value) == "number" then
			buffer.writeu16(ToCompress,Offset,Key)
			Offset += 2
			buffer.writeu8(ToCompress,Offset,SavedSizes[Key])
			Offset += 1
			buffer.writei8(ToCompress,Offset,Value)
			Offset += 1
		else
			buffer.writeu16(ToCompress,Offset,Key)
			Offset += 2
			buffer.writeu8(ToCompress,Offset,SavedSizes[Key])
			Offset += 1
			
			buffer.copy(ToCompress,Offset,Value,0,SavedSizes[Key])
			Offset += SavedSizes[Key]
		end
		
		self.OreList[Key] = nil
	end

	--Uses encoding service to compress the buffer that was just created at the highest compression level
	local CompressedData = EncodingService:CompressBuffer(ToCompress,Enum.CompressionAlgorithm.Zstd,21)
	self.CompressedBuffer = CompressedData
	
	self.CompressionState = CompressionStates.Compressed
end

--[[
	Reconstructs the ore table with the correct buffers and air values given a previously compressed chunk buffer
]]
function ChunkParseService.DecompressBuffer(self : ChunkParser)
	if self.Waiting == CompressionStates.Decompressing or self.CompressionState == CompressionStates.Decompressing or self.CompressionState == CompressionStates.Decompressed then
		return
	end
	
	self.Waiting = CompressionStates.Decompressing
	while self.CompressionState == CompressionStates.Compressing do
		task.wait()
	end
	self.Waiting = CompressionStates.Decompressed
	
	self.CompressionState = CompressionStates.Decompressing
	local CompressedData = self.CompressedBuffer
	self.CompressedBuffer = nil

	local UncompressedData = EncodingService:DecompressBuffer(CompressedData,Enum.CompressionAlgorithm.Zstd)
	local ReOffset = 0
	local Size = buffer.len(UncompressedData)

	local Constructed = {}

	while ReOffset < Size do
		local Key = buffer.readu16(UncompressedData,ReOffset)
		ReOffset += 2

		local ValueSize = buffer.readu8(UncompressedData,ReOffset)
		ReOffset += 1

		--Actual ore data is usually 20+ bytes and can't possibly be 1 so its guaranteed to be an air block if the size is 1
		if ValueSize == 1 then
			local Value = buffer.readi8(UncompressedData,ReOffset)
			ReOffset += 1

			Constructed[Key] = Value
		else
			local NewBuffer = buffer.create(ValueSize)
			buffer.copy(NewBuffer,0,UncompressedData,ReOffset,ValueSize)
			ReOffset += ValueSize

			Constructed[Key] = NewBuffer
		end
	end
	
	self.OreList = Constructed

	--Unyields all the actions that were paused while the chunk was decompressing
	self:ParseQueue()
	
	self.IsActive = true
	self.InactiveIn = 15
	
	self.CompressionState = CompressionStates.Decompressed
end


return ChunkParseService
