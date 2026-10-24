# PhotoCraft Bridge

Free, open-source plugins for editing Adobe XD and Figma image fills in PhotoCraft and syncing saved changes back to the original layer.

PhotoCraft Bridge is an independent integration. PhotoCraft, Figma, and Adobe XD are separate products; this repository does not distribute their applications or licenses.

## Platforms

| Host | Distribution | Requirements |
| --- | --- | --- |
| Figma Design desktop | Submitted for Community review ([pending, not public yet](https://www.figma.com/community/plugin/1695793882852666354)); standalone development package | Apple Silicon Mac; macOS 11 or later; PhotoCraft installed |
| Adobe XD | Standalone `.xdx` and companion installer | Apple Silicon Mac; macOS 26 or later; XD 36 or later; PhotoCraft installed |

Adobe no longer accepts new XD Marketplace plugins. Existing Marketplace listings can still be updated. The XD version is distributed through GitHub Releases. [Adobe distribution notice](https://developer.adobe.com/xd/uxp/distribution/)

## Use

1. Install the companion for your host application from a release package.
2. Install the Figma plugin or the XD `.xdx` package. The source builds also include development manifests.
3. Select a layer with one visible image fill, then run **在 PhotoCraft 中编辑** (Edit in PhotoCraft).
4. On first use, connect the plugin with the pairing code shown by the companion installer.
5. Edit the opened PSD in PhotoCraft and save with **Command+S**. The saved composite replaces the original layer's image fill.

Figma's plugin must remain running while receiving changes. Figma closes a running plugin when another plugin starts in that file. Re-run the editor command to establish a new editing association after closing it. Public plugins do not depend on Figma's private APIs.

XD's companion needs macOS Accessibility access to invoke the plugin's update command. The default installer does not change XD application resources or add an item to its native Photoshop menu.

Layer position, dimensions, and rotation are retained. Figma retains image-fill settings; XD retains the fill's scaling behavior, but an adjusted internal crop may need to be restored manually. Replacing the source image, deleting its layer, or undoing a returned image ends the association to avoid overwriting later work. Save the opened PSD directly; a different Save As path is not watched.

## Limits

- PNG, JPEG, and GIF input. GIF is treated as a static image.
- PhotoCraft must save a compatible RGB 8-bit or 16-bit PSD composite. Keep its maximum PSD compatibility setting enabled.
- Raw, RLE, ZIP, and ZIP-predicted PSD composites are supported. PSB, 32-bit, non-RGB, and missing composites are rejected.
- Figma image API limits continue to apply. The companion rejects input files over 64 MiB.
- The Figma public build isolates editing jobs by plugin run. Closing the file or plugin stops updates to that document; the local PSD remains available.
- The XD optional native-menu patch under `XD-Compositor/context-menu` is version-specific developer tooling. It is not applied by the release installers and is not included in the plugin store package.

## Data and permissions

Images and PSD working files are processed locally. The companions listen only on the loopback interface and require a random, per-installation token. Public plugin packages contain no installation tokens. Figma stores its pairing token in local `clientStorage`; XD stores it in its plugin data folder.

Working PSDs are retained until the user deletes them. See [Privacy](PRIVACY.md) for paths, data handling, and deletion instructions.

## Build from source

The build machine needs Python 3 and Xcode command-line tools. Release installers contain compiled companions, so end users do not need a compiler.

```sh
python3 scripts/build_release.py
```

The shared PSD implementation is in `shared/PSD.swift`. The XD legacy Compositor renderer includes pinned MIT-licensed upstream code; its source and attribution are retained in `XD-Compositor/renderer`.

## License and support

The integration code is available under the [MIT license](LICENSE). Third-party notices are in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). This MIT license also applies when the plugin is distributed for free through Figma Community.

Use this repository's Issues page for support. Do not attach pairing codes, authentication tokens, private documents, or images you do not intend to make public.
