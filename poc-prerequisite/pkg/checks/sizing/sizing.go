// pkg/checks/sizing/sizing.go
package sizing

import (
	"context"

	"github.com/armosec/armo-platform-tools/poc-prerequisite/pkg/common"
	"k8s.io/client-go/kubernetes"
)

func RunSizingChecker(ctx context.Context, clientset *kubernetes.Clientset, data *common.ClusterData) *common.SizingResult {
	totalResources := countAllResources(data)
	maxCPU, maxMem, largestImageMB := getNodeStats(data)

	recNodeAgentCPUReq, recNodeAgentCPULim := calculateNodeAgentCPU(maxCPU)
	recNodeAgentMemReq, recNodeAgentMemLim := calculateNodeAgentMemory(maxMem)
	recStorageMemReq, recStorageMemLim := calculateStorageMemory(totalResources)
	recKubevulnMemReq, recKubevulnMemLim := calculateKubevulnMemory(largestImageMB)

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

	return &common.SizingResult{
		TotalResources:             totalResources,
		MaxNodeCPUCapacity:         maxCPU,
		MaxNodeMemoryMB:            maxMem,
		LargestContainerImageMB:    largestImageMB,
		DefaultResourceAllocations: defaultResourceAllocations,
		FinalResourceAllocations:   finalResourceAllocations,
		HasAnyAdjustments:          computeHasAnyAdjustments(defaultResourceAllocations, finalResourceAllocations),
	}
}

// For example, countAllResources might sum up the lengths of pods, services,
// deployments, etc. stored in clusterData.
func countAllResources(cd *common.ClusterData) int {
	return len(cd.Pods) + len(cd.Services) +
		len(cd.Deployments) + len(cd.ReplicaSets) +
		len(cd.StatefulSets) + len(cd.DaemonSets) +
		len(cd.Jobs) + len(cd.CronJobs)
}

// parse node stats from clusterData
func getNodeStats(cd *common.ClusterData) (int, int, int) {
	var maxCPU, maxMem, largestImageBytes int64
	for _, node := range cd.Nodes {
		cpuQuantity := node.Status.Capacity.Cpu()
		memQuantity := node.Status.Capacity.Memory()
		cpuMilli := cpuQuantity.MilliValue()
		memMB := memQuantity.Value() / (1024 * 1024)

		if cpuMilli > maxCPU {
			maxCPU = cpuMilli
		}
		if memMB > maxMem {
			maxMem = memMB
		}
		for _, image := range node.Status.Images {
			if image.SizeBytes > largestImageBytes {
				largestImageBytes = image.SizeBytes
			}
		}
	}
	return int(maxCPU), int(maxMem), int(largestImageBytes / (1024 * 1024))
}

func computeHasAnyAdjustments(defaults, finals map[string]map[string]string) bool {
	for comp, defMap := range defaults {
		finalMap, ok := finals[comp]
		if !ok {
			continue
		}
		// Check each resource key
		for resKey, defVal := range defMap {
			finalVal, ok := finalMap[resKey]
			if !ok {
				continue
			}
			if defVal != finalVal {
				return true
			}
		}
	}
	return false
}
