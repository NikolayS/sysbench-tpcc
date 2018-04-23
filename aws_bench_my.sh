#!/bin/bash

define(){ IFS='\n' read -r -d '' ${1} || true; }

set -ueo pipefail
set -ueox pipefail # to debug

instanceIdDefined="${instanceIdDefined:-}"
securityGroupIds="${securityGroupIds:-sg-069a1372}"
ec2Type="${ec2Type:-i3.xlarge}"
ec2Price="${ec2Price:-0.115}"
n="${n:-50}"
s="${s:-10}"
increment="${increment:-50}"
duration="${duration:-30}"
myConfig=$(cat "my_config/$ec2Type")

if [ -z "$myConfig" ]
then
  echo "ERROR: cannot find MySQL config for $ec2Type" 1>&2
  exit 1
fi

d=$(date)
echo "*******************************************************"
echo "TEST:                   sysbench                       "
echo "Current date/time:      $d"
echo "EC2 node type:          $ec2Type"
echo "Percona/MySQL test"
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

sshdo "sudo mkdir /mysql"
sshdo 'echo "$myConfig" > ~/my.cnf'
# if it is "i3" family, attach nvme drive
if [ ${ec2Type:0:2} == 'i3']
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
  sshdo "sudo mount /dev/nvme0n1p1 /mysql"
fi
sshdo "sudo chmod a+w /mysql"

sshdo "df -h"

sshdo "sudo add-apt-repository ppa:ubuntu-toolchain-r/test"
sshdo "sudo apt-get update"
sshdo "sudo apt-get install -y git make automake libtool pkg-config libaio-dev libmysqlclient-dev gcc-4.9 numactl"
sshdo "sudo apt-get upgrade -y libstdc++6"

sshdo "wget https://www.percona.com/downloads/Percona-Server-LATEST/Percona-Server-5.7.21-20/binary/tarball/Percona-Server-5.7.21-20-Linux.x86_64.ssl100.tar.gz"
sshdo "tar xvf Percona-Server-5.7.21-20-Linux.x86_64.ssl100.tar.gz"
sshdo "cd Percona-Server-5.7.21-20-Linux.x86_64.ssl100/"

sshdo "numactl --interleave=all bin/mysqld --defaults-file=~/my.cnf --basedir=/home/ubuntu/Percona-Server-5.7.21-20-Linux.x86_64.ssl100 --user=ubuntu --innodb_buffer_pool_size=20G"

brr

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
