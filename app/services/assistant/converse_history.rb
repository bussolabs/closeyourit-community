# frozen_string_literal: true

module Assistant
  # The earlier turns the tool loop sends to the model. A reply that prepared cards is replayed as
  # what really happened: the propose_* call, the tool's answer, then the text. As bare text the
  # model learned to write "card ready" without calling the tool, and no card existed. CYRA-908
  class ConverseHistory < ApplicationService
    KIND_TOOLS = {
      "create_ticket" => "propose_ticket", "comment_ticket" => "propose_comment",
      "change_ticket_status" => "propose_status", "change_ticket_priority" => "propose_priority",
      "assign_ticket" => "propose_assignee", "create_todo" => "propose_todo", "create_idea" => "propose_idea"
    }.freeze

    def initialize(conversation:, question:)
      @conversation = conversation
      @question = question
    end

    def call
      earlier.flat_map { |message| message.role_user? ? [ text_turn("user", message) ] : reply_turns(message) }
    end

    private

    def earlier
      @conversation.messages.status_complete
                   .where(created_at: ...@question.created_at)
                   .where.not(content: [ nil, "" ])
                   .includes(:proposals)
                   .last(Constants::MAX_HISTORY_MESSAGES)
    end

    def reply_turns(message)
      return [ text_turn("model", message) ] if message.proposals.empty?

      [ { role: "model", parts: message.proposals.map { |proposal| { functionCall: call_of(proposal) } } },
        { role: "user", parts: message.proposals.map { |proposal| { functionResponse: response_of(proposal) } } },
        text_turn("model", message) ]
    end

    def text_turn(role, message) = { role: role, parts: [ { text: message.content } ] }

    # Ids and the similar-tickets list are for the card, not for the model.
    def call_of(proposal)
      { id: "proposal-#{proposal.id}", name: KIND_TOOLS.fetch(proposal.kind),
        args: proposal.payload.reject { |key, _| key.end_with?("_id") || key == "similar" } }
    end

    def response_of(proposal)
      status = proposal.status_pending? ? "awaiting_confirmation" : proposal.status
      { id: "proposal-#{proposal.id}", name: KIND_TOOLS.fetch(proposal.kind),
        response: { proposal_id: proposal.id, status: status } }
    end
  end
end
