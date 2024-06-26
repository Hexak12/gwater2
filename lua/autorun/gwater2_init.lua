AddCSLuaFile()

if SERVER then 
	-- swimming code
	local gravity_convar = GetConVar("sv_gravity")
	local function in_water(ply) 
		return ply.GWATER2_CONTACTS and ply.GWATER2_CONTACTS > 50
	end

	-- swim code provided by kodya
	hook.Add("CalcMainActivity", "gwater2_water_swimming", function(ply)
		if !in_water(ply) or ply:InVehicle() then return end
		return ACT_MP_SWIM, -1
	end)

	hook.Add("Move", "gwater2_water_swimming", function(ply, move)
		if !in_water(ply) then return end

		local vel = move:GetVelocity()
		local ang = move:GetMoveAngles()

		local acel =
		(ang:Forward() * move:GetForwardSpeed()) +
		(ang:Right() * move:GetSideSpeed()) +
		(ang:Up() * move:GetUpSpeed())

		local aceldir = acel:GetNormalized()
		local acelspeed = math.min(acel:Length(), ply:GetMaxSpeed())
		acel = aceldir * acelspeed * 2

		if bit.band(move:GetButtons(), IN_JUMP) ~= 0 then
			acel.z = acel.z + ply:GetMaxSpeed()
		end

		vel = vel + acel * FrameTime()
		vel = vel * (1 - FrameTime() * 2)

		local pgrav = ply:GetGravity() == 0 and 1 or ply:GetGravity()
		local gravity = pgrav * gravity_convar:GetFloat() * 0.5
		vel.z = vel.z + FrameTime() * gravity

		move:SetVelocity(vel * 0.99)
	end)

	hook.Add("FinishMove", "gwater2_water_swimming", function(ply, move)
		if !in_water(ply) then return end
		local vel = move:GetVelocity()
		local pgrav = ply:GetGravity() == 0 and 1 or ply:GetGravity()
		local gravity = pgrav * gravity_convar:GetFloat() * 0.5

		vel.z = vel.z + FrameTime() * gravity
		move:SetVelocity(vel)
	end)
	return 
end

-- GetMeshConvexes but for client
local function unfucked_get_mesh(ent, raw)
	-- Physics object exists
	local phys = ent:GetPhysicsObject()
	if phys:IsValid() then return phys:GetMesh() end

	local model = ent:GetModel()
	local is_ragdoll = util.IsValidRagdoll(model)
	local convexes

	if !is_ragdoll or raw then
		local cs_ent = ents.CreateClientProp(model)
		local phys = cs_ent:GetPhysicsObject()
		convexes = phys:IsValid() and (raw and phys:GetMesh() or phys:GetMeshConvexes())
		cs_ent:Remove()
	else 
		local cs_ent = ClientsideRagdoll(model)
		convexes = {}
		for i = 0, cs_ent:GetPhysicsObjectCount() - 1 do
			table.insert(convexes, cs_ent:GetPhysicsObjectNum(i):GetMesh())
		end
		cs_ent:Remove()
	end

	return convexes
end

-- adds entity to FlexSolver
local function add_prop(ent)
	if !IsValid(ent) or !ent:IsSolid() or ent:IsWeapon() or !ent:GetModel() then return end

	-- Note: if we want to respect no collide from the tool or context menu, check for COLLISION_GROUP_WORLD
	-- if ent:GetCollisionGroup() == COLLISION_GROUP_WORLD or (IsValid(ent:GetPhysicsObject()) and (!ent:GetPhysicsObject():IsCollisionEnabled())) then return end

	local convexes = unfucked_get_mesh(ent)
	if !convexes then return end

	if #convexes < 16 then	-- too many convexes to be worth calculating
		for k, v in ipairs(convexes) do
			if #v <= 64 * 3 then	-- hardcoded limits.. No more than 64 planes per convex as it is a FleX limitation
				gwater2.solver:AddConvexMesh(ent:EntIndex(), v, ent:GetPos(), ent:GetAngles())
			else
				gwater2.solver:AddConcaveMesh(ent:EntIndex(), v, ent:GetPos(), ent:GetAngles())
			end
		end
	else
		gwater2.solver:AddConcaveMesh(ent:EntIndex(), unfucked_get_mesh(ent, true), ent:GetPos(), ent:GetAngles())
	end

end

