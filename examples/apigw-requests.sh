#!/bin/bash

export UPSTREAM="http://api.virtual.api.ns.consul:9091"
export APIGW_URL="$(kubectl get services --namespace=consul api-gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')"
export URL_PATH="/"
export WAIT_TIME=1

downstream_requests() {
    echo "Consul APIGW - http://${APIGW_URL}${URL_PATH} , sending reqs to - ${UPSTREAM}"
    for i in {1..500}; do 
    #    curl -s -L http://${APIGW_URL}${URL_PATH} | jq -r ".upstream_calls.\"${UPSTREAM}\" | \"\(.name), \(.code), \(.duration)\""
       TEMP=$(time curl -s -L http://${APIGW_URL}${URL_PATH})
       #TEMP=$(curl -s -L http://${APIGW_URL}${URL_PATH})
       if $(echo ${TEMP} | jq -e >/dev/null 2>&1); then
          echo ${TEMP} | jq -r ".upstream_calls.\"${UPSTREAM}\" | \"\(.name), \(.code), \(.duration)\""
       else
          REAL_TIME=$(echo ${TEMP} | grep real | awk '{print $2}')
          echo "${TEMP}"
       fi 
       sleep ${WAIT_TIME};
    done
}

# Sending directly to upstream (JSON output will have no upstream_calls defined)
upstream_requests() {
    echo "Consul APIGW - http://${APIGW_URL}${URL_PATH} , sending reqs to - ${UPSTREAM}"
    for i in {1..500}; do 
        curl -s -L http://${APIGW_URL}${URL_PATH}  | jq -r ".| \"\(.name),\(.code)\""
       sleep ${WAIT_TIME};
    done
}

while getopts "h:p:w:u:" o; do
    case "${o}" in
        h)
            export APIGW_URL="${OPTARG}"
            ;;
        p)
            export URL_PATH="${OPTARG}"
            ;;
        w)
            export WAIT_TIME="${OPTARG}"
            ;;
        u)
            export UPSTREAM="${OPTARG}"
            ;;
        *)
            usage
            ;;
    esac
done
shift $((OPTIND-1))

downstream_requests