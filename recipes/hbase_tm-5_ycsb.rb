# to make sure it can run, you need to install all dependencies:
# gem install net-ssh
# gem install net-scp
# gem install amazon-ec2
# gem install aws-s3
# gem install git
# gem install aws
# 
# maven
# git

$ycsbTestOptions = {
  :emailTo => ["mingjie_lai@trendmicro.com"],
  :emailFrom =>  "ycsb.hbase@gmail.com",  
  :localProcessDir => "/tmp/ycsb",
  :remoteYcsbDir => "/mnt/ycsb",
  :testRecordCount => "1000000",
  :testOperationCount => "1000000",
  :testThreadNumber => "10",
  :smtpServer => "smtp.gmail.com",
  :smtpAccount => "ycsb.hbase",
  :smtpPassword => "Qazwsx123_",
  # check scm, to determine whether there is code changes since last
  # time. true: check scm and rebuild jar, if there is changes, rebuild
  # jar and use the new jar. false: to perform tests without scm check. 
  :checkSCMChanges => false,
  :gitWorkDir => "/home/mlai/git/hbase.asf",
  :gitCOBranch => "tm-5",
  :gitCheckLogSince => "1",
  :gitRemote => "origin",
  :gitRepo => "git@mothership.iridiant.net:hbase.git",
  :jarFileName => "hbase-0.90-tm-5.jar",
  # a customized ycsb, containing a run script and modified logic.
  :ycsbURL => "https://s3.amazonaws.com/mlai.hadoop.tarballs/ycsb.tar"
  
}


# start HBase cluster at EC2
$ClusterOptions = {
  :label => 'hbase-0.90-tm-5-x86_64',
  :master_instance_type => "m1.large",
  :rs_instance_type => "c1.xlarge",
  :zk_instance_type => "m1.large",
  :num_zookeepers => 1,
  :num_regionservers => 10,
  :security_group_prefix => 'hcluster',
  :hbase_debug_level => 'INFO',
  :owner_id => '801535628028'
}

$cluster = @hcluster.new $ClusterOptions


#######################

def startCluster
  opt = {
    :availability_zone => 'us-east-1c'
  }  
  $cluster.launch opt
end

def startHadoop
  #
  # Initialize and start Hadoop (HDFS and MapReduce)
  #
  
  $cluster.ssh("cd /usr/local/hadoop-*; kinit -k -t conf/nn.keytab hadoop/#{$cluster.master.privateDnsName.downcase}; bin/hadoop namenode -format")
  
  $cluster.ssh("/usr/local/hadoop-*/bin/hadoop-daemon.sh start namenode")
  $cluster.slaves.each {|inst|
    $cluster.ssh_to(inst.dnsName,
      "/usr/local/hadoop-*/bin/hadoop-daemon.sh start datanode") }
  
  $cluster.ssh("cd /usr/local/hadoop-* ; bin/hadoop fs -mkdir /mapred/system; bin/hadoop fs -chown hadoop /mapred/system")
  
  $cluster.ssh("/usr/local/hadoop-*/bin/hadoop-daemon.sh start jobtracker")
  $cluster.slaves.each {|inst|
    $cluster.ssh_to(inst.dnsName,
      "/usr/local/hadoop-*/bin/hadoop-daemon.sh start tasktracker") }
end

def startHBase 
  #
  # Initialize and start HBase
  #
  $cluster.ssh("cd /usr/local/hadoop-* ; bin/hadoop fs -mkdir /hbase; bin/hadoop fs -chown hbase /hbase")
  
  $cluster.ssh("/usr/local/hbase-*/bin/hbase-daemon.sh start master")
  $cluster.slaves.each {|inst|
    $cluster.ssh_to(inst.dnsName,
      "/usr/local/hbase-*/bin/hbase-daemon.sh start regionserver") }
end

def stopHBase 
  #
  # Initialize and start HBase
  #
  $cluster.slaves.each {|inst|
    $cluster.ssh_to(inst.dnsName,
      "/usr/local/hbase-*/bin/hbase-daemon.sh stop regionserver") }
  $cluster.ssh("/usr/local/hbase-*/bin/hbase-daemon.sh stop master")
end


