# frozen_string_literal: true

require "rails_helper"

# CYRA-744 — il motore comune della consegna. Quello che ogni dominio fa in modo suo (chi riceve,
# cosa legge, quale pagina spedisce) resta nei payload e lo tengono le prove dei domini; qui stanno
# le poche cose che appartengono al motore e a nessun dominio in particolare.
RSpec.describe Notifications::Deliver do
  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }
  let(:group) { create(:error_group, project: project) }
  let(:account) do
    create(:account).tap { |a| create(:membership, account: a, organization: organization, role: :member) }
  end

  def payload(dedup_key: "motore:1", mailer: nil)
    Notifications::Payload.new(
      organization: organization, project: project, account: account, subject: group,
      event_type: "error_new", title: "Titolo", body: "Corpo", url: "/x",
      dedup_key: dedup_key, mailer: mailer
    )
  end

  it "il payload minimo di un dispatch diretto non ha regola, dettagli né mailer" do
    minimo = payload

    expect(minimo.rule).to be_nil
    expect(minimo.details).to be_nil
    expect(minimo.mailer).to be_nil
  end

  # Il default dell'esito duplicato: il simbolo, per chi lo tratta come esito atteso. Chi lo espone
  # a un chiamante HTTP (la chat) passa il proprio AppError e lo si vede nelle prove di quel dominio.
  it "senza indicazioni il doppione torna il simbolo :duplicate" do
    described_class.in_app(payload: payload)

    expect(described_class.in_app(payload: payload).error).to eq(:duplicate)
  end

  # Il canale email è l'unico che ha bisogno di sapere quale pagina spedire, e ogni dominio ha la
  # sua. Meglio rumoroso subito che una notifica che risulta consegnata e non è mai partita.
  it "il canale email senza mailer si ferma invece di dire che ha spedito" do
    expect { described_class.email(payload: payload) }
      .to raise_error(ArgumentError, /mailer/)
  end

  # CYRA-853 — la mail parte solo dove Telegram non ha portato l'avviso.
  describe ".reached_by_telegram?" do
    def notification(status) = build(:alerting_notification, status: status)

    it "Telegram spento o in riassunto: la mail serve" do
      expect(described_class.reached_by_telegram?(nil)).to be(false)
      expect(described_class.reached_by_telegram?(Result.ok(notification(:queued)))).to be(false)
    end

    it "Telegram fallito: la mail è la riserva" do
      expect(described_class.reached_by_telegram?(Result.ok(notification(:failed)))).to be(false)
    end

    it "Telegram consegnato o doppione della finestra: niente mail" do
      expect(described_class.reached_by_telegram?(Result.ok(notification(:sent)))).to be(true)
      expect(described_class.reached_by_telegram?(Result.err(:duplicate))).to be(true)
    end
  end

  # I cinque domini passano tutti di qui: se uno tornasse a consegnare per conto suo, questa prova
  # resterebbe verde e il guard di spec/config/notifications_delivery_split_spec.rb no — sono le
  # due metà della stessa Definition of Done.
  it "i punti d'ingresso dei domini consegnano tutti col motore comune" do
    domini = [ Alerting::Deliver, Chat::Notifications::Deliver, Secrets::Notifications::Deliver,
               Ticketing::Notifications::Deliver, Projects::Tokens::Notifications::Deliver ]

    expect(domini).to all(respond_to(:in_app, :email, :telegram))
  end
end
