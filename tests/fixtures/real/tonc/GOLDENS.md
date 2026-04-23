# Tonc Golden Provenance

- oracle repository: `https://github.com/mgba-emu/mgba`
- oracle commit: `f8082d31fb3ef6af15226e74229d6a5aaec526c6`
- oracle build command: `scripts/build-mgba-headless.sh`
- required oracle patch: `scripts/patches/mgba-headless-video-buffer.patch`
- capture script: `scripts/mgba_capture_tonc.lua`
- regeneration command: `scripts/regen-tonc-goldens.sh`

## Oracle Notes

- The `0.10.5` Ubuntu release artifact is not used for tonc parity because it does not ship `mgba-headless`.
- The pinned source commit above does include `mgba-headless` plus Lua scripting, but upstream headless capture does not attach a software video buffer by default.
- `scripts/patches/mgba-headless-video-buffer.patch` exists specifically to attach that software video buffer in headless mode so `screenshotToImage()` can return real frame data during scripted capture.
- The patch is therefore part of the oracle contract, not an incidental local tweak.

## Capture Contract

- `sbb_reg`: stop after `60` frames, key mask `0`
- `obj_demo`: stop after `60` frames, key mask `0`
- `key_demo`: stop after `60` frames, key mask `1` (held `A`)

## Golden Hashes

- `sbb_reg.golden.rgba`: size `153600`, SHA-256 `08d15b57faf5802eea234e0065c17f3273ed072c559b48e27db66a574e4f6673`
- `obj_demo.golden.rgba`: size `153600`, SHA-256 `ab1027848c15ae55573e3a85b6bd651371931ee6eba0778ee11422f84e31f79a`
- `key_demo.golden.rgba`: size `153600`, SHA-256 `99138f4eca3379e2a502e3c08733e023e78562c206fbd556e9b7fa5291cd205f`
