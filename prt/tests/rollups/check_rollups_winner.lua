local input_file = "dave.log"
local MAX_EPOCH = tonumber(os.getenv("MAX_EPOCH")) or false -- number of epochs to check winner

local joined_commitments = {}                               -- Table to store joined commitments
local winner_commitments = {}                               -- Table to store winner commitments
local joined_count = 0
local winner_count = 0

-- Open the file for reading
local file = io.open(input_file, "r")
if not file then
    print("Could not open file: " .. input_file)
    return
end

print("Checking result of tournaments...")

-- Read from the file
for line in file:lines() do
    -- Pattern to match the commitments that join level 0 tournament
    local commitment_join = line:match("join tournament .- level 0 with commitment (0x%x+)")

    -- Pattern to match the winner commitments
    local commitment_winner = line:match("settle epoch %d+ with claim (0x%x+)")

    if commitment_join and not joined_commitments[commitment_join] and joined_count < MAX_EPOCH then
        joined_commitments[commitment_join] = true
        print(string.format("Root commitment joined: %s", commitment_join))
        joined_count = joined_count + 1
    end

    if commitment_winner and not winner_commitments[commitment_winner] and winner_count < MAX_EPOCH then
        winner_commitments[commitment_winner] = true
        print(string.format("Winner commitment: %s", commitment_winner))
        winner_count = winner_count + 1
    end

    -- Break if we have reached the maximum for both
    if joined_count >= MAX_EPOCH and winner_count >= MAX_EPOCH then
        break
    end
end

-- Close the file
file:close()

-- Check if all joined commitments are also winner commitments
local all_joined_are_winners = true
for commitment in pairs(joined_commitments) do
    if not winner_commitments[commitment] then
        all_joined_are_winners = false
        print(string.format("Commitment didn't win: %s", commitment))
    end
end

if all_joined_are_winners then
    print("Dave won all tournaments.")
else
    error("Dave didn't win all tournaments.")
end
