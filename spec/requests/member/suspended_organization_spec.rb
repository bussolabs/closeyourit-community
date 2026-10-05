# frozen_string_literal: true

require "rails_helper"

# CYRA-722 — sospendere un'organizzazione dalla console interna non aveva alcun effetto: il flag
# esisteva, lo leggevano solo l'elenco del god e i suoi filtri, e i membri continuavano a entrare e a
# lavorare come se niente fosse. Qui si presidia il canale web: chi appartiene a un'organizzazione
# sospesa non apre nessuna pagina dell'area utenti e legge il motivo, con le due sole vie d'uscita
# che restano — uscire, o passare a un'altra organizzazione ancora attiva.
RSpec.describe "Organizzazione sospesa — area utenti", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization, name: "Acme") }

  def sign_in(target = account)
    post login_path, params: { email: target.email, password: "Secret123!" }
  end

  before { create(:membership, account:, organization:, role: :owner) }

  context "quando l'organizzazione è sospesa" do
    before do
      organization.update!(suspended_at: Time.current)
      sign_in
    end

    it "la home non si apre e spiega che l'organizzazione è sospesa" do
      get root_path

      expect(response).to have_http_status(:forbidden)
      expect(response.body).to include("organization-suspended")
      expect(response.body).to include(I18n.t("member.suspended.title"))
    end

    it "nessuna pagina dell'area utenti si apre" do
      get member_tickets_path

      expect(response).to have_http_status(:forbidden)
      expect(response.body).to include("organization-suspended")
    end

    it "l'indirizzo esplicito della home è bloccato come la radice" do
      get member_home_path

      expect(response).to have_http_status(:forbidden)
    end

    it "blocca anche le scritture, non solo le pagine" do
      expect { post member_saved_views_path, params: { name: "X", resource_type: "tickets" } }
        .not_to change(SavedView, :count)

      expect(response).to have_http_status(:forbidden)
    end

    it "si può comunque uscire" do
      delete logout_path

      expect(response).to redirect_to(login_path)
    end

    # La 404 dell'area vive nel guscio member, con menu e conteggi: renderla a chi è stato chiuso
    # fuori riaprirebbe da lì la porta che la sospensione ha chiuso.
    it "anche un indirizzo inesistente dell'area mostra la sospensione" do
      get "/member/questa-non-esiste"

      expect(response).to have_http_status(:forbidden)
      expect(response.body).to include("organization-suspended")
    end
  end

  context "quando l'account ha anche un'organizzazione attiva" do
    let(:altra) { create(:organization, name: "Beta") }

    before do
      create(:membership, account:, organization: altra, role: :member)
      organization.update!(suspended_at: Time.current)
      sign_in
    end

    it "la pagina offre il passaggio all'organizzazione attiva" do
      get root_path

      expect(response.body).to include("Beta")
    end

    it "il passaggio funziona e l'area utenti torna disponibile" do
      post member_organization_switches_path, params: { organization_id: altra.id }
      expect(response).to redirect_to(root_path)

      get root_path
      expect(response).to have_http_status(:ok)
    end

    it "non si può tornare su quella sospesa" do
      post member_organization_switches_path, params: { organization_id: altra.id }
      post member_organization_switches_path, params: { organization_id: organization.id }

      get root_path
      expect(response).to have_http_status(:forbidden)
    end
  end

  context "quando l'organizzazione è attiva" do
    before { sign_in }

    it "l'area utenti si apre normalmente" do
      get root_path

      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include("organization-suspended")
    end

    it "riattivare l'organizzazione la rende di nuovo raggiungibile" do
      organization.update!(suspended_at: Time.current)
      get root_path
      expect(response).to have_http_status(:forbidden)

      organization.update!(suspended_at: nil)
      get root_path
      expect(response).to have_http_status(:ok)
    end
  end

  # È il god a sospendere: se la sospensione chiudesse fuori anche lui, non resterebbe nessuno che
  # possa guardare dentro l'organizzazione fermata per capire come rimetterla in piedi.
  context "amministratore globale" do
    let(:god) { create(:account, god: true) }

    it "entra anche in un'organizzazione sospesa" do
      organization.update!(suspended_at: Time.current)
      sign_in(god)
      post member_organization_switches_path, params: { organization_id: organization.id }

      get root_path
      expect(response).to have_http_status(:ok)
    end
  end
end
