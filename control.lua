--[[ Copyright (c) 2019 robot256 (MIT License)
 * Project: Multiple Unit Train Control
 * File: control.lua
 * Description: Runtime operation script for replacing locomotives and balancing fuel.
 * Functions:
 *  => On Train Created (any built, destroyed, coupled, or uncoupled rolling stock)
 *  ===> Check if forwards_locomotives and backwards_locomotives contain matching pairs
 *  =====> Replace them with MU locomotives, add to global list of MU pairs, reconnect train, etc.
 *  ===> Check if train contains existing MU pairs, and if those pairs are intact.
 *  =====> Replace any partial MU pairs with normal locomotives, remove from global list, reconnect trains
 *
 *  => On Mod Settings Changed (disabled flag changes to true)
 *  ===> Read through entire global list of MU pairs and replace them with normal locomotives
 
 *  => On Nth Tick (once per ~10 seconds)
 *  ===> Read through entire global list of MU pairs.  
 *  ===> Move among each pair if one has more of any item than the other.
 *
 --]]

require("util.saveItemRequestProxy")
require("util.saveGrid")
require("util.restoreGrid")
require("util.saveBurner")
require("util.restoreBurner")
require("util.replaceArtilleryWagon")

require("script.processTrainAutoFire")
require("script.processTrainManualFire")


------------------------- GLOBAL TABLE INITIALIZATION ---------------------------------------

-- Set up the mapping between normal and MU locomotives
-- Extract from the game prototypes list what MU locomotives are enabled
local function InitEntityMaps()

	global.upgrade_pairs = {}
	global.downgrade_pairs = {}
	
	-- Retrieve entity names from dummy technology, store in global variable
	for _,effect in pairs(game.technology_prototypes["smart-artillery-wagons-list"].effects) do
		if effect.type == "unlock-recipe" then
			local recipe = game.recipe_prototypes[effect.recipe]
			local std = recipe.products[1].name
			local auto = recipe.ingredients[1].name
			global.upgrade_pairs[std] = auto
			global.downgrade_pairs[auto] = std
			game.print("Registers SAW mapping "..std.." to "..auto)
		end
	end
	
end



------------------------- BLUEPRINT HANDLING ---------------------------------------
-- Finds the blueprint a player created and changes all MU locos to standard
local function purgeBlueprint(bp)
	-- Get Entity table from blueprint
	local entities = bp.get_blueprint_entities()
	-- Find any downgradable items and downgrade them
	if entities and next(entities) then
		for _,e in pairs(entities) do
			if global.downgrade_pairs[e.name] then
				e.name = global.downgrade_pairs[e.name]
			end
		end
		-- Write tables back to the blueprint
		bp.set_blueprint_entities(entities)
	end
	-- Find icons too
	local icons = bp.blueprint_icons
	if icons and next(icons) then
		for _,i in pairs(icons) do
			if i.signal.type == "item" then
				if global.downgrade_pairs[i.signal.name] then
					i.signal.name = global.downgrade_pairs[i.signal.name]
				end
			end
		end
		-- Write tables back to the blueprint
		bp.blueprint_icons = icons
	end
end


------------------------- WAGON REPLACEMENT CODE -------------------------------


-- Process replacement orders from the queue
--   Need to preserve mu_pairs across replacement
local function ProcessReplacementQueue()
	local idle = true
	
	if global.replacement_queue then
		while next(global.replacement_queue) do
			local r = table.remove(global.replacement_queue, 1)
			if r[1] and r[1].valid then
				-- Replace the wagon
				game.print("Smart Artillery is replacing ".. r[1].name .. "' with " .. r[2])
				--game.print({"debug-message.saw-replacement-message",r[1].name,r[1].backer_name,r[2]})
				
				replaceArtilleryWagon(r[1], r[2])
				
				idle = false  -- Tell OnTick that we did something useful
				break
			end
		end
	end
	
	return idle
end


