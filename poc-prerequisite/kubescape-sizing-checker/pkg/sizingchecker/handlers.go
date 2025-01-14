package sizingchecker

import (
	"fmt"
	"html/template"
	"strings"
)

func buildHTMLReport(data *reportData, tpl string) string {
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

func buildValuesYAML(d *reportData) string {
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
