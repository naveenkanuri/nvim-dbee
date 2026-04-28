package core_test

import (
	"context"
	"testing"

	"github.com/stretchr/testify/require"

	"github.com/kndndrj/nvim-dbee/dbee/core"
	"github.com/kndndrj/nvim-dbee/dbee/core/mock"
)

type bindAwareDriver struct {
	queryCalls          int
	queryWithBindsCalls int
	lastBinds           map[string]string
}

func (d *bindAwareDriver) Query(_ context.Context, _ string) (core.ResultStream, error) {
	d.queryCalls++
	return mock.NewResultStream(mock.NewRows(0, 1)), nil
}

func (d *bindAwareDriver) QueryWithBinds(_ context.Context, _ string, binds map[string]string) (core.ResultStream, error) {
	d.queryWithBindsCalls++
	d.lastBinds = make(map[string]string, len(binds))
	for k, v := range binds {
		d.lastBinds[k] = v
	}
	return mock.NewResultStream(mock.NewRows(0, 1)), nil
}

func (*bindAwareDriver) Structure() ([]*core.Structure, error) {
	return nil, nil
}

func (*bindAwareDriver) Ping(_ context.Context) error { return nil }

func (*bindAwareDriver) Columns(_ *core.TableOptions) ([]*core.Column, error) {
	return []*core.Column{{Name: "id", Type: "NUMBER"}}, nil
}

func (*bindAwareDriver) Close() {}

type basicDriver struct {
	queryCalls int
}

func (d *basicDriver) Query(_ context.Context, _ string) (core.ResultStream, error) {
	d.queryCalls++
	return mock.NewResultStream(mock.NewRows(0, 1)), nil
}

func (*basicDriver) Structure() ([]*core.Structure, error) {
	return nil, nil
}

func (*basicDriver) Ping(_ context.Context) error { return nil }

func (*basicDriver) Columns(_ *core.TableOptions) ([]*core.Column, error) {
	return []*core.Column{{Name: "id", Type: "NUMBER"}}, nil
}

func (*basicDriver) Close() {}

type singleDriverAdapter struct {
	driver core.Driver
}

func (a *singleDriverAdapter) Connect(string) (core.Driver, error) {
	return a.driver, nil
}

func (*singleDriverAdapter) GetHelpers(_ *core.TableOptions) map[string]string {
	return map[string]string{}
}

func TestConnectionExecuteWithOptions_UsesBindAwareDriver(t *testing.T) {
	driver := &bindAwareDriver{}

	conn, err := core.NewConnection(&core.ConnectionParams{
		ID:   "bind-aware",
		Type: "oracle",
		URL:  "mock://bind-aware",
	}, &singleDriverAdapter{driver: driver})
	require.NoError(t, err)
	defer conn.Close()

	call := conn.ExecuteWithOptions("SELECT :id FROM dual", &core.QueryExecuteOptions{
		Binds: map[string]string{"id": "42"},
	}, nil)

	<-call.Done()

	require.NoError(t, call.Err())
	require.Equal(t, 1, driver.queryWithBindsCalls)
	require.Equal(t, 0, driver.queryCalls)
	require.Equal(t, "42", driver.lastBinds["id"])
}

func TestConnectionExecuteWithOptions_FallsBackWhenDriverDoesNotSupportBinds(t *testing.T) {
	driver := &basicDriver{}

	conn, err := core.NewConnection(&core.ConnectionParams{
		ID:   "basic",
		Type: "sqlite",
		URL:  "mock://basic",
	}, &singleDriverAdapter{driver: driver})
	require.NoError(t, err)
	defer conn.Close()

	call := conn.ExecuteWithOptions("SELECT :id FROM dual", &core.QueryExecuteOptions{
		Binds: map[string]string{"id": "42"},
	}, nil)
	<-call.Done()

	require.NoError(t, call.Err())
	require.Equal(t, 1, driver.queryCalls)
}
