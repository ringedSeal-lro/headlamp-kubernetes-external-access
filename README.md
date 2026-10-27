# Kubernetes External Access

Automation for exposing services in Kubernetes clusters using MetalLB, NGINX Ingress Controller, and Headlamp. This project makes a web-based cluster management interface available through an external IP address and HTTP routing rules.

The configuration was developed for a Kubernetes environment running on Linux, using `kube-proxy` in IPVS mode and MetalLB in Layer 2 mode to advertise IP addresses on the local network.

## Architecture

The access flow consists of the following components:

1. **MetalLB:** manages external IP address allocation for `LoadBalancer` services and advertises these addresses on the local network.
    
2. **NGINX Ingress Controller:** receives HTTP requests and forwards traffic according to the configured Ingress rules.
    
3. **Headlamp:** provides a web interface for viewing and managing Kubernetes resources.
    
4. **kube-proxy with IPVS:** handles Kubernetes service traffic forwarding, with `strictARP` enabled for the Layer 2 advertisement scenario.
    

## Repository Files

|File|Description|
|---|---|
|`install.sh`|Automates component installation and configuration.|
|`uninstall.sh`|Automates the removal of components installed by the project.|
|`IPPool.yaml`|Defines the `IPAddressPool` and `L2Advertisement` resources used by MetalLB.|
|`headlamp-ingress.yaml`|Defines the HTTP routing rule for the Headlamp service.|

## 1. Prerequisites

Before getting started, ensure that the environment has:

- An operational Kubernetes cluster.
- `kubectl` configured with sufficient permissions to modify cluster resources.
- Helm installed.
- Linux on the nodes where IPVS kernel modules will be enabled.
- Python 3 and PyYAML available in the script execution environment if automated `kube-proxy` configuration is enabled.
- IP addresses reserved for MetalLB and available on the local network.
- Network connectivity between the client network, Kubernetes nodes, and the external IP address.
- All four repository files available in the same directory.
    

The reference environment uses Kubernetes `v1.34.x`, MetalLB `v0.15.3`, and NGINX Ingress Controller `2.5.1`. Check version compatibility with your Kubernetes distribution.

Verify the active context before making changes:

```
kubectl config current-context
kubectl get nodes
helm version
```

## 2. Environment Configuration

The installation script automates `kube-proxy` configuration, component installation, manifest application, and final validation.

By default, the script does not configure kernel modules because it does not assume administrative access to every cluster node. The IPVS modules must be loaded on each relevant node.

Run the following commands on each Linux node:

```
sudo modprobe ip_vs
sudo modprobe ip_vs_rr
sudo modprobe ip_vs_wrr
sudo modprobe ip_vs_sh
sudo modprobe nf_conntrack
```

To persist module loading across reboots:

```
printf "ip_vs\nip_vs_rr\nip_vs_wrr\nip_vs_sh\nnf_conntrack\n" \
  | sudo tee /etc/modules-load.d/ipvs.conf
```

Verify that the modules are loaded:

```
lsmod | grep -E 'ip_vs|nf_conntrack'
```

To configure the machine running the script as well, set `CONFIGURE_LOCAL_NODE=true`. This option does not automatically configure the other Kubernetes nodes.

## 3. kube-proxy Configuration

By default, the installation script updates the `kube-proxy` ConfigMap to use IPVS and enable `strictARP`.

The configured properties are:

```
mode: "ipvs"
ipvs:
  strictARP: true
```

The modification preserves the other configuration properties processed by the script. The `kube-proxy` pods are then recreated to load the new configuration.

The script uses Python and PyYAML to modify the YAML stored in the ConfigMap. Install this dependency before running the script if it is not already available.

To skip automated `kube-proxy` configuration:

```
KUBEPROXY_CONFIGURE=false ./install.sh
```

This option assumes that `kube-proxy` is already configured as required by the environment. If necessary, configure it manually before proceeding.

**Important:** before modifying `kube-proxy`, save the original configuration so that it can be restored manually if needed.

```
kubectl get configmap kube-proxy -n kube-system -o yaml \
  > kube-proxy-backup.yaml
```

## 4. Installation

Make both scripts executable:

```
chmod +x install.sh uninstall.sh
```

Run the installation script:

```
./install.sh
```

The script performs the following operations:

1. Checks dependencies, manifests, and cluster access.
2. Configures IPVS modules on the local machine if this option is enabled.
3. Configures `kube-proxy` to use IPVS and `strictARP` when enabled.
4. Installs MetalLB and waits for its components to become ready.
5. Applies `IPPool.yaml`.
6. Installs or upgrades the NGINX Ingress Controller with a `LoadBalancer` service.
7. Installs or upgrades Headlamp using Helm.
8. Applies `headlamp-ingress.yaml`.
9. Checks the deployed resources and performs an HTTP routing test.
    

The script uses environment variables to allow adjustments to component versions, the external IP address, and the hostname used for Headlamp.

## 5. External IP Address Configuration

The `IPPool.yaml` file defines the IP address range available to MetalLB:

```
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: metallb-single-ip
  namespace: metallb-system
spec:
  addresses:
    - 192.168.1.240-192.168.1.250
  autoAssign: false
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: metallb-single-ip-adv
  namespace: metallb-system
spec:
  ipAddressPools:
    - metallb-single-ip
```

The example uses `192.168.1.240` as the external IP address. This address must be available within the configured range.

To specify the address during installation:

