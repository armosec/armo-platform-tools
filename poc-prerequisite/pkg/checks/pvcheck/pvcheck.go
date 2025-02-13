package pvcheck

import (
	"context"
	"fmt"
	"log"
	"time"

	"github.com/armosec/armo-platform-tools/poc-prerequisite/pkg/common"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/wait"
	"k8s.io/client-go/kubernetes"
)

// PVCheckResult stores how many nodes passed/failed and a final display string.
type PVCheckResult struct {
	PassedCount   int
	FailedCount   int
	TotalNodes    int
	ResultMessage string // e.g. "Passed", or "Passed(7)/Failed(3)"
}

// RunPVProvisioningCheck tries to provision a 1Mi PVC + Pod on each node to confirm dynamic PV provisioning.
func RunPVProvisioningCheck(ctx context.Context, clientset *kubernetes.Clientset, clusterData *common.ClusterData) *PVCheckResult {
	totalNodes := len(clusterData.Nodes)
	if totalNodes == 0 {
		return &PVCheckResult{
			TotalNodes:    0,
			PassedCount:   0,
			FailedCount:   0,
			ResultMessage: "No nodes found; skipping PV provisioning check.",
		}
	}

	// 1) Create ephemeral namespace for the test
	nsName := "armo-pv-check-ns"
	if err := ensureNamespace(ctx, clientset, nsName); err != nil {
		return &PVCheckResult{
			ResultMessage: fmt.Sprintf("Failed to create namespace %q: %v", nsName, err),
		}
	}

	// Always remove the ephemeral namespace at the end, ensuring no leftovers
	cleanupDone := false
	defer func() {
		if !cleanupDone {
			if err := deleteNamespace(ctx, clientset, nsName); err != nil {
				log.Printf("Warning: failed to delete namespace %q: %v", nsName, err)
			}
		}
	}()

	// 2) Check for at least one StorageClass.
	//    If none exist, dynamic provisioning won't work.
	scList, err := clientset.StorageV1().StorageClasses().List(ctx, metav1.ListOptions{})
	if err != nil {
		return &PVCheckResult{
			ResultMessage: fmt.Sprintf("Failed to list StorageClasses: %v", err),
		}
	}
	if len(scList.Items) == 0 {
		return &PVCheckResult{
			ResultMessage: "No StorageClasses found; dynamic provisioning likely not available.",
		}
	}

	passedCount := 0
	failedCount := 0

	// We'll create a Pod + PVC per node
	for _, node := range clusterData.Nodes {
		nodeName := node.Name

		// Create PVC
		pvcName := fmt.Sprintf("armo-pv-check-pvc-%s", nodeName)
		if err := createTestPVC(ctx, clientset, nsName, pvcName, 1); err != nil {
			log.Printf("Failed to create PVC on node %s: %v", nodeName, err)
			failedCount++
			continue
		}

		// Create Pod that references the PVC, pinned to the nodeName
		podName := fmt.Sprintf("armo-pv-check-pod-%s", nodeName)
		if err := createTestPod(ctx, clientset, nsName, podName, pvcName, nodeName); err != nil {
			log.Printf("Failed to create Pod on node %s: %v", nodeName, err)
			failedCount++
			continue
		}

		// Wait for the Pod to become Running or Succeeded
		ok, werr := waitForPodRunningOrSucceeded(ctx, clientset, nsName, podName, 45*time.Second)
		if werr != nil {
			log.Printf("Pod %s in node %s didn't reach Running/Succeeded: %v", podName, nodeName, werr)
			failedCount++
		} else if !ok {
			log.Printf("Pod %s in node %s timed out", podName, nodeName)
			failedCount++
		} else {
			passedCount++
		}

		// Clean up Pod & PVC individually to keep the loop ephemeral
		cleanupResource(ctx, clientset, "pod", podName, nsName)
		cleanupResource(ctx, clientset, "pvc", pvcName, nsName)
	}

	// Final result
	cleanupDone = true                      // We'll do one final namespace delete below
	deleteNamespace(ctx, clientset, nsName) // ensure no leftovers

	var resultMsg string
	if failedCount == 0 && passedCount > 0 {
		resultMsg = "Passed"
	} else if passedCount == 0 && failedCount > 0 {
		resultMsg = "Failed"
	} else {
		resultMsg = fmt.Sprintf("Passed(%d)/Failed(%d)", passedCount, failedCount)
	}

	return &PVCheckResult{
		PassedCount:   passedCount,
		FailedCount:   failedCount,
		TotalNodes:    totalNodes,
		ResultMessage: resultMsg,
	}
}

