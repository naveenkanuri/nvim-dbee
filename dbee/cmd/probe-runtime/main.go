package main

import (
	"context"
	"fmt"
	"os"
	"strings"
	"time"

	th "github.com/kndndrj/nvim-dbee/dbee/tests/testhelpers"
)

func main() {
	start := time.Now()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	if envProvider := os.Getenv("LIVE_PG20_CONTAINER_PROVIDER"); envProvider != "" {
		switch strings.ToLower(strings.TrimSpace(envProvider)) {
		case "podman", "docker":
		default:
			emit("internal_error", "none", 0, fmt.Sprintf("invalid LIVE_PG20_CONTAINER_PROVIDER=%q: expected podman or docker", envProvider))
			os.Exit(2)
		}
	}

	name, _, ok, detail := th.HealthyContainerRuntime(ctx)
	durationMS := time.Since(start).Milliseconds()
	if ok {
		emit("ok", name, durationMS, detail)
		os.Exit(0)
	}
	emit("no_runtime", "none", durationMS, detail)
	os.Exit(1)
}

func emit(status, provider string, durationMS int64, detail string) {
	fmt.Printf("STATUS=%s|PROVIDER=%s|DURATION_MS=%d|DETAIL=%s\n", status, provider, durationMS, sanitize(detail))
}

func sanitize(value string) string {
	value = strings.TrimSpace(value)
	replacer := strings.NewReplacer("\r", " ", "\n", " ", "\t", " ", "|", "/")
	return strings.Join(strings.Fields(replacer.Replace(value)), " ")
}
