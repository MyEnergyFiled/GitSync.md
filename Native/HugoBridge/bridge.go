// Package hugobridge exposes the smallest JSON/bytes boundary needed by the
// iOS app. Hugo itself remains inside this package; no Hugo CLI or subprocess
// is used by the app.
package hugobridge

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	goruntime "runtime"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/bep/logg"
	"github.com/bep/overlayfs"
	"github.com/gohugoio/hugo/common/loggers"
	"github.com/gohugoio/hugo/config"
	"github.com/gohugoio/hugo/config/allconfig"
	"github.com/gohugoio/hugo/deps"
	"github.com/gohugoio/hugo/hugofs"
	"github.com/gohugoio/hugo/hugolib"
	"github.com/spf13/afero"
)

const runtimeVersion = "0.134.3"

type Runtime struct {
	mu       sync.Mutex
	nextID   int64
	sessions map[int64]*session
}

type session struct {
	mu sync.Mutex

	repositoryRoot string
	outputDir      string
	resourceDir    string
	cacheDir       string
	overlayDir     string
	theme          string

	sites   *hugolib.HugoSites
	baseURL string
}

type openRequest struct {
	RepositoryRoot string `json:"repositoryRoot"`
	OutputDirectory string `json:"outputDirectory"`
	ResourceDirectory string `json:"resourceDirectory"`
	CacheDirectory string `json:"cacheDirectory"`
	OverlayDirectory string `json:"overlayDirectory"`
	SelectedTheme *string `json:"selectedTheme"`
}

type overlayFile struct {
	RepositoryRelativePath string `json:"repositoryRelativePath"`
	Contents []byte `json:"contents"`
}

type buildRequest struct {
	Mode string `json:"mode"`
	RepositoryRoot string `json:"repositoryRoot"`
	ArticleRepositoryRelativePath *string `json:"articleRepositoryRelativePath"`
	SelectedTheme *string `json:"selectedTheme"`
	BaseURL string `json:"baseURL"`
	Environment string `json:"environment"`
	BuildDrafts bool `json:"buildDrafts"`
	BuildFuture bool `json:"buildFuture"`
	BuildExpired bool `json:"buildExpired"`
	OverlayFiles []overlayFile `json:"overlayFiles"`
	Generation uint64 `json:"generation"`
}

type runtimeVersionResponse struct {
	HugoVersion string `json:"hugoVersion"`
	Extended bool `json:"extended"`
	GoVersion string `json:"goVersion"`
	Target string `json:"target"`
}

type diagnostic struct {
	Severity string `json:"severity"`
	Summary string `json:"summary"`
}

type buildStatistics struct {
	DurationMilliseconds int64 `json:"durationMilliseconds"`
	RenderedPageCount int `json:"renderedPageCount"`
	OutputByteCount int64 `json:"outputByteCount"`
}

type buildResponse struct {
	Generation uint64 `json:"generation"`
	EntryPath string `json:"entryPath"`
	RenderedPaths []string `json:"renderedPaths"`
	Warnings []diagnostic `json:"warnings"`
	Statistics buildStatistics `json:"statistics"`
	CacheKey string `json:"cacheKey"`
	OutputDirectory string `json:"outputDirectory"`
}

// NewRuntime creates an isolated runtime manager. It is safe to call from
// Swift without any process-global Hugo state.
func NewRuntime() *Runtime {
	return &Runtime{sessions: make(map[int64]*session)}
}

// RuntimeVersion returns the exact embedded build contract as JSON.
func (r *Runtime) RuntimeVersion() string {
	value, _ := json.Marshal(runtimeVersionResponse{
		HugoVersion: runtimeVersion,
		Extended: false,
		GoVersion: runtimeGoVersion,
		Target: "ios",
	})
	return string(value)
}

