# Real Hugo preview fixture

This fixture is consumed by `Native/HugoBridge` integration tests. The test
copies only this small fixture into a disposable directory and renders it with
the embedded Hugo `0.134.3` engine; it does not use the Swift quick-preview
parser as a reference renderer.

Coverage includes a project layout override, a theme partial and shortcode,
two themes, an editor overlay path, Hugo Pipes CSS/JS output, and a pair of
pages used to verify the full page graph and editor-page segment.
