# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Website::Analytics (dashboard pubblica / embed)", type: :request do
  let(:project) { create(:project) }

  it "slug valido → 200 dashboard read-only, MAI dati sensibili (visitor_hash)" do
    create(:pageview, project:, path: "/home", visitor_hash: "SECRETVISITORHASH")
    link = create(:analytics_link, project:)

    get share_analytics_path(link.slug)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include("data-test=\"public-analytics\"")
    expect(response.body).to include("/home")
    expect(response.body).not_to include("SECRETVISITORHASH")
  end

  it "il corpo pagina è dentro un landmark <main> (a11y)" do
    link = create(:analytics_link, project:)
    get share_analytics_path(link.slug)
    doc = Nokogiri::HTML(response.body)
    main = doc.at_css("main#main-content")
    expect(main).to be_present
    expect(main["data-test"]).to eq("public-analytics")
  end

  it "slug inesistente → 404 (mai 403, non si rivela l'esistenza)" do
    get share_analytics_path("does-not-exist")
    expect(response).to have_http_status(:not_found)
  end

  it "link revocato (disabled) → 404" do
    link = create(:analytics_link, :disabled, project:)
    get share_analytics_path(link.slug)
    expect(response).to have_http_status(:not_found)
  end

  it "iframe-friendly: X-Frame-Options rimosso sulla dashboard pubblica" do
    link = create(:analytics_link, project:)
    get share_analytics_path(link.slug)
    expect(response.headers).not_to have_key("X-Frame-Options")
  end

  context "link protetto da password" do
    let(:link) { create(:analytics_link, :with_password, project:) }

    it "GET → form password, non la dashboard" do
      get share_analytics_path(link.slug)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("data-test=\"public-analytics-password\"")
      expect(response.body).not_to include("data-test=\"public-analytics\"")
    end

    it "il form password è dentro un landmark <main> (a11y)" do
      get share_analytics_path(link.slug)
      expect(Nokogiri::HTML(response.body).at_css("main#main-content")).to be_present
    end

    it "POST con password corretta → dashboard" do
      post share_analytics_path(link.slug), params: { password: "segreto123" }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("data-test=\"public-analytics\"")
    end

    it "POST con password errata → 401 con errore nel form" do
      post share_analytics_path(link.slug), params: { password: "sbagliata" }
      expect(response).to have_http_status(:unauthorized)
      expect(response.body).to include("data-test=\"public-analytics-password-error\"")
    end
  end
end
