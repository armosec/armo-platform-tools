package main

import (
	"context"
	"log"
	"os"
	"path/filepath"
	"strings"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/client-go/discovery"
	"k8s.io/client-go/dynamic"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

func buildKubeClient() (bool, *rest.Config, *kubernetes.Clientset) {
	inCluster := true
	config, err := rest.InClusterConfig()
	if err != nil {
		// Fallback to local kubeconfig => we're not in-cluster
		inCluster = false
		kubeconfig := filepath.Join(os.Getenv("HOME"), ".kube", "config")
		config, err = clientcmd.BuildConfigFromFlags("", kubeconfig)
		if err != nil {
			log.Printf("Could not load in-cluster or local kubeconfig: %v", err)
			return inCluster, nil, nil
		}
	}

	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		log.Printf("Failed to create Kubernetes clientset: %v", err)
		return inCluster, nil, nil
	}

	return inCluster, config, clientset
}

func getTotalResources(ctx context.Context, config *rest.Config) int {
	dynamicClient, err := dynamic.NewForConfig(config)
	if err != nil {
		log.Printf("Error creating dynamic client: %v", err)
		return 0
	}
	discoClient, err := discovery.NewDiscoveryClientForConfig(config)
	if err != nil {
		log.Printf("Error creating discovery client: %v", err)
		return 0
	}

	resourceLists, err := discoClient.ServerPreferredResources()
	if err != nil {
		log.Printf("Error listing server resources: %v", err)
		return 0
	}

	total := 0
	for _, rl := range resourceLists {
		gv, err := schema.ParseGroupVersion(rl.GroupVersion)
		if err != nil {
			continue
		}
		for _, r := range rl.APIResources {
			if strings.Contains(r.Name, "/") {
				continue
			}
			if !sliceContains(r.Verbs, "list") {
				continue
			}
			gvr := schema.GroupVersionResource{Group: gv.Group, Version: gv.Version, Resource: r.Name}
			list, err := dynamicClient.Resource(gvr).List(ctx, metav1.ListOptions{})
			if err != nil {
				log.Printf("failed to list %s: %v", gvr, err)
				continue
			}
			total += len(list.Items)
		}
	}
	return total
}

func getNodeStats(ctx context.Context, clientset *kubernetes.Clientset) (int, int, int) {
	nodes, err := clientset.CoreV1().Nodes().List(ctx, metav1.ListOptions{})
	if err != nil {
		log.Printf("Failed to list nodes: %v", err)
		// Return fallback guesses
		return 4000, 8192, 0
	}
	if len(nodes.Items) == 0 {
		// Also return fallback if no nodes
		return 4000, 8192, 0
	}

	var maxCPU, maxMem, largestImageBytes int64
	for _, node := range nodes.Items {
		cpuQuantity := node.Status.Capacity.Cpu()
		memQuantity := node.Status.Capacity.Memory()

		cpuMilli := cpuQuantity.MilliValue()
		memMB := memQuantity.Value() / (1024 * 1024)

		// Track max CPU
		if cpuMilli > maxCPU {
			maxCPU = cpuMilli
		}
		// Track max memory
		if memMB > maxMem {
			maxMem = memMB
		}

		// Track largest image
		for _, image := range node.Status.Images {
			if image.SizeBytes > largestImageBytes {
				largestImageBytes = image.SizeBytes
			}
		}
	}

	return int(maxCPU), int(maxMem), int(largestImageBytes / (1024 * 1024))
}

func sliceContains(slice []string, val string) bool {
	for _, s := range slice {
		if s == val {
			return true
		}
	}
	return false
}
