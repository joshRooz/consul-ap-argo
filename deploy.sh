#!/usr/bin/env bash
set -x

# BEGIN: deploy management cluster
kind create cluster --name=argocd --config=- <<EOY
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
- role: worker
- role: worker
  labels:
    targeted-by: consul-k8s
EOY

# BEGIN: deploy and configure argo cd
kubectl create ns argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# ignore -> jq: error (at <stdin>:19): Cannot iterate over null (null)
until [[ $(kubectl get -n argocd ep argocd-server  -ojson | jq '.subsets[] | length // 0' 2>/dev/null) -gt 0 ]] ; do sleep 2 ; done
nohup kubectl port-forward svc/argocd-server -n argocd 8080:443 &>/tmp/argocd.out & disown
until nc -z localhost 8080 ; do sleep 2 ; done

argocd login localhost:8080 --name argoctx \
--insecure \
--username admin \
--password "$(kubectl get secrets -n argocd argocd-initial-admin-secret -ojson | jq -r .data.password | base64 -d)"

argocd account update-password \
--server localhost:8080 \
--insecure \
--account admin \
--current-password "$(kubectl get secrets -n argocd argocd-initial-admin-secret -ojson | jq -r .data.password | base64 -d)" \
--new-password password

kubectl delete secret -n argocd argocd-initial-admin-secret

# BEGIN: add management cluster
# performed automatically for in-cluster
#argocd cluster add kind-argocd --in-cluster --yes # this performed automatically for in-cluster

# BEGIN: create an argo project - aka AppProj CRD
#####--source-namespaces consul \
argocd proj create consul \
--description "HashiCorp Consul" \
--src https://helm.releases.hashicorp.com \
--dest https://kubernetes.default.svc,consul \
--dest https://argocd-target-control-plane:6443,consul \
--allow-cluster-resource /Namespace \
--allow-cluster-resource rbac.authorization.k8s.io/ClusterRole \
--allow-cluster-resource rbac.authorization.k8s.io/ClusterRoleBinding \
--allow-cluster-resource rbac.authorization.k8s.io/ClusterRoleBinding \
--allow-cluster-resource apiextensions.k8s.io/CustomResourceDefinition \
--allow-cluster-resource admissionregistration.k8s.io/MutatingWebhookConfiguration \
--deny-namespaced-resource /LimitRange \
--deny-namespaced-resource /NetworkPolicy \
--deny-namespaced-resource /ResourceQuota \
--orphaned-resources

argocd proj role create consul read-only --description "Read-only Access to Consul"
argocd proj role add-policy consul read-only \
--object "*" \
--action  get \
--permission allow 
argocd proj role add-group consul read-only consul


# BEGIN: deploy consul w/ server plane
# in practice: reference secrets mgmt options - https://argo-cd.readthedocs.io/en/stable/operator-manual/secret-management/
kubectl create namespace consul 
kubectl create secret generic consul-license --namespace consul  --from-file=consul.hclic=license/consul.hclic

# in practice: values in git, but less moving parts for throwaway env
# consider templating helm in the repo as well - example: argo hook annotations can be more granularly applied (ie: job vs pod spec template provided by the chart)
argocd app create consul \
--project consul \
--dest-server https://kubernetes.default.svc \
--dest-namespace consul \
--repo https://helm.releases.hashicorp.com \
--helm-chart consul \
--revision 1.2.1 \
--sync-policy automated \
--sync-option CreateNamespace=true \
--self-heal \
--auto-prune \
--helm-set global.logLevel=debug \
--helm-set global.name=consul \
--helm-set global.adminPartitions.enabled=true \
--helm-set global.image=hashicorp/consul-enterprise:1.16.1-ent \
--helm-set global.gossipEncryption.autoGenerate=true \
--helm-set global.tls.enabled=true \
--helm-set global.enableConsulNamespaces=true \
--helm-set global.acls.manageSystemACLs=true \
--helm-set "global.acls.nodeSelector=targeted-by: consul-k8s" \
--helm-set "global.acls.annotations=argocd\.argoproj\.io\/hook: PostSync
argocd\.argoproj\.io\/hook-delete-policy: HookSucceeded" \
--helm-set global.enterpriseLicense.secretName=consul-license \
--helm-set global.enterpriseLicense.secretKey=consul.hclic \
--helm-set server.replicas=1 \
--helm-set "server.nodeSelector=targeted-by: consul-k8s" \
--helm-set server.exposeService.type=NodePort \
--helm-set server.exposeService.nodePort.https=32767 \
--helm-set server.exposeService.nodePort.grpc=32766 \
--helm-set connectInject.apiGateway.managedGatewayClass.serviceType=ClusterIP \
--helm-set "webhookCertManager.nodeselector=targeted-by: consul-k8s"

until [[ $(kubectl get -n consul ep consul-ui  -ojson | jq '.subsets[] | length // 0' 2>/dev/null) -gt 0 ]] ; do sleep 2 ; done
nohup kubectl port-forward svc/consul-ui -n consul 8501:443 &>/tmp/consul-ui.out & disown

#-------------------------------------------------
# BEGIN: deploying other cluster(s)
kind create cluster --name=argocd-target --config=- <<EOY
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
EOY

