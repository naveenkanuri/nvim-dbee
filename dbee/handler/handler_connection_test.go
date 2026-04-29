package handler

import (
	"context"
	"errors"
	"fmt"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/kndndrj/nvim-dbee/dbee/adapters"
	"github.com/kndndrj/nvim-dbee/dbee/core"
)

type connectionTestProbeDriver struct {
	probeErr error
}

func (d *connectionTestProbeDriver) Query(context.Context, string) (core.ResultStream, error) {
	return nil, errors.New("query not used in connection test")
}

func (d *connectionTestProbeDriver) Structure() ([]*core.Structure, error) {
	return nil, nil
}

func (d *connectionTestProbeDriver) Columns(*core.TableOptions) ([]*core.Column, error) {
	return nil, nil
}

func (d *connectionTestProbeDriver) Ping(context.Context) error {
	return d.probeErr
}

func (d *connectionTestProbeDriver) Close() {}

type connectionTestProbeAdapter struct{}

func (a *connectionTestProbeAdapter) Connect(rawURL string) (core.Driver, error) {
	switch rawURL {
	case "probe://ok":
		return &connectionTestProbeDriver{}, nil
	case "probe://unreachable":
		return &connectionTestProbeDriver{probeErr: errors.New("dial tcp 127.0.0.1:1: connect: connection refused")}, nil
	default:
		return nil, fmt.Errorf("unexpected probe url: %s", rawURL)
	}
}

func (a *connectionTestProbeAdapter) GetHelpers(*core.TableOptions) map[string]string {
	return nil
}

func TestConnectionTestUsesDriverProbeWithoutMutatingHandlerState(t *testing.T) {
	typeName := "handler-connection-test-probe"
	require.NoError(t, new(adapters.Mux).AddAdapter(typeName, &connectionTestProbeAdapter{}))

	validConn, err := adapters.NewConnection(&core.ConnectionParams{
		ID:   "conn-valid",
		Name: "Valid",
		Type: typeName,
		URL:  "probe://ok",
	})
	require.NoError(t, err)
	t.Cleanup(validConn.Close)

	unreachableConn, err := adapters.NewConnection(&core.ConnectionParams{
		ID:   "conn-unreachable",
		Name: "Unreachable",
		Type: typeName,
		URL:  "probe://unreachable",
	})
	require.NoError(t, err)
	t.Cleanup(unreachableConn.Close)

	h := &Handler{
		lookupConnection: map[core.ConnectionID]*core.Connection{
			validConn.GetID():       validConn,
			unreachableConn.GetID(): unreachableConn,
		},
		lookupCall:           make(map[core.CallID]*core.Call),
		lookupConnectionCall: make(map[core.ConnectionID][]core.CallID),
		currentConnectionID:  validConn.GetID(),
	}

	err = h.ConnectionTest(unreachableConn.GetID())
	require.Error(t, err)
	require.Contains(t, err.Error(), "connection refused")
	require.Len(t, h.lookupConnection, 2)
	require.Equal(t, validConn.GetID(), h.currentConnectionID)

	err = h.ConnectionTest(validConn.GetID())
	require.NoError(t, err)
	require.Len(t, h.lookupConnection, 2)
	require.Equal(t, validConn.GetID(), h.currentConnectionID)
	require.Same(t, validConn, h.lookupConnection[validConn.GetID()])
	require.Same(t, unreachableConn, h.lookupConnection[unreachableConn.GetID()])
}

func TestConnectionTestSpecUsesTemporaryConnectionWithoutMutatingHandlerState(t *testing.T) {
	typeName := "handler-connection-test-spec-probe"
	require.NoError(t, new(adapters.Mux).AddAdapter(typeName, &connectionTestProbeAdapter{}))

	existingConn, err := adapters.NewConnection(&core.ConnectionParams{
		ID:   "conn-existing",
		Name: "Existing",
		Type: typeName,
		URL:  "probe://ok",
	})
	require.NoError(t, err)
	t.Cleanup(existingConn.Close)

	h := &Handler{
		lookupConnection: map[core.ConnectionID]*core.Connection{
			existingConn.GetID(): existingConn,
		},
		lookupCall:           make(map[core.CallID]*core.Call),
		lookupConnectionCall: make(map[core.ConnectionID][]core.CallID),
		currentConnectionID:  existingConn.GetID(),
	}

	err = h.ConnectionTestSpec(&core.ConnectionParams{
		Name: "Probe OK",
		Type: typeName,
		URL:  "probe://ok",
	})
	require.NoError(t, err)
	require.Len(t, h.lookupConnection, 1)
	require.Equal(t, existingConn.GetID(), h.currentConnectionID)
	require.Same(t, existingConn, h.lookupConnection[existingConn.GetID()])

	err = h.ConnectionTestSpec(&core.ConnectionParams{
		Name: "Probe Down",
		Type: typeName,
		URL:  "probe://unreachable",
	})
	require.Error(t, err)
	require.Contains(t, err.Error(), "connection refused")
	require.Len(t, h.lookupConnection, 1)
	require.Equal(t, existingConn.GetID(), h.currentConnectionID)
	require.Same(t, existingConn, h.lookupConnection[existingConn.GetID()])
}
