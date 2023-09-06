#!/usr/bin/env bash
set -x

# these processes should die. be proactive anyway
ps -p $(pgrep kubectl) | awk '/port-forward svc\/argocd-server/ {print $1}' | xargs kill
ps -p $(pgrep kubectl) | awk '/port-forward svc\/consul-ui/ {print $1}' | xargs kill

kind delete cluster --name=management
kind delete cluster --name=foo
kind delete cluster --name=bar
kind delete cluster --name=baz

exit 0
