get-all:
	kubectl --context=service-catalog get broker,serviceclass,instance,binding
create-broker:
	kubectl --context=service-catalog create -f resources/masb-broker.yaml
get-broker:
	kubectl --context=service-catalog get broker masb -o yaml
get-serviceclasses:
	kubectl --context=service-catalog get serviceclass
create-instance:
	kubectl --context=service-catalog create -f resources/redis-instance.yaml
get-instance:
	kubectl --context=service-catalog get instance coreos-redis -o yaml -n my-redis
create-binding:
	kubectl --context=service-catalog create -f resources/redis-binding.yaml
get-binding:
	kubectl --context=service-catalog get binding coreos-redis -o yaml -n my-redis
get-secret:
	kubectl get secret coreos-redis-creds
cleanup:
	kubectl delete --context=service-catalog binding coreos-redis -n my-redis || \
	kubectl delete --context=service-catalog instance coreos-redis -n my-redis || \
	kubectl delete --context=service-catalog broker masb
