// output_writer.go
package main

import (
	"context"
	"fmt"
	"log"
	"os"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

// Helper function to print a separator line
func printSeparator() {
	fmt.Println("------------------------------------------------------------")
}

// Helper function to print the Helm upgrade command instructions
func printHelmInstructions() {
	fmt.Println("🚀 Use the following command to apply recommended resources:")
	fmt.Println("    helm upgrade --install kubescape kubescape/kubescape-operator \\")
	fmt.Println("     --namespace kubescape --create-namespace \\")
	fmt.Println("     --values recommended-values.yaml [other parameters or value files here]")
}

// Helper function to print the sizing report generation success message for local disk
func printDiskSuccess() {
	printSeparator()
	fmt.Println("✅ Sizing report generated locally!")
	fmt.Println("   • sizing-report.html (HTML report)")
	fmt.Println("   • recommended-values.yaml (Helm values file)")
	fmt.Println("")
	fmt.Println("📋 Open ./sizing-report.html in your browser for details.")
	printHelmInstructions()
	printSeparator()
}

// Helper function to print the sizing report storage success message for ConfigMap
func printConfigMapSuccess() {
	printSeparator()
	fmt.Println("✅ Sizing report stored in Kubernetes ConfigMap!")
	fmt.Println("   • ConfigMap Name: sizing-report")
	fmt.Println("   • Namespace: kubescape")
	printSeparator()
	fmt.Println("")
	fmt.Println("📋 To export the report and recommended values to local files, run the following commands:")
	fmt.Println("    kubectl get configmap sizing-report -n kubescape -o go-template='{{ index .data \"sizing-report.html\" }}' > sizing-report.html")
	fmt.Println("    kubectl get configmap sizing-report -n kubescape -o go-template='{{ index .data \"recommended-values.yaml\" }}' > recommended-values.yaml")
	fmt.Println("")
	printHelmInstructions()
	printSeparator()
}

// writeToDisk writes the HTML and YAML content to local disk and prints instructions.
func writeToDisk(htmlContent, yamlContent string) {
	// Write the HTML report
	if err := os.WriteFile("sizing-report.html", []byte(htmlContent), 0644); err != nil {
		log.Fatalf("Could not write HTML report: %v", err)
	}

	// Write the recommended values YAML
	if err := os.WriteFile("recommended-values.yaml", []byte(yamlContent), 0644); err != nil {
		log.Fatalf("Could not write recommended-values.yaml: %v", err)
	}

	// Print success messages and instructions for local disk
	printDiskSuccess()
}

// writeToConfigMap writes the HTML and YAML content to a Kubernetes ConfigMap and prints instructions.
func writeToConfigMap(htmlContent, yamlContent string) {
	// Build in-cluster Kubernetes client configuration
	config, err := rest.InClusterConfig()
	if err != nil {
		log.Fatalf("Failed to build in-cluster config: %v", err)
	}

	// Create Kubernetes clientset
	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		log.Fatalf("Failed to create Kubernetes client: %v", err)
	}

	// Define the ConfigMap name and namespace
	configMapName := "sizing-report"
	namespace := "kubescape"

	// Prepare the ConfigMap data
	configMap := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:      configMapName,
			Namespace: namespace,
		},
		Data: map[string]string{
			"sizing-report.html":      htmlContent,
			"recommended-values.yaml": yamlContent,
		},
	}

	// Attempt to create the ConfigMap
	_, err = clientset.CoreV1().ConfigMaps(namespace).Create(context.Background(), configMap, metav1.CreateOptions{})
	if err != nil {
		// If the ConfigMap already exists, attempt to update it
		_, err = clientset.CoreV1().ConfigMaps(namespace).Update(context.Background(), configMap, metav1.UpdateOptions{})
		if err != nil {
			log.Fatalf("Failed to create or update ConfigMap: %v", err)
		}
	}

	// Print success messages and instructions for ConfigMap
	printConfigMapSuccess()
}
