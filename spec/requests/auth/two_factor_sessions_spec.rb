# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Auth::TwoFactorSessions", type: :request do
  let(:account) { create(:account, :with_otp, email: "ada@example.com", password: "Secret123!") }

  def start_pending(acc = account)
    post login_path, params: { email: acc.email, password: "Secret123!" }
  end

  describe "POST /login con 2FA attivo" do
    it "NON crea la sessione: mette in pending e reindirizza alla challenge" do
      expect { start_pending }.not_to change(Accounts::Session, :count)
      expect(response).to redirect_to(two_factor_challenge_path)
    end
  end

  describe "GET /login/2fa" do
    it "con pending valido mostra il form del codice" do
      start_pending
      get two_factor_challenge_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('data-test="two-factor-form"')
    end

    it "senza pending reindirizza al login" do
      get two_factor_challenge_path
      expect(response).to redirect_to(login_path)
    end
  end

  describe "POST /login/2fa (verifica secondo fattore)" do
    it "con codice TOTP valido crea la sessione e reindirizza alla home" do
      start_pending
      expect {
        post two_factor_challenge_path, params: { code: ROTP::TOTP.new(account.otp_secret).now }
      }.to change(Accounts::Session, :count).by(1)
      expect(response).to redirect_to(root_path)
    end

    it "con un codice di recupero valido crea la sessione e lo consuma (monouso)" do
      codes = account.enable_otp!
      start_pending
      expect {
        post two_factor_challenge_path, params: { code: codes.first }
      }.to change(Accounts::Session, :count).by(1)
      digest = Accounts::Account.digest_recovery_code(codes.first)
      expect(account.otp_recovery_codes.find_by(code_digest: digest).used_at).to be_present
    end

    it "con codice errato resta sulla challenge 422 senza creare sessione" do
      start_pending
      expect {
        post two_factor_challenge_path, params: { code: "000000" }
      }.not_to change(Accounts::Session, :count)
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "con pending scaduto torna al login senza creare sessione" do
      start_pending
      travel_to(Accounts::Constants::OTP_PENDING_TTL.from_now + 1.minute) do
        expect {
          post two_factor_challenge_path, params: { code: ROTP::TOTP.new(account.otp_secret).now }
        }.not_to change(Accounts::Session, :count)
        expect(response).to redirect_to(login_path)
      end
    end

    # FIX-4: il pending è legato alla versione della password. Un reset password (che cambia password_salt
    # e revoca le sessioni) invalida anche una challenge 2FA in volo: chi aveva superato la VECCHIA
    # password non può completare il secondo fattore.
    it "un cambio password invalida un pending 2FA in volo (nessuna sessione creata)" do
      start_pending
      account.update!(password: "Nuova123!", password_confirmation: "Nuova123!")

      expect {
        post two_factor_challenge_path, params: { code: ROTP::TOTP.new(account.otp_secret).now }
      }.not_to change(Accounts::Session, :count)
      expect(response).to redirect_to(login_path)
    end
  end

  # FIX-5: la sessione creata al superamento del secondo fattore è marcata verificata (gate god Valhalla).
  describe "marcatura della sessione verificata (FIX-5)" do
    it "la sessione appena creata dal 2FA ha two_factor_verified_at valorizzato" do
      start_pending
      post two_factor_challenge_path, params: { code: ROTP::TOTP.new(account.otp_secret).now }
      expect(Accounts::Session.order(:created_at).last).to be_two_factor_verified
    end
  end

  # FIX-B: lockout del challenge legato al pending (resiste al brute-force distribuito, non solo per-IP).
  describe "lockout dopo troppi tentativi falliti (FIX-B)" do
    # FIX-H: il lockout vive in Rails.cache (server-side, non più nella rack session CookieStore, che un
    # attaccante rigiocherebbe azzerata). In test il cache è :null_store → lo sostituiamo con un MemoryStore
    # reale per l'esempio, così il contatore persiste tra le richieste (in produzione è Solid Cache).
    let(:lockout_cache) { ActiveSupport::Cache::MemoryStore.new }

    before { allow(Rails).to receive(:cache).and_return(lockout_cache) }

    # allow_n_plus_one: l'example fa N challenge HTTP di seguito; il lookup account per-richiesta NON è un
    # N+1 di produzione (ogni richiesta è isolata) → prosopite lo conterebbe come falso positivo.
    it "raggiunta la soglia annulla la challenge e rimanda al login" do
      start_pending
      allow_n_plus_one do
        (Accounts::Constants::OTP_MAX_ATTEMPTS - 1).times do
          post two_factor_challenge_path, params: { code: "000000" }
          expect(response).to have_http_status(:unprocessable_content)
        end

        post two_factor_challenge_path, params: { code: "000000" } # tocca la soglia
        expect(response).to redirect_to(login_path)

        # challenge annullata: nemmeno un codice valido crea più la sessione
        expect {
          post two_factor_challenge_path, params: { code: ROTP::TOTP.new(account.otp_secret).now }
        }.not_to change(Accounts::Session, :count)
        expect(response).to redirect_to(login_path)
      end
    end

    it "un codice valido entro la soglia completa il login (i tentativi falliti non bloccano)" do
      start_pending
      allow_n_plus_one do
        (Accounts::Constants::OTP_MAX_ATTEMPTS - 1).times { post two_factor_challenge_path, params: { code: "000000" } }

        expect {
          post two_factor_challenge_path, params: { code: ROTP::TOTP.new(account.otp_secret).now }
        }.to change(Accounts::Session, :count).by(1)
        expect(response).to redirect_to(root_path)
      end
    end

    it "resiste al replay del vecchio cookie: la challenge è consumata server-side (FIX-J)" do
      start_pending
      session_key = Rails.application.config.session_options[:key]
      replay_cookie = cookies[session_key] # copia del cookie col token pending ancora valido (attaccante)

      allow_n_plus_one do
        Accounts::Constants::OTP_MAX_ATTEMPTS.times { post two_factor_challenge_path, params: { code: "000000" } }
      end
      expect(response).to redirect_to(login_path) # lockout → challenge consumata

      cookies[session_key] = replay_cookie # rigioca il vecchio cookie e prova un codice CORRETTO
      expect {
        post two_factor_challenge_path, params: { code: ROTP::TOTP.new(account.otp_secret).now }
      }.not_to change(Accounts::Session, :count)
      expect(response).to redirect_to(login_path)
    end
  end
end
