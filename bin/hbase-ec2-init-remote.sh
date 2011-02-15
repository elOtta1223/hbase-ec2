#!/usr/bin/env bash
MASTER_HOST=$1
ZOOKEEPER_QUORUM=$2
NUM_SLAVES=$3
EXTRA_PACKAGES=$4
LOG_SETTING=$5
export JAVA_HOME=/usr/local/jdk1.6.0_23
ln -s $JAVA_HOME /usr/local/jdk
SECURITY_GROUPS=`wget -q -O - http://169.254.169.254/latest/meta-data/security-groups`
IS_MASTER=`echo $SECURITY_GROUPS | awk '{ a = match ($0, "-master$"); if (a) print "true"; else print "false"; }'`
if [ "$IS_MASTER" = "true" ]; then
 MASTER_HOST=`wget -q -O - http://169.254.169.254/latest/meta-data/local-hostname`
fi
MASTER_HOST=$(echo "$MASTER_HOST" | tr '[:upper:]' '[:lower:]')
HADOOP_HOME=`ls -d /usr/local/hadoop-* | grep -v tar.gz | head -n1`
HADOOP_VERSION=`echo $HADOOP_HOME | cut -d '-' -f 2`
HBASE_HOME=`ls -d /usr/local/hbase-* | grep -v tar.gz | head -n1`
HBASE_VERSION=`echo $HBASE_HOME | cut -d '-' -f 2`
HADOOP_SECURE_USER=hadoop
HOSTNAME=`hostname --fqdn | awk '{print tolower($1)}'`
HOST_IP=$(host $HOSTNAME | awk '{print $4}')
export USER="root"
add_client() {
 user=$1
 pass=$2
 kt=$3
 host=$4
 kadmin -p $user -w $pass <<EOF 
add_principal -randkey host/$host
add_principal -randkey hadoop/$host
add_principal -randkey hbase/$host
ktadd host/$host
ktadd -k $kt hadoop/$host
ktadd -k $kt hbase/$host
quit
EOF
}
kadmin_setup() {
 kmasterpass=$1
 kadmpass=$2
 host=$3
 kdb5_util create -s -P ${kmasterpass}
 service krb5kdc start
 service kadmin start
 sleep 1
 kadmin.local <<EOF 
add_principal -pw $kadmpass kadmin/admin
add_principal -pw $kadmpass hadoop/admin
add_principal -pw had00p hclient
add_principal -randkey ldap/$host
ktadd -k /etc/openldap/ldap.keytab ldap/$host
quit
EOF
}