// OpenSession validates paths and reserves a session. Hugo is initialized on
// the first Build call, after the local HTTP origin is known.
func (r *Runtime) OpenSession(requestJSON string) (int64, error) {
	var request openRequest
	if err := json.Unmarshal([]byte(requestJSON), &request); err != nil {
		return 0, fmt.Errorf("invalid open session request: %w", err)
	}
	paths := []string{request.RepositoryRoot, request.OutputDirectory, request.ResourceDirectory, request.CacheDirectory, request.OverlayDirectory}
	for _, path := range paths {
		if err := validateAbsolutePath(path); err != nil {
			return 0, err
		}
		if err := os.MkdirAll(path, 0o700); err != nil {
			return 0, fmt.Errorf("create runtime directory: %w", err)
		}
	}

	r.mu.Lock()
	defer r.mu.Unlock()
	r.nextID++
	id := r.nextID
	theme := ""
	if request.SelectedTheme != nil {
		theme = *request.SelectedTheme
	}
	r.sessions[id] = &session{
		repositoryRoot: filepath.Clean(request.RepositoryRoot),
		outputDir: filepath.Clean(request.OutputDirectory),
		resourceDir: filepath.Clean(request.ResourceDirectory),
		cacheDir: filepath.Clean(request.CacheDirectory),
		overlayDir: filepath.Clean(request.OverlayDirectory),
		theme: theme,
	}
	return id, nil
}

// Build renders the complete Hugo site with the real Hugo engine. Editor-page
// mode only changes which entry URL is returned; it never replaces Hugo's
// site object graph with a Markdown-only renderer.
func (r *Runtime) Build(id int64, requestJSON string) (string, error) {
	var request buildRequest
	if err := json.Unmarshal([]byte(requestJSON), &request); err != nil {
		return "", fmt.Errorf("invalid build request: %w", err)
	}
	r.mu.Lock()
	s := r.sessions[id]
	r.mu.Unlock()
	if s == nil {
		return "", errors.New("Hugo session not found")
	}

	s.mu.Lock()
	defer s.mu.Unlock()
	if filepath.Clean(request.RepositoryRoot) != s.repositoryRoot {
		return "", errors.New("build repository does not match the opened session")
	}
	if err := replaceOverlayFiles(s.overlayDir, request.OverlayFiles); err != nil {
		return "", err
	}
	if err := os.RemoveAll(s.outputDir); err != nil {
		return "", fmt.Errorf("clear preview output: %w", err)
	}
	if err := os.MkdirAll(s.outputDir, 0o700); err != nil {
		return "", fmt.Errorf("create preview output: %w", err)
	}

	if s.sites == nil || s.baseURL != request.BaseURL {
		if s.sites != nil && s.sites.Deps != nil {
			_ = s.sites.Deps.Close()
		}
		s.sites = nil
		s.baseURL = ""
		sites, err := newHugoSites(s, request)
		if err != nil {
			return "", err
		}
		s.sites = sites
		s.baseURL = request.BaseURL
	}

	started := time.Now()
	if err := s.sites.Build(hugolib.BuildCfg{NoBuildLock: true}); err != nil {
		return "", fmt.Errorf("hugo build failed: %w", err)
	}
	paths, bytesWritten, err := collectOutput(s.outputDir)
	if err != nil {
		return "", err
	}
	entry := chooseEntry(s.outputDir, request.ArticleRepositoryRelativePath)
	if entry == "" {
		return "", errors.New("Hugo produced no HTML preview entry")
	}
	response, err := json.Marshal(buildResponse{
		Generation: request.Generation,
		EntryPath: entry,
		RenderedPaths: paths,
		Statistics: buildStatistics{
			DurationMilliseconds: time.Since(started).Milliseconds(),
			RenderedPageCount: countHTML(paths),
			OutputByteCount: bytesWritten,
		},
		CacheKey: fmt.Sprintf("%s-%d", runtimeVersion, request.Generation),
		OutputDirectory: s.outputDir,
	})
	if err != nil {
		return "", fmt.Errorf("encode build response: %w", err)
	}
	return string(response), nil
}

