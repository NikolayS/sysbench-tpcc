#!/bin/bash

define(){ IFS='\n' read -r -d '' ${1} || true; }

set -ueo pipefail
set -ueox pipefail # to debug

instanceIdDefined="${instanceIdDefined:-}"
securityGroupIds="${securityGroupIds:sg-069a1372}"
pgVers="${pgVers:-10}"
ec2Type="${ec2Type:-m4.16xlarge}"
ec2Price="${ec2Price:-0.035}"
n="${n:-50}"
s="${s:-10}"
increment="${increment:-50}"
duration="${duration:-30}"
pgConfig=$(cat "config/$ec2Type")

if [ -z "$pgConfig" ]
then
  echo "ERROR: cannot find Postgres config for $ec2Type" 1>&2
  exit 1
fi

d=$(date)
echo "*******************************************************"
echo "TEST:                   sysbench                       "
echo "Current date/time:      $d"
echo "EC2 node type:          $ec2Type"
echo "Postgres major version: $pgVers"
echo "*******************************************************"


define ec2Opts <<EC2OPT
  {
    "MarketType": "spot",
    "SpotOptions": {
      "MaxPrice": "$ec2Price",
      "SpotInstanceType": "one-time",
      "InstanceInterruptionBehavior": "terminate"
    }
  }
EC2OPT

if [ -z "$instanceIdDefined" ]
then
  cmdout=$(aws ec2 run-instances --image-id "ami-9d751ee7" --count 1 \
    --instance-type "$ec2Type"  \
    --instance-market-options "$ec2Opts" \
    --security-group-ids "$securityGroupIds" \
    --block-device-mappings "[{\"DeviceName\": \"/dev/sda1\",\"Ebs\":{\"VolumeSize\":100}}]" \
    --key-name awskey)

  instanceId=$(echo $cmdout | jq -r '.Instances[0].InstanceId')
else
  instanceId="$instanceIdDefined"
fi

function cleanup {
#  cmdout=$(aws ec2 terminate-instances --instance-ids "$instanceId" | jq '.TerminatingInstances[0].CurrentState.Name')
#  echo "Finished working with instance $instanceId, termination requested, current status: $cmdout"
  echo "Done. But the instance is alive!"
}
trap cleanup EXIT


instanceState=$(echo $cmdout | jq -r '.Instances[0].State.Code')

echo "Instance requested, id: $instanceId, state code: $instanceState"

while true; do
  status=$(aws ec2 describe-instance-status --instance-ids "$instanceId" | jq -r '.InstanceStatuses[0].SystemStatus.Status')
  if [[ "$status" == "ok" ]]; then
    break
  fi
  echo "Status is $status, waiting 30 seconds…"
  sleep 30
done

instanceIP=$(aws ec2 describe-instances --instance-ids "$instanceId" | jq -r '.Reservations[0].Instances[0].PublicIpAddress')
echo "Public IP: $instanceIP"

shopt -s expand_aliases
alias sshdo='ssh -i ~/.ssh/awskey.pem -o "StrictHostKeyChecking no" "ubuntu@$instanceIP"'

sshdo "sudo mkdir /postgresql && sudo ln -s /postgresql /var/lib/postgresql"

sshdo "df -h"

sshdo "sudo sh -c 'echo \"deb http://apt.postgresql.org/pub/repos/apt/ \`lsb_release -cs\`-pgdg main\" >> /etc/apt/sources.list.d/pgdg.list'"
sshdo 'wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo apt-key add -'
sshdo 'sudo apt-get update >/dev/null'
sshdo "sudo apt-get install -y git libpq-dev make automake libtool pkg-config libaio-dev libmysqlclient-dev postgresql-$pgVers"

sshdo "echo \"$pgConfig\" >/tmp/111 && sudo sh -c 'cat /tmp/111 >> /etc/postgresql/$pgVers/main/postgresql.conf'"
sshdo "sudo /etc/init.d/postgresql restart"

sshdo "sudo -u postgres psql -c 'create database test;'"
sshdo "sudo -u postgres psql -c \"create role sysbench superuser login password '5y5b3nch';\""

sshdo "git clone https://github.com/akopytov/sysbench.git"
sshdo "cd ~/sysbench && ./autogen.sh && ./configure --with-pgsql && make -j && sudo make install"
sshdo "cd ~ && git clone https://github.com/NikolayS/sysbench-tpcc.git"
sshdo "cd ~/sysbench-tpcc && ./tpcc.lua  --threads=10 --report-interval=1 --tables=10 --scale=$s  --db-driver=pgsql --pgsql-port=5432 --pgsql-user=sysbench --pgsql-password=5y5b3nch  --pgsql-db=test prepare"
sshdo "cd ~/sysbench-tpcc && ./tpcc.lua  --threads=56 --report-interval=1 --tables=10 --scale=$s  --db-driver=pgsql --pgsql-port=5432 --pgsql-user=sysbench --pgsql-password=5y5b3nch  --pgsql-db=test --time=$duration --trx_level=RC run"


echo "The end."
exit 0
