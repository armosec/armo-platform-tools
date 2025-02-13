package common

import (
	appsv1 "k8s.io/api/apps/v1"
	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
)

type SizingResult struct {
	TotalResources          int
	MaxNodeCPUCapacity      int
	MaxNodeMemoryMB         int
	LargestContainerImageMB int

	// Final recommended resource allocations for each component
	FinalResourceAllocations map[string]map[string]string
	// Default resource allocations (if you need them, or remove if not)
	DefaultResourceAllocations map[string]map[string]string

	// Whether any resource changed from default
	HasAnyAdjustments bool
}

type NodeInfoSummary struct {
	OperatingSystemCounts         map[string]int
	ArchitectureCounts            map[string]int
	KernelVersionCounts           map[string]int
	OSImageCounts                 map[string]int
	ContainerRuntimeVersionCounts map[string]int
	KubeletVersionCounts          map[string]int
	KubeProxyVersionCounts        map[string]int
}

// ClusterDetails stores metadata about the cluster
type ClusterDetails struct {
	Name            string
	Version         string
	CloudProvider   string
	K8sDistribution string
	TotalNodeCount  int
	TotalVCPUCount  int
}

// ClusterData aggregates everything we collect from the cluster.
type ClusterData struct {
	Nodes        []corev1.Node
	Pods         []corev1.Pod
	Services     []corev1.Service
	Deployments  []appsv1.Deployment
	ReplicaSets  []appsv1.ReplicaSet
	StatefulSets []appsv1.StatefulSet
	DaemonSets   []appsv1.DaemonSet
	Jobs         []batchv1.Job
	CronJobs     []batchv1.CronJob

	ClusterDetails    ClusterDetails
	NodeInfoSummaries NodeInfoSummary
}

type ReportData struct {
	TotalResources          int
	MaxNodeCPUCapacity      int
	MaxNodeMemoryMB         int
	LargestContainerImageMB int

	DefaultResourceAllocations map[string]map[string]string
	FinalResourceAllocations   map[string]map[string]string

	KubernetesVersion string
	CloudProvider     string
	K8sDistribution   string
	TotalNodeCount    int
	TotalVCPUCount    int

	GenerationTime    string
	HasAnyAdjustments bool

	NodeOSSummary               string
	NodeArchSummary             string
	NodeKernelVersionSummary    string
	NodeOSImageSummary          string
	NodeContainerRuntimeSummary string
	NodeKubeletVersionSummary   string
	NodeKubeProxyVersionSummary string

	FullClusterData *ClusterData

	PVProvisioningMessage string
}