// ReadOutput reads only a regular file below the session output directory.
func (r *Runtime) ReadOutput(id int64, path string) ([]byte, error) {
	r.mu.Lock()
	s := r.sessions[id]
	r.mu.Unlock()
	if s == nil {
		return nil, errors.New("Hugo session not found")
	}
	relative, err := safeRelativePath(path)
	if err != nil {
		return nil, err
	}
	root := filepath.Clean(s.outputDir)
	candidate := filepath.Join(root, filepath.FromSlash(relative))
	if !isInside(candidate, root) {
		return nil, errors.New("output path escapes preview directory")
	}
	info, err := os.Stat(candidate)
	if err != nil || !info.Mode().IsRegular() {
		return nil, os.ErrNotExist
	}
	return os.ReadFile(candidate)
}

// ListOutput returns the regular output files as JSON.
func (r *Runtime) ListOutput(id int64) (string, error) {
	r.mu.Lock()
	s := r.sessions[id]
	r.mu.Unlock()
	if s == nil {
		return "", errors.New("Hugo session not found")
	}
	paths, _, err := collectOutput(s.outputDir)
	if err != nil {
		return "", err
	}
	data, err := json.Marshal(paths)
	return string(data), err
}

// Invalidate clears the output so the next build cannot reuse stale files.
func (r *Runtime) Invalidate(id int64, requestJSON string) error {
	r.mu.Lock()
	s := r.sessions[id]
	r.mu.Unlock()
	if s == nil {
		return errors.New("Hugo session not found")
	}
	return os.RemoveAll(s.outputDir)
}

