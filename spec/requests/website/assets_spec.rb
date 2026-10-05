# frozen_string_literal: true

require "rails_helper"

# CYRA-238 — The public channel does not depend on third parties for fonts and icons: no
# preconnect/stylesheet to Google Fonts or Font Awesome (cdnjs), no `fa-solid` classes in the HTML.
# Icons are inline Lucide SVGs (Ui::IconComponent, CYRA-926), fonts come from app/assets/fonts.
RSpec.describe "Website::Assets", type: :request do
  EXTERNAL_HOSTS = %w[fonts.googleapis.com fonts.gstatic.com cdnjs.cloudflare.com].freeze

  def assert_no_external_dependencies!(body)
    EXTERNAL_HOSTS.each { |host| expect(body).not_to include(host) }
    expect(body).not_to include("fa-solid")
  end

  it "la home non carica font/icone da terzi" do
    get "/"
    expect(response).to have_http_status(:ok)
    assert_no_external_dependencies!(response.body)
  end

  it "una pagina feature (icone dinamiche da FeaturePage incluse) non carica font/icone da terzi" do
    get "/features/error-monitoring"
    expect(response).to have_http_status(:ok)
    assert_no_external_dependencies!(response.body)

    doc = Nokogiri::HTML(response.body)
    expect(doc.css("svg[data-icon]").size).to be >= Website::FeaturePage.all.size
  end

  it "la status page pubblica non carica font/icone da terzi" do
    org = create(:organization, slug: "acme")
    project = create(:project, organization: org, key: "MYAP")
    environment = create(:environment, organization: org, code: "production").tap { |e| project.environments << e }
    create(:uptime_monitor, project:, environment:, public_status_enabled: true)

    get public_status_path("acme", "MYAP", "production")

    expect(response).to have_http_status(:ok)
    assert_no_external_dependencies!(response.body)
  end

  it "draws every icon of the channel inline, with no reference to a missing glyph" do
    get "/features/error-monitoring"
    doc = Nokogiri::HTML(response.body)

    icons = doc.css("svg[data-icon]")
    expect(icons).not_to be_empty
    expect(icons.map { |svg| svg.element_children.size }).to all(be_positive)
    expect(doc.css("svg use")).to be_empty
  end
end
