# Release readiness

## Current release state

The installer and updater are being prepared for wider Windows PC use, but the mod is still an experimental prototype. It relays player transforms only; the remote pawn, gameplay side effects, saves, and a two-PC session on the current game build remain unverified. Do not describe it as finished co-op or as supporting every device.

The supported target for the current package is Windows 10/11 x64, the Steam version of The Last Caretaker, Windows PowerShell 5.1+, Python 3.10+, and the separate UE4SS TLC UE5 8 v1.3 package. Linux/Steam Deck/Proton, macOS, consoles, and non-Steam copies are outside the current support target.

## Before publishing a public release

1. Confirm the game build and UE4SS package version in the release notes.
2. Install from a clean project folder on two Windows PCs with the game in different Steam library layouts. Confirm manual path selection also works.
3. Start a host and a joiner over LAN, then over a private VPN. Confirm invite parsing, firewall guidance, peer visibility, disconnect handling, and that saves and local input remain safe.
4. Repeat the install/update flow from the previous published tag, including one interrupted or failed update, and confirm the old files remain usable.
5. Update `VERSION` to exactly match the tag, review the README support table and release notes, then commit, push the tag, and publish a GitHub Release for it.

Until those game-client checks pass, publish only as an explicitly labeled experimental build. A passing installer or updater check alone does not prove co-op gameplay works.

## Package contents

The public source archive contains the launcher, installer, updater, UE4SS Lua mod, and Python bridge. It does not include the UE4SS package or game files. Each player obtains the UE4SS TLC package from its [Nexus Mods page](https://www.nexusmods.com/thelastcaretaker/mods/4?tab=files). Never put Steam credentials, personal invite codes, save files, or game binaries in the public repository or release archive.

## Player support details

Ask players to include their Windows version, game build, UE4SS package version, whether they hosted or joined, and relevant `[LastCaretakerCoop]` lines from `ue4ss\UE4SS.log`. Bridge logs are under `%LOCALAPPDATA%\LastCaretakerCoop\`. Invite codes contain the session token and should be shared only with the other player.
