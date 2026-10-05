# frozen_string_literal: true

require "rails_helper"

# Preferenza personale delle colonne RIDOTTE della board (CYRA-390): POST collassa, DELETE espande,
# per code di status. Persiste in Accounts::Account#board_collapsed_statuses ed è ricordata alla
# visita successiva. Il code è ammesso solo se è uno status attivo dell'org (niente accumulo arbitrario).
RSpec.describe "Member::Tickets::CollapsedColumns", type: :request do
  let(:org) { create(:organization) }
  let(:member) { create(:account) }
  let!(:status) { create(:ticket_status, organization: org, code: "resolved") }

  before do
    create(:membership, account: member, organization: org, role: :member)
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  it "POST collassa la colonna (aggiunge il code alle preferenze)" do
    sign_in(member)
    post member_collapsed_columns_path(code: "resolved")
    aggregate_failures do
      expect(response).to have_http_status(:no_content)
      expect(member.reload.board_collapsed_statuses).to eq(%w[resolved])
    end
  end

  it "è idempotente: due collassi non duplicano il code" do
    sign_in(member)
    post member_collapsed_columns_path(code: "resolved")
    post member_collapsed_columns_path(code: "resolved")
    expect(member.reload.board_collapsed_statuses).to eq(%w[resolved])
  end

  it "DELETE espande la colonna (rimuove il code)" do
    sign_in(member)
    member.update!(board_collapsed_statuses: %w[resolved])
    delete member_collapsed_column_path("resolved")
    aggregate_failures do
      expect(response).to have_http_status(:no_content)
      expect(member.reload.board_collapsed_statuses).to eq([])
    end
  end

  it "al primo tocco materializza il default: aprire una conclusa non riapre le altre" do
    sign_in(member)
    create(:ticket_status, :done, organization: org, code: "closed")
    create(:ticket_status, :done, organization: org, code: "archived")
    # Board mai configurata: closed/archived (concluse) sono ridotte di default (`status` qui, code
    # "resolved", è category open → non conclusa). Aprendo closed, archived deve restare ridotta.
    delete member_collapsed_column_path("closed")
    aggregate_failures do
      expect(response).to have_http_status(:no_content)
      expect(member.reload.board_collapsed_statuses).to match_array(%w[archived])
    end
  end

  it "ignora un code che non è uno status attivo dell'org (niente accumulo arbitrario)" do
    sign_in(member)
    post member_collapsed_columns_path(code: "made-up")
    aggregate_failures do
      expect(response).to have_http_status(:no_content)
      expect(member.reload.board_collapsed_statuses).to eq([])
    end
  end

  it "non autenticato → redirect login (nessuna scrittura)" do
    post member_collapsed_columns_path(code: "resolved")
    expect(response).to redirect_to(login_path)
  end
end
