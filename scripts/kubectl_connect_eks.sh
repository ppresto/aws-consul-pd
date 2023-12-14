#!/bin/bash

SCRIPT_DIR=$(cd $(dirname "${BASH_SOURCE[0]}") && pwd)
PROFILE="assumed-role"

# Setup local AWS Env variables
if [[ -z $1 ]]; then  #Pass path for tfstate dir if not in quickstart.
output=$(terraform output -state $SCRIPT_DIR/../quickstart/terraform.tfstate -json)
else
output=$(terraform output -state ${1}/terraform.tfstate -json)
fi
PROJECTS=($(echo $output | jq -r '. | to_entries[] | select(.key|endswith("_projects")) | .value.value[]'))

# Authenticate to EKS
EKS_CLUSTER_NAMES=$(echo $output | jq -r ".| to_entries[] | select(.key|endswith(\"_eks_cluster_names\")) | .value.value | to_entries[] | (.key)")
REGIONS=$(echo $output |jq -r ".| to_entries[] | select(.key|endswith(\"_regions\")) | .value.value | to_entries[] | (.value)")
for cluster in ${EKS_CLUSTER_NAMES}
do
    if [[ ! ${cluster} == "null" ]]; then
        regions=$(echo $output | jq -r ".| to_entries[] | select(.key|endswith(\"_eks_cluster_names\")) | .value.value.\"${cluster}\"")
        for region in ${regions}
        do
            if [[ ! ${region} == "null" ]]; then
                echo
                echo "Authenticating to EKS Cluster ${cluster} - ${region}"
                # get identity
                aws sts get-caller-identity
                # add EKS cluster to $HOME/.kube/config
                aws eks --region $region update-kubeconfig --name $cluster --alias "${cluster##*-}" 
                #aws eks --region $region update-kubeconfig --name $cluster --alias "${cluster##*-}" --profile "${PROFILE}" 
            fi
        done
    fi
done

Setup EKS aliases per project
echo
echo "EKS Environments"
echo

for cluster in ${EKS_CLUSTER_NAMES}
do
    if [[ ! ${cluster} == "null" ]]; then
        regions=$(echo $output | jq -r ".| to_entries[] | select(.key|endswith(\"_eks_cluster_names\")) | .value.value.\"${cluster}\"")
        for region in ${regions}
        do
            if [[ ! ${region} == "null" ]]; then
                echo "  EKS_CLUSTER_NAME: ${cluster}"
                echo "  Region: ${region}"
                alias $(echo ${cluster##*-})="kubectl config use-context ${cluster##*-}"
                echo "  alias: ${cluster##*-} =  kubectl config use-context ${cluster##*-}"
                echo
            fi
        done
    fi
done
echo "extra aliases"
echo "  alias: kk=kubectl -n kube-system"
echo "  alias: kc=kubectl -n consul"
echo "  alias: kw=kubectl -n web"
echo "  alias: ka=kubectl -n api"

# Setup Global aliases
alias 'kc=kubectl -n consul'
alias 'kw=kubectl -n web'
alias 'ka=kubectl -n api'
alias 'kk=kubectl -n kube-system'
