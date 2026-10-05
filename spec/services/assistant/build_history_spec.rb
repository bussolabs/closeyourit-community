# frozen_string_literal: true

require "rails_helper"

RSpec.describe Assistant::BuildHistory do
  let(:conversation) { create(:assistant_conversation) }

  it "mappa i messaggi completi in contents coi ruoli user/model, in ordine cronologico" do
    create(:assistant_message, conversation: conversation, role: :user, content: "come apro un ticket?", created_at: 2.minutes.ago)
    create(:assistant_message, :assistant_reply, conversation: conversation, content: "Vai su Ticket.", created_at: 1.minute.ago)

    expect(described_class.call(conversation: conversation)).to eq([
      { role: "user",  parts: [ { text: "come apro un ticket?" } ] },
      { role: "model", parts: [ { text: "Vai su Ticket." } ] }
    ])
  end

  it "esclude i messaggi ancora in streaming o falliti (senza contenuto utile)" do
    create(:assistant_message, conversation: conversation, role: :user, content: "ciao")
    create(:assistant_message, :assistant_streaming, conversation: conversation)
    create(:assistant_message, :failed, conversation: conversation)

    result = described_class.call(conversation: conversation)
    expect(result.size).to eq(1)
    expect(result.first[:role]).to eq("user")
  end

  it "si ferma al messaggio corrente: esclude i turni creati dopo (invii ravvicinati)" do
    create(:assistant_message, conversation: conversation, role: :user, content: "prima domanda", created_at: 3.minutes.ago)
    corrente = create(:assistant_message, :assistant_streaming, conversation: conversation, created_at: 2.minutes.ago)
    # turno successivo, arrivato mentre il job del messaggio corrente era in coda
    create(:assistant_message, conversation: conversation, role: :user, content: "seconda domanda", created_at: 1.minute.ago)

    texts = described_class.call(conversation: conversation, until_message: corrente).map { |h| h[:parts].first[:text] }
    expect(texts).to eq([ "prima domanda" ])
  end

  it "garantisce che il contesto inizi con un turno user (un contents che parte da model non è valido)" do
    stub_const("Assistant::Constants::MAX_HISTORY_MESSAGES", 2)
    create(:assistant_message, conversation: conversation, role: :user, content: "u1", created_at: 3.minutes.ago)
    create(:assistant_message, :assistant_reply, conversation: conversation, content: "m1", created_at: 2.minutes.ago)
    create(:assistant_message, conversation: conversation, role: :user, content: "u2", created_at: 1.minute.ago)

    result = described_class.call(conversation: conversation)
    expect(result.first[:role]).to eq("user")
    expect(result.map { |h| h[:parts].first[:text] }).to eq(%w[u2])
  end

  it "tiene solo gli ultimi MAX_HISTORY_MESSAGES (i più recenti, in ordine)" do
    stub_const("Assistant::Constants::MAX_HISTORY_MESSAGES", 2)
    create(:assistant_message, conversation: conversation, content: "m2", created_at: 2.minutes.ago)
    create(:assistant_message, conversation: conversation, content: "m1", created_at: 1.minute.ago)
    create(:assistant_message, conversation: conversation, content: "m0", created_at: Time.current)

    texts = described_class.call(conversation: conversation).map { |h| h[:parts].first[:text] }
    expect(texts).to eq(%w[m1 m0])
  end
end
