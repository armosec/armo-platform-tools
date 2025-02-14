package common

import (
	"context"
	"log"
	"strings"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
)

func CollectClusterData(ctx context.Context, clientset *kubernetes.Clientset) (*ClusterData, error) {
	cd := &ClusterData{}

	// 1) Get the Kubernetes version
	kubeVersion, err := clientset.Discovery().ServerVersion()
	if err != nil {
		log.Fatalf("Cannot access cluster: %v", err)
	}
	cd.ClusterDetails.Version = kubeVersion.String()

	// 2) List nodes
	nodes, err := clientset.CoreV1().Nodes().List(ctx, metav1.ListOptions{})
	if err != nil {
		log.Printf("Failed to list nodes: %v", err)
		return cd, err
	}
	cd.Nodes = nodes.Items

	gatherNodeInfoSummaries(&cd.NodeInfoSummaries, nodes.Items)

	// 3) Detect Cloud Provider & Distribution from nodes
	cd.ClusterDetails.CloudProvider = detectCloudProvider(nodes.Items)
	cd.ClusterDetails.K8sDistribution = detectK8sDistribution(nodes.Items)

	// 4) Calculate total node count & total vCPUs
	cd.ClusterDetails.TotalNodeCount = len(nodes.Items)
	var totalMilliCPU int64
	for _, node := range nodes.Items {
		totalMilliCPU += node.Status.Capacity.Cpu().MilliValue()
	}
	cd.ClusterDetails.TotalVCPUCount = int(totalMilliCPU / 1000)

	// 5) List other resources
	pods, err := clientset.CoreV1().Pods("").List(ctx, metav1.ListOptions{})
	if err != nil {
		log.Printf("Failed to list pods: %v", err)
		return cd, err
	}
	cd.Pods = pods.Items

	services, err := clientset.CoreV1().Services("").List(ctx, metav1.ListOptions{})
	if err != nil {
		log.Printf("Failed to list services: %v", err)
		return cd, err
	}
	cd.Services = services.Items

	deployments, err := clientset.AppsV1().Deployments("").List(ctx, metav1.ListOptions{})
	if err != nil {
		log.Printf("Failed to list deployments: %v", err)
		return cd, err
	}
	cd.Deployments = deployments.Items

	replicasets, err := clientset.AppsV1().ReplicaSets("").List(ctx, metav1.ListOptions{})
	if err != nil {
		log.Printf("Failed to list replicasets: %v", err)
		return cd, err
	}
	cd.ReplicaSets = replicasets.Items

	statefulsets, err := clientset.AppsV1().StatefulSets("").List(ctx, metav1.ListOptions{})
	if err != nil {
		log.Printf("Failed to list statefulsets: %v", err)
		return cd, err
	}
	cd.StatefulSets = statefulsets.Items

	daemonsets, err := clientset.AppsV1().DaemonSets("").List(ctx, metav1.ListOptions{})
	if err != nil {
		log.Printf("Failed to list daemonsets: %v", err)
		return cd, err
	}
	cd.DaemonSets = daemonsets.Items

	jobs, err := clientset.BatchV1().Jobs("").List(ctx, metav1.ListOptions{})
	if err != nil {
		log.Printf("Failed to list jobs: %v", err)
		return cd, err
	}
	cd.Jobs = jobs.Items

	cronjobs, err := clientset.BatchV1().CronJobs("").List(ctx, metav1.ListOptions{})
	if err != nil {
		log.Printf("Failed to list cronjobs: %v", err)
		return cd, err
	}
	cd.CronJobs = cronjobs.Items

	stripManagedFields(cd)

	return cd, nil
}

