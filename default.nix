{
  pkgs ? import <nixpkgs> { },
  lib ? pkgs.lib,
  emacs ? pkgs.emacs,
  emacsPackages ? emacs.pkgs,
  melpaBuild ? emacsPackages.melpaBuild,
  magit-section ? emacsPackages.magit-section,
  universal-ctags ? pkgs.universal-ctags,
}:

melpaBuild {
  pname = "ctags-mode";
  version = "0.1.0-unstable-2026-07-08";

  src = lib.cleanSource ./.;

  packageRequires = [ magit-section ];

  postPatch = ''
    substituteInPlace ctags-mode.el \
      --replace-fail 'ctags-program "ctags"' 'ctags-program "${lib.getExe universal-ctags}"'
  '';

  turnCompilationWarningToError = true;

  meta = {
    description = "Browse Universal Ctags JSON output in a collapsible magit-section tree";
    longDescription = ''
      ctags-mode is an Emacs major mode for browsing the JSON output of
      Universal Ctags.  It presents tags in a collapsible 3-level tree
      (kind → file → entry) built on magit-section.  Supports both
      file-backed buffers (opening a TAGS.json file) and directory-backed
      buffers (running ctags on a source tree with M-x ctags-run).
    '';
    license = lib.licenses.agpl3Plus;
    homepage = "https://github.com/nagy/emacs-ctags-mode";
    maintainers = with lib.maintainers; [ nagy ];
    platforms = lib.platforms.unix;
  };
}
