# AGENTS.md

## Project overview

`ctags-mode` is an Emacs major mode for browsing the JSON output of
[Universal Ctags](https://ctags.io/).  It presents tags in a
collapsible 3-level tree (kind → file → entry), derived from
`magit-section-mode`.

## Files

| File | Purpose |
|---|---|
| `ctags-mode.el` | The entire mode (single file, ~450 lines) |
| `default.nix` | Nix build with `melpaBuild`, patches the `ctags-program` default to the Nix-provided universal-ctags binary |
| `TAGS.json` | Sample NDJSON output for testing (not committed) |

## Dependencies

- Emacs ≥ 29.1 (uses `defvar-keymap`)
- `magit-section` (≥ 3.0) — provides the section tree and collapsible UI
- Universal Ctags on PATH (or set `ctags-program`) — for `ctags-run`

## Architecture

### Two buffer modes

| Mode | Trigger | Refresh | Bookmarkable |
|---|---|---|---|
| **File-backed** | `find-file` on `TAGS.json` (auto-mode-alist) or `M-x ctags-open` | Re-reads the file | No |
| **Directory-backed** | `M-x ctags-run` on a directory | Re-runs `ctags -R --output-format=json -f -` | Yes (`C-x r m`) |

Both produce identical tree output.  The distinction matters only for
refresh and bookmarking.

### Key buffer-local variables

- `ctags--source-dir` — directory for resolving relative file paths in tags
- `ctags--tags-dir` — non-nil signals a directory-backed buffer; used by `ctags-refresh`

### Parse → render pipeline

1. **`ctags--parse-buffer`** — reads NDJSON (one JSON object per line)
   from the buffer via `json-parse-string`, returns a list of plists.
2. **`ctags--group-by-kind`** — groups plists by `:kind` into an alist.
3. **`ctags--sort-groups`** — sorts kinds by count or name.
4. **`ctags--sort-entries`** — sorts entries within a kind by name or path.
5. **`ctags--refresh-buffer`** — erases the buffer, inserts the tree.
   Always wraps content in `magit-insert-section (ctags-root)` to keep
   `magit-root-section` non-nil (prevents post-command-hook crashes).

### Tree structure

```
1346 tags across 23 kinds

Func (348)                       ← ctags-kind section
  src/core/api.go (15)           ← ctags-file section
    AddHandler (core.Core)       ← ctags-entry section
    AddPeer (core.Core)
    ...
  src/core/link_ws.go (8)
    Accept (core.linkWSListener)
    ...
Struct (102)
  ...
```

Each section type is a symbol used in `magit-insert-section`:
`ctags-root`, `ctags-kind`, `ctags-file`, `ctags-entry`.

### Visiting entries

`RET` / `SPC` on an entry resolves the `:path` relative to
`ctags--source-dir`, opens the file in another window, and navigates
to the definition using the ctags `:pattern` regexp.

### Bookmarking

Directory-backed buffers set `bookmark-make-record-function` to
`ctags--bookmark-make-record`.  The bookmark stores the directory path
and a handler (`ctags--bookmark-handler`) that calls `ctags-run` to
restore the view.

## Customization (`M-x customize-group ctags`)

| Variable | Default | Description |
|---|---|---|
| `ctags-show-child-count` | t | Show `(N)` count in headings |
| `ctags-default-kind-sort` | count | Sort top-level kinds by `count` or `name` |
| `ctags-entry-sort` | name | Sort entries by `name` or `path` |
| `ctags-program` | `"ctags"` | Path to Universal Ctags binary |

## Building

```bash
# Nix (local)
nix-build -E "with import <nixpkgs> {}; (emacs.pkgs.callPackage ./. {})"

# Without Nix
emacs -Q --batch -l magit-section -f batch-byte-compile ctags-mode.el
```

## Testing

The sample `TAGS.json` is a 275 KB NDJSON file with 1346 tags across
23 kinds, generated from the Yggdrasil Go project.  Open it with
`find-file` to test the file-backed path, or (if Universal Ctags is
available) use `M-x ctags-run` on any source directory.

```bash
# Batch smoke test (file-backed)
emacs -Q --batch -l magit-section -l ctags-mode.el \
  --eval '(progn (find-file "./TAGS.json")
                 (princ (format "%d kinds\n"
                   (length (oref magit-root-section children)))))'

# Batch smoke test (dir-backed, needs universal-ctags)
emacs -Q --batch -l magit-section -l ctags-mode.el \
  --eval '(progn (ctags-run "/path/to/source")
                 (princ (format "%d kinds\n"
                   (length (oref magit-root-section children)))))'
```

## Important patterns

- **Always wrap buffer content in a root section.**  `magit-section-mode`
  installs a post-command-hook that assumes `magit-root-section` is
  non-nil.  If parsing fails, still create a `(ctags-root)` section
  with an error message inside it.

- **Inhibit magit-section markers in the mode.**  `ctags-mode` sets
  `magit-section-inhibit-markers` buffer-locally.  With markers enabled
  (the default) every insertion relocates the section markers of the
  whole buffer, making rendering quadratic on large trees (thousands
  of entries).  Plain positions are sufficient for a read-only stats
  buffer; the price is that positions are not kept in sync with
  edits, which is irrelevant here.

- **Don't double-parse.**  `ctags--refresh-buffer` erases the buffer
  and replaces it with the tree.  Calling it twice on the same buffer
  content will cause the second call to parse the tree text as NDJSON
  (returning nothing).  `ctags-run` handles this by calling
  `ctags-mode` (which calls `ctags--refresh-buffer` once) for fresh
  buffers, and `ctags--refresh-buffer` directly for re-used buffers
  (where the mode is already active and we've just re-populated with
  NDJSON).

- **`ctags--check-ctags` validates the binary.**  It runs
  `ctags --output-format=json --version` and checks the exit code.
  Emacs' `etags` (often installed as `ctags`) doesn't support this flag
  and exits non-zero, producing a clear user-error.

- **`default.nix` patches the default.**  The `postPatch` phase uses
  `substituteInPlace` to replace the string literal `"ctags"` with the
  Nix store path to Universal Ctags, so users never need to customize
  `ctags-program`.
