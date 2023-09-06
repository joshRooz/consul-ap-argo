.PHONY: login-argocd get-bootstrap-token

login-argocd:
	argocd login localhost:8080 --insecure --username admin --password password

get-bootstrap-token:
	kubectl get secret --context kind-management -n consul consul-bootstrap-acl-token -ojson | jq -r .data.token | base64 -d

