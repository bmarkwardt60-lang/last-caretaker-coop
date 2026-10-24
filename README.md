# The Last Caretaker Co-op

An independent two-player LAN prototype for the Steam build of The Last Caretaker.

> **Status: experimental prototype.** This is not yet a finished co-op release: only player poses are relayed, and the remote player puppet and a two-PC session have not been verified on the current game build.

## Supported PCs

| Component | Current support |
| --- | --- |
| Operating system | Windows 10/11, 64-bit, Steam version of the game |
| Mod loader | UE4SS TLC UE5 8 v1.3 package; Windows x64 only |
| Launcher | Windows PowerShell 5.1 or newer |
| LAN bridge | Python 3.10 or newer; the launcher can offer a per-user Python 3.12 install through `winget` |
| Network | Two PCs on the same LAN or a private VPN; direct IPv4 over UDP port `28770` |
| Other operating systems/devices | Linux, Steam Deck/Proton, macOS, consoles, and non-Steam game copies are unsupported and untested |

The installer discovers Steam through the Windows registry, Steam's library list, and the game's Steam app manifest. If automatic detection fails, it asks for the game folder. This supports different Windows PCs and Steam library drives; it does not make the current Windows UE4SS loader portable to every operating system or architecture.

## Start a session

Both players need their own game installation and a copy of this project folder. Double-click **Start-Coop.cmd** on both PCs. Before setup, it checks the public GitHub repository for the latest published release tag and downloads that version automatically when needed.

1. The launcher checks for Python 3.10 or newer. If it is missing and `winget` is available, it offers to install Python 3.12 for your Windows account.
2. It installs or updates the UE4SS mod files. On the first setup, it may ask for the UE4SS TLC UE5 8 v1.3 ZIP or extracted folder. Get the manual package from [Nexus Mods](https://www.nexusmods.com/thelastcaretaker/mods/4?tab=files).
3. Choose **Host** on one PC and **Join** on the other.
4. The host sends the copied invite code to the joining player. The joining player pastes it into their launcher.
5. The launcher starts the LAN bridge and launches the game through Steam. It stops the bridge when the game closes.

If Windows Firewall asks, allow Python on the network profile used by your trusted LAN or private VPN. The host and joining player need to be on the same LAN or an equivalent private VPN. The bridge uses UDP port `28770` and is not intended for the public internet. The invite code contains the session token; share it only with your co-op partner.

The Git repository excludes UE4SS package binaries. Each PC needs to obtain the manual package separately on first install.

To publish an update, set `VERSION` to the exact semantic version tag, commit the changes, push the tag (for example `v0.1.2`), and publish a GitHub Release for that tag. The launcher checks that the archive's `VERSION` matches its release tag, validates required files, and restores replaced files if an update copy fails. If restoration itself fails, it keeps recovery copies in the temporary update folder and prints the path. The launcher updates from the latest published release; a tag that has not been published as a release is not installed. The updater does not need a GitHub login on player PCs. See [release readiness](docs/release-readiness.md) before publishing.

Use a disposable test save on both PCs. The prototype is still being developed: it relays player poses and attempts to create a presentation-only second player, but shared inventory, construction, quests, creatures, and save state are not synchronized. A visible second player and stable play have not yet been confirmed on two clients.

Bridge logs are saved under `%LOCALAPPDATA%\LastCaretakerCoop\`. The host's latest invite is saved there as `last-invite.txt`.

## Target build

- Steam app: `1783560`
- Development machine's Steam build: `25982825`
- Executable: `Voyage/Voyage/Binaries/Win64/VoyageSteam-Win64-Shipping.exe`
- Engine version resource: Unreal Engine `5.8.2`
- Development machine's executable SHA-256: `08228b72d4590f9b00e2171f252d618464c2e04b785237fe728dddbf27d3b734`

The mod loader and local pawn/mesh details have been observed in-game on the development machine. The current code targets this build, but has not yet been validated as a playable two-PC co-op session. Other game builds may require new UE4SS compatibility work.

## Current prototype

The UE4SS mod writes the local caretaker transform to a small file. `bridge/coop_bridge.py` relays pose packets between two PCs and writes the remote transform back. **F8** logs local pawn details; **F9** logs the latest peer transform. When it receives a peer pose, the mod attempts to create and move a presentation-only player pawn. Treat this as experimental and use disposable saves.

## Layout

- `Start-Coop.cmd` — double-click entry point for the guided flow.
- `Update-Coop.ps1` — fetches the latest public GitHub release archive by tag before launching the game.
- `Start-Coop.ps1` — checks Python, installs/updates the mod, handles Host/Join, starts the bridge, and launches Steam.
- `VERSION` — current installed release tag.
- `Install-Coop.ps1` — lower-level installer used by the launcher.
- `Mods/LastCaretakerCoop/scripts/main.lua` — in-game UE4SS probe and remote-pawn prototype.
- `bridge/coop_bridge.py` — direct-IP two-player LAN pose relay.
- `docs/plan.md` — architecture and state policy.
- `docs/development.md` — manual setup and troubleshooting notes.
- `docs/release-readiness.md` — platform scope and gates before publishing a release.

## Prior art checked

- [MrSkelee's public prototype](https://github.com/MrSkelee/TheLastCaretaker_MultiplayerMod) reports movement and door-state sync on an older game build.
- [Voyage community project](https://www.reddit.com/r/TheLastCaretaker/comments/1wtre4g/i_made_a_coop_mod_for_the_last_caretaker_you_can/) has author-reported multiplayer features and known unsolved areas. Those claims have not been tested by this project.
- [CaretakerMP](https://caretakermp.com/) describes a separate multiplayer toolkit; this project has not verified its downloadable build or source.

This prototype remains standalone. It does not copy code, assets, or binaries from those projects.
