package hugobridge

import (
	"encoding/json"
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
	if version.HugoVersion != "0.134.3" || version.Extended || version.Target != "ios" {
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
	output := filepath.Join(root, "output")
	resource := filepath.Join(root, "resource")
	cache := filepath.Join(root, "cache")
	overlay := filepath.Join(root, "overlay")
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
