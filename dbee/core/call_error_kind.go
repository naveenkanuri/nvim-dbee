package core

import (
	"context"
	"errors"
	"strings"
)

const (
	callErrorKindUnknown      = "unknown"
	callErrorKindDisconnected = "disconnected"
	callErrorKindTimeout      = "timeout"
	callErrorKindCanceled     = "canceled"
)

var timeoutErrorPatterns = []string{
	"deadline exceeded",
	// Intentionally broad so we classify driver- and network-surfaced timeout text.
	"timed out",
	"timeout",
	"i/o timeout",
	"next row timeout",
	"ora-12170",
}

var disconnectedErrorPatterns = []string{
	"dial tcp",
	// keep trailing space so we avoid matching unrelated words containing "lookup"
	"lookup ",
	"no such host",
	"connection refused",
	"connection reset by peer",
	"network is unreachable",
	"broken pipe",
	"driver: bad connection",
	"failed to get connection",
	"ora-03113",
	"ora-03114",
	"ora-12541",
	"ora-12514",
	"ora-12545",
	"end-of-file on communication channel",
}

var canceledErrorPatterns = []string{
	"context canceled",
	"operation was canceled",
	"operation was cancelled",
	"ora-01013",
}

func hasErrorPattern(lowerMsg string, patterns []string) bool {
	for _, p := range patterns {
		if strings.Contains(lowerMsg, p) {
			return true
		}
	}
	return false
}

func classifyCallError(err error) string {
	if err == nil {
		return ""
	}

	if errors.Is(err, context.Canceled) {
		return callErrorKindCanceled
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return callErrorKindTimeout
	}

	msg := strings.ToLower(err.Error())
	if hasErrorPattern(msg, canceledErrorPatterns) {
		return callErrorKindCanceled
	}
	if hasErrorPattern(msg, timeoutErrorPatterns) {
		return callErrorKindTimeout
	}
	if hasErrorPattern(msg, disconnectedErrorPatterns) {
		return callErrorKindDisconnected
	}

	return callErrorKindUnknown
}
