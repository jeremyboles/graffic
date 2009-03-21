require 'rmagick'
require 'graffic/aws'
require 'graffic/ext'

require 'graffic/view_helpers'


# Graffic is an ActiveRecord class to make dealing with Image assets more enjoyable.
# Each image is an ActiveRecord object/record and therefor can be attached to other models
# through ActiveRecord's normal has_one and has_many methods.
# A Graffic record progresses through four states: received, moved, uploaded and processed.
# Graffic is designed in a way to let slow operating states out of the request cycle, if desired.
#
class Graffic < ActiveRecord::Base  
  after_create :move
  after_destroy :delete_s3_file
  
  before_validation_on_create :set_initial_state
  
  belongs_to :resource, :polymorphic => true

  class_inheritable_accessor :bucket_name
  class_inheritable_accessor :format, :default => 'png'
  class_inheritable_accessor :process_queue_name, :default => 'graffic_process'
  class_inheritable_accessor :upload_queue_name, :default => 'graffic_upload'
  class_inheritable_accessor :should_process_versions, :use_queue, :default => true
  class_inheritable_accessor :tmp_dir, :default => RAILS_ROOT + '/tmp/graffics'
  class_inheritable_accessor :processors, :default => []
  class_inheritable_accessor :versions, :default => {}
  
  attr_writer :file, :processors
  
  validate_on_create :file_was_given
  
  class << self
    # Returns the bucket for the model
    def bucket
      @bucket ||= Graffic::Aws.s3.bucket(bucket_name, true, 'public-read')
    end
    
    # Create the tmp dir to store files until we upload them
    def create_tmp_dir
      FileUtils.mkdir(tmp_dir) unless File.exists?(tmp_dir)
    end
    
    # Handle the first message in toe process queue
    def handle_top_in_process_queue!
      if message = process_queue.receive
        data = YAML.load(message.to_s)
        begin
          record = find(data[:id])
          record.process
        rescue ActiveRecord::RecordNotFound
          return 'Not found'
        ensure
          message.delete
        end
      end
    end
    
    # Handles the first message in the upload queue
    # TODO: Figure out a better way to handle messages when records aren't there
    def handle_top_in_upload_queue!
      if message = upload_queue.receive
        data = YAML.load(message.to_s)
        return if data[:hostname] != `hostname`.strip
        begin 
          record = find(data[:id])
          record.upload
        rescue ActiveRecord::RecordNotFound
          return 'Not found'
        ensure
          message.delete
        end
      end
    end
    
    # DSL method for processing images
    def process(&block)
      self.processors ||= []
      self.processors << block if block_given?
    end
    
    # When we create a new type of Graffic, make sure we save the original
    def inherited(subclass)
      subclass.has_one(:original, :class_name => 'Graffic', :as => :resource, :dependent => :destroy, :conditions => { :name => 'original' })
      super
    end
    
    # The queue for processing images
    def process_queue
      @process_queue ||= Graffic::Aws.sqs.queue(process_queue_name, true)
    end
    
    # DSL method for making thumbnails
    def size(name, size = {})
      size.assert_valid_keys(:width, :height)
      version(name) do |img|
        logger.debug("***** Resizing: #{size[:width]}x#{size[:height]}")
        img.crop_resized(size[:width], size[:height])
      end
    end
    
    # The queue for uploading images
    def upload_queue
      @upload_queue ||= Graffic::Aws.sqs.queue(upload_queue_name, true)
    end
    
    # DSL method for declaring a version of an image
    def version(name, &block)
      self.versions[name] ||= []
      self.versions[name] << block if block_given?
      has_one(name, :class_name => 'Graffic', :as => :resource, :dependent => :destroy, :conditions => { :name => name.to_s })
      logger.debug("***** Adding Version: #{name.to_s} : #{block.to_s}")
    end
  end
  
  # The format of the image
  def format
    attributes['format'] || self.class.format
  end
  
  # Return an RMagick image, based on the state of image
  def image
    @image ||= case self.state
      when 'moved': Magick::Image.read(tmp_file_path).first
      when 'uploaded', 'processed': Magick::Image.from_blob(bucket.get(uploaded_file_path)).first
    end
  end
  
  # Move the file to the temporary directory
  def move
    return unless self.state == 'received'
    logger.debug("***** Graffic[#{self.id}](#{self.name})#move!")
    if @file.is_a?(Tempfile) # Uploaded File
      @file.write(tmp_file_path)
    elsif @file.is_a?(String) # String representing a file's location
      FileUtils.cp(@file.strip, tmp_file_path)
    elsif @file.is_a?(Magick::Image) # An actually RMagick file
      @image = @file
      self.use_queue = false
      change_state('uploaded')
      process
      return
    end
    
    change_state('moved')
    use_queue? ? queue_for_upload : upload
  end
  
  attr_accessor :should_process_versions
  def should_process_versions?
    should_process_versions.nil? ? self.class.should_process_versions : should_process_versions
  end
  
  # Process the image
  def process
    return unless self.state == 'uploaded'
    logger.debug("***** Graffic[#{self.id}](#{self.name})#process!")
    run_processors
    record_image_dimensions_and_format
    upload_image
    change_state('processed')
    
    process_versions if should_process_versions?
  end

  # Returns the processor for the instance
  def processors
    @processors || self.class.processors
  end
  
  # Returns a size string.  Good for RMagick and image_tag :size
  def size
    "#{width}x#{height}"
  end
  
  # Upload the file
  def upload
    return unless self.state == 'moved'
    logger.debug("***** Graffic[#{self.id}](#{self.name})#upload!")
    upload_image
    save_original
    remove_tmp_file
    
    change_state('uploaded')
    use_queue? ? queue_for_processing : process
  end
  
  # Return the url for displaying the image
  def url
    self.s3_key.public_link
  end
  
  attr_accessor :use_queue
  def use_queue?
    use_queue.nil? ? self.class.use_queue : use_queue
  end
  
