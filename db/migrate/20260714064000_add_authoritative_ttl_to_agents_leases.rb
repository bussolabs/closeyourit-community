# frozen_string_literal: true

class AddAuthoritativeTtlToAgentsLeases < ActiveRecord::Migration[8.1]
  def change
    add_column :agents_leases, :authoritative_ttl_seconds, :integer
    add_check_constraint :agents_leases,
                         "authoritative_ttl_seconds IS NULL OR " \
                         "authoritative_ttl_seconds BETWEEN 1 AND 2592000",
                         name: "agents_leases_authoritative_ttl_range"
  end
end
