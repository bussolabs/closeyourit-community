# frozen_string_literal: true

require "rails_helper"

# CYRA-879 — every table reachable from projects or groups that holds organization_id, points to a
# per-organization lookup or to an organization-owned row must be classified in the move registry.
RSpec.describe "Project move registry" do
  let(:connection) { ActiveRecord::Base.connection }
  # Monthly partitions share the rules of their parent table (CYRA-879).
  let(:partitions) { connection.select_values("SELECT c.relname FROM pg_class c WHERE c.relispartition AND c.relkind = 'r'") }
  let(:tables) { connection.tables - %w[schema_migrations ar_internal_metadata] - partitions }
  let(:foreign_keys) { tables.to_h { |table| [ table, connection.foreign_keys(table) ] } }
  # Rows of the polymorphic tables that follow a move are roots too: their children move with them (CYRA-879).
  # Knowledge pages follow their moved projects without a foreign key to them, so they are a root as well (CYRA-882).
  let(:descendants) do
    reached = %w[projects projects_groups knowledge_pages] + registry::POLYMORPHIC_FOLLOW.map(&:first)
    loop do
      found = foreign_keys.select { |table, keys| !reached.include?(table) && keys.any? { reached.include?(_1.to_table) } }.keys
      break reached if found.empty?

      reached += found
    end
  end
  let(:org_owned) { tables.select { connection.column_exists?(_1, :organization_id) } - descendants }
  let(:registry) { Projects::Moves::Registry }

  it "classifies every descendant table that stores organization_id" do
    missing = descendants.select { connection.column_exists?(_1, :organization_id) } - registry.classified_tables
    expect(missing).to be_empty, "Classify in Projects::Moves::Registry: #{missing.join(', ')}"
  end

  it "remaps every descendant column pointing to a per-organization lookup" do
    missing = descendants.flat_map do |table|
      foreign_keys[table].select { _1.to_table.start_with?("types_") }
                         .reject { registry::LOOKUPS.dig(table, _1.column) || registry::DETACH[table] == :delete || registry.nullified?(table, _1.column) }
                         .map { "#{table}.#{_1.column}" }
    end
    expect(missing).to be_empty, "Add to Registry::LOOKUPS: #{missing.join(', ')}"
  end

  it "detaches or follows every descendant column pointing to an organization-owned row" do
    missing = descendants.flat_map do |table|
      foreign_keys[table].select { org_owned.include?(_1.to_table) && _1.to_table != "organizations" }
                         .reject { registry.handles_column?(table, _1.column) }
                         .map { "#{table}.#{_1.column} -> #{_1.to_table}" }
    end
    expect(missing).to be_empty, "Classify in Projects::Moves::Registry: #{missing.join(', ')}"
  end

  it "does not accept an unclassified column on a nullify table" do
    expect(registry.handles_column?("todos_items", "some_new_fk")).to be(false)
    expect(registry.handles_column?("todos_items", "ticket_id")).to be(true)
  end

  # CYRA-882 — a page or book may move, stay, or change book: every link to one must say which rule applies.
  it "classifies every column pointing to a knowledge page or book" do
    missing = tables.flat_map do |table|
      foreign_keys[table].select { %w[knowledge_pages knowledge_books].include?(_1.to_table) }
                         .reject { knowledge_link_classified?(table, _1.column) }
                         .map { "#{table}.#{_1.column} -> #{_1.to_table}" }
    end
    expect(missing).to be_empty, "Classify in Projects::Moves::Registry: #{missing.join(', ')}"
  end

  def knowledge_link_classified?(table, column)
    registry::DETACH[table] == :delete || registry.nullified?(table, column) ||
      registry::REPOINTED.dig(table, column).present? || registry::CARRIED_LINKS.dig(table, column).present?
  end

  it "accepts only the repointed column of a followed knowledge page" do
    expect(registry.handles_column?("knowledge_pages", "book_id")).to be(true)
    expect(registry.handles_column?("knowledge_pages", "some_new_fk")).to be(false)
  end

  it "classifies every polymorphic table that stores organization_id" do
    polymorphic = tables.select do |table|
      connection.column_exists?(table, :organization_id) &&
        connection.columns(table).any? { _1.name.end_with?("_type") && connection.column_exists?(table, _1.name.sub(/_type\z/, "_id")) }
    end
    missing = polymorphic - registry.classified_tables
    expect(missing).to be_empty, "Classify in Projects::Moves::Registry: #{missing.join(', ')}"
  end
end
