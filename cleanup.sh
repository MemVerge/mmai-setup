#!/usr/bin/env bash

# Save STDOUT and STDERR to a log file
# arg1 = path to log file. If empty, save to current directory
TEE=("$(command -v tee)")               # Path to tee
TAIL=("$(command -v tail)")             # Path to tail
DATE=$(date +"%d_%b_%Y_%T")
SCRIPT_NAME=${0##*/}                    # Name of this script
SCRIPT_NAME=${SCRIPT_NAME%.*}           # Name of this without extension
STDOUT_LOG_FILE="${SCRIPT_NAME}_${DATE}.log"    # Filename to save STDOUT and STDERR
log_stdout_stderr() {
    local LOG_PATH
    if [[ $1 != "" ]]; then
        # Use the specified path
        LOG_PATH=${1}
    else
        # Use current working directory
        LOG_PATH=$(pwd)
    fi

    LOG_FILE="${LOG_PATH}/${STDOUT_LOG_FILE}"

    # Capture STDOUT and STDERR to a log file, and display to the terminal
    if [[ ${TEE} != "" ]]; then
        # Use the tee approach
        exec &> >(${TEE} -a "${LOG_FILE}")
    else
        # Use the tail approach
        exec &> "${LOG_FILE}" && ${TAIL} "${LOG_FILE}"
    fi
}

initialize_log() {
    read -p "Enter the path to which logs should be saved (default '$STDOUT_LOG_FILE' in the current working directory): " logpath
    log_stdout_stderr $logpath
}

force_initialize_log() {
    local new_log_file=""
    if [[ -f "$STDOUT_LOG_FILE" ]]; then
        # Find all files with the pattern $STDOUT_LOG_FILE.[NUMBER]
        max_number=$(ls "$STDOUT_LOG_FILE".* 2>/dev/null | grep -Eo "${STDOUT_LOG_FILE}\.[0-9]+$" | sort -n | tail -1)

        if [[ -z "$max_number" ]]; then
            # If no numbered files exist, start with 2
            new_log_file="${STDOUT_LOG_FILE}.2"
        else
            # Increment the highest number by 1
            new_log_file="${STDOUT_LOG_FILE}.$((max_number + 1))"
        fi
    else
        # If the default log file doesn't exist, use it
        new_log_file="$STDOUT_LOG_FILE"
    fi

    log_stdout_stderr "$new_log_file"
}

# Warning
echo "==================== WARNING ===================="
echo "THIS WILL DELETE ALL RESOURCES CREATED BY MMAI"
echo "MAKE SURE YOU HAVE CREATED AND TESTED YOUR BACKUPS"
echo "THIS IS A NON REVERSIBLE ACTION"
echo "==================== WARNING ===================="

case $1 in
  "force" )
    echo "'force' flag provided. Continuing..."
    force_initialize_log
    ;;

  * )
    echo "Do you want to continue (y/n)?"
    read -r answer
    if [ "$answer" != "y" ]; then
      echo "Exiting..."
      exit 1
    else
      initialize_log
    fi
    ;;
esac

# Linux only for now
if [ "$(uname -s)" != "Linux" ]; then
  echo "Must be run on Linux"
  exit 1
fi

# Check kubectl existence
if ! type kubectl >/dev/null 2>&1; then
  echo "kubectl not found in PATH, make sure kubectl is available"
  exit 1
fi

# Check timeout existence
if ! type timeout >/dev/null 2>&1; then
  echo "timeout not found in PATH, make sure timeout is available"
  exit 1
fi


# Test connectivity
if ! kubectl get nodes >/dev/null 2>&1; then
  echo "'kubectl get nodes' exited non-zero, make sure environment variable KUBECONFIG is set to a working kubeconfig file"
  exit 1
fi

echo "=> Printing cluster info for confirmation"
kubectl cluster-info
kubectl get nodes -o wide

kcd()
{
    i="0"
    while [ $i -lt 4 ]; do
        if timeout 21 sh -c 'kubectl delete --ignore-not-found=true --grace-period=15 --timeout=20s '"$*"''; then
            break
        fi
        i=$((i+1))
    done
}

kcpf()
{
  FINALIZERS=$(kubectl get -o jsonpath="{.metadata.finalizers}" "$@")
  if [ "x${FINALIZERS}" != "x" ]; then
      echo "Finalizers before for ${*}: ${FINALIZERS}"
      kubectl patch -p '{"metadata":{"finalizers":null}}' --type=merge "$@"
      echo "Finalizers after for ${*}: $(kubectl get -o jsonpath="{.metadata.finalizers}" "${@}")"
  fi
}

