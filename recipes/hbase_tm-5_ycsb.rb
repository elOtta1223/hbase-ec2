
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

# run ycsb
    
puts("Sleep 5 secs ...cluster ")
sleep 5 
puts("Start to run ycsb ...")

cluster.ssh(". /usr/local/hbase/conf/hbase-env.sh; cd /usr/local; " +
  "rm -rf /usr/local/ycsb*;" + 
  "wget -nv https://s3.amazonaws.com/mlai.hadoop.tarballs/ycsb.tar; " +
  "tar xfP ycsb.tar;" + 
  "cd ycsb; chmod +x run-test.sh;" +
  "/usr/local/ycsb/run-test.sh -p recordcount=12300 -threads 10 " + 
  "-p measurementtype=timeseries -p timeseries.granularity=2000;" +
  "tar cfz /tmp/results.tar.gz results;") 

#cluster.ssh(". /usr/local/hbase/conf/hbase-env.sh; cd /usr/local; " +
#  "cd ycsb; chmod +x run-test.sh;" +
#  "/usr/local/ycsb/run-test.sh -p recordcount=123 -threads 10 -target 100 " + 
#  "-p measurementtype=timeseries -p timeseries.granularity=20;" +
#  "tar cfz /tmp/results.tar.gz results;") 

# download the results files locally.
localProcessDir="/tmp"
Net::SCP.start(cluster.dnsName(),
  'root',
  :keys => ENV['EC2_ROOT_SSH_KEY'],
  :paranoid => false
  ) do |scp|
    scp.download! "/tmp/results.tar.gz", localProcessDir
end

# send email now. ideally we can parse the result files and 
# insert the results to a DB, and display it in charts.
require 'net/smtp'

# you need to install smtp server locally to send email from localhost.

# untar the file
%x[cd #{localProcessDir}; tar zxf results.tar.gz]

resultsDir=localProcessDir + "/results"


# we need:
runTime = ""
throughput = ""
opsNumber = ""
command = ""
averageLatency = ""
minLatency = ""
maxLatency = ""
return0 = ""

reportDetail=""
Dir.foreach(resultsDir) { |subdir| 
  if ( subdir =~ /\d+[-]\d+/ )
    testStartTime = subdir
    reportDetail += "<br>Test Summary: <br>\n" +
      "start time: #{testStartTime}<br>\n" +
      "number of RS: #{options[:num_regionservers]}<br>\n"
      
    reportDetail += "Test Details:<br>\n"
    i = 0
    Dir.foreach(resultsDir + "/" + subdir) { |file|
      if ( file =~ /.*.txt/)
        filePath = resultsDir + "/" + subdir + "/" + file
        if (File.exist?(filePath))
          i+=1
          runTime = ""
          throughput = ""
          opsNumber = ""
          command = ""
          averageLatency = ""
          minLatency = ""
          maxLatency = ""
          return0 = ""
          
          #extract useful info:
          File.open(filePath, "r") do |infile|
            while (line = infile.gets)
              # break if it passes the first several lines
              
              if line =~ /[\[].*[\]],[ ]*\d+,[. \d]*/
                break
              elsif line =~ /[\[]OVERALL[\]],[ ]*RunTime/
                runTime = line
              elsif line =~ /[\[]OVERALL[\]],[ ]*Throughput/
                throughput = line
              elsif line =~ /[\[].*[\]],[ ]*Operations/
                opsNumber = line
              elsif line =~ /[\[].*[\]],[ ]*AverageLatency/
                averageLatency = line
              elsif line =~ /[\[].*[\]],[ ]*MinLatency/
                minLatency = line
              elsif line =~ /[\[].*[\]],[ ]*MaxLatency/
                maxLatency = line
              elsif line =~ /[\[].*[\]],[ ]*Return=0/
                return0 = line
              elsif line =~ /Command line:/
                command = line
              else
                puts "ignored lines: #{line}"
              end
            end
          end

          reportDetail += "<br>Test #{i}<br>\n"
          reportDetail += "command: #{command}<br>\n"
          reportDetail += "runTime: #{runTime}<br>\n"
          reportDetail += "throughput: #{throughput}<br>\n"
          reportDetail += "opsNumber: #{opsNumber}<br>\n"
          reportDetail += "averageLatency: #{averageLatency}<br>\n"
          reportDetail += "minLatency: #{minLatency}<br>\n"
          reportDetail += "maxLatency: #{maxLatency}<br>\n"
          reportDetail += "return0: #{return0}<br>\n"
        end
      end
    }
  end
}
puts reportDetail 

# the lines we have interests:
#Command line: -load -db com.yahoo.ycsb.db.HBaseClient -P /usr/local/ycsb/workloads/workloada -p colum
#...
#[OVERALL], RunTime(ms), 2082.0
#[OVERALL], Throughput(ops/sec), 59.07780979827089
#[INSERT], Operations, 120
#[INSERT], AverageLatency(ms), 3.925
#[INSERT], MinLatency(ms), 0
#[INSERT], MaxLatency(ms), 69
#[INSERT], Return=0, 120


from="ycsb_hbase@test"
to="mingjie@gmail.com"
reportGenerateTime=Time.new
formattedTime=reportGenerateTime.strftime("%Y-%m-%d %H:%M:%S")

message = <<MESSAGE_END
From: YCSB for HBase <#{from}>
To: #{to} <#{to}>
MIME-Version: 1.0
Content-type: text/html
Subject: YCSB test results #{formattedTime}

This is an e-mail message to be sent for the YCSB test results for HBase, 
which was generated at #{formattedTime}. 
<br>
#{reportDetail}
<br>
Please don\'t reply to this email.
MESSAGE_END

Net::SMTP.start('localhost') do |smtp|
  smtp.send_message message, from, to
end


cluster.terminate()
