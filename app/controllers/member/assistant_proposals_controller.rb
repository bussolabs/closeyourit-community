# frozen_string_literal: true

module Member
  # Cards of the actions the assistant proposed: only the owner of the conversation acts on them,
  # and every confirmation re-checks permission inside Assistant::Proposals::Confirm (CYRA-907).
  class AssistantProposalsController < Member::BaseController
    permission_not_required "Own conversation; each action re-checks its own permission at confirm time (CYRA-907)."

    EDITABLE = {
      "create_ticket" => %w[title description project_id priority_id],
      "comment_ticket" => %w[body],
      "change_ticket_status" => %w[status_id],
      "change_ticket_priority" => %w[priority_id],
      "assign_ticket" => %w[assignee_id],
      "create_todo" => %w[title list_id],
      "create_idea" => %w[title problem project_id],
      "start_agent_work" => %w[],
      "external_tool" => %w[]
    }.freeze

    before_action :set_conversation
    before_action :set_proposal, except: :confirm_all

    def confirm
      result = confirm_one(@proposal)
      respond_with_card(@proposal.reload, error: result.err? ? result.error.message : nil)
    end

    def update
      @proposal.update!(payload: @proposal.payload.merge(edited_payload)) if @proposal.confirmable?
      respond_with_card(@proposal)
    end

    def discard
      @proposal.update!(status: :discarded) if @proposal.confirmable?
      respond_with_card(@proposal)
    end

    def restore
      @proposal.update!(status: :pending) if @proposal.status_discarded?
      respond_with_card(@proposal)
    end

    def confirm_all
      message = @conversation.messages.find(params[:message_id])
      message.proposals.select(&:confirmable?).each { |proposal| confirm_one(proposal) }
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace("#{helpers.dom_id(message)}_proposals",
                                                    partial: "member/assistant_conversations/proposals",
                                                    locals: { message: message.reload })
        end
        format.html { redirect_to member_assistant_conversation_path(@conversation) }
      end
    end

    private

    def set_conversation
      @conversation = Assistant::Conversation.for(account: Current.account, organization: Current.organization)
                                             .find(params[:conversation_id])
    end

    def set_proposal
      @proposal = Assistant::Proposal.joins(:message)
                                     .where(account_id: Current.account.id, organization_id: Current.organization.id,
                                            assistant_messages: { conversation_id: @conversation.id })
                                     .find(params[:id])
    end

    def confirm_one(proposal)
      Assistant::Proposals::Confirm.call(proposal: proposal, account: Current.account,
                                         organization: Current.organization, true_actor: Current.true_account)
    end

    # Text keys as typed; chosen ids only when inside the scope, with their label (CYRA-907).
    def edited_payload
      input = params.require(:proposal).permit(*EDITABLE.fetch(@proposal.kind)).to_h
      choices = Assistant::Proposals::Choices.new(account: Current.account, organization: Current.organization)
      input.each_with_object({}) do |(key, value), changes|
        next changes[key] = value unless key.end_with?("_id")

        picked = choices.payload_for(key, value)
        changes.merge!(picked) if picked
      end
    end

    def respond_with_card(proposal, error: nil)
      respond_to do |format|
        format.turbo_stream do
          render turbo_stream: turbo_stream.replace(helpers.dom_id(proposal),
                                                    partial: "member/assistant_conversations/proposal",
                                                    locals: { proposal: proposal, error: error })
        end
        format.html do
          flash[:alert] = error if error
          redirect_to member_assistant_conversation_path(@conversation)
        end
      end
    end
  end
end
