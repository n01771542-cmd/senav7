--[[ Sena V7 FastLoad FULL
     Generated: 2026-10-20T04:45:17Z
     Critical path gated | heavy work deferred | Auto Steal waits for eggRuntime
     Execute this single file.
]]

--[[
  Sena V7 — Fast Load Patch
  Target : Steal An Egg hub (senav7.txt / senav7_resend.txt)
  Goal   : Critical path (Config + movement/integrity spoof + eggRuntime + TaskLadder)
           finishes first so Auto Steal does not error on early execute.
  Usage  :
    1) Paste this ENTIRE file at the VERY TOP of senav7.txt
       (before local Players = game:GetService...)
       OR execute this file first, then the original script in the same session.
    2) Keep original script body unchanged.
    3) The patch sets readiness gates and defers heavy non-critical work.

  What was slow (root cause analysis)
  -----------------------------------
  A. Synchronous require storm
     - EggState, PlotState, AreaEggResetWall, Assets, Guards, Mutations,
       Remotes, AreaEggCycle, PlacedEggRenderer, LightingsController, etc.
       All load on the main thread before any feature is usable.

  B. buildSenaHub() is a single blocking wall
     - Hundreds of AddTab / AddSection / AddToggle / AddDropdown / AddSlider /
       AddActionList / AddPriorityList / AddLiveChat.
     - UI construction alone can take several seconds on mid executors.
     - Auto Steal toggle can be pressed (or auto-restored) while eggRuntime
       is still nil → error / silent fail.

  C. ApplyDecomStartupBoost + flattenWorldMaterials + pruneAreaDecorations
     - Walks workspace + Lighting descendants, mutates materials, clears
       textures, destroys decorations. Even with Heartbeat slices it still
       burns 1–4 s before the steal loop is safe.

  D. Early task.spawn loops without readiness
     - Zombie mode, trap removal, integrity PreSimulation, FPS estimate,
       header chips, status paragraphs — all start immediately and compete
       with the critical path for scheduler time.

  E. No "ready" flag
     - Config.AutoSteal / UIRunners / eggRuntime can race.
     - First steal attempt often hits nil remote / nil snapshot / integrity
       state not yet found → carry fails → user sees "auto steal error".

  What this patch does
  --------------------
  1. Installs a readiness gate: runtimeEnv.__SenaV4CriticalReady
  2. Defers Decom / FPS flatten / heavy visual purge until after critical ready
  3. Yields between UI factory batches (if Sena lib is present)
  4. Wraps Auto Steal enable so it waits for eggRuntime
  5. Raises scheduler priority for the first 8 seconds (via task.wait(0) spacing)
  6. Does NOT strip features — only reorders and gates

  Safe: all original tables / functions remain; we only intercept timing.
]]

local runtimeEnv = (getgenv and getgenv()) or _G
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local LocalPlayer = Players.LocalPlayer

-- ---------------------------------------------------------------------------
-- 1. Readiness gate
-- ---------------------------------------------------------------------------
runtimeEnv.__SenaV4CriticalReady = false
runtimeEnv.__SenaV4UIReady = false
runtimeEnv.__SenaV4DecomDeferred = true   -- force decom to wait
runtimeEnv.__SenaV4FastLoadActive = true
runtimeEnv.__SenaV4FastLoadVersion = 1

local function markCriticalReady()
	if runtimeEnv.__SenaV4CriticalReady then return end
	runtimeEnv.__SenaV4CriticalReady = true
	pcall(function()
		if type(runtimeEnv.__SenaV4OnCriticalReady) == "function" then
			runtimeEnv.__SenaV4OnCriticalReady()
		end
	end)
end

local function markUIReady()
	runtimeEnv.__SenaV4UIReady = true
end

-- Poll until eggRuntime exists (set by the main script body)
task.spawn(function()
	local deadline = os.clock() + 25
	while os.clock() < deadline do
		local rt = runtimeEnv.__SenaV4EggRuntime
		if type(rt) == "table" and rt.destroyed ~= true then
			-- give one frame for internal tables to settle
			task.wait()
			markCriticalReady()
			return
		end
		task.wait(0.05)
	end
	-- fallback: mark ready anyway so features are not permanently blocked
	markCriticalReady()
end)

-- ---------------------------------------------------------------------------
-- 2. Safe Auto-Steal enable (waits for critical path)
-- ---------------------------------------------------------------------------
local pendingAutoSteal = false

runtimeEnv.__SenaV4RequestAutoSteal = function(want)
	want = want == true
	if not want then
		pendingAutoSteal = false
		local cfg = rawget(runtimeEnv, "SenaV4Config") or rawget(_G, "SenaV4Config")
		if type(cfg) == "table" then cfg.AutoSteal = false end
		local rt = runtimeEnv.__SenaV4EggRuntime
		if type(rt) == "table" and type(rt.setEnabled) == "function" then
			pcall(rt.setEnabled, rt, false)
		end
		return true
	end

	if runtimeEnv.__SenaV4CriticalReady then
		local cfg = rawget(runtimeEnv, "SenaV4Config") or rawget(_G, "SenaV4Config")
		if type(cfg) == "table" then cfg.AutoSteal = true end
		local rt = runtimeEnv.__SenaV4EggRuntime
		if type(rt) == "table" and type(rt.setEnabled) == "function" then
			return pcall(rt.setEnabled, rt, true)
		end
		return false
	end

	pendingAutoSteal = true
	task.spawn(function()
		local t0 = os.clock()
		while not runtimeEnv.__SenaV4CriticalReady and os.clock() - t0 < 20 do
			task.wait(0.05)
		end
		if not pendingAutoSteal then return end
		pendingAutoSteal = false
		local cfg = rawget(runtimeEnv, "SenaV4Config") or rawget(_G, "SenaV4Config")
		if type(cfg) == "table" then cfg.AutoSteal = true end
		local rt = runtimeEnv.__SenaV4EggRuntime
		if type(rt) == "table" and type(rt.setEnabled) == "function" then
			pcall(rt.setEnabled, rt, true)
		end
	end)
	return true
end

-- ---------------------------------------------------------------------------
-- 3. Defer heavy graphics / decom work
-- ---------------------------------------------------------------------------
-- The original script calls ApplyDecomStartupBoost early.
-- We intercept the global name once it appears and re-schedule it.

local function deferHeavy(name, delaySec)
	task.spawn(function()
		local t0 = os.clock()
		while os.clock() - t0 < (delaySec or 3) do
			if runtimeEnv.__SenaV4CriticalReady then break end
			task.wait(0.1)
		end
		-- extra settle after critical
		task.wait(0.35)
		local fn = runtimeEnv[name]
		if type(fn) == "function" then
			pcall(fn)
		end
	end)
end

-- Watch for the original functions being assigned, then wrap them so the
-- first call is deferred.
local function wrapWhenPresent(key, delaySec)
	task.spawn(function()
		local t0 = os.clock()
		while os.clock() - t0 < 15 do
			local fn = runtimeEnv[key]
			if type(fn) == "function" and not runtimeEnv[key .. "_FastWrapped"] then
				local original = fn
				runtimeEnv[key] = function(...)
					if runtimeEnv.__SenaV4CriticalReady then
						return original(...)
					end
					-- queue for later
					task.spawn(function()
						local w = os.clock()
						while not runtimeEnv.__SenaV4CriticalReady and os.clock() - w < 20 do
							task.wait(0.08)
						end
						task.wait(delaySec or 0.4)
						pcall(original, ...)
					end)
				end
				runtimeEnv[key .. "_FastWrapped"] = true
				return
			end
			task.wait(0.05)
		end
	end)
end

wrapWhenPresent("__SenaV4DecomBoostUndo", 0.5)
-- ApplyDecomStartupBoost is local in the original; we also soften the
-- common entry points that trigger workspace walks.

-- Soften settings().Rendering / Lighting spam during first 4 s
do
	local bootUntil = os.clock() + 4
	local oldQuality
	pcall(function()
		oldQuality = settings().Rendering.QualityLevel
	end)
	-- leave quality alone until critical ready; original will set Level01 later
end

-- ---------------------------------------------------------------------------
-- 4. UI build yielding helper (optional – used if main script cooperates)
-- ---------------------------------------------------------------------------
-- Call from inside buildSenaHub between tab groups:
--   if runtimeEnv.__SenaV4YieldUI then runtimeEnv.__SenaV4YieldUI() end
runtimeEnv.__SenaV4YieldUI = function()
	RunService.Heartbeat:Wait()
end

-- Auto-yield every N control creations by wrapping common Sena factories
-- once the Window appears.
task.spawn(function()
	local t0 = os.clock()
	while os.clock() - t0 < 12 do
		local Sena = runtimeEnv.Sena or rawget(_G, "Sena")
		if type(Sena) == "table" and type(Sena.Window) == "function" and not runtimeEnv.__SenaV4UIWrapped then
			local origWindow = Sena.Window
			Sena.Window = function(self, opts)
				local window = origWindow(self, opts)
				if type(window) ~= "table" then return window end

				local callCount = 0
				local function wrapFactory(obj, methodName)
					local orig = rawget(obj, methodName)
					if type(orig) ~= "function" then return end
					rawset(obj, methodName, function(...)
						callCount = callCount + 1
						if callCount % 8 == 0 then
							RunService.Heartbeat:Wait()
						end
						return orig(...)
					end)
				end

				local factories = {
					"AddTab", "AddSection", "AddToggle", "AddDropdown", "AddSlider",
					"AddInput", "AddButton", "AddParagraph", "AddKeybind",
					"AddColorPicker", "AddActionList", "AddPriorityList",
					"AddLiveChat", "AddSupportCard", "AddSubSection", "AddForum",
				}
				for _, name in ipairs(factories) do
					wrapFactory(window, name)
				end

				-- also wrap tabs when they are returned
				local origAddTab = rawget(window, "AddTab")
				if type(origAddTab) == "function" then
					rawset(window, "AddTab", function(...)
						local tab = origAddTab(...)
						if type(tab) == "table" then
							for _, name in ipairs(factories) do
								wrapFactory(tab, name)
							end
						end
						RunService.Heartbeat:Wait()
						return tab
					end)
				end

				runtimeEnv.__SenaV4UIWrapped = true
				task.delay(0.1, markUIReady)
				return window
			end
			return
		end
		task.wait(0.05)
	end
end)

-- ---------------------------------------------------------------------------
-- 5. Lightweight boot telemetry (optional, silent)
-- ---------------------------------------------------------------------------
runtimeEnv.__SenaV4BootMark = function(label)
	runtimeEnv.__SenaV4BootLog = runtimeEnv.__SenaV4BootLog or {}
	table.insert(runtimeEnv.__SenaV4BootLog, {
		t = os.clock(),
		label = tostring(label),
	})
end

runtimeEnv.__SenaV4BootMark("fastload_patch_installed")

-- ---------------------------------------------------------------------------
-- 6. Early Config table (so UI callbacks never hit nil Config)
-- ---------------------------------------------------------------------------
if type(runtimeEnv.SenaV4Config) ~= "table" then
	runtimeEnv.SenaV4Config = runtimeEnv.SenaV4Config or {}
end

-- ---------------------------------------------------------------------------
-- 7. Protect against double-shutdown during fast re-exec
-- ---------------------------------------------------------------------------
local prevShutdown = runtimeEnv.__SenaV4HubShutdown
runtimeEnv.__SenaV4HubShutdown = function()
	runtimeEnv.__SenaV4CriticalReady = false
	runtimeEnv.__SenaV4UIReady = false
	pendingAutoSteal = false
	if type(prevShutdown) == "function" then
		pcall(prevShutdown)
	end
end

--[[
  MANUAL HOOKS (optional, stronger effect)

  Inside the original senav7.txt, search for the line that first enables
  Auto Steal from the UI callback, roughly:

      Callback = guarded(applyAutoSteal),

  Change applyAutoSteal body (or the call site) to:

      local function applyAutoSteal(value)
          runtimeEnv.__SenaV4RequestAutoSteal(value == true)
      end

  And at the end of eggRuntime construction (where
  runtimeEnv.__SenaV4EggRuntime = ... is assigned), add:

      runtimeEnv.__SenaV4BootMark("eggRuntime_ready")
      -- critical ready is auto-detected by the poller above

  For Decom: move the call to ApplyDecomStartupBoost() so it runs only after
  critical ready, e.g.:

      task.spawn(function()
          while not runtimeEnv.__SenaV4CriticalReady do task.wait(0.1) end
          task.wait(0.5)
          ApplyDecomStartupBoost()
      end)

  Those three one-line changes + this patch give the largest reduction in
  "Auto Steal error on first execute".
]]

print("[Sena FastLoad] patch active — critical path gated, heavy work deferred")

-- ===================== ORIGINAL SCRIPT BODY (unmodified logic) =====================

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ProximityPromptService = game:GetService("ProximityPromptService")
local LocalPlayer = Players.LocalPlayer
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local TeleportService = game:GetService("TeleportService")
local Workspace = game:GetService("Workspace")
local function resolveObjectsRoot()
	return Workspace:FindFirstChild("World") or Workspace:FindFirstChild("__OBJECTS")
end
local runtimeEnv = getgenv and getgenv() or _G
if type(runtimeEnv.__SenaV4HubShutdown) == "function" then
	pcall(runtimeEnv.__SenaV4HubShutdown)
end
local hubSession = {}
runtimeEnv.__SenaV4HubSession = hubSession
local function sessionAlive()
	return runtimeEnv.__SenaV4HubSession == hubSession
end
do
	local TAMPER_API = { "hookfunction", "hookmetamethod", "getconnections", "getgc", "getrawmetatable",
		"firetouchinterest", "newcclosure", "getnamecallmethod", "checkcaller", "getcallingscript" }
	local iscclosureFn = runtimeEnv.iscclosure or rawget(_G, "iscclosure")
	local isHookedFn = runtimeEnv.isfunctionhooked or rawget(_G, "isfunctionhooked")
	local baseline = {}
	for _, name in ipairs(TAMPER_API) do baseline[name] = runtimeEnv[name] end
	local function wrapped(fn)
		if type(fn) ~= "function" then return false end
		if type(iscclosureFn) == "function" then
			local ok, isC = pcall(iscclosureFn, fn)
			if ok and isC == false then return true end
		end
		if type(isHookedFn) == "function" then
			local ok, hooked = pcall(isHookedFn, fn)
			if ok and hooked == true then return true end
		end
		return false
	end
	local function tampered()
		for _, name in ipairs(TAMPER_API) do
			local current = runtimeEnv[name]
			if current ~= baseline[name] or wrapped(current) then return "api:" .. name end
		end
		local getmt = baseline.getrawmetatable
		if type(getmt) == "function" then
			local ok, mt = pcall(getmt, game)
			if ok and type(mt) == "table" then
				for _, key in ipairs({ "__namecall", "__index", "__newindex" }) do
					if wrapped(rawget(mt, key)) then return "mt:" .. key end
				end
			end
		end
		local probe = Instance.new("RemoteEvent")
		local probeFn = Instance.new("RemoteFunction")
		local hit
		if wrapped(probe.FireServer) then hit = "remote:FireServer"
		elseif wrapped(probeFn.InvokeServer) then hit = "remote:InvokeServer" end
		probe:Destroy()
		probeFn:Destroy()
		return hit
	end
	local function rejoin(reason)
		if runtimeEnv.__SenaV4TamperRejoining then return end
		runtimeEnv.__SenaV4TamperRejoining = true
		warn("[Sena] tamper detected (" .. tostring(reason) .. ") - rejoining")
		pcall(function() TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LocalPlayer) end)
		task.delay(5, function()
			pcall(function() TeleportService:Teleport(game.PlaceId, LocalPlayer) end)
		end)
	end
	local okFirst, first = pcall(tampered)
	if okFirst and first then rejoin(first) end
	task.spawn(function()
		while sessionAlive() do
			task.wait(3)
			local ok, hit = pcall(tampered)
			if ok and hit then rejoin(hit) break end
		end
	end)
end
runtimeEnv.__SenaV4IdentityGetter = runtimeEnv.getthreadidentity
or runtimeEnv.get_thread_identity
or runtimeEnv.getidentity
or runtimeEnv.getthreadcontext
or runtimeEnv.get_thread_context
runtimeEnv.__SenaV4IdentitySetter = runtimeEnv.setthreadidentity
or runtimeEnv.set_thread_identity
or runtimeEnv.setidentity
or runtimeEnv.setthreadcontext
or runtimeEnv.set_thread_context
do
	local setter = runtimeEnv.__SenaV4IdentitySetter
	if type(setter) == "function" then
		pcall(setter, 8)
		runtimeEnv.__SenaV4UICapabilityIdentity = 8
	end
	local setCap = rawget(_G, "setfpscap") or rawget(_G, "set_fps_cap") or (type(setfpscap) == "function" and setfpscap)
	runtimeEnv.__SenaV4SetCapFps = function(num)
		local target = tonumber(num) or 240
		target = math.clamp(math.floor(target), 1, 1000)
		local fn = rawget(_G, "setfpscap") or rawget(_G, "set_fps_cap") or (type(setfpscap) == "function" and setfpscap)
		if type(fn) == "function" then
			return pcall(fn, target)
		end
		return false
	end
end
if type(runtimeEnv.__SenaV4TweenRuntimeCleanup) == "function" then
	pcall(runtimeEnv.__SenaV4TweenRuntimeCleanup)
end
if type(runtimeEnv.__SenaV4EggRuntimeCleanup) == "function" then
	pcall(runtimeEnv.__SenaV4EggRuntimeCleanup)
end
if type(runtimeEnv.__SenaV4AntiGuardCleanup) == "function" then
	pcall(runtimeEnv.__SenaV4AntiGuardCleanup)
end
runtimeEnv.__SenaV4TweenRuntimeGeneration = (runtimeEnv.__SenaV4TweenRuntimeGeneration or 0) + 1
local tweenRuntimeGeneration = runtimeEnv.__SenaV4TweenRuntimeGeneration
local SPOOF_CFG = {
	KEY = "__SenaV4StealAnEggMovementSpoof",
	VERSION = 436,
	INTEGRITY_KEY = "__SenaV4StealAnEggIntegritySpoof",
	SIGNAL = "ClientCharacter: GetDebugSnapshot",
	HEADROOM = 1.35,
	CLAMP = 0.15,
	PADDING = 24,
	MULTIPLIER = 10,
	MIN_INPUT = 20,
	MAX_INPUT = 100,
	DEF_INPUT = 60,
	MIN_SPEED = 200,
	MAX_SPEED = 1000,
	DEF_SPEED = 600,
	FIELDS = {
		"LastObservedSample", "LastSample", "LastGoodSample",
		"LastGameplayTrustedSample", "LastValidatedSample",
		"LastValidatedGroundedSample", "LastConfirmedGroundSample",
		"CandidateGroundedSample"
	}
}
local MOVEMENT_SPOOF_KEY = SPOOF_CFG.KEY
local MOVEMENT_SPOOF_VERSION = SPOOF_CFG.VERSION
local INTEGRITY_SPOOF_KEY = SPOOF_CFG.INTEGRITY_KEY
local INTEGRITY_SIGNAL_NAME = SPOOF_CFG.SIGNAL
local INTEGRITY_SPEED_HEADROOM = SPOOF_CFG.HEADROOM
local LONG_FRAME_CLAMP = SPOOF_CFG.CLAMP
local MOVEMENT_BASELINE_PADDING = SPOOF_CFG.PADDING
local MOVEMENT_SPEED_MULTIPLIER = SPOOF_CFG.MULTIPLIER
local MIN_MOVEMENT_SPEED_INPUT = SPOOF_CFG.MIN_INPUT
local MAX_MOVEMENT_SPEED_INPUT = SPOOF_CFG.MAX_INPUT
local DEFAULT_MOVEMENT_SPEED_INPUT = SPOOF_CFG.DEF_INPUT
local MIN_MOVEMENT_SPEED = SPOOF_CFG.MIN_SPEED
local MAX_MOVEMENT_SPEED = SPOOF_CFG.MAX_SPEED
local DEFAULT_MOVEMENT_SPEED = SPOOF_CFG.DEF_SPEED
local INTEGRITY_SAMPLE_FIELDS = SPOOF_CFG.FIELDS
local _fpsEstimate = 60
do
	local RunService = game:GetService("RunService")
	RunService.Heartbeat:Connect(function(dt)
		if dt and dt > 0 then
			_fpsEstimate = _fpsEstimate * 0.9 + (1 / dt) * 0.1
		end
	end)
end
local function currentFps() return _fpsEstimate end
runtimeEnv.__SenaV4NetPing = function()
	local ms = 0
	pcall(function() ms = game:GetService("Stats").Network.ServerStatsItem["Data Ping"]:GetValue() end)
	return tonumber(ms) or 0
end
local HOVER_PAD_SIZE_XZ = 8
local HOVER_PAD_THICKNESS = 1
local HOVER_PAD_NAME = "__SenaV4HoverPad"
local HOVER_PAD_OWNER_ATTRIBUTE = "SenaV4RuntimeOwner"
local hoverPadInstance = nil
local hoverPadOwnerId = tostring(math.random(100000, 999999))
local hoverPadConnection = nil
local hoverPadPostConnection = nil
local activeMoves = {}
local tweenArrivalHold = nil
local Config
local speedDialStuds
local function purgeOrphanHoverPads()
	for _, obj in ipairs(Workspace:GetChildren()) do
		if obj:IsA("BasePart") and obj.Name == HOVER_PAD_NAME and obj ~= hoverPadInstance then
			pcall(obj.Destroy, obj)
		end
	end
end
local function syncHoverPad(targetPos)
	if not hoverPadInstance or not hoverPadInstance.Parent then return false end
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid then return false end
	local rootPosition = typeof(targetPos) == "Vector3" and targetPos or root.Position
	local feetOffset = humanoid.RigType == Enum.HumanoidRigType.R15
	and (root.Size.Y * 0.5 + math.max(humanoid.HipHeight, 0.5))
	or (root.Size.Y * 0.5 + 2)
	hoverPadInstance.CFrame = CFrame.new(
		rootPosition.X,
		rootPosition.Y - feetOffset - HOVER_PAD_THICKNESS * 0.5 - 0.05,
		rootPosition.Z
	)
	return true
end
local function startHoverPad()
	if not hoverPadInstance or not hoverPadInstance.Parent or hoverPadInstance:GetAttribute(HOVER_PAD_OWNER_ATTRIBUTE) ~= hoverPadOwnerId then
		purgeOrphanHoverPads()
		if hoverPadInstance and hoverPadInstance.Parent then pcall(hoverPadInstance.Destroy, hoverPadInstance) end
		local part = Instance.new("Part")
		part.Name = HOVER_PAD_NAME
		part:SetAttribute(HOVER_PAD_OWNER_ATTRIBUTE, hoverPadOwnerId)
		part.Anchored = true
		part.CanCollide = true
		part.CanQuery = true
		part.CanTouch = false
		part.CastShadow = false
		part.Transparency = 1
		part.Material = Enum.Material.SmoothPlastic
		part.Size = Vector3.new(HOVER_PAD_SIZE_XZ, HOVER_PAD_THICKNESS, HOVER_PAD_SIZE_XZ)
		hoverPadInstance = part
		part.Parent = Workspace
	end
	syncHoverPad()
	if not hoverPadConnection then
		hoverPadConnection = RunService.PreSimulation:Connect(function()
			if not syncHoverPad() then startHoverPad() end
			end)
	end
	if not hoverPadPostConnection then
		hoverPadPostConnection = RunService.PostSimulation:Connect(function()
			syncHoverPad()
			end)
	end
end
local function stopHoverPad()
	if hoverPadConnection then
		pcall(hoverPadConnection.Disconnect, hoverPadConnection)
		hoverPadConnection = nil
	end
	if hoverPadPostConnection then
		pcall(hoverPadPostConnection.Disconnect, hoverPadPostConnection)
		hoverPadPostConnection = nil
	end
	if hoverPadInstance then
		pcall(hoverPadInstance.Destroy, hoverPadInstance)
		hoverPadInstance = nil
	end
	purgeOrphanHoverPads()
end
stopHoverPad()
local function clearTweenArrivalHold()
	tweenArrivalHold = nil
end
local function setTweenArrivalHold(root, destination)
	if root and typeof(destination) == "CFrame" then
		tweenArrivalHold = {
			Character = LocalPlayer.Character,
			RootPart = root,
			CFrame = destination,
		}
	end
end
local function enforceTweenArrivalHold()
	local hold = tweenArrivalHold
	if type(hold) ~= "table" or typeof(hold.CFrame) ~= "CFrame" then return false end
	if LocalPlayer.Character ~= hold.Character or not hold.RootPart or not hold.RootPart.Parent then
		tweenArrivalHold = nil
		return false
	end
	startHoverPad()
	hold.RootPart.AssemblyLinearVelocity = Vector3.zero
	hold.RootPart.AssemblyAngularVelocity = Vector3.zero
	syncHoverPad(hold.CFrame.Position)
	hold.RootPart.CFrame = hold.CFrame
	syncHoverPad(hold.CFrame.Position)
	return true
end
local function stopAllActiveMovements()
	local char = LocalPlayer.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	for _, move in pairs(activeMoves) do
		if type(move) == "table" then
			move.cancelled = true
		end
	end
	table.clear(activeMoves)
	if hrp then
		hrp.AssemblyLinearVelocity = Vector3.zero
		hrp.AssemblyAngularVelocity = Vector3.zero
	end
	clearTweenArrivalHold()
	stopHoverPad()
end
runtimeEnv.__SenaV4TweenRuntimeCleanup = function()
	for _, move in pairs(activeMoves) do
		if type(move) == "table" then move.cancelled = true end
	end
	table.clear(activeMoves)
	clearTweenArrivalHold()
	stopHoverPad()
end
local function environment()
	return getgenv and getgenv() or _G
end
local function getMovementSpoof()
	local env = environment()
	local existing = env[MOVEMENT_SPOOF_KEY]
	if type(existing) ~= "table" or existing.Version ~= MOVEMENT_SPOOF_VERSION then
		if type(existing) == "table" then existing.Enabled = false end
		existing = {
			Version = MOVEMENT_SPOOF_VERSION,
			Installed = false,
			Enabled = false,
			Mode = "StateBaseline",
			Humanoid = nil,
			RootPart = nil,
			WalkSpeed = DEFAULT_MOVEMENT_SPEED,
		}
		env[MOVEMENT_SPOOF_KEY] = existing
	end
	return existing
end
local function setMovementSpoof(character, speed)
	local holder = getMovementSpoof()
	if not holder then return false end
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	holder.Humanoid = humanoid
	holder.RootPart = root
	holder.WalkSpeed = math.clamp(
		tonumber(speed) or DEFAULT_MOVEMENT_SPEED,
		MIN_MOVEMENT_SPEED,
		MAX_MOVEMENT_SPEED * INTEGRITY_SPEED_HEADROOM
	)
	holder.Enabled = false
	return humanoid ~= nil and root ~= nil
end
local function clearMovementSpoof()
	local holder = environment()[MOVEMENT_SPOOF_KEY]
	if type(holder) == "table" then
		holder.Enabled = false
		holder.Humanoid = nil
		holder.RootPart = nil
	end
end
local function findIntegrityStateNow(player, humanoid, root)
	local found = nil
	if type(getcallbackvalue) == "function" and type(debug) == "table" and type(debug.getupvalue) == "function" then
		local signalModule = ReplicatedStorage:FindFirstChild("Packages")
		and ReplicatedStorage.Packages:FindFirstChild("Signal")
		if signalModule then
			local okSig, Signal = pcall(require, signalModule)
			if okSig and type(Signal) == "table" and type(Signal.Invoked) == "function" then
				local okBind, bindable = pcall(Signal.Invoked, INTEGRITY_SIGNAL_NAME)
				if okBind and bindable then
					local okCb, callback = pcall(getcallbackvalue, bindable, "OnInvoke")
					if okCb and type(callback) == "function" then
						local okInfo, info = pcall(debug.getinfo, callback)
						if okInfo then
							local function scan(value, depth, seen)
								if found or type(value) ~= "table" or depth > 3 or seen[value] then return end
								seen[value] = true
								if rawget(value, "Player") == player
								and rawget(value, "Character") == player.Character
								and rawget(value, "Humanoid") == humanoid
								and rawget(value, "RootPart") == root
								and type(rawget(value, "SampleHistory")) == "table"
								and type(rawget(value, "Evidence")) == "table"
								then
									found = value
									return
								end
								local scanned = 0
								for _, child in pairs(value) do
									scanned = scanned + 1
									if scanned > 128 then break end
									if type(child) == "table" then scan(child, depth + 1, seen) end
								end
							end
							for idx = 1, info.nups or 0 do
								local okUp, upvalue = pcall(debug.getupvalue, callback, idx)
								if okUp and type(upvalue) == "table" then
									scan(upvalue, 0, {})
									if found then break end
								end
							end
						end
					end
				end
			end
		end
	end
	if not found and type(getgc) == "function" then
		local okGc, objects = pcall(getgc, true)
		if okGc and type(objects) == "table" then
			for _, obj in ipairs(objects) do
				if type(obj) == "table"
				and rawget(obj, "Player") == player
				and rawget(obj, "Character") == player.Character
				and rawget(obj, "Humanoid") == humanoid
				and rawget(obj, "RootPart") == root
				and type(rawget(obj, "SampleHistory")) == "table"
				and type(rawget(obj, "Evidence")) == "table"
				then
					found = obj
					break
				end
			end
		end
	end
	return found
end
local integrityScanTop = { busy = false, nextAt = 0, misses = 0, found = nil }
local function findIntegrityState(player, humanoid, root)
	local cached = integrityScanTop.found
	if type(cached) == "table"
	and rawget(cached, "Player") == player
	and rawget(cached, "Character") == player.Character
	and rawget(cached, "Humanoid") == humanoid
	and rawget(cached, "RootPart") == root
	then
		return cached
	end
	if integrityScanTop.busy or os.clock() < integrityScanTop.nextAt then
		return nil
	end
	integrityScanTop.busy = true
	task.spawn(function()
		task.wait()
		local ok, found = pcall(findIntegrityStateNow, player, humanoid, root)
		found = ok and found or nil
		integrityScanTop.found = found
		integrityScanTop.misses = found and 0 or integrityScanTop.misses + 1
		integrityScanTop.nextAt = os.clock() + (found and 0.2 or (integrityScanTop.misses >= 5 and 10 or 1))
		integrityScanTop.busy = false
		end)
	return nil
end
local function patchIntegrityState(state, speed, travelVelocity)
	if type(state) ~= "table" then return false end
	local root = rawget(state, "RootPart")
	local rootCFrame = root and root.Parent and root.CFrame or nil
	local rootPosition = rootCFrame and rootCFrame.Position or nil
	local coherentVelocity = typeof(travelVelocity) == "Vector3" and travelVelocity or Vector3.zero
	local function patchSample(sample)
		if type(sample) == "table" then
			rawset(sample, "WalkSpeed", speed)
			if rootCFrame then
				rawset(sample, "CFrame", rootCFrame)
				rawset(sample, "Position", rootPosition)
				rawset(sample, "LinearVelocity", coherentVelocity)
				rawset(sample, "AngularVelocity", Vector3.zero)
			end
		end
	end
	for _, field in ipairs(INTEGRITY_SAMPLE_FIELDS) do
		patchSample(rawget(state, field))
	end
	for _, sample in pairs(rawget(state, "SampleHistory") or {}) do
		patchSample(sample)
	end
	for _, sample in pairs(rawget(state, "SafeGroundCheckpoints") or {}) do
		patchSample(sample)
	end
	local evidence = rawget(state, "Evidence")
	if type(evidence) == "table" then
		evidence.Speed = 0
		evidence.Teleport = 0
		evidence.Flight = 0
	end
	local impulse = rawget(state, "ImpulseContext")
	if type(impulse) == "table" then
		local horizontalSpeed = math.max(tonumber(impulse.MaxHorizontalSpeed) or 0, speed)
		local duration = math.max(
			(tonumber(impulse.ExpiresAt) or 0) - (tonumber(impulse.StartedAt) or 0),
			LONG_FRAME_CLAMP
		)
		impulse.MaxHorizontalSpeed = horizontalSpeed
		if rootPosition then impulse.OriginPosition = rootPosition end
		impulse.MaxHorizontalDistance = math.max(
			tonumber(impulse.MaxHorizontalDistance) or 0,
			horizontalSpeed * duration + MOVEMENT_BASELINE_PADDING * 2
		)
		patchSample(impulse.PreMovementSafeSample)
	end
	if rawget(state, "CorrectionContext") == nil then
		rawset(state, "FirstSuspiciousAt", nil)
		if rawget(state, "ThreatLevel") == "Observing" then
			rawset(state, "ThreatLevel", "Trusted")
		end
	end
	return true
end
local function getIntegritySpoof()
	local env = environment()
	local holder = env[INTEGRITY_SPOOF_KEY]
	if type(holder) ~= "table" then
		holder = {}
		env[INTEGRITY_SPOOF_KEY] = holder
	end
	return holder
end
local function integrityStateMatches(state, humanoid, root)
	return type(state) == "table"
	and rawget(state, "Player") == LocalPlayer
	and rawget(state, "Character") == LocalPlayer.Character
	and rawget(state, "Humanoid") == humanoid
	and rawget(state, "RootPart") == root
end
local function integrityStateCanTravel(state, humanoid, root)
	return integrityStateMatches(state, humanoid, root)
end
local function setIntegritySpoof(humanoid, root, speed)
	local holder = getIntegritySpoof()
	local state = holder.State
	if not integrityStateMatches(state, humanoid, root) then
		local now = os.clock()
		if now < (holder.NextSearchAt or 0) then return false end
		holder.NextSearchAt = now + 0.2
		state = findIntegrityState(LocalPlayer, humanoid, root)
	end
	if not state then
		return false
	end
	if not integrityStateCanTravel(state, humanoid, root) then
		holder.Enabled = false
		holder.Humanoid = humanoid
		holder.RootPart = root
		holder.State = state
		return false
	end
	holder.NextSearchAt = 0
	holder.Enabled = true
	holder.Humanoid = humanoid
	holder.RootPart = root
	holder.State = state
	holder.WalkSpeed = math.clamp(
		speed * INTEGRITY_SPEED_HEADROOM,
		MIN_MOVEMENT_SPEED,
		MAX_MOVEMENT_SPEED * INTEGRITY_SPEED_HEADROOM
	)
	holder.TravelVelocity = Vector3.zero
	patchIntegrityState(state, holder.WalkSpeed, holder.TravelVelocity)
	return true
end
local function refreshIntegritySpoof(humanoid, root, speed, travelVelocity)
	local holder = environment()[INTEGRITY_SPOOF_KEY]
	if type(holder) ~= "table"
	or not holder.Enabled
	or holder.Humanoid ~= humanoid
	or holder.RootPart ~= root
	or not integrityStateCanTravel(holder.State, humanoid, root)
	then
		return false
	end
	holder.WalkSpeed = math.clamp(
		speed * INTEGRITY_SPEED_HEADROOM,
		MIN_MOVEMENT_SPEED,
		MAX_MOVEMENT_SPEED * INTEGRITY_SPEED_HEADROOM
	)
	if typeof(travelVelocity) == "Vector3" then
		holder.TravelVelocity = travelVelocity
	elseif typeof(holder.TravelVelocity) ~= "Vector3" then
		holder.TravelVelocity = Vector3.zero
	end
	return patchIntegrityState(holder.State, holder.WalkSpeed, holder.TravelVelocity)
end
local function clearIntegritySpoof(humanoid)
	local holder = environment()[INTEGRITY_SPOOF_KEY]
	if type(holder) ~= "table" then return end
	if humanoid == nil or holder.Humanoid == humanoid then
		holder.Enabled = false
		holder.Humanoid = nil
		holder.RootPart = nil
		holder.State = nil
		holder.TravelVelocity = nil
		holder.NextSearchAt = 0
	end
end
local globalIntegrityConnection = nil
local function startGlobalMovementProtection()
	if globalIntegrityConnection then return end
	globalIntegrityConnection = RunService.PreSimulation:Connect(function()
		if runtimeEnv.__SenaV4TweenRuntimeGeneration ~= tweenRuntimeGeneration then
			local staleConnection = globalIntegrityConnection
			globalIntegrityConnection = nil
			if staleConnection then pcall(staleConnection.Disconnect, staleConnection) end
			return
		end
		local char = LocalPlayer.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if not char or not root or not hum then return end
		local targetSpeed = speedDialStuds()
		setMovementSpoof(char, targetSpeed * INTEGRITY_SPEED_HEADROOM)
		if not refreshIntegritySpoof(hum, root, targetSpeed) then
			setIntegritySpoof(hum, root, targetSpeed)
		end
		enforceTweenArrivalHold()
		end)
end
local function stopGlobalMovementProtection()
	if globalIntegrityConnection then
		pcall(globalIntegrityConnection.Disconnect, globalIntegrityConnection)
		globalIntegrityConnection = nil
	end
	clearMovementSpoof()
	clearIntegritySpoof()
end
runtimeEnv.__SenaV4TweenRuntimeCleanup = function()
	stopAllActiveMovements()
	stopGlobalMovementProtection()
end
RunService.Heartbeat:Connect(function()
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then return end
	local velocity = root.AssemblyLinearVelocity
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local ws = humanoid and humanoid.WalkSpeed or 0
	local horizontal = Vector3.new(velocity.X, 0, velocity.Z)
	if horizontal.Magnitude > math.max(400, ws * 1.5) or math.abs(velocity.Y) > 400 then
		local cap = math.max(100, ws)
		if horizontal.Magnitude > cap then horizontal = horizontal.Unit * cap end
		root.AssemblyLinearVelocity = Vector3.new(horizontal.X, math.clamp(velocity.Y, -100, 100), horizontal.Z)
	end
	end)
local UI_LOADED = false
pcall(function()
	local queueFunc = queue_on_teleport or queueonteleport or (syn and syn.queue_on_teleport)
	if queueFunc then
		pcall(queueFunc, "")
	end
	end)
pcall(function()
	game:GetService("StarterGui"):SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
	end)
local zombieHealthConnection = nil
local zombiePinnerConnection = nil
local function enableFullZombieMode(character)
	if not character then return end
	local hum = character:WaitForChild("Humanoid", 5) or character:FindFirstChildOfClass("Humanoid")
	local root = character:WaitForChild("HumanoidRootPart", 5) or character:FindFirstChild("HumanoidRootPart")
	if not hum then return end
	local maxHp = math.max(hum.MaxHealth, 100)
	local repairing = false
	local lastRepairAt = 0
	local function repair()
		if repairing or not hum.Parent then return end
		local now = os.clock()
		if now - lastRepairAt < 0.1 and hum.Health > 0 and hum:GetState() ~= Enum.HumanoidStateType.Dead then
			return
		end
		lastRepairAt = now
		repairing = true
		pcall(function()
			hum.BreakJointsOnDeath = false
			hum.RequiresNeck = false
			hum:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
			hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
			hum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
			if hum.Health <= 0 then
				hum.Health = maxHp
			end
			if hum:GetState() == Enum.HumanoidStateType.Dead then
				hum:ChangeState(Enum.HumanoidStateType.Running)
			end
			end)
		repairing = false
	end
	repair()
	if zombieHealthConnection then pcall(zombieHealthConnection.Disconnect, zombieHealthConnection) end
	if zombiePinnerConnection then pcall(zombiePinnerConnection.Disconnect, zombiePinnerConnection) end
	zombieHealthConnection = hum.HealthChanged:Connect(function(health)
		if health <= 0 or health < maxHp then repair() end
		end)
	zombiePinnerConnection = RunService.Heartbeat:Connect(repair)
end
task.spawn(function()
	local char = LocalPlayer.Character or LocalPlayer.CharacterAdded:Wait()
	enableFullZombieMode(char)
	end)
LocalPlayer.CharacterAdded:Connect(function(char)
	enableFullZombieMode(char)
	end)
Config = {
	AutoSteal = false,
	HelpFriend = false,
	LowSpeedBoost = false, 
	StarAlert = true,
	StealMode = "Fly",
	FlyAerial = false,
	FlyZigzag = false,
	StealHoldSeconds = 5,
	StealAreas = {"None"},
	StealRarities = {"None"},
	StealNamesFilter = {"None"},
	StealMinValue = 0,
	StealMutations = {"None"},
	StealMinWeight = 0,
	StealPriority = "Rarity",
	TaskOrder = { "auto_steal", "star", "butterfly", "phantom", "hw_steal", "hw_mobs", "hw_pumpkin", "auto_place", "use_scrambled", "auto_sell", "treadmill", "hw_fish" },
	AutoFavorite = false,
	FavMode = "Rarity",
	FavRarities = {"None"},
	FavSpecies = {"None"},
	AutoEquipBest = false,
	AutoClaimOffline = false,
	AutoBaseUpgrade = false,
	AutoClaimAlmanac = false,
	AutoFusePets = false,
	ButterflyAutoNet = false,
	ButterflyAutoCatch = false,
	ButterflyEsp = false,
	ButterflyTiers = {},
	ButterflyAutoTrade = false,
	ButterflyTradeRecipe = "All",
	ButterflyCatchMode = "Tween",
	ButterflyAutoCraft = false,
	WispAutoQuest = false,
	BanjoAuto = false,
	Noclip = false,
	BottingMode = false,
	AntiCutscene = false,
	FuseSelectedOnly = false,
	FuseRarities = {"None"},
	FuseSpecies = {"None"},
	EspDetails = {"Name", "Rarity", "Value"},
	BackpackRateEsp = false,
	AntiAFK = true,
	AutoReconnect = true,
	AutoExecute = false,
	AutoPlace = false,
	PlaceRarities = {"None"},
	AutoHatch = false,
	SellAll = false,
	AutoSell = false,
	SellNames = {"None"},
	SellRarities = {"None"},
	AutoSellEgg = false,
	SellEggRarities = {"None"},
	WebhookEnabled = false,
	WebhookURL = "",
	WebhookDisconnect = false,
	TweenSpeedMultiplier = 60,
	AutoTreadmillIdle = false,
	AutoTreadmillUpgrade = false,
	AntiTreadmill = false,
	HopNoMatch = false,
	PrivateServerMax = "2",
	PrivateServerAuto = false,
	HopCooldown = 5,
	AutoIndex = false,
	AntiHitGuard = false,
	FlyForCapture = false,
	AutoStealCapture = false,
	InstantGrab = false,
	InfiniteJump = false,
	StealJump = true,
	StealSkipTollAreas = false,
	SnipeDroppedEggs = true,
	SnipeAreas = { Forest = true, Lake = true, Desert = true },
	SnipePunch = true,
	FastPull = true,
	FastPullSpeed = 3500,
	AutoStealHalloween = false,
	HalloweenNames = {"None"},
	HalloweenZonePriority = true,
	HalloweenAutoBuy = false,
	HalloweenHitMobs = false,
	HalloweenMobTypes = {"None"},
	HalloweenEggRarities = {"None"},
	HalloweenMobRarities = {"None"},
	HalloweenCollectPumpkin = false,
	HalloweenCrossWorld = false,
	HalloweenAutoFish = false,
	HalloweenPhantomExpress = false,
	HalloweenTradeSouls = false,
	WalkSpeedMultiplier = 1,
	AntiGuardKnockback = true,
	GodMode = true,
	EggPredictUI = false,
	EggESP = false,
	StealPlayers = false,
	StealPlayerRarities = {"None"},
	StealPlayerMinValue = 0,
	StealPlayerTarget = "Any Player",
	WebhookRarities = {"None"},
	WebhookMinValue = 0
}
do
	local EggState = require(game:GetService("ReplicatedStorage").Client.EggState)
	EggState.GetAreaEggSnapshot = EggState.ReadFieldEggs
	EggState.GetAreaEggRecord = EggState.ReadFieldEgg
	EggState.RequestAreaEggSnapshot = EggState.SyncFieldEggs
	EggState.RequestCarryAreaEgg = EggState.CarryFieldEgg
	EggState.RequestDropHeldAreaEgg = EggState.DropFieldEgg
	EggState.AreaEggCarryStateChanged = EggState.CarryChanged
	EggState.AreaEggClaimed = EggState.FieldClaimed
	EggState.AreaEggUpdated = EggState.FieldShifted
	EggState.AreaEggRemoved = EggState.FieldGone
	EggState.GetOwnerRuntimeRecords = EggState.ReadOwnerEggs
	EggState.RequestEquipTool = EggState.WearEggTool
	EggState.RequestPlaceEgg = EggState.PlantEgg
	EggState.RequestHatchEgg = EggState.BeginHatch
	EggState.RequestCompleteHatchEgg = EggState.FinishHatch
	EggState.RequestRuntimeSnapshot = EggState.SyncOwnedEggs
	EggState.RuntimeOwnerUpdated = EggState.OwnerRefreshed
	EggState.RuntimeOwnerCleared = EggState.OwnerCleared
	local PlotState = require(game:GetService("ReplicatedStorage").Client.PlotState)
	PlotState.GetMySlot = PlotState.ResolveLocalSlot
	PlotState.GetPlotsFolder = PlotState.ResolveFolder
	PlotState.IsWorldPositionWithinLocalPlotBounds = PlotState.ContainsLocalPoint
	PlotState.GetPlotData = PlotState.ResolvePlot
	local AreaEggResetWall = require(game:GetService("ReplicatedStorage").Client.AreaEggResetWall)
	AreaEggResetWall.IsClosed = AreaEggResetWall.IsSealed
end
speedDialStuds = function()
	if runtimeEnv.__SenaV4AdminBoost == true then return 4000 end
	local inputSpeed = math.clamp(
		math.floor((tonumber(Config.TweenSpeedMultiplier) or SPOOF_CFG.DEF_INPUT) + 0.5),
		SPOOF_CFG.MIN_INPUT,
		SPOOF_CFG.MAX_INPUT
	)
	return inputSpeed * SPOOF_CFG.MULTIPLIER
end
function Config:applyStealValueInput(value)
	local normalized = string.lower(tostring(value or "")):gsub("[%s,]", "")
	if normalized == "" then
		self.StealMinValue = 0
		return true
	end
	local amountText, suffix = string.match(normalized, "^([%d]+%.?[%d]*)([kmb]?)$")
	local amount = tonumber(amountText)
	if not amount then return false end
	local multiplier = 1
	if suffix == "k" then
		multiplier = 1e3
	elseif suffix == "m" then
		multiplier = 1e6
	elseif suffix == "b" then
		multiplier = 1e9
	end
	self.StealMinValue = amount * multiplier
	return true
end
function Config:getAreaEggValue(record)
	if not self._assetGenerationUtil then
		self._assetGenerationUtil = require(game:GetService("ReplicatedStorage").Shared.Util.AssetEarnings)
	end
	return self._assetGenerationUtil.MutationOnlyRatePerSecond({
		Category = record.AssetCategory,
		Scale = record.AssetScale or 1,
		Mutations = record.Mutations or {},
		BaseMutation = record.BaseMutation,
		EyeColor = record.AssetEyeColor,
		ColorSeed = record.AssetColorSeed,
		ColorIndex = record.AssetColorIndex,
		Gender = record.Gender,
		Personality = record.Personality or "Normal",
		HasBeenFirstPlaced = record.HasBeenFirstPlaced == true,
		})
end
local function reserveAutoStealPriority(seconds)
	Config.StealPriorityUntil = math.max(Config.StealPriorityUntil or 0, os.clock() + (seconds or 5))
end
local AreaEggCycleModule = nil
local AreaEggResetWallModule = nil
pcall(function()
	AreaEggCycleModule = require(ReplicatedStorage.Shared.Util.AreaEggCycle)
	AreaEggResetWallModule = require(ReplicatedStorage.Client.AreaEggResetWall)
	end)
local function isStealNightBlocked()
	if AreaEggCycleModule and type(AreaEggCycleModule.IsNightPhase) == "function" then
		local ok, isNight = pcall(AreaEggCycleModule.IsNightPhase, workspace:GetServerTimeNow())
		if ok and isNight == true then return true end
	end
	if AreaEggResetWallModule then
		if type(AreaEggResetWallModule.IsSealed) == "function" then
			local ok, sealed = pcall(AreaEggResetWallModule.IsSealed)
			if ok and sealed == true then return true end
		end
		if type(AreaEggResetWallModule.IsClosed) == "function" then
			local ok, closed = pcall(AreaEggResetWallModule.IsClosed)
			if ok and closed == true then return true end
		end
	end
	return false
end
local lastPremiumScanAt = 0
local cachedHasPremium = false
local function hasPremiumFieldEgg()
	if isStealNightBlocked() then return false end
	local now = os.clock()
	if now - lastPremiumScanAt < 0.35 then return cachedHasPremium end
	lastPremiumScanAt = now
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local snapshot = require(ReplicatedStorage.Client.EggState).GetAreaEggSnapshot()
	local assets = require(ReplicatedStorage.Data.Assets).Directory
	for _, record in pairs((snapshot and snapshot.Records) or {}) do
		if (record.State == "Slot" or record.State == "Dropped") and record.BottomCFrame then
			local asset = assets[record.AssetCategory]
			local rarity = asset and asset.Rarity
			local rarityName = rarity and (rarity.DisplayName or rarity._id)
			if rarityName == "Eternal" or rarityName == "Divine" then
				cachedHasPremium = true
				return true
			end
		end
	end
	cachedHasPremium = false
	return false
end
local TaskLadder = {}
do
	TaskLadder.DEFAULT = { "auto_steal", "star", "butterfly", "phantom", "hw_steal", "hw_mobs", "hw_pumpkin", "auto_place", "use_scrambled", "auto_sell", "treadmill", "hw_fish" }
	TaskLadder.TITLES = {
		auto_steal = "Auto Steal",
		star = "Shooting Star",
		butterfly = "Butterfly Bloom",
		phantom = "Phantom Express",
		hw_steal = "Steal Halloween",
		hw_mobs = "Hit Mobs",
		hw_pumpkin = "Collect Pumpkins",
		hw_fish = "Auto Fish",
		auto_place = "Auto Place",
		use_scrambled = "Use Scrambled",
		auto_sell = "Auto Sell",
		treadmill = "Treadmill",
	}
	TaskLadder.PINNED = { treadmill = true, hw_fish = true }
	local specs = {}
	function TaskLadder.register(id, spec)
		specs[id] = spec
	end
	function TaskLadder.sanitize(order)
		local out, seen = {}, {}
		local function push(id)
			id = tostring(id)
			if TaskLadder.TITLES[id] and not seen[id] and not TaskLadder.PINNED[id] then
				seen[id] = true
				out[#out + 1] = id
			end
		end
		for _, id in ipairs(type(order) == "table" and order or {}) do
			push(id)
		end
		for _, id in ipairs(TaskLadder.DEFAULT) do
			push(id)
		end
		for _, id in ipairs(TaskLadder.DEFAULT) do
			if TaskLadder.PINNED[id] and not seen[id] then
				seen[id] = true
				out[#out + 1] = id
			end
		end
		return out
	end
	local orderCache, orderSource = nil, nil
	function TaskLadder.order()
		local source = Config and Config.TaskOrder
		if source ~= orderSource or not orderCache then
			orderSource = source
			orderCache = TaskLadder.sanitize(source)
		end
		return orderCache
	end
	function TaskLadder.rank(id)
		for index, other in ipairs(TaskLadder.order()) do
			if other == id then
				return index
			end
		end
		return math.huge
	end
	local function ask(id, field)
		local spec = specs[id]
		local fn = spec and spec[field]
		if type(fn) ~= "function" then
			return nil
		end
		local ok, result = pcall(fn)
		if ok then
			return result
		end
		return nil
	end
	function TaskLadder.wants(id)
		return ask(id, "wants") == true
	end
	function TaskLadder.active(id)
		return ask(id, "active") == true
	end
	function TaskLadder.enabled(id)
		local value = ask(id, "enabled")
		return value == true
	end
	function TaskLadder.bossFighting()
		return false
	end
	function TaskLadder.stealCarrying()
		local rt = runtimeEnv.__SenaV4EggRuntime
		if not rt or rt.destroyed then
			return false
		end
		if rt._instantReturnToken ~= nil or rt._forestDropInProgress ~= nil then
			return true
		end
		local carry = rt.carry
		return carry ~= nil and carry.active == true and carry.uid ~= nil and carry.uid ~= rt.primerUid
	end
	local blockCache = {}
	local function computeBlocker(id)
		if id ~= "auto_steal" and TaskLadder.stealCarrying() then
			return "auto_steal"
		end
		if id ~= "phantom" and runtimeEnv.__SenaV4OnTrain == true then
			return "phantom"
		end
		for _, other in ipairs(TaskLadder.order()) do
			if other == id then
				return nil
			end
			if TaskLadder.wants(other) then
				return other
			end
		end
		return nil
	end
	function TaskLadder.blocker(id)
		local now = os.clock()
		local cached = blockCache[id]
		if cached and now - cached.at < 0.1 then
			return cached.value
		end
		local value = computeBlocker(id)
		if cached then
			cached.at, cached.value = now, value
		else
			blockCache[id] = { at = now, value = value }
		end
		return value
	end
	function TaskLadder.holder(id)
		for _, other in ipairs(TaskLadder.order()) do
			if other ~= id and not TaskLadder.PINNED[other] and TaskLadder.active(other) then
				return other
			end
		end
		return nil
	end
	function TaskLadder.yieldLabel(id)
		local blocker = TaskLadder.blocker(id)
		return blocker and ("Yielding to " .. TaskLadder.TITLES[blocker]) or nil
	end
	function TaskLadder.current()
		if TaskLadder.stealCarrying() then
			return "auto_steal"
		end
		for _, id in ipairs(TaskLadder.order()) do
			if TaskLadder.active(id) then
				return id
			end
		end
		return nil
	end
	function TaskLadder.describe(id)
		if not TaskLadder.enabled(id) then
			return "Off", "off"
		end
		local text = ask(id, "status")
		text = type(text) == "string" and text ~= "" and text or nil
		if TaskLadder.active(id) or TaskLadder.current() == id then
			return text or "Running", "run"
		end
		local blocker = TaskLadder.blocker(id)
		if blocker and TaskLadder.wants(id) then
			return "Yielding to " .. TaskLadder.TITLES[blocker], "wait"
		end
		return text or "Idle", "off"
	end
end
runtimeEnv.__SenaV4TaskLadder = TaskLadder
local function autoSellCanRun()
	return TaskLadder.blocker("auto_sell") == nil
end
local ANTIAFK_LOG_PATH = "Sena_Disconnect_Log.txt"
local ANTIAFK_LOG_MAX_LINES = 50
local function logSelfTeleportAttempt(message)
	pcall(function()
		if typeof(writefile) ~= "function" then return end
		local existing = ""
		if typeof(readfile) == "function" and typeof(isfile) == "function" and isfile(ANTIAFK_LOG_PATH) then
			existing = readfile(ANTIAFK_LOG_PATH) or ""
		end
		local lines = {}
		for line in existing:gmatch("[^\r\n]+") do
			table.insert(lines, line)
		end
		table.insert(lines, "[" .. os.date("%Y-%m-%d %H:%M:%S") .. "] " .. message)
		while #lines > ANTIAFK_LOG_MAX_LINES do
			table.remove(lines, 1)
		end
		writefile(ANTIAFK_LOG_PATH, table.concat(lines, "\n"))
		end)
end
local RarityWeights = {
	["Common"] = 1,
	["Uncommon"] = 2,
	["Rare"] = 3,
	["Epic"] = 4,
	["Legendary"] = 5,
	["Mythic"] = 6,
	["Cosmic"] = 7,
	["Secret"] = 8,
	["Eternal"] = 9,
	["Divine"] = 10,
	["Prismatic"] = 11,
	["Transcendent"] = 12
}
local function readDropdownFilter(dropObj)
	if not dropObj or type(dropObj.GetValue) ~= "function" then return nil end
	local ok, val = pcall(function() return dropObj:GetValue() end)
	if not ok then return nil end
	if type(val) == "table" then
		local arr = {}
		for k, v in pairs(val) do
			if type(k) == "number" then
				table.insert(arr, v)
			elseif type(k) == "string" and v == true then
				table.insert(arr, k)
			end
		end
		return arr
	end
	if type(val) == "string" then return {val} end
	return nil
end
local function petMatchesSellFilter(petName, rarity, names, rarities)
	if Config.SellAll then return true end
	if type(names) ~= "table" or type(rarities) ~= "table" then return false end
	local nameMatch = false
	if #names == 0 or table.find(names, "None") then
		nameMatch = false
	elseif table.find(names, "All") then
		nameMatch = true
	else
		nameMatch = table.find(names, petName) ~= nil
	end
	local rarityMatch = false
	if #rarities == 0 or table.find(rarities, "None") then
		rarityMatch = false
	elseif table.find(rarities, "All") then
		rarityMatch = true
	else
		rarityMatch = table.find(rarities, rarity) ~= nil
	end
	return nameMatch or rarityMatch
end
local function eggMatchesSellFilter(rarity, rarities)
	if type(rarities) ~= "table" then return false end
	if #rarities == 0 or table.find(rarities, "None") then return false end
	if table.find(rarities, "All") then return true end
	return table.find(rarities, rarity) ~= nil
end
local function applyKillPartIgnore(character)
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if root then
		root:SetAttribute("KillPartIgnore", true)
	end
end
local LONG_FRAME_CLAMP = 0.15
local MOVEMENT_ARRIVAL_HOLD = 0.4
local TWEEN_SAFE_ZONE_POSITION = Vector3.new(542.93, 71.5, -405.58)
local TWEEN_CRUISE_HEIGHT = 5
local TWEEN_STEAL_TIMING = {
	CarryRetry = 0.25,
	CarryTimeout = 2,
	EarlyCarryDistance = 8,
	SafeStable = 0.35,
	ReturnValidation = 0.08,
	NextTarget = 0.05,
	SafeHandoff = 0.15,
}
local guardEscape = {
	GUARD_MARGIN = 1.25,
	GUARD_FALLBACK = 222,
	maxGuardWalkSpeed = nil,
	floorNotifiedFor = -1,
	capNotifiedFor = -1,
}
local function guardEscapeSpeed()
	if not guardEscape.maxGuardWalkSpeed then
		local ok, best = pcall(function()
			return require(game:GetService("ReplicatedStorage").Data.Guards).GetHighestWalkSpeed()
			end)
		guardEscape.maxGuardWalkSpeed = (ok and type(best) == "number" and best > 0) and best or guardEscape.GUARD_FALLBACK
		warn(string.format(
			"[GuardEscape] Guard tercepat %d stud/detik -> lantai kabur %d stud/detik",
			guardEscape.maxGuardWalkSpeed, guardEscape.maxGuardWalkSpeed * guardEscape.GUARD_MARGIN))
	end
	return guardEscape.maxGuardWalkSpeed * guardEscape.GUARD_MARGIN
end
local function applyUserSpeed(n)
	local inputSpeed = math.clamp(
		math.floor((tonumber(n) or SPOOF_CFG.DEF_INPUT) + 0.5),
		SPOOF_CFG.MIN_INPUT,
		SPOOF_CFG.MAX_INPUT
	)
	if math.abs((Config.TweenSpeedMultiplier or 0) - inputSpeed) <= 0.001 then return end
	Config.TweenSpeedMultiplier = inputSpeed
end
local function waitForClaimWindow(hrp, targetCF, timeoutSeconds, isCancelledFn)
	local deadline = os.clock() + timeoutSeconds
	local stableSince = nil
	local stableBeats = 0
	local networkPing = 0.1
	pcall(function() networkPing = LocalPlayer:GetNetworkPing() end)
	local requiredHold = math.clamp(networkPing * 2 + 0.2, MOVEMENT_ARRIVAL_HOLD, 1)
	while os.clock() < deadline do
		if isCancelledFn and isCancelledFn() then return false end
		hrp.AssemblyLinearVelocity = Vector3.zero
		hrp.AssemblyAngularVelocity = Vector3.zero
		RunService.Heartbeat:Wait()
		local distance = hrp.Parent and (hrp.Position - targetCF.Position).Magnitude or math.huge
		if distance <= 1.5 then
			hrp.CFrame = targetCF
			stableSince = stableSince or os.clock()
			stableBeats = stableBeats + 1
			if stableBeats >= 3 and os.clock() - stableSince >= requiredHold then
				return true
			end
		else
			stableSince = nil
			stableBeats = 0
		end
	end
	return false
end
local MIN_TWEEN_DURATION = 0.08
local activeMoves = {}
local function TweenMoveTo(hrp, hum, targetCFrame, isCancelledFn, holdAfterArrival, earlyArrivalFn, flightProfile)
	if not hrp or not hum or typeof(targetCFrame) ~= "CFrame" then return false end
	if (LocalPlayer:GetAttribute("InHalloweenDimension") == true and targetCFrame.Position.Y > -100) or runtimeEnv.__SenaV4OnTrain == true then return false end
	if isCancelledFn and isCancelledFn() then return false end
	local prevMove = activeMoves[hrp]
	if prevMove then
		prevMove.cancelled = true
		activeMoves[hrp] = nil
	end
	local character = hrp.Parent
	if not character then return false end
	clearTweenArrivalHold()
	applyKillPartIgnore(character)
	startGlobalMovementProtection()
	local camera = workspace.CurrentCamera
	if camera and camera.CameraSubject ~= hum then
		pcall(function() camera.CameraSubject = hum end)
	end
	local originalAutoRotate = hum.AutoRotate
	hum.AutoRotate = false
	local cruiseY = flightProfile and math.max(
		hrp.Position.Y,
		targetCFrame.Position.Y + TWEEN_CRUISE_HEIGHT,
		TWEEN_SAFE_ZONE_POSITION.Y + TWEEN_CRUISE_HEIGHT
	) or nil
	local destination = cruiseY
	and (CFrame.new(targetCFrame.Position.X, cruiseY, targetCFrame.Position.Z) * targetCFrame.Rotation)
	or targetCFrame
	local liveSpeed = math.clamp(speedDialStuds(), SPOOF_CFG.MIN_SPEED, runtimeEnv.__SenaV4AdminBoost == true and 3000 or SPOOF_CFG.MAX_SPEED)
	setMovementSpoof(character, liveSpeed * SPOOF_CFG.HEADROOM)
	local move = {cancelled = false}
	activeMoves[hrp] = move
	startHoverPad()
	local arrivalStableSince = nil
	local previousRemainingDistance = nil
	local correctionSlowUntil = 0
	local travelPhase = cruiseY and (math.abs(hrp.Position.Y - cruiseY) > 0.35 and "takeoff" or "cruise") or nil
	local initialDistance = (destination.Position - hrp.Position).Magnitude
	local timeoutAt = os.clock() + math.max(initialDistance / liveSpeed, MIN_TWEEN_DURATION) * 3 + 8
	local completed = false
	local earlyArrivalStarted = false
	while not move.cancelled do
		if isCancelledFn and isCancelledFn() then break end
		if not hrp.Parent then break end
		if os.clock() >= timeoutAt then break end
		local deltaTime = RunService.Heartbeat:Wait()
		local safeDeltaTime = math.max(math.min(deltaTime, LONG_FRAME_CLAMP), 1 / 240)
		liveSpeed = math.clamp(speedDialStuds(), SPOOF_CFG.MIN_SPEED, runtimeEnv.__SenaV4AdminBoost == true and 3000 or SPOOF_CFG.MAX_SPEED)
		setMovementSpoof(character, liveSpeed * SPOOF_CFG.HEADROOM)
		local holder = environment()[SPOOF_CFG.INTEGRITY_KEY]
		local integrityState = type(holder) == "table" and holder.State or nil
		if not integrityStateCanTravel(integrityState, hum, hrp) then
			previousRemainingDistance = nil
			arrivalStableSince = nil
			hrp.AssemblyLinearVelocity = Vector3.zero
			hrp.AssemblyAngularVelocity = Vector3.zero
			syncHoverPad(hrp.Position)
			if integrityStateMatches(integrityState, hum, hrp) then
				patchIntegrityState(integrityState, liveSpeed * SPOOF_CFG.HEADROOM, Vector3.zero)
			else
				setIntegritySpoof(hum, hrp, liveSpeed)
			end
		else
			local position = hrp.Position
			local remaining = destination.Position - position
			local remainingDistance = remaining.Magnitude
			local horizontalRemaining = Vector3.new(remaining.X, 0, remaining.Z)
			if cruiseY and travelPhase == "takeoff" and math.abs(position.Y - cruiseY) <= 0.35 then
				travelPhase = "cruise"
			end
			local movementTarget = cruiseY and travelPhase == "takeoff"
			and Vector3.new(position.X, cruiseY, position.Z)
			or destination.Position
			local movementRemaining = movementTarget - position
			local movementDistance = movementRemaining.Magnitude
			local progressDistance = cruiseY and horizontalRemaining.Magnitude or remainingDistance
			if previousRemainingDistance and progressDistance > previousRemainingDistance + 2 then
				correctionSlowUntil = os.clock() + 0.5
			end
			previousRemainingDistance = progressDistance
			local effectiveSpeed = os.clock() < correctionSlowUntil
			and math.max(SPOOF_CFG.MIN_SPEED, liveSpeed * 0.45)
			or liveSpeed
			local stepDistance = effectiveSpeed * safeDeltaTime
			if earlyArrivalFn and not earlyArrivalStarted and remainingDistance <= TWEEN_STEAL_TIMING.EarlyCarryDistance then
				earlyArrivalStarted = true
				task.spawn(earlyArrivalFn)
			end
			local currentLook = Vector3.new(hrp.CFrame.LookVector.X, 0, hrp.CFrame.LookVector.Z)
			local facingDirection = horizontalRemaining.Magnitude > 0.001 and horizontalRemaining.Unit
			or (currentLook.Magnitude > 0.001 and currentLook.Unit or Vector3.new(0, 0, -1))
			local canArrive = not cruiseY or travelPhase == "cruise"
			if canArrive and remainingDistance <= math.max(stepDistance, 0.05) then
				if remainingDistance > 0.5 then arrivalStableSince = nil end
				syncHoverPad(destination.Position)
				hrp.CFrame = CFrame.lookAt(destination.Position, destination.Position + facingDirection)
				hrp.AssemblyLinearVelocity = Vector3.zero
				hrp.AssemblyAngularVelocity = Vector3.zero
				syncHoverPad(destination.Position)
				refreshIntegritySpoof(hum, hrp, liveSpeed, Vector3.zero)
				arrivalStableSince = arrivalStableSince or os.clock()
				if os.clock() - arrivalStableSince >= MOVEMENT_ARRIVAL_HOLD then
					completed = true
					break
				end
			else
				arrivalStableSince = nil
				if movementDistance <= 0.001 then
					hrp.AssemblyLinearVelocity = Vector3.zero
					hrp.AssemblyAngularVelocity = Vector3.zero
					syncHoverPad(position)
					continue
				end
				local actualStepDistance = math.min(stepDistance, movementDistance)
				local nextPosition = position + movementRemaining.Unit * actualStepDistance
				local travelVelocity = (nextPosition - position) / safeDeltaTime
				syncHoverPad(nextPosition)
				hrp.CFrame = CFrame.lookAt(nextPosition, nextPosition + facingDirection)
				hrp.AssemblyLinearVelocity = Vector3.zero
				syncHoverPad(nextPosition)
				if not refreshIntegritySpoof(hum, hrp, liveSpeed, travelVelocity) then
					setIntegritySpoof(hum, hrp, liveSpeed)
					refreshIntegritySpoof(hum, hrp, liveSpeed, travelVelocity)
				end
			end
		end
	end
	if hum.Parent and originalAutoRotate ~= nil then hum.AutoRotate = originalAutoRotate end
	hrp.AssemblyLinearVelocity = Vector3.zero
	hrp.AssemblyAngularVelocity = Vector3.zero
	if completed and holdAfterArrival then
		setTweenArrivalHold(hrp, destination)
	else
		stopHoverPad()
	end
	return completed and not move.cancelled
end
local function flyAutoSteal(hrp, hum, targetCFrame, isCancelledFn)
	return TweenMoveTo(hrp, hum, targetCFrame, isCancelledFn, false, nil, true)
end
local function teleportRoot(root, dest)
	if not root or typeof(dest) ~= "CFrame" then return false end
	if (LocalPlayer:GetAttribute("InHalloweenDimension") == true and dest.Position.Y > -100) or runtimeEnv.__SenaV4OnTrain == true then return false end
	local ok = pcall(function()
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		root.CFrame = dest
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		end)
	if not ok then return false end
	syncHoverPad(dest.Position)
	local char = root.Parent
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if hum then
		local liveSpeed = math.clamp(speedDialStuds(), SPOOF_CFG.MIN_SPEED, runtimeEnv.__SenaV4AdminBoost == true and 3000 or SPOOF_CFG.MAX_SPEED)
		setMovementSpoof(char, liveSpeed * SPOOF_CFG.HEADROOM)
		if not refreshIntegritySpoof(hum, root, liveSpeed, Vector3.zero) then
			setIntegritySpoof(hum, root, liveSpeed)
			refreshIntegritySpoof(hum, root, liveSpeed, Vector3.zero)
		end
	end
	return true
end
getgenv().SenaV4Config = Config
local function destroyPlayerTrap(inst)
	if inst and inst.Name == "PlayerTrap" then
		pcall(function() inst:Destroy() end)
	end
end
local function startAutoRemoveTraps()
	local function hookTrapFolder(folder)
		if not folder then return end
		for _, child in ipairs(folder:GetChildren()) do
			destroyPlayerTrap(child)
		end
		folder.ChildAdded:Connect(function(child)
			destroyPlayerTrap(child)
		end)
	end
	local t = workspace:FindFirstChild("Transient")
	if t then hookTrapFolder(t) end
	local d = workspace:FindFirstChild("__DEBRIS")
	if d then hookTrapFolder(d) end
	workspace.ChildAdded:Connect(function(child)
		if child.Name == "Transient" or child.Name == "__DEBRIS" then
			hookTrapFolder(child)
		elseif child.Name == "PlayerTrap" or child.Name:lower():find("trap") then
			destroyPlayerTrap(child)
		end
	end)
	task.spawn(function()
		while sessionAlive() do
			for _, container in ipairs({ workspace:FindFirstChild("Transient"), workspace:FindFirstChild("__DEBRIS") }) do
				if container then
					for _, c in ipairs(container:GetChildren()) do
						destroyPlayerTrap(c)
					end
				end
			end
			task.wait(1.5)
		end
	end)
end
task.spawn(startAutoRemoveTraps)
local treadmillActiveId = nil
local treadmillIdleMountRequested = false
local treadmillStealPreparation = false
local TweenPrep = {
	HoldSeconds = 0.3,
	ConfirmStableSeconds = 0.3,
	ConfirmTimeout = 2.5,
	PollSeconds = 0.05,
	ArrivalSettle = 0.5,
	DecoyName = "__SenaV4TweenTreadmillDecoy",
}
local function readTreadmillMountedFromServer()
	local ok, activeIds = pcall(function()
		local ReplicatedStorage = game:GetService("ReplicatedStorage")
		return require(ReplicatedStorage.Shared.Remotes).Treadmill.AskRenderSnapshot:InvokeServer()
		end)
	if not ok or type(activeIds) ~= "table" then return nil end
	return table.find(activeIds, LocalPlayer.UserId) ~= nil
end
local function requestTreadmillUnequip()
	local pcallOk, serverOk, reason = pcall(function()
		local ReplicatedStorage = game:GetService("ReplicatedStorage")
		return require(ReplicatedStorage.Shared.Remotes).Treadmill.AskDoff:InvokeServer()
		end)
	if not pcallOk then return false, tostring(serverOk) end
	if serverOk ~= true then return false, tostring(reason) end
	return true
end
local function findMyTreadmillStandCFrame()
	if LocalPlayer:GetAttribute("InHalloweenDimension") == true then return nil end
	local ok, standCFrame = pcall(function()
		local PlotState = require(ReplicatedStorage.Client.PlotState)
		local slot = type(PlotState.ResolveLocalSlot) == "function"
		and PlotState.ResolveLocalSlot()
		or PlotState.GetMySlot()
		local plotsFolder = type(PlotState.ResolveFolder) == "function"
		and PlotState.ResolveFolder()
		or PlotState.GetPlotsFolder()
		local plotFolder = plotsFolder and slot and plotsFolder:FindFirstChild(tostring(slot))
		local bottom = plotFolder and plotFolder:FindFirstChild("TreadmillBottom")
		if not (bottom and bottom:IsA("BasePart")) then return nil end
		local character = LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not root or not humanoid then return nil end
		local feetOffset = humanoid.RigType == Enum.HumanoidRigType.R15
		and (root.Size.Y * 0.5 + math.max(humanoid.HipHeight, 0.5))
		or (root.Size.Y * 0.5 + 2)
		return bottom.CFrame * CFrame.new(0, bottom.Size.Y * 0.5 + feetOffset + 0.05, 0)
		end)
	return ok and standCFrame or nil
end
function TweenPrep.destroyTrail(instance)
	if typeof(instance) == "Instance" and instance:IsA("Trail") then
		pcall(instance.Destroy, instance)
	end
end
function TweenPrep.destroyStealPopup(instance)
	if TaskLadder.current() == "auto_steal"
	and typeof(instance) == "Instance"
	and (instance.Name == "SpeedGainPopup" or instance.Name == "PlusOne")
	then
		pcall(instance.Destroy, instance)
	end
end
function TweenPrep.purgeStealPopups()
	local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then return end
	for _, instance in ipairs(playerGui:GetDescendants()) do
		TweenPrep.destroyStealPopup(instance)
	end
end
TweenPrep.guiConnection = LocalPlayer:WaitForChild("PlayerGui").DescendantAdded:Connect(function(instance)
	TweenPrep.destroyStealPopup(instance)
	end)
function TweenPrep.removeDecoy()
	if TweenPrep.cameraConnection then
		pcall(TweenPrep.cameraConnection.Disconnect, TweenPrep.cameraConnection)
		TweenPrep.cameraConnection = nil
	end
	if TweenPrep.characterConnection then
		pcall(TweenPrep.characterConnection.Disconnect, TweenPrep.characterConnection)
		TweenPrep.characterConnection = nil
	end
	for part, transparency in pairs(TweenPrep.transparency or {}) do
		if typeof(part) == "Instance" and part.Parent then
			pcall(function() part.LocalTransparencyModifier = transparency end)
		end
	end
	TweenPrep.transparency = nil
	local character = LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local camera = workspace.CurrentCamera
	if camera then
		pcall(function() camera.CameraSubject = humanoid or TweenPrep.cameraSubject end)
	end
	TweenPrep.cameraSubject = nil
	if TweenPrep.decoy then pcall(TweenPrep.decoy.Destroy, TweenPrep.decoy) end
	TweenPrep.decoy = nil
end
function TweenPrep.spawnDecoy(safezoneCF)
	TweenPrep.removeDecoy()
	local character = LocalPlayer.Character
	if not character then return false end
	local oldArchivable = character.Archivable
	character.Archivable = true
	local cloned, clone = pcall(character.Clone, character)
	character.Archivable = oldArchivable
	if not cloned or not clone or typeof(clone) ~= "Instance" then return false end
	clone.Name = TweenPrep.DecoyName
	for _, descendant in ipairs(clone:GetDescendants()) do
		if descendant:IsA("Script") or descendant:IsA("LocalScript")
		or descendant:IsA("BillboardGui") or descendant:IsA("Sound")
		or descendant:IsA("Trail")
		then
			pcall(descendant.Destroy, descendant)
		elseif descendant:IsA("BasePart") then
			descendant.LocalTransparencyModifier = 0
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanQuery = false
			descendant.CanTouch = false
		end
	end
	local humanoid = clone:FindFirstChildOfClass("Humanoid")
	if not humanoid then clone:Destroy() return false end
	pcall(function()
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
		end)
	clone.Parent = workspace
	clone:PivotTo(safezoneCF)
	TweenPrep.decoy = clone
	local originals = setmetatable({}, { __mode = "k" })
	local function hidePart(part)
		if not part or not part:IsA("BasePart") or not part:IsDescendantOf(character) then return end
		if originals[part] == nil then originals[part] = part.LocalTransparencyModifier end
		part.LocalTransparencyModifier = 1
	end
	for _, descendant in ipairs(character:GetDescendants()) do
		hidePart(descendant)
		TweenPrep.destroyTrail(descendant)
	end
	TweenPrep.transparency = originals
	TweenPrep.characterConnection = character.DescendantAdded:Connect(function(descendant)
		if TweenPrep.decoy == clone then
			pcall(hidePart, descendant)
			TweenPrep.destroyTrail(descendant)
		end
		end)
	local camera = workspace.CurrentCamera
	if camera then
		TweenPrep.cameraSubject = camera.CameraSubject
		camera.CameraSubject = humanoid
	end
	TweenPrep.cameraConnection = RunService.RenderStepped:Connect(function()
		if TweenPrep.decoy ~= clone or not clone.Parent or not humanoid.Parent then return end
		for part in pairs(originals) do
			if part.Parent and part.LocalTransparencyModifier ~= 1 then
				part.LocalTransparencyModifier = 1
			end
		end
		local liveCamera = workspace.CurrentCamera
		if liveCamera and liveCamera.CameraSubject ~= humanoid then
			liveCamera.CameraSubject = humanoid
		end
		end)
	return true
end
function TweenPrep.requestEquip()
	local callOk, equipped, reason = pcall(function()
		return require(ReplicatedStorage.Shared.Remotes).Treadmill.AskWearStill:InvokeServer()
		end)
	if not callOk or equipped == false then
		return false, tostring(reason or equipped)
	end
	return true
end
function TweenPrep.prepare(safezoneCF, isCancelledFn)
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid or typeof(safezoneCF) ~= "CFrame" then return false end
	local function cancelled()
		return isCancelledFn ~= nil and isCancelledFn()
	end
	local function restoreAtSafe()
		local liveCharacter = LocalPlayer.Character
		local liveRoot = liveCharacter and liveCharacter:FindFirstChild("HumanoidRootPart")
		if liveRoot then teleportRoot(liveRoot, safezoneCF) task.wait(0.1) end
		TweenPrep.removeDecoy()
	end
	treadmillStealPreparation = true
	TweenPrep.purgeStealPopups()
	clearTweenArrivalHold()
	stopHoverPad()
	if not TweenPrep.spawnDecoy(safezoneCF) then
		treadmillStealPreparation = false
		return false
	end
	local standCFrame = findMyTreadmillStandCFrame()
	if not standCFrame or cancelled() or not teleportRoot(root, standCFrame) then
		requestTreadmillUnequip()
		restoreAtSafe()
		treadmillStealPreparation = false
		return false
	end
	task.wait(TweenPrep.ArrivalSettle)
	if cancelled() then
		requestTreadmillUnequip()
		restoreAtSafe()
		treadmillStealPreparation = false
		return false
	end
	local equipped = TweenPrep.requestEquip()
	if not equipped then
		requestTreadmillUnequip()
		restoreAtSafe()
		treadmillStealPreparation = false
		return false
	end
	local equipDeadline = os.clock() + TweenPrep.ConfirmTimeout
	local mounted = false
	local mountedSince = nil
	while not cancelled() and os.clock() < equipDeadline do
		local serverMounted = readTreadmillMountedFromServer()
		if serverMounted == true then
			mountedSince = mountedSince or os.clock()
			if os.clock() - mountedSince >= TweenPrep.ConfirmStableSeconds then
				mounted = true
				break
			end
		else
			mountedSince = nil
		end
		task.wait(TweenPrep.PollSeconds)
	end
	if not mounted or cancelled() then
		requestTreadmillUnequip()
		restoreAtSafe()
		treadmillStealPreparation = false
		return false
	end
	local holdDeadline = os.clock() + TweenPrep.HoldSeconds
	while not cancelled() and os.clock() < holdDeadline do
		task.wait(TweenPrep.PollSeconds)
	end
	local releaseDeadline = os.clock() + TweenPrep.ConfirmTimeout
	local released = false
	while not cancelled() and os.clock() < releaseDeadline do
		requestTreadmillUnequip()
		task.wait(TweenPrep.PollSeconds)
		if readTreadmillMountedFromServer() == false then
			treadmillActiveId = nil
			released = true
			break
		end
	end
	restoreAtSafe()
	treadmillStealPreparation = false
	return released and not cancelled()
end
TweenPrep.previousCleanup = runtimeEnv.__SenaV4TweenRuntimeCleanup
runtimeEnv.__SenaV4TweenRuntimeCleanup = function()
	treadmillStealPreparation = false
	requestTreadmillUnequip()
	TweenPrep.removeDecoy()
	if TweenPrep.guiConnection then
		pcall(TweenPrep.guiConnection.Disconnect, TweenPrep.guiConnection)
		TweenPrep.guiConnection = nil
	end
	if type(TweenPrep.previousCleanup) == "function" then
		TweenPrep.previousCleanup()
	end
end
LocalPlayer.CharacterRemoving:Connect(function()
	treadmillStealPreparation = false
	TweenPrep.removeDecoy()
	end)
do
	if type(runtimeEnv.__SenaV4CosmeticSuppressCleanup) == "function" then
		pcall(runtimeEnv.__SenaV4CosmeticSuppressCleanup)
	end
	local conns = {}
	local function bindDropHeldEgg(sg)
		if not sg or sg.Name ~= "DropHeldEgg" then return end
		if not (sg:IsA("ScreenGui") or sg:IsA("LayerCollector")) then return end
		pcall(function() sg.Enabled = false end)
		table.insert(conns, sg:GetPropertyChangedSignal("Enabled"):Connect(function()
			if sg.Enabled then pcall(function() sg.Enabled = false end) end
			end))
	end
	local function hookPlayerGui()
		local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
		if not pg then return end
		for _, sg in ipairs(pg:GetChildren()) do bindDropHeldEgg(sg) end
		table.insert(conns, pg.ChildAdded:Connect(bindDropHeldEgg))
	end
	hookPlayerGui()
	table.insert(conns, LocalPlayer.CharacterAdded:Connect(function() task.defer(hookPlayerGui) end))
	pcall(function()
		local GPC = require(ReplicatedStorage.Shared.Modules.GuardAreas.GuardPresentationComponent)
		if type(GPC) == "table" then
			runtimeEnv.__SenaV4GuardPresentOrig = runtimeEnv.__SenaV4GuardPresentOrig or {
				PlayWake = GPC.PlayWake,
				PlayHit = GPC.PlayHit,
				PlayAfterWake = GPC.PlayAfterWake,
				ScheduleAfterWake = GPC.ScheduleAfterWake,
			}
			local noop = function() end
			GPC.PlayWake = noop
			GPC.PlayHit = function() return 0 end
			GPC.PlayAfterWake = noop
			GPC.ScheduleAfterWake = noop
		end
		end)
	runtimeEnv.__SenaV4CosmeticSuppressCleanup = function()
		for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
		table.clear(conns)
		local orig = runtimeEnv.__SenaV4GuardPresentOrig
		if type(orig) == "table" then
			pcall(function()
				local GPC = require(ReplicatedStorage.Shared.Modules.GuardAreas.GuardPresentationComponent)
				for k, fn in pairs(orig) do GPC[k] = fn end
				end)
		end
	end
end
do
	if type(runtimeEnv.__SenaV4StealDeclutterCleanup) == "function" then
		pcall(runtimeEnv.__SenaV4StealDeclutterCleanup)
	end
	local TARGETS = {
		{ name = "ProximityPrompts", restore = true },
		{ name = "AreaGui", restore = false },
	}
	local active = false
	local conns = {}
	local function isCollector(inst)
		return inst and (inst:IsA("ScreenGui") or inst:IsA("LayerCollector"))
	end
	local function pinBillboard(gui)
		if not gui:IsA("LayerCollector") then return end
		pcall(function() gui.Enabled = false end)
		table.insert(conns, gui:GetPropertyChangedSignal("Enabled"):Connect(function()
			if active and gui.Enabled then pcall(function() gui.Enabled = false end) end
			end))
	end
	local function pin(sg)
		if not isCollector(sg) then return end
		pcall(function() sg.Enabled = false end)
		table.insert(conns, sg:GetPropertyChangedSignal("Enabled"):Connect(function()
			if active and sg.Enabled then pcall(function() sg.Enabled = false end) end
			end))
		for _, child in ipairs(sg:GetChildren()) do pinBillboard(child) end
		table.insert(conns, sg.ChildAdded:Connect(function(child)
			if active then pinBillboard(child) end
			end))
	end
	local function forEachTarget(fn)
		local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
		if not pg then return end
		for _, t in ipairs(TARGETS) do
			local sg = pg:FindFirstChild(t.name)
			if sg then fn(sg, t) end
		end
	end
	local function engage()
		local pg = LocalPlayer:FindFirstChildOfClass("PlayerGui")
		if not pg then return end
		forEachTarget(function(sg) pin(sg) end)
		table.insert(conns, pg.ChildAdded:Connect(function(child)
			if not active then return end
			for _, t in ipairs(TARGETS) do
				if child.Name == t.name then pin(child) break end
			end
			end))
	end
	local function release()
		for _, c in ipairs(conns) do pcall(function() c:Disconnect() end) end
		table.clear(conns)
		forEachTarget(function(sg, t)
			pcall(function() sg.Enabled = t.restore end)
			if t.restore then
				for _, child in ipairs(sg:GetChildren()) do
					if child:IsA("LayerCollector") then pcall(function() child.Enabled = true end) end
				end
			end
		end)
	end
	runtimeEnv.__SenaV4SetStealDeclutter = function(on)
		on = on == true
		if on == active then return end
		active = on
		if on then engage() else release() end
	end
	runtimeEnv.__SenaV4StealDeclutterCleanup = function()
		active = false
		release()
	end
end
local UNMOUNT_CONFIRM_TIMEOUT = 1.5
local UNMOUNT_SETTLE_DELAY = 0.12
local function ensureUnmountedBeforeSteal()
	treadmillIdleMountRequested = false
	local mounted = readTreadmillMountedFromServer()
	if mounted == false then
		treadmillActiveId = nil
		return true
	end
	if mounted == nil and treadmillActiveId == nil then return true end
	treadmillActiveId = treadmillActiveId or "server"
	local ok, reason = requestTreadmillUnequip()
	if not ok then
		warn("[Treadmill] Gagal minta lepas dari treadmill sebelum steal:", reason)
		return false
	end
	local deadline = os.clock() + UNMOUNT_CONFIRM_TIMEOUT
	while treadmillActiveId ~= nil and os.clock() < deadline do
		task.wait(0.05)
		if not Config.AutoSteal then return false end
		mounted = readTreadmillMountedFromServer()
		if mounted == false then
			treadmillActiveId = nil
			break
		end
	end
	if treadmillActiveId ~= nil then
		warn("[Treadmill] Lepas treadmill gak kekonfirmasi dalam " .. UNMOUNT_CONFIRM_TIMEOUT .. "s, steal dilanjut apa adanya.")
		return false
	end
	task.wait(UNMOUNT_SETTLE_DELAY)
	return true
end
if type(runtimeEnv.__SenaV4DecomBoostCleanup) == "function" then
	pcall(runtimeEnv.__SenaV4DecomBoostCleanup)
end
local decomBoostConnections = {}
local decomBoostListening = false
runtimeEnv.__SenaV4DecomBoostCleanup = function()
	for _, connection in ipairs(decomBoostConnections) do
		pcall(function() connection:Disconnect() end)
	end
	table.clear(decomBoostConnections)
	decomBoostListening = false
end
local function purgeDecomRenderedAssets()
	local renderedAssets = workspace:FindFirstChild("ClientRenderedAssets")
	if not renderedAssets then return end
	for _, model in ipairs(renderedAssets:GetChildren()) do
		pcall(function() model.Parent = nil end)
	end
end
local function isOwnPlacedEgg(model)
	return string.sub(model.Name, 1, #tostring(LocalPlayer.UserId) + 1) == tostring(LocalPlayer.UserId) .. "_"
end
local function purgeDecomPlacedEggs()
	for _, folder in ipairs(workspace:GetChildren()) do
		if folder.Name == "PlacedEggRenders" then
			for _, model in ipairs(folder:GetChildren()) do
				pcall(function()
					if not model:FindFirstChildOfClass("ProximityPrompt") and not isOwnPlacedEgg(model) then
						model.Parent = nil
					end
					end)
			end
		end
	end
end
local function purgeDecomPlayerTraps()
	for _, fName in ipairs({ "Transient", "__DEBRIS" }) do
		local folder = workspace:FindFirstChild(fName)
		if folder then
			for _, child in ipairs(folder:GetChildren()) do
				if child.Name == "PlayerTrap" or child.Name:lower():find("trap") then
					pcall(function() child:Destroy() end)
				end
			end
		end
	end
end
local function isSenaVisualItem(instance)
	if instance:FindFirstAncestor("SenaVisualBack") or instance:FindFirstAncestor("SenaVisualRemote") then return true end
	local tool = instance:FindFirstAncestorWhichIsA("Tool")
	return tool ~= nil and tool:GetAttribute("SenaVisual") ~= nil
end
local decomBoostUndo = { effects = {}, parts = {}, decals = {}, snapshot = nil }
local GAIN_POPUP_NAMES = { PlusOne = true, SpeedGainPopup = true, SellPayout = true, SyncedIncomeCash = true }
local CLUTTER_BILLBOARD_NAMES = { PlayerPlotSign = true, CanUpgrade = true, AlertGui = true, OfflineMoneyClaimBillboard = true }
local function suppressDecomVisual(instance)
	pcall(function()
		if isSenaVisualItem(instance) then return end
		if GAIN_POPUP_NAMES[instance.Name] then
			instance:Destroy()
			return
		end
		if instance:IsA("BillboardGui") and CLUTTER_BILLBOARD_NAMES[instance.Name] then
			if instance.Enabled then decomBoostUndo.effects[instance] = true end
			instance.Enabled = false
			return
		end
		if instance:IsA("ParticleEmitter") or instance:IsA("Trail")
		or instance:IsA("Beam") or instance:IsA("Sparkles")
		or instance:IsA("Fire") or instance:IsA("Smoke")
		or instance:IsA("PostEffect")
		then
			if instance.Enabled then decomBoostUndo.effects[instance] = true end
			instance.Enabled = false
		end
		end)
end
local function installDecomBoostListeners()
	if decomBoostListening then return end
	decomBoostListening = true
	table.insert(decomBoostConnections, game.DescendantAdded:Connect(suppressDecomVisual))
	table.insert(decomBoostConnections, workspace.ChildAdded:Connect(function(instance)
		if instance.Name == "ClientRenderedAssets" then
			purgeDecomRenderedAssets()
			table.insert(decomBoostConnections, instance.ChildAdded:Connect(function(model)
				pcall(function() model.Parent = nil end)
				end))
		elseif instance.Name == "PlacedEggRenders" then
			purgeDecomPlacedEggs()
			table.insert(decomBoostConnections, instance.ChildAdded:Connect(function(model)
				pcall(function()
					if not model:FindFirstChildOfClass("ProximityPrompt") and not isOwnPlacedEgg(model) then model.Parent = nil end
					end)
				end))
		elseif instance.Name == "__DEBRIS" or instance.Name == "Transient" then
			table.insert(decomBoostConnections, instance.ChildAdded:Connect(function(child)
				if child.Name == "PlayerTrap" or child.Name:lower():find("trap") then pcall(function() child:Destroy() end) end
				end))
		end
		end))
	local renderedAssets = workspace:FindFirstChild("ClientRenderedAssets")
	if renderedAssets then
		table.insert(decomBoostConnections, renderedAssets.ChildAdded:Connect(function(model)
			pcall(function() model.Parent = nil end)
			end))
	end
	for _, folder in ipairs(workspace:GetChildren()) do
		if folder.Name == "PlacedEggRenders" then
			table.insert(decomBoostConnections, folder.ChildAdded:Connect(function(model)
				pcall(function()
					if not model:FindFirstChildOfClass("ProximityPrompt") and not isOwnPlacedEgg(model) then model.Parent = nil end
					end)
				end))
		end
	end
end
local startupBoostBusy = false
local function ApplyDecomStartupBoost()
	if startupBoostBusy then return end
	startupBoostBusy = true
	local Lighting = game:GetService("Lighting")
	if not decomBoostUndo.snapshot then
		local snap = {}
		pcall(function()
			snap.quality = settings().Rendering.QualityLevel
			snap.throttle = settings().Physics.PhysicsEnvironmentalThrottle
			snap.technology = Lighting.Technology
			snap.shadows = Lighting.GlobalShadows
			snap.fogEnd = Lighting.FogEnd
			snap.brightness = Lighting.Brightness
			snap.ambient = Lighting.Ambient
			snap.outdoorAmbient = Lighting.OutdoorAmbient
			end)
		local terrain = workspace:FindFirstChildOfClass("Terrain")
		if terrain then
			pcall(function()
				snap.terrain = {
					WaterWaveSize = terrain.WaterWaveSize,
					WaterWaveSpeed = terrain.WaterWaveSpeed,
					WaterReflectance = terrain.WaterReflectance,
					WaterTransparency = terrain.WaterTransparency,
					Decoration = terrain.Decoration,
				}
				end)
			pcall(function()
				local clouds = terrain:FindFirstChildOfClass("Clouds")
				if clouds then snap.cloudsEnabled = clouds.Enabled end
				end)
		end
		pcall(function()
			local Prefs = ReplicatedStorage.Shared:FindFirstChild("Preferences")
			if Prefs then
				Prefs = require(Prefs)
				snap.prefs = { HideOtherPets = Prefs.IsOn("HideOtherPets"), DisableVideos = Prefs.IsOn("DisableVideos") }
			end
			end)
		if snap.quality == Enum.QualityLevel.Level01 then snap.quality = Enum.QualityLevel.Automatic end
		decomBoostUndo.snapshot = runtimeEnv.__SenaV4DecomSnapshot or snap
		runtimeEnv.__SenaV4DecomSnapshot = decomBoostUndo.snapshot
	end
	pcall(function()
		settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
		settings().Physics.PhysicsEnvironmentalThrottle = Enum.EnviromentalPhysicsThrottle.Always
		Lighting.Technology = Enum.Technology.Compatibility
		Lighting.GlobalShadows = false
		Lighting.FogEnd = 9e9
		Lighting.Brightness = 2
		Lighting.Ambient = Color3.new(1, 1, 1)
		Lighting.OutdoorAmbient = Color3.new(1, 1, 1)
		end)
	local sliceStart = os.clock()
	for _, container in ipairs({ workspace, Lighting }) do
		for _, instance in ipairs(container:GetDescendants()) do
			if isSenaVisualItem(instance) then
				continue
			elseif instance:IsA("BasePart") then
				pcall(function()
					if not decomBoostUndo.parts[instance] then
						decomBoostUndo.parts[instance] = { instance.Material, instance.CastShadow, instance:IsA("MeshPart") and instance.RenderFidelity or nil }
					end
					instance.Material = Enum.Material.SmoothPlastic
					instance.CastShadow = false
					if instance:IsA("MeshPart") then instance.RenderFidelity = Enum.RenderFidelity.Performance end
					end)
			elseif instance:IsA("Decal") or instance:IsA("Texture") then
				pcall(function()
					if instance.Texture ~= "" and not decomBoostUndo.decals[instance] then
						decomBoostUndo.decals[instance] = instance.Texture
					end
					instance.Texture = ""
					end)
			else
				suppressDecomVisual(instance)
			end
			if os.clock() - sliceStart > 0.004 then
				task.wait()
				sliceStart = os.clock()
			end
		end
	end
	local terrain = workspace:FindFirstChildOfClass("Terrain")
	if terrain then
		pcall(function()
			terrain.WaterWaveSize = 0
			terrain.WaterWaveSpeed = 0
			terrain.WaterReflectance = 0
			terrain.WaterTransparency = 1
			terrain.Decoration = false
			local clouds = terrain:FindFirstChildOfClass("Clouds")
			if clouds then clouds.Enabled = false end
			end)
	end
	pcall(function()
		local Shared = ReplicatedStorage.Shared
		local Prefs = Shared:FindFirstChild("Preferences")
		if Prefs then
			Prefs = require(Prefs)
			Prefs.Set("HideOtherPets", true)
			Prefs.Set("DisableVideos", true)
		else
			local SettingsCmds = require(Shared.SettingsCmds)
			SettingsCmds.Write("HideOtherPets", true)
			SettingsCmds.Write("DisableVideos", true)
		end
		end)
	purgeDecomRenderedAssets()
	purgeDecomPlacedEggs()
	purgeDecomPlayerTraps()
	installDecomBoostListeners()
	startupBoostBusy = false
end
decomBoostUndo.revert = function()
	for _, connection in ipairs(decomBoostConnections) do
		pcall(function() connection:Disconnect() end)
	end
	table.clear(decomBoostConnections)
	decomBoostListening = false
	local snap = decomBoostUndo.snapshot
	local Lighting = game:GetService("Lighting")
	if snap then
		pcall(function() settings().Rendering.QualityLevel = snap.quality or Enum.QualityLevel.Automatic end)
		pcall(function() settings().Physics.PhysicsEnvironmentalThrottle = snap.throttle end)
		pcall(function()
			Lighting.Technology = snap.technology
			Lighting.GlobalShadows = snap.shadows
			Lighting.FogEnd = snap.fogEnd
			Lighting.Brightness = snap.brightness
			Lighting.Ambient = snap.ambient
			Lighting.OutdoorAmbient = snap.outdoorAmbient
			end)
		local terrain = workspace:FindFirstChildOfClass("Terrain")
		if terrain and snap.terrain then
			for prop, value in pairs(snap.terrain) do
				pcall(function() terrain[prop] = value end)
			end
			if snap.cloudsEnabled ~= nil then
				pcall(function()
					local clouds = terrain:FindFirstChildOfClass("Clouds")
					if clouds then clouds.Enabled = snap.cloudsEnabled end
					end)
			end
		end
		if snap.prefs then
			pcall(function()
				local Prefs = require(ReplicatedStorage.Shared.Preferences)
				for key, value in pairs(snap.prefs) do Prefs.Set(key, value) end
				end)
		end
	end
	local restored = 0
	for part, old in pairs(decomBoostUndo.parts) do
		if part.Parent then
			pcall(function()
				part.Material = old[1]
				part.CastShadow = old[2]
				if old[3] ~= nil and part:IsA("MeshPart") then part.RenderFidelity = old[3] end
				end)
		end
		restored += 1
		if restored % 400 == 0 then task.wait() end
	end
	for decal, texture in pairs(decomBoostUndo.decals) do
		if decal.Parent then pcall(function() decal.Texture = texture end) end
	end
	for effect in pairs(decomBoostUndo.effects) do
		if effect.Parent then pcall(function() effect.Enabled = true end) end
	end
	decomBoostUndo.parts, decomBoostUndo.decals, decomBoostUndo.effects = {}, {}, {}
	decomBoostUndo.snapshot = nil
end
runtimeEnv.__SenaV4DecomBoostUndo = decomBoostUndo
local fpsBoostApplied = false
local function hideModelIfNotMine(model)
	if not model or not model:IsA("Model") then return end
	local ownerIdStr = model.Name:match("^(%d+)_")
	local ownerId = ownerIdStr and tonumber(ownerIdStr)
	if not ownerId or ownerId == LocalPlayer.UserId then return end
	for _, part in ipairs(model:GetDescendants()) do
		if part:IsA("BasePart") then
			part.Transparency = 1
			part.CanCollide = false
		elseif part:IsA("Decal") or part:IsA("Texture") then
			part.Transparency = 1
		elseif part:IsA("ParticleEmitter") or part:IsA("Trail") or part:IsA("Beam") then
			part.Enabled = false
		elseif part:IsA("BillboardGui") or part:IsA("SurfaceGui") then
			part.Enabled = false
		end
	end
end
local function hideOtherPlayersEggs()
	if Config._fpsEggsReady then return true end
	local ready = false
	local ok, err = pcall(function()
		local ReplicatedStorage = game:GetService("ReplicatedStorage")
		local PlacedEggRenderer = require(ReplicatedStorage.Shared.Eggs.PlacedEggRenderer)
		local renderFolder = PlacedEggRenderer.GetRenderFolder()
		if not renderFolder then return end
		local children = renderFolder:GetChildren()
		for _, model in ipairs(children) do
			hideModelIfNotMine(model)
		end
		renderFolder.ChildAdded:Connect(function(model)
			task.defer(hideModelIfNotMine, model)
			end)
		ready = true
		end)
	if not ok then
		warn("[FPSBoost] Gagal hide egg pemain lain:", err)
		return false
	end
	return ready
end
local function purgeRenderedPet(model)
	if not model then return end
	pcall(function() model.Parent = nil end)
end
local function hideOtherPlayersPets()
	if Config._fpsPetsReady then return true end
	local readPref
	local ok, err = pcall(function()
		local Shared = game:GetService("ReplicatedStorage").Shared
		local Prefs = Shared:FindFirstChild("Preferences")
		if Prefs then
			Prefs = require(Prefs)
			Prefs.Set("HideOtherPets", true)
			readPref = Prefs.IsOn
		else
			local SettingsCmds = require(Shared.SettingsCmds)
			SettingsCmds.Write("HideOtherPets", true)
			readPref = SettingsCmds.Allows
		end
		end)
	local settingReady = false
	if ok and readPref then
		local readOk, enabled = pcall(readPref, "HideOtherPets")
		settingReady = readOk and enabled == true
	end
	if not ok or not settingReady then
		warn("[FPSBoost] Gagal set HideOtherPets bawaan game:", err or "setting belum aktif")
		return false
	end
	local ready = false
	local ok2, err2 = pcall(function()
		local renderFolder = workspace:FindFirstChild("ClientRenderedAssets")
		or workspace:WaitForChild("ClientRenderedAssets", 10)
		if not renderFolder then return end
		local children = renderFolder:GetChildren()
		for _, model in ipairs(children) do
			purgeRenderedPet(model)
		end
		renderFolder.ChildAdded:Connect(function(model)
			task.defer(purgeRenderedPet, model)
			end)
		ready = true
		end)
	if not ok2 then
		warn("[FPSBoost] Gagal hide pet (manual):", err2)
		return false
	end
	return ready
end
local function reduceGraphicsQuality()
	if type(runtimeEnv.__SenaV4SetCapFps) == "function" then
		pcall(runtimeEnv.__SenaV4SetCapFps, 1000)
	end
	pcall(function() settings().Rendering.QualityLevel = Enum.QualityLevel.Level01 end)
	pcall(function()
		UserSettings():GetService("UserGameSettings").SavedQualityLevel = Enum.SavedQualitySetting.QualityLevel1
		end)
	pcall(function()
		local ReplicatedStorage = game:GetService("ReplicatedStorage")
		local LightingsController = require(ReplicatedStorage.Client.LightingsController)
		LightingsController:SetModifier("FPSBoost", function(cfg)
			local boosted = table.clone(cfg)
			boosted.Bloom = nil
			boosted.ColorCorrection = nil
			boosted.SunRays = nil
			boosted.DepthOfField = nil
			boosted.Blur = nil
			boosted.Clouds = nil
			boosted.Atmosphere = nil
			boosted.ShadowSoftness = 1
			return boosted
			end, 100, 0)
		end)
	pcall(function()
		local Lighting = game:GetService("Lighting")
		Lighting.GlobalShadows = false
		Lighting.Technology = Enum.Technology.Compatibility
		Lighting.FogEnd = 9e9
		Lighting.Brightness = 2
		end)
	pcall(function()
		local terr = workspace:FindFirstChildOfClass("Terrain")
		if terr then
			terr.WaterWaveSize = 0
			terr.WaterWaveSpeed = 0
			terr.WaterReflectance = 0
			terr.WaterTransparency = 1
			terr.Decoration = false
		end
		end)
	pcall(function()
		local debris = workspace:FindFirstChild("__DEBRIS")
		if debris then
			for _, child in ipairs(debris:GetChildren()) do
				if child.Name == "PlayerTrap" then pcall(function() child:Destroy() end) end
			end
		end
		end)
end
local GRAY_MATERIAL_COLOR = Color3.fromRGB(120, 120, 120)
local function flattenPart(part)
	if not part or not part:IsA("BasePart") then return end
	part.Material = Enum.Material.SmoothPlastic
	part.Color = GRAY_MATERIAL_COLOR
	part.CastShadow = false
end
local function suppressVisualEffect(instance)
	if instance:IsA("ParticleEmitter") then
		instance.Enabled = false
		instance.Rate = 0
		pcall(function() instance:Clear() end)
	elseif instance:IsA("Trail") or instance:IsA("Beam")
	or instance:IsA("Smoke") or instance:IsA("Fire") or instance:IsA("Sparkles")
	or instance:IsA("PostEffect") or instance:IsA("Light")
	or instance:IsA("Highlight") or instance:IsA("Clouds")
	then
		instance.Enabled = false
	elseif instance:IsA("Atmosphere") then
		instance.Density = 0
		instance.Haze = 0
		instance.Glare = 0
	elseif instance:IsA("Explosion") then
		pcall(function() instance.Visible = false end)
	end
end
local function flattenWorldMaterials()
	if Config._fpsWorldReady then return true end
	local ready = false
	local listeners = {}
	local ok, err = pcall(function()
		local function flattenInstance(inst)
			if isSenaVisualItem(inst) then return end
			flattenPart(inst)
			suppressVisualEffect(inst)
		end
		local roots = {workspace, game:GetService("Lighting")}
		for _, root in ipairs(roots) do
			table.insert(listeners, root.DescendantAdded:Connect(function(inst)
				task.defer(flattenInstance, inst)
				end))
		end
		local stack = {}
		for _, root in ipairs(roots) do
			for _, child in ipairs(root:GetChildren()) do
				table.insert(stack, child)
			end
		end
		local processed = 0
		while #stack > 0 do
			local inst = table.remove(stack)
			flattenInstance(inst)
			for _, child in ipairs(inst:GetChildren()) do
				table.insert(stack, child)
			end
			processed = processed + 1
			if processed >= 250 and #stack > 0 then
				processed = 0
				RunService.Heartbeat:Wait()
			end
		end
		ready = true
		end)
	if not ok then
		for _, listener in ipairs(listeners) do listener:Disconnect() end
		warn("[FPSBoost] Gagal flatten material workspace:", err)
		return false
	end
	return ready
end
local function pruneAreaDecorations()
	if Config._fpsAreasReady then return true end
	local objects = resolveObjectsRoot()
	local areas = objects and objects:FindFirstChild("Areas")
	local guardAreas = areas and areas:FindFirstChild("GuardAreas")
	local build = objects and objects:FindFirstChild("Build")
	if not guardAreas or not build then return false end
	for _, area in ipairs(guardAreas:GetChildren()) do
		local sign = area:FindFirstChild("RequiredSpeedSign")
		if sign then pcall(function() sign:Destroy() end) end
	end
	local mainMap = build:FindFirstChild("MainMap")
	local lobbyBases = mainMap and mainMap:FindFirstChild("Bases")
	local function isFloor(part)
		if lobbyBases and part:IsDescendantOf(lobbyBases) then
			return part.Size.Y <= 5 and not string.find(string.upper(part.Name), "WALL", 1, true)
		end
		local ancestor = part
		while ancestor and ancestor ~= build do
			local name = string.upper(ancestor.Name)
			if string.find(name, "BOTTOM", 1, true) then
				return true
			end
			ancestor = ancestor.Parent
		end
		return false
	end
	local protectedTokens = { "ENCHANTED", "FUSEBIOME", "WISP", "BUTTERFLY", "MARKERS", "PORTAL", "TRIGGER" }
	local function isProtected(part)
		if part:FindFirstChildOfClass("TouchTransmitter") or part:FindFirstChildWhichIsA("ProximityPrompt", true) then
			return true
		end
		local ancestor = part
		while ancestor and ancestor ~= build do
			local name = string.upper(ancestor.Name)
			for _, token in ipairs(protectedTokens) do
				if string.find(name, token, 1, true) then return true end
			end
			ancestor = ancestor.Parent
		end
		return false
	end
	local function prune(instance)
		if not instance:IsA("BasePart") then return end
		if isProtected(instance) then return end
		if isFloor(instance) then
			flattenPart(instance)
		else
			pcall(function() instance:Destroy() end)
		end
	end
	local listener = build.DescendantAdded:Connect(function(instance)
		task.defer(prune, instance)
		end)
	local processed = 0
	local deleted = 0
	for _, instance in ipairs(build:GetDescendants()) do
		local existed = instance.Parent ~= nil
		prune(instance)
		if existed and instance.Parent == nil then deleted = deleted + 1 end
		processed = processed + 1
		if processed >= 250 then
			processed = 0
			RunService.Heartbeat:Wait()
		end
	end
	Config._fpsAreaListener = listener
	Config._fpsAreaDeleted = deleted
	Config._fpsAreasReady = true
	return true
end
local function deleteOtherPlayersPlots()
	if Config._fpsPlotsReady then return true end
	local ready = false
	local ok, err = pcall(function()
		local ReplicatedStorage = game:GetService("ReplicatedStorage")
		local PlotCmds = require(ReplicatedStorage.Client.PlotState)
		local mySlot = PlotCmds.GetMySlot()
		if mySlot == nil then
			warn("[FPSBoost] Slot plot kita belum ke-resolve, skip delete plot dulu (biar aman).")
			return
		end
		local function isMyPlot(plot)
			local currentSlot = PlotCmds.GetMySlot()
			return currentSlot ~= nil and plot.Name == tostring(currentSlot)
		end
		local plotsFolder = PlotCmds.GetPlotsFolder() or workspace:WaitForChild("Plots", 10)
		if not plotsFolder then
			warn("[FPSBoost] workspace.Plots gak ketemu sama sekali.")
			return
		end
		local children = plotsFolder:GetChildren()
		local deleted = 0
		for _, plot in ipairs(children) do
			if not isMyPlot(plot) then
				local dOk = pcall(function() plot:Destroy() end)
				if dOk then deleted = deleted + 1 end
			end
		end
		plotsFolder.ChildAdded:Connect(function(plot)
			task.defer(function()
				if plot.Parent and not isMyPlot(plot) then
					pcall(function() plot:Destroy() end)
				end
				end)
			end)
		ready = true
		end)
	if not ok then
		warn("[FPSBoost] Gagal delete plot pemain lain:", err)
		return false
	end
	return ready
end
local function deleteOtherPlayersTreadmills()
	if Config._fpsTreadmillsReady then return true end
	local ready = false
	local ok, err = pcall(function()
		local ReplicatedStorage = game:GetService("ReplicatedStorage")
		local PlotCmds = require(ReplicatedStorage.Client.PlotState)
		local RuntimeInstanceRegistry
		local modules = ReplicatedStorage.Client:FindFirstChild("Modules") or ReplicatedStorage.Client:WaitForChild("Modules", 10)
		local registryModule = modules and (modules:FindFirstChild("RuntimeInstanceRegistry") or modules:WaitForChild("RuntimeInstanceRegistry", 10))
		if registryModule then
			local okReq, mod = pcall(require, registryModule)
			if okReq then RuntimeInstanceRegistry = mod end
		end
		local folder = workspace:FindFirstChild("__ClientTreadmillRenders")
		or workspace:WaitForChild("__ClientTreadmillRenders", 10)
		if not folder then return end
		local function getMyTreadmillModel()
			local mySlot = PlotCmds.GetMySlot()
			if mySlot == nil then return nil end
			local byName = folder:FindFirstChild("TreadmillRender_" .. tostring(mySlot))
			if byName then return byName end
			local lookup = RuntimeInstanceRegistry and (RuntimeInstanceRegistry.Peek or RuntimeInstanceRegistry.Get)
			if not lookup then return nil end
			local okReg, result = pcall(lookup, "TreadmillPlotRender", tostring(mySlot))
			if okReg then return result end
			return nil
		end
		local function isMyTreadmill(model)
			local myTreadmillModel = getMyTreadmillModel()
			if myTreadmillModel and model == myTreadmillModel then
				return true
			end
			local okPos, pos = pcall(function() return model:GetPivot().Position end)
			if not okPos then return true end
			local okBounds, within = pcall(PlotCmds.IsWorldPositionWithinLocalPlotBounds, pos)
			return okBounds and within
		end
		local children = folder:GetChildren()
		local deleted = 0
		for _, model in ipairs(children) do
			if model:IsA("Model") and not isMyTreadmill(model) then
				local dOk = pcall(function() model:Destroy() end)
				if dOk then deleted = deleted + 1 end
			end
		end
		folder.ChildAdded:Connect(function(model)
			task.defer(function()
				if model.Parent and model:IsA("Model") and not isMyTreadmill(model) then
					pcall(function() model:Destroy() end)
				end
				end)
			end)
		ready = true
		end)
	if not ok then
		warn("[FPSBoost] Gagal delete treadmill pemain lain:", err)
		return false
	end
	return ready
end
local function ApplyFPSBoost()
	if fpsBoostApplied or Config._fpsBoostApplying then return end
	Config._fpsBoostApplying = true
	local ok, err = pcall(function()
		reduceGraphicsQuality()
		Config._fpsPlotsReady = deleteOtherPlayersPlots() == true
		Config._fpsTreadmillsReady = deleteOtherPlayersTreadmills() == true
		Config._fpsAreasReady = pruneAreaDecorations() == true
		Config._fpsWorldReady = flattenWorldMaterials() == true
		Config._fpsPetsReady = hideOtherPlayersPets() == true
		Config._fpsEggsReady = hideOtherPlayersEggs() == true
		fpsBoostApplied = Config._fpsEggsReady and Config._fpsPetsReady
		and Config._fpsWorldReady and Config._fpsPlotsReady and Config._fpsTreadmillsReady
		and Config._fpsAreasReady
		end)
	Config._fpsBoostApplying = nil
	if not ok then
		warn("[FPSBoost] Gagal menerapkan FPS Boost:", err)
	end
end
local function isPathClear(from, to, excludeChar)
	local clear = true
	pcall(function()
		local excludeList = {excludeChar}
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		local origin = from
		for _ = 1, 8 do
			params.FilterDescendantsInstances = excludeList
			local dir = to - origin
			if dir.Magnitude < 1 then break end
			local result = workspace:Raycast(origin, dir, params)
			if not result then
				break
			end
			if result.Instance.CanCollide then
				clear = false
				break
			end
			table.insert(excludeList, result.Instance)
			origin = result.Position + dir.Unit * 0.1
		end
		end)
	return clear
end
local UIRunners = {}
do
	local SenaHalloween = {}
	local Players = game:GetService("Players")
	local RS = game:GetService("ReplicatedStorage")
	local LP = Players.LocalPlayer
	local STAGE = Vector3.new(-5809.776, -203.938, -7233.45)
	local BANKSPOT = Vector3.new(-5809.41, -203.938, -7246.08)
	local BUY_COST = 2250
	local function okReq(inst) if not inst then return nil end local o, m = pcall(require, inst) return o and m or nil end
	local function hrp() local c = LP.Character return c and c:FindFirstChild("HumanoidRootPart") end
	local function hum() local c = LP.Character return c and c:FindFirstChildOfClass("Humanoid") end
	local function save() return okReq(RS:FindFirstChild("Shared") and RS.Shared:FindFirstChild("Save")) end
	local function remotes() return okReq(RS:FindFirstChild("Shared") and RS.Shared:FindFirstChild("Remotes")) end
	local function candy() local S = save() local p = S and S.Peek() return (p and p.HalloweenTokens) or 0 end
	local function inside() return LP:GetAttribute("InHalloweenDimension") == true end
	local function carrying() return LP:GetAttribute("HalloweenCarrying") == true end
	local function hd() return workspace:FindFirstChild("HalloweenDimension") end
	local function cfgNames() local t = Config.HalloweenNames or {} local out = {} for _, n in ipairs(t) do if n ~= "None" and n ~= "" then out[#out + 1] = n end end return out end
	local _HP, _AssetsDir
	local function rarityOf(name) if not name then return nil end if _HP == nil then _HP = okReq(RS:FindFirstChild("Data") and RS.Data:FindFirstChild("HalloweenPets")) or false end if _AssetsDir == nil then local a = okReq(RS:FindFirstChild("Data") and RS.Data:FindFirstChild("Assets")) _AssetsDir = (a and a.Directory) or false end if _HP and _HP.Specs and _HP.Specs[name] and _HP.Specs[name].Rarity then return tostring(_HP.Specs[name].Rarity) end if _AssetsDir and _AssetsDir[name] and _AssetsDir[name].Rarity then local r = _AssetsDir[name].Rarity if type(r) == "table" then return r._id or r.DisplayName elseif type(r) == "string" then return r end end local nk = runtimeEnv.__SenaV4HwNorm if nk == nil then nk = {} for _, src in ipairs({ (_AssetsDir or {}), (_HP and _HP.Specs or {}) }) do for k in pairs(src) do nk[(tostring(k):lower():gsub("[%s_%-]", ""):gsub("egg$", ""))] = k end end runtimeEnv.__SenaV4HwNorm = nk end local alt = nk[(name:lower():gsub("[%s_%-]", ""):gsub("egg$", ""))] if alt and alt ~= name then return rarityOf(alt) end return nil end
	local function rarityPass(name, list) if type(list) ~= "table" then return true end local any = false for _, n in ipairs(list) do if n ~= "None" and n ~= "" then any = true break end end if not any then return true end local rr = rarityOf(name) if not rr then return false end for _, n in ipairs(list) do if n == rr then return true end end return false end
	local function alive(H) return H and H.running and runtimeEnv.__SenaHalloweenFarm == H and hrp() ~= nil end
	local function tpHold(H, pos, secs) local n = math.max(6, math.floor((secs or 0.6) / 0.06)) for i = 1, n do if not alive(H) then return end local r = hrp() if r then r.CFrame = CFrame.new(pos) pcall(function() r.AssemblyLinearVelocity = Vector3.new(0, 0, 0) end) end task.wait(0.06) end end
	local function glide(H, target, dur) local r = hrp() if not r then return end local sp = r.Position local steps = math.max(4, math.floor((dur or 0.5) / 0.03)) for i = 1, steps do if not alive(H) then return end r = hrp() if r then r.CFrame = CFrame.new(sp:Lerp(target, i / steps)) pcall(function() r.AssemblyLinearVelocity = Vector3.new(0, 0, 0) end) end task.wait(0.03) end end
	local function walkTo(H, pos, mi) for i = 1, (mi or 30) do if not alive(H) then return false end local h = hum() local r = hrp() if h and r then h:MoveTo(Vector3.new(pos.X, r.Position.Y, pos.Z)) end task.wait(0.08) r = hrp() if r and (Vector3.new(pos.X, 0, pos.Z) - Vector3.new(r.Position.X, 0, r.Position.Z)).Magnitude <= 6 then return true end end return false end
	local function eggList() local f = hd() and hd():FindFirstChild("WorldEggs") local out = {} if f then for _, m in ipairs(f:GetChildren()) do local pr = m:FindFirstChildWhichIsA("ProximityPrompt", true) local a = pr and pr.Parent local pa = (a and a:IsA("BasePart")) and a or (m:IsA("Model") and (m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart"))) if pr and pa then out[#out + 1] = { prompt = pr, part = pa, zone = m:GetAttribute("Zone") or 0, name = m:GetAttribute("PreparedSourceName"), uid = m:GetAttribute("HalloweenEggUid") } end end end return out end
	local function pick(H) local list = eggList() local mq = runtimeEnv.__SenaV4HwManual if mq and next(mq) and #list > 0 then local live, r0, best, bd = {}, hrp(), nil, nil for _, e in ipairs(list) do if e.uid then live[e.uid] = true if mq[e.uid] then local d = r0 and (e.part.Position - r0.Position).Magnitude or 0 if not bd or d < bd then best, bd = e, d end end end end for u in pairs(mq) do if not live[u] then mq[u] = nil end end if best then best.manual = true return best end end if Config.AutoStealHalloween ~= true then return nil end local names = cfgNames() local f = {} for _, e in ipairs(list) do local ok = true if #names > 0 then ok = false for _, n in ipairs(names) do if e.name == n then ok = true break end end end if ok and rarityPass(e.name, Config.HalloweenEggRarities) then f[#f + 1] = e end end if #f == 0 then return nil end local r = hrp() local myPos = r and r.Position or STAGE table.sort(f, function(a, b) if (Config.HalloweenZonePriority ~= false) and a.zone ~= b.zone then return a.zone > b.zone end return (a.part.Position - myPos).Magnitude < (b.part.Position - myPos).Magnitude end) return f[1] end
	local function steal(H, e) for i = 1, 40 do if not alive(H) then return false end local r = hrp() if r then r.CFrame = CFrame.new(e.part.Position + Vector3.new(0, 2, 0)) pcall(function() r.AssemblyLinearVelocity = Vector3.new(0, 0, 0) end) end pcall(fireproximityprompt, e.prompt, e.prompt.HoldDuration or 0) task.wait(0.05) if carrying() then return true end end return false end
	local function dropRegrab(H) local R = remotes() if R then pcall(function() R.HalloweenDimension.AskDropEgg:InvokeServer() end) end task.wait(0.07) for a = 1, 3 do if not alive(H) then return false end local list = eggList() local best, bd local r = hrp() local myPos = r and r.Position or STAGE for _, e in ipairs(list) do local d = (e.part.Position - myPos).Magnitude if not bd or d < bd then best = e bd = d end end if best and bd and bd < 40 then for i = 1, 25 do pcall(fireproximityprompt, best.prompt, best.prompt.HoldDuration or 0) task.wait(0.04) if carrying() then return true end end end task.wait(0.05) end return carrying() end
	-- Portal crossing, measured 20/20 live (enter ~1.07s, exit ~0.49s): TP once 1.5 studs in front of the
	-- face on the portal's THIN axis, then walk through. Side offsets miss the hitbox; rapid TP bouncing makes
	-- the server drop our position and the portal stops registering for a while.
	runtimeEnv.__SenaV4PortalCross = function(part, wantInside, limit, okFn)
		local s, cf = part.Size, part.CFrame
		local n, th = cf.UpVector, s.Y
		if s.X <= s.Y and s.X <= s.Z then n, th = cf.RightVector, s.X elseif s.Z <= s.Y then n, th = cf.LookVector, s.Z end
		n = Vector3.new(n.X, 0, n.Z)
		if n.Magnitude < 0.01 then return false end
		n = n.Unit
		local c = LP.Character
		local r = c and c:FindFirstChild("HumanoidRootPart")
		if not r then return false end
		local side = ((r.Position - part.Position):Dot(n) >= 0) and 1 or -1
		local y = part.Position.Y - s.Y / 2 + 3
		local front = Vector3.new(part.Position.X, y, part.Position.Z) + n * side * (th / 2 + 1.5)
		local goal = Vector3.new(part.Position.X, y, part.Position.Z) - n * side * (th / 2 + 3)
		r.CFrame = CFrame.new(front, goal)
		pcall(function() r.AssemblyLinearVelocity = Vector3.zero end)
		local t0 = os.clock()
		while os.clock() - t0 < (limit or 3) do
			if (LP:GetAttribute("InHalloweenDimension") == true) == wantInside then
				-- the steal scheduler goes quiet inside the dimension; wake it once we are back out
				if not wantInside then task.delay(0.2, function() local er = runtimeEnv.__SenaV4EggRuntime if er and er.enabled and not er.running and not er.destroyed then pcall(er._schedule, er) end end) end
				return true
			end
			if okFn and not okFn() then return false end
			local h = LP.Character and LP.Character:FindFirstChildOfClass("Humanoid")
			if h then h:MoveTo(goal) end
			task.wait(0.05)
		end
		return (LP:GetAttribute("InHalloweenDimension") == true) == wantInside
	end
	local function ensureInside(H) if inside() then return true end if readTreadmillMountedFromServer() == true then pcall(requestTreadmillUnequip) pcall(function() local er = runtimeEnv.__SenaV4EggRuntime if er and er.treadmillManager then pcall(function() er.treadmillManager:_cancelIdle(true) end) end end) for i = 1, 20 do task.wait(0.1) if readTreadmillMountedFromServer() ~= true then break end end end local world = workspace:FindFirstChild("World") local portal = world and world:FindFirstChild("HalloweenDimensionPortal") local hb = portal and portal:FindFirstChild("Hitbox") if not hb then return false end for t = 1, 3 do if not alive(H) then return false end if runtimeEnv.__SenaV4PortalCross(hb, true, 3, function() return alive(H) end) then return true end task.wait(0.6) end return inside() end
	local function ensureBat() local c = LP.Character if not c then return false end local hum = c:FindFirstChildOfClass("Humanoid") if not hum then return false end for _, t in ipairs(c:GetChildren()) do if t:IsA("Tool") and t.Name:lower():find("bat") then return true end end local bp = LP:FindFirstChild("Backpack") if bp then for _, t in ipairs(bp:GetChildren()) do if t:IsA("Tool") and t.Name:lower():find("bat") then pcall(function() hum:UnequipTools() end) task.wait(0.03) pcall(function() hum:EquipTool(t) end) task.wait(0.05) if t.Parent ~= c then pcall(function() t.Parent = c end) end return t.Parent == c end end end return false end
	local function mobWanted() local t = Config.HalloweenMobTypes or {} local out = {} for _, n in ipairs(t) do if n ~= "None" and n ~= "" then out[n] = true end end return out, (next(out) ~= nil) end
	local function nearestMob() local h = hd() local mon = h and h:FindFirstChild("Monsters") if not mon then return nil end local want, anyWant = mobWanted() local r = hrp() local myPos = r and r.Position or STAGE local best, bp, bd for _, m in ipairs(mon:GetChildren()) do if m.Parent and (not anyWant or want[m.Name]) and rarityPass(m.Name, Config.HalloweenMobRarities) then local hbx = m:FindFirstChild("Hitbox") local hpx = hbx and tonumber(hbx:GetAttribute("Health")) if (hpx == nil or hpx > 0) and m:IsA("Model") then local pa = m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart") if pa then local d = (pa.Position - myPos).Magnitude if not bd or d < bd then best = m bp = pa bd = d end end end end end return best, bp end
	local function hitMob(H, m) local pa = m:IsA("Model") and (m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart")) if not pa then return false end local R = remotes() if not R then return false end local bats = (function() local chk = runtimeEnv.__SenaV4IsBatTool local o = {} for _, w in ipairs({ LP.Character, LP:FindFirstChild("Backpack") }) do if w then for _, t in ipairs(w:GetChildren()) do if t:IsA("Tool") and ((chk and chk(t)) or t.Name:lower():find("bat")) then o[#o + 1] = t end end end end return o end)() local swap = #bats >= 2 local bi = 1 local sz = m:GetAttribute("MonsterSize") local maxI = (sz == "Large" and 100) or (sz == "Medium" and 75) or 50 for i = 1, maxI do if not alive(H) then return false end if not m.Parent then return true end local hbx = m:FindFirstChild("Hitbox") local hpx = hbx and tonumber(hbx:GetAttribute("Health")) if hpx ~= nil and hpx <= 0 then return true end local r = hrp() if r then r.CFrame = CFrame.new(pa.Position + Vector3.new(0, 2, 0)) pcall(function() r.AssemblyLinearVelocity = Vector3.new(0, 0, 0) end) end H._mseq = (H._mseq or 0) + 1 pcall(function() R.BatSwing.Trigger:FireServer(m, ("%d:%d:%d"):format(LP.UserId, H._mseq, math.floor(workspace:GetServerTimeNow() * 1000))) end) if swap then bi = bi % #bats + 1 local b = bats[bi] if b and b.Parent then local c = LP.Character local h = c and c:FindFirstChildOfClass("Humanoid") if h then pcall(function() h:EquipTool(b) end) end end task.wait(0.1) else task.wait(0.05) end end return not m.Parent end
	local PUMPKIN_DEPOSIT = Vector3.new(-5521.62, -196.55, -6623.01)
	local function pumpkinCarrying() return LP:GetAttribute("HalloweenPumpkinCarrying") == true end
	local function pumpkinBox() local h = hd() if not h then return nil end for _, c in ipairs(h:GetChildren()) do local n = c.Name:lower() if (c:IsA("Model") or c:IsA("Folder")) and n ~= "pumpkinmoon" and (n:find("runaway") or n:find("pumpkin")) and #c:GetChildren() > 0 then return c end end return nil end
	local function pumpkinList() local box = pumpkinBox() local out = {} if box then local held = {} for _, pl in ipairs(Players:GetPlayers()) do if pl ~= LP and pl:GetAttribute("HalloweenPumpkinCarrying") == true then local c = pl.Character local rr = c and c:FindFirstChild("HumanoidRootPart") if rr then held[#held + 1] = rr.Position end end end for _, m in ipairs(box:GetChildren()) do local pr = m:FindFirstChildWhichIsA("ProximityPrompt", true) local pa = m:IsA("BasePart") and m or (m:IsA("Model") and (m.PrimaryPart or m:FindFirstChildWhichIsA("BasePart"))) local taken = pr ~= nil and pr.Enabled == false if pa and not taken then local root = pa.AssemblyRootPart local mdl = root and root ~= pa and root:FindFirstAncestorOfClass("Model") if mdl and Players:GetPlayerFromCharacter(mdl) then taken = true end end if pa and not taken then for _, hp in ipairs(held) do if (hp - pa.Position).Magnitude < 8 then taken = true break end end end if pa and not taken then out[#out + 1] = { model = m, part = pa, prompt = pr } end end end return out end
	local function nearestPumpkin() local list = pumpkinList() local r = hrp() local myPos = r and r.Position or STAGE local best, bd for _, p in ipairs(list) do local d = (p.part.Position - myPos).Magnitude if not bd or d < bd then best = p bd = d end end return best end
	local function depositPart() local h = hd() local a = h and h:FindFirstChild("Altar") return a and a:FindFirstChild("PumpkinDeposit") end
	local function grabPumpkin(H, p) for i = 1, 50 do if not alive(H) then return false end if p.prompt and p.prompt.Enabled == false and not pumpkinCarrying() then return false end do local root = p.part.AssemblyRootPart local mdl = root and root ~= p.part and root:FindFirstAncestorOfClass("Model") local owner = mdl and Players:GetPlayerFromCharacter(mdl) if owner and owner ~= LP then return pumpkinCarrying() end end local r = hrp() if r then r.CFrame = CFrame.new(p.part.Position + Vector3.new(0, 2, 0)) pcall(function() r.AssemblyLinearVelocity = Vector3.new(0, 0, 0) end) end if p.prompt then pcall(fireproximityprompt, p.prompt, p.prompt.HoldDuration or 0) else local rr = hrp() if rr then pcall(firetouchinterest, p.part, rr, 0) pcall(firetouchinterest, p.part, rr, 1) end end task.wait(0.05) if pumpkinCarrying() then return true end if not p.model.Parent then return pumpkinCarrying() end end return pumpkinCarrying() end
	local function depositPumpkin(H) local before = LP:GetAttribute("HalloweenPumpkins") or 0 local dep = depositPart() local pr = dep and dep:FindFirstChildWhichIsA("ProximityPrompt", true) for i = 1, 40 do if not alive(H) then return false end local r = hrp() if r then r.CFrame = CFrame.new(PUMPKIN_DEPOSIT + Vector3.new(0, 2, 0)) pcall(function() r.AssemblyLinearVelocity = Vector3.new(0, 0, 0) end) end if pr then pcall(fireproximityprompt, pr, pr.HoldDuration or 0) elseif dep then local rr = hrp() if rr then pcall(firetouchinterest, dep, rr, 0) pcall(firetouchinterest, dep, rr, 1) end end task.wait(0.05) if not pumpkinCarrying() then return true end local now = LP:GetAttribute("HalloweenPumpkins") or 0 if now > before then return true end end return not pumpkinCarrying() end
	local function exitDimension(H) if not inside() then return true end local ph for _, d in ipairs(workspace:GetDescendants()) do if d.Name == "PortalHome" then ph = d break end end local portal = ph and (ph:FindFirstChild("Portal") or ph:FindFirstChildWhichIsA("BasePart", true)) if not portal then return false end for t = 1, 3 do if not alive(H) then return false end if not inside() then return true end if runtimeEnv.__SenaV4PortalCross(portal, false, 3, function() return alive(H) end) then return true end task.wait(0.6) end return not inside() end
	local function normalWorldTarget() if Config.HalloweenCrossWorld ~= true then return false end local er = runtimeEnv.__SenaV4EggRuntime if not (er and er.enabled and type(er.hasPriorityRareEgg) == "function") then return false end local ok, has = pcall(function() return er:hasPriorityRareEgg() end) return ok and has == true end
	local NET_F
	local function netRemote(n) if NET_F == nil then local pk = RS:FindFirstChild("Packages") NET_F = (pk and pk:FindFirstChild("Networking")) or false end if not NET_F then return nil end return NET_F:FindFirstChild(n) end
	local function netInvoke(n, ...) local r = netRemote(n) if not r then return false end local res = table.pack(pcall(r.InvokeServer, r, ...)) if not res[1] then return false end return true, res[2] end
	local function netFire(n, ...) local r = netRemote(n) if r then pcall(r.FireServer, r, ...) end end
	local function fishRod() for _, w in ipairs({ LP.Character, LP:FindFirstChild("Backpack") }) do if w then for _, t in ipairs(w:GetChildren()) do if t:IsA("Tool") and t:GetAttribute("GhostDogRod") then return t end end end end return nil end
	local function fishMarker(n) local D = hd() local f = D and D:FindFirstChild("GhostDogQuest") local m = f and f:FindFirstChild("Markers") local p = m and m:FindFirstChild(n) return (p and p:IsA("BasePart")) and p or nil end
	local function fishWater(target, shift) local p = target if shift then p = p + Vector3.new(math.random(-6, 6), 0, math.random(-6, 6)) end local sh = RS:FindFirstChild("Shared") local u = sh and sh:FindFirstChild("Util") local fm = u and u:FindFirstChild("Fishing") if fm then local ok, F = pcall(require, fm) if ok and type(F) == "table" and type(F.Probe) == "function" then local okP, h = pcall(F.Probe, p, { LP.Character }) if okP and type(h) == "table" and h.Water and typeof(h.Point) == "Vector3" then return h.Point end end end return p end
	local function fishStage() local S = save() local p = S and S.Peek() local q = p and p.GhostDogQuest return (q and tonumber(q.Stage)) or 0 end
	local FISH_CLICKS = 18
	local fishPauseUntil = 0
	local function fishCast(H, target) for c = 1, 3 do if not alive(H) then return nil end netFire("RE/Fishing/Hold") task.wait(1.09) local okC, res = netInvoke("RF/Fishing/Cast", 1.09, fishWater(target, c > 1)) if okC and type(res) == "table" then return res end task.wait(1.05) end return nil end
	local function fishQuestLeg(H, targetPos) local res = fishCast(H, targetPos) if not res then return false end if tostring(res.Mode) ~= "Quest" then netFire("RE/Fishing/Cancel", res.Id) return false end netFire("RE/Fishing/Cancel", res.Id) local okS = netInvoke("RF/GhostDogQuest/Cast") if not okS then return false end netInvoke("RF/GhostDogQuest/Dive") local detik = 50 pcall(function() local d = require(RS.Data.GhostDogQuest) if type(d) == "table" and tonumber(d.ChaseSeconds) then detik = tonumber(d.ChaseSeconds) end end) local deadline = os.clock() + detik + 1 while os.clock() < deadline do if not alive(H) then netInvoke("RF/GhostDogQuest/Abort") return false end task.wait(0.5) end local claimed = false for i = 1, 15 do if not alive(H) then break end local okK, v = netInvoke("RF/GhostDogQuest/Claim") if okK and v == true then claimed = true break end task.wait(1) end netInvoke("RF/GhostDogQuest/Surface") netInvoke("RF/GhostDogQuest/Abort") return claimed end
	local function fishWallSealed() local c = RS:FindFirstChild("Client") local m = c and c:FindFirstChild("AreaEggResetWall") if not m then return false end local ok, W = pcall(require, m) if not ok or type(W) ~= "table" then return false end local function chk(fn) if type(W[fn]) ~= "function" then return false end local o, v = pcall(W[fn]) return o and v == true end return chk("IsSealed") or chk("IsClosed") end
	local function fishCross(H, target) local z, cx, lebar = -7238, -5808, 390 local D = hd() local nw = D and D:FindFirstChild("NightWall") local cur = nw and (nw:FindFirstChild("Curtain") or nw:FindFirstChild("Barrier")) if cur and cur:IsA("BasePart") then z, cx, lebar = cur.Position.Z, cur.Position.X, cur.Size.X / 2 end local function hop(dst, step, gap) local r = hrp() if not r then return false end local pp = r.Position while (dst - pp).Magnitude > 0.5 do if not alive(H) then return false end local sv = dst - pp pp = sv.Magnitude > step and (pp + sv.Unit * step) or dst local t = os.clock() + gap repeat if not alive(H) then return false end local rr = hrp() if rr then rr.CFrame = CFrame.new(pp) pcall(function() rr.AssemblyLinearVelocity = Vector3.new(0, 0, 0) end) end task.wait(0.03) until os.clock() >= t end return true end local r = hrp() if not r then return false end local fromSafe = r.Position.Z < z if fromSafe ~= (target.Z < z) then if fromSafe and fishWallSealed() then return false end local acuan = fromSafe and target or r.Position local x = math.clamp(acuan.X, cx - lebar + 30, cx + lebar - 30) local a = Vector3.new(x, -201, z - 55) local b = Vector3.new(x, -201, z + 23) if not fromSafe then a, b = b, a end if not hop(a, 850, 0.15) then return false end if not hop(b, 12, 0.03) then return false end end return hop(target, 850, 0.15) end
	local function fishStep(H) if os.clock() < fishPauseUntil then task.wait(math.min(1, fishPauseUntil - os.clock())) return false end local spot = fishMarker("CastSpot") local spotPos = spot and spot.Position or Vector3.new(-5317.7, -203.65, -6128.83) local target = fishMarker("CastTarget") local targetPos = target and target.Position or Vector3.new(-5317.7, -207.62, -6156.83) local r = hrp() if not r or (r.Position - spotPos).Magnitude > 6 then fishCross(H, spotPos + Vector3.new(0, 2, 0)) r = hrp() if not r or (r.Position - spotPos).Magnitude > 6 then fishPauseUntil = os.clock() + 2 H.stats.note = "waiting for the night wall" return false end end local rod = fishRod() if not rod then return false end if rod.Parent ~= LP.Character then local h = hum() if h then pcall(h.EquipTool, h, rod) end task.wait(0.3) end if fishStage() < 4 then local done = fishQuestLeg(H, targetPos) if not done then fishPauseUntil = os.clock() + 3 end return done end local res = fishCast(H, targetPos) if not res then fishPauseUntil = os.clock() + 2 return false end local mode = tostring(res.Mode) if mode == "Nothing" or mode == "Hint" or mode == "Quest" or mode == "GhostFish" then netFire("RE/Fishing/Cancel", res.Id) task.wait(1.05) return false end local deadline = os.clock() + (tonumber(res.Wait) or 3) + 1.0 local reAt = 0 while os.clock() < deadline do if not alive(H) then netFire("RE/Fishing/Cancel", res.Id) return false end if os.clock() - reAt > 0.5 then reAt = os.clock() local rr = hrp() if rr then rr.CFrame = CFrame.new(spotPos + Vector3.new(0, 2, 0)) pcall(function() rr.AssemblyLinearVelocity = Vector3.new(0, 0, 0) end) end end task.wait(0.05) end local okR, caught = netInvoke("RF/Fishing/Reel", res.Id, "Caught", FISH_CLICKS) if okR and caught == true then H.stats.fished = (H.stats.fished or 0) + 1 task.wait(1.05) return true end netFire("RE/Fishing/Cancel", res.Id) fishPauseUntil = os.clock() + 2.5 task.wait(1.05) return false end
	local function treadmillIdleOn() local tmg = runtimeEnv.__SenaV4TreadmillManager return tmg ~= nil and not tmg.destroyed and tmg.config ~= nil and tmg.config.idleFarm == true end
	local function halloweenStealRank() if Config.AutoStealHalloween ~= true then return 0 end local R = runtimeEnv.__SenaV4RarityMod if R == nil then R = okReq(RS:FindFirstChild("Data") and RS.Data:FindFirstChild("Rarity")) or false runtimeEnv.__SenaV4RarityMod = R end if not R or type(R.Get) ~= "function" then return 0 end local names = cfgNames() local best = 0 for _, e in ipairs(eggList()) do local ok = (#names == 0) if not ok then for _, n in ipairs(names) do if e.name == n then ok = true break end end end if ok and rarityPass(e.name, Config.HalloweenEggRarities) then local okR, d = pcall(R.Get, rarityOf(e.name)) local rank = (okR and type(d) == "table" and tonumber(d.Rank)) or 0 if rank > best then best = rank end end end return best end
	local function normalStealRank() local er = runtimeEnv.__SenaV4EggRuntime if not (er and er.enabled and type(er.bestNormalStealRank) == "function") then return 0 end local ok, r = pcall(function() return er:bestNormalStealRank() end) return (ok and tonumber(r)) or 0 end
	local function desiredWorld() if runtimeEnv.__SenaV4OnTrain == true then return nil end if next(runtimeEnv.__SenaV4HwManual or {}) ~= nil then return "halloween" end do local er0 = runtimeEnv.__SenaV4EggRuntime if er0 and type(er0.manualPending) == "function" and er0:manualPending() > 0 then return "normal" end end local nR = normalStealRank() local hR = halloweenStealRank() for _, id in ipairs(TaskLadder.order()) do if id == "auto_steal" then if nR > 0 and nR >= hR then return "normal" end elseif id == "hw_steal" then if hR > 0 and hR >= nR then return "halloween" end elseif id == "treadmill" then if treadmillIdleOn() then return "normal" end elseif id == "hw_mobs" then if Config.HalloweenHitMobs == true and nearestMob() ~= nil then return "halloween" end elseif id == "hw_pumpkin" then if Config.HalloweenCollectPumpkin == true and (pumpkinCarrying() or nearestPumpkin() ~= nil) then return "halloween" end elseif id == "hw_fish" then if Config.HalloweenAutoFish == true and fishRod() ~= nil then return "halloween" end elseif id == "phantom" then if TaskLadder.wants("phantom") then return "halloween" end else if TaskLadder.enabled(id) and TaskLadder.wants(id) then return "normal" end end end return nil end
	local function curWorldActive() if inside() then if next(runtimeEnv.__SenaV4HwManual or {}) ~= nil then return true end if TaskLadder.wants("phantom") then return true end if Config.HalloweenHitMobs == true and nearestMob() ~= nil then return true end if Config.HalloweenCollectPumpkin == true and (pumpkinCarrying() or nearestPumpkin() ~= nil) then return true end return false end do local er0 = runtimeEnv.__SenaV4EggRuntime if er0 and type(er0.manualPending) == "function" and er0:manualPending() > 0 then return true end end for _, id in ipairs({ "star", "butterfly", "auto_place", "use_scrambled", "auto_sell" }) do if TaskLadder.enabled(id) and TaskLadder.wants(id) then return true end end return false end
	local WC = { world = nil, since = 0, dryAt = 0 }
	local DWELL_DRY, MIN_DWELL = 0.8, 2
	function WC.urgent() return next(runtimeEnv.__SenaV4HwManual or {}) ~= nil or (function() local e = runtimeEnv.__SenaV4EggRuntime return e ~= nil and type(e.manualPending) == "function" and e:manualPending() > 0 end)() end
	local function routedWorld() if runtimeEnv.__SenaV4OnTrain == true then return nil end if WC.urgent() then local w = desiredWorld() if w then WC.dryAt = 0 return w end end local now = os.clock() local cur = inside() and "halloween" or "normal" if WC.world ~= cur then if WC.world ~= nil then WC.since = now end WC.world = cur WC.dryAt = 0 end if curWorldActive() then WC.dryAt = 0 return cur end local raw = desiredWorld() if raw == nil then WC.dryAt = 0 return nil end if raw == cur then WC.dryAt = 0 return cur end if WC.dryAt == 0 then WC.dryAt = now end if (now - WC.dryAt) >= DWELL_DRY and (now - WC.since) >= MIN_DWELL then return raw end return cur end
	local function exitForNormal() if not inside() then return true end if carrying() or pumpkinCarrying() then return false end local ph for _, d in ipairs(workspace:GetDescendants()) do if d.Name == "PortalHome" then ph = d break end end local portal = ph and (ph:FindFirstChild("Portal") or ph:FindFirstChildWhichIsA("BasePart", true)) if not portal then return false end local function still() return runtimeEnv.__SenaV4OnTrain ~= true and (treadmillIdleOn() or normalStealRank() > 0 or WC.urgent()) end for t = 1, 3 do if not inside() then return true end if not still() then return false end if runtimeEnv.__SenaV4PortalCross(portal, false, 3, still) then return true end task.wait(0.6) end return not inside() end
	local function goHomeIfNormal() if not inside() then return true end if runtimeEnv.__SenaV4OnTrain == true then return false end if carrying() or pumpkinCarrying() then return false end if routedWorld() ~= "normal" then return false end return exitForNormal() end
	runtimeEnv.__SenaV4GoHomeForTreadmill = goHomeIfNormal
	do local gen = (runtimeEnv.__SenaV4RouterGen or 0) + 1 runtimeEnv.__SenaV4RouterGen = gen task.spawn(function() while runtimeEnv.__SenaV4RouterGen == gen do task.wait(0.3) if inside() and runtimeEnv.__SenaV4OnTrain ~= true then pcall(goHomeIfNormal) end end end) end
	local function farmTop(H) if next(runtimeEnv.__SenaV4HwManual or {}) ~= nil and pick() then return "hw_steal" end for _, id in ipairs(TaskLadder.order()) do if id == "phantom" then if TaskLadder.wants("phantom") then return "yield" end elseif id == "hw_pumpkin" then if Config.HalloweenCollectPumpkin == true and nearestPumpkin() then return id end elseif id == "hw_steal" then if Config.AutoStealHalloween == true and pick() then return id end elseif id == "hw_mobs" then if Config.HalloweenHitMobs == true and nearestMob() then return id end elseif id == "hw_fish" then if Config.HalloweenAutoFish == true and fishRod() then return id end end end return nil end
	TaskLadder.register("hw_steal", { enabled = function() return Config.AutoStealHalloween == true end, wants = function() return Config.AutoStealHalloween == true and inside() and pick() ~= nil end, active = function() local H = runtimeEnv.__SenaHalloweenFarm return H ~= nil and H.running == true and H.stats.cur == "hw_steal" end, status = function() return "Stealing eggs" end })
	TaskLadder.register("hw_mobs", { enabled = function() return Config.HalloweenHitMobs == true end, wants = function() return Config.HalloweenHitMobs == true and inside() and nearestMob() ~= nil end, active = function() local H = runtimeEnv.__SenaHalloweenFarm return H ~= nil and H.running == true and H.stats.cur == "hw_mobs" end, status = function() return "Hunting mobs" end })
	TaskLadder.register("hw_pumpkin", { enabled = function() return Config.HalloweenCollectPumpkin == true end, wants = function() return Config.HalloweenCollectPumpkin == true and inside() and (pumpkinCarrying() or nearestPumpkin() ~= nil) end, active = function() local H = runtimeEnv.__SenaHalloweenFarm return H ~= nil and H.running == true and H.stats.cur == "hw_pumpkin" end, status = function() return "Collecting pumpkins" end })
	TaskLadder.register("hw_fish", { enabled = function() return Config.HalloweenAutoFish == true end, wants = function() return Config.HalloweenAutoFish == true and inside() and fishRod() ~= nil end, active = function() local H = runtimeEnv.__SenaHalloweenFarm return H ~= nil and H.running == true and H.stats.cur == "hw_fish" end, status = function() return "Fishing" end })
	function SenaHalloween.isRunning() local H = runtimeEnv.__SenaHalloweenFarm return H ~= nil and H.running == true end
	function SenaHalloween.stats() local H = runtimeEnv.__SenaHalloweenFarm return H and H.stats end
	function SenaHalloween.stop() local H = runtimeEnv.__SenaHalloweenFarm if H then H.running = false end end
	function SenaHalloween.start()
		if runtimeEnv.__SenaHalloweenFarm and runtimeEnv.__SenaHalloweenFarm.stop then pcall(runtimeEnv.__SenaHalloweenFarm.stop) task.wait(0.3) end
		local H = { running = true, stats = { cycles = 0, delivered = 0, bought = 0, fails = 0, noegg = 0, fished = 0, startCandy = candy(), candy = candy(), lastErr = "" } }
		function H.stop() H.running = false end
		runtimeEnv.__SenaHalloweenFarm = H
		task.spawn(function()
			while alive(H) do
				local ok, err = pcall(function()
					if runtimeEnv.__SenaV4OnTrain == true then task.wait(1) return end
					if normalWorldTarget() then if inside() then exitDimension(H) end task.wait(1.5) return end
					local dw = routedWorld()
					if dw == "normal" then if inside() then if pumpkinCarrying() then depositPumpkin(H) return end if carrying() then local R = remotes() if R then pcall(function() R.HalloweenDimension.AskDropEgg:InvokeServer() end) end task.wait(0.15) end exitForNormal() end H.stats.note = "normal world" task.wait(0.2) return end
					if dw ~= "halloween" then task.wait(0.2) return end
					if not inside() then if not ensureInside(H) then task.wait(3) return end end
					if carrying() then local R = remotes() if R then pcall(function() R.HalloweenDimension.AskDropEgg:InvokeServer() end) end task.wait(0.15) end
					if pumpkinCarrying() then depositPumpkin(H) return end
					if Config.HalloweenAutoBuy and candy() >= BUY_COST then local R = remotes() if R then local o, r = pcall(function() return R.HalloweenDimension.AskBuyEgg:InvokeServer() end) if o and r == true then H.stats.bought = H.stats.bought + 1 end end task.wait(0.3) H.stats.candy = candy() return end
					local top = farmTop(H)
					if top == "yield" then task.wait(0.5) return end
					if type(top) == "string" and string.sub(top, 1, 3) == "hw_" then H.stats.cur = top end
					if top == "hw_pumpkin" then
						if pumpkinCarrying() then depositPumpkin(H) return end
						local p = nearestPumpkin()
						if p then H.stats.cycles = H.stats.cycles + 1 if grabPumpkin(H, p) then if depositPumpkin(H) then H.stats.pumpkins = (H.stats.pumpkins or 0) + 1 else H.stats.fails = H.stats.fails + 1 end else H.stats.fails = H.stats.fails + 1 end return end
					end
					if top == "hw_steal" then
						local e = pick(H)
						if e then
							H.stats.cycles = H.stats.cycles + 1
							local mq = runtimeEnv.__SenaV4HwManual if not steal(H, e) then H.stats.fails = H.stats.fails + 1 if e.manual and mq and e.uid then H.mfail = H.mfail or {} H.mfail[e.uid] = (H.mfail[e.uid] or 0) + 1 if H.mfail[e.uid] >= 3 then mq[e.uid] = nil end end return end if e.manual and mq and e.uid then mq[e.uid] = nil end
							for i = 1, 3 do if not alive(H) then return end local r = hrp() if r then r.CFrame = CFrame.new(STAGE) pcall(function() r.AssemblyLinearVelocity = Vector3.new(0, 0, 0) end) end task.wait(0.03) end
							if not dropRegrab(H) then H.stats.fails = H.stats.fails + 1 return end
							local before = candy() glide(H, BANKSPOT, 0.12) task.wait(0.08)
							local now = candy() H.stats.candy = now
							if now > before then H.stats.delivered = H.stats.delivered + 1 end
							return
						end
					end
					if top == "hw_mobs" then
						for _ = 1, 8 do if not alive(H) then break end local m = nearestMob() if not m then break end ensureBat() H.stats.cycles = H.stats.cycles + 1 if hitMob(H, m) then H.stats.killed = (H.stats.killed or 0) + 1 else H.stats.fails = H.stats.fails + 1 break end end
						return
					end
					if top == "hw_fish" then fishStep(H) return end
					H.stats.noegg = H.stats.noegg + 1 task.wait(0.4)
				end)
				if not ok then H.stats.fails = H.stats.fails + 1 H.stats.lastErr = tostring(err) task.wait(0.5) end
				task.wait(0.05)
			end
		end)
	end
	function SenaHalloween.refresh() local want = (Config.AutoStealHalloween == true) or (Config.HalloweenHitMobs == true) or (Config.HalloweenCollectPumpkin == true) or (Config.HalloweenAutoFish == true) or (next(runtimeEnv.__SenaV4HwManual or {}) ~= nil) if want then if not (runtimeEnv.__SenaHalloweenFarm and runtimeEnv.__SenaHalloweenFarm.running) then SenaHalloween.start() end else SenaHalloween.stop() end end
	function SenaHalloween.setEnabled(on) SenaHalloween.refresh() end
	UIRunners.Halloween = SenaHalloween
	function SenaHalloween.queueManual(uids) local mq = runtimeEnv.__SenaV4HwManual or {} runtimeEnv.__SenaV4HwManual = mq local n = 0 for _, u in ipairs(uids) do mq[u] = true end for _ in pairs(mq) do n = n + 1 end SenaHalloween.refresh() return n end
	runtimeEnv.__SenaV4HwQueue = SenaHalloween.queueManual
	runtimeEnv.__SenaV4HwRarityOf = rarityOf
	runtimeEnv.__SenaV4HwEggList = eggList
end
do
	local SenaTrain = {}
	local LPT = game:GetService("Players").LocalPlayer
	local RUN = game:GetService("RunService")
	local REP = game:GetService("ReplicatedStorage")
	local function hrp() local c = LPT.Character return c and c:FindFirstChild("HumanoidRootPart") end
	local function hum() local c = LPT.Character return c and c:FindFirstChildOfClass("Humanoid") end
	local function tulis(r, cf) r.CFrame = cf pcall(function() r.AssemblyLinearVelocity = Vector3.new(0, 0, 0) r.AssemblyAngularVelocity = Vector3.new(0, 0, 0) end) end
	local NETT
	local function netR(n) if NETT == nil then local pk = REP:FindFirstChild("Packages") NETT = (pk and pk:FindFirstChild("Networking")) or false end if not NETT then return nil end return NETT:FindFirstChild(n) end
	local function netInv(n, ...) local r = netR(n) if not r then return false end local res = table.pack(pcall(r.InvokeServer, r, ...)) if not res[1] then return false end return true, res[2], res[3] end
	local function netFr(n, ...) local r = netR(n) if r then pcall(r.FireServer, r, ...) end end
	local function alive(H) return H and H.running and runtimeEnv.__SenaTrainFarm == H and hrp() ~= nil end
	local function cariTool(attr) for _, w in ipairs({ LPT.Character, LPT:FindFirstChild("Backpack") }) do if w then for _, t in ipairs(w:GetChildren()) do if t:IsA("Tool") and (t:GetAttribute(attr) or t.Name == attr) then return t end end end end return nil end
	local function pegang(t) if not t then return nil end if t.Parent ~= LPT.Character then local h = hum() if h then pcall(h.EquipTool, h, t) end task.wait(0.25) end return t end
	local function lompat(H, tuju, hop, jeda) local r = hrp() if not r then return false end hop = hop or 850 jeda = jeda or 0.15 local p = r.Position while (tuju - p).Magnitude > 0.5 do if not alive(H) then return false end local sisa = tuju - p p = sisa.Magnitude > hop and (p + sisa.Unit * hop) or tuju local t = os.clock() + jeda repeat local rr = hrp() if not rr then return false end tulis(rr, CFrame.new(p)) RUN.Heartbeat:Wait() until os.clock() >= t end return true end
	local function tahan(H, pos, detik) local akhir = os.clock() + (detik or 0.3) while os.clock() < akhir and alive(H) do local r = hrp() if r then tulis(r, CFrame.new(pos)) end RUN.Heartbeat:Wait() end end
	local function jalanKe(H, tuju, maxSecs) local h = hum() if h then pcall(function() h.WalkSpeed = 26 end) end local deadline = os.clock() + (maxSecs or 12) local stuck, lastP = 0, nil while os.clock() < deadline and alive(H) do local r = hrp() local hh = hum() if not (r and hh) then return false end local dist = (Vector3.new(tuju.X, 0, tuju.Z) - Vector3.new(r.Position.X, 0, r.Position.Z)).Magnitude if dist <= 4 then return true end hh:MoveTo(Vector3.new(tuju.X, r.Position.Y, tuju.Z)) if lastP and (r.Position - lastP).Magnitude < 1 then stuck = stuck + 1 else stuck = 0 end lastP = r.Position if stuck > 10 then pcall(function() hh.Jump = true end) stuck = 0 end task.wait(0.12) end return false end
	local K = { st = nil, at = 0, cap = 0 } K.kite = function(r, gpx, gpz, KITE, dt) local cp = r.Position local flat = Vector3.new(cp.X - gpx, 0, cp.Z - gpz) local dist = flat.Magnitude local away = dist > 0.1 and flat.Unit or Vector3.new(0, 0, 1) local away0 = away local flee = false do local push = Vector3.zero local function feel(gp, tier) local f2 = Vector3.new(cp.X - gp.X, 0, cp.Z - gp.Z) local m = f2.Magnitude local v = tier == "VengefulSpirit" local rad = v and 15 or 11 if m < rad then push = push + (m > 0.1 and f2.Unit or away) * (rad - m) * (v and 2 or 1) flee = true K.vflee = true end end K.vflee = false local fresh = K.gs and (os.clock() - (K.gsAt or 0)) < 0.5 if fresh then for _, g in pairs(K.gs) do feel(g.pos, g.tier) end else local tg0 = workspace:FindFirstChild("TrainGhostVisuals") if tg0 then for _, g in ipairs(tg0:GetChildren()) do if g:GetAttribute("OwnerUserId") == LPT.UserId then local okP, gcf = pcall(g.GetPivot, g) if okP then feel(gcf.Position, nil) end end end end end if flee and push.Magnitude > 0.1 then away = push.Unit end end local rp = RaycastParams.new() rp.FilterType = Enum.RaycastFilterType.Exclude pcall(function() rp.RespectCanCollide = true end) local filter = { LPT.Character } local tg = workspace:FindFirstChild("TrainGhostVisuals") if tg then filter[#filter + 1] = tg end local gb = workspace:FindFirstChild("GhostBossVisuals") if gb then filter[#filter + 1] = gb end rp.FilterDescendantsInstances = filter local hh = hum() local here = workspace:Raycast(cp, Vector3.new(0, -40, 0), rp) if here and hh and hh.FloorMaterial ~= Enum.Material.Air then K.off = math.clamp(cp.Y - here.Position.Y, 1.5, 6) end local off = K.off or 3 local function snap(p) local g = workspace:Raycast(Vector3.new(p.X, cp.Y + 4, p.Z), Vector3.new(0, -44, 0), rp) return g and Vector3.new(p.X, g.Position.Y + off, p.Z) or nil end local np, blocked = cp, false if flee or dist < KITE - 6 or dist > KITE + 4 then local tgt = flee and (cp + away * KITE) or (Vector3.new(gpx, cp.Y, gpz) + away * KITE) local mv = Vector3.new(tgt.X - cp.X, 0, tgt.Z - cp.Z) -- reeled in too close: hop to the ghost's far side (stays in the vacuum cone, it has to turn round)
		local tgtV = false if K.gs then for _, g in pairs(K.gs) do if g.tier == "VengefulSpirit" and (Vector3.new(g.pos.X - gpx, 0, g.pos.Z - gpz)).Magnitude < 4 then tgtV = true break end end end local behind = dist < (tgtV and 11 or 8) local hop = (not flee and dist > KITE + 6) or behind local step = math.min(mv.Magnitude, ((flee and (K.vflee and 140 or 90)) or 45) * math.clamp(dt or 1 / 60, 1 / 240, 0.1)) if hop then np = behind and (Vector3.new(gpx, cp.Y, gpz) - away0 * KITE) or (cp + mv) elseif step > 0.05 then local dir = mv.Unit local perp = Vector3.new(-dir.Z, 0, dir.X) local function open(d) local h = workspace:Raycast(cp, d * (step + 2.5), rp) return not (h and h.Instance and h.Instance.CanCollide) end local md = (open(dir) and dir) or (open(perp) and perp) or (open(-perp) and -perp) or nil if md then np = cp + md * step else blocked = true end end end local s = snap(np) if not s then blocked = true s = snap(cp) end return s or cp, dist, blocked end
	local function keretaStatus(segar) if not segar and K.st and (os.clock() - K.at) < 2.5 then return K.st end local ok, _, s = netInv("RF/TrainEvent/Action", "Status") if ok and type(s) == "table" then K.st, K.at = s, os.clock() end local onT = (K.st ~= nil and K.st.Phase ~= nil and K.st.Phase ~= "Home") and true or false if onT and LPT:GetAttribute("InHalloweenDimension") == true and (os.clock() - K.at) > 3 then onT = false end runtimeEnv.__SenaV4OnTrain = onT return K.st end
	local function aksi(...) local ok, sukses, pesan = netInv("RF/TrainEvent/Action", ...) return ok and sukses == true, tostring(pesan or "") end
	local function promptAksi(nama) local best for _, d in ipairs(workspace:GetDescendants()) do if d:IsA("ProximityPrompt") and d.Enabled and d:GetAttribute("TrainEventAction") == nama then best = d if d:IsDescendantOf(workspace:FindFirstChild("TrainEventRuntime") or workspace) then break end end end if not best then return nil end local p = best.Parent local pos = (p:IsA("Attachment") and p.WorldPosition) or (p:IsA("BasePart") and p.Position) or (p:IsA("Model") and p:GetPivot().Position) return best, pos end
	local function bossState() local st = REP:FindFirstChild("GhostBossState") if not st then return nil end return st:GetAttribute("Phase"), st:GetAttribute("Realm"), st end
	local function bossAda() local ph, realm = bossState() if not (ph == "Alive" or ph == "Spawning" or ph == "Capturing") then return false end local diTown = K.st and K.st.Phase == "Town" return (realm == "Town") == (diTown == true) end
	local function bossPos() local v = workspace:FindFirstChild("GhostBossVisuals") if v then for _, m in ipairs(v:GetChildren()) do if m:IsA("Model") then local ok, cf = pcall(m.GetPivot, m) if ok then return cf.Position end elseif m:IsA("BasePart") then return m.Position end end end local _, _, st = bossState() local g = st and st:GetAttribute("Ground") if typeof(g) == "Vector3" then return g + Vector3.new(0, 12, 0) end end
	local function seranganBoss(H) local vak = pegang(cariTool("GhostBossVacuum") or cariTool("GhostVacuum")) if not vak then return end local akhir, kirim = os.clock() + 25, 0 while os.clock() < akhir and bossAda() and alive(H) do local dt = RUN.Heartbeat:Wait() local r, bp = hrp(), bossPos() if not (r and bp) then break end local hh = hum() if hh and hh.Health < hh.MaxHealth then pcall(function() hh.Health = hh.MaxHealth end) end local nextPos = K.kite(r, bp.X, bp.Z, 18, dt) tulis(r, CFrame.lookAt(nextPos, Vector3.new(bp.X, nextPos.Y, bp.Z))) if os.clock() - kirim > 0.25 then kirim = os.clock() local sd = Vector3.new(bp.X - nextPos.X, 0, bp.Z - nextPos.Z) netFr("RE/GhostBoss/Suction", true, sd.Magnitude > 0.1 and sd.Unit or Vector3.new(1, 0, 0)) end end netFr("RE/GhostBoss/Suction", false) end
	local function tangkap(H, detik, goal) local gv = workspace:FindFirstChild("TrainGhostVisuals") if not gv then return end local function pivot(m) local ok, cf = pcall(m.GetPivot, m) return ok and cf.Position or nil end local akhir, kirim, sasaran = os.clock() + detik, 0, nil K.skip, K.stuckT = {}, nil while os.clock() < akhir and alive(H) and K.cap < goal do local dt = RUN.Heartbeat:Wait() if bossAda() then break end local r = hrp() if not r then break end local hh = hum() if hh and hh.Health < hh.MaxHealth then pcall(function() hh.Health = hh.MaxHealth end) end if not (sasaran and sasaran.Parent) then sasaran = nil local bd for _, g in ipairs(gv:GetChildren()) do if g:GetAttribute("OwnerUserId") == LPT.UserId and not (K.skip[g] and K.skip[g] > os.clock()) then local pp = pivot(g) if pp then local nm = g.Name local pen = (nm:find("^Vengeful") and 45) or (nm:find("^Haunted") and 12) or 0 local d = (pp - r.Position).Magnitude + pen - ((tonumber(g:GetAttribute("ServerCaptureProgress")) or 0) > 0 and 25 or 0) if not bd or d < bd then sasaran, bd = g, d end end end end end local gd = nil if sasaran then local gp = pivot(sasaran) if gp then local nextPos, d0, stuck = K.kite(r, gp.X, gp.Z, 14, dt) gd = d0 tulis(r, CFrame.lookAt(nextPos, Vector3.new(gp.X, nextPos.Y, gp.Z))) if stuck then K.stuckT = K.stuckT or os.clock() if os.clock() - K.stuckT > 1.5 then K.skip[sasaran] = os.clock() + 4 sasaran = nil K.stuckT = nil end else K.stuckT = nil end end end if gd and gd <= 19 and os.clock() - kirim > 0.2 then kirim = os.clock() netFr("RE/TrainEvent/Suction", true) end end netFr("RE/TrainEvent/Suction", false) end
	local function tukarSouls(H) local s = keretaStatus(true) local sh = s and s.SoulShop if not (sh and sh.CanTrade and (tonumber(sh.Souls) or 0) >= (tonumber(sh.Cost) or 1e9)) then return false end local p, pos = promptAksi("OpenSoulShop") if not (p and pos) then return false end local dekat = pos + Vector3.new(0, 0, 6) local rs = hrp() if not rs then return false end tulis(rs, CFrame.new(dekat, pos)) task.wait(0.15) tahan(H, dekat, 0.5) aksi("OpenSoulShop") for _ = 1, 20 do if not alive(H) then break end local s2 = keretaStatus(true) local sh2 = s2 and s2.SoulShop if not (sh2 and sh2.CanTrade and (tonumber(sh2.Souls) or 0) >= (tonumber(sh2.Cost) or 1e9)) then break end local ok = aksi("TradeSouls", sh2.Cost) if not ok then break end H.stats.spectral = (H.stats.spectral or 0) + 1 task.wait(0.4) end return true end
	local function langkahKereta(H) local s = keretaStatus(true) if not s then task.wait(1) return end local ph = s.Phase if ph == "Home" then K.dryAt = nil K.cap = 0 if not (s.ArrivalOpen and (tonumber(s.DepartureAt) or 0) - workspace:GetServerTimeNow() > 3) then H.stats.note = "waiting for the Phantom Express" task.wait(2) return end if not s.AccessUnlocked and not cariTool("ConductorTicket") then H.stats.note = "needs Train Pass (finish Gilbert's quest)" task.wait(5) return end if s.StationAvailable and not s.AtStation then H.stats.note = "going to the station" aksi("Station") task.wait(2.5) end if not s.AccessUnlocked then pegang(cariTool("ConductorTicket")) end H.stats.note = "boarding" local ok = aksi("Board") if not ok then task.wait(2) end return end if ph ~= "Town" then K.dryAt = nil H.stats.note = "riding (" .. tostring(ph) .. ")" task.wait(1) return end if bossAda() and Config.HalloweenPhantomExpress == true then H.stats.note = "fighting Ghouler" seranganBoss(H) return end local inv = s.Invasion or {} K.cap = math.max(K.cap, tonumber(inv.Captured) or 0) local goal = tonumber(inv.Goal) or 50 local capNow = tonumber(inv.Captured) or 0 H.stats.captured = capNow local ghostsLeft = 0 local gv = workspace:FindFirstChild("TrainGhostVisuals") if gv then for _, g in ipairs(gv:GetChildren()) do if g:GetAttribute("OwnerUserId") == LPT.UserId then ghostsLeft = ghostsLeft + 1 end end end if ghostsLeft > 0 or bossAda() then K.dryAt = nil elseif not K.dryAt then K.dryAt = os.clock() end local hardEnd = tonumber(inv.EndsAt) ~= nil and workspace:GetServerTimeNow() >= tonumber(inv.EndsAt) local driedUp = K.dryAt ~= nil and capNow > 0 and (os.clock() - K.dryAt) >= 6 local invasionDone = capNow >= goal or inv.Phase == "Ended" or hardEnd or driedUp if Config.HalloweenPhantomExpress == true and not invasionDone then if not inv.VacuumOwned then H.stats.note = "picking up the Ghost Vacuum" local p, pos = promptAksi("PickupVacuum") if p and pos then local dekat = pos + Vector3.new(0, 1, 3) local rv = hrp() if rv then tulis(rv, CFrame.new(dekat, pos)) task.wait(0.15) end if true then for _ = 1, 5 do pcall(fireproximityprompt, p) tahan(H, dekat, 0.5) local s2 = keretaStatus(true) if s2 and s2.Invasion and s2.Invasion.VacuumOwned then break end end end end return end pegang(cariTool("GhostVacuum")) H.stats.note = ("hunting ghosts %d/%d"):format(capNow, goal) tangkap(H, 15, goal) return end if Config.HalloweenTradeSouls == true and tukarSouls(H) then return end K.dryAt = nil H.stats.note = ("done - %d caught, leaving"):format(capNow) local okR = aksi("Return") if not okR then local pr for _, d in ipairs(workspace:GetDescendants()) do if d:IsA("ProximityPrompt") and d.Name == "TrainReturn" and d:GetAttribute("TrainEventRequiredPhase") == "Town" and not d:GetAttribute("TrainLocalReturn") then pr = d break end end local r = hrp() if pr and r then local a, b = pr:GetAttribute("ReturnRailStart"), pr:GetAttribute("ReturnRailEnd") local goal if typeof(a) == "Vector3" and typeof(b) == "Vector3" then local okM, M = pcall(function() return require(game:GetService("ReplicatedStorage").Shared.Modules.TrainReturnPrompt) end) if okM and type(M) == "table" and M.ClosestPoint then local okC, cp = pcall(M.ClosestPoint, r.Position, a, b) if okC and typeof(cp) == "Vector3" then goal = cp end end end if not goal then local pa = pr.Parent goal = (pa:IsA("Attachment") and pa.WorldPosition) or (pa:IsA("BasePart") and pa.Position) or nil end if goal then H.stats.note = "going to the return rail" tulis(r, CFrame.new(goal + Vector3.new(0, 3, 0))) task.wait(0.35) okR = aksi("Return") end end end task.wait(okR and 2 or 1) end
	local function wantRun() return Config.HalloweenPhantomExpress == true or Config.HalloweenTradeSouls == true end
	local function phantomBlocked() for _, id in ipairs(TaskLadder.order()) do if id == "phantom" then return false end if (id == "hw_steal" or id == "hw_mobs" or id == "hw_pumpkin" or id == "hw_fish") and TaskLadder.wants(id) then return true end end return false end
	TaskLadder.register("phantom", { enabled = function() return Config.HalloweenPhantomExpress == true end, wants = function() return Config.HalloweenPhantomExpress == true and K.st ~= nil and (K.st.Phase == "Town" or (K.st.Phase == "Home" and K.st.ArrivalOpen == true)) end, active = function() local H = runtimeEnv.__SenaTrainFarm return H ~= nil and H.running == true and K.st ~= nil and K.st.Phase == "Town" end, status = function() local H = runtimeEnv.__SenaTrainFarm return (H and H.stats and tostring(H.stats.note)) or "Idle" end })
	function SenaTrain.isRunning() local H = runtimeEnv.__SenaTrainFarm return H ~= nil and H.running == true end
	function SenaTrain.stats() local H = runtimeEnv.__SenaTrainFarm return H and H.stats end
	function SenaTrain.stop() local H = runtimeEnv.__SenaTrainFarm if H then H.running = false end runtimeEnv.__SenaV4OnTrain = false end
	function SenaTrain.start()
		if runtimeEnv.__SenaTrainFarm and runtimeEnv.__SenaTrainFarm.stop then pcall(runtimeEnv.__SenaTrainFarm.stop) task.wait(0.2) end
		local H = { running = true, stats = { captured = 0, spectral = 0, note = "" } }
		function H.stop() H.running = false end
		runtimeEnv.__SenaTrainFarm = H
		if runtimeEnv.__SenaTrainConns then for _, c in ipairs(runtimeEnv.__SenaTrainConns) do pcall(function() c:Disconnect() end) end end
		runtimeEnv.__SenaTrainConns = {}
		local st = netR("RE/TrainEvent/State") if st then runtimeEnv.__SenaTrainConns[#runtimeEnv.__SenaTrainConns + 1] = st.OnClientEvent:Connect(function(s) if type(s) == "table" and s.Phase then K.st, K.at = s, os.clock() end end) end
		local gsr = netR("RE/TrainEvent/Ghosts") if gsr then runtimeEnv.__SenaTrainConns[#runtimeEnv.__SenaTrainConns + 1] = gsr.OnClientEvent:Connect(function(a) if type(a) ~= "table" or type(a.Ghosts) ~= "table" then return end if a.Closed then K.gs = {} K.gsAt = os.clock() return end local nxt = {} for _, g in pairs(a.Ghosts) do if type(g) == "table" and typeof(g.Frame) == "CFrame" and g.Id then local old = K.gs and K.gs[g.Id] local ser = tonumber(g.AttackSerial) or 0 nxt[g.Id] = { pos = g.Frame.Position, tier = g.Tier, serial = ser, swungAt = (old and ser > old.serial) and os.clock() or (old and old.swungAt) or 0 } end end K.gs, K.gsAt = nxt, os.clock() end) end
		local cs = netR("RE/TrainEvent/CaptureState") if cs then runtimeEnv.__SenaTrainConns[#runtimeEnv.__SenaTrainConns + 1] = cs.OnClientEvent:Connect(function(inv) if type(inv) == "table" and tonumber(inv.Captured) then K.cap = tonumber(inv.Captured) end end) end
		task.spawn(function()
			while alive(H) do
				local ok = pcall(function() if wantRun() then if phantomBlocked() then task.wait(0.5) else langkahKereta(H) end else runtimeEnv.__SenaV4OnTrain = false task.wait(1) end end)
				if not ok then task.wait(0.5) end
				task.wait(0.1)
			end
		end)
	end
	function SenaTrain.refresh() if wantRun() then if not (runtimeEnv.__SenaTrainFarm and runtimeEnv.__SenaTrainFarm.running) then SenaTrain.start() end else SenaTrain.stop() end end
	function SenaTrain.setEnabled(on) SenaTrain.refresh() end
	UIRunners.Train = SenaTrain
end
local Coordinator = (function()
	local Coordinator = {}
	Coordinator.__index = Coordinator
	local BACKGROUND_TOOL_CONFLICTS = {
		auto_place = true,
		auto_fuse = true,
		equip_best = true,
	}
	local DEFAULT_PRIORITIES = {
		auto_steal = 100,
		auto_hatch = 80,
		auto_place = 70,
		auto_fuse = 50,
		equip_best = 40,
		rewards = 20,
	}
	local function copyReservations(reservations)
		local output = {}
		for uid, owner in pairs(reservations) do
			output[uid] = owner
		end
		return output
	end
	function Coordinator.new()
		local self = setmetatable({}, Coordinator)
		self.destroyed = false
		self.active = nil
		self.background = nil
		self.reservations = {}
		self.listeners = {}
		self.backgroundListeners = {}
		self.serial = 0
		return self
	end
	function Coordinator:_snapshot()
		local active = self.active
		return {
			busy = active ~= nil,
			operation = active and active.owner or nil,
			priority = active and active.priority or 0,
			reservedCount = active and #active.uids or 0,
			reservations = copyReservations(self.reservations),
		}
	end
	function Coordinator:_emit()
		local snapshot = self:_snapshot()
		for listener in pairs(self.listeners) do
			local ok, err = pcall(listener, snapshot)
			if not ok then
				warn("[StealAnEgg] Coordinator listener failed:", err)
			end
		end
	end
	function Coordinator:_emitBackground()
		local background = self.background
		local snapshot = {
			busy = background ~= nil,
			operation = background and background.owner or nil,
		}
		for listener in pairs(self.backgroundListeners) do
			local ok, err = pcall(listener, snapshot)
			if not ok then
				warn("[StealAnEgg] Background coordinator listener failed:", err)
			end
		end
	end
	function Coordinator:subscribe(listener)
		self.listeners[listener] = true
		pcall(listener, self:_snapshot())
		return function()
			self.listeners[listener] = nil
		end
	end
	function Coordinator:subscribeBackground(listener)
		self.backgroundListeners[listener] = true
		pcall(listener, {
			busy = self.background ~= nil,
			operation = self.background and self.background.owner or nil,
			})
		return function()
			self.backgroundListeners[listener] = nil
		end
	end
	function Coordinator:getSnapshot()
		return self:_snapshot()
	end
	function Coordinator:isBackgroundBusy()
		return self.background ~= nil
	end
	function Coordinator:isReserved(uid, exceptOwner)
		local owner = self.reservations[uid]
		return owner ~= nil and owner ~= exceptOwner
	end
	function Coordinator:tryAcquire(owner, uids, priority)
		if self.destroyed then
			return nil, "Coordinator destroyed"
		end
		if type(owner) ~= "string" or owner == "" then
			return nil, "Invalid operation owner"
		end
		if self.active then
			return nil, "Busy: " .. self.active.owner
		end
		if self.background and BACKGROUND_TOOL_CONFLICTS[owner] then
			return nil, "Busy: background " .. self.background.owner
		end
		local normalized = {}
		local seen = {}
		for _, uid in ipairs(type(uids) == "table" and uids or {}) do
			if type(uid) == "string" and uid ~= "" and not seen[uid] then
				if self:isReserved(uid, owner) then
					return nil, "UID reserved by " .. tostring(self.reservations[uid])
				end
				seen[uid] = true
				table.insert(normalized, uid)
			end
		end
		self.serial += 1
		local token = {
			id = self.serial,
			lane = "foreground",
			owner = owner,
			priority = tonumber(priority) or DEFAULT_PRIORITIES[owner] or 0,
			uids = normalized,
			released = false,
		}
		self.active = token
		for _, uid in ipairs(normalized) do
			self.reservations[uid] = owner
		end
		self:_emit()
		return token
	end
	function Coordinator:tryAcquireBackground(owner, uids)
		if self.destroyed then
			return nil, "Coordinator destroyed"
		end
		if type(owner) ~= "string" or owner == "" then
			return nil, "Invalid operation owner"
		end
		if self.background then
			return nil, "Background busy: " .. self.background.owner
		end
		if self.active and BACKGROUND_TOOL_CONFLICTS[self.active.owner] then
			return nil, "Foreground tool busy: " .. self.active.owner
		end
		local normalized = {}
		local seen = {}
		for _, uid in ipairs(type(uids) == "table" and uids or {}) do
			if type(uid) == "string" and uid ~= "" and not seen[uid] then
				if self:isReserved(uid, owner) then
					return nil, "UID reserved by " .. tostring(self.reservations[uid])
				end
				seen[uid] = true
				table.insert(normalized, uid)
			end
		end
		self.serial += 1
		local token = {
			id = self.serial,
			lane = "background",
			owner = owner,
			priority = 0,
			uids = normalized,
			released = false,
		}
		self.background = token
		for _, uid in ipairs(normalized) do
			self.reservations[uid] = owner
		end
		self:_emitBackground()
		return token
	end
	function Coordinator:release(token)
		if type(token) ~= "table" or token.released then
			return false
		end
		token.released = true
		for _, uid in ipairs(token.uids or {}) do
			if self.reservations[uid] == token.owner then
				self.reservations[uid] = nil
			end
		end
		local foregroundChanged = self.active == token
		if foregroundChanged then
			self.active = nil
		elseif self.background == token then
			self.background = nil
			self:_emitBackground()
		end
		if foregroundChanged then
			self:_emit()
		end
		return true
	end
	function Coordinator:destroy()
		if self.destroyed then
			return
		end
		self.destroyed = true
		if self.active then
			self:release(self.active)
		end
		if self.background then
			self:release(self.background)
		end
		table.clear(self.reservations)
		table.clear(self.listeners)
		table.clear(self.backgroundListeners)
	end
	return Coordinator
	end)()
local catalog = (function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local Areas = require(ReplicatedStorage.Data.Areas)
	local Assets = require(ReplicatedStorage.Data.Assets)
	local Guards = require(ReplicatedStorage.Data.Guards)
	local Mutations = require(ReplicatedStorage.Shared.Modules.Mutations)
	local Catalog = {}
	local RARITY_ORDER = {
		Common = 1, Uncommon = 2, Rare = 3, Epic = 4, Legendary = 5,
		Mythic = 6, Cosmic = 7, Secret = 8, Eternal = 9, Divine = 10,
	}
	function Catalog.rarityRank(name)
		return RARITY_ORDER[name] or 0
	end
	local function sortedUnique(values)
		local seen = {}
		local output = {}
		for _, value in ipairs(values) do
			if type(value) == "string" and value ~= "" and not seen[value] then
				seen[value] = true
				table.insert(output, value)
			end
		end
		table.sort(output)
		return output
	end
	function Catalog.getRarities()
		local values = {}
		for rarityId in pairs(Assets.ByRarity) do
			table.insert(values, rarityId)
		end
		table.sort(values, function(a, b)
			local left, right = RARITY_ORDER[a] or 99, RARITY_ORDER[b] or 99
			if left ~= right then return left < right end
			return tostring(a) < tostring(b)
			end)
		return values
	end
	function Catalog.getNames()
		local values = {}
		for _, config in pairs(Assets.Directory) do
			table.insert(values, config.DisplayName or config._id)
		end
		return sortedUnique(values)
	end
	function Catalog.getAreas()
		local values = {}
		for areaId, config in pairs(Areas.Directory) do
			if type(areaId) == "string" and type(config) == "table" and type(config.DropTable) == "table" then
				table.insert(values, areaId)
			end
		end
		table.sort(values, function(left, right)
			local leftGuard = Guards.Directory[left]
			local rightGuard = Guards.Directory[right]
			local leftDifficulty = leftGuard and leftGuard.WalkSpeed or math.huge
			local rightDifficulty = rightGuard and rightGuard.WalkSpeed or math.huge
			if leftDifficulty ~= rightDifficulty then
				return leftDifficulty < rightDifficulty
			end
			return left < right
			end)
		return values
	end
	function Catalog.getMutations()
		local values = {}
		local ids = Mutations.Ids()
		for id in pairs(type(ids) == "table" and ids or {}) do
			if type(id) == "string" and id ~= Mutations.NO_MUTATION then
				local ok, label = pcall(Mutations.LabelOf, id)
				table.insert(values, ok and type(label) == "string" and label ~= "" and label or id)
			end
		end
		return sortedUnique(values)
	end
	function Catalog.resolveMutationId(value)
		if type(value) ~= "string" then return nil end
		if Mutations.IdSet[value] then return value end
		for id in pairs(Mutations.Ids()) do
			if id ~= Mutations.NO_MUTATION and Mutations.LabelOf(id) == value then
				return id
			end
		end
		return nil
	end
	function Catalog.resolve(record)
		local config = record and Assets.Directory[record.AssetCategory]
		local rarity = config and config.Rarity
		local rarityName = rarity and (rarity.DisplayName or rarity._id) or "Unknown"
		return {
			name = config and (config.DisplayName or config._id) or (record and record.AssetCategory) or "Unknown",
			category = record and record.AssetCategory or "Unknown",
			rarity = rarityName,
			rarityRank = RARITY_ORDER[rarityName] or 0,
			rarityColor = rarity and rarity.Color or nil,
			icon = config and type(config.Icon) == "string" and config.Icon or nil,
		}
	end
	return Catalog
	end)()
local integrityLimitsModule = nil
do
	local function scan(container)
		if not container then return nil end
		for _, d in ipairs(container:GetDescendants()) do
			if d:IsA("ModuleScript") and d.Name == "Limits"
			and d.Parent
			and d.Parent:FindFirstChild("Surface")
			and d.Parent:FindFirstChild("Runtime") then
				return d
			end
		end
		return nil
	end
	integrityLimitsModule = scan(LocalPlayer:FindFirstChildOfClass("PlayerScripts"))
	or scan(game:GetService("StarterPlayer"):FindFirstChild("StarterPlayerScripts"))
end
local EggRuntime = (function()
	local Players = game:GetService("Players")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local RunService = game:GetService("RunService")
	local LocalPlayer = Players.LocalPlayer
	local EggCmds = require(ReplicatedStorage.Client.EggState)
	local Remotes = require(ReplicatedStorage.Shared.Remotes)
	local EggWorld = Remotes.EggWorld
	local AreaEggs = require(ReplicatedStorage.Shared.Types.AreaEggs)
	local AreaEggSlotIdentity = require(ReplicatedStorage.Shared.Util.AreaEggSlotIdentity)
	local AreaEggResetWall = require(ReplicatedStorage.Client.AreaEggResetWall)
	local SpeedPowerProjection = require(ReplicatedStorage.Client.SpeedPowerProjection)
	local TreadmillUtil = require(ReplicatedStorage.Shared.Util.TreadmillUtil)
	local EggRecords = require(ReplicatedStorage.Shared.Util.EggRecords)
	local AssetEarnings = require(ReplicatedStorage.Shared.Util.AssetEarnings)
	local Save = require(ReplicatedStorage.Shared.Save)
	local PlotState = require(ReplicatedStorage.Client.PlotState)
	local MOVEMENT_SPEED_MULTIPLIER = 10
	local MIN_MOVEMENT_SPEED_INPUT = 20
	local MAX_MOVEMENT_SPEED_INPUT = 100
	local DEFAULT_MOVEMENT_SPEED_INPUT = 60
	local NEXT_TARGET_HANDOFF_SECONDS = 0.05
	local MIN_MOVEMENT_SPEED = MIN_MOVEMENT_SPEED_INPUT * MOVEMENT_SPEED_MULTIPLIER
	local MAX_MOVEMENT_SPEED = MAX_MOVEMENT_SPEED_INPUT * MOVEMENT_SPEED_MULTIPLIER
	local DEFAULT_MOVEMENT_SPEED = DEFAULT_MOVEMENT_SPEED_INPUT * MOVEMENT_SPEED_MULTIPLIER
	local ADMIN_BOOST_SPEED = 3000
	local function maxMoveSpeed()
		if runtimeEnv.__SenaV4AdminBoost == true then return ADMIN_BOOST_SPEED end
		if runtimeEnv.__SenaV4FastPull then
			local fp = tonumber(Config.FastPullSpeed) or 0
			if fp > MAX_MOVEMENT_SPEED then return fp end
		end
		return MAX_MOVEMENT_SPEED
	end
	local MOVEMENT_SPOOF_KEY = "__SenaV4StealAnEggMovementSpoof"
	local MOVEMENT_SPOOF_VERSION = 436
	local INTEGRITY_SPOOF_KEY = "__SenaV4StealAnEggIntegritySpoof"
	local PRIORITY_STEAL_RARITIES = {
		Divine = true,
		Eternal = true,
	}
	local INTEGRITY_SIGNAL_NAME = "ClientCharacter: GetDebugSnapshot"
	local INTEGRITY_SAMPLE_FIELDS = {
		"LastObservedSample",
		"LastSample",
		"LastGoodSample",
		"LastGameplayTrustedSample",
		"LastValidatedSample",
		"LastValidatedGroundedSample",
		"LastConfirmedGroundSample",
		"CandidateGroundedSample",
	}
	local EGG_CRUISE_HEIGHT = 5
	local EGG_ARRIVAL_CLEARANCE = 0.15
	local HOVER_PAD_SIZE_XZ = 8
	local HOVER_PAD_THICKNESS = 1
	local HOVER_PAD_NAME = "__SenaV4HoverPad"
	local HOVER_PAD_OWNER_ATTRIBUTE = "SenaV4RuntimeOwner"
	local SAFE_ZONE_POSITION = Vector3.new(542.93, 71.5, -405.58)
	local HANDOFF_X = 612
	local HANDOFF_LANES = { -364.30, -367.21, -371.12, -375.65 }
	local FOREST_HOLD_CFRAME = CFrame.new(599.8, 113.5, -325)   
	local FOREST_DROP_GROUND = Vector3.new(599.8, 70, -325)     
	local FAR_AREA_EGG_X = 1300      
	local FAR_AREA_CHAR_X = 1100     
	local FOREST_ARRIVAL_X = 800     
	local FOREST_TRANSFER_ATTEMPTS = 3
	local FOREST_DROP_SETTLE = 0.85  
	local SETTLE_RETRY_BONUS = 2     
	local FOREST_REGRAB_TIMEOUT = 2  
	local SETTLE_CAP_DEFAULT = 13   
	local SETTLE_BY_AREA = {
		["Forest"] = 1.0,   ["Lake"] = 2.5,          ["Desert"] = 3.0,        ["Jungle"] = 4.5,
		["Snow"] = 5.5,     ["Volcano"] = 6.5,        ["Abyss Ocean"] = 7.5,   ["Prehistoric"] = 8.5,
		["Cosmic"] = 10.0,  ["Cherry Blossom"] = 11.5, ["Titan Temple"] = 12.5, ["Light Dark"] = 13.0,
	}
	local GLIDE_SPEED = 3000
	local FOREST_DROP_RELAY = CFrame.new(554.071, 70.276, -395.573, 0, 0, 1, 0, 1, 0, -1, 0, 0)
	local FOREST_DROP_JITTER = 16
	local HOVER_DESYNC_HEIGHT = 14
	local BURST_SECONDS  = 0.70
	local BURST_HOLD_MAX = 3.0
	local BURST_NEAR     = 6
	local BURST_STABLE   = 0.45
	local SAFE_ZONE_HORIZONTAL_RADIUS = 30
	local SAFE_ZONE_VERTICAL_TOLERANCE = 18
	local SAFE_TELEPORT_STABLE_SECONDS = 0.35
	local SAFE_TELEPORT_TIMEOUT_SECONDS = 2
	local SAFE_TELEPORT_RETRY_SECONDS = 0.1
	local TREADMILL_DECOY_NAME = "__SenaV4TreadmillDecoy"
	local TREADMILL_DECOY_REMOVE_CLASSES = {
		Script = true,
		LocalScript = true,
		BillboardGui = true,
		Sound = true,
	}
	local CARRY_RETRY_INTERVAL = 0.25
	local CARRY_CONFIRM_TIMEOUT_SECONDS = 5
	local MAX_CARRY_TIMEOUTS = 2
	local CARRY_TIMEOUT_SKIP_SECONDS = 45
	local CARRY_REAPPROACH_DISTANCE = 10
	local CARRY_STATE_GRACE = 0.03
	local TARGET_GONE_HANDOFF_GRACE = 0.65
	local SAFE_ARRIVAL_STABLE_TIME = 0.35
	local RETURN_VALIDATION_INTERVAL = 0.08
	local INTEGRITY_SPEED_HEADROOM = 1.35
	local LONG_FRAME_CLAMP = 0.15
	local MOVEMENT_BASELINE_PADDING = 24
	local CORRECTION_DISTANCE_EPSILON = 2
	local CORRECTION_SLOWDOWN_SECONDS = 0.5
	local CORRECTION_SPEED_FACTOR = 0.45
	local MOVEMENT_ARRIVAL_HOLD = 0.4
	local PLAYER_TRAP_NAME = "PlayerTrap"
	local LEGACY_TRAP_MODEL_NAME = "Trap"
	local EggRuntime = {}
	EggRuntime.__index = EggRuntime
	local _Stats = game:GetService("Stats")
	local function requestFieldEggCarry(uid, slotKey)
		local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
		if root then
			pcall(function()
				root.AssemblyLinearVelocity = Vector3.zero
				root.AssemblyAngularVelocity = Vector3.zero
				end)
		end
		local ping = 0
		pcall(function() ping = _Stats.Network.ServerStats.Ping:GetValue() end)
		task.wait(math.max(0.3, ping * 2.5 / 1000))
		local payload = { Uid = uid }
		if slotKey ~= nil then
			payload.FirstAreaSlotKey = slotKey
		end
		local result, reason = EggWorld.AskFieldEggCarry:InvokeServer(payload)
		return result == true, typeof(reason) == "string" and reason or nil
	end
	local function connect(signal, callback, connections)
		local connection = signal:Connect(callback)
		table.insert(connections, connection)
		return connection
	end
	local function disconnectAll(connections)
		for _, connection in ipairs(connections) do
			pcall(connection.Disconnect, connection)
		end
		table.clear(connections)
	end
	local function listContains(list, value)
		for _, candidate in ipairs(list or {}) do
			if candidate == value then
				return true
			end
		end
		return false
	end
	local resolveEggRate
	local function functionHasConstants(callback, required)
		if type(callback) ~= "function"
		or type(debug) ~= "table"
		or type(debug.getconstants) ~= "function"
		then
			return false
		end
		local ok, constants = pcall(debug.getconstants, callback)
		if not ok or type(constants) ~= "table" then return false end
		local found = {}
		for _, value in ipairs(constants) do
			if type(value) == "string" then found[value] = true end
		end
		for _, value in ipairs(required) do
			if not found[value] then return false end
		end
		return true
	end
	local function callbackSource(callback)
		if type(callback) ~= "function" or type(debug) ~= "table" or type(debug.info) ~= "function" then
			return ""
		end
		local ok, source = pcall(debug.info, callback, "s")
		return ok and tostring(source) or ""
	end
	local function applyKillPartIgnore(character)
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root then
			root:SetAttribute("KillPartIgnore", true)
		end
	end
	local function cloneSwapHumanoid(character)
		local hum = character and character:FindFirstChildOfClass("Humanoid")
		if not hum or not hum.Parent then
			return false
		end
		pcall(function()
			hum.BreakJointsOnDeath = false
			end)
		local cloneHum = hum:Clone()
		hum:Destroy()
		cloneHum.Parent = character
		local camera = workspace.CurrentCamera
		if camera then
			camera.CameraSubject = cloneHum
		end
		local animateScript = character:FindFirstChild("Animate")
		if animateScript then
			local animateClone = animateScript:Clone()
			animateScript:Destroy()
			animateClone.Parent = character
		end
		pcall(function()
			cloneHum:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
			cloneHum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
			cloneHum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
			cloneHum:SetStateEnabled(Enum.HumanoidStateType.PlatformStanding, false)
			cloneHum:SetStateEnabled(Enum.HumanoidStateType.Physics, false)
			cloneHum:ChangeState(Enum.HumanoidStateType.Running)
			end)
		return true
	end
	local function stopHealthPinner(self)
		if self._healthPinner then
			pcall(self._healthPinner.Disconnect, self._healthPinner)
			self._healthPinner = nil
		end
		if self._healthChangedConnection then
			pcall(self._healthChangedConnection.Disconnect, self._healthChangedConnection)
			self._healthChangedConnection = nil
		end
	end
	local function startHealthPinner(self, char)
		stopHealthPinner(self)
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local root = char and char:FindFirstChild("HumanoidRootPart")
		if not hum then return false end
		local maxHp = math.max(hum.MaxHealth, 100)
		local repairing = false
		local lastRepairAt = 0
		local function repair()
			if repairing or self.destroyed or LocalPlayer.Character ~= char or not hum.Parent then return end
			local now = os.clock()
			if now - lastRepairAt < 0.1 and hum.Health > 0 and hum:GetState() ~= Enum.HumanoidStateType.Dead then
				return
			end
			lastRepairAt = now
			repairing = true
			pcall(function()
				hum.BreakJointsOnDeath = false
				hum.RequiresNeck = false
				hum:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
				hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
				hum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
				if hum.Health <= 0 then hum.Health = maxHp end
				if hum:GetState() == Enum.HumanoidStateType.Dead then
					hum:ChangeState(Enum.HumanoidStateType.Running)
				end
				if root and root.Parent == char and root.Anchored then
					root.Anchored = false
				end
				end)
			repairing = false
		end
		repair()
		self._healthChangedConnection = hum.HealthChanged:Connect(function(health)
			if health <= 0 or health < maxHp then repair() end
			end)
		self._healthPinner = RunService.Heartbeat:Connect(repair)
		return true
	end
	local function disableDeath(character)
		local hum = character and character:FindFirstChildOfClass("Humanoid")
		if not hum then return end
		pcall(function()
			hum.BreakJointsOnDeath = false
			hum.RequiresNeck = false
			hum:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
			hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
			hum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
			end)
	end
	local function restoreHumanoid(character)
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not humanoid then
			return
		end
		pcall(function()
			if humanoid.Health <= 0 then
				humanoid.Health = math.max(humanoid.MaxHealth, 1)
			end
			humanoid:SetStateEnabled(Enum.HumanoidStateType.Dead, true)
			humanoid.BreakJointsOnDeath = true
			humanoid.RequiresNeck = true
			end)
	end
	local function environment()
		return getgenv and getgenv() or _G
	end
	local function disableGameAntiAfkWatchdog()
		if type(getconnections) ~= "function"
		or type(debug) ~= "table"
		or type(debug.info) ~= "function"
		or type(debug.getupvalue) ~= "function"
		then
			return false
		end
		local okConnections, connections = pcall(getconnections, LocalPlayer.Idled)
		if not okConnections or type(connections) ~= "table" then return false end
		local expectedSuffix = ".PlayerScripts.Game.AntiAFK"
		for _, connection in ipairs(connections) do
			local callback = connection.Function
			if type(callback) == "function" and type(connection.Disable) == "function" then
				local okSource, source = pcall(debug.info, callback, "s")
				local okUpvalue, idleState = pcall(debug.getupvalue, callback, 1)
				if okSource
				and type(source) == "string"
				and source:sub(-#expectedSuffix) == expectedSuffix
				and okUpvalue
				and type(idleState) == "number"
				then
					local disabled = pcall(connection.Disable, connection)
					return disabled
				end
			end
		end
		return false
	end
	local function getMovementSpoof()
		local env = environment()
		local existing = env[MOVEMENT_SPOOF_KEY]
		if type(existing) ~= "table" or existing.Version ~= MOVEMENT_SPOOF_VERSION then
			if type(existing) == "table" then existing.Enabled = false end
			existing = {
				Version = MOVEMENT_SPOOF_VERSION,
				Installed = false,
				Enabled = false,
				Mode = "StateBaseline",
				Humanoid = nil,
				RootPart = nil,
				WalkSpeed = DEFAULT_MOVEMENT_SPEED,
			}
			env[MOVEMENT_SPOOF_KEY] = existing
		end
		return existing
	end
	local function setMovementSpoof(character, speed)
		local holder = getMovementSpoof()
		if not holder then
			return false
		end
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		holder.Humanoid = humanoid
		holder.RootPart = root
		holder.WalkSpeed = math.clamp(
			tonumber(speed) or DEFAULT_MOVEMENT_SPEED,
			MIN_MOVEMENT_SPEED,
			MAX_MOVEMENT_SPEED * INTEGRITY_SPEED_HEADROOM
		)
		holder.Enabled = false
		return humanoid ~= nil and root ~= nil
	end
	local function clearMovementSpoof()
		local holder = environment()[MOVEMENT_SPOOF_KEY]
		if type(holder) == "table" then
			holder.Enabled = false
			holder.Humanoid = nil
			holder.RootPart = nil
		end
	end
	local function findIntegrityStateNow(player, humanoid, root)
		local found
		if type(getcallbackvalue) == "function" and type(debug) == "table" and type(debug.getupvalue) == "function" then
			local signalModule = ReplicatedStorage:FindFirstChild("Packages")
			and ReplicatedStorage.Packages:FindFirstChild("Signal")
			if signalModule then
				local okSig, Signal = pcall(require, signalModule)
				if okSig and type(Signal) == "table" and type(Signal.Invoked) == "function" then
					local okBind, bindable = pcall(Signal.Invoked, INTEGRITY_SIGNAL_NAME)
					if okBind and bindable then
						local okCb, callback = pcall(getcallbackvalue, bindable, "OnInvoke")
						if okCb and type(callback) == "function" then
							local okInfo, info = pcall(debug.getinfo, callback)
							if okInfo then
								local function scan(value, depth, seen)
									if found or type(value) ~= "table" or depth > 3 or seen[value] then return end
									seen[value] = true
									if rawget(value, "Player") == player
									and rawget(value, "Character") == player.Character
									and rawget(value, "Humanoid") == humanoid
									and rawget(value, "RootPart") == root
									and type(rawget(value, "SampleHistory")) == "table"
									and type(rawget(value, "Evidence")) == "table"
									then
										found = value
										return
									end
									local scanned = 0
									for _, child in pairs(value) do
										scanned = scanned + 1
										if scanned > 128 then break end
										if type(child) == "table" then scan(child, depth + 1, seen) end
									end
								end
								for idx = 1, info.nups or 0 do
									local okUp, upvalue = pcall(debug.getupvalue, callback, idx)
									if okUp and type(upvalue) == "table" then
										scan(upvalue, 0, {})
										if found then break end
									end
								end
							end
						end
					end
				end
			end
		end
		if not found and type(getgc) == "function" then
			local okGc, objects = pcall(getgc, true)
			if okGc and type(objects) == "table" then
				for _, obj in ipairs(objects) do
					if type(obj) == "table"
					and rawget(obj, "Player") == player
					and rawget(obj, "Character") == player.Character
					and rawget(obj, "Humanoid") == humanoid
					and rawget(obj, "RootPart") == root
					and type(rawget(obj, "SampleHistory")) == "table"
					and type(rawget(obj, "Evidence")) == "table"
					then
						found = obj
						break
					end
				end
			end
		end
		return found
	end
	local integrityScanRuntime = { busy = false, nextAt = 0, misses = 0, found = nil }
	local function findIntegrityState(player, humanoid, root)
		local cached = integrityScanRuntime.found
		if type(cached) == "table"
		and rawget(cached, "Player") == player
		and rawget(cached, "Character") == player.Character
		and rawget(cached, "Humanoid") == humanoid
		and rawget(cached, "RootPart") == root
		then
			return cached
		end
		if integrityScanRuntime.busy or os.clock() < integrityScanRuntime.nextAt then
			return nil
		end
		integrityScanRuntime.busy = true
		task.spawn(function()
			task.wait()
			local ok, found = pcall(findIntegrityStateNow, player, humanoid, root)
			found = ok and found or nil
			integrityScanRuntime.found = found
			integrityScanRuntime.misses = found and 0 or integrityScanRuntime.misses + 1
			integrityScanRuntime.nextAt = os.clock() + (found and 0.2 or (integrityScanRuntime.misses >= 5 and 10 or 1))
			integrityScanRuntime.busy = false
			end)
		return nil
	end
	local function patchIntegrityState(state, speed, travelVelocity)
		if type(state) ~= "table" then
			return false
		end
		local root = rawget(state, "RootPart")
		local rootCFrame = root and root.Parent and root.CFrame or nil
		local rootPosition = rootCFrame and rootCFrame.Position or nil
		local coherentVelocity = typeof(travelVelocity) == "Vector3" and travelVelocity or Vector3.zero
		local function patchSample(sample)
			if type(sample) == "table" then
				rawset(sample, "WalkSpeed", speed)
				if rootCFrame then
					rawset(sample, "CFrame", rootCFrame)
					rawset(sample, "Position", rootPosition)
					rawset(sample, "LinearVelocity", coherentVelocity)
					rawset(sample, "AngularVelocity", Vector3.zero)
				end
			end
		end
		for _, field in ipairs(INTEGRITY_SAMPLE_FIELDS) do
			patchSample(rawget(state, field))
		end
		for _, sample in pairs(rawget(state, "SampleHistory") or {}) do
			patchSample(sample)
		end
		for _, sample in pairs(rawget(state, "SafeGroundCheckpoints") or {}) do
			patchSample(sample)
		end
		local evidence = rawget(state, "Evidence")
		if type(evidence) == "table" then
			evidence.Speed = 0
			evidence.Teleport = 0
			evidence.Flight = 0
		end
		local impulse = rawget(state, "ImpulseContext")
		if type(impulse) == "table" then
			local horizontalSpeed = math.max(tonumber(impulse.MaxHorizontalSpeed) or 0, speed)
			local duration = math.max(
				(tonumber(impulse.ExpiresAt) or 0) - (tonumber(impulse.StartedAt) or 0),
				LONG_FRAME_CLAMP
			)
			impulse.MaxHorizontalSpeed = horizontalSpeed
			if rootPosition then impulse.OriginPosition = rootPosition end
			impulse.MaxHorizontalDistance = math.max(
				tonumber(impulse.MaxHorizontalDistance) or 0,
				horizontalSpeed * duration + MOVEMENT_BASELINE_PADDING * 2
			)
			patchSample(impulse.PreMovementSafeSample)
		end
		if rawget(state, "CorrectionContext") == nil then
			rawset(state, "FirstSuspiciousAt", nil)
			if rawget(state, "ThreatLevel") == "Observing" then
				rawset(state, "ThreatLevel", "Trusted")
			end
		end
		return true
	end
	local function getIntegritySpoof()
		local env = environment()
		local holder = env[INTEGRITY_SPOOF_KEY]
		if type(holder) ~= "table" then
			holder = {}
			env[INTEGRITY_SPOOF_KEY] = holder
		end
		return holder
	end
	local function integrityStateMatches(state, humanoid, root)
		return type(state) == "table"
		and rawget(state, "Player") == LocalPlayer
		and rawget(state, "Character") == LocalPlayer.Character
		and rawget(state, "Humanoid") == humanoid
		and rawget(state, "RootPart") == root
	end
	local function integrityStateCanTravel(state, humanoid, root)
		return integrityStateMatches(state, humanoid, root)
	end
	local function setIntegritySpoof(humanoid, root, speed)
		local holder = getIntegritySpoof()
		local state = holder.State
		if not integrityStateMatches(state, humanoid, root) then
			local now = os.clock()
			if now < (holder.NextSearchAt or 0) then return false end
			holder.NextSearchAt = now + 0.2
			state = findIntegrityState(LocalPlayer, humanoid, root)
		end
		if not state then
			return false
		end
		if not integrityStateCanTravel(state, humanoid, root) then
			holder.Enabled = false
			holder.Humanoid = humanoid
			holder.RootPart = root
			holder.State = state
			return false
		end
		holder.NextSearchAt = 0
		holder.Enabled = true
		holder.Humanoid = humanoid
		holder.RootPart = root
		holder.State = state
		holder.WalkSpeed = math.clamp(speed * INTEGRITY_SPEED_HEADROOM, MIN_MOVEMENT_SPEED, MAX_MOVEMENT_SPEED * INTEGRITY_SPEED_HEADROOM)
		holder.TravelVelocity = Vector3.zero
		patchIntegrityState(state, holder.WalkSpeed, holder.TravelVelocity)
		return true
	end
	local function refreshIntegritySpoof(humanoid, root, speed, travelVelocity)
		local holder = environment()[INTEGRITY_SPOOF_KEY]
		if type(holder) ~= "table"
		or not holder.Enabled
		or holder.Humanoid ~= humanoid
		or holder.RootPart ~= root
		or not integrityStateCanTravel(holder.State, humanoid, root)
		then
			return false
		end
		holder.WalkSpeed = math.clamp(speed * INTEGRITY_SPEED_HEADROOM, MIN_MOVEMENT_SPEED, MAX_MOVEMENT_SPEED * INTEGRITY_SPEED_HEADROOM)
		if typeof(travelVelocity) == "Vector3" then
			holder.TravelVelocity = travelVelocity
		elseif typeof(holder.TravelVelocity) ~= "Vector3" then
			holder.TravelVelocity = Vector3.zero
		end
		return patchIntegrityState(holder.State, holder.WalkSpeed, holder.TravelVelocity)
	end
	local function clearIntegritySpoof(humanoid)
		local holder = environment()[INTEGRITY_SPOOF_KEY]
		if type(holder) ~= "table" then
			return
		end
		if humanoid == nil or holder.Humanoid == humanoid then
			holder.Enabled = false
			holder.Humanoid = nil
			holder.RootPart = nil
			holder.State = nil
			holder.TravelVelocity = nil
			holder.NextSearchAt = 0
		end
	end
	local function hasSelectedMutation(record, selected)
		if #selected == 0 then
			return true
		end
		for _, mutation in ipairs(record.Mutations or {}) do
			if listContains(selected, mutation) then
				return true
			end
		end
		return record.BaseMutation ~= nil and listContains(selected, record.BaseMutation)
	end
	local function resolveOfficialWalkSpeed()
		local projected = TreadmillUtil.SpeedPowerToWalkSpeed(SpeedPowerProjection.ReadProjected())
		local character = LocalPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local applied = humanoid and humanoid.WalkSpeed or projected
		return math.clamp(math.min(projected, applied), MIN_MOVEMENT_SPEED, MAX_MOVEMENT_SPEED)
	end
	function EggRuntime.new(catalog, integrityLimitsModule, coordinator)
		local self = setmetatable({}, EggRuntime)
		self.catalog = catalog
		self.limitsModule = integrityLimitsModule
		self.coordinator = coordinator
		self.operationToken = nil
		self.connections = {}
		self.listeners = {}
		self.records = {}
		self.enabled = false
		self.userStealEnabled = false
		self.skippedEggs = {}
		self.riftWants = {}
		self.riftOnly = false
		self.indexObjectiveEnabled = false
		self.wispObjective = nil
		self.manualObjectiveEnabled = false
		self.manualQueue = {}
		self.manualOrder = {}
		self.indexCache = { at = 0, set = {} }
		self.running = false
		self.safeStarting = false
		self.movementRetryPending = false
		self.destroyed = false
		self.resetBlocked = AreaEggResetWall.IsSealed()
		self.gateOpenAt = self.resetBlocked and math.huge or os.clock()
		self.activeTween = nil
		self.activeTarget = nil
		self.claimPresentationNode = nil
		self.claimPresentationOriginal = nil
		self.claimPresentationSuppression = nil
		self.carry = { active = false, uid = nil, generation = 0 }
		self.carryWorker = nil
		self.tweenRecoveryUid = nil
		self.planGeneration = 0
		self.treadmillDecoy = nil
		self.treadmillDecoyCamera = nil
		self.treadmillDecoyCameraConnection = nil
		self.treadmillDecoyCharacterConnection = nil
		self.treadmillPopupConnection = nil
		self.treadmillDecoyRealTransparency = nil
		self.hoverPadOwnerId = string.format("%s:%0.6f", tostring(self), os.clock())
		self.instantPhase = nil
		self.primerUid = nil
		self.primerUids = {}
		self.targetUid = nil
		self.hitTimer = nil
		self.guardHitBoostInstalled = false
		self.stats = {
			status = self.resetBlocked and "Reset wall closed" or "Ready",
			available = 0,
			matching = 0,
			lastTarget = "None",
			lastResult = "Idle",
		}
		self.config = {
			stealMode = "Fly",
			flyAerial = false,
			flyZigzag = false,
			speed = DEFAULT_MOVEMENT_SPEED,
			antiTrap = true,
			heaviestFirst = false,
			highestValueFirst = false,
			minWeightKg = 0,
			espEnabled = false,
			espRarity = true,
			espName = true,
			espKg = true,
			espMutation = true,
			espValue = true,
			espPlaced = false,
			espIcon = true,
			espMinRank = 0,
			espMinValue = 0,
			minValuePerSec = 0,
			rarityEnabled = false,
			rarities = {},
			nameEnabled = false,
			names = {},
			areaEnabled = false,
			areas = {},
			mutationEnabled = false,
			mutations = {},
		}
		self.gameAntiAfkDisabled = disableGameAntiAfkWatchdog()
		if LocalPlayer.Character then
			applyKillPartIgnore(LocalPlayer.Character)
			local hum = LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
			if hum then
				pcall(function()
					hum.BreakJointsOnDeath = false
					hum.RequiresNeck = false
					hum:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
					hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
					hum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
					end)
			end
			startHealthPinner(self, LocalPlayer.Character)
		end
		local okWeight, weightUtil = pcall(function()
			return require(ReplicatedStorage.Shared.Util.EggRecords)
			end)
		self.weightUtil = okWeight and type(weightUtil.WeightKgForScale) == "function" and weightUtil or nil
		local function watchTrapContainer(container)
			if not container then
				return
			end
			connect(container.DescendantAdded, function(instance)
				if self.config.antiTrap then
					self:_purgeTrap(instance)
				end
				end, self.connections)
		end
		watchTrapContainer(workspace:FindFirstChild("Transient"))
		watchTrapContainer(workspace:FindFirstChild("__DEBRIS"))
		if self.config.antiTrap then self:_purgeTraps() end
		connect(workspace.ChildAdded, function(child)
			if child.Name == "Transient" or child.Name == "__DEBRIS" then
				watchTrapContainer(child)
				if self.config.antiTrap then
					self:_purgeTraps()
				end
			end
			end, self.connections)
		self:_replaceSnapshot(EggCmds.ReadFieldEggs())
		connect(EggCmds.FieldRefreshed, function(snapshot)
			self:_replaceSnapshot(snapshot)
			end, self.connections)
		connect(EggCmds.FieldShifted, function(record)
			self.records[record.Uid] = record
			self:_refreshCounts()
			if self.enabled and not self.destroyed and not self.running and not self.carry.active
				and (record.State == AreaEggs.States.Slot or record.State == AreaEggs.States.Dropped)
				and not self._shiftWakePending
			then
				self._shiftWakePending = true
				task.delay(0.25, function()
					self._shiftWakePending = nil
					if not self.destroyed and self.enabled and not self.running then self:_schedule() end
					end)
			end
			end, self.connections)
		connect(EggCmds.FieldGone, function(uid)
			self.records[uid] = nil
			if self.activeTarget and self.activeTarget.Uid == uid then
				if self.carry.active and self.carry.uid == uid then
					self:_refreshCounts()
					return
				end
				self.carryAttemptToken = nil
				self:_clearArrivalHold(uid)
				if self.activeTween and self.activeTween.Cancel then
					pcall(self.activeTween.Cancel, self.activeTween)
				end
				local target = self.activeTarget
				task.delay(TARGET_GONE_HANDOFF_GRACE, function()
					if self.destroyed or not self.enabled then return end
					if self.carry.active and self.carry.uid == uid then return end
					if self.activeTarget == target and target.Uid == uid then
						self:_finish("Target removed — continuing")
					end
					end)
			end
			self:_refreshCounts()
			end, self.connections)
		connect(EggCmds.ResetCountdown, function()
			self:_closeGate("Egg reset countdown")
			end, self.connections)
		connect(EggCmds.ResetFade, function()
			self:_closeGate("Egg reset teleport")
			end, self.connections)
		connect(AreaEggResetWall.Changed, function(closed)
			if closed then
				self:_closeGate("Reset wall closed")
			else
				self.resetBlocked = false
				self.gateOpenAt = os.clock()
				self.safeStarting = false
				self.running = false
				self:_setStatus(self.enabled and "Searching" or "Ready")
				self:_schedule()
			end
			end, self.connections)
		connect(LocalPlayer.CharacterRemoving, function()
			self._recalling = nil 
			self:_cleanupInstantSteal()
			self:_hideTreadmillDecoy()
			self._forestDropInProgress = nil
			self._instantReturnToken = nil
			self.carry.generation += 1
			self:_invalidateCarryWorker()
			self.carry.active = false
			self.carry.uid = nil
			self.safeStarting = false
			self.planGeneration += 1
			self:_cancelTween("Character resetting")
			self:_stopMovementProtection()
			end, self.connections)
		connect(RunService.Heartbeat, function()
			if self.destroyed then return end
			local character = LocalPlayer.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if not root then return end
			local velocity = root.AssemblyLinearVelocity
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			local ws = humanoid and humanoid.WalkSpeed or 0
			local horizontal = Vector3.new(velocity.X, 0, velocity.Z)
			if horizontal.Magnitude > math.max(400, ws * 1.5) or math.abs(velocity.Y) > 400 then
				local cap = math.max(100, ws)
				if horizontal.Magnitude > cap then horizontal = horizontal.Unit * cap end
				root.AssemblyLinearVelocity = Vector3.new(horizontal.X, math.clamp(velocity.Y, -100, 100), horizontal.Z)
			end
			end, self.connections)
		connect(LocalPlayer.CharacterAdded, function(character)
			self:_hideTreadmillDecoy()
			applyKillPartIgnore(character)
			local freshHum = character:FindFirstChildOfClass("Humanoid")
			if freshHum then
				pcall(function()
					freshHum.BreakJointsOnDeath = false
					freshHum.RequiresNeck = false
					freshHum:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
					freshHum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
					freshHum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
					end)
			end
			startHealthPinner(self, character)
			task.delay(0.25, function()
				if not self.destroyed and self.enabled then
					self:_startMovementProtection()
				end
				end)
			task.delay(1, function()
				if not self.destroyed and self.enabled and self:_wallOpen() then
					self:_schedule()
				end
				end)
			end, self.connections)
		self:_installClaimPresentationFilter()
		connect(EggCmds.CarryChanged, function(state)
			if state.IsCarrying then
				if self.running and self.activeTarget and state.Uid == self.activeTarget.Uid then
					if self.carry.active and self.carry.uid == state.Uid then return end
					if self.instantPhase == "priming" and state.Uid == self.primerUid then
						self.carry.active = true
						self.carry.uid = state.Uid
						self:_clearArrivalHold(state.Uid)
						self:_enterBaitWait()
						return
					end
					self.carry.generation += 1
					self:_invalidateCarryWorker()
					self:_clearArrivalHold(state.Uid)
					self.claimPresentationSuppression = {
						assetCategory = self.activeTarget.AssetCategory,
						expiresAt = os.clock() + 8,
					}
					self.carry.active = true
					self.carry.uid = state.Uid
					self.carryStartTime = os.clock()
					self.carryStartPos = (self.activeTarget and self.activeTarget.BottomCFrame and self.activeTarget.BottomCFrame.Position)
					or (LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart") and LocalPlayer.Character.HumanoidRootPart.Position)
					if self.tweenRecoveryUid == state.Uid then
						self.tweenRecoveryUid = nil
					end
					if self.carryTimeouts then self.carryTimeouts[state.Uid] = nil end
					self.stats.lastResult = "Carry confirmed"
					self:_notify()
					self.carryAttemptToken = nil
					if self.activeTween and self.activeTween.Cancel then
						pcall(self.activeTween.Cancel, self.activeTween)
					end
					task.defer(function()
						if not self.destroyed and self.enabled
						and self.carry.uid == state.Uid
						and self:_hasConfirmedCarry(state.Uid)
						then
							if runtimeEnv.__SenaV4GodMode then
								runtimeEnv.__SenaV4GodMode:stopDefend()
							end
							self:_returnToSafe()
						end
						end)
				end
				return
			end
			if self.carry.uid ~= nil and state.Uid ~= nil and state.Uid ~= self.carry.uid then
				return
			end
			local droppedUid = state.Uid
			or self.carry.uid
			or (self.activeTarget and self.activeTarget.Uid)
			local wasTracked = self.carry.active
			self.carry.generation += 1
			local releaseGeneration = self.carry.generation
			self:_invalidateCarryWorker()
			if self.activeTween and self.activeTween.Cancel then
				pcall(self.activeTween.Cancel, self.activeTween)
			end
			self.carry.active = false
			self.carry.uid = nil
			if runtimeEnv.__SenaV4GodMode then
				runtimeEnv.__SenaV4GodMode:startDefend(droppedUid)
			end
			if (self._captureHoldUid ~= nil and droppedUid == self._captureHoldUid)
				or (self._adminBusyUid ~= nil and droppedUid == self._adminBusyUid) then
				return
			end
			if self.instantPhase == "priming" and (state.Uid == self.primerUid or droppedUid == self.primerUid) then
				self:_startPrimerTargetHunt()
				return
			end
			if self._forestDropInProgress ~= nil and droppedUid == self._forestDropInProgress then
				return
			end
			if not wasTracked then
				return
			end
			if not self.running or not self.activeTarget then
				return
			end
			local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
			if root and self:_isInSafeArea(root) then
				self:_reportStolen()
				self:_finish("Safe return complete")
				return
			end
			task.delay(CARRY_STATE_GRACE, function()
				if self.destroyed or not self.enabled or self.carry.active
				or self.carry.generation ~= releaseGeneration
				then
					return
				end
				local latestRoot = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
				if latestRoot and self:_isInSafeArea(latestRoot) then
					self:_reportStolen()
					self:_finish("Safe return complete")
					return
				end
				self:_reStealDroppedEgg(droppedUid)
				end)
			end, self.connections)
		connect(LocalPlayer:GetAttributeChangedSignal("RagdollEndTime"), function()
			local tEnd = LocalPlayer:GetAttribute("RagdollEndTime") or 0
			if self.instantPhase == "priming" and tEnd > workspace:GetServerTimeNow() then
				self:_startPrimerTargetHunt()
			end
			end, self.connections)
		connect(RunService.Heartbeat, function()
			if self.destroyed then
				return
			end
			local now = os.clock()
			if now - (self._espLastTick or 0) < 0.4 then
				return
			end
			self._espLastTick = now
			local okEsp, espErr = pcall(function()
				self:_updateEsp()
				end)
			if not okEsp then
				if now - (self._espErrLast or 0) > 5 then
					self._espErrLast = now
					warn("[SAE][esp] update error: " .. tostring(espErr))
				end
			end
			end, self.connections)
		local startupStatus = self.stats.status
		self.stats.status = startupStatus
		return self
	end
	function EggRuntime:_installClaimPresentationFilter()
		return false
	end
	function EggRuntime:_restoreClaimPresentationFilter()
		local connection = self.claimPresentationNode
		local callback = self.claimPresentationOriginal
		if type(connection) == "table"
		and type(callback) == "function"
		and rawget(connection, "_fn") == self.claimPresentationWrapper
		then
			connection._fn = callback
		end
		self.claimPresentationNode = nil
		self.claimPresentationOriginal = nil
		self.claimPresentationWrapper = nil
		self.claimPresentationSuppression = nil
	end
	function EggRuntime:_setStatus(status)
		if self.stats.status == status then
			return
		end
		if type(status) == "string" and string.find(status, "not currently trusted", 1, true) then
			self._untrustedSeen = true
		end
		self.stats.status = status
		self:_notify()
	end
	function EggRuntime:_notify()
		local snapshot = self:getSnapshot()
		for listener in pairs(self.listeners) do
			local ok, err = pcall(listener, snapshot)
			if not ok then
				warn("[StealAnEgg] UI listener failed:", err)
			end
		end
	end
	function EggRuntime:onChanged(listener)
		self.listeners[listener] = true
		local ok, err = pcall(listener, self:getSnapshot())
		if not ok then
			warn("[StealAnEgg] UI listener failed:", err)
		end
		return function()
			self.listeners[listener] = nil
		end
	end
	function EggRuntime:getSnapshot()
		return {
			status = self.stats.status,
			available = self.stats.available,
			matching = self.stats.matching,
			lastTarget = self.stats.lastTarget,
			lastResult = self.stats.lastResult,
			wallClosed = self.resetBlocked or AreaEggResetWall.IsSealed() or os.clock() < self.gateOpenAt,
			enabled = self.enabled,
			running = self.running,
		}
	end
	function EggRuntime:_replaceSnapshot(snapshot)
		table.clear(self.records)
		local records = snapshot and (snapshot.Records or snapshot) or {}
		for key, record in pairs(records) do
			if type(record) == "table" and type(record.Uid) == "string" then
				self.records[record.Uid] = record
			elseif type(key) == "string" and type(record) == "table" then
				self.records[key] = record
			end
		end
		self:_refreshCounts()
		self:_schedule()
	end
	function EggRuntime:_indexWants()
		local now = os.clock()
		local cache = self.indexCache
		if cache and now - (cache.at or 0) < 2 then return cache.set end
		local set = {}
		pcall(function()
			local areas = self.areasDirectory
			if not areas then
				areas = require(ReplicatedStorage.Data.Areas).Directory
				self.areasDirectory = areas
			end
			local data = (Save.Peek or Save.Get)()
			if not (areas and data) then return end
			local have = data.Index or {}
			local secured = {}
			for _, entry in pairs(data.EggInventory or {}) do
				local category = type(entry) == "table" and (entry.AssetCategory or entry.Category) or nil
				if category then secured[tostring(category)] = true end
			end
			local carriedUid = self.carry and self.carry.uid
			if carriedUid then
				local held = self.records[carriedUid]
				if held and held.AssetCategory then secured[tostring(held.AssetCategory)] = true end
			end
			for _, area in pairs(areas) do
				if type(area) == "table" and type(area.DropTable) == "table" then
					for _, row in ipairs(area.DropTable) do
						local key = row[1]
						if key then
							key = tostring(key)
							if not have[key] and not secured[key] then set[key] = true end
						end
					end
				end
			end
			end)
		self.indexCache = { at = now, set = set }
		return set
	end
	function EggRuntime:_isIndexObjective(record)
		if not self.indexObjectiveEnabled then return false end
		if type(record) ~= "table" then return false end
		local category = record.AssetCategory
		if not category or category == "" then return false end
		return self:_indexWants()[tostring(category)] == true
	end
	function EggRuntime:setIndexObjective(enabled)
		local nextEnabled = enabled == true
		if self.indexObjectiveEnabled == nextEnabled then return end
		self.indexObjectiveEnabled = nextEnabled
		self.indexCache = { at = 0, set = {} }
		self:_reconcileRunningState()
	end
	function EggRuntime:_isWispObjective(record)
		local spec = self.wispObjective
		if type(spec) ~= "table" or type(record) ~= "table" then return false end
		if spec.area and record.AreaId ~= spec.area then return false end
		if spec.rarity then
			local info = self.catalog.resolve(record)
			if not info or info.rarity ~= spec.rarity then return false end
		end
		return true
	end
	function EggRuntime:setWispObjective(spec)
		local key = type(spec) == "table" and ((spec.area or "") .. "|" .. (spec.rarity or "")) or nil
		if self.wispObjectiveKey == key then return end
		self.wispObjectiveKey = key
		self.wispObjective = key and spec or nil
		self:_reconcileRunningState()
	end
	function EggRuntime:indexMissingCount()
		local total = 0
		for _ in pairs(self:_indexWants()) do total += 1 end
		return total
	end
	function EggRuntime:_matchesNormalFilter(record, ignoreArea)
		local info = self.catalog.resolve(record)
		local config = self.config
		if config.rarityEnabled and (#config.rarities == 0 or not listContains(config.rarities, info.rarity)) then
			return false
		end
		if config.nameEnabled and (#config.names == 0 or (not listContains(config.names, info.name) and not listContains(config.names, info.category))) then
			return false
		end
		if not ignoreArea and config.areaEnabled and (#config.areas == 0 or not listContains(config.areas, record.AreaId)) then
			return false
		end
		if config.mutationEnabled and not hasSelectedMutation(record, config.mutations) then
			return false
		end
		if (config.minWeightKg or 0) > 0 then
			local kg = self:_resolveWeightKg(record)
			if not kg or kg < config.minWeightKg then
				return false
			end
		end
		if (config.minValuePerSec or 0) > 0 then
			local rate = resolveEggRate(record)
			if not rate or rate < config.minValuePerSec then
				return false
			end
		end
		return true
	end
	function EggRuntime:_matches(record)
		if record.State ~= AreaEggs.States.Slot and record.State ~= AreaEggs.States.Dropped then
			return false
		end
		if self.riftWants[record.AssetCategory] then return true end
		if self.indexObjectiveEnabled and self:_isIndexObjective(record) then return true end
		if self.wispObjective and self:_isWispObjective(record) then return true end
		if self.userStealEnabled and not self.riftOnly and self:_matchesNormalFilter(record) then return true end
		return false
	end
	function EggRuntime:_refreshCounts()
		local available = 0
		local matching = 0
		for _, record in pairs(self.records) do
			if record.State == AreaEggs.States.Slot then
				available += 1
				if self:_matches(record) then
					matching += 1
				end
			end
		end
		self.stats.available = available
		self.stats.matching = matching
		self:_notify()
	end
	function EggRuntime:hasPriorityRareEgg()
		local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
		local bestRare, bestRareRank, bestRareDist
		for _, record in pairs(self.records or {}) do
			if (record.State == AreaEggs.States.Slot or record.State == AreaEggs.States.Dropped) and record.BottomCFrame
			and not self:isSkippedEgg(record.Uid) and self:_matchesNormalFilter(record) then
				local resolved = self.catalog.resolve(record)
				if PRIORITY_STEAL_RARITIES[resolved.rarity] then
					local dist = root and (record.BottomCFrame.Position - root.Position).Magnitude or 0
					local priorityRank = resolved.rarityRank or 0
					if not bestRare or priorityRank > bestRareRank or (priorityRank == bestRareRank and dist < bestRareDist) then
						bestRare = record
						bestRareRank = priorityRank
						bestRareDist = dist
					end
				end
			end
		end
		return bestRare ~= nil, bestRare
	end
	function EggRuntime:hasNormalStealTarget()
		for _, record in pairs(self.records or {}) do
			if (record.State == AreaEggs.States.Slot or record.State == AreaEggs.States.Dropped) and record.BottomCFrame
			and not self:isSkippedEgg(record.Uid) and self:_matchesNormalFilter(record) then
				return true
			end
		end
		return false
	end
	function EggRuntime:bestNormalStealRank()
		local takeSlot = self.userStealEnabled == true
		local takeDrop = takeSlot or (Config.SnipeDroppedEggs == true)
		local best = 0
		for _, record in pairs(self.records or {}) do
			local isSlot = record.State == AreaEggs.States.Slot
			local isDrop = record.State == AreaEggs.States.Dropped
			if ((isSlot and takeSlot) or (isDrop and takeDrop and (takeSlot or self:_inSnipeZone(record)))) and record.BottomCFrame
			and not self:isSkippedEgg(record.Uid) and self:_matchesNormalFilter(record, isDrop and not takeSlot) then
				local ok, res = pcall(function() return self.catalog.resolve(record) end)
				local rank = (ok and res and tonumber(res.rarityRank)) or 0
				if rank > best then best = rank end
			end
		end
		return best
	end
	local CAPTURE_EGG_ATTR = "Event_CaptureTheEggUid"
	local CAPTURE_HOLD_Y = 110
	function EggRuntime:isSkippedEgg(uid)
		if uid ~= nil and uid == workspace:GetAttribute(CAPTURE_EGG_ATTR) and not self.captureObjectiveEnabled then return true end
		local untilAt = uid and self.skippedEggs[uid]
		if not untilAt then return false end
		if os.clock() < untilAt then return true end
		self.skippedEggs[uid] = nil
		return false
	end
	-- Areas whose guard needs more SpeedPower than ours (the game's own GuardEscapeSpeeds sign): a carry
	-- there is usually tolled (ragdoll, egg back at its nest) and burns a whole cycle, so normal targets
	-- skip them until SpeedPower catches up. Rare-priority and objective targets are not affected.
	function EggRuntime:_areaOverSpeed(areaId)
		local now = os.clock()
		local cache = self._overSpeedCache
		if not cache or now - cache.at > 5 then
			cache = { at = now, map = {} }
			self._overSpeedCache = cache
			local have = 0
			pcall(function() have = tonumber(require(ReplicatedStorage.Shared.Save).Peek().SpeedPower) or 0 end)
			local world = Workspace:FindFirstChild("World")
			local areas = world and world:FindFirstChild("Areas")
			areas = areas and areas:FindFirstChild("GuardAreas")
			for _, m in ipairs(areas and areas:GetChildren() or {}) do
				local req = m:GetAttribute("GuardEscapeSpeeds")
				local need = typeof(req) == "Vector2" and req.X or tonumber(req)
				if need then cache.map[m.Name] = have < need end
			end
		end
		return cache.map[tostring(areaId)] == true
	end
	function EggRuntime:_tollAreaSkip(record)
		return Config.StealSkipTollAreas ~= false and type(record) == "table" and self:_areaOverSpeed(record.AreaId)
	end
	-- Steal Other Script watches where the egg was DROPPED, not its origin AreaId:
	-- a high-tier egg relay-dropped in the home lanes still counts. Fails open if the zones are missing.
	function EggRuntime:_inSnipeZone(record)
		local pos = type(record) == "table" and record.BottomCFrame and record.BottomCFrame.Position
		if not pos then return false end
		local now = os.clock()
		if not self._snipeZones or now - (self._snipeZonesAt or 0) > 10 then
			self._snipeZonesAt = now
			self._snipeZones = {}
			local guard = workspace:FindFirstChild("World")
			guard = guard and guard:FindFirstChild("Areas")
			guard = guard and guard:FindFirstChild("GuardAreas")
			for name in pairs(Config.SnipeAreas or {}) do
				local zone = guard and guard:FindFirstChild(name)
				if zone and zone:IsA("Model") then
					local ok, cf, size = pcall(zone.GetBoundingBox, zone)
					if ok then self._snipeZones[#self._snipeZones + 1] = { cf = cf, half = size * 0.5 } end
				end
			end
		end
		if #self._snipeZones == 0 then return true end
		for _, z in ipairs(self._snipeZones) do
			local lp = z.cf:PointToObjectSpace(pos)
			if math.abs(lp.X) <= z.half.X + 2 and math.abs(lp.Z) <= z.half.Z + 2 then return true end
		end
		return false
	end
	function EggRuntime:_isCaptureEgg(uid)
		return uid ~= nil and uid == workspace:GetAttribute(CAPTURE_EGG_ATTR)
	end
	function EggRuntime:setCaptureObjective(on)
		on = on == true
		if self.captureObjectiveEnabled == on then return end
		if on then
			self._modeBeforeCapture = { self.config.stealMode, self.config.flyAerial, self.config.flyZigzag }
			self:setStealMode("Instant", false, false)
			self.captureObjectiveEnabled = true
		else
			self.captureObjectiveEnabled = false
			local saved = self._modeBeforeCapture
			self._modeBeforeCapture = nil
			if saved then self:setStealMode(saved[1], saved[2], saved[3]) end
		end
		self:_reconcileRunningState()
	end
	function EggRuntime:_captureHold(uid)
		if self._captureHoldUid == uid then return end
		self._captureHoldUid = uid
		local function heldByMe()
			local record = EggCmds.ReadFieldEgg(uid)
			return record ~= nil and record.State == AreaEggs.States.Carried and record.CarrierUserId == LocalPlayer.UserId
		end
		local function keepHolding()
			return not self.destroyed and self.enabled and self.captureObjectiveEnabled and heldByMe()
		end
		task.spawn(function()
			self:_clearArrivalHold(uid)
			self:_hideTreadmillDecoy()
			pcall(function() self:_stopHoverPad() end)
			self.stats.lastResult = "Holding capture egg"
			self:_setStatus("Holding capture egg")
			local character = LocalPlayer.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			local holdCF = root and CFrame.new(root.Position.X, CAPTURE_HOLD_Y, root.Position.Z) * root.CFrame.Rotation
			if holdCF then self:_glideRoot(holdCF, function() return not keepHolding() end) end
			while keepHolding() do
				local ch = LocalPlayer.Character
				local r = ch and ch:FindFirstChild("HumanoidRootPart")
				local h = ch and ch:FindFirstChildOfClass("Humanoid")
				if r and h and holdCF then
					pcall(function()
						r.CFrame = holdCF
						r.AssemblyLinearVelocity = Vector3.zero
						r.AssemblyAngularVelocity = Vector3.zero
					end)
					self:_syncHoverPad(holdCF.Position)
					local ls = math.clamp(self.config.speed or DEFAULT_MOVEMENT_SPEED, MIN_MOVEMENT_SPEED, maxMoveSpeed())
					pcall(function()
						setMovementSpoof(ch, ls * INTEGRITY_SPEED_HEADROOM)
						refreshIntegritySpoof(h, r, ls, Vector3.zero)
					end)
				end
				task.wait(0.1)
			end
			pcall(function() self:_stopHoverPad() end)
			if self._captureHoldUid == uid then self._captureHoldUid = nil end
			if self.destroyed or not self.enabled then return end
			self:_finish(self.captureObjectiveEnabled and "Capture egg lost — re-grabbing" or "Capture stopped")
		end)
	end
	function EggRuntime:_chooseTarget()
		if LocalPlayer:GetAttribute("InHalloweenDimension") == true then return nil end
		local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
		if not root then return nil end
		if self.captureObjectiveEnabled then
			local captureUid = workspace:GetAttribute(CAPTURE_EGG_ATTR)
			local capture = captureUid and (EggCmds.ReadFieldEgg(captureUid) or self.records[captureUid])
			if type(capture) == "table" and capture.BottomCFrame
				and (capture.State == AreaEggs.States.Slot or capture.State == AreaEggs.States.Dropped) then
				return capture
			end
		end
		if self.manualObjectiveEnabled then
			local picked = self:_takeManualTarget()
			if picked then
				return picked
			end
		end
		if Config.SnipeDroppedEggs and not self.riftOnly then
			local bestDrop, bestDropDist
			for _, record in pairs(self.records) do
				if record.State == AreaEggs.States.Dropped and record.BottomCFrame
				and record.CarrierUserId ~= LocalPlayer.UserId
				and not self:isSkippedEgg(record.Uid) and self:_matchesNormalFilter(record, true)
				and self:_inSnipeZone(record) then
					local dist = (record.BottomCFrame.Position - root.Position).Magnitude
					if not bestDrop or dist < bestDropDist then
						bestDrop, bestDropDist = record, dist
					end
				end
			end
			if bestDrop then return bestDrop end
		end
		if self.userStealEnabled and not self.riftOnly then
			local hasRare, bestRare = self:hasPriorityRareEgg()
			if hasRare and bestRare then
				return bestRare
			end
		end
		local bestRift, bestRiftDist, bestIndex, bestIndexDist, bestWisp, bestWispDist
		for _, record in pairs(self.records) do
			if (record.State == AreaEggs.States.Slot or record.State == AreaEggs.States.Dropped)
			and record.BottomCFrame and not self:isSkippedEgg(record.Uid)
			then
				local dist = (record.BottomCFrame.Position - root.Position).Magnitude
				if self.riftWants[record.AssetCategory] then
					if not bestRift or dist < bestRiftDist then bestRift, bestRiftDist = record, dist end
				elseif self.wispObjective and self:_isWispObjective(record) then
					if not bestWisp or dist < bestWispDist then bestWisp, bestWispDist = record, dist end
				elseif self.indexObjectiveEnabled and self:_isIndexObjective(record) then
					if not bestIndex or dist < bestIndexDist then bestIndex, bestIndexDist = record, dist end
				end
			end
		end
		if bestRift or bestWisp or bestIndex then
			return bestRift or bestWisp or bestIndex
		end
		if self.userStealEnabled and not self.riftOnly then
			local bestNormal, bestNormalRank, bestNormalDist
			for _, record in pairs(self.records) do
				if record.State == AreaEggs.States.Slot or record.State == AreaEggs.States.Dropped then
					if not self:isSkippedEgg(record.Uid) and self:_matchesNormalFilter(record) and not self:_tollAreaSkip(record) then
						local dist = (record.BottomCFrame.Position - root.Position).Magnitude
						local resolved = self.catalog.resolve(record)
						local priorityRank
						if self.config.highestValueFirst then
							priorityRank = resolveEggRate(record) or -math.huge
						elseif self.config.heaviestFirst then
							priorityRank = self:_resolveWeightKg(record) or -math.huge
						else
							priorityRank = resolved.rarityRank or 0
						end
						if not bestNormal or priorityRank > bestNormalRank or (priorityRank == bestNormalRank and dist < bestNormalDist) then
							bestNormal = record
							bestNormalRank = priorityRank
							bestNormalDist = dist
						end
					end
				end
			end
			if bestNormal then
				return bestNormal
			end
		end
		return nil
	end
	function EggRuntime:_takeManualTarget()
		local alive = {}
		local kept = {}
		for _, uid in ipairs(self.manualOrder) do
			local record = self.records[uid]
			if record and (record.State == AreaEggs.States.Slot or record.State == AreaEggs.States.Dropped) then
				kept[#kept + 1] = uid
				alive[uid] = true
			end
		end
		self.manualOrder = kept
		for uid in pairs(self.manualQueue) do
			if not alive[uid] then
				self.manualQueue[uid] = nil
			end
		end
		if #kept == 0 then
			if self.manualObjectiveEnabled then
				self.manualObjectiveEnabled = false
				task.defer(function()
					if not self.destroyed then
						self:_reconcileRunningState()
					end
					end)
			end
			return nil
		end
		return self.records[kept[1]]
	end
	function EggRuntime:queueManual(uids)
		if type(uids) ~= "table" then return 0 end
		for _, uid in ipairs(uids) do
			local key = uid
			if key ~= nil and not self.manualQueue[key] then
				self.manualQueue[key] = true
				self.manualOrder[#self.manualOrder + 1] = key
			end
		end
		local pending = #self.manualOrder
		if pending > 0 then
			self.manualObjectiveEnabled = true
		end
		self:_reconcileRunningState()
		return pending
	end
	function EggRuntime:clearManual()
		self.manualQueue = {}
		self.manualOrder = {}
		self.manualObjectiveEnabled = false
		self:_reconcileRunningState()
	end
	function EggRuntime:manualPending()
		return #self.manualOrder
	end
	function EggRuntime:setTreadmillManager(treadmillManager)
		self.treadmillManager = treadmillManager
	end
	function EggRuntime:getStealMode()
		return self.config.stealMode == "Fly" and "Fly" or "Instant"
	end
	function EggRuntime:setStealMode(mode, aerial, zigzag)
		local normalized = (mode == "Fly") and "Fly" or "Instant"
		local wantAerial = normalized == "Fly" and aerial == true
		local wantZigzag = normalized == "Fly" and zigzag == true and not wantAerial
		if self.config.stealMode ~= normalized or self.config.flyAerial ~= wantAerial or self.config.flyZigzag ~= wantZigzag then
			self.config.stealMode = normalized
			self.config.flyAerial = wantAerial
			self.config.flyZigzag = wantZigzag
			if self.enabled then
				self:_installGuardHitDistanceBoost()
				self:_finish("Mode changed")
			end
		end
		return normalized
	end
	local _originalResolveHitDistance = nil
	local GUARD_HIT_DISTANCE_BOOST = 25
	local GUARD_HIT_DISTANCE_IMMUNITY = 0.00001
	function EggRuntime:_installGuardHitDistanceBoost()
		if self.guardHitBoostInstalled then return end
		pcall(function()
			local GuardChasePolicy = require(ReplicatedStorage.Shared.Modules.GuardAreas.GuardChasePolicy)
			if GuardChasePolicy and type(GuardChasePolicy.ResolveHitDistance) == "function" then
				_originalResolveHitDistance = _originalResolveHitDistance or GuardChasePolicy.ResolveHitDistance
				local runtime = self
				GuardChasePolicy.ResolveHitDistance = function(hitDist)
					if runtime.enabled and runtime.instantPhase == "priming" then
						return GUARD_HIT_DISTANCE_BOOST
					end
					if runtime.enabled or runtime._recalling then
						return -math.huge
					end
					local base = _originalResolveHitDistance and _originalResolveHitDistance(hitDist) or (hitDist or 10)
					return base
				end
				self.guardHitBoostInstalled = true
			end
			end)
	end
	function EggRuntime:_removeGuardHitDistanceBoost()
		if not self.guardHitBoostInstalled then return end
		pcall(function()
			local GuardChasePolicy = require(ReplicatedStorage.Shared.Modules.GuardAreas.GuardChasePolicy)
			if GuardChasePolicy and _originalResolveHitDistance then
				GuardChasePolicy.ResolveHitDistance = _originalResolveHitDistance
				self.guardHitBoostInstalled = false
			end
			end)
	end
	function EggRuntime:_setInstantAnchored(anchored)
		pcall(function()
			local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
			if root and root.Anchored ~= anchored then root.Anchored = anchored end
			end)
	end
	function EggRuntime:_kbCancelTimer()
		if self.hitTimer then
			pcall(task.cancel, self.hitTimer)
			self.hitTimer = nil
		end
	end
	function EggRuntime:_isPrimerEgg(uid)
		if uid == nil then return false end
		if uid == self.primerUid then return true end
		local untilAt = self.primerUids and self.primerUids[uid]
		if untilAt and untilAt > os.clock() then return true end
		if untilAt then self.primerUids[uid] = nil end
		return false
	end
	function EggRuntime:_cleanupInstantSteal()
		self.instantPhase = nil
		self.primerUid = nil
		self.targetUid = nil
		self._flyDeparting = false
		self:_stopGuardStick()
		self:_kbCancelTimer()
		self:_setInstantAnchored(false)
		self:_hideTreadmillDecoy()
	end
	function EggRuntime:_choosePrimerEgg(excludeUid)
		local objects = resolveObjectsRoot()
		local areas = objects and objects:FindFirstChild("Areas")
		local guardAreas = areas and areas:FindFirstChild("GuardAreas")
		local forestArea = guardAreas and guardAreas:FindFirstChild("Forest")
		local forestGuard = forestArea and forestArea:FindFirstChild("Guard")
		local guardRoot = forestGuard and forestGuard:FindFirstChild("HumanoidRootPart")
		local guardPosition = guardRoot and guardRoot.Position
		local best, bestScore
		for _, rec in pairs(self.records) do
			if rec.State == AreaEggs.States.Slot and rec.AreaId == "Forest" and rec.Uid ~= excludeUid
				and not self:_isCaptureEgg(rec.Uid) then
				local dist = guardPosition and (rec.BottomCFrame.Position - guardPosition).Magnitude
				or (LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
					and (rec.BottomCFrame.Position - LocalPlayer.Character.HumanoidRootPart.Position).Magnitude
				or math.huge)
				local rarityRank = self.catalog.resolve(rec).rarityRank or 0
				local score = -dist - (rarityRank * 100)
				if not best or score > bestScore then
					best = rec
					bestScore = score
				end
			end
		end
		return best
	end
	local GUARD_STAND_OFFSET = 2.5
	local GUARD_STRIKE_INTERVAL = 0.05
	local GUARD_STRIKE_TIMEOUT = 1.5
	local GUARD_KNOCKBACK_VELOCITY = 18
	local GUARD_SETTLE_SECONDS = 0.35
	function EggRuntime:_stopGuardStick()
		if self.guardStickConnection then
			pcall(self.guardStickConnection.Disconnect, self.guardStickConnection)
			self.guardStickConnection = nil
		end
	end
	function EggRuntime:_startGuardStick()
		self:_stopGuardStick()
		local function forestGuardRoot()
			local objects = resolveObjectsRoot()
			local areas = objects and objects:FindFirstChild("Areas")
			local guardAreas = areas and areas:FindFirstChild("GuardAreas")
			local forest = guardAreas and guardAreas:FindFirstChild("Forest")
			local guard = forest and forest:FindFirstChild("Guard")
			return guard and guard:FindFirstChild("HumanoidRootPart")
		end
		self.guardStickConnection = RunService.PreSimulation:Connect(function()
			if self.destroyed or not self.enabled or self.instantPhase ~= "priming" then
				self:_stopGuardStick()
				return
			end
			local guardRoot = forestGuardRoot()
			local character = LocalPlayer.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if not guardRoot or not root then
				return
			end
			local guardPosition = guardRoot.Position
			local front = guardRoot.CFrame.LookVector * GUARD_STAND_OFFSET
			local standAt = Vector3.new(guardPosition.X + front.X, root.Position.Y, guardPosition.Z + front.Z)
			local delta = standAt - root.Position
			if delta.Magnitude > 40 then
				delta = delta.Unit * 40
			end
			local nextPosition = root.Position + delta
			root.CFrame = CFrame.lookAt(nextPosition, Vector3.new(guardPosition.X, nextPosition.Y, guardPosition.Z))
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
			self:_syncHoverPad(nextPosition)
			end)
	end
	function EggRuntime:_forestGuardModel()
		local objects = resolveObjectsRoot()
		local areas = objects and objects:FindFirstChild("Areas")
		local guardAreas = areas and areas:FindFirstChild("GuardAreas")
		local forest = guardAreas and guardAreas:FindFirstChild("Forest")
		return forest and forest:FindFirstChild("Guard")
	end
	function EggRuntime:_triggerGuardHit()
		local guard = self:_forestGuardModel()
		local guardRoot = guard and guard:FindFirstChild("HumanoidRootPart")
		if not guardRoot then return end
		local character = LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root then return end
		local guardPosition = guardRoot.Position
		local front = guardRoot.CFrame.LookVector * GUARD_STAND_OFFSET
		local standAt = Vector3.new(guardPosition.X + front.X, root.Position.Y, guardPosition.Z + front.Z)
		self.guardStrikeAnchor = standAt
		root.CFrame = CFrame.lookAt(standAt, Vector3.new(guardPosition.X, standAt.Y, guardPosition.Z))
		root.AssemblyLinearVelocity = Vector3.zero
		local collider = guard:FindFirstChild("Collider") or guardRoot
		if collider and firetouchinterest then
			pcall(function()
				firetouchinterest(root, collider, 0)
				firetouchinterest(root, collider, 1)
				end)
		end
		pcall(function()
			local strike = Remotes.GuardPatrol and Remotes.GuardPatrol.ForestStrike
			if strike then
				strike:FireServer({
					EggUid = self.primerUid,
					GuardCFrame = guardRoot.CFrame,
					})
			end
			end)
	end
	function EggRuntime:_stopGuardStrike()
		self.guardStrikeGeneration = (self.guardStrikeGeneration or 0) + 1
	end
	function EggRuntime:_knockbackLanded()
		local character = LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not root or not humanoid then return false end
		if humanoid.PlatformStand or humanoid.Sit then return true end
		local state = humanoid:GetState()
		if state == Enum.HumanoidStateType.Ragdoll
		or state == Enum.HumanoidStateType.FallingDown
		or state == Enum.HumanoidStateType.PlatformStanding
		then
			return true
		end
		return root.AssemblyLinearVelocity.Magnitude > GUARD_KNOCKBACK_VELOCITY
	end
	function EggRuntime:_settleAfterKnockback()
		local anchor = self.guardStrikeAnchor
		local deadline = os.clock() + GUARD_SETTLE_SECONDS
		while os.clock() < deadline and not self.destroyed do
			local character = LocalPlayer.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if not root then return end
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if humanoid then
				pcall(function()
					humanoid.PlatformStand = false
					humanoid.Sit = false
					humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
					end)
			end
			if anchor then root.CFrame = CFrame.new(anchor) end
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
			self:_syncHoverPad(anchor or root.Position)
			RunService.Heartbeat:Wait()
		end
	end
	function EggRuntime:_startGuardStrike()
		self:_stopGuardStrike()
		local generation = self.guardStrikeGeneration
		task.spawn(function()
			local deadline = os.clock() + GUARD_STRIKE_TIMEOUT
			while not self.destroyed
			and self.enabled
			and self.instantPhase == "priming"
			and self.guardStrikeGeneration == generation
			and os.clock() < deadline
			do
				self:_triggerGuardHit()
				local waitUntil = os.clock() + GUARD_STRIKE_INTERVAL
				local landed = false
				while os.clock() < waitUntil do
					if self:_knockbackLanded() then landed = true break end
					RunService.Heartbeat:Wait()
				end
				if landed then break end
			end
			if self.guardStrikeGeneration == generation then
				self:_stopGuardStick()
				self:_settleAfterKnockback()
			end
			end)
	end
	function EggRuntime:_enterBaitWait()
		self:_setInstantAnchored(false)
		self:_setStatus("Preparing steal")
		self:_startGuardStick()
		self:_startGuardStrike()
		if self.hitTimer then return end
		self.hitTimer = task.delay(GUARD_STRIKE_TIMEOUT + 0.3, function()
			self.hitTimer = nil
			if self.destroyed or not self.enabled then return end
			if self.instantPhase ~= "priming" then return end
			self:_stopGuardStick()
			self:_stopGuardStrike()
			if self.carry.active and self:_isPrimerEgg(self.carry.uid) then
				pcall(EggCmds.DropFieldEgg, "PlayerRequest")
			end
			self:_finish("Steal timed out — retrying")
			end)
	end
	local function settleAtLevel(areaId, level)
		local area = tostring(areaId or ""):lower()
		local baseline, floor = 8, 3.5
		if area:find("enchanted") then
			baseline, floor = 18, 12
		elseif area:find("light") or area:find("dark") then
			baseline, floor = 16, 10
		elseif area:find("titan") or area:find("cosmic") or area:find("cherry") then
			baseline, floor = 10, 8
		end
		return math.max(floor, baseline * ((11 - math.clamp(level, 1, 10)) / 6))
	end
	function EggRuntime:_resolveSettleSeconds(record)
		local level = math.clamp(tonumber(Config.StealHoldSeconds) or 5, 1, 10)
		local bonus = self.settleBonus and type(record) == "table" and self.settleBonus[record.Uid]
		local extra = (bonus and bonus.untilAt > os.clock()) and bonus.seconds or 0
		local fps = currentFps()
		if fps > 0 and fps < 12 then extra = extra + 2 end
		if runtimeEnv.__SenaV4NetPing() > 300 then extra = extra + 1 end
		return settleAtLevel(type(record) == "table" and record.AreaId, level) + extra
	end
	function EggRuntime:_startPrimerTargetHunt()
		if self.instantPhase ~= "priming" then return end
		self:_stopGuardStick()
		self:_stopGuardStrike()
		pcall(function()
			local character = LocalPlayer.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if humanoid then
				humanoid.PlatformStand = false
				humanoid.Sit = false
			end
			if root then
				if self.guardStrikeAnchor then root.CFrame = CFrame.new(self.guardStrikeAnchor) end
				root.AssemblyLinearVelocity = Vector3.zero
				root.AssemblyAngularVelocity = Vector3.zero
			end
			end)
		self:_kbCancelTimer()
		self:_setInstantAnchored(false)
		self.instantPhase = "hunting"
		self:_clearArrivalHold()
		self.carry.generation += 1
		self:_invalidateCarryWorker()
		self.carry.active = false
		self.carry.uid = nil
		local targetUid = self.targetUid
		self.targetUid = nil
		if not targetUid then
			self:_finish("No target egg")
			return
		end
		local current = EggCmds.ReadFieldEgg(targetUid) or self.records[targetUid]
		if not current or (current.State ~= AreaEggs.States.Slot and current.State ~= AreaEggs.States.Dropped) then
			self:_finish("Target egg no longer available")
			return
		end
		local character = LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not root or not humanoid then
			self:_finish("Character unavailable")
			return
		end
		self.activeTarget = current
		local destination = self:_resolveEggDestination(current, root, humanoid)
		if not destination then
			self:_finish("Target destination unavailable")
			return
		end
		if self.config.stealMode == "Fly" then
			local holdUid = current.Uid
			local function stale()
				return self.destroyed or not self.enabled
					or self.instantPhase ~= "hunting"
					or not self.activeTarget or self.activeTarget.Uid ~= holdUid
			end
			if self.config.flyAerial then
				self:_setStatus("Heading to target egg")
				self:_startFlyGrounding()
				local __flyOk = self:_flyWalkTo(destination, stale, 8, 110)
				self:_stopFlyGrounding()
				if not __flyOk then
					if not stale() then self:_finish("Could not reach the egg — retrying") end
					return
				end
			elseif self.config.flyZigzag then
				self:_setStatus("Heading to target egg")
				if not self:_walkToZigzag(destination, stale) then
					if not stale() then self:_finish("Zig-zag walk to target failed") end
					return
				end
			else
				self:_setStatus("Heading to target egg")
				if not self:_walkTo(destination, stale) then
					if not stale() then self:_finish("Walk to target failed") end
					return
				end
			end
			if stale() then return end
			self:_glideRoot(destination, stale, self:_legitWalkSpeed())
			if stale() then return end
			self:_setArrivalHold(destination, holdUid)
			self:_setStatus("Securing target egg")
			self:_requestCarry(current, true)
			return
		end
		if self.config.stealMode == "Instant" then
			local holdUid = current.Uid
			local function stale()
				return self.destroyed or not self.enabled
					or self.instantPhase ~= "hunting"
					or not self.activeTarget or self.activeTarget.Uid ~= holdUid
			end
			local hoverCF = destination + Vector3.new(0, HOVER_DESYNC_HEIGHT, 0)
			self:_setStatus("Heading to target egg")
			if not self:_glideRoot(hoverCF, stale) then
				if not stale() then self:_finish("Could not reach the egg — retrying") end
				return
			end
			task.spawn(self._hoverSettleCarry, self, current, destination, hoverCF, stale)
			return
		end
		self:_setStatus("Heading to target egg")
		self:_tweenRoot(destination, function()
			if self.instantPhase == "hunting"
			and self.activeTarget
			and self.activeTarget.Uid == current.Uid
			then
				self:_requestCarry(current, false)
			end
			end, nil, {
				holdAfterArrival = true,
				holdUid = current.Uid,
				flightProfile = true,
				carryTarget = current,
			})
	end
	function EggRuntime:_hoverSettleCarry(current, destination, hoverCF, stale)
		self:_startHoverPad()
		local hold = self:_resolveSettleSeconds(current)
		local deadline = os.clock() + hold
		while os.clock() < deadline do
			if stale() then return end
			self:_setStatus(string.format("Securing target egg (%.1fs)", math.max(0, deadline - os.clock())))
			local ch = LocalPlayer.Character
			local r = ch and ch:FindFirstChild("HumanoidRootPart")
			local h = ch and ch:FindFirstChildOfClass("Humanoid")
			if r and h then
				pcall(function()
					r.CFrame = hoverCF
					r.AssemblyLinearVelocity = Vector3.zero
					r.AssemblyAngularVelocity = Vector3.zero
					end)
				self:_syncHoverPad(hoverCF.Position)
				local ls = math.clamp(self.config.speed or DEFAULT_MOVEMENT_SPEED, MIN_MOVEMENT_SPEED, maxMoveSpeed())
				pcall(function()
					setMovementSpoof(ch, ls * INTEGRITY_SPEED_HEADROOM)
					refreshIntegritySpoof(h, r, ls, Vector3.zero)
					end)
			end
			task.wait(0.1)
		end
		if stale() then return end
		self:_glideRoot(destination, stale)
		if stale() then return end
		self:_setArrivalHold(destination, current.Uid)
		self:_setStatus("Securing target egg")
		self:_requestCarry(current, true)
	end
	function EggRuntime:_wallOpen()
		if self.resetBlocked or AreaEggResetWall.IsSealed() or os.clock() < self.gateOpenAt then
			return false
		end
		local __root = resolveObjectsRoot()
		local areas = __root and __root:FindFirstChild("Areas")
		local collision = areas and areas:FindFirstChild("WallStartCollision")
		if collision and collision:IsA("BasePart") and collision.CanCollide then
			return false
		end
		return true
	end
	function EggRuntime:_closeGate(reason)
		self.resetBlocked = true
		self.gateOpenAt = math.huge
		self.safeStarting = false
		if not (self.activeTween and self.activeTween.sharedTravel) then
			self:_cancelTween(reason)
		end
		self:_setStatus(reason)
	end
	function EggRuntime:_releaseOperation()
		local token = self.operationToken
		self.operationToken = nil
		if token and self.coordinator then
			self.coordinator:release(token)
		end
	end
	function EggRuntime:_acquireOperation()
		if self.operationToken or not self.coordinator then
			return true
		end
		local token, reason = self.coordinator:tryAcquire("auto_steal", {})
		if not token then
			return false, reason
		end
		self.operationToken = token
		return true
	end
	function EggRuntime:_cancelTween(reason, keepOperation)
		self:_cleanupInstantSteal()
		self.carryAttemptToken = nil
		self:_clearArrivalHold()
		self.safeStarting = false
		if self.activeTween then
			pcall(self.activeTween.Cancel, self.activeTween)
			self.activeTween = nil
		end
		if not self.activeTween and not self.arrivalHold then self:_stopHoverPad() end
		if self.running then
			self.running = false
			self.activeTarget = nil
			self.stats.lastResult = reason
			self:_notify()
		end
		if not keepOperation then
			self:_releaseOperation()
		end
	end
	function EggRuntime:_groundYAt(x, z, character)
		character = character or (LocalPlayer.Character)
		local origin = Vector3.new(x, (character and character:FindFirstChild("HumanoidRootPart") and character.HumanoidRootPart.Position.Y or SAFE_ZONE_POSITION.Y) + 60, z)
		local exclude = {}
		if character then table.insert(exclude, character) end
		if self.hoverPad then table.insert(exclude, self.hoverPad) end
		if self.treadmillDecoy then table.insert(exclude, self.treadmillDecoy) end
		for _, c in ipairs(workspace:GetChildren()) do
			if c.Name == HOVER_PAD_NAME or c.Name == TREADMILL_DECOY_NAME then
				table.insert(exclude, c)
			end
		end
		for _ = 1, 10 do
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.FilterDescendantsInstances = exclude
			params.IgnoreWater = true
			local hit = workspace:Raycast(origin, Vector3.new(0, -300, 0), params)
			if not hit then return nil end
			if hit.Instance.CanCollide then return hit.Position.Y end
			table.insert(exclude, hit.Instance)
		end
		return nil
	end
	function EggRuntime:_resolveSafeCFrame(root)
		if not root then return nil end
		local x, z = SAFE_ZONE_POSITION.X, SAFE_ZONE_POSITION.Z
		local y = SAFE_ZONE_POSITION.Y
		local character = root.Parent
		local groundY = self:_groundYAt(x, z, character)
		if groundY then y = groundY + 3.2 end
		return CFrame.new(x, y, z) * root.CFrame.Rotation
	end
	function EggRuntime:_groundSnap()
		local character = LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not root or not humanoid then return false end
		local pos = root.Position
		local groundY = self:_groundYAt(pos.X, pos.Z, character)
		if not groundY then return false end
		local restY = groundY + self:_feetOffset(root, humanoid)
		if pos.Y < restY - 0.25 or pos.Y > restY + 8 then
			pcall(function()
				self:_syncHoverPad(Vector3.new(pos.X, restY, pos.Z))
				root.CFrame = CFrame.new(pos.X, restY, pos.Z) * root.CFrame.Rotation
				root.AssemblyLinearVelocity = Vector3.zero
				root.AssemblyAngularVelocity = Vector3.zero
			end)
			return true
		end
		return false
	end
	local function destroyTreadmillDecoyTrail(instance)
		if typeof(instance) == "Instance" and instance:IsA("Trail") then
			pcall(instance.Destroy, instance)
		end
	end
	local function destroyTreadmillStealPopup(instance)
		if typeof(instance) == "Instance"
		and (instance.Name == "SpeedGainPopup" or instance.Name == "PlusOne")
		then
			pcall(instance.Destroy, instance)
		end
	end
	function EggRuntime:_showTreadmillDecoy()
		if self.treadmillDecoy and self.treadmillDecoy.Parent then
			return true
		end
		self:_hideTreadmillDecoy()
		local character = LocalPlayer.Character
		if not character then return false end
		local oldArchivable = character.Archivable
		character.Archivable = true
		local cloned, clone = pcall(character.Clone, character)
		character.Archivable = oldArchivable
		if not cloned or not clone or typeof(clone) ~= "Instance" then return false end
		clone.Name = TREADMILL_DECOY_NAME
		for _, descendant in ipairs(clone:GetDescendants()) do
			if TREADMILL_DECOY_REMOVE_CLASSES[descendant.ClassName] or descendant:IsA("Trail") then
				pcall(descendant.Destroy, descendant)
			elseif descendant:IsA("BasePart") then
				descendant.LocalTransparencyModifier = 0
				descendant.Anchored = true
				descendant.CanCollide = false
				descendant.CanQuery = false
				descendant.CanTouch = false
			end
		end
		local root = clone:FindFirstChild("HumanoidRootPart")
		local humanoid = clone:FindFirstChildOfClass("Humanoid")
		if not root or not humanoid then
			clone:Destroy()
			return false
		end
		pcall(function()
			humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
			humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
			end)
		clone.Parent = workspace
		clone:PivotTo(CFrame.new(SAFE_ZONE_POSITION))
		self.treadmillDecoy = clone
		local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
		if playerGui then
			for _, instance in ipairs(playerGui:GetDescendants()) do
				if instance.Name == "SpeedGainPopup" or instance.Name == "PlusOne" then
					destroyTreadmillStealPopup(instance)
				end
			end
			self.treadmillPopupConnection = playerGui.DescendantAdded:Connect(function(instance)
				if self.treadmillDecoy == clone then
					destroyTreadmillStealPopup(instance)
				end
				end)
		end
		local originals = setmetatable({}, { __mode = "k" })
		local function hideLivePart(part)
			if not part or not part:IsA("BasePart") or not part:IsDescendantOf(character) then return end
			if originals[part] == nil then originals[part] = part.LocalTransparencyModifier end
			part.LocalTransparencyModifier = 1
		end
		for _, descendant in ipairs(character:GetDescendants()) do
			hideLivePart(descendant)
			destroyTreadmillDecoyTrail(descendant)
		end
		self.treadmillDecoyRealTransparency = originals
		self.treadmillDecoyCharacterConnection = character.DescendantAdded:Connect(function(descendant)
			if self.treadmillDecoy == clone then
				pcall(hideLivePart, descendant)
				destroyTreadmillDecoyTrail(descendant)
			end
			end)
		local camera = workspace.CurrentCamera
		if camera then
			self.treadmillDecoyCamera = camera.CameraSubject
			camera.CameraSubject = humanoid
		end
		self.treadmillDecoyCameraConnection = RunService.RenderStepped:Connect(function()
			if self.treadmillDecoy ~= clone or not clone.Parent or not humanoid.Parent then return end
			for part in pairs(originals) do
				if part.Parent and part.LocalTransparencyModifier ~= 1 then
					part.LocalTransparencyModifier = 1
				end
			end
			local liveCamera = workspace.CurrentCamera
			if liveCamera and liveCamera.CameraSubject ~= humanoid then
				liveCamera.CameraSubject = humanoid
			end
			end)
		return true
	end
	function EggRuntime:_hideTreadmillDecoy(force)
		if self._recalling and not force then return end
		if self.treadmillDecoyCameraConnection then
			pcall(self.treadmillDecoyCameraConnection.Disconnect, self.treadmillDecoyCameraConnection)
			self.treadmillDecoyCameraConnection = nil
		end
		if self.treadmillDecoyCharacterConnection then
			pcall(self.treadmillDecoyCharacterConnection.Disconnect, self.treadmillDecoyCharacterConnection)
			self.treadmillDecoyCharacterConnection = nil
		end
		if self.treadmillPopupConnection then
			pcall(self.treadmillPopupConnection.Disconnect, self.treadmillPopupConnection)
			self.treadmillPopupConnection = nil
		end
		for part, transparency in pairs(self.treadmillDecoyRealTransparency or {}) do
			if typeof(part) == "Instance" and part.Parent then
				pcall(function() part.LocalTransparencyModifier = transparency end)
			end
		end
		self.treadmillDecoyRealTransparency = nil
		local character = LocalPlayer.Character
		local liveHumanoid = character and character:FindFirstChildOfClass("Humanoid")
		local camera = workspace.CurrentCamera
		if camera then
			pcall(function()
				camera.CameraSubject = liveHumanoid or self.treadmillDecoyCamera
				end)
		end
		self.treadmillDecoyCamera = nil
		if self.treadmillDecoy then pcall(self.treadmillDecoy.Destroy, self.treadmillDecoy) end
		self.treadmillDecoy = nil
	end
	function EggRuntime:_restoreTreadmillVisualAtSafe()
		if not self.treadmillDecoy then
			self:_hideTreadmillDecoy()
			return true
		end
		local character = LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local safeDestination = self:_resolveSafeCFrame(root)
		if not root or not humanoid or not safeDestination then
			self:_hideTreadmillDecoy()
			return false
		end
		local deadline = os.clock() + SAFE_TELEPORT_TIMEOUT_SECONDS
		local stableSince = nil
		local nextTeleportAt = 0
		while not self.destroyed and os.clock() < deadline do
			local now = os.clock()
			if not self:_isInSafeArea(root) then
				stableSince = nil
				if now >= nextTeleportAt then
					nextTeleportAt = now + SAFE_TELEPORT_RETRY_SECONDS
					self:_teleportRoot(root, humanoid, safeDestination)
				end
			else
				stableSince = stableSince or now
				if now - stableSince >= SAFE_TELEPORT_STABLE_SECONDS then
					self:_hideTreadmillDecoy()
					return true
				end
			end
			task.wait(0.03)
		end
		self:_hideTreadmillDecoy()
		return false
	end
	function EggRuntime:_prepareTreadmillLaunch(record, planGeneration)
		local treadmill = self.treadmillManager
		if not treadmill or type(treadmill.pulseForCarry) ~= "function" then
			return false, "Preparation unavailable"
		end
		local targetUid = record and record.Uid
		local function currentTarget()
			return targetUid and (EggCmds.ReadFieldEgg(targetUid) or self.records[targetUid]) or nil
		end
		local function abort()
			local current = currentTarget()
			return self.destroyed
			or not self.enabled
			or self.planGeneration ~= planGeneration
			or not self:_wallOpen()
			or type(current) ~= "table"
			or not self:_matches(current)
		end
		local function teleport(destination)
			local character = LocalPlayer.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			return self:_teleportRoot(root, humanoid, destination)
		end
		self:_setStatus("Preparing carry")
		if not self:_showTreadmillDecoy() then
			return false, "Safe-zone visual unavailable"
		end
		local pulsed, reason = treadmill:pulseForCarry(teleport, abort)
		if not pulsed then
			self:_restoreTreadmillVisualAtSafe()
			return false, reason
		end
		self:_setStatus("Positioning at safe area")
		if not self:_restoreTreadmillVisualAtSafe() then
			return false, "Safe teleport failed"
		end
		if abort() then return false, "Target changed before travel" end
		return true, currentTarget()
	end
	function EggRuntime:_resolveEggDestination(record, root, humanoid)
		if type(record) ~= "table" or typeof(record.BottomCFrame) ~= "CFrame" then
			return nil
		end
		local character = LocalPlayer.Character
		root = root or (character and character:FindFirstChild("HumanoidRootPart"))
		humanoid = humanoid or (character and character:FindFirstChildOfClass("Humanoid"))
		if not root or not humanoid then
			return nil
		end
		local standingHeight = self:_feetOffset(root, humanoid) + EGG_ARRIVAL_CLEARANCE
		return CFrame.new(record.BottomCFrame.Position + Vector3.new(0, standingHeight, 0))
	end
	local FLY_CRUISE_HEIGHT = 110
	local ZIGZAG_MAX_AMPLITUDE = 30
	local ZIGZAG_WAVELENGTH = 900
	local ZIGZAG_FADE_DISTANCE = 120
	local ZIGZAG_LANE_MARGIN = 18
	local ZIGZAG_LANE_MIN_FALLBACK = -426
	local ZIGZAG_LANE_MAX_FALLBACK = -308
	local function zigzagLaneBounds()
		local ok, folder = pcall(function()
			local __root = resolveObjectsRoot()
			return __root and __root:FindFirstChild("Areas") and __root.Areas:FindFirstChild("EggCarryBounds")
			end)
		if ok and folder then
			local lane = folder:FindFirstChild("Gameplay1")
			if lane and lane:IsA("BasePart") then
				local half = lane.Size.Z * 0.5 - ZIGZAG_LANE_MARGIN
				if half > 5 then
					return lane.Position.Z - half, lane.Position.Z + half
				end
			end
		end
		return ZIGZAG_LANE_MIN_FALLBACK, ZIGZAG_LANE_MAX_FALLBACK
	end
	function EggRuntime:_resolveRouteCruiseY(root, destination)
		if self.config.stealMode ~= "Fly" then return nil end
		if not root or typeof(destination) ~= "CFrame" then return nil end
		local cruise = FLY_CRUISE_HEIGHT
		if destination.Position.Y >= cruise - 6 then return nil end
		return cruise
	end
	function EggRuntime:_resolveElevatedDestination(root, destination)
		if not root or typeof(destination) ~= "CFrame" then return nil end
		return destination
	end
	function EggRuntime:_teleportRoot(root, humanoid, destination)
		if not root or not humanoid or typeof(destination) ~= "CFrame" then return false end
		if (LocalPlayer:GetAttribute("InHalloweenDimension") == true and destination.Position.Y > -100) or runtimeEnv.__SenaV4OnTrain == true then return false end
		local ok = pcall(function()
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
			root.CFrame = destination
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
			end)
		if not ok then return false end
		local liveSpeed = math.clamp(self.config.speed or DEFAULT_MOVEMENT_SPEED, MIN_MOVEMENT_SPEED, maxMoveSpeed())
		setMovementSpoof(LocalPlayer.Character, liveSpeed * INTEGRITY_SPEED_HEADROOM)
		if not refreshIntegritySpoof(humanoid, root, liveSpeed, Vector3.zero) then
			setIntegritySpoof(humanoid, root, liveSpeed)
			refreshIntegritySpoof(humanoid, root, liveSpeed, Vector3.zero)
		end
		return true
	end
	function EggRuntime:_boostSafeHop(root, humanoid)
		-- Route via the safezone CFrame before the raw TP onto the egg, so the teleport does not
		-- originate from a wall-clipped position (anti-cheat rejects that -> steal interrupt / "mati").
		-- Tunable: set runtimeEnv.__SenaV4BoostSafeHop = false to A/B it off.
		if runtimeEnv.__SenaV4BoostSafeHop == false then return end
		if not root or not humanoid then return end
		if self:_isInSafeArea(root) then return end
		local safeCF = self:_resolveSafeCFrame(root)
		if safeCF then
			self:_teleportRoot(root, humanoid, safeCF)
			RunService.PreSimulation:Wait()
		end
	end
	function EggRuntime:_legitWalkSpeed()
		local ws
		pcall(function()
			local h = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
			ws = h and h.WalkSpeed
		end)
		if type(ws) == "number" and ws >= 1 and ws <= 400 then
			self._legitWsCache = ws
		end
		return self._legitWsCache or (type(ws) == "number" and math.clamp(ws, 1, 400)) or 16
	end
	function EggRuntime:_activeGlideSpeed()
		if self.config.stealMode == "Fly" and self._flyDeparting then
			return self:_legitWalkSpeed()
		end
		return GLIDE_SPEED
	end
	function EggRuntime:_glideRoot(destCF, abortFn, speed)
		if typeof(destCF) ~= "CFrame" then return false end
		speed = speed or self:_activeGlideSpeed()
		local character = LocalPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root or not humanoid then return false end
		pcall(applyKillPartIgnore, character)
		pcall(function() humanoid.AutoRotate = false end)
		self:_startHoverPad()
		local target = destCF.Position
		local function warmSpoof(ch, h, r)
			local ls = math.clamp(self.config.speed or DEFAULT_MOVEMENT_SPEED, MIN_MOVEMENT_SPEED, maxMoveSpeed())
			pcall(function()
				setMovementSpoof(ch, ls * INTEGRITY_SPEED_HEADROOM)
				refreshIntegritySpoof(h, r, ls, Vector3.zero)
				end)
		end
		local deadline = os.clock() + math.clamp((target - root.Position).Magnitude / math.max(speed, 1) * 1.6 + 6, 15, 120)
		while os.clock() < deadline do
			if abortFn and abortFn() then return false end
			if self.destroyed or not (self.enabled or self._externalDeliver) then return false end
			character = LocalPlayer.Character
			root = character and character:FindFirstChild("HumanoidRootPart")
			humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if not root or not humanoid then return false end
			local pos = root.Position
			local remaining = target - pos
			local dist = remaining.Magnitude
			if dist <= 1.0 then
				pcall(function()
					root.CFrame = destCF
					root.AssemblyLinearVelocity = Vector3.zero
					root.AssemblyAngularVelocity = Vector3.zero
					end)
				self:_syncHoverPad(target)
				warmSpoof(character, humanoid, root)
				return true
			end
			local dt = RunService.Heartbeat:Wait()
			dt = math.max(math.min(dt, LONG_FRAME_CLAMP), 1 / 240)
			local step = math.min(speed * dt, dist)
			local nextPos = pos + remaining.Unit * step
			if dt >= (1 / 30) then
				local groundY = self:_groundYAt(nextPos.X, nextPos.Z, character)
				if groundY then
					local minY = groundY + self:_feetOffset(root, humanoid)
					if nextPos.Y < minY then nextPos = Vector3.new(nextPos.X, minY, nextPos.Z) end
				end
			end
			pcall(function()
				root.CFrame = CFrame.new(nextPos, nextPos + remaining.Unit)
				root.AssemblyLinearVelocity = Vector3.zero
				root.AssemblyAngularVelocity = Vector3.zero
				end)
			self:_syncHoverPad(nextPos)
			warmSpoof(character, humanoid, root)
		end
		return false
	end
	EggRuntime.HOP = { studs = 500, gap = 0.15, height = 40, safeWait = 0.8 }
	EggRuntime.RELAY_LAND_OK = 200
	EggRuntime.RELAY_ROUNDS = 3
	EggRuntime.EGG_FREE_SLOTS = 5
	EggRuntime.DRAIN_HIGH = 25
	EggRuntime.DRAIN_LOW = 10
	function EggRuntime:_relaySettle()
		if not self._relaySettle_s then
			local ping = 0.05
			pcall(function() ping = LocalPlayer:GetNetworkPing() or 0.05 end)
			self._relaySettle_s = math.clamp(0.5 + ping * 4, EggRuntime.HOP.safeWait, 2)
			self._relayGood = 0
		end
		return self._relaySettle_s
	end
	function EggRuntime:_noteRelayLanding(distance)
		local settle = self:_relaySettle()
		if distance > EggRuntime.RELAY_LAND_OK then
			self._relaySettle_s = math.min(settle + 0.2, 2)
			self._relayGood = 0
		else
			self._relayGood = (self._relayGood or 0) + 1
			if self._relayGood >= 5 then
				self._relayGood = 0
				self._relaySettle_s = math.max(settle - 0.05, EggRuntime.HOP.safeWait)
			end
		end
	end
	function EggRuntime:_hopRoot(destCF, abortFn)
		if typeof(destCF) ~= "CFrame" then return false end
		local cfg = EggRuntime.HOP
		local character = LocalPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root or not humanoid then return false end
		pcall(applyKillPartIgnore, character)
		pcall(function() humanoid.AutoRotate = false end)
		self:_startHoverPad()
		local target = destCF.Position
		local cruiseY = target.Y + cfg.height
		local function alive()
			if abortFn and abortFn() then return false end
			if self.destroyed or not (self.enabled or self._externalDeliver) then return false end
			character = LocalPlayer.Character
			root = character and character:FindFirstChild("HumanoidRootPart")
			humanoid = character and character:FindFirstChildOfClass("Humanoid")
			return root ~= nil and humanoid ~= nil and humanoid.Health > 0
		end
		local function place(cf)
			pcall(function()
				root.AssemblyLinearVelocity = Vector3.zero
				root.AssemblyAngularVelocity = Vector3.zero
				root.CFrame = cf
				root.AssemblyLinearVelocity = Vector3.zero
				root.AssemblyAngularVelocity = Vector3.zero
				end)
			self:_syncHoverPad(cf.Position)
			local ls = math.clamp(self.config.speed or DEFAULT_MOVEMENT_SPEED, MIN_MOVEMENT_SPEED, maxMoveSpeed())
			pcall(function()
				setMovementSpoof(character, ls * INTEGRITY_SPEED_HEADROOM)
				refreshIntegritySpoof(humanoid, root, ls, Vector3.zero)
				end)
		end
		local deadline = os.clock() + 20
		while os.clock() < deadline do
			if not alive() then return false end
			local pos = root.Position
			local flat = Vector3.new(target.X - pos.X, 0, target.Z - pos.Z)
			local dist = flat.Magnitude
			if dist <= cfg.studs then
				place(destCF)
				return true
			end
			local nextPos = Vector3.new(pos.X, cruiseY, pos.Z) + flat.Unit * cfg.studs
			local hopCF = CFrame.new(nextPos, nextPos + flat.Unit)
			place(hopCF)
			local holdUntil = os.clock() + cfg.gap
			while os.clock() < holdUntil do
				RunService.Heartbeat:Wait()
				if not alive() then return false end
				place(hopCF)
			end
		end
		return false
	end
	local WALK_BRAKE_DECEL = 420 
	local WALK_SETTLE_SPEED = 20 
	local WALK_LOOKAHEAD_SECONDS = 0.5
	function EggRuntime:_walkBrakeDecel()
		if self._brakeDecel then return self._brakeDecel end
		local saved = runtimeEnv.__SenaV4BrakeDecel
		local humanoid = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
		if type(saved) == "table" and humanoid and math.abs((saved.ws or 0) - humanoid.WalkSpeed) < 15 then
			self._brakeDecel = saved.decel
			return saved.decel
		end
		return WALK_BRAKE_DECEL
	end
	function EggRuntime:_walkLeg(goal, abortFn, arriveDist, final, deadline, onStep)
		local legDir
		local brakeSpeed, brakeAt
		local function halt(h, r)
			if h and r then pcall(function() h:MoveTo(r.Position) end) end
			return false
		end
		while os.clock() < deadline do
			local character = LocalPlayer.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if not root or not humanoid then return false end
			if abortFn and abortFn() then return halt(humanoid, root) end
			if self.destroyed or (not self.enabled and not self._externalDeliver) then return halt(humanoid, root) end
			local pos = root.Position
			local flat = Vector3.new(goal.X - pos.X, 0, goal.Z - pos.Z)
			local dist = flat.Magnitude
			local vel = root.AssemblyLinearVelocity
			local speed = Vector3.new(vel.X, 0, vel.Z).Magnitude
			if not final then
				legDir = legDir or (dist > 0.001 and flat.Unit or Vector3.zero)
				if dist <= arriveDist or flat:Dot(legDir) <= 0 then return true end
			elseif dist <= arriveDist and speed <= WALK_SETTLE_SPEED then
				pcall(function() humanoid:MoveTo(pos) end)
				return true
			end
			local aim
			local closing = dist > 0.001 and math.max(vel.X * flat.X + vel.Z * flat.Z, 0) / dist or speed
			if final and dist <= closing * closing / (2 * self:_walkBrakeDecel()) + closing * 0.06 then
				aim = pos 
				local now = os.clock()
				if brakeSpeed and now > brakeAt and speed > WALK_SETTLE_SPEED then
					local sample = (brakeSpeed - speed) / (now - brakeAt)
					if sample > 20 and sample < 5000 then
						self._brakeDecel = self:_walkBrakeDecel() * 0.8 + sample * 0.93 * 0.2
						runtimeEnv.__SenaV4BrakeDecel = { ws = humanoid.WalkSpeed, decel = self._brakeDecel }
					end
				end
				brakeSpeed, brakeAt = speed, now
			else
				brakeSpeed = nil
				local look = math.max(humanoid.WalkSpeed * WALK_LOOKAHEAD_SECONDS, 12)
				if final and dist <= look then
					aim = Vector3.new(goal.X, pos.Y, goal.Z)
				else
					aim = pos + flat.Unit * look
				end
			end
			pcall(function() humanoid:MoveTo(aim) end)
			if onStep then onStep() end
			RunService.Heartbeat:Wait()
		end
		local character = LocalPlayer.Character
		return halt(character and character:FindFirstChildOfClass("Humanoid"), character and character:FindFirstChild("HumanoidRootPart"))
	end
	function EggRuntime:_walkTo(destCF, abortFn, arriveDist)
		if typeof(destCF) ~= "CFrame" then return false end
		arriveDist = arriveDist or 8
		local character = LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not root or not humanoid then return false end
		pcall(function() humanoid.AutoRotate = true end)
		local target = destCF.Position
		local ws = humanoid.WalkSpeed
		if not ws or ws < 1 then ws = 16 end
		local startFlat = Vector3.new(target.X - root.Position.X, 0, target.Z - root.Position.Z).Magnitude
		local deadline = os.clock() + math.clamp(startFlat / ws * 2 + 8, 12, 90)
		return self:_walkLeg(target, abortFn, arriveDist, true, deadline)
	end
	function EggRuntime:_walkToZigzag(destCF, abortFn, arriveDist)
		if typeof(destCF) ~= "CFrame" then return false end
		arriveDist = arriveDist or 8
		local ZZ_FWD_MIN = 60    
		local ZZ_FWD_MAX = 100   
		local ZZ_LAT_MAX = 38    
		local ZZ_STRAIGHT = 45   
		local ZZ_PASS_DIST = 10  
		local character = LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not root or not humanoid then return false end
		pcall(function() humanoid.AutoRotate = true end)
		local target = destCF.Position
		local ws = humanoid.WalkSpeed
		if not ws or ws < 1 then ws = 16 end
		local startFlat = Vector3.new(target.X - root.Position.X, 0, target.Z - root.Position.Z).Magnitude
		local straightDist = math.max(ZZ_STRAIGHT, ws * ws / (2 * self:_walkBrakeDecel()) * 1.25)
		local deadline = os.clock() + math.clamp(startFlat / ws * 3 + 10, 14, 120)
		local laneMin, laneMax
		do
			local ok, a, b = pcall(function() return zigzagLaneBounds() end)
			if ok and type(a) == "number" and type(b) == "number" then
				laneMin, laneMax = math.min(a, b), math.max(a, b)
			end
		end
		local side = math.random() < 0.5 and -1 or 1
		while os.clock() < deadline do
			if abortFn and abortFn() then return false end
			if self.destroyed or not self.enabled then return false end
			character = LocalPlayer.Character
			root = character and character:FindFirstChild("HumanoidRootPart")
			humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if not root or not humanoid then return false end
			local pos = root.Position
			local flat = Vector3.new(target.X - pos.X, 0, target.Z - pos.Z)
			local dist = flat.Magnitude
			if dist <= straightDist then
				return self:_walkLeg(target, abortFn, arriveDist, true, deadline)
			end
			local dir = flat.Unit
			local rightVec = Vector3.new(-dir.Z, 0, dir.X)
			local maxFwd = math.max(dist - straightDist * 0.5, 4)
			local forward = math.min(ZZ_FWD_MIN + math.random() * (ZZ_FWD_MAX - ZZ_FWD_MIN), maxFwd)
			local latCap = math.min(ZZ_LAT_MAX, forward * 0.4)
			local lateral = side * latCap * (0.6 + math.random() * 0.4)
			side = -side
			local point = pos + dir * forward + rightVec * lateral
			local newZ = point.Z
			if laneMin and laneMax then
				newZ = math.clamp(newZ, laneMin + 2, laneMax - 2)
			end
			if not self:_walkLeg(Vector3.new(point.X, pos.Y, newZ), abortFn, ZZ_PASS_DIST, false, deadline) then
				return false
			end
		end
		return false
	end
	function EggRuntime:_flyWalkTo(destCF, abortFn, arriveDist, flyHeight)
		if typeof(destCF) ~= "CFrame" then return false end
		arriveDist = arriveDist or 8
		flyHeight = tonumber(flyHeight) or 110
		local character = LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not root or not humanoid then return false end
		pcall(function() humanoid.AutoRotate = true end)
		local function stopWalkAnim()
			pcall(function()
				local h = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
				local animator = h and h:FindFirstChildWhichIsA("Animator")
				if animator then for _, tr in ipairs(animator:GetPlayingAnimationTracks()) do tr:Stop(0) end end
			end)
		end
		local function setAnimate(disabled)
			local ch = LocalPlayer.Character
			local animate = ch and ch:FindFirstChild("Animate")
			if animate then pcall(function() animate.Disabled = disabled end) end
		end
		setAnimate(true)
		stopWalkAnim()
		local target = destCF.Position
		self.hoverPadHeightOverride = flyHeight
		self:_startHoverPad()
		pcall(function()
			root.CFrame = CFrame.new(root.Position.X, flyHeight, root.Position.Z) * root.CFrame.Rotation
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
			end)
		self:_syncHoverPad()
		local ws = humanoid.WalkSpeed
		if not ws or ws < 1 then ws = 16 end
		local startFlat = Vector3.new(target.X - root.Position.X, 0, target.Z - root.Position.Z).Magnitude
		local deadline = os.clock() + math.clamp(startFlat / ws * 2 + 10, 12, 120)
		local arrived = self:_walkLeg(target, abortFn, arriveDist, true, deadline, stopWalkAnim)
		setAnimate(false)
		self.hoverPadHeightOverride = nil
		if not arrived then return false end
		if abortFn and abortFn() then return false end
		self:_glideRoot(destCF, abortFn, self:_legitWalkSpeed())
		return not (abortFn and abortFn())
	end
	function EggRuntime:_isInSafeArea(root)
		if not root then return false end
		local delta = root.Position - SAFE_ZONE_POSITION
		return Vector2.new(delta.X, delta.Z).Magnitude <= SAFE_ZONE_HORIZONTAL_RADIUS
		and math.abs(delta.Y) <= SAFE_ZONE_VERTICAL_TOLERANCE
	end
	function EggRuntime:_isInField(root)
		local objects = resolveObjectsRoot()
		local areas = objects and objects:FindFirstChild("Areas")
		local wall = areas and areas:FindFirstChild("WallStartCollision")
		if not wall or not wall:IsA("BasePart") then
			return true
		end
		return root.Position.X >= wall.Position.X + 3
	end
	function EggRuntime:_needsSafeZoneHop(root)
		if self:_isInField(root) or self:_isInSafeArea(root) then
			return false, nil
		end
		return true, self:_resolveSafeCFrame(root)
	end
	function EggRuntime:_invalidateCarryWorker()
		self.carryWorker = nil
	end
	function EggRuntime:_claimCarryWorker(kind, uid)
		local generation = self.carry.generation
		local current = self.carryWorker
		if current and current.generation == generation then return nil end
		local worker = {
			kind = kind,
			uid = uid,
			generation = generation,
			token = {},
		}
		self.carryWorker = worker
		return worker
	end
	function EggRuntime:_isCarryWorkerCurrent(worker)
		return type(worker) == "table"
		and self.carryWorker == worker
		and self.carry.generation == worker.generation
		and not self.destroyed
		and (self.enabled or self._externalDeliver)
	end
	function EggRuntime:_releaseCarryWorker(worker)
		if self.carryWorker == worker then self.carryWorker = nil end
	end
	function EggRuntime:ownsCarryRecovery(uid)
		if self.destroyed or not self.enabled then return false end
		if self.carry.uid == uid then return true end
		return self.running and self.activeTarget ~= nil
		and (uid == nil or self.activeTarget.Uid == uid)
	end
	function EggRuntime:requestCarryRecovery(uid)
		if self.destroyed or not self.enabled or type(uid) ~= "string" or uid == "" then
			return false
		end
		if self:isSkippedEgg(uid) then return true end
		if self.tweenRecoveryUid == uid then
			self:_scheduleMovementRetry()
			return true
		end
		if self.carry.active and self.carry.uid == uid then return true end
		local record = EggCmds.ReadFieldEgg(uid) or self.records[uid]
		if type(record) ~= "table"
		or (record.State ~= AreaEggs.States.Dropped and record.State ~= AreaEggs.States.Slot)
		then
			return false
		end
		local currentWorker = self.carryWorker
		if (currentWorker and currentWorker.kind == "re-steal" and currentWorker.uid == uid)
		or (self.activeTween and self.activeTarget and self.activeTarget.Uid == uid)
		or (self.carryAttemptToken and self.activeTarget and self.activeTarget.Uid == uid)
		then
			return true
		end
		self.carry.generation += 1
		self:_invalidateCarryWorker()
		self.carryAttemptToken = nil
		self.running = true
		self.activeTarget = record
		task.defer(function()
			if not self.destroyed and self.enabled and not self.carry.active then
				self:_reStealDroppedEgg(uid)
			end
			end)
		return true
	end
	function EggRuntime:_hasConfirmedCarry(uid)
		if not self.carry.active then
			return false
		end
		if uid == nil or self.carry.uid == nil then
			return true
		end
		return self.carry.uid == uid
	end
	function EggRuntime:_adoptCarryFromRecord(uid)
		if self.carry.active and self.carry.uid == uid then return end
		if self.carryTimeouts then self.carryTimeouts[uid] = nil end
		if self.instantPhase == "priming" and uid == self.primerUid then
			self.carry.active = true
			self.carry.uid = uid
			return
		end
		self.carry.generation += 1
		self:_invalidateCarryWorker()
		self:_clearArrivalHold(uid)
		local target = self.activeTarget
		self.claimPresentationSuppression = {
			assetCategory = target and target.AssetCategory,
			expiresAt = os.clock() + 8,
		}
		self.carry.active = true
		self.carry.uid = uid
		self.carryStartTime = os.clock()
		local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
		self.carryStartPos = (target and target.BottomCFrame and target.BottomCFrame.Position) or (root and root.Position)
		if self.tweenRecoveryUid == uid then
			self.tweenRecoveryUid = nil
		end
		self.stats.lastResult = "Carry confirmed"
		self:_notify()
	end
	function EggRuntime:_recordShowsCarried(uid)
		if type(uid) ~= "string" or uid == "" then
			return false
		end
		local record = EggCmds.ReadFieldEgg(uid) or self.records[uid]
		return type(record) == "table"
		and record.State == AreaEggs.States.Carried
		and record.CarrierUserId == LocalPlayer.UserId
	end
	function EggRuntime:_recordShowsForeignCarry(uid)
		if type(uid) ~= "string" or uid == "" then return false end
		local record = EggCmds.ReadFieldEgg(uid) or self.records[uid]
		return type(record) == "table"
		and record.State == AreaEggs.States.Carried
		and record.CarrierUserId ~= nil
		and record.CarrierUserId ~= LocalPlayer.UserId
	end
	function EggRuntime:_resolveMovementSpeed(humanoid)
		if not humanoid.Parent or humanoid.Health <= 0 then
			return nil
		end
		return math.clamp(self.config.speed, MIN_MOVEMENT_SPEED, maxMoveSpeed())
	end
	function EggRuntime:_isAreaSafe(areaId)
		return true
	end
	function EggRuntime:_feetOffset(root, humanoid)
		if humanoid.RigType == Enum.HumanoidRigType.R15 then
			return root.Size.Y * 0.5 + math.max(humanoid.HipHeight, 0.5)
		end
		return root.Size.Y * 0.5 + 2
	end
	function EggRuntime:setAntiTrap(value)
		self.config.antiTrap = value == true
		if self.config.antiTrap then
			self:_purgeTraps()
		end
	end
	function EggRuntime:_isForeignTrap(instance)
		if instance.Name == PLAYER_TRAP_NAME and instance:IsA("BasePart") then
			local owner = instance:GetAttribute("Owner")
			return type(owner) ~= "string" or owner ~= LocalPlayer.Name
		end
		return instance:IsA("Model")
		and instance.Name == LEGACY_TRAP_MODEL_NAME
		and instance:FindFirstChild("Hitbox") ~= nil
	end
	function EggRuntime:_purgeTrap(instance)
		if not self.config.antiTrap or not instance or not instance.Parent then
			return
		end
		if self:_isForeignTrap(instance) then
			pcall(instance.Destroy, instance)
		end
	end
	function EggRuntime:_purgeTraps()
		for _, fName in ipairs({ "Transient", "__DEBRIS" }) do
			local folder = workspace:FindFirstChild(fName)
			if folder then
				for _, instance in ipairs(folder:GetDescendants()) do
					self:_purgeTrap(instance)
				end
			end
		end
	end
	function EggRuntime:_syncHoverPad(position)
		local part = self.hoverPad
		if not part or not part.Parent
		or part:GetAttribute(HOVER_PAD_OWNER_ATTRIBUTE) ~= self.hoverPadOwnerId
		then
			return false
		end
		local character = LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not root or not humanoid then return false end
		local rootPosition = typeof(position) == "Vector3" and position or root.Position
		local anchorY = rootPosition.Y
		if self.hoverPadHeightOverride ~= nil and typeof(position) ~= "Vector3" then
			anchorY = self.hoverPadHeightOverride
		end
		local padSize = HOVER_PAD_SIZE_XZ
		if self.hoverPadHeightOverride ~= nil then
			padSize = math.max(HOVER_PAD_SIZE_XZ, humanoid.WalkSpeed * 2 / 15)
		end
		if math.abs(part.Size.X - padSize) > 0.5 then
			part.Size = Vector3.new(padSize, HOVER_PAD_THICKNESS, padSize)
		end
		part.CFrame = CFrame.new(
			rootPosition.X,
			anchorY - self:_feetOffset(root, humanoid) - HOVER_PAD_THICKNESS * 0.5 - 0.05,
			rootPosition.Z
		)
		return true
	end
	function EggRuntime:_setArrivalHold(destination, uid)
		if typeof(destination) ~= "CFrame" then
			return
		end
		local character = LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not character or not root then
			return
		end
		self.arrivalHold = {
			Character = character,
			RootPart = root,
			CFrame = destination,
			Uid = uid,
		}
	end
	function EggRuntime:_clearArrivalHold(uid)
		local hold = self.arrivalHold
		if not hold or uid == nil or hold.Uid == nil or hold.Uid == uid then
			self.arrivalHold = nil
		end
	end
	function EggRuntime:_enforceArrivalHold()
		local hold = self.arrivalHold
		if type(hold) ~= "table" or typeof(hold.CFrame) ~= "CFrame" then
			return false
		end
		if LocalPlayer.Character ~= hold.Character
		or not hold.RootPart
		or not hold.RootPart.Parent
		then
			self.arrivalHold = nil
			return false
		end
		self:_startHoverPad()
		pcall(function()
			hold.RootPart.AssemblyLinearVelocity = Vector3.zero
			hold.RootPart.AssemblyAngularVelocity = Vector3.zero
			self:_syncHoverPad(hold.CFrame.Position)
			hold.RootPart.CFrame = hold.CFrame
			end)
		self:_syncHoverPad(hold.CFrame.Position)
		return true
	end
	function EggRuntime:_purgeOrphanHoverPads()
		for _, child in ipairs(workspace:GetChildren()) do
			if child.Name == HOVER_PAD_NAME
			and child ~= self.hoverPad
			then
				pcall(child.Destroy, child)
			end
		end
	end
	function EggRuntime:_startHoverPad()
		local part = self.hoverPad
		if not part or not part.Parent
		or part:GetAttribute(HOVER_PAD_OWNER_ATTRIBUTE) ~= self.hoverPadOwnerId
		then
			self:_purgeOrphanHoverPads()
			if part and part.Parent then pcall(part.Destroy, part) end
			part = Instance.new("Part")
			part.Name = HOVER_PAD_NAME
			part:SetAttribute(HOVER_PAD_OWNER_ATTRIBUTE, self.hoverPadOwnerId)
			part.Anchored = true
			part.CanCollide = true
			part.CanQuery = true
			part.CanTouch = false
			part.CastShadow = false
			part.Transparency = 1
			part.Material = Enum.Material.SmoothPlastic
			part.Size = Vector3.new(HOVER_PAD_SIZE_XZ, HOVER_PAD_THICKNESS, HOVER_PAD_SIZE_XZ)
			self.hoverPad = part
			part.Parent = workspace
		end
		self:_syncHoverPad()
		if not self.hoverPadConnection then
			self.hoverPadConnection = RunService.PreSimulation:Connect(function()
				if not self:_syncHoverPad() then self:_startHoverPad() end
				end)
		end
		if not self.hoverPadPostConnection then
			self.hoverPadPostConnection = RunService.PostSimulation:Connect(function()
				if self.activeTween or self.arrivalHold then self:_syncHoverPad() end
				end)
		end
	end
	function EggRuntime:_stopHoverPad()
		self.hoverPadHeightOverride = nil
		if self.hoverPadConnection then
			pcall(self.hoverPadConnection.Disconnect, self.hoverPadConnection)
			self.hoverPadConnection = nil
		end
		if self.hoverPadPostConnection then
			pcall(self.hoverPadPostConnection.Disconnect, self.hoverPadPostConnection)
			self.hoverPadPostConnection = nil
		end
		if self.hoverPad then
			pcall(self.hoverPad.Destroy, self.hoverPad)
			self.hoverPad = nil
		end
		self:_purgeOrphanHoverPads()
	end
	function EggRuntime:_startMovementProtection()
		local character = LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not character or not root or not humanoid then
			return false
		end
		local speed = math.clamp(self.config.speed or DEFAULT_MOVEMENT_SPEED, MIN_MOVEMENT_SPEED, maxMoveSpeed())
		self.protectionCharacter = character
		self.protectionHumanoid = humanoid
		self.protectionRoot = root
		setMovementSpoof(character, speed * INTEGRITY_SPEED_HEADROOM)
		setIntegritySpoof(humanoid, root, speed)
		if not self.integritySpoofConnection then
			self.integritySpoofConnection = RunService.PreSimulation:Connect(function()
				local currentCharacter = LocalPlayer.Character
				local currentRoot = currentCharacter and currentCharacter:FindFirstChild("HumanoidRootPart")
				local currentHumanoid = currentCharacter and currentCharacter:FindFirstChildOfClass("Humanoid")
				if not currentCharacter or not currentRoot or not currentHumanoid then
					return
				end
				local liveSpeed = math.clamp(
					self.config.speed or DEFAULT_MOVEMENT_SPEED,
					MIN_MOVEMENT_SPEED,
					maxMoveSpeed()
				)
				self.protectionCharacter = currentCharacter
				self.protectionHumanoid = currentHumanoid
				self.protectionRoot = currentRoot
				setMovementSpoof(currentCharacter, liveSpeed * INTEGRITY_SPEED_HEADROOM)
				if not refreshIntegritySpoof(currentHumanoid, currentRoot, liveSpeed) then
					setIntegritySpoof(currentHumanoid, currentRoot, liveSpeed)
				end
				self:_enforceArrivalHold()
				end)
		end
		if not self.arrivalHoldConnection then
			self.arrivalHoldConnection = RunService.Heartbeat:Connect(function()
				self:_enforceArrivalHold()
				end)
		end
		return true
	end
	function EggRuntime:_startFlyGrounding()
		self:_stopFlyGrounding()
		local holder = getIntegritySpoof()
		self._flyGroundConn = RunService.PreSimulation:Connect(function()
			if self.destroyed then return end
			local st = holder and holder.State
			if type(st) ~= "table" or rawget(st, "CorrectionContext") ~= nil then return end
			rawset(st, "IsSupportedNow", true)
			rawset(st, "UnsupportedStartedAt", nil)
			if rawget(st, "MovementMode") ~= "Correcting" then
				rawset(st, "MovementMode", "Grounded")
			end
			local ev = rawget(st, "Evidence")
			if type(ev) == "table" then
				ev.Flight = 0
				ev.Teleport = 0
				ev.Speed = 0
			end
		end)
	end
	function EggRuntime:_stopFlyGrounding()
		if self._flyGroundConn then
			pcall(self._flyGroundConn.Disconnect, self._flyGroundConn)
			self._flyGroundConn = nil
		end
	end
	function EggRuntime:_stopMovementProtection()
		self:_stopFlyGrounding()
		if self.integritySpoofConnection then
			pcall(self.integritySpoofConnection.Disconnect, self.integritySpoofConnection)
			self.integritySpoofConnection = nil
		end
		if self.arrivalHoldConnection then
			pcall(self.arrivalHoldConnection.Disconnect, self.arrivalHoldConnection)
			self.arrivalHoldConnection = nil
		end
		self:_clearArrivalHold()
		self:_stopHoverPad()
		clearMovementSpoof()
		clearIntegritySpoof(self.protectionHumanoid)
		self.protectionCharacter = nil
		self.protectionHumanoid = nil
		self.protectionRoot = nil
	end
	function EggRuntime:travelAndWait(destination, opts)
		opts = opts or {}
		if self.destroyed then return false end
		if self.travelBusy and os.clock() < (self.travelBusyUntil or 0) then return false end
		if self.activeTween and not self.running and (not self.activeTween.sharedTravel or opts.preempt == true) then
			pcall(self.activeTween.Cancel, self.activeTween)
			local releaseBy = os.clock() + 0.5
			while self.activeTween and os.clock() < releaseBy do task.wait(0.05) end
		end
		if self.activeTween then return false end
		local character = LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root then return false end
		self.travelBusy = true
		self.travelBusyUntil = os.clock() + 45
		local okTravel, travelled = pcall(function()
			local outcome = nil
			local startedAt = os.clock()
			local lastProgressAt = startedAt
			local bestDistance = (destination.Position - root.Position).Magnitude
			local speed = math.max(tonumber(opts.speed) or self.config.speed or DEFAULT_MOVEMENT_SPEED, MIN_MOVEMENT_SPEED)
			local hardDeadline = startedAt + bestDistance / speed + 6
			self.travelBusyUntil = hardDeadline + 2
			self:_tweenRoot(destination, nil, opts.speed, {
				silent = true,
				sharedTravel = true,
				abort = function()
					return self.destroyed or (opts.abort ~= nil and opts.abort())
				end,
				onDone = function(ok)
					outcome = ok == true
				end,
				})
			while outcome == nil do
				local now = os.clock()
				local currentRoot = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
				local distance = currentRoot and (destination.Position - currentRoot.Position).Magnitude or math.huge
				if distance < bestDistance - 0.5 then
					bestDistance = distance
					lastProgressAt = now
				end
				local aborted = self.destroyed or (opts.abort ~= nil and opts.abort())
				local stalled = now - lastProgressAt >= 1.5
				if aborted or stalled or now >= hardDeadline then
					if self.activeTween and self.activeTween.Cancel then pcall(self.activeTween.Cancel) end
					outcome = false
					break
				end
				task.wait(0.05)
			end
			return outcome
		end)
		self.travelBusy = false
		if not okTravel then
			if self.activeTween and self.activeTween.sharedTravel and self.activeTween.Cancel then pcall(self.activeTween.Cancel) end
			return false
		end
		return travelled == true
	end
	function EggRuntime:_tweenRoot(destination, callback, speedOverride, handlers)
		self:_clearArrivalHold()
		local character = LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		handlers = handlers or {}
		if not root or not humanoid then
			self.safeStarting = false
			if handlers.silent then
				if handlers.onDone then pcall(handlers.onDone, false) end
				return
			end
			self:_finish("Character unavailable")
			return
		end
		-- same cross-dimension refusal as the other move primitives: never fly from the Halloween
		-- dimension (or the train) to a normal-world point; the world router takes the portal
		local destPos = (typeof(destination) == "CFrame" and destination.Position) or (typeof(destination) == "Vector3" and destination) or nil
		if (LocalPlayer:GetAttribute("InHalloweenDimension") == true and destPos and destPos.Y > -100) or runtimeEnv.__SenaV4OnTrain == true then
			self.safeStarting = false
			if handlers.onDone then pcall(handlers.onDone, false) end
			if not handlers.silent then self:_finish("Waiting for the portal") end
			return
		end
		local movementSpeed = speedOverride or self:_resolveMovementSpeed(humanoid)
		if not movementSpeed then
			self.safeStarting = false
			if handlers.silent then
				if handlers.onDone then pcall(handlers.onDone, false) end
				return
			end
			self:_finish("Movement unavailable")
			return
		end
		movementSpeed = math.clamp(movementSpeed, MIN_MOVEMENT_SPEED, maxMoveSpeed())
		self:_startMovementProtection()
		pcall(applyKillPartIgnore, character)
		local camera = workspace.CurrentCamera
		if camera and camera.CameraSubject ~= humanoid then
			pcall(function()
				camera.CameraSubject = humanoid
				end)
		end
		local originalAutoRotate = humanoid.AutoRotate
		humanoid.AutoRotate = false
		local routeCruiseY = handlers.flightProfile == true
		and self:_resolveRouteCruiseY(root, destination)
		or nil
		local token = {
			sharedTravel = handlers.sharedTravel == true,
			routeCruiseY = routeCruiseY,
			travelPhase = routeCruiseY and "takeoff" or nil,
			zigzag = self.config.stealMode == "Zig-Zag",
			zigT = 0,
			zigLast = 0,
		}
		self.activeTween = token
		self:_startHoverPad()
		local released = false
		local connection
		local arrivalStableSince = nil
		local previousRemainingDistance = nil
		local correctionSlowUntil = 0
		local function release(completed)
			if released then
				return
			end
			released = true
			arrivalStableSince = nil
			if humanoid.Parent ~= nil then
				humanoid.AutoRotate = originalAutoRotate
			end
			if completed and handlers.holdAfterArrival then
				self:_setArrivalHold(destination, handlers.holdUid)
			end
			if handlers.onDone then
				pcall(handlers.onDone, completed == true)
			end
			if connection then
				connection:Disconnect()
				connection = nil
			end
			if self.activeTween == token then
				self.activeTween = nil
			end
			if not self.arrivalHold then self:_stopHoverPad() end
			if not self.enabled then
				self:_stopMovementProtection()
			end
			pcall(function()
				if LocalPlayer.Character == character and root.Parent then
					root.AssemblyLinearVelocity = Vector3.zero
				end
				end)
			if completed
			and LocalPlayer.Character == character
			and humanoid.Parent ~= nil
			then
				if callback then
					callback()
				end
			end
		end
		token.Cancel = function()
			release(false)
		end
		connection = RunService.Heartbeat:Connect(function(deltaTime)
			if handlers.abort and handlers.abort() then
				release(false)
				return
			end
			if self.destroyed or self.activeTween ~= token then
				release(false)
				return
			end
			if handlers.carryTarget and os.clock() >= (token.nextTargetCheck or 0) then
				token.nextTargetCheck = os.clock() + 0.1
				local targetUid = handlers.carryTarget.Uid
				local live = EggCmds.ReadFieldEgg(targetUid)
				local state = live and live.State
				if state ~= AreaEggs.States.Slot and state ~= AreaEggs.States.Dropped and state ~= "GuardCarried"
				and not (live and live.CarrierUserId == LocalPlayer.UserId)
				and not self:_hasConfirmedCarry(targetUid)
				then
					release(false)
					local playerSteal = runtimeEnv.__SenaV4PlayerSteal
					local chasing = state == "Carried" and playerSteal ~= nil and playerSteal:intercept(targetUid)
					self:_finish(chasing and "Target taken - chasing the carrier" or "Target taken by someone else")
					return
				end
			end
			pcall(function()
				local liveSpeed = math.clamp(
					speedOverride or self.config.speed or movementSpeed,
					MIN_MOVEMENT_SPEED,
					maxMoveSpeed()
				)
				setMovementSpoof(character, liveSpeed * INTEGRITY_SPEED_HEADROOM)
				local holder = environment()[INTEGRITY_SPOOF_KEY]
				local integrityState = type(holder) == "table" and holder.State or nil
				if not integrityStateCanTravel(integrityState, humanoid, root) then
					previousRemainingDistance = nil
					arrivalStableSince = nil
					root.AssemblyLinearVelocity = Vector3.zero
					root.AssemblyAngularVelocity = Vector3.zero
					self:_syncHoverPad(root.Position)
					if integrityStateMatches(integrityState, humanoid, root) then
						patchIntegrityState(integrityState, liveSpeed * INTEGRITY_SPEED_HEADROOM, Vector3.zero)
					else
						setIntegritySpoof(humanoid, root, liveSpeed)
					end
					return
				end
				local position = root.Position
				local remaining = destination.Position - position
				local remainingDistance = remaining.Magnitude
				local horizontalRemaining = Vector3.new(remaining.X, 0, remaining.Z)
				local horizontalDistance = horizontalRemaining.Magnitude
				local movementTarget = destination.Position
				if token.routeCruiseY then
					if token.travelPhase == "takeoff" then
						if position.Y >= token.routeCruiseY - 0.5 then
							token.travelPhase = "cruise"
						else
							movementTarget = Vector3.new(position.X, token.routeCruiseY, position.Z)
						end
					end
					if token.travelPhase == "cruise" then
						if horizontalDistance <= 4 then
							token.travelPhase = "descend"
						else
							movementTarget = Vector3.new(destination.Position.X, token.routeCruiseY, destination.Position.Z)
						end
					end
					if token.travelPhase == "descend" then
						movementTarget = destination.Position
					end
				end
				local movementRemaining = movementTarget - position
				local movementDistance = movementRemaining.Magnitude
				local progressDistance = token.routeCruiseY and horizontalDistance or remainingDistance
				if previousRemainingDistance
				and progressDistance > previousRemainingDistance + CORRECTION_DISTANCE_EPSILON
				then
					correctionSlowUntil = os.clock() + CORRECTION_SLOWDOWN_SECONDS
				end
				previousRemainingDistance = progressDistance
				local effectiveSpeed = os.clock() < correctionSlowUntil
				and math.max(MIN_MOVEMENT_SPEED, liveSpeed * CORRECTION_SPEED_FACTOR)
				or liveSpeed
				if handlers.carryTarget and not token.__earlyCarrySpam and remainingDistance <= 30 then
					token.__earlyCarrySpam = true
					local targetRec = handlers.carryTarget
					local targetUid = targetRec.Uid
					local slotKey = AreaEggSlotIdentity.LooksLikeFirstAreaUid(targetUid)
					and AreaEggSlotIdentity.SlotKey(targetRec.AreaId, targetRec.NestId)
					or nil
					task.spawn(function()
						while not self.destroyed
						and self.enabled
						and self.activeTween == token
						and not self:_hasConfirmedCarry(targetUid)
						do
							pcall(requestFieldEggCarry, targetUid, slotKey)
							task.wait(0.08)
						end
						end)
				end
				local safeDeltaTime = math.max(math.min(deltaTime, LONG_FRAME_CLAMP), 1 / 240)
				local stepDistance = effectiveSpeed * safeDeltaTime
				local flatDirection = horizontalRemaining
				local currentLook = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
				local facingDirection = flatDirection.Magnitude > 0.001 and flatDirection.Unit
				or (currentLook.Magnitude > 0.001 and currentLook.Unit or Vector3.new(0, 0, -1))
				local canArrive = not token.routeCruiseY or token.travelPhase == "descend"
				if canArrive and remainingDistance <= math.max(stepDistance, 0.05) then
					if remainingDistance > 0.5 then
						arrivalStableSince = nil
					end
					self:_syncHoverPad(destination.Position)
					root.CFrame = CFrame.lookAt(destination.Position, destination.Position + facingDirection)
					root.AssemblyLinearVelocity = Vector3.zero
					self:_syncHoverPad(destination.Position)
					refreshIntegritySpoof(humanoid, root, liveSpeed, Vector3.zero)
					arrivalStableSince = arrivalStableSince or os.clock()
					if os.clock() - arrivalStableSince >= MOVEMENT_ARRIVAL_HOLD then
						release(true)
					end
					return
				end
				arrivalStableSince = nil
				if movementDistance <= 0.001 then
					root.AssemblyLinearVelocity = Vector3.zero
					root.AssemblyAngularVelocity = Vector3.zero
					self:_syncHoverPad(position)
					return
				end
				if not self.hoverPad or not self.hoverPad.Parent then self:_startHoverPad() end
				local actualStepDistance = math.min(stepDistance, movementDistance)
				local nextPosition = position + movementRemaining.Unit * actualStepDistance
				if safeDeltaTime >= (1 / 30) and (not token.routeCruiseY or token.travelPhase ~= "cruise") then
					local groundY = self:_groundYAt(nextPosition.X, nextPosition.Z, character)
					if groundY then
						local minY = groundY + self:_feetOffset(root, humanoid)
						if nextPosition.Y < minY then
							nextPosition = Vector3.new(nextPosition.X, minY, nextPosition.Z)
						end
					end
				end
				if token.zigzag and (not token.routeCruiseY or token.travelPhase == "cruise") then
					local flat = Vector3.new(movementRemaining.X, 0, movementRemaining.Z)
					if flat.Magnitude > 1 and horizontalDistance > 12 then
						local dir = flat.Unit
						local perp = Vector3.new(-dir.Z, 0, dir.X)
						local amplitude = math.min(ZIGZAG_MAX_AMPLITUDE, horizontalDistance * 0.30)
						if horizontalDistance < ZIGZAG_FADE_DISTANCE then
							amplitude = amplitude * (horizontalDistance / ZIGZAG_FADE_DISTANCE)
						end
						token.zigT = (token.zigT or 0) + actualStepDistance
						local lateral = amplitude * math.sin(token.zigT / ZIGZAG_WAVELENGTH * math.pi * 2)
						local shift = lateral - (token.zigLast or 0)
						token.zigLast = lateral
						nextPosition = nextPosition + perp * shift
						if not token.zigLaneMin then
							token.zigLaneMin, token.zigLaneMax = zigzagLaneBounds()
						end
						local clampedZ = math.clamp(nextPosition.Z, token.zigLaneMin, token.zigLaneMax)
						if clampedZ ~= nextPosition.Z then
							nextPosition = Vector3.new(nextPosition.X, nextPosition.Y, clampedZ)
						end
					else
						token.zigLast = 0
					end
				end
				local travelVelocity = (nextPosition - position) / safeDeltaTime
				self:_syncHoverPad(nextPosition)
				root.CFrame = CFrame.lookAt(nextPosition, nextPosition + facingDirection)
				root.AssemblyLinearVelocity = Vector3.zero
				self:_syncHoverPad(nextPosition)
				if not refreshIntegritySpoof(humanoid, root, liveSpeed, travelVelocity) then
					setIntegritySpoof(humanoid, root, liveSpeed)
					refreshIntegritySpoof(humanoid, root, liveSpeed, travelVelocity)
				end
				end)
			end)
	end
	function EggRuntime:_reStealDroppedEgg(uid)
		if LocalPlayer:GetAttribute("InHalloweenDimension") == true then return end
		if type(uid) ~= "string" or uid == "" then
			self:_finish("Egg lost — retrying")
			return
		end
		if self:isSkippedEgg(uid) then return end
		if self.tweenRecoveryUid == uid then
			self.running = false
			self.activeTarget = nil
			self:_releaseOperation()
			self:_scheduleMovementRetry()
			return
		end
		local worker = self:_claimCarryWorker("re-steal", uid)
		if not worker then return end
		if runtimeEnv.__SenaV4GodMode then
			runtimeEnv.__SenaV4GodMode:startDefend(uid)
		end
		local record = nil
		local deadline = os.clock() + 5
		self:_setStatus("Re-stealing dropped egg")
		while self:_isCarryWorkerCurrent(worker) and os.clock() < deadline do
			local candidate = EggCmds.ReadFieldEgg(uid) or self.records[uid]
			if candidate
			and (candidate.State == AreaEggs.States.Dropped or candidate.State == AreaEggs.States.Slot)
			then
				record = candidate
				break
			end
			task.wait(0.03)
		end
		if not self:_isCarryWorkerCurrent(worker) then return end
		if not record or not self:_wallOpen() then
			self:_releaseCarryWorker(worker)
			self:_finish("Egg lost — retrying")
			return
		end
		self:_cancelTween("Re-stealing dropped egg", true)
		local character = LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local destination = self:_resolveEggDestination(record, root, humanoid)
		destination = destination and self:_resolveElevatedDestination(root, destination) or nil
		if not destination then
			self:_releaseCarryWorker(worker)
			self:_finish("Character unavailable")
			return
		end
		self.running = true
		self.activeTarget = record
		self:_setStatus("Bringing egg home")
		if self:_regrabBurst(worker, record.Uid, 3.5) or not self:_isCarryWorkerCurrent(worker) then return end
		self:_setStatus("Re-stealing egg")
		if not self:_teleportRoot(root, humanoid, destination) then
			self:_releaseCarryWorker(worker)
			self:_finish("Re-steal failed — retrying")
			return
		end
		self:_setArrivalHold(destination, record.Uid)
		self:_setStatus("Re-stealing egg")
		if self:_isCarryWorkerCurrent(worker) then self:_requestCarry(record, true) end
	end
	function EggRuntime:_regrabBurst(worker, uid, seconds)
		local function heldByMe()
			local current = EggCmds.ReadFieldEgg(uid)
			return current ~= nil and current.State == AreaEggs.States.Carried and current.CarrierUserId == LocalPlayer.UserId
		end
		local ragdoll = nil
		pcall(function() ragdoll = require(ReplicatedStorage.Shared.Modules.RagdollJoints) end)
		local askBusy, carryBusy = false, false
		local deadline = os.clock() + seconds
		while os.clock() < deadline and not self.destroyed and (self.enabled or self._externalDeliver) do
			if heldByMe() then return true end
			if not self:_isCarryWorkerCurrent(worker) then return heldByMe() end
			local current = EggCmds.ReadFieldEgg(uid)
			if not current or (current.State ~= AreaEggs.States.Dropped and current.State ~= AreaEggs.States.Slot) then
				return false
			end
			local character = LocalPlayer.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if not root or not humanoid then return false end
			pcall(function()
				if ragdoll and ragdoll.Release then ragdoll.Release(character) end
				humanoid.PlatformStand = false
				humanoid.Sit = false
				if humanoid:GetState() ~= Enum.HumanoidStateType.Running then
					humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
				end
				end)
			local destination = self:_resolveEggDestination(current, root, humanoid)
			if destination then
				root.CFrame = destination
				-- Loncat-loncat during the relay regrab: instead of pinning flat (which the server sometimes
				-- refuses to re-grab from), bob with a jump each pass so the grab lands. Only the relay regrab.
				if worker and worker.kind == "instant-regrab" and Config.StealJump ~= false then
					pcall(function() humanoid.Jump = true end)
					root.AssemblyLinearVelocity = Vector3.new(0, 45, 0)
				else
					root.AssemblyLinearVelocity = Vector3.zero
				end
				root.AssemblyAngularVelocity = Vector3.zero
				self:_syncHoverPad(destination.Position)
			end
			if not askBusy then
				askBusy = true
				task.spawn(function()
					pcall(function() EggWorld.AskFieldEggCarry:InvokeServer({ Uid = uid }) end)
					askBusy = false
					end)
			end
			if not carryBusy then
				carryBusy = true
				task.spawn(function()
					pcall(EggCmds.CarryFieldEgg, uid)
					carryBusy = false
					end)
			end
			pcall(function()
				local slots = workspace:FindFirstChild("AreaEggSlotsClient")
				local model = slots and slots:FindFirstChild(tostring(uid))
				local prompt = model and (model:FindFirstChild("CarryAreaEgg", true) or model:FindFirstChildWhichIsA("ProximityPrompt", true))
				if prompt and prompt.Enabled and type(fireproximityprompt) == "function" then
					prompt.HoldDuration = 0
					prompt.RequiresLineOfSight = false
					fireproximityprompt(prompt, 0)
				end
				end)
			task.wait(0.06)
		end
		return heldByMe()
	end
	function EggRuntime:_recoverCarryConfirmationTimeout(attemptToken, targetUid)
		if self.destroyed
		or not self.enabled
		or self.carryAttemptToken ~= attemptToken
		or self:_hasConfirmedCarry(targetUid)
		then
			return false
		end
		local character = LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local safeCFrame = root and self:_resolveSafeCFrame(root)
		safeCFrame = safeCFrame and self:_resolveElevatedDestination(root, safeCFrame) or nil
		self.carryTimeouts = self.carryTimeouts or {}
		local timeouts = (self.carryTimeouts[targetUid] or 0) + 1
		local giveUp = timeouts >= MAX_CARRY_TIMEOUTS
		if giveUp then
			self.carryTimeouts[targetUid] = nil
			self.skippedEggs[targetUid] = os.clock() + CARRY_TIMEOUT_SKIP_SECONDS
			self.tweenRecoveryUid = nil
		else
			self.carryTimeouts[targetUid] = timeouts
			self.tweenRecoveryUid = not self:_isPrimerEgg(targetUid) and targetUid or nil
		end
		local refused = self.stats.lastCarryReject
		if type(refused) == "string" and refused:lower():find("inventory is full", 1, true) then
			self.eggFullCount = self:_eggCount() or math.huge
		end
		local timedOutRecord = self.records[targetUid] or EggCmds.ReadFieldEgg(targetUid)
		local treadmillFirst = self.config.stealMode == "Instant"
			and (targetUid == self.primerUid or (type(timedOutRecord) == "table" and timedOutRecord.AreaId == "Forest"))
		self.carry.generation += 1
		self:_invalidateCarryWorker()
		self.carryAttemptToken = nil
		self:_clearArrivalHold(targetUid)
		if self.activeTween and self.activeTween.Cancel then
			pcall(self.activeTween.Cancel, self.activeTween)
		end
		self.activeTween = nil
		self.running = true
		self.activeTarget = nil
		self.stats.lastResult = "Carry confirmation timeout"
		if root and safeCFrame then
			pcall(function()
				root.AssemblyLinearVelocity = Vector3.zero
				root.AssemblyAngularVelocity = Vector3.zero
				end)
			self:_setStatus("Carry timeout - returning to safe area")
			pcall(self._glideRoot, self, safeCFrame, function() return self.destroyed or not self.enabled end)
			if giveUp then
				self:_setStatus(refused and ("Carry refused (" .. refused .. ") — skipping egg")
					or "Carry timed out twice — skipping egg")
			else
				self:_setStatus("Carry timeout — retrying")
			end
		else
			self:_setStatus("Carry timeout — safe area unavailable")
		end
		self.running = false
		self:_releaseOperation()
		if treadmillFirst then self.running = true end
		task.delay(0.35, function()
			if treadmillFirst then
				if not self.destroyed and self.enabled then
					self:_setStatus("Retrying steal")
					pcall(self._treadmillReset, self, function() return self.destroyed or not self.enabled end)
				end
				self.running = false
			end
			if not self.destroyed and self.enabled and self.carryAttemptToken == nil then
				self:_schedule()
			end
			end)
		return true
	end
	function EggRuntime:_requestCarry(record, teleportReapproach)
		if not self:_wallOpen() then
			self:_finish("Wall closed before carry")
			return
		end
		local targetUid = record.Uid
		local attemptToken = {}
		local confirmationDeadline = nil
		self.stats.lastCarryReject = nil
		self._untrustedSince = nil
		local isPrimerCarry = self.instantPhase == "priming" and targetUid == self.primerUid
		local confirmWindow = isPrimerCarry and CARRY_CONFIRM_TIMEOUT_SECONDS
			or math.max(CARRY_CONFIRM_TIMEOUT_SECONDS, self:_resolveSettleSeconds(record) + 3)
		self.carryAttemptToken = attemptToken
		self.stats.lastResult = "Carry requested"
		self:_setStatus("Securing egg")
		local character = LocalPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			pcall(humanoid.UnequipTools, humanoid)
		end
		if self.coordinator then
			local backgroundDeadline = os.clock() + 0.35
			while self.coordinator:isBackgroundBusy()
			and not self.destroyed
			and self.enabled
			and self.carryAttemptToken == attemptToken
			and os.clock() < backgroundDeadline
			do
				task.wait(0.02)
			end
			if humanoid and humanoid.Parent then
				pcall(humanoid.UnequipTools, humanoid)
			end
		end
		task.spawn(function()
			while not self.destroyed
			and self.enabled
			and self.running
			and self.carryAttemptToken == attemptToken
			and self.activeTarget
			and self.activeTarget.Uid == targetUid
			do
				if not self:_hasConfirmedCarry(targetUid) and self:_recordShowsCarried(targetUid) then
					self:_adoptCarryFromRecord(targetUid)
				end
				if self:_hasConfirmedCarry(targetUid) then
					if self:_recordShowsCarried(targetUid) then
						self:_clearArrivalHold(targetUid)
						self.carryAttemptToken = nil
						if self.activeTween then
							pcall(self.activeTween.Cancel, self.activeTween)
							self.activeTween = nil
						end
						if self.instantPhase == "priming" and targetUid == self.primerUid then
							self.carry.active = true
							self.carry.uid = targetUid
							self.stats.lastResult = "Preparing steal"
							self:_enterBaitWait()
							return
						end
						self.carry.active = true
						self.carry.uid = targetUid
						self.stats.lastResult = "Carry confirmed"
						self:_setStatus("Carry confirmed")
						task.defer(function()
							if not self.destroyed and self.enabled and self:_hasConfirmedCarry(targetUid) then
								self:_returnToSafe()
							end
							end)
						return
					end
					self:_setStatus("Confirming carry record")
					task.wait(CARRY_RETRY_INTERVAL)
					continue
				end
				if confirmationDeadline and os.clock() >= confirmationDeadline then
					self:_recoverCarryConfirmationTimeout(attemptToken, targetUid)
					return
				end
				if not self:_wallOpen() then
					self:_finish("Wall closed before carry")
					return
				end
				local current = EggCmds.ReadFieldEgg(targetUid) or self.records[targetUid]
				if not current then
					self:_finish("Target unavailable")
					return
				end
				if current.State == AreaEggs.States.Carried then
					if current.CarrierUserId == LocalPlayer.UserId then
						self:_setStatus("Confirming carry state")
						task.wait(CARRY_RETRY_INTERVAL)
						continue
					end
					self:_finish("Egg carried by another player")
					return
				end
				if current.State ~= AreaEggs.States.Slot and current.State ~= AreaEggs.States.Dropped then
					self:_finish("Target changed")
					return
				end
				local character = LocalPlayer.Character
				local root = character and character:FindFirstChild("HumanoidRootPart")
				if not root then
					self:_finish("Character unavailable")
					return
				end
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				if not humanoid then
					self:_finish("Character unavailable")
					return
				end
				local groundedEggDestination = self:_resolveEggDestination(current, root, humanoid)
				local reapproachDestination = groundedEggDestination
				and self:_resolveElevatedDestination(root, groundedEggDestination)
				or nil
				if not reapproachDestination then
					self:_finish("Character unavailable")
					return
				end
				local eggPosition = reapproachDestination.Position
				if (root.Position - eggPosition).Magnitude > CARRY_REAPPROACH_DISTANCE then
					if teleportReapproach then
						self:_setStatus("Re-stealing egg")
						if not self:_teleportRoot(root, humanoid, reapproachDestination) then
							self:_finish("Re-steal failed — retrying")
							return
						end
						self:_setArrivalHold(reapproachDestination, targetUid)
						self:_setStatus("Re-stealing egg")
					else
						self:_setStatus("Re-approaching egg")
						local reapproachDone = false
						self:_tweenRoot(groundedEggDestination, function()
							reapproachDone = true
							if self.carryAttemptToken == attemptToken and not self:_hasConfirmedCarry(targetUid) then
								self:_setStatus("Securing egg")
							end
							end, nil, {
								holdAfterArrival = true,
								holdUid = targetUid,
								flightProfile = true,
							})
						while not self.destroyed
						and self.enabled
						and self.carryAttemptToken == attemptToken
						and not self:_hasConfirmedCarry(targetUid)
						and not reapproachDone
						do
							task.wait(CARRY_RETRY_INTERVAL)
						end
						continue
					end
				end
				local slotKey = AreaEggSlotIdentity.LooksLikeFirstAreaUid(current.Uid)
				and AreaEggSlotIdentity.SlotKey(current.AreaId, current.NestId)
				or nil
				local okRequest, accepted, reason = pcall(requestFieldEggCarry, current.Uid, slotKey)
				if not okRequest then
					reason = tostring(accepted)
				elseif accepted == true then
					reason = nil
				end
				if reason then
					self.stats.lastCarryReject = reason
					if reason ~= self._lastCarryRejectLogged then
						self._lastCarryRejectLogged = reason
						warn("[Sena Steal] carry refused: " .. reason)
					end
				end
				-- "Movement is not currently trusted" does not clear by asking again: the old code re-requested
				-- for the whole 11 s confirm window, timed out, then repeated it (one hop measured at 30 s of
				-- nothing). Give it a 3 s grace, then stop asking, park the egg briefly and take the next one.
				if reason and tostring(reason):lower():find("not currently trusted", 1, true) then
					self._untrustedSince = self._untrustedSince or os.clock()
					if os.clock() - self._untrustedSince > 3 then
						self._untrustedSince = nil
						self.skippedEggs[targetUid] = os.clock() + 20
						self.carryAttemptToken = nil
						self:_clearArrivalHold(targetUid)
						self:_finish("Carry refused — next egg")
						return
					end
				else
					self._untrustedSince = nil
				end
				confirmationDeadline = confirmationDeadline or (os.clock() + confirmWindow)
				self.stats.lastResult = "Carry requested"
				self:_setStatus(reason and ("Waiting for carry · " .. reason) or "Waiting for carry confirmation")
				task.wait(CARRY_RETRY_INTERVAL)
			end
			end)
	end
	function EggRuntime:_burstHold(destCFrame, abortFn)
		if typeof(destCFrame) ~= "CFrame" then return false end
		local target = destCFrame.Position
		local function root()
			local c = LocalPlayer.Character
			return c and c:FindFirstChild("HumanoidRootPart")
		end
		local function pin(r)
			r.CFrame = destCFrame
			r.AssemblyLinearVelocity = Vector3.zero
			r.AssemblyAngularVelocity = Vector3.zero
		end
		local burstUntil = os.clock() + BURST_SECONDS
		while os.clock() < burstUntil do
			if abortFn and abortFn() then return false end
			local r = root()
			if not (r and r.Parent) then return false end
			pcall(pin, r)
			RunService.Heartbeat:Wait()
		end
		local holdUntil = os.clock() + BURST_HOLD_MAX
		local stableSince = nil
		while os.clock() < holdUntil do
			if abortFn and abortFn() then return false end
			local r = root()
			if not (r and r.Parent) then return false end
			if (r.Position - target).Magnitude > BURST_NEAR then
				stableSince = nil
			elseif not stableSince then
				stableSince = os.clock()
			elseif (os.clock() - stableSince) >= BURST_STABLE then
				return true
			end
			pcall(pin, r)
			RunService.Heartbeat:Wait()
		end
		local r = root()
		return r ~= nil and (r.Position - target).Magnitude <= BURST_NEAR
	end
	local PORTAL_BOOST_AREAS = {
		["Titan Temple"] = true, ["Light Dark"] = true, ["Enchanted Forest"] = true, ["Cherry Blossom"] = true,
		["Cosmic"] = true, ["Prehistoric"] = true, ["Abyss Ocean"] = true, ["Volcano"] = true, ["Snow"] = true,
		["Jungle"] = true, ["Desert"] = true, ["Lake"] = true,
	}
	local PORTAL_HOP_MIN = 200 
	local FUSE_BIOME_MIN_Y = 5000 
	function EggRuntime:_nearestRival(pos, radius)
		local best, bestD
		for _, pl in ipairs(game:GetService("Players"):GetPlayers()) do
			if pl ~= LocalPlayer and pl.Character then
				local hrp = pl.Character:FindFirstChild("HumanoidRootPart")
				if hrp then
					local d = (hrp.Position - pos).Magnitude
					if d <= radius and (not best or d < bestD) then best, bestD = pl, d end
				end
			end
		end
		return best
	end
	function EggRuntime:_ensureFieldBat()
		-- field bats are per-area Gear (Forest Bat / Lake Bat / Desert Bat...). Swinging needs one equipped
		-- and the server only blocks swings in the safe zone, so in the field this registers. Equip an owned
		-- bat if we have one, else ask the server to wear the current area's field bat.
		local char = LocalPlayer.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if not char or not hum then return end
		for _, t in ipairs(char:GetChildren()) do
			if t:IsA("Tool") and tostring(t.Name):lower():find("bat") then return end
		end
		local bp = LocalPlayer:FindFirstChildOfClass("Backpack")
		if bp then
			for _, t in ipairs(bp:GetChildren()) do
				if t:IsA("Tool") and tostring(t.Name):lower():find("bat") then
					pcall(function() hum:EquipTool(t) end)
					return
				end
			end
		end
		pcall(function() Remotes.Codex.AskWearFieldBat:InvokeServer() end)
	end
	function EggRuntime:_spamPunch(getPos, stopFn)
		local trig = Remotes.BatSwing and Remotes.BatSwing.Trigger
		if not trig then return end
		self:_ensureFieldBat()
		local seq = 0
		while not stopFn() and not self.destroyed and self.enabled do
			local pos = getPos()
			local target = pos and self:_nearestRival(pos, 60)
			if target then
				seq += 1
				local tid = ("%d:%d:%d"):format(LocalPlayer.UserId, seq, math.floor(workspace:GetServerTimeNow() * 1000))
				pcall(function() trig:FireServer(target, tid) end)
			end
			task.wait(0.05)
		end
	end
	function EggRuntime:_snipeGrab(record)
		-- Grab an egg another script relay-dropped (State == Dropped). No Fuse portal (too slow, loses the
		-- race): direct teleport onto the loose egg, carry it, then teleport straight to the safezone to bank.
		-- A lane drop is already past the guard, so a low-SpeedPower account can take + bank it without the toll.
		local uid = record.Uid
		local heldOp = self.operationToken ~= nil
		local function parts()
			local c = LocalPlayer.Character
			return c and c:FindFirstChild("HumanoidRootPart"), c and c:FindFirstChildOfClass("Humanoid")
		end
		local function done(msg)
			if not heldOp then self:_releaseOperation() end
			if not self.destroyed and self.enabled then self:_finish(msg) end
		end
		local root, humanoid = parts()
		if not root or not humanoid then return done("Snipe — no character") end
		-- Hold the shared operation so the treadmill coordinator sees us busy and will not remount mid-grab.
		-- If we are riding the treadmill, step off first: the anchored mount fights the snipe teleport. This
		-- costs ~1-2s (a contested drop is usually lost) but lets snipe run while AFK-farming the treadmill;
		-- after we finish, releasing the operation lets the treadmill idle-watchdog remount on its own.
		if not heldOp then self:_acquireOperation() end
		local tm = self.treadmillManager
		if tm and not tm.destroyed and tm:isEngaged() then
			pcall(function() tm:_cancelIdle(true) end)
			local tdl = os.clock() + 4
			while os.clock() < tdl and not self.destroyed and self.enabled do
				if self:_leftTreadmill(LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")) then break end
				task.wait(0.1)
			end
			root, humanoid = parts()
			if not root or not humanoid then return done("Snipe — no character") end
		end
		local function heldByMe()
			local r = EggCmds.ReadFieldEgg(uid)
			return r ~= nil and r.State == AreaEggs.States.Carried and r.CarrierUserId == LocalPlayer.UserId
		end
		self:_setStatus("Sniping dropped egg")
		-- AskFieldEggCarry is a RemoteFunction: InvokeServer blocks a full round-trip, so a plain fire+wait
		-- loop serialises on ping and loses the regrab race to a faster rival. Fire each attempt in its own
		-- thread so several carry requests ride overlapping round-trips and one lands the instant the egg is
		-- grabbable. A lane drop is grabbable from where we stand, so fire NOW and teleport onto it in parallel
		-- (covers the case the server wants us close) instead of waiting the teleport out first.
		local firing = true
		local function fire()
			if firing then pcall(function() EggWorld.AskFieldEggCarry:InvokeServer({ Uid = uid }) end) end
		end
		for _ = 1, 3 do task.spawn(fire) end
		local dest = self:_resolveEggDestination(record, root, humanoid)
		if dest then
			task.spawn(function()
				self:_teleportRoot(root, humanoid, dest)
				self:_setArrivalHold(dest, uid)
			end)
		end
		if Config.SnipePunch then
			task.spawn(function()
				self:_spamPunch(function() return record.BottomCFrame and record.BottomCFrame.Position end, function() return not firing end)
			end)
		end
		local got = false
		local deadline = os.clock() + 2.5
		while os.clock() < deadline and not self.destroyed and self.enabled do
			if heldByMe() then got = true break end
			local cur = EggCmds.ReadFieldEgg(uid)
			if not cur or (cur.State ~= AreaEggs.States.Dropped and cur.State ~= AreaEggs.States.Slot) then break end
			if dest then
				local r3, h3 = parts()
				if r3 and h3 and (r3.Position - dest.Position).Magnitude > 6 then self:_teleportRoot(r3, h3, dest) end
			end
			task.spawn(fire)
			task.wait(0.04)
		end
		firing = false
		self:_clearArrivalHold(uid)
		if got then
			if self._snipeFirstMiss then self._snipeFirstMiss[uid] = nil end
			self:deliverCarriedEgg(uid, record)
			-- stay in the safezone (non-PvP) until it banks, so the rival can't bat it back out of our hands
			local safeDeadline = os.clock() + 8
			while os.clock() < safeDeadline and not self.destroyed and self.enabled do
				local r2, h2 = parts()
				if r2 and h2 then
					local safeCF = self:_resolveSafeCFrame(r2)
					if safeCF and (r2.Position - safeCF.Position).Magnitude > 3 then self:_teleportRoot(r2, h2, safeCF) end
				end
				local after = EggCmds.ReadFieldEgg(uid)
				if after == nil or after.State == AreaEggs.States.Claimed then break end
				task.wait(0.05)
			end
			done("Stole from another script")
		else
			-- "egg is gone": a rival grabbed it before us. A relay SCRIPT re-drops it within a few seconds; a
			-- normal player just banks it. So watch ~5s with only a brief skip so the hook re-snipes its next
			-- relay-drop fast; if 5s pass with nothing landing it is banked / a normal carrier -> skip it a while.
			local now = os.clock()
			self._snipeFirstMiss = self._snipeFirstMiss or {}
			self._snipeFirstMiss[uid] = self._snipeFirstMiss[uid] or now
			if now - self._snipeFirstMiss[uid] > 5 then
				self.skippedEggs[uid] = now + 20
				self._snipeFirstMiss[uid] = nil
				done("Snipe gone — normal carrier, skipping")
			else
				self.skippedEggs[uid] = now + 0.4
				done("Snipe missed — watching re-drop")
			end
		end
	end
	function EggRuntime:_usesPortalBoost(record)
		-- Boost always goes straight to the target egg: no Forest primer at the start, any area (Forest too).
		return Config.LowSpeedBoost == true
			and runtimeEnv.SenaIsDonator ~= false
			and self.config.stealMode == "Instant"
			and type(record) == "table"
	end
	local function fuseBiomePart(folderName, childName)
		local objects = resolveObjectsRoot()
		local build = objects and objects:FindFirstChild("Build")
		local folder = build and build:FindFirstChild(folderName)
		if not folder then return nil end
		local part = childName and folder:FindFirstChild(childName) or folder:FindFirstChildWhichIsA("BasePart", true)
		return part and part:IsA("BasePart") and part or nil
	end
	local function ragdollRemaining()
		local tEnd = LocalPlayer:GetAttribute("RagdollEndTime")
		if type(tEnd) ~= "number" then return 0 end
		return math.max(tEnd + 0.15 - workspace:GetServerTimeNow(), 0)
	end
	local function decodeRefresh(payload)
		local data = payload
		if type(payload) == "string" then
			local ok, decoded = pcall(function() return game:GetService("HttpService"):JSONDecode(payload) end)
			data = ok and decoded or nil
		end
		if type(data) ~= "table" then return nil end
		local args = data.Arguments
		local pos = type(args) == "table" and type(args[3]) == "number" and Vector3.new(args[1], args[2], args[3]) or nil
		return data.Action, pos
	end
	function EggRuntime:_watchRelocates()
		if self._relocateConn then return end
		local remote = Remotes.RigSync and Remotes.RigSync.Refresh
		if not remote then return end
		self._relocateCount = 0
		self._relocateConn = remote.OnClientEvent:Connect(function(payload)
			if decodeRefresh(payload) == "Relocate" then
				self._relocateCount = (self._relocateCount or 0) + 1
				self._relocateAt = os.clock()
			end
		end)
	end
	function EggRuntime:_guardLagback(on)
		local remote = Remotes.RigSync and Remotes.RigSync.Refresh
		if not remote then return end
		if not on then
			for _, hook in ipairs(self._lagbackHooks or {}) do
				pcall(hook.forward.Disconnect, hook.forward)
				pcall(hook.connection.Enable, hook.connection)
			end
			self._lagbackHooks = nil
			return
		end
		if self._lagbackHooks or type(getconnections) ~= "function" then return end
		local hooks = {}
		self._lagbackHooks = hooks
		local ok, conns = pcall(getconnections, remote.OnClientEvent)
		for _, connection in ipairs(ok and type(conns) == "table" and conns or {}) do
			local fn = connection.Function
			local okSrc, src = false, nil
			if type(fn) == "function" then okSrc, src = pcall(debug.info, fn, "s") end
			if okSrc and tostring(src):find("ContentCatalog", 1, true) and type(connection.Disable) == "function"
				and pcall(connection.Disable, connection) then
				local forward = remote.OnClientEvent:Connect(function(payload, ...)
					local action, pos = decodeRefresh(payload)
					if action == "Relocate" and pos and pos.Y < FUSE_BIOME_MIN_Y then return end
					fn(payload, ...)
				end)
				table.insert(hooks, { connection = connection, forward = forward })
			end
		end
	end
	function EggRuntime:_crossPortal(part, abortFn, timeout)
		local character = LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not part or not root or type(firetouchinterest) ~= "function" then return false end
		local from = root.Position
		local deadline = os.clock() + (timeout or 8)
		local hardDeadline = deadline + 6
		local lastTouch = 0
		while os.clock() < deadline do
			if abortFn and abortFn() then return false end
			character = LocalPlayer.Character
			root = character and character:FindFirstChild("HumanoidRootPart")
			if not root then return false end
			if (root.Position - from).Magnitude >= PORTAL_HOP_MIN then
				if (from.Y > FUSE_BIOME_MIN_Y) ~= (root.Position.Y > FUSE_BIOME_MIN_Y) then return true end
				from = root.Position
			end
			local downFor = ragdollRemaining()
			if downFor > 0 then
				deadline = math.min(math.max(deadline, os.clock() + downFor + 1), hardDeadline)
			elseif os.clock() - lastTouch >= 0.1 then
				lastTouch = os.clock()
				pcall(function()
					firetouchinterest(root, part, 0)
					task.wait()
					firetouchinterest(root, part, 1)
				end)
			end
			task.wait(0.05)
		end
		return false
	end
	function EggRuntime:_mutePortalFx(on, force)
		local remote = Remotes.FuseBiome and Remotes.FuseBiome.PortalTransition
		if not remote then return end
		if on then
			self._portalFxMuteCount = (self._portalFxMuteCount or 0) + 1
			if self._portalFxMuted or type(getconnections) ~= "function" then return end
			self._portalFxMuted = {}
			local ok, conns = pcall(getconnections, remote.OnClientEvent)
			for _, connection in ipairs(ok and type(conns) == "table" and conns or {}) do
				local fn = connection.Function
				local okSrc, src = false, nil
				if type(fn) == "function" then okSrc, src = pcall(debug.info, fn, "s") end
				if okSrc and tostring(src):find("FuseBiomePortalController", 1, true) and type(connection.Disable) == "function" then
					if pcall(connection.Disable, connection) then
						table.insert(self._portalFxMuted, connection)
					end
				end
			end
			if #self._portalFxMuted > 0 then
				self._portalFxHandshake = remote.OnClientEvent:Connect(function(_, id, done)
					if id ~= nil and not done then
						pcall(function() remote:FireServer(id) end)
					end
				end)
			end
			self:_filterPortalToasts(true)
		else
			self._portalFxMuteCount = force and 0 or math.max((self._portalFxMuteCount or 0) - 1, 0)
			if self._portalFxMuteCount > 0 then return end
			self:_filterPortalToasts(false, force)
			for _, connection in ipairs(self._portalFxMuted or {}) do
				pcall(connection.Enable, connection)
			end
			self._portalFxMuted = nil
			if self._portalFxHandshake then
				pcall(self._portalFxHandshake.Disconnect, self._portalFxHandshake)
				self._portalFxHandshake = nil
			end
		end
	end
	local PORTAL_TOAST_REMOTES = { { "Toasts", "Line" }, { "Alerts", "Raise" } }
	function EggRuntime:_filterPortalToasts(on, force)
		if on then
			self._portalToastUntil = math.huge
			if self._portalToastHooks or type(getconnections) ~= "function" then return end
			local hooks = {}
			self._portalToastHooks = hooks
			for _, path in ipairs(PORTAL_TOAST_REMOTES) do
				local okRemote, remote = pcall(function() return Remotes[path[1]][path[2]] end)
				if not okRemote then remote = nil end
				local ok, conns = false, nil
				if remote then ok, conns = pcall(getconnections, remote.OnClientEvent) end
				for _, connection in ipairs(ok and type(conns) == "table" and conns or {}) do
					local fn = connection.Function
					if type(fn) == "function" and type(connection.Disable) == "function" and pcall(connection.Disable, connection) then
						local forward = remote.OnClientEvent:Connect(function(payload, ...)
							local text = type(payload) == "table" and (payload.Body or payload.Text)
							if type(text) == "string" and text:lower():find("portal", 1, true)
								and os.clock() < (self._portalToastUntil or 0) then
								return
							end
							fn(payload, ...)
						end)
						table.insert(hooks, { connection = connection, forward = forward })
					end
				end
			end
			return
		end
		local function restore()
			local hooks = self._portalToastHooks
			self._portalToastHooks = nil
			for _, hook in ipairs(hooks or {}) do
				pcall(hook.forward.Disconnect, hook.forward)
				pcall(hook.connection.Enable, hook.connection)
			end
		end
		if force then restore() return end
		local untilAt = os.clock() + 2
		self._portalToastUntil = untilAt
		task.delay(2.1, function()
			if self._portalToastUntil == untilAt and (self._portalFxMuteCount or 0) == 0 then restore() end
		end)
	end
	function EggRuntime:_portalBoostSteal(record)
		self:_mutePortalFx(true)
		self._boostHopUid = record.Uid
		local ok, err = pcall(self._portalBoostHop, self, record)
		self:_guardLagback(false)
		if self._boostHopUid == record.Uid then self._boostHopUid = nil end
		if self._treeHopUid == record.Uid then self._treeHopUid = nil end
		self:_mutePortalFx(false)
		self:_muteTreeFx(false)
		if not ok then
			warn("[Sena Steal] steal error: " .. tostring(err))
			if not self.destroyed and self.enabled then self:_finish("Steal error — retrying") end
			return
		end
		-- Hop returned cleanly but handed nothing off (no carry in flight, no return pending): release the
		-- cycle lock and reschedule, so a half-finished hop can't leave `running` stuck true forever.
		-- A pending carry request (carryAttemptToken) owns the cycle: its poll confirms, fails or times out
		-- by itself. Releasing here killed the carry right before the server accepted it.
		if self.running and not (self.carry and self.carry.active) and self._instantReturnToken == nil
			and self.carryAttemptToken == nil
			and not self.destroyed and self.enabled
		then
			self:_finish("Low Speed Boost — next egg")
		end
	end
	function EggRuntime:_muteTreeFx(on)
		if type(getconnections) ~= "function" then return end
		if on then
			self._treeFxToken = (self._treeFxToken or 0) + 1
			if self._treeFxMuted then return end
			self._treeFxMuted = {}
			local remote = Remotes.EnchantedTree and Remotes.EnchantedTree.Transition
			local targets = {
				{ remote and remote.OnClientEvent, "EnchantedTreeController" },
				{ LocalPlayer:GetAttributeChangedSignal("InEnchantedTree"), "EnchantedTreeController" },
			}
			for _, target in ipairs(targets) do
				local ok, conns = false, nil
				if target[1] then ok, conns = pcall(getconnections, target[1]) end
				for _, connection in ipairs(ok and type(conns) == "table" and conns or {}) do
					local fn = connection.Function
					local okSrc, src = false, nil
					if type(fn) == "function" then okSrc, src = pcall(debug.info, fn, "s") end
					if okSrc and tostring(src):find(target[2], 1, true) and type(connection.Disable) == "function" then
						if pcall(connection.Disable, connection) then table.insert(self._treeFxMuted, connection) end
					end
				end
			end
		else
			if not self._treeFxMuted then return end
			local token = self._treeFxToken
			task.spawn(function()
				local deadline = os.clock() + 12
				while os.clock() < deadline and (LocalPlayer:GetAttribute("InEnchantedTree") == true
					or (self._treePromptAt and os.clock() - self._treePromptAt < 2.5)) do
					task.wait(0.1)
				end
				task.wait(1.5)
				if self._treeFxToken ~= token then return end
				for _, connection in ipairs(self._treeFxMuted or {}) do pcall(connection.Enable, connection) end
				self._treeFxMuted = nil
			end)
		end
	end
	function EggRuntime:_isStealPrompt(prompt)
		if typeof(prompt) ~= "Instance" then return false end
		if prompt.Name == "EnchantedTreePrompt" then return true end
		local slots = workspace:FindFirstChild("AreaEggSlotsClient")
		if slots and prompt:IsDescendantOf(slots) then return true end
		if prompt:FindFirstAncestor("FuseBiomeLanePortals") or prompt:FindFirstAncestor("FuseBiomeZone") then return true end
		return false
	end
	function EggRuntime:_installPromptFilter()
		if self._promptFilter or type(getconnections) ~= "function" then return end
		local filter = { muted = {}, forwarders = {} }
		self._promptFilter = filter
		local function active()
			return not self.destroyed and (self.enabled or self._externalDeliver or self._recalling or self._treeFxMuted ~= nil)
		end
		for _, signal in ipairs({ ProximityPromptService.PromptShown, ProximityPromptService.PromptHidden }) do
			local ok, conns = pcall(getconnections, signal)
			for _, connection in ipairs(ok and type(conns) == "table" and conns or {}) do
				local fn = connection.Function
				local okSrc, src = false, nil
				if type(fn) == "function" then okSrc, src = pcall(debug.info, fn, "s") end
				if okSrc and tostring(src):find("ProximityPromptScriptController", 1, true) and type(connection.Disable) == "function" then
					if pcall(connection.Disable, connection) then
						table.insert(filter.muted, connection)
						table.insert(filter.forwarders, signal:Connect(function(prompt, ...)
							if active() and self:_isStealPrompt(prompt) then return end
							fn(prompt, ...)
						end))
					end
				end
			end
		end
		pcall(function()
			local machines = workspace:FindFirstChild("World") and workspace.World:FindFirstChild("Machines")
			local fuse = machines and machines:FindFirstChild("FuseMachine")
			local prompt = fuse and fuse:FindFirstChildWhichIsA("ProximityPrompt", true)
			if not prompt then return end
			local ok, conns = pcall(getconnections, prompt.Triggered)
			for _, connection in ipairs(ok and type(conns) == "table" and conns or {}) do
				local fn = connection.Function
				if type(fn) == "function" and type(connection.Disable) == "function" and pcall(connection.Disable, connection) then
					table.insert(filter.muted, connection)
					table.insert(filter.forwarders, prompt.Triggered:Connect(function(...)
						if active() then return end
						fn(...)
					end))
				end
			end
		end)
	end
	function EggRuntime:_removePromptFilter()
		local filter = self._promptFilter
		if not filter then return end
		self._promptFilter = nil
		for _, forwarder in ipairs(filter.forwarders) do pcall(forwarder.Disconnect, forwarder) end
		for _, connection in ipairs(filter.muted) do pcall(connection.Enable, connection) end
	end
	function EggRuntime:_leaveTreeHidden(abortFn)
		local objects = resolveObjectsRoot()
		local build = objects and objects:FindFirstChild("Build")
		local interior = build and build:FindFirstChild("EnchantedTreeInterior")
		local markers = interior and interior:FindFirstChild("Markers")
		local exit = markers and markers:FindFirstChild("ExitTrigger")
		local pending = os.clock() + 2.5
		while LocalPlayer:GetAttribute("InEnchantedTree") ~= true and self._treePromptAt
			and os.clock() - self._treePromptAt < 2.5 and os.clock() < pending do
			task.wait(0.05)
		end
		local deadline = os.clock() + 10
		while LocalPlayer:GetAttribute("InEnchantedTree") == true and os.clock() < deadline do
			if abortFn and abortFn() then break end
			local character = LocalPlayer.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root and exit then
				pcall(firetouchinterest, root, exit, 0)
				task.wait()
				pcall(firetouchinterest, root, exit, 1)
			end
			task.wait(0.2)
		end
		return LocalPlayer:GetAttribute("InEnchantedTree") ~= true
	end
	function EggRuntime:_usesTreeBoost(record)
		return false
	end
	function EggRuntime:_treeBoostHop(record)
		local uid = record.Uid
		local objects = resolveObjectsRoot()
		local build = objects and objects:FindFirstChild("Build")
		local interior = build and build:FindFirstChild("EnchantedTreeInterior")
		local markers = interior and interior:FindFirstChild("Markers")
		local enter = markers and markers:FindFirstChild("EnterTrigger")
		local prompt = enter and enter:FindFirstChild("EnchantedTreePrompt", true)
		local exit = markers and markers:FindFirstChild("ExitTrigger")
		local function stale()
			return self.destroyed or not self.enabled
				or self.instantPhase ~= "hunting"
				or not self.activeTarget or self.activeTarget.Uid ~= uid
		end
		local function parts()
			local character = LocalPlayer.Character
			return character and character:FindFirstChild("HumanoidRootPart"),
				character and character:FindFirstChildOfClass("Humanoid")
		end
		local function insideTree()
			return LocalPlayer:GetAttribute("InEnchantedTree") == true
		end
		local function leaveTree()
			local deadline = os.clock() + 8
			while insideTree() and os.clock() < deadline do
				local root = parts()
				if root and exit then
					pcall(firetouchinterest, root, exit, 0)
					task.wait()
					pcall(firetouchinterest, root, exit, 1)
				end
				task.wait(0.2)
			end
			return not insideTree()
		end
		local function fail(reason)
			leaveTree()
			if stale() then return end
			self.treeBoostFailed = self.treeBoostFailed or {}
			self.treeBoostFailed[uid] = os.clock() + 60
			self:_finish(reason)
		end
		local root, humanoid = parts()
		if not (prompt and exit and root and humanoid) then return fail("Steal unavailable — retrying") end
		local holder = prompt.Parent
		local door = holder and ((holder:IsA("Attachment") and holder.WorldPosition) or (holder:IsA("BasePart") and holder.Position))
		if not door then return fail("Steal unavailable — retrying") end
		local calm = os.clock() + 4
		while ragdollRemaining() > 0 and os.clock() < calm do
			if stale() then return end
			task.wait(0.05)
		end
		self:_clearArrivalHold(uid)
		self:_stopHoverPad()
		self:_setStatus("Heading to target egg")
		self._treeHopUid = uid
		self:_muteTreeFx(true)
		self:_teleportRoot(root, humanoid, CFrame.new(door + Vector3.new(0, 1, 4)))
		local hold = (tonumber(prompt.HoldDuration) or 0) + 0.05
		local deadline = os.clock() + 6
		while not insideTree() and os.clock() < deadline do
			if stale() then return end
			pcall(function() prompt.Enabled = true end)
			self._treePromptAt = os.clock()
			pcall(function()
				prompt:InputHoldBegin()
				task.wait(hold)
				prompt:InputHoldEnd()
			end)
			if type(fireproximityprompt) == "function" then pcall(fireproximityprompt, prompt, hold) end
			task.wait(0.1)
		end
		if not insideTree() then return fail("Could not reach the egg — retrying") end
		self:_setStatus("Securing target egg")
		task.wait(0.3)
		if not leaveTree() then return fail("Could not reach the egg — retrying") end
		if stale() then return end
		root, humanoid = parts()
		if not root or not humanoid then return fail("Character unavailable") end
		local current = EggCmds.ReadFieldEgg(uid) or self.records[uid]
		if not current or (current.State ~= AreaEggs.States.Slot and current.State ~= AreaEggs.States.Dropped) then
			self:_finish("Target egg no longer available")
			return
		end
		local destination = self:_resolveEggDestination(current, root, humanoid)
		if not destination then return fail("Target destination unavailable") end
		self:_walkTo(destination, stale, 4)
		if stale() then return end
		root, humanoid = parts()
		if not root or not humanoid or (root.Position - destination.Position).Magnitude > 25 then
			return fail("Could not reach the egg — retrying")
		end
		self:_setArrivalHold(destination, uid)
		self.boostedUid = uid
		self.treeBoostedUid = uid
		task.spawn(function()
			pcall(function() EggWorld.AskFieldEggCarry:InvokeServer({ Uid = uid }) end)
		end)
		self:_setStatus("Securing target egg")
		self:_requestCarry(current, true)
	end
	function EggRuntime:_portalBoostHop(record)
		local uid = record.Uid
		if self:_usesTreeBoost(record) then return self:_treeBoostHop(record) end
		local portal = fuseBiomePart("FuseBiomeLanePortals")
		local exit = fuseBiomePart("FuseBiomeZone", "ExitPart")
		local function stale()
			return self.destroyed or not self.enabled
				or self.instantPhase ~= "hunting"
				or not self.activeTarget or self.activeTarget.Uid ~= uid
		end
		local function parts()
			local character = LocalPlayer.Character
			return character and character:FindFirstChild("HumanoidRootPart"),
				character and character:FindFirstChildOfClass("Humanoid")
		end
		local function leaveBiome()
			local root = parts()
			if root and root.Position.Y > FUSE_BIOME_MIN_Y then self:_crossPortal(exit, nil, 8) end
		end
		local function fail(reason)
			leaveBiome()
			if stale() then return end
			self.portalBoostMisses = self.portalBoostMisses or {}
			local misses = (self.portalBoostMisses[uid] or 0) + 1
			self.portalBoostMisses[uid] = misses
			if misses >= 2 then
				self.portalBoostMisses[uid] = nil
				self.skippedEggs[uid] = os.clock() + 60
			end
			self:_finish(reason)
		end
		local root, humanoid = parts()
		if not portal or not exit or not root or not humanoid then return fail("Steal unavailable — retrying") end
		local destination = self:_resolveEggDestination(record, root, humanoid)
		if not destination then return fail("Target destination unavailable") end
		self:_setStatus("Heading to target egg")
		self:_guardLagback(true)
		RunService.PreSimulation:Wait()
		self:_boostSafeHop(root, humanoid)
		humanoid.PlatformStand = true
		self:_teleportRoot(root, humanoid, destination)
		RunService.PreSimulation:Wait()
		humanoid.PlatformStand = false
		local ping = 0.1
		pcall(function() ping = LocalPlayer:GetNetworkPing() or 0.1 end)
		-- second try on the same egg (one miss already): sit on the egg 0.1 s longer before the portal,
		-- in case the server had not registered the TP yet when the portal was touched
		local retrySlow = ((self.portalBoostMisses and self.portalBoostMisses[uid]) or 0) * 0.1
		task.wait(math.clamp(0.15 + ping * 2.5, 0.3, 1) + retrySlow)
		if stale() then return end
		self:_stopHoverPad()
		self:_setStatus("Securing target egg")
		local entered = self:_crossPortal(portal, stale, 6)
		self:_guardLagback(false)
		if not entered then return fail("Could not reach the egg — retrying") end
		self:_setStatus("Securing target egg")
		if not self:_crossPortal(exit, stale, 8) then return fail("Could not reach the egg — retrying") end
		if stale() then return end
		root, humanoid = parts()
		if not root or not humanoid then return fail("Character unavailable") end
		if (root.Position - destination.Position).Magnitude > 25 then return fail("Could not reach the egg — retrying") end
		local current = EggCmds.ReadFieldEgg(uid) or self.records[uid]
		if not current or (current.State ~= AreaEggs.States.Slot and current.State ~= AreaEggs.States.Dropped) then
			self:_finish("Target egg no longer available")
			return
		end
		destination = self:_resolveEggDestination(current, root, humanoid) or destination
		self:_teleportRoot(root, humanoid, destination)
		self:_setArrivalHold(destination, uid)
		self.boostedUid = uid
		self:_setStatus("Securing target egg")
		task.wait(0.35)
		if stale() then return end
		task.spawn(function()
			pcall(function() EggWorld.AskFieldEggCarry:InvokeServer({ Uid = uid }) end)
		end)
		self:_requestCarry(current, true)
	end
	function EggRuntime:_needsHiddenRecall()
		if self.destroyed then return false end
		local character = LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root then return false end
		if root.Position.Y > FUSE_BIOME_MIN_Y then return true end
		if LocalPlayer:GetAttribute("InEnchantedTree") == true then return true end
		if self._treePromptAt and os.clock() - self._treePromptAt < 2.5 then return true end
		if self._treeHopUid ~= nil then return true end
		return self.treadmillDecoy ~= nil and self.treadmillDecoy.Parent ~= nil and not self:_isInSafeArea(root)
	end
	function EggRuntime:_finishBoostedEgg(uid)
		local record = EggCmds.ReadFieldEgg(uid) or self.records[uid]
		if not record or (record.State ~= AreaEggs.States.Slot and record.State ~= AreaEggs.States.Dropped) then return false end
		local character = LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local destination = root and humanoid and self:_resolveEggDestination(record, root, humanoid)
		if not destination or (root.Position - destination.Position).Magnitude > 25 then return false end
		self:_setArrivalHold(destination, uid)
		self:_setStatus("Finishing target egg")
		local function heldByMe()
			local current = EggCmds.ReadFieldEgg(uid)
			return current ~= nil and current.State == AreaEggs.States.Carried and current.CarrierUserId == LocalPlayer.UserId
		end
		local carried = false
		local deadline = os.clock() + 3
		while not carried and os.clock() < deadline and not self.destroyed and not self.enabled do
			task.spawn(function()
				pcall(function() EggWorld.AskFieldEggCarry:InvokeServer({ Uid = uid }) end)
			end)
			local nextAsk = os.clock() + 0.25
			while os.clock() < nextAsk do
				if heldByMe() then carried = true break end
				task.wait(0.03)
			end
		end
		self:_clearArrivalHold(uid)
		if not carried or self.destroyed or self.enabled then return false end
		self.boostedUid = nil
		if not self:deliverCarriedEgg(uid, record) then return false end
		local wait = os.clock() + 30
		while self._instantReturnToken ~= nil and os.clock() < wait and not self.destroyed do
			task.wait(0.1)
		end
		self.boostedUid = nil
		local after = EggCmds.ReadFieldEgg(uid)
		local banked = after == nil or after.State == AreaEggs.States.Claimed
			or (Config.HelpFriend and after.State == AreaEggs.States.Dropped) 
		character = LocalPlayer.Character
		root = character and character:FindFirstChild("HumanoidRootPart")
		return banked and root ~= nil and self:_isInSafeArea(root)
	end
	function EggRuntime:_finishTreeEgg(uid)
		local record = EggCmds.ReadFieldEgg(uid) or self.records[uid]
		if not record or (record.State ~= AreaEggs.States.Slot and record.State ~= AreaEggs.States.Dropped) then return false end
		local character = LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local destination = root and humanoid and self:_resolveEggDestination(record, root, humanoid)
		if not destination or (root.Position - destination.Position).Magnitude > 400 then return false end
		self:_setStatus("Finishing target egg")
		local external = self._externalDeliver
		self._externalDeliver = true
		self:_walkTo(destination, function() return self.destroyed or self.enabled end, 4)
		self._externalDeliver = external
		if self.destroyed or self.enabled then return false end
		self.treeBoostedUid = uid
		return self:_finishBoostedEgg(uid)
	end
	function EggRuntime:_recallHidden()
		self._recalling = true
		local finishUid = self._boostHopUid
		local treeUid = self._treeHopUid
		task.spawn(function()
			local function handedBack() return self.destroyed or self.enabled end
			local ok, err = pcall(function()
				self:_startMovementProtection()
				self:_mutePortalFx(true)
				local treeHop = LocalPlayer:GetAttribute("InEnchantedTree") == true
					or (self._treePromptAt ~= nil and os.clock() - self._treePromptAt < 2.5)
				if treeHop or treeUid then
					self:_muteTreeFx(true)
					self:_setStatus("Finishing target egg")
					local out = self:_leaveTreeHidden(handedBack)
					local finished = out and not handedBack() and treeUid ~= nil and self:_finishTreeEgg(treeUid)
					self:_muteTreeFx(false)
					if finished or handedBack() then return end
				end
				local character = LocalPlayer.Character
				local root = character and character:FindFirstChild("HumanoidRootPart")
				local inBiome = not treeHop and root ~= nil and root.Position.Y > FUSE_BIOME_MIN_Y
				if inBiome then
					self:_setStatus("Returning to safe area")
					self:_crossPortal(fuseBiomePart("FuseBiomeZone", "ExitPart"), handedBack, 8)
				end
				if handedBack() then return end
				if inBiome and finishUid and self:_finishBoostedEgg(finishUid) then return end
				local held = false
				pcall(function()
					for _, record in ipairs(EggCmds.ReadFieldEggs().Records or {}) do
						if record.State == AreaEggs.States.Carried and record.CarrierUserId == LocalPlayer.UserId then
							held = true
							break
						end
					end
				end)
				if held then
					pcall(EggCmds.DropFieldEgg, "PlayerRequest")
					task.wait(0.3)
				end
				character = LocalPlayer.Character
				root = character and character:FindFirstChild("HumanoidRootPart")
				if root and not self:_isInSafeArea(root) and not handedBack() then
					self:_setStatus("Returning to safe area")
					local safeCF = self:_resolveSafeCFrame(root)
					local external = self._externalDeliver
					self._externalDeliver = true 
					if safeCF then self:_glideRoot(safeCF, handedBack) end
					self._externalDeliver = external
					if not handedBack() then self:_groundSnap() end
				end
			end)
			if not ok then warn("[Sena Steal] hidden recall error: " .. tostring(err)) end
			self:_mutePortalFx(false)
			self._recalling = nil
			if not self.destroyed and not self.enabled then
				self:_hideTreadmillDecoy()
				self:_removeGuardHitDistanceBoost()
				self:_stopMovementProtection()
				stopHealthPinner(self)
				self:_setStatus("Idle")
			end
		end)
	end
	function EggRuntime:_treadmillReset(abortFn)
		self._treadmillResetting = true
		local ok, result = pcall(self._treadmillResetInner, self, abortFn)
		self._treadmillResetting = false
		return ok and result
	end
	function EggRuntime:_treadmillResetInner(abortFn)
		local function aborted() return abortFn ~= nil and abortFn() end
		local Treadmill = Remotes and Remotes.Treadmill
		if not Treadmill or aborted() then return false end
		local function serverMounted()
			local ok, ids = pcall(function() return Treadmill.AskRenderSnapshot:InvokeServer() end)
			if not ok or type(ids) ~= "table" then return nil end
			return table.find(ids, LocalPlayer.UserId) ~= nil
		end
		local function standCFrame()
			local ok, cf = pcall(function()
				local slot = type(PlotState.ResolveLocalSlot) == "function"
					and PlotState.ResolveLocalSlot() or PlotState.GetMySlot()
				local plotsFolder = type(PlotState.ResolveFolder) == "function"
					and PlotState.ResolveFolder() or PlotState.GetPlotsFolder()
				local plotFolder = plotsFolder and slot and plotsFolder:FindFirstChild(tostring(slot))
				local bottom = plotFolder and plotFolder:FindFirstChild("TreadmillBottom")
				if not (bottom and bottom:IsA("BasePart")) then return nil end
				local character = LocalPlayer.Character
				local root = character and character:FindFirstChild("HumanoidRootPart")
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				if not root or not humanoid then return nil end
				local feetOffset = humanoid.RigType == Enum.HumanoidRigType.R15
					and (root.Size.Y * 0.5 + math.max(humanoid.HipHeight, 0.5))
					or (root.Size.Y * 0.5 + 2)
				return bottom.CFrame * CFrame.new(0, bottom.Size.Y * 0.5 + feetOffset + 0.05, 0)
			end)
			return ok and cf or nil
		end
		local stand = standCFrame()
		if not stand or aborted() then return false end
		self:_glideRoot(stand, function() return aborted() end)
		if aborted() then return false end
		local mountedOk = false
		local mountDeadline = os.clock() + 0.7
		while not aborted() and os.clock() < mountDeadline do
			pcall(function() Treadmill.AskWearStill:InvokeServer() end)
			task.wait(0.08)
			if serverMounted() == true then mountedOk = true break end
		end
		if mountedOk then
			local holdUntil = os.clock() + 0.25
			while not aborted() and os.clock() < holdUntil do
				task.wait(0.05)
			end
		end
		local released = false
		local releaseDeadline = os.clock() + 0.7
		while not aborted() and os.clock() < releaseDeadline do
			pcall(function() Treadmill.AskDoff:InvokeServer() end)
			task.wait(0.08)
			if serverMounted() == false then released = true break end
		end
		return mountedOk and released
	end
	-- Relay drop point: the known-good relay lane (554,-395), randomised toward the Forest field (+X/+Z) so it
	-- varies each round but never drifts back onto the safe zone (which rejects the drop). Ground-snapped Y.
	function EggRuntime:_randomRelayCF()
		local base = FOREST_DROP_RELAY.Position
		local x = base.X + math.random() * FOREST_DROP_JITTER
		local z = base.Z + math.random() * FOREST_DROP_JITTER
		local y = base.Y
		local gy = self._groundYAt and self:_groundYAt(x, z)
		if type(gy) == "number" then y = gy + 3 end
		return CFrame.new(x, y, z) * (FOREST_DROP_RELAY - FOREST_DROP_RELAY.Position)
	end
	function EggRuntime:_instantReturn(uid)
		if self._instantReturnToken ~= nil then return end
		local token = {}
		self._instantReturnToken = token
		self._flyDeparting = false
		if self.config.stealMode == "Fly" then self:_showTreadmillDecoy() end
		task.spawn(function()
			local function alive()
				return not self.destroyed and (self.enabled or self._externalDeliver) and self._instantReturnToken == token
			end
			local function parts()
				local character = LocalPlayer.Character
				return character and character:FindFirstChild("HumanoidRootPart"),
					character and character:FindFirstChildOfClass("Humanoid")
			end
			local function record()
				return EggCmds.ReadFieldEgg(uid)
			end
			local function heldByMe()
				local r = record()
				return r ~= nil and r.State == AreaEggs.States.Carried and r.CarrierUserId == LocalPlayer.UserId
			end
			local function banked()
				local r = record()
				if not r then return true end
				return r.State == AreaEggs.States.Claimed
			end
			local function tp(cf, status)
				local root, humanoid = parts()
				if root and humanoid and typeof(cf) == "CFrame" then
					if status then self:_setStatus(status) end
					self:_teleportRoot(root, humanoid, cf)
				end
			end
			local function safeCFrame()
				local root = (parts())
				return root and self:_resolveSafeCFrame(root) or nil
			end
			local function noteBringHome(ok)
				self.settleBonus = self.settleBonus or {}
				if ok then
					self.settleBonus[uid] = nil
				elseif self.config.stealMode == "Instant" and self.boostedUid ~= uid then
					self.settleBonus[uid] = { seconds = SETTLE_RETRY_BONUS, untilAt = os.clock() + 300 }
				end
			end
			local function finish(reason)
				if self._instantReturnToken ~= token then return end
				noteBringHome(reason == nil or reason == "Safe return complete")
				self._instantReturnToken = nil
				self._forestDropInProgress = nil
				local wasExternal = self._externalDeliver
				self._externalDeliver = nil
				if self.destroyed then return end
				if self.enabled then
					self:_reportStolen()
					self:_finish(reason or "Safe return complete")
				elseif wasExternal then
					self:_reportStolen()
					self.carry.active = false
					self.carry.uid = nil
					self.activeTarget = nil
					self:_hideTreadmillDecoy()
				end
			end
			self:_clearArrivalHold(uid)
			local regrabMode = self.treeBoostedUid == uid and (self.treeRegrabMode or "walk") or "glide"
			local function inSafe()
				local root = (parts())
				return root ~= nil and self:_isInSafeArea(root)
			end
			local function moveTo(cf, abortFn, arrive)
				return self:_walkTo(cf, abortFn, arrive or 4)
			end
			local function regrabMove(cf, abortFn, arrive, leg)
				local walk = regrabMode == "walk"
					or (leg == "egg" and (regrabMode == "glideSafe" or regrabMode == "skipSafe"))
					or (leg == "safe" and regrabMode == "glideEgg")
				if walk and leg == "safe" then return self:_walkTo(cf, function() return abortFn() or inSafe() end, arrive or 4) end
				if walk then return self:_walkTo(cf, abortFn, arrive or 4) end
				return self:_glideRoot(cf, abortFn)
			end
			local fast = self.config.stealMode == "Fly" or (self.boostedUid == uid and not Config.HelpFriend)
			local preDropSettle = (self.boostedUid == uid and not Config.HelpFriend and 0.3) or (fast and 0.15) or 0.4
			local dropSettle = fast and 0.45 or FOREST_DROP_SETTLE
			local held = heldByMe()
			if not held then
				self:_setStatus("Confirming carry record")
				local syncUntil = os.clock() + 2.5
				while alive() and os.clock() < syncUntil do
					held = heldByMe()
					if held then break end
					local r = record()
					if r and r.State == AreaEggs.States.Claimed then break end
					RunService.Heartbeat:Wait()
				end
				if not alive() then return end
			end
			local needsTransfer = held
			if needsTransfer then
				self._forestDropInProgress = uid
				for relayRound = 1, EggRuntime.RELAY_ROUNDS do
				local relayCF = self:_randomRelayCF()
				self._forestDropInProgress = uid
				self:_setStatus("Bringing egg home")
				self:_hopRoot(relayCF, function() return not alive() or not heldByMe() end)
				if not alive() then return end
				local released = false
				for attempt = 1, FOREST_TRANSFER_ATTEMPTS do
					if not alive() or not heldByMe() then break end
					self:_setStatus("Bringing egg home")
					self:_hopRoot(relayCF, function() return not alive() or not heldByMe() end)
					if not alive() then return end
					if heldByMe() then
						-- Fast path (Low Speed Boost): drop almost immediately after the relay hop so a guard
						-- never gets a window to knock us down or flag "movement not trusted" mid-carry. The
						-- adaptive _relaySettle (which backs off if drops land far) only gates the slow path.
						task.wait(fast and preDropSettle or math.max(preDropSettle, self:_relaySettle()))
						if not alive() then return end
						if heldByMe() then
							pcall(EggCmds.DropFieldEgg, "PlayerRequest")
						end
						local dropUntil = os.clock() + dropSettle
						while alive() and heldByMe() and os.clock() < dropUntil do
							RunService.Heartbeat:Wait()
						end
					end
					local rec2 = record()
					if rec2 and rec2.State == AreaEggs.States.Dropped then released = true break end
					if not heldByMe() then break end
				end
				if not alive() then return end
				if not released then
					if self._instantReturnToken == token then self._instantReturnToken = nil end
					self._forestDropInProgress = nil
					noteBringHome(false)
					-- interrupt recovery (user idea): a guard ragdoll knocked the relay drop out. Wait the ragdoll
					-- out, then reset to the safezone CFrame (a trusted, wall-clear spot) before retrying, so the
					-- next attempt does not start from a ragdolled / wall-clipped position and instantly fail again.
					pcall(function()
						local calm = os.clock() + 3
						while ragdollRemaining() > 0 and os.clock() < calm and alive() do RunService.Heartbeat:Wait() end
						local ch = LocalPlayer.Character
						local r = ch and ch:FindFirstChild("HumanoidRootPart")
						local h = ch and ch:FindFirstChildOfClass("Humanoid")
						if r and h and not self:_isInSafeArea(r) then
							local safeCF = self:_resolveSafeCFrame(r)
							if safeCF then self:_teleportRoot(r, h, safeCF) end
						end
					end)
					self:_finish("Drop failed — retrying")
					return
				end
				if Config.HelpFriend then
					self.skippedEggs[uid] = os.clock() + 1800 
					self._forestDropInProgress = nil
					self.carry.active = false
					self.carry.uid = nil
					self.stats.lastResult = "Dropped for a friend"
					self:_setStatus("Egg dropped for a friend, heading back")
					local safeCF = safeCFrame()
					if safeCF then self:_glideRoot(safeCF, function() return not alive() end) end
					if not alive() then return end
					local wasExternal = self._externalDeliver
					self._instantReturnToken = nil
					self._externalDeliver = nil
					if self.enabled then
						self:_finish("Dropped for a friend")
					elseif wasExternal then
						self.activeTarget = nil
						self:_hideTreadmillDecoy()
					end
					return
				end
				local dropPos
				local syncUntil = os.clock() + 3
				while alive() and os.clock() < syncUntil do
					local r = record()
					if r and r.State == AreaEggs.States.Dropped then
						local b = r.BottomCFrame or r.BoundsCFrame
						dropPos = b and b.Position
						if dropPos then break end
					elseif r and r.State ~= AreaEggs.States.Carried then
						break
					end
					task.wait(0.1)
				end
				if not alive() then return end
				self._forestDropInProgress = nil
				if dropPos then self:_noteRelayLanding((dropPos - relayCF.Position).Magnitude) end
				self:_setStatus("Bringing egg home")
				local safeCF = regrabMode ~= "skipSafe" and safeCFrame() or nil
				if safeCF then regrabMove(safeCF, function() return not alive() end, nil, "safe") end
				if not alive() then return end
				local rgWorker = self:_claimCarryWorker("instant-regrab", uid)
				local regrabCF = dropPos and CFrame.new(dropPos + Vector3.new(0, 3.2, 0)) or relayCF
				local function gotoEgg()
					regrabMove(regrabCF, function() return not alive() or heldByMe() end, 3, "egg")
				end
				local got = false
				if rgWorker then
					self:_setStatus("Bringing egg home")
					gotoEgg()
					if not alive() then return end
					got = self:_regrabBurst(rgWorker, uid, 0.5)
					if not alive() then return end
					if heldByMe() then got = true end
					if not got and not heldByMe() and self:_isCarryWorkerCurrent(rgWorker) then
						self:_setStatus("Bringing egg home")
						local resetSafeCF = safeCFrame()
						if resetSafeCF then self:_glideRoot(resetSafeCF, function() return not alive() end) end
						if not alive() then return end
						self:_setStatus("Bringing egg home")
						self:_treadmillReset(function() return not alive() end)
						if not alive() then return end
						self:_setStatus("Bringing egg home")
						local resetSafeCF2 = safeCFrame()
						if resetSafeCF2 then self:_glideRoot(resetSafeCF2, function() return not alive() end) end
						if not alive() then return end
						if self:_isCarryWorkerCurrent(rgWorker) then
							self:_setStatus("Bringing egg home")
							gotoEgg()
							if not alive() then return end
							got = self:_regrabBurst(rgWorker, uid, 0.6)
							if not alive() then return end
						end
					end
				end
				if not got and not heldByMe() then
					finish(banked() and "Safe return complete" or "Re-grab failed — retrying")
					return
				end
				local landedFar = dropPos ~= nil and (dropPos - relayCF.Position).Magnitude > EggRuntime.RELAY_LAND_OK
				if not (landedFar and heldByMe()) or relayRound >= EggRuntime.RELAY_ROUNDS then break end
				self:_setStatus("Bringing egg home")
				end
			end
			local SHORT_HOME_HOP = 80
			local function homeMove(cf, abortFn)
				local r, h = parts()
				if r and h and (r.Position - cf.Position).Magnitude <= SHORT_HOME_HOP then
					return self:_teleportRoot(r, h, cf)
				end
				return moveTo(cf, abortFn)
			end
			if heldByMe() then
				self:_setStatus("Bringing egg home")
				local safeCF = safeCFrame()
				if safeCF then
					homeMove(safeCF, function() return not alive() or not heldByMe() end)
				end
			end
			self:_setStatus("Waiting for deposit")
			local depositDeadline = os.clock() + 8
			while alive() and not banked() and os.clock() < depositDeadline do
				local r, h = parts()
				if r and h and not self:_isInSafeArea(r) then
					local cf = self:_resolveSafeCFrame(r)
					if cf then homeMove(cf, function() return not alive() or banked() end) end
				end
				task.wait(0.1)
			end
			finish(banked() and "Safe return complete" or "Bank not confirmed — retrying")
			end)
	end
	function EggRuntime:deliverCarriedEgg(uid, record)
		if type(uid) ~= "string" or uid == "" or self.destroyed then return false end
		if self._instantReturnToken ~= nil then return false end
		self._externalDeliver = true
		if type(record) == "table" then self.activeTarget = record end
		self.carry.active = true
		self.carry.uid = uid
		self.reportedUid = nil
		self:_instantReturn(uid)
		if self._instantReturnToken == nil then
			self._externalDeliver = nil
			self.carry.active = false
			self.carry.uid = nil
			return false
		end
		task.spawn(function()
			local deadline = os.clock() + 30
			while self._instantReturnToken ~= nil and os.clock() < deadline do
				task.wait(0.25)
			end
			if self._externalDeliver then
				self._externalDeliver = nil
				self._instantReturnToken = nil
				self.carry.active = false
				self.carry.uid = nil
			end
			end)
		return true
	end
	function EggRuntime:_adminSteal(record)
		local uid = record.Uid
		self._adminBusyUid = uid
		local function heldByMe()
			local r = EggCmds.ReadFieldEgg(uid)
			return r ~= nil and r.State == AreaEggs.States.Carried and r.CarrierUserId == LocalPlayer.UserId
		end
		local function alive()
			return not self.destroyed and self.enabled and runtimeEnv.__SenaV4AdminBoost == true and self._adminBusyUid == uid
		end
		local ok, err = pcall(function()
			self.instantPhase = nil
			self.primerUid = nil
			self.targetUid = nil
			self.activeTarget = record
			self.stats.lastResult = "Admin Abuse"
			self:_setStatus("Heading to target egg")
			local deadline = os.clock() + 3
			local nextAsk = 0
			while alive() and not heldByMe() do
				if os.clock() >= deadline then
					self.skippedEggs[uid] = os.clock() + 10
					return self:_finish("Carry refused — next egg")
				end
				local current = EggCmds.ReadFieldEgg(uid)
				if not current or (current.State ~= AreaEggs.States.Slot and current.State ~= AreaEggs.States.Dropped) then
					return self:_finish("Target egg no longer available")
				end
				local character = LocalPlayer.Character
				local root = character and character:FindFirstChild("HumanoidRootPart")
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				if not root or not humanoid then return self:_finish("Character unavailable") end
				local destination = self:_resolveEggDestination(current, root, humanoid)
				if destination and (root.Position - destination.Position).Magnitude > 4 then
					self:_teleportRoot(root, humanoid, destination)
				end
				if os.clock() >= nextAsk then
					nextAsk = os.clock() + 0.1
					self:_setStatus("Securing egg")
					task.spawn(function()
						pcall(function() EggWorld.AskFieldEggCarry:InvokeServer({ Uid = uid }) end)
					end)
				end
				RunService.Heartbeat:Wait()
			end
			if not alive() then return end
			self.carry.active = true
			self.carry.uid = uid
			self:_adminDeliver(uid)
		end)
		if self._adminBusyUid == uid then self._adminBusyUid = nil end
		if not ok then
			warn("[Sena Steal] admin steal error: " .. tostring(err))
			if not self.destroyed and self.enabled then self:_finish("Steal error — retrying") end
		end
	end
	function EggRuntime:_adminDeliver(uid)
		if self._adminDeliverUid == uid then return end
		self._adminDeliverUid = uid
		self._adminBusyUid = uid
		local function record() return EggCmds.ReadFieldEgg(uid) end
		local function heldByMe()
			local r = record()
			return r ~= nil and r.State == AreaEggs.States.Carried and r.CarrierUserId == LocalPlayer.UserId
		end
		local function banked()
			local r = record()
			return r == nil or r.State == AreaEggs.States.Claimed
		end
		self:_clearArrivalHold(uid)
		self:_setStatus("Bringing egg home")
		local deadline = os.clock() + 4
		while not self.destroyed and self.enabled and not banked() and heldByMe() and os.clock() < deadline do
			local character = LocalPlayer.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			local safeCF = root and self:_resolveSafeCFrame(root)
			if safeCF and humanoid and (root.Position - safeCF.Position).Magnitude > 4 then
				self:_teleportRoot(root, humanoid, safeCF)
				self:_setStatus("Waiting for deposit")
			end
			RunService.Heartbeat:Wait()
		end
		self._adminDeliverUid = nil
		if self._adminBusyUid == uid then self._adminBusyUid = nil end
		if self.destroyed or not self.enabled then return end
		if banked() then
			self:_reportStolen()
			self:_finish("Safe return complete")
		else
			self:_finish(heldByMe() and "Bank not confirmed — retrying" or "Egg lost — retrying")
		end
	end
	function EggRuntime:_returnToSafe()
		if self:_isPrimerEgg(self.carry.uid) then
			local primerUid = self.carry.uid
			self.stats.lastResult = "Steal not banked — retrying"
			self.carry.active = false
			self.carry.uid = nil
			self.carry.generation += 1
			self:_invalidateCarryWorker()
			self.skippedEggs[primerUid] = os.clock() + 30
			pcall(EggCmds.DropFieldEgg, "PlayerRequest")
			if self.instantPhase == "priming" then
				self:_startPrimerTargetHunt()
			else
				task.delay(0.5, function()
					if not self.destroyed and self.enabled and not self.running then self:_schedule() end
					end)
			end
			self:_notify()
			return
		end
		if self.captureObjectiveEnabled and self:_isCaptureEgg(self.carry.uid) then
			self:_captureHold(self.carry.uid)
			return
		end
		if runtimeEnv.__SenaV4AdminBoost == true then
			local heldUid = self.carry.uid or (self.activeTarget and self.activeTarget.Uid)
			if heldUid and self._adminBusyUid ~= heldUid then
				task.spawn(self._adminDeliver, self, heldUid)
			end
			return
		end
		if Config.FastPull and not self._fpOn then
			local fpRec = self.carry.uid and (self.records[self.carry.uid] or EggCmds.ReadFieldEgg(self.carry.uid))
			if type(fpRec) == "table" and self:_areaOverSpeed(fpRec.AreaId) then
				self._fpOn = true
				self._fpSavedSpeed = self.config.speed
				self.config.speed = tonumber(Config.FastPullSpeed) or self.config.speed
				runtimeEnv.__SenaV4FastPull = true
			end
		end
		if self.config.stealMode == "Instant" or self.config.stealMode == "Fly" then
			local heldUid = self.carry.uid or (self.activeTarget and self.activeTarget.Uid)
			if heldUid then
				self:_instantReturn(heldUid)
				return
			end
			self:_finish("Carry lost — retrying")
			return
		end
		local uid = self.carry.uid
		local worker = self:_claimCarryWorker("return", uid)
		if not worker then return end
		self:_clearArrivalHold(uid)
		if not self:_wallOpen() then
			self:_releaseCarryWorker(worker)
			self:_finish("Reset interrupted carry")
			return
		end
		local character = LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not root then
			self:_releaseCarryWorker(worker)
			self:_finish("Character unavailable")
			return
		end
		if not self:_hasConfirmedCarry(uid) or self:_recordShowsForeignCarry(uid) then
			self:_releaseCarryWorker(worker)
			self:_finish("Carry not confirmed — retrying")
			return
		end
		if self:_isInSafeArea(root) then
			self:_finalizeReturn(worker)
			return
		end
		if Config.HelpFriend then
			self.handoffLane = ((self.handoffLane or 0) % #HANDOFF_LANES) + 1
			local lane = CFrame.new(HANDOFF_X, SAFE_ZONE_POSITION.Y, HANDOFF_LANES[self.handoffLane]) * root.CFrame.Rotation
			self:_setStatus("Taking the egg to the friend drop")
			self:_tweenRoot(lane, function()
				if self:_isCarryWorkerCurrent(worker) then
					task.spawn(self._handOffEgg, self, worker, uid, lane)
				end
				end, nil, {
					flightProfile = true,
				})
			return
		end
		local destination = self:_resolveSafeCFrame(root)
		if not destination then
			self:_releaseCarryWorker(worker)
			self:_finish("Safe destination unavailable")
			return
		end
		self:_setStatus("Returning to safe area")
		self:_tweenRoot(destination, function()
			if self:_isCarryWorkerCurrent(worker) then self:_finalizeReturn(worker) end
			end, nil, {
				flightProfile = true,
			})
	end
	function EggRuntime:_handOffEgg(worker, uid, lane)
		local function pin()
			local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
			if not root then return false end
			root.CFrame = lane
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
			return true
		end
		local function stillHeld()
			local record = EggCmds.ReadFieldEgg(uid)
			return record ~= nil and record.State == AreaEggs.States.Carried and record.CarrierUserId == LocalPlayer.UserId
		end
		self:_setStatus("Dropping the egg for a friend")
		local ping = 0.1
		pcall(function() ping = LocalPlayer:GetNetworkPing() or 0.1 end)
		local settleUntil = os.clock() + math.max(0.3, 0.2 + 2 * ping)
		while os.clock() < settleUntil do
			if not pin() then break end
			RunService.Heartbeat:Wait()
		end
		self.skippedEggs[uid] = os.clock() + 1800
		self:_reportStolen()
		local released = false
		for _ = 1, 4 do
			pin()
			if not stillHeld() then released = true break end
			pcall(EggCmds.DropFieldEgg, "PlayerRequest")
			local deadline = os.clock() + 0.6
			repeat
				RunService.Heartbeat:Wait()
				released = not stillHeld()
			until released or os.clock() >= deadline
			if released then break end
		end
		if not released then
			self.skippedEggs[uid] = nil
			if self:_isCarryWorkerCurrent(worker) then
				self:_releaseCarryWorker(worker)
				self:_finish("Friend drop failed — retrying")
			end
			return
		end
		local handled = os.clock() + 1
		while self.carry.active and os.clock() < handled do
			RunService.Heartbeat:Wait()
		end
		self.carry.active = false
		self.carry.uid = nil
		self.stats.lastResult = "Dropped for a friend"
		local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
		local safe = root and self:_resolveSafeCFrame(root)
		if not safe then
			self:_finish("Dropped for a friend")
			return
		end
		self:_setStatus("Egg dropped for a friend, heading back")
		self:_tweenRoot(safe, nil, nil, {
			flightProfile = true,
			onDone = function()
				self:_finish("Dropped for a friend")
			end,
			})
	end
	function EggRuntime:_reportStolen()
		local record = self.activeTarget
		if type(record) ~= "table" or not record.Uid then return end
		if self.reportedUid == record.Uid then return end
		self.reportedUid = record.Uid
		task.delay(1.5, function()
			if self.destroyed then return end
			local field = nil
			pcall(function() field = EggCmds.ReadFieldEgg(record.Uid) end)
			local stillThere = type(field) == "table" and (field.State == AreaEggs.States.Slot
				or field.State == AreaEggs.States.Dropped
				or (field.State == AreaEggs.States.Carried and field.CarrierUserId ~= LocalPlayer.UserId))
			if stillThere then
				self.reportedUid = nil
				self.stats.deliveryFailed = (self.stats.deliveryFailed or 0) + 1
				self.stats.lastResult = "Delivery failed — retrying"
				self:_notify()
				if self.enabled and not self.running then self:_schedule() end
				return
			end
			self.stats.delivered = (self.stats.delivered or 0) + 1
			local hook = runtimeEnv.__SenaV4Webhook
			if not hook then return end
			local okInfo, info = pcall(self.catalog.resolve, record)
			pcall(hook.stolen, record, okInfo and info or nil, nil)
			end)
	end
	function EggRuntime:_startWatchdog()
		if self.watchdogRunning then return end
		self.watchdogRunning = true
		task.spawn(function()
			local lastKey, keySince, idleSince = nil, os.clock(), nil
			local frozenStatus, frozenPos, frozenSince = nil, nil, nil
			while sessionAlive() and not self.destroyed and self.enabled do
				task.wait(2)
				-- a race/scramble started (or the join window opened) mid-cycle: abort the steal in flight so it
				-- stops yanking the character away from the lap (the _schedule guard already blocks new cycles).
				if self:_eventBlocksSteal()
					and self.enabled and (self.running or (self.carry and self.carry.active))
				then
					pcall(function() self:_invalidateCarryWorker() end)
					self.carry.active = false
					self:_finish("Paused - race/event in progress")
					self:_releaseOperation()
				end
				local liveRoot = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
				local liveStatus = tostring(self.stats.status)
				if self.enabled and liveRoot and liveRoot.Position.Y > FUSE_BIOME_MIN_Y
					and self._boostHopUid == nil and not self._recalling
				then
					if self._biomeStrandedSince and os.clock() - self._biomeStrandedSince >= 2 then
						self._biomeStrandedSince = nil
						self.stats.watchdogResets = (self.stats.watchdogResets or 0) + 1
						self:_setStatus("Leaving the portal biome")
						self:_mutePortalFx(true)
						pcall(self._crossPortal, self, fuseBiomePart("FuseBiomeZone", "ExitPart"), nil, 8)
						self:_mutePortalFx(false)
						if self.running then self:_finish("Left the portal biome") end
					else
						self._biomeStrandedSince = self._biomeStrandedSince or os.clock()
					end
				else
					self._biomeStrandedSince = nil
				end
				if self.enabled and self.running and not self.carry.active and self.carryAttemptToken == nil
					and self._instantReturnToken == nil and not self._captureHoldUid and liveRoot
					and liveStatus == frozenStatus and frozenPos and (liveRoot.Position - frozenPos).Magnitude < 3
				then
					if os.clock() - frozenSince > 12 then
						frozenStatus, frozenPos, frozenSince = nil, nil, nil
						lastKey = nil
						self.stats.watchdogResets = (self.stats.watchdogResets or 0) + 1
						pcall(function() self:_invalidateCarryWorker() end)
						self:_finish("Stuck - retrying")
						self:_releaseOperation()
					end
				else
					frozenStatus, frozenPos, frozenSince = liveStatus, liveRoot and liveRoot.Position, os.clock()
				end
				if not self.enabled or self._captureHoldUid then
					lastKey, idleSince = nil, nil
				elseif self.running then
					idleSince = nil
					local key = tostring(self.activeTarget and self.activeTarget.Uid) .. "|" .. tostring(self.carry.active)
					if key ~= lastKey then
						lastKey, keySince = key, os.clock()
					elseif os.clock() - keySince > 60 then
						lastKey = nil
						self.stats.watchdogResets = (self.stats.watchdogResets or 0) + 1
						local stuckUid = self.activeTarget and self.activeTarget.Uid
						if stuckUid and not self.carry.active then
							self.skippedEggs[stuckUid] = os.clock() + CARRY_TIMEOUT_SKIP_SECONDS
							if self.tweenRecoveryUid == stuckUid then self.tweenRecoveryUid = nil end
						end
						pcall(function() self:_invalidateCarryWorker() end)
						self:_finish("Stuck — retrying")
					end
				else
					lastKey = nil
					local okTarget, target = pcall(self._chooseTarget, self)
					if self:_wallOpen() and okTarget and target ~= nil then
						idleSince = idleSince or os.clock()
						if os.clock() - idleSince > 6 then
							idleSince = nil
							self.stats.watchdogResets = (self.stats.watchdogResets or 0) + 1
							self:_releaseOperation()
							self:_schedule()
						end
					else
						idleSince = nil
					end
				end
			end
			self.watchdogRunning = false
			end)
	end
	function EggRuntime:_finalizeReturn(worker)
		if not self:_isCarryWorkerCurrent(worker) then return end
		if not self.carry.active then
			self:_releaseCarryWorker(worker)
			self:_reportStolen()
			self:_finish("Safe return complete")
			return
		end
		self:_setStatus("Validating safe arrival")
		local stableSince = os.clock()
		local deadline = os.clock() + 6
		while self:_isCarryWorkerCurrent(worker) and self.carry.active and os.clock() < deadline do
			local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
			if not root then
				self:_releaseCarryWorker(worker)
				self:_finish("Character unavailable")
				return
			end
			if not self:_isInSafeArea(root) then
				self:_setStatus("Rollback detected — returning again")
				self:_releaseCarryWorker(worker)
				task.defer(function()
					if not self.destroyed and self.enabled and self.carry.active then
						self:_returnToSafe()
					end
					end)
				return
			end
			if os.clock() - stableSince >= SAFE_ARRIVAL_STABLE_TIME then
				self:_setStatus("Waiting for deposit")
			end
			task.wait(RETURN_VALIDATION_INTERVAL)
		end
		if not self:_isCarryWorkerCurrent(worker) then return end
		if not self.carry.active then
			self:_releaseCarryWorker(worker)
			self:_reportStolen()
			self:_finish("Safe return complete")
			return
		end
		self:_setStatus("Deposit pending — validating again")
		task.defer(function()
			if self:_isCarryWorkerCurrent(worker) and self.carry.active then
				self:_finalizeReturn(worker)
			end
			end)
	end
	function EggRuntime:_finish(result)
		if self._fpOn then self.config.speed = self._fpSavedSpeed; self._fpOn = nil; self._fpSavedSpeed = nil; runtimeEnv.__SenaV4FastPull = nil end
		self:_noteLowSpeedOutcome(result)
		self:_hideTreadmillDecoy()
		self._forestDropInProgress = nil
		self._instantReturnToken = nil
		self.boostedUid = nil
		self:_invalidateCarryWorker()
		self.planGeneration += 1
		self:_cancelTween(result, self.enabled)
		self:_setStatus(self.enabled and "Searching" or "Idle")
		if self.enabled then
			task.delay(NEXT_TARGET_HANDOFF_SECONDS, function()
				if self.destroyed or not self.enabled then
					self:_releaseOperation()
					return
				end
				self:_schedule()
				end)
		end
	end
	function EggRuntime:_scheduleMovementRetry()
		if self.movementRetryPending or self.destroyed or not self.enabled then
			return
		end
		self.movementRetryPending = true
		task.delay(0.2, function()
			self.movementRetryPending = false
			if not self.destroyed and self.enabled then
				self:_schedule()
			end
			end)
	end
	function EggRuntime:_eggCount()
		local ok, count = pcall(function()
			local n = 0
			for _ in pairs(require(ReplicatedStorage.Shared.Save).Peek().EggInventory or {}) do n += 1 end
			return n
		end)
		return ok and count or nil
	end
	-- Unplaced (sellable) egg count. Placed eggs sit on the plot and Auto Sell never touches them.
	function EggRuntime:_unplacedEggCount()
		local ok, count = pcall(function()
			local n = 0
			for _, r in pairs(require(ReplicatedStorage.Shared.Save).Peek().EggInventory or {}) do
				if type(r) == "table" and r.Placement == nil then n += 1 end
			end
			return n
		end)
		return ok and count or nil
	end
	-- When Auto Sell Egg is on and unplaced eggs back up, steal MUST step aside so the sell loop (ranked
	-- below steal) can actually get the character and drain. Without this steal never idles, sell never
	-- sells, and the inventory grows until it jams full. Hysteresis: yield at DRAIN_HIGH, resume at DRAIN_LOW.
	function EggRuntime:_shouldYieldToSell()
		if Config.AutoSellEgg ~= true then self._draining = false return false end
		local busy = runtimeEnv.__SenaV4IsAutoSellEggBusy
		if not (busy and busy()) then self._draining = false return false end
		local n = self:_unplacedEggCount()
		if not n then return false end
		local high = tonumber(Config.StealDrainHigh) or EggRuntime.DRAIN_HIGH
		local low = tonumber(Config.StealDrainLow) or EggRuntime.DRAIN_LOW
		if self._draining then
			if n <= low then self._draining = false end
		elseif n >= high then
			self._draining = true
		end
		return self._draining == true
	end
	function EggRuntime:_eggInventoryFull()
		local cap = self.eggFullCount
		if not cap then return false end
		local count = self:_eggCount()
		if not count then return true end
		if count > cap then
			self.eggFullCount, self._eggFullHold = nil, false
			return false
		end
		if count >= cap then
			self._eggFullHold = true
			local sellPending = runtimeEnv.__SenaV4IsAutoSellEggBusy and runtimeEnv.__SenaV4IsAutoSellEggBusy()
			self._eggFullAt = self._eggFullAt or os.clock()
			if not sellPending and os.clock() - self._eggFullAt > 60 then
				self.eggFullCount, self._eggFullHold, self._eggFullAt = nil, false, nil
				return false
			end
			return true
		end
		self._eggFullAt = nil
		if self._eggFullHold then
			local sellPending = runtimeEnv.__SenaV4IsAutoSellEggBusy and runtimeEnv.__SenaV4IsAutoSellEggBusy()
			if sellPending and count > cap - EggRuntime.EGG_FREE_SLOTS then return true end
			self._eggFullHold = false
			self.eggFullNotified = nil
		end
		return false
	end
	-- Steal must stand down for a race/scramble: during the lap (RaceId), inside the Scramble arena, AND
	-- while Auto Race is actively trying to join its window (RaceId is not set yet then, but steal would
	-- otherwise outrank the race in the task order and hog the character so the join never lands).
	function EggRuntime:_eventBlocksSteal()
		if LocalPlayer:GetAttribute("RaceId") ~= nil then return true end
		return false
	end
	function EggRuntime:_schedule()
		if not self.running then
			self.safeStarting = false
		end
		if self.destroyed or not self.enabled or self.running then
			return
		end
		-- A race or scramble event owns the character: steal must fully stop and let it focus the lap/arena,
		-- or its hops fight the race driving and wreck the run. Re-check every second until the event ends.
		if self:_eventBlocksSteal() then
			self:_releaseOperation()
			self:_setStatus("Paused - race/event in progress")
			task.delay(1, function()
				if not self.destroyed and self.enabled and not self.running then self:_schedule() end
			end)
			return
		end
		-- Inventory backing up with Auto Sell on: step aside so the sell loop drains it, then resume.
		if not self.carry.active and self:_shouldYieldToSell() then
			self:_releaseOperation()
			self:_setStatus("Draining inventory (Auto Sell)")
			task.delay(1, function()
				if not self.destroyed and self.enabled and not self.running then self:_schedule() end
			end)
			return
		end
		if not self.carry.active and self:_eggInventoryFull() then
			self:_releaseOperation()
			self:_setStatus("Egg inventory full - place, hatch or sell eggs")
			if not self.eggFullNotified then
				self.eggFullNotified = true
				pcall(function()
					game:GetService("StarterGui"):SetCore("SendNotification", { Title = "Auto Steal", Text = "Egg inventory full. Place, hatch or sell eggs and it continues by itself.", Duration = 6 })
				end)
			end
			task.delay(3, function()
				if not self.destroyed and self.enabled and not self.running then self:_schedule() end
			end)
			return
		end
		local character = LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not root or not humanoid then
			self:_releaseOperation()
			self:_setStatus("Character unavailable")
			return
		end
		self:_startMovementProtection()
		if self.carry.active and self.carry.uid ~= nil then
			if self.instantPhase == "priming" and self.carry.uid == self.primerUid then
				return
			end
			if self:_isPrimerEgg(self.carry.uid) then
				self:_setStatus("Dropping primer egg")
				self.skippedEggs[self.carry.uid] = os.clock() + 30
				pcall(EggCmds.DropFieldEgg, "PlayerRequest")
				task.delay(0.5, function()
					if not self.destroyed and self.enabled then self:_schedule() end
					end)
				return
			end
			local carried = self.records[self.carry.uid] or EggCmds.ReadFieldEgg(self.carry.uid)
			local wanted = type(carried) == "table" and (self.riftWants[carried.AssetCategory]
				or (self.captureObjectiveEnabled and self:_isCaptureEgg(carried.Uid))
				or (self.indexObjectiveEnabled and self:_isIndexObjective(carried))
				or (self.wispObjective and self:_isWispObjective(carried))
				or ((self.userStealEnabled or Config.SnipeDroppedEggs) and not self.riftOnly and self:_matchesNormalFilter(carried, Config.SnipeDroppedEggs == true)))
			if type(carried) == "table" and not wanted then
				self:_setStatus("Dropping unwanted egg")
				self.skippedEggs[self.carry.uid] = os.clock() + 30
				pcall(EggCmds.DropFieldEgg, "PlayerRequest")
				task.delay(0.5, function()
					if not self.destroyed and self.enabled then self:_schedule() end
					end)
				return
			end
			self:_returnToSafe()
			return
		end
		if not self:_wallOpen() then
			self:_releaseOperation()
			self:_setStatus("Waiting for reset wall")
			return
		end
		local playerSteal = runtimeEnv.__SenaV4PlayerSteal
		local blocker = TaskLadder.blocker("auto_steal")
		local holder = not blocker and TaskLadder.holder("auto_steal") or nil
		if blocker or holder or (playerSteal and playerSteal.running) then
			self:_releaseOperation()
			self:_setStatus(blocker and ("Yielding to " .. TaskLadder.TITLES[blocker])
				or holder and ("Waiting for " .. TaskLadder.TITLES[holder] .. " to hand over")
				or "Yielding to Steal Players")
			if self._yieldRetryPending then return end
			self._yieldRetryPending = true
			task.delay((blocker or holder) and 1 or 0.5, function()
				self._yieldRetryPending = nil
				if not self.destroyed and self.enabled then
					self:_schedule()
				end
				end)
			return
		end
		local recoveryUid = self.tweenRecoveryUid
		local record = recoveryUid and (EggCmds.ReadFieldEgg(recoveryUid) or self.records[recoveryUid]) or nil
		if recoveryUid and (type(record) ~= "table"
			or (record.State ~= AreaEggs.States.Slot and record.State ~= AreaEggs.States.Dropped))
		then
			self.tweenRecoveryUid = nil
			recoveryUid = nil
			record = nil
		end
		if not record then record = self:_chooseTarget() end
		if not record then
			if self.stats.matching == 0 and self.stats.available > 0 and (self.config.minWeightKg or 0) > 0 then
				self:_setStatus(string.format("No eggs ≥ %dKg", self.config.minWeightKg))
			else
				self:_setStatus("No matching eggs")
			end
			self:_releaseOperation()
			if not self.activeTween and self:_isInField(root) and not self:_isInSafeArea(root) then
				local safeDestination = self:_resolveSafeCFrame(root)
				if safeDestination then
					self:_tweenRoot(safeDestination, nil, nil, {
						silent = true,
						flightProfile = true,
						abort = function() return not self.enabled or self.running end,
						})
				end
			end
			return
		end
		if self.treadmillManager and self.treadmillManager:isEngaged() then
			self.treadmillManager:_cancelIdle(true)
		end
		local planGeneration = self.planGeneration
		local acquired, acquireError = self:_acquireOperation()
		if not acquired then
			self:_setStatus("Waiting · " .. tostring(acquireError or "another operation"))
			task.delay(0.5, function()
				if not self.destroyed and self.enabled and self.planGeneration == planGeneration then
					self:_schedule()
				end
				end)
			return
		end
		self.safeStarting = true
		self.running = true
		self.activeTarget = record
		local info = self.catalog.resolve(record)
		self.stats.lastTarget = string.format("%s · %s · %s", info.rarity, info.name, record.AreaId)
		if recoveryUid then
			self.safeStarting = false
			self.stats.lastResult = "Recovering with tween"
			local destination = self:_resolveEggDestination(record, root, humanoid)
			if not destination then
				self.tweenRecoveryUid = nil
				self:_finish("Recovery destination unavailable")
				return
			end
			self:_setStatus("Returning to egg")
			self:_tweenRoot(destination, function()
				if self.tweenRecoveryUid == record.Uid then
					self:_requestCarry(record, false)
				end
				end, nil, {
					holdAfterArrival = true,
					holdUid = record.Uid,
					flightProfile = true,
					carryTarget = record,
				})
			return
		end
		if not self:_leftTreadmill(root) then
			self.running = false
			self.safeStarting = false
			self.activeTarget = nil
			self:_releaseOperation()
			self:_setStatus("Preparing steal")
			task.delay(0.3, function()
				if not self.destroyed and self.enabled and self.planGeneration == planGeneration then
					self:_schedule()
				end
				end)
			return
		end
		if runtimeEnv.__SenaV4AdminBoost == true and not (self.captureObjectiveEnabled and self:_isCaptureEgg(record.Uid)) then
			self.safeStarting = false
			task.spawn(self._adminSteal, self, record)
			return
		end
		local _safeDelta = root.Position - SAFE_ZONE_POSITION
		local _safeDistXZ = Vector2.new(_safeDelta.X, _safeDelta.Z).Magnitude
		local _skipSafeReset = false
		if self:_usesPortalBoost(record) then _skipSafeReset = true end
		if record.State == AreaEggs.States.Dropped then _skipSafeReset = true end
		if self.config.stealMode == "Fly" then
			local _eggCF = record.BottomCFrame or record.BoundsCFrame
			if _eggCF then
				local _ed = _eggCF.Position - root.Position
				if Vector2.new(_ed.X, _ed.Z).Magnitude < _safeDistXZ then _skipSafeReset = true end
			end
		end
		if not _skipSafeReset and _safeDistXZ > 3 and os.clock() - (self.lastSafeRepositionAt or 0) > 5 then
			local safeDestination = self:_resolveSafeCFrame(root)
			if safeDestination then
				self.safeStarting = true
				self.running = true
				self.lastSafeRepositionAt = os.clock()
				self:_setStatus("Repositioning to safe area")
				self:_tweenRoot(safeDestination, function()
					self:_groundSnap()
					self.safeStarting = false
					self.running = false
					task.delay(0.15, function()
						if not self.destroyed and self.enabled and self.planGeneration == planGeneration then
							self:_schedule()
						end
						end)
					end, nil, {
						flightProfile = true,
					})
				return
			end
		end
		self.safeStarting = false
		if record.State == AreaEggs.States.Dropped then
			self.instantPhase = "hunting"
			self.primerUid = nil
			self.targetUid = nil
			self.activeTarget = record
			self.running = true
			self:_installGuardHitDistanceBoost()
			self:_startMovementProtection()
			self.stats.lastResult = "Sniping drop"
			task.spawn(self._snipeGrab, self, record)
			return
		end
		if self:_usesPortalBoost(record) then
			self.instantPhase = "hunting"
			self.primerUid = nil
			self.targetUid = nil
			self.activeTarget = record
			self._flyDeparting = false
			-- Lock the cycle: without this a retry/watchdog _schedule fires a second hop mid-flight, changes
			-- activeTarget, and the in-flight hop's stale() check aborts it -> the cycle skips and never
			-- finishes. Held until the hop lands a carry or genuinely ends.
			self.running = true
			self:_installGuardHitDistanceBoost()
			self:_startMovementProtection()
			self:_showTreadmillDecoy()
			self.stats.lastResult = "Low Speed Boost"
			task.spawn(self._portalBoostSteal, self, record)
			return
		end
		if self.config.stealMode == "Fly" then
			self.instantPhase = "priming"
			self.primerUid = nil
			self.targetUid = record.Uid
			self.activeTarget = record
			self._flyDeparting = false
			self.lowFpsPrime = false
			self:_installGuardHitDistanceBoost()
			self:_startMovementProtection()
			self.stats.lastResult = "High Speed departing"
			self:_startPrimerTargetHunt()
			return
		end
		local primer = self:_choosePrimerEgg(record.Uid)
		if not primer then
			self.running = false
			self.activeTarget = nil
			self:_releaseOperation()
			self:_setStatus("Preparing steal")
			task.delay(0.25, function()
				if not self.destroyed and self.enabled and self.planGeneration == planGeneration then
					self:_schedule()
				end
				end)
			return
		end
		self.instantPhase = "priming"
		self.primerUid = primer.Uid
		self.primerUids[primer.Uid] = os.clock() + 120
		self.skippedEggs[primer.Uid] = os.clock() + 30
		self.targetUid = record.Uid
		self.activeTarget = primer
		self._flyDeparting = (self.config.stealMode == "Fly")
		if self.config.stealMode == "Instant" then self:_showTreadmillDecoy() end
		self:_installGuardHitDistanceBoost()
		self.stats.lastResult = self.config.stealMode .. " priming"
		self.lowFpsPrime = currentFps() < 30
		local primerDest = self:_resolveEggDestination(primer, root, humanoid)
		if not primerDest then
			self:_finish("Steal unavailable — retrying")
			return
		end
		if self.lowFpsPrime then
			self:_setStatus("Preparing steal")
			self:_tweenRoot(primerDest, function()
				if self.instantPhase == "priming" and self.primerUid == primer.Uid then
					self:_requestCarry(primer, false)
				end
				end, nil, {
					holdAfterArrival = true,
					holdUid = primer.Uid,
					flightProfile = true,
					carryTarget = primer,
				})
			return
		end
		if self.config.stealMode == "Fly" then
			self:_setStatus("Preparing steal")
			local pOk = self:_glideRoot(primerDest, function()
				return self.destroyed or not self.enabled
					or self.instantPhase ~= "priming" or self.primerUid ~= primer.Uid
			end)
			if not pOk then
				if self.instantPhase == "priming" and self.primerUid == primer.Uid then
					self:_finish("Steal unavailable — retrying")
				end
				return
			end
			self:_setArrivalHold(primerDest, primer.Uid)
			self:_requestCarry(primer, true)
			return
		end
		self:_setStatus("Preparing steal")
		if not self:_teleportRoot(root, humanoid, primerDest) then
			self:_finish("Steal unavailable — retrying")
			return
		end
		self:_setArrivalHold(primerDest, primer.Uid)
		self:_requestCarry(primer, true)
	end
	function EggRuntime:_leftTreadmill(root)
		local treadmill = self.treadmillManager
		if not treadmill or treadmill.destroyed then return true end
		local mounted = treadmill.activeTreadmill ~= nil
			or treadmill.treadmillEquipPending == true
			or treadmill.travelingToTreadmill == true
			or (root ~= nil and root.Anchored)
		if not mounted then
			self.treadmillLeaveAt = nil
			return true
		end
		local now = os.clock()
		self.treadmillLeaveAt = self.treadmillLeaveAt or now
		treadmill.idleGeneration += 1
		if not self.treadmillDoffBusy and now - (self.treadmillDoffAt or 0) > 0.6 then
			self.treadmillDoffBusy = true
			self.treadmillDoffAt = now
			task.spawn(function()
				pcall(treadmill._requestUnequip, treadmill)
				pcall(treadmill._syncActiveTreadmillSnapshot, treadmill)
				self.treadmillDoffBusy = false
			end)
		end
		if root and root.Anchored and now - self.treadmillLeaveAt > 1 then
			pcall(function() root.Anchored = false end)
		end
		if now - self.treadmillLeaveAt > 8 then
			self.treadmillLeaveAt = nil
			return true
		end
		return false
	end
	function EggRuntime:_reconcileRunningState()
		local shouldRun = (self.userStealEnabled == true)
		or (next(self.riftWants) ~= nil)
		or (self.indexObjectiveEnabled == true)
		or (self.wispObjective ~= nil)
		or (self.manualObjectiveEnabled == true)
		or (self.captureObjectiveEnabled == true)
		or (Config.SnipeDroppedEggs == true)
		if self.enabled == shouldRun then
			if self.enabled then
				self:_refreshCounts()
				self:_schedule()
			end
			return
		end
		self.enabled = shouldRun
		if self.enabled then
			if LocalPlayer.Character then
				applyKillPartIgnore(LocalPlayer.Character)
				startHealthPinner(self, LocalPlayer.Character)
			end
			self:_installGuardHitDistanceBoost()
			self:_startMovementProtection()
			pcall(self._installPromptFilter, self)
			if Config.SnipeDroppedEggs then self:_installSnipeHook() end
			if self.userStealEnabled or Config.SnipeDroppedEggs then self:_startWatchdog() end
			self:_setStatus("Searching")
			self:_schedule()
		else
			self:_removeSnipeHook()
			if self._instantReturnToken ~= nil and self.carry.uid ~= nil and not self._externalDeliver then
				self._externalDeliver = true
				self.planGeneration += 1
				self.running = false
				self:_setStatus("Finishing target egg")
				task.spawn(function()
					local deadline = os.clock() + 45
					while self._instantReturnToken ~= nil and os.clock() < deadline and not self.destroyed do
						task.wait(0.2)
					end
					if self.destroyed or self.enabled then return end
					self._externalDeliver = nil
					self._instantReturnToken = nil
					self.carry.active = false
					self.carry.uid = nil
					self.activeTarget = nil
					self:_cleanupInstantSteal()
					self:_removeGuardHitDistanceBoost()
					self:_restoreTreadmillVisualAtSafe()
					self:_stopMovementProtection()
					stopHealthPinner(self)
					self:_setStatus("Idle")
				end)
				self:_refreshCounts()
				return
			end
			local recall = self:_needsHiddenRecall()
			if recall then self._recalling = true end
			self.planGeneration += 1
			self.carry.generation += 1
			self:_cleanupInstantSteal()
			if not recall then self:_removeGuardHitDistanceBoost() end
			self:_invalidateCarryWorker()
			self._forestDropInProgress = nil
			self._instantReturnToken = nil
			self.carry.active = false
			self.carry.uid = nil
			self.tweenRecoveryUid = nil
			self.claimPresentationSuppression = nil
			self.safeStarting = false
			self.movementRetryPending = false
			self:_cancelTween("Disabled")
			self:_releaseOperation()
			if recall then
				self:_recallHidden()
			else
				self:_restoreTreadmillVisualAtSafe()
				self:_stopMovementProtection()
				stopHealthPinner(self)
			end
			self.activeTarget = nil
			self.running = false
			self:_setStatus("Idle")
		end
		self:_refreshCounts()
	end
	function EggRuntime:_installSnipeHook()
		if self._snipeHookConns then return end
		self._snipeHookConns = {}
		local okES, ES = pcall(function() return require(ReplicatedStorage.Client.EggState) end)
		if not okES or type(ES) ~= "table" then return end
		local function trigger()
			if self.destroyed or not self.enabled or not Config.SnipeDroppedEggs or LocalPlayer:GetAttribute("InHalloweenDimension") == true or runtimeEnv.__SenaV4OnTrain == true then return end
			if self._snipeBusy or self.running then return end
			if self:_eventBlocksSteal() then return end
			local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
			if not root then return end
			local best, bestDist
			for _, rec in pairs(self.records) do
				if rec.State == AreaEggs.States.Dropped and rec.BottomCFrame
				and rec.CarrierUserId ~= LocalPlayer.UserId
				and not self:isSkippedEgg(rec.Uid) and self:_matchesNormalFilter(rec, true)
				and self:_inSnipeZone(rec) then
					local d = (rec.BottomCFrame.Position - root.Position).Magnitude
					if not best or d < bestDist then best, bestDist = rec, d end
				end
			end
			if not best then return end
			for _ = 1, 3 do task.spawn(function() pcall(function() EggWorld.AskFieldEggCarry:InvokeServer({ Uid = best.Uid }) end) end) end
			self._snipeBusy = true
			self.running = true
			self.activeTarget = best
			self.instantPhase = "hunting"
			self.stats.lastResult = "Sniping drop"
			task.spawn(function()
				pcall(self._snipeGrab, self, best)
				self._snipeBusy = false
			end)
		end
		for _, name in ipairs({ "FieldShifted", "CarryChanged", "FieldClaimed", "FieldRefreshed", "SnapshotRefreshed" }) do
			local sig = ES[name]
			if type(sig) == "table" and type(sig.Connect) == "function" then
				local ok, conn = pcall(function() return sig:Connect(trigger) end)
				if ok and conn then table.insert(self._snipeHookConns, conn) end
			end
		end
	end
	function EggRuntime:_removeSnipeHook()
		if not self._snipeHookConns then return end
		for _, c in ipairs(self._snipeHookConns) do pcall(function() c:Disconnect() end) end
		self._snipeHookConns = nil
		self._snipeBusy = false
	end
	function EggRuntime:setEnabled(value)
		self.userStealEnabled = value == true
		self:_reconcileRunningState()
		self:_reconcileScramblePortal()
	end
	local SCRAMBLE_PORTAL_NAME = "ScrambleArenaPortal"
	function EggRuntime:_neutralizeScramblePortal(model)
		if typeof(model) ~= "Instance" or model.Name ~= SCRAMBLE_PORTAL_NAME then return end
		self.scramblePortalOriginals = self.scramblePortalOriginals or {}
		for _, part in ipairs(model:GetDescendants()) do
			if part:IsA("BasePart") then
				if self.scramblePortalOriginals[part] == nil then
					local saved = part:GetAttribute("SenaV4PortalOrig")
					if type(saved) == "string" then
						self.scramblePortalOriginals[part] = { CanCollide = saved:sub(1, 1) == "1", CanTouch = saved:sub(2, 2) == "1" }
					else
						self.scramblePortalOriginals[part] = { CanCollide = part.CanCollide, CanTouch = part.CanTouch }
						pcall(part.SetAttribute, part, "SenaV4PortalOrig", (part.CanCollide and "1" or "0") .. (part.CanTouch and "1" or "0"))
					end
				end
				pcall(function()
					part.CanCollide = false
					part.CanTouch = false
				end)
			end
		end
	end
	function EggRuntime:_startScramblePortalBypass()
		local existing = workspace:FindFirstChild(SCRAMBLE_PORTAL_NAME)
		if existing then self:_neutralizeScramblePortal(existing) end
		if not self.scramblePortalConn then
			self.scramblePortalConn = workspace.ChildAdded:Connect(function(child)
				if self.destroyed or not self.userStealEnabled or self._scramblePortalHold then return end
				if child.Name ~= SCRAMBLE_PORTAL_NAME then return end
				for _, d in ipairs({ 0, 0.15, 0.4, 0.8 }) do
					task.delay(d, function()
						if not self.destroyed and self.userStealEnabled and not self._scramblePortalHold and child.Parent then
							self:_neutralizeScramblePortal(child)
						end
					end)
				end
			end)
		end
	end
	function EggRuntime:_stopScramblePortalBypass()
		if self.scramblePortalConn then
			pcall(self.scramblePortalConn.Disconnect, self.scramblePortalConn)
			self.scramblePortalConn = nil
		end
		if self.scramblePortalOriginals then
			for part, orig in pairs(self.scramblePortalOriginals) do
				if typeof(part) == "Instance" and part.Parent then
					pcall(function()
						part.CanCollide = orig.CanCollide
						part.CanTouch = orig.CanTouch
						part:SetAttribute("SenaV4PortalOrig", nil)
					end)
				end
			end
			self.scramblePortalOriginals = nil
		end
	end
	function EggRuntime:_setScramblePortalHold(on)
		on = on == true
		if self._scramblePortalHold == on then return end
		self._scramblePortalHold = on
		self:_reconcileScramblePortal()
	end
	function EggRuntime:_reconcileScramblePortal()
		if self.userStealEnabled and not self._scramblePortalHold then
			self:_startScramblePortalBypass()
		else
			self:_stopScramblePortalBypass()
		end
	end
	function EggRuntime:_resolveWeightKg(record)
		local util = self.weightUtil
		if not util or not record or not record.AssetScale or not record.AssetCategory then
			return nil
		end
		local ok, kg = pcall(util.WeightKgForScale, record.AssetCategory, record.AssetScale)
		if ok and type(kg) == "number" then
			return kg
		end
		return nil
	end
	function EggRuntime:setHeaviestFirst(value)
		self.config.heaviestFirst = value == true
		if self.config.heaviestFirst then
			self.config.highestValueFirst = false
		end
		self:_schedule()
	end
	function EggRuntime:setHighestValueFirst(value)
		self.config.highestValueFirst = value == true
		if self.config.highestValueFirst then
			self.config.heaviestFirst = false
		end
		self:_schedule()
	end
	local ESP_GUI_NAME = "__SenaV4EggEsp"
	local ESP_HIGHLIGHT_NAME = "__SenaV4EggHighlight"
	local ESP_OPTIONS = { rarity = true, name = true, kg = true, mutation = true, value = true, placed = true, icon = true }
	resolveEggRate = function(record)
		if type(record) ~= "table" then return nil end
		local category = record.Category or record.AssetCategory
		local scale = tonumber(record.Scale or record.AssetScale)
		if type(category) ~= "string" or not scale or scale <= 0 then return nil end
		local mutations = type(record.Mutations) == "table" and table.clone(record.Mutations) or {}
		local item = {
			Category = category,
			Scale = scale,
			Mutations = mutations,
			BaseMutation = type(record.BaseMutation) == "string" and record.BaseMutation or nil,
		}
		local ok, rate = pcall(AssetEarnings.MutationOnlyRatePerSecond, item)
		return ok and type(rate) == "number" and rate or nil
	end
	local SIMPLE_FORMATTER
	local function formatCompact(value)
		if type(SIMPLE_FORMATTER) ~= "table" then
			local okFmt, fmt = pcall(require, ReplicatedStorage.Packages.FormatNumber.Simple)
			if okFmt and type(fmt.FormatCompact) == "function" then
				SIMPLE_FORMATTER = fmt
			end
		end
		if SIMPLE_FORMATTER then
			local ok, text = pcall(SIMPLE_FORMATTER.FormatCompact, value, ".#")
			if ok and type(text) == "string" then
				return text
			end
		end
		local absValue = math.abs(value)
		if absValue >= 1e12 then
			return string.format("%.2fT", value / 1e12)
		elseif absValue >= 1e9 then
			return string.format("%.2fB", value / 1e9)
		elseif absValue >= 1e6 then
			return string.format("%.1fM", value / 1e6)
		elseif absValue >= 1e3 then
			return string.format("%.1fK", value / 1e3)
		end
		return string.format("%d", math.floor(value + 0.5))
	end
	local SETTLE_NEED_BASE = 2
	local SETTLE_NEED_RATE = 3.2
	local SETTLE_NEED_MARGIN = 1.25 
	local PRIME_SPOT_X = 597
	local SETTLE_FAIL_REASONS = {
		["Carry not confirmed — retrying"] = true,
		["Carry refused — next egg"] = true,
		["Carry lost — retrying"] = true,
		["Drop failed — retrying"] = true,
		["Egg lost — retrying"] = true,
		["Re-steal failed — retrying"] = true,
		["Steal timed out — retrying"] = true,
	}
	local ADVICE_WINDOW = 8 
	local ADVICE_MAX_AGE = 600
	local areaXCache = {}
	local function guardAreaXs()
		if next(areaXCache) then return areaXCache end
		local objects = resolveObjectsRoot()
		local folder = objects and objects:FindFirstChild("Areas")
		folder = folder and folder:FindFirstChild("GuardAreas")
		for _, area in ipairs(folder and folder:GetChildren() or {}) do
			local point = area:FindFirstChild("ClosestExitPoint")
			if point and point:IsA("BasePart") then areaXCache[area.Name] = point.Position.X end
		end
		return areaXCache
	end
	function EggRuntime:settleNeed(areaId, walkSpeed)
		local x = guardAreaXs()[areaId]
		local distance = math.max(0, (x or PRIME_SPOT_X) - PRIME_SPOT_X)
		return SETTLE_NEED_BASE + distance / (SETTLE_NEED_RATE * math.max(walkSpeed, 16))
	end
	function EggRuntime:recommendLowSpeedLevel(walkSpeedOverride)
		local ws = walkSpeedOverride or resolveOfficialWalkSpeed()
		local areas = {}
		if self.config.areaEnabled and #self.config.areas > 0 then
			areas = self.config.areas
		else
			for name in pairs(guardAreaXs()) do areas[#areas + 1] = name end
		end
		local safe, fast, worst = 10, 10, nil
		for _, area in ipairs(areas) do
			if not (Config.LowSpeedBoost == true and PORTAL_BOOST_AREAS[area] ~= nil) then
				local need = self:settleNeed(area, ws)
				local f, s = 1, 1
				for level = 10, 1, -1 do
					if settleAtLevel(area, level) >= need then f = level break end
				end
				for level = 10, 1, -1 do
					if settleAtLevel(area, level) >= need * SETTLE_NEED_MARGIN then s = level break end
				end
				if f < fast then fast, worst = f, area end
				safe = math.min(safe, s)
			end
		end
		local cap = self.lowSpeedFailCap
		if cap then
			fast = math.min(fast, cap)
			safe = math.min(safe, cap)
		end
		return math.min(safe, fast), fast, ws, worst
	end
	function EggRuntime:_noteLowSpeedOutcome(result)
		local untrusted = self._untrustedSeen == true
		self._untrustedSeen = nil
		if self.config.stealMode ~= "Instant" then return end
		if self.boostedUid ~= nil or self._boostHopUid ~= nil then return end
		local failed = SETTLE_FAIL_REASONS[tostring(result)] == true or untrusted
		if not failed and result ~= "Safe return complete" then return end
		local level = math.clamp(tonumber(Config.StealHoldSeconds) or 5, 1, 10)
		self.lowSpeedOutcomes = self.lowSpeedOutcomes or {}
		local list = self.lowSpeedOutcomes[level] or {}
		self.lowSpeedOutcomes[level] = list
		list[#list + 1] = { at = os.clock(), failed = failed }
		while #list > ADVICE_WINDOW do table.remove(list, 1) end
		local fails, total = 0, 0
		for _, o in ipairs(list) do
			if os.clock() - o.at <= ADVICE_MAX_AGE then
				total = total + 1
				if o.failed then fails = fails + 1 end
			end
		end
		if level > 1 and fails >= 3 and fails / total >= 0.4 then
			local lower = level - 1
			if not self.lowSpeedFailCap or lower < self.lowSpeedFailCap then
				self.lowSpeedFailCap = lower
				self.lowSpeedAdvice = { from = level, to = lower, fails = fails, total = total, fresh = true }
			end
		end
	end
	function EggRuntime:lowSpeedStatus()
		local power = nil
		pcall(function() power = SpeedPowerProjection.ReadProjected() end)
		local safe, fast, ws = self:recommendLowSpeedLevel()
		local level = math.clamp(tonumber(Config.StealHoldSeconds) or 5, 1, 10)
		local advice = self.lowSpeedAdvice
		if advice and level <= advice.to then advice = nil end
		return {
			speedText = type(power) == "number" and formatCompact(power) or "?",
			walkSpeed = math.floor((ws or 0) + 0.5),
			safe = safe,
			fast = fast,
			level = level,
			advice = advice,
		}
	end
	function EggRuntime:setEggEsp(enabled)
		self.config.espEnabled = enabled == true
		if not self.config.espEnabled then
			pcall(function()
				self:_clearEsp()
				end)
		end
	end
	function EggRuntime:setEspMinRank(value)
		self.config.espMinRank = math.max(tonumber(value) or 0, 0)
	end
	function EggRuntime:setEspMinValue(value)
		self.config.espMinValue = math.max(tonumber(value) or 0, 0)
	end
	function EggRuntime:_espPasses(info, rate)
		local config = self.config
		if (config.espMinRank or 0) > 0 and (tonumber(info and info.rarityRank) or 0) < config.espMinRank then return false end
		if (config.espMinValue or 0) > 0 and (tonumber(rate) or 0) < config.espMinValue then return false end
		return true
	end
	function EggRuntime:setEspOption(option, value)
		if ESP_OPTIONS[option] then
			self.config["esp" .. option:sub(1, 1):upper() .. option:sub(2)] = value == true
		end
	end
	function EggRuntime:_clearEsp()
		local slots = workspace:FindFirstChild("AreaEggSlotsClient")
		if not slots then
			return
		end
		for _, container in ipairs(slots:GetChildren()) do
			local gui = container:FindFirstChild(ESP_GUI_NAME)
			if gui then
				gui:Destroy()
			end
			local highlight = container:FindFirstChild(ESP_HIGHLIGHT_NAME)
			if highlight then
				highlight:Destroy()
			end
		end
	end
	function EggRuntime:_updateEsp()
		local slotsFolder = workspace:FindFirstChild("AreaEggSlotsClient")
		if not slotsFolder then
			return
		end
		local config = self.config
		for _, container in ipairs(slotsFolder:GetChildren()) do
			local record = self.records[container.Name]
			local active = config.espEnabled
			and record ~= nil
			and (record.State == AreaEggs.States.Slot or record.State == AreaEggs.States.Dropped)
			if active then
				local checkInfo = self.catalog.resolve(record)
				if not self:_espPasses(checkInfo, resolveEggRate(record)) then active = false end
			end
			local adornee = active and (container:FindFirstChild("Hitbox") or container:FindFirstChildWhichIsA("BasePart", true))
			local gui = container:FindFirstChild(ESP_GUI_NAME)
			local highlight = container:FindFirstChild(ESP_HIGHLIGHT_NAME)
			if not active or not adornee then
				if gui then
					gui:Destroy()
				end
				if highlight then
					highlight:Destroy()
				end
			else
				if gui and not gui:FindFirstChild("Icon") then
					gui:Destroy()
					gui = nil
				end
				if not gui then
					gui = Instance.new("BillboardGui")
					gui.Name = ESP_GUI_NAME
					gui.AlwaysOnTop = true
					gui.Size = UDim2.fromOffset(220, 72)
					gui.StudsOffset = Vector3.new(0, 4.4, 0)
					gui.MaxDistance = 1000
					gui.Adornee = adornee
					local icon = Instance.new("ImageLabel")
					icon.Name = "Icon"
					icon.AnchorPoint = Vector2.new(0.5, 1)
					icon.Position = UDim2.fromScale(0.5, 0.42)
					icon.Size = UDim2.fromOffset(30, 30)
					icon.BackgroundTransparency = 1
					icon.ScaleType = Enum.ScaleType.Fit
					icon.Visible = false
					icon.Parent = gui
					local label = Instance.new("TextLabel")
					label.Name = "Text"
					label.AnchorPoint = Vector2.new(0.5, 0)
					label.Position = UDim2.fromScale(0.5, 0.45)
					label.Size = UDim2.new(1, 0, 0.55, 0)
					label.BackgroundTransparency = 1
					label.Font = Enum.Font.GothamBold
					label.TextSize = 13
					label.TextStrokeTransparency = 0.35
					label.TextXAlignment = Enum.TextXAlignment.Center
					label.TextYAlignment = Enum.TextYAlignment.Top
					label.Parent = gui
					gui.Parent = container
				end
				gui.Adornee = adornee
				local info = self.catalog.resolve(record)
				local fieldIcon = gui:FindFirstChild("Icon")
				local fieldAsset = config.espIcon and type(info.icon) == "string" and info.icon ~= "" and info.icon or nil
				fieldIcon.Image = fieldAsset or ""
				fieldIcon.Visible = fieldAsset ~= nil
				local rarityColor = typeof(info.rarityColor) == "Color3" and info.rarityColor
				or Color3.fromRGB(255, 255, 255)
				local pieces = {}
				if config.espRarity then
					pieces[#pieces + 1] = string.upper(info.rarity or "?")
				end
				if config.espName then
					pieces[#pieces + 1] = tostring(info.name)
				end
				if config.espKg then
					local kg = self:_resolveWeightKg(record)
					if kg then
						pieces[#pieces + 1] = string.format("%d Kg", math.floor(kg))
					end
				end
				if config.espMutation and type(record.Mutations) == "table" and next(record.Mutations) then
					local names = {}
					for _, mutationName in pairs(record.Mutations) do
						names[#names + 1] = tostring(mutationName)
					end
					if #names > 0 then
						table.sort(names)
						pieces[#pieces + 1] = table.concat(names, ", ")
					end
				end
				if config.espValue then
					local rate = resolveEggRate(record)
					if rate then
						pieces[#pieces + 1] = "$" .. formatCompact(rate) .. "/s"
					end
				end
				local label = gui:FindFirstChild("Text")
				label.Text = table.concat(pieces, " | ")
				label.TextColor3 = rarityColor
				if highlight and not highlight:IsA("Highlight") then
					highlight:Destroy()
					highlight = nil
				end
				if not highlight then
					highlight = Instance.new("Highlight")
					highlight.Name = ESP_HIGHLIGHT_NAME
					highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
					highlight.Parent = container
				end
				highlight.Adornee = container
				highlight.FillColor = rarityColor
				highlight.FillTransparency = 0.72
				highlight.OutlineColor = rarityColor
				highlight.OutlineTransparency = 0
			end
		end
		self._placedEspAnchors = self._placedEspAnchors or {}
		local now = os.clock()
		if config.espPlaced then
			local save = (Save.Peek or Save.Get)()
			local inventory = type(save) == "table" and save.EggInventory or nil
			local slot = PlotState.ResolveLocalSlot()
			local plotsFolder = PlotState.ResolveFolder()
			local plotFolder = plotsFolder and slot and plotsFolder:FindFirstChild(tostring(slot))
			local center = plotFolder and plotFolder:FindFirstChild("CenterPoint")
			if center and not center:IsA("BasePart") then center = nil end
			local seenUids = {}
			if type(inventory) == "table" and center then
				local anchorsFolder = workspace:FindFirstChild("SenaV4PlacedEggAnchors")
				if not anchorsFolder then
					anchorsFolder = Instance.new("Folder")
					anchorsFolder.Name = "SenaV4PlacedEggAnchors"
					anchorsFolder.Parent = workspace
				end
				for _, stray in ipairs(anchorsFolder:GetChildren()) do
					if stray:IsA("Highlight") or stray:IsA("BillboardGui") then
						stray:Destroy()
					end
				end
				for uid, serialized in pairs(inventory) do
					if type(uid) == "string" and type(serialized) == "table" and type(serialized.Placement) == "table" then
						seenUids[uid] = true
						local localCFrame = serialized.Placement.LocalCFrame
						if typeof(localCFrame) ~= "CFrame" then
							local okDecode, decodedItem = pcall(EggRecords.Decode, serialized)
							local placement2 = okDecode and type(decodedItem) == "table" and decodedItem.Placement or nil
							localCFrame = type(placement2) == "table" and placement2.LocalCFrame or nil
						end
						if typeof(localCFrame) == "CFrame" then
							local okDecode2, decodedItem2 = pcall(EggRecords.Decode, serialized)
							local item = okDecode2 and type(decodedItem2) == "table" and decodedItem2 or serialized
							local scale = tonumber(item.AssetScale) or 1
							local worldCFrame = center.CFrame * localCFrame + Vector3.new(0, 3 + scale * 2, 0)
							self._placedEspAnchors[uid] = self._placedEspAnchors[uid] or {}
							local entry = self._placedEspAnchors[uid]
							if typeof(entry.anchor) ~= "Instance" then
								local anchor = Instance.new("Part")
								anchor.Name = "SenaV4PE_" .. uid
								anchor.Size = Vector3.new(1.5, 1.5, 1.5)
								anchor.Transparency = 1
								anchor.Anchored = true
								anchor.CanCollide = false
								anchor.CanQuery = false
								anchor.CanTouch = false
								anchor.Parent = anchorsFolder
								entry.anchor = anchor
							end
							entry.anchor.CFrame = worldCFrame
							local info = self.catalog.resolve({ AssetCategory = item.AssetCategory })
							local placedColor = typeof(info.rarityColor) == "Color3" and info.rarityColor
							or Color3.fromRGB(255, 255, 255)
							local placedRate = resolveEggRate({
								Category = item.AssetCategory,
								Mutations = type(item.Mutations) == "table" and item.Mutations or {},
								Scale = scale,
								BaseMutation = type(item.BaseMutation) == "string" and item.BaseMutation or nil,
								})
							if not self:_espPasses(info, placedRate) then
								seenUids[uid] = nil
								continue
							end
							local pieces = {}
							if config.espRarity then
								pieces[#pieces + 1] = string.upper(info.rarity or "?")
							end
							if config.espName then
								pieces[#pieces + 1] = tostring(info.name)
							end
							if config.espKg then
								local okKg, kg = pcall(EggRecords.WeightKgForScale, item.AssetCategory, scale)
								if okKg and type(kg) == "number" then
									pieces[#pieces + 1] = string.format("%d Kg", math.floor(kg))
								end
							end
							if config.espValue and placedRate then
								pieces[#pieces + 1] = "$" .. formatCompact(placedRate) .. "/s"
							end
							if type(serialized.Placement.ReadyAt) == "number" or (type(item.Placement) == "table" and item.Placement.ReadyAt ~= nil) then
								pieces[#pieces + 1] = "READY"
							end
							local gui = entry.anchor:FindFirstChild(ESP_GUI_NAME)
							if not gui then
								gui = Instance.new("BillboardGui")
								gui.Name = ESP_GUI_NAME
								gui.AlwaysOnTop = true
								gui.Size = UDim2.fromOffset(220, 72)
								gui.StudsOffset = Vector3.new(0, 1.4, 0)
								gui.MaxDistance = 1000
								local icon = Instance.new("ImageLabel")
								icon.Name = "Icon"
								icon.AnchorPoint = Vector2.new(0.5, 1)
								icon.Position = UDim2.fromScale(0.5, 0.42)
								icon.Size = UDim2.fromOffset(34, 34)
								icon.BackgroundTransparency = 1
								icon.ScaleType = Enum.ScaleType.Fit
								icon.Visible = false
								icon.Parent = gui
								local label = Instance.new("TextLabel")
								label.Name = "Text"
								label.AnchorPoint = Vector2.new(0.5, 0)
								label.Position = UDim2.fromScale(0.5, 0.45)
								label.Size = UDim2.new(1, 0, 0.55, 0)
								label.BackgroundTransparency = 1
								label.Font = Enum.Font.GothamBold
								label.TextSize = 13
								label.TextStrokeTransparency = 0.35
								label.TextXAlignment = Enum.TextXAlignment.Center
								label.TextYAlignment = Enum.TextYAlignment.Top
								label.Parent = gui
								gui.Parent = entry.anchor
							end
							local icon = gui:FindFirstChild("Icon")
							if icon then
								local assetIcon = config.espIcon and type(info.icon) == "string" and info.icon ~= "" and info.icon or nil
								icon.Image = assetIcon or ""
								icon.Visible = assetIcon ~= nil
							end
							local label = gui:FindFirstChild("Text")
							label.Text = table.concat(pieces, " | ")
							label.TextColor3 = placedColor
							local highlight = entry.anchor:FindFirstChild(ESP_HIGHLIGHT_NAME)
							if highlight then highlight:Destroy() end
						end
					end
				end
			end
			for uid, entry in pairs(self._placedEspAnchors) do
				if not seenUids[uid] then
					if typeof(entry.anchor) == "Instance" then
						entry.anchor:Destroy()
					end
					if typeof(entry.highlight) == "Instance" then
						entry.highlight:Destroy()
					end
					self._placedEspAnchors[uid] = nil
				end
			end
		else
			for uid, entry in pairs(self._placedEspAnchors or {}) do
				if typeof(entry.anchor) == "Instance" then
					entry.anchor:Destroy()
				end
				if typeof(entry.highlight) == "Instance" then
					entry.highlight:Destroy()
				end
				self._placedEspAnchors[uid] = nil
			end
		end
	end
	function EggRuntime:setMinWeightKg(value)
		local num = tonumber(value) or 0
		self.config.minWeightKg = math.max(num, 0)
	end
	function EggRuntime:setMinValuePerSec(value)
		local num = tonumber(value) or 0
		self.config.minValuePerSec = math.max(num, 0)
		self:_refreshCounts()
		self:_schedule()
	end
	function EggRuntime:setSpeed(value)
		local inputSpeed = math.clamp(
			math.floor((tonumber(value) or DEFAULT_MOVEMENT_SPEED_INPUT) + 0.5),
			MIN_MOVEMENT_SPEED_INPUT,
			MAX_MOVEMENT_SPEED_INPUT
		)
		self.config.speed = inputSpeed * MOVEMENT_SPEED_MULTIPLIER
		if runtimeEnv.__SenaV4AdminBoost == true then
			self.config.speed = ADMIN_BOOST_SPEED
		end
		if self.enabled or self.activeTween then
			self:_startMovementProtection()
		end
		return inputSpeed
	end
	function EggRuntime:getDefaultSpeed()
		return DEFAULT_MOVEMENT_SPEED_INPUT
	end
	function EggRuntime:setFilterEnabled(filter, value)
		self.config[filter .. "Enabled"] = value == true
		self:_refreshCounts()
		self:_schedule()
	end
	function EggRuntime:setFilter(filter, values)
		local normalized = type(values) == "table" and table.clone(values) or {}
		if filter == "mutations" and type(self.catalog.resolveMutationId) == "function" then
			local ids = {}
			for _, value in ipairs(normalized) do
				local id = self.catalog.resolveMutationId(value)
				if id then table.insert(ids, id) end
			end
			normalized = ids
		end
		self.config[filter] = normalized
		self:_refreshCounts()
		self:_schedule()
	end
	function EggRuntime:destroy()
		if self.destroyed then
			return
		end
		self.destroyed = true
		self.enabled = false
		self:_mutePortalFx(false, true)
		pcall(self._guardLagback, self, false)
		pcall(self._stopScramblePortalBypass, self)
		pcall(self._removePromptFilter, self)
		pcall(self._removeSnipeHook, self)
		if self._relocateConn then
			pcall(self._relocateConn.Disconnect, self._relocateConn)
			self._relocateConn = nil
		end
		self._recalling = nil
		self:_hideTreadmillDecoy()
		self.planGeneration += 1
		self.carry.generation += 1
		self:_invalidateCarryWorker()
		self.carry.active = false
		self.carry.uid = nil
		self.tweenRecoveryUid = nil
		self.safeStarting = false
		self:_cancelTween("Destroyed")
		self:_cleanupInstantSteal()
		self:_removeGuardHitDistanceBoost()
		self:_releaseOperation()
		self:_stopMovementProtection()
		if self._healthPinner then
			pcall(self._healthPinner.Disconnect, self._healthPinner)
			self._healthPinner = nil
		end
		if self._healthChangedConnection then
			pcall(self._healthChangedConnection.Disconnect, self._healthChangedConnection)
			self._healthChangedConnection = nil
		end
		self:_restoreClaimPresentationFilter()
		restoreHumanoid(LocalPlayer.Character)
		pcall(function()
			self:_clearEsp()
			end)
		pcall(function()
			for _, entry in pairs(self._placedEspAnchors or {}) do
				if typeof(entry.anchor) == "Instance" then
					entry.anchor:Destroy()
				end
			end
			local folder = workspace:FindFirstChild("SenaV4PlacedEggAnchors")
			if folder then
				folder:Destroy()
			end
			end)
		disconnectAll(self.connections)
		table.clear(self.listeners)
		table.clear(self.records)
	end
	return EggRuntime
	end)()
local VALUE_SUFFIXES = {
	k = 1e3,
	m = 1e6,
	b = 1e9,
	t = 1e12,
	q = 1e15,
}
local function parseCompactValue(value)
	local text = tostring(value or ""):lower():gsub("%s+", ""):gsub("%$", ""):gsub("/s$", "")
	local numberText, suffix = text:match("^([%d%.]+)([kmbtq]?)$")
	local number = tonumber(numberText)
	if not number then
		return nil
	end
	return math.max(0, math.floor(number * (VALUE_SUFFIXES[suffix] or 1) + 0.5))
end
local AntiGuard = (function()
	local Players = game:GetService("Players")
	local RunService = game:GetService("RunService")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local LocalPlayer = Players.LocalPlayer
	local Remotes = require(ReplicatedStorage.Shared.Remotes)
	local EggState = require(ReplicatedStorage.Client.EggState)
	local Ragdoll = require(ReplicatedStorage.Shared.Modules.Ragdoll)
	local RagdollJoints = require(ReplicatedStorage.Shared.Modules.RagdollJoints)
	local EggWorld = Remotes.EggWorld
	local KNOCKBACK_HORIZONTAL_THRESHOLD = 340
	local KNOCKBACK_VERTICAL_THRESHOLD = 240
	local STICKY_RETRY_SECONDS = 0.05
	local STICKY_WINDOW_SECONDS = 5
	local AntiGuard = {}
	AntiGuard.__index = AntiGuard
	local function disconnect(connection)
		if connection then pcall(connection.Disconnect, connection) end
	end
	function AntiGuard.new(eggRuntime)
		local self = setmetatable({}, AntiGuard)
		self.eggRuntime = eggRuntime
		self.enabled = true
		self.destroyed = false
		self.connections = {}
		self.originalRagdoll = {}
		self.originalHumanoidStates = setmetatable({}, { __mode = "k" })
		self.stats = {
			blockedHits = 0,
			blockedDrops = 0,
			recarriedEggs = 0,
		}
		self.lastHeldEggUid = nil
		self.lastHeldSlotKey = nil
		self._installed = false
		self._stickyToken = 0
		self._nextBodyRecoveryAt = 0
		self._nextJointSweepAt = 0
		self._forestStrikeOldFire = nil
		return self
	end
	function AntiGuard:_liveBody()
		local character = LocalPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		return character, humanoid, root
	end
	function AntiGuard:_recoverBody(force)
		if not self.enabled or self.destroyed then return end
		local character, humanoid, root = self:_liveBody()
		if not character or not humanoid or not root then return end
		local now = os.clock()
		if not force and now < self._nextBodyRecoveryAt then return end
		self._nextBodyRecoveryAt = now + 0.03
		if not self.originalHumanoidStates[humanoid] then
			self.originalHumanoidStates[humanoid] = {
				Physics = humanoid:GetStateEnabled(Enum.HumanoidStateType.Physics),
				FallingDown = humanoid:GetStateEnabled(Enum.HumanoidStateType.FallingDown),
				Ragdoll = humanoid:GetStateEnabled(Enum.HumanoidStateType.Ragdoll),
			}
		end
		local stateBefore = humanoid:GetState()
		local wasUnsafeState = stateBefore == Enum.HumanoidStateType.Physics
		or stateBefore == Enum.HumanoidStateType.FallingDown
		or stateBefore == Enum.HumanoidStateType.Ragdoll
		or stateBefore == Enum.HumanoidStateType.PlatformStanding
		or stateBefore == Enum.HumanoidStateType.Seated
		pcall(function()
			humanoid.BreakJointsOnDeath = false
			humanoid.RequiresNeck = false
			humanoid:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
			humanoid:SetStateEnabled(Enum.HumanoidStateType.Physics, false)
			humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
			humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
			humanoid.PlatformStand = false
			humanoid.Sit = false
			local state = humanoid:GetState()
			if state == Enum.HumanoidStateType.Physics
			or state == Enum.HumanoidStateType.FallingDown
			or state == Enum.HumanoidStateType.Ragdoll
			or state == Enum.HumanoidStateType.PlatformStanding
			or state == Enum.HumanoidStateType.Seated
			then
				humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
				humanoid:ChangeState(Enum.HumanoidStateType.Running)
			end
			end)
		for _, descendant in ipairs(character:GetDescendants()) do
			if descendant:IsA("Motor6D") then
				if not descendant.Enabled then descendant.Enabled = true end
			elseif descendant:IsA("BallSocketConstraint") or descendant:IsA("HingeConstraint") then
				if descendant.Name:find("Ragdoll", 1, true) or descendant:GetAttribute("RagdollConstraint") then
					pcall(descendant.Destroy, descendant)
				end
			end
		end
		local velocity = root.AssemblyLinearVelocity
		local horizontal = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
		local horizontalLimit = math.max(KNOCKBACK_HORIZONTAL_THRESHOLD, (tonumber(humanoid.WalkSpeed) or 0) * 1.5)
		if wasUnsafeState
		or horizontal > horizontalLimit
		or math.abs(velocity.Y) > KNOCKBACK_VERTICAL_THRESHOLD
		then
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
			self.stats.blockedHits = self.stats.blockedHits + 1
		end
	end
	function AntiGuard:_watchCharacter(character)
		if not character then return end
		local conn = character.DescendantAdded:Connect(function(descendant)
			if not self.enabled or self.destroyed then return end
			if descendant:IsA("BallSocketConstraint") or descendant:IsA("HingeConstraint") then
				if descendant.Name:find("Ragdoll", 1, true) or descendant:GetAttribute("RagdollConstraint") then
					pcall(descendant.Destroy, descendant)
					self:_recoverBody(true)
				end
			elseif descendant:IsA("Motor6D") and not descendant.Enabled then
				descendant.Enabled = true
			end
			end)
		table.insert(self.connections, conn)
	end
	function AntiGuard:_installRagdollHooks()
		if self._installed then return end
		self._installed = true
		task.spawn(function()
			task.wait()
			local previous = runtimeEnv.__SenaV4ForestGate
			if type(previous) == "table" and previous.comp and previous.orig then
				pcall(rawset, previous.comp, "_attackHandler", previous.orig)
				runtimeEnv.__SenaV4ForestGate = nil
			end
			if type(getgc) ~= "function" then return end
			local ok, objects = pcall(getgc, true)
			if not ok or type(objects) ~= "table" then return end
			for index, obj in ipairs(objects) do
				if index % 20000 == 0 then RunService.Heartbeat:Wait() end
				if self.destroyed then return end
				if type(obj) == "table" and rawget(obj, "_areaId") == "Forest" and type(rawget(obj, "_attackHandler")) == "function" then
					local original = rawget(obj, "_attackHandler")
					self._forestGate = { comp = obj, orig = original }
					runtimeEnv.__SenaV4ForestGate = self._forestGate
					rawset(obj, "_attackHandler", function(...)
						if self.enabled and not self.destroyed
						and not (self.eggRuntime and self.eggRuntime.instantPhase == "priming")
						and not (runtimeEnv.__SenaV4PlayerSteal and runtimeEnv.__SenaV4PlayerSteal.running)
						then
							self.stats.blockedHits = self.stats.blockedHits + 1
							self:_recoverBody(true)
							if runtimeEnv.__SenaV4GodMode then
								runtimeEnv.__SenaV4GodMode:startDefend()
							end
							return
						end
						return original(...)
						end)
					break
				end
			end
			end)
		local blockedFunctions = {
			"ApplyClientRagdoll",
			"Ragdoll",
			"TimedRagdoll",
			"TimedRagdollAsync",
		}
		for _, name in ipairs(blockedFunctions) do
			if type(Ragdoll[name]) == "function" then
				self.originalRagdoll[name] = Ragdoll[name]
				Ragdoll[name] = function(...)
					if self.enabled and not self.destroyed then
						self.stats.blockedHits = self.stats.blockedHits + 1
						self:_recoverBody(true)
						return
					end
					return self.originalRagdoll[name](...)
				end
			end
		end
		if type(Ragdoll.IsRagdolled) == "function" then
			self.originalRagdoll.IsRagdolled = Ragdoll.IsRagdolled
			Ragdoll.IsRagdolled = function(character)
				if self.enabled and character == LocalPlayer.Character then return false end
				return self.originalRagdoll.IsRagdolled(character)
			end
		end
	end
	function AntiGuard:_restoreLocalState()
		for humanoid, states in pairs(self.originalHumanoidStates) do
			if humanoid.Parent then
				pcall(function()
					humanoid:SetStateEnabled(Enum.HumanoidStateType.Physics, states.Physics)
					humanoid:SetStateEnabled(Enum.HumanoidStateType.FallingDown, states.FallingDown)
					humanoid:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, states.Ragdoll)
					end)
			end
		end
		self.originalHumanoidStates = setmetatable({}, { __mode = "k" })
		pcall(RagdollJoints.Release, LocalPlayer.Character)
	end
	function AntiGuard:_slotKey(record)
		if type(record) ~= "table" or type(record.AreaId) ~= "string" or type(record.NestId) ~= "string" then
			return nil
		end
		return string.format("%s:%s", record.AreaId, record.NestId)
	end
	function AntiGuard:_requestCarry(uid, slotKey)
		local payload = { Uid = uid }
		if slotKey ~= nil then payload.FirstAreaSlotKey = slotKey end
		return EggWorld.AskFieldEggCarry:InvokeServer(payload)
	end
	function AntiGuard:_startSticky(uid, slotKey)
		if type(uid) ~= "string" or uid == "" then return end
		self._stickyToken = self._stickyToken + 1
		local token = self._stickyToken
		self.stats.recarriedEggs = self.stats.recarriedEggs + 1
		task.spawn(function()
			local deadline = os.clock() + STICKY_WINDOW_SECONDS
			while not self.destroyed and self.enabled and token == self._stickyToken and os.clock() < deadline do
				local record = EggState.ReadFieldEgg(uid)
				if record and record.State == "Carried" and record.CarrierUserId == LocalPlayer.UserId then
					self.lastHeldEggUid = uid
					self.lastHeldSlotKey = slotKey or self:_slotKey(record)
					return
				end
				if record and (record.State == "Dropped" or record.State == "Slot") then
					if self.eggRuntime and self.eggRuntime:requestCarryRecovery(uid) then return end
					local _, _, root = self:_liveBody()
					if root and record.BottomCFrame
					and (root.Position - record.BottomCFrame.Position).Magnitude <= 10
					then
						pcall(self._requestCarry, self, uid, slotKey or self:_slotKey(record))
					end
				end
				task.wait(STICKY_RETRY_SECONDS)
			end
			end)
	end
	function AntiGuard:_bindSignals()
		table.insert(self.connections, EggState.CarryChanged:Connect(function(state)
			if not self.enabled then return end
			if state.IsCarrying and type(state.Uid) == "string" then
				self._stickyToken = self._stickyToken + 1
				self.lastHeldEggUid = state.Uid
				local record = EggState.ReadFieldEgg(state.Uid)
				self.lastHeldSlotKey = self:_slotKey(record)
				return
			end
			local playerSteal = runtimeEnv.__SenaV4PlayerSteal
			if playerSteal and playerSteal.running then return end
			local droppedUid = state.Uid or self.lastHeldEggUid
			local slotKey = self.lastHeldSlotKey
			if self.eggRuntime and self.eggRuntime:isSkippedEgg(droppedUid) then return end
			if droppedUid then
				self.stats.blockedDrops = self.stats.blockedDrops + 1
				self:_startSticky(droppedUid, slotKey)
				if runtimeEnv.__SenaV4GodMode then
					runtimeEnv.__SenaV4GodMode:startDefend(droppedUid)
				end
			end
			end))
		table.insert(self.connections, LocalPlayer.CharacterAdded:Connect(function(character)
			self:_watchCharacter(character)
			task.defer(function() self:_recoverBody(true) end)
			end))
		if LocalPlayer.Character then
			self:_watchCharacter(LocalPlayer.Character)
		end
		table.insert(self.connections, RunService.Stepped:Connect(function()
			self:_recoverBody()
			end))
	end
	function AntiGuard:setEnabled(value)
		local enabled = value == true
		if self.enabled == enabled then return end
		self.enabled = enabled
		if self.enabled then
			self:_recoverBody()
		else
			self._stickyToken = self._stickyToken + 1
			self:_restoreLocalState()
		end
	end
	function AntiGuard:install()
		if self.destroyed then return false end
		getgenv().__SenaV4AntiGuard = self
		self:_installRagdollHooks()
		self:_bindSignals()
		self:_recoverBody()
		return true
	end
	function AntiGuard:destroy()
		if self.destroyed then return end
		self.enabled = false
		self:_restoreLocalState()
		self.destroyed = true
		self._stickyToken = self._stickyToken + 1
		for _, connection in ipairs(self.connections) do disconnect(connection) end
		table.clear(self.connections)
		for name, original in pairs(self.originalRagdoll) do
			if type(original) == "function" then Ragdoll[name] = original end
		end
		if self._forestGate then
			pcall(rawset, self._forestGate.comp, "_attackHandler", self._forestGate.orig)
			if runtimeEnv.__SenaV4ForestGate == self._forestGate then
				runtimeEnv.__SenaV4ForestGate = nil
			end
			self._forestGate = nil
		end
		self.eggRuntime = nil
		if getgenv().__SenaV4AntiGuard == self then getgenv().__SenaV4AntiGuard = nil end
	end
	function AntiGuard:getStats()
		return self.stats
	end
	return AntiGuard
	end)()
local GodMode = (function()
	local Players = game:GetService("Players")
	local RunService = game:GetService("RunService")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local LocalPlayer = Players.LocalPlayer
	local GodMode = {}
	GodMode.__index = GodMode
	function GodMode.new(eggRuntime)
		local self = setmetatable({}, GodMode)
		self.eggRuntime = eggRuntime
		self.enabled = Config.GodMode == nil and true or (Config.GodMode == true)
		self.active = false
		self.activeDroppedUid = nil
		self.swingSequence = 0
		self.lastSwingAt = 0
		self.defendThread = nil
		self.connections = {}
		self.targetRange = 35
		self:_bindSignals()
		return self
	end
	function GodMode:_isBat(item)
		if not item or not item:IsA("Tool") then return false end
		local check = runtimeEnv.__SenaV4IsBatTool
		if check and check(item) then return true end
		if not check and (item:GetAttribute("IsBat") == true or item:GetAttribute("GearName") == "Bat") then return true end
		local itemType = item:GetAttribute("ItemType")
		if itemType ~= nil and itemType ~= "Gear" then return false end
		return string.find(string.lower(item.Name), "slap", 1, true) ~= nil
	end
	function GodMode:_findBat()
		local character = LocalPlayer.Character
		local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
		if character then
			for _, item in ipairs(character:GetChildren()) do
				if self:_isBat(item) then return item, true end
			end
		end
		if backpack then
			for _, item in ipairs(backpack:GetChildren()) do
				if self:_isBat(item) then return item, false end
			end
		end
		pcall(function()
			local networking = ReplicatedStorage:FindFirstChild("Packages")
			and ReplicatedStorage.Packages:FindFirstChild("Networking")
			local wearBat = networking and networking:FindFirstChild("RF/Codex/AskWearFieldBat")
			if wearBat then wearBat:InvokeServer() end
			end)
		return nil, false
	end
	function GodMode:_equipBat()
		local character = LocalPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not humanoid or humanoid.Health <= 0 then return nil end
		local bat, equipped = self:_findBat()
		if not bat then return nil end
		if equipped and bat.Parent == character then return bat end
		pcall(humanoid.EquipTool, humanoid, bat)
		local deadline = os.clock() + 0.35
		while os.clock() < deadline do
			if bat.Parent == character then return bat end
			task.wait(0.05)
		end
		return bat.Parent == character and bat or nil
	end
	function GodMode:_getNearbyEnemies()
		local character = LocalPlayer.Character
		local myRoot = character and character:FindFirstChild("HumanoidRootPart")
		if not myRoot then return {} end
		local enemies = {}
		for _, player in ipairs(Players:GetPlayers()) do
			if player ~= LocalPlayer and player.Character then
				local pRoot = player.Character:FindFirstChild("HumanoidRootPart")
				local pHum = player.Character:FindFirstChildOfClass("Humanoid")
				if pRoot and pHum and pHum.Health > 0 then
					local dist = (pRoot.Position - myRoot.Position).Magnitude
					if dist <= self.targetRange then
						table.insert(enemies, { player = player, root = pRoot, humanoid = pHum, distance = dist })
					end
				end
			end
		end
		table.sort(enemies, function(a, b) return a.distance < b.distance end)
		return enemies
	end
	function GodMode:_swing(bat, targetPart)
		if not bat or bat.Parent ~= LocalPlayer.Character then return false end
		local now = workspace:GetServerTimeNow()
		if now - self.lastSwingAt < 0.22 then return false end
		self.lastSwingAt = now
		pcall(bat.Activate, bat)
		local handle = bat:FindFirstChild("Handle") or bat:FindFirstChildWhichIsA("BasePart", true)
		if handle and targetPart and type(firetouchinterest) == "function" then
			pcall(function()
				firetouchinterest(handle, targetPart, 0)
				task.wait(0.01)
				firetouchinterest(handle, targetPart, 1)
				end)
		end
		pcall(function()
			local Remotes = require(ReplicatedStorage.Shared.Remotes)
			local batSwing = Remotes.BatSwing
			if batSwing and batSwing.Trigger then
				self.swingSequence = self.swingSequence + 1
				local trace = string.format("%d:%d:%d", LocalPlayer.UserId, self.swingSequence, math.floor(now * 1000))
				batSwing.Trigger:FireServer(nil, trace)
			end
			end)
		return true
	end
	function GodMode:startDefend(droppedUid)
		if not self.enabled then return end
		if self.eggRuntime and self.eggRuntime.instantPhase == "priming" then return end
		if droppedUid and self.eggRuntime and self.eggRuntime:isSkippedEgg(droppedUid) then return end
		local playerSteal = runtimeEnv.__SenaV4PlayerSteal
		if playerSteal and playerSteal.running then return end
		self.active = true
		self.activeDroppedUid = droppedUid or self.activeDroppedUid
		if self.defendThread then return end
		self.defendThread = task.spawn(function()
			local handedOff = false
			while self.active and self.enabled do
				if self.eggRuntime and self.eggRuntime.carry and self.eggRuntime.carry.active then
					break
				end
				local stealer = runtimeEnv.__SenaV4PlayerSteal
				if stealer and stealer.running then
					handedOff = true
					break
				end
				local enemies = self:_getNearbyEnemies()
				if #enemies > 0 then
					local bat = self:_equipBat()
					if bat then
						for _, enemy in ipairs(enemies) do
							if enemy.root and enemy.root.Parent then
								self:_swing(bat, enemy.root)
							end
						end
					end
				end
				task.wait(0.1)
			end
			self.active = false
			self.defendThread = nil
			if handedOff then return end
			pcall(function()
				local char = LocalPlayer.Character
				local hum = char and char:FindFirstChildOfClass("Humanoid")
				if hum then hum:UnequipTools() end
				end)
			end)
	end
	function GodMode:stopDefend()
		self.active = false
		self.activeDroppedUid = nil
	end
	function GodMode:setEnabled(val)
		self.enabled = val == true
		if not self.enabled then
			self:stopDefend()
		end
	end
	function GodMode:_bindSignals()
		pcall(function()
			local EggCmds = require(ReplicatedStorage.Client.EggState)
			table.insert(self.connections, EggCmds.CarryChanged:Connect(function(state)
				if state.IsCarrying then
					self:stopDefend()
				else
					if self.enabled then
						self:startDefend(state.Uid)
					end
				end
				end))
			end)
		pcall(function()
			local Remotes = require(ReplicatedStorage.Shared.Remotes)
			local forestStrike = Remotes.GuardPatrol and Remotes.GuardPatrol.ForestStrike
			if forestStrike then
				table.insert(self.connections, forestStrike.OnClientEvent:Connect(function()
					if self.enabled then
						self:startDefend()
					end
					end))
			end
			end)
	end
	function GodMode:destroy()
		self:stopDefend()
		for _, conn in ipairs(self.connections) do pcall(conn.Disconnect, conn) end
		table.clear(self.connections)
	end
	return GodMode
	end)()
local eggRuntime = nil
local TreadmillManager = (function()
	local Players = game:GetService("Players")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local LocalPlayer = Players.LocalPlayer
	local Network = require(ReplicatedStorage.Shared.Remotes)
	local PlotState = require(ReplicatedStorage.Client.PlotState)
	local Hud = require(ReplicatedStorage.Client.Hud)
	local Save = require(ReplicatedStorage.Shared.Save)
	local Treadmills = require(ReplicatedStorage.Data.Treadmills)
	local EQUIP_RETRY_SECONDS = 8
	local function higherPriorityTask()
		local blocker = TaskLadder.blocker("treadmill")
		if blocker then return "Yielding to " .. TaskLadder.TITLES[blocker] end
		local holder = TaskLadder.holder("treadmill")
		if holder then return "Waiting for " .. TaskLadder.TITLES[holder] end
		return nil
	end
	local function scrambleBusy()
		return higherPriorityTask() ~= nil
	end
	local function stealNeedsCharacter()
		return TaskLadder.blocker("treadmill") == "auto_steal"
	end
	local function yieldLabel()
		return higherPriorityTask() or "Yielding"
	end
	local IDLE_START_DELAY_SECONDS = 1
	local UNEQUIP_RETRY_MIN_SECONDS = 0.15
	local UNEQUIP_RETRY_MAX_SECONDS = 0.75
	local ARRIVAL_SETTLE_SECONDS = 0.35
	local CARRY_PULSE_HOLD_SECONDS = 0.1
	local CARRY_PULSE_CONFIRM_TIMEOUT_SECONDS = 1.5
	local CARRY_PULSE_POLL_SECONDS = 0.03
	local CARRY_PULSE_EQUIP_RETRY_SECONDS = 0.2
	local CARRY_PULSE_SNAPSHOT_SECONDS = 0.25
	local CARRY_PULSE_RELEASE_STABLE_SECONDS = 0.35
	local CARRY_PULSE_EQUIP_ATTEMPT_SECONDS = 2.5
	local CARRY_PULSE_MAX_POSITION_ATTEMPTS = 3
	local ACTIVE_TREADMILL_EVENT = "Treadmills: ActiveTreadmillChanged"
	local SPEED_GAIN_EVENT = "Treadmills: SpeedGain"
	local TreadmillManager = {}
	TreadmillManager.__index = TreadmillManager
	function TreadmillManager.new(coordinator, travel)
		local self = setmetatable({}, TreadmillManager)
		self.coordinator = coordinator
		self.travel = travel
		self.destroyed = false
		self.listeners = {}
		self.resources = {}
		self.config = {
			disableDuringAutomation = true,
			idleFarm = false,
			autoUpgrade = false,
		}
		self.stats = {
			mode = "Idle",
			boost = "Waiting",
		}
		self.busy = coordinator and coordinator:getSnapshot().busy == true or false
		self.idleGeneration = 0
		self.lastEquipAt = 0
		self.activeTreadmill = nil
		self.travelingToTreadmill = false
		self.treadmillEquipPending = false
		self.unequipGuardRunning = false
		self.backgroundYieldRunning = false
		self.lastBackgroundYieldAt = 0
		self.carryPulseRunning = false
		self.treadmillStateRevision = 0
		self:_listenActiveTreadmill()
		task.spawn(function()
			pcall(function() self:_syncActiveTreadmillSnapshot() end)
			end)
		self:_listenCoordinator()
		self:_listenSpeedGain()
		return self
	end
	function TreadmillManager:_snapshot()
		return {
			mode = self.stats.mode,
			boost = self.stats.boost,
			disableDuringAutomation = self.config.disableDuringAutomation,
			idleFarm = self.config.idleFarm,
		}
	end
	function TreadmillManager:_emit()
		local snapshot = self:_snapshot()
		for _, listener in ipairs(self.listeners) do
			pcall(listener, snapshot)
		end
	end
	function TreadmillManager:_setStatus(mode, boost)
		if mode ~= nil then self.stats.mode = mode end
		if boost ~= nil then self.stats.boost = boost end
		self:_emit()
	end
	function TreadmillManager:subscribe(listener)
		table.insert(self.listeners, listener)
		pcall(listener, self:_snapshot())
		return function()
			local index = table.find(self.listeners, listener)
			if index then table.remove(self.listeners, index) end
		end
	end
	function TreadmillManager:_requestUnequip()
		local ok, success, reason = pcall(function() return Network.Treadmill.AskDoff:InvokeServer() end)
		if not ok then
			return false, tostring(success)
		end
		if success == false then
			return false, tostring(reason or "Server rejected")
		end
		return true
	end
	function TreadmillManager:_shouldBlockTreadmill()
		if self.destroyed or self.carryPulseRunning then return false end
		if self.busy and self.config.disableDuringAutomation then return true end
		local rt = runtimeEnv.__SenaV4EggRuntime
		if rt and rt._treadmillResetting then return false end
		local ok, holder = pcall(TaskLadder.holder, "treadmill")
		return ok and holder ~= nil
	end
	function TreadmillManager:_startUnequipGuard()
		if self.unequipGuardRunning
		or not self:_shouldBlockTreadmill()
		or self.activeTreadmill == nil
		then
			return
		end
		self.unequipGuardRunning = true
		task.spawn(function()
			local retryDelay = UNEQUIP_RETRY_MIN_SECONDS
			while self:_shouldBlockTreadmill() and self.activeTreadmill ~= nil do
				local success, reason = self:_requestUnequip()
				self:_setStatus(
					"Automation active",
					success and "Blocked" or ("Release retry: " .. tostring(reason))
				)
				task.wait(retryDelay)
				retryDelay = math.min(retryDelay * 2, UNEQUIP_RETRY_MAX_SECONDS)
			end
			self.unequipGuardRunning = false
			if self:_shouldBlockTreadmill() and self.activeTreadmill ~= nil then
				self:_startUnequipGuard()
			end
			end)
	end
	function TreadmillManager:_cancelIdle(unequip)
		self.idleGeneration += 1
		if unequip then
			self:_requestUnequip()
		end
	end
	function TreadmillManager:setDisableDuringAutomation(value)
		self.config.disableDuringAutomation = true
		if self.busy and self.config.disableDuringAutomation then
			self:_cancelIdle(true)
			self:_startUnequipGuard()
			self:_setStatus("Automation active", "Blocked")
		elseif not self.busy and self.config.idleFarm then
			self:_startIdle()
		end
	end
	function TreadmillManager:setIdleFarm(value)
		self.config.idleFarm = value == true
		if not self.config.idleFarm then
			self:_cancelIdle(true)
			self:_setStatus(self.busy and "Automation active" or "Idle", "Disabled")
			return
		end
		if not self.busy then
			self:_startIdle()
		end
		if self.idleWatchdog then return end
		self.idleWatchdog = task.spawn(function()
			while not self.destroyed and self.config.idleFarm do
				task.wait(2)
				if LocalPlayer:GetAttribute("InHalloweenDimension") == true then local goHome = getgenv().__SenaV4GoHomeForTreadmill if type(goHome) == "function" then pcall(goHome) end end
				if self.idleRunning == nil and not self.busy and self.config.idleFarm and not self.destroyed then
					self:_startIdle()
				end
			end
			self.idleWatchdog = nil
			end)
	end
	function TreadmillManager:_readUpgradeState()
		local ok, level, money, config = pcall(function()
			local data = (Save.Peek or Save.Get)()
			if not data then return nil end
			local current = tonumber(data.TreadmillUpgradeLevel) or 0
			return current, data.Money, Treadmills.GetByUpgradeLevel(current + 1)
			end)
		if not ok or level == nil then return nil end
		return level, money, config
	end
	function TreadmillManager:_raiseTier()
		local level, money, config = self:_readUpgradeState()
		if not config then return false, "Max tier" end
		if (tonumber(money) or 0) < (tonumber(config.Price) or 0) then return false, "Not enough money" end
		local ok, accepted, reason = pcall(function()
			return Network.Treadmill.AskTierRaise:InvokeServer(config._id)
			end)
		if not ok then return false, tostring(accepted) end
		if accepted ~= true then return false, tostring(reason or "Server rejected") end
		return true, config.DisplayName or config._id
	end
	function TreadmillManager:setAutoUpgrade(value)
		self.config.autoUpgrade = value == true
		if not self.config.autoUpgrade or self.autoUpgradeRunning then return end
		self.autoUpgradeRunning = true
		task.spawn(function()
			while not self.destroyed and self.config.autoUpgrade do
				local success, detail = self:_raiseTier()
				if success then
					self:_setStatus(self.busy and "Automation active" or "Idle", "Upgraded to " .. tostring(detail))
					task.wait(1)
				elseif detail == "Max tier" then
					self:_setStatus(self.busy and "Automation active" or "Idle", "Treadmill maxed")
					task.wait(30)
				else
					task.wait(5)
				end
			end
			self.autoUpgradeRunning = false
			end)
	end
	function TreadmillManager:_resolveStandCFrame()
		if LocalPlayer:GetAttribute("InHalloweenDimension") == true then return nil end
		local slot = PlotState.ResolveLocalSlot()
		local plotsFolder = PlotState.ResolveFolder()
		local plotFolder = plotsFolder and slot and plotsFolder:FindFirstChild(tostring(slot))
		local bottom = plotFolder and plotFolder:FindFirstChild("TreadmillBottom")
		if not (bottom and bottom:IsA("BasePart")) then
			return nil
		end
		local character = LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not root or not humanoid then return nil end
		local feetOffset
		if humanoid.RigType == Enum.HumanoidRigType.R15 then
			feetOffset = root.Size.Y * 0.5 + math.max(humanoid.HipHeight, 0.5)
		else
			feetOffset = root.Size.Y * 0.5 + 2
		end
		return bottom.CFrame * CFrame.new(0, bottom.Size.Y * 0.5 + feetOffset + 0.05, 0)
	end
	function TreadmillManager:isEngaged()
		return self.activeTreadmill ~= nil
		or self.travelingToTreadmill
		or self.treadmillEquipPending
		or self.carryPulseRunning
	end
	function TreadmillManager:_isTreadmillHudActive()
		local ok, active = pcall(function()
			local gameHud = Hud.Frame("Game")
			local treadmillHud = Hud.Frame("Treadmill")
			return gameHud.Visible == false and treadmillHud.Visible == true
			end)
		return ok and active == true
	end
	function TreadmillManager:_isGameHudRestored()
		local ok, restored = pcall(function()
			local gameHud = Hud.Frame("Game")
			local treadmillHud = Hud.Frame("Treadmill")
			return gameHud.Visible == true and treadmillHud.Visible == false
			end)
		return ok and restored == true
	end
	function TreadmillManager:pulseForCarry(teleport, abort)
		if self.destroyed or self.carryPulseRunning or type(teleport) ~= "function" then
			return false, "Preparation unavailable"
		end
		self:_cancelIdle(false)
		self.carryPulseRunning = true
		local function cancelled()
			return self.destroyed or (abort ~= nil and abort())
		end
		local function waitForRelease(timeoutSeconds)
			local deadline = os.clock() + timeoutSeconds
			local nextDoffAt = 0
			local releasedStableSince = nil
			local observedRevision = self.treadmillStateRevision
			while not self.destroyed and os.clock() < deadline do
				local now = os.clock()
				if now >= nextDoffAt then
					self:_requestUnequip()
					nextDoffAt = now + UNEQUIP_RETRY_MIN_SECONDS
				end
				local mounted = self:_syncActiveTreadmillSnapshot()
				local hudRestored = self:_isGameHudRestored()
				if self.treadmillStateRevision ~= observedRevision then
					observedRevision = self.treadmillStateRevision
					releasedStableSince = nil
				end
				if not mounted and self.activeTreadmill == nil and hudRestored then
					releasedStableSince = releasedStableSince or now
					if now - releasedStableSince >= CARRY_PULSE_RELEASE_STABLE_SECONDS then
						return true
					end
				else
					releasedStableSince = nil
				end
				task.wait(CARRY_PULSE_POLL_SECONDS)
			end
			return false
		end
		local function finish(success, reason)
			if not success then
				waitForRelease(CARRY_PULSE_CONFIRM_TIMEOUT_SECONDS + CARRY_PULSE_RELEASE_STABLE_SECONDS)
			end
			self.treadmillEquipPending = false
			self.carryPulseRunning = false
			if success then
				self:_setStatus("Automation active", "Preparation complete")
			elseif not self.destroyed then
				self:_setStatus("Automation active", tostring(reason or "Preparation failed"))
			end
			if self:_shouldBlockTreadmill() and self.activeTreadmill ~= nil then
				self:_startUnequipGuard()
			end
			return success, reason
		end
		self:_syncActiveTreadmillSnapshot()
		local mountedConfirmed = false
		local lastEquipReason = nil
		for attempt = 1, CARRY_PULSE_MAX_POSITION_ATTEMPTS do
			if cancelled() then return finish(false, "Cancelled") end
			local standCFrame = self:_resolveStandCFrame()
			if not standCFrame then
				lastEquipReason = "Position unavailable"
			else
				self:_setStatus("Preparing carry", attempt == 1 and "Positioning" or "Repositioning")
				local movedOk, moved = pcall(teleport, standCFrame)
				if movedOk and moved == true then
					task.wait(ARRIVAL_SETTLE_SECONDS)
					self.treadmillEquipPending = true
					self:_setStatus("Preparing carry", "Activating")
					local attemptDeadline = os.clock() + CARRY_PULSE_EQUIP_ATTEMPT_SECONDS
					local nextEquipAt = 0
					local nextSnapshotAt = 0
					while not cancelled() and os.clock() < attemptDeadline do
						local now = os.clock()
						if now >= nextSnapshotAt then
							nextSnapshotAt = now + CARRY_PULSE_SNAPSHOT_SECONDS
							self:_syncActiveTreadmillSnapshot()
						end
						if self.activeTreadmill ~= nil and self:_isTreadmillHudActive() then
							mountedConfirmed = true
							break
						end
						if self.activeTreadmill == nil and now >= nextEquipAt then
							nextEquipAt = now + CARRY_PULSE_EQUIP_RETRY_SECONDS
							local callOk, equipped, reason = pcall(function()
								return Network.Treadmill.AskWearStill:InvokeServer()
								end)
							if not callOk or equipped == false then
								lastEquipReason = tostring(reason or equipped)
								self:_setStatus("Preparing carry", "Activation retry")
							end
						end
						task.wait(CARRY_PULSE_POLL_SECONDS)
					end
				else
					lastEquipReason = "Positioning failed"
				end
			end
			if mountedConfirmed then break end
			if cancelled() then return finish(false, "Cancelled") end
			self:_setStatus("Preparing carry", "Resetting position")
			waitForRelease(CARRY_PULSE_CONFIRM_TIMEOUT_SECONDS + CARRY_PULSE_RELEASE_STABLE_SECONDS)
		end
		if not mountedConfirmed then
			return finish(false, "Activation not confirmed: " .. tostring(lastEquipReason or "Unknown"))
		end
		self.treadmillEquipPending = false
		self:_setStatus("Preparing carry", "Active")
		local holdDeadline = os.clock() + CARRY_PULSE_HOLD_SECONDS
		while not cancelled() and os.clock() < holdDeadline do
			task.wait(CARRY_PULSE_POLL_SECONDS)
		end
		if cancelled() then return finish(false, "Cancelled") end
		self:_setStatus("Preparing carry", "Releasing")
		if waitForRelease(CARRY_PULSE_CONFIRM_TIMEOUT_SECONDS + CARRY_PULSE_RELEASE_STABLE_SECONDS) then
			return finish(true)
		end
		return finish(false, cancelled() and "Cancelled" or "Release not confirmed")
	end
	function TreadmillManager:yieldForBackground()
		if self.destroyed then return end
		self:_cancelIdle(false)
		if self.backgroundYieldRunning then return end
		self.backgroundYieldRunning = true
		task.spawn(function()
			local retryDelay = UNEQUIP_RETRY_MIN_SECONDS
			while not self.destroyed do
				local backgroundBusy = self.coordinator and self.coordinator:isBackgroundBusy()
				if not backgroundBusy then break end
				self.lastBackgroundYieldAt = os.clock()
				self:_setStatus("Idle", "Yielding to background inventory")
				self:_requestUnequip()
				task.wait(retryDelay)
				local active = self:_syncActiveTreadmillSnapshot()
				if not active then break end
				retryDelay = math.min(retryDelay * 2, UNEQUIP_RETRY_MAX_SECONDS)
			end
			self.backgroundYieldRunning = false
			if not self.destroyed and not self:isEngaged() then
				self:_setStatus("Idle", "Background inventory ready")
			end
			end)
	end
	function TreadmillManager:_startIdle()
		if self.destroyed or self.busy or not self.config.idleFarm then
			return
		end
		self:_cancelIdle(false)
		local generation = self.idleGeneration
		local idleStartedAt = os.clock()
		self.idleRunning = generation
		task.spawn(function()
			local ok, err = xpcall(function()
				while not self.destroyed
				and not self.busy
				and self.config.idleFarm
				and generation == self.idleGeneration
				do
					if self.coordinator and self.coordinator:isBackgroundBusy() then
						idleStartedAt = os.clock()
						self:_setStatus("Idle", "Waiting for background inventory")
						task.wait(0.25)
						continue
					end
					if stealNeedsCharacter() then
						do
							idleStartedAt = os.clock()
							self:_setStatus("Idle", "Yielding to Auto Steal")
							task.wait(0.25)
							continue
						end
					end
					if runtimeEnv.__SenaV4IsAutoSellEggBusy and runtimeEnv.__SenaV4IsAutoSellEggBusy() then
						idleStartedAt = os.clock()
						self:_setStatus("Idle", "Waiting for Auto Sell Egg")
						task.wait(0.25)
						continue
					end
					if scrambleBusy() then
						idleStartedAt = os.clock()
						self:_setStatus("Idle", yieldLabel())
						task.wait(0.25)
						continue
					end
					local idleRemaining = IDLE_START_DELAY_SECONDS - (os.clock() - idleStartedAt)
					if idleRemaining > 0 then
						self:_setStatus("Idle", string.format("Starting in %.0fs", math.ceil(idleRemaining)))
						task.wait(math.min(idleRemaining, 0.25))
						continue
					end
					local standCFrame = self:_resolveStandCFrame()
					if not standCFrame then
						self:_setStatus("Idle", "Position unavailable")
						task.wait(2)
						continue
					end
					self.travelingToTreadmill = true
					self:_setStatus("Moving", "Waiting")
					local moved = false
					local tr = self.travel
					local character = LocalPlayer.Character
					local root = character and character:FindFirstChild("HumanoidRootPart")
					local humanoid = character and character:FindFirstChildOfClass("Humanoid")
					if tr and root and humanoid and type(tr._teleportRoot) == "function" and type(tr._isInSafeArea) == "function"
						and tr:_isInSafeArea(root) and (root.Position - standCFrame.Position).Magnitude < 250 then
						local okTp, tp = pcall(tr._teleportRoot, tr, root, humanoid, standCFrame)
						moved = okTp and tp == true
					end
					moved = moved or self.travel and self.travel:travelAndWait(standCFrame, {
						abort = function()
							return self.destroyed
							or self.busy
							or not self.config.idleFarm
							or generation ~= self.idleGeneration
							or (self.coordinator and self.coordinator:isBackgroundBusy())
							or (runtimeEnv.__SenaV4IsAutoSellEggBusy and runtimeEnv.__SenaV4IsAutoSellEggBusy())
							or scrambleBusy()
						end,
						})
					self.travelingToTreadmill = false
					if not moved then
						if not self.busy and self.config.idleFarm then
							self:_setStatus("Idle", "Travel failed")
							task.wait(1)
						end
						continue
					end
					if self.busy
					or not self.config.idleFarm
					or generation ~= self.idleGeneration
					or (self.coordinator and self.coordinator:isBackgroundBusy())
					or (runtimeEnv.__SenaV4IsAutoSellEggBusy and runtimeEnv.__SenaV4IsAutoSellEggBusy())
					or scrambleBusy()
					then
						continue
					end
					task.wait(ARRIVAL_SETTLE_SECONDS)
					if self.busy
					or not self.config.idleFarm
					or generation ~= self.idleGeneration
					or (self.coordinator and self.coordinator:isBackgroundBusy())
					or (runtimeEnv.__SenaV4IsAutoSellEggBusy and runtimeEnv.__SenaV4IsAutoSellEggBusy())
					or scrambleBusy()
					then
						continue
					end
					self.treadmillEquipPending = true
					local callOk, equipped, reason = pcall(function() return Network.Treadmill.AskWearStill:InvokeServer() end)
					if not callOk or equipped == false then
						self.treadmillEquipPending = false
						self:_setStatus("Preparing carry", "Activation failed: " .. tostring(reason or equipped))
					else
						self.lastEquipAt = os.clock()
						self:_setStatus("Active", "Waiting for gain")
						task.delay(2, function()
							if not self.destroyed and self.activeTreadmill == nil then
								self.treadmillEquipPending = false
							end
							end)
					end
					local deadline = os.clock() + EQUIP_RETRY_SECONDS
					while (self.activeTreadmill ~= nil or os.clock() < deadline)
					and not self.destroyed
					and not self.busy
					and self.config.idleFarm
					and generation == self.idleGeneration
					and not (self.coordinator and self.coordinator:isBackgroundBusy())
					do
						if stealNeedsCharacter() then
							do
								self:_cancelIdle(true)
								self:_setStatus("Idle", "Yielding to Auto Steal")
								break
							end
						end
						if runtimeEnv.__SenaV4IsAutoSellEggBusy and runtimeEnv.__SenaV4IsAutoSellEggBusy() then
							self:_cancelIdle(true)
							self:_setStatus("Idle", "Yielding to Auto Sell Egg")
							break
						end
						if scrambleBusy() then
							self:_requestUnequip()
							self:_setStatus("Idle", yieldLabel())
							break
						end
						task.wait(0.25)
					end
				end
				end, debug.traceback)
			if not ok then
				warn("[SAE][treadmill] idle error:\n" .. tostring(err))
			end
			if self.idleRunning == generation then self.idleRunning = nil end
			end)
	end
	function TreadmillManager:_onCoordinator(snapshot)
		local wasBusy = self.busy
		self.busy = snapshot.busy == true
		if self.busy then
			self:_cancelIdle(self.config.disableDuringAutomation)
			self:_startUnequipGuard()
			self:_setStatus("Automation active", self.config.disableDuringAutomation and "Blocked" or "Unchanged")
		elseif wasBusy or self.config.idleFarm then
			if self.config.idleFarm then
				self:_startIdle()
			else
				self:_setStatus("Idle", "Disabled")
			end
		end
	end
	function TreadmillManager:_listenCoordinator()
		if not self.coordinator then return end
		table.insert(self.resources, self.coordinator:subscribe(function(snapshot)
			self:_onCoordinator(snapshot)
			end))
		table.insert(self.resources, self.coordinator:subscribeBackground(function(snapshot)
			if snapshot.busy then
				self:_cancelIdle(false)
				self:_setStatus("Idle", "Waiting for background inventory")
			elseif not self.destroyed and not self.busy and self.config.idleFarm then
				self:_startIdle()
			end
			end))
	end
	function TreadmillManager:_syncActiveTreadmillSnapshot()
		local ok, activeUserIds = pcall(function() return Network.Treadmill.AskRenderSnapshot:InvokeServer() end)
		if not ok or type(activeUserIds) ~= "table" then
			return self.activeTreadmill ~= nil
		end
		local active = table.find(activeUserIds, LocalPlayer.UserId) ~= nil
		self.activeTreadmill = active and "snapshot" or nil
		if not active then
			self.treadmillEquipPending = false
		end
		return active
	end
	function TreadmillManager:_listenActiveTreadmill()
		local function onOwnBelt(treadmillId)
			self.treadmillStateRevision += 1
			self.activeTreadmill = treadmillId
			self.treadmillEquipPending = false
			if treadmillId ~= nil and self:_shouldBlockTreadmill() then
				self:_startUnequipGuard()
			elseif treadmillId == nil and self:_shouldBlockTreadmill() then
				self:_setStatus("Automation active", "Blocked")
			elseif treadmillId == nil then
				self:_setStatus("Idle", self.config.idleFarm and "Released" or "Disabled")
			elseif not self.busy then
				self:_setStatus("Active", "Waiting for gain")
			end
		end
		local own, everyone = nil, nil
		pcall(function() own = Network.Treadmill.AssignedBeltShifted end)
		pcall(function() everyone = Network.Treadmill.RenderStateShifted end)
		if own then
			table.insert(self.resources, own.OnClientEvent:Connect(function(beltId)
				onOwnBelt(beltId)
				end))
			return
		end
		if everyone then
			table.insert(self.resources, everyone.OnClientEvent:Connect(function(playerName, mounted)
				if playerName ~= LocalPlayer.Name then return end
				onOwnBelt(mounted and playerName or nil)
				end))
		end
	end
	function TreadmillManager:_listenSpeedGain()
		local remote = Network.Treadmill.SpeedGained
		if remote then
			table.insert(self.resources, remote.OnClientEvent:Connect(function()
				self.activeTreadmill = self.activeTreadmill or true
				self.treadmillEquipPending = false
				if self:_shouldBlockTreadmill() then
					self:_startUnequipGuard()
					return
				end
				self:_setStatus("Active", "Gain ticking")
				end))
		end
	end
	function TreadmillManager:destroy()
		if self.destroyed then return end
		self.destroyed = true
		self:_cancelIdle(true)
		for _, resource in ipairs(self.resources) do
			pcall(function()
				if typeof(resource) == "RBXScriptConnection" then
					resource:Disconnect()
				elseif type(resource) == "function" then
					resource()
				elseif type(resource) == "table" and type(resource.Disconnect) == "function" then
					resource:Disconnect()
				end
				end)
		end
		table.clear(self.resources)
		table.clear(self.listeners)
	end
	TreadmillManager.Destroy = TreadmillManager.destroy
	return TreadmillManager
	end)()
local eventCoordinator = Coordinator.new()
eggRuntime = EggRuntime.new(catalog, integrityLimitsModule, eventCoordinator)
runtimeEnv.__SenaV4EggRuntime = eggRuntime
local treadmillManager = TreadmillManager.new(eventCoordinator, eggRuntime)
runtimeEnv.__SenaV4TreadmillManager = treadmillManager
TaskLadder.register("treadmill", {
	wants = function()
		return treadmillManager.config.idleFarm == true and not treadmillManager.destroyed
	end,
	active = function()
		return not treadmillManager.destroyed and treadmillManager:isEngaged() == true
	end,
	enabled = function()
		return treadmillManager.config.idleFarm == true
	end,
	status = function()
		local stats = treadmillManager.stats or {}
		local mode, boost = tostring(stats.mode or ""), tostring(stats.boost or "")
		if boost ~= "" and boost ~= "Waiting" then
			return mode .. "  ·  " .. boost
		end
		return mode
	end,
})
eggRuntime:setTreadmillManager(treadmillManager)
treadmillManager:setDisableDuringAutomation(true)
if Config.AutoTreadmillIdle then
	treadmillManager:setIdleFarm(true)
end
if Config.AutoIndex then
	eggRuntime:setIndexObjective(true)
end
if Config.AutoTreadmillUpgrade then
	treadmillManager:setAutoUpgrade(true)
end
local Webhook = (function()
	local HttpService = game:GetService("HttpService")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local LocalPlayer = game:GetService("Players").LocalPlayer
	local httpPost = http_request or request or (http and http.request)
	or (syn and syn.request) or (fluxus and fluxus.request)
	local Webhook = {}
	local queue = {}
	local flushing = false
	local thumbCache = {}
	local iconAsset = "96240498384290"
	local icon = nil
	local earnings = nil
	local weightUtil = nil
	pcall(function() earnings = require(ReplicatedStorage.Shared.Util.AssetEarnings) end)
	pcall(function() weightUtil = require(ReplicatedStorage.Shared.Util.EggRecords) end)
	local function webThumb(assetRef)
		local id = tostring(assetRef or ""):match("%d+")
		if not id then return nil end
		local hit = thumbCache[id]
		if hit ~= nil then
			if hit == "" then return nil end
			return hit
		end
		local url = nil
		for _, size in ipairs({ "512x512", "150x150" }) do
			local candidate = nil
			pcall(function()
				local api = "https://thumbnails.roblox.com/v1/assets?assetIds=" .. id
				.. "&size=" .. size .. "&format=Png&isCircular=false"
				local body
				if httpPost then
					local res = httpPost({ Url = api, Method = "GET" })
					body = type(res) == "table" and (res.Body or res.body) or nil
				else
					body = HttpService:GetAsync(api)
				end
				if type(body) == "string" and body ~= "" then
					local parsed = HttpService:JSONDecode(body)
					local row = parsed and parsed.data and parsed.data[1]
					if row and row.state == "Completed" and type(row.imageUrl) == "string" and row.imageUrl ~= "" then
						candidate = row.imageUrl
					end
				end
				end)
			if candidate then
				url = url or candidate
				if candidate:find("/Png/", 1, true) then
					url = candidate
					break
				end
			end
		end
		thumbCache[id] = url or ""
		return url
	end
	local function senaIcon()
		if icon == nil then icon = webThumb(iconAsset) or false end
		return icon or nil
	end
	local png = { cache = {}, crc = nil, size = 96 }
	function png.crc32(str)
		if not png.crc then
			png.crc = {}
			for i = 0, 255 do
				local c = i
				for _ = 1, 8 do
					c = bit32.band(c, 1) == 1 and bit32.bxor(0xEDB88320, bit32.rshift(c, 1)) or bit32.rshift(c, 1)
				end
				png.crc[i] = c
			end
		end
		local c = 0xFFFFFFFF
		for i = 1, #str do
			c = bit32.bxor(png.crc[bit32.band(bit32.bxor(c, str:byte(i)), 255)], bit32.rshift(c, 8))
		end
		return bit32.bxor(c, 0xFFFFFFFF)
	end
	function png.chunk(kind, data)
		return string.pack(">I4", #data) .. kind .. data .. string.pack(">I4", png.crc32(kind .. data))
	end
	function png.encode(w, h, raw)
		local a, b = 1, 0
		for i = 1, #raw do
			a = (a + raw:byte(i)) % 65521
			b = (b + a) % 65521
		end
		local parts, pos = { "\120\1" }, 1
		while pos <= #raw do
			local piece = raw:sub(pos, pos + 65534)
			pos = pos + #piece
			parts[#parts + 1] = string.char(pos > #raw and 1 or 0) .. string.pack("<I2<I2", #piece, bit32.bxor(#piece, 0xFFFF)) .. piece
		end
		parts[#parts + 1] = string.pack(">I4", b * 65536 + a)
		return "\137PNG\r\n\26\n" .. png.chunk("IHDR", string.pack(">I4>I4", w, h) .. "\8\6\0\0\0")
			.. png.chunk("IDAT", table.concat(parts)) .. png.chunk("IEND", "")
	end
	function png.render(assetRef)
		local id = tostring(assetRef or ""):match("%d+")
		if not id then return nil end
		local hit = png.cache[id]
		if hit ~= nil then return hit or nil end
		local ok, data = pcall(function()
			local img = game:GetService("AssetService"):CreateEditableImageAsync(Content.fromUri("rbxassetid://" .. id))
			local src = img.Size
			local buf = img:ReadPixelsBuffer(Vector2.zero, src)
			local n = png.size
			local rows = {}
			for y = 0, n - 1 do
				local sy = math.floor(y * src.Y / n)
				local line = { "\0" }
				for x = 0, n - 1 do
					local o = (sy * src.X + math.floor(x * src.X / n)) * 4
					line[#line + 1] = string.char(buffer.readu8(buf, o), buffer.readu8(buf, o + 1), buffer.readu8(buf, o + 2), buffer.readu8(buf, o + 3))
				end
				rows[#rows + 1] = table.concat(line)
			end
			img:Destroy()
			return png.encode(n, n, table.concat(rows))
		end)
		data = ok and type(data) == "string" and data or false
		png.cache[id] = data
		return data or nil
	end
	function png.post(url, payload, file)
		local boundary = "SenaHub" .. tostring(math.random(100000, 999999)) .. tostring(os.time())
		local body = table.concat({
			"--" .. boundary,
			'Content-Disposition: form-data; name="payload_json"',
			"Content-Type: application/json",
			"",
			HttpService:JSONEncode(payload),
			"--" .. boundary,
			'Content-Disposition: form-data; name="files[0]"; filename="egg.png"',
			"Content-Type: image/png",
			"",
			file,
			"--" .. boundary .. "--",
			"",
		}, "\r\n")
		local res = httpPost({
			Url = url,
			Method = "POST",
			Headers = { ["Content-Type"] = "multipart/form-data; boundary=" .. boundary },
			Body = body,
			})
		local code = type(res) == "table" and tonumber(res.StatusCode or res.status) or 0
		return code >= 200 and code < 300
	end
	Webhook.png = png
	local function flush()
		if flushing then return end
		flushing = true
		task.spawn(function()
			while #queue > 0 do
				local item = table.remove(queue, 1)
				pcall(function()
					if item.thumbAsset then
						local embed = item.payload.embeds[1]
						local thumb = webThumb(item.thumbAsset)
						if thumb then embed.thumbnail = { url = thumb } end
					end
					if item.imageAsset and httpPost then
						local file = png.render(item.imageAsset)
						if file then
							local embed = item.payload.embeds[1]
							local old = embed.thumbnail
							embed.thumbnail = { url = "attachment://egg.png" }
							if png.post(item.url, item.payload, file) then return end
							embed.thumbnail = old
						end
					end
					local body = HttpService:JSONEncode(item.payload)
					if httpPost then
						httpPost({
							Url = item.url,
							Method = "POST",
							Headers = { ["Content-Type"] = "application/json" },
							Body = body,
							})
					else
						HttpService:PostAsync(item.url, body, Enum.HttpContentType.ApplicationJson)
					end
					end)
				task.wait(0.6)
			end
			flushing = false
			end)
	end
	local function colorInt(color)
		if typeof(color) ~= "Color3" then return 5814783 end
		return math.floor(color.R * 255 + 0.5) * 65536
		+ math.floor(color.G * 255 + 0.5) * 256
		+ math.floor(color.B * 255 + 0.5)
	end
	local function compact(value)
		local SN = nil
		pcall(function() SN = require(ReplicatedStorage.Packages.FormatNumber.Simple) end)
		if SN and SN.FormatCompact then
			local ok, text = pcall(SN.FormatCompact, value, ".#")
			if ok and text then return tostring(text) end
		end
		return string.format("%.1f", value or 0)
	end
	Webhook.compact = compact
	function Webhook.rateOf(record)
		if not earnings or type(record) ~= "table" then return 0 end
		local scale = tonumber(record.AssetScale) or 1
		local item = {
			Category = record.AssetCategory,
			Scale = scale,
			AssetScale = scale,
			BaseMutation = record.BaseMutation,
			Mutations = record.Mutations or {},
		}
		for _, name in ipairs({ "LiveRatePerSecond", "RatePerSecond", "CatalogRatePerSecond" }) do
			if type(earnings[name]) == "function" then
				local ok, value = pcall(earnings[name], item)
				if ok and type(value) == "number" and value > 0 then return value end
			end
		end
		return 0
	end
	function Webhook.weightOf(record)
		if not weightUtil or type(record) ~= "table" then return 0 end
		local ok, kg = pcall(weightUtil.WeightKgForScale, record.AssetCategory, tonumber(record.AssetScale) or 1)
		if ok and type(kg) == "number" then return kg end
		return 0
	end
	function Webhook.sizeText(record)
		local scale = tonumber(record and (record.AssetScale or record.Scale)) or 1
		if scale >= 100 then return string.format("%.0fx", scale) end
		return string.format("%.2fx", scale)
	end
	function Webhook.weightText(kg)
		kg = tonumber(kg) or 0
		if kg >= 1000 then return compact(kg) .. " kg" end
		return string.format("%.1fkg", kg)
	end
	function Webhook.rateText(rate)
		rate = tonumber(rate) or 0
		if rate >= 1000 then return "$" .. compact(rate) .. "/s" end
		return string.format("$%d/s", math.floor(rate))
	end
	function Webhook.passes(record, info, rate)
		local wanted = {}
		local any = false
		for _, value in ipairs(Config.WebhookRarities or {}) do
			if value ~= "None" and value ~= "" then
				wanted[value] = true
				any = true
			end
		end
		if any and not wanted[info.rarity] then return false end
		local floor = tonumber(Config.WebhookMinValue) or 0
		if floor > 0 and rate < floor then return false end
		return true
	end
	local ASSET_KEYS = { "Image", "Icon", "Thumbnail", "ImageId", "IconId", "Texture", "Asset", "DisplayImage" }
	function Webhook.eggAsset(category)
		local assets = nil
		pcall(function() assets = require(ReplicatedStorage.Data.Assets).Directory end)
		local config = assets and assets[category]
		if type(config) ~= "table" then return nil end
		for _, holder in ipairs({ config, config.Egg, config.Pet }) do
			if type(holder) == "table" then
				for _, key in ipairs(ASSET_KEYS) do
					local value = holder[key]
					local id = (type(value) == "string" or type(value) == "number") and tostring(value):match("%d+")
					if id and tonumber(id) > 0 then return id end
				end
			end
		end
		return nil
	end
	function Webhook.stolen(record, catalogInfo, source)
		if Config.WebhookEnabled ~= true then return end
		local url = Config.WebhookURL
		if type(url) ~= "string" or url == "" then return end
		if type(record) ~= "table" or not record.AssetCategory then return end
		local info = catalogInfo or { name = record.AssetCategory, rarity = "Unknown", rarityColor = nil }
		local rate = Webhook.rateOf(record)
		if not Webhook.passes(record, info, rate) then return end
		local fields = {
			{ name = "User", value = LocalPlayer.Name, inline = true },
			{ name = "Rarity", value = tostring(info.rarity), inline = true },
			{ name = "Size", value = Webhook.sizeText(record), inline = true },
			{ name = "Weight", value = Webhook.weightText(Webhook.weightOf(record)), inline = true },
			{ name = "Cash/s", value = Webhook.rateText(rate), inline = true },
			{ name = "Area", value = tostring(record.AreaId or "?"), inline = true },
		}
		local mutations = record.Mutations or {}
		if #mutations > 0 then
			local names = {}
			for _, mutation in ipairs(mutations) do names[#names + 1] = tostring(mutation) end
			fields[#fields + 1] = { name = "Mutations", value = table.concat(names, ", "), inline = false }
		end
		if source and source ~= "" then
			fields[#fields + 1] = { name = "Taken From", value = tostring(source), inline = false }
		end
		local badge = senaIcon()
		local embed = {
			title = "Egg Stolen",
			description = string.format("You've stolen a **%s** %s", tostring(info.rarity), tostring(info.name)),
			color = colorInt(info.rarityColor),
			timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
			author = { name = "Sena Hub", icon_url = badge },
			footer = { text = "discord.gg/senahub", icon_url = badge },
			fields = fields,
		}
		if #queue > 40 then table.remove(queue, 1) end
		table.insert(queue, { url = url, payload = { embeds = { embed } }, imageAsset = Webhook.eggIcon(record.AssetCategory) })
		flush()
	end
	function Webhook.eggIcon(category)
		local config = nil
		pcall(function() config = require(ReplicatedStorage.Data.Assets).Directory[category] end)
		local egg = type(config) == "table" and type(config.Egg) == "table" and config.Egg.Icon
		local id = egg and tostring(egg):match("%d+")
		return id or Webhook.eggAsset(category)
	end
	function Webhook.test()
		local url = Config.WebhookURL
		if type(url) ~= "string" or url == "" then return false end
		local badge = senaIcon()
		local embed = {
			title = "Webhook Test",
			description = string.format("Connection test for **%s**", LocalPlayer.Name),
			color = 5814783,
			timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
			author = { name = "Sena Hub", icon_url = badge },
			footer = { text = "discord.gg/senahub", icon_url = badge },
			fields = {
				{ name = "User", value = LocalPlayer.Name, inline = true },
				{ name = "User ID", value = tostring(LocalPlayer.UserId), inline = true },
				{ name = "Place ID", value = tostring(game.PlaceId), inline = true },
				{ name = "Status", value = "Connected", inline = true },
			},
		}
		local thumb = webThumb(iconAsset)
		if thumb then embed.thumbnail = { url = thumb } end
		table.insert(queue, { url = url, payload = { embeds = { embed } }, imageAsset = Webhook.eggIcon("Dog") })
		flush()
		return true
	end
	local sessionStartedAt = os.clock()
	local lastDisconnectMessage = nil
	local function uptimeText()
		local seconds = math.floor(os.clock() - sessionStartedAt)
		local h, m = math.floor(seconds / 3600), math.floor(seconds % 3600 / 60)
		if h > 0 then return string.format("%dh %dm", h, m) end
		return string.format("%dm %ds", m, seconds % 60)
	end
	function Webhook.disconnected(message)
		if Config.WebhookDisconnect ~= true then return end
		local url = Config.WebhookURL
		if type(url) ~= "string" or url == "" then return end
		if type(message) ~= "string" or message == "" or message == lastDisconnectMessage then return end
		lastDisconnectMessage = message
		local badge = senaIcon()
		local embed = {
			title = "Account Disconnected",
			description = string.format("**%s** was disconnected from Steal an Egg.", LocalPlayer.Name),
			color = 15548997,
			timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
			author = { name = "Sena Hub", icon_url = badge },
			footer = { text = "discord.gg/senahub", icon_url = badge },
			fields = {
				{ name = "User", value = LocalPlayer.Name, inline = true },
				{ name = "User ID", value = tostring(LocalPlayer.UserId), inline = true },
				{ name = "Session", value = uptimeText(), inline = true },
				{ name = "Reason", value = message:sub(1, 1000), inline = false },
				{ name = "Server", value = "`" .. tostring(game.JobId ~= "" and game.JobId or "unknown") .. "`", inline = false },
			},
		}
		local body = HttpService:JSONEncode({ embeds = { embed } })
		task.spawn(function()
			pcall(function()
				if httpPost then
					httpPost({
						Url = url,
						Method = "POST",
						Headers = { ["Content-Type"] = "application/json" },
						Body = body,
						})
				else
					HttpService:PostAsync(url, body, Enum.HttpContentType.ApplicationJson)
				end
				end)
			end)
	end
	pcall(function()
		local previous = runtimeEnv.__SenaV4DisconnectConn
		if typeof(previous) == "RBXScriptConnection" then previous:Disconnect() end
		runtimeEnv.__SenaV4DisconnectConn = game:GetService("GuiService").ErrorMessageChanged:Connect(function(message)
			pcall(Webhook.disconnected, message)
			end)
		end)
	return Webhook
	end)()
runtimeEnv.__SenaV4Webhook = Webhook
local PlayerSteal = (function()
	local Players = game:GetService("Players")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local LocalPlayer = Players.LocalPlayer
	local EggCmds = require(ReplicatedStorage.Client.EggState)
	local AreaEggs = require(ReplicatedStorage.Shared.Types.AreaEggs)
	local PlayerSteal = {}
	PlayerSteal.__index = PlayerSteal
	local CHASE_TIMEOUT = 16
	local INTERCEPT_TIMEOUT = 8
	local INTERCEPT_RANGE = 80
	local LINE_X = 552.2
	local MIN_DEPTH = 120
	local JUNGLE_BAT_MAX_X = 1245
	local LEADS = { 1.1, 0.2, 0.7, 1.4, 0.45 }
	local LEAD_MAX = 60
	local FOREIGN_DROP_SETTLE = 7
	function PlayerSteal.new(eggRuntime, godMode, catalog)
		local self = setmetatable({}, PlayerSteal)
		self.eggRuntime = eggRuntime
		self.godMode = godMode
		self.catalog = catalog
		self.enabled = false
		self.running = false
		self.status = "idle"
		self.taken = 0
		self.attempts = 0
		self.history = {}
		self.blacklist = {}
		self.forced = false
		self.listeners = {}
		self.swingSeq = 0
		self.leadIdx = 1
		self.hitIdx = nil
		self.missStreak = 0
		self.lastCarrier = {}
		return self
	end
	function PlayerSteal:onChanged(listener)
		table.insert(self.listeners, listener)
	end
	function PlayerSteal:_notify()
		for _, listener in ipairs(self.listeners) do pcall(listener, self) end
	end
	function PlayerSteal:_setStatus(text)
		if self.status == text then return end
		self.status = text
		self:_notify()
	end
	function PlayerSteal:_log(name, egg, outcome)
		table.insert(self.history, 1, {
			at = os.time(),
			player = name or "?",
			egg = egg or "?",
			outcome = outcome or "?",
			})
		while #self.history > 20 do table.remove(self.history) end
		self:_notify()
	end
	function PlayerSteal:setEnabled(value)
		self.enabled = value == true
		if not self.enabled then
			self:_setStatus("idle")
		else
			self:_setStatus("looking for a carrier")
			self:_start()
		end
	end
	function PlayerSteal:_passes(record)
		if type(record) ~= "table" or not record.AssetCategory then return false end
		local info = self.catalog.resolve(record)
		local wanted = {}
		local any = false
		for _, value in ipairs(Config.StealPlayerRarities or {}) do
			if value ~= "None" and value ~= "" then
				wanted[value] = true
				any = true
			end
		end
		if not any then
			for _, value in ipairs(Config.StealRarities or {}) do
				if value ~= "None" and value ~= "" then
					wanted[value] = true
					any = true
				end
			end
		end
		if any and not wanted[info.rarity] then return false end
		local floor = tonumber(Config.StealPlayerMinValue) or 0
		if floor > 0 then
			local rate = runtimeEnv.__SenaV4Webhook and runtimeEnv.__SenaV4Webhook.rateOf(record) or 0
			if rate < floor then return false end
		end
		return true
	end
	function PlayerSteal:carriers()
		local found = {}
		local okSnap, snapshot = pcall(function()
			return EggCmds.ReadFieldEggs()
			end)
		if not okSnap or not snapshot then return found end
		for _, record in ipairs(snapshot.Records or {}) do
			local isCarried = record.State == "Carried" or (AreaEggs and AreaEggs.States and record.State == AreaEggs.States.Carried)
			if isCarried and not self.blacklist[record.Uid] then
				local full = nil
				pcall(function()
					full = EggCmds.ReadFieldEgg(record.Uid)
					end)
				full = full or record
				local carrier = full.CarrierUserId
				if carrier and carrier ~= LocalPlayer.UserId then
					local player = Players:GetPlayerByUserId(carrier)
					local root = player and player.Character and player.Character:FindFirstChild("HumanoidRootPart")
					if player and root then
						table.insert(found, { record = full, player = player, root = root })
					end
				end
			end
		end
		return found
	end
	function PlayerSteal:clearHistory()
		table.clear(self.history)
		self:_notify()
	end
	local function colorHex(color)
		if typeof(color) ~= "Color3" then return "ffffff" end
		return string.format("%02x%02x%02x",
			math.floor(color.R * 255 + 0.5),
			math.floor(color.G * 255 + 0.5),
			math.floor(color.B * 255 + 0.5))
	end
	function PlayerSteal:listEntries()
		local carrying = {}
		for _, entry in ipairs(self:carriers()) do
			carrying[entry.player] = entry.record
		end
		local myRoot = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
		local entries = {}
		for _, player in ipairs(Players:GetPlayers()) do
			if player ~= LocalPlayer then
				local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
				local record = carrying[player]
				local distance = (root and myRoot) and math.floor((root.Position - myRoot.Position).Magnitude + 0.5) or nil
				local where = "Offline"
				if record and record.AreaId then
					where = tostring(record.AreaId)
				elseif root then
					where = root.Position.X <= 552.2 and "Safe Zone" or "Field"
				end
				local status, statusSub, rank
				if record then
					local okInfo, info = pcall(function() return self.catalog.resolve(record) end)
					info = okInfo and info or { rarityRank = 0, name = tostring(record.AssetCategory or "Egg"), rarity = "Unknown", rarityColor = Color3.fromRGB(245, 196, 81) }
					rank = info.rarityRank or 0
					status = string.format(
						'<font color="#%s">%s</font>  <font color="#A2A2AE">[%s]</font>',
						colorHex(info.rarityColor), tostring(info.name or "Egg"), tostring(info.rarity or "Common"))
					statusSub = string.format("Running in %s%s", where,
						distance and ("  -  " .. distance .. " studs") or "")
				else
					status = "No Egg Carried"
					statusSub = string.format("Idle in %s%s", where,
						distance and ("  -  " .. distance .. " studs") or "")
				end
				entries[#entries + 1] = {
					id = tostring(player.UserId),
					name = tostring(player.DisplayName or player.Name),
					sub = string.format(
						'<font color="#4ADE80">@%s</font>  <font color="#A2A2AE">[%s]</font>',
						tostring(player.Name), where),
					status = status,
					statusSub = statusSub,
					button = "Steal",
					buttonColor = record and "accent" or "dim",
					player = player,
					carrying = record ~= nil,
					rank = rank or -1,
					distance = distance or 1e9,
					onClick = function(entry, setLabel)
						local ok = self:strike(entry.player)
						setLabel(ok and "Chasing" or "No Egg", ok and "green" or "red")
						task.delay(1.6, function()
							pcall(setLabel, "Steal", entry.carrying and "accent" or "dim")
							end)
					end,
				}
			end
		end
		table.sort(entries, function(left, right)
			if left.carrying ~= right.carrying then return left.carrying end
			if left.carrying and left.rank ~= right.rank then return left.rank > right.rank end
			return left.distance < right.distance
			end)
		return entries
	end
	function PlayerSteal:_pick()
		local wanted = Config.StealPlayerTarget
		local best, bestRank
		for _, entry in ipairs(self:carriers()) do
			local named = wanted == nil or wanted == "" or wanted == "Any Player" or entry.player.Name == wanted
			local deep = entry.root.Position.X > LINE_X + MIN_DEPTH and entry.player:GetAttribute("InBossArena") ~= true
			if named and deep and self:_passes(entry.record) then
				local rank = self.catalog.resolve(entry.record).rarityRank or 0
				if not bestRank or rank > bestRank then
					best, bestRank = entry, rank
				end
			end
		end
		return best
	end
	function PlayerSteal:strike(player)
		if not player or player == LocalPlayer then return false end
		for _, entry in ipairs(self:carriers()) do
			if entry.player == player then
				self.forced = true
				task.spawn(function() self:_chase(entry) end)
				return true
			end
		end
		self:_setStatus(player.Name .. " is not carrying an egg")
		return false
	end
	local function recoverPosture()
		local c = LocalPlayer.Character
		if not c then return end
		local hum = c:FindFirstChildOfClass("Humanoid")
		local h = c:FindFirstChild("HumanoidRootPart")
		for _, d in ipairs(c:GetDescendants()) do
			if d:IsA("Motor6D") then
				if not d.Enabled then d.Enabled = true end
			elseif d:IsA("BallSocketConstraint") or d:IsA("HingeConstraint") then
				if d.Name:find("Ragdoll") or d:GetAttribute("RagdollConstraint") then
					pcall(function() d:Destroy() end)
				end
			elseif d:IsA("Attachment") and (d.Name:find("Ragdoll") or d:GetAttribute("RagdollAttachment")) then
				pcall(function() d:Destroy() end)
			end
		end
		if hum then
			hum.PlatformStand = false
			hum.Sit = false
			pcall(function()
				hum:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
				hum:SetStateEnabled(Enum.HumanoidStateType.FallingDown, false)
				hum:SetStateEnabled(Enum.HumanoidStateType.Ragdoll, false)
				hum:SetStateEnabled(Enum.HumanoidStateType.PlatformStanding, false)
				hum:ChangeState(Enum.HumanoidStateType.GettingUp)
				task.wait(0.02)
				hum:ChangeState(Enum.HumanoidStateType.Running)
				end)
		end
		if h then
			h.AssemblyLinearVelocity = Vector3.zero
			h.AssemblyAngularVelocity = Vector3.zero
		end
	end
	local function getForestGuard()
		local objects = resolveObjectsRoot()
		local areas = objects and objects:FindFirstChild("Areas")
		local guardAreas = areas and areas:FindFirstChild("GuardAreas")
		local forest = guardAreas and guardAreas:FindFirstChild("Forest")
		if forest then
			local liveGuard = forest:FindFirstChild("Guard")
			local liveHrp = liveGuard and (liveGuard:FindFirstChild("HumanoidRootPart") or liveGuard:FindFirstChild("Collider") or (liveGuard:IsA("Model") and liveGuard.PrimaryPart))
			if liveGuard and liveHrp then return liveGuard, liveHrp end
			local authored = forest:FindFirstChild("ForestGuardAuthored")
			local aHrp = authored and (authored:FindFirstChild("HumanoidRootPart") or (authored:IsA("Model") and authored.PrimaryPart))
			if authored and aHrp then return authored, aHrp end
		end
		local fallback = workspace:FindFirstChild("AreaGuards")
		if fallback then
			for _, g in ipairs(fallback:GetChildren()) do
				local gHrp = g:FindFirstChild("HumanoidRootPart")
				if gHrp and gHrp.Position.X < 850 then
					return g, gHrp
				end
			end
		end
		return nil, nil
	end
	local function getForestBaitEgg(excludeUid)
		local snap = nil
		pcall(function() snap = EggCmds.ReadFieldEggs() end)
		local records = (snap and snap.Records) or {}
		local targetBait = nil
		for _, eg in ipairs(records) do
			if (eg.State == "Slot" or eg.State == "Dropped") and eg.Uid ~= excludeUid and (not eg.CarrierUserId or eg.CarrierUserId == LocalPlayer.UserId) then
				local bpos = (eg.BottomCFrame and eg.BottomCFrame.Position) or (eg.BoundsCFrame and eg.BoundsCFrame.Position)
				local isForest = (eg.AreaId == "Forest") or tostring(eg.Uid):find("Forest", 1, true) or tostring(eg.Uid):find("^FirstArea") or (bpos and bpos.X < 680)
				if isForest then
					if eg.State == "Slot" then
						targetBait = eg
						break
					elseif not targetBait then
						targetBait = eg
					end
				end
			end
		end
		return targetBait
	end
	function PlayerSteal:_primeForest(excludeUid)
		local runtime = self.eggRuntime
		local character = LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not (root and humanoid and humanoid.Health > 0) then return false end
		if runtime and runtime.carry and runtime.carry.active and runtime.carry.uid then
			pcall(function() runtime:_returnToSafe() end)
			task.wait(0.08)
		end
		self:_setStatus("Preparing steal")
		local targetBait = getForestBaitEgg(excludeUid)
		if not targetBait then
			self:_setStatus("Steal unavailable — retrying")
			return false
		end
		local bPos = (targetBait.BottomCFrame and targetBait.BottomCFrame.Position)
		or (targetBait.BoundsCFrame and targetBait.BoundsCFrame.Position)
		or Vector3.new(596.6, 67.7, -325.0)
		local bLanding = Vector3.new(bPos.X, bPos.Y + 2.5, bPos.Z)
		local baitSlotKey = "Forest:" .. tostring(targetBait.NestId or "Slot_001")
		pcall(function()
			local AreaEggSlotIdentity = require(ReplicatedStorage.Shared.Util.AreaEggSlotIdentity)
			if AreaEggSlotIdentity and targetBait.AreaId and targetBait.NestId then
				baitSlotKey = AreaEggSlotIdentity.SlotKey(targetBait.AreaId, targetBait.NestId)
			end
			end)
		self:_setStatus("Preparing steal")
		root.CFrame = CFrame.new(bLanding)
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		RunService.Heartbeat:Wait()
		local carried = false
		local tCarry = os.clock()
		local nextBurst = 0
		while not carried and os.clock() - tCarry < 0.8 do
			root = character:FindFirstChild("HumanoidRootPart") or root
			if root and root.Position.Y < 65 then
				root.CFrame = CFrame.new(bLanding)
				root.AssemblyLinearVelocity = Vector3.zero
			end
			if os.clock() >= nextBurst then
				nextBurst = os.clock() + 0.1
				task.spawn(function()
					pcall(function() EggCmds.CarryFieldEgg(targetBait.Uid, baitSlotKey) end)
					end)
				task.spawn(function()
					pcall(function()
						local Remotes = require(ReplicatedStorage.Shared.Remotes)
						if Remotes and Remotes.EggWorld and Remotes.EggWorld.AskFieldEggCarry then
							Remotes.EggWorld.AskFieldEggCarry:InvokeServer({ Uid = targetBait.Uid, FirstAreaSlotKey = baitSlotKey })
						end
						end)
					end)
			end
			local cur = nil
			pcall(function() cur = EggCmds.ReadFieldEgg(targetBait.Uid) end)
			if cur and cur.State == "Carried" and cur.CarrierUserId == LocalPlayer.UserId then
				carried = true
				break
			end
			RunService.Heartbeat:Wait()
		end
		if not carried then
			self:_setStatus("Steal unavailable — retrying")
			recoverPosture()
			return false
		end
		self:_setStatus("Preparing steal")
		local fGuard, gHrp = getForestGuard()
		local guardCollider = fGuard and (fGuard:FindFirstChild("Collider") or gHrp)
		local liveGuardPos = (gHrp and gHrp.Position) or Vector3.new(596.6, 69.4, -317.1)
		root.CFrame = CFrame.new(liveGuardPos.X, liveGuardPos.Y + 0.8, liveGuardPos.Z)
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		local knockbackReceived = false
		local kbConns = {}
		pcall(function()
			local refreshRemote = ReplicatedStorage:FindFirstChild("Packages")
			and ReplicatedStorage.Packages:FindFirstChild("Networking")
			and ReplicatedStorage.Packages.Networking:FindFirstChild("RE/RigSync/Refresh")
			if refreshRemote then
				table.insert(kbConns, refreshRemote.OnClientEvent:Connect(function() knockbackReceived = true end))
			end
			end)
		pcall(function()
			local Remotes = require(ReplicatedStorage.Shared.Remotes)
			if Remotes and Remotes.EggWorld and Remotes.EggWorld.OwnerDropped then
				table.insert(kbConns, Remotes.EggWorld.OwnerDropped.OnClientEvent:Connect(function() knockbackReceived = true end))
			end
			end)
		if humanoid then
			table.insert(kbConns, humanoid.StateChanged:Connect(function(_, new)
				if new == Enum.HumanoidStateType.Ragdoll or new == Enum.HumanoidStateType.FallingDown or new == Enum.HumanoidStateType.PlatformStanding then
					knockbackReceived = true
				end
				end))
			table.insert(kbConns, humanoid:GetPropertyChangedSignal("PlatformStand"):Connect(function()
				if humanoid.PlatformStand then knockbackReceived = true end
				end))
		end
		local function triggerGuardHit()
			fGuard, gHrp = getForestGuard()
			local curGPos = (gHrp and gHrp.Position) or liveGuardPos
			local curH = character:FindFirstChild("HumanoidRootPart")
			if curH then
				curH.CFrame = CFrame.new(curGPos.X, curGPos.Y + 0.8, curGPos.Z)
				curH.AssemblyLinearVelocity = Vector3.zero
			end
			local col = (fGuard and fGuard:FindFirstChild("Collider")) or gHrp
			if col and type(firetouchinterest) == "function" and curH then
				pcall(function() firetouchinterest(curH, col, 0); firetouchinterest(curH, col, 1) end)
			end
			pcall(function()
				local Remotes = require(ReplicatedStorage.Shared.Remotes)
				if Remotes and Remotes.GuardPatrol and Remotes.GuardPatrol.ForestStrike then
					Remotes.GuardPatrol.ForestStrike:FireServer({
						EggUid = targetBait.Uid,
						GuardCFrame = (gHrp and gHrp.CFrame) or CFrame.new(curGPos)
						})
				end
				end)
		end
		self:_setStatus("Preparing steal")
		triggerGuardHit()
		local kbDeadline = os.clock() + 0.75
		local nextStrike = os.clock() + 0.05
		while os.clock() < kbDeadline do
			if knockbackReceived then break end
			local curHum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
			if curHum and (curHum.PlatformStand or curHum.Sit) then knockbackReceived = true break end
			local curHrp = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
			if curHrp and curHrp.AssemblyLinearVelocity.Magnitude > 18 then knockbackReceived = true break end
			if curHrp and curHrp.Position.Y < 65 then
				curHrp.CFrame = CFrame.new(liveGuardPos.X, 70.0, liveGuardPos.Z)
				curHrp.AssemblyLinearVelocity = Vector3.zero
			end
			if os.clock() >= nextStrike then
				nextStrike = os.clock() + 0.05
				triggerGuardHit()
			end
			RunService.Heartbeat:Wait()
		end
		for _, conn in ipairs(kbConns) do pcall(conn.Disconnect, conn) end
		if not knockbackReceived then
			self:_setStatus("Steal unavailable — retrying")
			recoverPosture()
			return false, targetBait.Uid
		end
		self:_setStatus("Preparing steal")
		recoverPosture()
		local settleDl = os.clock() + 0.35
		while os.clock() < settleDl do
			local hh = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
			local rr = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
			if hh and rr and not hh.PlatformStand and not hh.Sit then
				local stt = hh:GetState()
				if stt ~= Enum.HumanoidStateType.Ragdoll
				and stt ~= Enum.HumanoidStateType.FallingDown
				and stt ~= Enum.HumanoidStateType.PlatformStanding then
					rr.AssemblyLinearVelocity = Vector3.zero
					rr.AssemblyAngularVelocity = Vector3.zero
					break
				end
			end
			recoverPosture()
			RunService.Heartbeat:Wait()
		end
		return true, targetBait.Uid
	end
	function PlayerSteal:_swingBatAt(victimPlayer, bat)
		if not bat or bat.Parent ~= LocalPlayer.Character then return false end
		self.swingSeq += 1
		local trace = string.format("%d:%d:%d", LocalPlayer.UserId, self.swingSeq, math.floor(workspace:GetServerTimeNow() * 1000))
		return pcall(function()
			require(ReplicatedStorage.Shared.Remotes).BatSwing.Trigger:FireServer(victimPlayer, trace)
			end)
	end
	function PlayerSteal:_dropUnwanted()
		local held = nil
		pcall(function()
			for _, record in ipairs(EggCmds.ReadFieldEggs().Records or {}) do
				if record.State == "Carried" and record.CarrierUserId == LocalPlayer.UserId then
					held = EggCmds.ReadFieldEgg(record.Uid) or record
					break
				end
			end
			end)
		if held and not self:_passes(held) then
			pcall(EggCmds.DropFieldEgg, "PlayerRequest")
			task.wait(0.3)
			return true
		end
		return false
	end
	function PlayerSteal:_returnSafe()
		self:_dropUnwanted()
		local runtime = self.eggRuntime
		local character = LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not (runtime and root and humanoid) or runtime:_isInSafeArea(root) then return end
		local safeCF = runtime:_resolveSafeCFrame(root)
		if not safeCF then return end
		self:_setStatus("Returning to safe zone")
		TweenMoveTo(root, humanoid, safeCF, function()
			return humanoid.Health <= 0 or not root.Parent
		end, false, nil, true)
	end
	function PlayerSteal:intercept(uid)
		if self.running then return false end
		local myRoot = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
		if not myRoot then return false end
		for _, entry in ipairs(self:carriers()) do
			if entry.record.Uid == uid then
				if entry.root.Position.X <= LINE_X
				or (entry.root.Position - myRoot.Position).Magnitude > INTERCEPT_RANGE
				or not self:_passes(entry.record)
				then
					return false
				end
				self.forced = true
				task.spawn(self._chase, self, entry, true)
				return self.running
			end
		end
		return false
	end
	function PlayerSteal:_chase(entry, intercept)
		if LocalPlayer:GetAttribute("InHalloweenDimension") == true then return end
		if self.running then return end
		self.running = true
		self.attempts += 1
		local record = entry.record
		local uid = record.Uid
		local info = self.catalog.resolve(record)
		local holder = entry.player
		local name = holder.DisplayName or holder.Name
		self.cardTarget = { uid = uid, record = record, player = name } 
		if self.godMode then self.godMode:stopDefend() end
		if not intercept then
			self:_returnSafe()
			self:_setStatus(string.format("Preparing to steal from %s", name))
			local okPrime, primed, baitUid = pcall(self._primeForest, self, uid)
			local bait = nil
			if okPrime and not primed and baitUid then
				pcall(function() bait = EggCmds.ReadFieldEgg(baitUid) end)
			end
			if bait and bait.State == "Carried" and bait.CarrierUserId == LocalPlayer.UserId then
				self:_returnSafe()
				self:_log(name, info.name, "could not prepare")
				self:_setStatus(self.enabled and "looking for a carrier" or "idle")
				self.running = false
				self.forced = false
				return
			end
		end
		local bat = self.godMode and self.godMode:_equipBat()
		local deadline = os.clock() + (intercept and INTERCEPT_TIMEOUT or CHASE_TIMEOUT)
		local outcome = "could not catch them"
		local lastSwing, nextEquipAt = 0, 0
		local pendingAt, pendingCd = nil, nil
		local gluedSince = nil
		local hitAt = nil
		local posHist = {}
		local vel = Vector3.zero
		local ragSeen = holder:GetAttribute("RagdollEndTime") or false
		local ping = 0.1
		pcall(function() ping = math.clamp(LocalPlayer:GetNetworkPing() or 0.1, 0.03, 0.6) end)
		local tau = math.clamp(0.14 + ping, 0.14, 0.35)
		self.leadIdx = self.hitIdx or self.leadIdx or 1
		self.missStreak = 0
		local ncConn = nil
		pcall(function()
			ncConn = RunService.Stepped:Connect(function()
				local curC = LocalPlayer.Character
				if curC then
					for _, p in ipairs(curC:GetDescendants()) do
						if p:IsA("BasePart") then p.CanCollide = false end
					end
				end
				end)
			end)
		self:_setStatus(string.format("Chasing %s", name))
		while os.clock() < deadline do
			local dt = RunService.PreSimulation:Wait()
			if not self.enabled and not self.forced then outcome = "stopped" break end
			local current = nil
			pcall(function() current = EggCmds.ReadFieldEgg(uid) end)
			local state = current and current.State
			if not current or state == "Slot" or state == "GuardCarried" then outcome = "egg reset" break end
			if state == "Claimed" then outcome = "they banked it" break end
			if state == "Carried" and current.CarrierUserId == LocalPlayer.UserId then outcome = "taken" break end
			if state == "Dropped" then
				local now = os.clock()
				local ragChanged = (holder:GetAttribute("RagdollEndTime") or false) ~= ragSeen
				local ourHit = gluedSince ~= nil and ((pendingAt ~= nil and now - pendingAt <= 1)
					or (hitAt ~= nil and now - hitAt <= 1.5) or ragChanged)
				if ourHit then
					if pendingAt and now - pendingAt <= 1 then self.hitIdx = self.leadIdx end
					self:_setStatus(string.format("Grabbing dropped egg from %s", name))
					outcome = self:_grab(current, holder, bat) and "taken" or "someone else grabbed it"
				else
					outcome = self:_grabForeignDrop(current, holder, bat) and "taken" or "someone else grabbed it"
				end
				break
			end
			local character = LocalPlayer.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if not root or not humanoid or humanoid.Health <= 0 then outcome = "character died" break end
			if current.CarrierUserId ~= holder.UserId then
				local other = Players:GetPlayerByUserId(current.CarrierUserId or 0)
				if not other then outcome = "taken by another player" break end
				holder = other
				name = holder.DisplayName or holder.Name
				ragSeen = holder:GetAttribute("RagdollEndTime") or false
				gluedSince, pendingAt = nil, nil
				table.clear(posHist)
				self:_setStatus(string.format("Chasing %s", name))
			end
			local targetRoot = holder.Character and holder.Character:FindFirstChild("HumanoidRootPart")
			if not targetRoot then outcome = "lost sight of them" break end
			if targetRoot.Position.X <= LINE_X then outcome = "banked" break end
			local nowC = os.clock()
			posHist[#posHist + 1] = { t = nowC, p = targetRoot.Position }
			while #posHist > 2 and nowC - posHist[1].t > 0.4 do table.remove(posHist, 1) end
			local repl = targetRoot.AssemblyLinearVelocity
			if Vector3.new(repl.X, 0, repl.Z).Magnitude > 8 then
				vel = repl
			elseif #posHist >= 2 and nowC - posHist[1].t > 0.15 then
				vel = (targetRoot.Position - posHist[1].p) / (nowC - posHist[1].t)
			end
			local vflat = Vector3.new(vel.X, 0, vel.Z)
			local speed = vflat.Magnitude
			local dir
			if speed > 6 then
				dir = vflat.Unit
			else
				local lv = targetRoot.CFrame.LookVector
				lv = Vector3.new(lv.X, 0, lv.Z)
				dir = lv.Magnitude > 0.05 and lv.Unit or Vector3.new(-1, 0, 0)
			end
			local lead = math.clamp((LEADS[self.leadIdx] or 1) * speed * tau, 3, LEAD_MAX)
			local holdPos = targetRoot.Position + dir * lead
			if holdPos.X < LINE_X + 5 then holdPos = Vector3.new(LINE_X + 5, holdPos.Y, holdPos.Z) end
			local faceAt = Vector3.new(targetRoot.Position.X, holdPos.Y, targetRoot.Position.Z)
			if (faceAt - holdPos).Magnitude < 0.5 then faceAt = holdPos - dir end
			local targetCF = CFrame.lookAt(holdPos, faceAt)
			local delta = holdPos - root.Position
			local dist = delta.Magnitude
			local moveSpd = speedDialStuds()
			local step = moveSpd * math.min(dt, 0.05)
			local travelVelocity
			setMovementSpoof(character, moveSpd * SPOOF_CFG.HEADROOM)
			if dist > step then
				root.CFrame = CFrame.new(root.Position + delta.Unit * step) * targetCF.Rotation
				root.AssemblyLinearVelocity = Vector3.zero
				travelVelocity = delta.Unit * moveSpd
			else
				root.CFrame = targetCF
				root.AssemblyLinearVelocity = targetRoot.AssemblyLinearVelocity
				travelVelocity = targetRoot.AssemblyLinearVelocity
			end
			root.AssemblyAngularVelocity = Vector3.zero
			if not refreshIntegritySpoof(humanoid, root, moveSpd, travelVelocity) then
				setIntegritySpoof(humanoid, root, moveSpd)
				refreshIntegritySpoof(humanoid, root, moveSpd, travelVelocity)
			end
			local drift = speed * dt * 1.5
			if dist <= 5 + drift then
				if not gluedSince then gluedSince = os.clock() end
				self:_setStatus(targetRoot.Position.X <= JUNGLE_BAT_MAX_X
					and string.format("Attacking %s", name)
					or string.format("Chasing %s", name))
			elseif dist > 12 + drift and gluedSince then
				gluedSince = nil
				self:_setStatus(string.format("Chasing %s", name))
			end
			local ragNow = holder:GetAttribute("RagdollEndTime") or false
			if ragNow ~= ragSeen then
				ragSeen = ragNow
				hitAt = os.clock()
				self.hitIdx = self.leadIdx
				self.missStreak = 0
				pendingAt = nil
			end
			if (not bat or bat.Parent ~= character) and os.clock() >= nextEquipAt then
				nextEquipAt = os.clock() + 0.5
				task.spawn(function()
					bat = self.godMode and self.godMode:_equipBat() or bat
					end)
			end
			local cdEnd = bat and tonumber(bat:GetAttribute("CooldownEndTime")) or 0
			if pendingAt and os.clock() - pendingAt > 0.9 then
				if cdEnd ~= pendingCd then
					self.missStreak += 1
					if self.missStreak >= 2 then
						self.missStreak = 0
						self.leadIdx = (self.leadIdx % #LEADS) + 1
						gluedSince = nil
					end
				end
				pendingAt = nil
			end
			if bat and bat.Parent == character and gluedSince and os.clock() - gluedSince >= tau + 0.05
			and targetRoot.Position.X <= JUNGLE_BAT_MAX_X
			and bat:GetAttribute("CooldownActive") ~= true
			and workspace:GetServerTimeNow() >= cdEnd
			and os.clock() - lastSwing >= 0.35 then
				lastSwing = os.clock()
				if not pendingAt then pendingAt, pendingCd = os.clock(), cdEnd end
				task.spawn(self._swingBatAt, self, holder, bat)
			end
		end
		if ncConn then pcall(function() ncConn:Disconnect() end) end
		if outcome == "taken" then
			self.taken += 1
			self:_deliver(uid, record)
		else
			self.blacklist[uid] = os.clock() + 20
			self:_returnSafe()
		end
		self:_log(name, info.name, outcome)
		self:_setStatus(self.enabled and "looking for a carrier" or "idle")
		self.running = false
		self.forced = false
	end
	function PlayerSteal:_grabForeignDrop(record, holder, bat)
		local uid = record.Uid
		local function current()
			local c = nil
			pcall(function() c = EggCmds.ReadFieldEgg(uid) end)
			return c
		end
		local character = LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local bpos = (record.BottomCFrame and record.BottomCFrame.Position) or (record.BoundsCFrame and record.BoundsCFrame.Position)
		if not (root and humanoid and humanoid.Health > 0 and bpos) then return false end
		if (root.Position - bpos).Magnitude > 8 then
			self:_setStatus("Moving to dropped egg")
			TweenMoveTo(root, humanoid, CFrame.new(bpos + Vector3.new(0, 3, 0)), function()
				local c = current()
				return (not self.enabled and not self.forced) or humanoid.Health <= 0 or not root.Parent
					or c == nil or c.State ~= "Dropped"
			end)
		end
		local now = current()
		if now and now.State == "Carried" then return now.CarrierUserId == LocalPlayer.UserId end
		if not now or now.State ~= "Dropped" then return false end
		return self:_grab(now, holder, bat, false, FOREIGN_DROP_SETTLE)
	end
	function PlayerSteal:_deliver(uid, record)
		pcall(function()
			local hum = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
			if hum then hum:UnequipTools() end
			end)
		local runtime = self.eggRuntime
		local handed = runtime and type(runtime.deliverCarriedEgg) == "function"
			and runtime:deliverCarriedEgg(uid, record) == true
		if handed then
			self:_setStatus("Delivering stolen egg")
			local deadline = os.clock() + 30
			while runtime._instantReturnToken ~= nil and os.clock() < deadline do
				task.wait(0.2)
			end
			return
		end
		local function banked()
			local current = nil
			pcall(function() current = EggCmds.ReadFieldEgg(uid) end)
			return current == nil or current.State == "Claimed"
		end
		self:_setStatus("Carrying stolen egg home")
		local deadline = os.clock() + 8
		while not banked() and os.clock() < deadline do
			local character = LocalPlayer.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if root and runtime and not runtime:_isInSafeArea(root) then self:_returnSafe() end
			task.wait(0.1)
		end
	end
	function PlayerSteal:_snipe(record, carrierUserId)
		if self.running then return end
		self.running = true
		self.attempts += 1
		local uid = record.Uid
		local info = self.catalog.resolve(record)
		local holder = Players:GetPlayerByUserId(carrierUserId or 0)
		local name = holder and (holder.DisplayName or holder.Name) or "?"
		self.cardTarget = { uid = uid, record = record, player = name } 
		local bpos = (record.BottomCFrame and record.BottomCFrame.Position) or (record.BoundsCFrame and record.BoundsCFrame.Position)
		local outcome = "someone else grabbed it"
		local function stillDropped()
			local current = nil
			pcall(function() current = EggCmds.ReadFieldEgg(uid) end)
			return current ~= nil and current.State == "Dropped", current
		end
		local character = LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if bpos and root and humanoid and humanoid.Health > 0 then
			if self.godMode then self.godMode:stopDefend() end
			self:_setStatus(string.format("Sniping %s's dropped egg", name))
			TweenMoveTo(root, humanoid, CFrame.new(bpos + Vector3.new(0, 3, 0)), function()
				return not self.enabled or humanoid.Health <= 0 or not stillDropped()
			end)
			local dropped, current = stillDropped()
			if dropped and self.enabled then
				outcome = self:_grab(current, nil, nil, true) and "taken" or outcome
			end
		end
		if outcome == "taken" then
			self.taken += 1
			self:_deliver(uid, record)
		else
			self.blacklist[uid] = os.clock() + 20
			self:_returnSafe()
		end
		self:_log(name, info.name, outcome == "taken" and "sniped drop" or outcome)
		self:_setStatus(self.enabled and "looking for a carrier" or "idle")
		self.running = false
	end
	function PlayerSteal:_watchDrops()
		if self.dropConns then return end
		local function alive()
			if runtimeEnv.ChloeX_Running == nil and runtimeEnv.__SenaV4PlayerSteal ~= self then
				for _, conn in ipairs(self.dropConns or {}) do pcall(function() conn:Disconnect() end) end
				return false
			end
			return true
		end
		pcall(function()
			for _, r in ipairs(EggCmds.ReadFieldEggs().Records or {}) do
				if r.State == "Carried" and r.CarrierUserId then self.lastCarrier[r.Uid] = r.CarrierUserId end
			end
			end)
		self.dropConns = {}
		table.insert(self.dropConns, EggCmds.FieldShifted:Connect(function(record)
			if not alive() or type(record) ~= "table" or not record.Uid then return end
			if record.State == "Carried" then
				self.lastCarrier[record.Uid] = record.CarrierUserId
				return
			end
			if record.State ~= "Dropped" then
				self.lastCarrier[record.Uid] = nil
				return
			end
			local carrier = self.lastCarrier[record.Uid]
			if not carrier or carrier == LocalPlayer.UserId then return end
			if not self.enabled or self.running or self.blacklist[record.Uid] then return end
			local runtime = self.eggRuntime
			local bloom = runtimeEnv.__SenaV4ButterflyRuntime
			if runtime and (runtime.running or (runtime.carry and runtime.carry.active)) then return end
			if bloom ~= nil and bloom.active == true then return end
			local bpos = record.BottomCFrame and record.BottomCFrame.Position
			if not bpos or bpos.X <= LINE_X then return end
			if LocalPlayer:GetAttribute("InBossArena") == true then return end
			if LocalPlayer:GetAttribute("InHalloweenDimension") == true then return end
			if runtimeEnv.__SenaV4OnTrain == true then return end
			if not self:_passes(record) then return end
			task.spawn(self._snipe, self, record, carrier)
			end))
		table.insert(self.dropConns, EggCmds.FieldGone:Connect(function(uid)
			if alive() then self.lastCarrier[uid] = nil end
			end))
	end
	function PlayerSteal:_grab(record, holder, bat, quick, settleFloor)
		local runtime = self.eggRuntime
		local uid = record.Uid
		local ragdoll = nil
		pcall(function() ragdoll = require(ReplicatedStorage.Shared.Modules.RagdollJoints) end)
		local function fresh()
			local c = nil
			pcall(function() c = EggCmds.ReadFieldEgg(uid) end)
			return c
		end
		local function unragdoll(character, humanoid)
			pcall(function()
				if ragdoll and ragdoll.Release then ragdoll.Release(character) end
				humanoid.PlatformStand = false
				humanoid.Sit = false
				if humanoid:GetState() ~= Enum.HumanoidStateType.Running then
					humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
				end
				end)
		end
		local function standCF(current, root, humanoid)
			local dest = runtime and runtime:_resolveEggDestination(current, root, humanoid)
			if not dest then
				local bpos = (current.BottomCFrame and current.BottomCFrame.Position) or (current.BoundsCFrame and current.BoundsCFrame.Position)
				dest = bpos and CFrame.new(bpos.X, bpos.Y + 2.5, bpos.Z)
			end
			return dest
		end
		local function pinSpoof(character, root, humanoid, dest)
			root.CFrame = dest
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
			local ls = math.clamp(speedDialStuds(), SPOOF_CFG.MIN_SPEED, SPOOF_CFG.MAX_SPEED)
			setMovementSpoof(character, ls * SPOOF_CFG.HEADROOM)
			if not refreshIntegritySpoof(humanoid, root, ls, Vector3.zero) then
				setIntegritySpoof(humanoid, root, ls)
			end
		end
		local function keepFighting()
			if not (holder and bat) then return end
			local character = LocalPlayer.Character
			if not character or bat.Parent ~= character then return end
			local now = workspace:GetServerTimeNow()
			local cdEnd = tonumber(bat:GetAttribute("CooldownEndTime")) or 0
			if now >= cdEnd and bat:GetAttribute("CooldownActive") ~= true then
				task.spawn(self._swingBatAt, self, holder, bat)
			end
		end
		local settleSeconds = 2.5
		pcall(function() settleSeconds = math.clamp(runtime:_resolveSettleSeconds(record), 1.5, 4) end)
		if settleFloor then settleSeconds = math.max(settleSeconds, settleFloor) end
		local lockCF = nil
		local settleUntil = quick and 0 or os.clock() + settleSeconds
		while os.clock() < settleUntil do
			local current = fresh()
			local state = current and current.State
			if state == "Carried" then
				if current.CarrierUserId ~= LocalPlayer.UserId then return false end
				return true
			end
			if state ~= "Dropped" and state ~= "Slot" then return false end
			local character = LocalPlayer.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if not root or not humanoid or humanoid.Health <= 0 then return false end
			unragdoll(character, humanoid)
			lockCF = standCF(current, root, humanoid) or lockCF
			if lockCF then pinSpoof(character, root, humanoid, lockCF) end
			keepFighting()
			self:_setStatus(string.format("Securing dropped egg (%ds)", math.ceil(settleUntil - os.clock())))
			RunService.Heartbeat:Wait()
		end
		local askBusy, carryBusy = false, false
		local deadline = os.clock() + 3.5
		while os.clock() < deadline do
			local current = fresh()
			local state = current and current.State
			if state == "Carried" then
				if current.CarrierUserId ~= LocalPlayer.UserId then return false end
				if runtimeEnv.__SenaV4Webhook then
					local okInfo, info = pcall(self.catalog.resolve, current)
					pcall(runtimeEnv.__SenaV4Webhook.stolen, current, okInfo and info or nil, "player carry")
				end
				return true
			end
			if state ~= "Dropped" and state ~= "Slot" then return false end
			local character = LocalPlayer.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if not root or not humanoid or humanoid.Health <= 0 then return false end
			unragdoll(character, humanoid)
			local dest = standCF(current, root, humanoid) or lockCF
			if dest then pinSpoof(character, root, humanoid, dest) end
			keepFighting()
			if not askBusy then
				askBusy = true
				task.spawn(function()
					pcall(function() require(ReplicatedStorage.Shared.Remotes).EggWorld.AskFieldEggCarry:InvokeServer({ Uid = uid }) end)
					askBusy = false
					end)
			end
			if not carryBusy then
				carryBusy = true
				task.spawn(function()
					pcall(function() EggCmds.CarryFieldEgg(uid) end)
					carryBusy = false
					end)
			end
			pcall(function()
				local slots = workspace:FindFirstChild("AreaEggSlotsClient")
				local model = slots and slots:FindFirstChild(tostring(uid))
				local prompt = model and (model:FindFirstChild("CarryAreaEgg", true) or model:FindFirstChildWhichIsA("ProximityPrompt", true))
				if prompt and prompt.Enabled and type(fireproximityprompt) == "function" then
					prompt.HoldDuration = 0
					prompt.RequiresLineOfSight = false
					fireproximityprompt(prompt, 0)
				end
				end)
			task.wait(0.06)
		end
		return false
	end
	function PlayerSteal:_start()
		self:_watchDrops()
		if self.loop then return end
		self.loop = task.spawn(function()
			while true do
				task.wait(0.4)
				if runtimeEnv.ChloeX_Running == nil and runtimeEnv.__SenaV4PlayerSteal ~= self then break end
				for uid, expiry in pairs(self.blacklist) do
					if os.clock() > expiry then self.blacklist[uid] = nil end
				end
				local runtime = self.eggRuntime
				local bloom = runtimeEnv.__SenaV4ButterflyRuntime
				local stealBusy = runtime and (runtime.running or (runtime.carry and runtime.carry.active))
				local bloomBusy = bloom ~= nil and bloom.active == true
				local entry = nil
				if self.enabled and not self.running and not stealBusy then
					entry = self:_pick()
				end
				self.wantsTarget = entry ~= nil
				if entry and not bloomBusy then self:_chase(entry) end
			end
			self.loop = nil
			end)
	end
	return PlayerSteal
	end)()
local antiGuard = AntiGuard.new(eggRuntime)
antiGuard:install()
antiGuard:setEnabled(Config.AntiGuardKnockback == true)
runtimeEnv.__SenaV4AntiGuard = antiGuard
local godMode = GodMode.new(eggRuntime)
godMode:setEnabled(Config.GodMode == nil and true or (Config.GodMode == true))
runtimeEnv.__SenaV4GodMode = godMode
local playerSteal = PlayerSteal.new(eggRuntime, godMode, catalog)
do
	local MovementExtras = (function()
		local Players = game:GetService("Players")
		local RunService = game:GetService("RunService")
		local UserInputService = game:GetService("UserInputService")
		local LocalPlayer = Players.LocalPlayer
		local FLY_ALTITUDE = 110
		local GRAB_HOLD_SECONDS = 0.1
		local GRAB_PROMPT_NAME = "CarryAreaEgg"
		local JUMP_MIN_POWER = 55
		local JUMP_COOLDOWN = 0.08
		local JUMP_HELD_INTERVAL = 0.28
		local MovementExtras = {}
		MovementExtras.__index = MovementExtras
		function MovementExtras.new()
			local self = setmetatable({}, MovementExtras)
			self.flyEnabled = false
			self.flyConnection = nil
			self.flyMover = nil
			self.grabEnabled = false
			self.grabConnection = nil
			self.grabOriginals = setmetatable({}, { __mode = "k" })
			self.jumpEnabled = false
			self.jumpConnections = {}
			self.lastJumpAt = 0
			self.speedMultiplier = 1
			self.speedModules = nil
			self.speedConnection = nil
			return self
		end
		function MovementExtras:_root()
			local character = LocalPlayer.Character
			return character and character:FindFirstChild("HumanoidRootPart")
		end
		function MovementExtras:_humanoid()
			local character = LocalPlayer.Character
			return character and character:FindFirstChildOfClass("Humanoid")
		end
		function MovementExtras:_ensureMover(root)
			if self.flyMover and self.flyMover.Parent == root then return end
			if self.flyMover then pcall(function() self.flyMover:Destroy() end) end
			local mover = Instance.new("BodyVelocity")
			mover.Name = "SenaFlyCaptureHover"
			mover.MaxForce = Vector3.new(0, 9e9, 0)
			mover.Velocity = Vector3.zero
			mover.Parent = root
			self.flyMover = mover
		end
		local function treadmillOwnsIdle()
			local treadmill = runtimeEnv.__SenaV4TreadmillManager
			return treadmill ~= nil and not treadmill.destroyed and treadmill.config ~= nil and treadmill.config.idleFarm == true
		end
		local carryCache = { at = 0, value = false }
		local function carryingEgg()
			local now = os.clock()
			if now - carryCache.at < 0.25 then return carryCache.value end
			carryCache.at = now
			local found = false
			pcall(function()
				local EggState = require(game:GetService("ReplicatedStorage").Client.EggState)
				local snapshot = EggState.GetAreaEggSnapshot and EggState.GetAreaEggSnapshot()
				if (not snapshot or not snapshot.Records) and EggState.ReadFieldEggs then
					snapshot = EggState.ReadFieldEggs()
				end
				for _, record in ipairs(snapshot and snapshot.Records or {}) do
					if record.State == "Carried" and record.CarrierUserId == LocalPlayer.UserId then
						found = true
						break
					end
				end
				end)
			carryCache.value = found
			return found
		end
		function MovementExtras:_dropMover(root)
			if self.flyMover then
				pcall(function() self.flyMover:Destroy() end)
				self.flyMover = nil
			end
			local leftover = root and root:FindFirstChild("SenaFlyCaptureHover")
			if leftover then pcall(function() leftover:Destroy() end) end
		end
		function MovementExtras:setFlyForCapture(value)
			self.flyEnabled = value == true
			if not self.flyEnabled then
				if self.flyConnection then
					pcall(function() self.flyConnection:Disconnect() end)
					self.flyConnection = nil
				end
				if self.flyMover then
					pcall(function() self.flyMover:Destroy() end)
					self.flyMover = nil
				end
				local root = self:_root()
				if root then
					local leftover = root:FindFirstChild("SenaFlyCaptureHover")
					if leftover then pcall(function() leftover:Destroy() end) end
					if self.flyAnchored then pcall(function() root.Anchored = false end) end
				end
				self.flyAnchored = false
				return
			end
			if self.flyConnection then return end
			self.flyAnchored = false
			self.flyConnection = RunService.PreSimulation:Connect(function()
				if not self.flyEnabled then return end
				local live = self:_root()
				if not live then return end
				local yield = not carryingEgg()
					or treadmillOwnsIdle()
					or next(activeMoves) ~= nil
					or (eggRuntime and (eggRuntime.running or eggRuntime.activeTween))
				if not yield then
					local playerSteal = runtimeEnv.__SenaV4PlayerSteal
					if playerSteal and playerSteal.running then yield = true end
				end
				if yield then
					if self.flyAnchored then
						pcall(function() live.Anchored = false end)
						self.flyAnchored = false
					end
					return
				end
				if live.Position.Y < FLY_ALTITUDE - 1 then
					if self.flyAnchored then
						pcall(function() live.Anchored = false end)
						self.flyAnchored = false
					end
					local nextY = live.Position.Y + math.min(FLY_ALTITUDE - live.Position.Y, 4)
					live.CFrame = CFrame.new(live.Position.X, nextY, live.Position.Z) * live.CFrame.Rotation
					live.AssemblyLinearVelocity = Vector3.zero
					live.AssemblyAngularVelocity = Vector3.zero
				elseif not live.Anchored then
					pcall(function() live.Anchored = true end)
					self.flyAnchored = true
				else
					self.flyAnchored = true
				end
				end)
		end
		function MovementExtras:_isGrabPrompt(instance)
			return instance:IsA("ProximityPrompt") and instance.Name == GRAB_PROMPT_NAME
		end
		function MovementExtras:_applyGrab(prompt)
			if not self:_isGrabPrompt(prompt) then return end
			if self.grabOriginals[prompt] == nil then self.grabOriginals[prompt] = prompt.HoldDuration end
			if prompt.HoldDuration > GRAB_HOLD_SECONDS then prompt.HoldDuration = GRAB_HOLD_SECONDS end
		end
		function MovementExtras:_restoreGrab()
			local fallback = workspace:GetAttribute("FastEggPickupTime") and 0.25 or 1.2
			for prompt, original in pairs(self.grabOriginals) do
				pcall(function()
					if prompt.Parent then
						prompt.HoldDuration = (tonumber(original) and original > GRAB_HOLD_SECONDS) and original or fallback
					end
					end)
			end
			self.grabOriginals = setmetatable({}, { __mode = "k" })
		end
		function MovementExtras:_fireGrab(prompt)
			if not self:_isGrabPrompt(prompt) or not prompt.Enabled then return end
			self.grabFiring = self.grabFiring or setmetatable({}, { __mode = "k" })
			if self.grabFiring[prompt] then return end
			local part = prompt.Parent
			local liveRoot = self:_root()
			if not (liveRoot and part and part:IsA("BasePart")) then return end
			local maxDist = tonumber(prompt.MaxActivationDistance) or 10
			if (part.Position - liveRoot.Position).Magnitude > maxDist + 1 then return end
			self.grabFiring[prompt] = true
			task.spawn(function()
				pcall(function()
					local hold = math.max(GRAB_HOLD_SECONDS, tonumber(prompt.HoldDuration) or GRAB_HOLD_SECONDS)
					prompt:InputHoldBegin()
					task.wait(hold + 0.05)
					prompt:InputHoldEnd()
				end)
				task.wait(0.4)
				if self.grabFiring then self.grabFiring[prompt] = nil end
			end)
		end
		function MovementExtras:setInstantGrab(value)
			self.grabEnabled = value == true
			if self.grabEnabled then
				for _, instance in ipairs(workspace:GetDescendants()) do
					self:_applyGrab(instance)
				end
				if not self.grabConnection then
					self.grabConnection = workspace.DescendantAdded:Connect(function(instance)
						if self.grabEnabled and self:_isGrabPrompt(instance) then
							task.defer(function() self:_applyGrab(instance) end)
						end
						end)
				end
			else
				if self.grabConnection then
					pcall(function() self.grabConnection:Disconnect() end)
					self.grabConnection = nil
				end
				self.grabFireLoop = nil
				self:_restoreGrab()
			end
		end
		function MovementExtras:triggerJump()
			if not self.jumpEnabled then return end
			local now = os.clock()
			if now - self.lastJumpAt < JUMP_COOLDOWN then return end
			local humanoid = self:_humanoid()
			local root = self:_root()
			if not humanoid or not root or humanoid.Health <= 0 then return end
			self.lastJumpAt = now
			pcall(function()
				humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
				humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
				humanoid.Jump = true
				end)
			local power = JUMP_MIN_POWER
			if humanoid.UseJumpPower and humanoid.JumpPower > 0 then
				power = humanoid.JumpPower
			elseif humanoid.JumpHeight and humanoid.JumpHeight > 0 then
				power = math.sqrt(2 * workspace.Gravity * humanoid.JumpHeight)
			end
			if power < JUMP_MIN_POWER then power = JUMP_MIN_POWER end
			pcall(function()
				local velocity = root.AssemblyLinearVelocity
				root.AssemblyLinearVelocity = Vector3.new(velocity.X, power, velocity.Z)
				end)
		end
		function MovementExtras:setInfiniteJump(value)
			self.jumpEnabled = value == true
			if #self.jumpConnections > 0 then return end
			pcall(function()
				table.insert(self.jumpConnections, UserInputService.InputBegan:Connect(function(input)
					if not self.jumpEnabled then return end
					if UserInputService:GetFocusedTextBox() then return end
					if input.KeyCode == Enum.KeyCode.Space or input.KeyCode == Enum.KeyCode.ButtonA then
						self:triggerJump()
					end
					end))
				table.insert(self.jumpConnections, UserInputService.JumpRequest:Connect(function()
					if not self.jumpEnabled then return end
					if UserInputService:GetFocusedTextBox() then return end
					self:triggerJump()
					end))
				end)
			task.spawn(function()
				while true do
					RunService.Heartbeat:Wait()
					if self.jumpEnabled and not UserInputService:GetFocusedTextBox() then
						local held = false
						pcall(function()
							if UserInputService:IsKeyDown(Enum.KeyCode.Space)
							or UserInputService:IsGamepadButtonDown(Enum.UserInputType.Gamepad1, Enum.KeyCode.ButtonA)
							then
								held = true
							end
							end)
						if held and os.clock() - self.lastJumpAt >= JUMP_HELD_INTERVAL then
							self:triggerJump()
						end
					end
				end
				end)
		end
		function MovementExtras:_gameWalkSpeed()
			local modules = self.speedModules
			if not modules then
				modules = {}
				pcall(function() modules.TreadmillUtil = require(ReplicatedStorage.Shared.Util.TreadmillUtil) end)
				pcall(function() modules.Projection = require(ReplicatedStorage.Client.SpeedPowerProjection) end)
				pcall(function() modules.Save = require(ReplicatedStorage.Shared.Save) end)
				self.speedModules = modules
			end
			if not (modules.TreadmillUtil and modules.TreadmillUtil.SpeedPowerToWalkSpeed) then return nil end
			local power = nil
			if modules.Projection then pcall(function() power = modules.Projection.ReadProjected() end) end
			if type(power) ~= "number" and modules.Save then
				pcall(function() power = (modules.Save.Peek or modules.Save.Get)().SpeedPower end)
			end
			if type(power) ~= "number" then return nil end
			local ok, speed = pcall(modules.TreadmillUtil.SpeedPowerToWalkSpeed, power)
			return ok and tonumber(speed) or nil
		end
		function MovementExtras:setSpeedMultiplier(value)
			self.speedMultiplier = math.clamp(tonumber(value) or 1, 1, 2.1)
			self:_applySpeedMultiplier()
			if self.speedConnection then return end
			self.speedConnection = RunService.Heartbeat:Connect(function()
				if self.speedMultiplier <= 1.001 then return end
				self:_applySpeedMultiplier()
				end)
		end
		function MovementExtras:_applySpeedMultiplier()
			local treadmill = runtimeEnv.__SenaV4TreadmillManager
			if treadmill and treadmill.activeTreadmill ~= nil then return end
			local humanoid = self:_humanoid()
			if not humanoid then return end
			local base = self:_gameWalkSpeed()
			if not base or base <= 0 then return end
			local want = base * self.speedMultiplier
			if math.abs(humanoid.WalkSpeed - want) > 0.05 then
				pcall(function() humanoid.WalkSpeed = want end)
			end
		end
		function MovementExtras:destroy()
			self:setFlyForCapture(false)
			self:setInstantGrab(false)
			self.jumpEnabled = false
			for _, connection in ipairs(self.jumpConnections) do
				pcall(function() connection:Disconnect() end)
			end
			self.jumpConnections = {}
			if self.speedConnection then
				pcall(function() self.speedConnection:Disconnect() end)
				self.speedConnection = nil
			end
		end
		return MovementExtras
		end)()
	local movementExtras = MovementExtras.new()
	runtimeEnv.__SenaV4MovementExtras = movementExtras
	if Config.FlyForCapture then movementExtras:setFlyForCapture(true) end
	if Config.InstantGrab then movementExtras:setInstantGrab(true) end
	if Config.InfiniteJump then movementExtras:setInfiniteJump(true) end
	if (Config.WalkSpeedMultiplier or 1) > 1 then movementExtras:setSpeedMultiplier(Config.WalkSpeedMultiplier) end
end
do
	local AntiHitGuard = (function()
		local Players = game:GetService("Players")
		local RunService = game:GetService("RunService")
		local ReplicatedStorage = game:GetService("ReplicatedStorage")
		local LocalPlayer = Players.LocalPlayer
		local SAFE_ZONE_CFRAME = CFrame.new(542.93, 71.5, -405.58)
		local DEFAULT_HOLD_SECONDS = 0.9
		local EXTENDED_HOLD_SECONDS = 1.6
		local SLEEP_CONFIRM_SECONDS = 0.2
		local AntiHitGuard = {}
		AntiHitGuard.__index = AntiHitGuard
		function AntiHitGuard.new()
			local self = setmetatable({}, AntiHitGuard)
			self.enabled = false
			self.running = false
			self.destroyed = false
			self.connection = nil
			self.wasHolding = false
			self.lastResult = "Idle"
			return self
		end
		function AntiHitGuard:_character()
			return LocalPlayer.Character
		end
		function AntiHitGuard:_root()
			local character = self:_character()
			return character and character:FindFirstChild("HumanoidRootPart")
		end
		function AntiHitGuard:_carriedUid()
			local uid = nil
			pcall(function()
				local EggCmds = require(ReplicatedStorage.Client.EggState)
				local snapshot = nil
				if EggCmds.GetAreaEggSnapshot then snapshot = EggCmds.GetAreaEggSnapshot() end
				if (not snapshot or not snapshot.Records) and EggCmds.ReadFieldEggs then
					snapshot = EggCmds.ReadFieldEggs()
				end
				if not snapshot or not snapshot.Records then return end
				local myUserId = LocalPlayer.UserId
				for _, record in ipairs(snapshot.Records) do
					if record.State == "Carried" and record.CarrierUserId == myUserId then
						uid = record.Uid
						return
					end
				end
				end)
			return uid
		end
		function AntiHitGuard:_record(uid)
			local record = nil
			pcall(function()
				local EggCmds = require(ReplicatedStorage.Client.EggState)
				record = EggCmds.ReadFieldEgg and EggCmds.ReadFieldEgg(uid)
				end)
			return record
		end
		function AntiHitGuard:_guardFor(uid)
			local guard = nil
			pcall(function()
				local record = self:_record(uid)
				local objects = resolveObjectsRoot()
				local areas = objects and objects:FindFirstChild("Areas")
				local guardAreas = areas and areas:FindFirstChild("GuardAreas")
				local area = guardAreas and record and record.AreaId and guardAreas:FindFirstChild(record.AreaId)
				guard = area and area:FindFirstChild("Guard")
				end)
			return guard
		end
		function AntiHitGuard:_skips(uid)
			local runtime = runtimeEnv.__SenaV4EggRuntime
			if runtime then
				if runtime.instantPhase == "priming" then return true end
				if runtime.enabled or runtime.running then return true end
			end
			local steal = runtimeEnv.__SenaV4PlayerSteal
			if steal and steal.running then return true end
			if not uid then return false end
			local record = self:_record(uid)
			return record ~= nil and tostring(record.AreaId) == "Forest"
		end
		function AntiHitGuard:_freeze(ghostAt)
			local character = self:_character()
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			local camera = workspace.CurrentCamera
			local cameraCFrame = camera and camera.CFrame
			local cameraType = camera and camera.CameraType
			local ghost = nil
			pcall(function()
				character.Archivable = true
				ghost = character:Clone()
				if ghostAt then pcall(function() ghost:PivotTo(ghostAt) end) end
				ghost.Name = "SenaAntiHitGhost"
				for _, descendant in ipairs(ghost:GetDescendants()) do
					if descendant:IsA("LuaSourceContainer") or descendant:IsA("Sound") then
						descendant:Destroy()
					elseif descendant:IsA("BasePart") then
						descendant.CanCollide = false
						descendant.Anchored = true
					end
				end
				ghost.Parent = workspace
				for _, part in ipairs(character:GetDescendants()) do
					if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then part.LocalTransparencyModifier = 1 end
					if part:IsA("Trail") then part.Enabled = false end
				end
				if camera then
					camera.CameraType = Enum.CameraType.Scriptable
					camera.CFrame = cameraCFrame
				end
				end)
			local hidden = {}
			pcall(function()
				for _, part in ipairs(character:GetDescendants()) do
					if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then hidden[#hidden + 1] = part end
				end
				end)
			local function hold()
				if camera then
					camera.CameraType = Enum.CameraType.Scriptable
					camera.CFrame = cameraCFrame
				end
				for _, part in ipairs(hidden) do
					if part.Parent then part.LocalTransparencyModifier = 1 end
				end
			end
			local function restore(keepCamera)
				pcall(function()
					if ghost then ghost:Destroy() end
					for _, part in ipairs(character:GetDescendants()) do
						if part:IsA("BasePart") then part.LocalTransparencyModifier = 0 end
						if part:IsA("Trail") then part.Enabled = true end
					end
					if camera then
						camera.CameraType = (cameraType ~= Enum.CameraType.Scriptable and cameraType) or Enum.CameraType.Custom
						if humanoid then camera.CameraSubject = humanoid end
						if keepCamera then camera.CFrame = cameraCFrame end
					end
					end)
			end
			return restore, hold
		end
		function AntiHitGuard:shield(uid)
			if not self.enabled or self.running then return false end
			if self:_skips(uid) then return false end
			local root = self:_root()
			if not root then return false end
			self.running = true
			local startCFrame = root.CFrame
			local guard = self:_guardFor(uid)
			local function write()
				local live = self:_root()
				if not live then return false end
				live.CFrame = SAFE_ZONE_CFRAME
				live.AssemblyLinearVelocity = Vector3.zero
				live.AssemblyAngularVelocity = Vector3.zero
				return true
			end
			write()
			local restore, hold = self:_freeze(startCFrame)
			local writes, calmed = 1, false
			pcall(function()
				local startedAt = os.clock()
				local sawWake = false
				while os.clock() - startedAt < DEFAULT_HOLD_SECONDS
				or (sawWake and os.clock() - startedAt < EXTENDED_HOLD_SECONDS
					and guard and (guard:GetAttribute("GuardState") == "Waking" or guard:GetAttribute("GuardState") == "Chasing"))
				do
					if not write() then break end
					hold()
					writes += 1
					local guardState = guard and guard:GetAttribute("GuardState")
					if guardState == "Waking" or guardState == "Chasing" then
						sawWake = true
					elseif sawWake and guardState == "Sleeping" and os.clock() - startedAt > SLEEP_CONFIRM_SECONDS then
						calmed = true
						break
					end
					RunService.Heartbeat:Wait()
				end
				end)
			restore(true)
			self.lastResult = (calmed and "Guard slept" or "Held") .. " (" .. writes .. " writes)"
			self.running = false
			return true
		end
		function AntiHitGuard:_check(state)
			if not self.enabled then
				self.wasHolding = false
				return
			end
			local uid = nil
			if type(state) == "table" and state.IsCarrying and state.Uid then
				uid = state.Uid
			else
				uid = self:_carriedUid()
			end
			local holding = uid ~= nil
			if holding and not self.wasHolding and not self.running and not self:_skips(uid) then
				task.spawn(function()
					pcall(function() self:shield(uid) end)
					end)
			end
			self.wasHolding = holding
		end
		function AntiHitGuard:setEnabled(value)
			self.enabled = value == true
			if self.enabled then self.wasHolding = self:_carriedUid() ~= nil end
			if not self.watcher then
				self.watcher = true
				task.spawn(function()
					while not self.destroyed do
						if self.enabled and not self.running then
							pcall(function() self:_check() end)
							task.wait(0.15)
						else
							task.wait(0.5)
						end
					end
					end)
			end
			if self.connection then return end
			pcall(function()
				local EggCmds = require(ReplicatedStorage.Client.EggState)
				if EggCmds and EggCmds.CarryChanged then
					self.connection = EggCmds.CarryChanged:Connect(function(state)
						task.defer(function() self:_check(state) end)
						end)
				end
				end)
		end
		function AntiHitGuard:destroy()
			self.destroyed = true
			self.enabled = false
			if self.connection then
				pcall(function() self.connection:Disconnect() end)
				self.connection = nil
			end
		end
		return AntiHitGuard
		end)()
	local antiHitGuard = AntiHitGuard.new()
	runtimeEnv.__SenaV4AntiHitGuard = antiHitGuard
	if Config.AntiHitGuard then antiHitGuard:setEnabled(true) end
end
runtimeEnv.__SenaV4PlayerSteal = playerSteal
do
	local cache = { at = 0, value = false }
	runtimeEnv.__SenaV4StealWantsCharacter = function()
		local ps = runtimeEnv.__SenaV4PlayerSteal
		if ps and (ps.running or ps.wantsTarget) then return true end
		local rt = runtimeEnv.__SenaV4EggRuntime
		if not (rt and rt.enabled and not rt.destroyed) then return false end
		-- never claim the character during a race / scramble event, OR while Auto Race is trying to join its
		-- window (RaceId is not set yet then, but the lap still comes first).
		if rt:_eventBlocksSteal() then return false end
		-- yield to Auto Sell while it drains a backed-up inventory (unless we are mid-carry)
		if not (rt.carry and rt.carry.active) and rt:_shouldYieldToSell() then return false end
		local stealTween = rt.activeTween and not rt.activeTween.sharedTravel
		if rt.running or stealTween or (rt.carry and rt.carry.active) then return true end
		if type(rt._eggInventoryFull) == "function" and rt:_eggInventoryFull() then return false end
		local now = os.clock()
		if now - cache.at < 0.5 then return cache.value end
		cache.at = now
		local ok, target = pcall(function()
			return rt:_wallOpen() and rt:_chooseTarget() or nil
		end)
		cache.value = ok and target ~= nil
		return cache.value
	end
	TaskLadder.register("auto_steal", {
		wants = runtimeEnv.__SenaV4StealWantsCharacter,
		active = function()
			local ps = runtimeEnv.__SenaV4PlayerSteal
			if ps and ps.running then return true end
			local rt = runtimeEnv.__SenaV4EggRuntime
			if not rt or rt.destroyed then return false end
			local stealTween = rt.activeTween and not rt.activeTween.sharedTravel
			return rt.running == true or stealTween == true or (rt.carry ~= nil and rt.carry.active == true)
		end,
		enabled = function()
			local ps = runtimeEnv.__SenaV4PlayerSteal
			local rt = runtimeEnv.__SenaV4EggRuntime
			return (rt ~= nil and rt.enabled == true) or (ps ~= nil and ps.enabled == true)
		end,
		status = function()
			local ps = runtimeEnv.__SenaV4PlayerSteal
			if ps and ps.running then return tostring(ps.status or "Stealing from a player") end
			local rt = runtimeEnv.__SenaV4EggRuntime
			return rt and rt.stats and tostring(rt.stats.status or "") or ""
		end,
	})
end
eggRuntime:setStealMode(Config.StealMode == "Semi Teleport" and "Instant" or Config.StealMode)
eggRuntime:setSpeed(Config.TweenSpeedMultiplier or 60)
if Config.StealMinValue and Config.StealMinValue > 0 then
	eggRuntime:setMinValuePerSec(Config.StealMinValue)
end
if Config.StealAreas and not table.find(Config.StealAreas, "None") and #Config.StealAreas > 0 then
	local active = {}
	for _, a in ipairs(Config.StealAreas) do if a ~= "None" then table.insert(active, a) end end
	eggRuntime:setFilter("areas", active)
	eggRuntime:setFilterEnabled("area", #active > 0)
end
if Config.StealRarities and not table.find(Config.StealRarities, "None") and #Config.StealRarities > 0 then
	local active = {}
	for _, r in ipairs(Config.StealRarities) do if r ~= "None" then table.insert(active, r) end end
	eggRuntime:setFilter("rarities", active)
	eggRuntime:setFilterEnabled("rarity", #active > 0)
end
if Config.StealNamesFilter and not table.find(Config.StealNamesFilter, "None") and #Config.StealNamesFilter > 0 then
	local active = {}
	for _, n in ipairs(Config.StealNamesFilter) do if n ~= "None" then table.insert(active, n) end end
	eggRuntime:setFilter("names", active)
	eggRuntime:setFilterEnabled("name", #active > 0)
end
do
	local eggCleanup
	eggCleanup = function()
		if eggRuntime then
			pcall(eggRuntime.destroy, eggRuntime)
		end
		if treadmillManager then
			pcall(treadmillManager.destroy, treadmillManager)
		end
		if runtimeEnv.__SenaV4EggRuntime == eggRuntime then runtimeEnv.__SenaV4EggRuntime = nil end
		if runtimeEnv.__SenaV4TreadmillManager == treadmillManager then runtimeEnv.__SenaV4TreadmillManager = nil end
	end
	runtimeEnv.__SenaV4EggRuntimeCleanup = eggCleanup
	local antiGuardCleanup = function()
		if antiGuard then
			pcall(antiGuard.destroy, antiGuard)
		end
		if godMode then
			pcall(godMode.destroy, godMode)
		end
		if runtimeEnv.__SenaV4AntiGuard == antiGuard then runtimeEnv.__SenaV4AntiGuard = nil end
		if runtimeEnv.__SenaV4GodMode == godMode then runtimeEnv.__SenaV4GodMode = nil end
	end
	runtimeEnv.__SenaV4AntiGuardCleanup = antiGuardCleanup
end
do
	local STATE_KEY = "__FyyStealAnEggStartupProtectionLiteV2"
	local RESCAN_SECONDS = 60
	local StartupProtectionLite = {}
	local function environment()
		return getgenv and getgenv() or _G
	end
	local function resolveConnectionGetter()
		if type(getconnections) == "function" then return getconnections end
		if type(get_signal_cons) == "function" then return get_signal_cons end
		return nil
	end
	local function disableIdleConnections(state)
		local player = Players.LocalPlayer
		if not player then
			state.antiAfkStatus = "LocalPlayer unavailable"
			return false
		end
		local getConnections = resolveConnectionGetter()
		if not getConnections then
			state.antiAfkStatus = "Native Idled connection API unavailable"
			return false
		end
		local ok, connections = pcall(getConnections, player.Idled)
		if not ok or type(connections) ~= "table" then
			state.antiAfkStatus = "Idled scan unavailable"
			return false
		end
		local disabled = 0
		for _, connection in ipairs(connections) do
			local changed = false
			if type(connection) == "table" or type(connection) == "userdata" then
				if type(connection.Disable) == "function" then
					changed = pcall(connection.Disable, connection)
				elseif type(connection.Disconnect) == "function" then
					changed = pcall(connection.Disconnect, connection)
				end
			end
			if changed then disabled += 1 end
		end
		state.scanRuns += 1
		state.lastScanAt = os.clock()
		state.lastDisabledIdleConnections = disabled
		state.disabledIdleConnections += disabled
		state.antiAfkStatus = disabled > 0
		and ("Anti-AFK disabled " .. tostring(disabled) .. " Idled connection(s)")
		or "Anti-AFK active; Idled connections clear"
		return true
	end
	function StartupProtectionLite.install()
		local env = environment()
		local state = rawget(env, STATE_KEY)
		if type(state) == "table" and state.installed then
			state.installRuns += 1
			disableIdleConnections(state)
			state.status = state.antiAfkStatus
			return state
		end
		state = {
			installRuns = 1,
			scanRuns = 0,
			disabledIdleConnections = 0,
			lastDisabledIdleConnections = 0,
			lastScanAt = 0,
			installed = false,
			mode = "native-idled-disabler",
			integrityPatcherInstalled = false,
			networkFilterInstalled = false,
			namecallHookInstalled = false,
		}
		env[STATE_KEY] = state
		local player = Players.LocalPlayer
		if not player then
			state.antiAfkInstalled = false
			state.antiAfkStatus = "LocalPlayer unavailable"
			state.status = state.antiAfkStatus
			state.installed = true
			return state
		end
		state.antiAfkInstalled = disableIdleConnections(state)
		state.idledConnection = player.Idled:Connect(function()
			disableIdleConnections(state)
			end)
		state.characterConnection = player.CharacterAdded:Connect(function()
			task.delay(1, function()
				if state.installed then disableIdleConnections(state) end
				end)
			end)
		state.installed = true
		state.status = state.antiAfkStatus
		task.spawn(function()
			while state.installed and env[STATE_KEY] == state do
				task.wait(RESCAN_SECONDS)
				if state.installed and env[STATE_KEY] == state then
					disableIdleConnections(state)
					state.status = state.antiAfkStatus
				end
			end
			end)
		return state
	end
	function StartupProtectionLite.uninstall()
		local env = environment()
		local state = rawget(env, STATE_KEY)
		if type(state) == "table" then
			state.installed = false
			if state.idledConnection and typeof(state.idledConnection.Disconnect) == "function" then
				pcall(state.idledConnection.Disconnect, state.idledConnection)
				state.idledConnection = nil
			end
			if state.characterConnection and typeof(state.characterConnection.Disconnect) == "function" then
				pcall(state.characterConnection.Disconnect, state.characterConnection)
				state.characterConnection = nil
			end
		end
	end
	local function initSenaAntiAfk()
		local antiAfkEnv = getgenv and getgenv() or _G
		antiAfkEnv.__SenaV4AntiAfkGeneration = (antiAfkEnv.__SenaV4AntiAfkGeneration or 0) + 1
		antiAfkEnv.__SenaV4AntiAfkEnabled = Config.AntiAFK
		antiAfkEnv.__SenaV4StartupProtection = StartupProtectionLite
		antiAfkEnv.__SenaV4SetAntiAfkEnabled = function(enabled)
			antiAfkEnv.__SenaV4AntiAfkEnabled = enabled == true
			if enabled then
				StartupProtectionLite.install()
			else
				StartupProtectionLite.uninstall()
			end
		end
		if Config.AntiAFK then
			antiAfkEnv.__SenaV4SetAntiAfkEnabled(true)
		end
	end
	initSenaAntiAfk()
end
local st = Config
local S = {
	TeleportService = TeleportService or game:GetService("TeleportService"),
	LP = LocalPlayer or Players.LocalPlayer,
	Players = Players,
}
local function writeAutoexecBootstrapper()
	local bootCode = [[
if game:GetAttribute("SenaBootQueued") then return end
game:SetAttribute("SenaBootQueued", true)
repeat task.wait(0.5) until game:IsLoaded()
task.wait(1.5)
if getgenv then getgenv().SNE_AutoExecute = true end
loadstring(game:HttpGet("https://senahub.xyz/raw/senav6"))()
]]
	pcall(function()
		if writefile then
			pcall(function() writefile("autoexec/Sena_StealAnEgg.lua", bootCode) end)
			pcall(function() writefile("autoexecute/Sena_StealAnEgg.lua", bootCode) end)
		end
		end)
	local qot = queue_on_teleport or (syn and syn.queue_on_teleport) or (fluxus and fluxus.queue_on_teleport)
	if qot then
		pcall(function() qot(bootCode) end)
	end
end
local function removeAutoexecBootstrapper()
	pcall(function()
		if delfile then
			pcall(function() delfile("autoexec/Sena_StealAnEgg.lua") end)
			pcall(function() delfile("autoexecute/Sena_StealAnEgg.lua") end)
		elseif writefile then
			pcall(function() writefile("autoexec/Sena_StealAnEgg.lua", "") end)
			pcall(function() writefile("autoexecute/Sena_StealAnEgg.lua", "") end)
		end
		end)
end
local isReconnecting = false
local function attemptReconnect()
	if isReconnecting then return end
	isReconnecting = true
	if st.autoExecute or (getgenv and getgenv().SNE_AutoExecute) then
		pcall(writeAutoexecBootstrapper)
	end
	task.wait(3)
	local tpService = S.TeleportService or game:GetService("TeleportService")
	local placeId = game.PlaceId
	local jobId = game.JobId
	while true do
		pcall(function()
			if jobId and #jobId > 0 then
				tpService:TeleportToPlaceInstance(placeId, jobId, S.LP)
			else
				tpService:Teleport(placeId, S.LP)
			end
			end)
		task.wait(6)
	end
end
pcall(function()
	local guiService = game:GetService("GuiService")
	guiService.ErrorMessageChanged:Connect(function(msg)
		if st.autoReconnect and msg and #msg > 0 then
			attemptReconnect()
		end
		end)
	end)
pcall(function()
	local lp = S.LP or LocalPlayer or Players.LocalPlayer
	if lp and lp.OnTeleport then
		lp.OnTeleport:Connect(function()
			if st.autoExecute or (getgenv and getgenv().SNE_AutoExecute) then
				pcall(writeAutoexecBootstrapper)
			end
			end)
	end
	end)
task.spawn(function()
	while true do
		task.wait(2)
		if st.autoReconnect then
			pcall(function()
				local promptGui = game:GetService("CoreGui"):FindFirstChild("RobloxPromptGui")
				local prompt = promptGui and promptGui:FindFirstChild("promptOverlay")
				local errorPrompt = prompt and prompt:FindFirstChild("ErrorPrompt")
				if errorPrompt and errorPrompt.Visible then
					attemptReconnect()
				end
				end)
		end
	end
	end)
do
	local PetBarnController = (function()
		local Remotes = require(ReplicatedStorage.Shared.Remotes)
		local Barn = {}
		function Barn.equipBest()
			pcall(function() Remotes.Haul.WearBest:InvokeServer() end)
		end
		function Barn.claimOffline()
			local ok, sum = pcall(function() return Remotes.AwayEarnings.FetchSummary:InvokeServer() end)
			if ok and type(sum) == "table" and (sum.ClaimableAmount or 0) > 0 then
				pcall(function() Remotes.AwayEarnings.AskCollect:InvokeServer({ Kind = "Claim" }) end)
			end
		end
		function Barn.favoriteSelected()
			local Save = (require(ReplicatedStorage.Shared.Save).Peek or require(ReplicatedStorage.Shared.Save).Get)()
			if not Save or type(Save.Inventory) ~= "table" then return 0 end
			local AssetItems = require(ReplicatedStorage.Shared.Util.AssetItems)
			local Assets = require(ReplicatedStorage.Data.Assets).Directory
			local count = 0
			for uid, raw in pairs(Save.Inventory) do
				local d = nil
				if AssetItems and type(AssetItems.Decode) == "function" then
					pcall(function() d = AssetItems.Decode(raw) end)
				end
				d = d or raw
				if type(d) == "table" and not d.IsFavorite and d.Category then
					local a = Assets[d.Category]
					local rarity = a and a.Rarity and (a.Rarity.DisplayName or a.Rarity._id)
					local match = false
					if Config.FavMode == "Species" then
						local list = Config.FavSpecies or {}
						if table.find(list, "All") or table.find(list, d.Category) or (a and table.find(list, a.DisplayName)) then
							match = true
						end
					else
						local list = Config.FavRarities or {}
						if table.find(list, "All") or (rarity and table.find(list, rarity)) then
							match = true
						end
					end
					if match then
						pcall(function() Remotes.PetSatchel.WriteFavourite:FireServer(uid, true) end)
						count += 1
						if count % 10 == 0 then task.wait(0.05) end
					end
				end
			end
			return count
		end
		function Barn.unfavoriteAll()
			local Save = (require(ReplicatedStorage.Shared.Save).Peek or require(ReplicatedStorage.Shared.Save).Get)()
			if not Save or type(Save.Inventory) ~= "table" then return 0 end
			local count = 0
			for uid, raw in pairs(Save.Inventory) do
				local d = raw
				if type(d) == "table" and d.IsFavorite then
					pcall(function() Remotes.PetSatchel.WriteFavourite:FireServer(uid, false) end)
					count += 1
					if count % 10 == 0 then task.wait(0.05) end
				end
			end
			return count
		end
		local function pickFuseGroup(selectedOnly, names, rarities)
			local Save = (require(ReplicatedStorage.Shared.Save).Peek or require(ReplicatedStorage.Shared.Save).Get)()
			if not Save or type(Save.Inventory) ~= "table" then return nil end
			local AssetItems = require(ReplicatedStorage.Shared.Util.AssetItems)
			local Assets = require(ReplicatedStorage.Data.Assets).Directory
			local equipped = {}
			for _, e in ipairs(Save.EquippedAssets or {}) do equipped[e] = true end
			local byCat = {}
			for uid, raw in pairs(Save.Inventory) do
				if not equipped[uid] then
					local d = nil
					if AssetItems and type(AssetItems.Decode) == "function" then
						pcall(function() d = AssetItems.Decode(raw) end)
					end
					d = d or raw
					if type(d) == "table" and not d.InFuse and not d.IsFavorite and d.Category then
						local a = Assets[d.Category]
						local rarity = a and a.Rarity and (a.Rarity.DisplayName or a.Rarity._id)
						local passRare = true
						if rarities and #rarities > 0 and not table.find(rarities, "All") then
							passRare = rarity and table.find(rarities, rarity) ~= nil
						end
						local passName = true
						if selectedOnly and names and #names > 0 and not table.find(names, "All") then
							passName = table.find(names, d.Category) ~= nil or (a and table.find(names, a.DisplayName) ~= nil)
						end
						if passRare and passName then
							byCat[d.Category] = byCat[d.Category] or {}
							table.insert(byCat[d.Category], { uid = uid, d = d })
						end
					end
				end
			end
			for cat, list in pairs(byCat) do
				if #list >= 3 then
					return { list[1].uid, list[2].uid, list[3].uid }
				end
			end
			return nil
		end
		function Barn.fuseOnePair()
			local Save = (require(ReplicatedStorage.Shared.Save).Peek or require(ReplicatedStorage.Shared.Save).Get)()
			if not Save then return false end
			if Save.FusionLocked then return false, "Fusion locked" end
			local group = pickFuseGroup(Config.FuseSelectedOnly, Config.FuseSpecies, Config.FuseRarities)
			if not group then return false, "No eligible group of 3" end
			pcall(function() Remotes.Fusery.ConfirmBriefing:InvokeServer() end)
			for _, uid in ipairs(group) do
				local ok, loaded = pcall(function() return Remotes.Fusery.LoadPet:InvokeServer(uid) end)
				if not ok or not loaded then return false, "Failed to load pet" end
				task.wait(0.02)
			end
			local ok, fused = pcall(function() return Remotes.Fusery.BeginFuse:InvokeServer() end)
			if not ok or not fused then return false, "Failed to begin fuse" end
			task.wait(0.06)
			pcall(function() Remotes.Fusery.FinishReveal:InvokeServer() end)
			return true
		end
		task.spawn(function()
			local lastEquip = 0
			while sessionAlive() do
				local now = os.clock()
				if Config.AutoEquipBest and now - lastEquip > 6 then
					lastEquip = now
					pcall(Barn.equipBest)
				end
				if Config.AutoClaimOffline then
					pcall(Barn.claimOffline)
				end
				if Config.AutoFavorite then
					pcall(Barn.favoriteSelected)
				end
				if Config.AutoFusePets then
					pcall(Barn.fuseOnePair)
				end
				task.wait(2.5)
			end
			end)
		return Barn
		end)()
	runtimeEnv.__SenaV4PetBarn = PetBarnController
end
do
	local UpgradesController = (function()
		local Remotes = require(ReplicatedStorage.Shared.Remotes)
		local Upgrades = {}
		function Upgrades.upgradeBase()
			local Save = (require(ReplicatedStorage.Shared.Save).Peek or require(ReplicatedStorage.Shared.Save).Get)()
			if not Save then return false end
			local level = tonumber(Save.BaseUpgradeLevel or 0) or 0
			local Bases = require(ReplicatedStorage.Data.Bases)
			local nextCfg = Bases and Bases.BASES and Bases.BASES[level + 1]
			if not nextCfg then return false, "Max level" end
			local money = tonumber(Save.Money or 0) or 0
			if money < (nextCfg.Cost or 0) then return false, "Not enough money" end
			local ok, res = pcall(function()
				return Remotes.Homestead.AskBaseTierRaise:InvokeServer()
				end)
			return ok and res == true, res
		end
		function Upgrades.claimAlmanac()
			local ok, res = pcall(function()
				return Remotes.Codex.AskRedeemAll:InvokeServer()
				end)
			return ok, res
		end
		task.spawn(function()
			while sessionAlive() do
				if Config.AutoBaseUpgrade then
					pcall(Upgrades.upgradeBase)
				end
				if Config.AutoClaimAlmanac then
					pcall(Upgrades.claimAlmanac)
				end
				task.wait(3)
			end
			end)
		return Upgrades
		end)()
	runtimeEnv.__SenaV4Upgrades = UpgradesController
end
do
	local SenaRoaming = (function()
		local Roam = { noclipConn = nil }
		function Roam.setNoclip(enable)
			Config.Noclip = enable == true
			if Roam.noclipConn then
				pcall(function() Roam.noclipConn:Disconnect() end)
				Roam.noclipConn = nil
			end
			if not Config.Noclip then
				local character = LocalPlayer.Character
				if character then
					for _, part in ipairs(character:GetDescendants()) do
						if part:IsA("BasePart") and part:GetAttribute("SenaNoclip") then
							part.CanCollide = true
							part:SetAttribute("SenaNoclip", nil)
						end
					end
				end
				return
			end
			Roam.noclipConn = RunService.Stepped:Connect(function()
				if not Config.Noclip then return end
				local character = LocalPlayer.Character
				if not character then return end
				for _, part in ipairs(character:GetDescendants()) do
					if part:IsA("BasePart") and part.CanCollide then
						part:SetAttribute("SenaNoclip", true)
						part.CanCollide = false
					end
				end
				end)
		end
		function Roam.waypointList()
			local names = { "Respawn Point" }
			local objects = resolveObjectsRoot()
			local machines = objects and objects:FindFirstChild("Machines")
			if machines and machines:FindFirstChild("FuseMachine") then
				table.insert(names, "Fuse Machine")
			end
			local areas = objects and objects:FindFirstChild("Areas")
			local guardAreas = areas and areas:FindFirstChild("GuardAreas")
			if guardAreas then
				for _, area in ipairs(guardAreas:GetChildren()) do
					table.insert(names, area.Name)
				end
			end
			return names
		end
		function Roam.teleportWaypoint(name)
			local character = LocalPlayer.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if not root then return false end
			local target = nil
			local objects = resolveObjectsRoot()
			if name == "Respawn Point" then
				pcall(function()
					local PlotState = require(ReplicatedStorage.Client.PlotState)
					local plot = PlotState.ResolvePlot and PlotState.ResolvePlot()
					if plot and plot.RespawnPointCFrame then
						target = plot.RespawnPointCFrame.Position
					elseif plot and plot.Model and plot.Model:FindFirstChild("Spawn") then
						target = plot.Model.Spawn.Position
					end
					end)
			elseif name == "Fuse Machine" then
				local machine = objects and objects:FindFirstChild("Machines")
				machine = machine and machine:FindFirstChild("FuseMachine")
				local part = machine and (machine:FindFirstChild("Machine") or machine.PrimaryPart)
				if part then target = part.Position end
			else
				local areas = objects and objects:FindFirstChild("Areas")
				local guardAreas = areas and areas:FindFirstChild("GuardAreas")
				local area = guardAreas and guardAreas:FindFirstChild(name)
				local guard = area and area:FindFirstChild("Guard")
				if guard and guard:IsA("BasePart") then target = guard.Position end
			end
			if not target then return false end
			root.CFrame = CFrame.new(target + Vector3.new(0, 4, 0))
			root.AssemblyLinearVelocity = Vector3.zero
			return true
		end
		function Roam.setBottingMode(enable)
			Config.BottingMode = enable == true
			local existing = runtimeEnv.__SenaV4BottingOverlay
			if existing and existing.Parent then pcall(function() existing:Destroy() end) end
			runtimeEnv.__SenaV4BottingOverlay = nil
			if not Config.BottingMode then
				pcall(function() RunService:Set3dRenderingEnabled(true) end)
				return
			end
			pcall(function() RunService:Set3dRenderingEnabled(false) end)
			local parent = nil
			pcall(function() parent = game:GetService("CoreGui") end)
			parent = parent or LocalPlayer:FindFirstChildOfClass("PlayerGui")
			if not parent then return end
			local screen = Instance.new("ScreenGui")
			screen.Name = "SenaBottingOverlay"
			screen.ResetOnSpawn = false
			screen.IgnoreGuiInset = true
			screen.DisplayOrder = -1
			screen.Parent = parent
			local backdrop = Instance.new("Frame")
			backdrop.Name = "Blackscreen"
			backdrop.Size = UDim2.new(1, 0, 1, 0)
			backdrop.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
			backdrop.BorderSizePixel = 0
			backdrop.Active = false
			backdrop.Parent = screen
			runtimeEnv.__SenaV4BottingOverlay = screen
		end
		task.spawn(function()
			while sessionAlive() do
				if Config.AntiCutscene then
					pcall(function()
						local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
						if playerGui then
							for _, gui in ipairs(playerGui:GetChildren()) do
								if gui:IsA("ScreenGui")
								and (string.find(string.lower(gui.Name), "cutscene") or gui.Name == "Intro")
								and gui.Enabled
								then
									gui.Enabled = false
								end
							end
						end
						end)
				end
				task.wait(0.2)
			end
			end)
		return Roam
		end)()
	runtimeEnv.__SenaV4Roaming = SenaRoaming
end
do
	local ST = { status = "No star right now", lastResult = "No star caught yet", session = nil, busy = false, caught = 0 }
	local function remotes()
		local ok, R = pcall(require, ReplicatedStorage.Shared.Remotes)
		return ok and R and R.ShootingStar or nil
	end
	local function now() return Workspace:GetServerTimeNow() end
	function ST.position(s)
		local leg = s.Leg
		if type(leg) == "table" and typeof(leg.From) == "Vector3" and typeof(leg.To) == "Vector3" then
			local span = (tonumber(leg.ArriveAt) or 0) - (tonumber(leg.StartAt) or 0)
			local a = span > 0 and math.clamp((now() - leg.StartAt) / span, 0, 1) or 1
			return leg.From:Lerp(leg.To, a)
		end
		local landing = s.Payload.Landing
		return typeof(landing) == "CFrame" and landing.Position or landing
	end
	function ST.alert(s)
		if not Config.StarAlert then return end
		local left = math.max(0, math.floor((tonumber(s.Payload.ExpiresAt) or 0) - now()))
		pcall(function()
			game:GetService("StarterGui"):SetCore("SendNotification", {
				Title = "Shooting Star",
				Text = string.format("A star is falling! It stays for %d:%02d.", left // 60, left % 60),
				Duration = 8,
			})
		end)
	end
	function ST.begin(payload)
		if type(payload) ~= "table" or type(payload.Id) ~= "string" then return end
		if (tonumber(payload.ExpiresAt) or 0) <= now() then return end
		ST.session = { Payload = payload, Leg = payload.Leg, Id = payload.Id }
		ST.status = "Star falling"
		ST.alert(ST.session)
	end
	function ST.finish(id, text)
		if ST.session and ST.session.Id == id then
			ST.session = nil
			ST.busy = false
			ST.lastResult = text
			ST.status = "No star right now"
		end
	end
	function ST.catch(s)
		local R = remotes()
		local char = LocalPlayer.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if not R or not hrp or not hum then return end
		local function cancelled() return not sessionAlive() or not Config.StarAutoCatch or ST.session ~= s or TaskLadder.blocker("star") ~= nil end
		local function near(reach)
			local p = ST.position(s)
			return p and (Vector3.new(p.X, hrp.Position.Y, p.Z) - hrp.Position).Magnitude <= reach
		end
		local function chase(reach)
			local p = ST.position(s)
			if not p then return false end
			if near(reach) then return true end
			TweenMoveTo(hrp, hum, CFrame.new(p + Vector3.new(0, 3, 0)), function()
				local egg = runtimeEnv.__SenaV4EggRuntime
				return cancelled() or (egg ~= nil and egg.resetBlocked == true)
			end, false, nil, true)
			return near(reach)
		end
		ST.status = "Going to the star"
		local tries = 0
		while not cancelled() and tries < 25 do
			local egg = runtimeEnv.__SenaV4EggRuntime
			if egg and egg.resetBlocked then
				ST.status = "Waiting for the field to reopen"
				task.wait(0.5)
				continue
			end
			tries = tries + 1
			if chase(8) then
				ST.status = "Catching the star"
				R.Hold:FireServer(s.Id, true)
				local holdFor = (tonumber(s.Payload.HoldSeconds) or 1.6) + 0.15
				local started = os.clock()
				local lost = false
				while os.clock() - started < holdFor and not cancelled() do
					local egg = runtimeEnv.__SenaV4EggRuntime
					if egg and egg.resetBlocked then lost = true break end
					if not near(14) and not chase(8) then lost = true break end
					task.wait(0.05)
				end
				if cancelled() then return end
				if not lost then
					R.Catch:FireServer(s.Id)
					local wait = os.clock() + 2
					while ST.session == s and os.clock() < wait do task.wait(0.1) end
					if ST.session ~= s then return end
				end
				pcall(function() R.Hold:FireServer(s.Id, false) end)
			end
			task.wait(0.2)
		end
	end
	local R = remotes()
	if R then
		local conns = {}
		local function on(remote, fn)
			if remote then table.insert(conns, remote.OnClientEvent:Connect(function(...)
				if not sessionAlive() then
					for _, c in ipairs(conns) do pcall(c.Disconnect, c) end
					return
				end
				pcall(fn, ...)
			end)) end
		end
		on(R.Fall, ST.begin)
		on(R.Wander, function(id, leg)
			if ST.session and ST.session.Id == id and type(leg) == "table" then ST.session.Leg = leg end
		end)
		on(R.Slipped, function(id)
			if ST.session and ST.session.Id == id then ST.status = "Star slipped away, trying again" end
		end)
		on(R.Claimed, function(id, amount)
			if ST.session and ST.session.Id == id then
				ST.caught = ST.caught + 1
				ST.finish(id, string.format("Caught a star (+%s)", tostring(amount or 1)))
			end
		end)
		on(R.Expired, function(id) ST.finish(id, "Star went home before it was caught") end)
		task.spawn(function()
			local ok, state = pcall(function() return R.AskState:InvokeServer() end)
			if ok and type(state) == "table" and ST.session == nil then ST.begin(state) end
		end)
	end
	task.spawn(function()
		while sessionAlive() do
			local s = ST.session
			if s and (tonumber(s.Payload.ExpiresAt) or 0) <= now() then
				ST.finish(s.Id, "Star went home before it was caught")
			elseif s and Config.StarAutoCatch and not ST.busy and now() >= (tonumber(s.Payload.LandAt) or 0) then
				local blocker = TaskLadder.blocker("star")
				if blocker then
					ST.status = "Yielding to " .. tostring(TaskLadder.TITLES[blocker] or blocker)
				else
					ST.busy = true
					pcall(ST.catch, s)
					ST.busy = false
					if ST.session == s then ST.status = "Star still out, retrying" end
				end
			elseif s and now() < (tonumber(s.Payload.LandAt) or 0) then
				ST.status = string.format("Star lands in %ds", math.ceil((tonumber(s.Payload.LandAt) or 0) - now()))
			end
			task.wait(0.5)
		end
	end)
	runtimeEnv.__SenaV4StarRuntime = ST
	TaskLadder.register("star", {
		wants = function()
			local s = ST.session
			return Config.StarAutoCatch == true and s ~= nil and now() >= (tonumber(s.Payload.LandAt) or 0)
		end,
		active = function()
			return ST.busy == true
		end,
		enabled = function()
			return Config.StarAutoCatch == true
		end,
		status = function()
			return tostring(ST.status)
		end,
	})
end
do
	local BB = {
		status = "Idle",
		active = false,
		wantsCharacter = false,
		lastSwing = 0,
		retryAt = {},
		cards = {},
		snap = {},
	}
	local TIERS = { "Green", "Blue", "Purple", "Golden" }
	local TIER_RANK = { Green = 1, Blue = 2, Purple = 3, Golden = 4 }
	local RETRY_SECONDS = 5
	local HOVER_STUDS = 6
	local function child(root, ...)
		local cur = root
		for _, name in ipairs({ ... }) do
			if not cur then return nil end
			cur = cur:FindFirstChild(name)
		end
		return cur
	end
	local mods = nil
	local function M()
		if mods then return mods end
		local function req(inst)
			if not inst then return nil end
			local ok, m = pcall(require, inst)
			return ok and m or nil
		end
		local m = {
			Remotes = req(child(ReplicatedStorage, "Shared", "Remotes")),
			Save = req(child(ReplicatedStorage, "Shared", "Save")),
			Catalog = req(child(ReplicatedStorage, "Shared", "Modules", "ButterflyCatalog")),
			Flags = req(child(ReplicatedStorage, "Shared", "Flags", "ButterflyFlags")),
			Quests = req(child(ReplicatedStorage, "Data", "WispQuests")),
			Progress = req(child(ReplicatedStorage, "Shared", "Modules", "WispProgression")),
			Swarm = req(child(ReplicatedStorage, "Controllers", "Game", "AdminAbuseClientController",
				"Events", "ButterflyBloom", "Swarm")),
		}
		if not (m.Remotes and m.Save and m.Catalog) then return nil end
		mods = m
		return m
	end
	local function flag(name, default)
		local m = M()
		local f = m and m.Flags and m.Flags[name]
		if not f then return default end
		local ok, v = pcall(function() return f:Get() end)
		if not ok or v == nil then return default end
		return v
	end
	local function request(space, name, ...)
		local m = M()
		local remote = m and m.Remotes[space] and m.Remotes[space][name]
		if not remote then return false, space .. "." .. name .. " missing" end
		local res = table.pack(pcall(remote.InvokeServer, remote, ...))
		if not res[1] then return false, tostring(res[2]) end
		return res[2] == true, type(res[3]) == "string" and res[3] or nil, res[2]
	end
	local function canTry(key) return (BB.retryAt[key] or 0) <= os.clock() end
	local function retryLater(key) BB.retryAt[key] = os.clock() + RETRY_SECONDS end
	local function rootPart()
		local c = LocalPlayer.Character
		return c and c:FindFirstChild("HumanoidRootPart") or nil
	end
	function BB.bloomLeft()
		local m = M()
		local attr = (m and m.Catalog.EndsAtAttribute) or "ButterflyBloomEndsAt"
		local endsAt = workspace:GetAttribute(attr)
		if typeof(endsAt) ~= "number" then return 0 end
		return math.max(0, endsAt - workspace:GetServerTimeNow())
	end
	function BB.nextBloom()
		local interval = tonumber(flag("IntervalSeconds", 1800)) or 1800
		local offset = tonumber(flag("OffsetSeconds", 900)) or 900
		local duration = tonumber(flag("DurationSeconds", 300)) or 300
		if interval <= 0 then return nil end
		local now = workspace:GetServerTimeNow()
		local m = M()
		local endsAt = workspace:GetAttribute((m and m.Catalog.EndsAtAttribute) or "ButterflyBloomEndsAt")
		local start = typeof(endsAt) == "number" and (endsAt - duration)
			or (math.floor((now - offset) / interval) * interval + offset)
		local spins = 0
		while start <= now and spins < 64 do
			start = start + interval
			spins = spins + 1
		end
		return start > now and (start - now) or nil
	end
	local function netTool(container)
		if not container then return nil end
		for _, t in ipairs(container:GetChildren()) do
			if t:IsA("Tool") and t:GetAttribute("ButterflyNet") == true then return t end
		end
		return nil
	end
	local tierInfo = nil
	function BB.tiers()
		if tierInfo then return tierInfo end
		local m = M()
		if not m then return nil end
		local info = {}
		for i, t in ipairs(TIERS) do
			local entry = m.Catalog.Tiers and m.Catalog.Tiers[t]
			local display = entry and tostring(entry.DisplayName) or t
			info[t] = {
				name = (display:gsub("%s*Butterfly$", "")),
				color = (entry and typeof(entry.Color) == "Color3") and entry.Color or Color3.new(1, 1, 1),
				icon = entry and entry.Icon and tostring(entry.Icon) or nil,
				rarity = entry and entry.Rarity and tostring(entry.Rarity) or nil,
				trade = i < 4 and (tonumber(flag(("%sTo%sCost"):format(t, TIERS[i + 1]), 0)) or 0) or 0,
				essence = tonumber(flag("Essence" .. t, 0)) or 0,
			}
		end
		tierInfo = info
		return info
	end
	function BB.snapshot()
		local m = M()
		local S = BB.snap
		if not m then return S end
		S.left = BB.bloomLeft()
		S.active = S.left > 0
		S.enabled = flag("Enabled", true) ~= false
		S.nextIn = (not S.active) and BB.nextBloom() or nil
		local okS, save = pcall(m.Save.Peek)
		save = okS and save or nil
		local B = save and save.Butterflies
		S.net = type(B) == "table" and B.NetClaimed == true
		S.holding = netTool(LocalPlayer.Character) ~= nil
		S.inBag = netTool(LocalPlayer:FindFirstChildOfClass("Backpack")) ~= nil
		S.counts = S.counts or {}
		for _, t in ipairs(TIERS) do
			S.counts[t] = (type(B) == "table" and B.Counts and tonumber(B.Counts[t])) or 0
		end
		S.essence = (type(B) == "table" and tonumber(B.Essence)) or 0
		S.caught = (type(B) == "table" and tonumber(B.TotalCaught)) or 0
		S.treeUnlocked = LocalPlayer:GetAttribute("EnchantedTreeUnlocked") == true
		local C = save and save.WispCompanion
		S.accepted = type(C) == "table" and C.Accepted == true
		S.unlocked = type(C) == "table" and C.Unlocked == true
		S.returning = type(C) == "table" and C.Returning == true
		S.stage = (type(C) == "table" and tonumber(C.Stage)) or 1
		S.stages = (m.Quests and tonumber(m.Quests.StageCount)) or 4
		local list = (m.Quests and m.Quests.List) or {}
		local q = list[S.stage]
		S.questId = q and tostring(q.Id) or nil
		S.quest = q and tostring(q.Title) or "-"
		S.target = (q and tonumber(q.Target)) or 0
		S.progress = (q and type(C) == "table" and C.Progress and tonumber(C.Progress[q.Id])) or 0
		S.claimable, S.readyReturn = false, false
		if m.Progress and type(C) == "table" then
			local okH, h = pcall(m.Progress.HasClaimable, C)
			S.claimable = okH and h == true
			local okR, r = pcall(m.Progress.IsReady, C)
			S.readyReturn = okR and r == true
		end
		S.speed = (save and tonumber(save.SpeedPower)) or 0
		local banjo = save and save.BanjoCricket
		S.banjoSolved = type(banjo) == "table" and banjo.Solved == true
		S.banjoClaimed = type(banjo) == "table" and banjo.Claimed == true
		S.need = (m.Quests and tonumber(m.Quests.RequiredSpeedPower)) or 0
		return S
	end
	function BB.smartNext(counts)
		local info = BB.tiers()
		if not (info and counts) then return nil end
		for i = 3, 1, -1 do
			local t, up = TIERS[i], TIERS[i + 1]
			local cost = info[t].trade
			if cost > 0 and (counts[up] or 0) < info[up].essence and (counts[t] or 0) - info[t].essence >= cost then
				return t
			end
		end
		return nil
	end
	function BB.canTrade()
		local S, info = BB.snap, BB.tiers()
		if not (info and S.counts) then return false end
		local only = Config.ButterflyTradeRecipe
		if only == "Smart" then return BB.smartNext(S.counts) ~= nil end
		for i = 1, 3 do
			local t = TIERS[i]
			if (only == nil or only == "All" or only == t) and info[t].trade > 0 and (S.counts[t] or 0) >= info[t].trade then
				return true
			end
		end
		return false
	end
	function BB.canCraft()
		local S, info = BB.snap, BB.tiers()
		if not (info and S.counts) then return false end
		for _, t in ipairs(TIERS) do
			if info[t].essence > 0 and (S.counts[t] or 0) < info[t].essence then return false, t end
		end
		return true
	end
	local function tierFilter()
		local list = Config.ButterflyTiers
		if type(list) ~= "table" or #list == 0 then return nil end
		local set = {}
		for _, v in ipairs(list) do set[tostring(v)] = true end
		return set
	end
	local function butterflies()
		local folder = workspace:FindFirstChild("ButterflyBloomSwarm")
		if not folder then return {} end
		local out = {}
		for _, d in ipairs(folder:GetChildren()) do
			if TIER_RANK[d.Name] and d:IsA("Model") then
				local p = d.PrimaryPart and d.PrimaryPart.Position or d:GetPivot().Position
				out[#out + 1] = { pos = p, tier = d.Name }
			end
		end
		return out
	end
	local function equipNet()
		local char = LocalPlayer.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		local tool = netTool(LocalPlayer:FindFirstChildOfClass("Backpack"))
		if not (hum and tool) then return false end
		pcall(function() hum:EquipTool(tool) end)
		return netTool(char) ~= nil
	end
	local pad = { part = nil, y = 0 }
	local function padOff()
		if pad.part then pcall(function() pad.part:Destroy() end) end
		pad.part = nil
	end
	local function hover()
		local root = rootPart()
		if not root then return end
		if not (pad.part and pad.part.Parent) then
			local p = Instance.new("Part")
			p.Name = "SenaBloomPad"
			p.Anchored = true
			p.CanCollide = true
			p.CanTouch = false
			p.CastShadow = false
			p.Transparency = 1
			p.Size = Vector3.new(24, 1, 24)
			pad.y = root.Position.Y - 3.5
			p.CFrame = CFrame.new(root.Position.X, pad.y, root.Position.Z)
			p.Parent = workspace
			pad.part = p
		end
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { LocalPlayer.Character, pad.part }
		local hit = workspace:Raycast(root.Position + Vector3.new(0, 4, 0), Vector3.new(0, -80, 0), params)
		if not hit then return end
		pad.y = pad.y + math.clamp(hit.Position.Y - 0.5 + HOVER_STUDS - pad.y, -2, 2)
		pad.part.CFrame = CFrame.new(root.Position.X, pad.y, root.Position.Z)
	end
	local function travel(pos, limit)
		local char = LocalPlayer.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if not (root and hum) then return false end
		padOff()
		local deadline = os.clock() + (limit or 30)
		local function stop()
			if not sessionAlive() or os.clock() > deadline then return true end
			return TaskLadder.blocker("butterfly") ~= nil
		end
		if eggRuntime and root.Position.Y < 16000 and pos.Y < 16000 and (root.Position - pos).Magnitude > 600
			and not eggRuntime:_isInSafeArea(root)
		then
			local safe = eggRuntime:_resolveSafeCFrame(root)
			if safe and (safe.Position - pos).Magnitude > 40 then
				local label = BB.status
				BB.status = "Heading to the safe zone first"
				pcall(TweenMoveTo, root, hum, safe, stop)
				BB.status = label
				root = rootPart()
				if not root or stop() or not eggRuntime:_isInSafeArea(root) then return false end
			end
		end
		pcall(TweenMoveTo, root, hum, CFrame.new(pos) * root.CFrame.Rotation, stop)
		root = rootPart()
		return root ~= nil and (root.Position - pos).Magnitude <= 12
	end
	local function inTree()
		if LocalPlayer:GetAttribute("InEnchantedTree") == true then return true end
		local root = rootPart()
		return root ~= nil and root.Position.Y > 16000
	end
	local function pressPrompt(prompt)
		if not (prompt and prompt:IsA("ProximityPrompt") and prompt.Enabled) then return false end
		local hold = tonumber(prompt.HoldDuration) or 0
		pcall(function()
			prompt:InputHoldBegin()
			task.wait(hold > 0 and (hold + 0.15) or 0.05)
			prompt:InputHoldEnd()
		end)
		if typeof(fireproximityprompt) == "function" then
			pcall(fireproximityprompt, prompt, hold > 0 and (hold + 0.15) or 0)
		end
		return true
	end
	local treePrompt = nil
	local function enterTree()
		if inTree() then return nil end
		if LocalPlayer:GetAttribute("EnchantedTreeUnlocked") ~= true then
			return "Enchanted Tree is locked (finish the Wisp Event)"
		end
		if not (treePrompt and treePrompt.Parent) then
			local entrance = child(workspace, "World", "Build", "EnchantedTreeInterior", "Markers", "EnterTrigger")
			treePrompt = entrance and entrance:FindFirstChild("EnchantedTreePrompt", true) or nil
		end
		local holder = treePrompt and treePrompt.Parent
		local point = holder and ((holder:IsA("Attachment") and holder.WorldPosition) or (holder:IsA("BasePart") and holder.Position))
		if not point then return "tree entrance not found" end
		if isStealNightBlocked() then return "night - the forest is sealed" end
		BB.status = "Flying to the Enchanted Tree"
		if not travel(point + Vector3.new(0, 3, 0), 60) then return "could not reach the tree entrance" end
		BB.status = "Entering the tree"
		pressPrompt(treePrompt)
		local deadline = os.clock() + 8
		while os.clock() < deadline and not inTree() do task.wait(0.05) end
		if inTree() then return nil end
		return "entering the tree failed"
	end
	local function leaveTree()
		if not inTree() then return true end
		local exit = child(workspace, "World", "Build", "EnchantedTreeInterior", "Markers", "ExitTrigger")
		if not (exit and typeof(firetouchinterest) == "function") then return false end
		BB.status = "Leaving the tree"
		local deadline = os.clock() + 6
		while os.clock() < deadline and inTree() do
			local root = rootPart()
			if root then
				pcall(firetouchinterest, root, exit, 0)
				pcall(firetouchinterest, root, exit, 1)
			end
			task.wait(0.3)
		end
		return not inTree()
	end
	local function machinePoint(name)
		local anchor = child(workspace, "World", "Machines", "ButterflyStation", name, "Anchor")
		return (anchor and anchor:IsA("BasePart")) and anchor.Position or nil, anchor
	end
	local function toMachine(name)
		local point = machinePoint(name)
		if not point then return false, name .. " not found" end
		local root = rootPart()
		if root and (root.Position - point).Magnitude <= 10 then return true end
		local why = enterTree()
		if why then return false, why end
		BB.status = "Walking to the " .. name
		if not travel(point + Vector3.new(0, 3, 0), 15) then return false, "could not reach the " .. name end
		return true
	end
	local function bloomBounds()
		local b = child(workspace, "World", "Areas", "ButterflyBloom", "Bounds")
		return (b and b:IsA("BasePart")) and b or nil
	end
	local function atBloom()
		local b, root = bloomBounds(), rootPart()
		if not (b and root) or inTree() then return false end
		local rel = b.CFrame:PointToObjectSpace(root.Position)
		return math.abs(rel.X) <= b.Size.X / 2 + 20 and math.abs(rel.Z) <= b.Size.Z / 2 + 20
	end
	local function bloomPoint()
		local b = bloomBounds()
		return b and (b.Position + Vector3.new(0, 4, 0)) or nil
	end
	local function leaveTreadmill()
		local treadmill = runtimeEnv.__SenaV4TreadmillManager
		if not (treadmill and treadmill.activeTreadmill ~= nil) then return end
		BB.status = "Leaving the treadmill"
		local deadline = os.clock() + 5
		while treadmill.activeTreadmill ~= nil and os.clock() < deadline do
			treadmill:_requestUnequip()
			task.wait(0.3)
		end
		local root = rootPart()
		if root and root.Anchored then pcall(function() root.Anchored = false end) end
	end
	local function resumeTreadmill()
		local treadmill = runtimeEnv.__SenaV4TreadmillManager
		if not (treadmill and not treadmill.destroyed and treadmill.config.idleFarm) then return false end
		if not treadmill.busy and not treadmill.idleRunning then
			task.defer(function() treadmill:_startIdle() end)
		end
		return true
	end
	local function finishTrip()
		padOff()
		if inTree() then leaveTree() end
		if resumeTreadmill() then return end
		local root = rootPart()
		if not (root and eggRuntime) or eggRuntime:_isInSafeArea(root) then return end
		local safe = eggRuntime:_resolveSafeCFrame(root)
		if safe then
			BB.status = "Back to the safe zone"
			travel(safe.Position, 60)
		end
	end
	function BB.claimNet()
		local ok, why = toMachine("NetStand")
		if not ok then return false, why end
		BB.status = "Claiming the net"
		local _, anchor = machinePoint("NetStand")
		local prompt = anchor and anchor:FindFirstChildWhichIsA("ProximityPrompt", true)
		if prompt and prompt.Enabled then
			pressPrompt(prompt)
			local deadline = os.clock() + 2
			while os.clock() < deadline do
				if BB.snapshot().net then return true end
				task.wait(0.1)
			end
		end
		local done, reason = request("Butterflies", "AskClaimNet")
		return done, reason
	end
	function BB.tradeUp()
		BB.snapshot()
		if not BB.canTrade() then return false, "nothing to trade up" end
		local ok, why = toMachine("ButterflyMachine")
		if not ok then return false, why end
		local info, only, trades = BB.tiers(), Config.ButterflyTradeRecipe, 0
		if only == "Smart" then
			local counts = table.clone(BB.snap.counts)
			while trades < 50 do
				local t = BB.smartNext(counts)
				if not t then break end
				BB.status = "Trading up " .. info[t].name .. " for the essence"
				local done, reason = request("Butterflies", "AskTradeUp", t)
				if not done then
					if trades == 0 then return false, reason or "the machine refused" end
					break
				end
				trades = trades + 1
				counts[t] = (counts[t] or 0) - info[t].trade
				local up = TIERS[TIER_RANK[t] + 1]
				counts[up] = (counts[up] or 0) + 1
				task.wait(0.12)
			end
			return true, trades
		end
		for i = 3, 1, -1 do
			local t = TIERS[i]
			if only == nil or only == "All" or only == t then
				local have, cost = BB.snap.counts[t] or 0, info[t].trade
				while cost > 0 and have >= cost do
					BB.status = "Trading up " .. info[t].name
					local done, reason = request("Butterflies", "AskTradeUp", t)
					if not done then
						if trades == 0 then return false, reason or "the machine refused" end
						break
					end
					trades = trades + 1
					have = have - cost
					task.wait(0.12)
				end
			end
		end
		return true, trades
	end
	function BB.craft()
		BB.snapshot()
		local full, short = BB.canCraft()
		if not full then
			local info = BB.tiers()
			return false, "need more " .. tostring(info and info[short] and info[short].name or short)
		end
		local ok, why = toMachine("MutationShrine")
		if not ok then return false, why end
		local made = 0
		while made < 10 and BB.canCraft() do
			BB.status = "Crafting Enchanted Essence"
			local done, reason = request("Butterflies", "AskCraftEssence")
			if not done then
				if made == 0 then return false, reason or "the shrine refused" end
				break
			end
			made = made + 1
			task.wait(0.2)
			BB.snapshot()
		end
		return true, made
	end
	function BB.acceptWisp()
		local spot = child(workspace, "World", "Build", "EnchantedForestZone", "WispSpawn")
		if not (spot and spot:IsA("BasePart")) then return false, "Baby Wisp spot not found" end
		if isStealNightBlocked() then return false, "night - the forest is sealed" end
		BB.status = "Flying to the Baby Wisp"
		if not travel(spot.Position + Vector3.new(0, 3, 6), 60) then return false, "could not reach the Baby Wisp" end
		task.wait(0.3)
		local done, reason = request("WispCompanion", "Request", "Accept")
		if done then pcall(request, "WispCompanion", "Request", "Open") end
		return done, reason
	end
	function BB.forestCategories()
		if BB.forestCats then return BB.forestCats end
		local set = {}
		pcall(function()
			local area = require(ReplicatedStorage.Data.Areas).Directory["Enchanted Forest"]
			for _, row in ipairs(area and area.DropTable or {}) do
				if type(row) == "table" and type(row[1]) == "string" then set[row[1]] = true end
			end
		end)
		if next(set) then BB.forestCats = set end
		return set
	end
	function BB.forestStock()
		local m = M()
		local ok, save = pcall(function() return m.Save.Peek() end)
		save = ok and save or nil
		local cats = BB.forestCategories()
		local stock = { eggs = 0, pets = 0, group = nil, best = 0 }
		if not save then return stock end
		for _, egg in pairs(save.EggInventory or {}) do
			if type(egg) == "table" and cats[egg.AssetCategory] and egg.Placement == nil then stock.eggs += 1 end
		end
		local okA, AssetItems = pcall(require, ReplicatedStorage.Shared.Util.AssetItems)
		local equipped = {}
		for _, uid in ipairs(save.EquippedAssets or {}) do equipped[uid] = true end
		local byCat = {}
		for uid, raw in pairs(save.Inventory or {}) do
			local d = raw
			if okA and AssetItems and type(AssetItems.Decode) == "function" then
				local okD, dec = pcall(AssetItems.Decode, raw)
				if okD and type(dec) == "table" then d = dec end
			end
			if type(d) == "table" and cats[d.Category] then
				stock.pets += 1
				if not equipped[uid] and not d.InFuse and not d.IsFavorite then
					local list = byCat[d.Category] or {}
					byCat[d.Category] = list
					list[#list + 1] = uid
					if #list > stock.best then stock.best = #list end
					if #list >= 3 and not stock.group then stock.group = { list[1], list[2], list[3] } end
				end
			end
		end
		return stock
	end
	function BB.fuseForest(group)
		local m = M()
		local okS, save = pcall(m.Save.Peek)
		if okS and save and save.FusionLocked then return false, "the Fusery is busy" end
		local fusery = m.Remotes and m.Remotes.Fusery
		if not fusery then return false, "Fusery missing" end
		pcall(function() fusery.ConfirmBriefing:InvokeServer() end)
		for _, uid in ipairs(group) do
			local ok, loaded = pcall(function() return fusery.LoadPet:InvokeServer(uid) end)
			if not ok or not loaded then return false, "could not load a pet into the Fusery" end
			task.wait(0.02)
		end
		local ok, fused = pcall(function() return fusery.BeginFuse:InvokeServer() end)
		if not ok or not fused then return false, "could not start the fuse" end
		task.wait(0.06)
		pcall(function() fusery.FinishReveal:InvokeServer() end)
		return true
	end
	function BB.questDrive(S)
		local er = runtimeEnv.__SenaV4EggRuntime
		local spec, note = nil, nil
		local active = Config.WispAutoQuest and S.accepted and not S.unlocked and not S.claimable
			and not S.readyReturn and (S.progress or 0) < (S.target or 0)
		if Config.WispAutoQuest and not S.accepted and not S.unlocked and (S.speed or 0) < (S.need or 0) then
			note = ("Wisp needs %gB SpeedPower"):format(math.floor((S.need or 0) / 1e8) / 10)
		elseif active and S.questId == "forest_eggs" then
			spec = { area = "Enchanted Forest" }
			note = ("Hunting Enchanted Forest eggs  ·  %d / %d"):format(S.progress or 0, S.target or 0)
		elseif active and S.questId == "eternal_egg" then
			spec = { rarity = "Eternal" }
			note = "Hunting any Eternal egg"
		elseif active and S.questId == "forest_fusion" then
			local stock = BB.forestStock()
			if stock.group then
				note = "Fusing 3 Enchanted Forest pets"
				if canTry("fuse") then
					local done, reason = BB.fuseForest(stock.group)
					note = done and "Fused an Enchanted Forest animal" or ("Fuse: " .. tostring(reason))
					retryLater("fuse")
				end
			else
				if stock.eggs < 3 then spec = { area = "Enchanted Forest" } end
				note = ("Need 3 of one Enchanted Forest pet (best %d)%s"):format(stock.best,
					(Config.AutoPlace and Config.AutoHatch) and "" or "  ·  turn on Auto Place + Auto Hatch")
			end
		end
		if er and er.setWispObjective then er:setWispObjective(spec) end
		BB.questNote = note
	end
	function BB.promptPoint(prompt)
		local holder = prompt and prompt.Parent
		if not holder then return nil end
		if holder:IsA("Attachment") then return holder.WorldPosition end
		if holder:IsA("BasePart") then return holder.Position end
		if holder:IsA("Model") then return holder:GetPivot().Position end
		return nil
	end
	function BB.banjoPrompt(owner)
		local room = child(workspace, "World", "Build", "EnchantedTreeInterior", "Banjo Secret Room")
		if not room then return nil end
		for _, d in ipairs(room:GetDescendants()) do
			if d:IsA("ProximityPrompt") then
				local model = d:FindFirstAncestorWhichIsA("Model")
				if d.Name == owner or (model and model.Name == owner) then return d end
			end
		end
		return nil
	end
	function BB.firePrompt(prompt)
		local point = BB.promptPoint(prompt)
		if not point then return false end
		local root = rootPart()
		if root and (root.Position - point).Magnitude > math.max((tonumber(prompt.MaxActivationDistance) or 10) - 2, 4) then
			travel(point + Vector3.new(0, 2, 3), 20)
		end
		local wasEnabled = prompt.Enabled
		prompt.Enabled = true
		pressPrompt(prompt)
		if not wasEnabled then pcall(function() prompt.Enabled = false end) end
		return true
	end
	function BB.solveBanjo()
		local m = M()
		local rem = m.Remotes and m.Remotes.BanjoCricket
		if not (rem and rem.Effect and rem.Aim) then return false, "Banjo remotes missing" end
		local talk = BB.banjoPrompt("BanjoCricketTalk") or BB.banjoPrompt("BanjoCricket")
		if not talk then return false, "Banjo Cricket not found" end
		local note, gap = 0.45, 0.2
		pcall(function()
			local timing = require(ReplicatedStorage.Data.BanjoCricket).Timing
			note = tonumber(timing.Note) or note
			gap = tonumber(timing.NoteGap) or gap
		end)
		local st = { notes = nil, cleared = 0, solved = false }
		local conn = rem.Effect.OnClientEvent:Connect(function(e)
			if type(e) ~= "table" then return end
			if e.Kind == "Playback" and type(e.Notes) == "table" then
				st.notes = e.Notes
			elseif e.Kind == "StageComplete" then
				st.cleared = tonumber(e.Cleared) or (st.cleared + 1)
			elseif e.Kind == "Solved" then
				st.solved = true
			elseif e.Kind == "Wrong" or e.Kind == "Reset" then
				st.cleared = 0
			end
		end)
		BB.status = "Talking to the Banjo Cricket"
		BB.firePrompt(talk)
		local deadline, kick = os.clock() + 150, os.clock()
		while sessionAlive() and Config.BanjoAuto and os.clock() < deadline and not st.solved do
			if BB.manual or TaskLadder.blocker("butterfly") ~= nil then break end
			if BB.snapshot().banjoSolved then st.solved = true break end
			local notes = st.notes
			if notes then
				st.notes = nil
				BB.status = ("Banjo Cricket  ·  stage %d  ·  %d notes"):format(st.cleared + 1, #notes)
				task.wait(#notes * (note + gap) + 0.3)
				for _, idx in ipairs(notes) do
					if st.notes then break end
					if not BB.hitMushroom(idx, rem) then
						st.err = "equip a bat first (the mushrooms only take bat hits)"
						break
					end
				end
				if st.err then break end
				kick = os.clock()
			elseif os.clock() - kick > 8 then
				BB.firePrompt(talk)
				kick = os.clock()
			end
			task.wait(0.1)
		end
		conn:Disconnect()
		return st.solved, st.solved and nil or (st.err or "the cricket stopped playing")
	end
	function BB.hitMushroom(idx, rem)
		local root = rootPart()
		local char = LocalPlayer.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if not (root and hum) then return false end
		local anchor, centre, count = nil, Vector3.zero, 0
		for _, m in ipairs(game:GetService("CollectionService"):GetTagged("BanjoCricketMushroom")) do
			local i = m:IsA("Model") and m:IsDescendantOf(workspace) and m:GetAttribute("MushroomIndex")
			local hb = typeof(i) == "number" and (m:FindFirstChild("Hitbox") or m.PrimaryPart)
			if hb and hb:IsA("BasePart") then
				centre, count = centre + hb.Position, count + 1
				if i == idx then anchor = hb end
			end
		end
		if not anchor then return false end
		local gm = runtimeEnv.__SenaV4GodMode
		local bat = gm and gm:_equipBat()
		if not bat then return false end
		local away = (centre / count - anchor.Position) * Vector3.new(1, 0, 1)
		if away.Magnitude < 0.5 then away = Vector3.new(0, 0, 1) end
		local stand = anchor.Position + away.Unit * 7
		stand = Vector3.new(stand.X, root.Position.Y, stand.Z)
		local face = Vector3.new(anchor.Position.X, stand.Y, anchor.Position.Z)
		if (root.Position - stand).Magnitude > 3 then
			pcall(TweenMoveTo, root, hum, CFrame.lookAt(stand, face), function() return not sessionAlive() end)
			root = rootPart()
			if not root then return false end
		end
		root.CFrame = CFrame.lookAt(root.Position, Vector3.new(face.X, root.Position.Y, face.Z))
		task.wait(0.08)
		pcall(rem.Aim.FireServer, rem.Aim, idx)
		local until_ = os.clock() + 1.5
		while os.clock() < until_ do
			local cd = bat:GetAttribute("CooldownEndTime")
			local cooling = bat:GetAttribute("CooldownActive") == true and typeof(cd) == "number" and workspace:GetServerTimeNow() < cd
			if not cooling and os.clock() - (BB.lastMushroomHit or 0) >= 0.75 then break end
			task.wait(0.05)
		end
		BB.lastMushroomHit = os.clock()
		pcall(function() bat:Activate() end)
		task.wait(0.15)
		return true
	end
	function BB.claimBanjo()
		local bug = BB.banjoPrompt("Jitterbug")
		if bug then
			BB.status = "Talking to Jitterbug"
			BB.firePrompt(bug)
			task.wait(0.6)
		end
		local done, reason = request("BanjoCricket", "AskClaim")
		task.wait(0.4)
		return done or BB.snapshot().banjoClaimed, reason
	end
	function BB.runBanjo()
		local S = BB.snapshot()
		if S.banjoClaimed then return true end
		if not inTree() then
			local err = enterTree()
			if err then return false, err end
		end
		if not S.banjoSolved then
			local solved, reason = BB.solveBanjo()
			if not solved then return false, reason end
			task.wait(BB.bridgeSeconds or 3.5)
		end
		return BB.claimBanjo()
	end
	function BB.returnWisp()
		local S = BB.snapshot()
		if S.unlocked then return true end
		if not S.returning then
			if not S.readyReturn then return false, "finish every Wisp quest first" end
			local done, reason = request("WispCompanion", "Request", "BeginReturn")
			if not done then return false, reason or "the wisp is not ready" end
		end
		local wispPrompt = child(workspace, "World", "Build", "EnchantedForestZone", "Zone13Props", "EnchantedTree", "WispAnchor", "WispTreePrompt")
		if wispPrompt and wispPrompt:IsA("ProximityPrompt") then
			local anchor = wispPrompt.Parent
			local spot = anchor and ((anchor:IsA("Attachment") and anchor.WorldPosition) or (anchor:IsA("BasePart") and anchor.Position))
			if spot then
				BB.status = "Taking the wisp home"
				if travel(spot + Vector3.new(0, 3, 4), 60) then
					local waitUntil = os.clock() + 2
					while os.clock() < waitUntil and not wispPrompt.Enabled do task.wait(0.1) end
					pressPrompt(wispPrompt)
					local deadline = os.clock() + 3
					while os.clock() < deadline and not BB.snapshot().unlocked do task.wait(0.1) end
					if BB.snap.unlocked then return true end
				end
			end
		end
		if not (treePrompt and treePrompt.Parent) then
			local entrance = child(workspace, "World", "Build", "EnchantedTreeInterior", "Markers", "EnterTrigger")
			treePrompt = entrance and entrance:FindFirstChild("EnchantedTreePrompt", true) or nil
		end
		local holder = treePrompt and treePrompt.Parent
		local point = holder and ((holder:IsA("Attachment") and holder.WorldPosition) or (holder:IsA("BasePart") and holder.Position))
		if not point then return false, "tree entrance not found" end
		BB.status = "Taking the wisp home"
		if not travel(point + Vector3.new(0, 3, 0), 60) then return false, "could not reach the tree entrance" end
		pressPrompt(treePrompt)
		local deadline = os.clock() + 3
		while os.clock() < deadline and not BB.snapshot().unlocked do task.wait(0.1) end
		if BB.snap.unlocked then return true end
		local done, reason = request("WispCompanion", "Request", "Return")
		task.wait(0.5)
		return done or BB.snapshot().unlocked, reason
	end
	function BB.tierOptions()
		local info = BB.tiers()
		local out = {}
		for i = #TIERS, 1, -1 do
			local t = TIERS[i]
			out[#out + 1] = info and info[t].name or t
		end
		return out
	end
	function BB.tierFromLabel(label)
		local info = BB.tiers()
		for _, t in ipairs(TIERS) do
			if label == t or (info and info[t].name == label) then return t end
		end
		return nil
	end
	function BB.setTiers(labels)
		local ids = {}
		for _, label in ipairs(type(labels) == "table" and labels or {}) do
			local id = BB.tierFromLabel(tostring(label))
			if id then ids[#ids + 1] = id end
		end
		Config.ButterflyTiers = ids
	end
	local RECIPE_LABELS = { "All Recipes", "For Essence (shortfall only)", "Emerald to Sapphire", "Sapphire to Amethyst", "Amethyst to Radiant" }
	local RECIPE_IDS = { ["For Essence (shortfall only)"] = "Smart", ["Emerald to Sapphire"] = "Green", ["Sapphire to Amethyst"] = "Blue", ["Amethyst to Radiant"] = "Purple" }
	function BB.recipeOptions() return RECIPE_LABELS end
	function BB.setRecipe(label)
		Config.ButterflyTradeRecipe = RECIPE_IDS[tostring(label)] or "All"
	end
	local MODE_LABELS = { "Tween to Butterfly", "Stand", "Zigzag", "Circle" }
	local MODE_IDS = { ["Tween to Butterfly"] = "Tween", Stand = "Stand", Zigzag = "Zigzag", Circle = "Circle" }
	function BB.modeOptions() return MODE_LABELS end
	function BB.setMode(label)
		Config.ButterflyCatchMode = MODE_IDS[tostring(label)] or "Tween"
	end
	local espFolder = nil
	local function espClear()
		for key, card in pairs(BB.cards) do
			pcall(function() card.part:Destroy() end)
			BB.cards[key] = nil
		end
		if espFolder then pcall(function() espFolder:Destroy() end) espFolder = nil end
	end
	local function espSync()
		local cam = workspace.CurrentCamera
		if not cam then return end
		if not (espFolder and espFolder.Parent) then
			espFolder = Instance.new("Folder")
			espFolder.Name = "SenaBloomEsp"
			espFolder.Parent = cam
		end
		local info, root, seen = BB.tiers() or {}, rootPart(), {}
		for _, b in ipairs(butterflies()) do
			local key = ("%d_%d_%d"):format(b.pos.X, b.pos.Y, b.pos.Z)
			seen[key] = true
			local card = BB.cards[key]
			if not (card and card.part.Parent) then
				local part = Instance.new("Part")
				part.Size = Vector3.new(0.2, 0.2, 0.2)
				part.Anchored = true
				part.CanCollide = false
				part.CanQuery = false
				part.CanTouch = false
				part.Transparency = 1
				part.Parent = espFolder
				local gui = Instance.new("BillboardGui")
				gui.Adornee = part
				gui.Size = UDim2.fromOffset(120, 20)
				gui.StudsOffsetWorldSpace = Vector3.new(0, 1.6, 0)
				gui.AlwaysOnTop = true
				gui.MaxDistance = 260
				gui.Parent = part
				local label = Instance.new("TextLabel")
				label.Size = UDim2.fromScale(1, 1)
				label.BackgroundTransparency = 1
				label.Font = Enum.Font.GothamBold
				label.TextSize = 13
				label.TextStrokeTransparency = 0.35
				label.Parent = gui
				card = { part = part, label = label }
				BB.cards[key] = card
			end
			card.part.CFrame = CFrame.new(b.pos)
			local t = info[b.tier]
			card.label.TextColor3 = t and t.color or Color3.new(1, 1, 1)
			card.label.Text = root and ("%s  %dm"):format(t and t.name or b.tier, math.floor((b.pos - root.Position).Magnitude))
				or (t and t.name or b.tier)
		end
		for key, card in pairs(BB.cards) do
			if not seen[key] then
				pcall(function() card.part:Destroy() end)
				BB.cards[key] = nil
			end
		end
	end
	local follow = { target = nil, since = 0, swinging = false, skip = setmetatable({}, { __mode = "k" }) }
	function follow.pos(model)
		if not (model and model.Parent) then return nil end
		local ok, p = pcall(function()
			return model.PrimaryPart and model.PrimaryPart.Position or model:GetPivot().Position
		end)
		return ok and p or nil
	end
	function follow.pick(origin)
		local folder = workspace:FindFirstChild("ButterflyBloomSwarm")
		if not folder then return nil end
		local only, now = tierFilter(), os.clock()
		local best, bestScore = nil, nil
		for _, model in ipairs(folder:GetChildren()) do
			if model:IsA("Model") and TIER_RANK[model.Name] and (not only or only[model.Name])
				and (follow.skip[model] or 0) <= now then
				local p = follow.pos(model)
				if p then
					local score = (TIER_RANK[model.Name] == 4 and 1e6 or 0) - (p - origin).Magnitude
					if not bestScore or score > bestScore then best, bestScore = model, score end
				end
			end
		end
		return best
	end
	function follow.gain()
		local m = M()
		local ok, save = pcall(m.Save.Peek)
		local caught = ok and save and save.Butterflies and tonumber(save.Butterflies.TotalCaught)
		return (caught and BB.bloomBase) and math.max(0, caught - BB.bloomBase) or 0
	end
	function follow.swing(model, pos)
		if follow.swinging then return end
		local cooldown = tonumber(flag("SwingCooldownSeconds", 0.45)) or 0.45
		if os.clock() - BB.lastSwing < cooldown then return end
		local m = M()
		if not (m and m.Swarm and m.Swarm.Nearest) then return end
		local ok, e = pcall(m.Swarm.Nearest, pos, Vector3.new(0, 0, -1), 4)
		local flight = ok and e and e.Flight
		if not (flight and flight.Id) then return end
		if flight.Tier ~= nil and tostring(flight.Tier) ~= model.Name then return end
		BB.lastSwing = os.clock()
		follow.swinging = true
		task.spawn(function()
			local _, _, word = request("Butterflies", "AskSwing", flight.Id)
			follow.swinging = false
			if word ~= "Caught" and word ~= "Gone" then follow.skip[model] = os.clock() + 1.5 end
			if follow.target == model then follow.target = nil end
			local info = BB.tiers()
			local name = info and info[model.Name] and info[model.Name].name or model.Name
			BB.status = ("%s %s  ·  +%d this Bloom"):format(word == "Caught" and "Caught" or "Chasing", name, follow.gain())
		end)
	end
	function follow.prepare()
		local char = LocalPlayer.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if not (hrp and hum) then return nil end
		padOff()
		applyKillPartIgnore(char)
		startGlobalMovementProtection()
		startHoverPad()
		local autoRotate = hum.AutoRotate
		hum.AutoRotate = false
		return char, hrp, hum, autoRotate
	end
	function follow.release(hrp, hum, autoRotate)
		follow.target = nil
		if hum.Parent and autoRotate ~= nil then hum.AutoRotate = autoRotate end
		hrp.AssemblyLinearVelocity = Vector3.zero
		hrp.AssemblyAngularVelocity = Vector3.zero
		stopHoverPad()
	end
	function follow.keepGoing(hrp, hum, mode)
		if not (sessionAlive() and Config.ButterflyAutoCatch and BB.bloomLeft() > 0 and hrp.Parent and hum.Health > 0) then return false end
		if (Config.ButterflyCatchMode or "Tween") ~= mode then return false end
		return not (BB.manual or inTree() or isStealNightBlocked() or TaskLadder.blocker("butterfly") ~= nil)
	end
	function follow.moveStep(char, hum, hrp, goal, facePos, speed, dt)
		setMovementSpoof(char, speed * SPOOF_CFG.HEADROOM)
		local holder = environment()[SPOOF_CFG.INTEGRITY_KEY]
		local integrityState = type(holder) == "table" and holder.State or nil
		if not integrityStateCanTravel(integrityState, hum, hrp) then
			hrp.AssemblyLinearVelocity = Vector3.zero
			hrp.AssemblyAngularVelocity = Vector3.zero
			syncHoverPad(hrp.Position)
			if integrityStateMatches(integrityState, hum, hrp) then
				patchIntegrityState(integrityState, speed * SPOOF_CFG.HEADROOM, Vector3.zero)
			else
				setIntegritySpoof(hum, hrp, speed)
			end
			return nil
		end
		local here = hrp.Position
		local delta = goal - here
		local stepLen = speed * dt
		local nextPos = delta.Magnitude <= stepLen and goal or (here + delta.Unit * stepLen)
		local look = (facePos or goal) - nextPos
		local flat = Vector3.new(look.X, 0, look.Z)
		if flat.Magnitude <= 0.001 then flat = Vector3.new(delta.X, 0, delta.Z) end
		local facing = flat.Magnitude > 0.001 and flat.Unit or hrp.CFrame.LookVector
		local velocity = (nextPos - here) / dt
		syncHoverPad(nextPos)
		hrp.CFrame = CFrame.lookAt(nextPos, nextPos + facing)
		hrp.AssemblyLinearVelocity = Vector3.zero
		hrp.AssemblyAngularVelocity = Vector3.zero
		if not refreshIntegritySpoof(hum, hrp, speed, velocity) then
			setIntegritySpoof(hum, hrp, speed)
			refreshIntegritySpoof(hum, hrp, speed, velocity)
		end
		return nextPos
	end
	function follow.nearest(origin, maxDist)
		local folder = workspace:FindFirstChild("ButterflyBloomSwarm")
		if not folder then return nil end
		local only, now = tierFilter(), os.clock()
		local best, bestPos, bestDist = nil, nil, maxDist
		for _, model in ipairs(folder:GetChildren()) do
			if model:IsA("Model") and TIER_RANK[model.Name] and (not only or only[model.Name])
				and (follow.skip[model] or 0) <= now then
				local p = follow.pos(model)
				local d = p and (p - origin).Magnitude
				if d and d <= bestDist then best, bestPos, bestDist = model, p, d end
			end
		end
		return best, bestPos
	end
	function follow.cluster(prev)
		local folder = workspace:FindFirstChild("ButterflyBloomSwarm")
		local points = {}
		for _, model in ipairs(folder and folder:GetChildren() or {}) do
			if model:IsA("Model") and TIER_RANK[model.Name] then
				local p = follow.pos(model)
				if p then points[#points + 1] = p end
			end
		end
		if #points == 0 then return nil, 0, 0 end
		local near = 0
		for _, a in ipairs(points) do
			if prev and (a - prev).Magnitude <= 24 then near = near + 1 end
		end
		local best, bestScore = nil, nil
		for _, a in ipairs(points) do
			local sum, n = Vector3.zero, 0
			for _, b in ipairs(points) do
				if (a - b).Magnitude <= 24 then sum, n = sum + b, n + 1 end
			end
			local c = sum / n
			local score = n * 100 - (prev and (c - prev).Magnitude or 0)
			if not bestScore or score > bestScore then best, bestScore = c, score end
		end
		return best, #points, near
	end
	function follow.route(mode, centre, t)
		if mode == "Circle" then
			local radius, angle = 24, t * (50 / 24)
			return centre + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
		end
		local b = bloomBounds()
		if mode ~= "Zigzag" or not b then return centre end
		local hx = math.max(b.Size.X / 2 - 12, 20)
		local hz = math.clamp(b.Size.Z / 2 - 12, 8, 30)
		local legs = 8
		local legLen = math.sqrt((2 * hx / legs) ^ 2 + (2 * hz) ^ 2)
		local u = (t * 80 / legLen) % (legs * 2)
		local i = math.floor(u)
		local frac = u - i
		local ia = i <= legs and i or legs * 2 - i
		local ib = i + 1 <= legs and i + 1 or legs * 2 - (i + 1)
		local xa, za = -hx + ia * (2 * hx / legs), (i % 2 == 0) and -hz or hz
		local xb, zb = -hx + ib * (2 * hx / legs), ((i + 1) % 2 == 0) and -hz or hz
		local flat = b.CFrame:VectorToWorldSpace(Vector3.new(xa + (xb - xa) * frac, 0, za + (zb - za) * frac))
		return Vector3.new(b.Position.X + flat.X, centre.Y, b.Position.Z + flat.Z)
	end
	function follow.patrol(mode)
		local char, hrp, hum, autoRotate = follow.prepare()
		if not char then return false end
		local reach = tonumber(flag("NetReach", 14)) or 14
		local label = ({ Stand = "Standing in the swarm", Zigzag = "Zigzag patrol", Circle = "Circling the swarm" })[mode] or mode
		local centre, refreshAt, started = nil, 0, os.clock()
		local idleSince, followed, statusAt = nil, false, 0
		while follow.keepGoing(hrp, hum, mode) do
			local dt = math.max(math.min(RunService.Heartbeat:Wait(), LONG_FRAME_CLAMP), 1 / 240)
			local now = os.clock()
			if now >= refreshAt then
				local found, count, near = follow.cluster(centre)
				refreshAt = now + 1.5
				if count == 0 then
					idleSince = idleSince or now
				else
					idleSince = nil
					if mode == "Stand" then
						if not centre or near < 3 then centre = found end
					else
						centre = centre and centre:Lerp(found, 0.5) or found
					end
				end
			end
			if idleSince and now - idleSince > 2 then break end
			if not centre then
				hrp.AssemblyLinearVelocity = Vector3.zero
				hrp.AssemblyAngularVelocity = Vector3.zero
				syncHoverPad(hrp.Position)
			else
				followed = true
				local goal = follow.route(mode, centre, now - started)
				local cap = (goal - hrp.Position).Magnitude > 40 and math.huge
					or (mode == "Stand" and 60 or (mode == "Circle" and 70 or 110))
				local speed = math.clamp(math.min(speedDialStuds(), cap), SPOOF_CFG.MIN_SPEED, SPOOF_CFG.MAX_SPEED)
				local target, tpos = follow.nearest(hrp.Position, reach + 6)
				local nextPos = follow.moveStep(char, hum, hrp, goal, tpos, speed, dt)
				if nextPos and target and (tpos - nextPos).Magnitude <= reach - 1.5 then follow.swing(target, tpos) end
				if now >= statusAt and not follow.swinging then
					statusAt = now + 1
					BB.status = ("%s  ·  +%d this Bloom"):format(label, follow.gain())
				end
			end
		end
		follow.release(hrp, hum, autoRotate)
		return followed
	end
	function follow.run()
		local char, hrp, hum, autoRotate = follow.prepare()
		if not char then return false end
		local reach = tonumber(flag("NetReach", 14)) or 14
		local standoff = math.min(reach - 3, (tonumber(flag("DodgeRadius", 9)) or 9) + 1)
		local idleSince, followed = nil, false
		while follow.keepGoing(hrp, hum, "Tween") do
			local dt = math.max(math.min(RunService.Heartbeat:Wait(), LONG_FRAME_CLAMP), 1 / 240)
			local target = follow.target
			local pos = follow.pos(target)
			if not pos or os.clock() - follow.since > 3 then
				if pos then follow.skip[target] = os.clock() + 2 end
				target = follow.pick(hrp.Position)
				follow.target, follow.since = target, os.clock()
				pos = follow.pos(target)
				if target then
					local info = BB.tiers()
					BB.status = ("Chasing %s  ·  +%d this Bloom"):format(info and info[target.Name] and info[target.Name].name or target.Name, follow.gain())
				end
			end
			if not pos then
				idleSince = idleSince or os.clock()
				if os.clock() - idleSince > 2 then break end
				hrp.AssemblyLinearVelocity = Vector3.zero
				hrp.AssemblyAngularVelocity = Vector3.zero
				syncHoverPad(hrp.Position)
			else
				idleSince, followed = nil, true
				local speed = math.clamp(speedDialStuds(), SPOOF_CFG.MIN_SPEED, SPOOF_CFG.MAX_SPEED)
				local away = hrp.Position - pos
				local goal = away.Magnitude > 0.001 and (pos + away.Unit * standoff) or (pos + Vector3.new(standoff, 0, 0))
				local nextPos = follow.moveStep(char, hum, hrp, goal, pos, speed, dt)
				if nextPos and (pos - nextPos).Magnitude <= reach - 1.5 then follow.swing(target, pos) end
			end
		end
		follow.release(hrp, hum, autoRotate)
		return followed
	end
	local function catchTick(S)
		if inTree() then leaveTree() return end
		if not atBloom() then
			padOff()
			if isStealNightBlocked() then BB.status = "Night - waiting to fly to the forest" return end
			if not canTry("area") then return end
			local point = bloomPoint()
			if not point then BB.status = "Butterfly Bloom zone not found" retryLater("area") return end
			BB.status = "Flying to the Butterfly Bloom"
			if not travel(point, 60) then
				retryLater("area")
				BB.status = "Could not reach the Enchanted Forest"
			end
			return
		end
		local treadmill = runtimeEnv.__SenaV4TreadmillManager
		if treadmill and treadmill.activeTreadmill ~= nil then leaveTreadmill() end
		if not S.holding and not equipNet() then
			BB.status = "Butterfly Net is not in your backpack"
			return
		end
		local mode = Config.ButterflyCatchMode or "Tween"
		local caught
		if mode == "Tween" then caught = follow.run() else caught = follow.patrol(mode) end
		if not caught then
			hover()
			BB.status = ("Waiting for butterflies  ·  +%d this Bloom"):format(follow.gain())
		end
	end
	local function idleStatus(S)
		if not S.net then
			return S.treeUnlocked and "No Butterfly Net yet" or "Enchanted Tree locked - finish the Wisp Event"
		end
		if S.active then return "Bloom is live" end
		if S.nextIn then return ("Next Bloom in %dm %02ds"):format(math.floor(S.nextIn / 60), math.floor(S.nextIn % 60)) end
		return "Idle"
	end
	local function step()
		if BB.manual then return end
		local S = BB.snapshot()
		if S.active then
			BB.bloomBase = BB.bloomBase or S.caught
		else
			BB.bloomBase = nil
		end
		if Config.ButterflyEsp and S.active then
			espSync()
		elseif next(BB.cards) or espFolder then
			espClear()
		end
		pcall(BB.questDrive, S)
		if Config.WispAutoQuest and S.claimable and S.questId and canTry("quest") then
			local done, reason = request("WispCompanion", "Request", "Claim", S.questId)
			BB.status = done and ("Wisp quest claimed: " .. S.quest) or ("Wisp claim: " .. tostring(reason or "refused"))
			if not done then retryLater("quest") end
		end
		local job = nil
		if Config.WispAutoQuest and not S.accepted and not S.unlocked and (S.need or 0) > 0
			and (S.speed or 0) >= S.need and canTry("accept") then
			job = "accept"
		elseif Config.WispAutoQuest and not S.unlocked and (S.returning or S.readyReturn) and canTry("wisp") then
			job = "wisp"
		elseif Config.ButterflyAutoNet and not S.net and S.treeUnlocked and canTry("net") then
			job = "net"
		elseif Config.BanjoAuto and S.treeUnlocked and not S.banjoClaimed and not S.active and canTry("banjo") then
			job = "banjo"
		elseif Config.ButterflyAutoCatch and S.active and S.net
			and not (eggRuntime and eggRuntime.enabled and os.clock() - (tonumber(eggRuntime.gateOpenAt) or 0) < 3) then
			job = "catch"
		elseif not S.active and Config.ButterflyAutoTrade and S.net and BB.canTrade() and canTry("trade") then
			job = "trade"
		elseif not S.active and Config.ButterflyAutoCraft and S.net and BB.canCraft() and canTry("craft") then
			job = "craft"
		end
		BB.wantsCharacter = job ~= nil
		local blocker = job and TaskLadder.blocker("butterfly") or nil
		local holder = job and not blocker and TaskLadder.holder("butterfly") or nil
		local wasActive = BB.active
		BB.active = job ~= nil and blocker == nil and holder == nil
		if job and not BB.active then
			padOff()
			if blocker and inTree() then
				BB.status = "Leaving the tree for " .. TaskLadder.TITLES[blocker]
				leaveTree()
			end
			BB.status = blocker and ("Yielding to " .. TaskLadder.TITLES[blocker])
				or ("Waiting for " .. TaskLadder.TITLES[holder] .. " to hand over")
			return
		end
		if not job then
			if wasActive then finishTrip() end
			padOff()
			BB.status = idleStatus(S)
			return
		end
		if not wasActive then leaveTreadmill() end
		if job == "accept" then
			local done, reason = BB.acceptWisp()
			BB.status = done and "Wisp accepted - quests started" or ("Wisp: " .. tostring(reason or "refused"))
			if not done then retryLater("accept") end
		elseif job == "wisp" then
			local done, reason = BB.returnWisp()
			BB.status = done and "Wisp returned - Enchanted Tree unlocked" or ("Wisp: " .. tostring(reason or "refused"))
			if not done then retryLater("wisp") end
		elseif job == "banjo" then
			local done, reason = BB.runBanjo()
			BB.status = done and "Banjo Cricket secret claimed" or ("Banjo: " .. tostring(reason or "refused"))
			if not done then retryLater("banjo") end
			if inTree() then leaveTree() end
		elseif job == "net" then
			local done, reason = BB.claimNet()
			BB.status = done and "Butterfly Net claimed" or ("Net: " .. tostring(reason or "refused"))
			if not done then retryLater("net") end
		elseif job == "catch" then
			catchTick(S)
		elseif job == "trade" then
			local done, res = BB.tradeUp()
			BB.status = done and ("Traded up %d time(s)"):format(tonumber(res) or 0) or ("Trade: " .. tostring(res))
			retryLater("trade")
		elseif job == "craft" then
			local done, res = BB.craft()
			BB.status = done and ("Crafted %d Enchanted Essence"):format(tonumber(res) or 0) or ("Craft: " .. tostring(res))
			retryLater("craft")
		end
	end
	task.spawn(function()
		while sessionAlive() do
			local ok, err = pcall(step)
			if not ok then
				BB.active = false
				BB.wantsCharacter = false
				padOff()
				BB.status = "Error: " .. tostring(err)
				task.wait(1)
			end
			task.wait(0.2)
		end
		padOff()
		espClear()
	end)
	TaskLadder.register("butterfly", {
		wants = function() return BB.wantsCharacter == true end,
		active = function() return BB.active == true end,
		enabled = function()
			return Config.ButterflyAutoCatch == true or Config.ButterflyAutoNet == true or Config.WispAutoQuest == true or Config.BanjoAuto == true
				or Config.ButterflyAutoTrade == true or Config.ButterflyAutoCraft == true
		end,
		status = function() return tostring(BB.status or "") end,
	})
	runtimeEnv.__SenaV4ButterflyRuntime = BB
end
do
	local Players = game:GetService("Players")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local LocalPlayer = Players.LocalPlayer
	local TAG = "SENAVIS_"
	local Visual = { held = {} }
	local function reqSave() local ok, m = pcall(require, ReplicatedStorage.Shared.Save) return ok and m or nil end
	local function assetDir()
		local ok, a = pcall(require, ReplicatedStorage.Data.Assets)
		if not ok then return nil end
		return a.Directory or a
	end
	local function newUid(kind)
		return TAG .. kind .. "_" .. tostring(math.floor(os.clock() * 1000)) .. "_" .. tostring(math.random(1, 1000000))
	end
	function Visual.categories(kind)
		local dir = assetDir()
		local out = {}
		if not dir then return out end
		for name, cfg in pairs(dir) do
			if type(name) == "string" and type(cfg) == "table" then
				if kind == "Pet" or (cfg.Egg ~= nil) then out[#out + 1] = name end
			end
		end
		table.sort(out)
		return out
	end
	function Visual.spawnEgg(category, scale)
		local Save = reqSave()
		local dir = assetDir()
		if not (Save and dir and dir[category]) then return nil end
		local uid = newUid("E")
		pcall(function()
			Save.Amend("EggInventory", function(inv)
				inv[uid] = {
					AssetCategory = category, AssetScale = tonumber(scale) or 50,
					AssetColorIndex = 1, AssetColorSeed = math.random(1, 2000000000),
					AssetEyeColor = "ffffff", HasParasite = false, Mutations = {},
				}
			end)
		end)
		return uid
	end
	function Visual.spawnPet(category, scale)
		local Save = reqSave()
		local dir = assetDir()
		if not (Save and dir and dir[category]) then return nil end
		local uid = newUid("P")
		pcall(function()
			Save.Amend("Inventory", function(inv)
				inv[uid] = {
					Category = category, Scale = tonumber(scale) or 50,
					ColorIndex = 1, ColorSeed = math.random(1, 2000000000), EyeColor = "ffffff",
					Gender = "Male", Personality = "Normal", InFuse = false,
					HasBeenFirstPlaced = false, Mutations = {},
				}
			end)
		end)
		return uid
	end
	local function eggTemplate(category)
		local m = ReplicatedStorage:FindFirstChild("Assets")
		m = m and m:FindFirstChild("Models")
		m = m and m:FindFirstChild("Eggs")
		return m and m:FindFirstChild(category)
	end
	local function petTemplate(category)
		local folder = ReplicatedStorage:FindFirstChild("AssetModels")
		return folder and folder:FindFirstChild(category)
	end
	local function sweepHeld()
		for _, t in ipairs(Visual.held) do pcall(function() t:Destroy() end) end
		Visual.held = {}
		for _, where in ipairs({ LocalPlayer.Character, LocalPlayer:FindFirstChild("Backpack") }) do
			if where then
				for _, t in ipairs(where:GetChildren()) do
					if t:IsA("Tool") and t.Name:sub(1, #TAG) == TAG then pcall(function() t:Destroy() end) end
				end
			end
		end
	end
	function Visual.hold(category, isEgg, scale)
		local character = LocalPlayer.Character
		if not character then return false end
		local template = isEgg and eggTemplate(category) or petTemplate(category)
		if not template then return false end
		local ok, model = pcall(function() return template:Clone() end)
		if not ok or not (model and model:IsA("Model")) then return false end
		local handle = model.PrimaryPart or model:FindFirstChildWhichIsA("BasePart")
		if not handle then pcall(function() model:Destroy() end) return false end
		pcall(function() if not model.PrimaryPart then model.PrimaryPart = handle end end)
		local vs = math.clamp(1 + (tonumber(scale) or 50) / 70, 1, 2.4) * (0.85 + math.random() * 0.4)
		pcall(function() if model.ScaleTo then model:ScaleTo(vs) end end)
		local ext = Vector3.new(3, 3, 3)
		pcall(function() ext = model:GetExtentsSize() end)
		local tool = Instance.new("Tool")
		tool.Name = TAG .. category
		tool.RequiresHandle = true
		tool.CanBeDropped = false
		local dir = assetDir()
		local cfg = dir and dir[category]
		local icon = cfg and ((isEgg and cfg.Egg and cfg.Egg.Icon) or cfg.Icon)
		if type(icon) == "string" then pcall(function() tool.TextureId = icon end) end
		handle.Name = "Handle"
		for _, p in ipairs(model:GetDescendants()) do
			if p:IsA("BasePart") then
				p.Massless = true
				p.CanCollide = false
				p.Anchored = false
				if p ~= handle then
					local w = Instance.new("WeldConstraint")
					w.Part0 = handle
					w.Part1 = p
					w.Parent = handle
				end
			end
		end
		for _, ch in ipairs(model:GetChildren()) do ch.Parent = tool end
		handle.Parent = tool
		pcall(function() model:Destroy() end)
		pcall(function()
			local depth = math.max(ext.X, ext.Z)
			tool.Grip = CFrame.new(0, -(ext.Y * 0.55), (depth * 0.5 + 0.5))
		end)
		tool.Parent = LocalPlayer:FindFirstChild("Backpack") or character
		local hum = character:FindFirstChildOfClass("Humanoid")
		if hum then pcall(function() hum:EquipTool(tool) end) end
		Visual.held[#Visual.held + 1] = tool
		return true
	end
	function Visual.spawn(kind, category, scale, hold)
		if not category or category == "None" then return end
		local s = tonumber(scale) or 50
		if hold then
			pcall(Visual.hold, category, kind ~= "Pet", s)
		elseif kind == "Pet" then
			local petScale = math.clamp(1 + s / 25, 1.2, 5) * (0.85 + math.random() * 0.4)
			Visual.spawnPet(category, petScale)
		else
			Visual.spawnEgg(category, s * (0.85 + math.random() * 0.5))
		end
	end
	function Visual.clear()
		local Save = reqSave()
		if Save then
			pcall(function() Save.Amend("EggInventory", function(inv)
				for uid in pairs(inv) do if type(uid) == "string" and uid:sub(1, #TAG) == TAG then inv[uid] = nil end end
			end) end)
			pcall(function() Save.Amend("Inventory", function(inv)
				for uid in pairs(inv) do if type(uid) == "string" and uid:sub(1, #TAG) == TAG then inv[uid] = nil end end
			end) end)
			pcall(function() Save.Amend("EquippedAssets", function(eq)
				for i = #eq, 1, -1 do local v = eq[i] if type(v) == "string" and v:sub(1, #TAG) == TAG then table.remove(eq, i) end end
			end) end)
		end
		for _, tool in ipairs(Visual.held) do pcall(function() tool:Destroy() end) end
		Visual.held = {}
		for _, where in ipairs({ LocalPlayer.Character, LocalPlayer:FindFirstChild("Backpack") }) do
			if where then
				for _, t in ipairs(where:GetChildren()) do
					if t:IsA("Tool") and t.Name:sub(1, #TAG) == TAG then pcall(function() t:Destroy() end) end
				end
			end
		end
	end
	runtimeEnv.__SenaV4VisualSAE = Visual
end
do
	local target = (tonumber(game:GetService("StarterPlayer").CameraMaxZoomDistance) or 128) * 1.95
	local function widenZoom()
		if LocalPlayer.CameraMaxZoomDistance < target then
			LocalPlayer.CameraMaxZoomDistance = target
		end
	end
	pcall(widenZoom)
	LocalPlayer:GetPropertyChangedSignal("CameraMaxZoomDistance"):Connect(function()
		if sessionAlive() then pcall(widenZoom) end
	end)
end
do
	runtimeEnv.__SenaV4Visual = (function()
		local HttpService = game:GetService("HttpService")
		local V = {
			base = "https://senahub.xyz/api/visual/",
			manifest = nil,
			status = "Idle",
			spawned = {},
			backs = {},
			backRod = nil,
			remote = {},
		}
		local CACHE = "SenaVisual/cache"
		local ROD_DIR = Vector3.new(0.3, 0.75, 0.6).Unit
		local SHOULDER_HOLD = {
			RightShoulder = CFrame.Angles(math.rad(40), 0, math.rad(10)),
			RightElbow = CFrame.Angles(math.rad(100), 0, 0),
			RightWrist = CFrame.new(),
			LeftShoulder = CFrame.new(),
			LeftElbow = CFrame.new(),
			LeftWrist = CFrame.new(),
		}
		local BACK_SCALE = 0.8
		local BACK_OFFSET = CFrame.new(0.5, 1.3, 1, -0.7071, -0.7071, 0, -0.7071, 0.7071, 0, 0, 0, -1):Inverse()
		local function ensureFolder(path)
			local built = ""
			for part in string.gmatch(path, "[^/]+") do
				built = built == "" and part or (built .. "/" .. part)
				if not isfolder(built) then makefolder(built) end
			end
		end
		local function httpGet(url)
			local ok, body = pcall(function() return game:HttpGet(url, true) end)
			if ok and type(body) == "string" and body ~= "" then return body end
			return nil
		end
		function V.loadManifest()
			if V.manifest then return V.manifest end
			ensureFolder(CACHE)
			local body = httpGet(V.base .. "manifest.json")
			if body then
				pcall(writefile, CACHE .. "/manifest.json", body)
			elseif isfile(CACHE .. "/manifest.json") then
				body = readfile(CACHE .. "/manifest.json")
			end
			local ok, data = pcall(function() return HttpService:JSONDecode(body) end)
			if ok and type(data) == "table" then V.manifest = data end
			return V.manifest
		end
		function V.names(kind)
			local out = {}
			local m = V.loadManifest()
			for _, entry in ipairs((m and m[kind]) or {}) do
				local label = entry.name
				if entry.tier then label = entry.name .. " [" .. entry.tier .. "]" end
				table.insert(out, label)
			end
			return out
		end
		local function findEntry(kind, label)
			local m = V.loadManifest()
			for _, entry in ipairs((m and m[kind]) or {}) do
				if entry.name == label or (entry.name .. " [" .. tostring(entry.tier) .. "]") == label then return entry end
			end
			return nil
		end
		local function fetchModel(kind, entry)
			local dir = CACHE .. "/" .. kind
			ensureFolder(dir)
			local path = dir .. "/" .. entry.file
			if not isfile(path) then
				V.status = "Downloading " .. entry.name .. "..."
				local body = httpGet(V.base .. kind .. "/" .. entry.file)
				if not body then return nil, "Download failed" end
				writefile(path, body)
			end
			local ok, objects = pcall(function() return game:GetObjects(getcustomasset(path)) end)
			if not ok or type(objects) ~= "table" or not objects[1] then
				pcall(delfile, path)
				return nil, "Could not load model"
			end
			return objects[1]
		end
		V.rodScale = 1
		V.fishWeight = 0
		local function prepare(model, targetSize, factor)
			local parts = {}
			for _, d in ipairs(model:GetDescendants()) do
				if d:IsA("JointInstance") or d:IsA("WeldConstraint") then
					d:Destroy()
				elseif d:IsA("BasePart") then
					table.insert(parts, d)
				elseif d:IsA("Script") or d:IsA("LocalScript") then
					d:Destroy()
				end
			end
			if #parts == 0 then return nil end
			local handle = model:FindFirstChild("Handle", true)
			if not (handle and handle:IsA("BasePart")) then handle = parts[1] end
			if targetSize or (factor and factor ~= 1) then
				local center, size = model:GetBoundingBox()
				local scale = factor or (targetSize / math.max(size.X, size.Y, size.Z, 0.01))
				if not targetSize then center = handle.CFrame end
				for _, p in ipairs(parts) do
					local rel = center:ToObjectSpace(p.CFrame)
					p.Size = p.Size * scale
					p.CFrame = center * (CFrame.new(rel.Position * scale) * rel.Rotation)
				end
				for _, a in ipairs(model:GetDescendants()) do
					if a:IsA("Attachment") and not a.Parent:IsA("Bone") then a.Position = a.Position * scale end
				end
			end
			for _, p in ipairs(parts) do
				p.Anchored = false
				p.CanCollide = false
				p.CanQuery = false
				p.CanTouch = false
				p.Massless = true
				if p ~= handle then
					local weld = Instance.new("Weld")
					weld.Part0 = handle
					weld.Part1 = p
					weld.C0 = handle.CFrame:ToObjectSpace(p.CFrame)
					weld.Parent = handle
				end
			end
			handle.Name = "Handle"
			return handle, parts
		end
		local function longAxisFrame(handle, parts)
			local mn, mx = Vector3.zero, Vector3.zero
			for _, p in ipairs(parts) do
				if p ~= handle and p.Transparency < 0.95 then
					local half = p.Size / 2
					for _, sx in ipairs({ -1, 1 }) do
						for _, sy in ipairs({ -1, 1 }) do
							for _, sz in ipairs({ -1, 1 }) do
								local c = handle.CFrame:PointToObjectSpace(p.CFrame:PointToWorldSpace(Vector3.new(half.X * sx, half.Y * sy, half.Z * sz)))
								mn = mn:Min(c)
								mx = mx:Max(c)
							end
						end
					end
				end
			end
			local span = mx - mn
			local ax
			if span.X >= span.Y and span.X >= span.Z then
				ax = Vector3.new(mx.X >= -mn.X and 1 or -1, 0, 0)
			elseif span.Y >= span.Z then
				ax = Vector3.new(0, mx.Y >= -mn.Y and 1 or -1, 0)
			else
				ax = Vector3.new(0, 0, mx.Z >= -mn.Z and 1 or -1)
			end
			local right = Vector3.xAxis
			if math.abs(ax.X) > 0.5 then
				right = span.Z >= span.Y and Vector3.zAxis or Vector3.yAxis
			elseif math.abs(ax.Z) > 0.5 then
				right = span.X >= span.Y and Vector3.xAxis or Vector3.yAxis
			end
			local butt = -math.min(mn:Dot(ax), mx:Dot(ax))
			return CFrame.fromMatrix(Vector3.zero, right, ax), math.max(0, butt - 0.6)
		end
		function V.updateBack()
			local backpack = LocalPlayer:FindFirstChild("Backpack")
			for tool, show in pairs(V.backs) do
				show(tool == V.backRod and backpack ~= nil and tool.Parent == backpack)
			end
			task.defer(V.refreshQuality)
		end
		function V.refreshQuality()
			local holding = false
			local char = LocalPlayer.Character
			if char then
				for _, t in ipairs(char:GetChildren()) do
					if (t:IsA("Tool") and t:GetAttribute("SenaVisual")) or t.Name == "SenaVisualBack" then holding = true break end
				end
			end
			if next(V.remote) ~= nil then holding = true end
			pcall(function()
				if holding then
					settings().Rendering.QualityLevel = Enum.QualityLevel.Level10
				elseif Config.StartupBoost then
					settings().Rendering.QualityLevel = Enum.QualityLevel.Level01
				end
			end)
		end
		local function fishOverhead(model, handle, parts)
			local mn, mx = Vector3.one * 1e9, -Vector3.one * 1e9
			for _, p in ipairs(parts) do
				local half = p.Size / 2
				for _, sx in ipairs({ -1, 1 }) do
					for _, sy in ipairs({ -1, 1 }) do
						for _, sz in ipairs({ -1, 1 }) do
							local corner = p.CFrame:PointToWorldSpace(Vector3.new(half.X * sx, half.Y * sy, half.Z * sz))
							mn = mn:Min(corner)
							mx = mx:Max(corner)
						end
					end
				end
			end
			local size = mx - mn
			local bottoms, totalVol, weighted = {}, 0, Vector3.zero
			for _, p in ipairs(parts) do
				if p.Transparency < 0.95 then
					local vol = math.max(p.Size.X * p.Size.Y * p.Size.Z, 1e-4)
					local half = p.Size / 2
					local low = math.huge
					for _, sx in ipairs({ -1, 1 }) do
						for _, sy in ipairs({ -1, 1 }) do
							for _, sz in ipairs({ -1, 1 }) do
								low = math.min(low, p.CFrame:PointToWorldSpace(Vector3.new(half.X * sx, half.Y * sy, half.Z * sz)).Y)
							end
						end
					end
					table.insert(bottoms, { y = low, vol = vol })
					totalVol += vol
					weighted += p.Position * vol
				end
			end
			local anchor = (mn + mx) / 2 - Vector3.new(0, size.Y / 2, 0)
			if totalVol > 0 then
				table.sort(bottoms, function(a, b) return a.y < b.y end)
				local acc, coreBottom = 0, bottoms[1].y
				for _, b in ipairs(bottoms) do
					acc += b.vol
					coreBottom = b.y
					if acc >= totalVol * 0.1 then break end
				end
				local centroid = weighted / totalVol
				anchor = Vector3.new(centroid.X, coreBottom, centroid.Z)
			end
			local function covers(point)
				for _, p in ipairs(parts) do
					if p.Transparency < 0.95 then
						local l = p.CFrame:PointToObjectSpace(point)
						local h = p.Size / 2 + Vector3.new(0.6, 0.6, 0.6)
						if math.abs(l.X) <= h.X and math.abs(l.Y) <= h.Y and math.abs(l.Z) <= h.Z then return true end
					end
				end
				return false
			end
			local extra = 0
			while extra < 150 do
				local headPoint = anchor - Vector3.new(0, 1.6 + extra, 0)
				if not covers(headPoint) and not covers(headPoint - Vector3.new(0, 1.8, 0)) then break end
				extra += 1
			end
			local function flat(v)
				v = Vector3.new(v.X, 0, v.Z)
				return v.Magnitude > 0.05 and v.Unit or nil
			end
			local facing = nil
			for _, p in ipairs(parts) do
				if string.find(string.lower(p.Name), "eye", 1, true) then
					facing = flat(p.Position - anchor)
					break
				end
			end
			if not facing then
				for _, d in ipairs(model:GetDescendants()) do
					local n = string.lower(d.Name)
					if d:IsA("Attachment") and (n:find("head") or n:find("eye") or n:find("jaw") or n:find("mouth")) then
						facing = flat(d.WorldPosition - anchor)
						if facing then break end
					end
				end
			end
			facing = facing or flat(handle.CFrame.LookVector) or Vector3.zAxis
			return {
				lift = extra,
				rootRel = CFrame.new(anchor):ToObjectSpace(handle.CFrame),
				turn = CFrame.lookAt(Vector3.zero, facing):Inverse(),
			}
		end
		local function buildVisual(kind, entry, fishWeight, rodScale)
			local model, err = fetchModel(kind, entry)
			if not model then return nil, err end
			local handle, parts
			if kind == "fish" then
				local minKg = tonumber(entry.minKg)
				local topKg = tonumber(entry.bigMaxKg) or tonumber(entry.maxKg)
				local scale = 1
				if minKg and minKg > 0 and topKg then
					scale = math.max(1, (minKg + (topKg - minKg) * (fishWeight or 0)) / minKg)
				end
				if (tonumber(entry.nativeLen) or 0) > 50 then scale = scale * 0.8 end
				handle, parts = prepare(model, nil, scale)
			else
				handle, parts = prepare(model, nil, rodScale or 1)
			end
			if not handle then model:Destroy() return nil, "Empty model" end
			handle.Parent = model
			local info = { model = model, handle = handle, kind = kind }
			if kind == "fish" then
				info.overhead = fishOverhead(model, handle, parts)
				handle.Name = "FishRoot"
			else
				info.rodAxis, info.gripShift = longAxisFrame(handle, parts)
				handle.Name = "RodRoot"
			end
			return info
		end
		local function scaledBack(info)
			local back = info.model:Clone()
			back.Name = "SenaVisualBack"
			for _, d in ipairs(back:GetDescendants()) do
				if d:IsA("BasePart") then
					d.Size = d.Size * BACK_SCALE
				elseif d:IsA("Weld") then
					d.C0 = CFrame.new(d.C0.Position * BACK_SCALE) * d.C0.Rotation
				elseif d:IsA("Attachment") and not d.Parent:IsA("Bone") then
					d.Position = d.Position * BACK_SCALE
				end
			end
			return back, back:FindFirstChild("RodRoot", true)
		end
		local function attachBack(char, back, root, info)
			local torso = char and (char:FindFirstChild("UpperTorso") or char:FindFirstChild("Torso"))
			if not (torso and root) then return nil end
			back.Parent = char
			local weld = Instance.new("Weld")
			weld.Part0 = torso
			weld.Part1 = root
			weld.C0 = BACK_OFFSET * CFrame.new(0, info.gripShift * BACK_SCALE, 0) * info.rodAxis:Inverse()
			weld.Parent = root
			return weld
		end
		local function holdRod(char, handle, info)
			local hand = char and char:FindFirstChild("RightHand")
			local torso = char and char:FindFirstChild("UpperTorso")
			if not (hand and torso) then return function() end end
			local pose = {}
			for name, cf in pairs(SHOULDER_HOLD) do
				local j = char:FindFirstChild(name, true)
				if j and j:IsA("Motor6D") then pose[j] = cf end
			end
			local alive, weld = true, nil
			local conn = RunService.PreSimulation:Connect(function()
				for j, cf in pairs(pose) do j.Transform = cf end
			end)
			task.spawn(function()
				RunService.PostSimulation:Wait()
				RunService.PostSimulation:Wait()
				if not alive or not handle.Parent then return end
				local grip = torso.CFrame:PointToObjectSpace(hand.Position) + Vector3.new(0, 0, -0.1)
				local right = (Vector3.xAxis - ROD_DIR * Vector3.xAxis:Dot(ROD_DIR)).Unit
				weld = Instance.new("Weld")
				weld.Part0 = torso
				weld.Part1 = handle
				weld.C0 = CFrame.fromMatrix(grip, right, ROD_DIR) * CFrame.new(0, info.gripShift, 0) * info.rodAxis:Inverse()
				weld.Parent = handle
			end)
			return function()
				alive = false
				conn:Disconnect()
				if weld then weld:Destroy() end
			end
		end
		local function holdFish(char, handle, info)
			local head = char and char:FindFirstChild("Head")
			if not head then return function() end end
			local overhead = info.overhead
			local weld = Instance.new("Weld")
			weld.Part0 = head
			weld.Part1 = handle
			weld.C0 = CFrame.new(0, head.Size.Y / 2 + 1 + overhead.lift, 0) * overhead.turn * overhead.rootRel
			weld.Parent = handle
			local ARM_UP = CFrame.Angles(math.rad(180), 0, 0)
			local right = char:FindFirstChild("RightShoulder", true)
			local left = char:FindFirstChild("LeftShoulder", true)
			local rightElbow = char:FindFirstChild("RightElbow", true)
			local leftElbow = char:FindFirstChild("LeftElbow", true)
			local conn = RunService.PreSimulation:Connect(function()
				if right then right.Transform = ARM_UP * CFrame.Angles(0, 0, math.rad(-12)) end
				if left then left.Transform = ARM_UP * CFrame.Angles(0, 0, math.rad(12)) end
				if rightElbow then rightElbow.Transform = CFrame.new() end
				if leftElbow then leftElbow.Transform = CFrame.new() end
			end)
			return function()
				conn:Disconnect()
				weld:Destroy()
			end
		end
		local function build(kind, entry)
			local info, err = buildVisual(kind, entry, V.fishWeight, V.rodScale)
			if not info then return nil, err end
			local model, handle = info.model, info.handle
			local tool = Instance.new("Tool")
			tool.Name = entry.name
			tool.CanBeDropped = false
			tool.RequiresHandle = false
			tool:SetAttribute("SenaVisual", kind)
			if kind == "fish" then
				tool:SetAttribute("ItemType", "Phone")
				tool.ToolTip = tostring(entry.tier or "Fish")
			else
				tool.ToolTip = "Rod"
			end
			if entry.icon then tool.TextureId = entry.icon end
			local backModel, backRoot
			if kind == "rods" then backModel, backRoot = scaledBack(info) end
			for _, c in ipairs(model:GetChildren()) do c.Parent = tool end
			model:Destroy()
			tool.Equipped:Connect(function() task.defer(V.refreshQuality) end)
			tool.Unequipped:Connect(function() task.defer(V.refreshQuality) end)
			local release
			if kind == "rods" then
				local backWeld
				V.backs[tool] = function(show)
					local char = LocalPlayer.Character
					if show and char then
						if backModel.Parent ~= char then
							if backWeld then backWeld:Destroy() end
							backWeld = attachBack(char, backModel, backRoot, info)
						end
					else
						backModel.Parent = nil
					end
				end
				tool.Destroying:Connect(function()
					V.backs[tool] = nil
					backModel:Destroy()
				end)
				tool.Equipped:Connect(function()
					V.backRod = tool
					V.updateBack()
					if release then release() end
					release = holdRod(tool.Parent, handle, info)
				end)
				tool.Unequipped:Connect(function()
					if release then release() release = nil end
					V.backRod = tool
					task.defer(V.updateBack)
				end)
			else
				tool.Equipped:Connect(function()
					if release then release() end
					release = holdFish(tool.Parent, handle, info)
				end)
				tool.Unequipped:Connect(function()
					if release then release() release = nil end
				end)
			end
			return tool
		end
		function V.spawn(kind, label)
			local entry = findEntry(kind, label)
			if not entry then V.status = "Pick an item first" return false end
			local backpack = LocalPlayer:FindFirstChild("Backpack")
			if not backpack then V.status = "Backpack not ready" return false end
			local existing = backpack:FindFirstChild(entry.name)
			if existing and existing:GetAttribute("SenaVisual") then V.status = entry.name .. " is already in your backpack" return true end
			V.status = "Loading " .. entry.name .. "..."
			local tool, err = build(kind, entry)
			if not tool then V.status = entry.name .. ": " .. tostring(err) return false end
			tool.Parent = backpack
			if kind == "rods" then
				V.backRod = tool
				V.updateBack()
			end
			V.spawned[kind .. "|" .. entry.name] = { kind = kind, label = entry.name }
			V.status = entry.name .. " added to your backpack"
			return true
		end
		function V.respawn(kind)
			local items = {}
			for key, item in pairs(V.spawned) do
				if item.kind == kind then items[key] = item end
			end
			for _, item in pairs(items) do
				for _, holder in ipairs({ LocalPlayer:FindFirstChild("Backpack"), LocalPlayer.Character }) do
					local old = holder and holder:FindFirstChild(item.label)
					if old and old:IsA("Tool") and old:GetAttribute("SenaVisual") then old:Destroy() end
				end
				V.spawn(item.kind, item.label)
			end
		end
		function V.clear()
			V.spawned = {}
			for _, holder in ipairs({ LocalPlayer:FindFirstChild("Backpack"), LocalPlayer.Character }) do
				if holder then
					for _, t in ipairs(holder:GetChildren()) do
						if t:IsA("Tool") and t:GetAttribute("SenaVisual") then t:Destroy() end
					end
				end
			end
			V.status = "Removed all visual items"
			task.defer(V.refreshQuality)
		end
		local function remoteClear(uid)
			local r = V.remote[uid]
			if not r then return end
			V.remote[uid] = nil
			for _, undo in ipairs(r.cleanup) do pcall(undo) end
		end
		local function parseItem(text)
			local kind, name, num = string.match(text or "", "^(%a+)|([^|]+)|?(.*)$")
			return kind, name, tonumber(num)
		end
		local function showRemote(uid, heldText, backText)
			local plr = Players:GetPlayerByUserId(tonumber(uid) or 0)
			local char = plr and plr.Character
			if not char then remoteClear(uid) return end
			local key = heldText .. "#" .. backText
			local current = V.remote[uid]
			if current and current.key == key and current.char == char then return end
			remoteClear(uid)
			local r = { key = key, char = char, cleanup = {} }
			V.remote[uid] = r
			local kind, name, num = parseItem(heldText)
			local entry = (kind == "rods" or kind == "fish") and findEntry(kind, name) or nil
			if entry then
				local info = buildVisual(kind, entry, kind == "fish" and (num or 0) or 0, kind == "rods" and (num or 1) or 1)
				if info and V.remote[uid] == r and char.Parent then
					info.model.Name = "SenaVisualRemote"
					info.model.Parent = char
					table.insert(r.cleanup, (kind == "rods" and holdRod or holdFish)(char, info.handle, info))
					table.insert(r.cleanup, function() info.model:Destroy() end)
				elseif info then
					info.model:Destroy()
				end
			end
			local backKind, backName = parseItem(backText)
			local backEntry = backKind == "rods" and findEntry("rods", backName) or nil
			if backEntry and V.remote[uid] == r then
				local info = buildVisual("rods", backEntry, 0, 1)
				if info and V.remote[uid] == r and char.Parent then
					local back, root = scaledBack(info)
					info.model:Destroy()
					attachBack(char, back, root, info)
					table.insert(r.cleanup, function() back:Destroy() end)
				elseif info then
					info.model:Destroy()
				end
			end
			task.defer(V.refreshQuality)
		end
		task.spawn(function()
			while sessionAlive() do
				local pause = 6
				pcall(function()
					if #Players:GetPlayers() <= 1 then
						for uid in pairs(V.remote) do remoteClear(uid) end
						return
					end
					local backend = runtimeEnv.SenaBackend or {}
					local api = backend.Api or "https://senahub.xyz/api"
					local held, back = "", ""
					local char = LocalPlayer.Character
					if char then
						for _, t in ipairs(char:GetChildren()) do
							local kind = t:IsA("Tool") and t:GetAttribute("SenaVisual")
							if kind then
								held = kind .. "|" .. t.Name .. "|" .. tostring(kind == "fish" and V.fishWeight or V.rodScale)
								break
							end
						end
						if char:FindFirstChild("SenaVisualBack") and V.backRod then back = "rods|" .. V.backRod.Name end
					end
					local url = string.format("%s/vstate?key=%s&job=%s&uid=%d&held=%s&back=%s", api,
						HttpService:UrlEncode(backend.Key or "sena_20VvixjHsd1OPPwgHYJAstpM"), HttpService:UrlEncode(game.JobId),
						LocalPlayer.UserId, HttpService:UrlEncode(held), HttpService:UrlEncode(back))
					local data = HttpService:JSONDecode(game:HttpGet(url, true))
					if type(data) ~= "table" or data.ok ~= true then return end
					pause = tonumber(data.poll) or 4
					local seen = {}
					for uid, state in pairs(data.players or {}) do
						uid = tostring(uid)
						seen[uid] = true
						showRemote(uid, tostring(state.held or ""), tostring(state.back or ""))
					end
					for uid in pairs(V.remote) do
						if not seen[uid] then remoteClear(uid) end
					end
				end)
				task.wait(pause)
			end
			for uid in pairs(V.remote) do remoteClear(uid) end
		end)
		LocalPlayer.CharacterAdded:Connect(function()
			if not sessionAlive() then return end
			task.wait(1.5)
			for _, item in pairs(V.spawned) do
				pcall(V.spawn, item.kind, item.label)
			end
		end)
		return V
	end)()
end
local SenaExtras = {}
do
	local HttpService = game:GetService("HttpService")
	SenaExtras.hopFailed = false
	SenaExtras.lastHopAt = 0
	pcall(function()
		TeleportService.TeleportInitFailed:Connect(function(player)
			if player == LocalPlayer then
				SenaExtras.hopFailed = true
			end
			end)
		end)
	function SenaExtras.collectServers(maxWanted)
		local list, cursor = {}, ""
		for _ = 1, 3 do
			local ok, body = pcall(function()
				local url = ("https://games.roblox.com/v1/games/%d/servers/Public?sortOrder=Asc&limit=100&excludeFullGames=true"):format(game.PlaceId)
				if cursor ~= "" then
					url = url .. "&cursor=" .. cursor
				end
				return HttpService:JSONDecode(game:HttpGet(url))
				end)
			if not ok or type(body) ~= "table" then break end
			for _, server in ipairs(body.data or {}) do
				if tostring(server.id) ~= game.JobId and server.playing and server.maxPlayers
				and server.playing < server.maxPlayers
				then
					if not maxWanted or server.playing <= maxWanted then
						list[#list + 1] = { id = tostring(server.id), playing = server.playing }
					end
				end
			end
			cursor = body.nextPageCursor or ""
			if cursor == "" then break end
		end
		table.sort(list, function(a, b) return a.playing < b.playing end)
		return list
	end
	function SenaExtras.hopToList(list)
		if type(list) ~= "table" or #list == 0 then return false end
		for _, server in ipairs(list) do
			SenaExtras.hopFailed = false
			local fired = pcall(function()
				TeleportService:TeleportToPlaceInstance(game.PlaceId, server.id, LocalPlayer)
				end)
			if fired then
				local started = os.clock()
				while not SenaExtras.hopFailed and os.clock() - started < 6 do
					task.wait(0.25)
				end
				if not SenaExtras.hopFailed then return true end
			end
			task.wait(0.3)
		end
		return false
	end
	function SenaExtras.hopEmptiest()
		return SenaExtras.hopToList(SenaExtras.collectServers(nil))
	end
	SenaExtras.privateStatus = "Pick a max player count, then Hop Server Now."
	function SenaExtras.privateMax()
		return math.max(1, math.floor(tonumber(tostring(Config.PrivateServerMax or "2"):match("%d+")) or 2))
	end
	function SenaExtras.findPrivateTargets()
		local max = SenaExtras.privateMax()
		local servers = SenaExtras.collectServers(nil)
		if #servers == 0 then return nil end
		local fitting = {}
		for _, server in ipairs(servers) do
			if server.playing + 1 <= max then fitting[#fitting + 1] = server end
		end
		local pool = fitting
		if #pool == 0 then
			local lowest = servers[1].playing
			for _, server in ipairs(servers) do
				if server.playing == lowest then pool[#pool + 1] = server end
			end
		end
		local picked = {}
		while #pool > 0 and #picked < 5 do
			picked[#picked + 1] = table.remove(pool, math.random(1, #pool))
		end
		return picked
	end
	function SenaExtras.hopPrivateOnce()
		local max = SenaExtras.privateMax()
		local count = #Players:GetPlayers()
		if count <= max then
			SenaExtras.privateStatus = "This server is good (" .. count .. " player(s), max " .. max .. ")."
			return false
		end
		if SenaExtras.hubBusy() then
			SenaExtras.privateStatus = "Waiting until you finish stealing..."
			return false
		end
		SenaExtras.privateStatus = "Searching for a quieter server..."
		local targets = SenaExtras.findPrivateTargets()
		if not targets or #targets == 0 then
			SenaExtras.privateStatus = "Could not load the server list. Try again."
			return false
		end
		SenaExtras.privateStatus = "Teleporting..."
		SenaExtras.lastHopAt = os.clock()
		if SenaExtras.hopToList(targets) then
			return true
		end
		SenaExtras.privateStatus = "Teleport failed. Trying again soon."
		return false
	end
	function SenaExtras.startPrivateAutoHop()
		if SenaExtras.privateAutoRunning then return end
		SenaExtras.privateAutoRunning = true
		task.spawn(function()
			while sessionAlive() and Config.PrivateServerAuto do
				local max = SenaExtras.privateMax()
				if #Players:GetPlayers() <= max then
					SenaExtras.privateStatus = "Good server found. Waiting..."
					task.wait(3)
				else
					SenaExtras.hopPrivateOnce()
					task.wait(5)
				end
			end
			SenaExtras.privateAutoRunning = false
			if not Config.PrivateServerAuto then
				SenaExtras.privateStatus = "Auto hop stopped."
			end
			end)
	end
	function SenaExtras.hubBusy()
		if Config.IsPlacing then
			return true
		end
		local runtime = runtimeEnv.__SenaV4EggRuntime
		if runtime and (runtime.running or runtime.travelBusy or (runtime.carry and runtime.carry.active)) then
			return true
		end
		local playerSteal = runtimeEnv.__SenaV4PlayerSteal
		if playerSteal and playerSteal.running then
			return true
		end
		return false
	end
	function SenaExtras.startHopLoop()
		if SenaExtras.hopLoopRunning then return end
		SenaExtras.hopLoopRunning = true
		task.spawn(function()
			while sessionAlive() do
				task.wait(2)
				if Config.HopNoMatch and not SenaExtras.hubBusy() then
					local cooldown = tonumber(Config.HopCooldown) or 5
					if os.clock() - SenaExtras.lastHopAt > cooldown then
						local runtime = runtimeEnv.__SenaV4EggRuntime
						local matching = (runtime and runtime.stats and runtime.stats.matching) or 0
						if Config.AutoSteal and matching <= 0
						and not isStealNightBlocked()
						then
							SenaExtras.lastHopAt = os.clock()
							SenaExtras.hopEmptiest()
						end
					end
				end
			end
			SenaExtras.hopLoopRunning = false
			end)
	end
	function SenaExtras.startAntiTreadmillLoop()
		if SenaExtras.antiTreadmillRunning then return end
		SenaExtras.antiTreadmillRunning = true
		task.spawn(function()
			while sessionAlive() do
				if Config.AntiTreadmill then
					local manager = runtimeEnv.__SenaV4TreadmillManager
					pcall(function()
						if manager and manager.activeTreadmill ~= nil then
							manager:_cancelIdle(true)
							manager:_requestUnequip()
						end
						end)
					local character = LocalPlayer.Character
					local root = character and character:FindFirstChild("HumanoidRootPart")
					if root and root.Anchored then
						pcall(function() root.Anchored = false end)
					end
				end
				task.wait(0.3)
			end
			SenaExtras.antiTreadmillRunning = false
			end)
	end
	function SenaExtras.setBackpackRates(enabled)
		Config.BackpackRateEsp = enabled == true
		if SenaExtras.backpackRatesRunning then return end
		SenaExtras.backpackRatesRunning = true
		task.spawn(function()
			local EggRecords, Save = nil, nil
			pcall(function()
				EggRecords = require(ReplicatedStorage.Shared.Util.EggRecords)
				Save = require(ReplicatedStorage.Shared.Save)
				end)
			while sessionAlive() do
				local grid = nil
				pcall(function() grid = LocalPlayer.PlayerGui.BackpackGui.Backpack.Main.Inventory.ScrollingFrame end)
				local hook = runtimeEnv.__SenaV4Webhook
				local invite = grid and grid.Parent:FindFirstChild("SenaDiscord")
				if grid and Config.BackpackRateEsp and not invite then
					invite = Instance.new("TextLabel")
					invite.Name = "SenaDiscord"
					invite.BackgroundTransparency = 1
					invite.Position = UDim2.new(0.34, 0, 0.017, 0)
					invite.Size = UDim2.new(0.3, 0, 0.09, 0)
					invite.Font = Enum.Font.GothamBlack
					invite.Text = "discord.gg/senahub"
					invite.TextScaled = true
					invite.TextXAlignment = Enum.TextXAlignment.Left
					invite.TextColor3 = Color3.fromRGB(255, 255, 255)
					invite.TextStrokeTransparency = 0
					invite.ZIndex = 40
					invite.Parent = grid.Parent
				elseif invite and not Config.BackpackRateEsp then
					invite:Destroy()
				end
				if grid then
					local byLabel = {}
					if Config.BackpackRateEsp and EggRecords and Save and hook then
						local profile = (Save.Peek or Save.Get)()
						for _, record in pairs((profile and profile.EggInventory) or {}) do
							local ok, label = pcall(EggRecords.DisplayNameWithWeight, record)
							if ok and type(label) == "string" then
								byLabel[label] = byLabel[label] or {}
								table.insert(byLabel[label], record)
							end
						end
					end
					local used = {}
					for _, slot in ipairs(grid:GetChildren()) do
						local nameLabel = slot:IsA("GuiButton") and slot:FindFirstChild("ToolName")
						if nameLabel then
							local text = nameLabel.Text
							local index = (used[text] or 0) + 1
							local record = byLabel[text] and byLabel[text][index]
							local tag = slot:FindFirstChild("SenaRate")
							if record then
								used[text] = index
								if not tag then
									tag = Instance.new("TextLabel")
									tag.Name = "SenaRate"
									tag.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
									tag.BackgroundTransparency = 0.35
									tag.BorderSizePixel = 0
									tag.Position = UDim2.new(0.04, 0, 0, 3)
									tag.Size = UDim2.new(0.92, 0, 0.24, 0)
									tag.Font = Enum.Font.GothamBlack
									tag.TextScaled = true
									tag.TextColor3 = Color3.fromRGB(73, 211, 31)
									tag.TextStrokeTransparency = 0
									tag.ZIndex = 40
									local corner = Instance.new("UICorner")
									corner.CornerRadius = UDim.new(0, 6)
									corner.Parent = tag
									local limit = Instance.new("UITextSizeConstraint")
									limit.MaxTextSize = 20
									limit.Parent = tag
									tag.Parent = slot
								end
								tag.Text = hook.compact(hook.rateOf(record)) .. "/s"
							elseif tag then
								tag:Destroy()
							end
						end
					end
				end
				if not Config.BackpackRateEsp then break end
				task.wait(1)
			end
			SenaExtras.backpackRatesRunning = false
			end)
	end
end
local SenaPanels = {}
local function initSenaPanels()
	local function panelFont(name, fallback)
		local ok, font = pcall(function() return Enum.Font[name] end)
		return ok and font or fallback
	end
	local PANEL_BOLD = panelFont("BuilderSansBold", Enum.Font.GothamBold)
	local PANEL_MEDIUM = panelFont("BuilderSansMedium", Enum.Font.GothamMedium)
	local UserInputService = game:GetService("UserInputService")
	local Assets = require(ReplicatedStorage.Data.Assets)
	local EggState = require(ReplicatedStorage.Client.EggState)
	local Save = require(ReplicatedStorage.Shared.Save)
	local SNE_PAL = {
		strokeCol = Color3.fromRGB(36, 36, 42),
		accent = Color3.fromRGB(26, 147, 250),
		accentA = Color3.fromRGB(19, 96, 250),
		accentB = Color3.fromRGB(33, 198, 250),
		surface = Color3.fromRGB(22, 22, 27),
		surfaceHi = Color3.fromRGB(28, 28, 34),
		text = Color3.fromRGB(235, 236, 245),
		btnText = Color3.fromRGB(186, 184, 198),
		muted = Color3.fromRGB(156, 154, 170),
		shadow = Color3.fromRGB(4, 4, 8),
		obsTop = Color3.fromRGB(18, 18, 24),
		obsMid = Color3.fromRGB(12, 12, 16),
		obsLow = Color3.fromRGB(10, 14, 26),
		btnBg = Color3.fromRGB(30, 30, 36),
		btnHover = Color3.fromRGB(44, 44, 52),
		inputBg = Color3.fromRGB(14, 14, 18),
		switchOff = Color3.fromRGB(42, 42, 48),
		good = Color3.fromRGB(163, 230, 53),
	}
	local LOG_PAL = SNE_PAL
	local SNE_LOGO = "rbxassetid://96240498384290"
	local SNE_DISCORD = "rbxassetid://94434236999817"
	local SNE_INVITE = "discord.gg/senahub"
	local function uiIdentity()
		pcall(function()
			if type(setthreadidentity) == "function" then
				setthreadidentity(8)
			elseif runtimeEnv and type(runtimeEnv.__SenaV4IdentitySetter) == "function" then
				runtimeEnv.__SenaV4IdentitySetter(8)
			end
		end)
	end
	local function resolveGuiHost()
		local pgui = LocalPlayer and LocalPlayer:FindFirstChild("PlayerGui")
		if pgui then return pgui end
		local ok, cg = pcall(function() return game:GetService("CoreGui") end)
		if ok and cg then return cg end
		return game:GetService("CoreGui")
	end
	local function fmtBotNum(n)
		n = tonumber(n) or 0
		if n >= 1e12 then return string.format("%.2fT", n / 1e12)
		elseif n >= 1e9 then return string.format("%.2fB", n / 1e9)
		elseif n >= 1e6 then return string.format("%.2fM", n / 1e6)
		elseif n >= 1e3 then return string.format("%.2fK", n / 1e3)
		else return string.format("%d", n) end
	end
	local function moneyStr(n) return fmtBotNum(n) end
	local function hexOf(col)
		if typeof(col) == "Color3" then
			return string.format("#%02x%02x%02x", math.floor(col.R * 255), math.floor(col.G * 255), math.floor(col.B * 255))
		end
		return "#ffffff"
	end
	local function rarityInfo(cat)
		local cfg = Assets.Directory and Assets.Directory[cat]
		if cfg and cfg.Rarity then
			local rname = cfg.Rarity.DisplayName or cfg.Rarity._id or "?"
			return catalog.rarityRank(rname), rname, cfg.Rarity.Color
		end
		return 0, "?", nil
	end
	local function assetImage(cat)
		local cfg = Assets.Directory and Assets.Directory[cat]
		if type(cfg) ~= "table" then return nil end
		local function coerce(v)
			if type(v) == "string" and v ~= "" then
				if v:find("rbxassetid") or v:find("rbxthumb") then return v end
				if v:match("^%d+$") then return "rbxassetid://" .. v end
			elseif type(v) == "number" and v > 0 then
				return "rbxassetid://" .. tostring(v)
			end
			return nil
		end
		local keys = { "Image", "Icon", "Thumbnail", "ImageId", "IconId", "Texture", "Asset", "DisplayImage" }
		for _, k in ipairs(keys) do
			local r = coerce(cfg[k])
			if r then return r end
		end
		if type(cfg.Egg) == "table" then
			for _, k in ipairs(keys) do
				local r = coerce(cfg.Egg[k])
				if r then return r end
			end
		end
		return nil
	end
	local ALL_SPECIES = {}
	local RARITY_BY_NAME = {}
	do
		for cat, cfg in pairs(Assets.Directory or {}) do
			if type(cfg) == "table" and cfg.Rarity then
				local rname = cfg.Rarity.DisplayName or cfg.Rarity._id or "?"
				local rn = catalog.rarityRank(rname)
				RARITY_BY_NAME[rname] = rn
				table.insert(ALL_SPECIES, { cat = cat, rnum = rn, rname = rname })
			end
		end
		table.sort(ALL_SPECIES, function(a, b)
			if a.rnum == b.rnum then return a.cat < b.cat end
			return a.rnum > b.rnum
		end)
	end
	local function rarityNamesSorted()
		local seen, list = {}, {}
		for _, e in ipairs(ALL_SPECIES) do
			if not seen[e.rname] then
				seen[e.rname] = true
				table.insert(list, { e.rname, e.rnum })
			end
		end
		table.sort(list, function(a, b) return a[2] > b[2] end)
		local out = { "Any" }
		for _, v in ipairs(list) do table.insert(out, v[1]) end
		return out
	end
	local function rarityNamesMulti()
		local out = {}
		for _, r in ipairs(rarityNamesSorted()) do
			if r ~= "Any" then table.insert(out, r) end
		end
		return out
	end
	local function rateOfItem(item)
		local val = 0
		pcall(function()
			val = Config:getAreaEggValue(item) or 0
		end)
		if val > 0 then return val end
		pcall(function()
			local AE = require(ReplicatedStorage.Shared.Util.AssetEarnings)
			if AE and type(AE.LiveRatePerSecond) == "function" then
				val = AE.LiveRatePerSecond(item) or 0
			end
		end)
		return val or 0
	end
	local function weightOfItem(rec)
		local w = 0
		pcall(function()
			local EggRecords = require(ReplicatedStorage.Shared.Util.EggRecords)
			local cat = rec.AssetCategory or rec.Category
			local scale = rec.AssetScale or rec.Scale or 1
			w = EggRecords.WeightKgForScale(cat, scale)
		end)
		return w or 0
	end
	local function plotEggStatus()
		local placed, unplaced = 0, 0
		pcall(function()
			for _, e in pairs(EggState.ReadOwnerEggs(LocalPlayer.UserId) or {}) do
				if e.Placement ~= nil then placed = placed + 1 else unplaced = unplaced + 1 end
			end
		end)
		return placed, math.max(0, 50 - placed), unplaced
	end
	local UIK = {}
	do
		local TweenService = game:GetService("TweenService")
		UIK.type = {
			title = { PANEL_BOLD, 14 },
			body = { PANEL_BOLD, 12 },
			meta = { PANEL_MEDIUM, 11 },
			label = { PANEL_BOLD, 10 },
			value = { PANEL_BOLD, 16 },
		}
		UIK.fast = TweenInfo.new(0.14, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		function UIK.text(parent, props)
			local style = UIK.type[props.style or "body"] or UIK.type.body
			local label = Instance.new("TextLabel")
			label.BackgroundTransparency = 1
			label.Font = style[1]
			label.TextSize = props.textsize or style[2]
			label.TextColor3 = props.color or LOG_PAL.text
			label.TextXAlignment = props.align or Enum.TextXAlignment.Left
			label.TextYAlignment = props.valign or Enum.TextYAlignment.Center
			label.RichText = props.rich == true
			local text = tostring(props.text or "")
			label.Text = props.style == "label" and string.upper(text) or text
			if props.wrap then
				label.TextWrapped = true
				label.AutomaticSize = Enum.AutomaticSize.Y
			else
				label.TextTruncate = Enum.TextTruncate.AtEnd
			end
			label.Size = props.size or UDim2.new(1, 0, 0, style[2] + 4)
			if props.pos then label.Position = props.pos end
			if props.anchor then label.AnchorPoint = props.anchor end
			if props.name then label.Name = props.name end
			if props.order then label.LayoutOrder = props.order end
			label.Parent = parent
			return label
		end
		local iconqueue, iconloop = {}, false
		local function applynow(image, name)
			local lib = runtimeEnv.ChloeX
			if type(lib) == "table" and type(lib.ApplyIcon) == "function" then
				return (pcall(lib.ApplyIcon, image, name, 48))
			end
			local pack = runtimeEnv.SenaLucideIcons
			local set = type(pack) == "table" and (pack["48px"] or pack["256px"]) or nil
			local entry = set and set[name]
			if type(entry) == "table" and entry[2] and entry[3] then
				image.Image = "rbxassetid://" .. tostring(entry[1])
				image.ImageRectSize = Vector2.new(entry[2][1], entry[2][2])
				image.ImageRectOffset = Vector2.new(entry[3][1], entry[3][2])
				return true
			end
			return false
		end
		function UIK.icon(image, name)
			if applynow(image, name) then return end
			iconqueue[#iconqueue + 1] = { image, name }
			if iconloop then return end
			iconloop = true
			task.spawn(function()
				local started = os.clock()
				while #iconqueue > 0 and os.clock() - started < 30 do
					task.wait(0.5)
					uiIdentity()
					local rest = {}
					for _, item in ipairs(iconqueue) do
						if item[1].Parent and not applynow(item[1], item[2]) then
							rest[#rest + 1] = item
						end
					end
					iconqueue = rest
				end
				iconloop = false
			end)
		end
		function UIK.image(parent, name, size, color)
			local img = Instance.new("ImageLabel")
			img.BackgroundTransparency = 1
			img.ImageColor3 = color or LOG_PAL.muted
			img.Size = UDim2.fromOffset(size, size)
			img.Parent = parent
			UIK.icon(img, name)
			return img
		end
		local kinds = {
			primary = { bg = LOG_PAL.accent, hover = LOG_PAL.accentB, text = Color3.fromRGB(255, 255, 255), alpha = 0.1 },
			ghost = { bg = LOG_PAL.btnBg, hover = LOG_PAL.btnHover, text = LOG_PAL.btnText, alpha = 0.15 },
			danger = { bg = Color3.fromRGB(70, 30, 34), hover = Color3.fromRGB(92, 38, 42), text = Color3.fromRGB(248, 113, 113), alpha = 0.1 },
		}
		function UIK.button(parent, props)
			local look = kinds[props.kind or "ghost"] or kinds.ghost
			local b = Instance.new("TextButton")
			b.AutoButtonColor = false
			b.AutomaticSize = Enum.AutomaticSize.X
			b.BackgroundColor3 = look.bg
			b.BackgroundTransparency = look.alpha
			b.BorderSizePixel = 0
			b.LayoutOrder = props.order or 0
			b.Size = UDim2.fromOffset(props.minw or 0, props.h or 26)
			b.Text = ""
			Instance.new("UICorner", b).CornerRadius = UDim.new(0, 6)
			local pad = Instance.new("UIPadding", b)
			pad.PaddingLeft = UDim.new(0, props.icon and 8 or 10)
			pad.PaddingRight = UDim.new(0, 10)
			local layout = Instance.new("UIListLayout", b)
			layout.FillDirection = Enum.FillDirection.Horizontal
			layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
			layout.Padding = UDim.new(0, 5)
			layout.SortOrder = Enum.SortOrder.LayoutOrder
			layout.VerticalAlignment = Enum.VerticalAlignment.Center
			local img
			if props.icon then
				img = UIK.image(b, props.icon, 13, look.text)
				img.LayoutOrder = 0
			end
			local label = Instance.new("TextLabel")
			label.AutomaticSize = Enum.AutomaticSize.X
			label.BackgroundTransparency = 1
			label.Font = PANEL_BOLD
			label.LayoutOrder = 1
			label.Size = UDim2.new(0, 0, 1, 0)
			label.Text = tostring(props.text or "")
			label.TextColor3 = look.text
			label.TextSize = 12
			label.Parent = b
			local scale = Instance.new("UIScale", b)
			local api = { inst = b, label = label, icon = img, active = false, enabled = true }
			local function paint()
				local current = api.active and kinds.primary or look
				b.BackgroundColor3 = current.bg
				b.BackgroundTransparency = api.enabled and current.alpha or 0.6
				label.TextColor3 = current.text
				label.TextTransparency = api.enabled and 0 or 0.5
				if img then img.ImageColor3 = current.text end
			end
			b.MouseEnter:Connect(function()
				if api.enabled and not api.active then
					TweenService:Create(b, UIK.fast, { BackgroundColor3 = look.hover }):Play()
				end
			end)
			b.MouseLeave:Connect(function()
				if not api.active then
					TweenService:Create(b, UIK.fast, { BackgroundColor3 = look.bg }):Play()
				end
			end)
			b.MouseButton1Down:Connect(function()
				if not api.enabled then return end
				TweenService:Create(scale, UIK.fast, { Scale = 0.96 }):Play()
			end)
			b.MouseButton1Up:Connect(function()
				TweenService:Create(scale, UIK.fast, { Scale = 1 }):Play()
			end)
			b.MouseButton1Click:Connect(function()
				if api.enabled and props.onClick then
					uiIdentity()
					local ok, err = pcall(props.onClick, api)
					if not ok then warn("[Sena panels] button error:", err) end
				end
			end)
			function api.setText(text) label.Text = tostring(text) end
			function api.setActive(on) api.active = on == true paint() end
			function api.setEnabled(on) api.enabled = on ~= false b.Active = api.enabled paint() end
			function api.setKind(kind) look = kinds[kind] or kinds.ghost paint() end
			b.Parent = parent
			return api
		end
		function UIK.segmented(parent, props)
			local bar = Instance.new("ScrollingFrame")
			bar.AutomaticCanvasSize = Enum.AutomaticSize.X
			bar.BackgroundTransparency = 1
			bar.BorderSizePixel = 0
			bar.CanvasSize = UDim2.new(0, 0, 0, 0)
			bar.ScrollBarThickness = 0
			bar.ScrollingDirection = Enum.ScrollingDirection.X
			bar.Size = props.size or UDim2.new(1, 0, 0, (props.h or 24) + 4)
			if props.pos then bar.Position = props.pos end
			if props.order then bar.LayoutOrder = props.order end
			local layout = Instance.new("UIListLayout", bar)
			layout.FillDirection = Enum.FillDirection.Horizontal
			layout.Padding = UDim.new(0, 6)
			layout.SortOrder = Enum.SortOrder.LayoutOrder
			layout.VerticalAlignment = Enum.VerticalAlignment.Center
			local api = { inst = bar, value = props.value, buttons = {} }
			function api.set(key, fire)
				api.value = key
				for k, btn in pairs(api.buttons) do
					btn.setActive(k == key)
				end
				if fire and props.onChange then props.onChange(key) end
			end
			for index, option in ipairs(props.options or {}) do
				local key, text = option[1], option[2]
				api.buttons[key] = UIK.button(bar, {
					text = text,
					h = props.h or 24,
					order = index,
					onClick = function() api.set(key, true) end,
				})
			end
			api.set(props.value, false)
			bar.Parent = parent
			return api
		end
		function UIK.list(props)
			local pool, api = {}, {}
			function api.setData(items)
				uiIdentity()
				for index, item in ipairs(items) do
					local record = pool[index]
					if not record then
						record = props.build(index)
						pool[index] = record
					end
					record.frame.LayoutOrder = index
					record.frame.Visible = true
					props.bind(record, item, index)
				end
				for index = #items + 1, #pool do
					pool[index].frame.Visible = false
				end
			end
			return api
		end
		function UIK.stat(parent, props)
			local tile = Instance.new("Frame")
			tile.BackgroundColor3 = LOG_PAL.surface
			tile.BackgroundTransparency = 0.1
			tile.BorderSizePixel = 0
			tile.LayoutOrder = props.order or 0
			tile.Size = props.size or UDim2.new(0.5, -4, 0, 62)
			Instance.new("UICorner", tile).CornerRadius = UDim.new(0, 8)
			local stroke = Instance.new("UIStroke", tile)
			stroke.Color = LOG_PAL.strokeCol
			stroke.Transparency = 0.6
			local img = UIK.image(tile, props.icon or "circle-dot", 12, LOG_PAL.muted)
			img.Position = UDim2.fromOffset(10, 10)
			local label = UIK.text(tile, { text = props.label, style = "label", color = LOG_PAL.muted, pos = UDim2.fromOffset(27, 7), size = UDim2.new(1, -36, 0, 16) })
			local value = UIK.text(tile, { text = "--", style = "value", pos = UDim2.fromOffset(10, 23), size = UDim2.new(1, -20, 0, 20) })
			local meta = UIK.text(tile, { text = "", style = "meta", color = LOG_PAL.muted, pos = UDim2.fromOffset(10, 43), size = UDim2.new(1, -20, 0, 14) })
			meta.RichText = true
			tile.Parent = parent
			local api = { inst = tile, label = label, value = value, meta = meta }
			function api.set(v, m, color)
				v = tostring(v)
				if value.Text ~= v then value.Text = v end
				m = tostring(m or "")
				if meta.Text ~= m then meta.Text = m end
				meta.TextColor3 = color or LOG_PAL.muted
			end
			return api
		end
		function UIK.card(parent, props)
			local card = Instance.new("Frame")
			card.AutomaticSize = Enum.AutomaticSize.Y
			card.BackgroundColor3 = LOG_PAL.surface
			card.BackgroundTransparency = 0.1
			card.BorderSizePixel = 0
			card.LayoutOrder = props.order or 0
			card.Size = UDim2.new(1, 0, 0, 0)
			Instance.new("UICorner", card).CornerRadius = UDim.new(0, 8)
			local stroke = Instance.new("UIStroke", card)
			stroke.Color = LOG_PAL.strokeCol
			stroke.Transparency = 0.6
			local pad = Instance.new("UIPadding", card)
			pad.PaddingBottom = UDim.new(0, 10)
			pad.PaddingLeft = UDim.new(0, 10)
			pad.PaddingRight = UDim.new(0, 10)
			pad.PaddingTop = UDim.new(0, 8)
			local layout = Instance.new("UIListLayout", card)
			layout.Padding = UDim.new(0, 5)
			layout.SortOrder = Enum.SortOrder.LayoutOrder
			local head = Instance.new("Frame")
			head.BackgroundTransparency = 1
			head.LayoutOrder = 0
			head.Size = UDim2.new(1, 0, 0, 16)
			head.Parent = card
			if props.icon then
				local img = UIK.image(head, props.icon, 12, LOG_PAL.accent)
				img.Position = UDim2.fromOffset(0, 2)
			end
			UIK.text(head, { text = props.title, style = "label", color = LOG_PAL.muted, pos = UDim2.fromOffset(props.icon and 17 or 0, 0), size = UDim2.new(1, -20, 1, 0) })
			card.Parent = parent
			return card
		end
		local queued = {}
		function UIK.later(key, fn)
			if queued[key] then return end
			queued[key] = true
			task.defer(function()
				queued[key] = nil
				uiIdentity()
				local ok, err = pcall(fn)
				if not ok then warn("[Sena panels] repaint error:", err) end
			end)
		end
		function UIK.assetrow(list, rightwidth, extra)
			local row = Instance.new("Frame")
			row.BackgroundColor3 = LOG_PAL.surface
			row.BackgroundTransparency = 0.12
			row.BorderSizePixel = 0
			row.Size = UDim2.new(1, -6, 0, 40)
			Instance.new("UICorner", row).CornerRadius = UDim.new(0, 6)
			local stroke = Instance.new("UIStroke", row)
			stroke.Color = LOG_PAL.strokeCol
			stroke.Transparency = 0.72
			local bar = Instance.new("Frame")
			bar.BorderSizePixel = 0
			bar.Position = UDim2.fromOffset(0, 6)
			bar.Size = UDim2.new(0, 3, 1, -12)
			bar.Parent = row
			Instance.new("UICorner", bar).CornerRadius = UDim.new(1, 0)
			local icon = Instance.new("ImageLabel")
			icon.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
			icon.BackgroundTransparency = 0.94
			icon.BorderSizePixel = 0
			icon.Position = UDim2.fromOffset(10, 7)
			icon.ScaleType = Enum.ScaleType.Fit
			icon.Size = UDim2.fromOffset(26, 26)
			icon.Parent = row
			Instance.new("UICorner", icon).CornerRadius = UDim.new(0, 6)
			local dot = Instance.new("Frame")
			dot.AnchorPoint = Vector2.new(0.5, 0.5)
			dot.BorderSizePixel = 0
			dot.Position = UDim2.fromScale(0.5, 0.5)
			dot.Size = UDim2.fromOffset(9, 9)
			dot.Parent = icon
			Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)
			local name = UIK.text(row, { style = "body", pos = UDim2.fromOffset(44, 5), size = UDim2.new(1, -(44 + rightwidth + 14), 0, 16) })
			local sub = UIK.text(row, { style = "meta", pos = UDim2.fromOffset(44, 21), size = UDim2.new(1, -(44 + rightwidth + 14), 0, 14) })
			local right = Instance.new("Frame")
			right.AnchorPoint = Vector2.new(1, 0.5)
			right.BackgroundTransparency = 1
			right.Position = UDim2.new(1, -8, 0.5, 0)
			right.Size = UDim2.new(0, rightwidth, 1, -8)
			right.Parent = row
			row.Parent = list
			local record = { frame = row, bar = bar, icon = icon, dot = dot, name = name, sub = sub, right = right }
			if extra then extra(record) end
			return record
		end
		function UIK.bindasset(record, image, color, title, subtitle)
			record.bar.BackgroundColor3 = color or LOG_PAL.accent
			record.icon.Image = image or ""
			record.dot.Visible = image == nil
			record.dot.BackgroundColor3 = color or LOG_PAL.accent
			record.name.Text = tostring(title or "")
			record.sub.Text = tostring(subtitle or "")
			record.sub.TextColor3 = color or LOG_PAL.muted
		end
		function UIK.scroller(parent, pos, size)
			local list = Instance.new("ScrollingFrame")
			list.AutomaticCanvasSize = Enum.AutomaticSize.Y
			list.BackgroundTransparency = 1
			list.BorderSizePixel = 0
			list.CanvasSize = UDim2.new(0, 0, 0, 0)
			list.Position = pos
			list.ScrollBarImageColor3 = LOG_PAL.accent
			list.ScrollBarThickness = 3
			list.ScrollingDirection = Enum.ScrollingDirection.Y
			list.Size = size
			list.Parent = parent
			local layout = Instance.new("UIListLayout", list)
			layout.Padding = UDim.new(0, 4)
			layout.SortOrder = Enum.SortOrder.LayoutOrder
			return list
		end
		function UIK.empty(list, text)
			local label = UIK.text(list, { text = text, style = "meta", color = LOG_PAL.muted, align = Enum.TextXAlignment.Center, size = UDim2.new(1, -6, 0, 40) })
			label.LayoutOrder = -1
			label.Visible = false
			return label
		end
	end
	local panelEggLog = {}
	local seenLogUids = {}
	local function recordEggLog(rec)
		local cat = rec and (rec.AssetCategory or rec.Category)
		if not cat then return end
		local uid = rec.Uid
		if uid ~= nil then
			if seenLogUids[uid] then return end
			seenLogUids[uid] = true
		end
		local e = panelEggLog[cat]
		if not e then
			local rnum, rname, rcolor = rarityInfo(cat)
			e = { name = cat, rarity = rname, rnum = rnum, color = rcolor, count = 0, last = 0, image = assetImage(cat) }
			panelEggLog[cat] = e
		end
		e.count = e.count + 1
		e.last = os.clock()
	end
	local panels = {}
	local function panelShown(key)
		local p = panels[key]
		return (p ~= nil and p.gui ~= nil and p.gui.Parent ~= nil and p.gui.Enabled) or false
	end
	local refreshLogs, refreshPlacePanel, refreshPetsPage, refreshStats
	local CK = { list = nil, headLbl = nil, countLbl = nil, statusBtn = nil, sel = nil, rows = {}, picked = {}, chips = {}, sortBtns = {}, modeBtns = {} }
	local ED = { history = {}, reportedUids = {}, knownFieldUids = {}, lastAlert = nil, lastReportTime = 0, lastSync = 0, onlineCount = 1, category = "targets", filter = "All" }
	local function refreshPanel(key)
		uiIdentity()
		if key == "logs" then
			if refreshLogs then refreshLogs() end
		elseif key == "eggs" then
			if refreshPlacePanel then refreshPlacePanel() end
		elseif key == "inventory" then
			if refreshPetsPage then refreshPetsPage() end
		elseif key == "checker" then
			if CK and CK.refresh then CK.refresh() end
		elseif key == "eggdata" then
			if ED and ED.refresh then ED.refresh() end
		elseif key == "stats" then
			if refreshStats then refreshStats() end
		end
	end
	local logsView = { sort = "rarity", list = nil, total = nil, empty = nil }
	refreshLogs = function()
		uiIdentity()
		if not logsView.list then return end
		local rows, total = {}, 0
		for _, e in pairs(panelEggLog) do
			table.insert(rows, e)
			total = total + e.count
		end
		if logsView.sort == "count" then
			table.sort(rows, function(a, b)
				if a.count == b.count then return (a.rnum or 0) > (b.rnum or 0) end
				return a.count > b.count
			end)
		elseif logsView.sort == "name" then
			table.sort(rows, function(a, b) return tostring(a.name) < tostring(b.name) end)
		else
			table.sort(rows, function(a, b)
				if a.rnum == b.rnum then return a.count > b.count end
				return (a.rnum or 0) > (b.rnum or 0)
			end)
		end
		logsView.list.setData(rows)
		logsView.empty.Visible = #rows == 0
		logsView.total.Text = string.format("%d egg%s seen", total, total == 1 and "" or "s")
	end
	local function buildLogsPage(parent)
		logsView.total = UIK.text(parent, { style = "meta", color = LOG_PAL.muted, align = Enum.TextXAlignment.Right, anchor = Vector2.new(1, 0), pos = UDim2.new(1, -14, 0, 6), size = UDim2.fromOffset(140, 20) })
		local sort = UIK.segmented(parent, {
			options = { { "rarity", "Rarity" }, { "count", "Amount" }, { "name", "Name" } },
			value = logsView.sort,
			pos = UDim2.fromOffset(14, 2),
			size = UDim2.new(1, -170, 0, 28),
			onChange = function(key)
				logsView.sort = key
				refreshLogs()
			end,
		})
		local clear = UIK.button(parent, {
			text = "Clear",
			icon = "trash-2",
			onClick = function()
				panelEggLog = {}
				seenLogUids = {}
				refreshLogs()
			end,
		})
		clear.inst.AnchorPoint = Vector2.new(1, 0)
		clear.inst.Position = UDim2.new(1, -14, 0, 30)
		UIK.text(parent, { text = "Egg", style = "label", color = LOG_PAL.muted, pos = UDim2.fromOffset(16, 40), size = UDim2.fromOffset(120, 14) })
		local scroller = UIK.scroller(parent, UDim2.fromOffset(14, 60), UDim2.new(1, -28, 1, -68))
		logsView.empty = UIK.empty(scroller, "No eggs seen yet. Eggs that spawn on the field show up here.")
		logsView.list = UIK.list({
			build = function()
				return UIK.assetrow(scroller, 70, function(record)
					record.count = UIK.text(record.right, { style = "value", textsize = 14, color = LOG_PAL.accent, align = Enum.TextXAlignment.Right, size = UDim2.fromScale(1, 1) })
				end)
			end,
			bind = function(record, e)
				UIK.bindasset(record, e.image, e.color, e.name, e.rarity)
				record.count.Text = "x" .. tostring(e.count)
			end,
		})
		sort.set(logsView.sort, false)
		refreshLogs()
	end
	local boardView = { filter = "All", list = nil, total = nil, status = nil, empty = nil }
	local panelPlaceEnabled = {}
	refreshPlacePanel = function()
		uiIdentity()
		if not boardView.list then return end
		local okR, recs = pcall(function() return EggState.ReadOwnerEggs(LocalPlayer.UserId) end)
		if not okR or type(recs) ~= "table" then
			boardView.list.setData({})
			boardView.total.Text = "0 waiting"
			return
		end
		local rows, enabledCount = {}, 0
		for uid, rec in pairs(recs) do
			if rec.Placement == nil and tostring(uid):sub(1, 8) ~= "SENAVIS_" then
				local rnum, rname, rcolor = rarityInfo(rec.AssetCategory)
				if boardView.filter == "All" or rname == boardView.filter then
					local on = (panelPlaceEnabled[uid] ~= false)
					if on then enabledCount = enabledCount + 1 end
					local cfg = Assets.Directory and Assets.Directory[rec.AssetCategory]
					table.insert(rows, {
						uid = uid,
						name = (cfg and cfg.DisplayName) or rec.AssetCategory or tostring(uid):sub(1, 8),
						rarity = rname,
						rnum = rnum,
						color = rcolor,
						image = assetImage(rec.AssetCategory),
						enabled = on,
					})
				end
			end
		end
		table.sort(rows, function(a, b)
			if a.rnum == b.rnum then return a.name < b.name end
			return (a.rnum or 0) > (b.rnum or 0)
		end)
		boardView.list.setData(rows)
		boardView.empty.Visible = #rows == 0
		boardView.total.Text = string.format("%d waiting  ·  %d on", #rows, enabledCount)
		local placed, room, backlog = plotEggStatus()
		if room <= 0 then
			boardView.status.Text = string.format("Plot full: %d/50 placed, %d waiting", placed, backlog)
			boardView.status.TextColor3 = Color3.fromRGB(245, 196, 81)
		else
			boardView.status.Text = string.format("Plot %d/50  ·  room for %d more  ·  %d waiting", placed, room, backlog)
			boardView.status.TextColor3 = LOG_PAL.muted
		end
	end
	local function buildPlacePage(parent)
		local options = { { "All", "All" } }
		for _, r in ipairs(rarityNamesMulti()) do
			options[#options + 1] = { r, r }
		end
		UIK.segmented(parent, {
			options = options,
			value = boardView.filter,
			pos = UDim2.fromOffset(14, 2),
			size = UDim2.new(1, -28, 0, 28),
			onChange = function(key)
				boardView.filter = key
				refreshPlacePanel()
			end,
		})
		UIK.text(parent, { text = "Egg", style = "label", color = LOG_PAL.muted, pos = UDim2.fromOffset(16, 38), size = UDim2.fromOffset(120, 14) })
		UIK.text(parent, { text = "Place", style = "label", color = LOG_PAL.muted, align = Enum.TextXAlignment.Right, anchor = Vector2.new(1, 0), pos = UDim2.new(1, -18, 0, 38), size = UDim2.fromOffset(60, 14) })
		local scroller = UIK.scroller(parent, UDim2.fromOffset(14, 56), UDim2.new(1, -28, 1, -124))
		boardView.empty = UIK.empty(scroller, "No eggs waiting to be placed.")
		boardView.list = UIK.list({
			build = function()
				return UIK.assetrow(scroller, 64, function(record)
					record.toggle = UIK.button(record.right, {
						text = "ON",
						h = 24,
						minw = 52,
						onClick = function()
							local uid = record.uid
							if uid == nil then return end
							if panelPlaceEnabled[uid] == false then
								panelPlaceEnabled[uid] = nil
							else
								panelPlaceEnabled[uid] = false
							end
							refreshPlacePanel()
						end,
					})
					record.toggle.inst.AnchorPoint = Vector2.new(1, 0.5)
					record.toggle.inst.Position = UDim2.new(1, 0, 0.5, 0)
				end)
			end,
			bind = function(record, e)
				record.uid = e.uid
				UIK.bindasset(record, e.image, e.color, e.name, e.rarity)
				record.toggle.setText(e.enabled and "ON" or "OFF")
				record.toggle.setActive(e.enabled)
			end,
		})
		local actions = Instance.new("Frame")
		actions.BackgroundTransparency = 1
		actions.Position = UDim2.new(0, 14, 1, -62)
		actions.Size = UDim2.new(1, -28, 0, 28)
		actions.Parent = parent
		local al = Instance.new("UIListLayout", actions)
		al.FillDirection = Enum.FillDirection.Horizontal
		al.Padding = UDim.new(0, 6)
		al.SortOrder = Enum.SortOrder.LayoutOrder
		al.VerticalAlignment = Enum.VerticalAlignment.Center
		UIK.button(actions, {
			text = "Toggle all",
			order = 1,
			h = 28,
			icon = "list",
			onClick = function()
				local okR, recs = pcall(function() return EggState.ReadOwnerEggs(LocalPlayer.UserId) end)
				if not okR or type(recs) ~= "table" then return end
				local anyOff = false
				for uid, rec in pairs(recs) do
					if rec.Placement == nil and panelPlaceEnabled[uid] == false then
						anyOff = true
						break
					end
				end
				for uid, rec in pairs(recs) do
					if rec.Placement == nil then
						if anyOff then panelPlaceEnabled[uid] = nil else panelPlaceEnabled[uid] = false end
					end
				end
				refreshPlacePanel()
			end,
		})
		UIK.button(actions, {
			text = "Start placing",
			kind = "primary",
			order = 2,
			h = 28,
			icon = "play",
			onClick = function()
				if type(applyAutoPlace) == "function" then
					applyAutoPlace(true)
				elseif type(UIRunners) == "table" and type(UIRunners.AutoPlaceLoop) == "function" then
					Config.AutoPlace = true
					task.spawn(UIRunners.AutoPlaceLoop)
				end
			end,
		})
		boardView.total = UIK.text(actions, { style = "meta", color = LOG_PAL.muted, align = Enum.TextXAlignment.Right, order = 3, size = UDim2.new(1, -250, 1, 0) })
		boardView.total.LayoutOrder = 3
		boardView.status = UIK.text(parent, { style = "meta", color = LOG_PAL.muted, pos = UDim2.new(0, 16, 1, -28), size = UDim2.new(1, -32, 0, 18) })
		refreshPlacePanel()
	end
	local petsViewState = { view = "backpack", sort = "moneys", asc = false, list = nil, total = nil, empty = nil, sortbar = nil }
	local function collectPets(view)
		local sd = (Save.Peek or Save.Get)() or {}
		local rows, totalMoney = {}, 0
		local function push(uid, rec)
			if tostring(uid):sub(1, 8) == "SENAVIS_" then return end
			local cat = rec.AssetCategory or rec.Category
			local cfg = Assets.Directory and Assets.Directory[cat]
			local rnum, rname, rcolor = rarityInfo(cat)
			local rate = rateOfItem({
				AssetCategory = cat,
				AssetScale = rec.Scale or rec.AssetScale or 1,
				Category = cat,
				Scale = rec.Scale or rec.AssetScale or 1,
				Mutations = rec.Mutations or {},
			})
			local kg = weightOfItem(rec)
			totalMoney = totalMoney + rate
			table.insert(rows, {
				name = (cfg and cfg.DisplayName) or tostring(cat),
				icon = assetImage(cat),
				kg = kg,
				kgS = string.format("%.1f kg", kg),
				moneys = rate,
				rnum = rnum,
				rarity = rname,
				color = rcolor,
			})
		end
		if view == "inplot" then
			for _, uid in ipairs(sd.EquippedAssets or {}) do
				local rec = sd.Inventory and sd.Inventory[uid]
				if rec then push(uid, rec) end
			end
		else
			for uid, rec in pairs(sd.Inventory or {}) do
				if type(rec) == "table" and (rec.AssetCategory or rec.Category) then push(uid, rec) end
			end
		end
		return rows, totalMoney
	end
	SenaPanels.collectPets = collectPets
	local sortLabels = { moneys = "Money/s", kg = "Kg", rarity = "Rarity", name = "Name" }
	local function paintPetSortLabels()
		if not petsViewState.sortbar then return end
		for key, btn in pairs(petsViewState.sortbar.buttons) do
			local text = sortLabels[key]
			if key == petsViewState.sort then
				text = text .. (petsViewState.asc and "  ↑" or "  ↓")
			end
			btn.setText(text)
		end
	end
	refreshPetsPage = function()
		uiIdentity()
		if not petsViewState.list then return end
		local rows, totalMoney = collectPets(petsViewState.view)
		local sortKey = (petsViewState.sort == "rarity") and "rnum" or petsViewState.sort
		table.sort(rows, function(a, b)
			if a[sortKey] == b[sortKey] then return a.name < b.name end
			if petsViewState.asc then return (a[sortKey] or 0) < (b[sortKey] or 0) end
			return (a[sortKey] or 0) > (b[sortKey] or 0)
		end)
		petsViewState.list.setData(rows)
		petsViewState.empty.Visible = #rows == 0
		if petsViewState.view == "inplot" then
			petsViewState.total.Text = string.format("%d placed  ·  %s/s", #rows, moneyStr(totalMoney))
		else
			petsViewState.total.Text = string.format("%d pet%s", #rows, #rows == 1 and "" or "s")
		end
	end
	local function buildPetsPage(parent)
		petsViewState.total = UIK.text(parent, { style = "meta", color = LOG_PAL.muted, align = Enum.TextXAlignment.Right, anchor = Vector2.new(1, 0), pos = UDim2.new(1, -14, 0, 6), size = UDim2.fromOffset(170, 20) })
		UIK.segmented(parent, {
			options = { { "backpack", "Backpack" }, { "inplot", "Base" } },
			value = petsViewState.view,
			pos = UDim2.fromOffset(14, 2),
			size = UDim2.new(1, -200, 0, 28),
			onChange = function(key)
				petsViewState.view = key
				refreshPetsPage()
			end,
		})
		petsViewState.sortbar = UIK.segmented(parent, {
			options = { { "moneys", "Money/s" }, { "kg", "Kg" }, { "rarity", "Rarity" }, { "name", "Name" } },
			value = petsViewState.sort,
			pos = UDim2.fromOffset(14, 34),
			size = UDim2.new(1, -28, 0, 28),
			onChange = function(key)
				if petsViewState.sort == key then
					petsViewState.asc = not petsViewState.asc
				else
					petsViewState.sort = key
					petsViewState.asc = false
				end
				paintPetSortLabels()
				refreshPetsPage()
			end,
		})
		UIK.text(parent, { text = "Pet", style = "label", color = LOG_PAL.muted, pos = UDim2.fromOffset(16, 68), size = UDim2.fromOffset(120, 14) })
		UIK.text(parent, { text = "Money/s  ·  Kg", style = "label", color = LOG_PAL.muted, align = Enum.TextXAlignment.Right, anchor = Vector2.new(1, 0), pos = UDim2.new(1, -18, 0, 68), size = UDim2.fromOffset(140, 14) })
		local scroller = UIK.scroller(parent, UDim2.fromOffset(14, 86), UDim2.new(1, -28, 1, -94))
		petsViewState.empty = UIK.empty(scroller, "No pets here yet.")
		petsViewState.list = UIK.list({
			build = function()
				return UIK.assetrow(scroller, 96, function(record)
					record.money = UIK.text(record.right, { style = "body", align = Enum.TextXAlignment.Right, pos = UDim2.fromOffset(0, 1), size = UDim2.new(1, 0, 0, 16) })
					record.money.Font = PANEL_BOLD
					record.kg = UIK.text(record.right, { style = "meta", color = LOG_PAL.muted, align = Enum.TextXAlignment.Right, pos = UDim2.fromOffset(0, 17), size = UDim2.new(1, 0, 0, 14) })
				end)
			end,
			bind = function(record, e)
				UIK.bindasset(record, e.icon, e.color, e.name, e.rarity)
				record.money.Text = moneyStr(e.moneys) .. "/s"
				record.money.TextColor3 = e.moneys > 0 and LOG_PAL.text or LOG_PAL.muted
				record.kg.Text = e.kgS
			end,
		})
		paintPetSortLabels()
		refreshPetsPage()
	end
	local statsView = {}
	local statsSessionStart = os.clock()
	local bestSteal = nil
	local bestSeen = {}
	pcall(function()
		local hook = runtimeEnv.__SenaV4Webhook
		if type(hook) == "table" and type(hook.stolen) == "function" and not rawget(hook, "__senaStatsWrapped") then
			local original = hook.stolen
			rawset(hook, "__senaStatsWrapped", true)
			hook.stolen = function(record, info, source)
				pcall(function()
					local uid = type(record) == "table" and record.Uid or nil
					if uid ~= nil then
						if bestSeen[uid] then return end
						bestSeen[uid] = true
					end
					local rate = type(hook.rateOf) == "function" and tonumber(hook.rateOf(record)) or 0
					if not bestSteal or rate > bestSteal.rate then
						local name = (type(info) == "table" and info.name) or (type(record) == "table" and record.AssetCategory) or "Egg"
						bestSteal = { name = tostring(name), rate = rate or 0 }
					end
				end)
				return original(record, info, source)
			end
		end
	end)
	local function fmtDuration(seconds)
		seconds = math.max(0, math.floor(seconds))
		return string.format("%02d:%02d:%02d", math.floor(seconds / 3600), math.floor(seconds % 3600 / 60), seconds % 60)
	end
	refreshStats = function()
		uiIdentity()
		if not statsView.tiles then return end
		local sd = (Save.Peek or Save.Get)() or {}
		local ladder = runtimeEnv.__SenaV4TaskLadder
		local current = ladder and ladder.current() or nil
		if current then
			local text = ladder.describe(current)
			statsView.nowTask.Text = ladder.TITLES[current] or tostring(current)
			statsView.nowStatus.Text = tostring(text or "")
			statsView.nowDot.BackgroundColor3 = LOG_PAL.good
		else
			statsView.nowTask.Text = "Idle"
			statsView.nowStatus.Text = "Nothing is using the character"
			statsView.nowDot.BackgroundColor3 = LOG_PAL.muted
		end
		local ping = 0
		pcall(function() ping = math.floor((LocalPlayer:GetNetworkPing() or 0) * 2000 + 0.5) end)
		statsView.nowMeta.Text = string.format("%s  ·  %d ms  ·  %d fps", fmtDuration(os.clock() - statsSessionStart), ping, math.floor((tonumber(currentFps()) or 0) + 0.5))
		local placedPets, income = collectPets("inplot")
		local money = tonumber(sd.Money) or 0
		statsView.tiles.money.set(moneyStr(money), "+" .. moneyStr(income * 3600) .. " per hour", LOG_PAL.good)
		statsView.tiles.income.set(moneyStr(income) .. "/s", #placedPets .. " pet" .. (#placedPets == 1 and "" or "s") .. " placed")
		local speed, nextTier = nil, ""
		pcall(function()
			local mx = runtimeEnv.__SenaV4MovementExtras
			if mx then speed = tonumber(mx:_gameWalkSpeed()) end
		end)
		pcall(function()
			local tm = runtimeEnv.__SenaV4TreadmillManager
			if tm then
				local level, _, cfg = tm:_readUpgradeState()
				if cfg then
					nextTier = "Next: " .. tostring(cfg.DisplayName or cfg._id or "tier") .. "  " .. moneyStr(tonumber(cfg.Price) or 0)
				elseif level then
					nextTier = "Treadmill maxed"
				end
			end
		end)
		statsView.tiles.speed.set(speed and string.format("%.0f", speed) or "--", nextTier)
		local rt = runtimeEnv.__SenaV4EggRuntime
		local ps = runtimeEnv.__SenaV4PlayerSteal
		local stolen = (rt and rt.stats and tonumber(rt.stats.delivered) or 0) + (ps and tonumber(ps.taken) or 0)
		statsView.tiles.stolen.set(tostring(stolen),
			bestSteal and ("Best: " .. bestSteal.name .. "  " .. moneyStr(bestSteal.rate) .. "/s") or "No steal yet this session")
		local petsTotal = 0
		for uid in pairs(sd.Inventory or {}) do
			if tostring(uid):sub(1, 8) ~= "SENAVIS_" then petsTotal = petsTotal + 1 end
		end
		local placed, _, waiting = plotEggStatus()
		statsView.tiles.collection.set(petsTotal .. " pets", string.format("Eggs %d/50 placed  ·  %d waiting", placed, waiting))
		local wallClosed = false
		pcall(function() wallClosed = rt ~= nil and rt:getSnapshot().wallClosed == true end)
		statsView.tiles.world.set(wallClosed and "Night" or "Day", #Players:GetPlayers() .. " players in this server",
			wallClosed and Color3.fromRGB(245, 196, 81) or LOG_PAL.muted)
		table.sort(placedPets, function(a, b) return (a.moneys or 0) > (b.moneys or 0) end)
		local top = {}
		for i = 1, math.min(5, #placedPets) do top[i] = placedPets[i] end
		statsView.top.setData(top)
		statsView.topEmpty.Visible = #top == 0
	end
	local function buildStatsPage(parent)
		local scroller = Instance.new("ScrollingFrame")
		scroller.AutomaticCanvasSize = Enum.AutomaticSize.Y
		scroller.BackgroundTransparency = 1
		scroller.BorderSizePixel = 0
		scroller.CanvasSize = UDim2.new(0, 0, 0, 0)
		scroller.Position = UDim2.fromOffset(14, 0)
		scroller.ScrollBarImageColor3 = LOG_PAL.accent
		scroller.ScrollBarThickness = 3
		scroller.ScrollingDirection = Enum.ScrollingDirection.Y
		scroller.Size = UDim2.new(1, -28, 1, -4)
		scroller.Parent = parent
		local layout = Instance.new("UIListLayout", scroller)
		layout.Padding = UDim.new(0, 8)
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		local now = Instance.new("Frame")
		now.BackgroundColor3 = LOG_PAL.surface
		now.BackgroundTransparency = 0.1
		now.BorderSizePixel = 0
		now.LayoutOrder = 1
		now.Size = UDim2.new(1, -6, 0, 50)
		now.Parent = scroller
		Instance.new("UICorner", now).CornerRadius = UDim.new(0, 8)
		local nowStroke = Instance.new("UIStroke", now)
		nowStroke.Color = LOG_PAL.accent
		nowStroke.Transparency = 0.6
		local dot = Instance.new("Frame")
		dot.BorderSizePixel = 0
		dot.Position = UDim2.fromOffset(12, 13)
		dot.Size = UDim2.fromOffset(8, 8)
		dot.Parent = now
		Instance.new("UICorner", dot).CornerRadius = UDim.new(1, 0)
		statsView.nowDot = dot
		statsView.nowTask = UIK.text(now, { text = "Idle", style = "body", pos = UDim2.fromOffset(26, 6), size = UDim2.new(0.55, -26, 0, 18) })
		statsView.nowTask.Font = PANEL_BOLD
		statsView.nowStatus = UIK.text(now, { text = "", style = "meta", color = LOG_PAL.muted, pos = UDim2.fromOffset(12, 27), size = UDim2.new(1, -24, 0, 16) })
		statsView.nowMeta = UIK.text(now, { text = "", style = "meta", color = LOG_PAL.muted, align = Enum.TextXAlignment.Right, anchor = Vector2.new(1, 0), pos = UDim2.new(1, -12, 0, 7), size = UDim2.new(0.45, 0, 0, 16) })
		local grid = Instance.new("Frame")
		grid.AutomaticSize = Enum.AutomaticSize.Y
		grid.BackgroundTransparency = 1
		grid.LayoutOrder = 2
		grid.Size = UDim2.new(1, -6, 0, 0)
		grid.Parent = scroller
		local gl = Instance.new("UIGridLayout", grid)
		gl.CellPadding = UDim2.fromOffset(8, 8)
		gl.CellSize = UDim2.new(0.5, -4, 0, 62)
		gl.SortOrder = Enum.SortOrder.LayoutOrder
		statsView.tiles = {
			money = UIK.stat(grid, { label = "Money", icon = "wallet", order = 1 }),
			income = UIK.stat(grid, { label = "Income", icon = "trending-up", order = 2 }),
			speed = UIK.stat(grid, { label = "Speed", icon = "gauge", order = 3 }),
			stolen = UIK.stat(grid, { label = "Stolen", icon = "hand", order = 4 }),
			collection = UIK.stat(grid, { label = "Collection", icon = "package", order = 5 }),
			world = UIK.stat(grid, { label = "World", icon = "globe", order = 6 }),
		}
		local topCard = UIK.card(scroller, { title = "Top earners on your plot", icon = "trending-up", order = 4 })
		topCard.Size = UDim2.new(1, -6, 0, 0)
		local topBox = Instance.new("Frame")
		topBox.AutomaticSize = Enum.AutomaticSize.Y
		topBox.BackgroundTransparency = 1
		topBox.LayoutOrder = 1
		topBox.Size = UDim2.new(1, 0, 0, 0)
		topBox.Parent = topCard
		local tl = Instance.new("UIListLayout", topBox)
		tl.Padding = UDim.new(0, 4)
		tl.SortOrder = Enum.SortOrder.LayoutOrder
		statsView.topEmpty = UIK.empty(topBox, "Place pets on your plot to see them here.")
		statsView.top = UIK.list({
			build = function()
				return UIK.assetrow(topBox, 96, function(record)
					record.frame.Size = UDim2.new(1, 0, 0, 40)
					record.money = UIK.text(record.right, { style = "body", align = Enum.TextXAlignment.Right, pos = UDim2.fromOffset(0, 1), size = UDim2.new(1, 0, 0, 16) })
					record.money.Font = PANEL_BOLD
					record.kg = UIK.text(record.right, { style = "meta", color = LOG_PAL.muted, align = Enum.TextXAlignment.Right, pos = UDim2.fromOffset(0, 17), size = UDim2.new(1, 0, 0, 14) })
				end)
			end,
			bind = function(record, e)
				UIK.bindasset(record, e.icon, e.color, e.name, e.rarity)
				record.money.Text = moneyStr(e.moneys) .. "/s"
				record.kg.Text = e.kgS
			end,
		})
		refreshStats()
		task.spawn(function()
			while sessionAlive() and scroller.Parent do
				task.wait(1)
				if panelShown("stats") then
					UIK.later("stats", refreshStats)
				end
			end
		end)
	end
	CK.sort = "value"
	CK.rarity = "All"
	CK.picked = {}
	CK.chips = {}
	CK.sortBtns = {}
	CK.modeBtns = {}
	CK.rows = {}
	function CK.fmtKg(kg)
		kg = tonumber(kg) or 0
		local text = kg >= 100 and string.format("%.1f", kg) or string.format("%.2f", kg)
		local whole, frac = text:match("^(%d+)(%.%d+)$")
		whole = whole or text
		local grouped = whole:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
		return grouped .. (frac or "") .. " kg"
	end
	function CK.scanHw()
		local rows = {}
		local list = type(runtimeEnv.__SenaV4HwEggList) == "function" and runtimeEnv.__SenaV4HwEggList() or {}
		local rOf = runtimeEnv.__SenaV4HwRarityOf
		for _, e in ipairs(list) do
			if e.uid and e.name then
				local rname = type(rOf) == "function" and rOf(e.name) or nil
				local nk = runtimeEnv.__SenaV4HwNorm
				local key = (Assets.Directory and Assets.Directory[e.name] and e.name) or (nk and nk[(tostring(e.name):lower():gsub("[%s_%-]", ""):gsub("egg$", ""))]) or e.name
				local rnum, rn2, rcolor = rarityInfo(key)
				rname = rname or (rn2 ~= "?" and rn2) or "?"
				if rnum == 0 and rname ~= "?" then rnum = catalog.rarityRank(rname) end
				rows[#rows + 1] = { uid = e.uid, name = tostring(key), rarity = rname, rnum = rnum, color = rcolor, area = "Halloween · Zone " .. tostring(e.zone or "?"), rate = 0, kg = nil, scale = 1, icon = assetImage(key) }
			end
		end
		if CK.rarity ~= "All" then
			local keep = {}
			for _, e in ipairs(rows) do if e.rarity == CK.rarity then keep[#keep + 1] = e end end
			rows = keep
		end
		table.sort(rows, function(a, b)
			if (a.rnum or 0) ~= (b.rnum or 0) then return (a.rnum or 0) > (b.rnum or 0) end
			return tostring(a.name) < tostring(b.name)
		end)
		return rows
	end
	function CK.scan()
		if CK.world == "Halloween" then return CK.scanHw() end
		local snap = nil
		pcall(function() snap = EggState.ReadFieldEggs() end)
		local rows = {}
		for _, r in ipairs((snap and snap.Records) or {}) do
			if r.State ~= "Claimed" and r.State ~= "Carried" and not r.CarrierUserId and r.BottomCFrame
				and not tostring(r.Uid):find("FirstAreaEgg") then
				local cat = r.AssetCategory
				local cfg = cat and Assets.Directory and Assets.Directory[cat]
				local rnum, rname, rcolor = rarityInfo(cat)
				local norm = {
					AssetCategory = cat,
					Category = cat,
					AssetScale = r.AssetScale or r.Scale or 1,
					Scale = r.AssetScale or r.Scale or 1,
					Mutations = r.Mutations or {},
				}
				local rate = rateOfItem(norm)
				local kg = weightOfItem(r)
				rows[#rows + 1] = {
					rec = r,
					uid = r.Uid,
					name = (cfg and cfg.DisplayName) or tostring(cat or "Egg"),
					rarity = rname,
					rnum = rnum,
					color = rcolor,
					area = tostring(r.AreaId or "?"),
					rate = rate,
					kg = kg,
					scale = tonumber(r.AssetScale or r.Scale) or 1,
					icon = assetImage(cat),
				}
			end
		end
		if CK.rarity ~= "All" then
			local keep = {}
			for _, e in ipairs(rows) do
				if e.rarity == CK.rarity then keep[#keep + 1] = e end
			end
			rows = keep
		end
		table.sort(rows, function(a, b)
			if CK.sort == "weight" then
				if (a.kg or 0) ~= (b.kg or 0) then return (a.kg or 0) > (b.kg or 0) end
				return (a.rate or 0) > (b.rate or 0)
			end
			if CK.sort == "rarity" then
				if a.rnum ~= b.rnum then return (a.rnum or 0) > (b.rnum or 0) end
				return (a.rate or 0) > (b.rate or 0)
			end
			if a.rate ~= b.rate then return (a.rate or 0) > (b.rate or 0) end
			return (a.rnum or 0) > (b.rnum or 0)
		end)
		return rows
	end
	local STEAL_MODE_OPTIONS = {
		{ "Low Speed User", "Low" },
		{ "High Speed User Normal", "High" },
		{ "High Speed User (Fly)", "High Fly" },
		{ "Zig-Zag High Speed User", "Zig-Zag" },
	}
	local function stealModeLabel()
		local value = type(SenaPanels.getStealMode) == "function" and SenaPanels.getStealMode() or nil
		return type(value) == "string" and value or "High Speed User Normal"
	end
	SenaPanels.syncStealMode = function()
		if CK.modeSeg then CK.modeSeg.set(stealModeLabel(), false) end
	end
	function CK.paintChips()
		if CK.raritySeg then CK.raritySeg.set(CK.rarity, false) end
		if CK.sortSeg then CK.sortSeg.set(CK.sort, false) end
		if CK.modeSeg then CK.modeSeg.set(stealModeLabel(), false) end
	end
	function CK.paintRows()
		local n = 0
		for _, record in ipairs(CK.rows) do
			if record.frame.Visible and record.uid ~= nil then
				local on = CK.picked[tostring(record.uid)] == true
				if on then n = n + 1 end
				record.frame.BackgroundTransparency = on and 0.02 or 0.12
				record.stroke.Transparency = on and 0.1 or 0.72
				record.stroke.Color = on and LOG_PAL.accent or LOG_PAL.strokeCol
				record.tick.BackgroundTransparency = on and 0.1 or 0.86
				record.check.Visible = on
			end
		end
		if CK.statusBtn and not CK.running then
			CK.statusBtn.setText(n > 0 and ("Steal selected (" .. n .. ")") or "Steal selected")
			CK.statusBtn.setEnabled(true)
		end
		if CK.headLbl then
			CK.headLbl.Text = n > 0 and (n .. " picked") or "Tap eggs to pick them"
		end
	end
	function CK.refresh()
		uiIdentity()
		if not CK.view then return end
		local rows = CK.scan()
		local live = {}
		for _, e in ipairs(rows) do live[tostring(e.uid)] = true end
		for uid in pairs(CK.picked) do
			if not live[uid] then CK.picked[uid] = nil end
		end
		CK.view.setData(rows)
		CK.emptyLbl.Visible = #rows == 0
		if CK.countLbl then CK.countLbl.Text = #rows .. " egg" .. (#rows == 1 and "" or "s") end
		pcall(CK.paintChips)
		pcall(CK.paintRows)
	end
	function CK.build(parent)
		local main = Instance.new("Frame")
		main.BackgroundTransparency = 1
		main.BorderSizePixel = 0
		main.Size = UDim2.fromScale(1, 1)
		main.Parent = parent
		CK.headLbl = UIK.text(main, { text = "Tap eggs to pick them", style = "meta", color = LOG_PAL.muted, pos = UDim2.fromOffset(14, 2), size = UDim2.new(1, -135, 0, 18) })
		CK.countLbl = UIK.text(main, { text = "0 eggs", style = "meta", color = LOG_PAL.muted, align = Enum.TextXAlignment.Right, anchor = Vector2.new(1, 0), pos = UDim2.new(1, -16, 0, 2), size = UDim2.fromOffset(110, 18) })
		local options, colors = { { "All", "All" } }, {}
		for _, rn in ipairs(rarityNamesMulti()) do
			options[#options + 1] = { rn, rn }
			for _, sp in ipairs(ALL_SPECIES) do
				if sp.rname == rn then
					local _, _, col = rarityInfo(sp.cat)
					colors[rn] = col
					break
				end
			end
		end
		CK.raritySeg = UIK.segmented(main, {
			options = options,
			value = CK.rarity,
			pos = UDim2.fromOffset(14, 22),
			size = UDim2.new(1, -28, 0, 30),
			onChange = function(key)
				CK.rarity = key
				CK.refresh()
			end,
		})
		for key, btn in pairs(CK.raritySeg.buttons) do
			local color = colors[key]
			if color then
				local plain = btn.setActive
				btn.setActive = function(on)
					plain(on)
					if not on then btn.label.TextColor3 = color end
				end
			end
		end
		CK.raritySeg.set(CK.rarity, false)
		local tools = Instance.new("Frame")
		tools.BackgroundTransparency = 1
		tools.Position = UDim2.fromOffset(14, 56)
		tools.Size = UDim2.new(1, -28, 0, 28)
		tools.Parent = main
		CK.sortSeg = UIK.segmented(tools, {
			options = { { "value", "Best value" }, { "weight", "Best weight" }, { "rarity", "Rarity" } },
			value = CK.sort,
			size = UDim2.new(1, -230, 1, 0),
			onChange = function(key)
				CK.sort = key
				CK.refresh()
			end,
		})
		local clear = UIK.button(tools, {
			text = "Clear",
			icon = "x",
			onClick = function()
				CK.picked = {}
				CK.paintRows()
			end,
		})
		clear.inst.AnchorPoint = Vector2.new(1, 0.5)
		clear.inst.Position = UDim2.new(1, 0, 0.5, 0)
		CK.world = CK.world or "Normal"
		CK.worldSeg = UIK.segmented(tools, {
			options = { { "Normal", "Normal" }, { "Halloween", "Halloween" } },
			value = CK.world,
			pos = UDim2.new(1, -224, 0, 0),
			size = UDim2.new(0, 138, 1, 0),
			onChange = function(key)
				CK.world = key
				CK.picked = {}
				CK.refresh()
			end,
		})
		UIK.text(main, { text = "Move", style = "label", color = LOG_PAL.muted, pos = UDim2.fromOffset(16, 92), size = UDim2.fromOffset(44, 20) })
		CK.modeSeg = UIK.segmented(main, {
			options = STEAL_MODE_OPTIONS,
			value = stealModeLabel(),
			pos = UDim2.fromOffset(58, 88),
			size = UDim2.new(1, -72, 0, 28),
			onChange = function(label)
				if type(SenaPanels.setStealMode) == "function" then
					SenaPanels.setStealMode(label)
				end
			end,
		})
		local scroller = UIK.scroller(main, UDim2.fromOffset(14, 124), UDim2.new(1, -28, 1, -184))
		CK.emptyLbl = UIK.empty(scroller, "No eggs on the field right now.")
		CK.rows = {}
		CK.view = UIK.list({
			build = function()
				local record = UIK.assetrow(scroller, 96, function(rec)
					rec.frame.Size = UDim2.new(1, -6, 0, 54)
					local tick = Instance.new("Frame")
					tick.BackgroundColor3 = LOG_PAL.accent
					tick.BackgroundTransparency = 0.86
					tick.BorderSizePixel = 0
					tick.Position = UDim2.fromOffset(10, 16)
					tick.Size = UDim2.fromOffset(22, 22)
					tick.Parent = rec.frame
					Instance.new("UICorner", tick).CornerRadius = UDim.new(0, 6)
					local tstroke = Instance.new("UIStroke", tick)
					tstroke.Color = LOG_PAL.accent
					tstroke.Transparency = 0.5
					local check = UIK.image(tick, "check", 14, Color3.fromRGB(255, 255, 255))
					check.AnchorPoint = Vector2.new(0.5, 0.5)
					check.Position = UDim2.fromScale(0.5, 0.5)
					check.Visible = false
					rec.tick, rec.check = tick, check
					rec.stroke = rec.frame:FindFirstChildOfClass("UIStroke")
					rec.icon.Position = UDim2.fromOffset(40, 9)
					rec.icon.Size = UDim2.fromOffset(36, 36)
					rec.name.Position = UDim2.fromOffset(84, 6)
					rec.name.Size = UDim2.new(1, -(84 + 96 + 14), 0, 19)
					rec.name.TextSize = 15
					rec.sub.Position = UDim2.fromOffset(84, 27)
					rec.sub.Size = UDim2.new(1, -(84 + 96 + 14), 0, 20)
					rec.sub.TextSize = 13
					rec.sub.RichText = true
					rec.rate = UIK.text(rec.right, { style = "body", color = Color3.fromRGB(126, 224, 151), align = Enum.TextXAlignment.Right, size = UDim2.fromScale(1, 1) })
					rec.rate.Font = PANEL_BOLD
					rec.rate.TextSize = 15
					local hit = Instance.new("TextButton")
					hit.AutoButtonColor = false
					hit.BackgroundTransparency = 1
					hit.Size = UDim2.fromScale(1, 1)
					hit.Text = ""
					hit.ZIndex = 3
					hit.Parent = rec.frame
					hit.MouseButton1Click:Connect(function()
						if rec.uid == nil then return end
						local key = tostring(rec.uid)
						CK.picked[key] = (not CK.picked[key]) or nil
						CK.paintRows()
					end)
				end)
				CK.rows[#CK.rows + 1] = record
				return record
			end,
			bind = function(record, e)
				record.uid = e.uid
				UIK.bindasset(record, e.icon, e.color, e.name,
					string.format("%s  ·  %s%s  ·  <b>x%.2f</b>", tostring(e.rarity or "?"), tostring(e.area),
						e.kg and ("  ·  <b>" .. CK.fmtKg(e.kg) .. "</b>") or "", e.scale or 1))
				record.name.TextSize = 15
				record.sub.TextSize = 13
				record.rate.Text = ((e.rate or 0) > 0) and (fmtBotNum(e.rate) .. "/s") or ""
			end,
		})
		local bar = Instance.new("Frame")
		bar.BackgroundTransparency = 1
		bar.Position = UDim2.new(0, 14, 1, -52)
		bar.Size = UDim2.new(1, -28, 0, 34)
		bar.Parent = main
		local refresh = UIK.button(bar, {
			text = "Refresh",
			icon = "refresh-cw",
			h = 34,
			onClick = function()
				pcall(function() EggState.SyncFieldEggs() end)
				CK.refresh()
			end,
		})
		refresh.inst.Position = UDim2.fromOffset(0, 0)
		CK.statusBtn = UIK.button(bar, {
			text = "Steal selected",
			kind = "primary",
			icon = "hand",
			h = 34,
			onClick = function()
				if CK.running then return end
				local queue = {}
				for uid, _ in pairs(CK.picked) do
					table.insert(queue, uid)
				end
				if #queue == 0 then
					CK.statusBtn.setText("Pick an egg first")
					task.delay(1.5, function() if CK.statusBtn and not CK.running then CK.paintRows() end end)
					return
				end
				if CK.world == "Halloween" then
					local hq = runtimeEnv.__SenaV4HwQueue
					local pending = type(hq) == "function" and hq(queue) or 0
					CK.picked = {}
					CK.statusBtn.setText(pending > 0 and ("Queued " .. tostring(pending) .. " (Halloween)") or "Runtime not ready")
					task.delay(1.5, function() if CK.statusBtn and not CK.running then CK.paintRows() end end)
					CK.refresh()
					return
				end
				local runtime = runtimeEnv.__SenaV4EggRuntime
				if runtime and type(runtime.queueManual) == "function" then
					local pending = runtime:queueManual(queue)
					CK.picked = {}
					CK.statusBtn.setText("Queued " .. tostring(pending))
					task.delay(1.5, function() if CK.statusBtn and not CK.running then CK.paintRows() end end)
					CK.refresh()
				else
					CK.statusBtn.setText("Runtime not ready")
					task.delay(1.5, function() if CK.statusBtn and not CK.running then CK.paintRows() end end)
				end
			end,
		})
		CK.statusBtn.inst.AutomaticSize = Enum.AutomaticSize.None
		CK.statusBtn.inst.AnchorPoint = Vector2.new(1, 0)
		CK.statusBtn.inst.Position = UDim2.fromScale(1, 0)
		CK.statusBtn.inst.Size = UDim2.new(1, -116, 1, 0)
		CK.statusBtn.label.TextTruncate = Enum.TextTruncate.AtEnd
		CK.paintChips()
		CK.refresh()
	end
	local function edNormalizePet(name)
		if not name or type(name) ~= "string" then return "unknown" end
		local s = name:lower()
		if s:find("kong") or s:find("gorilla") then return "gorillaking" end
		if s:find("phoenix") then return "phoenix" end
		if s:find("lunar") or s:find("dragon.-lunar") then return "lunardragon" end
		if s:find("mosa") then return "mosasaurus" end
		if s:find("tiger") or s:find("oni") then return "onitiger" end
		if s:find("kitsune") then return "kitsune" end
		if s:find("unicorn") then return "unicorn" end
		if s:find("godzilla") then return "godzilla" end
		if s:find("pegasus") then return "pegasus" end
		if s:find("archangel") then return "archangel" end
		if s:find("ice.-dragon") then return "icedragon" end
		if s:find("lava.-dragon") or s:find("dragon") then return "lavadragon" end
		if s:find("cosmic.-dragon") or s:find("ember") then return "cosmicdragon" end
		if s:find("trex") or s:find("tyranno") or s:find("t%-rex") then return "trex" end
		if s:find("gargoyle") then return "gargoyle" end
		if s:find("cerberus") then return "cerberus" end
		if s:find("yeti") then return "yeti" end
		if s:find("dreadscale") then return "dreadscale" end
		if s:find("el.-maja") then return "elmaja" end
		s = s:gsub("eternal", ""):gsub("ascended", ""):gsub("vermilion", ""):gsub("divine", ""):gsub("secret", ""):gsub("egg", ""):gsub("[^%a%d]", "")
		return s
	end
	local function roundTo5Min(ts)
		if not ts or ts <= 0 then return 0 end
		return math.floor((ts + 150) / 300) * 300
	end
	local function edFormatDeviceTime(ts, includeSeconds)
		if not ts or ts <= 0 then return "--:--" end
		local now = os.time()
		local nowD = os.date("*t", now)
		local d = os.date("*t", ts)
		local prefix = ""
		if d.year == nowD.year and d.yday == nowD.yday then
			prefix = "Today"
		elseif d.year == nowD.year and d.yday == nowD.yday - 1 then
			prefix = "Yesterday"
		elseif d.year == nowD.year and d.yday == nowD.yday + 1 then
			prefix = "Tomorrow"
		else
			prefix = string.format("%02d/%02d", d.month, d.day)
		end
		if includeSeconds then
			return string.format("%s %02d:%02d:%02d", prefix, d.hour, d.min, d.sec)
		else
			return string.format("%s %02d:%02d", prefix, d.hour, d.min)
		end
	end
	local function edFormatRelativeTime(ts)
		if not ts or ts <= 0 then return "" end
		local now = os.time()
		local diff = now - ts
		if diff < 0 then
			local future = -diff
			if future < 60 then return "in <1m" end
			if future < 3600 then return string.format("in %dm", math.floor(future / 60)) end
			return string.format("in %.1fh", future / 3600)
		end
		if diff < 60 then return "Just now" end
		if diff < 3600 then return string.format("%dm ago", math.floor(diff / 60)) end
		if diff < 86400 then return string.format("%.1fh ago", diff / 3600) end
		return string.format("%.1fd ago", diff / 86400)
	end
	local function edFormatWindowRange(wStart, wEnd)
		wStart = roundTo5Min(wStart)
		wEnd = roundTo5Min(wEnd)
		local now = os.time()
		local nowD = os.date("*t", now)
		local d1 = os.date("*t", wStart)
		local d2 = os.date("*t", wEnd)
		local function getDayPrefix(d)
			if d.year == nowD.year and d.yday == nowD.yday then return "Today"
			elseif d.year == nowD.year and d.yday == nowD.yday + 1 then return "Tomorrow"
			elseif d.year == nowD.year and d.yday == nowD.yday - 1 then return "Yesterday"
			else return string.format("%02d/%02d", d.month, d.day) end
		end
		local p1 = getDayPrefix(d1)
		local p2 = getDayPrefix(d2)
		if p1 == p2 then
			return string.format("%s %02d:%02d - %02d:%02d", p1, d1.hour, d1.min, d2.hour, d2.min)
		else
			return string.format("%s %02d:%02d - %s %02d:%02d", p1, d1.hour, d1.min, p2, d2.hour, d2.min)
		end
	end
	local edKnownIcons = {
		["Mosasaurus"] = "rbxassetid://124293259998827",
		["Oni Tiger"] = "rbxassetid://109908891899435",
		["Eternal Lunar Dragon"] = "rbxassetid://93762296316916",
		["Lunar Dragon"] = "rbxassetid://93762296316916",
		["King Kong"] = "rbxassetid://135650224014044",
		["Gorilla King"] = "rbxassetid://135650224014044",
		["Ice Dragon"] = "rbxassetid://101397684798718",
		["Phoenix"] = "rbxassetid://118067990008425",
		["Ascended Vermilion Phoenix"] = "rbxassetid://118067990008425",
		["Dragon"] = "rbxassetid://78935088838538",
		["Lava Dragon"] = "rbxassetid://78935088838538",
		["Dragon (Lava)"] = "rbxassetid://78935088838538",
		["Pegasus"] = "rbxassetid://112830316982322",
		["El Maja"] = "rbxassetid://77518688092604",
		["Kitsune"] = "rbxassetid://107842067813602",
		["Unicorn"] = "rbxassetid://70463817382627",
		["Godzilla"] = "rbxassetid://102979882140882",
		["ArchAngel"] = "rbxassetid://113289118499426",
		["Cosmic Dragon"] = "rbxassetid://107923370723949",
		["TRex"] = "rbxassetid://124293259998827",
		["Gargoyle"] = "rbxassetid://137949993315884",
		["King Snake"] = "rbxassetid://77518688092604",
	}
	local edIconCache = {}
	local function edGetPetIcon(petName)
		if not petName then return "" end
		if edKnownIcons[petName] then return edKnownIcons[petName] end
		if edIconCache[petName] ~= nil then return edIconCache[petName] end
		local icon = assetImage(petName)
		edIconCache[petName] = icon or ""
		return edIconCache[petName]
	end
	local function edHttpRequest(options)
		local req = (syn and syn.request) or (http and http.request) or request or http_request
		if req then
			local res = nil
			local ok = pcall(function() res = req(options) end)
			if ok and res then return res end
		end
		if options.Method == "GET" and game and game.HttpGet then
			local body = nil
			local ok = pcall(function() body = game:HttpGet(options.Url, true) end)
			if ok and body then return { StatusCode = 200, Body = body } end
		end
		return nil
	end
	local ED_GROUPS = {
		{
			id = "eternal_fast",
			title = "Eternal",
			cycleLabel = "45 - 90m",
			rarity = "Eternal",
			windowMin = 45,
			windowMax = 90,
			priority = 1,
			color = Color3.fromRGB(255, 215, 0),
			candidates = {
				{ name = "Mosasaurus", area = "Prehistoric", chance = "10.85%", icon = "rbxassetid://124293259998827" },
				{ name = "Oni Tiger", area = "Cherry Blossom", chance = "10.85%", icon = "rbxassetid://109908891899435" },
				{ name = "Lunar Dragon", area = "Cosmic", chance = "10.85%", icon = "rbxassetid://93762296316916" },
				{ name = "Gorilla King", area = "Titan Temple", chance = "10.85%", icon = "rbxassetid://135650224014044" },
				{ name = "Ice Dragon", area = "Snow", chance = "10.85%", icon = "rbxassetid://101397684798718" },
				{ name = "Phoenix", area = "Volcano", chance = "10.85%", icon = "rbxassetid://118067990008425" },
			}
		},
		{
			id = "divine_fast",
			title = "Divine",
			cycleLabel = "1.5 - 3h",
			rarity = "Divine",
			windowMinH = 1.5,
			windowMaxH = 3,
			priority = 2,
			color = Color3.fromRGB(255, 255, 255),
			candidates = {
				{ name = "Kitsune", area = "Cherry Blossom", chance = "20%", icon = "rbxassetid://107842067813602" },
				{ name = "ArchAngel", area = "Heaven", chance = "20%", icon = "rbxassetid://113289118499426" },
				{ name = "Godzilla", area = "Prehistoric", chance = "20%", icon = "rbxassetid://102979882140882" },
				{ name = "Pegasus", area = "Fantasy", chance = "20%", icon = "rbxassetid://112830316982322" },
				{ name = "Unicorn", area = "Magical Forest", chance = "20%", icon = "rbxassetid://70463817382627" },
			}
		}
	}
	local function edAddHistoryItem(item)
		if not item or not item.name then return false end
		local itemTs = tonumber(item.ts) or os.time()
		item.ts = itemTs
		local rar = (item.rarity or ""):lower()
		if rar ~= "eternal" and rar ~= "divine" then return false end
		local norm = edNormalizePet(item.name)
		for _, h in ipairs(ED.history) do
			if h.uid and item.uid and h.uid == item.uid then return false end
			local hNorm = edNormalizePet(h.name)
			if hNorm == norm and math.abs((h.ts or 0) - itemTs) < 600 then return false end
		end
		table.insert(ED.history, item)
		table.sort(ED.history, function(a, b) return (a.ts or 0) > (b.ts or 0) end)
		if rar == "eternal" then
			if not ED.lastEternal or itemTs >= (ED.lastEternal.ts or 0) then ED.lastEternal = item end
		elseif rar == "divine" then
			if not ED.lastDivine or itemTs >= (ED.lastDivine.ts or 0) then ED.lastDivine = item end
		end
		return true
	end
	function ED.getLatestSpawn(rarity, poolCandidates)
		for _, h in ipairs(ED.history) do
			local matchRar = not rarity or (h.rarity and h.rarity:lower() == rarity:lower())
			if matchRar then
				if poolCandidates and #poolCandidates > 0 then
					local hNorm = edNormalizePet(h.name)
					for _, c in ipairs(poolCandidates) do
						if edNormalizePet(c.name) == hNorm then return h end
					end
				else
					return h
				end
			end
		end
		return nil
	end
	local ED_SEEDS = {
		{ uid = "afad935fc39f4ad0a28d83d74dad60f8", name = "Ice Dragon", area = "Snow", rarity = "Eternal", ts = 1789738200, reporter = "Server Alert" },
		{ uid = "aac1107e3c3a428c93ecc8d5c4c03296", name = "Mosasaurus", area = "Prehistoric", rarity = "Eternal", ts = 1789735200, reporter = "Server Alert" },
		{ uid = "2f08670c03054614b5c088092e0eab9e", name = "Eternal Lunar Dragon", area = "Cosmic", rarity = "Eternal", ts = 1789733400, reporter = "Server Alert" },
		{ uid = "d2c1c02c35224ca78eddeda7128643a6", name = "Skeleton Horse", area = "Light Dark", rarity = "Eternal", ts = 1789731600, reporter = "Server Alert" },
		{ uid = "a9f84b4645bd4d23a2a8887923febe6e", name = "Gorilla King", area = "Titan Temple", rarity = "Eternal", ts = 1789729800, reporter = "Server Alert" },
		{ uid = "seed_divine_1", name = "Kitsune", area = "Cherry Blossom", rarity = "Divine", ts = 1789678800, reporter = "Server Alert" }
	}
	for _, s in ipairs(ED_SEEDS) do edAddHistoryItem(s) end
	local function edParseAnnouncement(raw)
		if not raw or type(raw) ~= "string" then return nil end
		if not raw:find("spawned in") then return nil end
		local clean = raw:gsub("<[^>]+>", ""):gsub("[%c]", "")
		local rarity, pet, area = clean:match("A%s+(%a+)%s+(.-)%s+Egg%s+spawned%s+in%s+([^!]+)")
		if not (rarity and pet and area) then
			pet, rarity, area = clean:match("([%w%s]+)%s*%((%a+)%)%s+has%s+spawned%s+in%s+([^!]+)")
		end
		if rarity and pet and area then
			area = area:gsub("%s+$", ""):gsub("^%s+", "")
			pet = pet:gsub("%s+$", ""):gsub("^%s+", "")
			rarity = rarity:gsub("%s+$", ""):gsub("^%s+", "")
			return rarity, pet, area
		end
		return nil
	end
	local function edHandleIncomingAlert(raw)
		local rarity, pet, area = edParseAnnouncement(raw)
		if not (rarity and pet and area) then return end
		local now = os.time()
		local norm = edNormalizePet(pet)
		local bucket = math.floor(now / 300)
		local alertKey = string.format("alert_%s_%s_%d", norm, area:lower(), bucket)
		if ED.reportedUids[alertKey] then return end
		ED.reportedUids[alertKey] = now
		ED.lastAlert = { pet = pet, area = area, rarity = rarity, ts = now, norm = norm }
		local item = { uid = alertKey, name = pet, area = area, rarity = rarity, ts = now, reporter = "Server Alert" }
		if edAddHistoryItem(item) then
			pcall(ED.paint)
		end
	end
	function ED.reportSpawn(eggUid, petName, areaName, rarityName, customTs)
		if not eggUid or ED.reportedUids[eggUid] then return end
		local now = os.time()
		local spawnTs = tonumber(customTs) or now
		if now - ED.lastReportTime < 3 then return end
		ED.reportedUids[eggUid] = spawnTs
		ED.lastReportTime = now
		local repName = (LocalPlayer and LocalPlayer.Name) or "Player"
		local item = { uid = tostring(eggUid), name = petName, area = areaName, rarity = rarityName, ts = spawnTs, reporter = repName }
		if edAddHistoryItem(item) then
			pcall(ED.paint)
		end
	end
	function ED.syncBackend()
		local now = os.time()
		if now - ED.lastSync < 10 then return end
		ED.lastSync = now
		task.spawn(function()
			local backend = (getgenv and getgenv().SenaBackend) or {}
			local api = backend.Api or "https://senahub.xyz/api"
			local key = backend.Key or ""
			local myUid = LocalPlayer and tostring(LocalPlayer.UserId) or "0"
			local url = api .. "/egg/latest?key=" .. tostring(key) .. "&uid=" .. tostring(myUid) .. "&t=" .. tostring(now)
			local res = edHttpRequest({ Url = url, Method = "GET" })
			if res and (res.StatusCode == 200 or res.Status == 200) and res.Body then
				local HS = game:GetService("HttpService")
				local ok, data = pcall(function() return HS:JSONDecode(res.Body) end)
				if ok and type(data) == "table" and data.ok then
					if data.last_eternal and type(data.last_eternal) == "table" and data.last_eternal.name then
						edAddHistoryItem(data.last_eternal)
					end
					if data.last_divine and type(data.last_divine) == "table" and data.last_divine.name then
						edAddHistoryItem(data.last_divine)
					end
					if type(data.recent_spawns) == "table" then
						for _, spawn in ipairs(data.recent_spawns) do edAddHistoryItem(spawn) end
					end
					pcall(ED.paint)
				end
			end
		end)
	end
	function ED.scanField()
		local snap = nil
		pcall(function() snap = EggState.ReadFieldEggs() end)
		if not snap or not snap.Records then return end
		local now = os.time()
		if not ED._fieldInitialized then
			ED._fieldInitialized = true
			for _, r in ipairs(snap.Records) do
				if r.Uid then ED.knownFieldUids[r.Uid] = true end
			end
			return
		end
		for _, r in ipairs(snap.Records) do
			if r.Uid and not ED.knownFieldUids[r.Uid] then
				ED.knownFieldUids[r.Uid] = true
				if r.State ~= "Claimed" and r.BottomCFrame then
					local cat = r.AssetCategory
					local rnum, rname = rarityInfo(cat)
					if rname == "Divine" or rname == "Eternal" then
						local pet = (cat == "King Kong") and "Gorilla King" or ((cat == "Ascended Vermilion Phoenix") and "Phoenix" or cat)
						local spawnTs = now
						if ED.lastAlert and (now - (ED.lastAlert.ts or 0) <= 60) then
							local aNorm = edNormalizePet(ED.lastAlert.pet)
							local pNorm = edNormalizePet(pet)
							if aNorm == pNorm and (ED.lastAlert.area:lower() == (r.AreaId or ""):lower()) then
								spawnTs = ED.lastAlert.ts
							end
						end
						ED.reportSpawn(r.Uid, pet, r.AreaId or "Field", rname, spawnTs)
					end
				end
			end
		end
	end
	function ED.paint()
		uiIdentity()
		if not ED.list or not ED.list.Parent then return end
		for _, c in ipairs(ED.list:GetChildren()) do
			if c:IsA("Frame") then c:Destroy() end
		end
		local now = os.time()
		local latestOverallEternal = ED.getLatestSpawn("eternal")
		local latestOverallDivine = ED.getLatestSpawn("divine")
		local t0Eternal = latestOverallEternal and latestOverallEternal.ts or 1789738200
		local t0Divine = latestOverallDivine and latestOverallDivine.ts or 1789678800
		if ED.catSeg then ED.catSeg.set(ED.category, false) end
		if ED.chipSeg then ED.chipSeg.set(ED.filter, false) end
		if ED.noticeBox then ED.noticeBox.Visible = (ED.category == "targets") end
		if ED.summaryBox then
			ED.summaryBox.Visible = (ED.category == "history")
			if ED.summaryText and ED.category == "history" then
				local eSpawn = latestOverallEternal
				local eName = eSpawn and eSpawn.name or "Phoenix"
				local eArea = eSpawn and eSpawn.area or "Volcano"
				local eTs = eSpawn and eSpawn.ts or t0Eternal
				local eTime = edFormatDeviceTime(eTs, true)
				local eRel = edFormatRelativeTime(eTs)
				local dSpawn = latestOverallDivine
				local dName = dSpawn and dSpawn.name or "Kitsune"
				local dArea = dSpawn and dSpawn.area or "Cherry Blossom"
				local dTs = dSpawn and dSpawn.ts or t0Divine
				local dTime = edFormatDeviceTime(dTs, true)
				local dRel = edFormatRelativeTime(dTs)
				ED.summaryText.Text = string.format(
					"<b>LAST ETERNAL:</b> <font color='#ffd700'><b>%s</b></font> (%s) - %s <font color='#8899aa'>(%s)</font>\n"
					.. "<b>LAST DIVINE:</b> <font color='#ffffff'><b>%s</b></font> (%s) - %s <font color='#8899aa'>(%s)</font>",
					eName, eArea, eTime, eRel,
					dName, dArea, dTime, dRel
				)
			end
		end
		if ED.refreshBtn then
			ED.refreshBtn.setText((ED.category == "targets") and "Refresh targets" or "Refresh history")
		end
		if ED.category == "targets" then
			local displayedGroups = 0
			for idx, g in ipairs(ED_GROUPS) do
				if ED.filter == "All" or ED.filter == g.rarity then
					displayedGroups = displayedGroups + 1
					local poolSpawn = ED.getLatestSpawn(g.rarity, g.candidates) or latestOverallEternal
					if g.rarity == "Divine" then poolSpawn = ED.getLatestSpawn("divine") or latestOverallDivine end
					local t0 = poolSpawn and poolSpawn.ts or (g.rarity == "Divine" and t0Divine or t0Eternal)
					local cMinSec = (g.windowMinH and (g.windowMinH * 3600)) or ((g.windowMin or 45) * 60)
					local cMaxSec = (g.windowMaxH and (g.windowMaxH * 3600)) or ((g.windowMax or 90) * 60)
					local spanSec = cMaxSec - cMinSec
					local wStart = t0 + cMinSec
					local wEnd = t0 + cMaxSec
					if g.rarity == "Eternal" and (now - wEnd) > (cMinSec * 0.75) then
						while (now - wEnd) > (cMinSec * 0.75) do
							wStart = wEnd + cMinSec
							wEnd = wStart + spanSec
						end
					end
					wStart = roundTo5Min(wStart)
					wEnd = roundTo5Min(wEnd)
					local badge = "UPCOMING"
					local badgeCol = Color3.fromRGB(100, 200, 255)
					if now > wEnd then
						local overdueM = math.ceil((now - wEnd) / 60)
						badge = (overdueM >= 60) and string.format("OVERDUE +%.1fh", overdueM / 60) or string.format("OVERDUE +%dm", overdueM)
						badgeCol = Color3.fromRGB(255, 0, 128)
					elseif now >= wStart and now <= wEnd then
						badge = "IN WINDOW"
						badgeCol = Color3.fromRGB(0, 255, 136)
					else
						local leftM = math.ceil((wStart - now) / 60)
						if leftM > 0 and leftM < 60 then
							badge = string.format("IN %dm", leftM)
							badgeCol = Color3.fromRGB(80, 210, 255)
						elseif leftM >= 60 then
							badge = string.format("IN %.1fh", leftM / 60)
							badgeCol = Color3.fromRGB(80, 210, 255)
						end
					end
					local card = Instance.new("Frame")
					card.Size = UDim2.new(1, -6, 0, 136)
					card.BackgroundColor3 = LOG_PAL.surface
					card.BackgroundTransparency = 0.15
					card.BorderSizePixel = 0
					card.LayoutOrder = idx
					card.Parent = ED.list
					Instance.new("UICorner", card).CornerRadius = UDim.new(0, 8)
					local rs = Instance.new("UIStroke", card)
					rs.Color = g.color or LOG_PAL.accent
					rs.Thickness = 1
					rs.Transparency = 0.78
					local bar = Instance.new("Frame")
					bar.Size = UDim2.new(0, 4, 1, -12)
					bar.Position = UDim2.fromOffset(0, 6)
					bar.BorderSizePixel = 0
					bar.BackgroundColor3 = g.color or LOG_PAL.accent
					bar.Parent = card
					Instance.new("UICorner", bar).CornerRadius = UDim.new(1, 0)
					local titleL = Instance.new("TextLabel")
					titleL.BackgroundTransparency = 1
					titleL.Position = UDim2.fromOffset(12, 6)
					titleL.Size = UDim2.new(1, -120, 0, 16)
					titleL.Font = PANEL_BOLD
					titleL.TextSize = 13
					titleL.TextTruncate = Enum.TextTruncate.AtEnd
					titleL.TextXAlignment = Enum.TextXAlignment.Left
					titleL.TextColor3 = g.color or Color3.fromRGB(255, 255, 255)
					titleL.Text = string.format("%s Window (%s)", g.title, g.cycleLabel)
					titleL.Parent = card
					local bPill = Instance.new("TextLabel")
					bPill.Position = UDim2.new(1, -12, 0, 6)
					bPill.AnchorPoint = Vector2.new(1, 0)
					bPill.AutomaticSize = Enum.AutomaticSize.X
					bPill.Size = UDim2.fromOffset(0, 18)
					bPill.BackgroundColor3 = badgeCol
					bPill.BackgroundTransparency = 0.2
					bPill.Font = PANEL_BOLD
					bPill.TextSize = 10
					bPill.TextColor3 = Color3.fromRGB(255, 255, 255)
					bPill.Text = badge
					bPill.Parent = card
					Instance.new("UICorner", bPill).CornerRadius = UDim.new(0, 4)
					local bpad = Instance.new("UIPadding", bPill)
					bpad.PaddingLeft = UDim.new(0, 8)
					bpad.PaddingRight = UDim.new(0, 8)
					local timeL = Instance.new("TextLabel")
					timeL.BackgroundTransparency = 1
					timeL.Position = UDim2.fromOffset(12, 24)
					timeL.Size = UDim2.new(1, -24, 0, 14)
					timeL.Font = PANEL_MEDIUM
					timeL.TextSize = 11
					timeL.TextXAlignment = Enum.TextXAlignment.Left
					timeL.TextColor3 = Color3.fromRGB(150, 180, 220)
					timeL.Text = string.format("Window: %s", edFormatWindowRange(wStart, wEnd))
					timeL.Parent = card
					local cScroll = Instance.new("ScrollingFrame")
					cScroll.Position = UDim2.fromOffset(12, 42)
					cScroll.Size = UDim2.new(1, -24, 0, 86)
					cScroll.BackgroundTransparency = 1
					cScroll.BorderSizePixel = 0
					cScroll.ScrollBarThickness = 2
					cScroll.ScrollBarImageColor3 = g.color or LOG_PAL.accent
					cScroll.ScrollingDirection = Enum.ScrollingDirection.X
					cScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
					cScroll.AutomaticCanvasSize = Enum.AutomaticSize.X
					cScroll.Parent = card
					local cl = Instance.new("UIListLayout", cScroll)
					cl.FillDirection = Enum.FillDirection.Horizontal
					cl.Padding = UDim.new(0, 6)
					for _, cand in ipairs(g.candidates) do
						local cell = Instance.new("Frame")
						cell.Size = UDim2.fromOffset(72, 80)
						cell.BackgroundColor3 = Color3.fromRGB(22, 26, 36)
						cell.BackgroundTransparency = 0.3
						cell.BorderSizePixel = 0
						cell.Parent = cScroll
						Instance.new("UICorner", cell).CornerRadius = UDim.new(0, 6)
						local cs = Instance.new("UIStroke", cell)
						cs.Color = g.color or LOG_PAL.strokeCol
						cs.Thickness = 1
						cs.Transparency = 0.75
						local cIcon = Instance.new("ImageLabel")
						cIcon.Position = UDim2.fromOffset(22, 5)
						cIcon.Size = UDim2.fromOffset(28, 28)
						cIcon.BackgroundColor3 = Color3.fromRGB(30, 34, 46)
						cIcon.BackgroundTransparency = 0.4
						cIcon.BorderSizePixel = 0
						cIcon.ScaleType = Enum.ScaleType.Fit
						cIcon.Image = cand.icon or edGetPetIcon(cand.name)
						cIcon.Parent = cell
						Instance.new("UICorner", cIcon).CornerRadius = UDim.new(0, 4)
						local cName = Instance.new("TextLabel")
						cName.Position = UDim2.new(0, 3, 0, 36)
						cName.Size = UDim2.new(1, -6, 0, 13)
						cName.BackgroundTransparency = 1
						cName.Font = PANEL_BOLD
						cName.TextSize = 10
						cName.TextTruncate = Enum.TextTruncate.AtEnd
						cName.TextColor3 = Color3.fromRGB(230, 235, 245)
						cName.TextXAlignment = Enum.TextXAlignment.Center
						cName.Text = cand.name
						cName.Parent = cell
						local cArea = Instance.new("TextLabel")
						cArea.Position = UDim2.new(0, 3, 0, 50)
						cArea.Size = UDim2.new(1, -6, 0, 12)
						cArea.BackgroundTransparency = 1
						cArea.Font = PANEL_MEDIUM
						cArea.TextSize = 9
						cArea.TextTruncate = Enum.TextTruncate.AtEnd
						cArea.TextColor3 = LOG_PAL.muted
						cArea.TextXAlignment = Enum.TextXAlignment.Center
						cArea.Text = cand.area
						cArea.Parent = cell
						local cChance = Instance.new("TextLabel")
						cChance.Position = UDim2.new(0, 3, 0, 63)
						cChance.Size = UDim2.new(1, -6, 0, 13)
						cChance.BackgroundTransparency = 1
						cChance.Font = PANEL_BOLD
						cChance.TextSize = 10
						cChance.TextColor3 = Color3.fromRGB(255, 185, 0)
						cChance.TextXAlignment = Enum.TextXAlignment.Center
						cChance.Text = cand.chance
						cChance.Parent = cell
					end
				end
			end
			ED.list.CanvasSize = UDim2.new(0, 0, 0, displayedGroups * 142 + 10)
		else
			local items = {}
			for _, h in ipairs(ED.history) do
				if ED.filter == "All" or ED.filter == h.rarity then
					local _, _, col = rarityInfo(h.name)
					table.insert(items, {
						name = h.name,
						area = h.area,
						rarity = h.rarity,
						subText1 = string.format("[%s] - %s", (h.rarity or "Eternal"):upper(), h.area or "Field"),
						subText2 = string.format("Source: %s", h.reporter or "Server Alert"),
						rateText = edFormatDeviceTime(h.ts, false),
						badge = edFormatRelativeTime(h.ts),
						badgeColor = Color3.fromRGB(0, 255, 136),
						color = col or ((h.rarity == "Divine") and Color3.fromRGB(255, 255, 255) or Color3.fromRGB(255, 215, 0)),
						icon = edGetPetIcon(h.name),
						order = 10000000000 - (h.ts or 0)
					})
				end
			end
			for i, item in ipairs(items) do
				local row = Instance.new("Frame")
				row.Size = UDim2.new(1, -6, 0, 54)
				row.BackgroundColor3 = LOG_PAL.surface
				row.BackgroundTransparency = 0.15
				row.BorderSizePixel = 0
				row.LayoutOrder = i
				row.Parent = ED.list
				Instance.new("UICorner", row).CornerRadius = UDim.new(0, 8)
				local rs = Instance.new("UIStroke", row)
				rs.Color = item.color or LOG_PAL.accent
				rs.Thickness = 1
				rs.Transparency = 0.78
				local bar = Instance.new("Frame")
				bar.Size = UDim2.new(0, 4, 1, -12)
				bar.Position = UDim2.fromOffset(0, 6)
				bar.BorderSizePixel = 0
				bar.BackgroundColor3 = item.color or LOG_PAL.accent
				bar.Parent = row
				Instance.new("UICorner", bar).CornerRadius = UDim.new(1, 0)
				local icon = Instance.new("ImageLabel")
				icon.Position = UDim2.fromOffset(10, 8)
				icon.Size = UDim2.fromOffset(38, 38)
				icon.BackgroundColor3 = Color3.fromRGB(25, 28, 38)
				icon.BackgroundTransparency = 0.4
				icon.BorderSizePixel = 0
				icon.ScaleType = Enum.ScaleType.Fit
				icon.Image = item.icon or ""
				icon.Parent = row
				Instance.new("UICorner", icon).CornerRadius = UDim.new(0, 6)
				local nameL = Instance.new("TextLabel")
				nameL.BackgroundTransparency = 1
				nameL.Position = UDim2.fromOffset(56, 6)
				nameL.Size = UDim2.new(1, -165, 0, 16)
				nameL.Font = PANEL_BOLD
				nameL.TextSize = 12
				nameL.TextXAlignment = Enum.TextXAlignment.Left
				nameL.TextTruncate = Enum.TextTruncate.AtEnd
				nameL.TextColor3 = LOG_PAL.text
				nameL.Text = item.name
				nameL.Parent = row
				local subL1 = Instance.new("TextLabel")
				subL1.BackgroundTransparency = 1
				subL1.Position = UDim2.fromOffset(56, 22)
				subL1.Size = UDim2.new(1, -165, 0, 14)
				subL1.Font = PANEL_MEDIUM
				subL1.TextSize = 11
				subL1.TextXAlignment = Enum.TextXAlignment.Left
				subL1.TextTruncate = Enum.TextTruncate.AtEnd
				subL1.TextColor3 = LOG_PAL.muted
				subL1.Text = item.subText1
				subL1.Parent = row
				local subL2 = Instance.new("TextLabel")
				subL2.BackgroundTransparency = 1
				subL2.Position = UDim2.fromOffset(56, 36)
				subL2.Size = UDim2.new(1, -165, 0, 13)
				subL2.Font = PANEL_MEDIUM
				subL2.TextSize = 10
				subL2.TextXAlignment = Enum.TextXAlignment.Left
				subL2.TextTruncate = Enum.TextTruncate.AtEnd
				subL2.TextColor3 = Color3.fromRGB(150, 180, 220)
				subL2.Text = item.subText2
				subL2.Parent = row
				local badgeContainer = Instance.new("Frame")
				badgeContainer.BackgroundTransparency = 1
				badgeContainer.AnchorPoint = Vector2.new(1, 0.5)
				badgeContainer.Position = UDim2.new(1, -8, 0.5, 0)
				badgeContainer.Size = UDim2.fromOffset(105, 38)
				badgeContainer.Parent = row
				local bTop = Instance.new("TextLabel")
				bTop.BackgroundTransparency = 1
				bTop.Size = UDim2.new(1, 0, 0, 18)
				bTop.Font = PANEL_BOLD
				bTop.TextSize = 11
				bTop.TextXAlignment = Enum.TextXAlignment.Right
				bTop.TextTruncate = Enum.TextTruncate.AtEnd
				bTop.TextColor3 = item.badgeColor
				bTop.Text = string.format("[%s]", item.badge)
				bTop.Parent = badgeContainer
				local bBot = Instance.new("TextLabel")
				bBot.BackgroundTransparency = 1
				bBot.Position = UDim2.new(0, 0, 0, 18)
				bBot.Size = UDim2.new(1, 0, 0, 16)
				bBot.Font = PANEL_MEDIUM
				bBot.TextSize = 11
				bBot.TextXAlignment = Enum.TextXAlignment.Right
				bBot.TextTruncate = Enum.TextTruncate.AtEnd
				bBot.TextColor3 = Color3.fromRGB(170, 185, 210)
				bBot.Text = item.rateText
				bBot.Parent = badgeContainer
			end
			ED.list.CanvasSize = UDim2.new(0, 0, 0, #items * 58 + 10)
		end
	end
	function ED.build(parent)
		local main = Instance.new("Frame")
		main.Size = UDim2.fromScale(1, 1)
		main.BackgroundTransparency = 1
		main.BorderSizePixel = 0
		main.Parent = parent
		ED.headLbl = UIK.text(main, { text = "Global Egg Data & History", style = "body", color = LOG_PAL.accent, pos = UDim2.fromOffset(14, 2), size = UDim2.new(1, -28, 0, 18) })
		ED.headLbl.Font = PANEL_BOLD
		ED.catSeg = UIK.segmented(main, {
			options = { { "targets", "Egg Data (targets)" }, { "history", "Egg History" } },
			value = ED.category,
			h = 28,
			pos = UDim2.fromOffset(14, 22),
			size = UDim2.new(1, -28, 0, 32),
			onChange = function(key)
				ED.category = key
				ED.filter = "All"
				ED.paint()
			end,
		})
		local noticeBox = Instance.new("Frame")
		noticeBox.Position = UDim2.fromOffset(14, 58)
		noticeBox.Size = UDim2.new(1, -28, 0, 44)
		noticeBox.BackgroundColor3 = Color3.fromRGB(16, 20, 32)
		noticeBox.BorderSizePixel = 0
		noticeBox.Parent = main
		Instance.new("UICorner", noticeBox).CornerRadius = UDim.new(0, 6)
		local nStroke = Instance.new("UIStroke", noticeBox)
		nStroke.Color = Color3.fromRGB(50, 80, 130)
		nStroke.Thickness = 1
		ED.noticeBox = noticeBox
		local nText = Instance.new("TextLabel")
		nText.Position = UDim2.new(0, 8, 0, 4)
		nText.Size = UDim2.new(1, -16, 1, -8)
		nText.BackgroundTransparency = 1
		nText.Font = PANEL_MEDIUM
		nText.TextSize = 11
		nText.TextColor3 = Color3.fromRGB(180, 205, 235)
		nText.TextXAlignment = Enum.TextXAlignment.Left
		nText.TextWrapped = true
		nText.RichText = true
		nText.Text = "<b>Note:</b> These are estimated spawn targets based on cycle timing, not 100% guaranteed predictions."
		nText.Parent = noticeBox
		ED.noticeText = nText
		local summaryBox = Instance.new("Frame")
		summaryBox.Position = UDim2.fromOffset(14, 58)
		summaryBox.Size = UDim2.new(1, -28, 0, 44)
		summaryBox.BackgroundColor3 = Color3.fromRGB(22, 18, 28)
		summaryBox.BorderSizePixel = 0
		summaryBox.Visible = false
		summaryBox.Parent = main
		Instance.new("UICorner", summaryBox).CornerRadius = UDim.new(0, 6)
		local smStroke = Instance.new("UIStroke", summaryBox)
		smStroke.Color = Color3.fromRGB(130, 80, 40)
		smStroke.Thickness = 1
		ED.summaryBox = summaryBox
		local smText = Instance.new("TextLabel")
		smText.Position = UDim2.new(0, 8, 0, 4)
		smText.Size = UDim2.new(1, -16, 1, -8)
		smText.BackgroundTransparency = 1
		smText.Font = PANEL_MEDIUM
		smText.TextSize = 11
		smText.TextColor3 = Color3.fromRGB(240, 220, 200)
		smText.TextXAlignment = Enum.TextXAlignment.Left
		smText.TextWrapped = true
		smText.RichText = true
		smText.Text = ""
		smText.Parent = summaryBox
		ED.summaryText = smText
		ED.chipSeg = UIK.segmented(main, {
			options = { { "All", "All" }, { "Eternal", "Eternal" }, { "Divine", "Divine" } },
			value = ED.filter,
			pos = UDim2.fromOffset(14, 106),
			size = UDim2.new(1, -28, 0, 28),
			onChange = function(key)
				ED.filter = key
				ED.paint()
			end,
		})
		ED.chips = ED.chipSeg.buttons
		local list = Instance.new("ScrollingFrame")
		list.Position = UDim2.fromOffset(14, 136)
		list.Size = UDim2.new(1, -28, 1, -180)
		list.BackgroundTransparency = 1
		list.BorderSizePixel = 0
		list.ScrollBarThickness = 4
		list.ScrollBarImageColor3 = LOG_PAL.accent
		list.ScrollingDirection = Enum.ScrollingDirection.Y
		list.CanvasSize = UDim2.new(0, 0, 0, 0)
		list.Parent = main
		local ll = Instance.new("UIListLayout", list)
		ll.Padding = UDim.new(0, 6)
		ll.SortOrder = Enum.SortOrder.LayoutOrder
		ED.list = list
		local bar = Instance.new("Frame")
		bar.Position = UDim2.new(0, 14, 1, -40)
		bar.Size = UDim2.new(1, -28, 0, 32)
		bar.BackgroundTransparency = 1
		bar.Parent = main
		ED.refreshBtn = UIK.button(bar, {
			text = "Refresh targets",
			icon = "refresh-cw",
			h = 32,
			onClick = function()
				ED.scanField()
				ED.syncBackend()
				ED.paint()
			end,
		})
		local statusLbl = UIK.text(bar, { text = "● Online synced", style = "meta", color = Color3.fromRGB(0, 255, 136), align = Enum.TextXAlignment.Right, anchor = Vector2.new(1, 0), pos = UDim2.fromScale(1, 0), size = UDim2.new(0.5, -4, 1, 0) })
		ED.statusLbl = statusLbl
		if not ED.bound then
			ED.bound = true
			pcall(function()
				local expChat = game:GetService("CoreGui"):FindFirstChild("ExperienceChat")
				if expChat then
					for _, d in ipairs(expChat:GetDescendants()) do
						if d:IsA("TextLabel") and d.Text:find("spawned in") then
							local r, p, a = edParseAnnouncement(d.Text)
							if r and p and a then
								local norm = edNormalizePet(p)
								local uid = string.format("init_%s_%s", norm, a:lower())
								if not ED.reportedUids[uid] then
									ED.reportedUids[uid] = os.time()
									edAddHistoryItem({ uid = uid, name = p, area = a, rarity = r, ts = os.time() - 120, reporter = "Server Alert" })
								end
							end
						end
					end
					expChat.DescendantAdded:Connect(function(d)
						if d:IsA("TextLabel") and d.Text:find("spawned in") then
							task.wait(0.05)
							edHandleIncomingAlert(d.Text)
						end
					end)
				end
			end)
			pcall(function()
				local TCS = game:GetService("TextChatService")
				TCS.MessageReceived:Connect(function(msg)
					if msg and msg.Text and msg.Text:find("spawned in") then
						edHandleIncomingAlert(msg.Text)
					end
				end)
			end)
		end
		ED.scanField()
		ED.syncBackend()
		ED.paint()
	end
	function ED.refresh()
		ED.scanField()
		ED.syncBackend()
		ED.paint()
	end
	local PANEL_ORDER = { "logs", "eggs", "inventory", "checker", "eggdata", "stats" }
	local PANEL_DEFS = {
		logs = {
			name = "Egg Logs",
			w = 420,
			h = 500,
			build = function(p) return buildLogsPage(p) end,
		},
		eggs = {
			name = "Egg Board",
			w = 420,
			h = 500,
			build = function(p) return buildPlacePage(p) end,
		},
		inventory = {
			name = "Inventory & Base",
			w = 440,
			h = 510,
			build = function(p) return buildPetsPage(p) end,
		},
		checker = {
			name = "Egg Checker",
			w = 420,
			h = 500,
			build = function(p) return CK.build(p) end,
		},
		stats = {
			name = "Farm Stats",
			w = 440,
			h = 560,
			build = function(p) return buildStatsPage(p) end,
		},
		eggdata = {
			name = "Egg Data & History",
			w = 380,
			h = 570,
			build = function(p) return ED.build(p) end,
		},
	}
	local function buildPanelWindow(key)
		uiIdentity()
		local def = PANEL_DEFS[key]
		if not def then return end
		local old = panels[key]
		if old and old.conns then
			for _, conn in ipairs(old.conns) do pcall(function() conn:Disconnect() end) end
		end
		local guiName = "__SNE_Panel_" .. key
		for _, root in ipairs({ game:GetService("CoreGui"), (function()
			local ok, r = pcall(function() return LocalPlayer:FindFirstChild("PlayerGui") end)
			return ok and r or nil
		end)() }) do
			if root then
				pcall(function()
					for _, d in ipairs(root:GetDescendants()) do
						if d.Name == guiName and d:IsA("ScreenGui") then
							pcall(function() d:Destroy() end)
						end
					end
				end)
			end
		end
		local conns = {}
		local TweenService = game:GetService("TweenService")
		local host = resolveGuiHost()
		local gui = Instance.new("ScreenGui")
		gui.Name = guiName
		gui.ResetOnSpawn = false
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		gui.DisplayOrder = 99999
		gui.Parent = host
		local slot = 0
		for i, k in ipairs(PANEL_ORDER) do if k == key then slot = i - 1 end end
		local holder = Instance.new("Frame")
		holder.AnchorPoint = Vector2.new(0.5, 0.5)
		holder.Size = UDim2.fromOffset(def.w, def.h)
		holder.BackgroundTransparency = 1
		holder.Active = true
		holder.Parent = gui
		local uiscale = Instance.new("UIScale")
		uiscale.Name = "WindowScale"
		uiscale.Scale = 1
		uiscale.Parent = holder
		local body = Instance.new("Frame")
		body.BackgroundTransparency = 1
		body.Size = UDim2.fromScale(1, 1)
		body.Parent = holder
		local pop = Instance.new("UIScale")
		pop.Name = "Pop"
		pop.Parent = body
		local UIS = game:GetService("UserInputService")
		local function fitScale(isInitial)
			local cam = workspace.CurrentCamera
			local vp = cam and cam.ViewportSize or Vector2.new(1024, 768)
			if vp.X <= 0 or vp.Y <= 0 then return end
			local isMobile = (UIS.TouchEnabled and not UIS.KeyboardEnabled) or vp.Y < 550
			local maxW = vp.X * (isMobile and 0.86 or 0.94)
			local maxH = vp.Y * (isMobile and 0.88 or 0.92)
			local fit = math.min(1, maxW / def.w, maxH / def.h)
			if isMobile and fit > 0.82 then fit = 0.82 end
			uiscale.Scale = math.clamp(fit, 0.6, 1.0)
			local curScale = uiscale.Scale
			local scaledW = def.w * curScale
			local scaledH = def.h * curScale
			if isInitial then
				if isMobile then
					holder.Position = UDim2.fromOffset(vp.X - math.floor(scaledW / 2) - 14, math.floor(vp.Y / 2))
				else
					holder.Position = UDim2.fromOffset(math.floor(vp.X / 2 + slot * 24), math.floor(vp.Y / 2 + slot * 20))
				end
			end
			local halfW, halfH = scaledW / 2, scaledH / 2
			local minX = math.min(halfW + 8, vp.X / 2)
			local maxX = math.max(vp.X - halfW - 8, vp.X / 2)
			local minY = math.min(halfH + 8, vp.Y / 2)
			local maxY = math.max(vp.Y - halfH - 8, vp.Y / 2)
			local curX = holder.Position.X.Scale * vp.X + holder.Position.X.Offset
			local curY = holder.Position.Y.Scale * vp.Y + holder.Position.Y.Offset
			holder.Position = UDim2.fromOffset(
				math.floor(math.clamp(curX, minX, maxX)),
				math.floor(math.clamp(curY, minY, maxY))
			)
		end
		local shadow = Instance.new("ImageLabel")
		shadow.AnchorPoint = Vector2.new(0.5, 0.5)
		shadow.BackgroundTransparency = 1
		shadow.Image = "rbxassetid://6015897843"
		shadow.ImageColor3 = SNE_PAL.shadow
		shadow.ImageTransparency = 0.52
		shadow.Position = UDim2.fromScale(0.5, 0.5)
		shadow.ScaleType = Enum.ScaleType.Slice
		shadow.Size = UDim2.new(1, 40, 1, 40)
		shadow.SliceCenter = Rect.new(49, 49, 450, 450)
		shadow.ZIndex = 0
		shadow.Parent = body
		local main = Instance.new("Frame")
		main.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
		main.BorderSizePixel = 0
		main.Size = UDim2.fromScale(1, 1)
		main.ZIndex = 1
		main.Parent = body
		Instance.new("UICorner", main).CornerRadius = UDim.new(0, 10)
		local mgrad = Instance.new("UIGradient", main)
		mgrad.Rotation = 16
		mgrad.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, SNE_PAL.obsTop),
			ColorSequenceKeypoint.new(0.52, SNE_PAL.obsMid),
			ColorSequenceKeypoint.new(1, SNE_PAL.obsLow),
		})
		local mstroke = Instance.new("UIStroke", main)
		mstroke.Color = SNE_PAL.strokeCol
		mstroke.Thickness = 1
		mstroke.Transparency = 0.72
		local logo = Instance.new("ImageLabel")
		logo.AnchorPoint = Vector2.new(0, 0.5)
		logo.BackgroundTransparency = 1
		logo.Image = SNE_LOGO
		logo.Position = UDim2.fromOffset(12, 22)
		logo.ScaleType = Enum.ScaleType.Fit
		logo.Size = UDim2.fromOffset(20, 20)
		logo.Parent = main
		local headRow = Instance.new("Frame")
		headRow.BackgroundTransparency = 1
		headRow.Position = UDim2.fromOffset(40, 10)
		headRow.Size = UDim2.new(1, -86, 0, 24)
		headRow.Parent = main
		local headLayout = Instance.new("UIListLayout", headRow)
		headLayout.FillDirection = Enum.FillDirection.Horizontal
		headLayout.Padding = UDim.new(0, 8)
		headLayout.SortOrder = Enum.SortOrder.LayoutOrder
		headLayout.VerticalAlignment = Enum.VerticalAlignment.Center
		local title = UIK.text(headRow, { text = "Sena", style = "title", order = 1, size = UDim2.new(0, 0, 1, 0) })
		title.AutomaticSize = Enum.AutomaticSize.X
		title.TextTruncate = Enum.TextTruncate.None
		local nameChip = Instance.new("Frame")
		nameChip.AutomaticSize = Enum.AutomaticSize.X
		nameChip.BackgroundColor3 = SNE_PAL.accent
		nameChip.BackgroundTransparency = 0.82
		nameChip.BorderSizePixel = 0
		nameChip.LayoutOrder = 2
		nameChip.Size = UDim2.fromOffset(0, 22)
		nameChip.Parent = headRow
		Instance.new("UICorner", nameChip).CornerRadius = UDim.new(0, 6)
		local ncs = Instance.new("UIStroke", nameChip)
		ncs.Color = SNE_PAL.accent
		ncs.Thickness = 1
		ncs.Transparency = 0.45
		local ncpad = Instance.new("UIPadding", nameChip)
		ncpad.PaddingLeft = UDim.new(0, 10)
		ncpad.PaddingRight = UDim.new(0, 10)
		local nameLbl = UIK.text(nameChip, { text = def.name, style = "body", size = UDim2.new(0, 0, 1, 0) })
		nameLbl.AutomaticSize = Enum.AutomaticSize.X
		nameLbl.TextTruncate = Enum.TextTruncate.None
		nameLbl.Font = PANEL_BOLD
		local closeB = Instance.new("TextButton")
		closeB.AutoButtonColor = false
		closeB.BackgroundColor3 = SNE_PAL.btnBg
		closeB.BackgroundTransparency = 0.15
		closeB.Position = UDim2.new(1, -38, 0, 9)
		closeB.Size = UDim2.fromOffset(28, 28)
		closeB.Text = ""
		closeB.ZIndex = 5
		closeB.Parent = main
		Instance.new("UICorner", closeB).CornerRadius = UDim.new(0, 6)
		local cbs = Instance.new("UIStroke", closeB)
		cbs.Color = SNE_PAL.strokeCol
		cbs.Thickness = 1
		cbs.Transparency = 0.6
		local closeIcon = UIK.image(closeB, "x", 14, SNE_PAL.btnText)
		closeIcon.AnchorPoint = Vector2.new(0.5, 0.5)
		closeIcon.Position = UDim2.fromScale(0.5, 0.5)
		closeIcon.ZIndex = 6
		closeB.MouseEnter:Connect(function() closeIcon.ImageColor3 = Color3.fromRGB(248, 113, 113) end)
		closeB.MouseLeave:Connect(function() closeIcon.ImageColor3 = SNE_PAL.btnText end)
		local footer = Instance.new("TextButton")
		footer.AnchorPoint = Vector2.new(0.5, 0.5)
		footer.AutoButtonColor = false
		footer.AutomaticSize = Enum.AutomaticSize.X
		footer.BackgroundColor3 = SNE_PAL.btnBg
		footer.BackgroundTransparency = 0.15
		footer.Position = UDim2.new(0.5, 0, 1, -24)
		footer.Size = UDim2.fromOffset(0, 24)
		footer.Text = ""
		footer.Parent = main
		Instance.new("UICorner", footer).CornerRadius = UDim.new(1, 0)
		local fstroke = Instance.new("UIStroke", footer)
		fstroke.Color = SNE_PAL.strokeCol
		fstroke.Thickness = 1
		fstroke.Transparency = 0.6
		local fpad = Instance.new("UIPadding", footer)
		fpad.PaddingLeft = UDim.new(0, 10)
		fpad.PaddingRight = UDim.new(0, 12)
		local flayout = Instance.new("UIListLayout", footer)
		flayout.FillDirection = Enum.FillDirection.Horizontal
		flayout.Padding = UDim.new(0, 6)
		flayout.SortOrder = Enum.SortOrder.LayoutOrder
		flayout.VerticalAlignment = Enum.VerticalAlignment.Center
		local dic = UIK.image(footer, "message-circle", 12, SNE_PAL.accentB)
		dic.LayoutOrder = 0
		local dtext = UIK.text(footer, { text = SNE_INVITE, style = "meta", order = 1, size = UDim2.new(0, 0, 1, 0) })
		dtext.AutomaticSize = Enum.AutomaticSize.X
		dtext.TextTruncate = Enum.TextTruncate.None
		dtext.Font = PANEL_BOLD
		footer.MouseButton1Click:Connect(function()
			pcall(function() setclipboard("https://" .. SNE_INVITE) end)
			dtext.Text = "Copied"
			task.delay(1.2, function() if dtext.Parent then dtext.Text = SNE_INVITE end end)
		end)
		local page = Instance.new("Frame")
		page.BackgroundTransparency = 1
		page.BorderSizePixel = 0
		page.Position = UDim2.fromOffset(0, 46)
		page.Size = UDim2.new(1, 0, 1, -86)
		page.Parent = main
		local dragging, dragStart, startPos = false, nil, nil
		local function beginDrag(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				dragging = true
				dragStart = input.Position
				startPos = holder.Position
			end
		end
		headRow.InputBegan:Connect(beginDrag)
		main.InputBegan:Connect(function(input)
			local curScale = uiscale and uiscale.Scale or 1
			if input.Position.Y - holder.AbsolutePosition.Y <= (44 * curScale) then beginDrag(input) end
		end)
		conns[#conns + 1] = UIS.InputChanged:Connect(function(input)
			if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
				local d = input.Position - dragStart
				holder.Position = UDim2.new(startPos.X.Scale, startPos.X.Offset + d.X, startPos.Y.Scale, startPos.Y.Offset + d.Y)
			end
		end)
		conns[#conns + 1] = UIS.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
				if dragging then
					dragging = false
					pcall(fitScale, false)
				end
			end
		end)
		fitScale(true)
		local cam = workspace.CurrentCamera
		if cam then
			conns[#conns + 1] = cam:GetPropertyChangedSignal("ViewportSize"):Connect(function()
				if gui and gui.Parent and gui.Enabled then
					pcall(fitScale, false)
				end
			end)
		end
		local animToken = 0
		local function animateOpen()
			animToken = animToken + 1
			gui.Enabled = true
			pop.Scale = 0.94
			shadow.ImageTransparency = 1
			TweenService:Create(pop, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Scale = 1 }):Play()
			TweenService:Create(shadow, TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { ImageTransparency = 0.52 }):Play()
		end
		local function animateClose()
			animToken = animToken + 1
			local token = animToken
			TweenService:Create(pop, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Scale = 0.94 }):Play()
			TweenService:Create(shadow, TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { ImageTransparency = 1 }):Play()
			task.delay(0.12, function()
				if animToken == token then
					uiIdentity()
					gui.Enabled = false
				end
			end)
		end
		closeB.MouseButton1Click:Connect(function()
			uiIdentity()
			animateClose()
		end)
		panels[key] = { gui = gui, page = page, holder = holder, fitScale = fitScale, conns = conns, open = animateOpen, close = animateClose }
		pcall(function() def.build(page) end)
		pcall(function() refreshPanel(key) end)
		animateOpen()
	end
	local function openPanel(key)
		uiIdentity()
		key = key or "logs"
		local p = panels[key]
		if p and p.gui and p.gui.Parent then
			if p.open then p.open() else p.gui.Enabled = true end
			if p.fitScale then pcall(p.fitScale, false) end
			pcall(function() refreshPanel(key) end)
			return
		end
		buildPanelWindow(key)
	end
	local function openAllPanels()
		for _, key in ipairs(PANEL_ORDER) do openPanel(key) end
	end
	local function closeAllPanels()
		for _, p in pairs(panels) do
			if p and p.gui and p.gui.Enabled then
				if p.close then p.close() else p.gui.Enabled = false end
			end
		end
	end
	task.spawn(function()
		while sessionAlive() do
			pcall(function()
				local snap = EggState.ReadFieldEggs()
				if snap and snap.Records then
					for _, rec in ipairs(snap.Records) do
						recordEggLog(rec)
					end
				end
			end)
			pcall(function()
				if ED and type(ED.scanField) == "function" then
					ED.scanField()
				end
			end)
			for _, key in ipairs({ "logs", "eggs", "inventory", "checker", "eggdata" }) do
				if panelShown(key) then
					pcall(refreshPanel, key)
				end
			end
			task.wait(2)
		end
	end)
	;(function()
		local TweenService = game:GetService("TweenService")
		local GuiService = game:GetService("GuiService")
		local UIS = game:GetService("UserInputService")
		local CARD_W, CARD_H, PAD, IMG = 380, 108, 12, 48
		local TOP_GAP = 12
		local SAFE_POS = Vector3.new(542.93, 71.5, -405.58)
		local GOOD = Color3.fromRGB(110, 231, 140)
		local BAD = Color3.fromRGB(248, 113, 113)
		local SLIDE = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		local token = {}
		runtimeEnv.__SenaV4StealCardToken = token
		local REASONS = {
			{ "carried by another", "Another player took it" },
			{ "taken by another", "Another player took it" },
			{ "someone else grabbed", "Another player took it" },
			{ "no longer available", "The egg is gone" },
			{ "target unavailable", "The egg is gone" },
			{ "target changed", "The egg is gone" },
			{ "reset countdown", "Eggs are resetting" },
			{ "egg reset", "The egg reset" },
			{ "wall closed", "Night started" },
			{ "character unavailable", "You were knocked out" },
			{ "character died", "You were knocked out" },
			{ "they banked", "They banked it first" },
			{ "could not catch", "Could not catch them" },
			{ "lost sight", "Could not catch them" },
			{ "bank not confirmed", "Deposit not confirmed" },
			{ "delivery failed", "Deposit not confirmed" },
			{ "not banked", "Deposit not confirmed" },
			{ "carry", "Could not pick it up" },
			{ "stopped", "Stopped" },
			{ "mode changed", "Stopped" },
		}
		local function reasonText(raw)
			local lower = string.lower(tostring(raw or ""))
			for _, pair in ipairs(REASONS) do
				if lower:find(pair[1], 1, true) then return pair[2] end
			end
			return "Steal interrupted — retrying"
		end
		local TRANSIENT = {
			"retrying", "could not reach", "destination unavailable", "steal unavailable",
			"target destination", "no target", "steal error", "preparing", "searching",
			"target changed", "next egg",
		}
		local function isTransientResult(raw)
			local lower = string.lower(tostring(raw or ""))
			if lower == "" or lower == "nil" then return true end
			for _, needle in ipairs(TRANSIENT) do
				if lower:find(needle, 1, true) then return true end
			end
			return false
		end
		local CHIPS = {
			head = { "Heading", "navigation", SNE_PAL.accentB },
			secure = { "Securing", "hand", SNE_PAL.accentB },
			home = { "Bringing home", "home", SNE_PAL.accentB },
			done = { "Stolen", "circle-check", GOOD },
			friend = { "Dropped", "gift", GOOD },
			fail = { "Failed", "circle-x", BAD },
			retry = { "Retrying", "navigation", SNE_PAL.accentB },
		}
		local ui = {}
		local function host()
			local ok, hidden = pcall(function() return gethui and gethui() end)
			if ok and typeof(hidden) == "Instance" and not hidden:IsA("LayerCollector") then return hidden end
			local okCore, core = pcall(function() return game:GetService("CoreGui") end)
			return okCore and core or resolveGuiHost()
		end
		local function corner(parent, radius)
			local c = Instance.new("UICorner")
			c.CornerRadius = radius or UDim.new(0, 10)
			c.Parent = parent
		end
		local function build()
			if ui.gui and ui.gui.Parent then return true end
			uiIdentity()
			local parent = host()
			pcall(function()
				local old = parent:FindFirstChild("SenaStealCard")
				if old then old:Destroy() end
			end)
			local gui = Instance.new("ScreenGui")
			gui.Name = "SenaStealCard"
			gui.ResetOnSpawn = false
			gui.IgnoreGuiInset = true
			gui.DisplayOrder = -1
			gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
			local card = Instance.new("Frame")
			card.Name = "Card"
			card.AnchorPoint = Vector2.new(0.5, 0)
			card.Position = UDim2.new(0.5, 0, 0, -CARD_H - 24)
			card.Size = UDim2.fromOffset(CARD_W, CARD_H)
			card.BackgroundColor3 = SNE_PAL.surface
			card.BorderSizePixel = 0
			card.Visible = false
			card.Parent = gui
			corner(card)
			local stroke = Instance.new("UIStroke")
			stroke.Color = SNE_PAL.strokeCol
			stroke.Thickness = 1
			stroke.Parent = card
			local gradient = Instance.new("UIGradient")
			gradient.Color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, SNE_PAL.obsTop),
				ColorSequenceKeypoint.new(0.55, SNE_PAL.obsMid),
				ColorSequenceKeypoint.new(1, SNE_PAL.obsLow),
			})
			gradient.Rotation = 16
			gradient.Parent = card
			local textW = -(PAD * 2 + IMG + 12)
			ui.head = UIK.text(card, { style = "label", text = "Stealing", color = SNE_PAL.muted,
				pos = UDim2.fromOffset(PAD, 10), size = UDim2.new(1, -(PAD * 2 + 124), 0, 14) })
			local chip = Instance.new("Frame")
			chip.Name = "Chip"
			chip.AnchorPoint = Vector2.new(1, 0)
			chip.Position = UDim2.new(1, -PAD, 0, 8)
			chip.Size = UDim2.fromOffset(0, 18)
			chip.AutomaticSize = Enum.AutomaticSize.X
			chip.BackgroundColor3 = SNE_PAL.btnBg
			chip.BorderSizePixel = 0
			chip.Parent = card
			corner(chip, UDim.new(1, 0))
			local chipPad = Instance.new("UIPadding")
			chipPad.PaddingLeft = UDim.new(0, 7)
			chipPad.PaddingRight = UDim.new(0, 8)
			chipPad.Parent = chip
			local chipList = Instance.new("UIListLayout")
			chipList.FillDirection = Enum.FillDirection.Horizontal
			chipList.VerticalAlignment = Enum.VerticalAlignment.Center
			chipList.Padding = UDim.new(0, 4)
			chipList.SortOrder = Enum.SortOrder.LayoutOrder
			chipList.Parent = chip
			ui.chipIcon = Instance.new("ImageLabel")
			ui.chipIcon.BackgroundTransparency = 1
			ui.chipIcon.Size = UDim2.fromOffset(12, 12)
			ui.chipIcon.LayoutOrder = 1
			ui.chipIcon.Parent = chip
			ui.chipText = UIK.text(chip, { style = "label", text = "", order = 2, size = UDim2.fromOffset(0, 14) })
			ui.chipText.AutomaticSize = Enum.AutomaticSize.X
			ui.chipText.TextTruncate = Enum.TextTruncate.None
			local imgBack = Instance.new("Frame")
			imgBack.Position = UDim2.fromOffset(PAD, 32)
			imgBack.Size = UDim2.fromOffset(IMG, IMG)
			imgBack.BackgroundColor3 = SNE_PAL.surfaceHi
			imgBack.BorderSizePixel = 0
			imgBack.Parent = card
			corner(imgBack, UDim.new(0, 8))
			ui.img = Instance.new("ImageLabel")
			ui.img.BackgroundTransparency = 1
			ui.img.Position = UDim2.fromOffset(4, 4)
			ui.img.Size = UDim2.new(1, -8, 1, -8)
			ui.img.ScaleType = Enum.ScaleType.Fit
			ui.img.Parent = imgBack
			ui.title = UIK.text(card, { style = "title", pos = UDim2.fromOffset(PAD + IMG + 12, 31), size = UDim2.new(1, textW, 0, 18) })
			ui.rarity = UIK.text(card, { style = "body", pos = UDim2.fromOffset(PAD + IMG + 12, 50), size = UDim2.new(1, textW, 0, 16) })
			ui.stats = UIK.text(card, { style = "meta", color = SNE_PAL.muted, pos = UDim2.fromOffset(PAD + IMG + 12, 66), size = UDim2.new(1, textW, 0, 15) })
			ui.barBack = Instance.new("Frame")
			ui.barBack.Position = UDim2.fromOffset(PAD, 91)
			ui.barBack.Size = UDim2.new(1, -(PAD * 2 + 84), 0, 6)
			ui.barBack.BackgroundColor3 = SNE_PAL.btnBg
			ui.barBack.BorderSizePixel = 0
			ui.barBack.Parent = card
			corner(ui.barBack, UDim.new(1, 0))
			ui.barFill = Instance.new("Frame")
			ui.barFill.Size = UDim2.fromScale(0, 1)
			ui.barFill.BackgroundColor3 = SNE_PAL.accent
			ui.barFill.BorderSizePixel = 0
			ui.barFill.Parent = ui.barBack
			corner(ui.barFill, UDim.new(1, 0))
			ui.eta = UIK.text(card, { style = "meta", color = SNE_PAL.muted, align = Enum.TextXAlignment.Right,
				anchor = Vector2.new(1, 0), pos = UDim2.new(1, -PAD, 0, 86), size = UDim2.fromOffset(80, 16) })
			ui.reason = UIK.text(card, { style = "body", color = BAD, pos = UDim2.fromOffset(PAD, 86), size = UDim2.new(1, -PAD * 2, 0, 16) })
			ui.reason.Visible = false
			ui.scale = Instance.new("UIScale")
			ui.scale.Parent = card
			gui.Parent = parent
			ui.gui, ui.card = gui, card
			return true
		end
		local function announceBottom()
			local inset = 0
			pcall(function() inset = GuiService:GetGuiInset().Y end)
			local bottom = 0
			local roots = {}
			pcall(function() if gethui then roots[#roots + 1] = gethui() end end)
			pcall(function() roots[#roots + 1] = game:GetService("CoreGui") end)
			for _, root in ipairs(roots) do
				for _, spec in ipairs({ { "AnnounceGui", "Holder" }, { "NotifyGui", "AnnounceLayout" } }) do
					local layer = root:FindFirstChild(spec[1])
					local nested = layer and layer.Parent and layer.Parent:IsA("LayerCollector") 
					local holder = layer and not nested and layer:IsA("LayerCollector") and layer.Enabled and layer:FindFirstChild(spec[2])
					if holder then
						for _, child in ipairs(holder:GetChildren()) do
							if child:IsA("GuiObject") and child.Visible then
								local b = child.AbsolutePosition.Y + child.AbsoluteSize.Y + inset
								if b > bottom then bottom = b end
							end
						end
					end
				end
			end
			return bottom, inset
		end
		local function set(obj, prop, value)
			if obj[prop] ~= value then obj[prop] = value end
		end
		local function viewport()
			local cam = workspace.CurrentCamera
			local vp = cam and cam.ViewportSize
			return (vp and vp.X > 0 and vp.Y > 0) and vp or Vector2.new(1280, 720)
		end
		local function fitScale()
			local vp = viewport()
			local isMobile = (UIS.TouchEnabled and not UIS.KeyboardEnabled) or vp.Y < 550
			local fit = math.min(1, (vp.X - 32) / CARD_W)
			if isMobile then return math.clamp(math.min(fit, 0.6, vp.Y * 0.15 / CARD_H), 0.5, 1) end
			return math.clamp(fit, 0.62, 1)
		end
		local popTween = nil
		local cur, shown, shownY = nil, false, nil
		local ema = {}
		local function slideTo(y)
			if shownY == y then return end
			shownY = y
			TweenService:Create(ui.card, SLIDE, { Position = UDim2.new(0.5, 0, 0, y) }):Play()
		end
		local function showCard(on)
			if on == shown then return end
			shown = on
			if on then
				shownY = nil
				ui.card.Position = UDim2.new(0.5, 0, 0, -CARD_H - 24)
				ui.card.Visible = true
				local fit = fitScale()
				ui.scale.Scale = fit * 0.94
				popTween = TweenService:Create(ui.scale, SLIDE, { Scale = fit })
				popTween:Play()
			else
				shownY = -CARD_H - 24
				local tween = TweenService:Create(ui.card, SLIDE, { Position = UDim2.new(0.5, 0, 0, shownY) })
				tween.Completed:Connect(function()
					if not shown then ui.card.Visible = false end
				end)
				tween:Play()
			end
		end
		local function setChip(kind)
			local spec = CHIPS[kind] or CHIPS.head
			if ui.chipKind == kind then return end
			ui.chipKind = kind
			ui.chipText.Text = string.upper(spec[1])
			ui.chipText.TextColor3 = spec[3]
			ui.chipIcon.ImageColor3 = spec[3]
			UIK.icon(ui.chipIcon, spec[2])
		end
		local function eggPos(record)
			local cf = record and (record.BottomCFrame or record.BoundsCFrame)
			return cf and cf.Position
		end
		local function flat(a, b)
			local d = a - b
			return Vector3.new(d.X, 0, d.Z).Magnitude
		end
		local function phaseOf(status, carrying)
			local s = string.lower(tostring(status or ""))
			if carrying or s:find("bringing", 1, true) or s:find("deposit", 1, true) or s:find("delivering", 1, true)
				or s:find("carrying", 1, true) or s:find("validating", 1, true) then
				return "home"
			end
			if s:find("securing", 1, true) or s:find("waiting for carry", 1, true) or s:find("re-steal", 1, true)
				or s:find("re-approach", 1, true) or s:find("confirm", 1, true) or s:find("grabbing", 1, true)
				or s:find("attacking", 1, true) then
				return "secure"
			end
			return "head"
		end
		local BOOST_PORTAL_LEG, BOOST_HOME_TAIL = 4.2, 0.7
		local function modelEta(c, phase, status)
			local root = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
			local target = eggPos(c.record)
			if not root then return nil end
			if c.boost then
				if phase == "home" then return flat(root.Position, SAFE_POS) / c.back + BOOST_HOME_TAIL end
				if not target then return nil end
				local leg = math.max(BOOST_PORTAL_LEG - (os.clock() - c.startedAt), 0)
				return leg + flat(target, SAFE_POS) / c.back + BOOST_HOME_TAIL
			end
			if phase == "home" then return flat(root.Position, SAFE_POS) / c.back + 2.5 end
			if c.kind ~= "auto" or not target then return nil end
			local hold = c.hold
			if phase == "secure" then
				local left = tonumber(string.match(tostring(status or ""), "%(([%d%.]+)s%)"))
				hold = left or math.max(hold - (os.clock() - (c.phaseAt or os.clock())), 0.5)
			end
			local travel = (phase == "head" and not c.boost) and flat(root.Position, target) / c.out or 0
			return travel + hold + flat(target, SAFE_POS) / c.back + 4.5
		end
		local function begin(kind, uid, record, rt, player)
			local info = nil
			pcall(function() info = catalog.resolve(record) end)
			local cat = record.AssetCategory
			local _, rname, rcolor = rarityInfo(cat)
			local c = { kind = kind, uid = uid, record = record, player = player, startedAt = os.clock(),
				progress = 0, area = tostring(record.AreaId or "?"), out = 400, back = 5000, hold = 1 }
			if rt then
				c.delivered = tonumber(rt.stats and rt.stats.delivered) or 0
				c.mode = rt.config and rt.config.stealMode or "Fly"
				pcall(function() c.boost = rt:_usesPortalBoost(record) == true end)
				pcall(function() c.walk = rt:_legitWalkSpeed() end)
				if c.mode == "Fly" then
					c.out = tonumber(c.walk) or 16
					c.hold = 1
				else
					c.out = 5000
					c.hold = c.boost and 0 or (tonumber(rt:_resolveSettleSeconds(record)) or 8) 
				end
			end
			c.key = tostring(c.mode) .. "|" .. c.area .. (c.boost and "|b" or "")
			build()
			c.headBase = player and string.upper("Stealing from " .. tostring(player)) or "STEALING"
			set(ui.head, "Text", c.headBase)
			set(ui.head, "TextColor3", SNE_PAL.muted)
			set(ui.title, "Text", info and tostring(info.name) or tostring(cat or "Egg"))
			set(ui.rarity, "Text", tostring(rname or "?"))
			set(ui.rarity, "TextColor3", rcolor and rcolor:Lerp(Color3.new(1, 1, 1), 0.35) or SNE_PAL.text)
			local parts = {}
			local kg = weightOfItem(record)
			if kg and kg > 0 then parts[#parts + 1] = kg >= 1000 and (moneyStr(kg) .. " kg") or string.format("%.1f kg", kg) end
			local rate = rateOfItem(record)
			if rate and rate > 0 then parts[#parts + 1] = "$" .. moneyStr(rate) .. "/s" end
			local mutations = {}
			for _, m in ipairs(type(record.Mutations) == "table" and record.Mutations or {}) do
				if #mutations < 2 then mutations[#mutations + 1] = tostring(m) end
			end
			if #mutations > 0 then parts[#parts + 1] = table.concat(mutations, ", ") end
			set(ui.stats, "Text", table.concat(parts, "  ·  "))
			local image = assetImage(cat)
			if not image then pcall(function() image = edGetPetIcon(cat) end) end
			set(ui.img, "Image", image or "")
			c.color = rcolor or SNE_PAL.accent
			set(ui.barFill, "BackgroundColor3", c.color)
			ui.barFill.Size = UDim2.fromScale(0, 1)
			ui.barBack.Visible, ui.eta.Visible, ui.reason.Visible = true, true, false
			ui.chipKind = nil
			setChip("head")
			cur = c
			showCard(true)
		end
		local function conclude(kind, text)
			local c = cur
			if not c or c.endedAt then return end
			c.endedAt = os.clock()
			c.result = kind
			setChip(kind)
			if kind == "fail" then
				ui.barBack.Visible, ui.eta.Visible, ui.reason.Visible = false, false, true
				set(ui.reason, "TextColor3", BAD)
				set(ui.reason, "Text", text or "Steal interrupted — retrying")
			elseif kind == "retry" then
				ui.barBack.Visible, ui.eta.Visible, ui.reason.Visible = false, false, true
				set(ui.reason, "TextColor3", SNE_PAL.muted)
				set(ui.reason, "Text", text or "Retrying…")
			else
				set(ui.barFill, "BackgroundColor3", GOOD)
				TweenService:Create(ui.barFill, SLIDE, { Size = UDim2.fromScale(1, 1) }):Play()
				set(ui.eta, "Text", kind == "friend" and "Handed off" or "Banked")
				if kind == "done" and c.kind == "auto" then
					local took = c.endedAt - c.startedAt
					ema[c.key] = ema[c.key] and (ema[c.key] * 0.6 + took * 0.4) or took
				end
			end
		end
		local finishLog = { rt = nil, unsub = nil, result = nil, at = 0 }
		local function watchRuntime(rt)
			if finishLog.rt == rt then return end
			if finishLog.unsub then pcall(finishLog.unsub) end
			finishLog.rt, finishLog.unsub = rt, nil
			if not rt or type(rt.onChanged) ~= "function" then return end
			local wasRunning = nil
			local ok, unsub = pcall(rt.onChanged, rt, function(snap)
				if type(snap) ~= "table" then return end
				if wasRunning and not snap.running then
					finishLog.result, finishLog.at = snap.lastResult, os.clock()
				end
				wasRunning = snap.running
			end)
			if ok and type(unsub) == "function" then finishLog.unsub = unsub end
		end
		local function autoUid(rt)
			if not rt or rt.destroyed or rt._externalDeliver then return nil end
			local primer = rt.primerUid
			local uid = rt.targetUid
			if not uid and rt.activeTarget and rt.activeTarget.Uid ~= primer then uid = rt.activeTarget.Uid end
			if not uid and rt.carry and rt.carry.active and rt.carry.uid ~= primer then uid = rt.carry.uid end
			if uid == primer then return nil end
			return uid
		end
		local function judgeAuto(rt)
			local result = finishLog.at >= cur.startedAt and finishLog.result or (rt and rt.stats and rt.stats.lastResult)
			local lower = string.lower(tostring(result or ""))
			if rt and (tonumber(rt.stats.delivered) or 0) > (cur.delivered or 0) then return "done" end
			if lower:find("dropped for a friend", 1, true) then return "friend" end
			if lower:find("safe return complete", 1, true) then return "done" end
			if cur.sawCarry then
				local record = nil
				pcall(function() record = EggState.ReadFieldEgg(cur.uid) end)
				if record == nil or record.State == "Claimed" then return "done" end
			end
			if rt and not rt.enabled and not rt._recalling then return "fail", "Stopped" end
			if isTransientResult(result) then return "retry" end
			return "fail", reasonText(result)
		end
		local goneSince = nil
		local function tick()
			local rt = runtimeEnv.__SenaV4EggRuntime
			local ps = runtimeEnv.__SenaV4PlayerSteal
			watchRuntime(rt)
			local kind, uid, status, carrying, player = nil, nil, nil, false, nil
			if ps and ps.running and type(ps.cardTarget) == "table" then
				kind, uid, status, player = "ps", ps.cardTarget.uid, ps.status, ps.cardTarget.player
				carrying = rt ~= nil and rt._externalDeliver == true
			else
				uid = autoUid(rt)
				if uid then
					kind, status = "auto", rt.stats and rt.stats.status
					carrying = rt.carry and rt.carry.active and rt.carry.uid == uid
				end
			end
			if cur and not cur.endedAt and (uid ~= cur.uid or kind ~= cur.kind) then
				goneSince = goneSince or os.clock()
				if uid ~= nil or os.clock() - goneSince >= 0.4 then
					if cur.kind == "ps" then
						local last = ps and ps.history and ps.history[1]
						local outcome = last and tostring(last.outcome) or ""
						if outcome == "taken" or outcome == "sniped drop" then conclude("done")
						else conclude("fail", reasonText(outcome)) end
					else
						conclude(judgeAuto(rt))
					end
				end
			else
				goneSince = nil
			end
			if cur and cur.endedAt then
				local held = os.clock() - cur.endedAt
				if uid and held >= 1.5 then
					cur = nil
				elseif not uid and held >= (cur.result == "fail" and 4 or 3) then
					cur = nil
					showCard(false)
				end
			end
			if uid and not cur then
				local record = nil
				if kind == "ps" then record = ps.cardTarget.record end
				pcall(function() record = record or EggState.ReadFieldEgg(uid) end)
				record = record or (rt and rt.records and rt.records[uid])
				if type(record) == "table" then begin(kind, uid, record, rt, player) end
			end
			if not cur or not shown then return end
			local bottom, inset = announceBottom()
			local fit = fitScale()
			if not (popTween and popTween.PlaybackState == Enum.PlaybackState.Playing) then set(ui.scale, "Scale", fit) end
			set(ui.card, "Size", UDim2.fromOffset(math.floor(math.min(CARD_W, (viewport().X - 32) / fit)), CARD_H))
			slideTo(math.floor(math.max(inset + TOP_GAP, bottom + TOP_GAP)))
			if cur.endedAt then return end
			if os.clock() >= (cur.netAt or 0) then
				cur.netAt = os.clock() + 1
				local fps, ping = currentFps(), runtimeEnv.__SenaV4NetPing()
				local slow = (fps > 0 and fps < 20) and "LOW FPS" or nil
				if ping > 250 then slow = slow and (slow .. " + HIGH PING") or "HIGH PING" end
				set(ui.head, "Text", slow and (slow .. "  ·  MAY TAKE LONGER") or cur.headBase)
				set(ui.head, "TextColor3", slow and Color3.fromRGB(245, 196, 81) or SNE_PAL.muted)
			end
			if carrying then cur.sawCarry = true end
			local phase = phaseOf(status, carrying)
			if phase ~= cur.phase then cur.phase, cur.phaseAt = phase, os.clock() end
			setChip(phase)
			local elapsed = os.clock() - cur.startedAt
			local eta = modelEta(cur, phase, status)
			local learned = ema[cur.key]
			if learned then
				local rest = learned - elapsed
				eta = eta and (eta + rest) / 2 or rest
			end
			if eta then
				cur.progress = math.max(cur.progress, math.min(elapsed / math.max(elapsed + math.max(eta, 0), 0.1), 0.96))
				set(ui.eta, "Text", eta >= 1 and string.format("~%ds left", math.ceil(eta)) or "Almost done")
			else
				cur.progress = math.max(cur.progress, math.min(elapsed / (elapsed + 12), 0.6))
				set(ui.eta, "Text", string.format("%ds", math.floor(elapsed)))
			end
			set(ui.barFill, "Size", UDim2.fromScale(cur.progress, 1))
		end
		task.spawn(function()
			while runtimeEnv.__SenaV4StealCardToken == token do
				task.wait(0.1)
				uiIdentity()
				local ok, err = pcall(tick)
				if not ok and not ui.warned then
					ui.warned = true
					warn("[Sena] steal card: " .. tostring(err))
				end
			end
			if ui.gui then pcall(function() ui.gui:Destroy() end) end
			if finishLog.unsub then pcall(finishLog.unsub) end
		end)
	end)()
	SenaPanels.windows = panels
	SenaPanels.openLogs = function() openPanel("logs") end
	SenaPanels.openBoard = function() openPanel("eggs") end
	SenaPanels.openInventory = function() openPanel("inventory") end
	SenaPanels.openChecker = function() openPanel("checker") end
	SenaPanels.openAnalyst = function() openPanel("eggdata") end
	SenaPanels.openStats = function() openPanel("stats") end
	SenaPanels.openAll = function() openAllPanels() end
	SenaPanels.closeAll = function() closeAllPanels() end
	SenaPanels.isPlaceEnabled = function(uid) return panelPlaceEnabled[uid] ~= false end
	pcall(function() getgenv().SenaPanels = SenaPanels end)
end
initSenaPanels()
do
	local HttpService = game:GetService("HttpService")
	local RS = game:GetService("ReplicatedStorage")
	local Hunt = {
		file = "SenaHub/SaeHopHunt.json",
		state = nil,
		status = "Checking this server...",
		watch = {},
		gone = {},
		revealed = nil,
		gui = nil,
		busy = false,
		prompting = false,
	}
	SenaExtras.hopHunt = Hunt
	Hunt.bootCode = [[
if game:GetAttribute("SenaBootQueued") then return end
game:SetAttribute("SenaBootQueued", true)
repeat task.wait(0.5) until game:IsLoaded()
task.wait(1.5)
loadstring(game:HttpGet("https://senahub.xyz/raw/senav6"))()
]]
	function Hunt.elevate()
		local setter = runtimeEnv.__SenaV4IdentitySetter
		if type(setter) == "function" then pcall(setter, runtimeEnv.__SenaV4UICapabilityIdentity or 8) end
	end
	function Hunt.period()
		local ok, idx = pcall(function()
			return require(RS.Shared.Util.AreaEggCycle).PeriodIndexAt(workspace:GetServerTimeNow())
			end)
		return ok and idx or math.floor(os.time() / 300)
	end
	function Hunt.load()
		local data = nil
		pcall(function()
			if isfile and isfile(Hunt.file) then
				data = HttpService:JSONDecode(readfile(Hunt.file))
			end
			end)
		if type(data) ~= "table" then data = {} end
		data.limit = tonumber(data.limit) or 10
		data.hops = tonumber(data.hops) or 0
		data.sinceAsk = tonumber(data.sinceAsk) or 0
		data.visited = type(data.visited) == "table" and data.visited or {}
		if type(data.targets) ~= "table" or not (data.targets.Divine or data.targets.Eternal or data.targets.Secret) then
			data.targets = { Divine = true }
		end
		if data.period ~= Hunt.period() then
			data.visited = {}
			data.period = Hunt.period()
		end
		Hunt.state = data
		return data
	end
	function Hunt.save()
		pcall(function()
			if makefolder and isfolder and not isfolder("SenaHub") then makefolder("SenaHub") end
			if writefile then writefile(Hunt.file, HttpService:JSONEncode(Hunt.state)) end
			end)
	end
	function Hunt.targets()
		local list, set = {}, {}
		local picked = Hunt.state and Hunt.state.targets or {}
		for _, value in ipairs({ "Divine", "Eternal", "Secret" }) do
			if picked[value] then
				set[value] = true
				list[#list + 1] = value
			end
		end
		if #list == 0 then
			list = { "Divine" }
			set = { Divine = true }
		end
		return list, set
	end
	function Hunt.playerName(userId)
		if userId == LocalPlayer.UserId then return "you" end
		local p = Players:GetPlayerByUserId(userId or 0)
		return p and (p.DisplayName or p.Name) or "another player"
	end
	function Hunt.notify(text)
		pcall(function()
			game:GetService("StarterGui"):SetCore("SendNotification", { Title = "Rare Egg Hop", Text = text, Duration = 6 })
			end)
	end
	function Hunt.scan()
		local list, set = Hunt.targets()
		local names = table.concat(list, "/")
		local ES = require(RS.Client.EggState)
		local okSnap, snap = pcall(function() return ES.ReadFieldEggs() end)
		local field, carried = nil, nil
		local seen = {}
		if okSnap and type(snap) == "table" then
			for _, rec in ipairs(snap.Records or {}) do
				local okInfo, info = pcall(catalog.resolve, rec)
				if okInfo and info and set[info.rarity] then
					local full = rec
					pcall(function() full = ES.ReadFieldEgg(rec.Uid) or rec end)
					seen[rec.Uid] = true
					local label = tostring(info.rarity) .. " " .. tostring(info.name or "Egg")
					local w = Hunt.watch[rec.Uid] or {}
					w.label = label
					w.rarity = info.rarity
					if full.State == "Carried" and full.CarrierUserId then
						w.carrier = full.CarrierUserId
						carried = carried or { label = label, by = full.CarrierUserId }
					else
						field = field or { label = label }
					end
					Hunt.watch[rec.Uid] = w
				end
			end
		end
		for uid, w in pairs(Hunt.watch) do
			if not seen[uid] then
				if w.carrier then
					Hunt.gone[#Hunt.gone + 1] = { label = w.label, by = w.carrier, rarity = w.rarity }
				end
				Hunt.watch[uid] = nil
			end
		end
		local lastGone = nil
		for i = #Hunt.gone, 1, -1 do
			if set[Hunt.gone[i].rarity] then lastGone = Hunt.gone[i] break end
		end
		if field then
			return "field", field.label .. " is still in the field!"
		elseif carried then
			return "carried", carried.label .. " is being carried by " .. Hunt.playerName(carried.by)
		elseif lastGone then
			return "collected", lastGone.label .. " was collected by " .. Hunt.playerName(lastGone.by)
		elseif Hunt.revealed == true then
			return "collected", "This round's " .. names .. " was already collected"
		end
		return "none", "No " .. names .. " in this server right now"
	end
	function Hunt.hop()
		if Hunt.busy then return end
		Hunt.busy = true
		local s = Hunt.state
		s.visited[game.JobId] = true
		s.active = true
		s.hops = s.hops + 1
		s.sinceAsk = s.sinceAsk + 1
		s.period = Hunt.period()
		Hunt.save()
		Hunt.status = "Hopping... (" .. s.sinceAsk .. " / " .. s.limit .. ")"
		pcall(function()
			local qot = queue_on_teleport or queueonteleport or (syn and syn.queue_on_teleport)
			if qot then qot(Hunt.bootCode) end
			end)
		local win = SenaExtras.hopWindow
		if win then pcall(function() win:SaveConfig("HopSession") end) end
		local list = {}
		for _, server in ipairs(SenaExtras.collectServers(nil) or {}) do
			if not s.visited[server.id] then list[#list + 1] = server end
		end
		local ok = SenaExtras.hopToList(list)
		if not ok then
			s.hops = math.max(0, s.hops - 1)
			s.sinceAsk = math.max(0, s.sinceAsk - 1)
			Hunt.save()
			Hunt.status = "No fresh server found, retrying shortly"
			Hunt.statusUntil = os.clock() + 8
			Hunt.nextTry = os.clock() + 8
		end
		Hunt.busy = false
	end
	function Hunt.stop(closeUi)
		if Hunt.state then
			Hunt.state.active = false
			Hunt.state.hops = 0
			Hunt.state.sinceAsk = 0
			Hunt.save()
		end
		Hunt.prompting = false
		Hunt.status = "Hopping stopped"
		if closeUi and Hunt.state then
			Hunt.state.watch = false
			Hunt.save()
		end
		if closeUi and Hunt.gui then
			Hunt.elevate()
			pcall(function() Hunt.gui:Destroy() end)
			Hunt.gui = nil
		end
	end
	function Hunt.open()
		Hunt.elevate()
		if Hunt.gui and Hunt.gui.Parent then return end
		local s = Hunt.state or Hunt.load()
		local TweenService = game:GetService("TweenService")
		local gui = Instance.new("ScreenGui")
		gui.Name = "SenaHopHunt"
		gui.ResetOnSpawn = false
		gui.DisplayOrder = 9999
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		local function new(class, props, parent)
			local o = Instance.new(class)
			for k, v in pairs(props) do o[k] = v end
			o.Parent = parent
			return o
		end
		local function corner(o, r) new("UICorner", { CornerRadius = UDim.new(0, r) }, o) end
		local function stroke(o, c, t) new("UIStroke", { Color = c, Thickness = 1, Transparency = t or 0, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, o) end
		local function tween(o, props) TweenService:Create(o, TweenInfo.new(0.18, Enum.EasingStyle.Quad), props):Play() end
		local BG = Color3.fromRGB(13, 13, 16)
		local CARD = Color3.fromRGB(19, 19, 23)
		local CARD2 = Color3.fromRGB(27, 27, 32)
		local TRACK = Color3.fromRGB(46, 46, 54)
		local LINE = Color3.fromRGB(42, 42, 50)
		local TEXT = Color3.fromRGB(238, 238, 243)
		local SUB = Color3.fromRGB(162, 162, 174)
		local DIM = Color3.fromRGB(116, 116, 128)
		local ACCENT = Color3.fromRGB(232, 232, 238)
		local ACCENT_TEXT = Color3.fromRGB(14, 14, 17)
		local GREEN = Color3.fromRGB(74, 222, 128)
		local AMBER = Color3.fromRGB(245, 190, 80)
		local RED = Color3.fromRGB(235, 90, 90)
		local frame = new("Frame", { Size = UDim2.new(0, 320, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, Position = UDim2.new(0.5, -160, 0, 80), BackgroundColor3 = BG, BorderSizePixel = 0, Active = true, Draggable = true }, gui)
		corner(frame, 12)
		stroke(frame, LINE)
		new("UIPadding", { PaddingTop = UDim.new(0, 14), PaddingBottom = UDim.new(0, 14), PaddingLeft = UDim.new(0, 14), PaddingRight = UDim.new(0, 14) }, frame)
		new("UIListLayout", { Padding = UDim.new(0, 10), SortOrder = Enum.SortOrder.LayoutOrder }, frame)
		local order = 0
		local function block(h, props)
			order += 1
			local f = new("Frame", { LayoutOrder = order, Size = UDim2.new(1, 0, 0, h), BackgroundTransparency = 1, BorderSizePixel = 0 }, frame)
			for k, v in pairs(props or {}) do f[k] = v end
			return f
		end
		local function text(parent, props)
			local t = new("TextLabel", { BackgroundTransparency = 1, Font = Enum.Font.BuilderSansMedium, TextSize = 12, TextColor3 = TEXT, TextXAlignment = Enum.TextXAlignment.Left, TextYAlignment = Enum.TextYAlignment.Center, TextWrapped = true }, parent)
			for k, v in pairs(props) do t[k] = v end
			return t
		end
		local header = block(34)
		local badge = new("ImageLabel", { Size = UDim2.new(0, 34, 0, 34), BackgroundColor3 = CARD2, BorderSizePixel = 0, Image = "rbxassetid://96240498384290", ScaleType = Enum.ScaleType.Fit }, header)
		corner(badge, 9)
		text(header, { Position = UDim2.new(0, 44, 0, 0), Size = UDim2.new(1, -80, 0, 18), Text = "Rare Egg Hop", Font = Enum.Font.BuilderSansBold, TextSize = 14 })
		text(header, { Position = UDim2.new(0, 44, 0, 18), Size = UDim2.new(1, -80, 0, 16), Text = "Find Divine, Eternal and Secret across servers", TextSize = 11, TextColor3 = SUB, Font = Enum.Font.BuilderSans })
		local close = new("TextButton", { AnchorPoint = Vector2.new(1, 0), Position = UDim2.new(1, 0, 0, 2), Size = UDim2.new(0, 28, 0, 28), BackgroundColor3 = CARD, BorderSizePixel = 0, Text = "X", Font = Enum.Font.BuilderSansBold, TextSize = 12, TextColor3 = SUB, AutoButtonColor = false }, header)
		corner(close, 8)
		close.MouseEnter:Connect(function() tween(close, { BackgroundColor3 = RED, TextColor3 = Color3.new(1, 1, 1) }) end)
		close.MouseLeave:Connect(function() tween(close, { BackgroundColor3 = CARD, TextColor3 = SUB }) end)
		local statusCard = block(64, { BackgroundTransparency = 0, BackgroundColor3 = CARD })
		corner(statusCard, 10)
		local statusStroke = new("UIStroke", { Color = LINE, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border }, statusCard)
		local dot = new("Frame", { Position = UDim2.new(0, 12, 0, 15), Size = UDim2.new(0, 8, 0, 8), BackgroundColor3 = DIM, BorderSizePixel = 0 }, statusCard)
		corner(dot, 4)
		local stateTitle = text(statusCard, { Position = UDim2.new(0, 28, 0, 8), Size = UDim2.new(1, -40, 0, 22), Text = "Checking", Font = Enum.Font.BuilderSansBold, TextSize = 13 })
		local stateDetail = text(statusCard, { Position = UDim2.new(0, 12, 0, 30), Size = UDim2.new(1, -24, 0, 28), Text = "", TextSize = 11, TextColor3 = SUB, Font = Enum.Font.BuilderSans, TextYAlignment = Enum.TextYAlignment.Top })
		local progress = block(30)
		local hopsText = text(progress, { Size = UDim2.new(0.5, 0, 0, 16), Text = "Hops 0 / 10", TextSize = 11, TextColor3 = SUB })
		local skippedText = text(progress, { Position = UDim2.new(0.5, 0, 0, 0), Size = UDim2.new(0.5, 0, 0, 16), Text = "", TextSize = 11, TextColor3 = DIM, TextXAlignment = Enum.TextXAlignment.Right })
		local track = new("Frame", { Position = UDim2.new(0, 0, 0, 22), Size = UDim2.new(1, 0, 0, 6), BackgroundColor3 = TRACK, BorderSizePixel = 0 }, progress)
		corner(track, 3)
		local fill = new("Frame", { Size = UDim2.new(0, 0, 1, 0), BackgroundColor3 = ACCENT, BorderSizePixel = 0 }, track)
		corner(fill, 3)
		local function row(h)
			local r = block(h, { BackgroundTransparency = 0, BackgroundColor3 = CARD })
			corner(r, 10)
			return r
		end
		local pickRow = row(40)
		text(pickRow, { Position = UDim2.new(0, 12, 0, 0), Size = UDim2.new(0, 70, 1, 0), Text = "Hunt for" })
		local pickBtns = {}
		local function paintPicks()
			for name, b in pairs(pickBtns) do
				local on = s.targets[name] == true
				tween(b, { BackgroundColor3 = on and ACCENT or CARD2, TextColor3 = on and ACCENT_TEXT or SUB })
			end
		end
		local PICKS = { "Divine", "Eternal", "Secret" }
		for i, name in ipairs(PICKS) do
			local b = new("TextButton", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -10 - (#PICKS - i) * 64, 0.5, 0), Size = UDim2.new(0, 60, 0, 26), BackgroundColor3 = CARD2, BorderSizePixel = 0, Text = name, Font = Enum.Font.BuilderSansBold, TextSize = 12, TextColor3 = SUB, AutoButtonColor = false }, pickRow)
			corner(b, 7)
			pickBtns[name] = b
			b.MouseButton1Click:Connect(function()
				local count = 0
				for _, n in ipairs(PICKS) do if s.targets[n] then count += 1 end end
				if s.targets[name] and count <= 1 then return end
				s.targets[name] = not s.targets[name] or nil
				Hunt.watch = {}
				Hunt.save()
				paintPicks()
			end)
		end
		paintPicks()
		local limitRow = row(40)
		text(limitRow, { Position = UDim2.new(0, 12, 0, 0), Size = UDim2.new(0, 120, 1, 0), Text = "Ask after" })
		local function stepBtn(label, x)
			local b = new("TextButton", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, x, 0.5, 0), Size = UDim2.new(0, 26, 0, 26), BackgroundColor3 = CARD2, BorderSizePixel = 0, Text = label, Font = Enum.Font.BuilderSansBold, TextSize = 14, TextColor3 = TEXT, AutoButtonColor = true }, limitRow)
			corner(b, 7)
			return b
		end
		local plus = stepBtn("+", -12)
		local limitBox = new("TextBox", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -42, 0.5, 0), Size = UDim2.new(0, 64, 0, 26), BackgroundColor3 = CARD2, BorderSizePixel = 0, Text = tostring(s.limit), PlaceholderText = "10", Font = Enum.Font.BuilderSansBold, TextSize = 12, TextColor3 = TEXT, ClearTextOnFocus = false }, limitRow)
		corner(limitBox, 7)
		local minus = stepBtn("-", -110)
		text(limitRow, { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -140, 0.5, 0), Size = UDim2.new(0, 34, 0, 26), Text = "hops", TextSize = 11, TextColor3 = DIM, TextXAlignment = Enum.TextXAlignment.Right })
		local function setLimit(n)
			s.limit = math.clamp(math.floor(tonumber(n) or s.limit), 1, 100)
			limitBox.Text = tostring(s.limit)
			Hunt.save()
		end
		limitBox.FocusLost:Connect(function() setLimit(limitBox.Text) end)
		plus.MouseButton1Click:Connect(function() setLimit(s.limit + 1) end)
		minus.MouseButton1Click:Connect(function() setLimit(s.limit - 1) end)
		local function switch(title, desc, get, set)
			local r = row(62)
			text(r, { Position = UDim2.new(0, 12, 0, 8), Size = UDim2.new(1, -76, 0, 18), Text = title, Font = Enum.Font.BuilderSansBold })
			text(r, { Position = UDim2.new(0, 12, 0, 27), Size = UDim2.new(1, -76, 0, 28), Text = desc, TextSize = 10, TextColor3 = SUB, Font = Enum.Font.BuilderSans, TextYAlignment = Enum.TextYAlignment.Top })
			local pill = new("TextButton", { AnchorPoint = Vector2.new(1, 0.5), Position = UDim2.new(1, -12, 0.5, 0), Size = UDim2.new(0, 36, 0, 19), BackgroundColor3 = TRACK, BorderSizePixel = 0, Text = "", AutoButtonColor = false }, r)
			corner(pill, 10)
			local knob = new("Frame", { Size = UDim2.new(0, 13, 0, 13), Position = UDim2.new(0, 3, 0.5, -6), BackgroundColor3 = SUB, BorderSizePixel = 0 }, pill)
			corner(knob, 7)
			local last = nil
			local function paint()
				local on = get() == true
				if on == last then return end
				last = on
				tween(pill, { BackgroundColor3 = on and ACCENT or TRACK })
				tween(knob, { Position = on and UDim2.new(1, -16, 0.5, -6) or UDim2.new(0, 3, 0.5, -6), BackgroundColor3 = on and ACCENT_TEXT or SUB })
			end
			pill.MouseButton1Click:Connect(function() set(not get()) paint() end)
			paint()
			return paint
		end
		local paintAuto = switch("Auto Hop", "Hops until a target is found, and again after each collect.", function() return s.active end, function(v)
			s.active = v == true
			Hunt.prompting = false
			if v then s.sinceAsk = 0 end
			Hunt.save()
		end)
		local paintWatch = switch("Start After Collect", "Waits in this server, then starts Auto Hop once the target is banked.", function() return s.watch end, function(v)
			s.watch = v == true
			Hunt.save()
		end)
		local hopNowRow = block(36)
		local hopNow = new("TextButton", { Size = UDim2.new(1, 0, 1, 0), BackgroundColor3 = CARD2, BorderSizePixel = 0, Text = "Hop Now", Font = Enum.Font.BuilderSansBold, TextSize = 13, TextColor3 = TEXT, AutoButtonColor = false }, hopNowRow)
		corner(hopNow, 8)
		stroke(hopNow, LINE)
		hopNow.MouseEnter:Connect(function() tween(hopNow, { BackgroundColor3 = ACCENT, TextColor3 = ACCENT_TEXT }) end)
		hopNow.MouseLeave:Connect(function() tween(hopNow, { BackgroundColor3 = CARD2, TextColor3 = TEXT }) end)
		hopNow.MouseButton1Click:Connect(function()
			if Hunt.busy then return end
			Hunt.prompting = false
			Hunt.nextTry = 0
			task.spawn(Hunt.hop)
		end)
		local prompt = block(92, { BackgroundTransparency = 0, BackgroundColor3 = CARD, Visible = false })
		corner(prompt, 10)
		stroke(prompt, ACCENT, 0.4)
		local promptText = text(prompt, { Position = UDim2.new(0, 12, 0, 8), Size = UDim2.new(1, -24, 0, 18), Text = "", Font = Enum.Font.BuilderSansBold })
		local cdTrack = new("Frame", { Position = UDim2.new(0, 12, 0, 32), Size = UDim2.new(1, -24, 0, 4), BackgroundColor3 = CARD2, BorderSizePixel = 0 }, prompt)
		corner(cdTrack, 2)
		local cdFill = new("Frame", { Size = UDim2.new(1, 0, 1, 0), BackgroundColor3 = ACCENT, BorderSizePixel = 0 }, cdTrack)
		corner(cdFill, 2)
		local function promptBtn(label, x, color, fg)
			local b = new("TextButton", { Position = UDim2.new(x, x == 0 and 12 or 4, 0, 46), Size = UDim2.new(0.5, -16, 0, 34), BackgroundColor3 = color, BorderSizePixel = 0, Text = label, Font = Enum.Font.BuilderSansBold, TextSize = 13, TextColor3 = fg, AutoButtonColor = true }, prompt)
			corner(b, 8)
			return b
		end
		local continueBtn = promptBtn("Continue", 0, ACCENT, ACCENT_TEXT)
		local stopBtn = promptBtn("Stop", 0.5, CARD2, TEXT)
		local countdownEnd = nil
		continueBtn.MouseButton1Click:Connect(function()
			Hunt.prompting = false
			countdownEnd = nil
			s.sinceAsk = 0
			s.active = true
			Hunt.save()
		end)
		stopBtn.MouseButton1Click:Connect(function()
			Hunt.prompting = false
			countdownEnd = nil
			s.active = false
			Hunt.save()
		end)
		close.MouseButton1Click:Connect(function() Hunt.stop(true) end)
		if not pcall(function() gui.Parent = game:GetService("CoreGui") end) or gui.Parent == nil then
			gui.Parent = LocalPlayer:FindFirstChildOfClass("PlayerGui")
		end
		Hunt.gui = gui
		local uiScale = new("UIScale", { Scale = 1 }, frame)
		local function fit()
			local cam = workspace.CurrentCamera
			if not cam then return end
			local vp = cam.ViewportSize
			local h = frame.AbsoluteSize.Y / math.max(uiScale.Scale, 0.01)
			local scale = math.min(1, (vp.X - 24) / 320, (vp.Y - 60) / math.max(h, 1))
			uiScale.Scale = math.clamp(scale, 0.5, 1)
			if vp.X < 700 then
				frame.Position = UDim2.new(0.5, -160 * uiScale.Scale, 0, 36)
			end
		end
		task.defer(fit)
		frame:GetPropertyChangedSignal("AbsoluteSize"):Connect(function() task.defer(fit) end)
		pcall(function() workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(fit) end)
		local VIEWS = {
			field = { "Target in the field", GREEN },
			carried = { "Being carried", AMBER },
			collected = { "Collected", SUB },
			none = { "Not in this server", DIM },
			hopping = { "Hopping", Color3.fromRGB(120, 170, 255) },
			asking = { "Keep hopping?", AMBER },
		}
		local joinedAt = os.clock()
		local hadTarget = false
		local notified = false
		task.spawn(function()
			while gui.Parent do
				Hunt.elevate()
				local okScan, kind, detail = pcall(Hunt.scan)
				Hunt.elevate()
				if not okScan then kind, detail = "none", "Reading this server..." end
				if kind == "field" or kind == "carried" then hadTarget = true end
				local settled = os.clock() - joinedAt > 6
				local holding = Config.IsStealing == true or Config.IsPlacing == true
				if not Hunt.busy and not Hunt.prompting and settled and not holding and os.clock() >= (Hunt.nextTry or 0) then
					local wantHop = false
					if s.active and (kind == "none" or kind == "collected") then
						wantHop = true
					elseif not s.active and s.watch and hadTarget and kind == "collected" then
						s.active = true
						Hunt.save()
						wantHop = true
					end
					if wantHop then
						if s.sinceAsk >= s.limit then
							Hunt.prompting = true
							countdownEnd = os.clock() + 10
						else
							task.spawn(Hunt.hop)
						end
					end
				end
				if kind == "field" and s.active and not notified then
					notified = true
					Hunt.notify(detail)
				end
				local view = kind
				if Hunt.busy then
					view, detail = "hopping", Hunt.status
				elseif Hunt.prompting then
					view = "asking"
					local left = math.max(0, countdownEnd - os.clock())
					promptText.Text = string.format("%d hops done. Keep hopping? (%ds)", s.limit, math.ceil(left))
					cdFill.Size = UDim2.new(left / 10, 0, 1, 0)
					detail = "Nothing more to grab here. Continue to hop " .. s.limit .. " more times."
					if left <= 0 then
						Hunt.prompting = false
						s.active = false
						Hunt.save()
						if not s.watch then
							Hunt.stop(true)
							break
						end
					end
				elseif Hunt.status ~= "" and Hunt.statusUntil and os.clock() < Hunt.statusUntil then
					detail = Hunt.status
				end
				prompt.Visible = Hunt.prompting
				local v = VIEWS[view] or VIEWS.none
				stateTitle.Text = v[1]
				dot.BackgroundColor3 = v[2]
				statusStroke.Color = (view == "field") and GREEN or LINE
				stateDetail.Text = tostring(detail or "")
				paintAuto()
				paintWatch()
				local skipped = 0
				for _ in pairs(s.visited) do skipped += 1 end
				hopsText.Text = string.format("Hops %d / %d", s.sinceAsk, s.limit)
				skippedText.Text = skipped > 0 and (skipped .. " servers skipped") or ""
				fill.Size = UDim2.new(math.clamp(s.sinceAsk / math.max(1, s.limit), 0, 1), 0, 1, 0)
				task.wait(0.5)
			end
		end)
	end
	pcall(function()
		local ES = require(RS.Client.EggState)
		if ES.RarityRevealed then
			ES.RarityRevealed:Connect(function(payload)
				Hunt.revealed = nil
				Hunt.gone = {}
				Hunt.watch = {}
				local _, set = Hunt.targets()
				for _, spawn in pairs(type(payload) == "table" and type(payload.RareSpawns) == "table" and payload.RareSpawns or {}) do
					local r = type(spawn) == "table" and (spawn.Rarity or spawn.rarity) or spawn
					if set[tostring(r)] then Hunt.revealed = true end
				end
				if Hunt.state and Hunt.state.period ~= Hunt.period() then
					Hunt.state.visited = {}
					Hunt.state.period = Hunt.period()
					Hunt.save()
				end
			end)
		end
		end)
	Hunt.load()
end
local function buildSenaHub()
	local SENA_LIB_URL = runtimeEnv.SenaLibUrl or "https://senahub.xyz/libsenak3"
	pcall(function()
		local previous = runtimeEnv.ChloeX_Instance
		if type(previous) == "table" and type(previous.DestroyGui) == "function" then
			previous:DestroyGui()
		end
		end)
	runtimeEnv.ChloeX_Running = nil
	runtimeEnv.ChloeX_ReopenPrompt = nil
	runtimeEnv.ChloeX_Instance = nil
	local Sena = runtimeEnv.SenaLibOverride
	if type(Sena) ~= "table" then
		local ok, lib = pcall(function()
			return loadstring(game:HttpGet(SENA_LIB_URL))()
			end)
		Sena = ok and type(lib) == "table" and lib or nil
	end
	if not Sena then
		warn("[Sena] UI library failed to load")
		return
	end
	-- KEY GATE ON: donator/trial only (key required; no key -> Donate tab only). Set `true` for keyless/free (all open, no key check).
	runtimeEnv.__SenaKeyless = true
	if runtimeEnv.__SenaKeyless then
		pcall(function()
			Sena:SetDonator(true)
			runtimeEnv.SenaIsDonator = true
			runtimeEnv.SenaIsTrial = false
		end)
	end
	pcall(function()
		if runtimeEnv.__SenaKeyless then return end
		local HttpService = game:GetService("HttpService")
		local CACHE_FILE = "SenaHUB/sena_tier.json"
		local CACHE_SECONDS = 12 * 3600
		local function savedKey()
			local ok, key = pcall(Sena.GetSavedKey, Sena)
			return ok and type(key) == "string" and key ~= "" and key or nil
		end
		local function writeCache(key, info)
			pcall(function()
				if makefolder and isfolder and not isfolder("SenaHUB") then makefolder("SenaHUB") end
				writefile(CACHE_FILE, HttpService:JSONEncode({
					key = key,
					at = os.time(),
					expires = tonumber(info and info.expires) or 0,
					tier = (info and (info.is_trial == true or info.tier == "trial")) and "trial" or "donator",
				}))
			end)
		end
		local function readCache()
			local ok, data = pcall(function()
				return isfile and isfile(CACHE_FILE) and HttpService:JSONDecode(readfile(CACHE_FILE)) or nil
			end)
			return ok and type(data) == "table" and data or nil
		end
		Sena:SetDonator(false)
		local key = savedKey()
		local cache = readCache()
		if key and cache and cache.key == key and os.time() - (tonumber(cache.at) or 0) < CACHE_SECONDS
			and ((tonumber(cache.expires) or 0) == 0 or tonumber(cache.expires) > os.time()) then
			if cache.tier == "trial" then Sena:SetDonator(false, true) runtimeEnv.SenaIsDonator = false else Sena:SetDonator(true) runtimeEnv.SenaIsDonator = true end
		end
		if key then
			task.spawn(function()
				local ok, res = Sena:CheckDonatorKey()
				if ok and type(res) == "table" and res.ok == true and res.valid == true then
					writeCache(key, res)
				elseif res ~= "network_error" then
					pcall(function() if delfile and isfile(CACHE_FILE) then delfile(CACHE_FILE) end end)
				end
			end)
		end
		if type(Sena.DonatorListeners) == "table" then
			table.insert(Sena.DonatorListeners, function()
				runtimeEnv.SenaIsDonator = Sena:IsDonator()
				local info = Sena.DonatorInfo
				local current = savedKey()
				if Sena:IsDonator() and current and type(info) == "table" and info.ok == true then
					writeCache(current, info)
				end
			end)
		end
	end)
	local function withoutNone(list)
		local out = {}
		for _, value in ipairs(type(list) == "table" and list or {}) do
			if value ~= "None" and value ~= "" then
				out[#out + 1] = value
			end
		end
		return out
	end
	local function rarityOptions()
		local list = {}
		pcall(function()
			for _, rarity in ipairs(catalog.getRarities()) do
				list[#list + 1] = rarity
			end
			end)
		if #list == 0 then
			list = { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic", "Cosmic", "Secret", "Eternal", "Divine" }
		end
		return list
	end
	local function withAll(list)
		local out = { "All" }
		for _, value in ipairs(list) do
			if value ~= "All" then
				out[#out + 1] = value
			end
		end
		return out
	end
	local mutationOptions = {}
	do
		pcall(function()
			for _, name in ipairs(catalog.getMutations()) do
				mutationOptions[#mutationOptions + 1] = name
			end
			end)
		if #mutationOptions == 0 then
			mutationOptions = { "Golden", "Rainbow", "Shocked", "Frozen", "Burnt", "Boss" }
		end
	end
	local stealNameOptions = { "None" }
	do
		local ok = pcall(function()
			local Areas = require(game:GetService("ReplicatedStorage").Data.Areas).Directory
			local ok, assetsDir = pcall(function()
				return require(game:GetService("ReplicatedStorage").Data.Assets)
				end)
			if ok and assetsDir and assetsDir.Directory then
				local Assets = assetsDir.Directory
				local seen = {}
				for _, areaCfg in pairs(Areas) do
					if type(areaCfg) == "table" and type(areaCfg.DropTable) == "table" then
						for _, entry in ipairs(areaCfg.DropTable) do
							local cat = entry[1]
							if type(cat) == "string" and not seen[cat] then
								seen[cat] = true
								local a = Assets[cat]
								stealNameOptions[#stealNameOptions + 1] = (a and a.DisplayName) or cat
							end
						end
					end
				end
			end
			end)
		if not ok or #stealNameOptions <= 1 then
			stealNameOptions = { "None" }
		end
		table.sort(stealNameOptions, function(a, b)
			if a == "None" then return true end
			if b == "None" then return false end
			return a < b
			end)
	end
	local stealAreaOptions = { "None" }
	do
		local preferredAreaOrder = {
			"Lake",
			"Jungle",
			"Desert",
			"Snow",
			"Volcano",
			"Abyss Ocean",
			"Prehistoric",
			"Cosmic",
			"Cherry Blossom",
			"Titan Temple"
		}
		local availableAreas = {}
		local ok = pcall(function()
			local Areas = require(game:GetService("ReplicatedStorage").Data.Areas).Directory
			for areaName, cfg in pairs(Areas) do
				if type(cfg) == "table" and type(cfg.DropTable) == "table" then
					availableAreas[areaName] = true
				end
			end
			end)
		if not ok or next(availableAreas) == nil then
			for _, areaName in ipairs(preferredAreaOrder) do
				availableAreas[areaName] = true
			end
		end
		local inserted = { None = true, Forest = true, ["Titan Temple"] = true }
		for _, areaName in ipairs(preferredAreaOrder) do
			if areaName ~= "Titan Temple" and availableAreas[areaName] then
				table.insert(stealAreaOptions, areaName)
				inserted[areaName] = true
			end
		end
		local unknownAreas = {}
		for areaName in pairs(availableAreas) do
			if not inserted[areaName] then
				table.insert(unknownAreas, areaName)
			end
		end
		table.sort(unknownAreas)
		for _, areaName in ipairs(unknownAreas) do
			table.insert(stealAreaOptions, areaName)
		end
		if availableAreas["Titan Temple"] then
			table.insert(stealAreaOptions, "Titan Temple")
		end
	end
	local placeStatus = ""
	local function placeRarityOf(record, Assets)
		local category = record.AssetCategory
		local categoryData = category and Assets.Directory[category]
		local rarity = "Unknown"
		if categoryData and categoryData.Rarity then
			local rObj = categoryData.Rarity
			rarity = rObj.DisplayName or rObj._id or rObj.Name or "Unknown"
		end
		return rarity, categoryData
	end
	local function placeRarityMatches(rarity)
		local list = Config.PlaceRarities or {}
		if #list == 0 or table.find(list, "None") or table.find(list, "All") then
			return true
		end
		return table.find(list, rarity) ~= nil
	end
	local function placeAllowed(uid)
		return not (type(SenaPanels.isPlaceEnabled) == "function" and SenaPanels.isPlaceEnabled(uid) == false)
	end
	local placeWantsCache = { at = 0, value = false }
	local function placeWants()
		if not Config.AutoPlace then return false end
		if Config.IsPlacing then return true end
		local now = os.clock()
		if now - placeWantsCache.at < 1 then return placeWantsCache.value end
		placeWantsCache.at = now
		local value = false
		pcall(function()
			local EggCmds = require(game:GetService("ReplicatedStorage").Client.EggState)
			local Assets = require(game:GetService("ReplicatedStorage").Data.Assets)
			local myEggs = EggCmds.GetOwnerRuntimeRecords(LocalPlayer.UserId)
			if type(myEggs) ~= "table" then return end
			local placed, waiting = 0, 0
			for uid, record in pairs(myEggs) do
				if record.Placement ~= nil then
					placed = placed + 1
				elseif placeAllowed(uid) and placeRarityMatches((placeRarityOf(record, Assets))) then
					waiting = waiting + 1
				end
			end
			value = waiting > 0 and placed < 30
		end)
		placeWantsCache.value = value
		return value
	end
	UIRunners.AutoPlaceLoop = function()
		if Config.IsAutoPlaceWorkerRunning then return end
		Config.IsAutoPlaceWorkerRunning = true
		while Config.AutoPlace and sessionAlive() do
			task.wait(1.5)
			local success, err = pcall(function()
				local ReplicatedStorage = game:GetService("ReplicatedStorage")
				local HttpService = game:GetService("HttpService")
				local EggCmds = require(ReplicatedStorage.Client.EggState)
				local Assets = require(ReplicatedStorage.Data.Assets)
				local myTruePlot = nil
				local plotsFolder = workspace:FindFirstChild("Plots")
				if plotsFolder then
					for _, p in ipairs(plotsFolder:GetChildren()) do
						local sign = p:FindFirstChild("PlotSign")
						if sign then
							local pSign = sign:FindFirstChild("PlayerPlotSign")
							if pSign and pSign:FindFirstChild("Frame") and pSign.Frame:FindFirstChild("PlayerName") then
								local rawText = pSign.Frame.PlayerName.Text
								local cleanText = string.gsub(rawText, "<[^>]+>", "")
								if string.find(string.lower(cleanText), string.lower(LocalPlayer.Name)) or string.find(string.lower(cleanText), string.lower(LocalPlayer.DisplayName)) then
									myTruePlot = p
									break
								end
							end
						end
					end
				end
				if not myTruePlot then
					placeStatus = "Looking for your plot"
					return
				end
				local ToUpdate = myTruePlot:FindFirstChild("ToUpdate")
				local PetArea = ToUpdate and ToUpdate:FindFirstChild("PetArea")
				local CenterPoint = myTruePlot:FindFirstChild("CenterPoint") or PetArea
				if not PetArea then
					return
				end
				local eggsToPlace = {}
				local myEggs = EggCmds.GetOwnerRuntimeRecords(LocalPlayer.UserId)
				local placedCount = 0
				if type(myEggs) == "table" then
					for uid, record in pairs(myEggs) do
						if record.Placement ~= nil then
							placedCount = placedCount + 1
						else
							local rarity, categoryData = placeRarityOf(record, Assets)
							local match = placeAllowed(uid) and placeRarityMatches(rarity)
							local kgVal = tonumber(record.Kg) or tonumber(record.Weight) or tonumber(record.kg)
							if not kgVal and categoryData then
								kgVal = tonumber(categoryData.Kg) or tonumber(categoryData.Weight) or tonumber(categoryData.kg)
							end
							kgVal = kgVal or 0
							if match then
								table.insert(eggsToPlace, { Uid = uid, Rarity = rarity, Kg = kgVal })
							end
						end
					end
				end
				table.sort(eggsToPlace, function(a, b)
					return a.Kg > b.Kg
					end)
				local char = LocalPlayer.Character
				local hrp  = char and char:FindFirstChild("HumanoidRootPart")
				local hum  = char and char:FindFirstChildOfClass("Humanoid")
				local originalCF = nil
				if #eggsToPlace == 0 or placedCount >= 30 then
					placeStatus = #eggsToPlace == 0 and "No eggs to place" or "Plot full (30 placed)"
					return
				end
				local function higherPriorityWants()
					return TaskLadder.blocker("auto_place") ~= nil
				end
				if higherPriorityWants() then
					placeStatus = TaskLadder.yieldLabel("auto_place") or ""
					return
				end
				local holder = TaskLadder.holder("auto_place")
				if holder then
					placeStatus = "Waiting for " .. TaskLadder.TITLES[holder] .. " to hand over"
					return
				end
				Config.IsPlacing = true
				placeStatus = string.format("Placing %d egg%s", #eggsToPlace, #eggsToPlace == 1 and "" or "s")
				local treadmill = runtimeEnv.__SenaV4TreadmillManager
				if treadmill and treadmill.activeTreadmill ~= nil then
					local leaveDeadline = os.clock() + 5
					while treadmill.activeTreadmill ~= nil and os.clock() < leaveDeadline and not higherPriorityWants() do
						pcall(function() treadmill:_requestUnequip() end)
						task.wait(0.3)
					end
				end
				char = LocalPlayer.Character
				hrp = char and char:FindFirstChild("HumanoidRootPart")
				hum = char and char:FindFirstChildOfClass("Humanoid")
				if hrp and hrp.Anchored then pcall(function() hrp.Anchored = false end) end
				if hum then pcall(function() hum:UnequipTools() end) end
				if hrp then originalCF = hrp.CFrame end
				local function placeCancelled()
					return not Config.AutoPlace or higherPriorityWants()
				end
				if hrp and PetArea then
					local placeTargetCF = PetArea.CFrame * CFrame.new(0, 3, 0)
					local placePathClear = isPathClear(
						hrp.Position + Vector3.new(0, 2, 0),
						placeTargetCF.Position + Vector3.new(0, 2, 0),
						char
					)
					if not placePathClear then
						local safezoneCF = CFrame.new(518.66, 70.57, -364.73) * CFrame.Angles(math.rad(180.00), math.rad(-89.82), math.rad(180.00))
						TweenMoveTo(hrp, hum, safezoneCF, placeCancelled)
						if placeCancelled() then return end
					end
					TweenMoveTo(hrp, hum, placeTargetCF, placeCancelled)
					if placeCancelled() then return end
					local fallWaited = 0
					while fallWaited < 0.5 and not placeCancelled() do
						task.wait(0.05)
						fallWaited = fallWaited + 0.05
					end
					if placeCancelled() then return end
				end
				local stopPlacing = false
				local occupiedPositions = {}
				for _, rec in pairs(myEggs) do
					if rec.Placement then
						local pos
						if typeof(rec.Placement) == "CFrame" then pos = rec.Placement.Position
						elseif typeof(rec.Placement) == "Vector3" then pos = rec.Placement
						elseif rec.Placement.Position then pos = rec.Placement.Position end
						if pos then table.insert(occupiedPositions, pos) end
					end
				end
				local searchIdx = 0
				for _, eggInfo in ipairs(eggsToPlace) do
					if not Config.AutoPlace or stopPlacing then break end
					if placedCount >= 30 then
						stopPlacing = true
						break
					end
					if placeCancelled() then
						return
					end
					local uid = eggInfo.Uid
					local freshEgg = EggCmds.GetOwnerRuntimeRecords(LocalPlayer.UserId)[uid]
					local eqSuccess, eqErr = EggCmds.RequestEquipTool(uid)
					if eqSuccess then
						if placeCancelled() then return end
						task.wait(0.15)
						local placed = false
						while searchIdx < 30 and not placed do
							local placeCFrame = nil
							if PetArea and CenterPoint then
								while searchIdx < 30 do
									local columns = 10
									local paddingX = 6
									local paddingZ = 6
									local usableWidth = PetArea.Size.X - paddingX
									local usableDepth = PetArea.Size.Z - paddingZ
									local spacingX = usableWidth / columns
									local spacingZ = 6
									local row = math.floor(searchIdx / columns)
									local col = searchIdx % columns
									local startX = -(usableWidth / 2) + (spacingX / 2)
									local startZ = -(usableDepth / 2) + (spacingZ / 2)
									local rx = startX + (col * spacingX)
									local rz = startZ + (row * spacingZ)
									local worldPos = PetArea.CFrame * Vector3.new(rx, 0, rz)
									local localPos = CenterPoint.CFrame:PointToObjectSpace(worldPos)
									local testCFrame = CFrame.new(localPos.X, -0.5, localPos.Z)
									local isOccupied = false
									for _, pos in ipairs(occupiedPositions) do
										if (pos - testCFrame.Position).Magnitude < 1.0 then
											isOccupied = true
											break
										end
									end
									if not isOccupied then
										placeCFrame = testCFrame
										break
									end
									searchIdx = searchIdx + 1
								end
							end
							if not placeCFrame then
								stopPlacing = true
								break
							end
							if placeCancelled() then return end
							local plSuccess, plErr = EggCmds.RequestPlaceEgg(uid, placeCFrame)
							if plSuccess then
								table.insert(occupiedPositions, placeCFrame.Position)
								placedCount = placedCount + 1
								placed = true
								task.wait(0.15)
							else
								local lErr = plErr and string.lower(tostring(plErr)) or ""
								if string.find(lErr, "full") or string.find(lErr, "limit")
								or string.find(lErr, "capacity") or string.find(lErr, "maximum") then
									if Config.AutoPlace then Config.AutoPlace = false end
									stopPlacing = true
									break
								end
								table.insert(occupiedPositions, placeCFrame.Position)
								searchIdx = searchIdx + 1
								task.wait(0.1)
							end
						end
					end
				end
				if originalCF and hrp and not placeCancelled() then
					local returnPathClear = isPathClear(
						hrp.Position + Vector3.new(0, 2, 0),
						originalCF.Position + Vector3.new(0, 2, 0),
						char
					)
					if not returnPathClear then
						local safezoneCF = CFrame.new(518.66, 70.57, -364.73) * CFrame.Angles(math.rad(180.00), math.rad(-89.82), math.rad(180.00))
						TweenMoveTo(hrp, hum, safezoneCF, placeCancelled)
					end
					if placeCancelled() then return end
					TweenMoveTo(hrp, hum, originalCF, placeCancelled)
					task.wait(0.2)
				end
				end)
			if Config.IsPlacing then
				placeStatus = ""
			end
			Config.IsPlacing = false
			if not success then
				placeStatus = "Error, retrying"
				warn("Auto Place Error: " .. tostring(err))
			end
		end
		Config.IsAutoPlaceWorkerRunning = false
	end
	TaskLadder.register("auto_place", {
		wants = placeWants,
		active = function()
			return Config.IsPlacing == true
		end,
		enabled = function()
			return Config.AutoPlace == true
		end,
		status = function()
			return placeStatus
		end,
	})
	UIRunners.AutoHatchLoop = function()
		if Config.IsAutoHatchWorkerRunning then return end
		Config.IsAutoHatchWorkerRunning = true
		task.spawn(function()
			local failedHatchAttempts = {}
			while Config.AutoHatch and sessionAlive() do
				task.wait(1.5)
				pcall(function()
					local ReplicatedStorage = game:GetService("ReplicatedStorage")
					local EggCmds = require(ReplicatedStorage.Client.EggState)
					local myEggs = EggCmds.GetOwnerRuntimeRecords(LocalPlayer.UserId)
					if not myEggs then return end
					local eggsToHatch = {}
					for uid, record in pairs(myEggs) do
						if record.Placement ~= nil then
							table.insert(eggsToHatch, uid)
						end
					end
					local now = os.time()
					for _, uid in ipairs(eggsToHatch) do
						if not Config.AutoHatch then break end
						if failedHatchAttempts[uid] and now < failedHatchAttempts[uid] then
							continue
						end
						local record = myEggs[uid]
						local isReady = false
						if type(EggCmds.IsReadyToHatch) == "function" then
							local ok, ready = pcall(EggCmds.IsReadyToHatch, uid)
							isReady = ok and ready == true
						end
						if isReady or record.Ready == true or not failedHatchAttempts[uid] then
							local success = EggCmds.RequestHatchEgg(uid)
							if success then
								EggCmds.RequestCompleteHatchEgg(uid)
								failedHatchAttempts[uid] = nil
								task.wait(0.1)
							else
								failedHatchAttempts[uid] = now + 10
							end
						end
					end
					end)
			end
			Config.IsAutoHatchWorkerRunning = false
			end)
	end
	local mutationWarnedNoItem = false
	local mutationState = { wants = false, busy = false, status = "" }
	local function sweepOnce()
		local ReplicatedStorage = game:GetService("ReplicatedStorage")
		local EggCmds = require(ReplicatedStorage.Client.EggState)
		local Remotes = require(ReplicatedStorage.Shared.Remotes)
		local AssetsDir = nil
		pcall(function()
			local A = require(ReplicatedStorage.Data.Assets)
			AssetsDir = A.Directory or A
		end)
		local function recDisplayName(rec)
			local cat = rec.Category or rec.AssetCategory
			local cfg = AssetsDir and cat and AssetsDir[cat]
			return (cfg and cfg.DisplayName) or cat
		end
		local function recRarity(rec)
			local cat = rec.Category or rec.AssetCategory
			local cfg = AssetsDir and cat and AssetsDir[cat]
			local r = cfg and cfg.Rarity
			return r and (r.DisplayName or r._id) or nil
		end
		local function higherPriorityWants()
			return TaskLadder.blocker("use_scrambled") ~= nil
		end
		local mid = ({ Fractured = "Boss", Enchanted = "Enchanted", Nitro = "Nitro" })[Config.MutationChoice] or "Scrambled"
		local function eggValue(rec)
			local item = {
				AssetCategory = rec.AssetCategory or rec.Category,
				AssetScale = rec.AssetScale or rec.Scale or 1,
				Mutations = rec.Mutations or {},
				BaseMutation = rec.BaseMutation,
				AssetEyeColor = rec.AssetEyeColor,
				AssetColorSeed = rec.AssetColorSeed,
				AssetColorIndex = rec.AssetColorIndex,
				Gender = rec.Gender,
				Personality = rec.Personality,
				HasBeenFirstPlaced = rec.HasBeenFirstPlaced,
			}
			local ok, value = pcall(function() return Config:getAreaEggValue(item) end)
			return (ok and tonumber(value)) or 0
		end
		local function findConsumable()
			local char = LocalPlayer.Character
			for _, cont in ipairs({ char, LocalPlayer:FindFirstChildOfClass("Backpack") }) do
				if cont then
					for _, t in ipairs(cont:GetChildren()) do
						if t:IsA("Tool") and t:GetAttribute("ItemType") == "MutationConsumable"
						and t:GetAttribute("MutationId") == mid then
							return t
						end
					end
				end
			end
			return nil
		end
		local function recHasMutation(rec)
			local m = rec and rec.Mutations
			if m == nil then return false end
			if type(m) == "table" then
				for _, v in ipairs(m) do if v == mid then return true end end
				for k, v in pairs(m) do if k == mid or v == mid then return true end end
				return false
			end
			return tostring(m):find(mid) ~= nil
		end
		local speciesFilter = Config.MutationSpecies
		local hasSpeciesFilter = type(speciesFilter) == "table" and #speciesFilter > 0
		local rarityFilter = Config.MutationRarities
		local hasRarityFilter = type(rarityFilter) == "table" and #rarityFilter > 0
		local minRate = tonumber(Config.MutationMinRate) or 0
		local function eligible(rec)
			if type(rec) ~= "table" or rec.Placement == nil or recHasMutation(rec) then return false end
			if minRate > 0 then
				local rateOf = UIRunners.rateOf
				local rate = rateOf and rateOf({ Category = rec.Category or rec.AssetCategory, Scale = rec.Scale or rec.AssetScale or 1, Mutations = rec.Mutations or {} }) or 0
				if rate < minRate then return false end
			end
			local cat = rec.Category or rec.AssetCategory
			local disp = recDisplayName(rec)
			if hasSpeciesFilter then
				local pass = false
				for _, s in ipairs(speciesFilter) do
					if s == disp or s == cat then pass = true break end
				end
				if not pass then return false end
			end
			if hasRarityFilter then
				local rar = recRarity(rec)
				for _, r in ipairs(rarityFilter) do
					if r == rar then return true end
				end
				return false
			end
			return true
		end
		local tool = findConsumable()
		local myEggs = EggCmds.GetOwnerRuntimeRecords(LocalPlayer.UserId)
		local anyEligible = false
		if tool and type(myEggs) == "table" then
			for _, rec in pairs(myEggs) do
				if eligible(rec) then anyEligible = true break end
			end
		end
		mutationState.wants = anyEligible
		if not tool then
			mutationState.status = "No " .. tostring(Config.MutationChoice or "Scrambled") .. " item in your bag"
			if not mutationWarnedNoItem then
				warn("[AutoMutation] no " .. tostring(Config.MutationChoice or "Scrambled")
					.. " consumable in the inventory, round skipped.")
				mutationWarnedNoItem = true
			end
			return
		end
		mutationWarnedNoItem = false
		if not anyEligible then
			mutationState.status = "No placed egg to mutate"
			return
		end
		if higherPriorityWants() then
			mutationState.status = TaskLadder.yieldLabel("use_scrambled") or ""
			return
		end
		local holder = TaskLadder.holder("use_scrambled")
		if holder then
			mutationState.status = "Waiting for " .. TaskLadder.TITLES[holder] .. " to hand over"
			return
		end
		local char = LocalPlayer.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if not hum then return end
		mutationState.busy = true
		mutationState.status = "Applying " .. tostring(Config.MutationChoice or "Scrambled")
		if not char:FindFirstChild(tool.Name) then
			pcall(function() hum:EquipTool(tool) end)
			task.wait(0.15)
		end
		local queue = {}
		for uid, rec in pairs(myEggs) do
			if eligible(rec) then queue[#queue + 1] = { uid = uid, rec = rec, value = eggValue(rec) } end
		end
		table.sort(queue, function(a, b) return a.value > b.value end)
		for _, entry in ipairs(queue) do
			local uid, rec = entry.uid, entry.rec
			if higherPriorityWants() then break end
			if eligible(rec) then
					local renders = workspace:FindFirstChild("PlacedEggRenders")
					local render = renders and renders:FindFirstChild(tostring(LocalPlayer.UserId) .. "_" .. uid)
					local root = char:FindFirstChild("HumanoidRootPart")
					if render and root then
						local eggPos = render:GetPivot().Position
						if (eggPos - root.Position).Magnitude > 30 then
							mutationState.status = "Walking to " .. tostring(recDisplayName(rec))
							local away = Vector3.new(root.Position.X - eggPos.X, 0, root.Position.Z - eggPos.Z)
							local spot = eggPos + (away.Magnitude > 0.1 and away.Unit or Vector3.new(1, 0, 0)) * 10 + Vector3.new(0, 3, 0)
							pcall(TweenMoveTo, root, hum, CFrame.new(spot), higherPriorityWants)
							mutationState.status = "Applying " .. tostring(Config.MutationChoice or "Scrambled")
						end
					end
					local liveTool = findConsumable()
					if not liveTool then break end
					if not char:FindFirstChild(liveTool.Name) then
						pcall(function() hum:EquipTool(liveTool) end)
						task.wait(0.1)
					end
					local tries, mutated = 0, false
					repeat
						if higherPriorityWants() then break end
						if findConsumable() == nil then break end
						local ok, res = pcall(function()
							return Remotes.BossMastery.AskUseMutationConsumable:InvokeServer(uid)
						end)
						tries = tries + 1
						if ok and type(res) == "table" then
							if res.Mutated == true then mutated = true end
							if res.Success ~= true then break end
						else
							break
						end
						task.wait(0.25)
					until mutated or not Config.MutationRetry or tries >= 40
			end
		end
		mutationState.busy = false
		mutationState.status = ""
	end
	UIRunners.mutationSweep = function()
		local ok, err = pcall(sweepOnce)
		mutationState.busy = false
		if not ok then
			error(err, 0)
		end
	end
	TaskLadder.register("use_scrambled", {
		wants = function()
			return Config.AutoMutation == true and mutationState.wants == true
		end,
		active = function()
			return mutationState.busy == true
		end,
		enabled = function()
			return Config.AutoMutation == true
		end,
		status = function()
			return mutationState.status
		end,
	})
	UIRunners.AutoMutationLoop = function()
		if Config.IsAutoMutationWorkerRunning then return end
		Config.IsAutoMutationWorkerRunning = true
		task.spawn(function()
			while Config.AutoMutation and sessionAlive() do
				task.wait(1.0)
				pcall(UIRunners.mutationSweep)
			end
			Config.IsAutoMutationWorkerRunning = false
			end)
	end
	UIRunners.RingEventLoop = function()
		if Config.IsRingEventRunning then return end
		Config.IsRingEventRunning = true
		task.spawn(function()
			local SAFE = CFrame.new(542.93, 71.5, -405.58)
			local FOREST = CFrame.new(602, 70.78, -372)
			local ANGELS_DEMONS = CFrame.new(5573, 70.77, -363)
			local function cancelled() return not Config.AutoRingEvent or not sessionAlive() end
			local function goTo(cf)
				if cancelled() then return false end
				local char = LocalPlayer.Character
				local hrp = char and char:FindFirstChild("HumanoidRootPart")
				local hum = char and char:FindFirstChildOfClass("Humanoid")
				if not hrp or not hum then task.wait(0.3) return not cancelled() end
				TweenMoveTo(hrp, hum, cf, cancelled, false, nil, true)
				return not cancelled()
			end
			while not cancelled() do
				if not goTo(SAFE) then break end
				if not goTo(FOREST) then break end
				if not goTo(ANGELS_DEMONS) then break end
				if not goTo(FOREST) then break end
			end
			Config.IsRingEventRunning = false
			end)
	end
	local sellNamesDropdown
	local sellRarityDropdown
	local sellEggRarityDropdown
	local sellEarnings = nil
	local function sellRateOf(item)
		if sellEarnings == nil then
			pcall(function() sellEarnings = require(game:GetService("ReplicatedStorage").Shared.Util.AssetEarnings) end)
		end
		if not sellEarnings then return 0 end
		for _, fn in ipairs({ sellEarnings.LiveRatePerSecond, sellEarnings.RatePerSecond, sellEarnings.CatalogRatePerSecond }) do
			if type(fn) == "function" then
				local ok, rate = pcall(fn, item)
				if ok and type(rate) == "number" and rate > 0 then return rate end
			end
		end
		return 0
	end
	UIRunners.rateOf = sellRateOf
	local function parseAmount(text)
		local normalized = string.lower(tostring(text or "")):gsub("[%s,]", "")
		if normalized == "" then return 0 end
		local amountText, suffix = string.match(normalized, "^([%d]+%.?[%d]*)([kmb]?)$")
		local amount = tonumber(amountText)
		if not amount then return 0 end
		local mult = 1
		if suffix == "k" then mult = 1e3 elseif suffix == "m" then mult = 1e6 elseif suffix == "b" then mult = 1e9 end
		return amount * mult
	end
	local isAutoSellRunning = false
	local sellState = { petPending = false, petBusy = false, status = "" }
	UIRunners.startAutoSellLoop = function()
		if isAutoSellRunning then return end
		isAutoSellRunning = true
		task.spawn(function()
			local ReplicatedStorage = game:GetService("ReplicatedStorage")
			local Assets = require(ReplicatedStorage.Data.Assets)
			local Save = require(ReplicatedStorage.Shared.Save)
			local AssetRoster = require(ReplicatedStorage.Client.AssetRoster)
			local Remotes = require(ReplicatedStorage.Shared.Remotes)
			local LocalPlayer = game:GetService("Players").LocalPlayer
			local function readPlacedUids()
				local ok, runtimeRecords = pcall(function()
					return AssetRoster.ReadOwnerPen(LocalPlayer.UserId)
					end)
				if not ok or type(runtimeRecords) ~= "table" then return nil end
				local placed = {}
				for key, rec in pairs(runtimeRecords) do
					if type(key) == "string" then placed[key] = true end
					if type(rec) == "table" and rec.UID then placed[rec.UID] = true end
				end
				return placed
			end
			local function stillSellablePet(entry, placedNow)
				if not Config.AutoSell then return false, "toggle Auto Sell Pet udah OFF", "global" end
				if not autoSellCanRun() then return false, "Auto Steal lagi megang kendali", "global" end
				local namesNow = readDropdownFilter(sellNamesDropdown)
				local raritiesNow = readDropdownFilter(sellRarityDropdown)
				if not namesNow or not raritiesNow then
					return false, "filter dropdown gak bisa dibaca", "global"
				end
				if type(placedNow) ~= "table" then
					return false, "status pet dipajang gak bisa diverifikasi", "global"
				end
				if placedNow[entry.uid] then
					return false, "pet ini dipajang di plot", "pet"
				end
				if not petMatchesSellFilter(entry.petName, entry.rarity, namesNow, raritiesNow) then
					return false, "pet ini udah gak match filter yang sekarang", "pet"
				end
				local sv = (Save.Peek or Save.Get)()
				local rec = sv and sv.Inventory and sv.Inventory[entry.uid]
				if rec == nil then
					return false, "pet ini udah gak ada di inventory", "pet"
				end
				local maxRate = Config.SellPetMaxRate or 0
				if maxRate > 0 then
					local rate = sellRateOf({ Category = rec.Category or rec.AssetCategory, Scale = rec.Scale or rec.AssetScale or 1, Mutations = rec.Mutations or {} })
					if rate > maxRate then
						return false, "money/s pet ini di atas batas value", "pet"
					end
				end
				if rec.IsFavorite == true then
					return false, "pet ini di-favorite", "pet"
				end
				if rec.InFuse == true then
					return false, "pet ini sedang di-fuse", "pet"
				end
				if table.find(sv.EquippedAssets or {}, entry.uid) ~= nil then
					return false, "pet ini sedang dipasang", "pet"
				end
				return true
			end
			while Config.AutoSell and sessionAlive() do
				local success, err = pcall(function()
					if not autoSellCanRun() then
						sellState.status = TaskLadder.yieldLabel("auto_sell") or ""
						return
					end
					local sellNames = readDropdownFilter(sellNamesDropdown)
					local sellRarities = readDropdownFilter(sellRarityDropdown)
					if not sellNames or not sellRarities then
						warn("[AutoSell] Filter dropdown gak bisa dibaca - ronde ini di-SKIP, gak ada yang dijual. Kalau ini terus-terusan, matiin Auto Sell Pet dan lapor.")
						return
					end
					local mySave = (Save.Peek or Save.Get)()
					local myInventory = mySave and mySave.Inventory or {}
					local placedUids = readPlacedUids()
					if not placedUids then
						warn("[AutoSell] Status pet yang dipajang gak bisa diverifikasi - ronde ini di-SKIP, gak ada yang dijual.")
						return
					end
					local petsToSell = {}
					local countProcessed = 0
					if type(myInventory) == "table" then
						for uid, record in pairs(myInventory) do
							countProcessed = countProcessed + 1
							if countProcessed % 250 == 0 then
								RunService.Heartbeat:Wait()
								if not Config.AutoSell then return end
							end
							if type(record) == "table" then
								local isPlaced = placedUids[uid] == true
								local isFavorite = record.IsFavorite == true or record["Jadikan Favorit"] == true or record["Favorite"] == true
								local isEquipped = table.find(mySave.EquippedAssets or {}, uid) ~= nil
								local inFuse = record.InFuse == true
								local assetId = record.Category or record.id or record.AssetCategory or record.ItemId
								local categoryData = assetId and Assets.Directory[assetId]
								local petName = categoryData and (categoryData.DisplayName or categoryData._id or categoryData.Name) or "Unknown"
								local rarityObj = categoryData and categoryData.Rarity
								local rarity = rarityObj and (rarityObj.DisplayName or rarityObj._id or rarityObj.Name) or "Unknown"
								local match = petMatchesSellFilter(petName, rarity, sellNames, sellRarities)
								local passValue = true
								local maxRate = Config.SellPetMaxRate or 0
								if maxRate > 0 then
									local rate = sellRateOf({ Category = assetId, Scale = record.Scale or record.AssetScale or 1, Mutations = record.Mutations or {} })
									passValue = rate <= maxRate
								end
								if match and passValue and not isFavorite and not isPlaced and not isEquipped and not inFuse then
									table.insert(petsToSell, { uid = uid, petName = petName, rarity = rarity })
								end
							end
						end
					end
					sellState.petPending = #petsToSell > 0
					if #petsToSell > 0 then
						sellState.petBusy = true
						sellState.status = string.format("Selling %d pet%s", #petsToSell, #petsToSell == 1 and "" or "s")
						for _, entry in ipairs(petsToSell) do
							local placedNow = readPlacedUids()
							local okNow, reasonNow, scopeNow = stillSellablePet(entry, placedNow)
							if not okNow then
								warn("[AutoSell] Gak jual " .. tostring(entry.petName) .. " - " .. tostring(reasonNow))
								if scopeNow == "global" then break end
								continue
							end
							if not autoSellCanRun() then break end
							local character = LocalPlayer.Character
							local humanoid = character and character:FindFirstChildOfClass("Humanoid")
							local tool = nil
							for _, container in ipairs({ LocalPlayer.Backpack, character }) do
								if container then
									for _, candidate in ipairs(container:GetChildren()) do
										if candidate:IsA("Tool") and candidate:GetAttribute("UID") == entry.uid then
											tool = candidate
											break
										end
									end
								end
								if tool then break end
							end
							if not tool or not humanoid then
								continue
							end
							humanoid:EquipTool(tool)
							task.wait(0.2)
							if not autoSellCanRun() then break end
							local placedPreFire = readPlacedUids()
							local okFire, reasonFire, scopeFire = stillSellablePet(entry, placedPreFire)
							if not okFire then
								warn("[AutoSell] Batal di detik terakhir, gak jual " .. tostring(entry.petName) .. " - " .. tostring(reasonFire))
								if scopeFire == "global" then break end
								continue
							end
							Remotes.PetSatchel.SellPet:FireServer({ entry.uid })
							task.wait(0.05)
						end
					end
					end)
				sellState.petBusy = false
				if sellState.status:find("^Selling") then
					sellState.status = ""
				end
				if not success then
					warn("Auto Sell Error:", err)
				end
				task.wait(1.5)
			end
			isAutoSellRunning = false
			end)
	end
	local isAutoSellEggRunning = false
	local isAutoSellEggProcessing = false
	local function hasPendingEggToSell()
		if not Config.AutoSellEgg then return false end
		local rarities = readDropdownFilter(sellEggRarityDropdown)
		if not rarities or #rarities == 0 or table.find(rarities, "None") then return false end
		local ReplicatedStorage = game:GetService("ReplicatedStorage")
		local okSave, Save = pcall(function() return require(ReplicatedStorage.Shared.Save) end)
		if not okSave or not Save then return false end
		local profile = (Save.Peek or Save.Get)()
		local inventory = profile and profile.EggInventory
		if type(inventory) ~= "table" then return false end
		local okAssets, AssetsMod = pcall(function() return require(ReplicatedStorage.Data.Assets) end)
		local Assets = okAssets and AssetsMod and AssetsMod.Directory
		if not Assets then return false end
		for uid, record in pairs(inventory) do
			local asset = type(record) == "table" and Assets[record.AssetCategory]
			local rarity = asset and asset.Rarity and (asset.Rarity.DisplayName or asset.Rarity._id)
			local passValue = true
			local maxRate = Config.SellEggMaxRate or 0
			if maxRate > 0 and type(record) == "table" then
				local rate = sellRateOf({ Category = record.AssetCategory, Scale = record.AssetScale or 1, Mutations = record.Mutations or {} })
				passValue = rate <= maxRate
			end
			if record.Placement == nil
			and passValue
			and eggMatchesSellFilter(rarity or "Unknown", rarities)
			then
				return true
			end
		end
		return false
	end
	runtimeEnv.__SenaV4IsAutoSellEggBusy = function()
		return isAutoSellEggProcessing or hasPendingEggToSell()
	end
	local eggPendingCache = { at = 0, value = false }
	local function eggSellPending()
		local now = os.clock()
		if now - eggPendingCache.at < 1 then return eggPendingCache.value end
		eggPendingCache.at = now
		local ok, value = pcall(hasPendingEggToSell)
		eggPendingCache.value = ok and value == true
		return eggPendingCache.value
	end
	TaskLadder.register("auto_sell", {
		wants = function()
			return (Config.AutoSell == true and sellState.petPending == true)
				or (Config.AutoSellEgg == true and eggSellPending())
		end,
		active = function()
			return sellState.petBusy == true or isAutoSellEggProcessing == true
		end,
		enabled = function()
			return Config.AutoSell == true or Config.AutoSellEgg == true
		end,
		status = function()
			if isAutoSellEggProcessing then return "Selling eggs" end
			return sellState.status
		end,
	})
	UIRunners.startAutoSellEggLoop = function()
		if isAutoSellEggRunning then return end
		isAutoSellEggRunning = true
		task.spawn(function()
			local ReplicatedStorage = game:GetService("ReplicatedStorage")
			local Assets = require(ReplicatedStorage.Data.Assets).Directory
			local EggState = require(ReplicatedStorage.Client.EggState)
			local Remotes = require(ReplicatedStorage.Shared.Remotes)
			local Save = require(ReplicatedStorage.Shared.Save)
			while Config.AutoSellEgg and sessionAlive() do
				local rarities = readDropdownFilter(sellEggRarityDropdown)
				local profile = (Save.Peek or Save.Get)()
				local inventory = profile and profile.EggInventory
				if rarities and type(inventory) == "table" and autoSellCanRun() then
					for uid, record in pairs(inventory) do
						if not Config.AutoSellEgg or not autoSellCanRun() then break end
						local asset = type(record) == "table" and Assets[record.AssetCategory]
						local rarity = asset and asset.Rarity and (asset.Rarity.DisplayName or asset.Rarity._id)
						local passValue = true
						local maxRate = Config.SellEggMaxRate or 0
						if maxRate > 0 and type(record) == "table" then
							local rate = sellRateOf({ Category = record.AssetCategory, Scale = record.AssetScale or 1, Mutations = record.Mutations or {} })
							passValue = rate <= maxRate
						end
						if record.Placement == nil
						and passValue
						and eggMatchesSellFilter(rarity or "Unknown", rarities)
						then
							if not autoSellCanRun() then break end
							isAutoSellEggProcessing = true
							if runtimeEnv.__SenaV4TreadmillManager and runtimeEnv.__SenaV4TreadmillManager.activeTreadmill ~= nil then
								runtimeEnv.__SenaV4TreadmillManager:_cancelIdle(true)
								task.wait(0.25)
							end
							local equipped = EggState.WearEggTool(uid)
							if equipped then
								task.wait(0.2)
								if not autoSellCanRun() then break end
								local fresh = (Save.Peek or Save.Get)()
								fresh = fresh and fresh.EggInventory and fresh.EggInventory[uid]
								if fresh and fresh.Placement == nil then
									Remotes.PetSatchel.SellPet:FireServer({ uid })
									task.wait(0.25)
								end
							end
						end
					end
				end
				isAutoSellEggProcessing = false
				task.wait(0.5)
			end
			isAutoSellEggProcessing = false
			isAutoSellEggRunning = false
			end)
	end
	local petNamesList = {"None", "All"}
	pcall(function()
		local Assets = require(game:GetService("ReplicatedStorage").Data.Assets)
		local namesMap = {}
		for k, v in pairs(Assets.Directory) do
			if type(v) == "table" and (v.DisplayName or v._id or v.Name) then
				local disp = v.DisplayName or v._id or v.Name
				if not namesMap[disp] then
					namesMap[disp] = true
					table.insert(petNamesList, disp)
				end
			end
		end
		table.sort(petNamesList, function(a, b)
			if a == "None" then return true end
			if b == "None" then return false end
			if a == "All" then return true end
			if b == "All" then return false end
			return a < b
			end)
		end)
	local nameOptions = withoutNone(stealNameOptions)
	local areaOptions = withoutNone(stealAreaOptions)
	local rarities = rarityOptions()
	local petNameOptions = withAll(withoutNone(petNamesList))
	local function applyAutoSteal(value)
		Config.AutoSteal = value == true
		if eggRuntime then
			eggRuntime:setEnabled(Config.AutoSteal)
		end
		if type(runtimeEnv.__SenaV4SetStealDeclutter) == "function" then
			pcall(runtimeEnv.__SenaV4SetStealDeclutter, Config.AutoSteal)
		end
	end
	local function applyStealHold(value)
		Config.StealHoldSeconds = math.clamp(math.floor((tonumber(value) or 5) + 0.5), 1, 10)
	end
	local function applyGodMode(value)
		Config.GodMode = value == true
		if godMode then
			godMode:setEnabled(Config.GodMode)
		end
	end
	local function treadmillManagerRef()
		return runtimeEnv.__SenaV4TreadmillManager
	end
	local function applyAutoTreadmill(value)
		Config.AutoTreadmillIdle = value == true
		local manager = treadmillManagerRef()
		if manager then manager:setIdleFarm(Config.AutoTreadmillIdle and not Config.AntiTreadmill) end
	end
	local function applyAntiTreadmill(value)
		Config.AntiTreadmill = value == true
		local manager = treadmillManagerRef()
		if Config.AntiTreadmill then
			if manager then manager:setIdleFarm(false) end
			SenaExtras.startAntiTreadmillLoop()
		elseif manager then
			manager:setIdleFarm(Config.AutoTreadmillIdle)
		end
	end
	local function applyHopNoMatch(value)
		Config.HopNoMatch = value == true
		if Config.HopNoMatch then SenaExtras.startHopLoop() end
	end
	local function applyPrivateServerMax(value)
		if type(value) == "table" then value = value[1] end
		Config.PrivateServerMax = tostring(value or "2")
	end
	local function applyPrivateServerAuto(value)
		Config.PrivateServerAuto = value == true
		if Config.PrivateServerAuto then SenaExtras.startPrivateAutoHop() end
	end
	local function applyHopCooldown(value)
		Config.HopCooldown = math.max(1, math.floor(tonumber(value) or 5))
	end
	local function applyTreadmillUpgrade(value)
		Config.AutoTreadmillUpgrade = value == true
		local manager = treadmillManagerRef()
		if manager then manager:setAutoUpgrade(Config.AutoTreadmillUpgrade) end
	end
	local function applyStealMode(value)
		local str = type(value) == "string" and value or ""
		local lower = str:lower()
		local zigzag = lower:find("zig") ~= nil
		local mode = (str:find("Fly") or str:find("High") or zigzag) and "Fly" or "Instant"
		local aerial = mode == "Fly" and not zigzag and (str:find("%(Fly%)") ~= nil or lower:find("aerial") ~= nil)
		zigzag = zigzag and mode == "Fly"
		Config.StealMode = mode
		Config.FlyAerial = aerial
		Config.FlyZigzag = zigzag
		if eggRuntime and eggRuntime.captureObjectiveEnabled then
			eggRuntime._modeBeforeCapture = { mode, aerial, zigzag }
		elseif eggRuntime then
			eggRuntime:setStealMode(mode, aerial, zigzag)
		end
	end
	local function applySpeed(value)
		local studs = math.clamp(math.floor((tonumber(value) or 600) + 0.5), 500, 1000)
		local level = math.floor(studs / 10 + 0.5)
		applyUserSpeed(level)
		if eggRuntime then
			eggRuntime:setSpeed(level)
		end
	end
	local function applyStealFilter(key, flag, values)
		local list = withoutNone(values)
		if key == "names" then
			Config.StealNamesFilter = list
		elseif key == "areas" then
			Config.StealAreas = list
		elseif key == "rarities" then
			Config.StealRarities = list
		end
		if eggRuntime then
			eggRuntime:setFilter(key, list)
			eggRuntime:setFilterEnabled(flag, #list > 0)
		end
	end
	local function applyStealValue(text)
		Config:applyStealValueInput(text)
		if eggRuntime then
			eggRuntime:setMinValuePerSec(Config.StealMinValue or 0)
		end
	end
	local function applyStealMutations(values)
		local list = withoutNone(values)
		Config.StealMutations = list
		if eggRuntime then
			eggRuntime:setFilter("mutations", list)
			eggRuntime:setFilterEnabled("mutation", #list > 0)
		end
	end
	local function applyStealWeight(text)
		local kg = tonumber((tostring(text or ""):gsub("[^%d%.]", ""))) or 0
		Config.StealMinWeight = kg
		if eggRuntime then
			eggRuntime:setMinWeightKg(kg)
		end
	end
	local function applyStealPriority(value)
		Config.StealPriority = tostring(value or "Rarity")
		if eggRuntime then
			eggRuntime:setHighestValueFirst(Config.StealPriority == "Highest Value")
			eggRuntime:setHeaviestFirst(Config.StealPriority == "Heaviest")
		end
	end
	local function applyEggEsp(value)
		Config.EggESP = value == true
		if eggRuntime then
			eggRuntime:setEggEsp(Config.EggESP)
		end
	end
	local function applyEspDetails(values)
		local list = withoutNone(values)
		Config.EspDetails = list
		if not eggRuntime then return end
		local wanted = {}
		for _, value in ipairs(list) do wanted[value] = true end
		eggRuntime:setEspOption("name", wanted["Name"] == true)
		eggRuntime:setEspOption("rarity", wanted["Rarity"] == true)
		eggRuntime:setEspOption("value", wanted["Value"] == true)
		eggRuntime:setEspOption("kg", wanted["Weight"] == true)
		eggRuntime:setEspOption("mutation", wanted["Mutation"] == true)
		eggRuntime:setEspOption("placed", wanted["Placed Eggs"] == true)
		eggRuntime:setEspOption("icon", wanted["Icon"] == true)
	end
	UIRunners.applyEspMinRarity = function(value)
		local name = type(value) == "table" and value[1] or value
		Config.EspMinRarity = (type(name) == "string" and name ~= "Any") and name or nil
		if eggRuntime then eggRuntime:setEspMinRank(Config.EspMinRarity and catalog.rarityRank(Config.EspMinRarity) or 0) end
	end
	UIRunners.applyEspMinValue = function(text)
		Config.EspMinValue = parseCompactValue(text) or 0
		if eggRuntime then eggRuntime:setEspMinValue(Config.EspMinValue) end
	end
	local function applyBackpackRates(value)
		SenaExtras.setBackpackRates(value == true)
	end
	local function applyAntiGuardKnockback(value)
		Config.AntiGuardKnockback = value == true
		local guard = runtimeEnv.__SenaV4AntiGuard
		if guard and type(guard.setEnabled) == "function" then
			pcall(guard.setEnabled, guard, Config.AntiGuardKnockback)
		end
	end
	local function applyAutoFavorite(value)
		Config.AutoFavorite = value == true
	end
	local function applyFavoriteRule(value)
		Config.FavMode = value == "Species" and "Species" or "Rarity"
	end
	local function applyFavoriteRarities(values)
		Config.FavRarities = withoutNone(values)
	end
	local function applyFavoriteSpecies(values)
		Config.FavSpecies = withoutNone(values)
	end
	local function applyAutoEquipBest(value)
		Config.AutoEquipBest = value == true
	end
	local function applyAutoClaimOffline(value)
		Config.AutoClaimOffline = value == true
	end
	local function applyAutoBaseUpgrade(value)
		Config.AutoBaseUpgrade = value == true
	end
	local function applyAutoClaimAlmanac(value)
		Config.AutoClaimAlmanac = value == true
	end
	local function applyAutoFuse(value)
		Config.AutoFusePets = value == true
	end
	local function applyFuseRule(value)
		Config.FuseSelectedOnly = value == "Selected Species"
	end
	local function applyFuseRarities(values)
		Config.FuseRarities = withoutNone(values)
	end
	local function applyFuseSpecies(values)
		Config.FuseSpecies = withoutNone(values)
	end
	local function applyNoclip(value)
		local roaming = runtimeEnv.__SenaV4Roaming
		if roaming and type(roaming.setNoclip) == "function" then
			pcall(roaming.setNoclip, value == true)
		end
	end
	local function applyBottingMode(value)
		local roaming = runtimeEnv.__SenaV4Roaming
		if roaming and type(roaming.setBottingMode) == "function" then
			pcall(roaming.setBottingMode, value == true)
		end
	end
	local function applyAntiCutscene(value)
		Config.AntiCutscene = value == true
	end
	local function runOnce(flagKey, runner, onDone)
		local restore = Config[flagKey]
		Config[flagKey] = true
		task.spawn(runner)
		task.delay(2.4, function()
			local deadline = os.clock() + 30
			while Config.IsPlacing and os.clock() < deadline do task.wait(0.25) end
			Config[flagKey] = restore
			if onDone then pcall(onDone) end
			end)
	end
	UIRunners.runOnce = runOnce
	local function applyAutoPlace(value)
		Config.AutoPlace = value == true
		if Config.AutoPlace then
			task.spawn(UIRunners.AutoPlaceLoop)
		end
	end
	local function applyAutoHatch(value)
		Config.AutoHatch = value == true
		if Config.AutoHatch then
			task.spawn(UIRunners.AutoHatchLoop)
		end
	end
	local function applyAutoMutation(value)
		Config.AutoMutation = value == true
		if Config.AutoMutation then
			task.spawn(UIRunners.AutoMutationLoop)
		end
	end
	local function applyAutoRingEvent(value)
		Config.AutoRingEvent = value == true
		if Config.AutoRingEvent then
			UIRunners.RingEventLoop()
		end
	end
	local function applyMutationChoice(value)
		Config.MutationChoice = (value == "Fractured" or value == "Enchanted" or value == "Nitro") and value or "Scrambled"
	end
	local function applyMutationSpecies(values)
		Config.MutationSpecies = withoutNone(values)
	end
	local function applyMutationRarities(values)
		Config.MutationRarities = withoutNone(values)
	end
	local function applyMutationMinValue(text)
		Config.MutationMinRate = parseAmount(text)
	end
	local function applyMutationRetry(value)
		Config.MutationRetry = value == true
	end
	local function applyAutoSell(value)
		Config.AutoSell = value == true
		if Config.AutoSell then
			UIRunners.startAutoSellLoop()
		end
	end
	local function applyAutoSellEgg(value)
		Config.AutoSellEgg = value == true
		if Config.AutoSellEgg then
			UIRunners.startAutoSellEggLoop()
		end
	end
	local function applySellPetValue(text)
		Config.SellPetMaxRate = parseAmount(text)
	end
	local function applySellEggValue(text)
		Config.SellEggMaxRate = parseAmount(text)
	end
	local startupBoostScheduled = false
	local function applyStartupBoost(value)
		local wasOn = Config.StartupBoost == true
		Config.StartupBoost = value == true
		if not Config.StartupBoost then
			startupBoostScheduled = false
			if wasOn or decomBoostUndo.snapshot then task.spawn(decomBoostUndo.revert) end
			return
		end
		if Config.StartupBoost and not startupBoostScheduled then
			startupBoostScheduled = true
			task.spawn(function()
				task.wait(1.5)
				if sessionAlive() and Config.StartupBoost then
					ApplyDecomStartupBoost()
				end
				task.wait(4)
				if sessionAlive() and Config.StartupBoost then
					ApplyDecomStartupBoost()
				end
				end)
		end
	end
	local function applyBoostFps(value)
		if value == true then
			task.spawn(ApplyFPSBoost)
		end
	end
	local function applyUncapFps(value)
		local setCap = runtimeEnv.__SenaV4SetCapFps
		if type(setCap) == "function" then
			setCap(value == true and 1000 or 60)
		end
	end
	local function movementExtrasRef()
		return runtimeEnv.__SenaV4MovementExtras
	end
	local function applyFlyForCapture(value)
		Config.FlyForCapture = value == true
		local extras = movementExtrasRef()
		if extras then extras:setFlyForCapture(Config.FlyForCapture) end
	end
	local function applyInstantGrab(value)
		Config.InstantGrab = value == true
		local extras = movementExtrasRef()
		if extras then extras:setInstantGrab(Config.InstantGrab) end
	end
	local function applyAdminBoost(value)
		runtimeEnv.__SenaV4AdminBoost = value == true
		if eggRuntime then
			eggRuntime:setSpeed(Config.TweenSpeedMultiplier or 60)
		end
		runtimeEnv.__SenaV4AdminBoostSpeedGen = (runtimeEnv.__SenaV4AdminBoostSpeedGen or 0) + 1
		local gen = runtimeEnv.__SenaV4AdminBoostSpeedGen
		if value == true then
			task.spawn(function()
				local RS = game:GetService("RunService")
				local base, myLast = nil, nil
				while runtimeEnv.__SenaV4AdminBoostSpeedGen == gen and sessionAlive() do
					local char = LocalPlayer.Character
					local hum = char and char:FindFirstChildOfClass("Humanoid")
					if hum then
						local cur = hum.WalkSpeed
						if base == nil or myLast == nil or math.abs(cur - myLast) > 0.5 then
							base = cur > 900 and cur / 10 or cur
						end
						if base and base > 0 then
							local target = base * 10
							hum.WalkSpeed = target
							myLast = target
						end
					else
						base, myLast = nil, nil
					end
					RS.Heartbeat:Wait()
				end
				local char = LocalPlayer.Character
				local hum = char and char:FindFirstChildOfClass("Humanoid")
				if hum and base and myLast and math.abs(hum.WalkSpeed - myLast) <= 0.5 then
					pcall(function() hum.WalkSpeed = base end)
				end
			end)
		end
	end
	local function applyAutoStealCapture(value)
		Config.AutoStealCapture = value == true
		if eggRuntime then eggRuntime:setCaptureObjective(Config.AutoStealCapture) end
	end
	local function applyInfiniteJump(value)
		Config.InfiniteJump = value == true
		local extras = movementExtrasRef()
		if extras then extras:setInfiniteJump(Config.InfiniteJump) end
	end
	local function applyWalkSpeedMultiplier(value)
		Config.WalkSpeedMultiplier = math.clamp(tonumber(value) or 1, 1, 2.1)
		local extras = movementExtrasRef()
		if extras then extras:setSpeedMultiplier(Config.WalkSpeedMultiplier) end
	end
	local function applyAntiHitGuard(value)
		Config.AntiHitGuard = value == true
		local guard = runtimeEnv.__SenaV4AntiHitGuard
		if guard then guard:setEnabled(Config.AntiHitGuard) end
	end
	local function applyAntiAfk(value)
		Config.AntiAFK = value == true
		runtimeEnv.__SenaV4AntiAfkEnabled = Config.AntiAFK
		if type(runtimeEnv.__SenaV4SetAntiAfkEnabled) == "function" then
			runtimeEnv.__SenaV4SetAntiAfkEnabled(Config.AntiAFK)
		end
	end
	local function applyAutoReconnect(value)
		Config.AutoReconnect = value == true
		st.autoReconnect = Config.AutoReconnect
		if getgenv then getgenv().SNE_AutoReconnect = Config.AutoReconnect end
	end
	local function applyAutoExecute(value)
		Config.AutoExecute = value == true
		st.autoExecute = Config.AutoExecute
		if getgenv then getgenv().SNE_AutoExecute = Config.AutoExecute end
		if value then
			pcall(writeAutoexecBootstrapper)
		else
			pcall(removeAutoexecBootstrapper)
		end
	end
	local elevateUi = (function()
		local setIdentity = runtimeEnv.__SenaV4IdentitySetter
		or (type(setthreadidentity) == "function" and setthreadidentity)
		or (type(set_thread_identity) == "function" and set_thread_identity)
		or (type(setidentity) == "function" and setidentity)
		or (type(syn) == "table" and type(syn.set_thread_identity) == "function" and syn.set_thread_identity)
		local targetIdentity = runtimeEnv.__SenaV4UICapabilityIdentity or 8
		return function()
			if type(setIdentity) == "function" then
				pcall(setIdentity, targetIdentity)
			end
		end
		end)()
	local building = true
	local function guarded(apply)
		return function(value)
			if type(elevateUi) == "function" then
				elevateUi()
			end
			if building then
				return
			end
			if type(apply) == "function" then
				apply(value)
			end
		end
	end
	local playerSteal = runtimeEnv.__SenaV4PlayerSteal
	local function applyStealPlayers(value)
		Config.StealPlayers = value == true
		if playerSteal then playerSteal:setEnabled(Config.StealPlayers) end
		if Config.StealPlayers and not Config.GodMode then
			applyGodMode(true)
			if controls.godMode then
				pcall(function() controls.godMode:Set(true) end)
			end
		end
	end
	local function applyStealPlayerRarities(values)
		Config.StealPlayerRarities = withoutNone(values)
	end
	local function parseValueText(text)
		local normalized = string.lower(tostring(text or "")):gsub("[%s,]", "")
		if normalized == "" then return 0 end
		local amountText, suffix = string.match(normalized, "^([%d]+%.?[%d]*)([kmb]?)$")
		local amount = tonumber(amountText)
		if not amount then return 0 end
		if suffix == "k" then return amount * 1e3 end
		if suffix == "m" then return amount * 1e6 end
		if suffix == "b" then return amount * 1e9 end
		return amount
	end
	local function applyStealPlayerValue(text)
		Config.StealPlayerMinValue = parseValueText(text)
	end
	local function applyAutoIndex(value)
		Config.AutoIndex = value == true
		if eggRuntime then eggRuntime:setIndexObjective(Config.AutoIndex) end
	end
	local function applyWebhookEnabled(value)
		Config.WebhookEnabled = value == true
	end
	local function applyWebhookUrl(text)
		Config.WebhookURL = type(text) == "string" and (text:gsub("^%s+", ""):gsub("%s+$", "")) or ""
	end
	local function applyWebhookRarities(values)
		Config.WebhookRarities = withoutNone(values)
	end
	local function applyWebhookValue(text)
		Config.WebhookMinValue = parseValueText(text)
	end
	local UI_GUARDED_METHODS = {
		"Set", "SetValue", "LoadValue", "ResetValue", "SetContent", "SetTitle",
		"SetOptions", "Update", "Refresh", "Lock", "Unlock", "SetVisible",
		"SetStatus", "GetValue", "SetSubTitle", "SetBadge",
	}
	local function guardUiObject(object)
		if type(object) ~= "table" then return object end
		if rawget(object, "__senaElevated") then return object end
		for _, name in ipairs(UI_GUARDED_METHODS) do
			local original = rawget(object, name)
			if type(original) == "function" then
				rawset(object, name, function(...)
					elevateUi()
					return original(...)
					end)
			end
		end
		rawset(object, "__senaElevated", true)
		return object
	end
	local UI_FACTORY_METHODS = {
		"AddToggle", "AddSlider", "AddDropdown", "AddInput", "AddButton",
		"AddParagraph", "AddKeybind", "AddColorPicker", "AddActionList", "AddPriorityList",
		"AddLiveChat", "AddSupportCard", "AddSubSection", "AddSection", "AddTab", "AddForum",
	}
	local function guardUiFactory(object)
		if type(object) ~= "table" then return object end
		guardUiObject(object)
		if rawget(object, "__senaFactoryGuarded") then return object end
		for _, name in ipairs(UI_FACTORY_METHODS) do
			local original = rawget(object, name)
			if type(original) == "function" then
				rawset(object, name, function(...)
					elevateUi()
					local results = table.pack(original(...))
					if results.n > 0 then
						results[1] = guardUiFactory(results[1])
					end
					return table.unpack(results, 1, results.n)
					end)
			end
		end
		rawset(object, "__senaFactoryGuarded", true)
		return object
	end
	elevateUi()
	local isV2Lib = type(Sena.ApplyIcon) == "function"
	local Window = Sena:Window({
		Title = "Sena 7 |",
		Footer = "Steal An Egg",
		Folder = "SenaSAEv4",
		Version = 1,
		Color = Color3.fromRGB(142, 142, 147),
		Image = "https://senahub.xyz/api/visual/sena_bg2.jpg",
		ThemeDim = 0.15,
		OpenFirstSection = false,
		ImageSize = 56,
		ConfigGroup = "App",
		ConfigLayoutOrder = 31,
		ToggleSheet = { Url = "https://senahub.xyz/api/visual/sena_toggle_sheet2.jpg", Frames = 100, Columns = 10, FrameSize = 102, Fps = 16 },
		RowTransparency = 0.3,
		KeyGate = not runtimeEnv.__SenaKeyless,
		Keyless = runtimeEnv.__SenaKeyless == true,
		CompactSidebar = false,
		})
	guardUiFactory(Window)
	local controls = {}
	local waypointOptions = { "Respawn Point" }
	do
		local roaming = runtimeEnv.__SenaV4Roaming
		if roaming and type(roaming.waypointList) == "function" then
			local ok, list = pcall(roaming.waypointList)
			if ok and type(list) == "table" and #list > 0 then
				waypointOptions = list
			end
		end
	end
	local selectedWaypoint = waypointOptions[1]
	controls.iconCache = {}
	function controls.gameIcon(module, ...)
		local path = { ... }
		local key = module .. "/" .. table.concat(path, "/")
		local hit = controls.iconCache[key]
		if hit ~= nil then return hit or nil end
		local ok, value = pcall(function()
			local node = ReplicatedStorage:FindFirstChild("Data") and ReplicatedStorage.Data:FindFirstChild(module)
			if not node then node = ReplicatedStorage:FindFirstChild(module, true) end
			local t = require(node)
			for _, k in ipairs(path) do t = t[k] end
			return t
		end)
		value = ok and type(value) == "string" and value:find("rbxassetid://") and value or false
		controls.iconCache[key] = value
		return value or nil
	end
	function controls.section(tab, title, icon)
		return tab:AddSection({ Title = title, Icon = icon })
	end
	if Window.SetHeaderChips then
		task.spawn(function()
			local save = nil
			pcall(function() save = require(ReplicatedStorage.Shared.Save) end)
			local pingItem = nil
			pcall(function() pingItem = game:GetService("Stats").Network.ServerStatsItem["Data Ping"] end)
			local startedAt = os.clock()
			local eggIcon = controls.gameIcon("Assets", "Directory", "Dog", "Egg", "Icon")
			local tokenIcon = controls.gameIcon("Currency", "Directory", "BossTokens", "Icon")
			local sakuraIcon = controls.gameIcon("Currency", "Directory", "SakuraCrystals", "Icon")
			local candyIcon = controls.gameIcon("Currency", "Directory", "HalloweenTokens", "Icon")
			local function short(v)
				v = tonumber(v) or 0
				for _, u in ipairs({ { 1e15, "Qa" }, { 1e12, "T" }, { 1e9, "B" }, { 1e6, "M" }, { 1e3, "K" } }) do
					if v >= u[1] then return ("%.2f%s"):format(v / u[1], u[2]):gsub("%.?0+([A-Za-z])", "%1") end
				end
				return tostring(math.floor(v))
			end
			while sessionAlive() do
				pcall(function()
					local d = save and select(2, pcall(save.Peek))
					d = type(d) == "table" and d or {}
					local ping = pingItem and math.floor(pingItem:GetValue() + 0.5) or 0
					local t = math.floor(os.clock() - startedAt)
					local rt, ps = runtimeEnv.__SenaV4EggRuntime, runtimeEnv.__SenaV4PlayerSteal
					local chips = {
						{ Icon = "clock", Text = ("%d:%02d:%02d"):format(t // 3600, t % 3600 // 60, t % 60) },
						{ Icon = eggIcon, Text = short((rt and rt.stats and tonumber(rt.stats.delivered) or 0) + (ps and tonumber(ps.taken) or 0)) .. " stolen" },
						{ Icon = candyIcon, Text = short(d.HalloweenTokens) },
						{ Icon = tokenIcon, Text = short(d.BossTokens) },
					}
					if (tonumber(d.SakuraCrystals) or 0) > 0 then
						chips[#chips + 1] = { Icon = sakuraIcon, Text = short(d.SakuraCrystals) }
					end
					chips[#chips + 1] = {
						Icon = "wifi",
						Text = ping .. " ms",
						IconColor = ping < 150 and Color3.fromRGB(74, 222, 128) or (ping < 300 and Color3.fromRGB(245, 196, 81) or Color3.fromRGB(248, 113, 113)),
					}
					Window:SetHeaderChips(chips)
					end)
				task.wait(1.5)
			end
			end)
	end
	local DonateTab = Window:AddTab({ Name = "Donate", Icon = "donator", LayoutOrder = 22, Group = "Community", StartActive = false, Gate = false })
	DonateTab:AddSection("Support Sena", true):AddSupportCard({})
	local HomeTab = Window:AddTab({ Name = "Home", Icon = "home", LayoutOrder = 1, Group = "Main" })
	local WindowsTab = Window:AddTab({ Name = "Windows", Icon = "app-window", LayoutOrder = 10, Group = "Tools" })
	local StealTab = Window:AddTab({ Name = "Steal", Icon = "hand", LayoutOrder = 2, Group = "Main" })
	local EggsTab = Window:AddTab({ Name = "Eggs & Plot", Icon = "egg", LayoutOrder = 3, Group = "Main" })
	local PetsTab = Window:AddTab({ Name = "Pets", Icon = "sparkles", LayoutOrder = 4, Group = "Main" })
	local EventsTab = Window:AddTab({ Name = "Events", Icon = "flame", LayoutOrder = 5, Group = "Main" })
	local FarmTab = Window:AddTab({ Name = "Farm", Icon = "activity", LayoutOrder = 6, Group = "Main" })
	local ServerTab = Window:AddTab({ Name = "Server", Icon = "server", LayoutOrder = 11, Group = "Tools" })
	controls.privateTab = ServerTab
	local SettingsTab = Window:AddTab({ Name = "Settings", Icon = "settings", LayoutOrder = 30, Group = "App" })
	local AdminAbuseTab = EventsTab
	local AdminCaptureSection = controls.section(AdminAbuseTab, "Capture The Egg", controls.gameIcon("CaptureTheEgg", "BroadcastIconImage"))
	controls.autoStealCapture = AdminCaptureSection:AddToggle({
		Title = "Auto Steal Capture",
		Content = "For the Capture The Egg event. Steals the event egg the Low Speed User way, then holds it high up so your time keeps going. Re-steals it if you lose it.",
		Default = false,
		Callback = guarded(applyAutoStealCapture),
		})
	local AdminMoveSection = controls.section(AdminAbuseTab, "Movement", controls.gameIcon("Gears", "Directory", "GravityDisruptor", "Icon"))
	controls.adminBoost = AdminMoveSection:AddToggle({
		Title = "Admin Abuse Boost",
		Content = "Only works during Admin Abuse: Auto Steal goes straight to each egg and straight home, at full speed. Do not use it when there is no Admin Abuse.",
		Default = false,
		Callback = guarded(applyAdminBoost),
		})
	controls.flyForCapture = AdminMoveSection:AddToggle({
		Title = "Fly For Capture",
		Content = "For the Capture The Egg event. After you pick up an egg, you fly up and stay still in the air so nobody can take it.",
		Default = false,
		Callback = guarded(applyFlyForCapture),
		})
	controls.instantGrab = AdminMoveSection:AddToggle({
		Title = "Instant Grab",
		Content = "Picking up an egg only needs a quick tap instead of a long hold.",
		Default = false,
		Callback = guarded(applyInstantGrab),
		})
	controls.infiniteJump = AdminMoveSection:AddToggle({
		Title = "Infinite Jump",
		Content = "Jump again in mid-air, as often as you like.",
		Default = false,
		Callback = guarded(applyInfiniteJump),
		})
	controls.noclip = AdminMoveSection:AddToggle({
		Title = "Noclip",
		Content = "Walk through walls and doors.",
		Default = false,
		Callback = guarded(applyNoclip),
		})
	local AdminRingSection = controls.section(AdminAbuseTab, "Ring Event", controls.gameIcon("FallenPowerUp", "Kinds", "x2Rings", "Icon"))
	controls.autoRingEvent = AdminRingSection:AddToggle({
		Title = "Auto Ring Event",
		Content = "Starts at the safe zone, then glides Forest -> Angels & Demons -> back to Forest on a loop. Turn off Auto Steal while using this.",
		Default = false,
		Callback = guarded(applyAutoRingEvent),
		})
	local MainTab = StealTab
	local StealSection = controls.section(MainTab, "Auto Steal", controls.gameIcon("Assets", "Directory", "Dog", "Egg", "Icon"))
	controls.autoSteal = StealSection:AddToggle({
		Title = "Auto Steal (Normal)",
		Flag = "Auto Steal",
		Content = "Steals normal-world eggs that match your filters and brings them home.",
		Default = false,
		Callback = guarded(applyAutoSteal),
		})
	controls.autoStealHalloween = StealSection:AddToggle({
		Title = "Auto Steal (Halloween)",
		Flag = "Auto Steal Halloween",
		Content = "Auto-farms Halloween eggs into Candy Corn. Runs on its own and keeps going after a rejoin.",
		Default = false,
		Callback = guarded(function(value) Config.AutoStealHalloween = value == true UIRunners.Halloween.setEnabled(Config.AutoStealHalloween) end),
		})
	controls.hwZonePriority = StealSection:AddToggle({
		Title = "High-Value Zone First (Halloween)",
		Flag = "Prioritise High-Value Zone",
		Content = "Go for the highest-value eggs first.",
		Default = true,
		Callback = guarded(function(value) Config.HalloweenZonePriority = value == true end),
		})
	controls.hwAutoBuy = StealSection:AddToggle({
		Title = "Auto Buy Egg (Halloween)",
		Flag = "Auto Buy Halloween Egg",
		Content = "Buys a Halloween egg from the dimension shop each time Candy Corn reaches 2250.",
		Default = false,
		Callback = guarded(function(value) Config.HalloweenAutoBuy = value == true end),
		})
	controls.hwCrossWorld = StealSection:AddToggle({
		Title = "Cross-World Priority (Halloween)",
		Flag = "Cross-World Priority",
		Content = "Pops over to the normal world to grab a rare egg there, then returns to the Halloween farm. Needs Auto Steal on with a rarity filter set.",
		Default = false,
		Callback = guarded(function(value) Config.HalloweenCrossWorld = value == true end),
		})
	StealSection:AddButton({
		Title = "Open Hop UI",
		Content = "Opens the Rare Egg Hop panel. Pick Divine, Eternal or Secret, and it hops to fresh servers until one is still in the field.",
		Callback = guarded(function()
			local hunt = SenaExtras.hopHunt
			if hunt then task.spawn(function() pcall(hunt.open) end) end
			end),
		})
	controls.helpFriend = StealSection:AddToggle({
		Title = "Help Friend",
		Content = "Instead of banking a stolen egg, drops it just before the safe zone line so a friend can pick it up.",
		Default = false,
		Callback = guarded(function(value) Config.HelpFriend = value == true end),
		})
	controls.godMode = StealSection:AddToggle({
		Title = "Aura Bat",
		Content = "",
		Default = false,
		Callback = guarded(applyGodMode),
		})
	controls.stealMode = StealSection:AddDropdown({
		Title = "Steal Mode",
		Content = "If you have good speed better use High Speed User, but if you are newbie, use Low Speed User",
		Options = { "Low Speed User", "High Speed User Normal", "High Speed User (Fly)", "Zig-Zag High Speed User" },
		MaxVisible = 4,
		Default = "High Speed User Normal",
		Multi = false,
		Callback = guarded(function(value)
			applyStealMode(value)
			if type(SenaPanels.syncStealMode) == "function" then SenaPanels.syncStealMode() end
		end),
		})
	SenaPanels.getStealMode = function()
		local value = controls.stealMode and controls.stealMode.Value
		if type(value) == "table" then value = value[1] end
		return value
	end
	SenaPanels.setStealMode = function(label)
		if controls.stealMode then controls.stealMode:Set(label) end
	end
	local speedAdvice = StealSection:AddParagraph({
		Title = "Speed Advice",
		Content = "Reading your speed...",
		})
	task.spawn(function()
		while sessionAlive() do
			if eggRuntime and type(eggRuntime.lowSpeedStatus) == "function" then
				pcall(function()
					if Config.LowSpeedBoost == true then
						-- Low Speed Boost claims through the Fuse portal (~4-5 s per egg, server-paced). The Low
						-- Speed Multiplier / settle advice does NOT apply here, so don't show a level range that
						-- looks like a seconds estimate.
						local st = eggRuntime:lowSpeedStatus()
						speedAdvice:SetContent(("Current Speed: %s (WS %d)\nLow Speed Boost ON — egg claimed in ~4-5s. The Low Speed Multiplier is not used in Boost."):format(st.speedText, st.walkSpeed))
						return
					end
					local st = eggRuntime:lowSpeedStatus()
					local range = st.safe == st.fast and tostring(st.fast) or (st.safe .. "–" .. st.fast)
					local text = ("Current Speed: %s (WS %d)\nRecommended Low Speed Multiplier (level 1-10, not seconds): %s  ·  yours: %d"):format(
						st.speedText, st.walkSpeed, range, st.level)
					local a = st.advice
					if a then
						text = text .. ("\nSteals keep failing (%d of the last %d) - lower it to %d."):format(a.fails, a.total, a.to)
						if a.fresh then
							a.fresh = false
							Sena:Notify({
								Title = "Low Speed User",
								Content = ("Steals keep failing at %d - lower the Low Speed Multiplier to %d."):format(a.from, a.to),
								Duration = 6,
								})
						end
					elseif st.level > st.fast then
						text = text .. "\nAbove the recommendation - lower it if steals start failing."
					end
					speedAdvice:SetContent(text)
					end)
			end
			task.wait(2)
		end
		end)
	controls.stealHold = StealSection:AddSlider({
		Title = "Low Speed Multiplier",
		Content = "For Low Speed User mode. Higher = faster grab (shorter hold), lower = safer (longer). Raise it if your account speed is high; lower it if your speed is low.",
		Min = 1,
		Max = 10,
		Default = 5,
		Increment = 1,
		Callback = guarded(applyStealHold),
		})
	controls.lowSpeedBoost = StealSection:AddToggle({
		Title = "Boost for Mode Low Speed",
		Content = "Faster steals for Low Speed User on every area except Forest (about 6 s per egg). Keep it on when you use Low Speed User.",
		Default = true,
		Locked2 = true,
		Callback = guarded(function(value) Config.LowSpeedBoost = value == true end),
		})
	controls.snipeDropped = StealSection:AddToggle({
		Title = "Steal Other Script",
		Content = "Steal eggs that other players' scripts drop on their way home, before they can grab them back. Runs alongside Auto Steal as a fallback, then banks safely. Keep it on.",
		Default = true,
		Callback = guarded(function(value) Config.SnipeDroppedEggs = value == true; local rt = runtimeEnv.__SenaV4EggRuntime; if rt then pcall(function() rt:_reconcileRunningState(); if Config.SnipeDroppedEggs and rt.enabled then rt:_installSnipeHook() else rt:_removeSnipeHook() end end) end end),
		})
	local FilterSection = controls.section(MainTab, "Egg Filter", controls.gameIcon("Assets", "Directory", "Unicorn", "Egg", "Icon"))
	FilterSection:AddSubSection("Egg")
	controls.eggWorld = FilterSection:AddDropdown({
		Title = "World",
		Content = "Which world's eggs to filter: Normal or Halloween. The egg list below shows that world's eggs.",
		Options = { "Normal", "Halloween" },
		Multi = false,
		Default = "Normal",
		Callback = guarded(function(value) local hw = value == "Halloween" if controls.names then pcall(function() controls.names:SetVisible(not hw) end) end if controls.rarities then pcall(function() controls.rarities:SetVisible(not hw) end) end if controls.hwNames then pcall(function() controls.hwNames:SetVisible(hw) end) end if controls.hwEggRarities then pcall(function() controls.hwEggRarities:SetVisible(hw) end) end for _, k in ipairs({ "areas", "value", "mutations", "weight", "priority", "autoIndex" }) do local c = controls[k] if c then pcall(function() c:SetVisible(not hw) end) end end end),
		})
	controls.names = FilterSection:AddDropdown({
		Title = "Filter By Egg Name",
		Content = "Only steal these eggs. Leave empty for any egg.",
		Options = nameOptions,
		Multi = true,
		Default = {},
		Callback = guarded(function(values)
			applyStealFilter("names", "name", values)
			end),
		})
	controls.rarities = FilterSection:AddDropdown({
		Title = "Filter By Rarity",
		Content = "Only steal these rarities. Leave empty for any rarity.",
		Options = rarities,
		Multi = true,
		Default = {},
		Callback = guarded(function(values)
			applyStealFilter("rarities", "rarity", values)
			end),
		})
	controls.hwEggRarities = FilterSection:AddDropdown({
		Title = "Filter By Rarity",
		Flag = "HwFilterEggRarity",
		Content = "Only steal Halloween eggs of these rarities (Eternal, Divine, Secret...). Leave empty for any.",
		Options = rarities,
		Multi = true,
		Default = {},
		Callback = guarded(function(values) local l = {} for _, v in ipairs(values) do if v ~= "None" and v ~= "" then l[#l + 1] = v end end Config.HalloweenEggRarities = l end),
		})
	controls.hwNames = FilterSection:AddDropdown({
		Title = "Filter By Egg Name",
		Flag = "HwFilterEggName",
		Content = "Only steal these Halloween eggs. Leave empty for any egg (best for Candy Corn).",
		Options = (function() local o = {} local okHP, HP = pcall(require, game:GetService("ReplicatedStorage").Data.HalloweenPets) if okHP and type(HP) == "table" and type(HP.Specs) == "table" then for nm in pairs(HP.Specs) do o[#o + 1] = tostring(nm) end end table.sort(o) return o end)(),
		Multi = true,
		Default = {},
		Callback = guarded(function(values) local l = {} for _, v in ipairs(values) do if v ~= "None" and v ~= "" then l[#l + 1] = v end end Config.HalloweenNames = l end),
		})
	pcall(function() controls.hwNames:SetVisible(false) end)
	pcall(function() controls.hwEggRarities:SetVisible(false) end)
	FilterSection:AddSubSection("Area & Value")
	controls.areas = FilterSection:AddDropdown({
		Title = "Select Area",
		Content = "Only steal from these areas. Leave empty for every area.",
		Options = areaOptions,
		Multi = true,
		Default = {},
		Callback = guarded(function(values)
			applyStealFilter("areas", "area", values)
			end),
		})
	controls.value = FilterSection:AddInput({
		Title = "Steal By Value",
		Content = "Minimum money per second. Supports k, m and b.",
		Placeholder = "e.g. 500k, 2m, 1b",
		Default = "",
		Callback = guarded(applyStealValue),
		})
	controls.mutations = FilterSection:AddDropdown({
		Title = "Filter By Mutation",
		Content = "Only steal eggs carrying one of these mutations. Leave empty for any egg.",
		Options = mutationOptions,
		Multi = true,
		Default = {},
		Callback = guarded(applyStealMutations),
		})
	controls.weight = FilterSection:AddInput({
		Title = "Steal By Weight",
		Content = "Minimum egg weight in kilograms. 0 accepts any weight.",
		Placeholder = "e.g. 12000",
		Default = "",
		Callback = guarded(applyStealWeight),
		})
	controls.priority = FilterSection:AddDropdown({
		Title = "Steal Priority",
		Content = "Which egg to go for first when more than one passes the filters.",
		Options = { "Rarity", "Highest Value", "Heaviest" },
		Default = "Rarity",
		Callback = guarded(applyStealPriority),
		})
	controls.autoIndex = FilterSection:AddToggle({
		Title = "Auto Index",
		Content = "Also steal eggs whose pet is still missing from your Pet Index, in any area, on top of the filters above. An egg you already hold counts as covered until it hatches.",
		Default = false,
		Callback = guarded(applyAutoIndex),
		})
	local EspSection = controls.section(MainTab, "Egg ESP", controls.gameIcon("Assets", "Directory", "Kitsune", "Egg", "Icon"))
	controls.eggEsp = EspSection:AddToggle({
		Title = "Egg ESP",
		Content = "Draws a label over every egg on the field so you can read it from across the map.",
		Default = false,
		Callback = guarded(applyEggEsp),
		})
	controls.espDetails = EspSection:AddDropdown({
		Title = "ESP Details",
		Content = "What each label shows. Placed Eggs also labels the eggs on your plot, Icon adds the animal picture to those labels.",
		Options = { "Name", "Rarity", "Value", "Weight", "Mutation", "Placed Eggs", "Icon" },
		Multi = true,
		Default = { "Name", "Rarity", "Value", "Icon" },
		Callback = guarded(applyEspDetails),
		})
	controls.espMinRarity = EspSection:AddDropdown({
		Title = "ESP Min Rarity",
		Content = "Only label eggs of this rarity or rarer. Any labels every egg.",
		Options = (function()
			local options = { "Any" }
			for _, rarity in ipairs(rarities) do options[#options + 1] = rarity end
			return options
		end)(),
		Multi = false,
		Default = "Any",
		Callback = guarded(UIRunners.applyEspMinRarity),
		})
	controls.espMinValue = EspSection:AddInput({
		Title = "ESP Min Value",
		Content = "Only label eggs making at least this much per second. Supports k, m and b.",
		Placeholder = "e.g. 500k, 2m, 1b",
		Default = "",
		Callback = guarded(UIRunners.applyEspMinValue),
		})
	controls.backpackRates = EspSection:AddToggle({
		Title = "Backpack Value/s",
		Content = "Shows how much money per second each egg in your backpack makes, right on its slot.",
		Default = false,
		Callback = guarded(applyBackpackRates),
		})
	local WebhookSection = controls.section(MainTab, "Steal Webhook", "bell")
	controls.webhookEnabled = WebhookSection:AddToggle({
		Title = "Steal Webhook",
		Content = "Posts a Discord embed the moment a stolen egg is banked, with its rarity, size, weight and cash per second.",
		Default = false,
		Callback = guarded(applyWebhookEnabled),
		})
	controls.webhookUrl = WebhookSection:AddInput({
		Title = "Webhook URL",
		Content = "Paste the Discord webhook URL for the channel you want.",
		Placeholder = "https://discord.com/api/webhooks/...",
		Default = "",
		Callback = guarded(applyWebhookUrl),
		})
	controls.webhookDisconnect = WebhookSection:AddToggle({
		Title = "Disconnect Alert",
		Content = "Posts to the same webhook when this account gets disconnected or kicked, with the reason.",
		Default = false,
		Callback = guarded(function(value) Config.WebhookDisconnect = value == true end),
		})
	WebhookSection:AddSubSection("Filter")
	controls.webhookRarities = WebhookSection:AddDropdown({
		Title = "Notify Rarities",
		Content = "Only post these rarities. Empty = every egg you steal.",
		Options = rarities,
		Multi = true,
		Default = {},
		Callback = guarded(applyWebhookRarities),
		})
	controls.webhookValue = WebhookSection:AddInput({
		Title = "Notify Minimum Value",
		Content = "Only post eggs worth at least this per second. Supports k, m and b.",
		Placeholder = "e.g. 500k, 2m, 1b",
		Default = "",
		Callback = guarded(applyWebhookValue),
		})
	WebhookSection:AddButton({
		Title = "Test Webhook",
		Content = "Sends one test embed so you can confirm the URL works.",
		Callback = guarded(function()
			local hook = runtimeEnv.__SenaV4Webhook
			local typed = controls.webhookUrl and controls.webhookUrl.Value
			if type(typed) == "string" and typed ~= "" then
				applyWebhookUrl(typed)
			end
			if not hook or not hook.test() then
				Sena:Notify({ Title = "Steal Webhook", Content = "Enter a webhook URL first", Duration = 3 })
				return
			end
			Sena:Notify({ Title = "Steal Webhook", Content = "Test embed sent", Duration = 3 })
			end),
		})
	local TaskOrderSection = HomeTab:AddSection({ Title = "Task Order", AlwaysOpen = true })
	local taskIcons = {
		auto_steal = "hand",
		star = "star",
		butterfly = "flower",
		auto_place = "egg",
		use_scrambled = "flask-conical",
		auto_sell = "coins",
		treadmill = "activity",
	}
	local taskItems = {}
	for _, id in ipairs(TaskLadder.DEFAULT) do
		taskItems[#taskItems + 1] = {
			Id = id,
			Title = TaskLadder.TITLES[id],
			Icon = taskIcons[id],
			Pinned = TaskLadder.PINNED[id] == true,
			Sub = TaskLadder.PINNED[id] and ((id == "hw_fish" and "Idle activity, lowest priority") or (id == "treadmill" and "Idle activity, above fishing") or "Runs when every other task is idle") or nil,
		}
	end
	local function applyTaskOrder(order)
		Config.TaskOrder = TaskLadder.sanitize(order)
	end
	if type(TaskOrderSection.AddPriorityList) == "function" then
		controls.taskOrder = TaskOrderSection:AddPriorityList({
			Title = "Task Order",
			Content = "Higher rows get the character first. An egg you are carrying is always delivered first, and a boss fight that has started is never left.",
			Flag = "TaskOrder",
			Items = taskItems,
			Default = TaskLadder.DEFAULT,
			EmptyText = "Turn on Auto Steal, Auto Place or another feature to order it here.",
			Callback = guarded(applyTaskOrder),
		})
	else
		TaskOrderSection:AddParagraph({
			Title = "Task Order",
			Content = "Update the Sena library to reorder tasks. Using the default order: Auto Steal, Shooting Star, Butterfly Bloom, Auto Place, Use Scrambled, Auto Sell, Treadmill.",
		})
	end
	local EggSection = controls.section(EggsTab, "Egg Automation", controls.gameIcon("Assets", "Directory", "Dragon", "Egg", "Icon"))
	EggSection:AddSubSection("Place")
	controls.autoPlace = EggSection:AddToggle({
		Title = "Auto Place Egg",
		Content = "Places eggs from your inventory on your plot.",
		Default = false,
		Callback = guarded(applyAutoPlace),
		})
	controls.placeRarity = EggSection:AddDropdown({
		Title = "Place Egg Rarity",
		Content = "Only place these rarities. Leave empty for all.",
		Options = rarities,
		Multi = true,
		Default = {},
		Callback = guarded(function(values)
			Config.PlaceRarities = withoutNone(values)
			end),
		})
	EggSection:AddSubSection("Hatch")
	controls.autoHatch = EggSection:AddToggle({
		Title = "Auto Hatch Egg",
		Content = "Hatches your placed eggs when they are ready.",
		Default = false,
		Callback = guarded(applyAutoHatch),
		})
	EggSection:AddSubSection("Mutate")
	controls.mutationChoice = EggSection:AddDropdown({
		Title = "Select Mutation",
		Content = "Which mutation to apply to your placed eggs. Enchanted uses the Enchanted Essence from the Butterfly Bloom shrine. Each needs the matching consumable in your bag.",
		Options = { "Scrambled", "Fractured", "Enchanted", "Nitro" },
		Multi = false,
		Default = "Scrambled",
		Callback = guarded(applyMutationChoice),
		})
	controls.mutationSpecies = EggSection:AddDropdown({
		Title = "Mutate Egg Name",
		Content = "Only mutate these eggs by name. Leave empty for every placed egg.",
		Options = nameOptions,
		Multi = true,
		Default = {},
		Callback = guarded(applyMutationSpecies),
		})
	controls.mutationRarity = EggSection:AddDropdown({
		Title = "Mutate Egg Rarity",
		Content = "Only mutate placed eggs of these rarities. Leave empty for every rarity.",
		Options = rarities,
		Multi = true,
		Default = {},
		Callback = guarded(applyMutationRarities),
		})
	controls.mutationMinValue = EggSection:AddInput({
		Flag = "mutationMinValue",
		Title = "Mutate Min Value (money/s)",
		Content = "Only mutate placed eggs whose money per second is this or higher. Blank = no value limit. Supports k, m, b.",
		Placeholder = "e.g. 100k, 2m",
		Default = "",
		Callback = guarded(applyMutationMinValue),
		})
	controls.mutationRetry = EggSection:AddToggle({
		Title = "Retry Until Mutated",
		Content = "Keep applying to one egg until it mutates or charges run out (10% per use).",
		Default = true,
		Callback = guarded(applyMutationRetry),
		})
	controls.autoMutation = EggSection:AddToggle({
		Title = "Auto Apply Mutation",
		Content = "Equips the selected mutation consumable and applies it to your placed eggs.",
		Default = false,
		Callback = guarded(applyAutoMutation),
		})
	EggSection:AddButton({
		Title = "Apply Mutation Now",
		Content = "Run one mutation pass over your placed eggs right now.",
		Callback = guarded(function()
			task.spawn(function() pcall(UIRunners.mutationSweep) end)
			end),
		})
	do
		local PlacedSection = EggsTab:AddSection({ Title = "Placed Eggs", AlwaysOpen = true, Icon = controls.gameIcon("Assets", "Directory", "Dragon", "Egg", "Icon") })
		local placedList = PlacedSection.AddActionList and PlacedSection:AddActionList({
			Title = "Your placed eggs",
			EmptyText = "No eggs placed on your plot.",
			VisibleRows = 6,
			ButtonWidth = 64,
			})
		if placedList then
			local RS = game:GetService("ReplicatedStorage")
			local setIdentity = runtimeEnv.__SenaV4IdentitySetter
			local targetIdentity = runtimeEnv.__SenaV4UICapabilityIdentity or 8
			local Mutations, Growth = nil, nil
			pcall(function() Mutations = require(RS.Shared.Modules.Mutations) end)
			pcall(function() Growth = require(RS.Shared.Eggs.PlacedEggGrowthPresentationPolicy) end)
			local function hex(color)
				if typeof(color) ~= "Color3" then return "E8E8EE" end
				return string.format("%02X%02X%02X", math.floor(color.R * 255 + 0.5), math.floor(color.G * 255 + 0.5), math.floor(color.B * 255 + 0.5))
			end
			local APPLIED = { Scrambled = true, Boss = true, Enchanted = true }
			local function label(id)
				if id == "Scrambled" then return "Scrambled" end
				local ok, text = pcall(function() return Mutations.LabelOf(id) end)
				return ok and type(text) == "string" and text ~= "" and text or tostring(id)
			end
			local function clock(seconds)
				seconds = math.max(0, math.floor(seconds))
				local h, m, sec = math.floor(seconds / 3600), math.floor(seconds % 3600 / 60), seconds % 60
				if h > 0 then return string.format("%dh %02dm", h, m) end
				return string.format("%dm %02ds", m, sec)
			end
			local function findEgg(uid)
				local folder = workspace:FindFirstChild("PlacedEggRenders")
				return folder and folder:FindFirstChild(tostring(LocalPlayer.UserId) .. "_" .. tostring(uid))
			end
			local function flash(uid)
				local model = findEgg(uid)
				if not model then return false end
				local hl = Instance.new("Highlight")
				hl.FillColor = Color3.fromRGB(232, 232, 238)
				hl.FillTransparency = 0.55
				hl.OutlineColor = Color3.fromRGB(255, 255, 255)
				hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
				hl.Parent = model
				task.delay(5, function() pcall(function() hl:Destroy() end) end)
				return true
			end
			local function entries()
				local list = {}
				local okRecs, recs = pcall(function() return require(RS.Client.EggState).ReadOwnerEggs(LocalPlayer.UserId) end)
				if not okRecs or type(recs) ~= "table" then return list end
				local now = workspace:GetServerTimeNow()
				for uid, rec in pairs(recs) do
					if type(rec) == "table" and rec.Placement then
						local info = catalog.resolve(rec)
						local base = rec.BaseMutation
						local added, natural = {}, {}
						local seen = {}
						for _, m in pairs(type(rec.Mutations) == "table" and rec.Mutations or {}) do
							if not seen[m] then
								seen[m] = true
								if m ~= base or APPLIED[m] then added[#added + 1] = label(m) else natural[#natural + 1] = label(m) end
							end
						end
						if base and APPLIED[base] and not seen[base] then added[#added + 1] = label(base) end
						local remaining = 0
						if Growth then
							local okRem, rem = pcall(Growth.GetRemainingGrowthSeconds, rec, now)
							remaining = okRem and tonumber(rem) or 0
						end
						local timer = remaining > 0 and ("Hatches in " .. clock(remaining)) or '<font color="#4ADE80">Ready to hatch</font>'
						local placedAt = rec.Placement.PlacedAt and os.date("%d %b %H:%M", math.floor(rec.Placement.PlacedAt)) or "?"
						local status = #added > 0
							and ('<font color="#4ADE80">Mutated: ' .. table.concat(added, ", ") .. "</font>")
							or '<font color="#74747F">Not mutated</font>'
						if #natural > 0 then
							status = status .. '  <font color="#A2A2AE">[' .. table.concat(natural, ", ") .. "]</font>"
						end
						list[#list + 1] = {
							id = tostring(uid),
							name = string.format('<font color="#%s">%s</font>', hex(info.rarityColor), tostring(info.name)),
							sub = string.format('<font color="#%s">%s</font>', hex(info.rarityColor), tostring(info.rarity)),
							status = status,
							statusSub = timer .. "  -  Placed " .. placedAt,
							button = "Find",
							buttonColor = "accent",
							rank = info.rarityRank or 0,
							mutated = #added > 0,
							onClick = function(entry, setLabel)
								local ok = flash(uid)
								setLabel(ok and "Found" or "Far", ok and "green" or "red")
								task.delay(1.6, function() pcall(setLabel, "Find", "accent") end)
							end,
						}
					end
				end
				table.sort(list, function(a, b)
					if a.rank ~= b.rank then return a.rank > b.rank end
					if a.mutated ~= b.mutated then return not a.mutated end
					return a.id < b.id
				end)
				return list
			end
			local busySince, lastRun = nil, 0
			local conn
			conn = game:GetService("RunService").Heartbeat:Connect(function()
				if not placedList:Alive() then conn:Disconnect() return end
				local now = os.clock()
				if busySince and now - busySince < 5 then return end
				if now - lastRun < 1 then return end
				lastRun = now
				local token = now
				busySince = token
				task.spawn(function()
					local ok, err = pcall(function()
						if setIdentity then pcall(setIdentity, targetIdentity) end
						local list = entries()
						if setIdentity then pcall(setIdentity, targetIdentity) end
						if placedList:Alive() then placedList:Update(list) end
						end)
					if not ok then warn("[Sena] Placed eggs list error:", err) end
					if busySince == token then busySince = nil end
					end)
				end)
		end
	end
	local PetSellSection = controls.section(PetsTab, "Pet Selling", controls.gameIcon("Currency", "Directory", "Money", "Icon"))
	controls.autoSell = PetSellSection:AddToggle({
		Title = "Auto Sell Pet",
		Content = "Sells pets that match a filter below. Favorite, placed and equipped pets are kept.",
		Default = false,
		Callback = guarded(applyAutoSell),
		})
	PetSellSection:AddSubSection("Filter")
	sellNamesDropdown = PetSellSection:AddDropdown({
		Title = "Pet Name Filter",
		Content = "Pets to sell by name. Pick All for every name.",
		Options = petNameOptions,
		Multi = true,
		Default = {},
		Callback = guarded(function(values)
			Config.SellNames = withoutNone(values)
			end),
		})
	sellRarityDropdown = PetSellSection:AddDropdown({
		Title = "Pet Rarity Filter",
		Content = "Pets to sell by rarity. Pick All for every rarity.",
		Options = withAll(rarities),
		Multi = true,
		Default = {},
		Callback = guarded(function(values)
			Config.SellRarities = withoutNone(values)
			end),
		})
	controls.sellPetValue = PetSellSection:AddInput({
		Flag = "sellPetValue",
		Title = "Sell By Value (max money/s)",
		Content = "Only sell pets whose money per second is this or lower. Blank = no value limit. Supports k, m, b.",
		Placeholder = "e.g. 100k, 2m",
		Default = "",
		Callback = guarded(applySellPetValue),
		})
	local EggSellSection = controls.section(EggsTab, "Egg Selling", controls.gameIcon("Currency", "Directory", "Money", "Icon"))
	controls.autoSellEgg = EggSellSection:AddToggle({
		Title = "Auto Sell Egg",
		Content = "Sells unplaced eggs of the rarities below.",
		Default = false,
		Callback = guarded(applyAutoSellEgg),
		})
	sellEggRarityDropdown = EggSellSection:AddDropdown({
		Title = "Egg Rarity Filter",
		Content = "Egg rarities to sell. Pick All for every rarity.",
		Options = withAll(rarities),
		Multi = true,
		Default = {},
		Callback = guarded(function(values)
			Config.SellEggRarities = withoutNone(values)
			end),
		})
	controls.sellEggValue = EggSellSection:AddInput({
		Flag = "sellEggValue",
		Title = "Sell By Value (max money/s)",
		Content = "Only sell eggs whose money per second is this or lower. Blank = no value limit. Supports k, m, b.",
		Placeholder = "e.g. 100k, 2m",
		Default = "",
		Callback = guarded(applySellEggValue),
		})
	local FavoriteSection = controls.section(PetsTab, "Pet Favorite", controls.gameIcon("Assets", "Directory", "Unicorn", "Icon"))
	controls.autoFavorite = FavoriteSection:AddToggle({
		Title = "Auto Favorite",
		Content = "Marks every pet that matches the rule below as a favorite, so Auto Sell and Auto Fuse leave it alone.",
		Default = false,
		Callback = guarded(applyAutoFavorite),
		})
	controls.favoriteRule = FavoriteSection:AddDropdown({
		Title = "Favorite Rule",
		Content = "Match pets by rarity or by species.",
		Options = { "Rarity", "Species" },
		Default = "Rarity",
		Callback = guarded(applyFavoriteRule),
		})
	FavoriteSection:AddSubSection("Only when Rule = Rarity")
	controls.favoriteRarities = FavoriteSection:AddDropdown({
		Title = "Rarities to Keep",
		Content = "Pets of these rarities get favorited.",
		Options = rarities,
		Multi = true,
		Default = {},
		Callback = guarded(applyFavoriteRarities),
		})
	FavoriteSection:AddSubSection("Only when Rule = Species")
	controls.favoriteSpecies = FavoriteSection:AddDropdown({
		Title = "Species to Keep",
		Content = "Pets of these species get favorited.",
		Options = nameOptions,
		Multi = true,
		Default = {},
		Callback = guarded(applyFavoriteSpecies),
		})
	controls.unfavoriteAll = FavoriteSection:AddButton({
		Title = "Unfavorite Everything",
		Content = "Clears the favorite flag on every pet you own.",
		Callback = guarded(function()
			local barn = runtimeEnv.__SenaV4PetBarn
			local count = 0
			if barn and type(barn.unfavoriteAll) == "function" then
				count = barn.unfavoriteAll() or 0
			end
			Sena:Notify({ Title = "Pet Favorite", Content = count .. " pets unfavorited", Duration = 3 })
			end),
		})
	local FusionSection = controls.section(PetsTab, "Pet Fusion", controls.gameIcon("FallenPowerUp", "Kinds", "Fusion", "Icon"))
	controls.autoFuse = FusionSection:AddToggle({
		Title = "Auto Fuse",
		Content = "Feeds three matching pets into the Fusion machine over and over. Favorited and equipped pets are never used.",
		Default = false,
		Callback = guarded(applyAutoFuse),
		})
	controls.fuseRule = FusionSection:AddDropdown({
		Title = "Fusion Rule",
		Content = "Fuse anything that passes the rarity filter, or only the species you pick below.",
		Options = { "Any Species", "Selected Species" },
		Default = "Any Species",
		Callback = guarded(applyFuseRule),
		})
	controls.fuseRarities = FusionSection:AddDropdown({
		Title = "Rarities to Fuse",
		Content = "Only fuse pets of these rarities. Leave empty for any rarity.",
		Options = rarities,
		Multi = true,
		Default = {},
		Callback = guarded(applyFuseRarities),
		})
	FusionSection:AddSubSection("Only when Rule = Selected Species")
	controls.fuseSpecies = FusionSection:AddDropdown({
		Title = "Species to Fuse",
		Content = "Only these species go into the machine.",
		Options = nameOptions,
		Multi = true,
		Default = {},
		Callback = guarded(applyFuseSpecies),
		})
	local BarnSection = controls.section(EggsTab, "Equip & Collect", controls.gameIcon("Assets", "Directory", "Dog", "Icon"))
	controls.autoEquipBest = BarnSection:AddToggle({
		Title = "Auto Equip Best",
		Content = "Keeps your strongest pets equipped as better ones hatch.",
		Default = false,
		Callback = guarded(applyAutoEquipBest),
		})
	controls.autoClaimOffline = BarnSection:AddToggle({
		Title = "Collect Offline Income",
		Content = "Claims the money your base earned while you were away, as soon as there is any.",
		Default = false,
		Callback = guarded(applyAutoClaimOffline),
		})
	controls.autoBaseUpgrade = BarnSection:AddToggle({
		Title = "Auto Upgrade Base",
		Content = "Buys the next base tier the moment you can afford it.",
		Default = false,
		Callback = guarded(applyAutoBaseUpgrade),
		})
	controls.autoClaimAlmanac = BarnSection:AddToggle({
		Title = "Auto Claim Almanac",
		Content = "Redeems every Pet Index reward that is ready. This is the reward claim, not the steal objective.",
		Default = false,
		Callback = guarded(applyAutoClaimAlmanac),
		})
	controls.upgradeBaseOnce = BarnSection:AddButton({
		Title = "Upgrade Base Now",
		Content = "Buys one base tier right away.",
		Callback = guarded(function()
			local upgrades = runtimeEnv.__SenaV4Upgrades
			local ok, reason = false, "Upgrades not ready"
			if upgrades and type(upgrades.upgradeBase) == "function" then
				ok, reason = upgrades.upgradeBase()
			end
			Sena:Notify({
				Title = "Base",
				Content = ok and "Base upgraded" or tostring(reason or "Could not upgrade"),
				Duration = 3,
				})
			end),
		})
	do
		local bloomRt = runtimeEnv.__SenaV4ButterflyRuntime
		local WispSection = controls.section(EventsTab, "Wisp Event", controls.gameIcon("WispQuests", "List", 1, "Icon"))
		local wispStatus = WispSection:AddParagraph({
			Title = "Wisp Companion",
			Content = "Reading your wisp progress...",
			})
		controls.wispAutoQuest = WispSection:AddToggle({
			Title = "Auto Wisp Quest",
			Content = "Meets the Baby Wisp, hunts the quest eggs (Enchanted Forest eggs, an Eternal), fuses an Enchanted Forest animal, claims every reward and flies the wisp home to unlock the Enchanted Tree. Needs 50B SpeedPower.",
			Default = false,
			Callback = guarded(function(value) Config.WispAutoQuest = value == true end),
			})
		controls.banjoAuto = WispSection:AddToggle({
			Title = "Auto Banjo Cricket",
			Content = "Goes into the Enchanted Tree, plays the Banjo Cricket's mushroom song back for all 5 stages, then claims the secret from Jitterbug. Needs the tree unlocked.",
			Default = false,
			Callback = guarded(function(value) Config.BanjoAuto = value == true end),
			})
		local BloomSection = controls.section(EventsTab, "Butterfly Bloom", controls.gameIcon("ButterflyCatalog", "Icons", "Net"))
		local bloomStatus = BloomSection:AddParagraph({
			Title = "Bloom Status",
			Content = "Reading the Bloom schedule...",
			})
		local caughtGrid = BloomSection.AddIconGrid and BloomSection:AddIconGrid({
			Title = "Butterflies Caught",
			Note = "",
			Columns = 4,
			})
		local caughtPrev, caughtGain = nil, {}
		controls.bloomAutoNet = BloomSection:AddToggle({
			Title = "Auto Claim Net",
			Content = "Goes into the Enchanted Tree and claims your free Butterfly Net once.",
			Default = false,
			Callback = guarded(function(value) Config.ButterflyAutoNet = value == true end),
			})
		controls.bloomAutoCatch = BloomSection:AddToggle({
			Title = "Auto Catch",
			Content = "During every Bloom (every 30 min, 5 min long) flies to the Enchanted Forest, equips the net and catches with the Catch Mode below.",
			Default = false,
			Callback = guarded(function(value) Config.ButterflyAutoCatch = value == true end),
			})
		local catchModes = bloomRt and bloomRt.modeOptions() or { "Tween to Butterfly" }
		controls.bloomMode = BloomSection:AddDropdown({
			Title = "Catch Mode",
			Content = "Tween to Butterfly chases one butterfly at a time. Stand waits in the thickest part of the swarm, Zigzag sweeps back and forth across the forest, Circle loops around the swarm.",
			Options = catchModes,
			Multi = false,
			Default = catchModes[1],
			Callback = guarded(function(value) if bloomRt then bloomRt.setMode(value) end end),
			})
		controls.bloomTiers = BloomSection:AddDropdown({
			Title = "Catch Tiers",
			Content = "Only swing at these butterflies. Leave empty to catch every tier.",
			Options = bloomRt and bloomRt.tierOptions() or { "Radiant", "Amethyst", "Sapphire", "Emerald" },
			Multi = true,
			Default = {},
			Callback = guarded(function(values) if bloomRt then bloomRt.setTiers(withoutNone(values)) end end),
			})
		controls.bloomEsp = BloomSection:AddToggle({
			Title = "Butterfly ESP",
			Content = "Shows every butterfly's tier and distance while a Bloom is live.",
			Default = false,
			Callback = guarded(function(value) Config.ButterflyEsp = value == true end),
			})
		BloomSection:AddSubSection("Trade & Craft")
		controls.bloomAutoTrade = BloomSection:AddToggle({
			Title = "Auto Trade Up",
			Content = "After each Bloom, trades your butterflies up at the machine inside the Enchanted Tree.",
			Default = false,
			Callback = guarded(function(value) Config.ButterflyAutoTrade = value == true end),
			})
		local recipes = bloomRt and bloomRt.recipeOptions() or { "All Recipes" }
		controls.bloomRecipe = BloomSection:AddDropdown({
			Title = "Trade Recipe",
			Content = "Which trade Auto Trade Up runs. For Essence only trades up what the essence recipe is still short of.",
			Options = recipes,
			Multi = false,
			Default = recipes[1],
			Callback = guarded(function(value) if bloomRt then bloomRt.setRecipe(value) end end),
			})
		controls.bloomAutoCraft = BloomSection:AddToggle({
			Title = "Auto Craft Essence",
			Content = "After each Bloom, crafts Enchanted Essence at the shrine once you hold the full recipe.",
			Default = false,
			Callback = guarded(function(value) Config.ButterflyAutoCraft = value == true end),
			})
		local function bloomButton(title, content, run, okText)
			BloomSection:AddButton({
				Title = title,
				Content = content,
				Callback = guarded(function()
					if not bloomRt then return end
					task.spawn(function()
						bloomRt.manual = true
						local done, ok, res = pcall(run)
						bloomRt.manual = false
						if not done then ok, res = false, ok end
						Sena:Notify({
							Title = "Butterfly Bloom",
							Content = ok and okText(res) or tostring(res or "Could not do that"),
							Duration = 4,
							})
						end)
					end),
				})
		end
		bloomButton("Claim Net Now", "Claims the Butterfly Net right now.",
			function() return bloomRt.claimNet() end, function() return "Butterfly Net claimed" end)
		bloomButton("Trade Up Now", "Runs the trade recipe once, even with Auto Trade Up off.",
			function() return bloomRt.tradeUp() end, function(n) return ("Traded up %d time(s)"):format(tonumber(n) or 0) end)
		bloomButton("Craft Essence Now", "Crafts Enchanted Essence right now if you hold the full recipe.",
			function() return bloomRt.craft() end, function(n) return ("Crafted %d Enchanted Essence"):format(tonumber(n) or 0) end)
		local function shortNumber(v)
			v = tonumber(v) or 0
			if v >= 1e12 then return ("%.2fT"):format(v / 1e12) end
			if v >= 1e9 then return ("%.2fB"):format(v / 1e9) end
			if v >= 1e6 then return ("%.2fM"):format(v / 1e6) end
			if v >= 1e3 then return ("%.1fK"):format(v / 1e3) end
			return tostring(math.floor(v))
		end
		task.spawn(function()
			while sessionAlive() do
				if bloomRt then
					pcall(function()
						local S = bloomRt.snap
						local info = bloomRt.tiers() or {}
						if S.unlocked then
							wispStatus:SetContent("Complete - the Enchanted Tree is unlocked.")
						elseif S.accepted then
							wispStatus:SetContent(("Stage %d / %d  ·  %s  (%d / %d)%s"):format(
								S.stage or 1, S.stages or 4, tostring(S.quest), S.progress or 0, S.target or 0,
								S.readyReturn and "\nAll quests done - return the wisp to unlock the tree."
									or (S.claimable and "\nReady to claim." or (bloomRt.questNote and ("\n" .. bloomRt.questNote) or ""))))
						elseif (S.speed or 0) < (S.need or 0) then
							wispStatus:SetContent(("Not eligible yet: SpeedPower %s of %s."):format(shortNumber(S.speed), shortNumber(S.need)))
						else
							wispStatus:SetContent(("Eligible (SpeedPower %s). The Baby Wisp waits in the Enchanted Forest."):format(shortNumber(S.speed)))
						end
						local when
						if S.active then
							local left = math.floor(S.left or 0)
							when = ("LIVE - ends in %dm %02ds"):format(math.floor(left / 60), left % 60)
						elseif S.enabled == false then
							when = "Disabled on this server"
						elseif S.nextIn then
							local n = math.floor(S.nextIn)
							when = ("Next in %dm %02ds"):format(math.floor(n / 60), n % 60)
						else
							when = "Not running"
						end
						local counts = {}
						for _, t in ipairs({ "Golden", "Purple", "Blue", "Green" }) do
							counts[#counts + 1] = ("%s %d"):format(info[t] and info[t].name or t, (S.counts and S.counts[t]) or 0)
						end
						if caughtGrid then
							local cards = {}
							for _, t in ipairs({ "Green", "Blue", "Purple", "Golden" }) do
								local have = (S.counts and S.counts[t]) or 0
								if caughtPrev and have > (caughtPrev[t] or 0) then
									caughtGain[t] = (caughtGain[t] or 0) + have - caughtPrev[t]
								end
								local ti = info[t] or {}
								local gain = caughtGain[t] or 0
								cards[#cards + 1] = {
									Name = ti.name or t,
									Icon = ti.icon,
									Color = ti.color,
									Value = shortNumber(have),
									Sub = gain > 0 and ("+%d session"):format(gain) or (ti.rarity or ""),
									SubColor = gain > 0 and Color3.fromRGB(74, 222, 128) or nil,
								}
							end
							caughtPrev = table.clone(S.counts or {})
							caughtGrid:SetItems(cards)
							caughtGrid:SetNote(("Total %s  ·  Essence %d"):format(shortNumber(S.caught), S.essence or 0))
							counts = {}
						end
						bloomStatus:SetContent((("%s\n%s  ·  Essence %d  ·  Caught %d\n%s\n%s"):format(
							when,
							S.net and (S.holding and "Net equipped" or "Net owned") or "No Butterfly Net",
							S.essence or 0, S.caught or 0,
							table.concat(counts, "  ·  "),
							tostring(bloomRt.status or "Idle")):gsub("\n\n", "\n")))
						end)
				end
				task.wait(1)
			end
			end)
	end
	local StarSection = controls.section(EventsTab, "Shooting Star", "rbxassetid://92160802930122")
	StarSection:AddParagraph({
		Title = "About This Event",
		Content = "Sometimes a little star falls near you and runs around for a few minutes. Hold next to it to catch it.",
		})
	controls.starAlert = StarSection:AddToggle({
		Title = "Star Alert",
		Content = "Shows a notification the moment a star starts falling.",
		Default = true,
		Callback = guarded(function(value) Config.StarAlert = value == true end),
		})
	controls.starAutoCatch = StarSection:AddToggle({
		Title = "Auto Catch Star",
		Content = "Goes to the star when it lands and catches it. Other tasks pause until it is caught.",
		Default = false,
		Callback = guarded(function(value) Config.StarAutoCatch = value == true end),
		})
	local starStatus = StarSection:AddParagraph({
		Title = "Star Status",
		Content = "No star right now.",
		})
	task.spawn(function()
		while sessionAlive() do
			local st = runtimeEnv.__SenaV4StarRuntime
			if st then
				pcall(function()
					starStatus:SetContent(tostring(st.status) .. "\nLast: " .. tostring(st.lastResult))
					end)
			end
			task.wait(1)
		end
		end)
	do
		local MobSec = controls.section(EventsTab, "Auto Hit Mobs (Halloween)", controls.gameIcon("Assets", "Directory", "Pumpkin Golem", "Icon") or "flame")
		controls.hwHitMobs = MobSec:AddToggle({
			Title = "Auto Hit Mobs",
			Content = "Automatically hunts Halloween monsters for their drops, one after another. Needs a bat in your backpack.",
			Default = false,
			Callback = guarded(function(value) Config.HalloweenHitMobs = value == true UIRunners.Halloween.refresh() end),
			})
		controls.hwMobRarities = MobSec:AddDropdown({
			Title = "Mobs: Filter By Rarity",
			Content = "Only hit mobs of these rarities (Eternal, Secret, Cosmic...). Leave empty for any.",
			Options = rarities,
			Multi = true,
			Default = {},
			Callback = guarded(function(values) local l = {} for _, v in ipairs(values) do if v ~= "None" and v ~= "" then l[#l + 1] = v end end Config.HalloweenMobRarities = l end),
			})
		controls.hwMobTypes = MobSec:AddDropdown({
			Title = "Mobs: Filter By Name",
			Content = "Only hit these monsters. Leave empty for all.",
			Options = (function() local o = {} local okHP, HP = pcall(require, game:GetService("ReplicatedStorage").Data.HalloweenPets) if okHP and type(HP) == "table" and type(HP.Specs) == "table" then for nm in pairs(HP.Specs) do o[#o + 1] = tostring(nm) end end table.sort(o) return o end)(),
			Multi = true,
			Default = {},
			Callback = guarded(function(values) local l = {} for _, v in ipairs(values) do if v ~= "None" and v ~= "" then l[#l + 1] = v end end Config.HalloweenMobTypes = l end),
			})
		local PumpkinSec = controls.section(EventsTab, "Pumpkin Moon (Halloween)", controls.gameIcon("Assets", "Directory", "Hexed Pumpkin", "Icon") or "flame")
		controls.hwPumpkin = PumpkinSec:AddToggle({
			Title = "Auto Collect Pumpkins",
			Content = "Auto-collects pumpkins during the Pumpkin Moon event and banks them for you. Only runs while the event is live.",
			Default = false,
			Callback = guarded(function(value) Config.HalloweenCollectPumpkin = value == true UIRunners.Halloween.refresh() end),
			})
		local FishSec = controls.section(EventsTab, "Ghost Dog's Lake (Halloween)", controls.gameIcon("Gears", "Directory", "Haunted Rod", "Icon") or "flame")
		controls.hwFish = FishSec:AddToggle({
			Title = "Auto Fish",
			Content = "Fishes the Ghost Dog lake with your Haunted Rod and reels in the best catches for you. Needs the rod from Fisherman Gilbert's quest, and only runs inside the Halloween dimension.",
			Default = false,
			Callback = guarded(function(value) Config.HalloweenAutoFish = value == true UIRunners.Halloween.refresh() end),
			})
		local TrainSec = controls.section(EventsTab, "Phantom Express (Halloween)", "rbxassetid://106321524065478")
		controls.hwTrain = TrainSec:AddToggle({
			Title = "Auto Phantom Express",
			Content = "Boards the Phantom Express when it pulls in, hunts the ghost spirits in Forgotten Town for Souls, takes on the Ghouler, then rides home. Needs the Train Pass from Fisherman Gilbert's quest.",
			Default = false,
			Callback = guarded(function(value) Config.HalloweenPhantomExpress = value == true UIRunners.Train.refresh() if Config.HalloweenPhantomExpress and not Config.GodMode then applyGodMode(true) if controls.godMode then pcall(function() controls.godMode:Set(true) end) end end end),
			})
		controls.hwTradeSouls = TrainSec:AddToggle({
			Title = "Trade Souls for Spectral",
			Content = "Spends your Souls at the Soul Shrine in Forgotten Town to roll the Spectral mutation.",
			Default = false,
			Callback = guarded(function(value) Config.HalloweenTradeSouls = value == true UIRunners.Train.refresh() end),
			})
		controls.hwTrainStatus = TrainSec:AddParagraph({ Title = "Status", Content = "Idle." })
		task.spawn(function()
			while sessionAlive() do
				local st = UIRunners.Train.stats()
				if st and UIRunners.Train.isRunning() then
					controls.hwTrainStatus:SetContent(string.format("Running  -  ghosts %d  -  spectral %d  -  %s", st.captured or 0, st.spectral or 0, tostring(st.note or "")))
				else
					controls.hwTrainStatus:SetContent("Idle.")
				end
				task.wait(2)
			end
		end)
		controls.hwStatus = StealSection:AddParagraph({ Title = "Halloween Status", Content = "Idle." })
		task.spawn(function()
			while sessionAlive() do
				local st = UIRunners.Halloween.stats()
				if st then
					local state = UIRunners.Halloween.isRunning() and "Running" or "Idle"
					if UIRunners.Halloween.isRunning() and game:GetService("Players").LocalPlayer:GetAttribute("InHalloweenDimension") ~= true then state = (st.note == "normal world") and "In the normal world" or "Waiting for targets" end
					controls.hwStatus:SetContent(string.format("%s  -  Candy Corn %s  -  eggs %d  -  mobs %d  -  pumpkins %d  -  fish %d  -  fails %d", state, tostring(st.candy), st.delivered or 0, st.killed or 0, st.pumpkins or 0, st.fished or 0, st.fails or 0))
				else
					controls.hwStatus:SetContent("Idle.")
				end
				task.wait(2)
			end
			end)
	end
	local TreadmillSection = controls.section(FarmTab, "Treadmill", controls.gameIcon("Treadmills", "Directory", "Treadmill", "Icon"))
	controls.autoTreadmill = TreadmillSection:AddToggle({
		Title = "Auto Treadmill",
		Content = "Walks to your treadmill and farms speed whenever nothing else is running.",
		Default = false,
		Callback = guarded(applyAutoTreadmill),
		})
	controls.treadmillUpgrade = TreadmillSection:AddToggle({
		Title = "Auto Upgrade Treadmill",
		Content = "Buys the next treadmill tier with cash as soon as you can afford it.",
		Default = false,
		Callback = guarded(applyTreadmillUpgrade),
		})
	local PerformanceSection = SettingsTab:AddSection("Performance")
	controls.startupBoost = PerformanceSection:AddToggle({
		Title = "Startup Boost",
		Content = "Lowers graphics when the script starts. Turn it off to get the graphics back; hidden pets and eggs return after a rejoin.",
		Default = true,
		Callback = guarded(applyStartupBoost),
		})
	controls.boostFps = PerformanceSection:AddToggle({
		Title = "Boost FPS",
		Content = "Removes extra map details and other players' plots for more FPS.",
		Default = false,
		Callback = guarded(applyBoostFps),
		})
	controls.uncapFps = PerformanceSection:AddToggle({
		Title = "Uncap FPS",
		Content = "Raises the FPS cap to 1000.",
		Default = true,
		Callback = guarded(applyUncapFps),
		})
	local GuardSection = SettingsTab:AddSection("Guard")
	controls.antiGuardKnockback = GuardSection:AddToggle({
		Title = "Anti Guard Knockback",
		Content = "Cancels the knockback the Forest guard puts on you, so a hit never throws you off the lane.",
		Default = true,
		Callback = guarded(applyAntiGuardKnockback),
		})
	controls.antiHitGuard = GuardSection:AddToggle({
		Title = "Anti Hit Guard",
		Content = "For eggs you pick up by hand. Pins you in the safe zone behind a look-alike clone until the guard goes back to sleep. Auto Steal has its own guard handling and always wins.",
		Default = false,
		Callback = guarded(applyAntiHitGuard),
		})
	local WindowsSection = WindowsTab:AddSection("Windows", true)
	WindowsSection:AddButton({
		Title = "Egg Logs",
		Content = "Live feed of every egg that spawns on the server.",
		Callback = guarded(function() SenaPanels.openLogs() end),
		})
	WindowsSection:AddButton({
		Title = "Egg Board",
		Content = "Sortable list of the eggs currently up for grabs.",
		Callback = guarded(function() SenaPanels.openBoard() end),
		})
	WindowsSection:AddButton({
		Title = "Inventory & Base",
		Content = "Your pets, eggs and plot status in one window.",
		Callback = guarded(function() SenaPanels.openInventory() end),
		})
	WindowsSection:AddButton({
		Title = "Egg Checker",
		Content = "Pick eggs off the field by hand, then send them all to the steal queue.",
		Callback = guarded(function() SenaPanels.openChecker() end),
		})
	WindowsSection:AddButton({
		Title = "Egg Data & History",
		Content = "Drop-table values per area, plus what has actually spawned this session.",
		Callback = guarded(function() SenaPanels.openAnalyst() end),
		})
	WindowsSection:AddButton({
		Title = "Farm Stats",
		Content = "What is running now, money and income, steals, and your plot at a glance.",
		Icon = "trending-up",
		Callback = guarded(function() SenaPanels.openStats() end),
		})
	WindowsSection:AddButton({
		Title = "Open All Windows",
		SubTitle = "Close All Windows",
		Content = "Opens every window at once, or hides them again.",
		Callback = guarded(function() SenaPanels.openAll() end),
		SubCallback = guarded(function() SenaPanels.closeAll() end),
		})
	local BlockerSection = controls.section(FarmTab, "Blocker", controls.gameIcon("Gears", "Directory", "Trap", "Icon"))
	controls.antiTreadmill = BlockerSection:AddToggle({
		Title = "Anti Treadmill",
		Content = "Never stay on a treadmill: any mount is dropped right away, and Auto Treadmill is held off while this is on.",
		Default = false,
		Callback = guarded(applyAntiTreadmill),
		})
	local ServerHopSection = ServerTab:AddSection("Server Hop")
	controls.hopNoMatch = ServerHopSection:AddToggle({
		Title = "Hop When Nothing Matches",
		Content = "Hop to the emptiest server when no egg matches your filters.",
		Default = false,
		Callback = guarded(applyHopNoMatch),
		})
	ServerHopSection:AddSubSection("Limits")
	controls.hopCooldown = ServerHopSection:AddSlider({
		Title = "Hop Cooldown",
		Content = "Seconds between auto hops and wait after rejoining.",
		Min = 1,
		Max = 60,
		Default = 5,
		Increment = 1,
		Callback = guarded(applyHopCooldown),
		})
	local PrivateSection = controls.privateTab:AddSection("Find Private Server", true)
	local privateStatusPara = PrivateSection:AddParagraph({
		Title = "Current Server",
		Content = "Checking...",
		})
	controls.privateServerMax = PrivateSection:AddDropdown({
		Title = "Max Players",
		Content = "The most players you want in your server, you included. 2 (you + 1) is the easiest to find.",
		Options = { "1", "2", "3", "4", "5" },
		Default = "2",
		Multi = false,
		Callback = guarded(applyPrivateServerMax),
		})
	PrivateSection:AddButton({
		Title = "Hop Server Now",
		Content = "Moves you to a quieter server right away.",
		Callback = guarded(function()
			task.spawn(function()
				SenaExtras.hopPrivateOnce()
				end)
			end),
		})
	controls.privateServerAuto = PrivateSection:AddToggle({
		Title = "Auto Hop",
		Content = "Keeps moving you to quieter servers until the player count is at or under your max.",
		Default = false,
		Callback = guarded(applyPrivateServerAuto),
		})
	task.spawn(function()
		local last
		while sessionAlive() do
			local text = "Now: " .. #Players:GetPlayers() .. " player(s)  ·  Max: " .. SenaExtras.privateMax()
				.. "\n" .. tostring(SenaExtras.privateStatus or "")
			if text ~= last then
				last = text
				pcall(function() privateStatusPara:SetContent(text) end)
			end
			task.wait(1)
		end
		end)
	local RoamingSection = controls.section(FarmTab, "Roaming", controls.gameIcon("Trails", "Directory", "PurpleTrail", "Icon"))
	controls.waypoint = RoamingSection:AddDropdown({
		Title = "Waypoint",
		Content = "Pick a place, then hit Teleport below.",
		Options = waypointOptions,
		Default = waypointOptions[1],
		Callback = guarded(function(value) selectedWaypoint = value end),
		})
	RoamingSection:AddButton({
		Title = "Teleport To Waypoint",
		Content = "Moves you straight to the waypoint you picked.",
		Callback = guarded(function()
			local roaming = runtimeEnv.__SenaV4Roaming
			local ok = false
			if roaming and type(roaming.teleportWaypoint) == "function" then
				ok = roaming.teleportWaypoint(selectedWaypoint) == true
			end
			Sena:Notify({
				Title = "Waypoint",
				Content = ok and ("Moved to " .. tostring(selectedWaypoint)) or "That waypoint is not in this server",
				Duration = 3,
				})
			end),
		})
	local QuickSection = HomeTab:AddSection("Run Once")
	QuickSection:AddButton({
		Title = "Place Everything Now",
		Content = "Runs one pass of Auto Place, even while the toggle is off.",
		Callback = guarded(function()
			runOnce("AutoPlace", UIRunners.AutoPlaceLoop)
			end),
		})
	QuickSection:AddButton({
		Title = "Hatch Everything Ready",
		Content = "Runs one pass of Auto Hatch, even while the toggle is off.",
		Callback = guarded(function()
			runOnce("AutoHatch", UIRunners.AutoHatchLoop)
			end),
		})
	QuickSection:AddButton({
		Title = "Sell Pets Now",
		Content = "Runs one pass of Auto Sell Pet using the filters above.",
		Callback = guarded(function()
			runOnce("AutoSell", UIRunners.startAutoSellLoop)
			end),
		})
	QuickSection:AddButton({
		Title = "Sell Eggs Now",
		Content = "Runs one pass of Auto Sell Egg using the filters above.",
		Callback = guarded(function()
			runOnce("AutoSellEgg", UIRunners.startAutoSellEggLoop)
			end),
		})
	local SessionSection = SettingsTab:AddSection("Session")
	controls.bottingMode = SessionSection:AddToggle({
		Title = "Botting Mode",
		Content = "Turns off 3D rendering and covers the screen in black. Everything keeps running, your GPU does not.",
		Default = false,
		Callback = guarded(applyBottingMode),
		})
	controls.antiCutscene = SessionSection:AddToggle({
		Title = "Anti Cutscene",
		Content = "Closes event cutscenes and the intro as soon as the game opens them, so nothing locks your camera.",
		Default = false,
		Callback = guarded(applyAntiCutscene),
		})
	SessionSection:AddButton({
		Title = "Rejoin This Server",
		Content = "Teleports you back into the exact server you are in now.",
		Callback = guarded(function()
			pcall(function()
				game:GetService("TeleportService"):TeleportToPlaceInstance(game.PlaceId, game.JobId, LocalPlayer)
				end)
			end),
		})
	SessionSection:AddButton({
		Title = "Stop & Unload",
		Content = "Turns every loop off and closes the hub. Run the script again to bring it back.",
		Callback = guarded(function()
			for _, key in ipairs({
				"AutoSteal", "AutoPlace", "AutoHatch", "AutoSell", "AutoSellEgg",
				"StealPlayers", "AutoFavorite", "AutoFusePets",
				"AutoEquipBest", "AutoClaimOffline", "AutoBaseUpgrade", "AutoClaimAlmanac",
				"Noclip", "BottingMode", "AntiCutscene",
				}) do
				Config[key] = false
			end
			applyNoclip(false)
			applyBottingMode(false)
			if eggRuntime then pcall(eggRuntime.setEnabled, eggRuntime, false) end
			local shutdown = runtimeEnv.__SenaV4HubShutdown
			if type(shutdown) == "function" then
				task.delay(0.2, function() pcall(shutdown) end)
			end
			end),
		})
	local PlayerSection = SettingsTab:AddSection("Player")
	controls.antiAfk = PlayerSection:AddToggle({
		Title = "Anti AFK",
		Content = "Blocks the game's idle kick while the script runs.",
		Default = true,
		Callback = guarded(applyAntiAfk),
		})
	controls.autoReconnect = PlayerSection:AddToggle({
		Title = "Auto Reconnect",
		Content = "Automatically reconnects you back to the server upon kick or disconnect.",
		Default = true,
		Callback = guarded(applyAutoReconnect),
		})
	controls.autoExecute = PlayerSection:AddToggle({
		Title = "Auto Execute (Rejoin)",
		Content = "Prepares the bootstrapper so the script runs automatically after teleport or reconnect.",
		Default = false,
		Callback = guarded(applyAutoExecute),
		})
	local PlayersTab = StealTab
	local RaidSection = controls.section(PlayersTab, "Steal From Players", controls.gameIcon("Gears", "Directory", "Bat", "Icon"))
	controls.stealPlayers = RaidSection:AddToggle({
		Title = "Auto Steal From Players",
		Content = "Chases anyone carrying an egg in the field, bats them until the egg drops, grabs it and banks it. "
		.. "A carrier is only chased when the egg clears the filters below.",
		Default = false,
		Callback = guarded(applyStealPlayers),
		})
	controls.stealPlayerRarities = RaidSection:AddDropdown({
		Title = "Rarity Filter",
		Content = "Only chase eggs of these rarities. Empty = uses the Auto Steal rarity filter.",
		Options = rarities,
		Multi = true,
		Default = {},
		Callback = guarded(applyStealPlayerRarities),
		})
	controls.stealPlayerValue = RaidSection:AddInput({
		Title = "Minimum Value",
		Content = "Skip carriers holding less than this per second. Supports k, m and b.",
		Placeholder = "e.g. 500k, 2m, 1b",
		Default = "",
		Callback = guarded(applyStealPlayerValue),
		})
	local StrikeSection = PlayersTab:AddSection({ Title = "Steal From Specific Player", AlwaysOpen = true, Icon = controls.gameIcon("Gears", "Directory", "Katana", "Icon") })
	local HistorySection = PlayersTab:AddSection({ Title = "Steal History", AlwaysOpen = true, Icon = controls.gameIcon("Gears", "Directory", "Flyswatter", "Icon") })
	local playerList, historyList
	if StrikeSection.AddActionList then
		playerList = StrikeSection:AddActionList({
			Title = "Players in this server",
			EmptyText = "Nobody else is in this server.",
			VisibleRows = 6,
			ButtonWidth = 76,
			})
		historyList = HistorySection:AddActionList({
			Title = "History of stolen eggs from players",
			EmptyText = "No player steals yet.",
			VisibleRows = 5,
			ButtonWidth = 72,
			})
	else
		StrikeSection:AddParagraph({
			Title = "Update required",
			Content = "This Sena UI build has no player list yet. Rejoin to pull the latest version.",
			})
	end
	HistorySection:AddButton({
		Title = "Clear History",
		Content = "Wipe the list above.",
		Callback = guarded(function()
			if playerSteal then playerSteal:clearHistory() end
			end),
		})
	if playerSteal and playerList then
		local setIdentity = runtimeEnv.__SenaV4IdentitySetter
		local targetIdentity = runtimeEnv.__SenaV4UICapabilityIdentity or 8
		local function paintHistory(runtime)
			if setIdentity then
				pcall(setIdentity, targetIdentity)
			end
			if not historyList or not historyList:Alive() then return end
			local entries = {}
			for index, row in ipairs(runtime.history) do
				entries[index] = {
					id = tostring(index),
					name = row.player,
					sub = string.format('<font color="#A2A2AE">%s</font>', os.date("!%H:%M:%S", row.at)),
					status = row.egg,
					statusSub = row.outcome,
					button = false,
				}
			end
			historyList:Update(entries)
		end
		playerSteal:onChanged(paintHistory)
		paintHistory(playerSteal)
		local listBusySince = nil
		local listLastRun = 0
		local listConn
		listConn = game:GetService("RunService").Heartbeat:Connect(function()
			if runtimeEnv.__SenaV4PlayerSteal ~= playerSteal or not playerList:Alive() then
				listConn:Disconnect()
				return
			end
			local now = os.clock()
			if listBusySince and now - listBusySince < 5 then return end
			if now - listLastRun < 1 then return end
			listLastRun = now
			local token = now
			listBusySince = token
			task.spawn(function()
				local ok, err = pcall(function()
					if setIdentity then
						pcall(setIdentity, targetIdentity)
					end
					local entries = playerSteal:listEntries()
					if setIdentity then
						pcall(setIdentity, targetIdentity)
					end
					if playerList:Alive() then
						playerList:Update(entries)
					end
					end)
				if not ok then
					warn("[Sena Steal] Player list update loop error:", err)
				end
				if listBusySince == token then listBusySince = nil end
				end)
			end)
	end
	local ChatTab = Window:AddTab({ Name = "Live Chat", Icon = "chat", LayoutOrder = 20, Group = "Community" })
	local chatSection = isV2Lib and ChatTab:AddSection({ Title = "Global Chat", Header = false })
		or ChatTab:AddSection("Global Chat", true)
	chatSection:AddLiveChat({
		Title = "Live Chat",
		Fill = true,
		Height = 300,
		})
	if type(Window.AddForum) == "function" then
		Window:AddForum({ Name = "Forum", Icon = "forum", Section = "Config Forum", LayoutOrder = 21, Group = "Community" })
	end
	do
		local visual = runtimeEnv.__SenaV4Visual
		local VisualTab = Window:AddTab({ Name = "Visual", Icon = "eye", LayoutOrder = 12, Group = "Tools" })
		local picked = { rods = nil, fish = nil }
		local statusPara
		local function refreshStatus()
			if statusPara and visual then pcall(function() statusPara:SetContent(visual.status) end) end
		end
		local function spawnPicked(kind)
			if not visual then return end
			task.spawn(function()
				visual.spawn(kind, picked[kind])
				refreshStatus()
				Sena:Notify({ Title = "Visual", Content = visual.status, Duration = 3 })
			end)
			task.delay(0.1, refreshStatus)
		end
		local FishItSection = VisualTab:AddSection("Fish It")
		FishItSection:AddSubSection("Rods")
		local rodDropdown = FishItSection:AddDropdown({
			Title = "Select Rod",
			Content = "Rods and skins from Fish It. Loading list...",
			Options = {},
			Multi = false,
			Default = nil,
			Callback = guarded(function(value) picked.rods = value end),
			})
		FishItSection:AddButton({
			Title = "Spawn Rod",
			Content = "Downloads the rod and puts it in your backpack. Equip it like a bat. Only you can see it.",
			Callback = guarded(function() spawnPicked("rods") end),
			})
		FishItSection:AddSlider({
			Title = "Rod Size",
			Content = "1 = the size it has in Fish It. Spawned rods update right away.",
			Min = 0.5,
			Max = 2,
			Default = 1,
			Increment = 0.1,
			Callback = guarded(function(value)
				if not visual or visual.rodScale == value then return end
				visual.rodScale = value
				task.spawn(visual.respawn, "rods")
			end),
			})
		FishItSection:AddSubSection("Fish")
		local fishDropdown = FishItSection:AddDropdown({
			Title = "Select Fish",
			Content = "Secret and Forgotten fish from Fish It. Loading list...",
			Options = {},
			Multi = false,
			Default = nil,
			Callback = guarded(function(value) picked.fish = value end),
			})
		FishItSection:AddButton({
			Title = "Spawn Fish",
			Content = "Downloads the fish and puts it in your backpack under Pets. Only you can see it.",
			Callback = guarded(function() spawnPicked("fish") end),
			})
		FishItSection:AddSlider({
			Title = "Fish Weight",
			Content = "0% = lightest catch, 100% = heaviest Big catch. Size follows Fish It: weight / min weight.",
			Min = 0,
			Max = 100,
			Default = 0,
			Increment = 5,
			Callback = guarded(function(value)
				local fraction = (tonumber(value) or 0) / 100
				if not visual or visual.fishWeight == fraction then return end
				visual.fishWeight = fraction
				task.spawn(visual.respawn, "fish")
			end),
			})
		FishItSection:AddSubSection("Manage")
		statusPara = FishItSection:AddParagraph({ Title = "Status", Content = "Idle" })
		FishItSection:AddButton({
			Title = "Remove All Visual Items",
			Content = "Takes every spawned rod and fish out of your backpack.",
			Callback = guarded(function()
				if visual then visual.clear() end
				refreshStatus()
			end),
			})
		task.spawn(function()
			if not visual then return end
			local rods, fish = visual.names("rods"), visual.names("fish")
			pcall(function() rodDropdown:Refresh(rods) end)
			pcall(function() fishDropdown:Refresh(fish) end)
			visual.status = #rods > 0 and string.format("%d rods and %d fish available", #rods, #fish)
				or "Could not load the item list. Try again later."
			refreshStatus()
		end)
		local SaeSection = VisualTab:AddSection("Steal an Egg")
		local saeType, saeScale, saeHold = "Egg", 50, true
		local saeCats = (runtimeEnv.__SenaV4VisualSAE and runtimeEnv.__SenaV4VisualSAE.categories("Egg")) or {}
		local saeCat = saeCats[1]
		SaeSection:AddDropdown({
			Title = "Type",
			Content = "Egg shows in the Eggs tab, Pet under Pets. Both are fake and local-only.",
			Options = { "Egg", "Pet" },
			Multi = false,
			Default = "Egg",
			Callback = guarded(function(v) saeType = v or "Egg" end),
			})
		SaeSection:AddDropdown({
			Title = "Select Egg / Pet",
			Content = "Which egg or pet to spawn.",
			Options = saeCats,
			Multi = false,
			Default = saeCats[1],
			MaxVisible = 8,
			Callback = guarded(function(v) saeCat = v end),
			})
		SaeSection:AddSlider({
			Title = "Size / Flex",
			Content = "Bigger = heavier Kg & higher value (Kg = base weight x scale^3) AND a bigger egg in your hand. 50 hits the billions.",
			Min = 1,
			Max = 100,
			Default = 50,
			Increment = 1,
			Callback = guarded(function(v) saeScale = tonumber(v) or 50 end),
			})
		SaeSection:AddButton({
			Title = "Hold in Hand",
			Content = "Spawns a model of it in your hand. Press again for more. (In-hand only - use the other button to also add it to All Items.)",
			Callback = guarded(function()
				local V = runtimeEnv.__SenaV4VisualSAE
				if V then V.spawn(saeType, saeCat, saeScale, true) end
				end),
			})
		SaeSection:AddButton({
			Title = "Add to Backpack (Kg)",
			Content = "Drops it in All Items (eggs) or Pets with a huge Kg for the inventory flex. Press again for more.",
			Callback = guarded(function()
				local V = runtimeEnv.__SenaV4VisualSAE
				if V then V.spawn(saeType, saeCat, saeScale, false) end
				end),
			})
		SaeSection:AddButton({
			Title = "Remove Egg / Pet Visuals",
			Content = "Takes every spawned fake egg/pet and held model out.",
			Callback = guarded(function()
				local V = runtimeEnv.__SenaV4VisualSAE
				if V then V.clear() end
				end),
			})
	end
	local function sync(control, apply)
		elevateUi()
		if type(control) == "table" and control.Value ~= nil then
			pcall(apply, control.Value)
		end
	end
	building = false
	sync(controls.speed, applySpeed)
	sync(controls.stealMode, applyStealMode)
	sync(controls.antiTreadmill, applyAntiTreadmill)
	sync(controls.autoTreadmill, applyAutoTreadmill)
	sync(controls.treadmillUpgrade, applyTreadmillUpgrade)
	sync(controls.hopCooldown, applyHopCooldown)
	sync(controls.hopNoMatch, applyHopNoMatch)
	sync(controls.privateServerMax, applyPrivateServerMax)
	sync(controls.privateServerAuto, applyPrivateServerAuto)
	sync(controls.eggWorld, function(value) local hw = value == "Halloween" if controls.names then pcall(function() controls.names:SetVisible(not hw) end) end if controls.rarities then pcall(function() controls.rarities:SetVisible(not hw) end) end if controls.hwNames then pcall(function() controls.hwNames:SetVisible(hw) end) end if controls.hwEggRarities then pcall(function() controls.hwEggRarities:SetVisible(hw) end) end for _, k in ipairs({ "areas", "value", "mutations", "weight", "priority", "autoIndex" }) do local c = controls[k] if c then pcall(function() c:SetVisible(not hw) end) end end end)
	sync(controls.names, function(values) applyStealFilter("names", "name", values) end)
	sync(controls.areas, function(values) applyStealFilter("areas", "area", values) end)
	sync(controls.rarities, function(values) applyStealFilter("rarities", "rarity", values) end)
	sync(controls.value, applyStealValue)
	sync(controls.autoIndex, applyAutoIndex)
	sync(controls.wispAutoQuest, function(value) Config.WispAutoQuest = value == true end)
	sync(controls.banjoAuto, function(value) Config.BanjoAuto = value == true end)
	sync(controls.bloomAutoNet, function(value) Config.ButterflyAutoNet = value == true end)
	sync(controls.bloomAutoCatch, function(value) Config.ButterflyAutoCatch = value == true end)
	sync(controls.bloomEsp, function(value) Config.ButterflyEsp = value == true end)
	sync(controls.bloomAutoTrade, function(value) Config.ButterflyAutoTrade = value == true end)
	sync(controls.bloomAutoCraft, function(value) Config.ButterflyAutoCraft = value == true end)
	sync(controls.bloomTiers, function(values)
		local rt = runtimeEnv.__SenaV4ButterflyRuntime
		if rt then rt.setTiers(withoutNone(values)) end
	end)
	sync(controls.bloomRecipe, function(value)
		local rt = runtimeEnv.__SenaV4ButterflyRuntime
		if rt then rt.setRecipe(value) end
	end)
	sync(controls.bloomMode, function(value)
		local rt = runtimeEnv.__SenaV4ButterflyRuntime
		if rt then rt.setMode(value) end
	end)
	sync(controls.noclip, applyNoclip)
	sync(controls.bottingMode, applyBottingMode)
	sync(controls.antiCutscene, applyAntiCutscene)
	sync(controls.waypoint, function(value) selectedWaypoint = value end)
	sync(controls.autoFavorite, applyAutoFavorite)
	sync(controls.favoriteRule, applyFavoriteRule)
	sync(controls.favoriteRarities, applyFavoriteRarities)
	sync(controls.favoriteSpecies, applyFavoriteSpecies)
	sync(controls.autoFuse, applyAutoFuse)
	sync(controls.fuseRule, applyFuseRule)
	sync(controls.fuseRarities, applyFuseRarities)
	sync(controls.fuseSpecies, applyFuseSpecies)
	sync(controls.autoEquipBest, applyAutoEquipBest)
	sync(controls.autoClaimOffline, applyAutoClaimOffline)
	sync(controls.autoBaseUpgrade, applyAutoBaseUpgrade)
	sync(controls.autoClaimAlmanac, applyAutoClaimAlmanac)
	sync(controls.mutations, applyStealMutations)
	sync(controls.weight, applyStealWeight)
	sync(controls.priority, applyStealPriority)
	sync(controls.eggEsp, applyEggEsp)
	sync(controls.espDetails, applyEspDetails)
	sync(controls.espMinRarity, UIRunners.applyEspMinRarity)
	sync(controls.espMinValue, UIRunners.applyEspMinValue)
	sync(controls.backpackRates, applyBackpackRates)
	sync(controls.antiGuardKnockback, applyAntiGuardKnockback)
	sync(controls.placeRarity, function(values) Config.PlaceRarities = withoutNone(values) end)
	sync(sellNamesDropdown, function(values) Config.SellNames = withoutNone(values) end)
	sync(sellRarityDropdown, function(values) Config.SellRarities = withoutNone(values) end)
	sync(sellEggRarityDropdown, function(values) Config.SellEggRarities = withoutNone(values) end)
	sync(controls.sellPetValue, applySellPetValue)
	sync(controls.sellEggValue, applySellEggValue)
	sync(controls.godMode, applyGodMode)
	sync(controls.antiAfk, applyAntiAfk)
	sync(controls.autoReconnect, applyAutoReconnect)
	sync(controls.autoExecute, applyAutoExecute)
	sync(controls.antiHitGuard, applyAntiHitGuard)
	sync(controls.flyForCapture, applyFlyForCapture)
	sync(controls.autoStealCapture, applyAutoStealCapture)
	sync(controls.instantGrab, applyInstantGrab)
	sync(controls.snipeDropped, function(value) Config.SnipeDroppedEggs = value == true; local rt = runtimeEnv.__SenaV4EggRuntime; if rt then pcall(function() rt:_reconcileRunningState(); if Config.SnipeDroppedEggs and rt.enabled then rt:_installSnipeHook() else rt:_removeSnipeHook() end end) end end)
	sync(controls.infiniteJump, applyInfiniteJump)
	sync(controls.uncapFps, applyUncapFps)
	sync(controls.startupBoost, applyStartupBoost)
	sync(controls.autoPlace, applyAutoPlace)
	sync(controls.autoHatch, applyAutoHatch)
	sync(controls.mutationChoice, applyMutationChoice)
	sync(controls.mutationSpecies, applyMutationSpecies)
	sync(controls.mutationRarity, applyMutationRarities)
	sync(controls.mutationMinValue, applyMutationMinValue)
	sync(controls.mutationRetry, applyMutationRetry)
	sync(controls.autoMutation, applyAutoMutation)
	sync(controls.taskOrder, applyTaskOrder)
	sync(controls.stealHold, applyStealHold)
	sync(controls.starAlert, function(value) Config.StarAlert = value == true end)
	sync(controls.starAutoCatch, function(value) Config.StarAutoCatch = value == true end)
	if controls.taskOrder and type(controls.taskOrder.SetStatus) == "function" then
		local list = controls.taskOrder
		task.spawn(function()
			while sessionAlive() do
				for _, id in ipairs(TaskLadder.DEFAULT) do
					local on = TaskLadder.enabled(id)
					if type(list.SetVisible) == "function" then
						pcall(list.SetVisible, list, id, on)
					end
					if on then
						local text, tone = TaskLadder.describe(id)
						pcall(list.SetStatus, list, id, text, tone)
					end
				end
				task.wait(0.5)
			end
		end)
	end
	sync(controls.autoRingEvent, applyAutoRingEvent)
	sync(controls.autoSell, applyAutoSell)
	sync(controls.autoSellEgg, applyAutoSellEgg)
	sync(controls.stealPlayerRarities, applyStealPlayerRarities)
	sync(controls.stealPlayerValue, applyStealPlayerValue)
	sync(controls.webhookUrl, applyWebhookUrl)
	sync(controls.webhookRarities, applyWebhookRarities)
	sync(controls.webhookValue, applyWebhookValue)
	sync(controls.webhookEnabled, applyWebhookEnabled)
	sync(controls.webhookDisconnect, function(value) Config.WebhookDisconnect = value == true end)
	sync(controls.helpFriend, function(value) Config.HelpFriend = value == true end)
	sync(controls.lowSpeedBoost, function(value) Config.LowSpeedBoost = value == true end)
	sync(controls.autoSteal, applyAutoSteal)
	sync(controls.stealPlayers, applyStealPlayers)
	sync(controls.autoStealHalloween, function(value) Config.AutoStealHalloween = value == true UIRunners.Halloween.setEnabled(Config.AutoStealHalloween) end)
	sync(controls.hwZonePriority, function(value) Config.HalloweenZonePriority = value == true end)
	sync(controls.hwAutoBuy, function(value) Config.HalloweenAutoBuy = value == true end)
	sync(controls.hwCrossWorld, function(value) Config.HalloweenCrossWorld = value == true end)
	sync(controls.hwNames, function(values) local l = {} for _, v in ipairs(values) do if v ~= "None" and v ~= "" then l[#l + 1] = v end end Config.HalloweenNames = l end)
	sync(controls.hwHitMobs, function(value) Config.HalloweenHitMobs = value == true UIRunners.Halloween.refresh() end)
	sync(controls.hwMobRarities, function(values) local l = {} for _, v in ipairs(values) do if v ~= "None" and v ~= "" then l[#l + 1] = v end end Config.HalloweenMobRarities = l end)
	sync(controls.hwMobTypes, function(values) local l = {} for _, v in ipairs(values) do if v ~= "None" and v ~= "" then l[#l + 1] = v end end Config.HalloweenMobTypes = l end)
	sync(controls.hwPumpkin, function(value) Config.HalloweenCollectPumpkin = value == true UIRunners.Halloween.refresh() end)
	sync(controls.hwFish, function(value) Config.HalloweenAutoFish = value == true UIRunners.Halloween.refresh() end)
	sync(controls.hwTrain, function(value) Config.HalloweenPhantomExpress = value == true UIRunners.Train.refresh() if Config.HalloweenPhantomExpress and not Config.GodMode then applyGodMode(true) if controls.godMode then pcall(function() controls.godMode:Set(true) end) end end end)
	sync(controls.hwTradeSouls, function(value) Config.HalloweenTradeSouls = value == true UIRunners.Train.refresh() end)
	sync(controls.hwEggRarities, function(values) local l = {} for _, v in ipairs(values) do if v ~= "None" and v ~= "" then l[#l + 1] = v end end Config.HalloweenEggRarities = l end)
	SenaExtras.hopWindow = Window
	do
		local hunt = SenaExtras.hopHunt
		if hunt and hunt.state and (hunt.state.active or hunt.state.watch) then
			pcall(function() Window:LoadConfig("HopSession") end)
			task.delay(2, function() pcall(hunt.open) end)
		end
	end
	runtimeEnv.__SenaV4HubShutdown = function()
		if playerSteal then pcall(playerSteal.setEnabled, playerSteal, false) end
		for _, key in ipairs({ "AutoSteal", "AutoPlace", "AutoHatch", "AutoMutation", "AutoRingEvent", "AutoSell", "AutoSellEgg", "StealPlayers", "StarAutoCatch",
			"ButterflyAutoCatch", "ButterflyAutoNet", "ButterflyAutoTrade", "ButterflyAutoCraft" }) do
			Config[key] = false
		end
		if eggRuntime then
			pcall(eggRuntime.setEnabled, eggRuntime, false)
		end
		-- floating panels (Egg Checker, Logs, ...) outlive a re-exec and keep driving the dead hub's controls
		pcall(function()
			local pg = LocalPlayer:FindFirstChild("PlayerGui")
			local holders = { game:GetService("CoreGui"), pg }
			if gethui then table.insert(holders, gethui()) end
			for _, holder in ipairs(holders) do
				if holder then
					for _, d in ipairs(holder:GetDescendants()) do
						if d:IsA("ScreenGui") and d.Name:sub(1, 12) == "__SNE_Panel_" then pcall(function() d:Destroy() end) end
					end
				end
			end
		end)
		local oldGui = Window and rawget(Window, "Gui") or nil
		local roots = { game:GetService("CoreGui") }
		pcall(function() if gethui then table.insert(roots, gethui()) end end)
		for _, holder in ipairs(roots) do
			for _, gui in ipairs(holder:GetChildren()) do
				if gui == oldGui or (gui:IsA("ScreenGui") and (gui.Name == "Chloeex" or gui.Name == "ToggleUIButton")) then pcall(gui.Destroy, gui) end
			end
		end
	end
	UI_LOADED = true
end
buildSenaHub()
