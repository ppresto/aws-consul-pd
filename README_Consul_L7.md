# Traffic Mgmt Use Cases 

## PreReq
* Consul is installed
* Consul API Gateway configured
* fake-services (web,api-v1, api-v2) deployed and healthy
    ```
    cd ./examples
    ./fake-service/web/deploy.sh
    ./fake-service/api/deploy.sh
    ```

## Circuit Breaking

Validate `api` services (v1, v2) are deployed, healthy, and returning 200 Status codes every request.  Below is a simple shell script that uses curl to send requests to the Consul APIGW and returns the service name and HTTP code.  
```
cd ./examples
./apigw-requests.sh -w .4
```
`-w` waits for # of seconds between requests.

`web` is routing to multiple `api` deployments (v1, v2). Redeploy v2 with the configuration below so it fails 50% of the time with HTTP Status 500.
```
kubectl apply -f fake-service/api/errors/
./apigw-requests.sh -w 1
```
Now `web` is experiencing many intermittent failures 25% of the time.
Configure `web` servicedefaults with limits and passiveHealthChecks to enable circuit breaking for its upstreams. 
```
kubectl apply -f fake-service/web/init-consul-config/servicedefaults-circuitbreaker.yaml.enable
```
search the web config_dump for `circuit_breaker` which should be configured for its upstream service api.

Run the following script to see requests load balance across api v1,v2 and once v2 fails requests should be routed to v1 for 10 seconds.  Once v2 passes the health check requests can route there again.  This flow should repeat over and over.
```
./apigw-requests.sh -w 1
```

### Clean up test
Remove the circuit breaker from `web` to restore normal behavior.
```
kubectl apply -f fake-service/api/api-v2.yaml
kubectl apply -f fake-service/web/init-consul-config/servicedefaults.yaml
kubectl -n web get servicedefaults web -o yaml
```

## Rate Limiting
The `api` servicedefaults (`./fake-service/api/init-consul-config/servicedefaults.yaml`) are already setup to limit 200 requests per second to / and only 1 request per second to /api-v2.  Redeploy services to make sure all requests are healthy.

```
./fake-service/web/deploy.sh
./fake-service/api/deploy.sh
```

Send 5 reqs/sec to / (or 1 request every .2 seconds)
```
# Usage: ./apigw-requests.sh -w [Sleep wait time] -p [URI Path]
./apigw-requests.sh -w .2 -p /
```
All requests to `-p` path / should respond with an HTTP 200 status code

Now send 5 reqs/sec to the rate limited path. Requests to /api-v2 should return an HTTP 429 anytime there is more then 1 req/sec.
```
./apigw-requests.sh -w .2 -p /api-v2
```

Verify the number of rate limited requests `web` received using envoy stats `consul.external.upstream_rq_429`
```
kubectl -n web exec -it deployment/web-v1 -c web -- /usr/bin/curl -s localhost:19000/stats | grep consul.external.upstream_rq_429
```
Envoy access logs will also show
```consul-dataplane {
"response_code_details":"via_upstream"
"response_code":429
...
```

Look at 1 instance of the upstream service `api` to see how many rq that instance rate limited.
```
kubectl -n api exec -it deployment/api-v2 -c api  -- /usr/bin/curl -s localhost:19000/stats | grep rate_limit
```
Envoy access logs will also show
```consul-dataplane {
"response_code_details":"local_rate_limited"
"response_code":429
...
```

## Retries
The `api` service should be running healthy.  
```
./fake-service/web/deploy.sh
./fake-service/api/deploy.sh
```

Lets redeploy api-v2 so it throws 50% errors and verify the service is unstable.
```
kubectl apply -f fake-service/api/errors
./apigw-requests.sh -w .2
```

Enabling retries for the `api` service will allow the proxy to retry failed requests and stabilize the `api` service.  Enable this by configuring a serviceRouter.  This serviceRouter information will be sent to all downstream proxies.
```
kubectl apply -f fake-service/api/init-consul-config/serviceRouter-retries.yaml.enable
./apigw-requests.sh -w .2
```

In another terminal window track the total request retry stats for `web` to see each retry as it happens.
```
while true; do kubectl -n web exec -it deployment/web-v1 -c web -- /usr/bin/curl -s localhost:19000/stats | grep "consul.upstream_rq_retry:"; sleep 1; done
```
Review all retry stats `kubectl -n web exec -it deployment/web-v1 -c web -- /usr/bin/curl -s localhost:19000/stats | grep "consul.upstream_rq_retry"`

