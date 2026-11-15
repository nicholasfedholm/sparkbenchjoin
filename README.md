# sparkbenchjoin

Vintage Story 1.22 test/bench helper mod. On a fresh world it lets the player join without the character creation dialog and in Creative mode, so automated benches reach a playing state with terrain loading.

- Server side, on PlayerCreate: sets the player's `createCharacter` moddata to true (the client then skips the dialog) and switches the player to Creative (set `SPARKBENCH_SURVIVAL=1` to keep survival).
- On join: assigns a default character class if none is set.
- Logs `[sparkbenchjoin]` lines to server-main.log.

For test worlds only. Do not add it to a real play save.

## Build

`dotnet build -c Release` with `VINTAGE_STORY` pointing at the game install (falls back to `%APPDATA%\Vintagestory`). Target: net10.0.

## tools/new-world-drive.ps1

Creates a fresh world in a scratch data folder with only this mod loaded, waits for the join line, samples GPU memory (nvidia-smi, GPU-wide, delta vs pre-launch baseline), takes a screenshot, closes the game normally and writes a result json. It refuses to run on the real VintagestoryData folder, refuses if a game process is already running or free RAM is under 16 GB, and only ever closes the process it launched.

```
powershell -ExecutionPolicy Bypass -File tools\new-world-drive.ps1 -Reason MyTest -DataPath <scratch data folder> -ModZip <sparkbenchjoin zip>
```

The scratch data folder needs a clientsettings.json with a valid login session; the script pins its mod paths to the scratch folder only.

License: MIT.
