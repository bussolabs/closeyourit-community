# frozen_string_literal: true

module Assistant
  # Produce UNA risposta dell'assistente che legge i dati, fuori dal ciclo della richiesta web.
  #
  # Gira sul worker (coda :ai) perché il giro degli attrezzi fa più chiamate al modello di fila —
  # due o tre per una domanda normale, fino a cinque per una che ne incatena diverse — e tenere
  # occupato un thread di Puma per quei secondi è un modo lento di mettersi giù da soli. Chi ha
  # scritto riceve subito l'id del messaggio e ne segue lo stato.
  #
  # Il perimetro visibile arriva dal controller e non viene ricalcolato qui: è quello autorizzato al
  # momento dell'invio. Ricostruirlo dentro il job cambierebbe le carte in tavola fra la domanda e la
  # risposta, e nel caso di un god che impersona darebbe il perimetro sbagliato. È però un TETTO e
  # non un lasciapassare (CYRA-812): prima di leggere lo si interseca con il perimetro di adesso,
  # perché fra la domanda e la risposta possono passare minuti e un accesso può essere stato tolto.
  #
  # Gemello del canale web (StreamReplyJob) ma senza streaming: a un client JSON i token uno a uno
  # non servono e costerebbero un WebSocket. Qui la risposta si scrive tutta insieme quando è pronta.
  class ConverseJob < ApplicationJob
    queue_as :ai

    # Una risposta per volta nella STESSA conversazione: due invii ravvicinati costruirebbero la
    # storia prima che la risposta precedente sia finita, e si risponderebbero addosso. Conversazioni
    # diverse restano parallele. Stessa scelta di StreamReplyJob, per gli stessi motivi.
    limits_concurrency to: 1, key: ->(message_id:, **) {
      Assistant::Message.where(id: message_id).pick(:conversation_id) || message_id
    }

    def perform(message_id:, question_id:, project_ids:, group_ids: [], full_access: false,
                scope_listed: false, with_catalog: false)
      message = Assistant::Message.find_by(id: message_id)
      # Già risposto (consegna at-least-once di Solid Queue, o retry): non si ripaga il giro di
      # attrezzi per sovrascrivere una risposta che chi ha chiesto sta già leggendo.
      return unless message&.status_streaming?

      conversation = message.conversation
      Current.account = conversation.account
      Current.organization = conversation.organization

      I18n.with_locale(conversation.account.effective_locale) do
        answer(message, conversation, question_id,
               Authorization::ScopeSnapshot.frozen(project_ids: project_ids, group_ids: group_ids,
                                                   full_access: full_access, listed: scope_listed),
               with_catalog: with_catalog)
      end
    ensure
      Current.reset
    end

    private

    def answer(message, conversation, question_id, ceiling, with_catalog:)
      # La domanda potrebbe non esserci più (conversazione ripulita fra l'invio e l'esecuzione):
      # senza questo la risposta resterebbe "in lavorazione" per sempre.
      question = conversation.messages.find_by(id: question_id)
      return fail_message(message, code: "R422-ASSISTANT-001", reason: "domanda sparita") if question.nil?

      context = context_for(conversation, ceiling, reply_message_id: (message.id if with_catalog))
      result = Converse.call(
        context: context, question: question.content.to_s,
        history: ConverseHistory.call(conversation: conversation, question: question),
        catalog: (catalog_for(conversation) if with_catalog), focus: focus_of(conversation, context)
      )

      if result.ok?
        message.update!(status: :complete,
                        content: result.value.text.presence || I18n.t("assistant.errors.no_answer"),
                        tools_used: result.value.tools_used)
        broadcast_final(message)
      else
        fail_message(message, code: result.error.code, reason: result.error.message)
      end
    rescue StandardError => e
      # Un guasto imprevisto non deve lasciare la risposta a girare per sempre: chi ha scritto deve
      # vedere che è andata male. Si logga la causa, altrimenti resta solo un codice su una riga.
      Rails.logger.error("[assistant] risposta fallita message=#{message.id}: #{e.class} #{e.message}")
      fail_message(message, code: "R500-ASSISTANT-001", reason: e.message)
      raise
    end

    # Il perimetro arriva dall'invio e resta un TETTO (CYRA-812): prima di leggere si interseca con
    # quello che l'account vede ADESSO. Così una revoca arrivata mentre la domanda era in coda vale,
    # e un permesso arrivato dopo non allarga la risposta. L'account è quello della conversazione
    # perché il canale a token non impersona: chi ha scritto è chi ha il token.
    def context_for(conversation, ceiling, reply_message_id: nil)
      Tools::Context.from_snapshot(
        ceiling.narrow(account: conversation.account, organization: conversation.organization),
        account: conversation.account, organization: conversation.organization, reply_message_id: reply_message_id
      )
    end

    # Storia nel formato del provider: i turni CONCLUSI e con del testo che precedono questa domanda.
    #
    # Il taglio è per ISTANTE della domanda assegnata e non per contenuto: due domande identiche in
    # momenti diversi sono due turni distinti, e scartarle entrambe lascerebbe una risposta senza la
    # sua domanda — un buco su cui il modello ragiona male.
    #
    # I messaggi falliti non entrano: riproporre al modello una risposta che non c'è stata è
    # raccontargli una cosa mai avvenuta. E si tengono solo gli ULTIMI turni: la conversazione serve
    # a risolvere i riferimenti all'indietro, che guardano vicino, mentre una storia senza tetto fa
    # crescere il costo di ogni domanda con la lunghezza della chiacchierata.
    def fail_message(message, code:, reason:)
      Rails.logger.warn("[assistant] #{code} su message=#{message.id}: #{reason}")
      message.update!(status: :failed, error_code: code)
      broadcast_final(message)
    end

    # The project a conversation is fixed on, named to the model only while it is still in scope.
    def focus_of(conversation, context)
      conversation.project if context.project_ids.include?(conversation.project_id)
    end

    # The widget also helps finding pages: it gets the pages the asking account may open (CYRA-906).
    def catalog_for(conversation)
      BuildCatalog.call(account: conversation.account, organization: conversation.organization)
    end

    # The widget waits for the final bubble; a CLI conversation has no subscriber (CYRA-906).
    def broadcast_final(message)
      Turbo::StreamsChannel.broadcast_replace_to(
        Realtime::Streams.assistant_conversation(message.conversation),
        target: ActionView::RecordIdentifier.dom_id(message),
        partial: "member/assistant_conversations/message",
        locals: { message: message }
      )
    end
  end
end
