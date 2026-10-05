# frozen_string_literal: true

require "rails_helper"

RSpec.describe Ideas::Comment, type: :model do
  let(:org) { create(:organization) }
  let(:project) { create(:project, organization: org) }
  let(:idea) { create(:idea, organization: org, project: project) }

  it "è valido con autore membro dell'org e body presente" do
    expect(build(:idea_comment, idea: idea, organization: org)).to be_valid
  end

  it "rifiuta il body vuoto (anche solo spazi, via normalizes)" do
    comment = build(:idea_comment, idea: idea, organization: org, body: "   ")
    expect(comment).not_to be_valid
    expect(comment.errors[:body]).to be_present
  end

  it "rifiuta un autore non membro dell'org dell'idea (integrità tenant)" do
    outsider = create(:account)
    comment = build(:idea_comment, idea: idea, author: outsider)

    expect(comment).not_to be_valid
    expect(comment.errors[:author]).to be_present
  end

  it "aggiorna comments_count dell'idea (counter_cache) alla creazione e alla rimozione" do
    comment = create(:idea_comment, idea: idea, organization: org)
    expect(idea.reload.comments_count).to eq(1)

    comment.destroy
    expect(idea.reload.comments_count).to eq(0)
  end

  it "validatore tenant nil-safe: idea senza progetto → nessuna eccezione" do
    comment = described_class.new(idea: Ideas::Idea.new, author: create(:account), body: "x")
    expect { comment.valid? }.not_to raise_error
  end

  describe "tetto di lunghezza" do
    let(:max) { Ideas::Constants::COMMENT_MAX_CHARS }

    # CYRA-371 — qui si argomenta una decisione di prodotto: il tetto è quello del dominio idee, molto
    # più alto di quello dei commenti dei ticket (che è breve per costruzione, il lungo va nel resoconto).
    it "ha un tetto proprio, molto più largo di quello dei commenti dei ticket" do
      expect(max).to be > Ticketing::Constants::COMMENT_MAX_CHARS

      argomentato = build(:idea_comment, idea: idea, organization: org, body: "x" * 3_000)
      expect(argomentato).to be_valid
    end

    it "accetta il testo fino al tetto e rifiuta oltre, dichiarando il tetto delle idee" do
      expect(build(:idea_comment, idea: idea, organization: org, body: "x" * max)).to be_valid

      comment = build(:idea_comment, idea: idea, organization: org, body: "x" * (max + 1))
      expect(comment).to be_invalid
      expect(comment.errors.details[:body])
        .to include(hash_including(error: :length_budget_exceeded, count: max))
    end

    it "conta i fine-riga come li conta il browser (CRLF normalizzato a LF)" do
      comment = create(:idea_comment, idea: idea, organization: org, body: "riga1\r\nriga2")

      expect(comment.body).not_to include("\r")
    end

    # I commenti già in DB restano intoccati: la clausola di salvaguardia di LengthBudget vale anche
    # qui, quindi nemmeno un testo scritto oltre il tetto diventa di colpo non salvabile.
    it "un commento già oltre il tetto resta salvabile finché non si allunga" do
      storico = build(:idea_comment, idea: idea, organization: org, body: "x" * (max + 500))
      storico.save!(validate: false)

      storico.body = "x" * (max + 200)
      expect(storico).to be_valid
    end
  end
end
