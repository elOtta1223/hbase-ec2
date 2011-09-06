
# start HBase cluster at EC2
require 'YcsbCluster'
require 'git'

ycsbTestOptions = {
  :emailTo => ["mingjie_lai@trendmicro.com", "mingjie@gmail.com"],
  :emailFrom =>  "ycsb.hbase@gmail.com",  
  :localProcessDir => "/tmp/ycsb",
  :remoteYcsbDir => "/home/ec2-user/ycsb",
  :testRecordCount => "100000",
  :testOperationCount => "100000",
  :testThreadNumber => "10",
  :smtpServer => "smtp.gmail.com",
  :smtpAccount => "ycsb.hbase",
  :smtpPassword => "Qazwsx123_",
  # a customized ycsb, containing a run script and modified logic.
  :ycsbURL => "https://s3.amazonaws.com/mlai.hadoop.tarballs/ycsb.tar",
  :ycsbScript => "https://s3.amazonaws.com/mlai.hadoop.tarballs/run-test.sh",
  :jarFileName => "hbase-0.90-tm-5+1.jar"  
}

#  ["apurtell@apache.org",
#    "gary_helmling@trendmicro.com",
#    "eugene_koontz@trendmicro.com",
#    "mingjie_lai@trendmicro.com"]

GitOptions = {
  # check scm, to determine whether there is code changes since last
  # time. true: check scm and rebuild jar, if there is changes, rebuild
  # jar and use the new jar. false: to perform tests without scm check. 
  :userDefaultImage => false,
  :gitWorkDir => "/home/mlai/git/hbase.asf",
  :gitCOBranch => "tm-5+1",
  :gitCheckLogSince => "10",
  :gitRemote => "origin",
  :gitRepo => "git@github.com:trendmicro/hbase-private.git",
  :jarFileName => "hbase-0.90-tm-5.jar"  
}

@ycsb = Hadoop::YcsbCluster

cluster = @ycsb.new

launchOptions = {
  :scriptHome => "/home/mlai/git/tm-ec2/",
  :slaveNumber => 3
}

#cluster.launch launchOptions

#if there is scm changes

def isHBaseChangedSinceLastTime(workDir, repo, remote, branch, lastTime)
  if (lastTime == nil)
    return true
  else
    begin
  
    changes = getGitChangesSinceLastTime(workDir, repo, remote, branch, lastTime)
    
    rescue => e
      p "Get git status failed."
      raise
      return false
      
    ensure
      
      if (changes  == nil || changes.length == 0)
        return false
      else
        p "Changes: " + changes.to_s()
        return true
      end
    end
  end  
end

# check git changes for a given period of time. 
def getGitChangesSinceLastTime(workDir, repo, remote, branch, lastTime)
  if (lastTime == nil)
    return nil
  else
    begin
      # open an existing 
      g = Git.open(working_dir = workDir)
      
    rescue => e
      p "Fail to open local work directory at " + workDir + ". " + 
        e.message + ". Try to clone from " + repo 
      g = Git.clone(repo, workDir)
      
    ensure  
      p "Open git dire: " + workDir + ". Start to pull from remote/branch: " + 
        remote + "/" + branch
      #g.pull(remote, branch)
      begin
	      g.fetch(remote)
	      g.merge(remote)
	      g.branch(branch)
	      p "Check changes from " + lastTime.strftime("%Y-%m-%d %H:%M:%S %z")
	      changes = g.log().since(lastTime.strftime("%Y-%m-%d %H:%M:%S %z")).to_s
	      return changes
	  rescue => e
	  	p "Git ailed to work. " + e.message
	  end
    end
  end  
end

def buildNewHBaseJar(workDir, jarFile)
  # 1. check out hbase from git
  p "Start to build new HBase jar...."
  `cd #{workDir}; mvn clean; mvn -DskipTests install`

  # 2. build hbase
  jarPath = "#{workDir}/target/#{jarFile}"
  p jarPath
  
  return jarPath if File.exists?(jarPath)
  return nil
end

def loadLastBuildTimeFromFile(filePath)
  begin
  File.open(filePath, 'r') {|f|
    line = f.read()
    d = Time.parse(line)
      return d
    
  }
  rescue => e
    return nil
  end 
end

def writeBuildTimeToFile(filePath, t)
  File.open(filePath, 'w') {|f|  f.write(t.strftime("%Y-%m-%d %H:%M:%S %z"))}
end

begin
  p "Start to run YCSB test at: " + Time.new.strftime("%Y-%m-%d %H:%M:%S %z")
  gitChanges=nil
  if (!GitOptions[:userDefaultImage]) 
    begin
      # build jars from git (or other scm?)
      buildTimeFile = "/tmp/buildTime.tmp"
      
      lastTime = loadLastBuildTimeFromFile(buildTimeFile)
      
      # if no time information, or there is change happened during last time, 
      # rebuild jar and perform test
      if (isHBaseChangedSinceLastTime(GitOptions[:gitWorkDir],
                GitOptions[:gitRepo],      
                GitOptions[:gitRemote],  
                GitOptions[:gitCOBranch], 
                lastTime) )
        changes = getGitChangesSinceLastTime(GitOptions[:gitWorkDir],
          GitOptions[:gitRepo],      
          GitOptions[:gitRemote],  
          GitOptions[:gitCOBranch], 
          lastTime)
        if (changes != nil)
          gitChanges= changes.gsub("\n", ", ")
        end
          
        # build a new jar and mark time stamp
        localJarPath = buildNewHBaseJar(GitOptions[:gitWorkDir], 
          GitOptions[:jarFileName])
        p "Built a new hbase jar at: " + localJarPath
        
        # mark the build time file. 
        t = Time.new
        writeBuildTimeToFile(buildTimeFile, t)
        
        cluster.launch launchOptions
      else
        # No need to start a test.
        p "No changes since " + lastTime.strftime("%Y-%m-%d %H:%M:%S %z") +
          ", no need to perform any test, just exit. "
        exit
      end
      
      rescue => e
        p "Check git failed. Exit. " + e.backtrace.to_s() + 
          " Messages: " + e.message
        exit
    end
  else
    # start cluster, get hbase information from downloaded jar files.
    # start cluster with default hbase jars.
    cluster.launch launchOptions
  end
  
  #cluster.installYCSB ycsbTestOptions
  cluster.test ycsbTestOptions, gitChanges
  
rescue => e
  p "Exception: " + e.backtrace.to_s() 
  p "Exception: " + e.to_s()
ensure
  cluster.terminate
end