kcdns()
{
  if kubectl get namespace "$1"; then
    kcpf namespace "$1"
    FINALIZERS=$(kubectl get -o jsonpath="{.spec.finalizers}" namespace "$1")
    if [ "x${FINALIZERS}" != "x" ]; then
        echo "Finalizers before for namespace ${1}: ${FINALIZERS}"
        kubectl get -o json namespace "$1" | tr -d "\n" | sed "s/\"finalizers\": \[[^]]\+\]/\"finalizers\": []/"   | kubectl replace --raw /api/v1/namespaces/$1/finalize -f -
        echo "Finalizers after for namespace ${1}: $(kubectl get -o jsonpath="{.spec.finalizers}" namespace ${1})"
    fi
    i="0"
    while [ $i -lt 4 ]; do
        if timeout 21 sh -c 'kubectl delete --ignore-not-found=true --grace-period=15 --timeout=20s namespace '"$1"''; then
            break
        fi
        i=$((i+1))
    done
  fi
}

printapiversion()
{
if echo "$1" | grep -q '/'; then
  echo "$1" | cut -d'/' -f1
else
  echo ""
fi
}

set -x
# Namespaces with resources that probably have finalizers/dependencies (needs manual traverse to patch and delete else it will hang)
CATTLE_NAMESPACES="local cattle-system cattle-impersonation-system cattle-global-data cattle-global-nt cattle-provisioning-capi-system cattle-ui-plugin-system"
TOOLS_NAMESPACES="istio-system cattle-resources-system cis-operator-system cattle-dashboards cattle-gatekeeper-system cattle-alerting cattle-logging cattle-pipeline cattle-prometheus rancher-operator-system cattle-monitoring-system cattle-logging-system cattle-elemental-system"
FLEET_NAMESPACES="cattle-fleet-clusters-system cattle-fleet-local-system cattle-fleet-system fleet-default fleet-local fleet-system"

# Delete MMAI install to not have anything running that (re)creates resources
kcd "-n cattle-system deploy,ds --all"
kubectl -n cattle-system wait --for delete pod --selector=app=mmai
# Delete the only resource not in cattle namespaces
kcd "-n kube-system configmap cattle-controllers"

# Delete any blocking webhooks from preventing requests
if kubectl get mutatingwebhookconfigurations -o name | grep -q cattle\.io; then
    kcd "$(kubectl get mutatingwebhookconfigurations -o name | grep cattle\.io)"
fi
if kubectl get validatingwebhookconfigurations -o name | grep -q cattle\.io; then
    kcd "$(kubectl get validatingwebhookconfigurations -o name | grep cattle\.io)"
fi

# Delete any monitoring webhooks
if kubectl get mutatingwebhookconfigurations -o name | grep -q rancher-monitoring; then
    kcd "$(kubectl get mutatingwebhookconfigurations -o name | grep rancher-monitoring)"
fi
if kubectl get validatingwebhookconfigurations -o name | grep -q rancher-monitoring; then
    kcd "$(kubectl get validatingwebhookconfigurations -o name | grep rancher-monitoring)"
fi
# Delete any gatekeeper webhooks
if kubectl get validatingwebhookconfigurations -o name | grep -q gatekeeper; then
    kcd "$(kubectl get validatingwebhookconfigurations -o name | grep gatekeeper)"
fi

# Delete any istio webhooks
if kubectl get mutatingwebhookconfigurations -o name | grep -q istio;  then
    kcd "$(kubectl get mutatingwebhookconfigurations -o name | grep istio)"
fi
if kubectl get validatingwebhookconfigurations -o name | grep -q istio; then
    kcd "$(kubectl get validatingwebhookconfigurations -o name | grep istio)"
fi

# Cluster api
if [ -n "$(kubectl get validatingwebhookconfiguration.admissionregistration.k8s.io/validating-webhook-configuration)" ]; then
    kcd validatingwebhookconfiguration.admissionregistration.k8s.io/validating-webhook-configuration
fi
if [ -n "$(kubectl get mutatingwebhookconfiguration.admissionregistration.k8s.io/mutating-webhook-configuration)" ]; then
    kcd mutatingwebhookconfiguration.admissionregistration.k8s.io/mutating-webhook-configuration
