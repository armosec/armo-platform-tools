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

func printDiskSuccess(reportPath, valuesPath, dumpPath string) {
	printSeparator()
	fmt.Println("✅ prerequisites report generated locally!")
	fmt.Println("   •", reportPath, "(HTML report)")
	fmt.Println("   •", valuesPath, "(Helm values file)")
	fmt.Println("   •", dumpPath, "(Full cluster dump)")
	fmt.Println("")
	fmt.Println("📋 Open", reportPath, "in your browser for details.")
	printHelmInstructions()
	printSeparator()
}

func printConfigMapSuccess() {
	printSeparator()
	fmt.Println("✅ prerequisites report stored in Kubernetes ConfigMap!")
	fmt.Println("   • ConfigMap Name: kubescape-prerequisites-report")
	fmt.Println("   • Namespace: default")
	printSeparator()
	fmt.Println("")
	fmt.Println("⬇️  To export the report files locally:")
	fmt.Println("    kubectl get configmap kubescape-prerequisites-report -n default -o go-template='{{ index .data \"prerequisites-report.html\" }}' > prerequisites-report.html")
	fmt.Println("    kubectl get configmap kubescape-prerequisites-report -n default -o go-template='{{ index .data \"recommended-values.yaml\" }}' > recommended-values.yaml")
	fmt.Println("    kubectl get configmap kubescape-prerequisites-report -n default -o go-template='{{ index .data \"full-cluster-dump.yaml\" }}' > full-cluster-dump.yaml")
	fmt.Println("")
	fmt.Println("📋 Open prerequisites-report.html in your browser for details.")
	printHelmInstructions()
	printSeparator()
}

func WriteToDisk(htmlContent, helmValuesContent, fullDumpContent string) {
	// 1) Write the HTML report
	reportPath := filepath.Join(os.TempDir(), "prerequisites-report.html")
	if err := os.WriteFile(reportPath, []byte(htmlContent), 0644); err != nil {
		log.Fatalf("Could not write HTML report: %v", err)
	}

	// 2) Write the recommended values YAML
	valuesPath := filepath.Join(os.TempDir(), "recommended-values.yaml")
	if err := os.WriteFile(valuesPath, []byte(helmValuesContent), 0644); err != nil {
		log.Fatalf("Could not write recommended-values.yaml: %v", err)
	}

	// 3) Write the full cluster dump
	dumpPath := filepath.Join(os.TempDir(), "full-cluster-dump.yaml")
	if err := os.WriteFile(dumpPath, []byte(fullDumpContent), 0644); err != nil {
		log.Fatalf("Could not write full-cluster-dump.yaml: %v", err)
	}

	// 4) Print success messages and instructions for local disk
	printDiskSuccess(reportPath, valuesPath, dumpPath)
}

func WriteToConfigMap(htmlContent, helmValuesContent, fullDumpContent string) {
	// Build in-cluster Kubernetes client configuration
	config, err := rest.InClusterConfig()
	if err != nil {
		log.Fatalf("Failed to build in-cluster config: %v", err)
	}

	// Create clientset
	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		log.Fatalf("Failed to create Kubernetes client: %v", err)
	}

	configMapName := "kubescape-prerequisites-report"
	namespace := "default"

	configMap := &corev1.ConfigMap{
		ObjectMeta: metav1.ObjectMeta{
			Name:      configMapName,
			Namespace: namespace,
		},
		Data: map[string]string{
			"prerequisites-report.html": htmlContent,
			"recommended-values.yaml":   helmValuesContent,
			"full-cluster-dump.yaml":    fullDumpContent,
		},
	}

	// Create or Update
	_, err = clientset.CoreV1().ConfigMaps(namespace).Create(context.Background(), configMap, metav1.CreateOptions{})
	if err != nil {
		log.Printf("Failed to create ConfigMap: %v", err)
		_, err = clientset.CoreV1().ConfigMaps(namespace).Update(context.Background(), configMap, metav1.UpdateOptions{})
		if err != nil {
			log.Fatalf("Failed to update ConfigMap: %v", err)
		}
	}

	printConfigMapSuccess()
}

func GenerateOutput(sizingReportData *ReportData, inCluster bool) {
	htmlContent := BuildHTMLReport(sizingReportData, PrerequisitesReportHTML)
	yamlContent := BuildValuesYAML(sizingReportData)
	fullDumpContent := BuildFullDumpYAML(sizingReportData.FullClusterData)

	if inCluster {
		WriteToConfigMap(htmlContent, yamlContent, fullDumpContent)
	} else {
		WriteToDisk(htmlContent, yamlContent, fullDumpContent)
	}
}
