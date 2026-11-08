# Dustling

A free, open-source native macOS cleaner.

Status: work in progress.

## Build and test

```
swift build
swift test
```

## Command line

`dustling-cli` is a front end for the core engine. Run it with `swift run dustling-cli <command>`.

| Command | What it does |
| --- | --- |
| `doctor` | Full Disk Access status, free and purgeable space, snapshot count, problems (exit 1 if any) |
| `scan` | Categories with size and item count (`couldn't scan` or `at least` when something couldn't be read); `[review]` and `[trash]` mark ones that are not ticked by default; separate totals for what's cleanable by default, review items, admin-only items and the Trash |
| `clean [--include <categoryID>...]` | Moves the default categories (plus any you include, each item listed first) to the Trash |
| `apps` | Numbered list of installed apps with sizes; a symlinked app shows where it points |
| `uninstall <name\|number> [--all]` | Moves an app and its checked leftovers to the Trash; `--all` also moves unchecked ones |
| `startup`, `startup disable\|enable <label>` | Lists login items and background agents, or turns one off or on |
| `history` | Past runs, with a `restorable` marker |
| `restore <run-id-prefix> [--path <p>]` | Lists a run's items (or one path) and puts them back from the Trash |
| `empty-trash` | Lists what's in the Trash, then permanently deletes it |

Every command that changes something asks first (`[y/N]`; anything but `y` or `yes` cancels, prints
`Cancelled.` and exits 0). Without a terminal the answer is no, unless you pass `--yes`. Cleaning and
uninstalling only move items to the Trash, so space is freed when you run `empty-trash`, which is the
only permanent delete. Exit codes: 0 success, 1 usage error or `doctor` problems, 2 when any item
failed or needs admin rights.
