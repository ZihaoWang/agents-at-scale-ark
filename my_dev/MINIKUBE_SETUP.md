# Running Ark on macOS (Minikube + Colima)

This guide helps you run the Ark platform locally on a MacBook (Air/Pro) using Minikube and Colima, optimized to save system resources.

## 1. Prerequisites (Resource Optimization)

By default, Docker and Minikube can consume too many resources (or too few to run Ark). We explicitly size them to **4 CPUs** and **8GB RAM**, which is enough for Ark but leaves room for your OS.

### Step 1: Configure Colima
Colima provides the virtual machine (VM) that Docker runs in. We use `--vm-type=vz` (Apple's native Virtualization framework) instead of QEMU because QEMU can consume significantly more memory than allocated (overhead/bloat) on Apple Silicon. VZ respects the memory limit strictly and is more performant.

```bash
# Stop any existing instance
colima stop

# Start with optimized limits (4 CPUs, 8GB RAM) and VZ (fixes QEMU memory bloat)
colima start --cpu 4 --memory 8 --vm-type=vz --vz-rosetta
```

### Step 2: Start Minikube
We start Minikube using the Docker driver. It will run inside the Colima VM.

```bash
# Clean up any old cluster state
minikube delete

# Start Minikube (using slightly less memory than the VM total to be safe)
minikube start --driver=docker --cpus 4 --memory 7500m
```

# Automated Script

We have created a script that handles all of this for you (starting, stopping, cleaning up):

```bash
./my_dev/scripts/ark-control.sh start-minikube
./my_dev/scripts/ark-control.sh start-ark
./my_dev/scripts/ark-control.sh delete-ark
```

---

## 2. Configuration Changes

I have modified the `devspace.yaml` file in this repository to support a "Low Resource" mode (`minikube` profile).

### What changed?
1. **Added `minikube` Profile**:
   This profile overrides the default CPU/Memory requests for Ark services.
   - Default request: **200m** (0.2 CPU) per service.
   - Minikube request: **50m** (0.05 CPU) per service.
   *This allows all pods to fit on a smaller cluster.*

2. **Propagated Settings to Dependencies**:
   I configured the pipeline to pass these low-resource settings down to sub-services (`ark-api`, `ark-dashboard`, etc.) using environment variables.

   ```yaml
   # In devspace.yaml (simplified)
   pipelines:
     dev: |-
       export DEVSPACE_PROFILES=minikube  # passes profile to children
       run_dependency_pipelines ...
   ```

---

## 3. Running Ark

To start Ark in development mode with these optimizations, run:

```bash
# The '-p minikube' flag activates the low-resource profile
devspace dev -p minikube
```

### If deployments fail:
If you see errors like `UPGRADE FAILED` or `release not found` (often caused by previous crashed attempts), clean up the stuck releases and try again:

```bash
helm uninstall argo-workflows -n default
helm uninstall localhost-gateway -n ark-system
devspace dev -p minikube
```
