package testhelpers

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/kndndrj/nvim-dbee/dbee/adapters"
	"github.com/kndndrj/nvim-dbee/dbee/core"
	tc "github.com/testcontainers/testcontainers-go"
	tcpsql "github.com/testcontainers/testcontainers-go/modules/postgres"
)

const DefaultPostgresRichMetadataImage = "postgres:16-alpine@sha256:4e6e670bb069649261c9c18031f0aded7bb249a5b6664ddec29c013a89310d50"

type PostgresRichMetadataContainer struct {
	*tcpsql.PostgresContainer
	ConnURL     string
	Driver      *core.Connection
	RuntimeName string
}

func NewPostgresRichMetadataContainer(parent context.Context, params *core.ConnectionParams) (*PostgresRichMetadataContainer, error) {
	runtimeName, provider, ok, detail := HealthyContainerRuntime(parent)
	if !ok {
		return nil, fmt.Errorf("%s", detail)
	}
	if runtimeName == "podman" {
		if err := configurePodmanTestcontainersEnv(parent); err != nil {
			return nil, err
		}
	}

	seedFile, err := GetTestDataFile("postgres_rich_metadata_seed.sql")
	if err != nil {
		return nil, err
	}
	defer seedFile.Close()

	image := os.Getenv("LIVE_PG20_POSTGRES_IMAGE")
	if image == "" {
		image = DefaultPostgresRichMetadataImage
	}

	ctx, cancel := context.WithTimeout(parent, 10*time.Minute)
	defer cancel()

	ctr, err := tcpsql.Run(
		ctx,
		image,
		tcpsql.BasicWaitStrategies(),
		tc.CustomizeRequest(tc.GenericContainerRequest{
			ProviderType: provider,
		}),
		tcpsql.WithInitScripts(seedFile.Name()),
		tcpsql.WithDatabase("dev"),
	)
	if err != nil {
		return nil, err
	}

	connURL, err := ctr.ConnectionString(ctx, "sslmode=disable")
	if err != nil {
		_ = ctr.Terminate(ctx)
		return nil, err
	}

	if params == nil {
		params = &core.ConnectionParams{}
	}
	if params.Type == "" {
		params.Type = "postgres"
	}
	if params.URL == "" {
		params.URL = connURL
	}

	driver, err := adapters.NewConnection(params)
	if err != nil {
		_ = ctr.Terminate(ctx)
		return nil, err
	}

	return &PostgresRichMetadataContainer{
		PostgresContainer: ctr,
		ConnURL:           connURL,
		Driver:            driver,
		RuntimeName:       runtimeName,
	}, nil
}

func configurePodmanTestcontainersEnv(ctx context.Context) error {
	if os.Getenv("TESTCONTAINERS_RYUK_CONTAINER_PRIVILEGED") == "" {
		if err := os.Setenv("TESTCONTAINERS_RYUK_CONTAINER_PRIVILEGED", "true"); err != nil {
			return err
		}
	}
	if os.Getenv("TESTCONTAINERS_RYUK_DISABLED") == "" {
		if err := os.Setenv("TESTCONTAINERS_RYUK_DISABLED", "true"); err != nil {
			return err
		}
	}
	if os.Getenv("DOCKER_HOST") != "" {
		return nil
	}

	socket, err := discoverPodmanAPISocket(ctx)
	if err != nil {
		return err
	}
	if err := os.Setenv("DOCKER_HOST", "unix://"+socket); err != nil {
		return err
	}
	if os.Getenv("TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE") == "" {
		if err := os.Setenv("TESTCONTAINERS_DOCKER_SOCKET_OVERRIDE", socket); err != nil {
			return err
		}
	}
	return nil
}

func discoverPodmanAPISocket(ctx context.Context) (string, error) {
	if socket, ok := podmanSocketFromInfo(ctx); ok {
		return socket, nil
	}
	if socket, ok := podmanSocketFromConnections(ctx); ok {
		return socket, nil
	}
	matches, err := filepath.Glob(filepath.Join(os.TempDir(), "podman", "*-api.sock"))
	if err == nil {
		for _, match := range matches {
			if socketExists(match) {
				return match, nil
			}
		}
	}
	return "", fmt.Errorf("podman runtime is healthy, but no local podman API socket was found for testcontainers")
}

func podmanSocketFromInfo(ctx context.Context) (string, bool) {
	out, err := runBoundedPodman(ctx, "info", "--format", "{{.Host.RemoteSocket.Path}}")
	if err != nil {
		return "", false
	}
	socket := strings.TrimSpace(string(out))
	socket = strings.TrimPrefix(socket, "unix://")
	if socketExists(socket) {
		return socket, true
	}
	return "", false
}

type podmanConnection struct {
	Name      string `json:"Name"`
	URI       string `json:"URI"`
	Default   bool   `json:"Default"`
	ReadWrite bool   `json:"ReadWrite"`
}

func podmanSocketFromConnections(ctx context.Context) (string, bool) {
	out, err := runBoundedPodman(ctx, "system", "connection", "list", "--format=json")
	if err != nil {
		return "", false
	}
	var connections []podmanConnection
	if err := json.Unmarshal(out, &connections); err != nil {
		return "", false
	}
	for _, conn := range connections {
		if !conn.Default && !conn.ReadWrite {
			continue
		}
		if strings.HasPrefix(conn.URI, "unix://") {
			socket := strings.TrimPrefix(conn.URI, "unix://")
			if socketExists(socket) {
				return socket, true
			}
		}
		if conn.Name != "" {
			socket := filepath.Join(os.TempDir(), "podman", conn.Name+"-api.sock")
			if socketExists(socket) {
				return socket, true
			}
		}
	}
	return "", false
}

func runBoundedPodman(parent context.Context, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(parent, 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "podman", args...)
	return cmd.Output()
}

func socketExists(path string) bool {
	if path == "" {
		return false
	}
	info, err := os.Stat(path)
	return err == nil && !info.IsDir()
}
