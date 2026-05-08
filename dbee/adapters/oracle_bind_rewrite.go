package adapters

import (
	"database/sql"
	"errors"
	"fmt"
	"sort"
	"strings"
)

const (
	oracleDollarSentinel = "_x24_"
	oracleHashSentinel   = "_x23_"
)

type codeRegion struct {
	start int
	end   int
}

type oracleCursorMarker struct {
	name        string
	markerStart int
	markerEnd   int
}

type oracleBindRewriteMap struct {
	userToDriver      map[string]string
	driverToUser      map[string]string
	driverUpperToUser map[string]string
	sortedDriverNames []string
}

type oracleBindRewritePlan struct {
	originalSQL  string
	rewrittenSQL string
	bindArgs     []any
	mapping      oracleBindRewriteMap
	cursorParams []string
	hasCursor    bool
}

func validateOracleBindNameUser(name string) error {
	if name == "" || !isOracleUserBindName(name) {
		return fmt.Errorf("invalid oracle bind identifier %q (grammar requires letter or underscore start, then [A-Za-z0-9_$#]*); rename to %q", name, oracleSafeBindSuggestion(name))
	}
	if containsOracleBindSentinelName(name) {
		return fmt.Errorf("oracle bind name %q contains internal sentinel '_x24_' or '_x23_' (case-insensitive); rename to avoid collision", name)
	}
	if _, bad := oracleUnsafeBindNames[strings.ToUpper(name)]; bad {
		return fmt.Errorf("oracle bind name %q is reserved or unsafe; rename the SQL placeholder and bind option to a non-reserved name such as %q", name, oracleSafeBindSuggestion(name))
	}
	return nil
}

func validateOracleBindNameDriver(name string) error {
	if name == "" || !oracleBindNameRe.MatchString(name) {
		return fmt.Errorf("invalid oracle driver bind identifier %q after rewrite", name)
	}
	if _, bad := oracleUnsafeBindNames[strings.ToUpper(name)]; bad {
		return fmt.Errorf("oracle driver bind name %q is reserved or unsafe after rewrite", name)
	}
	return nil
}

func oracleSafeBindSuggestion(name string) string {
	if name == "" {
		return "p_unnamed"
	}

	var b strings.Builder
	b.Grow(len(name) + 2)
	if !isOracleUserBindStart(name[0]) {
		b.WriteString("p_")
	}
	for i := 0; i < len(name); i++ {
		ch := name[i]
		if isOracleUserBindBody(ch) {
			b.WriteByte(ch)
			continue
		}
		b.WriteByte('_')
	}

	suggestion := strings.Trim(b.String(), "_")
	if suggestion == "" {
		return "p_unnamed"
	}
	if !isOracleUserBindStart(suggestion[0]) {
		suggestion = "p_" + suggestion
	}
	if containsOracleBindSentinelName(suggestion) {
		return "p_unnamed"
	}
	if _, bad := oracleUnsafeBindNames[strings.ToUpper(suggestion)]; bad {
		suggestion = "p_" + suggestion
	}
	if !isOracleUserBindName(suggestion) || containsOracleBindSentinelName(suggestion) {
		return "p_unnamed"
	}
	return suggestion
}

func rewriteOracleBindNameForDriver(name string) (string, bool, error) {
	if err := validateOracleBindNameUser(name); err != nil {
		return "", false, err
	}
	if strings.IndexAny(name, "$#") < 0 {
		if err := validateOracleBindNameDriver(name); err != nil {
			return "", false, err
		}
		return name, false, nil
	}

	var b strings.Builder
	b.Grow(len(name) + 8)
	for i := 0; i < len(name); i++ {
		switch name[i] {
		case '$':
			b.WriteString(oracleDollarSentinel)
		case '#':
			b.WriteString(oracleHashSentinel)
		default:
			b.WriteByte(name[i])
		}
	}
	driverName := b.String()
	if err := validateOracleBindNameDriver(driverName); err != nil {
		return "", false, err
	}
	return driverName, true, nil
}

func newOracleBindRewriteMap() oracleBindRewriteMap {
	return oracleBindRewriteMap{}
}

