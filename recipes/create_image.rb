$:.unshift("~/hbase-ec2/lib")
load 'hcluster.rb'
include Hadoop 

options = {
  :hadoop_url => 'http://mlai.hadoop.tarballs.s3.amazonaws.com/hadoop-0.90-tm-5.tar.gz',
  :hbase_url => 'http://mlai.hadoop.tarballs.s3.amazonaws.com/hbase-0.90-tm-5.tar.gz', 
  :tar_s3 => "mlai.tarballs", 
  :ami_s3 => "mlai-ami"
}

builder = Himage.new options
builder.create_image :debug => true, :delete_existing => true

