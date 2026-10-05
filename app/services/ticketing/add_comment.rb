# frozen_string_literal: true

module Ticketing
  # Aggiunge un commento a un ticket già risolto e scoped dal controller (visibilità Fase E).
  # L'autore deve essere membro dell'org (validato sul model). Allegati opzionali. Result pattern.
  class AddComment < ApplicationService
    def initialize(ticket:, author:, params:)
      @ticket = ticket
      @author = author
      @params = params
    end

    def call
      comment = @ticket.comments.new(body: @params[:body], author: @author)
      comment.files.attach(files) if files.present?
      if comment.save
        capture_legacy_answer(comment)
        notify(comment)
        # `comment.save` ha già committato (l'action non apre transazioni esterne) → siamo dopo il commit.
        Ticketing::BroadcastComment.call(comment: comment)
        return Result.ok(comment)
      end

      too_long?(comment) ? too_long_error(comment) : invalid_error(comment)
    end

    private

    def too_long?(comment)
      comment.errors.details[:body].any? { |detail| detail[:error] == :length_budget_exceeded }
    end

    # Errore DEDICATO al superamento del tetto, e non il generico: è il messaggio che insegna il nuovo
    # posto del testo lungo a ogni chiamante esistente, umano o macchina. Un agente che prova a
    # postare 900 caratteri non deve leggere "commento non valido" ma "usa il resoconto".
    def too_long_error(comment)
      actual = comment.errors.details[:body].find { |d| d[:error] == :length_budget_exceeded }[:actual]
      Result.err(AppError.new(
                   I18n.t("member.tickets.comments.errors.too_long",
                          count: Ticketing::Constants::COMMENT_MAX_CHARS, actual: actual),
                   code: "R422-COMMENT-002", details: comment.errors.to_hash
                 ))
    end

    # Messaggio i18n generico (non i full_messages grezzi del model: evita "translation missing" nel
    # flash) per tutto ciò che non è previsto. I dettagli per-campo restano in details.
    def invalid_error(comment)
      Result.err(AppError.new(I18n.t("member.tickets.comments.errors.invalid"),
                              code: "R422-COMMENT-001", details: comment.errors.to_hash))
    end

    # RETE DI SICUREZZA, non più il canale (CYRA-781).
    #
    # Fino a qui questa era la strada normale per rispondere: il primo commento umano dopo una domanda
    # diventava la risposta, qualunque cosa dicesse. Adesso si risponde alla domanda che si nomina, e
    # un commento è di nuovo solo un commento.
    #
    # Ma i canali che sanno rispondere in modo mirato non sono ancora tutti: chi risponde commentando
    # dalla discussione, dalla riga di comando o da Telegram passa ancora di qui, e togliere l'aggancio
    # oggi lascerebbe una lavorazione ferma per sempre in mano a chi ha risposto in buona fede. Quindi
    # resta, ma stretta: morde SOLO su un giro a cui non ha ancora risposto nessuno. Morirà quando
    # anche gli ultimi canali sapranno nominare la domanda: CYRA-784 ha spento il marker e l'archivio
    # vecchio, non ha insegnato a Telegram e alla riga di comando a rispondere per domanda.
    #
    # `covers_round: true`: il commento è una risposta all'INTERO giro, non a una domanda in
    # particolare — chi l'ha scritto non ne ha nominata nessuna, ed è quello che va scritto.
    def capture_legacy_answer(comment)
      return unless @author.human?
      # Un commento marcato dall'automazione non è la parola di nessuno, anche quando lo firma un
      # account umano: la guardia c'era prima di questo cambiamento e resta, perché la ragione per cui
      # è stata scritta non è cambiata.
      return if comment.automation_generated?
      return if @ticket.status.category_done?

      workflow = @ticket.agent_workflow
      return if workflow.blank?

      clarification = workflow.clarifications.where(answered_at: nil).order(created_at: :desc).first
      return if clarification.blank? || clarification.created_at >= comment.created_at
      # Qualcuno ha già risposto a una domanda di questo giro dal canale giusto: il commento che
      # arriva dopo è una conversazione, non una risposta. Prima non c'era modo di distinguerli.
      return if clarification.questions.where.not(answered_at: nil).exists?

      # CYRA-784 — un giro senza nemmeno una riga non ha niente a cui appendere la risposta, e Settle
      # risponderebbe `blank`. Uscire qui lo dice invece di chiamare per farselo dire: dopo il drop
      # dell'archivio jsonb un giro così può nascere solo se qualcuno ne ha cancellato le domande, e
      # in quel caso il commento è una conversazione, non una risposta a niente.
      question_count = clarification.questions.count
      return if question_count.zero?

      # Lo stesso testo su ogni posizione del giro: chi ha commentato non ha nominato nessuna domanda,
      # e `covers_round` è ciò che permette di dirlo invece di attribuirgliene una.
      Agents::Clarifications::Settle.call(
        clarification: clarification, author: @author, response_comment: comment,
        answers: Array.new(question_count) { comment.body }, covers_round: true
      )
    end

    # Loop di collaborazione: l'autore diventa watcher; i menzionati (@handle, membri dell'org)
    # diventano watcher e vengono notificati. Il fan-out vero gira nel job (DispatchComment).
    def notify(comment)
      organization = @ticket.project.organization
      Subscription.ensure_for(ticket: @ticket, account: @author, source: :commenter)
      mentioned = Mentions::Parse.call(text: comment.body, organization: organization) - [ @author ]
      mentioned.each { |account| Subscription.ensure_for(ticket: @ticket, account: account, source: :mentioned) }
      Ticketing::CommentNotifyJob.perform_later(comment_id: comment.id, mentioned_ids: mentioned.map(&:id))
    end

    # Scarta i placeholder blank del form (hidden "" dell'input file array).
    # Array.wrap (non Array) per non spezzare un eventuale hash in coppie.
    def files
      Array.wrap(@params[:files]).reject(&:blank?)
    end
  end
end
