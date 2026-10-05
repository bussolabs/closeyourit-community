# frozen_string_literal: true

module Cli
  module V1
    module Assistant
      module Conversations
        # Invio di una domanda all'assistente che legge i dati.
        #
        # Risponde 202 e non 200: la risposta non è pronta. Vengono creati due messaggi — la domanda
        # (già completa) e la risposta (in lavorazione) — e il client segue quest'ultima su
        # GET /cli/v1/assistant/messages/:id finché smette di essere "streaming". Non si passa da
        # Ai::Request: il messaggio è già l'oggetto che il client deve mostrare, un secondo
        # identificatore da inseguire non aggiungerebbe nulla.
        #
        # Il perimetro visibile si congela QUI e viaggia con il lavoro. Ricalcolarlo dentro il job
        # darebbe il perimetro di un altro momento, e con un god che impersona darebbe quello
        # sbagliato: le autorizzazioni sono quelle valide quando la domanda è partita. Porta tre
        # cose e non una — progetti, gruppi e accesso pieno — perché la knowledge base non appartiene
        # a un progetto (::Assistant::Tools::Context). È un TETTO e non un lasciapassare (CYRA-812):
        # prima di leggere, il job lo interseca con il perimetro di allora, così una revoca arrivata
        # mentre la domanda era in coda vale e un permesso arrivato dopo non allarga la risposta.
        class MessagesController < Cli::V1::BaseController
          def create
            conversation = scope.find(params[:conversation_id])
            text = params[:text].to_s.strip
            return render_blank if text.blank?
            return render_too_long if text.length > ::Assistant::Constants::MAX_MESSAGE_CHARS
            # Il gate sta PRIMA della scrittura, come in ::Assistant::PostMessage: con l'assistente
            # spento dal god la domanda va rifiutata subito, non accolta e lasciata senza risposta per
            # sempre. Così non nasce nemmeno il messaggio, e nessun lavoro finisce in coda. Il gate
            # «servizio collegato» non c'è più: l'AI la offre il sistema, non l'organizzazione (CYRA-765).
            return render_disabled if ::Ai::Feature.disabled?(:assistant_tools)

            reply = post(conversation, text)
            render json: { data: AssistantMessageSerializer.new(reply).to_h }, status: :accepted
          end

          private

          def post(conversation, text)
            question = nil
            reply = nil

            ActiveRecord::Base.transaction do
              question = conversation.messages.create!(organization: Current.organization, role: :user,
                                                       status: :complete, content: text)
              reply = conversation.messages.create!(organization: Current.organization, role: :assistant,
                                                    status: :streaming)
              conversation.update!(last_message_at: reply.created_at, title: conversation.title || title_from(text))
            end

            scope_now = Authorization::ScopeSnapshot.capture(account: Current.account,
                                                             organization: Current.organization)
            ::Assistant::ConverseJob.perform_later(
              message_id: reply.id, question_id: question.id,
              project_ids: scope_now.project_ids, group_ids: scope_now.group_ids,
              full_access: scope_now.full_access, scope_listed: true
            )
            reply
          end

          # Il titolo nasce dalla PRIMA domanda: una lista di conversazioni tutte senza nome non aiuta
          # a ritrovare quella giusta, e riscriverlo a ogni invio la farebbe cambiare nome sotto gli
          # occhi di chi la sta cercando.
          def title_from(text) = text.truncate(60)

          def render_blank
            render_error("R422-ASSISTANT-001", I18n.t("assistant.errors.blank"),
                         status: :unprocessable_content)
          end

          # Sul web il testo abbondante viene troncato in silenzio (::Assistant::PostMessage); qui no:
          # un client che riceve la risposta a una domanda tagliata a metà non ha modo di accorgersene.
          def render_too_long
            render_error("R422-ASSISTANT-004",
                         I18n.t("assistant.errors.too_long", max: ::Assistant::Constants::MAX_MESSAGE_CHARS),
                         status: :unprocessable_content)
          end

          def render_disabled
            error = ::Ai::Feature.disabled_error(:assistant_tools)
            render_error(error.code, error.message, status: error.status)
          end

          def scope
            ::Assistant::Conversation.for(account: Current.account, organization: Current.organization,
                                          kind: :tools)
          end
        end
      end
    end
  end
end
