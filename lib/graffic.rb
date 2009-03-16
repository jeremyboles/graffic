# Graffic
class Graffic < ActiveRecord::Base
  attr_writer :file
  attr_writer :image
  belongs_to :resource, :polymorphic => true
  
  after_create :move
  after_destroy :delete_s3_file
  
  # We're using the state machine to keep track of what stage of photo
  # processing we're at. Here are the states:
  # 
  # received -> moved -> uploaded -> processed
  #
  state_machine :state, :initial => :received do
    before_transition :to => :moved,      :do => :move!
    before_transition :to => :uploaded,   :do => :save_original!
    before_transition :from => :moved,    :do => :upload!
    before_transition :to => :processed,  :do => :process!
    
    after_transition :from => :moved,   :do => :remove_moved_file!
    after_transition :to => :uploaded,  :do => :queue_job!
    after_transition :to => :processed, :from => :uploaded, :do => :create_sizes!
    after_transition :to => :processed, :do => :record_dimensions!
    
    event :move do
      transition :to => :moved, :from => :received
    end
    
    event :upload do
      transition :to => :uploaded, :from => :moved
    end
    
    event :upload_unprocessed do
      transition :to => :processed, :from => :moved
    end
    
    event :process do
      transition :to => :processed, :from => :uploaded
    end
    
    # Based on which state we're at, we'll need to pull the image from a different are
    state :moved do
      # If it hasn't been moved, we'll need to pull it from the local file system
      def image
        @image ||= Magick::Image.read(tmp_file_path).first
      end
    end
    
    state :uploaded, :processed do
      # If it's been uploaded and procesed, grab it from S3
      def image
        @image ||= Magick::Image.from_blob(bucket.get(uploaded_file_path)).first
      end
    end
  end
  
  class << self
    # Returns the bucket for the model
    def bucket
      @bucket ||= Aws.s3.bucket(bucket_name, true, 'public-read')
    end
    
    # Change the bucket name from the default
    def bucket_name(name = nil)
      @bucket_name = name unless name == nil
      @bucket_name || 'images.missionaries.com'
    end
    
    # Upload all of the files that have been moved.  This will only work on
    # local files.
    # TODO: Make this work only on file system that the file was used on
    def handle_moved!
      image = first(:conditions => { :state => 'moved' })
      return if image.nil?
      image.upload 
    end
    
    # Process all of the the uploaded files that are in the queue
    def handle_uploaded!
      message = queue.pop
      return if message.nil?
      image = find(message.body)
      image.process
      message.body
    rescue
      true
    end
    
    def inherited(child)
      child.has_one(:original, :class_name => 'Image', :as => :resource, :dependent => :destroy, :conditions => { :name => 'original' })
      super
    end
    
    def process(&block)
      if block_given?
        @process = block
      else
        return @process
      end
    end
    
    # Change the queue name from the default
    def queue_name(name = nil)
      @queue_name = name unless name == nil
      @queue_name || 'images'
    end
    
    # Return the model's queue
    def queue
      @queue ||= Aws.sqs.queue(queue_name, true)
    end
    
    # Create a size of the image.
    def size(name, size={})
      size[:format] ||= :png
      size.assert_valid_keys(:width, :height, :format)
      
      @sizes ||= {}
      @sizes[name] = size
      
      has_one(name, :class_name => 'Image', :as => :resource, :dependent => :destroy, :conditions => { :name => name.to_s })
    end
    
    # Returns all of the version names for the mode
    def sizes
      @sizes ||= {}
    end
    
    # Set the image format
    def format(format = nil)
      @format = format unless format.nil?
      @format ||= :png
    end
  end
  
  # Returns a size string
  def size
    "#{width}x#{height}"
  end
  
  # Return the url for displaying the image
  def url
    key.public_link
  end
  
private
  # Connivence method for getting the bucket
  def bucket
    self.class.bucket
  end
  
  def create_sizes!
    self.class.sizes.each do |name, size|
      logger.debug("***** Sizing: #{name}")
      file_name = "#{tmp_file_path}.#{name}.#{image_extension(size[:format])}"
      
      img = image.crop_resized(size[:width], size[:height])
      img.write(file_name)
      
      i = Image.create(:file => file_name, :format => size[:format].to_s, :name => name.to_s)
      update_attribute(name, i)
      i.upload_unprocessed
      
      FileUtils.rm(file_name)
    end
  end
  
  # Deletes the file from S3
  def delete_s3_file
    key.delete
  end
  
  # The formate of the image
  def format
    attributes['format'] || self.class.format
  end
  
  # Returns true if the file has versions
  def has_sizes?
    !self.class.sizes.empty?
  end
  
  def image_extension(atype = nil)
    (atype || format).to_s
  end
  
  # Return the S3 key for the record
  def key
    @s3_key ||= bucket.key(uploaded_file_path)
  end
  
  # If the file is a Tempfile, we'll need to move to the app's tmp directory so
  # we can insure that it is retrained until we can upload it
  # If its a S3 Key, we'll write that file's date to our tmp directory
  def move!
    if @file.is_a?(Tempfile)
      FileUtils.mv(@file.path, tmp_file_path)
    elsif @file.is_a?(String)
      FileUtils.cp(@file, tmp_file_path)
    end
  end
  
  # Process the image
  def process!
    unless self.class.process.nil?
      @image = self.class.process.call(image)
      raise 'You need to return an image' unless @image.is_a?(Magick::Image)
      upload!
    end
  end
  
  # Connivence method for getting the queue
  def queue
    self.class.queue
  end
  
  # Add a job to the queue
  def queue_job!
    logger.debug("***** Image(#{self.id})#queue_job!")
    queue.push(self.id)
  end
  
  # Save the image's width and height to the database
  def record_dimensions!
    logger.debug("***** Image(#{self.id})#record_dimensions!")
    self.update_attributes(:height => image.rows, :width => image.columns)
  end
  
  # Remove the temp file in the app's temp director
  def remove_moved_file!
    logger.debug("***** Image(#{self.id})#remove_moved_file!")
    FileUtils.rm(tmp_file_path) if File.exists?(tmp_file_path)
  end
  
  # Returns a RMagick constant for the type of image
  def rmagick_type(atype = nil)
    return case (atype || format).to_sym
      when :gif then Magick::LZWCompression
      when :jpg then Magick::JPEGCompression
      when :png then Magick::ZipCompression
    end
  end
  
  # Uploads an untouched original
  def save_original!
    logger.debug("***** Image(#{self.id})#save_original!")
    if respond_to?(:original)
      i = Image.new(:file => tmp_file_path, :name => 'original')
      update_attribute(:original, i)
      i.upload_unprocessed
    end
  end
  
  # Returns the path to the file in the app's tmp directory
  def tmp_file_path
    RAILS_ROOT + "/tmp/images/#{id}.tmp"
  end
  
  # Upload the file to S3
  def upload!
    logger.debug("***** Image(#{self.id})#upload!")
    t = rmagick_type
    data = image.to_blob { |i| i.compression = t }
    bucket.put(uploaded_file_path, data, {}, 'public-read')
  end
  
  # Return the path on S3 for the file (the key name, essentially)
  def uploaded_file_path
    "#{self.class.name.tableize}/#{id}.#{image_extension}"
  end
  
end # Graffic