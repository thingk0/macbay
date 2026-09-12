# MacBay documentation assets

The four project READMEs use the supplied MacBay storage-bridge symbol at 140 × 140 pixels:

- `macbay-symbol-color.svg`: light theme and fallback.
- `macbay-symbol-dark.svg`: dark theme, selected through a `<picture>` element.

These files are copied from `MacBay-Brand-Assets/logo/`. Only trailing whitespace has been normalized; artwork is unchanged. Keep both variants in sync when updating the brand kit. The previous `Assets/macbay-icon-concept.png` is retained as an archived concept.

The Swift package currently ships terminal executables, so app-icon catalogs, menu-bar template images, and favicons are not bundled into the CLI.
