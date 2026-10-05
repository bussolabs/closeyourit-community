# frozen_string_literal: true

require "spec_helper"
require_relative "../../../script/certification/guard"

RSpec.describe Certification::Guard do
  let(:run_id) { "a123456789abcdef" }
  let(:env) { { "RAILS_ENV" => "test", "TEST_SLOT" => "_cert_#{run_id}", "CERTIFICATION_RUN_ID" => run_id } }

  it "accepts only the isolated test slot" do
    expect(described_class.new(env).validate!).to eq(run_id)
  end

  it "refuses other environments before Rails loads" do
    %w[development staging production].each do |name|
      expect { described_class.new(env.merge("RAILS_ENV" => name)).validate! }.to raise_error(ArgumentError, /test environment/)
    end
  end

  it "refuses another slot and malformed run identifiers" do
    expect { described_class.new(env.merge("TEST_SLOT" => "_labs")).validate! }.to raise_error(ArgumentError, /slot/)
    expect { described_class.new(env.merge("CERTIFICATION_RUN_ID" => "../shared")).validate! }.to raise_error(ArgumentError, /identifier/)
  end

  it "rejects database URLs and PostgreSQL connection overrides without exposing their values" do
    %w[DATABASE_URL PRIMARY_DATABASE_URL QUEUE_DATABASE_URL CACHE_DATABASE_URL CABLE_DATABASE_URL
       PGSERVICE PGSERVICEFILE PGDATABASE PGHOSTADDR PGOPTIONS TEST_ENV_NUMBER].each do |key|
      expect { described_class.new(env.merge(key => "private-value")).validate! }
        .to raise_error(ArgumentError) { |error| expect(error.message).not_to include("private-value") }
    end
  end

  it "rejects remote and multiple PostgreSQL hosts" do
    %w[db.example.com localhost,db.example.com].each do |host|
      expect { described_class.new(env.merge("PGHOST" => host)).validate! }.to raise_error(ArgumentError, /local/)
    end
  end

  it "accepts loopback or a local socket" do
    [ "localhost", "127.0.0.1", "::1", "/tmp" ].each do |host|
      expect(described_class.new(env.merge("PGHOST" => host)).validate!).to eq(run_id)
    end
  end
end
