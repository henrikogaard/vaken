# Third-party notices

Vaken is distributed under the [MIT license](LICENSE).

## Sparkle

The app embeds [Sparkle 2.10.1](https://github.com/sparkle-project/Sparkle/tree/2.10.1), the macOS software update framework. Sparkle is provided under its own license and includes third-party components. Its complete license and notices are copied from the pinned distribution into `Vaken.app/Contents/Resources/Sparkle-LICENSE.txt` during packaging.

The dependency URL, exact version and revision are recorded in `Package.swift` and `Package.resolved`. The Swift package verifies the binary artifact using the checksum supplied by the pinned upstream package manifest.
