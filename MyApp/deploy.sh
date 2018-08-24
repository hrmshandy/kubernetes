#!/usr/bin/env bash

SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do # resolve $SOURCE until the file is no longer a symlink
  DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE" # if $SOURCE was a relative symlink, we need to resolve it relative to the path where the symlink file was located
done

export DEPLOY_ROOT_DIR="$( cd -P "$( dirname "$SOURCE" )" && pwd )"

# https://gitlab.com/gitlab-examples/kubernetes-deploy/blob/master/src/common.bash
source "$DEPLOY_ROOT_DIR/common.bash"

ensure_environment_url
ensure_deploy_variables
create_kubeconfig

CI_ENVIRONMENT_HOSTNAME="${CI_ENVIRONMENT_URL}"
CI_ENVIRONMENT_HOSTNAME="${CI_ENVIRONMENT_HOSTNAME/http:\/\//}"
CI_ENVIRONMENT_HOSTNAME="${CI_ENVIRONMENT_HOSTNAME/https:\/\//}"

cat <<EOF | kubectl apply -f -
kind: Namespace
apiVersion: v1
metadata:
  name: $KUBE_NAMESPACE
EOF

kubectl create secret -n $KUBE_NAMESPACE \
  docker-registry gitlab-registry \
  --docker-server="$CI_REGISTRY" \
  --docker-username="$CI_REGISTRY_USER" \
  --docker-password="$CI_REGISTRY_PASSWORD" \
  --docker-email="$GITLAB_USER_EMAIL" \
  -o yaml --dry-run | kubectl replace -n $KUBE_NAMESPACE --force -f -

track="${1-stable}"
name="$CI_ENVIRONMENT_SLUG"

if [[ "$track" != "stable" ]]; then
  name="$name-$track"
fi

replicas="1"

env_track="${track^^}"
env_slug="${CI_ENVIRONMENT_SLUG//-/_}"
env_slug="${env_slug^^}"

if [[ "$track" == "stable" ]]; then
  # for stable track get number of replicas from `PRODUCTION_REPLICAS`
  eval new_replicas=\$${env_slug}_REPLICAS
  if [[ -n "$new_replicas" ]]; then
    replicas="$new_replicas"
  fi
else
  # for all tracks get number of replicas from `CANARY_PRODUCTION_REPLICAS`
  eval new_replicas=\$${env_track}_${env_slug}_REPLICAS
  if [[ -n "$new_replicas" ]]; then
    replicas="$new_replicas"
  fi
fi

echo "Deploying $CI_ENVIRONMENT_SLUG (track: $track, replicas: $replicas) with $CI_REGISTRY_IMAGE:$CI_REGISTRY_TAG..."
cat <<EOF | kubectl apply -n $KUBE_NAMESPACE --force -f -
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: $name
  namespace: $KUBE_NAMESPACE
  labels:
    app: $CI_ENVIRONMENT_SLUG
    track: "$track"
    pipeline_id: "$CI_PIPELINE_ID"
    build_id: "$CI_BUILD_ID"
    tier: web
spec:
  replicas: $replicas
  template:
    metadata:
      labels:
        name: $name
        app: $CI_ENVIRONMENT_SLUG
        track: "$track"
        tier: web
    spec:
      imagePullSecrets:
      - name: gitlab-registry
      containers:
      - name: app
        image: $CI_REGISTRY_IMAGE:$CI_REGISTRY_TAG
        imagePullPolicy: Always
        env:
        - name: CI_PIPELINE_ID
          value: "$CI_PIPELINE_ID"
        - name: CI_BUILD_ID
          value: "$CI_BUILD_ID"
        - name: DATABASE_URL
          value: "$DATABASE_URL"
        ports:
        - name: web
          containerPort: 5000
        livenessProbe:
          httpGet:
            path: /
            port: 5000
          initialDelaySeconds: 15
          timeoutSeconds: 15
        readinessProbe:
          httpGet:
            path: /
            port: 5000
          initialDelaySeconds: 5
          timeoutSeconds: 3
---
apiVersion: v1
kind: Service
metadata:
  name: $CI_ENVIRONMENT_SLUG
  namespace: $KUBE_NAMESPACE
  labels:
    app: $CI_ENVIRONMENT_SLUG
    pipeline_id: "$CI_PIPELINE_ID"
    build_id: "$CI_BUILD_ID"
spec:
  ports:
    - name: web
      port: 5000
      targetPort: web
  selector:
    app: $CI_ENVIRONMENT_SLUG
    tier: web
---
apiVersion: extensions/v1beta1
kind: Ingress
metadata:
  name: $CI_ENVIRONMENT_SLUG
  namespace: $KUBE_NAMESPACE
  labels:
    app: $CI_ENVIRONMENT_SLUG
    pipeline_id: "$CI_PIPELINE_ID"
    build_id: "$CI_BUILD_ID"
  annotations:
    kubernetes.io/tls-acme: "true"
    kubernetes.io/ingress.class: "nginx"
spec:
  tls:
  - hosts:
    - $CI_ENVIRONMENT_HOSTNAME
    secretName: ${CI_ENVIRONMENT_SLUG}-tls
  rules:
  - host: $CI_ENVIRONMENT_HOSTNAME
    http:
      paths:
      - path: /
        backend:
          serviceName: $CI_ENVIRONMENT_SLUG
          servicePort: 5000
EOF

echo "Waiting for deployment..."
kubectl rollout status -n "$KUBE_NAMESPACE" -w "deployment/$name"

if [[ "$track" == "stable" ]]; then
  echo "Removing canary deployments (if found)..."
  kubectl delete all,ing -l "app=$CI_ENVIRONMENT_SLUG" -l "track=canary" -n "$KUBE_NAMESPACE"
fi

echo "Application is accessible at: ${CI_ENVIRONMENT_URL}"
echo ""
