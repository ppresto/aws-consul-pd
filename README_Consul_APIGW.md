# aws-consul-pd
Setup the Consul API Gateway (apigw) with fake-service to access services inside the service mesh.

## Deploy services
The fake-service can be configured as any service and can route requests to any number of other upstreams. 
* Deploy 2 services (web, api) into the Consul service mesh, and each will run in their own K8s namespace.  
* fake-service `web` will be configured to route to `api`.
* Create Consul intentions to authorize `web` to route requests to `api`.

```
cd ./examples
./fake-service/web/deploy.sh
./fake-service/api/deploy.sh
```

## Deploy the Consul apigw
Authenticate to the EKS cluster and ensure you are on the context (ex: usw2) you want to deploy the api-gateway to.
* Deploy Gateway to listen on port 80
* Set annotations to support AWS LB Controller
* Create RBACs so the API gateway can interact with Consul resources
* Configure HTTP routes for services in the mesh (`web`, `api`).

```
kubectl apply -f consul-apigw/
```

### Get apigw URL
```
export APIGW_URL=$(kubectl get services --namespace=consul api-gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "Wait for the external DNS name to be resolvable"
nslookup ${APIGW_URL}
```

## Access the services using the HTTP routes defined in the apigw
```
echo "http://${APIGW_URL}/"
echo "http://${APIGW_URL}/web"
echo "http://${APIGW_URL}/api"
```

## Clean up
```
kubectl delete -f consul-apigw/
./fake-service/web/deploy.sh -d
./fake-service/api/deploy.sh -d

```