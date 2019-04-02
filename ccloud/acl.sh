#!/bin/bash


################################################################################
# Overview
################################################################################
#
# Demo the new Confluent Cloud CLI and Access Control List (ACL) functionality
# in your Confluent Cloud Enterprise cluster that has been enabled for ACLs
#
# ACLs are only available in Confluent Cloud Enterprise,
# not in Confluent Cloud Professional
#
# DISCLAIMER:
#
#   This is mostly for reference to see a workflow using Confluent Cloud CLI
#
#   If you choose to run it against your Confluent Cloud cluster, be aware that it:
#      - creates and deletes topics, service accounts, API keys, and ACLs
#      - is for demo purposes only
#      - should be used only on a non-production cluster
#
# Usage:
#
#   ./acl.sh <url to cloud> <cloud email> <cloud password> <cluster>
#
# Requirements:
#   - Access to a Confluent Cloud Enterprise cluster
#   - Local install of the new Confluent Cloud CLI
#   - `timeout` installed on your host
#   - `mvn` installed on your host
#
################################################################################



# Source library
. ../utils/helper.sh

check_ccloud_v2 v0.48.0 || exit 1
check_timeout || exit 1
check_mvn || exit 1


##################################################
# Read URL, EMAIL, PASSWORD, CLUSTER from command line arguments
#
#  Rudimentary argument processing and must be in order:
#    <url to cloud> <cloud email> <cloud password> <cluster id>
##################################################
URL=$1
EMAIL=$2
PASSWORD=$3
CLUSTER=$4
if [[ -z "$URL" ]]; then
  read -s -p "Cloud cluster: " URL
  echo ""
fi
if [[ -z "$EMAIL" ]]; then
  read -s -p "Cloud user email: " EMAIL
  echo ""
fi
if [[ -z "$PASSWORD" ]]; then
  read -s -p "Cloud user password: " PASSWORD
  echo ""
fi
if [[ -z "$CLUSTER" ]]; then
  read -s -p "Cluster id: " CLUSTER
  echo ""
fi


##################################################
# Init user
##################################################

echo -e "\n-- Login --"
OUTPUT=$(
expect <<END
  log_user 1
  spawn ccloud login --url $URL
  expect "Email: "
  send "$EMAIL\r";
  expect "Password: "
  send "$PASSWORD\r";
  expect "Logged in as "
  set result $expect_out(buffer)
END
)
echo "$OUTPUT"
if [[ ! "$OUTPUT" =~ "Logged in as" ]]; then
  echo "Failed to log into your cluster.  Please check all parameters and run again"
  exit 1
fi

echo -e "\n-- Set cluster --"
echo "ccloud kafka cluster use $CLUSTER"
ccloud kafka cluster use $CLUSTER

echo -e "\n-- Create API key and set context --"
echo "ccloud kafka cluster auth"
OUTPUT=$(
expect <<END
  log_user 1
  spawn ccloud kafka cluster auth
  expect {
    "Bootstrap Servers" {
      set result $expect_out(buffer)
    }
    "\[N/y\]" {
      send "N\r"
      expect "Okay, we've created an API key"
      sleep 2
      set result $expect_out(buffer)
    }
  }
END
)
if [[ ! "$OUTPUT" =~ "Bootstrap Servers" ]]; then
  ccloud kafka cluster auth
  OUTPUT=$(ccloud kafka cluster auth)
fi
BOOTSTRAP_SERVERS=$(echo "$OUTPUT" | grep "Bootstrap Servers" | awk '{print $3;}')
#echo "BOOTSTRAP_SERVERS: $BOOTSTRAP_SERVERS"

echo -e "\n-- Sleeping 60 seconds to wait for user key to propagate --"
sleep 60


##################################################
# Produce and consume with Confluent Cloud CLI
##################################################

TOPIC1="demo-topic-1"
echo -e "\n-- Create topic $TOPIC1 --"
echo "ccloud kafka topic create $TOPIC1"
ccloud kafka topic create $TOPIC1 || true

echo -e "\n-- Produce to topic $TOPIC1 --"
echo "ccloud kafka topic produce $TOPIC1"
(for i in `seq 1 10`; do echo "${i}" ; done) | timeout 10s ccloud kafka topic produce $TOPIC1

echo -e "\n-- Consume from topic $TOPIC1 --"
echo "ccloud kafka topic consume $TOPIC1"
timeout 10s ccloud kafka topic consume $TOPIC1


##################################################
# Create a Service Account and API key and secret
#
#   A service account represents an application access 
##################################################

