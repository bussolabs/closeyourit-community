# frozen_string_literal: true

require "rails_helper"

# Sidebar section titles must meet WCAG AA on their own ground: text-gray-400 on Valhalla's dark
# rail (CYRA-5), text-gray-600 at 10.5px on the white member sidebar (CYRA-883, CYRA-903).
RSpec.describe "Sidebar — contrasto dei titoli di sezione", type: :request do
  def sezioni(prefisso)
    # The divider between sections is a line, not a title.
    Nokogiri::HTML(response.body).css("[data-test^='#{prefisso}']:not([data-test$='-divider'])")
  end

  describe "area member" do
    before do
      org = create(:organization)
      owner = create(:account)
      create(:membership, account: owner, organization: org, role: :owner)
      post login_path, params: { email: owner.email, password: "Secret123!" }
      get member_projects_path
    end

    # Checked on every section actually rendered. At 9.5px in gray-500 the titles sat just above the
    # reading threshold (CYRA-903).
    it "uses text-gray-600 at 10.5px for every section title on the white sidebar" do
      titles = sezioni("member-nav-section-")
      expect(titles).not_to be_empty
      titles.each do |title|
        expect(title["class"]).to include("text-gray-600", "text-[10.5px]"),
                                  "#{title['data-test']}: expected text-gray-600, found: #{title['class'].inspect}"
      end
    end
  end

  describe "area Valhalla" do
    before do
      sign_in_god(create(:account, god: true, name: "Root God"))
      get valhalla_root_path
    end

    it "gives the section title a readable grey on the light shell and its dark twin" do
      classi = Nokogiri::HTML(response.body).at_css("[data-test='valhalla-nav-section-admin']")["class"]

      expect(classi).to include("text-gray-500", "dark:text-zinc-400")
      expect(classi).not_to include("text-gray-400")
    end
  end
end
