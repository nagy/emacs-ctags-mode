{
  description = "Browse Universal Ctags JSON output in a collapsible magit-section tree (Emacs package)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      # One nixpkgs closure, no duplicates.
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      flake-parts,
      nixpkgs,
      treefmt-nix,
      ...
    }:
    # Date of the last commit as YYYY-MM-DD, folded into the version
    # string below.  Flake source info gives it as e.g. "20260922133522",
    # so slice out the year, month and day and glue them with hyphens.
    let
      sourceInfo = inputs.self.sourceInfo or { };
      lastModifiedDate = sourceInfo.lastModifiedDate or "19700101000000";
      commitDate = "${builtins.substring 0 4 lastModifiedDate}-${
        builtins.substring 4 2 lastModifiedDate
      }-${builtins.substring 6 2 lastModifiedDate}";
      version = "0.1.0-unstable-${commitDate}";
    in
    flake-parts.lib.mkFlake { inherit inputs; } {
      # `nix fmt' runs nixfmt via treefmt, and the module adds the
      # `checks.treefmt' gate that fails on an unformatted file.
      imports = [ treefmt-nix.flakeModule ];

      # Emacs packages are pure Elisp: no ELF binaries, so evaluate on
      # every Linux arch (and darwin if the deps exist there).
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      perSystem =
        {
          system,
          pkgs,
          lib,
          config,
          ...
        }:
        let
          # The package shells out to Universal Ctags at runtime
          # (`ctags-run`); bake its store path in so the installed
          # package works without anything on $PATH.
          universalCtags = pkgs.universal-ctags;

          # Overridable, so a consumer can swap the Emacs or the package
          # set: inputs.emacs-ctags-mode.packages.${system}.ctags-mode.override
          # { emacs = pkgs.emacs-nox; }
          ctags-mode = lib.makeOverridable (
            {
              # `melpaBuild' closes over the Emacs of its package set, so an
              # `emacs' argument on the build does nothing. Build the set
              # against the chosen Emacs instead.
              emacs ? pkgs.emacs,
              emacsPackages ? emacs.pkgs,
              melpaBuild ? emacsPackages.melpaBuild,
              # The flake passes this, so a plain import stays explicit.
              version,
            }:
            melpaBuild {
              pname = "ctags-mode";
              preferLocalBuild = true;
              inherit version;

              src = lib.cleanSource ./.;

              # Elisp dependencies from the Package-Requires header that
              # already exist in nixpkgs.
              packageRequires = with emacsPackages; [ magit-section ];

              # Rewrite the default executable path to the Nix store path.
              # Interpolating the derivation bakes the store path in;
              # `lib.getExe'` picks the exact binary name inside the package.
              postPatch = ''
                substituteInPlace ctags-mode.el \
                  --replace-fail 'ctags-program "ctags"' 'ctags-program "${lib.getExe' universalCtags "ctags"}"'
              '';

              # Byte-compilation warnings fail the build. Keep it on: it is
              # the cheapest lint the package will ever get. Silence only
              # genuinely noisy third-party warnings, never your own code.
              turnCompilationWarningToError = true;

              meta = {
                description = "Browse Universal Ctags JSON output in a collapsible magit-section tree";
                longDescription = ''
                  ctags-mode is a major mode for browsing the JSON output of
                  Universal Ctags.  Tags are grouped by kind (func, struct,
                  variable, …) in a collapsible 3-level tree (kind → file →
                  entry) built on magit-section.

                  Both file-backed buffers (opening a generated TAGS.json)
                  and directory-backed buffers (running ctags on a source
                  tree with M-x ctags-run) are supported; the latter can be
                  bookmarked and refreshed by re-running ctags.
                '';
                # Read the license from the file header — Elisp packages
                # conventionally declare it after ";;; Code:".
                license = lib.licenses.agpl3Plus;
                homepage = "https://github.com/nagy/emacs-ctags-mode";
                maintainers = with lib.maintainers; [ nagy ];
                platforms = lib.platforms.linux;
              };
            }
          ) { inherit version; };
        in
        {
          packages.ctags-mode = ctags-mode;
          packages.default = config.packages.ctags-mode;

          checks = {
            # Run the ERT suite against the *installed* package, not the
            # checkout.  The suite covers the parsing and sorting helpers,
            # the renderer, visiting, refresh and bookmarks.  The
            # directory-backed tests drive the real Universal Ctags binary
            # in a throwaway source tree.
            default =
              pkgs.runCommandLocal "ctags-mode-ert"
                {
                  nativeBuildInputs = [
                    # magit-section comes from the same package set, so a
                    # plain batch Emacs sees the packageRequires
                    # dependencies without `package-initialize'.
                    (pkgs.emacsPackages.emacsWithPackages (p: [ p.magit-section ]))
                    # The directory-backed tests shell out to ctags.  The
                    # installed package already bakes in this store path;
                    # the input keeps the tests honest about the binary.
                    universalCtags
                    # Gives Emacs a writable HOME, so the builder needs no
                    # `export HOME=$TMPDIR' line and no two checks share a
                    # home directory.
                    pkgs.writableTmpDirAsHomeHook
                  ];
                  meta.description = "ctags-mode ERT test suite";
                }
                ''
                  # runCommandLocal does not stage the source tree, so copy the
                  # test tree out of the store first.
                  cp -r ${config.packages.ctags-mode.src}/test ./test
                  # Glob every test file instead of listing them: a new
                  # test/<unit>-test.el needs no flake edit.  printf repeats
                  # "-l %s" per match.  failglob makes an empty glob a shell
                  # error, so the || guard fires even without `set -e'.
                  # Restore the default right after: later commands must keep
                  # default glob semantics.  The unquoted $test_args is
                  # intentional: the words must split into -l <file> pairs,
                  # which is safe because test file names never contain
                  # spaces.
                  shopt -s failglob
                  test_args=$(printf -- "-l %s " test/*-test.el) || { echo 'no tests matched test/*-test.el' >&2; exit 1; }
                  shopt -u failglob
                  emacs --batch \
                    -L ${config.packages.ctags-mode}/share/emacs/site-lisp/elpa/ctags-mode-* \
                    -l ${config.packages.ctags-mode}/share/emacs/site-lisp/elpa/ctags-mode-*/ctags-mode.el \
                    $test_args \
                    -f ert-run-tests-batch-and-exit
                  touch $out
                '';

            # checkdoc + package-lint: catch what byte-compilation cannot.
            lint =
              pkgs.runCommandLocal "ctags-mode-lint"
                {
                  nativeBuildInputs = [
                    (pkgs.emacsPackages.emacsWithPackages (p: [ p.package-lint ]))
                    # Gives Emacs a writable HOME, so the builder needs no
                    # `export HOME=$TMPDIR' line and no two checks share a
                    # home directory.
                    pkgs.writableTmpDirAsHomeHook
                  ];
                  # Lint the unpatched sources; the patched copy inside the
                  # built package differs only in one string literal.
                  # test/ is part of the lint surface; `src' may be
                  # pre-filtered, so copy the tree explicitly instead of
                  # relying on what melpaBuild staged.
                  src = config.packages.ctags-mode.src;
                  meta.description = "checkdoc and package-lint for ctags-mode";
                }
                ''
                  cp -r "$src"/. .
                  # package-lint assumes an online ELPA; offline it cannot
                  # resolve `magit-section', so register a stub package
                  # description via an advice on `package-initialize' (which
                  # resets `package-alist' on every call, wiping plain
                  # pushes).  `package-lint-main-file' stops package-lint
                  # from treating the test file as its own package and
                  # complaining about its missing Package-Requires header.
                  emacs --batch -l package-lint \
                    --eval '(setq package-lint-main-file "ctags-mode.el")' \
                    --eval '(advice-add (quote package-initialize) :after (lambda (&rest _) (push (cons (quote magit-section) (list (package-desc-create :name (quote magit-section) :version (quote (4 0 0)) :reqs nil :kind (quote single) :archive "stub" :summary "stub"))) package-alist)))' \
                    -f package-lint-batch-and-exit \
                    *.el test/*.el
                  # checkdoc always exits zero; gate on its output instead.
                  lint_log=$(emacs --batch -l checkdoc \
                    --eval '(setq checkdoc-arguments-in-order-flag t)' \
                    --eval '(mapc (lambda (f) (checkdoc-file f)) command-line-args-left)' \
                    *.el test/*.el 2>&1)
                  if [ -n "$lint_log" ]; then printf '%s\n' "$lint_log"; exit 1; fi
                  touch $out
                '';
          };

          # treefmt-nix has no Elisp formatter, so this formats the flake
          # itself; keep formatting canonical.
          treefmt = {
            projectRootFile = "flake.nix";
            programs.nixfmt.enable = true;
          };

          devShells.default = pkgs.mkShell {
            # Mirror whatever the package needs at runtime when hacking on
            # it: the external CLI, a real Emacs for interactive testing,
            # with the Elisp dependencies on `load-path'.
            packages = [
              universalCtags
              (pkgs.emacsPackages.emacsWithPackages (p: [ p.magit-section ]))
            ];
          };
        };
    };
}
