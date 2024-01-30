import gzip
import json
import os
import boto3
from typing import Tuple, Dict, Any
from cloudevents.http import CloudEvent
from cloudevents.conversion import to_structured
from kafka import KafkaProducer
from kafka.errors import KafkaError


DESTINATION_BOOTSTRAP_SERVERS = os.environ.get("DESTINATION_BOOTSTRAP_SERVERS").split(",")
DESTINATION_TOPIC = os.environ.get("DESTINATION_TOPIC")

FILTER_FILE = "./filters.json"

session = boto3.Session()

s3_client = session.client("s3")
if os.environ.get("DEBUG"):
    endpoint_url = "http://host.docker.internal:4566"
    #endpoint_url = "http://localhost:4566"
    s3_client = session.client("s3", endpoint_url=endpoint_url)


def cloud_event_creator(source: str, data: dict):
    attributes = {
        "source": source,
        "type": "AWS Event",
        "datacontenttype": "application/json"
    }

    event = CloudEvent(attributes, data)
    headers, body = to_structured(event)
    return body

def kafka_producer(bootstrap_servers: str) -> KafkaProducer:
    try:
        producer = KafkaProducer(bootstrap_servers=bootstrap_servers)
        return producer
    except KafkaError as e:
        print(f"Error creating Kafka producer: {e}")
        return e


def kafka_producer_send(producer: KafkaProducer, topic_name: str, message: bytes):
    try:
        producer.send(topic_name, message)
        producer.flush()
    except Exception as e:
        print(f"Error sending messages to Kafka: {e}")
        return e

def handler(event, context):
    print("Event: " + str(event))
    print("Starting event-connect-processor...")

    f = open(FILTER_FILE, "r")
    event_filter = json.loads(f.read())
    print("No of events: " + str(len(event['Records'])))
    for event in event['Records']:
        bucket = event['s3']['bucket']['name']
        file_name = event['s3']['object']['key']
        if not file_name.endswith('.json.gz'):
            print("File with the wrong name: " + str(file_name))
            continue


        s3_obj = s3_client.get_object(Bucket=bucket, Key=file_name)
        print("S3 object successfully downloaded")
        with gzip.open(s3_obj["Body"]) as infile:
            records = json.load(infile)

        filtered_events = []
        for log in records["Records"]:
            for filter in event_filter['filters']:
                if filter['source']==log['eventSource'] and log['eventName'] in filter['actions']:
                    filtered_events.append(log)

        print("Filtered logs: ", len(filtered_events))

        if len(filtered_events) > 0:
            producer = kafka_producer(DESTINATION_BOOTSTRAP_SERVERS)
            print("Producer: " + str(producer))

            for event in filtered_events:
                body = cloud_event_creator(event["eventSource"], event)
                kafka_producer_send(producer, DESTINATION_TOPIC, body)