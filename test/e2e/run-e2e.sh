#!/bin/bash -e

script_path="$(dirname -- "${BASH_SOURCE[0]}")"

main() {
    echo "Running E2E tests" >&2
    # shellcheck disable=SC1091
    source "${script_path}/vars.sh"

    local github_org="${GH_ORG:?A GitHub org where the https://github.com/redhat-appstudio-qe/konflux-ci-sample repo is present/forked should be provided}"
    local github_token="${GH_TOKEN:?A GitHub token should be provided}"
    local quay_dockerconfig="${QUAY_DOCKERCONFIGJSON:?quay.io credentials in .dockerconfig format should be provided}"
    local catalog_revision="${RELEASE_SERVICE_CATALOG_REVISION:?RELEASE_SERVICE_CATALOG_REVISION must be set in vars.sh or env}"
    local release_catalog_ta_quay_token="${RELEASE_CATALOG_TA_QUAY_TOKEN:-}"

    # Generate proxy kubeconfig
    local proxy_kubeconfig="${script_path}/proxy.kubeconfig"
    "${script_path}/gen-proxy-config.sh" "$proxy_kubeconfig"

    # Extract CA cert from kubeconfig and inject it as a trusted system CA 
    # to fix "x509: certificate signed by unknown authority" errors in E2E runtime
    local ca_cert_path="${script_path}/proxy-ca.crt"
    # Get CA cert and decode base64, save to proxy-ca.crt
    kubectl config view -f "$proxy_kubeconfig" --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > "$ca_cert_path" || touch "$ca_cert_path"

    docker run \
        --network=host \
        -v "${proxy_kubeconfig}:/kube/config" \
        -v "${ca_cert_path}:/etc/pki/ca-trust/source/anchors/proxy-ca.crt" \
        --env KUBECONFIG=/kube/config \
        -e GITHUB_TOKEN="$github_token" \
        -e QUAY_TOKEN="$(base64 <<< "$quay_dockerconfig")" \
        -e MY_GITHUB_ORG="$github_org" \
        -e E2E_APPLICATIONS_NAMESPACE=user-ns2 \
        -e TEST_ENVIRONMENT=upstream \
        -e RELEASE_SERVICE_CATALOG_REVISION="$catalog_revision" \
        -e RELEASE_CATALOG_TA_QUAY_TOKEN="$release_catalog_ta_quay_token" \
        --user 0 \
        "$E2E_TEST_IMAGE" \
        /bin/bash -c "update-ca-trust && ginkgo -v --label-filter=upstream-konflux --focus=\"Test local\" /konflux-e2e/konflux-e2e.test"
}


if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
