package pvcheck

import (
	"context"
	"fmt"
	"log"
	"time"

	"github.com/armosec/armo-platform-tools/poc-prerequisite/pkg/common"
	corev1 "k8s.io/api/core/v1"
	storagev1 "k8s.io/api/storage/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/wait"
	"k8s.io/client-go/kubernetes"
)

const (
	annDefaultStorageClass     = "storageclass.kubernetes.io/is-default-class"
	annBetaDefaultStorageClass = "storageclass.beta.kubernetes.io/is-default-class"
	noProvisioner              = "kubernetes.io/no-provisioner"
)

// PVCheckResult is a minimal struct containing pass/fail info.
type PVCheckResult struct {
	PassedCount   int
	FailedCount   int
	TotalNodes    int
	ResultMessage string // Only "Passed", "Failed", or "Skipped"
}

// RunPVProvisioningCheck first verifies that dynamic provisioning is likely available
// and that there's a default StorageClass. Then it actually creates a 5Gi PVC + Pod
// in a temporary namespace, waits for them to become ready, and verifies the PVC is bound.
func RunPVProvisioningCheck(
	ctx context.Context,
	clientset *kubernetes.Clientset,
	clusterData *common.ClusterData,
) *PVCheckResult {

	// 1) Pre-checks for dynamic provisioning
	passed, failReason := basicPreCheck(ctx, clientset, clusterData)
	if !passed {
		return failResult(len(clusterData.Nodes), failReason)
	}

	// 2) If all pre-checks pass, try a real creation of PVC + Pod
	//    in an ephemeral namespace.
	namespace := "armo-pv-check-ns"
	if err := createNamespace(ctx, clientset, namespace); err != nil {
		return failResult(len(clusterData.Nodes),
			fmt.Sprintf("Failed to create temporary namespace %q: %v", namespace, err))
	}

	// Defer ensures cleanup even if we return early or panic
	defer func() {
		if delErr := deleteNamespace(context.Background(), clientset, namespace); delErr != nil {
			log.Printf("Warning: could not delete namespace %q: %v", namespace, delErr)
		}
	}()

	pvcName := "armo-pv-check-pvc"
	podName := "armo-pv-check-pod"

	// 2a) Create a 5Gi PVC, letting the cluster pick the default StorageClass.
	if err := createTestPVC(ctx, clientset, namespace, pvcName, "5Gi"); err != nil {
		return failResult(len(clusterData.Nodes),
			fmt.Sprintf("Failed to create PVC: %v", err))
	}

	// 2b) Create a Pod that references the PVC (no NodeName => let scheduler place it)
	if err := createTestPod(ctx, clientset, namespace, podName, pvcName); err != nil {
		return failResult(len(clusterData.Nodes),
			fmt.Sprintf("Failed to create Pod: %v", err))
	}

	// 2c) Wait for the PVC to be Bound (important if StorageClass uses WaitForFirstConsumer)
	if err := waitForPVCBound(ctx, clientset, namespace, pvcName, 60*time.Second); err != nil {
		return failResult(len(clusterData.Nodes),
			fmt.Sprintf("PVC did not become Bound: %v", err))
	}

	// 2d) Wait for the Pod to become Running or Succeeded
	if err := waitForPodRunningOrSucceeded(ctx, clientset, namespace, podName, 60*time.Second); err != nil {
		return failResult(len(clusterData.Nodes),
			fmt.Sprintf("Pod did not become Running/Succeeded: %v", err))
	}

	// 3) If everything was successful => "Passed"
	return &PVCheckResult{
		PassedCount:   len(clusterData.Nodes),
		FailedCount:   0,
		TotalNodes:    len(clusterData.Nodes),
		ResultMessage: "Passed",
	}
}

// ---------------------------------------------------------------------
// Basic Pre-Check to ensure dynamic provisioning likely works
// ---------------------------------------------------------------------
func basicPreCheck(
	ctx context.Context,
	clientset *kubernetes.Clientset,
	clusterData *common.ClusterData,
) (bool, string) {

	totalNodes := len(clusterData.Nodes)
	if totalNodes == 0 {
		return false, "No nodes found in cluster."
	}

	// Ensure at least one node is schedulable
	var schedulableFound bool
	for _, node := range clusterData.Nodes {
		if !node.Spec.Unschedulable {
			schedulableFound = true
			break
		}
	}
	if !schedulableFound {
		return false, "No schedulable node found (all unschedulable)."
	}

	// Check if at least one StorageClass is present
	scList, err := clientset.StorageV1().StorageClasses().List(ctx, metav1.ListOptions{})
	if err != nil {
		return false, fmt.Sprintf("Failed to list StorageClasses: %v", err)
	}
	if len(scList.Items) == 0 {
		return false, "No StorageClasses found; dynamic provisioning not available."
	}

	// Identify dynamic StorageClasses
	dynamicSCs := make([]storagev1.StorageClass, 0, len(scList.Items))
	for _, sc := range scList.Items {
		if sc.Provisioner != noProvisioner && sc.Provisioner != "" {
			dynamicSCs = append(dynamicSCs, sc)
		}
	}
	if len(dynamicSCs) == 0 {
		return false, "All StorageClasses use 'no-provisioner'; no dynamic provisioning."
	}

	// Require at least one default dynamic SC
	hasDefault := false
	for _, sc := range dynamicSCs {
		if isStorageClassDefault(&sc) {
			hasDefault = true
			break
		}
	}
	if !hasDefault {
		return false, "No default dynamic StorageClass found."
	}

	// If we got here, all “theoretical” checks pass
	return true, ""
}

