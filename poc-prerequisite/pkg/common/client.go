// pkg/common/client.go
package common

import (
	"log"
	"os"
	"path/filepath"

	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

func BuildKubeClient() (*kubernetes.Clientset, bool) {
	inCluster := true
	config, err := rest.InClusterConfig()
	if err != nil {
		// Fallback to local kubeconfig => we're not in-cluster
		inCluster = false
		kubeconfig := filepath.Join(os.Getenv("HOME"), ".kube", "config")
		config, err = clientcmd.BuildConfigFromFlags("", kubeconfig)
		if err != nil {
			log.Printf("Could not load in-cluster or local kubeconfig: %v", err)
			return nil, inCluster
		}
	}

	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		log.Printf("Failed to create Kubernetes clientset: %v", err)
		return nil, inCluster
	}

	return clientset, inCluster
}
