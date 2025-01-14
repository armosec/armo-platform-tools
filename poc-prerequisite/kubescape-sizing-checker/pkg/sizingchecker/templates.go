package sizingchecker

import (
	_ "embed"
)

//go:embed templates/sizing-report.html
var sizingReportHTML string