fi

# Delete any MMAI webhooks
kubectl get mutatingwebhookconfigurations -o name | grep -e mmai -e kueue -e mmcloud -e nvidia -e hami | while read -r WH; do
  kcd "$WH"
done
kubectl get validatingwebhookconfigurations -o name | grep -e mmai -e kueue -e mmcloud -e nvidia -e hami | while read -r WH; do
  kcd "$WH"
done

# Delete generic k8s resources either labeled with norman or resource name starting with "cattle|rancher|fleet"
# ClusterRole/ClusterRoleBinding
kubectl get clusterrolebinding -l cattle.io/creator=norman --no-headers -o custom-columns=NAME:.metadata.name | while read -r CRB; do
  kcpf clusterrolebindings "$CRB"
  kcd "clusterrolebindings ""$CRB"""
done

kubectl get clusterrolebinding --no-headers -o custom-columns=NAME:.metadata.name | grep ^cattle- | while read -r CRB; do
  kcpf clusterrolebindings "$CRB"
  kcd "clusterrolebindings ""$CRB"""
done

kubectl get clusterrolebinding --no-headers -o custom-columns=NAME:.metadata.name | grep rancher | while read -r CRB; do
  kcpf clusterrolebindings "$CRB"
  kcd "clusterrolebindings ""$CRB"""
done

kubectl get clusterrolebinding --no-headers -o custom-columns=NAME:.metadata.name | grep ^fleet- | while read -r CRB; do
  kcpf clusterrolebindings "$CRB"
  kcd "clusterrolebindings ""$CRB"""
done

kubectl get clusterrolebinding --no-headers -o custom-columns=NAME:.metadata.name | grep ^gitjob | while read -r CRB; do
  kcpf clusterrolebindings "$CRB"
  kcd "clusterrolebindings ""$CRB"""
done

kubectl get clusterrolebinding --no-headers -o custom-columns=NAME:.metadata.name | grep ^pod-impersonation-helm- | while read -r CRB; do
  kcpf clusterrolebindings "$CRB"
  kcd "clusterrolebindings ""$CRB"""
done

kubectl get clusterrolebinding --no-headers -o custom-columns=NAME:.metadata.name | grep ^gatekeeper | while read -r CRB; do
  kcpf clusterrolebindings "$CRB"
  kcd "clusterrolebindings ""$CRB"""
done

kubectl get clusterrolebinding --no-headers -o custom-columns=NAME:.metadata.name | grep ^cis | while read -r CRB; do
  kcpf clusterrolebindings "$CRB"
  kcd "clusterrolebindings ""$CRB"""
done

kubectl get clusterrolebinding --no-headers -o custom-columns=NAME:.metadata.name | grep ^istio | while read -r CRB; do
  kcpf clusterrolebindings "$CRB"
  kcd "clusterrolebindings ""$CRB"""
done

kubectl get clusterrolebinding --no-headers -o custom-columns=NAME:.metadata.name | grep ^elemental | while read -r CRB; do
  kcpf clusterrolebindings "$CRB"
  kcd "clusterrolebindings ""$CRB"""
done

kubectl get clusterrolebinding --no-headers -o custom-columns=NAME:.metadata.name | grep -e ^mmai -e ^kueue -e ^mmcloud -e ^gpu-operator -e ^hami | while read -r CRB; do
  kcpf clusterrolebindings "$CRB"
  kcd "clusterrolebindings ""$CRB"""
done

kubectl  get clusterroles -l cattle.io/creator=norman --no-headers -o custom-columns=NAME:.metadata.name | while read -r CR; do
  kcpf clusterroles "$CR"
  kcd "clusterroles ""$CR"""
done

kubectl get clusterroles --no-headers -o custom-columns=NAME:.metadata.name | grep ^cattle- | while read -r CR; do
  kcpf clusterroles "$CR"
  kcd "clusterroles ""$CR"""
done

kubectl get clusterroles --no-headers -o custom-columns=NAME:.metadata.name | grep rancher | while read -r CR; do
  kcpf clusterroles "$CR"
  kcd "clusterroles ""$CR"""
done

kubectl get clusterroles --no-headers -o custom-columns=NAME:.metadata.name | grep ^fleet | while read -r CR; do
  kcpf clusterroles "$CR"
  kcd "clusterroles ""$CR"""
done

