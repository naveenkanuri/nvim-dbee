package adapters

import (
	"archive/zip"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

type walletMarkerEmitter struct {
	t    *testing.T
	seen map[string]bool
}

func newWalletMarkerEmitter(t *testing.T) *walletMarkerEmitter {
	return &walletMarkerEmitter{t: t, seen: map[string]bool{}}
}

func (e *walletMarkerEmitter) True(name string) {
	e.t.Helper()
	if e.seen[name] {
		e.t.Fatalf("duplicate marker emitted: %s", name)
	}
	e.seen[name] = true
	fmt.Printf("%s=true\n", name)
}

func (e *walletMarkerEmitter) Metric(name string, value float64) {
	e.t.Helper()
	if e.seen[name] {
		e.t.Fatalf("duplicate marker emitted: %s", name)
	}
	e.seen[name] = true
	fmt.Printf("%s=%.3f\n", name, value)
}

func withWalletTestCache(t *testing.T) string {
	t.Helper()
	cacheHome := t.TempDir()
	t.Setenv("XDG_CACHE_HOME", cacheHome)
	SetOracleWalletAutoExtract(true)
	if err := ClearOracleWalletCache(); err != nil {
		t.Fatalf("clear wallet cache: %v", err)
	}
	t.Cleanup(func() {
		SetOracleWalletAutoExtract(true)
		_ = ClearOracleWalletCache()
	})
	return cacheHome
}

func createWalletZip(t *testing.T, dir, name string, files map[string]string) string {
	t.Helper()
	zipPath := filepath.Join(dir, name)
	f, err := os.Create(zipPath)
	if err != nil {
		t.Fatalf("create zip: %v", err)
	}
	zw := zip.NewWriter(f)
	for fileName, content := range files {
		w, err := zw.Create(fileName)
		if err != nil {
			t.Fatalf("create zip entry: %v", err)
		}
		if _, err := w.Write([]byte(content)); err != nil {
			t.Fatalf("write zip entry: %v", err)
		}
	}
	if err := zw.Close(); err != nil {
		t.Fatalf("close zip writer: %v", err)
	}
	if err := f.Close(); err != nil {
		t.Fatalf("close zip file: %v", err)
	}
	return zipPath
}

func defaultWalletFiles() map[string]string {
	return map[string]string{
		"cwallet.sso":      "wallet",
		"tnsnames.ora":     "db_low=(DESCRIPTION=(ADDRESS=(PROTOCOL=tcps)(HOST=example.com)(PORT=1522))(CONNECT_DATA=(SERVICE_NAME=db_low)))",
		"sqlnet.ora":       "WALLET_LOCATION=(SOURCE=(METHOD=file))",
		"ewallet.p12":      "extra",
		"ojdbc.properties": "oracle.net.wallet_location=(SOURCE=(METHOD=file))",
	}
}

func oracleURLWithWallet(walletPath string) string {
	return "oracle://user:pass@example.com:1522/db_low?wallet=" + url.QueryEscape(walletPath) + "&ssl=true"
}

func requirePreparedWallet(t *testing.T, zipPath string) (string, *coreWalletMetaForTest) {
	t.Helper()
	prepared, meta, err := prepareOracleWalletURL(oracleURLWithWallet(zipPath))
	if err != nil {
		t.Fatalf("prepare wallet URL: %v", err)
	}
	if meta == nil {
		t.Fatalf("expected wallet metadata")
	}
	u, err := url.Parse(prepared)
	if err != nil {
		t.Fatalf("parse prepared URL: %v", err)
	}
	return u.Query().Get("wallet"), &coreWalletMetaForTest{
		hashPrefix: meta.HashPrefix,
		cacheHit:   meta.CacheHit,
		extracted:  meta.Extracted,
		fileCount:  meta.FileCount,
	}
}

type coreWalletMetaForTest struct {
	hashPrefix string
	cacheHit   bool
	extracted  bool
	fileCount  int
}

func assertRequiredFiles(t *testing.T, dir string) {
	t.Helper()
	for _, required := range oracleWalletRequiredFiles {
		if _, err := os.Stat(filepath.Join(dir, required)); err != nil {
			t.Fatalf("required file %s missing: %v", required, err)
		}
	}
}

func TestOracleWalletZipMarkers(t *testing.T) {
	emit := newWalletMarkerEmitter(t)
	withWalletTestCache(t)

	tmp := t.TempDir()
	zipPath := createWalletZip(t, tmp, "Wallet.zip", defaultWalletFiles())

	cacheDir, meta := requirePreparedWallet(t, zipPath)
	assertRequiredFiles(t, cacheDir)
	if meta.cacheHit || !meta.extracted || meta.hashPrefix == "" || meta.fileCount < len(oracleWalletRequiredFiles) {
		t.Fatalf("unexpected first extract metadata: %+v", meta)
	}
	emit.True("WALLET_ZIP_AUTO_EXTRACT_OK")

	markerPath := filepath.Join(cacheDir, oracleWalletMarkerFile)
	firstMarkerInfo, err := os.Stat(markerPath)
	if err != nil {
		t.Fatalf("stat marker: %v", err)
	}
	cacheDirAgain, metaAgain := requirePreparedWallet(t, zipPath)
	secondMarkerInfo, err := os.Stat(markerPath)
	if err != nil {
		t.Fatalf("stat marker second: %v", err)
	}
	if cacheDirAgain != cacheDir || !metaAgain.cacheHit || secondMarkerInfo.ModTime() != firstMarkerInfo.ModTime() {
		t.Fatalf("cache hit did not reuse cache")
	}
	emit.True("WALLET_ZIP_CACHE_HIT_REUSES")

	copiedZip := filepath.Join(tmp, "Copy.zip")
	content, err := os.ReadFile(zipPath)
	if err != nil {
		t.Fatalf("read zip: %v", err)
	}
	if err := os.WriteFile(copiedZip, content, 0o600); err != nil {
		t.Fatalf("copy zip: %v", err)
	}
	copiedCacheDir, _ := requirePreparedWallet(t, copiedZip)
	if copiedCacheDir != cacheDir {
		t.Fatalf("content hash did not dedupe: %s != %s", copiedCacheDir, cacheDir)
	}
	emit.True("WALLET_ZIP_CONTENT_HASH_DEDUPES")

	if err := os.WriteFile(filepath.Join(cacheDir, "junk.txt"), []byte("stale"), 0o600); err != nil {
		t.Fatalf("write stale junk: %v", err)
	}
	future := time.Now().Add(2 * time.Second)
	if err := os.Chtimes(zipPath, future, future); err != nil {
		t.Fatalf("touch zip: %v", err)
	}
	cacheDirAfterMTime, metaAfterMTime := requirePreparedWallet(t, zipPath)
	if cacheDirAfterMTime != cacheDir || metaAfterMTime.cacheHit {
		t.Fatalf("mtime did not force re-extract")
	}
	if _, err := os.Stat(filepath.Join(cacheDir, "junk.txt")); !os.IsNotExist(err) {
		t.Fatalf("stale final junk was not removed")
	}
	emit.True("WALLET_ZIP_MTIME_INVALIDATES")
	emit.True("WALLET_ZIP_STALE_FINAL_REPLACED")

	if !walletPermissionsLocked(cacheDir) {
		t.Fatalf("wallet cache permissions are not locked")
	}
	emit.True("WALLET_ZIP_PERMISSIONS_LOCKED")

	dirWallet := filepath.Join(tmp, "wallet-dir")
	if err := os.MkdirAll(dirWallet, 0o700); err != nil {
		t.Fatalf("mkdir wallet dir: %v", err)
	}
	rawDirURL := oracleURLWithWallet(dirWallet)
	preparedDirURL, dirMeta, err := prepareOracleWalletURL(rawDirURL)
	if err != nil {
		t.Fatalf("dir passthrough: %v", err)
	}
	if preparedDirURL != rawDirURL || dirMeta != nil {
		t.Fatalf("directory wallet should pass through")
	}
	emit.True("WALLET_ZIP_NON_ZIP_PASSTHROUGH")

	noExtZip := filepath.Join(tmp, "WalletNoExt")
	if err := os.WriteFile(noExtZip, content, 0o600); err != nil {
		t.Fatalf("write no-ext zip: %v", err)
	}
	if _, magicMeta := requirePreparedWallet(t, noExtZip); magicMeta == nil || magicMeta.hashPrefix == "" {
		t.Fatalf("zip magic was not detected")
	}
	emit.True("WALLET_ZIP_MAGIC_BYTES_DETECTED")

	home := t.TempDir()
	t.Setenv("HOME", home)
	homeZip := filepath.Join(home, "WalletHome.zip")
	if err := os.WriteFile(homeZip, content, 0o600); err != nil {
		t.Fatalf("write home zip: %v", err)
	}
	if _, tildeMeta := requirePreparedWallet(t, "~/WalletHome.zip"); tildeMeta == nil || tildeMeta.hashPrefix == "" {
		t.Fatalf("tilde path did not expand")
	}
	emit.True("WALLET_ZIP_TILDE_EXPANDS")

	badZip := createWalletZip(t, tmp, "Bad.zip", map[string]string{"tnsnames.ora": "x"})
	if _, _, err := prepareOracleWalletURL(oracleURLWithWallet(badZip)); err == nil ||
		!strings.Contains(err.Error(), "missing required file") {
		t.Fatalf("missing files should produce actionable error, got %v", err)
	}
	root, err := oracleWalletCacheRoot()
	if err != nil {
		t.Fatalf("cache root: %v", err)
	}
	entries, _ := os.ReadDir(root)
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".extract-") {
			t.Fatalf("failed extraction left temp residue: %s", entry.Name())
		}
	}
	emit.True("WALLET_ZIP_MISSING_FILES_ERROR")
	emit.True("WALLET_ZIP_ATOMIC_RENAME_OK")

	assertUnsafeZipRejected(t, tmp, "Slip.zip", "../cwallet.sso", "x", "path traversal")
	emit.True("WALLET_ZIP_SLIP_REJECTED")

	assertSymlinkZipRejected(t, tmp)
	emit.True("WALLET_ZIP_SYMLINK_REJECTED")

	assertBombZipRejected(t, tmp)
	emit.True("WALLET_ZIP_BOMB_REJECTED")

	testURLRewriteAndDuplicateKeys(t, zipPath, cacheDir)
	emit.True("WALLET_ZIP_CONN_URL_REWRITTEN")
	emit.True("WALLET_ZIP_DUPLICATE_WALLET_KEYS_NORMALIZED")

	SetOracleWalletAutoExtract(false)
	disabledURL := oracleURLWithWallet(zipPath)
	preparedDisabled, disabledMeta, err := prepareOracleWalletURL(disabledURL)
	if err != nil {
		t.Fatalf("disabled auto-extract should preserve old flow: %v", err)
	}
	if preparedDisabled != disabledURL || disabledMeta != nil {
		t.Fatalf("disabled auto-extract rewrote URL")
	}
	SetOracleWalletAutoExtract(true)
	emit.True("WALLET_ZIP_DISABLE_FLAG_HONORED")

	assertConcurrentResolve(t, zipPath, cacheDir)
	emit.True("WALLET_ZIP_CONCURRENT_RESOLVE_OK")

	emit.True("WALLET_ZIP_NO_LIVE_ORACLE_DEPENDENCY")
}

