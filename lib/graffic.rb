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
  after_destroy :delete_s3_file
  
  attr_writer :file, :processor
  
  before_validation_on_create :set_initial_state
  
  belongs_to :resource, :polymorphic => true

  class_inheritable_accessor :bucket_name, :processor
  class_inheritable_accessor :format, :default => 'png'
  class_inheritable_accessor :process_queue_name, :default => 'graffic_process'
  class_inheritable_accessor :upload_queue_name, :default => 'graffic_upload'
  class_inheritable_accessor :tmp_dir, :default => RAILS_ROOT + '/tmp/graffics'
  class_inheritable_hash :versions
  
  validate_on_create :file_was_given
  
  class << self
    # Returns the bucket for the model
    def bucket
      @bucket ||= Graffic::Aws.s3.bucket(bucket_name, true, 'public-read')
    end
    
    def create_tmp_dir
      FileUtils.mkdir(tmp_dir) unless File.exists?(tmp_dir)
    end
    
    # Handle the first message in toe process queue
    def handle_top_in_process_queue!
      if message = process_queue.receive
        data = YAML.load(message.to_s)
        begin
          record = find(data[:id])
          record.process!
        rescue ActiveRecord::RecordNotFound
          return 'Not found'
        ensure
          message.delete
        end
      end
    end
    
    # Handles the first message in the upload queue
    def handle_top_in_upload_queue!
      if message = upload_queue.receive
        data = YAML.load(message.to_s)
        return if data[:hostname] != `hostname`.strip
        begin 
          record = find(data[:id])
          record.upload!
        rescue ActiveRecord::RecordNotFound
          return 'Not found'
        ensure
          message.delete
        end
      end
    end
    
    def process(&block)
      self.processor = block if block_given?
    end
    
    def inherited(subclass)
      subclass.has_one(:original, :class_name => 'Graffic', :as => :resource, :dependent => :destroy, :conditions => { :name => 'original' })
      super
    end
    
    # The queue for processing images
    def process_queue
      @process_queue ||= Graffic::Aws.sqs.queue(process_queue_name, true)
    end
    
    def size(name, size = {})
      size.assert_valid_keys(:width, :height)
      version(name) do |img|
        img = img.first if img.respond_to?(:first)
        img.crop_resized(size[:width], size[:height])
      end
    end
    
    # The queue for uploading images
    def upload_queue
      @upload_queue ||= Graffic::Aws.sqs.queue(upload_queue_name, true)
    end
    
    def version(name, &block)
      self.versions ||= {}
      if block_given?
        self.versions[name] = block || nil
        has_one(name, :class_name => 'Graffic', :as => :resource, :dependent => :destroy, :conditions => { :name => name.to_s })
      end
    end
  end
  
  # The format of the image
  def format
    attributes['format'] || self.class.format
  end
  
  def image
    @image ||= case self.state
      when 'moved': Magick::Image.read(tmp_file_path).first
      when 'uploaded', 'processed': Magick::Image.from_blob(bucket.get(uploaded_file_path)).first
    end
  end
  
  # Move the file to the temporary directory
  def move!
    move_without_queue!
    queue_for_upload
  end
  
  # Move the file to the temporary directory
  def move_without_queue!
    logger.debug("***** Graffic[#{self.id}](#{self.name})#move!")
    if @file.is_a?(Tempfile)
      @file.write(tmp_file_path)
      change_state('moved')
    elsif @file.is_a?(String)
      FileUtils.cp(@file, tmp_file_path)
      change_state('moved')
    elsif @file.is_a?(Magick::Image)
      @image = @file
      upload_without_queue!
      change_state('uploaded')
    end
  end
  
  # Process the image
  def process!
    process_without_verions!
    process_versions
  end
  
  # Process the image without the versions
  def process_without_verions!
    logger.debug("***** Graffic[#{self.id}](#{self.name})#process!")
    run_processors
    record_image_dimensions_and_format
    upload_image
    change_state('processed')
  end
  
  # Returns the processor for the instance
  def processor
    @processor || self.class.processor
  end
  
  # Move the file if it saved successfully
  def save_and_move
    move! if status = save
    status
  end
  
  # Save the file and process it immediately. Does to use queues.
  def save_and_process
    if status = save
      move_without_queue!
      upload_without_queue!
      process!
    end
    status
  end
  
  def save_and_process_without_versions
    if status = save
      move_without_queue!
      upload_without_queue!
      process_without_verions!
    end
    status
  end
  
  # Returns a size string.  Good for RMagick and image_tag :size
  def size
    "#{width}x#{height}"
  end
  
  # Upload the file
  def upload!
    upload_without_queue!
    queue_for_processing
  end
  
  # Upload the file
  def upload_without_queue!
    logger.debug("***** Graffic[#{self.id}](#{self.name})#upload!")
    upload_image
    save_original
    remove_tmp_file
    change_state('uploaded')
  end
  
  # Return the url for displaying the image
  def url
    self.s3_key.public_link
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
    unless self.versions.blank?
      self.versions.each do |version, processor|
        logger.debug("***** Graffic[#{self.id}](#{self.name}): Processing version: #{version}")
        g = Graffic.create(:file => self.image, :name => version.to_s)
        g.processor = processor unless processor.nil?
        g.save_and_process
        self.update_attribute(version, g)
      end
    end
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
    logger.debug("***** Graffic[#{self.id}](#{self.name}): Running processor")
    unless self.processor.blank?
      @image = processor.call(image, self)
      raise 'You need to return an image' unless @image.is_a?(Magick::Image)
    end
  end
  
  def s3_key
    @s3_key ||= bucket.key(uploaded_file_path)
  end
  
  def save_original
    if respond_to?(:original)
      logger.debug("***** Graffic[#{self.id}](#{self.name}): Saving Original")
      g = Graffic.new(:file => tmp_file_path, :name => 'original')
      g.save_and_process
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