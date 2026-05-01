package adapters

import (
	"archive/zip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"sync/atomic"
	"time"

	"github.com/kndndrj/nvim-dbee/dbee/core"
)

const (
	oracleWalletMarkerFile = ".nvim-dbee-wallet.json"
	oracleWalletHashPrefix = 12
	oracleWalletFileCap    = int64(10 * 1024 * 1024)
	oracleWalletTotalCap   = int64(50 * 1024 * 1024)
)

var oracleWalletRequiredFiles = []string{"cwallet.sso", "tnsnames.ora", "sqlnet.ora"}

var oracleWalletAutoExtract atomic.Bool

const (
	oracleWalletLockWait       = 30 * time.Second
	oracleWalletLockStaleAfter = 2 * time.Minute
	oracleWalletLockPollStart  = 10 * time.Millisecond
	oracleWalletLockPollMax    = 100 * time.Millisecond
)

func init() {
	oracleWalletAutoExtract.Store(true)
}

type oracleWalletMarker struct {
	FullHash           string `json:"full_hash"`
	SourceMTimeUnixNS  int64  `json:"source_mtime_unix_ns"`
	ExtractedFileCount int    `json:"extracted_file_count"`
}

type walletQueryParam struct {
	key   string
	value string
}

func SetOracleWalletAutoExtract(enabled bool) {
	oracleWalletAutoExtract.Store(enabled)
}

func OracleWalletAutoExtractEnabled() bool {
	return oracleWalletAutoExtract.Load()
}

func ClearOracleWalletCache() error {
	root, err := oracleWalletCacheRoot()
	if err != nil {
		return err
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return fmt.Errorf("read wallet cache: %w", err)
	}

	activeLocks := false
	for _, entry := range entries {
		if entry.IsDir() && strings.HasSuffix(entry.Name(), ".lock") {
			activeLocks = true
			break
		}
	}

	for _, entry := range entries {
		name := entry.Name()
		p := filepath.Join(root, name)
		if entry.IsDir() && strings.HasSuffix(name, ".lock") {
			continue
		}
		if entry.IsDir() && strings.HasPrefix(name, ".extract-") && activeLocks {
			continue
		}
		if entry.IsDir() && isOracleWalletHashPrefix(name) {
			unlock, acquired, err := tryAcquireOracleWalletHashLock(root, name)
			if err != nil {
				return err
			}
			if !acquired {
				continue
			}
			removeErr := os.RemoveAll(p)
			unlock()
			if removeErr != nil {
				return fmt.Errorf("remove wallet cache entry %s: %w", name, removeErr)
			}
			continue
		}
		if err := os.RemoveAll(p); err != nil {
			return fmt.Errorf("remove wallet cache entry %s: %w", name, err)
		}
	}
	return nil
}

func prepareOracleWalletURL(rawURL string) (string, *core.WalletAutoExtractMetadata, error) {
	parsed, err := url.Parse(rawURL)
	if err != nil {
		return "", nil, fmt.Errorf("parse oracle URL: %w", err)
	}

	wallet, found, err := findWalletQueryParam(parsed.RawQuery)
	if err != nil {
		return "", nil, err
	}
	if !found || strings.TrimSpace(wallet.value) == "" {
		return rawURL, nil, nil
	}
	if !oracleWalletAutoExtract.Load() {
		return rawURL, nil, nil
	}

	walletPath := expandHomePath(wallet.value)
	isZip, err := isOracleWalletZipPath(walletPath)
	if err != nil {
		return "", nil, err
	}
	if !isZip {
		return rawURL, nil, nil
	}

	extractedDir, meta, err := resolveOracleWalletZip(walletPath)
	if err != nil {
		return "", nil, err
	}

	parsed.RawQuery = rewriteWalletRawQuery(parsed.RawQuery, wallet.key, extractedDir)
	return parsed.String(), meta, nil
}