-- Process up to one valid train from the queue per tick
--   The queue prevents us from processing another train until we finish with the first one.
--   That way we don't process "intermediate" trains created while replacing a locomotive by the script.
local function ProcessTrainQueue()
	local idle = true
	local replace_wagons = {}
	
	if global.trains_in_queue then
		--game.print("ProcessTrainQueue has a train in the queue")
		while next(global.trains_in_queue) do
			local t = table.remove(global.trains_in_queue,1)
			if t and t.valid then
				game.print("SAW processing train "..t.id)
				-- Check if the train is at a stop and the firing signal is present
				local auto_allowed = false
				if t.station and t.station.valid then
					-- We are at a station, check circuit conditions
					local signals = t.station.get_merged_signals()
					game.print("At valid station "..t.id)
					if signals then 
						game.print("with valid signal list "..t.id)
						for k,v in pairs(signals) do
							game.print("found signal. "..tostring(v.signal.name).." count="..tostring(v.count).." "..t.id)
							if v.signal.name == "smart-artillery-enable" then
								if v.count > 0 then
									auto_allowed = true
								end
								break
							end
						end
					end
				else
					game.print("Not at station "..t.id)
				end
				
				-- Replace artillery wagons according to signal
				if auto_allowed == true then
					replace_wagons = processTrainAutoFire(t)
				else
					replace_wagons = processTrainManualFire(t)
				end
				
				-- Add replacements to the replacement queue
				for _,entry in pairs(replace_wagons) do
					table.insert(global.replacement_queue,entry)
				end
				
				idle = false  -- Make sure OnTick stays enabled to process our queued replacements
				break  -- Only process one train per tick
			end
		end
		
	end
	
	return idle
end


----------------------------------------------
------ EVENT HANDLING ---

--== ONTICK EVENT ==--
-- Process items queued up by other actions
-- Only one action allowed per tick
local function OnTick(event)
	local idle = true
	
	-- Replacing Locomotives has first priority
	idle = ProcessReplacementQueue()
	
	-- Processing new Trains has second priority
	if idle then
		idle = ProcessTrainQueue()
	end
	
	
	if idle or ((not next(global.replacement_queue)) and 
	            (not next(global.trains_in_queue))) then
		-- All three queues are empty, unsubscribe from OnTick to save UPS
		--game.print("Turning off OnTick")
		script.on_event(defines.events.on_tick, nil)
	end
	
end

--== ON_TRAIN_CREATED EVENT ==--
-- Record every new train in global queue, so we can process them one at a time.
--   Many of these events will be triggered by our own replacements, and those
--   "intermediate" trains will be invalid by the time we pull them from the queue.
--   This is the desired behavior. 
local function OnTrainCreated(event)
	-- Event contains train, old_train_id_1, old_train_id_2
	
	-- These are a hack to make sure our global variables get created.
	if not global.trains_in_queue then
		global.trains_in_queue = {}
	end
	if not global.replacement_queue then
		global.replacement_queue = {}
	end
	
	
	-- Add this train to the train processing queue
	table.insert(global.trains_in_queue,event.train)
	
	--game.print("Train " .. event.train.id .. " queued.")
	
	-- Set up the on_tick action to process trains
	script.on_event(defines.events.on_tick, OnTick)
	
end

--== ON_TRAIN_CHANGED_STATE EVENT ==--
-- Every time a train arrives or leaves a station, check if we need to replace wagons. 
local function OnTrainChangedState(event)
	-- Event contains train, old_state
	
	if not global.trains_in_queue then
		global.trains_in_queue = {}
	end
	if not global.replacement_queue then
		global.replacement_queue = {}
	end
	
	--game.print("old_state = "..tostring(event.old_state)..", new_state = "..tostring(event.train.state))
	
	--if (event.train.state == defines.train_state.wait_station) or 
	--   (old_state == defines.train_state.wait_station) then
	    
		-- We either just arrived or just left a station
		-- Add this train to the train processing queue
		table.insert(global.trains_in_queue,event.train)
		
		--game.print("Train " .. event.train.id .. " queued.")
		
		-- Set up the on_tick action to process trains
		script.on_event(defines.events.on_tick, OnTick)
	--end

end


