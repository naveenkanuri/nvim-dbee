package core

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestClassifyCallError(t *testing.T) {
	t.Parallel()

	tests := []struct {
		name string
		err  error
		want string
	}{
		{
			name: "nil",
			err:  nil,
			want: "",
		},
		{
			name: "context canceled",
			err:  context.Canceled,
			want: callErrorKindCanceled,
		},
		{
			name: "deadline exceeded",
			err:  context.DeadlineExceeded,
			want: callErrorKindTimeout,
		},
		{
			name: "oracle timeout pattern",
			err:  errors.New("ORA-12170: TNS:Connect timeout occurred"),
			want: callErrorKindTimeout,
		},
		{
			name: "next row timeout pattern",
			err:  errors.New("next row timeout"),
			want: callErrorKindTimeout,
		},
		{
			name: "oracle canceled pattern",
			err:  errors.New("ORA-01013: user requested cancel of current operation"),
			want: callErrorKindCanceled,
		},
		{
			name: "disconnected pattern",
			err:  errors.New("dial tcp: lookup host: no such host"),
			want: callErrorKindDisconnected,
		},
		{
			name: "lookup pattern without dial tcp prefix",
			err:  errors.New("lookup db.internal: no such host"),
			want: callErrorKindDisconnected,
		},
		{
			name: "unknown",
			err:  errors.New("query failed"),
			want: callErrorKindUnknown,
		},
	}

	for _, tt := range tests {
		tt := tt
		t.Run(tt.name, func(t *testing.T) {
			t.Parallel()
			got := classifyCallError(tt.err)
			require.Equal(t, tt.want, got)
		})
	}
}

func TestCallUnmarshalJSON_InferLegacyErrorKind(t *testing.T) {
	t.Parallel()

	var c Call
	err := json.Unmarshal([]byte(`{
	  "id":"call_1",
	  "query":"SELECT 1",
	  "state":"executing_failed",
	  "time_taken_us":123,
	  "timestamp_us":456,
	  "error":"dial tcp: lookup db.internal: no such host"
	}`), &c)
	require.NoError(t, err)
	require.Equal(t, callErrorKindDisconnected, c.ErrorKind())
}

func TestCallUnmarshalJSON_PreserveProvidedErrorKind(t *testing.T) {
	t.Parallel()

	var c Call
	err := json.Unmarshal([]byte(`{
	  "id":"call_2",
	  "query":"SELECT 1",
	  "state":"executing_failed",
	  "time_taken_us":123,
	  "timestamp_us":456,
	  "error":"something",
	  "error_kind":"timeout"
	}`), &c)
	require.NoError(t, err)
	require.Equal(t, callErrorKindTimeout, c.ErrorKind())
}
