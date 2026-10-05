# frozen_string_literal: true

require "rails_helper"

RSpec.describe Logs::Links::Attach do
  let(:entry) { create(:log_entry) }
  let(:linkable) { create(:error_group, project: entry.project) }
  let(:actor) { create(:account) }

  it "crea il collegamento e registra l'autore" do
    result = described_class.call(log_entry: entry, linkable:, actor:)
    expect(result).to be_ok
    expect(result.value).to be_persisted
    expect(result.value.created_by).to eq(actor)
  end

  it "è idempotente: ri-collegare lo stesso target non duplica" do
    described_class.call(log_entry: entry, linkable:, actor:)
    expect do
      described_class.call(log_entry: entry, linkable:, actor:)
    end.not_to change(Logs::Link, :count)
  end

  it "fallisce con R422-LOG-003 se il linkable è di un altro progetto (anti-BOLA)" do
    foreign = create(:error_group)
    result = described_class.call(log_entry: entry, linkable: foreign, actor:)
    expect(result).to be_err
    expect(result.error.code).to eq("R422-LOG-003")
  end
end