func assertUnsafeZipRejected(t *testing.T, dir, zipName, entryName, content, wanted string) {
	t.Helper()
	zipPath := createWalletZip(t, dir, zipName, map[string]string{
		entryName:      content,
		"tnsnames.ora": "x",
		"sqlnet.ora":   "x",
	})
	_, _, err := prepareOracleWalletURL(oracleURLWithWallet(zipPath))
	if err == nil || !strings.Contains(strings.ToLower(err.Error()), wanted) {
		t.Fatalf("expected unsafe zip error containing %q, got %v", wanted, err)
	}
}

func assertSymlinkZipRejected(t *testing.T, dir string) {
	t.Helper()
	zipPath := filepath.Join(dir, "Symlink.zip")
	f, err := os.Create(zipPath)
	if err != nil {
		t.Fatalf("create symlink zip: %v", err)
	}
	zw := zip.NewWriter(f)
	hdr := &zip.FileHeader{Name: "cwallet.sso"}
	hdr.SetMode(os.ModeSymlink | 0o777)
	w, err := zw.CreateHeader(hdr)
	if err != nil {
		t.Fatalf("create symlink header: %v", err)
	}
	if _, err := w.Write([]byte("target")); err != nil {
		t.Fatalf("write symlink body: %v", err)
	}
	for name, body := range map[string]string{"tnsnames.ora": "x", "sqlnet.ora": "x"} {
		w, err := zw.Create(name)
		if err != nil {
			t.Fatalf("create zip entry: %v", err)
		}
		_, _ = w.Write([]byte(body))
	}
	if err := zw.Close(); err != nil {
		t.Fatalf("close symlink zip: %v", err)
	}
	if err := f.Close(); err != nil {
		t.Fatalf("close symlink zip file: %v", err)
	}
	_, _, err = prepareOracleWalletURL(oracleURLWithWallet(zipPath))
	if err == nil || !strings.Contains(strings.ToLower(err.Error()), "symlink") {
		t.Fatalf("expected symlink rejection, got %v", err)
	}
}

