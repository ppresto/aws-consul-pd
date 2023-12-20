# Traffic Mgmt Use Cases 

## PreReq
* Consul is installed
* Consul API Gateway configured
* fake-services (web,api) deployed

## Circuit Breaking

The `web` servicedefaults (`./examples/fake-service/web/init-consul-config/servicedefaults-circuitbreaker.yaml`) have been configured with limits and passiveHealthChecks to enable circuit breaking.  `web` routes to multiple `api` instances (v1, v2). api-v2 is configured to fail 30% of the time.  Run the following script to see requests load balance across v1,v2 and once v2 fails requests should be routed to v1 for 10 seconds.  Once v2 passes the health check requests can route there again.  This flow should repeate over and over.
```
./examples/apigw-requests.sh
```

## Rate Limiting
The `api` servicedefaults (`./examples/fake-service/api/init-consul-config/servicedefaults.yaml`) are setup to limit 200 requests per second to / and only 1 request per second to /api-v1.  All requests to / should respond with an HTTP 200 code everytime, and /api-v1 should return an HTTP 429 anytime there is more then 1 req/sec.  Below is a simple shell script that uses curl to send requests to the Consul APIGW and returns the service name and HTTP code. 

```
./apigw-requests.sh -w .4 -p /
./apigw-requests.sh -w .4 -p /api-v1
```
Usage: ./apigw-requests.sh -w [Sleep wait time] -p [URI Path]


## Retries

```
kubectl delete -f examples/fake-service/api/api-v2.yaml
```
Get Envoy stats
```
kubectl -n web exec -it deployment/web-deployment -c web -- /usr/bin/curl -s localhost:19000/stats | sort | awk '$NF!=0'
kubectl -n web exec -it deployment/web-deployment -c web -- /usr/bin/curl -s localhost:19000/stats | sort | grep -i retry
kubectl -n web exec -it deployment/web-deployment -c web -- /usr/bin/curl -s localhost:19000/stats | sort | grep -i attempt
```


