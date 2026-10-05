# frozen_string_literal: true

require "rails_helper"

# CYRA-411, livello 1: la rete di sicurezza server-side corregge le forme note, ma la difesa vera è
# non far scrivere male il modello. Ogni service che gli fa produrre testo italiano destinato a un
# umano deve portare la regola ortografica nel proprio prompt di sistema — è un elenco esplicito,
# così aggiungere un service nuovo senza la regola resta una scelta e non una dimenticanza.
RSpec.describe "Regola ortografica nei prompt di sistema" do
  PROMPT_CONSTANTS = {
    "Ticketing::AnalyzeBugReport" => -> { Ticketing::AnalyzeBugReport::SYSTEM_PROMPT },
    "Ticketing::SummarizeAnalysis" => -> { Ticketing::SummarizeAnalysis::SYSTEM_PROMPT },
    "Ticketing::SummarizeComment" => -> { Ticketing::SummarizeComment::SYSTEM_PROMPT },
    "Ticketing::RelabelAnalysis" => -> { Ticketing::RelabelAnalysis::SYSTEM_PROMPT },
    "Ticketing::AskTickets" => -> { Ticketing::AskTickets::SYSTEM_PROMPT },
    "Ticketing::EvaluateAgentEligibility" => -> { Ticketing::EvaluateAgentEligibility::SYSTEM_PROMPT },
    "Ideas::SynthesizeTicket" => -> { Ideas::SynthesizeTicket::SYSTEM_PROMPT },
    "Knowledge::AskPages" => -> { Knowledge::AskPages::SYSTEM_PROMPT },
    "Errors::TriageWithAi" => -> { Errors::TriageWithAi::SYSTEM_PROMPT },
    "Errors::FindSimilarGroups" => -> { Errors::FindSimilarGroups::SYSTEM_PROMPT },
    "Metrics::TriageWithAi" => -> { Metrics::TriageWithAi::SYSTEM_PROMPT },
    "Ticketing::ComposeTicket" => -> { Ticketing::ComposeTicket.new(project: nil, text: "x").send(:system_prompt) },
    "Assistant::SystemPrompt" => -> { Assistant::SystemPrompt.call(catalog: []) }
  }.freeze

  PROMPT_CONSTANTS.each do |name, prompt|
    it "#{name} chiede l'ortografia italiana corretta" do
      expect(prompt.call).to include(Text::ItalianOrthography::PROMPT_RULE.strip)
    end
  end
end
