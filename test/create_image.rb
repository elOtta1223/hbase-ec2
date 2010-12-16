#!/usr/bin/ruby

require 'test/unit'
$:.unshift File.join(File.dirname(__FILE__),"..", "lib")
require 'hcluster.rb'

include Hadoop

class TestCreateImage < Test::Unit::TestCase
  @@builder = Himage.new(
                         { :tar_s3 => 'ekoontz-tarballs', :ami_s3 => 'ekoontz-amis', 
                           :hbase => '/Users/ekoontz/hbase/target/hbase-0.89.20100621-bin.tar.gz', 
                           :hadoop => '/Users/ekoontz/hadoop-common/build/hadoop-0.20.104.3-append-SNAPSHOT.tar.gz'})
  
  def setup
    @@ami = @@builder.create_image :delete_existing => true
  end

  def teardown
    #...
  end

  def test_image_exists
    #check to make sure that that image we built (@@ami) exists in our images.
    images = Himage.myimages :output_fn => nil

    found = false
    images.each {|image|
      if image.imageId == @@ami
        found = true
      end
    }
    assert(found == true)
  end
  
end
