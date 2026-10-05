# frozen_string_literal: true

require "rails_helper"

# CYRA-691 — il default ripiegava TUTTE le colonne concluse: chi arrivava per «cosa è stato
# consegnato» trovava chiusa esattamente quella metà. La fonte unica del default vive qui, letta
# dalla board, dalla roadmap e dalla materializzazione al primo tocco.
RSpec.describe Ticketing::BoardDefaults do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:open_status) { create(:ticket_status, organization:, code: "open") }
  let(:resolved) { create(:ticket_status, :done, organization:, code: "resolved") }
  let(:closed) { create(:ticket_status, :done, organization:, code: "closed") }

  def collapsed
    described_class.collapsed_codes([ open_status, resolved, closed ],
                                    Ticketing::Ticket.where(project_id: project.id))
  end

  it "ripiega le concluse vuote nella finestra recente, mai quelle di lavoro vivo" do
    expect(collapsed).to eq(Set.new(%w[resolved closed]))
  end

  it "una conclusa con un ticket chiuso di recente resta aperta" do
    create(:ticket, organization:, project:, status: resolved, closed_at: 2.days.ago)

    expect(collapsed).to eq(Set.new(%w[closed]))
  end

  it "un ticket chiuso fuori dalla finestra recente non tiene aperta la colonna" do
    create(:ticket, organization:, project:, status: resolved,
                    closed_at: (Ticketing::Constants::BOARD_DONE_WINDOW + 1.day).ago)

    expect(collapsed).to eq(Set.new(%w[resolved closed]))
  end

  it "senza colonne concluse non ripiega niente" do
    expect(described_class.collapsed_codes([ open_status ], Ticketing::Ticket.none)).to eq(Set.new)
  end
end