func assertBombZipRejected(t *testing.T, dir string) {
	t.Helper()
	files := defaultWalletFiles()
	files["cwallet.sso"] = strings.Repeat("x", int(oracleWalletFileCap)+1)
	zipPath := createWalletZip(t, dir, "Bomb.zip", files)
	_, _, err := prepareOracleWalletURL(oracleURLWithWallet(zipPath))
	if err == nil || !strings.Contains(strings.ToLower(err.Error()), "10 mib") {
		t.Fatalf("expected bomb rejection, got %v", err)
	}
}

func testURLRewriteAndDuplicateKeys(t *testing.T, zipPath, cacheDir string) {
	t.Helper()
	rawURL := "oracle://user:pass@example.com:1522/db_low?foo=bar&WALLET=" +
		url.QueryEscape(zipPath) + "&wallet=" + url.QueryEscape(zipPath) + "&ssl=true"
	prepared, meta, err := prepareOracleWalletURL(rawURL)
	if err != nil {
		t.Fatalf("rewrite duplicate wallet keys: %v", err)
	}
	if meta == nil {
		t.Fatalf("expected metadata for duplicate wallet rewrite")
	}
	if strings.Contains(prepared, url.QueryEscape(zipPath)) {
		t.Fatalf("prepared URL leaked source zip path")
	}
	if !strings.Contains(prepared, "foo=bar") || !strings.Contains(prepared, "ssl=true") {
		t.Fatalf("prepared URL lost query params: %s", prepared)
	}
	u, err := url.Parse(prepared)
	if err != nil {
		t.Fatalf("parse prepared URL: %v", err)
	}
	if u.Query().Get("WALLET") != cacheDir {
		t.Fatalf("wallet param was not rewritten to cache dir: %s", prepared)
	}

	conflictURL := "oracle://user:pass@example.com:1522/db_low?wallet=" +
		url.QueryEscape(zipPath) + "&WALLET=" + url.QueryEscape(zipPath+"x")
	if _, _, err := prepareOracleWalletURL(conflictURL); err == nil {
		t.Fatalf("conflicting duplicate wallet keys should fail")
	}
}

