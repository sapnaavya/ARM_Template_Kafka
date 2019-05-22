#!/bin/bash

# The MIT License (MIT)
#
# Copyright (c) 2015 Microsoft Azure
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
# Author: Cognosys Technologies
 
### 
### Warning! This script partitions and formats disk information be careful where you run it
###          This script is currently under development and has only been tested on Ubuntu images in Azure
###          This script is not currently idempotent and only works for provisioning at the moment

### Remaining work items
### -Alternate discovery options (Azure Storage)
### -Implement Idempotency and Configuration Change Support
### -Recovery Settings (These can be changed via API)

#Setup logging
cat >> /mnt/kafka_extension.log << EOF
Running Kafka setup
=> $0 $@
EOF
cp $0 /mnt
exec 3>&1 4>&2
trap 'exec 2>&4 1>&3' EXIT SIGHUP SIGINT SIGQUIT
exec 1>> /mnt/kafka_extension.log 2>&1
export PS4='+(${BASH_SOURCE}:${LINENO}): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
set -x +H

function help() {
    #TODO: Add help text here
    echo "This script installs kafka cluster on Ubuntu"
    echo "Parameters:"
    echo "-b broker id"
    echo "-c number of instances"
    echo "-h view this help content"
    echo "-i zookeeper Private IP address prefix"    
    echo "-k kafka version like 0.8.2.1"    
    echo "-n instance number 0..n"
    echo "-z zookeeper not kafka"
}

echo "Begin execution of kafka script extension on ${HOSTNAME}"

if [ "${UID}" -ne 0 ]
then
    echo "Script executed without root permissions"
    echo "You must be root to run this program." >&2
    exit 3
fi

# TEMP FIX - Re-evaluate and remove when possible
# This is an interim fix for hostname resolution in current VM
grep -q "${HOSTNAME}" /etc/hosts
if [ "${?}" -eq 0 ]
then
  echo "${HOSTNAME} found in /etc/hosts"
else
  echo "${HOSTNAME} not found in /etc/hosts"
  # Append it to the hsots file if not there
  echo "127.0.0.1 $(hostname)" >> /etc/hosts
  echo "hostname ${HOSTNAME} added to /etc/hosts"
fi

#Script Parameters
KF_VERSION="2.2.0"
BROKER_ID=0
ZOOKEEPER1KAFKA0="0"

ZOOKEEPER_IP_PREFIX="10.0.0.4"
INSTANCE_COUNT=1
ZOOKEEPER_PORT="2181"

#Loop through options passed
while getopts b:c:hi:k:n:z: optname
do
  echo "Option ${optname} set with value ${OPTARG}"
  case $optname in
    b)  #broker id
      BROKER_ID=${OPTARG}
      ;;
    c) # Number of instances
      INSTANCE_COUNT=${OPTARG}
      ;;
    h)  #show help
      help
      exit 2
      ;;
    i)  #zookeeper Private IP address prefix
      ZOOKEEPER_IP_PREFIX=${OPTARG}
      ;;
    k)  #kafka version
      KF_VERSION=${OPTARG}
      ;;
    n) # Instance number
      INSTANCE_NUMBER=${OPTARG}
      ;;
    z)  #zookeeper not kafka
      ZOOKEEPER1KAFKA0=${OPTARG}
      ;;
  esac
done

# Install Oracle Java
function install_java() {
    echo "Installing Java"
    cp -f /etc/apt/sources.list /etc/apt/sources.list.bak
    cat - /etc/apt/sources.list.bak > /etc/apt/sources.list << EOF
deb mirror://mirrors.ubuntu.com/mirrors.txt precise-security main restricted universe multiverse
deb mirror://mirrors.ubuntu.com/mirrors.txt precise-backports main restricted universe multiverse
deb mirror://mirrors.ubuntu.com/mirrors.txt precise-updates main restricted universe multiverse
deb mirror://mirrors.ubuntu.com/mirrors.txt precise main restricted universe multiverse
EOF
    apt-get update >> /mnt/aptget.log
    tries=3
    while [ $tries -gt 0 ]
    do
        DEBIAN_FRONTEND=noninteractive apt-get install --yes --quiet default-jre >> /mnt/aptget.log
        if [[ $? -eq 0 ]]
        then
            tries=0
        else
            tries=$(($tries - 1))
        fi
    done
    JAVA_HOME=`readlink -f /usr/bin/java | sed 's:/bin/java::'`
    echo -e "export JAVA_HOME=$JAVA_HOME" >> /etc/profile.d/java.sh
}

# Expand a list of successive IP range defined by a starting address prefix (e.g. 10.0.0.1) and the number of machines in the range
# 10.0.0.1-3 would be converted to "10.0.0.10 10.0.0.11 10.0.0.12"

