# frozen_string_literal: true

require "rails_helper"

RSpec.describe Embeddings::ResizeColumns do
  def column_size(table)
    ActiveRecord::Base.connection.select_value(<<~SQL)
      SELECT format_type(atttypid, atttypmod) FROM pg_attribute
      WHERE attrelid = '#{table}'::regclass AND attname = 'embedding'
    SQL
  end

  after { ActiveRecord::Base.connection.clear_cache! }

  it "resizes every embedding column, clears the old vectors and keeps the search index" do
    ticket = create(:ticket, embedding: Array.new(1024, 0.1), embedding_version: "old")

    result = described_class.call(dimensions: 768)

    expect(result).to be_ok
    described_class::TABLES.each { |table| expect(column_size(table)).to eq("vector(768)") }
    expect(ticket.reload.embedding).to be_nil
    expect(ticket.embedding_version).to be_nil
    expect(ActiveRecord::Base.connection.index_name_exists?(:ticketing_tickets, "index_ticketing_tickets_on_embedding"))
      .to be(true)
  end

  it "resizes the helpdesk requests too, so their embeddings keep working after a model change (CYRA-914 P8)" do
    expect(described_class.call(dimensions: 768)).to be_ok

    expect(column_size("helpdesk_requests")).to eq("vector(768)")
  end

  it "does nothing when the columns already have the requested size" do
    ticket = create(:ticket, embedding: Array.new(1024, 0.1), embedding_version: "kept")

    expect(described_class.call(dimensions: 1024)).to be_ok
    expect(ticket.reload.embedding_version).to eq("kept")
  end

  it "refuses a size the search index cannot hold" do
    expect(described_class.call(dimensions: 3072)).not_to be_ok
    expect(column_size("ticketing_tickets")).to eq("vector(1024)")
  end
end
