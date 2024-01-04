# HA/Failover across data centers

## PreReq
* Consul is installed in 2 DCs
* Consul Mesh Gateways are routable across both DCs
* Consul API Gateway configured for ingress
* fake-services (web,api-v1, api-v2) deployed and healthy in both DCs
    ```
    cd ./examples

    kubectl config use-context usw2
    ./fake-service/web/deploy.sh
    ./fake-service/api/deploy.sh
    kubectl apply -f consul-apigw/

    kubectl config use-context use1
    ./fake-service/web/deploy.sh
    ./fake-service/api/deploy.sh
    kubectl apply -f consul-apigw/
    ```

### Setup the required L3/L4 Connectivity between Consul data centers.
If this repo was used to provision infra, then it can Peer the usw2 and use1 AWS transit gateways and create required routes for L3/L4 connectivity between Consul data centers.  Consul is configured with best practices using mesh-gateways for all cross data center communication to improve security and simplify networking.  Ensure the following file ends with .tf and was applied and that your mesh-gateway service in both k8s clusters (aka: data centers) are routable. 
```
cd ../quickstart/2vpc-2eks-multiregion/
mv ./tgw-peering-usw2-to-use1.tf.dis ./tgw-peering-usw2-to-use1.tf
terraform apply -auto-approve
terraform apply -auto-approve
```
Run terraform to peer the regional transit gateways and run it a second time to create the necessary routes within each tgw.  Sometimes the regional peering status isn't updated before route creation is attempted so rerunning terraform will resolve this timing issue.

## Peer Consul data centers so they can share their service registry data and provide multi-regional failover routing.
Connect the Consul DCs to enable multi-region communication for distributed services or failover.
```
peering/peer_dc1_to_dc2.sh
```
The Consul UI can be used to peer data centers and verify the health of a peering connection.

### Setup DNS forwarding (optional)
It can be helpful to lookup remote services using Consul DNS when troubleshooting.  Service calls within the mesh are using the cni plugin and dont require this DNS forwarding.
```
../scripts/patch_coredns_to_forward_to_consul.sh
```
## Sameness Groups
Use sameness groups when deploying services to minimize service configuration and provide failover at the same time.  A sameness group allows a service or group of services to be configured together.  A sameness group consists of the following:
* SamenessGroup - Define the remote Peers or Partitions the should be used for HA/failover when the local services is unavailable.
* Intentions - authorize service to service requests both locally and from remote data centers.
* ExportedServices - The list of services allowed to be discovered from outside the local data center

### Create a Sameness Group
For each partition and peer that you want to include in the sameness group, you must write and apply a sameness group CRD that defines the group’s members from that partition’s perspective. All services are running in their own namespaces within the default Consul partition.  So this configuration includes all the local services running in the default partition, and then looks at the listed peering connections.  This repo is enabling [Automatic failover using sameness groups](https://developer.hashicorp.com/consul/docs/connect/manage-traffic/failover/sameness). The following was already applied when deploying `web`.  

```./examples/fake-service/web/init-consul-config/sg-samenessGroup.yaml
apiVersion: consul.hashicorp.com/v1alpha1
kind: SamenessGroup
metadata:
  name: shared-sameness-group
spec:
  defaultForFailover: true
  members:
    - partition: default
    - peer: usw2-default
    - peer: use1-default
```
Another alternative is to enable [Failover using a service resolver](https://developer.hashicorp.com/consul/docs/connect/manage-traffic/failover/sameness#failover-with-a-service-resolver-configuration-entry) to define granular failover rules and targets.  This may be desireable in more complex environments and below is an example.
```
apiVersion: consul.hashicorp.com/v1alpha1
kind: ServiceResolver
metadata:
  name: db
spec:
  defaultSubset: v1
  subsets:
    v1:
      filter: 'Service.Meta.version == v1'
    v2:
      filter: 'Service.Meta.version == v2'
  failover:
    v1:
      samenessGroup: "product-group"
    v2:
      service: "canary-db"

```
Refer to the [sameness group configuration entry reference](https://developer.hashicorp.com/consul/docs/connect/config-entries/sameness-group) for details on configuration hierarchy, default values, and specifications.

### Export Services
Export services to members of the sameness group. When deploying `web` the exported services CRD was applied to make the partition’s services available to other members of the group. 
```./examples/fake-service/web/init-consul-config/sg-exportedServices.yaml
apiVersion: consul.hashicorp.com/v1alpha1
kind: ExportedServices
metadata:
  name: default ## The name of the partition containing the service
spec:
  services:
    - name: mesh-gateway
      namespace: default
      consumers:
        - samenessGroup: shared-sameness-group
    - name: web ## The name of the service you want to export
      namespace: web
      consumers:
        - samenessGroup: shared-sameness-group
    - name: api ## The name of the service you want to export
      namespace: api
      consumers:
        - samenessGroup: shared-sameness-group
    - name: payments ## The name of the service you want to export
      namespace: payments
      consumers:
        - samenessGroup: shared-sameness-group
```
Refer to [exported services configuration entry](https://developer.hashicorp.com/consul/docs/connect/config-entries/exported-services) reference for additional specification information.  

### Intentions (Authorization)
For each partition that you want to include in the sameness group, you must write and apply service intentions CRDs to authorize traffic to your services from all members of the group. When deploying `web` the below CRD was applied. 
```./examples/fake-service/web/init-consul-config/sg-intentions.yaml
apiVersion: consul.hashicorp.com/v1alpha1
kind: ServiceIntentions
metadata:
  name: api-gateway-web
spec:
  destination:
    name: web
    namespace: web
  sources:
    - name: api-gateway
      namespace: consul
      action: allow
      samenessGroup: shared-sameness-group
```
Refer to the [service intentions configuration entry reference](https://developer.hashicorp.com/consul/docs/connect/config-entries/service-intentions) for additional specification information.

## Failover
At this point, both usw2 and use1 data centers should have all services available through the API Gateway URL.  Verify the health of both datacenters using their API Gateway URL.
```
usw2
kubectl get services --namespace=consul api-gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
use1
kubectl get services --namespace=consul api-gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}'
```

Choose a data center and delete the `api` deployments.
```
usw2
kubectl -n api get deployments
kubectl -n api delete deployments api-v1 api-v2
```
Go to that data centers API Gateway URL and first verify the IP address of the api.virtual.api.ns.consul:9091 instance.  Now refresh, and the service should respond but with an IP address from the other data center.  

Redeploy `api` and then refresh again to see requests immediately route locally once the service is available.
```
./examples/fake-service/api/deploy.sh
```
Try doing the same steps from the other data center.