kubectl get clusterroles --no-headers -o custom-columns=NAME:.metadata.name | grep ^gitjob | while read -r CR; do
  kcpf clusterroles "$CR"
  kcd "clusterroles ""$CR"""
done

kubectl get clusterroles --no-headers -o custom-columns=NAME:.metadata.name | grep ^pod-impersonation-helm | while read -r CR; do
  kcpf clusterroles "$CR"
  kcd "clusterroles ""$CR"""
done

kubectl get clusterroles --no-headers -o custom-columns=NAME:.metadata.name | grep ^logging- | while read -r CR; do
  kcpf clusterroles "$CR"
  kcd "clusterroles ""$CR"""
done

kubectl get clusterroles --no-headers -o custom-columns=NAME:.metadata.name | grep ^monitoring- | while read -r CR; do
  kcpf clusterroles "$CR"
  kcd "clusterroles ""$CR"""
done

kubectl get clusterroles --no-headers -o custom-columns=NAME:.metadata.name | grep ^gatekeeper | while read -r CR; do
  kcpf clusterroles "$CR"
  kcd "clusterroles ""$CR"""
done

kubectl get clusterroles --no-headers -o custom-columns=NAME:.metadata.name | grep ^cis | while read -r CR; do
  kcpf clusterroles "$CR"
  kcd "clusterroles ""$CR"""
done

kubectl get clusterroles --no-headers -o custom-columns=NAME:.metadata.name | grep ^istio | while read -r CR; do
  kcpf clusterroles "$CR"
  kcd "clusterroles ""$CR"""
done

kubectl get clusterroles --no-headers -o custom-columns=NAME:.metadata.name | grep ^elemental | while read -r CR; do
  kcpf clusterroles "$CR"
  kcd "clusterroles ""$CR"""
done

kubectl get clusterroles --no-headers -o custom-columns=NAME:.metadata.name | grep -e ^mmai -e ^kueue -e ^mmcloud -e ^gpu-operator -e ^hami | while read -r CR; do
  kcpf clusterroles "$CR"
  kcd "clusterroles ""$CR"""
done

# Bulk delete data CRDs
# Saves time in the loop below where we patch/delete individual resources
DATACRDS="settings.management.cattle.io authconfigs.management.cattle.io features.management.cattle.io rkeaddons.management.cattle.io rkek8sserviceoptions.management.cattle.io rkek8ssystemimages.management.cattle.io catalogtemplateversions.management.cattle.io catalogtemplates.management.cattle.io rkeaddons.management.cattle.io tokens.management.cattle.io elemental.cattle.io"
for CRD in $DATACRDS; do
  kcd "crd $CRD"
done

# Delete apiservice
for APISERVICE in $(kubectl  get apiservice -o name | grep cattle | grep -v k3s\.cattle\.io | grep -v helm\.cattle\.io) $(kubectl  get apiservice -o name | grep gatekeeper\.sh) $(kubectl  get apiservice -o name | grep istio\.io) $(kubectl  get apiservice elemental-operator) apiservice\.apiregistration\.k8s\.io\/v1beta1\.custom\.metrics\.k8s\.io; do
  kcd "$APISERVICE"
done

# Pod security policies
#Check if psps are available on the target cluster
kubectl get podsecuritypolicy > /dev/null 2>&1

# Check the exit code and only run if there are psps available on the cluster
if [ $? -ne 0 ]; then
  echo "Removing PSPs"

  # Rancher logging
  for PSP in $(kubectl get podsecuritypolicy -o name -l app.kubernetes.io/name=rancher-logging) podsecuritypolicy.policy/rancher-logging-rke-aggregator; do
    kcd "$PSP"
  done

  # Rancher monitoring
  for PSP in $(kubectl  get podsecuritypolicy -o name -l release=rancher-monitoring) $(kubectl get podsecuritypolicy -o name -l app=rancher-monitoring-crd-manager) $(kubectl get podsecuritypolicy -o name -l app=rancher-monitoring-patch-sa) $(kubectl get podsecuritypolicy -o name -l app.kubernetes.io/instance=rancher-monitoring); do
    kcd "$PSP"
  done

  # Rancher OPA
  for PSP in $(kubectl  get podsecuritypolicy -o name -l release=rancher-gatekeeper) $(kubectl get podsecuritypolicy -o name -l app=rancher-gatekeeper-crd-manager); do
    kcd "$PSP"
  done

  # Backup restore operator
  for PSP in $(kubectl get podsecuritypolicy -o name -l app.kubernetes.io/name=rancher-backup); do
    kcd "$PSP"
  done

  # Istio
  for PSP in istio-installer istio-psp kiali-psp psp-istio-cni; do
    kcd "podsecuritypolicy $PSP"
  done
