# frozen_string_literal: true

require "rails_helper"

# Comportamento trasversale del concern Localizable: la lingua dell'interfaccia segue l'account
# autenticato (Current.account) e, pre-login, l'header Accept-Language del browser. L'asserzione è
# sull'attributo <html lang="…"> dei layout — stabile e indipendente dalla copy.
RSpec.describe "Localizzazione dell'interfaccia", type: :request do
  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  describe "home autenticata (HomeController → layout member)" do
    it "rende il dashboard nella lingua dell'account" do
      sign_in(create(:account, locale: "it"))
      get root_path
      expect(response.body).to include('lang="it"')
    end

    it "default inglese quando l'account non ha preferenza" do
      sign_in(create(:account, locale: nil))
      get root_path
      expect(response.body).to include('lang="en"')
    end
  end

  describe "pagine pre-login (Auth → Accept-Language)" do
    it "login in italiano se Accept-Language preferisce it" do
      get login_path, headers: { "HTTP_ACCEPT_LANGUAGE" => "it-IT,it;q=0.9,en;q=0.8" }
      expect(response.body).to include('lang="it"')
    end

    it "default inglese senza header Accept-Language" do
      get login_path
      expect(response.body).to include('lang="en"')
    end

    it "lingua non supportata (de) → default inglese" do
      get login_path, headers: { "HTTP_ACCEPT_LANGUAGE" => "de-DE,de;q=0.9" }
      expect(response.body).to include('lang="en"')
    end

    it "l'avviso «accedi per continuare» parla la lingua del login, non il default" do
      headers = { "HTTP_ACCEPT_LANGUAGE" => "it-IT,it;q=0.9,en;q=0.8" }
      get member_home_path, headers: headers
      follow_redirect!(headers: headers)
      expect(response.body).to include('lang="it"', I18n.t("auth.sessions.required", locale: :it))
      expect(response.body).not_to include(I18n.t("auth.sessions.required", locale: :en))
    end
  end
end
