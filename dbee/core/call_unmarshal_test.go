package core

import (
	"encoding/json"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/stretchr/testify/require"
)

func TestCallUnmarshalJSON_ArchivedStateWithoutArchiveDirFallsBackToUnknown(t *testing.T) {
	id := CallID(fmt.Sprintf("unmarshal-no-archive-%d", time.Now().UnixNano()))
	path := archiveDir(id)
	require.NoError(t, os.RemoveAll(path))
	t.Cleanup(func() { _ = os.RemoveAll(path) })

	var c Call
	err := json.Unmarshal([]byte(fmt.Sprintf(`{
	  "id":"%s",
	  "query":"SELECT 1",
	  "state":"archived",
	  "time_taken_us":123,
	  "timestamp_us":456
	}`, id)), &c)
	require.NoError(t, err)
	require.Equal(t, CallStateUnknown, c.GetState())
}

func TestCallUnmarshalJSON_ArchivedStateWithArchiveDirStaysArchived(t *testing.T) {
	id := CallID(fmt.Sprintf("unmarshal-with-archive-%d", time.Now().UnixNano()))
	path := archiveDir(id)
	require.NoError(t, os.RemoveAll(path))
	require.NoError(t, os.MkdirAll(path, os.ModePerm))
	t.Cleanup(func() { _ = os.RemoveAll(path) })

	var c Call
	err := json.Unmarshal([]byte(fmt.Sprintf(`{
	  "id":"%s",
	  "query":"SELECT 1",
	  "state":"archived",
	  "time_taken_us":123,
	  "timestamp_us":456
	}`, id)), &c)
	require.NoError(t, err)
	require.Equal(t, CallStateArchived, c.GetState())
}
