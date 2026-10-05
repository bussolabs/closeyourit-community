# frozen_string_literal: true

require "rails_helper"

# CYRA-672 — il rilascio ACCODA il riepilogo: le righe passano a :pending («presa in carico»),
# non a :sent. Escono comunque dal trattenuto, quindi un secondo giro non le rispedisce, e a
# segnarle consegnate e' Notifications::DeliveryObserver quando il messaggio esce davvero.
RSpec.describe Notifications::ReleaseHeldJob, type: :job do
  let(:organization) { create(:organization) }
  let(:account) { create(:account) }

  # Notte 22→08 Europe/Rome: 02:30 Rome è dentro il silenzio, 08:00 Rome ne è appena fuori.
  def in_quiet(&) = travel_to(Time.utc(2026, 1, 15, 1, 30), &)  # Rome 02:30
  def after_quiet(&) = travel_to(Time.utc(2026, 1, 15, 7, 0), &) # Rome 08:00

  def held(title: "N", account: self.account, org: organization)
    create(:alerting_notification, account: account, organization: org, via: :email,
                                   status: :held, title: title)
  end

  it "scenario notturno: la :held creata nel silenzio resta trattenuta e viene consegnata a fine silenzio" do
    create(:alerting_preference, :quiet_nights, account: account, organization: organization)
    n = held

    in_quiet do
      described_class.perform_now
      expect(n.reload).to be_status_held # 02:30 Rome: silenzio attivo, nulla viene rilasciato
    end

    after_quiet do
      expect { described_class.perform_now }
        .to have_enqueued_mail(Notifications::DigestMailer, :summary).once
      expect(n.reload).to be_status_pending
    end
  end

  it "raccoglie tutte le email :held del gruppo in UN solo riepilogo e le toglie dal trattenuto" do
    create(:alerting_preference, :quiet_nights, account: account, organization: organization)
    a = held(title: "A")
    b = held(title: "B")

    after_quiet do
      expect { described_class.perform_now }
        .to have_enqueued_mail(Notifications::DigestMailer, :summary).once
    end

    expect(a.reload).to be_status_pending
    expect(b.reload).to be_status_pending
  end

  it "gruppo ancora nelle quiet hours → lascia le righe :held, nessuna mail" do
    create(:alerting_preference, :quiet_nights, account: account, organization: organization)
    n = held

    in_quiet do
      expect { described_class.perform_now }
        .not_to have_enqueued_mail(Notifications::DigestMailer, :summary)
    end

    expect(n.reload).to be_status_held
  end

  it "preferenza senza quiet hours (finestra rimossa) → rilascia comunque le :held rimaste" do
    # Nessuna preferenza persistita → quiet_now? è sempre false: una :held orfana non resta bloccata.
    n = held

    expect { described_class.perform_now }
      .to have_enqueued_mail(Notifications::DigestMailer, :summary).once
    expect(n.reload).to be_status_pending
  end

  it "vuoto → no-op (nessuna mail)" do
    expect { described_class.perform_now }
      .not_to have_enqueued_mail(Notifications::DigestMailer, :summary)
  end

  it "idempotente: un secondo run non re-invia (righe già uscite dal trattenuto)" do
    held
    described_class.perform_now

    expect { described_class.perform_now }
      .not_to have_enqueued_mail(Notifications::DigestMailer, :summary)
  end

  it "un riepilogo per ogni (account, organizzazione) distinto" do
    other = create(:account)
    held
    held(account: other)

    expect { described_class.perform_now }
      .to have_enqueued_mail(Notifications::DigestMailer, :summary).exactly(2).times
  end

  it "ignora le righe che non sono email :held (queued/pending/skipped/telegram/in-app)" do
    queued = create(:alerting_notification, account: account, organization: organization, via: :email,
                                            status: :queued, digest_bucket: :daily)
    skipped = create(:alerting_notification, account: account, organization: organization, via: :email,
                                             status: :skipped)
    telegram = create(:alerting_notification, account: account, organization: organization, via: :telegram,
                                              status: :held)

    described_class.perform_now

    expect(queued.reload).to be_status_queued
    expect(skipped.reload).to be_status_skipped
    expect(telegram.reload).to be_status_held
  end

  it "account sparito tra creazione e rilascio → salta il gruppo, riga ancora :held" do
    n = held
    allow(Accounts::Account).to receive(:find_by).and_return(nil)

    expect { described_class.perform_now }
      .not_to have_enqueued_mail(Notifications::DigestMailer, :summary)
    expect(n.reload).to be_status_held
  end

  it "organizzazione sparita tra creazione e rilascio → salta il gruppo, riga ancora :held" do
    n = held
    allow(Organizations::Organization).to receive(:find_by).and_return(nil)

    expect { described_class.perform_now }
      .not_to have_enqueued_mail(Notifications::DigestMailer, :summary)
    expect(n.reload).to be_status_held
  end

  # Senza questa voce le :held resterebbero trattenute per sempre finché il prune non le elimina: un
  # fallimento silenzioso peggiore del bug originale. Blinda che il rilascio giri davvero.
  it "è schedulato nel recurring di produzione" do
    schedule = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true).fetch("production")

    expect(schedule).to include(
      "release_held_notifications" => a_hash_including("class" => described_class.name, "queue" => "notifications")
    )
  end
end
