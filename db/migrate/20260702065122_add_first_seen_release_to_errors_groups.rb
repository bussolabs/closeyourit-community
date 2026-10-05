class AddFirstSeenReleaseToErrorsGroups < ActiveRecord::Migration[8.1]
  def change
    # Release del PRIMO evento del gruppo ("introdotto in"); la colonna esistente `release`
    # resta la più recente osservata.
    add_column :errors_groups, :first_seen_release, :string
  end
end
