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
```

After that runs, you'll see the following output:

```console
Registering is still on-going. You can monitor using 'az provider show -n Microsoft.Cache'
```

Run the `az provider show -n Microsoft.Cache` command until you see 
`registrationState: "Registered"` in the output.

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
NAME               KIND
azure-documentdb   ServiceClass.v1alpha1.servicecatalog.k8s.io
azure-rediscache   ServiceClass.v1alpha1.servicecatalog.k8s.io
azure-servicebus   ServiceClass.v1alpha1.servicecatalog.k8s.io
azure-sqldb        ServiceClass.v1alpha1.servicecatalog.k8s.io
azure-storage      ServiceClass.v1alpha1.servicecatalog.k8s.io
```

# Provision a New Service

After `ServieClass`es are listed in the catalog, you can provision instances of them. Conveniently,
you submit an `Instance` resource to the Service Catalog API server in order to provision a service.

Unlike `Broker`s and `ServiceClass`es above, `Instance`s are namespaced, so we'll have to create
a new Kubernetes namespace for them. Do so with this command:

```console
kubectl create ns my-redis
```

After you've created the namespace, you can create the `Instance`. This repository has a 
`redis-instance.yaml` file in the `resources/` directory that represents an `Instance` to provision
a Redis server via [Azure's Redis Cache service](https://azure.microsoft.com/en-us/services/cache/).

To provision, create an `Instance` with this command:

```console
kubectl --context=service-catalog create -f resources/redis-instance.yaml
```

Next, view the newly created `Instance` with this command:

```console
kubectl get instance --context=service-catalog -o yaml -n my-redis coreos-redis
```

A large amount of YAML will be output, but the important bits are under the
`status.conditions[0]` field (near the bottom). Since the Azure redis service takes a few minutes
to create new caches, the Azure broker provisions them asynchronously. As a result, you'll see
the following under the first condition:

```yaml
message: The instance is being provisioned asynchronously
reason: Provisioning
status: "False"
type: Ready
```

Wait until the `reason` field reads `ProvisionedSuccessfully` and the `status` field
reads `"True"` before moving on to the next step.

# Bind to the new Instance

Our last step is to bind to the instance. In doing so, service-catalog will get back some
credentials that it will write into a `Secret`. All we have to do is run the following command:

```console
kubectl --context=service-catalog create -f resources/redis-binding.yaml
```

This command will create a `Secret` called `coreos-redis-creds` in the same (`my-redis`) namespace.
To see it, run this command:

```console
kubectl get secret -n my-redis
```

After this secret is created, our application can use its contents to access its newly provisioned
redis instance.