ldap_server_setup() {
  cat >>/etc/sysconfig/ldap <<EOF
export KRB5_KTNAME=/etc/openldap/ldap.keytab
EOF

  mv /etc/openldap/slapd.d /etc/openldap/slapd.d.bak

  rootpw=$(slappasswd -p 'passwd')

  cat >/etc/openldap/slapd.conf <<EOF
suffix          "dc=hadoop,dc=localdomain"
rootdn          "cn=Manager,dc=hadoop,dc=localdomain"
rootpw          $rootpw
idletimeout 3600
# This is a bit of a hack to restrict the SASL mechanisms that the
# server advertises to just GSSAPI.  Otherwise it also advertises
# DIGEST-MD5, which the clients prefer.  Then you have to add "-Y
# GSSAPI" to all of your ldapsearch/ldapmodify/etc. command lines, which
# is annoying.  The default for this is noanonymous,noplain so the
# addition of noactive is what makes DIGEST-MD5 and the others go away.
sasl-secprops noanonymous,noplain,noactive

# Map SASL authentication DNs to LDAP DNs
#   This leaves "username/admin" principals untouched
sasl-regexp uid=([^/]*),cn=GSSAPI,cn=auth uid=$1,ou=people,dc=hadoop,dc=localdomain
# This should be a   ^  plus, not a star, but slapd won't accept it

# Users can change their shell, anyone else can see it
access to attr=loginShell
        by dn.regex="uid=.*/admin,cn=GSSAPI,cn=auth" write
        by self write
        by * read
# Only the user can see their employeeNumber
access to attr=employeeNumber
        by dn.regex="uid=.*/admin,cn=GSSAPI,cn=auth" write
        by self read
        by * none
# Default read access for everything else
access to *
        by dn.regex="uid=.*/admin,cn=GSSAPI,cn=auth" write
        by * read
EOF

  # create the config file for bdb
  cat >/var/lib/ldap/DB_CONFIG <<EOF
# Increase the cache size to 8MB
set_cachesize 0 8388608 1
EOF

  chkconfig slapd on
  service slapd start

  cat >sample.ldif <<EOF
dn: dc=hadoop,dc=localdomain
objectclass: organization
objectclass: dcObject
o: Hadoop
dc: hadoop
description: Hadoop org

##############################################################################
# passwd
##############################################################################

dn: ou=people,dc=hadoop,dc=localdomain
objectclass: organizationalUnit
ou: people
description: Hadoop users

dn: uid=huser,ou=people,dc=hadoop,dc=localdomain
objectClass: inetOrgPerson
objectClass: posixAccount
cn: Hadoop User
givenName: huser
sn:  Hadoop
mail: huser@hadoop.localdomain
telephoneNumber: +1 206 111 2222
title: Tester
uid: huser
uidNumber: 10000
gidNumber: 100
homeDirectory: /home/huser
loginShell: /bin/bash

##############################################################################
# group
##############################################################################

dn: ou=group,dc=hadoop,dc=localdomain
objectClass: organizationalUnit
ou: group
description: Hadoop Groups

dn: cn=users,ou=group,dc=hadoop,dc=localdomain
cn: users
objectClass: posixGroup
userPassword: {crypt}*
gidNumber: 100
memberUid: huser
memberUid: hclient

EOF

  ldapadd -x -D "cn=Manager,dc=hadoop,dc=localdomain" -w $rootpw -f sample.ldif
}

ldap_client() {
  masterhost=$1
  authconfig --enableldap --enablekrb5 --update

  cat >/etc/openldap/ldap.conf <<EOF
BASE	dc=hadoop, dc=localdomain
URI	ldap://$masterhost ldaps://$masterhost
TLS_CACERT	/etc/pki/tls/certs/ca-bundle.crt
EOF
  ln -s /etc/openldap/ldap.conf /etc/ldap.conf
  ln -s /etc/openldap/ldap.conf /etc/pam_ldap.conf
  ln -s /etc/openldap/ldap.conf /etc/nss_ldap.conf
}

sysctl -w fs.file-max=65536
echo "root soft nofile 65536" >> /etc/security/limits.conf
echo "root hard nofile 65536" >> /etc/security/limits.conf
ulimit -n 65536
sysctl -w fs.epoll.max_user_instances=65536 > /dev/null 2>&1
[ ! -f /etc/hosts ] &&  echo "127.0.0.1 localhost" > /etc/hosts
echo "$HOST_IP $HOSTNAME" >> /etc/hosts
echo -n "$MASTER_HOST" > /etc/tm-kdc-hostname
if [ "$EXTRA_PACKAGES" != "" ] ; then
 pkg=( $EXTRA_PACKAGES )
 wget -nv -O /etc/yum.repos.d/user.repo ${pkg[0]}
 yum -y update yum
 yum -y install ${pkg[@]:1}
fi
[ -f $HADOOP_HOME/bin/jsvc ] || ln -s /usr/bin/jsvc $HADOOP_HOME/bin
adduser hadoop
groupadd supergroup
adduser -G supergroup hbase
if [ "$IS_MASTER" = "true" ]; then
 cat > /var/kerberos/krb5kdc/kadm5.acl <<EOF
