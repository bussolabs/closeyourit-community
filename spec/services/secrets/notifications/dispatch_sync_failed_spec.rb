# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::Notifications::DispatchSyncFailed do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }

  def member!(account, role = :member) = create(:membership, account: account, organization: organization, role: role)

  def role_with(name, *keys)
    role = create(:role, organization: organization, name: name)
    keys.each { |k| create(:role_permission, role: role, permission_key: k) }
    role
  end

  def manager!
    account = create(:account)
    member!(account)
    create(:project_membership, account: account, project: project)
    create(:account_role, account: account, organization: organization,
                          role: role_with("Vault admin #{SecureRandom.hex(3)}", "secrets.manage"))
    account
  end

  def dispatch(reason: nil, at: Time.current)
    described_class.call(project: project, reason: reason, at: at)
  end

  describe "destinatari" do
    it "notifica l'owner dell'organizzazione" do
      owner = create(:account)
      member!(owner, :owner)

      dispatch

      expect(Alerting::Notification.where(account: owner, event_type: :secret_sync_failed, subject: project)).to exist
    end

    it "notifica chi ha secrets.manage sul progetto" do
      manager = manager!

      dispatch

      expect(Alerting::Notification.where(account: manager, event_type: :secret_sync_failed, subject: project)).to exist
    end

    it "ESCLUDE chi vede il progetto ma non ha secrets.manage" do
      viewer = create(:account)
      member!(viewer)
      create(:project_membership, account: viewer, project: project)

      dispatch

      expect(Alerting::Notification.where(account: viewer)).not_to exist
    end

    it "nessun attore da escludere: è un evento di sistema, l'owner viene sempre notificato" do
      owner = create(:account)
      member!(owner, :owner)

      dispatch

      expect(Alerting::Notification.where(account: owner, subject: project)).to exist
    end
  end

  describe "canali" do
    it "in-app sempre creata" do
      manager = manager!
      dispatch
      expect(Alerting::Notification.where(account: manager, via: :in_app, event_type: :secret_sync_failed)).to exist
    end

    it "accoda la mail quando l'email è attiva (default canale acceso)" do
      manager = manager!
      expect { dispatch }.to have_enqueued_mail(Secrets::SecretNotificationsMailer, :notify)
      expect(Alerting::Notification.where(account: manager, via: :email, event_type: :secret_sync_failed)).to exist
    end

    it "cadenza email off per l'evento → nessuna email, l'in-app resta" do
      manager = manager!
      create(:alerting_preference, account: manager, organization: organization,
                                   email_cadences: { "secret_sync_failed" => "off" })
      dispatch
      expect(Alerting::Notification.where(account: manager, via: :in_app)).to exist
      expect(Alerting::Notification.where(account: manager, via: :email)).not_to exist
    end

    it "telegram acceso + account collegato → invia il DM e crea la riga via telegram" do
      manager = manager!
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("TELEGRAM_BOT_TOKEN").and_return("999:xyz")
      stub = stub_request(:post, "https://api.telegram.org/bot999:xyz/sendMessage").to_return(status: 200)
      manager.update!(telegram_chat_id: "800")
      create(:alerting_preference, account: manager, organization: organization, telegram_enabled: true)

      dispatch

      expect(stub).to have_been_requested
      expect(Alerting::Notification.where(account: manager, via: :telegram, event_type: :secret_sync_failed)).to exist
    end
  end

  describe "idempotenza (finestra scelta: una notifica al giorno per progetto, non per retry/causa)" do
    it "due fallimenti nello stesso giorno → una sola notifica per destinatario" do
      manager = manager!

      dispatch(at: Time.zone.local(2026, 7, 17, 9, 0))
      expect { dispatch(at: Time.zone.local(2026, 7, 17, 18, 0)) }.not_to change(Alerting::Notification, :count)

      expect(Alerting::Notification.where(account: manager, via: :in_app).count).to eq(1)
    end

    it "un fallimento il giorno dopo riarma un nuovo avviso" do
      manager = manager!
      dispatch(at: Time.zone.local(2026, 7, 17, 9, 0))

      expect { dispatch(at: Time.zone.local(2026, 7, 18, 9, 0)) }.to change(Alerting::Notification, :count)
      expect(Alerting::Notification.where(account: manager, via: :in_app).count).to eq(2)
    end

    it "cause diverse nello stesso giorno restano UNA notifica (finestra per progetto+giorno, non per causa)" do
      manager = manager!
      dispatch(reason: "R422-GITHUB-006", at: Time.zone.local(2026, 7, 17, 9, 0))

      expect { dispatch(reason: "R502-GITHUB-001", at: Time.zone.local(2026, 7, 17, 10, 0)) }
        .not_to change(Alerting::Notification, :count)
      expect(Alerting::Notification.where(account: manager, via: :in_app).count).to eq(1)
    end
  end

  describe "contenuto" do
    it "il subject della notifica è il progetto" do
      manager!
      dispatch
      notification = Alerting::Notification.find_by(event_type: :secret_sync_failed, via: :in_app)
      expect(notification.subject).to eq(project)
    end

    it "titolo col nome del progetto" do
      manager!
      dispatch
      notification = Alerting::Notification.find_by(event_type: :secret_sync_failed, via: :in_app)
      expect(notification.title).to include(project.name)
    end

    it "senza motivo: corpo generico comunque presente" do
      manager!
      dispatch(reason: nil)
      notification = Alerting::Notification.find_by(event_type: :secret_sync_failed, via: :in_app)
      expect(notification.body).to be_present
    end

    it "con motivo: il corpo riporta il codice sintetico" do
      manager!
      dispatch(reason: "R502-GITHUB-001")
      notification = Alerting::Notification.find_by(event_type: :secret_sync_failed, via: :in_app)
      expect(notification.body).to include("R502-GITHUB-001")
    end
  end
end
