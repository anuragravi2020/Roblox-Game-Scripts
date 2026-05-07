--[[
================================================================================
  GameServer  (ServerScriptService)
  
  RESUME BULLETS:
  1. "Architected client/server game systems in Luau using RemoteEvents and
     RemoteFunctions to cleanly separate game logic, shop transactions, and
     player state across the network boundary"
  
  3. "Implemented an in-game economy with a 104-item cosmetic shop, configurable
     stat bonuses, and gamepass monetization logic integrated into the player
     progression and reward system"
  
  WHAT THIS SCRIPT DOES:
  • Single authoritative server script — ALL game rules live here
  • Player state initialisation (GameData folder + in-memory tables)
  • Gamepass ownership checks + live purchases via MarketplaceService
  • Developer product (cash bundle) purchases via ProcessReceipt
  • KickBall RemoteEvent: physics simulation, cash formula, stat updates
  • Shop RemoteEvents: BuyShopItem, EquipShopItem, GetShopData
  • Rebirth prestige mechanic

  NETWORK BOUNDARY:
  • Client fires KickBall/BuyShopItem/EquipShopItem  → server validates & responds
  • Server fires KickResult/ShopItemResult/UpdateCurrency → client updates UI
  • GetShopData is a RemoteFunction (client invokes, server returns table)
================================================================================
--]]

-- GameServer: Football Kicking Simulator
-- Single authoritative copy — do not duplicate

local Players            = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")

-- All RemoteEvents live in ReplicatedStorage/RemoteEvents folder.
-- Client and server both reference the same objects — this is the network boundary.
local RE             = ReplicatedStorage:WaitForChild("RemoteEvents")
local KickBall       = RE:WaitForChild("KickBall")       -- client → server: kick request
local KickResult     = RE:WaitForChild("KickResult")     -- server → client: kick outcome
local UpdateCurrency = RE:WaitForChild("UpdateCurrency") -- server → client: refresh cash HUD
local BuyShopItem    = RE:WaitForChild("BuyShopItem")    -- client → server: purchase request
local EquipShopItem  = RE:WaitForChild("EquipShopItem")  -- client → server: equip request
local ShopItemResult = RE:WaitForChild("ShopItemResult") -- server → client: buy/equip outcome
local GetShopData    = RE:WaitForChild("GetShopData")    -- RemoteFunction: owned/equipped items
local RebirthRE      = RE:FindFirstChild("Rebirth")      -- client → server: prestige reset
local GetPlayerData  = RE:FindFirstChild("GetPlayerData")-- RemoteFunction: raw data table for UI

-- ShopCatalog ModuleScript: shared between server and client, defines all 104 items
local ShopCatalog = require(ReplicatedStorage:WaitForChild("ShopCatalog"))

-- ── Gamepass IDs ──────────────────────────────────────────────────────────────
-- Maps Roblox gamepass asset IDs to internal bonus names.
-- Each pass permanently modifies the player's stat bonuses for the session.
local GAMEPASS_IDS = {
    [1812865009] = "SpeedBonus",     -- +10% speed on kicks
    [1811401069] = "PowerBonus",     -- +25% power on kicks
    [1811113060] = "KickSpeedBonus", -- faster kick charge bar
    [1811545077] = "AutoKick",       -- automatically triggers kicks
    [1811689145] = "TwoxCash",       -- doubles all cash earned
    [1811329041] = "AccuracyBonus",  -- +150 accuracy points
}

-- ── Developer product cash amounts ────────────────────────────────────────────
-- Maps Roblox developer product IDs to the amount of in-game cash granted.
-- ProcessReceipt below handles these — must return PurchaseGranted or data is lost.
local PRODUCT_CASH = {
    [3581387507] = 25000,
    [3581389045] = 100000,
    [3581390209] = 1000000,
    [3581390960] = 5000000,
    [3581391771] = 1000000000,   -- $1 Billion bundle
    [3581392699] = 10000000000,  -- $10 Billion bundle
}

-- BASE_CASH: the fundamental cash constant all formulas scale from.
-- Tier-1 ball earns ~$50/goal. End-game Divine gear earns ~$50K+/goal.
local BASE_CASH = 500

-- ── In-memory player state ────────────────────────────────────────────────────
-- Three separate tables to avoid mixing concerns:
--   playerData    = numeric stats (Cash, Goals, etc.)
--   ownedItems    = set of purchased item IDs {itemId = true}
--   equippedItems = currently equipped item per category {Ball=..., Jersey=...}
local playerData    = {}
local ownedItems    = {}
local equippedItems = {}

