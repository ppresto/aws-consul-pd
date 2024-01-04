# aws-consul-pd
This repo can build the required AWS Networking and EKS resources to run self hosted Consul clusters on EKS in two different regions and enable inner-region connectivity to test distributed services and failover use cases with Consul.  

If infrastructure already exists, use the included [Consul helm configuration](https://github.com/ppresto/aws-consul-pd/blob/main/quickstart/2vpc-2eks-multiregion/consul_helm_values/yaml/ex-values-server.yaml) to help deploy Consul and validate the following Consul service mesh use cases with the guides below.
* [Deploy API Gateway](https://github.com/ppresto/aws-consul-pd/blob/main/README_Consul_APIGW.md)
* [circuit breaking](https://github.com/ppresto/aws-consul-pd/blob/main/README_Consul_L7.md#circuit-breaking)
* [rate limiting](https://github.com/ppresto/aws-consul-pd/blob/main/README_Consul_L7.md#rate-limiting)
* [retries](https://github.com/ppresto/aws-consul-pd/blob/main/README_Consul_L7.md#retries)
* [timeouts](https://github.com/ppresto/aws-consul-pd/blob/main/README_Consul_L7.md#timeouts)
* [multi-region service failover](https://github.com/ppresto/aws-consul-pd/blob/main/README_Consul_Failover.md)

## Pre Reqs
- Consul Enterprise License `./files/consul.lic`
- Setup shell with AWS credentials
- Terraform 1.3.7+
- aws cli
- kubectl
- helm
- curl
- jq

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
../../scripts/install_awslb_controller.sh .
```

### Install Consul
This terraform configuration will run helm and create the full helm values file for future modifications.
```
cd consul_helm_values
terraform init
terraform apply -auto-approve
```
An example consul helm values can be found [here]((https://github.com/ppresto/aws-consul-pd/blob/main/quickstart/2vpc-2eks-multiregion/consul_helm_values/yaml/ex-values-server.yaml))

### Login to the Consul UI
Connect to the EKS cluster running the consul server you want to access (usw2 | use1)
```
usw2  #alias created by the connect script to switch context to the usw2 eks cluster
```

Next, run the following script to get the external LB URL and Consul Root Token to login.
```
cd ..
../../scripts/setConsulEnv.sh
```
## Use Cases
* [Setup API Gateway](https://github.com/ppresto/aws-consul-pd/blob/main/README_Consul_APIGW.md)
* [circuit breaking](https://github.com/ppresto/aws-consul-pd/blob/main/README_Consul_L7.md#circuit-breaking)
* [rate limiting](https://github.com/ppresto/aws-consul-pd/blob/main/README_Consul_L7.md#rate-limiting)
* [retries](https://github.com/ppresto/aws-consul-pd/blob/main/README_Consul_L7.md#retries)
* [timeouts](https://github.com/ppresto/aws-consul-pd/blob/main/README_Consul_L7.md#timeouts)
* [multi-region service failover](https://github.com/ppresto/aws-consul-pd/blob/main/README_Consul_Failover.md)

## References
Circuit Breaking
https://developer.hashicorp.com/consul/tutorials/developer-mesh/service-mesh-circuit-breaking#set-up-circuit-breaking

API GW Timeouts
https://developer.hashicorp.com/consul/docs/connect/gateways/api-gateway/configuration/routeretryfilter
https://developer.hashicorp.com/consul/docs/connect/gateways/api-gateway/configuration/routetimeoutfilter