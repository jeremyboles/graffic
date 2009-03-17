require 'right_aws'

class Graffic::Aws
  cattr_accessor :access_key
  cattr_accessor :secret_key
  
  def self.s3
    RightAws::S3.new(access_key, secret_key, defaults)
  end
  
  def self.sqs
    RightAws::SqsGen2.new(access_key, secret_key, defaults)
  end
  
private
  
  def self.defaults(options = {})
    { :logger => Logger.new("#{RAILS_ROOT}/log/#{RAILS_ENV}_aws.log"),
      :port => 80, 
      :protocol => 'http' 
    }.merge(options)
  end
  
end