-- ── Helpers ───────────────────────────────────────────────────────────────────
-- fmtCash: formats large numbers as "$1.5M", "$2.3B", etc. for display
local function fmtCash(n)
    if     n >= 1e12 then return "$"..string.format("%.3gT", n/1e12)
    elseif n >= 1e9  then return "$"..string.format("%.3gB", n/1e9)
    elseif n >= 1e6  then return "$"..string.format("%.3gM", n/1e6)
    elseif n >= 1e3  then return "$"..string.format("%.3gK", n/1e3)
    else return "$"..math.floor(n) end
end

-- setFV: sets a Value object inside the player's GameData folder.
-- GameData values are replicated to all clients automatically by Roblox.
local function setFV(player, key, value)
    local folder = player:FindFirstChild("GameData")
    if not folder then return end
    local v = folder:FindFirstChild(key)
    if v then v.Value = value end
end

-- ── Create GameData folder ────────────────────────────────────────────────────
-- Called every CharacterAdded. Destroys old folder first to avoid duplicates.
-- Creates NumberValue / BoolValue / StringValue children for each stat —
-- these replicate to all clients and DataManager reads them for persistence.
local function createGameData(player)
    local existing = player:FindFirstChild("GameData")
    if existing then existing:Destroy() end
    local folder = Instance.new("Folder")
    folder.Name = "GameData"
    folder.Parent = player
    -- Helper closures to reduce boilerplate
    local function N(n,d) local v=Instance.new("NumberValue"); v.Name=n; v.Value=d or 0; v.Parent=folder end
    local function B(n,d) local v=Instance.new("BoolValue");   v.Name=n; v.Value=d or false; v.Parent=folder end
    local function S(n,d) local v=Instance.new("StringValue"); v.Name=n; v.Value=d or ""; v.Parent=folder end
    N("Cash",              0)
    N("TotalCashEarned",   0)
    N("Goals",             0)
    N("Snipes",            0)
    N("Attempts",          0)
    N("LongestGoal",       0)
    N("Rebirths",          0)
    N("RebirthMultiplier", 1)
    N("CashLevel",         0)
    B("HasAutoKick",        false)
    B("Has2xCash",          false)
    N("SpeedPassBonus",     0)
    N("PowerPassBonus",     0)
    N("AccuracyPassBonus",  0)
    B("KickSpeedPassBonus", false)
    N("BallTier",    1)
    N("JerseyTier",  1)
    N("CleatsTier",  1)
    N("HelmetTier",  1)
    N("BallColorR",  1)
    N("BallColorG",  1)
    N("BallColorB",  1)
    S("EquippedBall",   "ball_1")
    S("EquippedJersey", "jersey_1")
    S("EquippedCleats", "cleats_1")
    S("EquippedHelmet", "helmet_1")
end

-- ── Apply gamepass bonus ───────────────────────────────────────────────────────
-- Writes the bonus from a gamepass into the player's in-memory data table
-- AND into the GameData folder (so it persists this session).
local function applyPassBonus(player, data, passName)
    if passName == "AutoKick" then
        data.HasAutoKick = true
        setFV(player, "HasAutoKick", true)
    elseif passName == "TwoxCash" then
        data.Has2xCash = true
        setFV(player, "Has2xCash", true)
    elseif passName == "SpeedBonus" then
        data.SpeedPassBonus = 10
        setFV(player, "SpeedPassBonus", 10)
    elseif passName == "PowerBonus" then
        data.PowerPassBonus = 25
        setFV(player, "PowerPassBonus", 25)
    elseif passName == "AccuracyBonus" then
        data.AccuracyPassBonus = 150
        setFV(player, "AccuracyPassBonus", 150)
    elseif passName == "KickSpeedBonus" then
        data.KickSpeedPassBonus = true
        setFV(player, "KickSpeedPassBonus", true)
    end
end

-- ── Check gamepasses on join ───────────────────────────────────────────────────
-- Iterates all gamepass IDs and applies bonuses for any the player owns.
-- pcall wraps each UserOwnsGamePassAsync call — Roblox API calls can fail.
-- Runs in a task.spawn so it doesn't block PlayerAdded.
local function checkGamepasses(player, data)
    for passId, passName in pairs(GAMEPASS_IDS) do
        local ok, owned = pcall(function()
            return MarketplaceService:UserOwnsGamePassAsync(player.UserId, passId)
        end)
        if ok and owned then
            applyPassBonus(player, data, passName)
        end
    end