else
  echo "Kubernetes version v1.25 or higher, skipping PSP removal"
fi

# Get all namespaced resources and delete in loop
# Exclude helm.cattle.io and k3s.cattle.io to not break K3S/RKE2 addons
kubectl get "$(kubectl api-resources --namespaced=true --verbs=delete -o name| grep cattle\.io | grep -v helm\.cattle\.io | grep -v k3s\.cattle\.io | tr "\n" "," | sed -e 's/,$//')" -A --no-headers -o custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace,KIND:.kind,APIVERSION:.apiVersion | while read -r NAME NAMESPACE KIND APIVERSION; do
  kcpf -n "$NAMESPACE" "${KIND}.$(printapiversion "$APIVERSION")" "$NAME"
  kcd "-n ""$NAMESPACE"" ${KIND}.$(printapiversion "$APIVERSION") ""$NAME"""
done

# Logging
kubectl get "$(kubectl api-resources --namespaced=true --verbs=delete -o name| grep logging\.banzaicloud\.io | tr "\n" "," | sed -e 's/,$//')" -A --no-headers -o custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace,KIND:.kind,APIVERSION:.apiVersion | while read -r NAME NAMESPACE KIND APIVERSION; do
  kcpf -n "$NAMESPACE" "${KIND}.$(printapiversion "$APIVERSION")" "$NAME"
  kcd "-n ""$NAMESPACE"" ${KIND}.$(printapiversion "$APIVERSION") ""$NAME"""
done

kubectl get "$(kubectl api-resources --namespaced=true --verbs=delete -o name | grep -v events\.events\.k8s\.io | grep -v ^events$ | tr "\n" "," | sed -e 's/,$//')" -A --no-headers -o custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace,KIND:.kind,APIVERSION:.apiVersion | grep rancher-monitoring | while read -r NAME NAMESPACE KIND APIVERSION; do
  kcpf -n "$NAMESPACE" "${KIND}.$(printapiversion "$APIVERSION")" "$NAME"
  kcd "-n ""$NAMESPACE"" ${KIND}.$(printapiversion "$APIVERSION") ""$NAME"""
done

# Monitoring
kubectl get "$(kubectl api-resources --namespaced=true --verbs=delete -o name| grep monitoring\.coreos\.com | tr "\n" "," | sed -e 's/,$//')" -A --no-headers -o custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace,KIND:.kind,APIVERSION:.apiVersion | while read -r NAME NAMESPACE KIND APIVERSION; do
  kcpf -n "$NAMESPACE" "${KIND}.$(printapiversion "$APIVERSION")" "$NAME"
  kcd "-n ""$NAMESPACE"" ${KIND}.$(printapiversion "$APIVERSION") ""$NAME"""
done

# Gatekeeper
kubectl get "$(kubectl api-resources --namespaced=true --verbs=delete -o name| grep gatekeeper\.sh | tr "\n" "," | sed -e 's/,$//')" -A --no-headers -o custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace,KIND:.kind,APIVERSION:.apiVersion | while read -r NAME NAMESPACE KIND APIVERSION; do
  kcpf -n "$NAMESPACE" "${KIND}.$(printapiversion "$APIVERSION")" "$NAME"
  kcd "-n ""$NAMESPACE"" ${KIND}.$(printapiversion "$APIVERSION") ""$NAME"""
done

# Cluster-api
kubectl get "$(kubectl api-resources --namespaced=true --verbs=delete -o name| grep cluster\.x-k8s\.io | tr "\n" "," | sed -e 's/,$//')" -A --no-headers -o custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace,KIND:.kind,APIVERSION:.apiVersion | while read -r NAME NAMESPACE KIND APIVERSION; do
  kcpf -n "$NAMESPACE" "${KIND}.$(printapiversion "$APIVERSION")" "$NAME"
  kcd "-n ""$NAMESPACE"" ${KIND}.$(printapiversion "$APIVERSION") ""$NAME"""
done

