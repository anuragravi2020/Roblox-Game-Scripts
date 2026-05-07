--[[
================================================================================
  CosmeticsServer  (ServerScriptService)
  
  RESUME BULLET: "Implemented an in-game economy with a 104-item cosmetic shop,
  configurable stat bonuses, and gamepass monetization logic integrated into the
  player progression and reward system"
  
  WHAT THIS SCRIPT DOES:
  • Manages all player visual appearance server-side (so all other players see it)
  • Disables CharacterAutoLoads — spawns characters manually with a clean
    HumanoidDescription (preserves face + skin tone; strips all default accessories)
  • Reads EquippedJersey / EquippedHelmet / EquippedCleats from GameData folder
  • Applies jersey by directly setting body-part BrickColor (no Shirt asset IDs)
  • Applies helmet as a Sphere SpecialMesh Accessory (built-in, always renders)
  • Applies cleats as Cylinder SpecialMesh Accessories on each foot (left + right)
  • Re-applies cosmetics on CharacterAdded AND whenever any Equipped* value changes
    (debounced 0.4s to batch rapid sequential changes into one visual update)
  • BindableEvent "RefreshCosmetics" lets GameServer trigger re-apply after buy/equip

  COSMETIC ARCHITECTURE:
  Jersey  → Body-part BrickColor tinting (UpperTorso, LowerTorso, UpperArm, LowerArm, Hand × 2, UpperLeg, LowerLeg, Foot × 2)
  Helmet  → Accessory with Sphere SpecialMesh parented to Head attachment
  Cleats  → Two Accessories with Cylinder SpecialMesh on LeftFoot and RightFoot attachments
  
  WHY SERVER-SIDE:
  If cosmetics were applied client-side only, other players wouldn't see them.
  Server-side application via HumanoidDescription/Accessory ensures replication.
================================================================================
--]]

print("[CosmeticsServer] v9 loaded — color jerseys, sphere helmets, cylinder cleats")

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

-- ShopCatalog: needed to look up item colour by equipped item ID
local ShopCatalog = require(ReplicatedStorage:WaitForChild("ShopCatalog"))

-- BindableEvent: allows GameServer (or any server script) to trigger a cosmetics
-- refresh for a specific player — fires after buy/equip transactions complete
local refreshBE = Instance.new("BindableEvent")
refreshBE.Name   = "RefreshCosmetics"
refreshBE.Parent = ReplicatedStorage

-- ── Disable CharacterAutoLoads ─────────────────────────────────────────────────
-- We take manual control of character spawning so we can apply a clean
-- HumanoidDescription (strips default Roblox accessories and clothing)
-- before the character is first replicated to other clients.
Players.CharacterAutoLoads = false

-- ── Body part names ────────────────────────────────────────────────────────────
-- These are the part names inside the R15 character model.
-- We tint all of them for jersey colour.
local BODY_PARTS = {
    "UpperTorso", "LowerTorso",
    "LeftUpperArm", "LeftLowerArm", "LeftHand",
    "RightUpperArm", "RightLowerArm", "RightHand",
    "LeftUpperLeg", "LeftLowerLeg", "LeftFoot",
    "RightUpperLeg", "RightLowerLeg", "RightFoot",
}

-- ── applyJersey ────────────────────────────────────────────────────────────────
-- Sets BrickColor on all body parts to simulate a jersey colour.
-- We avoid Shirt/Pants assets because they require specific Roblox asset IDs
-- that can break; BrickColor tinting always works regardless of catalog status.
local function applyJersey(character, color3)
    if not character then return end
    for _, partName in ipairs(BODY_PARTS) do
        local part = character:FindFirstChild(partName)
        if part then
            part.BrickColor = BrickColor.new(color3)
        end
    end
end