// createTestPVC creates a 1Mi PVC in the given namespace
func createTestPVC(ctx context.Context, clientset *kubernetes.Clientset, namespace, pvcName string, sizeMi int64) error {
	pvc := &corev1.PersistentVolumeClaim{
		ObjectMeta: metav1.ObjectMeta{
			Name: pvcName,
		},
		Spec: corev1.PersistentVolumeClaimSpec{
			AccessModes: []corev1.PersistentVolumeAccessMode{
				corev1.ReadWriteOnce,
			},
			Resources: corev1.VolumeResourceRequirements{
				Requests: corev1.ResourceList{
					corev1.ResourceStorage: *resource.NewQuantity(sizeMi*1024*1024, resource.BinarySI),
				},
			},
		},
	}
	_, err := clientset.CoreV1().PersistentVolumeClaims(namespace).Create(ctx, pvc, metav1.CreateOptions{})
	return err
}

// createTestPod pins a Pod to the given nodeName, referencing the named PVC.
func createTestPod(ctx context.Context, clientset *kubernetes.Clientset, ns, podName, pvcName, nodeName string) error {
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name: podName,
		},
		Spec: corev1.PodSpec{
			NodeName:      nodeName, // ensures scheduling exactly on that node
			RestartPolicy: corev1.RestartPolicyNever,
			Containers: []corev1.Container{
				{
					Name:    "pv-check-container",
					Image:   "busybox:1.36.1", // minimal image
					Command: []string{"sh", "-c"},
					Args: []string{
						"echo 'Hello from PV provisioning check' > /test/datafile && sleep 5 && exit 0",
					},
					VolumeMounts: []corev1.VolumeMount{
						{
							Name:      "pvc-volume",
							MountPath: "/test",
						},
					},
				},
			},
			Volumes: []corev1.Volume{
				{
					Name: "pvc-volume",
					VolumeSource: corev1.VolumeSource{
						PersistentVolumeClaim: &corev1.PersistentVolumeClaimVolumeSource{
							ClaimName: pvcName,
						},
					},
				},
			},
		},
	}
	_, err := clientset.CoreV1().Pods(ns).Create(ctx, pod, metav1.CreateOptions{})
	return err
}

// waitForPodRunningOrSucceeded waits for the Pod to be Running or Succeeded within the timeout.
func waitForPodRunningOrSucceeded(ctx context.Context, clientset *kubernetes.Clientset, ns, podName string, timeout time.Duration) (bool, error) {
	// Poll every 3 seconds
	interval := 3 * time.Second

	var success bool
	err := wait.PollImmediate(interval, timeout, func() (bool, error) {
		pod, getErr := clientset.CoreV1().Pods(ns).Get(ctx, podName, metav1.GetOptions{})
		if getErr != nil {
			return false, getErr
		}
		switch pod.Status.Phase {
		case corev1.PodRunning, corev1.PodSucceeded:
			success = true
			return true, nil
		case corev1.PodFailed:
			// If Pod fails quickly, we consider that a no
			return false, fmt.Errorf("pod failed")
		}
		// Not ready yet, keep polling
		return false, nil
	})
	return success, err
}

// cleanupResource attempts to delete the specified resource type ("pvc" or "pod").
func cleanupResource(ctx context.Context, clientset *kubernetes.Clientset, resourceType, name, namespace string) {
	var delErr error
	switch resourceType {
	case "pod":
		delErr = clientset.CoreV1().Pods(namespace).Delete(ctx, name, metav1.DeleteOptions{})
	case "pvc":
		delErr = clientset.CoreV1().PersistentVolumeClaims(namespace).Delete(ctx, name, metav1.DeleteOptions{})
	default:
		log.Printf("Unknown resourceType %s for cleanup", resourceType)
		return
	}
	if delErr != nil {
		log.Printf("Warning: failed to clean up %s %s: %v", resourceType, name, delErr)
	}
}

// ensureNamespace creates the ephemeral namespace if it doesn't exist
func ensureNamespace(ctx context.Context, clientset *kubernetes.Clientset, ns string) error {
	_, err := clientset.CoreV1().Namespaces().Get(ctx, ns, metav1.GetOptions{})
	if err == nil {
		return nil // already exists
	}
	nsObj := &corev1.Namespace{
		ObjectMeta: metav1.ObjectMeta{
			Name: ns,
		},
	}
	_, createErr := clientset.CoreV1().Namespaces().Create(ctx, nsObj, metav1.CreateOptions{})
	return createErr
}

// deleteNamespace forcibly removes the ephemeral namespace, cleaning all resources inside.
func deleteNamespace(ctx context.Context, clientset *kubernetes.Clientset, ns string) error {
	return clientset.CoreV1().Namespaces().Delete(ctx, ns, metav1.DeleteOptions{})
}