*/admin@HADOOP.LOCALDOMAIN    *
EOF
  cat > /var/kerberos/krb5kdc/kdc.conf <<EOF
[kdcdefaults]
 v4_mode = nopreauth
 kdc_ports = 0
 kdc_tcp_ports = 88

[realms]
 HADOOP.LOCALDOMAIN = {
  master_key_type = des3-hmac-sha1
  acl_file = /var/kerberos/krb5kdc/kadm5.acl
  dict_file = /usr/share/dict/words
  admin_keytab = /var/kerberos/krb5kdc/kadm5.keytab
  supported_enctypes = des3-hmac-sha1:normal des-cbc-crc:normal des:normal des:v4 des:norealm des:onlyrealm
  max_life = 1d 0h 0m 0s
  max_renewable_life = 7d 0h 0m 0s
#  default_principal_flags = +preauth
 }
EOF
fi
cat > /etc/krb5.conf <<EOF
[logging]
 default = FILE:/var/log/krb5libs.log
 kdc = FILE:/var/log/krb5kdc.log
 admin_server = FILE:/var/log/kadmind.log

[libdefaults]
 default_realm = HADOOP.LOCALDOMAIN
 dns_lookup_realm = false
 dns_lookup_kdc = false
 ticket_lifetime = 1d
 renew_lifetime = 7d
 forwardable = yes
 proxiable = yes
 udp_preference_limit = 1
 extra_addresses = 127.0.0.1
 kdc_timesync = 1
 ccache_type = 4

[realms]
 HADOOP.LOCALDOMAIN = {
  kdc = ${MASTER_HOST}:88
  admin_server = ${MASTER_HOST}:749
 }

[domain_realm]
 localhost = HADOOP.LOCALDOMAIN
 .compute-1.internal = HADOOP.LOCALDOMAIN
 .us-west-1.compute-1.internal = HADOOP.LOCALDOMAIN
 .internal = HADOOP.LOCALDOMAIN
 internal = HADOOP.LOCALDOMAIN

[appdefaults]
 pam = {
  debug = false
  ticket_lifetime = 36000
  renew_lifetime = 36000
  forwardable = true
  krb4_convert = false
 }

[login]
 krb4_convert = true
 krb4_get_tickets = false
EOF
KDC_MASTER_PASS="EiSei0Da"
KDC_ADMIN_PASS="Chohpet6"
if [ "$IS_MASTER" = "true" ]; then
  kadmin_setup $KDC_MASTER_PASS $KDC_ADMIN_PASS $MASTER_HOST
  yum -y install openldap-servers
fi
keytab="$HADOOP_HOME/conf/nn.keytab"
add_client "hadoop/admin" $KDC_ADMIN_PASS $keytab $HOSTNAME
yum -y install openldap-clients cyrus-sasl-gssapi pam-krb5 nss-pam-ldapd
chown hadoop:hadoop $keytab
if [ "$IS_MASTER" = "true" ]; then
 cd /usr/local/hadoop-*; kinit -k -t conf/nn.keytab hadoop/$HOSTNAME
fi
umount /mnt
umount /media/ephemeral0
mkfs.xfs -f /dev/sdb
mount -o noatime /dev/sdb /mnt
mkdir -p /mnt/hadoop/dfs/data /mnt/mapred/local /mnt/hadoop/logs /mnt/hbase/logs
chmod 01777 /mnt/hadoop/logs
chown -R $HADOOP_SECURE_USER:root /mnt/hadoop /mnt/mapred /mnt/hbase
DFS_NAME_DIR="/mnt/hadoop/dfs/name"
DFS_DATA_DIR="/mnt/hadoop/dfs/data"
MAPRED_LOCAL_DIR="/mnt/mapred/local"
i=2
for d in c d e f g h i j k l m n o p q r s t u v w x y z; do
 m="/mnt${i}"
 mkdir -p $m && mkfs.xfs -f /dev/xvd${d}
 if [ $? -eq 0 ] ; then
  mount -o noatime /dev/xvd${d} $m > /dev/null 2>&1
  if [ $i -lt 3 ] ; then # no more than two namedirs
   DFS_NAME_DIR="${DFS_NAME_DIR},${m}/hadoop/dfs/name"
  fi
  mkdir -p ${m}/hadoop/dfs/data
  DFS_DATA_DIR="${DFS_DATA_DIR},${m}/hadoop/dfs/data"
  mkdir -p ${m}/mapred/local
  MAPRED_LOCAL_DIR="${MAPRED_LOCAL_DIR},${m}/mapred/local"
  chown -R $HADOOP_SECURE_USER:root ${m}/hadoop ${m}/mapred
  i=$(( i + 1 ))
 fi
