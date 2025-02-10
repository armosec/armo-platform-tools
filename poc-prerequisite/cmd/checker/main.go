package main

import (
	"context"
	"log"

	"github.com/armosec/armo-platform-tools/poc-prerequisite/pkg/checks/sizing"
	"github.com/armosec/armo-platform-tools/poc-prerequisite/pkg/common"
)

func main() {
	clientset, inCluster := common.BuildKubeClient()
	if clientset == nil {
		log.Fatal("Could not create kube client. Exiting.")
	}

	ctx := context.Background()

	clusterData, err := common.CollectClusterData(ctx, clientset)
	if err != nil {
		log.Printf("Failed to collect cluster data: %v", err)
	}

	// Run the prerequisites checkes
	sizingReportData := sizing.RunSizingChecker(ctx, clientset, clusterData)

	// Generate the output
	common.GenerateOutput(sizingReportData, inCluster)

}