### Cleanup
```
kubectl delete -f fake-service/api/init-consul-config/serviceRouter-retries.yaml.enable
```

## Timeouts
![Envoy Timeouts](https://github.com/ppresto/aws-consul-pd/blob/main/request_timeout.png?raw=true)
The request_timeout is a feature of the [Envoy HTTP connection manager (proto) — envoy 1.29.0-dev-cd13b6](https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/filters/network/http_connection_manager/v3/http_connection_manager.proto#envoy-v3-api-field-extensions-filters-network-http-connection-manager-v3-httpconnectionmanager-request-timeout). For a lifecycle of a request, the final timeout is min(A,B,C). When a request has a timeout, the downstream will show an HTTP Status code **504**.  The HTTP request in the Envoy log will have this header `x-envoy-expected-rq-timeout-ms` indicating the time Envoy will wait for its upstream.  There are a few different types of timeouts and ways to configure them.  Here is a brief overview.

| Object | Field | Purpose |
| ---------------- | -------------------- | ---------------------------------------------------------- |
| [ServiceDefaults](https://developer.hashicorp.com/consul/docs/connect/config-entries/service-defaults#localrequesttimeoutms) | LocalRequestTimeoutMs | Specifies the timeout for HTTP requests to the local application instance. Applies to HTTP-based protocols only. |
| [ServiceResolvers](https://developer.hashicorp.com/consul/docs/connect/config-entries/service-resolver#requesttimeout) | RequestTimeout | Specifies the timeout duration for receiving an HTTP response from this service. This will configure Envoy Route to this service with Timeout value|
| [ServiceRouters](https://developer.hashicorp.com/consul/docs/connect/config-entries/service-router#routes-destination-requesttimeout) | RequestTimeout | Specifies the total amount of time permitted for the entire downstream request to be processed, including retry attempts. Configuration wise, this will generate the same Envoy timeout config as the ServiceResolver|
| [ProxyDefaults](https://developer.hashicorp.com/consul/docs/connect/proxies/envoy#proxy-config-options) | local_connect_timeout_ms\n local_request_timeout_ms\n local_idle_timeout_ms | Global settings that affect all proxies are configured here. It's recommended to set timeouts in ServiceDefaults, and ServiceRouters at the service level if possible. These 3 examples show the time permitted to make connections, HTTP requests, and allow idle HTTP time.|

Start with a working environment
```
./fake-service/web/deploy.sh
./fake-service/api/deploy.sh
kubectl apply -f consul-apigw/
```

Deploy an `api-v3` and `payments` service.  `api` makes requests to the new upstream, `payments`. This new service is configured to error 50% of the time with an HTTP 500 status code, and takes 15 seconds or more to process successful requests. 
```
./fake-service/payments/deploy.sh
kubectl delete -f fake-service/api/
kubectl apply -f fake-service/api/api-v3.yaml.enable
```
* Successful requests taking more then 15s will timeout with an HTTP **504** status code because this is greater then the default envoy timeout of 15s.
* `payments` is configured to error ~50% of the time. Unsuccessful requests will respond in ~4 sec with an HTTP 500 status code.

From the `api` container verify upstream requests taking longer then 15s to payments are timing out  and shorter requests (~4s) are returning an HTTP 500.  Run the following command a few times to see the different results.
```
kubectl -n api exec -it deployment/api-v3 -c api -- /usr/bin/curl -s localhost:9091
```
The output shows `payments` returning 500 errors as well as 504 timeouts.  Run this command a couple times to see if the same errors are happening from the `payments` container.

```
kubectl -n payments exec -it deployment/payments-v1 -c payments -- /usr/bin/curl -s localhost:9091
```
`payments` returns successful 200 codes 50% of the time and 500 error codes 50% of the time when tested locally.  Update 2 timeout settings for payments so downstream requests wont timeout and are aware of the additional time requirements.
```
kubectl apply -f fake-service/payments/init-consul-config/servicedefaults-timeout.yaml.enable
kubectl apply -f fake-service/payments/init-consul-config/serviceResolver-timeout.yaml.enable
```


Verify `api` can access `payments`
```
kubectl -n api exec -it deployment/api-v3 -c api -- /usr/bin/curl -s localhost:9091
```

Now verify `web` can access `api` which will call `payments` like before.
```
kubectl -n web exec -it deployment/web-v1 -c web -- /usr/bin/curl -s localhost:9091
```
This will fail because `api` hasn't defined any timeouts telling `web` to wait longer for a request.  Set timeouts for `api` with the following commands and test the workflow again.
```
kubectl apply -f fake-service/api/init-consul-config/servicedefaults-timeout.yaml.enable
kubectl apply -f fake-service/api/init-consul-config/serviceResolver-timeout.yaml.enable
kubectl -n web exec -it deployment/web-v1 -c web -- /usr/bin/curl -s localhost:9091
```
Now requests from `web` should be successful!

Requests from the API GW should fail since it's not aware of the additional timeout requirements.
Update the API Gateway with a RouteTimeoutFilter for path /api
```
kubectl apply -f fake-service/api/init-consul-config/apigw-RouteTimeoutFilter.yaml.enable
```
Test this route.  
```
./apigw-requests.sh -p /api -u "http://payments.payments:9091"
```
Status 500 codes should be returned in ~4s and Status 200 should be seen for the longer 15s requests.

Finally, update both `web` and its API GW routes so everything will work with the new `payments` service.
```
kubectl apply -f fake-service/web/init-consul-config/apigw-RouteTimeoutFilter.yaml.enable
kubectl apply -f fake-service/web/init-consul-config/servicedefaults-timeout.yaml.enable
kubectl apply -f fake-service/web/init-consul-config/serviceResolver-timeout.yaml.enable
```

Verify all services are receiving responses from `payments`
```
./apigw-requests.sh -p /
./apigw-requests.sh -p /api -u "http://payments.payments:9091"
```


### Cleanup
```
kubectl delete -f fake-service/web/init-consul-config/apigw-RouteTimeoutFilter.yaml.enable
kubectl delete -f fake-service/web/init-consul-config/serviceResolver-timeout.yaml.enable
./fake-service/web/deploy.sh -d
kubectl delete -f ./fake-service/api/api-v3.yaml.enable
kubectl delete -f fake-service/api/init-consul-config/apigw-RouteTimeoutFilter.yaml.enable
kubectl delete -f fake-service/api/init-consul-config/serviceResolver-timeout.yaml.enable
./fake-service/api/deploy.sh -d
kubectl delete -f fake-service/payments/init-consul-config/serviceResolver-timeout.yaml.enable
kubectl delete -f ./fake-service/payments/serviceRouter
./fake-service/payments/deploy.sh -d
kubectl delete -f consul-apigw/
```

### Notes
Look at the `api` envoy proxy upstream health status.  
```
kubectl -n api exec -it deployment/api-v3 -c api -- curl -s localhost:19000/clusters | grep health
```
the `payments` upstream may show a `failed_outlier_check` at some times. This means the cluster failed an outlier detection check. An [outlier_detection](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/outlier) is when envoy determines an upstream cluster is not healthy and ejects it from the load balancing set.

```
kubectl -n web exec -it deployment/web-deployment -c web -- curl -s localhost:19000/clusters | grep health
kubectl -n api exec deploy/api-v3 -c api -- curl -s localhost:19000/clusters | grep health
kubectl -n payments exec -it deployment/payments-v1 -c payments -- curl -s localhost:19000/clusters | grep health
```

Get Envoy config_dump for web, api
```
kubectl -n web exec -it deployment/web-deployment -c web -- /usr/bin/curl -s localhost:19000/config_dump | code -
kubectl -n api exec -it deployment/api-v1 -c api -- /usr/bin/curl -s localhost:19000/config_dump | code -
```

API Gateway : /config_dump
```
kubectl debug -it -n consul $(kubectl -n consul get pods -l gateway.consul.hashicorp.com/name=api-gateway --output jsonpath='{.items[0].metadata.name}') --target api-gateway --image nicolaka/netshoot -- curl localhost:19000/config_dump\?include_eds | code -
```

Mesh Gateway : /clusters
```
kubectl debug -it -n consul $(kubectl -n consul get pods -l component=mesh-gateway --output jsonpath='{.items[0].metadata.name}') --target mesh-gateway --image nicolaka/netshoot -- curl localhost:19000/clusters | code -
```

Sameness Groups (usw2)
```
usw2
source ../scripts/setConsul.sh
curl -sk --header "X-Consul-Token: ${CONSUL_HTTP_TOKEN}" "${CONSUL_HTTP_ADDR}"/v1/config/sameness-group | jq

```