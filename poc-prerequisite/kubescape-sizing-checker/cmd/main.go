package main

import (
	"context"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/discovery"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

// Default values from the Helm chart:
var (
	defaultNodeAgentCPUReq = "100m"
	defaultNodeAgentCPULim = "500m"
	defaultNodeAgentMemReq = "180Mi"
	defaultNodeAgentMemLim = "700Mi"

	defaultStorageMemReq = "400Mi"
	defaultStorageMemLim = "1500Mi"

	defaultKubevulnMemReq = "1000Mi"
	defaultKubevulnMemLim = "5000Mi"
)

// Used to structure data passed to HTML templates
type reportData struct {
	TotalResources          int
	AverageNodeCPUCapacity  int
	AverageNodeMemoryMB     int
	LargestContainerImageMB int

	FinalNodeAgentCPUReq string
	FinalNodeAgentCPULim string
	FinalNodeAgentMemReq string
	FinalNodeAgentMemLim string

	FinalStorageMemReq string
	FinalStorageMemLim string

	FinalKubevulnMemReq string
	FinalKubevulnMemLim string
}

func main() {
	// 1) Build Kubernetes client
	config, clientset, err := buildKubeClient()
	if err != nil {
		log.Fatalf("Failed to build Kube client: %v", err)
	}

	// 2) Gather data
	ctx := context.Background()
	totalResources, err := getTotalResources(ctx, config)
	if err != nil {
		log.Printf("Error gathering total resources: %v", err)
		totalResources = 0
	}

	avgCPU, avgMem := getAverageNodeCapacity(ctx, clientset)
	largestImageMB := getLargestContainerImage(ctx, clientset)

	// 3) Calculate recommended resources
	// nodeAgent
	recNodeAgentCPUReq, recNodeAgentCPULim := calculateNodeAgentCPU(avgCPU)
	recNodeAgentMemReq, recNodeAgentMemLim := calculateNodeAgentMemory(avgMem)

	// storage
	recStorageMemReq, recStorageMemLim := calculateStorageMemory(totalResources)

	// kubevuln
	recKubevulnMemReq, recKubevulnMemLim := calculateKubevulnMemory(largestImageMB)

	// 4) Compare with defaults => final
	finalNodeAgentCPUReq := compareAndChoose(defaultNodeAgentCPUReq, recNodeAgentCPUReq)
	finalNodeAgentCPULim := compareAndChoose(defaultNodeAgentCPULim, recNodeAgentCPULim)
	finalNodeAgentMemReq := compareAndChoose(defaultNodeAgentMemReq, recNodeAgentMemReq)
	finalNodeAgentMemLim := compareAndChoose(defaultNodeAgentMemLim, recNodeAgentMemLim)

	finalStorageMemReq := compareAndChoose(defaultStorageMemReq, recStorageMemReq)
	finalStorageMemLim := compareAndChoose(defaultStorageMemLim, recStorageMemLim)

	finalKubevulnMemReq := compareAndChoose(defaultKubevulnMemReq, recKubevulnMemReq)
	finalKubevulnMemLim := compareAndChoose(defaultKubevulnMemLim, recKubevulnMemLim)

	// Prepare data for HTML template
	data := &reportData{
		TotalResources:          totalResources,
		AverageNodeCPUCapacity:  avgCPU,
		AverageNodeMemoryMB:     avgMem,
		LargestContainerImageMB: largestImageMB,

		FinalNodeAgentCPUReq: finalNodeAgentCPUReq,
		FinalNodeAgentCPULim: finalNodeAgentCPULim,
		FinalNodeAgentMemReq: finalNodeAgentMemReq,
		FinalNodeAgentMemLim: finalNodeAgentMemLim,

		FinalStorageMemReq: finalStorageMemReq,
		FinalStorageMemLim: finalStorageMemLim,

		FinalKubevulnMemReq: finalKubevulnMemReq,
		FinalKubevulnMemLim: finalKubevulnMemLim,
	}

	// 5) Run an HTTP server to serve this data as HTML
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		tmpl, err := template.New("report").Parse(htmlTemplate)
		if err != nil {
			log.Printf("Error parsing template: %v", err)
			http.Error(w, "template error", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		if err := tmpl.Execute(w, data); err != nil {
			log.Printf("Error executing template: %v", err)
		}
	})

	log.Println("Starting webserver on :8080 ...")
	if err := http.ListenAndServe(":8080", nil); err != nil {
		log.Fatalf("Server failed: %v", err)
	}
}

// buildKubeClient initializes a kubernetes.Clientset using in-cluster config if available,
// otherwise falls back to local kubeconfig.
// buildKubeClient returns both the *rest.Config and the *kubernetes.Clientset.
func buildKubeClient() (*rest.Config, *kubernetes.Clientset, error) {
	// First, try in-cluster config
	config, err := rest.InClusterConfig()
	if err != nil {
		// Fallback to local kubeconfig
		kubeconfig := filepath.Join(
			os.Getenv("HOME"), ".kube", "config",
		)
		config, err = clientcmd.BuildConfigFromFlags("", kubeconfig)
		if err != nil {
			return nil, nil, fmt.Errorf("failed to build kubeconfig: %w", err)
		}
	}

	// Create the Clientset
	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		return nil, nil, fmt.Errorf("failed to create kubernetes clientset: %w", err)
	}

	return config, clientset, nil
}