func (m *oracleBindRewriteMap) addName(name string) (string, bool, error) {
	driverName, changed, err := rewriteOracleBindNameForDriver(name)
	if err != nil {
		return "", false, err
	}

	upperDriver := strings.ToUpper(driverName)
	if m.driverUpperToUser == nil {
		m.driverUpperToUser = make(map[string]string)
	}
	if previous, ok := m.driverUpperToUser[upperDriver]; ok && previous != name {
		return "", false, fmt.Errorf("oracle bind names %q and %q rewrite to driver name %q case-insensitively; rename one bind to avoid collision", previous, name, driverName)
	}
	m.driverUpperToUser[upperDriver] = name

	if m.userToDriver == nil {
		m.userToDriver = make(map[string]string)
	}
	m.userToDriver[name] = driverName
	if changed {
		if m.driverToUser == nil {
			m.driverToUser = make(map[string]string)
		}
		m.driverToUser[driverName] = name
	}
	return driverName, changed, nil
}

func (m *oracleBindRewriteMap) finalize() {
	if len(m.driverToUser) == 0 {
		m.sortedDriverNames = nil
		return
	}
	m.sortedDriverNames = make([]string, 0, len(m.driverToUser))
	for name := range m.driverToUser {
		m.sortedDriverNames = append(m.sortedDriverNames, name)
	}
	sort.Slice(m.sortedDriverNames, func(i, j int) bool {
		if len(m.sortedDriverNames[i]) != len(m.sortedDriverNames[j]) {
			return len(m.sortedDriverNames[i]) > len(m.sortedDriverNames[j])
		}
		return m.sortedDriverNames[i] < m.sortedDriverNames[j]
	})
}

func (m oracleBindRewriteMap) emptyReverseMap() bool {
	return len(m.driverToUser) == 0 || len(m.sortedDriverNames) == 0
}

func prepareOracleBindRewrite(query string, binds map[string]string) (oracleBindRewritePlan, error) {
	plan := oracleBindRewritePlan{
		originalSQL:  query,
		rewrittenSQL: query,
		mapping:      newOracleBindRewriteMap(),
	}

	needsSQLScan := strings.IndexAny(query, "$#") >= 0 ||
		containsOracleSentinelASCII(query) ||
		containsOracleQQuoteCandidateASCII(query) ||
		containsOracleCursorMarkerCandidateASCII(query)

	if len(binds) > 0 {
		args, err := oracleNamedArgsWithRewrite(binds, &plan.mapping)
		if err != nil {
			return plan, err
		}
		plan.bindArgs = args
	}

	if !needsSQLScan {
		plan.mapping.finalize()
		return plan, nil
	}

	regions, err := scanOracleSQLCodeRegions(query)
	if err != nil {
		return plan, err
	}
	cursorMarkers, err := scanOracleCursorMarkersInRegions(query, regions)
	if err != nil {
		return plan, err
	}
	rewritten, err := transformOracleSQLBinds(query, regions, cursorMarkers, &plan.mapping)
	if err != nil {
		return plan, err
	}
	plan.rewrittenSQL = rewritten
	if len(cursorMarkers) > 0 {
		plan.hasCursor = true
		plan.cursorParams = make([]string, 0, len(cursorMarkers))
		for _, marker := range cursorMarkers {
			plan.cursorParams = append(plan.cursorParams, marker.name)
		}
	}
	plan.mapping.finalize()
	return plan, nil
}

func oracleNamedArgs(binds map[string]string) ([]any, error) {
	if len(binds) == 0 {
		return nil, nil
	}
	mapping := newOracleBindRewriteMap()
	args, err := oracleNamedArgsWithRewrite(binds, &mapping)
	if err != nil {
		return nil, err
	}
	return args, nil
}

