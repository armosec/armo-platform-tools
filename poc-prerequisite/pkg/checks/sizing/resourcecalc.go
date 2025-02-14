package sizing

import (
	"fmt"
	"strconv"
	"strings"
)

var defaultResourceAllocations = map[string]map[string]string{
	"nodeAgent": {
		"cpuReq": "100m",
		"cpuLim": "500m",
		"memReq": "180Mi",
		"memLim": "700Mi",
	},
	"storage": {
		"memReq": "400Mi",
		"memLim": "1500Mi",
	},
	"kubevuln": {
		"memReq": "1000Mi",
		"memLim": "5000Mi",
	},
}

func calculateNodeAgentCPU(nodeCPUMilli int) (string, string) {
	req := float64(nodeCPUMilli) * 0.025
	lim := float64(nodeCPUMilli) * 0.10
	return fmt.Sprintf("%.0fm", req), fmt.Sprintf("%.0fm", lim)
}

func calculateNodeAgentMemory(nodeMemMB int) (string, string) {
	req := float64(nodeMemMB) * 0.025
	lim := float64(nodeMemMB) * 0.10
	return fmt.Sprintf("%.0fMi", req), fmt.Sprintf("%.0fMi", lim)
}

func calculateStorageMemory(total int) (string, string) {
	r := float64(total) * 0.2
	l := float64(total) * 0.8
	return fmt.Sprintf("%.0fMi", r), fmt.Sprintf("%.0fMi", l)
}

func calculateKubevulnMemory(largestImgMB int) (string, string) {
	limit := float64(largestImgMB) + 400.0
	req := limit / 4.0
	return fmt.Sprintf("%.0fMi", req), fmt.Sprintf("%.0fMi", limit)
}

func compareAndChoose(defaultVal, recommendedVal string) string {
	defVal, defUnit := parseResource(defaultVal)
	recVal, recUnit := parseResource(recommendedVal)
	if defUnit != recUnit {
		return defaultVal
	}
	if recVal > defVal {
		return recommendedVal
	}
	return defaultVal
}

func parseResource(val string) (float64, string) {
	if strings.HasSuffix(val, "m") {
		num := strings.TrimSuffix(val, "m")
		f, _ := strconv.ParseFloat(num, 64)
		return f, "m"
	} else if strings.HasSuffix(val, "Mi") {
		num := strings.TrimSuffix(val, "Mi")
		f, _ := strconv.ParseFloat(num, 64)
		return f, "Mi"
	}
	f, _ := strconv.ParseFloat(val, 64)
	return f, ""
}