func assertConcurrentResolve(t *testing.T, zipPath, expectedDir string) {
	t.Helper()
	var wg sync.WaitGroup
	errs := make(chan error, 8)
	for i := 0; i < 8; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			dir, _ := requirePreparedWallet(t, zipPath)
			if dir != expectedDir {
				errs <- fmt.Errorf("unexpected dir %s", dir)
			}
		}()
	}
	wg.Wait()
	close(errs)
	for err := range errs {
		if err != nil {
			t.Fatal(err)
		}
	}
	root, err := oracleWalletCacheRoot()
	if err != nil {
		t.Fatalf("cache root: %v", err)
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Fatalf("read cache root: %v", err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".extract-") {
			t.Fatalf("temp residue after concurrent resolve: %s", entry.Name())
		}
	}
}

func TestOracleWalletPerfMarkers(t *testing.T) {
	emit := newWalletMarkerEmitter(t)
	withWalletTestCache(t)

	tmp := t.TempDir()
	zipPath := createWalletZip(t, tmp, "PerfWallet.zip", defaultWalletFiles())
	rawURL := oracleURLWithWallet(zipPath)
	prepared, meta, err := prepareOracleWalletURL(rawURL)
	if err != nil {
		t.Fatalf("prime wallet cache: %v", err)
	}
	if meta == nil || !meta.Extracted || prepared == rawURL {
		t.Fatalf("cache prime did not extract wallet")
	}
	u, err := url.Parse(prepared)
	if err != nil {
		t.Fatalf("parse prepared URL: %v", err)
	}
	cacheDir := u.Query().Get("wallet")
	fullHash, err := hashFileSHA256(zipPath)
	if err != nil {
		t.Fatalf("hash zip: %v", err)
	}
	sourceInfo, err := os.Stat(zipPath)
	if err != nil {
		t.Fatalf("stat zip: %v", err)
	}

	hitValidation := measureP95(10, 100, func(i int) {
		if _, ok := validOracleWalletCache(cacheDir, fullHash, sourceInfo.ModTime()); !ok {
			t.Fatalf("valid cache failed at iteration %d", i)
		}
	})
	hitTotal := measureP95(10, 100, func(i int) {
		if _, _, err := prepareOracleWalletURL(rawURL); err != nil {
			t.Fatalf("cache hit prepare failed at iteration %d: %v", i, err)
		}
	})
	extract := measureP95(10, 100, func(i int) {
		if err := ClearOracleWalletCache(); err != nil {
			t.Fatalf("clear cache: %v", err)
		}
		if _, _, err := prepareOracleWalletURL(rawURL); err != nil {
			t.Fatalf("extract prepare failed at iteration %d: %v", i, err)
		}
	})
	if _, _, err := prepareOracleWalletURL(rawURL); err != nil {
		t.Fatalf("re-prime cache: %v", err)
	}
	reextract := measureP95(10, 100, func(i int) {
		next := time.Now().Add(time.Duration(i+1) * time.Second)
		if err := os.Chtimes(zipPath, next, next); err != nil {
			t.Fatalf("touch zip: %v", err)
		}
		if _, _, err := prepareOracleWalletURL(rawURL); err != nil {
			t.Fatalf("reextract prepare failed at iteration %d: %v", i, err)
		}
	})

	if hitValidation >= 5 {
		t.Fatalf("cache validation P95 %.3fms exceeds 5ms", hitValidation)
	}
	if hitTotal >= 30 {
		t.Fatalf("cache hit total P95 %.3fms exceeds 30ms", hitTotal)
	}
	if extract >= 500 {
		t.Fatalf("extract P95 %.3fms exceeds 500ms", extract)
	}
	if reextract >= 500 {
		t.Fatalf("reextract P95 %.3fms exceeds 500ms", reextract)
	}

	emit.True("WALLET_ZIP_PERF_DETERMINISTIC")
	emit.Metric("WALLET_ZIP_CACHE_HIT_MS", hitValidation)
	emit.Metric("WALLET_ZIP_CACHE_HIT_TOTAL_P95_MS", hitTotal)
	emit.Metric("WALLET_ZIP_EXTRACT_MS", extract)
	emit.Metric("WALLET_ZIP_REEXTRACT_MS", reextract)
}

func measureP95(warmup, measured int, fn func(iteration int)) float64 {
	for i := 0; i < warmup; i++ {
		fn(-warmup + i)
	}
	samples := make([]float64, 0, measured)
	for i := 0; i < measured; i++ {
		start := time.Now()
		fn(i)
		samples = append(samples, float64(time.Since(start).Microseconds())/1000.0)
	}
	sortFloat64s(samples)
	index := int(float64(len(samples))*0.95 + 0.5)
	if index >= len(samples) {
		index = len(samples) - 1
	}
	return samples[index]
}

func sortFloat64s(values []float64) {
	for i := 1; i < len(values); i++ {
		value := values[i]
		j := i - 1
		for j >= 0 && values[j] > value {
			values[j+1] = values[j]
			j--
		}
		values[j+1] = value
	}
}
