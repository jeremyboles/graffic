class CreateGraffics < ActiveRecord::Migration
  def self.up
    create_table :graffics do |t|
      t.belongs_to :resource, :polymorphic => true
      t.string :format, :name, :state, :type
      t.integer :height, :width
      t.datetime :created_at
    end
    add_index :graffics, [:resource_id, :resource_type]
    add_index :graffics, [:resource_id, :resource_type, :name]
    add_index :graffics, :state
  end
 
  def self.down
    drop_table :graffics
  end
end