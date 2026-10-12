# MacBay brand assets

The four project READMEs use the official MacBay storage-bridge symbol at 140 × 140 pixels:

- `macbay-symbol-color.svg`: light theme and fallback.
- `macbay-symbol-dark.svg`: dark theme, selected through a `<picture>` element.

Keep both variants in sync when updating the branding. The artwork comes from the supplied brand kit; only trailing whitespace has been normalized.

`macbay-social-preview.png` (1280 × 640) is the GitHub social preview image. GitHub does not read it from the repository; upload it under **Settings → General → Social preview** whenever it changes.

Keep only assets used by the project in this directory. The complete source kit and retired icon concept are archived outside the repository, in the sibling `../MacBay-Brand-Assets/` directory (relative to the repository root). That local archive is not required to build the CLI or render the documentation.

The Swift package currently ships terminal executables, so app-icon catalogs, menu-bar template images, and favicons are not bundled into the CLI. Add those assets when a product surface needs them.
