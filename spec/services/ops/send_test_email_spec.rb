# frozen_string_literal: true

require "rails_helper"

# CYRA-233, prima voce della Definition of Done: «un'email di prova parte e arriva davvero al
# destinatario». Serviva un modo di provarlo che non fosse aspettare il prossimo guasto vero.
RSpec.describe Ops::SendTestEmail, type: :service do
  let(:recipient) { "operatore@example.test" }

  it "spedisce SUBITO al destinatario indicato, dal mittente reale del prodotto" do
    result = described_class.call(to: recipient)

    expect(result).to be_ok
    delivered = ActionMailer::Base.deliveries.last
    expect(delivered.to).to eq([ recipient ])
    expect(delivered.from).to eq([ Mail::Address.new(ApplicationMailer.default[:from]).address ])
  end

  # Deve passare dallo stesso mittente delle email vere: una prova che parte da un altro indirizzo non
  # prova niente sul dominio che si vuole verificare.
  it "l'oggetto dice che è una prova e da dove viene" do
    described_class.call(to: recipient)

    expect(ActionMailer::Base.deliveries.last.subject).to include("CloseYourIt").and include(Rails.env)
  end

  it "rifiuta un destinatario vuoto senza spedire nulla" do
    result = described_class.call(to: "  ")

    expect(result).to be_err
    expect(result.error.code).to eq("R422-MAIL-001")
    expect { described_class.call(to: "  ") }.not_to change { ActionMailer::Base.deliveries.count }
  end

  it "rifiuta un destinatario che non è un indirizzo" do
    expect(described_class.call(to: "non-un-indirizzo").error.code).to eq("R422-MAIL-001")
  end

  # Il rifiuto del fornitore è proprio l'informazione che si sta cercando: deve tornare leggibile, non
  # come eccezione sputata a schermo.
  it "riporta il motivo quando il fornitore rifiuta la spedizione, senza sollevare" do
    allow_any_instance_of(ActionMailer::MessageDelivery).to receive(:deliver_now)
      .and_raise(StandardError, "The domain is not verified")

    result = nil
    expect { result = described_class.call(to: recipient) }.not_to raise_error
    expect(result).to be_err
    expect(result.error.code).to eq("R502-MAIL-001")
    expect(result.error.message).to include("The domain is not verified")
  end
end
