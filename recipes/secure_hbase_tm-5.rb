options = {
  :label => 'hbase-0.90-tm-5-x86_64',
  :master_instance_type => "m1.large",
  :rs_instance_type => "c1.xlarge",
  :zk_instance_type => "m1.large",
  :num_zookeepers => 1,
  :num_regionservers => 3,
  :security_group_prefix => 'hcluster',
  :hbase_debug_level => 'INFO',
  :owner_id => '801535628028'
}
cluster = @hcluster.new options
cluster.launch 

#
# Initialize and start Hadoop (HDFS and MapReduce)
#

cluster.ssh("cd /usr/local/hadoop-*; kinit -k -t conf/nn.keytab hadoop/#{cluster.master.privateDnsName.downcase}; bin/hadoop namenode -format")

cluster.ssh("/usr/local/hadoop-*/bin/hadoop-daemon.sh start namenode")
cluster.slaves.each {|inst|
  cluster.ssh_to(inst.dnsName,
    "/usr/local/hadoop-*/bin/hadoop-daemon.sh start datanode") }

cluster.ssh("cd /usr/local/hadoop-* ; bin/hadoop fs -mkdir /mapred/system; bin/hadoop fs -chown hadoop /mapred/system")

cluster.ssh("/usr/local/hadoop-*/bin/hadoop-daemon.sh start jobtracker")
cluster.slaves.each {|inst|
  cluster.ssh_to(inst.dnsName,
    "/usr/local/hadoop-*/bin/hadoop-daemon.sh start tasktracker") }

#
# Initialize and start HBase
#

cluster.ssh("cd /usr/local/hadoop-* ; bin/hadoop fs -mkdir /hbase; bin/hadoop fs -chown hbase /hbase")

cluster.ssh("/usr/local/hbase-*/bin/hbase-daemon.sh start master")
cluster.slaves.each {|inst|
  cluster.ssh_to(inst.dnsName,
    "/usr/local/hbase-*/bin/hbase-daemon.sh start regionserver") }