func isStorageClassDefault(sc *storagev1.StorageClass) bool {
	if sc.Annotations == nil {
		return false
	}
	if sc.Annotations[annDefaultStorageClass] == "true" {
		return true
	}
	if sc.Annotations[annBetaDefaultStorageClass] == "true" {
		return true
	}
	return false
}

// ---------------------------------------------------------------------
// Creating resources
// ---------------------------------------------------------------------
func createNamespace(ctx context.Context, clientset *kubernetes.Clientset, name string) error {
	nsObj := &corev1.Namespace{
		ObjectMeta: metav1.ObjectMeta{
			Name: name,
		},
	}
	_, err := clientset.CoreV1().Namespaces().Create(ctx, nsObj, metav1.CreateOptions{})
	return err
}

func createTestPVC(ctx context.Context, clientset *kubernetes.Clientset, namespace, pvcName, size string) error {
	// Using no 'storageClassName' => let the cluster pick the default SC
	qty, err := resource.ParseQuantity(size)
	if err != nil {
		return fmt.Errorf("invalid size quantity %q: %w", size, err)
	}

	pvc := &corev1.PersistentVolumeClaim{
		ObjectMeta: metav1.ObjectMeta{
			Name: pvcName,
		},
		Spec: corev1.PersistentVolumeClaimSpec{
			AccessModes: []corev1.PersistentVolumeAccessMode{
				corev1.ReadWriteOnce,
			},
			Resources: corev1.VolumeResourceRequirements{ // use VolumeResourceRequirements here
				Requests: corev1.ResourceList{
					corev1.ResourceStorage: qty,
				},
			},
		},
	}
	_, createErr := clientset.CoreV1().PersistentVolumeClaims(namespace).Create(ctx, pvc, metav1.CreateOptions{})
	return createErr
}

func createTestPod(ctx context.Context, clientset *kubernetes.Clientset, namespace, podName, pvcName string) error {
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name: podName,
		},
		Spec: corev1.PodSpec{
			RestartPolicy: corev1.RestartPolicyNever,
			Containers: []corev1.Container{
				{
					Name:  "pv-check-container",
					Image: "registry.k8s.io/pause:3.9",
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
	_, err := clientset.CoreV1().Pods(namespace).Create(ctx, pod, metav1.CreateOptions{})
	return err
}

// ---------------------------------------------------------------------
// Waiting for resources to be ready
// ---------------------------------------------------------------------
func waitForPVCBound(ctx context.Context, clientset *kubernetes.Clientset, ns, pvcName string, timeout time.Duration) error {
	return wait.PollImmediate(3*time.Second, timeout, func() (bool, error) {
		pvc, err := clientset.CoreV1().PersistentVolumeClaims(ns).Get(ctx, pvcName, metav1.GetOptions{})
		if err != nil {
			return false, err
		}
		if pvc.Status.Phase == corev1.ClaimBound {
			return true, nil
		}
		return false, nil
	})
}

// Wait for Pod to be Running or Succeeded
func waitForPodRunningOrSucceeded(ctx context.Context, clientset *kubernetes.Clientset, ns, podName string, timeout time.Duration) error {
	return wait.PollImmediate(3*time.Second, timeout, func() (bool, error) {
		pod, err := clientset.CoreV1().Pods(ns).Get(ctx, podName, metav1.GetOptions{})
		if err != nil {
			return false, err
		}
		switch pod.Status.Phase {
		case corev1.PodRunning, corev1.PodSucceeded:
			return true, nil
		case corev1.PodFailed:
			return false, fmt.Errorf("pod failed")
		default:
			return false, nil
		}
	})
}

// ---------------------------------------------------------------------
// Cleanup / Final
// ---------------------------------------------------------------------
func deleteNamespace(ctx context.Context, clientset *kubernetes.Clientset, ns string) error {
	return clientset.CoreV1().Namespaces().Delete(ctx, ns, metav1.DeleteOptions{})
}

func failResult(totalNodes int, reason string) *PVCheckResult {
	// We only return "Passed" or "Failed", but let's log the reason.
	log.Printf("Dynamic PV check failed: %s", reason)
	return &PVCheckResult{
		PassedCount:   0,
		FailedCount:   totalNodes,
		TotalNodes:    totalNodes,
		ResultMessage: "Failed",
	}
}
