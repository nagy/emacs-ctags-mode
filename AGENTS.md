# AGENTS.md — emacs-ctags-mode

## Purpose

`ctags-mode`: Emacs major mode for browsing the JSON output of Universal Ctags.
Presents tags in a collapsible three-level tree (kind, file, entry) derived from
`magit-section-mode`. Emacs 30.1 or newer. License: AGPL-3.0-or-later.

## Layout

| File | Ownership |
|---|---|
| `ctags-mode.el` | The entire mode, single file. |
| `test/ctags-mode-test.el` | ERT suite: unit tests and real-ctags integration tests. |
| `flake.nix` | `melpaBuild` package, patches the `ctags-program` default to the Nix universal-ctags binary, runs the ERT suite in `checks.default` against the installed package. |
| `TAGS.json` | Sample NDJSON output for manual testing. Not committed. |

## Build and test

- `nix flake check` — byte-compile, ERT suite, checkdoc, package-lint.
- `nix build` — the package.
- `nix develop --command emacs -Q --batch -L . -L test -l
  test/ctags-mode-test.el -f ert-run-tests-batch-and-exit` — ERT suite in the
  dev shell, which provides Emacs, magit-section and ctags.
- Single test: the same command with `--eval '(ert-run-tests-batch-and-exit
  "ctags-mode-render-tree")'`.
- Without Nix: `emacs -Q --batch -l magit-section -f batch-byte-compile
  ctags-mode.el`.
- `nix fmt` — nixfmt through treefmt.

For manual testing, generate `TAGS.json` with
`ctags -R --output-format=json -f - > TAGS.json` and open it with `find-file`,
or run `M-x ctags-run` on a source directory.

## Architecture

### Two buffer modes

| Mode | Trigger | Refresh | Bookmarkable |
|---|---|---|---|
| File-backed | `find-file` on `TAGS.json` through `auto-mode-alist`, or `M-x ctags-open` | Re-reads the file | No |
| Directory-backed | `M-x ctags-run` on a directory | Re-runs `ctags -R --output-format=json -f -` | Yes, `C-x r m` |

Both modes produce identical tree output. The distinction matters only for
refresh and bookmarking.

Key buffer-local variables: `ctags--source-dir` resolves relative file paths in
tags, and `ctags--tags-dir` signals a directory-backed buffer for
`ctags-refresh`.

### Parse and render pipeline

1. `ctags--parse-buffer` reads NDJSON through `json-parse-string` and returns a
   list of plists.
2. `ctags--group-by-kind` groups plists by `:kind` into an alist.
3. `ctags--sort-groups` sorts kinds by count or name.
4. `ctags--sort-entries` sorts entries within a kind by name or path.
5. `ctags--refresh-buffer` erases the buffer and inserts the tree.

The tree shape:

```
1346 tags across 23 kinds

Func (348)                       <- ctags-kind section
  src/core/api.go (15)           <- ctags-file section
    AddHandler (core.Core)       <- ctags-entry section
```

### Visiting and bookmarks

`RET` or `SPC` on an entry resolves `:path` against `ctags--source-dir`, opens
the file in another window and navigates to the definition through the ctags
`:pattern` regexp. A directory-backed buffer sets
`bookmark-make-record-function` to `ctags--bookmark-make-record`. The bookmark
stores the directory path and a handler, `ctags--bookmark-handler`, which calls
`ctags-run` to restore the view.

### Customization

`M-x customize-group ctags` holds four variables:

| Variable | Default | Effect |
|---|---|---|
| `ctags-show-child-count` | t | Show `(N)` counts in headings. |
| `ctags-default-kind-sort` | count | Sort top-level kinds by `count` or `name`. |
| `ctags-entry-sort` | name | Sort entries by `name` or `path`. |
| `ctags-program` | `"ctags"` | Path to the Universal Ctags binary. |

## Rules

- Always wrap buffer content in a `(ctags-root)` section.
  `magit-section-mode` installs a post-command-hook that assumes
  `magit-root-section` holds a value. If parsing fails, still create the root
  section with an error message inside.
- Keep `magit-section-inhibit-markers` buffer-local and non-nil in the mode. With
  markers enabled, every insertion relocates the section markers of the whole
  buffer, so rendering turns quadratic on thousands of entries. Plain positions
  suffice for a read-only stats buffer.
- Do not double-parse. `ctags--refresh-buffer` erases the buffer and replaces it
  with the tree, so a second call on the same content parses tree text as NDJSON
  and returns nothing. `ctags-run` calls `ctags-mode` once for a fresh buffer and
  calls `ctags--refresh-buffer` directly for a reused buffer.
- Keep `ctags--check-ctags`. It runs `ctags --output-format=json --version` and
  checks the exit code, so Emacs' `etags` binary produces a clear user-error
  instead of a parse failure.
- Do not drop the `postPatch` substitution in `flake.nix`. It replaces the string
  literal `"ctags"` with the Nix store path to Universal Ctags, so users never
  need to customize `ctags-program`.
- Do not hand-bump `version`. The flake derives `0.1.0-unstable-YYYY-MM-DD` from
  `inputs.self.sourceInfo.lastModifiedDate`.
- `checks.default` loads the installed package, copies `test/` from the store and
  runs the suite against it with ctags on `PATH`. `melpaBuild` leaves the test
  tree out of the installed package, because MELPA file specs never descend into
  subdirectories.

## Conventions

- Name section type symbols `ctags-<level>`: `ctags-root`, `ctags-kind`,
  `ctags-file`, `ctags-entry`.
- Prefix private names with `ctags--`.
- Keep the defcustom group at `ctags`.

## Testing

- Tests live in `test/`, one `<unit>-test.el` per source file, shared helpers in
  `<name>-test-helper.el`.
- The suite has three layers: unit tests over the pure helpers (parsing, key
  normalization, grouping, sorting, pattern conversion), buffer tests over
  rendering, visiting, refresh, revert and bookmarks, and integration tests that
  drive the real Universal Ctags binary against a throwaway tree.
- Buffer tests build fixtures with `json-serialize`, so no sample file is needed.
- Integration tests call `skip-unless` when `ctags-program` sits off `PATH`, so
  the other layers still run without ctags.
- `checks.default` globs `test/*-test.el`, so a new test file needs no flake edit.

## Dependencies

- Emacs 30.1 or newer, for `defvar-keymap`.
- `magit-section` 3.0 or newer, for the section tree.
- Universal Ctags on `PATH`, or a value in `ctags-program`, for `ctags-run`.
