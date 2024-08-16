#!/bin/bash

source logging.sh

## welcome message

div
log "Welcome to MMC.AI setup!"
div

NAMESPACE="mmcai-system"

div
log_good "Please provide information for billing database:"
div

read -p "MySQL database node hostname: " mysql_node_hostname
read -sp "MySQL root password: " MYSQL_ROOT_PASSWORD
echo ""


div
log_good "Creating namespaces if needed..."
div

## Create namespaces

kubectl get namespace $NAMESPACE &>/dev/null || kubectl create namespace $NAMESPACE
kubectl get namespace mmcloud-operator-system &>/dev/null || kubectl create namespace mmcloud-operator-system
kubectl get namespace monitoring &>/dev/null || kubectl create namespace monitoring

div
log_good "Creating secrets if needed..."
div

## Create MySQL secret

kubectl -n $NAMESPACE get secret mysql-secret &>/dev/null || \
kubectl -n $NAMESPACE create secret generic mysql-secret --from-literal=mysql-root-password=$MYSQL_ROOT_PASSWORD --from-literal=mysql-password=$MYSQL_ROOT_PASSWORD # TODO: Determine which passwords are needed for what

## Create image pull secrets

kubectl -n $NAMESPACE get secret memverge-dockerconfig &>/dev/null || \
kubectl -n $NAMESPACE create secret generic memverge-dockerconfig --from-file=.dockerconfigjson=$DOCKER_CONFIG --type=kubernetes.io/dockerconfigjson

kubectl -n mmcloud-operator-system get secret memverge-dockerconfig &>/dev/null || \
kubectl -n mmcloud-operator-system create secret generic memverge-dockerconfig --from-file=.dockerconfigjson=$DOCKER_CONFIG --type=kubernetes.io/dockerconfigjson

div
log_good "Beginning installation..."
div

## Add repository

helm repo add memverge https://memverge.github.io/mmc.ai-setup

## install mmc.ai system
helm install -n $NAMESPACE mmcai-cluster memverge/mmcai-cluster \
    --set billing.database.nodeHostname=$mysql_node_hostname

## install mmc.ai management
helm install -n $NAMESPACE mmcai-manager memverge/mmcai-manager