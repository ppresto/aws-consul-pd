# Traffic Mgmt Use Cases 

## PreReq
* Consul is installed in 2 DCs
* Consul Mesh Gateways are routable across both DCs
* Consul API Gateway configured for ingress
* fake-services (web,api-v1, api-v2) deployed and healthy in both DCs
    ```
    cd ./examples

    kubectl config use-context usw2
    kubectl apply -f consul-apigw/
    ./fake-service/web/deploy.sh
    ./fake-service/api/deploy.sh

    kubectl config use-context use1
    kubectl apply -f consul-apigw/
    ./fake-service/web/deploy.sh
    ./fake-service/api/deploy.sh
    ```

### AWS Peer Transit gateways
This this repo was used to provision infra, then it can Peer the usw2 and use1 TGWs and create required routes.  Rename the following file:
```
cd ../quickstart/2vpc-2eks-multiregion/
mv ./tgw-peering-usw2-to-use1.tf.dis ./tgw-peering-usw2-to-use1.tf
terraform apply -auto-approve
terraform apply -auto-approve
```
Run terraform to peer the regional transit gateways and run it a second time to create the necessary routes.  Sometimes the regional peering isn't completed before route creation is attempted so rerunning terraform will resolve this timing issue.

## Peering
Connect the Consul DCs to enable multi-region communication for distributed services or failover.
```
peering/peer_dc1_to_dc2.sh
```

### Sameness Groups

### Exported Services

### Intentions (Authorization)

## Failover