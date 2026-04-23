local output_png = os.getenv("HM_MGBA_OUTPUT_PNG")
assert(output_png and #output_png > 0, "HM_MGBA_OUTPUT_PNG is required")

local stop_frames = tonumber(os.getenv("HM_MGBA_STOP_FRAMES"))
assert(stop_frames and stop_frames > 0, "HM_MGBA_STOP_FRAMES must be a positive integer")

local key_mask = tonumber(os.getenv("HM_MGBA_KEY_MASK") or "0")
if key_mask ~= 0 then
  emu:addKeys(key_mask)
end

for _ = 1, stop_frames do
  emu:runFrame()
end

local image = emu:screenshotToImage()
assert(image, "screenshotToImage() returned nil")
assert(image:save(output_png), "failed to save screenshot")
