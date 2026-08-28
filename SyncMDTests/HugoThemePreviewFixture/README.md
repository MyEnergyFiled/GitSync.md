# Legacy quick-preview snapshot fixture

This fixture is retained only for regression coverage of the legacy Swift quick
preview during migration. It is not used by the real Hugo theme preview.

`expected.html` was generated with the official [Hugo v0.164.0](https://github.com/gohugoio/hugo/releases/tag/v0.164.0) Linux amd64 release:

```bash
hugo --source HugoThemePreviewFixture --destination public --minify
```

The downloaded archive SHA-256 was `d9c8b17285ea4ec004d9f814273ea910f2051ce02c284993fd1f91ba455ae50d`.
The snapshot deliberately uses only the compatibility layer's supported semantic subset. Unsupported capabilities are documented in `HUGO_THEME_PREVIEW_COMPATIBILITY.md` at the repository root.
