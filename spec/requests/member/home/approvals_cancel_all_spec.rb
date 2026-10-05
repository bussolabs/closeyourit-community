# frozen_string_literal: true

require "rails_helper"

# CYRA-867 — il pulsante che annulla tutte le lavorazioni aperte: solo owner e admin, e il lavoro va a un job.
RSpec.describe "Annullare tutte le lavorazioni", type: :request do
  include ActiveJob::TestHelper

  let(:org) { create(:organization) }

  def account_with(role)
    create(:account).tap { |a| create(:membership, account: a, organization: org, role: role) }
  end

  def sign_in(account)
    post login_path, params: { email: account.email, password: "Secret123!" }
  end

  it "l'owner vede il pulsante con la conferma" do
    sign_in(account_with(:owner))
    get member_home_approvals_path

    # CYRA-904 — the most dangerous action waits in the More menu, not next to the title.
    menu = Nokogiri::HTML(response.body).at_css("[data-test='approvals-more-menu']").parent
    button = menu.at_css("[data-test='approvals-cancel-all']")
    expect(button).to be_present
    expect(button["data-turbo-confirm"]).to eq(I18n.t("member.approvals.cancel_all.confirm"))
  end

  it "chi è membro non vede il pulsante" do
    sign_in(account_with(:member))
    get member_home_approvals_path

    expect(response.body).not_to include("approvals-cancel-all")
  end

  it "l'owner avvia l'annullamento e sa quante sono" do
    owner = account_with(:owner)
    # Due lavorazioni per contarle: la fixture crea ticket uno per volta, non è un N+1 dell'app.
    allow_n_plus_one { create_list(:agent_workflow, 2, organization: org) }
    sign_in(owner)

    expect { post member_home_approvals_cancel_all_path }
      .to have_enqueued_job(Agents::CancelAllWorkflowsJob).with(org.id, owner.id, I18n.t("member.approvals.cancel_all.reason"))
    expect(response).to redirect_to(member_home_approvals_path)
    expect(flash[:notice]).to eq(I18n.t("member.approvals.cancel_all.started", count: 2))
  end

  it "chi è membro non avvia niente" do
    sign_in(account_with(:member))

    expect { post member_home_approvals_cancel_all_path }.not_to have_enqueued_job(Agents::CancelAllWorkflowsJob)
    expect(flash[:alert]).to eq(I18n.t("member.forbidden"))
  end
end
