require 'rmagick'
require 'graffic/aws'
require 'graffic/ext'


# Graffic is an ActiveRecord class to make dealing with Image assets more enjoyable.
# Each image is an ActiveRecord object/record and therefor can be attached to other models
# through ActiveRecord's normal has_one and has_many methods.
# A Graffic record progresses through four states: received, moved, uploaded and processed.
# Graffic is designed in a way to let slow operating states out of the request cycle, if desired.
#
class Graffic < ActiveRecord::Base  
  attr_writer :file
  
  before_validation_on_create :set_initial_state

  class_inheritable_accessor :bucket_name
  class_inheritable_accessor :format, :default => 'png'
  class_inheritable_accessor :process_queue_name, :default => 'graffic_process'
  class_inheritable_accessor :upload_queue_name, :default => 'graffic_upload'
  class_inheritable_accessor :tmp_dir, :default => RAILS_ROOT + '/tmp/graffics'
  
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
        return unless record = find(data[:id])
        record.process!
        message.delete
      end
    end
    
    # Handles the first message in the upload queue
    def handle_top_in_upload_queue!
      if message = upload_queue.receive
        data = YAML.load(message.to_s)
        return if data[:hostname] != `hostname`.strip
        return unless record = find(data[:id])
        record.upload!
        message.delete
      end
    end
    
    def inherited(subclass)
      subclass.has_one(:original, :class_name => 'Graffic', :as => :resource, :dependent => :destroy, :conditions => { :name => 'original' })
      super
    end
    
    # The queue for processing images
    def process_queue
      @process_queue ||= Graffic::Aws.sqs.queue(process_queue_name, true)
    end
    
    # The queue for uploading images
    def upload_queue
      @upload_queue ||= Graffic::Aws.sqs.queue(upload_queue_name, true)
    end
  end
  
  # The format of the image
  def format
    attributes['format'] || self.class.format
  end
  
  # Move the file to the temporary directory
  def move!
    move_without_queue!
    queue_for_upload
  end
  
  # Move the file to the temporary directory
  def move_without_queue!
    logger.debug("***** Graffic[#{self.id}]#move!")
    if @file.is_a?(Tempfile)
      @file.write(tmp_file_path)
    elsif @file.is_a?(String)
      FileUtils.cp(@file, tmp_file_path)
    end
    change_state('moved')
  end
  
  # Process the image
  def process!
    logger.debug("***** Graffic[#{self.id}]#process!")
    record_image_dimensions_and_format
    upload_image
    change_state('processed')
  end
  
  # Move the file if it saved successfully
  def save_and_move
    move! if status = save
    status
  end
  
  def save_and_process
    if status = save
      move_without_queue!
      upload_without_queue!
      process!
    end
    status
  end
  
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
    logger.debug("***** Graffic[#{self.id}]#upload!")
    upload_image
    save_original
    remove_tmp_file
    change_state('uploaded')
  end
  
protected

  # Connivence method for getting the bucket
  def bucket
    self.class.bucket
  end
    
  # Save the state without running all the callbacks
  def change_state(state)
    logger.debug("***** Changing state to: #{state}")
    self.state = state
    save(false)
  end
  
  # Make sure a file was given
  def file_was_given
    errors.add(:file, 'not included.  You need a file when creating.') if @file.nil?
  end
  
  def image
    case self.state
      when 'moved': Magick::Image.read(tmp_file_path).first
      when 'uploaded', 'processed': Magick::Image.from_blob(bucket.get(uploaded_file_path)).first
    end
  end
  
  # Return the file extension based on the type
  def extension(atype = nil)
    (atype || format).to_s
  end
  
  def process_queue
    self.class.process_queue
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
    FileUtils.rm(tmp_file_path)
  end
  
  # Returns a RMagick constant for the type of image
  def rmagick_type(atype = nil)
    return case (atype || self.format).to_sym
      when :gif then Magick::LZWCompression
      when :jpg then Magick::JPEGCompression
      when :png then Magick::ZipCompression
    end
  end
  
  def save_original
    logger.debug('Saving Original')
    if respond_to?(:original)
      i = Graffic.new(:file => tmp_file_path, :name => 'original')
      i.save_and_process
      update_attribute(:original, i)
    end
  end

  # If we got a new file, we need to start over with the state
  def set_initial_state
    self.state = 'received' unless @file.nil?
  end
  
  def upload_queue
    self.class.upload_queue
  end
  
  def tmp_file_path
    self.tmp_dir + "/#{id}.tmp"
  end
  
  # Upload the image
  def upload_image
    t = self.rmagick_type
    data = image.to_blob { |i| i.compression = t }
    bucket.put(uploaded_file_path, data, {}, 'public-read')
  end
  
  # Return the path on S3 for the file (the key name, essentially)
  def uploaded_file_path
    "#{self.class.name.tableize}/#{id}.#{extension}"
  end

  create_tmp_dir
end # Graffic