# MMAI
kubectl get "$(kubectl api-resources --namespaced=true --verbs=delete -o name| grep -e memverge\.ai -e kueue\.x-k8s\.io -e mmcloud\.io -e nvidia\.com -e nfd\.k8s-sigs\.io -e hami\.io | tr "\n" "," | sed -e 's/,$//')" -A --no-headers -o custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace,KIND:.kind,APIVERSION:.apiVersion | while read -r NAME NAMESPACE KIND APIVERSION; do
  kcpf -n "$NAMESPACE" "${KIND}.$(printapiversion "$APIVERSION")" "$NAME"
  kcd "-n ""$NAMESPACE"" ${KIND}.$(printapiversion "$APIVERSION") ""$NAME"""
done


# Get all non-namespaced resources and delete in loop
kubectl get "$(kubectl api-resources --namespaced=false --verbs=delete -o name| grep cattle\.io | tr "\n" "," | sed -e 's/,$//')" -A --no-headers -o name | while read -r NAME; do
  kcpf "$NAME"
  kcd "$NAME"
done

# Logging
kubectl get "$(kubectl api-resources --namespaced=false --verbs=delete -o name| grep logging\.banzaicloud\.io | tr "\n" "," | sed -e 's/,$//')" -A --no-headers -o name | while read -r NAME; do
  kcpf "$NAME"
  kcd "$NAME"
done

# Gatekeeper
kubectl get "$(kubectl api-resources --namespaced=false --verbs=delete -o name| grep gatekeeper\.sh | tr "\n" "," | sed -e 's/,$//')" -A --no-headers -o name | while read -r NAME; do
  kcpf "$NAME"
  kcd "$NAME"
done

# MMAI
kubectl get "$(kubectl api-resources --namespaced=false --verbs=delete -o name| grep  -e memverge\.ai -e kueue\.x-k8s\.io -e mmcloud\.io -e nvidia\.com -e nfd\.k8s-sigs\.io -e hami\.io | tr "\n" "," | sed -e 's/,$//')" -A --no-headers -o name | while read -r NAME; do
  kcpf "$NAME"
  kcd "$NAME"
done

# Delete istio certs
for NS in $(kubectl  get ns --no-headers -o custom-columns=NAME:.metadata.name); do
  kcd "-n ${NS} configmap istio-ca-root-cert"
done

# Delete all cattle namespaces, including project namespaces (p-),cluster (c-),cluster-fleet and user (user-) namespaces
for NS in $TOOLS_NAMESPACES $FLEET_NAMESPACES $CATTLE_NAMESPACES; do
  kubectl get "$(kubectl api-resources --namespaced=true --verbs=delete -o name| grep -v events\.events\.k8s\.io | grep -v ^events$ | tr "\n" "," | sed -e 's/,$//')" -n "$NS" --no-headers -o custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace,KIND:.kind,APIVERSION:.apiVersion | while read -r NAME NAMESPACE KIND APIVERSION; do
    kcpf -n "$NAMESPACE" "${KIND}.$(printapiversion "$APIVERSION")" "$NAME"
    kcd "-n ""$NAMESPACE"" ${KIND}.$(printapiversion "$APIVERSION") ""$NAME"""
  done

  kcdns "$NS"
done

for NS in $(kubectl get namespace --no-headers -o custom-columns=NAME:.metadata.name | grep "^cluster-fleet"); do
  kubectl get "$(kubectl api-resources --namespaced=true --verbs=delete -o name| grep -v events\.events\.k8s\.io | grep -v ^events$ | tr "\n" "," | sed -e 's/,$//')" -n "$NS" --no-headers -o custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace,KIND:.kind,APIVERSION:.apiVersion | while read -r NAME NAMESPACE KIND APIVERSION; do
    kcpf -n "$NAMESPACE" "${KIND}.$(printapiversion "$APIVERSION")" "$NAME"
    kcd "-n ""$NAMESPACE"" ${KIND}.$(printapiversion "$APIVERSION") ""$NAME"""
  done

  kcdns "$NS"
done

for NS in $(kubectl get namespace --no-headers -o custom-columns=NAME:.metadata.name | grep "^p-"); do
  kubectl get "$(kubectl api-resources --namespaced=true --verbs=delete -o name| grep -v events\.events\.k8s\.io | grep -v ^events$ | tr "\n" "," | sed -e 's/,$//')" -n "$NS" --no-headers -o custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace,KIND:.kind,APIVERSION:.apiVersion | while read -r NAME NAMESPACE KIND APIVERSION; do
    kcpf -n "$NAMESPACE" "${KIND}.$(printapiversion "$APIVERSION")" "$NAME"
    kcd "-n ""$NAMESPACE"" ${KIND}.$(printapiversion "$APIVERSION") ""$NAME"""
  done

  kcdns "$NS"
