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
The request_timeout is a feature of the [Envoy HTTP connection manager (proto) — envoy 1.29.0-dev-cd13b6](https://www.envoyproxy.io/docs/envoy/latest/api-v3/extensions/filters/network/http_connection_manager/v3/http_connection_manager.proto#envoy-v3-api-field-extensions-filters-network-http-connection-manager-v3-httpconnectionmanager-request-timeout). For a lifecycle of a request, the final timeout is min(A,B,C). When a request has a timeout, the downstream will show an HTTP Status code **504**.  The HTTP request in the Envoy log will have this header `x-envoy-expected-rq-timeout-ms` indicating the time Envoy will wait for its upstream.  Certain applications might require more than the default 15-second timeout of Envoy to respond, necessitating a configuration for extended timeouts. Conversely, others could respond in less than 1 second, desiring a shorter timeout so it can fail quickly and retry a healthy instance.  Here is a brief overview of timeouts in Consul.

| Object | Field | Purpose |
| ---------------- | -------------------- | ---------------------------------------------------------- |
| [ServiceDefaults](https://developer.hashicorp.com/consul/docs/connect/config-entries/service-defaults#localrequesttimeoutms) | LocalRequestTimeoutMs | Specifies the timeout for HTTP requests to the local application instance. Applies to HTTP-based protocols only. |
| [ServiceResolvers](https://developer.hashicorp.com/consul/docs/connect/config-entries/service-resolver#requesttimeout) | RequestTimeout | Specifies the timeout duration for receiving an HTTP response from this service. This will configure Envoy Route to this service with Timeout value|
| [ServiceRouters](https://developer.hashicorp.com/consul/docs/connect/config-entries/service-router#routes-destination-requesttimeout) | RequestTimeout | Specifies the total amount of time permitted for the entire downstream request to be processed, including retry attempts. Configuration wise, this will generate the same Envoy timeout config as the ServiceResolver|
| [ProxyDefaults](https://developer.hashicorp.com/consul/docs/connect/proxies/envoy#proxy-config-options) | local_connect_timeout_ms\n local_request_timeout_ms\n local_idle_timeout_ms | Global settings that affect all proxies are configured here. It's recommended to set timeouts in ServiceDefaults, and ServiceRouters at the service level if possible. These 3 examples show the time permitted to make connections, HTTP requests, and allow idle HTTP time.|

The following guide will walk through the setup of an upstream application that requires an extended timeout beyond the defaults set by Envoy.  It will then address timeouts for the downstream applications that consume this upstream service as well as timeouts set in the API gateway routes.  This exercise will address timeouts at every stage of the workflow `[ APIGW -> web -> api -> payments]`

Start with a working environment
```
./fake-service/web/deploy.sh
./fake-service/api/deploy.sh
kubectl apply -f consul-apigw/
```
Wait for the apigw to be resolvable in DNS and then validate access using the browser or script: `./apigw-requests.sh -w 1`


Deploy `api-v3` and `payments` services. `api-v3` makes requests to a new upstream service, `payments`. This new service is configured to error 50% of the time with an HTTP 500 status code, and successful requests will be take more than >15s. 
```
./fake-service/payments/deploy.sh
kubectl delete -f fake-service/api/
kubectl apply -f fake-service/api/api-v3.yaml.enable
```

### Verify local application container is healthy
First, verify the `payments` service container is working as expected.  
```
kubectl -n payments exec -it deployment/payments-v1 -c payments -- /usr/bin/curl -s localhost:9091
```
It should return successful 200 codes after 15s and 500 error codes after 4s.  Note: This was a local application test and didn't use any envoy proxies.

The `api` service is registered to the Consul service mesh so it will have an envoy sidecar proxy.  This means all requests from `api` will route through its envoy sidecar proxy to the target upstream.  `[]` will be used to highlight requests inside the service mesh or in other words using envoy.

### Verify service mesh requests to [payments]
Next, from the `api` container make requests to `[payments]`.  Verify some requests timeout.
* Successful requests > 15s will timeout with an HTTP **504** status code
* Unsuccessful requests will take ~4 sec to respond with an HTTP 500 status code and not timeout.
```
kubectl -n api exec -it deployment/api-v3 -c api -- /usr/bin/curl -s localhost:9091
```
Run the command multiple times to see `payments` HTTP responses (500 Server Error | 504 timeout).

Update 2 timeout settings for `payments` so downstream requests from the `api` (envoy sidecar proxy) wont timeout.
```
kubectl apply -f fake-service/payments/init-consul-config/servicedefaults-timeout.yaml.enable
kubectl apply -f fake-service/payments/init-consul-config/serviceResolver-timeout.yaml.enable
```

Now `api` should be able to access `[payments]` successfully 50% of the time.  Run the following command multiple times and look for the response codes (500 Server Error | 200 Success).
```
kubectl -n api exec -it deployment/api-v3 -c api -- /usr/bin/curl -s localhost:9091
```
When testing from the `api` container the service mesh is only used for the upstream call to `[payments]`.

### Verify service mesh requests to [api->payments]
`api` requests to `[payments]` were just validated above so move to the next downstream service `web`.  Verify `web` can access `[api]` by making requests from the `web` container.  Note, when making requests from the `web` container the service mesh will now be used for  upstreams `[api->payments]`.
```
kubectl -n web exec -it deployment/web-v1 -c web -- /usr/bin/curl -s localhost:9091
```
This should timeout because `api` hasn't defined any timeouts telling the `web` services proxy to wait longer for a response.  Set timeouts for `api` with the following commands to tell its downstream's like `web` to wait longer than the default timeout 15s.  Run the last command a couple times to verify HTTP status codes returned are 500 and 200 now.  No more 504 timeouts.
```
kubectl apply -f fake-service/api/init-consul-config/servicedefaults-timeout.yaml.enable
kubectl apply -f fake-service/api/init-consul-config/serviceResolver-timeout.yaml.enable
kubectl -n web exec -it deployment/web-v1 -c web -- /usr/bin/curl -s localhost:9091
```
When sending `api` requests to `[payments]` from the local container it worked, but when using `web` to test requests to `[api->payments]` next it failed until `api` was configured with the proper timeouts.  When inside the `api` container its envoy sidecar proxy is only used for the upstream call to `[payments]` so the service mesh is not yet testing the full path `[api->payments]`. When requests are sent from the `web` container its envoy proxy is now sending requests to `[api->payments]` and the `api` service timeouts need to be properly defined.  

### Verify service mesh requests to [web->api->payments]
Other downstream services in the mesh (like the API Gateway) might be calling `web` so to support `[web->api->payments]` remember to set timeouts for `web` too.
```
kubectl apply -f fake-service/web/init-consul-config/servicedefaults-timeout.yaml.enable
kubectl apply -f fake-service/web/init-consul-config/serviceResolver-timeout.yaml.enable
```

### Verify external requests to [APIGateway->web->api->payments]
All requests from within the service mesh (`[web->api->payments]`) should be working with updated timeouts, but what about external requests using the API Gateway? The API GW is not aware of any timeout requirements. Think of it as another downstream service that needs to be configured.  It has routes to both `web` and `api`.
* http-route: /    - `[APIGW->web->api->payments]`
* http-route: /api -`[APIGW->api->payments]`

Update the API Gateway with a RouteTimeoutFilter for every http-route that needs more time. Both routes for `web` and `api` will eventually connect to the `payments` upstream so they require a RouteTimeoutFilter.
```
kubectl apply -f fake-service/web/init-consul-config/apigw-RouteTimeoutFilter.yaml.enable
kubectl apply -f fake-service/api/init-consul-config/apigw-RouteTimeoutFilter.yaml.enable
```

Test API Gateway http-routes using the browser or the following script.
```
./apigw-requests.sh -p /
./apigw-requests.sh -p /api -u "http://payments.payments:9091"
```
This is validating the full end to end request flow.  Payments is configured to return 500 Server errors 50% of the time in 4s.  The other responses should be successful 200 status codes taking >15s to process.

### Configure Retries to eliminate 500 Server Errors from `payments`
Use a serviceRouter to configure retries.  Configure any timeout requirements inside the serviceRouter using `requestTimeout`. 
```
spec:
  routes:
    - match:
        http:
          pathPrefix: /
      destination:
        requestTimeout: 45000ms  #total time permitted for the entire downstream request to be processed, including retry attempts.
        numRetries: 3
        retryOnConnectFailure: true
        retryOn: ['reset','connect-failure','refused-stream','unavailable','cancelled','retriable-4xx','5xx','gateway-error']
```
If requests average 15s and the number of desired retries is 3 set `requestTimeout` to 45s or more.

Apply retries to `payments` and verify all requests now are returning successful 200.
```
kubectl apply -f fake-service/payments/init-consul-config/serviceRouter-retries.yaml.enable
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
kubectl delete -f fake-service/payments/init-consul-config/serviceRouter-retries.yaml.enable
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