# frozen_string_literal: true

require "rails_helper"
require Rails.root.join("db/migrate/20260715085246_rebuild_authorized_agents")

RSpec.describe RebuildAuthorizedAgents do
  subject(:migration) { described_class.new }

  it "valorizza il run legacy per tutti gli agenti finché la colonna NOT NULL non viene rimossa" do
    statements = []

    allow(migration).to receive(:execute) { |sql| statements << sql.squish }
    allow(migration).to receive(:quote) do |value|
      value.nil? ? "NULL" : ActiveRecord::Base.connection.quote(value)
    end

    described_class::COMMANDS.each do |key, config|
      migration.send(
        :insert_agent,
        SecureRandom.uuid,
        SecureRandom.uuid,
        SecureRandom.uuid,
        key,
        config,
        true,
        Time.current
      )
    end

    expect(statements.size).to eq(3)
    statements.zip(described_class::COMMANDS.keys).each do |statement, key|
      expect(statement).to include("kind, run, schedule")
      expect(statement).to include("#{ActiveRecord::Base.connection.quote(key)}, 'every 1m'")
    end
  end
end
