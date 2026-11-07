# MacBay brand assets

The four project READMEs use the official MacBay storage-bridge symbol at 140 × 140 pixels:

- `macbay-symbol-color.svg`: light theme and fallback.
- `macbay-symbol-dark.svg`: dark theme, selected through a `<picture>` element.

Keep both variants in sync when updating the branding. The artwork comes from the supplied brand kit; only trailing whitespace has been normalized.

`macbay-social-preview.png` (1280 × 640) is the GitHub social preview image. GitHub does not read it from the repository; upload it under **Settings → General → Social preview** whenever it changes.

Keep only assets used by the project in this directory. The complete source kit and retired icon concept are archived outside the repository, in the sibling `../MacBay-Brand-Assets/` directory (relative to the repository root). That local archive is not required to build the CLI or render the documentation.

The GUI PoC uses the existing app artwork as `Sources/MacBayGUI/Resources/AppIcon.png`
and its macOS icon as `MacBay.icns`. Both were copied or converted from the archived
brand kit without changing the artwork. The app packaging script includes them in
`MacBay.app`; the CLI does not bundle GUI assets. Menu-bar template images and
favicons remain in the archive until those product surfaces need them.
