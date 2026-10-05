# frozen_string_literal: true

require "rails_helper"

RSpec.describe Embeddings::CheckVersionDriftJob do
  before do
    Ticketing::Ticket.delete_all
    Errors::Group.delete_all
    Knowledge::Page.delete_all
  end

  it "logga un WARN coi conteggi quando restano righe embeddate invisibili alla ricerca" do
    stale = create(:ticket)
    stale.update_columns(embedding: basis_vector(0), embedding_version: nil)

    allow(Rails.logger).to receive(:warn)
    described_class.perform_now

    expect(Rails.logger).to have_received(:warn).with(a_string_including("tickets=stale:1/missing:0"))
  end

  # CYRA-232: il buco silenzioso da guasto (righe mai indicizzate) deve finire nei registri, non solo le
  # versioni obsolete.
  it "logga anche i contenuti mai indicizzati rimasti oltre la grazia" do
    never = create(:ticket)
    never.update_columns(embedding: nil, created_at: 2.hours.ago)

    allow(Rails.logger).to receive(:warn)
    described_class.perform_now

    expect(Rails.logger).to have_received(:warn).with(a_string_including("missing:1"))
  end

  it "non logga nulla quando ogni riga embeddata è alla versione corrente" do
    ok = create(:ticket)
    ok.update_columns(embedding: basis_vector(0), embedding_version: Ai::Constants::EMBEDDING_VERSION)

    allow(Rails.logger).to receive(:warn)
    described_class.perform_now

    expect(Rails.logger).not_to have_received(:warn)
  end

  # DoD: la normale attesa di pochi minuti dopo una modifica non deve far scattare il segnale.
  it "non logga per una riga senza embedding ancora entro la grazia" do
    fresh = create(:ticket)
    fresh.update_columns(embedding: nil, created_at: 1.minute.ago)

    allow(Rails.logger).to receive(:warn)
    described_class.perform_now

    expect(Rails.logger).not_to have_received(:warn)
  end

  it "è di sola lettura: rileva ma non ripara le versioni mancanti" do
    stale = create(:ticket)
    stale.update_columns(embedding: basis_vector(0), embedding_version: nil)

    expect { described_class.perform_now }.not_to(change { stale.reload.embedding_version })
  end
end
