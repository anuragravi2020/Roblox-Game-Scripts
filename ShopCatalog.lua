--[[
================================================================================
  ShopCatalog  (ReplicatedStorage — ModuleScript)
  
  RESUME BULLET: "Implemented an in-game economy with a 104-item cosmetic shop,
  configurable stat bonuses, and gamepass monetization logic"
  
  WHAT THIS SCRIPT DOES:
  • Defines all 104 shop items (26 tiers × 4 categories: Ball, Jersey, Cleats, Helmet)
  • Shared between server (GameServer) AND client (ShopController) — same module, same data
  • Generates items procedurally from compact name/description/colour tables
  • Stat bonuses scale linearly from tier 1→26 using lerp()
  • Exposes: ShopCatalog.Items, ShopCatalog.ById, ShopCatalog.GetCategory(),
             ShopCatalog.RarityColors

  ITEM COUNTS:
  • 26 balls × 1 = 26
  • 26 jerseys × 1 = 26
  • 26 cleats × 1 = 26
  • 26 helmets × 1 = 26
  • TOTAL: 104 items

  RARITIES:
  Common (1-3) → Uncommon (4-6) → Rare (7-9) → Epic (10-13) → Legendary (14-18)
  → Mythic (19-22) → Divine (23-26)

  PRICE RANGE: $0 (tier 1 free starter) → $10 Billion (tier 26 Divine cap)
================================================================================
--]]

-- ShopCatalog: 26 items per category (Ball, Jersey, Cleats, Helmet)
-- Bonuses scale linearly from tier 1..26. Ball goalMult/distMult gate scoring.

local ShopCatalog = {}

-- PRICES: 26 price points from free ($0) to endgame ($10B Divine).
-- Designed so each tier costs ~50 goals at the previous tier's earnings.
local PRICES = {
    0, 5000, 8000, 13000, 20000, 30000,
    42000, 58000, 78000, 103000, 135000, 171000,
    209000, 254000, 305000, 364000, 431000, 506000,
    591000, 685000, 791000, 908000, 1038000, 1180000,
    1337000, 10000000000,  -- tier 26 is the ultimate Divine item ($10 Billion)
}

-- RARITIES: maps each tier number to its rarity string
local RARITIES = {
    "Common","Common","Common",              -- tiers 1-3
    "Uncommon","Uncommon","Uncommon",        -- tiers 4-6
    "Rare","Rare","Rare",                    -- tiers 7-9
    "Epic","Epic","Epic","Epic",             -- tiers 10-13
    "Legendary","Legendary","Legendary","Legendary","Legendary", -- 14-18
    "Mythic","Mythic","Mythic","Mythic",     -- tiers 19-22
    "Divine","Divine","Divine","Divine",     -- tiers 23-26
}

-- tf: normalises tier to a 0→1 fraction for use in lerp (tier 1 = 0, tier 26 = 1)
local function lerp(a,b,t) return a+(b-a)*t end
local function tf(tier) return (tier-1)/25 end

-- ── Ball definitions ──────────────────────────────────────────────────────────
-- Format: {displayName, description, {R, G, B}}
-- 26 balls from Classic (free starter) to Godly (Divine tier)
local BALL_DEFS = {
    {"Classic Ball","A trusty old match ball.",{255,255,255}},
    {"Bronze Ball","A notch above the rest.",{180,120,40}},
    {"Silver Ball","Polished to a mirror shine.",{200,210,220}},
    {"Golden Ball","Weighs like a trophy, kicks like a rocket.",{255,210,0}},
    {"Neon Ball","Glows so bright it blinds goalkeepers.",{0,255,200}},
    {"Galaxy Ball","Contains a tiny universe inside.",{80,0,200}},
    {"Inferno Ball","Too hot to handle, too fast to stop.",{255,80,0}},
    {"Celestial Ball","Forged from pure stardust.",{180,200,255}},
    {"Crystal Ball","Clear as glass, hard as ice.",{150,240,255}},
    {"Plasma Ball","Pure unstable energy.",{200,0,255}},
    {"Thunder Ball","Strikes like a bolt from above.",{255,240,0}},
    {"Shadow Ball","Born from the darkest night.",{40,40,60}},
    {"Vortex Ball","Bends the air around it.",{0,200,180}},
    {"Nebula Ball","Dust from ancient dying stars.",{100,0,140}},
    {"Toxic Ball","Approach with extreme caution.",{100,220,0}},
    {"Royal Ball","Only kings deserve this.",{120,0,200}},
    {"Prism Ball","Splits light into every colour.",{240,240,255}},
    {"Omega Ball","The last word in ball technology.",{0,60,180}},
    {"Phantom Ball","You hear it before you see it.",{80,80,120}},
    {"Blaze Ball","Burns with an eternal flame.",{255,100,0}},
    {"Aurora Ball","Dances with the northern lights.",{0,220,180}},
    {"Void Ball","From the space between stars.",{20,0,40}},
    {"Solar Ball","Powered by the sun itself.",{255,200,0}},
    {"Lunar Ball","Blessed by moonlight and tides.",{200,210,255}},
    {"Quantum Ball","Exists in all places at once.",{0,255,255}},
    {"Godly Ball","Touched by the hands of a god.",{255,255,180}},
}

