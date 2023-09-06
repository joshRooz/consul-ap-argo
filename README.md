# Consul Enterprise - Admin Partitons with ArgoCD Application Sets

For the purposes of demonstration and testing - deploys Consul Enterprise in KinD using ArgoCD. An `ApplicationSet` deploys Consul to three additional KinD clusters as Admin Partitions.

> **Faux GitOps** All configuration is specified through the CLI to minimize the deployment requirements - intending to emulate the GitOps workflow just enough to surface areas of focus.



*BYO Enterprise License (expected path: `license/consul.hclic`)*

