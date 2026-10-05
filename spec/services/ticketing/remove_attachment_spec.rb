# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ticketing::RemoveAttachment do
  let(:org) { create(:organization) }
  let(:ticket) { create(:ticket, organization: org) }
  let(:actor) { ticket.reporter }

  def attach!
    ticket.files.attach(
      io: File.open(Rails.root.join("spec/fixtures/files/screenshot.png")),
      filename: "screenshot.png", content_type: "image/png"
    )
    ticket.files.first
  end

  it "rimuove l'allegato (Result.ok)" do
    attachment = attach!
    result = described_class.call(ticket: ticket, attachment_id: attachment.id, actor: actor)
    expect(result).to be_ok
    expect(ticket.reload.files).not_to be_attached
  end

  it "registra `attachment_removed` con il filename snapshottato" do
    attachment = attach!
    expect do
      described_class.call(ticket: ticket, attachment_id: attachment.id, actor: actor)
    end.to change(Ticketing::Event, :count).by(1)

    event = Ticketing::Event.last
    expect(event.action).to eq("attachment_removed")
    expect(event.actor).to eq(actor)
    expect(event.data).to eq("filename" => "screenshot.png")
  end

  it "id inesistente → RecordNotFound (come il purge diretto sostituito)" do
    expect do
      described_class.call(ticket: ticket, attachment_id: SecureRandom.uuid, actor: actor)
    end.to raise_error(ActiveRecord::RecordNotFound)
  end

  it "registra true_actor in impersonation" do
    attachment = attach!
    god = create(:account)
    described_class.call(ticket: ticket, attachment_id: attachment.id, actor: actor, true_actor: god)
    expect(Ticketing::Event.last.true_actor).to eq(god)
  end
end
