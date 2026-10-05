# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::TodoLists reorder", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }

  before { create(:membership, account:, organization:, role: :member) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }

  it "senza bearer → 401" do
    put "/cli/v1/todo_lists/reorder", params: { ordered_ids: [] }
    expect(response).to have_http_status(:unauthorized)
  end

  it "PUT reorder riordina le liste possedute → 204" do
    a = create(:todo_list, account:, organization:, position: 0)
    b = create(:todo_list, account:, organization:, position: 1)

    put "/cli/v1/todo_lists/reorder", headers: headers, params: { ordered_ids: [ b.id, a.id ] }

    expect(response).to have_http_status(:no_content)
    # Una sola query per l'asserzione (evita il falso positivo Prosopite di due .reload separate).
    ordered = Todos::List.where(id: [ a.id, b.id ]).order(:position).pluck(:id)
    expect(ordered).to eq([ b.id, a.id ])
  end
end