function expand_ip_range_for_server_properties() {
    count="$(echo "$1" | sed 's/.*-//')"
    prefix="$(echo "$1" | sed 's/-.*//')"
    for (( n=0 ; n<count ; n++))
    do
        echo "server.$(expr ${n} + 1)=${prefix}${n}:2888:3888" >> zookeeper-3.4.14/conf/zoo.cfg
    done
}

function join() {
    local IFS="$1"; shift; echo "$*";
}

function expand_ip_range() 
{
    count="$(echo "$1" | sed 's/.*-//')"
    prefix="$(echo "$1" | sed 's/-.*//')"
    declare -a result=()
    for (( n=0 ; n<count ; n++))
    do
        host="${prefix}${n}:${ZOOKEEPER_PORT}"
        result+=($host)
    done
    echo "${result[@]}"
}

# Install Zookeeper - can expose zookeeper version
function install_zookeeper() {
    mkdir -p /var/lib/zookeeper
    cd /var/lib/zookeeper
    # wget "http://mirrors.ukfast.co.uk/sites/ftp.apache.org/zookeeper/stable/zookeeper-3.4.14.tar.gz"
    wget "http://mirrors.ukfast.co.uk/sites/ftp.apache.org/zookeeper/zookeeper-3.4.14/zookeeper-3.4.14.tar.gz"
    tar -xvf "zookeeper-3.4.14.tar.gz"
    touch zookeeper-3.4.14/conf/zoo.cfg
    echo "tickTime=2000" >> zookeeper-3.4.14/conf/zoo.cfg
    echo "dataDir=/var/lib/zookeeper" >> zookeeper-3.4.14/conf/zoo.cfg
    echo "clientPort=2181" >> zookeeper-3.4.14/conf/zoo.cfg
    echo "initLimit=5" >> zookeeper-3.4.14/conf/zoo.cfg
    echo "syncLimit=2" >> zookeeper-3.4.14/conf/zoo.cfg
    # OLD Test echo "server.1=${ZOOKEEPER_IP_PREFIX}:2888:3888" >> zookeeper-3.4.6/conf/zoo.cfg
    $(expand_ip_range_for_server_properties "${ZOOKEEPER_IP_PREFIX}-${INSTANCE_COUNT}")
    echo $((INSTANCE_NUMBER + 1 )) >> /var/lib/zookeeper/myid
    zookeeper-3.4.14/bin/zkServer.sh start
}

# Install kafka
function install_kafka() {
    cd /usr/local
    name=kafka
    version=${KF_VERSION}
    #this Kafka version is prefix same used for all versions
    kafkaversion="2.11"
    description="Apache Kafka is a distributed publish-subscribe messaging system."
    url="https://kafka.apache.org/"
    arch="all"
    section="misc"
    license="Apache Software License 2.0"
    package_version="-1"
    src_package="kafka_${kafkaversion}-${version}.tgz"
    download_url=http://www-eu.apache.org/dist/kafka/${version}/${src_package}
    rm -rf kafka
    mkdir -p kafka
    cd kafka
    #_ MAIN _#
    if [[ ! -f "${src_package}" ]]; then
        wget ${download_url}
    fi
    tar zxf ${src_package}
    cd kafka_${kafkaversion}-${version}
    sed -r -i "s/(broker.id)=(.*)/\1=${BROKER_ID}/g" config/server.properties
    sed -r -i "s/(zookeeper.connect)=(.*)/\1=$(join , $(expand_ip_range "${ZOOKEEPER_IP_PREFIX}-${INSTANCE_COUNT}"))/g" config/server.properties
    #cp config/server.properties config/server-1.properties
    #sed -r -i "s/(broker.id)=(.*)/\1=1/g" config/server-1.properties
    #sed -r -i "s/^(port)=(.*)/\1=9093/g" config/server-1.properties````
    chmod u+x /usr/local/kafka/kafka_${kafkaversion}-${version}/bin/kafka-server-start.sh
    /usr/local/kafka/kafka_${kafkaversion}-${version}/bin/kafka-server-start.sh /usr/local/kafka/kafka_${kafkaversion}-${version}/config/server.properties &
}

# Primary Install Tasks
#########################
#NOTE: These first three could be changed to run in parallel
#      Future enhancement - (export the functions and use background/wait to run in parallel)

#Install Oracle Java
#------------------------
install_java

if [ ${ZOOKEEPER1KAFKA0} -eq "1" ];
then
    #
    #Install zookeeper
    #-----------------------
    install_zookeeper
else
    #
    #Install kafka
    #-----------------------
    install_kafka
fi
