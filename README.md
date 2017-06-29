# meta-azure-service-broker-helm

This repository contains charts and instructions for a demo of 
[service-catalog](https://github.com/kubernetes-incubator/service-catalog)
with the 
[Azure Meta Service Broker](https://github.com/Azure/meta-azure-service-broker).

It currently shows how to install and set up Service Catalog and the Azure broker, and how
to provision and bind to [Azure Redis](https://azure.microsoft.com/en-us/services/cache/)
and [Azure Postgres](https://azure.microsoft.com/en-us/services/postgresql/) services.

Note that the instructions herein don't necessarily reflect a production-quality installation, but
they should get you started down that path. They also assume you are using a Kubernetes cluster in a cloud. They have been tested with [Azure Container Service](https://azure.microsoft.com/en-us/services/container-service/).

# Prereqs

- Start a cluster as normal
- Make sure you are using Helm v2.4.2 or newer. These charts utilize a feature that's only available
as of that version
- Initialize Helm/Tiller as normal (helm init)

# Installing Service-Catalog

First, check out the service-catalog repository and `cd` into the repository directory:

```console
git clone https://github.com/kubernetes-incubator/service-catalog.git
cd service-catalog
```

Next, use Helm to install it:

```console
helm install charts/catalog --name catalog --namespace catalog --set apiserver.service.type=LoadBalancer,apiserver.storage.type=tpr
```

(notice the `apiserver.service.type=LoadBalancer`. I am doing this so that the `Service` for the service-catalog API server gets a public IP on the ACS cluster)

Next, get the IP of the service, under the `EXTERNAL-IP` column, and assign that value to `SVC_CAT_API_SERVER_IP`:

```console
kubectl get svc -n catalog
export SVC_CAT_API_SERVER_IP=<EXTERNAL-IP>
```

Next, set up a `kubectl` context to communicate with the service-catalog API server:

```console
kubectl config set-cluster service-catalog --server=http://$SVC_CAT_API_SERVER_IP:80
kubectl config set-context service-catalog --cluster=service-catalog
```

# Create a Service Principal


This content is copied from https://gist.github.com/krancour/98a3e4a1e1000b7dbe0373f223706b68#create-a-service-principal

It is necessary to create a service principal (this is ActiveDirectory speak for "service account") 
having adequate permission to provision services into your Azure subscription.

Get the subscription ID by running `az account list` and selecting the `"id"` field from the 
account that you'd like to use for this demo.

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

Finally, register the subscription to use the Redis service:

```console
az provider register -n Microsoft.Cache
az provider register -n Microsoft.DBforPostgreSQL
```

After that runs, you'll see the following output:

```console
Registering is still on-going. You can monitor using 'az provider show -n Microsoft.Cache'
```

Run the following commands until you see `registrationState: "Registered"` under both:

```console
az provider show -n Microsoft.Cache -o table
az provider show -n Microsoft.DBforPostgreSQL -o table
```

# Install the Meta Azure Service Broker

There are helm charts in this repository for the 
[Azure meta service broker](https://github.com/Azure/meta-azure-service-broker). To install it,
simply run the following command from the root of this repository:

```console
helm install charts/meta-azure-service-broker \
    --name masb \
    --namespace masb \
    --set azure.subscriptionId=$SUB_ID,azure.tenantId=$TENANT_ID,azure.clientId=$CLIENT_ID,azure.clientSecret=$CLIENT_SECRET,sql-server.acceptLicense=true,sql-server.persistence.enabled=false
```

This command starts up a pod running SQL Server and a pod running the Azure service broker. SQL 
server takes a few minutes to start up completely, and the broker contains an init container
that waits for it to be available, so the complete system will take some time to be completely
available.

# Register the Broker with Service Catalog

Service Catalog looks for `Broker` resources in Kubernetes to point it to a new broker server. After
it sees one, it makes a request to the broker server to fetch its catalog. This repository has a
`masb-broker.yaml` file in the `resources/` directory that specifies the `Broker` for the Azure 
broker we just started in the cluster.

To create this `Broker` resource, run the following `kubectl` command:

```console
kubectl --context service-catalog create -f resources/masb-broker.yaml
```

(Note: we are running our broker in the same cluster as the service-catalog, but in general, 
brokers can run anywhere as long as they're accessible over HTTP)

# View Service Classes

After the `Broker` is submitted, Service Catalog will fetch all of the services and plans
that the Azure meta service broker provides. It will then convert these services and plans
into `ServiceClass` resources in Kubernetes and store them. After they're stored, they are in the 
catalog of services.

This entire process happens automatically, so a few seconds after you create the `Broker`, the
catalog will be populated. Run the following command after you create the `Broker` to see the 
catalog:

```console
kubectl --context=service-catalog get serviceclass
```

You should output similar to the following:

```console
NAME               KIND                                          BINDABLE   BROKER NAME   DESCRIPTION
azure-documentdb   ServiceClass.v1alpha1.servicecatalog.k8s.io   true       masb          Azure DocumentDb Service
azure-postgresqldb   ServiceClass.v1alpha1.servicecatalog.k8s.io   3 item(s)   true      masb
azure-rediscache   ServiceClass.v1alpha1.servicecatalog.k8s.io   true      masb      Azure Redis Cache Service
azure-servicebus   ServiceClass.v1alpha1.servicecatalog.k8s.io   2 item(s)   true      masb
azure-sqldb   ServiceClass.v1alpha1.servicecatalog.k8s.io   true      masb      Azure SQL Database Service
azure-storage   ServiceClass.v1alpha1.servicecatalog.k8s.io   2 item(s)   true      masb
```

# Provision a New Service

After `ServieClass`es are listed in the catalog, you can provision instances of them. Conveniently,
you submit an `Instance` resource to the Service Catalog API server in order to provision a service.

Unlike `Broker`s and `ServiceClass`es above, `Instance`s are namespaced, so we'll have to create
a new Kubernetes namespace for them. Do so with this command:

```console
kubectl create ns testing
```

After you've created the namespace, you can create the `Instance` for the service that you'd
like to provision. This repository provides the following manifests for `Instance`s:

- `resources/redis-instance.yaml`
- `resources/postgres-instance.yaml`

To provision a Redis instance, for example, run this command:

```console
kubectl --context=service-catalog create -f resources/redis-instance.yaml
```

Next, view the newly created Redis `Instance` with this command:

```console
kubectl get instance --context=service-catalog -o yaml -n testing my-redis
```

A large amount of YAML will be output, but the important bits are under the
`status.conditions[0]` field (near the bottom).

Since the Azure redis service takes a few minutes to create new caches, the Azure broker provisions
 them asynchronously. As a result, you'll see the following under the first condition:

```yaml
message: The instance is being provisioned asynchronously
reason: Provisioning
status: "False"
type: Ready
```

Wait until the `reason` field reads `ProvisionedSuccessfully` and the `status` field
reads `"True"` before moving on to the next step.

You should see similar behavior for Azure Postgres.

# Bind to the new Instance

Our last step is to bind to the instance. In doing so, service-catalog will get back some
credentials that it will write into a `Secret`.

Since we provisioned Redis in the previous section, we'll bind to it with this command:

```console
kubectl --context=service-catalog create -f resources/redis-binding.yaml
```

This command will create a `Secret` called `my-redis-creds` in the same namespace as the `Binding`.
To see it, run this command:

```console
kubectl get secret -n testing
```

After this secret is created, our application can use its contents to access its newly provisioned
redis instance.