done
if [ "$IS_MASTER" = "true" ]; then
 sed -i -e "s|\( *mcast_join *=.*\)|#\1|" \
  -e "s|\( *bind *=.*\)|#\1|" \
  -e "s|\( *mute *=.*\)|  mute = yes|" \
  -e "s|\( *location *=.*\)|  location = \"master-node\"|" \
  /etc/gmond.conf
 mkdir -p /mnt/ganglia/rrds
 chown -R ganglia:ganglia /mnt/ganglia/rrds
 rm -rf /var/lib/ganglia; cd /var/lib; ln -s /mnt/ganglia ganglia; cd
 service gmond start
 service gmetad start
 apachectl start
else
 sed -i -e "s|\( *mcast_join *=.*\)|#\1|" \
  -e "s|\( *bind *=.*\)|#\1|" \
  -e "s|\(udp_send_channel {\)|\1\n  host=$MASTER_HOST|" \
  /etc/gmond.conf
 service gmond start
fi
cat >> $HADOOP_HOME/conf/hadoop-env.sh <<EOF
export HADOOP_OPTS="\$HADOOP_OPTS -Djavax.security.auth.useSubjectCredsOnly=false"
export HADOOP_NAMENODE_USER=$HADOOP_SECURE_USER
export HADOOP_SECONDARYNAMENODE_USER=$HADOOP_SECURE_USER
export HADOOP_DATANODE_USER=$HADOOP_SECURE_USER
export HADOOP_JOBTRACKER_USER=$HADOOP_SECURE_USER
export HADOOP_TASKTRACKER_USER=$HADOOP_SECURE_USER
EOF
( cd /usr/local && ln -s $HADOOP_HOME hadoop ) || true
cat > $HADOOP_HOME/conf/core-site.xml <<EOF
<?xml version="1.0"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
<property>
 <name>hadoop.tmp.dir</name>
 <value>/mnt/hadoop</value>
</property>
<property>
 <name>fs.default.name</name>
 <value>hdfs://$MASTER_HOST:8020</value>
</property>
<property>
 <name>hadoop.security.authorization</name>
 <value>true</value>
</property>
<property>
 <name>hadoop.security.authentication</name>
 <value>kerberos</value>
</property>
</configuration>
EOF
cat > $HADOOP_HOME/conf/hdfs-site.xml <<EOF
<?xml version="1.0"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
<property>
 <name>fs.default.name</name>
 <value>hdfs://$MASTER_HOST:8020</value>
</property>
<property>
 <name>dfs.name.dir</name>
 <value>$DFS_NAME_DIR</value>
</property>
<property>
 <name>dfs.data.dir</name>
 <value>$DFS_DATA_DIR</value>
</property>
<property>
 <name>dfs.support.append</name>
 <value>true</value>
</property>
<property>
 <name>dfs.replication</name>
 <value>3</value>
</property>
<property>
 <name>dfs.block.size</name>
 <value>67108864</value>
</property>
<property>
 <name>dfs.datanode.handler.count</name>
 <value>100</value>
</property>
<property>
 <name>dfs.datanode.max.xcievers</name>
 <value>10000</value>