echo -e "\n-- Create service account --"
RANDOM_NUM=$((1 + RANDOM % 100))
SERVICE_NAME="demo-app-$RANDOM_NUM"
echo "ccloud service-account create --name $SERVICE_NAME --description $SERVICE_NAME"
ccloud service-account create --name $SERVICE_NAME --description $SERVICE_NAME || true
SERVICE_ACCOUNT_ID=$(ccloud service-account list | grep $SERVICE_NAME | awk '{print $1;}')

echo -e "\n-- Create API keys for service account --"
echo "ccloud api-key create --service-account-id $SERVICE_ACCOUNT_ID --cluster $CLUSTER"
OUTPUT=$(ccloud api-key create --service-account-id $SERVICE_ACCOUNT_ID --cluster $CLUSTER)
API_KEY=$(echo "$OUTPUT" | grep '| API Key' | awk '{print $5;}')
API_SECRET=$(echo "$OUTPUT" | grep "\| Secret" | awk '{print $4;}')
echo -e "\n-- Sleeping 90 seconds to wait for service-account key to propagate --"
sleep 90

CLIENT_CONFIG="/tmp/client.config"
echo -e "\n-- Create a file with the API key and secret --"
echo "Writing to $CLIENT_CONFIG"
cat <<EOF > $CLIENT_CONFIG
ssl.endpoint.identification.algorithm=https
sasl.mechanism=PLAIN
request.timeout.ms=20000
retry.backoff.ms=500
security.protocol=SASL_SSL
bootstrap.servers=${BOOTSTRAP_SERVERS}
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username\="${API_KEY}" password\="${API_SECRET}";
EOF


##################################################
# Java client: before and after ACLs
#
# When ACLs are enabled on your Confluent Cloud Enterprise cluster,
# by default no client applications are authorized.
#
# The following steps show the same Java producer failing at first due to
# `TopicAuthorizationException` and then passing once the appropriate
# ACLs are configured
##################################################

echo -e "\n-- No ACLs to start --"
echo "ccloud kafka acl list --service-account-id $SERVICE_ACCOUNT_ID"
ccloud kafka acl list --service-account-id $SERVICE_ACCOUNT_ID

echo -e "\n-- Run producer to $TOPIC1: before ACLs --"
mvn -q -f clients/java/pom.xml clean package
if [[ $? != 0 ]]; then
  echo "ERROR: There seems to be a build failure error compiling the client code? Please troubleshoot"
  exit 1
fi
LOG1="/tmp/log.1"
mvn -f clients/java/pom.xml exec:java -Dexec.mainClass="io.confluent.examples.clients.cloud.ProducerExample" -Dexec.args="$CLIENT_CONFIG $TOPIC1" > $LOG1 2>&1
OUTPUT=$(grep "org.apache.kafka.common.errors.TopicAuthorizationException" $LOG1)
if [[ ! -z $OUTPUT ]]; then
  echo "PASS: Producer failed due to org.apache.kafka.common.errors.TopicAuthorizationException (expected because there are no ACLs)"
else
  echo "FAIL: Something went wrong, check $LOG1"
fi

echo -e "\n-- Create ACLs for the producer --"
echo "ccloud kafka acl create --allow --service-account-id $SERVICE_ACCOUNT_ID --operation CREATE --topic $TOPIC1"
echo "ccloud kafka acl create --allow --service-account-id $SERVICE_ACCOUNT_ID --operation WRITE --topic $TOPIC1"
ccloud kafka acl create --allow --service-account-id $SERVICE_ACCOUNT_ID --operation CREATE --topic $TOPIC1
ccloud kafka acl create --allow --service-account-id $SERVICE_ACCOUNT_ID --operation WRITE --topic $TOPIC1
echo "ccloud kafka acl list --service-account-id $SERVICE_ACCOUNT_ID"
ccloud kafka acl list --service-account-id $SERVICE_ACCOUNT_ID
sleep 2

echo -e "\n-- Run producer to $TOPIC1: after ACLs --"
LOG2="/tmp/log.2"
mvn -f clients/java/pom.xml exec:java -Dexec.mainClass="io.confluent.examples.clients.cloud.ProducerExample" -Dexec.args="$CLIENT_CONFIG $TOPIC1" > $LOG2 2>&1
OUTPUT=$(grep "BUILD SUCCESS" $LOG2)
if [[ ! -z $OUTPUT ]]; then
  echo "PASS: Producer works"
else
  echo "FAIL: Something went wrong, check $LOG2"
fi

echo -e "\n-- Delete ACLs --"
ccloud kafka acl delete --allow --service-account-id $SERVICE_ACCOUNT_ID --operation CREATE --topic $TOPIC1
ccloud kafka acl delete --allow --service-account-id $SERVICE_ACCOUNT_ID --operation WRITE --topic $TOPIC1



