# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::Notifications::DispatchChangeApproved do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization: organization) }
  let(:environment) { create(:environment, organization: organization).tap { |env| project.environments << env } }

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

  def applied_request_for(requester, **attrs)
    create(:secret_change_request, project: project, organization: organization, environment: environment,
                                   requested_by: requester, status: :applied, decided_by: create(:account),
                                   decided_at: Time.current, **attrs)
  end

  def dispatch(change_request)
    described_class.call(change_request: change_request)
  end

  describe "destinatario" do
    it "notifica SOLO il richiedente" do
      requester = manager!
      other_manager = manager!

      dispatch(applied_request_for(requester))

      expect(Alerting::Notification.where(account: requester, event_type: :secret_change_approved,
                                          subject: project)).to exist
      expect(Alerting::Notification.where(account: other_manager)).not_to exist
    end

    it "il richiedente è anche owner: riceve comunque una sola notifica in-app" do
      requester = create(:account)
      member!(requester, :owner)
      create(:project_membership, account: requester, project: project)

      dispatch(applied_request_for(requester))

      expect(Alerting::Notification.where(account: requester, via: :in_app,
                                          event_type: :secret_change_approved).count).to eq(1)
    end

    it "richiedente non più risolvibile (account cancellato, requested_by nullificato dalla FK): " \
       "nessun invio, nessun errore" do
      requester = manager!
      change_request = applied_request_for(requester)
      requester.destroy!
      change_request.reload
      expect(change_request.requested_by_id).to be_nil # sanity: la FK nullify ha davvero fatto il suo lavoro

      result = dispatch(change_request)

      expect(result).to be_ok
      expect(result.value).to eq(0)
      expect(Alerting::Notification.count).to eq(0)
    end
  end

  describe "canali" do
    it "in-app sempre creata" do
      requester = manager!

      dispatch(applied_request_for(requester))

      expect(Alerting::Notification.where(account: requester, via: :in_app,
                                          event_type: :secret_change_approved)).to exist
    end

    it "accoda la mail quando l'email è attiva (default canale acceso)" do
      requester = manager!

      expect { dispatch(applied_request_for(requester)) }
        .to have_enqueued_mail(Secrets::SecretNotificationsMailer, :notify)
      expect(Alerting::Notification.where(account: requester, via: :email,
                                          event_type: :secret_change_approved)).to exist
    end

    it "cadenza email off per l'evento → nessuna email, l'in-app resta" do
      requester = manager!
      create(:alerting_preference, account: requester, organization: organization,
                                   email_cadences: { "secret_change_approved" => "off" })

      dispatch(applied_request_for(requester))

      expect(Alerting::Notification.where(account: requester, via: :in_app)).to exist
      expect(Alerting::Notification.where(account: requester, via: :email)).not_to exist
    end

    it "telegram acceso + account collegato → invia il DM e crea la riga via telegram" do
      requester = manager!
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("TELEGRAM_BOT_TOKEN").and_return("999:xyz")
      stub = stub_request(:post, "https://api.telegram.org/bot999:xyz/sendMessage").to_return(status: 200)
      requester.update!(telegram_chat_id: "800")
      create(:alerting_preference, account: requester, organization: organization, telegram_enabled: true)

      dispatch(applied_request_for(requester))

      expect(stub).to have_been_requested
      expect(Alerting::Notification.where(account: requester, via: :telegram,
                                          event_type: :secret_change_approved)).to exist
    end
  end

  describe "idempotenza (una CR è decisa una volta sola)" do
    it "due dispatch della STESSA change request non duplicano" do
      requester = manager!
      change_request = applied_request_for(requester)

      dispatch(change_request)
      expect { dispatch(change_request) }.not_to change(Alerting::Notification, :count)

      expect(Alerting::Notification.where(account: requester, via: :in_app).count).to eq(1)
    end
  end

  describe "contenuto" do
    it "il subject della notifica è il progetto" do
      requester = manager!
      change_request = applied_request_for(requester, name: "API_KEY")

      dispatch(change_request)

      notification = Alerting::Notification.find_by(event_type: :secret_change_approved, via: :in_app)
      expect(notification.subject).to eq(project)
    end

    it "titolo con nome/progetto/ambiente, mai il valore del secret" do
      requester = manager!
      change_request = applied_request_for(requester, name: "DATABASE_URL", value: "s3cr3t-plain")

      dispatch(change_request)

      notification = Alerting::Notification.find_by(event_type: :secret_change_approved, via: :in_app)
      expect(notification.title).to include("DATABASE_URL").and include(project.name)
      expect(notification.title).not_to include("s3cr3t-plain")
      expect(notification.body).not_to include("s3cr3t-plain")
    end

    it "url punta alla tab Secrets del progetto (stato reale, non la change request)" do
      requester = manager!
      change_request = applied_request_for(requester)

      dispatch(change_request)

      notification = Alerting::Notification.find_by(event_type: :secret_change_approved, via: :in_app)
      expect(notification.url).to eq(Rails.application.routes.url_helpers.member_project_secrets_path(project))
    end
  end
end