</property>
<property>
 <name>dfs.datanode.socket.write.timeout</name>
 <value>0</value>
</property>
<property>
 <name>dfs.https.port</name>
 <value>50475</value>
</property>
<property>
 <name>dfs.datanode.failed.volumes.tolerated</name>
 <value>2</value>
</property>
<property>
 <name>dfs.namenode.keytab.file</name>
 <value>$HADOOP_HOME/conf/nn.keytab</value>
</property>	
<property>
 <name>dfs.namenode.kerberos.principal</name>
 <value>hadoop/$MASTER_HOST@HADOOP.LOCALDOMAIN</value>
</property>
<property>
 <name>dfs.namenode.kerberos.https.principal</name>
 <value>hadoop/$MASTER_HOST@HADOOP.LOCALDOMAIN</value>
</property>
<property>
 <name>dfs.secondary.https.port</name>
 <value>50495</value>
</property>	
<property>
 <name>dfs.secondary.namenode.keytab.file</name>
 <value>$HADOOP_HOME/conf/nn.keytab</value>
</property>	
<property>
 <name>dfs.secondary.namenode.kerberos.principal</name>
 <value>hadoop/$MASTER_HOST@HADOOP.LOCALDOMAIN</value>
</property>
<property>
 <name>dfs.secondary.namenode.kerberos.https.principal</name>
 <value>hadoop/$MASTER_HOST@HADOOP.LOCALDOMAIN</value>
</property>
<property>
 <name>dfs.datanode.keytab.file</name>
 <value>$HADOOP_HOME/conf/nn.keytab</value>
</property>	
<property>
 <name>dfs.datanode.kerberos.principal</name>
 <value>hadoop/$HOSTNAME@HADOOP.LOCALDOMAIN</value>
</property>
<property>
 <name>dfs.datanode.kerberos.https.principal</name>
 <value>hadoop/$HOSTNAME@HADOOP.LOCALDOMAIN</value>
</property>
<property>
 <name>dfs.datanode.require.secure.ports</name>
 <value>false</value>
</property>
<property>
 <name>dfs.block.access.token.enable</name>
 <value>true</value>
</property>
</configuration>
EOF
cat > $HADOOP_HOME/conf/mapred-site.xml <<EOF
<?xml version="1.0"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
<property>
 <name>mapred.job.tracker</name>
 <value>$MASTER_HOST:8021</value>
</property>
<property>
 <name>mapreduce.jobtracker.keytab.file</name>
 <value>$HADOOP_HOME/conf/nn.keytab</value>
</property>	
<property>
 <name>mapreduce.jobtracker.kerberos.principal</name>
 <value>hadoop/$MASTER_HOST@HADOOP.LOCALDOMAIN</value>
</property>
<property>
 <name>mapreduce.jobtracker.kerberos.https.principal</name>
 <value>hadoop/$MASTER_HOST@HADOOP.LOCALDOMAIN</value>
</property>
<property>
 <name>mapreduce.tasktracker.keytab.file</name>
 <value>$HADOOP_HOME/conf/nn.keytab</value>
</property>	
<property>
 <name>mapreduce.tasktracker.kerberos.principal</name>
 <value>hadoop/$HOSTNAME@HADOOP.LOCALDOMAIN</value>
</property>
<property>
 <name>mapreduce.tasktracker.kerberos.https.principal</name>
 <value>hadoop/$HOSTNAME@HADOOP.LOCALDOMAIN</value>
</property>
<property>
 <name>mapred.tmp.dir</name>
 <value>/tmp/mapred</value>
</property>
<property>
 <name>mapred.local.dir</name>
 <value>$MAPRED_LOCAL_DIR</value>
</property>
<property>
 <name>mapred.system.dir</name>
 <value>/mapred/system</value>
</property>
<property>
 <name>mapred.acls.enabled</name>
 <value>true</value>
</property>
<property>
 <name>mapreduce.cluster.job-authorization-enabled</name>
 <value>true</value>
