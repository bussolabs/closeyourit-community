# frozen_string_literal: true

require "rails_helper"

# Il vecchio indirizzo dei workflow apre le approvazioni sulla vista «In corso», non sulla coda.
RSpec.describe "GET /member/workflows", type: :request do
  it "porta alle approvazioni con la vista dei lavori in corso" do
    get "/member/workflows"

    expect(response).to redirect_to("http://www.example.com/member/home/approvals?view=in_flight")
  end
end
