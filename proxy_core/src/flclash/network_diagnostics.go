package main

import (
	"fmt"
	"time"

	"github.com/metacubex/mihomo/log"
)

var networkDiagnosticsStartedAt = time.Now()

func netDiag(event string, format string, args ...any) {
	wallTime := time.Now().UTC().Format(time.RFC3339Nano)
	monotonicDeltaNs := time.Since(networkDiagnosticsStartedAt).Nanoseconds()
	details := fmt.Sprintf(format, args...)
	log.Infoln(
		"[NETDIAG] wall_time=%s monotonic_delta_ns=%d event=%s %s",
		wallTime,
		monotonicDeltaNs,
		event,
		details,
	)
}
