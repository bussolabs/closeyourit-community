# frozen_string_literal: true

module Member
  # Invio di un messaggio all'assistente. Thin: risolve la conversazione (anti-BOLA via ownership) e
  # delega a Assistant::PostMessage, che persiste il turno, appende le bolle sullo stream e accoda il
  # job di risposta in streaming. Le bolle arrivano al browser via Turbo Stream (broadcast), quindi qui
  # basta reindirizzare alla conversazione (l'esperienza fluida senza reload è rifinita nella UI).
  class AssistantMessagesController < Member::BaseController
    permission_not_required "Messaggi di una conversazione propria: la conversazione si risolve dentro lo scope del " \
                            "proprio account."

    # Stato corrente di una bolla (partial `_message`). È il fallback di riconciliazione dello streaming:
    # se il turbo-frame del pannello sottoscrive lo stream DOPO che il job ha già inviato il broadcast
    # finale (rete/caricamento lenti), quel broadcast è perso e la bolla resterebbe su "sto scrivendo".
    # Lo Stimulus `ui--assistant-reconcile` interroga qui e, appena il messaggio è complete/failed,
    # rimpiazza la bolla. Ownership-scoped (anti-BOLA 404) come il resto del controller.
    def show
      conversation = scope.find(params[:conversation_id])
      message = conversation.messages.find(params[:id])
      render partial: "member/assistant_conversations/message", locals: { message: message }
    end

    def create
      conversation = scope.find(params[:conversation_id])

      result = Assistant::PostMessage.call(conversation: conversation, text: params[:text],
                                           correction_of: params[:correction_of].presence)

      respond_to do |format|
        # Nel pannello le bolle arrivano via broadcast Turbo; il campo lo svuota lo Stimulus SOLO se il
        # submit è riuscito. Su errore (es. testo di soli spazi) rispondi 422 → Stimulus NON svuota, il
        # testo dell'utente resta e la richiesta non "sparisce" in silenzio.
        format.turbo_stream { head(result.ok? ? :no_content : :unprocessable_content) }
        format.html do
          flash[:alert] = result.error.message if result.err?
          redirect_to member_assistant_conversation_path(conversation)
        end
      end
    end

    private

    def scope
      Assistant::Conversation.for(account: Current.account, organization: Current.organization)
    end
  end
end
