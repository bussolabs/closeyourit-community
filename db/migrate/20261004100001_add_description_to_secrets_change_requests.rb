# frozen_string_literal: true

class AddDescriptionToSecretsChangeRequests < ActiveRecord::Migration[8.1]
  def change
    add_column :secrets_change_requests, :description, :text
    add_column :secrets_change_requests, :description_only, :boolean, default: false, null: false
  end
end
