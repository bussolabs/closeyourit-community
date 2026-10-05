# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Impersonations", type: :request do
  let(:god) { create(:account, god: true) }
  let(:target) { create(:account, email: "target@example.com") }

  # CYRA-170: il god passa dal 2FA (attivato al volo + secondo fattore) così può entrare in Valhalla;
  # gli account non-god restano invariati.
  def sign_in_as(account)
    enable_two_factor!(account) if account.god? && !account.otp_enabled?
    post login_path, params: { email: account.email, password: "Secret123!" }
    complete_two_factor(account) if account.otp_enabled?
  end

  # CYRA-719: l'avvio dell'impersonation richiede DI NUOVO il secondo fattore (start_impersonation_as
  # genera il codice nella finestra TOTP successiva, perché quello del login è già consumato).
  def impersonate(params)
    start_impersonation_as(god, params)
  end

  describe "POST /impersonation" do
    it "il god impersona: l'app vede l'account target e crea l'evento" do
      sign_in_as(god)
      expect { impersonate(account_id: target.id) }
        .to change(Accounts::ImpersonationEvent, :count).by(1)
      expect(response).to redirect_to(root_path)

      get root_path
      expect(response.body).to include("target@example.com")
      expect(response.body).to include('data-test="impersonation-banner"')
    end

    it "non può impersonare se stesso" do
      sign_in_as(god)
      impersonate(account_id: god.id)
      expect(response).to redirect_to(valhalla_accounts_path)
    end

    it "un account non-god non può impersonare" do
      non_god = create(:account, god: false)
      sign_in_as(non_god)
      target
      expect { post impersonation_path, params: { account_id: target.id } }
        .not_to change(Accounts::ImpersonationEvent, :count)
      expect(response).to redirect_to(root_path)
    end
  end

  describe "POST /impersonation con organization_id (entra nell'org)" do
    let(:owner) { create(:account, email: "owner@acme.test") }
    let(:organization) { create(:organization, name: "Acme") }

    before { create(:membership, organization: organization, account: owner, role: :owner) }

    it "impersona l'owner dell'org e imposta il contesto org in sessione" do
      sign_in_as(god)

      expect { impersonate(organization_id: organization.id) }
        .to change(Accounts::ImpersonationEvent, :count).by(1)
      expect(response).to redirect_to(root_path)
      expect(session[:organization_id]).to eq(organization.id)
      expect(Accounts::ImpersonationEvent.open.last.account).to eq(owner)
    end

    it "atterra nell'org entrata anche se l'owner appartiene a piu' org" do
      other = create(:organization, name: "Altra")
      create(:membership, organization: other, account: owner, role: :member)
      sign_in_as(god)

      impersonate(organization_id: organization.id)
      get root_path

      expect(response.body).to include('data-test="member-org-switcher"')
      expect(session[:organization_id]).to eq(organization.id)
    end

    it "senza owner usa il primo membro come rappresentante" do
      no_owner_org = create(:organization, name: "Senza Owner")
      member = create(:account, email: "member@acme.test")
      create(:membership, organization: no_owner_org, account: member, role: :member)
      sign_in_as(god)

      expect { impersonate(organization_id: no_owner_org.id) }
        .to change(Accounts::ImpersonationEvent, :count).by(1)
      expect(Accounts::ImpersonationEvent.open.last.account).to eq(member)
    end

    it "org senza membri: alert e nessuna impersonazione" do
      empty_org = create(:organization, name: "Vuota")
      sign_in_as(god)

      expect { impersonate(organization_id: empty_org.id) }
        .not_to change(Accounts::ImpersonationEvent, :count)
      expect(response).to redirect_to(valhalla_organization_path(empty_org))
    end

    it "un account non-god non puo' entrare" do
      sign_in_as(create(:account, god: false))

      expect { post impersonation_path, params: { organization_id: organization.id } }
        .not_to change(Accounts::ImpersonationEvent, :count)
      expect(response).to redirect_to(root_path)
    end
  end

  # CYRA-719: una sessione god rubata non deve poter entrare nei panni di chiunque solo perché il
  # cookie è valido. Il secondo fattore va ridimostrato QUI, sull'avvio, non solo al login.
  describe "GET /impersonation/new (conferma col secondo fattore)" do
    it "mostra il modulo con il codice per l'account bersaglio" do
      sign_in_as(god)

      get new_impersonation_path, params: { account_id: target.id }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="impersonation-confirm-form"')
      expect(response.body).to include("target@example.com")
    end

    it "mostra il modulo per l'organizzazione, col nome dell'organizzazione" do
      organization = create(:organization, name: "Acme")
      create(:membership, organization: organization, account: create(:account), role: :owner)
      sign_in_as(god)

      get new_impersonation_path, params: { organization_id: organization.id }

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="impersonation-confirm-form"')
      expect(response.body).to include("Acme")
    end

    it "org senza membri: nessun modulo da mostrare, torna alla scheda con l'avviso" do
      empty_org = create(:organization, name: "Vuota")
      sign_in_as(god)

      get new_impersonation_path, params: { organization_id: empty_org.id }

      expect(response).to redirect_to(valhalla_organization_path(empty_org))
    end

    it "un account non-god non raggiunge il modulo" do
      sign_in_as(create(:account, god: false))
      target

      get new_impersonation_path, params: { account_id: target.id }

      expect(response).to redirect_to(root_path)
    end
  end

  describe "POST /impersonation senza secondo fattore valido (CYRA-719)" do
    it "senza codice non impersona e ripropone il modulo" do
      sign_in_as(god)

      expect { post impersonation_path, params: { account_id: target.id } }
        .not_to change(Accounts::ImpersonationEvent, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('data-test="impersonation-confirm-form"')
    end

    it "con codice errato non impersona e ripropone il modulo" do
      sign_in_as(god)

      expect { post impersonation_path, params: { account_id: target.id, code: "000000" } }
        .not_to change(Accounts::ImpersonationEvent, :count)
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.body).to include('data-test="impersonation-confirm-form"')
    end

    it "il codice del login non vale una seconda volta (già consumato)" do
      enable_two_factor!(god)
      code = current_totp(god)
      post login_path, params: { email: god.email, password: "Secret123!" }
      post two_factor_challenge_path, params: { code: code }

      expect { post impersonation_path, params: { account_id: target.id, code: code } }
        .not_to change(Accounts::ImpersonationEvent, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "lo stesso codice non riapre una seconda impersonation" do
      sign_in_as(god)
      other = create(:account, email: "altro@example.com")

      travel_to(1.minute.from_now) do
        code = current_totp(god)
        post impersonation_path, params: { account_id: target.id, code: code }
        delete impersonation_path

        expect { post impersonation_path, params: { account_id: other.id, code: code } }
          .not_to change(Accounts::ImpersonationEvent, :count)
        expect(response).to have_http_status(:unprocessable_content)
      end
    end
  end

  # CYRA-719: il freno per indirizzo non basta da solo — un cookie rubato si usa da mille indirizzi
  # diversi contro un codice di sei cifre. I tentativi si contano anche SULLA SESSIONE, server-side.
  describe "lockout dopo troppi tentativi falliti (CYRA-719)" do
    # In test il cache è :null_store → lo sostituiamo con un MemoryStore reale per l'esempio, così il
    # contatore persiste tra le richieste (in produzione è Solid Cache). Stessa forma del lockout della
    # challenge di login.
    let(:lockout_cache) { ActiveSupport::Cache::MemoryStore.new }

    before { allow(Rails).to receive(:cache).and_return(lockout_cache) }

    # allow_n_plus_one: l'example fa N richieste HTTP di seguito; il lookup account per-richiesta NON è
    # un N+1 di produzione (ogni richiesta è isolata) → prosopite lo conterebbe come falso positivo.
    it "raggiunta la soglia la sessione muore: nemmeno un codice valido impersona più" do
      sign_in_as(god)

      allow_n_plus_one do
        (Accounts::Constants::OTP_MAX_ATTEMPTS - 1).times do
          post impersonation_path, params: { account_id: target.id, code: "000000" }
          expect(response).to have_http_status(:unprocessable_content)
        end

        post impersonation_path, params: { account_id: target.id, code: "000000" } # tocca la soglia
        expect(response).to redirect_to(login_path)

        expect { impersonate(account_id: target.id) }
          .not_to change(Accounts::ImpersonationEvent, :count)
        expect(response).to redirect_to(login_path)
      end
    end

    it "un codice valido entro la soglia impersona: i tentativi falliti non bloccano da soli" do
      sign_in_as(god)

      allow_n_plus_one do
        (Accounts::Constants::OTP_MAX_ATTEMPTS - 1).times do
          post impersonation_path, params: { account_id: target.id, code: "000000" }
        end

        expect { impersonate(account_id: target.id) }
          .to change(Accounts::ImpersonationEvent, :count).by(1)
        expect(response).to redirect_to(root_path)
      end
    end

    it "un avvio riuscito azzera il conto: i falliti di prima non si sommano ai successivi" do
      sign_in_as(god)

      allow_n_plus_one do
        (Accounts::Constants::OTP_MAX_ATTEMPTS - 1).times do
          post impersonation_path, params: { account_id: target.id, code: "000000" }
        end
        impersonate(account_id: target.id)
        delete impersonation_path

        post impersonation_path, params: { account_id: target.id, code: "000000" }
        expect(response).to have_http_status(:unprocessable_content) # non è lockout: il conto è ripartito
      end
    end
  end

  # FIX-10: l'impersonation è top-level (fuori da Valhalla) → il gate 2FA di FIX-5 va applicato QUI, ma
  # SOLO sull'avvio (create). Un attaccante con la sola password del god non deve poter impersonare.
  describe "gate 2FA sull'avvio impersonation (FIX-10)" do
    it "un god SENZA 2FA non può avviare un'impersonation → redirect all'enrollment, nessuna impersonation" do
      god_no2fa = create(:account, god: true)
      post login_path, params: { email: god_no2fa.email, password: "Secret123!" } # login diretto (no 2FA)

      expect { post impersonation_path, params: { account_id: target.id } }
        .not_to change(Accounts::ImpersonationEvent, :count)
      expect(response).to redirect_to(account_two_factor_path)
    end

    it "un god con 2FA ma sessione NON verificata non può avviare un'impersonation (termina + login)" do
      god_stale = create(:account, god: true)
      post login_path, params: { email: god_stale.email, password: "Secret123!" } # sessione con sola password
      enable_two_factor!(god_stale) # 2FA attivato altrove: la sessione corrente non è verificata

      expect { post impersonation_path, params: { account_id: target.id } }
        .not_to change(Accounts::ImpersonationEvent, :count)
      expect(response).to redirect_to(login_path)
    end

    it "l'USCITA dall'impersonation resta possibile (destroy non è mai gated)" do
      sign_in_as(god)
      impersonate(account_id: target.id)

      expect { delete impersonation_path }.to change { Accounts::ImpersonationEvent.open.count }.by(-1)
      expect(response).to redirect_to(valhalla_root_path)
    end
  end

  describe "DELETE /impersonation" do
    it "termina l'impersonazione, chiude l'evento e torna god" do
      sign_in_as(god)
      impersonate(account_id: target.id)

      expect { delete impersonation_path }.to change { Accounts::ImpersonationEvent.open.count }.by(-1)
      expect(response).to redirect_to(valhalla_root_path)

      get valhalla_root_path
      expect(response).to have_http_status(:ok)
    end

    it "senza impersonazione attiva è un no-op (redirect valhalla)" do
      sign_in_as(god)
      expect { delete impersonation_path }.not_to change(Accounts::ImpersonationEvent, :count)
      expect(response).to redirect_to(valhalla_root_path)
    end

    it "impersonazione attiva SENZA evento aperto → azzera comunque la sessione (guard last&.close!)" do
      sign_in_as(god)
      # Sessione che impersona ma senza ImpersonationEvent aperto (stato di bordo).
      Accounts::Session.order(:created_at).last.update!(impersonated_account: target)

      expect { delete impersonation_path }.not_to change(Accounts::ImpersonationEvent, :count)
      expect(response).to redirect_to(valhalla_root_path)
    end
  end
end
