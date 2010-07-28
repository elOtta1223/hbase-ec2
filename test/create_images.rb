#!/usr/bin/ruby

require 'test/unit'
$:.unshift File.join(File.dirname(__FILE__),"..", "lib")
require 'hcluster.rb'

class TestCreateImage < Test::Unit::TestCase
  #test 1: separate ami and tar buckets, each of which exists.
  image_builder = HimageBuilder.new :ami_bucket => 'ekoontz-amis', :tar_bucket => 'ekoontz-tarballs'
  #test 2: separate ami and tar buckets, neither of which exists.
  image_builder = HimageBuilder.new :ami_bucket => 'ekoontz-amis2', :tar_bucket => 'ekoontz-tarballs2'
  #test 3: common bucket, which exists.
  image_builder = HimageBuilder.new :bucket => 'ekoontz-tarballs'
  #test 4: common bucket, which does not exist.
  image_builder = HimageBuilder.new :bucket => 'ekoontz-common-bucket2'
end
