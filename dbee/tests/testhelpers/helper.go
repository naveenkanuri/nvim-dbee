// Package testhelpers provides helpers for integration tests.
package testhelpers

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/kndndrj/nvim-dbee/dbee/core"
	"github.com/stretchr/testify/require"
	"github.com/testcontainers/testcontainers-go"
)

const (
	// eventBufferTime is a padding to let events come through (e.g. archived)
	eventBufferTime = 100 * time.Millisecond
	// eventTimeout is the maximum time to wait for an event to come through
	eventTimeout = 10 * time.Second
)

// errTimeOut is an error for when an event did not finish within the expected time.
var errTimeOut = fmt.Errorf("event did not finish within %v", eventTimeout)

// GetContainerProvider returns the container provider type to use for the tests.
// If we detect podman is available, we use it, otherwise we use docker.
func GetContainerProvider() testcontainers.ProviderType {
	if _, err := exec.LookPath("podman"); err == nil {
		fmt.Println("Podman detected. Remember to set TESTCONTAINERS_RYUK_CONTAINER_PRIVILEGED=true;")
		return testcontainers.ProviderPodman
	}
	return testcontainers.ProviderDocker
}

type probeResult struct {
	runtime  string
	provider testcontainers.ProviderType
	healthy  bool
	detail   string
}

// HealthyContainerRuntime returns a health-checked podman or docker provider.
// It preserves podman preference without letting a stopped podman shadow docker.
func HealthyContainerRuntime(ctx context.Context) (string, testcontainers.ProviderType, bool, string) {
	if envProvider := os.Getenv("LIVE_PG20_CONTAINER_PROVIDER"); envProvider != "" {
		runtimeName, provider, err := providerFromEnv(envProvider)
		if err != nil {
			return "", testcontainers.ProviderDocker, false, formatInvalidProvider(envProvider, err)
		}
		r := runtimeInfoOK(ctx, runtimeName, provider)
		if r.healthy {
			return r.runtime, r.provider, true, r.detail
		}
		if runtimeName == "podman" {
			return "", provider, false, formatNoRuntimeDetail(r, probeResult{runtime: "docker"})
		}
		return "", provider, false, formatNoRuntimeDetail(probeResult{runtime: "podman"}, r)
	}

	parent, cancel := context.WithCancel(ctx)
	defer cancel()

	results := make(chan probeResult, 2)
	go probeRuntime(parent, "podman", testcontainers.ProviderPodman, results)
	go probeRuntime(parent, "docker", testcontainers.ProviderDocker, results)

	var podman, docker probeResult
	for i := 0; i < 2; i++ {
		r := <-results
		switch r.runtime {
		case "podman":
			podman = r
			if r.healthy {
				cancel()
				return r.runtime, r.provider, true, r.detail
			}
			if docker.healthy {
				cancel()
				return docker.runtime, docker.provider, true, docker.detail
			}
		case "docker":
			docker = r
			if r.healthy {
				cancel()
				return r.runtime, r.provider, true, r.detail
			}
		}
	}
	if docker.healthy {
		cancel()
		return docker.runtime, docker.provider, true, docker.detail
	}
	return "", testcontainers.ProviderDocker, false, formatNoRuntimeDetail(podman, docker)
}

func providerFromEnv(value string) (string, testcontainers.ProviderType, error) {
	switch strings.ToLower(strings.TrimSpace(value)) {
	case "podman":
		return "podman", testcontainers.ProviderPodman, nil
	case "docker":
		return "docker", testcontainers.ProviderDocker, nil
	default:
		return "", testcontainers.ProviderDocker, fmt.Errorf("expected podman or docker")
	}
}

func probeRuntime(parent context.Context, runtime string, provider testcontainers.ProviderType, results chan<- probeResult) {
	results <- runtimeInfoOK(parent, runtime, provider)
}

func runtimeInfoOK(parent context.Context, binary string, provider testcontainers.ProviderType) probeResult {
	if _, err := exec.LookPath(binary); err != nil {
		return probeResult{
			runtime:  binary,
			provider: provider,
			detail:   "status: 127; stderr: binary-not-found",
		}
	}

	ctx, cancel := context.WithTimeout(parent, 5*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, binary, "info")
	var stderrBuf bytes.Buffer
	cmd.Stderr = &stderrBuf
	err := cmd.Run()
	stderr := normalizeProbeText(stderrBuf.String())
	if ctx.Err() == context.DeadlineExceeded {
		return probeResult{
			runtime:  binary,
			provider: provider,
			detail:   "status: 124; stderr: timeout after 5s",
		}
	}
	if err != nil {
		return probeResult{
			runtime:  binary,
			provider: provider,
			detail:   fmt.Sprintf("status: %s; stderr: %s", normalizeProbeResult(exitStatus(err)), stderr),
		}
	}
	return probeResult{
		runtime:  binary,
		provider: provider,
		healthy:  true,
		detail:   "status: 0; stderr: ",
	}
}

