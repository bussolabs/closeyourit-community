# frozen_string_literal: true

require "rails_helper"

# Connection channel spec (ActionCable::Connection::TestCase via rspec-rails, type: :channel).
# Copre: autorizzazione con sessione cookie valida, rifiuto senza sessione, rifiuto cross-tenant
# (BOLA), e i confini di risoluzione dell'organizzazione (org richiesta vs fallback vs nessuna).
#
# Note di harness:
#  - `cookies.signed[:session_id] = ...` imposta il cookie firmato letto da find_verified_session.
#  - L'org richiesta (`session[:organization_id]`) vive nel cookie di sessione cifrato; nel test
#    si inietta via `cookies.encrypted[<session key>] = { value: { "organization_id" => ... } }`
#    (il TestCookieJar estrae :value). Stessa via di lettura usata in produzione
#    (cookies.encrypted[session key]), quindi il test è fedele al runtime.
RSpec.describe ApplicationCable::Connection, type: :channel do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }
  let!(:membership) { create(:membership, account: account, organization: organization) }
  let(:session) { create(:session, account: account) }

  def session_cookie_key
    Rails.application.config.session_options[:key]
  end

  def request_organization(org)
    cookies.encrypted[session_cookie_key] = { value: { "organization_id" => org.id } }
  end

  describe "#connect — autenticazione" do
    it "autorizza con cookie di sessione valido e identifica account, sessione e org" do
      cookies.signed[:session_id] = session.id

      connect

      expect(connection.current_account).to eq(account)
      expect(connection.current_session).to eq(session)
      expect(connection.current_organization).to eq(organization)
    end

    it "usa l'account impersonato quando la sessione impersona (come resume_session)" do
      god = create(:account, god: true)
      impersonating = create(:session, account: god, impersonated_account: account)
      cookies.signed[:session_id] = impersonating.id

      connect

      expect(connection.current_account).to eq(account)
      expect(connection.current_session).to eq(impersonating)
    end

    it "RIFIUTA senza alcun cookie di sessione" do
      expect { connect }.to have_rejected_connection
    end

    it "RIFIUTA se il cookie punta a una sessione inesistente" do
      cookies.signed[:session_id] = SecureRandom.uuid

      expect { connect }.to have_rejected_connection
    end

    it "RIFIUTA se la sessione è scaduta oltre la finestra assoluta (CYRA-272)" do
      cookies.signed[:session_id] = create(:session, :expired, account: account).id

      expect { connect }.to have_rejected_connection
    end

    it "RIFIUTA se la sessione è idle oltre il timeout di inattività (CYRA-272)" do
      cookies.signed[:session_id] = create(:session, :idle, account: account).id

      expect { connect }.to have_rejected_connection
    end
  end

  describe "#connect — risoluzione organizzazione (anti-BOLA)" do
    it "onora l'org richiesta in sessione quando l'account ne è membro" do
      other = create(:organization)
      create(:membership, account: account, organization: other)
      cookies.signed[:session_id] = session.id
      request_organization(other)

      connect

      expect(connection.current_organization).to eq(other)
    end

    it "RIFIUTA (BOLA) quando la sessione richiede un'org su cui l'account non ha membership" do
      foreign = create(:organization) # nessuna membership per `account`
      cookies.signed[:session_id] = session.id
      request_organization(foreign)

      expect { connect }.to have_rejected_connection
    end

    it "ricade sulla prima membership quando in sessione non c'è org richiesta" do
      cookies.signed[:session_id] = session.id

      connect

      expect(connection.current_organization).to eq(organization)
    end

    it "autorizza con current_organization nil per un account senza alcuna membership" do
      loner = create(:account)
      loner_session = create(:session, account: loner)
      cookies.signed[:session_id] = loner_session.id

      connect

      expect(connection.current_account).to eq(loner)
      expect(connection.current_organization).to be_nil
    end

    it "cookie di sessione illeggibile (payload non-hash) → org fallback, nessun raise (rescue)" do
      cookies.signed[:session_id] = session.id
      # Payload non-Hash: la lettura di ["organization_id"] solleva → rescue → nil → fallback membership.
      cookies.encrypted[session_cookie_key] = { value: 5 }

      connect

      expect(connection.current_organization).to eq(organization)
    end
  end

  # CYRA-722 — chiusa la porta HTTP resta questa: una pagina già aperta tiene il suo canale in tempo
  # reale e continua a ricevere messaggi, presenze e aggiornamenti dell'organizzazione sospesa. È lo
  # stesso accesso, per un'altra via.
  describe "#connect — organizzazione sospesa" do
    it "RIFIUTA la connessione di un membro" do
      organization.update!(suspended_at: Time.current)
      cookies.signed[:session_id] = session.id

      expect { connect }.to have_rejected_connection
    end

    it "RIFIUTA anche quando l'organizzazione sospesa è quella richiesta in sessione" do
      organization.update!(suspended_at: Time.current)
      cookies.signed[:session_id] = session.id
      request_organization(organization)

      expect { connect }.to have_rejected_connection
    end

    it "l'amministratore globale resta connesso" do
      god = create(:account, god: true)
      create(:membership, account: god, organization: organization, role: :owner)
      god_session = create(:session, account: god)
      organization.update!(suspended_at: Time.current)
      cookies.signed[:session_id] = god_session.id

      connect

      expect(connection.current_organization).to eq(organization)
    end

    it "riattivata l'organizzazione, la connessione torna ad aprirsi" do
      organization.update!(suspended_at: Time.current)
      organization.update!(suspended_at: nil)
      cookies.signed[:session_id] = session.id

      connect

      expect(connection.current_organization).to eq(organization)
    end
  end
end
