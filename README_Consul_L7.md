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

Validate `api` services (v1, v2) are deployed, healthy, and returning 200 Status codes every request.
```
cd ./examples
./apigw-requests.sh -w .4
```

`web` is routing to multiple `api` deployments (v1, v2). Redeploy v2 with the configuration below so it fails 30% of the time with HTTP Status 500.
```
kubectl apply -f fake-service/api/api-v2-http_error_30.yaml.test
./apigw-requests.sh -w 1
```
Now `web` is experiencing many intermittent failures
Configure `web` servicedefaults with limits and passiveHealthChecks to enable circuit breaking for its upstreams. 
```
kubectl apply -f fake-service/web/init-consul-config/servicedefaults-circuitbreaker.yaml.test
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

Below is a simple shell script that uses curl to send requests to the Consul APIGW and returns the service name and HTTP code. Send 5 reqs/sec to / (or 1 request every .2 seconds)
```
# Usage: ./apigw-requests.sh -w [Sleep wait time] -p [URI Path]
./apigw-requests.sh -w .2 -p /
```
All requests to / should respond with an HTTP 200 code

Now send 5 reqs/sec to the rate limited path. Requests to /api-v2 should return an HTTP 429 anytime there is more then 1 req/sec. 
```
./apigw-requests.sh -w .2 -p /api-v2
```

Verify the number of rate limited requests `web` received using envoy stats `consul.external.upstream_rq_429`
```
kubectl -n web exec -it deployment/web-deployment -c web -- /usr/bin/curl -s localhost:19000/stats | grep consul.external.upstream_rq_429
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

Lets redeploy api-v2 so it throws 30% errors and verify the service is unstable.
```
kubectl apply -f fake-service/api/api-v2-http_error_30.yaml.test
./apigw-requests.sh -w .2
```

Enabling retries for the `api` service will allow the proxy to retry failed requests and stabilize the `api` service.  Enable this by configuring a serviceRouter.  This serviceRouter information will be sent to all downstream proxies.
```
kubectl apply -f fake-service/api/init-consul-config/serviceRouter-retries.yaml.test
./apigw-requests.sh -w .2
```

Get total request retry stats for `web`
```
while true; do kubectl -n web exec -it deployment/web-deployment -c web -- /usr/bin/curl -s localhost:19000/stats | grep "consul.upstream_rq_retry:"; sleep 1; done
```
Review all retry stats `kubectl -n web exec -it deployment/web-deployment -c web -- /usr/bin/curl -s localhost:19000/stats | grep "consul.upstream_rq_retry"`

Get Envoy config_dump
```
kubectl -n web exec -it deployment/web-deployment -c web -- /usr/bin/curl -s localhost:19000/config_dump | code -
kubectl -n api exec -it deployment/api-v1 -c api -- /usr/bin/curl -s localhost:19000/config_dump | code -
```
### Cleanup
```
kubectl delete -f fake-service/api/init-consul-config/serviceRouter-retries.yaml.test
```

## Timeouts
![Envoy Timeouts](https://github.com/ppresto/aws-consul-pg/blob/main/request_timeout.png?raw=true)
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
```

Deploy a modified api-v2 that has a p50 latency of **1000ms**.  This version of api-v2 should take 1 sec to respond and everything should return a status code 200.
```
kubectl apply -f fake-service/api/api-v2-latency_1sec.yaml.test
./apigw-requests.sh -w 1
```

Deploy `payments`.  payments includes api-v3 which is a new version of the `api` service that has the same p50 latency of **1000ms** and also makes requests to the new upstream, `payments`.  api-v3 has a p50 latency of **1000ms**. Any request to api-v3 should timeout with a **504** status code because this instance takes 1000ms to respond which is greater then the `localRequestTimeoutMs: 900` being set in the `api` serviceDefaults `./fake-service/payments/init-consul-config/servicedefaults-localRequestTimeoutMs900.yaml`.

```
kubectl apply -f fake-service/api/api-v3_to_payments.yaml.test
./fake-service/payments/deploy.sh
sleep 5
./apigw-requests.sh -w 1
```

Update the ServiceDefaults for `api` to allow 2 seconds for local application requests.  Setting `localRequestTimeoutMs: 2000` should be more then enough to support the 1 second needed for api-v3.
```
kubectl apply -f fake-service/payments/init-consul-config/servicedefaults-localRequestTimeoutMs2000.yaml.test

```

Look at the envoy proxy upstream health status for `web`.  
```
kubectl -n web exec -it deployment/web-deployment -c web -- curl -s localhost:19000/clusters | grep health
```
the `api` service may show a `failed_outlier_check`. This means the cluster failed an outlier detection check. An [outlier_detection](https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/upstream/outlier) is when envoy determines an upstream cluster is not healthy and ejects it from the load balancing set.  When an application is timing out it can be detected and removed.


Setting `LocalRequestTimeoutMs` in the ServiceDefault manages timeouts for the local service only. Setting `RequestTimeout` in a ServiceRouter defines the total amount of time to complete a downstream request which can include multiple upstreams and retries.  Cleanup api-v2, and deploy the new api-v3 with the upstream app called `payments`.  This will set the RequestTimeout for `api` to 5 seconds to complete the entire downstream request. 
```
./fake-service/api/deploy.sh
./fake-service/payments/deploy.sh
./apigw-requests.sh -w .2
```


```
kubectl -n web exec -it deployment/web-deployment -c web -- curl -s localhost:19000/clusters | grep health
kubectl -n api exec deploy/api-v3 -c api -- curl -s localhost:19000/clusters | grep health
kubectl -n payments exec -it deployment/payments-v1 -c payments -- curl -s localhost:19000/clusters | grep health
```