```
EXTERNAL_IP=192.168.1.240 ./install.sh
```

The specified address must belong to the range defined in `IPPool.yaml`, be compatible with the local network, and not conflict with addresses used by other devices or assigned through DHCP.

The manifest also defines the `L2Advertisement` resource, which configures address advertisement on the local network.

## 6. Accessing Headlamp

The `headlamp-ingress.yaml` file defines an Ingress rule for the `headlamp.local` hostname. It forwards requests to the `my-headlamp` service on port 80 in the `kube-system` namespace.

To access the interface through a browser, configure `headlamp.local` to resolve to the external IP address. On a Linux client, add the following entry to `/etc/hosts`:

```
192.168.1.240 headlamp.local
```

Then open:

```
http://headlamp.local
```

You can also test HTTP routing directly by sending the `Host` header:

```
curl -H "Host: headlamp.local" http://192.168.1.240/
```

An HTTP response indicates that communication with the entry point was established. To confirm that the setup is fully operational, verify that the response corresponds to the Headlamp application and that the required Kubernetes resources are running correctly.

**HTTPS note:** the example manifest includes an annotation referencing cert-manager, but it does not define a `tls` section in the Ingress resource. Therefore, this tutorial demonstrates HTTP access. HTTPS requires additional TLS configuration, including a certificate and the necessary resources in the environment.

## 7. Installation Validation

After installation, check the MetalLB components:

```
kubectl get pods -n metallb-system
kubectl get ipaddresspools,l2advertisements -n metallb-system
```

Check the NGINX Ingress Controller:

```
kubectl get pods -n nginx-ingress
kubectl get svc -n nginx-ingress
```

Check Headlamp and the Ingress rule:

```
kubectl get pods,svc -n kube-system
kubectl get ingress -n kube-system
```

The NGINX service should display the configured address in the `EXTERNAL-IP` column.

## 8. Troubleshooting

If the installation does not work as expected, inspect the cluster resources and events.

### External IP Address Stuck in `Pending`

```
kubectl get svc -n nginx-ingress
kubectl get ipaddresspools,l2advertisements -n metallb-system
kubectl get pods -n metallb-system
```

Check whether the requested address belongs to the MetalLB pool and whether the advertisement components are operational.

### HTTP Routing Issues

```
kubectl get ingress -n kube-system
kubectl describe ingress headlamp -n kube-system
kubectl get svc -n kube-system
```

Check that the Ingress class, backend service name, and port configured in `headlamp-ingress.yaml` match the installed resources.

### IPVS Configuration Issues

```
kubectl get configmap kube-proxy -n kube-system -o yaml
kubectl get pods -n kube-system -l k8s-app=kube-proxy
```

Verify that `mode` is set to `ipvs`, `strictARP` is enabled, and the `kube-proxy` pods are operational.

### NGINX Component Issues

```
kubectl get pods -n nginx-ingress
kubectl get svc -n nginx-ingress
helm list -n nginx-ingress
```

To inspect the logs, first identify the controller pod name:

```
kubectl get pods -n nginx-ingress
kubectl logs -n nginx-ingress <pod-name>
```

Service names and selectors used in troubleshooting commands may vary depending on the installed chart version and values.

## 9. Uninstallation

The repository includes `uninstall.sh` to automate the removal of components installed by the project.

Run:

```
./uninstall.sh
```

The script asks for confirmation before proceeding. To run it without interactive confirmation:

```
./uninstall.sh --yes
```

The uninstallation process includes:

1. Removing the Headlamp Ingress resource.
2. Uninstalling the Headlamp Helm release.
3. Uninstalling the NGINX Ingress Controller Helm release.
4. Removing the `IPAddressPool` and `L2Advertisement` resources defined by the project.
5. Removing the MetalLB installation.
    

The script checks whether the expected Helm releases and resources exist before attempting to remove them.

### Uninstallation Considerations

- **Shared MetalLB installation:** removing MetalLB may affect other `LoadBalancer` services in the cluster. Confirm that no other services depend on it before running the script.
- **kube-proxy configuration:** the uninstallation script does not automatically restore the original `kube-proxy` configuration. If the IPVS configuration must be reverted, use the backup and plan the restoration according to your Kubernetes distribution.
- **IPVS modules:** modules loaded in Linux and the `/etc/modules-load.d/ipvs.conf` file are not automatically removed.
- **Shared resources:** check whether the namespace and cluster resources are used by other applications before performing additional cleanup.
    

Uninstalling the components does not mean that all environment changes have been reverted. Review the cluster state after execution.

## 10. Security and Operational Considerations

- The IP address range must be available and compatible with the local network.
- Kernel module configuration must persist across reboots on all relevant nodes.
- The scripts require administrative cluster permissions and may modify networking components.
- A single NGINX Ingress Controller replica does not provide high availability.
- Headlamp provides access according to the permissions associated with the configured identity. Protect access and avoid exposing the interface to untrusted networks.
- The HTTP test does not replace HTTPS, authentication, or authorization configuration.
- Re-running the installation script uses Helm installation or upgrade operations, but does not guarantee automatic rollback of partially applied changes.
- Before using the scripts in a shared or production environment, review the manifests and the changes made to the cluster.
    

## Purpose

This project serves as a practical reference for automating web service exposure in Kubernetes clusters by combining IP address allocation, Layer 2 advertisement, and HTTP routing.

Although the example uses Headlamp, the infrastructure can be adapted to expose other applications and APIs compatible with Ingress.