func oracleNamedArgsWithRewrite(binds map[string]string, mapping *oracleBindRewriteMap) ([]any, error) {
	if len(binds) == 0 {
		return nil, nil
	}

	keys := make([]string, 0, len(binds))
	for name := range binds {
		keys = append(keys, name)
	}
	sort.Strings(keys)

	var nameErrs []error
	args := make([]any, 0, len(keys))
	for _, name := range keys {
		driverName, _, err := mapping.addName(name)
		if err != nil {
			nameErrs = append(nameErrs, err)
			continue
		}
		if err := validateOracleBindNameDriver(driverName); err != nil {
			nameErrs = append(nameErrs, err)
			continue
		}
		args = append(args, sql.Named(driverName, coerceOracleBindValue(binds[name])))
	}
	if len(nameErrs) > 0 {
		return nil, errors.Join(nameErrs...)
	}
	return args, nil
}

func scanOracleSQLCodeRegions(query string) ([]codeRegion, error) {
	regions := make([]codeRegion, 0, 4)
	codeStart := 0
	for i := 0; i < len(query); {
		switch query[i] {
		case '\'':
			if codeStart < i {
				regions = append(regions, codeRegion{start: codeStart, end: i})
			}
			i = skipOracleSingleQuoted(query, i)
			codeStart = i
		case '"':
			if codeStart < i {
				regions = append(regions, codeRegion{start: codeStart, end: i})
			}
			i = skipOracleDoubleQuoted(query, i)
			codeStart = i
		case '-':
			if i+1 < len(query) && query[i+1] == '-' {
				if codeStart < i {
					regions = append(regions, codeRegion{start: codeStart, end: i})
				}
				i += 2
				for i < len(query) && query[i] != '\n' {
					i++
				}
				codeStart = i
				continue
			}
			i++
		case '/':
			if i+1 < len(query) && query[i+1] == '*' {
				if _, ok := scanOracleCursorComment(query, i, len(query)); ok {
					i++
					continue
				}
				if codeStart < i {
					regions = append(regions, codeRegion{start: codeStart, end: i})
				}
				i += 2
				for i+1 < len(query) && !(query[i] == '*' && query[i+1] == '/') {
					i++
				}
				if i+1 < len(query) {
					i += 2
				} else {
					i = len(query)
				}
				codeStart = i
				continue
			}
			i++
		case 'q', 'Q':
			if i+1 < len(query) && query[i+1] == '\'' {
				if codeStart < i {
					regions = append(regions, codeRegion{start: codeStart, end: i})
				}
				next, err := skipOracleQQuote(query, i)
				if err != nil {
					return nil, err
				}
				i = next
				codeStart = i
				continue
			}
			i++
		default:
			i++
		}
	}
	if codeStart < len(query) {
		regions = append(regions, codeRegion{start: codeStart, end: len(query)})
	}
	if len(regions) == 0 {
		return nil, nil
	}
	return regions, nil
}

func transformOracleSQLBinds(query string, regions []codeRegion, markers []oracleCursorMarker, mapping *oracleBindRewriteMap) (string, error) {
	if len(regions) == 0 {
		return query, nil
	}
	sort.Slice(markers, func(i, j int) bool { return markers[i].markerStart < markers[j].markerStart })

	var b strings.Builder
	changed := false
	lastEmit := 0
	markerIndex := 0
	ensureBuilder := func() {
		if !changed {
			b.Grow(len(query))
			b.WriteString(query[:lastEmit])
			changed = true
		}
	}

	for _, region := range regions {
		for markerIndex < len(markers) && markers[markerIndex].markerEnd <= region.start {
			markerIndex++
		}
		for i := region.start; i < region.end; {
			if markerIndex < len(markers) && markers[markerIndex].markerStart == i {
				ensureBuilder()
				b.WriteString(query[lastEmit:i])
				lastEmit = markers[markerIndex].markerEnd
				i = lastEmit
				markerIndex++
				continue
			}
			if query[i] != ':' {
				i++
				continue
			}
			if i+1 < region.end && isOracleUserBindStart(query[i+1]) {
				nameStart := i + 1
				nameEnd := nameStart + 1
				for nameEnd < region.end && isOracleUserBindBody(query[nameEnd]) {
					nameEnd++
				}
				name := query[nameStart:nameEnd]
				driverName, rewritten, err := mapping.addName(name)
				if err != nil {
					return "", err
				}
				if rewritten {
					ensureBuilder()
					b.WriteString(query[lastEmit:nameStart])
					b.WriteString(driverName)
					lastEmit = nameEnd
				}
				i = nameEnd
				continue
			}
			if i+1 < region.end && isOracleInvalidBindStart(query[i+1]) {
				nameEnd := i + 2
				for nameEnd < region.end && isOracleInvalidBindBody(query[nameEnd]) {
					nameEnd++
				}
				name := query[i+1 : nameEnd]
				return "", validateOracleBindNameUser(name)
			}
			i++
		}
	}

	if !changed {
		return query, nil
	}
	b.WriteString(query[lastEmit:])
	return b.String(), nil
}

