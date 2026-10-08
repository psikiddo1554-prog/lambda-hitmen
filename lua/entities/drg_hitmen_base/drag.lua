-- lua/autorun/drag.lua
--
-- HitmenDrag
--
-- Drags entities alongside another entity.
--
-- Lambda Players:
--   * Are NOT parented.
--   * Are frozen through Lambda's native l_isfrozen state.
--   * Have their movement coroutine cancelled.
--   * Are directly repositioned every server tick.
--
-- Normal entities:
--   * Are parented to the dragger.
--   * Have their movement disabled while dragged.
--
-- API:
--
--   HitmenDrag.Drag(target, dragger, offset)
--   HitmenDrag.Undrag(target)
--   HitmenDrag.IsDragged(target)
--   HitmenDrag.GetState(target)
--   HitmenDrag.ReleaseEntity(entity)
--


HitmenDrag = HitmenDrag or {}

HitmenDrag.Active = HitmenDrag.Active or {}

-- Remove any old weak-table behavior from previous versions.
setmetatable(HitmenDrag.Active, nil)

local Active = HitmenDrag.Active


-- ============================================================================
-- Utility
-- ============================================================================

local ZERO_VECTOR = vector_origin


local function IsLambdaPlayer(entity)
	if not IsValid(entity) then
		return false
	end

	-- Lambda Players.
	if entity.IsLambdaPlayer == true then
		return true
	end

	-- GLambda compatibility.
	if entity.gb_IsLambdaPlayer == true then
		return true
	end

	return false
end


local function NormalizeOffset(offset)
	if isvector(offset) then
		return offset
	end

	return Vector(0, 0, 0)
end


local function GetWorldCenter(entity)
	if not IsValid(entity) then
		return nil
	end

	if isfunction(entity.WorldSpaceCenter) then
		return entity:WorldSpaceCenter()
	end

	local mins, maxs = entity:GetCollisionBounds()

	return entity:LocalToWorld(
		(mins + maxs) * 0.5
	)
end


local function GetWorldOffset(entity, offset)
	if not IsValid(entity) then
		return ZERO_VECTOR
	end

	return
		entity:GetForward() * offset.x +
		entity:GetRight() * offset.y +
		entity:GetUp() * offset.z
end


local function GetCenterOffsetFromOrigin(entity)
	if not IsValid(entity) then
		return ZERO_VECTOR
	end

	-- World-space center minus entity origin.
	return
		entity:WorldSpaceCenter() -
		entity:GetPos()
end


local function GetDesiredCenter(dragger, offset)
	if not IsValid(dragger) then
		return nil
	end

	local draggerCenter =
		GetWorldCenter(dragger)

	if not draggerCenter then
		return nil
	end

	return
		draggerCenter +
		GetWorldOffset(
			dragger,
			offset
		)
end


local function GetDesiredOrigin(target, dragger, offset)
	if not IsValid(target)
		or not IsValid(dragger)
	then
		return nil
	end

	local desiredCenter =
		GetDesiredCenter(
			dragger,
			offset
		)

	if not desiredCenter then
		return nil
	end

	local targetCenterOffset =
		GetCenterOffsetFromOrigin(target)

	return
		desiredCenter -
		targetCenterOffset
end


-- ============================================================================
-- Velocity
-- ============================================================================

local function StopNormalMovement(entity)
	if not IsValid(entity) then
		return
	end

	if isfunction(entity.SetVelocity) then
		entity:SetVelocity(ZERO_VECTOR)
	end

	if isfunction(entity.SetLocalVelocity) then
		entity:SetLocalVelocity(ZERO_VECTOR)
	end
end


local function StopLambdaMovement(entity)
	if not IsLambdaPlayer(entity) then
		return
	end

	-- Stop NextBot locomotion.
	if entity.loco
		and isfunction(entity.loco.SetVelocity)
	then
		entity.loco:SetVelocity(ZERO_VECTOR)
	end

	-- Stop normal entity velocity.
	StopNormalMovement(entity)
end


local function GetLambdaVelocity(entity)
	if not IsLambdaPlayer(entity) then
		return ZERO_VECTOR
	end

	if entity.loco
		and isfunction(entity.loco.GetVelocity)
	then
		return entity.loco:GetVelocity()
	end

	if isfunction(entity.GetVelocity) then
		return entity:GetVelocity()
	end

	return ZERO_VECTOR
end


-- ============================================================================
-- Lambda control
-- ============================================================================

