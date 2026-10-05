# frozen_string_literal: true

require "rails_helper"

# DESIGN.md T1: from md up the panels touch the frame and share its border; on a phone the page keeps
# its padding. The gap between panels stays.
RSpec.describe "Member panels flush with the frame", type: :request do
  before do
    org = create(:organization)
    owner = create(:account)
    create(:membership, account: owner, organization: org, role: :owner)
    post login_path, params: { email: owner.email, password: "Secret123!" }
  end

  def main_classes
    Nokogiri::HTML(response.body).at_css("main#main-content[data-panels='flush']")&.[]("class").to_s.split
  end

  it "drops the page padding from md up and reaches 1px past the frame, which clips it" do
    get member_projects_path

    expect(main_classes).to include("md:[&>.p-7]:p-0", "md:[&>.p-7]:-m-px", "md:[&>.p-7]:max-w-none", "md:overflow-x-hidden")
  end

  it "keeps the page padding on a phone" do
    get member_projects_path

    expect(main_classes.grep(/\A(?!md:|lg:).*\bp-0\z/)).to be_empty
    expect(Nokogiri::HTML(response.body).at_css("main#main-content > .p-7")).to be_present
  end

  it "squares only the outermost panels, from md up, until their edges are measured" do
    css = Rails.root.join("app/assets/tailwind/application.css").read

    expect(css).to include('[data-panels="flush"] :is(.rounded-lg, .rounded-xl).border:not(:is(.rounded-lg, .rounded-xl).border *, dialog, .fixed, [data-flush])')
  end

  # A corner is square only where the panel touches the frame: inner corners stay rounded.
  it "sets panels 8px apart from md up: every spacing that sits outside a panel shrinks (T1)" do
    css = Rails.root.join("app/assets/tailwind/application.css").read

    expect(css).to include('[data-panels="flush"] :is(.space-y-4, .space-y-5, .space-y-6, .space-y-8):not(:is(.rounded-lg, .rounded-xl).border, :is(.rounded-lg, .rounded-xl).border *, dialog *, .fixed *) > :not(:last-child)')
    expect(css).to include("--panel-gap: 0.5rem")
  end

  it "measures which sides of each panel touch the frame and squares only those corners" do
    get member_projects_path

    expect(Nokogiri::HTML(response.body).at_css("main#main-content")["data-controller"]).to include("ui--panel-edges")
    css = Rails.root.join("app/assets/tailwind/application.css").read
    %w[top right bottom left].each { |side| expect(css).to include(%([data-flush~="#{side}"])) }
  end

  it "drops the bottom border of a panel that reaches the page end: the frame already draws that line" do
    css = Rails.root.join("app/assets/tailwind/application.css").read

    expect(css).to match(/\[data-flush~="bottom"\] \{[^}]*border-bottom-width: 0/)
  end

  it "makes the section list of the Administration pages an edge the panels touch" do
    get member_members_path

    expect(Nokogiri::HTML(response.body).at_css("main#main-content [data-panel-edge]")).to be_present
  end
end
