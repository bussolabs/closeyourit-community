# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Importmap preloads", type: :request do
  it "does not modulepreload the replay player on every page" do
    get root_path

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('rel="modulepreload"')
    expect(response.body).not_to match(/modulepreload[^>]*rrweb-player/)
  end

  it "keeps the replay player in the importmap for the dynamic import" do
    get root_path

    expect(response.body).to match(/"rrweb-player": ?"[^"]*rrweb-player/)
  end
end
