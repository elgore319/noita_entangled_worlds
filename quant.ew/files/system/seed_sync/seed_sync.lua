-- Moves a client onto the host's world seed when they differ, keeping the
-- client's inventory.
--
-- A world seed can only be chosen before the world is generated, so a client
-- that ends up on another seed (usually from pressing "Continue" on an old
-- save, or because the host continued a save whose seed differs from the
-- proxy's) cannot be fixed in place. Instead the client:
--   0. the player is shown a "Multiplayer Continue" prompt; nothing happens
--      until they press it,
--   1. writes its wands, items, spells, perks, gold and max HP to a carryover
--      file together with the host's seed,
--   2. ends its own run (only locally; the host's run is unaffected),
--   3. on the next "New Game" (an on-screen note explains this during the
--      game-over screen), the seed from the carryover file is applied in
--      OnModPreInit, before world generation, and
--   4. once the new player has spawned on the host's seed, the carryover is
--      restored and the file is deleted.

local bitser = dofile_once("mods/quant.ew/files/lib/bitser.lua")
local perk_fns = dofile_once("mods/quant.ew/files/core/perk_fns.lua")

local module = {}

local CARRYOVER_PATH = "mods/quant.ew/ew_seed_carryover.bin"
-- A carryover older than this is from a different session and is dropped.
local CARRYOVER_MAX_AGE_SECONDS = 60 * 60
-- Frames to wait after spawning before restoring, so the starting inventory
-- is set up first and then replaced.
local RESTORE_DELAY_FRAMES = 20

local migrating = false
-- The host's seed, while it differs from ours and the player hasn't switched.
local pending_host_seed = nil
local prompt_minimized = false
local gui = GuiCreate()
local pending_restore = nil
local restore_frame = nil

local function read_carryover()
    local file = io.open(CARRYOVER_PATH, "rb")
    if file == nil then
        return nil
    end
    local data = file:read("*a")
    file:close()
    if data == nil or data == "" then
        return nil
    end
    local ok, carry = pcall(bitser.loads, data)
    if not ok or type(carry) ~= "table" or carry.seed == nil then
        print("Seed sync: ignoring unreadable carryover file")
        return nil
    end
    return carry
end

local function write_carryover(carry)
    local file, err = io.open(CARRYOVER_PATH, "wb")
    if file == nil then
        print("Seed sync: could not write carryover: " .. tostring(err))
        return false
    end
    file:write(bitser.dumps(carry))
    file:close()
    return true
end

local function delete_carryover()
    os.remove(CARRYOVER_PATH)
end

local function carryover_is_current(carry)
    if carry.saved_at == nil or os.time() - carry.saved_at > CARRYOVER_MAX_AGE_SECONDS then
        return false
    end
    -- Only carry items over into the same lobby.
    if carry.host_id ~= nil and ctx.host_id ~= nil and ctx.host_id ~= 0 and carry.host_id ~= ctx.host_id then
        return false
    end
    return true
end

-- Called from OnModPreInit right after the proxy handshake, which is the last
-- point where the world seed can still be changed.
function module.apply_pending_seed()
    local carry = read_carryover()
    if carry == nil then
        return
    end
    if not carryover_is_current(carry) then
        print("Seed sync: dropping stale carryover")
        delete_carryover()
        return
    end
    local seed = tonumber(carry.seed)
    if seed ~= nil then
        print("Seed sync: using host seed " .. tostring(seed) .. " from carryover")
        SetWorldSeed(seed)
        SetRandomSeed(seed, 141)
    end
end

local function collect_carryover(host_seed)
    local player = ctx.my_player
    local items, spells = player_fns.serialize_items(player)
    local carry = {
        seed = host_seed,
        host_id = ctx.host_id,
        saved_at = os.time(),
        items = items,
        spells = spells,
        perks = perk_fns.get_my_perks(),
    }
    local wallet = EntityGetFirstComponentIncludingDisabled(player.entity, "WalletComponent")
    if wallet ~= nil then
        carry.money = ComponentGetValue2(wallet, "money")
    end
    if ctx.proxy_opt.game_mode ~= "shared_health" then
        local damage = EntityGetFirstComponentIncludingDisabled(player.entity, "DamageModelComponent")
        if damage ~= nil then
            carry.hp = ComponentGetValue2(damage, "hp")
            carry.max_hp = ComponentGetValue2(damage, "max_hp")
        end
    end
    return carry
end

-- Saves the carryover and ends this client's run. Returns false and a reason
-- for the player if that can't be done right now.
local function move_to_host_seed(host_seed)
    if migrating then
        return true
    end
    if ctx.is_host or ctx.run_ended or ctx.my_player == nil then
        return false, "Not available right now."
    end
    if EntityHasTag(ctx.my_player.entity, "polymorphed") or GameHasFlagRun("ew_flag_notplayer_active") then
        -- Inventory can't be read reliably while polymorphed or dead.
        return false, "Get back into your own body first, then try again."
    end

    local ok, carry = pcall(collect_carryover, host_seed)
    if not ok or not write_carryover(carry) then
        print("Seed sync: could not save carryover: " .. tostring(carry))
        return false, "Couldn't save your items, so nothing was changed."
    end

    migrating = true
    GamePrint("Your items are saved. Press New Game to continue in the host's world.")
    print("Seed sync: saved carryover, ending local run to switch to seed " .. tostring(host_seed))
    -- Same path as a proxy-requested end of run: only this client's run ends.
    net.net_handling.proxy.end_run()
    return true
end

-- Called on a client when the host reports a different world seed. Nothing
-- happens until the player presses "Multiplayer Continue".
function module.on_host_seed_differs(host_seed)
    if migrating or ctx.is_host then
        return
    end
    if pending_host_seed == nil then
        GamePrint("You're in a different world than the host. Use Multiplayer Continue to join theirs.")
    end
    pending_host_seed = host_seed
end

-- The host now reports our seed (e.g. both started a new run), so the
-- prompt no longer applies.
function module.on_host_seed_matches()
    pending_host_seed = nil
    prompt_minimized = false
end

local function draw_centered_text(y, text)
    local w = GuiGetScreenDimensions(gui)
    local tw = GuiGetTextDimensions(gui, text)
    GuiText(gui, (w - tw) / 2, y, text)
end

local function draw_centered_button(id, y, text)
    local w = GuiGetScreenDimensions(gui)
    local tw = GuiGetTextDimensions(gui, text)
    return GuiButton(gui, id, (w - tw) / 2, y, text)
end

-- The prompt shown while this client is in a different world than the host.
local function draw_prompt()
    GuiStartFrame(gui)
    GuiZSet(gui, -100)
    local _, h = GuiGetScreenDimensions(gui)
    if prompt_minimized then
        local text = "[Multiplayer Continue]"
        local tw, th = GuiGetTextDimensions(gui, text)
        local w = GuiGetScreenDimensions(gui)
        if GuiButton(gui, 2, w - tw - 4, h - th - 14, text) then
            prompt_minimized = false
        end
        return
    end
    local y = h * 0.3
    draw_centered_text(y, "You're in a different world than the host.")
    draw_centered_text(y + 12, "Multiplayer Continue moves you into the host's world.")
    draw_centered_text(y + 24, "You keep your wands, items, spells, perks and gold.")
    if draw_centered_button(1, y + 44, "[ Multiplayer Continue ]") then
        local ok, reason = move_to_host_seed(pending_host_seed)
        if ok then
            pending_host_seed = nil
        elseif reason ~= nil then
            GamePrint(reason)
        end
    end
    if draw_centered_button(3, y + 60, "[ Not now ]") then
        prompt_minimized = true
    end
end

-- Shown after the run has ended for the switch, while Noita shows its own
-- game-over screen.
function module.draw_after_run_end()
    if not migrating then
        return
    end
    GuiStartFrame(gui)
    GuiZSet(gui, -100)
    local _, h = GuiGetScreenDimensions(gui)
    local y = h * 0.15
    draw_centered_text(y, "Your items are saved. This isn't a real game over.")
    draw_centered_text(y + 12, "Press New Game to continue in the host's world with everything you had.")
end

local function restore_carryover(carry)
    local player = ctx.my_player
    if carry.items ~= nil or carry.spells ~= nil then
        inventory_helper.set_item_data({ carry.items or {}, carry.spells or {} }, player, true, true)
    end
    if carry.perks ~= nil then
        perk_fns.give_perks_to_local_player(carry.perks)
    end
    if carry.money ~= nil then
        local wallet = EntityGetFirstComponentIncludingDisabled(player.entity, "WalletComponent")
        if wallet ~= nil then
            ComponentSetValue2(wallet, "money", carry.money)
        end
    end
    if carry.max_hp ~= nil and ctx.proxy_opt.game_mode ~= "shared_health" then
        local damage = EntityGetFirstComponentIncludingDisabled(player.entity, "DamageModelComponent")
        if damage ~= nil then
            ComponentSetValue2(damage, "max_hp", carry.max_hp)
            ComponentSetValue2(damage, "hp", math.min(carry.hp or carry.max_hp, carry.max_hp))
        end
    end
    ctx.events.inventory_maybe_just_changed = true
end

function module.on_local_player_spawn()
    if ctx.is_host then
        return
    end
    local carry = read_carryover()
    if carry == nil then
        return
    end
    if not carryover_is_current(carry) then
        delete_carryover()
        return
    end
    if tostring(StatsGetValue("world_seed")) ~= tostring(carry.seed) then
        -- Still not on the host's seed (e.g. "Continue" was pressed). Keep the
        -- carryover; the next host seed report will end this run again.
        return
    end
    pending_restore = carry
    restore_frame = GameGetFrameNum() + RESTORE_DELAY_FRAMES
end

function module.on_world_update()
    if pending_host_seed ~= nil and not migrating then
        draw_prompt()
    end
    if pending_restore == nil or GameGetFrameNum() < restore_frame then
        return
    end
    local carry = pending_restore
    pending_restore = nil
    -- Delete first so a failed restore can never loop.
    delete_carryover()
    local ok, err = pcall(restore_carryover, carry)
    if ok then
        GamePrint("Now on the host's seed. Your items were restored.")
    else
        print("Seed sync: restore failed: " .. tostring(err))
        GamePrint("Now on the host's seed, but restoring your items failed.")
    end
end

return module
