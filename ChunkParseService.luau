ambwuwu // thecatofalltime
now with more comments ig
im not gonna make the same comment for lines that do the exact thing as a previous comment (like queueing actions or the inactive timer)

--[[
	This script is pretty much the thing that carries my game and allows for ~25,000,000 blocks to be generated in the mine at a time (excluding air blocks).
	Any time you interact with a block this code is being run, any time you load a new chunk this code is being run, and any time you leave unloaded chunks for long enough this code is being run.
]]

--native code generation is good for buffers  and this module is lots of buffers so i use native
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

--all the states that a chunk can have relating to compression
local CompressionStates = {
	["Decompressed"] = 0;
	["Compressing"] = 1;
	["Decompressing"] = 2;
	["Compressed"] = 3;
}

function ChunkParseService.new()
	--create table with necessary data to perform chunk actions
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

	--use metatable for oop, indexes ChunkParseService when table index is nil
	return setmetatable(NewChunk,ChunkParseService)
end

export type ChunkParser = typeof(ChunkParseService.new())

--[[
	Removes all large data from a chunk
]]
function ChunkParseService.Clean(self : ChunkParser) : nil
	--remove metatable because the chunk is no longer needed
	setmetatable(self,nil)
end

--[[
	Gets an ores coordinates inside of local chunk space instead of gloal space
]]
function ChunkParseService.GetLocalCoords(self : ChunkParser, X : number,Y : number,Z : number) : (number,number,number)
	--bit math to turn a world position (any vector between like -2.1b and 2.1b) into a local coordinate within this chunk (16x16x16 grid area)
	return bit32.band(X,ChunkSize-1), bit32.band(Y,ChunkSize-1), bit32.band(Z,ChunkSize-1)
end

--[[
	Gets a unique position key for an ore in a chunk
]]
function ChunkParseService.GetOreKey(self : ChunkParser, X : number,Y : number,Z : number) : number
	--coordinates divided by 6 because thats the normal grid size and its easier to work with 1,2,3... instead of 6,12,18...
	X,Y,Z = self:GetLocalCoords(X/6,Y/6,Z/6)
	--more bit math to turn the local x,y,z into a unique number key within the chunk
	return bit32.bor(X, bit32.lshift(Y, 4), bit32.lshift(Z, 8))
end

--[[
	Returns the world coordinates from a local ore key
]]
function ChunkParseService.UnpackKey(self : ChunkParser, Key : number) : (number,number,number)
	--more bit math to undo previous bit operations and get the original world coordinates for a ores key
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
	--dont process the queue twice itd probable implode
	if self.ProcessingQueue then
		return
	end

	--mark processing so it wont run twice
	self.ProcessingQueue = true

	--resume all paused threads that were waiting for the chunk to decompress
	local i = 1
	while i <= #self.Queue do
		coroutine.resume(self.Queue[i])
		i += 1
	end

	--reset queue and mark not processing so that when the chunk goes inactive and decompresses it can go through this step again
	self.Queue = {}
	self.ProcessingQueue = false
end

--[[
	Queues an action to be run after a chunk has finished decompressing
]]
function ChunkParseService.QueueAction(self : ChunkParser)
	--get current thread and insert it into the queue
	local Thread = coroutine.running()
	table.insert(self.Queue,Thread)

	--attempt to decompress the chunk, return early if this is the call that decompressed it because the thread wouldnt need to yield for the queue
	self:DecompressBuffer()
	if self.CompressionState == CompressionStates.Decompressed then
		return
	end

	--yield thread so that the action isnt lost if the chunk is decompressing and also allows for the actions to still happen in order when unyielded
	coroutine.yield()
end

