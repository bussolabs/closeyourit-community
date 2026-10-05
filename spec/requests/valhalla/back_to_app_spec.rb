# frozen_string_literal: true

require "rails_helper"

# CYRA-331: dal pannello god si deve poter tornare all'applicazione con un click, senza doversi
# disconnettere né affidarsi al tasto Indietro del browser. Il link di rientro è in cima alla
# sidebar Valhalla e punta a root_path.
RSpec.describe "Valhalla — rientro all'applicazione", type: :request do
  it "dalla sidebar del pannello god si torna all'app, senza disconnettersi" do
    sign_in_god(create(:account, god: true))
    get valhalla_root_path

    rientro = Nokogiri::HTML(response.body).at_css("[data-test='valhalla-nav-back-to-app']")
    expect(rientro["href"]).to eq(root_path)

    get rientro["href"]

    expect(response).to have_http_status(:ok)
    # Non disconnesso: la home member risponde con la sessione ancora attiva.
    expect(response.body).to include('data-test="member-user-menu"')
  end
end
