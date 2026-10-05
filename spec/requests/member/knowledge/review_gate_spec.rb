# frozen_string_literal: true

require "rails_helper"

# CYRA-764 — il rifiuto del revisore automatico arriva al form come un 422 con l'elenco di cosa
# correggere sopra i campi.
RSpec.describe "Member::Knowledge::Pages — revisore automatico", type: :request, knowledge_review: true do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:member) do
    create(:account).tap do |account|
      create(:membership, account: account, organization: org, role: :member)
      create(:project_membership, account: account, project: project)
    end
  end
  let(:rejected) do
    Knowledge::Review::Verdict.new(format: "troubleshooting", verdict: "reject", suggested_kind: "note",
                                   suggested_title: "Rails — la cache non tiene niente in prova", split_suggestion: [], duplicate_of: nil, model: "qwen",
                                   violations: [ Knowledge::Review::Violation.new(code: "T01", message: "Il sintomo non cita il messaggio esatto.",
                                                                                  quote: "La CI falliva senza dire altro") ])
  end

  before { post login_path, params: { email: member.email, password: "Secret123!" } }

  it "POST rifiutata → 422 col form e le violazioni" do
    allow(Knowledge::ReviewPage).to receive(:call).and_return(Result.ok(rejected))

    expect {
      post member_knowledge_pages_path, params: { project_ids: [ project.id ], title: "Rails — cache", body: "Formato: troubleshooting", kind: "note" }
    }.not_to change(Knowledge::Page, :count)

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include('data-test="knowledge-form-review-violations"')
    expect(response.body).to include("T01").and include("Il sintomo non cita il messaggio esatto.")
    expect(response.body).to include("Rails — la cache non tiene niente in prova")
    # CYAU-200 — il passaggio della pagina che motiva il rifiuto, accanto alla regola.
    expect(response.body).to include("La CI falliva senza dire altro")
  end

  it "PATCH rifiutata → 422 senza toccare la pagina" do
    page = create(:knowledge_page, organization: org, project: project, created_by: member, title: "Rails — cache", body: "Formato: troubleshooting")
    allow(Knowledge::ReviewPage).to receive(:call).and_return(Result.ok(rejected))

    patch member_knowledge_page_path(page), params: { title: "Rails — cache", body: "Formato: troubleshooting\nper ora", kind: "note" }
    expect(response).to have_http_status(:unprocessable_content)
    expect(page.reload.body).to eq("Formato: troubleshooting")
  end

  it "revisore giù → 503 con il messaggio, mai un 500" do
    allow(Knowledge::ReviewPage).to receive(:call).and_return(Result.err(AppError.new(I18n.t("member.knowledge.errors.review_unavailable"), code: "R503-KNOWLEDGE-001", status: :service_unavailable)))

    post member_knowledge_pages_path, params: { project_ids: [ project.id ], title: "Rails — cache", body: "x", kind: "note" }
    expect(response).to have_http_status(:service_unavailable)
    expect(response.body).to include(I18n.t("member.knowledge.errors.review_unavailable", locale: :en))
  end
end
