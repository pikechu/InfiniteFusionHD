# InfiniteFusionHD

[简体中文](README.md) | [English](README.en.md)

**A community fork inherited from KIF FORK, focused on enhanced visuals and cross-platform online play.**

InfiniteFusionHD builds on **KIF FORK (Kuray Infinite Fusion)**, preserving its Pokémon fusion gameplay, shiny color system, Mod support, and quality-of-life features while developing **HD visual enhancements, online multiplayer, Windows / Android support, and Simplified Chinese localization**. Inherited features remain credited to their upstream contributors; this fork's additions and their current status are described below.

[Repository](https://github.com/pikechu/InfiniteFusionHD) · [Releases](https://github.com/pikechu/InfiniteFusionHD/releases) · [Report an issue](https://github.com/pikechu/InfiniteFusionHD/issues)

**Development status (2026-10-27):** Accounts, cloud saves, the online world, and the casual multiplayer features below are available in main. HD texture work, further map and loading fixes, the trading center, and the operations dashboard remain in the development working tree and have not been merged into main. Check each release's notes for the features and assets actually included.

## HD visuals: a more detailed fusion world

- **Battle background enhancements (in development):** Four batches totaling **86 assets** have been applied in the development working tree: all **70 standalone battle backgrounds** and **16 player / opponent platforms**, covering outdoor day and night scenes, cities, caves, Gyms, and special locations.
- **Original composition and compatibility:** AI-assisted texture and detail work preserves filenames, dimensions, alpha channels, scene layouts, and platform placement.
- **Rendering and movement fixes (in development):** Improvements address clothing, hair, and hat layering and tracking, grass rendering, movement sprite caching, and resource cleanup.
- **Work continues in batches:** HD describes this fork's visual enhancement direction. Assets retain their original dimensions and the game retains its base rendering resolution. Tilesets, UI, characters, animations, and other assets still need further work.

These texture and rendering changes are currently applied in the development working tree and have not been released with main or a client package. They do not imply that every asset has been redrawn or that the display resolution has increased.

## Online play: share the adventure

| Feature | Additions in this fork |
| --- | --- |
| Accounts and cloud saves | Registration, login, cloud saving, cross-device restoration, and an online / offline choice at startup |
| Online world | See other players on main-story maps; use map and world chat |
| Friend battles | Two-player rooms, team selection, ready checks, singles battles, and rematches |
| Co-op and challenges | Co-op Boss battles, asynchronous player AI Gyms, random rental cups, and fixed-route co-op dungeons |
| Pokémon exchange | Casual friend trades, online Wonder Trade pools, and server-managed collections |
| Social features and replays | Trainer cards, six-slot showcases, Pokémon displays, and battle replay sharing with both participants' consent |
| Deployable server | Coordination service, production deployment materials, and backup / recovery tools |

**Extensions in development:** The trading center supports controlled online characters trading Pokémon, items, and GOLD, with listings, purchases, pending deliveries, and transaction history. The operations dashboard adds auditing, statistics, and controlled-character save rollback. These implementations have not yet been merged into main.

Casual online play and the controlled-character system in development have separate rules and asset boundaries. Historical local saves are not directly imported into the controlled online economy. Cloud synchronization does not certify the origin of local assets.

Windows and Android emulator integration checks and feature-specific validation records are available. Public deployment, physical-phone experience, natural completion of every map, and production capacity still require separate acceptance. Online play requires a reachable, compatible server; the default domain in the source does not mean a public service is open.

Documentation, currently primarily in Chinese: [Multiplayer setup](docs/multiplayer-setup.zh-CN.md) · [Accounts, cloud saves, and the online world](docs/multiplayer-online-world.zh-CN.md) · [Casual trade fields and recovery](docs/multiplayer-trade-fields.zh-CN.md) · [Server](server/multiplayer/README.zh-CN.md) · [Deployment](server/multiplayer/deploy/README.md)

## Other additions

- **Windows / Android support:** Windows packaging and a standalone Android app, including touch controls, keyboard input, aspect-ratio settings, save import / export, and optional HTTPS networking.
- **Simplified Chinese localization:** Switchable languages, Chinese fonts, story and common UI translations, Chinese fusion names, and Pokédex text, with community translation credits preserved. See the [localization notes](docs/localization.zh-CN.md) for coverage and remaining work.
- **Pokédex and asset loading:** Upstream Pokédex additions, sprite sheet support, and download-failure handling improve startup when optional online resources are unavailable. See [Pokédex updates](docs/pokedex-merge.zh-CN.md) and [sprite sheets](docs/spritesheets.zh-CN.md).
- **Loading and stability (in development):** Further improvements to Android first-run asset installation, map loading, character animation caching, and local rendering are being developed and have not yet been merged into main.

## Features inherited from KIF FORK

The following capabilities come from KIF and its community and continue to be maintained here:

- Pokémon fusion, custom sprites, and fusion icons.
- Multiple shiny color modes, custom shiny colors, and shiny caching.
- Community extensions loaded from the `Mods` folder.
- DemICE's enhanced AI, endgame challenge, and self-battles.
- Fast-forward, auto-battle, multiple save slots and backups, quicksave, and configurable experience / level limits.
- Pokémon import / export, PC sorting and multiselect, and individual custom sprites.

The full upstream feature list and original contributor credits are preserved in the [KIF upstream README](docs/upstream-KIF-README.md).

## Download and run

1. Download a complete client for your platform from [InfiniteFusionHD Releases](https://github.com/pikechu/InfiniteFusionHD/releases). If no suitable package is available, follow the [client packaging instructions](docs/client-packaging.zh-CN.md).
2. On Windows, extract the complete client into a writable directory and run `Game.exe`. A source ZIP is not guaranteed to include local development assets or a complete runnable release.
3. On Android, install the phone APK; emulator-specific builds are only for emulator testing. Allow the first launch to finish verifying and installing assets.
4. Choose offline mode for single-player play, or configure a compatible server address in the game for online play.

Install this project separately rather than over an existing PIF / KIF game directory. The rename preserves existing save locations, the Android package ID `org.kuray.kif`, native interfaces, and service configuration identifiers to support existing saves and same-signature app upgrades. Uninstalling Android deletes private saves, so export them before migrating.

Development resources: [Windows / Android packaging](docs/client-packaging.zh-CN.md) · [Android project](docs/android/README.md) · [Multiplayer progress](docs/multiplayer-progress.zh-CN.md)

## Origins and credits

Project lineage: **Pokémon Essentials → Pokémon Infinite Fusion (PIF) → Kuray Infinite Fusion (KIF FORK) → InfiniteFusionHD**.

- **KIF FORK / Kuray Infinite Fusion:** Created by Kurayami Blackheart (Reïzod) and the KurayHub community. Thanks to DemICE, Sylvi, Hungry Pickle, bluewuppo, Trapstarr, and all other code, art, and testing contributors. [Upstream repository](https://github.com/kurayamiblackheart/kurayshinyrevamp) · [Upstream website](https://www.kurayinfinitefusion.com/)
- **Pokémon Infinite Fusion:** Created by Chardub / Frogman and its community. [PIF repository](https://github.com/infinitefusion/infinitefusion-e18)
- **Pokémon Essentials:** Thanks to Maruno and all engine contributors. [Essentials repository](https://github.com/Maruno17/pokemon-essentials)
- **Community art and translation:** Original sprite, music, tileset, and translation credits remain in `PIF_Credits.txt`, the in-game credits, and `Data/localization/source-notice.zh-CN.txt`.

InfiniteFusionHD is a community derivative built on these projects. Renaming the project does not change ownership or attribution of upstream work, assets, or community contributions. KIF's website and community links are provided as upstream references.
