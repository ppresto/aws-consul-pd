#!/bin/bash
SCRIPT_DIR=$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)
#CTX1=usw2

if [[ -z $CTX1 ]]; then
    CTX1=$(kubectl config current-context)
fi

deploy() {
    # deploy eastus services
    kubectl config use-context ${CTX1}
    kubectl create ns web
    kubectl apply -f ${SCRIPT_DIR}/init-consul-config/sg-samenessGroup.yaml
    kubectl apply -f ${SCRIPT_DIR}/init-consul-config
    kubectl apply -f ${SCRIPT_DIR}/
}

delete() {
    kubectl config use-context ${CTX1}
    kubectl delete -f ${SCRIPT_DIR}/
    kubectl delete -f ${SCRIPT_DIR}/init-consul-config
    kubectl delete ns web
}

#Cleanup if any param is given on CLI
if [[ ! -z $1 ]]; then
    echo "Deleting Services"
    delete
else
    echo "Deploying Services"
    deploy
fi