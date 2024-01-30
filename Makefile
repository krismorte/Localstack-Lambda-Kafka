zookeeper:
	docker run --rm -d --name zookeeper -p "2181:2181" -e "ZOOKEEPER_CLIENT_PORT=2181" -e "ZOOKEEPER_TICK_TIME=2000" confluentinc/cp-zookeeper:latest

broker:
	docker run --rm -d --name broker -p "9092:9092" -e "KAFKA_BROKER_ID=1" -e "KAFKA_ZOOKEEPER_CONNECT=localhost:2181" -e "KAFKA_ADVERTISED_LISTENERS=INSIDE://broker:9092,OUTSIDE://broker:9093" -e "KAFKA_LISTENER_SECURITY_PROTOCOL_MAP=INSIDE:PLAINTEXT,OUTSIDE:PLAINTEXT" -e "KAFKA_LISTENERS=INSIDE://0.0.0.0:9092,OUTSIDE://0.0.0.0:9093" -e "KAFKA_INTER_BROKER_LISTENER_NAME=INSIDE" -e "KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR=1" -e "KAFKA_TRANSACTION_STATE_LOG_MIN_ISR=1" -e "KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR=1" -e "KAFKA_CREATE_TOPICS:='my_topic:1:1'" confluentinc/cp-kafka:latest

localstack:
	docker run --rm -d --name localstack -e SERVICES=s3,iam,lambda -e "DOCKER_HOST=unix:///var/run/docker.sock" -e "DATA_DIR=/tmp/localstack/data" -e AWS_DEFAULT_REGION=us-east-1 -p "4566:4566" -v "/var/run/docker.sock:/var/run/docker.sock" localstack/localstack

infra:
	docker compose up -d 

clean-tmp-files:
	rm -rf ./src/lambda | true
	rm .terraform.lock.hcl | true
	rm terraform.tfstate | true
	rm terraform.tfstate.backup | true

terraform: clean-tmp-files
	sleep 5
	terraform init
	terraform apply -auto-approve

kafka_topic:
	docker exec broker /usr/bin/kafka-topics --create --topic mytopic --bootstrap-server broker:29092

kafka_ls:
	docker exec broker /usr/bin/kafka-topics --bootstrap-server broker:29092 --list

	

kafka_msg:
	docker exec broker /usr/bin/kafka-console-producer --bootstrap-server localhost:9092 --topic my_topic

kafka_read:
	docker exec broker /usr/bin/kafka-console-consumer --topic my_topic --bootstrap-server localhost:9092 --from-beginning

stop_localstack:
	docker compose down

tf:
	docker run --rm -v $(PWD):/data -w /data hashicorp/terraform:1.5.2 init
	docker run --rm -v $(PWD):/data -w /data hashicorp/terraform:1.5.2 apply

deploy: infra  

config: terraform

lambda-docker:
	docker build -t lambda .
	docker run --rm -it -p 9000:8080 --env-file .env  lambda 

lambda-test:
	curl -XPOST "http://localhost:9000/2015-03-31/functions/function/invocations" -d @bucket.payload.json '{"Records": [{"payload":"hello world!"}]}'

destroy:
	docker stop zookeeper
	docker stop localstack
	docker stop broker
	

redeploy: stop_localstack localstack tf

BUCKET = dd-external-events.trail.log

download:
	OBJECT="$$(aws s3 ls $(BUCKET)/AWSLogs/580803390928/CloudTrail/us-east-1/ --recursive | sort | tail -n 1 | awk '{print $$4}')"; \
	aws s3 cp s3://$(BUCKET)/$$OBJECT ./input.cloudtrail.json.gz
	aws s3 cp input.cloudtrail.json.gz s3://bucket-trail --endpoint-url=http://localhost:4566
	rm input.cloudtrail.json.gz

upload:
	gzip --keep cloudtrail.logs.json --force
	aws s3 cp cloudtrail.logs.json.gz s3://bucket-trail --endpoint-url=http://localhost:4566
	rm cloudtrail.logs.json.gz

log:
	aws --endpoint-url=http://localhost:4566 logs tail '/aws/lambda/lambda-filter'