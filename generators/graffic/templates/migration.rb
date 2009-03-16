class CreateGraffics < ActiveRecord::Migration
  def self.up
    create_table :graffics do |t|
      t.belongs_to :resource, :polymorphic => true
      t.string :format, :name, :state, :type
      t.integer :height, :width
      t.datetime :created_at
    end
    add_index :images, [:resource_id, :resource_type]
    add_index :images, [:resource_id, :resource_type, :name]
    add_index :images, :state
  end
 
  def self.down
    drop_table :graffics
  end
end