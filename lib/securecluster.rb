module Hadoop

  class SecureCluster < HCluster

    def startHDFS
      done = false
      unless done
        begin
          ssh("su -l hadoop -c \"cd /usr/local/hadoop; kinit -k -t conf/nn.keytab hadoop/#{master.privateDnsName.downcase}; bin/hadoop namenode -format\"; /usr/local/hadoop/bin/hadoop-daemon.sh start namenode")
          done = true
        rescue
        end
      end
      done = false
      unless done
        begin
          ssh_to(secondary.dnsName, "su -l hadoop -c \"cd /usr/local/hadoop; kinit -k -t conf/nn.keytab hadoop/#{secondary.privateDnsName.downcase}\"; /usr/local/hadoop/bin/hadoop-daemon.sh start secondarynamenode")
          done = true
        rescue
        end
      end
      done = false
      unless done
        begin
          slaves.each { |inst| ssh_to(inst.dnsName, "su -l hadoop -c \"cd /usr/local/hadoop; kinit -k -t conf/nn.keytab hadoop/#{inst.privateDnsName.downcase}\"; /usr/local/hadoop/bin/hadoop-daemon.sh start datanode") }
          done = true
        rescue
        end
      end
    end
  
    def startMR
      done = false
      unless done
        begin
          ssh("su -l hadoop -c \"cd /usr/local/hadoop ; bin/hadoop fs -mkdir /mapred/system; bin/hadoop fs -chown hadoop /mapred/system\"; /usr/local/hadoop/bin/hadoop-daemon.sh start jobtracker")
          done = true
        rescue
        end
      end
      done = false
      unless done
        begin
          slaves.each { |inst| ssh_to(inst.dnsName, "/usr/local/hadoop/bin/hadoop-daemon.sh start tasktracker") }
          done = true
        rescue
        end
      end
    end

    def startHBase 
      done = false
      unless done
        begin
          ssh("su -l hadoop -c \"cd /usr/local/hadoop ; bin/hadoop fs -mkdir /hbase; bin/hadoop fs -chown hbase /hbase\" ; /usr/local/hbase/bin/hbase-daemon.sh start master")
          done = true
        rescue
        end
      end
      done = false
      unless done
        begin
          slaves.each { |inst| ssh_to(inst.dnsName, "/usr/local/hbase/bin/hbase-daemon.sh start regionserver") }
          done = true
        rescue
        end
      end
    end

    def uploadHBaseJar(filePath)
      # TODO: make sure hbase is not running
      scp(filePath, dnsName + ":/usr/local/hbase/")
      slaves.each {|inst| scp(filePath, inst.dnsName + ":/usr/local/hbase/") }
    end
  
    def launch(options = {})
      super(options)

      startHDFS

      if (options[:uploadHBaseJar] != nil)
        uploadHBaseJar(options[:uploadHBaseJar]) if File.exists?(options[:uploadHBaseJar])
      end

      startHBase

      startMR
    end

  end

end