protected

  # Connivence method for getting the bucket
  def bucket
    self.class.bucket
  end
    
  # Save the state without running all the callbacks
  def change_state(state)
    logger.debug("***** Graffic[#{self.id}](#{self.name}): Changing state to: #{state}")
    self.state = state
    save(false)
  end
  
  def delete_s3_file
    self.s3_key.delete
  end
  
  # Make sure a file was given
  def file_was_given
    self.errors.add(:file, 'not included.  You need a file when creating.') if @file.nil?
  end
  
  # Return the file extension based on the type
  def extension(atype = nil)
    (atype || format).to_s
  end
  
  def process_queue
    self.class.process_queue
  end
  
  def process_versions
    self.versions.each do |version, processors|
      logger.debug("***** Graffic[#{self.id}](#{self.name}): Processing version: #{version} (#{processors.size} processors)")
      g = Graffic.new(:file => self.image, :name => version.to_s, :use_queue => false)
      g.processors += processors unless processors.nil?
      self.update_attribute(version, g)
    end unless self.versions.blank?
  end
  
  def queue_for_upload
    self.upload_queue.push({ :id => self.id, :hostname => `hostname`.strip }.to_yaml)
  end
  
  def queue_for_processing
    self.process_queue.push({ :id => self.id }.to_yaml)
  end
  
  def record_image_dimensions_and_format
    self.height, self.width, self.format = image.rows, image.columns, self.format
    save(false)
  end
  
  def remove_tmp_file
    FileUtils.rm(tmp_file_path) if File.exists?(tmp_file_path)
  end
  
  # Returns a RMagick constant for the type of image
  def rmagick_type(atype = nil)
    return case (atype || self.format).to_sym
      when :gif then Magick::LZWCompression
      when :jpg then Magick::JPEGCompression
      when :png then Magick::ZipCompression
    end
  end
  
  def run_processors
    logger.debug("***** Graffic[#{self.id}](#{self.name}): Running processor (#{self.processors.try(:size)} processors)")
    self.processors.each do |processor|
      img = self.image
      img = img.first if img.respond_to?(:first)
      @image =  case processor.arity # Pass in the record itself, if the block wants it
        when 1: processor.call(img)
        when 2: processor.call(img, self)
      end
      raise 'You need to return an image' unless @image.is_a?(Magick::Image)
      logger.debug("Returned Image Size: #{@image.columns}x#{@image.rows}")
    end unless self.processors.blank?
  end
  
  def s3_key
    @s3_key ||= bucket.key(uploaded_file_path)
  end
  
  def save_original
    if respond_to?(:original)
      logger.debug("***** Graffic[#{self.id}](#{self.name}): Saving Original")
      g = Graffic.new(:file => tmp_file_path, :name => 'original', :use_queue => false)
      self.update_attribute(:original, g)
    end
  end

  # If we got a new file, we need to start over with the state
  def set_initial_state
    self.state = 'received' unless @file.nil?
  end
  
  def tmp_file_path
    self.tmp_dir + "/#{id}.tmp"
  end
  
  # Return the path on S3 for the file (the key name, essentially)
  def uploaded_file_path
    "#{self.class.name.tableize}/#{id}.#{extension}"
  end
  
  # Upload the image
  def upload_image
    t = self.rmagick_type
    data = image.to_blob { |i| i.compression = t }
    bucket.put(uploaded_file_path, data, {}, 'public-read')
  end
  
  def upload_queue
    self.class.upload_queue
  end

  create_tmp_dir
end # Graffic