func scanOracleCursorMarkersInRegions(query string, regions []codeRegion) ([]oracleCursorMarker, error) {
	var markers []oracleCursorMarker
	var errs []error
	for _, region := range regions {
		for i := region.start; i < region.end; i++ {
			if query[i] != ':' || i+1 >= region.end || query[i+1] == '=' {
				continue
			}
			nameStart := i + 1
			nameEnd := nameStart
			for nameEnd < region.end && isOracleCursorBroadNameByte(query[nameEnd]) {
				nameEnd++
			}
			spaceEnd := nameEnd
			for spaceEnd < region.end && isASCIIWhitespace(query[spaceEnd]) {
				spaceEnd++
			}
			commentEnd, ok := scanOracleCursorComment(query, spaceEnd, region.end)
			if !ok {
				continue
			}
			name := query[nameStart:nameEnd]
			if err := validateOracleBindNameUser(name); err != nil {
				errs = append(errs, err)
				i = commentEnd - 1
				continue
			}
			markers = append(markers, oracleCursorMarker{
				name:        name,
				markerStart: nameEnd,
				markerEnd:   commentEnd,
			})
			i = commentEnd - 1
		}
	}
	if len(errs) > 0 {
		return markers, errors.Join(errs...)
	}
	return markers, nil
}

func stripOracleCursorMarkersOnly(query string, regions []codeRegion, markers []oracleCursorMarker) string {
	if len(markers) == 0 {
		return query
	}
	sort.Slice(markers, func(i, j int) bool { return markers[i].markerStart < markers[j].markerStart })
	var b strings.Builder
	b.Grow(len(query))
	last := 0
	for _, marker := range markers {
		b.WriteString(query[last:marker.markerStart])
		last = marker.markerEnd
	}
	b.WriteString(query[last:])
	return b.String()
}

func skipOracleSingleQuoted(query string, start int) int {
	i := start + 1
	for i < len(query) {
		if query[i] == '\'' {
			if i+1 < len(query) && query[i+1] == '\'' {
				i += 2
				continue
			}
			return i + 1
		}
		i++
	}
	return len(query)
}

func skipOracleDoubleQuoted(query string, start int) int {
	i := start + 1
	for i < len(query) {
		if query[i] == '"' {
			if i+1 < len(query) && query[i+1] == '"' {
				i += 2
				continue
			}
			return i + 1
		}
		i++
	}
	return len(query)
}

func skipOracleQQuote(query string, start int) (int, error) {
	if start+2 >= len(query) {
		return 0, fmt.Errorf("unterminated oracle q-quote literal")
	}
	opener := query[start+2]
	if opener >= 0x80 || opener == '\'' || isASCIIWhitespace(opener) {
		return 0, fmt.Errorf("unsupported oracle q-quote delimiter %q; whitespace, single-quote, and multibyte delimiters are not supported", query[start:minInt(start+3, len(query))])
	}
	closer := opener
	switch opener {
	case '(':
		closer = ')'
	case '{':
		closer = '}'
	case '[':
		closer = ']'
	case '<':
		closer = '>'
	}
	for i := start + 3; i+1 < len(query); i++ {
		if query[i] == closer && query[i+1] == '\'' {
			return i + 2, nil
		}
	}
	return 0, fmt.Errorf("unterminated oracle q-quote literal")
}

