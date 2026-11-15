# Inkstream

Web novel library and live reader for KOReader.

Fork of [Mythos](https://github.com/unitreign/Mythos) by unitreign, licensed under GPL-3.

## Features

- Browse and search popular novels by title directly from your device
- Track novels in a library and check for new chapters at a glance
- Chapter selection: select all, deselect, or cherry-pick a custom range
- Flexible export: a single EPUB, one EPUB per chapter, or bundles of N chapters
- Organised output: EPUBs are saved to `Inkstream/Series/Book.epub` with cover art embedded
- Extension system: sources are installable plugins; add new sites without updating Inkstream
- Chapter caching: re-opening a tracked novel is fast; only new chapters are fetched
- Live reading (in progress): a novel appears as a book in your KOReader home folder and new chapters stream in as you read

## Installation

1. Download `inkstream.koplugin.zip` from https://github.com/bitmvk/inkstream/releases
2. Unzip it into KOReader's plugins directory (`koreader/plugins/`)
3. Restart KOReader

## Extensions

Inkstream uses the Mythos extension format. Add an extension repo under Sources -> Add Repo:

- `github.com/bitmvk/mythosext`
- `github.com/unitreign/mythosext`

## License

GPL-3. See [LICENSE](LICENSE).