// CloseSession releases Hugo resources and removes only disposable preview
// directories. The repository is never modified.
func (r *Runtime) CloseSession(id int64) error {
	r.mu.Lock()
	s := r.sessions[id]
	delete(r.sessions, id)
	r.mu.Unlock()
	if s == nil {
		return nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.sites != nil && s.sites.Deps != nil {
		_ = s.sites.Deps.Close()
	}
	return nil
}

func newHugoSites(s *session, request buildRequest) (*hugolib.HugoSites, error) {
	sourceOverlay := afero.NewBasePathFs(hugofs.Os, s.overlayDir)
	sourceRepository := afero.NewBasePathFs(hugofs.Os, s.repositoryRoot)
	// Hugo's config loader probes and creates cache/resource directories through
	// the source filesystem. Mount those virtual names to the disposable
	// workspace instead of allowing it to touch the repository's resources/
	// directory or its parent.
	workspaceParent := filepath.Dir(s.cacheDir)
	sourceResources := afero.NewBasePathFs(hugofs.Os, workspaceParent)
	sourceCache := afero.NewBasePathFs(hugofs.Os, workspaceParent)
	source := overlayfs.New(overlayfs.Options{Fss: []afero.Fs{
		sourceOverlay,
		sourceResources,
		sourceRepository,
		sourceCache,
	}})
	flags := config.New()
	flags.Set("workingDir", "/")
	flags.Set("publishDir", s.outputDir)
	flags.Set("publishDirDynamic", s.outputDir)
	flags.Set("publishDirStatic", s.outputDir)
	flags.Set("resourceDir", filepath.Base(s.resourceDir))
	flags.Set("cacheDir", filepath.Base(s.cacheDir))
	flags.Set("themesDir", "themes")
	flags.Set("baseURL", request.BaseURL)
	flags.Set("buildDrafts", request.BuildDrafts)
	flags.Set("buildFuture", request.BuildFuture)
	flags.Set("buildExpired", request.BuildExpired)
	flags.Set("renderToMemory", false)
	flags.Set("noBuildLock", true)
	if request.Environment != "" {
		flags.Set("environment", request.Environment)
	}
	if request.SelectedTheme != nil && *request.SelectedTheme != "" {
		flags.Set("theme", *request.SelectedTheme)
	}
	logger := loggers.New(loggers.Options{Stdout: io.Discard, Stderr: io.Discard, Level: logg.LevelError})
	configs, err := allconfig.LoadConfig(allconfig.ConfigSourceDescriptor{
		Fs: source,
		Flags: flags,
		Environment: request.Environment,
		Logger: logger,
		IgnoreModuleDoesNotExist: true,
	})
	if err != nil {
		return nil, fmt.Errorf("load Hugo config: %w", err)
	}
	destination := hugofs.Os
	fs := hugofs.NewFromSourceAndDestination(source, destination, flags)
	return hugolib.NewHugoSites(deps.DepsCfg{
		Configs: configs,
		Fs: fs,
		LogLevel: logg.LevelError,
		LogOut: io.Discard,
	})
}

func replaceOverlayFiles(root string, files []overlayFile) error {
	if err := os.RemoveAll(root); err != nil {
		return fmt.Errorf("clear preview overlay: %w", err)
	}
	if err := os.MkdirAll(root, 0o700); err != nil {
		return fmt.Errorf("create preview overlay: %w", err)
	}
	for _, file := range files {
		relative, err := safeRelativePath(file.RepositoryRelativePath)
		if err != nil {
			return err
		}
		destination := filepath.Join(root, filepath.FromSlash(relative))
		if !isInside(destination, root) {
			return errors.New("overlay path escapes preview directory")
		}
		if err := os.MkdirAll(filepath.Dir(destination), 0o700); err != nil {
			return fmt.Errorf("create overlay parent: %w", err)
		}
		if err := os.WriteFile(destination, file.Contents, 0o600); err != nil {
			return fmt.Errorf("write overlay file: %w", err)
		}
	}
	return nil
}

func collectOutput(root string) ([]string, int64, error) {
	var paths []string
	var bytesWritten int64
	err := filepath.Walk(root, func(path string, info os.FileInfo, err error) error {
		if err != nil { return err }
		if info.IsDir() { return nil }
		if !info.Mode().IsRegular() { return nil }
		relative, err := filepath.Rel(root, path)
		if err != nil { return err }
		paths = append(paths, filepath.ToSlash(relative))
		bytesWritten += info.Size()
		return nil
	})
	sort.Strings(paths)
	return paths, bytesWritten, err
}

func chooseEntry(outputDir string, article *string) string {
	paths, _, err := collectOutput(outputDir)
	if err != nil { return "" }
	if article != nil && *article != "" {
		relative := filepath.ToSlash(filepath.Clean(*article))
		relative = strings.TrimPrefix(relative, "content/")
		stem := strings.TrimSuffix(relative, filepath.Ext(relative))
		candidates := []string{stem + "/index.html", stem + ".html"}
		if strings.HasSuffix(stem, "/index") {
			candidates = append([]string{strings.TrimSuffix(stem, "/index") + "/index.html"}, candidates...)
		}
		for _, candidate := range candidates {
			for _, path := range paths { if path == candidate { return candidate } }
		}
	}
	for _, path := range paths { if path == "index.html" { return path } }
	for _, path := range paths { if strings.HasSuffix(path, "/index.html") { return path } }
	return ""
}

func countHTML(paths []string) int { n := 0; for _, path := range paths { if strings.HasSuffix(path, ".html") { n++ } }; return n }

func validateAbsolutePath(path string) error {
	if path == "" || !filepath.IsAbs(path) || strings.ContainsRune(path, 0) {
		return errors.New("runtime paths must be absolute and NUL-free")
	}
	return nil
}

func safeRelativePath(path string) (string, error) {
	path = filepath.ToSlash(path)
	if path == "" || strings.HasPrefix(path, "/") || strings.ContainsRune(path, 0) || strings.Contains(path, "://") {
		return "", errors.New("invalid runtime relative path")
	}
	clean := filepath.ToSlash(filepath.Clean(filepath.FromSlash(path)))
	if clean == "." || clean == ".." || strings.HasPrefix(clean, "../") {
		return "", errors.New("runtime relative path escapes its root")
	}
	return clean, nil
}

func isInside(candidate, root string) bool {
	candidate, _ = filepath.Abs(candidate)
	root, _ = filepath.Abs(root)
	return candidate == root || strings.HasPrefix(candidate, root+string(os.PathSeparator))
}

// Kept in one place so the runtime version report and the generated build
// summary cannot drift.
var runtimeGoVersion = goruntime.Version()
