# frozen_string_literal: true

require "rails_helper"

# CYRA-462 Scenario 2: un indirizzo inesistente dell'area mostra la pagina di errore del prodotto
# (guscio member, nella lingua dell'utente, con la via d'uscita), non la 404 statica grezza in inglese.
RSpec.describe "Member::Errors (404 di prodotto)", type: :request do
  let(:organization) { create(:organization) }
  let(:owner) { create(:account) }

  before { create(:membership, account: owner, organization:, role: :owner) }

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  # Il caso osservato nel ticket: /member/monitoring/server_databases (rotta inesistente).
  it "un indirizzo inesistente dell'area risponde con la 404 di prodotto, non con la pagina grezza" do
    sign_in(owner)
    get "/member/monitoring/server_databases"

    expect(response).to have_http_status(:not_found)
    # guscio del prodotto (sidebar member) + via d'uscita verso la dashboard
    expect(response.body).to include("member-sidebar")
    expect(response.body).to include(I18n.t("errors.pages.not_found.title"))
    expect(response.body).to include('data-test="not-found-home"')
    # non è la schermata tecnica statica di Rails, in inglese e senza uscita
    expect(response.body).not_to include("The page you were looking for doesn't exist")
  end

  # CYRA-372 — il testo è UNO solo, condiviso con la pagina di errore fuori dall'area member.
  it "il titolo della 404 è in italiano per l'utente italiano" do
    expect(I18n.t("errors.pages.not_found.title", locale: :it)).to eq("Questa pagina non esiste")
  end

  it "a chi non è autenticato l'area resta protetta (redirect al login)" do
    get "/member/monitoring/server_databases"
    expect(response).to redirect_to(login_path)
  end

  # CYRA-442 — l'indirizzo osservato nell'audit (/member/notification_preferences: la pagina esiste
  # sotto /member/preferences/notifications) rispondeva con la schermata tecnica di Rails, in inglese
  # e fuori dal guscio, proprio mentre l'utente cercava le sue impostazioni.
  it "anche un indirizzo sbagliato delle preferenze resta dentro il prodotto" do
    sign_in(owner)
    get "/member/notification_preferences"

    expect(response).to have_http_status(:not_found)
    expect(response.body).to include("member-sidebar")
    expect(response.body).to include(I18n.t("errors.pages.not_found.title"))
    expect(response.body).not_to include("Routing Error")
  end
end