-- ── Jersey definitions ────────────────────────────────────────────────────────
-- Jerseys apply body-part BrickColor tinting (no Shirt asset IDs needed).
-- Color field is used by CosmeticsServer to set UpperTorso/Arms/Legs color.
local JERSEY_DEFS = {
    {"Basic White","Standard issue kit.",{240,240,240}},
    {"Sky Blue","Clean and classic.",{100,180,255}},
    {"Flame Red","For the bold striker.",{220,50,50}},
    {"Forest Green","Blend into the pitch.",{50,160,70}},
    {"Midnight Black","No mercy, no colour.",{30,30,30}},
    {"Royal Purple","Reserved for champions.",{130,0,200}},
    {"Solar Orange","Impossible to miss.",{255,140,0}},
    {"Ice White","Cold as the north wind.",{220,235,255}},
    {"Toxic Green","Glows under stadium lights.",{80,255,80}},
    {"Navy Deep","Classic away strip.",{20,40,120}},
    {"Crimson Wave","Blood and thunder.",{180,0,60}},
    {"Gold Rush","Worth its weight in goals.",{255,200,0}},
    {"Arctic Blue","From the frozen tundra.",{0,200,255}},
    {"Lava Red","Forged in the volcano.",{255,60,0}},
    {"Emerald","The colour of victory.",{0,180,90}},
    {"Obsidian","As dark as your rivals' fears.",{20,15,30}},
    {"Rose Gold","Elegant under the lights.",{255,160,130}},
    {"Storm Grey","Calm before the kick.",{120,130,140}},
    {"Electric Blue","Charged and ready.",{0,120,255}},
    {"Inferno","Burning with desire.",{255,80,20}},
    {"Aurora","Northern lights kit.",{0,240,200}},
    {"Galaxy","For kicks across the cosmos.",{60,0,160}},
    {"Phantom","Ghost on the pitch.",{180,180,220}},
    {"Void","From another dimension.",{10,0,25}},
    {"Mythic Gold","Only myths wear this.",{255,230,80}},
    {"Divine White","Worn by legends.",{255,255,240}},
}

-- ── Cleats definitions ────────────────────────────────────────────────────────
-- Rendered as Cylinder SpecialMesh Accessories on each foot (CosmeticsServer).
local CLEATS_DEFS = {
    {"Basic Boots","Gets the job done.",{100,80,60}},
    {"Leather Cleats","Quality craftsmanship.",{140,100,60}},
    {"Sprint Shoes","Built for speed.",{200,200,200}},
    {"Power Kicks","Extra leverage on impact.",{60,60,200}},
    {"Grip Masters","Planted like a rock.",{80,160,80}},
    {"Turbo Cleats","Zero to full power instantly.",{255,180,0}},
    {"Carbon Fiber","Lighter than air.",{40,40,40}},
    {"Storm Treads","Traction in any weather.",{100,120,160}},
    {"Flash Kicks","Leave afterimages.",{255,255,0}},
    {"Iron Soles","Heavy but devastating.",{150,150,170}},
    {"Fire Boots","Every step scorches.",{255,80,0}},
    {"Ice Blades","Perfect slide tackle.",{180,230,255}},
    {"Venom Kicks","Toxic to defenders.",{120,220,0}},
    {"Shadow Steps","Silent as the night.",{50,50,80}},
    {"Titan Treads","Size of a giant's foot.",{120,80,60}},
    {"Neon Rush","Glow as you go.",{0,255,200}},
    {"Crystal Heels","Transparent perfection.",{200,240,255}},
    {"Thunder Boots","Crack the ground.",{255,240,60}},
    {"Void Walkers","Step through dimensions.",{20,0,40}},
    {"Inferno Soles","Leave scorch marks.",{255,60,0}},
    {"Aurora Kicks","Dance with the lights.",{0,220,180}},
    {"Nebula Steps","One small step, one giant kick.",{100,0,160}},
    {"Solar Sprints","Speed of light.",{255,210,0}},
    {"Quantum Grip","Grip beyond physics.",{0,255,255}},
    {"Mythic Boots","Passed down through ages.",{255,200,80}},
    {"Divine Cleats","Sanctified at the altar.",{255,255,200}},
}

