$:.unshift("~/hbase-ec2/lib")
load 'hcluster.rb'
include Hadoop 

options = {
  :hadoop_url => 'http://ekoontz-tarballs.s3.amazonaws.com/hadoop-0.20-tm-3.tar.gz',
  :hbase_url => 'http://ekoontz-tarballs.s3.amazonaws.com/hbase-0.20-tm-3.tar.gz', 
  :tar_s3 => "ekoontz-tarballs", 
  :ami_s3 => "ekoontz-amis"
}

builder = Himage.new options
builder.create_image :debug => true, :delete_existing => true

