# frozen_string_literal: true

require "rails_helper"

RSpec.describe Logs::Links::Detach do
  let(:link) { create(:log_link) }

  it "rimuove il collegamento" do
    entry = link.log_entry
    linkable = link.linkable
    expect do
      described_class.call(log_entry: entry, linkable:)
    end.to change(Logs::Link, :count).by(-1)
  end

  it "è idempotente: detach di un collegamento inesistente è un no-op" do
    entry = create(:log_entry)
    linkable = create(:error_group, project: entry.project)
    result = described_class.call(log_entry: entry, linkable:)
    expect(result).to be_ok
  end
end