--== ON_PLAYER_CONFIGURED_BLUEPRINT EVENT ==--
-- ID 70, fires when you select a blueprint to place
--== ON_PLAYER_SETUP_BLUEPRINT EVENT ==--
-- ID 68, fires when you select an area to make a blueprint or copy
local function OnPlayerSetupBlueprint(event)
	--game.print("MU Control handling Blueprint from ".. event.name .." event.")
	
	-- Get Blueprint from player (LuaItemStack object)
	-- If this is a Copy operation, BP is in cursor_stack
	-- If this is a Blueprint operation, BP is in blueprint_to_setup
	-- Need to use "valid_for_read" because "valid" returns true for empty LuaItemStack
	
	local item1 = game.get_player(event.player_index).blueprint_to_setup
	local item2 = game.get_player(event.player_index).cursor_stack
	if item1 and item1.valid_for_read==true then
		purgeBlueprint(item1)
	elseif item2 and item2.valid_for_read==true and item2.is_blueprint==true then
		purgeBlueprint(item2)
	end
end


--== ON_PLAYER_PIPETTE ==--
-- Fires when player presses 'Q'.  We need to sneakily grab the correct item from inventory if it exists,
--  or sneakily give the correct item in cheat mode.
local function OnPlayerPipette(event)
	--game.print("MUTC: OnPlayerPipette, cheat mode="..tostring(event.used_cheat_mode))
	local item = event.item
	if item and item.valid then
		--game.print("item: " .. item.name)
		if global.downgrade_pairs[item.name] then
			local player = game.players[event.player_index]
			local newName = global.downgrade_pairs[item.name]
			local cursor = player.cursor_stack
			local inventory = player.get_main_inventory()
			-- Check if the player got MU versions from inventory, and convert them
			if cursor.valid_for_read == true and event.used_cheat_mode == false then
				-- Huh, he actually had MU items.
				--game.print("Converting cursor to "..newName)
				cursor.set_stack({name=newName,count=cursor.count})
			else
				-- Check if the player could have gotten the right thing from inventory/cheat, otherwise clear the cursor
				--game.print("Looking for " .. newName .. " in inventory")
				local newItemStack = inventory.find_item_stack(newName)
				cursor.set_stack(newItemStack)
				if not cursor.valid_for_read then
					--game.print("Not found!")
					if player.cheat_mode==true then
						--game.print("Giving free " .. newName)
						cursor.set_stack({name=newName, count=game.item_prototypes[newName].stack_size})
					end
				else
					--game.print("Found!")
					inventory.remove(newItemStack)
				end
			end
		end
	end


end


-----------
-- Queues all existing trains for updating with new settings
local function QueueAllTrains()
	if not global.replacement_queue then
		global.replacement_queue = {}
	end
	for _, surface in pairs(game.surfaces) do
		local trains = surface.get_trains()
		for _,train in pairs(trains) do
			table.insert(global.trains_in_queue,train)
		end
	end
	script.on_event(defines.events.on_tick, OnTick)
end

---- Bootstrap ----
do
local function init_events()

	-- Subscribe to Blueprint activity always
	script.on_event({defines.events.on_player_setup_blueprint,defines.events.on_player_configured_blueprint}, OnPlayerSetupBlueprint)
	script.on_event(defines.events.on_player_pipette, OnPlayerPipette)

	-- Subscribe to On_Train_Created according to mod enabled setting
	--script.on_event(defines.events.on_train_created, OnTrainCreated)
	script.on_event(defines.events.on_train_changed_state, OnTrainChangedState)
	
	-- Set conditional OnTick event handler correctly on load based on global queues, so we can sync with a multiplayer game.
	if (global.trains_in_queue and next(global.trains_in_queue)) or
	      (global.replacement_queue and next(global.replacement_queue)) then
		script.on_event(defines.events.on_tick, OnTick)
	end
	
end



script.on_load(function()
	init_events()
end)

script.on_init(function()
	--game.print("In on_init!")
	global.replacement_queue = {}
	global.trains_in_queue = {}
	InitEntityMaps()
	init_events()
	
end)

script.on_configuration_changed(function(data)
	--game.print("In on_configuration_changed!")
	global.replacement_queue = global.replacement_queue or {}
	global.trains_in_queue = global.trains_in_queue or {}
	InitEntityMaps()
	-- On config change, scrub the list of trains
	QueueAllTrains()
	init_events()

end)
end
