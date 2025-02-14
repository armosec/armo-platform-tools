package main

import (
	"context"
	"flag"
	"log"

	"github.com/armosec/armo-platform-tools/poc-prerequisite/pkg/checks/pvcheck"
	"github.com/armosec/armo-platform-tools/poc-prerequisite/pkg/checks/sizing"
	"github.com/armosec/armo-platform-tools/poc-prerequisite/pkg/common"
)

func main() {
	// Define and parse our flag for active checks
	activeChecks := flag.Bool("active-checks", false, "If set, run checks that require resource deployment on the cluster.")
	flag.Parse()

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

	// Conditionally run resource-deploying checks
	var pvResult *pvcheck.PVCheckResult
	if *activeChecks {
		pvResult = pvcheck.RunPVProvisioningCheck(ctx, clientset, clusterData)
	} else {
		// If not running active checks, fill with a "Skipped" result
		pvResult = &pvcheck.PVCheckResult{
			PassedCount:   0,
			FailedCount:   0,
			TotalNodes:    len(clusterData.Nodes),
			ResultMessage: "Skipped (use --active-checks to run)",
		}
	}

	// 3) Build and export the final ReportData
	finalReport := common.BuildReportData(clusterData, sizingResult)
	finalReport.PVProvisioningMessage = pvResult.ResultMessage

	common.GenerateOutput(finalReport, inCluster)
}
