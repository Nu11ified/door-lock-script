-- Door Lock Client Script: Doorgun System

local doorgunActive = false
local doorgunKeyType = nil
local doorStates = {} -- [netId] = {locked=true/false, keyType="LEO_Key"}
local removalMode = false

-- Add chat suggestions on resource start
AddEventHandler('onClientResourceStart', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    TriggerEvent('chat:addSuggestion', '/doorgun leokey', 'Enable doorgun mode for LEO key')
    TriggerEvent('chat:addSuggestion', '/doorgun safdkey', 'Enable doorgun mode for SAFD key')
    TriggerEvent('chat:addSuggestion', '/doorgunremoval', 'Enable doorgun removal mode')
end)

-- Helper: Give player SNS Pistol
local function giveDoorgun()
    local playerPed = PlayerPedId()
    local weaponHash = GetHashKey("WEAPON_SNSPISTOL")
    GiveWeaponToPed(playerPed, weaponHash, 1, false, true)
    SetCurrentPedWeapon(playerPed, weaponHash, true)
end

-- Helper: Draw 3D text
function DrawText3D(x, y, z, text, r, g, b)
    SetTextScale(0.35, 0.35)
    SetTextFont(4)
    SetTextProportional(1)
    SetTextColour(r, g, b, 215)
    SetTextEntry("STRING")
    SetTextCentre(true)
    AddTextComponentString(text)
    SetDrawOrigin(x, y, z + 1.0, 0)
    DrawText(0.0, 0.0)
    ClearDrawOrigin()
end

-- Command registration
for _, keyType in ipairs({"leokey", "safdkey"}) do
    RegisterCommand("doorgun " .. keyType, function()
        doorgunActive = true
        doorgunKeyType = keyType:upper() .. "_Key"
        giveDoorgun()
        TriggerEvent('chat:addMessage', {args = {"Doorgun mode enabled for " .. doorgunKeyType}})
    end, false)
end

RegisterCommand("doorgunremoval", function()
    removalMode = true
    giveDoorgun()
    TriggerEvent('chat:addMessage', {args = {"Doorgun removal mode enabled. Shoot a door to remove its lock."}})
end, false)

-- Raycast and shoot detection
CreateThread(function()
    while true do
        Wait(0)
        if doorgunActive or removalMode then
            if IsPedShooting(PlayerPedId()) then
                local result, entity = GetEntityPlayerIsFreeAimingAt(PlayerId())
                if result and DoesEntityExist(entity) then
                    local netId = NetworkGetNetworkIdFromEntity(entity)
                    if netId and netId ~= 0 then
                        if removalMode then
                            TriggerServerEvent('doorgun:removeDoor', netId)
                            removalMode = false
                        elseif doorgunActive then
                            TriggerServerEvent('doorgun:registerDoor', netId, doorgunKeyType)
                        end
                        Wait(500) -- Prevent spamming
                    end
                end
            end
        end
    end
end)

-- Listen for door state updates
RegisterNetEvent('doorgun:updateDoorState')
AddEventHandler('doorgun:updateDoorState', function(netId, locked, keyType)
    doorStates[netId] = {locked=locked, keyType=keyType}
end)

-- Listen for door removal updates
RegisterNetEvent('doorgun:removeDoorClient')
AddEventHandler('doorgun:removeDoorClient', function(netId)
    doorStates[netId] = nil
end)

-- Draw door state text
CreateThread(function()
    while true do
        Wait(0)
        local playerCoords = GetEntityCoords(PlayerPedId())
        for netId, data in pairs(doorStates) do
            local entity = NetworkGetEntityFromNetworkId(netId)
            if entity and DoesEntityExist(entity) then
                local coords = GetEntityCoords(entity)
                if #(playerCoords - coords) < 20.0 then
                    local text = data.locked and "Locked" or "Unlocked"
                    local r, g, b = data.locked and 200 or 0, data.locked and 0 or 200, 0
                    DrawText3D(coords.x, coords.y, coords.z, text, r, g, b)
                end
            end
        end
    end
end) 