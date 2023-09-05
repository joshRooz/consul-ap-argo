.PHONY: get-bootstrap-token

get-bootstrap-token:
	kubectl get secret --context kind-argocd -n consul consul-bootstrap-acl-token -ojson | jq -r .data.token | base64 -d

