# frozen_string_literal: true

module Ai
  # Esegue una Ai::Request in background (coda :ai): il polling del gateway Proxanything (~30s)
  # non occupa più un thread Puma — l'endpoint accoda e risponde 202, la UI polla l'esito su
  # GET /member/ai/requests/:id. Autorizzazione e anti-BOLA sono verificati dal controller
  # all'enqueue; qui il lookup è difensivo (scoped all'organization della richiesta).
  #
  # Niente retry: il service incapsula gli errori del gateway in Result.err (nessuna eccezione),
  # e un'eccezione inattesa marca la richiesta failed — ritentarla ripagherebbe una chiamata LLM
  # per un esito già mostrato come fallito.
  class RunJob < ApplicationJob
    queue_as :ai

    def perform(request)
      Current.organization = request.organization # runs with this organization's AI settings (CYRA-914)
      run(request)
    rescue StandardError => e
      Rails.logger.error("Ai::RunJob failed request=#{request.id} kind=#{request.kind}: #{e.class} #{e.message}")
      request.finish_err!(code: "R500-SYSTEM-001", message: I18n.t("member.ai.errors.internal"))
    end

    private

    def run(request)
      result = execute(request)
      if result.ok?
        request.finish_ok!(payload_for(request, result.value))
        record_knowledge_ask(request, result.value) if request.kind == "knowledge_ask"
      else
        request.finish_err!(code: result.error.code, message: result.error.message)
      end
    end

    # Storico condiviso "Chiedi alla KB" (CYRA-421): la domanda conclusa entra nella memoria di team con
    # risposta e pagine citate, portandosi lo snapshot di scope autorizzato all'enqueue (per la stessa
    # visibilità delle pagine). Best-effort con rescue PROPRIO: la risposta è già stata consegnata
    # (finish_ok! sopra), un intoppo nel salvare lo storico non deve ricadere nel rescue di #perform e
    # ribaltare a failed una richiesta done.
    def record_knowledge_ask(request, value)
      # Il perimetro registrato è quello su cui si è RISPOSTO (già ristretto dalle revoche, CYRA-812),
      # non quello dell'invio: è lo stesso perimetro con cui lo storico decide poi chi può rileggere
      # la voce, e scriverci il tetto la renderebbe visibile più larga di com'è stata prodotta.
      scope = narrowed_scope(request)
      Knowledge::AskLog.record!(
        account: request.account, organization: request.organization,
        question: request.args.fetch("question").to_s, answer: value.answer, insufficient: value.insufficient,
        full_access: scope.full_access, project_ids: scope.project_ids, group_ids: scope.group_ids,
        citations: value.pages.map { |page| page_ask_payload(page) }
      )
    rescue StandardError => e
      Rails.logger.error("Ai::RunJob knowledge_ask history failed request=#{request.id}: #{e.class} #{e.message}")
    end

    def execute(request)
      org = request.organization
      case request.kind
      when "ticket_analyze"
        project = org.projects.find(request.args.fetch("project_id"))
        Ticketing::AnalyzeBugReport.call(project:, text: request.args.fetch("text").to_s)
      when "ticket_compose"
        project = org.projects.find(request.args.fetch("project_id"))
        # correction/previous_draft sono assenti al primo giro (richieste create prima di CYRA-632
        # comprese): `[]` e non `fetch`, o una richiesta rimasta in coda dal deploy precedente
        # morirebbe con una KeyError invece di comporre come ha sempre fatto.
        Ticketing::ComposeTicket.call(project:, text: request.args.fetch("text").to_s,
                                      correction: request.args["correction"],
                                      previous_draft: request.args["previous_draft"])
      when "ticket_ask"
        Ticketing::AskTickets.call(scope: ticket_ask_scope(request), organization: org,
                                   question: request.args.fetch("question").to_s)
      when "knowledge_ask"
        Knowledge::AskPages.call(scope: knowledge_ask_scope(request), organization: org,
                                 question: request.args.fetch("question").to_s)
      when "error_triage"
        Errors::TriageWithAi.call(group: org.error_groups.find(request.args.fetch("group_id")))
      when "error_similar"
        Errors::FindSimilarGroups.call(group: org.error_groups.find(request.args.fetch("group_id")))
      when "metric_triage"
        Metrics::TriageWithAi.call(group: metric_group(org, request.args.fetch("group_id")))
      when "idea_synthesize"
        Ideas::SynthesizeTicket.call(idea: idea(org, request.args.fetch("idea_id")))
      else
        Result.err(AppError.new("Kind AI sconosciuto", code: "R422-AI-001"))
      end
    end

    def metric_group(org, id)
      Metrics::Group.where(project_id: org.projects.select(:id)).find(id)
    end

    def idea(org, id)
      Ideas::Idea.where(project_id: org.projects.select(:id)).find(id)
    end

    # Scope di visibilità AUTORIZZATO NEL CONTROLLER (visible.projects) e passato come ids.
    # Lo snapshot resta — ricalcolare da zero qui darebbe il perimetro di un altro momento, e con un
    # god che impersona quello dell'impersonato — ma è un TETTO, non un lasciapassare (CYRA-812):
    # #narrowed_scope lo interseca col perimetro di ADESSO. Così una revoca arrivata mentre la
    # domanda era in coda vale, e un permesso arrivato dopo non allarga la risposta. Prima l'attesa
    # era "una finestra di secondi", ma il lavoro sta in coda quanto serve al worker per arrivarci.
    # Gemello di Authorization::VisibleScope#tickets.
    def ticket_ask_scope(request)
      Ticketing::Ticket.where(project_id: narrowed_scope(request).project_ids)
    end

    # Idem per la KB (visibilità N:N su progetti/gruppi). full_access=true (owner/god) → tutte le
    # pagine dell'org, ma solo se l'accesso pieno c'è ANCORA; altrimenti EXISTS sui project/group ids
    # rimasti. Gemello di Authorization::VisibleScope#pages.
    def knowledge_ask_scope(request)
      scope = narrowed_scope(request)
      Knowledge::Page.visible_to(
        account: request.account, organization: request.organization,
        full_access: scope.full_access,
        visible_project_ids: scope.project_ids, visible_group_ids: scope.group_ids
      )
    end

    # Il tetto dell'invio ∩ il perimetro di adesso, memoizzato PER RICHIESTA: lo storico della KB lo
    # rilegge subito dopo la risposta e non deve rifare le stesse letture. La chiave è l'id e non una
    # variabile sola perché il memo non deve poter rispondere per la richiesta sbagliata.
    def narrowed_scope(request)
      @narrowed_scopes ||= {}
      @narrowed_scopes[request.id] ||= begin
        args = request.args
        Authorization::ScopeSnapshot
          .frozen(project_ids: args["project_ids"], group_ids: args["group_ids"],
                  full_access: args["full_access"], listed: args["scope_listed"])
          .narrow(account: actor_for(request), organization: request.organization)
      end
    end

    # Chi ha AUTORIZZATO la domanda, che non sempre è l'account della richiesta: con un god che
    # impersona, il controller salva l'id del god (Current.true_account) perché il perimetro era il
    # suo. Senza quell'id — richieste accodate prima di CYRA-812 — si ripiega sull'account della
    # richiesta: al più restringe, mai allarga, che è il verso giusto in cui sbagliare.
    def actor_for(request)
      id = request.args["actor_account_id"]
      (id.present? && Accounts::Account.find_by(id: id)) || request.account
    end

    # Trasforma il valore del service nello stesso payload che gli endpoint sincroni rendevano:
    # il JS lato client resta identico a valle del poll.
    #
    # CYRA-831 — le due domande che portano un perimetro dichiarano anche se quel perimetro si è
    # ristretto fra l'invio e la risposta. Il dato c'è già (#narrowed_scope, memoizzato: nessuna
    # lettura in più), ma senza dirlo la risposta arriva più povera senza spiegare perché, e
    # «nessun ticket pertinente» si legge come un fatto sull'archivio invece che come un accesso
    # tolto nel frattempo. Il campo resta FUORI dagli altri kind: là non c'è nessun perimetro da
    # restringere, e un `false` costante li farebbe sembrare misurati quando non lo sono.
    def payload_for(request, value)
      case request.kind
      when "ticket_analyze"
        { complete: value.complete, scenarios: value.scenarios,
          technical_analysis: value.technical_analysis, questions: value.questions }
      when "ticket_compose"
        { title: value.title, kind: value.kind, description: value.description,
          technical_analysis: value.technical_analysis,
          scenarios: value.scenarios, conditions: value.conditions,
          # Le pagine lette entrano nel payload perché l'anteprima le mostri: una bozza che non dice
          # su cosa si è basata chiede di essere creduta sulla parola, ed è esattamente ciò che qui
          # non vogliamo. Serve anche a chi legge per capire perché la bozza ha imboccato una strada.
          knowledge: value.knowledge }
      when "ticket_ask"
        { answer: value.answer, insufficient: value.insufficient,
          scope_reduced: narrowed_scope(request).reduced?,
          tickets: value.tickets.map { |ticket| ticket_ask_payload(ticket) } }
      when "knowledge_ask"
        { answer: value.answer, insufficient: value.insufficient,
          scope_reduced: narrowed_scope(request).reduced?,
          pages: value.pages.map { |page| page_ask_payload(page) } }
      when "error_triage"
        { category: value.category, severity_suggested: value.severity_suggested,
          root_cause: value.root_cause, suggested_action: value.suggested_action,
          confidence: value.confidence, summary: value.summary }
      when "error_similar"
        { reason: value.reason,
          groups: value.groups.map do |group|
            { id: group.id, title: group.title, culprit: group.culprit,
              url: Rails.application.routes.url_helpers.member_monitoring_error_group_path(group) }
          end }
      when "metric_triage"
        { category: value.category, severity: value.severity, root_cause: value.root_cause,
          suggested_fix: value.suggested_fix, suggested_action: value.suggested_action,
          confidence: value.confidence, summary: value.summary }
      when "idea_synthesize"
        { title: value.title, description: value.description }
      end
    end

    # Serializzazione delle citazioni, allineata a Ticketing::DedupPresenter#payload: le
    # chiavi che il JS ticket_ask legge (code/title/status_label/url) + id/kind per parità col
    # payload che l'endpoint sincrono rendeva prima di CYRA-275.
    def ticket_ask_payload(ticket)
      { id: ticket.id, code: ticket.code, title: ticket.title, kind: ticket.kind,
        status_label: ticket.status&.label, url: url_helpers.member_ticket_path(ticket) }
    end

    # Allineata a Member::Knowledge::PagesController#ask_payload.
    def page_ask_payload(page)
      { id: page.id, title: page.title, kind: page.kind,
        kind_label: I18n.t("member.knowledge.kind.#{page.kind}"),
        url: url_helpers.member_knowledge_page_path(page) }
    end

    def url_helpers
      Rails.application.routes.url_helpers
    end
  end
end