func scanOracleCursorComment(query string, start int, end int) (int, bool) {
	if start+3 >= end || query[start] != '/' || query[start+1] != '*' {
		return 0, false
	}
	i := start + 2
	for i < end && isASCIIWhitespace(query[i]) {
		i++
	}
	for _, ch := range "CURSOR" {
		if i >= end || asciiUpper(query[i]) != byte(ch) {
			return 0, false
		}
		i++
	}
	for i < end && isASCIIWhitespace(query[i]) {
		i++
	}
	if i+1 >= end || query[i] != '*' || query[i+1] != '/' {
		return 0, false
	}
	return i + 2, true
}

func hasCursorMarker(query string) bool {
	regions, err := scanOracleSQLCodeRegions(query)
	if err != nil {
		return false
	}
	markers, err := scanOracleCursorMarkersInRegions(query, regions)
	return err == nil && len(markers) > 0
}

func hasCursorMarkerBroad(query string) bool {
	regions, err := scanOracleSQLCodeRegions(query)
	if err != nil {
		return true
	}
	markers, err := scanOracleCursorMarkersInRegions(query, regions)
	return err != nil || len(markers) > 0
}

func validateRawCursorMarkers(query string) error {
	regions, err := scanOracleSQLCodeRegions(query)
	if err != nil {
		return err
	}
	_, err = scanOracleCursorMarkersInRegions(query, regions)
	return err
}

func parseCursorParams(query string) ([]string, string) {
	regions, err := scanOracleSQLCodeRegions(query)
	if err != nil {
		return nil, query
	}
	markers, err := scanOracleCursorMarkersInRegions(query, regions)
	if err != nil {
		return nil, query
	}
	params := make([]string, 0, len(markers))
	for _, marker := range markers {
		params = append(params, marker.name)
	}
	return params, stripOracleCursorMarkersOnly(query, regions, markers)
}

func wrapOracleError(err error, mapping oracleBindRewriteMap) error {
	if err == nil {
		return nil
	}
	formatted := formatOracleError(err)
	if mapping.emptyReverseMap() {
		return formatted
	}
	reversed := reverseDriverNames(formatted.Error(), mapping.driverToUser, mapping.sortedDriverNames)
	if reversed == formatted.Error() {
		return formatted
	}
	return &oracleBindReverseError{original: err, message: reversed}
}

type oracleBindReverseError struct {
	original error
	message  string
}

func (e *oracleBindReverseError) Error() string {
	return e.message
}

func (e *oracleBindReverseError) Unwrap() error {
	return e.original
}

func reverseDriverNames(msg string, driverToUser map[string]string, sortedKeys []string) string {
	msg = reverseDriverNamesInBareTemplates(msg, driverToUser, sortedKeys)
	var b strings.Builder
	changed := false
	last := 0
	for i := 0; i < len(msg); i++ {
		if msg[i] != ':' {
			continue
		}
		for _, key := range sortedKeys {
			end := i + 1 + len(key)
			if end > len(msg) || msg[i+1:end] != key {
				continue
			}
			if end < len(msg) && isOracleUserBindBody(msg[end]) {
				continue
			}
			if !changed {
				b.Grow(len(msg))
				changed = true
			}
			b.WriteString(msg[last : i+1])
			b.WriteString(driverToUser[key])
			last = end
			i = end - 1
			break
		}
	}
	if !changed {
		return msg
	}
	b.WriteString(msg[last:])
	return b.String()
}

func reverseDriverNamesInBareTemplates(msg string, driverToUser map[string]string, sortedKeys []string) string {
	for _, key := range sortedKeys {
		user := driverToUser[key]
		for _, prefix := range []string{"parameter ", "bind "} {
			start := strings.Index(msg, prefix+key)
			if start < 0 {
				continue
			}
			nameStart := start + len(prefix)
			nameEnd := nameStart + len(key)
			if prefix == "parameter " {
				if !strings.HasPrefix(msg[nameEnd:], " is not defined") {
					continue
				}
			} else if !strings.HasPrefix(msg[nameEnd:], " invalid") {
				continue
			}
			return replaceOracleSpan(msg, nameStart, nameEnd, user)
		}
		quotedPrefix := `parameter "`
		start := strings.Index(msg, quotedPrefix+key+`" not found`)
		if start >= 0 {
			nameStart := start + len(quotedPrefix)
			return replaceOracleSpan(msg, nameStart, nameStart+len(key), user)
		}
	}
	return msg
}