-- ── makeAccessory ──────────────────────────────────────────────────────────────
-- Creates a Roblox Accessory instance with a SpecialMesh.
-- meshType: "Sphere" for helmets, "Cylinder" for cleats.
-- Returns the Accessory ready to be parented into the character.
local function makeAccessory(meshType, color3, scale, cframe)
    local acc  = Instance.new("Accessory")
    local part = Instance.new("Part")
    part.Name            = "Handle"
    part.CanCollide      = false
    part.Massless        = true  -- doesn't affect physics
    part.Size            = Vector3.new(1, 1, 1)
    part.BrickColor      = BrickColor.new(color3)
    part.CFrame          = cframe or CFrame.new(0, 0, 0)
    part.Parent          = acc

    local mesh = Instance.new("SpecialMesh")
    mesh.MeshType  = Enum.MeshType[meshType]  -- "Sphere" or "Cylinder"
    mesh.Scale     = scale or Vector3.new(1.2, 1.2, 1.2)
    mesh.Parent    = part

    return acc
end

-- ── applyHelmet ────────────────────────────────────────────────────────────────
-- Creates a sphere-shaped Accessory and welds it to the character's Head.
-- Sphere SpecialMesh is a built-in mesh that always renders without external assets.
local function applyHelmet(character, color3)
    if not character then return end
    local head = character:FindFirstChild("Head")
    if not head then return end

    local acc  = makeAccessory("Sphere", color3, Vector3.new(1.15, 1.15, 1.15))
    local handle = acc:FindFirstChild("Handle")
    if not handle then return end

    -- Weld to Head so it moves with the character
    local weld = Instance.new("Weld")
    weld.Part0  = head
    weld.Part1  = handle
    weld.C0     = CFrame.new(0, 0.05, 0)  -- slight Y offset sits on top of head
    weld.Parent = handle

    acc.Parent = character
end

-- ── applyCleats ────────────────────────────────────────────────────────────────
-- Creates two Cylinder Accessories, one for each foot.
-- Cylinder SpecialMesh is another built-in mesh (no asset ID needed).
local function applyCleats(character, color3)
    if not character then return end
    local leftFoot  = character:FindFirstChild("LeftFoot")
    local rightFoot = character:FindFirstChild("RightFoot")

    local function attachCleat(foot)
        if not foot then return end
        local acc    = makeAccessory("Cylinder", color3, Vector3.new(0.3, 1.1, 0.3))
        local handle = acc:FindFirstChild("Handle")
        if not handle then return end
        local weld = Instance.new("Weld")
        weld.Part0  = foot
        weld.Part1  = handle
        weld.C0     = CFrame.new(0, -0.5, 0)  -- attach below the foot
        weld.Parent = handle
        acc.Parent = character
    end

    attachCleat(leftFoot)
    attachCleat(rightFoot)
end

-- ── removeCosmetics ────────────────────────────────────────────────────────────
-- Removes all cosmetic accessories from the character before re-applying.
-- Called at the top of applyCosmetics to avoid stacking duplicate helmets/cleats.
local function removeCosmetics(character)
    if not character then return end
    for _, child in ipairs(character:GetChildren()) do
        if child:IsA("Accessory") then
            child:Destroy()
        end
    end
end

-- ── applyCosmetics ────────────────────────────────────────────────────────────
-- Main function: reads the player's GameData folder for equipped item IDs,
-- looks up colours from ShopCatalog, then applies jersey/helmet/cleats.
local function applyCosmetics(player)
    local character = player.Character
    if not character then return end

    -- Read equipped item IDs from the GameData folder
    local gameData = player:FindFirstChild("GameData")
    if not gameData then return end

    local jerseyId = (gameData:FindFirstChild("EquippedJersey") or {}).Value or "jersey_1"
    local helmetId = (gameData:FindFirstChild("EquippedHelmet") or {}).Value or "helmet_1"
    local cleatsId = (gameData:FindFirstChild("EquippedCleats") or {}).Value or "cleats_1"

    -- Look up item colours from ShopCatalog
    local jerseyItem = ShopCatalog.ById[jerseyId]
    local helmetItem = ShopCatalog.ById[helmetId]
    local cleatsItem = ShopCatalog.ById[cleatsId]

    local jerseyColor = jerseyItem and jerseyItem.color or Color3.fromRGB(240, 240, 240)
    local helmetColor = helmetItem and helmetItem.color or Color3.fromRGB(200, 200, 200)
    local cleatsColor = cleatsItem and cleatsItem.color or Color3.fromRGB(100, 80, 60)

    -- Remove old cosmetics before applying new ones (prevents stacking duplicates)
    removeCosmetics(character)

    -- Apply all three cosmetic types
    applyJersey(character, jerseyColor)
    applyHelmet(character, helmetColor)
    applyCleats(character, cleatsColor)