done

for NS in $(kubectl get namespace --no-headers -o custom-columns=NAME:.metadata.name | grep "^c-"); do
  kubectl get "$(kubectl api-resources --namespaced=true --verbs=delete -o name| grep -v events\.events\.k8s\.io | grep -v ^events$ | tr "\n" "," | sed -e 's/,$//')" -n "$NS" --no-headers -o custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace,KIND:.kind,APIVERSION:.apiVersion | while read -r NAME NAMESPACE KIND APIVERSION; do
    kcpf -n "$NAMESPACE" "${KIND}.$(printapiversion "$APIVERSION")" "$NAME"
    kcd "-n ""$NAMESPACE"" ${KIND}.$(printapiversion "$APIVERSION") ""$NAME"""
  done

  kcdns "$NS"
done

for NS in $(kubectl get namespace --no-headers -o custom-columns=NAME:.metadata.name | grep "^user-"); do
  kubectl get "$(kubectl api-resources --namespaced=true --verbs=delete -o name| grep -v events\.events\.k8s\.io | grep -v ^events$ | tr "\n" "," | sed -e 's/,$//')" -n "$NS" --no-headers -o custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace,KIND:.kind,APIVERSION:.apiVersion | while read -r NAME NAMESPACE KIND APIVERSION; do
    kcpf -n "$NAMESPACE" "${KIND}.$(printapiversion "$APIVERSION")" "$NAME"
    kcd "-n ""$NAMESPACE"" ${KIND}.$(printapiversion "$APIVERSION") ""$NAME"""
  done

  kcdns "$NS"
done

for NS in $(kubectl get namespace --no-headers -o custom-columns=NAME:.metadata.name | grep "^u-"); do
  kubectl get "$(kubectl api-resources --namespaced=true --verbs=delete -o name| grep -v events\.events\.k8s\.io | grep -v ^events$ | tr "\n" "," | sed -e 's/,$//')" -n "$NS" --no-headers -o custom-columns=NAME:.metadata.name,NAMESPACE:.metadata.namespace,KIND:.kind,APIVERSION:.apiVersion | while read -r NAME NAMESPACE KIND APIVERSION; do
    kcpf -n "$NAMESPACE" "${KIND}.$(printapiversion "$APIVERSION")" "$NAME"
    kcd "-n ""$NAMESPACE"" ${KIND}.$(printapiversion "$APIVERSION") ""$NAME"""
  done

  kcdns "$NS"
done

# Delete logging CRDs
for CRD in $(kubectl get crd -o name | grep logging\.banzaicloud\.io); do
  kcd "$CRD"
done

# Delete monitoring CRDs
for CRD in $(kubectl get crd -o name | grep monitoring\.coreos\.com); do
  kcd "$CRD"
done

# Delete OPA CRDs
for CRD in $(kubectl get crd -o name | grep gatekeeper\.sh); do
  kcd "$CRD"
done

# Delete Istio CRDs
for CRD in $(kubectl get crd -o name | grep istio\.io); do
  kcd "$CRD"
done

# Delete cluster-api CRDs
for CRD in $(kubectl get crd -o name | grep cluster\.x-k8s\.io); do
  kcd "$CRD"
done

# Delete all cattle CRDs
# Exclude helm.cattle.io and addons.k3s.cattle.io to not break RKE2 addons
for CRD in $(kubectl get crd -o name | grep cattle\.io | grep -v helm\.cattle\.io | grep -v k3s\.cattle\.io); do
  kcd "$CRD"
done

# Delete all MMAI CRDs
for CRD in $(kubectl get crd -o name | grep -e memverge\.ai -e kueue\.x-k8s\.io -e mmcloud\.io -e nvidia\.com -e nfd\.k8s-sigs\.io -e hami\.io); do
  kcd "$CRD"
done

# Remove MMAI labels from nodes
for node in $(kubectl get nodes -o name); do
  if kubectl get "$node" -o jsonpath="{.metadata.labels}" | grep -q memverge\.ai; then
    kubectl label "$node" memverge.ai/nodegroup- memverge.ai/fractional-gpu- node.kubernetes.io/unschedulable-
  fi
done
