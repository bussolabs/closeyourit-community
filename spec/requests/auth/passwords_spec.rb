# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Auth::Passwords", type: :request do
  let(:account) { create(:account, email: "ada@example.com") }

  describe "GET /passwords/new" do
    it "risponde 200" do
      get new_password_path
      expect(response).to have_http_status(:ok)
    end
  end

  describe "POST /passwords" do
    it "con email esistente accoda l'email e reindirizza al login" do
      account
      expect { post passwords_path, params: { email: "ada@example.com" } }
        .to have_enqueued_mail(Auth::PasswordsMailer, :reset)
      expect(response).to redirect_to(login_path)
    end

    it "con email inesistente reindirizza comunque senza inviare (no enumeration)" do
      expect { post passwords_path, params: { email: "nessuno@example.com" } }
        .not_to have_enqueued_mail(Auth::PasswordsMailer, :reset)
      expect(response).to redirect_to(login_path)
    end
  end

  describe "GET /passwords/:token/edit" do
    it "token valido → 200" do
      get edit_password_path(account.generate_token_for(:password_reset))
      expect(response).to have_http_status(:ok)
    end

    it "token invalido → redirect a new" do
      get edit_password_path("spazzatura")
      expect(response).to redirect_to(new_password_path)
    end

    it "token scaduto → redirect a new" do
      token = account.generate_token_for(:password_reset)
      travel_to(Accounts::Constants::TTL_PASSWORD_RESET.from_now + 1.second) do
        get edit_password_path(token)
        expect(response).to redirect_to(new_password_path)
      end
    end
  end

  describe "PATCH /passwords/:token" do
    it "aggiorna la password con dati validi" do
      token = account.generate_token_for(:password_reset)
      patch password_path(token), params: { password: "Nuova123!", password_confirmation: "Nuova123!" }
      expect(response).to redirect_to(login_path)
      expect(account.reload.authenticate("Nuova123!")).to be_truthy
    end

    it "password debole → 422" do
      token = account.generate_token_for(:password_reset)
      patch password_path(token), params: { password: "debole", password_confirmation: "debole" }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "conferma errata → 422" do
      token = account.generate_token_for(:password_reset)
      patch password_path(token), params: { password: "Nuova123!", password_confirmation: "Diversa1!" }
      expect(response).to have_http_status(:unprocessable_content)
    end

    it "token invalido → redirect a new" do
      patch password_path("spazzatura"), params: { password: "Nuova123!", password_confirmation: "Nuova123!" }
      expect(response).to redirect_to(new_password_path)
    end

    describe "revoca delle sessioni al cambio password (CYRA-170)" do
      it "distrugge tutte le sessioni esistenti dell'account (invalida i cookie aperti altrove)" do
        create_list(:session, 2, account: account)
        token = account.generate_token_for(:password_reset)
        expect {
          patch password_path(token), params: { password: "Nuova123!", password_confirmation: "Nuova123!" }
        }.to change { account.sessions.count }.from(2).to(0)
      end

      it "non tocca le sessioni di un altro account" do
        other = create(:account)
        create(:session, account: other)
        token = account.generate_token_for(:password_reset)
        patch password_path(token), params: { password: "Nuova123!", password_confirmation: "Nuova123!" }
        expect(other.sessions.count).to eq(1)
      end

      it "un cambio password fallito (password debole) lascia intatte le sessioni" do
        create(:session, account: account)
        token = account.generate_token_for(:password_reset)
        patch password_path(token), params: { password: "debole", password_confirmation: "debole" }
        expect(account.sessions.count).to eq(1)
      end
    end

    describe "revoca dei token CLI al cambio password (CYRA-643)" do
      let(:organization) { create(:organization) }

      before { create(:membership, account:, organization:) }

      it "revoca i token CLI attivi dell'account (la riga di comando aperta altrove smette di funzionare)" do
        token = create(:api_token, account:, organization:)
        reset = account.generate_token_for(:password_reset)

        patch password_path(reset), params: { password: "Nuova123!", password_confirmation: "Nuova123!" }

        expect(token.reload.revoked?).to be(true)
      end

      it "non tocca i token CLI di un altro account" do
        altrui = create(:api_token)
        reset = account.generate_token_for(:password_reset)

        patch password_path(reset), params: { password: "Nuova123!", password_confirmation: "Nuova123!" }

        expect(altrui.reload.revoked?).to be(false)
      end

      it "un cambio password fallito lascia i token attivi" do
        token = create(:api_token, account:, organization:)
        reset = account.generate_token_for(:password_reset)

        patch password_path(reset), params: { password: "debole", password_confirmation: "debole" }

        expect(token.reload.revoked?).to be(false)
      end
    end
  end
end
