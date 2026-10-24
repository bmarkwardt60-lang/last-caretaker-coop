# Prototype plan

## Hook and evidence

The installed Steam build is app `1783560`, depot build ID `25982825`, executable version `5.8.2.0`. UE4SS `v3.0.1 Beta #0` loads through the available script hook. The user's October 24 runtime log confirmed:

- Pawn: `BP_FirstPersonCharacter_New_C` (`/Game/Blueprints/BP_FirstPersonCharacter_New.BP_FirstPersonCharacter_New_C`)
- Mesh component: `CharacterMesh0`
- Skeletal mesh: `/Game/Characters/Mechanical_Light_01_A/SKM_PlayerCharacter.SKM_PlayerCharacter`
- Animation instance: `ABP_Manny_New_C`
- The `SkeletalMesh` reflected property is valid; `SkeletalMeshAsset` is not.
- The pose bridge was not running during capture, so no peer pose had arrived.

UE4SS and the shipped `SplitScreenMod` example expose `UGameplayStatics:CreatePlayer`, which this prototype now uses to create a local presentation-only pawn when the bridge first receives a peer pose. That pawn has input and collision disabled and is moved from the peer transform. This new path has not yet been confirmed in-game.

## First playable slice

- Two players on one LAN, connected by direct IP.
- A small Python bridge carries the game mod's newest transform over UDP and uses local files for IPC.
- Host owns the session and later becomes authoritative for shared world state.
- Each client owns its local caretaker.
- The other caretaker is intended to be presentation-only. The current path disables its input and collision, but inventory and save isolation are not verified.
- The current implementation attempts to create the game's own second player pawn on receipt of a peer pose, then moves it to the peer transform. Runtime behavior is still unconfirmed.
- Movement uses sequenced unreliable pose updates; reliable messages are reserved for join/leave and later interaction events.
- Late join starts with a peer snapshot, then pose updates.

## State policy (initial)

| State | Initial owner | Initial policy |
| --- | --- | --- |
| Player transform | Each player | Send to host; host relays to peer |
| Player animation | Each player | Defer until the puppet mesh and animation graph are confirmed |
| Doors and pickups | Host | Defer until interaction hooks are identified |
| Inventory, building, quests, creatures | Host | Unspecified until the game-specific object model is inspected |
| Saves | Host | No save isolation exists yet; second-player side effects must be checked before using a valuable save |

## Runtime facts still needed

1. Whether the second local pawn can be created and shown without changing the camera or viewport on build `5.8.2.0`.
2. Whether direct transform updates produce stable movement and useful locomotion animation.
3. A safe way to remove the puppet on peer disconnect, map travel, and game shutdown.
4. Whether the second player pawn changes inventory, quests, or save data; add guards before using valuable saves.
5. Which interaction hooks can be synchronized without letting the puppet affect local inventory or saves.

## Prior work found on October 24, 2026

The Co-op Anything directory query had no entry for this game. Web and repository searches found:

- [MrSkelee/TheLastCaretaker_MultiplayerMod](https://github.com/MrSkelee/TheLastCaretaker_MultiplayerMod): its README reports player-position and door-state sync on game `0.8.0.612251`; items are not synced and animations are incomplete. Its source has no stated license, so this project does not copy its code.
- [Gentlemannn/LastCaretaker-Multiplayer](https://github.com/Gentlemannn/LastCaretaker-Multiplayer): an early DLL-injection/P2P experiment; its January 2026 development thread says the work was paused before a playable ghost-player build.
- [Bentlybro/VoyageCoop](https://github.com/Bentlybro/VoyageCoop): MIT-licensed UE4SS/C++ prototype whose README reports live position and rotation sync via a second local player pawn and a native bridge. Its memory offsets target UE 5.7.4. The devlog describes unsuccessful listen-server experiments and an incomplete client-handshake matrix; do not reuse its offsets for this UE 5.8.2.0 install.

These projects are useful prior art, but none has a verified release for the user's current game build.

## Current implementation boundary

The UDP bridge and UE4SS file adapter carry only player transforms. The remote-player pawn code is present but still needs a live two-client run. Doors, items, building, enemies, quests, and saves are not synchronized. The LAN protocol is not encrypted and must not be exposed to the public internet.

No game assets or binaries are included in this project.
