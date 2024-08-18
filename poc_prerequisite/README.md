# ARMO POC Prerequisite Validation Script

This script is designed to validate the prerequisites for the ARMO Security Proof of Concept (POC). It performs the following checks:

1. Network accessibility
2. Helm chart installation permissions
3. eBPF support on all nodes
4. Persistent Volume (PV) support

## Prerequisites

- A Kubernetes cluster
- kubectl configured to access the cluster
- Helm installed and configured
- A file named `ip_list.txt` containing a list of IP addresses to check for network accessibility

## Usage

1. Clone this repository and navigate to the directory:
   ```bash
   git clone <repository_url>
   cd <repository_directory>
   ```

2. Ensure the `ip_list.txt` file is present in the directory. This file should contain the IP addresses to be checked, one per line.

3. Make the script executable:
   ```bash
   chmod +x armo_poc_prerequisite.sh
   ```

4. Run the script:
   ```bash
   ./armo_poc_prerequisite.sh
   ```

## Script Details

### check_network_accessibility

This function checks if the network is accessible by trying to connect to each IP address listed in `ip_list.txt` on port 443 using `nc` (netcat).

### verify_helm_permissions

This function verifies that you have the necessary permissions to install Helm charts by performing a dry-run installation of the `kubescape` chart.

### check_ebpf_support

This function checks if eBPF is supported on all nodes in the cluster by creating a DaemonSet that attempts to access `/sys/fs/bpf`.

### check_pv_support

This function checks if Persistent Volume Claims (PVCs) can be successfully bound by creating a test PVC.

## Output

The script will output the status of each check:

- ✅ for a successful check
- ❌ for a failed check

If any checks fail, detailed failure messages will be printed.

## Example `ip_list.txt`

```
192.168.1.1
10.0.0.1
172.16.0.1
```

## Example Output

```plaintext
✅ Network accessibility check passed.
✅ Helm chart installation permissions check passed.
✅ eBPF support check passed.
✅ PV support check passed.

🎉🐼 Your cluster is ready for the ARMO Security POC.
```

If any checks fail, the output will look like this:

```plaintext
❌ Network accessibility check failed.
###    Details    ###
failed to access: 192.168.1.1 10.0.0.1

✅ Helm chart installation permissions check passed.
❌ eBPF support check failed.
###    Details    ###
failed on nodes: node1 node2

✅ PV support check passed.

🚨 Your cluster is not ready for the ARMO Security POC. Failures: 2
```

## Troubleshooting

- Ensure `kubectl` is configured to access your cluster.
- Verify Helm is installed and configured correctly.
- Check the `ip_list.txt` file for correct IP addresses.

For further assistance, please contact support.