local function CancelLambdaMovement(target)
	if not IsLambdaPlayer(target) then
		return
	end

	-- Lambda's movement coroutine checks AbortMovement.
	if isfunction(target.CancelMovement) then
		target:CancelMovement()
	end

	-- Explicitly terminate the current movement state.
	target.l_issmoving = false
	target.l_movepos = nil
	target.l_moveoptions = nil
	target.l_CurrentPath = nil
	target.AbortMovement = false

	StopLambdaMovement(target)
end


local function FreezeLambda(target)
	if not IsLambdaPlayer(target) then
		return
	end

	-- IMPORTANT:
	-- Do not call target:Freeze(true) here.
	--
	-- We only want Lambda's own AI-disabled state, without allowing the
	-- engine's normal Entity:Freeze behavior to modify the NextBot's
	-- movement type.
	target.l_isfrozen = true

	CancelLambdaMovement(target)
end


local function UnfreezeLambda(target, wasFrozen)
	if not IsLambdaPlayer(target) then
		return
	end

	target.l_isfrozen = wasFrozen == true

	if wasFrozen then
		StopLambdaMovement(target)
	end
end


-- ============================================================================
-- Lambda positioning
-- ============================================================================

local function MoveLambdaToTarget(
	target,
	dragger,
	offset
)

	if not IsValid(target)
		or not IsValid(dragger)
	then
		return false
	end

	local desiredOrigin =
		GetDesiredOrigin(
			target,
			dragger,
			offset
		)

	if not desiredOrigin then
		return false
	end

	-- Stop AI movement immediately before teleporting.
	CancelLambdaMovement(target)

	-- Put the Lambda exactly where its center should be.
	target:SetPos(
		desiredOrigin
	)

	-- Kill any velocity the movement system may have generated.
	StopLambdaMovement(target)

	return true
end


-- ============================================================================
-- Parent safety
-- ============================================================================

local function WouldCreateParentCycle(child, parent)
	if not IsValid(child)
		or not IsValid(parent)
	then
		return false
	end

	if child == parent then
		return true
	end

	local current = parent

	for _ = 1, 64 do
		if not IsValid(current) then
			return false
		end

		if current == child then
			return true
		end

		current = current:GetParent()
	end

	return false
end


-- ============================================================================
-- Start dragging
-- ============================================================================

function HitmenDrag.Drag(
	target,
	dragger,
	offset
)

	if not SERVER then
		return false
	end

	if not IsValid(target)
		or not IsValid(dragger)
		or target == dragger
	then
		return false
	end

	offset = NormalizeOffset(offset)

	-- Never allow parent cycles for normal entities.
	if not IsLambdaPlayer(target)
		and WouldCreateParentCycle(
			target,
			dragger
		)
	then
		return false
	end

	-- Remove any existing drag.
	HitmenDrag.Undrag(target)


	local isLambda =
		IsLambdaPlayer(target)


	local state = {
		target = target,
		dragger = dragger,

		offset = offset,

		isLambda = isLambda,

		originalParent = nil,
		originalMoveType = nil,

		originalPosition = target:GetPos(),
		originalAngles = target:GetAngles(),

		originalVelocity = GetLambdaVelocity(target),

		wasFrozen = false
	}


	-- ========================================================================
	-- Lambda Player
	-- ========================================================================

	if isLambda then

		-- Save Lambda's original frozen state.
		state.wasFrozen =
			target.l_isfrozen == true

		-- Save original parent only for restoration.
		if IsValid(target:GetParent()) then
			state.originalParent =
				target:GetParent()
		end

		-- Lambda should NOT remain parented during the drag.
		target:SetParent(nil)

		-- Disable its AI safely.
		FreezeLambda(target)

		-- Initial placement.
		if not MoveLambdaToTarget(
			target,
			dragger,
			offset
		) then

			UnfreezeLambda(
				target,
				state.wasFrozen
			)

			if IsValid(state.originalParent) then
				target:SetParent(
					state.originalParent
				)
			end

			return false
		end

		Active[target] = state

		return true
	end


	-- ========================================================================
	-- Normal entity
	-- ========================================================================

	state.originalParent =
		IsValid(target:GetParent())
		and target:GetParent()
		or nil

	state.originalMoveType =
		target:GetMoveType()


	-- Remove any previous parent before positioning.
	target:SetParent(nil)

	-- Freeze movement.
	target:SetMoveType(
		MOVETYPE_NONE
	)

	StopNormalMovement(target)


	-- Position the target using its center.
	local desiredOrigin =
		GetDesiredOrigin(
			target,
			dragger,
			offset
		)

	if not desiredOrigin then

		target:SetMoveType(
			state.originalMoveType
		)

		if IsValid(state.originalParent) then
			target:SetParent(
				state.originalParent
			)
		end

		return false
	end


	target:SetPos(
		desiredOrigin
	)


	-- Parent normal entities.
	if not WouldCreateParentCycle(
		target,
		dragger
	) then
		target:SetParent(dragger)
	end


	StopNormalMovement(target)

	Active[target] = state

	return true
