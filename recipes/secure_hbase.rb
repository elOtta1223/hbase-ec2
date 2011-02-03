version = "0.90-tm-5"

options = {
  :label => "hbase-#{version}-x86_64",
  :master_instance_type => "m1.large",
  :rs_instance_type => "c1.xlarge",
  :zk_instance_type => "m1.large",
  :num_zookeepers => 1,
  :num_regionservers => 3,
  :security_group_prefix => "hcluster",
  :debug_level => 1,
  :hbase_debug_level => "INFO",
  :owner_id => '801535628028'
}

@cluster = Hadoop::SecureCluster
cluster = @cluster.new options

cluster.launch

# Print cluster info and exit
s = "MASTER: #{cluster.master.dnsName}\n"
s += "SECONDARY: #{cluster.secondary.dnsName}\n" 
cluster.zks.each {|inst| s += "ZK: #{inst.dnsName}\n"}
cluster.slaves.each {|inst| s += "SLAVE: #{inst.dnsName}\n"}
cluster.aux.each {|inst| s += "AUX: #{inst.dnsName}\n"}
print s