local function get_map_vertices()
	local all_vertices = {}
	for _, brush in ipairs(game.GetWorld():GetBrushSurfaces()) do
		local vertices = brush:GetVertices()
		for i = 3, #vertices do
			all_vertices[#all_vertices + 1] = vertices[1]
			all_vertices[#all_vertices + 1] = vertices[i - 1]
			all_vertices[#all_vertices + 1] = vertices[i]
		end
	end

	return all_vertices
end

require((BRANCH == "x86-64" or BRANCH == "chromium" ) and "gwater2" or "gwater2_main")	-- carrying
include("gwater2_shaders.lua")

gwater2 = {
	solver = FlexSolver(100000),
	renderer = FlexRenderer(46),
	new_ticker = true,
	material = Material("gwater2/finalpass"),--Material("vgui/circle"),--Material("sprites/sent_ball"),
	update_meshes = function(index, id, rep)
		if id == 0 then return end	-- skip, entity is world

		local ent = Entity(id)
		if !IsValid(ent) then 
			gwater2.solver:RemoveMesh(id)
		else 
			if !util.IsValidRagdoll(ent:GetModel()) then
				gwater2.solver:UpdateMesh(index, ent:GetPos(), ent:GetAngles())	
			else
				-- horrible code for proper ragdoll collision. Still breaks half the time. Fuck source
				local bone_index = ent:TranslatePhysBoneToBone(rep)
				local pos, ang = ent:GetBonePosition(bone_index)
				if !pos or pos == ent:GetPos() then 	-- wtf?
					local bone = ent:GetBoneMatrix(bone_index)
					if bone then
						pos = bone:GetTranslation()
						ang = bone:GetAngles()
					else
						pos = ent:GetPos()
						ang = ent:GetAngles()
					end
				end
				gwater2.solver:UpdateMesh(index, pos, ang)
			end
		end
	end,
	reset_solver = function(err)
		xpcall(function()
			gwater2.solver:AddMapMesh(0, game.GetMap())
		end, function(e)
			gwater2.solver:AddConcaveMesh(0, get_map_vertices(), Vector(), Angle())
			if !err then
				ErrorNoHaltWithStack("[GWater2]: Map BSP structure is unsupported. Reverting to brushes. Collision WILL have holes!")
			end
		end)

		for k, ent in ipairs(ents.GetAll()) do
			add_prop(ent)
		end

		gwater2.solver:InitBounds(Vector(-16384, -16384, -16384), Vector(16384, 16384, 16384))	-- source bounds
	end
}

-- setup percentage values (used in menu)
gwater2["surface_tension"] = gwater2.solver:GetParameter("surface_tension") * gwater2.solver:GetParameter("radius")^4	-- dont ask me why its a power of 4
gwater2["fluid_rest_distance"] = gwater2.solver:GetParameter("fluid_rest_distance") / gwater2.solver:GetParameter("radius")
gwater2["collision_distance"] = gwater2.solver:GetParameter("collision_distance") / gwater2.solver:GetParameter("radius")
gwater2["blur_passes"] = 3
gwater2["size"] = 4
gwater2["density"] = 1
gwater2["forward_velocity"] = 100

-- tick particle solver
local last_systime = os.clock()
local limit_fps = 1 / 60
local average_frametime = limit_fps
local function gwater_tick()
	if gwater2.new_ticker then return end

	local systime = os.clock()

	if gwater2.solver:Tick(average_frametime, 1) then
	//if gwater2.solver:Tick(1/165, hang_thread and 0 or 1) then
		average_frametime = average_frametime + ((systime - last_systime) - average_frametime) * 0.03
		last_systime = systime	// smooth out fps
	end
end

local function gwater_tick2()
	last_systime = os.clock()
	gwater2.solver:ApplyContacts(limit_fps * 0.01, 3, 0)
	gwater2.solver:IterateMeshes(gwater2.update_meshes)
	gwater2.solver:Tick(limit_fps, 0)
end

// run whenever possible, as often as possible. we dont know when flex will finish calculations
local no = function() end
hook.Add("PreRender", "gwater_tick", gwater_tick)
hook.Add("PostRender", "gwater_tick", gwater_tick)
hook.Add("Think", "gwater_tick", function()
	if gwater2.new_ticker then return end
	gwater2.solver:IterateMeshes(gwater2.update_meshes)
end)

timer.Create("gwater2_tick", limit_fps, 0, function()
	if !gwater2.new_ticker then return end
	gwater_tick2()
end)
gwater2.reset_solver()
hook.Add("InitPostEntity", "gwater2_addprop", gwater2.reset_solver)
hook.Add("OnEntityCreated", "gwater2_addprop", function(ent) timer.Simple(0, function() add_prop(ent) end) end)	// timer.0 so data values are setup correctly