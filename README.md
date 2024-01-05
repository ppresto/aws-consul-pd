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
- AWS Key Pair
- Terraform 1.3.7+
- aws cli
- kubectl
- helm
- curl
- jq

## Getting Started
```
cd quickstart/2vpc-2eks-multiregion
```
Update the `my.auto.tfvars` for your environment.  Configure your existing AWS Key Pair that is present in both target regions (**us-west-2, us-east-1**) or copy a local SSH key to all your available regions using this script `./scripts/push-aws-sshkey-multiregion.sh`. Review the prefix being used for resource names, the EKS version, and Consul version. 

### Provision Infrastructure
Use terraform to build the required AWS Infrastructure
```
terraform init
terraform apply -auto-approve
```
**The initial apply might fail** and require multiple applies to properly setup transit gateways across 2 regions, peer them, and establish routes.

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
This terraform configuration will run helm to install Consul and create thae full helm values.yaml file for reference or to use when making future modifications.
```
cd consul_helm_values
terraform init
terraform apply -auto-approve
```
An example consul helm values can be found [here]((https://github.com/ppresto/aws-consul-pd/blob/main/quickstart/2vpc-2eks-multiregion/consul_helm_values/yaml/ex-values-server.yaml)).

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


## Next Steps
Once the EKS infrastructure is ready, and Consul is deployed it's time to build the service mesh.  A good starting place is to deploy the Consul API Gateway with fake-service.  This will create an ingress into the service mesh with a test service that is designed to validate service mesh traffic management use cases. Once this is setup validate the various use cases.
* [Deploy the Consul API Gateway and fake-service](https://github.com/ppresto/aws-consul-pd/blob/main/README_Consul_APIGW.md)
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