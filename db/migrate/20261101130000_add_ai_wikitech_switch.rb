# frozen_string_literal: true

# Emergency switch for the Wikitech AI calls (CYRA-1129): turning notes into cards. A backfill of a
# whole channel history queues thousands of extractions, so the god needs a way to stop them.
class AddAiWikitechSwitch < ActiveRecord::Migration[8.1]
  def change
    add_column :settings_global, :ai_wikitech_enabled, :boolean, null: false, default: true
  end
end
