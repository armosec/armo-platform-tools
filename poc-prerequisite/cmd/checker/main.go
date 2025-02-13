package main

import (
	"context"
	"log"

	"github.com/armosec/armo-platform-tools/poc-prerequisite/pkg/checks/pvcheck"
	"github.com/armosec/armo-platform-tools/poc-prerequisite/pkg/checks/sizing"
	"github.com/armosec/armo-platform-tools/poc-prerequisite/pkg/common"
)

func main() {
	clientset, inCluster := common.BuildKubeClient()
	if clientset == nil {
		log.Fatal("Could not create kube client. Exiting.")
	}

	ctx := context.Background()

	// 1) Collect cluster data
	clusterData, err := common.CollectClusterData(ctx, clientset)
	if err != nil {
		log.Printf("Failed to collect cluster data: %v", err)
	}

	// 2) Run checks
	sizingResult := sizing.RunSizingChecker(ctx, clientset, clusterData)
	pvResult := pvcheck.RunPVProvisioningCheck(ctx, clientset, clusterData)

	// 3) Build export the final ReportData
	finalReport := common.BuildReportData(clusterData, sizingResult)
	// Attach the new PV check result to the finalReport
	finalReport.PVProvisioningMessage = pvResult.ResultMessage

	common.GenerateOutput(finalReport, inCluster)
}