</property>
<property>
 <name>mapreduce.job.acl-modify-job</name>
 <value></value>
</property>
<property>
 <name>mapreduce.job.acl-view-job</name>
 <value></value>
</property>
<property>
 <name>mapred.map.tasks</name>
 <value>4</value>
</property>
</configuration>
EOF
cat >> $HADOOP_HOME/conf/hadoop-env.sh <<EOF
export JAVA_HOME=/usr/local/jdk
EOF
cat >> $HADOOP_HOME/conf/hadoop-env.sh <<EOF
export HADOOP_CLASSPATH="$HBASE_HOME/hbase-${HBASE_VERSION}.jar:$HBASE_HOME/lib/zookeeper-3.3.2.jar:$HBASE_HOME/conf"
export HADOOP_NAMENODE_OPTS="-Xms4000m -Xmx4000m -XX:+UseMembar -XX:+UseConcMarkSweepGC -XX:+CMSParallelRemarkEnabled -XX:+UseParNewGC -verbose:gc -XX:+PrintGCDetails -XX:+PrintGCDateStamps"
export HADOOP_SECONDARYNAMENODE_OPTS="\$HADOOP_NAMENODE_OPTS -Xloggc:/mnt/hadoop/logs/hadoop-secondarynamenode-gc.log"
export HADOOP_NAMENODE_OPTS="\$HADOOP_NAMENODE_OPTS -Xloggc:/mnt/hadoop/logs/hadoop-namenode-gc.log"
export HADOOP_DATANODE_OPTS="-Xms1000m -Xmx1000m -XX:+UseMembar -XX:+UseConcMarkSweepGC -XX:+CMSParallelRemarkEnabled -XX:+UseParNewGC"
EOF
cat > $HADOOP_HOME/conf/hadoop-metrics.properties <<EOF
dfs.class=org.apache.hadoop.metrics.ganglia.GangliaContext
dfs.period=10
dfs.servers=$MASTER_HOST:8649
jvm.class=org.apache.hadoop.metrics.ganglia.GangliaContext
jvm.period=10
jvm.servers=$MASTER_HOST:8649
mapred.class=org.apache.hadoop.metrics.ganglia.GangliaContext
mapred.period=10
mapred.servers=$MASTER_HOST:8649
EOF
( cd /usr/local && ln -s $HBASE_HOME hbase ) || true
cat > $HBASE_HOME/conf/hbase-site.xml <<EOF
<?xml version="1.0"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
<property>
 <name>hbase.rootdir</name>
 <value>hdfs://$MASTER_HOST:8020/hbase</value>
</property>
<property>
 <name>hbase.cluster.distributed</name>
 <value>true</value>
</property>
<property>
 <name>hbase.zookeeper.quorum</name>
 <value>$ZOOKEEPER_QUORUM</value>
</property>
<property>
 <name>hadoop.security.authorization</name>
 <value>true</value>
</property>
<property>
 <name>hadoop.security.authentication</name>
 <value>kerberos</value>
</property>
<property>
 <name>hbase.hregion.majorcompaction</name>
 <value>0</value>
</property>
<property>
 <name>hbase.hregion.max.filesize</name>
 <value>671088640</value>
</property>
<property>
 <name>hbase.regionserver.handler.count</name>
 <value>100</value>
</property>
<property>
 <name>hbase.hregion.memstore.block.multiplier</name>
 <value>8</value>
</property>
<property>
 <name>hbase.hstore.blockingStoreFiles</name>
 <value>25</value>
</property>
<property>
 <name>hbase.client.keyvalue.maxsize</name>
 <value>52428800</value>
</property>
<property>
 <name>hbase.client.write.buffer</name>
 <value>10485760</value>
</property>
<property>
 <name>zookeeper.session.timeout</name>
 <value>600000</value>
</property>
<property>
 <name>hbase.tmp.dir</name>
 <value>/mnt/hbase</value>
