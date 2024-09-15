--If you think this code is disgusting. I agree.
--I'm unfamiliar with the camera and most of this was copied from ingamewaitingforrespawn.lua (aka custody), and modified enough to work.

local function setup_class(class, id)
	Hooks:PostHook(class, "init", "init_downed_spectate_" .. id, function(self, game_state_machine)
		self._slotmask = managers.slot:get_mask("world_geometry") + 39
		self._fwd = Vector3(1, 0, 0)
		self._rot = Rotation()
		self._vec_target = Vector3()
		self._vec_eye = Vector3()
		self._vec_dir = Vector3()
	end)

	function class:_setup_controller()
		if self._spectate_controller then
			self:_clear_controller()
		end

		self._spectate_controller = managers.controller:create_controller("downed_spectate", managers.controller:get_default_wrapper_index(), false)
		self._next_player_cb = callback(self, self, "cb_next_player")
		self._prev_player_cb = callback(self, self, "cb_prev_player")
		local next_btn = "right"
		local prev_btn = "left"

		if _G.IS_VR then
			next_btn = "suvcam_next"
			prev_btn = "suvcam_prev"
		end

		DelayedCalls:Add("downed_spectate", 0.01, function() 
			--Seems to get triggered when holding left or right click while getting put into fatal state
			--Simple solution? Add a delayed call
			self._spectate_controller:add_trigger(prev_btn, self._prev_player_cb)
			self._spectate_controller:add_trigger(next_btn, self._next_player_cb)

			if not _G.IS_VR then
				self._spectate_controller:add_trigger("primary_attack", self._prev_player_cb)
				self._spectate_controller:add_trigger("secondary_attack", self._next_player_cb)
			end

			self._spectate_controller:set_enabled(true)
			managers.controller:set_ingame_mode("main")
		end)
	end

	function class:_clear_controller()
		if self._spectate_controller then
			self._spectate_controller:remove_trigger("left", self._prev_player_cb)
			self._spectate_controller:remove_trigger("right", self._next_player_cb)
			self._spectate_controller:remove_trigger("primary_attack", self._prev_player_cb)
			self._spectate_controller:remove_trigger("secondary_attack", self._next_player_cb)
			self._spectate_controller:set_enabled(false)
			self._spectate_controller:destroy()

			self._spectate_controller = nil
		end
	end

	function class:_setup_camera()
		self:_clear_camera()

		self._camera_object = World:create_camera()

		self._camera_object:set_near_range(3)
		self._camera_object:set_far_range(1000000)
		self._camera_object:set_fov(75)

		if _G.IS_VR then
			self._camera_object:set_aspect_ratio(1.7777777777777777)
			self._camera_object:set_stereo(false)
			managers.menu:set_override_ingame_camera(self._camera_object)
		else
			self._viewport = managers.viewport:new_vp(0, 0, 1, 1, "spectator", CoreManagerBase.PRIO_WORLDCAMERA)

			self._viewport:set_camera(self._camera_object)
			self._viewport:set_active(true)
		end
	end

	function class:camera_exists()
		return self._viewport and self._camera_object
	end

	function class:_clear_camera()
		if alive(self._viewport) then
			self._viewport:set_active(false)
			self._viewport:destroy()

			self._viewport = nil
		end

		if alive(self._camera_object) then
			self._camera_object:set_visibility(false)
			World:delete_camera(self._camera_object)

			self._camera_object = nil
		end

		if _G.IS_VR then
			managers.menu:set_override_ingame_camera(nil)
		end
	end

	function class:_create_spectator_data()
		local all_teammates = managers.groupai:state():all_char_criminals()
		local teammate_list = {}

		for u_key, u_data in pairs(all_teammates) do
			table.insert(teammate_list, u_key)
		end

		self._spectator_data = {
			teammate_records = all_teammates,
			teammate_list = teammate_list,
			watch_u_key = teammate_list[1]
		}
	end

	function class:_refresh_teammate_list()
		local all_teammates = self._spectator_data.teammate_records
		local teammate_list = self._spectator_data.teammate_list
		local lost_teammate_at_i = nil
		local i = #teammate_list

		while i > 0 do
			local u_key = teammate_list[i]
			local teammate_data = all_teammates[u_key]

			if not teammate_data then
				table.remove(teammate_list, i)

				if u_key == self._spectator_data.watch_u_key then
					lost_teammate_at_i = i
					self._spectator_data.watch_u_key = nil
				end
			end

			i = i - 1
		end

		if #teammate_list ~= table.size(all_teammates) then
			for u_key, u_data in pairs(all_teammates) do
				local add = true

				for i_key, test_u_key in ipairs(teammate_list) do
					if test_u_key == u_key then
						add = false

						break
					end
				end

				if add then
					table.insert(teammate_list, u_key)
				end
			end
		end

		if lost_teammate_at_i then
			self._spectator_data.watch_u_key = teammate_list[math.clamp(lost_teammate_at_i, 1, #teammate_list)]
		end

		if not self._spectator_data.watch_u_key and #teammate_list > 0 then
			self._spectator_data.watch_u_key = teammate_list[1]
		end
	end

	function class:watch_priority_character()
		self:_refresh_teammate_list()

		local function try_watch_unit(unit_key)
			if table.contains(self._spectator_data.teammate_list, unit_key) then
				self._spectator_data.watch_u_key = unit_key
				self._dis_curr = nil

				return true
			end
		end

		if Network:is_client() then
			local peer = managers.network:session():server_peer()
			local unit = peer and peer:unit()

			if unit and try_watch_unit(unit:key()) then
				return
			end
		end

		for u_key, _ in pairs(managers.groupai:state():all_player_criminals()) do
			if try_watch_unit(u_key) then
				return
			end
		end

		self._spectator_data.watch_u_key = self._spectator_data.teammate_list[1]
		self._dis_curr = nil
	end

	function class:_get_teammate_index_by_unit_key(u_key)
		for i_key, test_u_key in ipairs(self._spectator_data.teammate_list) do
			if test_u_key == u_key then
				return i_key
			end
		end
	end

	function class:cb_next_player()
		self:_refresh_teammate_list()

		local watch_u_key = self._spectator_data.watch_u_key

		if not watch_u_key then
			return
		end

		local i_watch = self:_get_teammate_index_by_unit_key(watch_u_key)
		i_watch = i_watch == #self._spectator_data.teammate_list and 1 or i_watch + 1
		watch_u_key = self._spectator_data.teammate_list[i_watch]
		self._spectator_data.watch_u_key = watch_u_key
		self._dis_curr = nil

		if not self:camera_exists() then
			self:_setup_camera()
		end
	end

	function class:cb_prev_player()
		self:_refresh_teammate_list()

		local watch_u_key = self._spectator_data.watch_u_key

		if not watch_u_key then
			return
		end

		local i_watch = self:_get_teammate_index_by_unit_key(watch_u_key)
		i_watch = i_watch == 1 and #self._spectator_data.teammate_list or i_watch - 1
		watch_u_key = self._spectator_data.teammate_list[i_watch]
		self._spectator_data.watch_u_key = watch_u_key
		self._dis_curr = nil

		if not self:camera_exists() then
			self:_setup_camera()
		end
	end

	function class:_get_local_player_by_unit(unit)
		for i, v in ipairs(self._spectator_data.teammate_records) do
			if v.unit == unit then
				return i
			end
		end
	end

	function class:reviving()
		local hud = managers.hud:script(PlayerBase.PLAYER_DOWNED_HUD)
		local reviving = hud.paused

		if reviving then
			self:_clear_controller()
			self:_clear_camera()
			self._spectator_data.watch_u_key = self:_get_local_player_by_unit(managers.player:local_player())
			return true
		end

		if not self._spectate_controller then
			self:_setup_controller()
		end

		return false
	end

	local mvec3_set = mvector3.set
	local mvec3_add = mvector3.add
	local mvec3_subtract = mvector3.subtract
	local mvec3_multiply = mvector3.multiply
	local mvec3_negate = mvector3.negate
	local mvec3_rotate_with = mvector3.rotate_with
	local mvec3_x = mvector3.x
	local mvec3_y = mvector3.y
	local mvec3_normalize = mvector3.normalize
	local mvec3_length = mvector3.length
	local mvec3_cross = mvector3.cross
	local mvec3_angle = mvector3.angle
	local mrot_set_axis_angle = mrotation.set_axis_angle
	local mrot_set_look_at = mrotation.set_look_at
	local math_up = math.UP

	Hooks:PostHook(class, "update", "update_downed_spectate_" .. id, function(self, t, dt)
		if not self:camera_exists() then
			return --Yes we could try creating the camera again, but if it fucked up while creating it. Creating it again probs wouldn't have an effect
		end

		if self:reviving() then
			return
		end

		self:_refresh_teammate_list()

		if self._spectator_data.watch_u_key then
			local watch_u_record = self._spectator_data.teammate_records[self._spectator_data.watch_u_key]
			local watch_u_head = watch_u_record.unit:movement():get_object(Idstring("Head"))

			if not watch_u_head then
				if watch_u_record.unit == managers.player:local_player() then --Just to make sure
					self:_clear_camera()
				else
					self._next_player_cb()
				end

				return
			end

			mvec3_set(self._vec_dir, self._spectate_controller:get_input_axis("look"))

			if _G.IS_VR then
				mvec3_set(self._vec_dir, self._spectate_controller:get_input_axis("touchpad_primary"))
			end

			local controller_type = self._spectate_controller:get_default_controller_id()
			local stick_input_x = mvec3_x(self._vec_dir)

			if mvec3_length(self._vec_dir) > 0.1 then
				if controller_type ~= "keyboard" then
					stick_input_x = stick_input_x / (1.3 - 0.3 * (1 - math.abs(mvec3_y(self._vec_dir))))
					stick_input_x = stick_input_x * dt * 180
				end

				mrot_set_axis_angle(self._rot, math_up, -0.5 * stick_input_x)
				mvec3_rotate_with(self._fwd, self._rot)
				mvec3_cross(self._vec_target, math_up, self._fwd)
				mrot_set_axis_angle(self._rot, self._vec_target, 0.5 * -mvec3_y(self._vec_dir))
				mvec3_rotate_with(self._fwd, self._rot)

				local angle = mvec3_angle(math_up, self._fwd)
				local rot = 0

				if angle > 145 then
					rot = 145 - angle
				elseif angle < 85 then
					rot = 85 - angle
				end

				if rot ~= 0 then
					mrot_set_axis_angle(self._rot, self._vec_target, rot)
					mvec3_rotate_with(self._fwd, self._rot)
				end
			end

			local vehicle_unit, vehicle_seat

			if managers.network and managers.network:session() and watch_u_record.unit:network() then
				if watch_u_record.unit:brain() then
					vehicle_unit = watch_u_record.unit:movement().vehicle_unit
					vehicle_seat = watch_u_record.unit:movement().vehicle_seat
				elseif watch_u_record.unit:network():peer() then
					local peer_id = watch_u_record.unit:network():peer():id()
					local vehicle_data = managers.player:get_vehicle_for_peer(peer_id)

					if vehicle_data then
						vehicle_unit = vehicle_data.vehicle_unit
						vehicle_seat = vehicle_unit:vehicle_driving()._seats[vehicle_data.seat]
					end
				end
			end

			if vehicle_unit and vehicle_seat then
				local target_pos = vehicle_unit:vehicle():object_position(vehicle_seat.object)

				mvec3_set(self._vec_target, target_pos)

				local spectate_object = vehicle_unit:vehicle_driving() and vehicle_unit:vehicle_driving().spectate_object and vehicle_unit:get_object(Idstring(vehicle_unit:vehicle_driving().spectate_object)) or vehicle_unit
				local oobb = spectate_object:oobb()
				local z_offset = vehicle_unit:vehicle_driving() and vehicle_unit:vehicle_driving().spectate_offset or 2.5
				local up = oobb:z() * z_offset

				mvec3_add(self._vec_target, up)
			else
				watch_u_head:m_position(self._vec_target)
			end

			mvec3_set(self._vec_eye, self._fwd)
			mvec3_multiply(self._vec_eye, 150)
			mvec3_negate(self._vec_eye)
			mvec3_add(self._vec_eye, self._vec_target)
			mrot_set_look_at(self._rot, self._fwd, math_up)

			local col_ray = World:raycast("ray", self._vec_target, self._vec_eye, "slot_mask", self._slotmask)
			local dis_new = nil

			if col_ray then
				mvec3_set(self._vec_dir, col_ray.ray)

				dis_new = math.max(col_ray.distance - 30, 0)
			else
				mvec3_set(self._vec_dir, self._vec_eye)
				mvec3_subtract(self._vec_dir, self._vec_target)

				dis_new = mvec3_normalize(self._vec_dir)
			end

			if self._dis_curr and self._dis_curr < dis_new then
				local speed = math.max((dis_new - self._dis_curr) / 5, 1.5)
				self._dis_curr = math.lerp(self._dis_curr, dis_new, speed * dt)
			else
				self._dis_curr = dis_new
			end

			mvec3_set(self._vec_eye, self._vec_dir)
			mvec3_multiply(self._vec_eye, self._dis_curr)
			mvec3_add(self._vec_eye, self._vec_target)
			self._camera_object:set_position(self._vec_eye)
			self._camera_object:set_rotation(self._rot)
		end
	end)

	Hooks:PostHook(class, "at_enter", "enter_downed_spectate_" .. id, function(self)
		self:_setup_controller()
		self:_create_spectator_data()
		self:watch_priority_character()
	end)


	Hooks:PostHook(class, "at_exit", "exit_downed_spectate_" .. id, function(self)
		self:_clear_controller()
		self:_clear_camera()
	end)
end

if RequiredScript == "lib/states/ingameincapacitated" then
    setup_class(IngameIncapacitatedState, "IngameIncapacitatedState")
elseif RequiredScript == "lib/states/ingamefatalstate" then
	setup_class(IngameFatalState, "IngameFatalState")
end