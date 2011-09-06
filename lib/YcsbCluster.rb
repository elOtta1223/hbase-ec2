
require 'rubygems'
require 'net/smtp'
require 'monitor'
require 'net/ssh'
require 'net/scp'
require 'AWS'
require 'aws/s3'

module Hadoop

class YcsbCluster # < SecureCluster
  @master = ""
  @slaves = []
  @launchOptions = {}
  
  HBASE_ROOT_DIR="/usr/lib/hbase"  
  MASTER_HOST_FILE="/tmp/ec2-master"
  
  EC2_ROOT_SSH_KEY = ENV['EC2_ROOT_SSH_KEY'] ? "#{ENV['EC2_ROOT_SSH_KEY']}" : "#{ENV['HOME']}/.ec2/ec2-user.pem"
  EC2_CERT = ENV['EC2_CERT'] ? "#{ENV['EC2_CERT']}" : "#{ENV['HOME']}/.ec2/cert.pem"
  EC2_PRIVATE_KEY = ENV['EC2_PRIVATE_KEY'] ? "#{ENV['EC2_PRIVATE_KEY']}" : "#{ENV['HOME']}/.ec2/key.pem"

  if ENV['AWS_ENDPOINT'] != nil
    ENDPOINT = ENV['AWS_ENDPOINT']
  else
    ENDPOINT = "ec2.amazonaws.com"
  end
  
  def initialize()
  end
  
  def getMaster
    file = File.open( "#{MASTER_HOST_FILE}", "rb" )
    master = file.read
    return master.gsub("\n", "")
  end
    
  def launch(options = {})    
    File.delete("#{MASTER_HOST_FILE}") if (File.exist?("#{MASTER_HOST_FILE}"))
    @launchOptions = options 

    # launch master
    %x[ #{@launchOptions[:scriptHome]}/bin/launch-master ]
    
    # wait until image started
    p "Wait for master starting: "
    while (!File.exist?(MASTER_HOST_FILE))
      p "."
      sleep(5)
    end
    
    @master = getMaster
    
    # launch slaves
    %x[ #{@launchOptions[:scriptHome]}/bin/launch-slaves #{@master} #{@launchOptions[:slaveNumber]} ]
    
    timeOutCounter=0
    slaveString = ""
    while (true)
      sleep(6)
      
#      slaveString = %x[ #{@launchOptions[:scriptHome]}/bin/list-slaves #{@master}]
      slaveString = %x[ #{ENV["EC2_HOME"]}/bin/ec2-describe-instances --region us-west-1 | grep running | awk '{print $4}' | grep -v #{@master} ]
      @slaves = slaveString.split("\n") if slaveString != nil
      
      if (@slaves.length == @launchOptions[:slaveNumber])
        continue=false
        @slaves.each {|s| 
          if (!s.start_with?("ec2"))
            continue=true
          end
        }
        break if !continue
      end
      return false if (++timeOutCounter > 200)
    end
    p "Master: " + @master
    p "Slaves: " + @slaves.to_s
  end
  
  def terminate()
    connection = AWS::EC2::Base.new(
      :access_key_id=>ENV['AWS_ACCESS_KEY_ID'],
      :secret_access_key=>ENV['AWS_SECRET_ACCESS_KEY'],
      :server => ENDPOINT) 
    
    if (connection.describe_instances.reservationSet.length > 0)  
      connection.describe_instances.reservationSet.item.each { |instance| 
        options = {
          :instance_id => instance.instancesSet.item[0].instanceId
        }
        connection.terminate_instances options
      }
    end
  end
  
  def echo_stdout
    return lambda{|line,channel|
      puts line
    }
  end
  
  def echo_stderr 
    return lambda{|line,channel|
      puts "(stderr): #{line}"
    }
  end
  
  def ssh(command = nil,
          stdout_line_reader = echo_stdout,
          stderr_line_reader = echo_stderr,
          host = @master,
          begin_output = nil,
          end_output = nil)
    ssh_with_host(command,stdout_line_reader,stderr_line_reader,host,begin_output,end_output)
  end

  def ssh_to(host,
             command=nil,
             stdout_line_reader = echo_stdout,
             stderr_line_reader = echo_stderr,
             begin_output = nil,
             end_output = nil)
    ssh_with_host(command,stdout_line_reader,stderr_line_reader,host,begin_output,end_output)
  end
  
  def ssh_with_host(command,stdout_line_reader,stderr_line_reader,host,begin_output,end_output)
    if command == nil
      interactive = true
    end
    
    if begin_output
      print begin_output
      STDOUT.flush
    end
    # http://net-ssh.rubyforge.org/ssh/v2/api/classes/Net/SSH.html#M000013
    # paranoid=>false because we should ignore known_hosts, since AWS IPs get frequently recycled
    # and their servers' private keys will vary.
    
    until command == "exit\n"
      if interactive == true
        print "#{host} $ "
        command = gets
      end
      Net::SSH.start(host,'ec2-user',
                           :keys => [EC2_ROOT_SSH_KEY],
                           :paranoid => false
                           ) do |ssh|
        stdout = ""
        channel = ssh.open_channel do |ch|
          channel.request_pty()
          channel.exec(command) do |ch, success|
            #FIXME: throw exception(?)
            puts "channel.exec('#{command}') was not successful." unless success
          end
          channel.on_data do |ch, data|
            stdout_line_reader.call(data,channel)
            # example of how to talk back to server.
            #          channel.send_data "something for stdin\n"
          end
          channel.on_extended_data do |channel, type, data|
            stderr_line_reader.call(data,channel)
          end
          channel.wait
          if !(interactive == true)
            #Cause exit from until(..) loop.
            command = "exit\n"
          end
          channel.on_close do |channel|
            # cleanup, if any..
          end
        end
      end
    end
    if end_output
      print end_output
      STDOUT.flush
    end
  end


  # Send results to email recipients thru SMTP
  def sendResults(reportDetail, options)
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
    builtTime, buildNumber, gitChanges = nil)
    # untar the file
    %x[ cd #{options[:localProcessDir]}; mkdir -p backup; if [ -r results ]; then mv results/* backup; fi; rm -rf results; tar zxf results.tar.gz]
    
    resultsDir=options[:localProcessDir] + "/results"
    reportDetail=""
    reportDetail += "<br><b>Test Summary: </b><br>\n"
    
    formattedTime = testStartTime.strftime("%Y-%m-%d %H:%M:%S %z")
    reportDetail += "Test start time: #{formattedTime}<br>\n"
    
    formattedTime = testEndTime.strftime("%Y-%m-%d %H:%M:%S %z")
    reportDetail += "Test end time: #{formattedTime}<br>\n"
    
    reportDetail += "# of RS: #{@slaves.length}<br>\n"
    reportDetail += "HBase version: #{buildNumber}<br>\n"
    reportDetail += "HBase compiled time: #{builtTime}<br>\n"
    reportDetail += "Git changes: #{gitChanges.to_s}<br>\n"
    
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

  def installYCSB(options = {})
    ssh(". #{HBASE_ROOT_DIR}/conf/hbase-env.sh; rm -rf #{options[:remoteYcsbDir]};" +
          "mkdir -p #{options[:remoteYcsbDir]}; " +
          "cd #{options[:remoteYcsbDir]}; " +
          "wget -nv #{options[:ycsbURL]}; " +
          "tar xfP ycsb.tar;" + 
          "cd ycsb; rm -rf run-test*; " +
          "wget https://s3.amazonaws.com/mlai.hadoop.tarballs/run-test.sh;" +
          "chmod +x run-test.sh; sudo cp #{HBASE_ROOT_DIR}/conf/hbase.keytab hbase.keytab; " + 
          "sudo chown ec2-user hbase.keytab;")
  end
    
    
  # perform test and analyze the results (including sending emails) 
  def test(options = {}, gitChanges = nil)
    installYCSB options
    
    # perform test
    testStartTime = Time.new
    # 1. run ycsb test
    ssh("cd #{options[:remoteYcsbDir]}/ycsb; echo create \\\"usertable\\\", \\\"family\\\" > init; echo exit >>init;" + 
      "kinit -k -t ./hbase.keytab hbase/`hostname -f`;kinit -R; hbase shell init;" +
      "#{options[:remoteYcsbDir]}/ycsb/run-test.sh " + 
      "-p recordcount=#{options[:testRecordCount]} " + 
      "-p operationcount=#{options[:testOperationCount]} " + 
      "-threads #{options[:testThreadNumber]} " + 
      "-p measurementtype=timeseries -p timeseries.granularity=60000 -p basicdb.verbose=false;" +
      "tar cfz #{options[:remoteYcsbDir]}/results.tar.gz results;") 
    
    testEndTime = Time.new
    
    p "Test started at " + testStartTime.to_s() + ", ended at " + testEndTime.to_s() + "." 
      
    # 2. download the results files locally.
    %x[mkdir -p #{options[:localProcessDir]}; ]
    Net::SCP.start(@master,
      'ec2-user',
      :keys => ENV['EC2_ROOT_SSH_KEY'],
      :paranoid => false
      ) do |scp|
        scp.download! "#{options[:remoteYcsbDir]}/results.tar.gz", options[:localProcessDir]
    end
    
    # download hbase jar file to get some properties of tested hbase
    jarDire = options[:localProcessDir] + "/jar"
  
    %x[rm -rf #{jarDire}; mkdir -p #{jarDire}]
    
    Net::SCP.start(@master,
      'ec2-user',
      :keys => ENV['EC2_ROOT_SSH_KEY'],
      :paranoid => false
      ) do |scp|
        scp.download! "#{HBASE_ROOT_DIR}/#{options[:jarFileName]}", jarDire
    end
    
    %x[cd #{jarDire}; jar xf #{options[:jarFileName]}]
    
    mfFile = jarDire + "/META-INF/MANIFEST.MF"
    # jarDire += options[:jarFileName]
    buildNumber = ""
      
    if File.exists?(mfFile)
      builtTime = File.stat(mfFile).mtime
      
      # buildNumber
      File.open(mfFile, "r")  do |infile|
        while (line = infile.gets)
          if ( line =~ /Implementation-Version:/ )
            buildNumber = line.split[1] if line.split[1] != nil
          end
        end
      end
    end
    
    # 3. generate email contents
    resultDetail = generateResultDetail(options, 
      testStartTime, testEndTime, builtTime, buildNumber, 
      gitChanges)
    
    # 4. send email. 
    sendResults(resultDetail, options)
  end
  
end
end
