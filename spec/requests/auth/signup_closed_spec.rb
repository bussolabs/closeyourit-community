# frozen_string_literal: true

require "rails_helper"

# CYRA-249: /signup era pubblica e senza freni — una POST anonima creava account, organizzazione,
# membership owner e l'intero corredo di default, e il modulo diceva pure se un'email era già
# registrata. Le rotte sono state rimosse: il 404 arriva dal router, non da un flag che qualcuno può
# riaccendere per sbaglio. L'ingresso passa solo da un invito o dal provisioning god.
RSpec.describe "Registrazione pubblica chiusa", type: :request do
  let(:params) do
    {
      name: "Ada Lovelace", email: "ada@example.com",
      password: "Secret123!", password_confirmation: "Secret123!",
      organization_name: "Acme Inc"
    }
  end

  it "GET /signup risponde 404" do
    get "/signup"
    expect(response).to have_http_status(:not_found)
  end

  it "POST /signup risponde 404 e non crea né account né organizzazione" do
    expect { post "/signup", params: params }
      .to not_change(Accounts::Account, :count)
      .and not_change(Organizations::Organization, :count)

    expect(response).to have_http_status(:not_found)
  end

  it "l'helper signup_path non esiste più (nessuna vista può rimandarci)" do
    expect(Rails.application.routes.url_helpers).not_to respond_to(:signup_path)
  end

  it "la pagina di accesso non offre più la registrazione" do
    get login_path

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("login-to-signup")
  end

  # Scenario 2 del ticket: senza modulo pubblico non esiste più nessuna risposta che confermi o
  # smentisca l'esistenza di un'email — l'enumerazione sparisce insieme alla pagina.
  it "un'email già registrata non ottiene una risposta diversa da una mai vista" do
    create(:account, email: "ada@example.com")

    post "/signup", params: params
    known = response.status
    expect(response.body).not_to include("has already been taken")

    post "/signup", params: params.merge(email: "mai-vista@example.com")

    expect(response.status).to eq(known)
  end

  describe "vie d'ingresso legittime" do
    it "l'invito continua a creare l'account e ad autenticare" do
      invitation = create(:invitation, email: "grace@example.com")

      expect do
        patch invitation_path(invitation.generate_token_for(:invitation)),
              params: { name: "Grace Hopper", password: "Secret123!", password_confirmation: "Secret123!" }
      end.to change(Accounts::Account, :count).by(1)

      expect(response).to redirect_to(root_path)
    end

    it "il provisioning dal pannello god continua a creare organizzazione e owner" do
      expect { Organizations::Provision.call(name: "Acme Inc", owner_email: "owner@example.com") }
        .to change(Organizations::Organization, :count).by(1)
        .and change(Accounts::Account, :count).by(1)
    end
  end
end
