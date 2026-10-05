# frozen_string_literal: true

require "rails_helper"

# Atkinson Hyperlegible Next (text and titles) and Atkinson Hyperlegible Mono (codes, numbers, labels)
# are self-hosted (app/assets/tailwind/application.css): the Google Fonts stylesheet only added a
# render-blocking request to a third party (CYRA-895).
RSpec.describe "Self-hosted fonts", type: :request do
  let(:stylesheet) { Rails.root.join("app/assets/tailwind/application.css").read }

  it "uses Atkinson Hyperlegible Next for text and titles and Atkinson Hyperlegible Mono for data" do
    expect(stylesheet).to match(/--font-sans: "Atkinson Hyperlegible Next",/)
    expect(stylesheet).to match(/--font-display: "Atkinson Hyperlegible Next",/)
    expect(stylesheet).to match(/--font-mono: "Atkinson Hyperlegible Mono",/)
  end

  it "declares only Atkinson Hyperlegible faces, each backed by a file in app/assets/fonts" do
    families = stylesheet.scan(/font-family: "([^"]+)";/).flatten.uniq
    files = stylesheet.scan(%r{url\("/([^"]+\.woff2)"\)}).flatten

    expect(families).to contain_exactly("Atkinson Hyperlegible Next", "Atkinson Hyperlegible Mono")
    expect(files).not_to be_empty
    expect(files.reject { |file| Rails.root.join("app/assets/fonts", file).exist? }).to be_empty
  end

  it "no layout loads Google Fonts" do
    offenders = Rails.root.glob("app/views/layouts/*.erb").select do |path|
      path.read.match?(/fonts\.(googleapis|gstatic)\.com/)
    end

    expect(offenders.map { |path| path.basename.to_s }).to be_empty
  end

  it "the login page renders without Google Fonts" do
    get login_path

    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include("fonts.googleapis.com")
  end
end