</property>
<!-- default scanner caching is 1, this is terrible for performance -->
<property>
 <name>hbase.client.scanner.caching</name>
 <value>100</value>
</property>
<!-- we want to decouple store latency from HDFS load, so a small window of
  possible data loss is acceptable as a trade off: up to 10 seconds, or up
  to 100 entries -->
<property>
 <name>hbase.regionserver.optionallogflushinterval</name>
 <value>10000</value>
</property>
<property>
 <name>hbase.regionserver.flushlogentries</name>
 <value>100</value>
</property>
<property>
 <name>hbase.master.keytab.file</name>
 <value>$HADOOP_HOME/conf/nn.keytab</value>
</property>	
<property>
 <name>hbase.master.kerberos.principal</name>
 <value>hbase/_HOST@HADOOP.LOCALDOMAIN</value>
</property>
<property>
 <name>hbase.master.kerberos.https.principal</name>
 <value>hbase/_HOST@HADOOP.LOCALDOMAIN</value>
</property>
<property>
 <name>hbase.regionserver.keytab.file</name>
 <value>$HADOOP_HOME/conf/nn.keytab</value>
</property>	
<property>
 <name>hbase.regionserver.kerberos.principal</name>
 <value>hbase/_HOST@HADOOP.LOCALDOMAIN</value>
</property>
<property>
 <name>hbase.regionserver.kerberos.https.principal</name>
 <value>hbase/_HOST@HADOOP.LOCALDOMAIN</value>
</property>
</configuration>
EOF
cat > $HBASE_HOME/conf/hadoop-policy.xml <<EOF
<?xml version="1.0"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
<property>
 <name>security.client.protocol.acl</name>
 <value>*</value>
</property>
<property>
 <name>security.admin.protocol.acl</name>
 <value>*</value>
</property>
<property>
 <name>security.masterregion.protocol.acl</name>
 <value>*</value>
</property>
</configuration>
EOF
ln -s $HADOOP_HOME/conf/core-site.xml $HBASE_HOME/conf
ln -s $HADOOP_HOME/conf/hdfs-site.xml $HBASE_HOME/conf
ln -s $HADOOP_HOME/conf/mapred-site.xml $HBASE_HOME/conf
cat >> $HBASE_HOME/conf/hbase-env.sh <<EOF
export JAVA_HOME=/usr/local/jdk
export HBASE_MASTER_HEAPSIZE=2000
export HBASE_MASTER_OPTS="-XX:+UseMembar -verbose:gc -XX:+PrintGCDetails -XX:+PrintGCDateStamps -Xloggc:/mnt/hbase/logs/hbase-master-gc.log"
export HBASE_REGIONSERVER_HEAPSIZE=4000
export HBASE_REGIONSERVER_OPTS="-XX:+UseMembar -verbose:gc -XX:+PrintGCDetails -XX:+PrintGCDateStamps -Xloggc:/mnt/hbase/logs/hbase-regionserver-gc.log"
EOF
sed -i -e "s/hadoop.hbase=DEBUG/hadoop.hbase=$LOG_SETTING/g" $HBASE_HOME/conf/log4j.properties
cat > $HBASE_HOME/conf/hadoop-metrics.properties <<EOF
dfs.class=org.apache.hadoop.metrics.ganglia.GangliaContext
dfs.period=10
dfs.servers=$MASTER_HOST:8649
hbase.class=org.apache.hadoop.metrics.ganglia.GangliaContext
hbase.period=10
hbase.servers=$MASTER_HOST:8649
jvm.class=org.apache.hadoop.metrics.ganglia.GangliaContext
jvm.period=10
jvm.servers=$MASTER_HOST:8649
webtable.class=org.apache.hadoop.metrics.ganglia.GangliaContext
webtable.period=10
webtable.servers=$MASTER_HOST:8649
EOF
rm -f /var/ec2/ec2-run-user-data.*
