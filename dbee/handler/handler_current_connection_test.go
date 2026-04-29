package handler

import (
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/kndndrj/nvim-dbee/dbee/adapters"
	"github.com/kndndrj/nvim-dbee/dbee/core"
)

func TestClearCurrentConnectionResetsSelectionAndAllowsFreshAutoSelect(t *testing.T) {
	typeName := "handler-clear-current-probe"
	require.NoError(t, new(adapters.Mux).AddAdapter(typeName, &connectionTestProbeAdapter{}))

	currentConn, err := adapters.NewConnection(&core.ConnectionParams{
		ID:   "conn-current",
		Name: "Current",
		Type: typeName,
		URL:  "probe://ok",
	})
	require.NoError(t, err)
	t.Cleanup(currentConn.Close)

	h := &Handler{
		events:               &eventBus{},
		lookupConnection:     map[core.ConnectionID]*core.Connection{currentConn.GetID(): currentConn},
		lookupCall:           make(map[core.CallID]*core.Call),
		lookupConnectionCall: make(map[core.ConnectionID][]core.CallID),
		currentConnectionID:  currentConn.GetID(),
	}

	require.NoError(t, h.ClearCurrentConnection())
	require.Empty(t, h.currentConnectionID)

	_, err = h.GetCurrentConnection()
	require.Error(t, err)

	newConnID, err := h.CreateConnection(&core.ConnectionParams{
		ID:   "conn-reselected",
		Name: "Reselected",
		Type: typeName,
		URL:  "probe://ok",
	})
	require.NoError(t, err)
	t.Cleanup(func() {
		if conn := h.lookupConnection[newConnID]; conn != nil {
			conn.Close()
		}
	})

	require.Equal(t, newConnID, h.currentConnectionID)
}

func TestCreateConnectionPreserveNilCurrentSuppressesAutoSelect(t *testing.T) {
	typeName := "handler-preserve-nil-current-probe"
	require.NoError(t, new(adapters.Mux).AddAdapter(typeName, &connectionTestProbeAdapter{}))

	h := &Handler{
		events:               &eventBus{},
		lookupConnection:     map[core.ConnectionID]*core.Connection{},
		lookupCall:           make(map[core.CallID]*core.Call),
		lookupConnectionCall: make(map[core.ConnectionID][]core.CallID),
	}

	newConnID, err := h.CreateConnection(&core.ConnectionParams{
		ID:   "conn-preserve-nil",
		Name: "Preserve Nil",
		Type: typeName,
		URL:  "probe://ok",
	}, CreateConnectionOpts{PreserveNilCurrent: true})
	require.NoError(t, err)
	t.Cleanup(func() {
		if conn := h.lookupConnection[newConnID]; conn != nil {
			conn.Close()
		}
	})

	require.Empty(t, h.currentConnectionID)
	require.Len(t, h.lookupConnection, 1)
}
