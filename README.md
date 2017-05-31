# meta-azure-service-broker-helm

This repository contains charts and instructions for a demo of 
[service-catalog](https://github.com/kubernetes-incubator/service-catalog)
with the 
[Azure Meta Service Broker](https://github.com/Azure/meta-azure-service-broker)

# Prereqs

- Start a cluster as normal
- Make sure you are using Helm v2.4.2 or newer. These charts utilize a brand new Helm feature.
- Initialize Helm/Tiller as normal (helm init)

# Installing Service-Catalog

First, check out the service-catalog repository and `cd` into the repository directory:

```console
git clone https://github.com/kubernetes-incubator/service-catalog.git
cd service-catalog
```

Next, use Helm to install it:

```console
helm install charts/catalog --name catalog --namespace catalog --set apiserver.service.type=LoadBalancer
```

(notice the `apiserver.service.type=LoadBalancer`. I am doing this so that the `Service` for the service-catalog API server gets a public IP on the ACS cluster)

Next, get the IP of the service, under the `EXTERNAL-IP` column, and assign that value to `SVC_CAT_API_SERVER_IP`:

```console
kubectl get svc -n catalog
export SVC_CAT_API_SERVER_IP=<EXTERNAL-IP>
```

Next, set up a `kubectl` context to communicate with the service-catalog API server:

```console
kubectl config set-cluster service-catalog --server=http://$SVC_CAT_API_SERVER_IP:30080
kubectl config set-context service-catalog --cluster=service-catalog
```

# Create a Service Principal


This content is copied from https://gist.github.com/krancour/98a3e4a1e1000b7dbe0373f223706b68#create-a-service-principal

It is necessary to create a service principal (this is ActiveDirectory speak for "service account") having adequate permission to provision services into your Azure subscription.

```console
export SUB_ID=<subscriptionId>
az account set --subscription $SUB_ID
az ad sp create-for-rbac \
    --role="Contributor" --scopes="/subscriptions/$SUB_ID"
```


You will see output similar to the following:


```json
{
  "appId": "039dda10-fccc-4293-96d5-2535da19b9a7",
  "displayName": "azure-cli-2017-05-19-19-21-21",
  "name": "http://azure-cli-2017-05-19-19-21-21",
  "password": "<redacted>",
  "tenant": "72f988bf-86f1-41af-91ab-2d7cd011db47"
}
```

For convenience, save these as environment variables because you'll need them later.

```console
$ export TENANT_ID=<tenant>
$ export CLIENT_ID=<appId>
$ export CLIENT_SECRET=<password>
```

# Install the Meta Azure Service Broker

There are helm charts in this repository for the 
[Azure meta service broker](https://github.com/Azure/meta-azure-service-broker). To install it,
simply run the following command:

```console
helm install charts/meta-azure-service-broker \
    --name masb \
    --namespace masb \
    --set azure.subscriptionId=$SUB_ID,azure.tenantId=$TENANT_ID,azure.clientId=$CLIENT_ID,azure.clientSecret=$CLIENT_SECRET,sql-server.acceptLicense=true
```

This command starts up a pod running SQL Server and a pod running the Azure service broker. SQL 
server takes a few minutes to start up completely, and the broker contains an init container
that waits for it to be available, so the complete system will take some time to be completely
available.

# Register the Broker with Service Catalog

Service Catalog looks for `Broker` resources in Kubernetes to point it to a new broker server. After
it sees one, it makes a request to the broker server to fetch its catalog. This repository has a
`masb-broker.yaml` file in the `resources/` directory that specifies the `Broker` for the Azure 
broker we just started in the cluster (note that the broker just needs to be accessible over
HTTP. It doesn't need to be created in the cluster.)

To create this `Broker` resource, run the following `kubectl` command:

```console
kubectl --context service-catalog create -f resources/masb-broker.yaml
```