func findWalletQueryParam(rawQuery string) (walletQueryParam, bool, error) {
	var found *walletQueryParam
	for _, part := range strings.FieldsFunc(rawQuery, func(r rune) bool { return r == '&' }) {
		if part == "" {
			continue
		}
		rawKey, rawValue, hasValue := strings.Cut(part, "=")
		key, err := url.QueryUnescape(rawKey)
		if err != nil {
			return walletQueryParam{}, false, fmt.Errorf("decode wallet query key: %w", err)
		}
		if !strings.EqualFold(key, "wallet") {
			continue
		}
		value := ""
		if hasValue {
			value, err = url.QueryUnescape(rawValue)
			if err != nil {
				return walletQueryParam{}, false, fmt.Errorf("decode wallet query value: %w", err)
			}
		}
		if found == nil {
			found = &walletQueryParam{key: key, value: value}
			continue
		}
		if found.value != value {
			return walletQueryParam{}, false, fmt.Errorf("conflicting wallet query parameters")
		}
	}
	if found == nil {
		return walletQueryParam{}, false, nil
	}
	return *found, true, nil
}

func rewriteWalletRawQuery(rawQuery, originalKey, walletPath string) string {
	parts := strings.FieldsFunc(rawQuery, func(r rune) bool { return r == '&' })
	out := make([]string, 0, len(parts))
	wroteWallet := false
	for _, part := range parts {
		if part == "" {
			continue
		}
		rawKey, _, _ := strings.Cut(part, "=")
		key, err := url.QueryUnescape(rawKey)
		if err == nil && strings.EqualFold(key, "wallet") {
			if wroteWallet {
				continue
			}
			wroteWallet = true
			out = append(out, url.QueryEscape(originalKey)+"="+url.QueryEscape(walletPath))
			continue
		}
		out = append(out, part)
	}
	if !wroteWallet {
		out = append(out, url.QueryEscape(originalKey)+"="+url.QueryEscape(walletPath))
	}
	return strings.Join(out, "&")
}