end


-- ============================================================================
-- Stop dragging
-- ============================================================================

function HitmenDrag.Undrag(target)

	if not SERVER then
		return false
	end

	if not IsValid(target) then
		return false
	end

	local state =
		Active[target]

	if not state then
		return false
	end


	-- Capture exact release transform.
	local releasePosition =
		target:GetPos()

	local releaseAngles =
		target:GetAngles()


	Active[target] = nil


	-- ========================================================================
	-- Lambda Player
	-- ========================================================================

	if state.isLambda then

		-- Lambda was never parented, so this is just a normal release.
		target:SetPos(
			releasePosition
		)

		target:SetAngles(
			releaseAngles
		)

		UnfreezeLambda(
			target,
			state.wasFrozen
		)

		-- Restore original parent only if one existed.
		if IsValid(state.originalParent) then
			target:SetParent(
				state.originalParent
			)
		end

		-- Prevent a stale drag velocity.
		if state.wasFrozen then
			StopLambdaMovement(target)
		end

		return true
	end


	-- ========================================================================
	-- Normal entity
	-- ========================================================================

	target:SetParent(nil)

	target:SetPos(
		releasePosition
	)

	target:SetAngles(
		releaseAngles
	)


	if state.originalMoveType ~= nil then
		target:SetMoveType(
			state.originalMoveType
		)
	end


	if IsValid(state.originalParent) then
		target:SetParent(
			state.originalParent
		)
	end


	StopNormalMovement(target)

	return true
end


-- ============================================================================
-- State
-- ============================================================================

function HitmenDrag.IsDragged(target)

	return IsValid(target)
		and Active[target] ~= nil
end


function HitmenDrag.GetState(target)

	if not IsValid(target) then
		return nil
	end

	return Active[target]
end


-- ============================================================================
-- Release everything associated with an entity
-- ============================================================================

function HitmenDrag.ReleaseEntity(entity)

	if not IsValid(entity) then
		return
	end


	-- Entity is being dragged.
	if Active[entity] then
		HitmenDrag.Undrag(entity)
	end


	-- Entity is dragging something.
	local targets = {}

	for target, state in pairs(Active) do

		if state.dragger == entity then
			targets[#targets + 1] = target
		end
	end


	for _, target in ipairs(targets) do

		if IsValid(target) then
			HitmenDrag.Undrag(target)
		else
			Active[target] = nil
		end
	end
end


-- ============================================================================
-- Server maintenance
-- ============================================================================

if SERVER then

	hook.Add(
		"Tick",
		"HitmenDrag_Maintain",
		function()

			for target, state in pairs(Active) do

				-- Invalid drag.
				if not IsValid(target)
					or not IsValid(state.dragger)
					or target == state.dragger
				then

					if IsValid(target) then
						HitmenDrag.Undrag(target)
					else
						Active[target] = nil
					end

					continue
				end


				-- ==============================================================
				-- Lambda Player
				-- ==============================================================

				if state.isLambda then

					-- Do not parent Lambda.
					if target:GetParent() ~= nil then
						target:SetParent(nil)
					end

					-- Keep Lambda's AI disabled.
					target.l_isfrozen = true

					-- Keep its movement coroutine dead.
					CancelLambdaMovement(target)

					-- Recalculate its position relative to the dragger.
					local success =
						MoveLambdaToTarget(
							target,
							state.dragger,
							state.offset
						)

					if not success then
						HitmenDrag.Undrag(target)
						continue
					end

					continue
				end


				-- ==============================================================
				-- Normal entity
				-- ==============================================================

				if target:GetParent()
					~= state.dragger
				then
					if WouldCreateParentCycle(
						target,
						state.dragger
					) then

						HitmenDrag.Undrag(target)
						continue
					end

					target:SetParent(
						state.dragger
					)
				end


				if target:GetMoveType()
					~= MOVETYPE_NONE
				then
					target:SetMoveType(
						MOVETYPE_NONE
					)
				end


				StopNormalMovement(target)
			end
		end
	)


	-- ==========================================================================
	-- Entity removal
	-- ==========================================================================

	hook.Add(
		"EntityRemoved",
		"HitmenDrag_EntityRemoved",
		function(entity)

			HitmenDrag.ReleaseEntity(
				entity
			)
		end
	)

end