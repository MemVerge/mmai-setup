#!/bin/bash

RELEASE_NAMESPACE='mmcai-system'
MMCLOUD_OPERATOR_NAMESPACE='mmcloud-operator-system'
PROMETHEUS_NAMESPACE='monitoring'

CERT_MANAGER_VERSION='v1.15.3'
KUBEFLOW_VERSION='v1.9.0'
KUBEFLOW_ISTIO_VERSION='1.22'
NVIDIA_GPU_OPERATOR_VERSION='v24.3.0'

ANSIBLE_VENV='mmai-ansible'
ANSIBLE_INVENTORY_DATABASE_NODE_GROUP='mmai_database'

KUBEFLOW_MANIFEST='kubeflow-manifest.yaml'

ensure_prerequisites() {
    local script='ensure-prerequisites.sh'
    if ! curl -LfsSo $script https://raw.githubusercontent.com/MemVerge/mmc.ai-setup/better-logging/$script; then
        echo "Error getting script: $script"
        return 1
    fi
    ./$script
}

build_kubeflow() {
    local base_dir
    if (( $# == 1 )) && [[ "$1" != "" ]] && [[ -d "$1" ]]; then
        # Use the specified log file.
        base_dir=$1
    else
        return 1
    fi

    git clone https://github.com/kubeflow/manifests.git $base_dir/kubeflow --branch $KUBEFLOW_VERSION

    # From DeepOps: Change the default Istio Ingress Gateway configuration to support NodePort for ease-of-use in on-prem
    path_istio_version=${KUBEFLOW_ISTIO_VERSION#v}
    path_istio_version=${path_istio_version//./-}
    sed -i 's:ClusterIP:NodePort:g' "$base_dir/kubeflow/common/istio-$path_istio_version/istio-install/base/patches/service.yaml"

    # From DeepOps: Make the Kubeflow cluster allow insecure http instead of https
    # https://github.com/kubeflow/manifests#connect-to-your-kubeflow-cluster
    sed -i 's:JWA_APP_SECURE_COOKIES=true:JWA_APP_SECURE_COOKIES=false:' "$base_dir/kubeflow/apps/jupyter/jupyter-web-app/upstream/base/params.env"
    sed -i 's:VWA_APP_SECURE_COOKIES=true:VWA_APP_SECURE_COOKIES=false:' "$base_dir/kubeflow/apps/volumes-web-app/upstream/base/params.env"
    sed -i 's:TWA_APP_SECURE_COOKIES=true:TWA_APP_SECURE_COOKIES=false:' "$base_dir/kubeflow/apps/tensorboard/tensorboards-web-app/upstream/base/params.env"

    kustomize build $base_dir/kubeflow/example > $base_dir/$KUBEFLOW_MANIFEST
}