--[[
	Compresses an ores data into a buffer and sets the ores unique key to the buffer
]]
function ChunkParseService.WriteOreData(self : ChunkParser, X : number, Y : number, Z : number, UpdateTable : {[string] : any})
	--queue this action for later if the chunk is compressed
	if self.CompressionState ~= CompressionStates.Decompressed then
		self:QueueAction()
	end

	--reset active timer because an action happened in the chunk
	self.InactiveIn = 15

	--get ore key and state of the update table that is being written, different states because one expects a # of attributes int and one doesnt and i save 1 byte of data in network traffic and storage if i remove that 1 byte
	local OreKey : number = self:GetOreKey(X,Y,Z)
	local State : number = UpdateTable.Attributes and GenEnum.States.AttributeCreation or GenEnum.States.Create

	--increment ores in chunk
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

	--check the index in the orelist corresponding to the ores key and check if it is air, lowkey writing this comment i realize it should be typeof(...) == "number" because i added cave type air but it works so... does it realllllly matter... (yes)
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

	--check the index in the orelist corresponding to the ores key and check if it is nil (nothing exists there)
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

	--check the index in the orelist corresponding to the ores key and check if it is a buffer (contains ore data, meaning an ore exists there)
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

	--check if the index in the orelist is nil or already air, its fine if a new air value overrides a previous air value so it doesnt only check if its nil
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
	--if the index in the ore list is a number then it is air and can be removed, returns true if removed and false if there was a buffer or nothing at the index
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

	--Combines all buffer sizes to create the full buffer, skip  air because that is unimportant data for the client (this is only used for chunk loading and air blocks dont exist)
	for Key : number,Info : number|buffer in pairs(self.OreList) do
		--skip air
		if typeof(Info) == "number" then
			continue
		end

		--get length of the buffer at the index, increase the total byte count, save the size of this buffer
		local Len : number = buffer.len(Info)
		ByteCount += Len
		SavedSizes[Key] = Len
	end

	--create buffer  with the previously calculated bytecount that will be the perfect size for all the  data
	local OreBuffer : buffer = buffer.create(ByteCount)
	local Offset : number = 0

	for Key : number,Info : number|buffer in pairs(self.OreList) do
		if typeof(Info) == "number" then
			continue
		end

		--run copy operation on the new buffer based on the saved size to perfectly copy all of its contents, increase offset by saved size so that the next operation happens  at the end of this operation
		buffer.copy(OreBuffer,Offset,Info,0,SavedSizes[Key])
		Offset += SavedSizes[Key]
	end

	return OreBuffer
end

--[[
	Takes an inactive chunk and compresses all of its data into 1 buffer, then uses encoding service to compress it even further to make long term storage of chunks more viable
]]
function ChunkParseService.CreateCompressedBuffer(self : ChunkParser) : buffer
	--dont compress if its already compressing, waiting to compress, or already compressed
	if self.Waiting == CompressionStates.Compressing or self.CompressionState == CompressionStates.Compressing or self.CompressionState == CompressionStates.Compressed then
		return
	end

	--mark inactive
	self.IsActive = false

	--if the chunk isnt already decompressed, then it can only be decompressing, and this action should be queued until after that happens (will yield the thread if you remember the coroutine.yield() from before)
	--THIS LINE SHOULDNT RUN UNLESS IT TAKES LIKE 15+ SECONDS TO DECOMPRESS WHICH IS IMPOSSIBLE I THINK BUT JUUUST IN CASE SOMETHING GOES TERRIBLY WRONG ITS HERE
	if self.CompressionState ~= CompressionStates.Decompressed then
		self.Waiting = CompressionStates.Compressing
		self:QueueAction()
		self.Waiting = CompressionStates.Decompressed
	end

	--mark chunk as compressing
	self.CompressionState = CompressionStates.Compressing
	local ByteCount : number = 0
	local SavedSizes = {} :: {[number] : number}

	--Same action as combining in the previous step but now also includes the number values as those need to be saved too
	for Key : number, Buffer : number|buffer in pairs(self.OreList) do
		--default size is 3, 2 bytes for the key and 1 byte for the length of the buffer
		local Size = 3
		if typeof(Buffer) == "number" then
			--add 1 byte to size to write the type of air, only uses an 8 bit int so the size of the key will only be 1
			Size += 1
			SavedSizes[Key] = 1
		else
			--add the length of the buffer to the size
			local Len = buffer.len(Buffer)
			Size += Len
			SavedSizes[Key] = Len
		end

		--increase total byte count by size of this index
		ByteCount += Size
	end

	--create new buffer based on the total  byte count
	local ToCompress = buffer.create(ByteCount)
	local Offset : number = 0

	--Writes all the air and buffer values to the newly created buffer
	for Key : number, Value : number|buffer in pairs(self.OreList) do
		if typeof(Value) == "number" then
			--write the key, size, and air value to the buffer
			buffer.writeu16(ToCompress,Offset,Key)
			Offset += 2
			buffer.writeu8(ToCompress,Offset,SavedSizes[Key])
			Offset += 1
			buffer.writei8(ToCompress,Offset,Value)
			Offset += 1
		else
			--write the key, size, and then copy the buffer data
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
	--this step usually reduces the memory usage of the chunks ore data by 3x, up to 10x depending on how many ores exist in the chunk, its best for larger chunks, this decrease is Huge for a game that is meant to have 20 million ores existing at once
	local CompressedData = EncodingService:CompressBuffer(ToCompress,Enum.CompressionAlgorithm.Zstd,21)
	self.CompressedBuffer = CompressedData

	--mark chunk as compressed
	self.CompressionState = CompressionStates.Compressed
