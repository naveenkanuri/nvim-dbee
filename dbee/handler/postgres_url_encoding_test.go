package handler

import (
	"net/url"
	"testing"

	"github.com/stretchr/testify/require"
)

func TestEncodedPostgresFormURLParsesWithNetURL(t *testing.T) {
	raw := "postgres://user%3Aname:pa%2Fss%3A%40%3F%23@form-host:5432/db%2Fname%3F%23?sslmode=require"

	parsed, err := url.Parse(raw)
	require.NoError(t, err)
	require.Equal(t, "form-host:5432", parsed.Host)
	require.NotNil(t, parsed.User)

	password, ok := parsed.User.Password()
	require.True(t, ok)
	require.Equal(t, "user:name", parsed.User.Username())
	require.Equal(t, "pa/ss:@?#", password)
	require.Equal(t, "/db%2Fname%3F%23", parsed.EscapedPath())
	require.Equal(t, "sslmode=require", parsed.RawQuery)
}