##################################################
# Prefix ACL
#
# The following steps configure ACLs to match topics prefixed with a value
##################################################

TOPIC2="demo-topic-2"
echo -e "\n-- Create topic $TOPIC2 --"
echo "ccloud kafka topic create $TOPIC2"
ccloud kafka topic create $TOPIC2 || true

echo -e "\n-- Create ACLs for the producer using a prefix --"
PREFIX=${TOPIC2/%??/}
echo "ccloud kafka acl create --allow --service-account-id $SERVICE_ACCOUNT_ID --operation CREATE --topic $PREFIX --prefix"
echo "ccloud kafka acl create --allow --service-account-id $SERVICE_ACCOUNT_ID --operation WRITE --topic $PREFIX --prefix"
ccloud kafka acl create --allow --service-account-id $SERVICE_ACCOUNT_ID --operation CREATE --topic $PREFIX --prefix
ccloud kafka acl create --allow --service-account-id $SERVICE_ACCOUNT_ID --operation WRITE --topic $PREFIX --prefix
echo "ccloud kafka acl list --service-account-id $SERVICE_ACCOUNT_ID"
ccloud kafka acl list --service-account-id $SERVICE_ACCOUNT_ID
sleep 2

echo -e "\n-- Run producer to $TOPIC2: prefix ACLs --"
LOG3="/tmp/log.3"
mvn -f clients/java/pom.xml exec:java -Dexec.mainClass="io.confluent.examples.clients.cloud.ProducerExample" -Dexec.args="$CLIENT_CONFIG $TOPIC2" > $LOG3 2>&1
OUTPUT=$(grep "BUILD SUCCESS" $LOG3)
if [[ ! -z $OUTPUT ]]; then
  echo "PASS: Producer works"
else
  echo "FAIL: Something went wrong, check $LOG3"
fi

echo -e "\n-- Delete ACLs --"
ccloud kafka acl delete --allow --service-account-id $SERVICE_ACCOUNT_ID --operation CREATE --topic $PREFIX --prefix
ccloud kafka acl delete --allow --service-account-id $SERVICE_ACCOUNT_ID --operation WRITE --topic $PREFIX --prefix


##################################################
# Wildcard ACL
#
# The following steps configure ACLs to match topics using a wildcard
##################################################

echo -e "\n-- Create ACLs for the consumer using a wildcard --"
echo "ccloud kafka acl create --allow --service-account-id $SERVICE_ACCOUNT_ID --operation READ --consumer-group java_example_group_1"
echo "ccloud kafka acl create --allow --service-account-id $SERVICE_ACCOUNT_ID --operation READ --topic '*'"
ccloud kafka acl create --allow --service-account-id $SERVICE_ACCOUNT_ID --operation READ --consumer-group java_example_group_1
ccloud kafka acl create --allow --service-account-id $SERVICE_ACCOUNT_ID --operation READ --topic '*' 
echo "ccloud kafka acl list --service-account-id $SERVICE_ACCOUNT_ID"
ccloud kafka acl list --service-account-id $SERVICE_ACCOUNT_ID
sleep 2

echo -e "\n-- Run consumer from $TOPIC2: wildcard ACLs --"
LOG4="/tmp/log.4"
timeout 15s mvn -f clients/java/pom.xml exec:java -Dexec.mainClass="io.confluent.examples.clients.cloud.ConsumerExample" -Dexec.args="$CLIENT_CONFIG $TOPIC2" > $LOG4 2>&1
OUTPUT=$(grep "Successfully joined group with" $LOG4)
if [[ ! -z $OUTPUT ]]; then
  echo "PASS: Consumer works"
else
  echo "FAIL: Something went wrong, check $LOG4"
fi

echo -e "\n-- Delete ACLs --"
ccloud kafka acl delete --allow --service-account-id $SERVICE_ACCOUNT_ID --operation READ --consumer-group java_example_group_1
ccloud kafka acl delete --allow --service-account-id $SERVICE_ACCOUNT_ID --operation READ --topic '*' 


##################################################
# Cleanup
#
# Delete the API key, service account, Kafka topics, and some of the local files
##################################################

echo -e "\n-- Cleanup --"
ccloud api-key delete --api-key $API_KEY
ccloud service-account delete --service-account-id $SERVICE_ACCOUNT_ID
ccloud kafka topic delete $TOPIC1
ccloud kafka topic delete $TOPIC2
#rm -f "$LOG1"
#rm -f "$LOG2"
#rm -f "$LOG3"
#rm -f "$LOG4"
rm -f "$CLIENT_CONFIG"