func stripManagedFields(cd *ClusterData) {
	// Remove from Nodes
	for i := range cd.Nodes {
		cd.Nodes[i].ManagedFields = nil
	}

	// Remove from Pods
	for i := range cd.Pods {
		cd.Pods[i].ManagedFields = nil
	}

	// Remove from Services
	for i := range cd.Services {
		cd.Services[i].ManagedFields = nil
	}

	// Remove from Deployments
	for i := range cd.Deployments {
		cd.Deployments[i].ManagedFields = nil
	}

	// Remove from ReplicaSets
	for i := range cd.ReplicaSets {
		cd.ReplicaSets[i].ManagedFields = nil
	}

	// Remove from StatefulSets
	for i := range cd.StatefulSets {
		cd.StatefulSets[i].ManagedFields = nil
	}

	// Remove from DaemonSets
	for i := range cd.DaemonSets {
		cd.DaemonSets[i].ManagedFields = nil
	}

	// Remove from Jobs
	for i := range cd.Jobs {
		cd.Jobs[i].ManagedFields = nil
	}

	// Remove from CronJobs
	for i := range cd.CronJobs {
		cd.CronJobs[i].ManagedFields = nil
	}
}

// detectCloudProvider uses node.Spec.ProviderID or node labels to guess the cloud
func detectCloudProvider(nodes []corev1.Node) string {
	for _, node := range nodes {
		pid := node.Spec.ProviderID
		// Many providers set providerID like: "aws:///<region>/<instanceID>", "gce:///<projectID>/<zone>/<instanceID>", etc.
		if strings.HasPrefix(pid, "aws://") {
			return "AWS"
		}
		if strings.HasPrefix(pid, "gce://") {
			return "GCP"
		}
		if strings.HasPrefix(pid, "azure://") {
			return "Azure"
		}
		if strings.HasPrefix(pid, "digitalocean://") {
			return "DigitalOcean"
		}
		// Some providers might use openstack://, vsphere://, etc.
		// Add more as needed
	}
	return "Unknown"
}

// detectK8sDistribution looks at node labels for known distributions (EKS, GKE, AKS, OpenShift, Rancher, etc.)
func detectK8sDistribution(nodes []corev1.Node) string {
	for _, node := range nodes {
		for labelKey := range node.Labels {
			// EKS nodes typically have labels like: "eks.amazonaws.com/nodegroup"
			if strings.Contains(labelKey, "eks.amazonaws.com") {
				return "EKS"
			}
			// GKE usually has: "cloud.google.com/gke-nodepool"
			if strings.Contains(labelKey, "cloud.google.com/gke-nodepool") {
				return "GKE"
			}
			// AKS typically: "kubernetes.azure.com/cluster" or "agentpool=..."
			if strings.Contains(labelKey, "kubernetes.azure.com") {
				return "AKS"
			}
			// OpenShift often has: "machine.openshift.io/machine"
			if strings.Contains(labelKey, "openshift") {
				return "OpenShift"
			}
			// Rancher RKE: might have "cattle.io/creator" or "rke.cattle.io"
			if strings.Contains(labelKey, "rke.cattle.io") || strings.Contains(labelKey, "cattle.io") {
				return "RKE"
			}
			// DigitalOcean: "doks.digitalocean.com" label
			if strings.Contains(labelKey, "doks.digitalocean.com") {
				return "DOKS"
			}
			// Add more checks if needed (K3s, etc.)
		}
	}
	return "Unknown"
}

func gatherNodeInfoSummaries(summaries *NodeInfoSummary, nodes []corev1.Node) {
	// Initialize all maps
	summaries.OperatingSystemCounts = make(map[string]int)
	summaries.ArchitectureCounts = make(map[string]int)
	summaries.KernelVersionCounts = make(map[string]int)
	summaries.OSImageCounts = make(map[string]int)
	summaries.ContainerRuntimeVersionCounts = make(map[string]int)
	summaries.KubeletVersionCounts = make(map[string]int)
	summaries.KubeProxyVersionCounts = make(map[string]int)

	for _, node := range nodes {
		ni := node.Status.NodeInfo

		summaries.OperatingSystemCounts[ni.OperatingSystem]++
		summaries.ArchitectureCounts[ni.Architecture]++
		summaries.KernelVersionCounts[ni.KernelVersion]++
		summaries.OSImageCounts[ni.OSImage]++
		summaries.ContainerRuntimeVersionCounts[ni.ContainerRuntimeVersion]++
		summaries.KubeletVersionCounts[ni.KubeletVersion]++
		summaries.KubeProxyVersionCounts[ni.KubeProxyVersion]++
	}
}