-- ── Helmet definitions ────────────────────────────────────────────────────────
-- Rendered as Sphere SpecialMesh Accessories (built-in mesh, always renders).
local HELMET_DEFS = {
    {"Basic Cap","Sun out of your eyes.",{200,200,200}},
    {"Training Helm","Padding for practice.",{180,160,100}},
    {"Leather Guard","Old-school protection.",{140,100,60}},
    {"Sprint Visor","Aerodynamic edge.",{80,80,200}},
    {"Power Dome","Extra skull armour.",{200,80,80}},
    {"Grip Helm","Stays on through tackles.",{80,160,80}},
    {"Carbon Shell","Featherlight composite.",{40,40,40}},
    {"Storm Visor","Rain can't stop you.",{100,120,160}},
    {"Flash Dome","Bright as a floodlight.",{255,255,0}},
    {"Iron Crown","Forged in the foundry.",{150,150,170}},
    {"Fire Helm","Hotter head, cooler mind.",{255,80,0}},
    {"Ice Dome","Brain stays cool.",{180,230,255}},
    {"Toxic Shell","Hazardous to the opposition.",{120,220,0}},
    {"Shadow Mask","Strikes fear.",{50,50,80}},
    {"Titan Dome","Built like a tank.",{120,80,60}},
    {"Neon Helm","Be seen from the stands.",{0,255,200}},
    {"Crystal Dome","See the field like never before.",{200,240,255}},
    {"Thunder Crown","Electrifies your play.",{255,240,60}},
    {"Void Mask","From the abyss.",{20,0,40}},
    {"Inferno Helm","On fire, literally.",{255,60,0}},
    {"Aurora Crown","Northern lights on your head.",{0,220,180}},
    {"Nebula Dome","Galactic styling.",{100,0,160}},
    {"Solar Helm","Powered by the sun.",{255,210,0}},
    {"Quantum Shell","Phase through defenders.",{0,255,255}},
    {"Mythic Crown","Worn by kings of old.",{255,200,80}},
    {"Divine Halo","Blessed by the football gods.",{255,255,200}},
}

-- ── Item generator ─────────────────────────────────────────────────────────────
-- makeItems: builds the item table for a category using a bonus function.
-- The bonus function receives (tier, t) where t=0..1 and returns stat bonuses.
-- Procedural approach: adding a new category = new defs table + one makeItems call.
local function makeItems(category, defs, bonusFn)
    local items = {}
    for tier, def in ipairs(defs) do
        local t = tf(tier)
        local bonuses = bonusFn(tier, t)
        local item = {
            id          = string.lower(category).."_"..tier,
            category    = category,
            tier        = tier,
            rarity      = RARITIES[tier],
            name        = def[1],
            desc        = def[2],
            price       = PRICES[tier],
            color       = Color3.fromRGB(table.unpack(def[3])),
            powerBonus    = bonuses.power,
            accuracyBonus = bonuses.acc,
            speedBonus    = bonuses.speed,
            cashBonus     = bonuses.cash,
        }
        -- Balls also get goalMult and distMult (used in GameServer kick formula)
        if bonuses.goalMult then item.goalMult = bonuses.goalMult end
        if bonuses.distMult then item.distMult = bonuses.distMult end
        table.insert(items, item)
    end
    return items
