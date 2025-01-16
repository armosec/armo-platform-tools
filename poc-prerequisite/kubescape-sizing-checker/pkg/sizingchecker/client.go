package sizingchecker

import (
	"context"
	"log"
	"os"
	"path/filepath"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

func buildKubeClient() (bool, *kubernetes.Clientset) {
	inCluster := true
	config, err := rest.InClusterConfig()
	if err != nil {
		// Fallback to local kubeconfig => we're not in-cluster
		inCluster = false
		kubeconfig := filepath.Join(os.Getenv("HOME"), ".kube", "config")
		config, err = clientcmd.BuildConfigFromFlags("", kubeconfig)
		if err != nil {
			log.Printf("Could not load in-cluster or local kubeconfig: %v", err)
			return inCluster, nil
		}
	}

	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		log.Printf("Failed to create Kubernetes clientset: %v", err)
		return inCluster, nil
	}

	return inCluster, clientset
}

func getTotalResources(ctx context.Context, clientset *kubernetes.Clientset) int {
	if clientset == nil {
		log.Println("clientset is nil")
		return 0
	}

	resourceCounters := []func(context.Context, *kubernetes.Clientset) (int, error){
		func(c context.Context, cs *kubernetes.Clientset) (int, error) {
			list, err := cs.CoreV1().Pods("").List(c, metav1.ListOptions{})
			return len(list.Items), err
		},
		func(c context.Context, cs *kubernetes.Clientset) (int, error) {
			list, err := cs.CoreV1().Services("").List(c, metav1.ListOptions{})
			return len(list.Items), err
		},
		func(c context.Context, cs *kubernetes.Clientset) (int, error) {
			list, err := cs.AppsV1().Deployments("").List(c, metav1.ListOptions{})
			return len(list.Items), err
		},
		func(c context.Context, cs *kubernetes.Clientset) (int, error) {
			list, err := cs.AppsV1().ReplicaSets("").List(c, metav1.ListOptions{})
			return len(list.Items), err
		},
		func(c context.Context, cs *kubernetes.Clientset) (int, error) {
			list, err := cs.AppsV1().StatefulSets("").List(c, metav1.ListOptions{})
			return len(list.Items), err
		},
		func(c context.Context, cs *kubernetes.Clientset) (int, error) {
			list, err := cs.AppsV1().DaemonSets("").List(c, metav1.ListOptions{})
			return len(list.Items), err
		},
		func(c context.Context, cs *kubernetes.Clientset) (int, error) {
			list, err := cs.CoreV1().ReplicationControllers("").List(c, metav1.ListOptions{})
			return len(list.Items), err
		},
		func(c context.Context, cs *kubernetes.Clientset) (int, error) {
			list, err := cs.BatchV1().Jobs("").List(c, metav1.ListOptions{})
			return len(list.Items), err
		},
		func(c context.Context, cs *kubernetes.Clientset) (int, error) {
			list, err := cs.BatchV1().CronJobs("").List(c, metav1.ListOptions{})
			return len(list.Items), err
		},
	}

	var total int
	for _, counter := range resourceCounters {
		n, err := counter(ctx, clientset)
		if err != nil {
			log.Printf("Error listing resources: %v", err)
			continue
		}
		total += n
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
