# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::BackfillEmbeddingsJob do
  it "senza ticket non accoda nulla" do
    expect { described_class.perform_now }.not_to have_enqueued_job(Ticketing::EmbedTicketJob)
  end

  it "accoda EmbedTicketJob per ogni ticket mai embeddato" do
    tickets = create_list(:ticket, 2)

    expect { described_class.perform_now }
      .to have_enqueued_job(Ticketing::EmbedTicketJob).with(ticket_id: tickets.first.id)
      .and have_enqueued_job(Ticketing::EmbedTicketJob).with(ticket_id: tickets.second.id)
  end

  it "salta i ticket col checksum fresco e accoda quelli stale" do
    fresh = create(:ticket)
    fresh.update_columns(embedding: basis_vector(0),
                         embedding_checksum: Ticketing::EmbeddingText.checksum(ticket: fresh))
    stale = create(:ticket)
    stale.update_columns(embedding: basis_vector(1), embedding_checksum: "vecchia-versione")

    expect { described_class.perform_now }
      .to have_enqueued_job(Ticketing::EmbedTicketJob).with(ticket_id: stale.id).exactly(:once)
    expect(Ticketing::EmbedTicketJob).not_to have_been_enqueued.with(ticket_id: fresh.id)
  end

  # CYRA-232: ora è schedulato daily → il checksum degli embeddati carica ticket.scenarios per ogni
  # riga. Senza preload è un N+1 sull'intero storico. Prosopite non scanna i job spec in automatico:
  # apro io la finestra.
  it "non genera un N+1 sugli scenari calcolando i checksum" do
    create_list(:ticket, 3).each_with_index do |ticket, i|
      ticket.update_columns(embedding: basis_vector(i),
                            embedding_checksum: Ticketing::EmbeddingText.checksum(ticket: ticket))
    end

    Prosopite.scan
    described_class.perform_now
    expect { Prosopite.finish }.not_to raise_error
  end
end
