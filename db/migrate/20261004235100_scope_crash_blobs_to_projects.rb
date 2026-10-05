# frozen_string_literal: true

class ScopeCrashBlobsToProjects < ActiveRecord::Migration[8.1]
  def change
    add_index :crashes_blobs, [ :id, :project_id ], unique: true
    add_foreign_key :crashes_attachments, :crashes_blobs, column: [ :blob_id, :project_id ], primary_key: [ :id, :project_id ]
  end
end
