# frozen_string_literal: true

require "rails_helper"

RSpec.describe "member/tickets/_draft_fields", type: :view do
  it "carries the chosen error and slow operation through the duplicate comparison" do
    controller.params.merge!(error_group_id: "eg-1", metric_group_id: "mg-1")

    render partial: "member/tickets/draft_fields", locals: { draft_params: {} }

    page = Nokogiri::HTML(rendered)
    expect(page.at_css("input[type=hidden][name=error_group_id]")["value"]).to eq("eg-1")
    expect(page.at_css("input[type=hidden][name=metric_group_id]")["value"]).to eq("mg-1")
  end
end
