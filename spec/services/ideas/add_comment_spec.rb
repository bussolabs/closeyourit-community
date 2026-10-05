# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ideas::AddComment, type: :service do
  include ActiveJob::TestHelper

  let(:organization) { create(:organization) }
  let(:project) { create(:project, organization:) }
  let(:idea) { create(:idea, organization:, project:) }
  let(:member) do
    create(:account).tap { |a| create(:membership, account: a, organization:, role: :member) }
  end

  # CYRA-147: un commento accodato accoda l'avviso idea_commented escludendo l'autore.
  it "accoda l'avviso idea_commented con l'autore escluso" do
    expect do
      described_class.call(idea:, author: member, params: { body: "Ottima idea, servirebbe su mobile" })
    end.to have_enqueued_job(Alerting::EvaluateJob).with(
      hash_including(event_type: "idea_commented", subject_type: "Ideas::Comment",
                     project_id: project.id, actor_id: member.id)
    )
  end

  it "non accoda alcun avviso se l'idea è congelata (nessun commento)" do
    frozen = create(:idea, :archived, organization:, project:)
    expect do
      described_class.call(idea: frozen, author: member, params: { body: "tardi" })
    end.not_to have_enqueued_job(Alerting::EvaluateJob)
  end

  it "aggiunge il commento a un'idea aperta e aggiorna il contatore" do
    result = described_class.call(idea:, author: member, params: { body: "Ottima idea, servirebbe anche su mobile" })

    expect(result).to be_ok
    expect(result.value).to be_persisted
    expect(idea.reload.comments_count).to eq(1)
  end

  it "idea archiviata (congelata) → R422-IDEA-002, nessun commento" do
    frozen = create(:idea, :archived, organization:, project:)

    expect do
      result = described_class.call(idea: frozen, author: member, params: { body: "tardi" })
      expect(result).to be_err
      expect(result.error.code).to eq("R422-IDEA-002")
    end.not_to change(Ideas::Comment, :count)
  end

  it "idea convertita (congelata) → R422-IDEA-002" do
    frozen = create(:idea, :converted, organization:, project:)

    result = described_class.call(idea: frozen, author: member, params: { body: "tardi" })
    expect(result).to be_err
    expect(result.error.code).to eq("R422-IDEA-002")
  end

  it "corpo vuoto → R422-IDEA-004 con details" do
    result = described_class.call(idea:, author: member, params: { body: "   " })

    expect(result).to be_err
    expect(result.error.code).to eq("R422-IDEA-004")
    expect(result.error.details).to have_key(:body)
  end

  # CYRA-371 — la discussione di un'idea è argomentata: un intervento di qualche migliaio di caratteri
  # è il caso normale, non l'eccezione.
  it "accetta un intervento argomentato di qualche migliaio di caratteri" do
    result = described_class.call(idea:, author: member, params: { body: "x" * 3_000 })

    expect(result).to be_ok
    expect(result.value.body.length).to eq(3_000)
  end

  it "oltre il tetto delle idee → R422-IDEA-005 con il tetto dichiarato nel messaggio" do
    tetto = Ideas::Constants::COMMENT_MAX_CHARS

    result = described_class.call(idea:, author: member, params: { body: "x" * (tetto + 1) })

    expect(result).to be_err
    expect(result.error.code).to eq("R422-IDEA-005")
    expect(result.error.message).to include(tetto.to_s, (tetto + 1).to_s)
  end

  it "autore non membro dell'org → R422-IDEA-004 (integrità tenant dal model)" do
    outsider = create(:account)

    result = described_class.call(idea:, author: outsider, params: { body: "ciao" })

    expect(result).to be_err
    expect(result.error.code).to eq("R422-IDEA-004")
  end
end