// getTotalResources retrieves a count of all resources (including CRDs) in the cluster.
func getTotalResources(ctx context.Context, config *rest.Config) (int, error) {
	// Create a dynamic client (needed to list arbitrary resources at runtime)
	dynamicClient, err := dynamic.NewForConfig(config)
	if err != nil {
		return 0, fmt.Errorf("creating dynamic client: %w", err)
	}

	// Create a discovery client (to discover all APIs/resources)
	discoveryClient, err := discovery.NewDiscoveryClientForConfig(config)
	if err != nil {
		return 0, fmt.Errorf("creating discovery client: %w", err)
	}

	// Discover all preferred resources
	apiResourceLists, err := discoveryClient.ServerPreferredResources()
	if err != nil {
		// ServerPreferredResources often returns partial results and an error
		// If you want to handle partial results, you can decide how.
		// For simplicity here, we just return an error if it can't list anything.
		return 0, fmt.Errorf("listing server resources: %w", err)
	}

	totalCount := 0

	// Iterate through all discovered API groups/versions
	for _, apiResourceList := range apiResourceLists {
		groupVersion, err := schema.ParseGroupVersion(apiResourceList.GroupVersion)
		if err != nil {
			// skip malformed groupVersions
			continue
		}

		for _, apiResource := range apiResourceList.APIResources {
			// Skip subresources (e.g., pods/proxy)
			if strings.Contains(apiResource.Name, "/") {
				continue
			}
			// Skip if it cannot be listed
			if !contains(apiResource.Verbs, "list") {
				continue
			}

			// Build the GroupVersionResource needed for the dynamic client
			gvr := schema.GroupVersionResource{
				Group:    groupVersion.Group,
				Version:  groupVersion.Version,
				Resource: apiResource.Name,
			}

			// List the resource across all namespaces if it's Namespaced,
			// or at cluster scope if it's not Namespaced
			list, err := dynamicClient.Resource(gvr).List(ctx, metav1.ListOptions{})
			if err != nil {
				// In a real-world scenario, you might want to handle partial successes.
				// For brevity, we'll just log and continue.
				log.Printf("failed to list %s: %v", gvr.String(), err)
				continue
			}

			totalCount += len(list.Items)
		}
	}

	return totalCount, nil
}

// Helper function to check if a verb is supported
func contains(verbs []string, verb string) bool {
	for _, v := range verbs {
		if v == verb {
			return true
		}
	}
	return false
}

// getAverageNodeCapacity sums the CPU/memory capacity across all nodes, divides by node count
func getAverageNodeCapacity(ctx context.Context, clientset *kubernetes.Clientset) (int, int) {
	nodes, err := clientset.CoreV1().Nodes().List(ctx, metav1.ListOptions{})
	if err != nil || len(nodes.Items) == 0 {
		// fallback guess: 4000m CPU, 8192Mi memory
		return 4000, 8192
	}

	var totalCPU, totalMem int64
	for _, node := range nodes.Items {
		cpuQuantity := node.Status.Capacity.Cpu()
		memQuantity := node.Status.Capacity.Memory()

		// Convert CPU to milli
		totalCPU += cpuQuantity.MilliValue()
		// Convert memory to Mi
		memMB := memQuantity.Value() / (1024 * 1024)
		totalMem += memMB
	}

	count := int64(len(nodes.Items))
	avgCPU := int(totalCPU / count)
	avgMem := int(totalMem / count)
	return avgCPU, avgMem
}

// getLargestContainerImage inspects node.Status.Images to find the biggest image by sizeBytes
func getLargestContainerImage(ctx context.Context, clientset *kubernetes.Clientset) int {
	nodes, err := clientset.CoreV1().Nodes().List(ctx, metav1.ListOptions{})
	if err != nil {
		log.Printf("Failed to list nodes: %v", err)
		return 0
	}
	var largest int64
	for _, node := range nodes.Items {
		for _, image := range node.Status.Images {
			if image.SizeBytes > largest {
				largest = image.SizeBytes
			}
		}
	}
	// Convert bytes to MB
	return int(largest / (1024 * 1024))
}