func expandHomePath(p string) string {
	if p == "~" {
		if home, err := os.UserHomeDir(); err == nil {
			return home
		}
	}
	if strings.HasPrefix(p, "~/") || strings.HasPrefix(p, `~\`) {
		if home, err := os.UserHomeDir(); err == nil {
			return filepath.Join(home, p[2:])
		}
	}
	return p
}

func isOracleWalletZipPath(p string) (bool, error) {
	zipExt := strings.EqualFold(filepath.Ext(p), ".zip")
	info, err := os.Stat(p)
	if err != nil {
		if zipExt {
			return false, fmt.Errorf("stat wallet zip: %w", err)
		}
		return false, nil
	}
	if info.IsDir() {
		return false, nil
	}
	if zipExt {
		return true, nil
	}
	return fileHasZipMagic(p)
}

func fileHasZipMagic(p string) (bool, error) {
	f, err := os.Open(p)
	if err != nil {
		return false, fmt.Errorf("open wallet file: %w", err)
	}
	defer f.Close()

	var header [4]byte
	n, err := io.ReadFull(f, header[:])
	if err != nil && !errors.Is(err, io.EOF) && !errors.Is(err, io.ErrUnexpectedEOF) {
		return false, fmt.Errorf("read wallet file header: %w", err)
	}
	if n < 4 {
		return false, nil
	}
	return header == [4]byte{'P', 'K', 0x03, 0x04} ||
		header == [4]byte{'P', 'K', 0x05, 0x06} ||
		header == [4]byte{'P', 'K', 0x07, 0x08}, nil
}

func oracleWalletCacheRoot() (string, error) {
	if xdg := os.Getenv("XDG_CACHE_HOME"); xdg != "" {
		return filepath.Join(xdg, "nvim-dbee", "wallets"), nil
	}
	root, err := os.UserCacheDir()
	if err != nil {
		return "", fmt.Errorf("resolve user cache dir: %w", err)
	}
	return filepath.Join(root, "nvim-dbee", "wallets"), nil
}

func resolveOracleWalletZip(zipPath string) (string, *core.WalletAutoExtractMetadata, error) {
	info, err := os.Stat(zipPath)
	if err != nil {
		return "", nil, fmt.Errorf("stat wallet zip: %w", err)
	}
	if info.IsDir() {
		return zipPath, nil, nil
	}

	fullHash, err := hashFileSHA256(zipPath)
	if err != nil {
		return "", nil, err
	}
	prefix := fullHash[:oracleWalletHashPrefix]
	root, err := oracleWalletCacheRoot()
	if err != nil {
		return "", nil, err
	}
	finalDir := filepath.Join(root, prefix)

	unlock, err := acquireOracleWalletHashLock(root, prefix)
	if err != nil {
		return "", nil, err
	}
	defer unlock()

	if marker, ok := validOracleWalletCache(finalDir, fullHash, info.ModTime()); ok {
		return finalDir, &core.WalletAutoExtractMetadata{
			HashPrefix: prefix,
			CacheHit:   true,
			Extracted:  false,
			FileCount:  marker.ExtractedFileCount,
		}, nil
	}

	fileCount, err := extractOracleWalletZip(zipPath, root, finalDir, fullHash, info.ModTime())
	if err != nil {
		return "", nil, err
	}

	return finalDir, &core.WalletAutoExtractMetadata{
		HashPrefix: prefix,
		CacheHit:   false,
		Extracted:  true,
		FileCount:  fileCount,
	}, nil
}

func acquireOracleWalletHashLock(root, prefix string) (func(), error) {
	if err := os.MkdirAll(root, 0o700); err != nil {
		return nil, fmt.Errorf("create wallet cache root: %w", err)
	}
	_ = os.Chmod(root, 0o700)

	lockDir := filepath.Join(root, prefix+".lock")
	deadline := time.Now().Add(oracleWalletLockWait)
	delay := oracleWalletLockPollStart
	for {
		if err := os.Mkdir(lockDir, 0o700); err == nil {
			_ = os.Chmod(lockDir, 0o700)
			return func() {
				_ = os.Remove(lockDir)
			}, nil
		} else if !os.IsExist(err) {
			return nil, fmt.Errorf("acquire wallet cache lock: %w", err)
		}

		now := time.Now()
		if oracleWalletLockIsStale(lockDir, now) {
			_ = os.RemoveAll(lockDir)
			continue
		}
		if now.After(deadline) {
			return nil, fmt.Errorf("timeout acquiring wallet cache lock for %s", prefix)
		}

		time.Sleep(delay)
		if delay < oracleWalletLockPollMax {
			delay *= 2
			if delay > oracleWalletLockPollMax {
				delay = oracleWalletLockPollMax
			}
		}
	}
}

func tryAcquireOracleWalletHashLock(root, prefix string) (func(), bool, error) {
	lockDir := filepath.Join(root, prefix+".lock")
	if err := os.Mkdir(lockDir, 0o700); err == nil {
		_ = os.Chmod(lockDir, 0o700)
		return func() {
			_ = os.Remove(lockDir)
		}, true, nil
	} else if os.IsExist(err) {
		return nil, false, nil
	} else {
		return nil, false, fmt.Errorf("acquire wallet cache lock: %w", err)
	}
}

func oracleWalletLockIsStale(lockDir string, now time.Time) bool {
	info, err := os.Stat(lockDir)
	if err != nil {
		return false
	}
	return now.Sub(info.ModTime()) > oracleWalletLockStaleAfter
}

func isOracleWalletHashPrefix(name string) bool {
	if len(name) != oracleWalletHashPrefix {
		return false
	}
	for i := 0; i < len(name); i++ {
		c := name[i]
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return false
		}
	}
	return true
}

func hashFileSHA256(p string) (string, error) {
	f, err := os.Open(p)
	if err != nil {
		return "", fmt.Errorf("open wallet zip for hash: %w", err)
	}
	defer f.Close()

	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", fmt.Errorf("hash wallet zip: %w", err)
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func validOracleWalletCache(dir, fullHash string, sourceMTime time.Time) (oracleWalletMarker, bool) {
	marker, err := readOracleWalletMarker(dir)
	if err != nil {
		return oracleWalletMarker{}, false
	}
	if marker.FullHash != fullHash {
		return oracleWalletMarker{}, false
	}
	if time.Unix(0, marker.SourceMTimeUnixNS).Before(sourceMTime) {
		return oracleWalletMarker{}, false
	}
	if err := validateOracleWalletDir(dir); err != nil {
		return oracleWalletMarker{}, false
	}
	return marker, true
}

func readOracleWalletMarker(dir string) (oracleWalletMarker, error) {
	content, err := os.ReadFile(filepath.Join(dir, oracleWalletMarkerFile))
	if err != nil {
		return oracleWalletMarker{}, err
	}
	var marker oracleWalletMarker
	if err := json.Unmarshal(content, &marker); err != nil {
		return oracleWalletMarker{}, err
	}
	if marker.FullHash == "" || marker.ExtractedFileCount < len(oracleWalletRequiredFiles) {
		return oracleWalletMarker{}, fmt.Errorf("invalid wallet cache marker")
	}
	return marker, nil
}

func extractOracleWalletZip(zipPath, root, finalDir, fullHash string, sourceMTime time.Time) (int, error) {
	if err := os.MkdirAll(root, 0o700); err != nil {
		return 0, fmt.Errorf("create wallet cache root: %w", err)
	}
	_ = os.Chmod(root, 0o700)

	tmpDir, err := os.MkdirTemp(root, ".extract-*")
	if err != nil {
		return 0, fmt.Errorf("create wallet extraction temp dir: %w", err)
	}
	tmpKept := false
	defer func() {
		if !tmpKept {
			_ = os.RemoveAll(tmpDir)
		}
	}()
	_ = os.Chmod(tmpDir, 0o700)

	if err := extractZipEntries(zipPath, tmpDir); err != nil {
		return 0, err
	}
	if err := validateOracleWalletDir(tmpDir); err != nil {
		return 0, err
	}
	fileCount, err := countRegularFiles(tmpDir)
	if err != nil {
		return 0, err
	}
	if err := writeOracleWalletMarker(tmpDir, oracleWalletMarker{
		FullHash:           fullHash,
		SourceMTimeUnixNS:  sourceMTime.UnixNano(),
		ExtractedFileCount: fileCount,
	}); err != nil {
		return 0, err
	}
	if err := validateOracleWalletDir(tmpDir); err != nil {
		return 0, err
	}

	if err := os.RemoveAll(finalDir); err != nil {
		return 0, fmt.Errorf("replace stale wallet cache: %w", err)
	}
	if err := os.Rename(tmpDir, finalDir); err != nil {
		if _, ok := validOracleWalletCache(finalDir, fullHash, sourceMTime); ok {
			return fileCount, nil
		}
		return 0, fmt.Errorf("publish wallet cache: %w", err)
	}
	tmpKept = true
	_ = os.Chmod(finalDir, 0o700)
	if err := validateOracleWalletDir(finalDir); err != nil {
		return 0, err
	}
	return fileCount, nil
}

func extractZipEntries(zipPath, destRoot string) error {
	reader, err := zip.OpenReader(zipPath)
	if err != nil {
		return fmt.Errorf("open wallet zip: %w", err)
	}
	defer reader.Close()

	var total int64
	for _, entry := range reader.File {
		cleanName, err := safeZipEntryName(entry.Name)
		if err != nil {
			return err
		}
		mode := entry.FileInfo().Mode()
		if mode&os.ModeSymlink != 0 {
			return fmt.Errorf("unsafe wallet zip entry %q: symlinks are not allowed", entry.Name)
		}
		if entry.FileInfo().IsDir() {
			if err := mkdirSafeZipDir(destRoot, cleanName); err != nil {
				return err
			}
			continue
		}
		if !mode.IsRegular() {
			return fmt.Errorf("unsafe wallet zip entry %q: only regular files are allowed", entry.Name)
		}
		if entry.UncompressedSize64 > uint64(oracleWalletFileCap) {
			return fmt.Errorf("unsafe wallet zip entry %q: file exceeds 10 MiB", entry.Name)
		}
		if total+int64(entry.UncompressedSize64) > oracleWalletTotalCap {
			return fmt.Errorf("unsafe wallet zip: total extracted size exceeds 50 MiB")
		}
		copied, err := extractZipFile(entry, destRoot, cleanName)
		if err != nil {
			return err
		}
		if copied > oracleWalletFileCap {
			return fmt.Errorf("unsafe wallet zip entry %q: copied file exceeds 10 MiB", entry.Name)
		}
		total += copied
		if total > oracleWalletTotalCap {
			return fmt.Errorf("unsafe wallet zip: total copied size exceeds 50 MiB")
		}
	}
	return nil
}

func safeZipEntryName(name string) (string, error) {
	normalized := strings.ReplaceAll(name, "\\", "/")
	if normalized == "" || normalized == "." {
		return "", fmt.Errorf("unsafe wallet zip entry: empty path")
	}
	if strings.HasPrefix(normalized, "/") || filepath.IsAbs(normalized) || hasWindowsDrivePrefix(normalized) {
		return "", fmt.Errorf("unsafe wallet zip entry %q: absolute paths are not allowed", name)
	}
	cleanName := path.Clean(normalized)
	if cleanName == "." || cleanName == ".." || strings.HasPrefix(cleanName, "../") {
		return "", fmt.Errorf("unsafe wallet zip entry %q: path traversal is not allowed", name)
	}
	return cleanName, nil
}

func hasWindowsDrivePrefix(name string) bool {
	if len(name) < 2 {
		return false
	}
	first := name[0]
	return name[1] == ':' && ((first >= 'A' && first <= 'Z') || (first >= 'a' && first <= 'z'))
}

func safeZipDestination(root, cleanName string) (string, error) {
	dest := filepath.Join(root, filepath.FromSlash(cleanName))
	rootAbs, err := filepath.Abs(root)
	if err != nil {
		return "", err
	}
	destAbs, err := filepath.Abs(dest)
	if err != nil {
		return "", err
	}
	if destAbs != rootAbs && !strings.HasPrefix(destAbs, rootAbs+string(os.PathSeparator)) {
		return "", fmt.Errorf("unsafe wallet zip entry %q: outside extraction root", cleanName)
	}
	return destAbs, nil
}

func mkdirSafeZipDir(root, cleanName string) error {
	dest, err := safeZipDestination(root, cleanName)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(dest, 0o700); err != nil {
		return fmt.Errorf("create wallet zip directory: %w", err)
	}
	return os.Chmod(dest, 0o700)
}

func extractZipFile(entry *zip.File, root, cleanName string) (int64, error) {
	dest, err := safeZipDestination(root, cleanName)
	if err != nil {
		return 0, err
	}
	if err := os.MkdirAll(filepath.Dir(dest), 0o700); err != nil {
		return 0, fmt.Errorf("create wallet zip parent directory: %w", err)
	}
	src, err := entry.Open()
	if err != nil {
		return 0, fmt.Errorf("open wallet zip entry %q: %w", entry.Name, err)
	}
	defer src.Close()

	out, err := os.OpenFile(dest, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o600)
	if err != nil {
		return 0, fmt.Errorf("create wallet cache file: %w", err)
	}
	copied, copyErr := io.Copy(out, io.LimitReader(src, oracleWalletFileCap+1))
	closeErr := out.Close()
	if copyErr != nil {
		return copied, fmt.Errorf("extract wallet zip entry %q: %w", entry.Name, copyErr)
	}
	if closeErr != nil {
		return copied, fmt.Errorf("close wallet cache file: %w", closeErr)
	}
	_ = os.Chmod(dest, 0o600)
	return copied, nil
}

func validateOracleWalletDir(dir string) error {
	var missing []string
	for _, required := range oracleWalletRequiredFiles {
		info, err := os.Stat(filepath.Join(dir, required))
		if err != nil || info.IsDir() {
			missing = append(missing, required)
		}
	}
	if len(missing) > 0 {
		sort.Strings(missing)
		return fmt.Errorf("wallet cache missing required file(s): %s", strings.Join(missing, ", "))
	}
	return nil
}

func countRegularFiles(dir string) (int, error) {
	count := 0
	err := filepath.WalkDir(dir, func(p string, d os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.Type().IsRegular() {
			count++
		}
		return nil
	})
	if err != nil {
		return 0, fmt.Errorf("count wallet cache files: %w", err)
	}
	return count, nil
}

func writeOracleWalletMarker(dir string, marker oracleWalletMarker) error {
	content, err := json.Marshal(marker)
	if err != nil {
		return fmt.Errorf("encode wallet cache marker: %w", err)
	}
	p := filepath.Join(dir, oracleWalletMarkerFile)
	if err := os.WriteFile(p, content, 0o600); err != nil {
		return fmt.Errorf("write wallet cache marker: %w", err)
	}
	return os.Chmod(p, 0o600)
}

func walletPermissionsLocked(dir string) bool {
	if runtime.GOOS == "windows" {
		return true
	}
	info, err := os.Stat(dir)
	if err != nil || info.Mode().Perm() != 0o700 {
		return false
	}
	ok := true
	_ = filepath.WalkDir(dir, func(p string, d os.DirEntry, err error) error {
		if err != nil || !d.Type().IsRegular() {
			return nil
		}
		info, statErr := d.Info()
		if statErr != nil || info.Mode().Perm() != 0o600 {
			ok = false
		}
		return nil
	})
	return ok
}
