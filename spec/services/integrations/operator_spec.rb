# frozen_string_literal: true

require "rails_helper"

RSpec.describe Integrations::Operator, type: :service do
  def organizzazione_con_proprietario(account)
    create(:organization).tap { |org| create(:membership, organization: org, account:, role: :owner) }
  end

  it "è l'organizzazione di chi gestisce l'installazione" do
    god = create(:account, god: true)
    sua = organizzazione_con_proprietario(god)
    organizzazione_con_proprietario(create(:account, god: false))

    expect(described_class.organization).to eq(sua)
  end

  it "un'organizzazione dove chi gestisce l'installazione è soltanto membro non conta" do
    god = create(:account, god: true)
    create(:membership, organization: create(:organization), account: god, role: :admin)

    expect(described_class.organization).to be_nil
  end

  # Il caso pericoloso: due candidate vogliono dire che nessuno sa quale sia «quella dell'operatore»,
  # e sbagliare significa consegnare la chiave — e il conto del consumo — a un'organizzazione che non
  # è la sua. Meglio non scegliere e lasciare che sia una persona a dirlo.
  it "con due candidate non ne sceglie una: l'ambiguità non si indovina" do
    organizzazione_con_proprietario(create(:account, god: true))
    organizzazione_con_proprietario(create(:account, god: true))

    expect(described_class.organization).to be_nil
  end

  it "senza nessun candidato non inventa niente" do
    organizzazione_con_proprietario(create(:account, god: false))

    expect(described_class.organization).to be_nil
  end
end
