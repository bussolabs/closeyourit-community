# frozen_string_literal: true

require "rails_helper"

RSpec.describe Secrets::Notifications::DispatchChangeRequested do
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

  def change_request_for(requester, **attrs)
    create(:secret_change_request, project: project, organization: organization, environment: environment,
                                   requested_by: requester, **attrs)
  end

  def dispatch(change_request)
    described_class.call(change_request: change_request)
  end

  describe "destinatari" do
    it "notifica l'owner dell'organizzazione" do
      owner = create(:account)
      member!(owner, :owner)
      requester = manager!

      dispatch(change_request_for(requester))

      expect(Alerting::Notification.where(account: owner, event_type: :secret_change_requested,
                                          subject: project)).to exist
    end

    it "notifica chi ha secrets.manage sul progetto" do
      requester = manager!
      other_manager = manager!

      dispatch(change_request_for(requester))

      expect(Alerting::Notification.where(account: other_manager, event_type: :secret_change_requested)).to exist
    end

    it "ESCLUDE chi vede il progetto ma non ha secrets.manage" do
      viewer = create(:account)
      member!(viewer)
      create(:project_membership, account: viewer, project: project)
      requester = manager!

      dispatch(change_request_for(requester))

      expect(Alerting::Notification.where(account: viewer)).not_to exist
    end

    it "ESCLUDE il richiedente, anche se ha secrets.manage sul progetto (è lui che deve aspettare)" do
      requester = manager!

      dispatch(change_request_for(requester))

      expect(Alerting::Notification.where(account: requester)).not_to exist
    end

    it "il richiedente è l'unico responsabile del progetto: nessuna notifica, nessun errore" do
      requester = manager!

      result = dispatch(change_request_for(requester))

      expect(result).to be_ok
      expect(result.value).to eq(0)
      expect(Alerting::Notification.count).to eq(0)
    end
  end

  describe "canali" do
    it "in-app sempre creata" do
      requester = manager!
      other_manager = manager!

      dispatch(change_request_for(requester))

      expect(Alerting::Notification.where(account: other_manager, via: :in_app,
                                          event_type: :secret_change_requested)).to exist
    end

    it "accoda la mail quando l'email è attiva (default canale acceso)" do
      requester = manager!
      other_manager = manager!

      expect { dispatch(change_request_for(requester)) }
        .to have_enqueued_mail(Secrets::SecretNotificationsMailer, :notify)
      expect(Alerting::Notification.where(account: other_manager, via: :email,
                                          event_type: :secret_change_requested)).to exist
    end

    it "cadenza email off per l'evento → nessuna email, l'in-app resta" do
      requester = manager!
      other_manager = manager!
      create(:alerting_preference, account: other_manager, organization: organization,
                                   email_cadences: { "secret_change_requested" => "off" })

      dispatch(change_request_for(requester))

      expect(Alerting::Notification.where(account: other_manager, via: :in_app)).to exist
      expect(Alerting::Notification.where(account: other_manager, via: :email)).not_to exist
    end

    it "telegram acceso + account collegato → invia il DM e crea la riga via telegram" do
      requester = manager!
      other_manager = manager!
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("TELEGRAM_BOT_TOKEN").and_return("999:xyz")
      stub = stub_request(:post, "https://api.telegram.org/bot999:xyz/sendMessage").to_return(status: 200)
      other_manager.update!(telegram_chat_id: "800")
      create(:alerting_preference, account: other_manager, organization: organization, telegram_enabled: true)

      dispatch(change_request_for(requester))

      expect(stub).to have_been_requested
      expect(Alerting::Notification.where(account: other_manager, via: :telegram,
                                          event_type: :secret_change_requested)).to exist
    end

    it "telegram acceso ma account NON collegato → nessuna notifica telegram" do
      requester = manager!
      other_manager = manager!
      create(:alerting_preference, account: other_manager, organization: organization, telegram_enabled: true)

      dispatch(change_request_for(requester))

      expect(Alerting::Notification.where(account: other_manager, via: :telegram)).not_to exist
    end
  end

  describe "idempotenza (dedup_key ancorato alla change request, una CR nasce una volta sola)" do
    it "due dispatch della STESSA change request non duplicano" do
      requester = manager!
      other_manager = manager!
      change_request = change_request_for(requester)

      dispatch(change_request)
      expect { dispatch(change_request) }.not_to change(Alerting::Notification, :count)

      expect(Alerting::Notification.where(account: other_manager, via: :in_app).count).to eq(1)
    end
  end

  describe "contenuto" do
    it "il subject della notifica è il progetto" do
      requester = manager!
      manager!
      change_request = change_request_for(requester, name: "API_KEY")

      dispatch(change_request)

      notification = Alerting::Notification.find_by(event_type: :secret_change_requested, via: :in_app)
      expect(notification.subject).to eq(project)
    end

    it "titolo con nome/progetto/ambiente/richiedente, mai il valore proposto" do
      requester = manager!
      requester.update!(name: "Mario Rossi")
      manager!
      change_request = change_request_for(requester, name: "DATABASE_URL", value: "s3cr3t-plain")

      dispatch(change_request)

      notification = Alerting::Notification.find_by(event_type: :secret_change_requested, via: :in_app)
      expect(notification.title).to include("DATABASE_URL").and include(project.name).and include("Mario Rossi")
      expect(notification.title).not_to include("s3cr3t-plain")
      expect(notification.body).not_to include("s3cr3t-plain")
    end

    it "url punta alla pagina delle richieste in attesa" do
      requester = manager!
      manager!
      change_request = change_request_for(requester)

      dispatch(change_request)

      notification = Alerting::Notification.find_by(event_type: :secret_change_requested, via: :in_app)
      expect(notification.url).to eq(Rails.application.routes.url_helpers.member_vault_attention_path)
    end
  end
end