func normalizeProbeResult(rc int) string {
	switch {
	case rc == 0:
		return "healthy"
	case rc == 124:
		return "timeout after 5s"
	case rc == 127:
		return "binary-not-found"
	case rc >= 128:
		return fmt.Sprintf("signal-killed (rc=%d)", rc)
	default:
		return fmt.Sprintf("unhealthy (rc=%d)", rc)
	}
}

func exitStatus(err error) int {
	if err == nil {
		return 0
	}
	if exitErr, ok := err.(*exec.ExitError); ok {
		if rc := exitErr.ExitCode(); rc >= 0 {
			return rc
		}
		return 128
	}
	return 1
}

func formatNoRuntimeDetail(podman, docker probeResult) string {
	if podman.runtime == "" {
		podman.runtime = "podman"
	}
	if podman.detail == "" {
		podman.detail = "status: not-probed; stderr: provider override"
	}
	if docker.runtime == "" {
		docker.runtime = "docker"
	}
	if docker.detail == "" {
		docker.detail = "status: not-probed; stderr: provider override"
	}
	return fmt.Sprintf(
		"no healthy container runtime: tried podman info (%s) and docker info (%s); set LIVE_PG20_REQUIRED=0 to skip",
		podman.detail,
		docker.detail,
	)
}

func formatInvalidProvider(value string, err error) string {
	return fmt.Sprintf("invalid LIVE_PG20_CONTAINER_PROVIDER=%q: %s", value, err)
}

func normalizeProbeText(value string) string {
	value = strings.TrimSpace(value)
	value = strings.ReplaceAll(value, "\r", " ")
	value = strings.ReplaceAll(value, "\n", " ")
	return strings.TrimSpace(value)
}

// GetResult is a helper function for calling the Execute method on a driver
// and waiting for the result to be available.
func GetResult(t *testing.T, d *core.Connection, query string) ([]core.Row, core.Header, []core.CallState, error) {
	t.Helper()

	var result *core.Result
	outStates := make([]core.CallState, 0)
	outRows := make([]core.Row, 0)

	call := d.Execute(query, func(state core.CallState, c *core.Call) {
		outStates = append(outStates, state)

		var err error
		if state == core.CallStateArchived || state == core.CallStateRetrieving {
			result, err = c.GetResult()
			require.NoError(t, err, "failed getting result with %s, err: %s", state, c.Err())
			outRows, err = result.Rows(0, result.Len())
			require.NoError(t, err, "failed getting rows with %s, err: %s", state, c.Err())
		}
	})

	select {
	case <-call.Done():
		time.Sleep(eventBufferTime)
		require.NotNil(t, result, call.Err())
		return outRows, result.Header(), outStates, nil

	case <-time.After(eventTimeout):
		return nil, nil, nil, errTimeOut
	}
}

// GetResultWithCancel is a helper function for calling the Execute method on a driver
// and canceling the call after the first state is received.
func GetResultWithCancel(t *testing.T, d *core.Connection, query string) (*core.Result, []core.CallState, error) {
	t.Helper()

	var (
		outResult *core.Result
		outErr    error
	)
	outStates := make([]core.CallState, 0)

	call := d.Execute(query, func(cs core.CallState, c *core.Call) {
		outStates = append(outStates, cs)
		c.Cancel()
	})

	select {
	case <-call.Done():
		time.Sleep(eventBufferTime)
		return outResult, outStates, outErr
	case <-time.After(eventTimeout):
		return nil, nil, errTimeOut
	}
}

// GetSchemas returns a list of schema names from the given structure.
func GetSchemas(t *testing.T, structure []*core.Structure) []string {
	t.Helper()

	schemas := make([]string, 0)
	for _, s := range structure {
		if s.Name == s.Schema {
			schemas = append(schemas, s.Name)
			continue
		}
	}
	return schemas
}

// GetModels returns a list of model names (views, table, etc) from the given structure.
func GetModels(t *testing.T, structure []*core.Structure, modelType core.StructureType) []string {
	t.Helper()

	out := make([]string, 0)
	for _, s := range structure {
		for _, c := range s.Children {
			if c.Type == modelType {
				out = append(out, c.Name)
				continue
			}
		}
	}
	return out
}

// GetTestDataPath returns the path to the testdata directory.
func GetTestDataPath() (string, error) {
	_, currentFile, _, ok := runtime.Caller(0)
	if !ok {
		return "", fmt.Errorf("failed to get current file path")
	}

	return filepath.Join(filepath.Dir(currentFile), "../testdata"), nil
}

// GetTestDataFile returns a file from the testdata directory.
func GetTestDataFile(filename string) (*os.File, error) {
	testDataPath, err := GetTestDataPath()
	if err != nil {
		return nil, err
	}

	path := filepath.Join(testDataPath, filename)
	return os.Open(path)
}