func replaceOracleSpan(s string, start int, end int, replacement string) string {
	var b strings.Builder
	b.Grow(len(s) + len(replacement) - (end - start))
	b.WriteString(s[:start])
	b.WriteString(replacement)
	b.WriteString(s[end:])
	return b.String()
}

func containsOracleSentinelASCII(s string) bool {
	return containsFoldASCII(s, oracleDollarSentinel) || containsFoldASCII(s, oracleHashSentinel)
}

func containsOracleBindSentinelName(name string) bool {
	return containsFoldASCII(name, oracleDollarSentinel) || containsFoldASCII(name, oracleHashSentinel)
}

func containsOracleQQuoteCandidateASCII(s string) bool {
	idx := strings.IndexAny(s, "qQ")
	for idx >= 0 {
		if idx+1 < len(s) && s[idx+1] == '\'' {
			return true
		}
		if idx+1 >= len(s) {
			return false
		}
		next := strings.IndexAny(s[idx+1:], "qQ")
		if next < 0 {
			return false
		}
		idx += 1 + next
	}
	return false
}

func containsOracleCursorMarkerCandidateASCII(s string) bool {
	for i := 0; i+1 < len(s); i++ {
		if s[i] != '/' || s[i+1] != '*' {
			continue
		}
		for j := i + 2; j+5 < len(s); j++ {
			if asciiUpper(s[j]) == 'C' &&
				asciiUpper(s[j+1]) == 'U' &&
				asciiUpper(s[j+2]) == 'R' &&
				asciiUpper(s[j+3]) == 'S' &&
				asciiUpper(s[j+4]) == 'O' &&
				asciiUpper(s[j+5]) == 'R' {
				return true
			}
			if j+1 < len(s) && s[j] == '*' && s[j+1] == '/' {
				break
			}
		}
	}
	return false
}

func containsFoldASCII(s string, needle string) bool {
	if len(needle) == 0 {
		return true
	}
	if len(s) < len(needle) {
		return false
	}
	for i := 0; i <= len(s)-len(needle); i++ {
		ok := true
		for j := 0; j < len(needle); j++ {
			if asciiLower(s[i+j]) != asciiLower(needle[j]) {
				ok = false
				break
			}
		}
		if ok {
			return true
		}
	}
	return false
}

func isOracleUserBindName(name string) bool {
	if name == "" || !isOracleUserBindStart(name[0]) {
		return false
	}
	for i := 1; i < len(name); i++ {
		if !isOracleUserBindBody(name[i]) {
			return false
		}
	}
	return true
}

func isOracleUserBindStart(ch byte) bool {
	return (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || ch == '_'
}

func isOracleUserBindBody(ch byte) bool {
	return isOracleUserBindStart(ch) || (ch >= '0' && ch <= '9') || ch == '$' || ch == '#'
}

func isOracleInvalidBindStart(ch byte) bool {
	return (ch >= '0' && ch <= '9') || ch == '$' || ch == '#'
}

func isOracleInvalidBindBody(ch byte) bool {
	return isOracleUserBindBody(ch) || ch == '-'
}

// The broad cursor marker byte set intentionally supersets the strict user
// bind grammar and still excludes "=" so PL/SQL assignment (:=) is not a marker.
func isOracleCursorBroadNameByte(ch byte) bool {
	if isASCIIWhitespace(ch) {
		return false
	}
	switch ch {
	case '/', ':', '(', ')', ';', ',', '\'', '"', '=':
		return false
	default:
		return true
	}
}

func isASCIIWhitespace(ch byte) bool {
	return ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t' || ch == '\f' || ch == '\v'
}

func asciiLower(ch byte) byte {
	if ch >= 'A' && ch <= 'Z' {
		return ch + ('a' - 'A')
	}
	return ch
}

func asciiUpper(ch byte) byte {
	if ch >= 'a' && ch <= 'z' {
		return ch - ('a' - 'A')
	}
	return ch
}

func minInt(a int, b int) int {
	if a < b {
		return a
	}
	return b
}
