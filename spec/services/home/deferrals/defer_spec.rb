# frozen_string_literal: true

require "rails_helper"

RSpec.describe Home::Deferrals::Defer do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let(:card_key) { "agent_plan:#{SecureRandom.uuid}" }

  def rimanda(**overrides)
    described_class.call(account:, organization:, card_key:, **overrides)
  end

  it "scrive il rimando e lo fa scadere domani mattina" do
    viaggio = Time.zone.parse("2026-08-24 15:30")

    result = rimanda(now: viaggio)

    expect(result).to be_ok
    expect(result.value.card_key).to eq(card_key)
    expect(result.value.until_at).to eq(Time.zone.parse("2026-08-25 07:00"))
  end

  it "rimanda a domani mattina anche se lo faccio a notte fonda" do
    result = rimanda(now: Time.zone.parse("2026-08-24 23:50"))

    expect(result.value.until_at).to eq(Time.zone.parse("2026-08-25 07:00"))
  end

  it "rimandare due volte la stessa card sposta la scadenza invece di aggiungere una riga" do
    rimanda(now: Time.zone.parse("2026-08-24 09:00"))

    expect { rimanda(now: Time.zone.parse("2026-08-25 09:00")) }
      .not_to change(Home::Deferral, :count)

    expect(Home::Deferral.sole.until_at).to eq(Time.zone.parse("2026-08-26 07:00"))
  end

  it "il rimando è di chi lo fa: un'altra persona sulla stessa card scrive una riga sua" do
    rimanda

    expect { described_class.call(account: create(:account), organization:, card_key:) }
      .to change(Home::Deferral, :count).by(1)
  end

  # Doppio clic, due schede, un rinvio del browser: la stessa richiesta arriva due volte e la
  # seconda trova la riga già scritta. È lo stesso gesto, non un conflitto: deve andare a buon fine.
  it "regge due richieste che si accavallano sulla stessa card, senza esplodere" do
    chiamate = 0
    allow_any_instance_of(Home::Deferral).to receive(:save).and_wrap_original do |original, *args|
      chiamate += 1
      # Alla prima chiamata qualcun altro ha già scritto la riga: l'indice unico scatta.
      if chiamate == 1
        create(:home_deferral, account:, organization:, card_key:)
        raise ActiveRecord::RecordNotUnique, "duplicate key"
      end
      original.call(*args)
    end

    result = rimanda(now: Time.zone.parse("2026-08-24 09:00"))

    expect(result).to be_ok
    expect(Home::Deferral.where(account_id: account.id, card_key:).count).to eq(1)
    expect(Home::Deferral.sole.until_at).to eq(Time.zone.parse("2026-08-25 07:00"))
  end

  it "rifiuta una chiave vuota invece di scrivere una riga senza senso" do
    result = rimanda(card_key: "   ")

    expect(result).to be_err
    expect(result.error.code).to eq("R422-HOMEDEFERRAL-002")
    expect(Home::Deferral.count).to be_zero
  end

  it "tiene l'organizzazione con cui il rimando è nato" do
    rimanda

    expect(Home::Deferral.sole.organization_id).to eq(organization.id)
  end
end
