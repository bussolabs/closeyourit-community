require "rails_helper"

RSpec.describe Ticketing::CommentShape do
  let(:organization) { create(:organization) }
  let(:ticket) { create(:ticket, organization: organization, with_agent_workflow: true) }

  # `save!(validate: false)`: sono righe storiche, scritte prima che il tetto esistesse — è esattamente
  # lo stato in cui il classificatore le incontra in produzione.
  def comment(body, **attributes)
    build(:ticket_comment, organization: organization, ticket: ticket, body: body, **attributes)
      .tap { |record| record.save!(validate: false) }
  end

  def shape_of(record, **options)
    described_class.call(comment: record, **options)
  end

  describe "commenti corti" do
    it "classifica corto ciò che sta già entro il tetto" do
      expect(shape_of(comment("Confermo."))).to eq(:short)
    end

    it "considera corto un commento esattamente al tetto" do
      expect(shape_of(comment("x" * Ticketing::Constants::COMMENT_MAX_CHARS))).to eq(:short)
    end

    it "non classifica corto un commento di un carattere oltre il tetto" do
      expect(shape_of(comment("x" * (Ticketing::Constants::COMMENT_MAX_CHARS + 1)))).not_to eq(:short)
    end

    it "considera corta anche una domanda breve: non c'è niente da spostare" do
      short_question = comment("DOMANDE: <!-- closeyourit-autopilot:waiting:v1 cycle=1 -->")

      expect(shape_of(short_question)).to eq(:short)
    end
  end

  describe "domande di chiarimento" do
    let(:long_body) { "DOMANDE:\n\n1. Quale delle due strade preferisci?\n#{"x" * 300}" }

    it "riconosce una domanda dal marker legacy nel corpo" do
      question = comment("#{long_body}\n<!-- closeyourit-autopilot:waiting:v1 cycle=1 -->")

      expect(shape_of(question)).to eq(:question)
    end

    it "riconosce una domanda dalla foreign key, anche senza marker nel corpo" do
      question = comment(long_body)

      expect(shape_of(question, question_comment_ids: [ question.id ])).to eq(:question)
    end

    it "risolve la foreign key da sola se non gliela si passa" do
      question = comment(long_body)
      # La factory :ticket crea già il workflow: crearne un secondo violerebbe l'unicità.
      create(:agent_clarification, workflow: ticket.agent_workflow, question_comment: question)

      expect(shape_of(question)).to eq(:question)
    end
  end

  describe "resoconti" do
    it "classifica resoconto qualunque commento lungo che non è una domanda" do
      report = comment("Fatto. #{"x" * 500}")

      expect(shape_of(report)).to eq(:report)
    end

    it "non si fa ingannare da un marker di automazione diverso da quello dei chiarimenti" do
      report = comment("Fatto. #{"x" * 500}\n<!-- closeyourit-automation:triage -->")

      expect(shape_of(report)).to eq(:report)
    end
  end
end
