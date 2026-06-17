{
  lib,
  melpaBuild,
  magit-section,
  universal-ctags,
}:

melpaBuild {
  pname = "ctags-mode";
  version = "0.1.0-unstable-2026-06-17";

  src = lib.cleanSource ./.;

  packageRequires = [ magit-section ];

  postPatch = ''
    substituteInPlace ctags-mode.el \
      --replace-fail '"ctags"' '"${lib.getExe universal-ctags}"'
  '';

  meta = {
    description = "Browse Universal Ctags JSON output in a collapsible magit-section tree";
    license = lib.licenses.gpl3Plus;
  };
}
