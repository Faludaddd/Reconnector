--[[
    AE Reconnector - Disconnect Detection Hook
    ==========================================
    Detects the official Roblox "Disconnected" popup via
    GuiService.ErrorMessageChanged and writes a signal file
    that the Python bot watches for.

    Install: /storage/emulated/0/delta/Autoexecute/AE_Reconnector.lua
]]

local GuiService = game:GetService("GuiService")
local TeleportService = game:GetService("TeleportService")
local Players = game:GetService("Players")
local LocalPlayer = Players.LocalPlayer

local SIGNAL_FILE = "AE_disconnect_signal.txt"
local lastSignalTime = 0

local function writeSignal(message)
    if type(writefile) ~= "function" then return end
    pcall(function()
        writefile(SIGNAL_FILE, tostring(message) .. "\n" .. tostring(os.time()))
    end)
end

GuiService.ErrorMessageChanged:Connect(function()
    local err = GuiService:GetErrorMessage() or "Unknown error"
    local now = os.time()

    if now - lastSignalTime < 15 then return end
    lastSignalTime = now

    print("[Reconnector] Official disconnect popup detected: " .. tostring(err))
    writeSignal(err)

    task.delay(3, function()
        print("[Reconnector] Attempting TeleportService reconnect...")
        pcall(function()
            TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LocalPlayer)
        end)
    end)
end)

Players.PlayerRemoving:Connect(function(player)
    if player == LocalPlayer then
        print("[Reconnector] LocalPlayer removing")
        writeSignal("PlayerRemoving")
    end
end)

print("[Reconnector] Disconnect hook active. Watching for ErrorMessageChanged.")
