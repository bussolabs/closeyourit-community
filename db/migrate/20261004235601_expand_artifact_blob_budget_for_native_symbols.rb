class ExpandArtifactBlobBudgetForNativeSymbols < ActiveRecord::Migration[8.1]
  def change
    remove_check_constraint :artifacts_blobs, "byte_size >= 0 AND byte_size <= 5242880", name: "artifacts_blob_size"
    add_check_constraint :artifacts_blobs, "byte_size >= 0 AND byte_size <= 20971520", name: "artifacts_blob_size"
  end
end
