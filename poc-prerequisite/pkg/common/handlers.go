package common

import (
	"fmt"
	"html/template"
	"strings"
	"time"

	"gopkg.in/yaml.v3"
)

func BuildReportData(cd *ClusterData, sr *SizingResult) *ReportData {
	report := &ReportData{
		// existing merges:
		TotalResources:             sr.TotalResources,
		MaxNodeCPUCapacity:         sr.MaxNodeCPUCapacity,
		MaxNodeMemoryMB:            sr.MaxNodeMemoryMB,
		LargestContainerImageMB:    sr.LargestContainerImageMB,
		DefaultResourceAllocations: sr.DefaultResourceAllocations,
		FinalResourceAllocations:   sr.FinalResourceAllocations,
		HasAnyAdjustments:          sr.HasAnyAdjustments,

		KubernetesVersion: cd.ClusterDetails.Version,
		CloudProvider:     cd.ClusterDetails.CloudProvider,
		K8sDistribution:   cd.ClusterDetails.K8sDistribution,
		TotalNodeCount:    cd.ClusterDetails.TotalNodeCount,
		TotalVCPUCount:    cd.ClusterDetails.TotalVCPUCount,

		GenerationTime:  time.Now().Format("2006-01-02 15:04:05"),
		FullClusterData: cd,
	}

	// Now populate the node info summary fields:
	totalNodes := cd.ClusterDetails.TotalNodeCount
	ni := cd.NodeInfoSummaries

	report.NodeOSSummary = summarizeMap(ni.OperatingSystemCounts, totalNodes)
	report.NodeArchSummary = summarizeMap(ni.ArchitectureCounts, totalNodes)
	report.NodeKernelVersionSummary = summarizeMap(ni.KernelVersionCounts, totalNodes)
	report.NodeOSImageSummary = summarizeMap(ni.OSImageCounts, totalNodes)
	report.NodeContainerRuntimeSummary = summarizeMap(ni.ContainerRuntimeVersionCounts, totalNodes)
	report.NodeKubeletVersionSummary = summarizeMap(ni.KubeletVersionCounts, totalNodes)
	report.NodeKubeProxyVersionSummary = summarizeMap(ni.KubeProxyVersionCounts, totalNodes)

	return report
}

func BuildFullDumpYAML(cd *ClusterData) string {
	if cd == nil {
		return "Error building full cluster dump: cluster data is nil"
	}
	y, err := yaml.Marshal(cd)
	if err != nil {
		return fmt.Sprintf("Error building full cluster dump: %v", err)
	}
	return string(y)
}

func BuildHTMLReport(data *ReportData, tpl string) string {
	tmpl, err := template.New("report").Parse(tpl)
	if err != nil {
		return fmt.Sprintf("Error building report: %v", err)
	}
	var sb strings.Builder
	if err := tmpl.Execute(&sb, data); err != nil {
		return fmt.Sprintf("Error rendering template: %v", err)
	}
	return sb.String()
}

