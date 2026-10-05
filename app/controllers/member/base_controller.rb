# frozen_string_literal: true

module Member
  # Base dell'area organizzazione: richiede autenticazione + un'organizzazione di contesto.
  class BaseController < ApplicationController
    include OrganizationContext
    # CYRA-740 — le tre parti che prima vivevano dentro OrganizationContext: chi può fare cosa, che
    # cosa vede di ogni dominio, quali voci di menu hanno senso per lui.
    include PermissionGates
    include VisibleResources
    include NavigationVisibility
    include GroupContext
    include Listable
    # CYRA-694 — inerte finché un controller non dichiara `remembers_filters`.
    include RememberableFilters
    include AiEnqueueing
    include Localizable
    # CYRA-727 — ogni pagina dell'area dice quale permesso controlla, o perché non ne serve uno.
    include PermissionDeclaration

    include ModalForms

    layout -> { modal_form_request? ? "member_modal" : "member" }

    before_action :set_current_organization
    before_action :require_organization
    # CYRA-722 — l'organizzazione sospesa non apre nessuna pagina dell'area. Sta qui, sulla base di
    # tutti i controller member, non sui singoli: una pagina nuova nasce già chiusa.
    before_action :require_active_organization
    # CYRA-700 — quali parti del prodotto girano davvero; CYRA-733 aggiunge la FUNZIONE aperta
    # accanto alla rotta. Spento finché non è configurato un progetto (Usage::SelfRecorder): allora
    # `record` non tiene nemmeno il simbolo in memoria.
    after_action :record_usage

    # B25 — only member pages expose it, so the page header offers its toggle here and nowhere else.
    helper_method :page_header_compact?
    # Ui::FloatingNoticeComponent — a notice the person closed stays closed.
    helper_method :notice_dismissed?

    private

    def page_header_compact?
      Current.account&.page_header_compact? || false
    end

    def notice_dismissed?(key)
      Current.account&.notice_dismissed?(key) || false
    end

    # Solo le pagine viste per davvero: una GET andata a buon fine. Un redirect non è una pagina
    # aperta, e contarlo direbbe che una funzione è usata mentre chi l'ha aperta è finito altrove.
    # Non deve MAI far fallire la richiesta che la sta misurando.
    def record_usage
      return unless request.get? && response.successful?
      return if prefetch?
      # CYRA-823 — un pezzo di pagina che si ricarica da solo non è una pagina aperta. La scheda di
      # un agente ri-chiede il riquadro dell'attività a ogni battito della macchina: contarlo direbbe
      # che quella funzione è stata aperta centinaia di volte al giorno da chi l'ha aperta una volta,
      # e quel numero è proprio quello su cui si decide cosa vale la pena tenere.
      return if turbo_frame_request?

      Usage::SelfRecorder.record("#{self.class.name}##{action_name}")
      # CYRA-733 — la stessa apertura vale anche come FUNZIONE di prodotto. La chiave viene dal
      # percorso normalizzato (mai da `request.path`, che porta gli identificativi) e dal catalogo
      # dell'assistente, così una funzione ha lo stesso nome ovunque. Le pagine fuori catalogo
      # restano coperte dal solo simbolo di rotta: meglio nessuna chiave che una inventata qui.
      feature = Usage::FeatureMap.key_for(
        Usage::FeatureMap.normalize(request.path, request.path_parameters)
      )
      Usage::SelfRecorder.record(feature, kind: "feature_view") if feature
      Usage::SelfRecorder.flush_if_due!
    rescue StandardError => e
      Rails.logger.warn("Usage::SelfRecorder — #{e.class}: #{e.message}")
    end

    # CYRA-733 — la pagina che il browser scarica in ANTICIPO non è una pagina aperta. Turbo la
    # chiede al passaggio del mouse su un link (prefetch acceso di default) e il browser la chiede
    # per conto suo: senza questo confine basterebbe sfiorare le voci del menu — che linkano tutte le
    # funzioni — per far risultare «usata» ogni funzione del prodotto, cioè proprio il numero su cui
    # si decide che cosa vale la pena tenere. Tre nomi per la stessa intenzione: `X-Sec-Purpose` lo
    # mette Turbo, `Sec-Purpose` il browser moderno (`prefetch;prerender`), `Purpose` quelli vecchi.
    def prefetch?
      %w[X-Sec-Purpose Sec-Purpose Purpose].any? do |header|
        request.headers[header].to_s.include?("prefetch")
      end
    end

    # Viste salvate dell'utente per una risorsa (index filtrabili): alimenta il widget del toolbar.
    def saved_views_for(resource_type)
      SavedView.for(account: Current.account, organization: Current.organization)
               .for_resource(resource_type).ordered
    end

    # A New opened from inside the modal (the + next to a select) stacks a second modal on top.
    def stacked_modal_request?
      turbo_frame_request_id == "modal_stack"
    end

    # What a stacked save answers: the record, so the form underneath adds and picks it (CYRA-933).
    def render_modal_created(value:, label:, color: nil)
      render "member/shared/modal_created", locals: { value: value, label: label, color: color }
    end
  end
end