# BEGIN: add the new cluster to argo
# create ->
#   INFO[0001] ServiceAccount "argocd-manager" created in namespace "kube-system" 
#   INFO[0001] ClusterRole "argocd-manager-role" created    
#   INFO[0001] ClusterRoleBinding "argocd-manager-role-binding" created 
#   INFO[0006] Created bearer token secret for ServiceAccount "argocd-manager" 
argocd cluster add kind-argocd-target --name argocd-target --yes
# fix ->
#   FATA[0006] rpc error: code = Unknown desc = Get "https://127.0.0.1:<ephem-port>/version?timeout=32s": dial tcp 127.0.0.1:<ephem-port>: connect: connection refused 
kubectl apply --context kind-argocd --namespace argocd -f - <<EOY
apiVersion: v1
kind: Secret
metadata:
  name: argocd-target
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: argocd-target
  server: https://argocd-target-control-plane:6443
  config: |
    {
      "bearerToken": "$(kubectl get secret --context kind-argocd-target -n kube-system -ojsonpath='{.items[?(@.metadata.annotations.kubernetes\.io/service-account\.name=="argocd-manager")].data.token}' | base64 -d)",
      "tlsClientConfig": {
        "insecure": false,
        "caData": "$(kubectl get secret --context kind-argocd-target -n kube-system -ojsonpath='{.items[?(@.metadata.annotations.kubernetes\.io/service-account\.name=="argocd-manager")].data.ca\.crt}')"
      }
    }
EOY

# BEGIN: consul admin partition secrets 
# see secrets management note above
kubectl create namespace consul --context kind-argocd-target
#kubectl create secret generic consul-license --context kind-argocd-target --namespace consul  --from-file=consul.hclic=license/consul.hclic # is this actually required?
kubectl get secret --context kind-argocd --namespace consul  consul-ca-cert -ojson | jq -r '.data."tls.crt"' | base64 -d -o tls.crt
kubectl create secret generic consul-ca-cert --context kind-argocd-target --namespace consul --from-file="tls.crt=tls.crt" # decode/reencode. ugh.
rm tls.crt

# in practice: generate an acl token for the partition to perform bootstrap activities
# determine least privileged token policy to permission consul-k8s-control-plane effectively
kubectl get secret --context kind-argocd --namespace consul  consul-bootstrap-acl-token -ojson | jq -r .data.token | base64 -d |
  xargs -I {} kubectl create secret generic consul-partition-acl-token --context kind-argocd-target --namespace consul --from-literal="token={}" # decode/reencode. ugh.


# add mesh gateway
#--sync-policy automated \  line above sync-option
#--self-heal \ line beneath sync-option
#--auto-prune \ line beneath self-heal
argocd app create consul-ap \
--project consul \
--dest-server https://argocd-target-control-plane:6443 \
--dest-namespace consul \
--repo https://helm.releases.hashicorp.com \
--helm-chart consul \
--revision 1.2.1 \
--sync-option CreateNamespace=true \
--helm-set global.enabled=false \
--helm-set global.logLevel=debug \
--helm-set global.name=consul \
--helm-set global.adminPartitions.enabled=true \
--helm-set global.adminPartitions.name=tgt01 \
--helm-set global.image=hashicorp/consul-enterprise:1.16.1-ent \
--helm-set global.tls.enabled=true \
--helm-set global.tls.caCert.secretName=consul-ca-cert \
--helm-set global.tls.caCert.secretKey=tls.crt \
--helm-set global.enableConsulNamespaces=true \
--helm-set global.acls.manageSystemACLs=true \
--helm-set global.acls.bootstrapToken.secretName=consul-partition-acl-token \
--helm-set global.acls.bootstrapToken.secretKey=token \
--helm-set "global.acls.annotations=argocd\.argoproj\.io\/hook: PostSync
argocd\.argoproj\.io\/hook-delete-policy: HookSucceeded" \
--helm-set global.enterpriseLicense.secretName=consul-license \
--helm-set global.enterpriseLicense.secretKey=consul.hclic \
--helm-set externalServers.enabled=true \
--helm-set externalServers.hosts[0]=argocd-worker3 \
--helm-set externalServers.httpsPort=32767 \
--helm-set externalServers.grpcPort=32766 \
--helm-set externalServers.tlsServerName=server.dc1.consul \
--helm-set externalServers.k8sAuthMethodHost=https://argocd-target-control-plane:6443 \
--helm-set connectInject.apiGateway.managedGatewayClass.serviceType=ClusterIP \
--helm-set connectInject.default=true \
--helm-set meshGateway.enabled=true \
--helm-set meshGateway.service.type=ClusterIP 
#--helm-set meshGateway.wanAddress.source=NodeIP \
#--helm-set meshGateway.service.type=HostPort \
#--helm-set meshGateway.service.hostPort=8443



#--helm-set externalServers.useSystemRoots=true \


# deploy the demo app to the project aka App CRD
#argocd app create guestbook \
#--repo https://github.com/argoproj/argocd-example-apps.git \
#--path guestbook \
#--sync-policy automated \
#--sync-option CreateNamespace=true \
#--self-heal \
#--auto-prune \
#--dest-server https://kubernetes.default.svc \
#--dest-namespace guestbook