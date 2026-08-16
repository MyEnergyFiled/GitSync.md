# HugoInk Brand Assets

HugoInk is the user-facing name of the app. Its mark combines four elements:

- a hexagonal frame for the Hugo-oriented workspace;
- a dominant `H` for immediate product recognition;
- a folded document for Markdown content;
- three connected nodes for Git history and publishing.

## Palette

| Role | Color |
| --- | --- |
| Ink navy | `#061838` |
| Coral | `#FF4261` |
| Cyan | `#20C4D5` |
| Warm cream | `#FFF1D0` |

`HugoInk-Mark.svg` is the scalable source mark. With Python 3 and Pillow
available, the iOS asset is rendered as an opaque 1024×1024 RGB PNG with:

```bash
python3 scripts/render-hugoink-icon.py \
  --png Sync.md/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png \
  --svg Branding/HugoInk-Mark.svg
```

`GitSync-AppIcon-legacy.png` preserves the previous icon for migration history.
Do not rename the Xcode project, bundle identifier, URL scheme, or Keychain
service as part of the visible-brand migration; those identifiers remain stable
so an upgrade keeps credentials, callbacks, app-container data, and signing
behavior.