end

-- ── Debounce helper ────────────────────────────────────────────────────────────
-- applyCosmetics is triggered any time any Equipped* value changes.
-- Debouncing 0.4s ensures rapid sequential changes (e.g. buying then equipping)
-- result in a single re-apply rather than multiple rapid calls.
local debounceTimers = {}
local function debouncedApply(player)
    if debounceTimers[player.UserId] then
        debounceTimers[player.UserId]:Disconnect()
    end
    debounceTimers[player.UserId] = task.delay(0.4, function()
        debounceTimers[player.UserId] = nil
        applyCosmetics(player)
    end)
end

-- ── Spawn character ────────────────────────────────────────────────────────────
-- Since CharacterAutoLoads = false, we spawn manually.
-- Apply a clean HumanoidDescription: preserves face asset + body colors from
-- the player's avatar, but strips all default accessories (hats, shirts, pants).
local function spawnCharacter(player)
    -- Build a clean HumanoidDescription from the player's avatar
    local desc = Players:GetHumanoidDescriptionFromUserId(player.UserId)
    -- Strip all default accessories/clothing that might conflict with our cosmetics
    desc.HatAccessory       = ""
    desc.HairAccessory      = ""
    desc.FaceAccessory      = ""
    desc.BackAccessory      = ""
    desc.ShoulderAccessory  = ""
    desc.FrontAccessory     = ""
    desc.WaistAccessory     = ""
    desc.Shirt              = 0
    desc.Pants              = 0
    desc.GraphicTShirt      = 0
    player:LoadCharacterWithHumanoidDescription(desc)
end

-- ── PlayerAdded: wire up character events ─────────────────────────────────────
Players.PlayerAdded:Connect(function(player)
    -- Spawn character on join (since CharacterAutoLoads = false)
    spawnCharacter(player)

    player.CharacterAdded:Connect(function(character)
        -- Wait for the character model to fully load before applying cosmetics
        character:WaitForChild("HumanoidRootPart", 5)
        task.wait(0.2)  -- brief wait for GameData folder to be populated by DataManager
        applyCosmetics(player)

        -- Watch for GameData Equipped* value changes so cosmetics update live
        -- when player buys or equips items (without needing to respawn)
        local gameData = player:FindFirstChild("GameData")
        if gameData then
            local function watchValue(valueName)
                local v = gameData:WaitForChild(valueName, 3)
                if v then
                    v.Changed:Connect(function()
                        debouncedApply(player)  -- debounced so rapid changes batch together
                    end)
                end
            end
            watchValue("EquippedJersey")
            watchValue("EquippedHelmet")
            watchValue("EquippedCleats")
            -- Note: EquippedBall is handled by GameServer directly (visual is on the ball model)
        end

        -- Respawn on character death
        local humanoid = character:WaitForChild("Humanoid")
        humanoid.Died:Connect(function()
            task.wait(3)  -- respawn delay
            if player.Parent then
                spawnCharacter(player)
            end
        end)
    end)
end)

-- ── BindableEvent: RefreshCosmetics ───────────────────────────────────────────
-- GameServer fires this after buy/equip transactions so cosmetics update
-- immediately without waiting for the debounced value-change handler.
refreshBE.Event:Connect(function(player)
    if player and player.Parent then
        applyCosmetics(player)
    end
end)

-- ── Bootstrap players already in-game (Studio hot-reload) ─────────────────────
for _, player in ipairs(Players:GetPlayers()) do
    if player.Character then
        task.spawn(applyCosmetics, player)
    else
        spawnCharacter(player)
    end
end

print("[CosmeticsServer] Cosmetics wired — jersey tinting, sphere helmets, cylinder cleats")