end

--[[
	Reconstructs the ore table with the correct buffers and air values given a previously compressed chunk buffer
]]
function ChunkParseService.DecompressBuffer(self : ChunkParser)
	--return if its waiting to decompress,  already decompressing, or already decompresed
	if self.Waiting == CompressionStates.Decompressing or self.CompressionState == CompressionStates.Decompressing or self.CompressionState == CompressionStates.Decompressed then
		return
	end

	--mark as waiting to decompress until it finishes compressing if it is already compressing
	self.Waiting = CompressionStates.Decompressing
	while self.CompressionState == CompressionStates.Compressing do
		task.wait()
	end
	self.Waiting = CompressionStates.Decompressed

	--mark as decompressing, get the compressed buffer from the chunk and remove it from the permanent data
	self.CompressionState = CompressionStates.Decompressing
	local CompressedData = self.CompressedBuffer
	self.CompressedBuffer = nil

	--decompress the original buffer, prepare size for an offset loop
	local UncompressedData = EncodingService:DecompressBuffer(CompressedData,Enum.CompressionAlgorithm.Zstd)
	local ReOffset = 0
	local Size = buffer.len(UncompressedData)

	local Constructed = {}

	--since offset is the index at which data will be read/written in a buffer, you can run loops while its < the size of the buffer to iterate over every value in a buffer as long as you properly increment the offset value
	while ReOffset < Size do
		--read key from buffer
		local Key = buffer.readu16(UncompressedData,ReOffset)
		ReOffset += 2

		--read value size from buffer
		local ValueSize = buffer.readu8(UncompressedData,ReOffset)
		ReOffset += 1

		--Actual ore data is usually 20+ bytes and can't possibly be 1 so its guaranteed to be an air block if the size is 1
		if ValueSize == 1 then
			--read air value from  buffer
			local Value = buffer.readi8(UncompressedData,ReOffset)
			ReOffset += 1

			--add air value to key in reconstructed orelist table
			Constructed[Key] = Value
		else
			--create new buffer with the size value, copy from offset to offset+size from decompressed data to new buffer
			local NewBuffer = buffer.create(ValueSize)
			buffer.copy(NewBuffer,0,UncompressedData,ReOffset,ValueSize)
			ReOffset += ValueSize

			--add buffer value to key in reconstructed orelist table
			Constructed[Key] = NewBuffer
		end
	end

	--add orelist back to the chunk
	self.OreList = Constructed

	--Unyields all the actions that were paused while the chunk was decompressing
	self:ParseQueue()

	--mark chunk as active again
	self.IsActive = true
	self.InactiveIn = 15

	--mark chunk  as decompressed
	self.CompressionState = CompressionStates.Decompressed
end


return ChunkParseService