// According to sizing guide: nodeAgent request ~2.5% CPU, limit ~10%.
func calculateNodeAgentCPU(avgCPU int) (string, string) {
	req := float64(avgCPU) * 0.025
	lim := float64(avgCPU) * 0.10
	return fmt.Sprintf("%.0fm", req), fmt.Sprintf("%.0fm", lim)
}

// nodeAgent memory request ~2.5%, limit ~10%.
func calculateNodeAgentMemory(avgMemMB int) (string, string) {
	req := float64(avgMemMB) * 0.025
	lim := float64(avgMemMB) * 0.10
	return fmt.Sprintf("%.0fMi", req), fmt.Sprintf("%.0fMi", lim)
}

// storage: memory request = 0.2 x (# resources), limit = 0.8 x (# resources).
func calculateStorageMemory(total int) (string, string) {
	r := float64(total) * 0.2
	l := float64(total) * 0.8
	return fmt.Sprintf("%.0fMi", r), fmt.Sprintf("%.0fMi", l)
}

// kubevuln: if building SBOM, limit >= largestImageMB + 400MB, request ~ 1/4 of that.
func calculateKubevulnMemory(largestImgMB int) (string, string) {
	limit := float64(largestImgMB) + 400.0
	req := limit / 4.0
	return fmt.Sprintf("%.0fMi", req), fmt.Sprintf("%.0fMi", limit)
}

// compareAndChoose returns whichever is larger: the default or the recommended.
func compareAndChoose(defaultVal, recommendedVal string) string {
	defVal, defUnit := parseResource(defaultVal)
	recVal, recUnit := parseResource(recommendedVal)
	// If units differ, keep default. (Simplified approach)
	if defUnit != recUnit {
		return defaultVal
	}
	// Compare numeric
	if recVal > defVal {
		return recommendedVal
	}
	return defaultVal
}

func parseResource(val string) (float64, string) {
	// Very simplified parser for e.g. "100m", "500Mi"
	if strings.HasSuffix(val, "m") {
		num := strings.TrimSuffix(val, "m")
		f, _ := strconv.ParseFloat(num, 64)
		return f, "m"
	} else if strings.HasSuffix(val, "Mi") {
		num := strings.TrimSuffix(val, "Mi")
		f, _ := strconv.ParseFloat(num, 64)
		return f, "Mi"
	}
	// fallback
	f, _ := strconv.ParseFloat(val, 64)
	return f, ""
}

const htmlTemplate = `
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8"/>
    <title>Kubescape Sizing Checker</title>
</head>
<body>
    <h1>Kubescape Sizing Checker Results</h1>
    <h2>Cluster Summary</h2>
    <ul>
        <li>Total Resources: {{.TotalResources}}</li>
        <li>Avg Node CPU Capacity (m): {{.AverageNodeCPUCapacity}}</li>
        <li>Avg Node Memory (Mi): {{.AverageNodeMemoryMB}}</li>
        <li>Largest Container Image (MB): {{.LargestContainerImageMB}}</li>
    </ul>

    <h2>Recommended vs. Final Values (Comparisons with Defaults)</h2>

    <h3>Node Agent</h3>
    <p>CPU Request: {{.FinalNodeAgentCPUReq}}</p>
    <p>CPU Limit: {{.FinalNodeAgentCPULim}}</p>
    <p>Memory Request: {{.FinalNodeAgentMemReq}}</p>
    <p>Memory Limit: {{.FinalNodeAgentMemLim}}</p>

    <h3>Storage</h3>
    <p>Memory Request: {{.FinalStorageMemReq}}</p>
    <p>Memory Limit: {{.FinalStorageMemLim}}</p>

    <h3>KubeVuln</h3>
    <p>Memory Request: {{.FinalKubevulnMemReq}}</p>
    <p>Memory Limit: {{.FinalKubevulnMemLim}}</p>

    <h2>Helm Overrides (if recommended &gt; defaults)</h2>
    <p>
    <code>
--set nodeAgent.resources.requests.cpu={{.FinalNodeAgentCPUReq}} \\
--set nodeAgent.resources.requests.memory={{.FinalNodeAgentMemReq}} \\
--set nodeAgent.resources.limits.cpu={{.FinalNodeAgentCPULim}} \\
--set nodeAgent.resources.limits.memory={{.FinalNodeAgentMemLim}} \\
--set storage.resources.requests.memory={{.FinalStorageMemReq}} \\
--set storage.resources.limits.memory={{.FinalStorageMemLim}} \\
--set kubevuln.resources.requests.memory={{.FinalKubevulnMemReq}} \\
--set kubevuln.resources.limits.memory={{.FinalKubevulnMemLim}}
    </code>
    </p>
</body>
</html>
`