# this function needs to be called after the cluster started.
# it does: download jar from master, return the jar path name. 
def getLocalHBasePath
  jarDire = $ycsbTestOptions[:localProcessDir] + "/jar"
  
  %x[rm -rf #{jarDire}; mkdir -p #{jarDire}]
  
  Net::SCP.start($cluster.dnsName(),
    'root',
    :keys => ENV['EC2_ROOT_SSH_KEY'],
    :paranoid => false
    ) do |scp|
      scp.download! "/usr/local/hbase/#{$ycsbTestOptions[:jarFileName]}", jarDire
  end
  
  %x[cd #{jarDire}; jar xf #{$ycsbTestOptions[:jarFileName]}]
  
  jarDire += "/" + $ycsbTestOptions[:jarFileName]
  
  return jarDire if File.exists?(jarDire)
  return nil
end

def uploadHBaseJar(filePath)
  # TODO: make sure hbase is not running
  $cluster.scp(filePath, $cluster.dnsName + ":/usr/local/hbase/")
  $cluster.slaves.each {|inst|
      $cluster.scp(filePath, inst.dnsName + ":/usr/local/hbase/") }
end

# perform git checkin check, to see any changes during the last 

require 'git'

#######################

def isHBaseChanged(workDir, repo, remote, branch, sinceDaysAgo)
  changes = getGitChanges(workDir, repo, remote, branch, sinceDaysAgo)

rescue => e
  p "Get git status failed."
  raise
  return false
  
ensure
  
  if (changes!=nil && changes.length == 0)
    return false
  else
    p "Changes: " + changes
    return true
  end  
end

# check git changes for a given period of time. 
def getGitChanges(workDir, repo, remote, branch, sinceDaysAgo)
  # open an existing 
  g = Git.open(working_dir = workDir)
  
rescue => e
  p "Fail to open local work directory at " + workDir + ". " + 
    e.message + ". Try to clone from " + repo 
  g = Git.clone(repo, workDir)
  
ensure  
  g.pull(remote, branch)
  g.branch(branch)
  changes = g.log().since(sinceDaysAgo + ' days ago').to_s
  return changes
end

def buildNewHBaseJar(workDir)
  # 1. check out hbase from git
  p "Start to build new HBase jar...."
  #%x[cd #{wordDir}; mvn clean; mvn -DskipTests install]

  # 2. build hbase
  jarPath = "#{workDir}/target/#{$ycsbTestOptions[:jarFileName]}"
  
  return jarPath if File.exists?(jarPath)
  return nil
end



# Send results to email recipients thru SMTP
def sendResults(reportDetail)
  from = $ycsbTestOptions[:emailFrom] 
  to = $ycsbTestOptions[:emailTo] 
#  ["apurtell@apache.org",
#    "gary_helmling@trendmicro.com",
#    "eugene_koontz@trendmicro.com",
#    "mingjie_lai@trendmicro.com"]

  reportGenerateTime = Time.new
  formattedTime = reportGenerateTime.strftime("%Y-%m-%d %H:%M:%S")
  
message = <<MESSAGE_END
From: YCSB for HBase <#{from}>
To: #{to.join(", ")}
MIME-Version: 1.0
Content-type: text/html
Subject: YCSB test results #{formattedTime}

This is an automatic generated e-mail message. 
It's YCSB test results for HBase on EC2 which was generated at #{formattedTime}. 
<br>
#{reportDetail}
<br>
Please don\'t reply to this email.
MESSAGE_END
  
  smtp = Net::SMTP.new $ycsbTestOptions[:smtpServer], 587
  smtp.enable_starttls
  smtp.start('localhost',
    $ycsbTestOptions[:smtpAccount], $ycsbTestOptions[:smtpPassword],
    :login) do |smtp|
   smtp.send_message message, from, to
  end
end


def generateResultDetail()
  # untar the file
  %x[ cd #{$ycsbTestOptions[:localProcessDir]}; mkdir -p backup; mv results/* backup; rm -rf results; tar zxf results.tar.gz]
  
  resultsDir=$ycsbTestOptions[:localProcessDir] + "/results"
  reportDetail=""
  reportDetail += "<br><b>Test Summary: </b><br>\n"
  
  formattedTime = $testStartTime.strftime("%Y-%m-%d %H:%M:%S")
  reportDetail += "Test start time: #{formattedTime}<br>\n"
  
  formattedTime = $testEndTime.strftime("%Y-%m-%d %H:%M:%S")
  reportDetail += "Test end time: #{formattedTime}<br>\n"
  
  reportDetail += "# of RS: #{$ClusterOptions[:num_regionservers]}<br>\n"
  reportDetail += "HBase version: #{$HBaseVersion}<br>\n"
  reportDetail += "HBase compiled time: #{$HBaseBuiltTime}<br>\n"
  
  Dir.foreach(resultsDir) { |subdir| 
    if ( subdir =~ /\d+[-]\d+/ )
      reportDetail += "Test Details:<br>\n"
      i = 0
      Dir.foreach(resultsDir + "/" + subdir) { |file|
        if ( file =~ /.*.txt/)
          filePath = resultsDir + "/" + subdir + "/" + file
          if (File.exist?(filePath))
            i+=1
            reportDetail += "<hr><br><b>Test #{i}</b><br>\n"
                      
            #extract useful info:
            File.open(filePath, "r") do |infile|
              # assume we need all contents from the result files.
              while (line = infile.gets)
                reportDetail += line + "<br>\n"
              end
            end
          end
        end
      }
    end
  } 
  return reportDetail
end


localJarPath = ""
clusterStartTime = Time.new


if ($ycsbTestOptions[:checkSCMChanges]) 
  begin
    if (isHBaseChanged($ycsbTestOptions[:gitWorkDir],
        $ycsbTestOptions[:gitRepo],      
        $ycsbTestOptions[:gitRemote],  
        $ycsbTestOptions[:gitCOBranch], 
        $ycsbTestOptions[:gitCheckLogSince]))
          
      p "Source code changed since " + $ycsbTestOptions[:gitCheckLogSince] +
        " days ago. Rebuild jar and use it to perform the test."
      # rebuild hbase jar and upload to cluster later on    
      localJarPath = buildNewHBaseJar($ycsbTestOptions[:gitWorkDir])
       
      # start cluster, upload built hbase jars, get hbase info 
      
      # start cluster
      startCluster
      startHadoop
      
      # upload to all nodes        
      uploadHBaseJar(localJarPath)
      startHBase
    else
      puts "No git changes. Don't need to run times."
      exit
    end 
        
    rescue => e
      p "Check git failed. Exit."
      exit  
  end
else
  # start cluster, get hbase information from downloaded jar files.
  # start cluster
  startCluster
  startHadoop
  startHBase
  localJarPath = getLocalHBasePath
end

##############################################
# run ycsb
# blindly wait 2 mins to make sure hbase starts
puts("Sleep 120 secs ... ")
sleep 20
puts("Start to run ycsb ...")

require 'net/smtp'

$testStartTime = Time.new
# 1. run ycsb test
$cluster.ssh(". /usr/local/hbase/conf/hbase-env.sh; rm -rf #{$ycsbTestOptions[:remoteYcsbDir]};" +
  "mkdir -p #{$ycsbTestOptions[:remoteYcsbDir]}; cd #{$ycsbTestOptions[:remoteYcsbDir]}; " +
  "wget -nv #{$ycsbTestOptions[:ycsbURL]}; " +
  "tar xfP ycsb.tar;" + 
  "cd ycsb; chmod +x run-test.sh;" +
  "#{$ycsbTestOptions[:remoteYcsbDir]}/ycsb/run-test.sh " + 
  "-p recordcount=#{$ycsbTestOptions[:testRecordCount]} " + 
  "-p operationcount=#{$ycsbTestOptions[:testOperationCount]} " + 
  "-threads #{$ycsbTestOptions[:testThreadNumber]} " + 
  "-p measurementtype=timeseries -p timeseries.granularity=60000 -p basicdb.verbose=false;" +
  "tar cfz #{$ycsbTestOptions[:remoteYcsbDir]}/results.tar.gz results;") 

$testEndTime = Time.new

# 2. download the results files locally.

%x[mkdir -p #{$ycsbTestOptions[:localProcessDir]}; ]
Net::SCP.start($cluster.dnsName(),
  'root',
  :keys => ENV['EC2_ROOT_SSH_KEY'],
  :paranoid => false
  ) do |scp|
    scp.download! "#{$ycsbTestOptions[:remoteYcsbDir]}/results.tar.gz", $ycsbTestOptions[:localProcessDir]
end

# 3. generate email contents
resultDetail = generateResultDetail()

# 4. send email. 
sendResults(resultDetail)

# terminate the cluster
$cluster.terminate()
