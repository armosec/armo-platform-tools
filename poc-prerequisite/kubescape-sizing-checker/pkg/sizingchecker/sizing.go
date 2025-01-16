package sizingchecker

import (
	"context"
)

// RunSizingChecker is the real driver for your sizing logic.
func RunSizingChecker() {
	// 1) Build Kubernetes client (detect if running in-cluster or local)
	inCluster, clientset := buildKubeClient()

	// 2) Gather data
	ctx := context.Background()
	totalResources := getTotalResources(ctx, clientset)
	maxCPU, maxMem, largestImageMB := getNodeStats(ctx, clientset)

	// 3) Calculate recommended resources
	recNodeAgentCPUReq, recNodeAgentCPULim := calculateNodeAgentCPU(maxCPU)
	recNodeAgentMemReq, recNodeAgentMemLim := calculateNodeAgentMemory(maxMem)
	recStorageMemReq, recStorageMemLim := calculateStorageMemory(totalResources)
	recKubevulnMemReq, recKubevulnMemLim := calculateKubevulnMemory(largestImageMB)

	// 4) Build final map of recommended resources
	finalResourceAllocations := map[string]map[string]string{
		"nodeAgent": {
			"cpuReq": compareAndChoose(defaultResourceAllocations["nodeAgent"]["cpuReq"], recNodeAgentCPUReq),
			"cpuLim": compareAndChoose(defaultResourceAllocations["nodeAgent"]["cpuLim"], recNodeAgentCPULim),
			"memReq": compareAndChoose(defaultResourceAllocations["nodeAgent"]["memReq"], recNodeAgentMemReq),
			"memLim": compareAndChoose(defaultResourceAllocations["nodeAgent"]["memLim"], recNodeAgentMemLim),
		},
		"storage": {
			"memReq": compareAndChoose(defaultResourceAllocations["storage"]["memReq"], recStorageMemReq),
			"memLim": compareAndChoose(defaultResourceAllocations["storage"]["memLim"], recStorageMemLim),
		},
		"kubevuln": {
			"memReq": compareAndChoose(defaultResourceAllocations["kubevuln"]["memReq"], recKubevulnMemReq),
			"memLim": compareAndChoose(defaultResourceAllocations["kubevuln"]["memLim"], recKubevulnMemLim),
		},
	}

	// 5) Put it all into reportData
	data := &reportData{
		TotalResources:          totalResources,
		MaxNodeCPUCapacity:      maxCPU,
		MaxNodeMemoryMB:         maxMem,
		LargestContainerImageMB: largestImageMB,

		DefaultResourceAllocations: defaultResourceAllocations,
		FinalResourceAllocations:   finalResourceAllocations,
	}

	// 6) Generate HTML report and values.yaml
	htmlContent := buildHTMLReport(data, sizingReportHTML)
	yamlContent := buildValuesYAML(data)

	if inCluster {
		writeToConfigMap(htmlContent, yamlContent)
	} else {
		writeToDisk(htmlContent, yamlContent)
	}
}
