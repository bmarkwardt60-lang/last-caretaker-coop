# Development and troubleshooting

## Platform boundary

The current installer, launcher, and UE4SS payload support Windows x64 PCs running the Steam game. The launcher requires Windows PowerShell 5.1+ and Python 3.10+; the UE4SS TLC package is obtained separately. Steam Deck/Proton, native Linux, macOS, consoles, and non-Steam copies are not supported by this build. Supporting those would need a different loader and install flow, not just a different network adapter setting.

Steam detection reads registered Steam locations and `libraryfolders.vdf`, then checks the Steam app manifest for app `1783560`. If none of those paths resolves, the installer asks for the game folder so the user can select a nonstandard library location.

## Normal play flow

Run `Start-Coop.cmd` on both PCs with The Last Caretaker closed. The bootstrap checks the public GitHub repository for its latest published release tag and updates the project files before launching the guided setup. The setup installs the UE4SS mod, guides each player through Host or Join, starts the bridge, and launches the game through Steam. Keep the launcher window open until the game closes; it owns the bridge process. When hosting, choose the address for the LAN or private VPN shared with the other player; private and common VPN IPv4 ranges are listed first.

On the first setup, the installer needs the manual **UE4SS TLC UE5 8 v1.3** package. It searches the project folder and Downloads for a matching package, then asks for its ZIP or extracted-folder path if it cannot find one. The package is available from [Nexus Mods](https://www.nexusmods.com/thelastcaretaker/mods/4?tab=files). Each PC must also have Python 3.10 or newer; the launcher can offer a per-user Python 3.12 install through `winget`.

The host's invite code includes the LAN address, UDP port, session, and generated token. Send it privately to the joining player. If Windows Firewall asks, allow Python on the network profile used by the trusted LAN or private VPN. If the joiner cannot connect, check that both PCs are on the same LAN/private VPN and that inbound UDP `28770` is allowed on the host's active network profile. Do not expose this prototype bridge to the public internet.

## Publish an update

The launcher reads the latest published GitHub Release and installs its source archive when the `VERSION` tag differs from the installed tag. Set `VERSION` to the exact tag before creating the tagged commit. The updater checks that version match and required files before copying; failed copies roll back the files already replaced. Tags without a published release are ignored. Updates are downloaded over HTTPS from the public repository; no GitHub credential is stored on player PCs. Follow [release-readiness.md](release-readiness.md) before publishing.

## Manual developer flow

To run the bridge without the launcher, start a host:

```powershell
python bridge/coop_bridge.py host --name Host --session tlc-coop --token <shared-token>
```

Then start the joining player:

```powershell
python bridge/coop_bridge.py join --host <host-lan-ip> --name Friend --session tlc-coop --token <shared-token>
```

The session name and token must match. The default UDP port is `28770`.

## In-game diagnostics

Use a disposable test save on both PCs. **F8** logs the local pawn details. **F9** logs the latest peer pose. The UE4SS output is at:

```text
<game Win64 folder>\ue4ss\UE4SS.log
```

When a peer pose arrives, the mod attempts to create a presentation-only player pawn and apply its transform. If the peer does not appear, collect `[LastCaretakerCoop]` lines about `Receiving peer pose`, `Created a local presentation-only player controller`, `Remote player pawn ready`, `Could not create`, or `Could not move`, plus nearby UE4SS errors. The bridge stdout and stderr are in `%LOCALAPPDATA%\LastCaretakerCoop\bridge-output.log` and `bridge-errors.log`.

Do not share a full save file. This prototype only needs class, transform, and relevant error details. Shared inventory, construction, quests, creatures, and save state are not implemented.
