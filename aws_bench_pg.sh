#!/bin/bash

define(){ IFS='\n' read -r -d '' ${1} || true; }

set -ueo pipefail
set -ueox pipefail # to debug

instanceIdDefined="${instanceIdDefined:-}"
securityGroupIds="${securityGroupIds:-sg-069a1372}"
pgVers="${pgVers:-10}"
ec2Type="${ec2Type:-i3.xlarge}"
ec2Price="${ec2Price:-0.115}"
n="${n:-50}"
s="${s:-10}"
increment="${increment:-50}"
duration="${duration:-30}"
pgConfig=$(cat "pg_config/$ec2Type")

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
  if [ ${ec2Type:0:2} == 'i3' ]
  then
    cmdout=$(aws ec2 run-instances --image-id "ami-9d751ee7" --count 1 \
      --instance-type "$ec2Type"  \
      --instance-market-options "$ec2Opts" \
      --security-group-ids "$securityGroupIds" \
      --key-name awskey)
  else
    cmdout=$(aws ec2 run-instances --image-id "ami-9d751ee7" --count 1 \
      --instance-type "$ec2Type"  \
      --instance-market-options "$ec2Opts" \
      --security-group-ids "$securityGroupIds" \
      --block-device-mappings "[{\"DeviceName\": \"/dev/sda1\",\"Ebs\":{\"VolumeSize\":100}}]" \
      --key-name awskey)
  fi

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

sleep 5

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
#sshdo "sudo rm -rf /var/log/postgresql"
# if it is "i3" family, attach nvme drive
if [ ${ec2Type:0:2} == 'i3' ]
then
  sshdo "sudo add-apt-repository -y ppa:sbates"
  sshdo "sudo apt-get update"
  sshdo "sudo apt-get install -y nvme-cli"

  define nvmePart <<CONF
# partition table of /dev/nvme0n1
unit: sectors

/dev/nvme0n1p1 : start=     2048, size=1855466702, Id=83
/dev/nvme0n1p2 : start=        0, size=        0, Id= 0
/dev/nvme0n1p3 : start=        0, size=        0, Id= 0
/dev/nvme0n1p4 : start=        0, size=        0, Id= 0
CONF

  sshdo "echo \"$nvmePart\" > /tmp/nvme.part"
  sshdo "sudo sfdisk /dev/nvme0n1 < /tmp/nvme.part"
  sshdo "sudo mkfs -t ext4 /dev/nvme0n1p1"
  sshdo "sudo mount /dev/nvme0n1p1 /postgresql"
fi

sshdo "df -h"

sshdo "sudo mkdir /postgresql/log && sudo ln -s /postgresql/log /var/log/postgresql && sudo chmod a+w /var/log/postgresql"

sshdo "sudo sh -c 'echo \"deb http://apt.postgresql.org/pub/repos/apt/ \`lsb_release -cs\`-pgdg main\" >> /etc/apt/sources.list.d/pgdg.list'"
sshdo 'wget --quiet -O - https://www.postgresql.org/media/keys/ACCC4CF8.asc | sudo apt-key add -'
sshdo 'sudo apt-get update >/dev/null'
sshdo "sudo apt-get install -y git libpq-dev make automake libtool pkg-config libaio-dev libmysqlclient-dev postgresql-$pgVers"

sshdo "echo \"$pgConfig\" >/tmp/111 && sudo sh -c 'cat /tmp/111 >> /etc/postgresql/$pgVers/main/postgresql.conf'"
sshdo "sudo sh -c \"echo '' > /var/log/postgresql/postgresql-$pgVers-main.log\""
sshdo "sudo /etc/init.d/postgresql restart"

sshdo "sudo -u postgres psql -c 'create database test;'"
sshdo "sudo -u postgres psql test -c 'create extension pg_stat_statements;'"
sshdo "sudo -u postgres psql -c \"create role sysbench superuser login password '5y5b3nch';\""

sshdo "git clone https://github.com/akopytov/sysbench.git"
sshdo "cd ~/sysbench && ./autogen.sh && ./configure --with-pgsql && make -j && sudo make install"
sshdo "cd ~ && git clone https://github.com/NikolayS/sysbench-tpcc.git"
sshdo "cd ~/sysbench-tpcc && ./tpcc.lua  --threads=10 --report-interval=1 --tables=10 --scale=$s  --db-driver=pgsql --pgsql-port=5432 --pgsql-user=sysbench --pgsql-password=5y5b3nch  --pgsql-db=test prepare"

sshdo "sudo -u postgres psql test -c 'vacuum analyze;'"

sshdo "sudo -u postgres psql test -c 'select pg_stat_reset();'"
sshdo "sudo -u postgres psql test -c 'select pg_stat_statements_reset();'"
sshdo "sudo sh -c \"echo '' > /var/log/postgresql/postgresql-$pgVers-main.log\""

sshdo "cd ~/sysbench-tpcc && ./tpcc.lua  --threads=56 --report-interval=1 --tables=10 --scale=$s  --db-driver=pgsql --pgsql-port=5432 --pgsql-user=sysbench --pgsql-password=5y5b3nch  --pgsql-db=test --time=$duration --trx_level=RC run"

sshdo "sudo -u postgres psql test -c 'create schema stats;'"
sshdo "sudo -u postgres psql test -c 'create table stats.pg_stat_statements as select * from pg_stat_statements;'"
sshdo "sudo -u postgres psql test -c 'create table stats.pg_stat_database as select * from pg_stat_database;'"
sshdo "sudo -u postgres psql test -c 'create table stats.pg_stat_user_tables as select * from pg_stat_user_tables;'"
sshdo "sudo -u postgres pg_dump test -n stats > /tmp/stats"
scp -i ~/.ssh/awskey.pem -o "StrictHostKeyChecking no" "ubuntu@$instanceIP:/tmp/stats" ./stats
sshdo "sudo gzip /var/log/postgresql/postgresql-$pgVers-main.log"
scp -i ~/.ssh/awskey.pem -o "StrictHostKeyChecking no" "ubuntu@$instanceIP:/var/log/postgresql/postgresql-$pgVers-main.log.gz" ./pg.log.gz

echo "The end."
exit 0
