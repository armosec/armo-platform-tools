package common

import (
	"context"
	"fmt"
	"log"
	"os"
	"path/filepath"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
)

func printSeparator() {
	fmt.Println("------------------------------------------------------------")
}

func printHelmInstructions() {
	fmt.Println("🚀 Use the generated recommended-values.yaml to optimize Kubescape for your cluster.")
}

func printDiskSuccess(reportPath, valuesPath string) {
	printSeparator()
	fmt.Println("✅ prerequisites report generated locally!")
	fmt.Println("   •", reportPath, "(HTML report)")
	fmt.Println("   •", valuesPath, "(Helm values file)")
	fmt.Println("")
	fmt.Println("📋 Open", reportPath, "in your browser for details.")
	printHelmInstructions()
	printSeparator()
}

func printConfigMapSuccess() {
	printSeparator()
	fmt.Println("✅ prerequisites report stored in Kubernetes ConfigMap!")
	fmt.Println("   • ConfigMap Name: prerequisites-report")
	fmt.Println("   • Namespace: default")
	printSeparator()
	fmt.Println("")
	fmt.Println("⬇️  To export the report and recommended values to local files, run the following commands:")
	fmt.Println("    kubectl get configmap kubescape-prerequisites-report -n default -o go-template='{{ index .data \"prerequisites-report.html\" }}' > prerequisites-report.html")
	fmt.Println("    kubectl get configmap kubescape-prerequisites-report -n default -o go-template='{{ index .data \"recommended-values.yaml\" }}' > recommended-values.yaml")
	fmt.Println("")
	fmt.Println("📋 Open prerequisites-report.html in your browser for details.")
	printHelmInstructions()
	printSeparator()
}

// WriteToDisk writes the HTML and YAML content to local disk and prints instructions.
func WriteToDisk(htmlContent, yamlContent string) {
	// Write the HTML report
	reportPath := filepath.Join(os.TempDir(), "prerequisites-report.html")
	if err := os.WriteFile(reportPath, []byte(htmlContent), 0644); err != nil {
		log.Fatalf("Could not write HTML report: %v", err)
	}

	// Write the recommended values YAML
	valuesPath := filepath.Join(os.TempDir(), "recommended-values.yaml")
	if err := os.WriteFile(valuesPath, []byte(yamlContent), 0644); err != nil {
		log.Fatalf("Could not write recommended-values.yaml: %v", err)
	}

	// Print success messages and instructions for local disk
	printDiskSuccess(reportPath, valuesPath)
}

// WriteToConfigMap writes the HTML and YAML content to a Kubernetes ConfigMap and prints instructions.
func WriteToConfigMap(htmlContent, yamlContent string) {
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
	configMapName := "kubescape-prerequisites-report"
	namespace := "default"

	// Prepare the ConfigMap data
	configMap := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:      configMapName,
			Namespace: namespace,
		},
		Data: map[string]string{
			"prerequisites-report.html": htmlContent,
			"recommended-values.yaml":   yamlContent,
		},
	}

	// Attempt to create the ConfigMap
	_, err = clientset.CoreV1().ConfigMaps(namespace).Create(context.Background(), configMap, metav1.CreateOptions{})
	if err != nil {
		log.Printf("Failed to create ConfigMap: %v", err)
		// If the ConfigMap already exists, attempt to update it
		_, err = clientset.CoreV1().ConfigMaps(namespace).Update(context.Background(), configMap, metav1.UpdateOptions{})
		if err != nil {
			log.Fatalf("Failed to update ConfigMap: %v", err)
		}
	}

	// Print success messages and instructions for ConfigMap
	printConfigMapSuccess()
}

func GenerateOutput(sizingReportData *ReportData, inCluster bool) {
	htmlContent := BuildHTMLReport(sizingReportData, PrerequisitesReportHTML)
	yamlContent := BuildValuesYAML(sizingReportData)

	if inCluster {
		WriteToConfigMap(htmlContent, yamlContent)
	} else {
		WriteToDisk(htmlContent, yamlContent)
	}
}
