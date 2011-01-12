require 'hcluster.rb'
require 'net/smtp'

module Hadoop

class YcsbCluster < HCluster
      
  def startHadoop
    #
    # Initialize and start Hadoop (HDFS and MapReduce)
    #
    
    ssh("cd /usr/local/hadoop-*; kinit -k -t conf/nn.keytab hadoop/#{master.privateDnsName.downcase}; bin/hadoop namenode -format")
    
    ssh("/usr/local/hadoop-*/bin/hadoop-daemon.sh start namenode")
    slaves.each {|inst|
      ssh_to(inst.dnsName,
        "/usr/local/hadoop-*/bin/hadoop-daemon.sh start datanode") }
    
    ssh("cd /usr/local/hadoop-* ; bin/hadoop fs -mkdir /mapred/system; bin/hadoop fs -chown hadoop /mapred/system")
    
    ssh("/usr/local/hadoop-*/bin/hadoop-daemon.sh start jobtracker")
    slaves.each {|inst|
      ssh_to(inst.dnsName,
        "/usr/local/hadoop-*/bin/hadoop-daemon.sh start tasktracker") }
  end
  
  def startHBase 
    #
    # Initialize and start HBase
    #
    ssh("cd /usr/local/hadoop-* ; bin/hadoop fs -mkdir /hbase; bin/hadoop fs -chown hbase /hbase")
    
    ssh("/usr/local/hbase-*/bin/hbase-daemon.sh start master")
    slaves.each {|inst|
      ssh_to(inst.dnsName,
        "/usr/local/hbase-*/bin/hbase-daemon.sh start regionserver") }
  end
  
  def stopHBase 
    #
    # Initialize and start HBase
    
    slaves.each {|inst|
      ssh_to(inst.dnsName,
        "/usr/local/hbase-*/bin/hbase-daemon.sh stop regionserver") }
    ssh("/usr/local/hbase-*/bin/hbase-daemon.sh stop master")
  end

  def uploadHBaseJar(filePath)
    # TODO: make sure hbase is not running
    scp(filePath, dnsName + ":/usr/local/hbase/")
    slaves.each {|inst|
        scp(filePath, inst.dnsName + ":/usr/local/hbase/") }
  end
  
  def launch(options = {})
    super(options)
    
    startHadoop
    
    uploadHBaseJar(options[:uploadHBaseJar]) if File.exists?(uploadHBaseJar)
    
    startHBase
  end

  # Send results to email recipients thru SMTP
  def sendResults(reportDetail)
    from = options[:emailFrom] 
    to = options[:emailTo]
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
    
    smtp = Net::SMTP.new options[:smtpServer], 587
    smtp.enable_starttls
    smtp.start('localhost',
      options[:smtpAccount], options[:smtpPassword],
      :login) do |smtp|
     smtp.send_message message, from, to
    end
  end
  
  
  def generateResultDetail(options, testStartTime, testEndTime,
    builtTime, buildNumber)
    # untar the file
    %x[ cd #{options[:localProcessDir]}; mkdir -p backup; mv results/* backup; rm -rf results; tar zxf results.tar.gz]
    
    resultsDir=options[:localProcessDir] + "/results"
    reportDetail=""
    reportDetail += "<br><b>Test Summary: </b><br>\n"
    
    formattedTime = testStartTime.strftime("%Y-%m-%d %H:%M:%S")
    reportDetail += "Test start time: #{formattedTime}<br>\n"
    
    formattedTime = testEndTime.strftime("%Y-%m-%d %H:%M:%S")
    reportDetail += "Test end time: #{formattedTime}<br>\n"
    
    reportDetail += "# of RS: #{@num_regionservers}<br>\n"
    reportDetail += "HBase version: #{buildNumber}<br>\n"
    reportDetail += "HBase compiled time: #{builtTime}<br>\n"
    
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

    
  # perform test and analyze the results (including sending emails) 
  def test(options = {})
    # perform test
    testStartTime = Time.new
    # 1. run ycsb test
    ssh(". /usr/local/hbase/conf/hbase-env.sh; rm -rf #{options[:remoteYcsbDir]};" +
      "mkdir -p #{options[:remoteYcsbDir]}; cd #{options[:remoteYcsbDir]}; " +
      "wget -nv #{options[:ycsbURL]}; " +
      "tar xfP ycsb.tar;" + 
      "cd ycsb; chmod +x run-test.sh;" +
      "#{options[:remoteYcsbDir]}/ycsb/run-test.sh " + 
      "-p recordcount=#{options[:testRecordCount]} " + 
      "-p operationcount=#{options[:testOperationCount]} " + 
      "-threads #{options[:testThreadNumber]} " + 
      "-p measurementtype=timeseries -p timeseries.granularity=60000 -p basicdb.verbose=false;" +
      "tar cfz #{options[:remoteYcsbDir]}/results.tar.gz results;") 
    
    testEndTime = Time.new
    
    p "Test started at " + testStartTime + ", ended at " + testEndTime + "." 
      
    # 2. download the results files locally.
    %x[mkdir -p #{options[:localProcessDir]}; ]
    Net::SCP.start(dnsName(),
      'root',
      :keys => ENV['EC2_ROOT_SSH_KEY'],
      :paranoid => false
      ) do |scp|
        scp.download! "#{options[:remoteYcsbDir]}/results.tar.gz", options[:localProcessDir]
    end
    
    # download hbase jar file to get some properties of tested hbase
    jarDire = options[:localProcessDir] + "/jar"
  
    %x[rm -rf #{jarDire}; mkdir -p #{jarDire}]
    
    Net::SCP.start(dnsName(),
      'root',
      :keys => ENV['EC2_ROOT_SSH_KEY'],
      :paranoid => false
      ) do |scp|
        scp.download! "/usr/local/hbase/#{options[:jarFileName]}", jarDire
    end
    
    %x[cd #{jarDire}; jar xf #{options[:jarFileName]}]
    
    mfFile = options[:jarFileName] + "/META-INF/MANIFEST.MF"
    # jarDire += options[:jarFileName]
      
    if File.exists?(jarDire)
      builtTime = File.stat(mfFile).mtime if (File.exists(mfFile))
      
    end
      
    # 3. generate email contents
    resultDetail = generateResultDetail(options, 
      testStartTime, testEndTime, builtTime, buildNumber)
    
    # 4. send email. 
    sendResults(resultDetail)
  end
end
end