end

-- ── Player join ───────────────────────────────────────────────────────────────
Players.PlayerAdded:Connect(function(player)
    -- Initialise all three state tables with defaults
    local data = {
        Cash=0, TotalCashEarned=0, Goals=0, Snipes=0, Attempts=0, LongestGoal=0,
        Rebirths=0, RebirthMultiplier=1, CashLevel=0,
        HasAutoKick=false, Has2xCash=false,
        SpeedPassBonus=0, PowerPassBonus=0, AccuracyPassBonus=0, KickSpeedPassBonus=false,
    }
    playerData[player.UserId]    = data
    ownedItems[player.UserId]    = {}
    equippedItems[player.UserId] = {Ball="ball_1", Jersey="jersey_1", Cleats="cleats_1", Helmet="helmet_1"}
    -- Create GameData folder if character already exists (Studio hot-reload edge case)
    if player.Character then createGameData(player) end
    player.CharacterAdded:Connect(function() createGameData(player) end)
    -- Check gamepasses async so join isn't delayed
    task.spawn(checkGamepasses, player, data)
end)

-- Clean up state tables on leave (prevents memory leaks)
Players.PlayerRemoving:Connect(function(player)
    playerData[player.UserId]    = nil
    ownedItems[player.UserId]    = nil
    equippedItems[player.UserId] = nil
end)

-- ── Gamepass purchased live (during session) ───────────────────────────────────
-- Fires when a player completes a gamepass purchase prompt mid-game.
MarketplaceService.PromptGamePassPurchaseFinished:Connect(function(player, passId, purchased)
    if not purchased then return end
    local passName = GAMEPASS_IDS[passId]
    if not passName then return end
    local data = playerData[player.UserId]
    if not data then return end
    applyPassBonus(player, data, passName)
    print("[GameServer] Pass applied:", passName, "->", player.Name)
end)

-- ── Developer product handler ──────────────────────────────────────────────────
-- ProcessReceipt is called by Roblox when a developer product purchase completes.
-- MUST return PurchaseGranted after successfully granting the product, or Roblox
-- will attempt to re-deliver it. If the player isn't loaded yet, return
-- NotProcessedYet so Roblox retries later.
MarketplaceService.ProcessReceipt = function(receiptInfo)
    local cashAmt = PRODUCT_CASH[receiptInfo.ProductId]
    if not cashAmt then return Enum.ProductPurchaseDecision.NotProcessedYet end
    local player = Players:GetPlayerByUserId(receiptInfo.PlayerId)
    if not player then return Enum.ProductPurchaseDecision.NotProcessedYet end
    local data = playerData[player.UserId]
    if not data then return Enum.ProductPurchaseDecision.NotProcessedYet end
    data.Cash = (data.Cash or 0) + cashAmt
    data.TotalCashEarned = (data.TotalCashEarned or 0) + cashAmt
    setFV(player, "Cash",           data.Cash)
    setFV(player, "TotalCashEarned",data.TotalCashEarned)
    UpdateCurrency:FireClient(player, data.Cash)  -- push new balance to HUD immediately
    print("[GameServer] Product", receiptInfo.ProductId, "-> +$"..cashAmt, "for", player.Name)
    return Enum.ProductPurchaseDecision.PurchaseGranted
end

-- ── Kick handler ───────────────────────────────────────────────────────────────
-- CLIENT sends: KickBall:FireServer(power)
-- SERVER validates power, looks up equipped gear stats from ShopCatalog,
-- runs the physics/probability formula, awards cash, updates stats, and
-- fires KickResult back to the client with the outcome.
--
-- kickInFlight guard: prevents a client from firing multiple kick events
-- within 1 second (exploit prevention / duplicate event prevention).
local kickInFlight = {}

