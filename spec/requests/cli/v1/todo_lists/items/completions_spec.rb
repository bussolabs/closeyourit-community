# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Cli::V1::TodoLists::Items::Completions", type: :request do
  let(:account) { create(:account) }
  let(:organization) { create(:organization) }

  before { create(:membership, account:, organization:) }

  let(:secret) { Accounts::ApiTokens::Issue.call(account:, organization:, name: "CLI").value[:secret] }
  let(:headers) { { "Authorization" => "Bearer #{secret}" } }
  let(:list) { create(:todo_list, account:, organization:) }
  let(:item) { create(:todo_item, list:, done: false) }

  def path = "/cli/v1/todo_lists/#{list.id}/items/#{item.id}/completion"

  it "senza bearer → 401" do
    put path
    expect(response).to have_http_status(:unauthorized)
  end

  it "PUT → completa la voce (done: true), 200" do
    put path, headers: headers
    expect(response).to have_http_status(:ok)
    expect(item.reload.done?).to be(true)
  end

  it "DELETE → riapre la voce (done: false), 200" do
    item.update!(done: true, completed_at: Time.current)
    delete path, headers: headers
    expect(response).to have_http_status(:ok)
    expect(item.reload.done?).to be(false)
  end

  it "voce di una lista altrui → 404 (anti-BOLA)" do
    foreign_item = create(:todo_item)
    put "/cli/v1/todo_lists/#{foreign_item.list_id}/items/#{foreign_item.id}/completion", headers: headers
    expect(response).to have_http_status(:not_found)
  end

  it "Toggle fallito → render_error col codice del Result" do
    allow(Todos::Items::Toggle).to receive(:call).and_return(
      Result.err(AppError.new("toggle fallito", code: "R422-TODOITEM-001", status: :unprocessable_content))
    )
    put path, headers: headers
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.parsed_body["error"]["code"]).to eq("R422-TODOITEM-001")
  end
end
