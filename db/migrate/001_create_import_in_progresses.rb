class CreateImportInProgresses < ActiveRecord::Migration
  def self.up
    create_table :import_in_progresses do |t|
      t.column :user_id, :integer, :null => false
      t.string :quote_char, :limit => 8
      t.string :col_sep, :limit => 8
      t.string :encoding, :limit => 64
      t.column :created, :datetime
      t.column :csv_data, :binary
    end
  end

  def self.down
    drop_table :import_in_progresses
  end
end