KickBall.OnServerEvent:Connect(function(player, power)
    local uid = player.UserId
    -- Anti-spam: ignore if a kick is already being processed for this player
    if kickInFlight[uid] then return end
    kickInFlight[uid] = true
    task.delay(1.0, function() kickInFlight[uid] = false end)

    -- Clamp power to valid range — never trust raw client input
    power = math.clamp(tonumber(power) or 0.5, 0.08, 1.5)
    local data     = playerData[uid]
    if not data then kickInFlight[uid] = false; return end
    local equipped = equippedItems[uid] or {}

    -- Fetch item stat tables from ShopCatalog for all 4 equipped slots
    local ball   = ShopCatalog.ById[equipped.Ball   or "ball_1"]
    local jersey = ShopCatalog.ById[equipped.Jersey  or "jersey_1"]
    local cleats = ShopCatalog.ById[equipped.Cleats  or "cleats_1"]
    local helm   = ShopCatalog.ById[equipped.Helmet  or "helmet_1"]

    -- Ball-specific multipliers (gate scoring and distance ceiling)
    local goalMult  = ball and ball.goalMult or 0.35  -- base goal probability modifier
    local distMult  = ball and ball.distMult or 0.30  -- fraction of max distance
    local ballTier  = ball and ball.tier     or 1
    local ballColor = ball and ball.color    or Color3.new(1,1,1)

    -- Sum cashBonus across all 4 gear slots (additive)
    local totalCashBonus =
        (ball    and ball.cashBonus    or 0) +
        (jersey  and jersey.cashBonus  or 0) +
        (cleats  and cleats.cashBonus  or 0) +
        (helm    and helm.cashBonus    or 0)

    -- Sum powerBonus from gear + gamepass; clamp the effective kick power
    local gearPowerBonus =
        (ball    and ball.powerBonus    or 0) +
        (jersey  and jersey.powerBonus  or 0) +
        (cleats  and cleats.powerBonus  or 0) +
        (helm    and helm.powerBonus    or 0)
    local effectivePower = math.clamp(power + (data.PowerPassBonus or 0)/100 + gearPowerBonus, 0.08, 1.5)

    -- Sum accuracyBonus from gear + gamepass
    local gearAccBonus =
        (ball    and ball.accuracyBonus    or 0) +
        (jersey  and jersey.accuracyBonus  or 0) +
        (cleats  and cleats.accuracyBonus  or 0) +
        (helm    and helm.accuracyBonus    or 0)

    -- Sum speedBonus from gear (used as a cash multiplier: +65% Speed → 1.65× cash)
    local gearSpeedBonus =
        (ball    and ball.speedBonus    or 0) +
        (jersey  and jersey.speedBonus  or 0) +
        (cleats  and cleats.speedBonus  or 0) +
        (helm    and helm.speedBonus    or 0)
    local speedFactor = 1 + gearSpeedBonus

    -- Goal probability: goalMult × power × gear accuracy bonuses, capped at 92%
    local goalChance = math.clamp(goalMult * effectivePower * 0.85 + (data.AccuracyPassBonus or 0)/2000 + gearAccBonus, 0.05, 0.92)
    local isGoal     = math.random() < goalChance
    local isSnipe    = false

    -- Random kick distance within a tier-scaled range
    local maxDist = math.floor(180 * distMult * effectivePower)
    local minDist = math.max(20, math.floor(maxDist * 0.65))
    local distance = math.random(minDist, math.max(minDist, maxDist))

    -- Snipe (corner goal) chance — increases with accuracy gamepass
    if isGoal then
        local snipeChance = 0.08 + ((data.AccuracyPassBonus or 0) / 300) * 0.25
        isSnipe = math.random() < snipeChance
    end

    -- Cash formula: BASE × goalMult × distMult × (1 + totalCashBonus) × power × speedFactor
    -- Snipe multiplies cash by 4. Rebirth and CashLevel apply on top.
    local rebirthMult    = data.RebirthMultiplier or 1
    local cashLevelBonus = 1 + (data.CashLevel or 0) * 0.1
    local cash
    if isGoal then
        cash = BASE_CASH * goalMult * distMult * (1 + totalCashBonus) * effectivePower * speedFactor
        if isSnipe then cash = cash * 4 end
    else
        cash = BASE_CASH * distMult * (1 + totalCashBonus) * effectivePower * 0.15 * speedFactor
    end
    cash = math.floor(cash * rebirthMult * cashLevelBonus)
    if data.Has2xCash then cash = cash * 2 end  -- 2× gamepass doubles everything
    cash = math.max(cash, 1)  -- always earn at least $1

    -- Write new stats into both in-memory table and GameData folder (replicated to all clients)
    data.Cash            = (data.Cash or 0) + cash
    data.TotalCashEarned = (data.TotalCashEarned or 0) + cash
    data.Attempts        = (data.Attempts or 0) + 1
    setFV(player, "Cash",           data.Cash)
    setFV(player, "TotalCashEarned",data.TotalCashEarned)
    setFV(player, "Attempts",       data.Attempts)
    if isGoal then
        data.Goals = (data.Goals or 0) + 1
        setFV(player, "Goals", data.Goals)
        if isSnipe then
            data.Snipes = (data.Snipes or 0) + 1
            setFV(player, "Snipes", data.Snipes)
        end
        if distance > (data.LongestGoal or 0) then
            data.LongestGoal = distance
            setFV(player, "LongestGoal", distance)
        end
    end

    -- Fire outcome back to client (one fire, no duplicates)
    KickResult:FireClient(player, {
        power    = effectivePower,
        isGoal   = isGoal,
        isSnipe  = isSnipe,
        distance = distance,
        cash     = cash,
        cashStr  = fmtCash(cash),
        ballTier   = ballTier,
        ballColorR = ballColor.R,
        ballColorG = ballColor.G,
        ballColorB = ballColor.B,
        distMult   = distMult,
    })
end)

