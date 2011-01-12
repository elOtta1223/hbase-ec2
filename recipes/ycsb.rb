
# start HBase cluster at EC2

ycsbTestOptions = {
  :emailTo => ["mingjie_lai@trendmicro.com"],
  :emailFrom =>  "ycsb.hbase@gmail.com",  
  :localProcessDir => "/tmp/ycsb",
  :remoteYcsbDir => "/mnt/ycsb",
  :testRecordCount => "10000000",
  :testOperationCount => "10000000",
  :testThreadNumber => "10",
  :smtpServer => "smtp.gmail.com",
  :smtpAccount => "ycsb.hbase",
  :smtpPassword => "Qazwsx123_",
  # a customized ycsb, containing a run script and modified logic.
  :ycsbURL => "https://s3.amazonaws.com/mlai.hadoop.tarballs/ycsb.tar"  
}

#  ["apurtell@apache.org",
#    "gary_helmling@trendmicro.com",
#    "eugene_koontz@trendmicro.com",
#    "mingjie_lai@trendmicro.com"]

GitOptions = {
  # check scm, to determine whether there is code changes since last
  # time. true: check scm and rebuild jar, if there is changes, rebuild
  # jar and use the new jar. false: to perform tests without scm check. 
  :checkSCMChanges => false,
  :gitWorkDir => "/home/mlai/git/hbase.asf",
  :gitCOBranch => "tm-5",
  :gitCheckLogSince => "1",
  :gitRemote => "origin",
  :gitRepo => "git@mothership.iridiant.net:hbase.git",
  :jarFileName => "hbase-0.90-tm-5.jar"
}

ClusterOptions = {
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

@ycsb = Hadoop::YcsbCluster

cluster = @ycsb.new ClusterOptions

launchOptions = {
  :availability_zone => 'us-east-1c',
  :uploadHBaseJar => ''
}

#if there is scm changes
localJarPath = ''

if (GitOptions[:checkSCMChanges]) 
  begin
    if (isHBaseChanged(GitOptions[:gitWorkDir],
        GitOptions[:gitRepo],      
        GitOptions[:gitRemote],  
        GitOptions[:gitCOBranch], 
        GitOptions[:gitCheckLogSince]))
          
      p "Source code changed since " + GitOptions[:gitCheckLogSince] +
        " days ago. Rebuild jar and use it to perform the test."
      # rebuild hbase jar and upload to cluster later on    
      
      localJarPath = buildNewHBaseJar(GitOptions[:gitWorkDir])
      p "Built a new hbase jar at: " + localJarPath

      # start cluster with a new hbase jar to be uploaded. 
      launchOptions[:uploadHBaseJar] = localJarPath
      cluster.launch launchOptions
      
    else
      puts "No git change. Don't need to run tests."
      exit
    end 
        
    rescue => e
      p "Check git failed. Exit."
      exit
  end
else
  # start cluster, get hbase information from downloaded jar files.
  # start cluster with default hbase jars.
  cluster.launch launchOptions
  localJarPath = getLocalHBasePath
  
  #TODO: test the  above if block
  
  
end

cluster.test ycsbTestOptions      

cluster.terminate
