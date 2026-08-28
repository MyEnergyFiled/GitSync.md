package hugobridge

import (
	"encoding/json"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRuntimeVersionIsPinned(t *testing.T) {
	var version runtimeVersionResponse
	if err := json.Unmarshal([]byte(NewRuntime().RuntimeVersion()), &version); err != nil {
		t.Fatal(err)
	}
	if version.HugoVersion != "0.134.3" || version.Extended || !strings.HasPrefix(version.Target, "ios/") {
		t.Fatalf("unexpected runtime version: %+v", version)
	}
}

func TestSafeRelativePathRejectsTraversal(t *testing.T) {
	for _, path := range []string{"../secret", "a/../../secret", "/absolute", "file://remote", "", "."} {
		if _, err := safeRelativePath(path); err == nil {
			t.Errorf("expected %q to be rejected", path)
		}
	}
	if value, err := safeRelativePath("content/posts/index.md"); err != nil || value != "content/posts/index.md" {
		t.Fatalf("valid path rejected: %q, %v", value, err)
	}
}

func TestLogicalPagePathRecognizesContentBundles(t *testing.T) {
	tests := map[string]string{
		"content/posts/hello.md":       "/posts/hello",
		"content/posts/hello/index.md": "/posts/hello",
		"content/posts/_index.md":      "/posts",
		"content/_index.md":            "/",
	}
	for input, expected := range tests {
		if actual := logicalPagePath(input); actual != expected {
			t.Errorf("logicalPagePath(%q) = %q, want %q", input, actual, expected)
		}
	}
}

func TestBuildUsesOverlayWithoutChangingRepository(t *testing.T) {
	root := t.TempDir()
	workspace := t.TempDir()
	output := filepath.Join(workspace, "output")
	resource := filepath.Join(workspace, "resource")
	cache := filepath.Join(workspace, "cache")
	overlay := filepath.Join(workspace, "overlay")
	for _, dir := range []string{output, resource, cache, overlay} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	write := func(path, contents string) {
		t.Helper()
		if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(contents), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	write(filepath.Join(root, "hugo.toml"), "baseURL = \"https://example.test/\"\n")
	write(filepath.Join(root, "layouts", "_default", "single.html"), "<h1>{{ .Title }}</h1>{{ .Content }}")
	write(filepath.Join(root, "content", "posts", "hello.md"), "---\ntitle: Disk\n---\nDisk body")
	original, err := os.ReadFile(filepath.Join(root, "content", "posts", "hello.md"))
	if err != nil {
		t.Fatal(err)
	}

	runtime := NewRuntime()
	openJSON, err := json.Marshal(openRequest{
		RepositoryRoot: root,
		OutputDirectory: output,
		ResourceDirectory: resource,
		CacheDirectory: cache,
		OverlayDirectory: overlay,
	})
	if err != nil {
		t.Fatal(err)
	}
	id, err := runtime.OpenSession(string(openJSON))
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.CloseSession(id)

	buildJSON, err := json.Marshal(buildRequest{
		Mode: "editorPage",
		RepositoryRoot: root,
		BaseURL: "http://127.0.0.1:1234/token/",
		Environment: "production",
		BuildDrafts: true,
		BuildFuture: true,
		BuildExpired: true,
		OverlayFiles: []overlayFile{{
			RepositoryRelativePath: "content/posts/hello.md",
			Contents: []byte("---\ntitle: Overlay\n---\nOverlay body"),
		}},
		Generation: 1,
	})
	if err != nil {
		t.Fatal(err)
	}
	responseJSON, err := runtime.Build(id, string(buildJSON))
	if err != nil {
		t.Fatal(err)
	}
	var response buildResponse
	if err := json.Unmarshal([]byte(responseJSON), &response); err != nil {
		t.Fatal(err)
	}
	if response.EntryPath == "" || len(response.RenderedPaths) == 0 {
		t.Fatalf("empty build response: %+v", response)
	}
	entry, err := runtime.ReadOutput(id, response.EntryPath)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(entry), "Overlay") || strings.Contains(string(entry), "Disk body") {
		t.Fatalf("overlay was not rendered: %s", entry)
	}
	current, err := os.ReadFile(filepath.Join(root, "content", "posts", "hello.md"))
	if err != nil {
		t.Fatal(err)
	}
	if string(current) != string(original) {
		t.Fatalf("repository content was modified")
	}
}

func TestBuildRealFixtureUsesThemePipesAndEditorSegment(t *testing.T) {
	root := t.TempDir()
	fixture := filepath.Join("..", "..", "SyncMDTests", "HugoRealPreviewFixture")
	copyFixture(t, fixture, root)
	before := snapshotTree(t, root)
	output := filepath.Join(t.TempDir(), "output")
	resource := filepath.Join(t.TempDir(), "resources")
	cache := filepath.Join(t.TempDir(), "cache")
	overlay := filepath.Join(t.TempDir(), "overlay")
	runtime := NewRuntime()
	openJSON, err := json.Marshal(openRequest{
		RepositoryRoot: root,
		OutputDirectory: output,
		ResourceDirectory: resource,
		CacheDirectory: cache,
		OverlayDirectory: overlay,
		SelectedTheme: stringPointer("ThemeA"),
	})
	if err != nil {
		t.Fatal(err)
	}
	id, err := runtime.OpenSession(string(openJSON))
	if err != nil {
		t.Fatal(err)
	}
	defer runtime.CloseSession(id)

	buildJSON, err := json.Marshal(buildRequest{
		Mode: "editorPage",
		RepositoryRoot: root,
		ArticleRepositoryRelativePath: stringPointer("content/posts/first/index.md"),
		SelectedTheme: stringPointer("ThemeA"),
		BaseURL: "http://127.0.0.1:1234/fixture/",
		Environment: "production",
		BuildDrafts: true,
		BuildFuture: true,
		BuildExpired: true,
		Generation: 7,
	})
	if err != nil {
		t.Fatal(err)
	}
	responseJSON, err := runtime.Build(id, string(buildJSON))
	if err != nil {
		paths, _, collectErr := collectOutput(output)
		t.Fatalf("%v; output paths=%v (collect error: %v)", err, paths, collectErr)
	}
	var response buildResponse
	if err := json.Unmarshal([]byte(responseJSON), &response); err != nil {
		t.Fatal(err)
	}
	if response.EntryPath != "posts/first/index.html" {
		t.Fatalf("unexpected entry path: %q", response.EntryPath)
	}
	if containsPath(response.RenderedPaths, "posts/second/index.html") {
		t.Fatalf("editor segment rendered the unrelated page: %+v", response.RenderedPaths)
	}
	entry, err := runtime.ReadOutput(id, response.EntryPath)
	if err != nil {
		t.Fatal(err)
	}
	page := string(entry)
	for _, marker := range []string{
		"data-theme=\"a\"",
		"First fixture page",
		"shortcode output",
		"project layout override",
		"previous",
	} {
		if !strings.Contains(page, marker) {
			t.Fatalf("rendered fixture is missing %q: %s", marker, page)
		}
	}
	if !containsSuffix(response.RenderedPaths, ".css") || !containsSuffix(response.RenderedPaths, ".js") {
		t.Fatalf("resource pipeline output missing: %+v", response.RenderedPaths)
	}
	after := snapshotTree(t, root)
	if len(before) != len(after) {
		t.Fatalf("runtime changed repository file list: before=%d after=%d", len(before), len(after))
	}
	for path, contents := range before {
		if after[path] != contents {
			t.Fatalf("runtime changed repository file %q", path)
		}
	}
}

func stringPointer(value string) *string { return &value }

func containsPath(paths []string, expected string) bool {
	for _, path := range paths {
		if path == expected {
			return true
		}
	}
	return false
}

func containsSuffix(paths []string, suffix string) bool {
	for _, path := range paths {
		if strings.HasSuffix(path, suffix) {
			return true
		}
	}
	return false
}

func snapshotTree(t *testing.T, root string) map[string]string {
	t.Helper()
	snapshot := map[string]string{}
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			return nil
		}
		contents, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		relative, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		snapshot[filepath.ToSlash(relative)] = string(contents)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return snapshot
}

func copyFixture(t *testing.T, source, destination string) {
	t.Helper()
	err := fs.WalkDir(os.DirFS(source), ".", func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		target := filepath.Join(destination, filepath.FromSlash(path))
		if entry.IsDir() {
			return os.MkdirAll(target, 0o700)
		}
		contents, err := os.ReadFile(filepath.Join(source, filepath.FromSlash(path)))
		if err != nil {
			return err
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
			return err
		}
		return os.WriteFile(target, contents, 0o600)
	})
	if err != nil {
		t.Fatal(err)
	}
}