-- ── Shop: GetShopData (RemoteFunction) ────────────────────────────────────────
-- Client invokes this to get their current owned + equipped items when opening shop.
-- Returns a table the ShopController uses to set button states (Buy / Equip / Equipped).
GetShopData.OnServerInvoke = function(player)
    local owned    = ownedItems[player.UserId]    or {}
    local equipped = equippedItems[player.UserId] or {}
    -- Tier-1 starter items are always free and always considered owned
    owned["ball_1"]   = true
    owned["jersey_1"] = true
    owned["cleats_1"] = true
    owned["helmet_1"] = true
    local parts = {}
    for id in pairs(owned) do table.insert(parts, id) end
    return {
        OwnedItems     = table.concat(parts, ","),  -- CSV string of owned item IDs
        EquippedBall   = equipped.Ball   or "ball_1",
        EquippedJersey = equipped.Jersey or "jersey_1",
        EquippedCleats = equipped.Cleats or "cleats_1",
        EquippedHelmet = equipped.Helmet or "helmet_1",
    }
end

-- ── Shop: BuyShopItem (RemoteEvent) ───────────────────────────────────────────
-- Server validates purchase server-side:
--   1. Item exists in catalog
--   2. Player doesn't already own it
--   3. Player has enough cash
-- Only then deducts cash, marks owned, auto-equips, and syncs GameData folder.
BuyShopItem.OnServerEvent:Connect(function(player, itemId)
    local data     = playerData[player.UserId]
    local owned    = ownedItems[player.UserId]
    local equipped = equippedItems[player.UserId]
    if not (data and owned) then return end

    local item = ShopCatalog.ById[itemId]
    if not item then ShopItemResult:FireClient(player, false, "Invalid item", itemId); return end

    if item.tier == 1 or owned[itemId] then
        owned[itemId] = true
        ShopItemResult:FireClient(player, false, "Already owned", itemId)
        return
    end

    if (data.Cash or 0) < item.price then
        ShopItemResult:FireClient(player, false, "Not enough cash", itemId)
        return
    end

    -- Deduct cash and update both in-memory and GameData folder
    data.Cash = data.Cash - item.price
    setFV(player, "Cash", data.Cash)
    UpdateCurrency:FireClient(player, data.Cash)
    owned[itemId] = true

    -- Auto-equip newly purchased item (also updates GameData for CosmeticsServer to read)
    if equipped then equipped[item.category] = itemId end
    setFV(player, item.category.."Tier", item.tier)
    if item.category == "Ball" then
        setFV(player, "EquippedBall",   itemId)
        setFV(player, "BallColorR", item.color.R)
        setFV(player, "BallColorG", item.color.G)
        setFV(player, "BallColorB", item.color.B)
    elseif item.category == "Jersey" then
        setFV(player, "EquippedJersey", itemId)
    elseif item.category == "Cleats" then
        setFV(player, "EquippedCleats", itemId)
    elseif item.category == "Helmet" then
        setFV(player, "EquippedHelmet", itemId)
    end

    ShopItemResult:FireClient(player, true, "Purchased", itemId)
    print("[GameServer] Buy:", player.Name, itemId, "-$"..item.price)
    -- Trigger CosmeticsServer to immediately refresh the player's visual appearance
    local refreshBE = ReplicatedStorage:FindFirstChild("RefreshCosmetics")
    if refreshBE and (item.category == "Jersey" or item.category == "Helmet" or item.category == "Cleats") then
        refreshBE:Fire(player)
    end
end)

