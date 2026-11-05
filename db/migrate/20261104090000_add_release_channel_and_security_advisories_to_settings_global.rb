# frozen_string_literal: true

# The release channel of a community install (stable for everyone at first) and the last signed list
# of insecure versions it verified, kept in the database so a restart or a cleared cache never loses it.
class AddReleaseChannelAndSecurityAdvisoriesToSettingsGlobal < ActiveRecord::Migration[8.1]
  def change
    add_column :settings_global, :release_channel, :string, default: "stable", null: false
    add_column :settings_global, :security_advisories, :jsonb
    add_column :settings_global, :security_advisories_issued_at, :datetime
  end
end
