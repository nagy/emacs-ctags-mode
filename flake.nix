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
      self,
      flake-parts,
      nixpkgs,
      treefmt-nix,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
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
          inherit (pkgs.emacsPackages) melpaBuild;
          # The package shells out to Universal Ctags at runtime
          # (`ctags-run`); bake its store path in so the installed
          # package works without anything on $PATH.
          universalCtags = pkgs.universal-ctags;
        in
        {
          packages.ctags-mode = melpaBuild {
            pname = "ctags-mode";
            # Nix rejects versions Nixpkgs cannot parse. Convention for
            # unreleased packages: <upstream-version>-unstable-<YYYY-MM-DD>,
            # where the date is the last commit touching the source.
            # Derive the date from the flake self-reference. Fall back to
            # the epoch when the source is not a git checkout.
            version =
              let
                d = self.lastModifiedDate or "19700101000000";
              in
              "0-unstable-${builtins.substring 0 4 d}-${builtins.substring 4 2 d}-${builtins.substring 6 2 d}";

            src = lib.cleanSource ./.;

            # Elisp dependencies from the Package-Requires header that
            # already exist in nixpkgs.
            packageRequires = with pkgs.emacsPackages; [ magit-section ];

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

            # The ERT suite covers the parsing and sorting helpers, the
            # renderer, visiting, refresh and bookmarks.  The
            # directory-backed tests drive the real Universal Ctags binary
            # in a throwaway source tree.
            checkPhase = ''
              runHook preCheck
              export HOME=$TMPDIR
              # `package-initialize' (as elpa2nix does at install time) is
              # what puts the packageRequires dependencies on `load-path';
              # a plain batch Emacs cannot see them otherwise.
              emacs --batch -L . \
                --eval "(require 'package)" \
                -f package-initialize \
                --eval '(setq byte-compile-error-on-warn t)' \
                -f batch-byte-compile ctags-mode-tests.el
              emacs --batch -L . \
                --eval "(require 'package)" \
                -f package-initialize \
                -l ctags-mode-tests.elc \
                -f ert-run-tests-batch-and-exit
              runHook postCheck
            '';

            doCheck = true;

            # The directory-backed tests shell out to Universal Ctags.
            nativeCheckInputs = [ universalCtags ];

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
              platforms = lib.platforms.unix;
            };
          };

          packages.default = config.packages.ctags-mode;

          checks = {
            # melpaBuild byte-compiles with warnings as errors and
            # `checkPhase' runs the ERT suite, so building the package is
            # the main check.
            default = config.packages.ctags-mode;

            # checkdoc + package-lint: catch what byte-compilation cannot.
            lint =
              pkgs.runCommand "ctags-mode-lint"
                {
                  nativeBuildInputs = [
                    (pkgs.emacsPackages.emacsWithPackages (p: [ p.package-lint ]))
                  ];
                  # Lint the unpatched sources; the patched copy inside the
                  # built package differs only in one string literal.
                  src = config.packages.ctags-mode.src;
                  meta.description = "checkdoc and package-lint for ctags-mode";
                }
                ''
                  export HOME=$TMPDIR
                  cp "$src"/ctags-mode.el "$src"/ctags-mode-tests.el .
                  # package-lint assumes an online ELPA; offline it cannot
                  # resolve `magit-section', so register a stub package
                  # description via an advice on `package-initialize' (which
                  # resets `package-alist' on every call, wiping plain
                  # pushes).
                  emacs --batch -l package-lint \
                    --eval '(advice-add (quote package-initialize) :after (lambda (&rest _) (push (cons (quote magit-section) (list (package-desc-create :name (quote magit-section) :version (quote (4 0 0)) :reqs nil :kind (quote single) :archive "stub" :summary "stub"))) package-alist)))' \
                    -f package-lint-batch-and-exit ctags-mode.el
                  # checkdoc always exits zero; gate on its output instead.
                  lint_log=$(emacs --batch -l checkdoc \
                    --eval '(progn (checkdoc-file "ctags-mode.el") (checkdoc-file "ctags-mode-tests.el"))' 2>&1)
                  if [ -n "$lint_log" ]; then printf '%s\n' "$lint_log"; exit 1; fi
                  touch $out
                '';
          };

          # `nix fmt` runs nixfmt via treefmt; keep formatting canonical.
          formatter = treefmt-nix.lib.mkWrapper pkgs {
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
