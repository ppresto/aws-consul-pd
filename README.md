# aws-consul-pd
This repo builds the required AWS Networking and EKS resources to run self hosted Consul clusters on EKS in two different regions.  Transit gateways are peered to allow for inner-region connectivity to test distributed services and failover with Consul.

## Pre Reqs
- Consul Enterprise License `./files/consul.lic`
- Setup shell with AWS credentials
- Terraform 1.3.7+
- aws cli
- kubectl
- helm

## Getting Started

### Provision Infrastructure
Use terraform to build the required AWS Infrastructure
```
cd quickstart/2vpc-2eks-multiregion
terraform init
terraform apply -auto-approve
```
**NOTE**, the initial apply might fail and require multiple applies to properly setup transit gateways across 2 regions, peer them, and establish routes.

### Connect to EKS clusters
Connect to EKS using `scripts/kubectl_connect_eks.sh`.  Pass this script the path to the terraform state file used to provision the EKS cluster.  If cwd is ./2vpc-2eks-multiregion like above then this command would look like the following:
```
source ../../scripts/kubectl_connect_eks.sh .
```
This script connects EKS and builds some useful aliases shown in the output.

### Install AWS Loadbalancer controller on EKS
This AWS LB controller is required to map internal NLB or ALBs to kubernetes services.  The helm templates used to install consul will attempt to leverage this controller.  This repo is adding the required tags to public and private subnets in order for the LB to properly discover them.  After connecting to the EKS clusters run this script.

```
../../install_aws_controller.sh .
```

### Install Consul
This terraform configuration will run helm and create the full helm values file for future modifications.
```
cd consul_helm_values
terraform init
terraform apply -auto-approve
```
### Login to the Consul UI
Connect to the EKS cluster running the consul server you want to access.
```
usw2  #alias created to switch context to the usw2 eks cluster
```

Next, run the following script to get the external LB URL and Consul Token
```
../../setConsulEnv.sh
```