-- ── Shop: EquipShopItem (RemoteEvent) ─────────────────────────────────────────
-- Equip an already-owned item. Same validation flow but no cash deduction.
EquipShopItem.OnServerEvent:Connect(function(player, itemId)
    local data     = playerData[player.UserId]
    local owned    = ownedItems[player.UserId]
    local equipped = equippedItems[player.UserId]
    if not (data and owned) then return end

    local item = ShopCatalog.ById[itemId]
    if not item then ShopItemResult:FireClient(player, false, "Invalid item", itemId); return end

    -- Server-side ownership check — client can't fake owning an item
    if item.tier ~= 1 and not owned[itemId] then
        ShopItemResult:FireClient(player, false, "Not owned", itemId)
        return
    end

    if equipped then equipped[item.category] = itemId end
    setFV(player, item.category.."Tier", item.tier)
    if item.category == "Ball" then
        setFV(player, "EquippedBall",   itemId)
        setFV(player, "BallColorR", item.color.R)
        setFV(player, "BallColorG", item.color.G)
        setFV(player, "BallColorB", item.color.B)
    elseif item.category == "Jersey" then
        setFV(player, "EquippedJersey", itemId)
    elseif item.category == "Cleats" then
        setFV(player, "EquippedCleats", itemId)
    elseif item.category == "Helmet" then
        setFV(player, "EquippedHelmet", itemId)
    end

    ShopItemResult:FireClient(player, true, "Equipped", itemId)
    print("[GameServer] Equip:", player.Name, itemId)
    local refreshBE = ReplicatedStorage:FindFirstChild("RefreshCosmetics")
    if refreshBE and (item.category == "Jersey" or item.category == "Helmet" or item.category == "Cleats") then
        refreshBE:Fire(player)
    end
end)

-- ── GetPlayerData (RemoteFunction) ────────────────────────────────────────────
-- Returns the raw playerData table to a client (used by HUD/UI scripts
-- that need things like Rebirths or CashLevel for display purposes).
if GetPlayerData then
    GetPlayerData.OnServerInvoke = function(player)
        return playerData[player.UserId] or {}
    end
end

-- ── Rebirth (prestige reset) ───────────────────────────────────────────────────
-- Costs $1 Billion, resets cash to 0, increments rebirth count,
-- and increases RebirthMultiplier by 0.5× per rebirth.
if RebirthRE then
    RebirthRE.OnServerEvent:Connect(function(player)
        local data = playerData[player.UserId]
        if not data then return end
        local REBIRTH_COST = 1000000000
        if (data.Cash or 0) < REBIRTH_COST then return end
        data.Cash = 0
        data.Rebirths = (data.Rebirths or 0) + 1
        data.RebirthMultiplier = 1 + data.Rebirths * 0.5
        setFV(player, "Cash",             0)
        setFV(player, "Rebirths",          data.Rebirths)
        setFV(player, "RebirthMultiplier", data.RebirthMultiplier)
        UpdateCurrency:FireClient(player, 0)
        print("[GameServer] Rebirth:", player.Name, "x"..data.Rebirths)
    end)
end

-- ── Bootstrap players already in game (Studio hot-reload) ─────────────────────
for _, player in ipairs(Players:GetPlayers()) do
    if not playerData[player.UserId] then
        local data = {
            Cash=0, TotalCashEarned=0, Goals=0, Snipes=0, Attempts=0, LongestGoal=0,
            Rebirths=0, RebirthMultiplier=1, CashLevel=0,
            HasAutoKick=false, Has2xCash=false,
            SpeedPassBonus=0, PowerPassBonus=0, AccuracyPassBonus=0, KickSpeedPassBonus=false,
        }
        playerData[player.UserId]    = data
        ownedItems[player.UserId]    = {}
        equippedItems[player.UserId] = {Ball="ball_1", Jersey="jersey_1", Cleats="cleats_1", Helmet="helmet_1"}
        if player.Character then createGameData(player) end
        player.CharacterAdded:Connect(function() createGameData(player) end)
        task.spawn(checkGamepasses, player, data)
    end
end

print("[GameServer] Loaded — BASE_CASH="..BASE_CASH.." | acc/speed bonuses active")