func BuildValuesYAML(d *ReportData) string {
	overrides := map[string]string{}

	// For each component in the default resource limits
	for comp, defMap := range d.DefaultResourceAllocations {
		// Grab the final map for the same component
		finalMap := d.FinalResourceAllocations[comp]
		if finalMap == nil {
			continue // skip if there's no final map for this component
		}

		// CPU request override
		if finalCPUReq, ok := finalMap["cpuReq"]; ok {
			if defaultCPUReq, okDef := defMap["cpuReq"]; okDef && finalCPUReq != defaultCPUReq {
				overrides[fmt.Sprintf("%s.resources.requests.cpu", comp)] = finalCPUReq
			}
		}

		// Memory request override
		if finalMemReq, ok := finalMap["memReq"]; ok {
			if defaultMemReq, okDef := defMap["memReq"]; okDef && finalMemReq != defaultMemReq {
				overrides[fmt.Sprintf("%s.resources.requests.memory", comp)] = finalMemReq
			}
		}

		// CPU limit override
		if finalCPULim, ok := finalMap["cpuLim"]; ok {
			if defaultCPULim, okDef := defMap["cpuLim"]; okDef && finalCPULim != defaultCPULim {
				overrides[fmt.Sprintf("%s.resources.limits.cpu", comp)] = finalCPULim
			}
		}

		// Memory limit override
		if finalMemLim, ok := finalMap["memLim"]; ok {
			if defaultMemLim, okDef := defMap["memLim"]; okDef && finalMemLim != defaultMemLim {
				overrides[fmt.Sprintf("%s.resources.limits.memory", comp)] = finalMemLim
			}
		}
	}

	// If no overrides, just return a comment
	if len(overrides) == 0 {
		return "# no adjustments are required for the default values\n"
	}

	// Build the partial YAML for each known component
	var sb strings.Builder
	sb.WriteString(buildYamlSection("nodeAgent", overrides,
		[]string{"requests.cpu", "requests.memory", "limits.cpu", "limits.memory"}))
	sb.WriteString(buildYamlSection("storage", overrides,
		[]string{"requests.memory", "limits.memory"}))
	sb.WriteString(buildYamlSection("kubevuln", overrides,
		[]string{"requests.memory", "limits.memory"}))

	return sb.String()
}

func addIfOverride(overrides map[string]string, key, defaultVal, finalVal string) {
	if finalVal != defaultVal {
		overrides[key] = finalVal
	}
}

func buildYamlSection(componentName string, overrides map[string]string, keys []string) string {
	fields := map[string]string{}
	for _, k := range keys {
		fullKey := fmt.Sprintf("%s.resources.%s", componentName, k)
		fields[k] = overrides[fullKey]
	}
	return buildComponentSection(componentName, "resources", fields)
}

// buildComponentSection is the final sub-snippet for generating the partial YAML
func buildComponentSection(componentName, subSection string, fields map[string]string) string {
	// Check if there's any override
	hasData := false
	for _, val := range fields {
		if val != "" {
			hasData = true
			break
		}
	}
	if !hasData {
		return ""
	}

	var sb strings.Builder
	sb.WriteString(fmt.Sprintf("%s:\n", componentName))
	sb.WriteString(fmt.Sprintf("  %s:\n", subSection))

	// "requests" block
	requests := []string{}
	if fields["requests.cpu"] != "" {
		requests = append(requests, fmt.Sprintf("      cpu: %s", fields["requests.cpu"]))
	}
	if fields["requests.memory"] != "" {
		requests = append(requests, fmt.Sprintf("      memory: %s", fields["requests.memory"]))
	}
	if len(requests) > 0 {
		sb.WriteString("    requests:\n")
		for _, line := range requests {
			sb.WriteString(line + "\n")
		}
	}

	// "limits" block
	limits := []string{}
	if fields["limits.cpu"] != "" {
		limits = append(limits, fmt.Sprintf("      cpu: %s", fields["limits.cpu"]))
	}
	if fields["limits.memory"] != "" {
		limits = append(limits, fmt.Sprintf("      memory: %s", fields["limits.memory"]))
	}
	if len(limits) > 0 {
		sb.WriteString("    limits:\n")
		for _, line := range limits {
			sb.WriteString(line + "\n")
		}
	}

	return sb.String()
}

func summarizeMap(counts map[string]int, totalCount int) string {
	if len(counts) == 1 {
		// If there's exactly one key, we might just return that key (or "Linux (7)" depending on preference)
		for key, c := range counts {
			if c == totalCount {
				return key // e.g., all 10 are "Linux"
			}
			// If there's a single key but it doesn't match totalCount, display "Linux (7)"
			return fmt.Sprintf("%s (%d)", key, c)
		}
	}

	// multiple distinct keys: "Linux (7), Windows (3)"
	var parts []string
	for key, c := range counts {
		parts = append(parts, fmt.Sprintf("%s (%d)", key, c))
	}
	return strings.Join(parts, ", ")
}
