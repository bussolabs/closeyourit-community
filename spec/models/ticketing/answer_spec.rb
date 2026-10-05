require "rails_helper"

RSpec.describe Ticketing::Answer, type: :model do
  it "produce una risposta valida" do
    expect(build(:ticket_answer)).to be_valid
  end

  describe "corpo" do
    it "è invalido se vuoto o di soli spazi" do
      expect(build(:ticket_answer, body: nil)).not_to be_valid
      expect(build(:ticket_answer, body: "   ")).not_to be_valid
    end

    it "normalizza gli spazi e mette gli accenti mancanti" do
      answer = create(:ticket_answer, body: "  E' cosi'  ")

      expect(answer.body).to eq("È così")
    end

    it "rifiuta una risposta oltre il tetto" do
      max = Ticketing::Constants::ANSWER_MAX_CHARS

      expect(build(:ticket_answer, body: "x" * max)).to be_valid
      expect(build(:ticket_answer, body: "x" * (max + 1))).to be_invalid
    end
  end

  # Chi risponde può legittimamente nominare un file o un comando: la regola anti-comando esiste
  # perché una DOMANDA posta a una persona non deve sembrare un'istruzione da eseguire, e su una
  # risposta quella ragione non c'è.
  it "accetta un percorso o un comando nella risposta" do
    expect(build(:ticket_answer, body: "Sta in app/models/x.rb, lancia bin/rails db:migrate")).to be_valid
  end

  describe "isolamento tenant" do
    it "rifiuta un autore che non è membro dell'organizzazione del ticket" do
      answer = build(:ticket_answer, author: create(:account))

      expect(answer).to be_invalid
      expect(answer.errors.details[:author]).to include(hash_including(error: :not_member))
    end
  end

  it "sparisce con la domanda" do
    answer = create(:ticket_answer)

    expect { answer.question.destroy }.to change(described_class, :count).by(-1)
  end
end