end

-- ── Bonus scaling functions ────────────────────────────────────────────────────
-- All bonuses scale linearly from tier 1 (t=0) to tier 26 (t=1).
-- Ball: goalMult (0.35→0.95) and distMult (0.30→1.0) gate scoring capability.
-- Jersey/Cleats/Helmet: focus on speed, accuracy, and cash bonuses.

local ballItems = makeItems("Ball", BALL_DEFS, function(tier, t)
    return {
        goalMult = lerp(0.35, 0.95, t),  -- probability of scoring on a kick
        distMult = lerp(0.30, 1.0,  t),  -- fraction of max distance achievable
        power    = lerp(0,    0.10, t),  -- +0% to +10% kick power
        acc      = lerp(0,    0.02, t),  -- +0% to +2% accuracy boost
        speed    = lerp(0,    0.20, t),  -- +0% to +20% speed (cash multiplier)
        cash     = lerp(0,    1.50, t),  -- +0% to +150% cash per kick
    }
end)

local jerseyItems = makeItems("Jersey", JERSEY_DEFS, function(tier, t)
    return {
        power = lerp(0,    0.05, t),   -- +0% to +5% kick power
        acc   = lerp(0,    0.03, t),   -- +0% to +3% accuracy
        speed = lerp(0,    0.65, t),   -- +0% to +65% speed (cash multiplier)
        cash  = lerp(0,    0.75, t),   -- +0% to +75% cash per kick
    }
end)

local cleatsItems = makeItems("Cleats", CLEATS_DEFS, function(tier, t)
    return {
        power = lerp(0,    0.08, t),   -- +0% to +8% kick power
        acc   = lerp(0,    0.05, t),   -- +0% to +5% accuracy
        speed = lerp(0,    0.50, t),   -- +0% to +50% speed (cash multiplier)
        cash  = lerp(0,    0.60, t),   -- +0% to +60% cash per kick
    }
end)

local helmetItems = makeItems("Helmet", HELMET_DEFS, function(tier, t)
    return {
        power = lerp(0,    0.03, t),   -- +0% to +3% kick power
        acc   = lerp(0,    0.04, t),   -- +0% to +4% accuracy
        speed = lerp(0,    0.30, t),   -- +0% to +30% speed (cash multiplier)
        cash  = lerp(0,    0.40, t),   -- +0% to +40% cash per kick
    }
end)

-- Combine all 4 categories into one flat list (104 items total)
ShopCatalog.Items = {}
for _, list in ipairs({ballItems, jerseyItems, cleatsItems, helmetItems}) do
    for _, item in ipairs(list) do
        table.insert(ShopCatalog.Items, item)
    end
end

-- ShopCatalog.ById: fast O(1) item lookup by ID string (e.g. "ball_14", "jersey_3")
-- Used by GameServer for every kick calculation and every shop transaction.
ShopCatalog.ById = {}
for _, item in ipairs(ShopCatalog.Items) do
    ShopCatalog.ById[item.id] = item
end

-- ShopCatalog.GetCategory(cat): returns all items for one category, sorted by tier.
-- Used by ShopController to render each tab of the shop GUI.
function ShopCatalog.GetCategory(category)
    local result = {}
    for _, item in ipairs(ShopCatalog.Items) do
        if item.category == category then
            table.insert(result, item)
        end
    end
    table.sort(result, function(a,b) return a.tier < b.tier end)
    return result
end

-- Rarity colour map: used by ShopController to colour the rarity banner in the GUI.
-- These colours also appear on item cards and preview panels.
ShopCatalog.RarityColors = {
    Common    = Color3.fromRGB(180, 180, 180),  -- grey
    Uncommon  = Color3.fromRGB(80,  200, 80),   -- green
    Rare      = Color3.fromRGB(60,  120, 255),  -- blue
    Epic      = Color3.fromRGB(160, 50,  255),  -- purple
    Legendary = Color3.fromRGB(255, 165, 0),    -- orange
    Mythic    = Color3.fromRGB(255, 60,  180),  -- pink
    Divine    = Color3.fromRGB(255, 240, 80),   -- gold
}

return ShopCatalog
